//! `claude agents --json` gathering for `shiibar-cc reconcile` (DESIGN.md
//! §3.5). This is the "gather" half: parse `claude agents --json`, map its
//! status vocabulary to shiibar's, and resolve each entry's pid to a shiibar
//! target by matching it against **every running supported terminal**
//! (`iterm2::iterm2_targets`, `apple_terminal::apple_terminal_targets`, and
//! `ghostty::ghostty_targets`), falling back to `process:<pid>` for a
//! session that has a tty but matches no scan. The result is what `shiibar-cc` sends as `{"cmd":"reconcile",...}` (§4.2);
//! daemon-side application (add/update/prune) lives in shiibar-ccd, not here.

use crate::terminal::{
    AppleScriptRunner, PsOutput, PsRunner, TerminalError, TerminalResult, has_controlling_tty,
    parse_ps_tty_output,
};
use crate::{apple_terminal, ghostty, iterm2};
use shiibar_cc_proto::extract::process_target_for_pid;
use shiibar_cc_proto::{ReconcileSession, Status};
use std::collections::HashMap;
use std::process::Command;

/// Runs `claude agents --json` and returns its raw stdout. Injected so tests
/// never shell out to the real `claude` binary (DESIGN.md / M2 task brief:
/// "the claude execution part must be injectable").
pub trait ClaudeAgentsRunner {
    fn run(&self) -> std::io::Result<String>;
}

pub struct RealClaudeAgents;

impl ClaudeAgentsRunner for RealClaudeAgents {
    fn run(&self) -> std::io::Result<String> {
        let output = Command::new("claude").args(["agents", "--json"]).output()?;
        Ok(String::from_utf8_lossy(&output.stdout).into_owned())
    }
}

/// One entry from `claude agents --json`, already translated to shiibar's
/// status vocabulary (§3.5/§8.13). Real payload shape verified 2026-07-04
/// (DESIGN.md §7-3): `sessionId` / `cwd` / `pid` / `status` / `waitingFor`
/// (`statusUpdatedAt` also exists but shiibar doesn't use it, §3.3 —
/// `claude agents` is always trusted outright, no time-based arbitration).
#[derive(Debug, Clone, PartialEq)]
pub struct ClaudeAgent {
    pub session_id: String,
    pub cwd: String,
    pub pid: u32,
    pub status: Status,
    pub waiting_for: Option<String>,
}

#[derive(Debug, serde::Deserialize)]
struct RawClaudeAgent {
    #[serde(rename = "sessionId")]
    session_id: String,
    cwd: String,
    pid: u32,
    status: String,
    #[serde(rename = "waitingFor", default)]
    waiting_for: Option<String>,
}

/// `claude agents`' 4-value status -> shiibar's 3-value status (§3.5):
/// `busy`/`shell` -> working, `waiting` -> waiting, `idle` -> idle. A status
/// string this build doesn't recognize (a future `claude agents` version)
/// maps to **working** (DESIGN.md §3.5): dropping the session from the live
/// list instead would let a complete-scan prune delete a live entry, while
/// `working` keeps it tracked and raises no unreviewed flag.
fn map_status(raw: &str) -> Status {
    match raw {
        "waiting" => Status::Waiting,
        "idle" => Status::Idle,
        // "busy" / "shell" / anything unrecognized (§3.5).
        _ => Status::Working,
    }
}

/// Parse `claude agents --json`'s raw stdout into `ClaudeAgent`s.
pub fn parse_claude_agents_json(raw: &str) -> Result<Vec<ClaudeAgent>, String> {
    let entries: Vec<RawClaudeAgent> = serde_json::from_str(raw).map_err(|e| e.to_string())?;
    Ok(entries
        .into_iter()
        .map(|e| ClaudeAgent {
            session_id: e.session_id,
            cwd: e.cwd,
            pid: e.pid,
            status: map_status(&e.status),
            waiting_for: e.waiting_for,
        })
        .collect())
}

/// Result of gathering: the live sessions to send in `{"cmd":"reconcile"}`,
/// whether every attempted terminal scan was complete enough to prune from
/// (§3.5), and whether any scan hit an Automation (TCC) denial. `complete`
/// is `false` for every failure mode (`claude` missing or erroring,
/// unparseable JSON, `ps` failing, or any terminal's scan failing or being
/// incomplete); the caller still sends whatever sessions were resolved, and
/// the daemon skips pruning. `permission_denied` does not stop the gather:
/// the caller sends the result first and then exits 3 (§4.4).
#[derive(Debug, Clone, PartialEq)]
pub struct GatherResult {
    pub complete: bool,
    pub sessions: Vec<ReconcileSession>,
    pub permission_denied: bool,
}

/// One terminal's reconcile scan, normalized so the gather treats every
/// terminal module's `<terminal>_targets` result the same way (§3.5):
/// `targets` maps a `claude agents` pid to that terminal's target,
/// `complete` is whether the scan can be trusted for pruning, and
/// `permission_denied` records an Automation (TCC) denial. A terminal that
/// is not running yields an empty, complete scan (its `<terminal>_targets`
/// script is is-running guarded and never launches it — §3.5/§7-7).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalScan {
    pub targets: HashMap<u32, String>,
    pub complete: bool,
    pub permission_denied: bool,
}

