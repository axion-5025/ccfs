#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

MOUNT_DIR="mount"
LOG_FILE="/tmp/ccfs-boundary-cases.log"

RUN_ID="$(date +%s)"
BASE="boundary-$RUN_ID"

BOUNDARY_FILE="$BASE-block.bin"
EOF_FILE="$BASE-eof.bin"
ZERO_FILE="$BASE-zero.txt"
DUP_FILE="$BASE-duplicate.txt"
SAME_FILE="$BASE-same-name.txt"
DEEP_ROOT="$BASE-deep"
MANY_DIR="$BASE-many"
LARGE_FILE="$BASE-large.bin"

TMP_1="/tmp/$BASE-1.bin"
TMP_4095="/tmp/$BASE-4095.bin"
TMP_4096="/tmp/$BASE-4096.bin"
TMP_4097="/tmp/$BASE-4097.bin"
TMP_EXPECTED="/tmp/$BASE-expected.bin"
TMP_EOF="/tmp/$BASE-eof-expected.bin"
TMP_LARGE="/tmp/$BASE-large-source.bin"

CCFS_PID=""

pass() {
    echo "PASS: $1"
}

fail() {
    echo
    echo "========================================"
    echo "TEST FAILED: $1"
    echo "========================================"
    echo
    echo "CCFS log:"
    echo "----------------------------------------"
    cat "$LOG_FILE" 2>/dev/null || true
    exit 1
}

is_mounted() {
    mountpoint -q "$MOUNT_DIR"
}

wait_for_unmount() {
    for _ in $(seq 1 50); do
        if ! is_mounted; then
            return 0
        fi
        sleep 0.1
    done

    return 1
}

force_unmount() {
    set +e

    if is_mounted; then
        fusermount3 -u "$MOUNT_DIR" 2>/dev/null || true
    fi

    if is_mounted; then
        fusermount3 -uz "$MOUNT_DIR" 2>/dev/null || true
    fi

    wait_for_unmount >/dev/null 2>&1 || true

    set -e
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

    if is_mounted; then
        fusermount3 -uz "$MOUNT_DIR" 2>/dev/null || true
    fi

    wait_for_unmount >/dev/null 2>&1 || true

    set -e
}

start_ccfs() {
    echo "Starting CCFS..."

    if is_mounted; then
        force_unmount
    fi

    : > "$LOG_FILE"

    ./target/debug/ccfs >"$LOG_FILE" 2>&1 &
    CCFS_PID=$!

    for _ in $(seq 1 50); do
        if is_mounted; then
            echo "CCFS mounted."
            return
        fi

        if ! kill -0 "$CCFS_PID" 2>/dev/null; then
            fail "CCFS exited before mount completed"
        fi

        sleep 0.1
    done

    fail "Timed out waiting for CCFS mount"
}

expect_failure() {
    local description="$1"
    shift

    if "$@" >/tmp/ccfs-boundary-command.out 2>&1; then
        cat /tmp/ccfs-boundary-command.out || true
        fail "$description unexpectedly succeeded"
    fi

    pass "$description"
}

cleanup() {
    set +e

    if is_mounted; then
        rm -f "$MOUNT_DIR/$BASE-1.bin"
        rm -f "$MOUNT_DIR/$BASE-4095.bin"
        rm -f "$MOUNT_DIR/$BASE-4096.bin"
        rm -f "$MOUNT_DIR/$BASE-4097.bin"
        rm -f "$MOUNT_DIR/$BOUNDARY_FILE"
        rm -f "$MOUNT_DIR/$EOF_FILE"
        rm -f "$MOUNT_DIR/$ZERO_FILE"
        rm -f "$MOUNT_DIR/$DUP_FILE"
        rm -f "$MOUNT_DIR/$SAME_FILE"
        rm -f "$MOUNT_DIR/$LARGE_FILE"

        rm -rf "$MOUNT_DIR/$DEEP_ROOT" 2>/dev/null || true
        rm -rf "$MOUNT_DIR/$MANY_DIR" 2>/dev/null || true

        if [[ -n "${LONG_255:-}" ]]; then
            rm -f "$MOUNT_DIR/$LONG_255" 2>/dev/null || true
        fi
    fi

    stop_ccfs

    rm -f "$TMP_1"
    rm -f "$TMP_4095"
    rm -f "$TMP_4096"
    rm -f "$TMP_4097"
    rm -f "$TMP_EXPECTED"
    rm -f "$TMP_EOF"
    rm -f "$TMP_LARGE"
    rm -f /tmp/ccfs-boundary-command.out

    set -e
}

