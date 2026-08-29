#[path = "../db.rs"]
mod db;

#[path = "../journal.rs"]
mod journal;

#[path = "../recovery.rs"]
mod recovery;

use std::process;

fn pass(message: &str) {
    println!("PASS: {message}");
}

fn fail(message: &str) -> ! {
    eprintln!();
    eprintln!("========================================");
    eprintln!("RECOVERY TEST FAILED: {message}");
    eprintln!("========================================");
    process::exit(1);
}

fn main() {
    println!();
    println!("========================================");
    println!(" CCFS Recovery Engine Self-Test");
    println!("========================================");
    println!();

    println!("[1/9] Initializing clean recovery state...");

    db::init_database().unwrap_or_else(|err| fail(&format!("database init failed: {err}")));

    journal::clear_journal().unwrap_or_else(|err| fail(&format!("journal clear failed: {err}")));

    recovery::clear_recovery_state()
        .unwrap_or_else(|err| fail(&format!("recovery state clear failed: {err}")));

    pass("journal and applied_tx cleared");

    println!();
    println!("[2/9] Creating committed transaction...");

    let committed_txid = journal::begin_transaction("CREATE", b"recovery-file.txt")
        .unwrap_or_else(|err| fail(&format!("BEGIN failed: {err}")));

    journal::commit_transaction(committed_txid)
        .unwrap_or_else(|err| fail(&format!("COMMIT failed: {err}")));

    pass(&format!("committed transaction created: {committed_txid}"));

    println!();
    println!("[3/9] Creating incomplete transaction...");

    let incomplete_txid = journal::begin_transaction("WRITE", b"incomplete-data")
        .unwrap_or_else(|err| fail(&format!("incomplete BEGIN failed: {err}")));

    pass(&format!(
        "incomplete transaction created: {incomplete_txid}"
    ));

    println!();
    println!("[4/9] Inspecting recovery classification...");

    let summary = recovery::inspect_recovery_state()
        .unwrap_or_else(|err| fail(&format!("recovery inspection failed: {err}")));

    if summary.total_transactions != 2 {
        fail(&format!(
            "expected 2 transactions, got {}",
            summary.total_transactions
        ));
    }

    if summary.committed_transactions != 1 {
        fail(&format!(
            "expected 1 committed transaction, got {}",
            summary.committed_transactions
        ));
    }

    if summary.incomplete_transactions != 1 {
        fail(&format!(
            "expected 1 incomplete transaction, got {}",
            summary.incomplete_transactions
        ));
    }

    pass("committed and incomplete transactions classified correctly");

    println!();
    println!("[5/9] Running first recovery...");

    let mut replayed = Vec::new();

    let first_summary = recovery::recover_with(|transaction| {
        if transaction.operation != "CREATE" {
            fail(&format!(
                "unexpected operation replayed: {}",
                transaction.operation
            ));
        }

        if transaction.payload != b"recovery-file.txt" {
            fail("committed transaction payload corrupted");
        }

        replayed.push(transaction.txid);

        Ok(())
    })
    .unwrap_or_else(|err| fail(&format!("first recovery failed: {err}")));

    if replayed != vec![committed_txid] {
        fail("first recovery replayed wrong transaction set");
    }

    if first_summary.replayed_transactions != 1 {
        fail("first recovery did not replay exactly one transaction");
    }

    if first_summary.incomplete_transactions != 1 {
        fail("incomplete transaction was not ignored");
    }

    pass("committed transaction replayed; incomplete transaction ignored");

    println!();
    println!("[6/9] Verifying applied_tx bookkeeping...");

    let applied = recovery::transaction_is_applied(committed_txid)
        .unwrap_or_else(|err| fail(&format!("applied_tx lookup failed: {err}")));

    if !applied {
        fail("committed transaction was not marked applied");
    }

    let incomplete_applied = recovery::transaction_is_applied(incomplete_txid)
        .unwrap_or_else(|err| fail(&format!("incomplete tx lookup failed: {err}")));

    if incomplete_applied {
        fail("incomplete transaction was incorrectly marked applied");
    }

    let count = recovery::applied_transaction_count()
        .unwrap_or_else(|err| fail(&format!("applied_tx count failed: {err}")));

    if count != 1 {
        fail(&format!("expected applied_tx count 1, got {count}"));
    }

    pass("applied_tx contains only successfully replayed transaction");

    println!();
    println!("[7/9] Testing idempotent second recovery...");

    let mut second_replay_count = 0usize;

    let second_summary = recovery::recover_with(|_| {
        second_replay_count += 1;
        Ok(())
    })
    .unwrap_or_else(|err| fail(&format!("second recovery failed: {err}")));

    if second_replay_count != 0 {
        fail("already-applied transaction was replayed again");
    }

    if second_summary.replayed_transactions != 0 {
        fail("second recovery reported an unexpected replay");
    }

    if second_summary.already_applied_transactions != 1 {
        fail("second recovery did not identify already-applied transaction");
    }

    pass("repeated recovery is idempotent");

    println!();
    println!("[8/9] Committing previously incomplete transaction...");

    journal::commit_transaction(incomplete_txid)
        .unwrap_or_else(|err| fail(&format!("late COMMIT failed: {err}")));

    let mut late_replays = Vec::new();

    let third_summary = recovery::recover_with(|transaction| {
        late_replays.push(transaction.txid);
        Ok(())
    })
    .unwrap_or_else(|err| fail(&format!("third recovery failed: {err}")));

    if late_replays != vec![incomplete_txid] {
        fail("newly committed transaction was not replayed exactly once");
    }

    if third_summary.replayed_transactions != 1 {
        fail("third recovery replay count incorrect");
    }

    if third_summary.already_applied_transactions != 1 {
        fail("previously applied transaction was not skipped");
    }

    let final_count = recovery::applied_transaction_count()
        .unwrap_or_else(|err| fail(&format!("final applied count failed: {err}")));

    if final_count != 2 {
        fail(&format!(
            "expected 2 applied transactions, got {final_count}"
        ));
    }

    pass("newly committed transaction recovered without duplicate replay");

    println!();
    println!("[9/9] Final cleanup...");

    journal::clear_journal()
        .unwrap_or_else(|err| fail(&format!("final journal clear failed: {err}")));

    recovery::clear_recovery_state()
        .unwrap_or_else(|err| fail(&format!("final recovery clear failed: {err}")));

    let final_state = recovery::inspect_recovery_state()
        .unwrap_or_else(|err| fail(&format!("final state inspection failed: {err}")));

    if final_state.total_transactions != 0 {
        fail("journal still contains transactions after cleanup");
    }

    let applied_after_cleanup = recovery::applied_transaction_count()
        .unwrap_or_else(|err| fail(&format!("post-cleanup applied count failed: {err}")));

    if applied_after_cleanup != 0 {
        fail("applied_tx was not cleared");
    }

    pass("recovery test state cleaned successfully");

    println!();
    println!("========================================");
    println!(" ALL CCFS RECOVERY ENGINE TESTS PASSED");
    println!("========================================");
    println!();
}
