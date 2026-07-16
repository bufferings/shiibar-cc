//! `shiibar-cc resume --cwd <dir> [--terminal iterm2|apple-terminal]
//! <session-id>` (DESIGN.md §4.3/§4.4): open a new terminal window and resume
//! a past conversation there. Called by the Conversations window's Resume
//! button (§4.6), and usable standalone from a script. Unlike
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

/// Parsed `--cwd <dir> [--terminal <t>] <session-id>` arguments. Pure token
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
}

const USAGE: &str =
    "usage: shiibar-cc resume --cwd <dir> [--terminal iterm2|apple-terminal] <session-id>";

pub fn parse_resume_args(args: &[String]) -> Result<ResumeArgs, String> {
    let mut cwd: Option<PathBuf> = None;
    let mut session_id: Option<String> = None;
    // §4.4: `--terminal` defaults to iterm2 when omitted.
    let mut terminal = TerminalKind::Iterm2;
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
    })
}

/// `resume` (§4.4): validate `cwd` (absolute + exists — before touching
/// AppleScript at all, since a transcript can outlive the folder it was
/// recorded in, §4.4), then open a new window in `terminal` there running
/// `claude --resume <session_id>`.
pub fn run_resume(
    cwd: &Path,
    session_id: &str,
    terminal: TerminalKind,
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

    match open_resume_window(terminal, cwd_str, session_id, runner) {
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
        let report = run_resume(Path::new("relative/path"), "SESSION-1", TerminalKind::Iterm2, &PanicRunner);
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
        let report = run_resume(&missing, "SESSION-1", TerminalKind::Iterm2, &PanicRunner);
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
        let report = run_resume(dir.path(), "SESSION-1", TerminalKind::Iterm2, &runner);
        assert_eq!(report.exit_code, exitcode::OK, "message={:?}", report.message);
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
        let report = run_resume(dir.path(), "SESSION-1", TerminalKind::Iterm2, &runner);
        assert_eq!(report.exit_code, exitcode::TCC_DENIED);
    }

    #[test]
    fn other_osascript_failure_is_exit_1() {
        let dir = tempfile::tempdir().unwrap();
        let runner = ScriptedRunner {
            output: out(false, "", "some other osascript error"),
        };
        let report = run_resume(dir.path(), "SESSION-1", TerminalKind::Iterm2, &runner);
        assert_eq!(report.exit_code, exitcode::ERROR);
    }
}
