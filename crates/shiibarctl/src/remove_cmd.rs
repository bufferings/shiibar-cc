//! `shiibarctl remove <selector>` (DESIGN.md §3.2/§4.4): manually delete a
//! ghost entry.

use crate::exitcode;
use shiibar_client::selector::{SelectError, Selector, resolve_selector};
use shiibar_proto::{AckResponse, ListResponse, Request};
use std::path::{Path, PathBuf};

pub fn run_remove(socket_path: &Path, selector_arg: &str, cwd: PathBuf) -> (i32, Option<String>) {
    let selector = Selector::parse(selector_arg, cwd);

    let agents =
        match shiibar_client::connection::request::<ListResponse>(socket_path, &Request::List) {
            Ok(resp) => resp.agents,
            Err(e) => return (exitcode::ERROR, Some(format!("shiibarctl remove: {e}"))),
        };

    let target = match resolve_selector(&selector, &agents) {
        Ok(agent) => agent.target.clone(),
        Err(SelectError::NoMatch) => {
            return (
                exitcode::NOT_FOUND,
                Some("shiibarctl remove: no agent matches the given selector".to_string()),
            );
        }
        Err(SelectError::Ambiguous(n)) => {
            return (
                exitcode::ERROR,
                Some(format!(
                    "shiibarctl remove: selector matches {n} agents; use an exact target"
                )),
            );
        }
    };

    match shiibar_client::connection::request::<AckResponse>(
        socket_path,
        &Request::Remove { target },
    ) {
        Ok(_) => (exitcode::OK, None),
        Err(e) => (exitcode::ERROR, Some(format!("shiibarctl remove: {e}"))),
    }
}
