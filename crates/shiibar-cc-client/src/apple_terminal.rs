//! Terminal.app / AppleScript knowledge lives here ONLY (design principle 2,
//! DESIGN.md §4.3 / §8.2 / §8.47). Everything measured about Terminal.app is
//! in §7-7; this module is the code expression of it. The generic osascript
//! / `ps` plumbing, the shared error type, and the prefix dispatch live in
//! `crate::terminal`.
//!
//! The identity key for a Terminal.app session is its **tty** — the only key
//! derivable from both inside (the hook environment) and outside (AppleScript)
//! (§7-7: `TERM_SESSION_ID` has no AppleScript counterpart, so it's unusable
//! for matching). The AppleScript `tty of tab` reports `/dev/ttysNNN`, the
//! same absolute form the target carries; `ps` reports it bare, so
//! comparisons normalize with `normalize_tty` (§7-7).
//!
//! Test separation is the same as the iterm2 module (DESIGN.md §4.3): script
//! generation and output parsing are pure functions; only the osascript
//! process invocation is impure, behind the injected `AppleScriptRunner`.

use crate::terminal::{
    AppleScriptOutput, AppleScriptRunner, ProbeOutcome, PsRunner, TerminalError, TerminalResult,
    bad_output, build_resume_shell_command, escape_as_string_literal, is_permission_denied,
    normalize_tty, parse_ps_tty_output,
};

/// The target prefix for Terminal.app sessions (§2), with the trailing `:`.
const APPLE_TERMINAL_PREFIX: &str = "apple-terminal:";

// ---------------------------------------------------------------------
// Pure: AppleScript generation
// ---------------------------------------------------------------------

/// AppleScript that scans **all windows × all tabs** of Terminal.app for a
/// tab whose `tty` equals `tty`, and if found: activates Terminal.app FIRST,
/// then selects that tab and brings its window frontmost (DESIGN.md
/// §4.3/§7-7). Activate-first mirrors the iterm2 module: with the selects
/// first, a focus issued while another app is active raises a same-Space
/// window, so a tab on another Space never comes forward (§7-1; the
/// Terminal.app cross-Space case is measured too, §7-7). The full scan is
/// required because a Cmd+T tab appears to
/// AppleScript as a separate single-tab window (AppKit window tabs), while a
/// merged window holds several tabs — one loop covers both shapes (§7-7). A
/// no-match moves nothing.
///
/// Guarded on `application id "com.apple.Terminal" is running` first, and the
/// `tell application "Terminal"` block lives inside that guard: the
/// is-running query does NOT launch Terminal.app (§7-7), but a bare `tell`
/// would — so this is what keeps `focus` from launching it when it isn't
/// running (same pattern as the iterm2 module). Reading `tty of t` is wrapped
/// in a `try` so one odd tab can't abort the scan. Prints `FOUND` or
/// `NOTFOUND` as the last line of stdout.
pub fn build_focus_script(tty: &str) -> String {
    let tty = escape_as_string_literal(tty);
    format!(
        r#"if application id "com.apple.Terminal" is running then
    tell application "Terminal"
        repeat with w in windows
            repeat with t in tabs of w
                try
                    if (tty of t) is "{tty}" then
                        activate
                        set selected of t to true
                        set frontmost of w to true
                        return "FOUND"
                    end if
                end try
            end repeat
        end repeat
    end tell
end if
return "NOTFOUND"
"#
    )
}

/// AppleScript that reports the frontmost Terminal.app tab's tty, if
/// Terminal.app is the frontmost application (DESIGN.md §4.3). The frontmost
/// application process is named `Terminal`. Prints `FOCUSED:<tty>` or `NONE`.
pub fn build_focused_script() -> String {
    r#"if application id "com.apple.Terminal" is running then
    tell application "System Events"
        set frontAppName to name of first application process whose frontmost is true
    end tell
    if frontAppName is "Terminal" then
        tell application "Terminal"
            return "FOCUSED:" & (tty of selected tab of front window)
        end tell
    else
        return "NONE"
    end if
else
    return "NONE"
end if
"#
    .to_string()
}

