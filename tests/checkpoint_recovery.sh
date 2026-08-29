#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

MOUNT_DIR="mount"
DB_FILE="volume/metadata.db"

RUN_ID="$(date +%s)"

APPLIED_DIR="checkpoint-applied-$RUN_ID"
INCOMPLETE_DIR="checkpoint-incomplete-$RUN_ID"
UNAPPLIED_DIR="checkpoint-unapplied-$RUN_ID"

NORMAL_LOG="/tmp/ccfs-checkpoint-normal.log"
CRASH_LOG="/tmp/ccfs-checkpoint-crash.log"
CHECKPOINT_LOG="/tmp/ccfs-checkpoint.log"
STATUS_LOG="/tmp/ccfs-checkpoint-status.log"
INTEGRITY_LOG="/tmp/ccfs-checkpoint-integrity.log"

CCFS_PID=""
BACKUP_ROOT=""

fail() {
    echo
    echo "TEST FAILED: $1"
    echo

    echo "Normal/recovery log:"
    echo "----------------------------------------"
    cat "$NORMAL_LOG" 2>/dev/null || true

    echo
    echo "Crash log:"
    echo "----------------------------------------"
    cat "$CRASH_LOG" 2>/dev/null || true

    echo
    echo "Checkpoint log:"
    echo "----------------------------------------"
    cat "$CHECKPOINT_LOG" 2>/dev/null || true

    echo
    echo "Recovery status:"
    echo "----------------------------------------"
    cat "$STATUS_LOG" 2>/dev/null || true

    exit 1
}

pass() {
    echo "PASS: $1"
}

is_mounted() {
    mountpoint -q "$MOUNT_DIR"
}

detach_mount() {
    set +e

    if is_mounted; then
        fusermount3 -u "$MOUNT_DIR" 2>/dev/null ||
            fusermount3 -uz "$MOUNT_DIR" 2>/dev/null ||
            true
    fi

    set -e
}

stop_ccfs() {
    set +e

    detach_mount

    if [[ -n "${CCFS_PID:-}" ]] &&
        kill -0 "$CCFS_PID" 2>/dev/null
    then
        kill "$CCFS_PID" 2>/dev/null || true
    fi

    if [[ -n "${CCFS_PID:-}" ]]; then
        wait "$CCFS_PID" 2>/dev/null || true
    fi

    CCFS_PID=""

    set -e
}

wait_for_mount() {
    local pid="$1"

    for _ in $(seq 1 100); do
        if is_mounted; then
            return 0
        fi

        if ! kill -0 "$pid" 2>/dev/null; then
            return 1
        fi

        sleep 0.05
    done

    return 1
}

start_normal_ccfs() {
    stop_ccfs

    : > "$NORMAL_LOG"

    ./target/debug/ccfs >"$NORMAL_LOG" 2>&1 &
    CCFS_PID=$!

    wait_for_mount "$CCFS_PID" ||
        fail "normal CCFS failed to mount"
}

start_crash_ccfs() {
    local point="$1"

    stop_ccfs

    : > "$CRASH_LOG"

    env \
        CCFS_KILL9_OPERATION="MKDIR" \
        CCFS_KILL9_POINT="$point" \
        ./target/debug/ccfs >"$CRASH_LOG" 2>&1 &

    CCFS_PID=$!

    wait_for_mount "$CCFS_PID" ||
        fail "crash-mode CCFS failed to mount"
}

wait_for_sigkill() {
    local pid="$CCFS_PID"

    for _ in $(seq 1 100); do
        if ! kill -0 "$pid" 2>/dev/null; then
            break
        fi

        sleep 0.05
    done

    if kill -0 "$pid" 2>/dev/null; then
        fail "CCFS did not crash at requested failpoint"
    fi

    set +e

    wait "$pid" 2>/dev/null
    local status=$?

    set -e

    CCFS_PID=""

    detach_mount

    if [[ "$status" -ne 137 ]]; then
        fail "expected SIGKILL exit status 137, got $status"
    fi
}

trigger_mkdir() {
    local name="$1"

    set +e

    mkdir "$MOUNT_DIR/$name" 2>/dev/null

    set -e
}

