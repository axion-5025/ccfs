use std::ffi::OsStr;
use std::time::{Duration, UNIX_EPOCH};

use fuser::{
    Config, Errno, FileAttr, FileHandle, FileType, Filesystem, INodeNo,
    LockOwner, MountOption, OpenFlags, ReplyAttr, ReplyData,
    ReplyDirectory, ReplyEntry, Request,
};

const TTL: Duration = Duration::from_secs(1);

const HELLO_INO: INodeNo = INodeNo(2);
const HELLO_NAME: &str = "hello.txt";
const HELLO_CONTENT: &[u8] = b"Hello from CCFS!\n";

const ROOT_ATTR: FileAttr = FileAttr {
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
};

const HELLO_ATTR: FileAttr = FileAttr {
    ino: HELLO_INO,
    size: 17,
    blocks: 1,
    atime: UNIX_EPOCH,
    mtime: UNIX_EPOCH,
    ctime: UNIX_EPOCH,
    crtime: UNIX_EPOCH,
    kind: FileType::RegularFile,
    perm: 0o444,
    nlink: 1,
    uid: 1000,
    gid: 1000,
    rdev: 0,
    blksize: 4096,
    flags: 0,
};

struct Ccfs;

impl Filesystem for Ccfs {
    fn lookup(
        &self,
        _req: &Request,
        parent: INodeNo,
        name: &OsStr,
        reply: ReplyEntry,
    ) {
        if parent == INodeNo::ROOT && name.to_str() == Some(HELLO_NAME) {
            reply.entry(&TTL, &HELLO_ATTR, fuser::Generation(0));
        } else {
            reply.error(Errno::ENOENT);
        }
    }

    fn getattr(
        &self,
        _req: &Request,
        ino: INodeNo,
        _fh: Option<FileHandle>,
        reply: ReplyAttr,
    ) {
        match u64::from(ino) {
            1 => reply.attr(&TTL, &ROOT_ATTR),
            2 => reply.attr(&TTL, &HELLO_ATTR),
            _ => reply.error(Errno::ENOENT),
        }
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
            reply.error(Errno::ENOENT);
            return;
        }

        let entries = [
            (INodeNo::ROOT, FileType::Directory, "."),
            (INodeNo::ROOT, FileType::Directory, ".."),
            (HELLO_INO, FileType::RegularFile, HELLO_NAME),
        ];

        for (i, entry) in entries.iter().enumerate().skip(offset as usize) {
            if reply.add(entry.0, (i + 1) as u64, entry.1, entry.2) {
                break;
            }
        }

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
        if ino != HELLO_INO {
            reply.error(Errno::ENOENT);
            return;
        }

        let start = offset as usize;

        if start >= HELLO_CONTENT.len() {
            reply.data(&[]);
            return;
        }

        let end = (start + size as usize).min(HELLO_CONTENT.len());

        reply.data(&HELLO_CONTENT[start..end]);
    }
}

fn main() {
    let mountpoint = "mount";

    let mut config = Config::default();

    config
        .mount_options
        .extend([
            MountOption::RO,
            MountOption::FSName("ccfs".to_string()),
        ]);

    println!("CCFS mounting at: {}", mountpoint);
    println!("Press Ctrl+C to stop the filesystem.");

    fuser::mount(Ccfs, mountpoint, &config)
        .expect("Failed to mount CCFS");
}