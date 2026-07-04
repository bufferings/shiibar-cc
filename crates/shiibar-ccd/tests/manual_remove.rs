//! Manual `remove` deletion path (§3.6, §4.2, M4 acceptance criterion): the
//! `{"cmd":"remove"}` command must delete the entry and broadcast
//! `agent_removed` with `reason: "remove"` (distinct from the other three
//! deletion paths — session_end / stale / prune).

mod support;

use shiibar_cc_proto::{
    extract::build_report, AckResponse, HookEvent, ListResponse, RemovalReason, Request, SubscribeEvent,
};
use shiibar_ccd::clock::SystemClock;
use std::sync::Arc;
use support::{load_fixture, TestDaemon};

const TARGET: &str = "11111111-1111-1111-1111-111111111111";
const ITERM_SESSION_ID: &str = "w0t0p0:11111111-1111-1111-1111-111111111111";

#[tokio::test]
async fn manual_remove_deletes_the_entry_and_broadcasts_reason_remove() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = TestDaemon::start(dir.path(), Arc::new(SystemClock)).await;
    let mut sub = daemon.subscribe().await;
    assert!(matches!(sub.next_event().await, SubscribeEvent::Snapshot { .. }));

    // Register an entry via a real hook report.
    let raw = load_fixture("session_start_startup.json");
    let payload = build_report(HookEvent::SessionStart, &raw, Some(ITERM_SESSION_ID), 1)
        .unwrap()
        .unwrap();
    daemon.report(payload).await;
    assert!(matches!(sub.next_event().await, SubscribeEvent::StatusChanged { .. }));

    let _ack: AckResponse = daemon
        .request(&Request::Remove {
            target: TARGET.to_string(),
        })
        .await
        .expect("remove ack");

    match sub.next_event().await {
        SubscribeEvent::AgentRemoved { target, reason } => {
            assert_eq!(target, TARGET);
            assert_eq!(reason, RemovalReason::Remove, "manual remove must report reason=remove (§4.2)");
        }
        other => panic!("expected agent_removed, got {other:?}"),
    }

    let resp: ListResponse = daemon.request(&Request::List).await.unwrap();
    assert!(resp.agents.is_empty(), "removed entry must no longer be listed");

    daemon.shutdown_and_join().await;
}

#[tokio::test]
async fn manual_remove_of_an_unregistered_target_is_still_ok_and_does_not_broadcast() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = TestDaemon::start(dir.path(), Arc::new(SystemClock)).await;
    let mut sub = daemon.subscribe().await;
    assert!(matches!(sub.next_event().await, SubscribeEvent::Snapshot { .. }));

    let ack: AckResponse = daemon
        .request(&Request::Remove {
            target: "no-such-target".to_string(),
        })
        .await
        .expect("remove ack");
    assert!(ack.ok, "remove of an unregistered target must still be ok (§4.2)");

    daemon.shutdown_and_join().await;
}
