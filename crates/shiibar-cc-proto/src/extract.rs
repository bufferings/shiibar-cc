//! Turn a raw Claude Code hook JSON payload into a `ReportPayload` (§4.1).
//!
//! Shared by `shiibar-cc report` (production) and shiibar-ccd's integration
//! tests (fixtures replay), so both exercise the exact same normalization
//! logic.

use crate::{HookEvent, NotificationType, ReportPayload, SessionStartSource};
use serde_json::Value;

/// prompt / task display truncation (§9): first 80 **characters**, not bytes.
pub const TASK_TRUNCATE_CHARS: usize = 80;

/// `last_assistant_message` display truncation (§9): first 200
/// **characters**, not bytes — same char-boundary care as `TASK_TRUNCATE_CHARS`.
pub const LAST_ASSISTANT_MESSAGE_TRUNCATE_CHARS: usize = 200;

/// A UserPromptSubmit whose prompt starts with this prefix is Claude Code's
/// automatic wake-up delivering a background-agent completion to the parent
/// session, not a user request (observed live 2026-07-05). It must drive
/// the status transition as usual but must NOT overwrite `task`
/// (DESIGN.md §3.6). Omitting the prompt from the payload here lets the
/// daemon's existing "task is only updated by prompt-carrying reports"
/// rule do the rest — the daemon stays untouched.
pub const TASK_NOTIFICATION_PREFIX: &str = "<task-notification>";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExtractError(pub String);

impl std::fmt::Display for ExtractError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl std::error::Error for ExtractError {}

/// The hook's terminal environment, as read by `shiibar-cc report` (§4.1).
/// These are the only inputs the target classification looks at besides the
/// ancestor walk's result; passing them in keeps `build_report` a pure fn.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct HookEnv<'a> {
    /// `$TERM_PROGRAM`.
    pub term_program: Option<&'a str>,
    /// `$TERM_PROGRAM_VERSION` (only consulted for Ghostty, §4.1).
    pub term_program_version: Option<&'a str>,
    /// `$ITERM_SESSION_ID` (shape `wNtNpN:UUID`, §7-1).
    pub iterm_session_id: Option<&'a str>,
}

/// The `entrypoint` value Claude Code records for a session started
/// non-interactively (`claude -p`): in the hook's `$CLAUDE_CODE_ENTRYPOINT`,
/// in `~/.claude/sessions/<pid>.json`, and on transcript lines (§7-13).
/// Such sessions are neither tracked nor listed as conversations (§8.67).
/// It is the only value treated this way: hiding a session whose value is
/// unknown would leave no visible reason why it is missing (§8.67).
pub const NON_INTERACTIVE_ENTRYPOINT: &str = "sdk-cli";

/// Whether an `entrypoint` value marks a session started non-interactively.
/// A missing, empty or any other value does not. For the hook this is
/// `$CLAUDE_CODE_ENTRYPOINT`, and a match drops every report before the
/// ancestor walk, SessionEnd included (§4.1); the reconcile gather applies
/// it to the sessions registry's value (§3.5). Takes the value rather than
/// reading the environment so the rule stays a pure function.
pub fn is_non_interactive_entrypoint(entrypoint: Option<&str>) -> bool {
    entrypoint == Some(NON_INTERACTIVE_ENTRYPOINT)
}

/// The first ancestor of the hook process that has a controlling terminal
/// (§4.1): in practice the `claude` process running the session. Its pid is
/// carried on every report as `pid` (§4.2) and keys `process:` targets; its
/// tty keys `apple-terminal:` and `ghostty:` targets (§2).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ControllingProcess {
    pub pid: u32,
    /// Absolute tty path (`/dev/ttysNNN`).
    pub tty: String,
}

/// Build the `report` wire payload for `event` from the raw hook JSON `raw`.
///
/// `controlling` is the result of the ancestor walk (§4.1), which runs for
/// every report regardless of the terminal. `None` means no ancestor with a
/// controlling terminal was found within the walk limit: the session has no
/// terminal (an editor extension, a background job, ...) and is not tracked
/// (§8.66), so this returns `Ok(None)` — "drop this report, don't send it" —
/// for every event except `SessionEnd`. Closing a terminal window detaches
/// the `claude` process from its terminal before its SessionEnd hook runs,
/// so that SessionEnd is still sent, without a target and without a pid,
/// whatever the environment claims; the daemon matches it by `session_id`
/// (§4.2).
///
/// Otherwise the report always has a target (see `derive_target` for the
/// rule) and always carries the controlling process's pid.
///
/// `now` is the report timestamp (epoch seconds) — display-only on the wire
/// (§3.6), supplied by the caller so this function stays a pure fn.
pub fn build_report(
    event: HookEvent,
    raw: &Value,
    env: &HookEnv<'_>,
    controlling: Option<&ControllingProcess>,
    now: i64,
) -> Result<Option<ReportPayload>, ExtractError> {
    let (target, pid) = match controlling {
        Some(controlling) => (Some(derive_target(env, controlling)), Some(controlling.pid)),
        None if event == HookEvent::SessionEnd => (None, None),
        None => return Ok(None),
    };

    let session_id = str_field(raw, "session_id")
        .filter(|s| !s.is_empty())
        .ok_or_else(|| ExtractError("hook JSON missing non-empty session_id".to_string()))?;
    let cwd = str_field(raw, "cwd")
        .filter(|s| !s.is_empty())
        .ok_or_else(|| ExtractError("hook JSON missing non-empty cwd".to_string()))?;
    let transcript_path = str_field(raw, "transcript_path");

    let source = parse_enum_field::<SessionStartSource>(raw, "source")?;
    let notification_type = parse_enum_field::<NotificationType>(raw, "notification_type")?;
    let message = str_field(raw, "message");
    // Task-notification wake-ups keep the event (status transition) but
    // drop the prompt (no task overwrite, §3.6).
    let prompt = str_field(raw, "prompt")
        .filter(|p| !p.starts_with(TASK_NOTIFICATION_PREFIX))
        .map(|p| truncate_chars(&p, TASK_TRUNCATE_CHARS));
    let background_tasks = raw
        .get("background_tasks")
        .and_then(|v| v.as_array())
        .cloned();
    // Markdown is stripped *before* the char truncation below (DESIGN.md
    // §4.1) so the 200-char budget is spent on display text, not markup.
    let last_assistant_message = str_field(raw, "last_assistant_message")
        .map(|m| truncate_chars(&strip_markdown(&m), LAST_ASSISTANT_MESSAGE_TRUNCATE_CHARS));

    Ok(Some(ReportPayload {
        event,
        target,
        session_id,
        cwd,
        transcript_path,
        ts: now,
        source,
        notification_type,
        message,
        prompt,
        background_tasks,
        last_assistant_message,
        pid,
    }))
}