sql_name_count() {
    local name="$1"

    sqlite3 "$DB_FILE" \
        "SELECT COUNT(*)
         FROM entries
         WHERE name='$name';"
}

applied_tx_count() {
    sqlite3 "$DB_FILE" \
        "SELECT COUNT(*)
         FROM applied_tx;"
}

clear_recovery_state() {
    mkdir -p volume

    : > volume/journal.log

    sqlite3 "$DB_FILE" \
        "DELETE FROM applied_tx;"
}

snapshot_volume() {
    stop_ccfs

    BACKUP_ROOT="$(
        mktemp -d /tmp/ccfs-checkpoint-backup.XXXXXX
    )"

    if [[ -d volume ]]; then
        cp -a volume "$BACKUP_ROOT/volume"
    else
        mkdir -p "$BACKUP_ROOT/volume"
    fi
}

restore_volume() {
    if [[ -z "${BACKUP_ROOT:-}" ]]; then
        return
    fi

    stop_ccfs

    rm -rf volume

    cp -a "$BACKUP_ROOT/volume" volume

    rm -rf "$BACKUP_ROOT"

    BACKUP_ROOT=""
}

run_integrity_check() {
    stop_ccfs

    ./target/debug/ccfs \
        --check-integrity \
        >"$INTEGRITY_LOG" 2>&1 ||
    {
        cat "$INTEGRITY_LOG"
        fail "integrity verification failed"
    }

    grep -q \
        "ALL CCFS BLOCKS PASSED INTEGRITY CHECK" \
        "$INTEGRITY_LOG" ||
        fail "integrity success marker missing"
}

cleanup() {
    set +e

    restore_volume

    rm -f "$NORMAL_LOG"
    rm -f "$CRASH_LOG"
    rm -f "$CHECKPOINT_LOG"
    rm -f "$STATUS_LOG"
    rm -f "$INTEGRITY_LOG"

    set -e
}

trap cleanup EXIT INT TERM

echo
echo "========================================"
echo " CCFS JOURNAL CHECKPOINT RECOVERY TEST"
echo "========================================"
echo

mkdir -p "$MOUNT_DIR"
mkdir -p volume/blocks

echo "[1/8] Snapshotting volume and building CCFS..."

snapshot_volume

cargo build --bin ccfs >/dev/null

./target/debug/ccfs \
    --recovery-status \
    >/dev/null

clear_recovery_state

pass "clean test recovery state prepared"

echo
echo "[2/8] Creating applied committed transaction..."

start_normal_ccfs

mkdir "$MOUNT_DIR/$APPLIED_DIR"

[[ -d "$MOUNT_DIR/$APPLIED_DIR" ]] ||
    fail "normal applied directory creation failed"

stop_ccfs

[[ "$(sql_name_count "$APPLIED_DIR")" == "1" ]] ||
    fail "applied transaction metadata missing"

[[ "$(applied_tx_count)" == "1" ]] ||
    fail "expected exactly one applied transaction"

pass "applied committed transaction created"

echo
echo "[3/8] Creating incomplete BEGIN transaction..."

start_crash_ccfs "after_begin"

trigger_mkdir "$INCOMPLETE_DIR"

wait_for_sigkill

[[ "$(sql_name_count "$INCOMPLETE_DIR")" == "0" ]] ||
    fail "incomplete transaction unexpectedly reached metadata"

pass "incomplete BEGIN transaction created"

echo
echo "[4/8] Creating committed-but-unapplied transaction..."

start_crash_ccfs "after_commit"

trigger_mkdir "$UNAPPLIED_DIR"

wait_for_sigkill

[[ "$(sql_name_count "$UNAPPLIED_DIR")" == "0" ]] ||
    fail "committed transaction applied before recovery"

pass "committed unapplied transaction created"

echo
echo "[5/8] Running journal checkpoint..."

./target/debug/ccfs \
    --checkpoint \
    >"$CHECKPOINT_LOG" 2>&1 ||
{
    cat "$CHECKPOINT_LOG"
    fail "checkpoint command failed"
}

cat "$CHECKPOINT_LOG"

grep -q \
    "Original transactions:       3" \
    "$CHECKPOINT_LOG" ||
    fail "checkpoint did not observe exactly three transactions"

