#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

MOUNT_DIR="mount"

RUN_ID="$(date +%s)"

NORMAL_LOG="/tmp/ccfs-acceptance-edge-normal.log"
INTEGRITY_LOG="/tmp/ccfs-acceptance-edge-integrity.log"
CHECKPOINT_LOG="/tmp/ccfs-acceptance-edge-checkpoint.log"

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
        mktemp -d /tmp/ccfs-acceptance-edge-backup.XXXXXX
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

trap cleanup EXIT INT TERM

echo
echo "========================================"
echo " CCFS ACCEPTANCE EDGE CASE TESTS"
echo "========================================"
echo

# Remove any stale FUSE endpoint before touching mount/.
fusermount3 -u "$MOUNT_DIR" 2>/dev/null || true
fusermount3 -uz "$MOUNT_DIR" 2>/dev/null || true
sleep 0.1

mkdir -p "$MOUNT_DIR"

echo "[1/16] Preserving original volume and building..."

snapshot_volume

cargo build --bin ccfs >/dev/null

rm -rf volume
mkdir -p volume/blocks

start_ccfs
stop_ccfs

pass "clean test volume initialized"

echo
echo "[2/16] Testing 0, 1, 4095, 4096 and 4097-byte files..."

start_ccfs

python3 - "$MOUNT_DIR" "$RUN_ID" <<'PY'
import os
import sys

mount = sys.argv[1]
run_id = sys.argv[2]

sizes = [0, 1, 4095, 4096, 4097]

for size in sizes:
    path = os.path.join(
        mount,
        f"boundary-{size}-{run_id}.bin",
    )

    payload = bytes(
        (index % 251 for index in range(size))
    )

    fd = os.open(
        path,
        os.O_CREAT | os.O_WRONLY | os.O_TRUNC,
        0o644,
    )

    try:
        if payload:
            written = os.write(fd, payload)

            if written != len(payload):
                raise RuntimeError(
                    f"short write for size {size}"
                )

        os.fsync(fd)

    finally:
        os.close(fd)

    with open(path, "rb") as handle:
        actual = handle.read()

    if actual != payload:
        raise RuntimeError(
            f"boundary content mismatch for size {size}"
        )

    if os.stat(path).st_size != size:
        raise RuntimeError(
            f"boundary size mismatch for size {size}"
        )
PY

pass "0/1/4095/4096/4097-byte files handled correctly"

echo
echo "[3/16] Testing write exactly at 4096-byte boundary..."

python3 - "$MOUNT_DIR" "$RUN_ID" <<'PY'
import os
import sys

mount = sys.argv[1]
run_id = sys.argv[2]

path = os.path.join(
    mount,
    f"write-boundary-{run_id}.bin",
)

initial = b"A" * 8192

fd = os.open(
    path,
    os.O_CREAT | os.O_WRONLY | os.O_TRUNC,
    0o644,
)

try:
    os.write(fd, initial)
    os.fsync(fd)
finally:
    os.close(fd)

fd = os.open(path, os.O_WRONLY)

try:
    os.lseek(fd, 4096, os.SEEK_SET)
    os.write(fd, b"XYZ")
    os.fsync(fd)
finally:
    os.close(fd)

with open(path, "rb") as handle:
    actual = handle.read()

expected = (
    b"A" * 4096
    + b"XYZ"
    + b"A" * (8192 - 4099)
)

if actual != expected:
    raise RuntimeError(
        "exact-boundary write corrupted surrounding data"
    )
PY

pass "write at exact block boundary preserved surrounding bytes"

echo
echo "[4/16] Testing write crossing 4096-byte boundary..."

python3 - "$MOUNT_DIR" "$RUN_ID" <<'PY'
import os
import sys

mount = sys.argv[1]
run_id = sys.argv[2]

path = os.path.join(
    mount,
    f"write-crossing-{run_id}.bin",
)

initial = b"B" * 8192

with open(path, "wb") as handle:
    handle.write(initial)
    handle.flush()
    os.fsync(handle.fileno())

fd = os.open(path, os.O_WRONLY)

try:
    os.lseek(fd, 4095, os.SEEK_SET)
    os.write(fd, b"WXYZ")
    os.fsync(fd)
finally:
    os.close(fd)

with open(path, "rb") as handle:
    actual = handle.read()

expected = (
    b"B" * 4095
    + b"WXYZ"
    + b"B" * (8192 - 4099)
)

if actual != expected:
    raise RuntimeError(
        "cross-boundary write corrupted file"
    )
PY

pass "cross-boundary write updated correct byte range"

echo
echo "[5/16] Testing partial write preservation..."

