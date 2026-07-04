//! Message types and NDJSON codec shared by shiibar-ccd and shiibar-cc.
//!
//! Wire format: docs/DESIGN.md §4.2. Forward compatibility: deserialization
//! ignores unknown fields (serde default). Enums that a *client* observes
//! from the daemon (status, subscribe event kind) carry a `#[serde(other)]`
//! fallback so an unrecognized value doesn't fail the whole line.

pub mod codec;
pub mod extract;

use serde::{Deserialize, Serialize};

/// Agent status. `idle` / `working` / `blocked` / `done` per DESIGN.md §3.
///
/// `Unknown` only exists for forward-compatible *deserialization* on the
/// client side (a future daemon version emitting a status this build
/// doesn't know about must not fail the line). shiibar-ccd itself never
/// constructs `Unknown`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Status {
    Idle,
    Working,
    Blocked,
    Done,
    #[serde(other)]
    Unknown,
}

/// A single agent entry as seen over the wire (list / snapshot / status_changed).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Agent {
    pub target: String,
    pub status: Status,
    pub session_id: String,
    pub cwd: String,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub task: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub message: Option<String>,
    pub since: i64,
    pub last_seen: i64,
}

/// Hook event kind, as normalized by `shiibar-cc report` (§4.1) and sent to
/// shiibar-ccd over the wire (§4.2). This is a closed set for M1: the seven
/// events wired up in `hooks/settings-snippet.json`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum HookEvent {
    SessionStart,
    UserPromptSubmit,
    PostToolUse,
    PostToolUseFailure,
    Notification,
    Stop,
    SessionEnd,
}

/// `SessionStart` source (§3.1). Only `compact` is behaviorally distinct
/// (it must not force the agent back to idle); every other source value
/// (including ones this build doesn't know about yet) is treated the same
/// as `startup`/`clear`/`resume`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionStartSource {
    Startup,
    Clear,
    Resume,
    Compact,
    #[serde(other)]
    Other,
}

/// `Notification` sub-type (§3.1). Any value this build doesn't recognize
/// falls into `Unknown`, which is deliberately treated as blocked-inducing
/// (prefer a false alarm over a miss, DESIGN.md §3.1).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NotificationType {
    PermissionPrompt,
    AgentNeedsInput,
    ElicitationDialog,
    IdlePrompt,
    AuthSuccess,
    ElicitationComplete,
    ElicitationResponse,
    AgentCompleted,
    #[serde(other)]
    Unknown,
}

/// A report from `shiibar-cc report`, normalized (§4.1) and already
/// enriched with `target` / `ts`. This is the `{"cmd":"report",...}` payload.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ReportPayload {
    pub event: HookEvent,
    pub target: String,
    pub session_id: String,
    pub cwd: String,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub transcript_path: Option<String>,
    pub ts: i64,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub source: Option<SessionStartSource>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub notification_type: Option<NotificationType>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub message: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub prompt: Option<String>,
    /// Opaque for M1: real shape is still unverified (DESIGN.md §7-2c). Only
    /// emptiness is used by the state machine.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub background_tasks: Option<Vec<serde_json::Value>>,
}

/// A `sessions.jsonl` line / `sessions` response entry (§4.2, §4.2 Operations).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SessionRecord {
    pub session_id: String,
    pub cwd: String,
    pub last_status: Status,
    pub last_seen: i64,
}

/// Requests a client may send, tagged by `cmd` (§4.2).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "cmd", rename_all = "snake_case")]
pub enum Request {
    Report(ReportPayload),
    List,
    Subscribe,
    Remove { target: String },
    Seen { target: String },
    Sessions,
    Info,
    Shutdown,
}

/// Generic `{"ok":false,"error":"..."}` response, used for malformed JSON
/// and unknown `cmd` (§4.2).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ErrorResponse {
    pub ok: bool,
    pub error: String,
}

impl ErrorResponse {
    pub fn new(error: impl Into<String>) -> Self {
        Self {
            ok: false,
            error: error.into(),
        }
    }
}

/// `{"ok":true}` — response to `remove` / `seen` / `shutdown`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct AckResponse {
    pub ok: bool,
}

