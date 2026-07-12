//! Whole-catch-up exclusion: an advisory `flock` on `<DB path>.lock`
//! (DESIGN.md §4.4/§4.6). Deriving the lock path from the DB path means it
//! automatically follows DB-path injection, so tests never lock the real
//! state dir. The OS releases the lock when the holding process dies — a
//! stuck lock cannot happen.
//!
//! Uses std's file locking (flock semantics on macOS): the lock is held
//! for the lifetime of the open file and released on drop/close.

use std::fs::{File, OpenOptions, TryLockError};
use std::io;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

/// Held exclusive lock; released when dropped (or when the process dies).
#[derive(Debug)]
pub struct CatchUpLock {
    _file: File,
}

/// `<DB path>.lock` — appended to the full file name, not an extension
/// swap ("conversations-index.db.lock").
pub fn lock_path_for(db_path: &Path) -> PathBuf {
    let mut name = db_path.as_os_str().to_os_string();
    name.push(".lock");
    PathBuf::from(name)
}

fn open_lock_file(path: &Path) -> io::Result<File> {
    OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .mode(0o600)
        .open(path)
}

/// Block until the exclusive lock is acquired.
pub fn acquire_blocking(lock_path: &Path) -> io::Result<CatchUpLock> {
    let file = open_lock_file(lock_path)?;
    file.lock()?;
    Ok(CatchUpLock { _file: file })
}

/// Try once; `Ok(None)` when another holder has it.
pub fn try_acquire(lock_path: &Path) -> io::Result<Option<CatchUpLock>> {
    let file = open_lock_file(lock_path)?;
    match file.try_lock() {
        Ok(()) => Ok(Some(CatchUpLock { _file: file })),
        Err(TryLockError::WouldBlock) => Ok(None),
        Err(TryLockError::Error(e)) => Err(e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lock_path_appends_to_the_full_file_name() {
        assert_eq!(
            lock_path_for(Path::new("/tmp/state/conversations-index.db")),
            PathBuf::from("/tmp/state/conversations-index.db.lock")
        );
    }

    #[test]
    fn second_acquire_conflicts_even_within_one_process() {
        // flock is per open file description, so two opens of the same
        // path conflict even in a single process — which is what lets the
        // integration tests reproduce contention.
        let dir = tempfile::tempdir().unwrap();
        let lock_path = lock_path_for(&dir.path().join("db"));
        let held = try_acquire(&lock_path).unwrap();
        assert!(held.is_some());
        let second = try_acquire(&lock_path).unwrap();
        assert!(second.is_none(), "second try_acquire must be refused");
        drop(held);
        let third = try_acquire(&lock_path).unwrap();
        assert!(third.is_some(), "lock must be free after drop");
    }
}
