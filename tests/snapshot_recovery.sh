#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

MOUNT_DIR="mount"

RUN_ID="$(date +%s)"

SNAP1="snapshot-before-$RUN_ID"
SNAP2="snapshot-after-$RUN_ID"

BASE_FILE="snapshot-base-$RUN_ID.txt"
AFTER_FILE="snapshot-after-$RUN_ID.txt"

OLD_CONTENT="CCFS-SNAPSHOT-OLD-$RUN_ID"
NEW_CONTENT="CCFS-SNAPSHOT-NEW-$RUN_ID"
AFTER_CONTENT="CCFS-AFTER-SNAPSHOT-$RUN_ID"

NORMAL_LOG="/tmp/ccfs-snapshot-normal.log"
VERIFY_LOG="/tmp/ccfs-snapshot-verify.log"
INTEGRITY_LOG="/tmp/ccfs-snapshot-integrity.log"

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
        mktemp -d /tmp/ccfs-snapshot-backup.XXXXXX
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

assert_live_text() {
    local path="$1"
    local expected="$2"

    local actual

    actual="$(cat "$path")"

    [[ "$actual" == "$expected" ]] ||
        fail "live content mismatch for $path"
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
        fail "snapshot $snapshot content mismatch for $path"
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
echo " CCFS SNAPSHOT / COPY-ON-WRITE TEST"
echo "========================================"
echo

# Remove any stale FUSE mount before touching mount/.
fusermount3 -u "$MOUNT_DIR" 2>/dev/null || true
fusermount3 -uz "$MOUNT_DIR" 2>/dev/null || true
sleep 0.1

mkdir -p "$MOUNT_DIR"
mkdir -p volume/blocks

echo "[1/10] Snapshotting original volume and building..."

snapshot_volume

cargo build --bin ccfs >/dev/null

pass "original volume preserved and CCFS built"

echo
echo "[2/10] Creating baseline live filesystem data..."

start_ccfs

printf '%s' "$OLD_CONTENT" \
    > "$MOUNT_DIR/$BASE_FILE"

BASE_INO="$(
    stat -c '%i' \
        "$MOUNT_DIR/$BASE_FILE"
)"

assert_live_text \
    "$MOUNT_DIR/$BASE_FILE" \
    "$OLD_CONTENT"

stop_ccfs

[[ -f "volume/blocks/$BASE_INO.bin" ]] ||
    fail "baseline live block missing"

[[ -f "volume/blocks/$BASE_INO.checksum" ]] ||
    fail "baseline live checksum missing"

pass "baseline file persisted"

echo
echo "[3/10] Creating first snapshot..."

./target/debug/ccfs \
    --snapshot-create \
    "$SNAP1"

[[ -d "volume/snapshots/$SNAP1" ]] ||
    fail "snapshot directory was not created"

[[ -f "volume/snapshots/$SNAP1/metadata.db" ]] ||
    fail "snapshot metadata.db missing"

[[ -f "volume/snapshots/$SNAP1/blocks/$BASE_INO.bin" ]] ||
    fail "snapshot data block missing"

[[ -f "volume/snapshots/$SNAP1/blocks/$BASE_INO.checksum" ]] ||
    fail "snapshot checksum missing"

./target/debug/ccfs \
    --snapshot-verify \
    "$SNAP1" \
    >"$VERIFY_LOG" 2>&1 ||
{
    cat "$VERIFY_LOG"
    fail "first snapshot verification failed"
}

grep -q \
    "Snapshot verified: $SNAP1" \
    "$VERIFY_LOG" ||
    fail "first snapshot verification marker missing"

assert_snapshot_text \
    "$SNAP1" \
    "$BASE_FILE" \
    "$OLD_CONTENT"

LIVE_HOST_INODE_BEFORE="$(
    stat -c '%i' \
        "volume/blocks/$BASE_INO.bin"
)"

SNAP1_HOST_INODE="$(
    stat -c '%i' \
        "volume/snapshots/$SNAP1/blocks/$BASE_INO.bin"
)"

[[ "$LIVE_HOST_INODE_BEFORE" == "$SNAP1_HOST_INODE" ]] ||
    fail "snapshot block was not initially hard-linked to live block"

SNAP1_LINKS="$(
    stat -c '%h' \
        "volume/snapshots/$SNAP1/blocks/$BASE_INO.bin"
)"

[[ "$SNAP1_LINKS" -ge 2 ]] ||
    fail "snapshot block does not show shared COW hard link"

pass "snapshot creation and initial COW sharing verified"

echo
echo "[4/10] Modifying live file and verifying Copy-on-Write..."

start_ccfs

printf '%s' "$NEW_CONTENT" \
    > "$MOUNT_DIR/$BASE_FILE"

assert_live_text \
    "$MOUNT_DIR/$BASE_FILE" \
    "$NEW_CONTENT"

printf '%s' "$AFTER_CONTENT" \
    > "$MOUNT_DIR/$AFTER_FILE"

stop_ccfs

LIVE_HOST_INODE_AFTER="$(
    stat -c '%i' \
        "volume/blocks/$BASE_INO.bin"
)"

