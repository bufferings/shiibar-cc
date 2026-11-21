//! A SessionEnd report without a target (DESIGN.md §4.1/§4.2): closing a
//! terminal window detaches the `claude` process from its terminal before
//! its SessionEnd hook runs, so the hook can derive neither a target nor a
//! pid and sends the SessionEnd with only its `session_id`. The daemon
//! removes every entry with that `session_id`, whatever its target kind, as
//! an ordinary SessionEnd would. A targetless report of any other event is
//! invalid and changes nothing.
//!
//! Most cases drive a `Core` directly (temp state dir, fake clock, the
//! broadcast channel read back); the last ones go through a real socket to
//! pin the daemon's responses.

mod support;

use shiibar_cc_proto::{
    ErrorResponse, HookEvent, InfoResponse, ReconcileSession, RemovalReason, ReportPayload,
    Request, SessionStartSource, Status, SubscribeEvent, TARGETLESS_REPORT_ERROR,
};
use shiibar_ccd::clock::FakeClock;
use shiibar_ccd::core::{BroadcastEvent, Core, BROADCAST_CAPACITY};
use shiibar_ccd::logging::{Level, Logger};
use shiibar_ccd::paths::StateDir;
use shiibar_ccd::state::{self, AgentEntry};
use std::sync::Arc;
use std::time::Duration;
use support::TestDaemon;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::broadcast;

const START: i64 = 1_000_000;

struct Harness {
    dir: tempfile::TempDir,
    core: Core,
    rx: broadcast::Receiver<BroadcastEvent>,
    clock: Arc<FakeClock>,
}

impl Harness {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        Self::load(dir, Arc::new(FakeClock::new(START)))
    }

    fn load(dir: tempfile::TempDir, clock: Arc<FakeClock>) -> Self {
        let (events_tx, rx) = broadcast::channel(BROADCAST_CAPACITY);
        let core = Core::load(&StateDir::new(dir.path()), clock.clone(), Logger::new(Level::Error), events_tx)
            .expect("Core::load");
        Self { dir, core, rx, clock }
    }

    /// A daemon restart on the same state dir.
    fn restart(self) -> Self {
        let Harness { dir, clock, .. } = self;
        Self::load(dir, clock)
    }

    fn state_json(&self) -> std::path::PathBuf {
        StateDir::new(self.dir.path()).state_json()
    }

    fn events(&mut self) -> Vec<BroadcastEvent> {
        let mut out = Vec::new();
        while let Ok(e) = self.rx.try_recv() {
            out.push(e);
        }
        out
    }

    fn targets(&self) -> Vec<String> {
        let mut t: Vec<String> = self.core.agents.iter().map(|a| a.target.clone()).collect();
        t.sort();
        t
    }

    /// Register an entry through an ordinary hook report and drain its event.
    fn register(&mut self, target: &str, session_id: &str, pid: Option<u32>) {
        let mut r = report(HookEvent::SessionStart, Some(target), session_id, pid);
        r.source = Some(SessionStartSource::Startup);
        self.core.handle_report(r);
        self.events();
    }
}

fn report(event: HookEvent, target: Option<&str>, session_id: &str, pid: Option<u32>) -> ReportPayload {
    ReportPayload {
        event,
        target: target.map(str::to_string),
        session_id: session_id.into(),
        cwd: format!("/proj/{session_id}"),
        transcript_path: None,
        ts: 1,
        source: None,
        notification_type: None,
        message: None,
        prompt: None,
        background_tasks: None,
        last_assistant_message: None,
        pid,
    }
}

/// The SessionEnd a hook sends after its terminal window was closed.
fn targetless_session_end(session_id: &str) -> ReportPayload {
    report(HookEvent::SessionEnd, None, session_id, None)
}

fn session_end_removal(target: &str) -> BroadcastEvent {
    BroadcastEvent::AgentRemoved {
        target: target.into(),
        reason: RemovalReason::SessionEnd,
        to: None,
    }
}

const EVERY_TARGET_KIND: [&str; 4] = [
    "iterm2:D2DA6A1F",
    "apple-terminal:/dev/ttys004",
    "ghostty:/dev/ttys005",
    "process:48213",
];

#[test]
fn removes_the_entry_with_that_session_id_whatever_its_target_kind() {
    for target in EVERY_TARGET_KIND {
        let mut h = Harness::new();
        h.register(target, "s1", Some(48213));
        h.clock.advance(5);
        h.core.handle_report(targetless_session_end("s1"));
        assert!(h.core.agents.is_empty(), "{target}: entry removed");
        assert_eq!(h.events(), vec![session_end_removal(target)], "{target}: one session_end removal");
    }
}

