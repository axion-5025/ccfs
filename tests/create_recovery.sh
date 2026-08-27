#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

MOUNT_DIR="mount"
LOG_FILE="/tmp/ccfs-create-recovery.log"
STATUS_FILE="/tmp/ccfs-create-recovery-status.txt"

RUN_ID="$(date +%s)"

NORMAL_NAME="create-normal-$RUN_ID.txt"
RECOVER_NAME="create-recovered-$RUN_ID.txt"
INCOMPLETE_NAME="create-incomplete-$RUN_ID.txt"

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

sql_count_name() {
    local name="$1"

    sqlite3 volume/metadata.db \
        "SELECT COUNT(*) FROM entries WHERE name='$name';"
}

append_create_transaction() {
    local txid="$1"
    local ino="$2"
    local name="$3"
    local committed="$4"

    python3 - \
        "$txid" \
        "$ino" \
        "$name" \
        "$committed" <<'PY'
import struct
import sys
import time
from pathlib import Path

txid = int(sys.argv[1])
ino = int(sys.argv[2])
name = sys.argv[3]
committed = sys.argv[4] == "yes"

journal = Path("volume/journal.log")
journal.parent.mkdir(parents=True, exist_ok=True)

MAGIC = b"CCFSCRT1"
parent = 1
perm = 0o644
now = int(time.time())

name_bytes = name.encode("utf-8")

payload = (
    MAGIC
    + struct.pack("<Q", ino)
    + struct.pack("<Q", parent)
    + struct.pack("<H", perm)
    + struct.pack("<q", now)
    + struct.pack("<q", now)
    + struct.pack("<q", now)
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
    checksum = fnv1a64(body.encode("ascii"))
    return f"{body}|{checksum:016x}\n"

operation_hex = b"CREATE".hex()
payload_hex = payload.hex()

begin_body = (
    f"BEGIN|{txid}|{operation_hex}|{payload_hex}"
)

with journal.open("a", encoding="ascii") as f:
    f.write(record(begin_body))

    if committed:
        f.write(record(f"COMMIT|{txid}"))

    f.flush()

    import os
    os.fsync(f.fileno())
PY
}

cleanup() {
    set +e

    if is_mounted; then
        rm -f "$MOUNT_DIR/$NORMAL_NAME" 2>/dev/null || true
        rm -f "$MOUNT_DIR/$RECOVER_NAME" 2>/dev/null || true
    fi

    stop_ccfs

    sqlite3 volume/metadata.db \
        "DELETE FROM entries
         WHERE name IN (
             '$NORMAL_NAME',
             '$RECOVER_NAME',
             '$INCOMPLETE_NAME'
         );" \
        >/dev/null 2>&1 || true

    if [[ -n "${NORMAL_INO:-}" ]]; then
        rm -f "volume/blocks/$NORMAL_INO.bin"
        rm -f "volume/blocks/$NORMAL_INO.checksum"
    fi

    if [[ -n "${RECOVER_INO:-}" ]]; then
        rm -f "volume/blocks/$RECOVER_INO.bin"
        rm -f "volume/blocks/$RECOVER_INO.checksum"
    fi

    if [[ -n "${INCOMPLETE_INO:-}" ]]; then
        rm -f "volume/blocks/$INCOMPLETE_INO.bin"
        rm -f "volume/blocks/$INCOMPLETE_INO.checksum"
    fi

    sqlite3 volume/metadata.db \
        "DELETE FROM applied_tx;" \
        >/dev/null 2>&1 || true

    : > volume/journal.log

    rm -f "$STATUS_FILE"

    set -e
}

trap cleanup EXIT INT TERM

echo
echo "========================================"
echo " CCFS CREATE Recovery Test Suite"
echo "========================================"
echo

echo "[1/10] Building CCFS..."

cargo build --bin ccfs >/dev/null

pass "cargo build"

echo
echo "[2/10] Initializing clean journal/recovery state..."

stop_ccfs

# Initialize database/applied_tx without mounting.
./target/debug/ccfs --recovery-status >/dev/null

: > volume/journal.log

sqlite3 volume/metadata.db \
    "DELETE FROM applied_tx;"

pass "journal and applied_tx cleared"

echo
echo "[3/10] Normal journaled CREATE..."

start_ccfs

python3 - "$MOUNT_DIR/$NORMAL_NAME" <<'PYCREATE'
import os
import sys

path = sys.argv[1]

fd = os.open(
    path,
    os.O_CREAT | os.O_EXCL | os.O_WRONLY,
    0o644,
)

os.close(fd)
PYCREATE

[[ -f "$MOUNT_DIR/$NORMAL_NAME" ]] ||
    fail "normal CREATE did not produce file"

NORMAL_INO="$(
    stat -c '%i' "$MOUNT_DIR/$NORMAL_NAME"
)"

