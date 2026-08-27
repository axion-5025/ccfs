use rusqlite::{Connection, Result};

#[derive(Debug)]
pub struct EntryMetadata {
    pub ino: u64,
    pub parent: u64,
    pub name: String,
    pub is_dir: bool,
    pub perm: u16,
    pub size: u64,
}

pub fn init_database() -> Result<Connection> {
    let conn = Connection::open("volume/metadata.db")?;

    conn.pragma_update(None, "journal_mode", "WAL")?;

    conn.execute_batch(
        "
        CREATE TABLE IF NOT EXISTS entries (
            ino INTEGER PRIMARY KEY,
            parent INTEGER NOT NULL,
            name TEXT NOT NULL,
            kind INTEGER NOT NULL,
            perm INTEGER NOT NULL,
            size INTEGER NOT NULL DEFAULT 0,
            UNIQUE(parent, name)
        );

        CREATE INDEX IF NOT EXISTS idx_entries_parent
        ON entries(parent);
        ",
    )?;

    let old_table_exists: i64 = conn.query_row(
        "
        SELECT EXISTS(
            SELECT 1
            FROM sqlite_master
            WHERE type = 'table'
              AND name = 'files'
        )
        ",
        [],
        |row| row.get(0),
    )?;

    if old_table_exists != 0 {
        conn.execute_batch(
            "
            INSERT OR IGNORE INTO entries
                (ino, parent, name, kind, perm, size)
            SELECT
                ino,
                1,
                name,
                0,
                perm,
                size
            FROM files;

            DROP TABLE files;
            ",
        )?;
    }

    Ok(conn)
}

pub fn save_entry_metadata(
    ino: u64,
    parent: u64,
    name: &str,
    is_dir: bool,
    perm: u16,
    size: u64,
) -> Result<()> {
    let conn = Connection::open("volume/metadata.db")?;

    let kind = if is_dir { 1i64 } else { 0i64 };

    conn.execute(
        "
        INSERT INTO entries
            (ino, parent, name, kind, perm, size)
        VALUES
            (?1, ?2, ?3, ?4, ?5, ?6)

        ON CONFLICT(ino) DO UPDATE SET
            parent = excluded.parent,
            name   = excluded.name,
            kind   = excluded.kind,
            perm   = excluded.perm,
            size   = excluded.size
        ",
        rusqlite::params![
            ino as i64,
            parent as i64,
            name,
            kind,
            perm as i64,
            size as i64,
        ],
    )?;

    Ok(())
}

pub fn load_entries() -> Result<Vec<EntryMetadata>> {
    let conn = Connection::open("volume/metadata.db")?;

    let mut stmt = conn.prepare(
        "
        SELECT
            ino,
            parent,
            name,
            kind,
            perm,
            size
        FROM entries
        ORDER BY ino
        ",
    )?;

    let rows = stmt.query_map([], |row| {
        let kind: i64 = row.get(3)?;

        Ok(EntryMetadata {
            ino: row.get::<_, i64>(0)? as u64,
            parent: row.get::<_, i64>(1)? as u64,
            name: row.get(2)?,
            is_dir: kind != 0,
            perm: row.get::<_, i64>(4)? as u16,
            size: row.get::<_, i64>(5)? as u64,
        })
    })?;

    let mut entries = Vec::new();

    for row in rows {
        entries.push(row?);
    }

    Ok(entries)
}

pub fn delete_entry_metadata(ino: u64) -> Result<()> {
    let conn = Connection::open("volume/metadata.db")?;

    conn.execute(
        "DELETE FROM entries WHERE ino = ?1",
        rusqlite::params![ino as i64],
    )?;

    Ok(())
}

pub fn rename_entry_metadata(ino: u64, new_parent: u64, new_name: &str) -> Result<()> {
    let conn = Connection::open("volume/metadata.db")?;

    conn.execute(
        "
        UPDATE entries
        SET parent = ?1,
            name = ?2
        WHERE ino = ?3
        ",
        rusqlite::params![new_parent as i64, new_name, ino as i64,],
    )?;

    Ok(())
}
