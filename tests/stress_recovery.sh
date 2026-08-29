#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

MOUNT_DIR="mount"

NORMAL_LOG="/tmp/ccfs-stress-normal.log"
CRASH_LOG="/tmp/ccfs-stress-crash.log"
INTEGRITY_LOG="/tmp/ccfs-stress-integrity.log"
CHECKPOINT_LOG="/tmp/ccfs-stress-checkpoint.log"
STATUS_LOG="/tmp/ccfs-stress-status.log"

RUN_ID="$(date +%s)"

WORKERS=6
ITERATIONS=20
RESTART_CYCLES=3
CRASH_CYCLES=3

SENTINEL="stress-sentinel-$RUN_ID.txt"
SENTINEL_DATA="CCFS-STRESS-SENTINEL-$RUN_ID"

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

    # Always attempt a normal and then lazy FUSE unmount.
    # After SIGKILL, a stale "Transport endpoint is not connected"
    # mount may not be reported reliably by mountpoint -q.
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

    : > "$NORMAL_LOG"

    ./target/debug/ccfs >"$NORMAL_LOG" 2>&1 &
    CCFS_PID=$!

    wait_for_mount "$CCFS_PID" ||
        fail "CCFS failed to mount"
}

kill_ccfs_hard() {
    local pid="$CCFS_PID"

    [[ -n "$pid" ]] ||
        fail "no CCFS pid available for SIGKILL"

    kill -0 "$pid" 2>/dev/null ||
        fail "CCFS exited before SIGKILL"

    set +e

    kill -9 "$pid" 2>/dev/null

    wait "$pid" 2>/dev/null
    local status=$?

    set -e

    CCFS_PID=""

    detach_mount

    [[ "$status" -eq 137 ]] ||
        fail "expected SIGKILL status 137, got $status"
}

snapshot_volume() {
    stop_ccfs

    BACKUP_ROOT="$(
        mktemp -d /tmp/ccfs-stress-backup.XXXXXX
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

    cp -a \
        "$BACKUP_ROOT/volume" \
        volume

    rm -rf "$BACKUP_ROOT"

    BACKUP_ROOT=""
}

cleanup() {
    set +e

    restore_volume

    rm -f "$NORMAL_LOG"
    rm -f "$CRASH_LOG"
    rm -f "$INTEGRITY_LOG"
    rm -f "$CHECKPOINT_LOG"
    rm -f "$STATUS_LOG"

    set -e
}

run_integrity_check() {
    stop_ccfs

    ./target/debug/ccfs \
        --check-integrity \
        >"$INTEGRITY_LOG" 2>&1 ||
    {
        cat "$INTEGRITY_LOG"
        fail "integrity verification failed"
    }

    grep -q \
        "ALL CCFS BLOCKS PASSED INTEGRITY CHECK" \
        "$INTEGRITY_LOG" ||
        fail "integrity success marker missing"
}

assert_parallel_results() {
    local worker
    local path
    local expected
    local actual

    for worker in $(seq 1 "$WORKERS"); do
        path="$MOUNT_DIR/stress-worker-$RUN_ID-$worker/final.txt"

        expected="worker=$worker;final"

        [[ -f "$path" ]] ||
            fail "worker $worker final file missing"

        actual="$(cat "$path")"

        [[ "$actual" == "$expected" ]] ||
            fail "worker $worker final content mismatch"
    done
}

assert_sentinel() {
    [[ -f "$MOUNT_DIR/$SENTINEL" ]] ||
        fail "stress sentinel missing"

    local actual

    actual="$(cat "$MOUNT_DIR/$SENTINEL")"

    [[ "$actual" == "$SENTINEL_DATA" ]] ||
        fail "stress sentinel data corrupted"
}

run_parallel_worker() {
    local worker="$1"

    python3 - \
        "$MOUNT_DIR" \
        "$RUN_ID" \
        "$worker" \
        "$ITERATIONS" <<'PY'
import os
import sys

mount_dir = sys.argv[1]
run_id = sys.argv[2]
worker = int(sys.argv[3])
iterations = int(sys.argv[4])

worker_dir = os.path.join(
    mount_dir,
    f"stress-worker-{run_id}-{worker}",
)

os.mkdir(worker_dir)

for i in range(iterations):
    original = os.path.join(
        worker_dir,
        f"file-{i}.txt",
    )

    renamed = os.path.join(
        worker_dir,
        f"file-{i}.renamed",
    )

    payload = (
        f"worker={worker};iteration={i};phase=create"
    ).encode()

    fd = os.open(
        original,
        os.O_CREAT | os.O_WRONLY | os.O_TRUNC,
        0o644,
    )

    try:
        written = os.write(fd, payload)

        if written != len(payload):
            raise RuntimeError("short initial write")

        os.fsync(fd)

    finally:
        os.close(fd)

    os.rename(
        original,
        renamed,
    )

    append_payload = b";phase=append"

    fd = os.open(
        renamed,
        os.O_WRONLY | os.O_APPEND,
    )

    try:
        written = os.write(
            fd,
            append_payload,
        )

        if written != len(append_payload):
            raise RuntimeError("short append write")

        os.fdatasync(fd)

    finally:
        os.close(fd)

    if i % 3 == 0:
        os.unlink(renamed)

final_path = os.path.join(
    worker_dir,
    "final.txt",
)

final_payload = f"worker={worker};final".encode()

fd = os.open(
    final_path,
    os.O_CREAT | os.O_WRONLY | os.O_TRUNC,
    0o644,
)

try:
    written = os.write(
        fd,
        final_payload,
    )

    if written != len(final_payload):
        raise RuntimeError("short final write")

    os.fsync(fd)

finally:
    os.close(fd)
PY
}

