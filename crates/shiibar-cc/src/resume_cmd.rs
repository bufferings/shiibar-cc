//! `shiibar-cc resume --cwd <dir> [--terminal iterm2|apple-terminal] [--fork]
//! <session-id>` (DESIGN.md §4.3/§4.4): open a new terminal window and resume
//! a past conversation there. With `--fork`, the command run in the terminal
//! gets `--fork-session` appended, so the conversation continues as a copy
//! under a new session ID and the original is left unchanged (§4.4/§7-6);
//! nothing else differs. Called by the app's Resume action, and by its Branch
//! action with `--fork` (§4.6), and usable standalone from a script. Unlike
//! `focus`/`seen`/`remove`, this does NOT connect to the daemon and does NOT
//! resolve a selector — `cwd`, `session_id`, and the terminal are taken as
//! the caller's explicit, exact values (§4.4: resume makes no decisions of
//! its own — the app decides which terminal from observation, §4.6/T6, and
//! passes `--terminal`; the default is `iterm2`).

use crate::exitcode;
use shiibar_cc_client::terminal::{
    AppleScriptRunner, TerminalError, TerminalKind, open_resume_window,
};
use std::path::{Path, PathBuf};

pub struct ResumeReport {
    pub exit_code: i32,
    pub message: Option<String>,
}

fn ok() -> ResumeReport {
    ResumeReport {
        exit_code: exitcode::OK,
        message: None,
    }
}

fn err(code: i32, msg: impl Into<String>) -> ResumeReport {
    ResumeReport {
        exit_code: code,
        message: Some(msg.into()),
    }
}

/// Parsed `--cwd <dir> [--terminal <t>] [--fork] <session-id>` arguments. Pure token
/// parsing only — no filesystem access here (that's `run_resume`'s job, so
/// the "cwd must be absolute and exist" check, DESIGN.md §4.4, can be tested
/// without touching a real directory for the parsing half).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResumeArgs {
    pub cwd: PathBuf,
    pub session_id: String,
    /// Which terminal to open in (§4.4). Defaults to `iterm2` when
    /// `--terminal` is omitted.
    pub terminal: TerminalKind,
    /// `--fork` (§4.4): append `--fork-session` to the resume command.
    pub fork: bool,
}

const USAGE: &str =
    "usage: shiibar-cc resume --cwd <dir> [--terminal iterm2|apple-terminal] [--fork] <session-id>";

pub fn parse_resume_args(args: &[String]) -> Result<ResumeArgs, String> {
    let mut cwd: Option<PathBuf> = None;
    let mut session_id: Option<String> = None;
    // §4.4: `--terminal` defaults to iterm2 when omitted.
    let mut terminal = TerminalKind::Iterm2;
    let mut fork = false;
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--cwd" => {
                let Some(v) = it.next() else {
                    return Err("shiibar-cc resume: --cwd requires a value".to_string());
                };
                cwd = Some(PathBuf::from(v));
            }
            "--terminal" => {
                let Some(v) = it.next() else {
                    return Err("shiibar-cc resume: --terminal requires a value".to_string());
                };
                terminal = TerminalKind::parse(v).ok_or_else(|| {
                    format!(
                        "shiibar-cc resume: unknown --terminal '{v}' (expected iterm2|apple-terminal)"
                    )
                })?;
            }
            "--fork" => fork = true,
            other if session_id.is_none() => session_id = Some(other.to_string()),
            other => {
                return Err(format!("shiibar-cc resume: unexpected argument '{other}'"));
            }
        }
    }

    let Some(cwd) = cwd else {
        return Err(USAGE.to_string());
    };
    let Some(session_id) = session_id else {
        return Err(USAGE.to_string());
    };
    Ok(ResumeArgs {
        cwd,
        session_id,
        terminal,
        fork,
    })
}

