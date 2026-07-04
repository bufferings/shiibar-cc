//! `sessions.jsonl` history (§4.2 Operations): one line per SessionStart / Stop /
//! SessionEnd, deduped by `session_id` (latest wins) for the `sessions`
//! response, and physically compacted at startup once the file exceeds
//! 1000 lines (§9).
//!
//! Full compaction-under-load coverage is a listed M3 test item (DESIGN.md
//! §6); this module still implements + minimally tests dedup/compaction now
//! since §4.2 requires the behavior to exist for M1's restart test.

use serde::Deserialize;
use shiibar_cc_proto::SessionRecord;
use std::collections::HashMap;
use std::io::Write;
use std::path::{Path, PathBuf};

const COMPACT_THRESHOLD_LINES: usize = 1000;

pub struct SessionStore {
    path: PathBuf,
    // Keyed by session_id; last write (by append order) wins.
    records: HashMap<String, SessionRecord>,
}

impl SessionStore {
    /// Load existing history, deduping by session_id (latest occurrence in
    /// the file wins). If the raw file has more than 1000 lines, rewrite it
    /// with the deduped set.
    pub fn load(path: &Path) -> anyhow::Result<Self> {
        let mut records: HashMap<String, SessionRecord> = HashMap::new();
        let mut raw_line_count = 0usize;

        if let Ok(contents) = std::fs::read_to_string(path) {
            for line in contents.lines() {
                if line.trim().is_empty() {
                    continue;
                }
                raw_line_count += 1;
                match serde_json::from_str::<SessionRecordDe>(line) {
                    Ok(rec) => {
                        records.insert(rec.0.session_id.clone(), rec.0);
                    }
                    Err(_) => {
                        // Defensive: a corrupted line shouldn't take down the
                        // daemon. Not specced either way; skip it.
                        continue;
                    }
                }
            }
        }

        let mut store = Self {
            path: path.to_path_buf(),
            records,
        };
        if raw_line_count > COMPACT_THRESHOLD_LINES {
            store.rewrite_compacted()?;
        }
        Ok(store)
    }

    /// Append one line to disk and update the in-memory deduped view.
    pub fn append(&mut self, record: SessionRecord) -> anyhow::Result<()> {
        let line = shiibar_cc_proto::codec::encode_line(&record)?;
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)?;
        file.write_all(line.as_bytes())?;
        self.records.insert(record.session_id.clone(), record);
        Ok(())
    }

    /// All known sessions, most-recently-seen first (`sessions` response).
    pub fn list(&self) -> Vec<SessionRecord> {
        let mut v: Vec<SessionRecord> = self.records.values().cloned().collect();
        v.sort_by_key(|r| std::cmp::Reverse(r.last_seen));
        v
    }

    fn rewrite_compacted(&mut self) -> anyhow::Result<()> {
        let mut entries: Vec<&SessionRecord> = self.records.values().collect();
        entries.sort_by_key(|r| r.last_seen);
        let mut out = String::new();
        for rec in entries {
            out.push_str(&shiibar_cc_proto::codec::encode_line(rec)?);
        }
        let tmp_path = self.path.with_extension("jsonl.tmp");
        std::fs::write(&tmp_path, out.as_bytes())?;
        std::fs::rename(&tmp_path, &self.path)?;
        Ok(())
    }
}

/// Newtype so we can `impl Deserialize` without fighting orphan rules,
/// while keeping `shiibar_cc_proto::SessionRecord` itself simple.
struct SessionRecordDe(SessionRecord);

impl<'de> Deserialize<'de> for SessionRecordDe {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        SessionRecord::deserialize(deserializer).map(SessionRecordDe)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use shiibar_cc_proto::Status;

    fn rec(session_id: &str, last_seen: i64) -> SessionRecord {
        SessionRecord {
            session_id: session_id.to_string(),
            cwd: "/c".into(),
            last_status: Status::Idle,
            last_seen,
        }
    }

    #[test]
    fn append_and_list_sorts_by_last_seen_desc() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sessions.jsonl");
        let mut store = SessionStore::load(&path).unwrap();
        store.append(rec("a", 10)).unwrap();
        store.append(rec("b", 20)).unwrap();
        let listed = store.list();
        assert_eq!(listed[0].session_id, "b");
        assert_eq!(listed[1].session_id, "a");
    }

    #[test]
    fn reload_dedupes_by_session_id_latest_wins() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sessions.jsonl");
        let mut store = SessionStore::load(&path).unwrap();
        store.append(rec("a", 10)).unwrap();
        store.append(rec("a", 20)).unwrap();

        let reloaded = SessionStore::load(&path).unwrap();
        let listed = reloaded.list();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].last_seen, 20);
    }

    #[test]
    fn startup_compacts_when_over_threshold() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sessions.jsonl");
        {
            let mut store = SessionStore::load(&path).unwrap();
            for i in 0..(COMPACT_THRESHOLD_LINES + 5) {
                store.append(rec("same-session", i as i64)).unwrap();
            }
        }
        let raw = std::fs::read_to_string(&path).unwrap();
        assert!(raw.lines().count() > COMPACT_THRESHOLD_LINES);

        // Reloading should trigger compaction: file collapses to 1 line.
        let _reloaded = SessionStore::load(&path).unwrap();
        let raw_after = std::fs::read_to_string(&path).unwrap();
        assert_eq!(raw_after.lines().count(), 1);
    }
}
