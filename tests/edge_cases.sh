#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

MOUNT_DIR="mount"
DB_FILE="volume/metadata.db"
LOG_FILE="/tmp/ccfs-edge-cases.log"

RUN_ID="$(date +%s)"
BASE="edge-$RUN_ID"

DIR_A="${BASE}-a"
DIR_B="${BASE}-b"
DIR_C="${BASE}-c"

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

    # First try a normal FUSE unmount.
    if is_mounted; then
        fusermount3 -u "$MOUNT_DIR" 2>/dev/null || true
    fi

    # If normal unmount failed because the mount is busy/stale,
    # use lazy unmount.
    if is_mounted; then
        fusermount3 -uz "$MOUNT_DIR" 2>/dev/null || true
    fi

    # Stop the CCFS process tracked by this test run.
    if [[ -n "${CCFS_PID:-}" ]] && kill -0 "$CCFS_PID" 2>/dev/null; then
        kill "$CCFS_PID" 2>/dev/null || true
    fi

    if [[ -n "${CCFS_PID:-}" ]]; then
        wait "$CCFS_PID" 2>/dev/null || true
    fi

    CCFS_PID=""

    # Killing the FUSE process can leave a disconnected endpoint.
    # Clean that up as well.
    if is_mounted; then
        fusermount3 -uz "$MOUNT_DIR" 2>/dev/null || true
    fi

    wait_for_unmount >/dev/null 2>&1 || true

    set -e
}