/// The value of `$TERM_PROGRAM` that means "running directly inside iTerm2"
/// (§4.1/§7-1).
const ITERM_TERM_PROGRAM: &str = "iTerm.app";

/// The value of `$TERM_PROGRAM` that means "running directly inside
/// Terminal.app" (§4.1/§7-7).
const APPLE_TERMINAL_TERM_PROGRAM: &str = "Apple_Terminal";

/// The value of `$TERM_PROGRAM` that means "running directly inside
/// Ghostty" (§4.1/§7-8).
const GHOSTTY_TERM_PROGRAM: &str = "ghostty";

/// Minimum Ghostty version whose AppleScript `terminal` exposes `tty`
/// (§9/§7-8). Older Ghostty sessions get a `process:` target.
pub const GHOSTTY_MIN_VERSION: (u64, u64, u64) = (1, 4, 0);

/// Maximum number of ancestry hops the controlling-terminal walk takes
/// before giving up and dropping the report (§9: 10 steps; §4.1).
pub const MAX_ANCESTOR_WALK_STEPS: usize = 10;

/// Classify the session and derive its prefixed target — the sole place the
/// target-generation rule (§4.1/§2) is expressed. One of the three supported
/// terminals' targets when it can be derived, `process:<pid>` otherwise:
///
/// - **iTerm2** (`iterm2:<UUID>`): only when **both** `$TERM_PROGRAM ==
///   "iTerm.app"` **and** `$ITERM_SESSION_ID` (shape `wNtNpN:UUID`) has a
///   UUID after its `:`. The target is the `:`-onward UUID half only, so
///   `iterm2_targets` (reconcile, via AppleScript) lands on the same target
///   — AppleScript can't reproduce the `wNtNpN` prefix (§7-1).
///   `$ITERM_SESSION_ID` alone is not enough: apps launched from iTerm2
///   (e.g. VS Code's integrated terminal) inherit it while overwriting
///   `$TERM_PROGRAM`, so it would point at the launching tab (§7-1).
/// - **Terminal.app** (`apple-terminal:<tty path>`): `$TERM_PROGRAM ==
///   "Apple_Terminal"`; the tty is the ancestor walk's. `$TERM_SESSION_ID`
///   is not used (no AppleScript counterpart, §7-7).
/// - **Ghostty** (`ghostty:<tty path>`): `$TERM_PROGRAM == "ghostty"` **and**
///   `$TERM_PROGRAM_VERSION` at least `GHOSTTY_MIN_VERSION` (compared with
///   `parse_version_triple`); the tty is the ancestor walk's.
///   `$GHOSTTY_SURFACE_ID` is not used (it doesn't match AppleScript's `id`,
///   §7-8).
/// - Anything else (another or no `$TERM_PROGRAM`, iTerm.app without a usable
///   `$ITERM_SESSION_ID`, Ghostty with a missing, unparsable or too-old
///   version): `process:<pid>` with the walk's pid — tracked, but not
///   jumpable (§2/§8.66).
fn derive_target(env: &HookEnv<'_>, controlling: &ControllingProcess) -> String {
    match env.term_program {
        Some(ITERM_TERM_PROGRAM) => match iterm_uuid(env.iterm_session_id) {
            Some(uuid) => format!("iterm2:{uuid}"),
            None => process_target(controlling),
        },
        Some(APPLE_TERMINAL_TERM_PROGRAM) => format!("apple-terminal:{}", controlling.tty),
        Some(GHOSTTY_TERM_PROGRAM) if is_supported_ghostty(env.term_program_version) => {
            format!("ghostty:{}", controlling.tty)
        }
        _ => process_target(controlling),
    }
}

/// The non-empty UUID half (after the first `:`) of `$ITERM_SESSION_ID`.
fn iterm_uuid(iterm_session_id: Option<&str>) -> Option<&str> {
    iterm_session_id
        .and_then(|id| id.split_once(':'))
        .map(|(_position, uuid)| uuid)
        .filter(|uuid| !uuid.is_empty())
}

/// Whether `$TERM_PROGRAM_VERSION` names a Ghostty at or above
/// `GHOSTTY_MIN_VERSION`; a missing or unparsable version does not.
fn is_supported_ghostty(term_program_version: Option<&str>) -> bool {
    term_program_version
        .and_then(parse_version_triple)
        .is_some_and(|v| v >= GHOSTTY_MIN_VERSION)
}

