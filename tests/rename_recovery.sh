#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

MOUNT_DIR="mount"
LOG_FILE="/tmp/ccfs-rename-recovery.log"
STATUS_FILE="/tmp/ccfs-rename-recovery-status.txt"
INTEGRITY_FILE="/tmp/ccfs-rename-recovery-integrity.txt"

RUN_ID="$(date +%s)"

SRC_DIR="rename-src-$RUN_ID"
DST_DIR="rename-dst-$RUN_ID"

ORIGINAL_NAME="original-$RUN_ID.txt"
NORMAL_NAME="normal-renamed-$RUN_ID.txt"
RECOVERED_NAME="recovered-$RUN_ID.txt"
INCOMPLETE_NAME="incomplete-$RUN_ID.txt"

EXPECTED_CONTENT="CCFS rename recovery data $RUN_ID"

CCFS_PID=""
FILE_INO=""
SRC_INO=""
DST_INO=""

pass() {
    echo "PASS: $1"
}

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

start_ccfs() {
    stop_ccfs

    : > "$LOG_FILE"

    ./target/debug/ccfs >"$LOG_FILE" 2>&1 &
    CCFS_PID=$!

    for _ in $(seq 1 80); do
        if is_mounted; then
            return 0
        fi

        if ! kill -0 "$CCFS_PID" 2>/dev/null; then
            fail "CCFS exited before mount completed"
        fi

        sleep 0.1
    done

    fail "Timed out waiting for CCFS mount"
}

clear_recovery_state() {
    : > volume/journal.log

    sqlite3 volume/metadata.db \
        "DELETE FROM applied_tx;"
}

assert_content() {
    local path="$1"

    local actual

    actual="$(cat "$path")"

    [[ "$actual" == "$EXPECTED_CONTENT" ]] ||
        fail "file contents changed during rename"
}

append_rename_transaction() {
    local txid="$1"
    local ino="$2"
    local new_parent="$3"
    local new_name="$4"
    local committed="$5"

    python3 - \
        "$txid" \
        "$ino" \
        "$new_parent" \
        "$new_name" \
        "$committed" <<'PY'
import os
import sqlite3
import struct
import sys
import time
from pathlib import Path

txid = int(sys.argv[1])
ino = int(sys.argv[2])
new_parent = int(sys.argv[3])
new_name = sys.argv[4]
committed = sys.argv[5] == "yes"

conn = sqlite3.connect("volume/metadata.db")

row = conn.execute(
    """
    SELECT
        kind,
        perm,
        size,
        atime,
        mtime,
        ctime
    FROM entries
    WHERE ino = ?
    """,
    (ino,),
).fetchone()

conn.close()

if row is None:
    raise SystemExit(
        f"metadata for inode {ino} does not exist"
    )

kind, perm, size, atime, mtime, _ctime = row

is_dir = 1 if kind != 0 else 0
ctime = int(time.time())

name_bytes = new_name.encode("utf-8")

MAGIC = b"CCFSREN1"

payload = (
    MAGIC
    + struct.pack("<Q", ino)
    + struct.pack("<Q", new_parent)
    + struct.pack("<B", is_dir)
    + struct.pack("<H", perm)
    + struct.pack("<Q", size)
    + struct.pack("<q", atime)
    + struct.pack("<q", mtime)
    + struct.pack("<q", ctime)
    + struct.pack("<I", len(name_bytes))
    + name_bytes
)

def fnv1a64(data: bytes) -> int:
    h = 0xcbf29ce484222325
    prime = 0x100000001b3

    for byte in data:
        h ^= byte
        h = (h * prime) & 0xffffffffffffffff

    return h

def record(body: str) -> str:
    value = fnv1a64(body.encode("ascii"))
    return f"{body}|{value:016x}\n"

operation_hex = b"RENAME".hex()
payload_hex = payload.hex()

begin_body = (
    f"BEGIN|{txid}|{operation_hex}|{payload_hex}"
)

journal_path = Path("volume/journal.log")
journal_path.parent.mkdir(parents=True, exist_ok=True)

with journal_path.open("a", encoding="ascii") as journal:
    journal.write(record(begin_body))

    if committed:
        journal.write(
            record(f"COMMIT|{txid}")
        )

    journal.flush()
    os.fsync(journal.fileno())
PY
}

