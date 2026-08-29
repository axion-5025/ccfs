#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

MOUNT_DIR="mount"
LOG_FILE="/tmp/ccfs-write-recovery.log"
STATUS_FILE="/tmp/ccfs-write-recovery-status.txt"
INTEGRITY_FILE="/tmp/ccfs-write-recovery-integrity.txt"

RUN_ID="$(date +%s)"
TEST_NAME="write-recovery-$RUN_ID.bin"

CCFS_PID=""
TEST_INO=""

RECOVERED_CONTENT="CCFS committed WRITE recovery $RUN_ID"
INCOMPLETE_CONTENT="THIS INCOMPLETE WRITE MUST NEVER APPEAR $RUN_ID"

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

wait_for_unmount() {
    for _ in $(seq 1 50); do
        if ! is_mounted; then
            return 0
        fi

        sleep 0.1
    done

    return 1
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

    wait_for_unmount >/dev/null 2>&1 || true

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

append_write_transaction() {
    local txid="$1"
    local ino="$2"
    local committed="$3"
    local final_content="$4"

    python3 - \
        "$txid" \
        "$ino" \
        "$committed" \
        "$final_content" <<'PY'
import os
import sqlite3
import struct
import sys
import time
from pathlib import Path

txid = int(sys.argv[1])
ino = int(sys.argv[2])
committed = sys.argv[3] == "yes"
final_data = sys.argv[4].encode("utf-8")

conn = sqlite3.connect("volume/metadata.db")

row = conn.execute(
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

conn.close()

if row is None:
    raise SystemExit(
        f"metadata for inode {ino} does not exist"
    )

parent, name, perm, atime, _old_mtime, _old_ctime = row

now = int(time.time())

name_bytes = name.encode("utf-8")

MAGIC = b"CCFSWRT1"

payload = (
    MAGIC
    + struct.pack("<Q", ino)
    + struct.pack("<Q", parent)
    + struct.pack("<H", perm)
    + struct.pack("<q", atime)
    + struct.pack("<q", now)
    + struct.pack("<q", now)
    + struct.pack("<I", len(name_bytes))
    + struct.pack("<Q", len(final_data))
    + name_bytes
    + final_data
)

def fnv1a64(data: bytes) -> int:
    h = 0xcbf29ce484222325
    prime = 0x100000001b3

    for byte in data:
        h ^= byte
        h = (h * prime) & 0xffffffffffffffff

    return h

def make_record(body: str) -> str:
    value = fnv1a64(body.encode("ascii"))
    return f"{body}|{value:016x}\n"

operation_hex = b"WRITE".hex()
payload_hex = payload.hex()

begin_body = (
    f"BEGIN|{txid}|{operation_hex}|{payload_hex}"
)

journal_path = Path("volume/journal.log")
journal_path.parent.mkdir(parents=True, exist_ok=True)

with journal_path.open("a", encoding="ascii") as journal:
    journal.write(
        make_record(begin_body)
    )

    if committed:
        journal.write(
            make_record(f"COMMIT|{txid}")
        )

    journal.flush()
    os.fsync(journal.fileno())
PY
}

assert_normal_binary_contents() {
    python3 - "$MOUNT_DIR/$TEST_NAME" <<'PY'
import sys

path = sys.argv[1]

with open(path, "rb") as f:
    actual = f.read()

expected = (
    b"ABC"
    + (b"\x00" * 7)
    + b"XYZ"
)

if actual != expected:
    print("Expected:", expected)
    print("Actual:  ", actual)
    raise SystemExit(1)
PY
}

assert_text_contents() {
    local expected="$1"

    python3 - \
        "$MOUNT_DIR/$TEST_NAME" \
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

cleanup() {
    set +e

    if is_mounted; then
        rm -f "$MOUNT_DIR/$TEST_NAME" 2>/dev/null || true
    fi

    stop_ccfs

    if [[ -n "${TEST_INO:-}" ]]; then
        sqlite3 volume/metadata.db \
            "DELETE FROM entries WHERE ino=$TEST_INO;" \
            >/dev/null 2>&1 || true

        rm -f "volume/blocks/$TEST_INO.bin"
        rm -f "volume/blocks/$TEST_INO.checksum"
    fi

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
echo " CCFS WRITE Recovery Test Suite"
echo "========================================"
echo

echo "[1/12] Building CCFS..."

cargo build --bin ccfs >/dev/null

pass "cargo build"

echo
echo "[2/12] Creating isolated WRITE test file..."

stop_ccfs

./target/debug/ccfs \
    --recovery-status \
    >/dev/null

clear_recovery_state

start_ccfs

touch "$MOUNT_DIR/$TEST_NAME"

TEST_INO="$(
    stat -c '%i' "$MOUNT_DIR/$TEST_NAME"
)"

[[ -n "$TEST_INO" ]] ||
    fail "unable to determine test inode"

stop_ccfs

# Remove CREATE journal history so this test now
# measures WRITE recovery independently.
clear_recovery_state

[[ -f "volume/blocks/$TEST_INO.bin" ]] ||
    fail "test data block missing"

[[ -f "volume/blocks/$TEST_INO.checksum" ]] ||
    fail "test checksum missing"

pass "isolated file ready at inode $TEST_INO"

echo
echo "[3/12] Normal sequential WRITE..."

start_ccfs

python3 - "$MOUNT_DIR/$TEST_NAME" <<'PY'
import os
import sys

path = sys.argv[1]

fd = os.open(
    path,
    os.O_WRONLY,
)

try:
    written = os.write(
        fd,
        b"ABC",
    )

    if written != 3:
        raise SystemExit(
            f"expected 3 bytes written, got {written}"
        )

    os.fsync(fd)

finally:
    os.close(fd)
PY

RAW="$(
    python3 - "$MOUNT_DIR/$TEST_NAME" <<'PY'
import sys

with open(sys.argv[1], "rb") as f:
    print(f.read().decode("ascii"))
PY
)"

[[ "$RAW" == "ABC" ]] ||
    fail "normal WRITE returned wrong contents"

pass "normal WRITE persisted"

echo
echo "[4/12] Offset WRITE beyond EOF with zero-fill..."

python3 - "$MOUNT_DIR/$TEST_NAME" <<'PY'
import os
import sys

path = sys.argv[1]

fd = os.open(
    path,
    os.O_WRONLY,
)

try:
    offset = os.lseek(
        fd,
        10,
        os.SEEK_SET,
    )

    if offset != 10:
        raise SystemExit(
            f"seek returned unexpected offset {offset}"
        )

    written = os.write(
        fd,
        b"XYZ",
    )

    if written != 3:
        raise SystemExit(
            f"expected 3 bytes written, got {written}"
        )

    os.fsync(fd)

finally:
    os.close(fd)
PY

assert_normal_binary_contents ||
    fail "offset WRITE / zero-fill contents incorrect"

SIZE="$(
    stat -c '%s' "$MOUNT_DIR/$TEST_NAME"
)"

[[ "$SIZE" == "13" ]] ||
    fail "expected file size 13 after offset WRITE, got $SIZE"

stop_ccfs

DB_SIZE="$(
    sqlite3 volume/metadata.db \
        "SELECT size
         FROM entries
         WHERE ino=$TEST_INO;"
)"

