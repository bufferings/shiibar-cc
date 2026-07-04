//! Restart persistence test (M1 acceptance criterion): a few reports ->
//! shutdown -> restart -> `list` must show the same `blocked` entry
//! restored from `state.json`.
//!
//! Ordering (report has landed before we act on it) is confirmed by
//! reading the `subscribe` stream, never by sleeping.

mod support;

use shiibar_proto::{extract::build_report, HookEvent, ListResponse, Request, Status, SubscribeEvent};
use shiibard::clock::SystemClock;
use std::sync::Arc;
use support::{load_fixture, TestDaemon};

const TARGET: &str = "session:11111111-1111-1111-1111-111111111111";

#[tokio::test]
async fn blocked_entry_survives_a_restart() {
    let dir = tempfile::tempdir().unwrap();

    {
        let daemon = TestDaemon::start(dir.path(), Arc::new(SystemClock)).await;
        let mut sub = daemon.subscribe().await;
        assert!(matches!(sub.next_event().await, SubscribeEvent::Snapshot { .. }));

        let prompt = load_fixture("user_prompt_submit.json");
        let payload = build_report(HookEvent::UserPromptSubmit, &prompt, None, 1_700_000_000).unwrap();
        daemon.report(payload).await;
        match sub.next_event().await {
            SubscribeEvent::StatusChanged { agent } => assert_eq!(agent.status, Status::Working),
            other => panic!("expected working, got {other:?}"),
        }

        let notif = load_fixture("notification_permission_prompt.json");
        let payload = build_report(HookEvent::Notification, &notif, None, 1_700_000_100).unwrap();
        daemon.report(payload).await;
        match sub.next_event().await {
            SubscribeEvent::StatusChanged { agent } => assert_eq!(agent.status, Status::Blocked),
            other => panic!("expected blocked, got {other:?}"),
        }

        // Only send `shutdown` once we've *observed* the blocked transition,
        // so we know state.json already reflects it (persist happens before
        // the broadcast in Core::handle_report).
        daemon.shutdown_and_join().await;
    }

    // Fresh process (well, fresh Core + listener) over the same state dir.
    let daemon2 = TestDaemon::start(dir.path(), Arc::new(SystemClock)).await;
    let resp: ListResponse = daemon2.request(&Request::List).await.unwrap();
    let restored = resp
        .agents
        .iter()
        .find(|a| a.target == TARGET)
        .unwrap_or_else(|| panic!("target not restored, agents = {:?}", resp.agents));
    assert_eq!(restored.status, Status::Blocked);
    assert_eq!(restored.message.as_deref(), Some("Bash: cargo test"));

    daemon2.shutdown_and_join().await;
}
