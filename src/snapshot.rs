use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{Connection, OptionalExtension};

const VOLUME_DIR: &str = "volume";
const LIVE_BLOCK_DIR: &str = "volume/blocks";
const LIVE_METADATA_DB: &str = "volume/metadata.db";
const LIVE_JOURNAL: &str = "volume/journal.log";
const SNAPSHOT_ROOT: &str = "volume/snapshots";
const MOUNT_DIR: &str = "mount";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SnapshotCreateSummary {
    pub name: String,
    pub files: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SnapshotVerifySummary {
    pub name: String,
    pub files_checked: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SnapshotRestoreSummary {
    pub name: String,
    pub files_restored: usize,
}

fn maybe_snapshot_kill9(point: &str) {
    let requested = std::env::var("CCFS_SNAPSHOT_KILL9_POINT").ok();

    if requested.as_deref() != Some(point) {
        return;
    }

    eprintln!("CCFS snapshot SIGKILL failpoint triggered: {}", point);

    let _ = std::process::Command::new("kill")
        .arg("-9")
        .arg(std::process::id().to_string())
        .status();

    std::process::abort();
}

fn database_error(error: rusqlite::Error) -> io::Error {
    io::Error::new(
        io::ErrorKind::Other,
        format!("snapshot database error: {error}"),
    )
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

fn sync_directory(path: &Path) -> io::Result<()> {
    let directory = File::open(path)?;
    directory.sync_all()
}

fn write_synced_file(path: &Path, data: &[u8]) -> io::Result<()> {
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

fn copy_synced_file(source: &Path, destination: &Path) -> io::Result<()> {
    let mut input = File::open(source)?;

    let mut output = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(destination)?;

    io::copy(&mut input, &mut output)?;

    output.flush()?;
    output.sync_all()?;

    Ok(())
}

fn validate_snapshot_name(name: &str) -> io::Result<()> {
    if name.is_empty() || name.len() > 128 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "snapshot name must contain 1..128 characters",
        ));
    }

    if name == "." || name == ".." || name.starts_with('.') {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "snapshot name may not start with '.'",
        ));
    }

    if !name.chars().all(|character| {
        character.is_ascii_alphanumeric()
            || character == '-'
            || character == '_'
            || character == '.'
    }) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "snapshot name may contain only letters, digits, '-', '_' and '.'",
        ));
    }

    Ok(())
}

fn snapshot_path(name: &str) -> PathBuf {
    Path::new(SNAPSHOT_ROOT).join(name)
}

fn snapshot_blocks_path(name: &str) -> PathBuf {
    snapshot_path(name).join("blocks")
}

fn snapshot_metadata_path(name: &str) -> PathBuf {
    snapshot_path(name).join("metadata.db")
}

fn mountinfo_unescape(value: &str) -> String {
    value
        .replace("\\040", " ")
        .replace("\\011", "\t")
        .replace("\\012", "\n")
        .replace("\\134", "\\")
}

fn filesystem_is_mounted() -> io::Result<bool> {
    let mount_target = std::env::current_dir()?.join(MOUNT_DIR);

    let contents = match fs::read_to_string("/proc/self/mountinfo") {
        Ok(contents) => contents,

        Err(err) if err.kind() == io::ErrorKind::NotFound => {
            return Ok(false);
        }

        Err(err) => return Err(err),
    };

    for line in contents.lines() {
        let fields: Vec<&str> = line.split_whitespace().collect();

        if fields.len() < 5 {
            continue;
        }

        let mount_point = PathBuf::from(mountinfo_unescape(fields[4]));

        if mount_point == mount_target {
            return Ok(true);
        }
    }

    Ok(false)
}

fn require_offline_filesystem() -> io::Result<()> {
    if filesystem_is_mounted()? {
        return Err(io::Error::new(
            io::ErrorKind::Other,
            "CCFS must be unmounted before creating or restoring a snapshot",
        ));
    }

    Ok(())
}

