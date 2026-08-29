#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

MOUNT_DIR="mount"

RUN_ID="$(date +%s)"

THROUGHPUT_FILE="perf-throughput-$RUN_ID.bin"
LATENCY_FILE="perf-latency-$RUN_ID.bin"
RECOVERY_FILE="perf-recovery-$RUN_ID.bin"

NORMAL_LOG="/tmp/ccfs-performance-normal.log"
CRASH_LOG="/tmp/ccfs-performance-crash.log"
INTEGRITY_LOG="/tmp/ccfs-performance-integrity.log"
CHECKPOINT_LOG="/tmp/ccfs-performance-checkpoint.log"

METRICS_FILE="/tmp/ccfs-performance-metrics-$RUN_ID.txt"

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

    echo
    echo "Metrics:"
    echo "----------------------------------------"
    cat "$METRICS_FILE" 2>/dev/null || true

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

    for _ in $(seq 1 200); do
        if is_mounted; then
            return 0
        fi

        if ! kill -0 "$pid" 2>/dev/null; then
            return 1
        fi

        sleep 0.02
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

snapshot_volume() {
    stop_ccfs

    BACKUP_ROOT="$(
        mktemp -d /tmp/ccfs-performance-backup.XXXXXX
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
    rm -f "$INTEGRITY_LOG"
    rm -f "$CHECKPOINT_LOG"
    rm -f "$METRICS_FILE"

    set -e
}

