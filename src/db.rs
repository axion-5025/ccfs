use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{Connection, Result};

#[derive(Debug)]
pub struct EntryMetadata {
    pub ino: u64,
    pub parent: u64,
    pub name: String,
    pub is_dir: bool,
    pub perm: u16,
    pub uid: u32,
    pub gid: u32,
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

    if !column_exists(conn, "uid")? {
        conn.execute(
            "
            ALTER TABLE entries
            ADD COLUMN uid INTEGER NOT NULL DEFAULT 1000
            ",
            [],
        )?;
    }

    if !column_exists(conn, "gid")? {
        conn.execute(
            "
            ALTER TABLE entries
            ADD COLUMN gid INTEGER NOT NULL DEFAULT 1000
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
            uid INTEGER NOT NULL DEFAULT 1000,
            gid INTEGER NOT NULL DEFAULT 1000,
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

fn maybe_metadata_kill9(point: &str) {
    let requested = std::env::var("CCFS_DB_KILL9_POINT").ok();

    if requested.as_deref() != Some(point) {
        return;
    }

    eprintln!("CCFS metadata SIGKILL failpoint triggered: {}", point);

    let _ = std::process::Command::new("kill")
        .arg("-9")
        .arg(std::process::id().to_string())
        .status();

    std::process::abort();
}

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

    maybe_metadata_kill9("after_metadata_before_applied_tx");

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

/*
 * Crash-safe POSIX rename replacement.
 *
 * Existing destination metadata delete, source rename,
 * and applied_tx record all commit in one SQLite transaction.
 */
pub fn rename_entry_replacing_and_mark_tx(
    txid: u64,
    ino: u64,
    replaced_ino: Option<u64>,
    new_parent: u64,
    new_name: &str,
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

    if let Some(replaced_ino) = replaced_ino {
        if replaced_ino != ino {
            tx.execute(
                "
                DELETE FROM entries
                WHERE ino = ?1
                ",
                rusqlite::params![replaced_ino as i64],
            )?;
        }
    }

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
            new_parent as i64,
            new_name,
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
        rusqlite::params![txid as i64, now_timestamp()],
    )?;

    tx.commit()?;

    Ok(())
}

/*
 * Crash-safe SETATTR ownership commit.
 *
 * Metadata, uid/gid, and applied_tx are committed atomically.
 */
pub fn save_entry_metadata_with_ownership_and_mark_tx(
    txid: u64,
    ino: u64,
    parent: u64,
    name: &str,
    is_dir: bool,
    perm: u16,
    uid: u32,
    gid: u32,
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
                uid,
                gid,
                size,
                atime,
                mtime,
                ctime
            )
        VALUES
            (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)

        ON CONFLICT(ino) DO UPDATE SET
            parent = excluded.parent,
            name   = excluded.name,
            kind   = excluded.kind,
            perm   = excluded.perm,
            uid    = excluded.uid,
            gid    = excluded.gid,
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
            uid as i64,
            gid as i64,
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
        rusqlite::params![txid as i64, now_timestamp()],
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
                ctime,
                uid,
                gid
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

            uid: row.get::<_, i64>(9)? as u32,

            gid: row.get::<_, i64>(10)? as u32,

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

/*
 * Crash-safe DELETE metadata commit.
 *
 * Deleting metadata and recording applied_tx happen
 * in the same SQLite transaction.
 */
pub fn delete_entry_metadata_and_mark_tx(txid: u64, ino: u64) -> Result<()> {
    let mut conn = Connection::open("volume/metadata.db")?;

    conn.pragma_update(None, "synchronous", "FULL")?;

    let tx = conn.transaction()?;

    tx.execute(
        "
        DELETE FROM entries
        WHERE ino = ?1
        ",
        rusqlite::params![ino as i64],
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

/*
 * Flush SQLite WAL state back into metadata.db after
 * journal compaction.
 *
 * TRUNCATE checkpoint also shrinks the WAL when possible.
 */
pub fn checkpoint_metadata_database() -> Result<()> {
    let conn = Connection::open("volume/metadata.db")?;

    conn.pragma_update(None, "synchronous", "FULL")?;

    let _: (i64, i64, i64) = conn.query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |row| {
        Ok((row.get(0)?, row.get(1)?, row.get(2)?))
    })?;

    Ok(())
}

pub fn clear_applied_transactions() -> Result<()> {
    let conn = Connection::open("volume/metadata.db")?;

    conn.execute("DELETE FROM applied_tx", [])?;

    Ok(())
}