[[ -f "volume/blocks/$NORMAL_INO.bin" ]] ||
    fail "normal CREATE data block missing"

[[ -f "volume/blocks/$NORMAL_INO.checksum" ]] ||
    fail "normal CREATE checksum missing"

stop_ccfs

NORMAL_DB_COUNT="$(
    sql_count_name "$NORMAL_NAME"
)"

[[ "$NORMAL_DB_COUNT" == "1" ]] ||
    fail "normal CREATE metadata missing"

APPLIED_COUNT="$(
    sqlite3 volume/metadata.db \
        "SELECT COUNT(*) FROM applied_tx;"
)"

[[ "$APPLIED_COUNT" == "1" ]] ||
    fail "normal CREATE transaction was not marked applied"

pass "normal CREATE journaled and applied"

echo
echo "[4/10] Restart idempotency for normal CREATE..."

start_ccfs

[[ -f "$MOUNT_DIR/$NORMAL_NAME" ]] ||
    fail "normal CREATE file missing after restart"

grep -q \
    "already applied: 1" \
    "$LOG_FILE" ||
    fail "restart did not identify applied CREATE transaction"

stop_ccfs

NORMAL_DB_COUNT="$(
    sql_count_name "$NORMAL_NAME"
)"

[[ "$NORMAL_DB_COUNT" == "1" ]] ||
    fail "restart duplicated normal CREATE metadata"

pass "normal CREATE not replayed twice"

echo
echo "[5/10] Injecting committed-but-not-applied CREATE..."

MAX_INO="$(
    sqlite3 volume/metadata.db \
        "SELECT COALESCE(MAX(ino), 2) FROM entries;"
)"

RECOVER_INO=$((MAX_INO + 1000))

RECOVER_TXID="$(
    python3 -c 'import time; print(time.time_ns())'
)"

append_create_transaction \
    "$RECOVER_TXID" \
    "$RECOVER_INO" \
    "$RECOVER_NAME" \
    "yes"

[[ "$(sql_count_name "$RECOVER_NAME")" == "0" ]] ||
    fail "synthetic CREATE existed before recovery"

[[ ! -e "volume/blocks/$RECOVER_INO.bin" ]] ||
    fail "synthetic CREATE block existed before recovery"

pass "committed CREATE injected without applying state"

echo
echo "[6/10] Startup recovery of committed CREATE..."

start_ccfs

grep -q \
    "replayed: 1" \
    "$LOG_FILE" ||
    fail "startup did not report one replayed transaction"

[[ -f "$MOUNT_DIR/$RECOVER_NAME" ]] ||
    fail "committed CREATE was not restored"

RECOVER_VISIBLE_INO="$(
    stat -c '%i' "$MOUNT_DIR/$RECOVER_NAME"
)"

[[ "$RECOVER_VISIBLE_INO" == "$RECOVER_INO" ]] ||
    fail "recovered CREATE inode mismatch"

[[ "$(
    stat -c '%s' "$MOUNT_DIR/$RECOVER_NAME"
)" == "0" ]] ||
    fail "recovered CREATE should be empty"

stop_ccfs

[[ "$(sql_count_name "$RECOVER_NAME")" == "1" ]] ||
    fail "recovered CREATE metadata missing"

[[ -f "volume/blocks/$RECOVER_INO.bin" ]] ||
    fail "recovered CREATE data block missing"

[[ -f "volume/blocks/$RECOVER_INO.checksum" ]] ||
    fail "recovered CREATE checksum missing"

RECOVER_APPLIED="$(
    sqlite3 volume/metadata.db \
        "SELECT COUNT(*)
         FROM applied_tx
         WHERE txid=$RECOVER_TXID;"
)"