fn checkpoint_live_metadata() -> io::Result<()> {
    if !Path::new(LIVE_METADATA_DB).exists() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "volume/metadata.db does not exist",
        ));
    }

    let conn = Connection::open(LIVE_METADATA_DB).map_err(database_error)?;

    conn.pragma_update(None, "synchronous", "FULL")
        .map_err(database_error)?;

    let _: (i64, i64, i64) = conn
        .query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?))
        })
        .map_err(database_error)?;

    Ok(())
}

fn prepare_snapshot_root() -> io::Result<()> {
    fs::create_dir_all(SNAPSHOT_ROOT)?;
    sync_directory(Path::new(VOLUME_DIR))?;

    Ok(())
}

fn remove_stale_snapshot_temp(name: &str) -> io::Result<()> {
    let prefix = format!(".creating-{name}-");

    if !Path::new(SNAPSHOT_ROOT).exists() {
        return Ok(());
    }

    for entry in fs::read_dir(SNAPSHOT_ROOT)? {
        let entry = entry?;

        if !entry.file_type()?.is_dir() {
            continue;
        }

        let file_name = entry.file_name();
        let file_name = file_name.to_string_lossy();

        if file_name.starts_with(&prefix) {
            fs::remove_dir_all(entry.path())?;
        }
    }

    Ok(())
}

fn live_block_files() -> io::Result<Vec<PathBuf>> {
    fs::create_dir_all(LIVE_BLOCK_DIR)?;

    let mut files = Vec::new();

    for entry in fs::read_dir(LIVE_BLOCK_DIR)? {
        let entry = entry?;

        if !entry.file_type()?.is_file() {
            continue;
        }

        let name = entry.file_name();
        let name = name.to_string_lossy();

        if name.ends_with(".bin") || name.ends_with(".checksum") {
            files.push(entry.path());
        }
    }

    files.sort();

    Ok(files)
}

fn count_bin_files(directory: &Path) -> io::Result<usize> {
    if !directory.exists() {
        return Ok(0);
    }

    let mut count = 0usize;

    for entry in fs::read_dir(directory)? {
        let entry = entry?;

        if !entry.file_type()?.is_file() {
            continue;
        }

        if entry.file_name().to_string_lossy().ends_with(".bin") {
            count += 1;
        }
    }

    Ok(count)
}

fn verify_block_pair(blocks_directory: &Path, ino: u64) -> io::Result<()> {
    let data_path = blocks_directory.join(format!("{ino}.bin"));

    let checksum_path = blocks_directory.join(format!("{ino}.checksum"));

    if !data_path.exists() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!("snapshot inode {ino} data block missing"),
        ));
    }

    if !checksum_path.exists() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!("snapshot inode {ino} checksum missing"),
        ));
    }

    let data = fs::read(&data_path)?;

    let expected_text = fs::read_to_string(&checksum_path)?;

    let expected = u64::from_str_radix(expected_text.trim(), 16).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("snapshot inode {ino} checksum file is invalid"),
        )
    })?;

    let actual = checksum(&data);

    if expected != actual {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "snapshot inode {ino} checksum mismatch: \
                 expected {expected:016x}, actual {actual:016x}"
            ),
        ));
    }

    Ok(())
}

fn verify_snapshot_directory(directory: &Path) -> io::Result<usize> {
    let metadata_path = directory.join("metadata.db");
    let blocks_path = directory.join("blocks");

    if !metadata_path.exists() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "snapshot metadata.db missing",
        ));
    }

    if !blocks_path.is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "snapshot blocks directory missing",
        ));
    }

    let conn = Connection::open(&metadata_path).map_err(database_error)?;

    let mut stmt = conn
        .prepare(
            "
            SELECT ino
            FROM entries
            WHERE kind = 0
            ORDER BY ino
            ",
        )
        .map_err(database_error)?;

    let rows = stmt
        .query_map([], |row| row.get::<_, i64>(0))
        .map_err(database_error)?;

    let mut checked = 0usize;

    for row in rows {
        let ino = row.map_err(database_error)? as u64;

        verify_block_pair(&blocks_path, ino)?;

        checked += 1;
    }

    Ok(checked)
}

