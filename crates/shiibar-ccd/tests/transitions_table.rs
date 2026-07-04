//! Table-driven test mirroring DESIGN.md §3.4 exactly: one case per cell of
//! the transition table (event × current state), with the status column and
//! the `unreviewed` flag column asserted independently (§3.4: "the status
//! column and the flag column are independent"). This does not touch any
//! socket or filesystem — `transitions::apply_report` / `apply_seen` are
//! pure functions.

use shiibar_ccd::state::AgentEntry;
use shiibar_ccd::transitions::{Outcome, apply_report, apply_seen};
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

fn existing(status: Status, unreviewed: bool) -> AgentEntry {
    AgentEntry {
        target: "t".into(),
        status,
        unreviewed,
        session_id: "s-old".into(),
        cwd: "/old".into(),
        since: 500,
        last_seen: 500,
        task: Some("old task".into()),
        message: if status == Status::Waiting {
            Some("old reason".into())
        } else {
            None
        },
    }
}

/// What a table cell says should happen to *status* (the flag column is
/// asserted separately, see the `flag behavior` tests below each row).
#[derive(Debug, Clone, Copy)]
enum Cell {
    /// "ignore": unregistered target, event produces no entry at all.
    Ignore,
    /// "register(x, flag)": unregistered target becomes a fresh entry with
    /// status x and `unreviewed` == flag (§3.4: registration cells obey the
    /// flag column too — Notification(waiting-inducing) and Stop(empty)
    /// register already-unreviewed, everything else registers clear).
    Register(Status, bool),
    /// A registered entry's resulting status (covers both "—" cells, where
    /// this equals the starting status, and real transitions).
    ToStatus(Status),
    /// "remove": registered entry is deleted.
    Removed,
}

/// Run one event across the 4 starting points a table row has (unregistered
/// / working / waiting / idle) and assert the *status* column against
/// `cells` in that order. Starting `unreviewed` is fixed at `false` here —
/// the flag column has its own dedicated assertions per row.
fn assert_row(label: &str, build: impl Fn(&mut ReportPayload), cells: [Cell; 4]) {
    let starts: [Option<Status>; 4] = [
        None,
        Some(Status::Working),
        Some(Status::Waiting),
        Some(Status::Idle),
    ];

    for (start, cell) in starts.into_iter().zip(cells) {
        let mut payload = base_payload(HookEvent::SessionStart); // overwritten by `build`
        build(&mut payload);
        let existing_entry = start.map(|s| existing(s, false));
        let outcome = apply_report(existing_entry.as_ref(), &payload, NOW);
        let case = format!("{label} / start={start:?}");

        match cell {
            Cell::Ignore => {
                assert_eq!(outcome, Outcome::Ignored, "{case}: expected ignore (Ignored)");
            }
            Cell::Register(expected, expected_flag) => {
                let Outcome::Updated { entry, previous } = outcome else {
                    panic!("{case}: expected Updated (register), got {outcome:?}");
                };
                assert!(previous.is_none(), "{case}: register must have no previous entry");
                assert_eq!(entry.status, expected, "{case}: registered status");
                assert_eq!(
                    entry.unreviewed, expected_flag,
                    "{case}: unreviewed flag on fresh registration"
                );
                assert_eq!(entry.since, NOW, "{case}: since on fresh registration");
                assert_eq!(entry.last_seen, NOW, "{case}: last_seen on fresh registration");
            }
            Cell::ToStatus(expected) => {
                let Outcome::Updated { entry, previous } = outcome else {
                    panic!("{case}: expected Updated, got {outcome:?}");
                };
                let previous = previous.unwrap_or_else(|| panic!("{case}: expected a previous entry"));
                assert_eq!(entry.status, expected, "{case}: resulting status");
                // §3.6: session_id / cwd / last_seen always overwrite.
                assert_eq!(entry.session_id, "s-new", "{case}: session_id must overwrite");
                assert_eq!(entry.cwd, "/new", "{case}: cwd must overwrite");
                assert_eq!(entry.last_seen, NOW, "{case}: last_seen always bumped by report");
                // §3.4: since only moves on an actual value change.
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

// ---------------------------------------------------------------------
// SessionStart
// ---------------------------------------------------------------------

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
                Cell::Register(Status::Idle, false),
                Cell::ToStatus(Status::Idle),
                Cell::ToStatus(Status::Idle),
                Cell::ToStatus(Status::Idle),
            ],
        );
    }
}