impl TerminalScan {
    /// Normalize a `<terminal>_targets` result given as `(targets,
    /// complete)`. A TCC denial makes the scan empty and incomplete and
    /// flags it; any other error (the modules degrade those to `Ok` today,
    /// so this is defensive) makes it empty and incomplete. A failed scan
    /// never aborts the gather (§3.5: one terminal's failure does not stop
    /// the other terminals' scans or sending their results).
    pub fn from_result(result: TerminalResult<(HashMap<u32, String>, bool)>) -> Self {
        match result {
            Ok((targets, complete)) => TerminalScan {
                targets,
                complete,
                permission_denied: false,
            },
            Err(TerminalError::PermissionDenied) => TerminalScan {
                targets: HashMap::new(),
                complete: false,
                permission_denied: true,
            },
            Err(_) => TerminalScan {
                targets: HashMap::new(),
                complete: false,
                permission_denied: false,
            },
        }
    }
}

/// A `PsRunner` that replays one `ps` result. The gather runs `ps` once and
/// hands this to every terminal scan, so the scans and the gather's own
/// "does this pid have a tty" decision all read the same pid -> tty
/// snapshot: a pid can't be matched by one scan yet judged differently by
/// another call taken a moment later.
struct ReplayPs {
    result: Result<PsOutput, String>,
}

impl PsRunner for ReplayPs {
    fn run(&self, _pids: &[u32]) -> std::io::Result<PsOutput> {
        self.result.clone().map_err(std::io::Error::other)
    }
}

/// Gather the live session list for a `reconcile` request (§3.5): run
/// `claude agents --json`, map statuses, run `ps` once for every pid, scan
/// each supported terminal (`iterm2_targets`, `apple_terminal_targets`,
/// and `ghostty_targets`), and assemble the sessions with
/// `assemble_sessions`.
///
/// Never fails: a TCC denial in one terminal's scan is recorded in
/// `permission_denied` and leaves the other terminals' results intact
/// (§3.5/§4.4: the caller sends them, then exits 3).
pub fn gather(
    claude_runner: &dyn ClaudeAgentsRunner,
    ps_runner: &dyn PsRunner,
    script_runner: &dyn AppleScriptRunner,
) -> GatherResult {
    let incomplete_and_empty = GatherResult {
        complete: false,
        sessions: Vec::new(),
        permission_denied: false,
    };
    let Ok(raw) = claude_runner.run() else {
        return incomplete_and_empty;
    };
    let Ok(agents) = parse_claude_agents_json(&raw) else {
        return incomplete_and_empty;
    };
    if agents.is_empty() {
        // Nothing to resolve: every scan would be empty and complete
        // without running anything.
        return GatherResult {
            complete: true,
            sessions: Vec::new(),
            permission_denied: false,
        };
    }

    let pids: Vec<u32> = agents.iter().map(|a| a.pid).collect();
    let ps = ReplayPs {
        result: ps_runner.run(&pids).map_err(|e| e.to_string()),
    };
    // A failed `ps` (an error or a nonzero exit) makes the round incomplete
    // here, whether or not a terminal module consulted it (a module whose
    // terminal is not running never runs `ps`), so the daemon won't prune
    // sessions whose tty couldn't be read; and no pid is judged to be in a
    // terminal from its output, so no `process:` session comes from it.
    let pid_tty = match &ps.result {
        Ok(output) if output.success => Some(parse_ps_tty_output(&output.stdout)),
        _ => None,
    };

    let scans = [
        TerminalScan::from_result(
            iterm2::iterm2_targets(&pids, &ps, script_runner).map(|r| (r.targets, r.complete)),
        ),
        TerminalScan::from_result(
            apple_terminal::apple_terminal_targets(&pids, &ps, script_runner)
                .map(|r| (r.targets, r.complete)),
        ),
        TerminalScan::from_result(
            ghostty::ghostty_targets(&pids, &ps, script_runner).map(|r| (r.targets, r.complete)),
        ),
    ];

    assemble_sessions(agents, pid_tty.as_ref(), &scans)
}

