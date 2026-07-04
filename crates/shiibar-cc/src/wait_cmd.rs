//! `shiibar-cc wait <selector> --status STATUS [--timeout SEC]` (DESIGN.md
//! §4.4): thin exit-code mapping over `shiibar_cc_client::wait`.

use crate::exitcode;
use shiibar_cc_client::selector::Selector;
use shiibar_cc_client::wait::{WaitError, WaitOutcome, wait};
use shiibar_cc_proto::Status;
use std::path::{Path, PathBuf};
use std::time::Duration;

pub fn parse_status(s: &str) -> Option<Status> {
    match s {
        "idle" => Some(Status::Idle),
        "working" => Some(Status::Working),
        "waiting" => Some(Status::Waiting),
        _ => None,
    }
}

pub fn run_wait(
    socket_path: &Path,
    selector_arg: &str,
    cwd: PathBuf,
    want: Status,
    timeout: Option<Duration>,
) -> (i32, Option<String>) {
    let selector = Selector::parse(selector_arg, cwd);
    match wait(socket_path, &selector, want, timeout) {
        Ok(WaitOutcome::Matched(_)) => (exitcode::OK, None),
        Ok(WaitOutcome::Removed) => (
            exitcode::NOT_FOUND,
            Some("shiibar-cc wait: the target agent was removed while waiting".to_string()),
        ),
        Ok(WaitOutcome::TimedOut) => (
            exitcode::TIMEOUT,
            Some("shiibar-cc wait: timed out waiting for the status".to_string()),
        ),
        Err(WaitError::AmbiguousSelector(n)) => (
            exitcode::ERROR,
            Some(format!(
                "shiibar-cc wait: selector matches {n} agents; use an exact target"
            )),
        ),
        Err(WaitError::Client(e)) => (exitcode::ERROR, Some(format!("shiibar-cc wait: {e}"))),
    }
}