cleanup() {
    set +e

    if is_mounted; then
        rm -f \
            "$MOUNT_DIR/$SRC_DIR/$ORIGINAL_NAME" \
            "$MOUNT_DIR/$SRC_DIR/$NORMAL_NAME" \
            "$MOUNT_DIR/$SRC_DIR/$RECOVERED_NAME" \
            "$MOUNT_DIR/$SRC_DIR/$INCOMPLETE_NAME" \
            "$MOUNT_DIR/$DST_DIR/$ORIGINAL_NAME" \
            "$MOUNT_DIR/$DST_DIR/$NORMAL_NAME" \
            "$MOUNT_DIR/$DST_DIR/$RECOVERED_NAME" \
            "$MOUNT_DIR/$DST_DIR/$INCOMPLETE_NAME" \
            2>/dev/null || true

        rmdir "$MOUNT_DIR/$SRC_DIR" 2>/dev/null || true
        rmdir "$MOUNT_DIR/$DST_DIR" 2>/dev/null || true
    fi

    stop_ccfs

    if [[ -n "${FILE_INO:-}" ]]; then
        sqlite3 volume/metadata.db \
            "DELETE FROM entries WHERE ino=$FILE_INO;" \
            >/dev/null 2>&1 || true

        rm -f "volume/blocks/$FILE_INO.bin"
        rm -f "volume/blocks/$FILE_INO.checksum"
    fi

    sqlite3 volume/metadata.db \
        "DELETE FROM entries
         WHERE name IN ('$SRC_DIR', '$DST_DIR');" \
        >/dev/null 2>&1 || true

    sqlite3 volume/metadata.db \
        "DELETE FROM applied_tx;" \
        >/dev/null 2>&1 || true

    : > volume/journal.log

    rm -f "$STATUS_FILE"
    rm -f "$INTEGRITY_FILE"

    set -e
}

trap cleanup EXIT INT TERM

echo
echo "========================================"
echo " CCFS RENAME Recovery Test Suite"
echo "========================================"
echo

echo "[1/11] Building CCFS..."

cargo build --bin ccfs >/dev/null

pass "cargo build"

echo
echo "[2/11] Preparing directories and file..."

stop_ccfs

./target/debug/ccfs \
    --recovery-status \
    >/dev/null

clear_recovery_state

start_ccfs

mkdir "$MOUNT_DIR/$SRC_DIR"
mkdir "$MOUNT_DIR/$DST_DIR"

printf '%s' "$EXPECTED_CONTENT" \
    > "$MOUNT_DIR/$SRC_DIR/$ORIGINAL_NAME"

FILE_INO="$(
    stat -c '%i' \
        "$MOUNT_DIR/$SRC_DIR/$ORIGINAL_NAME"
)"

SRC_INO="$(
    stat -c '%i' \
        "$MOUNT_DIR/$SRC_DIR"
)"

DST_INO="$(
    stat -c '%i' \
        "$MOUNT_DIR/$DST_DIR"
)"

[[ -n "$FILE_INO" ]] ||
    fail "file inode missing"

[[ -n "$SRC_INO" ]] ||
    fail "source directory inode missing"

[[ -n "$DST_INO" ]] ||
    fail "destination directory inode missing"

assert_content \
    "$MOUNT_DIR/$SRC_DIR/$ORIGINAL_NAME"

stop_ccfs

# Ignore CREATE/WRITE setup journal history.
clear_recovery_state

pass "isolated rename test state ready"

echo
echo "[3/11] Normal cross-directory RENAME..."

start_ccfs

