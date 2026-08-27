#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

MOUNT_DIR="mount"
LOG_FILE="/tmp/ccfs-integrity-test.log"

RUN_ID="$(date +%s)"
TEST_FILE="integrity-$RUN_ID.txt"

CCFS_PID=""
TEST_INODE=""

DATA_BACKUP=""
CHECKSUM_BACKUP=""

fail() {
    echo
    echo "========================================"
    echo "TEST FAILED: $1"
    echo "========================================"
    echo

    if [[ -f "$LOG_FILE" ]]; then
        echo "CCFS log:"
        echo "----------------------------------------"
        cat "$LOG_FILE" || true
    fi

    exit 1
}

pass() {
    echo "PASS: $1"
}

is_mounted() {
    mountpoint -q "$MOUNT_DIR"
}

stop_ccfs() {
    set +e

    if is_mounted; then
        fusermount3 -u "$MOUNT_DIR" 2>/dev/null || true
    fi

    if is_mounted; then
        fusermount3 -uz "$MOUNT_DIR" 2>/dev/null || true
    fi

    if [[ -n "${CCFS_PID:-}" ]] && kill -0 "$CCFS_PID" 2>/dev/null; then
        kill "$CCFS_PID" 2>/dev/null || true
    fi

    if [[ -n "${CCFS_PID:-}" ]]; then
        wait "$CCFS_PID" 2>/dev/null || true
    fi

    CCFS_PID=""

    set -e
}

start_ccfs() {
    stop_ccfs

    : > "$LOG_FILE"

    ./target/debug/ccfs >"$LOG_FILE" 2>&1 &
    CCFS_PID=$!

    for _ in $(seq 1 50); do
        if is_mounted; then
            return
        fi

        if ! kill -0 "$CCFS_PID" 2>/dev/null; then
            fail "CCFS exited before mounting"
        fi

        sleep 0.1
    done

    fail "Timed out waiting for CCFS mount"
}

cleanup() {
    set +e

    if [[ -n "${TEST_INODE:-}" ]]; then
        if [[ -n "${DATA_BACKUP:-}" && -f "$DATA_BACKUP" ]]; then
            cp "$DATA_BACKUP" "volume/blocks/$TEST_INODE.bin"
        fi

        if [[ -n "${CHECKSUM_BACKUP:-}" && -f "$CHECKSUM_BACKUP" ]]; then
            cp "$CHECKSUM_BACKUP" "volume/blocks/$TEST_INODE.checksum"
        fi
    fi

    if ! is_mounted; then
        start_ccfs >/dev/null 2>&1 || true
    fi

    if is_mounted; then
        rm -f "$MOUNT_DIR/$TEST_FILE" 2>/dev/null || true
    fi

    stop_ccfs

    rm -f "${DATA_BACKUP:-}"
    rm -f "${CHECKSUM_BACKUP:-}"
    rm -f /tmp/ccfs-integrity-output.txt

    set -e
}

trap cleanup EXIT INT TERM

echo
echo "========================================"
echo " CCFS Integrity / Corruption Test Suite"
echo "========================================"
echo

echo "[1/7] Building project..."
cargo build >/dev/null
pass "cargo build"

echo
echo "[2/7] Creating checksum-protected test file..."

start_ccfs

printf "CCFS integrity test data\n" > "$MOUNT_DIR/$TEST_FILE"

TEST_INODE="$(stat -c '%i' "$MOUNT_DIR/$TEST_FILE")"

[[ -n "$TEST_INODE" ]] ||
    fail "Could not determine test inode"

[[ -f "volume/blocks/$TEST_INODE.bin" ]] ||
    fail "Data block was not created"

[[ -f "volume/blocks/$TEST_INODE.checksum" ]] ||
    fail "Checksum file was not created"

pass "data block and checksum created for inode $TEST_INODE"

stop_ccfs

DATA_BACKUP="/tmp/ccfs-$TEST_INODE.bin.backup"
CHECKSUM_BACKUP="/tmp/ccfs-$TEST_INODE.checksum.backup"

cp "volume/blocks/$TEST_INODE.bin" "$DATA_BACKUP"
cp "volume/blocks/$TEST_INODE.checksum" "$CHECKSUM_BACKUP"

echo
echo "[3/7] Healthy integrity check..."

./target/debug/ccfs --check-integrity \
    >/tmp/ccfs-integrity-output.txt 2>&1 ||
    fail "Healthy integrity check unexpectedly failed"

grep -q \
    "ALL CCFS BLOCKS PASSED INTEGRITY CHECK" \
    /tmp/ccfs-integrity-output.txt ||
    fail "Healthy integrity success message missing"

pass "healthy block accepted"

echo
echo "[4/7] Corrupting persisted data block..."

printf 'X' |
    dd \
        of="volume/blocks/$TEST_INODE.bin" \
        bs=1 \
        seek=0 \
        conv=notrunc \
        status=none

if ./target/debug/ccfs --check-integrity \
    >/tmp/ccfs-integrity-output.txt 2>&1
then
    cat /tmp/ccfs-integrity-output.txt
    fail "Corrupted block was not detected"
fi

grep -q \
    "checksum mismatch" \
    /tmp/ccfs-integrity-output.txt ||
    fail "Corruption failure did not report checksum mismatch"

pass "corrupted block detected"

echo
echo "[5/7] Restoring healthy data..."

cp "$DATA_BACKUP" "volume/blocks/$TEST_INODE.bin"

./target/debug/ccfs --check-integrity \
    >/tmp/ccfs-integrity-output.txt 2>&1 ||
    fail "Integrity did not recover after restoring data"

pass "restored block is healthy"

echo
echo "[6/7] Missing checksum detection..."

rm "volume/blocks/$TEST_INODE.checksum"

if ./target/debug/ccfs --check-integrity \
    >/tmp/ccfs-integrity-output.txt 2>&1
then
    cat /tmp/ccfs-integrity-output.txt
    fail "Missing checksum was not detected"
fi

grep -q \
    "checksum missing" \
    /tmp/ccfs-integrity-output.txt ||
    fail "Missing checksum was not reported"

pass "missing checksum detected"

echo
echo "[7/7] Restore checksum and final verification..."

cp \
    "$CHECKSUM_BACKUP" \
    "volume/blocks/$TEST_INODE.checksum"

./target/debug/ccfs --check-integrity \
    >/tmp/ccfs-integrity-output.txt 2>&1 ||
    fail "Final integrity check failed"

grep -q \
    "ALL CCFS BLOCKS PASSED INTEGRITY CHECK" \
    /tmp/ccfs-integrity-output.txt ||
    fail "Final healthy integrity message missing"

pass "final filesystem integrity healthy"

start_ccfs
rm "$MOUNT_DIR/$TEST_FILE"
stop_ccfs

trap - EXIT INT TERM

rm -f "$DATA_BACKUP"
rm -f "$CHECKSUM_BACKUP"
rm -f /tmp/ccfs-integrity-output.txt

echo
echo "========================================"
echo " ALL CCFS INTEGRITY TESTS PASSED"
echo "========================================"
echo