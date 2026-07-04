//! Injectable clock (DESIGN.md §3.2: "all times are the daemon's clock").
//! Needed so the stale-sweep (24h) test doesn't have to sleep for a day.

use std::sync::atomic::{AtomicI64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

pub trait Clock: Send + Sync + 'static {
    /// Current time, epoch seconds.
    fn now(&self) -> i64;
}

#[derive(Debug, Default)]
pub struct SystemClock;

impl Clock for SystemClock {
    fn now(&self) -> i64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock is before UNIX_EPOCH")
            .as_secs() as i64
    }
}

/// A manually-advanced clock for tests.
#[derive(Debug)]
pub struct FakeClock {
    now: AtomicI64,
}

impl FakeClock {
    pub fn new(start: i64) -> Self {
        Self {
            now: AtomicI64::new(start),
        }
    }

    pub fn advance(&self, secs: i64) {
        self.now.fetch_add(secs, Ordering::SeqCst);
    }

    pub fn set(&self, value: i64) {
        self.now.store(value, Ordering::SeqCst);
    }
}

impl Clock for FakeClock {
    fn now(&self) -> i64 {
        self.now.load(Ordering::SeqCst)
    }
}
