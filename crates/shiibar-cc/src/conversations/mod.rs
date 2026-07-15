//! Conversations: index, search and read Claude Code transcripts
//! (DESIGN.md §4.6). ALL knowledge of the transcript files, the
//! `~/.claude/sessions` pid registry, and SQLite lives inside this module
//! (design principle 2 — the same localization as iTerm2 knowledge in the
//! iterm module). The commands never talk to the daemon.
//!
//! Invariant (§4.6): every command answers against the CURRENT state of
//! the transcripts. The DB is a self-updating internal cache — `index` and
//! `search` run the catch-up first (under the `<DB path>.lock` flock);
//! `show` only reads the DB (whatever the list showed is indexed).

pub mod db;
pub mod live;
pub mod lock;
pub mod transcript;

use std::collections::HashSet;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::{Duration, Instant};

/// Everything the environment injects (M34 brief): the transcript root,
/// the pid-file registry, the DB path, and the process liveness check.
/// Tests substitute all four; `main.rs` wires the real ones.
pub struct Deps {
    /// Default `~/.claude/projects`.
    pub projects_dir: PathBuf,
    /// Default `~/.claude/sessions`.
    pub sessions_dir: PathBuf,
    /// Default `resolve_state_dir()/conversations-index.db` (§9).
    pub db_path: PathBuf,
    pub probe: Box<dyn live::LivenessProbe>,
}

/// Progress stream for `index` (§4.4: start / progress / done; the error
/// event is the CLI layer's, paired with exit 1). `start` can appear more
/// than once in a stream and counters are non-monotonic (builder handover
/// while relaying) — consumers always draw the latest line.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProgressEvent {
    Start { total: u64 },
    Progress { done: u64, total: u64 },
    Done { indexed: u64, removed: u64 },
}

/// Emission throttle for progress events: every N files or every interval
/// (§9: "100 files or 250ms").
const PROGRESS_EMIT_FILES: u64 = 100;
const PROGRESS_EMIT_INTERVAL: Duration = Duration::from_millis(250);

/// Poll cadence while relaying another builder's progress (M34 brief:
/// about 250ms).
const RELAY_POLL_INTERVAL: Duration = Duration::from_millis(250);

/// `conversations index`: catch-up only (§4.4/§4.6).
pub fn run_index(deps: &Deps, emit: &mut dyn FnMut(ProgressEvent)) -> anyhow::Result<()> {
    ensure_state_dir(&deps.db_path)?;
    let lock_path = lock::lock_path_for(&deps.db_path);
    let _lock = match lock::try_acquire(&lock_path)? {
        Some(l) => l,
        None => wait_relaying_progress(&lock_path, &deps.db_path, emit)?,
    };
    let (mut db, _full_build) = db::open_rw(&deps.db_path)?;
    let outcome = catch_up(deps, &mut db, emit)?;
    emit(ProgressEvent::Done {
        indexed: outcome.indexed,
        removed: outcome.removed,
    });
    Ok(())
}

/// `conversations search` failures the CLI maps to exit codes.
#[derive(Debug)]
pub enum SearchError {
    /// No valid term (2+ characters) in a non-empty query — exit 1, never
    /// a silent empty result (§4.4).
    QueryTooShort,
    Other(anyhow::Error),
}

impl<E: Into<anyhow::Error>> From<E> for SearchError {
    fn from(e: E) -> Self {
        SearchError::Other(e.into())
    }
}

