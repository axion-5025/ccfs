mod db;
mod journal;
mod recovery;
mod snapshot;
mod storage;

use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::ffi::OsStr;
use std::fs;
use std::io::{self, ErrorKind};
use std::os::unix::ffi::OsStrExt;
use std::process;
use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use fuser::{
    BsdFileFlags, Config, Errno, FileAttr, FileHandle, FileType, Filesystem, FopenFlags,
    Generation, INodeNo, LockOwner, MountOption, OpenFlags, RenameFlags, ReplyAttr, ReplyCreate,
    ReplyData, ReplyDirectory, ReplyEmpty, ReplyEntry, ReplyWrite, Request, TimeOrNow, WriteFlags,
};

use storage::IntegrityStatus;

const TTL: Duration = Duration::from_secs(1);
const NAME_MAX: usize = 255;

const CREATE_PAYLOAD_MAGIC: &[u8; 8] = b"CCFSCRT1";
const MKDIR_PAYLOAD_MAGIC: &[u8; 8] = b"CCFSMKD1";
const WRITE_PAYLOAD_MAGIC: &[u8; 8] = b"CCFSWRT1";
const RENAME_PAYLOAD_MAGIC_V1: &[u8; 8] = b"CCFSREN1";
const RENAME_PAYLOAD_MAGIC_V2: &[u8; 8] = b"CCFSREN2";
const DELETE_PAYLOAD_MAGIC: &[u8; 8] = b"CCFSDEL1";
const RMDIR_PAYLOAD_MAGIC: &[u8; 8] = b"CCFSRMD1";
const TRUNCATE_PAYLOAD_MAGIC_V1: &[u8; 8] = b"CCFSTRN1";
const TRUNCATE_PAYLOAD_MAGIC_V2: &[u8; 8] = b"CCFSTRN2";
const SETATTR_PAYLOAD_MAGIC_V1: &[u8; 8] = b"CCFSATR1";
const SETATTR_PAYLOAD_MAGIC_V2: &[u8; 8] = b"CCFSATR2";

fn validate_name(name: &OsStr) -> Result<(), Errno> {
    let bytes = name.as_bytes();

    if bytes.is_empty() {
        return Err(Errno::EINVAL);
    }

    if bytes.len() > NAME_MAX {
        return Err(Errno::ENAMETOOLONG);
    }

    Ok(())
}

struct MemoryEntry {
    ino: INodeNo,
    parent: INodeNo,
    name: String,
    is_dir: bool,
    data: Vec<u8>,
    perm: u16,
    uid: u32,
    gid: u32,
    atime: SystemTime,
    mtime: SystemTime,
    ctime: SystemTime,
}

struct State {
    entries: BTreeMap<u64, MemoryEntry>,
    next_ino: u64,
}

struct Ccfs {
    state: Mutex<State>,
}

#[derive(Debug)]
struct CreateJournalPayload {
    ino: u64,
    parent: u64,
    name: String,
    perm: u16,
    atime: i64,
    mtime: i64,
    ctime: i64,
}

#[derive(Debug)]
struct MkdirJournalPayload {
    ino: u64,
    parent: u64,
    name: String,
    perm: u16,
    atime: i64,
    mtime: i64,
    ctime: i64,
}

#[derive(Debug)]
struct WriteJournalPayload {
    ino: u64,
    parent: u64,
    name: String,
    perm: u16,
    atime: i64,
    mtime: i64,
    ctime: i64,
    data: Vec<u8>,
}

#[derive(Debug)]
struct TruncateJournalPayload {
    ino: u64,
    parent: u64,
    name: String,
    perm: u16,
    uid: u32,
    gid: u32,
    atime: i64,
    mtime: i64,
    ctime: i64,
    data: Vec<u8>,
}

#[derive(Debug)]
struct SetattrJournalPayload {
    ino: u64,
    parent: u64,
    name: String,
    is_dir: bool,
    perm: u16,
    uid: u32,
    gid: u32,
    size: u64,
    atime: i64,
    mtime: i64,
    ctime: i64,
}

#[derive(Debug)]
struct RenameJournalPayload {
    ino: u64,
    replaced_ino: Option<u64>,
    new_parent: u64,
    new_name: String,
    is_dir: bool,
    perm: u16,
    size: u64,
    atime: i64,
    mtime: i64,
    ctime: i64,
}

#[derive(Debug)]
struct DeleteJournalPayload {
    ino: u64,
}

#[derive(Debug)]
struct RmdirJournalPayload {
    ino: u64,
}

fn database_io_error(error: rusqlite::Error) -> io::Error {
    io::Error::new(
        io::ErrorKind::Other,
        format!("metadata database error: {error}"),
    )
}

fn timestamp_to_system_time(timestamp: i64) -> SystemTime {
    if timestamp <= 0 {
        UNIX_EPOCH
    } else {
        UNIX_EPOCH + Duration::from_secs(timestamp as u64)
    }
}

fn system_time_to_timestamp(time: SystemTime) -> i64 {
    time.duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

fn resolve_time(value: TimeOrNow) -> SystemTime {
    match value {
        TimeOrNow::Now => SystemTime::now(),
        TimeOrNow::SpecificTime(time) => time,
    }
}

fn maybe_kill9(operation: &str, point: &str) {
    let configured_operation = env::var("CCFS_KILL9_OPERATION").ok();
    let configured_point = env::var("CCFS_KILL9_POINT").ok();

    if configured_operation.as_deref() == Some(operation)
        && configured_point.as_deref() == Some(point)
    {
        eprintln!(
            "CCFS TEST FAILPOINT: SIGKILL operation={} point={}",
            operation, point
        );

        let pid = process::id().to_string();

        let _ = std::process::Command::new("kill")
            .arg("-9")
            .arg(pid)
            .status();

        process::abort();
    }
}

fn persist_entry(entry: &MemoryEntry) -> rusqlite::Result<()> {
    let size = if entry.is_dir {
        0
    } else {
        entry.data.len() as u64
    };

    db::save_entry_metadata_with_times(
        u64::from(entry.ino),
        u64::from(entry.parent),
        &entry.name,
        entry.is_dir,
        entry.perm,
        size,
        system_time_to_timestamp(entry.atime),
        system_time_to_timestamp(entry.mtime),
        system_time_to_timestamp(entry.ctime),
    )
}

fn read_array<const N: usize>(payload: &[u8], cursor: &mut usize) -> io::Result<[u8; N]> {
    if payload.len().saturating_sub(*cursor) < N {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "journal payload is truncated",
        ));
    }

    let mut output = [0u8; N];

    output.copy_from_slice(&payload[*cursor..*cursor + N]);

    *cursor += N;

    Ok(output)
}

/* ============================================================
 * CREATE
 * ============================================================
 */

fn encode_create_payload(entry: &MemoryEntry) -> Vec<u8> {
    let name_bytes = entry.name.as_bytes();

    let mut payload = Vec::new();

    payload.extend_from_slice(CREATE_PAYLOAD_MAGIC);
    payload.extend_from_slice(&u64::from(entry.ino).to_le_bytes());
    payload.extend_from_slice(&u64::from(entry.parent).to_le_bytes());
    payload.extend_from_slice(&entry.perm.to_le_bytes());

    payload.extend_from_slice(&system_time_to_timestamp(entry.atime).to_le_bytes());

    payload.extend_from_slice(&system_time_to_timestamp(entry.mtime).to_le_bytes());

    payload.extend_from_slice(&system_time_to_timestamp(entry.ctime).to_le_bytes());

    payload.extend_from_slice(&(name_bytes.len() as u32).to_le_bytes());

    payload.extend_from_slice(name_bytes);

    payload
}

fn decode_create_payload(payload: &[u8]) -> io::Result<CreateJournalPayload> {
    if payload.len() < CREATE_PAYLOAD_MAGIC.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "CREATE payload is too short",
        ));
    }

    if &payload[..CREATE_PAYLOAD_MAGIC.len()] != CREATE_PAYLOAD_MAGIC {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid CREATE payload magic",
        ));
    }

    let mut cursor = CREATE_PAYLOAD_MAGIC.len();

    let ino = u64::from_le_bytes(read_array::<8>(payload, &mut cursor)?);

    let parent = u64::from_le_bytes(read_array::<8>(payload, &mut cursor)?);

    let perm = u16::from_le_bytes(read_array::<2>(payload, &mut cursor)?);

    let atime = i64::from_le_bytes(read_array::<8>(payload, &mut cursor)?);

    let mtime = i64::from_le_bytes(read_array::<8>(payload, &mut cursor)?);

    let ctime = i64::from_le_bytes(read_array::<8>(payload, &mut cursor)?);

    let name_length = u32::from_le_bytes(read_array::<4>(payload, &mut cursor)?) as usize;

    if payload.len().saturating_sub(cursor) != name_length {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid CREATE filename length",
        ));
    }

    let name = String::from_utf8(payload[cursor..].to_vec()).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "CREATE filename is not valid UTF-8",
        )
    })?;

    Ok(CreateJournalPayload {
        ino,
        parent,
        name,
        perm,
        atime,
        mtime,
        ctime,
    })
}

fn apply_create_payload(txid: u64, payload: &CreateJournalPayload) -> io::Result<()> {
    storage::save_file_data(payload.ino, &[])?;

    db::save_entry_metadata_with_times_and_mark_tx(
        txid,
        payload.ino,
        payload.parent,
        &payload.name,
        false,
        payload.perm,
        0,
        payload.atime,
        payload.mtime,
        payload.ctime,
    )
    .map_err(database_io_error)?;

    Ok(())
}

/* ============================================================
 * MKDIR
 * ============================================================
 */

