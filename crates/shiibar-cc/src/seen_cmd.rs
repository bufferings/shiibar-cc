//! `shiibar-cc seen <selector>` (DESIGN.md §4.2/§4.4): clear the unreviewed
//! flag for one agent. Same selector-resolution and exit-code contract as
//! `remove` (§4.4); the menu bar app's Clear badges calls this once per
//! unreviewed target (§4.5/§8.24).

use crate::exitcode;
use shiibar_cc_client::selector::{SelectError, Selector, resolve_selector};
use shiibar_cc_proto::{AckResponse, ListResponse, Request};
use std::path::{Path, PathBuf};

pub fn run_seen(socket_path: &Path, selector_arg: &str, cwd: PathBuf) -> (i32, Option<String>) {
    let selector = Selector::parse(selector_arg, cwd);

    let agents =
        match shiibar_cc_client::connection::request::<ListResponse>(socket_path, &Request::List) {
            Ok(resp) => resp.agents,
            Err(e) => return (exitcode::ERROR, Some(format!("shiibar-cc seen: {e}"))),
        };

    let target = match resolve_selector(&selector, &agents) {
        Ok(agent) => agent.target.clone(),
        Err(SelectError::NoMatch) => {
            return (
                exitcode::NOT_FOUND,
                Some("shiibar-cc seen: no agent matches the given selector".to_string()),
            );
        }
        Err(SelectError::Ambiguous(n)) => {
            return (
                exitcode::ERROR,
                Some(format!(
                    "shiibar-cc seen: selector matches {n} agents; use an exact target"
                )),
            );
        }
    };

    match shiibar_cc_client::connection::request::<AckResponse>(
        socket_path,
        &Request::Seen { target },
    ) {
        Ok(_) => (exitcode::OK, None),
        Err(e) => (exitcode::ERROR, Some(format!("shiibar-cc seen: {e}"))),
    }
}
