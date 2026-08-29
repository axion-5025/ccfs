#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

MOUNT_DIR="mount"

LOG_FILE="/tmp/ccfs-setattr-recovery.log"
STATUS_FILE="/tmp/ccfs-setattr-recovery-status.txt"
INTEGRITY_FILE="/tmp/ccfs-setattr-recovery-integrity.txt"

RUN_ID="$(date +%s)"

NORMAL_NAME="setattr-normal-$RUN_ID.txt"
RECOVER_NAME="setattr-recover-$RUN_ID.txt"
INCOMPLETE_NAME="setattr-incomplete-$RUN_ID.txt"

NORMAL_CONTENT="NORMAL-SETATTR-DATA-$RUN_ID"
RECOVER_CONTENT="RECOVER-SETATTR-DATA-$RUN_ID"
INCOMPLETE_CONTENT="INCOMPLETE-SETATTR-DATA-$RUN_ID"

NORMAL_MODE="600"
NORMAL_MTIME="1700000123"

RECOVER_MODE="640"
RECOVER_ATIME="1700000200"
RECOVER_MTIME="1700000300"
RECOVER_CTIME="1700000400"

INCOMPLETE_MODE="400"
INCOMPLETE_ATIME="1700000500"
INCOMPLETE_MTIME="1700000600"
INCOMPLETE_CTIME="1700000700"

CCFS_PID=""

NORMAL_INO=""
RECOVER_INO=""
INCOMPLETE_INO=""

RECOVER_ORIGINAL_ROW=""
INCOMPLETE_ORIGINAL_ROW=""

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

metadata_perm() {
    local ino="$1"

    sqlite3 volume/metadata.db \
        "SELECT perm
         FROM entries
         WHERE ino=$ino;"
}

metadata_atime() {
    local ino="$1"

    sqlite3 volume/metadata.db \
        "SELECT atime
         FROM entries
         WHERE ino=$ino;"
}

metadata_mtime() {
    local ino="$1"

    sqlite3 volume/metadata.db \
        "SELECT mtime
         FROM entries
         WHERE ino=$ino;"
}

metadata_ctime() {
    local ino="$1"

    sqlite3 volume/metadata.db \
        "SELECT ctime
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

assert_mode() {
    local path="$1"
    local expected="$2"

    local actual

    actual="$(
        stat -c '%a' "$path"
    )"

    [[ "$actual" == "$expected" ]] ||
        fail "mode mismatch for $path: expected $expected got $actual"
}

assert_mtime() {
    local path="$1"
    local expected="$2"

    local actual

    actual="$(
        stat -c '%Y' "$path"
    )"

    [[ "$actual" == "$expected" ]] ||
        fail "mtime mismatch for $path: expected $expected got $actual"
}

assert_block_exact() {
    local ino="$1"
    local expected="$2"

    python3 - \
        "volume/blocks/$ino.bin" \
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

append_setattr_transaction() {
    local txid="$1"
    local ino="$2"
    local mode="$3"
    local atime="$4"
    local mtime="$5"
    local ctime="$6"
    local committed="$7"

    python3 - \
        "$txid" \
        "$ino" \
        "$mode" \
        "$atime" \
        "$mtime" \
        "$ctime" \
        "$committed" <<'PY'
import os
import sqlite3
import struct
import sys
from pathlib import Path

txid = int(sys.argv[1])
ino = int(sys.argv[2])

perm = int(
    sys.argv[3],
    8,
)

target_atime = int(sys.argv[4])
target_mtime = int(sys.argv[5])
target_ctime = int(sys.argv[6])

committed = (
    sys.argv[7] == "yes"
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
        size
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

parent, name, kind, size = row

is_dir = 1 if kind != 0 else 0

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
    target_mtime,
)

payload += struct.pack(
    "<q",
    target_ctime,
)

payload += struct.pack(
    "<I",
    len(name_bytes),
)

payload += name_bytes


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
    b"SETATTR".hex()
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
echo " CCFS SETATTR Recovery Test Suite"
echo "========================================"
echo

# ============================================================
# BUILD
# ============================================================

echo "[1/13] Building CCFS..."

cargo build --bin ccfs \
    >/dev/null

pass "cargo build"

# ============================================================
# PREPARE
# ============================================================

echo
echo "[2/13] Preparing isolated test files..."

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

stop_ccfs

[[ "$(metadata_count "$NORMAL_INO")" == "1" ]] ||
    fail "normal test metadata missing"

[[ "$(metadata_count "$RECOVER_INO")" == "1" ]] ||
    fail "recovery test metadata missing"

[[ "$(metadata_count "$INCOMPLETE_INO")" == "1" ]] ||
    fail "incomplete test metadata missing"

assert_block_exact \
    "$NORMAL_INO" \
    "$NORMAL_CONTENT"

assert_block_exact \
    "$RECOVER_INO" \
    "$RECOVER_CONTENT"

assert_block_exact \
    "$INCOMPLETE_INO" \
    "$INCOMPLETE_CONTENT"

RECOVER_ORIGINAL_ROW="$(
    metadata_row \
        "$RECOVER_INO"
)"

INCOMPLETE_ORIGINAL_ROW="$(
    metadata_row \
        "$INCOMPLETE_INO"
)"