fn encode_mkdir_payload(payload: &MkdirJournalPayload) -> Vec<u8> {
    let name_bytes = payload.name.as_bytes();

    let mut output = Vec::new();

    output.extend_from_slice(MKDIR_PAYLOAD_MAGIC);

    output.extend_from_slice(&payload.ino.to_le_bytes());

    output.extend_from_slice(&payload.parent.to_le_bytes());

    output.extend_from_slice(&payload.perm.to_le_bytes());

    output.extend_from_slice(&payload.atime.to_le_bytes());

    output.extend_from_slice(&payload.mtime.to_le_bytes());

    output.extend_from_slice(&payload.ctime.to_le_bytes());

    output.extend_from_slice(&(name_bytes.len() as u32).to_le_bytes());

    output.extend_from_slice(name_bytes);

    output
}

fn decode_mkdir_payload(payload: &[u8]) -> io::Result<MkdirJournalPayload> {
    if payload.len() < MKDIR_PAYLOAD_MAGIC.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "MKDIR payload is too short",
        ));
    }

    if &payload[..MKDIR_PAYLOAD_MAGIC.len()] != MKDIR_PAYLOAD_MAGIC {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid MKDIR payload magic",
        ));
    }

    let mut cursor = MKDIR_PAYLOAD_MAGIC.len();

    let ino = u64::from_le_bytes(read_array::<8>(payload, &mut cursor)?);

    let parent = u64::from_le_bytes(read_array::<8>(payload, &mut cursor)?);

    let perm = u16::from_le_bytes(read_array::<2>(payload, &mut cursor)?);

    let atime = i64::from_le_bytes(read_array::<8>(payload, &mut cursor)?);

    let mtime = i64::from_le_bytes(read_array::<8>(payload, &mut cursor)?);

    let ctime = i64::from_le_bytes(read_array::<8>(payload, &mut cursor)?);

    let name_length = u32::from_le_bytes(read_array::<4>(payload, &mut cursor)?) as usize;

    if payload.len().saturating_sub(cursor) != name_length {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid MKDIR filename length",
        ));
    }

    let name = String::from_utf8(payload[cursor..].to_vec())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "MKDIR filename invalid UTF-8"))?;

    Ok(MkdirJournalPayload {
        ino,
        parent,
        name,
        perm,
        atime,
        mtime,
        ctime,
    })
}

fn apply_mkdir_payload(txid: u64, payload: &MkdirJournalPayload) -> io::Result<()> {
    db::save_entry_metadata_with_times_and_mark_tx(
        txid,
        payload.ino,
        payload.parent,
        &payload.name,
        true,
        payload.perm,
        0,
        payload.atime,
        payload.mtime,
        payload.ctime,
    )
    .map_err(database_io_error)?;

    Ok(())
}

/* ============================================================
 * WRITE
 * ============================================================
 */

fn encode_write_payload(payload: &WriteJournalPayload) -> io::Result<Vec<u8>> {
    let name_bytes = payload.name.as_bytes();

    let name_length = u32::try_from(name_bytes.len())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "WRITE filename too large"))?;

    let data_length = u64::try_from(payload.data.len())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "WRITE data too large"))?;

    let mut output = Vec::new();

    output.extend_from_slice(WRITE_PAYLOAD_MAGIC);
    output.extend_from_slice(&payload.ino.to_le_bytes());
    output.extend_from_slice(&payload.parent.to_le_bytes());
    output.extend_from_slice(&payload.perm.to_le_bytes());
    output.extend_from_slice(&payload.atime.to_le_bytes());
    output.extend_from_slice(&payload.mtime.to_le_bytes());
    output.extend_from_slice(&payload.ctime.to_le_bytes());
    output.extend_from_slice(&name_length.to_le_bytes());
    output.extend_from_slice(&data_length.to_le_bytes());
    output.extend_from_slice(name_bytes);
    output.extend_from_slice(&payload.data);

    Ok(output)
}

fn decode_write_payload(payload: &[u8]) -> io::Result<WriteJournalPayload> {
    if payload.len() < WRITE_PAYLOAD_MAGIC.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "WRITE payload is too short",
        ));
    }

    if &payload[..WRITE_PAYLOAD_MAGIC.len()] != WRITE_PAYLOAD_MAGIC {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid WRITE payload magic",
        ));
    }

    let mut cursor = WRITE_PAYLOAD_MAGIC.len();

    let ino = u64::from_le_bytes(read_array::<8>(payload, &mut cursor)?);

    let parent = u64::from_le_bytes(read_array::<8>(payload, &mut cursor)?);

    let perm = u16::from_le_bytes(read_array::<2>(payload, &mut cursor)?);

    let atime = i64::from_le_bytes(read_array::<8>(payload, &mut cursor)?);

    let mtime = i64::from_le_bytes(read_array::<8>(payload, &mut cursor)?);

    let ctime = i64::from_le_bytes(read_array::<8>(payload, &mut cursor)?);

    let name_length = u32::from_le_bytes(read_array::<4>(payload, &mut cursor)?) as usize;

    let data_length_u64 = u64::from_le_bytes(read_array::<8>(payload, &mut cursor)?);

    let data_length = usize::try_from(data_length_u64)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "WRITE data length too large"))?;

    let remaining = name_length.checked_add(data_length).ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidData, "WRITE payload length overflow")
    })?;

    if payload.len().saturating_sub(cursor) != remaining {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid WRITE payload length",
        ));
    }

    let name_end = cursor + name_length;

    let name = String::from_utf8(payload[cursor..name_end].to_vec())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "WRITE filename invalid UTF-8"))?;

    let data = payload[name_end..].to_vec();

    Ok(WriteJournalPayload {
        ino,
        parent,
        name,
        perm,
        atime,
        mtime,
        ctime,
        data,
    })
}

fn apply_write_payload(txid: u64, payload: &WriteJournalPayload) -> io::Result<()> {
    storage::save_file_data(payload.ino, &payload.data)?;

    db::save_entry_metadata_with_times_and_mark_tx(
        txid,
        payload.ino,
        payload.parent,
        &payload.name,
        false,
        payload.perm,
        payload.data.len() as u64,
        payload.atime,
        payload.mtime,
        payload.ctime,
    )
    .map_err(database_io_error)?;

    Ok(())
}

/* ============================================================
 * TRUNCATE
 * ============================================================
 */

fn encode_truncate_payload(payload: &TruncateJournalPayload) -> io::Result<Vec<u8>> {
    let name_bytes = payload.name.as_bytes();

    let name_length = u32::try_from(name_bytes.len())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "TRUNCATE filename too large"))?;

    let data_length = u64::try_from(payload.data.len())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "TRUNCATE data too large"))?;

    let mut output = Vec::new();

    output.extend_from_slice(TRUNCATE_PAYLOAD_MAGIC_V2);
    output.extend_from_slice(&payload.ino.to_le_bytes());
    output.extend_from_slice(&payload.parent.to_le_bytes());
    output.extend_from_slice(&payload.perm.to_le_bytes());
    output.extend_from_slice(&payload.uid.to_le_bytes());
    output.extend_from_slice(&payload.gid.to_le_bytes());
    output.extend_from_slice(&payload.atime.to_le_bytes());
    output.extend_from_slice(&payload.mtime.to_le_bytes());
    output.extend_from_slice(&payload.ctime.to_le_bytes());
    output.extend_from_slice(&name_length.to_le_bytes());
    output.extend_from_slice(&data_length.to_le_bytes());
    output.extend_from_slice(name_bytes);
    output.extend_from_slice(&payload.data);

    Ok(output)
}

fn decode_truncate_payload(payload: &[u8]) -> io::Result<TruncateJournalPayload> {
    if payload.len() < TRUNCATE_PAYLOAD_MAGIC_V1.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "TRUNCATE payload is too short",
        ));
    }

    let magic = &payload[..TRUNCATE_PAYLOAD_MAGIC_V1.len()];

    let is_v2 = if magic == TRUNCATE_PAYLOAD_MAGIC_V2 {
        true
    } else if magic == TRUNCATE_PAYLOAD_MAGIC_V1 {
        false
    } else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid TRUNCATE payload magic",
        ));
    };

    let mut cursor = TRUNCATE_PAYLOAD_MAGIC_V1.len();

    let ino = u64::from_le_bytes(read_array::<8>(payload, &mut cursor)?);
    let parent = u64::from_le_bytes(read_array::<8>(payload, &mut cursor)?);
    let perm = u16::from_le_bytes(read_array::<2>(payload, &mut cursor)?);

    let (uid, gid) = if is_v2 {
        (
            u32::from_le_bytes(read_array::<4>(payload, &mut cursor)?),
            u32::from_le_bytes(read_array::<4>(payload, &mut cursor)?),
        )
    } else {
        (1000, 1000)
    };

    let atime = i64::from_le_bytes(read_array::<8>(payload, &mut cursor)?);
    let mtime = i64::from_le_bytes(read_array::<8>(payload, &mut cursor)?);
    let ctime = i64::from_le_bytes(read_array::<8>(payload, &mut cursor)?);

    let name_length = u32::from_le_bytes(read_array::<4>(payload, &mut cursor)?) as usize;

    let data_length_u64 = u64::from_le_bytes(read_array::<8>(payload, &mut cursor)?);

    let data_length = usize::try_from(data_length_u64).map_err(|_| {
        io::Error::new(io::ErrorKind::InvalidData, "TRUNCATE data length too large")
    })?;

    let remaining = name_length.checked_add(data_length).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "TRUNCATE payload length overflow",
        )
    })?;

    if payload.len().saturating_sub(cursor) != remaining {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid TRUNCATE payload length",
        ));
    }

    let name_end = cursor + name_length;

    let name = String::from_utf8(payload[cursor..name_end].to_vec()).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "TRUNCATE filename invalid UTF-8",
        )
    })?;

    let data = payload[name_end..].to_vec();

    Ok(TruncateJournalPayload {
        ino,
        parent,
        name,
        perm,
        uid,
        gid,
        atime,
        mtime,
        ctime,
        data,
    })
}

