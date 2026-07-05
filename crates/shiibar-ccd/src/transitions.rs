//! The state machine (DESIGN.md §3, transition table is §3.4). This module
//! is deliberately pure (no I/O, no locking) so the transition table can be
//! tested cell-by-cell without any daemon plumbing.

use crate::state::AgentEntry;
use shiibar_cc_proto::{
    HookEvent, NotificationType, ReconcileSession, ReportPayload, SessionStartSource, Status,
};

/// Result of applying one event to (possibly absent) existing state.
#[derive(Debug, Clone, PartialEq)]
pub enum Outcome {
    /// Unregistered target + an event the table marks "ignore": nothing
    /// happens (no entry created, nothing persisted, nothing broadcast).
    Ignored,
    /// A registered entry was deleted (`SessionEnd`). `previous` is the
    /// entry's final snapshot (fields refreshed from this report) — used to
    /// build the `agent_removed` broadcast.
    Removed { previous: AgentEntry },
    /// An entry was created or updated. `previous` is `None` for a brand
    /// new registration. Callers should compare `entry` against `previous`
    /// with `AgentEntry::observably_differs_from` to decide whether to
    /// broadcast `status_changed` (a newly-created entry always counts as
    /// differing).
    Updated {
        entry: AgentEntry,
        previous: Option<AgentEntry>,
    },
}

impl Outcome {
    fn updated_new(entry: AgentEntry) -> Self {
        Outcome::Updated {
            entry,
            previous: None,
        }
    }

    fn updated(entry: AgentEntry, previous: AgentEntry) -> Self {
        Outcome::Updated {
            entry,
            previous: Some(previous),
        }
    }
}

enum UnregisteredAction {
    Ignore,
    Register(Status),
}

/// Apply a `report` (§4.1/§4.2 payload) to `existing` state for its target.
pub fn apply_report(existing: Option<&AgentEntry>, report: &ReportPayload, now: i64) -> Outcome {
    match report.event {
        HookEvent::SessionStart => apply_session_start(existing, report, now),
        HookEvent::UserPromptSubmit => apply_transition(
            existing,
            report,
            now,
            UnregisteredAction::Register(Status::Working),
            |_current| Some(Status::Working),
            Some(false),
            false,
        ),
        HookEvent::PostToolUse | HookEvent::PostToolUseFailure => apply_transition(
            existing,
            report,
            now,
            UnregisteredAction::Register(Status::Working),
            |current| (current == Status::Waiting).then_some(Status::Working),
            Some(false),
            false,
        ),
        HookEvent::Notification => apply_notification(existing, report, now),
        HookEvent::Stop => apply_stop(existing, report, now),
        HookEvent::SessionEnd => apply_session_end(existing, report, now),
    }
}

/// Apply the `seen` protocol command (§3.4 last row, §4.2). Not a `report`:
/// deliberately does not touch `last_seen` (defined as "time of last
/// report", §3.6), never changes `status`, and only has an observable
/// effect when `unreviewed` was actually set.
pub fn apply_seen(existing: Option<&AgentEntry>, now: i64) -> Outcome {
    let _ = now; // status/since are untouched by design; kept for signature symmetry.
    match existing {
        Some(prev) if prev.unreviewed => {
            let mut next = prev.clone();
            next.unreviewed = false;
            Outcome::updated(next, prev.clone())
        }
        _ => Outcome::Ignored,
    }
}

fn apply_session_start(existing: Option<&AgentEntry>, report: &ReportPayload, now: i64) -> Outcome {
    match report.source {
        Some(SessionStartSource::Compact) => apply_transition(
            existing,
            report,
            now,
            UnregisteredAction::Ignore,
            |_current| None,
            None,
            false,
        ),
        // startup / clear / resume / other-unknown-source / missing-source
        // all behave the same: always (re)enter idle, flag cleared (§3.4).
        _ => apply_transition(
            existing,
            report,
            now,
            UnregisteredAction::Register(Status::Idle),
            |_current| Some(Status::Idle),
            Some(false),
            false,
        ),
    }
}

