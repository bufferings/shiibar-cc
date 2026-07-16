//! Restart persistence test (M1 acceptance criterion, extended for the
//! respec'd model): a few reports -> shutdown -> restart -> `list` must show
//! the same `waiting` entry, **with `unreviewed` still set**, restored from
//! `state.json`.
//!
//! Ordering (report has landed before we act on it) is confirmed by
//! reading the `subscribe` stream, never by sleeping.

mod support;

use shiibar_cc_proto::{extract::build_report, HookEvent, ListResponse, Request, Status, SubscribeEvent};
use shiibar_ccd::clock::SystemClock;
use std::sync::Arc;
use support::{load_fixture, TestDaemon};

const TARGET: &str = "iterm2:11111111-1111-1111-1111-111111111111";
const ITERM_SESSION_ID: &str = "w0t0p0:11111111-1111-1111-1111-111111111111";

#[tokio::test]
async fn waiting_entry_and_its_unreviewed_flag_survive_a_restart() {
    let dir = tempfile::tempdir().unwrap();

    {
        let daemon = TestDaemon::start(dir.path(), Arc::new(SystemClock)).await;
        let mut sub = daemon.subscribe().await;
        assert!(matches!(sub.next_event().await, SubscribeEvent::Snapshot { .. }));

        let prompt = load_fixture("user_prompt_submit.json");
        let payload = build_report(HookEvent::UserPromptSubmit, &prompt, Some("iTerm.app"), Some(ITERM_SESSION_ID), None, 1_700_000_000)
            .unwrap()
            .unwrap();
        daemon.report(payload).await;
        match sub.next_event().await {
            SubscribeEvent::StatusChanged { agent } => assert_eq!(agent.status, Status::Working),
            other => panic!("expected working, got {other:?}"),
        }

        let notif = load_fixture("notification_permission_prompt.json");
        let payload = build_report(HookEvent::Notification, &notif, Some("iTerm.app"), Some(ITERM_SESSION_ID), None, 1_700_000_100)
            .unwrap()
            .unwrap();
        daemon.report(payload).await;
        match sub.next_event().await {
            SubscribeEvent::StatusChanged { agent } => {
                assert_eq!(agent.status, Status::Waiting);
                assert!(agent.unreviewed);
            }
            other => panic!("expected waiting, got {other:?}"),
        }

        // Only send `shutdown` once we've *observed* the waiting transition,
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
    assert_eq!(restored.status, Status::Waiting);
    assert!(restored.unreviewed, "unreviewed flag must survive a restart too");
    // The real captured permission_prompt message (fixtures/README.md).
    assert_eq!(restored.message.as_deref(), Some("Claude needs your permission"));

    daemon2.shutdown_and_join().await;
}