#[test]
fn session_start_non_compact_always_lowers_the_flag() {
    for start in [Status::Working, Status::Waiting, Status::Idle] {
        let prev = existing(start, true);
        let mut p = base_payload(HookEvent::SessionStart);
        p.source = Some(SessionStartSource::Startup);
        let Outcome::Updated { entry, .. } = apply_report(Some(&prev), &p, NOW) else {
            panic!("expected Updated");
        };
        assert!(!entry.unreviewed, "SessionStart(startup) from {start:?}+unreviewed must clear the flag");
    }

    let Outcome::Updated { entry, .. } = apply_report(None, &{
        let mut p = base_payload(HookEvent::SessionStart);
        p.source = Some(SessionStartSource::Startup);
        p
    }, NOW) else {
        panic!("expected Updated (register)");
    };
    assert!(!entry.unreviewed, "a freshly registered idle has no flag");
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
            Cell::ToStatus(Status::Working),
            Cell::ToStatus(Status::Waiting),
            Cell::ToStatus(Status::Idle),
        ],
    );
}

#[test]
fn session_start_compact_never_touches_the_flag() {
    for start in [Status::Working, Status::Waiting, Status::Idle] {
        for starting_flag in [false, true] {
            let prev = existing(start, starting_flag);
            let mut p = base_payload(HookEvent::SessionStart);
            p.source = Some(SessionStartSource::Compact);
            let Outcome::Updated { entry, .. } = apply_report(Some(&prev), &p, NOW) else {
                panic!("expected Updated (no-op passthrough)");
            };
            assert_eq!(
                entry.unreviewed, starting_flag,
                "compact must never touch the flag (start={start:?}, flag={starting_flag})"
            );
        }
    }
}

// ---------------------------------------------------------------------
// UserPromptSubmit
// ---------------------------------------------------------------------

#[test]
fn user_prompt_submit_always_working() {
    assert_row(
        "UserPromptSubmit",
        |p| {
            p.event = HookEvent::UserPromptSubmit;
            p.prompt = Some("do the thing".into());
        },
        [
            Cell::Register(Status::Working, false),
            Cell::ToStatus(Status::Working),
            Cell::ToStatus(Status::Working),
            Cell::ToStatus(Status::Working),
        ],
    );
}

#[test]
fn user_prompt_submit_always_lowers_the_flag() {
    for start in [Status::Working, Status::Waiting, Status::Idle] {
        let prev = existing(start, true);
        let mut p = base_payload(HookEvent::UserPromptSubmit);
        p.prompt = Some("do the thing".into());
        let Outcome::Updated { entry, .. } = apply_report(Some(&prev), &p, NOW) else {
            panic!("expected Updated");
        };
        assert!(!entry.unreviewed, "UserPromptSubmit from {start:?}+unreviewed must clear the flag");
    }
}

// ---------------------------------------------------------------------
// PostToolUse / PostToolUseFailure
// ---------------------------------------------------------------------

#[test]
fn post_tool_use_only_releases_waiting() {
    for event in [HookEvent::PostToolUse, HookEvent::PostToolUseFailure] {
        assert_row(
            &format!("{event:?}"),
            |p| p.event = event,
            [
                Cell::Register(Status::Working, false),
                Cell::ToStatus(Status::Working),
                Cell::ToStatus(Status::Working),
                Cell::ToStatus(Status::Idle),
            ],
        );
    }
}

#[test]
fn post_tool_use_lowers_the_flag_only_when_it_actually_releases_waiting() {
    for event in [HookEvent::PostToolUse, HookEvent::PostToolUseFailure] {
        // waiting -> working: releases, flag forced down.
        let waiting = existing(Status::Waiting, true);
        let p = { let mut p = base_payload(event); p.event = event; p };
        let Outcome::Updated { entry, .. } = apply_report(Some(&waiting), &p, NOW) else {
            panic!("expected Updated");
        };
        assert_eq!(entry.status, Status::Working);
        assert!(!entry.unreviewed, "{event:?}: waiting->working must clear the flag");

        // idle+unreviewed (a completed-but-unseen entry): PostToolUse
        // doesn't apply to idle at all ("—"), so the flag must survive.
        let idle = existing(Status::Idle, true);
        let Outcome::Updated { entry, .. } = apply_report(Some(&idle), &p, NOW) else {
            panic!("expected Updated (no-op passthrough)");
        };
        assert_eq!(entry.status, Status::Idle);
        assert!(entry.unreviewed, "{event:?}: idle is untouched, flag must survive");
    }
}