# Ignore CREATE / WRITE setup transactions.
clear_recovery_state

pass "isolated SETATTR files ready"

# ============================================================
# NORMAL CHMOD
# ============================================================

echo
echo "[3/13] Normal journaled chmod SETATTR..."

start_ccfs

chmod \
    "$NORMAL_MODE" \
    "$MOUNT_DIR/$NORMAL_NAME"

assert_mode \
    "$MOUNT_DIR/$NORMAL_NAME" \
    "$NORMAL_MODE"

stop_ccfs

NORMAL_PERM_DECIMAL="$(
    metadata_perm \
        "$NORMAL_INO"
)"

NORMAL_PERM_OCTAL="$(
    printf '%o' \
        "$NORMAL_PERM_DECIMAL"
)"

[[ "$NORMAL_PERM_OCTAL" == "$NORMAL_MODE" ]] ||
    fail "chmod permission not persisted"

APPLIED_COUNT="$(
    sqlite3 volume/metadata.db \
        "SELECT COUNT(*)
         FROM applied_tx;"
)"

[[ "$APPLIED_COUNT" == "1" ]] ||
    fail "normal chmod SETATTR transaction not marked applied"

pass "normal chmod SETATTR journaled and applied"

# ============================================================
# CHMOD RESTART
# ============================================================

echo
echo "[4/13] chmod SETATTR restart idempotency..."

start_ccfs

assert_mode \
    "$MOUNT_DIR/$NORMAL_NAME" \
    "$NORMAL_MODE"

grep -q \
    "replayed: 0" \
    "$LOG_FILE" ||
    fail "normal chmod SETATTR replayed unexpectedly"

grep -q \
    "already applied: 1" \
    "$LOG_FILE" ||
    fail "normal chmod SETATTR not recognized as applied"

stop_ccfs

pass "chmod SETATTR survived restart"

# ============================================================
# NORMAL MTIME
# ============================================================

echo
echo "[5/13] Normal journaled timestamp SETATTR..."

clear_recovery_state

start_ccfs

touch \
    -m \
    -d "@$NORMAL_MTIME" \
    "$MOUNT_DIR/$NORMAL_NAME"

assert_mtime \
    "$MOUNT_DIR/$NORMAL_NAME" \
    "$NORMAL_MTIME"

stop_ccfs

[[ "$(metadata_mtime "$NORMAL_INO")" == "$NORMAL_MTIME" ]] ||
    fail "normal timestamp SETATTR mtime not persisted"

APPLIED_COUNT="$(
    sqlite3 volume/metadata.db \
        "SELECT COUNT(*)
         FROM applied_tx;"
)"

[[ "$APPLIED_COUNT" == "1" ]] ||
    fail "timestamp SETATTR transaction not marked applied"

pass "normal timestamp SETATTR journaled and applied"

# ============================================================
# TIMESTAMP RESTART
# ============================================================

echo
echo "[6/13] Timestamp SETATTR restart idempotency..."

start_ccfs

assert_mtime \
    "$MOUNT_DIR/$NORMAL_NAME" \
    "$NORMAL_MTIME"

grep -q \
    "replayed: 0" \
    "$LOG_FILE" ||
    fail "normal timestamp SETATTR replayed unexpectedly"

grep -q \
    "already applied: 1" \
    "$LOG_FILE" ||
    fail "normal timestamp SETATTR not recognized as applied"

stop_ccfs

pass "timestamp SETATTR survived restart"

# ============================================================
# INTEGRITY
# ============================================================

echo
echo "[7/13] Checking data integrity after metadata SETATTR..."

run_integrity_check

assert_block_exact \
    "$NORMAL_INO" \
    "$NORMAL_CONTENT"

pass "metadata SETATTR did not modify file data"

# ============================================================
# COMMITTED INJECTION
# ============================================================

echo
echo "[8/13] Injecting committed-but-not-applied SETATTR..."

clear_recovery_state

RECOVER_TXID="$(
    python3 -c \
        'import time; print(time.time_ns())'
)"

append_setattr_transaction \
    "$RECOVER_TXID" \
    "$RECOVER_INO" \
    "$RECOVER_MODE" \
    "$RECOVER_ATIME" \
    "$RECOVER_MTIME" \
    "$RECOVER_CTIME" \
    "yes"

[[ "$(metadata_row "$RECOVER_INO")" == "$RECOVER_ORIGINAL_ROW" ]] ||
    fail "committed SETATTR changed metadata before replay"

assert_block_exact \
    "$RECOVER_INO" \
    "$RECOVER_CONTENT"

pass "committed SETATTR injected without applying metadata"

# ============================================================
# STARTUP REPLAY
# ============================================================

echo
echo "[9/13] Startup replay of committed SETATTR..."

start_ccfs

grep -q \
    "replayed: 1" \
    "$LOG_FILE" ||
    fail "startup did not replay committed SETATTR"

