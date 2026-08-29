#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

MOUNT_DIR="mount"

RUN_ID="$(date +%s)"

EMPTY_SNAP="snapshot-empty-$RUN_ID"
UNCHANGED_A="snapshot-unchanged-a-$RUN_ID"
UNCHANGED_B="snapshot-unchanged-b-$RUN_ID"
IMMEDIATE_SNAP="snapshot-immediate-$RUN_ID"

SHARED_FILE="snapshot-shared-$RUN_ID.txt"
IMMEDIATE_FILE="snapshot-immediate-$RUN_ID.txt"

SHARED_DATA="CCFS-SHARED-SNAPSHOT-DATA-$RUN_ID"
IMMEDIATE_DATA="CCFS-IMMEDIATE-WRITE-$RUN_ID"

NORMAL_LOG="/tmp/ccfs-snapshot-edge-normal.log"
VERIFY_LOG="/tmp/ccfs-snapshot-edge-verify.log"
INTEGRITY_LOG="/tmp/ccfs-snapshot-edge-integrity.log"

CCFS_PID=""
BACKUP_ROOT=""

fail() {
    echo
    echo "TEST FAILED: $1"
    echo

    echo "CCFS log:"
    echo "----------------------------------------"
    cat "$NORMAL_LOG" 2>/dev/null || true

    echo
    echo "Snapshot verify log:"
    echo "----------------------------------------"
    cat "$VERIFY_LOG" 2>/dev/null || true

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

    for _ in $(seq 1 100); do
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

    ./target/debug/ccfs >"$NORMAL_LOG" 2>&1 &
    CCFS_PID=$!

    wait_for_mount "$CCFS_PID" ||
        fail "CCFS failed to mount"
}

snapshot_volume() {
    stop_ccfs

    BACKUP_ROOT="$(
        mktemp -d /tmp/ccfs-snapshot-edge-backup.XXXXXX
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
    rm -f "$VERIFY_LOG"
    rm -f "$INTEGRITY_LOG"

    set -e
}

assert_snapshot_text() {
    local snapshot="$1"
    local path="$2"
    local expected="$3"

    local actual

    actual="$(
        ./target/debug/ccfs \
            --snapshot-read \
            "$snapshot" \
            "$path"
    )"

    [[ "$actual" == "$expected" ]] ||
        fail "snapshot content mismatch: $snapshot / $path"
}

verify_snapshot() {
    local snapshot="$1"

    ./target/debug/ccfs \
        --snapshot-verify \
        "$snapshot" \
        >"$VERIFY_LOG" 2>&1 ||
    {
        cat "$VERIFY_LOG"
        fail "snapshot verification failed: $snapshot"
    }

    grep -q \
        "Snapshot verified: $snapshot" \
        "$VERIFY_LOG" ||
        fail "snapshot verify marker missing: $snapshot"
}

run_integrity_check() {
    stop_ccfs

    ./target/debug/ccfs \
        --check-integrity \
        >"$INTEGRITY_LOG" 2>&1 ||
    {
        cat "$INTEGRITY_LOG"
        fail "live integrity verification failed"
    }

    grep -q \
        "ALL CCFS BLOCKS PASSED INTEGRITY CHECK" \
        "$INTEGRITY_LOG" ||
        fail "live integrity success marker missing"
}

trap cleanup EXIT INT TERM

echo
echo "========================================"
echo " CCFS SNAPSHOT EDGE CASE TESTS"
echo "========================================"
echo

fusermount3 -u "$MOUNT_DIR" 2>/dev/null || true
fusermount3 -uz "$MOUNT_DIR" 2>/dev/null || true
sleep 0.1

mkdir -p "$MOUNT_DIR"

echo "[1/8] Preserving original volume and building..."

snapshot_volume

cargo build --bin ccfs >/dev/null

pass "original volume preserved and CCFS built"

echo
echo "[2/8] Preparing clean persistent filesystem..."

rm -rf volume
mkdir -p volume/blocks

start_ccfs
stop_ccfs

[[ -f volume/metadata.db ]] ||
    fail "clean metadata database was not created"

pass "clean filesystem initialized"

echo
echo "[3/8] Testing empty filesystem snapshot..."

EMPTY_OUTPUT="$(
    ./target/debug/ccfs \
        --snapshot-create \
        "$EMPTY_SNAP"
)"

echo "$EMPTY_OUTPUT"

echo "$EMPTY_OUTPUT" |
    grep -q "Snapshot created: $EMPTY_SNAP" ||
    fail "empty snapshot creation marker missing"

echo "$EMPTY_OUTPUT" |
    grep -q "Files captured: 0" ||
    fail "empty snapshot should contain zero persistent files"

verify_snapshot "$EMPTY_SNAP"

[[ -d "volume/snapshots/$EMPTY_SNAP" ]] ||
    fail "empty snapshot directory missing"

pass "empty filesystem snapshot is valid"

echo
echo "[4/8] Creating durable file for unchanged snapshots..."

start_ccfs

python3 - \
    "$MOUNT_DIR/$SHARED_FILE" \
    "$SHARED_DATA" <<'PY'
