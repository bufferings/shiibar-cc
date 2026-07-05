//! Client library: socket connection, list / subscribe / wait, selector
//! resolution, cwd label formatting, and the iterm module (the ONLY place
//! that knows about iTerm2 / AppleScript).
//!
//! Spec: docs/DESIGN.md §4.3.

pub mod connection;
pub mod iterm;
pub mod label;
pub mod reconcile;
pub mod selector;
pub mod wait;

pub use connection::{
    ClientError, resolve_socket_path, resolve_state_dir,
};
pub use label::format_cwd_label;
pub use reconcile::{ClaudeAgentsRunner, GatherResult, RealClaudeAgents, gather as gather_reconcile};
pub use selector::{SelectError, Selector, resolve_selector};
pub use wait::{WaitError, WaitOutcome, wait as run_wait};

use shiibar_cc_proto::{Agent, ListResponse, Request};
use std::path::Path;

/// `list` (DESIGN.md §4.2/§4.3): the current agent table.
pub fn list(socket_path: &Path) -> Result<Vec<Agent>, ClientError> {
    let resp: ListResponse = connection::request(socket_path, &Request::List)?;
    Ok(resp.agents)
}
