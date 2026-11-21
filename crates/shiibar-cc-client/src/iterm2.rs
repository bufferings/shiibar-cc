//! iTerm2 / AppleScript knowledge lives here ONLY (design principle 2,
//! DESIGN.md §4.3 / §8.2). The generic osascript / `ps` plumbing, the shared
//! error type, and the prefix dispatch live in `crate::terminal`; this
//! module owns everything iTerm2-specific.
//!
//! Test separation is the load-bearing property of this module (DESIGN.md
//! §4.3, task brief): "AppleScript source generation" and "osascript output
//! parsing" are pure functions (`build_*_script`, `parse_*_output`,
//! `extract_uuid`), and the actual `osascript` process invocation is the
//! only impure part, hidden behind the `AppleScriptRunner` trait. No
//! automated test in this crate ever shells out to the real `osascript` —
//! that needs TCC Automation permission, which isn't available in CI (and
//! would pop a permission dialog on a dev machine the first time).

use crate::terminal::{
    AppleScriptOutput, AppleScriptRunner, ProbeOutcome, PsRunner, TerminalError, TerminalResult,
    bad_output, build_resume_shell_command, escape_as_string_literal, is_permission_denied,
    normalize_tty, parse_ps_tty_output,
};

/// The target prefix for iTerm2 sessions (§2), with the trailing `:`.
const ITERM2_PREFIX: &str = "iterm2:";

// ---------------------------------------------------------------------
// Pure: target <-> UUID
// ---------------------------------------------------------------------

/// Extract the UUID a target refers to (DESIGN.md §2/§4.3). A target is
/// normally already a bare UUID (that's the wire format since the M1M2
/// respec: `shiibar-cc report` and `iterm2_targets` both derive the *same*
/// bare UUID for the same session, §2). The `wNtNpN:UUID` shape (the raw
/// `$ITERM_SESSION_ID` value, §7-1) is also accepted — for pre-respec
/// callers and defensiveness — by taking the part after the `:`; anything
/// with a `:` that *doesn't* match that shape returns `None` ("no match"),
/// rather than being guessed at.
pub fn extract_uuid(target: &str) -> Option<&str> {
    match target.split_once(':') {
        None => (!target.is_empty()).then_some(target),
        Some((prefix, uuid)) => {
            if uuid.is_empty() {
                return None;
            }
            let rest = prefix.strip_prefix('w')?;
            let (w, rest) = split_leading_digits(rest)?;
            let rest = rest.strip_prefix('t')?;
            let (_t, rest) = split_leading_digits(rest)?;
            let rest = rest.strip_prefix('p')?;
            let (_p, rest) = split_leading_digits(rest)?;
            if !rest.is_empty() || w.is_empty() {
                return None;
            }
            Some(uuid)
        }
    }
}

fn split_leading_digits(s: &str) -> Option<(&str, &str)> {
    let end = s.find(|c: char| !c.is_ascii_digit()).unwrap_or(s.len());
    if end == 0 {
        None
    } else {
        Some((&s[..end], &s[end..]))
    }
}

// ---------------------------------------------------------------------
// Pure: AppleScript generation
// ---------------------------------------------------------------------

/// AppleScript that only asks whether iTerm2 is running. Every operation
/// except `open_resume_window` sends this first, and sends its own script
/// only when the answer is `RUNNING`.
///
/// A script that uses iTerm2's terminology (`tabs`, `sessions`, `tty`,
/// `current session`, ...) does not compile when iTerm2 is not installed,
/// because the terminology cannot be loaded; the whole script then fails
/// before it runs, so an `is running` guard inside the same script cannot
/// protect it. This script uses no `tell` and no iTerm2-specific term, so
/// it compiles and runs on a Mac without iTerm2, where it prints
/// `NOT_RUNNING`. It sends no Apple event to iTerm2, so it never launches
/// it. Prints `RUNNING` or `NOT_RUNNING`.
pub fn build_running_script() -> String {
    r#"if application "iTerm2" is running then
    return "RUNNING"
else
    return "NOT_RUNNING"
end if
"#
    .to_string()
}

/// AppleScript that scans iTerm2 for a session whose `id` equals `uuid`,
/// and if found: activates iTerm2 FIRST, then selects its window, its tab,
/// and the matched session (pane). Activate must come before the selects:
/// with the selects first, a focus issued while another app is active makes
/// activate raise a same-Space iTerm2 window, so a session on another Space
/// never comes forward — the script still reports FOUND (DESIGN.md §7-1,
/// 2026-07-17; §4.3). `tell s to select` is essential for split panes —
/// selecting only the window/tab leaves the tab's previously active pane
/// focused, so a jump to a session in a split would land on the wrong pane
/// (verified on a real machine 2026-07-04, M2 smoke test).
/// Deliberately checks `application "iTerm2" is running` first and only
/// opens a `tell application "iTerm2"` block inside that guard — this is
/// what keeps `focus` from launching iTerm2 when it isn't running
/// (DESIGN.md §4.3: "if iTerm2 isn't running, return 'no match' without
/// launching it"; a bare `tell application "iTerm2"` would auto-launch it).
/// `focus` sends `build_running_script` before this script; the guard here
/// still keeps iTerm2 from launching when it quits between the two scripts.
/// Prints `FOUND` or `NOTFOUND` as the last line of stdout.
///
/// Uses explicit numeric indices (`session si of t`) with a per-session
/// `try`, NOT `repeat with s in sessions of t`. The plural form makes
/// iTerm2 resolve "item N of every session of ..." during iteration, which
/// intermittently throws `-1719` (invalid index) on split-pane tabs
/// (real-machine M2 smoke test). Indexing one session at a time inside a
/// `try` lets a transient bad element be skipped instead of aborting the
/// whole scan. The `activate` and the window/tab/session `select`s all stay
/// outside the `try`, so a real error (e.g. TCC denial) still surfaces.
pub fn build_focus_script(uuid: &str) -> String {
    let uuid = escape_as_string_literal(uuid);
    format!(
        r#"if application "iTerm2" is running then
    tell application "iTerm2"
        repeat with wi from 1 to (count of windows)
            set w to window wi
            repeat with ti from 1 to (count of tabs of w)
                set t to tab ti of w
                repeat with si from 1 to (count of sessions of t)
                    set sid to ""
                    try
                        set sid to id of (session si of t)
                    end try
                    if sid is "{uuid}" then
                        activate
                        set s to session si of t
                        tell w to select
                        tell t to select
                        tell s to select
                        return "FOUND"
                    end if
                end repeat
            end repeat
        end repeat
    end tell
end if
return "NOTFOUND"
"#
    )
}