grep -q \
    "Retained unapplied committed: 1" \
    "$CHECKPOINT_LOG" ||
    fail "checkpoint did not retain committed unapplied transaction"

grep -q \
    "Removed applied:             1" \
    "$CHECKPOINT_LOG" ||
    fail "checkpoint did not remove applied transaction"

grep -q \
    "Removed incomplete:          1" \
    "$CHECKPOINT_LOG" ||
    fail "checkpoint did not remove incomplete transaction"

[[ "$(applied_tx_count)" == "0" ]] ||
    fail "stale applied_tx rows were not cleared"

./target/debug/ccfs \
    --recovery-status \
    >"$STATUS_LOG" 2>&1 ||
    fail "unable to inspect post-checkpoint recovery state"

grep -q \
    "Total transactions:          1" \
    "$STATUS_LOG" ||
    fail "checkpoint journal should contain one transaction"

grep -q \
    "Committed transactions:      1" \
    "$STATUS_LOG" ||
    fail "retained transaction is not committed"

grep -q \
    "Incomplete transactions:     0" \
    "$STATUS_LOG" ||
    fail "incomplete transaction survived checkpoint"

pass "checkpoint retained only committed unapplied transaction"

echo
echo "[6/8] Restarting and replaying retained transaction..."

start_normal_ccfs

[[ -d "$MOUNT_DIR/$APPLIED_DIR" ]] ||
    fail "previously applied directory disappeared"

[[ ! -e "$MOUNT_DIR/$INCOMPLETE_DIR" ]] ||
    fail "discarded incomplete directory unexpectedly appeared"

[[ -d "$MOUNT_DIR/$UNAPPLIED_DIR" ]] ||
    fail "retained committed transaction was not replayed"

grep -q \
    "replayed: 1" \
    "$NORMAL_LOG" ||
    fail "retained transaction was not reported as replayed"

stop_ccfs

[[ "$(sql_name_count "$APPLIED_DIR")" == "1" ]] ||
    fail "applied directory metadata missing after recovery"

[[ "$(sql_name_count "$INCOMPLETE_DIR")" == "0" ]] ||
    fail "incomplete directory metadata appeared after recovery"

[[ "$(sql_name_count "$UNAPPLIED_DIR")" == "1" ]] ||
    fail "replayed directory metadata missing"

[[ "$(applied_tx_count)" == "1" ]] ||
    fail "replayed transaction was not marked applied"

pass "retained committed transaction recovered correctly"

echo
echo "[7/8] Running second checkpoint..."

./target/debug/ccfs \
    --checkpoint \
    >"$CHECKPOINT_LOG" 2>&1 ||
{
    cat "$CHECKPOINT_LOG"
    fail "second checkpoint failed"
}

cat "$CHECKPOINT_LOG"

grep -q \
    "Original transactions:       1" \
    "$CHECKPOINT_LOG" ||
    fail "second checkpoint expected one transaction"

grep -q \
    "Retained unapplied committed: 0" \
    "$CHECKPOINT_LOG" ||
    fail "second checkpoint retained already-applied transaction"

grep -q \
    "Removed applied:             1" \
    "$CHECKPOINT_LOG" ||
    fail "second checkpoint did not remove applied transaction"

[[ "$(applied_tx_count)" == "0" ]] ||
    fail "applied_tx not empty after second checkpoint"

./target/debug/ccfs \
    --recovery-status \
    >"$STATUS_LOG" 2>&1 ||
    fail "unable to inspect final recovery state"

grep -q \
    "Total transactions:          0" \
    "$STATUS_LOG" ||
    fail "journal not empty after second checkpoint"

run_integrity_check

pass "journal compacted to empty and filesystem remained healthy"

echo
echo "[8/8] Restoring original pre-test volume..."

restore_volume

trap - EXIT INT TERM

rm -f "$NORMAL_LOG"
rm -f "$CRASH_LOG"
rm -f "$CHECKPOINT_LOG"
rm -f "$STATUS_LOG"
rm -f "$INTEGRITY_LOG"

echo
echo "========================================"
echo " ALL CCFS CHECKPOINT TESTS PASSED"
echo "========================================"
echo
