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
        replay(&transaction)?;

        /*
         * Only mark the transaction applied after replay succeeds.
         */
        mark_transaction_applied(transaction.txid)?;

        summary.replayed_transactions += 1;
    }

    Ok(summary)
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
