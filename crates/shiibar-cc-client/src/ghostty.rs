//! Ghostty / AppleScript knowledge lives here ONLY (design principle 2,
//! DESIGN.md §4.3 / §8.66). Everything measured about Ghostty is in §7-8;
//! this module is the code expression of it. The generic osascript / `ps`
//! plumbing, the shared error type, and the prefix dispatch live in
//! `crate::terminal`.
//!
//! The identity key for a Ghostty session is its **tty**, as with
//! Terminal.app: it is derivable from both inside (the hook environment)
//! and outside (AppleScript's `tty of terminal`), while
//! `$GHOSTTY_SURFACE_ID` does not match AppleScript's `id` (§2/§7-8). Each
//! Ghostty `terminal` (one surface in a window, a tab, or a split) has its
//! own tty, so every split is its own target. AppleScript reports the tty
//! as `/dev/ttysNNN`, the same absolute form the target carries; `ps`
//! reports it bare, so comparisons normalize with `normalize_tty`.
//!
//! **Minimum version** (§4.3/§9): only Ghostty 1.4.0 or later exposes `tty`
//! on its AppleScript `terminal`. Every operation therefore first asks the
//! running Ghostty for its `version` in a separate osascript run, and only
//! sends a script that references `tty` once that version is supported.
//! The version is compared with the same rule the hook side uses for
//! `$TERM_PROGRAM_VERSION` (§4.1: the part before the first `-` or `+`, as
//! three numbers). Keeping the `tty` reference out of the version query
//! means a script naming a term an older Ghostty does not define is never
//! sent to it.
//!
//! **Enumeration** (§4.3/§7-8): all ttys are fetched with one query
//! (`tty of every terminal`). Taking terminals one at a time fails with
//! error -1719 when a terminal closes mid-enumeration, so this module never
//! iterates over terminals; a failing query (other than a TCC denial) is an
//! incomplete scan.
//!
//! **Addressing**: every script names the app `application "Ghostty"`,
//! not its bundle id. A reference by bundle id to an app that is not
//! installed makes the whole script fail before it runs (error -1728), even
//! when the reference sits inside an `is running` guard or a `try` block, so
//! the guard would not protect it. By name, `application "Ghostty" is
//! running` is simply false when Ghostty is not installed. The version query
//! also uses no Ghostty-specific terminology (only `version`), because such
//! terms make a script fail to compile when the app is not installed; it is
//! therefore the only script sent before a running, supported Ghostty is
//! known, and it reports `NOT_RUNNING` on a Mac without Ghostty, so a
//! reconcile round there stays complete.
//!
//! Test separation is the same as the other terminal modules (§4.3): script
//! generation and output parsing are pure functions; only the osascript
//! process invocation is impure, behind the injected `AppleScriptRunner`.

use crate::terminal::{
    AppleScriptOutput, AppleScriptRunner, ProbeOutcome, PsRunner, TerminalError, TerminalResult,
    bad_output, build_resume_shell_command, escape_as_string_literal, is_permission_denied,
    normalize_tty, parse_ps_tty_output,
};
use shiibar_cc_proto::extract::{GHOSTTY_MIN_VERSION, parse_version_triple};

/// The target prefix for Ghostty sessions (§2), with the trailing `:`.
const GHOSTTY_PREFIX: &str = "ghostty:";

/// The error message `open_resume_window` returns when the running Ghostty
/// is older than the minimum version (§4.3). The installed Ghostty may
/// already be new enough while an older instance is still running, hence
/// the advice to quit and reopen it.
pub const UNSUPPORTED_VERSION_MESSAGE: &str =
    "Ghostty 1.4.0 or later is required. Quit and reopen Ghostty after updating it.";

// ---------------------------------------------------------------------
// Pure: version
// ---------------------------------------------------------------------

/// The running Ghostty, as far as this module's operations are concerned.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RunningGhostty {
    /// Ghostty isn't running (nothing was launched to find out).
    NotRunning,
    /// Running, and at least the minimum version: `tty` may be referenced.
    Supported,
    /// Running, but older than the minimum version or with a version that
    /// doesn't parse: `tty` must not be referenced (§4.3). An unparsable
    /// version is treated like an old one, as the hook side does (§4.1).
    Unsupported,
}

/// Whether a Ghostty version string is at least the minimum version
/// (§4.3/§9), compared by the same rule as the hook side (§4.1).
pub fn is_supported_version(version: &str) -> bool {
    parse_version_triple(version).is_some_and(|v| v >= GHOSTTY_MIN_VERSION)
}

// ---------------------------------------------------------------------
// Pure: AppleScript generation
// ---------------------------------------------------------------------

/// AppleScript that reports the running Ghostty's `version` (the
/// application's `version` property, §4.3/§7-8). Every operation sends this
/// first. Guarded on `application "Ghostty" is running`, with the `tell`
/// inside the guard, so it never launches Ghostty. Prints
/// `VERSION:<version>` or `NOT_RUNNING`.
///
/// It must also work on a Mac where Ghostty is not installed: it addresses
/// the app by name (a reference by bundle id to an app that is not installed
/// makes the whole script fail before it runs, so the guard would not
/// protect it) and uses no Ghostty-specific terminology (which would fail
/// to compile without the app's scripting definition). It then prints
/// `NOT_RUNNING`.
///
/// This query changes no state, so it is also the doctor's TCC probe
/// (§4.3 `probe()`).
pub fn build_version_script() -> String {
    r#"if application "Ghostty" is running then
    tell application "Ghostty" to return "VERSION:" & (version as text)
else
    return "NOT_RUNNING"
end if
"#
    .to_string()
}