fn apply_notification(existing: Option<&AgentEntry>, report: &ReportPayload, now: i64) -> Outcome {
    use NotificationType::*;
    match report.notification_type {
        // Missing notification_type on a Notification event is undefined by
        // the table; treated the same as an unrecognized type (waiting-
        // inducing) — prefer a false alarm over a miss (DESIGN.md §3.4).
        // The flag is *always* (re)raised here, even waiting -> waiting
        // (§3.2: "a new request arriving is prioritized"), which is why
        // `registered_transition` unconditionally returns `Some` too.
        None | Some(PermissionPrompt) | Some(AgentNeedsInput) | Some(ElicitationDialog) | Some(Unknown) => {
            apply_transition(
                existing,
                report,
                now,
                UnregisteredAction::Register(Status::Waiting),
                |_current| Some(Status::Waiting),
                Some(true),
                true,
            )
        }
        // idle_prompt is fully ignored in the respec'd model (§3.4): the
        // old working->blocked behavior is gone. idle == your-turn is
        // already knowable from `claude agents` (reconcile backstops any
        // miss), so this notification carries no new information. A
        // registered entry still gets its common attributes (last_seen
        // etc.) refreshed — "ignored" only means "don't register if
        // unregistered, and never touch status/flag".
        Some(IdlePrompt) => apply_transition(
            existing,
            report,
            now,
            UnregisteredAction::Ignore,
            |_current| None,
            None,
            false,
        ),
        Some(AuthSuccess) | Some(ElicitationComplete) | Some(ElicitationResponse) | Some(AgentCompleted) => {
            apply_transition(
                existing,
                report,
                now,
                UnregisteredAction::Ignore,
                |_current| None,
                None,
                false,
            )
        }
    }
}

fn apply_stop(existing: Option<&AgentEntry>, report: &ReportPayload, now: i64) -> Outcome {
    // background_tasks shape is still unverified against real payloads
    // (DESIGN.md §7-2c); only emptiness matters here. A missing field is
    // treated the same as an empty array (§3.4 "empty" branch).
    let has_background_tasks = report
        .background_tasks
        .as_ref()
        .is_some_and(|tasks| !tasks.is_empty());

    let (target_status, flag) = if has_background_tasks {
        (Status::Working, false)
    } else {
        (Status::Idle, true)
    };
    apply_transition(
        existing,
        report,
        now,
        UnregisteredAction::Register(target_status),
        move |_current| Some(target_status),
        Some(flag),
        false,
    )
}

fn apply_session_end(existing: Option<&AgentEntry>, report: &ReportPayload, now: i64) -> Outcome {
    match existing {
        None => Outcome::Ignored,
        Some(prev) => {
            let mut final_entry = prev.clone();
            apply_common_overwrites(&mut final_entry, report, now);
            Outcome::Removed {
                previous: final_entry,
            }
        }
    }
}

/// Shared engine behind every `report` branch above: decide what to do for
/// an unregistered target, and — for a registered one — whether/how it
/// transitions, always applying the common attribute overwrites (§3.6).
///
/// `flag_on_transition`: whenever `registered_transition` (or, for an
/// unregistered target, the registration itself) actually assigns a status —
/// which for an "always transitions" row happens on every call, same-value
/// included (§3.4's "raise/lower even on a same-value cell" rule) — the
/// `unreviewed` flag is forced to this value. `None` means "never touch the
/// flag" (rows that can leave status alone, like `PostToolUse` from `idle`).
fn apply_transition(
    existing: Option<&AgentEntry>,
    report: &ReportPayload,
    now: i64,
    unregistered_action: UnregisteredAction,
    registered_transition: impl Fn(Status) -> Option<Status>,
    flag_on_transition: Option<bool>,
    update_message_on_transition: bool,
) -> Outcome {
    match existing {
        None => match unregistered_action {
            UnregisteredAction::Ignore => Outcome::Ignored,
            UnregisteredAction::Register(status) => {
                let mut entry = create_entry(report, now, status);
                entry.unreviewed = flag_on_transition.unwrap_or(false);
                if update_message_on_transition {
                    entry.message = report.message.clone();
                }
                Outcome::updated_new(entry)
            }
        },
        Some(prev) => {
            let mut next = prev.clone();
            apply_common_overwrites(&mut next, report, now);
            if let Some(new_status) = registered_transition(prev.status) {
                set_status(&mut next, new_status, now);
                if let Some(flag) = flag_on_transition {
                    next.unreviewed = flag;
                }
                if update_message_on_transition {
                    next.message = report.message.clone();
                }
            }
            Outcome::updated(next, prev.clone())
        }
    }
}

