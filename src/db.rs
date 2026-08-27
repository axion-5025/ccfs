use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{Connection, Result};

#[derive(Debug)]
pub struct EntryMetadata {
    pub ino: u64,
    pub parent: u64,
    pub name: String,
    pub is_dir: bool,
    pub perm: u16,
    pub size: u64,
    pub atime: i64,
    pub mtime: i64,
    pub ctime: i64,
}

fn now_timestamp() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

fn column_exists(conn: &Connection, column: &str) -> Result<bool> {
    let mut stmt = conn.prepare("PRAGMA table_info(entries)")?;

    let rows = stmt.query_map([], |row| row.get::<_, String>(1))?;

    for row in rows {
        if row? == column {
            return Ok(true);
        }
    }

    Ok(false)
}

fn ensure_timestamp_columns(conn: &Connection) -> Result<()> {
    if !column_exists(conn, "atime")? {
        conn.execute(
            "
            ALTER TABLE entries
            ADD COLUMN atime INTEGER NOT NULL DEFAULT 0
            ",
            [],
        )?;
    }

    if !column_exists(conn, "mtime")? {
        conn.execute(
            "
            ALTER TABLE entries
            ADD COLUMN mtime INTEGER NOT NULL DEFAULT 0
            ",
            [],
        )?;
    }

    if !column_exists(conn, "ctime")? {
        conn.execute(
            "
            ALTER TABLE entries
            ADD COLUMN ctime INTEGER NOT NULL DEFAULT 0
            ",
            [],
        )?;
    }

    Ok(())
}

pub fn init_database() -> Result<Connection> {
    let conn = Connection::open("volume/metadata.db")?;

    conn.pragma_update(None, "journal_mode", "WAL")?;

    conn.pragma_update(None, "synchronous", "FULL")?;

    conn.execute_batch(
        "
        CREATE TABLE IF NOT EXISTS entries (
            ino INTEGER PRIMARY KEY,
            parent INTEGER NOT NULL,
            name TEXT NOT NULL,
            kind INTEGER NOT NULL,
            perm INTEGER NOT NULL,
            size INTEGER NOT NULL DEFAULT 0,
            atime INTEGER NOT NULL DEFAULT 0,
            mtime INTEGER NOT NULL DEFAULT 0,
            ctime INTEGER NOT NULL DEFAULT 0,
            UNIQUE(parent, name)
        );

        CREATE INDEX IF NOT EXISTS idx_entries_parent
        ON entries(parent);

        CREATE TABLE IF NOT EXISTS applied_tx (
            txid INTEGER PRIMARY KEY,
            applied_at INTEGER NOT NULL
        );
        ",
    )?;

    ensure_timestamp_columns(&conn)?;

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
        let now = now_timestamp();

        conn.execute(
            "
            INSERT OR IGNORE INTO entries
                (
                    ino,
                    parent,
                    name,
                    kind,
                    perm,
                    size,
                    atime,
                    mtime,
                    ctime
                )
            SELECT
                ino,
                1,
                name,
                0,
                perm,
                size,
                ?1,
                ?1,
                ?1
            FROM files
            ",
            rusqlite::params![now],
        )?;

        conn.execute_batch("DROP TABLE files;")?;
    }

    Ok(conn)
}

pub fn save_entry_metadata_with_times(
    ino: u64,
    parent: u64,
    name: &str,
    is_dir: bool,
    perm: u16,
    size: u64,
    atime: i64,
    mtime: i64,
    ctime: i64,
) -> Result<()> {
    let conn = Connection::open("volume/metadata.db")?;

    let kind = if is_dir { 1i64 } else { 0i64 };

    conn.execute(
        "
        INSERT INTO entries
            (
                ino,
                parent,
                name,
                kind,
                perm,
                size,
                atime,
                mtime,
                ctime
            )
        VALUES
            (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)

        ON CONFLICT(ino) DO UPDATE SET
            parent = excluded.parent,
            name   = excluded.name,
            kind   = excluded.kind,
            perm   = excluded.perm,
            size   = excluded.size,
            atime  = excluded.atime,
            mtime  = excluded.mtime,
            ctime  = excluded.ctime
        ",
        rusqlite::params![
            ino as i64,
            parent as i64,
            name,
            kind,
            perm as i64,
            size as i64,
            atime,
            mtime,
            ctime,
        ],
    )?;

    Ok(())
}

