//! `wait` integration tests against a real (in-process) shiibar-ccd, per the
//! M2 task brief: "already blocked resolves immediately / waits for
//! appearance then resolves / timeout / target disappears" — the four
//! `WaitOutcome` branches. Exit-code mapping (124/2)
//! is shiibar-cc's job and is tested there; here we assert the
//! `WaitOutcome` shiibar-cc-client hands back.

mod support;

use shiibar_cc_client::selector::Selector;
use shiibar_cc_client::wait::{WaitOutcome, wait};
use shiibar_cc_proto::{HookEvent, NotificationType, SessionStartSource, Status};
use std::time::Duration;
use support::{TestDaemon, report_payload};

#[test]
fn matches_immediately_when_already_in_the_wanted_status() {
    let daemon = TestDaemon::start();

    let mut payload = report_payload(HookEvent::Notification, "target-1", "/proj/a", 1);
    payload.notification_type = Some(NotificationType::PermissionPrompt);
    payload.message = Some("Bash: rm -rf /".to_string());
    daemon.report(payload); // unregistered + Notification(permission_prompt) => registered blocked

    // Give the fire-and-forget report a moment to be processed before we
    // open the subscribe connection (otherwise the snapshot could beat it —
    // not a synchronization requirement, just avoids test flakiness since
    // report has no response to await).
    std::thread::sleep(Duration::from_millis(50));

    let selector = Selector::parse("target-1", "/irrelevant");
    let outcome = wait(
        &daemon.sock_path,
        &selector,
        Status::Blocked,
        Some(Duration::from_secs(5)),
    )
    .unwrap();
    match outcome {
        WaitOutcome::Matched(agent) => {
            assert_eq!(agent.target, "target-1");
            assert_eq!(agent.status, Status::Blocked);
        }
        other => panic!("expected Matched, got {other:?}"),
    }

    daemon.shutdown();
}

#[test]
fn matches_after_the_agent_appears_and_reaches_the_wanted_status() {
    let daemon = TestDaemon::start();
    // Nothing registered yet: `wait` must resolve dynamically once the
    // target shows up in a status_changed event, not just the snapshot.
    let selector = Selector::parse("target-2", "/irrelevant");

    let wait_thread = std::thread::spawn({
        let sock_path = daemon.sock_path.clone();
        move || {
            wait(
                &sock_path,
                &selector,
                Status::Blocked,
                Some(Duration::from_secs(5)),
            )
        }
    });

    // Let `wait` open its subscribe connection and read the (empty)
    // snapshot before the agent appears.
    std::thread::sleep(Duration::from_millis(100));

    let mut payload = report_payload(HookEvent::Notification, "target-2", "/proj/b", 1);
    payload.notification_type = Some(NotificationType::AgentNeedsInput);
    payload.message = Some("needs input".to_string());
    daemon.report(payload);

    let outcome = wait_thread.join().unwrap().unwrap();
    match outcome {
        WaitOutcome::Matched(agent) => assert_eq!(agent.target, "target-2"),
        other => panic!("expected Matched, got {other:?}"),
    }

    daemon.shutdown();
}

#[test]
fn times_out_when_the_status_never_arrives() {
    let daemon = TestDaemon::start();
    let selector = Selector::parse("target-3", "/irrelevant");

    let outcome = wait(
        &daemon.sock_path,
        &selector,
        Status::Done,
        Some(Duration::from_millis(200)),
    )
    .unwrap();
    assert_eq!(outcome, WaitOutcome::TimedOut);

    daemon.shutdown();
}

#[test]
fn returns_removed_when_the_tracked_agent_is_removed_while_waiting() {
    let daemon = TestDaemon::start();

    let mut payload = report_payload(HookEvent::SessionStart, "target-4", "/proj/d", 1);
    payload.source = Some(SessionStartSource::Startup);
    daemon.report(payload); // registers idle
    std::thread::sleep(Duration::from_millis(50));

    let selector = Selector::parse("target-4", "/irrelevant");
    let wait_thread = std::thread::spawn({
        let sock_path = daemon.sock_path.clone();
        move || {
            wait(
                &sock_path,
                &selector,
                Status::Done,
                Some(Duration::from_secs(5)),
            )
        }
    });

    std::thread::sleep(Duration::from_millis(100));
    daemon.remove("target-4");

    let outcome = wait_thread.join().unwrap().unwrap();
    assert_eq!(outcome, WaitOutcome::Removed);

    daemon.shutdown();
}
