#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

MOUNT_DIR="mount"

RUN_ID="$(date +%s)"

SNAPSHOT_NAME="e2e-snapshot-$RUN_ID"
TEST_FILE="e2e-file-$RUN_ID.txt"

OLD_CONTENT="CCFS-E2E-OLD-$RUN_ID"
NEW_CONTENT="CCFS-E2E-NEW-$RUN_ID"

NORMAL_LOG="/tmp/ccfs-e2e-normal.log"
CRASH_LOG="/tmp/ccfs-e2e-crash.log"
RECOVERY_LOG="/tmp/ccfs-e2e-recovery.log"
VERIFY_LOG="/tmp/ccfs-e2e-snapshot-verify.log"
INTEGRITY_LOG="/tmp/ccfs-e2e-integrity.log"
CHECKPOINT_LOG="/tmp/ccfs-e2e-checkpoint.log"

CCFS_PID=""
BACKUP_ROOT=""
FILE_INO=""

fail() {
    echo
    echo "TEST FAILED: $1"
    echo

    echo "Normal log:"
    echo "----------------------------------------"
    cat "$NORMAL_LOG" 2>/dev/null || true

    echo
    echo "Crash log:"
    echo "----------------------------------------"
    cat "$CRASH_LOG" 2>/dev/null || true

    echo
    echo "Recovery log:"
    echo "----------------------------------------"
    cat "$RECOVERY_LOG" 2>/dev/null || true

    echo
    echo "Snapshot verify log:"
    echo "----------------------------------------"
    cat "$VERIFY_LOG" 2>/dev/null || true

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

start_recovery_ccfs() {
    stop_ccfs

    : > "$RECOVERY_LOG"

    ./target/debug/ccfs >"$RECOVERY_LOG" 2>&1 &
    CCFS_PID=$!

    wait_for_mount "$CCFS_PID" ||
        fail "recovery CCFS failed to mount"
}

start_crash_ccfs() {
    stop_ccfs

    : > "$CRASH_LOG"

    env \
        CCFS_KILL9_OPERATION="WRITE" \
        CCFS_KILL9_POINT="after_commit" \
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
        fail "CCFS did not crash at WRITE after_commit"
    fi

    set +e

    wait "$pid" 2>/dev/null
    local status=$?

    set -e

    CCFS_PID=""

    detach_mount

    if [[ "$status" -ne 137 ]]; then
        fail "expected SIGKILL status 137, got $status"
    fi
}

snapshot_volume() {
    stop_ccfs

    BACKUP_ROOT="$(
        mktemp -d /tmp/ccfs-final-e2e-backup.XXXXXX
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
    rm -f "$CRASH_LOG"
    rm -f "$RECOVERY_LOG"
    rm -f "$VERIFY_LOG"
    rm -f "$INTEGRITY_LOG"
    rm -f "$CHECKPOINT_LOG"

    set -e
}

assert_live_text() {
    local expected="$1"

    [[ -f "$MOUNT_DIR/$TEST_FILE" ]] ||
        fail "live E2E file missing"

    local actual

    actual="$(cat "$MOUNT_DIR/$TEST_FILE")"

    [[ "$actual" == "$expected" ]] ||
        fail "live E2E content mismatch"
}

assert_snapshot_old_text() {
    local actual

    actual="$(
        ./target/debug/ccfs \
            --snapshot-read \
            "$SNAPSHOT_NAME" \
            "$TEST_FILE"
    )"

    [[ "$actual" == "$OLD_CONTENT" ]] ||
        fail "snapshot old version changed unexpectedly"
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

trap cleanup EXIT INT TERM

echo
echo "========================================"
echo " CCFS FINAL END-TO-END ACCEPTANCE TEST"
echo "========================================"
echo

fusermount3 -u "$MOUNT_DIR" 2>/dev/null || true
fusermount3 -uz "$MOUNT_DIR" 2>/dev/null || true
sleep 0.1

mkdir -p "$MOUNT_DIR"
mkdir -p volume/blocks

echo "[1/9] Preserving original volume and building CCFS..."

snapshot_volume

cargo build --bin ccfs >/dev/null

pass "original volume preserved and CCFS built"

echo
echo "[2/9] Creating durable initial file..."

start_normal_ccfs

python3 - \
    "$MOUNT_DIR/$TEST_FILE" \
    "$OLD_CONTENT" <<'PY'
import os
import sys

path = sys.argv[1]
payload = sys.argv[2].encode()

fd = os.open(
    path,
    os.O_CREAT | os.O_WRONLY | os.O_TRUNC,
    0o644,
)

try:
    written = os.write(fd, payload)

    if written != len(payload):
        raise RuntimeError("short initial write")

    os.fsync(fd)

finally:
    os.close(fd)
PY

assert_live_text "$OLD_CONTENT"

stop_ccfs

FILE_INO="$(
    sqlite3 volume/metadata.db \
        "SELECT ino
         FROM entries
         WHERE name='$TEST_FILE'
         LIMIT 1;"
)"