#[test]
fn removes_an_entry_rekeyed_by_reconcile_since_its_last_report() {
    // While the hook waits, a reconcile no longer finds the closed tab and
    // rekeys the entry to `process:<pid>`; the rekey keeps the session_id.
    let mut h = Harness::new();
    h.register("iterm2:D2DA6A1F", "s1", Some(48213));
    h.core.handle_reconcile(
        true,
        &[ReconcileSession {
            target: "process:48213".into(),
            session_id: "s1".into(),
            cwd: "/proj/s1".into(),
            status: Status::Idle,
            waiting_for: None,
            pid: Some(48213),
            update_only: false,
        }],
    );
    assert_eq!(h.targets(), vec!["process:48213"], "precondition: rekeyed");
    h.events();

    h.core.handle_report(targetless_session_end("s1"));
    assert!(h.core.agents.is_empty());
    assert_eq!(h.events(), vec![session_end_removal("process:48213")]);
}

#[test]
fn removes_an_entry_restored_from_state_json_with_an_unknown_pid() {
    let mut h = Harness::new();
    h.register("apple-terminal:/dev/ttys004", "s1", Some(48213));
    let mut h = h.restart();
    assert_eq!(h.core.agents[0].pid, None, "precondition: pid unknown after a load");

    h.core.handle_report(targetless_session_end("s1"));
    assert!(h.core.agents.is_empty());
    assert_eq!(h.events(), vec![session_end_removal("apple-terminal:/dev/ttys004")]);
}

#[test]
fn removes_every_entry_with_that_session_id_and_leaves_the_others() {
    let mut h = Harness::new();
    h.register("iterm2:A", "s1", Some(10));
    h.register("process:11", "s1", Some(11));
    h.register("ghostty:/dev/ttys005", "s2", Some(12));
    h.register("process:13", "s3", None);
    let others: Vec<AgentEntry> = h
        .core
        .agents
        .iter()
        .filter(|a| a.session_id != "s1")
        .cloned()
        .collect();

    h.clock.advance(5);
    h.core.handle_report(targetless_session_end("s1"));
    assert_eq!(h.core.agents, others, "other entries untouched (incl. last_seen / last_report_at)");
    assert_eq!(
        h.events(),
        vec![session_end_removal("iterm2:A"), session_end_removal("process:11")]
    );
}

#[test]
fn a_nested_session_end_cannot_remove_the_parent_entry() {
    // A nested `claude -p` has its own session_id, so its targetless
    // SessionEnd matches nothing even though it ran under the parent.
    let mut h = Harness::new();
    h.register("iterm2:A", "s-parent", Some(10));
    let before = h.core.agents.clone();
    h.core.handle_report(targetless_session_end("s-child"));
    assert_eq!(h.core.agents, before);
    assert!(h.events().is_empty());
}

#[test]
fn no_matching_session_id_changes_nothing_and_broadcasts_nothing() {
    let mut h = Harness::new();
    h.register("iterm2:A", "s1", Some(10));
    let before = h.core.agents.clone();
    let _ = std::fs::remove_file(h.state_json());
    h.clock.advance(5);

    h.core.handle_report(targetless_session_end("s-unknown"));
    assert_eq!(h.core.agents, before, "no entry created or changed");
    assert!(h.events().is_empty(), "nothing broadcast");
    assert!(!h.state_json().exists(), "nothing persisted");
}

#[test]
fn no_entry_at_all_creates_nothing() {
    let mut h = Harness::new();
    h.core.handle_report(targetless_session_end("s1"));
    assert!(h.core.agents.is_empty());
    assert!(h.events().is_empty());
}

#[test]
fn the_removal_is_persisted() {
    let mut h = Harness::new();
    h.register("iterm2:A", "s1", Some(10));
    h.register("iterm2:B", "s2", Some(11));
    h.core.handle_report(targetless_session_end("s1"));

    let saved = state::load(&h.state_json()).expect("state.json loads");
    let saved_targets: Vec<&str> = saved.iter().map(|a| a.target.as_str()).collect();
    assert_eq!(saved_targets, vec!["iterm2:B"]);
    let h = h.restart();
    assert_eq!(h.targets(), vec!["iterm2:B"]);
}

