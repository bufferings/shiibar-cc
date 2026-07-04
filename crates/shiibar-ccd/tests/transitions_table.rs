//! Table-driven test mirroring DESIGN.md §3.1 exactly: one case per cell of
//! the transition table (event × current state). This does not touch any
//! socket or filesystem — `transitions::apply_report` / `apply_seen` are
//! pure functions.

use shiibar_ccd::state::AgentEntry;
use shiibar_ccd::transitions::{apply_report, apply_seen, Outcome};
use shiibar_cc_proto::{HookEvent, NotificationType, ReportPayload, SessionStartSource, Status};

const NOW: i64 = 1_000_000;

fn base_payload(event: HookEvent) -> ReportPayload {
    ReportPayload {
        event,
        target: "t".into(),
        session_id: "s-new".into(),
        cwd: "/new".into(),
        transcript_path: None,
        ts: 12345,
        source: None,
        notification_type: None,
        message: None,
        prompt: None,
        background_tasks: None,
    }
}

fn existing(status: Status) -> AgentEntry {
    AgentEntry {
        target: "t".into(),
        status,
        session_id: "s-old".into(),
        cwd: "/old".into(),
        since: 500,
        last_seen: 500,
        task: Some("old task".into()),
        message: if status == Status::Blocked {
            Some("old reason".into())
        } else {
            None
        },
    }
}

/// What a table cell says should happen.
#[derive(Debug, Clone, Copy)]
enum Cell {
    /// "ignore": unregistered target, event produces no entry at all.
    Ignore,
    /// "register(x)": unregistered target becomes a fresh entry with status x.
    Register(Status),
    /// A registered entry's resulting status (covers both "—" cells, where
    /// this equals the starting status, and real transitions).
    ToStatus(Status),
    /// "remove": registered entry is deleted.
    Removed,
}

/// Run one event across the 5 starting points a table row has
/// (unregistered / idle / working / blocked / done) and assert against
/// `cells` in that order.
fn assert_row(label: &str, build: impl Fn(&mut ReportPayload), cells: [Cell; 5]) {
    let starts: [Option<Status>; 5] = [
        None,
        Some(Status::Idle),
        Some(Status::Working),
        Some(Status::Blocked),
        Some(Status::Done),
    ];

    for (start, cell) in starts.into_iter().zip(cells) {
        let mut payload = base_payload(HookEvent::SessionStart); // overwritten by `build`
        build(&mut payload);
        let existing_entry = start.map(existing);
        let outcome = apply_report(existing_entry.as_ref(), &payload, NOW);
        let case = format!("{label} / start={start:?}");

        match cell {
            Cell::Ignore => {
                assert_eq!(outcome, Outcome::Ignored, "{case}: expected ignore (Ignored)");
            }
            Cell::Register(expected) => {
                let Outcome::Updated { entry, previous } = outcome else {
                    panic!("{case}: expected Updated (register), got {outcome:?}");
                };
                assert!(previous.is_none(), "{case}: register must have no previous entry");
                assert_eq!(entry.status, expected, "{case}: registered status");
                assert_eq!(entry.since, NOW, "{case}: since on fresh registration");
                assert_eq!(entry.last_seen, NOW, "{case}: last_seen on fresh registration");
            }
            Cell::ToStatus(expected) => {
                let Outcome::Updated { entry, previous } = outcome else {
                    panic!("{case}: expected Updated, got {outcome:?}");
                };
                let previous = previous.unwrap_or_else(|| panic!("{case}: expected a previous entry"));
                assert_eq!(entry.status, expected, "{case}: resulting status");
                // §3.2: session_id / cwd / last_seen always overwrite.
                assert_eq!(entry.session_id, "s-new", "{case}: session_id must overwrite");
                assert_eq!(entry.cwd, "/new", "{case}: cwd must overwrite");
                assert_eq!(entry.last_seen, NOW, "{case}: last_seen always bumped by report");
                // §3.1: since only moves on an actual value change.
                if previous.status == expected {
                    assert_eq!(
                        entry.since, previous.since,
                        "{case}: same-value transition must preserve `since`"
                    );
                } else {
                    assert_eq!(entry.since, NOW, "{case}: real transition bumps `since`");
                }
            }
            Cell::Removed => {
                let Outcome::Removed { previous } = outcome else {
                    panic!("{case}: expected Removed (remove), got {outcome:?}");
                };
                assert_eq!(
                    previous.status,
                    start.expect("Removed only applies to registered starts"),
                    "{case}: removed entry's last-known status"
                );
            }
        }
    }
}