python3 - "$MOUNT_DIR" "$RUN_ID" <<'PY'
import os
import sys

mount = sys.argv[1]
run_id = sys.argv[2]

path = os.path.join(
    mount,
    f"partial-write-{run_id}.bin",
)

initial = (
    b"0123456789" * 1000
)

with open(path, "wb") as handle:
    handle.write(initial)
    handle.flush()
    os.fsync(handle.fileno())

fd = os.open(path, os.O_WRONLY)

try:
    os.lseek(fd, 1234, os.SEEK_SET)
    os.write(fd, b"CCFS")
    os.fsync(fd)
finally:
    os.close(fd)

expected = bytearray(initial)
expected[1234:1238] = b"CCFS"

with open(path, "rb") as handle:
    actual = handle.read()

if actual != bytes(expected):
    raise RuntimeError(
        "partial write changed bytes outside target range"
    )
PY

pass "partial write preserved untouched bytes"

echo
echo "[6/16] Testing write beyond EOF and zero-filled gap..."

python3 - "$MOUNT_DIR" "$RUN_ID" <<'PY'
import os
import sys

mount = sys.argv[1]
run_id = sys.argv[2]

path = os.path.join(
    mount,
    f"beyond-eof-{run_id}.bin",
)

with open(path, "wb") as handle:
    handle.write(b"ABC")
    handle.flush()
    os.fsync(handle.fileno())

fd = os.open(path, os.O_WRONLY)

try:
    os.lseek(fd, 10, os.SEEK_SET)
    os.write(fd, b"Z")
    os.fsync(fd)
finally:
    os.close(fd)

with open(path, "rb") as handle:
    actual = handle.read()

expected = (
    b"ABC"
    + (b"\x00" * 7)
    + b"Z"
)

if actual != expected:
    raise RuntimeError(
        f"write beyond EOF mismatch: {actual!r}"
    )

if os.stat(path).st_size != 11:
    raise RuntimeError(
        "write beyond EOF produced wrong size"
    )
PY

pass "write beyond EOF extended file with zero-filled gap"

echo
echo "[7/16] Testing truncate-to-zero and regrowth..."

python3 - "$MOUNT_DIR" "$RUN_ID" <<'PY'
import os
import sys

mount = sys.argv[1]
run_id = sys.argv[2]

path = os.path.join(
    mount,
    f"truncate-zero-{run_id}.bin",
)

with open(path, "wb") as handle:
    handle.write(b"truncate-me" * 100)
    handle.flush()
    os.fsync(handle.fileno())

os.truncate(path, 0)

if os.stat(path).st_size != 0:
    raise RuntimeError(
        "truncate-to-zero did not produce zero-byte file"
    )

with open(path, "rb") as handle:
    if handle.read() != b"":
        raise RuntimeError(
            "truncate-to-zero file still contains data"
        )

with open(path, "wb") as handle:
    handle.write(b"REGROWN")
    handle.flush()
    os.fsync(handle.fileno())

with open(path, "rb") as handle:
    if handle.read() != b"REGROWN":
        raise RuntimeError(
            "file failed to regrow after truncate"
        )
PY

pass "truncate-to-zero and subsequent regrowth worked"

echo
echo "[8/16] Testing create-existing and missing-file errors..."

python3 - "$MOUNT_DIR" "$RUN_ID" <<'PY'
import errno
import os
import sys

mount = sys.argv[1]
run_id = sys.argv[2]

existing = os.path.join(
    mount,
    f"existing-{run_id}.txt",
)

with open(existing, "wb") as handle:
    handle.write(b"exists")
    handle.flush()
    os.fsync(handle.fileno())

try:
    fd = os.open(
        existing,
        os.O_CREAT | os.O_EXCL | os.O_WRONLY,
        0o644,
    )
except OSError as error:
    if error.errno != errno.EEXIST:
        raise
else:
    os.close(fd)
    raise RuntimeError(
        "O_EXCL create unexpectedly replaced existing file"
    )

missing = os.path.join(
    mount,
    f"missing-{run_id}.txt",
)

try:
    open(missing, "rb")
except FileNotFoundError:
    pass
else:
    raise RuntimeError(
        "read missing file unexpectedly succeeded"
    )

try:
    os.unlink(missing)
except FileNotFoundError:
    pass
else:
    raise RuntimeError(
        "delete missing file unexpectedly succeeded"
    )
PY

pass "existing/missing file error semantics correct"

echo
echo "[9/16] Testing rename-to-same-name and replacement..."

python3 - "$MOUNT_DIR" "$RUN_ID" <<'PY'
import os
import sys

