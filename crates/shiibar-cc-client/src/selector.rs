//! Selector resolution shared by `wait` / `focus` / `remove` (DESIGN.md
//! §4.4): a target's exact string, or `.` meaning "the agent whose `cwd`
//! equals the caller's current directory" (cwd *substring* matching is
//! deliberately out of scope, §8.10).

use shiibar_cc_proto::Agent;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Selector {
    Target(String),
    Cwd(PathBuf),
}

impl Selector {
    /// Parse a CLI selector argument. `cwd` is the caller's current
    /// directory, passed in explicitly (rather than read from
    /// `std::env::current_dir()` here) so tests can exercise `.` resolution
    /// against an arbitrary directory.
    pub fn parse(arg: &str, cwd: impl Into<PathBuf>) -> Self {
        if arg == "." {
            Selector::Cwd(cwd.into())
        } else {
            Selector::Target(arg.to_string())
        }
    }

    pub fn matches(&self, agent: &Agent) -> bool {
        match self {
            Selector::Target(t) => agent.target == *t,
            Selector::Cwd(cwd) => Path::new(&agent.cwd) == cwd.as_path(),
        }
    }
}

/// Selector resolution failure (DESIGN.md §4.4 exit code table maps
/// `NoMatch` to exit 2; this crate leaves the `Ambiguous` mapping to the
/// caller — shiibar-cc treats it as exit 1, see the M2 completion report).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SelectError {
    NoMatch,
    /// Only possible for `Selector::Cwd`: more than one agent shares the
    /// same `cwd`. Carries the match count.
    Ambiguous(usize),
}

/// Resolve `selector` against a snapshot of agents (typically a `list`
/// response, or the first `subscribe` snapshot).
pub fn resolve_selector<'a>(
    selector: &Selector,
    agents: &'a [Agent],
) -> Result<&'a Agent, SelectError> {
    let mut matches = agents.iter().filter(|a| selector.matches(a));
    let first = matches.next().ok_or(SelectError::NoMatch)?;
    let extra = matches.count();
    if extra > 0 {
        Err(SelectError::Ambiguous(extra + 1))
    } else {
        Ok(first)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use shiibar_cc_proto::Status;

    fn agent(target: &str, cwd: &str) -> Agent {
        Agent {
            target: target.to_string(),
            status: Status::Idle,
            unreviewed: false,
            session_id: "s".into(),
            cwd: cwd.to_string(),
            task: None,
            message: None,
            last_assistant_message: None,
            created_at: 1,
            last_report_at: 1,
            since: 1,
            last_seen: 2,
        }
    }

    #[test]
    fn exact_target_match() {
        let agents = vec![agent("t1", "/a"), agent("t2", "/b")];
        let sel = Selector::parse("t2", "/whatever");
        assert_eq!(resolve_selector(&sel, &agents).unwrap().target, "t2");
    }

    #[test]
    fn exact_target_no_match() {
        let agents = vec![agent("t1", "/a")];
        let sel = Selector::parse("nope", "/whatever");
        assert_eq!(resolve_selector(&sel, &agents), Err(SelectError::NoMatch));
    }

    #[test]
    fn dot_selector_matches_cwd() {
        let agents = vec![agent("t1", "/a"), agent("t2", "/b")];
        let sel = Selector::parse(".", "/b");
        assert_eq!(resolve_selector(&sel, &agents).unwrap().target, "t2");
    }

    #[test]
    fn dot_selector_no_match() {
        let agents = vec![agent("t1", "/a")];
        let sel = Selector::parse(".", "/nowhere");
        assert_eq!(resolve_selector(&sel, &agents), Err(SelectError::NoMatch));
    }

    #[test]
    fn dot_selector_ambiguous_when_multiple_agents_share_cwd() {
        let agents = vec![agent("t1", "/a"), agent("t2", "/a"), agent("t3", "/a")];
        let sel = Selector::parse(".", "/a");
        assert_eq!(
            resolve_selector(&sel, &agents),
            Err(SelectError::Ambiguous(3))
        );
    }
}