/// `conversations search`: catch up, then query. `on_full_build` fires
/// when this call starts a full build itself (the CLI prints "Building
/// index…" to stderr and waits — §4.4). No query (None or blank) = browse
/// = all conversations, newest first.
pub fn run_search(
    deps: &Deps,
    query: Option<&str>,
    on_full_build: &mut dyn FnMut(),
) -> Result<Vec<db::ConversationRow>, SearchError> {
    let parsed = parse_query(query.unwrap_or(""));
    let terms = match parsed {
        Query::TooShort => return Err(SearchError::QueryTooShort),
        Query::Browse => Vec::new(),
        Query::Terms(t) => t,
    };
    ensure_state_dir(&deps.db_path)?;
    let lock_path = lock::lock_path_for(&deps.db_path);
    // Wait for whoever is building; full builds too — partial results are
    // never returned (§4.6). The lock is held through the queries so the
    // result set matches the catch-up this call just did.
    let _lock = lock::acquire_blocking(&lock_path)?;
    let (mut db, full_build) = db::open_rw(&deps.db_path)?;
    if full_build {
        on_full_build();
    }
    catch_up(deps, &mut db, &mut |_| {})?;

    if terms.is_empty() {
        return Ok(db.all_conversations()?);
    }
    // One independent query per term, intersected in code — no branching
    // on term-length combinations, and serial is enough (§4.6).
    let mut ids: Option<HashSet<String>> = None;
    for term in &terms {
        let matched = db.sessions_matching_term(term)?;
        ids = Some(match ids {
            None => matched,
            Some(acc) => acc.intersection(&matched).cloned().collect(),
        });
        if ids.as_ref().is_some_and(HashSet::is_empty) {
            return Ok(Vec::new());
        }
    }
    Ok(db.conversations_by_ids(&ids.unwrap_or_default())?)
}

/// `conversations show`: DB read only, no catch-up (§4.6). `Ok(None)` =
/// the session id is not in the index (exit 2) — a missing DB or missing
/// tables read as an empty index.
pub fn run_show(deps: &Deps, session_id: &str) -> anyhow::Result<Option<db::ShowResult>> {
    let db = match db::open_ro(&deps.db_path) {
        Ok(db) => db,
        // No DB file yet = empty index = not found.
        Err(rusqlite::Error::SqliteFailure(e, _))
            if e.code == rusqlite::ffi::ErrorCode::CannotOpen =>
        {
            return Ok(None);
        }
        Err(e) => return Err(e.into()),
    };
    match db.show(session_id) {
        Ok(v) => Ok(v),
        // A DB without our tables (e.g. created but never built) is an
        // empty index, not an internal error.
        Err(rusqlite::Error::SqliteFailure(_, Some(ref msg))) if msg.contains("no such table") => {
            Ok(None)
        }
        Err(e) => Err(e.into()),
    }
}

/// Query parsing (§4.6): trim surrounding whitespace (ASCII and ideographic
/// — `char::is_whitespace` covers U+3000), split on whitespace, AND the
/// terms. Terms start at 2 characters; 1-character terms are ignored; no
/// term-count limit.
#[derive(Debug, PartialEq, Eq)]
pub enum Query {
    /// Blank query: browse (all conversations).
    Browse,
    Terms(Vec<String>),
    /// Non-blank query with no valid term.
    TooShort,
}

pub fn parse_query(query: &str) -> Query {
    // NFC before anything else (4.6 / 8.38(12)): IME input arrives in the
    // decomposed form on macOS, and the corpus is stored composed - both
    // sides of the match normalize (the app also normalizes before dispatch;
    // this covers every other entry path, e.g. a terminal).
    use unicode_normalization::UnicodeNormalization;
    let normalized: String = query.nfc().collect();
    let trimmed = normalized.trim();
    if trimmed.is_empty() {
        return Query::Browse;
    }
    let terms: Vec<String> = trimmed
        .split_whitespace()
        .filter(|w| w.chars().count() >= 2)
        .map(str::to_string)
        .collect();
    if terms.is_empty() {
        Query::TooShort
    } else {
        Query::Terms(terms)
    }
}

/// One transcript file found by the stat sweep.
#[derive(Debug, Clone)]
struct SweptFile {
    session_id: String,
    path: PathBuf,
    mtime_ns: i64,
    updated_at: i64,
    size: i64,
}

