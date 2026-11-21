//! Merging by pid and nested-session detection (DESIGN.md §3.6). Pure
//! functions over the agent table: `core.rs` uses them to decide which entry
//! a report or reconcile session applies to, and whether a report is
//! ignored, before handing the entry to `transitions.rs` (whose §3.4
//! transitions are unchanged).
//!
//! The daemon never interprets a target's prefix (`process:` included): every
//! decision here uses only exact target string equality and the pid (§4.2
//! "target kinds").

use crate::state::AgentEntry;
use shiibar_cc_proto::{HookEvent, ReportPayload, SessionStartSource};

/// The entry whose target is exactly `target`.
pub fn find_by_target(agents: &[AgentEntry], target: &str) -> Option<usize> {
    agents.iter().position(|a| a.target == target)
}

/// The entry with the same pid (§3.6): an entry whose pid is known and equal
/// to `pid`, restricted to those `eligible` accepts. `pid` being `None`
/// (the incoming report / session carries no pid) matches nothing, and an
/// entry with an unknown pid is never matched.
///
/// When several entries qualify, the one with the newest `last_seen` wins,
/// then the newest `created_at` (§3.6). A full tie keeps the earliest entry
/// in the table, so the choice is deterministic.
pub fn find_by_pid(
    agents: &[AgentEntry],
    pid: Option<u32>,
    eligible: impl Fn(&AgentEntry) -> bool,
) -> Option<usize> {
    let pid = pid?;
    let mut best: Option<usize> = None;
    for (i, entry) in agents.iter().enumerate() {
        if entry.pid != Some(pid) || !eligible(entry) {
            continue;
        }
        let newer = match best {
            None => true,
            Some(b) => {
                (entry.last_seen, entry.created_at) > (agents[b].last_seen, agents[b].created_at)
            }
        };
        if newer {
            best = Some(i);
        }
    }
    best
}

/// The entry a hook report with `target` and `pid` applies to (§3.6 "hook
/// report"): (a) the entry whose target is `target`; otherwise (b) the entry
/// with the same pid, whose target the report leaves unchanged. `None` is
/// case (c): the target is unregistered, and §3.4's "unregistered" column
/// applies. Update-only reconcile sessions use the same order (§3.6).
pub fn resolve_entry(agents: &[AgentEntry], target: &str, pid: Option<u32>) -> Option<usize> {
    find_by_target(agents, target).or_else(|| find_by_pid(agents, pid, |_| true))
}