fn process_target(controlling: &ControllingProcess) -> String {
    process_target_for_pid(controlling.pid)
}

/// The `process:<pid>` target (§2) for a session no supported terminal's
/// target could be derived for. Shared by the hook side (`build_report`,
/// keyed by the ancestor walk's pid — §4.1) and the reconcile gather (keyed
/// by the `claude agents` pid — §3.5), so both derive the same string for
/// the same `claude` process.
pub fn process_target_for_pid(pid: u32) -> String {
    format!("process:{pid}")
}

/// Parse a terminal version string as a `major.minor.patch` triple (§4.1):
/// only the part before the first `-` or `+` counts, so a non-release build
/// such as `1.4.0-main+abc1234` reads as `(1, 4, 0)`. Anything that isn't
/// exactly three dot-separated decimal numbers there yields `None`.
pub fn parse_version_triple(version: &str) -> Option<(u64, u64, u64)> {
    let core = version.split(['-', '+']).next().unwrap_or("");
    let mut parts = core.split('.');
    let mut number = || -> Option<u64> {
        let part = parts.next()?;
        if part.is_empty() || !part.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        part.parse().ok()
    };
    let triple = (number()?, number()?, number()?);
    parts.next().is_none().then_some(triple)
}

/// One process's parent pid and controlling tty, as seen by the ancestor
/// walk. Injected so `controlling_process_from_ancestor_walk` stays a pure
/// function (the real lookup — libproc — lives in `shiibar-cc report`, §4.1).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProcInfo {
    /// Parent process id.
    pub ppid: i32,
    /// Controlling tty as an absolute path (`/dev/ttysNNN`), or `None` when
    /// the process has no controlling terminal (`??` in `ps`, §7-7 — true of
    /// the hook process itself and of `report.sh`'s shell).
    pub tty: Option<String>,
}

/// Find the process a hook is running under by walking from `start_pid`
/// toward the process tree root, following each process's parent pid, and
/// returning the pid and controlling tty of the **first process that has a
/// controlling terminal** (§4.1). The hook process and its shell are
/// detached from the terminal, so the walk normally stops a couple of hops
/// up, at the `claude` process (§7-7/§7-8/§7-9). Bounded to
/// `MAX_ANCESTOR_WALK_STEPS` hops (§9); returns `None` — meaning "drop the
/// report" — if no controlling terminal is found within the limit, or if
/// the chain dead-ends (a process the lookup can't resolve, or reaching the
/// tree root).
pub fn controlling_process_from_ancestor_walk(
    start_pid: i32,
    lookup: impl Fn(i32) -> Option<ProcInfo>,
) -> Option<ControllingProcess> {
    let mut pid = start_pid;
    for _ in 0..MAX_ANCESTOR_WALK_STEPS {
        let info = lookup(pid)?;
        if let Some(tty) = info.tty.filter(|t| !t.is_empty()) {
            return Some(ControllingProcess {
                pid: u32::try_from(pid).ok()?,
                tty,
            });
        }
        // A non-positive or self-referential parent means we've hit the
        // tree root (pid 1 / 0) or a cycle — stop rather than loop.
        if info.ppid <= 0 || info.ppid == pid {
            return None;
        }
        pid = info.ppid;
    }
    None
}

fn str_field(raw: &Value, key: &str) -> Option<String> {
    raw.get(key).and_then(|v| v.as_str()).map(|s| s.to_string())
}

fn parse_enum_field<T: serde::de::DeserializeOwned>(
    raw: &Value,
    key: &str,
) -> Result<Option<T>, ExtractError> {
    match raw.get(key).and_then(|v| v.as_str()) {
        None => Ok(None),
        Some(s) => serde_json::from_value(Value::String(s.to_string()))
            .map(Some)
            .map_err(|e| ExtractError(format!("invalid {key}: {e}"))),
    }
}

fn truncate_chars(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}

/// Strip lightweight Markdown markup from `last_assistant_message` (§4.1):
/// the completion banner renders as raw text, so unstripped markup shows up
/// verbatim (observed live: `` All four links still return **`200`** — no
/// broken links ``).
///
/// Handled, content kept: backtick characters / `**` and `__` pairs / a
/// line-leading run of `#` followed by a space / `[text](url)` -> `text`.
/// Deliberately left alone: a solitary `*` or `_` (would misfire on
/// `snake_case` identifiers and file paths) and an unclosed `**`/`__` (no
/// closing pair to guess at, so it's left in place — §4.1: "leaving markup
/// behind is fine, breaking the text is not").
fn strip_markdown(s: &str) -> String {
    let no_backticks: String = s.chars().filter(|&c| c != '`').collect();
    let no_headings = strip_heading_markers(&no_backticks);
    let no_bold = strip_paired_delimiter(&no_headings, "**");
    let no_underline = strip_paired_delimiter(&no_bold, "__");
    strip_links(&no_underline)
}

/// Remove a line-leading heading marker (a run of `#` immediately followed
/// by a space) from every line, keeping any leading whitespace before the
/// `#` run and everything after the marker's space untouched.
fn strip_heading_markers(s: &str) -> String {
    s.split('\n')
        .map(strip_heading_marker_from_line)
        .collect::<Vec<_>>()
        .join("\n")
}

fn strip_heading_marker_from_line(line: &str) -> String {
    let trimmed = line.trim_start();
    let leading_ws_len = line.len() - trimmed.len();
    let hash_len = trimmed.chars().take_while(|&c| c == '#').count();
    if hash_len == 0 {
        return line.to_string();
    }
    match trimmed[hash_len..].strip_prefix(' ') {
        Some(rest) => format!("{}{}", &line[..leading_ws_len], rest),
        // A `#` run with no following space isn't a heading marker (e.g. a
        // hashtag-like `#foo`) — leave the line untouched.
        None => line.to_string(),
    }
}