/// AppleScript that focuses the Ghostty terminal whose `tty` equals `tty`
/// (§4.3/§7-8): the first of `every terminal whose tty is "<tty>"` gets the
/// `focus` command, which alone brings its window to the front and selects
/// its tab and split. `activate window` and `select tab` are not used
/// (§4.3), and neither is `activate`. Zero matches moves nothing.
///
/// Guarded on `is running` with the `tell` inside the guard, so `focus`
/// never launches Ghostty. Prints `FOUND` or `NOTFOUND`.
pub fn build_focus_script(tty: &str) -> String {
    let tty = escape_as_string_literal(tty);
    format!(
        r#"if application "Ghostty" is running then
    tell application "Ghostty"
        set matchingTerminals to (every terminal whose tty is "{tty}")
        if (count of matchingTerminals) > 0 then
            focus (item 1 of matchingTerminals)
            return "FOUND"
        end if
    end tell
end if
return "NOTFOUND"
"#
    )
}

/// AppleScript that reports the tty of the focused terminal of the selected
/// tab of Ghostty's front window, if Ghostty is the frontmost application
/// (§4.3). The frontmost check reads the application's own `frontmost`
/// property (listed on `application` in the scripting definition of the
/// Ghostty 1.4.0 bundle, read with `sdef`). Prints `FOCUSED:<tty>` or
/// `NONE`.
pub fn build_focused_script() -> String {
    r#"if application "Ghostty" is running then
    tell application "Ghostty"
        if frontmost then
            return "FOCUSED:" & (tty of focused terminal of selected tab of front window)
        end if
    end tell
end if
return "NONE"
"#
    .to_string()
}

/// AppleScript that opens a *new* Ghostty window and runs
/// `cd <cwd> && claude --resume <session_id>` (plus `--fork-session` when
/// forking) in its interactive shell (§4.3). Unlike the other scripts this
/// does NOT guard on `is running`: a bare `tell` launches Ghostty, which is
/// wanted for a verb that opens a new window (§4.3). It addresses the app by
/// name like the other scripts; when Ghostty is not installed the script
/// fails and the failure is returned as an error.
///
/// Launch method (§4.3/§7-8): a record from `new surface configuration`
/// gets the command plus a trailing newline as its `initial input`, then
/// `new window with configuration` opens the window. The trailing newline
/// makes the interactive shell run the line, so `claude` resolves through
/// the user's rc-file PATH (the reason the iterm2 module types its command
/// too). `input text` is not used (it pastes, so the newline doesn't run
/// the line), and neither is the configuration's direct command property
/// (it bypasses the login shell's PATH setup).
///
/// Escaping is two-stage (§4.3): `build_resume_shell_command` single-quotes
/// `cwd` and `session_id` for the shell, then the whole line is escaped as
/// an AppleScript string literal. `activate` comes first, as in the other
/// modules' resume scripts, so the new window opens in front. Prints `OK`.
pub fn build_resume_script(cwd: &str, session_id: &str, fork: bool) -> String {
    let shell_command = build_resume_shell_command(cwd, session_id, fork);
    let escaped_command = escape_as_string_literal(&shell_command);
    format!(
        r#"tell application "Ghostty"
    activate
    set surfaceConfiguration to new surface configuration
    set initial input of surfaceConfiguration to "{escaped_command}" & linefeed
    new window with configuration surfaceConfiguration
end tell
return "OK"
"#
    )
}

/// AppleScript that fetches every Ghostty terminal's tty in ONE query
/// (`tty of every terminal`, §4.3/§7-8) — no per-terminal iteration, which
/// fails with -1719 when a terminal closes mid-enumeration. The list is
/// joined with linefeeds after the query returns. A query error is not
/// caught, so osascript fails and the caller treats the scan as incomplete
/// (or as a TCC denial, which stays distinguishable in stderr).
///
/// Guarded on `is running` with the `tell` inside the guard. Prints a
/// `TTYS` line followed by one tty per line, or `NOT_RUNNING` (Ghostty quit
/// after the version query).
pub fn build_ghostty_targets_script() -> String {
    r#"if application "Ghostty" is running then
    tell application "Ghostty"
        set allTtys to tty of every terminal
    end tell
    set AppleScript's text item delimiters to linefeed
    set outputText to allTtys as text
    set AppleScript's text item delimiters to ""
    return "TTYS" & linefeed & outputText
else
    return "NOT_RUNNING"
end if
"#
    .to_string()
}

// ---------------------------------------------------------------------
// Pure: osascript output parsing
// ---------------------------------------------------------------------

/// Map a failed osascript run: a TCC denial is `PermissionDenied`, anything
/// else is `Other` with osascript's stderr. `None` when the run succeeded.
fn failure(output: &AppleScriptOutput) -> Option<TerminalError> {
    if is_permission_denied(output) {
        return Some(TerminalError::PermissionDenied);
    }
    if !output.success {
        return Some(TerminalError::Other(output.stderr.trim().to_string()));
    }
    None
}

pub fn parse_version_output(output: &AppleScriptOutput) -> TerminalResult<RunningGhostty> {
    if let Some(e) = failure(output) {
        return Err(e);
    }
    let stdout = output.stdout.trim();
    if stdout == "NOT_RUNNING" {
        return Ok(RunningGhostty::NotRunning);
    }
    let Some(version) = stdout.strip_prefix("VERSION:") else {
        return Err(bad_output(stdout));
    };
    Ok(if is_supported_version(version) {
        RunningGhostty::Supported
    } else {
        RunningGhostty::Unsupported
    })
}

