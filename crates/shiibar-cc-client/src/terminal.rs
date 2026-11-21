//! Shared terminal plumbing and the single prefix-dispatch entry point
//! (DESIGN.md §4.3). The osascript / `ps` runners and the error/outcome
//! types are generic (not terminal-specific knowledge — design principle 2
//! keeps *terminal* knowledge in the `iterm2` / `apple_terminal` / `ghostty`
//! modules, but the osascript process plumbing itself is common), so they
//! live here and every terminal module builds on them.
//!
//! Routing (§4.3): `iterm2:` -> the iterm2 module, `apple-terminal:` -> the
//! apple_terminal module, `ghostty:` -> the ghostty module. `process:` is a
//! session in a terminal shiibar can't drive, so it goes to no module and is
//! "no match" without running any osascript (§2). A `:`-less target is
//! treated as a bare iTerm2 UUID (pre-prefix / hand-typed / notifications
//! delivered before an upgrade), and a `wNtNpN:UUID` target (a hand-pasted
//! `$ITERM_SESSION_ID`) also goes to iterm2. Any other unknown prefix is "no
//! match" (never silently routed to iterm2).

use std::io::Write as _;
use std::process::{Command, Stdio};

// ---------------------------------------------------------------------
// osascript runner (shared)
// ---------------------------------------------------------------------

/// Output of one `osascript` invocation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppleScriptOutput {
    pub success: bool,
    pub stdout: String,
    pub stderr: String,
}

/// Runs an AppleScript source string and returns its output. Injected so
/// tests can substitute a fake (DESIGN.md §4.3 test-separation requirement).
pub trait AppleScriptRunner {
    fn run(&self, script: &str) -> std::io::Result<AppleScriptOutput>;
}

/// Real `osascript` runner: the script is piped over stdin (`osascript -`)
/// rather than passed as a `-e` argument, so no shell-escaping is needed
/// for the generated multi-line source.
pub struct Osascript;

impl AppleScriptRunner for Osascript {
    fn run(&self, script: &str) -> std::io::Result<AppleScriptOutput> {
        let mut child = Command::new("osascript")
            .arg("-")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;
        child
            .stdin
            .take()
            .expect("stdin was requested as piped")
            .write_all(script.as_bytes())?;
        let output = child.wait_with_output()?;
        Ok(AppleScriptOutput {
            success: output.status.success(),
            stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        })
    }
}

// ---------------------------------------------------------------------
// Error type (shared)
// ---------------------------------------------------------------------

/// Errors from a terminal operation. The no-match vs. TCC-permission
/// distinction is required by DESIGN.md §4.4 (shiibar-cc exit 2 vs. 3), and
/// is the same across every terminal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TerminalError {
    NoMatch,
    PermissionDenied,
    Other(String),
}

impl std::fmt::Display for TerminalError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            TerminalError::NoMatch => write!(f, "no matching terminal session"),
            TerminalError::PermissionDenied => {
                write!(f, "osascript is not authorized to control the terminal (Automation permission)")
            }
            TerminalError::Other(s) => write!(f, "{s}"),
        }
    }
}

impl std::error::Error for TerminalError {}

pub type TerminalResult<T> = Result<T, TerminalError>;

/// TCC Automation-permission denial: osascript exits non-zero with an error
/// mentioning "not authorized to send Apple events" / AppleEvent error
/// -1743. Shared by every terminal module's output parsers.
pub(crate) fn is_permission_denied(output: &AppleScriptOutput) -> bool {
    let text = output.stderr.to_lowercase();
    text.contains("not authorized to send apple events") || text.contains("-1743")
}

pub(crate) fn bad_output(stdout: &str) -> TerminalError {
    TerminalError::Other(format!("unexpected osascript output: {stdout:?}"))
}

/// Outcome of a harmless TCC probe (DESIGN.md §4.4): the terminal answered
/// (permission granted) or it isn't running (permission couldn't be checked).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProbeOutcome {
    /// The terminal isn't running, so permission couldn't be checked.
    NotRunning,
    /// The terminal answered a query: automation permission is granted.
    Granted,
}

// ---------------------------------------------------------------------
// ps runner (shared by every *_targets)
// ---------------------------------------------------------------------