// ---------------------------------------------------------------------
// Notification
// ---------------------------------------------------------------------

#[test]
fn notification_waiting_inducing_types_always_waiting() {
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
                Cell::Register(Status::Waiting, true),
                Cell::ToStatus(Status::Waiting),
                Cell::ToStatus(Status::Waiting),
                Cell::ToStatus(Status::Waiting),
            ],
        );
    }
}

#[test]
fn notification_missing_notification_type_behaves_like_unknown() {
    assert_row(
        "Notification(missing notification_type)",
        |p| {
            p.event = HookEvent::Notification;
            p.notification_type = None;
        },
        [
            Cell::Register(Status::Waiting, true),
            Cell::ToStatus(Status::Waiting),
            Cell::ToStatus(Status::Waiting),
            Cell::ToStatus(Status::Waiting),
        ],
    );
}

#[test]
fn notification_waiting_inducing_always_raises_the_flag_even_from_waiting_to_waiting() {
    for nt in [
        NotificationType::PermissionPrompt,
        NotificationType::AgentNeedsInput,
        NotificationType::ElicitationDialog,
        NotificationType::Unknown,
    ] {
        for (start, starting_flag) in [
            (Status::Working, false),
            (Status::Idle, false),
            (Status::Waiting, false),
            (Status::Waiting, true), // already waiting+seen: a new request re-raises it
        ] {
            let prev = existing(start, starting_flag);
            let mut p = base_payload(HookEvent::Notification);
            p.notification_type = Some(nt);
            p.message = Some("please confirm again".into());
            let Outcome::Updated { entry, .. } = apply_report(Some(&prev), &p, NOW) else {
                panic!("expected Updated");
            };
            assert!(
                entry.unreviewed,
                "{nt:?} from {start:?}(flag={starting_flag}) must (re-)raise the flag"
            );
            assert_eq!(entry.message.as_deref(), Some("please confirm again"));
        }
    }
}

#[test]
fn notification_idle_prompt_is_fully_ignored() {
    assert_row(
        "Notification(idle_prompt)",
        |p| {
            p.event = HookEvent::Notification;
            p.notification_type = Some(NotificationType::IdlePrompt);
        },
        [
            Cell::Ignore,
            Cell::ToStatus(Status::Working),
            Cell::ToStatus(Status::Waiting),
            Cell::ToStatus(Status::Idle),
        ],
    );
}

#[test]
fn notification_idle_prompt_never_touches_the_flag() {
    for start in [Status::Working, Status::Waiting, Status::Idle] {
        for starting_flag in [false, true] {
            let prev = existing(start, starting_flag);
            let mut p = base_payload(HookEvent::Notification);
            p.notification_type = Some(NotificationType::IdlePrompt);
            let Outcome::Updated { entry, .. } = apply_report(Some(&prev), &p, NOW) else {
                panic!("expected Updated (no-op passthrough)");
            };
            assert_eq!(entry.status, start);
            assert_eq!(entry.unreviewed, starting_flag);
        }
    }
}

#[test]
fn notification_ignored_family_never_changes_status_or_flag() {
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
                Cell::ToStatus(Status::Working),
                Cell::ToStatus(Status::Waiting),
                Cell::ToStatus(Status::Idle),
            ],
        );

        for start in [Status::Working, Status::Waiting, Status::Idle] {
            let prev = existing(start, true);
            let mut p = base_payload(HookEvent::Notification);
            p.notification_type = Some(nt);
            let Outcome::Updated { entry, .. } = apply_report(Some(&prev), &p, NOW) else {
                panic!("expected Updated (no-op passthrough)");
            };
            assert!(entry.unreviewed, "{nt:?}: ignored family must never touch the flag");
        }
    }
}

// ---------------------------------------------------------------------
// Stop
// ---------------------------------------------------------------------

#[test]
fn stop_with_background_tasks_always_working() {
    assert_row(
        "Stop(background_tasks non-empty)",
        |p| {
            p.event = HookEvent::Stop;
            p.background_tasks = Some(vec![serde_json::json!({"id": "1", "status": "running"})]);
        },
        [
            Cell::Register(Status::Working, false),
            Cell::ToStatus(Status::Working),
            Cell::ToStatus(Status::Working),
            Cell::ToStatus(Status::Working),
        ],
    );
}