mv \
    "$MOUNT_DIR/$SRC_DIR/$ORIGINAL_NAME" \
    "$MOUNT_DIR/$DST_DIR/$NORMAL_NAME"

[[ ! -e \
    "$MOUNT_DIR/$SRC_DIR/$ORIGINAL_NAME" ]] ||
    fail "old path still exists after rename"

[[ -f \
    "$MOUNT_DIR/$DST_DIR/$NORMAL_NAME" ]] ||
    fail "new path missing after rename"

NORMAL_INO="$(
    stat -c '%i' \
        "$MOUNT_DIR/$DST_DIR/$NORMAL_NAME"
)"

[[ "$NORMAL_INO" == "$FILE_INO" ]] ||
    fail "rename changed inode identity"

assert_content \
    "$MOUNT_DIR/$DST_DIR/$NORMAL_NAME"

stop_ccfs

APPLIED_COUNT="$(
    sqlite3 volume/metadata.db \
        "SELECT COUNT(*) FROM applied_tx;"
)"

[[ "$APPLIED_COUNT" == "1" ]] ||
    fail "normal RENAME not marked applied"

pass "normal rename journaled and applied"

echo
echo "[4/11] Restart idempotency..."

start_ccfs

[[ -f \
    "$MOUNT_DIR/$DST_DIR/$NORMAL_NAME" ]] ||
    fail "renamed file missing after restart"

[[ ! -e \
    "$MOUNT_DIR/$SRC_DIR/$ORIGINAL_NAME" ]] ||
    fail "old filename returned after restart"

assert_content \
    "$MOUNT_DIR/$DST_DIR/$NORMAL_NAME"

grep -q \
    "replayed: 0" \
    "$LOG_FILE" ||
    fail "normal rename replayed unexpectedly"

grep -q \
    "already applied: 1" \
    "$LOG_FILE" ||
    fail "normal rename not recognized as applied"

stop_ccfs

pass "normal rename survived restart without duplicate replay"

echo
echo "[5/11] Checking integrity after normal rename..."

./target/debug/ccfs \
    --check-integrity \
    >"$INTEGRITY_FILE"

grep -q \
    "ALL CCFS BLOCKS PASSED INTEGRITY CHECK" \
    "$INTEGRITY_FILE" ||
    fail "integrity failed after normal rename"

pass "rename preserved data/checksum integrity"

echo
echo "[6/11] Injecting committed-but-not-applied RENAME..."

clear_recovery_state

RECOVER_TXID="$(
    python3 -c 'import time; print(time.time_ns())'
)"

append_rename_transaction \
    "$RECOVER_TXID" \
    "$FILE_INO" \
    "$SRC_INO" \
    "$RECOVERED_NAME" \
    "yes"

CURRENT_NAME="$(
    sqlite3 volume/metadata.db \
        "SELECT name
         FROM entries
         WHERE ino=$FILE_INO;"
)"

[[ "$CURRENT_NAME" == "$NORMAL_NAME" ]] ||
    fail "synthetic rename was applied before recovery"

pass "committed rename injected without applying metadata"

echo
echo "[7/11] Startup replay of committed RENAME..."

start_ccfs

grep -q \
    "replayed: 1" \
    "$LOG_FILE" ||
    fail "startup did not replay committed rename"

[[ -f \
    "$MOUNT_DIR/$SRC_DIR/$RECOVERED_NAME" ]] ||
    fail "recovered rename destination missing"

[[ ! -e \
    "$MOUNT_DIR/$DST_DIR/$NORMAL_NAME" ]] ||
    fail "old path survived recovered rename"

RECOVERED_INO="$(
    stat -c '%i' \
        "$MOUNT_DIR/$SRC_DIR/$RECOVERED_NAME"
)"

[[ "$RECOVERED_INO" == "$FILE_INO" ]] ||
    fail "recovered rename changed inode"

assert_content \
    "$MOUNT_DIR/$SRC_DIR/$RECOVERED_NAME"

stop_ccfs