run_crash_workload() {
    local cycle="$1"

    python3 - \
        "$MOUNT_DIR" \
        "$RUN_ID" \
        "$cycle" <<'PY'
import os
import sys

mount_dir = sys.argv[1]
run_id = sys.argv[2]
cycle = sys.argv[3]

base = os.path.join(
    mount_dir,
    f"stress-crash-{run_id}-{cycle}",
)

try:
    os.mkdir(base)
except OSError:
    pass

for i in range(200):
    path = os.path.join(
        base,
        f"crash-{i}.txt",
    )

    renamed = os.path.join(
        base,
        f"crash-{i}.renamed",
    )

    payload = (
        f"cycle={cycle};iteration={i}"
    ).encode()

    try:
        fd = os.open(
            path,
            os.O_CREAT | os.O_WRONLY | os.O_TRUNC,
            0o644,
        )

        try:
            os.write(
                fd,
                payload,
            )

            os.fsync(fd)

        finally:
            os.close(fd)

        if i % 2 == 0:
            os.rename(
                path,
                renamed,
            )

            path = renamed

        if i % 5 == 0:
            os.unlink(path)

    except OSError:
        break
PY
}

trap cleanup EXIT INT TERM

echo
echo "========================================"
echo " CCFS CONCURRENCY / STRESS / CRASH TEST"
echo "========================================"
echo

# Clean any stale/broken FUSE mount before touching mount/.
fusermount3 -u "$MOUNT_DIR" 2>/dev/null || true
fusermount3 -uz "$MOUNT_DIR" 2>/dev/null || true
sleep 0.1

mkdir -p "$MOUNT_DIR"
mkdir -p volume/blocks

echo "[1/9] Snapshotting volume and building..."

snapshot_volume

cargo build --bin ccfs >/dev/null

pass "volume snapshot created and CCFS built"

echo
echo "[2/9] Running parallel filesystem workload..."

start_normal_ccfs

WORKER_PIDS=()

for worker in $(seq 1 "$WORKERS"); do
    run_parallel_worker "$worker" &
    WORKER_PIDS+=("$!")
done

for pid in "${WORKER_PIDS[@]}"; do
    if ! wait "$pid"; then
        fail "parallel worker failed"
    fi
done

assert_parallel_results

pass "$WORKERS parallel workers completed successfully"

echo
echo "[3/9] Verifying parallel workload durability..."

stop_ccfs
start_normal_ccfs

assert_parallel_results

run_integrity_check

pass "parallel workload survived restart and integrity check"

echo
echo "[4/9] Running repeated clean restart cycles..."

for cycle in $(seq 1 "$RESTART_CYCLES"); do
    start_normal_ccfs

    assert_parallel_results

    stop_ccfs

    echo "PASS: clean restart cycle $cycle/$RESTART_CYCLES"
done

pass "all clean restart cycles completed"

echo
echo "[5/9] Creating durable crash sentinel..."

start_normal_ccfs

python3 - \
    "$MOUNT_DIR/$SENTINEL" \
    "$SENTINEL_DATA" <<'PY'
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
    written = os.write(
        fd,
        payload,
    )

    if written != len(payload):
        raise RuntimeError("short sentinel write")

    os.fsync(fd)

finally:
    os.close(fd)
PY

assert_sentinel

stop_ccfs

pass "durable sentinel created"

echo
echo "[6/9] Running repeated arbitrary SIGKILL cycles..."

for cycle in $(seq 1 "$CRASH_CYCLES"); do
    start_normal_ccfs

    assert_sentinel

    : > "$CRASH_LOG"

    run_crash_workload "$cycle" \
        >"$CRASH_LOG" 2>&1 &

    WORKLOAD_PID=$!

    sleep 0.20

    kill_ccfs_hard

    set +e

    wait "$WORKLOAD_PID" 2>/dev/null

    set -e

    start_normal_ccfs

    assert_sentinel

    stop_ccfs

    run_integrity_check

    echo "PASS: SIGKILL recovery cycle $cycle/$CRASH_CYCLES"
done

pass "all arbitrary SIGKILL cycles recovered cleanly"

echo
echo "[7/9] Final restart and namespace verification..."

start_normal_ccfs

assert_parallel_results
assert_sentinel

stop_ccfs

run_integrity_check

pass "final namespace and block integrity healthy"

echo
echo "[8/9] Compacting recovery journal..."

./target/debug/ccfs \
    --checkpoint \
    >"$CHECKPOINT_LOG" 2>&1 ||
{
    cat "$CHECKPOINT_LOG"
    fail "final checkpoint failed"
}

cat "$CHECKPOINT_LOG"

./target/debug/ccfs \
    --recovery-status \
    >"$STATUS_LOG" 2>&1 ||
    fail "unable to inspect recovery status"

grep -q \
    "Total transactions:          0" \
    "$STATUS_LOG" ||
    fail "journal not empty after final checkpoint"

run_integrity_check

pass "journal compacted and final integrity remained healthy"

echo
echo "[9/9] Restoring original pre-test volume..."

restore_volume

trap - EXIT INT TERM

rm -f "$NORMAL_LOG"
rm -f "$CRASH_LOG"
rm -f "$INTEGRITY_LOG"
rm -f "$CHECKPOINT_LOG"
rm -f "$STATUS_LOG"

echo
echo "========================================"
echo " ALL CCFS STRESS / CRASH TESTS PASSED"
echo "========================================"
echo
