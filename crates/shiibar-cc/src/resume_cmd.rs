//! `shiibar-cc resume` (DESIGN.md §4.4): pick a past session from
//! `sessions.jsonl` history and reopen it with `claude --resume
//! <session_id>` in a new iTerm2 tab (`open_tab`, §4.3).
//!
//! Selection UI is split the same way `iterm.rs` splits AppleScript
//! generation from `osascript` invocation (task brief): "build candidate
//! lines" and "interpret a selection result" are pure functions
//! (`build_candidates`, `format_candidate_line`, `session_id_from_selected_line`,
//! `parse_numbered_selection`), and only the actual fzf-or-prompt process
//! invocation is behind the injectable `SelectionRunner` trait — so tests
//! never depend on whether `fzf` happens to be installed.

use crate::exitcode;
use crate::list_cmd::format_elapsed;
use shiibar_cc_client::iterm::{AppleScriptRunner, ItermError, open_tab};
use shiibar_cc_client::label::format_cwd_label;
use shiibar_cc_proto::{Agent, ListResponse, Request, SessionRecord, SessionsResponse, Status};
use std::collections::HashSet;
use std::ffi::OsStr;
use std::io::{BufRead, Write};
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

// ---------------------------------------------------------------------
// Pure: candidate selection (exclude running sessions, DESIGN.md §4.4)
// ---------------------------------------------------------------------

/// A past session that is a resume candidate: present in `sessions.jsonl`
/// history and NOT currently running (§4.4: "running sessions are excluded
/// from candidates, to prevent double-launching a `claude --resume`").
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Candidate {
    pub session_id: String,
    pub cwd: String,
    pub last_status: Status,
    pub last_seen: i64,
}

/// Exclude history entries whose `session_id` is currently running (i.e.
/// present in a `list` response). `sessions` is expected in `last_seen`
/// descending order (the `sessions` response's own order, §4.2) and that
/// order is preserved.
pub fn exclude_running(sessions: Vec<SessionRecord>, running_agents: &[Agent]) -> Vec<Candidate> {
    let running: HashSet<&str> = running_agents
        .iter()
        .map(|a| a.session_id.as_str())
        .collect();
    sessions
        .into_iter()
        .filter(|s| !running.contains(s.session_id.as_str()))
        .map(|s| Candidate {
            session_id: s.session_id,
            cwd: s.cwd,
            last_status: s.last_status,
            last_seen: s.last_seen,
        })
        .collect()
}

// ---------------------------------------------------------------------
// Pure: candidate line formatting / selection-result interpretation
// ---------------------------------------------------------------------

fn status_label(status: Status) -> &'static str {
    match status {
        Status::Idle => "idle",
        Status::Working => "working",
        Status::Waiting => "waiting",
        Status::Unknown => "unknown",
    }
}

/// One human-readable candidate line: status / shortened cwd label /
/// elapsed time since last seen / session_id (DESIGN.md §4.4 task brief:
/// "human-distinguishable, includes cwd's shortened label, last_status,
/// elapsed time, session_id"). The session_id is always the last
/// whitespace-delimited field, which is what makes a selected line's
/// session_id recoverable (`session_id_from_selected_line`) without
/// re-deriving it from the candidate list.
fn format_candidate_line(candidate: &Candidate, now: i64) -> String {
    format!(
        "{:<8} {:<24} {:>4}  {}",
        status_label(candidate.last_status),
        format_cwd_label(&candidate.cwd),
        format_elapsed(now - candidate.last_seen),
        candidate.session_id,
    )
}

/// Build one display line per candidate, in the same order as `candidates`.
pub fn build_candidate_lines(candidates: &[Candidate], now: i64) -> Vec<String> {
    candidates
        .iter()
        .map(|c| format_candidate_line(c, now))
        .collect()
}

/// Recover the `session_id` from a candidate line handed back by fzf
/// (`session_id` is always the trailing field, §4.4 task brief: "a
/// selection result must uniquely recover its session_id").
pub fn session_id_from_selected_line(line: &str) -> Option<String> {
    line.split_whitespace().last().map(str::to_string)
}

