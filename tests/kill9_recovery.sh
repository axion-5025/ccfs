#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

MOUNT_DIR="mount"

CRASH_LOG="/tmp/ccfs-kill9-crash.log"
RECOVERY_LOG="/tmp/ccfs-kill9-recovery.log"
INTEGRITY_LOG="/tmp/ccfs-kill9-integrity.log"

BACKUP_ROOT=""
CCFS_PID=""

RUN_ID="$(date +%s)"

CREATE_BEGIN_NAME="k9-create-begin-$RUN_ID.txt"
CREATE_COMMIT_NAME="k9-create-commit-$RUN_ID.txt"

MKDIR_BEGIN_NAME="k9-mkdir-begin-$RUN_ID"
MKDIR_COMMIT_NAME="k9-mkdir-commit-$RUN_ID"

RMDIR_BEGIN_NAME="k9-rmdir-begin-$RUN_ID"
RMDIR_COMMIT_NAME="k9-rmdir-commit-$RUN_ID"

WRITE_BEGIN_NAME="k9-write-begin-$RUN_ID.txt"
WRITE_COMMIT_NAME="k9-write-commit-$RUN_ID.txt"

TRUNCATE_BEGIN_NAME="k9-truncate-begin-$RUN_ID.txt"
TRUNCATE_COMMIT_NAME="k9-truncate-commit-$RUN_ID.txt"

SETATTR_BEGIN_NAME="k9-setattr-begin-$RUN_ID.txt"
SETATTR_COMMIT_NAME="k9-setattr-commit-$RUN_ID.txt"

RENAME_BEGIN_OLD="k9-rename-begin-old-$RUN_ID.txt"
RENAME_BEGIN_NEW="k9-rename-begin-new-$RUN_ID.txt"

RENAME_COMMIT_OLD="k9-rename-commit-old-$RUN_ID.txt"
RENAME_COMMIT_NEW="k9-rename-commit-new-$RUN_ID.txt"

DELETE_BEGIN_NAME="k9-delete-begin-$RUN_ID.txt"
DELETE_COMMIT_NAME="k9-delete-commit-$RUN_ID.txt"

WRITE_BEGIN_INO=""
WRITE_COMMIT_INO=""

TRUNCATE_BEGIN_INO=""
TRUNCATE_COMMIT_INO=""

RENAME_BEGIN_INO=""
RENAME_COMMIT_INO=""

DELETE_BEGIN_INO=""
DELETE_COMMIT_INO=""

pass() {
    echo "PASS: $1"
}

fail() {
    echo
    echo "========================================"
    echo "TEST FAILED: $1"
    echo "========================================"
    echo

    if [[ -f "$CRASH_LOG" ]]; then
        echo "Crash-run log:"
        echo "----------------------------------------"
        cat "$CRASH_LOG" || true
        echo
    fi

    if [[ -f "$RECOVERY_LOG" ]]; then
        echo "Recovery-run log:"
        echo "----------------------------------------"
        cat "$RECOVERY_LOG" || true
        echo
    fi

    exit 1
}

is_mounted() {
    mountpoint -q "$MOUNT_DIR" 2>/dev/null
}

detach_mount() {
    set +e

    fusermount3 -u "$MOUNT_DIR" \
        2>/dev/null || true

    fusermount3 -uz "$MOUNT_DIR" \
        2>/dev/null || true

    set -e
}