start_ccfs() {
    echo "Starting CCFS..."

    # Never start on top of a stale FUSE mount.
    if is_mounted; then
        echo "Cleaning stale mount before start..."
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

cleanup() {
    set +e

    if is_mounted; then
        rm -f "$MOUNT_DIR/$BASE-empty.txt"
        rm -f "$MOUNT_DIR/$BASE-delete.txt"
        rm -f "$MOUNT_DIR/$BASE-renamed.txt"
        rm -f "$MOUNT_DIR/$BASE-rename-source.txt"
        rm -f "$MOUNT_DIR/$BASE-rename-dest.txt"
        rm -f "$MOUNT_DIR/$BASE-truncate.txt"
        rm -f "$MOUNT_DIR/$BASE-perm.txt"
        rm -f "$MOUNT_DIR/$BASE-large.bin"
        rm -f "$MOUNT_DIR/$DIR_B-file-temp.txt"

        rm -f "$MOUNT_DIR/$DIR_A/file.txt"
        rm -f "$MOUNT_DIR/$DIR_A/child/file.txt"
        rm -f "$MOUNT_DIR/$DIR_B/file.txt"

        rmdir "$MOUNT_DIR/$DIR_A/child" 2>/dev/null || true
        rmdir "$MOUNT_DIR/$DIR_A" 2>/dev/null || true
        rmdir "$MOUNT_DIR/$DIR_B" 2>/dev/null || true
        rmdir "$MOUNT_DIR/$DIR_C" 2>/dev/null || true
    fi

    stop_ccfs

    rm -f "/tmp/$BASE-source.bin"
    rm -f /tmp/ccfs-edge-command.out

    set -e
}

trap cleanup EXIT INT TERM

expect_failure() {
    local description="$1"
    shift

    if "$@" >/tmp/ccfs-edge-command.out 2>&1; then
        cat /tmp/ccfs-edge-command.out || true
        fail "$description unexpectedly succeeded"
    fi

    pass "$description"
}

echo
echo "========================================"
echo " CCFS Pre-Release Edge-Case Test Suite"
echo "========================================"
echo

mkdir -p "$MOUNT_DIR"
mkdir -p volume/blocks

# Clean a mount left behind by an earlier failed test run.
if is_mounted; then
    echo "Removing stale mount..."

    fusermount3 -u "$MOUNT_DIR" 2>/dev/null || true

    if is_mounted; then
        fusermount3 -uz "$MOUNT_DIR" 2>/dev/null || true
    fi

    wait_for_unmount >/dev/null 2>&1 || true
fi

echo "[1] Building project..."
cargo build
pass "cargo build"

start_ccfs

echo
echo "[2] Duplicate directory creation..."

mkdir "$MOUNT_DIR/$DIR_A"

expect_failure \
    "duplicate mkdir rejected" \
    mkdir "$MOUNT_DIR/$DIR_A"

echo
echo "[3] rmdir on non-empty directory..."

printf "data\n" > "$MOUNT_DIR/$DIR_A/file.txt"

expect_failure \
    "rmdir non-empty directory rejected" \
    rmdir "$MOUNT_DIR/$DIR_A"

echo
echo "[4] rm on directory..."

expect_failure \
    "rm regular command does not delete directory" \
    rm "$MOUNT_DIR/$DIR_A"

[[ -d "$MOUNT_DIR/$DIR_A" ]] ||
    fail "Directory disappeared after failed rm"

echo
echo "[5] rmdir on regular file..."

expect_failure \
    "rmdir regular file rejected" \
    rmdir "$MOUNT_DIR/$DIR_A/file.txt"

echo
echo "[6] Reading directory as regular file..."

expect_failure \
    "cat directory rejected" \
    cat "$MOUNT_DIR/$DIR_A"

echo
echo "[7] Writing directly to directory..."

expect_failure \
    "write to directory rejected" \
    bash -c "printf 'bad\n' > '$MOUNT_DIR/$DIR_A'"

echo
echo "[8] Rename missing source..."

expect_failure \
    "rename missing source rejected" \
    mv \
        "$MOUNT_DIR/$BASE-missing.txt" \
        "$MOUNT_DIR/$BASE-anything.txt"

echo
echo "[9] Rename into existing destination..."

printf "source-data\n" > "$MOUNT_DIR/$BASE-rename-source.txt"
printf "destination-data\n" > "$MOUNT_DIR/$BASE-rename-dest.txt"

expect_failure \
    "rename onto existing destination rejected safely" \
    mv \
        "$MOUNT_DIR/$BASE-rename-source.txt" \
        "$MOUNT_DIR/$BASE-rename-dest.txt"

[[ "$(cat "$MOUNT_DIR/$BASE-rename-source.txt")" == "source-data" ]] ||
    fail "Source changed after failed rename"

[[ "$(cat "$MOUNT_DIR/$BASE-rename-dest.txt")" == "destination-data" ]] ||
    fail "Destination changed after failed rename"

pass "failed rename preserved both files"

echo
echo "[10] Directory cycle prevention..."

mkdir "$MOUNT_DIR/$DIR_A/child"

expect_failure \
    "moving directory into its own child rejected" \
    mv \
        "$MOUNT_DIR/$DIR_A" \
        "$MOUNT_DIR/$DIR_A/child/moved"

[[ -d "$MOUNT_DIR/$DIR_A" ]] ||
    fail "Parent directory disappeared after cycle rejection"

[[ -d "$MOUNT_DIR/$DIR_A/child" ]] ||
    fail "Child directory disappeared after cycle rejection"

echo
echo "[11] Empty file persistence..."

touch "$MOUNT_DIR/$BASE-empty.txt"

[[ -f "$MOUNT_DIR/$BASE-empty.txt" ]] ||
    fail "Empty file was not created"

[[ "$(stat -c '%s' "$MOUNT_DIR/$BASE-empty.txt")" == "0" ]] ||
    fail "Empty file size is not zero"

stop_ccfs
start_ccfs

[[ -f "$MOUNT_DIR/$BASE-empty.txt" ]] ||
    fail "Empty file missing after restart"

[[ "$(stat -c '%s' "$MOUNT_DIR/$BASE-empty.txt")" == "0" ]] ||
    fail "Empty file size changed after restart"

pass "empty file persisted"

echo
echo "[12] Rename persistence..."

printf "rename-persist\n" > "$MOUNT_DIR/$BASE-renamed.txt"

mv \
    "$MOUNT_DIR/$BASE-renamed.txt" \
    "$MOUNT_DIR/$DIR_B-file-temp.txt"

mv \
    "$MOUNT_DIR/$DIR_B-file-temp.txt" \
    "$MOUNT_DIR/$BASE-renamed.txt"

stop_ccfs
start_ccfs

[[ -f "$MOUNT_DIR/$BASE-renamed.txt" ]] ||
    fail "Renamed file missing after restart"

[[ "$(cat "$MOUNT_DIR/$BASE-renamed.txt")" == "rename-persist" ]] ||
    fail "Renamed file content corrupted after restart"

pass "rename survived restart"

echo
echo "[13] Delete persistence..."

printf "delete-me\n" > "$MOUNT_DIR/$BASE-delete.txt"

DELETE_INODE="$(stat -c '%i' "$MOUNT_DIR/$BASE-delete.txt")"

rm "$MOUNT_DIR/$BASE-delete.txt"

[[ ! -e "$MOUNT_DIR/$BASE-delete.txt" ]] ||
    fail "Deleted file still visible"

if [[ -e "volume/blocks/$DELETE_INODE.bin" ]]; then
    fail "Deleted file block still exists"
fi

stop_ccfs
start_ccfs

[[ ! -e "$MOUNT_DIR/$BASE-delete.txt" ]] ||
    fail "Deleted file returned after restart"

DELETE_COUNT="$(
    sqlite3 "$DB_FILE" \
        "SELECT COUNT(*) FROM entries
         WHERE name='$BASE-delete.txt';"
)"