pub fn parse_focus_output(output: &AppleScriptOutput) -> TerminalResult<()> {
    if let Some(e) = failure(output) {
        return Err(e);
    }
    match output.stdout.trim() {
        "FOUND" => Ok(()),
        "NOTFOUND" => Err(TerminalError::NoMatch),
        other => Err(bad_output(other)),
    }
}

pub fn parse_focused_output(output: &AppleScriptOutput) -> TerminalResult<Option<String>> {
    if let Some(e) = failure(output) {
        return Err(e);
    }
    let stdout = output.stdout.trim();
    if stdout == "NONE" {
        return Ok(None);
    }
    let Some(tty) = stdout.strip_prefix("FOCUSED:") else {
        return Err(bad_output(stdout));
    };
    if tty.is_empty() {
        return Err(bad_output(stdout));
    }
    Ok(Some(format!("{GHOSTTY_PREFIX}{}", dev_tty(tty))))
}

/// Parse `build_resume_script`'s output. There's no "no match" outcome:
/// `open_resume_window` always opens a new window.
pub fn parse_resume_output(output: &AppleScriptOutput) -> TerminalResult<()> {
    if let Some(e) = failure(output) {
        return Err(e);
    }
    match output.stdout.trim() {
        "OK" => Ok(()),
        other => Err(bad_output(other)),
    }
}

/// Parse `build_ghostty_targets_script`'s output into the list of terminal
/// ttys. `NOT_RUNNING` is an empty list. Any osascript failure is an error
/// (`PermissionDenied` for a TCC denial); the caller turns a non-TCC error
/// into an incomplete scan.
pub fn parse_ghostty_targets_output(output: &AppleScriptOutput) -> TerminalResult<Vec<String>> {
    if let Some(e) = failure(output) {
        return Err(e);
    }
    let mut lines = output.stdout.lines();
    match lines.next().map(str::trim) {
        Some("NOT_RUNNING") => Ok(Vec::new()),
        Some("TTYS") => Ok(lines
            .map(str::trim)
            .filter(|line| !line.is_empty())
            .map(str::to_string)
            .collect()),
        _ => Err(bad_output(output.stdout.trim())),
    }
}

/// The `/dev/`-prefixed form of a tty, which is what a target carries (§2).
fn dev_tty(tty: &str) -> String {
    format!("/dev/{}", normalize_tty(tty))
}

// ---------------------------------------------------------------------
// Impure: wire pure generation/parsing to a runner
// ---------------------------------------------------------------------

fn run(runner: &dyn AppleScriptRunner, script: &str) -> TerminalResult<AppleScriptOutput> {
    runner
        .run(script)
        .map_err(|e| TerminalError::Other(e.to_string()))
}

/// Ask the running Ghostty for its version (the first step of every
/// operation, §4.3).
fn running_ghostty(runner: &dyn AppleScriptRunner) -> TerminalResult<RunningGhostty> {
    parse_version_output(&run(runner, &build_version_script())?)
}

/// `focus(target)` (§4.3): focus the Ghostty terminal whose tty is `tty`
/// (the target with `ghostty:` already stripped by the dispatch). `NoMatch`
/// covers "no such terminal", "Ghostty isn't running", and "the running
/// Ghostty is older than the minimum version".
pub fn focus(tty: &str, runner: &dyn AppleScriptRunner) -> TerminalResult<()> {
    if tty.is_empty() {
        return Err(TerminalError::NoMatch);
    }
    match running_ghostty(runner)? {
        RunningGhostty::Supported => {
            parse_focus_output(&run(runner, &build_focus_script(tty))?)
        }
        RunningGhostty::NotRunning | RunningGhostty::Unsupported => Err(TerminalError::NoMatch),
    }
}

/// `focused()` (§4.3): the target (`ghostty:<tty>`) of the focused terminal
/// in Ghostty's front window, if Ghostty is the frontmost application;
/// `Ok(None)` otherwise, including when Ghostty isn't running or is older
/// than the minimum version.
pub fn focused(runner: &dyn AppleScriptRunner) -> TerminalResult<Option<String>> {
    match running_ghostty(runner)? {
        RunningGhostty::Supported => parse_focused_output(&run(runner, &build_focused_script())?),
        RunningGhostty::NotRunning | RunningGhostty::Unsupported => Ok(None),
    }
}

/// Harmless Ghostty probe for `shiibar-cc doctor`'s TCC permission check
/// (§4.3): one `version` query to a running Ghostty, nothing sent when it
/// isn't running.
pub fn probe(runner: &dyn AppleScriptRunner) -> TerminalResult<ProbeOutcome> {
    match running_ghostty(runner)? {
        RunningGhostty::NotRunning => Ok(ProbeOutcome::NotRunning),
        RunningGhostty::Supported | RunningGhostty::Unsupported => Ok(ProbeOutcome::Granted),
    }
}

/// `open_resume_window(cwd, session_id, fork)` (§4.3): open a new Ghostty
/// window and run `claude --resume <session_id>` there, `cd`-ed into `cwd`
/// (with `--fork-session` appended when `fork` is true, §4.4). When a
/// running Ghostty is older than the minimum version, nothing is opened and
/// the error carries `UNSUPPORTED_VERSION_MESSAGE` (§4.3). When Ghostty
/// isn't running, the resume script launches it. `cwd` and `session_id` are
/// escaped, not validated — `shiibar-cc resume` checks `cwd` first (§4.4).
pub fn open_resume_window(
    cwd: &str,
    session_id: &str,
    fork: bool,
    runner: &dyn AppleScriptRunner,
) -> TerminalResult<()> {
    if running_ghostty(runner)? == RunningGhostty::Unsupported {
        return Err(TerminalError::Other(UNSUPPORTED_VERSION_MESSAGE.to_string()));
    }
    parse_resume_output(&run(runner, &build_resume_script(cwd, session_id, fork))?)
}

