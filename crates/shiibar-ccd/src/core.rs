//! Shared daemon state: the agent table, session history, and the request
//! handlers that mutate them (§4.2). Deliberately synchronous/lock-free by
//! itself — `server.rs` wraps one `Core` in a `std::sync::Mutex` so
//! connections process in accept/receive order (§4.2 Protocol contract).

use crate::clock::Clock;
use crate::merge;
use crate::state::{self, AgentEntry};
use crate::transitions::{self, Outcome};
use crate::{log_debug, log_info};
use crate::logging::Logger;
use crate::paths::StateDir;
use shiibar_cc_proto::{
    Agent, InfoResponse, ListResponse, ReconcileSession, RemovalReason, ReportPayload,
};
use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::broadcast;

/// Stale-entry threshold (§9): 24h since `last_seen`.
pub const STALE_THRESHOLD_SECS: i64 = 24 * 60 * 60;
/// Sweep period (§9): 60s, plus once at startup (driven by `server.rs`).
pub const SWEEP_INTERVAL_SECS: u64 = 60;
/// Broadcast channel capacity. An implementation detail, not a protocol
/// contract (§4.2): a lagging subscriber is disconnected, not queued
/// forever.
pub const BROADCAST_CAPACITY: usize = 1024;

/// The two live-update kinds pushed to subscribers after their initial
/// snapshot (§4.2). `Snapshot` itself isn't part of this: it's built fresh
/// per new subscriber from the current table, not broadcast.
#[derive(Debug, Clone, PartialEq)]
pub enum BroadcastEvent {
    StatusChanged(Agent),
    /// `to` is the new target, set only for `RemovalReason::Rekey` (§4.2).
    AgentRemoved {
        target: String,
        reason: RemovalReason,
        to: Option<String>,
    },
}

pub struct Core {
    pub agents: Vec<AgentEntry>,
    clock: Arc<dyn Clock>,
    state_path: PathBuf,
    logger: Logger,
    pub events_tx: broadcast::Sender<BroadcastEvent>,
    started_at: i64,
    last_report_at: Option<i64>,
}

impl Core {
    pub fn load(
        state_dir: &StateDir,
        clock: Arc<dyn Clock>,
        logger: Logger,
        events_tx: broadcast::Sender<BroadcastEvent>,
    ) -> anyhow::Result<Self> {
        let agents = state::load(&state_dir.state_json())?;
        let started_at = clock.now();
        Ok(Self {
            agents,
            clock,
            state_path: state_dir.state_json(),
            logger,
            events_tx,
            started_at,
            last_report_at: None,
        })
    }

    fn find(&self, target: &str) -> Option<usize> {
        merge::find_by_target(&self.agents, target)
    }

    /// Persist state.json, logging (rather than propagating) on failure.
    /// Every mutating handler below is synchronous and infallible from the
    /// caller's point of view by design: `server.rs` needs to be able to
    /// drop the `std::sync::MutexGuard` before any `.await`, so handlers
    /// don't return `Result` (a `MutexGuard` briefly outliving an `Err`
    /// branch is exactly the shape that trips the `Future: Send` check for
    /// `tokio::spawn`).
    fn persist_state(&self) {
        if let Err(e) = state::save(&self.state_path, &self.agents) {
            self.logger.error(format_args!("failed to persist state.json: {e}"));
        }
    }

