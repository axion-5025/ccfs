#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

MOUNT_DIR="mount"
LOG_FILE="/tmp/ccfs-delete-recovery.log"
STATUS_FILE="/tmp/ccfs-delete-recovery-status.txt"
INTEGRITY_FILE="/tmp/ccfs-delete-recovery-integrity.txt"

RUN_ID="$(date +%s)"

NORMAL_NAME="delete-normal-$RUN_ID.txt"
RECOVER_NAME="delete-recover-$RUN_ID.txt"
INCOMPLETE_NAME="delete-incomplete-$RUN_ID.txt"

NORMAL_CONTENT="CCFS normal delete $RUN_ID"
RECOVER_CONTENT="CCFS committed delete recovery $RUN_ID"
INCOMPLETE_CONTENT="CCFS incomplete delete must survive $RUN_ID"

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

assert_content() {
    local path="$1"
    local expected="$2"

    local actual

    actual="$(cat "$path")"

    [[ "$actual" == "$expected" ]] ||
        fail "unexpected file contents for $path"
}

append_delete_transaction() {
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

MAGIC = b"CCFSDEL1"

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

operation_hex = b"DELETE".hex()
payload_hex = payload.hex()

begin_body = (
    f"BEGIN|{txid}|{operation_hex}|{payload_hex}"
)

journal_path = Path("volume/journal.log")
journal_path.parent.mkdir(parents=True, exist_ok=True)

with journal_path.open("a", encoding="ascii") as journal:
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
        rm -f "$MOUNT_DIR/$NORMAL_NAME" 2>/dev/null || true
        rm -f "$MOUNT_DIR/$RECOVER_NAME" 2>/dev/null || true
        rm -f "$MOUNT_DIR/$INCOMPLETE_NAME" 2>/dev/null || true
    fi

    stop_ccfs

    for ino in \
        "${NORMAL_INO:-}" \
        "${RECOVER_INO:-}" \
        "${INCOMPLETE_INO:-}"
    do
        if [[ -n "$ino" ]]; then
            sqlite3 volume/metadata.db \
                "DELETE FROM entries WHERE ino=$ino;" \
                >/dev/null 2>&1 || true

            rm -f "volume/blocks/$ino.bin"
            rm -f "volume/blocks/$ino.checksum"
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
echo " CCFS DELETE Recovery Test Suite"
echo "========================================"
echo

echo "[1/11] Building CCFS..."

cargo build --bin ccfs >/dev/null

pass "cargo build"

echo
echo "[2/11] Preparing isolated DELETE test files..."

stop_ccfs

./target/debug/ccfs \
    --recovery-status \
    >/dev/null

clear_recovery_state

start_ccfs

printf '%s' "$NORMAL_CONTENT" \
    > "$MOUNT_DIR/$NORMAL_NAME"

printf '%s' "$RECOVER_CONTENT" \
    > "$MOUNT_DIR/$RECOVER_NAME"

printf '%s' "$INCOMPLETE_CONTENT" \
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

assert_content \
    "$MOUNT_DIR/$NORMAL_NAME" \
    "$NORMAL_CONTENT"

assert_content \
    "$MOUNT_DIR/$RECOVER_NAME" \
    "$RECOVER_CONTENT"

assert_content \
    "$MOUNT_DIR/$INCOMPLETE_NAME" \
    "$INCOMPLETE_CONTENT"

stop_ccfs

# CREATE/WRITE setup history is irrelevant to this suite.
clear_recovery_state

pass "isolated DELETE test state ready"

echo
echo "[3/11] Normal journaled DELETE..."

start_ccfs

rm "$MOUNT_DIR/$NORMAL_NAME"

[[ ! -e "$MOUNT_DIR/$NORMAL_NAME" ]] ||
    fail "normal DELETE left file visible"

stop_ccfs

[[ "$(metadata_count "$NORMAL_INO")" == "0" ]] ||
    fail "normal DELETE left SQLite metadata"

[[ ! -e "volume/blocks/$NORMAL_INO.bin" ]] ||
    fail "normal DELETE left data block"

[[ ! -e "volume/blocks/$NORMAL_INO.checksum" ]] ||
    fail "normal DELETE left checksum"

APPLIED_COUNT="$(
    sqlite3 volume/metadata.db \
        "SELECT COUNT(*) FROM applied_tx;"
)"

[[ "$APPLIED_COUNT" == "1" ]] ||
    fail "normal DELETE transaction not marked applied"

pass "normal DELETE journaled and applied"

echo
echo "[4/11] Restart idempotency after normal DELETE..."

start_ccfs

[[ ! -e "$MOUNT_DIR/$NORMAL_NAME" ]] ||
    fail "deleted file returned after restart"

grep -q \
    "replayed: 0" \
    "$LOG_FILE" ||
    fail "normal DELETE replayed unexpectedly"

grep -q \
    "already applied: 1" \
    "$LOG_FILE" ||
    fail "normal DELETE not recognized as applied"

stop_ccfs

pass "normal DELETE survived restart"

echo
echo "[5/11] Checking integrity after normal DELETE..."

