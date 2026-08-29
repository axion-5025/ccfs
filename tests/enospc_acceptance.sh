#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

MOUNT_DIR="mount"

RUN_ID="$(date +%s)"

DATA_FILE="enospc-data-$RUN_ID.txt"
JOURNAL_FILE="enospc-journal-$RUN_ID.txt"

DATA_OLD="CCFS-ENOSPC-OLD-$RUN_ID"
DATA_NEW="CCFS-ENOSPC-NEW-$RUN_ID"

JOURNAL_OLD="CCFS-JOURNAL-OLD-$RUN_ID"
JOURNAL_NEW="CCFS-JOURNAL-NEW-$RUN_ID"

NORMAL_LOG="/tmp/ccfs-enospc-normal.log"
DATA_LOG="/tmp/ccfs-enospc-data.log"
JOURNAL_LOG="/tmp/ccfs-enospc-journal.log"
INTEGRITY_LOG="/tmp/ccfs-enospc-integrity.log"
CHECKPOINT_LOG="/tmp/ccfs-enospc-checkpoint.log"

CCFS_PID=""
BACKUP_ROOT=""
DATA_INO=""

fail() {
    echo
    echo "TEST FAILED: $1"
    echo

    echo "Normal log:"
    echo "----------------------------------------"
    cat "$NORMAL_LOG" 2>/dev/null || true

    echo
    echo "Data ENOSPC log:"
    echo "----------------------------------------"
    cat "$DATA_LOG" 2>/dev/null || true

    echo
    echo "Journal ENOSPC log:"
    echo "----------------------------------------"
    cat "$JOURNAL_LOG" 2>/dev/null || true

    echo
    echo "Integrity log:"
    echo "----------------------------------------"
    cat "$INTEGRITY_LOG" 2>/dev/null || true

    exit 1
}

pass() {
    echo "PASS: $1"
}

is_mounted() {
    mountpoint -q "$MOUNT_DIR"
}

detach_mount() {
    set +e

    fusermount3 -u "$MOUNT_DIR" 2>/dev/null || true
    fusermount3 -uz "$MOUNT_DIR" 2>/dev/null || true

    sleep 0.1

    mkdir -p "$MOUNT_DIR" 2>/dev/null || true

    set -e
}

stop_ccfs() {
    set +e

    detach_mount

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

    detach_mount
}

wait_for_mount() {
    local pid="$1"

    for _ in $(seq 1 120); do
        if is_mounted; then
            return 0
        fi

        if ! kill -0 "$pid" 2>/dev/null; then
            return 1
        fi

        sleep 0.05
    done

    return 1
}

start_ccfs() {
    stop_ccfs

    : > "$NORMAL_LOG"

    ./target/debug/ccfs \
        >"$NORMAL_LOG" 2>&1 &

    CCFS_PID=$!

    wait_for_mount "$CCFS_PID" ||
        fail "CCFS failed to mount"
}

start_ccfs_enospc() {
    local point="$1"
    local log="$2"

    stop_ccfs

    : > "$log"

    env \
        CCFS_ENOSPC_POINT="$point" \
        ./target/debug/ccfs \
        >"$log" 2>&1 &

    CCFS_PID=$!

    wait_for_mount "$CCFS_PID" ||
        fail "CCFS failed to mount with ENOSPC failpoint $point"
}

snapshot_volume() {
    stop_ccfs

    BACKUP_ROOT="$(
        mktemp -d /tmp/ccfs-enospc-backup.XXXXXX
    )"

    if [[ -d volume ]]; then
        cp -a volume "$BACKUP_ROOT/volume"
    else
        mkdir -p "$BACKUP_ROOT/volume"
    fi
}

restore_volume() {
    if [[ -z "${BACKUP_ROOT:-}" ]]; then
        return
    fi

    stop_ccfs

    rm -rf volume
    cp -a "$BACKUP_ROOT/volume" volume

    rm -rf "$BACKUP_ROOT"
    BACKUP_ROOT=""
}

cleanup() {
    set +e

    restore_volume

    rm -f "$NORMAL_LOG"
    rm -f "$DATA_LOG"
    rm -f "$JOURNAL_LOG"
    rm -f "$INTEGRITY_LOG"
    rm -f "$CHECKPOINT_LOG"

    set -e
}

run_integrity() {
    stop_ccfs

    ./target/debug/ccfs \
        --check-integrity \
        >"$INTEGRITY_LOG" 2>&1 ||
    {
        cat "$INTEGRITY_LOG"
        fail "integrity check failed"
    }

    grep -q \
        "ALL CCFS BLOCKS PASSED INTEGRITY CHECK" \
        "$INTEGRITY_LOG" ||
        fail "integrity PASS marker missing"
}

checkpoint_clean() {
    stop_ccfs

    ./target/debug/ccfs \
        --checkpoint \
        >"$CHECKPOINT_LOG" 2>&1 ||
    {
        cat "$CHECKPOINT_LOG"
        fail "checkpoint failed"
    }

    local status

    status="$(
        ./target/debug/ccfs --recovery-status
    )"

    grep -q \
        "Total transactions:          0" \
        <<<"$status" ||
        fail "journal not empty after checkpoint"
}

assert_file_content() {
    local path="$1"
    local expected="$2"

    [[ -f "$path" ]] ||
        fail "expected file missing: $path"

    local actual

    actual="$(cat "$path")"

    [[ "$actual" == "$expected" ]] ||
        fail "file content mismatch: $path"
}

trap cleanup EXIT INT TERM

echo
echo "========================================"
echo " CCFS ENOSPC ACCEPTANCE TESTS"
echo "========================================"
echo