/// Output of one `ps` invocation, mirroring `AppleScriptOutput`'s
/// success/stdout split so a failed `ps` degrades the same way a failed
/// `osascript` does (§3.5: "an incomplete scan must not prune").
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PsOutput {
    pub success: bool,
    pub stdout: String,
}

/// Runs `ps` to resolve pid -> tty. Injected so tests never shell out to the
/// real `ps` (DESIGN.md / M2 task brief test-separation requirement).
pub trait PsRunner {
    fn run(&self, pids: &[u32]) -> std::io::Result<PsOutput>;
}

/// Real `ps` runner: `ps -o pid=,tty= -p <comma-separated pids>` (verified
/// on a real machine 2026-07-04: prints `"<pid> <tty>"` per line, `tty`
/// without a `/dev/` prefix, e.g. `ttys003`; a pid that isn't running is
/// silently omitted from the output rather than erroring).
pub struct RealPs;

impl PsRunner for RealPs {
    fn run(&self, pids: &[u32]) -> std::io::Result<PsOutput> {
        let pid_list = pids.iter().map(u32::to_string).collect::<Vec<_>>().join(",");
        let output = Command::new("ps")
            .args(["-o", "pid=,tty=", "-p", &pid_list])
            .output()?;
        Ok(PsOutput {
            success: output.status.success(),
            stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
        })
    }
}

/// Parse `ps -o pid=,tty=` output into a pid -> tty map. Lines that don't
/// parse as `<pid> <tty>` are skipped rather than failing the whole batch
/// (defensive: a stray warning line on stderr wouldn't land here, but this
/// keeps the parser total).
pub fn parse_ps_tty_output(stdout: &str) -> std::collections::HashMap<u32, String> {
    stdout
        .lines()
        .filter_map(|line| {
            let mut parts = line.split_whitespace();
            let pid: u32 = parts.next()?.parse().ok()?;
            let tty = parts.next()?.to_string();
            Some((pid, tty))
        })
        .collect()
}

/// Whether a tty value from `parse_ps_tty_output` names a controlling
/// terminal. `ps -o tty=` prints `??` for a process without one (checked
/// with the system `ps` on 2026-11-21; the same `??` the hook side sees,
/// §7-7), and such a process is a session without a terminal, which
/// reconcile does not send (§3.5).
pub fn has_controlling_tty(tty: &str) -> bool {
    !tty.is_empty() && tty != "??"
}

/// Escape `s` for embedding inside an AppleScript double-quoted string
/// literal (backslash and double-quote are the two metacharacters). Shared
/// by every terminal's `build_*_script` functions.
pub(crate) fn escape_as_string_literal(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

/// Wrap `s` in POSIX shell single quotes, safe against any byte the shell
/// treats specially (spaces, `$`, backticks, double quotes, `;`, ...):
/// single quotes make everything between them literal except a single quote
/// itself, so each embedded `'` is closed, escaped as `\'`, and reopened
/// (`'\''`). Used by every terminal's resume script for the `cd`/`claude
/// --resume` command line sent to the new window's shell.
pub(crate) fn escape_shell_single_quoted(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('\'');
    for c in s.chars() {
        if c == '\'' {
            out.push_str("'\\''");
        } else {
            out.push(c);
        }
    }
    out.push('\'');
    out
}

/// The `cd <cwd> && claude --resume <session_id>` shell command line run in
/// the new window (DESIGN.md §4.3). When `fork` is true, `--fork-session` is
/// appended at the end (`... claude --resume <session_id> --fork-session`,
/// §4.4): the conversation continues as a copy under a new session ID and the
/// original is left unchanged (§7-6). Each argument is POSIX single-quote
/// escaped independently — `cwd` may contain spaces, quotes, or `$`, and
/// `session_id` is expected to be a UUID but is escaped the same way rather
/// than trusted (§4.3: "escape it, don't validate it"). Shared by every
/// terminal's resume script.
pub(crate) fn build_resume_shell_command(cwd: &str, session_id: &str, fork: bool) -> String {
    let mut command = format!(
        "cd {} && claude --resume {}",
        escape_shell_single_quoted(cwd),
        escape_shell_single_quoted(session_id)
    );
    if fork {
        command.push_str(" --fork-session");
    }
    command
}

/// Normalize a tty for comparison: `ps` prints it bare (`ttys003`), the
/// terminals' AppleScript `tty of ...` prints it with a `/dev/` prefix
/// (`/dev/ttys003`) — verified on a real machine (iTerm2: §7-1; Terminal.app:
/// §7-7; Ghostty: §7-8). Stripping the prefix (if present) makes the two
/// comparable regardless of source.
pub(crate) fn normalize_tty(tty: &str) -> &str {
    tty.strip_prefix("/dev/").unwrap_or(tty)
}

// ---------------------------------------------------------------------
// Prefix dispatch (§4.3)
// ---------------------------------------------------------------------

/// Which terminal a `resume` should open in (DESIGN.md §4.4 `--terminal`).
/// The app passes the terminal chosen in Settings (§4.6); the CLI just
/// opens.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TerminalKind {
    Iterm2,
    AppleTerminal,
    Ghostty,
}

