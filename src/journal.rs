use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

const JOURNAL_PATH: &str = "volume/journal.log";

static TX_COUNTER: AtomicU64 = AtomicU64::new(1);

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum JournalRecord {
    Begin {
        txid: u64,
        operation: String,
        payload: Vec<u8>,
    },
    Commit {
        txid: u64,
    },
}

#[derive(Debug, Clone)]
pub struct JournalTransaction {
    pub txid: u64,
    pub operation: String,
    pub payload: Vec<u8>,
    pub committed: bool,
}

fn checksum(data: &[u8]) -> u64 {
    const OFFSET_BASIS: u64 = 0xcbf29ce484222325;
    const FNV_PRIME: u64 = 0x100000001b3;

    let mut hash = OFFSET_BASIS;

    for byte in data {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(FNV_PRIME);
    }

    hash
}

fn hex_encode(data: &[u8]) -> String {
    let mut output = String::with_capacity(data.len() * 2);

    for byte in data {
        output.push_str(&format!("{byte:02x}"));
    }

    output
}

fn hex_decode(value: &str) -> io::Result<Vec<u8>> {
    if value.len() % 2 != 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "hex payload has odd length",
        ));
    }

    let mut output = Vec::with_capacity(value.len() / 2);

    for index in (0..value.len()).step_by(2) {
        let pair = &value[index..index + 2];

        let byte = u8::from_str_radix(pair, 16).map_err(|_| {
            io::Error::new(io::ErrorKind::InvalidData, "journal contains invalid hex")
        })?;

        output.push(byte);
    }

    Ok(output)
}

fn next_txid() -> u64 {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos() as u64;

    nanos.wrapping_add(TX_COUNTER.fetch_add(1, Ordering::Relaxed))
}

fn ensure_journal_parent() -> io::Result<()> {
    if let Some(parent) = Path::new(JOURNAL_PATH).parent() {
        fs::create_dir_all(parent)?;
    }

    Ok(())
}

fn maybe_enospc(point: &str) -> io::Result<()> {
    let requested = std::env::var("CCFS_ENOSPC_POINT").ok();

    if requested.as_deref() != Some(point) {
        return Ok(());
    }

    eprintln!("CCFS ENOSPC failpoint triggered: {}", point);

    Err(io::Error::from_raw_os_error(28))
}

fn append_record(record_without_checksum: &str) -> io::Result<()> {
    ensure_journal_parent()?;

    let record_checksum = checksum(record_without_checksum.as_bytes());

    let complete_record = format!("{record_without_checksum}|{record_checksum:016x}\n");

    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(JOURNAL_PATH)?;

    maybe_enospc("journal_write")?;

    file.write_all(complete_record.as_bytes())?;
    file.flush()?;

    /*
     * Make the journal record durable before returning.
     */
    file.sync_all()?;

    Ok(())
}

pub fn begin_transaction(operation: &str, payload: &[u8]) -> io::Result<u64> {
    let txid = next_txid();

    let operation_hex = hex_encode(operation.as_bytes());
    let payload_hex = hex_encode(payload);

    let record = format!("BEGIN|{txid}|{operation_hex}|{payload_hex}");

    append_record(&record)?;

    Ok(txid)
}

pub fn commit_transaction(txid: u64) -> io::Result<()> {
    let record = format!("COMMIT|{txid}");

    append_record(&record)
}

fn parse_record(line: &str) -> io::Result<JournalRecord> {
    let Some((body, stored_checksum)) = line.rsplit_once('|') else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "journal record has no checksum",
        ));
    };

    let expected_checksum = u64::from_str_radix(stored_checksum, 16).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "journal checksum is not valid hex",
        )
    })?;

    let actual_checksum = checksum(body.as_bytes());

    if expected_checksum != actual_checksum {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "journal checksum mismatch: expected \
                 {expected_checksum:016x}, actual {actual_checksum:016x}"
            ),
        ));
    }

    let parts: Vec<&str> = body.split('|').collect();

    match parts.as_slice() {
        ["BEGIN", txid, operation_hex, payload_hex] => {
            let txid = txid.parse::<u64>().map_err(|_| {
                io::Error::new(io::ErrorKind::InvalidData, "invalid BEGIN transaction id")
            })?;

            let operation_bytes = hex_decode(operation_hex)?;

            let operation = String::from_utf8(operation_bytes).map_err(|_| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    "journal operation is not valid UTF-8",
                )
            })?;

            let payload = hex_decode(payload_hex)?;

            Ok(JournalRecord::Begin {
                txid,
                operation,
                payload,
            })
        }

        ["COMMIT", txid] => {
            let txid = txid.parse::<u64>().map_err(|_| {
                io::Error::new(io::ErrorKind::InvalidData, "invalid COMMIT transaction id")
            })?;

            Ok(JournalRecord::Commit { txid })
        }

        _ => Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "unknown journal record format",
        )),
    }
}