stop_ccfs() {
    set +e

    detach_mount

    if [[ -n "${CCFS_PID:-}" ]] &&
       kill -0 "$CCFS_PID" 2>/dev/null
    then
        kill "$CCFS_PID" \
            2>/dev/null || true

        sleep 0.2

        kill -9 "$CCFS_PID" \
            2>/dev/null || true
    fi

    if [[ -n "${CCFS_PID:-}" ]]; then
        wait "$CCFS_PID" \
            2>/dev/null || true
    fi

    CCFS_PID=""

    detach_mount

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

    ./target/debug/ccfs \
        >"$RECOVERY_LOG" 2>&1 &

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
        ./target/debug/ccfs \
        >"$CRASH_LOG" 2>&1 &

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

sql_name_perm() {
    local name="$1"

    sqlite3 volume/metadata.db \
        "SELECT perm
         FROM entries
         WHERE name='$name';"
}

assert_file_text() {
    local path="$1"
    local expected="$2"

    python3 - "$path" "$expected" <<'PY'
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

assert_block_text() {
    local ino="$1"
    local expected="$2"

    python3 - "volume/blocks/$ino.bin" "$expected" <<'PY'
import sys

path = sys.argv[1]
expected = sys.argv[2].encode("utf-8")

with open(path, "rb") as f:
    actual = f.read()

if actual != expected:
    print("Expected block:", expected)
    print("Actual block:  ", actual)
    raise SystemExit(1)
PY
}

run_integrity_check() {
    ./target/debug/ccfs \
        --check-integrity \
        >"$INTEGRITY_LOG"

    grep -q \
        "ALL CCFS BLOCKS PASSED INTEGRITY CHECK" \
        "$INTEGRITY_LOG" ||
        fail "filesystem integrity check failed"
}

snapshot_volume() {
    stop_ccfs

    BACKUP_ROOT="$(
        mktemp -d /tmp/ccfs-kill9-backup.XXXXXX
    )"

    if [[ -d volume ]]; then
        cp -a \
            volume \
            "$BACKUP_ROOT/volume"
    else
        mkdir -p \
            "$BACKUP_ROOT/volume"
    fi
}

restore_volume() {
    if [[ -z "${BACKUP_ROOT:-}" ]]; then
        return
    fi

    stop_ccfs

    rm -rf volume

    if [[ -d "$BACKUP_ROOT/volume" ]]; then
        cp -a \
            "$BACKUP_ROOT/volume" \
            volume
    else
        mkdir -p volume
    fi

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

trap cleanup EXIT INT TERM

echo
echo "========================================"
echo " CCFS REAL SIGKILL Recovery Test Suite"
echo "========================================"
echo

echo "[1/18] Snapshotting original volume and building CCFS..."

snapshot_volume

cargo build --bin ccfs >/dev/null

./target/debug/ccfs \
    --recovery-status \
    >/dev/null

pass "volume snapshot created and CCFS built"

# ============================================================
# CREATE — AFTER BEGIN
# ============================================================

echo
echo "[2/18] CREATE crash after BEGIN..."

clear_recovery_state

start_crash_ccfs \
    "CREATE" \
    "after_begin"

timeout 5 \
    touch "$MOUNT_DIR/$CREATE_BEGIN_NAME" \
    2>/dev/null || true

wait_for_sigkill

[[ "$(sql_name_count "$CREATE_BEGIN_NAME")" == "0" ]] ||
    fail "CREATE-after-BEGIN changed metadata before recovery"

start_normal_ccfs

[[ ! -e "$MOUNT_DIR/$CREATE_BEGIN_NAME" ]] ||
    fail "incomplete CREATE became visible after restart"

grep -q \
    "incomplete ignored: 1" \
    "$RECOVERY_LOG" ||
    fail "CREATE-after-BEGIN was not classified incomplete"

stop_ccfs

pass "CREATE killed after BEGIN was safely ignored"

# ============================================================
# CREATE — AFTER COMMIT
# ============================================================

echo
echo "[3/18] CREATE crash after COMMIT..."

clear_recovery_state

start_crash_ccfs \
    "CREATE" \
    "after_commit"

timeout 5 \
    touch "$MOUNT_DIR/$CREATE_COMMIT_NAME" \
    2>/dev/null || true

wait_for_sigkill

[[ "$(sql_name_count "$CREATE_COMMIT_NAME")" == "0" ]] ||
    fail "CREATE-after-COMMIT applied before intended crash"

start_normal_ccfs

[[ -f "$MOUNT_DIR/$CREATE_COMMIT_NAME" ]] ||
    fail "committed CREATE was not recovered"

grep -q \
    "replayed: 1" \
    "$RECOVERY_LOG" ||
    fail "committed CREATE did not replay"

stop_ccfs

run_integrity_check

pass "CREATE killed after COMMIT recovered successfully"

# ============================================================
# MKDIR — AFTER BEGIN
# ============================================================

echo
echo "[4/18] MKDIR crash after BEGIN..."

clear_recovery_state

start_crash_ccfs \
    "MKDIR" \
    "after_begin"

timeout 5 \
    mkdir "$MOUNT_DIR/$MKDIR_BEGIN_NAME" \
    2>/dev/null || true

wait_for_sigkill

[[ "$(sql_name_count "$MKDIR_BEGIN_NAME")" == "0" ]] ||
    fail "MKDIR-after-BEGIN changed metadata before recovery"

start_normal_ccfs

[[ ! -e "$MOUNT_DIR/$MKDIR_BEGIN_NAME" ]] ||
    fail "incomplete MKDIR became visible after restart"

grep -q \
    "incomplete ignored: 1" \
    "$RECOVERY_LOG" ||
    fail "MKDIR-after-BEGIN was not classified incomplete"

stop_ccfs

pass "MKDIR killed after BEGIN was safely ignored"

# ============================================================
# MKDIR — AFTER COMMIT
# ============================================================

echo
echo "[5/18] MKDIR crash after COMMIT..."

clear_recovery_state

start_crash_ccfs \
    "MKDIR" \
    "after_commit"

timeout 5 \
    mkdir "$MOUNT_DIR/$MKDIR_COMMIT_NAME" \
    2>/dev/null || true

wait_for_sigkill

[[ "$(sql_name_count "$MKDIR_COMMIT_NAME")" == "0" ]] ||
    fail "MKDIR-after-COMMIT applied before intended crash"

start_normal_ccfs

[[ -d "$MOUNT_DIR/$MKDIR_COMMIT_NAME" ]] ||
    fail "committed MKDIR was not recovered"

grep -q \
    "replayed: 1" \
    "$RECOVERY_LOG" ||
    fail "committed MKDIR did not replay"

stop_ccfs

[[ "$(sql_name_count "$MKDIR_COMMIT_NAME")" == "1" ]] ||
    fail "recovered MKDIR metadata missing"

run_integrity_check

pass "MKDIR killed after COMMIT recovered successfully"

# ============================================================
# RMDIR — AFTER BEGIN
# ============================================================

echo
echo "[6/18] RMDIR crash after BEGIN..."

clear_recovery_state

start_normal_ccfs

mkdir "$MOUNT_DIR/$RMDIR_BEGIN_NAME"

[[ -d "$MOUNT_DIR/$RMDIR_BEGIN_NAME" ]] ||
    fail "RMDIR-after-BEGIN setup directory missing"

stop_ccfs

clear_recovery_state

start_crash_ccfs \
    "RMDIR" \
    "after_begin"

timeout 5 \
    rmdir "$MOUNT_DIR/$RMDIR_BEGIN_NAME" \
    2>/dev/null || true

wait_for_sigkill

[[ "$(sql_name_count "$RMDIR_BEGIN_NAME")" == "1" ]] ||
    fail "RMDIR-after-BEGIN removed metadata before recovery"

start_normal_ccfs

[[ -d "$MOUNT_DIR/$RMDIR_BEGIN_NAME" ]] ||
    fail "incomplete RMDIR removed directory after restart"

grep -q \
    "incomplete ignored: 1" \
    "$RECOVERY_LOG" ||
    fail "RMDIR-after-BEGIN was not classified incomplete"

stop_ccfs

pass "RMDIR killed after BEGIN preserved directory"

# ============================================================
# RMDIR — AFTER COMMIT
# ============================================================

echo
echo "[7/18] RMDIR crash after COMMIT..."

clear_recovery_state

start_normal_ccfs

mkdir "$MOUNT_DIR/$RMDIR_COMMIT_NAME"

[[ -d "$MOUNT_DIR/$RMDIR_COMMIT_NAME" ]] ||
    fail "RMDIR-after-COMMIT setup directory missing"

stop_ccfs

clear_recovery_state

start_crash_ccfs \
    "RMDIR" \
    "after_commit"

timeout 5 \
    rmdir "$MOUNT_DIR/$RMDIR_COMMIT_NAME" \
    2>/dev/null || true

wait_for_sigkill

[[ "$(sql_name_count "$RMDIR_COMMIT_NAME")" == "1" ]] ||
    fail "RMDIR-after-COMMIT applied before intended crash"

start_normal_ccfs

[[ ! -e "$MOUNT_DIR/$RMDIR_COMMIT_NAME" ]] ||
    fail "committed RMDIR directory returned after recovery"

grep -q \
    "replayed: 1" \
    "$RECOVERY_LOG" ||
    fail "committed RMDIR did not replay"

stop_ccfs

[[ "$(sql_name_count "$RMDIR_COMMIT_NAME")" == "0" ]] ||
    fail "recovered RMDIR left metadata"

run_integrity_check

pass "RMDIR killed after COMMIT recovered deletion"

# ============================================================
# WRITE — AFTER BEGIN
# ============================================================

echo
echo "[8/18] WRITE crash after BEGIN..."

clear_recovery_state

start_normal_ccfs

printf '%s' "OLD-WRITE-BEGIN" \
    > "$MOUNT_DIR/$WRITE_BEGIN_NAME"

WRITE_BEGIN_INO="$(
    stat -c '%i' \
        "$MOUNT_DIR/$WRITE_BEGIN_NAME"
)"

stop_ccfs

clear_recovery_state

start_crash_ccfs \
    "WRITE" \
    "after_begin"

timeout 5 python3 - \
    "$MOUNT_DIR/$WRITE_BEGIN_NAME" \
    2>/dev/null <<'PY' || true
import os
import sys

path = sys.argv[1]

fd = os.open(
    path,
    os.O_WRONLY,
)

try:
    os.pwrite(
        fd,
        b"NEW-WRITE-BEGIN",
        0,
    )

    os.fsync(fd)

finally:
    os.close(fd)
PY

wait_for_sigkill

assert_block_text \
    "$WRITE_BEGIN_INO" \
    "OLD-WRITE-BEGIN" ||
    fail "incomplete WRITE modified durable block"

start_normal_ccfs

assert_file_text \
    "$MOUNT_DIR/$WRITE_BEGIN_NAME" \
    "OLD-WRITE-BEGIN" ||
    fail "WRITE-after-BEGIN changed file after restart"

grep -q \
    "incomplete ignored: 1" \
    "$RECOVERY_LOG" ||
    fail "WRITE-after-BEGIN was not classified incomplete"

stop_ccfs

pass "WRITE killed after BEGIN preserved old data"

# ============================================================
# WRITE — AFTER COMMIT
# ============================================================

echo
echo "[9/18] WRITE crash after COMMIT..."

clear_recovery_state

start_normal_ccfs

printf '%s' "OLD-WRITE-COMMIT" \
    > "$MOUNT_DIR/$WRITE_COMMIT_NAME"

WRITE_COMMIT_INO="$(
    stat -c '%i' \
        "$MOUNT_DIR/$WRITE_COMMIT_NAME"
)"

