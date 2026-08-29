#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

MOUNT_DIR="mount"

LOG_FILE="/tmp/ccfs-truncate-recovery.log"
STATUS_FILE="/tmp/ccfs-truncate-recovery-status.txt"
INTEGRITY_FILE="/tmp/ccfs-truncate-recovery-integrity.txt"

RUN_ID="$(date +%s)"

NORMAL_NAME="truncate-normal-$RUN_ID.txt"
RECOVER_NAME="truncate-recover-$RUN_ID.txt"
INCOMPLETE_NAME="truncate-incomplete-$RUN_ID.txt"

NORMAL_CONTENT="NORMAL-TRUNCATE-CONTENT-$RUN_ID"
RECOVER_CONTENT="GROW"
INCOMPLETE_CONTENT="INCOMPLETE-TRUNCATE-CONTENT-$RUN_ID"

NORMAL_TARGET_SIZE=8
RECOVER_TARGET_SIZE=12
INCOMPLETE_TARGET_SIZE=5

CCFS_PID=""

NORMAL_INO=""
RECOVER_INO=""
INCOMPLETE_INO=""

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
    mountpoint -q "$MOUNT_DIR" 2>/dev/null
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

    ./target/debug/ccfs \
        >"$LOG_FILE" 2>&1 &

    CCFS_PID=$!

    for _ in $(seq 1 100); do
        if is_mounted; then
            return 0
        fi

        if ! kill -0 "$CCFS_PID" 2>/dev/null; then
            fail "CCFS exited before mount completed"
        fi

        sleep 0.05
    done

    fail "Timed out waiting for CCFS mount"
}

clear_recovery_state() {
    : > volume/journal.log

    sqlite3 volume/metadata.db \
        "DELETE FROM applied_tx;"
}

metadata_count() {
    local ino="$1"

    sqlite3 volume/metadata.db \
        "SELECT COUNT(*)
         FROM entries
         WHERE ino=$ino;"
}

metadata_size() {
    local ino="$1"

    sqlite3 volume/metadata.db \
        "SELECT size
         FROM entries
         WHERE ino=$ino;"
}

assert_file_prefix_size() {
    local path="$1"
    local expected_prefix="$2"
    local expected_size="$3"

    python3 - \
        "$path" \
        "$expected_prefix" \
        "$expected_size" <<'PY'
import sys

path = sys.argv[1]
expected_prefix = sys.argv[2].encode("utf-8")
expected_size = int(sys.argv[3])

with open(path, "rb") as f:
    data = f.read()

if len(data) != expected_size:
    print(
        f"Expected size {expected_size}, "
        f"actual size {len(data)}"
    )
    raise SystemExit(1)

if not data.startswith(expected_prefix):
    print("Expected prefix:", expected_prefix)
    print("Actual data:    ", data)
    raise SystemExit(1)
PY
}

assert_file_exact() {
    local path="$1"
    local expected="$2"

    python3 - \
        "$path" \
        "$expected" <<'PY'
import sys

path = sys.argv[1]
expected = sys.argv[2].encode("utf-8")

with open(path, "rb") as f:
    actual = f.read()

if actual != expected:
    print("Expected:", expected)
    print("Actual:  ", actual)
    raise SystemExit(1)
PY
}

assert_grown_file() {
    local path="$1"
    local prefix="$2"
    local expected_size="$3"

    python3 - \
        "$path" \
        "$prefix" \
        "$expected_size" <<'PY'
import sys

path = sys.argv[1]
prefix = sys.argv[2].encode("utf-8")
expected_size = int(sys.argv[3])

with open(path, "rb") as f:
    data = f.read()

if len(data) != expected_size:
    print(
        f"Expected size {expected_size}, "
        f"actual size {len(data)}"
    )
    raise SystemExit(1)

if data[:len(prefix)] != prefix:
    print("Expected prefix:", prefix)
    print("Actual data:    ", data)
    raise SystemExit(1)

tail = data[len(prefix):]

if tail != b"\x00" * len(tail):
    print("Expected zero-filled growth tail")
    print("Actual tail:", tail)
    raise SystemExit(1)
PY
}

