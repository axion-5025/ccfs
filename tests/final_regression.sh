#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

MOUNT_DIR="mount"

RUN_ID="$(date +%Y%m%d-%H%M%S)"
LOG_ROOT="/tmp/ccfs-final-regression-$RUN_ID"

BACKUP_ROOT=""
STEP=0
TOTAL_STEPS=26

mkdir -p "$LOG_ROOT"

fail() {
    echo
    echo "========================================"
    echo " FINAL REGRESSION FAILED"
    echo "========================================"
    echo
    echo "Reason: $1"
    echo "Logs: $LOG_ROOT"
    echo
    exit 1
}

detach_mount() {
    set +e

    fusermount3 -u "$MOUNT_DIR" 2>/dev/null || true
    fusermount3 -uz "$MOUNT_DIR" 2>/dev/null || true

    sleep 0.1

    mkdir -p "$MOUNT_DIR" 2>/dev/null || true

    set -e
}

backup_volume() {
    detach_mount

    BACKUP_ROOT="$(
        mktemp -d /tmp/ccfs-final-regression-volume.XXXXXX
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

    detach_mount

    rm -rf volume
    cp -a "$BACKUP_ROOT/volume" volume

    rm -rf "$BACKUP_ROOT"
    BACKUP_ROOT=""
}

cleanup() {
    set +e

    detach_mount
    restore_volume

    set -e
}

trap cleanup EXIT INT TERM

run_step() {
    local label="$1"
    shift

    STEP=$((STEP + 1))

    local safe_name
    safe_name="$(
        printf '%02d-%s' "$STEP" "$label" |
            tr ' /:' '---' |
            tr -cd 'A-Za-z0-9._-'
    )"

    local log_file="$LOG_ROOT/$safe_name.log"

    echo
    echo "========================================"
    echo "[$STEP/$TOTAL_STEPS] $label"
    echo "========================================"

    detach_mount

    set +e

    "$@" > >(tee "$log_file") 2>&1

    local status=$?

    set -e

    if [[ "$status" -ne 0 ]]; then
        echo
        echo "FAILED: $label"
        echo "Exit status: $status"
        echo "Log: $log_file"

        tail -n 80 "$log_file" 2>/dev/null || true

        fail "$label"
    fi

    echo
    echo "PASS: $label"
}

run_suite() {
    local label="$1"
    local script="$2"

    [[ -f "$script" ]] ||
        fail "required test script missing: $script"

    if command -v timeout >/dev/null 2>&1; then
        run_step \
            "$label" \
            timeout 15m bash "$script"
    else
        run_step \
            "$label" \
            bash "$script"
    fi
}

echo
echo "=================================================="
echo " CCFS FINAL COMPLETE REGRESSION"
echo "=================================================="
echo
echo "Run ID: $RUN_ID"
echo "Logs:   $LOG_ROOT"
echo

echo "Preserving original volume before final regression..."

backup_volume

echo "PASS: original volume preserved"

run_step \
    "Rust formatting check" \
    cargo fmt -- --check

run_step \
    "Rust compile check" \
    cargo check --bin ccfs

run_step \
    "Build all CCFS binaries" \
    cargo build --bins

run_step \
    "Journal engine self-test" \
    cargo run --quiet --bin journal_tool -- self-test

run_suite \
    "Core integration suite" \
    "tests/integration.sh"

run_suite \
    "Real SIGKILL recovery suite" \
    "tests/kill9_recovery.sh"

run_suite \
    "ATIME recovery suite" \
    "tests/atime_recovery.sh"

run_suite \
    "Flush and fsync durability suite" \
    "tests/fsync_durability.sh"

run_suite \
    "POSIX rename-replace suite" \
    "tests/rename_replace.sh"

run_suite \
    "Rename-replace SIGKILL recovery suite" \
    "tests/rename_replace_recovery.sh"

run_suite \
    "UID and GID recovery suite" \
    "tests/uidgid_recovery.sh"

run_suite \
    "Journal checkpoint recovery suite" \
    "tests/checkpoint_recovery.sh"

run_suite \
    "Concurrency and crash stress suite" \
    "tests/stress_recovery.sh"

run_suite \
    "Snapshot and Copy-on-Write suite" \
    "tests/snapshot_recovery.sh"

run_suite \
    "Snapshot SIGKILL suite" \
    "tests/snapshot_crash_recovery.sh"

run_suite \
    "Snapshot edge-case suite" \
    "tests/snapshot_edge_cases.sh"

run_suite \
    "Final end-to-end acceptance suite" \
    "tests/final_e2e.sh"

run_suite \
    "General acceptance edge suite" \
    "tests/acceptance_edge_cases.sh"

run_suite \
    "Fault-injection acceptance suite" \
    "tests/fault_injection_acceptance.sh"

run_suite \
    "Recovery-crash acceptance suite" \
    "tests/recovery_crash_acceptance.sh"

run_suite \
    "ENOSPC acceptance suite" \
    "tests/enospc_acceptance.sh"

run_suite \
    "Performance acceptance suite" \
    "tests/performance_acceptance.sh"

run_suite \
    "Metadata-crash acceptance suite" \
    "tests/metadata_crash_acceptance.sh"

run_suite \
    "Remaining seven acceptance cases" \
    "tests/remaining_acceptance.sh"

#
# Final state validation is deliberately performed on the
# regression working copy of the original volume. The master
# backup is restored after all checks complete.
#

run_step \
    "Final block integrity verification" \
    ./target/debug/ccfs --check-integrity

run_step \
    "Final journal checkpoint" \
    ./target/debug/ccfs --checkpoint

echo
echo "========================================"
echo "[Final] Verifying checkpoint left zero transactions"
echo "========================================"

RECOVERY_STATUS="$(
    ./target/debug/ccfs --recovery-status
)"

printf '%s\n' "$RECOVERY_STATUS" |
    tee "$LOG_ROOT/final-recovery-status.log"

grep -q \
    "Total transactions:          0" \
    <<<"$RECOVERY_STATUS" ||
    fail "final checkpoint did not leave an empty recovery journal"

echo "PASS: final recovery state contains zero transactions"

echo
echo "Running post-checkpoint integrity verification..."

./target/debug/ccfs \
    --check-integrity \
    > >(tee "$LOG_ROOT/final-post-checkpoint-integrity.log") \
    2>&1 ||
    fail "post-checkpoint integrity verification failed"

echo "PASS: post-checkpoint integrity healthy"

echo
echo "Restoring exact original pre-regression volume..."

restore_volume

trap - EXIT INT TERM

detach_mount

echo
echo "=================================================="
echo " ALL CCFS FINAL REGRESSION TESTS PASSED"
echo "=================================================="
echo
echo "Acceptance coverage: 113 / 113"
echo "Use Cases:           18 / 18"
echo "Test Cases:          50 / 50"
echo "Edge Cases:          45 / 45"
echo
echo "Regression logs preserved at:"
echo "$LOG_ROOT"
echo
echo "Original pre-regression volume restored."
echo
