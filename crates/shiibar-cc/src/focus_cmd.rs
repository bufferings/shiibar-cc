//! `shiibar-cc focus <selector>` / `focused` (DESIGN.md §4.4).
//!
//! `run_focus` funnels through `jump_to`, which is the part that actually
//! talks to the terminal and the daemon; this is what `focus`'s exit 2 (no
//! matching session, or a `process:` target that has no tab) and exit 3
//! (TCC denied) tests exercise by injecting a fake `AppleScriptRunner` — no
//! real `osascript` is ever invoked in this crate's automated tests either.

use crate::exitcode;
use shiibar_cc_client::selector::{SelectError, Selector, resolve_selector};
use shiibar_cc_client::terminal::{
    AppleScriptRunner, TerminalError, focus, focused, is_process_target,
};
use shiibar_cc_proto::{AckResponse, ListResponse, Request};
use std::path::{Path, PathBuf};

/// stderr for a `process:` target (§4.4): the session runs in a terminal
/// shiibar can't drive, so there is no tab to jump to. Kept distinct from
/// `NO_MATCHING_SESSION_MESSAGE` (a tab that is gone) so a caller can tell
/// the two exit-2 cases apart.
pub const PROCESS_TARGET_MESSAGE: &str =
    "shiibar-cc focus: the session is running in a terminal Shiibar CC can't drive; there is no tab to jump to";

/// stderr when the terminal scan finds no session for the target (§4.4).
pub const NO_MATCHING_SESSION_MESSAGE: &str =
    "shiibar-cc focus: no matching terminal session (tab may be closed)";

pub struct FocusReport {
    pub exit_code: i32,
    pub message: Option<String>,
}

fn ok() -> FocusReport {
    FocusReport {
        exit_code: exitcode::OK,
        message: None,
    }
}

fn err(code: i32, msg: impl Into<String>) -> FocusReport {
    FocusReport {
        exit_code: code,
        message: Some(msg.into()),
    }
}

/// `focus <selector>` (§4.4 "focus's selector resolution"): an exact-match
/// target *is* the destination, so it goes straight to `jump_to` without
/// consulting the daemon's `list` — the jump can succeed even if the
/// daemon is down or the entry has gone stale, as long as the iTerm2 tab
/// itself is still alive ("no match" there is exit 2, from iTerm2 scanning
/// failing rather than from selector resolution). Only `.` (cwd match)
/// needs the daemon's `list` to resolve, since "which agent's cwd matches
/// mine" isn't answerable from the selector alone.
pub fn run_focus(
    socket_path: &Path,
    selector_arg: &str,
    cwd: PathBuf,
    runner: &dyn AppleScriptRunner,
) -> FocusReport {
    let selector = Selector::parse(selector_arg, cwd);

    let dest_target = match selector {
        Selector::Target(t) => t,
        Selector::Cwd(_) => {
            let agents = match shiibar_cc_client::connection::request::<ListResponse>(
                socket_path,
                &Request::List,
            ) {
                Ok(resp) => resp.agents,
                Err(e) => return err(exitcode::ERROR, format!("shiibar-cc focus: {e}")),
            };

            match resolve_selector(&selector, &agents) {
                Ok(agent) => agent.target.clone(),
                Err(SelectError::NoMatch) => {
                    return err(
                        exitcode::NOT_FOUND,
                        "shiibar-cc focus: no agent matches the given selector",
                    );
                }
                Err(SelectError::Ambiguous(n)) => {
                    return err(
                        exitcode::ERROR,
                        format!(
                            "shiibar-cc focus: selector matches {n} agents; use an exact target"
                        ),
                    );
                }
            }
        }
    };

    jump_to(socket_path, &dest_target, runner)
}

/// `focused` (§4.4): the frontmost iTerm2 session's target, or "none".
pub struct FocusedReport {
    pub exit_code: i32,
    pub target: Option<String>,
    pub message: Option<String>,
}

