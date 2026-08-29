#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

MOUNT_DIR="mount"
DB_FILE="volume/metadata.db"
LOG_FILE="/tmp/ccfs-rename-replace.log"
INTEGRITY_LOG="/tmp/ccfs-rename-replace-integrity.log"

RUN_ID="$(date +%s)"

SRC_FILE="rr-src-$RUN_ID.txt"
DST_FILE="rr-dst-$RUN_ID.txt"

SRC_DIR="rr-src-dir-$RUN_ID"
DST_DIR="rr-dst-dir-$RUN_ID"

TYPE_FILE="rr-type-file-$RUN_ID.txt"
TYPE_DIR="rr-type-dir-$RUN_ID"

NONEMPTY_SRC="rr-nonempty-src-$RUN_ID"
NONEMPTY_DST="rr-nonempty-dst-$RUN_ID"

SRC_CONTENT="CCFS rename replacement source data"
DST_CONTENT="CCFS old destination data"

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

cleanup_paths() {
    set +e

    if is_mounted; then
        rm -f "$MOUNT_DIR/$SRC_FILE"
        rm -f "$MOUNT_DIR/$DST_FILE"

        rm -f "$MOUNT_DIR/$TYPE_FILE"
        rm -rf "$MOUNT_DIR/$TYPE_DIR"

        rm -rf "$MOUNT_DIR/$SRC_DIR"
        rm -rf "$MOUNT_DIR/$DST_DIR"

        rm -rf "$MOUNT_DIR/$NONEMPTY_SRC"
        rm -rf "$MOUNT_DIR/$NONEMPTY_DST"
    fi

    set -e
}

cleanup() {
    cleanup_paths
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
echo " CCFS POSIX RENAME-REPLACE TEST"
echo "========================================"
echo

mkdir -p "$MOUNT_DIR"
mkdir -p volume/blocks

if is_mounted; then
    echo "Removing stale CCFS mount..."
    fusermount3 -u "$MOUNT_DIR"
fi

echo "[1/12] Building CCFS..."
cargo build --bin ccfs

start_ccfs

echo "[2/12] Creating source and destination files..."

printf '%s' "$SRC_CONTENT" > "$MOUNT_DIR/$SRC_FILE"
printf '%s' "$DST_CONTENT" > "$MOUNT_DIR/$DST_FILE"

SRC_INODE="$(stat -c '%i' "$MOUNT_DIR/$SRC_FILE")"
OLD_DST_INODE="$(stat -c '%i' "$MOUNT_DIR/$DST_FILE")"

[[ "$SRC_INODE" != "$OLD_DST_INODE" ]] ||
    fail "Source and destination unexpectedly have same inode"

[[ -f "volume/blocks/$SRC_INODE.bin" ]] ||
    fail "Source block missing before replacement"

[[ -f "volume/blocks/$OLD_DST_INODE.bin" ]] ||
    fail "Destination block missing before replacement"

echo "[3/12] Replacing existing file with POSIX rename()..."

python3 - \
    "$MOUNT_DIR/$SRC_FILE" \
    "$MOUNT_DIR/$DST_FILE" <<'PY'
import os
import sys

source = sys.argv[1]
destination = sys.argv[2]

os.rename(source, destination)
PY

[[ ! -e "$MOUNT_DIR/$SRC_FILE" ]] ||
    fail "Old source pathname still exists after replacement"

[[ -f "$MOUNT_DIR/$DST_FILE" ]] ||
    fail "Destination pathname missing after replacement"

NEW_DST_INODE="$(stat -c '%i' "$MOUNT_DIR/$DST_FILE")"

[[ "$NEW_DST_INODE" == "$SRC_INODE" ]] ||
    fail "Source inode was not preserved during file replacement"

REPLACED_CONTENT="$(cat "$MOUNT_DIR/$DST_FILE")"

[[ "$REPLACED_CONTENT" == "$SRC_CONTENT" ]] ||
    fail "Destination does not contain source content after replacement"

echo "[4/12] Verifying replaced destination cleanup..."

OLD_DST_METADATA_COUNT="$(
    sqlite3 "$DB_FILE" \
        "SELECT COUNT(*)
         FROM entries
         WHERE ino=$OLD_DST_INODE;"
)"

