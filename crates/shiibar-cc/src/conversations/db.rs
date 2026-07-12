//! The conversations index: one SQLite file (FTS5 + trigram) in the state
//! dir (DESIGN.md §4.6). The schema is PRIVATE to this module — the public
//! contract is the CLI's output JSON only (§4.4), so anything here may
//! change freely behind a schema-version bump.
//!
//! SQLite discipline (§4.6): WAL mode; writes use BEGIN IMMEDIATE; one
//! commit per conversation; the lock wait is set explicitly (5s, not the
//! default); a full rebuild recreates the tables INSIDE the same
//! connection instead of deleting the file (no delete race with concurrent
//! readers). The schema-version row is part of the very first commit, so
//! an interrupted rebuild converges: the next run sees the right version
//! and simply diff-indexes whatever is missing.

use crate::conversations::transcript::Extracted;
use rusqlite::{Connection, OpenFlags, TransactionBehavior, ffi, params};
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::time::Duration;

/// Extractor schema version: bump when the extraction rules or the table
/// shapes change; a mismatch triggers an automatic full rebuild.
const SCHEMA_VERSION: i64 = 1;

/// Explicit SQLite lock wait (DESIGN.md §4.6: never rely on the default).
const BUSY_TIMEOUT: Duration = Duration::from_secs(5);

/// The synthetic FTS row that makes title + cwd searchable through the
/// same term queries as the body; `show` filters it out.
const META_ROLE: &str = "meta";

/// One `search` result row (the five public fields of §4.4 come from
/// here).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConversationRow {
    pub session_id: String,
    pub cwd: Option<String>,
    pub title: Option<String>,
    pub updated_at: i64,
    pub live: bool,
}

/// One `show` result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShowResult {
    pub session_id: String,
    pub cwd: Option<String>,
    pub title: Option<String>,
    pub messages: Vec<ShowMessage>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShowMessage {
    pub seq: i64,
    pub role: String,
    pub text: String,
}

/// What the index knows about a file, for the stat sweep diff.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IndexedFile {
    pub path: String,
    pub mtime_ns: i64,
    pub size: i64,
}

pub struct Db {
    conn: Connection,
}

/// Open the index read-write, creating or rebuilding the schema as needed.
/// Returns the handle and whether this open decided a full build (fresh
/// DB, schema-version mismatch, or corruption recovery).
///
/// Only the catch-up lock holder may call this (DESIGN.md §4.4: waiting
/// readers are read-only best effort; corruption judgement and rebuild
/// belong to the holder alone).
pub fn open_rw(db_path: &Path) -> anyhow::Result<(Db, bool)> {
    match try_open_rw(db_path) {
        Ok(v) => Ok(v),
        Err(e) if is_corruption(&e) => {
            // The file is not (or no longer) a database. Recover by
            // truncating in place — NOT by deleting: an unlink would fork
            // the path from the inode a concurrent reader still has open
            // (§4.6 forbids file deletion for exactly that race).
            truncate_in_place(db_path)?;
            let (db, _) = try_open_rw(db_path)?;
            Ok((db, true))
        }
        Err(e) => Err(e.into()),
    }
}

fn try_open_rw(db_path: &Path) -> rusqlite::Result<(Db, bool)> {
    let conn = Connection::open(db_path)?;
    restrict_permissions(db_path);
    configure(&conn)?;
    let mut db = Db { conn };
    let full_build = db.ensure_schema()?;
    Ok((db, full_build))
}