import os
import sys

path = sys.argv[1]
payload = sys.argv[2].encode()

fd = os.open(
    path,
    os.O_CREAT | os.O_WRONLY | os.O_TRUNC,
    0o644,
)

try:
    written = os.write(fd, payload)

    if written != len(payload):
        raise RuntimeError("short write")

    os.fsync(fd)

finally:
    os.close(fd)
PY

SHARED_INO="$(
    stat -c '%i' \
        "$MOUNT_DIR/$SHARED_FILE"
)"

[[ "$(cat "$MOUNT_DIR/$SHARED_FILE")" == "$SHARED_DATA" ]] ||
    fail "shared file content incorrect"

stop_ccfs

pass "shared file persisted"

echo
echo "[5/8] Testing multiple snapshots without changes..."

./target/debug/ccfs \
    --snapshot-create \
    "$UNCHANGED_A" \
    >/dev/null

./target/debug/ccfs \
    --snapshot-create \
    "$UNCHANGED_B" \
    >/dev/null

verify_snapshot "$UNCHANGED_A"
verify_snapshot "$UNCHANGED_B"

assert_snapshot_text \
    "$UNCHANGED_A" \
    "$SHARED_FILE" \
    "$SHARED_DATA"

assert_snapshot_text \
    "$UNCHANGED_B" \
    "$SHARED_FILE" \
    "$SHARED_DATA"

LIVE_HOST_INODE="$(
    stat -c '%i' \
        "volume/blocks/$SHARED_INO.bin"
)"

SNAP_A_HOST_INODE="$(
    stat -c '%i' \
        "volume/snapshots/$UNCHANGED_A/blocks/$SHARED_INO.bin"
)"

SNAP_B_HOST_INODE="$(
    stat -c '%i' \
        "volume/snapshots/$UNCHANGED_B/blocks/$SHARED_INO.bin"
)"

[[ "$LIVE_HOST_INODE" == "$SNAP_A_HOST_INODE" ]] ||
    fail "unchanged snapshot A is not sharing immutable block"

[[ "$LIVE_HOST_INODE" == "$SNAP_B_HOST_INODE" ]] ||
    fail "unchanged snapshot B is not sharing immutable block"

LINK_COUNT="$(
    stat -c '%h' \
        "volume/blocks/$SHARED_INO.bin"
)"

[[ "$LINK_COUNT" -ge 3 ]] ||
    fail "expected live + two snapshots to share the same block"

pass "multiple unchanged snapshots are valid and COW-efficient"

echo
echo "[6/8] Testing snapshot immediately after durable write..."

start_ccfs

python3 - \
    "$MOUNT_DIR/$IMMEDIATE_FILE" \
    "$IMMEDIATE_DATA" <<'PY'
import os
import sys

path = sys.argv[1]
payload = sys.argv[2].encode()

fd = os.open(
    path,
    os.O_CREAT | os.O_WRONLY | os.O_TRUNC,
    0o644,
)

try:
    written = os.write(fd, payload)

    if written != len(payload):
        raise RuntimeError("short write")

    os.fsync(fd)

finally:
    os.close(fd)
PY

[[ "$(cat "$MOUNT_DIR/$IMMEDIATE_FILE")" == "$IMMEDIATE_DATA" ]] ||
    fail "immediate file content incorrect before snapshot"

stop_ccfs

./target/debug/ccfs \
    --snapshot-create \
    "$IMMEDIATE_SNAP" \
    >/dev/null

verify_snapshot "$IMMEDIATE_SNAP"

assert_snapshot_text \
    "$IMMEDIATE_SNAP" \
    "$IMMEDIATE_FILE" \
    "$IMMEDIATE_DATA"

pass "snapshot immediately after write captured latest durable state"

echo
echo "[7/8] Verifying restart access and live integrity..."

start_ccfs

[[ "$(cat "$MOUNT_DIR/$SHARED_FILE")" == "$SHARED_DATA" ]] ||
    fail "shared live file incorrect after restart"

[[ "$(cat "$MOUNT_DIR/$IMMEDIATE_FILE")" == "$IMMEDIATE_DATA" ]] ||
    fail "immediate live file incorrect after restart"

stop_ccfs

assert_snapshot_text \
    "$UNCHANGED_A" \
    "$SHARED_FILE" \
    "$SHARED_DATA"

assert_snapshot_text \
    "$UNCHANGED_B" \
    "$SHARED_FILE" \
    "$SHARED_DATA"

assert_snapshot_text \
    "$IMMEDIATE_SNAP" \
    "$IMMEDIATE_FILE" \
    "$IMMEDIATE_DATA"

run_integrity_check

pass "snapshot edge states survived restart and integrity check"

echo
echo "[8/8] Restoring original pre-test volume..."

restore_volume

trap - EXIT INT TERM

rm -f "$NORMAL_LOG"
rm -f "$VERIFY_LOG"
rm -f "$INTEGRITY_LOG"

echo
echo "========================================"
echo " ALL CCFS SNAPSHOT EDGE TESTS PASSED"
echo "========================================"
echo
