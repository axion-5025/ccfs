#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

MOUNT_DIR="mount"

RUN_ID="$(date +%s)"

BASE_FILE="snapshot-crash-base-$RUN_ID.txt"
BASE_DATA="CCFS-SNAPSHOT-CRASH-DATA-$RUN_ID"

AFTER_BLOCKS_SNAP="snap-crash-blocks-$RUN_ID"
BEFORE_PUBLISH_SNAP="snap-crash-before-publish-$RUN_ID"
AFTER_PUBLISH_SNAP="snap-crash-after-publish-$RUN_ID"

NORMAL_LOG="/tmp/ccfs-snapshot-crash-normal.log"
CRASH_LOG="/tmp/ccfs-snapshot-crash.log"
VERIFY_LOG="/tmp/ccfs-snapshot-crash-verify.log"
INTEGRITY_LOG="/tmp/ccfs-snapshot-crash-integrity.log"

CCFS_PID=""
BACKUP_ROOT=""

fail() {
    echo
    echo "TEST FAILED: $1"
    echo

    echo "Normal log:"
    echo "----------------------------------------"
    cat "$NORMAL_LOG" 2>/dev/null || true

    echo
    echo "Crash log:"
    echo "----------------------------------------"
    cat "$CRASH_LOG" 2>/dev/null || true

    echo
    echo "Verify log:"
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
        mktemp -d /tmp/ccfs-snapshot-crash-backup.XXXXXX
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
    rm -f "$CRASH_LOG"
    rm -f "$VERIFY_LOG"
    rm -f "$INTEGRITY_LOG"

    set -e
}

assert_live_file() {
    start_ccfs

    [[ -f "$MOUNT_DIR/$BASE_FILE" ]] ||
        fail "baseline live file missing"

    local actual

    actual="$(cat "$MOUNT_DIR/$BASE_FILE")"

    [[ "$actual" == "$BASE_DATA" ]] ||
        fail "baseline live file content changed"

    stop_ccfs
}

assert_snapshot_not_visible() {
    local name="$1"

    [[ ! -e "volume/snapshots/$name" ]] ||
        fail "half-created snapshot became visible: $name"

    local list

    list="$(
        ./target/debug/ccfs \
            --snapshot-list
    )"

    if echo "$list" | grep -qx "$name"; then
        fail "half-created snapshot appeared in snapshot list: $name"
    fi
}

assert_snapshot_valid() {
    local name="$1"

    [[ -d "volume/snapshots/$name" ]] ||
        fail "published snapshot missing: $name"

    ./target/debug/ccfs \
        --snapshot-verify \
        "$name" \
        >"$VERIFY_LOG" 2>&1 ||
    {
        cat "$VERIFY_LOG"
        fail "snapshot verification failed: $name"
    }

    grep -q \
        "Snapshot verified: $name" \
        "$VERIFY_LOG" ||
        fail "snapshot verify marker missing: $name"

    local actual

    actual="$(
        ./target/debug/ccfs \
            --snapshot-read \
            "$name" \
            "$BASE_FILE"
    )"

    [[ "$actual" == "$BASE_DATA" ]] ||
        fail "snapshot data incorrect: $name"
}

run_snapshot_crash() {
    local point="$1"
    local name="$2"

    : > "$CRASH_LOG"

    set +e

    env \
        CCFS_SNAPSHOT_KILL9_POINT="$point" \
        ./target/debug/ccfs \
        --snapshot-create \
        "$name" \
        >"$CRASH_LOG" 2>&1

    local status=$?

    set -e

    if [[ "$status" -ne 137 ]]; then
        cat "$CRASH_LOG"

        fail \
            "expected SIGKILL status 137 at $point, got $status"
    fi
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
echo " CCFS SNAPSHOT REAL SIGKILL TEST"
echo "========================================"
echo

fusermount3 -u "$MOUNT_DIR" 2>/dev/null || true
fusermount3 -uz "$MOUNT_DIR" 2>/dev/null || true
sleep 0.1

mkdir -p "$MOUNT_DIR"
mkdir -p volume/blocks

echo "[1/8] Snapshotting original volume and building..."

snapshot_volume

cargo build --bin ccfs >/dev/null

pass "original volume preserved and CCFS built"

echo
echo "[2/8] Creating durable baseline file..."

start_ccfs

printf '%s' "$BASE_DATA" \
    > "$MOUNT_DIR/$BASE_FILE"

sync

[[ "$(cat "$MOUNT_DIR/$BASE_FILE")" == "$BASE_DATA" ]] ||
    fail "baseline file write failed"

stop_ccfs

assert_live_file

pass "baseline filesystem state durable"

echo
echo "[3/8] Crashing snapshot after block linking..."

run_snapshot_crash \
    "after_blocks" \
    "$AFTER_BLOCKS_SNAP"

assert_snapshot_not_visible \
    "$AFTER_BLOCKS_SNAP"

assert_live_file

pass "after_blocks crash exposed no half-created snapshot"

echo
echo "[4/8] Verifying stale temp cleanup and retry..."

./target/debug/ccfs \
    --snapshot-create \
    "$AFTER_BLOCKS_SNAP" \
    >/dev/null ||
    fail "snapshot retry after after_blocks crash failed"

assert_snapshot_valid \
    "$AFTER_BLOCKS_SNAP"

pass "stale hidden snapshot cleaned and retry succeeded"

echo
echo "[5/8] Crashing immediately before publication..."

run_snapshot_crash \
    "before_publish" \
    "$BEFORE_PUBLISH_SNAP"

assert_snapshot_not_visible \
    "$BEFORE_PUBLISH_SNAP"

assert_live_file

pass "before_publish crash exposed no half-created snapshot"

echo
echo "[6/8] Retrying before_publish snapshot normally..."

./target/debug/ccfs \
    --snapshot-create \
    "$BEFORE_PUBLISH_SNAP" \
    >/dev/null ||
    fail "snapshot retry after before_publish crash failed"

assert_snapshot_valid \
    "$BEFORE_PUBLISH_SNAP"

pass "before_publish stale temp cleaned successfully"

echo
echo "[7/8] Crashing immediately after atomic publication..."

run_snapshot_crash \
    "after_publish" \
    "$AFTER_PUBLISH_SNAP"

assert_snapshot_valid \
    "$AFTER_PUBLISH_SNAP"

SNAPSHOT_LIST="$(
    ./target/debug/ccfs \
        --snapshot-list
)"

echo "$SNAPSHOT_LIST" |
    grep -qx "$AFTER_PUBLISH_SNAP" ||
    fail "durably published snapshot missing from list"

assert_live_file

run_integrity_check

pass "after_publish crash left complete valid snapshot"

echo
echo "[8/8] Restoring original pre-test volume..."

restore_volume

trap - EXIT INT TERM

rm -f "$NORMAL_LOG"
rm -f "$CRASH_LOG"
rm -f "$VERIFY_LOG"
rm -f "$INTEGRITY_LOG"

echo
echo "========================================"
echo " ALL CCFS SNAPSHOT SIGKILL TESTS PASSED"
echo "========================================"
echo