[[ "$DB_SIZE" == "13" ]] ||
    fail "SQLite size metadata was not updated to 13"

WRITE_BEGIN_COUNT="$(
    grep -c '|5752495445|' \
        volume/journal.log \
        || true
)"

[[ "$WRITE_BEGIN_COUNT" == "2" ]] ||
    fail "expected 2 WRITE BEGIN records, found $WRITE_BEGIN_COUNT"

APPLIED_COUNT="$(
    sqlite3 volume/metadata.db \
        "SELECT COUNT(*)
         FROM applied_tx;"
)"

[[ "$APPLIED_COUNT" == "2" ]] ||
    fail "expected 2 applied WRITE transactions, found $APPLIED_COUNT"

pass "offset, extension and zero-fill semantics correct"

echo
echo "[5/12] Restart persistence and WRITE idempotency..."

start_ccfs

assert_normal_binary_contents ||
    fail "WRITE contents did not survive restart"

grep -q \
    "replayed: 0" \
    "$LOG_FILE" ||
    fail "normal WRITE transactions unexpectedly replayed"

grep -q \
    "already applied: 2" \
    "$LOG_FILE" ||
    fail "restart did not identify both applied WRITE transactions"

stop_ccfs

pass "normal WRITE state survived restart without duplicate replay"

echo
echo "[6/12] Checking checksum integrity after normal WRITEs..."

./target/debug/ccfs \
    --check-integrity \
    >"$INTEGRITY_FILE"

grep -q \
    "ALL CCFS BLOCKS PASSED INTEGRITY CHECK" \
    "$INTEGRITY_FILE" ||
    fail "integrity check failed after normal WRITE"

pass "WRITE data and checksum are healthy"

echo
echo "[7/12] Injecting committed-but-not-applied WRITE..."

clear_recovery_state

RECOVER_TXID="$(
    python3 -c 'import time; print(time.time_ns())'
)"

append_write_transaction \
    "$RECOVER_TXID" \
    "$TEST_INO" \
    "yes" \
    "$RECOVERED_CONTENT"

# The journal contains the committed new state,
# but the block must still contain the old data here.
python3 - \
    "volume/blocks/$TEST_INO.bin" \
    "$RECOVERED_CONTENT" <<'PY'
import sys

path = sys.argv[1]
new_value = sys.argv[2].encode("utf-8")

with open(path, "rb") as f:
    current = f.read()

if current == new_value:
    raise SystemExit(
        "synthetic committed WRITE was already applied"
    )
PY