pub fn load_records() -> io::Result<Vec<JournalRecord>> {
    if !Path::new(JOURNAL_PATH).exists() {
        return Ok(Vec::new());
    }

    let mut file = File::open(JOURNAL_PATH)?;

    let mut contents = String::new();
    file.read_to_string(&mut contents)?;

    /*
     * Crash during the final journal write can leave an incomplete
     * record without a newline.
     *
     * Ignore only that final incomplete fragment.
     */
    let complete_contents = if contents.ends_with('\n') {
        contents.as_str()
    } else {
        match contents.rfind('\n') {
            Some(last_newline) => &contents[..=last_newline],
            None => "",
        }
    };

    let mut records = Vec::new();

    for line in complete_contents.lines() {
        if line.trim().is_empty() {
            continue;
        }

        records.push(parse_record(line)?);
    }

    Ok(records)
}

pub fn load_transactions() -> io::Result<Vec<JournalTransaction>> {
    let records = load_records()?;

    let mut transactions: BTreeMap<u64, JournalTransaction> = BTreeMap::new();

    for record in records {
        match record {
            JournalRecord::Begin {
                txid,
                operation,
                payload,
            } => {
                transactions.insert(
                    txid,
                    JournalTransaction {
                        txid,
                        operation,
                        payload,
                        committed: false,
                    },
                );
            }

            JournalRecord::Commit { txid } => {
                if let Some(transaction) = transactions.get_mut(&txid) {
                    transaction.committed = true;
                }
            }
        }
    }

    Ok(transactions.into_values().collect())
}

pub fn committed_transactions() -> io::Result<Vec<JournalTransaction>> {
    Ok(load_transactions()?
        .into_iter()
        .filter(|transaction| transaction.committed)
        .collect())
}

pub fn incomplete_transactions() -> io::Result<Vec<JournalTransaction>> {
    Ok(load_transactions()?
        .into_iter()
        .filter(|transaction| !transaction.committed)
        .collect())
}

pub fn journal_exists() -> bool {
    Path::new(JOURNAL_PATH).exists()
}

pub fn journal_path() -> &'static str {
    JOURNAL_PATH
}

/*
 * Atomically rewrite the journal with only the transactions
 * the caller wants to preserve.
 *
 * Durability sequence:
 *
 *   1. Write a temporary journal in the same directory.
 *   2. flush + fsync the temporary file.
 *   3. Atomically rename it over journal.log.
 *   4. fsync the parent directory so the rename itself is durable.
 *
 * If CCFS crashes before the rename, the old journal remains valid.
 * If it crashes after the rename, the new journal is already durable.
 */
pub fn rewrite_transactions(transactions: &[JournalTransaction]) -> io::Result<()> {
    ensure_journal_parent()?;

    let journal_path = Path::new(JOURNAL_PATH);

    let parent = journal_path.parent().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "journal path has no parent directory",
        )
    })?;

    let temp_path = parent.join(".journal.log.checkpoint.tmp");

    let mut file = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(&temp_path)?;

    for transaction in transactions {
        let operation_hex = hex_encode(transaction.operation.as_bytes());
        let payload_hex = hex_encode(&transaction.payload);

        let begin_body = format!(
            "BEGIN|{}|{}|{}",
            transaction.txid, operation_hex, payload_hex
        );

        let begin_checksum = checksum(begin_body.as_bytes());

        writeln!(file, "{}|{:016x}", begin_body, begin_checksum)?;

        if transaction.committed {
            let commit_body = format!("COMMIT|{}", transaction.txid);

            let commit_checksum = checksum(commit_body.as_bytes());

            writeln!(file, "{}|{:016x}", commit_body, commit_checksum)?;
        }
    }

    file.flush()?;
    file.sync_all()?;

    fs::rename(&temp_path, journal_path)?;

    /*
     * Persist the directory entry replacement itself.
     */
    let directory = File::open(parent)?;

    directory.sync_all()?;

    Ok(())
}

pub fn clear_journal() -> io::Result<()> {
    ensure_journal_parent()?;

    let file = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(JOURNAL_PATH)?;

    file.sync_all()?;

    Ok(())
}
