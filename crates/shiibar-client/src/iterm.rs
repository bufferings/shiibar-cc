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
/// distinction is required by DESIGN.md §4.4 (shiibarctl exit 2 vs. 3).
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

/// Extract the UUID portion of a target in the `wNtNpN:UUID` shape
/// (DESIGN.md §7-1, verified 2026-07-04: iTerm2's AppleScript `id of
/// session` is the bare UUID, and it matches the UUID half of
/// `$ITERM_SESSION_ID` for a plain — non-tmux — session). Anything else,
/// including the `session:<id>` fallback target used when
/// `$ITERM_SESSION_ID` was absent at report time, returns `None`: DESIGN.md
/// §4.3 calls this out explicitly as "no match", so it's handled here
/// rather than left to accidentally (mis)match a real session.
pub fn extract_uuid(target: &str) -> Option<&str> {
    let (prefix, uuid) = target.split_once(':')?;
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
/// and if found: selects its tab, brings its window to the front, and
/// activates iTerm2. Deliberately checks `application "iTerm2" is running`
/// first and only opens a `tell application "iTerm2"` block inside that
/// guard — this is what keeps `focus` from launching iTerm2 when it isn't
/// running (DESIGN.md §4.3: "if iTerm2 isn't running, return 'no match'
/// without launching it"; a bare `tell application "iTerm2"` would
/// auto-launch it). Prints
/// `FOUND` or `NOTFOUND` as the last line of stdout.
pub fn build_focus_script(uuid: &str) -> String {
    let uuid = escape_as_string_literal(uuid);
    format!(
        r#"if application "iTerm2" is running then
    tell application "iTerm2"
        repeat with w in windows
            repeat with t in tabs of w
                repeat with s in sessions of t
                    if id of s is "{uuid}" then
                        tell w to select
                        tell t to select
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
/// frontmost application. Prints `FOCUSED:<uuid>:<window index>:<tab
/// index>` or `NONE`.
pub fn build_focused_script() -> String {
    r#"if application "iTerm2" is running then
    tell application "System Events"
        set frontAppName to name of first application process whose frontmost is true
    end tell
    if frontAppName is "iTerm2" then
        tell application "iTerm2"
            set w to current window
            set t to current tab of w
            set s to current session of t
            return "FOCUSED:" & (id of s) & ":" & (index of w) & ":" & (index of t)
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

/// Harmless AppleScript used by `shiibarctl doctor` to check osascript's
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
    let Some(rest) = stdout.strip_prefix("FOCUSED:") else {
        return Err(bad_output(stdout));
    };
    let mut parts = rest.splitn(3, ':');
    let (Some(uuid), Some(win), Some(tab)) = (parts.next(), parts.next(), parts.next()) else {
        return Err(bad_output(stdout));
    };
    if uuid.is_empty() || win.parse::<u32>().is_err() || tab.parse::<u32>().is_err() {
        return Err(bad_output(stdout));
    }
    // Reassemble a target in the same `wNtNpN:UUID` shape `extract_uuid`
    // expects, so this can round-trip through `focus` later (e.g. for
    // `focus -`). The window/tab numbers are cosmetic here: `focus` only
    // ever looks at the UUID half (§7-1 — the w/t/p numbers in a real
    // $ITERM_SESSION_ID can go stale as tabs are reordered, so `focus`
    // never relies on them either).
    Ok(Some(format!("w{win}t{tab}p0:{uuid}")))
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

/// Harmless iTerm2 probe for `shiibarctl doctor`'s TCC permission check.
pub fn probe(runner: &dyn AppleScriptRunner) -> ItermResult<ProbeOutcome> {
    let output = runner
        .run(&build_probe_script())
        .map_err(|e| ItermError::Other(e.to_string()))?;
    parse_probe_output(&output)
}

#[cfg(test)]
mod tests {
    use super::*;

    // ---- extract_uuid ----

    #[test]
    fn extracts_uuid_from_well_formed_target() {
        assert_eq!(extract_uuid("w0t0p0:D2DA6A1F-TEST"), Some("D2DA6A1F-TEST"));
        assert_eq!(extract_uuid("w12t3p0:UUID-1"), Some("UUID-1"));
    }

    #[test]
    fn session_fallback_target_does_not_match() {
        assert_eq!(
            extract_uuid("session:11111111-1111-1111-1111-111111111111"),
            None
        );
    }

    #[test]
    fn malformed_targets_do_not_match() {
        assert_eq!(extract_uuid("no-colon-here"), None);
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
        let if_match = script.find("if id of s is").unwrap();
        let activate = script.find("activate").unwrap();
        let found = script.find("\"FOUND\"").unwrap();
        assert!(
            if_match < activate,
            "activate must be inside the match branch"
        );
        assert!(activate < found, "activate must run before reporting FOUND");
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
    fn parse_focused_output_reassembles_target() {
        assert_eq!(
            parse_focused_output(&out(true, "FOCUSED:ABCD-1234:2:3\n", "")),
            Ok(Some("w2t3p0:ABCD-1234".to_string()))
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
    fn focus_with_session_fallback_target_never_runs_osascript() {
        struct PanicRunner;
        impl AppleScriptRunner for PanicRunner {
            fn run(&self, _script: &str) -> std::io::Result<AppleScriptOutput> {
                panic!("osascript should not be invoked for a session: fallback target");
            }
        }
        let result = focus("session:11111111-1111-1111-1111-111111111111", &PanicRunner);
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
            output: out(true, "FOCUSED:UUID:1:1\n", ""),
        };
        assert_eq!(focused(&runner), Ok(Some("w1t1p0:UUID".to_string())));
    }

    #[test]
    fn probe_end_to_end_with_fake_runner() {
        let runner = FakeRunner {
            output: out(true, "NOT_RUNNING\n", ""),
        };
        assert_eq!(probe(&runner), Ok(ProbeOutcome::NotRunning));
    }
}
