#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

MOUNT_DIR="mount"

LOG_FILE="/tmp/ccfs-mkdir-recovery.log"
STATUS_FILE="/tmp/ccfs-mkdir-recovery-status.txt"
INTEGRITY_FILE="/tmp/ccfs-mkdir-recovery-integrity.txt"

RUN_ID="$(date +%s)"

NORMAL_DIR="mkdir-normal-$RUN_ID"
RECOVER_DIR="mkdir-recover-$RUN_ID"
INCOMPLETE_DIR="mkdir-incomplete-$RUN_ID"

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

metadata_count_by_name() {
    local name="$1"

    sqlite3 volume/metadata.db \
        "SELECT COUNT(*)
         FROM entries
         WHERE name='$name';"
}

metadata_count_by_ino() {
    local ino="$1"

    sqlite3 volume/metadata.db \
        "SELECT COUNT(*)
         FROM entries
         WHERE ino=$ino;"
}

metadata_kind() {
    local ino="$1"

    sqlite3 volume/metadata.db \
        "SELECT kind
         FROM entries
         WHERE ino=$ino;"
}

append_mkdir_transaction() {
    local txid="$1"
    local ino="$2"
    local name="$3"
    local committed="$4"

    python3 - \
        "$txid" \
        "$ino" \
        "$name" \
        "$committed" <<'PY'
import os
import struct
import sys
import time
from pathlib import Path

txid = int(sys.argv[1])
ino = int(sys.argv[2])
name = sys.argv[3]
committed = sys.argv[4] == "yes"

MAGIC = b"CCFSMKD1"

parent = 1
perm = 0o755
now = int(time.time())

name_bytes = name.encode("utf-8")

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
    "<H",
    perm,
)

payload += struct.pack(
    "<q",
    now,
)

payload += struct.pack(
    "<q",
    now,
)

payload += struct.pack(
    "<q",
    now,
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
    b"MKDIR".hex()
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
        rmdir \
            "$MOUNT_DIR/$NORMAL_DIR" \
            2>/dev/null || true

        rmdir \
            "$MOUNT_DIR/$RECOVER_DIR" \
            2>/dev/null || true

        rmdir \
            "$MOUNT_DIR/$INCOMPLETE_DIR" \
            2>/dev/null || true
    fi

    stop_ccfs

    sqlite3 volume/metadata.db \
        "DELETE FROM entries
         WHERE name IN (
             '$NORMAL_DIR',
             '$RECOVER_DIR',
             '$INCOMPLETE_DIR'
         );" \
        >/dev/null 2>&1 || true

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
echo " CCFS MKDIR Recovery Test Suite"
echo "========================================"
echo

# ============================================================
# BUILD
# ============================================================

echo "[1/11] Building CCFS..."

cargo build --bin ccfs >/dev/null

pass "cargo build"

# ============================================================
# CLEAN STATE
# ============================================================

echo
echo "[2/11] Initializing clean recovery state..."

stop_ccfs

./target/debug/ccfs \
    --recovery-status \
    >/dev/null

clear_recovery_state

pass "journal and applied_tx cleared"

# ============================================================
# NORMAL MKDIR
# ============================================================

echo
echo "[3/11] Normal journaled MKDIR..."

start_ccfs

mkdir \
    "$MOUNT_DIR/$NORMAL_DIR"

[[ -d "$MOUNT_DIR/$NORMAL_DIR" ]] ||
    fail "normal MKDIR did not create directory"

NORMAL_INO="$(
    stat -c '%i' \
        "$MOUNT_DIR/$NORMAL_DIR"
)"

[[ -n "$NORMAL_INO" ]] ||
    fail "normal MKDIR inode missing"

stop_ccfs

[[ "$(metadata_count_by_name "$NORMAL_DIR")" == "1" ]] ||
    fail "normal MKDIR metadata missing"

[[ "$(metadata_kind "$NORMAL_INO")" == "1" ]] ||
    fail "normal MKDIR metadata is not directory kind"

