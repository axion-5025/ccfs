#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

MOUNT_DIR="mount"

RUN_ID="$(date +%s)"

TEST_FILE="fault-file-$RUN_ID.txt"
CRASH_FILE="fault-crash-$RUN_ID.txt"

TEST_DATA="CCFS-FAULT-DATA-$RUN_ID"
CRASH_DATA="CCFS-CRASH-DURABLE-$RUN_ID"

NORMAL_LOG="/tmp/ccfs-fault-normal.log"
ERROR_LOG="/tmp/ccfs-fault-error.log"
INTEGRITY_LOG="/tmp/ccfs-fault-integrity.log"
JOURNAL_LOG="/tmp/ccfs-fault-journal.log"

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
    echo "Error log:"
    echo "----------------------------------------"
    cat "$ERROR_LOG" 2>/dev/null || true

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

start_ccfs() {
    stop_ccfs

    : > "$NORMAL_LOG"

    ./target/debug/ccfs >"$NORMAL_LOG" 2>&1 &
    CCFS_PID=$!

    wait_for_mount "$CCFS_PID" ||
        fail "CCFS failed to mount"

    return 0
}

kill_ccfs_hard() {
    local pid="$CCFS_PID"

    [[ -n "$pid" ]] ||
        fail "no CCFS pid available for SIGKILL"

    kill -0 "$pid" 2>/dev/null ||
        fail "CCFS exited before SIGKILL"

    set +e

    kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null

    local status=$?

    set -e

    CCFS_PID=""

    detach_mount

    [[ "$status" -eq 137 ]] ||
        fail "expected SIGKILL status 137, got $status"
}

snapshot_volume() {
    stop_ccfs

    BACKUP_ROOT="$(
        mktemp -d /tmp/ccfs-fault-backup.XXXXXX
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
    rm -f "$ERROR_LOG"
    rm -f "$INTEGRITY_LOG"
    rm -f "$JOURNAL_LOG"

    set -e
}

run_integrity_expect_pass() {
    stop_ccfs

    ./target/debug/ccfs \
        --check-integrity \
        >"$INTEGRITY_LOG" 2>&1 ||
    {
        cat "$INTEGRITY_LOG"
        fail "integrity checker unexpectedly failed"
    }

    grep -q \
        "ALL CCFS BLOCKS PASSED INTEGRITY CHECK" \
        "$INTEGRITY_LOG" ||
        fail "integrity PASS marker missing"
}

run_integrity_expect_fail() {
    stop_ccfs

    set +e

    ./target/debug/ccfs \
        --check-integrity \
        >"$INTEGRITY_LOG" 2>&1

    local status=$?

    set -e

    [[ "$status" -ne 0 ]] ||
        fail "integrity checker unexpectedly accepted damaged storage"
}

assert_live_file() {
    local path="$1"
    local expected="$2"

    [[ -f "$path" ]] ||
        fail "expected live file missing: $path"

    local actual

    actual="$(cat "$path")"

    [[ "$actual" == "$expected" ]] ||
        fail "live file content mismatch: $path"
}

trap cleanup EXIT INT TERM

echo
echo "========================================"
echo " CCFS FAULT-INJECTION ACCEPTANCE TESTS"
echo "========================================"
echo

fusermount3 -u "$MOUNT_DIR" 2>/dev/null || true
fusermount3 -uz "$MOUNT_DIR" 2>/dev/null || true
sleep 0.1

mkdir -p "$MOUNT_DIR"

echo "[1/10] Preserving volume and building CCFS..."

snapshot_volume

cargo build --bin ccfs >/dev/null

rm -rf volume
mkdir -p volume/blocks

start_ccfs
stop_ccfs

pass "clean fault-injection volume initialized"

echo
echo "[2/10] Testing missing journal.log..."

rm -f volume/journal.log

start_ccfs

printf '%s' "$TEST_DATA" \
    > "$MOUNT_DIR/$TEST_FILE"

sync

assert_live_file \
    "$MOUNT_DIR/$TEST_FILE" \
    "$TEST_DATA"

stop_ccfs

[[ -f volume/journal.log ]] ||
    fail "journal.log was not recreated after normal operation"

pass "missing journal.log recovered with defined normal behavior"

echo
echo "[3/10] Capturing baseline inode and integrity..."

TEST_INO="$(
    sqlite3 volume/metadata.db \
        "SELECT ino
         FROM entries
         WHERE name='$TEST_FILE'
         LIMIT 1;"
)"

[[ -n "$TEST_INO" ]] ||
    fail "unable to resolve baseline inode"

run_integrity_expect_pass

pass "baseline storage healthy"

echo
echo "[4/10] Testing invalid metadata database detection..."

cp volume/metadata.db \
    /tmp/ccfs-valid-metadata-$RUN_ID.db

printf 'THIS IS NOT SQLITE' \
    > volume/metadata.db

set +e

./target/debug/ccfs \
    >"$ERROR_LOG" 2>&1

INVALID_DB_STATUS=$?

set -e

[[ "$INVALID_DB_STATUS" -ne 0 ]] ||
    fail "invalid metadata DB unexpectedly mounted successfully"