/// One pid -> target(`ghostty:<tty>`) mapping, plus whether the underlying
/// scan (both `ps` and the Ghostty query) was complete enough to trust for
/// pruning (§3.5). Mirrors `apple_terminal::AppleTerminalTargets`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GhosttyTargets {
    pub targets: std::collections::HashMap<u32, String>,
    pub complete: bool,
}

/// `ghostty_targets(pids)` (§3.5/§4.3): resolve `claude agents`' pids to
/// targets by matching `ps`'s pid -> tty against the ttys of all Ghostty
/// terminals. A pid with no matching terminal is absent from `targets` (not
/// a scan failure).
///
/// - Ghostty not running, or older than the minimum version: empty and
///   complete, without sending a script that references `tty` (§4.3; such
///   sessions are `process:` targets on both the hook and reconcile sides).
/// - A TCC denial of either query is `Err(PermissionDenied)`.
/// - Any other failure of either query (including -1719, §7-8) or of `ps`
///   is `Ok` with `complete: false` and whatever could still be resolved
///   (§3.5: an incomplete round does not prune).
pub fn ghostty_targets(
    pids: &[u32],
    ps_runner: &dyn PsRunner,
    script_runner: &dyn AppleScriptRunner,
) -> TerminalResult<GhosttyTargets> {
    let empty = |complete| GhosttyTargets {
        targets: std::collections::HashMap::new(),
        complete,
    };
    if pids.is_empty() {
        return Ok(empty(true));
    }

    match running_ghostty(script_runner) {
        Ok(RunningGhostty::Supported) => {}
        Ok(RunningGhostty::NotRunning | RunningGhostty::Unsupported) => return Ok(empty(true)),
        Err(TerminalError::PermissionDenied) => return Err(TerminalError::PermissionDenied),
        Err(_) => return Ok(empty(false)),
    }

    let (pid_tty, ps_ok) = match ps_runner.run(pids) {
        Ok(output) if output.success => (parse_ps_tty_output(&output.stdout), true),
        Ok(output) => (parse_ps_tty_output(&output.stdout), false),
        Err(_) => (std::collections::HashMap::new(), false),
    };

    let (terminal_ttys, scan_complete) = match run(script_runner, &build_ghostty_targets_script())
        .and_then(|output| parse_ghostty_targets_output(&output))
    {
        Ok(ttys) => (ttys, true),
        Err(TerminalError::PermissionDenied) => return Err(TerminalError::PermissionDenied),
        Err(_) => (Vec::new(), false),
    };

    let mut targets = std::collections::HashMap::new();
    for (&pid, tty) in &pid_tty {
        if let Some(terminal_tty) = terminal_ttys
            .iter()
            .find(|terminal_tty| normalize_tty(terminal_tty) == normalize_tty(tty))
        {
            targets.insert(pid, format!("{GHOSTTY_PREFIX}{}", dev_tty(terminal_tty)));
        }
    }

    Ok(GhosttyTargets {
        targets,
        complete: ps_ok && scan_complete,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::terminal::PsOutput;
    use std::cell::RefCell;

    fn out(success: bool, stdout: &str, stderr: &str) -> AppleScriptOutput {
        AppleScriptOutput {
            success,
            stdout: stdout.to_string(),
            stderr: stderr.to_string(),
        }
    }

    const TCC_DENIED: &str =
        "execution error: Not authorized to send Apple events to Ghostty. (-1743)";
    const INVALID_INDEX: &str = "execution error: Ghostty got an error: Invalid index. (-1719)";

    /// Whether a script references the `tty` term. The app name itself
    /// contains the letters `tty`, so it is removed before searching.
    fn references_tty(script: &str) -> bool {
        script.replace("Ghostty", "").contains("tty")
    }

    /// Every script this module can send.
    fn all_scripts() -> Vec<String> {
        vec![
            build_version_script(),
            build_focus_script("/dev/ttys005"),
            build_focused_script(),
            build_ghostty_targets_script(),
            build_resume_script("/Users/example/project", "SESSION-1", false),
        ]
    }

    // ---- version ----

    #[test]
    fn is_supported_version_reads_release_and_non_release_versions() {
        // §4.1/§4.3: only the part before the first `-` or `+` counts.
        assert!(is_supported_version("1.4.0"));
        assert!(is_supported_version("1.4.0-main+abc1234"));
        assert!(is_supported_version("1.4.0-dev+0000000"));
        assert!(is_supported_version("1.10.0"));
        assert!(!is_supported_version("1.3.1"));
        assert!(!is_supported_version("1.3.1-main+abc1234"));
        assert!(!is_supported_version("1.4"));
        assert!(!is_supported_version(""));
    }

    #[test]
    fn version_script_is_guarded_and_never_references_tty() {
        let script = build_version_script();
        let guard = script
            .find(r#"application "Ghostty" is running"#)
            .unwrap();
        let tell = script.find(r#"tell application "Ghostty""#).unwrap();
        assert!(guard < tell, "must check `is running` before telling the app");
        assert!(script.contains("version"));
        assert!(script.contains("NOT_RUNNING"));
        assert!(!references_tty(&script));
        assert!(!script.contains("activate"));
    }

    #[test]
    fn version_script_addresses_ghostty_by_name_so_it_runs_when_ghostty_is_not_installed() {
        // A reference by bundle id to an app that is not installed makes the
        // whole script fail before it runs, even inside the guard.
        let script = build_version_script();
        assert!(!script.contains("application id"));
        let guard = script.find(r#"if application "Ghostty" is running then"#).unwrap();
        let tell = script.find(r#"tell application "Ghostty""#).unwrap();
        assert!(guard < tell, "the guard must come before the tell");
        assert_eq!(script.matches("application").count(), 2, "only the guard and the tell name the app");
        // Ghostty-specific terminology fails to compile when the app is not
        // installed; only the generic `version` property may be used.
        assert!(!references_tty(&script));
        let without_app_name = script.replace(r#"application "Ghostty""#, "");
        for term in ["terminal", "focus", "frontmost", "window", "tab", "surface", "configuration"] {
            assert!(
                !without_app_name.contains(term),
                "Ghostty-specific term `{term}` in the version script"
            );
        }
    }

    #[test]
    fn no_script_addresses_ghostty_by_bundle_id() {
        for script in all_scripts() {
            assert!(!script.contains("application id"), "{script}");
            assert!(!script.contains("com.mitchellh.ghostty"), "{script}");
            assert!(script.contains(r#"tell application "Ghostty""#), "{script}");
        }
    }

    #[test]
    fn parse_version_output_classifies_the_running_ghostty() {
        let cases = [
            ("NOT_RUNNING\n", RunningGhostty::NotRunning),
            ("VERSION:1.4.0\n", RunningGhostty::Supported),
            ("VERSION:1.4.0-main+abc1234\n", RunningGhostty::Supported),
            ("VERSION:1.3.1\n", RunningGhostty::Unsupported),
            ("VERSION:not-a-version\n", RunningGhostty::Unsupported),
        ];
        for (stdout, expected) in cases {
            assert_eq!(parse_version_output(&out(true, stdout, "")), Ok(expected), "{stdout:?}");
        }
    }

    #[test]
    fn parse_version_output_distinguishes_tcc_denial_from_other_errors() {
        assert_eq!(
            parse_version_output(&out(false, "", TCC_DENIED)),
            Err(TerminalError::PermissionDenied)
        );
        assert!(matches!(
            parse_version_output(&out(false, "", INVALID_INDEX)),
            Err(TerminalError::Other(_))
        ));
        assert!(matches!(
            parse_version_output(&out(true, "garbage\n", "")),
            Err(TerminalError::Other(_))
        ));
    }

    // ---- script generation ----

    #[test]
    fn focus_script_uses_whose_tty_and_focus_without_activate_window_or_select_tab() {
        let script = build_focus_script("/dev/ttys005");
        let guard = script
            .find(r#"application "Ghostty" is running"#)
            .unwrap();
        let tell = script.find(r#"tell application "Ghostty""#).unwrap();
        assert!(guard < tell, "must check `is running` before telling the app");
        assert!(script.contains(r#"every terminal whose tty is "/dev/ttys005""#));
        assert!(script.contains("focus (item 1 of matchingTerminals)"));
        assert!(!script.contains("activate window"));
        assert!(!script.contains("select tab"));
        assert!(!script.contains("activate"), "activate is not run before a real-device check (§4.3)");
        assert!(script.contains("\"FOUND\""));
        assert!(script.contains("\"NOTFOUND\""));
    }

    #[test]
    fn focus_script_focuses_only_inside_the_match_branch() {
        // Zero matches must move nothing (§4.3).
        let script = build_focus_script("/dev/ttys005");
        let count_check = script.find("(count of matchingTerminals) > 0").unwrap();
        let focus = script.find("focus (item 1").unwrap();
        let end_if = script.find("end if").unwrap();
        assert!(count_check < focus && focus < end_if);
    }

    #[test]
    fn focus_script_escapes_quotes_and_backslashes_in_tty() {
        let script = build_focus_script(r#"weird"tty\"#);
        assert!(script.contains(r#""weird\"tty\\""#));
    }

    #[test]
    fn focused_script_reads_the_focused_terminal_of_the_front_window_when_frontmost() {
        let script = build_focused_script();
        let guard = script
            .find(r#"application "Ghostty" is running"#)
            .unwrap();
        let tell = script.find(r#"tell application "Ghostty""#).unwrap();
        assert!(guard < tell);
        let frontmost = script.find("if frontmost then").unwrap();
        let read = script
            .find("tty of focused terminal of selected tab of front window")
            .unwrap();
        assert!(frontmost < read, "must check frontmost before reading the tty");
        assert!(script.contains("FOCUSED:"));
        assert!(script.contains("\"NONE\""));
        assert!(!script.contains("activate"));
    }

    #[test]
    fn targets_script_fetches_all_ttys_in_one_query_without_iterating_terminals() {
        let script = build_ghostty_targets_script();
        let guard = script
            .find(r#"application "Ghostty" is running"#)
            .unwrap();
        let tell = script.find(r#"tell application "Ghostty""#).unwrap();
        assert!(guard < tell);
        assert!(script.contains("tty of every terminal"));
        // §4.3/§7-8: no per-terminal enumeration (it fails with -1719 when
        // a terminal closes mid-enumeration), and no swallowed errors.
        assert!(!script.contains("repeat"));
        assert!(!script.contains("try"));
        assert!(!script.contains("activate"));
        assert!(script.contains("\"TTYS\""));
        assert!(script.contains("\"NOT_RUNNING\""));
    }

    #[test]
    fn resume_script_uses_initial_input_with_a_trailing_newline_and_launches_ghostty() {
        let script = build_resume_script("/Users/example/project", "SESSION-1", false);
        // Opening a window launches Ghostty when needed: no is-running guard.
        assert!(!script.contains("is running"));
        assert!(script.contains(r#"tell application "Ghostty""#));
        let make = script.find("set surfaceConfiguration to new surface configuration").unwrap();
        let input = script
            .find(
                r#"set initial input of surfaceConfiguration to "cd '/Users/example/project' && claude --resume 'SESSION-1'" & linefeed"#,
            )
            .unwrap();
        let open = script
            .find("new window with configuration surfaceConfiguration")
            .unwrap();
        assert!(make < input && input < open);
        assert!(!script.contains("input text"));
        assert!(!script.contains("send key"));
        assert!(!script.contains("command"));
        assert!(script.contains("\"OK\""));
    }

    #[test]
    fn resume_script_double_escapes_a_cwd_and_session_id_with_spaces_and_quotes() {
        // Shell single-quoting first (`'` -> `'\''`), then AppleScript
        // string-literal escaping (`\` -> `\\`, `"` -> `\"`) on top (§4.3).
        let script = build_resume_script(r#"/Users/example/My "great" O'Brien dir"#, "weird'id \"x\"", false);
        assert!(script.contains(
            r#""cd '/Users/example/My \"great\" O'\\''Brien dir' && claude --resume 'weird'\\''id \"x\"'" & linefeed"#
        ));
    }

    #[test]
    fn resume_script_with_fork_appends_fork_session_at_the_end_of_the_command() {
        let script = build_resume_script("/Users/example/project", "SESSION-1", true);
        assert!(script.contains(
            r#""cd '/Users/example/project' && claude --resume 'SESSION-1' --fork-session" & linefeed"#
        ));
        let plain = build_resume_script("/Users/example/project", "SESSION-1", false);
        assert!(!plain.contains("--fork-session"));
    }

    // ---- output parsing ----

    #[test]
    fn parse_focus_output_found_notfound_and_errors() {
        assert_eq!(parse_focus_output(&out(true, "FOUND\n", "")), Ok(()));
        assert_eq!(parse_focus_output(&out(true, "NOTFOUND\n", "")), Err(TerminalError::NoMatch));
        assert_eq!(
            parse_focus_output(&out(false, "", TCC_DENIED)),
            Err(TerminalError::PermissionDenied)
        );
        assert_eq!(
            parse_focus_output(&out(false, "", "some other osascript error")),
            Err(TerminalError::Other("some other osascript error".to_string()))
        );
    }

    #[test]
    fn parse_focused_output_returns_the_prefixed_tty_as_target() {
        assert_eq!(parse_focused_output(&out(true, "NONE\n", "")), Ok(None));
        assert_eq!(
            parse_focused_output(&out(true, "FOCUSED:/dev/ttys005\n", "")),
            Ok(Some("ghostty:/dev/ttys005".to_string()))
        );
        assert_eq!(
            parse_focused_output(&out(false, "", TCC_DENIED)),
            Err(TerminalError::PermissionDenied)
        );
        assert!(matches!(
            parse_focused_output(&out(true, "FOCUSED:\n", "")),
            Err(TerminalError::Other(_))
        ));
    }

    #[test]
    fn parse_resume_output_ok_and_tcc_denial() {
        assert_eq!(parse_resume_output(&out(true, "OK\n", "")), Ok(()));
        assert_eq!(
            parse_resume_output(&out(false, "", TCC_DENIED)),
            Err(TerminalError::PermissionDenied)
        );
    }

    #[test]
    fn parse_targets_output_lists_every_terminal_tty_across_windows_tabs_and_splits() {
        // Each window, tab, and split is its own terminal with its own tty (§7-8).
        let output = out(true, "TTYS\n/dev/ttys001\n/dev/ttys002\n/dev/ttys003\n/dev/ttys004\n", "");
        assert_eq!(
            parse_ghostty_targets_output(&output),
            Ok(vec![
                "/dev/ttys001".to_string(),
                "/dev/ttys002".to_string(),
                "/dev/ttys003".to_string(),
                "/dev/ttys004".to_string(),
            ])
        );
    }

    #[test]
    fn parse_targets_output_with_no_terminals_or_not_running_is_empty() {
        assert_eq!(parse_ghostty_targets_output(&out(true, "TTYS\n", "")), Ok(Vec::new()));
        assert_eq!(parse_ghostty_targets_output(&out(true, "NOT_RUNNING\n", "")), Ok(Vec::new()));
    }

    #[test]
    fn parse_targets_output_distinguishes_tcc_denial_from_a_failed_query() {
        assert_eq!(
            parse_ghostty_targets_output(&out(false, "", TCC_DENIED)),
            Err(TerminalError::PermissionDenied)
        );
        assert!(matches!(
            parse_ghostty_targets_output(&out(false, "", INVALID_INDEX)),
            Err(TerminalError::Other(_))
        ));
        assert!(matches!(
            parse_ghostty_targets_output(&out(true, "garbage\n", "")),
            Err(TerminalError::Other(_))
        ));
    }

    // ---- end-to-end wiring with fake runners ----

    /// Answers scripts in order and records every script it was sent.
    struct ScriptedRunner {
        outputs: RefCell<Vec<AppleScriptOutput>>,
        scripts: RefCell<Vec<String>>,
    }

    impl ScriptedRunner {
        fn new(outputs: Vec<AppleScriptOutput>) -> Self {
            ScriptedRunner {
                outputs: RefCell::new(outputs),
                scripts: RefCell::new(Vec::new()),
            }
        }

        fn scripts(&self) -> Vec<String> {
            self.scripts.borrow().clone()
        }
    }

    impl AppleScriptRunner for ScriptedRunner {
        fn run(&self, script: &str) -> std::io::Result<AppleScriptOutput> {
            self.scripts.borrow_mut().push(script.to_string());
            let mut outputs = self.outputs.borrow_mut();
            assert!(!outputs.is_empty(), "unexpected extra osascript run: {script}");
            Ok(outputs.remove(0))
        }
    }

    struct PanicRunner;
    impl AppleScriptRunner for PanicRunner {
        fn run(&self, script: &str) -> std::io::Result<AppleScriptOutput> {
            panic!("osascript must not run: {script}");
        }
    }

    struct FakePs {
        output: PsOutput,
    }
    impl PsRunner for FakePs {
        fn run(&self, _pids: &[u32]) -> std::io::Result<PsOutput> {
            Ok(self.output.clone())
        }
    }

    struct PanicPs;
    impl PsRunner for PanicPs {
        fn run(&self, _pids: &[u32]) -> std::io::Result<PsOutput> {
            panic!("ps must not run");
        }
    }

    fn ps(stdout: &str) -> FakePs {
        FakePs {
            output: PsOutput {
                success: true,
                stdout: stdout.to_string(),
            },
        }
    }

    fn version(v: &str) -> AppleScriptOutput {
        out(true, &format!("VERSION:{v}\n"), "")
    }

    fn not_running() -> AppleScriptOutput {
        out(true, "NOT_RUNNING\n", "")
    }

    fn assert_no_tty_reference(runner: &ScriptedRunner) {
        for script in runner.scripts() {
            assert!(!references_tty(&script), "an old Ghostty must not be asked for tty: {script}");
        }
    }

    #[test]
    fn focus_queries_the_version_first_then_focuses() {
        let runner = ScriptedRunner::new(vec![version("1.4.0"), out(true, "FOUND\n", "")]);
        assert_eq!(focus("/dev/ttys005", &runner), Ok(()));
        let scripts = runner.scripts();
        assert_eq!(scripts.len(), 2);
        assert_eq!(scripts[0], build_version_script());
        assert_eq!(scripts[1], build_focus_script("/dev/ttys005"));
    }

    #[test]
    fn focus_with_no_matching_terminal_is_no_match() {
        let runner = ScriptedRunner::new(vec![version("1.4.0"), out(true, "NOTFOUND\n", "")]);
        assert_eq!(focus("/dev/ttys099", &runner), Err(TerminalError::NoMatch));
    }

    #[test]
    fn focus_when_ghostty_is_not_running_is_no_match_after_one_guarded_query() {
        let runner = ScriptedRunner::new(vec![not_running()]);
        assert_eq!(focus("/dev/ttys005", &runner), Err(TerminalError::NoMatch));
        assert_eq!(runner.scripts().len(), 1);
    }

    #[test]
    fn focus_on_a_ghostty_older_than_the_minimum_is_no_match_without_referencing_tty() {
        let runner = ScriptedRunner::new(vec![version("1.3.1")]);
        assert_eq!(focus("/dev/ttys005", &runner), Err(TerminalError::NoMatch));
        assert_eq!(runner.scripts().len(), 1);
        assert_no_tty_reference(&runner);
    }

    #[test]
    fn focus_surfaces_a_tcc_denial() {
        let runner = ScriptedRunner::new(vec![out(false, "", TCC_DENIED)]);
        assert_eq!(focus("/dev/ttys005", &runner), Err(TerminalError::PermissionDenied));
    }

    #[test]
    fn focus_empty_tty_never_runs_osascript() {
        assert_eq!(focus("", &PanicRunner), Err(TerminalError::NoMatch));
    }

    #[test]
    fn focused_returns_the_prefixed_target_when_ghostty_is_frontmost() {
        let runner = ScriptedRunner::new(vec![version("1.4.0"), out(true, "FOCUSED:/dev/ttys005\n", "")]);
        assert_eq!(focused(&runner), Ok(Some("ghostty:/dev/ttys005".to_string())));
        assert_eq!(runner.scripts()[1], build_focused_script());
    }

    #[test]
    fn focused_is_none_when_not_running_or_older_than_the_minimum() {
        let runner = ScriptedRunner::new(vec![not_running()]);
        assert_eq!(focused(&runner), Ok(None));
        let runner = ScriptedRunner::new(vec![version("1.3.1")]);
        assert_eq!(focused(&runner), Ok(None));
        assert_no_tty_reference(&runner);
    }

    #[test]
    fn probe_sends_only_the_version_query() {
        let runner = ScriptedRunner::new(vec![not_running()]);
        assert_eq!(probe(&runner), Ok(ProbeOutcome::NotRunning));
        let runner = ScriptedRunner::new(vec![version("1.4.0")]);
        assert_eq!(probe(&runner), Ok(ProbeOutcome::Granted));
        assert_eq!(runner.scripts(), vec![build_version_script()]);
        let runner = ScriptedRunner::new(vec![version("1.3.1")]);
        assert_eq!(probe(&runner), Ok(ProbeOutcome::Granted));
        let runner = ScriptedRunner::new(vec![out(false, "", TCC_DENIED)]);
        assert_eq!(probe(&runner), Err(TerminalError::PermissionDenied));
    }

    #[test]
    fn open_resume_window_opens_a_window_on_a_supported_or_not_running_ghostty() {
        for first in [version("1.4.0"), not_running()] {
            let runner = ScriptedRunner::new(vec![first, out(true, "OK\n", "")]);
            assert_eq!(
                open_resume_window("/Users/example/project", "SESSION-1", false, &runner),
                Ok(())
            );
            assert_eq!(
                runner.scripts()[1],
                build_resume_script("/Users/example/project", "SESSION-1", false)
            );
        }
    }

    #[test]
    fn open_resume_window_on_a_ghostty_older_than_the_minimum_is_the_dedicated_error() {
        let runner = ScriptedRunner::new(vec![version("1.3.1")]);
        assert_eq!(
            open_resume_window("/Users/example/project", "SESSION-1", false, &runner),
            Err(TerminalError::Other(UNSUPPORTED_VERSION_MESSAGE.to_string()))
        );
        assert_eq!(runner.scripts().len(), 1, "no window is opened");
        assert_eq!(
            UNSUPPORTED_VERSION_MESSAGE,
            "Ghostty 1.4.0 or later is required. Quit and reopen Ghostty after updating it."
        );
    }

    #[test]
    fn open_resume_window_surfaces_a_tcc_denial() {
        let runner = ScriptedRunner::new(vec![version("1.4.0"), out(false, "", TCC_DENIED)]);
        assert_eq!(
            open_resume_window("/Users/example/project", "SESSION-1", true, &runner),
            Err(TerminalError::PermissionDenied)
        );
    }

    #[test]
    fn ghostty_targets_matches_pids_to_prefixed_targets_across_windows_tabs_and_splits() {
        // `ps` reports ttys bare; AppleScript reports them with /dev/.
        let runner = ScriptedRunner::new(vec![
            version("1.4.0"),
            out(true, "TTYS\n/dev/ttys001\n/dev/ttys002\n/dev/ttys003\n", ""),
        ]);
        let result =
            ghostty_targets(&[111, 222, 333], &ps("111 ttys001\n222 ttys003\n333 ttys009\n"), &runner)
                .unwrap();
        assert_eq!(result.targets.len(), 2);
        assert_eq!(result.targets.get(&111).map(String::as_str), Some("ghostty:/dev/ttys001"));
        assert_eq!(result.targets.get(&222).map(String::as_str), Some("ghostty:/dev/ttys003"));
        assert!(result.complete, "a pid outside Ghostty isn't a scan failure");
        assert_eq!(runner.scripts()[1], build_ghostty_targets_script());
    }

    #[test]
    fn ghostty_targets_when_not_running_is_empty_and_complete() {
        let runner = ScriptedRunner::new(vec![not_running()]);
        let result = ghostty_targets(&[111], &PanicPs, &runner).unwrap();
        assert!(result.targets.is_empty());
        assert!(result.complete);
    }

    #[test]
    fn ghostty_targets_on_a_ghostty_older_than_the_minimum_is_empty_and_complete_without_referencing_tty() {
        let runner = ScriptedRunner::new(vec![version("1.3.1")]);
        let result = ghostty_targets(&[111], &PanicPs, &runner).unwrap();
        assert!(result.targets.is_empty());
        assert!(result.complete);
        assert_no_tty_reference(&runner);
    }

    #[test]
    fn ghostty_targets_is_incomplete_when_the_query_fails_with_invalid_index() {
        let runner = ScriptedRunner::new(vec![version("1.4.0"), out(false, "", INVALID_INDEX)]);
        let result = ghostty_targets(&[111], &ps("111 ttys001\n"), &runner).unwrap();
        assert!(result.targets.is_empty());
        assert!(!result.complete);
    }

    #[test]
    fn ghostty_targets_is_incomplete_when_the_version_query_fails() {
        let runner = ScriptedRunner::new(vec![out(false, "", "some other osascript error")]);
        let result = ghostty_targets(&[111], &PanicPs, &runner).unwrap();
        assert!(result.targets.is_empty());
        assert!(!result.complete);
    }

    #[test]
    fn ghostty_targets_is_incomplete_when_ps_fails() {
        let runner = ScriptedRunner::new(vec![version("1.4.0"), out(true, "TTYS\n/dev/ttys001\n", "")]);
        let failing_ps = FakePs {
            output: PsOutput {
                success: false,
                stdout: String::new(),
            },
        };
        let result = ghostty_targets(&[111], &failing_ps, &runner).unwrap();
        assert!(!result.complete);
    }

    #[test]
    fn ghostty_targets_surfaces_a_tcc_denial_of_either_query_as_permission_denied() {
        let runner = ScriptedRunner::new(vec![out(false, "", TCC_DENIED)]);
        assert_eq!(
            ghostty_targets(&[111], &PanicPs, &runner),
            Err(TerminalError::PermissionDenied)
        );
        let runner = ScriptedRunner::new(vec![version("1.4.0"), out(false, "", TCC_DENIED)]);
        assert_eq!(
            ghostty_targets(&[111], &ps("111 ttys001\n"), &runner),
            Err(TerminalError::PermissionDenied)
        );
    }

    #[test]
    fn ghostty_targets_with_no_pids_never_runs_ps_or_osascript() {
        let result = ghostty_targets(&[], &PanicPs, &PanicRunner).unwrap();
        assert!(result.targets.is_empty());
        assert!(result.complete);
    }
}