[[ -n "$FILE_INO" ]] ||
    fail "unable to find E2E inode in metadata database"

[[ "$(cat "volume/blocks/$FILE_INO.bin")" == "$OLD_CONTENT" ]] ||
    fail "initial backing block content incorrect"

pass "initial file created and persisted"

echo
echo "[3/9] Creating snapshot of old state..."

./target/debug/ccfs \
    --snapshot-create \
    "$SNAPSHOT_NAME" \
    >/dev/null

./target/debug/ccfs \
    --snapshot-verify \
    "$SNAPSHOT_NAME" \
    >"$VERIFY_LOG" 2>&1 ||
{
    cat "$VERIFY_LOG"
    fail "E2E snapshot verification failed"
}

grep -q \
    "Snapshot verified: $SNAPSHOT_NAME" \
    "$VERIFY_LOG" ||
    fail "E2E snapshot verify marker missing"

assert_snapshot_old_text

pass "snapshot captured old file state"

echo
echo "[4/9] Compacting old journal history before crash test..."

./target/debug/ccfs \
    --checkpoint \
    >"$CHECKPOINT_LOG" 2>&1 ||
{
    cat "$CHECKPOINT_LOG"
    fail "pre-crash checkpoint failed"
}

RECOVERY_STATUS="$(
    ./target/debug/ccfs --recovery-status
)"

grep -q "Total transactions:          0" <<<"$RECOVERY_STATUS" ||
    fail "journal was not empty before crash workload"

pass "isolated recovery state prepared"

echo
echo "[5/9] Modifying file and crashing after WRITE COMMIT..."

start_crash_ccfs

set +e

python3 - \
    "$MOUNT_DIR/$TEST_FILE" \
    "$NEW_CONTENT" <<'PY'
import os
import sys

path = sys.argv[1]
payload = sys.argv[2].encode()

fd = os.open(
    path,
    os.O_WRONLY,
)

try:
    os.write(
        fd,
        payload,
    )

finally:
    try:
        os.close(fd)
    except OSError:
        pass
PY

set -e

wait_for_sigkill

grep -q \
    "CCFS TEST FAILPOINT: SIGKILL operation=WRITE point=after_commit" \
    "$CRASH_LOG" ||
    fail "WRITE SIGKILL failpoint was not observed"

# Transaction is committed in the journal, but apply happens
# only during the next recovery.
[[ "$(cat "volume/blocks/$FILE_INO.bin")" == "$OLD_CONTENT" ]] ||
    fail "committed WRITE applied before recovery unexpectedly"

assert_snapshot_old_text

pass "crash occurred after COMMIT while old durable state remained intact"

echo
echo "[6/9] Restarting and replaying committed WRITE..."

start_recovery_ccfs

assert_live_text "$NEW_CONTENT"

grep -q \
    "replayed: 1" \
    "$RECOVERY_LOG" ||
    fail "committed WRITE was not reported as replayed"

[[ "$(cat "volume/blocks/$FILE_INO.bin")" == "$NEW_CONTENT" ]] ||
    fail "recovered backing block does not contain new content"

stop_ccfs

assert_snapshot_old_text

./target/debug/ccfs \
    --snapshot-verify \
    "$SNAPSHOT_NAME" \
    >/dev/null ||
    fail "snapshot became invalid after crash recovery"

pass "committed modification recovered while snapshot preserved old state"

echo
echo "[7/9] Verifying idempotent second restart..."

start_recovery_ccfs

assert_live_text "$NEW_CONTENT"

grep -q \
    "replayed: 0" \
    "$RECOVERY_LOG" ||
    fail "already-applied E2E transaction replayed again"

stop_ccfs

assert_snapshot_old_text

pass "second restart remained idempotent"

echo
echo "[8/9] Final integrity and checkpoint verification..."

run_integrity_check

./target/debug/ccfs \
    --checkpoint \
    >"$CHECKPOINT_LOG" 2>&1 ||
{
    cat "$CHECKPOINT_LOG"
    fail "final checkpoint failed"
}

RECOVERY_STATUS="$(
    ./target/debug/ccfs --recovery-status
)"

grep -q "Total transactions:          0" <<<"$RECOVERY_STATUS" ||
    fail "final journal was not compacted to empty"

./target/debug/ccfs \
    --snapshot-verify \
    "$SNAPSHOT_NAME" \
    >/dev/null ||
    fail "final snapshot verification failed"

pass "final live state, journal and snapshot all healthy"

echo
echo "[9/9] Restoring original pre-test volume..."

restore_volume

trap - EXIT INT TERM

rm -f "$NORMAL_LOG"
rm -f "$CRASH_LOG"
rm -f "$RECOVERY_LOG"
rm -f "$VERIFY_LOG"
rm -f "$INTEGRITY_LOG"
rm -f "$CHECKPOINT_LOG"

echo
echo "========================================"
echo " ALL CCFS FINAL E2E TESTS PASSED"
echo "========================================"
echo