#[test]
fn stop_with_background_tasks_always_lowers_the_flag() {
    for start in [Status::Working, Status::Waiting, Status::Idle] {
        let prev = existing(start, true);
        let mut p = base_payload(HookEvent::Stop);
        p.background_tasks = Some(vec![serde_json::json!({"id": "1", "status": "running"})]);
        let Outcome::Updated { entry, .. } = apply_report(Some(&prev), &p, NOW) else {
            panic!("expected Updated");
        };
        assert!(!entry.unreviewed, "Stop(bg residual) from {start:?}+unreviewed must clear the flag");
    }
}

#[test]
fn stop_without_background_tasks_always_idle() {
    for background_tasks in [None, Some(vec![])] {
        assert_row(
            &format!("Stop(background_tasks={background_tasks:?})"),
            |p| {
                p.event = HookEvent::Stop;
                p.background_tasks = background_tasks.clone();
            },
            [
                Cell::Register(Status::Idle, true),
                Cell::ToStatus(Status::Idle),
                Cell::ToStatus(Status::Idle),
                Cell::ToStatus(Status::Idle),
            ],
        );
    }
}

#[test]
fn stop_without_background_tasks_always_raises_the_flag_even_idle_to_idle() {
    for background_tasks in [None, Some(vec![])] {
        for (start, starting_flag) in [
            (Status::Working, false),
            (Status::Waiting, false),
            (Status::Idle, false),
            (Status::Idle, true),
        ] {
            let prev = existing(start, starting_flag);
            let mut p = base_payload(HookEvent::Stop);
            p.background_tasks = background_tasks.clone();
            let Outcome::Updated { entry, .. } = apply_report(Some(&prev), &p, NOW) else {
                panic!("expected Updated");
            };
            assert!(
                entry.unreviewed,
                "Stop(empty) from {start:?}(flag={starting_flag}) must (re-)raise the flag"
            );
        }
    }
}

// ---------------------------------------------------------------------
// SessionEnd
// ---------------------------------------------------------------------

#[test]
fn session_end_deletes_registered_and_ignores_unregistered() {
    assert_row(
        "SessionEnd",
        |p| p.event = HookEvent::SessionEnd,
        [Cell::Ignore, Cell::Removed, Cell::Removed, Cell::Removed],
    );
}

// ---------------------------------------------------------------------
// seen (not a `report` event, exercised directly against `apply_seen`)
// ---------------------------------------------------------------------

#[test]
fn seen_lowers_the_flag_without_touching_status_and_is_a_no_op_when_already_clear() {
    assert_eq!(apply_seen(None, NOW), Outcome::Ignored, "unregistered: ignore");

    for status in [Status::Working, Status::Waiting, Status::Idle] {
        // Already clear: no observable effect (§3.4 "—").
        let clear = existing(status, false);
        assert_eq!(
            apply_seen(Some(&clear), NOW),
            Outcome::Ignored,
            "{status:?}: seen with no flag set is a no-op"
        );

        // Flag set: lowered, status/since untouched, last_seen untouched
        // (seen is deliberately not a `last_seen`-bumping event, §3.6).
        let flagged = existing(status, true);
        let Outcome::Updated { entry, previous } = apply_seen(Some(&flagged), NOW) else {
            panic!("{status:?}: expected seen to lower the flag");
        };
        let previous = previous.unwrap();
        assert_eq!(previous.status, status);
        assert_eq!(entry.status, status, "seen never changes status");
        assert!(!entry.unreviewed);
        assert_eq!(entry.since, flagged.since, "seen never bumps since");
        assert_eq!(entry.last_seen, flagged.last_seen, "seen never bumps last_seen");
    }
}

// --- Targeted attribute-rule tests (§3.6), beyond pure status/flag cells ---

#[test]
fn leaving_waiting_clears_message() {
    let waiting = existing(Status::Waiting, false);
    assert_eq!(waiting.message.as_deref(), Some("old reason"));

    let mut p = base_payload(HookEvent::PostToolUse);
    p.event = HookEvent::PostToolUse;
    let Outcome::Updated { entry, .. } = apply_report(Some(&waiting), &p, NOW) else {
        panic!("expected Updated");
    };
    assert_eq!(entry.status, Status::Working);
    assert_eq!(entry.message, None, "message must be cleared on leaving waiting");
}

#[test]
fn task_persists_across_status_changes_and_only_user_prompt_submit_updates_it() {
    let idle = existing(Status::Idle, false);
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
