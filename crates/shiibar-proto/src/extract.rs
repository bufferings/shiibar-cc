//! Turn a raw Claude Code hook JSON payload into a `ReportPayload` (§4.1).
//!
//! Shared by `shiibarctl report` (production) and shiibard's integration
//! tests (fixtures replay), so both exercise the exact same normalization
//! logic.

use crate::{HookEvent, NotificationType, ReportPayload, SessionStartSource};
use serde_json::Value;

/// prompt / task display truncation (§9): first 80 **characters**, not bytes.
pub const TASK_TRUNCATE_CHARS: usize = 80;

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
/// `iterm_session_id` is `$ITERM_SESSION_ID` (target generation rule, §4.1):
/// used verbatim if non-empty, else `target` falls back to
/// `session:<session_id>`.
///
/// `now` is the report timestamp (epoch seconds) — display-only on the wire
/// (§3.2), supplied by the caller so this function stays a pure fn.
pub fn build_report(
    event: HookEvent,
    raw: &Value,
    iterm_session_id: Option<&str>,
    now: i64,
) -> Result<ReportPayload, ExtractError> {
    let session_id = str_field(raw, "session_id")
        .filter(|s| !s.is_empty())
        .ok_or_else(|| ExtractError("hook JSON missing non-empty session_id".to_string()))?;
    let cwd = str_field(raw, "cwd")
        .filter(|s| !s.is_empty())
        .ok_or_else(|| ExtractError("hook JSON missing non-empty cwd".to_string()))?;
    let transcript_path = str_field(raw, "transcript_path");

    let target = match iterm_session_id.filter(|s| !s.is_empty()) {
        Some(id) => id.to_string(),
        None => format!("session:{session_id}"),
    };

    let source = parse_enum_field::<SessionStartSource>(raw, "source")?;
    let notification_type = parse_enum_field::<NotificationType>(raw, "notification_type")?;
    let message = str_field(raw, "message");
    let prompt = str_field(raw, "prompt").map(|p| truncate_chars(&p, TASK_TRUNCATE_CHARS));
    let background_tasks = raw
        .get("background_tasks")
        .and_then(|v| v.as_array())
        .cloned();

    Ok(ReportPayload {
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
    })
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
    fn uses_iterm_session_id_as_target_when_present() {
        let raw = json!({"session_id": "s1", "cwd": "/c"});
        let r = build_report(HookEvent::SessionStart, &raw, Some("w0t0p0:UUID"), 100).unwrap();
        assert_eq!(r.target, "w0t0p0:UUID");
    }

    #[test]
    fn falls_back_to_session_target_when_no_iterm_session_id() {
        let raw = json!({"session_id": "s1", "cwd": "/c"});
        let r = build_report(HookEvent::SessionStart, &raw, None, 100).unwrap();
        assert_eq!(r.target, "session:s1");
    }

    #[test]
    fn falls_back_to_session_target_when_iterm_session_id_is_empty() {
        let raw = json!({"session_id": "s1", "cwd": "/c"});
        let r = build_report(HookEvent::SessionStart, &raw, Some(""), 100).unwrap();
        assert_eq!(r.target, "session:s1");
    }

    #[test]
    fn truncates_prompt_to_80_chars_by_char_not_byte() {
        // multi-byte chars: naive byte-slicing at 80 could split a codepoint.
        let long_prompt: String = "あ".repeat(100);
        let raw = json!({"session_id": "s1", "cwd": "/c", "prompt": long_prompt});
        let r = build_report(HookEvent::UserPromptSubmit, &raw, None, 1).unwrap();
        assert_eq!(r.prompt.unwrap().chars().count(), 80);
    }

    #[test]
    fn missing_session_id_is_an_error() {
        let raw = json!({"cwd": "/c"});
        assert!(build_report(HookEvent::SessionStart, &raw, None, 1).is_err());
    }

    #[test]
    fn unknown_notification_type_becomes_unknown_variant() {
        let raw = json!({"session_id": "s1", "cwd": "/c", "notification_type": "totally_new"});
        let r = build_report(HookEvent::Notification, &raw, None, 1).unwrap();
        assert_eq!(r.notification_type, Some(NotificationType::Unknown));
    }

    #[test]
    fn background_tasks_array_is_passed_through_opaquely() {
        let raw = json!({"session_id": "s1", "cwd": "/c", "background_tasks": [{"id":"1","status":"running"}]});
        let r = build_report(HookEvent::Stop, &raw, None, 1).unwrap();
        assert_eq!(r.background_tasks.unwrap().len(), 1);
    }

    #[test]
    fn missing_background_tasks_is_none() {
        let raw = json!({"session_id": "s1", "cwd": "/c"});
        let r = build_report(HookEvent::Stop, &raw, None, 1).unwrap();
        assert_eq!(r.background_tasks, None);
    }
}
