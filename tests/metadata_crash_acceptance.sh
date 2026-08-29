#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

MOUNT_DIR="mount"

RUN_ID="$(date +%s)"

TEST_FILE="metadata-crash-$RUN_ID.txt"

OLD_DATA="CCFS-METADATA-OLD-$RUN_ID"
NEW_DATA="CCFS-METADATA-NEW-$RUN_ID"

NORMAL_LOG="/tmp/ccfs-metadata-crash-normal.log"
CRASH_LOG="/tmp/ccfs-metadata-crash.log"
INTEGRITY_LOG="/tmp/ccfs-metadata-crash-integrity.log"
CHECKPOINT_LOG="/tmp/ccfs-metadata-crash-checkpoint.log"

CCFS_PID=""
BACKUP_ROOT=""

fail() {
    echo
    echo "TEST FAILED: $1"
    echo

    echo "Normal log:"
    echo "----------------------------------------"
    cat "$NORMAL_LOG" 2>/dev/null || true

    echo
    echo "Metadata crash log:"
    echo "----------------------------------------"
    cat "$CRASH_LOG" 2>/dev/null || true

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
}

snapshot_volume() {
    stop_ccfs

    BACKUP_ROOT="$(
        mktemp -d /tmp/ccfs-metadata-crash-backup.XXXXXX
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

checkpoint_clean() {
    stop_ccfs

    ./target/debug/ccfs \
        --checkpoint \
        >"$CHECKPOINT_LOG" 2>&1 ||
    {
        cat "$CHECKPOINT_LOG"
        fail "checkpoint failed"
    }

    local status

    status="$(
        ./target/debug/ccfs --recovery-status
    )"

    grep -q \
        "Total transactions:          0" \
        <<<"$status" ||
        fail "journal not empty after checkpoint"
}

assert_file() {
    local expected="$1"

    [[ -f "$MOUNT_DIR/$TEST_FILE" ]] ||
        fail "test file missing"

    local actual

    actual="$(cat "$MOUNT_DIR/$TEST_FILE")"

    [[ "$actual" == "$expected" ]] ||
        fail "test file content mismatch"
}

trap cleanup EXIT INT TERM

echo
echo "========================================"
echo " CCFS METADATA-CRASH ACCEPTANCE TEST"
echo "========================================"
echo

fusermount3 -u "$MOUNT_DIR" 2>/dev/null || true
fusermount3 -uz "$MOUNT_DIR" 2>/dev/null || true
sleep 0.1

mkdir -p "$MOUNT_DIR"

echo "[1/7] Preserving original volume and building..."

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

fd = os.open(sys.argv[1], os.O_RDONLY)

try:
    os.fsync(fd)
finally:
    os.close(fd)
PY

assert_file "$OLD_DATA"

stop_ccfs

pass "durable baseline metadata and file created"

echo
echo "[2/7] Clearing previous journal history..."

checkpoint_clean
run_integrity

pass "isolated recovery state prepared"

echo
echo "[3/7] Crashing inside SQLite metadata transaction..."

detach_mount
: > "$CRASH_LOG"

set +e

env \
    CCFS_DB_KILL9_POINT=after_metadata_before_applied_tx \
    ./target/debug/ccfs \
    >"$CRASH_LOG" 2>&1 &

CCFS_PID=$!

if ! wait_for_mount "$CCFS_PID"; then
    set -e
    fail "metadata crash CCFS failed to mount"
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
    try:
        os.write(fd, payload)
    except OSError:
        # Expected when the FUSE process is SIGKILLed.
        pass
finally:
    try:
        os.close(fd)
    except OSError:
        pass
PY

wait "$CCFS_PID"
CRASH_STATUS=$?

set -e

CCFS_PID=""

detach_mount

[[ "$CRASH_STATUS" -eq 137 ]] ||
    fail "expected metadata SIGKILL status 137, got $CRASH_STATUS"

grep -q \
    "CCFS metadata SIGKILL failpoint triggered: after_metadata_before_applied_tx" \
    "$CRASH_LOG" ||
    fail "metadata SIGKILL marker missing"

pass "SIGKILL occurred inside metadata transaction"

echo
echo "[4/7] Verifying uncommitted applied_tx record rolled back..."

APPLIED_COUNT="$(
    sqlite3 volume/metadata.db \
        "SELECT COUNT(*) FROM applied_tx;"
)"

[[ "$APPLIED_COUNT" -eq 0 ]] ||
    fail "uncommitted applied_tx row survived SQLite crash"

RECOVERY_STATUS="$(
    ./target/debug/ccfs --recovery-status
)"

grep -Eq \
    "Committed transactions:[[:space:]]*1" \
    <<<"$RECOVERY_STATUS" ||
    fail "committed journal transaction not preserved after metadata crash"

pass "SQLite rollback preserved committed transaction for recovery"

echo
echo "[5/7] Restarting and replaying committed operation..."

start_ccfs

assert_file "$NEW_DATA"

grep -q \
    "replayed: 1" \
    "$NORMAL_LOG" ||
    fail "metadata-crash recovery did not replay one transaction"

pass "journal replay completed metadata update successfully"

echo
echo "[6/7] Verifying idempotent second restart..."

stop_ccfs
start_ccfs

assert_file "$NEW_DATA"

grep -q \
    "replayed: 0" \
    "$NORMAL_LOG" ||
    fail "second restart unexpectedly replayed transaction"

pass "second restart remained idempotent"

echo
echo "[7/7] Final integrity and checkpoint verification..."

stop_ccfs

run_integrity
checkpoint_clean
run_integrity

restore_volume

trap - EXIT INT TERM

rm -f "$NORMAL_LOG"
rm -f "$CRASH_LOG"
rm -f "$INTEGRITY_LOG"
rm -f "$CHECKPOINT_LOG"

echo
echo "========================================"
echo " ALL CCFS METADATA-CRASH TESTS PASSED"
echo "========================================"
echo
