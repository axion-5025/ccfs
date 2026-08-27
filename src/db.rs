use rusqlite::{Connection, Result};

pub fn init_database() -> Result<Connection> {
    let conn = Connection::open("volume/metadata.db")?;

    conn.pragma_update(None, "journal_mode", "WAL")?;

    conn.execute_batch(
        "
        CREATE TABLE IF NOT EXISTS files (
            ino INTEGER PRIMARY KEY,
            name TEXT UNIQUE NOT NULL,
            perm INTEGER NOT NULL,
            size INTEGER NOT NULL DEFAULT 0
        );
        ",
    )?;

    Ok(conn)
}

pub fn save_file_metadata(ino: u64, name: &str, perm: u16, size: u64) -> Result<()> {
    let conn = Connection::open("volume/metadata.db")?;

    conn.execute(
        "
        INSERT OR REPLACE INTO files (ino, name, perm, size)
        VALUES (?1, ?2, ?3, ?4)
        ",
        rusqlite::params![ino as i64, name, perm, size as i64],
    )?;

    Ok(())
}

#[derive(Debug)]
pub struct FileMetadata {
    pub ino: u64,
    pub name: String,
    pub perm: u16,
    pub size: u64,
}

pub fn load_file_metadata() -> Result<Vec<FileMetadata>> {
    let conn = Connection::open("volume/metadata.db")?;

    let mut stmt = conn.prepare(
        "
        SELECT ino, name, perm, size
        FROM files
        ORDER BY ino
        ",
    )?;

    let rows = stmt.query_map([], |row| {
        Ok(FileMetadata {
            ino: row.get::<_, i64>(0)? as u64,
            name: row.get(1)?,
            perm: row.get::<_, i64>(2)? as u16,
            size: row.get::<_, i64>(3)? as u64,
        })
    })?;

    let mut files = Vec::new();

    for row in rows {
        files.push(row?);
    }

    Ok(files)
}

pub fn delete_file_metadata(ino: u64) -> Result<()> {
    let conn = Connection::open("volume/metadata.db")?;

    conn.execute(
        "DELETE FROM files WHERE ino = ?1",
        rusqlite::params![ino as i64],
    )?;

    Ok(())
}

pub fn rename_file_metadata(ino: u64, new_name: &str) -> Result<()> {
    let conn = Connection::open("volume/metadata.db")?;

    conn.execute(
        "
        UPDATE files
        SET name = ?1
        WHERE ino = ?2
        ",
        rusqlite::params![new_name, ino as i64],
    )?;

    Ok(())
}