pub fn run_focused(runner: &dyn AppleScriptRunner) -> FocusedReport {
    match focused(runner) {
        Ok(Some(target)) => FocusedReport {
            exit_code: exitcode::OK,
            target: Some(target),
            message: None,
        },
        Ok(None) => FocusedReport {
            exit_code: exitcode::NOT_FOUND,
            target: None,
            message: None,
        },
        Err(TerminalError::PermissionDenied) => FocusedReport {
            exit_code: exitcode::TCC_DENIED,
            target: None,
            message: Some(
                "shiibar-cc focused: osascript automation permission for the terminal is denied"
                    .to_string(),
            ),
        },
        Err(e) => FocusedReport {
            exit_code: exitcode::ERROR,
            target: None,
            message: Some(format!("shiibar-cc focused: {e}")),
        },
    }
}

/// Shared jump logic (§4.4): do the jump, and on success notify the daemon
/// via `seen` (best-effort — a successful jump is the primary outcome, and
/// a daemon that's down must not turn it into a reported failure).
///
/// A `process:` target — given exactly, or resolved from `.` — is exit 2
/// with its own message and runs no osascript: the session is in a terminal
/// shiibar can't drive, so there is nothing to jump to (§4.4).
fn jump_to(socket_path: &Path, dest_target: &str, runner: &dyn AppleScriptRunner) -> FocusReport {
    if is_process_target(dest_target) {
        return err(exitcode::NOT_FOUND, PROCESS_TARGET_MESSAGE);
    }
    if let Err(e) = focus(dest_target, runner) {
        return match e {
            TerminalError::NoMatch => err(exitcode::NOT_FOUND, NO_MATCHING_SESSION_MESSAGE),
            TerminalError::PermissionDenied => err(
                exitcode::TCC_DENIED,
                "shiibar-cc focus: osascript automation permission for the terminal is denied",
            ),
            TerminalError::Other(msg) => err(exitcode::ERROR, format!("shiibar-cc focus: {msg}")),
        };
    }

    if let Err(e) = shiibar_cc_client::connection::request::<AckResponse>(
        socket_path,
        &Request::Seen {
            target: dest_target.to_string(),
        },
    ) {
        eprintln!("shiibar-cc focus: warning: failed to notify daemon (seen): {e}");
    }

    ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use shiibar_cc_client::terminal::AppleScriptOutput;
    use std::sync::Mutex;

    /// A fake `AppleScriptRunner` that returns pre-scripted outputs in
    /// order (one per call).
    struct ScriptedRunner {
        outputs: Mutex<Vec<AppleScriptOutput>>,
    }

    impl ScriptedRunner {
        fn new(outputs: Vec<AppleScriptOutput>) -> Self {
            Self {
                outputs: Mutex::new(outputs),
            }
        }
    }

    impl AppleScriptRunner for ScriptedRunner {
        fn run(&self, _script: &str) -> std::io::Result<AppleScriptOutput> {
            let mut outputs = self.outputs.lock().unwrap();
            assert!(
                !outputs.is_empty(),
                "ScriptedRunner ran out of canned outputs"
            );
            Ok(outputs.remove(0))
        }
    }

    fn out(success: bool, stdout: &str, stderr: &str) -> AppleScriptOutput {
        AppleScriptOutput {
            success,
            stdout: stdout.to_string(),
            stderr: stderr.to_string(),
        }
    }

    /// The iterm2 module's answer to its preliminary running query, sent
    /// before every iTerm2 script other than resume.
    fn iterm2_running() -> AppleScriptOutput {
        out(true, "RUNNING\n", "")
    }

    /// No daemon at `socket_path` in any of these tests: `jump_to`'s
    /// iTerm2 interaction is what's under test, and a `seen` failure must
    /// not change the exit code (best-effort, per the doc comment above).
    fn dead_socket(dir: &std::path::Path) -> std::path::PathBuf {
        dir.join("no-such-socket")
    }

    #[test]
    fn focus_no_matching_session_is_exit_2() {
        let dir = tempfile::tempdir().unwrap();
        let runner = ScriptedRunner::new(vec![iterm2_running(), out(true, "NOTFOUND\n", "")]);
        let report = jump_to(&dead_socket(dir.path()), "w0t0p0:UUID", &runner);
        assert_eq!(report.exit_code, exitcode::NOT_FOUND);
    }

    #[test]
    fn focus_when_iterm2_is_not_running_is_exit_2_after_only_the_running_query() {
        let dir = tempfile::tempdir().unwrap();
        let runner = ScriptedRunner::new(vec![out(true, "NOT_RUNNING\n", "")]);
        let report = jump_to(&dead_socket(dir.path()), "w0t0p0:UUID", &runner);
        assert_eq!(report.exit_code, exitcode::NOT_FOUND);
        assert_eq!(report.message.as_deref(), Some(NO_MATCHING_SESSION_MESSAGE));
        assert!(runner.outputs.lock().unwrap().is_empty());
    }

    #[test]
    fn focus_tcc_denied_is_exit_3() {
        let dir = tempfile::tempdir().unwrap();
        let runner = ScriptedRunner::new(vec![iterm2_running(), out(
            false,
            "",
            "Not authorized to send Apple events to iTerm2. (-1743)",
        )]);
        let report = jump_to(&dead_socket(dir.path()), "w0t0p0:UUID", &runner);
        assert_eq!(report.exit_code, exitcode::TCC_DENIED);
    }

    #[test]
    fn successful_focus_ignores_seen_failure() {
        // The daemon is dead, so the post-jump `seen` fails — the jump
        // still reports success (§4.4: seen is best-effort).
        let dir = tempfile::tempdir().unwrap();
        let runner = ScriptedRunner::new(vec![iterm2_running(), out(true, "FOUND\n", "")]);
        let report = jump_to(&dead_socket(dir.path()), "w0t0p0:DEST-UUID", &runner);
        assert_eq!(report.exit_code, exitcode::OK);
    }

    // ---- run_focus: exact-match target bypasses the daemon entirely
    // (DESIGN.md §4.4 "focus's selector resolution"), `.` still needs it ----

    #[test]
    fn run_focus_with_exact_target_jumps_without_the_daemon() {
        // The socket doesn't even exist (dead, not just unreachable): an
        // exact-match target is the destination itself, so `run_focus`
        // must never try to reach the daemon's `list` before jumping.
        let dir = tempfile::tempdir().unwrap();
        let runner = ScriptedRunner::new(vec![iterm2_running(), out(true, "FOUND\n", "")]);
        let report = run_focus(
            &dead_socket(dir.path()),
            "w0t0p0:UUID",
            dir.path().to_path_buf(),
            &runner,
        );
        assert_eq!(report.exit_code, exitcode::OK, "message={:?}", report.message);
    }

    #[test]
    fn run_focus_with_exact_target_and_no_iterm_match_is_exit_2() {
        // Still no daemon involved: "no match" here is iTerm2's scan
        // coming up empty, not a selector-resolution failure.
        let dir = tempfile::tempdir().unwrap();
        let runner = ScriptedRunner::new(vec![iterm2_running(), out(true, "NOTFOUND\n", "")]);
        let report = run_focus(
            &dead_socket(dir.path()),
            "w0t0p0:UUID",
            dir.path().to_path_buf(),
            &runner,
        );
        assert_eq!(report.exit_code, exitcode::NOT_FOUND);
    }

    #[test]
    fn run_focus_with_dot_selector_still_requires_the_daemon() {
        // `.` can't be resolved from the selector alone (which agent's cwd
        // matches mine?), so this must still hit `list` — and with a dead
        // socket that fails before osascript is ever touched.
        let dir = tempfile::tempdir().unwrap();
        let report = run_focus(
            &dead_socket(dir.path()),
            ".",
            dir.path().to_path_buf(),
            &PanicRunner,
        );
        assert_eq!(report.exit_code, exitcode::ERROR);
    }

    // ---- process: targets (DESIGN.md §4.4): exit 2, no osascript, and a
    // message distinct from the closed-tab one ----

    struct PanicRunner;
    impl AppleScriptRunner for PanicRunner {
        fn run(&self, _script: &str) -> std::io::Result<AppleScriptOutput> {
            panic!("osascript must not run for a process: target");
        }
    }

    #[test]
    fn run_focus_with_an_exact_process_target_is_exit_2_without_osascript() {
        let dir = tempfile::tempdir().unwrap();
        let report = run_focus(
            &dead_socket(dir.path()),
            "process:48213",
            dir.path().to_path_buf(),
            &PanicRunner,
        );
        assert_eq!(report.exit_code, exitcode::NOT_FOUND);
        assert_eq!(report.message.as_deref(), Some(PROCESS_TARGET_MESSAGE));
    }

    #[test]
    fn jump_to_a_process_target_resolved_from_dot_is_exit_2_without_osascript() {
        // `.` resolves to an entry's target before `jump_to`; a `process:`
        // entry takes the same path as the exact target.
        let dir = tempfile::tempdir().unwrap();
        let report = jump_to(&dead_socket(dir.path()), "process:48213", &PanicRunner);
        assert_eq!(report.exit_code, exitcode::NOT_FOUND);
        assert_eq!(report.message.as_deref(), Some(PROCESS_TARGET_MESSAGE));
    }

    #[test]
    fn process_target_message_differs_from_the_closed_tab_message() {
        let dir = tempfile::tempdir().unwrap();
        let runner = ScriptedRunner::new(vec![iterm2_running(), out(true, "NOTFOUND\n", "")]);
        let closed_tab = jump_to(&dead_socket(dir.path()), "w0t0p0:UUID", &runner);
        assert_eq!(closed_tab.exit_code, exitcode::NOT_FOUND);
        assert_eq!(closed_tab.message.as_deref(), Some(NO_MATCHING_SESSION_MESSAGE));
        assert_ne!(PROCESS_TARGET_MESSAGE, NO_MATCHING_SESSION_MESSAGE);
    }

    // ---- run_focused: exit-code mapping (§4.4) ----

    #[test]
    fn run_focused_with_a_frontmost_iterm2_session_is_exit_0_with_its_prefixed_target() {
        // `terminal::focused` asks iTerm2 first (its running query, then
        // its focused script); a hit there returns the prefixed target and
        // Terminal.app is never queried (two canned outputs are enough).
        let runner = ScriptedRunner::new(vec![iterm2_running(), out(true, "FOCUSED:UUID-1\n", "")]);
        let report = run_focused(&runner);
        assert_eq!(report.exit_code, exitcode::OK);
        assert_eq!(report.target, Some("iterm2:UUID-1".to_string()));
        assert_eq!(report.message, None);
    }

    #[test]
    fn run_focused_with_neither_terminal_frontmost_is_exit_2() {
        // No supported terminal is frontmost: iTerm2 answers its running
        // query as running, the iTerm2 and Terminal.app `focused` scripts
        // answer NONE, and Ghostty's version query answers not running, so
        // four canned outputs are consumed.
        let runner = ScriptedRunner::new(vec![
            iterm2_running(),
            out(true, "NONE\n", ""),
            out(true, "NONE\n", ""),
            out(true, "NOT_RUNNING\n", ""),
        ]);
        let report = run_focused(&runner);
        assert_eq!(report.exit_code, exitcode::NOT_FOUND);
        assert_eq!(report.target, None);
    }

    #[test]
    fn run_focused_with_tcc_denied_is_exit_3() {
        let runner = ScriptedRunner::new(vec![iterm2_running(), out(
            false,
            "",
            "Not authorized to send Apple events to System Events. (-1743)",
        )]);
        let report = run_focused(&runner);
        assert_eq!(report.exit_code, exitcode::TCC_DENIED);
        assert!(report.message.is_some());
    }

    #[test]
    fn run_focused_with_other_osascript_error_is_exit_1() {
        let runner = ScriptedRunner::new(vec![iterm2_running(), out(false, "", "some other osascript error")]);
        let report = run_focused(&runner);
        assert_eq!(report.exit_code, exitcode::ERROR);
        assert!(report.message.is_some());
    }
}
