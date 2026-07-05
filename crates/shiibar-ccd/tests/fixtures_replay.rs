//! Fixtures replay test (M1 acceptance criterion): feed the hand-written
//! hook JSON fixtures through the real `report` pipeline (the same
//! `shiibar_cc_proto::extract::build_report` that `shiibar-cc report` calls)
//! into a real in-process daemon, and assert the `subscribe` output
//! sequence (snapshot -> change events) matches what DESIGN.md §3.4 says
//! should happen. Ordering is synchronized purely by reading the subscribe
//! stream — no sleeping.
//!
//! The fixture JSON files themselves are unchanged (still `session_id`-only,
//! no `$ITERM_SESSION_ID` inside the hook payload — that variable is never
//! part of the hook JSON, it's a real env var `report.sh`/`shiibar-cc report`
//! reads separately, §4.1). This harness supplies it the same way the real
//! CLI does, exercising the same `wNtNpN:UUID` -> bare-UUID-target rule
//! (§2/§4.1) `build_report` implements.

mod support;

use shiibar_cc_proto::{extract::build_report, HookEvent, RemovalReason, Status, SubscribeEvent};
use shiibar_ccd::clock::SystemClock;
use std::sync::Arc;
use support::{load_fixture, TestDaemon};

const TARGET: &str = "11111111-1111-1111-1111-111111111111";
const ITERM_SESSION_ID: &str = "w0t0p0:11111111-1111-1111-1111-111111111111";

#[tokio::test]
async fn fixtures_replay_matches_expected_subscribe_sequence() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = TestDaemon::start(dir.path(), Arc::new(SystemClock)).await;

    let mut sub = daemon.subscribe().await;
    // Initial snapshot: nothing registered yet.
    match sub.next_event().await {
        SubscribeEvent::Snapshot { agents } => assert!(agents.is_empty()),
        other => panic!("expected empty snapshot, got {other:?}"),
    }

    // 1. SessionStart(startup) -> registers idle.
    send(&daemon, "session_start_startup.json", HookEvent::SessionStart).await;
    match sub.next_event().await {
        SubscribeEvent::StatusChanged { agent } => {
            assert_eq!(agent.target, TARGET);
            assert_eq!(agent.status, Status::Idle);
            assert!(!agent.unreviewed);
        }
        other => panic!("expected status_changed(idle), got {other:?}"),
    }

    // 2. UserPromptSubmit -> idle -> working, task set (the real captured
    //    prompt, translated to English in the fixture — fixtures/README.md).
    send(&daemon, "user_prompt_submit.json", HookEvent::UserPromptSubmit).await;
    match sub.next_event().await {
        SubscribeEvent::StatusChanged { agent } => {
            assert_eq!(agent.status, Status::Working);
            assert_eq!(
                agent.task.as_deref(),
                Some("Show me this project's file list with ls")
            );
        }
        other => panic!("expected status_changed(working), got {other:?}"),
    }

    // 3. Notification(permission_prompt) -> working -> waiting, message set,
    //    unreviewed raised.
    send(
        &daemon,
        "notification_permission_prompt.json",
        HookEvent::Notification,
    )
    .await;
    match sub.next_event().await {
        SubscribeEvent::StatusChanged { agent } => {
            assert_eq!(agent.status, Status::Waiting);
            assert_eq!(agent.message.as_deref(), Some("Claude needs your permission"));
            assert!(agent.unreviewed);
        }
        other => panic!("expected status_changed(waiting), got {other:?}"),
    }

    // 4. PostToolUse -> waiting -> working (release), message cleared,
    //    unreviewed lowered.
    send(&daemon, "post_tool_use.json", HookEvent::PostToolUse).await;
    match sub.next_event().await {
        SubscribeEvent::StatusChanged { agent } => {
            assert_eq!(agent.status, Status::Working);
            assert_eq!(agent.message, None);
            assert!(!agent.unreviewed);
        }
        other => panic!("expected status_changed(working), got {other:?}"),
    }

    // 5. Stop(no background_tasks) -> working -> idle, unreviewed raised
    //    (§3.4: completion; `done` no longer exists in the respec'd model).
    send(&daemon, "stop_no_background_tasks.json", HookEvent::Stop).await;
    match sub.next_event().await {
        SubscribeEvent::StatusChanged { agent } => {
            assert_eq!(agent.status, Status::Idle);
            assert!(agent.unreviewed);
        }
        other => panic!("expected status_changed(idle), got {other:?}"),
    }

    // 6-7. The real `/clear` flow, as captured: a SessionEnd with reason
    //    "clear" ends the old session (removal, reason session_end on the
    //    wire — §4.2 doesn't distinguish why the hook fired), then a
    //    SessionStart(clear) immediately re-registers the same pane as a
    //    fresh idle entry with the flag down (§3.4).
    send(&daemon, "session_end_clear.json", HookEvent::SessionEnd).await;
    match sub.next_event().await {
        SubscribeEvent::AgentRemoved { target, reason } => {
            assert_eq!(target, TARGET);
            assert_eq!(reason, RemovalReason::SessionEnd);
        }
        other => panic!("expected agent_removed, got {other:?}"),
    }
    send(&daemon, "session_start_clear.json", HookEvent::SessionStart).await;
    match sub.next_event().await {
        SubscribeEvent::StatusChanged { agent } => {
            assert_eq!(agent.target, TARGET);
            assert_eq!(agent.status, Status::Idle);
            assert!(!agent.unreviewed);
        }
        other => panic!("expected status_changed(idle) after /clear restart, got {other:?}"),
    }

    // 8. SessionEnd (reason "other" — pane closed) -> removed, reason
    //    session_end (§4.2: the app must not sweep a not-yet-reviewed
    //    completion toast for this reason).
    send(&daemon, "session_end.json", HookEvent::SessionEnd).await;
    match sub.next_event().await {
        SubscribeEvent::AgentRemoved { target, reason } => {
            assert_eq!(target, TARGET);
            assert_eq!(reason, RemovalReason::SessionEnd);
        }
        other => panic!("expected agent_removed, got {other:?}"),
    }

    daemon.shutdown_and_join().await;
}

async fn send(daemon: &TestDaemon, fixture: &str, event: HookEvent) {
    let raw = load_fixture(fixture);
    let payload = build_report(event, &raw, Some(ITERM_SESSION_ID), 1_700_000_000)
        .expect("fixture should extract cleanly")
        .expect("fixture + ITERM_SESSION_ID should never be dropped");
    daemon.report(payload).await;
}
