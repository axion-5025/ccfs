#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

MOUNT_DIR="mount"
LOG_FILE="/tmp/ccfs-rmdir-recovery.log"
STATUS_FILE="/tmp/ccfs-rmdir-recovery-status.txt"
INTEGRITY_FILE="/tmp/ccfs-rmdir-recovery-integrity.txt"

RUN_ID="$(date +%s)"

NORMAL_DIR="rmdir-normal-$RUN_ID"
RECOVER_DIR="rmdir-recover-$RUN_ID"
INCOMPLETE_DIR="rmdir-incomplete-$RUN_ID"

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

metadata_count() {
    local ino="$1"

    sqlite3 volume/metadata.db \
        "SELECT COUNT(*)
         FROM entries
         WHERE ino=$ino;"
}

append_rmdir_transaction() {
    local txid="$1"
    local ino="$2"
    local committed="$3"

    python3 - \
        "$txid" \
        "$ino" \
        "$committed" <<'PY'
import os
import struct
import sys
from pathlib import Path

txid = int(sys.argv[1])
ino = int(sys.argv[2])
committed = sys.argv[3] == "yes"

MAGIC = b"CCFSRMD1"

payload = (
    MAGIC
    + struct.pack("<Q", ino)
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

operation_hex = b"RMDIR".hex()
payload_hex = payload.hex()

begin_body = (
    f"BEGIN|{txid}|{operation_hex}|{payload_hex}"
)

journal_path = Path("volume/journal.log")
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
            record(f"COMMIT|{txid}")
        )

    journal.flush()
    os.fsync(journal.fileno())
PY
}

cleanup() {
    set +e

    if is_mounted; then
        rmdir "$MOUNT_DIR/$NORMAL_DIR" 2>/dev/null || true
        rmdir "$MOUNT_DIR/$RECOVER_DIR" 2>/dev/null || true
        rmdir "$MOUNT_DIR/$INCOMPLETE_DIR" 2>/dev/null || true
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
        fi
    done

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
echo " CCFS RMDIR Recovery Test Suite"
echo "========================================"
echo

echo "[1/11] Building CCFS..."

cargo build --bin ccfs >/dev/null

pass "cargo build"

echo
echo "[2/11] Preparing isolated directories..."

stop_ccfs

./target/debug/ccfs \
    --recovery-status \
    >/dev/null

clear_recovery_state

start_ccfs

mkdir "$MOUNT_DIR/$NORMAL_DIR"
mkdir "$MOUNT_DIR/$RECOVER_DIR"
mkdir "$MOUNT_DIR/$INCOMPLETE_DIR"

NORMAL_INO="$(
    stat -c '%i' \
        "$MOUNT_DIR/$NORMAL_DIR"
)"

RECOVER_INO="$(
    stat -c '%i' \
        "$MOUNT_DIR/$RECOVER_DIR"
)"

INCOMPLETE_INO="$(
    stat -c '%i' \
        "$MOUNT_DIR/$INCOMPLETE_DIR"
)"

[[ -n "$NORMAL_INO" ]] ||
    fail "normal directory inode missing"

[[ -n "$RECOVER_INO" ]] ||
    fail "recovery directory inode missing"

[[ -n "$INCOMPLETE_INO" ]] ||
    fail "incomplete directory inode missing"

stop_ccfs

# Ignore setup metadata history.
clear_recovery_state

pass "isolated RMDIR test directories ready"

echo
echo "[3/11] Normal journaled RMDIR..."

start_ccfs

rmdir "$MOUNT_DIR/$NORMAL_DIR"

[[ ! -e "$MOUNT_DIR/$NORMAL_DIR" ]] ||
    fail "normal RMDIR left directory visible"

stop_ccfs

[[ "$(metadata_count "$NORMAL_INO")" == "0" ]] ||
    fail "normal RMDIR left SQLite metadata"

APPLIED_COUNT="$(
    sqlite3 volume/metadata.db \
        "SELECT COUNT(*)
         FROM applied_tx;"
)"

[[ "$APPLIED_COUNT" == "1" ]] ||
    fail "normal RMDIR transaction not marked applied"

pass "normal RMDIR journaled and applied"

echo
echo "[4/11] Restart idempotency after normal RMDIR..."

start_ccfs

[[ ! -e "$MOUNT_DIR/$NORMAL_DIR" ]] ||
    fail "removed directory returned after restart"

grep -q \
    "replayed: 0" \
    "$LOG_FILE" ||
    fail "normal RMDIR replayed unexpectedly"

