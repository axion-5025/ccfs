#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

MOUNT_DIR="mount"
RUN_ID="$(date +%s)"

READ_FILE="concurrent-read-$RUN_ID.bin"
WRITE_RENAME_SRC="write-rename-src-$RUN_ID.bin"
WRITE_RENAME_DST="write-rename-dst-$RUN_ID.bin"
MAP_A="mapping-a-$RUN_ID.bin"
MAP_B="mapping-b-$RUN_ID.bin"
RENAME_DELETE_SRC="rename-delete-src-$RUN_ID.bin"
RENAME_DELETE_DST="rename-delete-dst-$RUN_ID.bin"
READ_TRUNCATE_FILE="read-truncate-$RUN_ID.bin"
STRESS_DIR="acceptance-stress-$RUN_ID"
SENTINEL_FILE="remaining-sentinel-$RUN_ID.txt"

NORMAL_LOG="/tmp/ccfs-remaining-normal.log"
INTEGRITY_LOG="/tmp/ccfs-remaining-integrity.log"
CHECKPOINT_LOG="/tmp/ccfs-remaining-checkpoint.log"

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

    for _ in $(seq 1 160); do
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

snapshot_volume() {
    stop_ccfs

    BACKUP_ROOT="$(
        mktemp -d /tmp/ccfs-remaining-backup.XXXXXX
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
    rm -f "$INTEGRITY_LOG"
    rm -f "$CHECKPOINT_LOG"

    rm -f "/tmp/ccfs-map-a-$RUN_ID.bin"
    rm -f "/tmp/ccfs-map-b-$RUN_ID.bin"

    set -e
}

run_integrity_pass() {
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

run_integrity_fail() {
    stop_ccfs

    set +e

    ./target/debug/ccfs \
        --check-integrity \
        >"$INTEGRITY_LOG" 2>&1

    local status=$?

    set -e

    [[ "$status" -ne 0 ]] ||
        fail "integrity checker accepted invalid block mapping"
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

    local recovery_status

    recovery_status="$(
        ./target/debug/ccfs --recovery-status
    )"

    grep -q \
        "Total transactions:          0" \
        <<<"$recovery_status" ||
        fail "journal not empty after checkpoint"
}

trap cleanup EXIT INT TERM

echo
echo "========================================"
echo " CCFS REMAINING ACCEPTANCE TESTS"
echo "========================================"
echo

fusermount3 -u "$MOUNT_DIR" 2>/dev/null || true
fusermount3 -uz "$MOUNT_DIR" 2>/dev/null || true
sleep 0.1

mkdir -p "$MOUNT_DIR"

echo "[1/9] Preserving original volume and building..."

snapshot_volume

cargo build --bin ccfs >/dev/null

rm -rf volume
mkdir -p volume/blocks

start_ccfs

pass "clean acceptance filesystem mounted"

echo
echo "[2/9] Testing concurrent reads..."

python3 - \
    "$MOUNT_DIR/$READ_FILE" <<'PY'
import hashlib
import multiprocessing
import os
import sys

path = sys.argv[1]

payload = bytes(
    (index % 251 for index in range(128 * 1024))
)

with open(path, "wb") as handle:
    handle.write(payload)
    handle.flush()
    os.fsync(handle.fileno())

expected_hash = hashlib.sha256(payload).hexdigest()

start = multiprocessing.Event()
queue = multiprocessing.Queue()

def worker(worker_id):
    try:
        start.wait()

        for iteration in range(20):
            with open(path, "rb") as handle:
                data = handle.read()

            digest = hashlib.sha256(data).hexdigest()

            if digest != expected_hash:
                raise RuntimeError(
                    f"worker {worker_id} hash mismatch "
                    f"at iteration {iteration}"
                )

        queue.put(("ok", worker_id))

    except BaseException as error:
        queue.put(
            ("error", worker_id, repr(error))
        )

processes = [
    multiprocessing.Process(
        target=worker,
        args=(worker_id,),
    )
    for worker_id in range(6)
]

for process in processes:
    process.start()

start.set()

for process in processes:
    process.join(30)

    if process.is_alive():
        process.terminate()
        process.join()
        raise RuntimeError(
            "concurrent reader timed out"
        )

results = [
    queue.get(timeout=5)
    for _ in processes
]

errors = [
    result
    for result in results
    if result[0] != "ok"
]

if errors:
    raise RuntimeError(
        f"concurrent read failures: {errors}"
    )

print(
    "Concurrent-read operations completed: "
    f"{6 * 20}"
)
PY

pass "6 processes completed 120 verified concurrent reads"

echo
echo "[3/9] Testing write + rename race on same inode..."

python3 - \
    "$MOUNT_DIR/$WRITE_RENAME_SRC" \
    "$MOUNT_DIR/$WRITE_RENAME_DST" <<'PY'
