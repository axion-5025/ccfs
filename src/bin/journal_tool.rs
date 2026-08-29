#[path = "../journal.rs"]
mod journal;

use std::env;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::process;

fn pass(message: &str) {
    println!("PASS: {message}");
}

fn fail(message: &str) -> ! {
    eprintln!();
    eprintln!("========================================");
    eprintln!("JOURNAL TEST FAILED: {message}");
    eprintln!("========================================");
    process::exit(1);
}

fn write_and_sync(path: &str, data: &[u8]) -> io::Result<()> {
    let mut file = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(path)?;

    file.write_all(data)?;
    file.flush()?;
    file.sync_all()?;

    Ok(())
}

fn show_status() {
    println!("CCFS Journal Status");
    println!("-------------------");
    println!("Path: {}", journal::journal_path());
    println!(
        "Exists: {}",
        if journal::journal_exists() {
            "yes"
        } else {
            "no"
        }
    );

    let transactions = match journal::load_transactions() {
        Ok(transactions) => transactions,

        Err(err) => {
            eprintln!("Unable to read journal: {err}");
            process::exit(1);
        }
    };

    if transactions.is_empty() {
        println!("Transactions: 0");
        return;
    }

    println!("Transactions: {}", transactions.len());
    println!();

    for transaction in transactions {
        println!(
            "txid={} operation={} payload_bytes={} committed={}",
            transaction.txid,
            transaction.operation,
            transaction.payload.len(),
            transaction.committed
        );
    }
}

fn clear_journal() {
    match journal::clear_journal() {
        Ok(()) => {
            println!("Journal cleared.");
            println!("Path: {}", journal::journal_path());
        }

        Err(err) => {
            eprintln!("Failed to clear journal: {err}");
            process::exit(1);
        }
    }
}

