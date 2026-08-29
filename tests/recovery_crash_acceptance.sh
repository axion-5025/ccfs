#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

MOUNT_DIR="mount"

RUN_ID="$(date +%s)"

TEST_FILE="recovery-crash-$RUN_ID.txt"

OLD_DATA="CCFS-RECOVERY-OLD-$RUN_ID"
NEW_DATA="CCFS-RECOVERY-NEW-$RUN_ID"

NORMAL_LOG="/tmp/ccfs-recovery-crash-normal.log"
RUNTIME_CRASH_LOG="/tmp/ccfs-recovery-runtime-crash.log"
RECOVERY_CRASH1_LOG="/tmp/ccfs-recovery-crash1.log"
RECOVERY_CRASH2_LOG="/tmp/ccfs-recovery-crash2.log"
INTEGRITY_LOG="/tmp/ccfs-recovery-crash-integrity.log"
CHECKPOINT_LOG="/tmp/ccfs-recovery-crash-checkpoint.log"

CCFS_PID=""
BACKUP_ROOT=""
TEST_INO=""

fail() {
    echo
    echo "TEST FAILED: $1"
    echo

    echo "Normal log:"
    echo "----------------------------------------"
    cat "$NORMAL_LOG" 2>/dev/null || true

    echo
    echo "Runtime crash log:"
    echo "----------------------------------------"
    cat "$RUNTIME_CRASH_LOG" 2>/dev/null || true

    echo
    echo "Recovery crash #1 log:"
    echo "----------------------------------------"
    cat "$RECOVERY_CRASH1_LOG" 2>/dev/null || true

    echo
    echo "Recovery crash #2 log:"
    echo "----------------------------------------"
    cat "$RECOVERY_CRASH2_LOG" 2>/dev/null || true

    echo
    echo "Integrity log:"
    echo "----------------------------------------"
    cat "$INTEGRITY_LOG" 2>/dev/null || true

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

    fusermount3 -u "$MOUNT_DIR" 2>/dev/null || true
    fusermount3 -uz "$MOUNT_DIR" 2>/dev/null || true

    sleep 0.1

    mkdir -p "$MOUNT_DIR" 2>/dev/null || true

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

    detach_mount
}

wait_for_mount() {
    local pid="$1"

    for _ in $(seq 1 120); do
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

start_ccfs() {
    stop_ccfs

    : > "$NORMAL_LOG"

    ./target/debug/ccfs \
        >"$NORMAL_LOG" 2>&1 &

    CCFS_PID=$!

    wait_for_mount "$CCFS_PID" ||
        fail "CCFS failed to mount"

    return 0
}

snapshot_volume() {
    stop_ccfs

    BACKUP_ROOT="$(
        mktemp -d /tmp/ccfs-recovery-crash-backup.XXXXXX
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

cleanup() {
    set +e

    restore_volume

    rm -f "$NORMAL_LOG"
    rm -f "$RUNTIME_CRASH_LOG"
    rm -f "$RECOVERY_CRASH1_LOG"
    rm -f "$RECOVERY_CRASH2_LOG"
    rm -f "$INTEGRITY_LOG"
    rm -f "$CHECKPOINT_LOG"

    set -e
}

run_integrity() {
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
        fail "integrity PASS marker missing"
}

assert_mounted_file() {
    local expected="$1"

    [[ -f "$MOUNT_DIR/$TEST_FILE" ]] ||
        fail "expected file missing from mounted filesystem"

    local actual

    actual="$(cat "$MOUNT_DIR/$TEST_FILE")"

    [[ "$actual" == "$expected" ]] ||
        fail "mounted file content mismatch"
}

assert_backing_file() {
    local expected="$1"

    [[ -n "$TEST_INO" ]] ||
        fail "test inode is not known"

    local block="volume/blocks/$TEST_INO.bin"

    [[ -f "$block" ]] ||
        fail "backing block is missing"

    local actual

    actual="$(cat "$block")"

    [[ "$actual" == "$expected" ]] ||
        fail "backing block content mismatch"
}

run_recovery_crash() {
    local output_log="$1"

    detach_mount
    : > "$output_log"

    set +e

    env \
        CCFS_RECOVERY_KILL9_POINT=before_replay \
        ./target/debug/ccfs \
        >"$output_log" 2>&1 &

    local pid=$!

    wait "$pid"
    local status=$?

    set -e

    detach_mount

    [[ "$status" -eq 137 ]] ||
        fail "recovery failpoint expected status 137, got $status"

    grep -q \
        "CCFS recovery SIGKILL failpoint triggered: before_replay" \
        "$output_log" ||
        fail "recovery SIGKILL marker missing"
}

trap cleanup EXIT INT TERM

echo
echo "========================================"
echo " CCFS RECOVERY-CRASH ACCEPTANCE TESTS"
echo "========================================"
echo

fusermount3 -u "$MOUNT_DIR" 2>/dev/null || true
fusermount3 -uz "$MOUNT_DIR" 2>/dev/null || true
sleep 0.1

mkdir -p "$MOUNT_DIR"

echo "[1/9] Preserving original volume and building..."

snapshot_volume

cargo build --bin ccfs >/dev/null

rm -rf volume
mkdir -p volume/blocks

start_ccfs

printf '%s' "$OLD_DATA" \
    > "$MOUNT_DIR/$TEST_FILE"

python3 - "$MOUNT_DIR/$TEST_FILE" <<'PY'
import os
import sys

path = sys.argv[1]

fd = os.open(path, os.O_RDONLY)

try:
    os.fsync(fd)
finally:
    os.close(fd)
PY

assert_mounted_file "$OLD_DATA"

stop_ccfs

TEST_INO="$(
    sqlite3 volume/metadata.db \
        "SELECT ino
         FROM entries
         WHERE name='$TEST_FILE'
         LIMIT 1;"
)"

[[ -n "$TEST_INO" ]] ||
    fail "unable to resolve test inode"

assert_backing_file "$OLD_DATA"

pass "durable old state created"

echo
echo "[2/9] Clearing previous journal/recovery history..."

./target/debug/ccfs \
    --checkpoint \
    >"$CHECKPOINT_LOG" 2>&1 ||
{
    cat "$CHECKPOINT_LOG"
    fail "pre-test checkpoint failed"
}

RECOVERY_STATUS="$(
    ./target/debug/ccfs \
        --recovery-status
)"