RECOVER_APPLIED="$(
    sqlite3 volume/metadata.db \
        "SELECT COUNT(*)
         FROM applied_tx
         WHERE txid=$RECOVER_TXID;"
)"

[[ "$RECOVER_APPLIED" == "1" ]] ||
    fail "recovered rename not marked applied"

pass "committed rename recovered successfully"

echo
echo "[8/11] Recovered rename idempotency..."

start_ccfs

grep -q \
    "replayed: 0" \
    "$LOG_FILE" ||
    fail "recovered rename replayed twice"

grep -q \
    "already applied: 1" \
    "$LOG_FILE" ||
    fail "recovered rename not recognized as applied"

[[ -f \
    "$MOUNT_DIR/$SRC_DIR/$RECOVERED_NAME" ]] ||
    fail "recovered file missing on second restart"

assert_content \
    "$MOUNT_DIR/$SRC_DIR/$RECOVERED_NAME"

stop_ccfs

pass "recovered rename is idempotent"

echo
echo "[9/11] Injecting incomplete RENAME..."

INCOMPLETE_TXID=$((RECOVER_TXID + 1))

append_rename_transaction \
    "$INCOMPLETE_TXID" \
    "$FILE_INO" \
    "$DST_INO" \
    "$INCOMPLETE_NAME" \
    "no"

pass "incomplete rename BEGIN injected"

echo
echo "[10/11] Incomplete RENAME must be ignored..."

start_ccfs

grep -q \
    "incomplete ignored: 1" \
    "$LOG_FILE" ||
    fail "startup did not report incomplete rename"

grep -q \
    "replayed: 0" \
    "$LOG_FILE" ||
    fail "incomplete rename caused replay"

[[ -f \
    "$MOUNT_DIR/$SRC_DIR/$RECOVERED_NAME" ]] ||
    fail "current file disappeared"

[[ ! -e \
    "$MOUNT_DIR/$DST_DIR/$INCOMPLETE_NAME" ]] ||
    fail "incomplete rename became visible"

assert_content \
    "$MOUNT_DIR/$SRC_DIR/$RECOVERED_NAME"

stop_ccfs

INCOMPLETE_APPLIED="$(
    sqlite3 volume/metadata.db \
        "SELECT COUNT(*)
         FROM applied_tx
         WHERE txid=$INCOMPLETE_TXID;"
)"

[[ "$INCOMPLETE_APPLIED" == "0" ]] ||
    fail "incomplete rename was marked applied"

pass "incomplete rename safely ignored"

echo
echo "[11/11] Final status and cleanup..."

./target/debug/ccfs \
    --recovery-status \
    >"$STATUS_FILE"

cat "$STATUS_FILE"

grep -q \
    "Total transactions:          2" \
    "$STATUS_FILE" ||
    fail "unexpected transaction total"

grep -q \
    "Committed transactions:      1" \
    "$STATUS_FILE" ||
    fail "unexpected committed count"

grep -q \
    "Incomplete transactions:     1" \
    "$STATUS_FILE" ||
    fail "unexpected incomplete count"

grep -q \
    "Already applied transactions:1" \
    "$STATUS_FILE" ||
    fail "unexpected applied count"

start_ccfs

rm "$MOUNT_DIR/$SRC_DIR/$RECOVERED_NAME"

rmdir "$MOUNT_DIR/$SRC_DIR"
rmdir "$MOUNT_DIR/$DST_DIR"

stop_ccfs

FILE_INO=""

clear_recovery_state

./target/debug/ccfs \
    --check-integrity \
    >"$INTEGRITY_FILE"

grep -q \
    "ALL CCFS BLOCKS PASSED INTEGRITY CHECK" \
    "$INTEGRITY_FILE" ||
    fail "integrity failed after rename cleanup"

trap - EXIT INT TERM

rm -f "$STATUS_FILE"
rm -f "$INTEGRITY_FILE"

echo
echo "========================================"
echo " ALL CCFS RENAME RECOVERY TESTS PASSED"
echo "========================================"
echo