stop_ccfs

clear_recovery_state

start_crash_ccfs \
    "WRITE" \
    "after_commit"

timeout 5 python3 - \
    "$MOUNT_DIR/$WRITE_COMMIT_NAME" \
    2>/dev/null <<'PY' || true
import os
import sys

path = sys.argv[1]

fd = os.open(
    path,
    os.O_WRONLY,
)

try:
    os.pwrite(
        fd,
        b"NEW-WRITE-COMMIT",
        0,
    )

    os.fsync(fd)

finally:
    os.close(fd)
PY

wait_for_sigkill

assert_block_text \
    "$WRITE_COMMIT_INO" \
    "OLD-WRITE-COMMIT" ||
    fail "WRITE-after-COMMIT applied before intended crash"

start_normal_ccfs

assert_file_text \
    "$MOUNT_DIR/$WRITE_COMMIT_NAME" \
    "NEW-WRITE-COMMIT" ||
    fail "committed WRITE was not recovered"

grep -q \
    "replayed: 1" \
    "$RECOVERY_LOG" ||
    fail "committed WRITE did not replay"

stop_ccfs

run_integrity_check

pass "WRITE killed after COMMIT recovered exact data"

# ============================================================
# TRUNCATE — AFTER BEGIN
# ============================================================

echo
echo "[10/18] TRUNCATE crash after BEGIN..."