mount = sys.argv[1]
run_id = sys.argv[2]

same = os.path.join(
    mount,
    f"rename-same-{run_id}.txt",
)

with open(same, "wb") as handle:
    handle.write(b"SAME")
    handle.flush()
    os.fsync(handle.fileno())

os.rename(same, same)

with open(same, "rb") as handle:
    if handle.read() != b"SAME":
        raise RuntimeError(
            "rename-to-same-name changed file"
        )

src = os.path.join(
    mount,
    f"rename-src-{run_id}.txt",
)

dst = os.path.join(
    mount,
    f"rename-dst-{run_id}.txt",
)

with open(src, "wb") as handle:
    handle.write(b"SOURCE")
    handle.flush()
    os.fsync(handle.fileno())

with open(dst, "wb") as handle:
    handle.write(b"DESTINATION")
    handle.flush()
    os.fsync(handle.fileno())

os.rename(src, dst)

if os.path.exists(src):
    raise RuntimeError(
        "rename replacement left source name behind"
    )

with open(dst, "rb") as handle:
    if handle.read() != b"SOURCE":
        raise RuntimeError(
            "rename replacement did not install source content"
        )
PY

pass "same-name and replace-existing rename semantics correct"

echo
echo "[10/16] Testing non-empty directory rejection..."

python3 - "$MOUNT_DIR" "$RUN_ID" <<'PY'
import errno
import os
import sys

mount = sys.argv[1]
run_id = sys.argv[2]

directory = os.path.join(
    mount,
    f"nonempty-{run_id}",
)

os.mkdir(directory)

child = os.path.join(
    directory,
    "child.txt",
)

with open(child, "wb") as handle:
    handle.write(b"child")
    handle.flush()
    os.fsync(handle.fileno())

try:
    os.rmdir(directory)
except OSError as error:
    if error.errno not in (
        errno.ENOTEMPTY,
        errno.EEXIST,
    ):
        raise
else:
    raise RuntimeError(
        "non-empty directory removal unexpectedly succeeded"
    )

os.unlink(child)
os.rmdir(directory)
PY

pass "non-empty directory removal correctly rejected"

echo
echo "[11/16] Testing deep nested directories..."

python3 - "$MOUNT_DIR" "$RUN_ID" <<'PY'
import os
import sys

mount = sys.argv[1]
run_id = sys.argv[2]

current = mount

for depth in range(1, 31):
    current = os.path.join(
        current,
        f"d{depth}-{run_id}",
    )

    os.mkdir(current)

leaf = os.path.join(
    current,
    "leaf.txt",
)

with open(leaf, "wb") as handle:
    handle.write(b"DEEP")
    handle.flush()
    os.fsync(handle.fileno())

with open(leaf, "rb") as handle:
    if handle.read() != b"DEEP":
        raise RuntimeError(
            "deep nested file read mismatch"
        )
PY

pass "30-level nested directory path worked"

echo
echo "[12/16] Testing many files in one directory..."

python3 - "$MOUNT_DIR" "$RUN_ID" <<'PY'
import os
import sys

mount = sys.argv[1]
run_id = sys.argv[2]

directory = os.path.join(
    mount,
    f"many-files-{run_id}",
)

os.mkdir(directory)

count = 200

for index in range(count):
    path = os.path.join(
        directory,
        f"file-{index:04d}.txt",
    )

    with open(path, "wb") as handle:
        payload = f"file-{index}".encode()
        handle.write(payload)

names = os.listdir(directory)

if len(names) != count:
    raise RuntimeError(
        f"expected {count} files, got {len(names)}"
    )

for index in (0, 50, 100, 150, 199):
    path = os.path.join(
        directory,
        f"file-{index:04d}.txt",
    )

    with open(path, "rb") as handle:
        expected = f"file-{index}".encode()

        if handle.read() != expected:
            raise RuntimeError(
                f"many-files content mismatch at {index}"
            )
PY

pass "200 files in one directory listed and read correctly"

echo
echo "[13/16] Testing filename length boundary..."

python3 - "$MOUNT_DIR" <<'PY'
import errno
import os
import sys

mount = sys.argv[1]

valid_name = "v" * 255
valid_path = os.path.join(
    mount,
    valid_name,
)

with open(valid_path, "wb") as handle:
    handle.write(b"LONGNAME")

with open(valid_path, "rb") as handle:
    if handle.read() != b"LONGNAME":
        raise RuntimeError(
            "255-byte filename read mismatch"
        )

invalid_name = "x" * 256
invalid_path = os.path.join(
    mount,
    invalid_name,
)