run_integrity() {
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

trap cleanup EXIT INT TERM

echo
echo "========================================"
echo " CCFS PERFORMANCE ACCEPTANCE TESTS"
echo "========================================"
echo

fusermount3 -u "$MOUNT_DIR" 2>/dev/null || true
fusermount3 -uz "$MOUNT_DIR" 2>/dev/null || true
sleep 0.1

mkdir -p "$MOUNT_DIR"

: > "$METRICS_FILE"

echo "[1/7] Preserving original volume and building..."

snapshot_volume

cargo build --bin ccfs >/dev/null

rm -rf volume
mkdir -p volume/blocks

start_ccfs

pass "clean benchmark filesystem mounted"

echo
echo "[2/7] Measuring sequential write throughput..."

python3 - \
    "$MOUNT_DIR/$THROUGHPUT_FILE" \
    "$METRICS_FILE" <<'PY'
import hashlib
import os
import sys
import time

path = sys.argv[1]
metrics_path = sys.argv[2]

size = 4 * 1024 * 1024
chunk_size = 64 * 1024

chunk = bytes(
    (index % 251 for index in range(chunk_size))
)

expected_hash = hashlib.sha256()

fd = os.open(
    path,
    os.O_CREAT | os.O_WRONLY | os.O_TRUNC,
    0o644,
)

start = time.perf_counter()

try:
    remaining = size

    while remaining:
        part = chunk[:min(chunk_size, remaining)]

        offset = 0

        while offset < len(part):
            written = os.write(fd, part[offset:])

            if written <= 0:
                raise RuntimeError(
                    "write benchmark made no progress"
                )

            expected_hash.update(
                part[offset:offset + written]
            )

            offset += written
            remaining -= written

    os.fsync(fd)

finally:
    os.close(fd)

elapsed = time.perf_counter() - start

if elapsed <= 0:
    raise RuntimeError("invalid write benchmark duration")

mib = size / (1024 * 1024)
throughput = mib / elapsed

with open(
    "/tmp/ccfs-performance-expected-hash",
    "w",
) as handle:
    handle.write(expected_hash.hexdigest())

with open(metrics_path, "a") as handle:
    handle.write(
        f"WRITE_THROUGHPUT_MIB_S={throughput:.3f}\n"
    )
    handle.write(
        f"WRITE_DURATION_S={elapsed:.6f}\n"
    )

print(
    f"WRITE throughput: {throughput:.3f} MiB/s "
    f"({mib:.0f} MiB in {elapsed:.3f}s)"
)

if throughput <= 0:
    raise RuntimeError(
        "write throughput must be greater than zero"
    )
PY

pass "write throughput measured successfully"

echo
echo "[3/7] Measuring sequential read throughput..."

python3 - \
    "$MOUNT_DIR/$THROUGHPUT_FILE" \
    "$METRICS_FILE" <<'PY'
import hashlib
import os
import sys
import time

path = sys.argv[1]
metrics_path = sys.argv[2]

with open(
    "/tmp/ccfs-performance-expected-hash",
    "r",
) as handle:
    expected_hash = handle.read().strip()

start = time.perf_counter()

digest = hashlib.sha256()
total = 0

with open(path, "rb", buffering=0) as handle:
    while True:
        chunk = handle.read(64 * 1024)

        if not chunk:
            break

        digest.update(chunk)
        total += len(chunk)

elapsed = time.perf_counter() - start

if digest.hexdigest() != expected_hash:
    raise RuntimeError(
        "read benchmark content hash mismatch"
    )

if total != 4 * 1024 * 1024:
    raise RuntimeError(
        f"read benchmark size mismatch: {total}"
    )

if elapsed <= 0:
    raise RuntimeError("invalid read benchmark duration")

mib = total / (1024 * 1024)
throughput = mib / elapsed

with open(metrics_path, "a") as handle:
    handle.write(
        f"READ_THROUGHPUT_MIB_S={throughput:.3f}\n"
    )
    handle.write(
        f"READ_DURATION_S={elapsed:.6f}\n"
    )

print(
    f"READ throughput: {throughput:.3f} MiB/s "
    f"({mib:.0f} MiB in {elapsed:.3f}s)"
)

if throughput <= 0:
    raise RuntimeError(
        "read throughput must be greater than zero"
    )
PY

pass "read throughput measured successfully"

echo
echo "[4/7] Measuring p50/p95/p99 durable-write latency..."

python3 - \
    "$MOUNT_DIR/$LATENCY_FILE" \
    "$METRICS_FILE" <<'PY'
import math
import os
import statistics
import sys
import time

path = sys.argv[1]
metrics_path = sys.argv[2]

payload = b"L" * 4096

fd = os.open(
    path,
    os.O_CREAT | os.O_WRONLY | os.O_TRUNC,
    0o644,
)

latencies_ms = []

try:
    # Small warm-up before measured operations.
    for index in range(5):
        os.lseek(fd, 0, os.SEEK_SET)
        os.write(fd, payload)
        os.fsync(fd)

    for index in range(50):
        payload = bytes(
            [65 + (index % 26)]
        ) * 4096

        start = time.perf_counter_ns()

        os.lseek(fd, 0, os.SEEK_SET)

        offset = 0

        while offset < len(payload):
            written = os.write(
                fd,
                payload[offset:],
            )

            if written <= 0:
                raise RuntimeError(
                    "latency write made no progress"
                )

            offset += written

        os.fsync(fd)

        end = time.perf_counter_ns()

        latencies_ms.append(
            (end - start) / 1_000_000.0
        )

finally:
    os.close(fd)

ordered = sorted(latencies_ms)

def percentile(values, percentile_value):
    rank = math.ceil(
        (percentile_value / 100.0) * len(values)
    )

    index = max(0, min(len(values) - 1, rank - 1))

    return values[index]

p50 = percentile(ordered, 50)
p95 = percentile(ordered, 95)
p99 = percentile(ordered, 99)
mean = statistics.mean(ordered)

if not (
    0 < p50 <= p95 <= p99
):
    raise RuntimeError(
        f"invalid percentile ordering: "
        f"{p50}, {p95}, {p99}"
    )

with open(metrics_path, "a") as handle:
    handle.write(
        f"WRITE_LATENCY_P50_MS={p50:.3f}\n"
    )
    handle.write(
        f"WRITE_LATENCY_P95_MS={p95:.3f}\n"
    )
    handle.write(
        f"WRITE_LATENCY_P99_MS={p99:.3f}\n"
    )
    handle.write(
        f"WRITE_LATENCY_MEAN_MS={mean:.3f}\n"
    )

print(
    "Durable 4 KiB WRITE latency: "
    f"p50={p50:.3f} ms, "
    f"p95={p95:.3f} ms, "
    f"p99={p99:.3f} ms"
)
PY

pass "p50/p95/p99 latency metrics measured successfully"

echo
echo "[5/7] Preparing committed transaction for recovery timing..."

python3 - \
    "$MOUNT_DIR/$RECOVERY_FILE" <<'PY'
import os
import sys

path = sys.argv[1]

payload = b"R" * 4096

fd = os.open(
    path,
    os.O_CREAT | os.O_WRONLY | os.O_TRUNC,
    0o644,
)

try:
    offset = 0

    while offset < len(payload):
        written = os.write(
            fd,
            payload[offset:],
        )

        if written <= 0:
            raise RuntimeError(
                "recovery baseline write made no progress"
            )

        offset += written

    os.fsync(fd)

finally:
    os.close(fd)
PY

stop_ccfs

checkpoint_clean

detach_mount
: > "$CRASH_LOG"

set +e

env \
    CCFS_KILL9_OPERATION=WRITE \
    CCFS_KILL9_POINT=after_commit \
    ./target/debug/ccfs \
    >"$CRASH_LOG" 2>&1 &

CCFS_PID=$!

if ! wait_for_mount "$CCFS_PID"; then
    set -e
    fail "crash benchmark CCFS failed to mount"
fi

python3 - \
    "$MOUNT_DIR/$RECOVERY_FILE" <<'PY'
import os
import sys

path = sys.argv[1]

payload = b"N" * 4096

fd = os.open(path, os.O_WRONLY)

try:
    os.write(fd, payload)
finally:
    try:
        os.close(fd)
    except OSError:
        pass
PY

wait "$CCFS_PID"
CRASH_STATUS=$?

set -e

CCFS_PID=""

detach_mount

[[ "$CRASH_STATUS" -eq 137 ]] ||
    fail "expected recovery benchmark SIGKILL status 137"

grep -q \
    "CCFS TEST FAILPOINT: SIGKILL operation=WRITE point=after_commit" \
    "$CRASH_LOG" ||
    fail "recovery benchmark crash marker missing"

pass "committed-but-unrecovered WRITE prepared"

echo
echo "[6/7] Measuring recovery duration..."

: > "$NORMAL_LOG"

START_NS="$(date +%s%N)"

./target/debug/ccfs \
    >"$NORMAL_LOG" 2>&1 &

CCFS_PID=$!

wait_for_mount "$CCFS_PID" ||
    fail "CCFS failed to mount during recovery benchmark"

END_NS="$(date +%s%N)"

RECOVERY_MS="$(
    python3 - \
        "$START_NS" \
        "$END_NS" <<'PY'
import sys

start = int(sys.argv[1])
end = int(sys.argv[2])

print(f"{(end - start) / 1_000_000.0:.3f}")
PY
)"