fn apply_truncate_payload(txid: u64, payload: &TruncateJournalPayload) -> io::Result<()> {
    storage::save_file_data(payload.ino, &payload.data)?;

    db::save_entry_metadata_with_ownership_and_mark_tx(
        txid,
        payload.ino,
        payload.parent,
        &payload.name,
        false,
        payload.perm,
        payload.uid,
        payload.gid,
        payload.data.len() as u64,
        payload.atime,
        payload.mtime,
        payload.ctime,
    )
    .map_err(database_io_error)?;

    Ok(())
}

/* ============================================================
 * SETATTR
 * ============================================================
 */

fn encode_setattr_payload(payload: &SetattrJournalPayload) -> io::Result<Vec<u8>> {
    let name_bytes = payload.name.as_bytes();

    let name_length = u32::try_from(name_bytes.len())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "SETATTR filename too large"))?;

    let mut output = Vec::new();

    output.extend_from_slice(SETATTR_PAYLOAD_MAGIC_V2);
    output.extend_from_slice(&payload.ino.to_le_bytes());
    output.extend_from_slice(&payload.parent.to_le_bytes());

    output.push(if payload.is_dir { 1 } else { 0 });

    output.extend_from_slice(&payload.perm.to_le_bytes());
    output.extend_from_slice(&payload.uid.to_le_bytes());
    output.extend_from_slice(&payload.gid.to_le_bytes());
    output.extend_from_slice(&payload.size.to_le_bytes());
    output.extend_from_slice(&payload.atime.to_le_bytes());
    output.extend_from_slice(&payload.mtime.to_le_bytes());
    output.extend_from_slice(&payload.ctime.to_le_bytes());
    output.extend_from_slice(&name_length.to_le_bytes());
    output.extend_from_slice(name_bytes);

    Ok(output)
}

fn decode_setattr_payload(payload: &[u8]) -> io::Result<SetattrJournalPayload> {
    if payload.len() < SETATTR_PAYLOAD_MAGIC_V1.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "SETATTR payload is too short",
        ));
    }

    let magic = &payload[..SETATTR_PAYLOAD_MAGIC_V1.len()];

    let is_v2 = if magic == SETATTR_PAYLOAD_MAGIC_V2 {
        true
    } else if magic == SETATTR_PAYLOAD_MAGIC_V1 {
        false
    } else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid SETATTR payload magic",
        ));
    };

    let mut cursor = SETATTR_PAYLOAD_MAGIC_V1.len();

    let ino = u64::from_le_bytes(read_array::<8>(payload, &mut cursor)?);
    let parent = u64::from_le_bytes(read_array::<8>(payload, &mut cursor)?);

    let is_dir = match read_array::<1>(payload, &mut cursor)?[0] {
        0 => false,
        1 => true,

        _ => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "invalid SETATTR directory flag",
            ));
        }
    };

    let perm = u16::from_le_bytes(read_array::<2>(payload, &mut cursor)?);

    let (uid, gid) = if is_v2 {
        (
            u32::from_le_bytes(read_array::<4>(payload, &mut cursor)?),
            u32::from_le_bytes(read_array::<4>(payload, &mut cursor)?),
        )
    } else {
        (1000, 1000)
    };

    let size = u64::from_le_bytes(read_array::<8>(payload, &mut cursor)?);
    let atime = i64::from_le_bytes(read_array::<8>(payload, &mut cursor)?);
    let mtime = i64::from_le_bytes(read_array::<8>(payload, &mut cursor)?);
    let ctime = i64::from_le_bytes(read_array::<8>(payload, &mut cursor)?);

    let name_length = u32::from_le_bytes(read_array::<4>(payload, &mut cursor)?) as usize;

    if payload.len().saturating_sub(cursor) != name_length {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid SETATTR filename length",
        ));
    }

    let name = String::from_utf8(payload[cursor..].to_vec()).map_err(|_| {
        io::Error::new(io::ErrorKind::InvalidData, "SETATTR filename invalid UTF-8")
    })?;

    Ok(SetattrJournalPayload {
        ino,
        parent,
        name,
        is_dir,
        perm,
        uid,
        gid,
        size,
        atime,
        mtime,
        ctime,
    })
}

fn apply_setattr_payload(txid: u64, payload: &SetattrJournalPayload) -> io::Result<()> {
    db::save_entry_metadata_with_ownership_and_mark_tx(
        txid,
        payload.ino,
        payload.parent,
        &payload.name,
        payload.is_dir,
        payload.perm,
        payload.uid,
        payload.gid,
        payload.size,
        payload.atime,
        payload.mtime,
        payload.ctime,
    )
    .map_err(database_io_error)?;

    Ok(())
}

/* ============================================================
 * RENAME
 * ============================================================
 */

fn encode_rename_payload(payload: &RenameJournalPayload) -> io::Result<Vec<u8>> {
    let name_bytes = payload.new_name.as_bytes();

    let name_length = u32::try_from(name_bytes.len())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "RENAME filename too large"))?;

    let replaced_ino = payload.replaced_ino.unwrap_or(u64::MAX);

    let mut output = Vec::new();

    output.extend_from_slice(RENAME_PAYLOAD_MAGIC_V2);

    output.extend_from_slice(&payload.ino.to_le_bytes());

    output.extend_from_slice(&payload.new_parent.to_le_bytes());

    output.extend_from_slice(&replaced_ino.to_le_bytes());

    output.push(if payload.is_dir { 1 } else { 0 });

    output.extend_from_slice(&payload.perm.to_le_bytes());

    output.extend_from_slice(&payload.size.to_le_bytes());

    output.extend_from_slice(&payload.atime.to_le_bytes());

    output.extend_from_slice(&payload.mtime.to_le_bytes());

    output.extend_from_slice(&payload.ctime.to_le_bytes());

    output.extend_from_slice(&name_length.to_le_bytes());

    output.extend_from_slice(name_bytes);

    Ok(output)
}

fn decode_rename_payload(payload: &[u8]) -> io::Result<RenameJournalPayload> {
    if payload.len() < RENAME_PAYLOAD_MAGIC_V1.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "RENAME payload too short",
        ));
    }

    let magic = &payload[..RENAME_PAYLOAD_MAGIC_V1.len()];

    let is_v2 = if magic == RENAME_PAYLOAD_MAGIC_V2 {
        true
    } else if magic == RENAME_PAYLOAD_MAGIC_V1 {
        false
    } else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid RENAME payload magic",
        ));
    };

    let mut cursor = RENAME_PAYLOAD_MAGIC_V1.len();

    let ino = u64::from_le_bytes(read_array::<8>(payload, &mut cursor)?);

    let new_parent = u64::from_le_bytes(read_array::<8>(payload, &mut cursor)?);

    /*
     * V1 journal transactions did not store a replacement inode.
     * Keeping V1 decoding means old journals remain recoverable.
     */
    let replaced_ino = if is_v2 {
        let value = u64::from_le_bytes(read_array::<8>(payload, &mut cursor)?);

        if value == u64::MAX { None } else { Some(value) }
    } else {
        None
    };

    let is_dir = match read_array::<1>(payload, &mut cursor)?[0] {
        0 => false,
        1 => true,

        _ => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "invalid RENAME directory flag",
            ));
        }
    };

    let perm = u16::from_le_bytes(read_array::<2>(payload, &mut cursor)?);

    let size = u64::from_le_bytes(read_array::<8>(payload, &mut cursor)?);

    let atime = i64::from_le_bytes(read_array::<8>(payload, &mut cursor)?);

    let mtime = i64::from_le_bytes(read_array::<8>(payload, &mut cursor)?);

    let ctime = i64::from_le_bytes(read_array::<8>(payload, &mut cursor)?);

    let name_length = u32::from_le_bytes(read_array::<4>(payload, &mut cursor)?) as usize;

    if payload.len().saturating_sub(cursor) != name_length {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid RENAME filename length",
        ));
    }

    let new_name = String::from_utf8(payload[cursor..].to_vec())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "RENAME filename invalid UTF-8"))?;

    Ok(RenameJournalPayload {
        ino,
        replaced_ino,
        new_parent,
        new_name,
        is_dir,
        perm,
        size,
        atime,
        mtime,
        ctime,
    })
}

fn apply_rename_payload(txid: u64, payload: &RenameJournalPayload) -> io::Result<()> {
    /*
     * If POSIX rename replaces an existing destination, remove its
     * durable block/checksum before metadata commits the replacement.
     *
     * This ordering is intentional:
     *
     * - Crash before metadata commit:
     *   recovery sees tx as unapplied and repeats this idempotently.
     *
     * - Crash after metadata commit:
     *   destination storage is already removed and applied_tx was
     *   committed atomically with the metadata rename.
     */
    if let Some(replaced_ino) = payload.replaced_ino {
        if replaced_ino != payload.ino {
            storage::delete_file_data(replaced_ino)?;
        }
    }

    db::rename_entry_replacing_and_mark_tx(
        txid,
        payload.ino,
        payload.replaced_ino,
        payload.new_parent,
        &payload.new_name,
        payload.is_dir,
        payload.perm,
        payload.size,
        payload.atime,
        payload.mtime,
        payload.ctime,
    )
    .map_err(database_io_error)?;

    Ok(())
}

/* ============================================================
 * DELETE
 * ============================================================
 */

fn encode_delete_payload(payload: &DeleteJournalPayload) -> Vec<u8> {
    let mut output = Vec::with_capacity(DELETE_PAYLOAD_MAGIC.len() + 8);

    output.extend_from_slice(DELETE_PAYLOAD_MAGIC);

    output.extend_from_slice(&payload.ino.to_le_bytes());

    output
}

fn decode_delete_payload(payload: &[u8]) -> io::Result<DeleteJournalPayload> {
    let expected_length = DELETE_PAYLOAD_MAGIC.len() + 8;

    if payload.len() != expected_length {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "DELETE payload has invalid length",
        ));
    }

    if &payload[..DELETE_PAYLOAD_MAGIC.len()] != DELETE_PAYLOAD_MAGIC {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid DELETE payload magic",
        ));
    }

    let mut cursor = DELETE_PAYLOAD_MAGIC.len();

    let ino = u64::from_le_bytes(read_array::<8>(payload, &mut cursor)?);

    Ok(DeleteJournalPayload { ino })
}

