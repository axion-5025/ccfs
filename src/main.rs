mod db;
mod storage;

use std::collections::BTreeMap;
use std::ffi::OsStr;
use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use fuser::{
    BsdFileFlags, Config, Errno, FileAttr, FileHandle, FileType, Filesystem, FopenFlags,
    Generation, INodeNo, LockOwner, MountOption, OpenFlags, RenameFlags, ReplyAttr, ReplyCreate,
    ReplyData, ReplyDirectory, ReplyEmpty, ReplyEntry, ReplyWrite, Request, TimeOrNow, WriteFlags,
};

const TTL: Duration = Duration::from_secs(1);

struct MemoryEntry {
    ino: INodeNo,
    parent: INodeNo,
    name: String,
    is_dir: bool,
    data: Vec<u8>,
    perm: u16,
}

struct State {
    entries: BTreeMap<u64, MemoryEntry>,
    next_ino: u64,
}

struct Ccfs {
    state: Mutex<State>,
}

impl Ccfs {
    fn new() -> Self {
        let mut entries = BTreeMap::new();

        // Built-in demo file.
        entries.insert(
            2,
            MemoryEntry {
                ino: INodeNo(2),
                parent: INodeNo::ROOT,
                name: "hello.txt".to_string(),
                is_dir: false,
                data: b"Hello from CCFS!\n".to_vec(),
                perm: 0o644,
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
                        storage::load_file_data(meta.ino)
                            .unwrap_or_else(|_| vec![0; meta.size as usize])
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
        atime: UNIX_EPOCH,
        mtime: UNIX_EPOCH,
        ctime: UNIX_EPOCH,
        crtime: UNIX_EPOCH,
        kind: entry_kind(entry),
        perm: entry.perm,
        nlink: if entry.is_dir { 2 } else { 1 },
        uid: 1000,
        gid: 1000,
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

impl Filesystem for Ccfs {
    fn lookup(&self, _req: &Request, parent: INodeNo, name: &OsStr, reply: ReplyEntry) {
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
        _uid: Option<u32>,
        _gid: Option<u32>,
        size: Option<u64>,
        _atime: Option<TimeOrNow>,
        _mtime: Option<TimeOrNow>,
        _ctime: Option<SystemTime>,
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

        if let Some(mode) = mode {
            entry.perm = (mode & 0o777) as u16;
        }

        if let Some(size) = size {
            if entry.is_dir {
                reply.error(Errno::EISDIR);
                return;
            }

            entry.data.resize(size as usize, 0);

            if let Err(err) = storage::save_file_data(u64::from(entry.ino), &entry.data) {
                eprintln!("Failed to persist resized file: {}", err);
                reply.error(Errno::EIO);
                return;
            }
        }

        let metadata_size = if entry.is_dir {
            0
        } else {
            entry.data.len() as u64
        };

        if let Err(err) = db::save_entry_metadata(
            u64::from(entry.ino),
            u64::from(entry.parent),
            &entry.name,
            entry.is_dir,
            entry.perm,
            metadata_size,
        ) {
            eprintln!("Failed to update metadata: {}", err);
            reply.error(Errno::EIO);
            return;
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

        let mut entries: Vec<(INodeNo, FileType, String)> = vec![
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
            entries.push((child.ino, entry_kind(child), child.name.clone()));
        }

        for (index, entry) in entries.iter().enumerate().skip(offset as usize) {
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

        let entry = MemoryEntry {
            ino: INodeNo(ino_value),
            parent,
            name: name.clone(),
            is_dir: true,
            data: Vec::new(),
            perm: (mode & !umask & 0o777) as u16,
        };

        let attr = entry_attr(&entry);

        if let Err(err) =
            db::save_entry_metadata(ino_value, u64::from(parent), &name, true, entry.perm, 0)
        {
            eprintln!("Failed to persist directory metadata: {}", err);
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

        let entry = MemoryEntry {
            ino: INodeNo(ino_value),
            parent,
            name: name.clone(),
            is_dir: false,
            data: Vec::new(),
            perm: (mode & !umask & 0o777) as u16,
        };

        let attr = entry_attr(&entry);

        if let Err(err) =
            db::save_entry_metadata(ino_value, u64::from(parent), &name, false, entry.perm, 0)
        {
            eprintln!("Failed to persist file metadata: {}", err);
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

        if let Err(err) = storage::delete_file_data(ino_value) {
            eprintln!("Failed to delete file contents: {}", err);
            reply.error(Errno::EIO);
            return;
        }

        if let Err(err) = db::delete_entry_metadata(ino_value) {
            eprintln!("Failed to delete file metadata: {}", err);
            reply.error(Errno::EIO);
            return;
        }

        state.entries.remove(&ino_value);

        reply.ok();
    }

    fn rmdir(&self, _req: &Request, parent: INodeNo, name: &OsStr, reply: ReplyEmpty) {
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

        if let Err(err) = db::delete_entry_metadata(ino_value) {
            eprintln!("Failed to delete directory metadata: {}", err);
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

        if ino_value == 2 {
            reply.error(Errno::EPERM);
            return;
        }

        if parent == newparent && old_name == new_name {
            reply.ok();
            return;
        }

        if find_child(&state, newparent, &new_name).is_some() {
            reply.error(Errno::EEXIST);
            return;
        }

        let is_dir = state
            .entries
            .get(&ino_value)
            .map(|entry| entry.is_dir)
            .unwrap_or(false);

        if is_dir && would_create_directory_cycle(&state, ino_value, newparent) {
            reply.error(Errno::EINVAL);
            return;
        }

        if let Err(err) = db::rename_entry_metadata(ino_value, u64::from(newparent), &new_name) {
            eprintln!("Failed to persist rename: {}", err);
            reply.error(Errno::EIO);
            return;
        }

        let Some(entry) = state.entries.get_mut(&ino_value) else {
            reply.error(Errno::ENOENT);
            return;
        };

        entry.parent = newparent;
        entry.name = new_name;

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
        let state = self.state.lock().unwrap();

        let Some(entry) = state.entries.get(&u64::from(ino)) else {
            reply.error(Errno::ENOENT);
            return;
        };

        if entry.is_dir {
            reply.error(Errno::EISDIR);
            return;
        }

        let start = offset as usize;

        if start >= entry.data.len() {
            reply.data(&[]);
            return;
        }

        let end = (start + size as usize).min(entry.data.len());

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

        let start = offset as usize;
        let end = start + data.len();

        if entry.data.len() < start {
            entry.data.resize(start, 0);
        }

        if entry.data.len() < end {
            entry.data.resize(end, 0);
        }

        entry.data[start..end].copy_from_slice(data);

        if let Err(err) = storage::save_file_data(u64::from(entry.ino), &entry.data) {
            eprintln!("Failed to persist file contents: {}", err);
            reply.error(Errno::EIO);
            return;
        }

        if let Err(err) = db::save_entry_metadata(
            u64::from(entry.ino),
            u64::from(entry.parent),
            &entry.name,
            false,
            entry.perm,
            entry.data.len() as u64,
        ) {
            eprintln!("Failed to update file metadata: {}", err);
            reply.error(Errno::EIO);
            return;
        }

        reply.written(data.len() as u32);
    }

    fn flush(
        &self,
        _req: &Request,
        _ino: INodeNo,
        _fh: FileHandle,
        _lock_owner: LockOwner,
        reply: ReplyEmpty,
    ) {
        reply.ok();
    }

    fn fsync(
        &self,
        _req: &Request,
        _ino: INodeNo,
        _fh: FileHandle,
        _datasync: bool,
        reply: ReplyEmpty,
    ) {
        reply.ok();
    }
}

fn main() {
    let _db = db::init_database().expect("Failed to initialize SQLite database");

    println!("SQLite metadata database ready.");

    let mountpoint = "mount";

    let mut config = Config::default();

    config
        .mount_options
        .push(MountOption::FSName("ccfs".to_string()));

    println!(
        "CCFS directory-aware filesystem mounting at: {}",
        mountpoint
    );

    println!("Press Ctrl+C to stop the filesystem.");

    fuser::mount(Ccfs::new(), mountpoint, &config).expect("Failed to mount CCFS");
}