append_truncate_transaction() {
    local txid="$1"
    local ino="$2"
    local target_size="$3"
    local committed="$4"

    python3 - \
        "$txid" \
        "$ino" \
        "$target_size" \
        "$committed" <<'PY'
import os
import sqlite3
import struct
import sys
from pathlib import Path

txid = int(sys.argv[1])
ino = int(sys.argv[2])
target_size = int(sys.argv[3])
committed = sys.argv[4] == "yes"

MAGIC = b"CCFSTRN1"

db = sqlite3.connect("volume/metadata.db")

row = db.execute(
    """
    SELECT
        parent,
        name,
        perm,
        atime,
        mtime,
        ctime
    FROM entries
    WHERE ino = ?
    """,
    (ino,),
).fetchone()

db.close()

if row is None:
    raise SystemExit(
        f"inode {ino} not found in metadata database"
    )

parent, name, perm, atime, mtime, ctime = row

block_path = Path(
    f"volume/blocks/{ino}.bin"
)

if not block_path.exists():
    raise SystemExit(
        f"data block missing for inode {ino}"
    )

current_data = block_path.read_bytes()

if target_size <= len(current_data):
    final_data = current_data[:target_size]
else:
    final_data = (
        current_data
        + b"\x00" * (
            target_size - len(current_data)
        )
    )

name_bytes = name.encode("utf-8")

payload = bytearray()

payload += MAGIC
payload += struct.pack("<Q", ino)
payload += struct.pack("<Q", parent)
payload += struct.pack("<H", perm)

payload += struct.pack(
    "<q",
    atime,
)

payload += struct.pack(
    "<q",
    mtime,
)

payload += struct.pack(
    "<q",
    ctime,
)

payload += struct.pack(
    "<I",
    len(name_bytes),
)

payload += struct.pack(
    "<Q",
    len(final_data),
)

payload += name_bytes
payload += final_data

def fnv1a64(data: bytes) -> int:
    h = 0xcbf29ce484222325
    prime = 0x100000001b3

    for byte in data:
        h ^= byte
        h = (
            h * prime
        ) & 0xffffffffffffffff

    return h

def record(body: str) -> str:
    checksum = fnv1a64(
        body.encode("ascii")
    )

    return (
        f"{body}|"
        f"{checksum:016x}\n"
    )

operation_hex = (
    b"TRUNCATE".hex()
)

payload_hex = (
    bytes(payload).hex()
)

begin_body = (
    f"BEGIN|{txid}|"
    f"{operation_hex}|"
    f"{payload_hex}"
)

journal_path = Path(
    "volume/journal.log"
)

journal_path.parent.mkdir(
    parents=True,
    exist_ok=True,
)

with journal_path.open(
    "a",
    encoding="ascii",
) as journal:
    journal.write(
        record(begin_body)
    )

    if committed:
        journal.write(
            record(
                f"COMMIT|{txid}"
            )
        )

    journal.flush()
    os.fsync(
        journal.fileno()
    )
PY
}

cleanup() {
    set +e

    if is_mounted; then
        rm -f \
            "$MOUNT_DIR/$NORMAL_NAME" \
            "$MOUNT_DIR/$RECOVER_NAME" \
            "$MOUNT_DIR/$INCOMPLETE_NAME" \
            2>/dev/null || true
    fi

    stop_ccfs

    for ino in \
        "${NORMAL_INO:-}" \
        "${RECOVER_INO:-}" \
        "${INCOMPLETE_INO:-}"
    do
        if [[ -n "$ino" ]]; then
            sqlite3 volume/metadata.db \
                "DELETE FROM entries
                 WHERE ino=$ino;" \
                >/dev/null 2>&1 || true

            rm -f \
                "volume/blocks/$ino.bin" \
                "volume/blocks/$ino.checksum"
        fi
    done

    sqlite3 volume/metadata.db \
        "DELETE FROM applied_tx;" \
        >/dev/null 2>&1 || true

    : > volume/journal.log

    rm -f \
        "$STATUS_FILE" \
        "$INTEGRITY_FILE"

    set -e
}

trap cleanup EXIT INT TERM

echo
echo "========================================"
echo " CCFS TRUNCATE Recovery Test Suite"
echo "========================================"
echo

echo "[1/12] Building CCFS..."

cargo build --bin ccfs >/dev/null

pass "cargo build"

echo
echo "[2/12] Preparing isolated test files..."

stop_ccfs

./target/debug/ccfs \
    --recovery-status \
    >/dev/null

clear_recovery_state

start_ccfs

printf '%s' \
    "$NORMAL_CONTENT" \
    > "$MOUNT_DIR/$NORMAL_NAME"

printf '%s' \
    "$RECOVER_CONTENT" \
    > "$MOUNT_DIR/$RECOVER_NAME"

printf '%s' \
    "$INCOMPLETE_CONTENT" \
    > "$MOUNT_DIR/$INCOMPLETE_NAME"

NORMAL_INO="$(
    stat -c '%i' \
        "$MOUNT_DIR/$NORMAL_NAME"
)"

