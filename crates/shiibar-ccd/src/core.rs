//! Shared daemon state: the agent table, session history, and the request
//! handlers that mutate them (§4.2). Deliberately synchronous/lock-free by
//! itself — `server.rs` wraps one `Core` in a `std::sync::Mutex` so
//! connections process in accept/receive order (§4.2 Protocol contract).

use crate::clock::Clock;
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
    AgentRemoved { target: String, reason: RemovalReason },
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
        self.agents.iter().position(|a| a.target == target)
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
    pub fn handle_report(&mut self, payload: ReportPayload) {
        let now = self.clock.now();
        self.last_report_at = Some(now);
        log_debug!(
            self.logger,
            "report target={} event={:?}",
            payload.target,
            payload.event
        );

        let idx = self.find(&payload.target);
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
                });
            }
            Outcome::Updated { entry, previous } => {
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
            });
        }
    }

    /// Handle `{"cmd":"reconcile","complete":...,"sessions":[...]}` (§3.5).
    /// `sessions` is the client's gathered live list from `claude agents`
    /// (translated to shiibar's status vocabulary and matched to iTerm2
    /// targets already, §3.5); `complete` says whether the client's iTerm2
    /// scan was trustworthy enough to prune from (§7-1: a partial/failed
    /// scan must never be treated as "this session is gone").
    pub fn handle_reconcile(&mut self, complete: bool, sessions: &[ReconcileSession]) {
        let now = self.clock.now();
        let mut broadcasts = Vec::new();
        let mut changed = false;

        for session in sessions {
            let idx = self.find(&session.target);
            let existing = idx.map(|i| &self.agents[i]);
            let Outcome::Updated { entry, previous } =
                transitions::apply_reconcile_session(existing, session, now)
            else {
                unreachable!("apply_reconcile_session never returns Ignored/Removed");
            };
            changed = true;

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

            let should_broadcast = match &previous {
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

        if complete {
            let live: HashSet<&str> = sessions.iter().map(|s| s.target.as_str()).collect();
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