impl Default for AckResponse {
    fn default() -> Self {
        Self { ok: true }
    }
}

/// Response to `{"cmd":"list"}`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ListResponse {
    pub ok: bool,
    pub agents: Vec<Agent>,
}

impl ListResponse {
    pub fn new(agents: Vec<Agent>) -> Self {
        Self { ok: true, agents }
    }
}

/// Response to `{"cmd":"sessions"}`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SessionsResponse {
    pub ok: bool,
    pub sessions: Vec<SessionRecord>,
}

impl SessionsResponse {
    pub fn new(sessions: Vec<SessionRecord>) -> Self {
        Self { ok: true, sessions }
    }
}

/// Response to `{"cmd":"info"}`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct InfoResponse {
    pub ok: bool,
    pub version: String,
    pub started_at: i64,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub last_report_at: Option<i64>,
}

/// Events pushed on a `subscribe` connection (§4.2). `Unknown` is the
/// forward-compat fallback for a future daemon version's client.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum SubscribeEvent {
    Snapshot { agents: Vec<Agent> },
    StatusChanged { agent: Agent },
    AgentRemoved { target: String },
    #[serde(other)]
    Unknown,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_report_round_trips_and_matches_wire_example() {
        let line = r#"{"cmd":"report","event":"Notification","notification_type":"permission_prompt","message":"Bash: cargo test","target":"w0t0p0:D2DA6A1F","session_id":"s1","cwd":"/path","transcript_path":"t","ts":1751600000}"#;
        let req: Request = serde_json::from_str(line).unwrap();
        match req {
            Request::Report(p) => {
                assert_eq!(p.event, HookEvent::Notification);
                assert_eq!(p.notification_type, Some(NotificationType::PermissionPrompt));
                assert_eq!(p.message.as_deref(), Some("Bash: cargo test"));
                assert_eq!(p.target, "w0t0p0:D2DA6A1F");
            }
            other => panic!("expected Report, got {other:?}"),
        }
    }

    #[test]
    fn unknown_notification_type_falls_back_to_unknown() {
        let line = r#"{"cmd":"report","event":"Notification","target":"t","session_id":"s","cwd":"/c","ts":1,"notification_type":"some_future_type"}"#;
        let req: Request = serde_json::from_str(line).unwrap();
        let Request::Report(p) = req else { panic!("expected report") };
        assert_eq!(p.notification_type, Some(NotificationType::Unknown));
    }

    #[test]
    fn unknown_status_falls_back_to_unknown_for_forward_compat() {
        let v: Status = serde_json::from_str(r#""future_status""#).unwrap();
        assert_eq!(v, Status::Unknown);
    }

    #[test]
    fn unknown_subscribe_event_falls_back_to_unknown() {
        let v: SubscribeEvent = serde_json::from_str(r#"{"event":"future_event","foo":"bar"}"#).unwrap();
        assert_eq!(v, SubscribeEvent::Unknown);
    }

    #[test]
    fn unknown_cmd_fails_to_deserialize_as_request() {
        // The daemon is responsible for turning this Err into
        // {"ok":false,"error":"..."} — Request itself has no catch-all,
        // since "unknown cmd" is a server-side error case, not a
        // forward-compat client concern (§4.2).
        let err = serde_json::from_str::<Request>(r#"{"cmd":"frobnicate"}"#);
        assert!(err.is_err());
    }

    #[test]
    fn error_response_shape() {
        let r = ErrorResponse::new("bad json");
        let s = serde_json::to_string(&r).unwrap();
        assert_eq!(s, r#"{"ok":false,"error":"bad json"}"#);
    }

    #[test]
    fn list_response_omits_task_and_message_when_absent() {
        let agent = Agent {
            target: "t".into(),
            status: Status::Idle,
            session_id: "s".into(),
            cwd: "/c".into(),
            task: None,
            message: None,
            since: 1,
            last_seen: 2,
        };
        let s = serde_json::to_string(&agent).unwrap();
        assert!(!s.contains("task"));
        assert!(!s.contains("message"));
    }
}
