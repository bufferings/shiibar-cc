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

/// Build the `report` wire payload for `event` from the raw hook JSON `raw`.
///
/// Target generation has two branches (§4.1), both yielding a prefixed,
/// opaque target (§2):
///
/// - **iTerm2** (`iterm2:<UUID>`): a session is only ever an iTerm2 session
///   when **both** `$TERM_PROGRAM == "iTerm.app"` **and** `$ITERM_SESSION_ID`
///   (shape `wNtNpN:UUID`) are present — the target is the **`:` -onward
///   UUID** half only (not the whole `$ITERM_SESSION_ID` string), so
///   `iterm2_targets` (reconcile, derived independently via AppleScript)
///   lands on the same target for the same session — AppleScript can't
///   reproduce the `wNtNpN` position prefix (§7-1). `$ITERM_SESSION_ID`
///   alone is not enough: iTerm2 launches other apps (e.g. VS Code's
///   integrated terminal) that inherit the whole environment,
///   `$ITERM_SESSION_ID` included, while overwriting `$TERM_PROGRAM` with
///   their own value (`vscode`, ...); checking `$ITERM_SESSION_ID` alone
///   would misclassify that inherited session as the launching iTerm2 tab
///   (observed live 2026-07-05, §7-1).
/// - **Terminal.app** (`apple-terminal:<tty path>`): when `$TERM_PROGRAM ==
///   "Apple_Terminal"`. The tty can't be read from the hook process itself
///   (it's detached from the terminal — `??` in `ps`, §7-7); the caller
///   resolves it by walking the process ancestry (see
///   `tty_from_ancestor_walk`) and passes it in as `apple_terminal_tty`
///   (already the absolute `/dev/ttysNNN` path, §2). `$TERM_SESSION_ID` is
///   used neither for detection nor as the target — it has no AppleScript
///   counterpart (§7-7). If no tty could be resolved, `apple_terminal_tty`
///   is `None` and this branch drops the report.
///
/// A session that matches neither branch (or matches Apple_Terminal but has
/// no resolvable tty) can never be focused, so it isn't tracked at all
/// (§8.11/§8.47): this returns `Ok(None)` to mean "drop this report, don't
/// send it" — there is no fallback target.
///
/// `now` is the report timestamp (epoch seconds) — display-only on the wire
/// (§3.6), supplied by the caller so this function stays a pure fn.
pub fn build_report(
    event: HookEvent,
    raw: &Value,
    term_program: Option<&str>,
    iterm_session_id: Option<&str>,
    apple_terminal_tty: Option<&str>,
    now: i64,
) -> Result<Option<ReportPayload>, ExtractError> {
    let Some(target) = derive_target(term_program, iterm_session_id, apple_terminal_tty) else {
        return Ok(None);
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
    }))
}

/// The value of `$TERM_PROGRAM` that means "running directly inside iTerm2"
/// (§4.1/§7-1).
const ITERM_TERM_PROGRAM: &str = "iTerm.app";

/// The value of `$TERM_PROGRAM` that means "running directly inside
/// Terminal.app" (§4.1/§7-7).
const APPLE_TERMINAL_TERM_PROGRAM: &str = "Apple_Terminal";

/// Maximum number of ancestry hops the Apple_Terminal tty walk takes before
/// giving up and dropping the report (§9: 10 steps; §4.1).
pub const MAX_ANCESTOR_WALK_STEPS: usize = 10;

/// Classify the session and derive its prefixed target — the sole place the
/// target-generation rule (§4.1/§2) is expressed. Returns `None` ("drop the
/// report", decided by the caller) for anything that matches neither
/// terminal, per §8.11/§8.47. See `build_report` for the full branch rules.
fn derive_target(
    term_program: Option<&str>,
    iterm_session_id: Option<&str>,
    apple_terminal_tty: Option<&str>,
) -> Option<String> {
    if term_program == Some(ITERM_TERM_PROGRAM) {
        let id = iterm_session_id.filter(|s| !s.is_empty())?;
        let (_prefix, uuid) = id.split_once(':')?;
        return (!uuid.is_empty()).then(|| format!("iterm2:{uuid}"));
    }
    if term_program == Some(APPLE_TERMINAL_TERM_PROGRAM) {
        let tty = apple_terminal_tty.filter(|s| !s.is_empty())?;
        return Some(format!("apple-terminal:{tty}"));
    }
    None
}