trap cleanup EXIT INT TERM

echo
echo "========================================"
echo " CCFS Boundary & Namespace Test Suite"
echo "========================================"
echo

mkdir -p "$MOUNT_DIR"
mkdir -p volume/blocks

if is_mounted; then
    echo "Removing stale mount..."
    force_unmount
fi

echo "[1/19] Building project..."
cargo build
pass "cargo build"

start_ccfs

echo
echo "[2/19] 1-byte file..."

printf 'X' > "$TMP_1"
cp "$TMP_1" "$MOUNT_DIR/$BASE-1.bin"

[[ "$(stat -c '%s' "$MOUNT_DIR/$BASE-1.bin")" == "1" ]] ||
    fail "1-byte file has wrong size"

cmp -s "$TMP_1" "$MOUNT_DIR/$BASE-1.bin" ||
    fail "1-byte file content mismatch"

pass "1-byte file"

echo
echo "[3/19] 4095-byte file..."

head -c 4095 /dev/urandom > "$TMP_4095"
cp "$TMP_4095" "$MOUNT_DIR/$BASE-4095.bin"

[[ "$(stat -c '%s' "$MOUNT_DIR/$BASE-4095.bin")" == "4095" ]] ||
    fail "4095-byte file has wrong size"

cmp -s "$TMP_4095" "$MOUNT_DIR/$BASE-4095.bin" ||
    fail "4095-byte file content mismatch"

pass "4095-byte file"

echo
echo "[4/19] 4096-byte file..."

head -c 4096 /dev/urandom > "$TMP_4096"
cp "$TMP_4096" "$MOUNT_DIR/$BASE-4096.bin"

[[ "$(stat -c '%s' "$MOUNT_DIR/$BASE-4096.bin")" == "4096" ]] ||
    fail "4096-byte file has wrong size"

cmp -s "$TMP_4096" "$MOUNT_DIR/$BASE-4096.bin" ||
    fail "4096-byte file content mismatch"

pass "4096-byte file"

echo
echo "[5/19] 4097-byte file..."

head -c 4097 /dev/urandom > "$TMP_4097"
cp "$TMP_4097" "$MOUNT_DIR/$BASE-4097.bin"

[[ "$(stat -c '%s' "$MOUNT_DIR/$BASE-4097.bin")" == "4097" ]] ||
    fail "4097-byte file has wrong size"

cmp -s "$TMP_4097" "$MOUNT_DIR/$BASE-4097.bin" ||
    fail "4097-byte file content mismatch"

pass "4097-byte file"

echo
echo "[6/19] Write at 4096-byte boundary..."

python3 -c \
    'import sys; open(sys.argv[1], "wb").write(b"A" * 8192)' \
    "$TMP_EXPECTED"

cp "$TMP_EXPECTED" "$MOUNT_DIR/$BOUNDARY_FILE"

printf 'XYZ' |
    dd \
        of="$MOUNT_DIR/$BOUNDARY_FILE" \
        bs=1 \
        seek=4096 \
        conv=notrunc \
        status=none

python3 -c '
import sys
p = sys.argv[1]
d = bytearray(open(p, "rb").read())
d[4096:4099] = b"XYZ"
open(p, "wb").write(d)
' "$TMP_EXPECTED"

cmp -s "$TMP_EXPECTED" "$MOUNT_DIR/$BOUNDARY_FILE" ||
    fail "write at block boundary corrupted data"

pass "write at block boundary"

echo
echo "[7/19] Write crossing 4096-byte boundary..."

printf 'WXYZ' |
    dd \
        of="$MOUNT_DIR/$BOUNDARY_FILE" \
        bs=1 \
        seek=4094 \
        conv=notrunc \
        status=none

python3 -c '
import sys
p = sys.argv[1]
d = bytearray(open(p, "rb").read())
d[4094:4098] = b"WXYZ"
open(p, "wb").write(d)
' "$TMP_EXPECTED"

cmp -s "$TMP_EXPECTED" "$MOUNT_DIR/$BOUNDARY_FILE" ||
    fail "cross-boundary write corrupted data"

pass "write crossing block boundary"

echo
echo "[8/19] Partial write preserves remaining bytes..."

printf '12345' |
    dd \
        of="$MOUNT_DIR/$BOUNDARY_FILE" \
        bs=1 \
        seek=100 \
        conv=notrunc \
        status=none

python3 -c '
import sys
p = sys.argv[1]
d = bytearray(open(p, "rb").read())
d[100:105] = b"12345"
open(p, "wb").write(d)
' "$TMP_EXPECTED"