#[test]
fn session_start_startup_clear_resume_always_idle() {
    for source in [
        SessionStartSource::Startup,
        SessionStartSource::Clear,
        SessionStartSource::Resume,
        SessionStartSource::Other,
    ] {
        assert_row(
            &format!("SessionStart(source={source:?})"),
            |p| {
                p.event = HookEvent::SessionStart;
                p.source = Some(source);
            },
            [
                Cell::Register(Status::Idle),
                Cell::ToStatus(Status::Idle),
                Cell::ToStatus(Status::Idle),
                Cell::ToStatus(Status::Idle),
                Cell::ToStatus(Status::Idle),
            ],
        );
    }
}

#[test]
fn session_start_compact_is_ignored_and_never_forces_idle() {
    assert_row(
        "SessionStart(source=compact)",
        |p| {
            p.event = HookEvent::SessionStart;
            p.source = Some(SessionStartSource::Compact);
        },
        [
            Cell::Ignore,
            Cell::ToStatus(Status::Idle),
            Cell::ToStatus(Status::Working),
            Cell::ToStatus(Status::Blocked),
            Cell::ToStatus(Status::Done),
        ],
    );
}

#[test]
fn user_prompt_submit_always_working() {
    assert_row(
        "UserPromptSubmit",
        |p| {
            p.event = HookEvent::UserPromptSubmit;
            p.prompt = Some("do the thing".into());
        },
        [
            Cell::Register(Status::Working),
            Cell::ToStatus(Status::Working),
            Cell::ToStatus(Status::Working),
            Cell::ToStatus(Status::Working),
            Cell::ToStatus(Status::Working),
        ],
    );
}

#[test]
fn post_tool_use_only_releases_blocked() {
    for event in [HookEvent::PostToolUse, HookEvent::PostToolUseFailure] {
        assert_row(
            &format!("{event:?}"),
            |p| p.event = event,
            [
                Cell::Register(Status::Working),
                Cell::ToStatus(Status::Idle),
                Cell::ToStatus(Status::Working),
                Cell::ToStatus(Status::Working),
                Cell::ToStatus(Status::Done),
            ],
        );
    }
}

#[test]
fn notification_blocking_types_always_blocked() {
    for nt in [
        NotificationType::PermissionPrompt,
        NotificationType::AgentNeedsInput,
        NotificationType::ElicitationDialog,
        NotificationType::Unknown,
    ] {
        assert_row(
            &format!("Notification({nt:?})"),
            |p| {
                p.event = HookEvent::Notification;
                p.notification_type = Some(nt);
                p.message = Some("please confirm".into());
            },
            [
                Cell::Register(Status::Blocked),
                Cell::ToStatus(Status::Blocked),
                Cell::ToStatus(Status::Blocked),
                Cell::ToStatus(Status::Blocked),
                Cell::ToStatus(Status::Blocked),
            ],
        );
    }
}

#[test]
fn notification_idle_prompt_only_blocks_from_working() {
    assert_row(
        "Notification(idle_prompt)",
        |p| {
            p.event = HookEvent::Notification;
            p.notification_type = Some(NotificationType::IdlePrompt);
        },
        [
            Cell::Ignore,
            Cell::ToStatus(Status::Idle),
            Cell::ToStatus(Status::Blocked),
            Cell::ToStatus(Status::Blocked), // stays blocked ("—")
            Cell::ToStatus(Status::Done),
        ],
    );
}

#[test]
fn notification_ignored_family_never_changes_status() {
    for nt in [
        NotificationType::AuthSuccess,
        NotificationType::ElicitationComplete,
        NotificationType::ElicitationResponse,
        NotificationType::AgentCompleted,
    ] {
        assert_row(
            &format!("Notification({nt:?})"),
            |p| {
                p.event = HookEvent::Notification;
                p.notification_type = Some(nt);
            },
            [
                Cell::Ignore,
                Cell::ToStatus(Status::Idle),
                Cell::ToStatus(Status::Working),
                Cell::ToStatus(Status::Blocked),
                Cell::ToStatus(Status::Done),
            ],
        );
    }
}

#[test]
fn stop_with_background_tasks_always_working() {
    assert_row(
        "Stop(background_tasks non-empty)",
        |p| {
            p.event = HookEvent::Stop;
            p.background_tasks = Some(vec![serde_json::json!({"id": "1", "status": "running"})]);
        },
        [
            Cell::Register(Status::Working),
            Cell::ToStatus(Status::Working),
            Cell::ToStatus(Status::Working),
            Cell::ToStatus(Status::Working),
            Cell::ToStatus(Status::Working),
        ],
    );
}