fn manifest_contents(name: &str, files: usize) -> String {
    let created_at = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();

    format!(
        "CCFS_SNAPSHOT_V1\n\
         name={name}\n\
         created_at={created_at}\n\
         files={files}\n"
    )
}

pub fn create_snapshot(name: &str) -> io::Result<SnapshotCreateSummary> {
    validate_snapshot_name(name)?;
    require_offline_filesystem()?;

    prepare_snapshot_root()?;
    remove_stale_snapshot_temp(name)?;

    let final_path = snapshot_path(name);

    if final_path.exists() {
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            format!("snapshot '{name}' already exists"),
        ));
    }

    checkpoint_live_metadata()?;

    let temp_name = format!(".creating-{}-{}", name, std::process::id(),);

    let temp_path = Path::new(SNAPSHOT_ROOT).join(temp_name);

    let temp_blocks = temp_path.join("blocks");

    if temp_path.exists() {
        fs::remove_dir_all(&temp_path)?;
    }

    fs::create_dir_all(&temp_blocks)?;

    let result = (|| -> io::Result<SnapshotCreateSummary> {
        copy_synced_file(Path::new(LIVE_METADATA_DB), &temp_path.join("metadata.db"))?;

        for source in live_block_files()? {
            let file_name = source.file_name().ok_or_else(|| {
                io::Error::new(io::ErrorKind::InvalidData, "block path has no filename")
            })?;

            let destination = temp_blocks.join(file_name);

            /*
             * Copy-on-Write snapshot:
             *
             * Snapshot and live storage initially share the
             * same immutable inode through a hard link.
             *
             * CCFS live writes replace .bin/.checksum files
             * using temp-file + atomic rename, so future writes
             * create new live inodes while the snapshot keeps
             * the old block unchanged.
             */
            fs::hard_link(&source, &destination)?;
        }

        sync_directory(&temp_blocks)?;

        maybe_snapshot_kill9("after_blocks");

        let files = verify_snapshot_directory(&temp_path)?;

        let manifest = manifest_contents(name, files);

        write_synced_file(&temp_path.join("manifest.txt"), manifest.as_bytes())?;

        sync_directory(&temp_path)?;

        maybe_snapshot_kill9("before_publish");

        /*
         * Atomic visibility point:
         * a crash before this rename leaves only a hidden
         * .creating-* directory, never a half-valid snapshot.
         */
        fs::rename(&temp_path, &final_path)?;

        sync_directory(Path::new(SNAPSHOT_ROOT))?;

        maybe_snapshot_kill9("after_publish");

        Ok(SnapshotCreateSummary {
            name: name.to_string(),
            files,
        })
    })();

    if result.is_err() && temp_path.exists() {
        let _ = fs::remove_dir_all(&temp_path);
    }

    result
}

pub fn list_snapshots() -> io::Result<Vec<String>> {
    prepare_snapshot_root()?;

    let mut snapshots = Vec::new();

    for entry in fs::read_dir(SNAPSHOT_ROOT)? {
        let entry = entry?;

        if !entry.file_type()?.is_dir() {
            continue;
        }

        let name = entry.file_name().to_string_lossy().into_owned();

        /*
         * Hidden .creating-* directories are incomplete
         * snapshot attempts and are never exposed as valid
         * snapshots.
         */
        if name.starts_with('.') {
            continue;
        }

        if entry.path().join("metadata.db").exists() && entry.path().join("blocks").is_dir() {
            snapshots.push(name);
        }
    }

    snapshots.sort();

    Ok(snapshots)
}

pub fn verify_snapshot(name: &str) -> io::Result<SnapshotVerifySummary> {
    validate_snapshot_name(name)?;

    let directory = snapshot_path(name);

    if !directory.is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!("snapshot '{name}' does not exist"),
        ));
    }

    let files_checked = verify_snapshot_directory(&directory)?;

    Ok(SnapshotVerifySummary {
        name: name.to_string(),
        files_checked,
    })
}