TX_APPLIED_BEFORE="$(
    sqlite3 volume/metadata.db \
        "SELECT COUNT(*)
         FROM applied_tx
         WHERE txid=$RECOVER_TXID;"
)"

[[ "$TX_APPLIED_BEFORE" == "0" ]] ||
    fail "synthetic WRITE was marked applied before recovery"

pass "committed WRITE injected without applying file state"

echo
echo "[8/12] Startup replay of committed WRITE..."

start_ccfs

grep -q \
    "replayed: 1" \
    "$LOG_FILE" ||
    fail "startup did not replay committed WRITE"

assert_text_contents "$RECOVERED_CONTENT" ||
    fail "recovered WRITE contents incorrect"

RECOVERED_SIZE="$(
    stat -c '%s' "$MOUNT_DIR/$TEST_NAME"
)"

EXPECTED_RECOVERED_SIZE="$(
    printf '%s' "$RECOVERED_CONTENT" |
        wc -c
)"

[[ "$RECOVERED_SIZE" == "$EXPECTED_RECOVERED_SIZE" ]] ||
    fail "recovered WRITE size metadata incorrect"

stop_ccfs

TX_APPLIED_AFTER="$(
    sqlite3 volume/metadata.db \
        "SELECT COUNT(*)
         FROM applied_tx
         WHERE txid=$RECOVER_TXID;"
)"

[[ "$TX_APPLIED_AFTER" == "1" ]] ||
    fail "recovered WRITE was not marked applied"

./target/debug/ccfs \
    --check-integrity \
    >"$INTEGRITY_FILE"

grep -q \
    "ALL CCFS BLOCKS PASSED INTEGRITY CHECK" \
    "$INTEGRITY_FILE" ||
    fail "checksum invalid after committed WRITE replay"

pass "committed WRITE replayed with healthy checksum"

echo
echo "[9/12] Recovered WRITE idempotency..."

start_ccfs

grep -q \
    "replayed: 0" \
    "$LOG_FILE" ||
    fail "recovered WRITE replayed a second time"

grep -q \
    "already applied: 1" \
    "$LOG_FILE" ||
    fail "recovered WRITE not recognized as already applied"

assert_text_contents "$RECOVERED_CONTENT" ||
    fail "idempotent restart changed recovered contents"

stop_ccfs

pass "repeated recovery does not duplicate WRITE"

echo
echo "[10/12] Injecting incomplete WRITE..."

INCOMPLETE_TXID=$((RECOVER_TXID + 1))

append_write_transaction \
    "$INCOMPLETE_TXID" \
    "$TEST_INO" \
    "no" \
    "$INCOMPLETE_CONTENT"

pass "incomplete WRITE BEGIN injected"

echo
echo "[11/12] Incomplete WRITE must be ignored..."

start_ccfs

grep -q \
    "incomplete ignored: 1" \
    "$LOG_FILE" ||
    fail "startup did not report incomplete WRITE"

grep -q \
    "replayed: 0" \
    "$LOG_FILE" ||
    fail "incomplete WRITE caused an unexpected replay"

assert_text_contents "$RECOVERED_CONTENT" ||
    fail "incomplete WRITE changed file contents"

stop_ccfs

INCOMPLETE_APPLIED="$(
    sqlite3 volume/metadata.db \
        "SELECT COUNT(*)
         FROM applied_tx
         WHERE txid=$INCOMPLETE_TXID;"
)"

[[ "$INCOMPLETE_APPLIED" == "0" ]] ||
    fail "incomplete WRITE was incorrectly marked applied"

pass "incomplete WRITE safely ignored"

echo
echo "[12/12] Final status, cleanup and integrity verification..."

./target/debug/ccfs \
    --recovery-status \
    >"$STATUS_FILE"

cat "$STATUS_FILE"

grep -q \
    "Total transactions:          2" \
    "$STATUS_FILE" ||
    fail "expected 2 synthetic WRITE transactions"

grep -q \
    "Committed transactions:      1" \
    "$STATUS_FILE" ||
    fail "expected 1 committed WRITE transaction"

grep -q \
    "Incomplete transactions:     1" \
    "$STATUS_FILE" ||
    fail "expected 1 incomplete WRITE transaction"

grep -q \
    "Already applied transactions:1" \
    "$STATUS_FILE" ||
    fail "expected 1 applied committed WRITE"

start_ccfs

rm "$MOUNT_DIR/$TEST_NAME"

stop_ccfs

TEST_INO=""

clear_recovery_state

./target/debug/ccfs \
    --check-integrity \
    >"$INTEGRITY_FILE"

grep -q \
    "ALL CCFS BLOCKS PASSED INTEGRITY CHECK" \
    "$INTEGRITY_FILE" ||
    fail "filesystem integrity failed after WRITE recovery cleanup"

trap - EXIT INT TERM

rm -f "$STATUS_FILE"
rm -f "$INTEGRITY_FILE"

echo
echo "========================================"
echo " ALL CCFS WRITE RECOVERY TESTS PASSED"
echo "========================================"
echo