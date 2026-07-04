//! Fixtures replay test (M1 acceptance criterion): feed the hand-written
//! hook JSON fixtures through the real `report` pipeline (the same
//! `shiibar_proto::extract::build_report` that `shiibarctl report` calls)
//! into a real in-process daemon, and assert the `subscribe` output
//! sequence (snapshot -> change events) matches what DESIGN.md §3.1 says
//! should happen. Ordering is synchronized purely by reading the subscribe
//! stream — no sleeping.

mod support;

use shiibar_proto::{extract::build_report, HookEvent, Status, SubscribeEvent};
use shiibard::clock::SystemClock;
use std::sync::Arc;
use support::{load_fixture, TestDaemon};

const TARGET: &str = "session:11111111-1111-1111-1111-111111111111";

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
        }
        other => panic!("expected status_changed(idle), got {other:?}"),
    }

    // 2. UserPromptSubmit -> idle -> working, task set.
    send(&daemon, "user_prompt_submit.json", HookEvent::UserPromptSubmit).await;
    match sub.next_event().await {
        SubscribeEvent::StatusChanged { agent } => {
            assert_eq!(agent.status, Status::Working);
            assert_eq!(agent.task.as_deref(), Some("Implement the focus AppleScript"));
        }
        other => panic!("expected status_changed(working), got {other:?}"),
    }

    // 3. Notification(permission_prompt) -> working -> blocked, message set.
    send(
        &daemon,
        "notification_permission_prompt.json",
        HookEvent::Notification,
    )
    .await;
    match sub.next_event().await {
        SubscribeEvent::StatusChanged { agent } => {
            assert_eq!(agent.status, Status::Blocked);
            assert_eq!(agent.message.as_deref(), Some("Bash: cargo test"));
        }
        other => panic!("expected status_changed(blocked), got {other:?}"),
    }

    // 4. PostToolUse -> blocked -> working (release), message cleared.
    send(&daemon, "post_tool_use.json", HookEvent::PostToolUse).await;
    match sub.next_event().await {
        SubscribeEvent::StatusChanged { agent } => {
            assert_eq!(agent.status, Status::Working);
            assert_eq!(agent.message, None);
        }
        other => panic!("expected status_changed(working), got {other:?}"),
    }

    // 5. Stop(no background_tasks) -> working -> done.
    send(&daemon, "stop_no_background_tasks.json", HookEvent::Stop).await;
    match sub.next_event().await {
        SubscribeEvent::StatusChanged { agent } => {
            assert_eq!(agent.status, Status::Done);
        }
        other => panic!("expected status_changed(done), got {other:?}"),
    }

    // 6. SessionEnd -> removed.
    send(&daemon, "session_end.json", HookEvent::SessionEnd).await;
    match sub.next_event().await {
        SubscribeEvent::AgentRemoved { target } => assert_eq!(target, TARGET),
        other => panic!("expected agent_removed, got {other:?}"),
    }

    daemon.shutdown_and_join().await;
}

async fn send(daemon: &TestDaemon, fixture: &str, event: HookEvent) {
    let raw = load_fixture(fixture);
    let payload = build_report(event, &raw, None, 1_700_000_000).expect("fixture should extract cleanly");
    daemon.report(payload).await;
}
