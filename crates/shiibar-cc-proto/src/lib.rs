//! Message types and NDJSON codec shared by shiibar-ccd and shiibar-cc.
//!
//! Wire format: docs/DESIGN.md §4.2. Forward compatibility: deserialization
//! ignores unknown fields (serde default). Enums that a *client* observes
//! from the daemon (status, subscribe event kind) carry a `#[serde(other)]`
//! fallback so an unrecognized value doesn't fail the whole line.

pub mod codec;
pub mod extract;

use serde::{Deserialize, Serialize};

/// Agent status. `idle` / `working` / `waiting` per DESIGN.md §3.1 (3 values;
/// `blocked` was renamed to `waiting` and `done` was dropped in the state
/// model respec — `seen` no longer moves `done` to `idle`, it only clears
/// `unreviewed`, §3.2).
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
    Waiting,
    #[serde(other)]
    Unknown,
}

/// A single agent entry as seen over the wire (list / snapshot / status_changed).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Agent {
    pub target: String,
    pub status: Status,
    /// Not yet focused since entering the current your-turn state (`waiting`,
    /// or `idle` right after completion). Only meaningful for `waiting` /
    /// `idle` (§3.2); `working` never carries it.
    pub unreviewed: bool,
    pub session_id: String,
    pub cwd: String,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub task: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub message: Option<String>,
    /// Last assistant reply as of the most recent completion (Stop with
    /// empty `background_tasks`), truncated to 200 chars (§9). Cleared when
    /// the entry transitions to `working` (§3.6). Forward-compatible
    /// addition (M5 T4, §4.2): `#[serde(default)]` so an older daemon build
    /// omitting this field on the wire still deserializes on a future
    /// client, and vice versa.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub last_assistant_message: Option<String>,
    /// Epoch seconds this entry was first registered (§3.6). Immutable
    /// after creation; the sort key for the dropdown's "Newest session"
    /// mode (§4.5). Forward-compatible addition (M5 T9, §4.2):
    /// `#[serde(default)]` so an older daemon build omitting this field on
    /// the wire still deserializes on a future client, and vice versa.
    #[serde(default)]
    pub created_at: i64,
    /// Epoch seconds of the last hook report received for this target
    /// (§3.6). NOT updated by reconcile or the stale sweep — only an actual
    /// hook report bumps it. The sort key for the dropdown's "Recent
    /// activity" mode (§4.5). Forward-compatible addition (M5 T9), same
    /// `#[serde(default)]` rationale as `created_at` above.
    #[serde(default)]
    pub last_report_at: i64,
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

/// `Notification` sub-type (§3.4). Any value this build doesn't recognize
/// falls into `Unknown`, which is deliberately treated the same as the
/// waiting-inducing family (prefer a false alarm over a miss, DESIGN.md §3.4).
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
    /// Stop's `last_assistant_message` (§4.1/§9), already truncated to 200
    /// chars by the extraction. Only ever populated on a `Stop` report.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub last_assistant_message: Option<String>,
}

/// One live session as gathered by the client from `claude agents --json` +
/// `iterm_targets` (§3.5), sent as part of a `reconcile` request. `status`
/// is already translated to shiibar's 3-value vocabulary by the client
/// (busy/shell -> working, waiting -> waiting, idle -> idle, §3.5) — the
/// daemon never sees the `claude agents` vocabulary.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ReconcileSession {
    pub target: String,
    pub session_id: String,
    pub cwd: String,
    pub status: Status,
    /// `waitingFor` from `claude agents`, only meaningful when `status` is
    /// `waiting` (§3.5/§3.6).
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub waiting_for: Option<String>,
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
    Info,
    Shutdown,
    /// `claude agents` reconciliation (§3.5). `complete` is whether the
    /// client's iTerm2 scan was complete (§7-1: iTerm2 AppleScript scanning
    /// can intermittently fail on split panes) — `false` tells the daemon to
    /// skip pruning this round, since a partial scan can't be trusted to
    /// mean "this session is really gone".
    Reconcile {
        complete: bool,
        sessions: Vec<ReconcileSession>,
    },
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

/// Response to `{"cmd":"info"}`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct InfoResponse {
    pub ok: bool,
    pub version: String,
    pub started_at: i64,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub last_report_at: Option<i64>,
}

