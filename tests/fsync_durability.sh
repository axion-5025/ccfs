#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

MOUNT_DIR="mount"
LOG_FILE="/tmp/ccfs-fsync-durability.log"

RUN_ID="$(date +%s)"
TEST_FILE="fsync-durability-$RUN_ID.txt"
TEST_PATH="$MOUNT_DIR/$TEST_FILE"

INITIAL_CONTENT="flush-stage"
FSYNC_CONTENT="-fsync-stage"
FDATASYNC_CONTENT="-fdatasync-stage"

EXPECTED_CONTENT="${INITIAL_CONTENT}${FSYNC_CONTENT}${FDATASYNC_CONTENT}"

CCFS_PID=""

fail() {
    echo
    echo "TEST FAILED: $1"
    echo
    echo "CCFS log:"
    echo "----------------------------------------"
    cat "$LOG_FILE" 2>/dev/null || true
    exit 1
}

is_mounted() {
    mountpoint -q "$MOUNT_DIR"
}

stop_ccfs() {
    set +e

    if is_mounted; then
        fusermount3 -u "$MOUNT_DIR"
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

cleanup() {
    set +e

    if is_mounted; then
        rm -f "$TEST_PATH"
    fi

    stop_ccfs

    set -e
}

trap cleanup EXIT INT TERM

start_ccfs() {
    echo "Starting CCFS..."

    : > "$LOG_FILE"

    ./target/debug/ccfs >"$LOG_FILE" 2>&1 &
    CCFS_PID=$!

    for _ in $(seq 1 50); do
        if is_mounted; then
            echo "CCFS mounted."
            return
        fi

        if ! kill -0 "$CCFS_PID" 2>/dev/null; then
            fail "CCFS process exited before mounting"
        fi

        sleep 0.1
    done

    fail "Timed out waiting for CCFS mount"
}

echo
echo "========================================"
echo " CCFS FLUSH / FSYNC DURABILITY TEST"
echo "========================================"
echo

mkdir -p "$MOUNT_DIR"
mkdir -p volume/blocks

if is_mounted; then
    echo "Removing stale CCFS mount..."
    fusermount3 -u "$MOUNT_DIR"
fi

echo "[1/8] Building CCFS..."
cargo build --bin ccfs

start_ccfs

echo "[2/8] Testing close/FLUSH path..."

python3 - "$TEST_PATH" "$INITIAL_CONTENT" <<'PY'
import sys

path = sys.argv[1]
data = sys.argv[2].encode()

with open(path, "wb", buffering=0) as file:
    file.write(data)

# Closing the file exercises the FUSE FLUSH path.
PY

[[ -f "$TEST_PATH" ]] ||
    fail "File missing after FLUSH/close"

INODE="$(stat -c '%i' "$TEST_PATH")"

[[ -f "volume/blocks/$INODE.bin" ]] ||
    fail "Durable data block missing after FLUSH"

[[ -f "volume/blocks/$INODE.checksum" ]] ||
    fail "Durable checksum missing after FLUSH"

CONTENT="$(cat "$TEST_PATH")"

[[ "$CONTENT" == "$INITIAL_CONTENT" ]] ||
    fail "Content mismatch after FLUSH"

echo "[3/8] Testing explicit fsync()..."

python3 - "$TEST_PATH" "$FSYNC_CONTENT" <<'PY'
import os
import sys

path = sys.argv[1]
data = sys.argv[2].encode()

fd = os.open(path, os.O_RDWR)

try:
    os.lseek(fd, 0, os.SEEK_END)

    written = os.write(fd, data)

    if written != len(data):
        raise RuntimeError(
            f"short write: expected {len(data)}, wrote {written}"
        )

    os.fsync(fd)

finally:
    os.close(fd)
PY

CONTENT="$(cat "$TEST_PATH")"

[[ "$CONTENT" == "${INITIAL_CONTENT}${FSYNC_CONTENT}" ]] ||
    fail "Content mismatch after fsync()"

echo "[4/8] Testing explicit fdatasync()..."

python3 - "$TEST_PATH" "$FDATASYNC_CONTENT" <<'PY'
import os
import sys

path = sys.argv[1]
data = sys.argv[2].encode()

fd = os.open(path, os.O_RDWR)

try:
    os.lseek(fd, 0, os.SEEK_END)

    written = os.write(fd, data)

    if written != len(data):
        raise RuntimeError(
            f"short write: expected {len(data)}, wrote {written}"
        )

    os.fdatasync(fd)

finally:
    os.close(fd)
PY

CONTENT="$(cat "$TEST_PATH")"

[[ "$CONTENT" == "$EXPECTED_CONTENT" ]] ||
    fail "Content mismatch after fdatasync()"

echo "[5/8] Checking durable backing files..."

[[ -f "volume/blocks/$INODE.bin" ]] ||
    fail "Data block missing"

[[ -f "volume/blocks/$INODE.checksum" ]] ||
    fail "Checksum file missing"

BACKING_CONTENT="$(cat "volume/blocks/$INODE.bin")"

[[ "$BACKING_CONTENT" == "$EXPECTED_CONTENT" ]] ||
    fail "Backing block content mismatch"

echo "[6/8] Restarting CCFS and verifying persistence..."

stop_ccfs
start_ccfs

[[ -f "$TEST_PATH" ]] ||
    fail "File missing after restart"

RESTART_INODE="$(stat -c '%i' "$TEST_PATH")"

[[ "$RESTART_INODE" == "$INODE" ]] ||
    fail "Inode changed after restart"

RESTART_CONTENT="$(cat "$TEST_PATH")"

[[ "$RESTART_CONTENT" == "$EXPECTED_CONTENT" ]] ||
    fail "Durable content not preserved after restart"

echo "[7/8] Running integrity verification..."

./target/debug/ccfs --check-integrity >/tmp/ccfs-fsync-integrity.log 2>&1 ||
{
    cat /tmp/ccfs-fsync-integrity.log
    fail "Integrity verification failed"
}

grep -q "ALL CCFS BLOCKS PASSED INTEGRITY CHECK" \
    /tmp/ccfs-fsync-integrity.log ||
    fail "Integrity success marker missing"

echo "[8/8] Cleaning test file..."

rm "$TEST_PATH"

[[ ! -e "$TEST_PATH" ]] ||
    fail "Test file still exists after cleanup"

[[ ! -e "volume/blocks/$INODE.bin" ]] ||
    fail "Data block still exists after cleanup"

[[ ! -e "volume/blocks/$INODE.checksum" ]] ||
    fail "Checksum still exists after cleanup"

stop_ccfs

trap - EXIT INT TERM

echo
echo "========================================"
echo " ALL CCFS FLUSH / FSYNC TESTS PASSED"
echo "========================================"
echo