import multiprocessing
import os
import sys

src = sys.argv[1]
dst = sys.argv[2]

old_payload = b"A" * 4096
new_payload = b"B" * 4096

with open(src, "wb") as handle:
    handle.write(old_payload)
    handle.flush()
    os.fsync(handle.fileno())

writer_ready = multiprocessing.Event()
start = multiprocessing.Event()
queue = multiprocessing.Queue()

def writer():
    try:
        fd = os.open(src, os.O_WRONLY)

        try:
            writer_ready.set()
            start.wait()

            os.lseek(fd, 0, os.SEEK_SET)

            offset = 0

            while offset < len(new_payload):
                written = os.write(
                    fd,
                    new_payload[offset:],
                )

                if written <= 0:
                    raise RuntimeError(
                        "writer made no progress"
                    )

                offset += written

            os.fsync(fd)

        finally:
            os.close(fd)

        queue.put(("writer", "ok"))

    except BaseException as error:
        queue.put(
            ("writer", "error", repr(error))
        )

def renamer():
    try:
        writer_ready.wait()
        start.wait()

        os.rename(src, dst)

        queue.put(("renamer", "ok"))

    except BaseException as error:
        queue.put(
            ("renamer", "error", repr(error))
        )

writer_process = multiprocessing.Process(
    target=writer
)

rename_process = multiprocessing.Process(
    target=renamer
)

writer_process.start()
rename_process.start()

if not writer_ready.wait(10):
    raise RuntimeError(
        "writer failed to open source before race"
    )

start.set()

writer_process.join(30)
rename_process.join(30)

if writer_process.is_alive():
    writer_process.terminate()
    writer_process.join()
    raise RuntimeError("writer race timed out")

if rename_process.is_alive():
    rename_process.terminate()
    rename_process.join()
    raise RuntimeError("rename race timed out")

results = [
    queue.get(timeout=5),
    queue.get(timeout=5),
]

errors = [
    result
    for result in results
    if result[1] != "ok"
]

if errors:
    raise RuntimeError(
        f"write/rename race failure: {errors}"
    )

if os.path.exists(src):
    raise RuntimeError(
        "source remained after successful rename"
    )

if not os.path.isfile(dst):
    raise RuntimeError(
        "renamed destination missing"
    )

with open(dst, "rb") as handle:
    actual = handle.read()

if actual != new_payload:
    raise RuntimeError(
        "write/rename race produced incorrect data"
    )
PY

pass "open-file WRITE and concurrent RENAME preserved correct inode data"

echo
echo "[4/9] Testing root-directory removal rejection..."

python3 - "$MOUNT_DIR" <<'PY'
import errno
import os
import sys

mount = sys.argv[1]

allowed = {
    errno.EBUSY,
    errno.ENOTEMPTY,
    errno.EPERM,
    errno.EACCES,
    errno.EINVAL,
}

try:
    os.rmdir(mount)
except OSError as error:
    if error.errno not in allowed:
        raise RuntimeError(
            f"unexpected root-rmdir errno: "
            f"{error.errno}"
        ) from error
else:
    raise RuntimeError(
        "mounted filesystem root was removed"
    )

if not os.path.ismount(mount):
    raise RuntimeError(
        "filesystem root ceased to be a mountpoint"
    )
PY

pass "filesystem root removal correctly rejected"

echo
echo "[5/9] Testing invalid block mapping detection..."

python3 - \
    "$MOUNT_DIR/$MAP_A" \
    "$MOUNT_DIR/$MAP_B" <<'PY'
import os
import sys

cases = [
    (sys.argv[1], b"MAPPING-A-" * 512),
    (sys.argv[2], b"MAPPING-B-" * 512),
]

for path, payload in cases:
    with open(path, "wb") as handle:
        handle.write(payload)
        handle.flush()
        os.fsync(handle.fileno())
PY

stop_ccfs

MAP_A_INO="$(
    sqlite3 volume/metadata.db \
        "SELECT ino
         FROM entries
         WHERE name='$MAP_A'
         LIMIT 1;"
)"

MAP_B_INO="$(
    sqlite3 volume/metadata.db \
        "SELECT ino
         FROM entries
         WHERE name='$MAP_B'
         LIMIT 1;"
)"

[[ -n "$MAP_A_INO" ]] ||
    fail "unable to resolve mapping A inode"

[[ -n "$MAP_B_INO" ]] ||
    fail "unable to resolve mapping B inode"

cp \
    "volume/blocks/$MAP_A_INO.bin" \
    "/tmp/ccfs-map-a-$RUN_ID.bin"

cp \
    "volume/blocks/$MAP_B_INO.bin" \
    "/tmp/ccfs-map-b-$RUN_ID.bin"