grep -q \
    "already applied: 1" \
    "$LOG_FILE" ||
    fail "normal RMDIR not recognized as applied"

stop_ccfs

pass "normal RMDIR survived restart"

echo
echo "[5/11] Checking filesystem integrity..."

./target/debug/ccfs \
    --check-integrity \
    >"$INTEGRITY_FILE"

grep -q \
    "ALL CCFS BLOCKS PASSED INTEGRITY CHECK" \
    "$INTEGRITY_FILE" ||
    fail "integrity failed after normal RMDIR"

pass "normal RMDIR preserved filesystem integrity"

echo
echo "[6/11] Injecting committed-but-not-applied RMDIR..."

clear_recovery_state

RECOVER_TXID="$(
    python3 -c \
        'import time; print(time.time_ns())'
)"

append_rmdir_transaction \
    "$RECOVER_TXID" \
    "$RECOVER_INO" \
    "yes"

[[ "$(metadata_count "$RECOVER_INO")" == "1" ]] ||
    fail "recovery directory metadata missing before replay"

pass "committed RMDIR injected without applying metadata"

echo
echo "[7/11] Startup replay of committed RMDIR..."

start_ccfs

grep -q \
    "replayed: 1" \
    "$LOG_FILE" ||
    fail "startup did not replay committed RMDIR"

[[ ! -e "$MOUNT_DIR/$RECOVER_DIR" ]] ||
    fail "committed RMDIR directory still visible"

stop_ccfs

[[ "$(metadata_count "$RECOVER_INO")" == "0" ]] ||
    fail "recovered RMDIR left metadata"

RECOVER_APPLIED="$(
    sqlite3 volume/metadata.db \
        "SELECT COUNT(*)
         FROM applied_tx
         WHERE txid=$RECOVER_TXID;"
)"

[[ "$RECOVER_APPLIED" == "1" ]] ||
    fail "recovered RMDIR not marked applied"

pass "committed RMDIR recovered successfully"

echo
echo "[8/11] Recovered RMDIR idempotency..."

start_ccfs

grep -q \
    "replayed: 0" \
    "$LOG_FILE" ||
    fail "recovered RMDIR replayed twice"

grep -q \
    "already applied: 1" \
    "$LOG_FILE" ||
    fail "recovered RMDIR not recognized as applied"

[[ ! -e "$MOUNT_DIR/$RECOVER_DIR" ]] ||
    fail "removed directory returned after second restart"

stop_ccfs

pass "recovered RMDIR is idempotent"

echo
echo "[9/11] Injecting incomplete RMDIR..."

INCOMPLETE_TXID=$((RECOVER_TXID + 1))

append_rmdir_transaction \
    "$INCOMPLETE_TXID" \
    "$INCOMPLETE_INO" \
    "no"

pass "incomplete RMDIR BEGIN injected"

echo
echo "[10/11] Incomplete RMDIR must be ignored..."

start_ccfs

grep -q \
    "incomplete ignored: 1" \
    "$LOG_FILE" ||
    fail "startup did not report incomplete RMDIR"

grep -q \
    "replayed: 0" \
    "$LOG_FILE" ||
    fail "incomplete RMDIR caused replay"

[[ -d "$MOUNT_DIR/$INCOMPLETE_DIR" ]] ||
    fail "incomplete RMDIR removed directory"

stop_ccfs

[[ "$(metadata_count "$INCOMPLETE_INO")" == "1" ]] ||
    fail "incomplete RMDIR removed metadata"

INCOMPLETE_APPLIED="$(
    sqlite3 volume/metadata.db \
        "SELECT COUNT(*)
         FROM applied_tx
         WHERE txid=$INCOMPLETE_TXID;"
)"

[[ "$INCOMPLETE_APPLIED" == "0" ]] ||
    fail "incomplete RMDIR incorrectly marked applied"

pass "incomplete RMDIR safely ignored"

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

rmdir "$MOUNT_DIR/$INCOMPLETE_DIR"

stop_ccfs

INCOMPLETE_INO=""

clear_recovery_state

./target/debug/ccfs \
    --check-integrity \
    >"$INTEGRITY_FILE"

grep -q \
    "ALL CCFS BLOCKS PASSED INTEGRITY CHECK" \
    "$INTEGRITY_FILE" ||
    fail "integrity failed after RMDIR cleanup"

trap - EXIT INT TERM

rm -f "$STATUS_FILE"
rm -f "$INTEGRITY_FILE"

echo
echo "========================================"
echo " ALL CCFS RMDIR RECOVERY TESTS PASSED"
echo "========================================"
echo