assert_mode \
    "$MOUNT_DIR/$RECOVER_NAME" \
    "$RECOVER_MODE"

assert_mtime \
    "$MOUNT_DIR/$RECOVER_NAME" \
    "$RECOVER_MTIME"

stop_ccfs

RECOVER_PERM_DECIMAL="$(
    metadata_perm \
        "$RECOVER_INO"
)"

RECOVER_PERM_OCTAL="$(
    printf '%o' \
        "$RECOVER_PERM_DECIMAL"
)"

[[ "$RECOVER_PERM_OCTAL" == "$RECOVER_MODE" ]] ||
    fail "recovered SETATTR permission incorrect"

[[ "$(metadata_atime "$RECOVER_INO")" == "$RECOVER_ATIME" ]] ||
    fail "recovered SETATTR atime incorrect"

[[ "$(metadata_mtime "$RECOVER_INO")" == "$RECOVER_MTIME" ]] ||
    fail "recovered SETATTR mtime incorrect"

[[ "$(metadata_ctime "$RECOVER_INO")" == "$RECOVER_CTIME" ]] ||
    fail "recovered SETATTR ctime incorrect"

RECOVER_APPLIED="$(
    sqlite3 volume/metadata.db \
        "SELECT COUNT(*)
         FROM applied_tx
         WHERE txid=$RECOVER_TXID;"
)"

[[ "$RECOVER_APPLIED" == "1" ]] ||
    fail "recovered SETATTR not marked applied"

assert_block_exact \
    "$RECOVER_INO" \
    "$RECOVER_CONTENT"

pass "committed SETATTR recovered successfully"

# ============================================================
# RECOVERY IDEMPOTENCY
# ============================================================

echo
echo "[10/13] Recovered SETATTR idempotency..."

start_ccfs

grep -q \
    "replayed: 0" \
    "$LOG_FILE" ||
    fail "recovered SETATTR replayed twice"

grep -q \
    "already applied: 1" \
    "$LOG_FILE" ||
    fail "recovered SETATTR not recognized as applied"

assert_mode \
    "$MOUNT_DIR/$RECOVER_NAME" \
    "$RECOVER_MODE"

assert_mtime \
    "$MOUNT_DIR/$RECOVER_NAME" \
    "$RECOVER_MTIME"

stop_ccfs

pass "recovered SETATTR is idempotent"

# ============================================================
# INCOMPLETE INJECTION
# ============================================================

echo
echo "[11/13] Injecting incomplete SETATTR..."

INCOMPLETE_TXID=$((RECOVER_TXID + 1))

append_setattr_transaction \
    "$INCOMPLETE_TXID" \
    "$INCOMPLETE_INO" \
    "$INCOMPLETE_MODE" \
    "$INCOMPLETE_ATIME" \
    "$INCOMPLETE_MTIME" \
    "$INCOMPLETE_CTIME" \
    "no"

[[ "$(metadata_row "$INCOMPLETE_INO")" == "$INCOMPLETE_ORIGINAL_ROW" ]] ||
    fail "incomplete SETATTR changed metadata before restart"

pass "incomplete SETATTR BEGIN injected"

# ============================================================
# INCOMPLETE MUST BE IGNORED
# ============================================================

echo
echo "[12/13] Incomplete SETATTR must be ignored..."

start_ccfs

grep -q \
    "incomplete ignored: 1" \
    "$LOG_FILE" ||
    fail "startup did not report incomplete SETATTR"

grep -q \
    "replayed: 0" \
    "$LOG_FILE" ||
    fail "incomplete SETATTR caused replay"

stop_ccfs

[[ "$(metadata_row "$INCOMPLETE_INO")" == "$INCOMPLETE_ORIGINAL_ROW" ]] ||
    fail "incomplete SETATTR modified metadata"

INCOMPLETE_APPLIED="$(
    sqlite3 volume/metadata.db \
        "SELECT COUNT(*)
         FROM applied_tx
         WHERE txid=$INCOMPLETE_TXID;"
)"

[[ "$INCOMPLETE_APPLIED" == "0" ]] ||
    fail "incomplete SETATTR incorrectly marked applied"

assert_block_exact \
    "$INCOMPLETE_INO" \
    "$INCOMPLETE_CONTENT"

pass "incomplete SETATTR safely ignored"

# ============================================================
# FINAL STATUS / CLEANUP
# ============================================================

echo
echo "[13/13] Final status, integrity and cleanup..."

run_integrity_check

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
    "Replayed transactions:       0" \
    "$STATUS_FILE" ||
    fail "unexpected replayed count"

grep -q \
    "Already applied transactions:1" \
    "$STATUS_FILE" ||
    fail "unexpected already-applied count"

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

run_integrity_check

trap - EXIT INT TERM

rm -f \
    "$STATUS_FILE" \
    "$INTEGRITY_FILE"

echo
echo "========================================"
echo " ALL CCFS SETATTR RECOVERY TESTS PASSED"
echo "========================================"
echo