cp \
    "/tmp/ccfs-map-b-$RUN_ID.bin" \
    "volume/blocks/$MAP_A_INO.bin"

cp \
    "/tmp/ccfs-map-a-$RUN_ID.bin" \
    "volume/blocks/$MAP_B_INO.bin"

run_integrity_fail

grep -qi \
    "checksum" \
    "$INTEGRITY_LOG" ||
    fail "invalid block mapping did not produce checksum failure"

cp \
    "/tmp/ccfs-map-a-$RUN_ID.bin" \
    "volume/blocks/$MAP_A_INO.bin"

cp \
    "/tmp/ccfs-map-b-$RUN_ID.bin" \
    "volume/blocks/$MAP_B_INO.bin"

run_integrity_pass

start_ccfs

python3 - \
    "$MOUNT_DIR/$MAP_A" \
    "$MOUNT_DIR/$MAP_B" <<'PY'
import sys

expected = [
    b"MAPPING-A-" * 512,
    b"MAPPING-B-" * 512,
]

for path, wanted in zip(sys.argv[1:], expected):
    with open(path, "rb") as handle:
        actual = handle.read()

    if actual != wanted:
        raise RuntimeError(
            f"restored mapping content mismatch: {path}"
        )
PY

pass "swapped inode-to-block mapping detected and healthy mapping restored"

echo
echo "[6/9] Testing rename + delete race on same file..."

python3 - \
    "$MOUNT_DIR/$RENAME_DELETE_SRC" \
    "$MOUNT_DIR/$RENAME_DELETE_DST" <<'PY'
import errno
import multiprocessing
import os
import sys

src = sys.argv[1]
dst = sys.argv[2]

payload = b"RENAME-DELETE-RACE-DATA"

with open(src, "wb") as handle:
    handle.write(payload)
    handle.flush()
    os.fsync(handle.fileno())

start = multiprocessing.Event()
queue = multiprocessing.Queue()

def rename_worker():
    try:
        start.wait()

        try:
            os.rename(src, dst)
            queue.put(("rename", "success"))
        except OSError as error:
            if error.errno != errno.ENOENT:
                raise

            queue.put(("rename", "enoent"))

    except BaseException as error:
        queue.put(
            ("rename", "error", repr(error))
        )

def delete_worker():
    try:
        start.wait()

        try:
            os.unlink(src)
            queue.put(("delete", "success"))
        except OSError as error:
            if error.errno != errno.ENOENT:
                raise

            queue.put(("delete", "enoent"))

    except BaseException as error:
        queue.put(
            ("delete", "error", repr(error))
        )

processes = [
    multiprocessing.Process(
        target=rename_worker
    ),
    multiprocessing.Process(
        target=delete_worker
    ),
]

for process in processes:
    process.start()

start.set()

for process in processes:
    process.join(30)

    if process.is_alive():
        process.terminate()
        process.join()
        raise RuntimeError(
            "rename/delete race timed out"
        )

results = [
    queue.get(timeout=5),
    queue.get(timeout=5),
]

if any(
    len(result) >= 2 and result[1] == "error"
    for result in results
):
    raise RuntimeError(
        f"rename/delete race error: {results}"
    )

if os.path.exists(src):
    raise RuntimeError(
        "source unexpectedly survived rename/delete race"
    )

if os.path.exists(dst):
    with open(dst, "rb") as handle:
        actual = handle.read()

    if actual != payload:
        raise RuntimeError(
            "renamed survivor contains corrupt data"
        )
PY

pass "rename/delete race ended in one valid namespace state"

echo
echo "[7/9] Testing read while truncate race..."

python3 - \
    "$MOUNT_DIR/$READ_TRUNCATE_FILE" <<'PY'
import multiprocessing
import os
import sys
import time

path = sys.argv[1]

payload = bytes(
    (index % 251 for index in range(4096))
)

with open(path, "wb") as handle:
    handle.write(payload)
    handle.flush()
    os.fsync(handle.fileno())

reader_ready = multiprocessing.Event()
start = multiprocessing.Event()
queue = multiprocessing.Queue()

def reader():
    samples = []

    try:
        fd = os.open(path, os.O_RDONLY)

        try:
            reader_ready.set()
            start.wait()

            for _ in range(30):
                os.lseek(fd, 0, os.SEEK_SET)
                data = os.read(fd, len(payload))

                if data != payload[:len(data)]:
                    raise RuntimeError(
                        "reader observed corrupt/non-prefix data"
                    )

                samples.append(len(data))
                time.sleep(0.001)

        finally:
            os.close(fd)

        queue.put(
            ("reader", "ok", samples)
        )

    except BaseException as error:
        queue.put(
            ("reader", "error", repr(error))
        )