/// Open read-only (used by `show` and by the progress relay).
pub fn open_ro(db_path: &Path) -> rusqlite::Result<Db> {
    let conn = Connection::open_with_flags(
        db_path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    conn.busy_timeout(BUSY_TIMEOUT)?;
    Ok(Db { conn })
}

fn configure(conn: &Connection) -> rusqlite::Result<()> {
    conn.busy_timeout(BUSY_TIMEOUT)?;
    // WAL survives in the file; setting it every open is idempotent.
    conn.query_row("PRAGMA journal_mode=WAL", [], |_| Ok(()))?;
    Ok(())
}

/// The DB file is 0600 explicitly (DESIGN.md §4.6: no looser than the
/// transcripts it copies from). Best effort — a failure here must not
/// break indexing itself.
fn restrict_permissions(db_path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    let _ = std::fs::set_permissions(db_path, std::fs::Permissions::from_mode(0o600));
}

fn is_corruption(err: &rusqlite::Error) -> bool {
    matches!(
        err,
        rusqlite::Error::SqliteFailure(ffi::Error { code, .. }, _)
            if *code == ffi::ErrorCode::NotADatabase
                || *code == ffi::ErrorCode::DatabaseCorrupt
    )
}

/// Truncate the DB and its WAL sidecars to zero length (same inodes kept —
/// see `open_rw`). A zero-length file is a valid empty database.
fn truncate_in_place(db_path: &Path) -> std::io::Result<()> {
    for suffix in ["", "-wal", "-shm"] {
        let mut name = db_path.as_os_str().to_os_string();
        name.push(suffix);
        let path = std::path::PathBuf::from(name);
        match std::fs::OpenOptions::new().write(true).open(&path) {
            Ok(f) => f.set_len(0)?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(e),
        }
    }
    Ok(())
}

impl Db {
    /// Create the schema if absent, or recreate it on a version mismatch.
    /// Returns true when the schema was (re)created now = full build.
    fn ensure_schema(&mut self) -> rusqlite::Result<bool> {
        let version: Option<i64> = match self.conn.query_row(
            "SELECT value FROM meta WHERE key='schema_version'",
            [],
            |row| row.get::<_, String>(0),
        ) {
            Ok(v) => v.parse::<i64>().ok(),
            Err(rusqlite::Error::QueryReturnedNoRows) => None,
            Err(rusqlite::Error::SqliteFailure(_, Some(ref msg)))
                if msg.contains("no such table") =>
            {
                None
            }
            Err(e) => return Err(e),
        };
        if version == Some(SCHEMA_VERSION) {
            return Ok(false);
        }
        self.recreate_schema()?;
        Ok(true)
    }

    /// Drop and recreate everything in one IMMEDIATE transaction whose
    /// first commit already contains the schema-version row (§4.6).
    fn recreate_schema(&mut self) -> rusqlite::Result<()> {
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        tx.execute_batch(
            "DROP TABLE IF EXISTS conversations;
             DROP TABLE IF EXISTS messages;
             DROP TABLE IF EXISTS meta;
             CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
             CREATE TABLE conversations(
                 session_id TEXT PRIMARY KEY,
                 path       TEXT NOT NULL,
                 mtime_ns   INTEGER NOT NULL,
                 size       INTEGER NOT NULL,
                 cwd        TEXT,
                 title      TEXT,
                 live       INTEGER NOT NULL DEFAULT 0,
                 updated_at INTEGER NOT NULL
             );
             CREATE VIRTUAL TABLE messages USING fts5(
                 text,
                 session_id UNINDEXED,
                 seq        UNINDEXED,
                 role       UNINDEXED,
                 tokenize='trigram'
             );",
        )?;
        tx.execute(
            "INSERT INTO meta(key, value) VALUES('schema_version', ?1)",
            params![SCHEMA_VERSION.to_string()],
        )?;
        tx.commit()
    }

    /// What the index currently holds, keyed by session id (for the diff).
    pub fn indexed_files(&self) -> rusqlite::Result<HashMap<String, IndexedFile>> {
        let mut stmt = self
            .conn
            .prepare("SELECT session_id, path, mtime_ns, size FROM conversations")?;
        let rows = stmt.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                IndexedFile {
                    path: row.get(1)?,
                    mtime_ns: row.get(2)?,
                    size: row.get(3)?,
                },
            ))
        })?;
        rows.collect()
    }

    /// Replace one conversation wholesale — its row, its FTS rows, and the
    /// progress counter — in a single per-conversation commit (§4.6).
    #[allow(clippy::too_many_arguments)]
    pub fn replace_conversation(
        &mut self,
        session_id: &str,
        path: &str,
        mtime_ns: i64,
        size: i64,
        updated_at: i64,
        extracted: &Extracted,
        progress_done: u64,
        progress_total: u64,
    ) -> rusqlite::Result<()> {
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        tx.execute(
            "DELETE FROM messages WHERE session_id = ?1",
            params![session_id],
        )?;
        tx.execute(
            "DELETE FROM conversations WHERE session_id = ?1",
            params![session_id],
        )?;
        tx.execute(
            "INSERT INTO conversations(session_id, path, mtime_ns, size, cwd, title, live, updated_at)
             VALUES(?1, ?2, ?3, ?4, ?5, ?6, 0, ?7)",
            params![
                session_id,
                path,
                mtime_ns,
                size,
                extracted.cwd,
                extracted.title,
                updated_at
            ],
        )?;
        // Synthetic row: title + cwd share the body's search path (§4.6
        // allows indexing them as a special role; `show` filters it).
        let meta_text = format!(
            "{}\n{}",
            extracted.title.as_deref().unwrap_or(""),
            extracted.cwd.as_deref().unwrap_or("")
        );
        if !meta_text.trim().is_empty() {
            tx.execute(
                "INSERT INTO messages(text, session_id, seq, role) VALUES(?1, ?2, '-1', ?3)",
                params![meta_text, session_id, META_ROLE],
            )?;
        }
        for (seq, m) in extracted.messages.iter().enumerate() {
            tx.execute(
                "INSERT INTO messages(text, session_id, seq, role) VALUES(?1, ?2, ?3, ?4)",
                params![m.text, session_id, seq.to_string(), m.role.as_str()],
            )?;
        }
        write_progress(&tx, progress_done, progress_total)?;
        tx.commit()
    }

    pub fn remove_conversation(&mut self, session_id: &str) -> rusqlite::Result<()> {
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        tx.execute(
            "DELETE FROM messages WHERE session_id = ?1",
            params![session_id],
        )?;
        tx.execute(
            "DELETE FROM conversations WHERE session_id = ?1",
            params![session_id],
        )?;
        tx.commit()
    }

    /// Reset the build progress rows (start of a catch-up).
    pub fn reset_progress(&mut self, total: u64) -> rusqlite::Result<()> {
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        write_progress(&tx, 0, total)?;
        tx.commit()
    }

    /// Build progress as recorded by the current lock holder, if the DB
    /// speaks the current schema version. Used by waiting `index`
    /// processes to relay progress (§4.4) — any failure reads as None.
    pub fn read_progress(&self) -> Option<(u64, u64)> {
        let version: String = self
            .conn
            .query_row(
                "SELECT value FROM meta WHERE key='schema_version'",
                [],
                |row| row.get(0),
            )
            .ok()?;
        if version.parse::<i64>().ok()? != SCHEMA_VERSION {
            return None;
        }
        let get = |key: &str| -> Option<u64> {
            self.conn
                .query_row(
                    "SELECT value FROM meta WHERE key = ?1",
                    params![key],
                    |row| row.get::<_, String>(0),
                )
                .ok()?
                .parse()
                .ok()
        };
        Some((get("progress_done")?, get("progress_total")?))
    }

    /// Set the live flags: everything in `live` is 1, the rest 0 (§4.6).
    pub fn update_live_flags(&mut self, live: &HashSet<String>) -> rusqlite::Result<()> {
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        tx.execute("UPDATE conversations SET live = 0 WHERE live != 0", [])?;
        {
            let mut stmt = tx.prepare("UPDATE conversations SET live = 1 WHERE session_id = ?1")?;
            for id in live {
                stmt.execute(params![id])?;
            }
        }
        tx.commit()
    }

    /// All conversations, newest first (browse).
    pub fn all_conversations(&self) -> rusqlite::Result<Vec<ConversationRow>> {
        let mut stmt = self.conn.prepare(
            "SELECT session_id, cwd, title, updated_at, live FROM conversations
             ORDER BY updated_at DESC, session_id",
        )?;
        let rows = stmt.query_map([], row_to_conversation)?;
        rows.collect()
    }

    /// Conversations whose ids are in `ids`, newest first.
    pub fn conversations_by_ids(
        &self,
        ids: &HashSet<String>,
    ) -> rusqlite::Result<Vec<ConversationRow>> {
        if ids.is_empty() {
            return Ok(Vec::new());
        }
        let placeholders = vec!["?"; ids.len()].join(",");
        let sql = format!(
            "SELECT session_id, cwd, title, updated_at, live FROM conversations
             WHERE session_id IN ({placeholders})
             ORDER BY updated_at DESC, session_id"
        );
        let mut stmt = self.conn.prepare(&sql)?;
        let params_vec: Vec<&dyn rusqlite::ToSql> =
            ids.iter().map(|s| s as &dyn rusqlite::ToSql).collect();
        let rows = stmt.query_map(params_vec.as_slice(), row_to_conversation)?;
        rows.collect()
    }

    /// Session ids whose indexed text contains `term` (case-insensitive
    /// substring). Terms of 2 characters go through LIKE (the only LIKE
    /// path); 3+ characters use FTS MATCH with the term quoted as a phrase
    /// string so FTS5's query language cannot be injected (§4.6).
    pub fn sessions_matching_term(&self, term: &str) -> rusqlite::Result<HashSet<String>> {
        let (sql, param) = if term.chars().count() >= 3 {
            (
                "SELECT DISTINCT session_id FROM messages WHERE messages MATCH ?1",
                fts_phrase(term),
            )
        } else {
            (
                "SELECT DISTINCT session_id FROM messages WHERE text LIKE ?1 ESCAPE '\\'",
                like_pattern(term),
            )
        };
        let mut stmt = self.conn.prepare(sql)?;
        let rows = stmt.query_map(params![param], |row| row.get::<_, String>(0))?;
        rows.collect()
    }

    /// One conversation's full utterance sequence (§4.4's `show`): None
    /// when the session id is not in the index.
    pub fn show(&self, session_id: &str) -> rusqlite::Result<Option<ShowResult>> {
        let head = self.conn.query_row(
            "SELECT cwd, title FROM conversations WHERE session_id = ?1",
            params![session_id],
            |row| {
                Ok((
                    row.get::<_, Option<String>>(0)?,
                    row.get::<_, Option<String>>(1)?,
                ))
            },
        );
        let (cwd, title) = match head {
            Ok(v) => v,
            Err(rusqlite::Error::QueryReturnedNoRows) => return Ok(None),
            Err(e) => return Err(e),
        };
        let mut stmt = self.conn.prepare(
            "SELECT seq, role, text FROM messages
             WHERE session_id = ?1 AND role != ?2
             ORDER BY CAST(seq AS INTEGER)",
        )?;
        let rows = stmt.query_map(params![session_id, META_ROLE], |row| {
            Ok(ShowMessage {
                seq: row.get::<_, String>(0)?.parse::<i64>().unwrap_or_default(),
                role: row.get(1)?,
                text: row.get(2)?,
            })
        })?;
        let messages = rows.collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(Some(ShowResult {
            session_id: session_id.to_string(),
            cwd,
            title,
            messages,
        }))
    }
}

