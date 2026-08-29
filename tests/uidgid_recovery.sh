#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

MOUNT_DIR="mount"
DB_FILE="volume/metadata.db"

CRASH_LOG="/tmp/ccfs-uidgid-crash.log"
RECOVERY_LOG="/tmp/ccfs-uidgid-recovery.log"
INTEGRITY_LOG="/tmp/ccfs-uidgid-integrity.log"

RUN_ID="$(date +%s)"

NORMAL_FILE="uidgid-normal-$RUN_ID.txt"
BEGIN_FILE="uidgid-begin-$RUN_ID.txt"
COMMIT_FILE="uidgid-commit-$RUN_ID.txt"

BASE_UID=1000
BASE_GID=1000

TARGET_UID=1000
TARGET_GID=4

CCFS_PID=""
BACKUP_ROOT=""

fail() {
    echo
    echo "TEST FAILED: $1"
    echo

    echo "Crash log:"
    echo "----------------------------------------"
    cat "$CRASH_LOG" 2>/dev/null || true

    echo
    echo "Recovery log:"
    echo "----------------------------------------"
    cat "$RECOVERY_LOG" 2>/dev/null || true

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

    : > "$RECOVERY_LOG"

    ./target/debug/ccfs >"$RECOVERY_LOG" 2>&1 &
    CCFS_PID=$!

    wait_for_mount "$CCFS_PID" ||
        fail "normal CCFS failed to mount"
}

