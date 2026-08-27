#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

MOUNT_DIR="mount"
DB_FILE="volume/metadata.db"
LOG_FILE="/tmp/ccfs-integration-test.log"

RUN_ID="$(date +%s)"
SRC_DIR="it-src-$RUN_ID"
DST_DIR="it-dst-$RUN_ID"

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

cleanup_test_files() {
    set +e

    if is_mounted; then
        rm -f "$MOUNT_DIR/$SRC_DIR/a.txt"
        rm -f "$MOUNT_DIR/$SRC_DIR/b.txt"
        rm -f "$MOUNT_DIR/$DST_DIR/final.txt"

        rmdir "$MOUNT_DIR/$SRC_DIR" 2>/dev/null || true
        rmdir "$MOUNT_DIR/$DST_DIR" 2>/dev/null || true
    fi

    set -e
}

cleanup() {
    cleanup_test_files
    stop_ccfs
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
echo " CCFS Integration Test"
echo "========================================"
echo

mkdir -p "$MOUNT_DIR"
mkdir -p volume/blocks

if is_mounted; then
    echo "Removing stale CCFS mount..."
    fusermount3 -u "$MOUNT_DIR"
fi

echo "[1/9] Building project..."
cargo build

start_ccfs

echo "[2/9] Creating directory..."
mkdir "$MOUNT_DIR/$SRC_DIR"

[[ -d "$MOUNT_DIR/$SRC_DIR" ]] ||
    fail "Directory creation failed"

echo "[3/9] Creating and reading file..."
printf "CCFS integration data\n" > "$MOUNT_DIR/$SRC_DIR/a.txt"

CONTENT="$(cat "$MOUNT_DIR/$SRC_DIR/a.txt")"

[[ "$CONTENT" == "CCFS integration data" ]] ||
    fail "Initial file content mismatch"

ORIGINAL_INODE="$(stat -c '%i' "$MOUNT_DIR/$SRC_DIR/a.txt")"

echo "[4/9] Renaming file inside directory..."
mv \
    "$MOUNT_DIR/$SRC_DIR/a.txt" \
    "$MOUNT_DIR/$SRC_DIR/b.txt"

[[ ! -e "$MOUNT_DIR/$SRC_DIR/a.txt" ]] ||
    fail "Old filename still exists after rename"

[[ -f "$MOUNT_DIR/$SRC_DIR/b.txt" ]] ||
    fail "Renamed file does not exist"

RENAMED_INODE="$(stat -c '%i' "$MOUNT_DIR/$SRC_DIR/b.txt")"

[[ "$ORIGINAL_INODE" == "$RENAMED_INODE" ]] ||
    fail "Inode changed during rename"

echo "[5/9] Moving file across directories..."
mkdir "$MOUNT_DIR/$DST_DIR"

mv \
    "$MOUNT_DIR/$SRC_DIR/b.txt" \
    "$MOUNT_DIR/$DST_DIR/final.txt"

[[ -f "$MOUNT_DIR/$DST_DIR/final.txt" ]] ||
    fail "Cross-directory move failed"

MOVED_CONTENT="$(cat "$MOUNT_DIR/$DST_DIR/final.txt")"

[[ "$MOVED_CONTENT" == "CCFS integration data" ]] ||
    fail "Content changed after cross-directory move"

MOVED_INODE="$(stat -c '%i' "$MOUNT_DIR/$DST_DIR/final.txt")"

[[ "$ORIGINAL_INODE" == "$MOVED_INODE" ]] ||
    fail "Inode changed during cross-directory move"

echo "[6/9] Checking SQLite metadata..."

FILE_COUNT="$(
    sqlite3 "$DB_FILE" \
        "SELECT COUNT(*) FROM entries
         WHERE name='final.txt'
         AND parent=(
             SELECT ino FROM entries
             WHERE name='$DST_DIR'
             LIMIT 1
         );"
)"

[[ "$FILE_COUNT" == "1" ]] ||
    fail "SQLite metadata does not contain moved file"

echo "[7/9] Testing restart persistence..."

stop_ccfs
start_ccfs

[[ -d "$MOUNT_DIR/$DST_DIR" ]] ||
    fail "Destination directory missing after restart"

[[ -f "$MOUNT_DIR/$DST_DIR/final.txt" ]] ||
    fail "File missing after restart"

RESTART_CONTENT="$(cat "$MOUNT_DIR/$DST_DIR/final.txt")"

[[ "$RESTART_CONTENT" == "CCFS integration data" ]] ||
    fail "File contents not preserved after restart"

RESTART_INODE="$(stat -c '%i' "$MOUNT_DIR/$DST_DIR/final.txt")"

[[ "$ORIGINAL_INODE" == "$RESTART_INODE" ]] ||
    fail "Inode not preserved after restart"

echo "[8/9] Testing persistent deletion..."

rm "$MOUNT_DIR/$DST_DIR/final.txt"

[[ ! -e "$MOUNT_DIR/$DST_DIR/final.txt" ]] ||
    fail "File still exists after rm"

FILE_COUNT="$(
    sqlite3 "$DB_FILE" \
        "SELECT COUNT(*) FROM entries
         WHERE name='final.txt';"
)"

[[ "$FILE_COUNT" == "0" ]] ||
    fail "Deleted file still exists in SQLite"

if [[ -e "volume/blocks/$ORIGINAL_INODE.bin" ]]; then
    fail "Deleted file block still exists"
fi

echo "[9/9] Testing directory removal..."

rmdir "$MOUNT_DIR/$SRC_DIR"
rmdir "$MOUNT_DIR/$DST_DIR"

[[ ! -e "$MOUNT_DIR/$SRC_DIR" ]] ||
    fail "Source directory still exists"

[[ ! -e "$MOUNT_DIR/$DST_DIR" ]] ||
    fail "Destination directory still exists"

stop_ccfs

trap - EXIT INT TERM

echo
echo "========================================"
echo " ALL CCFS INTEGRATION TESTS PASSED"
echo "========================================"
echo