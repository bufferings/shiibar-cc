//! Stale sweep test (M1 acceptance criterion): with an injected clock
//! advanced past the 24h threshold (§9), an entry whose `last_seen` is
//! that old gets removed and broadcast as `agent_removed`; a fresher entry
//! is left alone.
//!
//! This drives `Core` directly rather than through the socket + 60s timer:
//! the timer is a 3-line `tokio::time::interval` wrapper (`server::
//! run_sweep_loop`) around this same `Core::sweep_stale`, and faking real
//! wall-clock time to make it fire would add complexity for no additional
//! coverage of the behavior this test cares about.

use shiibar_cc_proto::{HookEvent, ReportPayload, Status};
use shiibar_ccd::clock::FakeClock;
use shiibar_ccd::core::{BroadcastEvent, Core, BROADCAST_CAPACITY};
use shiibar_ccd::logging::{Level, Logger};
use shiibar_ccd::paths::StateDir;
use std::sync::Arc;

fn session_start(target: &str, session_id: &str, ts: i64) -> ReportPayload {
    ReportPayload {
        event: HookEvent::SessionStart,
        target: target.to_string(),
        session_id: session_id.to_string(),
        cwd: "/repo".to_string(),
        transcript_path: None,
        ts,
        source: Some(shiibar_cc_proto::SessionStartSource::Startup),
        notification_type: None,
        message: None,
        prompt: None,
        background_tasks: None,
    }
}

#[test]
fn stale_entry_is_removed_and_broadcast_fresh_entry_is_kept() {
    let dir = tempfile::tempdir().unwrap();
    let state_dir = StateDir::new(dir.path());
    state_dir.ensure().unwrap();

    let clock = Arc::new(FakeClock::new(0));
    let (events_tx, _rx) = tokio::sync::broadcast::channel(BROADCAST_CAPACITY);
    let mut core = Core::load(&state_dir, clock.clone(), Logger::new(Level::Debug), events_tx).unwrap();

    // "a" is last seen at t=0.
    core.handle_report(session_start("a", "s-a", 0));

    // "b" is last seen at t=80_000 (still < 24h before the sweep below).
    clock.set(80_000);
    core.handle_report(session_start("b", "s-b", 80_000));

    let mut rx = core.events_tx.subscribe();

    // t=90_000: "a" is 90_000s stale (> 86_400 = 24h), "b" is only 10_000s.
    clock.set(90_000);
    core.sweep_stale();

    assert_eq!(core.agents.len(), 1, "only the fresh entry should remain");
    assert_eq!(core.agents[0].target, "b");
    assert_eq!(core.agents[0].status, Status::Idle);

    match rx.try_recv().expect("expected an agent_removed broadcast") {
        BroadcastEvent::AgentRemoved { target } => assert_eq!(target, "a"),
        other => panic!("expected AgentRemoved, got {other:?}"),
    }
    assert!(rx.try_recv().is_err(), "b must not be removed/broadcast");

    // Restarting from the persisted state.json must also not resurrect "a".
    let (events_tx2, _rx2) = tokio::sync::broadcast::channel(BROADCAST_CAPACITY);
    let reloaded = Core::load(&state_dir, clock, Logger::new(Level::Debug), events_tx2).unwrap();
    assert_eq!(reloaded.agents.len(), 1);
    assert_eq!(reloaded.agents[0].target, "b");
}
