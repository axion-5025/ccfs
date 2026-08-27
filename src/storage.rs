use std::fs;
use std::io;
use std::path::PathBuf;

fn block_path(ino: u64) -> PathBuf {
    PathBuf::from(format!("volume/blocks/{}.bin", ino))
}

pub fn save_file_data(ino: u64, data: &[u8]) -> io::Result<()> {
    fs::create_dir_all("volume/blocks")?;
    fs::write(block_path(ino), data)?;
    Ok(())
}

pub fn load_file_data(ino: u64) -> io::Result<Vec<u8>> {
    let path = block_path(ino);

    if !path.exists() {
        return Ok(Vec::new());
    }

    fs::read(path)
}
