//! End-to-end for the task-notification rule (DESIGN.md §3.6): a
//! UserPromptSubmit whose prompt starts with `<task-notification>` (Claude
//! Code's automatic wake-up delivering a background-agent completion to the
//! parent session) still drives the status transition, but the previous
//! `task` survives. The filtering happens in the shared report extraction
//! (`build_report`), so this exercises the real pipeline: raw hook JSON ->
//! extraction -> daemon -> subscribe output.

mod support;

use serde_json::json;
use shiibar_cc_proto::{extract::build_report, HookEvent, Status, SubscribeEvent};
use shiibar_ccd::clock::SystemClock;
use std::sync::Arc;
use support::TestDaemon;

const ITERM_SESSION_ID: &str = "w0t0p0:11111111-1111-1111-1111-111111111111";

async fn send(daemon: &TestDaemon, event: HookEvent, raw: serde_json::Value) {
    let payload = build_report(event, &raw, Some(ITERM_SESSION_ID), 1)
        .expect("extraction should succeed")
        .expect("must not be dropped");
    daemon.report(payload).await;
}

#[tokio::test]
async fn task_notification_wakeup_transitions_status_but_keeps_the_previous_task() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = TestDaemon::start(dir.path(), Arc::new(SystemClock)).await;
    let mut sub = daemon.subscribe().await;
    assert!(matches!(sub.next_event().await, SubscribeEvent::Snapshot { .. }));

    // 1. A real user prompt: registers as working with that task.
    send(
        &daemon,
        HookEvent::UserPromptSubmit,
        json!({"session_id": "s1", "cwd": "/proj", "prompt": "implement the docs build"}),
    )
    .await;
    match sub.next_event().await {
        SubscribeEvent::StatusChanged { agent } => {
            assert_eq!(agent.status, Status::Working);
            assert_eq!(agent.task.as_deref(), Some("implement the docs build"));
        }
        other => panic!("expected status_changed, got {other:?}"),
    }

    // 2. Completion: working -> idle.
    send(
        &daemon,
        HookEvent::Stop,
        json!({"session_id": "s1", "cwd": "/proj"}),
    )
    .await;
    match sub.next_event().await {
        SubscribeEvent::StatusChanged { agent } => assert_eq!(agent.status, Status::Idle),
        other => panic!("expected status_changed(idle), got {other:?}"),
    }

    // 3. The automatic wake-up: idle -> working (§3.4 as usual), but the
    //    task must still read "implement the docs build" (§3.6).
    send(
        &daemon,
        HookEvent::UserPromptSubmit,
        json!({
            "session_id": "s1",
            "cwd": "/proj",
            "prompt": "<task-notification>Background task abc123 completed"
        }),
    )
    .await;
    match sub.next_event().await {
        SubscribeEvent::StatusChanged { agent } => {
            assert_eq!(agent.status, Status::Working, "the transition still applies");
            assert_eq!(
                agent.task.as_deref(),
                Some("implement the docs build"),
                "a task-notification wake-up must not overwrite the user's task (§3.6)"
            );
        }
        other => panic!("expected status_changed, got {other:?}"),
    }

    daemon.shutdown_and_join().await;
}