/// Why an entry was deleted (§3.6, §4.2): which of the four deletion paths
/// produced this `agent_removed`. The menu bar app uses this to decide
/// whether to sweep delivered notifications for the target (§4.5) — it
/// must NOT do so for `SessionEnd` (closing the pane shouldn't wipe an
/// unread completion toast), but may for the others.
///
/// `Unknown` is both the `#[serde(other)]` fallback for a reason string a
/// future daemon version might add, and the `Default` used by
/// `#[serde(default)]` when reading a pre-M4 `agent_removed` line that has
/// no `reason` field at all. Per DESIGN.md §4.2, an unrecognized reason is
/// treated the same as `Remove` by consumers, so `Unknown` behaves like
/// `Remove` everywhere except in this enum's own wire representation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RemovalReason {
    /// SessionEnd hook (pane closed).
    SessionEnd,
    /// `last_seen` older than the stale threshold (§9).
    Stale,
    /// Manual `shiibar-cc remove` / `{"cmd":"remove"}`.
    Remove,
    /// reconcile prune: target absent from a complete `claude agents` scan.
    Prune,
    #[serde(other)]
    #[default]
    Unknown,
}

/// Events pushed on a `subscribe` connection (§4.2). `Unknown` is the
/// forward-compat fallback for a future daemon version's client.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum SubscribeEvent {
    Snapshot { agents: Vec<Agent> },
    StatusChanged { agent: Agent },
    AgentRemoved {
        target: String,
        #[serde(default)]
        reason: RemovalReason,
    },
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
    fn pre_respec_status_strings_fall_back_to_unknown() {
        // M1M2 respec migration policy: a state.json written by the old
        // 4-value-status model has `blocked` / `done` strings that no
        // longer exist. No migration code is written for this — they
        // deserialize to `Unknown` and get corrected/pruned by the next
        // reconcile (M1M2-respec brief).
        for legacy in ["blocked", "done"] {
            let v: Status = serde_json::from_str(&format!("{legacy:?}")).unwrap();
            assert_eq!(v, Status::Unknown, "legacy status {legacy:?} must fall back to Unknown");
        }
    }

    #[test]
    fn unknown_subscribe_event_falls_back_to_unknown() {
        let v: SubscribeEvent = serde_json::from_str(r#"{"event":"future_event","foo":"bar"}"#).unwrap();
        assert_eq!(v, SubscribeEvent::Unknown);
    }

    #[test]
    fn agent_removed_matches_wire_example_with_reason() {
        let line = r#"{"event":"agent_removed","target":"…","reason":"session_end"}"#;
        let v: SubscribeEvent = serde_json::from_str(line).unwrap();
        assert_eq!(
            v,
            SubscribeEvent::AgentRemoved {
                target: "…".to_string(),
                reason: RemovalReason::SessionEnd,
            }
        );
    }

    #[test]
    fn agent_removed_reason_defaults_to_unknown_when_field_absent() {
        // Forward/backward compat (§4.2): a pre-M4 agent_removed line has no
        // `reason` field at all. `#[serde(default)]` must still parse it.
        let line = r#"{"event":"agent_removed","target":"t"}"#;
        let v: SubscribeEvent = serde_json::from_str(line).unwrap();
        assert_eq!(
            v,
            SubscribeEvent::AgentRemoved {
                target: "t".to_string(),
                reason: RemovalReason::Unknown,
            }
        );
    }

    #[test]
    fn agent_removed_unrecognized_reason_falls_back_to_unknown() {
        let line = r#"{"event":"agent_removed","target":"t","reason":"some_future_reason"}"#;
        let v: SubscribeEvent = serde_json::from_str(line).unwrap();
        match v {
            SubscribeEvent::AgentRemoved { reason, .. } => assert_eq!(reason, RemovalReason::Unknown),
            other => panic!("expected AgentRemoved, got {other:?}"),
        }
    }

    #[test]
    fn all_four_removal_reasons_round_trip() {
        for (reason, wire) in [
            (RemovalReason::SessionEnd, "session_end"),
            (RemovalReason::Stale, "stale"),
            (RemovalReason::Remove, "remove"),
            (RemovalReason::Prune, "prune"),
        ] {
            let event = SubscribeEvent::AgentRemoved {
                target: "t".to_string(),
                reason,
            };
            let s = serde_json::to_string(&event).unwrap();
            assert!(s.contains(&format!(r#""reason":"{wire}""#)), "got {s}");
            let back: SubscribeEvent = serde_json::from_str(&s).unwrap();
            assert_eq!(back, event);
        }
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
            unreviewed: false,
            session_id: "s".into(),
            cwd: "/c".into(),
            task: None,
            message: None,
            last_assistant_message: None,
            created_at: 0,
            last_report_at: 0,
            since: 1,
            last_seen: 2,
        };
        let s = serde_json::to_string(&agent).unwrap();
        assert!(!s.contains("task"));
        assert!(!s.contains("message"));
        assert!(!s.contains("last_assistant_message"));
    }

    #[test]
    fn agent_wire_carries_last_assistant_message_when_present() {
        // §4.2: `last_assistant_message` is a forward-compatible addition to
        // the wire `Agent` (M5 T4).
        let agent = Agent {
            target: "t".into(),
            status: Status::Idle,
            unreviewed: true,
            session_id: "s".into(),
            cwd: "/c".into(),
            task: Some("implement the docs build".into()),
            message: None,
            last_assistant_message: Some("Done. All 54 tests pass.".into()),
            created_at: 100,
            last_report_at: 200,
            since: 1,
            last_seen: 2,
        };
        let s = serde_json::to_string(&agent).unwrap();
        assert!(s.contains(r#""last_assistant_message":"Done. All 54 tests pass.""#));
        let back: Agent = serde_json::from_str(&s).unwrap();
        assert_eq!(back, agent);
    }

    #[test]
    fn agent_wire_without_last_assistant_message_field_still_deserializes() {
        // Backward compat: a pre-M5 daemon's `Agent` line has no
        // `last_assistant_message` key at all.
        let line = r#"{"target":"t","status":"idle","unreviewed":false,"session_id":"s","cwd":"/c","since":1,"last_seen":2}"#;
        let agent: Agent = serde_json::from_str(line).unwrap();
        assert_eq!(agent.last_assistant_message, None);
    }

    #[test]
    fn agent_wire_carries_created_at_and_last_report_at_when_present() {
        // §4.2/§3.6: `created_at` / `last_report_at` are the sort keys for
        // the dropdown's "Newest session" / "Recent activity" modes (M5 T9).
        let agent = Agent {
            target: "t".into(),
            status: Status::Idle,
            unreviewed: false,
            session_id: "s".into(),
            cwd: "/c".into(),
            task: None,
            message: None,
            last_assistant_message: None,
            created_at: 100,
            last_report_at: 200,
            since: 1,
            last_seen: 2,
        };
        let s = serde_json::to_string(&agent).unwrap();
        assert!(s.contains(r#""created_at":100"#));
        assert!(s.contains(r#""last_report_at":200"#));
        let back: Agent = serde_json::from_str(&s).unwrap();
        assert_eq!(back, agent);
    }

    #[test]
    fn agent_wire_without_created_at_or_last_report_at_field_still_deserializes() {
        // Forward/backward compat (M5 T9, §4.2): a pre-M5 daemon's `Agent`
        // line has neither key at all; both must default to 0 rather than
        // failing the line.
        let line = r#"{"target":"t","status":"idle","unreviewed":false,"session_id":"s","cwd":"/c","since":1,"last_seen":2}"#;
        let agent: Agent = serde_json::from_str(line).unwrap();
        assert_eq!(agent.created_at, 0);
        assert_eq!(agent.last_report_at, 0);
    }

    #[test]
    fn report_payload_carries_last_assistant_message_on_stop() {
        let line = r#"{"cmd":"report","event":"Stop","target":"t","session_id":"s","cwd":"/c","ts":1,"background_tasks":[],"last_assistant_message":"Done. All 54 tests pass."}"#;
        let req: Request = serde_json::from_str(line).unwrap();
        let Request::Report(p) = req else { panic!("expected Report") };
        assert_eq!(p.last_assistant_message.as_deref(), Some("Done. All 54 tests pass."));
    }

    #[test]
    fn report_payload_without_last_assistant_message_field_still_deserializes() {
        // Backward compat: an older `shiibar-cc report` build never sent
        // this field at all.
        let line = r#"{"cmd":"report","event":"Stop","target":"t","session_id":"s","cwd":"/c","ts":1}"#;
        let req: Request = serde_json::from_str(line).unwrap();
        let Request::Report(p) = req else { panic!("expected Report") };
        assert_eq!(p.last_assistant_message, None);
    }

    #[test]
    fn reconcile_request_round_trips_and_matches_wire_example() {
        let line = r#"{"cmd":"reconcile","complete":true,"sessions":[{"target":"D2DA6A1F","session_id":"s1","cwd":"/path","status":"waiting","waiting_for":"permission prompt"}]}"#;
        let req: Request = serde_json::from_str(line).unwrap();
        match req {
            Request::Reconcile { complete, sessions } => {
                assert!(complete);
                assert_eq!(sessions.len(), 1);
                assert_eq!(sessions[0].target, "D2DA6A1F");
                assert_eq!(sessions[0].status, Status::Waiting);
                assert_eq!(sessions[0].waiting_for.as_deref(), Some("permission prompt"));
            }
            other => panic!("expected Reconcile, got {other:?}"),
        }
    }
}