fn remove_file_storage_idempotent(ino: u64) -> io::Result<()> {
    let paths = [
        format!("volume/blocks/{ino}.bin"),
        format!("volume/blocks/{ino}.checksum"),
    ];

    for path in paths {
        match fs::remove_file(&path) {
            Ok(()) => {}

            Err(err) if err.kind() == ErrorKind::NotFound => {}

            Err(err) => {
                return Err(err);
            }
        }
    }

    Ok(())
}

fn apply_delete_payload(txid: u64, payload: &DeleteJournalPayload) -> io::Result<()> {
    remove_file_storage_idempotent(payload.ino)?;

    db::delete_entry_metadata_and_mark_tx(txid, payload.ino).map_err(database_io_error)?;

    Ok(())
}

/* ============================================================
 * RMDIR
 * ============================================================
 */

fn encode_rmdir_payload(payload: &RmdirJournalPayload) -> Vec<u8> {
    let mut output = Vec::with_capacity(RMDIR_PAYLOAD_MAGIC.len() + 8);

    output.extend_from_slice(RMDIR_PAYLOAD_MAGIC);

    output.extend_from_slice(&payload.ino.to_le_bytes());

    output
}

fn decode_rmdir_payload(payload: &[u8]) -> io::Result<RmdirJournalPayload> {
    let expected_length = RMDIR_PAYLOAD_MAGIC.len() + 8;

    if payload.len() != expected_length {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "RMDIR payload has invalid length",
        ));
    }

    if &payload[..RMDIR_PAYLOAD_MAGIC.len()] != RMDIR_PAYLOAD_MAGIC {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid RMDIR payload magic",
        ));
    }

    let mut cursor = RMDIR_PAYLOAD_MAGIC.len();

    let ino = u64::from_le_bytes(read_array::<8>(payload, &mut cursor)?);

    Ok(RmdirJournalPayload { ino })
}

fn apply_rmdir_payload(txid: u64, payload: &RmdirJournalPayload) -> io::Result<()> {
    db::delete_entry_metadata_and_mark_tx(txid, payload.ino).map_err(database_io_error)?;

    Ok(())
}

/* ============================================================
 * STARTUP RECOVERY
 * ============================================================
 */

fn run_startup_recovery() -> io::Result<recovery::RecoverySummary> {
    recovery::recover_with(|transaction| match transaction.operation.as_str() {
        "CREATE" => {
            let payload = decode_create_payload(&transaction.payload)?;

            apply_create_payload(transaction.txid, &payload)
        }

        "MKDIR" => {
            let payload = decode_mkdir_payload(&transaction.payload)?;

            apply_mkdir_payload(transaction.txid, &payload)
        }

        "WRITE" => {
            let payload = decode_write_payload(&transaction.payload)?;

            apply_write_payload(transaction.txid, &payload)
        }

        "TRUNCATE" => {
            let payload = decode_truncate_payload(&transaction.payload)?;

            apply_truncate_payload(transaction.txid, &payload)
        }

        "SETATTR" => {
            let payload = decode_setattr_payload(&transaction.payload)?;

            apply_setattr_payload(transaction.txid, &payload)
        }

        "ATIME" => {
            let payload = decode_setattr_payload(&transaction.payload)?;

            apply_setattr_payload(transaction.txid, &payload)
        }

        "RENAME" => {
            let payload = decode_rename_payload(&transaction.payload)?;

            apply_rename_payload(transaction.txid, &payload)
        }

        "DELETE" => {
            let payload = decode_delete_payload(&transaction.payload)?;

            apply_delete_payload(transaction.txid, &payload)
        }

        "RMDIR" => {
            let payload = decode_rmdir_payload(&transaction.payload)?;

            apply_rmdir_payload(transaction.txid, &payload)
        }

        other => Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("unsupported committed journal operation: {other}"),
        )),
    })
}

/* ============================================================
 * STATE
 * ============================================================
 */

impl Ccfs {
    fn new() -> Self {
        let mut entries = BTreeMap::new();

        let now = SystemTime::now();

        entries.insert(
            2,
            MemoryEntry {
                ino: INodeNo(2),

                parent: INodeNo::ROOT,

                name: "hello.txt".to_string(),

                is_dir: false,

                data: b"Hello from CCFS!\n".to_vec(),

                perm: 0o644,

                uid: 1000,

                gid: 1000,

                atime: now,

                mtime: now,

                ctime: now,
            },
        );

        let mut next_ino = 3;

        match db::load_entries() {
            Ok(metadata_entries) => {
                for meta in metadata_entries {
                    if meta.ino == 2 {
                        continue;
                    }

                    next_ino = next_ino.max(meta.ino + 1);

                    let data = if meta.is_dir {
                        Vec::new()
                    } else {
                        match storage::load_file_data(meta.ino) {
                            Ok(data) => data,

                            Err(err) if err.kind() == ErrorKind::NotFound && meta.size == 0 => {
                                match storage::save_file_data(meta.ino, &[]) {
                                    Ok(()) => {
                                        eprintln!(
                                            "Repaired legacy empty file storage for inode {}",
                                            meta.ino
                                        );
                                    }

                                    Err(init_err) => {
                                        eprintln!(
                                            "Failed to repair empty inode {}: {}",
                                            meta.ino, init_err
                                        );
                                    }
                                }

                                Vec::new()
                            }

                            Err(err) => {
                                eprintln!(
                                    "Failed to load file data for inode {}: {}",
                                    meta.ino, err
                                );

                                vec![0; meta.size as usize]
                            }
                        }
                    };

                    entries.insert(
                        meta.ino,
                        MemoryEntry {
                            ino: INodeNo(meta.ino),

                            parent: INodeNo(meta.parent),

                            name: meta.name,

                            is_dir: meta.is_dir,

                            data,

                            perm: meta.perm,

                            uid: meta.uid,

                            gid: meta.gid,

                            atime: timestamp_to_system_time(meta.atime),

                            mtime: timestamp_to_system_time(meta.mtime),

                            ctime: timestamp_to_system_time(meta.ctime),
                        },
                    );
                }
            }

            Err(err) => {
                eprintln!("Failed to load filesystem metadata: {}", err);
            }
        }

        Self {
            state: Mutex::new(State { entries, next_ino }),
        }
    }
}

fn root_attr() -> FileAttr {
    FileAttr {
        ino: INodeNo::ROOT,

        size: 0,

        blocks: 0,

        atime: UNIX_EPOCH,

        mtime: UNIX_EPOCH,

        ctime: UNIX_EPOCH,

        crtime: UNIX_EPOCH,

        kind: FileType::Directory,

        perm: 0o755,

        nlink: 2,

        uid: 1000,

        gid: 1000,

        rdev: 0,

        blksize: 4096,

        flags: 0,
    }
}

fn entry_kind(entry: &MemoryEntry) -> FileType {
    if entry.is_dir {
        FileType::Directory
    } else {
        FileType::RegularFile
    }
}

fn entry_attr(entry: &MemoryEntry) -> FileAttr {
    let size = if entry.is_dir {
        0
    } else {
        entry.data.len() as u64
    };

    FileAttr {
        ino: entry.ino,

        size,

        blocks: (size + 511) / 512,

        atime: entry.atime,

        mtime: entry.mtime,

        ctime: entry.ctime,

        crtime: entry.ctime,

        kind: entry_kind(entry),

        perm: entry.perm,

        nlink: if entry.is_dir { 2 } else { 1 },

        uid: entry.uid,

        gid: entry.gid,

        rdev: 0,

        blksize: 4096,

        flags: 0,
    }
}

fn check_directory(state: &State, ino: INodeNo) -> Result<(), Errno> {
    if ino == INodeNo::ROOT {
        return Ok(());
    }

    match state.entries.get(&u64::from(ino)) {
        Some(entry) if entry.is_dir => Ok(()),

        Some(_) => Err(Errno::ENOTDIR),

        None => Err(Errno::ENOENT),
    }
}

fn find_child(state: &State, parent: INodeNo, name: &str) -> Option<u64> {
    state
        .entries
        .iter()
        .find(|(_, entry)| entry.parent == parent && entry.name == name)
        .map(|(ino, _)| *ino)
}

fn would_create_directory_cycle(state: &State, moving_ino: u64, new_parent: INodeNo) -> bool {
    let mut current = new_parent;

    let mut steps = 0usize;

    while current != INodeNo::ROOT {
        let current_ino = u64::from(current);

        if current_ino == moving_ino {
            return true;
        }

        let Some(entry) = state.entries.get(&current_ino) else {
            return false;
        };

        current = entry.parent;

        steps += 1;

        if steps > state.entries.len() {
            return true;
        }
    }

    false
}

/* ============================================================
 * ADMIN
 * ============================================================
 */

fn migrate_checksums() {
    let _db = match db::init_database() {
        Ok(conn) => conn,

        Err(err) => {
            eprintln!("Failed to initialize metadata database: {}", err);

            process::exit(1);
        }
    };

    println!("CCFS checksum migration");

    println!("-----------------------");

    let entries = match db::load_entries() {
        Ok(entries) => entries,

        Err(err) => {
            eprintln!("Failed to load metadata: {}", err);

            process::exit(1);
        }
    };

    let mut repaired_empty_files = 0usize;

    let mut unrecoverable_missing_blocks = 0usize;

    for entry in entries {
        if entry.is_dir {
            continue;
        }

        match storage::verify_file_data(entry.ino) {
            Ok(IntegrityStatus::MissingData) if entry.size == 0 => {
                match storage::save_file_data(entry.ino, &[]) {
                    Ok(()) => {
                        repaired_empty_files += 1;

                        println!("[REPAIR] inode {}: initialized empty data block", entry.ino);
                    }

                    Err(err) => {
                        eprintln!(
                            "[FAIL] inode {}: unable to initialize empty block: {}",
                            entry.ino, err
                        );

                        process::exit(1);
                    }
                }
            }

            Ok(IntegrityStatus::MissingData) => {
                unrecoverable_missing_blocks += 1;

                eprintln!(
                    "[FAIL] inode {}: {} byte file has no data block",
                    entry.ino, entry.size
                );
            }

            Ok(_) => {}

            Err(err) => {
                eprintln!("[FAIL] inode {}: integrity read error: {}", entry.ino, err);

                process::exit(1);
            }
        }
    }

    if unrecoverable_missing_blocks > 0 {
        eprintln!();

        eprintln!(
            "Migration stopped: {} non-empty file(s) are missing data blocks.",
            unrecoverable_missing_blocks
        );

        process::exit(2);
    }

    let migrated_checksums = match storage::migrate_missing_checksums() {
        Ok(count) => count,

        Err(err) => {
            eprintln!("Checksum migration failed: {}", err);

            process::exit(1);
        }
    };

    println!();
    println!("Migration completed.");

    println!("Legacy empty blocks repaired: {}", repaired_empty_files);

    println!("Checksums created: {}", migrated_checksums);
}