fn create_entry(report: &ReportPayload, now: i64, status: Status) -> AgentEntry {
    AgentEntry {
        target: report.target.clone(),
        status,
        unreviewed: false,
        session_id: report.session_id.clone(),
        cwd: report.cwd.clone(),
        since: now,
        last_seen: now,
        task: report.prompt.clone(),
        message: None,
    }
}

/// session_id / cwd / last_seen always overwrite; task overwrites only when
/// this report carries a prompt (UserPromptSubmit) — §3.6.
fn apply_common_overwrites(entry: &mut AgentEntry, report: &ReportPayload, now: i64) {
    entry.session_id = report.session_id.clone();
    entry.cwd = report.cwd.clone();
    entry.last_seen = now;
    if let Some(prompt) = &report.prompt {
        entry.task = Some(prompt.clone());
    }
}

/// Assign `new_status`, bumping `since` only on an actual value change
/// (§3.4 "same-value transitions preserve `since`"), and clearing `message`
/// whenever the entry is not (or is no longer) `waiting` (§3.6).
fn set_status(entry: &mut AgentEntry, new_status: Status, now: i64) {
    if entry.status != new_status {
        entry.status = new_status;
        entry.since = now;
    }
    if new_status != Status::Waiting {
        entry.message = None;
    }
}

/// Apply one `reconcile` session (§3.5) against `existing` state for its
/// target. Reconcile never "ignores" here — every live session either
/// registers a new entry or updates a known one; pruning (dropping entries
/// absent from the live set) is computed separately by the caller from the
/// full session list, since it isn't a per-session decision.
pub fn apply_reconcile_session(
    existing: Option<&AgentEntry>,
    session: &ReconcileSession,
    now: i64,
) -> Outcome {
    match existing {
        None => {
            // New discovery: unreviewed for idle/waiting (you haven't seen
            // this outcome yet), not for working (§3.5).
            let unreviewed = matches!(session.status, Status::Idle | Status::Waiting);
            let message = if session.status == Status::Waiting {
                session.waiting_for.clone()
            } else {
                None
            };
            Outcome::updated_new(AgentEntry {
                target: session.target.clone(),
                status: session.status,
                unreviewed,
                session_id: session.session_id.clone(),
                cwd: session.cwd.clone(),
                since: now,
                last_seen: now,
                task: None,
                message,
            })
        }
        Some(prev) => {
            let mut next = prev.clone();
            next.session_id = session.session_id.clone();
            next.cwd = session.cwd.clone();
            next.last_seen = now;

            if session.status != prev.status {
                next.status = session.status;
                next.since = now;
                match session.status {
                    Status::Waiting => next.unreviewed = true,
                    Status::Working => next.unreviewed = false,
                    // A *known* entry transitioning to idle can't be told
                    // apart from "still idle" via claude agents (it doesn't
                    // expose "just completed"), so this must NOT raise
                    // unreviewed — only the Stop hook can (DESIGN.md §8.12).
                    Status::Idle | Status::Unknown => {}
                }
                next.message = if session.status == Status::Waiting {
                    session.waiting_for.clone()
                } else {
                    None
                };
            } else if session.status == Status::Waiting {
                // Same status, but a reconcile that reconfirms `waiting`
                // still refreshes the reason text (§3.6).
                next.message = session.waiting_for.clone();
            }
            // Status unchanged and not waiting: flag and message untouched
            // (§3.2 "unchanged status: don't touch the flag"), only
            // last_seen was bumped above (keeps a live entry off the stale
            // sweep, §3.5).

            Outcome::updated(next, prev.clone())
        }
    }
}

#[cfg(test)]
mod reconcile_tests {
    use super::*;