/// Stat sweep of `<projects>/<slug>/<session_id>.jsonl` (§4.6's source
/// pattern — exactly one directory level; deeper `subagents/*.jsonl` files
/// are sidechain transcripts, not conversations). Missing root = no
/// conversations. mtime is compared at nanosecond precision (M34 brief).
fn sweep(projects_dir: &Path) -> io::Result<Vec<SweptFile>> {
    let mut out: Vec<SweptFile> = Vec::new();
    let slugs = match std::fs::read_dir(projects_dir) {
        Ok(rd) => rd,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(out),
        Err(e) => return Err(e),
    };
    for slug in slugs.flatten() {
        let slug_path = slug.path();
        if !slug_path.is_dir() {
            continue;
        }
        let Ok(entries) = std::fs::read_dir(&slug_path) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("jsonl") {
                continue;
            }
            let Some(stem) = path.file_stem().and_then(|s| s.to_str()) else {
                continue;
            };
            let Ok(meta) = entry.metadata() else {
                continue; // vanished mid-sweep
            };
            if !meta.is_file() {
                continue;
            }
            let Ok(modified) = meta.modified() else {
                continue;
            };
            let since_epoch = modified
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default();
            out.push(SweptFile {
                session_id: stem.to_string(),
                path,
                mtime_ns: since_epoch.as_nanos() as i64,
                updated_at: since_epoch.as_secs() as i64,
                size: meta.len() as i64,
            });
        }
    }
    // Newest first: both the processing order (§4.4) and, should the same
    // session id ever appear under two slugs, a deterministic winner (the
    // newer file) via the dedup below.
    out.sort_by_key(|f| std::cmp::Reverse(f.mtime_ns));
    let mut seen = HashSet::new();
    out.retain(|f| seen.insert(f.session_id.clone()));
    Ok(out)
}

struct CatchUpOutcome {
    indexed: u64,
    removed: u64,
}

/// The catch-up (§4.6): stat sweep -> full re-read of changed files with
/// wholesale row replacement (one commit per conversation) -> removal of
/// vanished files -> live/past flag update. Caller must hold the flock.
fn catch_up(
    deps: &Deps,
    db: &mut db::Db,
    emit: &mut dyn FnMut(ProgressEvent),
) -> anyhow::Result<CatchUpOutcome> {
    let swept = sweep(&deps.projects_dir)?;
    let existing = db.indexed_files()?;

    let changed: Vec<&SweptFile> = swept
        .iter()
        .filter(|f| {
            existing.get(&f.session_id)
                != Some(&db::IndexedFile {
                    path: f.path.to_string_lossy().into_owned(),
                    mtime_ns: f.mtime_ns,
                    size: f.size,
                })
        })
        .collect();
    let swept_ids: HashSet<&str> = swept.iter().map(|f| f.session_id.as_str()).collect();
    let removed_ids: Vec<String> = existing
        .keys()
        .filter(|id| !swept_ids.contains(id.as_str()))
        .cloned()
        .collect();

    let total = changed.len() as u64;
    db.reset_progress(total)?;
    emit(ProgressEvent::Start { total });

    let mut throttle_mark = Instant::now();
    let mut last_emitted_done: u64 = 0;
    let mut done: u64 = 0;
    for file in changed {
        // A file that vanished between sweep and read is simply skipped;
        // the next catch-up removes it (§4.6: skip and continue).
        if let Ok(content) = std::fs::read_to_string(&file.path) {
            let extracted = transcript::extract(&content);
            db.replace_conversation(
                &file.session_id,
                &file.path.to_string_lossy(),
                file.mtime_ns,
                file.size,
                file.updated_at,
                &extracted,
                done + 1,
                total,
            )?;
        }
        done += 1;
        if done - last_emitted_done >= PROGRESS_EMIT_FILES
            || throttle_mark.elapsed() >= PROGRESS_EMIT_INTERVAL
        {
            emit(ProgressEvent::Progress { done, total });
            last_emitted_done = done;
            throttle_mark = Instant::now();
        }
    }

    for id in &removed_ids {
        db.remove_conversation(id)?;
    }

    let live = live::live_session_ids(&deps.sessions_dir, deps.probe.as_ref());
    db.update_live_flags(&live)?;

    Ok(CatchUpOutcome {
        indexed: done,
        removed: removed_ids.len() as u64,
    })
}