fn check_integrity() {
    let _db = match db::init_database() {
        Ok(conn) => conn,

        Err(err) => {
            eprintln!("Failed to initialize metadata database: {}", err);

            process::exit(1);
        }
    };

    println!("CCFS integrity check");

    println!("--------------------");

    let entries = match db::load_entries() {
        Ok(entries) => entries,

        Err(err) => {
            eprintln!("Unable to read filesystem metadata: {}", err);

            process::exit(1);
        }
    };

    let mut failures = 0usize;

    let mut regular_file_inodes = BTreeSet::new();

    for entry in entries {
        if entry.is_dir {
            continue;
        }

        regular_file_inodes.insert(entry.ino);

        match storage::verify_file_data(entry.ino) {
            Ok(IntegrityStatus::Healthy) => {
                println!("[PASS] inode {}: {} healthy", entry.ino, entry.name);
            }

            Ok(IntegrityStatus::MissingData) => {
                failures += 1;

                println!(
                    "[FAIL] inode {}: {} data block missing",
                    entry.ino, entry.name
                );
            }

            Ok(IntegrityStatus::MissingChecksum) => {
                failures += 1;

                println!(
                    "[FAIL] inode {}: {} checksum missing",
                    entry.ino, entry.name
                );
            }

            Ok(IntegrityStatus::Corrupted { expected, actual }) => {
                failures += 1;

                println!(
                    "[FAIL] inode {}: {} checksum mismatch expected={:016x} actual={:016x}",
                    entry.ino, entry.name, expected, actual
                );
            }

            Err(err) => {
                failures += 1;

                println!(
                    "[FAIL] inode {}: {} integrity error: {}",
                    entry.ino, entry.name, err
                );
            }
        }
    }

    match storage::list_block_inodes() {
        Ok(block_inodes) => {
            for ino in block_inodes {
                if !regular_file_inodes.contains(&ino) {
                    failures += 1;

                    println!(
                        "[FAIL] inode {}: orphan data block has no regular-file metadata",
                        ino
                    );
                }
            }
        }

        Err(err) => {
            failures += 1;

            println!("[FAIL] unable to enumerate block files: {}", err);
        }
    }

    println!();

    if failures == 0 {
        println!("ALL CCFS BLOCKS PASSED INTEGRITY CHECK");
    } else {
        println!(
            "CCFS INTEGRITY CHECK FAILED: {} problem(s) detected",
            failures
        );

        process::exit(2);
    }
}

fn show_recovery_status() {
    let summary = match recovery::inspect_recovery_state() {
        Ok(summary) => summary,

        Err(err) => {
            eprintln!("Unable to inspect recovery state: {}", err);

            process::exit(1);
        }
    };

    recovery::print_summary(&summary);

    match recovery::applied_transaction_count() {
        Ok(count) => {
            println!("Applied transaction records: {}", count);
        }

        Err(err) => {
            eprintln!("Unable to read applied transaction count: {}", err);

            process::exit(1);
        }
    }
}

fn run_checkpoint() {
    let summary = match recovery::checkpoint_recovery_state() {
        Ok(summary) => summary,

        Err(err) => {
            eprintln!("CCFS checkpoint failed: {}", err);
            process::exit(1);
        }
    };

    recovery::print_checkpoint_summary(&summary);
}

fn print_usage() {
    println!("CCFS");
    println!();
    println!("Usage:");
    println!("  ccfs");
    println!("  ccfs --migrate-checksums");
    println!("  ccfs --check-integrity");
    println!("  ccfs --recovery-status");
    println!("  ccfs --checkpoint");
    println!("  ccfs --snapshot-create <name>");
    println!("  ccfs --snapshot-list");
    println!("  ccfs --snapshot-read <name> <path>");
    println!("  ccfs --snapshot-verify <name>");
    println!("  ccfs --snapshot-restore <name>");
    println!("  ccfs --snapshot-delete <name>");
}
/* ============================================================
 * FILESYSTEM
 * ============================================================
 */

impl Filesystem for Ccfs {
    fn lookup(&self, _req: &Request, parent: INodeNo, name: &OsStr, reply: ReplyEntry) {
        if let Err(err) = validate_name(name) {
            reply.error(err);
            return;
        }

        let state = self.state.lock().unwrap();

        if let Err(err) = check_directory(&state, parent) {
            reply.error(err);
            return;
        }

        let name = name.to_string_lossy();

        let Some(ino) = find_child(&state, parent, name.as_ref()) else {
            reply.error(Errno::ENOENT);
            return;
        };

        let Some(entry) = state.entries.get(&ino) else {
            reply.error(Errno::ENOENT);
            return;
        };

        reply.entry(&TTL, &entry_attr(entry), Generation(0));
    }

    fn getattr(&self, _req: &Request, ino: INodeNo, _fh: Option<FileHandle>, reply: ReplyAttr) {
        if ino == INodeNo::ROOT {
            reply.attr(&TTL, &root_attr());
            return;
        }

        let state = self.state.lock().unwrap();

        let Some(entry) = state.entries.get(&u64::from(ino)) else {
            reply.error(Errno::ENOENT);
            return;
        };

        reply.attr(&TTL, &entry_attr(entry));
    }

    fn setattr(
        &self,
        _req: &Request,
        ino: INodeNo,
        mode: Option<u32>,
        uid: Option<u32>,
        gid: Option<u32>,
        size: Option<u64>,
        atime: Option<TimeOrNow>,
        mtime: Option<TimeOrNow>,
        ctime: Option<SystemTime>,
        _fh: Option<FileHandle>,
        _crtime: Option<SystemTime>,
        _chgtime: Option<SystemTime>,
        _bkuptime: Option<SystemTime>,
        _flags: Option<BsdFileFlags>,
        reply: ReplyAttr,
    ) {
        if ino == INodeNo::ROOT {
            reply.attr(&TTL, &root_attr());
            return;
        }

        let mut state = self.state.lock().unwrap();

        let Some(entry) = state.entries.get_mut(&u64::from(ino)) else {
            reply.error(Errno::ENOENT);
            return;
        };

        let mut new_perm = entry.perm;
        let mut new_uid = entry.uid;
        let mut new_gid = entry.gid;
        let mut new_atime = entry.atime;
        let mut new_mtime = entry.mtime;
        let mut new_ctime = entry.ctime;
        let mut final_data = entry.data.clone();

        let mut changed = false;
        let mut change_ctime = false;

        let size_requested = size.is_some();

        if let Some(mode) = mode {
            new_perm = (mode & 0o777) as u16;
            changed = true;
            change_ctime = true;
        }

        if let Some(value) = uid {
            new_uid = value;
            changed = true;
            change_ctime = true;
        }

        if let Some(value) = gid {
            new_gid = value;
            changed = true;
            change_ctime = true;
        }

        if let Some(new_size) = size {
            if entry.is_dir {
                reply.error(Errno::EISDIR);
                return;
            }

            let new_size_usize = match usize::try_from(new_size) {
                Ok(value) => value,

                Err(_) => {
                    reply.error(Errno::EFBIG);
                    return;
                }
            };

            final_data.resize(new_size_usize, 0);

            new_mtime = SystemTime::now();

            changed = true;
            change_ctime = true;
        }

        if let Some(value) = atime {
            new_atime = resolve_time(value);
            changed = true;
        }

        if let Some(value) = mtime {
            new_mtime = resolve_time(value);
            changed = true;
            change_ctime = true;
        }

        let explicit_ctime = ctime.is_some();

        if let Some(value) = ctime {
            new_ctime = value;
            changed = true;
        }

        if change_ctime && !explicit_ctime {
            new_ctime = SystemTime::now();
        }

        if size_requested {
            let payload = TruncateJournalPayload {
                ino: u64::from(entry.ino),
                parent: u64::from(entry.parent),
                name: entry.name.clone(),
                perm: new_perm,
                uid: new_uid,
                gid: new_gid,
                atime: system_time_to_timestamp(new_atime),
                mtime: system_time_to_timestamp(new_mtime),
                ctime: system_time_to_timestamp(new_ctime),
                data: final_data.clone(),
            };

            let encoded_payload = match encode_truncate_payload(&payload) {
                Ok(encoded) => encoded,

                Err(err) => {
                    eprintln!("Failed TRUNCATE payload encode: {}", err);
                    reply.error(Errno::EIO);
                    return;
                }
            };

            let txid = match journal::begin_transaction("TRUNCATE", &encoded_payload) {
                Ok(txid) => txid,

                Err(err) => {
                    eprintln!("Failed TRUNCATE BEGIN: {}", err);
                    reply.error(Errno::EIO);
                    return;
                }
            };

            maybe_kill9("TRUNCATE", "after_begin");

            if let Err(err) = journal::commit_transaction(txid) {
                eprintln!("Failed TRUNCATE COMMIT: {}", err);
                reply.error(Errno::EIO);
                return;
            }

            maybe_kill9("TRUNCATE", "after_commit");

            if let Err(err) = apply_truncate_payload(txid, &payload) {
                eprintln!("Committed TRUNCATE {} apply failed: {}", txid, err);
                reply.error(Errno::EIO);
                return;
            }

            entry.data = final_data;
            entry.perm = new_perm;
            entry.uid = new_uid;
            entry.gid = new_gid;
            entry.atime = new_atime;
            entry.mtime = new_mtime;
            entry.ctime = new_ctime;

            reply.attr(&TTL, &entry_attr(entry));
            return;
        }

        if changed {
            let payload = SetattrJournalPayload {
                ino: u64::from(entry.ino),
                parent: u64::from(entry.parent),
                name: entry.name.clone(),
                is_dir: entry.is_dir,
                perm: new_perm,
                uid: new_uid,
                gid: new_gid,
                size: if entry.is_dir {
                    0
                } else {
                    entry.data.len() as u64
                },
                atime: system_time_to_timestamp(new_atime),
                mtime: system_time_to_timestamp(new_mtime),
                ctime: system_time_to_timestamp(new_ctime),
            };

            let encoded_payload = match encode_setattr_payload(&payload) {
                Ok(encoded) => encoded,

                Err(err) => {
                    eprintln!("Failed SETATTR payload encode: {}", err);
                    reply.error(Errno::EIO);
                    return;
                }
            };

            let txid = match journal::begin_transaction("SETATTR", &encoded_payload) {
                Ok(txid) => txid,

                Err(err) => {
                    eprintln!("Failed SETATTR BEGIN: {}", err);
                    reply.error(Errno::EIO);
                    return;
                }
            };

            maybe_kill9("SETATTR", "after_begin");

            if let Err(err) = journal::commit_transaction(txid) {
                eprintln!("Failed SETATTR COMMIT: {}", err);
                reply.error(Errno::EIO);
                return;
            }

            maybe_kill9("SETATTR", "after_commit");

            if let Err(err) = apply_setattr_payload(txid, &payload) {
                eprintln!("Committed SETATTR {} apply failed: {}", txid, err);
                reply.error(Errno::EIO);
                return;
            }

            entry.perm = new_perm;
            entry.uid = new_uid;
            entry.gid = new_gid;
            entry.atime = new_atime;
            entry.mtime = new_mtime;
            entry.ctime = new_ctime;
        }

        reply.attr(&TTL, &entry_attr(entry));
    }