#[test]
fn updates_the_daemon_last_report_at_whether_or_not_an_entry_matches() {
    let mut h = Harness::new();
    h.register("iterm2:A", "s1", Some(10));
    h.clock.advance(30);
    h.core.handle_report(targetless_session_end("s1"));
    assert_eq!(h.core.handle_info().last_report_at, Some(START + 30));

    h.clock.advance(30);
    h.core.handle_report(targetless_session_end("s-unknown"));
    assert_eq!(h.core.handle_info().last_report_at, Some(START + 60));
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
fn a_targetless_report_of_another_event_changes_nothing() {
    for event in EVENTS_OTHER_THAN_SESSION_END {
        let mut h = Harness::new();
        h.register("iterm2:A", "s1", Some(10));
        let before = h.core.agents.clone();
        let info_before = h.core.handle_info().last_report_at;
        let _ = std::fs::remove_file(h.state_json());
        h.clock.advance(5);

        // Same session_id as the entry, and another one that matches nothing.
        for session_id in ["s1", "s-new"] {
            let mut r = report(event, None, session_id, None);
            r.prompt = Some("p".into());
            r.background_tasks = Some(vec![]);
            h.core.handle_report(r);
        }
        assert_eq!(h.core.agents, before, "{event:?}: no entry created or changed");
        assert!(h.events().is_empty(), "{event:?}: nothing broadcast");
        assert!(!h.state_json().exists(), "{event:?}: nothing persisted");
        assert_eq!(h.core.handle_info().last_report_at, info_before, "{event:?}: not counted as a report");
    }
}

#[test]
fn a_session_end_with_a_target_still_resolves_by_target_and_keeps_the_nested_session_rule() {
    // Unchanged behavior: an entry with another session_id is removed by a
    // targeted SessionEnd (a relaunch in the same tab, pids differ) ...
    let mut h = Harness::new();
    h.register("iterm2:A", "s1", Some(10));
    h.core.handle_report(report(HookEvent::SessionEnd, Some("iterm2:A"), "s-other", Some(11)));
    assert!(h.core.agents.is_empty());
    assert_eq!(h.events(), vec![session_end_removal("iterm2:A")]);

    // ... while a nested session's SessionEnd (same pid, another session_id)
    // is still ignored.
    let mut h = Harness::new();
    h.register("iterm2:A", "s1", Some(10));
    h.core.handle_report(report(HookEvent::SessionEnd, Some("iterm2:A"), "s-child", Some(10)));
    assert_eq!(h.targets(), vec!["iterm2:A"]);
    assert!(h.events().is_empty());
}

// ---------------------------------------------------------------------------
// Over the socket: responses and the subscribe event
// ---------------------------------------------------------------------------

/// Write one raw line and return the response line ("" if the daemon closed
/// the connection without answering).
async fn send_raw(daemon: &TestDaemon, line: &str) -> String {
    let mut stream = UnixStream::connect(&daemon.sock_path).await.unwrap();
    stream.write_all(line.as_bytes()).await.unwrap();
    stream.write_all(b"\n").await.unwrap();
    let mut reader = BufReader::new(stream);
    let mut resp = String::new();
    tokio::time::timeout(Duration::from_secs(5), reader.read_line(&mut resp))
        .await
        .expect("the daemon answers or closes the connection")
        .unwrap();
    resp
}

#[tokio::test]
async fn targetless_session_end_over_the_socket_gets_no_response_and_broadcasts_session_end() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = TestDaemon::start(dir.path(), Arc::new(FakeClock::new(START))).await;
    let mut sub = daemon.subscribe().await;
    assert!(matches!(sub.next_event().await, SubscribeEvent::Snapshot { .. }));

    let mut start = report(HookEvent::SessionStart, Some("ghostty:/dev/ttys005"), "s1", Some(48213));
    start.source = Some(SessionStartSource::Startup);
    daemon.report(start).await;
    assert!(matches!(sub.next_event().await, SubscribeEvent::StatusChanged { .. }));

    let line = r#"{"cmd":"report","event":"SessionEnd","session_id":"s1","cwd":"/proj/s1","ts":1}"#;
    assert_eq!(send_raw(&daemon, line).await, "", "a report is fire-and-forget");
    assert_eq!(
        sub.next_event().await,
        SubscribeEvent::AgentRemoved {
            target: "ghostty:/dev/ttys005".into(),
            reason: RemovalReason::SessionEnd,
            to: None,
        }
    );
    daemon.shutdown_and_join().await;
}

#[tokio::test]
async fn targetless_report_of_another_event_over_the_socket_is_rejected_as_an_invalid_request() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = TestDaemon::start(dir.path(), Arc::new(FakeClock::new(START))).await;
    for event in EVENTS_OTHER_THAN_SESSION_END {
        let line = serde_json::to_string(&Request::Report(report(event, None, "s1", None))).unwrap();
        let resp: ErrorResponse = serde_json::from_str(&send_raw(&daemon, &line).await).unwrap();
        assert_eq!(
            resp,
            ErrorResponse::new(format!("invalid request: {TARGETLESS_REPORT_ERROR}")),
            "{event:?}"
        );
    }
    let info: InfoResponse = daemon.request(&Request::Info).await.unwrap();
    assert_eq!(info.last_report_at, None, "an invalid report is not counted");
    assert!(daemon.core.lock().unwrap().agents.is_empty(), "no entry created");
    daemon.shutdown_and_join().await;
}