grep -qiE \
    "sqlite|database|initialize|malformed|not a database" \
    "$ERROR_LOG" ||
    fail "invalid metadata DB did not report a clear database error"

mv \
    /tmp/ccfs-valid-metadata-$RUN_ID.db \
    volume/metadata.db

rm -f volume/metadata.db-wal
rm -f volume/metadata.db-shm

start_ccfs

assert_live_file \
    "$MOUNT_DIR/$TEST_FILE" \
    "$TEST_DATA"

stop_ccfs

pass "invalid metadata DB detected and valid DB restored cleanly"

echo
echo "[5/10] Testing missing data block detection..."

cp \
    "volume/blocks/$TEST_INO.bin" \
    "/tmp/ccfs-test-$RUN_ID.bin"

rm \
    "volume/blocks/$TEST_INO.bin"

run_integrity_expect_fail

grep -qiE \
    "missing|data" \
    "$INTEGRITY_LOG" ||
    fail "missing data block error not clearly reported"

mv \
    "/tmp/ccfs-test-$RUN_ID.bin" \
    "volume/blocks/$TEST_INO.bin"

run_integrity_expect_pass

pass "missing data block detected"

echo
echo "[6/10] Testing missing checksum detection..."

cp \
    "volume/blocks/$TEST_INO.checksum" \
    "/tmp/ccfs-test-$RUN_ID.checksum"

rm \
    "volume/blocks/$TEST_INO.checksum"

run_integrity_expect_fail

grep -qiE \
    "missing|checksum" \
    "$INTEGRITY_LOG" ||
    fail "missing checksum error not clearly reported"

mv \
    "/tmp/ccfs-test-$RUN_ID.checksum" \
    "volume/blocks/$TEST_INO.checksum"

run_integrity_expect_pass

pass "missing checksum detected"

echo
echo "[7/10] Testing corrupted block checksum detection..."

cp \
    "volume/blocks/$TEST_INO.bin" \
    "/tmp/ccfs-corrupt-$RUN_ID.bin"

printf 'X' |
    dd \
        of="volume/blocks/$TEST_INO.bin" \
        bs=1 \
        seek=0 \
        conv=notrunc \
        status=none

run_integrity_expect_fail

grep -qi \
    "checksum" \
    "$INTEGRITY_LOG" ||
    fail "corrupted block did not report checksum error"

mv \
    "/tmp/ccfs-corrupt-$RUN_ID.bin" \
    "volume/blocks/$TEST_INO.bin"

run_integrity_expect_pass

pass "corrupted current block detected by checksum"

echo
echo "[8/10] Testing torn and bad journal record handling..."

cargo run \
    --bin journal_tool \
    -- self-test \
    >"$JOURNAL_LOG" 2>&1 ||
{
    cat "$JOURNAL_LOG"
    fail "journal corruption/torn-write self-test failed"
}

grep -q \
    "PASS: incomplete final record ignored safely" \
    "$JOURNAL_LOG" ||
    fail "torn journal tail test marker missing"

grep -q \
    "PASS: corrupted journal record detected" \
    "$JOURNAL_LOG" ||
    fail "bad journal checksum detection marker missing"

grep -q \
    "ALL CCFS JOURNAL ENGINE TESTS PASSED" \
    "$JOURNAL_LOG" ||
    fail "journal engine self-test final marker missing"

# journal_tool self-test intentionally manipulates the journal.
# Return to a clean recovery history before continuing.
./target/debug/ccfs \
    --checkpoint \
    >/dev/null 2>&1 ||
    true

pass "torn journal tail ignored and corrupted record detected"

echo
echo "[9/10] Testing crash immediately after mount..."

start_ccfs

kill_ccfs_hard

start_ccfs

assert_live_file \
    "$MOUNT_DIR/$TEST_FILE" \
    "$TEST_DATA"

stop_ccfs

run_integrity_expect_pass

pass "immediate-after-mount SIGKILL caused no filesystem damage"

echo
echo "[10/10] Testing crash before clean unmount..."

start_ccfs

python3 - \
    "$MOUNT_DIR/$CRASH_FILE" \
    "$CRASH_DATA" <<'PY'
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
        raise RuntimeError("short durable crash write")

    os.fsync(fd)

finally:
    os.close(fd)
PY

assert_live_file \
    "$MOUNT_DIR/$CRASH_FILE" \
    "$CRASH_DATA"

kill_ccfs_hard

start_ccfs

assert_live_file \
    "$MOUNT_DIR/$TEST_FILE" \
    "$TEST_DATA"

assert_live_file \
    "$MOUNT_DIR/$CRASH_FILE" \
    "$CRASH_DATA"

stop_ccfs

run_integrity_expect_pass

restore_volume

trap - EXIT INT TERM

rm -f "$NORMAL_LOG"
rm -f "$ERROR_LOG"
rm -f "$INTEGRITY_LOG"
rm -f "$JOURNAL_LOG"

echo
echo "========================================"
echo " ALL CCFS FAULT-INJECTION TESTS PASSED"
echo "========================================"
echo