    fn readdir(
        &self,
        _req: &Request,
        ino: INodeNo,
        _fh: FileHandle,
        offset: u64,
        mut reply: ReplyDirectory,
    ) {
        let state = self.state.lock().unwrap();

        if let Err(err) = check_directory(&state, ino) {
            reply.error(err);
            return;
        }

        let parent_ino = if ino == INodeNo::ROOT {
            INodeNo::ROOT
        } else {
            state
                .entries
                .get(&u64::from(ino))
                .map(|entry| entry.parent)
                .unwrap_or(INodeNo::ROOT)
        };

        let mut directory_entries: Vec<(INodeNo, FileType, String)> = vec![
            (ino, FileType::Directory, ".".to_string()),
            (parent_ino, FileType::Directory, "..".to_string()),
        ];

        let mut children: Vec<&MemoryEntry> = state
            .entries
            .values()
            .filter(|entry| entry.parent == ino)
            .collect();

        children.sort_by(|a, b| a.name.cmp(&b.name));

        for child in children {
            directory_entries.push((child.ino, entry_kind(child), child.name.clone()));
        }

        for (index, entry) in directory_entries.iter().enumerate().skip(offset as usize) {
            if reply.add(entry.0, (index + 1) as u64, entry.1, &entry.2) {
                break;
            }
        }

        reply.ok();
    }

    fn mkdir(
        &self,
        _req: &Request,
        parent: INodeNo,
        name: &OsStr,
        mode: u32,
        umask: u32,
        reply: ReplyEntry,
    ) {
        if let Err(err) = validate_name(name) {
            reply.error(err);
            return;
        }

        let name = name.to_string_lossy().into_owned();

        let mut state = self.state.lock().unwrap();

        if let Err(err) = check_directory(&state, parent) {
            reply.error(err);
            return;
        }

        if find_child(&state, parent, &name).is_some() {
            reply.error(Errno::EEXIST);
            return;
        }

        let ino_value = state.next_ino;
        state.next_ino += 1;

        let now = SystemTime::now();

        let entry = MemoryEntry {
            ino: INodeNo(ino_value),
            parent,
            name: name.clone(),
            is_dir: true,
            data: Vec::new(),
            perm: (mode & !umask & 0o777) as u16,
            uid: 1000,
            gid: 1000,
            atime: now,
            mtime: now,
            ctime: now,
        };

        let attr = entry_attr(&entry);

        let payload = MkdirJournalPayload {
            ino: ino_value,
            parent: u64::from(parent),
            name: name.clone(),
            perm: entry.perm,
            atime: system_time_to_timestamp(entry.atime),
            mtime: system_time_to_timestamp(entry.mtime),
            ctime: system_time_to_timestamp(entry.ctime),
        };

        let encoded_payload = encode_mkdir_payload(&payload);

        let txid = match journal::begin_transaction("MKDIR", &encoded_payload) {
            Ok(txid) => txid,

            Err(err) => {
                eprintln!("Failed MKDIR BEGIN: {}", err);
                reply.error(Errno::EIO);
                return;
            }
        };

        maybe_kill9("MKDIR", "after_begin");

        if let Err(err) = journal::commit_transaction(txid) {
            eprintln!("Failed MKDIR COMMIT: {}", err);
            reply.error(Errno::EIO);
            return;
        }

        maybe_kill9("MKDIR", "after_commit");

        if let Err(err) = apply_mkdir_payload(txid, &payload) {
            eprintln!("Committed MKDIR {} apply failed: {}", txid, err);
            reply.error(Errno::EIO);
            return;
        }

        state.entries.insert(ino_value, entry);

        reply.entry(&TTL, &attr, Generation(0));
    }

    fn create(
        &self,
        _req: &Request,
        parent: INodeNo,
        name: &OsStr,
        mode: u32,
        umask: u32,
        _flags: i32,
        reply: ReplyCreate,
    ) {
        if let Err(err) = validate_name(name) {
            reply.error(err);
            return;
        }

        let name = name.to_string_lossy().into_owned();

        let mut state = self.state.lock().unwrap();

        if let Err(err) = check_directory(&state, parent) {
            reply.error(err);
            return;
        }

        if find_child(&state, parent, &name).is_some() {
            reply.error(Errno::EEXIST);
            return;
        }

        let ino_value = state.next_ino;
        state.next_ino += 1;

        let now = SystemTime::now();

        let entry = MemoryEntry {
            ino: INodeNo(ino_value),
            parent,
            name: name.clone(),
            is_dir: false,
            data: Vec::new(),
            perm: (mode & !umask & 0o777) as u16,
            uid: 1000,
            gid: 1000,
            atime: now,
            mtime: now,
            ctime: now,
        };

        let attr = entry_attr(&entry);

        let encoded_payload = encode_create_payload(&entry);

        let txid = match journal::begin_transaction("CREATE", &encoded_payload) {
            Ok(txid) => txid,

            Err(err) => {
                eprintln!("Failed CREATE BEGIN: {}", err);
                reply.error(Errno::EIO);
                return;
            }
        };

        maybe_kill9("CREATE", "after_begin");

        if let Err(err) = journal::commit_transaction(txid) {
            eprintln!("Failed CREATE COMMIT: {}", err);
            reply.error(Errno::EIO);
            return;
        }

        maybe_kill9("CREATE", "after_commit");

        let payload = CreateJournalPayload {
            ino: ino_value,
            parent: u64::from(parent),
            name: name.clone(),
            perm: entry.perm,
            atime: system_time_to_timestamp(entry.atime),
            mtime: system_time_to_timestamp(entry.mtime),
            ctime: system_time_to_timestamp(entry.ctime),
        };

        if let Err(err) = apply_create_payload(txid, &payload) {
            eprintln!("Committed CREATE {} apply failed: {}", txid, err);
            reply.error(Errno::EIO);
            return;
        }

        state.entries.insert(ino_value, entry);

        reply.created(
            &TTL,
            &attr,
            Generation(0),
            FileHandle(0),
            FopenFlags::empty(),
        );
    }

    fn unlink(&self, _req: &Request, parent: INodeNo, name: &OsStr, reply: ReplyEmpty) {
        if let Err(err) = validate_name(name) {
            reply.error(err);
            return;
        }

        let name = name.to_string_lossy().into_owned();

        let mut state = self.state.lock().unwrap();

        if let Err(err) = check_directory(&state, parent) {
            reply.error(err);
            return;
        }

        let Some(ino_value) = find_child(&state, parent, &name) else {
            reply.error(Errno::ENOENT);
            return;
        };

        if ino_value == 2 {
            reply.error(Errno::EPERM);
            return;
        }

        let Some(entry) = state.entries.get(&ino_value) else {
            reply.error(Errno::ENOENT);
            return;
        };

        if entry.is_dir {
            reply.error(Errno::EISDIR);
            return;
        }

        let delete_payload = DeleteJournalPayload { ino: ino_value };
        let encoded_payload = encode_delete_payload(&delete_payload);

        let txid = match journal::begin_transaction("DELETE", &encoded_payload) {
            Ok(txid) => txid,

            Err(err) => {
                eprintln!("Failed DELETE BEGIN: {}", err);
                reply.error(Errno::EIO);
                return;
            }
        };

        maybe_kill9("DELETE", "after_begin");

        if let Err(err) = journal::commit_transaction(txid) {
            eprintln!("Failed DELETE COMMIT: {}", err);
            reply.error(Errno::EIO);
            return;
        }

        maybe_kill9("DELETE", "after_commit");

        if let Err(err) = apply_delete_payload(txid, &delete_payload) {
            eprintln!("Committed DELETE {} apply failed: {}", txid, err);
            reply.error(Errno::EIO);
            return;
        }

        state.entries.remove(&ino_value);

        reply.ok();
    }