    /// Handle `{"cmd":"report",...}` (§3.1/§3.2). No response (fire-and-forget).
    ///
    /// An invalid report (`ReportPayload::validate`: no target on an event
    /// other than SessionEnd) changes nothing, not even `last_report_at`;
    /// `server.rs` rejects it with an error response before it gets here.
    pub fn handle_report(&mut self, payload: ReportPayload) {
        if let Err(e) = payload.validate() {
            log_debug!(
                self.logger,
                "ignored invalid report event={:?} session_id={}: {e}",
                payload.event,
                payload.session_id
            );
            return;
        }
        let now = self.clock.now();
        self.last_report_at = Some(now);
        let Some(target) = payload.target.clone() else {
            self.remove_by_session_id(&payload.session_id);
            return;
        };
        log_debug!(
            self.logger,
            "report target={} event={:?}",
            target,
            payload.event
        );

        // The entry this report applies to: same target, else same pid
        // (whose target the report never changes), else unregistered
        // (§3.6 "merging by pid").
        let idx = merge::resolve_entry(&self.agents, &target, payload.pid);
        if let Some(i) = idx
            && merge::is_nested_session_report(&self.agents[i], &payload)
        {
            // A nested session's report leaves the entry untouched: no
            // last_seen / last_report_at bump, no deletion on SessionEnd,
            // nothing persisted or broadcast (§3.6 "nested sessions").
            log_debug!(
                self.logger,
                "ignored nested-session report target={} entry={} session_id={}",
                target,
                self.agents[i].target,
                payload.session_id
            );
            return;
        }
        let existing = idx.map(|i| &self.agents[i]);
        let outcome = transitions::apply_report(existing, &payload, now);

        match outcome {
            Outcome::Ignored => {}
            Outcome::Removed { previous } => {
                log_info!(
                    self.logger,
                    "removed target={} (SessionEnd, was {:?})",
                    previous.target,
                    previous.status
                );
                self.agents.remove(idx.expect("Removed implies an existing entry"));
                self.persist_state();
                let _ = self.events_tx.send(BroadcastEvent::AgentRemoved {
                    target: previous.target,
                    reason: RemovalReason::SessionEnd,
                    to: None,
                });
            }
            Outcome::Updated { mut entry, previous } => {
                if payload.pid.is_some() {
                    entry.pid = payload.pid;
                }
                let should_broadcast = match &previous {
                    None => true,
                    Some(prev) => entry.observably_differs_from(prev),
                };
                match &previous {
                    None => log_info!(
                        self.logger,
                        "registered target={} status={:?}",
                        entry.target,
                        entry.status
                    ),
                    Some(prev) if prev.status != entry.status => log_info!(
                        self.logger,
                        "transition target={} {:?} -> {:?}",
                        entry.target,
                        prev.status,
                        entry.status
                    ),
                    Some(_) => {}
                }

                match idx {
                    Some(i) => self.agents[i] = entry.clone(),
                    None => self.agents.push(entry.clone()),
                }
                self.persist_state();
                if should_broadcast {
                    let _ = self
                        .events_tx
                        .send(BroadcastEvent::StatusChanged(entry.to_wire()));
                }
            }
        }
    }

    /// A SessionEnd report without a target: closing a terminal window
    /// detaches the `claude` process from its terminal before its SessionEnd
    /// hook runs, so the hook could derive neither a target nor a pid
    /// (§4.1). Remove every entry with this `session_id` (normally one,
    /// whatever its target kind, including one rekeyed by reconcile or
    /// restored from state.json with an unknown pid), as an ordinary
    /// SessionEnd would. Matching is by `session_id` only, so the
    /// nested-session rule (§3.6) is not needed: a nested session's
    /// SessionEnd carries its own `session_id` and cannot match the parent.
    /// No match: nothing changes and nothing is broadcast.
    fn remove_by_session_id(&mut self, session_id: &str) {
        let (removed, kept): (Vec<AgentEntry>, Vec<AgentEntry>) = std::mem::take(&mut self.agents)
            .into_iter()
            .partition(|a| a.session_id == session_id);
        self.agents = kept;
        if removed.is_empty() {
            log_debug!(
                self.logger,
                "targetless SessionEnd session_id={session_id} matched no entry"
            );
            return;
        }
        self.persist_state();
        for entry in removed {
            log_info!(
                self.logger,
                "removed target={} (SessionEnd without target, session_id={}, was {:?})",
                entry.target,
                session_id,
                entry.status
            );
            let _ = self.events_tx.send(BroadcastEvent::AgentRemoved {
                target: entry.target,
                reason: RemovalReason::SessionEnd,
                to: None,
            });
        }
    }

    /// Handle `{"cmd":"seen","target":...}` (§3.1 last row, §4.2).
    pub fn handle_seen(&mut self, target: &str) {
        let now = self.clock.now();
        let idx = self.find(target);
        let existing = idx.map(|i| &self.agents[i]);
        if let Outcome::Updated { entry, previous } = transitions::apply_seen(existing, now) {
            log_info!(
                self.logger,
                "transition target={} {:?} -> {:?} (seen)",
                entry.target,
                previous.map(|p| p.status),
                entry.status
            );
            self.agents[idx.expect("Updated implies an existing entry for seen")] = entry.clone();
            self.persist_state();
            let _ = self
                .events_tx
                .send(BroadcastEvent::StatusChanged(entry.to_wire()));
        }
    }