clear_recovery_state

start_normal_ccfs

printf '%s' "TRUNCATE-BEGIN-DATA" \
    > "$MOUNT_DIR/$TRUNCATE_BEGIN_NAME"

TRUNCATE_BEGIN_INO="$(
    stat -c '%i' \
        "$MOUNT_DIR/$TRUNCATE_BEGIN_NAME"
)"

stop_ccfs

clear_recovery_state

start_crash_ccfs \
    "TRUNCATE" \
    "after_begin"

timeout 5 python3 - \
    "$MOUNT_DIR/$TRUNCATE_BEGIN_NAME" \
    2>/dev/null <<'PY' || true
import os
import sys

path = sys.argv[1]

os.truncate(
    path,
    8,
)
PY

wait_for_sigkill

assert_block_text \
    "$TRUNCATE_BEGIN_INO" \
    "TRUNCATE-BEGIN-DATA" ||
    fail "TRUNCATE-after-BEGIN changed durable data"

start_normal_ccfs

assert_file_text \
    "$MOUNT_DIR/$TRUNCATE_BEGIN_NAME" \
    "TRUNCATE-BEGIN-DATA" ||
    fail "incomplete TRUNCATE changed file after restart"

grep -q \
    "incomplete ignored: 1" \
    "$RECOVERY_LOG" ||
    fail "TRUNCATE-after-BEGIN was not classified incomplete"

