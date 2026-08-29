use std::io;

use crate::db;
use crate::journal::JournalTransaction;

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct RecoverySummary {
    pub total_transactions: usize,
    pub committed_transactions: usize,
    pub incomplete_transactions: usize,
    pub replayed_transactions: usize,
    pub already_applied_transactions: usize,
}

fn database_error(error: rusqlite::Error) -> io::Error {
    io::Error::new(
        io::ErrorKind::Other,
        format!("recovery database error: {error}"),
    )
}

pub fn transaction_is_applied(txid: u64) -> io::Result<bool> {
    db::is_transaction_applied(txid).map_err(database_error)
}

pub fn mark_transaction_applied(txid: u64) -> io::Result<()> {
    db::mark_transaction_applied(txid).map_err(database_error)
}

fn maybe_recovery_kill9(point: &str) {
    let requested = std::env::var("CCFS_RECOVERY_KILL9_POINT").ok();

    if requested.as_deref() != Some(point) {
        return;
    }

    eprintln!("CCFS recovery SIGKILL failpoint triggered: {}", point);

    let _ = std::process::Command::new("kill")
        .arg("-9")
        .arg(std::process::id().to_string())
        .status();

    std::process::abort();
}

pub fn recover_with<F>(mut replay: F) -> io::Result<RecoverySummary>
where
    F: FnMut(&JournalTransaction) -> io::Result<()>,
{
    /*
     * Make sure the metadata database and applied_tx table exist
     * before recovery starts.
     */
    let _connection = db::init_database().map_err(database_error)?;

    let transactions = crate::journal::load_transactions()?;

    let mut summary = RecoverySummary {
        total_transactions: transactions.len(),
        ..RecoverySummary::default()
    };

    for transaction in transactions {
        /*
         * A BEGIN without COMMIT must never be replayed.
         *
         * This represents an operation that did not reach the
         * durability point before the crash.
         */
        if !transaction.committed {
            summary.incomplete_transactions += 1;
            continue;
        }

        summary.committed_transactions += 1;

        /*
         * applied_tx provides idempotency across repeated restarts.
         *
         * If the transaction was successfully applied during an
         * earlier recovery, do not execute it again.
         */
        if transaction_is_applied(transaction.txid)? {
            summary.already_applied_transactions += 1;
            continue;
        }

        /*
         * Operation-specific replay happens here.
         *
         * The caller decides how CREATE / WRITE / RENAME / DELETE
         * should be restored.
         */
        maybe_recovery_kill9("before_replay");

        replay(&transaction)?;

        /*
         * Only mark the transaction applied after replay succeeds.
         */
        mark_transaction_applied(transaction.txid)?;

        summary.replayed_transactions += 1;
    }

    Ok(summary)
}

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct CheckpointSummary {
    pub original_transactions: usize,
    pub retained_transactions: usize,
    pub removed_applied_transactions: usize,
    pub removed_incomplete_transactions: usize,
}

/*
 * Compact recovery state safely.
 *
 * Keep only committed transactions that have NOT yet been applied.
 *
 * Safe ordering:
 *
 *   1. Inspect journal + applied_tx.
 *   2. Atomically rewrite journal.
 *   3. Clear stale applied_tx records.
 *   4. Checkpoint SQLite WAL.
 *
 * If the process crashes before journal replacement, the old journal
 * remains valid. If it crashes after replacement but before DB cleanup,
 * stale applied_tx rows are harmless.
 */
pub fn checkpoint_recovery_state() -> io::Result<CheckpointSummary> {
    let _connection = db::init_database().map_err(database_error)?;

    let transactions = crate::journal::load_transactions()?;

    let mut summary = CheckpointSummary {
        original_transactions: transactions.len(),
        ..CheckpointSummary::default()
    };

    let mut retained = Vec::new();

    for transaction in transactions {
        if !transaction.committed {
            summary.removed_incomplete_transactions += 1;
            continue;
        }

        if transaction_is_applied(transaction.txid)? {
            summary.removed_applied_transactions += 1;
            continue;
        }

        retained.push(transaction);
    }

    summary.retained_transactions = retained.len();

    /*
     * Journal replacement must succeed before applied_tx cleanup.
     */
    crate::journal::rewrite_transactions(&retained)?;

    db::clear_applied_transactions().map_err(database_error)?;

    db::checkpoint_metadata_database().map_err(database_error)?;

    Ok(summary)
}

pub fn print_checkpoint_summary(summary: &CheckpointSummary) {
    println!("CCFS checkpoint summary");
    println!("-----------------------");
    println!(
        "Original transactions:       {}",
        summary.original_transactions
    );
    println!(
        "Retained unapplied committed: {}",
        summary.retained_transactions
    );
    println!(
        "Removed applied:             {}",
        summary.removed_applied_transactions
    );
    println!(
        "Removed incomplete:          {}",
        summary.removed_incomplete_transactions
    );
}

pub fn inspect_recovery_state() -> io::Result<RecoverySummary> {
    let _connection = db::init_database().map_err(database_error)?;

    let transactions = crate::journal::load_transactions()?;

    let mut summary = RecoverySummary {
        total_transactions: transactions.len(),
        ..RecoverySummary::default()
    };

    for transaction in transactions {
        if !transaction.committed {
            summary.incomplete_transactions += 1;
            continue;
        }

        summary.committed_transactions += 1;

        if transaction_is_applied(transaction.txid)? {
            summary.already_applied_transactions += 1;
        }
    }

    Ok(summary)
}

pub fn applied_transaction_count() -> io::Result<u64> {
    db::applied_transaction_count().map_err(database_error)
}

pub fn clear_recovery_state() -> io::Result<()> {
    db::clear_applied_transactions().map_err(database_error)
}

pub fn print_summary(summary: &RecoverySummary) {
    println!("CCFS recovery summary");
    println!("---------------------");
    println!(
        "Total transactions:          {}",
        summary.total_transactions
    );
    println!(
        "Committed transactions:      {}",
        summary.committed_transactions
    );
    println!(
        "Incomplete transactions:     {}",
        summary.incomplete_transactions
    );
    println!(
        "Replayed transactions:       {}",
        summary.replayed_transactions
    );
    println!(
        "Already applied transactions:{}",
        summary.already_applied_transactions
    );
}
