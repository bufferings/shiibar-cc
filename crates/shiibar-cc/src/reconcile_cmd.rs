//! `shiibar-cc reconcile` (DESIGN.md §3.5/§4.4): gather the live session list
//! (`claude agents --json` + the terminal scans, done by
//! `shiibar_cc_client::reconcile::gather`) and send it to the daemon as
//! `{"cmd":"reconcile",...}`.

use crate::exitcode;
use shiibar_cc_client::reconcile::{ClaudeAgentsRunner, gather};
use shiibar_cc_client::terminal::{AppleScriptRunner, PsRunner};
use shiibar_cc_proto::{AckResponse, Request};
use std::path::Path;

/// Runs the gather + send round trip. Exit codes (§4.4 common rule):
/// - 0: request sent — including a `complete:false` one after a degraded
///   scan (reported on stderr, informational: pruning was skipped).
/// - 1: daemon unreachable.
/// - 3: some terminal's osascript Automation (TCC) permission is denied.
///   The request is **still sent first** (§3.5/§4.4): one terminal's denial
///   must not stop the other terminals' sessions and the `process:`
///   sessions from being reconciled. The round is `complete:false`. If
///   sending also fails, the connection error (exit 1) is reported instead.
pub fn run_reconcile(
    socket_path: &Path,
    claude_runner: &dyn ClaudeAgentsRunner,
    ps_runner: &dyn PsRunner,
    script_runner: &dyn AppleScriptRunner,
) -> (i32, Option<String>) {
    let result = gather(claude_runner, ps_runner, script_runner);
    let request = Request::Reconcile {
        complete: result.complete,
        sessions: result.sessions,
    };
    match shiibar_cc_client::connection::request::<AckResponse>(socket_path, &request) {
        Ok(_) if result.permission_denied => (
            exitcode::TCC_DENIED,
            Some(
                "shiibar-cc reconcile: osascript automation permission for a terminal is denied \
                 (System Settings > Privacy & Security > Automation); sent complete:false with the \
                 sessions the other scans resolved"
                    .to_string(),
            ),
        ),
        Ok(_) if result.complete => (exitcode::OK, None),
        Ok(_) => (
            exitcode::OK,
            Some(
                "shiibar-cc reconcile: a terminal or claude scan was incomplete; sent complete:false \
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

    /// Answers iTerm2's running query as running, the iTerm2 and
    /// Terminal.app scans with zero sessions, and Ghostty's version query
    /// as not running.
    struct FakeScript;
    impl AppleScriptRunner for FakeScript {
        fn run(&self, script: &str) -> std::io::Result<AppleScriptOutput> {
            let stdout = if script == shiibar_cc_client::iterm2::build_running_script() {
                "RUNNING\n"
            } else if script == shiibar_cc_client::ghostty::build_version_script() {
                "NOT_RUNNING\n"
            } else {
                "DONE\t0\n"
            };
            Ok(AppleScriptOutput {
                success: true,
                stdout: stdout.to_string(),
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

    /// A one-shot stand-in for the daemon: accepts one connection, records
    /// the request line, and answers `{"ok":true}`.
    fn fake_daemon(socket: &Path) -> std::thread::JoinHandle<String> {
        use std::io::{BufRead as _, BufReader, Write as _};
        let listener = std::os::unix::net::UnixListener::bind(socket).unwrap();
        std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            (&stream).write_all(b"{\"ok\":true}\n").unwrap();
            line
        })
    }

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

    struct TtyPs;
    impl PsRunner for TtyPs {
        fn run(&self, _pids: &[u32]) -> std::io::Result<PsOutput> {
            Ok(PsOutput {
                success: true,
                stdout: "111 ttys004\n".to_string(),
            })
        }
    }

    #[test]
    fn exits_3_on_tcc_denial_after_sending_the_reconcile() {
        // §4.4: a TCC denial still sends what the gather resolved (here a
        // session no scan could match, sent update-only because the round
        // is incomplete), then exits 3.
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("shiibar-ccd.sock");
        let daemon = fake_daemon(&socket);
        let claude = FakeClaude {
            json: r#"[{"sessionId":"s","cwd":"/c","pid":111,"status":"busy"}]"#.to_string(),
        };
        let (code, err) = run_reconcile(&socket, &claude, &TtyPs, &TccScript);
        assert_eq!(code, exitcode::TCC_DENIED);
        assert!(err.unwrap().contains("automation permission"));

        let sent: Request = serde_json::from_str(daemon.join().unwrap().trim_end()).unwrap();
        match sent {
            Request::Reconcile { complete, sessions } => {
                assert!(!complete);
                assert_eq!(sessions.len(), 1);
                assert_eq!(sessions[0].target, "process:111");
                assert_eq!(sessions[0].pid, Some(111));
                assert!(sessions[0].update_only);
            }
            other => panic!("expected a reconcile request, got {other:?}"),
        }
    }

    #[test]
    fn exits_1_on_tcc_denial_when_the_daemon_is_absent() {
        // The send comes first; when it fails, the connection error wins.
        let dir = tempfile::tempdir().unwrap();
        let claude = FakeClaude {
            json: r#"[{"sessionId":"s","cwd":"/c","pid":111,"status":"busy"}]"#.to_string(),
        };
        let (code, _) = run_reconcile(&dir.path().join("no-socket"), &claude, &TtyPs, &TccScript);
        assert_eq!(code, exitcode::ERROR);
    }

    #[test]
    fn exits_0_after_sending_a_complete_round() {
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("shiibar-ccd.sock");
        let daemon = fake_daemon(&socket);
        let claude = FakeClaude {
            json: r#"[{"sessionId":"s","cwd":"/c","pid":111,"status":"busy"}]"#.to_string(),
        };
        let (code, err) = run_reconcile(&socket, &claude, &TtyPs, &FakeScript);
        assert_eq!(code, exitcode::OK);
        assert!(err.is_none());
        let sent: Request = serde_json::from_str(daemon.join().unwrap().trim_end()).unwrap();
        match sent {
            Request::Reconcile { complete, sessions } => {
                assert!(complete);
                assert_eq!(sessions[0].target, "process:111");
                assert!(!sessions[0].update_only);
            }
            other => panic!("expected a reconcile request, got {other:?}"),
        }
    }
}
