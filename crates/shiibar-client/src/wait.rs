//! `wait(selector, status, timeout)` (DESIGN.md §4.3): implemented on a
//! single `subscribe` connection — the first pushed event is always a
//! snapshot, so there's no separate `list` round trip.
//!
//! Selector resolution happens once, against whatever the subscribe stream
//! shows next: if it already matches an agent in the snapshot, that
//! agent's `target` is locked in and followed from then on. If nothing
//! matches yet, the selector predicate itself (exact target, or cwd
//! equality for `.`) is applied to each subsequent `status_changed` until
//! something matches — at which point *that* target is locked in
//! (DESIGN.md §4.4: "resolve once at the start, then follow that target
//! from then on (waiting for it to appear if unregistered)").

use crate::connection::{ClientError, Subscription};
use crate::selector::{SelectError, Selector, resolve_selector};
use shiibar_proto::{Agent, Status, SubscribeEvent};
use std::path::Path;
use std::time::{Duration, Instant};

#[derive(Debug, Clone, PartialEq)]
pub enum WaitOutcome {
    /// The tracked agent reached the wanted status.
    Matched(Agent),
    /// The tracked agent was removed (SessionEnd / stale sweep / manual
    /// `remove`) before reaching the wanted status.
    Removed,
    /// `timeout` elapsed first.
    TimedOut,
}

#[derive(Debug)]
pub enum WaitError {
    Client(ClientError),
    /// Selector was `.` and matched more than one agent at resolution
    /// time. See the M2 completion report for why this is treated as an
    /// error rather than "no match" or "pick the first one".
    AmbiguousSelector(usize),
}

impl From<ClientError> for WaitError {
    fn from(e: ClientError) -> Self {
        WaitError::Client(e)
    }
}

impl std::fmt::Display for WaitError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            WaitError::Client(e) => write!(f, "{e}"),
            WaitError::AmbiguousSelector(n) => {
                write!(f, "selector matches {n} agents; use an exact target")
            }
        }
    }
}

impl std::error::Error for WaitError {}

pub fn wait(
    socket_path: &Path,
    selector: &Selector,
    want: Status,
    timeout: Option<Duration>,
) -> Result<WaitOutcome, WaitError> {
    let deadline = timeout.map(|d| Instant::now() + d);
    let mut sub = Subscription::open(socket_path)?;

    let Some(first) = sub.next_event(deadline)? else {
        return Ok(WaitOutcome::TimedOut);
    };
    let SubscribeEvent::Snapshot { agents } = first else {
        return Err(WaitError::Client(ClientError::Protocol(
            "expected a snapshot as the first subscribe event".into(),
        )));
    };

    let mut tracked: Option<String> = match resolve_selector(selector, &agents) {
        Ok(agent) if agent.status == want => return Ok(WaitOutcome::Matched(agent.clone())),
        Ok(agent) => Some(agent.target.clone()),
        Err(SelectError::NoMatch) => None,
        Err(SelectError::Ambiguous(n)) => return Err(WaitError::AmbiguousSelector(n)),
    };

    loop {
        let Some(event) = sub.next_event(deadline)? else {
            return Ok(WaitOutcome::TimedOut);
        };
        match event {
            SubscribeEvent::StatusChanged { agent } => match &tracked {
                Some(t) if *t == agent.target => {
                    if agent.status == want {
                        return Ok(WaitOutcome::Matched(agent));
                    }
                }
                Some(_) => {} // a different agent changed; irrelevant to this wait
                None => {
                    if selector.matches(&agent) {
                        let matched_now = agent.status == want;
                        tracked = Some(agent.target.clone());
                        if matched_now {
                            return Ok(WaitOutcome::Matched(agent));
                        }
                    }
                }
            },
            SubscribeEvent::AgentRemoved { target } => {
                if tracked.as_deref() == Some(target.as_str()) {
                    return Ok(WaitOutcome::Removed);
                }
            }
            SubscribeEvent::Snapshot { .. } | SubscribeEvent::Unknown => {
                // A second snapshot never happens on a live subscribe
                // connection, and unknown events are forward-compat noise
                // (§4.2) — both are simply not relevant to wait.
            }
        }
    }
}