/// Parse a 1-indexed numbered-prompt answer into a 0-indexed line number.
/// Anything that isn't a valid in-range integer is treated the same as an
/// abort (DESIGN.md §4.4: aborted selection is exit 2, not an error) —
/// callers turn `None` into that outcome.
pub fn parse_numbered_selection(input: &str, len: usize) -> Option<usize> {
    let n: usize = input.trim().parse().ok()?;
    if n >= 1 && n <= len { Some(n - 1) } else { None }
}

// ---------------------------------------------------------------------
// Impure: fzf-or-numbered-prompt selection UI
// ---------------------------------------------------------------------

/// Presents `lines` for interactive selection and returns the chosen line
/// verbatim, or `None` if the selection was aborted (fzf Esc/Ctrl-C, or EOF
/// at the numbered prompt) — DESIGN.md §4.4 treats both as "exit 2, no
/// selection", not an error. Injected so `run_resume` is testable without
/// either `fzf` or a real terminal (task brief: "separate only the process
/// invocation part").
pub trait SelectionRunner {
    fn select(&self, lines: &[String]) -> std::io::Result<Option<String>>;
}

/// Real fzf-backed runner: candidate lines are piped to fzf's stdin (fzf
/// reads keystrokes from `/dev/tty` directly, not stdin — the standard `cmd
/// | fzf` pattern), and the selected line (if any) comes back on stdout.
pub struct FzfRunner;

impl SelectionRunner for FzfRunner {
    fn select(&self, lines: &[String]) -> std::io::Result<Option<String>> {
        let mut child = Command::new("fzf")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()?;
        {
            let mut stdin = child.stdin.take().expect("stdin was requested as piped");
            let joined = lines.join("\n");
            stdin.write_all(joined.as_bytes())?;
            if !joined.is_empty() {
                stdin.write_all(b"\n")?;
            }
        }
        let output = child.wait_with_output()?;
        let selected = String::from_utf8_lossy(&output.stdout).trim().to_string();
        Ok((!selected.is_empty()).then_some(selected))
    }
}

/// Real numbered-prompt runner (used when `fzf` isn't on `PATH`, §4.4):
/// prints the candidates to stderr (stdout is reserved for `resume`'s own
/// output, though there isn't any on success), then reads one line from
/// stdin. An unparseable/out-of-range answer or immediate EOF is an abort.
pub struct NumberedPromptRunner;

impl SelectionRunner for NumberedPromptRunner {
    fn select(&self, lines: &[String]) -> std::io::Result<Option<String>> {
        for (i, line) in lines.iter().enumerate() {
            eprintln!("{:3}) {line}", i + 1);
        }
        eprint!("select a session [1-{}]: ", lines.len());
        std::io::stderr().flush()?;

        let mut input = String::new();
        let n = std::io::stdin().lock().read_line(&mut input)?;
        if n == 0 {
            return Ok(None); // EOF: abort (§4.4)
        }
        Ok(parse_numbered_selection(&input, lines.len()).map(|idx| lines[idx].clone()))
    }
}

/// Whether `fzf` is on `PATH` (DESIGN.md §4.4: "fzf if on PATH, else a
/// numbered prompt"). Mirrors `doctor_cmd`'s `shiibar_cc_on_path` pattern.
pub fn fzf_on_path(path_env: Option<&OsStr>) -> bool {
    let Some(path_env) = path_env else {
        return false;
    };
    std::env::split_paths(path_env)
        .map(|dir| dir.join("fzf"))
        .any(|p| p.is_file())
}

// ---------------------------------------------------------------------
// run_resume
// ---------------------------------------------------------------------

