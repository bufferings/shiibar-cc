//! The state machine (DESIGN.md §3.1). This module is deliberately pure
//! (no I/O, no locking) so the transition table can be tested cell-by-cell
//! without any daemon plumbing.

use crate::state::AgentEntry;
use shiibar_proto::{HookEvent, NotificationType, ReportPayload, SessionStartSource, Status};

/// Result of applying one event to (possibly absent) existing state.
#[derive(Debug, Clone, PartialEq)]
pub enum Outcome {
    /// Unregistered target + an event the table marks "ignore": nothing
    /// happens (no entry created, nothing persisted, nothing broadcast).
    Ignored,
    /// A registered entry was deleted (`SessionEnd`). `previous` is the
    /// entry's final snapshot (fields refreshed from this report) — used to
    /// build the `sessions.jsonl` line and the `agent_removed` broadcast.
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
            false,
        ),
        HookEvent::PostToolUse | HookEvent::PostToolUseFailure => apply_transition(
            existing,
            report,
            now,
            UnregisteredAction::Register(Status::Working),
            |current| (current == Status::Blocked).then_some(Status::Working),
            false,
        ),
        HookEvent::Notification => apply_notification(existing, report, now),
        HookEvent::Stop => apply_stop(existing, report, now),
        HookEvent::SessionEnd => apply_session_end(existing, report, now),
    }
}

/// Apply the `seen` protocol command (§3.1 last row, §4.2). Not a `report`:
/// deliberately does not touch `last_seen` (defined as "time of last
/// report", §3.2) and only has an observable effect from `done`.
pub fn apply_seen(existing: Option<&AgentEntry>, now: i64) -> Outcome {
    match existing {
        Some(prev) if prev.status == Status::Done => {
            let mut next = prev.clone();
            set_status(&mut next, Status::Idle, now);
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
            false,
        ),
        // startup / clear / resume / other-unknown-source / missing-source
        // all behave the same: always (re)enter idle (§3.1).
        _ => apply_transition(
            existing,
            report,
            now,
            UnregisteredAction::Register(Status::Idle),
            |_current| Some(Status::Idle),
            false,
        ),
    }
}

fn apply_notification(existing: Option<&AgentEntry>, report: &ReportPayload, now: i64) -> Outcome {
    use NotificationType::*;
    match report.notification_type {
        // Missing notification_type on a Notification event is undefined by
        // the table; treated the same as an unrecognized type (blocked-
        // inducing) — prefer a false alarm over a miss (DESIGN.md §3.1).
        None | Some(PermissionPrompt) | Some(AgentNeedsInput) | Some(ElicitationDialog) | Some(Unknown) => {
            apply_transition(
                existing,
                report,
                now,
                UnregisteredAction::Register(Status::Blocked),
                |_current| Some(Status::Blocked),
                true,
            )
        }
        Some(IdlePrompt) => apply_transition(
            existing,
            report,
            now,
            UnregisteredAction::Ignore,
            |current| (current == Status::Working).then_some(Status::Blocked),
            true,
        ),
        Some(AuthSuccess) | Some(ElicitationComplete) | Some(ElicitationResponse) | Some(AgentCompleted) => {
            apply_transition(
                existing,
                report,
                now,
                UnregisteredAction::Ignore,
                |_current| None,
                false,
            )
        }
    }
}

fn apply_stop(existing: Option<&AgentEntry>, report: &ReportPayload, now: i64) -> Outcome {
    // background_tasks shape is still unverified against real payloads
    // (DESIGN.md §7-2c); only emptiness matters here. A missing field is
    // treated the same as an empty array (§3.1 "empty" branch).
    let has_background_tasks = report
        .background_tasks
        .as_ref()
        .is_some_and(|tasks| !tasks.is_empty());

    let target_status = if has_background_tasks {
        Status::Working
    } else {
        Status::Done
    };
    apply_transition(
        existing,
        report,
        now,
        UnregisteredAction::Register(target_status),
        move |_current| Some(target_status),
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
/// transitions, always applying the common attribute overwrites (§3.2).
fn apply_transition(
    existing: Option<&AgentEntry>,
    report: &ReportPayload,
    now: i64,
    unregistered_action: UnregisteredAction,
    registered_transition: impl Fn(Status) -> Option<Status>,
    update_message_on_transition: bool,
) -> Outcome {
    match existing {
        None => match unregistered_action {
            UnregisteredAction::Ignore => Outcome::Ignored,
            UnregisteredAction::Register(status) => {
                let mut entry = create_entry(report, now, status);
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
        session_id: report.session_id.clone(),
        cwd: report.cwd.clone(),
        since: now,
        last_seen: now,
        task: report.prompt.clone(),
        message: None,
    }
}

/// session_id / cwd / last_seen always overwrite; task overwrites only when
/// this report carries a prompt (UserPromptSubmit) — §3.2.
fn apply_common_overwrites(entry: &mut AgentEntry, report: &ReportPayload, now: i64) {
    entry.session_id = report.session_id.clone();
    entry.cwd = report.cwd.clone();
    entry.last_seen = now;
    if let Some(prompt) = &report.prompt {
        entry.task = Some(prompt.clone());
    }
}

/// Assign `new_status`, bumping `since` only on an actual value change
/// (§3.1 "same-value transitions preserve `since`"), and clearing `message` whenever the
/// entry is not (or is no longer) `blocked` (§3.2).
fn set_status(entry: &mut AgentEntry, new_status: Status, now: i64) {
    if entry.status != new_status {
        entry.status = new_status;
        entry.since = now;
    }
    if new_status != Status::Blocked {
        entry.message = None;
    }
}
