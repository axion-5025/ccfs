# CCFS

CCFS is a custom persistent filesystem written in Rust using FUSE.

The project started as a small in-memory filesystem and was progressively extended with writable files, SQLite-backed metadata, persistent file contents, deletion, rename, nested directories, timestamps, and automated integration testing.

## Current Features

- FUSE-based userspace filesystem
- Read and write regular files
- Create files with `touch` or shell redirection
- Persistent file contents
- SQLite metadata storage
- Persistent inode allocation
- File deletion with `rm`
- File rename with `mv`
- Directory creation with `mkdir`
- Empty-directory removal with `rmdir`
- Nested files and directories
- Cross-directory file moves
- Persistent directory hierarchy
- Persistent `atime`, `mtime`, and `ctime`
- File truncate/resize persistence
- Restart/remount persistence
- Automated integration test suite

## Architecture

CCFS currently uses three main Rust modules:

```text
src/
├── main.rs
├── db.rs
└── storage.rs
```

### `main.rs`

Contains the FUSE filesystem implementation.

It manages:

- inode allocation
- in-memory filesystem state
- lookup
- attributes
- directory listing
- file creation
- directory creation
- reads
- writes
- rename
- unlink
- rmdir
- timestamp updates
- mounting the filesystem

### `db.rs`

Handles persistent filesystem metadata using SQLite.

Metadata includes:

- inode
- parent inode
- name
- entry type
- permissions
- size
- access time
- modification time
- change time

The SQLite database is stored at:

```text
volume/metadata.db
```

### `storage.rs`

Handles persistent file contents.

Each regular file is stored using its inode:

```text
volume/blocks/<inode>.bin
```

For example:

```text
volume/blocks/10.bin
```

This separates filesystem metadata from file contents.

## Persistent Storage Layout

```text
ccfs/
├── src/
│   ├── main.rs
│   ├── db.rs
│   └── storage.rs
├── tests/
│   └── integration.sh
├── volume/
│   └── blocks/
│       └── .gitkeep
├── mount/
├── Cargo.toml
├── Cargo.lock
├── .gitignore
└── README.md
```

Runtime database and file blocks are intentionally not committed to Git.

## Requirements

The project is currently developed and tested on Linux.

Typical Ubuntu dependencies:

```bash
sudo apt update
sudo apt install -y \
    fuse3 \
    libfuse3-dev \
    pkg-config \
    sqlite3
```

Install Rust with `rustup` if Rust is not already installed.

Verify the tools:

```bash
rustc --version
cargo --version
fusermount3 --version
sqlite3 --version
```

## Build

From the project root:

```bash
cargo build
```

For a compile check:

```bash
cargo check
```

For formatting:

```bash
cargo fmt
```

## Run

Make sure the mount directory exists:

```bash
mkdir -p mount
```

Start CCFS:

```bash
cargo run
```

Expected output is similar to:

```text
SQLite metadata database ready.
CCFS metadata-aware filesystem mounting at: mount
Press Ctrl+C to stop the filesystem.
```

Keep that terminal running.

Use another terminal to interact with the mounted filesystem.

## Example Usage

Create a file:

```bash
echo "Hello CCFS" > mount/example.txt
```

Read it:

```bash
cat mount/example.txt
```

List files:

```bash
ls -la mount
```

Rename it:

```bash
mv mount/example.txt mount/renamed.txt
```

Delete it:

```bash
rm mount/renamed.txt
```

Create a directory:

```bash
mkdir mount/docs
```

Create a nested file:

```bash
echo "Nested CCFS data" > mount/docs/test.txt
```

Read it:

```bash
cat mount/docs/test.txt
```

Move a file across directories:

```bash
mkdir mount/archive
mv mount/docs/test.txt mount/archive/test.txt
```

Remove an empty directory:

```bash
rmdir mount/docs
```

## Unmount

Unmount CCFS with:

```bash
fusermount3 -u mount
```

If a CCFS process is still running, stop it with `Ctrl+C`.

## Persistence

CCFS persists both metadata and file contents.

Metadata is stored in:

```text
volume/metadata.db
```

File contents are stored in:

```text
volume/blocks/
```

Example persistence test:

```bash
echo "persistent data" > mount/persist.txt
cat mount/persist.txt
fusermount3 -u mount
```

Start CCFS again:

```bash
cargo run
```

Then verify:

```bash
cat mount/persist.txt
```

The file and its contents should still exist.

## Automated Integration Tests

CCFS includes an integration test script:

```text
tests/integration.sh
```

Run it from the project root:

```bash
./tests/integration.sh
```

The test suite verifies:

1. project build
2. filesystem mounting
3. directory creation
4. file creation and reading
5. rename with inode preservation
6. cross-directory move
7. SQLite metadata consistency
8. restart persistence
9. persistent deletion
10. file block cleanup
11. directory removal

A successful run ends with:

```text
========================================
 ALL CCFS INTEGRATION TESTS PASSED
========================================
```

## Development Milestones

### Milestone 1 — Basic FUSE filesystem

Implemented basic mounting and file access.

### Milestone 2 — Writable files

Added in-memory file creation, reading, and writing.

### Milestone 3 — Metadata persistence

Added SQLite-backed filesystem metadata.

### Milestone 4 — File-content persistence

Added inode-based persistent file-content storage.

### Milestone 5 — Persistent deletion

Added deletion across memory, SQLite metadata, and block storage.

### Milestone 6 — Persistent rename

Added file rename while preserving inode and contents.

### Milestone 7 — Persistent directories

Added nested directories, nested files, cross-directory moves, and `rmdir`.

### Milestone 8 — Persistent timestamps

Added persistent access, modification, and change timestamps.

### Milestone 9 — Integration testing

Added automated end-to-end filesystem regression testing.

## Current Limitations

CCFS is currently a learning/research filesystem prototype, not a production filesystem.

Not yet fully implemented:

- symbolic links
- hard links
- extended attributes
- production-grade locking
- crash-consistent multi-step transactions
- full POSIX ownership behavior
- advanced rename flags
- atomic overwrite semantics
- quota management
- production security hardening
- large-scale performance optimization

## Technology

- Rust
- FUSE / `fuser`
- SQLite / `rusqlite`
- Linux
- Bash integration testing

## Status

Current development status:

```text
Persistent files          ✅
Persistent contents       ✅
Persistent metadata       ✅
Persistent deletion       ✅
Persistent rename         ✅
Persistent directories    ✅
Persistent timestamps     ✅
Integration tests         ✅
Production ready          ❌
```

CCFS is actively evolving toward a more complete persistent userspace filesystem.