[[ "$DELETE_COUNT" == "0" ]] ||
    fail "Deleted file metadata returned after restart"

pass "deletion survived restart"

echo
echo "[14] Truncate smaller..."

printf "0123456789ABCDEFGHIJ" > "$MOUNT_DIR/$BASE-truncate.txt"

truncate -s 5 "$MOUNT_DIR/$BASE-truncate.txt"

[[ "$(stat -c '%s' "$MOUNT_DIR/$BASE-truncate.txt")" == "5" ]] ||
    fail "truncate smaller produced wrong size"

[[ "$(cat "$MOUNT_DIR/$BASE-truncate.txt")" == "01234" ]] ||
    fail "truncate smaller produced wrong content"

stop_ccfs
start_ccfs

[[ "$(stat -c '%s' "$MOUNT_DIR/$BASE-truncate.txt")" == "5" ]] ||
    fail "smaller truncate size not persistent"

[[ "$(cat "$MOUNT_DIR/$BASE-truncate.txt")" == "01234" ]] ||
    fail "smaller truncate content not persistent"

pass "truncate smaller persisted"

echo
echo "[15] Truncate larger / zero fill..."

truncate -s 16 "$MOUNT_DIR/$BASE-truncate.txt"

[[ "$(stat -c '%s' "$MOUNT_DIR/$BASE-truncate.txt")" == "16" ]] ||
    fail "truncate larger produced wrong size"

HEX="$(
    od -An -tx1 -v "$MOUNT_DIR/$BASE-truncate.txt" \
        | tr -d ' \n'
)"

EXPECTED_HEX="30313233340000000000000000000000"

[[ "$HEX" == "$EXPECTED_HEX" ]] ||
    fail "truncate larger did not zero-fill extension"

stop_ccfs
start_ccfs

HEX="$(
    od -An -tx1 -v "$MOUNT_DIR/$BASE-truncate.txt" \
        | tr -d ' \n'
)"

[[ "$HEX" == "$EXPECTED_HEX" ]] ||
    fail "zero-filled truncate extension not persistent"

pass "truncate larger persisted with zero fill"

echo
echo "[16] Permission persistence..."

printf "permissions\n" > "$MOUNT_DIR/$BASE-perm.txt"

chmod 600 "$MOUNT_DIR/$BASE-perm.txt"

[[ "$(stat -c '%a' "$MOUNT_DIR/$BASE-perm.txt")" == "600" ]] ||
    fail "chmod did not update mode"