[[ "$RECOVER_APPLIED" == "1" ]] ||
    fail "recovered CREATE not recorded in applied_tx"

pass "committed CREATE recovered successfully"

echo
echo "[7/10] Recovery idempotency after replay..."

start_ccfs

grep -q \
    "replayed: 0" \
    "$LOG_FILE" ||
    fail "already-recovered CREATE replayed again"

[[ -f "$MOUNT_DIR/$RECOVER_NAME" ]] ||
    fail "recovered file missing on second restart"

stop_ccfs

[[ "$(sql_count_name "$RECOVER_NAME")" == "1" ]] ||
    fail "second recovery duplicated CREATE metadata"

pass "recovered CREATE is idempotent"

echo
echo "[8/10] Injecting incomplete CREATE..."

INCOMPLETE_INO=$((RECOVER_INO + 1))
INCOMPLETE_TXID=$((RECOVER_TXID + 1))

append_create_transaction \
    "$INCOMPLETE_TXID" \
    "$INCOMPLETE_INO" \
    "$INCOMPLETE_NAME" \
    "no"

pass "incomplete CREATE BEGIN injected"

echo
echo "[9/10] Incomplete CREATE must be ignored..."

start_ccfs

grep -q \
    "incomplete ignored: 1" \
    "$LOG_FILE" ||
    fail "startup did not report incomplete transaction"

if [[ -e "$MOUNT_DIR/$INCOMPLETE_NAME" ]]; then
    fail "incomplete CREATE became visible"
fi

stop_ccfs

[[ "$(sql_count_name "$INCOMPLETE_NAME")" == "0" ]] ||
    fail "incomplete CREATE metadata was applied"

[[ ! -e "volume/blocks/$INCOMPLETE_INO.bin" ]] ||
    fail "incomplete CREATE data block was created"

[[ ! -e "volume/blocks/$INCOMPLETE_INO.checksum" ]] ||
    fail "incomplete CREATE checksum was created"

INCOMPLETE_APPLIED="$(
    sqlite3 volume/metadata.db \
        "SELECT COUNT(*)
         FROM applied_tx
         WHERE txid=$INCOMPLETE_TXID;"
)"

[[ "$INCOMPLETE_APPLIED" == "0" ]] ||
    fail "incomplete CREATE was marked applied"

pass "incomplete CREATE safely ignored"

echo
echo "[10/10] Final recovery status and cleanup..."

./target/debug/ccfs \
    --recovery-status \
    >"$STATUS_FILE"

cat "$STATUS_FILE"

grep -q \
    "Total transactions:          3" \
    "$STATUS_FILE" ||
    fail "unexpected total journal transaction count"

grep -q \
    "Committed transactions:      2" \
    "$STATUS_FILE" ||
    fail "unexpected committed transaction count"

grep -q \
    "Incomplete transactions:     1" \
    "$STATUS_FILE" ||
    fail "unexpected incomplete transaction count"

grep -q \
    "Already applied transactions:2" \
    "$STATUS_FILE" ||
    fail "unexpected applied transaction count"

# Remove the two real files through CCFS.
start_ccfs

rm "$MOUNT_DIR/$NORMAL_NAME"
rm "$MOUNT_DIR/$RECOVER_NAME"

stop_ccfs

: > volume/journal.log

sqlite3 volume/metadata.db \
    "DELETE FROM applied_tx;"

./target/debug/ccfs --check-integrity \
    >/tmp/ccfs-create-final-integrity.txt

grep -q \
    "ALL CCFS BLOCKS PASSED INTEGRITY CHECK" \
    /tmp/ccfs-create-final-integrity.txt ||
    fail "filesystem integrity failed after CREATE recovery tests"

rm -f /tmp/ccfs-create-final-integrity.txt

trap - EXIT INT TERM

rm -f "$STATUS_FILE"

echo
echo "========================================"
echo " ALL CCFS CREATE RECOVERY TESTS PASSED"
echo "========================================"
echo