/// One process's parent pid and controlling tty, as seen by the ancestor
/// walk. Injected so `tty_from_ancestor_walk` stays a pure function (the
/// real lookup — libproc / sysctl — lives in `shiibar-cc report`, §4.1).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProcInfo {
    /// Parent process id.
    pub ppid: i32,
    /// Controlling tty as an absolute path (`/dev/ttysNNN`), or `None` when
    /// the process has no controlling terminal (`??` in `ps`, §7-7 — true of
    /// the hook process itself and of `report.sh`'s shell).
    pub tty: Option<String>,
}

/// Resolve the controlling tty of the terminal a hook is running under by
/// walking from `start_pid` toward the process tree root, following each
/// process's parent pid, and returning the controlling tty of the **first
/// ancestor that has one** (§4.1/§7-7). The hook process is detached from
/// its terminal, so its own tty (and `report.sh`'s) is `None`; the tty is
/// found a couple of hops up, at the `claude` process (§7-7). Bounded to
/// `MAX_ANCESTOR_WALK_STEPS` hops (§9); returns `None` — meaning "drop the
/// report" — if no controlling tty is found within the limit, or if the
/// chain dead-ends (a process the lookup can't resolve, or reaching the
/// tree root).
pub fn tty_from_ancestor_walk(
    start_pid: i32,
    lookup: impl Fn(i32) -> Option<ProcInfo>,
) -> Option<String> {
    let mut pid = start_pid;
    for _ in 0..MAX_ANCESTOR_WALK_STEPS {
        let info = lookup(pid)?;
        if let Some(tty) = info.tty {
            return Some(tty);
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

    #[test]
    fn uses_the_prefixed_uuid_half_of_iterm_session_id_as_target() {
        let raw = json!({"session_id": "s1", "cwd": "/c"});
        let r = build_report(HookEvent::SessionStart, &raw, Some("iTerm.app"), Some("w0t0p0:UUID"), None, 100)
            .unwrap()
            .expect("should not be dropped");
        assert_eq!(r.target, "iterm2:UUID");
    }

    #[test]
    fn drops_the_report_when_no_iterm_session_id() {
        let raw = json!({"session_id": "s1", "cwd": "/c"});
        let r = build_report(HookEvent::SessionStart, &raw, Some("iTerm.app"), None, None, 100).unwrap();
        assert_eq!(r, None, "outside iTerm2: no fallback target, drop it (§8.11)");
    }

    #[test]
    fn drops_the_report_when_iterm_session_id_is_empty() {
        let raw = json!({"session_id": "s1", "cwd": "/c"});
        let r = build_report(HookEvent::SessionStart, &raw, Some("iTerm.app"), Some(""), None, 100).unwrap();
        assert_eq!(r, None);
    }

    #[test]
    fn drops_the_report_when_iterm_session_id_has_no_colon() {
        // Not the documented wNtNpN:UUID shape (§7-1): can't extract a UUID
        // half, so this is treated the same as "absent" rather than guessed at.
        let raw = json!({"session_id": "s1", "cwd": "/c"});
        let r = build_report(HookEvent::SessionStart, &raw, Some("iTerm.app"), Some("no-colon-here"), None, 100)
            .unwrap();
        assert_eq!(r, None);
    }

    #[test]
    fn drops_the_report_when_term_program_is_vscode_even_with_a_valid_iterm_session_id() {
        // §4.1/§7-1: VS Code's integrated terminal, launched from an iTerm2
        // tab, inherits that tab's $ITERM_SESSION_ID verbatim but overwrites
        // $TERM_PROGRAM with its own value — checking $ITERM_SESSION_ID alone
        // would misclassify this inherited session as the iTerm2 tab.
        let raw = json!({"session_id": "s1", "cwd": "/c"});
        let r = build_report(HookEvent::SessionStart, &raw, Some("vscode"), Some("w0t0p0:UUID"), None, 100)
            .unwrap();
        assert_eq!(r, None);
    }

    #[test]
    fn drops_the_report_when_term_program_is_missing_even_with_a_valid_iterm_session_id() {
        let raw = json!({"session_id": "s1", "cwd": "/c"});
        let r = build_report(HookEvent::SessionStart, &raw, None, Some("w0t0p0:UUID"), None, 100).unwrap();
        assert_eq!(r, None);
    }

    #[test]
    fn apple_terminal_uses_the_prefixed_tty_path_as_target() {
        // §4.1/§2: TERM_PROGRAM == Apple_Terminal + a resolved tty path ->
        // `apple-terminal:<tty path>`. ITERM_SESSION_ID plays no part.
        let raw = json!({"session_id": "s1", "cwd": "/c"});
        let r = build_report(
            HookEvent::SessionStart,
            &raw,
            Some("Apple_Terminal"),
            None,
            Some("/dev/ttys006"),
            100,
        )
        .unwrap()
        .expect("should not be dropped");
        assert_eq!(r.target, "apple-terminal:/dev/ttys006");
    }

    #[test]
    fn apple_terminal_without_a_resolved_tty_is_dropped() {
        // §4.1/§7-7: the ancestor walk found no controlling tty within the
        // limit, so there's no target to build — drop, no fallback (§8.11).
        let raw = json!({"session_id": "s1", "cwd": "/c"});
        let r = build_report(HookEvent::SessionStart, &raw, Some("Apple_Terminal"), None, None, 100).unwrap();
        assert_eq!(r, None);
    }

    #[test]
    fn apple_terminal_with_an_empty_tty_is_dropped() {
        let raw = json!({"session_id": "s1", "cwd": "/c"});
        let r = build_report(HookEvent::SessionStart, &raw, Some("Apple_Terminal"), None, Some(""), 100).unwrap();
        assert_eq!(r, None);
    }

    #[test]
    fn iterm2_branch_ignores_a_resolved_apple_terminal_tty() {
        // Belt-and-suspenders: even if a tty were resolved, an iTerm2
        // TERM_PROGRAM must take the iterm2 branch, never apple-terminal.
        let raw = json!({"session_id": "s1", "cwd": "/c"});
        let r = build_report(
            HookEvent::SessionStart,
            &raw,
            Some("iTerm.app"),
            Some("w0t0p0:UUID"),
            Some("/dev/ttys006"),
            100,
        )
        .unwrap()
        .unwrap();
        assert_eq!(r.target, "iterm2:UUID");
    }

    #[test]
    fn truncates_prompt_to_80_chars_by_char_not_byte() {
        // multi-byte chars: naive byte-slicing at 80 could split a codepoint.
        let long_prompt: String = "€".repeat(100);
        let raw = json!({"session_id": "s1", "cwd": "/c", "prompt": long_prompt});
        let r = build_report(HookEvent::UserPromptSubmit, &raw, Some("iTerm.app"), Some("w0t0p0:UUID"), None, 1)
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
        let r = build_report(HookEvent::UserPromptSubmit, &raw, Some("iTerm.app"), Some("w0t0p0:UUID"), None, 1)
            .unwrap()
            .unwrap();
        assert_eq!(r.prompt, None, "task-notification prompt must be omitted");
        assert_eq!(r.event, HookEvent::UserPromptSubmit, "the event itself still goes through");
    }

    #[test]
    fn ordinary_prompt_is_still_carried() {
        let raw = json!({"session_id": "s1", "cwd": "/c", "prompt": "implement the thing"});
        let r = build_report(HookEvent::UserPromptSubmit, &raw, Some("iTerm.app"), Some("w0t0p0:UUID"), None, 1)
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
        let r = build_report(HookEvent::UserPromptSubmit, &raw, Some("iTerm.app"), Some("w0t0p0:UUID"), None, 1)
            .unwrap()
            .unwrap();
        assert!(r.prompt.is_some());
    }

    #[test]
    fn missing_session_id_is_an_error() {
        let raw = json!({"cwd": "/c"});
        assert!(build_report(HookEvent::SessionStart, &raw, Some("iTerm.app"), Some("w0t0p0:UUID"), None, 1).is_err());
    }

    #[test]
    fn unknown_notification_type_becomes_unknown_variant() {
        let raw = json!({"session_id": "s1", "cwd": "/c", "notification_type": "totally_new"});
        let r = build_report(HookEvent::Notification, &raw, Some("iTerm.app"), Some("w0t0p0:UUID"), None, 1)
            .unwrap()
            .unwrap();
        assert_eq!(r.notification_type, Some(NotificationType::Unknown));
    }

    #[test]
    fn background_tasks_array_is_passed_through_opaquely() {
        let raw = json!({"session_id": "s1", "cwd": "/c", "background_tasks": [{"id":"1","status":"running"}]});
        let r = build_report(HookEvent::Stop, &raw, Some("iTerm.app"), Some("w0t0p0:UUID"), None, 1)
            .unwrap()
            .unwrap();
        assert_eq!(r.background_tasks.unwrap().len(), 1);
    }

    #[test]
    fn missing_background_tasks_is_none() {
        let raw = json!({"session_id": "s1", "cwd": "/c"});
        let r = build_report(HookEvent::Stop, &raw, Some("iTerm.app"), Some("w0t0p0:UUID"), None, 1)
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
        let r = build_report(HookEvent::Stop, &raw, Some("iTerm.app"), Some("w0t0p0:UUID"), None, 1)
            .unwrap()
            .unwrap();
        assert_eq!(r.last_assistant_message.unwrap().chars().count(), 200);
    }

    #[test]
    fn missing_last_assistant_message_is_none() {
        let raw = json!({"session_id": "s1", "cwd": "/c"});
        let r = build_report(HookEvent::Stop, &raw, Some("iTerm.app"), Some("w0t0p0:UUID"), None, 1)
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
        let r = build_report(HookEvent::Stop, &raw, Some("iTerm.app"), Some("w0t0p0:UUID"), None, 1)
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
        let r = build_report(HookEvent::Stop, &raw, Some("iTerm.app"), Some("w0t0p0:UUID"), None, 1)
            .unwrap()
            .unwrap();
        assert_eq!(r.last_assistant_message.as_deref(), Some("a".repeat(200).as_str()));
    }

    // tty_from_ancestor_walk (§4.1/§7-7) — pure-function unit tests. The
    // process table is injected as a map, so no real process is inspected.

    use std::collections::HashMap;

    fn walk(table: &HashMap<i32, ProcInfo>, start: i32) -> Option<String> {
        tty_from_ancestor_walk(start, |pid| table.get(&pid).cloned())
    }

    #[test]
    fn ancestor_walk_returns_the_first_ancestor_with_a_controlling_tty() {
        // §7-7 chain: hook sh (no tty) -> claude (ttys006) -> zsh -> ...
        let table = HashMap::from([
            (100, ProcInfo { ppid: 90, tty: None }), // the hook process itself
            (90, ProcInfo { ppid: 80, tty: None }),  // report.sh's shell (??)
            (80, ProcInfo { ppid: 70, tty: Some("/dev/ttys006".into()) }), // claude
            (70, ProcInfo { ppid: 1, tty: Some("/dev/ttys006".into()) }),  // zsh
        ]);
        assert_eq!(walk(&table, 100), Some("/dev/ttys006".into()));
    }

    #[test]
    fn ancestor_walk_uses_the_start_process_tty_when_it_already_has_one() {
        let table = HashMap::from([(80, ProcInfo { ppid: 70, tty: Some("/dev/ttys006".into()) })]);
        assert_eq!(walk(&table, 80), Some("/dev/ttys006".into()));
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
        assert_eq!(walk(&table, 1), Some("/dev/ttys006".into()));
    }

    #[test]
    fn ancestor_walk_stops_on_a_self_referential_parent() {
        let table = HashMap::from([(100, ProcInfo { ppid: 100, tty: None })]);
        assert_eq!(walk(&table, 100), None);
    }
}
