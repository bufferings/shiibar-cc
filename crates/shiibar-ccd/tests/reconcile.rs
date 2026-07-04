//! `reconcile` integration tests (§3.5, M1M2 respec acceptance criterion):
//! add / update / prune / flag semantics, driven through a real in-process
//! daemon over the `reconcile` protocol command, asserting on the
//! `subscribe` output and a follow-up `list`.

mod support;

use shiibar_cc_proto::{
    AckResponse, HookEvent, ListResponse, ReconcileSession, Request, Status, SubscribeEvent,
    extract::build_report,
};
use shiibar_ccd::clock::SystemClock;
use std::sync::Arc;
use support::{load_fixture, TestDaemon};

const ITERM_SESSION_ID: &str = "w0t0p0:11111111-1111-1111-1111-111111111111";

fn session(target: &str, status: Status, waiting_for: Option<&str>) -> ReconcileSession {
    ReconcileSession {
        target: target.to_string(),
        session_id: format!("sess-{target}"),
        cwd: format!("/proj/{target}"),
        status,
        waiting_for: waiting_for.map(str::to_string),
    }
}

async fn reconcile(daemon: &TestDaemon, complete: bool, sessions: Vec<ReconcileSession>) {
    let _ack: AckResponse = daemon
        .request(&Request::Reconcile { complete, sessions })
        .await
        .expect("reconcile ack");
}

#[tokio::test]
async fn reconcile_adds_idle_and_waiting_as_unreviewed_but_not_working() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = TestDaemon::start(dir.path(), Arc::new(SystemClock)).await;
    let mut sub = daemon.subscribe().await;
    assert!(matches!(sub.next_event().await, SubscribeEvent::Snapshot { .. }));

    reconcile(
        &daemon,
        true,
        vec![
            session("t-idle", Status::Idle, None),
            session("t-waiting", Status::Waiting, Some("permission prompt")),
            session("t-working", Status::Working, None),
        ],
    )
    .await;

    let mut seen = std::collections::HashMap::new();
    for _ in 0..3 {
        match sub.next_event().await {
            SubscribeEvent::StatusChanged { agent } => {
                seen.insert(agent.target.clone(), agent);
            }
            other => panic!("expected status_changed, got {other:?}"),
        }
    }

    assert!(seen["t-idle"].unreviewed, "new idle discovery must be unreviewed");
    assert!(seen["t-waiting"].unreviewed, "new waiting discovery must be unreviewed");
    assert_eq!(seen["t-waiting"].message.as_deref(), Some("permission prompt"));
    assert!(!seen["t-working"].unreviewed, "new working discovery must not be unreviewed");

    daemon.shutdown_and_join().await;
}

#[tokio::test]
async fn reconcile_update_raises_flag_on_waiting_but_not_on_idle_and_message_follows_waiting() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = TestDaemon::start(dir.path(), Arc::new(SystemClock)).await;
    let mut sub = daemon.subscribe().await;
    assert!(matches!(sub.next_event().await, SubscribeEvent::Snapshot { .. }));

    // Register two known working sessions via reconcile first.
    reconcile(
        &daemon,
        true,
        vec![
            session("t-to-waiting", Status::Working, None),
            session("t-to-idle", Status::Working, None),
        ],
    )
    .await;
    for _ in 0..2 {
        assert!(matches!(sub.next_event().await, SubscribeEvent::StatusChanged { .. }));
    }

    // Reconcile again: one transitions to waiting (must raise the flag +
    // set message), the other to idle (must NOT raise the flag, §8.12).
    reconcile(
        &daemon,
        true,
        vec![
            session("t-to-waiting", Status::Waiting, Some("permission prompt")),
            session("t-to-idle", Status::Idle, None),
        ],
    )
    .await;

    let mut seen = std::collections::HashMap::new();
    for _ in 0..2 {
        match sub.next_event().await {
            SubscribeEvent::StatusChanged { agent } => {
                seen.insert(agent.target.clone(), agent);
            }
            other => panic!("expected status_changed, got {other:?}"),
        }
    }

    assert_eq!(seen["t-to-waiting"].status, Status::Waiting);
    assert!(seen["t-to-waiting"].unreviewed);
    assert_eq!(seen["t-to-waiting"].message.as_deref(), Some("permission prompt"));

    assert_eq!(seen["t-to-idle"].status, Status::Idle);
    assert!(
        !seen["t-to-idle"].unreviewed,
        "a known entry reconciled into idle must not be newly flagged (§8.12)"
    );

    daemon.shutdown_and_join().await;
}

