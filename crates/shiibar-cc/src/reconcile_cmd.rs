//! `shiibar-cc reconcile` (DESIGN.md §3.5/§4.4): gather the live session list
//! (`claude agents --json` + the terminal scans, done by
//! `shiibar_cc_client::reconcile::gather`) and send it to the daemon as
//! `{"cmd":"reconcile",...}`.

use crate::exitcode;
use shiibar_cc_client::reconcile::{ClaudeAgentsRunner, gather};
use shiibar_cc_client::terminal::{AppleScriptRunner, PsRunner, TerminalError};
use shiibar_cc_proto::{AckResponse, Request};
use std::path::Path;

/// Runs the gather + send round trip. Exit codes (§4.4 common rule):
/// - 0: request sent — including a `complete:false` one after a degraded
///   scan (reported on stderr, informational: pruning was skipped).
/// - 1: daemon unreachable.
/// - 3: osascript TCC (Automation) permission denied. In this case **no
///   reconcile request is sent at all**: with TCC denied, zero targets can
///   be resolved, so the request would be an empty `complete:false` no-op
///   on the daemon — skipping it keeps "exit 3 = nothing happened, fix the
///   permission" unambiguous (same mapping as `focus`/`focused`).
pub fn run_reconcile(
    socket_path: &Path,
    claude_runner: &dyn ClaudeAgentsRunner,
    ps_runner: &dyn PsRunner,
    script_runner: &dyn AppleScriptRunner,
) -> (i32, Option<String>) {
    let result = match gather(claude_runner, ps_runner, script_runner) {
        Ok(r) => r,
        Err(TerminalError::PermissionDenied) => {
            return (
                exitcode::TCC_DENIED,
                Some(
                    "shiibar-cc reconcile: osascript automation permission for the terminal is denied \
                     (System Settings > Privacy & Security > Automation); nothing was sent"
                        .to_string(),
                ),
            );
        }
        // gather only errors on TCC today; anything else is defensive.
        Err(e) => return (exitcode::ERROR, Some(format!("shiibar-cc reconcile: {e}"))),
    };
    let request = Request::Reconcile {
        complete: result.complete,
        sessions: result.sessions,
    };
    match shiibar_cc_client::connection::request::<AckResponse>(socket_path, &request) {
        Ok(_) if result.complete => (exitcode::OK, None),
        Ok(_) => (
            exitcode::OK,
            Some(
                "shiibar-cc reconcile: iTerm2/claude scan was incomplete; sent complete:false \
                 (pruning skipped this round, adds/updates still applied)"
                    .to_string(),
            ),
        ),
        Err(e) => (exitcode::ERROR, Some(format!("shiibar-cc reconcile: {e}"))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use shiibar_cc_client::terminal::{AppleScriptOutput, PsOutput};

    struct FakeClaude {
        json: String,
    }

    impl ClaudeAgentsRunner for FakeClaude {
        fn run(&self) -> std::io::Result<String> {
            Ok(self.json.clone())
        }
    }

    struct FakePs;
    impl PsRunner for FakePs {
        fn run(&self, _pids: &[u32]) -> std::io::Result<PsOutput> {
            Ok(PsOutput {
                success: true,
                stdout: String::new(),
            })
        }
    }

    struct FakeScript;
    impl AppleScriptRunner for FakeScript {
        fn run(&self, _script: &str) -> std::io::Result<AppleScriptOutput> {
            Ok(AppleScriptOutput {
                success: true,
                stdout: "DONE\t0\n".to_string(),
                stderr: String::new(),
            })
        }
    }

    #[test]
    fn exits_1_when_the_daemon_is_absent() {
        let dir = tempfile::tempdir().unwrap();
        let claude = FakeClaude { json: "[]".to_string() };
        let (code, err) = run_reconcile(&dir.path().join("no-socket"), &claude, &FakePs, &FakeScript);
        assert_eq!(code, exitcode::ERROR);
        assert!(err.is_some());
    }

    #[test]
    fn exits_3_on_tcc_denial_and_sends_nothing() {
        struct TccScript;
        impl AppleScriptRunner for TccScript {
            fn run(&self, _script: &str) -> std::io::Result<AppleScriptOutput> {
                Ok(AppleScriptOutput {
                    success: false,
                    stdout: String::new(),
                    stderr: "Not authorized to send Apple events to iTerm2. (-1743)".to_string(),
                })
            }
        }
        // A live daemon socket exists here (a plain listener would do), but
        // the point is stronger with none: the TCC branch must return
        // before any socket I/O, so a dead socket must NOT turn this into
        // exit 1.
        let dir = tempfile::tempdir().unwrap();
        let claude = FakeClaude {
            // At least one pid, so iterm_targets actually runs the script
            // (it short-circuits on an empty pid list).
            json: r#"[{"sessionId":"s","cwd":"/c","pid":111,"status":"busy"}]"#.to_string(),
        };
        let (code, err) = run_reconcile(&dir.path().join("no-socket"), &claude, &FakePs, &TccScript);
        assert_eq!(code, exitcode::TCC_DENIED);
        assert!(err.unwrap().contains("automation permission"));
    }
}