cmp -s "$TMP_EXPECTED" "$MOUNT_DIR/$BOUNDARY_FILE" ||
    fail "partial write changed unrelated bytes"

pass "partial write preservation"

echo
echo "[9/19] Write beyond EOF..."

printf 'ABC' > "$MOUNT_DIR/$EOF_FILE"

printf 'Z' |
    dd \
        of="$MOUNT_DIR/$EOF_FILE" \
        bs=1 \
        seek=10 \
        conv=notrunc \
        status=none

python3 -c '
import sys
open(sys.argv[1], "wb").write(
    b"ABC" + (b"\x00" * 7) + b"Z"
)
' "$TMP_EOF"

[[ "$(stat -c '%s' "$MOUNT_DIR/$EOF_FILE")" == "11" ]] ||
    fail "write beyond EOF produced wrong size"

cmp -s "$TMP_EOF" "$MOUNT_DIR/$EOF_FILE" ||
    fail "write beyond EOF did not zero-fill gap correctly"

pass "write beyond EOF"

echo
echo "[10/19] Truncate to zero..."

printf 'truncate-me' > "$MOUNT_DIR/$ZERO_FILE"

truncate -s 0 "$MOUNT_DIR/$ZERO_FILE"

[[ "$(stat -c '%s' "$MOUNT_DIR/$ZERO_FILE")" == "0" ]] ||
    fail "truncate-to-zero did not produce zero-byte file"

pass "truncate to zero"

echo
echo "[11/19] Duplicate regular-file creation..."

printf 'original-content\n' > "$MOUNT_DIR/$DUP_FILE"

expect_failure \
    "exclusive duplicate regular-file create rejected" \
    python3 -c '
import os
import sys

p = sys.argv[1]
fd = os.open(
    p,
    os.O_CREAT | os.O_EXCL | os.O_WRONLY,
    0o644
)
os.close(fd)
' "$MOUNT_DIR/$DUP_FILE"

[[ "$(cat "$MOUNT_DIR/$DUP_FILE")" == "original-content" ]] ||
    fail "duplicate create changed existing file"

pass "existing file preserved"

echo
echo "[12/19] Rename to same name..."

printf 'same-name-data\n' > "$MOUNT_DIR/$SAME_FILE"

python3 -c '
import os
import sys
os.rename(sys.argv[1], sys.argv[1])
' "$MOUNT_DIR/$SAME_FILE"

[[ -f "$MOUNT_DIR/$SAME_FILE" ]] ||
    fail "same-name rename removed file"

[[ "$(cat "$MOUNT_DIR/$SAME_FILE")" == "same-name-data" ]] ||
    fail "same-name rename changed content"

pass "rename to same name"

echo
echo "[13/19] Missing-file operations..."

expect_failure \
    "delete missing file rejected" \
    rm "$MOUNT_DIR/$BASE-does-not-exist.txt"

expect_failure \
    "read missing file rejected" \
    cat "$MOUNT_DIR/$BASE-does-not-exist.txt"

echo
echo "[14/19] Root mountpoint removal..."

expect_failure \
    "mounted filesystem root removal rejected" \
    rmdir "$MOUNT_DIR"

echo
echo "[15/19] Deep nested directories..."

DEEP_PATH="$MOUNT_DIR/$DEEP_ROOT"
mkdir "$DEEP_PATH"

for level in $(seq -w 1 20); do
    DEEP_PATH="$DEEP_PATH/d$level"
    mkdir "$DEEP_PATH"
done

printf 'deep-data\n' > "$DEEP_PATH/final.txt"

[[ "$(cat "$DEEP_PATH/final.txt")" == "deep-data" ]] ||
    fail "deep nested file read failed"

pass "20-level nested directory"

echo
echo "[16/19] Very long filename..."

LONG_255="$(python3 -c 'print("n" * 255, end="")')"
LONG_256="$(python3 -c 'print("n" * 256, end="")')"

printf 'long-name\n' > "$MOUNT_DIR/$LONG_255"

[[ -f "$MOUNT_DIR/$LONG_255" ]] ||
    fail "255-character filename was not created"

expect_failure \
    "256-character filename rejected" \
    touch "$MOUNT_DIR/$LONG_256"

pass "filename length boundary"

echo
echo "[17/19] Many files in one directory..."

mkdir "$MOUNT_DIR/$MANY_DIR"

for i in $(seq -w 1 250); do
    printf 'file-%s\n' "$i" > "$MOUNT_DIR/$MANY_DIR/file-$i.txt"
