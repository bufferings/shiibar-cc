//! Agent entry storage: the in-memory table plus atomic persistence to
//! `state.json` (§4.2 Operations).

use serde::{Deserialize, Serialize};
use shiibar_proto::{Agent, Status};
use std::io::Write;
use std::path::Path;

/// Internal representation of one tracked agent (§3.2).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AgentEntry {
    pub target: String,
    pub status: Status,
    pub session_id: String,
    pub cwd: String,
    /// Epoch seconds the entry entered its *current* status.
    pub since: i64,
    /// Epoch seconds of the last report received for this target.
    pub last_seen: i64,
    /// First 80 chars of the last `UserPromptSubmit` prompt. Persists
    /// across status changes (§3.2: "the last ... prompt").
    pub task: Option<String>,
    /// blocked reason (last Notification message that caused/held blocked).
    /// Cleared whenever the entry leaves `blocked` (§3.2).
    pub message: Option<String>,
}

impl AgentEntry {
    pub fn to_wire(&self) -> Agent {
        Agent {
            target: self.target.clone(),
            status: self.status,
            session_id: self.session_id.clone(),
            cwd: self.cwd.clone(),
            task: self.task.clone(),
            message: self.message.clone(),
            since: self.since,
            last_seen: self.last_seen,
        }
    }

    /// The subset of fields whose change triggers a `status_changed`
    /// broadcast (§4.2: "whenever any of status / session_id / cwd / task /
    /// message changes").
    fn observable(&self) -> (Status, &str, &str, Option<&str>, Option<&str>) {
        (
            self.status,
            self.session_id.as_str(),
            self.cwd.as_str(),
            self.task.as_deref(),
            self.message.as_deref(),
        )
    }

    pub fn observably_differs_from(&self, other: &AgentEntry) -> bool {
        self.observable() != other.observable()
    }
}

/// Serialized shape of `state.json`. Wrapped in an object (rather than a
/// bare array) to leave room for daemon-level metadata later without
/// breaking the format.
#[derive(Debug, Default, Serialize, Deserialize)]
struct StateFile {
    agents: Vec<AgentEntry>,
}

/// Load persisted agents from `path`. Missing file => empty (fresh start).
pub fn load(path: &Path) -> anyhow::Result<Vec<AgentEntry>> {
    match std::fs::read_to_string(path) {
        Ok(contents) => {
            let file: StateFile = serde_json::from_str(&contents)?;
            Ok(file.agents)
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Vec::new()),
        Err(e) => Err(e.into()),
    }
}

/// Atomically persist `agents` to `path` (tmp file + rename, §4.2 Operations).
pub fn save(path: &Path, agents: &[AgentEntry]) -> anyhow::Result<()> {
    let file = StateFile {
        agents: agents.to_vec(),
    };
    let json = serde_json::to_vec_pretty(&file)?;
    let tmp_path = path.with_extension("json.tmp");
    {
        let mut tmp = std::fs::File::create(&tmp_path)?;
        tmp.write_all(&json)?;
        tmp.sync_all()?;
    }
    std::fs::rename(&tmp_path, path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(target: &str, status: Status) -> AgentEntry {
        AgentEntry {
            target: target.to_string(),
            status,
            session_id: "s".into(),
            cwd: "/c".into(),
            since: 1,
            last_seen: 2,
            task: None,
            message: None,
        }
    }

    #[test]
    fn round_trips_through_save_and_load() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state.json");
        let agents = vec![entry("a", Status::Blocked), entry("b", Status::Idle)];
        save(&path, &agents).unwrap();
        let loaded = load(&path).unwrap();
        assert_eq!(loaded, agents);
    }

    #[test]
    fn load_missing_file_is_empty() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("does-not-exist.json");
        assert_eq!(load(&path).unwrap(), Vec::new());
    }

    #[test]
    fn observably_differs_ignores_last_seen_only_changes() {
        let mut a = entry("a", Status::Idle);
        let mut b = a.clone();
        b.last_seen = a.last_seen + 100;
        assert!(!a.observably_differs_from(&b));

        b.status = Status::Working;
        assert!(a.observably_differs_from(&b));

        b.status = a.status;
        a.task = Some("x".into());
        assert!(a.observably_differs_from(&b));
    }
}