[[ "$OLD_DST_METADATA_COUNT" == "0" ]] ||
    fail "Old destination metadata still exists"

[[ ! -e "volume/blocks/$OLD_DST_INODE.bin" ]] ||
    fail "Old destination data block still exists"

[[ ! -e "volume/blocks/$OLD_DST_INODE.checksum" ]] ||
    fail "Old destination checksum still exists"

NEW_METADATA_COUNT="$(
    sqlite3 "$DB_FILE" \
        "SELECT COUNT(*)
         FROM entries
         WHERE ino=$SRC_INODE
           AND name='$DST_FILE';"
)"

[[ "$NEW_METADATA_COUNT" == "1" ]] ||
    fail "Source metadata was not renamed onto destination pathname"

echo "[5/12] Testing directory -> empty-directory replacement..."

mkdir "$MOUNT_DIR/$SRC_DIR"
mkdir "$MOUNT_DIR/$DST_DIR"

SRC_DIR_INODE="$(stat -c '%i' "$MOUNT_DIR/$SRC_DIR")"
OLD_DST_DIR_INODE="$(stat -c '%i' "$MOUNT_DIR/$DST_DIR")"

python3 - \
    "$MOUNT_DIR/$SRC_DIR" \
    "$MOUNT_DIR/$DST_DIR" <<'PY'
import os
import sys

source = sys.argv[1]
destination = sys.argv[2]

os.rename(source, destination)
PY

[[ ! -e "$MOUNT_DIR/$SRC_DIR" ]] ||
    fail "Old source directory pathname still exists"

[[ -d "$MOUNT_DIR/$DST_DIR" ]] ||
    fail "Replacement destination directory missing"

NEW_DST_DIR_INODE="$(stat -c '%i' "$MOUNT_DIR/$DST_DIR")"

[[ "$NEW_DST_DIR_INODE" == "$SRC_DIR_INODE" ]] ||
    fail "Source directory inode was not preserved"

OLD_DST_DIR_COUNT="$(
    sqlite3 "$DB_FILE" \
        "SELECT COUNT(*)
         FROM entries
         WHERE ino=$OLD_DST_DIR_INODE;"
)"

[[ "$OLD_DST_DIR_COUNT" == "0" ]] ||
    fail "Old destination directory metadata still exists"

echo "[6/12] Testing file -> directory rejection..."

printf 'type-file' > "$MOUNT_DIR/$TYPE_FILE"
mkdir "$MOUNT_DIR/$TYPE_DIR"

python3 - \
    "$MOUNT_DIR/$TYPE_FILE" \
    "$MOUNT_DIR/$TYPE_DIR" <<'PY'
import errno
import os
import sys

source = sys.argv[1]
destination = sys.argv[2]

try:
    os.rename(source, destination)
except OSError as error:
    if error.errno != errno.EISDIR:
        raise SystemExit(
            f"expected EISDIR ({errno.EISDIR}), got {error.errno}: {error}"
        )
else:
    raise SystemExit("file -> directory rename unexpectedly succeeded")
PY

[[ -f "$MOUNT_DIR/$TYPE_FILE" ]] ||
    fail "Source file disappeared after rejected file->directory rename"

[[ -d "$MOUNT_DIR/$TYPE_DIR" ]] ||
    fail "Destination directory disappeared after rejected rename"

echo "[7/12] Testing directory -> file rejection..."

python3 - \
    "$MOUNT_DIR/$TYPE_DIR" \
    "$MOUNT_DIR/$TYPE_FILE" <<'PY'
import errno
import os
import sys

source = sys.argv[1]
destination = sys.argv[2]

try:
    os.rename(source, destination)
except OSError as error:
    if error.errno != errno.ENOTDIR:
        raise SystemExit(
            f"expected ENOTDIR ({errno.ENOTDIR}), got {error.errno}: {error}"
        )
else:
    raise SystemExit("directory -> file rename unexpectedly succeeded")
PY

[[ -d "$MOUNT_DIR/$TYPE_DIR" ]] ||
    fail "Source directory disappeared after rejected dir->file rename"