grep -q \
    "Total transactions:          0" \
    <<<"$RECOVERY_STATUS" ||
    fail "journal was not empty before crash workload"

pass "isolated recovery state prepared"

echo
echo "[3/9] Creating committed-but-unrecovered WRITE..."

detach_mount
: > "$RUNTIME_CRASH_LOG"

set +e

env \
    CCFS_KILL9_OPERATION=WRITE \
    CCFS_KILL9_POINT=after_commit \
    ./target/debug/ccfs \
    >"$RUNTIME_CRASH_LOG" 2>&1 &

CCFS_PID=$!

if ! wait_for_mount "$CCFS_PID"; then
    set -e
    fail "runtime crash test CCFS failed to mount"
fi

python3 - \
    "$MOUNT_DIR/$TEST_FILE" \
    "$NEW_DATA" <<'PY'
import os
import sys

path = sys.argv[1]
payload = sys.argv[2].encode()

fd = os.open(path, os.O_WRONLY)

try:
    os.write(fd, payload)
finally:
    os.close(fd)
PY

wait "$CCFS_PID"
RUNTIME_STATUS=$?

set -e

CCFS_PID=""

detach_mount

[[ "$RUNTIME_STATUS" -eq 137 ]] ||
    fail "runtime WRITE crash expected status 137, got $RUNTIME_STATUS"

grep -q \
    "CCFS TEST FAILPOINT: SIGKILL operation=WRITE point=after_commit" \
    "$RUNTIME_CRASH_LOG" ||
    fail "runtime WRITE after_commit marker missing"

assert_backing_file "$OLD_DATA"

pass "committed WRITE exists while old durable block remains"

echo
echo "[4/9] Crashing during first recovery replay..."

run_recovery_crash "$RECOVERY_CRASH1_LOG"

assert_backing_file "$OLD_DATA"

pass "first recovery crash preserved old durable state and transaction remained pending"

echo
echo "[5/9] Crashing again during repeated recovery..."

run_recovery_crash "$RECOVERY_CRASH2_LOG"

assert_backing_file "$OLD_DATA"

pass "second recovery crash again preserved old state and pending transaction"

echo
echo "[6/9] Restarting normally to finish recovery..."

start_ccfs

assert_mounted_file "$NEW_DATA"

grep -q \
    "replayed: 1" \
    "$NORMAL_LOG" ||
    fail "normal recovery did not report one replayed transaction"

pass "normal restart completed recovery successfully"

echo
echo "[7/9] Verifying idempotent second normal restart..."

stop_ccfs
start_ccfs

assert_mounted_file "$NEW_DATA"

grep -q \
    "replayed: 0" \
    "$NORMAL_LOG" ||
    fail "second normal restart unexpectedly replayed transaction"

pass "second normal restart remained idempotent"

echo
echo "[8/9] Verifying integrity after repeated recovery crashes..."

stop_ccfs

run_integrity

pass "filesystem integrity healthy after repeated recovery crashes"

echo
echo "[9/9] Checkpointing and verifying clean recovery state..."

./target/debug/ccfs \
    --checkpoint \
    >"$CHECKPOINT_LOG" 2>&1 ||
{
    cat "$CHECKPOINT_LOG"
    fail "final checkpoint failed"
}

RECOVERY_STATUS="$(
    ./target/debug/ccfs \
        --recovery-status
)"

grep -q \
    "Total transactions:          0" \
    <<<"$RECOVERY_STATUS" ||
    fail "journal not empty after final checkpoint"

run_integrity

restore_volume

trap - EXIT INT TERM

rm -f "$NORMAL_LOG"
rm -f "$RUNTIME_CRASH_LOG"
rm -f "$RECOVERY_CRASH1_LOG"
rm -f "$RECOVERY_CRASH2_LOG"
rm -f "$INTEGRITY_LOG"
rm -f "$CHECKPOINT_LOG"

echo
echo "========================================"
echo " ALL CCFS RECOVERY-CRASH TESTS PASSED"
echo "========================================"
echo
