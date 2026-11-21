//! Merging by pid, rekeying and nested sessions (DESIGN.md §3.6 "merging by
//! pid" and "nested sessions"; §3.5; §4.2).
//!
//! The tests drive a `Core` directly. It is bound to a temp state dir and a
//! fake clock. Reading its broadcast channel lets every case assert the exact
//! table and the exact event sequence.

use shiibar_cc_proto::{
    HookEvent, NotificationType, ReconcileSession, RemovalReason, ReportPayload, SessionStartSource,
    Status,
};
use shiibar_ccd::clock::FakeClock;
use shiibar_ccd::core::{BroadcastEvent, Core, BROADCAST_CAPACITY};
use shiibar_ccd::logging::{Level, Logger};
use shiibar_ccd::paths::StateDir;
use shiibar_ccd::state::AgentEntry;
use std::sync::Arc;
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

    /// Simulate a daemon restart on the same state dir.
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

    fn entry(&self, target: &str) -> Option<&AgentEntry> {
        self.core.agents.iter().find(|a| a.target == target)
    }

    fn targets(&self) -> Vec<String> {
        let mut t: Vec<String> = self.core.agents.iter().map(|a| a.target.clone()).collect();
        t.sort();
        t
    }

    fn report(&mut self, payload: ReportPayload) {
        self.core.handle_report(payload);
    }

    fn reconcile(&mut self, complete: bool, sessions: &[ReconcileSession]) {
        self.core.handle_reconcile(complete, sessions);
    }

    /// Put an entry straight into the table (with its in-memory pid).
    fn insert(&mut self, entry: AgentEntry) {
        self.core.agents.push(entry);
    }
}

