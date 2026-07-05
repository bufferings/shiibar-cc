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
/// `term_program` and `iterm_session_id` are `$TERM_PROGRAM` / `$ITERM_SESSION_ID`
/// (target generation rule, §4.1): a session is only ever an iTerm2 session
/// when **both** `$TERM_PROGRAM == "iTerm.app"` **and** `$ITERM_SESSION_ID`
/// (shape `wNtNpN:UUID`) are present — the target is the **`:` -onward UUID**
/// half only (not the whole `$ITERM_SESSION_ID` string) — this is what lets
/// `iterm_targets` (reconcile, derived independently via AppleScript) land on
/// the same target for the same session, since AppleScript can't reproduce
/// the `wNtNpN` position prefix (§7-1).
///
/// `$ITERM_SESSION_ID` alone is not enough: iTerm2 launches other apps (e.g.
/// VS Code's integrated terminal) that inherit the whole environment,
/// `$ITERM_SESSION_ID` included, from the iTerm2 tab that spawned them —
/// while overwriting `$TERM_PROGRAM` with their own value (`vscode`, ...).
/// Checking `$ITERM_SESSION_ID` alone would misclassify that inherited
/// session as the launching iTerm2 tab (observed live 2026-07-05, §7-1).
///
/// A session that fails either check can never be focused, so it isn't
/// tracked at all (§8.11): this returns `Ok(None)` to mean "drop this
/// report, don't send it" — there is no fallback target.
///
/// `now` is the report timestamp (epoch seconds) — display-only on the wire
/// (§3.6), supplied by the caller so this function stays a pure fn.
pub fn build_report(
    event: HookEvent,
    raw: &Value,
    term_program: Option<&str>,
    iterm_session_id: Option<&str>,
    now: i64,
) -> Result<Option<ReportPayload>, ExtractError> {
    let Some(target) = target_from_iterm_env(term_program, iterm_session_id) else {
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
    let last_assistant_message = str_field(raw, "last_assistant_message")
        .map(|m| truncate_chars(&m, LAST_ASSISTANT_MESSAGE_TRUNCATE_CHARS));

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

/// The only value of `$TERM_PROGRAM` that means "running directly inside
/// iTerm2" (§4.1/§7-1). Every other value (missing, empty, `vscode`,
/// `tmux`, `Apple_Terminal`, ...) fails the iTerm2 check.
const ITERM_TERM_PROGRAM: &str = "iTerm.app";

/// Classify the session and, if it's iTerm2, extract its target — the sole
/// place the iTerm2-detection rule (§4.1) is expressed. `$TERM_PROGRAM` must
/// be `"iTerm.app"` **and** `$ITERM_SESSION_ID` must be present in the
/// documented `wNtNpN:UUID` shape (§2); either condition failing means
/// "drop the report" (§4.1/§8.11), decided by the caller. The target is the
/// UUID half after the first `:`.
fn target_from_iterm_env(term_program: Option<&str>, iterm_session_id: Option<&str>) -> Option<String> {
    if term_program != Some(ITERM_TERM_PROGRAM) {
        return None;
    }
    let id = iterm_session_id.filter(|s| !s.is_empty())?;
    let (_prefix, uuid) = id.split_once(':')?;
    if uuid.is_empty() { None } else { Some(uuid.to_string()) }
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn uses_the_uuid_half_of_iterm_session_id_as_target() {
        let raw = json!({"session_id": "s1", "cwd": "/c"});
        let r = build_report(HookEvent::SessionStart, &raw, Some("iTerm.app"), Some("w0t0p0:UUID"), 100)
            .unwrap()
            .expect("should not be dropped");
        assert_eq!(r.target, "UUID");
    }

    #[test]
    fn drops_the_report_when_no_iterm_session_id() {
        let raw = json!({"session_id": "s1", "cwd": "/c"});
        let r = build_report(HookEvent::SessionStart, &raw, Some("iTerm.app"), None, 100).unwrap();
        assert_eq!(r, None, "outside iTerm2: no fallback target, drop it (§8.11)");
    }

    #[test]
    fn drops_the_report_when_iterm_session_id_is_empty() {
        let raw = json!({"session_id": "s1", "cwd": "/c"});
        let r = build_report(HookEvent::SessionStart, &raw, Some("iTerm.app"), Some(""), 100).unwrap();
        assert_eq!(r, None);
    }

    #[test]
    fn drops_the_report_when_iterm_session_id_has_no_colon() {
        // Not the documented wNtNpN:UUID shape (§7-1): can't extract a UUID
        // half, so this is treated the same as "absent" rather than guessed at.
        let raw = json!({"session_id": "s1", "cwd": "/c"});
        let r = build_report(HookEvent::SessionStart, &raw, Some("iTerm.app"), Some("no-colon-here"), 100)
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
        let r = build_report(HookEvent::SessionStart, &raw, Some("vscode"), Some("w0t0p0:UUID"), 100)
            .unwrap();
        assert_eq!(r, None);
    }

    #[test]
    fn drops_the_report_when_term_program_is_missing_even_with_a_valid_iterm_session_id() {
        let raw = json!({"session_id": "s1", "cwd": "/c"});
        let r = build_report(HookEvent::SessionStart, &raw, None, Some("w0t0p0:UUID"), 100).unwrap();
        assert_eq!(r, None);
    }

    #[test]
    fn truncates_prompt_to_80_chars_by_char_not_byte() {
        // multi-byte chars: naive byte-slicing at 80 could split a codepoint.
        let long_prompt: String = "€".repeat(100);
        let raw = json!({"session_id": "s1", "cwd": "/c", "prompt": long_prompt});
        let r = build_report(HookEvent::UserPromptSubmit, &raw, Some("iTerm.app"), Some("w0t0p0:UUID"), 1)
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
        let r = build_report(HookEvent::UserPromptSubmit, &raw, Some("iTerm.app"), Some("w0t0p0:UUID"), 1)
            .unwrap()
            .unwrap();
        assert_eq!(r.prompt, None, "task-notification prompt must be omitted");
        assert_eq!(r.event, HookEvent::UserPromptSubmit, "the event itself still goes through");
    }

    #[test]
    fn ordinary_prompt_is_still_carried() {
        let raw = json!({"session_id": "s1", "cwd": "/c", "prompt": "implement the thing"});
        let r = build_report(HookEvent::UserPromptSubmit, &raw, Some("iTerm.app"), Some("w0t0p0:UUID"), 1)
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
        let r = build_report(HookEvent::UserPromptSubmit, &raw, Some("iTerm.app"), Some("w0t0p0:UUID"), 1)
            .unwrap()
            .unwrap();
        assert!(r.prompt.is_some());
    }

    #[test]
    fn missing_session_id_is_an_error() {
        let raw = json!({"cwd": "/c"});
        assert!(build_report(HookEvent::SessionStart, &raw, Some("iTerm.app"), Some("w0t0p0:UUID"), 1).is_err());
    }

    #[test]
    fn unknown_notification_type_becomes_unknown_variant() {
        let raw = json!({"session_id": "s1", "cwd": "/c", "notification_type": "totally_new"});
        let r = build_report(HookEvent::Notification, &raw, Some("iTerm.app"), Some("w0t0p0:UUID"), 1)
            .unwrap()
            .unwrap();
        assert_eq!(r.notification_type, Some(NotificationType::Unknown));
    }

    #[test]
    fn background_tasks_array_is_passed_through_opaquely() {
        let raw = json!({"session_id": "s1", "cwd": "/c", "background_tasks": [{"id":"1","status":"running"}]});
        let r = build_report(HookEvent::Stop, &raw, Some("iTerm.app"), Some("w0t0p0:UUID"), 1)
            .unwrap()
            .unwrap();
        assert_eq!(r.background_tasks.unwrap().len(), 1);
    }

    #[test]
    fn missing_background_tasks_is_none() {
        let raw = json!({"session_id": "s1", "cwd": "/c"});
        let r = build_report(HookEvent::Stop, &raw, Some("iTerm.app"), Some("w0t0p0:UUID"), 1)
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
        let r = build_report(HookEvent::Stop, &raw, Some("iTerm.app"), Some("w0t0p0:UUID"), 1)
            .unwrap()
            .unwrap();
        assert_eq!(r.last_assistant_message.unwrap().chars().count(), 200);
    }

    #[test]
    fn missing_last_assistant_message_is_none() {
        let raw = json!({"session_id": "s1", "cwd": "/c"});
        let r = build_report(HookEvent::Stop, &raw, Some("iTerm.app"), Some("w0t0p0:UUID"), 1)
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
        let r = build_report(HookEvent::Stop, &raw, Some("iTerm.app"), Some("w0t0p0:UUID"), 1)
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
}