/// Harmless AppleScript used by `shiibar-cc doctor` to check osascript's TCC
/// Automation permission for Terminal.app, without side effects (no
/// `activate`, and no `tell` unless it's already running — so it never
/// launches it). Prints a window count, or `NOT_RUNNING`.
pub fn build_probe_script() -> String {
    r#"if application id "com.apple.Terminal" is running then
    tell application "Terminal" to return (count of windows) as string
else
    return "NOT_RUNNING"
end if
"#
    .to_string()
}

/// AppleScript that opens a *new* Terminal.app window and runs
/// `claude --resume <session_id>` there, `cd`-ed into `cwd` (DESIGN.md §4.3).
/// Unlike `build_focus_script`, this does NOT guard on `is running`: a bare
/// `tell application "Terminal"` launches Terminal.app if needed, which is
/// the wanted behavior for a verb that opens a new window (§4.3).
///
/// Launch method: `do script "<cmd>"` with no `in <tab>` target, which
/// **opens a new window** and types the command into its interactive login
/// shell — so `claude` resolves through the user's rc-file PATH (the same
/// reason the iterm2 module uses `write text` rather than a directly-run
/// command, §4.3). The shell command line is embedded as an AppleScript
/// string literal, so it goes through `escape_as_string_literal` on top of
/// `build_resume_shell_command`'s shell single-quoting (the double escaping
/// the spec flags). Prints `OK` as the last line of stdout on success.
pub fn build_resume_script(cwd: &str, session_id: &str) -> String {
    let shell_command = build_resume_shell_command(cwd, session_id);
    let escaped_command = escape_as_string_literal(&shell_command);
    format!(
        r#"tell application "Terminal"
    activate
    do script "{escaped_command}"
end tell
return "OK"
"#
    )
}

/// AppleScript that enumerates every Terminal.app tab's `tty` (DESIGN.md
/// §3.5/§4.3). Same guarded, `try`-per-tab pattern as `build_focus_script`;
/// a `try` failure increments a counter instead of aborting the scan, so one
/// bad tab doesn't erase everything that enumerated cleanly. Output is one
/// `TAB<TAB>tty` line per tab found, followed by a final `DONE<TAB><failure
/// count>` line; `failures > 0` marks the scan incomplete (§3.5: skip
/// pruning that round).
pub fn build_apple_terminal_targets_script() -> String {
    r#"if application id "com.apple.Terminal" is running then
    tell application "Terminal"
        set failures to 0
        set outputLines to {}
        repeat with w in windows
            repeat with t in tabs of w
                try
                    set theTty to tty of t
                    set end of outputLines to ("TAB" & (ASCII character 9) & theTty)
                on error
                    set failures to failures + 1
                end try
            end repeat
        end repeat
        set AppleScript's text item delimiters to linefeed
        set outputText to outputLines as text
        set AppleScript's text item delimiters to ""
        return outputText & linefeed & "DONE" & (ASCII character 9) & failures
    end tell
else
    return "DONE" & (ASCII character 9) & "0"
end if
"#
    .to_string()
}

// ---------------------------------------------------------------------
// Pure: osascript output parsing
// ---------------------------------------------------------------------

pub fn parse_focus_output(output: &AppleScriptOutput) -> TerminalResult<()> {
    if is_permission_denied(output) {
        return Err(TerminalError::PermissionDenied);
    }
    if !output.success {
        return Err(TerminalError::Other(output.stderr.trim().to_string()));
    }
    match output.stdout.trim() {
        "FOUND" => Ok(()),
        "NOTFOUND" => Err(TerminalError::NoMatch),
        other => Err(bad_output(other)),
    }
}