    /// Handle `{"cmd":"remove","target":...}` (§3.2, §4.4). Always ok, even
    /// for an unregistered target.
    pub fn handle_remove(&mut self, target: &str) {
        if let Some(idx) = self.find(target) {
            let removed = self.agents.remove(idx);
            log_info!(self.logger, "removed target={} (manual remove)", removed.target);
            self.persist_state();
            let _ = self.events_tx.send(BroadcastEvent::AgentRemoved {
                target: removed.target,
                reason: RemovalReason::Remove,
                to: None,
            });
        }
    }

    /// Handle `{"cmd":"reconcile","complete":...,"sessions":[...]}` (§3.5).
    /// `sessions` is the client's gathered live list from `claude agents`
    /// (already translated to shiibar's status vocabulary and given targets,
    /// §3.5); `complete` says whether every terminal scan the client
    /// attempted was trustworthy enough to prune from (§7-1: a partial or
    /// failed scan must never be treated as "this session is gone").
    ///
    /// Application order (§3.6 "merging by pid"), so that the result does not
    /// depend on the order of `sessions`:
    /// 1. every session whose target is already registered (known);
    /// 2. every remaining session: an update-only session updates the entry
    ///    with the same pid, or nothing; otherwise, in a complete round, the
    ///    entry with the same pid whose target is not in this round's live
    ///    set is rekeyed to the session's target and updated as known, and
    ///    in an incomplete round the entry with the same pid is updated as
    ///    known without rekeying; with no such entry, the session is added
    ///    as untracked;
    /// 3. only in a complete round, prune every entry whose target is not in
    ///    the live set (judged after all rekeys).
    pub fn handle_reconcile(&mut self, complete: bool, sessions: &[ReconcileSession]) {
        let now = self.clock.now();
        let mut broadcasts = Vec::new();
        let mut changed = false;
        let live: HashSet<&str> = sessions.iter().map(|s| s.target.as_str()).collect();

        let (registered, remaining): (Vec<&ReconcileSession>, Vec<&ReconcileSession>) = sessions
            .iter()
            .partition(|s| self.find(&s.target).is_some());

        for session in registered {
            let idx = self.find(&session.target);
            self.apply_reconcile_session_at(idx, session, now, false, &mut broadcasts);
            changed = true;
        }

        for session in remaining {
            // A duplicate target earlier in this step may have registered it.
            if let Some(i) = self.find(&session.target) {
                self.apply_reconcile_session_at(Some(i), session, now, false, &mut broadcasts);
                changed = true;
                continue;
            }
            if session.update_only {
                // Update-only: never create or rekey (§3.6).
                if let Some(i) = merge::find_by_pid(&self.agents, session.pid, |_| true) {
                    self.apply_reconcile_session_at(Some(i), session, now, false, &mut broadcasts);
                    changed = true;
                }
                continue;
            }
            let same_pid = if complete {
                merge::find_by_pid(&self.agents, session.pid, |e| !live.contains(e.target.as_str()))
            } else {
                merge::find_by_pid(&self.agents, session.pid, |_| true)
            };
            match same_pid {
                Some(i) if complete => {
                    let old_target =
                        std::mem::replace(&mut self.agents[i].target, session.target.clone());
                    log_info!(
                        self.logger,
                        "rekeyed target={} -> {} (reconcile, pid={:?})",
                        old_target,
                        session.target,
                        session.pid
                    );
                    // The rekey notice and the new target's status_changed
                    // are always sent, adjacent and in this order, so a
                    // subscriber never loses the session (§3.6 "rekey").
                    broadcasts.push(BroadcastEvent::AgentRemoved {
                        target: old_target,
                        reason: RemovalReason::Rekey,
                        to: Some(session.target.clone()),
                    });
                    self.apply_reconcile_session_at(Some(i), session, now, true, &mut broadcasts);
                }
                Some(i) => {
                    self.apply_reconcile_session_at(Some(i), session, now, false, &mut broadcasts);
                }
                None => {
                    self.apply_reconcile_session_at(None, session, now, false, &mut broadcasts);
                }
            }
            changed = true;
        }

        if complete {
            let mut i = 0;
            while i < self.agents.len() {
                if live.contains(self.agents[i].target.as_str()) {
                    i += 1;
                    continue;
                }
                let removed = self.agents.remove(i);
                log_info!(
                    self.logger,
                    "removed target={} (reconcile prune, was {:?})",
                    removed.target,
                    removed.status
                );
                broadcasts.push(BroadcastEvent::AgentRemoved {
                    target: removed.target,
                    reason: RemovalReason::Prune,
                    to: None,
                });
                changed = true;
            }
        }

        if changed {
            self.persist_state();
        }
        for event in broadcasts {
            let _ = self.events_tx.send(event);
        }
    }