stop_ccfs
start_ccfs

[[ "$(stat -c '%a' "$MOUNT_DIR/$BASE-perm.txt")" == "600" ]] ||
    fail "permissions not preserved after restart"

pass "permissions persisted"

echo
echo "[17] Nested directory restart persistence..."

mkdir "$MOUNT_DIR/$DIR_B"
mkdir "$MOUNT_DIR/$DIR_C"

printf "nested-persist\n" > "$MOUNT_DIR/$DIR_B/file.txt"

stop_ccfs
start_ccfs

[[ -d "$MOUNT_DIR/$DIR_B" ]] ||
    fail "Nested test directory missing after restart"

[[ -f "$MOUNT_DIR/$DIR_B/file.txt" ]] ||
    fail "Nested file missing after restart"

[[ "$(cat "$MOUNT_DIR/$DIR_B/file.txt")" == "nested-persist" ]] ||
    fail "Nested file content corrupted after restart"

pass "nested directory/file persisted"

echo
echo "[18] Larger binary file..."

dd \
    if=/dev/urandom \
    of="/tmp/$BASE-source.bin" \
    bs=1024 \
    count=64 \
    status=none

cp \
    "/tmp/$BASE-source.bin" \
    "$MOUNT_DIR/$BASE-large.bin"

SOURCE_HASH="$(sha256sum "/tmp/$BASE-source.bin" | awk '{print $1}')"
MOUNT_HASH="$(sha256sum "$MOUNT_DIR/$BASE-large.bin" | awk '{print $1}')"

[[ "$SOURCE_HASH" == "$MOUNT_HASH" ]] ||
    fail "Large file hash mismatch before restart"

stop_ccfs
start_ccfs

RESTART_HASH="$(sha256sum "$MOUNT_DIR/$BASE-large.bin" | awk '{print $1}')"

[[ "$SOURCE_HASH" == "$RESTART_HASH" ]] ||
    fail "Large file hash mismatch after restart"

pass "64 KiB binary file persisted exactly"

echo
echo "[19] Repeated mount/unmount..."

for round in 1 2 3; do
    stop_ccfs
    start_ccfs

    [[ -f "$MOUNT_DIR/$BASE-large.bin" ]] ||
        fail "File missing during mount cycle $round"

    echo "mount cycle $round passed"
done

pass "repeated mount/unmount"

echo
echo "[20] Cleanup and metadata verification..."

rm -f "$MOUNT_DIR/$DIR_A/file.txt"
rmdir "$MOUNT_DIR/$DIR_A/child"
rmdir "$MOUNT_DIR/$DIR_A"

rm -f "$MOUNT_DIR/$DIR_B/file.txt"
rmdir "$MOUNT_DIR/$DIR_B"
rmdir "$MOUNT_DIR/$DIR_C"

rm -f "$MOUNT_DIR/$BASE-empty.txt"
rm -f "$MOUNT_DIR/$BASE-renamed.txt"
rm -f "$MOUNT_DIR/$BASE-rename-source.txt"
rm -f "$MOUNT_DIR/$BASE-rename-dest.txt"
rm -f "$MOUNT_DIR/$BASE-truncate.txt"
rm -f "$MOUNT_DIR/$BASE-perm.txt"
rm -f "$MOUNT_DIR/$BASE-large.bin"

LEFTOVER_COUNT="$(
    sqlite3 "$DB_FILE" \
        "SELECT COUNT(*)
         FROM entries
         WHERE name LIKE '$BASE%';"
)"

[[ "$LEFTOVER_COUNT" == "0" ]] ||
    fail "Edge-case test metadata was not fully cleaned up"

stop_ccfs

trap - EXIT INT TERM

rm -f "/tmp/$BASE-source.bin"
rm -f /tmp/ccfs-edge-command.out

echo
echo "========================================"
echo " ALL CCFS EDGE-CASE TESTS PASSED"
echo "========================================"
echo