APPLIED_COUNT="$(
    sqlite3 volume/metadata.db \
        "SELECT COUNT(*)
         FROM applied_tx;"
)"

[[ "$APPLIED_COUNT" == "1" ]] ||
    fail "normal MKDIR transaction not marked applied"

pass "normal MKDIR journaled and applied"

# ============================================================
# NORMAL RESTART IDEMPOTENCY
# ============================================================

echo
echo "[4/11] Restart idempotency after normal MKDIR..."

start_ccfs

[[ -d "$MOUNT_DIR/$NORMAL_DIR" ]] ||
    fail "normal MKDIR disappeared after restart"

grep -q \
    "replayed: 0" \
    "$LOG_FILE" ||
    fail "normal MKDIR replayed unexpectedly"

grep -q \
    "already applied: 1" \
    "$LOG_FILE" ||
    fail "normal MKDIR not recognized as applied"

stop_ccfs

[[ "$(metadata_count_by_name "$NORMAL_DIR")" == "1" ]] ||
    fail "restart duplicated normal MKDIR metadata"

pass "normal MKDIR survived restart without duplicate replay"

# ============================================================
# INTEGRITY
# ============================================================

echo
echo "[5/11] Checking filesystem integrity after normal MKDIR..."

./target/debug/ccfs \
    --check-integrity \
    >"$INTEGRITY_FILE"

grep -q \
    "ALL CCFS BLOCKS PASSED INTEGRITY CHECK" \
    "$INTEGRITY_FILE" ||
    fail "integrity failed after normal MKDIR"

pass "normal MKDIR preserved filesystem integrity"

# ============================================================
# COMMITTED BUT NOT APPLIED MKDIR
# ============================================================

echo
echo "[6/11] Injecting committed-but-not-applied MKDIR..."

MAX_INO="$(
    sqlite3 volume/metadata.db \
        "SELECT COALESCE(MAX(ino), 2)
         FROM entries;"
)"

RECOVER_INO=$((MAX_INO + 1000))

RECOVER_TXID="$(
    python3 -c \
        'import time; print(time.time_ns())'
)"

append_mkdir_transaction \
    "$RECOVER_TXID" \
    "$RECOVER_INO" \
    "$RECOVER_DIR" \
    "yes"

[[ "$(metadata_count_by_name "$RECOVER_DIR")" == "0" ]] ||
    fail "synthetic MKDIR metadata existed before recovery"

pass "committed MKDIR injected without applying metadata"

# ============================================================
# COMMITTED REPLAY
# ============================================================

echo
echo "[7/11] Startup replay of committed MKDIR..."

start_ccfs

grep -q \
    "replayed: 1" \
    "$LOG_FILE" ||
    fail "startup did not replay committed MKDIR"

[[ -d "$MOUNT_DIR/$RECOVER_DIR" ]] ||
    fail "committed MKDIR was not recovered"

RECOVER_VISIBLE_INO="$(
    stat -c '%i' \
        "$MOUNT_DIR/$RECOVER_DIR"
)"

[[ "$RECOVER_VISIBLE_INO" == "$RECOVER_INO" ]] ||
    fail "recovered MKDIR inode mismatch"

stop_ccfs

[[ "$(metadata_count_by_ino "$RECOVER_INO")" == "1" ]] ||
    fail "recovered MKDIR metadata missing"

[[ "$(metadata_kind "$RECOVER_INO")" == "1" ]] ||
    fail "recovered MKDIR metadata is not directory kind"

RECOVER_APPLIED="$(
    sqlite3 volume/metadata.db \
        "SELECT COUNT(*)
         FROM applied_tx
         WHERE txid=$RECOVER_TXID;"
)"

[[ "$RECOVER_APPLIED" == "1" ]] ||
    fail "recovered MKDIR not marked applied"

pass "committed MKDIR recovered successfully"