fn resolve_snapshot_inode(name: &str, path: &str) -> io::Result<(u64, bool)> {
    validate_snapshot_name(name)?;

    let metadata_path = snapshot_metadata_path(name);

    if !metadata_path.exists() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!("snapshot '{name}' does not exist"),
        ));
    }

    let components: Vec<&str> = path
        .split('/')
        .filter(|component| !component.is_empty())
        .collect();

    if components.is_empty() {
        return Ok((1, true));
    }

    let conn = Connection::open(metadata_path).map_err(database_error)?;

    let mut parent = 1u64;

    for (index, component) in components.iter().enumerate() {
        if *component == "." || *component == ".." {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "snapshot path may not contain '.' or '..'",
            ));
        }

        let found: Option<(i64, i64)> = conn
            .query_row(
                "
                SELECT ino, kind
                FROM entries
                WHERE parent = ?1
                  AND name = ?2
                LIMIT 1
                ",
                rusqlite::params![parent as i64, component,],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()
            .map_err(database_error)?;

        let Some((ino, kind)) = found else {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!("path '{}' does not exist in snapshot '{}'", path, name,),
            ));
        };

        let is_dir = kind != 0;

        if index + 1 < components.len() && !is_dir {
            return Err(io::Error::new(
                io::ErrorKind::NotADirectory,
                format!("'{}' is not a directory in snapshot '{}'", component, name,),
            ));
        }

        parent = ino as u64;

        if index + 1 == components.len() {
            return Ok((ino as u64, is_dir));
        }
    }

    Err(io::Error::new(
        io::ErrorKind::NotFound,
        "unable to resolve snapshot path",
    ))
}

pub fn read_snapshot_file(name: &str, path: &str) -> io::Result<Vec<u8>> {
    let (ino, is_dir) = resolve_snapshot_inode(name, path)?;

    if is_dir {
        return Err(io::Error::new(
            io::ErrorKind::IsADirectory,
            format!("'{path}' is a directory in snapshot '{name}'"),
        ));
    }

    let blocks = snapshot_blocks_path(name);

    verify_block_pair(&blocks, ino)?;

    fs::read(blocks.join(format!("{ino}.bin")))
}

fn prepare_restore_blocks(snapshot_name: &str, destination: &Path) -> io::Result<usize> {
    let source = snapshot_blocks_path(snapshot_name);

    fs::create_dir_all(destination)?;

    let mut restored = 0usize;

    for entry in fs::read_dir(source)? {
        let entry = entry?;

        if !entry.file_type()?.is_file() {
            continue;
        }

        let file_name = entry.file_name();
        let file_name_text = file_name.to_string_lossy();

        if !file_name_text.ends_with(".bin") && !file_name_text.ends_with(".checksum") {
            continue;
        }

        fs::hard_link(entry.path(), destination.join(&file_name))?;

        if file_name_text.ends_with(".bin") {
            restored += 1;
        }
    }

    sync_directory(destination)?;

    Ok(restored)
}

fn clear_restored_applied_transactions(metadata_path: &Path) -> io::Result<()> {
    let conn = Connection::open(metadata_path).map_err(database_error)?;

    conn.pragma_update(None, "synchronous", "FULL")
        .map_err(database_error)?;

    conn.execute("DELETE FROM applied_tx", [])
        .map_err(database_error)?;

    let _: (i64, i64, i64) = conn
        .query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?))
        })
        .map_err(database_error)?;

    Ok(())
}