fn report(event: HookEvent, target: &str, session_id: &str, pid: Option<u32>) -> ReportPayload {
    ReportPayload {
        event,
        target: Some(target.into()),
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

fn session_start(target: &str, session_id: &str, pid: Option<u32>, source: SessionStartSource) -> ReportPayload {
    let mut r = report(HookEvent::SessionStart, target, session_id, pid);
    r.source = Some(source);
    r
}

fn session(target: &str, status: Status, session_id: &str, pid: Option<u32>) -> ReconcileSession {
    ReconcileSession {
        target: target.into(),
        session_id: session_id.into(),
        cwd: format!("/proj/{session_id}"),
        status,
        waiting_for: (status == Status::Waiting).then(|| "permission prompt".to_string()),
        pid,
        update_only: false,
    }
}

fn update_only(target: &str, status: Status, session_id: &str, pid: Option<u32>) -> ReconcileSession {
    ReconcileSession {
        update_only: true,
        ..session(target, status, session_id, pid)
    }
}

/// A fully populated entry, so attribute carry-over can be asserted.
fn entry(target: &str, status: Status, unreviewed: bool, pid: Option<u32>) -> AgentEntry {
    AgentEntry {
        target: target.into(),
        status,
        unreviewed,
        session_id: "s-parent".into(),
        cwd: "/proj/parent".into(),
        since: START - 300,
        last_seen: START - 100,
        task: Some("parent task".into()),
        message: (status == Status::Waiting).then(|| "parent reason".to_string()),
        last_assistant_message: (status == Status::Idle).then(|| "parent reply".to_string()),
        created_at: START - 500,
        last_report_at: START - 200,
        pid,
    }
}

fn removed(target: &str, reason: RemovalReason, to: Option<&str>) -> BroadcastEvent {
    BroadcastEvent::AgentRemoved {
        target: target.into(),
        reason,
        to: to.map(str::to_string),
    }
}

fn status_changed_targets(events: &[BroadcastEvent]) -> Vec<String> {
    events
        .iter()
        .filter_map(|e| match e {
            BroadcastEvent::StatusChanged(a) => Some(a.target.clone()),
            _ => None,
        })
        .collect()
}

// ---------------------------------------------------------------------------
// Hook report: entry resolution (§3.6 "hook report" (a)/(b)/(c))
// ---------------------------------------------------------------------------

#[test]
fn report_for_a_registered_target_applies_to_it_and_overwrites_the_pid() {
    let mut h = Harness::new();
    h.insert(entry("iterm2:A", Status::Idle, false, Some(10)));
    h.report(report(HookEvent::UserPromptSubmit, "iterm2:A", "s-parent", Some(11)));
    let e = h.entry("iterm2:A").unwrap();
    assert_eq!(e.status, Status::Working);
    assert_eq!(e.pid, Some(11));
    assert_eq!(h.core.agents.len(), 1);
}

#[test]
fn report_for_an_unregistered_target_applies_to_the_entry_with_the_same_pid_without_changing_its_target() {
    // Both directions: a process: report reaching a terminal entry, and a
    // terminal-target report reaching a process: entry.
    for (entry_target, report_target) in [("iterm2:A", "process:10"), ("process:10", "ghostty:/dev/ttys004")] {
        let mut h = Harness::new();
        h.insert(entry(entry_target, Status::Idle, true, Some(10)));
        h.report(report(HookEvent::UserPromptSubmit, report_target, "s-parent", Some(10)));
        assert_eq!(h.targets(), vec![entry_target.to_string()], "{report_target}: no new entry");
        let e = h.entry(entry_target).unwrap();
        assert_eq!(e.status, Status::Working, "{report_target}: §3.4 applied to the pid match");
        assert!(!e.unreviewed);
        assert_eq!(e.pid, Some(10));
        assert_eq!(status_changed_targets(&h.events()), vec![entry_target.to_string()]);
    }
}

#[test]
fn report_with_neither_target_nor_pid_match_uses_the_unregistered_column() {
    let mut h = Harness::new();
    h.insert(entry("iterm2:A", Status::Idle, false, Some(10)));
    // An "ignore" row registers nothing.
    let mut idle_prompt = report(HookEvent::Notification, "process:20", "s-other", Some(20));
    idle_prompt.notification_type = Some(NotificationType::IdlePrompt);
    h.report(idle_prompt);
    assert_eq!(h.targets(), vec!["iterm2:A".to_string()]);
    // A registering row creates an entry under the report's target and pid.
    h.report(report(HookEvent::UserPromptSubmit, "process:20", "s-other", Some(20)));
    let e = h.entry("process:20").expect("registered");
    assert_eq!(e.status, Status::Working);
    assert_eq!(e.pid, Some(20));
}

#[test]
fn session_end_removes_only_the_entry_resolved_by_the_same_order() {
    let mut h = Harness::new();
    h.insert(entry("iterm2:A", Status::Working, false, Some(10)));
    h.insert(entry("process:20", Status::Working, false, Some(20)));
    // Target unregistered; only the pid matches iterm2:A.
    h.report(report(HookEvent::SessionEnd, "process:10", "s-parent", Some(10)));
    assert_eq!(h.targets(), vec!["process:20".to_string()]);
    assert_eq!(
        h.events(),
        vec![removed("iterm2:A", RemovalReason::SessionEnd, None)],
        "session_end for the resolved entry, and no rekey"
    );
}

#[test]
fn a_report_without_pid_or_an_entry_with_unknown_pid_matches_by_target_only() {
    let mut h = Harness::new();
    h.insert(entry("iterm2:A", Status::Idle, false, Some(10)));
    h.insert(entry("iterm2:B", Status::Idle, false, None));
    h.report(report(HookEvent::UserPromptSubmit, "process:10", "s-x", None));
    h.report(report(HookEvent::UserPromptSubmit, "process:30", "s-y", Some(30)));
    assert_eq!(
        h.targets(),
        vec!["iterm2:A", "iterm2:B", "process:10", "process:30"],
        "neither report may reach an entry through the pid"
    );
}

#[test]
fn a_report_without_pid_leaves_the_entry_pid_unchanged() {
    let mut h = Harness::new();
    h.insert(entry("iterm2:A", Status::Idle, false, Some(10)));
    h.report(report(HookEvent::UserPromptSubmit, "iterm2:A", "s-parent", None));
    let e = h.entry("iterm2:A").unwrap();
    assert_eq!(e.status, Status::Working, "sanity: the report applied");
    assert_eq!(e.pid, Some(10));
}

// ---------------------------------------------------------------------------
// Nested sessions (§3.6 "nested sessions")
// ---------------------------------------------------------------------------

/// (entry target, report target): a registered target, and the pid
/// fallback, each with a terminal target and a process: target.
const NESTED_CASES: [(&str, &str); 4] = [
    ("iterm2:A", "iterm2:A"),
    ("process:10", "process:10"),
    ("iterm2:A", "process:10"),
    ("process:10", "iterm2:A"),
];

fn nested_child_reports() -> Vec<ReportPayload> {
    let mut out = Vec::new();
    let mut start = report(HookEvent::SessionStart, "", "s-child", Some(10));
    start.source = Some(SessionStartSource::Startup);
    out.push(start);
    let mut prompt = report(HookEvent::UserPromptSubmit, "", "s-child", Some(10));
    prompt.prompt = Some("child prompt".into());
    out.push(prompt);
    out.push(report(HookEvent::PostToolUse, "", "s-child", Some(10)));
    let mut notification = report(HookEvent::Notification, "", "s-child", Some(10));
    notification.notification_type = Some(NotificationType::PermissionPrompt);
    out.push(notification);
    out.push(report(HookEvent::Stop, "", "s-child", Some(10)));
    out.push(report(HookEvent::SessionEnd, "", "s-child", Some(10)));
    out
}

#[test]
fn a_nested_session_report_with_the_same_pid_and_another_session_id_leaves_the_entry_untouched() {
    for (entry_target, report_target) in NESTED_CASES {
        for status in [Status::Working, Status::Waiting] {
            for mut child in nested_child_reports() {
                let mut h = Harness::new();
                h.insert(entry(entry_target, status, status == Status::Waiting, Some(10)));
                h.clock.advance(60);
                let before = h.core.agents.clone();
                let _ = std::fs::remove_file(h.state_json());
                child.target = Some(report_target.into());
                let label = format!("{entry_target} <- {report_target} {:?} from {status:?}", child.event);
                h.report(child);
                assert_eq!(h.core.agents, before, "{label}: entry must not change (incl. last_seen / last_report_at)");
                assert!(h.events().is_empty(), "{label}: nothing broadcast");
                assert!(!h.state_json().exists(), "{label}: nothing persisted");
            }
        }
    }
}

#[test]
fn a_clear_or_resume_session_start_with_the_same_pid_switches_the_session() {
    for (entry_target, report_target) in NESTED_CASES {
        for source in [SessionStartSource::Clear, SessionStartSource::Resume] {
            let mut h = Harness::new();
            h.insert(entry(entry_target, Status::Waiting, true, Some(10)));
            h.report(session_start(report_target, "s-new", Some(10), source));
            let label = format!("{entry_target} <- {report_target} {source:?}");
            assert_eq!(h.targets(), vec![entry_target.to_string()], "{label}");
            let e = h.entry(entry_target).unwrap();
            assert_eq!(e.session_id, "s-new", "{label}: session_id overwritten");
            assert_eq!(e.status, Status::Idle, "{label}");
            assert!(!e.unreviewed, "{label}: flag lowered");
        }
    }
}

#[test]
fn a_fork_compact_missing_or_unknown_source_session_start_with_the_same_pid_is_ignored() {
    let fork: SessionStartSource = serde_json::from_str(r#""fork""#).unwrap();
    for (entry_target, report_target) in NESTED_CASES {
        for source in [Some(fork), Some(SessionStartSource::Compact), None, Some(SessionStartSource::Other)] {
            let mut h = Harness::new();
            h.insert(entry(entry_target, Status::Working, false, Some(10)));
            let before = h.core.agents.clone();
            let mut r = report(HookEvent::SessionStart, report_target, "s-other", Some(10));
            r.source = source;
            h.report(r);
            assert_eq!(h.core.agents, before, "{entry_target} <- {report_target} {source:?}");
            assert!(h.events().is_empty());
        }
    }
}

#[test]
fn a_report_with_the_same_session_id_is_applied_as_before_including_compact() {
    let mut h = Harness::new();
    h.insert(entry("iterm2:A", Status::Working, false, Some(10)));
    h.clock.advance(60);
    h.report(session_start("iterm2:A", "s-parent", Some(10), SessionStartSource::Compact));
    let e = h.entry("iterm2:A").unwrap();
    assert_eq!(e.status, Status::Working, "compact leaves the status alone (§3.4)");
    assert_eq!(e.last_seen, START + 60, "but the report is applied (last_seen bumped)");
    h.report(report(HookEvent::Stop, "iterm2:A", "s-parent", Some(10)));
    let e = h.entry("iterm2:A").unwrap();
    assert_eq!(e.status, Status::Idle);
    assert!(e.unreviewed);
}

#[test]
fn another_session_id_with_a_different_missing_or_unknown_pid_is_applied_as_before() {
    // (entry pid, report pid)
    for (entry_pid, report_pid) in [(Some(10), Some(11)), (Some(10), None), (None, Some(10))] {
        let mut h = Harness::new();
        h.insert(entry("iterm2:A", Status::Working, false, entry_pid));
        h.report(report(HookEvent::Stop, "iterm2:A", "s-relaunched", report_pid));
        let e = h.entry("iterm2:A").unwrap();
        let label = format!("entry {entry_pid:?} report {report_pid:?}");
        assert_eq!(e.session_id, "s-relaunched", "{label}: session_id overwritten");
        assert_eq!(e.status, Status::Idle, "{label}");
        h.report(report(HookEvent::SessionEnd, "iterm2:A", "s-other", report_pid.map(|p| p + 100)));
        assert!(h.core.agents.is_empty(), "{label}: SessionEnd deletes");
    }
}

#[test]
fn clear_sends_session_end_then_session_start_and_re_registers_under_the_same_target() {
    let mut h = Harness::new();
    h.report(session_start("process:10", "s-1", Some(10), SessionStartSource::Startup));
    let created = h.entry("process:10").unwrap().created_at;
    h.clock.advance(60);
    h.report(report(HookEvent::SessionEnd, "process:10", "s-1", Some(10)));
    assert!(h.core.agents.is_empty());
    h.report(session_start("process:10", "s-2", Some(10), SessionStartSource::Clear));
    let e = h.entry("process:10").expect("re-registered");
    assert_eq!(e.session_id, "s-2");
    assert_eq!(e.status, Status::Idle);
    assert!(e.created_at > created, "a re-registration gets a new created_at");
}

#[test]
fn clear_reports_received_in_reverse_order_keep_the_entry() {
    let mut h = Harness::new();
    h.report(session_start("process:10", "s-1", Some(10), SessionStartSource::Startup));
    h.report(session_start("process:10", "s-2", Some(10), SessionStartSource::Clear));
    h.report(report(HookEvent::SessionEnd, "process:10", "s-1", Some(10)));
    let e = h.entry("process:10").expect("the entry survives the late SessionEnd");
    assert_eq!(e.session_id, "s-2");
}

#[test]
fn a_child_session_between_parent_reports_leaves_the_same_result_as_no_child() {
    let parent_before = |h: &mut Harness| {
        h.report(session_start("iterm2:A", "s-parent", Some(10), SessionStartSource::Startup));
        let mut prompt = report(HookEvent::UserPromptSubmit, "iterm2:A", "s-parent", Some(10));
        prompt.prompt = Some("parent prompt".into());
        h.report(prompt);
    };
    let parent_after = |h: &mut Harness| {
        h.report(report(HookEvent::PostToolUse, "iterm2:A", "s-parent", Some(10)));
    };

    let mut with_child = Harness::new();
    parent_before(&mut with_child);
    with_child.clock.advance(30);
    for mut child in nested_child_reports() {
        child.target = Some("iterm2:A".into());
        with_child.report(child);
    }
    with_child.clock.advance(30);
    parent_after(&mut with_child);

    let mut without_child = Harness::new();
    parent_before(&mut without_child);
    without_child.clock.advance(60);
    parent_after(&mut without_child);

    assert_eq!(with_child.core.agents, without_child.core.agents);
    assert_eq!(with_child.events(), without_child.events());
    let e = with_child.entry("iterm2:A").unwrap();
    assert_eq!(e.status, Status::Working);
    assert_eq!(e.task.as_deref(), Some("parent prompt"));
}

// ---------------------------------------------------------------------------
// Reconcile, complete round (§3.6 "reconcile (complete scan)")
// ---------------------------------------------------------------------------

#[test]
fn rekey_moves_the_entry_in_both_directions_and_carries_every_attribute() {
    for (old, new) in [("process:10", "iterm2:A"), ("iterm2:A", "process:10")] {
        let mut h = Harness::new();
        let before = entry(old, Status::Waiting, false, Some(10));
        h.insert(before.clone());
        h.reconcile(true, &[session(new, Status::Waiting, "s-parent", Some(10))]);
        assert_eq!(h.targets(), vec![new.to_string()], "{old} -> {new}");
        let e = h.entry(new).unwrap().clone();
        assert_eq!(e.status, before.status);
        assert_eq!(e.unreviewed, before.unreviewed, "no new unreviewed from a rekey");
        assert_eq!(e.since, before.since);
        assert_eq!(e.created_at, before.created_at);
        assert_eq!(e.task, before.task);
        assert_eq!(e.last_assistant_message, before.last_assistant_message);
        assert_eq!(e.last_report_at, before.last_report_at);
        assert_eq!(e.session_id, before.session_id);
        assert_eq!(e.pid, Some(10));
        assert_eq!(e.last_seen, START, "the known application after the rekey bumps last_seen");

        let events = h.events();
        assert_eq!(events.len(), 2, "{old} -> {new}: {events:?}");
        assert_eq!(events[0], removed(old, RemovalReason::Rekey, Some(new)));
        match &events[1] {
            BroadcastEvent::StatusChanged(a) => {
                assert_eq!(a.target, new);
                assert_eq!(a.status, Status::Waiting);
            }
            other => panic!("expected status_changed after the rekey, got {other:?}"),
        }
    }
}

#[test]
fn rekey_does_not_raise_unreviewed_where_a_new_discovery_would() {
    let mut h = Harness::new();
    h.insert(entry("process:10", Status::Idle, false, Some(10)));
    h.reconcile(true, &[session("iterm2:A", Status::Idle, "s-parent", Some(10))]);
    assert!(!h.entry("iterm2:A").unwrap().unreviewed);
}

#[test]
fn the_status_changed_after_a_rekey_is_the_only_one_and_reflects_the_known_update() {
    let mut h = Harness::new();
    h.insert(entry("process:10", Status::Working, false, Some(10)));
    h.reconcile(true, &[session("iterm2:A", Status::Waiting, "s-new", Some(10))]);
    let events = h.events();
    assert_eq!(status_changed_targets(&events), vec!["iterm2:A".to_string()]);
    match &events[1] {
        BroadcastEvent::StatusChanged(a) => {
            assert_eq!(a.status, Status::Waiting);
            assert!(a.unreviewed, "a known transition to waiting raises the flag (§3.5)");
            assert_eq!(a.session_id, "s-new");
            assert_eq!(a.message.as_deref(), Some("permission prompt"));
        }
        other => panic!("expected status_changed, got {other:?}"),
    }
}

#[test]
fn rekey_events_stay_adjacent_among_other_events_of_the_round() {
    let mut h = Harness::new();
    h.insert(entry("iterm2:gone", Status::Idle, false, Some(1)));
    h.insert(entry("iterm2:known", Status::Working, false, Some(2)));
    h.insert(entry("process:10", Status::Idle, false, Some(10)));
    h.reconcile(
        true,
        &[
            session("process:20", Status::Working, "s-new", Some(20)),
            session("iterm2:A", Status::Idle, "s-parent", Some(10)),
            session("iterm2:known", Status::Waiting, "s-known", Some(2)),
        ],
    );
    let events = h.events();
    let at = events
        .iter()
        .position(|e| matches!(e, BroadcastEvent::AgentRemoved { reason: RemovalReason::Rekey, .. }))
        .expect("a rekey event");
    assert_eq!(events[at], removed("process:10", RemovalReason::Rekey, Some("iterm2:A")));
    assert!(
        matches!(&events[at + 1], BroadcastEvent::StatusChanged(a) if a.target == "iterm2:A"),
        "the new target's status_changed follows immediately: {events:?}"
    );
    assert!(events.contains(&removed("iterm2:gone", RemovalReason::Prune, None)));
    assert_eq!(
        status_changed_targets(&events).iter().filter(|t| *t == "iterm2:A").count(),
        1
    );
}

#[test]
fn a_same_pid_entry_whose_target_is_live_is_not_rekeyed_and_the_session_is_added() {
    let mut h = Harness::new();
    h.insert(entry("iterm2:A", Status::Working, false, Some(10)));
    h.reconcile(
        true,
        &[
            session("iterm2:A", Status::Working, "s-parent", Some(10)),
            session("process:10", Status::Idle, "s-other", Some(10)),
        ],
    );
    assert_eq!(h.targets(), vec!["iterm2:A", "process:10"]);
    assert!(h
        .events()
        .iter()
        .all(|e| !matches!(e, BroadcastEvent::AgentRemoved { .. })));
}

#[test]
fn registered_targets_are_applied_first_so_a_stale_entry_pid_cannot_steal_another_session() {
    // The entry's pid (10) equals the pid of another session in the same
    // round; its own session now reports pid 11. Applying the registered
    // target first overwrites the pid, so process:10 becomes a new entry.
    let sessions = [
        session("process:10", Status::Idle, "s-other", Some(10)),
        session("iterm2:A", Status::Working, "s-parent", Some(11)),
    ];
    let mut forward = Harness::new();
    forward.insert(entry("iterm2:A", Status::Working, false, Some(10)));
    forward.reconcile(true, &sessions);
    let mut reversed = Harness::new();
    reversed.insert(entry("iterm2:A", Status::Working, false, Some(10)));
    reversed.reconcile(true, &[sessions[1].clone(), sessions[0].clone()]);

    assert_eq!(forward.targets(), vec!["iterm2:A", "process:10"]);
    assert_eq!(forward.entry("iterm2:A").unwrap().pid, Some(11));
    assert_eq!(sorted(&forward.core.agents), sorted(&reversed.core.agents));
}

fn sorted(agents: &[AgentEntry]) -> Vec<AgentEntry> {
    let mut v = agents.to_vec();
    v.sort_by(|a, b| a.target.cmp(&b.target));
    v
}

#[test]
fn the_result_of_a_complete_round_does_not_depend_on_session_order() {
    let setup = |h: &mut Harness| {
        h.insert(entry("process:10", Status::Idle, true, Some(10)));
        h.insert(entry("iterm2:B", Status::Working, false, Some(20)));
        h.insert(entry("iterm2:C", Status::Working, false, Some(30)));
        h.insert(entry("iterm2:gone", Status::Idle, false, Some(40)));
    };
    let sessions = [
        session("iterm2:A", Status::Idle, "s-10", Some(10)), // rekey process:10 -> iterm2:A
        session("iterm2:B", Status::Waiting, "s-20", Some(30)), // registered; its pid is C's old pid
        session("process:30", Status::Working, "s-30", Some(20)), // pid of B's old pid; B is live
        session("iterm2:C", Status::Working, "s-c", Some(31)),
        session("process:50", Status::Idle, "s-50", Some(50)), // brand new
    ];
    let mut results = Vec::new();
    for order in permutations(sessions.len()) {
        let mut h = Harness::new();
        setup(&mut h);
        let ordered: Vec<ReconcileSession> = order.iter().map(|&i| sessions[i].clone()).collect();
        h.reconcile(true, &ordered);
        let mut events: Vec<String> = h.events().iter().map(|e| format!("{e:?}")).collect();
        events.sort();
        results.push((sorted(&h.core.agents), events));
    }
    let first = &results[0];
    assert_eq!(
        first.0.iter().map(|a| a.target.as_str()).collect::<Vec<_>>(),
        vec!["iterm2:A", "iterm2:B", "iterm2:C", "process:30", "process:50"]
    );
    for r in &results {
        assert_eq!(r, first);
    }
}

fn permutations(n: usize) -> Vec<Vec<usize>> {
    if n == 0 {
        return vec![Vec::new()];
    }
    let mut out = Vec::new();
    for p in permutations(n - 1) {
        for i in 0..=p.len() {
            let mut q = p.clone();
            q.insert(i, n - 1);
            out.push(q);
        }
    }
    out
}

#[test]
fn several_same_pid_entries_rekey_the_newest_last_seen_then_created_at() {
    let mut h = Harness::new();
    let mut older = entry("process:10", Status::Idle, false, Some(10));
    older.last_seen = START - 50;
    let mut newer = entry("iterm2:B", Status::Idle, false, Some(10));
    newer.last_seen = START - 10;
    h.insert(older);
    h.insert(newer);
    h.reconcile(true, &[session("iterm2:A", Status::Idle, "s", Some(10))]);
    let events = h.events();
    assert_eq!(events[0], removed("iterm2:B", RemovalReason::Rekey, Some("iterm2:A")));
    assert!(events.contains(&removed("process:10", RemovalReason::Prune, None)));

    let mut h = Harness::new();
    let mut first = entry("process:10", Status::Idle, false, Some(10));
    first.created_at = START - 900;
    let mut second = entry("iterm2:B", Status::Idle, false, Some(10));
    second.created_at = START - 800;
    h.insert(second);
    h.insert(first);
    h.reconcile(true, &[session("iterm2:A", Status::Idle, "s", Some(10))]);
    assert_eq!(h.events()[0], removed("iterm2:B", RemovalReason::Rekey, Some("iterm2:A")));
}

#[test]
fn same_pid_entries_under_two_terminal_targets_are_not_merged_and_the_unscanned_one_is_pruned() {
    let mut h = Harness::new();
    h.insert(entry("iterm2:A", Status::Working, false, Some(10)));
    h.insert(entry("apple-terminal:/dev/ttys001", Status::Working, false, Some(10)));
    h.reconcile(true, &[session("apple-terminal:/dev/ttys001", Status::Working, "s-parent", Some(10))]);
    assert_eq!(h.targets(), vec!["apple-terminal:/dev/ttys001"]);
    let removals: Vec<BroadcastEvent> = h
        .events()
        .into_iter()
        .filter(|e| matches!(e, BroadcastEvent::AgentRemoved { .. }))
        .collect();
    assert_eq!(removals, vec![removed("iterm2:A", RemovalReason::Prune, None)], "a prune, never a rekey");
}

#[test]
fn prune_judges_the_table_after_rekeys_and_removes_absent_process_entries() {
    let mut h = Harness::new();
    h.insert(entry("process:10", Status::Idle, false, Some(10)));
    h.insert(entry("process:99", Status::Idle, false, Some(99)));
    h.reconcile(true, &[session("ghostty:/dev/ttys004", Status::Idle, "s", Some(10))]);
    assert_eq!(h.targets(), vec!["ghostty:/dev/ttys004"], "the rekeyed entry survives prune");
    assert!(h.events().contains(&removed("process:99", RemovalReason::Prune, None)));
}

// ---------------------------------------------------------------------------
// Reconcile, incomplete round (§3.6 update-only and non-update-only sessions)
// ---------------------------------------------------------------------------

#[test]
fn update_only_sessions_never_create_rekey_or_prune() {
    let mut h = Harness::new();
    h.insert(entry("iterm2:unscanned", Status::Idle, false, Some(99)));
    h.reconcile(false, &[update_only("process:10", Status::Waiting, "s", Some(10))]);
    assert_eq!(h.targets(), vec!["iterm2:unscanned"], "nothing created, nothing pruned");
    assert!(h.events().is_empty());
}

#[test]
fn update_only_session_applies_the_known_rules_to_the_target_match_else_the_pid_match() {
    for entry_target in ["process:10", "iterm2:A"] {
        let mut h = Harness::new();
        h.insert(entry(entry_target, Status::Working, false, Some(10)));
        h.insert(entry("iterm2:unscanned", Status::Idle, false, Some(99)));
        h.clock.advance(60);
        h.reconcile(false, &[update_only("process:10", Status::Waiting, "s-new", Some(10))]);
        assert_eq!(h.targets().len(), 2, "{entry_target}: no create, no prune");
        let e = h.entry(entry_target).expect("target unchanged, no rekey");
        assert_eq!(e.status, Status::Waiting);
        assert!(e.unreviewed, "{entry_target}: a known transition to waiting raises the flag");
        assert_eq!(e.message.as_deref(), Some("permission prompt"));
        assert_eq!(e.since, START + 60);
        assert_eq!(e.last_seen, START + 60);
        assert_eq!(e.session_id, "s-new");
        assert_eq!(e.cwd, "/proj/s-new");
        assert!(h
            .events()
            .iter()
            .all(|ev| matches!(ev, BroadcastEvent::StatusChanged(a) if a.target == entry_target)));
    }
}

#[test]
fn incomplete_round_non_update_only_sessions_update_by_target_then_pid_else_add_and_never_prune() {
    let mut h = Harness::new();
    h.insert(entry("iterm2:A", Status::Working, false, Some(10)));
    h.insert(entry("process:20", Status::Working, false, Some(20)));
    h.insert(entry("iterm2:unscanned", Status::Idle, false, Some(99)));
    h.reconcile(
        false,
        &[
            session("iterm2:A", Status::Idle, "s-a", Some(10)),
            session("ghostty:/dev/ttys004", Status::Waiting, "s-20", Some(20)),
            session("iterm2:new", Status::Working, "s-new", Some(30)),
        ],
    );
    assert_eq!(
        h.targets(),
        vec!["iterm2:A", "iterm2:new", "iterm2:unscanned", "process:20"],
        "pid match updated in place (no rekey), new one added, nothing pruned"
    );
    assert_eq!(h.entry("iterm2:A").unwrap().status, Status::Idle);
    assert_eq!(h.entry("process:20").unwrap().status, Status::Waiting);
    assert!(h
        .events()
        .iter()
        .all(|e| !matches!(e, BroadcastEvent::AgentRemoved { .. })));
}

// ---------------------------------------------------------------------------
// pid lifetime (§3.6 attribute `pid`)
// ---------------------------------------------------------------------------

#[test]
fn reconcile_overwrites_the_pid_only_when_the_session_carries_one() {
    let mut h = Harness::new();
    h.insert(entry("iterm2:A", Status::Working, false, Some(10)));
    h.reconcile(false, &[session("iterm2:A", Status::Working, "s-parent", None)]);
    assert_eq!(h.entry("iterm2:A").unwrap().pid, Some(10));
    h.reconcile(false, &[session("iterm2:A", Status::Working, "s-parent", Some(11))]);
    assert_eq!(h.entry("iterm2:A").unwrap().pid, Some(11));
    h.reconcile(false, &[session("process:7", Status::Working, "s-7", Some(7))]);
    assert_eq!(h.entry("process:7").unwrap().pid, Some(7), "a new entry starts with the session's pid");
}

#[test]
fn after_a_restart_every_pid_is_unknown_and_a_saved_pid_does_not_merge() {
    let mut h = Harness::new();
    h.report(session_start("process:10", "s-1", Some(10), SessionStartSource::Startup));
    h.report(session_start("iterm2:A", "s-2", Some(20), SessionStartSource::Startup));
    let raw = std::fs::read_to_string(h.state_json()).unwrap();
    assert!(!raw.contains("\"pid\""), "state.json must not hold pids: {raw}");

    let mut h = h.restart();
    assert_eq!(h.targets(), vec!["iterm2:A", "process:10"], "process: target survives the restart");
    assert!(h.core.agents.iter().all(|a| a.pid.is_none()));
    h.report(report(HookEvent::UserPromptSubmit, "iterm2:B", "s-3", Some(10)));
    assert_eq!(
        h.targets(),
        vec!["iterm2:A", "iterm2:B", "process:10"],
        "the saved pid 10 must not route this report to process:10"
    );
}

#[test]
fn a_process_target_report_switching_session_id_overwrites_the_same_entry() {
    // Inside one process the session id changes through a clear / resume
    // SessionStart (§3.6 rule 3), and with the entry's pid unknown (after a
    // restart) through any report (rule 2); both overwrite the same entry.
    let mut h = Harness::new();
    h.report(session_start("process:10", "s-1", Some(10), SessionStartSource::Startup));
    h.report(session_start("process:10", "s-2", Some(10), SessionStartSource::Resume));
    assert_eq!(h.targets(), vec!["process:10"]);
    assert_eq!(h.entry("process:10").unwrap().session_id, "s-2");

    let mut h = h.restart();
    h.report(report(HookEvent::UserPromptSubmit, "process:10", "s-3", Some(10)));
    assert_eq!(h.targets(), vec!["process:10"]);
    let e = h.entry("process:10").unwrap();
    assert_eq!(e.session_id, "s-3");
    assert_eq!(e.status, Status::Working);
}

#[test]
fn seen_and_remove_for_the_old_target_after_a_rekey_change_nothing() {
    let mut h = Harness::new();
    h.insert(entry("process:10", Status::Idle, true, Some(10)));
    h.reconcile(true, &[session("iterm2:A", Status::Idle, "s-parent", Some(10))]);
    let _ = h.events();
    let before = h.core.agents.clone();
    h.core.handle_seen("process:10");
    h.core.handle_remove("process:10");
    assert_eq!(h.core.agents, before);
    assert!(h.events().is_empty());
    assert!(h.entry("iterm2:A").unwrap().unreviewed);
}