fn self_test() {
    println!();
    println!("========================================");
    println!(" CCFS Journal Engine Self-Test");
    println!("========================================");
    println!();

    println!("[1/9] Clearing old journal...");

    journal::clear_journal().unwrap_or_else(|err| fail(&format!("unable to clear journal: {err}")));

    pass("journal cleared");

    println!();
    println!("[2/9] Writing BEGIN record...");

    let committed_txid = journal::begin_transaction("CREATE", b"file=journal-test.txt")
        .unwrap_or_else(|err| fail(&format!("BEGIN write failed: {err}")));

    pass(&format!("BEGIN persisted for transaction {committed_txid}"));

    println!();
    println!("[3/9] Writing COMMIT record...");

    journal::commit_transaction(committed_txid)
        .unwrap_or_else(|err| fail(&format!("COMMIT write failed: {err}")));

    pass("COMMIT persisted");

    println!();
    println!("[4/9] Creating incomplete transaction...");

    let incomplete_txid = journal::begin_transaction("WRITE", b"incomplete-test-data")
        .unwrap_or_else(|err| fail(&format!("incomplete BEGIN write failed: {err}")));

    pass(&format!("incomplete transaction {incomplete_txid} created"));

    println!();
    println!("[5/9] Loading and classifying transactions...");

    let committed = journal::committed_transactions()
        .unwrap_or_else(|err| fail(&format!("unable to load committed transactions: {err}")));

    let incomplete = journal::incomplete_transactions()
        .unwrap_or_else(|err| fail(&format!("unable to load incomplete transactions: {err}")));

    if committed.len() != 1 {
        fail(&format!(
            "expected 1 committed transaction, found {}",
            committed.len()
        ));
    }

    if committed[0].txid != committed_txid {
        fail("wrong committed transaction id");
    }

    if committed[0].operation != "CREATE" {
        fail("committed operation payload decoded incorrectly");
    }

    if committed[0].payload != b"file=journal-test.txt" {
        fail("committed transaction payload corrupted");
    }

    if incomplete.len() != 1 {
        fail(&format!(
            "expected 1 incomplete transaction, found {}",
            incomplete.len()
        ));
    }

    if incomplete[0].txid != incomplete_txid {
        fail("wrong incomplete transaction id");
    }

    if incomplete[0].operation != "WRITE" {
        fail("incomplete operation decoded incorrectly");
    }

    pass("committed and incomplete transactions classified correctly");

    println!();
    println!("[6/9] Verifying journal records...");

    let records = journal::load_records()
        .unwrap_or_else(|err| fail(&format!("unable to load records: {err}")));

    if records.len() != 3 {
        fail(&format!("expected 3 records, found {}", records.len()));
    }

    pass("BEGIN / COMMIT records parsed correctly");

    println!();
    println!("[7/9] Simulating torn final journal write...");

    let journal_path = journal::journal_path();

    let healthy_contents = fs::read(journal_path)
        .unwrap_or_else(|err| fail(&format!("unable to backup journal: {err}")));

    {
        let mut file = OpenOptions::new()
            .append(true)
            .open(journal_path)
            .unwrap_or_else(|err| {
                fail(&format!(
                    "unable to open journal for torn-write test: {err}"
                ))
            });

        file.write_all(b"PARTIAL_RECORD_WITHOUT_NEWLINE")
            .unwrap_or_else(|err| fail(&format!("unable to append partial record: {err}")));

        file.flush()
            .unwrap_or_else(|err| fail(&format!("unable to flush partial record: {err}")));

        file.sync_all()
            .unwrap_or_else(|err| fail(&format!("unable to sync partial record: {err}")));
    }

    let records_after_torn_write = journal::load_records()
        .unwrap_or_else(|err| fail(&format!("torn final record was not handled safely: {err}")));

    if records_after_torn_write.len() != 3 {
        fail("torn final record changed valid record count");
    }

    pass("incomplete final record ignored safely");

    write_and_sync(journal_path, &healthy_contents).unwrap_or_else(|err| {
        fail(&format!(
            "unable to restore journal after torn-write test: {err}"
        ))
    });

    println!();
    println!("[8/9] Testing journal corruption detection...");

    {
        let mut file = OpenOptions::new()
            .append(true)
            .open(journal_path)
            .unwrap_or_else(|err| {
                fail(&format!(
                    "unable to open journal for corruption test: {err}"
                ))
            });

        file.write_all(b"CORRUPTED_RECORD|0000000000000000\n")
            .unwrap_or_else(|err| fail(&format!("unable to write corrupted record: {err}")));

        file.flush()
            .unwrap_or_else(|err| fail(&format!("unable to flush corrupted record: {err}")));

        file.sync_all()
            .unwrap_or_else(|err| fail(&format!("unable to sync corrupted record: {err}")));
    }

    match journal::load_records() {
        Ok(_) => {
            fail("corrupted journal record was accepted");
        }

        Err(_) => {
            pass("corrupted journal record detected");
        }
    }

    write_and_sync(journal_path, &healthy_contents)
        .unwrap_or_else(|err| fail(&format!("unable to restore healthy journal: {err}")));

    println!();
    println!("[9/9] Final journal cleanup...");

    journal::clear_journal()
        .unwrap_or_else(|err| fail(&format!("final journal cleanup failed: {err}")));

    let final_transactions = journal::load_transactions()
        .unwrap_or_else(|err| fail(&format!("unable to verify cleared journal: {err}")));

    if !final_transactions.is_empty() {
        fail("journal still contains transactions after clear");
    }

    pass("journal clean");

    println!();
    println!("========================================");
    println!(" ALL CCFS JOURNAL ENGINE TESTS PASSED");
    println!("========================================");
    println!();
}

fn print_usage() {
    println!("CCFS Journal Tool");
    println!();
    println!("Usage:");
    println!("  cargo run --bin journal_tool -- self-test");
    println!("  cargo run --bin journal_tool -- status");
    println!("  cargo run --bin journal_tool -- clear");
}

fn main() {
    let args: Vec<String> = env::args().collect();

    if args.len() != 2 {
        print_usage();
        process::exit(2);
    }

    match args[1].as_str() {
        "self-test" => self_test(),
        "status" => show_status(),
        "clear" => clear_journal(),

        "--help" | "-h" => {
            print_usage();
        }

        other => {
            eprintln!("Unknown command: {other}");
            eprintln!();
            print_usage();
            process::exit(2);
        }
    }
}