/// Whether a hook report must be ignored as a nested session's report
/// (§3.6 "nested sessions"): a different `claude` process started by the
/// running session (for example `claude -p` from its Bash tool) walks up to
/// the parent's process, so it reports the parent's pid and target with its
/// own `session_id`.
///
/// `entry` is the entry the report resolved to via (a) or (b). The rules, in
/// order:
/// 1. same `session_id` as the entry: apply;
/// 2. different `session_id`, and the report has no pid, the entry's pid is
///    unknown, or the two pids differ: apply (a relaunch in the same tab, or
///    a case the pid can't decide);
/// 3. different `session_id` and the same pid: apply only a SessionStart
///    whose `source` is `clear` or `resume` (a session switch inside the
///    same process); ignore everything else, SessionEnd included.
pub fn is_nested_session_report(entry: &AgentEntry, report: &ReportPayload) -> bool {
    if report.session_id == entry.session_id {
        return false;
    }
    match (report.pid, entry.pid) {
        (Some(report_pid), Some(entry_pid)) if report_pid == entry_pid => {
            let switches_session_in_process = report.event == HookEvent::SessionStart
                && matches!(
                    report.source,
                    Some(SessionStartSource::Clear) | Some(SessionStartSource::Resume)
                );
            !switches_session_in_process
        }
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use shiibar_cc_proto::{NotificationType, Status};

    fn entry(target: &str, pid: Option<u32>, last_seen: i64, created_at: i64) -> AgentEntry {
        AgentEntry {
            target: target.into(),
            status: Status::Working,
            unreviewed: false,
            session_id: "s-parent".into(),
            cwd: "/proj".into(),
            since: 1,
            last_seen,
            task: None,
            message: None,
            last_assistant_message: None,
            created_at,
            last_report_at: 1,
            pid,
        }
    }

    fn report(event: HookEvent, session_id: &str, pid: Option<u32>) -> ReportPayload {
        ReportPayload {
            event,
            target: Some("iterm2:A".into()),
            session_id: session_id.into(),
            cwd: "/proj".into(),
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

    // --- entry resolution (§3.6 "hook report" (a)/(b)/(c)) ---

    #[test]
    fn resolve_prefers_the_target_match_over_a_pid_match() {
        let agents = vec![entry("process:7", Some(7), 9, 9), entry("iterm2:A", Some(8), 1, 1)];
        assert_eq!(resolve_entry(&agents, "iterm2:A", Some(7)), Some(1));
    }

    #[test]
    fn resolve_falls_back_to_the_entry_with_the_same_pid() {
        let agents = vec![entry("process:7", Some(7), 1, 1)];
        assert_eq!(resolve_entry(&agents, "iterm2:A", Some(7)), Some(0));
    }

    #[test]
    fn resolve_finds_nothing_when_neither_target_nor_pid_matches() {
        let agents = vec![entry("process:7", Some(7), 1, 1)];
        assert_eq!(resolve_entry(&agents, "iterm2:A", Some(8)), None);
    }

    #[test]
    fn a_missing_pid_on_either_side_matches_by_target_only() {
        let unknown = vec![entry("process:7", None, 1, 1)];
        assert_eq!(resolve_entry(&unknown, "iterm2:A", Some(7)), None, "entry pid unknown");
        let known = vec![entry("process:7", Some(7), 1, 1)];
        assert_eq!(resolve_entry(&known, "iterm2:A", None), None, "report has no pid");
    }

    #[test]
    fn several_entries_with_the_same_pid_pick_the_newest_last_seen_then_created_at() {
        let agents = vec![
            entry("a", Some(7), 5, 9),
            entry("b", Some(7), 6, 1),
            entry("c", Some(7), 6, 2),
            entry("d", Some(8), 99, 99),
        ];
        assert_eq!(find_by_pid(&agents, Some(7), |_| true), Some(2));
    }

    #[test]
    fn find_by_pid_skips_ineligible_entries() {
        let agents = vec![entry("a", Some(7), 9, 9), entry("b", Some(7), 1, 1)];
        assert_eq!(find_by_pid(&agents, Some(7), |e| e.target != "a"), Some(1));
    }

    // --- nested sessions (§3.6 rules 1-3) ---

    #[test]
    fn rule_1_same_session_id_is_applied_regardless_of_pid() {
        let e = entry("iterm2:A", Some(7), 1, 1);
        for pid in [Some(7), Some(8), None] {
            let mut r = report(HookEvent::SessionStart, "s-parent", pid);
            r.source = Some(SessionStartSource::Compact);
            assert!(!is_nested_session_report(&e, &r), "pid {pid:?}");
        }
    }

    #[test]
    fn rule_2_different_session_id_without_a_comparable_pid_is_applied() {
        let known = entry("iterm2:A", Some(7), 1, 1);
        let unknown = entry("iterm2:A", None, 1, 1);
        let r_other_pid = report(HookEvent::Stop, "s-child", Some(8));
        let r_no_pid = report(HookEvent::Stop, "s-child", None);
        let r_same_pid = report(HookEvent::Stop, "s-child", Some(7));
        assert!(!is_nested_session_report(&known, &r_other_pid), "pids differ");
        assert!(!is_nested_session_report(&known, &r_no_pid), "report has no pid");
        assert!(!is_nested_session_report(&unknown, &r_same_pid), "entry pid unknown");
    }

    #[test]
    fn rule_3_same_pid_applies_only_a_clear_or_resume_session_start() {
        let e = entry("iterm2:A", Some(7), 1, 1);
        for source in [SessionStartSource::Clear, SessionStartSource::Resume] {
            let mut r = report(HookEvent::SessionStart, "s-new", Some(7));
            r.source = Some(source);
            assert!(!is_nested_session_report(&e, &r), "{source:?} must be applied");
        }
        for source in [
            Some(SessionStartSource::Startup),
            Some(SessionStartSource::Compact),
            Some(SessionStartSource::Other),
            None,
        ] {
            let mut r = report(HookEvent::SessionStart, "s-child", Some(7));
            r.source = source;
            assert!(is_nested_session_report(&e, &r), "{source:?} must be ignored");
        }
    }

    #[test]
    fn rule_3_same_pid_ignores_every_other_event() {
        let e = entry("iterm2:A", Some(7), 1, 1);
        for event in [
            HookEvent::UserPromptSubmit,
            HookEvent::PostToolUse,
            HookEvent::PostToolUseFailure,
            HookEvent::Notification,
            HookEvent::Stop,
            HookEvent::SessionEnd,
        ] {
            let mut r = report(event, "s-child", Some(7));
            r.notification_type = Some(NotificationType::PermissionPrompt);
            r.source = Some(SessionStartSource::Clear); // irrelevant outside SessionStart
            assert!(is_nested_session_report(&e, &r), "{event:?} must be ignored");
        }
    }
}