start_crash_ccfs() {
    local point="$1"

    stop_ccfs

    : > "$CRASH_LOG"

    env \
        CCFS_KILL9_OPERATION="SETATTR" \
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

clear_recovery_state() {
    : > volume/journal.log

    sqlite3 "$DB_FILE" \
        "DELETE FROM applied_tx;"
}

sql_owner() {
    local name="$1"

    sqlite3 "$DB_FILE" \
        "SELECT uid || ':' || gid
         FROM entries
         WHERE name='$name'
         LIMIT 1;"
}

assert_owner() {
    local path="$1"
    local expected="$2"

    local actual

    actual="$(stat -c '%u:%g' "$path")"

    [[ "$actual" == "$expected" ]] ||
        fail "owner mismatch for $path: expected $expected, got $actual"
}

trigger_chown() {
    local path="$1"

    set +e

    chown \
        "$TARGET_UID:$TARGET_GID" \
        "$path"

    set -e
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

snapshot_volume() {
    stop_ccfs

    BACKUP_ROOT="$(
        mktemp -d /tmp/ccfs-uidgid-backup.XXXXXX
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

    cp -a \
        "$BACKUP_ROOT/volume" \
        volume

    rm -rf "$BACKUP_ROOT"

    BACKUP_ROOT=""
}

cleanup() {
    set +e

    restore_volume

    rm -f "$CRASH_LOG"
    rm -f "$RECOVERY_LOG"
    rm -f "$INTEGRITY_LOG"

    set -e
}

trap cleanup EXIT INT TERM

echo
echo "========================================"
echo " CCFS UID/GID SETATTR RECOVERY TEST"
echo "========================================"
echo

mkdir -p "$MOUNT_DIR"
mkdir -p volume/blocks

if ! id -G | tr ' ' '\n' | grep -qx "$TARGET_GID"; then
    fail "current user is not a member of target gid $TARGET_GID"
fi

echo "[1/7] Snapshotting volume and building..."

snapshot_volume

cargo build --bin ccfs >/dev/null

./target/debug/ccfs \
    --recovery-status \
    >/dev/null

pass "CCFS built and ownership test prerequisites verified"

echo
echo "[2/7] Testing normal uid/gid persistence..."

clear_recovery_state

start_normal_ccfs

printf 'uidgid-normal-data' \
    > "$MOUNT_DIR/$NORMAL_FILE"

assert_owner \
    "$MOUNT_DIR/$NORMAL_FILE" \
    "$BASE_UID:$BASE_GID"

chown \
    "$TARGET_UID:$TARGET_GID" \
    "$MOUNT_DIR/$NORMAL_FILE"

assert_owner \
    "$MOUNT_DIR/$NORMAL_FILE" \
    "$TARGET_UID:$TARGET_GID"

stop_ccfs

[[ "$(sql_owner "$NORMAL_FILE")" == "$TARGET_UID:$TARGET_GID" ]] ||
    fail "SQLite did not persist normal uid/gid change"

start_normal_ccfs

assert_owner \
    "$MOUNT_DIR/$NORMAL_FILE" \
    "$TARGET_UID:$TARGET_GID"

pass "uid/gid persisted across normal restart"

echo
echo "[3/7] SETATTR ownership crash after BEGIN..."

stop_ccfs
clear_recovery_state

start_normal_ccfs

printf 'uidgid-begin-data' \
    > "$MOUNT_DIR/$BEGIN_FILE"

assert_owner \
    "$MOUNT_DIR/$BEGIN_FILE" \
    "$BASE_UID:$BASE_GID"

stop_ccfs
clear_recovery_state

start_crash_ccfs "after_begin"

trigger_chown \
    "$MOUNT_DIR/$BEGIN_FILE"

wait_for_sigkill

[[ "$(sql_owner "$BEGIN_FILE")" == "$BASE_UID:$BASE_GID" ]] ||
    fail "after-BEGIN ownership reached SQLite unexpectedly"

start_normal_ccfs

assert_owner \
    "$MOUNT_DIR/$BEGIN_FILE" \
    "$BASE_UID:$BASE_GID"

grep -q \
    "incomplete ignored: 1" \
    "$RECOVERY_LOG" ||
    fail "after-BEGIN SETATTR was not classified incomplete"

pass "SETATTR killed after BEGIN preserved old ownership"

echo
echo "[4/7] SETATTR ownership crash after COMMIT..."

stop_ccfs
clear_recovery_state

start_normal_ccfs

printf 'uidgid-commit-data' \
    > "$MOUNT_DIR/$COMMIT_FILE"

assert_owner \
    "$MOUNT_DIR/$COMMIT_FILE" \
    "$BASE_UID:$BASE_GID"

stop_ccfs
clear_recovery_state

start_crash_ccfs "after_commit"

trigger_chown \
    "$MOUNT_DIR/$COMMIT_FILE"

wait_for_sigkill

[[ "$(sql_owner "$COMMIT_FILE")" == "$BASE_UID:$BASE_GID" ]] ||
    fail "after-COMMIT ownership applied before recovery"

echo
echo "[5/7] Recovering committed uid/gid SETATTR..."

start_normal_ccfs

grep -q \
    "replayed: 1" \
    "$RECOVERY_LOG" ||
    fail "committed ownership SETATTR did not replay"

assert_owner \
    "$MOUNT_DIR/$COMMIT_FILE" \
    "$TARGET_UID:$TARGET_GID"

[[ "$(sql_owner "$COMMIT_FILE")" == "$TARGET_UID:$TARGET_GID" ]] ||
    fail "recovered uid/gid not persisted in SQLite"

pass "committed uid/gid SETATTR replayed correctly"

echo
echo "[6/7] Verifying idempotent second restart..."

stop_ccfs
start_normal_ccfs

grep -q \
    "replayed: 0" \
    "$RECOVERY_LOG" ||
    fail "already-applied ownership transaction replayed again"

grep -q \
    "already applied: 1" \
    "$RECOVERY_LOG" ||
    fail "ownership transaction not recognized as already applied"

assert_owner \
    "$MOUNT_DIR/$COMMIT_FILE" \
    "$TARGET_UID:$TARGET_GID"

run_integrity_check

pass "ownership recovery remained idempotent and healthy"

echo
echo "[7/7] Restoring original pre-test volume..."

restore_volume

trap - EXIT INT TERM

rm -f "$CRASH_LOG"
rm -f "$RECOVERY_LOG"
rm -f "$INTEGRITY_LOG"

echo
echo "========================================"
echo " ALL CCFS UID/GID RECOVERY TESTS PASSED"
echo "========================================"
echo
