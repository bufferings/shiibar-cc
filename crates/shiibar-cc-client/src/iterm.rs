//! iTerm2 / AppleScript knowledge lives here ONLY (design principle 2,
//! DESIGN.md §4.3 / §8.2).
//!
//! Test separation is the load-bearing property of this module (DESIGN.md
//! §4.3, task brief): "AppleScript source generation" and "osascript output
//! parsing" are pure functions (`build_*_script`, `parse_*_output`,
//! `extract_uuid`), and the actual `osascript` process invocation is the
//! only impure part, hidden behind the `AppleScriptRunner` trait. No
//! automated test in this crate ever shells out to the real `osascript` —
//! that needs TCC Automation permission, which isn't available in CI (and
//! would pop a permission dialog on a dev machine the first time).

use std::io::Write as _;
use std::process::{Command, Stdio};

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

/// Errors from an iterm operation. The focus/no-match vs. TCC-permission
/// distinction is required by DESIGN.md §4.4 (shiibar-cc exit 2 vs. 3).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ItermError {
    NoMatch,
    PermissionDenied,
    Other(String),
}

impl std::fmt::Display for ItermError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ItermError::NoMatch => write!(f, "no matching iTerm2 session"),
            ItermError::PermissionDenied => {
                write!(
                    f,
                    "osascript is not authorized to control iTerm2 (Automation permission)"
                )
            }
            ItermError::Other(s) => write!(f, "{s}"),
        }
    }
}

impl std::error::Error for ItermError {}

pub type ItermResult<T> = Result<T, ItermError>;

// ---------------------------------------------------------------------
// Pure: target <-> UUID
// ---------------------------------------------------------------------

/// Extract the UUID a target refers to (DESIGN.md §2/§4.3). A target is
/// normally already a bare UUID (that's the wire format since the M1M2
/// respec: `shiibar-cc report` and `iterm_targets` both derive the *same*
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