RECOVER_INO="$(
    stat -c '%i' \
        "$MOUNT_DIR/$RECOVER_NAME"
)"

INCOMPLETE_INO="$(
    stat -c '%i' \
        "$MOUNT_DIR/$INCOMPLETE_NAME"
)"

assert_file_exact \
    "$MOUNT_DIR/$NORMAL_NAME" \
    "$NORMAL_CONTENT"

assert_file_exact \
    "$MOUNT_DIR/$RECOVER_NAME" \
    "$RECOVER_CONTENT"

assert_file_exact \
    "$MOUNT_DIR/$INCOMPLETE_NAME" \
    "$INCOMPLETE_CONTENT"

stop_ccfs

# Ignore CREATE/WRITE setup transactions.
clear_recovery_state

pass "isolated TRUNCATE test files ready"

# ============================================================
# NORMAL SHRINK
# ============================================================

echo
echo "[3/12] Normal journaled shrink TRUNCATE..."

start_ccfs

truncate \
    -s "$NORMAL_TARGET_SIZE" \
    "$MOUNT_DIR/$NORMAL_NAME"

assert_file_prefix_size \
    "$MOUNT_DIR/$NORMAL_NAME" \
    "${NORMAL_CONTENT:0:$NORMAL_TARGET_SIZE}" \
    "$NORMAL_TARGET_SIZE"

stop_ccfs

[[ "$(metadata_size "$NORMAL_INO")" == "$NORMAL_TARGET_SIZE" ]] ||
    fail "normal TRUNCATE metadata size incorrect"

APPLIED_COUNT="$(
    sqlite3 volume/metadata.db \
        "SELECT COUNT(*)
         FROM applied_tx;"
)"

[[ "$APPLIED_COUNT" == "1" ]] ||
    fail "normal TRUNCATE transaction not marked applied"

pass "normal shrink TRUNCATE journaled and applied"

# ============================================================
# NORMAL RESTART
# ============================================================

echo
echo "[4/12] Restart idempotency after normal TRUNCATE..."

start_ccfs

assert_file_prefix_size \
    "$MOUNT_DIR/$NORMAL_NAME" \
    "${NORMAL_CONTENT:0:$NORMAL_TARGET_SIZE}" \
    "$NORMAL_TARGET_SIZE"

grep -q \
    "replayed: 0" \
    "$LOG_FILE" ||
    fail "normal TRUNCATE replayed unexpectedly"

grep -q \
    "already applied: 1" \
    "$LOG_FILE" ||
    fail "normal TRUNCATE not recognized as applied"

stop_ccfs

pass "normal TRUNCATE survived restart"

# ============================================================
# INTEGRITY
# ============================================================

echo
echo "[5/12] Checking checksum integrity after shrink..."

./target/debug/ccfs \
    --check-integrity \
    >"$INTEGRITY_FILE"

grep -q \
    "ALL CCFS BLOCKS PASSED INTEGRITY CHECK" \
    "$INTEGRITY_FILE" ||
    fail "integrity failed after normal TRUNCATE"

pass "TRUNCATE data and checksum are healthy"

# ============================================================
# COMMITTED GROW INJECTION
# ============================================================

echo
echo "[6/12] Injecting committed-but-not-applied grow TRUNCATE..."

clear_recovery_state

RECOVER_TXID="$(
    python3 -c \
        'import time; print(time.time_ns())'
)"

append_truncate_transaction \
    "$RECOVER_TXID" \
    "$RECOVER_INO" \
    "$RECOVER_TARGET_SIZE" \
    "yes"

[[ "$(metadata_size "$RECOVER_INO")" == "${#RECOVER_CONTENT}" ]] ||
    fail "recovery target metadata changed before replay"

python3 - \
    "volume/blocks/$RECOVER_INO.bin" \
    "$RECOVER_CONTENT" <<'PY'
import sys

path = sys.argv[1]
expected = sys.argv[2].encode("utf-8")

with open(path, "rb") as f:
    actual = f.read()

if actual != expected:
    print("Block changed before recovery")
    raise SystemExit(1)
PY

pass "committed grow TRUNCATE injected without applying state"

# ============================================================
# COMMITTED REPLAY
# ============================================================

echo
echo "[7/12] Startup replay of committed TRUNCATE..."

start_ccfs

grep -q \
    "replayed: 1" \
    "$LOG_FILE" ||
    fail "startup did not replay committed TRUNCATE"

assert_grown_file \
    "$MOUNT_DIR/$RECOVER_NAME" \
    "$RECOVER_CONTENT" \
    "$RECOVER_TARGET_SIZE"