/// Remove matched pairs of `delim` (e.g. `**`), keeping the text between
/// each pair. An occurrence with no later matching `delim` is a solitary,
/// unclosed marker and is left untouched — along with everything after it,
/// since there's nothing left to pair it with.
fn strip_paired_delimiter(s: &str, delim: &str) -> String {
    let mut result = String::with_capacity(s.len());
    let mut rest = s;
    loop {
        let Some(open_idx) = rest.find(delim) else {
            result.push_str(rest);
            return result;
        };
        let after_open = &rest[open_idx + delim.len()..];
        let Some(close_idx) = after_open.find(delim) else {
            // No closing delimiter anywhere in the remainder: leave this
            // occurrence (and the rest of the string) as-is.
            result.push_str(rest);
            return result;
        };
        result.push_str(&rest[..open_idx]);
        result.push_str(&after_open[..close_idx]);
        rest = &after_open[close_idx + delim.len()..];
    }
}

/// Rewrite `[text](url)` to `text`. A `[` that isn't part of a well-formed
/// link (no matching `]`, or no `(url)` immediately after) is left in
/// place, and scanning resumes right after it.
fn strip_links(s: &str) -> String {
    let mut result = String::with_capacity(s.len());
    let mut rest = s;
    loop {
        let Some(open_idx) = rest.find('[') else {
            result.push_str(rest);
            return result;
        };
        let after_open = &rest[open_idx + 1..];
        let Some(text_end) = after_open.find(']') else {
            result.push_str(rest);
            return result;
        };
        let link_text = &after_open[..text_end];
        let after_text = &after_open[text_end + 1..];
        let Some(after_paren_open) = after_text.strip_prefix('(') else {
            // "[...]" not followed by "(": not a link. Keep the "[" and
            // resume scanning right after it.
            result.push_str(&rest[..open_idx + 1]);
            rest = after_open;
            continue;
        };
        let Some(url_end) = after_paren_open.find(')') else {
            result.push_str(&rest[..open_idx + 1]);
            rest = after_open;
            continue;
        };
        result.push_str(&rest[..open_idx]);
        result.push_str(link_text);
        rest = &after_paren_open[url_end + 1..];
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// The controlling process the ancestor walk is assumed to have found
    /// (the `claude` process): pid 48213 on `/dev/ttys005`.
    fn claude() -> ControllingProcess {
        ControllingProcess { pid: 48213, tty: "/dev/ttys005".into() }
    }

    const ITERM_ENV: HookEnv<'static> = HookEnv {
        term_program: Some("iTerm.app"),
        term_program_version: None,
        iterm_session_id: Some("w0t0p0:UUID"),
    };

    fn env<'a>(
        term_program: Option<&'a str>,
        term_program_version: Option<&'a str>,
        iterm_session_id: Option<&'a str>,
    ) -> HookEnv<'a> {
        HookEnv { term_program, term_program_version, iterm_session_id }
    }

    /// The target `build_report` derives for `env` when the walk found `claude()`.
    fn target_for(env: HookEnv<'_>) -> String {
        let raw = json!({"session_id": "s1", "cwd": "/c"});
        build_report(HookEvent::SessionStart, &raw, &env, Some(&claude()), 100)
            .unwrap()
            .expect("a report with a controlling process must not be dropped")
            .target
            .expect("a report with a controlling process has a target")
    }

    // Non-interactive sessions (§4.1/§8.67).

    #[test]
    fn sdk_cli_entrypoint_is_non_interactive() {
        assert!(is_non_interactive_entrypoint(Some("sdk-cli")));
    }

    #[test]
    fn missing_empty_and_other_entrypoints_are_not_non_interactive() {
        for value in [
            None,
            Some(""),
            Some("cli"),
            Some("claude-vscode"),
            Some("some-future-entrypoint"),
            Some("SDK-CLI"),
            Some(" sdk-cli"),
        ] {
            assert!(!is_non_interactive_entrypoint(value), "{value:?}");
        }
    }

    // Target generation (§4.1/§2).

    #[test]
    fn iterm2_with_a_session_id_uses_the_uuid_half_as_target() {
        assert_eq!(target_for(ITERM_ENV), "iterm2:UUID");
    }

    #[test]
    fn iterm2_target_ignores_the_walked_tty() {
        // The iTerm2 key is the session UUID, never the tty (§2).
        assert_eq!(
            target_for(env(Some("iTerm.app"), Some("3.7.6"), Some("w0t0p0:UUID"))),
            "iterm2:UUID"
        );
    }

    #[test]
    fn iterm2_without_a_session_id_falls_back_to_the_process_target() {
        // §4.1: iTerm.app with no usable $ITERM_SESSION_ID is tracked by pid
        // instead of being dropped.
        assert_eq!(target_for(env(Some("iTerm.app"), None, None)), "process:48213");
    }

    #[test]
    fn iterm2_with_an_empty_session_id_falls_back_to_the_process_target() {
        assert_eq!(target_for(env(Some("iTerm.app"), None, Some(""))), "process:48213");
    }

    #[test]
    fn iterm2_with_a_session_id_without_a_colon_falls_back_to_the_process_target() {
        // Not the documented wNtNpN:UUID shape (§7-1): no UUID half to use.
        assert_eq!(
            target_for(env(Some("iTerm.app"), None, Some("no-colon-here"))),
            "process:48213"
        );
    }

    #[test]
    fn iterm2_with_an_empty_uuid_half_falls_back_to_the_process_target() {
        assert_eq!(target_for(env(Some("iTerm.app"), None, Some("w0t0p0:"))), "process:48213");
    }

    #[test]
    fn inherited_iterm_session_id_under_vscode_is_not_an_iterm2_target() {
        // §4.1/§7-1: VS Code's integrated terminal, launched from an iTerm2
        // tab, inherits that tab's $ITERM_SESSION_ID but overwrites
        // $TERM_PROGRAM — it must not be classified as the iTerm2 tab.
        assert_eq!(
            target_for(env(Some("vscode"), Some("1.100.0"), Some("w0t0p0:UUID"))),
            "process:48213"
        );
    }

    #[test]
    fn inherited_iterm_session_id_without_term_program_is_not_an_iterm2_target() {
        assert_eq!(target_for(env(None, None, Some("w0t0p0:UUID"))), "process:48213");
    }

    #[test]
    fn apple_terminal_uses_the_walked_tty_as_target() {
        assert_eq!(
            target_for(env(Some("Apple_Terminal"), Some("455"), None)),
            "apple-terminal:/dev/ttys005"
        );
    }

    #[test]
    fn ghostty_at_or_above_the_minimum_version_uses_the_walked_tty_as_target() {
        for version in ["1.4.0", "1.4.1", "1.10.0", "2.0.0"] {
            assert_eq!(
                target_for(env(Some("ghostty"), Some(version), None)),
                "ghostty:/dev/ttys005",
                "version {version}"
            );
        }
    }

    #[test]
    fn ghostty_non_release_builds_compare_only_the_part_before_dash_or_plus() {
        // §4.1/§7-8: non-release builds report `X.Y.Z-<branch>+<short hash>`.
        for (version, expected) in [
            ("1.4.0-main+abc1234", "ghostty:/dev/ttys005"),
            ("1.4.0-dev+0000000", "ghostty:/dev/ttys005"),
            ("1.4.0+abc1234", "ghostty:/dev/ttys005"),
            ("1.3.1-main+abc1234", "process:48213"),
        ] {
            assert_eq!(target_for(env(Some("ghostty"), Some(version), None)), expected, "version {version}");
        }
    }

    #[test]
    fn ghostty_below_the_minimum_version_falls_back_to_the_process_target() {
        // §7-8: Ghostty 1.3.x has no `tty` on its AppleScript `terminal`.
        for version in ["1.3.0", "1.3.1", "0.9.9"] {
            assert_eq!(
                target_for(env(Some("ghostty"), Some(version), None)),
                "process:48213",
                "version {version}"
            );
        }
    }

    #[test]
    fn ghostty_without_a_version_falls_back_to_the_process_target() {
        assert_eq!(target_for(env(Some("ghostty"), None, None)), "process:48213");
    }

    #[test]
    fn ghostty_with_an_unparsable_version_falls_back_to_the_process_target() {
        for version in ["", "tip", "1.4", "1.4.0.1", "v1.4.0", "1.x.0", "1..0", " 1.4.0"] {
            assert_eq!(
                target_for(env(Some("ghostty"), Some(version), None)),
                "process:48213",
                "version {version:?}"
            );
        }
    }

    #[test]
    fn other_or_missing_term_program_falls_back_to_the_process_target() {
        for term_program in [Some("vscode"), Some("WezTerm"), Some("some-future-terminal"), Some(""), None] {
            assert_eq!(
                target_for(env(term_program, None, None)),
                "process:48213",
                "TERM_PROGRAM {term_program:?}"
            );
        }
    }

    #[test]
    fn every_report_carries_the_walked_pid_whatever_the_target() {
        // §4.1/§4.2: the pid is sent regardless of the target kind.
        let raw = json!({"session_id": "s1", "cwd": "/c"});
        for env in [
            ITERM_ENV,
            env(Some("Apple_Terminal"), None, None),
            env(Some("ghostty"), Some("1.4.0"), None),
            env(Some("ghostty"), Some("1.3.1"), None),
            env(Some("vscode"), None, None),
            env(None, None, None),
        ] {
            let r = build_report(HookEvent::Stop, &raw, &env, Some(&claude()), 1)
                .unwrap()
                .expect("not dropped");
            assert_eq!(r.pid, Some(48213), "env {env:?}");
        }
    }

    /// Every environment the target classification distinguishes, for the
    /// cases where the ancestor walk found no controlling terminal.
    fn every_term_program_env() -> [HookEnv<'static>; 7] {
        [
            ITERM_ENV,
            env(Some("iTerm.app"), None, None),
            env(Some("Apple_Terminal"), Some("455"), None),
            env(Some("ghostty"), Some("1.4.0"), None),
            env(Some("ghostty"), Some("1.3.1"), None),
            env(Some("vscode"), None, None),
            env(None, None, None),
        ]
    }

    const EVENTS_OTHER_THAN_SESSION_END: [HookEvent; 6] = [
        HookEvent::SessionStart,
        HookEvent::UserPromptSubmit,
        HookEvent::PostToolUse,
        HookEvent::PostToolUseFailure,
        HookEvent::Notification,
        HookEvent::Stop,
    ];

    #[test]
    fn no_controlling_process_drops_every_event_but_session_end_for_every_term_program() {
        // §4.1/§8.66: a session with no terminal anywhere up the walk is not
        // tracked, whichever terminal the environment claims.
        let raw = json!({"session_id": "s1", "cwd": "/c", "prompt": "p", "background_tasks": []});
        for env in every_term_program_env() {
            for event in EVENTS_OTHER_THAN_SESSION_END {
                let r = build_report(event, &raw, &env, None, 1).unwrap();
                assert_eq!(r, None, "event {event:?}, env {env:?}");
            }
        }
    }

    #[test]
    fn no_controlling_process_still_sends_session_end_without_target_or_pid_for_every_term_program() {
        // A closed terminal window detaches the claude process from its
        // terminal before its SessionEnd hook runs, so the walk finds
        // nothing; the SessionEnd is still sent so the daemon can remove the
        // entry by session_id (§4.2). The environment (iTerm2 variables
        // included) is not used to invent a target.
        let raw = json!({
            "session_id": "s1",
            "cwd": "/c",
            "transcript_path": "/c/t.jsonl",
            "reason": "other"
        });
        for env in every_term_program_env() {
            let r = build_report(HookEvent::SessionEnd, &raw, &env, None, 7)
                .unwrap()
                .unwrap_or_else(|| panic!("SessionEnd must not be dropped, env {env:?}"));
            assert_eq!(
                r,
                ReportPayload {
                    event: HookEvent::SessionEnd,
                    target: None,
                    session_id: "s1".into(),
                    cwd: "/c".into(),
                    transcript_path: Some("/c/t.jsonl".into()),
                    ts: 7,
                    source: None,
                    notification_type: None,
                    message: None,
                    prompt: None,
                    background_tasks: None,
                    last_assistant_message: None,
                    pid: None,
                },
                "env {env:?}"
            );
        }
    }

    #[test]
    fn targetless_session_end_still_requires_a_session_id() {
        // Without a session_id the daemon could not match the entry.
        let raw = json!({"cwd": "/c"});
        assert!(build_report(HookEvent::SessionEnd, &raw, &ITERM_ENV, None, 1).is_err());
    }

    #[test]
    fn session_end_with_a_controlling_process_keeps_its_target_and_pid() {
        let raw = json!({"session_id": "s1", "cwd": "/c"});
        let r = build_report(HookEvent::SessionEnd, &raw, &ITERM_ENV, Some(&claude()), 1)
            .unwrap()
            .unwrap();
        assert_eq!(r.target.as_deref(), Some("iterm2:UUID"));
        assert_eq!(r.pid, Some(48213));
    }

    #[test]
    fn parse_version_triple_reads_release_and_non_release_versions() {
        assert_eq!(parse_version_triple("1.4.0"), Some((1, 4, 0)));
        assert_eq!(parse_version_triple("1.4.0-main+abc1234"), Some((1, 4, 0)));
        assert_eq!(parse_version_triple("1.3.1"), Some((1, 3, 1)));
        assert_eq!(parse_version_triple("10.20.30+meta"), Some((10, 20, 30)));
        assert_eq!(parse_version_triple("1.4"), None);
        assert_eq!(parse_version_triple("1.4.0.0"), None);
        assert_eq!(parse_version_triple("-1.4.0"), None);
        assert_eq!(parse_version_triple(""), None);
    }

    #[test]
    fn truncates_prompt_to_80_chars_by_char_not_byte() {
        // multi-byte chars: naive byte-slicing at 80 could split a codepoint.
        let long_prompt: String = "€".repeat(100);
        let raw = json!({"session_id": "s1", "cwd": "/c", "prompt": long_prompt});
        let r = build_report(HookEvent::UserPromptSubmit, &raw, &ITERM_ENV, Some(&claude()), 1)
            .unwrap()
            .unwrap();
        assert_eq!(r.prompt.unwrap().chars().count(), 80);
    }

    #[test]
    fn task_notification_prompt_is_omitted_from_the_payload() {
        // §3.6: a background-agent completion wake-up must not overwrite
        // `task`; the extraction drops the prompt so the daemon's
        // prompt-carrying rule leaves the previous task alone.
        let raw = json!({
            "session_id": "s1",
            "cwd": "/c",
            "prompt": "<task-notification>Background agent finished: build the docs"
        });
        let r = build_report(HookEvent::UserPromptSubmit, &raw, &ITERM_ENV, Some(&claude()), 1)
            .unwrap()
            .unwrap();
        assert_eq!(r.prompt, None, "task-notification prompt must be omitted");
        assert_eq!(r.event, HookEvent::UserPromptSubmit, "the event itself still goes through");
    }

    #[test]
    fn ordinary_prompt_is_still_carried() {
        let raw = json!({"session_id": "s1", "cwd": "/c", "prompt": "implement the thing"});
        let r = build_report(HookEvent::UserPromptSubmit, &raw, &ITERM_ENV, Some(&claude()), 1)
            .unwrap()
            .unwrap();
        assert_eq!(r.prompt.as_deref(), Some("implement the thing"));
    }

    #[test]
    fn task_notification_prefix_must_be_at_the_start_to_count() {
        // A user prompt that merely mentions the tag mid-text is a real
        // request and must keep its prompt.
        let raw = json!({"session_id": "s1", "cwd": "/c",
            "prompt": "explain what <task-notification> means"});
        let r = build_report(HookEvent::UserPromptSubmit, &raw, &ITERM_ENV, Some(&claude()), 1)
            .unwrap()
            .unwrap();
        assert!(r.prompt.is_some());
    }

    #[test]
    fn missing_session_id_is_an_error() {
        let raw = json!({"cwd": "/c"});
        assert!(build_report(HookEvent::SessionStart, &raw, &ITERM_ENV, Some(&claude()), 1).is_err());
    }

    #[test]
    fn unknown_notification_type_becomes_unknown_variant() {
        let raw = json!({"session_id": "s1", "cwd": "/c", "notification_type": "totally_new"});
        let r = build_report(HookEvent::Notification, &raw, &ITERM_ENV, Some(&claude()), 1)
            .unwrap()
            .unwrap();
        assert_eq!(r.notification_type, Some(NotificationType::Unknown));
    }

    #[test]
    fn background_tasks_array_is_passed_through_opaquely() {
        let raw = json!({"session_id": "s1", "cwd": "/c", "background_tasks": [{"id":"1","status":"running"}]});
        let r = build_report(HookEvent::Stop, &raw, &ITERM_ENV, Some(&claude()), 1)
            .unwrap()
            .unwrap();
        assert_eq!(r.background_tasks.unwrap().len(), 1);
    }

    #[test]
    fn missing_background_tasks_is_none() {
        let raw = json!({"session_id": "s1", "cwd": "/c"});
        let r = build_report(HookEvent::Stop, &raw, &ITERM_ENV, Some(&claude()), 1)
            .unwrap()
            .unwrap();
        assert_eq!(r.background_tasks, None);
    }

    #[test]
    fn last_assistant_message_is_extracted_and_truncated_to_200_chars_by_char_not_byte() {
        // multi-byte chars: naive byte-slicing at 200 could split a codepoint
        // (same care as the 80-char prompt truncation above).
        let long_message: String = "€".repeat(300);
        let raw = json!({"session_id": "s1", "cwd": "/c", "last_assistant_message": long_message});
        let r = build_report(HookEvent::Stop, &raw, &ITERM_ENV, Some(&claude()), 1)
            .unwrap()
            .unwrap();
        assert_eq!(r.last_assistant_message.unwrap().chars().count(), 200);
    }

    #[test]
    fn missing_last_assistant_message_is_none() {
        let raw = json!({"session_id": "s1", "cwd": "/c"});
        let r = build_report(HookEvent::Stop, &raw, &ITERM_ENV, Some(&claude()), 1)
            .unwrap()
            .unwrap();
        assert_eq!(r.last_assistant_message, None);
    }

    /// Real captured payload (fixtures/stop_no_background_tasks.json, §7-3):
    /// the extraction must pull `last_assistant_message` out and pass it
    /// through unchanged (it's well under the 200-char cap).
    #[test]
    fn extracts_last_assistant_message_from_the_real_stop_fixture() {
        let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../fixtures/stop_no_background_tasks.json");
        let contents = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("failed to read fixture {}: {e}", path.display()));
        let raw: Value = serde_json::from_str(&contents).unwrap();
        let r = build_report(HookEvent::Stop, &raw, &ITERM_ENV, Some(&claude()), 1)
            .unwrap()
            .unwrap();
        assert_eq!(
            r.last_assistant_message.as_deref(),
            Some(
                "Here is the project root listing:\n\nCLAUDE.md\nCargo.lock\nCargo.toml\napp\ncrates\ndocs\nfixtures\nhooks\nrust-toolchain.toml\nscripts\ntarget\n\nLet me know if you want the contents of any subdirectory."
            )
        );
        assert_eq!(r.background_tasks.as_ref().map(|v| v.is_empty()), Some(true));
    }

    // strip_markdown (§4.1) — pure-function unit tests.

    #[test]
    fn strip_markdown_removes_backticks_and_bold_around_the_observed_example() {
        // Real dogfooding observation (DESIGN.md §4.1 / M10 brief): the
        // banner renders raw text, so `**`/backticks showed through verbatim.
        let input = "All four links still return **`200`** — no broken links";
        assert_eq!(
            strip_markdown(input),
            "All four links still return 200 — no broken links"
        );
    }

    #[test]
    fn strip_markdown_removes_heading_markers_across_multiple_lines() {
        let input = "# Summary\n\n## Details\nEverything passed.\n### Nested ### still trimmed only at line start";
        assert_eq!(
            strip_markdown(input),
            "Summary\n\nDetails\nEverything passed.\nNested ### still trimmed only at line start"
        );
    }

    #[test]
    fn strip_markdown_rewrites_markdown_links_to_their_text() {
        let input = "See [the docs](https://example.invalid/docs) for details.";
        assert_eq!(strip_markdown(input), "See the docs for details.");
    }

    #[test]
    fn strip_markdown_leaves_an_unclosed_bold_marker_untouched() {
        // §4.1: a solitary, unclosed `**`/`__` is left as-is rather than guessed at.
        let input = "Started **bold but never closed";
        assert_eq!(strip_markdown(input), input);
    }

    #[test]
    fn strip_markdown_does_not_touch_solitary_asterisks_or_underscores() {
        // §4.1: single `*`/`_` must survive untouched — snake_case identifiers,
        // paths, and single-star emphasis are not markup this function handles.
        let input = "Renamed foo_bar_baz.rs and passed *args through the call";
        assert_eq!(strip_markdown(input), input);
    }

    #[test]
    fn strip_markdown_leaves_ordinary_text_with_no_markup_unchanged() {
        let input = "Done. All 54 tests pass.";
        assert_eq!(strip_markdown(input), input);
    }

    #[test]
    fn last_assistant_message_markdown_is_stripped_before_the_200_char_truncation() {
        // Build a message that is over the 200-char cap *with* its markup but
        // exactly 200 chars once the `**` pair is stripped. If truncation ran
        // first, the closing `**` would be cut off, leaving a stray, now-unclosed
        // `**` prefix behind and only 198 of the 200 inner characters.
        let raw_message = format!("**{}**", "a".repeat(200));
        let raw = json!({"session_id": "s1", "cwd": "/c", "last_assistant_message": raw_message});
        let r = build_report(HookEvent::Stop, &raw, &ITERM_ENV, Some(&claude()), 1)
            .unwrap()
            .unwrap();
        assert_eq!(r.last_assistant_message.as_deref(), Some("a".repeat(200).as_str()));
    }

    // controlling_process_from_ancestor_walk (§4.1) — pure-function unit
    // tests. The process table is injected as a map, so no real process is
    // inspected.

    use std::collections::HashMap;

    fn walk(table: &HashMap<i32, ProcInfo>, start: i32) -> Option<ControllingProcess> {
        controlling_process_from_ancestor_walk(start, |pid| table.get(&pid).cloned())
    }

    fn found(pid: u32, tty: &str) -> Option<ControllingProcess> {
        Some(ControllingProcess { pid, tty: tty.into() })
    }

    #[test]
    fn ancestor_walk_returns_the_pid_and_tty_of_the_first_ancestor_with_a_controlling_tty() {
        // §7-7 chain: hook sh (no tty) -> claude (ttys006) -> zsh -> ...
        let table = HashMap::from([
            (100, ProcInfo { ppid: 90, tty: None }), // the hook process itself
            (90, ProcInfo { ppid: 80, tty: None }),  // report.sh's shell (??)
            (80, ProcInfo { ppid: 70, tty: Some("/dev/ttys006".into()) }), // claude
            (70, ProcInfo { ppid: 1, tty: Some("/dev/ttys006".into()) }),  // zsh
        ]);
        assert_eq!(walk(&table, 100), found(80, "/dev/ttys006"));
    }

    #[test]
    fn ancestor_walk_from_a_nested_claude_reaches_the_parent_claude() {
        // §4.1/§7-9: a `claude -p` started by a running session's Bash tool
        // has no controlling terminal either, so the walk passes through it
        // and takes the parent `claude`'s pid and tty.
        let table = HashMap::from([
            (500, ProcInfo { ppid: 490, tty: None }), // the child's hook process
            (490, ProcInfo { ppid: 480, tty: None }), // the child's hook shell
            (480, ProcInfo { ppid: 470, tty: None }), // child claude -p
            (470, ProcInfo { ppid: 460, tty: None }), // Bash tool shell
            (460, ProcInfo { ppid: 450, tty: Some("/dev/ttys005".into()) }), // parent claude
            (450, ProcInfo { ppid: 1, tty: Some("/dev/ttys005".into()) }),   // login shell
        ]);
        assert_eq!(walk(&table, 500), found(460, "/dev/ttys005"));
    }

    #[test]
    fn ancestor_walk_uses_the_start_process_tty_when_it_already_has_one() {
        let table = HashMap::from([(80, ProcInfo { ppid: 70, tty: Some("/dev/ttys006".into()) })]);
        assert_eq!(walk(&table, 80), found(80, "/dev/ttys006"));
    }

    #[test]
    fn ancestor_walk_drops_when_the_chain_reaches_the_tree_root_without_a_tty() {
        // Every ancestor detached from a terminal, up to launchd (ppid 0).
        let table = HashMap::from([
            (100, ProcInfo { ppid: 50, tty: None }),
            (50, ProcInfo { ppid: 1, tty: None }),
            (1, ProcInfo { ppid: 0, tty: None }),
        ]);
        assert_eq!(walk(&table, 100), None);
    }

    #[test]
    fn ancestor_walk_drops_when_the_lookup_cannot_resolve_a_pid() {
        // A dead-end (reparented / exited ancestor the lookup can't see):
        // stop and drop rather than guess.
        let table = HashMap::from([(100, ProcInfo { ppid: 999, tty: None })]);
        assert_eq!(walk(&table, 100), None);
    }

    #[test]
    fn ancestor_walk_drops_when_no_tty_is_found_within_the_step_limit() {
        // A chain longer than MAX_ANCESTOR_WALK_STEPS where the tty only
        // appears past the limit: the walk gives up (drop) before reaching it.
        let mut table = HashMap::new();
        let deep_tty_pid = MAX_ANCESTOR_WALK_STEPS as i32 + 5;
        for pid in 1..=deep_tty_pid {
            let tty = (pid == deep_tty_pid).then(|| "/dev/ttys006".to_string());
            table.insert(pid, ProcInfo { ppid: pid + 1, tty });
        }
        assert_eq!(
            walk(&table, 1),
            None,
            "a tty beyond the {MAX_ANCESTOR_WALK_STEPS}-hop limit must not be found"
        );
    }

    #[test]
    fn ancestor_walk_finds_a_tty_exactly_at_the_step_limit() {
        // Boundary: a tty on the process reached by the last allowed hop is
        // still found (the limit is inclusive of that many lookups).
        let mut table = HashMap::new();
        for step in 0..MAX_ANCESTOR_WALK_STEPS {
            let pid = step as i32 + 1;
            let is_last = step == MAX_ANCESTOR_WALK_STEPS - 1;
            let tty = is_last.then(|| "/dev/ttys006".to_string());
            table.insert(pid, ProcInfo { ppid: pid + 1, tty });
        }
        assert_eq!(walk(&table, 1), found(MAX_ANCESTOR_WALK_STEPS as u32, "/dev/ttys006"));
    }

    #[test]
    fn ancestor_walk_stops_on_a_self_referential_parent() {
        let table = HashMap::from([(100, ProcInfo { ppid: 100, tty: None })]);
        assert_eq!(walk(&table, 100), None);
    }
}
