#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

MOUNT_DIR="mount"
CRASH_LOG="/tmp/ccfs-rename-replace-crash.log"
RECOVERY_LOG="/tmp/ccfs-rename-replace-recovery.log"
INTEGRITY_LOG="/tmp/ccfs-rename-replace-integrity.log"

RUN_ID="$(date +%s)"

BEGIN_SRC="rr-k9-begin-src-$RUN_ID.txt"
BEGIN_DST="rr-k9-begin-dst-$RUN_ID.txt"

COMMIT_SRC="rr-k9-commit-src-$RUN_ID.txt"
COMMIT_DST="rr-k9-commit-dst-$RUN_ID.txt"

BEGIN_SRC_DATA="BEGIN-SOURCE-DATA"
BEGIN_DST_DATA="BEGIN-OLD-DESTINATION-DATA"

COMMIT_SRC_DATA="COMMIT-SOURCE-DATA"
COMMIT_DST_DATA="COMMIT-OLD-DESTINATION-DATA"

CCFS_PID=""
BACKUP_ROOT=""

fail() {
    echo
    echo "TEST FAILED: $1"
    echo
    echo "Crash log:"
    echo "----------------------------------------"
    cat "$CRASH_LOG" 2>/dev/null || true
    echo
    echo "Recovery log:"
    echo "----------------------------------------"
    cat "$RECOVERY_LOG" 2>/dev/null || true
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

    if is_mounted; then
        fusermount3 -u "$MOUNT_DIR" 2>/dev/null ||
            fusermount3 -uz "$MOUNT_DIR" 2>/dev/null ||
            true
    fi

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

start_normal_ccfs() {
    stop_ccfs

    : > "$RECOVERY_LOG"

    ./target/debug/ccfs >"$RECOVERY_LOG" 2>&1 &
    CCFS_PID=$!

    wait_for_mount "$CCFS_PID" ||
        fail "normal CCFS failed to mount"
}

start_crash_ccfs() {
    local operation="$1"
    local point="$2"

    stop_ccfs

    : > "$CRASH_LOG"

    env \
        CCFS_KILL9_OPERATION="$operation" \
        CCFS_KILL9_POINT="$point" \
        ./target/debug/ccfs >"$CRASH_LOG" 2>&1 &

    CCFS_PID=$!

    wait_for_mount "$CCFS_PID" ||
        fail "crash-mode CCFS failed to mount"
}

wait_for_sigkill() {
    local pid="$CCFS_PID"

    for _ in $(seq 1 100); do
        if ! kill -0 "$pid" 2>/dev/null; then
            break
        fi

        sleep 0.05
    done

    if kill -0 "$pid" 2>/dev/null; then
        fail "CCFS did not crash at requested failpoint"
    fi

    set +e
    wait "$pid" 2>/dev/null
    local status=$?
    set -e

    CCFS_PID=""

    detach_mount

    if [[ "$status" -ne 137 ]]; then
        fail "expected SIGKILL exit status 137, got $status"
    fi
}

clear_recovery_state() {
    mkdir -p volume

    : > volume/journal.log

    sqlite3 volume/metadata.db \
        "DELETE FROM applied_tx;"
}

sql_name_count() {
    local name="$1"

    sqlite3 volume/metadata.db \
        "SELECT COUNT(*)
         FROM entries
         WHERE name='$name';"
}

sql_inode_count() {
    local ino="$1"

    sqlite3 volume/metadata.db \
        "SELECT COUNT(*)
         FROM entries
         WHERE ino=$ino;"
}

sql_inode_name() {
    local ino="$1"

    sqlite3 volume/metadata.db \
        "SELECT name
         FROM entries
         WHERE ino=$ino;"
}

assert_file_text() {
    local path="$1"
    local expected="$2"

    python3 - "$path" "$expected" <<'PY'
import sys

path = sys.argv[1]
expected = sys.argv[2].encode("utf-8")

with open(path, "rb") as file:
    actual = file.read()

if actual != expected:
    print("Expected:", expected)
    print("Actual:  ", actual)
    raise SystemExit(1)
PY
}

assert_block_text() {
    local ino="$1"
    local expected="$2"

    python3 - "volume/blocks/$ino.bin" "$expected" <<'PY'
import sys

path = sys.argv[1]
expected = sys.argv[2].encode("utf-8")

with open(path, "rb") as file:
    actual = file.read()

if actual != expected:
    print("Expected:", expected)
    print("Actual:  ", actual)
    raise SystemExit(1)
PY
}

run_integrity_check() {
    stop_ccfs

    ./target/debug/ccfs \
        --check-integrity \
        >"$INTEGRITY_LOG" 2>&1 ||
    {
        cat "$INTEGRITY_LOG"
        fail "filesystem integrity check failed"
    }

    grep -q \
        "ALL CCFS BLOCKS PASSED INTEGRITY CHECK" \
        "$INTEGRITY_LOG" ||
        fail "integrity success marker missing"
}

snapshot_volume() {
    stop_ccfs

    BACKUP_ROOT="$(
        mktemp -d /tmp/ccfs-rename-replace-backup.XXXXXX
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

    rm -f "$CRASH_LOG"
    rm -f "$RECOVERY_LOG"
    rm -f "$INTEGRITY_LOG"

    set -e
}

trigger_rename() {
    local source="$1"
    local destination="$2"

    set +e

    python3 - "$source" "$destination" <<'PY'
import os
import sys

os.rename(sys.argv[1], sys.argv[2])
PY

    set -e
}

trap cleanup EXIT INT TERM

echo
echo "============================================="
echo " CCFS RENAME-REPLACE REAL SIGKILL RECOVERY"
echo "============================================="
echo

mkdir -p "$MOUNT_DIR"
mkdir -p volume/blocks

echo "[1/6] Snapshotting original volume and building..."

snapshot_volume

cargo build --bin ccfs >/dev/null

./target/debug/ccfs \
    --recovery-status \
    >/dev/null

pass "volume snapshot created and CCFS built"

echo
echo "[2/6] RENAME-REPLACE crash after BEGIN..."

clear_recovery_state

start_normal_ccfs

printf '%s' "$BEGIN_SRC_DATA" > "$MOUNT_DIR/$BEGIN_SRC"
printf '%s' "$BEGIN_DST_DATA" > "$MOUNT_DIR/$BEGIN_DST"

BEGIN_SRC_INO="$(stat -c '%i' "$MOUNT_DIR/$BEGIN_SRC")"
BEGIN_DST_INO="$(stat -c '%i' "$MOUNT_DIR/$BEGIN_DST")"

[[ "$BEGIN_SRC_INO" != "$BEGIN_DST_INO" ]] ||
    fail "BEGIN source and destination inode unexpectedly identical"

stop_ccfs

clear_recovery_state

start_crash_ccfs \
    "RENAME" \
    "after_begin"

trigger_rename \
    "$MOUNT_DIR/$BEGIN_SRC" \
    "$MOUNT_DIR/$BEGIN_DST"

wait_for_sigkill

[[ "$(sql_name_count "$BEGIN_SRC")" == "1" ]] ||
    fail "after-BEGIN source metadata changed"

[[ "$(sql_name_count "$BEGIN_DST")" == "1" ]] ||
    fail "after-BEGIN destination metadata changed"

[[ -f "volume/blocks/$BEGIN_SRC_INO.bin" ]] ||
    fail "after-BEGIN source block disappeared"

[[ -f "volume/blocks/$BEGIN_SRC_INO.checksum" ]] ||
    fail "after-BEGIN source checksum disappeared"

[[ -f "volume/blocks/$BEGIN_DST_INO.bin" ]] ||
    fail "after-BEGIN destination block disappeared"

[[ -f "volume/blocks/$BEGIN_DST_INO.checksum" ]] ||
    fail "after-BEGIN destination checksum disappeared"

start_normal_ccfs

[[ -f "$MOUNT_DIR/$BEGIN_SRC" ]] ||
    fail "incomplete replacement removed source after restart"

[[ -f "$MOUNT_DIR/$BEGIN_DST" ]] ||
    fail "incomplete replacement removed destination after restart"

assert_file_text \
    "$MOUNT_DIR/$BEGIN_SRC" \
    "$BEGIN_SRC_DATA" ||
    fail "incomplete replacement corrupted source"

assert_file_text \
    "$MOUNT_DIR/$BEGIN_DST" \
    "$BEGIN_DST_DATA" ||
    fail "incomplete replacement corrupted destination"

grep -q \
    "incomplete ignored: 1" \
    "$RECOVERY_LOG" ||
    fail "after-BEGIN replacement was not classified incomplete"

run_integrity_check

pass "RENAME-REPLACE killed after BEGIN preserved both files"

echo
echo "[3/6] RENAME-REPLACE crash after COMMIT..."

clear_recovery_state

start_normal_ccfs

printf '%s' "$COMMIT_SRC_DATA" > "$MOUNT_DIR/$COMMIT_SRC"
printf '%s' "$COMMIT_DST_DATA" > "$MOUNT_DIR/$COMMIT_DST"

COMMIT_SRC_INO="$(stat -c '%i' "$MOUNT_DIR/$COMMIT_SRC")"
COMMIT_DST_INO="$(stat -c '%i' "$MOUNT_DIR/$COMMIT_DST")"

[[ "$COMMIT_SRC_INO" != "$COMMIT_DST_INO" ]] ||
    fail "COMMIT source and destination inode unexpectedly identical"

stop_ccfs

clear_recovery_state

start_crash_ccfs \
    "RENAME" \
    "after_commit"

trigger_rename \
    "$MOUNT_DIR/$COMMIT_SRC" \
    "$MOUNT_DIR/$COMMIT_DST"

wait_for_sigkill

# SIGKILL occurred after durable journal COMMIT but before apply.
# Durable metadata/storage must still show the pre-rename state here.

[[ "$(sql_name_count "$COMMIT_SRC")" == "1" ]] ||
    fail "after-COMMIT source metadata applied before recovery"

[[ "$(sql_name_count "$COMMIT_DST")" == "1" ]] ||
    fail "after-COMMIT destination metadata applied before recovery"

[[ -f "volume/blocks/$COMMIT_SRC_INO.bin" ]] ||
    fail "after-COMMIT source block vanished before recovery"

[[ -f "volume/blocks/$COMMIT_DST_INO.bin" ]] ||
    fail "after-COMMIT destination block vanished before recovery"

echo
echo "[4/6] Recovering committed replacement..."

start_normal_ccfs

grep -q \
    "replayed: 1" \
    "$RECOVERY_LOG" ||
    fail "committed rename replacement did not replay"

[[ ! -e "$MOUNT_DIR/$COMMIT_SRC" ]] ||
    fail "old source pathname survived committed replacement"

[[ -f "$MOUNT_DIR/$COMMIT_DST" ]] ||
    fail "replacement destination missing after recovery"

RECOVERED_INO="$(stat -c '%i' "$MOUNT_DIR/$COMMIT_DST")"

[[ "$RECOVERED_INO" == "$COMMIT_SRC_INO" ]] ||
    fail "source inode was not preserved after recovery"

[[ "$(sql_inode_name "$COMMIT_SRC_INO")" == "$COMMIT_DST" ]] ||
    fail "source metadata name not recovered onto destination"

[[ "$(sql_inode_count "$COMMIT_DST_INO")" == "0" ]] ||
    fail "old destination metadata survived recovery"

[[ ! -e "volume/blocks/$COMMIT_DST_INO.bin" ]] ||
    fail "old destination block survived recovery"

[[ ! -e "volume/blocks/$COMMIT_DST_INO.checksum" ]] ||
    fail "old destination checksum survived recovery"

[[ -f "volume/blocks/$COMMIT_SRC_INO.bin" ]] ||
    fail "source block missing after recovery"

[[ -f "volume/blocks/$COMMIT_SRC_INO.checksum" ]] ||
    fail "source checksum missing after recovery"

assert_block_text \
    "$COMMIT_SRC_INO" \
    "$COMMIT_SRC_DATA" ||
    fail "recovered destination durable data is incorrect"

pass "committed replacement replayed correctly"

echo
echo "[5/6] Verifying idempotent second restart..."

stop_ccfs
start_normal_ccfs

grep -q \
    "replayed: 0" \
    "$RECOVERY_LOG" ||
    fail "already-applied replacement replayed again"

grep -q \
    "already applied: 1" \
    "$RECOVERY_LOG" ||
    fail "replacement was not recognized as already applied"

[[ ! -e "$MOUNT_DIR/$COMMIT_SRC" ]] ||
    fail "old source pathname returned on second restart"

[[ -f "$MOUNT_DIR/$COMMIT_DST" ]] ||
    fail "destination missing on second restart"

SECOND_RESTART_INO="$(stat -c '%i' "$MOUNT_DIR/$COMMIT_DST")"

[[ "$SECOND_RESTART_INO" == "$COMMIT_SRC_INO" ]] ||
    fail "inode changed on second restart"

assert_file_text \
    "$MOUNT_DIR/$COMMIT_DST" \
    "$COMMIT_SRC_DATA" ||
    fail "content changed on second restart"

run_integrity_check

pass "second restart remained idempotent and healthy"

echo
echo "[6/6] Restoring original pre-test volume..."

restore_volume

trap - EXIT INT TERM

rm -f "$CRASH_LOG"
rm -f "$RECOVERY_LOG"
rm -f "$INTEGRITY_LOG"

echo
echo "============================================="
echo " ALL CCFS RENAME-REPLACE SIGKILL TESTS PASSED"
echo "============================================="
echo