/*
 * Crash-consistency helper.
 *
 * Metadata update and applied_tx insertion happen
 * inside ONE SQLite transaction.
 *
 * Either both become durable or neither does.
 */
pub fn save_entry_metadata_with_times_and_mark_tx(
    txid: u64,
    ino: u64,
    parent: u64,
    name: &str,
    is_dir: bool,
    perm: u16,
    size: u64,
    atime: i64,
    mtime: i64,
    ctime: i64,
) -> Result<()> {
    let mut conn = Connection::open("volume/metadata.db")?;

    conn.pragma_update(None, "synchronous", "FULL")?;

    let tx = conn.transaction()?;

    let kind = if is_dir { 1i64 } else { 0i64 };

    tx.execute(
        "
        INSERT INTO entries
            (
                ino,
                parent,
                name,
                kind,
                perm,
                size,
                atime,
                mtime,
                ctime
            )
        VALUES
            (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)

        ON CONFLICT(ino) DO UPDATE SET
            parent = excluded.parent,
            name   = excluded.name,
            kind   = excluded.kind,
            perm   = excluded.perm,
            size   = excluded.size,
            atime  = excluded.atime,
            mtime  = excluded.mtime,
            ctime  = excluded.ctime
        ",
        rusqlite::params![
            ino as i64,
            parent as i64,
            name,
            kind,
            perm as i64,
            size as i64,
            atime,
            mtime,
            ctime,
        ],
    )?;

    tx.execute(
        "
        INSERT OR IGNORE INTO applied_tx
            (
                txid,
                applied_at
            )
        VALUES
            (?1, ?2)
        ",
        rusqlite::params![txid as i64, now_timestamp(),],
    )?;

    tx.commit()?;

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
                size,
                atime,
                mtime,
                ctime
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

            atime: row.get(6)?,

            mtime: row.get(7)?,

            ctime: row.get(8)?,
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
        "
        DELETE FROM entries
        WHERE ino = ?1
        ",
        rusqlite::params![ino as i64],
    )?;

    Ok(())
}

pub fn is_transaction_applied(txid: u64) -> Result<bool> {
    let conn = Connection::open("volume/metadata.db")?;

    let exists: i64 = conn.query_row(
        "
            SELECT EXISTS(
                SELECT 1
                FROM applied_tx
                WHERE txid = ?1
            )
            ",
        rusqlite::params![txid as i64],
        |row| row.get(0),
    )?;

    Ok(exists != 0)
}

pub fn mark_transaction_applied(txid: u64) -> Result<()> {
    let conn = Connection::open("volume/metadata.db")?;

    conn.execute(
        "
        INSERT OR IGNORE INTO applied_tx
            (
                txid,
                applied_at
            )
        VALUES
            (?1, ?2)
        ",
        rusqlite::params![txid as i64, now_timestamp(),],
    )?;

    Ok(())
}

pub fn applied_transaction_count() -> Result<u64> {
    let conn = Connection::open("volume/metadata.db")?;

    let count: i64 = conn.query_row(
        "
            SELECT COUNT(*)
            FROM applied_tx
            ",
        [],
        |row| row.get(0),
    )?;

    Ok(count as u64)
}

pub fn clear_applied_transactions() -> Result<()> {
    let conn = Connection::open("volume/metadata.db")?;

    conn.execute("DELETE FROM applied_tx", [])?;

    Ok(())
}