    fn entry(status: Status, unreviewed: bool) -> AgentEntry {
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

    fn session(status: Status, waiting_for: Option<&str>) -> ReconcileSession {
        ReconcileSession {
            target: "t".into(),
            session_id: "s-new".into(),
            cwd: "/new".into(),
            status,
            waiting_for: waiting_for.map(str::to_string),
        }
    }

    #[test]
    fn new_discovery_of_idle_or_waiting_raises_unreviewed() {
        for status in [Status::Idle, Status::Waiting] {
            let outcome = apply_reconcile_session(None, &session(status, Some("permission prompt")), 1000);
            let Outcome::Updated { entry, previous } = outcome else {
                panic!("expected Updated");
            };
            assert!(previous.is_none());
            assert_eq!(entry.status, status);
            assert!(entry.unreviewed, "{status:?}: new discovery must be unreviewed");
        }
    }

    #[test]
    fn new_discovery_of_working_is_not_unreviewed() {
        let outcome = apply_reconcile_session(None, &session(Status::Working, None), 1000);
        let Outcome::Updated { entry, .. } = outcome else {
            panic!("expected Updated");
        };
        assert!(!entry.unreviewed);
    }

    #[test]
    fn known_entry_transitioning_to_waiting_raises_unreviewed() {
        let prev = entry(Status::Working, false);
        let outcome = apply_reconcile_session(Some(&prev), &session(Status::Waiting, Some("permission prompt")), 1000);
        let Outcome::Updated { entry, .. } = outcome else {
            panic!("expected Updated");
        };
        assert_eq!(entry.status, Status::Waiting);
        assert!(entry.unreviewed);
        assert_eq!(entry.message.as_deref(), Some("permission prompt"));
    }

    #[test]
    fn known_entry_transitioning_to_idle_does_not_raise_unreviewed() {
        // §8.12: claude agents can't distinguish "just completed" from
        // "idle a while", so reconcile alone must never flag this.
        let prev = entry(Status::Working, false);
        let outcome = apply_reconcile_session(Some(&prev), &session(Status::Idle, None), 1000);
        let Outcome::Updated { entry, .. } = outcome else {
            panic!("expected Updated");
        };
        assert_eq!(entry.status, Status::Idle);
        assert!(!entry.unreviewed);
    }

    #[test]
    fn known_entry_transitioning_from_waiting_to_idle_keeps_an_already_set_flag() {
        // §3.5 (resolved ambiguity): waiting+unreviewed -> idle via reconcile
        // must neither newly raise nor clear the flag — "not yet seen" is
        // still true, so it's carried over as-is.
        let prev = entry(Status::Waiting, true);
        let outcome = apply_reconcile_session(Some(&prev), &session(Status::Idle, None), 1000);
        let Outcome::Updated { entry, .. } = outcome else {
            panic!("expected Updated");
        };
        assert_eq!(entry.status, Status::Idle);
        assert!(entry.unreviewed, "waiting->idle must keep an already-set flag");
        assert_eq!(entry.message, None, "leaving waiting still clears message");
    }

    #[test]
    fn known_entry_transitioning_to_working_lowers_unreviewed() {
        let prev = entry(Status::Waiting, true);
        let outcome = apply_reconcile_session(Some(&prev), &session(Status::Working, None), 1000);
        let Outcome::Updated { entry, .. } = outcome else {
            panic!("expected Updated");
        };
        assert_eq!(entry.status, Status::Working);
        assert!(!entry.unreviewed);
        assert_eq!(entry.message, None, "leaving waiting clears message");
    }

    #[test]
    fn unchanged_status_does_not_touch_the_flag_but_bumps_last_seen() {
        let prev = entry(Status::Waiting, true);
        let outcome = apply_reconcile_session(Some(&prev), &session(Status::Waiting, Some("still waiting")), 2000);
        let Outcome::Updated { entry, previous } = outcome else {
            panic!("expected Updated");
        };
        assert!(previous.unwrap().unreviewed);
        assert_eq!(entry.status, Status::Waiting);
        assert!(entry.unreviewed, "flag preserved, not re-derived");
        assert_eq!(entry.last_seen, 2000);
        assert_eq!(entry.since, 500, "since is untouched by a same-value reconcile");
        assert_eq!(
            entry.message.as_deref(),
            Some("still waiting"),
            "waiting_for refreshes message even without a transition"
        );
    }

    #[test]
    fn unchanged_idle_status_leaves_a_previously_set_flag_alone() {
        let prev = entry(Status::Idle, true); // e.g. completed but not yet focused
        let outcome = apply_reconcile_session(Some(&prev), &session(Status::Idle, None), 2000);
        let Outcome::Updated { entry, .. } = outcome else {
            panic!("expected Updated");
        };
        assert!(entry.unreviewed, "reconcile must not clear a flag it didn't set");
    }

    #[test]
    fn session_id_and_cwd_always_overwrite() {
        let prev = entry(Status::Idle, false);
        let outcome = apply_reconcile_session(Some(&prev), &session(Status::Idle, None), 1000);
        let Outcome::Updated { entry, .. } = outcome else {
            panic!("expected Updated");
        };
        assert_eq!(entry.session_id, "s-new");
        assert_eq!(entry.cwd, "/new");
    }
}