./target/debug/ccfs \
    --check-integrity \
    >"$INTEGRITY_FILE"

grep -q \
    "ALL CCFS BLOCKS PASSED INTEGRITY CHECK" \
    "$INTEGRITY_FILE" ||
    fail "integrity failed after normal DELETE"

pass "normal DELETE left no orphan blocks"

echo
echo "[6/11] Injecting committed-but-not-applied DELETE..."

clear_recovery_state

RECOVER_TXID="$(
    python3 -c 'import time; print(time.time_ns())'
)"

append_delete_transaction \
    "$RECOVER_TXID" \
    "$RECOVER_INO" \
    "yes"

[[ "$(metadata_count "$RECOVER_INO")" == "1" ]] ||
    fail "recovery target metadata missing before replay"

[[ -f "volume/blocks/$RECOVER_INO.bin" ]] ||
    fail "recovery target block missing before replay"

pass "committed DELETE injected without applying state"

echo
echo "[7/11] Startup replay of committed DELETE..."

start_ccfs

grep -q \
    "replayed: 1" \
    "$LOG_FILE" ||
    fail "startup did not replay committed DELETE"

[[ ! -e "$MOUNT_DIR/$RECOVER_NAME" ]] ||
    fail "committed DELETE target still visible"

stop_ccfs

[[ "$(metadata_count "$RECOVER_INO")" == "0" ]] ||
    fail "recovered DELETE left metadata"

[[ ! -e "volume/blocks/$RECOVER_INO.bin" ]] ||
    fail "recovered DELETE left data block"

[[ ! -e "volume/blocks/$RECOVER_INO.checksum" ]] ||
    fail "recovered DELETE left checksum"

RECOVER_APPLIED="$(
    sqlite3 volume/metadata.db \
        "SELECT COUNT(*)
         FROM applied_tx
         WHERE txid=$RECOVER_TXID;"
)"

[[ "$RECOVER_APPLIED" == "1" ]] ||
    fail "recovered DELETE not marked applied"

pass "committed DELETE recovered successfully"

echo
echo "[8/11] Recovered DELETE idempotency..."

start_ccfs

grep -q \
    "replayed: 0" \
    "$LOG_FILE" ||
    fail "recovered DELETE replayed twice"

grep -q \
    "already applied: 1" \
    "$LOG_FILE" ||
    fail "recovered DELETE not recognized as applied"

[[ ! -e "$MOUNT_DIR/$RECOVER_NAME" ]] ||
    fail "deleted file returned after second restart"

stop_ccfs

pass "recovered DELETE is idempotent"

echo
echo "[9/11] Injecting incomplete DELETE..."

INCOMPLETE_TXID=$((RECOVER_TXID + 1))

append_delete_transaction \
    "$INCOMPLETE_TXID" \
    "$INCOMPLETE_INO" \
    "no"

pass "incomplete DELETE BEGIN injected"

echo
echo "[10/11] Incomplete DELETE must be ignored..."

start_ccfs

grep -q \
    "incomplete ignored: 1" \
    "$LOG_FILE" ||
    fail "startup did not report incomplete DELETE"

grep -q \
    "replayed: 0" \
    "$LOG_FILE" ||
    fail "incomplete DELETE caused replay"

[[ -f "$MOUNT_DIR/$INCOMPLETE_NAME" ]] ||
    fail "incomplete DELETE removed file"

assert_content \
    "$MOUNT_DIR/$INCOMPLETE_NAME" \
    "$INCOMPLETE_CONTENT"

stop_ccfs

[[ "$(metadata_count "$INCOMPLETE_INO")" == "1" ]] ||
    fail "incomplete DELETE removed metadata"

[[ -f "volume/blocks/$INCOMPLETE_INO.bin" ]] ||
    fail "incomplete DELETE removed data block"

[[ -f "volume/blocks/$INCOMPLETE_INO.checksum" ]] ||
    fail "incomplete DELETE removed checksum"

INCOMPLETE_APPLIED="$(
    sqlite3 volume/metadata.db \
        "SELECT COUNT(*)
         FROM applied_tx
         WHERE txid=$INCOMPLETE_TXID;"
)"

[[ "$INCOMPLETE_APPLIED" == "0" ]] ||
    fail "incomplete DELETE incorrectly marked applied"

pass "incomplete DELETE safely ignored"

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

rm "$MOUNT_DIR/$INCOMPLETE_NAME"

stop_ccfs

INCOMPLETE_INO=""

clear_recovery_state

./target/debug/ccfs \
    --check-integrity \
    >"$INTEGRITY_FILE"

grep -q \
    "ALL CCFS BLOCKS PASSED INTEGRITY CHECK" \
    "$INTEGRITY_FILE" ||
    fail "integrity failed after DELETE recovery cleanup"

trap - EXIT INT TERM

rm -f "$STATUS_FILE"
rm -f "$INTEGRITY_FILE"

echo
echo "========================================"
echo " ALL CCFS DELETE RECOVERY TESTS PASSED"
echo "========================================"
echo