stop_ccfs

run_integrity_check

pass "TRUNCATE killed after BEGIN preserved old data"

# ============================================================
# TRUNCATE — AFTER COMMIT
# ============================================================

echo
echo "[11/18] TRUNCATE crash after COMMIT..."

clear_recovery_state

start_normal_ccfs

printf '%s' "TRUNCATE-COMMIT-DATA" \
    > "$MOUNT_DIR/$TRUNCATE_COMMIT_NAME"

TRUNCATE_COMMIT_INO="$(
    stat -c '%i' \
        "$MOUNT_DIR/$TRUNCATE_COMMIT_NAME"
)"

stop_ccfs

clear_recovery_state

start_crash_ccfs \
    "TRUNCATE" \
    "after_commit"

timeout 5 python3 - \
    "$MOUNT_DIR/$TRUNCATE_COMMIT_NAME" \
    2>/dev/null <<'PY' || true
import os
import sys

path = sys.argv[1]

os.truncate(
    path,
    8,
)
PY

wait_for_sigkill

assert_block_text \
    "$TRUNCATE_COMMIT_INO" \
    "TRUNCATE-COMMIT-DATA" ||
    fail "TRUNCATE-after-COMMIT applied before intended crash"

start_normal_ccfs

assert_file_text \
    "$MOUNT_DIR/$TRUNCATE_COMMIT_NAME" \
    "TRUNCATE" ||
    fail "committed TRUNCATE was not recovered"

grep -q \
    "replayed: 1" \
    "$RECOVERY_LOG" ||
    fail "committed TRUNCATE did not replay"

stop_ccfs

run_integrity_check

pass "TRUNCATE killed after COMMIT recovered exact size and data"

# ============================================================
# SETATTR — AFTER BEGIN
# ============================================================

echo
echo "[12/18] SETATTR crash after BEGIN..."

clear_recovery_state

start_normal_ccfs

printf '%s' "SETATTR-BEGIN-DATA" \
    > "$MOUNT_DIR/$SETATTR_BEGIN_NAME"

chmod 644 \
    "$MOUNT_DIR/$SETATTR_BEGIN_NAME"

OLD_SETATTR_BEGIN_PERM="$(
    sql_name_perm \
        "$SETATTR_BEGIN_NAME"
)"

[[ "$OLD_SETATTR_BEGIN_PERM" == "420" ]] ||
    fail "SETATTR-after-BEGIN setup permission is not 0644"

stop_ccfs

clear_recovery_state

start_crash_ccfs \
    "SETATTR" \
    "after_begin"

timeout 5 \
    chmod 600 \
    "$MOUNT_DIR/$SETATTR_BEGIN_NAME" \
    2>/dev/null || true

wait_for_sigkill

[[ "$(sql_name_perm "$SETATTR_BEGIN_NAME")" == "$OLD_SETATTR_BEGIN_PERM" ]] ||
    fail "SETATTR-after-BEGIN changed durable permissions"

start_normal_ccfs

CURRENT_MODE="$(
    stat -c '%a' \
        "$MOUNT_DIR/$SETATTR_BEGIN_NAME"
)"

[[ "$CURRENT_MODE" == "644" ]] ||
    fail "incomplete SETATTR changed mode after restart"

grep -q \
    "incomplete ignored: 1" \
    "$RECOVERY_LOG" ||
    fail "SETATTR-after-BEGIN was not classified incomplete"

stop_ccfs

run_integrity_check

pass "SETATTR killed after BEGIN preserved old metadata"

# ============================================================
# SETATTR — AFTER COMMIT
# ============================================================

echo
echo "[13/18] SETATTR crash after COMMIT..."

clear_recovery_state

start_normal_ccfs

printf '%s' "SETATTR-COMMIT-DATA" \
    > "$MOUNT_DIR/$SETATTR_COMMIT_NAME"

chmod 644 \
    "$MOUNT_DIR/$SETATTR_COMMIT_NAME"

