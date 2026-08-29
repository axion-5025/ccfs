#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

MOUNT_DIR="mount"

LOG_FILE="/tmp/ccfs-atime-recovery.log"
STATUS_FILE="/tmp/ccfs-atime-recovery-status.txt"
INTEGRITY_FILE="/tmp/ccfs-atime-recovery-integrity.txt"

RUN_ID="$(date +%s)"

TEST_NAME="atime-recovery-$RUN_ID.txt"
TEST_CONTENT="ATIME-RECOVERY-DATA-$RUN_ID"

CCFS_PID=""
TEST_INO=""

BASELINE_ATIME=""
NORMAL_ATIME=""
RECOVER_TARGET_ATIME=""
INCOMPLETE_TARGET_ATIME=""

RECOVER_TXID=$((8000000000 + RUN_ID))
INCOMPLETE_TXID=$((9000000000 + RUN_ID))

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

        echo
    fi

    exit 1
}

is_mounted() {
    mountpoint -q "$MOUNT_DIR" 2>/dev/null
}

stop_ccfs() {
    set +e

    if is_mounted; then
        fusermount3 -u "$MOUNT_DIR" \
            2>/dev/null || true
    fi

    if is_mounted; then
        fusermount3 -uz "$MOUNT_DIR" \
            2>/dev/null || true
    fi

    if [[ -n "${CCFS_PID:-}" ]] &&
       kill -0 "$CCFS_PID" 2>/dev/null
    then
        kill "$CCFS_PID" \
            2>/dev/null || true
    fi

    if [[ -n "${CCFS_PID:-}" ]]; then
        wait "$CCFS_PID" \
            2>/dev/null || true
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

metadata_atime() {
    local ino="$1"

    sqlite3 volume/metadata.db \
        "SELECT atime
         FROM entries
         WHERE ino=$ino;"
}

metadata_count() {
    local ino="$1"

    sqlite3 volume/metadata.db \
        "SELECT COUNT(*)
         FROM entries
         WHERE ino=$ino;"
}

metadata_row() {
    local ino="$1"

    sqlite3 volume/metadata.db \
        "SELECT
            perm || '|' ||
            atime || '|' ||
            mtime || '|' ||
            ctime || '|' ||
            size
         FROM entries
         WHERE ino=$ino;"
}

read_and_verify_file() {
    local path="$1"
    local expected="$2"

    python3 - \
        "$path" \
        "$expected" <<'PY'
import sys

path = sys.argv[1]
expected = sys.argv[2].encode("utf-8")

with open(
    path,
    "rb",
    buffering=0,
) as f:
    actual = f.read()

if actual != expected:
    print(
        "Expected:",
        expected,
    )

    print(
        "Actual:  ",
        actual,
    )

    raise SystemExit(1)
PY
}

append_atime_transaction() {
    local txid="$1"
    local ino="$2"
    local target_atime="$3"
    local committed="$4"

    python3 - \
        "$txid" \
        "$ino" \
        "$target_atime" \
        "$committed" <<'PY'
import os
import sqlite3
import struct
import sys

from pathlib import Path

txid = int(
    sys.argv[1]
)

ino = int(
    sys.argv[2]
)

target_atime = int(
    sys.argv[3]
)

committed = (
    sys.argv[4] == "yes"
)

MAGIC = b"CCFSATR1"

db = sqlite3.connect(
    "volume/metadata.db"
)

row = db.execute(
    """
    SELECT
        parent,
        name,
        kind,
        perm,
        size,
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
        f"inode {ino} not found"
    )

(
    parent,
    name,
    kind,
    perm,
    size,
    mtime,
    ctime,
) = row

is_dir = (
    1
    if kind != 0
    else 0
)

name_bytes = name.encode(
    "utf-8"
)

payload = bytearray()

payload += MAGIC

payload += struct.pack(
    "<Q",
    ino,
)

payload += struct.pack(
    "<Q",
    parent,
)

payload += struct.pack(
    "<B",
    is_dir,
)

payload += struct.pack(
    "<H",
    perm,
)

payload += struct.pack(
    "<Q",
    size,
)

payload += struct.pack(
    "<q",
    target_atime,
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

payload += name_bytes


def fnv1a64(data: bytes) -> int:
    h = 0xCBF29CE484222325
    prime = 0x100000001B3

    for byte in data:
        h ^= byte

        h = (
            h * prime
        ) & 0xFFFFFFFFFFFFFFFF

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
    b"ATIME".hex()
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

run_integrity_check() {
    ./target/debug/ccfs \
        --check-integrity \
        >"$INTEGRITY_FILE"

    grep -q \
        "ALL CCFS BLOCKS PASSED INTEGRITY CHECK" \
        "$INTEGRITY_FILE" ||
        fail "filesystem integrity check failed"
}

cleanup() {
    set +e

    if is_mounted; then
        rm -f \
            "$MOUNT_DIR/$TEST_NAME" \
            2>/dev/null || true
    fi

    stop_ccfs

    if [[ -n "${TEST_INO:-}" ]]; then
        sqlite3 volume/metadata.db \
            "DELETE FROM entries
             WHERE ino=$TEST_INO;" \
            >/dev/null 2>&1 || true

        rm -f \
            "volume/blocks/$TEST_INO.bin" \
            "volume/blocks/$TEST_INO.checksum"
    fi

    sqlite3 volume/metadata.db \
        "DELETE FROM applied_tx;" \
        >/dev/null 2>&1 || true

    : > volume/journal.log \
        2>/dev/null || true

    rm -f \
        "$STATUS_FILE" \
        "$INTEGRITY_FILE"

    set -e
}

trap cleanup EXIT INT TERM

echo
echo "========================================"
echo " CCFS ATIME Recovery Test Suite"
echo "========================================"
echo

# ============================================================
# BUILD
# ============================================================

echo "[1/9] Building CCFS..."

cargo build --bin ccfs \
    >/dev/null

pass "cargo build"

# ============================================================
# PREPARE
# ============================================================

echo
echo "[2/9] Preparing isolated ATIME test file..."

stop_ccfs

./target/debug/ccfs \
    --recovery-status \
    >/dev/null

clear_recovery_state

start_ccfs

printf '%s' \
    "$TEST_CONTENT" \
    > "$MOUNT_DIR/$TEST_NAME"

TEST_INO="$(
    stat -c '%i' \
        "$MOUNT_DIR/$TEST_NAME"
)"

stop_ccfs

[[ "$(metadata_count "$TEST_INO")" == "1" ]] ||
    fail "ATIME test metadata missing"

BASELINE_ATIME="$(
    metadata_atime \
        "$TEST_INO"
)"

[[ -n "$BASELINE_ATIME" ]] ||
    fail "unable to read baseline atime"

# Ignore CREATE / WRITE setup transactions.
clear_recovery_state

pass "isolated ATIME file ready"

# ============================================================
# NORMAL READ
# ============================================================

echo
echo "[3/9] Normal journaled READ updates ATIME..."

sleep 2

start_ccfs

read_and_verify_file \
    "$MOUNT_DIR/$TEST_NAME" \
    "$TEST_CONTENT" ||
    fail "normal READ returned wrong file data"

stop_ccfs

NORMAL_ATIME="$(
    metadata_atime \
        "$TEST_INO"
)"

[[ "$NORMAL_ATIME" -gt "$BASELINE_ATIME" ]] ||
    fail "normal READ did not advance persisted atime"

APPLIED_COUNT="$(
    sqlite3 volume/metadata.db \
        "SELECT COUNT(*)
         FROM applied_tx;"
)"

[[ "$APPLIED_COUNT" -ge 1 ]] ||
    fail "normal ATIME transaction was not marked applied"

pass "normal READ journaled and persisted ATIME"

# ============================================================
# NORMAL RESTART IDEMPOTENCY
# ============================================================

echo
echo "[4/9] Normal ATIME restart idempotency..."

start_ccfs

sleep 0.1

stop_ccfs

grep -q \
    "replayed: 0" \
    "$LOG_FILE" ||
    fail "applied ATIME transaction replayed unexpectedly"

grep -Eq \
    "already applied: [1-9][0-9]*" \
    "$LOG_FILE" ||
    fail "applied ATIME transaction not recognized on restart"

[[ "$(metadata_atime "$TEST_INO")" == "$NORMAL_ATIME" ]] ||
    fail "restart changed ATIME without a read"

pass "normal ATIME survived restart idempotently"

# ============================================================
# COMMITTED RECOVERY
# ============================================================

echo
echo "[5/9] Committed ATIME recovery replay..."

clear_recovery_state

RECOVER_TARGET_ATIME=$((NORMAL_ATIME + 1000))

append_atime_transaction \
    "$RECOVER_TXID" \
    "$TEST_INO" \
    "$RECOVER_TARGET_ATIME" \
    yes

[[ "$(metadata_atime "$TEST_INO")" == "$NORMAL_ATIME" ]] ||
    fail "committed ATIME changed metadata before recovery"

start_ccfs

sleep 0.1

stop_ccfs

[[ "$(metadata_atime "$TEST_INO")" == "$RECOVER_TARGET_ATIME" ]] ||
    fail "committed ATIME transaction was not replayed"

grep -q \
    "replayed: 1" \
    "$LOG_FILE" ||
    fail "recovery summary did not report one replayed ATIME transaction"

[[ "$(
    sqlite3 volume/metadata.db \
        "SELECT COUNT(*)
         FROM applied_tx
         WHERE txid=$RECOVER_TXID;"
)" == "1" ]] ||
    fail "replayed ATIME transaction was not marked applied"

pass "committed ATIME replayed correctly"

# ============================================================
# COMMITTED RESTART IDEMPOTENCY
# ============================================================

echo
echo "[6/9] Replayed ATIME restart idempotency..."

start_ccfs

sleep 0.1

stop_ccfs

[[ "$(metadata_atime "$TEST_INO")" == "$RECOVER_TARGET_ATIME" ]] ||
    fail "second restart changed recovered ATIME"

grep -q \
    "replayed: 0" \
    "$LOG_FILE" ||
    fail "recovered ATIME replayed a second time"

grep -Eq \
    "already applied: [1-9][0-9]*" \
    "$LOG_FILE" ||
    fail "recovered ATIME not recognized as already applied"

pass "recovered ATIME is idempotent"

# ============================================================
# INCOMPLETE RECOVERY
# ============================================================

echo
echo "[7/9] Incomplete ATIME transaction is ignored..."

clear_recovery_state

RECOVERED_ROW="$(
    metadata_row \
        "$TEST_INO"
)"

INCOMPLETE_TARGET_ATIME=$((RECOVER_TARGET_ATIME + 1000))

append_atime_transaction \
    "$INCOMPLETE_TXID" \
    "$TEST_INO" \
    "$INCOMPLETE_TARGET_ATIME" \
    no

start_ccfs

sleep 0.1

stop_ccfs

[[ "$(metadata_row "$TEST_INO")" == "$RECOVERED_ROW" ]] ||
    fail "incomplete ATIME transaction modified metadata"

grep -q \
    "incomplete ignored: 1" \
    "$LOG_FILE" ||
    fail "recovery summary did not report incomplete ATIME transaction"

grep -q \
    "replayed: 0" \
    "$LOG_FILE" ||
    fail "incomplete ATIME transaction was replayed"

[[ "$(
    sqlite3 volume/metadata.db \
        "SELECT COUNT(*)
         FROM applied_tx
         WHERE txid=$INCOMPLETE_TXID;"
)" == "0" ]] ||
    fail "incomplete ATIME transaction was marked applied"

pass "incomplete ATIME transaction ignored safely"

# ============================================================
# RECOVERY STATUS
# ============================================================

echo
echo "[8/9] Checking recovery status..."

./target/debug/ccfs \
    --recovery-status \
    >"$STATUS_FILE"

grep -Eq \
    "Incomplete transactions:[[:space:]]+1" \
    "$STATUS_FILE" ||
    fail "recovery status did not preserve incomplete ATIME state"

pass "recovery status is consistent"

# ============================================================
# INTEGRITY
# ============================================================

echo
echo "[9/9] Running filesystem integrity check..."

run_integrity_check

pass "filesystem integrity remains healthy"

echo
echo "========================================"
echo " ALL CCFS ATIME RECOVERY TESTS PASSED"
echo "========================================"
echo