fn row_to_conversation(row: &rusqlite::Row<'_>) -> rusqlite::Result<ConversationRow> {
    Ok(ConversationRow {
        session_id: row.get(0)?,
        cwd: row.get(1)?,
        title: row.get(2)?,
        updated_at: row.get(3)?,
        live: row.get::<_, i64>(4)? != 0,
    })
}

/// Progress rows travel inside the caller's transaction so they commit
/// together with the conversation they describe (§4.6).
fn write_progress(tx: &rusqlite::Transaction<'_>, done: u64, total: u64) -> rusqlite::Result<()> {
    tx.execute(
        "INSERT INTO meta(key, value) VALUES('progress_done', ?1)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![done.to_string()],
    )?;
    tx.execute(
        "INSERT INTO meta(key, value) VALUES('progress_total', ?1)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![total.to_string()],
    )?;
    Ok(())
}

/// Quote a term as an FTS5 phrase string: wrap in double quotes, double
/// any internal double quotes. This neutralizes the whole FTS5 query
/// language (AND/OR/NEAR/*/^...).
fn fts_phrase(term: &str) -> String {
    format!("\"{}\"", term.replace('"', "\"\""))
}

/// `%term%` with LIKE wildcards escaped (`\` is the ESCAPE character).
fn like_pattern(term: &str) -> String {
    let escaped = term
        .replace('\\', "\\\\")
        .replace('%', "\\%")
        .replace('_', "\\_");
    format!("%{escaped}%")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fts_phrase_neutralizes_query_syntax() {
        assert_eq!(fts_phrase("abc"), "\"abc\"");
        assert_eq!(fts_phrase("ab\"cd"), "\"ab\"\"cd\"");
        assert_eq!(fts_phrase("a OR b"), "\"a OR b\"");
    }

    #[test]
    fn like_pattern_escapes_wildcards() {
        assert_eq!(like_pattern("ab"), "%ab%");
        assert_eq!(like_pattern("a%"), "%a\\%%");
        assert_eq!(like_pattern("a_"), "%a\\_%");
        assert_eq!(like_pattern("a\\"), "%a\\\\%");
    }

    /// T1 (M34 brief): FTS5 + the trigram tokenizer must work through the
    /// libsqlite3 this binary actually links (the /usr/bin/sqlite3 CLI was
    /// verified separately — this test is about the linked dylib).
    #[test]
    fn linked_libsqlite3_supports_fts5_with_trigram() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE VIRTUAL TABLE t USING fts5(body, tokenize='trigram');
             INSERT INTO t(body) VALUES('The quick brown fox jumps');
             INSERT INTO t(body) VALUES('conversations index in SQLite');",
        )
        .unwrap();
        let count = |q: &str| -> i64 {
            conn.query_row(
                "SELECT count(*) FROM t WHERE t MATCH ?1",
                params![q],
                |row| row.get(0),
            )
            .unwrap()
        };
        // Substring match (not word-boundary): the trigram tokenizer's
        // defining behavior.
        assert_eq!(count("\"uick brow\""), 1);
        assert_eq!(count("\"onversation\""), 1);
        // Case-insensitive by default.
        assert_eq!(count("\"QUICK\""), 1);
        assert_eq!(count("\"nothing here\""), 0);
    }
}