/// AppleScript that reports the frontmost iTerm2 session, if iTerm2 is the
/// frontmost application. Prints `FOCUSED:<uuid>` or `NONE`.
///
/// Only the session UUID is returned: `focus` matches on the UUID alone
/// (§7-1), and iTerm2's AppleScript can't produce a tab index anyway
/// (`index of tab` errors -1728 on a real machine — verified 2026-07-04,
/// found by the M2 smoke test; it is NOT a tmux-only issue).
pub fn build_focused_script() -> String {
    r#"if application "iTerm2" is running then
    tell application "System Events"
        set frontAppName to name of first application process whose frontmost is true
    end tell
    if frontAppName is "iTerm2" then
        tell application "iTerm2"
            return "FOCUSED:" & (id of current session of current window)
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

/// Harmless AppleScript used by `shiibar-cc doctor` to check osascript's
/// TCC Automation permission for iTerm2, without side effects (no
/// `activate`, and no `tell application "iTerm2"` unless it's already
/// running — so it never launches it). Prints a window count, or
/// `NOT_RUNNING`.
pub fn build_probe_script() -> String {
    r#"if application "iTerm2" is running then
    tell application "iTerm2" to return (count of windows) as string
else
    return "NOT_RUNNING"
end if
"#
    .to_string()
}

/// AppleScript that opens a *new* iTerm2 window and runs
/// `claude --resume <session_id>` there, `cd`-ed into `cwd` (DESIGN.md
/// §4.3, task brief T1). Unlike `build_focus_script`, this does NOT guard
/// on `application "iTerm2" is running`: a bare `tell application "iTerm2"`
/// launches iTerm2 if it's not already running, which is the wanted
/// behavior here (a verb that opens a new window has nothing to fail to
/// find, unlike `focus` scanning for an existing session).
///
/// Launch method: `write text` into the new window's session, rather than
/// `create window with default profile command "..."`. `write text` types
/// into the session's normal interactive login shell, which sources the
/// user's shell rc files and so sees the same PATH the user's own terminal
/// sees — this matters because `claude` is commonly reachable only through
/// a PATH assembled by rc-file logic (a version manager shim, an alias,
/// etc.), whereas `create window ... command "..."` runs the given command
/// directly as the session's process, bypassing login-shell PATH setup.
/// This choice could not be confirmed on a real machine in this environment
/// (no TCC Automation grant / no iTerm2 available) — it is the provisional
/// method the task brief calls for in that case; a real-machine
/// smoke test is what confirms or overturns it (see M33 completion report).
///
/// The shell command line is embedded as an AppleScript string literal, so
/// it goes through `escape_as_string_literal` on top of
/// `escape_shell_single_quoted` — the double escaping the task brief flags
/// (AppleScript string quoting, then shell quoting inside that string).
/// Prints `OK` as the last line of stdout on success.
pub fn build_resume_script(cwd: &str, session_id: &str, fork: bool) -> String {
    let shell_command = build_resume_shell_command(cwd, session_id, fork);
    let escaped_command = escape_as_string_literal(&shell_command);
    format!(
        r#"tell application "iTerm2"
    activate
    set newWindow to (create window with default profile)
    tell current session of newWindow
        write text "{escaped_command}"
    end tell
end tell
return "OK"
"#
    )
}

// ---------------------------------------------------------------------
// Pure: osascript output parsing
// ---------------------------------------------------------------------

/// Parse `build_running_script`'s output: `true` for `RUNNING`, `false`
/// for `NOT_RUNNING`. A failed run is `PermissionDenied` for a TCC denial
/// and `Other` otherwise, like every other parser here.
pub fn parse_running_output(output: &AppleScriptOutput) -> TerminalResult<bool> {
    if is_permission_denied(output) {
        return Err(TerminalError::PermissionDenied);
    }
    if !output.success {
        return Err(TerminalError::Other(output.stderr.trim().to_string()));
    }
    match output.stdout.trim() {
        "RUNNING" => Ok(true),
        "NOT_RUNNING" => Ok(false),
        other => Err(bad_output(other)),
    }
}

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
    let Some(uuid) = stdout.strip_prefix("FOCUSED:") else {
        return Err(bad_output(stdout));
    };
    if uuid.is_empty() {
        return Err(bad_output(stdout));
    }
    // The target is the prefixed `iterm2:<UUID>` (§2/§4.3): no `wNtNpN`
    // prefix to reassemble (focus only ever looks at the UUID half, §7-1,
    // and iTerm2 can't give a tab index — see `build_focused_script`).
    Ok(Some(format!("{ITERM2_PREFIX}{uuid}")))
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
/// (unlike `parse_focus_output`) — `open_resume_window` always creates a
/// new window, it never searches for an existing one.
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

// ---------------------------------------------------------------------
// Impure: wire pure generation/parsing to a runner
// ---------------------------------------------------------------------

/// Send `build_running_script` (see there for why it is a separate script)
/// and report whether iTerm2 is running.
fn iterm2_is_running(runner: &dyn AppleScriptRunner) -> TerminalResult<bool> {
    let output = runner
        .run(&build_running_script())
        .map_err(|e| TerminalError::Other(e.to_string()))?;
    parse_running_output(&output)
}

/// `focus(target)` (DESIGN.md §4.3): jump to the iTerm2 session matching
/// `target`'s UUID half. `NoMatch` covers "no such session found in
/// iTerm2", "iTerm2 isn't running" (only `build_running_script` is sent),
/// and "target isn't in the `wNtNpN:UUID` shape at all" (the `session:`
/// fallback target, or garbage input) — no osascript is run in the last
/// case.
pub fn focus(target: &str, runner: &dyn AppleScriptRunner) -> TerminalResult<()> {
    let uuid = extract_uuid(target).ok_or(TerminalError::NoMatch)?;
    if !iterm2_is_running(runner)? {
        return Err(TerminalError::NoMatch);
    }
    let script = build_focus_script(uuid);
    let output = runner
        .run(&script)
        .map_err(|e| TerminalError::Other(e.to_string()))?;
    parse_focus_output(&output)
}

/// `focused()` (DESIGN.md §4.3): the frontmost iTerm2 session's target, if
/// iTerm2 is the frontmost application; `Ok(None)` otherwise, including
/// when iTerm2 isn't running (only `build_running_script` is sent).
pub fn focused(runner: &dyn AppleScriptRunner) -> TerminalResult<Option<String>> {
    if !iterm2_is_running(runner)? {
        return Ok(None);
    }
    let output = runner
        .run(&build_focused_script())
        .map_err(|e| TerminalError::Other(e.to_string()))?;
    parse_focused_output(&output)
}

/// Harmless iTerm2 probe for `shiibar-cc doctor`'s TCC permission check.
/// When iTerm2 isn't running, only `build_running_script` is sent and the
/// result is `NotRunning`.
pub fn probe(runner: &dyn AppleScriptRunner) -> TerminalResult<ProbeOutcome> {
    if !iterm2_is_running(runner)? {
        return Ok(ProbeOutcome::NotRunning);
    }
    let output = runner
        .run(&build_probe_script())
        .map_err(|e| TerminalError::Other(e.to_string()))?;
    parse_probe_output(&output)
}

/// `open_resume_window(cwd, session_id, fork)` (DESIGN.md §4.3): open a new
/// iTerm2 window and run `claude --resume <session_id>` there, `cd`-ed into
/// `cwd` (with `--fork-session` appended when `fork` is true — §4.4). Called
/// by `shiibar-cc resume` (§4.4), which is what Conversations' Resume and
/// Branch buttons shell out to (§4.6). `cwd` and `session_id` are taken as
/// given and escaped, not validated — `shiibar-cc resume` is responsible for
/// checking `cwd` is an absolute, existing directory before this is called.
pub fn open_resume_window(
    cwd: &str,
    session_id: &str,
    fork: bool,
    runner: &dyn AppleScriptRunner,
) -> TerminalResult<()> {
    let script = build_resume_script(cwd, session_id, fork);
    let output = runner
        .run(&script)
        .map_err(|e| TerminalError::Other(e.to_string()))?;
    parse_resume_output(&output)
}

// ---------------------------------------------------------------------
// iterm2_targets: reconcile's pid -> target derivation (DESIGN.md §3.5/§4.3)
// ---------------------------------------------------------------------

/// AppleScript that enumerates every iTerm2 session's `tty` and `id` (§3.5).
/// Same explicit-index-plus-`try` scanning pattern as `build_focus_script`
/// (§7-1: the plural `repeat with s in sessions of t` form intermittently
/// throws `-1719` on split-pane tabs) — a `try` failure here increments a
/// counter instead of aborting the whole scan, so one bad session doesn't
/// erase everything else that *did* enumerate cleanly. Output is one
/// `SESSION<TAB>tty<TAB>uuid` line per session found, followed by a final
/// `DONE<TAB><failure count>` line; `failures > 0` is the signal callers use
/// to treat the scan as incomplete (§3.5: skip pruning that round).
/// `iterm2_targets` sends `build_running_script` before this script; the
/// `is running` guard here still keeps iTerm2 from launching when it quits
/// between the two scripts.
pub fn build_iterm2_targets_script() -> String {
    r#"if application "iTerm2" is running then
    tell application "iTerm2"
        set failures to 0
        set outputLines to {}
        repeat with wi from 1 to (count of windows)
            set w to window wi
            repeat with ti from 1 to (count of tabs of w)
                set t to tab ti of w
                repeat with si from 1 to (count of sessions of t)
                    try
                        set thisSession to session si of t
                        set theTty to tty of thisSession
                        set theId to id of thisSession
                        set end of outputLines to ("SESSION" & (ASCII character 9) & theTty & (ASCII character 9) & theId)
                    on error
                        set failures to failures + 1
                    end try
                end repeat
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

/// Parse `build_iterm2_targets_script`'s output into `(tty, uuid)` pairs plus
/// whether the scan was complete (no `try` failures, §3.5).
pub fn parse_iterm2_targets_output(output: &AppleScriptOutput) -> TerminalResult<(Vec<(String, String)>, bool)> {
    if is_permission_denied(output) {
        return Err(TerminalError::PermissionDenied);
    }
    if !output.success {
        return Err(TerminalError::Other(output.stderr.trim().to_string()));
    }

    let mut sessions = Vec::new();
    let mut failures: Option<u32> = None;
    for line in output.stdout.lines() {
        if let Some(rest) = line.strip_prefix("SESSION\t") {
            let (tty, uuid) = rest.split_once('\t').ok_or_else(|| bad_output(line))?;
            sessions.push((tty.to_string(), uuid.to_string()));
        } else if let Some(rest) = line.strip_prefix("DONE\t") {
            failures = Some(rest.trim().parse().map_err(|_| bad_output(line))?);
        }
    }
    let failures = failures.ok_or_else(|| bad_output(output.stdout.trim()))?;
    Ok((sessions, failures == 0))
}

/// One pid -> target(`iterm2:<UUID>`) mapping, plus whether the underlying
/// scan (both `ps` and the iTerm2 AppleScript enumeration) was complete
/// enough to trust for pruning (§3.5: reconcile only prunes when this is
/// `true`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Iterm2Targets {
    pub targets: std::collections::HashMap<u32, String>,
    pub complete: bool,
}

/// `iterm2_targets(pids)` (DESIGN.md §3.5/§4.3): resolve `claude agents`' pids
/// to shiibar targets by matching `ps`'s pid -> tty against iTerm2's own
/// tty -> uuid enumeration. A pid with no matching iTerm2 session (not
/// running inside iTerm2 at all) is simply absent from `targets` — that
/// session is out of scope for shiibar (§8.11), not a scan failure.
///
/// Error handling is two-tiered, matching the exit-code contract (§4.4):
/// - **TCC (Automation) denial is `Err(PermissionDenied)`** — not a
///   transient scan hiccup but a configuration problem that makes every
///   future scan fail the same way, and callers must be able to map it to
///   exit 3 (`shiibar-cc reconcile`, same rule as `focus`/`focused`).
/// - Every other failure (I/O error on `ps` or `osascript`, unparseable
///   output, per-session `-1719`s) degrades to `Ok` with `complete: false`
///   and whatever could still be resolved (§3.5: caller sends
///   `complete:false` and skips pruning, but still adds/updates from what
///   it *did* get). A failure of `build_running_script` is the same:
///   empty and incomplete.
///
/// `build_running_script` is sent first. When iTerm2 isn't running, the
/// result is empty and complete without running `ps` or the enumeration
/// script.
pub fn iterm2_targets(
    pids: &[u32],
    ps_runner: &dyn PsRunner,
    script_runner: &dyn AppleScriptRunner,
) -> TerminalResult<Iterm2Targets> {
    let empty = |complete| Iterm2Targets {
        targets: std::collections::HashMap::new(),
        complete,
    };
    if pids.is_empty() {
        return Ok(empty(true));
    }

    match iterm2_is_running(script_runner) {
        Ok(true) => {}
        Ok(false) => return Ok(empty(true)),
        Err(TerminalError::PermissionDenied) => return Err(TerminalError::PermissionDenied),
        Err(_) => return Ok(empty(false)),
    }

    let (pid_tty, ps_ok) = match ps_runner.run(pids) {
        Ok(output) if output.success => (parse_ps_tty_output(&output.stdout), true),
        Ok(output) => (parse_ps_tty_output(&output.stdout), false),
        Err(_) => (std::collections::HashMap::new(), false),
    };

    let (sessions, scan_complete) = match script_runner.run(&build_iterm2_targets_script()) {
        Ok(output) => match parse_iterm2_targets_output(&output) {
            Ok(v) => v,
            Err(TerminalError::PermissionDenied) => return Err(TerminalError::PermissionDenied),
            Err(_) => (Vec::new(), false),
        },
        Err(_) => (Vec::new(), false),
    };

    let mut targets = std::collections::HashMap::new();
    for (&pid, tty) in &pid_tty {
        if let Some((_, uuid)) = sessions
            .iter()
            .find(|(session_tty, _)| normalize_tty(session_tty) == normalize_tty(tty))
        {
            // Prefixed target (§2/§3.5): reconcile keys on `iterm2:<UUID>`.
            targets.insert(pid, format!("{ITERM2_PREFIX}{uuid}"));
        }
    }

    Ok(Iterm2Targets {
        targets,
        complete: ps_ok && scan_complete,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    // ---- extract_uuid ----

    #[test]
    fn extracts_uuid_from_a_bare_uuid_target() {
        // The normal shape since the M1M2 respec (§2): target IS the UUID.
        assert_eq!(extract_uuid("D2DA6A1F-TEST"), Some("D2DA6A1F-TEST"));
    }

    #[test]
    fn extracts_uuid_from_well_formed_wntnpn_target() {
        // Still accepted (the raw $ITERM_SESSION_ID shape, §7-1) for
        // defensiveness / pre-respec callers.
        assert_eq!(extract_uuid("w0t0p0:D2DA6A1F-TEST"), Some("D2DA6A1F-TEST"));
        assert_eq!(extract_uuid("w12t3p0:UUID-1"), Some("UUID-1"));
    }

    #[test]
    fn empty_target_does_not_match() {
        assert_eq!(extract_uuid(""), None);
    }

    #[test]
    fn malformed_colon_targets_do_not_match() {
        assert_eq!(extract_uuid("w0t0p0:"), None); // empty uuid
        assert_eq!(extract_uuid("wXtYpZ:UUID"), None); // non-numeric indices
        assert_eq!(extract_uuid("t0p0:UUID"), None); // missing leading w
        assert_eq!(extract_uuid(":UUID"), None); // empty prefix
    }

    // ---- AppleScript generation (structural assertions only) ----

    #[test]
    fn focus_script_checks_running_before_telling_the_app() {
        let script = build_focus_script("SOME-UUID");
        let running_check = script.find(r#"application "iTerm2" is running"#).unwrap();
        let tell_app = script.find(r#"tell application "iTerm2""#).unwrap();
        assert!(
            running_check < tell_app,
            "must check `is running` before addressing the app"
        );
        assert!(script.contains("SOME-UUID"));
        assert!(script.contains("FOUND"));
        assert!(script.contains("NOTFOUND"));
    }

    #[test]
    fn focus_script_activates_first_then_selects_inside_the_match_branch() {
        // Activate-first: with the selects first, a focus issued while
        // another app is active raises a same-Space window and never crosses
        // to the matched session's Space (DESIGN.md §7-1/§4.3).
        let script = build_focus_script("SOME-UUID");
        let if_match = script.find("if sid is").unwrap();
        let activate = script.find("activate").unwrap();
        let window_select = script.find("tell w to select").unwrap();
        let session_select = script.find("tell s to select").unwrap();
        let found = script.find("\"FOUND\"").unwrap();
        assert!(
            if_match < activate,
            "activate must be inside the match branch"
        );
        assert!(
            activate < window_select,
            "activate must run before the window/tab/session selects"
        );
        assert!(window_select < session_select);
        assert!(
            session_select < found,
            "the selects must run before reporting FOUND"
        );
    }

    #[test]
    fn focus_script_activate_appears_only_inside_the_match_branch() {
        // The scan, the no-match (NOTFOUND) path, and the not-running guard
        // must move nothing: activate exists exactly once, inside the
        // `if sid is` branch (DESIGN.md §7-1/§4.3).
        let script = build_focus_script("SOME-UUID");
        assert_eq!(
            script.matches("activate").count(),
            1,
            "activate must appear exactly once"
        );
        let if_match = script.find("if sid is").unwrap();
        // The first `end if` in the text closes the match branch (it nests
        // inside the outer is-running guard), so activate sitting before it
        // proves activate is confined to the match branch.
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
    fn focus_script_selects_the_session_for_split_panes() {
        // Selecting only window/tab lands on the wrong pane in a split;
        // `tell s to select` is required (real-machine finding).
        let script = build_focus_script("SOME-UUID");
        assert!(
            script.contains("tell s to select"),
            "must select the matched session (pane), not just its tab"
        );
    }

    #[test]
    fn focus_script_escapes_quotes_and_backslashes_in_uuid() {
        let script = build_focus_script(r#"weird"uuid\"#);
        assert!(script.contains(r#""weird\"uuid\\""#));
    }

    #[test]
    fn focused_script_checks_frontmost_app_before_reading_session() {
        let script = build_focused_script();
        assert!(script.contains("frontmost is true"));
        assert!(script.contains("FOCUSED:"));
        assert!(script.contains("NONE"));
    }

    #[test]
    fn probe_script_never_activates_and_guards_on_running() {
        let script = build_probe_script();
        assert!(!script.contains("activate"));
        assert!(script.contains(r#"application "iTerm2" is running"#));
        assert!(script.contains("NOT_RUNNING"));
    }

    // ---- build_resume_script ----

    #[test]
    fn resume_script_launches_iterm2_without_a_running_guard() {
        // Unlike build_focus_script, this must NOT gate on "is running" —
        // open_resume_window is expected to launch iTerm2 (DESIGN.md §4.3).
        let script = build_resume_script("/Users/example/project", "SESSION-1", false);
        assert!(!script.contains("is running"));
        assert!(script.contains(r#"tell application "iTerm2""#));
        assert!(script.contains("create window"));
    }

    #[test]
    fn resume_script_contains_the_cd_and_resume_command() {
        let script = build_resume_script("/Users/example/project", "SESSION-1", false);
        assert!(script.contains("cd '/Users/example/project'"));
        assert!(script.contains("claude --resume 'SESSION-1'"));
        assert!(script.contains("write text"));
        assert!(script.contains("\"OK\""));
    }

    #[test]
    fn resume_script_double_escapes_a_cwd_with_spaces_and_quotes() {
        // A cwd like `/Users/example/My "great" project` needs shell
        // single-quote escaping first (a no-op here: double quotes need no
        // escaping inside a shell single-quoted string), then AppleScript
        // string-literal escaping on top of that (task brief T1: "double
        // escaping") — which is what turns the embedded `"` into `\"`.
        let script =
            build_resume_script(r#"/Users/example/My "great" project"#, "SESSION-1", false);
        assert!(script.contains(r#"cd '/Users/example/My \"great\" project'"#));
    }

    #[test]
    fn resume_script_escapes_a_cwd_containing_a_single_quote() {
        // Shell layer: `O'Brien` -> `O'\''Brien` (close quote, escaped
        // quote, reopen quote). AppleScript layer then doubles that
        // sequence's one backslash into two, since the shell-escaped text
        // is itself embedded as an AppleScript string literal.
        let script = build_resume_script("/Users/example/O'Brien", "SESSION-1", false);
        assert!(script.contains(r#"cd '/Users/example/O'\\''Brien'"#));
    }

    #[test]
    fn resume_script_escapes_a_session_id_needing_shell_escaping() {
        // session_id is expected to be a UUID, but is escaped rather than
        // trusted (task brief T1). Same double-escaping as the cwd case.
        let script = build_resume_script("/Users/example/project", "weird'id", false);
        assert!(script.contains(r#"claude --resume 'weird'\\''id'"#));
    }

    #[test]
    fn resume_script_without_fork_has_no_fork_session_flag() {
        let script = build_resume_script("/Users/example/project", "SESSION-1", false);
        assert!(!script.contains("--fork-session"));
    }

    #[test]
    fn resume_script_with_fork_appends_fork_session_at_the_end_of_the_command() {
        // §4.4: `--fork-session` is the last token of the typed command.
        let script = build_resume_script("/Users/example/project", "SESSION-1", true);
        assert!(script.contains(
            r#"write text "cd '/Users/example/project' && claude --resume 'SESSION-1' --fork-session""#
        ));
    }

    #[test]
    fn resume_script_with_fork_keeps_the_existing_double_escaping() {
        let script = build_resume_script("/Users/example/O'Brien", "weird'id", true);
        assert!(script.contains(
            r#"cd '/Users/example/O'\\''Brien' && claude --resume 'weird'\\''id' --fork-session""#
        ));
    }

    // ---- parse_resume_output ----

    #[test]
    fn parse_resume_output_ok() {
        assert_eq!(parse_resume_output(&out(true, "OK\n", "")), Ok(()));
    }

    #[test]
    fn parse_resume_output_permission_denied() {
        let stderr = "Not authorized to send Apple events to iTerm2. (-1743)";
        assert_eq!(
            parse_resume_output(&out(false, "", stderr)),
            Err(TerminalError::PermissionDenied)
        );
    }

    #[test]
    fn parse_resume_output_other_failure() {
        assert_eq!(
            parse_resume_output(&out(false, "", "some other osascript error")),
            Err(TerminalError::Other("some other osascript error".to_string()))
        );
    }

    #[test]
    fn parse_resume_output_unexpected_stdout_is_an_error() {
        assert!(matches!(
            parse_resume_output(&out(true, "garbage", "")),
            Err(TerminalError::Other(_))
        ));
    }

    // ---- osascript output parsing ----

    fn out(success: bool, stdout: &str, stderr: &str) -> AppleScriptOutput {
        AppleScriptOutput {
            success,
            stdout: stdout.to_string(),
            stderr: stderr.to_string(),
        }
    }

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
        let stderr = "execution error: iTerm2 got an error: Not authorized to send Apple events to iTerm2. (-1743)";
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
    fn parse_focus_output_unexpected_stdout_is_an_error() {
        assert!(matches!(
            parse_focus_output(&out(true, "garbage", "")),
            Err(TerminalError::Other(_))
        ));
    }

    #[test]
    fn parse_focused_output_none() {
        assert_eq!(parse_focused_output(&out(true, "NONE\n", "")), Ok(None));
    }

    #[test]
    fn parse_focused_output_returns_the_prefixed_uuid_as_target() {
        assert_eq!(
            parse_focused_output(&out(true, "FOCUSED:ABCD-1234\n", "")),
            Ok(Some("iterm2:ABCD-1234".to_string()))
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
        assert_eq!(
            parse_probe_output(&out(true, "2\n", "")),
            Ok(ProbeOutcome::Granted)
        );
    }

    #[test]
    fn parse_probe_output_permission_denied() {
        let stderr = "osascript is not allowed to send Apple events, error -1743";
        assert_eq!(
            parse_probe_output(&out(false, "", stderr)),
            Err(TerminalError::PermissionDenied)
        );
    }

    // ---- build_running_script / parse_running_output ----

    #[test]
    fn running_script_uses_no_tell_and_no_iterm2_terminology() {
        // A script that uses iTerm2's terminology does not compile when
        // iTerm2 is not installed, so the preliminary query must use none.
        let script = build_running_script();
        assert!(script.contains(r#"application "iTerm2" is running"#));
        assert!(!script.contains("tell"), "{script}");
        for term in [
            "window", "tab", "session", "tty", "activate", "select", "write text", "id of",
        ] {
            assert!(!script.contains(term), "must not use `{term}`: {script}");
        }
        assert!(script.contains("\"RUNNING\""));
        assert!(script.contains("\"NOT_RUNNING\""));
    }

    #[test]
    fn parse_running_output_classifies_running_and_not_running() {
        assert_eq!(parse_running_output(&out(true, "RUNNING\n", "")), Ok(true));
        assert_eq!(parse_running_output(&out(true, "NOT_RUNNING\n", "")), Ok(false));
    }

    #[test]
    fn parse_running_output_distinguishes_tcc_denial_from_other_errors() {
        assert_eq!(
            parse_running_output(&out(false, "", "Not authorized to send Apple events to iTerm2. (-1743)")),
            Err(TerminalError::PermissionDenied)
        );
        assert_eq!(
            parse_running_output(&out(false, "", "some other osascript error")),
            Err(TerminalError::Other("some other osascript error".to_string()))
        );
        assert!(matches!(
            parse_running_output(&out(true, "garbage\n", "")),
            Err(TerminalError::Other(_))
        ));
    }

    // ---- scripted runner: focus()/focused()/probe() wiring ----

    /// Answers each script with the next output in order and records the
    /// scripts it was sent. Running out of outputs is a test failure.
    struct ScriptedRunner {
        outputs: std::cell::RefCell<std::collections::VecDeque<AppleScriptOutput>>,
        scripts: std::cell::RefCell<Vec<String>>,
    }

    impl ScriptedRunner {
        fn new(outputs: Vec<AppleScriptOutput>) -> Self {
            ScriptedRunner {
                outputs: std::cell::RefCell::new(outputs.into()),
                scripts: std::cell::RefCell::new(Vec::new()),
            }
        }

        fn scripts(&self) -> Vec<String> {
            self.scripts.borrow().clone()
        }
    }

    impl AppleScriptRunner for ScriptedRunner {
        fn run(&self, script: &str) -> std::io::Result<AppleScriptOutput> {
            self.scripts.borrow_mut().push(script.to_string());
            Ok(self
                .outputs
                .borrow_mut()
                .pop_front()
                .unwrap_or_else(|| panic!("unexpected extra script: {script}")))
        }
    }

    /// Fails every run with an I/O error (osascript could not be started).
    struct IoErrorRunner;

    impl AppleScriptRunner for IoErrorRunner {
        fn run(&self, _script: &str) -> std::io::Result<AppleScriptOutput> {
            Err(std::io::Error::other("osascript unavailable"))
        }
    }

    const TCC_DENIED: &str = "Not authorized to send Apple events to iTerm2. (-1743)";

    fn running() -> AppleScriptOutput {
        out(true, "RUNNING\n", "")
    }

    fn not_running() -> AppleScriptOutput {
        out(true, "NOT_RUNNING\n", "")
    }

    #[test]
    fn focus_with_malformed_colon_target_never_runs_osascript() {
        struct PanicRunner;
        impl AppleScriptRunner for PanicRunner {
            fn run(&self, _script: &str) -> std::io::Result<AppleScriptOutput> {
                panic!("osascript should not be invoked for an unparseable target");
            }
        }
        let result = focus("not-w-t-p-shaped:garbage", &PanicRunner);
        assert_eq!(result, Err(TerminalError::NoMatch));
    }

    #[test]
    fn focus_sends_the_running_query_first_then_the_focus_script() {
        let runner = ScriptedRunner::new(vec![running(), out(true, "FOUND\n", "")]);
        assert_eq!(focus("w0t0p0:UUID", &runner), Ok(()));
        assert_eq!(
            runner.scripts(),
            vec![build_running_script(), build_focus_script("UUID")]
        );
    }

    #[test]
    fn focus_when_iterm2_is_not_running_is_no_match_after_only_the_running_query() {
        let runner = ScriptedRunner::new(vec![not_running()]);
        assert_eq!(focus("w0t0p0:UUID", &runner), Err(TerminalError::NoMatch));
        assert_eq!(runner.scripts(), vec![build_running_script()]);
    }

    #[test]
    fn focus_permission_denied_end_to_end_with_scripted_runner() {
        let runner = ScriptedRunner::new(vec![running(), out(false, "", TCC_DENIED)]);
        assert_eq!(
            focus("w0t0p0:UUID", &runner),
            Err(TerminalError::PermissionDenied)
        );
    }

    #[test]
    fn focus_maps_a_failed_running_query_like_a_failed_focus_script() {
        let runner = ScriptedRunner::new(vec![out(false, "", TCC_DENIED)]);
        assert_eq!(focus("w0t0p0:UUID", &runner), Err(TerminalError::PermissionDenied));
        assert_eq!(runner.scripts().len(), 1);

        let runner = ScriptedRunner::new(vec![out(false, "", "some other osascript error")]);
        assert_eq!(
            focus("w0t0p0:UUID", &runner),
            Err(TerminalError::Other("some other osascript error".to_string()))
        );
        assert_eq!(runner.scripts().len(), 1);

        assert!(matches!(
            focus("w0t0p0:UUID", &IoErrorRunner),
            Err(TerminalError::Other(_))
        ));
    }

    #[test]
    fn focused_sends_the_running_query_first_then_the_focused_script() {
        let runner = ScriptedRunner::new(vec![running(), out(true, "FOCUSED:UUID\n", "")]);
        assert_eq!(focused(&runner), Ok(Some("iterm2:UUID".to_string())));
        assert_eq!(
            runner.scripts(),
            vec![build_running_script(), build_focused_script()]
        );
    }

    #[test]
    fn focused_when_iterm2_is_not_running_is_none_after_only_the_running_query() {
        let runner = ScriptedRunner::new(vec![not_running()]);
        assert_eq!(focused(&runner), Ok(None));
        assert_eq!(runner.scripts(), vec![build_running_script()]);
    }

    #[test]
    fn focused_maps_a_failed_running_query_like_a_failed_focused_script() {
        let runner = ScriptedRunner::new(vec![out(false, "", TCC_DENIED)]);
        assert_eq!(focused(&runner), Err(TerminalError::PermissionDenied));
        assert_eq!(runner.scripts().len(), 1);

        let runner = ScriptedRunner::new(vec![out(false, "", "some other osascript error")]);
        assert_eq!(
            focused(&runner),
            Err(TerminalError::Other("some other osascript error".to_string()))
        );
    }

    #[test]
    fn probe_sends_the_running_query_first_then_the_probe_script() {
        let runner = ScriptedRunner::new(vec![running(), out(true, "2\n", "")]);
        assert_eq!(probe(&runner), Ok(ProbeOutcome::Granted));
        assert_eq!(
            runner.scripts(),
            vec![build_running_script(), build_probe_script()]
        );
    }

    #[test]
    fn probe_when_iterm2_is_not_running_is_not_running_after_only_the_running_query() {
        let runner = ScriptedRunner::new(vec![not_running()]);
        assert_eq!(probe(&runner), Ok(ProbeOutcome::NotRunning));
        assert_eq!(runner.scripts(), vec![build_running_script()]);
    }

    #[test]
    fn probe_maps_a_failed_running_query_like_a_failed_probe_script() {
        let runner = ScriptedRunner::new(vec![out(false, "", TCC_DENIED)]);
        assert_eq!(probe(&runner), Err(TerminalError::PermissionDenied));
        assert_eq!(runner.scripts().len(), 1);

        let runner = ScriptedRunner::new(vec![out(false, "", "some other osascript error")]);
        assert_eq!(
            probe(&runner),
            Err(TerminalError::Other("some other osascript error".to_string()))
        );
    }

    #[test]
    fn probe_is_not_running_when_iterm2_quits_after_the_running_query() {
        let runner = ScriptedRunner::new(vec![running(), out(true, "NOT_RUNNING\n", "")]);
        assert_eq!(probe(&runner), Ok(ProbeOutcome::NotRunning));
    }

    #[test]
    fn probe_surfaces_a_tcc_denial_of_the_probe_script() {
        let runner = ScriptedRunner::new(vec![running(), out(false, "", TCC_DENIED)]);
        assert_eq!(probe(&runner), Err(TerminalError::PermissionDenied));
    }

    #[test]
    fn open_resume_window_sends_only_the_resume_script() {
        // The resume script launches iTerm2 on purpose, so no running
        // query precedes it.
        let runner = ScriptedRunner::new(vec![out(true, "OK\n", "")]);
        assert_eq!(
            open_resume_window("/Users/example/project", "SESSION-1", false, &runner),
            Ok(())
        );
        assert_eq!(
            runner.scripts(),
            vec![build_resume_script("/Users/example/project", "SESSION-1", false)]
        );
    }

    #[test]
    fn open_resume_window_permission_denied_end_to_end_with_scripted_runner() {
        let runner = ScriptedRunner::new(vec![out(false, "", TCC_DENIED)]);
        assert_eq!(
            open_resume_window("/Users/example/project", "SESSION-1", false, &runner),
            Err(TerminalError::PermissionDenied)
        );
    }

    // ---- iterm2_targets: build_iterm2_targets_script / parsing ----

    #[test]
    fn iterm_targets_script_never_activates_and_guards_on_running() {
        let script = build_iterm2_targets_script();
        assert!(!script.contains("activate"));
        assert!(script.contains(r#"application "iTerm2" is running"#));
        assert!(script.contains("DONE"));
    }

    #[test]
    fn iterm_targets_script_uses_explicit_index_and_try_like_focus() {
        // Same -1719 avoidance as build_focus_script (§7-1).
        let script = build_iterm2_targets_script();
        assert!(script.contains("session si of t"));
        assert!(script.contains("try"));
        assert!(!script.contains("repeat with s in sessions"));
    }

    #[test]
    fn parse_iterm_targets_output_extracts_sessions_and_zero_failures_is_complete() {
        let output = out(
            true,
            "SESSION\t/dev/ttys000\tUUID-A\nSESSION\t/dev/ttys003\tUUID-B\nDONE\t0\n",
            "",
        );
        let (sessions, complete) = parse_iterm2_targets_output(&output).unwrap();
        assert_eq!(
            sessions,
            vec![
                ("/dev/ttys000".to_string(), "UUID-A".to_string()),
                ("/dev/ttys003".to_string(), "UUID-B".to_string()),
            ]
        );
        assert!(complete);
    }

    #[test]
    fn parse_iterm_targets_output_nonzero_failures_is_incomplete() {
        let output = out(true, "SESSION\t/dev/ttys000\tUUID-A\nDONE\t1\n", "");
        let (sessions, complete) = parse_iterm2_targets_output(&output).unwrap();
        assert_eq!(sessions.len(), 1);
        assert!(!complete, "a nonzero failure count must mark the scan incomplete");
    }

    #[test]
    fn parse_iterm_targets_output_iterm2_not_running_is_empty_and_complete() {
        let output = out(true, "DONE\t0\n", "");
        let (sessions, complete) = parse_iterm2_targets_output(&output).unwrap();
        assert!(sessions.is_empty());
        assert!(complete, "no iTerm2 at all is zero sessions, not a failed scan");
    }

    #[test]
    fn parse_iterm_targets_output_permission_denied() {
        let stderr = "Not authorized to send Apple events to iTerm2. (-1743)";
        assert_eq!(
            parse_iterm2_targets_output(&out(false, "", stderr)),
            Err(TerminalError::PermissionDenied)
        );
    }

    // ---- iterm2_targets: end-to-end wiring with fake runners ----
    // (ps parsing / normalize_tty are shared and tested in `terminal`.)

    use crate::terminal::PsOutput;

    struct FakePs {
        output: PsOutput,
    }

    impl PsRunner for FakePs {
        fn run(&self, _pids: &[u32]) -> std::io::Result<PsOutput> {
            Ok(self.output.clone())
        }
    }

    #[test]
    fn iterm2_targets_matches_pid_to_prefixed_target_via_tty() {
        let ps = FakePs {
            output: PsOutput {
                success: true,
                stdout: "111 ttys000\n222 ttys003\n".to_string(),
            },
        };
        let script_runner = ScriptedRunner::new(vec![
            running(),
            out(
                true,
                "SESSION\t/dev/ttys000\tUUID-A\nSESSION\t/dev/ttys003\tUUID-B\nDONE\t0\n",
                "",
            ),
        ]);
        let result = iterm2_targets(&[111, 222], &ps, &script_runner).unwrap();
        assert_eq!(result.targets.get(&111).map(String::as_str), Some("iterm2:UUID-A"));
        assert_eq!(result.targets.get(&222).map(String::as_str), Some("iterm2:UUID-B"));
        assert!(result.complete);
    }

    #[test]
    fn iterm_targets_omits_a_pid_with_no_matching_iterm2_session() {
        let ps = FakePs {
            output: PsOutput {
                success: true,
                stdout: "111 ttys009\n".to_string(), // no iTerm2 session on this tty
            },
        };
        let script_runner = ScriptedRunner::new(vec![
            running(),
            out(true, "SESSION\t/dev/ttys000\tUUID-A\nDONE\t0\n", ""),
        ]);
        let result = iterm2_targets(&[111], &ps, &script_runner).unwrap();
        assert!(result.targets.is_empty());
        assert!(result.complete, "a pid outside iTerm2 isn't a scan failure");
    }

    #[test]
    fn iterm_targets_is_incomplete_when_the_applescript_scan_reports_failures() {
        let ps = FakePs {
            output: PsOutput {
                success: true,
                stdout: "111 ttys000\n".to_string(),
            },
        };
        let script_runner = ScriptedRunner::new(vec![
            running(),
            out(true, "SESSION\t/dev/ttys000\tUUID-A\nDONE\t1\n", ""),
        ]);
        let result = iterm2_targets(&[111], &ps, &script_runner).unwrap();
        assert_eq!(result.targets.get(&111).map(String::as_str), Some("iterm2:UUID-A"));
        assert!(!result.complete);
    }

    #[test]
    fn iterm_targets_is_incomplete_when_ps_fails() {
        let ps = FakePs {
            output: PsOutput {
                success: false,
                stdout: String::new(),
            },
        };
        let script_runner = ScriptedRunner::new(vec![
            running(),
            out(true, "SESSION\t/dev/ttys000\tUUID-A\nDONE\t0\n", ""),
        ]);
        let result = iterm2_targets(&[111], &ps, &script_runner).unwrap();
        assert!(!result.complete);
    }

    #[test]
    fn iterm_targets_surfaces_tcc_denial_as_permission_denied() {
        // TCC denial must NOT degrade to complete:false (that would make
        // reconcile a permanent silent no-op); it must surface as an error
        // so `shiibar-cc reconcile` can map it to exit 3 (§4.4).
        let ps = FakePs {
            output: PsOutput {
                success: true,
                stdout: "111 ttys000\n".to_string(),
            },
        };
        let script_runner = ScriptedRunner::new(vec![running(), out(false, "", TCC_DENIED)]);
        assert_eq!(
            iterm2_targets(&[111], &ps, &script_runner),
            Err(TerminalError::PermissionDenied)
        );
    }

    #[test]
    fn iterm2_targets_sends_the_running_query_first_then_the_enumeration_script() {
        let ps = FakePs {
            output: PsOutput {
                success: true,
                stdout: "111 ttys000\n".to_string(),
            },
        };
        let script_runner = ScriptedRunner::new(vec![
            running(),
            out(true, "SESSION\t/dev/ttys000\tUUID-A\nDONE\t0\n", ""),
        ]);
        iterm2_targets(&[111], &ps, &script_runner).unwrap();
        assert_eq!(
            script_runner.scripts(),
            vec![build_running_script(), build_iterm2_targets_script()]
        );
    }

    #[test]
    fn iterm2_targets_when_iterm2_is_not_running_is_empty_and_complete_after_only_the_running_query() {
        struct PanicPs;
        impl PsRunner for PanicPs {
            fn run(&self, _pids: &[u32]) -> std::io::Result<PsOutput> {
                panic!("ps must not run when iTerm2 is not running");
            }
        }
        let script_runner = ScriptedRunner::new(vec![not_running()]);
        let result = iterm2_targets(&[111], &PanicPs, &script_runner).unwrap();
        assert!(result.targets.is_empty());
        assert!(result.complete, "no iTerm2 at all is zero sessions, not a failed scan");
        assert_eq!(script_runner.scripts(), vec![build_running_script()]);
    }

    #[test]
    fn iterm2_targets_is_incomplete_when_the_running_query_fails() {
        let ps = FakePs {
            output: PsOutput {
                success: true,
                stdout: "111 ttys000\n".to_string(),
            },
        };
        let script_runner = ScriptedRunner::new(vec![out(false, "", "some other osascript error")]);
        let result = iterm2_targets(&[111], &ps, &script_runner).unwrap();
        assert!(result.targets.is_empty());
        assert!(!result.complete, "a failed running query is an incomplete scan");
        assert_eq!(script_runner.scripts().len(), 1);

        let result = iterm2_targets(&[111], &ps, &IoErrorRunner).unwrap();
        assert!(result.targets.is_empty());
        assert!(!result.complete);
    }

    #[test]
    fn iterm2_targets_surfaces_a_tcc_denial_of_the_running_query_as_permission_denied() {
        let ps = FakePs {
            output: PsOutput {
                success: true,
                stdout: "111 ttys000\n".to_string(),
            },
        };
        let script_runner = ScriptedRunner::new(vec![out(false, "", TCC_DENIED)]);
        assert_eq!(
            iterm2_targets(&[111], &ps, &script_runner),
            Err(TerminalError::PermissionDenied)
        );
        assert_eq!(script_runner.scripts().len(), 1);
    }

    #[test]
    fn iterm_targets_with_no_pids_never_runs_ps_or_osascript() {
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
        let result = iterm2_targets(&[], &PanicPs, &PanicScript).unwrap();
        assert!(result.targets.is_empty());
        assert!(result.complete);
    }
}