stop_ccfs

[[ "$(metadata_size "$RECOVER_INO")" == "$RECOVER_TARGET_SIZE" ]] ||
    fail "recovered TRUNCATE metadata size incorrect"

RECOVER_APPLIED="$(
    sqlite3 volume/metadata.db \
        "SELECT COUNT(*)
         FROM applied_tx
         WHERE txid=$RECOVER_TXID;"
)"

[[ "$RECOVER_APPLIED" == "1" ]] ||
    fail "recovered TRUNCATE not marked applied"

pass "committed grow TRUNCATE recovered successfully"

# ============================================================
# RECOVERED IDEMPOTENCY
# ============================================================

echo
echo "[8/12] Recovered TRUNCATE idempotency..."

start_ccfs

grep -q \
    "replayed: 0" \
    "$LOG_FILE" ||
    fail "recovered TRUNCATE replayed twice"

grep -q \
    "already applied: 1" \
    "$LOG_FILE" ||
    fail "recovered TRUNCATE not recognized as applied"

assert_grown_file \
    "$MOUNT_DIR/$RECOVER_NAME" \
    "$RECOVER_CONTENT" \
    "$RECOVER_TARGET_SIZE"

stop_ccfs

pass "recovered TRUNCATE is idempotent"

# ============================================================
# INCOMPLETE INJECTION
# ============================================================

echo
echo "[9/12] Injecting incomplete TRUNCATE..."

INCOMPLETE_TXID=$((RECOVER_TXID + 1))

append_truncate_transaction \
    "$INCOMPLETE_TXID" \
    "$INCOMPLETE_INO" \
    "$INCOMPLETE_TARGET_SIZE" \
    "no"

pass "incomplete TRUNCATE BEGIN injected"

# ============================================================
# INCOMPLETE MUST BE IGNORED
# ============================================================

echo
echo "[10/12] Incomplete TRUNCATE must be ignored..."

start_ccfs

grep -q \
    "incomplete ignored: 1" \
    "$LOG_FILE" ||
    fail "startup did not report incomplete TRUNCATE"

grep -q \
    "replayed: 0" \
    "$LOG_FILE" ||
    fail "incomplete TRUNCATE caused replay"

assert_file_exact \
    "$MOUNT_DIR/$INCOMPLETE_NAME" \
    "$INCOMPLETE_CONTENT"

stop_ccfs

[[ "$(metadata_size "$INCOMPLETE_INO")" == "${#INCOMPLETE_CONTENT}" ]] ||
    fail "incomplete TRUNCATE changed metadata"

INCOMPLETE_APPLIED="$(
    sqlite3 volume/metadata.db \
        "SELECT COUNT(*)
         FROM applied_tx
         WHERE txid=$INCOMPLETE_TXID;"
)"

[[ "$INCOMPLETE_APPLIED" == "0" ]] ||
    fail "incomplete TRUNCATE incorrectly marked applied"

pass "incomplete TRUNCATE safely ignored"

# ============================================================
# FINAL INTEGRITY
# ============================================================

echo
echo "[11/12] Final checksum integrity verification..."

./target/debug/ccfs \
    --check-integrity \
    >"$INTEGRITY_FILE"

grep -q \
    "ALL CCFS BLOCKS PASSED INTEGRITY CHECK" \
    "$INTEGRITY_FILE" ||
    fail "integrity failed after TRUNCATE recovery"

pass "all TRUNCATE recovery blocks are healthy"

# ============================================================
# STATUS + CLEANUP
# ============================================================

echo
echo "[12/12] Recovery status and cleanup..."

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

rm -f \
    "$MOUNT_DIR/$NORMAL_NAME" \
    "$MOUNT_DIR/$RECOVER_NAME" \
    "$MOUNT_DIR/$INCOMPLETE_NAME"

stop_ccfs

NORMAL_INO=""
RECOVER_INO=""
INCOMPLETE_INO=""

clear_recovery_state

./target/debug/ccfs \
    --check-integrity \
    >"$INTEGRITY_FILE"

grep -q \
    "ALL CCFS BLOCKS PASSED INTEGRITY CHECK" \
    "$INTEGRITY_FILE" ||
    fail "integrity failed after TRUNCATE cleanup"

trap - EXIT INT TERM

rm -f \
    "$STATUS_FILE" \
    "$INTEGRITY_FILE"

echo
echo "========================================"
echo " ALL CCFS TRUNCATE RECOVERY TESTS PASSED"
echo "========================================"
echo