    fn rmdir(&self, _req: &Request, parent: INodeNo, name: &OsStr, reply: ReplyEmpty) {
        if let Err(err) = validate_name(name) {
            reply.error(err);
            return;
        }

        let name = name.to_string_lossy().into_owned();

        let mut state = self.state.lock().unwrap();

        if let Err(err) = check_directory(&state, parent) {
            reply.error(err);
            return;
        }

        let Some(ino_value) = find_child(&state, parent, &name) else {
            reply.error(Errno::ENOENT);
            return;
        };

        let Some(entry) = state.entries.get(&ino_value) else {
            reply.error(Errno::ENOENT);
            return;
        };

        if !entry.is_dir {
            reply.error(Errno::ENOTDIR);
            return;
        }

        let directory_ino = entry.ino;

        if state
            .entries
            .values()
            .any(|child| child.parent == directory_ino)
        {
            reply.error(Errno::ENOTEMPTY);
            return;
        }

        let payload = RmdirJournalPayload { ino: ino_value };
        let encoded_payload = encode_rmdir_payload(&payload);

        let txid = match journal::begin_transaction("RMDIR", &encoded_payload) {
            Ok(txid) => txid,

            Err(err) => {
                eprintln!("Failed RMDIR BEGIN: {}", err);
                reply.error(Errno::EIO);
                return;
            }
        };

        maybe_kill9("RMDIR", "after_begin");

        if let Err(err) = journal::commit_transaction(txid) {
            eprintln!("Failed RMDIR COMMIT: {}", err);
            reply.error(Errno::EIO);
            return;
        }

        maybe_kill9("RMDIR", "after_commit");

        if let Err(err) = apply_rmdir_payload(txid, &payload) {
            eprintln!("Committed RMDIR {} apply failed: {}", txid, err);
            reply.error(Errno::EIO);
            return;
        }

        state.entries.remove(&ino_value);

        reply.ok();
    }

    fn rename(
        &self,
        _req: &Request,
        parent: INodeNo,
        name: &OsStr,
        newparent: INodeNo,
        newname: &OsStr,
        flags: RenameFlags,
        reply: ReplyEmpty,
    ) {
        if let Err(err) = validate_name(name) {
            reply.error(err);
            return;
        }

        if let Err(err) = validate_name(newname) {
            reply.error(err);
            return;
        }

        /*
         * This project currently implements normal POSIX rename()
         * replacement semantics for the no-flags case.
         *
         * RENAME_NOREPLACE / RENAME_EXCHANGE / RENAME_WHITEOUT
         * are intentionally not implemented yet.
         */
        if !flags.is_empty() {
            reply.error(Errno::EINVAL);
            return;
        }

        let old_name = name.to_string_lossy().into_owned();
        let new_name = newname.to_string_lossy().into_owned();

        let mut state = self.state.lock().unwrap();

        if let Err(err) = check_directory(&state, parent) {
            reply.error(err);
            return;
        }

        if let Err(err) = check_directory(&state, newparent) {
            reply.error(err);
            return;
        }

        let Some(ino_value) = find_child(&state, parent, &old_name) else {
            reply.error(Errno::ENOENT);
            return;
        };

        /*
         * hello.txt is CCFS's built-in non-persistent inode.
         * Keep it protected from rename/replacement operations.
         */
        if ino_value == 2 {
            reply.error(Errno::EPERM);
            return;
        }

        if parent == newparent && old_name == new_name {
            reply.ok();
            return;
        }

        let (source_is_dir, source_perm, source_size, source_atime, source_mtime) = {
            let Some(source) = state.entries.get(&ino_value) else {
                reply.error(Errno::ENOENT);
                return;
            };

            (
                source.is_dir,
                source.perm,
                if source.is_dir {
                    0
                } else {
                    source.data.len() as u64
                },
                source.atime,
                source.mtime,
            )
        };

        /*
         * POSIX rename allows the destination to already exist.
         *
         * Compatible destinations are replaced:
         *   file -> file
         *   directory -> empty directory
         *
         * Incompatible type replacement must fail.
         */
        let replaced_ino = find_child(&state, newparent, &new_name);

        if let Some(destination_ino) = replaced_ino {
            if destination_ino == ino_value {
                reply.ok();
                return;
            }

            if destination_ino == 2 {
                reply.error(Errno::EPERM);
                return;
            }

            let (destination_is_dir, destination_entry_ino) = {
                let Some(destination) = state.entries.get(&destination_ino) else {
                    reply.error(Errno::ENOENT);
                    return;
                };

                (destination.is_dir, destination.ino)
            };

            if source_is_dir && !destination_is_dir {
                reply.error(Errno::ENOTDIR);
                return;
            }

            if !source_is_dir && destination_is_dir {
                reply.error(Errno::EISDIR);
                return;
            }

            /*
             * A directory may replace only an empty directory.
             */
            if source_is_dir
                && destination_is_dir
                && state
                    .entries
                    .values()
                    .any(|child| child.parent == destination_entry_ino)
            {
                reply.error(Errno::ENOTEMPTY);
                return;
            }
        }

        /*
         * A directory may never be moved into itself or one of
         * its descendants.
         */
        if source_is_dir && would_create_directory_cycle(&state, ino_value, newparent) {
            reply.error(Errno::EINVAL);
            return;
        }

        let now = SystemTime::now();

        let rename_payload = RenameJournalPayload {
            ino: ino_value,
            replaced_ino,
            new_parent: u64::from(newparent),
            new_name: new_name.clone(),
            is_dir: source_is_dir,
            perm: source_perm,
            size: source_size,
            atime: system_time_to_timestamp(source_atime),
            mtime: system_time_to_timestamp(source_mtime),
            ctime: system_time_to_timestamp(now),
        };

        let encoded_payload = match encode_rename_payload(&rename_payload) {
            Ok(payload) => payload,

            Err(err) => {
                eprintln!("Failed to encode RENAME payload: {}", err);
                reply.error(Errno::EIO);
                return;
            }
        };

        let txid = match journal::begin_transaction("RENAME", &encoded_payload) {
            Ok(txid) => txid,

            Err(err) => {
                eprintln!("Failed RENAME BEGIN: {}", err);
                reply.error(Errno::EIO);
                return;
            }
        };

        maybe_kill9("RENAME", "after_begin");

        if let Err(err) = journal::commit_transaction(txid) {
            eprintln!("Failed RENAME COMMIT: {}", err);
            reply.error(Errno::EIO);
            return;
        }

        maybe_kill9("RENAME", "after_commit");

        if let Err(err) = apply_rename_payload(txid, &rename_payload) {
            eprintln!("Committed RENAME {} apply failed: {}", txid, err);

            reply.error(Errno::EIO);
            return;
        }

        /*
         * Durable metadata/storage apply succeeded.
         * Now mirror the same result in memory.
         */
        if let Some(destination_ino) = replaced_ino {
            if destination_ino != ino_value {
                state.entries.remove(&destination_ino);
            }
        }

        let Some(entry) = state.entries.get_mut(&ino_value) else {
            reply.error(Errno::EIO);
            return;
        };

        entry.parent = newparent;
        entry.name = new_name;
        entry.ctime = now;

        reply.ok();
    }

    fn read(
        &self,
        _req: &Request,
        ino: INodeNo,
        _fh: FileHandle,
        offset: u64,
        size: u32,
        _flags: OpenFlags,
        _lock_owner: Option<LockOwner>,
        reply: ReplyData,
    ) {
        let mut state = self.state.lock().unwrap();

        let Some(entry) = state.entries.get_mut(&u64::from(ino)) else {
            reply.error(Errno::ENOENT);
            return;
        };

        if entry.is_dir {
            reply.error(Errno::EISDIR);
            return;
        }

        let new_atime = SystemTime::now();

        let payload = SetattrJournalPayload {
            ino: u64::from(entry.ino),
            parent: u64::from(entry.parent),
            name: entry.name.clone(),
            is_dir: entry.is_dir,
            perm: entry.perm,
            uid: entry.uid,
            gid: entry.gid,
            size: entry.data.len() as u64,
            atime: system_time_to_timestamp(new_atime),
            mtime: system_time_to_timestamp(entry.mtime),
            ctime: system_time_to_timestamp(entry.ctime),
        };

        let encoded_payload = match encode_setattr_payload(&payload) {
            Ok(encoded) => encoded,

            Err(err) => {
                eprintln!("Failed ATIME payload encode: {}", err);
                reply.error(Errno::EIO);
                return;
            }
        };

        let txid = match journal::begin_transaction("ATIME", &encoded_payload) {
            Ok(txid) => txid,

            Err(err) => {
                eprintln!("Failed ATIME BEGIN: {}", err);
                reply.error(Errno::EIO);
                return;
            }
        };

        maybe_kill9("ATIME", "after_begin");

        if let Err(err) = journal::commit_transaction(txid) {
            eprintln!("Failed ATIME COMMIT: {}", err);
            reply.error(Errno::EIO);
            return;
        }

        maybe_kill9("ATIME", "after_commit");

        if let Err(err) = apply_setattr_payload(txid, &payload) {
            eprintln!("Committed ATIME {} apply failed: {}", txid, err);
            reply.error(Errno::EIO);
            return;
        }

        entry.atime = new_atime;

        let start = match usize::try_from(offset) {
            Ok(value) => value,

            Err(_) => {
                reply.error(Errno::EFBIG);
                return;
            }
        };

        if start >= entry.data.len() {
            reply.data(&[]);
            return;
        }

        let size = size as usize;

        let end = start.saturating_add(size).min(entry.data.len());

        reply.data(&entry.data[start..end]);
    }