pub fn parse_focused_output(output: &AppleScriptOutput) -> TerminalResult<Option<String>> {
    if is_permission_denied(output) {
        return Err(TerminalError::PermissionDenied);
    }
    if !output.success {
        return Err(TerminalError::Other(output.stderr.trim().to_string()));
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
    // The AppleScript tty is already the `/dev/ttysNNN` form the target
    // carries (§7-7); prefix it to make the full target (§2/§4.3).
    Ok(Some(format!("{APPLE_TERMINAL_PREFIX}{tty}")))
}

pub fn parse_probe_output(output: &AppleScriptOutput) -> TerminalResult<ProbeOutcome> {
    if is_permission_denied(output) {
        return Err(TerminalError::PermissionDenied);
    }
    if !output.success {
        return Err(TerminalError::Other(output.stderr.trim().to_string()));
    }
    if output.stdout.trim() == "NOT_RUNNING" {
        Ok(ProbeOutcome::NotRunning)
    } else {
        Ok(ProbeOutcome::Granted)
    }
}

/// Parse `build_resume_script`'s output. There's no "no match" outcome here
/// (unlike `parse_focus_output`) — `open_resume_window` always opens a new
/// window, it never searches for one.
pub fn parse_resume_output(output: &AppleScriptOutput) -> TerminalResult<()> {
    if is_permission_denied(output) {
        return Err(TerminalError::PermissionDenied);
    }
    if !output.success {
        return Err(TerminalError::Other(output.stderr.trim().to_string()));
    }
    match output.stdout.trim() {
        "OK" => Ok(()),
        other => Err(bad_output(other)),
    }
}

/// Parse `build_apple_terminal_targets_script`'s output into a list of tab
/// ttys plus whether the scan was complete (no `try` failures, §3.5).
pub fn parse_apple_terminal_targets_output(
    output: &AppleScriptOutput,
) -> TerminalResult<(Vec<String>, bool)> {
    if is_permission_denied(output) {
        return Err(TerminalError::PermissionDenied);
    }
    if !output.success {
        return Err(TerminalError::Other(output.stderr.trim().to_string()));
    }

    let mut ttys = Vec::new();
    let mut failures: Option<u32> = None;
    for line in output.stdout.lines() {
        if let Some(rest) = line.strip_prefix("TAB\t") {
            ttys.push(rest.to_string());
        } else if let Some(rest) = line.strip_prefix("DONE\t") {
            failures = Some(rest.trim().parse().map_err(|_| bad_output(line))?);
        }
    }
    let failures = failures.ok_or_else(|| bad_output(output.stdout.trim()))?;
    Ok((ttys, failures == 0))
}

// ---------------------------------------------------------------------
// Impure: wire pure generation/parsing to a runner
// ---------------------------------------------------------------------

/// `focus(target)` (DESIGN.md §4.3): jump to the Terminal.app tab whose tty
/// is `tty` (the target with `apple-terminal:` already stripped by the
/// dispatch). `NoMatch` covers "no such tab" and "Terminal.app isn't running".
pub fn focus(tty: &str, runner: &dyn AppleScriptRunner) -> TerminalResult<()> {
    if tty.is_empty() {
        return Err(TerminalError::NoMatch);
    }
    let output = runner
        .run(&build_focus_script(tty))
        .map_err(|e| TerminalError::Other(e.to_string()))?;
    parse_focus_output(&output)
}

/// `focused()` (DESIGN.md §4.3): the frontmost Terminal.app tab's target
/// (`apple-terminal:<tty>`), if Terminal.app is the frontmost application;
/// `Ok(None)` otherwise.
pub fn focused(runner: &dyn AppleScriptRunner) -> TerminalResult<Option<String>> {
    let output = runner
        .run(&build_focused_script())
        .map_err(|e| TerminalError::Other(e.to_string()))?;
    parse_focused_output(&output)
}

/// Harmless Terminal.app probe for `shiibar-cc doctor`'s TCC permission check.
pub fn probe(runner: &dyn AppleScriptRunner) -> TerminalResult<ProbeOutcome> {
    let output = runner
        .run(&build_probe_script())
        .map_err(|e| TerminalError::Other(e.to_string()))?;
    parse_probe_output(&output)
}

/// `open_resume_window(cwd, session_id)` (DESIGN.md §4.3): open a new
/// Terminal.app window and run `claude --resume <session_id>` there, `cd`-ed
/// into `cwd`. `cwd` and `session_id` are escaped, not validated —
/// `shiibar-cc resume` checks `cwd` first (§4.4).
pub fn open_resume_window(
    cwd: &str,
    session_id: &str,
    runner: &dyn AppleScriptRunner,
) -> TerminalResult<()> {
    let output = runner
        .run(&build_resume_script(cwd, session_id))
        .map_err(|e| TerminalError::Other(e.to_string()))?;
    parse_resume_output(&output)
}

/// One pid -> target(`apple-terminal:<tty>`) mapping, plus whether the
/// underlying scan (both `ps` and the Terminal.app enumeration) was complete
/// enough to trust for pruning (§3.5). Mirrors `iterm2::Iterm2Targets`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppleTerminalTargets {
    pub targets: std::collections::HashMap<u32, String>,
    pub complete: bool,
}

