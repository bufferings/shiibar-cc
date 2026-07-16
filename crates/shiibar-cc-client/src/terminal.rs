//! Shared terminal plumbing and the single prefix-dispatch entry point
//! (DESIGN.md §4.3). The osascript / `ps` runners and the error/outcome
//! types are generic (not terminal-specific knowledge — design principle 2
//! keeps *terminal* knowledge in the `iterm2` / `apple_terminal` modules,
//! but the osascript process plumbing itself is common), so they live here
//! and both terminal modules build on them.
//!
//! Routing (§4.3): `iterm2:` -> the iterm2 module, `apple-terminal:` -> the
//! apple_terminal module, a `:`-less target is treated as a bare iTerm2 UUID
//! (pre-prefix / hand-typed / notifications delivered before an upgrade),
//! and a `wNtNpN:UUID` target (a hand-pasted `$ITERM_SESSION_ID`) also goes
//! to iterm2. Any other unknown prefix is "no match" (never silently routed
//! to iterm2).

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
/// is the same across both terminals.
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
/// -1743. Shared by both terminal modules' output parsers.
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
// ps runner (shared by both *_targets)
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

/// Escape `s` for embedding inside an AppleScript double-quoted string
/// literal (backslash and double-quote are the two metacharacters). Shared
/// by both terminals' `build_*_script` functions.
pub(crate) fn escape_as_string_literal(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

/// Wrap `s` in POSIX shell single quotes, safe against any byte the shell
/// treats specially (spaces, `$`, backticks, double quotes, `;`, ...):
/// single quotes make everything between them literal except a single quote
/// itself, so each embedded `'` is closed, escaped as `\'`, and reopened
/// (`'\''`). Used by both terminals' resume scripts for the `cd`/`claude
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
/// the new window (DESIGN.md §4.3). Each argument is POSIX single-quote
/// escaped independently — `cwd` may contain spaces, quotes, or `$`, and
/// `session_id` is expected to be a UUID but is escaped the same way rather
/// than trusted (§4.3: "escape it, don't validate it"). Shared by both
/// terminals' resume scripts.
pub(crate) fn build_resume_shell_command(cwd: &str, session_id: &str) -> String {
    format!(
        "cd {} && claude --resume {}",
        escape_shell_single_quoted(cwd),
        escape_shell_single_quoted(session_id)
    )
}

/// Normalize a tty for comparison: `ps` prints it bare (`ttys003`), the
/// terminals' AppleScript `tty of ...` prints it with a `/dev/` prefix
/// (`/dev/ttys003`) — verified on a real machine (iTerm2: §7-1; Terminal.app:
/// §7-7). Stripping the prefix (if present) makes the two comparable
/// regardless of source.
pub(crate) fn normalize_tty(tty: &str) -> &str {
    tty.strip_prefix("/dev/").unwrap_or(tty)
}

// ---------------------------------------------------------------------
// Prefix dispatch (§4.3)
// ---------------------------------------------------------------------

/// Which terminal a `resume` should open in (DESIGN.md §4.4 `--terminal`).
/// The app decides this from observation (§4.6/T6) and passes it through;
/// the CLI just opens.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TerminalKind {
    Iterm2,
    AppleTerminal,
}

impl TerminalKind {
    /// Parse the `--terminal` argument value (`iterm2` / `apple-terminal`,
    /// the target prefixes without the trailing `:`). Anything else is
    /// rejected by the caller.
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "iterm2" => Some(TerminalKind::Iterm2),
            "apple-terminal" => Some(TerminalKind::AppleTerminal),
            _ => None,
        }
    }
}

/// The routing outcome for a target (§4.3). The borrowed `&str` is the
/// per-module argument: the iterm2 UUID (bare or `wNtNpN:UUID`) for
/// `Iterm2`, or the tty path for `AppleTerminal`.
enum Route<'a> {
    Iterm2(&'a str),
    AppleTerminal(&'a str),
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
        Route::NoMatch => Err(TerminalError::NoMatch),
    }
}

/// `focused()` (DESIGN.md §4.3/§4.4): the frontmost supported terminal's
/// front session target (already prefixed), or `None` if neither iTerm2 nor
/// Terminal.app is frontmost. iTerm2 is asked first; each `focused` script
/// internally checks whether its app is the frontmost one, so at most one
/// returns a target.
pub fn focused(runner: &dyn AppleScriptRunner) -> TerminalResult<Option<String>> {
    if let Some(target) = crate::iterm2::focused(runner)? {
        return Ok(Some(target));
    }
    crate::apple_terminal::focused(runner)
}

/// `open_resume_window` dispatch (DESIGN.md §4.3/§4.4): open a new window in
/// the chosen terminal and run `claude --resume <session_id>` there.
pub fn open_resume_window(
    kind: TerminalKind,
    cwd: &str,
    session_id: &str,
    runner: &dyn AppleScriptRunner,
) -> TerminalResult<()> {
    match kind {
        TerminalKind::Iterm2 => crate::iterm2::open_resume_window(cwd, session_id, runner),
        TerminalKind::AppleTerminal => {
            crate::apple_terminal::open_resume_window(cwd, session_id, runner)
        }
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
            build_resume_shell_command("/Users/example/proj", "SESSION-1"),
            "cd '/Users/example/proj' && claude --resume 'SESSION-1'"
        );
    }

    // ---- TerminalKind::parse ----

    #[test]
    fn terminal_kind_parses_the_two_prefixes() {
        assert_eq!(TerminalKind::parse("iterm2"), Some(TerminalKind::Iterm2));
        assert_eq!(
            TerminalKind::parse("apple-terminal"),
            Some(TerminalKind::AppleTerminal)
        );
        assert_eq!(TerminalKind::parse("tmux"), None);
        assert_eq!(TerminalKind::parse(""), None);
    }

    // ---- route() classification (§4.3, all branches) ----

    fn route_kind(target: &str) -> &'static str {
        match route(target) {
            Route::Iterm2(_) => "iterm2",
            Route::AppleTerminal(_) => "apple-terminal",
            Route::NoMatch => "no-match",
        }
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
        // The iterm2 focus script addresses `application "iTerm2"`.
        let runner = OkRunner { stdout: "FOUND\n" };
        assert_eq!(focus("iterm2:UUID", &runner), Ok(()));
    }

    #[test]
    fn focus_apple_terminal_prefix_routes_to_the_apple_terminal_module() {
        // The apple_terminal focus script addresses Terminal.app.
        let runner = OkRunner { stdout: "FOUND\n" };
        assert_eq!(focus("apple-terminal:/dev/ttys006", &runner), Ok(()));
    }
}
