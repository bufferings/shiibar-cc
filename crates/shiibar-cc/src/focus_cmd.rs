//! `shiibar-cc focus <selector>` / `focus -` / `focused` (DESIGN.md §4.4).
//!
//! `run_focus` and `run_focus_back` both funnel through `jump_to`, which is
//! the part that actually talks to iTerm2 and the daemon; this is what
//! `focus`'s exit 2 (no matching session) and exit 3 (TCC denied) tests
//! exercise by injecting a fake `AppleScriptRunner` — no real `osascript`
//! is ever invoked in this crate's automated tests either.

use crate::exitcode;
use shiibar_cc_client::iterm::{AppleScriptRunner, ItermError, focus, focused};
use shiibar_cc_client::selector::{SelectError, Selector, resolve_selector};
use shiibar_cc_proto::{AckResponse, ListResponse, Request};
use std::path::{Path, PathBuf};

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
    last_focus_path: &Path,
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

    jump_to(socket_path, last_focus_path, &dest_target, runner)
}

/// `focus -` (§4.4): jump back to whatever was frontmost the last time
/// `focus` (or `focus -`) succeeded. The saved target is an opaque iTerm2
/// session identity captured via `focused()`, not necessarily a
/// shiibar-ccd-tracked agent, so this bypasses selector/list resolution
/// entirely and jumps to it directly.
pub fn run_focus_back(
    socket_path: &Path,
    last_focus_path: &Path,
    runner: &dyn AppleScriptRunner,
) -> FocusReport {
    let Some(dest_target) = read_last_focus(last_focus_path) else {
        return err(
            exitcode::NOT_FOUND,
            "shiibar-cc focus -: no previous focus recorded",
        );
    };
    jump_to(socket_path, last_focus_path, &dest_target, runner)
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
        Err(ItermError::PermissionDenied) => FocusedReport {
            exit_code: exitcode::TCC_DENIED,
            target: None,
            message: Some(
                "shiibar-cc focused: osascript automation permission for iTerm2 is denied"
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

/// Shared jump logic (§4.4): capture what's frontmost *before* the jump
/// (best-effort — a failure here means osascript can't drive iTerm2 at
/// all, so bail out with the same error the jump itself would hit), do the
/// jump, and only on success record the pre-jump target into `last_focus`
/// and notify the daemon via `seen`.
fn jump_to(
    socket_path: &Path,
    last_focus_path: &Path,
    dest_target: &str,
    runner: &dyn AppleScriptRunner,
) -> FocusReport {
    let before = match focused(runner) {
        Ok(b) => b,
        Err(ItermError::PermissionDenied) => {
            return err(
                exitcode::TCC_DENIED,
                "shiibar-cc focus: osascript automation permission for iTerm2 is denied",
            );
        }
        Err(e) => return err(exitcode::ERROR, format!("shiibar-cc focus: {e}")),
    };

    if let Err(e) = focus(dest_target, runner) {
        return match e {
            ItermError::NoMatch => err(
                exitcode::NOT_FOUND,
                "shiibar-cc focus: no matching iTerm2 session (tab may be closed)",
            ),
            ItermError::PermissionDenied => err(
                exitcode::TCC_DENIED,
                "shiibar-cc focus: osascript automation permission for iTerm2 is denied",
            ),
            ItermError::Other(msg) => err(exitcode::ERROR, format!("shiibar-cc focus: {msg}")),
        };
    }

    // Only save the "where we came from" pointer if there *was* a
    // frontmost iTerm2 session to come from (§4.4 decision, see the M2
    // completion report).
    if let Some(before_target) = before
        && let Err(e) = std::fs::write(last_focus_path, before_target)
    {
        eprintln!("shiibar-cc focus: warning: failed to save last_focus: {e}");
    }

    // Best-effort: a successful jump is the primary outcome; a failure to
    // notify the daemon (e.g. it's not running) shouldn't turn a
    // successful jump into a reported failure.
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

fn read_last_focus(path: &Path) -> Option<String> {
    std::fs::read_to_string(path)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;
    use shiibar_cc_client::iterm::AppleScriptOutput;
    use std::sync::Mutex;

    /// A fake `AppleScriptRunner` that returns pre-scripted outputs in
    /// order (one per call: first call is `focused()`'s script, second is
    /// `focus()`'s), so both the "before" query and the jump can be
    /// controlled independently.
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

    /// No daemon at `socket_path` in any of these tests: `jump_to`'s
    /// iTerm2 interaction is what's under test, and a `seen` failure must
    /// not change the exit code (best-effort, per the doc comment above).
    fn dead_socket(dir: &std::path::Path) -> std::path::PathBuf {
        dir.join("no-such-socket")
    }

    #[test]
    fn focus_no_matching_session_is_exit_2() {
        let dir = tempfile::tempdir().unwrap();
        let runner = ScriptedRunner::new(vec![
            out(true, "NONE\n", ""),     // focused() before the jump
            out(true, "NOTFOUND\n", ""), // focus() itself
        ]);
        let report = jump_to(
            &dead_socket(dir.path()),
            &dir.path().join("last_focus"),
            "w0t0p0:UUID",
            &runner,
        );
        assert_eq!(report.exit_code, exitcode::NOT_FOUND);
        assert!(
            !dir.path().join("last_focus").exists(),
            "no before-target to save"
        );
    }

    #[test]
    fn focus_tcc_denied_on_the_jump_itself_is_exit_3() {
        let dir = tempfile::tempdir().unwrap();
        let runner = ScriptedRunner::new(vec![
            out(true, "NONE\n", ""),
            out(
                false,
                "",
                "Not authorized to send Apple events to iTerm2. (-1743)",
            ),
        ]);
        let report = jump_to(
            &dead_socket(dir.path()),
            &dir.path().join("last_focus"),
            "w0t0p0:UUID",
            &runner,
        );
        assert_eq!(report.exit_code, exitcode::TCC_DENIED);
    }

    #[test]
    fn focus_tcc_denied_on_the_before_query_is_exit_3() {
        let dir = tempfile::tempdir().unwrap();
        let runner = ScriptedRunner::new(vec![out(
            false,
            "",
            "Not authorized to send Apple events to System Events. (-1743)",
        )]);
        let report = jump_to(
            &dead_socket(dir.path()),
            &dir.path().join("last_focus"),
            "w0t0p0:UUID",
            &runner,
        );
        assert_eq!(report.exit_code, exitcode::TCC_DENIED);
    }

    #[test]
    fn successful_focus_saves_last_focus_and_ignores_seen_failure() {
        let dir = tempfile::tempdir().unwrap();
        let last_focus_path = dir.path().join("last_focus");
        let runner = ScriptedRunner::new(vec![
            out(true, "FOCUSED:BEFORE-UUID:1:1\n", ""), // focused() before
            out(true, "FOUND\n", ""),                   // focus() succeeds
        ]);
        let report = jump_to(
            &dead_socket(dir.path()),
            &last_focus_path,
            "w0t0p0:DEST-UUID",
            &runner,
        );
        assert_eq!(report.exit_code, exitcode::OK);
        let saved = std::fs::read_to_string(&last_focus_path).unwrap();
        assert_eq!(saved, "w1t1p0:BEFORE-UUID");
    }

    #[test]
    fn focus_back_with_no_last_focus_is_exit_2() {
        let dir = tempfile::tempdir().unwrap();
        struct PanicRunner;
        impl AppleScriptRunner for PanicRunner {
            fn run(&self, _script: &str) -> std::io::Result<AppleScriptOutput> {
                panic!("must not touch osascript when there's nothing to jump back to");
            }
        }
        let report = run_focus_back(
            &dead_socket(dir.path()),
            &dir.path().join("last_focus"),
            &PanicRunner,
        );
        assert_eq!(report.exit_code, exitcode::NOT_FOUND);
    }

    #[test]
    fn focus_back_jumps_to_the_saved_target_and_toggles_it() {
        let dir = tempfile::tempdir().unwrap();
        let last_focus_path = dir.path().join("last_focus");
        std::fs::write(&last_focus_path, "w0t0p0:OLD-UUID").unwrap();

        let runner = ScriptedRunner::new(vec![
            out(true, "FOCUSED:CURRENT-UUID:2:2\n", ""), // focused() before jumping back
            out(true, "FOUND\n", ""),                    // focus() to OLD-UUID succeeds
        ]);
        let report = run_focus_back(&dead_socket(dir.path()), &last_focus_path, &runner);
        assert_eq!(report.exit_code, exitcode::OK);
        // cd -/toggle semantics: last_focus now points at where we jumped
        // *from* this time, ready for a subsequent `focus -` to swap back.
        let saved = std::fs::read_to_string(&last_focus_path).unwrap();
        assert_eq!(saved, "w2t2p0:CURRENT-UUID");
    }

    // ---- run_focus: exact-match target bypasses the daemon entirely
    // (DESIGN.md §4.4 "focus's selector resolution"), `.` still needs it ----

    #[test]
    fn run_focus_with_exact_target_jumps_without_the_daemon() {
        // The socket doesn't even exist (dead, not just unreachable): an
        // exact-match target is the destination itself, so `run_focus`
        // must never try to reach the daemon's `list` before jumping.
        let dir = tempfile::tempdir().unwrap();
        let runner = ScriptedRunner::new(vec![
            out(true, "NONE\n", ""),  // focused() before the jump
            out(true, "FOUND\n", ""), // focus() itself
        ]);
        let report = run_focus(
            &dead_socket(dir.path()),
            &dir.path().join("last_focus"),
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
        let runner = ScriptedRunner::new(vec![
            out(true, "NONE\n", ""),
            out(true, "NOTFOUND\n", ""),
        ]);
        let report = run_focus(
            &dead_socket(dir.path()),
            &dir.path().join("last_focus"),
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
        struct PanicRunner;
        impl AppleScriptRunner for PanicRunner {
            fn run(&self, _script: &str) -> std::io::Result<AppleScriptOutput> {
                panic!("must not touch osascript before the daemon `list` resolves `.`");
            }
        }
        let report = run_focus(
            &dead_socket(dir.path()),
            &dir.path().join("last_focus"),
            ".",
            dir.path().to_path_buf(),
            &PanicRunner,
        );
        assert_eq!(report.exit_code, exitcode::ERROR);
    }

    // ---- run_focused: exit-code mapping (§4.4) ----

    #[test]
    fn run_focused_with_a_frontmost_session_is_exit_0_with_its_target() {
        let runner = ScriptedRunner::new(vec![out(true, "FOCUSED:UUID-1:1:2\n", "")]);
        let report = run_focused(&runner);
        assert_eq!(report.exit_code, exitcode::OK);
        assert_eq!(report.target, Some("w1t2p0:UUID-1".to_string()));
        assert_eq!(report.message, None);
    }

    #[test]
    fn run_focused_with_iterm2_not_frontmost_is_exit_2() {
        let runner = ScriptedRunner::new(vec![out(true, "NONE\n", "")]);
        let report = run_focused(&runner);
        assert_eq!(report.exit_code, exitcode::NOT_FOUND);
        assert_eq!(report.target, None);
    }

    #[test]
    fn run_focused_with_tcc_denied_is_exit_3() {
        let runner = ScriptedRunner::new(vec![out(
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
        let runner = ScriptedRunner::new(vec![out(false, "", "some other osascript error")]);
        let report = run_focused(&runner);
        assert_eq!(report.exit_code, exitcode::ERROR);
        assert!(report.message.is_some());
    }
}