    /// Apply one reconcile session (§3.5 step 3) to the entry at `idx`
    /// ("known"), or add it as a new entry when `idx` is `None`
    /// ("untracked"), overwriting the entry's pid when the session carries
    /// one (§3.6). `force_broadcast` sends `status_changed` even without an
    /// observable change (the one that follows a rekey, §3.6).
    fn apply_reconcile_session_at(
        &mut self,
        idx: Option<usize>,
        session: &ReconcileSession,
        now: i64,
        force_broadcast: bool,
        broadcasts: &mut Vec<BroadcastEvent>,
    ) {
        let existing = idx.map(|i| &self.agents[i]);
        let Outcome::Updated { mut entry, previous } =
            transitions::apply_reconcile_session(existing, session, now)
        else {
            unreachable!("apply_reconcile_session never returns Ignored/Removed");
        };
        if session.pid.is_some() {
            entry.pid = session.pid;
        }

        match &previous {
            None => log_info!(
                self.logger,
                "registered target={} status={:?} (reconcile)",
                entry.target,
                entry.status
            ),
            Some(prev) if prev.status != entry.status => log_info!(
                self.logger,
                "transition target={} {:?} -> {:?} (reconcile)",
                entry.target,
                prev.status,
                entry.status
            ),
            Some(_) => {}
        }

        let should_broadcast = force_broadcast
            || match &previous {
                None => true,
                Some(prev) => entry.observably_differs_from(prev),
            };
        match idx {
            Some(i) => self.agents[i] = entry.clone(),
            None => self.agents.push(entry.clone()),
        }
        if should_broadcast {
            broadcasts.push(BroadcastEvent::StatusChanged(entry.to_wire()));
        }
    }

    /// Stale sweep (§3.2, §9): drop entries whose `last_seen` is more than
    /// 24h old. Run at startup and every 60s by `server.rs`.
    pub fn sweep_stale(&mut self) {
        let now = self.clock.now();
        let mut removed_any = false;
        let mut i = 0;
        while i < self.agents.len() {
            if now - self.agents[i].last_seen > STALE_THRESHOLD_SECS {
                let removed = self.agents.remove(i);
                log_info!(
                    self.logger,
                    "removed target={} (stale, last_seen={} now={})",
                    removed.target,
                    removed.last_seen,
                    now
                );
                let _ = self.events_tx.send(BroadcastEvent::AgentRemoved {
                    target: removed.target,
                    reason: RemovalReason::Stale,
                    to: None,
                });
                removed_any = true;
            } else {
                i += 1;
            }
        }
        if removed_any {
            self.persist_state();
        }
    }

    pub fn handle_list(&self) -> ListResponse {
        ListResponse::new(self.agents.iter().map(AgentEntry::to_wire).collect())
    }

    pub fn handle_info(&self) -> InfoResponse {
        InfoResponse {
            ok: true,
            version: env!("CARGO_PKG_VERSION").to_string(),
            started_at: self.started_at,
            last_report_at: self.last_report_at,
        }
    }

    /// Snapshot for a freshly-connected subscriber (§4.2).
    pub fn snapshot(&self) -> Vec<Agent> {
        self.agents.iter().map(AgentEntry::to_wire).collect()
    }

    pub fn logger(&self) -> &Logger {
        &self.logger
    }
}
