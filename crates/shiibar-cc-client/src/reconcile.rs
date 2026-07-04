//! `claude agents --json` gathering for `shiibar-cc reconcile` (DESIGN.md
//! §3.5). This is the "gather" half: parse `claude agents --json`, map its
//! status vocabulary to shiibar's, and use `iterm::iterm_targets` to turn
//! each entry's pid into a shiibar target. The result is what `shiibar-cc`
//! sends as `{"cmd":"reconcile",...}` (§4.2); daemon-side application
//! (add/update/prune) lives in shiibar-ccd, not here.

use crate::iterm::{self, AppleScriptRunner, PsRunner};
use shiibar_cc_proto::{ReconcileSession, Status};
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
/// and whether the underlying scans were complete enough to prune from
/// (§3.5). `false` covers every failure mode uniformly (`claude` missing or
/// erroring, unparseable JSON, or `iterm_targets`'s own scan being
/// incomplete) — the caller always still sends whatever sessions *were*
/// resolved, just with `complete:false` so the daemon skips pruning.
#[derive(Debug, Clone, PartialEq)]
pub struct GatherResult {
    pub complete: bool,
    pub sessions: Vec<ReconcileSession>,
}

/// Gather the live session list for a `reconcile` request (§3.5): run
/// `claude agents --json`, map statuses, and resolve each pid to a shiibar
/// target via `iterm::iterm_targets`. A `claude agents` entry whose pid
/// doesn't resolve to an iTerm2 session is skipped (§3.5 step 1: "no iTerm2
/// match -> skip", §8.11).
///
/// `Err(PermissionDenied)` is the one non-degradable failure: osascript's
/// TCC (Automation) denial, propagated from `iterm_targets` so the caller
/// can exit 3 (§4.4) instead of silently sending useless `complete:false`
/// reconciles forever.
pub fn gather(
    claude_runner: &dyn ClaudeAgentsRunner,
    ps_runner: &dyn PsRunner,
    script_runner: &dyn AppleScriptRunner,
) -> Result<GatherResult, iterm::ItermError> {
    let raw = match claude_runner.run() {
        Ok(s) => s,
        Err(_) => {
            return Ok(GatherResult {
                complete: false,
                sessions: Vec::new(),
            });
        }
    };
    let agents = match parse_claude_agents_json(&raw) {
        Ok(v) => v,
        Err(_) => {
            return Ok(GatherResult {
                complete: false,
                sessions: Vec::new(),
            });
        }
    };

    let pids: Vec<u32> = agents.iter().map(|a| a.pid).collect();
    let resolved = iterm::iterm_targets(&pids, ps_runner, script_runner)?;

    let sessions = agents
        .into_iter()
        .filter_map(|a| {
            let target = resolved.targets.get(&a.pid)?.clone();
            let waiting_for = (a.status == Status::Waiting).then_some(a.waiting_for).flatten();
            Some(ReconcileSession {
                target,
                session_id: a.session_id,
                cwd: a.cwd,
                status: a.status,
                waiting_for,
            })
        })
        .collect();

    Ok(GatherResult {
        complete: resolved.complete,
        sessions,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::iterm::{AppleScriptOutput, PsOutput};

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

    struct FakeScript {
        stdout: String,
    }

    impl AppleScriptRunner for FakeScript {
        fn run(&self, _script: &str) -> std::io::Result<AppleScriptOutput> {
            Ok(AppleScriptOutput {
                success: true,
                stdout: self.stdout.clone(),
                stderr: String::new(),
            })
        }
    }

    #[test]
    fn gather_resolves_pids_to_targets_and_skips_sessions_outside_iterm2() {
        let claude = FakeClaude {
            output: Ok(claude_agents_json().to_string()),
        };
        let ps = FakePs {
            stdout: "111 ttys000\n222 ttys001\n".to_string(), // 333 has no tty (not in iTerm2)
        };
        let script = FakeScript {
            stdout: "SESSION\t/dev/ttys000\tUUID-A\nSESSION\t/dev/ttys001\tUUID-B\nDONE\t0\n".to_string(),
        };

        let result = gather(&claude, &ps, &script).unwrap();
        assert!(result.complete);
        assert_eq!(result.sessions.len(), 2, "pid 333 (no iTerm2 match) must be skipped");
        let by_target: std::collections::HashMap<_, _> =
            result.sessions.iter().map(|s| (s.target.as_str(), s)).collect();
        assert_eq!(by_target["UUID-A"].status, Status::Working);
        assert_eq!(by_target["UUID-B"].status, Status::Waiting);
        assert_eq!(by_target["UUID-B"].waiting_for.as_deref(), Some("permission prompt"));
    }

    #[test]
    fn gather_is_incomplete_when_claude_agents_fails() {
        let claude = FakeClaude { output: Err(()) };
        let ps = FakePs { stdout: String::new() };
        let script = FakeScript { stdout: "DONE\t0\n".to_string() };
        let result = gather(&claude, &ps, &script).unwrap();
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
        let result = gather(&claude, &ps, &script).unwrap();
        assert!(!result.complete);
        assert_eq!(result.sessions.len(), 1, "still adds/updates from a partial scan");
    }

    #[test]
    fn gather_propagates_tcc_denial_as_an_error() {
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
        let claude = FakeClaude {
            output: Ok(r#"[{"sessionId":"s","cwd":"/c","pid":111,"status":"busy"}]"#.to_string()),
        };
        let ps = FakePs {
            stdout: "111 ttys000\n".to_string(),
        };
        let result = gather(&claude, &ps, &TccScript);
        assert!(matches!(result, Err(crate::iterm::ItermError::PermissionDenied)));
    }
}