done

FILE_COUNT="$(
    find "$MOUNT_DIR/$MANY_DIR" \
        -maxdepth 1 \
        -type f \
        | wc -l
)"

[[ "$FILE_COUNT" == "250" ]] ||
    fail "many-files directory expected 250 files, got $FILE_COUNT"

ls -1 "$MOUNT_DIR/$MANY_DIR" >/dev/null

pass "250 files listed correctly"

echo
echo "[18/19] 4 MiB binary file..."

dd \
    if=/dev/urandom \
    of="$TMP_LARGE" \
    bs=1M \
    count=4 \
    status=none

cp "$TMP_LARGE" "$MOUNT_DIR/$LARGE_FILE"

SOURCE_HASH="$(
    sha256sum "$TMP_LARGE" |
        awk '{print $1}'
)"

MOUNT_HASH="$(
    sha256sum "$MOUNT_DIR/$LARGE_FILE" |
        awk '{print $1}'
)"

[[ "$SOURCE_HASH" == "$MOUNT_HASH" ]] ||
    fail "4 MiB binary hash mismatch"

pass "4 MiB binary file"

echo
echo "[19/19] Restart persistence for boundary cases..."

stop_ccfs
start_ccfs

cmp -s "$TMP_1" "$MOUNT_DIR/$BASE-1.bin" ||
    fail "1-byte file failed after restart"

cmp -s "$TMP_4095" "$MOUNT_DIR/$BASE-4095.bin" ||
    fail "4095-byte file failed after restart"

cmp -s "$TMP_4096" "$MOUNT_DIR/$BASE-4096.bin" ||
    fail "4096-byte file failed after restart"

cmp -s "$TMP_4097" "$MOUNT_DIR/$BASE-4097.bin" ||
    fail "4097-byte file failed after restart"

cmp -s "$TMP_EXPECTED" "$MOUNT_DIR/$BOUNDARY_FILE" ||
    fail "boundary-write file failed after restart"

cmp -s "$TMP_EOF" "$MOUNT_DIR/$EOF_FILE" ||
    fail "beyond-EOF file failed after restart"

[[ "$(stat -c '%s' "$MOUNT_DIR/$ZERO_FILE")" == "0" ]] ||
    fail "truncate-to-zero did not survive restart"

[[ "$(cat "$MOUNT_DIR/$SAME_FILE")" == "same-name-data" ]] ||
    fail "same-name file failed after restart"

[[ "$(cat "$DEEP_PATH/final.txt")" == "deep-data" ]] ||
    fail "deep directory data failed after restart"

FILE_COUNT="$(
    find "$MOUNT_DIR/$MANY_DIR" \
        -maxdepth 1 \
        -type f \
        | wc -l
)"

[[ "$FILE_COUNT" == "250" ]] ||
    fail "many-files directory changed after restart"

RESTART_HASH="$(
    sha256sum "$MOUNT_DIR/$LARGE_FILE" |
        awk '{print $1}'
)"

[[ "$SOURCE_HASH" == "$RESTART_HASH" ]] ||
    fail "4 MiB binary changed after restart"

pass "all boundary cases survived restart"

echo
echo "Cleaning generated test data..."

rm -f "$MOUNT_DIR/$BASE-1.bin"
rm -f "$MOUNT_DIR/$BASE-4095.bin"
rm -f "$MOUNT_DIR/$BASE-4096.bin"
rm -f "$MOUNT_DIR/$BASE-4097.bin"
rm -f "$MOUNT_DIR/$BOUNDARY_FILE"
rm -f "$MOUNT_DIR/$EOF_FILE"
rm -f "$MOUNT_DIR/$ZERO_FILE"
rm -f "$MOUNT_DIR/$DUP_FILE"
rm -f "$MOUNT_DIR/$SAME_FILE"
rm -f "$MOUNT_DIR/$LARGE_FILE"
rm -f "$MOUNT_DIR/$LONG_255"

rm -rf "$MOUNT_DIR/$DEEP_ROOT"
rm -rf "$MOUNT_DIR/$MANY_DIR"

stop_ccfs

trap - EXIT INT TERM

rm -f "$TMP_1"
rm -f "$TMP_4095"
rm -f "$TMP_4096"
rm -f "$TMP_4097"
rm -f "$TMP_EXPECTED"
rm -f "$TMP_EOF"
rm -f "$TMP_LARGE"
rm -f /tmp/ccfs-boundary-command.out

echo
echo "========================================"
echo " ALL CCFS BOUNDARY TESTS PASSED"
echo "========================================"
echo