try:
    with open(invalid_path, "wb") as handle:
        handle.write(b"SHOULD-NOT-WORK")
except OSError as error:
    if error.errno != errno.ENAMETOOLONG:
        raise
else:
    raise RuntimeError(
        "256-byte filename unexpectedly succeeded"
    )
PY

pass "255-byte filename accepted and 256-byte filename rejected"

echo
echo "[14/16] Testing two-process same-file create race..."

python3 - "$MOUNT_DIR" "$RUN_ID" <<'PY'
import multiprocessing
import os
import sys

mount = sys.argv[1]
run_id = sys.argv[2]

path = os.path.join(
    mount,
    f"create-race-{run_id}.txt",
)

def worker(queue):
    try:
        fd = os.open(
            path,
            os.O_CREAT | os.O_EXCL | os.O_WRONLY,
            0o644,
        )

        try:
            os.write(fd, b"winner")
            os.fsync(fd)
        finally:
            os.close(fd)

        queue.put("created")

    except FileExistsError:
        queue.put("exists")

queue = multiprocessing.Queue()

processes = [
    multiprocessing.Process(
        target=worker,
        args=(queue,),
    )
    for _ in range(2)
]

for process in processes:
    process.start()

for process in processes:
    process.join()

results = sorted(
    queue.get()
    for _ in range(2)
)

if results != ["created", "exists"]:
    raise RuntimeError(
        f"unexpected create-race results: {results}"
    )

with open(path, "rb") as handle:
    if handle.read() != b"winner":
        raise RuntimeError(
            "race winner file content corrupted"
        )
PY

pass "same-file concurrent create race produced one winner"

echo
echo "[15/16] Testing 1 MiB file and restart persistence..."

python3 - "$MOUNT_DIR" "$RUN_ID" <<'PY'
import hashlib
import os
import sys

mount = sys.argv[1]
run_id = sys.argv[2]

path = os.path.join(
    mount,
    f"large-1mib-{run_id}.bin",
)

size = 1024 * 1024

payload = bytes(
    (index % 251 for index in range(size))
)

expected_hash = hashlib.sha256(payload).hexdigest()

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
            payload[offset:offset + 65536],
        )

        if written <= 0:
            raise RuntimeError(
                "large-file write made no progress"
            )

        offset += written

    os.fsync(fd)

finally:
    os.close(fd)

with open(path, "rb") as handle:
    actual_hash = hashlib.sha256(
        handle.read()
    ).hexdigest()

if actual_hash != expected_hash:
    raise RuntimeError(
        "large-file hash mismatch before restart"
    )

with open(
    "/tmp/ccfs-large-expected-hash",
    "w",
) as handle:
    handle.write(expected_hash)
PY

stop_ccfs
start_ccfs

python3 - "$MOUNT_DIR" "$RUN_ID" <<'PY'
import hashlib
import os
import sys

mount = sys.argv[1]
run_id = sys.argv[2]

path = os.path.join(
    mount,
    f"large-1mib-{run_id}.bin",
)

with open(
    "/tmp/ccfs-large-expected-hash",
    "r",
) as handle:
    expected_hash = handle.read().strip()

with open(path, "rb") as handle:
    actual_hash = hashlib.sha256(
        handle.read()
    ).hexdigest()

if actual_hash != expected_hash:
    raise RuntimeError(
        "large-file hash mismatch after restart"
    )

if os.stat(path).st_size != 1024 * 1024:
    raise RuntimeError(
        "large-file size mismatch after restart"
    )
PY

rm -f /tmp/ccfs-large-expected-hash

pass "1 MiB file survived restart without data loss"

echo
echo "[16/16] Final checkpoint, integrity and restoration..."

stop_ccfs

run_integrity_check

./target/debug/ccfs \
    --checkpoint \
    >"$CHECKPOINT_LOG" 2>&1 ||
{
    cat "$CHECKPOINT_LOG"
    fail "final checkpoint failed"
}

RECOVERY_STATUS="$(
    ./target/debug/ccfs \
        --recovery-status
)"

grep -q \
    "Total transactions:          0" \
    <<<"$RECOVERY_STATUS" ||
    fail "journal not empty after final checkpoint"

run_integrity_check

restore_volume

trap - EXIT INT TERM

rm -f "$NORMAL_LOG"
rm -f "$INTEGRITY_LOG"
rm -f "$CHECKPOINT_LOG"
rm -f /tmp/ccfs-large-expected-hash

echo
echo "========================================"
echo " ALL CCFS ACCEPTANCE EDGE TESTS PASSED"
echo "========================================"
echo