/// `resume` (§4.4): validate `cwd` (absolute + exists — before touching
/// AppleScript at all, since a transcript can outlive the folder it was
/// recorded in, §4.4), then open a new window in `terminal` there running
/// `claude --resume <session_id>` (plus `--fork-session` when `fork` is
/// true — the only difference, §4.4).
pub fn run_resume(
    cwd: &Path,
    session_id: &str,
    terminal: TerminalKind,
    fork: bool,
    runner: &dyn AppleScriptRunner,
) -> ResumeReport {
    if !cwd.is_absolute() {
        return err(
            exitcode::ERROR,
            format!(
                "shiibar-cc resume: --cwd must be an absolute path, got '{}'",
                cwd.display()
            ),
        );
    }
    if !cwd.is_dir() {
        return err(
            exitcode::ERROR,
            format!("shiibar-cc resume: --cwd does not exist: '{}'", cwd.display()),
        );
    }
    let Some(cwd_str) = cwd.to_str() else {
        return err(
            exitcode::ERROR,
            "shiibar-cc resume: --cwd is not valid UTF-8",
        );
    };

    match open_resume_window(terminal, cwd_str, session_id, fork, runner) {
        Ok(()) => ok(),
        Err(TerminalError::PermissionDenied) => err(
            exitcode::TCC_DENIED,
            "shiibar-cc resume: osascript automation permission for the terminal is denied",
        ),
        // NoMatch isn't a real outcome of open_resume_window (it always
        // creates a new window, it never searches for one) — mapped to the
        // generic internal-error exit code defensively, since resume's
        // exit-code contract (§4.4) has no "not found" (2) case.
        Err(TerminalError::NoMatch) => err(
            exitcode::ERROR,
            "shiibar-cc resume: unexpected internal error (no-match result)",
        ),
        Err(TerminalError::Other(msg)) => err(exitcode::ERROR, format!("shiibar-cc resume: {msg}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use shiibar_cc_client::terminal::AppleScriptOutput;

    fn out(success: bool, stdout: &str, stderr: &str) -> AppleScriptOutput {
        AppleScriptOutput {
            success,
            stdout: stdout.to_string(),
            stderr: stderr.to_string(),
        }
    }

    struct ScriptedRunner {
        output: AppleScriptOutput,
    }

    impl AppleScriptRunner for ScriptedRunner {
        fn run(&self, _script: &str) -> std::io::Result<AppleScriptOutput> {
            Ok(self.output.clone())
        }
    }

    fn args(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    // ---- parse_resume_args ----

    #[test]
    fn parses_cwd_before_session_id_and_defaults_terminal_to_iterm2() {
        let parsed = parse_resume_args(&args(&["--cwd", "/tmp/proj", "SESSION-1"])).unwrap();
        assert_eq!(parsed.cwd, PathBuf::from("/tmp/proj"));
        assert_eq!(parsed.session_id, "SESSION-1");
        // §4.4: omitting --terminal defaults to iterm2.
        assert_eq!(parsed.terminal, TerminalKind::Iterm2);
    }

    #[test]
    fn parses_an_explicit_apple_terminal() {
        let parsed =
            parse_resume_args(&args(&["--cwd", "/tmp/proj", "--terminal", "apple-terminal", "S"]))
                .unwrap();
        assert_eq!(parsed.terminal, TerminalKind::AppleTerminal);
    }

    #[test]
    fn parses_an_explicit_iterm2() {
        let parsed =
            parse_resume_args(&args(&["--terminal", "iterm2", "--cwd", "/tmp/proj", "S"])).unwrap();
        assert_eq!(parsed.terminal, TerminalKind::Iterm2);
    }

    #[test]
    fn an_unknown_terminal_value_is_an_error() {
        assert!(
            parse_resume_args(&args(&["--cwd", "/tmp/proj", "--terminal", "tmux", "S"])).is_err()
        );
    }

    #[test]
    fn terminal_flag_with_no_value_is_an_error() {
        assert!(parse_resume_args(&args(&["--cwd", "/tmp/proj", "S", "--terminal"])).is_err());
    }

    #[test]
    fn parses_session_id_before_cwd() {
        let parsed = parse_resume_args(&args(&["SESSION-1", "--cwd", "/tmp/proj"])).unwrap();
        assert_eq!(parsed.cwd, PathBuf::from("/tmp/proj"));
        assert_eq!(parsed.session_id, "SESSION-1");
    }

    #[test]
    fn fork_defaults_to_false_when_omitted() {
        let parsed = parse_resume_args(&args(&["--cwd", "/tmp/proj", "S"])).unwrap();
        assert!(!parsed.fork);
    }

    #[test]
    fn parses_fork_after_the_session_id() {
        let parsed = parse_resume_args(&args(&["--cwd", "/tmp/proj", "S", "--fork"])).unwrap();
        assert!(parsed.fork);
        assert_eq!(parsed.session_id, "S");
        assert_eq!(parsed.cwd, PathBuf::from("/tmp/proj"));
    }

    #[test]
    fn parses_fork_first_before_every_other_argument() {
        let parsed = parse_resume_args(&args(&[
            "--fork",
            "--terminal",
            "apple-terminal",
            "--cwd",
            "/tmp/proj",
            "S",
        ]))
        .unwrap();
        assert!(parsed.fork);
        assert_eq!(parsed.terminal, TerminalKind::AppleTerminal);
        assert_eq!(parsed.session_id, "S");
        assert_eq!(parsed.cwd, PathBuf::from("/tmp/proj"));
    }

    #[test]
    fn parses_fork_between_other_options() {
        let parsed = parse_resume_args(&args(&[
            "--cwd",
            "/tmp/proj",
            "--fork",
            "--terminal",
            "iterm2",
            "S",
        ]))
        .unwrap();
        assert!(parsed.fork);
        assert_eq!(parsed.terminal, TerminalKind::Iterm2);
        assert_eq!(parsed.session_id, "S");
    }

    #[test]
    fn fork_does_not_consume_the_following_token() {
        // `--fork` takes no value: the next token is still the session id.
        let parsed = parse_resume_args(&args(&["--fork", "S", "--cwd", "/tmp/proj"])).unwrap();
        assert!(parsed.fork);
        assert_eq!(parsed.session_id, "S");
    }

    #[test]
    fn fork_alone_still_requires_cwd_and_session_id() {
        assert!(parse_resume_args(&args(&["--fork"])).is_err());
        assert!(parse_resume_args(&args(&["--fork", "S"])).is_err());
        assert!(parse_resume_args(&args(&["--fork", "--cwd", "/tmp/proj"])).is_err());
    }

    #[test]
    fn missing_cwd_is_an_error() {
        assert!(parse_resume_args(&args(&["SESSION-1"])).is_err());
    }

    #[test]
    fn missing_session_id_is_an_error() {
        assert!(parse_resume_args(&args(&["--cwd", "/tmp/proj"])).is_err());
    }

    #[test]
    fn cwd_flag_with_no_value_is_an_error() {
        assert!(parse_resume_args(&args(&["--cwd"])).is_err());
    }

    #[test]
    fn a_second_positional_argument_is_an_error() {
        assert!(parse_resume_args(&args(&["--cwd", "/tmp/proj", "SESSION-1", "extra"])).is_err());
    }

    #[test]
    fn no_arguments_is_an_error() {
        assert!(parse_resume_args(&args(&[])).is_err());
    }

    // ---- run_resume: cwd validation happens before any AppleScript ----

    #[test]
    fn relative_cwd_is_exit_1_and_never_touches_osascript() {
        struct PanicRunner;
        impl AppleScriptRunner for PanicRunner {
            fn run(&self, _script: &str) -> std::io::Result<AppleScriptOutput> {
                panic!("osascript must not run for a relative --cwd");
            }
        }
        let report = run_resume(
            Path::new("relative/path"),
            "SESSION-1",
            TerminalKind::Iterm2,
            false,
            &PanicRunner,
        );
        assert_eq!(report.exit_code, exitcode::ERROR);
        assert!(report.message.is_some());
    }

    #[test]
    fn nonexistent_cwd_is_exit_1_and_never_touches_osascript() {
        struct PanicRunner;
        impl AppleScriptRunner for PanicRunner {
            fn run(&self, _script: &str) -> std::io::Result<AppleScriptOutput> {
                panic!("osascript must not run for a nonexistent --cwd");
            }
        }
        let dir = tempfile::tempdir().unwrap();
        let missing = dir.path().join("does-not-exist");
        let report = run_resume(
            &missing,
            "SESSION-1",
            TerminalKind::Iterm2,
            false,
            &PanicRunner,
        );
        assert_eq!(report.exit_code, exitcode::ERROR);
        assert!(report.message.is_some());
    }

    // ---- run_resume: exit-code mapping from open_resume_window (§4.4) ----

    #[test]
    fn successful_resume_is_exit_0() {
        let dir = tempfile::tempdir().unwrap();
        let runner = ScriptedRunner {
            output: out(true, "OK\n", ""),
        };
        let report = run_resume(
            dir.path(),
            "SESSION-1",
            TerminalKind::Iterm2,
            false,
            &runner,
        );
        assert_eq!(
            report.exit_code,
            exitcode::OK,
            "message={:?}",
            report.message
        );
    }

    #[test]
    fn tcc_denied_is_exit_3() {
        let dir = tempfile::tempdir().unwrap();
        let runner = ScriptedRunner {
            output: out(
                false,
                "",
                "Not authorized to send Apple events to iTerm2. (-1743)",
            ),
        };
        let report = run_resume(
            dir.path(),
            "SESSION-1",
            TerminalKind::Iterm2,
            false,
            &runner,
        );
        assert_eq!(report.exit_code, exitcode::TCC_DENIED);
    }

    /// Records the script it was asked to run, so a test can check the
    /// command line that would be typed into the new window.
    struct CapturingRunner {
        scripts: std::cell::RefCell<Vec<String>>,
    }

    impl CapturingRunner {
        fn new() -> Self {
            CapturingRunner {
                scripts: std::cell::RefCell::new(Vec::new()),
            }
        }
    }

    impl AppleScriptRunner for CapturingRunner {
        fn run(&self, script: &str) -> std::io::Result<AppleScriptOutput> {
            self.scripts.borrow_mut().push(script.to_string());
            Ok(out(true, "OK\n", ""))
        }
    }

    #[test]
    fn fork_appends_fork_session_in_both_terminals() {
        for terminal in [TerminalKind::Iterm2, TerminalKind::AppleTerminal] {
            let dir = tempfile::tempdir().unwrap();
            let runner = CapturingRunner::new();
            let report = run_resume(dir.path(), "SESSION-1", terminal, true, &runner);
            assert_eq!(
                report.exit_code,
                exitcode::OK,
                "message={:?}",
                report.message
            );
            let scripts = runner.scripts.borrow();
            assert_eq!(scripts.len(), 1);
            assert!(
                scripts[0].contains("claude --resume 'SESSION-1' --fork-session\""),
                "{terminal:?}: {}",
                scripts[0]
            );
        }
    }

    #[test]
    fn no_fork_omits_fork_session_in_both_terminals() {
        for terminal in [TerminalKind::Iterm2, TerminalKind::AppleTerminal] {
            let dir = tempfile::tempdir().unwrap();
            let runner = CapturingRunner::new();
            let report = run_resume(dir.path(), "SESSION-1", terminal, false, &runner);
            assert_eq!(
                report.exit_code,
                exitcode::OK,
                "message={:?}",
                report.message
            );
            let scripts = runner.scripts.borrow();
            assert_eq!(scripts.len(), 1);
            assert!(scripts[0].contains("claude --resume 'SESSION-1'\""));
            assert!(!scripts[0].contains("--fork-session"));
        }
    }

    #[test]
    fn fork_with_a_relative_cwd_is_still_exit_1_without_osascript() {
        // §4.4: --fork changes nothing about the cwd check.
        let runner = CapturingRunner::new();
        let report = run_resume(
            Path::new("relative/path"),
            "SESSION-1",
            TerminalKind::Iterm2,
            true,
            &runner,
        );
        assert_eq!(report.exit_code, exitcode::ERROR);
        assert!(runner.scripts.borrow().is_empty());
    }

    #[test]
    fn fork_tcc_denied_is_still_exit_3() {
        let dir = tempfile::tempdir().unwrap();
        let runner = ScriptedRunner {
            output: out(
                false,
                "",
                "Not authorized to send Apple events to Terminal. (-1743)",
            ),
        };
        let report = run_resume(
            dir.path(),
            "SESSION-1",
            TerminalKind::AppleTerminal,
            true,
            &runner,
        );
        assert_eq!(report.exit_code, exitcode::TCC_DENIED);
    }

    #[test]
    fn other_osascript_failure_is_exit_1() {
        let dir = tempfile::tempdir().unwrap();
        let runner = ScriptedRunner {
            output: out(false, "", "some other osascript error"),
        };
        let report = run_resume(
            dir.path(),
            "SESSION-1",
            TerminalKind::Iterm2,
            false,
            &runner,
        );
        assert_eq!(report.exit_code, exitcode::ERROR);
    }
}