OLD_SETATTR_COMMIT_PERM="$(
    sql_name_perm \
        "$SETATTR_COMMIT_NAME"
)"

[[ "$OLD_SETATTR_COMMIT_PERM" == "420" ]] ||
    fail "SETATTR-after-COMMIT setup permission is not 0644"

stop_ccfs

clear_recovery_state

start_crash_ccfs \
    "SETATTR" \
    "after_commit"

timeout 5 \
    chmod 600 \
    "$MOUNT_DIR/$SETATTR_COMMIT_NAME" \
    2>/dev/null || true

wait_for_sigkill

[[ "$(sql_name_perm "$SETATTR_COMMIT_NAME")" == "$OLD_SETATTR_COMMIT_PERM" ]] ||
    fail "SETATTR-after-COMMIT applied before intended crash"

start_normal_ccfs

CURRENT_MODE="$(
    stat -c '%a' \
        "$MOUNT_DIR/$SETATTR_COMMIT_NAME"
)"

[[ "$CURRENT_MODE" == "600" ]] ||
    fail "committed SETATTR permission was not recovered"

grep -q \
    "replayed: 1" \
    "$RECOVERY_LOG" ||
    fail "committed SETATTR did not replay"

stop_ccfs

[[ "$(sql_name_perm "$SETATTR_COMMIT_NAME")" == "384" ]] ||
    fail "recovered SETATTR durable permission is incorrect"

run_integrity_check

pass "SETATTR killed after COMMIT recovered metadata"

# ============================================================
# RENAME — AFTER BEGIN
# ============================================================

echo
echo "[14/18] RENAME crash after BEGIN..."

clear_recovery_state

start_normal_ccfs

printf '%s' "RENAME-BEGIN-DATA" \
    > "$MOUNT_DIR/$RENAME_BEGIN_OLD"

RENAME_BEGIN_INO="$(
    stat -c '%i' \
        "$MOUNT_DIR/$RENAME_BEGIN_OLD"
)"

stop_ccfs

clear_recovery_state

start_crash_ccfs \
    "RENAME" \
    "after_begin"

timeout 5 \
    mv \
    "$MOUNT_DIR/$RENAME_BEGIN_OLD" \
    "$MOUNT_DIR/$RENAME_BEGIN_NEW" \
    2>/dev/null || true

wait_for_sigkill

CURRENT_RENAME_BEGIN_NAME="$(
    sqlite3 volume/metadata.db \
        "SELECT name
         FROM entries
         WHERE ino=$RENAME_BEGIN_INO;"
)"

[[ "$CURRENT_RENAME_BEGIN_NAME" == "$RENAME_BEGIN_OLD" ]] ||
    fail "RENAME-after-BEGIN changed metadata"

start_normal_ccfs

[[ -f "$MOUNT_DIR/$RENAME_BEGIN_OLD" ]] ||
    fail "old rename path disappeared after incomplete crash"

[[ ! -e "$MOUNT_DIR/$RENAME_BEGIN_NEW" ]] ||
    fail "incomplete rename became visible"

stop_ccfs

pass "RENAME killed after BEGIN preserved old namespace"

# ============================================================
# RENAME — AFTER COMMIT
# ============================================================

echo
echo "[15/18] RENAME crash after COMMIT..."

clear_recovery_state

start_normal_ccfs

printf '%s' "RENAME-COMMIT-DATA" \
    > "$MOUNT_DIR/$RENAME_COMMIT_OLD"

RENAME_COMMIT_INO="$(
    stat -c '%i' \
        "$MOUNT_DIR/$RENAME_COMMIT_OLD"
)"

stop_ccfs

clear_recovery_state

start_crash_ccfs \
    "RENAME" \
    "after_commit"

timeout 5 \
    mv \
    "$MOUNT_DIR/$RENAME_COMMIT_OLD" \
    "$MOUNT_DIR/$RENAME_COMMIT_NEW" \
    2>/dev/null || true

wait_for_sigkill

CURRENT_RENAME_COMMIT_NAME="$(
    sqlite3 volume/metadata.db \
        "SELECT name
         FROM entries
         WHERE ino=$RENAME_COMMIT_INO;"
)"

[[ "$CURRENT_RENAME_COMMIT_NAME" == "$RENAME_COMMIT_OLD" ]] ||
    fail "RENAME-after-COMMIT applied before intended crash"