# ============================================================
# RECOVERED IDEMPOTENCY
# ============================================================

echo
echo "[8/11] Recovered MKDIR idempotency..."

start_ccfs

grep -q \
    "replayed: 0" \
    "$LOG_FILE" ||
    fail "recovered MKDIR replayed twice"

grep -q \
    "already applied: 2" \
    "$LOG_FILE" ||
    fail "recovered MKDIR transactions not recognized as applied"

[[ -d "$MOUNT_DIR/$RECOVER_DIR" ]] ||
    fail "recovered directory missing after second restart"

stop_ccfs

[[ "$(metadata_count_by_name "$RECOVER_DIR")" == "1" ]] ||
    fail "second recovery duplicated MKDIR metadata"

pass "recovered MKDIR is idempotent"

# ============================================================
# INCOMPLETE MKDIR
# ============================================================

echo
echo "[9/11] Injecting incomplete MKDIR..."

INCOMPLETE_INO=$((RECOVER_INO + 1))
INCOMPLETE_TXID=$((RECOVER_TXID + 1))

append_mkdir_transaction \
    "$INCOMPLETE_TXID" \
    "$INCOMPLETE_INO" \
    "$INCOMPLETE_DIR" \
    "no"

[[ "$(metadata_count_by_name "$INCOMPLETE_DIR")" == "0" ]] ||
    fail "incomplete MKDIR metadata existed before restart"

pass "incomplete MKDIR BEGIN injected"

# ============================================================
# INCOMPLETE MUST BE IGNORED
# ============================================================

echo
echo "[10/11] Incomplete MKDIR must be ignored..."

start_ccfs

grep -q \
    "incomplete ignored: 1" \
    "$LOG_FILE" ||
    fail "startup did not report incomplete MKDIR"

grep -q \
    "replayed: 0" \
    "$LOG_FILE" ||
    fail "incomplete MKDIR caused replay"

if [[ -e "$MOUNT_DIR/$INCOMPLETE_DIR" ]]; then
    fail "incomplete MKDIR became visible"
fi

stop_ccfs

[[ "$(metadata_count_by_name "$INCOMPLETE_DIR")" == "0" ]] ||
    fail "incomplete MKDIR metadata was applied"

INCOMPLETE_APPLIED="$(
    sqlite3 volume/metadata.db \
        "SELECT COUNT(*)
         FROM applied_tx
         WHERE txid=$INCOMPLETE_TXID;"
)"

[[ "$INCOMPLETE_APPLIED" == "0" ]] ||
    fail "incomplete MKDIR incorrectly marked applied"

pass "incomplete MKDIR safely ignored"

# ============================================================
# FINAL STATUS + CLEANUP
# ============================================================

echo
echo "[11/11] Final status, cleanup and integrity..."

./target/debug/ccfs \
    --recovery-status \
    >"$STATUS_FILE"

cat "$STATUS_FILE"

grep -q \
    "Total transactions:          3" \
    "$STATUS_FILE" ||
    fail "unexpected transaction total"

grep -q \
    "Committed transactions:      2" \
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
    "Already applied transactions:2" \
    "$STATUS_FILE" ||
    fail "unexpected already-applied count"

APPLIED_RECORDS="$(
    sqlite3 volume/metadata.db \
        "SELECT COUNT(*)
         FROM applied_tx;"
)"

[[ "$APPLIED_RECORDS" == "2" ]] ||
    fail "unexpected applied transaction record count"

start_ccfs

rmdir \
    "$MOUNT_DIR/$NORMAL_DIR"

rmdir \
    "$MOUNT_DIR/$RECOVER_DIR"

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
    fail "integrity failed after MKDIR cleanup"

trap - EXIT INT TERM

rm -f \
    "$STATUS_FILE" \
    "$INTEGRITY_FILE"

echo
echo "========================================"
echo " ALL CCFS MKDIR RECOVERY TESTS PASSED"
echo "========================================"
echo