/// Pure assembly of the reconcile sessions from `claude agents`, the `ps`
/// pid -> tty map (None when the `ps` run failed), and the terminal scans
/// (§3.5 step 1):
///
/// - `complete` is false when `ps` failed, otherwise the AND of every
///   scan's `complete`; `permission_denied` is the OR of every scan's flag.
/// - A session whose pid a scan matched is sent with that scan's target.
///   A tty belongs to exactly one terminal, so at most one scan matches a
///   pid; the scans are consulted in order and the first match wins.
/// - A session no scan matched is sent as `process:<pid>` when `ps`
///   reported a controlling tty for its pid (never when `ps` failed). A pid
///   missing from the `ps`
///   output (the process exited after `claude agents` ran) or without a
///   tty (a session without a terminal, including a `claude -p` started by
///   another session's Bash tool — §7-9) is not sent.
/// - When the round is incomplete, those unmatched sessions carry
///   `update_only` (§4.2), so a session a failed scan missed is never
///   registered a second time under `process:` (§3.6 "merging by pid").
/// - Every session carries its `claude agents` pid (§4.2).
pub fn assemble_sessions(
    agents: Vec<ClaudeAgent>,
    pid_tty: Option<&HashMap<u32, String>>,
    scans: &[TerminalScan],
) -> GatherResult {
    let complete = pid_tty.is_some() && scans.iter().all(|s| s.complete);
    let permission_denied = scans.iter().any(|s| s.permission_denied);

    let sessions = agents
        .into_iter()
        .filter_map(|a| {
            let (target, update_only) =
                match scans.iter().find_map(|s| s.targets.get(&a.pid)) {
                    Some(target) => (target.clone(), false),
                    None => {
                        let tty = pid_tty?.get(&a.pid)?;
                        if !has_controlling_tty(tty) {
                            return None;
                        }
                        (process_target_for_pid(a.pid), !complete)
                    }
                };
            let waiting_for = (a.status == Status::Waiting).then_some(a.waiting_for).flatten();
            Some(ReconcileSession {
                target,
                session_id: a.session_id,
                cwd: a.cwd,
                status: a.status,
                waiting_for,
                pid: Some(a.pid),
                update_only,
            })
        })
        .collect();

    GatherResult {
        complete,
        sessions,
        permission_denied,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::terminal::{AppleScriptOutput, PsOutput};

    fn claude_agents_json() -> &'static str {
        r#"[
            {"sessionId":"s-1","cwd":"/proj/a","pid":111,"status":"busy","statusUpdatedAt":1},
            {"sessionId":"s-2","cwd":"/proj/b","pid":222,"status":"waiting","statusUpdatedAt":2,"waitingFor":"permission prompt"},
            {"sessionId":"s-3","cwd":"/proj/c","pid":333,"status":"idle","statusUpdatedAt":3}
        ]"#
    }

    #[test]
    fn parse_claude_agents_json_maps_statuses() {
        let agents = parse_claude_agents_json(claude_agents_json()).unwrap();
        assert_eq!(agents.len(), 3);
        assert_eq!(agents[0].status, Status::Working);
        assert_eq!(agents[1].status, Status::Waiting);
        assert_eq!(agents[1].waiting_for.as_deref(), Some("permission prompt"));
        assert_eq!(agents[2].status, Status::Idle);
    }

    #[test]
    fn parse_claude_agents_json_shell_status_maps_to_working() {
        let raw = r#"[{"sessionId":"s","cwd":"/c","pid":1,"status":"shell"}]"#;
        let agents = parse_claude_agents_json(raw).unwrap();
        assert_eq!(agents[0].status, Status::Working);
    }

    #[test]
    fn parse_claude_agents_json_maps_unrecognized_status_to_working() {
        // §3.5: an unmapped status must NOT drop the session (a complete-
        // scan prune would then delete a live entry); working keeps it
        // tracked without raising the unreviewed flag.
        let raw = r#"[{"sessionId":"s","cwd":"/c","pid":1,"status":"some_future_status"}]"#;
        let agents = parse_claude_agents_json(raw).unwrap();
        assert_eq!(agents.len(), 1);
        assert_eq!(agents[0].status, Status::Working);
    }

    #[test]
    fn parse_claude_agents_json_invalid_json_is_an_error() {
        assert!(parse_claude_agents_json("not json").is_err());
    }

    struct FakeClaude {
        output: Result<String, ()>,
    }

    impl ClaudeAgentsRunner for FakeClaude {
        fn run(&self) -> std::io::Result<String> {
            self.output
                .clone()
                .map_err(|_| std::io::Error::other("claude not found"))
        }
    }

    struct FakePs {
        stdout: String,
    }

    impl PsRunner for FakePs {
        fn run(&self, _pids: &[u32]) -> std::io::Result<PsOutput> {
            Ok(PsOutput {
                success: true,
                stdout: self.stdout.clone(),
            })
        }
    }

    /// Whether a script is one of the ghostty module's (they all address
    /// Ghostty by name).
    fn is_ghostty_script(script: &str) -> bool {
        script.contains(r#"application "Ghostty""#)
    }

    /// Whether a script is the iterm2 module's preliminary running query
    /// (sent before every iTerm2 scan).
    fn is_iterm2_running_query(script: &str) -> bool {
        script == iterm2::build_running_script()
    }

    /// Answers iTerm2's running query with "running", the iTerm2 and
    /// Terminal.app scans with the same `stdout`, and reports Ghostty as
    /// not running.
    struct FakeScript {
        stdout: String,
    }

    impl AppleScriptRunner for FakeScript {
        fn run(&self, script: &str) -> std::io::Result<AppleScriptOutput> {
            if is_iterm2_running_query(script) {
                return Ok(ok_output("RUNNING\n"));
            }
            if is_ghostty_script(script) {
                return Ok(ok_output("NOT_RUNNING\n"));
            }
            Ok(AppleScriptOutput {
                success: true,
                stdout: self.stdout.clone(),
                stderr: String::new(),
            })
        }
    }

    /// Answers each terminal's scripts separately: iTerm2's running query
    /// with "running", the iTerm2 enumeration by its SESSION marker, Ghostty's version query and tty query by the
    /// bundle ID and `tty of every terminal`, and everything else as
    /// Terminal.app's enumeration.
    struct MarkerScript {
        iterm2: AppleScriptOutput,
        apple_terminal: AppleScriptOutput,
        ghostty_version: AppleScriptOutput,
        ghostty_ttys: AppleScriptOutput,
    }

    impl MarkerScript {
        /// iTerm2 and Terminal.app answer as given; Ghostty isn't running.
        fn without_ghostty(iterm2: AppleScriptOutput, apple_terminal: AppleScriptOutput) -> Self {
            MarkerScript {
                iterm2,
                apple_terminal,
                ghostty_version: ok_output("NOT_RUNNING\n"),
                ghostty_ttys: ok_output("NOT_RUNNING\n"),
            }
        }
    }

    impl AppleScriptRunner for MarkerScript {
        fn run(&self, script: &str) -> std::io::Result<AppleScriptOutput> {
            Ok(if is_iterm2_running_query(script) {
                ok_output("RUNNING\n")
            } else if is_ghostty_script(script) {
                if script.contains("tty of every terminal") {
                    self.ghostty_ttys.clone()
                } else {
                    self.ghostty_version.clone()
                }
            } else if script.contains("SESSION") {
                self.iterm2.clone()
            } else {
                self.apple_terminal.clone()
            })
        }
    }

    fn ok_output(stdout: &str) -> AppleScriptOutput {
        AppleScriptOutput {
            success: true,
            stdout: stdout.to_string(),
            stderr: String::new(),
        }
    }

    fn tcc_denied_output() -> AppleScriptOutput {
        AppleScriptOutput {
            success: false,
            stdout: String::new(),
            stderr: "Not authorized to send Apple events to iTerm2. (-1743)".to_string(),
        }
    }

    fn by_target(result: &GatherResult) -> std::collections::HashMap<&str, &ReconcileSession> {
        result.sessions.iter().map(|s| (s.target.as_str(), s)).collect()
    }

    #[test]
    fn gather_resolves_pids_to_targets_and_skips_a_pid_missing_from_ps() {
        let claude = FakeClaude {
            output: Ok(claude_agents_json().to_string()),
        };
        let ps = FakePs {
            // 333 is absent: the process exited after `claude agents` ran.
            stdout: "111 ttys000\n222 ttys001\n".to_string(),
        };
        let script = FakeScript {
            stdout: "SESSION\t/dev/ttys000\tUUID-A\nSESSION\t/dev/ttys001\tUUID-B\nDONE\t0\n".to_string(),
        };

        let result = gather(&claude, &ps, &script);
        assert!(result.complete);
        assert!(!result.permission_denied);
        assert_eq!(result.sessions.len(), 2, "pid 333 (not in the ps output) must not be sent");
        let by_target = by_target(&result);
        assert_eq!(by_target["iterm2:UUID-A"].status, Status::Working);
        assert_eq!(by_target["iterm2:UUID-B"].status, Status::Waiting);
        assert_eq!(by_target["iterm2:UUID-B"].waiting_for.as_deref(), Some("permission prompt"));
    }

    #[test]
    fn gather_resolves_an_apple_terminal_session_and_merges_both_terminals() {
        // pid 111 is an iTerm2 session, pid 222 a Terminal.app tab: the
        // merged result carries both prefixed targets (§3.5/§4.3).
        let script = MarkerScript::without_ghostty(
            ok_output("SESSION\t/dev/ttys000\tUUID-A\nDONE\t0\n"),
            ok_output("TAB\t/dev/ttys006\nDONE\t0\n"),
        );
        let claude = FakeClaude {
            output: Ok(r#"[
                {"sessionId":"s-1","cwd":"/a","pid":111,"status":"busy"},
                {"sessionId":"s-2","cwd":"/b","pid":222,"status":"waiting","waitingFor":"input"}
            ]"#
            .to_string()),
        };
        let ps = FakePs {
            stdout: "111 ttys000\n222 ttys006\n".to_string(),
        };
        let result = gather(&claude, &ps, &script);
        assert!(result.complete);
        let by_target = by_target(&result);
        assert_eq!(by_target["iterm2:UUID-A"].status, Status::Working);
        assert_eq!(
            by_target["apple-terminal:/dev/ttys006"].status,
            Status::Waiting
        );
        assert_eq!(
            by_target["apple-terminal:/dev/ttys006"].waiting_for.as_deref(),
            Some("input")
        );
    }

    #[test]
    fn gather_attaches_the_claude_agents_pid_to_every_session() {
        // §3.5/§4.2: matched and unmatched sessions alike carry the pid
        // from the `claude agents` list.
        let claude = FakeClaude {
            output: Ok(r#"[
                {"sessionId":"s-1","cwd":"/a","pid":111,"status":"busy"},
                {"sessionId":"s-2","cwd":"/b","pid":222,"status":"idle"}
            ]"#
            .to_string()),
        };
        let ps = FakePs {
            stdout: "111 ttys000\n222 ttys009\n".to_string(),
        };
        let script = FakeScript {
            stdout: "SESSION\t/dev/ttys000\tUUID-A\nDONE\t0\n".to_string(),
        };
        let result = gather(&claude, &ps, &script);
        let by_target = by_target(&result);
        assert_eq!(by_target["iterm2:UUID-A"].pid, Some(111));
        assert_eq!(by_target["process:222"].pid, Some(222));
    }

    #[test]
    fn gather_sends_a_session_with_a_tty_that_matches_no_scan_as_a_process_target() {
        // §3.5: a session running in a terminal shiibar can't drive (it has
        // a tty, but no supported terminal's scan matches it) is tracked
        // as `process:<pid>`; in a complete round it is not update-only.
        let claude = FakeClaude {
            output: Ok(r#"[{"sessionId":"s-9","cwd":"/x","pid":48213,"status":"waiting","waitingFor":"input"}]"#.to_string()),
        };
        let ps = FakePs {
            stdout: "48213 ttys012\n".to_string(),
        };
        let script = FakeScript { stdout: "DONE\t0\n".to_string() };
        let result = gather(&claude, &ps, &script);
        assert!(result.complete);
        assert_eq!(
            result.sessions,
            vec![ReconcileSession {
                target: "process:48213".to_string(),
                session_id: "s-9".to_string(),
                cwd: "/x".to_string(),
                status: Status::Waiting,
                waiting_for: Some("input".to_string()),
                pid: Some(48213),
                update_only: false,
            }]
        );
    }

    #[test]
    fn gather_does_not_send_a_pid_without_a_tty() {
        // §3.5: a session without a terminal (`??` in ps), such as a
        // `claude -p` started from another session's Bash tool (§7-9), is
        // not tracked.
        let claude = FakeClaude {
            output: Ok(r#"[{"sessionId":"s","cwd":"/c","pid":777,"status":"busy"}]"#.to_string()),
        };
        let ps = FakePs {
            stdout: "  777 ??      \n".to_string(),
        };
        let script = FakeScript { stdout: "DONE\t0\n".to_string() };
        let result = gather(&claude, &ps, &script);
        assert!(result.complete);
        assert!(result.sessions.is_empty());
    }

    #[test]
    fn gather_marks_unmatched_sessions_update_only_when_a_scan_is_incomplete() {
        // §3.5: in an incomplete round, a session that matched no scan may
        // be one the failed scan missed, so it goes as update-only (target
        // still `process:<pid>`); a session a scan did match is not.
        let claude = FakeClaude {
            output: Ok(r#"[
                {"sessionId":"s-1","cwd":"/a","pid":111,"status":"busy"},
                {"sessionId":"s-2","cwd":"/b","pid":222,"status":"idle"}
            ]"#
            .to_string()),
        };
        let ps = FakePs {
            stdout: "111 ttys000\n222 ttys009\n".to_string(),
        };
        let script = FakeScript {
            stdout: "SESSION\t/dev/ttys000\tUUID-A\nDONE\t1\n".to_string(),
        };
        let result = gather(&claude, &ps, &script);
        assert!(!result.complete);
        let by_target = by_target(&result);
        assert!(!by_target["iterm2:UUID-A"].update_only);
        assert!(by_target["process:222"].update_only);
        assert_eq!(by_target["process:222"].pid, Some(222));
    }

    #[test]
    fn gather_is_incomplete_when_claude_agents_fails() {
        let claude = FakeClaude { output: Err(()) };
        let ps = FakePs { stdout: String::new() };
        let script = FakeScript { stdout: "DONE\t0\n".to_string() };
        let result = gather(&claude, &ps, &script);
        assert!(!result.complete);
        assert!(result.sessions.is_empty());
    }

    #[test]
    fn gather_is_incomplete_when_the_iterm2_scan_reports_failures() {
        let claude = FakeClaude {
            output: Ok(r#"[{"sessionId":"s","cwd":"/c","pid":111,"status":"busy"}]"#.to_string()),
        };
        let ps = FakePs {
            stdout: "111 ttys000\n".to_string(),
        };
        let script = FakeScript {
            stdout: "SESSION\t/dev/ttys000\tUUID-A\nDONE\t1\n".to_string(),
        };
        let result = gather(&claude, &ps, &script);
        assert!(!result.complete);
        assert_eq!(result.sessions.len(), 1, "still adds/updates from a partial scan");
    }

    #[test]
    fn gather_is_incomplete_and_sends_no_process_target_when_ps_fails() {
        // Without `ps` no tty is known, so no pid can be judged to be in a
        // terminal; the round must not prune what it couldn't check. iTerm2
        // and Ghostty are not running (their modules never run `ps`), so
        // the failure must be caught by the gather itself, both for an
        // error and for a nonzero exit with partial output.
        struct FailingPs {
            output: Option<&'static str>,
        }
        impl PsRunner for FailingPs {
            fn run(&self, _pids: &[u32]) -> std::io::Result<PsOutput> {
                match self.output {
                    Some(stdout) => Ok(PsOutput {
                        success: false,
                        stdout: stdout.to_string(),
                    }),
                    None => Err(std::io::Error::other("ps unavailable")),
                }
            }
        }
        /// iTerm2 and Ghostty not running; Terminal.app answers with
        /// `apple_terminal` (a tab list, or nothing when not running).
        struct OnlyAppleTerminal {
            apple_terminal: &'static str,
        }
        impl AppleScriptRunner for OnlyAppleTerminal {
            fn run(&self, script: &str) -> std::io::Result<AppleScriptOutput> {
                Ok(if is_iterm2_running_query(script) || is_ghostty_script(script) {
                    ok_output("NOT_RUNNING\n")
                } else {
                    assert!(!script.contains("SESSION"), "no iTerm2 enumeration while it is not running");
                    ok_output(self.apple_terminal)
                })
            }
        }
        let claude = FakeClaude {
            output: Ok(r#"[{"sessionId":"s","cwd":"/c","pid":111,"status":"busy"}]"#.to_string()),
        };
        for apple_terminal in ["TAB\t/dev/ttys009\nDONE\t0\n", "DONE\t0\n"] {
            for ps in [FailingPs { output: None }, FailingPs { output: Some("111 ttys000\n") }] {
                let result = gather(&claude, &ps, &OnlyAppleTerminal { apple_terminal });
                let name = format!("Terminal.app {apple_terminal:?}, ps output {:?}", ps.output);
                assert!(!result.complete, "{name}");
                assert!(result.sessions.is_empty(), "{name}");
                assert!(!result.permission_denied, "{name}");
            }
        }
    }

    #[test]
    fn gather_runs_ps_once_and_shares_the_result_with_every_scan() {
        struct CountingPs {
            calls: std::cell::Cell<u32>,
        }
        impl PsRunner for CountingPs {
            fn run(&self, _pids: &[u32]) -> std::io::Result<PsOutput> {
                self.calls.set(self.calls.get() + 1);
                Ok(PsOutput {
                    success: true,
                    stdout: "111 ttys000\n".to_string(),
                })
            }
        }
        let claude = FakeClaude {
            output: Ok(r#"[{"sessionId":"s","cwd":"/c","pid":111,"status":"busy"}]"#.to_string()),
        };
        let ps = CountingPs {
            calls: std::cell::Cell::new(0),
        };
        let script = FakeScript { stdout: "DONE\t0\n".to_string() };
        let result = gather(&claude, &ps, &script);
        assert_eq!(ps.calls.get(), 1);
        assert_eq!(result.sessions[0].target, "process:111");
    }

    #[test]
    fn gather_keeps_other_terminals_results_when_one_scan_is_tcc_denied() {
        // §3.5/§4.4: iTerm2's Automation permission is denied, but the
        // Terminal.app scan and the `process:` sessions are still sent; the
        // round is incomplete (so unmatched sessions are update-only) and
        // the denial is reported for exit 3.
        let script = MarkerScript::without_ghostty(
            tcc_denied_output(),
            ok_output("TAB\t/dev/ttys006\nDONE\t0\n"),
        );
        let claude = FakeClaude {
            output: Ok(r#"[
                {"sessionId":"s-1","cwd":"/a","pid":111,"status":"busy"},
                {"sessionId":"s-2","cwd":"/b","pid":222,"status":"idle"}
            ]"#
            .to_string()),
        };
        let ps = FakePs {
            stdout: "111 ttys000\n222 ttys006\n".to_string(),
        };
        let result = gather(&claude, &ps, &script);
        assert!(result.permission_denied);
        assert!(!result.complete);
        let by_target = by_target(&result);
        assert_eq!(result.sessions.len(), 2);
        assert!(!by_target["apple-terminal:/dev/ttys006"].update_only);
        assert!(by_target["process:111"].update_only);
    }

    #[test]
    fn gather_keeps_other_terminals_results_when_the_apple_terminal_scan_is_tcc_denied() {
        let script = MarkerScript::without_ghostty(
            ok_output("SESSION\t/dev/ttys000\tUUID-A\nDONE\t0\n"),
            tcc_denied_output(),
        );
        let claude = FakeClaude {
            output: Ok(r#"[{"sessionId":"s-1","cwd":"/a","pid":111,"status":"busy"}]"#.to_string()),
        };
        let ps = FakePs {
            stdout: "111 ttys000\n".to_string(),
        };
        let result = gather(&claude, &ps, &script);
        assert!(result.permission_denied);
        assert!(!result.complete);
        assert_eq!(result.sessions.len(), 1);
        assert_eq!(result.sessions[0].target, "iterm2:UUID-A");
    }

    #[test]
    fn gather_only_sends_is_running_guarded_scan_scripts() {
        // §3.5/§7-7: a terminal that isn't running must not be launched by
        // the scan, so every script the gather sends checks `is running`
        // before addressing the application; a not-running answer is an
        // empty, complete scan. iTerm2 answers its running query as
        // running and Ghostty as a supported, running version, so both
        // terminals' preliminary queries and their scans are sent and
        // checked too.
        struct RecordingScript {
            scripts: std::cell::RefCell<Vec<String>>,
        }
        impl AppleScriptRunner for RecordingScript {
            fn run(&self, script: &str) -> std::io::Result<AppleScriptOutput> {
                self.scripts.borrow_mut().push(script.to_string());
                Ok(if is_iterm2_running_query(script) {
                    ok_output("RUNNING\n")
                } else if !is_ghostty_script(script) {
                    ok_output("DONE\t0\n")
                } else if script.contains("tty of every terminal") {
                    ok_output("TTYS\n")
                } else {
                    ok_output("VERSION:1.4.0\n")
                })
            }
        }
        let claude = FakeClaude {
            output: Ok(r#"[{"sessionId":"s","cwd":"/c","pid":111,"status":"busy"}]"#.to_string()),
        };
        let ps = FakePs {
            stdout: "111 ttys000\n".to_string(),
        };
        let script = RecordingScript {
            scripts: std::cell::RefCell::new(Vec::new()),
        };
        let result = gather(&claude, &ps, &script);
        assert!(result.complete);
        let scripts = script.scripts.borrow();
        assert_eq!(
            scripts.len(),
            5,
            "iTerm2 running query, iTerm2 sessions, Terminal.app, Ghostty version, Ghostty ttys"
        );
        assert_eq!(scripts[0], iterm2::build_running_script());
        assert_eq!(scripts[1], iterm2::build_iterm2_targets_script());
        assert!(scripts.iter().any(|s| s.contains("tty of every terminal")));
        for s in scripts.iter() {
            assert!(
                s.trim_start().starts_with("if application") && s.contains("is running then"),
                "scan script must be is-running guarded: {s}"
            );
        }
    }

    #[test]
    fn gather_resolves_a_ghostty_session_alongside_the_other_terminals() {
        // §3.5/§4.3: pid 333 runs in a Ghostty terminal, so the Ghostty
        // scan's target is sent; the round is complete when all three
        // scans are.
        let script = MarkerScript {
            iterm2: ok_output("SESSION\t/dev/ttys000\tUUID-A\nDONE\t0\n"),
            apple_terminal: ok_output("TAB\t/dev/ttys006\nDONE\t0\n"),
            ghostty_version: ok_output("VERSION:1.4.0\n"),
            ghostty_ttys: ok_output("TTYS\n/dev/ttys004\n/dev/ttys005\n"),
        };
        let claude = FakeClaude {
            output: Ok(r#"[
                {"sessionId":"s-1","cwd":"/a","pid":111,"status":"busy"},
                {"sessionId":"s-2","cwd":"/b","pid":222,"status":"idle"},
                {"sessionId":"s-3","cwd":"/c","pid":333,"status":"waiting","waitingFor":"input"}
            ]"#
            .to_string()),
        };
        let ps = FakePs {
            stdout: "111 ttys000\n222 ttys006\n333 ttys005\n".to_string(),
        };
        let result = gather(&claude, &ps, &script);
        assert!(result.complete);
        assert!(!result.permission_denied);
        let by_target = by_target(&result);
        assert_eq!(result.sessions.len(), 3);
        assert!(by_target.contains_key("iterm2:UUID-A"));
        assert!(by_target.contains_key("apple-terminal:/dev/ttys006"));
        let ghostty = by_target["ghostty:/dev/ttys005"];
        assert_eq!(ghostty.pid, Some(333));
        assert_eq!(ghostty.status, Status::Waiting);
        assert!(!ghostty.update_only);
    }

    #[test]
    fn gather_does_not_scan_ghostty_beyond_the_version_query_when_it_is_not_running() {
        // §3.5: an un-launched terminal is not scanned; only the guarded
        // version query is sent, and the round stays complete.
        struct RecordingScript {
            scripts: std::cell::RefCell<Vec<String>>,
        }
        impl AppleScriptRunner for RecordingScript {
            fn run(&self, script: &str) -> std::io::Result<AppleScriptOutput> {
                self.scripts.borrow_mut().push(script.to_string());
                Ok(if is_iterm2_running_query(script) {
                    ok_output("RUNNING\n")
                } else if is_ghostty_script(script) {
                    ok_output("NOT_RUNNING\n")
                } else {
                    ok_output("DONE\t0\n")
                })
            }
        }
        let claude = FakeClaude {
            output: Ok(r#"[{"sessionId":"s","cwd":"/c","pid":111,"status":"busy"}]"#.to_string()),
        };
        let ps = FakePs {
            stdout: "111 ttys005\n".to_string(),
        };
        let script = RecordingScript {
            scripts: std::cell::RefCell::new(Vec::new()),
        };
        let result = gather(&claude, &ps, &script);
        assert!(result.complete);
        assert_eq!(result.sessions[0].target, "process:111");
        let scripts = script.scripts.borrow();
        assert!(!scripts.iter().any(|s| s.contains("tty of every terminal")));
    }

    #[test]
    fn gather_does_not_send_the_iterm2_scan_when_iterm2_is_not_running() {
        // The iTerm2 scan uses iTerm2's terminology and does not compile
        // when iTerm2 is not installed; a not-running answer to the running
        // query is an empty, complete iTerm2 scan, so the round can prune.
        struct RecordingScript {
            scripts: std::cell::RefCell<Vec<String>>,
        }
        impl AppleScriptRunner for RecordingScript {
            fn run(&self, script: &str) -> std::io::Result<AppleScriptOutput> {
                self.scripts.borrow_mut().push(script.to_string());
                Ok(if is_iterm2_running_query(script) || is_ghostty_script(script) {
                    ok_output("NOT_RUNNING\n")
                } else {
                    ok_output("DONE\t0\n")
                })
            }
        }
        let claude = FakeClaude {
            output: Ok(r#"[{"sessionId":"s","cwd":"/c","pid":111,"status":"busy"}]"#.to_string()),
        };
        let ps = FakePs {
            stdout: "111 ttys000\n".to_string(),
        };
        let script = RecordingScript {
            scripts: std::cell::RefCell::new(Vec::new()),
        };
        let result = gather(&claude, &ps, &script);
        assert!(result.complete);
        assert_eq!(result.sessions[0].target, "process:111");
        let scripts = script.scripts.borrow();
        assert_eq!(scripts[0], iterm2::build_running_script());
        assert!(!scripts.iter().any(|s| *s == iterm2::build_iterm2_targets_script()));
    }

    #[test]
    fn gather_is_incomplete_when_the_ghostty_query_fails_with_invalid_index() {
        // §4.3/§7-8: a failed Ghostty query (here -1719) makes the round
        // incomplete, so the session it might have matched is update-only.
        let mut script = MarkerScript::without_ghostty(
            ok_output("DONE\t0\n"),
            ok_output("DONE\t0\n"),
        );
        script.ghostty_version = ok_output("VERSION:1.4.0\n");
        script.ghostty_ttys = AppleScriptOutput {
            success: false,
            stdout: String::new(),
            stderr: "execution error: Ghostty got an error: Invalid index. (-1719)".to_string(),
        };
        let claude = FakeClaude {
            output: Ok(r#"[{"sessionId":"s","cwd":"/c","pid":333,"status":"busy"}]"#.to_string()),
        };
        let ps = FakePs {
            stdout: "333 ttys005\n".to_string(),
        };
        let result = gather(&claude, &ps, &script);
        assert!(!result.complete);
        assert!(!result.permission_denied);
        assert_eq!(result.sessions[0].target, "process:333");
        assert!(result.sessions[0].update_only);
    }

    #[test]
    fn gather_keeps_other_terminals_results_when_the_ghostty_scan_is_tcc_denied() {
        let mut script = MarkerScript::without_ghostty(
            ok_output("SESSION\t/dev/ttys000\tUUID-A\nDONE\t0\n"),
            ok_output("DONE\t0\n"),
        );
        script.ghostty_version = AppleScriptOutput {
            success: false,
            stdout: String::new(),
            stderr: "Not authorized to send Apple events to Ghostty. (-1743)".to_string(),
        };
        let claude = FakeClaude {
            output: Ok(r#"[{"sessionId":"s-1","cwd":"/a","pid":111,"status":"busy"}]"#.to_string()),
        };
        let ps = FakePs {
            stdout: "111 ttys000\n".to_string(),
        };
        let result = gather(&claude, &ps, &script);
        assert!(result.permission_denied);
        assert!(!result.complete);
        assert_eq!(result.sessions.len(), 1);
        assert_eq!(result.sessions[0].target, "iterm2:UUID-A");
    }

    #[test]
    fn gather_with_no_agents_is_complete_and_runs_nothing() {
        struct PanicPs;
        impl PsRunner for PanicPs {
            fn run(&self, _pids: &[u32]) -> std::io::Result<PsOutput> {
                panic!("ps must not run without pids");
            }
        }
        struct PanicScript;
        impl AppleScriptRunner for PanicScript {
            fn run(&self, _script: &str) -> std::io::Result<AppleScriptOutput> {
                panic!("osascript must not run without pids");
            }
        }
        let claude = FakeClaude { output: Ok("[]".to_string()) };
        let result = gather(&claude, &PanicPs, &PanicScript);
        assert!(result.complete);
        assert!(result.sessions.is_empty());
    }

    // ---- assemble_sessions: three scans (iTerm2, Terminal.app, Ghostty) ----

    fn agent(pid: u32) -> ClaudeAgent {
        ClaudeAgent {
            session_id: format!("s-{pid}"),
            cwd: "/c".to_string(),
            pid,
            status: Status::Idle,
            waiting_for: None,
        }
    }

    fn scan(targets: &[(u32, &str)], complete: bool) -> TerminalScan {
        TerminalScan {
            targets: targets.iter().map(|(p, t)| (*p, t.to_string())).collect(),
            complete,
            permission_denied: false,
        }
    }

    fn ttys(pairs: &[(u32, &str)]) -> HashMap<u32, String> {
        pairs.iter().map(|(p, t)| (*p, t.to_string())).collect()
    }

    #[test]
    fn assemble_uses_the_third_scan_target_for_a_ghostty_session() {
        let result = assemble_sessions(
            vec![agent(1), agent(2), agent(3)],
            Some(&ttys(&[(1, "ttys001"), (2, "ttys002"), (3, "ttys005")])),
            &[
                scan(&[(1, "iterm2:UUID-A")], true),
                scan(&[(2, "apple-terminal:/dev/ttys002")], true),
                scan(&[(3, "ghostty:/dev/ttys005")], true),
            ],
        );
        assert!(result.complete);
        let targets: Vec<_> = result.sessions.iter().map(|s| s.target.as_str()).collect();
        assert_eq!(
            targets,
            vec!["iterm2:UUID-A", "apple-terminal:/dev/ttys002", "ghostty:/dev/ttys005"]
        );
        assert!(result.sessions.iter().all(|s| !s.update_only));
    }

    #[test]
    fn assemble_complete_is_the_and_of_all_three_scans() {
        for incomplete_index in 0..3 {
            let mut scans = [scan(&[], true), scan(&[], true), scan(&[], true)];
            scans[incomplete_index].complete = false;
            let result = assemble_sessions(
                vec![agent(9)],
                Some(&ttys(&[(9, "ttys009")])),
                &scans,
            );
            assert!(!result.complete, "scan {incomplete_index} incomplete");
            assert!(result.sessions[0].update_only);
            assert_eq!(result.sessions[0].target, "process:9");
        }
        let result = assemble_sessions(
            vec![agent(9)],
            Some(&ttys(&[(9, "ttys009")])),
            &[scan(&[], true), scan(&[], true), scan(&[], true)],
        );
        assert!(result.complete);
        assert!(!result.sessions[0].update_only);
    }

    #[test]
    fn assemble_reports_a_permission_denial_from_any_scan() {
        let denied = TerminalScan::from_result(Err(TerminalError::PermissionDenied));
        assert!(!denied.complete);
        assert!(denied.targets.is_empty());
        let result = assemble_sessions(
            vec![agent(1)],
            Some(&ttys(&[(1, "ttys001")])),
            &[scan(&[(1, "iterm2:UUID-A")], true), scan(&[], true), denied],
        );
        assert!(result.permission_denied);
        assert!(!result.complete);
        assert_eq!(result.sessions[0].target, "iterm2:UUID-A");
    }

    #[test]
    fn assemble_is_incomplete_and_sends_no_process_target_when_ps_failed_even_if_every_scan_is_complete() {
        // §3.5: the failed `ps` alone makes the round incomplete, whatever
        // the terminal modules reported; a session a scan matched is still
        // sent with that scan's target.
        let result = assemble_sessions(
            vec![agent(1), agent(9)],
            None,
            &[scan(&[(1, "iterm2:UUID-A")], true), scan(&[], true), scan(&[], true)],
        );
        assert!(!result.complete);
        let targets: Vec<_> = result.sessions.iter().map(|s| s.target.as_str()).collect();
        assert_eq!(targets, vec!["iterm2:UUID-A"]);
    }
}