fn escape_as_string_literal(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

// ---------------------------------------------------------------------
// Pure: AppleScript generation
// ---------------------------------------------------------------------

/// AppleScript that scans iTerm2 for a session whose `id` equals `uuid`,
/// and if found: selects that session (pane), its tab, brings its window
/// to the front, and activates iTerm2. `tell s to select` is essential for
/// split panes — selecting only the window/tab leaves the tab's previously
/// active pane focused, so a jump to a session in a split would land on the
/// wrong pane (verified on a real machine 2026-07-04, M2 smoke test).
/// Deliberately checks `application "iTerm2" is running` first and only
/// opens a `tell application "iTerm2"` block inside that guard — this is
/// what keeps `focus` from launching iTerm2 when it isn't running
/// (DESIGN.md §4.3: "if iTerm2 isn't running, return 'no match' without
/// launching it"; a bare `tell application "iTerm2"` would auto-launch it).
/// Prints `FOUND` or `NOTFOUND` as the last line of stdout.
///
/// Uses explicit numeric indices (`session si of t`) with a per-session
/// `try`, NOT `repeat with s in sessions of t`. The plural form makes
/// iTerm2 resolve "item N of every session of ..." during iteration, which
/// intermittently throws `-1719` (invalid index) on split-pane tabs
/// (real-machine M2 smoke test). Indexing one session at a time inside a
/// `try` lets a transient bad element be skipped instead of aborting the
/// whole scan. The window/tab/session `select` + `activate` stay outside
/// the `try`, so a real error (e.g. TCC denial) still surfaces.
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
                        set s to session si of t
                        tell w to select
                        tell t to select
                        tell s to select
                        activate
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

/// AppleScript that opens a new iTerm2 tab (or window, if iTerm2 currently
/// has none) in `cwd` and runs `cmd` there (DESIGN.md §4.3 `open_tab`, used
/// by `resume`, §4.4). Unlike `focus`/`focused`/`iterm_targets`, this is
/// deliberately allowed to launch iTerm2: there is no `application "iTerm2"
/// is running` guard, so a bare `tell application "iTerm2"` (which
/// auto-launches the app) is exactly what's wanted here.
///
/// `cwd` and `cmd` are both embedded as AppleScript string literals via
/// `escape_as_string_literal` (same escaping `build_focus_script` uses for
/// the target uuid). `cwd` additionally goes through AppleScript's `quoted
/// form of` at script-run-time, which is expected to shell-quote it
/// correctly for the `cd` the new session's shell executes.
///
/// **Unverified on a real machine**: unlike the AppleScript findings in §7-1
/// (focus/iterm_targets), this script's actual behavior — `create window` /
/// `create tab` semantics, whether `quoted form of` works inside a `tell
/// application "iTerm2"` block, whether `write text` reaches the shell
/// before it's ready right after `create window` — has not been
/// real-machine smoke-tested yet. Treat this as a best-effort first draft
/// pending the M3 manual smoke test (DESIGN.md §6).
///
/// Prints `OK` as the last line of stdout on success.
pub fn build_open_tab_script(cwd: &str, cmd: &str) -> String {
    let cwd = escape_as_string_literal(cwd);
    let cmd = escape_as_string_literal(cmd);
    format!(
        r#"tell application "iTerm2"
    activate
    if (count of windows) is 0 then
        create window with default profile
    else
        tell current window to create tab with default profile
    end if
    tell current session of current window
        write text "cd " & quoted form of "{cwd}"
        write text "{cmd}"
    end tell
end tell
return "OK"
"#
    )
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

// ---------------------------------------------------------------------
// Pure: osascript output parsing
// ---------------------------------------------------------------------

/// TCC Automation-permission denial: osascript exits non-zero with an
/// error mentioning "not authorized to send Apple events" / AppleEvent
/// error -1743.
fn is_permission_denied(output: &AppleScriptOutput) -> bool {
    let text = output.stderr.to_lowercase();
    text.contains("not authorized to send apple events") || text.contains("-1743")
}

fn bad_output(stdout: &str) -> ItermError {
    ItermError::Other(format!("unexpected osascript output: {stdout:?}"))
}

pub fn parse_focus_output(output: &AppleScriptOutput) -> ItermResult<()> {
    if is_permission_denied(output) {
        return Err(ItermError::PermissionDenied);
    }
    if !output.success {
        return Err(ItermError::Other(output.stderr.trim().to_string()));
    }
    match output.stdout.trim() {
        "FOUND" => Ok(()),
        "NOTFOUND" => Err(ItermError::NoMatch),
        other => Err(bad_output(other)),
    }
}

pub fn parse_focused_output(output: &AppleScriptOutput) -> ItermResult<Option<String>> {
    if is_permission_denied(output) {
        return Err(ItermError::PermissionDenied);
    }
    if !output.success {
        return Err(ItermError::Other(output.stderr.trim().to_string()));
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
    // The target IS the bare UUID (§2) — no `wNtNpN` prefix to reassemble:
    // `focus` only ever looks at the UUID half anyway (§7-1), and iTerm2
    // can't give us a tab index (see `build_focused_script`).
    Ok(Some(uuid.to_string()))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProbeOutcome {
    /// iTerm2 isn't running, so permission couldn't be checked.
    NotRunning,
    /// iTerm2 answered a query: automation permission is granted.
    Granted,
}

pub fn parse_probe_output(output: &AppleScriptOutput) -> ItermResult<ProbeOutcome> {
    if is_permission_denied(output) {
        return Err(ItermError::PermissionDenied);
    }
    if !output.success {
        return Err(ItermError::Other(output.stderr.trim().to_string()));
    }
    if output.stdout.trim() == "NOT_RUNNING" {
        Ok(ProbeOutcome::NotRunning)
    } else {
        Ok(ProbeOutcome::Granted)
    }
}

pub fn parse_open_tab_output(output: &AppleScriptOutput) -> ItermResult<()> {
    if is_permission_denied(output) {
        return Err(ItermError::PermissionDenied);
    }
    if !output.success {
        return Err(ItermError::Other(output.stderr.trim().to_string()));
    }
    match output.stdout.trim() {
        "OK" => Ok(()),
        other => Err(bad_output(other)),
    }
}

// ---------------------------------------------------------------------
// Impure: wire pure generation/parsing to a runner
// ---------------------------------------------------------------------

/// `focus(target)` (DESIGN.md §4.3): jump to the iTerm2 session matching
/// `target`'s UUID half. `NoMatch` covers both "no such session found in
/// iTerm2" and "target isn't in the `wNtNpN:UUID` shape at all" (the
/// `session:` fallback target, or garbage input) — no osascript is run in
/// the latter case.
pub fn focus(target: &str, runner: &dyn AppleScriptRunner) -> ItermResult<()> {
    let uuid = extract_uuid(target).ok_or(ItermError::NoMatch)?;
    let script = build_focus_script(uuid);
    let output = runner
        .run(&script)
        .map_err(|e| ItermError::Other(e.to_string()))?;
    parse_focus_output(&output)
}

/// `focused()` (DESIGN.md §4.3): the frontmost iTerm2 session's target, if
/// iTerm2 is the frontmost application; `Ok(None)` otherwise.
pub fn focused(runner: &dyn AppleScriptRunner) -> ItermResult<Option<String>> {
    let output = runner
        .run(&build_focused_script())
        .map_err(|e| ItermError::Other(e.to_string()))?;
    parse_focused_output(&output)
}

/// Harmless iTerm2 probe for `shiibar-cc doctor`'s TCC permission check.
pub fn probe(runner: &dyn AppleScriptRunner) -> ItermResult<ProbeOutcome> {
    let output = runner
        .run(&build_probe_script())
        .map_err(|e| ItermError::Other(e.to_string()))?;
    parse_probe_output(&output)
}

/// `open_tab(cwd, cmd)` (DESIGN.md §4.3): open a new iTerm2 tab (or window)
/// in `cwd` and run `cmd` there. Used by `resume` (§4.4). Unlike `focus`,
/// this is allowed to launch iTerm2 if it isn't already running.
pub fn open_tab(cwd: &str, cmd: &str, runner: &dyn AppleScriptRunner) -> ItermResult<()> {
    let script = build_open_tab_script(cwd, cmd);
    let output = runner
        .run(&script)
        .map_err(|e| ItermError::Other(e.to_string()))?;
    parse_open_tab_output(&output)
}

// ---------------------------------------------------------------------
// iterm_targets: reconcile's pid -> target derivation (DESIGN.md §3.5/§4.3)
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

/// Normalize a tty path for comparison: `ps` prints it bare (`ttys003`),
/// iTerm2's AppleScript `tty of session` prints it with a `/dev/` prefix
/// (`/dev/ttys003`) — verified on a real machine 2026-07-04. Stripping the
/// prefix (if present) makes the two comparable regardless of source.
fn normalize_tty(tty: &str) -> &str {
    tty.strip_prefix("/dev/").unwrap_or(tty)
}

/// AppleScript that enumerates every iTerm2 session's `tty` and `id` (§3.5).
/// Same explicit-index-plus-`try` scanning pattern as `build_focus_script`
/// (§7-1: the plural `repeat with s in sessions of t` form intermittently
/// throws `-1719` on split-pane tabs) — a `try` failure here increments a
/// counter instead of aborting the whole scan, so one bad session doesn't
/// erase everything else that *did* enumerate cleanly. Output is one
/// `SESSION<TAB>tty<TAB>uuid` line per session found, followed by a final
/// `DONE<TAB><failure count>` line; `failures > 0` is the signal callers use
/// to treat the scan as incomplete (§3.5: skip pruning that round).
pub fn build_iterm_targets_script() -> String {
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

/// Parse `build_iterm_targets_script`'s output into `(tty, uuid)` pairs plus
/// whether the scan was complete (no `try` failures, §3.5).
pub fn parse_iterm_targets_output(output: &AppleScriptOutput) -> ItermResult<(Vec<(String, String)>, bool)> {
    if is_permission_denied(output) {
        return Err(ItermError::PermissionDenied);
    }
    if !output.success {
        return Err(ItermError::Other(output.stderr.trim().to_string()));
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

/// One pid -> target(bare UUID) mapping, plus whether the underlying scan
/// (both `ps` and the iTerm2 AppleScript enumeration) was complete enough to
/// trust for pruning (§3.5: reconcile only prunes when this is `true`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ItermTargets {
    pub targets: std::collections::HashMap<u32, String>,
    pub complete: bool,
}

/// `iterm_targets(pids)` (DESIGN.md §3.5/§4.3): resolve `claude agents`' pids
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
///   it *did* get).
pub fn iterm_targets(
    pids: &[u32],
    ps_runner: &dyn PsRunner,
    script_runner: &dyn AppleScriptRunner,
) -> ItermResult<ItermTargets> {
    if pids.is_empty() {
        return Ok(ItermTargets {
            targets: std::collections::HashMap::new(),
            complete: true,
        });
    }

    let (pid_tty, ps_ok) = match ps_runner.run(pids) {
        Ok(output) if output.success => (parse_ps_tty_output(&output.stdout), true),
        Ok(output) => (parse_ps_tty_output(&output.stdout), false),
        Err(_) => (std::collections::HashMap::new(), false),
    };

    let (sessions, scan_complete) = match script_runner.run(&build_iterm_targets_script()) {
        Ok(output) => match parse_iterm_targets_output(&output) {
            Ok(v) => v,
            Err(ItermError::PermissionDenied) => return Err(ItermError::PermissionDenied),
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
            targets.insert(pid, uuid.clone());
        }
    }

    Ok(ItermTargets {
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
    fn focus_script_only_activates_after_a_match_is_found() {
        let script = build_focus_script("SOME-UUID");
        let if_match = script.find("if sid is").unwrap();
        let activate = script.find("activate").unwrap();
        let found = script.find("\"FOUND\"").unwrap();
        assert!(
            if_match < activate,
            "activate must be inside the match branch"
        );
        assert!(activate < found, "activate must run before reporting FOUND");
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

    #[test]
    fn open_tab_script_activates_without_guarding_on_running() {
        // Unlike focus/probe, open_tab is allowed to launch iTerm2 (§4.3),
        // so there must be no `is running` guard before `activate`.
        let script = build_open_tab_script("/some/cwd", "claude --resume UUID");
        assert!(script.contains("activate"));
        assert!(!script.contains(r#"application "iTerm2" is running"#));
    }

    #[test]
    fn open_tab_script_creates_a_window_or_tab_and_writes_cd_then_cmd() {
        let script = build_open_tab_script("/some/cwd", "claude --resume UUID");
        assert!(script.contains("create window with default profile"));
        assert!(script.contains("create tab with default profile"));
        let cd_pos = script.find("write text \"cd \"").unwrap();
        let cmd_pos = script.find("claude --resume UUID").unwrap();
        assert!(cd_pos < cmd_pos, "cd must be written before the resume command");
        assert!(script.contains("quoted form of"));
        assert!(script.contains("/some/cwd"));
        assert!(script.contains("OK"));
    }

    #[test]
    fn open_tab_script_escapes_quotes_and_backslashes_in_cwd_and_cmd() {
        let script = build_open_tab_script(r#"/weird"path\"#, r#"cmd with "quotes" and \ backslash"#);
        assert!(script.contains(r#"/weird\"path\\"#));
        assert!(script.contains(r#"cmd with \"quotes\" and \\ backslash"#));
    }

    #[test]
    fn parse_open_tab_output_ok() {
        assert_eq!(parse_open_tab_output(&out(true, "OK\n", "")), Ok(()));
    }

    #[test]
    fn parse_open_tab_output_permission_denied() {
        let stderr = "Not authorized to send Apple events to iTerm2. (-1743)";
        assert_eq!(
            parse_open_tab_output(&out(false, "", stderr)),
            Err(ItermError::PermissionDenied)
        );
    }

    #[test]
    fn parse_open_tab_output_other_failure() {
        assert_eq!(
            parse_open_tab_output(&out(false, "", "some other osascript error")),
            Err(ItermError::Other("some other osascript error".to_string()))
        );
    }

    #[test]
    fn parse_open_tab_output_unexpected_stdout_is_an_error() {
        assert!(matches!(
            parse_open_tab_output(&out(true, "garbage", "")),
            Err(ItermError::Other(_))
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
            Err(ItermError::NoMatch)
        );
    }

    #[test]
    fn parse_focus_output_permission_denied() {
        let stderr = "execution error: iTerm2 got an error: Not authorized to send Apple events to iTerm2. (-1743)";
        assert_eq!(
            parse_focus_output(&out(false, "", stderr)),
            Err(ItermError::PermissionDenied)
        );
    }

    #[test]
    fn parse_focus_output_other_failure() {
        assert_eq!(
            parse_focus_output(&out(false, "", "some other osascript error")),
            Err(ItermError::Other("some other osascript error".to_string()))
        );
    }

    #[test]
    fn parse_focus_output_unexpected_stdout_is_an_error() {
        assert!(matches!(
            parse_focus_output(&out(true, "garbage", "")),
            Err(ItermError::Other(_))
        ));
    }

    #[test]
    fn parse_focused_output_none() {
        assert_eq!(parse_focused_output(&out(true, "NONE\n", "")), Ok(None));
    }

    #[test]
    fn parse_focused_output_returns_the_bare_uuid_as_target() {
        assert_eq!(
            parse_focused_output(&out(true, "FOCUSED:ABCD-1234\n", "")),
            Ok(Some("ABCD-1234".to_string()))
        );
    }

    #[test]
    fn parse_focused_output_permission_denied() {
        let stderr = "not authorized to send Apple events to System Events.";
        assert_eq!(
            parse_focused_output(&out(false, "", stderr)),
            Err(ItermError::PermissionDenied)
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
            Err(ItermError::PermissionDenied)
        );
    }

    // ---- fake runner: focus()/focused()/probe() wiring ----

    struct FakeRunner {
        output: AppleScriptOutput,
    }

    impl AppleScriptRunner for FakeRunner {
        fn run(&self, _script: &str) -> std::io::Result<AppleScriptOutput> {
            Ok(self.output.clone())
        }
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
        assert_eq!(result, Err(ItermError::NoMatch));
    }

    #[test]
    fn focus_success_end_to_end_with_fake_runner() {
        let runner = FakeRunner {
            output: out(true, "FOUND\n", ""),
        };
        assert_eq!(focus("w0t0p0:UUID", &runner), Ok(()));
    }

    #[test]
    fn focus_permission_denied_end_to_end_with_fake_runner() {
        let runner = FakeRunner {
            output: out(
                false,
                "",
                "Not authorized to send Apple events to iTerm2. (-1743)",
            ),
        };
        assert_eq!(
            focus("w0t0p0:UUID", &runner),
            Err(ItermError::PermissionDenied)
        );
    }

    #[test]
    fn focused_end_to_end_with_fake_runner() {
        let runner = FakeRunner {
            output: out(true, "FOCUSED:UUID\n", ""),
        };
        assert_eq!(focused(&runner), Ok(Some("UUID".to_string())));
    }

    #[test]
    fn probe_end_to_end_with_fake_runner() {
        let runner = FakeRunner {
            output: out(true, "NOT_RUNNING\n", ""),
        };
        assert_eq!(probe(&runner), Ok(ProbeOutcome::NotRunning));
    }

    #[test]
    fn open_tab_success_end_to_end_with_fake_runner() {
        let runner = FakeRunner {
            output: out(true, "OK\n", ""),
        };
        assert_eq!(open_tab("/proj/a", "claude --resume UUID", &runner), Ok(()));
    }

    #[test]
    fn open_tab_permission_denied_end_to_end_with_fake_runner() {
        let runner = FakeRunner {
            output: out(
                false,
                "",
                "Not authorized to send Apple events to iTerm2. (-1743)",
            ),
        };
        assert_eq!(
            open_tab("/proj/a", "claude --resume UUID", &runner),
            Err(ItermError::PermissionDenied)
        );
    }

    // ---- iterm_targets: build_iterm_targets_script / parsing ----

    #[test]
    fn iterm_targets_script_never_activates_and_guards_on_running() {
        let script = build_iterm_targets_script();
        assert!(!script.contains("activate"));
        assert!(script.contains(r#"application "iTerm2" is running"#));
        assert!(script.contains("DONE"));
    }

    #[test]
    fn iterm_targets_script_uses_explicit_index_and_try_like_focus() {
        // Same -1719 avoidance as build_focus_script (§7-1).
        let script = build_iterm_targets_script();
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
        let (sessions, complete) = parse_iterm_targets_output(&output).unwrap();
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
        let (sessions, complete) = parse_iterm_targets_output(&output).unwrap();
        assert_eq!(sessions.len(), 1);
        assert!(!complete, "a nonzero failure count must mark the scan incomplete");
    }

    #[test]
    fn parse_iterm_targets_output_iterm2_not_running_is_empty_and_complete() {
        let output = out(true, "DONE\t0\n", "");
        let (sessions, complete) = parse_iterm_targets_output(&output).unwrap();
        assert!(sessions.is_empty());
        assert!(complete, "no iTerm2 at all is zero sessions, not a failed scan");
    }

    #[test]
    fn parse_iterm_targets_output_permission_denied() {
        let stderr = "Not authorized to send Apple events to iTerm2. (-1743)";
        assert_eq!(
            parse_iterm_targets_output(&out(false, "", stderr)),
            Err(ItermError::PermissionDenied)
        );
    }

    // ---- iterm_targets: ps output parsing ----

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

    // ---- iterm_targets: end-to-end wiring with fake runners ----

    struct FakePs {
        output: PsOutput,
    }

    impl PsRunner for FakePs {
        fn run(&self, _pids: &[u32]) -> std::io::Result<PsOutput> {
            Ok(self.output.clone())
        }
    }

    #[test]
    fn iterm_targets_matches_pid_to_target_via_tty() {
        let ps = FakePs {
            output: PsOutput {
                success: true,
                stdout: "111 ttys000\n222 ttys003\n".to_string(),
            },
        };
        let script_runner = FakeRunner {
            output: out(
                true,
                "SESSION\t/dev/ttys000\tUUID-A\nSESSION\t/dev/ttys003\tUUID-B\nDONE\t0\n",
                "",
            ),
        };
        let result = iterm_targets(&[111, 222], &ps, &script_runner).unwrap();
        assert_eq!(result.targets.get(&111).map(String::as_str), Some("UUID-A"));
        assert_eq!(result.targets.get(&222).map(String::as_str), Some("UUID-B"));
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
        let script_runner = FakeRunner {
            output: out(true, "SESSION\t/dev/ttys000\tUUID-A\nDONE\t0\n", ""),
        };
        let result = iterm_targets(&[111], &ps, &script_runner).unwrap();
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
        let script_runner = FakeRunner {
            output: out(true, "SESSION\t/dev/ttys000\tUUID-A\nDONE\t1\n", ""),
        };
        let result = iterm_targets(&[111], &ps, &script_runner).unwrap();
        assert_eq!(result.targets.get(&111).map(String::as_str), Some("UUID-A"));
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
        let script_runner = FakeRunner {
            output: out(true, "SESSION\t/dev/ttys000\tUUID-A\nDONE\t0\n", ""),
        };
        let result = iterm_targets(&[111], &ps, &script_runner).unwrap();
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
        let script_runner = FakeRunner {
            output: out(
                false,
                "",
                "Not authorized to send Apple events to iTerm2. (-1743)",
            ),
        };
        assert_eq!(
            iterm_targets(&[111], &ps, &script_runner),
            Err(ItermError::PermissionDenied)
        );
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
        let result = iterm_targets(&[], &PanicPs, &PanicScript).unwrap();
        assert!(result.targets.is_empty());
        assert!(result.complete);
    }
}