start_normal_ccfs

[[ ! -e "$MOUNT_DIR/$RENAME_COMMIT_OLD" ]] ||
    fail "old path survived committed rename recovery"

[[ -f "$MOUNT_DIR/$RENAME_COMMIT_NEW" ]] ||
    fail "new path missing after committed rename recovery"

grep -q \
    "replayed: 1" \
    "$RECOVERY_LOG" ||
    fail "committed RENAME did not replay"

stop_ccfs

run_integrity_check

pass "RENAME killed after COMMIT recovered namespace"

# ============================================================
# DELETE — AFTER BEGIN
# ============================================================

echo
echo "[16/18] DELETE crash after BEGIN..."

clear_recovery_state

start_normal_ccfs

printf '%s' "DELETE-BEGIN-DATA" \
    > "$MOUNT_DIR/$DELETE_BEGIN_NAME"

DELETE_BEGIN_INO="$(
    stat -c '%i' \
        "$MOUNT_DIR/$DELETE_BEGIN_NAME"
)"

stop_ccfs

clear_recovery_state

start_crash_ccfs \
    "DELETE" \
    "after_begin"

timeout 5 \
    rm "$MOUNT_DIR/$DELETE_BEGIN_NAME" \
    2>/dev/null || true

wait_for_sigkill

[[ "$(sql_name_count "$DELETE_BEGIN_NAME")" == "1" ]] ||
    fail "DELETE-after-BEGIN removed metadata"

[[ -f "volume/blocks/$DELETE_BEGIN_INO.bin" ]] ||
    fail "DELETE-after-BEGIN removed data block"

start_normal_ccfs

[[ -f "$MOUNT_DIR/$DELETE_BEGIN_NAME" ]] ||
    fail "incomplete DELETE removed file after restart"

assert_file_text \
    "$MOUNT_DIR/$DELETE_BEGIN_NAME" \
    "DELETE-BEGIN-DATA" ||
    fail "incomplete DELETE corrupted file"

stop_ccfs

pass "DELETE killed after BEGIN preserved file"

# ============================================================
# DELETE — AFTER COMMIT
# ============================================================

echo
echo "[17/18] DELETE crash after COMMIT..."

clear_recovery_state

start_normal_ccfs

printf '%s' "DELETE-COMMIT-DATA" \
    > "$MOUNT_DIR/$DELETE_COMMIT_NAME"

DELETE_COMMIT_INO="$(
    stat -c '%i' \
        "$MOUNT_DIR/$DELETE_COMMIT_NAME"
)"

stop_ccfs

clear_recovery_state

start_crash_ccfs \
    "DELETE" \
    "after_commit"

timeout 5 \
    rm "$MOUNT_DIR/$DELETE_COMMIT_NAME" \
    2>/dev/null || true

wait_for_sigkill

[[ "$(sql_name_count "$DELETE_COMMIT_NAME")" == "1" ]] ||
    fail "DELETE-after-COMMIT applied before intended crash"

[[ -f "volume/blocks/$DELETE_COMMIT_INO.bin" ]] ||
    fail "DELETE block vanished before intended crash"

start_normal_ccfs

[[ ! -e "$MOUNT_DIR/$DELETE_COMMIT_NAME" ]] ||
    fail "committed DELETE target returned after recovery"

grep -q \
    "replayed: 1" \
    "$RECOVERY_LOG" ||
    fail "committed DELETE did not replay"

stop_ccfs

[[ "$(sql_name_count "$DELETE_COMMIT_NAME")" == "0" ]] ||
    fail "recovered DELETE left metadata"

[[ ! -e "volume/blocks/$DELETE_COMMIT_INO.bin" ]] ||
    fail "recovered DELETE left data block"

[[ ! -e "volume/blocks/$DELETE_COMMIT_INO.checksum" ]] ||
    fail "recovered DELETE left checksum"

pass "DELETE killed after COMMIT recovered deletion"

# ============================================================
# FINAL
# ============================================================

echo
echo "[18/18] Final integrity verification..."

run_integrity_check

echo
echo "Restoring original pre-test volume..."

restore_volume

trap - EXIT INT TERM

rm -f "$CRASH_LOG"
rm -f "$RECOVERY_LOG"
rm -f "$INTEGRITY_LOG"

echo
echo "========================================"
echo " ALL CCFS REAL SIGKILL TESTS PASSED"
echo "========================================"
echo