fn now_epoch_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// `resume` (DESIGN.md §4.4): fetch history (`sessions`) + running agents
/// (`list`), exclude running sessions from the candidates, let the caller
/// pick one via `selection_runner`, and `open_tab` a `claude --resume
/// <session_id>` in its `cwd` (falling back to `home_dir` with a warning if
/// that `cwd` no longer exists on disk).
///
/// Exit codes (§4.4 common rule): 0 success / 1 connection or internal
/// error / **2 no candidates (empty history or all running) or aborted
/// selection** (reason on stderr) / 3 osascript TCC denial.
pub fn run_resume(
    socket_path: &Path,
    home_dir: &Path,
    selection_runner: &dyn SelectionRunner,
    script_runner: &dyn AppleScriptRunner,
) -> (i32, Option<String>) {
    let sessions = match shiibar_cc_client::connection::request::<SessionsResponse>(
        socket_path,
        &Request::Sessions,
    ) {
        Ok(resp) => resp.sessions,
        Err(e) => return (exitcode::ERROR, Some(format!("shiibar-cc resume: {e}"))),
    };
    let agents = match shiibar_cc_client::connection::request::<ListResponse>(
        socket_path,
        &Request::List,
    ) {
        Ok(resp) => resp.agents,
        Err(e) => return (exitcode::ERROR, Some(format!("shiibar-cc resume: {e}"))),
    };

    let candidates = exclude_running(sessions, &agents);
    if candidates.is_empty() {
        return (
            exitcode::NOT_FOUND,
            Some(
                "shiibar-cc resume: no resumable sessions (history is empty, or every \
                 known session is currently running)"
                    .to_string(),
            ),
        );
    }

    let lines = build_candidate_lines(&candidates, now_epoch_secs());

    let selected_line = match selection_runner.select(&lines) {
        Ok(Some(line)) => line,
        Ok(None) => {
            return (
                exitcode::NOT_FOUND,
                Some("shiibar-cc resume: selection aborted".to_string()),
            );
        }
        Err(e) => {
            return (
                exitcode::ERROR,
                Some(format!("shiibar-cc resume: selection UI failed: {e}")),
            );
        }
    };

    let Some(session_id) = session_id_from_selected_line(&selected_line) else {
        return (
            exitcode::ERROR,
            Some("shiibar-cc resume: could not parse the selected line".to_string()),
        );
    };

    let Some(candidate) = candidates.iter().find(|c| c.session_id == session_id) else {
        return (
            exitcode::ERROR,
            Some("shiibar-cc resume: selected line did not match a candidate".to_string()),
        );
    };

    let cwd = if Path::new(&candidate.cwd).is_dir() {
        candidate.cwd.clone()
    } else {
        eprintln!(
            "shiibar-cc resume: warning: {} no longer exists; opening $HOME instead",
            candidate.cwd
        );
        home_dir.to_string_lossy().into_owned()
    };

    let cmd = format!("claude --resume {}", candidate.session_id);
    match open_tab(&cwd, &cmd, script_runner) {
        Ok(()) => (exitcode::OK, None),
        Err(ItermError::PermissionDenied) => (
            exitcode::TCC_DENIED,
            Some(
                "shiibar-cc resume: osascript automation permission for iTerm2 is denied"
                    .to_string(),
            ),
        ),
        Err(e) => (exitcode::ERROR, Some(format!("shiibar-cc resume: {e}"))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use shiibar_cc_client::iterm::AppleScriptOutput;
    use std::io::BufReader;
    use std::os::unix::net::UnixListener;
    use std::sync::Mutex;

    fn session(session_id: &str, cwd: &str, status: Status, last_seen: i64) -> SessionRecord {
        SessionRecord {
            session_id: session_id.to_string(),
            cwd: cwd.to_string(),
            last_status: status,
            last_seen,
        }
    }

    fn agent(session_id: &str) -> Agent {
        Agent {
            target: format!("target-{session_id}"),
            status: Status::Working,
            unreviewed: false,
            session_id: session_id.to_string(),
            cwd: "/proj".to_string(),
            task: None,
            message: None,
            since: 1,
            last_seen: 1,
        }
    }

    // ---- exclude_running ----

    #[test]
    fn exclude_running_filters_out_running_session_ids() {
        let sessions = vec![
            session("s-running", "/proj/a", Status::Idle, 10),
            session("s-done", "/proj/b", Status::Idle, 20),
        ];
        let running = vec![agent("s-running")];
        let candidates = exclude_running(sessions, &running);
        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].session_id, "s-done");
    }

    #[test]
    fn exclude_running_keeps_everything_when_nothing_is_running() {
        let sessions = vec![session("s-a", "/proj/a", Status::Idle, 10)];
        let candidates = exclude_running(sessions, &[]);
        assert_eq!(candidates.len(), 1);
    }

    #[test]
    fn exclude_running_can_result_in_zero_candidates() {
        let sessions = vec![session("s-a", "/proj/a", Status::Idle, 10)];
        let running = vec![agent("s-a")];
        let candidates = exclude_running(sessions, &running);
        assert!(candidates.is_empty());
    }

    // ---- candidate line formatting / interpretation ----

    #[test]
    fn candidate_line_contains_status_label_cwd_label_elapsed_and_session_id() {
        let c = Candidate {
            session_id: "sess-1234".to_string(),
            cwd: "/proj/a".to_string(),
            last_status: Status::Waiting,
            last_seen: 100,
        };
        let line = format_candidate_line(&c, 160);
        assert!(line.contains("waiting"));
        assert!(line.contains("proj/a"));
        assert!(line.contains("1m")); // 60s elapsed
        assert!(line.trim_end().ends_with("sess-1234"));
    }

    #[test]
    fn session_id_from_selected_line_extracts_the_trailing_field() {
        let line = format!("{:<8} {:<24} {:>4}  {}", "idle", "~/a/b", "3m", "sess-xyz");
        assert_eq!(
            session_id_from_selected_line(&line),
            Some("sess-xyz".to_string())
        );
    }

    #[test]
    fn build_candidate_lines_preserves_order_and_uniquely_round_trips() {
        let candidates = vec![
            Candidate {
                session_id: "s-1".to_string(),
                cwd: "/proj/a".to_string(),
                last_status: Status::Idle,
                last_seen: 10,
            },
            Candidate {
                session_id: "s-2".to_string(),
                cwd: "/proj/a".to_string(), // same cwd/status as s-1 on purpose
                last_status: Status::Idle,
                last_seen: 10,
            },
        ];
        let lines = build_candidate_lines(&candidates, 10);
        assert_eq!(lines.len(), 2);
        // Even with identical cwd/status/elapsed, the trailing session_id
        // keeps each line's selection uniquely recoverable.
        assert_eq!(
            session_id_from_selected_line(&lines[0]),
            Some("s-1".to_string())
        );
        assert_eq!(
            session_id_from_selected_line(&lines[1]),
            Some("s-2".to_string())
        );
    }

    // ---- parse_numbered_selection ----

    #[test]
    fn parse_numbered_selection_accepts_in_range_answers() {
        assert_eq!(parse_numbered_selection("1", 3), Some(0));
        assert_eq!(parse_numbered_selection("3\n", 3), Some(2));
    }

    #[test]
    fn parse_numbered_selection_rejects_out_of_range_and_garbage() {
        assert_eq!(parse_numbered_selection("0", 3), None);
        assert_eq!(parse_numbered_selection("4", 3), None);
        assert_eq!(parse_numbered_selection("abc", 3), None);
        assert_eq!(parse_numbered_selection("", 3), None);
    }

    // ---- fzf_on_path ----

    #[test]
    fn fzf_on_path_finds_an_executable_named_fzf() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("fzf"), "#!/bin/sh\n").unwrap();
        let path_env = std::env::join_paths([dir.path()]).unwrap();
        assert!(fzf_on_path(Some(&path_env)));
    }

    #[test]
    fn fzf_on_path_is_false_when_absent() {
        let dir = tempfile::tempdir().unwrap();
        let path_env = std::env::join_paths([dir.path()]).unwrap();
        assert!(!fzf_on_path(Some(&path_env)));
        assert!(!fzf_on_path(None));
    }

    // ---- run_resume: end-to-end against a fake daemon socket ----

    /// A minimal in-process fake daemon: answers `sessions` and `list`
    /// requests with canned responses over a real Unix socket, exactly
    /// like `shiibar-ccd` would for the two round trips `run_resume` makes.
    /// This keeps these tests independent of the compiled `shiibar-ccd`
    /// binary (unlike `crates/shiibar-cc/tests/`, this crate's own unit
    /// tests don't have it as a dev-dependency).
    struct FakeDaemon {
        sock_path: std::path::PathBuf,
        _dir: tempfile::TempDir,
    }

    impl FakeDaemon {
        fn start(sessions_json: &'static str, list_json: &'static str) -> Self {
            let dir = tempfile::tempdir().unwrap();
            let sock_path = dir.path().join("shiibar-ccd.sock");
            let listener = UnixListener::bind(&sock_path).unwrap();
            std::thread::spawn(move || {
                for stream in listener.incoming().take(2) {
                    let Ok(mut stream) = stream else { continue };
                    let mut reader = BufReader::new(&stream);
                    let mut line = String::new();
                    if reader.read_line(&mut line).unwrap_or(0) == 0 {
                        continue;
                    }
                    let resp = if line.contains("\"sessions\"") {
                        sessions_json
                    } else {
                        list_json
                    };
                    let _ = stream.write_all(resp.as_bytes());
                    let _ = stream.write_all(b"\n");
                }
            });
            Self {
                sock_path,
                _dir: dir,
            }
        }
    }

    struct FakeSelection {
        line: Mutex<Option<String>>,
    }

    impl SelectionRunner for FakeSelection {
        fn select(&self, _lines: &[String]) -> std::io::Result<Option<String>> {
            Ok(self.line.lock().unwrap().take())
        }
    }

    struct AbortedSelection;
    impl SelectionRunner for AbortedSelection {
        fn select(&self, _lines: &[String]) -> std::io::Result<Option<String>> {
            Ok(None)
        }
    }

    struct FakeScript {
        output: AppleScriptOutput,
    }
    impl AppleScriptRunner for FakeScript {
        fn run(&self, _script: &str) -> std::io::Result<AppleScriptOutput> {
            Ok(self.output.clone())
        }
    }

    #[test]
    fn run_resume_exits_2_when_history_is_empty() {
        let daemon = FakeDaemon::start(
            r#"{"ok":true,"sessions":[]}"#,
            r#"{"ok":true,"agents":[]}"#,
        );
        let home = tempfile::tempdir().unwrap();
        let selection = AbortedSelection; // must never be consulted
        let script = FakeScript {
            output: AppleScriptOutput {
                success: true,
                stdout: "OK\n".to_string(),
                stderr: String::new(),
            },
        };
        let (code, msg) = run_resume(&daemon.sock_path, home.path(), &selection, &script);
        assert_eq!(code, exitcode::NOT_FOUND);
        assert!(msg.unwrap().contains("no resumable sessions"));
    }

    #[test]
    fn run_resume_exits_2_when_every_session_is_running() {
        let daemon = FakeDaemon::start(
            r#"{"ok":true,"sessions":[{"session_id":"s-1","cwd":"/proj/a","last_status":"idle","last_seen":10}]}"#,
            r#"{"ok":true,"agents":[{"target":"t-1","status":"working","unreviewed":false,"session_id":"s-1","cwd":"/proj/a","since":1,"last_seen":1}]}"#,
        );
        let home = tempfile::tempdir().unwrap();
        let selection = AbortedSelection;
        let script = FakeScript {
            output: AppleScriptOutput {
                success: true,
                stdout: "OK\n".to_string(),
                stderr: String::new(),
            },
        };
        let (code, msg) = run_resume(&daemon.sock_path, home.path(), &selection, &script);
        assert_eq!(code, exitcode::NOT_FOUND);
        assert!(msg.unwrap().contains("no resumable sessions"));
    }

    #[test]
    fn run_resume_exits_2_when_selection_is_aborted() {
        let daemon = FakeDaemon::start(
            r#"{"ok":true,"sessions":[{"session_id":"s-1","cwd":"/proj/a","last_status":"idle","last_seen":10}]}"#,
            r#"{"ok":true,"agents":[]}"#,
        );
        let home = tempfile::tempdir().unwrap();
        let selection = AbortedSelection;
        let script = FakeScript {
            output: AppleScriptOutput {
                success: true,
                stdout: "OK\n".to_string(),
                stderr: String::new(),
            },
        };
        let (code, msg) = run_resume(&daemon.sock_path, home.path(), &selection, &script);
        assert_eq!(code, exitcode::NOT_FOUND);
        assert!(msg.unwrap().contains("aborted"));
    }

    #[test]
    fn run_resume_falls_back_to_home_when_cwd_is_missing() {
        let daemon = FakeDaemon::start(
            r#"{"ok":true,"sessions":[{"session_id":"s-1","cwd":"/no/such/dir/ever","last_status":"idle","last_seen":10}]}"#,
            r#"{"ok":true,"agents":[]}"#,
        );
        let home = tempfile::tempdir().unwrap();
        let selected_line = format!(
            "{:<8} {:<24} {:>4}  {}",
            "idle", "no/such", "1m", "s-1"
        );
        let selection = FakeSelection {
            line: Mutex::new(Some(selected_line)),
        };
        let script = FakeScript {
            output: AppleScriptOutput {
                success: true,
                stdout: "OK\n".to_string(),
                stderr: String::new(),
            },
        };
        let (code, msg) = run_resume(&daemon.sock_path, home.path(), &selection, &script);
        assert_eq!(code, exitcode::OK, "msg={msg:?}");
    }

    #[test]
    fn run_resume_uses_the_real_cwd_and_calls_open_tab_successfully() {
        let cwd_dir = tempfile::tempdir().unwrap();
        let cwd = cwd_dir.path().to_str().unwrap().to_string();
        let sessions_json = format!(
            r#"{{"ok":true,"sessions":[{{"session_id":"s-1","cwd":"{cwd}","last_status":"idle","last_seen":10}}]}}"#
        );
        let daemon = FakeDaemon::start(
            Box::leak(sessions_json.into_boxed_str()),
            r#"{"ok":true,"agents":[]}"#,
        );
        let home = tempfile::tempdir().unwrap();
        let selected_line = format!("{:<8} {:<24} {:>4}  {}", "idle", "x", "1m", "s-1");
        let selection = FakeSelection {
            line: Mutex::new(Some(selected_line)),
        };
        let script = FakeScript {
            output: AppleScriptOutput {
                success: true,
                stdout: "OK\n".to_string(),
                stderr: String::new(),
            },
        };
        let (code, msg) = run_resume(&daemon.sock_path, home.path(), &selection, &script);
        assert_eq!(code, exitcode::OK, "msg={msg:?}");
    }

    #[test]
    fn run_resume_maps_tcc_denial_from_open_tab_to_exit_3() {
        let cwd_dir = tempfile::tempdir().unwrap();
        let cwd = cwd_dir.path().to_str().unwrap().to_string();
        let sessions_json = format!(
            r#"{{"ok":true,"sessions":[{{"session_id":"s-1","cwd":"{cwd}","last_status":"idle","last_seen":10}}]}}"#
        );
        let daemon = FakeDaemon::start(
            Box::leak(sessions_json.into_boxed_str()),
            r#"{"ok":true,"agents":[]}"#,
        );
        let home = tempfile::tempdir().unwrap();
        let selected_line = format!("{:<8} {:<24} {:>4}  {}", "idle", "x", "1m", "s-1");
        let selection = FakeSelection {
            line: Mutex::new(Some(selected_line)),
        };
        let script = FakeScript {
            output: AppleScriptOutput {
                success: false,
                stdout: String::new(),
                stderr: "Not authorized to send Apple events to iTerm2. (-1743)".to_string(),
            },
        };
        let (code, msg) = run_resume(&daemon.sock_path, home.path(), &selection, &script);
        assert_eq!(code, exitcode::TCC_DENIED);
        assert!(msg.unwrap().contains("automation permission"));
    }

    #[test]
    fn run_resume_exits_1_when_the_daemon_is_absent() {
        let dir = tempfile::tempdir().unwrap();
        let home = tempfile::tempdir().unwrap();
        let selection = AbortedSelection;
        let script = FakeScript {
            output: AppleScriptOutput {
                success: true,
                stdout: "OK\n".to_string(),
                stderr: String::new(),
            },
        };
        let (code, msg) = run_resume(
            &dir.path().join("no-such-socket"),
            home.path(),
            &selection,
            &script,
        );
        assert_eq!(code, exitcode::ERROR);
        assert!(msg.is_some());
    }
}
