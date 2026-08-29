use std::fs::{self, File};
use std::io;
use std::path::{Path, PathBuf};

const BLOCK_DIR: &str = "volume/blocks";

fn data_path(ino: u64) -> PathBuf {
    Path::new(BLOCK_DIR).join(format!("{ino}.bin"))
}

fn checksum_path(ino: u64) -> PathBuf {
    Path::new(BLOCK_DIR).join(format!("{ino}.checksum"))
}

fn data_temp_path(ino: u64) -> PathBuf {
    Path::new(BLOCK_DIR).join(format!(".{ino}.bin.tmp"))
}

fn checksum_temp_path(ino: u64) -> PathBuf {
    Path::new(BLOCK_DIR).join(format!(".{ino}.checksum.tmp"))
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

fn sync_block_directory() -> io::Result<()> {
    fs::create_dir_all(BLOCK_DIR)?;

    let directory = File::open(BLOCK_DIR)?;

    directory.sync_all()?;

    Ok(())
}

fn write_synced_file(path: &Path, data: &[u8]) -> io::Result<()> {
    fs::write(path, data)?;

    let file = File::open(path)?;

    file.sync_all()?;

    Ok(())
}

fn write_checksum(ino: u64, data: &[u8]) -> io::Result<()> {
    fs::create_dir_all(BLOCK_DIR)?;

    let value = checksum(data);

    let final_path = checksum_path(ino);
    let temp_path = checksum_temp_path(ino);

    let contents = format!("{value:016x}\n");

    write_synced_file(&temp_path, contents.as_bytes())?;

    fs::rename(&temp_path, &final_path)?;

    /*
     * Persist the checksum rename itself.
     *
     * sync_all() on the file protects the file contents,
     * while syncing the directory protects the filename /
     * rename operation across a power loss.
     */
    sync_block_directory()?;

    Ok(())
}

fn read_expected_checksum(ino: u64) -> io::Result<u64> {
    let contents = fs::read_to_string(checksum_path(ino))?;

    u64::from_str_radix(contents.trim(), 16).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("Invalid checksum file for inode {ino}"),
        )
    })
}

fn maybe_enospc(point: &str) -> io::Result<()> {
    let requested = std::env::var("CCFS_ENOSPC_POINT").ok();

    if requested.as_deref() != Some(point) {
        return Ok(());
    }

    eprintln!("CCFS ENOSPC failpoint triggered: {}", point);

    Err(io::Error::from_raw_os_error(28))
}

pub fn save_file_data(ino: u64, data: &[u8]) -> io::Result<()> {
    fs::create_dir_all(BLOCK_DIR)?;

    let final_path = data_path(ino);
    let temp_path = data_temp_path(ino);

    /*
     * Write the new data to a temporary file first.
     *
     * The temporary file is fully synced before rename so
     * the final block never points at partially-written data.
     */
    maybe_enospc("data_write")?;

    write_synced_file(&temp_path, data)?;

    /*
     * Atomically publish the new data block.
     */
    fs::rename(&temp_path, &final_path)?;

    /*
     * Write and durably publish the checksum.
     *
     * write_checksum() also syncs BLOCK_DIR after its rename.
     * Because the data rename happened in the same directory
     * before that directory sync, both directory updates are
     * durable before this function returns.
     */
    write_checksum(ino, data)?;

    Ok(())
}

pub fn sync_file_data(ino: u64, data_only: bool) -> io::Result<()> {
    let data_file = File::open(data_path(ino))?;

    if data_only {
        data_file.sync_data()?;
    } else {
        data_file.sync_all()?;
    }

    /*
     * The checksum is required to validate the durable data,
     * so it must also reach stable storage.
     */
    let checksum_file = File::open(checksum_path(ino))?;

    checksum_file.sync_all()?;

    /*
     * Ensure block/checksum directory entries and renames are
     * also durable.
     */
    sync_block_directory()?;

    Ok(())
}

pub fn load_file_data(ino: u64) -> io::Result<Vec<u8>> {
    let data = fs::read(data_path(ino))?;

    /*
     * Legacy migration:
     *
     * Files created before checksum support already have .bin files
     * but do not have .checksum files.
     *
     * On first successful load, create a checksum from the current
     * persisted data. Future reads will verify it normally.
     */
    if !checksum_path(ino).exists() {
        write_checksum(ino, &data)?;

        return Ok(data);
    }

    let expected = read_expected_checksum(ino)?;
    let actual = checksum(&data);

    if expected != actual {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "Checksum mismatch for inode {ino}: \
                 expected {expected:016x}, actual {actual:016x}"
            ),
        ));
    }

    Ok(data)
}

pub fn delete_file_data(ino: u64) -> io::Result<()> {
    let data_file = data_path(ino);
    let checksum_file = checksum_path(ino);

    match fs::remove_file(&data_file) {
        Ok(()) => {}

        Err(err) if err.kind() == io::ErrorKind::NotFound => {}

        Err(err) => {
            return Err(err);
        }
    }

    match fs::remove_file(&checksum_file) {
        Ok(()) => {}

        Err(err) if err.kind() == io::ErrorKind::NotFound => {}

        Err(err) => {
            return Err(err);
        }
    }

    /*
     * fsync the directory so deletion of the data/checksum
     * names survives a power loss.
     */
    sync_block_directory()?;

    Ok(())
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IntegrityStatus {
    Healthy,
    MissingData,
    MissingChecksum,
    Corrupted { expected: u64, actual: u64 },
}

pub fn verify_file_data(ino: u64) -> io::Result<IntegrityStatus> {
    let data_file = data_path(ino);
    let checksum_file = checksum_path(ino);

    if !data_file.exists() {
        return Ok(IntegrityStatus::MissingData);
    }

    if !checksum_file.exists() {
        return Ok(IntegrityStatus::MissingChecksum);
    }

    let data = fs::read(data_file)?;

    let expected = read_expected_checksum(ino)?;
    let actual = checksum(&data);

    if expected == actual {
        Ok(IntegrityStatus::Healthy)
    } else {
        Ok(IntegrityStatus::Corrupted { expected, actual })
    }
}

pub fn list_block_inodes() -> io::Result<Vec<u64>> {
    fs::create_dir_all(BLOCK_DIR)?;

    let mut inodes = Vec::new();

    for entry in fs::read_dir(BLOCK_DIR)? {
        let entry = entry?;

        if !entry.file_type()?.is_file() {
            continue;
        }

        let name = entry.file_name();
        let name = name.to_string_lossy();

        let Some(raw_ino) = name.strip_suffix(".bin") else {
            continue;
        };

        let Ok(ino) = raw_ino.parse::<u64>() else {
            continue;
        };

        inodes.push(ino);
    }

    inodes.sort_unstable();

    Ok(inodes)
}

pub fn migrate_missing_checksums() -> io::Result<usize> {
    let mut migrated = 0usize;

    for ino in list_block_inodes()? {
        let checksum_file = checksum_path(ino);

        if checksum_file.exists() {
            continue;
        }

        let data = fs::read(data_path(ino))?;

        write_checksum(ino, &data)?;

        migrated += 1;
    }

    Ok(migrated)
}

pub fn verify_all_blocks() -> io::Result<Vec<(u64, IntegrityStatus)>> {
    let mut results = Vec::new();

    for ino in list_block_inodes()? {
        results.push((ino, verify_file_data(ino)?));
    }

    Ok(results)
}