python3 - \
    "$MOUNT_DIR/$RECOVERY_FILE" <<'PY'
import sys

path = sys.argv[1]

with open(path, "rb") as handle:
    actual = handle.read()

expected = b"N" * 4096

if actual != expected:
    raise RuntimeError(
        "recovered file content mismatch"
    )
PY

grep -q \
    "replayed: 1" \
    "$NORMAL_LOG" ||
    fail "timed recovery did not replay transaction"

python3 - \
    "$RECOVERY_MS" \
    "$METRICS_FILE" <<'PY'
import sys

recovery_ms = float(sys.argv[1])
metrics_path = sys.argv[2]

if recovery_ms <= 0:
    raise RuntimeError(
        "recovery duration must be greater than zero"
    )

with open(metrics_path, "a") as handle:
    handle.write(
        f"RECOVERY_DURATION_MS={recovery_ms:.3f}\n"
    )

print(
    f"Recovery-to-mount duration: "
    f"{recovery_ms:.3f} ms"
)
PY

pass "recovery duration measured and recovered data verified"

echo
echo "[7/7] Final integrity and performance summary..."

stop_ccfs

run_integrity
checkpoint_clean
run_integrity

echo
echo "----------------------------------------"
echo " CCFS PERFORMANCE RESULTS"
echo "----------------------------------------"

cat "$METRICS_FILE"

echo "----------------------------------------"

restore_volume

trap - EXIT INT TERM

rm -f "$NORMAL_LOG"
rm -f "$CRASH_LOG"
rm -f "$INTEGRITY_LOG"
rm -f "$CHECKPOINT_LOG"
rm -f "$METRICS_FILE"
rm -f /tmp/ccfs-performance-expected-hash

echo
echo "========================================"
echo " ALL CCFS PERFORMANCE TESTS PASSED"
echo "========================================"
echo