#[tokio::test]
async fn reconcile_prune_removes_only_on_complete_true() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = TestDaemon::start(dir.path(), Arc::new(SystemClock)).await;
    let mut sub = daemon.subscribe().await;
    assert!(matches!(sub.next_event().await, SubscribeEvent::Snapshot { .. }));

    // Register a session that a hook, not reconcile, put there (a ghost
    // candidate: still tracked by shiibar-ccd, but no longer live).
    let raw = load_fixture("session_start_startup.json");
    let payload = build_report(HookEvent::SessionStart, &raw, Some(ITERM_SESSION_ID), 1)
        .unwrap()
        .unwrap();
    daemon.report(payload).await;
    assert!(matches!(sub.next_event().await, SubscribeEvent::StatusChanged { .. }));

    // An incomplete scan must never prune, even though the ghost is absent
    // from the live set (§7-1: a partial scan can't tell "gone" from
    // "scan missed it").
    reconcile(&daemon, false, vec![session("t-other", Status::Working, None)]).await;
    match sub.next_event().await {
        SubscribeEvent::StatusChanged { agent } => assert_eq!(agent.target, "t-other"),
        other => panic!("expected status_changed(t-other), got {other:?}"),
    }
    let resp: ListResponse = daemon.request(&Request::List).await.unwrap();
    assert!(
        resp.agents.iter().any(|a| a.target == "11111111-1111-1111-1111-111111111111"),
        "complete:false must not prune the ghost"
    );

    // A complete scan without the ghost in the live set prunes it.
    reconcile(&daemon, true, vec![session("t-other", Status::Working, None)]).await;
    match sub.next_event().await {
        SubscribeEvent::AgentRemoved { target } => {
            assert_eq!(target, "11111111-1111-1111-1111-111111111111");
        }
        other => panic!("expected agent_removed, got {other:?}"),
    }
    let resp: ListResponse = daemon.request(&Request::List).await.unwrap();
    assert!(
        !resp.agents.iter().any(|a| a.target == "11111111-1111-1111-1111-111111111111"),
        "complete:true must prune the ghost"
    );
    assert!(resp.agents.iter().any(|a| a.target == "t-other"), "still-live session must survive");

    daemon.shutdown_and_join().await;
}

#[tokio::test]
async fn reconcile_can_recover_a_waiting_session_the_daemon_never_saw() {
    // The scenario in DESIGN.md §3.5's rationale: a hook report was lost
    // (e.g. daemon was down) but the session is now `waiting` per `claude
    // agents` — reconcile alone must surface it as unreviewed waiting.
    let dir = tempfile::tempdir().unwrap();
    let daemon = TestDaemon::start(dir.path(), Arc::new(SystemClock)).await;
    let mut sub = daemon.subscribe().await;
    assert!(matches!(sub.next_event().await, SubscribeEvent::Snapshot { .. }));

    reconcile(
        &daemon,
        true,
        vec![session("t-missed", Status::Waiting, Some("permission prompt"))],
    )
    .await;

    match sub.next_event().await {
        SubscribeEvent::StatusChanged { agent } => {
            assert_eq!(agent.status, Status::Waiting);
            assert!(agent.unreviewed);
        }
        other => panic!("expected status_changed, got {other:?}"),
    }

    daemon.shutdown_and_join().await;
}