pub fn restore_snapshot(name: &str) -> io::Result<SnapshotRestoreSummary> {
    validate_snapshot_name(name)?;
    require_offline_filesystem()?;

    verify_snapshot(name)?;

    fs::create_dir_all(VOLUME_DIR)?;

    let pid = std::process::id();

    let new_blocks = Path::new(VOLUME_DIR).join(format!(".restore-new-blocks-{pid}"));

    let old_blocks = Path::new(VOLUME_DIR).join(format!(".restore-old-blocks-{pid}"));

    let new_metadata = Path::new(VOLUME_DIR).join(format!(".restore-new-metadata-{pid}.db"));

    let old_metadata = Path::new(VOLUME_DIR).join(format!(".restore-old-metadata-{pid}.db"));

    for path in [&new_blocks, &old_blocks] {
        if path.exists() {
            fs::remove_dir_all(path)?;
        }
    }

    for path in [&new_metadata, &old_metadata] {
        if path.exists() {
            fs::remove_file(path)?;
        }
    }

    let files_restored = prepare_restore_blocks(name, &new_blocks)?;

    copy_synced_file(&snapshot_metadata_path(name), &new_metadata)?;

    /*
     * A restored snapshot starts with a clean recovery ledger.
     * Its old applied_tx rows refer to historical journal records
     * that are not part of the restored live journal.
     */
    clear_restored_applied_transactions(&new_metadata)?;

    sync_directory(Path::new(VOLUME_DIR))?;

    checkpoint_live_metadata()?;

    let live_blocks = Path::new(LIVE_BLOCK_DIR);
    let live_metadata = Path::new(LIVE_METADATA_DB);

    let mut moved_old_blocks = false;
    let mut installed_new_blocks = false;
    let mut moved_old_metadata = false;

    let swap_result = (|| -> io::Result<()> {
        if live_blocks.exists() {
            fs::rename(live_blocks, &old_blocks)?;

            moved_old_blocks = true;
        }

        fs::rename(&new_blocks, live_blocks)?;

        installed_new_blocks = true;

        if live_metadata.exists() {
            fs::rename(live_metadata, &old_metadata)?;

            moved_old_metadata = true;
        }

        fs::rename(&new_metadata, live_metadata)?;

        /*
         * The restored metadata is now paired with the restored
         * COW blocks. Remove old WAL/SHM side files and start with
         * an empty recovery journal so pre-restore operations
         * cannot replay into the restored state.
         */
        let wal_path = Path::new("volume/metadata.db-wal");

        let shm_path = Path::new("volume/metadata.db-shm");

        if wal_path.exists() {
            fs::remove_file(wal_path)?;
        }

        if shm_path.exists() {
            fs::remove_file(shm_path)?;
        }

        write_synced_file(Path::new(LIVE_JOURNAL), b"")?;

        sync_directory(Path::new(VOLUME_DIR))?;

        Ok(())
    })();

    if let Err(err) = swap_result {
        /*
         * Best-effort rollback for ordinary I/O failures.
         */
        if live_metadata.exists() && moved_old_metadata {
            let _ = fs::remove_file(live_metadata);
        }

        if moved_old_metadata && old_metadata.exists() {
            let _ = fs::rename(&old_metadata, live_metadata);
        }

        if installed_new_blocks && live_blocks.exists() {
            let _ = fs::remove_dir_all(live_blocks);
        }

        if moved_old_blocks && old_blocks.exists() {
            let _ = fs::rename(&old_blocks, live_blocks);
        }

        let _ = sync_directory(Path::new(VOLUME_DIR));

        return Err(err);
    }

    if old_blocks.exists() {
        fs::remove_dir_all(&old_blocks)?;
    }

    if old_metadata.exists() {
        fs::remove_file(&old_metadata)?;
    }

    sync_directory(Path::new(VOLUME_DIR))?;

    Ok(SnapshotRestoreSummary {
        name: name.to_string(),
        files_restored,
    })
}

pub fn delete_snapshot(name: &str) -> io::Result<()> {
    validate_snapshot_name(name)?;

    let path = snapshot_path(name);

    if !path.exists() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!("snapshot '{name}' does not exist"),
        ));
    }

    fs::remove_dir_all(path)?;

    sync_directory(Path::new(SNAPSHOT_ROOT))?;

    Ok(())
}

pub fn snapshot_block_link_count(name: &str, ino: u64) -> io::Result<u64> {
    validate_snapshot_name(name)?;

    let path = snapshot_blocks_path(name).join(format!("{ino}.bin"));

    let metadata = fs::metadata(path)?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;

        return Ok(metadata.nlink());
    }

    #[allow(unreachable_code)]
    Ok(1)
}

pub fn snapshot_file_count(name: &str) -> io::Result<usize> {
    validate_snapshot_name(name)?;

    count_bin_files(&snapshot_blocks_path(name))
}