/// Block on the flock in a helper thread and, while waiting, relay the
/// lock holder's progress from the meta table as our own stream (§4.4:
/// callers get the same shape from whichever `index` they invoked). The
/// reads are read-only best effort: no DB, no tables, or an old schema
/// version all read as "no progress yet".
fn wait_relaying_progress(
    lock_path: &Path,
    db_path: &Path,
    emit: &mut dyn FnMut(ProgressEvent),
) -> anyhow::Result<lock::CatchUpLock> {
    let (tx, rx) = mpsc::channel();
    let lock_path = lock_path.to_path_buf();
    std::thread::spawn(move || {
        let _ = tx.send(lock::acquire_blocking(&lock_path));
    });
    let mut last: Option<(u64, u64)> = None;
    loop {
        match rx.recv_timeout(RELAY_POLL_INTERVAL) {
            Ok(result) => return Ok(result?),
            Err(mpsc::RecvTimeoutError::Timeout) => {
                let Some((done, total)) = read_progress_best_effort(db_path) else {
                    continue;
                };
                if last.map(|(_, t)| t) != Some(total) {
                    emit(ProgressEvent::Start { total });
                }
                if last != Some((done, total)) {
                    emit(ProgressEvent::Progress { done, total });
                    last = Some((done, total));
                }
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                anyhow::bail!("lock waiter thread terminated unexpectedly");
            }
        }
    }
}

fn read_progress_best_effort(db_path: &Path) -> Option<(u64, u64)> {
    db::open_ro(db_path).ok()?.read_progress()
}

/// Create the state dir with 0700 if missing (§4.6; same rule as the rest
/// of the state dir).
fn ensure_state_dir(db_path: &Path) -> io::Result<()> {
    use std::os::unix::fs::DirBuilderExt;
    let Some(parent) = db_path.parent() else {
        return Ok(());
    };
    if parent.as_os_str().is_empty() || parent.exists() {
        return Ok(());
    }
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(parent)
}

#[cfg(test)]
mod tests {
    #[test]
    fn parse_query_normalizes_to_nfc() {
        // 4.6 / 8.38(12): a decomposed query (hi + U+3099) parses to the
        // composed term (bi), so matching is composition-form independent.
        match super::parse_query("\u{30D2}\u{3099}\u{30B9}") {
            super::Query::Terms(terms) => assert_eq!(terms, vec!["\u{30D3}\u{30B9}".to_string()]),
            other => panic!("expected terms, got {other:?}"),
        }
    }

    use super::*;

    #[test]
    fn parse_query_blank_is_browse() {
        assert_eq!(parse_query(""), Query::Browse);
        assert_eq!(parse_query("   "), Query::Browse);
        // Ideographic space (U+3000) counts as whitespace.
        assert_eq!(parse_query("\u{3000}\u{3000}"), Query::Browse);
    }

    #[test]
    fn parse_query_trims_and_splits_on_ascii_and_ideographic_space() {
        assert_eq!(
            parse_query("  rust\u{3000}sqlite "),
            Query::Terms(vec!["rust".to_string(), "sqlite".to_string()])
        );
    }

    #[test]
    fn parse_query_ignores_one_character_terms() {
        assert_eq!(
            parse_query("a rust b"),
            Query::Terms(vec!["rust".to_string()])
        );
    }

    #[test]
    fn parse_query_only_short_terms_is_too_short() {
        assert_eq!(parse_query("a b c"), Query::TooShort);
        assert_eq!(parse_query("x"), Query::TooShort);
    }

    #[test]
    fn parse_query_counts_characters_not_bytes() {
        // Two Japanese characters = a valid term (multi-byte in UTF-8).
        assert_eq!(
            parse_query("\u{691c}\u{7d22}"),
            Query::Terms(vec!["\u{691c}\u{7d22}".to_string()])
        );
    }
}