impl TerminalKind {
    /// Parse the `--terminal` argument value (`iterm2` / `apple-terminal` /
    /// `ghostty`, the target prefixes without the trailing `:`). Anything
    /// else is rejected by the caller.
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "iterm2" => Some(TerminalKind::Iterm2),
            "apple-terminal" => Some(TerminalKind::AppleTerminal),
            "ghostty" => Some(TerminalKind::Ghostty),
            _ => None,
        }
    }
}

/// Whether `target` is a `process:<pid>` target: a session running in a
/// terminal shiibar can't drive, which has no tab to jump to (§2). `focus`
/// routes it to no module (§4.3); `shiibar-cc focus` uses this to report
/// that case differently from a closed tab (§4.4).
pub fn is_process_target(target: &str) -> bool {
    target.starts_with("process:")
}

/// The routing outcome for a target (§4.3). The borrowed `&str` is the
/// per-module argument: the iterm2 UUID (bare or `wNtNpN:UUID`) for
/// `Iterm2`, or the tty path for `AppleTerminal` and `Ghostty`.
enum Route<'a> {
    Iterm2(&'a str),
    AppleTerminal(&'a str),
    Ghostty(&'a str),
    NoMatch,
}

/// Classify a target by its prefix (§4.3). See the module docs for the full
/// set of rules; the one subtlety is the `:`-bearing-but-unprefixed case,
/// which routes to iterm2 only when the whole target is a `wNtNpN:UUID`
/// (recognized by `iterm2::extract_uuid`) and is "no match" otherwise.
fn route(target: &str) -> Route<'_> {
    if let Some(rest) = target.strip_prefix("iterm2:") {
        return Route::Iterm2(rest);
    }
    if let Some(rest) = target.strip_prefix("apple-terminal:") {
        return Route::AppleTerminal(rest);
    }
    if let Some(rest) = target.strip_prefix("ghostty:") {
        return Route::Ghostty(rest);
    }
    if is_process_target(target) {
        // A session in a terminal shiibar can't drive: not jumpable (§2).
        return Route::NoMatch;
    }
    match target.split_once(':') {
        // No `:` at all: a pre-prefix / hand-typed bare iTerm2 UUID (§4.3).
        None => Route::Iterm2(target),
        // Has a `:` but not a known prefix: only `wNtNpN:UUID` is accepted
        // (hand-pasted $ITERM_SESSION_ID, §4.3); every other unknown prefix
        // is "no match", never silently sent to iterm2.
        Some(_) => {
            if crate::iterm2::extract_uuid(target).is_some() {
                Route::Iterm2(target)
            } else {
                Route::NoMatch
            }
        }
    }
}

/// `focus(target)` (DESIGN.md §4.3/§4.4): route by prefix and jump to the
/// matching terminal session. An unknown prefix (or an empty / malformed
/// target) is `NoMatch` and never runs any osascript.
pub fn focus(target: &str, runner: &dyn AppleScriptRunner) -> TerminalResult<()> {
    match route(target) {
        Route::Iterm2(uuid) => crate::iterm2::focus(uuid, runner),
        Route::AppleTerminal(tty) => crate::apple_terminal::focus(tty, runner),
        Route::Ghostty(tty) => crate::ghostty::focus(tty, runner),
        Route::NoMatch => Err(TerminalError::NoMatch),
    }
}

/// `focused()` (DESIGN.md §4.3/§4.4): the frontmost supported terminal's
/// front session target (already prefixed), or `None` if none of iTerm2,
/// Terminal.app, and Ghostty is frontmost. They are asked in that order and
/// the first target returned wins; each module's `focused` checks whether
/// its app is the frontmost one, and only one app is frontmost, so the
/// order doesn't change the result (§4.3).
pub fn focused(runner: &dyn AppleScriptRunner) -> TerminalResult<Option<String>> {
    if let Some(target) = crate::iterm2::focused(runner)? {
        return Ok(Some(target));
    }
    if let Some(target) = crate::apple_terminal::focused(runner)? {
        return Ok(Some(target));
    }
    crate::ghostty::focused(runner)
}

/// `open_resume_window` dispatch (DESIGN.md §4.3/§4.4): open a new window in
/// the chosen terminal and run `claude --resume <session_id>` there (with
/// `--fork-session` appended when `fork` is true — §4.4).
pub fn open_resume_window(
    kind: TerminalKind,
    cwd: &str,
    session_id: &str,
    fork: bool,
    runner: &dyn AppleScriptRunner,
) -> TerminalResult<()> {
    match kind {
        TerminalKind::Iterm2 => crate::iterm2::open_resume_window(cwd, session_id, fork, runner),
        TerminalKind::AppleTerminal => {
            crate::apple_terminal::open_resume_window(cwd, session_id, fork, runner)
        }
        TerminalKind::Ghostty => crate::ghostty::open_resume_window(cwd, session_id, fork, runner),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ---- ps / tty helpers (shared) ----

    #[test]
    fn parse_ps_tty_output_builds_a_pid_to_tty_map() {
        let map = parse_ps_tty_output("20124 ttys000\n16437 ttys001\n");
        assert_eq!(map.get(&20124).map(String::as_str), Some("ttys000"));
        assert_eq!(map.get(&16437).map(String::as_str), Some("ttys001"));
        assert_eq!(map.len(), 2);
    }

    #[test]
    fn parse_ps_tty_output_skips_unparseable_lines() {
        let map = parse_ps_tty_output("not a line\n20124 ttys000\n");
        assert_eq!(map.len(), 1);
        assert_eq!(map.get(&20124).map(String::as_str), Some("ttys000"));
    }

    #[test]
    fn has_controlling_tty_rejects_the_no_terminal_marker_and_empty() {
        assert!(has_controlling_tty("ttys003"));
        assert!(!has_controlling_tty("??"));
        assert!(!has_controlling_tty(""));
    }

    #[test]
    fn normalize_tty_strips_dev_prefix() {
        assert_eq!(normalize_tty("/dev/ttys003"), "ttys003");
        assert_eq!(normalize_tty("ttys003"), "ttys003");
    }

    // ---- escaping helpers (shared) ----

    #[test]
    fn escape_shell_single_quoted_wraps_plain_text() {
        assert_eq!(escape_shell_single_quoted("plain"), "'plain'");
    }

    #[test]
    fn escape_shell_single_quoted_handles_spaces_and_dollar_and_backticks() {
        // Single-quoting makes the shell treat these as plain bytes; no
        // separate handling needed for any of them.
        assert_eq!(
            escape_shell_single_quoted("has space $VAR `cmd`"),
            "'has space $VAR `cmd`'"
        );
    }

    #[test]
    fn escape_shell_single_quoted_escapes_embedded_single_quotes() {
        assert_eq!(escape_shell_single_quoted("it's"), r#"'it'\''s'"#);
    }

    #[test]
    fn escape_shell_single_quoted_handles_empty_string() {
        assert_eq!(escape_shell_single_quoted(""), "''");
    }

    #[test]
    fn escape_as_string_literal_escapes_backslash_and_quote() {
        assert_eq!(escape_as_string_literal(r#"a"b\c"#), r#"a\"b\\c"#);
    }

    #[test]
    fn build_resume_shell_command_joins_cd_and_resume() {
        assert_eq!(
            build_resume_shell_command("/Users/example/proj", "SESSION-1", false),
            "cd '/Users/example/proj' && claude --resume 'SESSION-1'"
        );
    }

    #[test]
    fn build_resume_shell_command_appends_fork_session_last_when_forking() {
        // §4.4: `--fork` adds `--fork-session` at the end of the command.
        assert_eq!(
            build_resume_shell_command("/Users/example/proj", "SESSION-1", true),
            "cd '/Users/example/proj' && claude --resume 'SESSION-1' --fork-session"
        );
    }

    #[test]
    fn build_resume_shell_command_escapes_the_same_way_when_forking() {
        assert_eq!(
            build_resume_shell_command("/Users/example/O'Brien", "weird'id", true),
            r#"cd '/Users/example/O'\''Brien' && claude --resume 'weird'\''id' --fork-session"#
        );
    }

    // ---- TerminalKind::parse ----

    #[test]
    fn terminal_kind_parses_the_three_prefixes() {
        assert_eq!(TerminalKind::parse("iterm2"), Some(TerminalKind::Iterm2));
        assert_eq!(
            TerminalKind::parse("apple-terminal"),
            Some(TerminalKind::AppleTerminal)
        );
        assert_eq!(TerminalKind::parse("ghostty"), Some(TerminalKind::Ghostty));
        assert_eq!(TerminalKind::parse("tmux"), None);
        assert_eq!(TerminalKind::parse(""), None);
    }

    // ---- route() classification (§4.3, all branches) ----

    fn route_kind(target: &str) -> &'static str {
        route_kind_of(&route(target))
    }

    #[test]
    fn route_iterm2_prefix_strips_to_the_bare_uuid() {
        match route("iterm2:ABCD-1234") {
            Route::Iterm2(uuid) => assert_eq!(uuid, "ABCD-1234"),
            other => panic!("expected iterm2, got {}", route_kind_of(&other)),
        }
    }

    #[test]
    fn route_apple_terminal_prefix_strips_to_the_tty_path() {
        match route("apple-terminal:/dev/ttys006") {
            Route::AppleTerminal(tty) => assert_eq!(tty, "/dev/ttys006"),
            other => panic!("expected apple-terminal, got {}", route_kind_of(&other)),
        }
    }

    #[test]
    fn route_ghostty_prefix_strips_to_the_tty_path() {
        match route("ghostty:/dev/ttys005") {
            Route::Ghostty(tty) => assert_eq!(tty, "/dev/ttys005"),
            other => panic!("expected ghostty, got {}", route_kind_of(&other)),
        }
    }

    #[test]
    fn route_a_process_target_is_no_match() {
        // §2/§4.3: a session in a terminal shiibar can't drive goes to no
        // terminal module.
        assert_eq!(route_kind("process:48213"), "no-match");
    }

    #[test]
    fn is_process_target_matches_only_the_process_prefix() {
        assert!(is_process_target("process:48213"));
        assert!(!is_process_target("iterm2:ABCD-1234"));
        assert!(!is_process_target("apple-terminal:/dev/ttys006"));
        assert!(!is_process_target("ghostty:/dev/ttys005"));
        assert!(!is_process_target("BARE-UUID"));
        assert!(!is_process_target("w0t0p0:ABCD-1234"));
    }

    #[test]
    fn route_a_colonless_target_is_a_bare_iterm2_uuid() {
        // §4.3: pre-prefix / hand-typed / pre-upgrade-notification targets.
        match route("BARE-UUID") {
            Route::Iterm2(uuid) => assert_eq!(uuid, "BARE-UUID"),
            other => panic!("expected iterm2, got {}", route_kind_of(&other)),
        }
    }

    #[test]
    fn route_a_wntnpn_target_goes_to_iterm2_whole() {
        // §4.3: a hand-pasted $ITERM_SESSION_ID (`wNtNpN:UUID`) routes to
        // iterm2, passing the whole string (extract_uuid pulls the UUID half).
        match route("w0t0p0:ABCD-1234") {
            Route::Iterm2(v) => assert_eq!(v, "w0t0p0:ABCD-1234"),
            other => panic!("expected iterm2, got {}", route_kind_of(&other)),
        }
    }

    #[test]
    fn route_an_unknown_prefix_is_no_match() {
        // §4.3: never silently sent to iterm2.
        assert_eq!(route_kind("tmux:whatever"), "no-match");
        assert_eq!(route_kind("vscode:1234"), "no-match");
    }

    // A tiny helper so the panic arms above can name the wrong variant.
    fn route_kind_of(r: &Route<'_>) -> &'static str {
        match r {
            Route::Iterm2(_) => "iterm2",
            Route::AppleTerminal(_) => "apple-terminal",
            Route::Ghostty(_) => "ghostty",
            Route::NoMatch => "no-match",
        }
    }

    // ---- focus dispatch: routing decides which module runs ----

    struct PanicRunner;
    impl AppleScriptRunner for PanicRunner {
        fn run(&self, _script: &str) -> std::io::Result<AppleScriptOutput> {
            panic!("osascript must not run for a no-match target");
        }
    }

    #[test]
    fn focus_unknown_prefix_is_no_match_without_running_osascript() {
        assert_eq!(focus("tmux:whatever", &PanicRunner), Err(TerminalError::NoMatch));
    }

    struct OkRunner {
        stdout: &'static str,
    }
    impl AppleScriptRunner for OkRunner {
        fn run(&self, script: &str) -> std::io::Result<AppleScriptOutput> {
            // Assert routing landed in the intended module by inspecting a
            // marker unique to each module's focus script.
            Ok(AppleScriptOutput {
                success: true,
                stdout: self.stdout.to_string(),
                stderr: script.to_string(),
            })
        }
    }

    #[test]
    fn focus_iterm2_prefix_routes_to_the_iterm2_module() {
        // The iterm2 module asks whether iTerm2 is running, then sends its
        // focus script for the bare UUID.
        let runner = MarkerRunner::new(vec![
            (ITERM2_RUNNING, "RUNNING\n"),
            (ITERM2_FOCUS, "FOUND\n"),
        ]);
        assert_eq!(focus("iterm2:UUID", &runner), Ok(()));
        let scripts = runner.scripts();
        assert_eq!(scripts.len(), 2);
        assert!(scripts[0].contains(ITERM2_RUNNING));
        assert!(scripts[1].contains(r#"if sid is "UUID""#));
    }

    #[test]
    fn focus_apple_terminal_prefix_routes_to_the_apple_terminal_module() {
        // The apple_terminal focus script addresses Terminal.app.
        let runner = OkRunner { stdout: "FOUND\n" };
        assert_eq!(focus("apple-terminal:/dev/ttys006", &runner), Ok(()));
    }

    #[test]
    fn focus_process_target_is_no_match_without_running_osascript() {
        // §4.3: a `process:` target is not jumpable; no osascript runs.
        assert_eq!(focus("process:48213", &PanicRunner), Err(TerminalError::NoMatch));
    }

    /// Records every script and answers with the first canned output whose
    /// marker the script contains, so a test can tell which module ran.
    struct MarkerRunner {
        answers: Vec<(&'static str, AppleScriptOutput)>,
        scripts: std::cell::RefCell<Vec<String>>,
    }

    impl MarkerRunner {
        fn new(answers: Vec<(&'static str, &'static str)>) -> Self {
            MarkerRunner {
                answers: answers
                    .into_iter()
                    .map(|(marker, stdout)| {
                        (
                            marker,
                            AppleScriptOutput {
                                success: true,
                                stdout: stdout.to_string(),
                                stderr: String::new(),
                            },
                        )
                    })
                    .collect(),
                scripts: std::cell::RefCell::new(Vec::new()),
            }
        }

        fn scripts(&self) -> Vec<String> {
            self.scripts.borrow().clone()
        }
    }

    impl AppleScriptRunner for MarkerRunner {
        fn run(&self, script: &str) -> std::io::Result<AppleScriptOutput> {
            self.scripts.borrow_mut().push(script.to_string());
            let (_, output) = self
                .answers
                .iter()
                .find(|(marker, _)| script.contains(marker))
                .unwrap_or_else(|| panic!("no canned output for script: {script}"));
            Ok(output.clone())
        }
    }

    const ITERM2_RUNNING: &str = r#"return "RUNNING""#;
    const ITERM2_FOCUS: &str = "if sid is";
    const ITERM2_FOCUSED: &str = "current session of current window";
    const APPLE_TERMINAL_FOCUSED: &str = "tty of selected tab of front window";
    const GHOSTTY_VERSION: &str = r#"return "VERSION:""#;
    const GHOSTTY_FOCUSED: &str = "tty of focused terminal";
    const GHOSTTY_FOCUS: &str = "every terminal whose tty is";

    #[test]
    fn focus_ghostty_prefix_routes_to_the_ghostty_module() {
        let runner = MarkerRunner::new(vec![
            (GHOSTTY_VERSION, "VERSION:1.4.0\n"),
            (GHOSTTY_FOCUS, "FOUND\n"),
        ]);
        assert_eq!(focus("ghostty:/dev/ttys005", &runner), Ok(()));
        let scripts = runner.scripts();
        assert_eq!(scripts.len(), 2);
        assert!(scripts[1].contains(r#"every terminal whose tty is "/dev/ttys005""#));
    }

    #[test]
    fn focused_asks_iterm2_then_apple_terminal_then_ghostty_and_returns_ghosttys_target() {
        let runner = MarkerRunner::new(vec![
            (ITERM2_RUNNING, "RUNNING\n"),
            (ITERM2_FOCUSED, "NONE\n"),
            (APPLE_TERMINAL_FOCUSED, "NONE\n"),
            (GHOSTTY_VERSION, "VERSION:1.4.0\n"),
            (GHOSTTY_FOCUSED, "FOCUSED:/dev/ttys005\n"),
        ]);
        assert_eq!(focused(&runner), Ok(Some("ghostty:/dev/ttys005".to_string())));
        let scripts = runner.scripts();
        assert_eq!(scripts.len(), 5);
        assert!(scripts[0].contains(ITERM2_RUNNING));
        assert!(scripts[1].contains(ITERM2_FOCUSED));
        assert!(scripts[2].contains(APPLE_TERMINAL_FOCUSED));
        assert!(scripts[3].contains(GHOSTTY_VERSION));
        assert!(scripts[4].contains(GHOSTTY_FOCUSED));
    }

    #[test]
    fn focused_returns_the_first_module_target_without_asking_the_later_ones() {
        let runner = MarkerRunner::new(vec![
            (ITERM2_RUNNING, "RUNNING\n"),
            (ITERM2_FOCUSED, "FOCUSED:UUID-1\n"),
        ]);
        assert_eq!(focused(&runner), Ok(Some("iterm2:UUID-1".to_string())));
        assert_eq!(runner.scripts().len(), 2, "iTerm2's running query and focused query only");

        let runner = MarkerRunner::new(vec![
            (ITERM2_RUNNING, "RUNNING\n"),
            (ITERM2_FOCUSED, "NONE\n"),
            (APPLE_TERMINAL_FOCUSED, "FOCUSED:/dev/ttys006\n"),
        ]);
        assert_eq!(focused(&runner), Ok(Some("apple-terminal:/dev/ttys006".to_string())));
        assert_eq!(runner.scripts().len(), 3, "Ghostty is not asked after a hit");
    }

    #[test]
    fn focused_is_none_when_no_supported_terminal_is_frontmost() {
        let runner = MarkerRunner::new(vec![
            (ITERM2_RUNNING, "RUNNING\n"),
            (ITERM2_FOCUSED, "NONE\n"),
            (APPLE_TERMINAL_FOCUSED, "NONE\n"),
            (GHOSTTY_VERSION, "NOT_RUNNING\n"),
        ]);
        assert_eq!(focused(&runner), Ok(None));
    }

    #[test]
    fn focused_skips_iterm2s_focused_query_when_iterm2_is_not_running() {
        // A script that uses iTerm2's terminology does not compile when
        // iTerm2 is not installed, so it is sent only after the running
        // query reports a running iTerm2.
        let runner = MarkerRunner::new(vec![
            (ITERM2_RUNNING, "NOT_RUNNING\n"),
            (APPLE_TERMINAL_FOCUSED, "FOCUSED:/dev/ttys006\n"),
        ]);
        assert_eq!(focused(&runner), Ok(Some("apple-terminal:/dev/ttys006".to_string())));
        let scripts = runner.scripts();
        assert_eq!(scripts.len(), 2);
        assert!(scripts[0].contains(ITERM2_RUNNING));
        assert!(!scripts.iter().any(|s| s.contains(ITERM2_FOCUSED)));
    }

    #[test]
    fn open_resume_window_ghostty_routes_to_the_ghostty_module() {
        let runner = MarkerRunner::new(vec![
            (GHOSTTY_VERSION, "VERSION:1.4.0\n"),
            ("new surface configuration", "OK\n"),
        ]);
        assert_eq!(
            open_resume_window(
                TerminalKind::Ghostty,
                "/Users/example/project",
                "SESSION-1",
                false,
                &runner
            ),
            Ok(())
        );
        assert!(runner.scripts()[1].contains("initial input"));
    }
}
