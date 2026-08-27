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

struct MemoryFile {
    ino: INodeNo,
    name: String,
    data: Vec<u8>,
    perm: u16,
}

struct State {
    files: BTreeMap<String, MemoryFile>,
    next_ino: u64,
}

struct Ccfs {
    state: Mutex<State>,
}

impl Ccfs {
    fn new() -> Self {
        let mut files = BTreeMap::new();

        files.insert(
            "hello.txt".to_string(),
            MemoryFile {
                ino: INodeNo(2),
                name: "hello.txt".to_string(),
                data: b"Hello from CCFS!\n".to_vec(),
                perm: 0o644,
            },
        );

        let mut next_ino = 3;

        match db::load_file_metadata() {
            Ok(metadata_files) => {
                for meta in metadata_files {
                    if meta.ino == 2 || meta.name == "hello.txt" {
                        continue;
                    }

                    next_ino = next_ino.max(meta.ino + 1);

                    let data = storage::load_file_data(meta.ino)
                        .unwrap_or_else(|_| vec![0; meta.size as usize]);

                    let name = meta.name.clone();

                    files.insert(
                        name.clone(),
                        MemoryFile {
                            ino: INodeNo(meta.ino),
                            name,
                            data,
                            perm: meta.perm,
                        },
                    );
                }
            }

            Err(err) => {
                eprintln!("Failed to load file metadata: {}", err);
            }
        }

        Self {
            state: Mutex::new(State { files, next_ino }),
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

fn file_attr(file: &MemoryFile) -> FileAttr {
    FileAttr {
        ino: file.ino,
        size: file.data.len() as u64,
        blocks: ((file.data.len() as u64) + 511) / 512,
        atime: UNIX_EPOCH,
        mtime: UNIX_EPOCH,
        ctime: UNIX_EPOCH,
        crtime: UNIX_EPOCH,
        kind: FileType::RegularFile,
        perm: file.perm,
        nlink: 1,
        uid: 1000,
        gid: 1000,
        rdev: 0,
        blksize: 4096,
        flags: 0,
    }
}

impl Filesystem for Ccfs {
    fn lookup(&self, _req: &Request, parent: INodeNo, name: &OsStr, reply: ReplyEntry) {
        if parent != INodeNo::ROOT {
            reply.error(Errno::ENOENT);
            return;
        }

        let state = self.state.lock().unwrap();
        let name = name.to_string_lossy();

        if let Some(file) = state.files.get(name.as_ref()) {
            reply.entry(&TTL, &file_attr(file), Generation(0));
        } else {
            reply.error(Errno::ENOENT);
        }
    }

    fn getattr(&self, _req: &Request, ino: INodeNo, _fh: Option<FileHandle>, reply: ReplyAttr) {
        if ino == INodeNo::ROOT {
            reply.attr(&TTL, &root_attr());
            return;
        }

        let state = self.state.lock().unwrap();

        if let Some(file) = state.files.values().find(|file| file.ino == ino) {
            reply.attr(&TTL, &file_attr(file));
        } else {
            reply.error(Errno::ENOENT);
        }
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

        let Some(file) = state.files.values_mut().find(|file| file.ino == ino) else {
            reply.error(Errno::ENOENT);
            return;
        };

        if let Some(mode) = mode {
            file.perm = (mode & 0o777) as u16;
        }

        if let Some(size) = size {
            file.data.resize(size as usize, 0);

            if let Err(err) = storage::save_file_data(u64::from(file.ino), &file.data) {
                eprintln!("Failed to persist resized file data: {}", err);
                reply.error(Errno::EIO);
                return;
            }
        }

        if let Err(err) = db::save_file_metadata(
            u64::from(file.ino),
            &file.name,
            file.perm,
            file.data.len() as u64,
        ) {
            eprintln!("Failed to update file metadata: {}", err);
            reply.error(Errno::EIO);
            return;
        }

        reply.attr(&TTL, &file_attr(file));
    }

    fn readdir(
        &self,
        _req: &Request,
        ino: INodeNo,
        _fh: FileHandle,
        offset: u64,
        mut reply: ReplyDirectory,
    ) {
        if ino != INodeNo::ROOT {
            reply.error(Errno::ENOTDIR);
            return;
        }

        let state = self.state.lock().unwrap();

        let mut entries: Vec<(INodeNo, FileType, String)> = vec![
            (INodeNo::ROOT, FileType::Directory, ".".to_string()),
            (INodeNo::ROOT, FileType::Directory, "..".to_string()),
        ];

        for file in state.files.values() {
            entries.push((file.ino, FileType::RegularFile, file.name.clone()));
        }

        for (i, entry) in entries.iter().enumerate().skip(offset as usize) {
            if reply.add(entry.0, (i + 1) as u64, entry.1, &entry.2) {
                break;
            }
        }

        reply.ok();
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
        if parent != INodeNo::ROOT {
            reply.error(Errno::ENOENT);
            return;
        }

        let name = name.to_string_lossy().into_owned();

        let mut state = self.state.lock().unwrap();

        if state.files.contains_key(&name) {
            reply.error(Errno::EEXIST);
            return;
        }

        let ino = INodeNo(state.next_ino);
        state.next_ino += 1;

        let file = MemoryFile {
            ino,
            name: name.clone(),
            data: Vec::new(),
            perm: (mode & !umask & 0o777) as u16,
        };

        let attr = file_attr(&file);

        if let Err(err) =
            db::save_file_metadata(u64::from(ino), &name, file.perm, file.data.len() as u64)
        {
            eprintln!("Failed to save file metadata: {}", err);
            reply.error(Errno::EIO);
            return;
        }

        state.files.insert(name, file);

        reply.created(
            &TTL,
            &attr,
            Generation(0),
            FileHandle(0),
            FopenFlags::empty(),
        );
    }

    fn unlink(&self, _req: &Request, parent: INodeNo, name: &OsStr, reply: ReplyEmpty) {
        if parent != INodeNo::ROOT {
            reply.error(Errno::ENOENT);
            return;
        }

        let name = name.to_string_lossy().into_owned();

        if name == "hello.txt" {
            reply.error(Errno::EPERM);
            return;
        }

        let mut state = self.state.lock().unwrap();

        let Some(ino) = state.files.get(&name).map(|file| file.ino) else {
            reply.error(Errno::ENOENT);
            return;
        };

        if let Err(err) = storage::delete_file_data(u64::from(ino)) {
            eprintln!("Failed to delete file data: {}", err);
            reply.error(Errno::EIO);
            return;
        }

        if let Err(err) = db::delete_file_metadata(u64::from(ino)) {
            eprintln!("Failed to delete file metadata: {}", err);
            reply.error(Errno::EIO);
            return;
        }

        state.files.remove(&name);

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
        if parent != INodeNo::ROOT || newparent != INodeNo::ROOT {
            reply.error(Errno::ENOENT);
            return;
        }

        // Current milestone supports normal rename only.
        if !flags.is_empty() {
            reply.error(Errno::EINVAL);
            return;
        }

        let old_name = name.to_string_lossy().into_owned();
        let new_name = newname.to_string_lossy().into_owned();

        if old_name == "hello.txt" {
            reply.error(Errno::EPERM);
            return;
        }

        if old_name == new_name {
            reply.ok();
            return;
        }

        let mut state = self.state.lock().unwrap();

        if !state.files.contains_key(&old_name) {
            reply.error(Errno::ENOENT);
            return;
        }

        // For now we do not overwrite an existing destination file.
        if state.files.contains_key(&new_name) {
            reply.error(Errno::EEXIST);
            return;
        }

        let Some(mut file) = state.files.remove(&old_name) else {
            reply.error(Errno::ENOENT);
            return;
        };

        let ino = file.ino;

        if let Err(err) = db::rename_file_metadata(u64::from(ino), &new_name) {
            eprintln!("Failed to rename file metadata: {}", err);

            // Roll back the in-memory removal.
            state.files.insert(old_name, file);

            reply.error(Errno::EIO);
            return;
        }

        file.name = new_name.clone();
        state.files.insert(new_name, file);

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

        let Some(file) = state.files.values().find(|file| file.ino == ino) else {
            reply.error(Errno::ENOENT);
            return;
        };

        let start = offset as usize;

        if start >= file.data.len() {
            reply.data(&[]);
            return;
        }

        let end = (start + size as usize).min(file.data.len());

        reply.data(&file.data[start..end]);
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

        let Some(file) = state.files.values_mut().find(|file| file.ino == ino) else {
            reply.error(Errno::ENOENT);
            return;
        };

        let start = offset as usize;
        let end = start + data.len();

        if file.data.len() < start {
            file.data.resize(start, 0);
        }

        if file.data.len() < end {
            file.data.resize(end, 0);
        }

        file.data[start..end].copy_from_slice(data);

        if let Err(err) = storage::save_file_data(u64::from(file.ino), &file.data) {
            eprintln!("Failed to persist file data: {}", err);
            reply.error(Errno::EIO);
            return;
        }

        if let Err(err) = db::save_file_metadata(
            u64::from(file.ino),
            &file.name,
            file.perm,
            file.data.len() as u64,
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

    println!("CCFS writable filesystem mounting at: {}", mountpoint);
    println!("Press Ctrl+C to stop the filesystem.");

    fuser::mount(Ccfs::new(), mountpoint, &config).expect("Failed to mount CCFS");
}