fusermount3 -u "$MOUNT_DIR" 2>/dev/null || true
fusermount3 -uz "$MOUNT_DIR" 2>/dev/null || true
sleep 0.1

mkdir -p "$MOUNT_DIR"

echo "[1/8] Preserving volume and building CCFS..."

snapshot_volume

cargo build --bin ccfs >/dev/null

rm -rf volume
mkdir -p volume/blocks

start_ccfs

printf '%s' "$DATA_OLD" \
    > "$MOUNT_DIR/$DATA_FILE"

printf '%s' "$JOURNAL_OLD" \
    > "$MOUNT_DIR/$JOURNAL_FILE"

python3 - \
    "$MOUNT_DIR/$DATA_FILE" \
    "$MOUNT_DIR/$JOURNAL_FILE" <<'PY'
import os
import sys

for path in sys.argv[1:]:
    fd = os.open(path, os.O_RDONLY)

    try:
        os.fsync(fd)
    finally:
        os.close(fd)
PY

assert_file_content \
    "$MOUNT_DIR/$DATA_FILE" \
    "$DATA_OLD"

assert_file_content \
    "$MOUNT_DIR/$JOURNAL_FILE" \
    "$JOURNAL_OLD"

stop_ccfs

DATA_INO="$(
    sqlite3 volume/metadata.db \
        "SELECT ino
         FROM entries
         WHERE name='$DATA_FILE'
         LIMIT 1;"
)"

[[ -n "$DATA_INO" ]] ||
    fail "unable to resolve data test inode"

pass "durable baseline files created"

echo
echo "[2/8] Clearing baseline journal history..."

checkpoint_clean

run_integrity

pass "clean recovery state prepared"

echo
echo "[3/8] Simulating storage full during data write..."

start_ccfs_enospc \
    "data_write" \
    "$DATA_LOG"

python3 - \
    "$MOUNT_DIR/$DATA_FILE" \
    "$DATA_NEW" <<'PY'
import errno
import os
import sys

path = sys.argv[1]
payload = sys.argv[2].encode()

fd = os.open(path, os.O_WRONLY)

try:
    try:
        os.write(fd, payload)
    except OSError as error:
        if error.errno != errno.ENOSPC:
            raise RuntimeError(
                f"expected ENOSPC(28), got errno {error.errno}"
            ) from error
    else:
        raise RuntimeError(
            "data write unexpectedly succeeded during ENOSPC"
        )
finally:
    try:
        os.close(fd)
    except OSError:
        pass
PY

grep -q \
    "CCFS ENOSPC failpoint triggered: data_write" \
    "$DATA_LOG" ||
    fail "data-write ENOSPC failpoint marker missing"

pass "data write returned ENOSPC"

echo
echo "[4/8] Verifying failed data write did not publish partial block..."

stop_ccfs

[[ -f "volume/blocks/$DATA_INO.bin" ]] ||
    fail "data backing block missing"

BACKING_DATA="$(
    cat "volume/blocks/$DATA_INO.bin"
)"

[[ "$BACKING_DATA" == "$DATA_OLD" ]] ||
    fail "failed ENOSPC write changed durable data block"

run_integrity

pass "old durable data remained intact after ENOSPC"

echo
echo "[5/8] Restarting without ENOSPC and recovering committed write..."

start_ccfs

assert_file_content \
    "$MOUNT_DIR/$DATA_FILE" \
    "$DATA_NEW"

grep -q \
    "replayed: 1" \
    "$NORMAL_LOG" ||
    fail "committed data-write transaction was not recovered"

stop_ccfs

run_integrity
checkpoint_clean

pass "pending committed write recovered safely after space became available"

echo
echo "[6/8] Simulating storage full during journal write..."

start_ccfs_enospc \
    "journal_write" \
    "$JOURNAL_LOG"

python3 - \
    "$MOUNT_DIR/$JOURNAL_FILE" \
    "$JOURNAL_NEW" <<'PY'
import errno
import os
import sys

path = sys.argv[1]
payload = sys.argv[2].encode()

fd = os.open(path, os.O_WRONLY)

try:
    try:
        os.write(fd, payload)
    except OSError as error:
        if error.errno != errno.ENOSPC:
            raise RuntimeError(
                f"expected ENOSPC(28), got errno {error.errno}"
            ) from error
    else:
        raise RuntimeError(
            "journal write unexpectedly succeeded during ENOSPC"
        )
finally:
    try:
        os.close(fd)
    except OSError:
        pass
PY

grep -q \
    "CCFS ENOSPC failpoint triggered: journal_write" \
    "$JOURNAL_LOG" ||
    fail "journal-write ENOSPC failpoint marker missing"

pass "journal write returned ENOSPC before filesystem mutation"

echo
echo "[7/8] Restarting after journal-write ENOSPC..."

stop_ccfs

start_ccfs

assert_file_content \
    "$MOUNT_DIR/$JOURNAL_FILE" \
    "$JOURNAL_OLD"

grep -q \
    "replayed: 0" \
    "$NORMAL_LOG" ||
    fail "failed journal write unexpectedly created replayable transaction"

stop_ccfs

run_integrity

pass "journal ENOSPC produced no phantom recovery transaction"

echo
echo "[8/8] Final checkpoint, integrity and restoration..."

checkpoint_clean
run_integrity

restore_volume

trap - EXIT INT TERM

rm -f "$NORMAL_LOG"
rm -f "$DATA_LOG"
rm -f "$JOURNAL_LOG"
rm -f "$INTEGRITY_LOG"
rm -f "$CHECKPOINT_LOG"

echo
echo "========================================"
echo " ALL CCFS ENOSPC TESTS PASSED"
echo "========================================"
echo