SNAP1_HOST_INODE_AFTER="$(
    stat -c '%i' \
        "volume/snapshots/$SNAP1/blocks/$BASE_INO.bin"
)"

[[ "$LIVE_HOST_INODE_AFTER" != "$SNAP1_HOST_INODE_AFTER" ]] ||
    fail "live write did not break COW sharing"

assert_snapshot_text \
    "$SNAP1" \
    "$BASE_FILE" \
    "$OLD_CONTENT"

./target/debug/ccfs \
    --snapshot-verify \
    "$SNAP1" \
    >/dev/null ||
    fail "first snapshot became invalid after live modification"

pass "old snapshot block remained unchanged after live write"

echo
echo "[5/10] Creating second snapshot..."

./target/debug/ccfs \
    --snapshot-create \
    "$SNAP2"

assert_snapshot_text \
    "$SNAP1" \
    "$BASE_FILE" \
    "$OLD_CONTENT"

assert_snapshot_text \
    "$SNAP2" \
    "$BASE_FILE" \
    "$NEW_CONTENT"

assert_snapshot_text \
    "$SNAP2" \
    "$AFTER_FILE" \
    "$AFTER_CONTENT"

SNAPSHOT_LIST="$(
    ./target/debug/ccfs \
        --snapshot-list
)"

echo "$SNAPSHOT_LIST" |
    grep -qx "$SNAP1" ||
    fail "first snapshot missing from snapshot list"

echo "$SNAPSHOT_LIST" |
    grep -qx "$SNAP2" ||
    fail "second snapshot missing from snapshot list"

pass "multiple snapshot versions preserved independently"

echo
echo "[6/10] Testing snapshot access after CCFS restart..."

start_ccfs

assert_live_text \
    "$MOUNT_DIR/$BASE_FILE" \
    "$NEW_CONTENT"

stop_ccfs

assert_snapshot_text \
    "$SNAP1" \
    "$BASE_FILE" \
    "$OLD_CONTENT"

assert_snapshot_text \
    "$SNAP2" \
    "$BASE_FILE" \
    "$NEW_CONTENT"

pass "snapshots remained accessible after restart"

echo
echo "[7/10] Deleting live file while preserving snapshots..."

start_ccfs

rm "$MOUNT_DIR/$BASE_FILE"

[[ ! -e "$MOUNT_DIR/$BASE_FILE" ]] ||
    fail "live baseline file was not deleted"

stop_ccfs

assert_snapshot_text \
    "$SNAP1" \
    "$BASE_FILE" \
    "$OLD_CONTENT"

assert_snapshot_text \
    "$SNAP2" \
    "$BASE_FILE" \
    "$NEW_CONTENT"

pass "snapshot retained deleted live file data"

echo
echo "[8/10] Restoring first snapshot..."

./target/debug/ccfs \
    --snapshot-restore \
    "$SNAP1"

start_ccfs

[[ -f "$MOUNT_DIR/$BASE_FILE" ]] ||
    fail "restored baseline file missing"

assert_live_text \
    "$MOUNT_DIR/$BASE_FILE" \
    "$OLD_CONTENT"

[[ ! -e "$MOUNT_DIR/$AFTER_FILE" ]] ||
    fail "post-snapshot file survived restore unexpectedly"

stop_ccfs

run_integrity_check

pass "snapshot restore returned filesystem to previous valid state"

echo
echo "[9/10] Testing snapshot corruption detection..."

# After restoring SNAP1, SNAP2 no longer shares its block with
# the current live block, so it is safe to corrupt SNAP2 here.
printf 'X' |
    dd \
        of="volume/snapshots/$SNAP2/blocks/$BASE_INO.bin" \
        bs=1 \
        seek=0 \
        conv=notrunc \
        status=none

set +e

./target/debug/ccfs \
    --snapshot-verify \
    "$SNAP2" \
    >"$VERIFY_LOG" 2>&1

VERIFY_STATUS=$?

set -e

[[ "$VERIFY_STATUS" -ne 0 ]] ||
    fail "corrupted snapshot block was accepted"

grep -qi \
    "checksum mismatch" \
    "$VERIFY_LOG" ||
    fail "snapshot corruption did not report checksum mismatch"

./target/debug/ccfs \
    --snapshot-verify \
    "$SNAP1" \
    >/dev/null ||
    fail "healthy first snapshot was affected by second snapshot corruption"

./target/debug/ccfs \
    --snapshot-delete \
    "$SNAP2"

[[ ! -e "volume/snapshots/$SNAP2" ]] ||
    fail "snapshot delete did not remove corrupted snapshot"

pass "snapshot corruption detected and isolated"

echo
echo "[10/10] Restoring original pre-test volume..."

restore_volume

trap - EXIT INT TERM

rm -f "$NORMAL_LOG"
rm -f "$VERIFY_LOG"
rm -f "$INTEGRITY_LOG"

echo
echo "========================================"
echo " ALL CCFS SNAPSHOT / COW TESTS PASSED"
echo "========================================"
echo