#[test]
fn stop_without_background_tasks_always_done() {
    for background_tasks in [None, Some(vec![])] {
        assert_row(
            &format!("Stop(background_tasks={background_tasks:?})"),
            |p| {
                p.event = HookEvent::Stop;
                p.background_tasks = background_tasks.clone();
            },
            [
                Cell::Register(Status::Done),
                Cell::ToStatus(Status::Done),
                Cell::ToStatus(Status::Done),
                Cell::ToStatus(Status::Done),
                Cell::ToStatus(Status::Done),
            ],
        );
    }
}

#[test]
fn session_end_deletes_registered_and_ignores_unregistered() {
    assert_row(
        "SessionEnd",
        |p| p.event = HookEvent::SessionEnd,
        [
            Cell::Ignore,
            Cell::Removed,
            Cell::Removed,
            Cell::Removed,
            Cell::Removed,
        ],
    );
}

#[test]
fn seen_only_moves_done_to_idle() {
    // `seen` isn't a `report` event, so it's exercised directly against
    // `apply_seen` rather than through `assert_row`.
    assert_eq!(apply_seen(None, NOW), Outcome::Ignored, "unregistered: ignore");

    for status in [Status::Idle, Status::Working, Status::Blocked] {
        let prev = existing(status);
        assert_eq!(
            apply_seen(Some(&prev), NOW),
            Outcome::Ignored,
            "{status:?}: seen has no effect (—)"
        );
    }

    let done = existing(Status::Done);
    let Outcome::Updated { entry, previous } = apply_seen(Some(&done), NOW) else {
        panic!("expected done -> idle transition");
    };
    assert_eq!(previous.unwrap().status, Status::Done);
    assert_eq!(entry.status, Status::Idle);
    assert_eq!(entry.since, NOW, "seen->idle is a real transition, since bumps");
}

// --- Targeted attribute-rule tests (§3.2), beyond pure status cells ---

#[test]
fn notification_sets_message_only_when_it_actually_blocks() {
    // idle_prompt from idle: no transition, no message set.
    let idle = existing(Status::Idle);
    let mut p = base_payload(HookEvent::Notification);
    p.notification_type = Some(NotificationType::IdlePrompt);
    p.message = Some("ignored message".into());
    let Outcome::Updated { entry, .. } = apply_report(Some(&idle), &p, NOW) else {
        panic!("expected Updated");
    };
    assert_eq!(entry.message, None);

    // idle_prompt from working: transitions to blocked, message is set.
    let working = existing(Status::Working);
    let Outcome::Updated { entry, .. } = apply_report(Some(&working), &p, NOW) else {
        panic!("expected Updated");
    };
    assert_eq!(entry.status, Status::Blocked);
    assert_eq!(entry.message.as_deref(), Some("ignored message"));
}

#[test]
fn leaving_blocked_clears_message() {
    let blocked = existing(Status::Blocked);
    assert_eq!(blocked.message.as_deref(), Some("old reason"));

    let mut p = base_payload(HookEvent::PostToolUse);
    p.event = HookEvent::PostToolUse;
    let Outcome::Updated { entry, .. } = apply_report(Some(&blocked), &p, NOW) else {
        panic!("expected Updated");
    };
    assert_eq!(entry.status, Status::Working);
    assert_eq!(entry.message, None, "message must be cleared on leaving blocked");
}

#[test]
fn task_persists_across_status_changes_and_only_user_prompt_submit_updates_it() {
    let idle = existing(Status::Idle);
    assert_eq!(idle.task.as_deref(), Some("old task"));

    let mut p = base_payload(HookEvent::Stop);
    p.background_tasks = None;
    let Outcome::Updated { entry, .. } = apply_report(Some(&idle), &p, NOW) else {
        panic!("expected Updated");
    };
    assert_eq!(entry.task.as_deref(), Some("old task"), "Stop must not touch task");

    let mut p2 = base_payload(HookEvent::UserPromptSubmit);
    p2.prompt = Some("new task".into());
    let Outcome::Updated { entry, .. } = apply_report(Some(&idle), &p2, NOW) else {
        panic!("expected Updated");
    };
    assert_eq!(entry.task.as_deref(), Some("new task"));
}