[[ -f "$MOUNT_DIR/$TYPE_FILE" ]] ||
    fail "Destination file disappeared after rejected rename"

echo "[8/12] Testing non-empty destination directory protection..."

mkdir "$MOUNT_DIR/$NONEMPTY_SRC"
mkdir "$MOUNT_DIR/$NONEMPTY_DST"

printf 'child-data' > "$MOUNT_DIR/$NONEMPTY_DST/child.txt"

python3 - \
    "$MOUNT_DIR/$NONEMPTY_SRC" \
    "$MOUNT_DIR/$NONEMPTY_DST" <<'PY'
import errno
import os
import sys

source = sys.argv[1]
destination = sys.argv[2]

try:
    os.rename(source, destination)
except OSError as error:
    if error.errno not in (errno.ENOTEMPTY, errno.EEXIST):
        raise SystemExit(
            f"expected ENOTEMPTY/EEXIST, got {error.errno}: {error}"
        )
else:
    raise SystemExit(
        "directory replacement over non-empty destination unexpectedly succeeded"
    )
PY

[[ -d "$MOUNT_DIR/$NONEMPTY_SRC" ]] ||
    fail "Source directory disappeared after ENOTEMPTY rejection"

[[ -f "$MOUNT_DIR/$NONEMPTY_DST/child.txt" ]] ||
    fail "Non-empty destination contents were damaged"

echo "[9/12] Restarting CCFS..."

stop_ccfs
start_ccfs

[[ -f "$MOUNT_DIR/$DST_FILE" ]] ||
    fail "Replaced file missing after restart"

RESTART_FILE_INODE="$(stat -c '%i' "$MOUNT_DIR/$DST_FILE")"

[[ "$RESTART_FILE_INODE" == "$SRC_INODE" ]] ||
    fail "Replaced file inode changed after restart"

RESTART_CONTENT="$(cat "$MOUNT_DIR/$DST_FILE")"

[[ "$RESTART_CONTENT" == "$SRC_CONTENT" ]] ||
    fail "Replaced file content changed after restart"

[[ -d "$MOUNT_DIR/$DST_DIR" ]] ||
    fail "Replaced directory missing after restart"

RESTART_DIR_INODE="$(stat -c '%i' "$MOUNT_DIR/$DST_DIR")"

[[ "$RESTART_DIR_INODE" == "$SRC_DIR_INODE" ]] ||
    fail "Replaced directory inode changed after restart"

echo "[10/12] Verifying rejected operations persisted unchanged..."

[[ -f "$MOUNT_DIR/$TYPE_FILE" ]] ||
    fail "Type-test file missing after restart"

[[ -d "$MOUNT_DIR/$TYPE_DIR" ]] ||
    fail "Type-test directory missing after restart"

[[ -d "$MOUNT_DIR/$NONEMPTY_SRC" ]] ||
    fail "Non-empty test source directory missing after restart"

[[ -f "$MOUNT_DIR/$NONEMPTY_DST/child.txt" ]] ||
    fail "Non-empty destination child missing after restart"

echo "[11/12] Running integrity verification..."

./target/debug/ccfs --check-integrity >"$INTEGRITY_LOG" 2>&1 || {
    cat "$INTEGRITY_LOG"
    fail "Integrity verification failed"
}

grep -q \
    "ALL CCFS BLOCKS PASSED INTEGRITY CHECK" \
    "$INTEGRITY_LOG" ||
    fail "Integrity success marker missing"

echo "[12/12] Cleaning test data..."

rm "$MOUNT_DIR/$DST_FILE"

rm "$MOUNT_DIR/$TYPE_FILE"
rmdir "$MOUNT_DIR/$TYPE_DIR"

rmdir "$MOUNT_DIR/$DST_DIR"

rm "$MOUNT_DIR/$NONEMPTY_DST/child.txt"
rmdir "$MOUNT_DIR/$NONEMPTY_DST"
rmdir "$MOUNT_DIR/$NONEMPTY_SRC"

stop_ccfs

trap - EXIT INT TERM

echo
echo "========================================"
echo " ALL CCFS RENAME-REPLACE TESTS PASSED"
echo "========================================"
echo
