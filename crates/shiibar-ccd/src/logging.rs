//! Minimal stderr logger (§4.2 Operations): level via `SHIIBAR_CC_LOG`
//! (error/info/debug, default info). `report` receipt logs at debug,
//! transitions and removals log at info.
//!
//! No external logging crate is pulled in for this — the need (leveled,
//! one-line-per-event, stderr) is small enough to hand-roll and keeps the
//! dependency set matching the workspace skeleton.

use std::fmt::Arguments;
use std::io::Write;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Level {
    Error,
    Info,
    Debug,
}

impl Level {
    fn as_str(self) -> &'static str {
        match self {
            Level::Error => "error",
            Level::Info => "info",
            Level::Debug => "debug",
        }
    }

    fn from_env_str(s: &str) -> Option<Self> {
        match s.to_ascii_lowercase().as_str() {
            "error" => Some(Level::Error),
            "info" => Some(Level::Info),
            "debug" => Some(Level::Debug),
            _ => None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct Logger {
    threshold: Level,
}

impl Logger {
    pub fn from_env() -> Self {
        let threshold = std::env::var("SHIIBAR_CC_LOG")
            .ok()
            .and_then(|v| Level::from_env_str(&v))
            .unwrap_or(Level::Info);
        Self { threshold }
    }

    pub fn new(threshold: Level) -> Self {
        Self { threshold }
    }

    pub fn error(&self, args: Arguments<'_>) {
        self.log(Level::Error, args);
    }

    pub fn info(&self, args: Arguments<'_>) {
        self.log(Level::Info, args);
    }

    pub fn debug(&self, args: Arguments<'_>) {
        self.log(Level::Debug, args);
    }

    fn log(&self, level: Level, args: Arguments<'_>) {
        if level > self.threshold {
            return;
        }
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let _ = writeln!(std::io::stderr(), "{now} {} {args}", level.as_str());
    }
}

#[macro_export]
macro_rules! log_error {
    ($logger:expr, $($arg:tt)*) => { $logger.error(format_args!($($arg)*)) };
}

#[macro_export]
macro_rules! log_info {
    ($logger:expr, $($arg:tt)*) => { $logger.info(format_args!($($arg)*)) };
}

#[macro_export]
macro_rules! log_debug {
    ($logger:expr, $($arg:tt)*) => { $logger.debug(format_args!($($arg)*)) };
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ord_matches_verbosity() {
        assert!(Level::Error < Level::Info);
        assert!(Level::Info < Level::Debug);
    }
}