def truncater():
    try:
        reader_ready.wait()
        start.wait()

        time.sleep(0.005)

        os.truncate(path, 0)

        queue.put(("truncate", "ok"))

    except BaseException as error:
        queue.put(
            ("truncate", "error", repr(error))
        )

reader_process = multiprocessing.Process(
    target=reader
)

truncate_process = multiprocessing.Process(
    target=truncater
)

reader_process.start()
truncate_process.start()

if not reader_ready.wait(10):
    raise RuntimeError(
        "reader failed to open file"
    )

start.set()

reader_process.join(30)
truncate_process.join(30)

if reader_process.is_alive():
    reader_process.terminate()
    reader_process.join()
    raise RuntimeError(
        "reader/truncate race timed out"
    )

if truncate_process.is_alive():
    truncate_process.terminate()
    truncate_process.join()
    raise RuntimeError(
        "truncate race timed out"
    )

results = [
    queue.get(timeout=5),
    queue.get(timeout=5),
]

errors = [
    result
    for result in results
    if result[1] != "ok"
]

if errors:
    raise RuntimeError(
        f"read/truncate race failures: {errors}"
    )

if os.stat(path).st_size != 0:
    raise RuntimeError(
        "final truncated file size is not zero"
    )

with open(path, "rb") as handle:
    if handle.read() != b"":
        raise RuntimeError(
            "truncated file contains residual bytes"
        )
PY

pass "concurrent reader saw only valid data while truncate completed safely"

echo
echo "[8/9] Running 2,000+ filesystem-operation stress workload..."

python3 - \
    "$MOUNT_DIR/$STRESS_DIR" \
    "$MOUNT_DIR/$SENTINEL_FILE" <<'PY'
import os
import sys

directory = sys.argv[1]
sentinel = sys.argv[2]

os.mkdir(directory)

operations = 1

iterations = 250

for index in range(iterations):
    src = os.path.join(
        directory,
        f"src-{index:04d}.bin",
    )

    dst = os.path.join(
        directory,
        f"dst-{index:04d}.bin",
    )

    payload = (
        f"CCFS-STRESS-{index:04d}-"
        .encode()
        * 64
    )

    # 1: create
    fd = os.open(
        src,
        os.O_CREAT | os.O_EXCL | os.O_WRONLY,
        0o644,
    )
    operations += 1

    try:
        # 2: write
        offset = 0

        while offset < len(payload):
            written = os.write(
                fd,
                payload[offset:],
            )

            if written <= 0:
                raise RuntimeError(
                    "stress write made no progress"
                )

            offset += written

        operations += 1

        # 3: fsync
        os.fsync(fd)
        operations += 1

    finally:
        os.close(fd)

    # 4: stat
    stat_result = os.stat(src)
    operations += 1

    if stat_result.st_size != len(payload):
        raise RuntimeError(
            f"stress size mismatch at {index}"
        )

    # 5: rename
    os.rename(src, dst)
    operations += 1

    # 6: read
    with open(dst, "rb") as handle:
        actual = handle.read()

    operations += 1

    if actual != payload:
        raise RuntimeError(
            f"stress content mismatch at {index}"
        )

    # 7: stat after rename
    os.stat(dst)
    operations += 1

    # 8: delete
    os.unlink(dst)
    operations += 1

if os.listdir(directory):
    raise RuntimeError(
        "stress directory not empty after workload"
    )

os.rmdir(directory)
operations += 1

if operations < 2000:
    raise RuntimeError(
        f"only {operations} operations executed"
    )

with open(sentinel, "wb") as handle:
    handle.write(
        f"CCFS-STRESS-SENTINEL-{operations}".encode()
    )
    handle.flush()
    os.fsync(handle.fileno())

print(
    f"Filesystem operations completed: {operations}"
)
PY

pass "2,000+ operation stress workload completed successfully"

echo
echo "[9/9] Restarting and performing final integrity/checkpoint verification..."

stop_ccfs
start_ccfs

python3 - \
    "$MOUNT_DIR/$SENTINEL_FILE" <<'PY'
import sys

path = sys.argv[1]

with open(path, "rb") as handle:
    actual = handle.read()

if not actual.startswith(
    b"CCFS-STRESS-SENTINEL-"
):
    raise RuntimeError(
        "post-stress sentinel content invalid"
    )
PY

stop_ccfs

run_integrity_pass
checkpoint_clean
run_integrity_pass

restore_volume

trap - EXIT INT TERM

rm -f "$NORMAL_LOG"
rm -f "$INTEGRITY_LOG"
rm -f "$CHECKPOINT_LOG"

rm -f "/tmp/ccfs-map-a-$RUN_ID.bin"
rm -f "/tmp/ccfs-map-b-$RUN_ID.bin"

echo
echo "========================================"
echo " ALL CCFS REMAINING ACCEPTANCE TESTS PASSED"
echo "========================================"
echo