    fn write(
        &self,
        _req: &Request,
        ino: INodeNo,
        _fh: FileHandle,
        offset: u64,
        data: &[u8],
        _write_flags: WriteFlags,
        _flags: OpenFlags,
        _lock_owner: Option<LockOwner>,
        reply: ReplyWrite,
    ) {
        let mut state = self.state.lock().unwrap();

        let Some(entry) = state.entries.get_mut(&u64::from(ino)) else {
            reply.error(Errno::ENOENT);
            return;
        };

        if entry.is_dir {
            reply.error(Errno::EISDIR);
            return;
        }

        let start = match usize::try_from(offset) {
            Ok(value) => value,

            Err(_) => {
                reply.error(Errno::EFBIG);
                return;
            }
        };

        let end = match start.checked_add(data.len()) {
            Some(value) => value,

            None => {
                reply.error(Errno::EFBIG);
                return;
            }
        };

        let mut final_data = entry.data.clone();

        if final_data.len() < start {
            final_data.resize(start, 0);
        }

        if final_data.len() < end {
            final_data.resize(end, 0);
        }

        final_data[start..end].copy_from_slice(data);

        let now = SystemTime::now();

        let payload = WriteJournalPayload {
            ino: u64::from(entry.ino),
            parent: u64::from(entry.parent),
            name: entry.name.clone(),
            perm: entry.perm,
            atime: system_time_to_timestamp(entry.atime),
            mtime: system_time_to_timestamp(now),
            ctime: system_time_to_timestamp(now),
            data: final_data.clone(),
        };

        let encoded = match encode_write_payload(&payload) {
            Ok(encoded) => encoded,

            Err(err) => {
                eprintln!("Failed WRITE payload encode: {}", err);
                reply.error(Errno::EIO);
                return;
            }
        };

        let txid = match journal::begin_transaction("WRITE", &encoded) {
            Ok(txid) => txid,

            Err(err) => {
                eprintln!("Failed WRITE BEGIN: {}", err);

                if err.raw_os_error() == Some(28) {
                    reply.error(Errno::ENOSPC);
                } else {
                    reply.error(Errno::EIO);
                }
                return;
            }
        };

        maybe_kill9("WRITE", "after_begin");

        if let Err(err) = journal::commit_transaction(txid) {
            eprintln!("Failed WRITE COMMIT: {}", err);

            if err.raw_os_error() == Some(28) {
                reply.error(Errno::ENOSPC);
            } else {
                reply.error(Errno::EIO);
            }
            return;
        }

        maybe_kill9("WRITE", "after_commit");

        if let Err(err) = apply_write_payload(txid, &payload) {
            eprintln!("Committed WRITE {} apply failed: {}", txid, err);

            if err.raw_os_error() == Some(28) {
                reply.error(Errno::ENOSPC);
            } else {
                reply.error(Errno::EIO);
            }
            return;
        }

        entry.data = final_data;
        entry.mtime = now;
        entry.ctime = now;

        reply.written(data.len() as u32);
    }

    fn flush(
        &self,
        _req: &Request,
        ino: INodeNo,
        _fh: FileHandle,
        _lock_owner: LockOwner,
        reply: ReplyEmpty,
    ) {
        {
            let state = self.state.lock().unwrap();

            let Some(entry) = state.entries.get(&u64::from(ino)) else {
                reply.error(Errno::ENOENT);
                return;
            };

            if entry.is_dir {
                reply.error(Errno::EISDIR);
                return;
            }

            /*
             * inode 2 is the built-in hello.txt entry.
             * It does not have a persistent block on disk.
             */
            if u64::from(ino) == 2 {
                reply.ok();
                return;
            }
        }

        if let Err(err) = storage::sync_file_data(u64::from(ino), false) {
            eprintln!(
                "Failed FLUSH durability sync for inode {}: {}",
                u64::from(ino),
                err
            );

            reply.error(Errno::EIO);
            return;
        }

        reply.ok();
    }

    fn fsync(
        &self,
        _req: &Request,
        ino: INodeNo,
        _fh: FileHandle,
        datasync: bool,
        reply: ReplyEmpty,
    ) {
        {
            let state = self.state.lock().unwrap();

            let Some(entry) = state.entries.get(&u64::from(ino)) else {
                reply.error(Errno::ENOENT);
                return;
            };

            if entry.is_dir {
                reply.error(Errno::EISDIR);
                return;
            }

            /*
             * inode 2 is the built-in hello.txt entry.
             * It does not have a persistent block on disk.
             */
            if u64::from(ino) == 2 {
                reply.ok();
                return;
            }
        }

        if let Err(err) = storage::sync_file_data(u64::from(ino), datasync) {
            eprintln!(
                "Failed FSYNC durability sync for inode {}: {}",
                u64::from(ino),
                err
            );

            reply.error(Errno::EIO);
            return;
        }

        reply.ok();
    }
}

/* ============================================================
 * MAIN
 * ============================================================
 */

fn main() {
    let args: Vec<String> = env::args().collect();

    if args.len() > 1 {
        match args[1].as_str() {
            "--migrate-checksums" => {
                migrate_checksums();
                return;
            }

            "--check-integrity" => {
                check_integrity();
                return;
            }

            "--recovery-status" => {
                show_recovery_status();
                return;
            }

            "--checkpoint" => {
                run_checkpoint();
                return;
            }

            "--snapshot-create" => {
                if args.len() != 3 {
                    eprintln!("Usage: ccfs --snapshot-create <name>");
                    process::exit(2);
                }

                match snapshot::create_snapshot(&args[2]) {
                    Ok(summary) => {
                        println!("Snapshot created: {}", summary.name);
                        println!("Files captured: {}", summary.files);
                    }

                    Err(err) => {
                        eprintln!("Snapshot creation failed: {}", err);
                        process::exit(1);
                    }
                }

                return;
            }

            "--snapshot-list" => {
                if args.len() != 2 {
                    eprintln!("Usage: ccfs --snapshot-list");
                    process::exit(2);
                }

                match snapshot::list_snapshots() {
                    Ok(snapshots) => {
                        println!("CCFS snapshots");
                        println!("--------------");

                        if snapshots.is_empty() {
                            println!("No snapshots.");
                        } else {
                            for name in snapshots {
                                println!("{}", name);
                            }
                        }
                    }

                    Err(err) => {
                        eprintln!("Snapshot listing failed: {}", err);
                        process::exit(1);
                    }
                }

                return;
            }

            "--snapshot-read" => {
                if args.len() != 4 {
                    eprintln!("Usage: ccfs --snapshot-read <name> <path>");
                    process::exit(2);
                }

                match snapshot::read_snapshot_file(&args[2], &args[3]) {
                    Ok(data) => {
                        let mut stdout = std::io::stdout();

                        if let Err(err) = std::io::Write::write_all(&mut stdout, &data) {
                            eprintln!("Snapshot read output failed: {}", err);
                            process::exit(1);
                        }

                        if let Err(err) = std::io::Write::flush(&mut stdout) {
                            eprintln!("Snapshot read flush failed: {}", err);
                            process::exit(1);
                        }
                    }

                    Err(err) => {
                        eprintln!("Snapshot read failed: {}", err);
                        process::exit(1);
                    }
                }

                return;
            }

            "--snapshot-verify" => {
                if args.len() != 3 {
                    eprintln!("Usage: ccfs --snapshot-verify <name>");
                    process::exit(2);
                }

                match snapshot::verify_snapshot(&args[2]) {
                    Ok(summary) => {
                        println!("Snapshot verified: {}", summary.name);

                        println!("Files checked: {}", summary.files_checked);
                    }

                    Err(err) => {
                        eprintln!("Snapshot verification failed: {}", err);
                        process::exit(1);
                    }
                }

                return;
            }

            "--snapshot-restore" => {
                if args.len() != 3 {
                    eprintln!("Usage: ccfs --snapshot-restore <name>");
                    process::exit(2);
                }

                match snapshot::restore_snapshot(&args[2]) {
                    Ok(summary) => {
                        println!("Snapshot restored: {}", summary.name);

                        println!("Files restored: {}", summary.files_restored);
                    }

                    Err(err) => {
                        eprintln!("Snapshot restore failed: {}", err);
                        process::exit(1);
                    }
                }

                return;
            }

            "--snapshot-delete" => {
                if args.len() != 3 {
                    eprintln!("Usage: ccfs --snapshot-delete <name>");
                    process::exit(2);
                }

                match snapshot::delete_snapshot(&args[2]) {
                    Ok(()) => {
                        println!("Snapshot deleted: {}", args[2]);
                    }

                    Err(err) => {
                        eprintln!("Snapshot deletion failed: {}", err);
                        process::exit(1);
                    }
                }

                return;
            }

            "--help" | "-h" => {
                print_usage();
                return;
            }

            unknown => {
                eprintln!("Unknown argument: {}", unknown);

                print_usage();

                process::exit(2);
            }
        }
    }

    let _db = db::init_database().expect("Failed to initialize SQLite database");

    println!("SQLite metadata database ready.");

    println!("CCFS journal recovery starting...");

    let recovery_summary = match run_startup_recovery() {
        Ok(summary) => summary,

        Err(err) => {
            eprintln!("CCFS recovery failed: {}", err);

            process::exit(1);
        }
    };

    println!("Journal recovery completed.");

    println!(
        "  total transactions: {}",
        recovery_summary.total_transactions
    );

    println!("  committed: {}", recovery_summary.committed_transactions);

    println!(
        "  incomplete ignored: {}",
        recovery_summary.incomplete_transactions
    );

    println!("  replayed: {}", recovery_summary.replayed_transactions);

    println!(
        "  already applied: {}",
        recovery_summary.already_applied_transactions
    );

    let mountpoint = "mount";

    let mut config = Config::default();

    config
        .mount_options
        .push(MountOption::FSName("ccfs".to_string()));

    println!("CCFS metadata-aware filesystem mounting at: {}", mountpoint);

    println!("Press Ctrl+C to stop the filesystem.");

    fuser::mount(Ccfs::new(), mountpoint, &config).expect("Failed to mount CCFS");
}