/// `apple_terminal_targets(pids)` (DESIGN.md §3.5/§4.3): resolve `claude
/// agents`' pids to shiibar targets by matching `ps`'s pid -> tty against
/// Terminal.app's own tab tty enumeration. A pid with no matching tab (not
/// running inside Terminal.app) is simply absent from `targets` — out of
/// scope for shiibar (§8.11/§8.47), not a scan failure.
///
/// Error handling matches the iterm2 module exactly (§4.4): TCC (Automation)
/// denial is `Err(PermissionDenied)`; every other failure degrades to `Ok`
/// with `complete: false` and whatever could still be resolved (§3.5).
///
/// **Terminal.app is not asked to launch**: when it isn't running, its
/// enumeration script returns zero tabs (via the is-running guard, §7-7), so
/// an empty result is the natural "no Terminal.app sessions" answer without a
/// separate not-running branch here — the same treatment §3.5 wants for an
/// un-launched terminal.
pub fn apple_terminal_targets(
    pids: &[u32],
    ps_runner: &dyn PsRunner,
    script_runner: &dyn AppleScriptRunner,
) -> TerminalResult<AppleTerminalTargets> {
    if pids.is_empty() {
        return Ok(AppleTerminalTargets {
            targets: std::collections::HashMap::new(),
            complete: true,
        });
    }

    let (pid_tty, ps_ok) = match ps_runner.run(pids) {
        Ok(output) if output.success => (parse_ps_tty_output(&output.stdout), true),
        Ok(output) => (parse_ps_tty_output(&output.stdout), false),
        Err(_) => (std::collections::HashMap::new(), false),
    };

    let (tab_ttys, scan_complete) = match script_runner.run(&build_apple_terminal_targets_script()) {
        Ok(output) => match parse_apple_terminal_targets_output(&output) {
            Ok(v) => v,
            Err(TerminalError::PermissionDenied) => return Err(TerminalError::PermissionDenied),
            Err(_) => (Vec::new(), false),
        },
        Err(_) => (Vec::new(), false),
    };

    let mut targets = std::collections::HashMap::new();
    for (&pid, tty) in &pid_tty {
        if let Some(tab_tty) = tab_ttys
            .iter()
            .find(|tab_tty| normalize_tty(tab_tty) == normalize_tty(tty))
        {
            // Prefixed target (§2/§3.5): the `/dev/`-prefixed AppleScript tty.
            let full_tty = if tab_tty.starts_with("/dev/") {
                tab_tty.to_string()
            } else {
                format!("/dev/{tab_tty}")
            };
            targets.insert(pid, format!("{APPLE_TERMINAL_PREFIX}{full_tty}"));
        }
    }

    Ok(AppleTerminalTargets {
        targets,
        complete: ps_ok && scan_complete,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::terminal::PsOutput;

    fn out(success: bool, stdout: &str, stderr: &str) -> AppleScriptOutput {
        AppleScriptOutput {
            success,
            stdout: stdout.to_string(),
            stderr: stderr.to_string(),
        }
    }

    // ---- AppleScript generation (structural assertions only) ----

    #[test]
    fn focus_script_checks_running_before_telling_the_app_and_scans_all_tabs() {
        let script = build_focus_script("/dev/ttys006");
        let running_check = script
            .find(r#"application id "com.apple.Terminal" is running"#)
            .unwrap();
        let tell_app = script.find(r#"tell application "Terminal""#).unwrap();
        assert!(running_check < tell_app, "must check `is running` before telling the app");
        // All windows × all tabs (§7-7): a window loop containing a tab loop.
        assert!(script.contains("repeat with w in windows"));
        assert!(script.contains("repeat with t in tabs of w"));
        assert!(script.contains("tty of t"));
        assert!(script.contains("/dev/ttys006"));
        assert!(script.contains("FOUND"));
        assert!(script.contains("NOTFOUND"));
    }

    #[test]
    fn focus_script_activates_first_then_sets_selected_and_frontmost() {
        // Activate-first (DESIGN.md §7-1/§4.3); selected/frontmost keep their
        // relative order, only activate moves to the front of the branch.
        let script = build_focus_script("/dev/ttys006");
        let if_match = script.find("if (tty of t) is").unwrap();
        let activate = script.find("activate").unwrap();
        let set_selected = script.find("set selected of t to true").unwrap();
        let set_frontmost = script.find("set frontmost of w to true").unwrap();
        let found = script.find("\"FOUND\"").unwrap();
        assert!(if_match < activate, "activate must be inside the match branch");
        assert!(activate < set_selected, "activate must run before the selects");
        assert!(set_selected < set_frontmost);
        assert!(set_frontmost < found);
    }

    #[test]
    fn focus_script_activate_appears_only_inside_the_match_branch() {
        // The scan, the no-match (NOTFOUND) path, and the not-running guard
        // must move nothing: activate exists exactly once, inside the
        // `if (tty of t) is` branch (DESIGN.md §7-1/§4.3).
        let script = build_focus_script("/dev/ttys006");
        assert_eq!(
            script.matches("activate").count(),
            1,
            "activate must appear exactly once"
        );
        let if_match = script.find("if (tty of t) is").unwrap();
        // The first `end if` in the text closes the match branch (it nests
        // inside the outer is-running guard), so activate before it proves
        // activate is confined to the match branch.
        let end_of_match = script.find("end if").unwrap();
        let activate = script.find("activate").unwrap();
        assert!(
            if_match < activate && activate < end_of_match,
            "activate must sit inside the match branch, so NOTFOUND moves nothing"
        );
        let notfound = script.find("\"NOTFOUND\"").unwrap();
        assert!(activate < notfound);
    }

    #[test]
    fn focus_script_escapes_quotes_and_backslashes_in_tty() {
        let script = build_focus_script(r#"weird"tty\"#);
        assert!(script.contains(r#""weird\"tty\\""#));
    }

    #[test]
    fn focused_script_checks_frontmost_app_before_reading_tty() {
        let script = build_focused_script();
        assert!(script.contains("frontmost is true"));
        assert!(script.contains("is \"Terminal\""));
        assert!(script.contains("tty of selected tab of front window"));
        assert!(script.contains("FOCUSED:"));
        assert!(script.contains("NONE"));
    }

    #[test]
    fn probe_script_never_activates_and_guards_on_running() {
        let script = build_probe_script();
        assert!(!script.contains("activate"));
        assert!(script.contains(r#"application id "com.apple.Terminal" is running"#));
        assert!(script.contains("NOT_RUNNING"));
    }

    #[test]
    fn targets_script_never_activates_and_guards_on_running() {
        let script = build_apple_terminal_targets_script();
        assert!(!script.contains("activate"));
        assert!(script.contains(r#"application id "com.apple.Terminal" is running"#));
        assert!(script.contains("TAB"));
        assert!(script.contains("DONE"));
    }

    // ---- build_resume_script ----

    #[test]
    fn resume_script_launches_terminal_without_a_running_guard_via_do_script() {
        // Unlike build_focus_script, must NOT gate on "is running" —
        // open_resume_window is expected to launch Terminal.app (§4.3), and
        // the launch method is `do script` (new window).
        let script = build_resume_script("/Users/example/project", "SESSION-1");
        assert!(!script.contains("is running"));
        assert!(script.contains(r#"tell application "Terminal""#));
        assert!(script.contains("do script"));
    }

    #[test]
    fn resume_script_contains_the_cd_and_resume_command() {
        let script = build_resume_script("/Users/example/project", "SESSION-1");
        assert!(script.contains("cd '/Users/example/project'"));
        assert!(script.contains("claude --resume 'SESSION-1'"));
        assert!(script.contains("\"OK\""));
    }

    #[test]
    fn resume_script_double_escapes_a_cwd_with_spaces_and_quotes() {
        // Shell single-quote escaping first (a no-op for `"` inside single
        // quotes), then AppleScript string-literal escaping on top (§4.3
        // double escaping) — which turns the embedded `"` into `\"`.
        let script = build_resume_script(r#"/Users/example/My "great" project"#, "SESSION-1");
        assert!(script.contains(r#"cd '/Users/example/My \"great\" project'"#));
    }

    #[test]
    fn resume_script_escapes_a_cwd_containing_a_single_quote() {
        let script = build_resume_script("/Users/example/O'Brien", "SESSION-1");
        assert!(script.contains(r#"cd '/Users/example/O'\\''Brien'"#));
    }

    // ---- output parsing ----

    #[test]
    fn parse_focus_output_found() {
        assert_eq!(parse_focus_output(&out(true, "FOUND\n", "")), Ok(()));
    }

    #[test]
    fn parse_focus_output_notfound() {
        assert_eq!(
            parse_focus_output(&out(true, "NOTFOUND\n", "")),
            Err(TerminalError::NoMatch)
        );
    }

    #[test]
    fn parse_focus_output_permission_denied() {
        let stderr = "execution error: Terminal got an error: Not authorized to send Apple events to Terminal. (-1743)";
        assert_eq!(
            parse_focus_output(&out(false, "", stderr)),
            Err(TerminalError::PermissionDenied)
        );
    }

    #[test]
    fn parse_focus_output_other_failure() {
        assert_eq!(
            parse_focus_output(&out(false, "", "some other osascript error")),
            Err(TerminalError::Other("some other osascript error".to_string()))
        );
    }

    #[test]
    fn parse_focused_output_none() {
        assert_eq!(parse_focused_output(&out(true, "NONE\n", "")), Ok(None));
    }

    #[test]
    fn parse_focused_output_returns_the_prefixed_tty_as_target() {
        assert_eq!(
            parse_focused_output(&out(true, "FOCUSED:/dev/ttys006\n", "")),
            Ok(Some("apple-terminal:/dev/ttys006".to_string()))
        );
    }

    #[test]
    fn parse_focused_output_permission_denied() {
        let stderr = "not authorized to send Apple events to System Events.";
        assert_eq!(
            parse_focused_output(&out(false, "", stderr)),
            Err(TerminalError::PermissionDenied)
        );
    }

    #[test]
    fn parse_probe_output_not_running() {
        assert_eq!(
            parse_probe_output(&out(true, "NOT_RUNNING\n", "")),
            Ok(ProbeOutcome::NotRunning)
        );
    }

    #[test]
    fn parse_probe_output_granted() {
        assert_eq!(parse_probe_output(&out(true, "2\n", "")), Ok(ProbeOutcome::Granted));
    }

    #[test]
    fn parse_probe_output_permission_denied() {
        let stderr = "osascript is not allowed to send Apple events, error -1743";
        assert_eq!(
            parse_probe_output(&out(false, "", stderr)),
            Err(TerminalError::PermissionDenied)
        );
    }

    #[test]
    fn parse_resume_output_ok() {
        assert_eq!(parse_resume_output(&out(true, "OK\n", "")), Ok(()));
    }

    #[test]
    fn parse_resume_output_permission_denied() {
        let stderr = "Not authorized to send Apple events to Terminal. (-1743)";
        assert_eq!(
            parse_resume_output(&out(false, "", stderr)),
            Err(TerminalError::PermissionDenied)
        );
    }

    #[test]
    fn parse_targets_output_extracts_ttys_and_zero_failures_is_complete() {
        let output = out(true, "TAB\t/dev/ttys000\nTAB\t/dev/ttys006\nDONE\t0\n", "");
        let (ttys, complete) = parse_apple_terminal_targets_output(&output).unwrap();
        assert_eq!(ttys, vec!["/dev/ttys000".to_string(), "/dev/ttys006".to_string()]);
        assert!(complete);
    }

    #[test]
    fn parse_targets_output_nonzero_failures_is_incomplete() {
        let output = out(true, "TAB\t/dev/ttys000\nDONE\t1\n", "");
        let (ttys, complete) = parse_apple_terminal_targets_output(&output).unwrap();
        assert_eq!(ttys.len(), 1);
        assert!(!complete);
    }

    #[test]
    fn parse_targets_output_not_running_is_empty_and_complete() {
        let output = out(true, "DONE\t0\n", "");
        let (ttys, complete) = parse_apple_terminal_targets_output(&output).unwrap();
        assert!(ttys.is_empty());
        assert!(complete, "no Terminal.app at all is zero tabs, not a failed scan");
    }

    #[test]
    fn parse_targets_output_permission_denied() {
        let stderr = "Not authorized to send Apple events to Terminal. (-1743)";
        assert_eq!(
            parse_apple_terminal_targets_output(&out(false, "", stderr)),
            Err(TerminalError::PermissionDenied)
        );
    }

    // ---- end-to-end wiring with fake runners ----

    struct FakeRunner {
        output: AppleScriptOutput,
    }

    impl AppleScriptRunner for FakeRunner {
        fn run(&self, _script: &str) -> std::io::Result<AppleScriptOutput> {
            Ok(self.output.clone())
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

    #[test]
    fn focus_empty_tty_never_runs_osascript() {
        struct PanicRunner;
        impl AppleScriptRunner for PanicRunner {
            fn run(&self, _script: &str) -> std::io::Result<AppleScriptOutput> {
                panic!("osascript should not run for an empty tty");
            }
        }
        assert_eq!(focus("", &PanicRunner), Err(TerminalError::NoMatch));
    }

    #[test]
    fn focus_success_end_to_end() {
        let runner = FakeRunner { output: out(true, "FOUND\n", "") };
        assert_eq!(focus("/dev/ttys006", &runner), Ok(()));
    }

    #[test]
    fn focused_end_to_end_returns_prefixed_target() {
        let runner = FakeRunner {
            output: out(true, "FOCUSED:/dev/ttys006\n", ""),
        };
        assert_eq!(
            focused(&runner),
            Ok(Some("apple-terminal:/dev/ttys006".to_string()))
        );
    }

    #[test]
    fn probe_end_to_end() {
        let runner = FakeRunner { output: out(true, "NOT_RUNNING\n", "") };
        assert_eq!(probe(&runner), Ok(ProbeOutcome::NotRunning));
    }

    #[test]
    fn open_resume_window_success_end_to_end() {
        let runner = FakeRunner { output: out(true, "OK\n", "") };
        assert_eq!(
            open_resume_window("/Users/example/project", "SESSION-1", &runner),
            Ok(())
        );
    }

    #[test]
    fn apple_terminal_targets_matches_pid_to_prefixed_target_via_tty() {
        let ps = FakePs {
            output: PsOutput {
                success: true,
                // `ps` reports the tty bare (no /dev/); the AppleScript
                // enumeration reports it with /dev/ (§7-7).
                stdout: "111 ttys000\n222 ttys006\n".to_string(),
            },
        };
        let script = FakeRunner {
            output: out(true, "TAB\t/dev/ttys000\nTAB\t/dev/ttys006\nDONE\t0\n", ""),
        };
        let result = apple_terminal_targets(&[111, 222], &ps, &script).unwrap();
        assert_eq!(
            result.targets.get(&111).map(String::as_str),
            Some("apple-terminal:/dev/ttys000")
        );
        assert_eq!(
            result.targets.get(&222).map(String::as_str),
            Some("apple-terminal:/dev/ttys006")
        );
        assert!(result.complete);
    }

    #[test]
    fn apple_terminal_targets_omits_a_pid_with_no_matching_tab() {
        let ps = FakePs {
            output: PsOutput {
                success: true,
                stdout: "111 ttys009\n".to_string(),
            },
        };
        let script = FakeRunner {
            output: out(true, "TAB\t/dev/ttys000\nDONE\t0\n", ""),
        };
        let result = apple_terminal_targets(&[111], &ps, &script).unwrap();
        assert!(result.targets.is_empty());
        assert!(result.complete, "a pid outside Terminal.app isn't a scan failure");
    }

    #[test]
    fn apple_terminal_targets_is_incomplete_when_the_scan_reports_failures() {
        let ps = FakePs {
            output: PsOutput {
                success: true,
                stdout: "111 ttys000\n".to_string(),
            },
        };
        let script = FakeRunner {
            output: out(true, "TAB\t/dev/ttys000\nDONE\t1\n", ""),
        };
        let result = apple_terminal_targets(&[111], &ps, &script).unwrap();
        assert_eq!(
            result.targets.get(&111).map(String::as_str),
            Some("apple-terminal:/dev/ttys000")
        );
        assert!(!result.complete);
    }

    #[test]
    fn apple_terminal_targets_is_incomplete_when_ps_fails() {
        let ps = FakePs {
            output: PsOutput { success: false, stdout: String::new() },
        };
        let script = FakeRunner {
            output: out(true, "TAB\t/dev/ttys000\nDONE\t0\n", ""),
        };
        let result = apple_terminal_targets(&[111], &ps, &script).unwrap();
        assert!(!result.complete);
    }

    #[test]
    fn apple_terminal_targets_surfaces_tcc_denial_as_permission_denied() {
        let ps = FakePs {
            output: PsOutput {
                success: true,
                stdout: "111 ttys000\n".to_string(),
            },
        };
        let script = FakeRunner {
            output: out(false, "", "Not authorized to send Apple events to Terminal. (-1743)"),
        };
        assert_eq!(
            apple_terminal_targets(&[111], &ps, &script),
            Err(TerminalError::PermissionDenied)
        );
    }

    #[test]
    fn apple_terminal_targets_with_no_pids_never_runs_ps_or_osascript() {
        struct PanicPs;
        impl PsRunner for PanicPs {
            fn run(&self, _pids: &[u32]) -> std::io::Result<PsOutput> {
                panic!("ps must not run when there are no pids to resolve");
            }
        }
        struct PanicScript;
        impl AppleScriptRunner for PanicScript {
            fn run(&self, _script: &str) -> std::io::Result<AppleScriptOutput> {
                panic!("osascript must not run when there are no pids to resolve");
            }
        }
        let result = apple_terminal_targets(&[], &PanicPs, &PanicScript).unwrap();
        assert!(result.targets.is_empty());
        assert!(result.complete);
    }
}
