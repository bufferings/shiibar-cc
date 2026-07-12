//! `shiibar-cc conversations index|search|show` (DESIGN.md §4.4): the CLI
//! face of the conversations module. Output is dual, like doctor: default
//! human-readable text, `--json` machine-readable — and the JSON shapes
//! are the PUBLIC contract scripts may depend on (snake_case, epoch
//! seconds, consumers ignore unknown fields).
//!
//! Exit codes (§4.4): `index`/`search` 0 or 1 (0 matches is still 0;
//! a query with no valid term is 1, never a silent empty result);
//! `show` 0 / 1 / 2 (2 = session id not in the index).

use crate::conversations::{self, Deps, ProgressEvent, SearchError};
use crate::exitcode;
use serde::Serialize;
use std::io::Write;

/// §4.4: `{"conversations":[{"session_id","cwd","title","updated_at","live"}]}`.
#[derive(Serialize)]
struct SearchJson<'a> {
    conversations: Vec<ConversationJson<'a>>,
}

#[derive(Serialize)]
struct ConversationJson<'a> {
    session_id: &'a str,
    cwd: Option<&'a str>,
    title: Option<&'a str>,
    updated_at: i64,
    live: bool,
}

/// §4.4: `{"session_id","cwd","title","messages":[{"seq","role","text"}]}`.
#[derive(Serialize)]
struct ShowJson<'a> {
    session_id: &'a str,
    cwd: Option<&'a str>,
    title: Option<&'a str>,
    messages: Vec<MessageJson<'a>>,
}

#[derive(Serialize)]
struct MessageJson<'a> {
    seq: i64,
    role: &'a str,
    text: &'a str,
}

/// §4.4 `index --json` line events.
#[derive(Serialize)]
#[serde(tag = "event", rename_all = "snake_case")]
enum IndexEventJson {
    Start { total: u64 },
    Progress { done: u64, total: u64 },
    Done { indexed: u64, removed: u64 },
    Error { message: String },
}

fn write_event(out: &mut dyn Write, event: &IndexEventJson) {
    if let Ok(line) = serde_json::to_string(event) {
        let _ = writeln!(out, "{line}");
        let _ = out.flush(); // line stream: consumers draw the latest line
    }
}

/// `conversations index [--json]`.
pub fn run_index(deps: &Deps, json: bool, out: &mut dyn Write, err: &mut dyn Write) -> i32 {
    let mut last_done: Option<(u64, u64)> = None;
    let result = conversations::run_index(deps, &mut |event| {
        if json {
            let e = match event {
                ProgressEvent::Start { total } => IndexEventJson::Start { total },
                ProgressEvent::Progress { done, total } => IndexEventJson::Progress { done, total },
                ProgressEvent::Done { indexed, removed } => {
                    IndexEventJson::Done { indexed, removed }
                }
            };
            write_event(out, &e);
        }
        if let ProgressEvent::Done { indexed, removed } = event {
            last_done = Some((indexed, removed));
        }
    });
    match result {
        Ok(()) => {
            if !json {
                let (indexed, removed) = last_done.unwrap_or((0, 0));
                let _ = writeln!(out, "Indexed {indexed} conversation(s), removed {removed}.");
            }
            exitcode::OK
        }
        Err(e) => {
            if json {
                write_event(
                    out,
                    &IndexEventJson::Error {
                        message: e.to_string(),
                    },
                );
            }
            let _ = writeln!(err, "shiibar-cc conversations index: {e}");
            exitcode::ERROR
        }
    }
}

/// `conversations search [<query>] [--json]`.
pub fn run_search(
    deps: &Deps,
    query: Option<&str>,
    json: bool,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> i32 {
    // "Building index…" goes to stderr when this call starts a full build
    // itself, then the search waits for completion (§4.4/§4.6).
    let result = conversations::run_search(deps, query, &mut || {
        let _ = writeln!(err, "Building index\u{2026}");
    });
    let rows = match result {
        Ok(rows) => rows,
        Err(SearchError::QueryTooShort) => {
            let _ = writeln!(err, "query too short (minimum 2 characters)");
            return exitcode::ERROR;
        }
        Err(SearchError::Other(e)) => {
            let _ = writeln!(err, "shiibar-cc conversations search: {e}");
            return exitcode::ERROR;
        }
    };
    if json {
        let payload = SearchJson {
            conversations: rows
                .iter()
                .map(|r| ConversationJson {
                    session_id: &r.session_id,
                    cwd: r.cwd.as_deref(),
                    title: r.title.as_deref(),
                    updated_at: r.updated_at,
                    live: r.live,
                })
                .collect(),
        };
        if let Ok(s) = serde_json::to_string(&payload) {
            let _ = writeln!(out, "{s}");
        }
    } else {
        let _ = writeln!(out, "{}", format_search_table(&rows, now_epoch_secs()));
    }
    exitcode::OK
}

/// `conversations show <session-id> [--json]`.
pub fn run_show(
    deps: &Deps,
    session_id: &str,
    json: bool,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> i32 {
    let result = match conversations::run_show(deps, session_id) {
        Ok(Some(r)) => r,
        Ok(None) => {
            let _ = writeln!(
                err,
                "no conversation with session id '{session_id}' in the index"
            );
            return exitcode::NOT_FOUND;
        }
        Err(e) => {
            let _ = writeln!(err, "shiibar-cc conversations show: {e}");
            return exitcode::ERROR;
        }
    };
    if json {
        let payload = ShowJson {
            session_id: &result.session_id,
            cwd: result.cwd.as_deref(),
            title: result.title.as_deref(),
            messages: result
                .messages
                .iter()
                .map(|m| MessageJson {
                    seq: m.seq,
                    role: &m.role,
                    text: &m.text,
                })
                .collect(),
        };
        if let Ok(s) = serde_json::to_string(&payload) {
            let _ = writeln!(out, "{s}");
        }
    } else {
        let _ = writeln!(out, "session: {}", result.session_id);
        let _ = writeln!(out, "cwd: {}", result.cwd.as_deref().unwrap_or("-"));
        let _ = writeln!(out, "title: {}", result.title.as_deref().unwrap_or("-"));
        for m in &result.messages {
            let _ = writeln!(out, "\n[{}]\n{}", m.role, m.text);
        }
    }
    exitcode::OK
}

fn now_epoch_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Human-facing table (not a contract): age, running marker, folder label,
/// session id, title.
fn format_search_table(rows: &[conversations::db::ConversationRow], now: i64) -> String {
    if rows.is_empty() {
        return "(no conversations)".to_string();
    }
    let cells: Vec<(String, &str, String, &str, &str)> = rows
        .iter()
        .map(|r| {
            (
                crate::list_cmd::format_elapsed(now - r.updated_at),
                if r.live { "running" } else { "" },
                shiibar_cc_client::label::format_cwd_label(r.cwd.as_deref().unwrap_or("")),
                r.session_id.as_str(),
                r.title.as_deref().unwrap_or("-"),
            )
        })
        .collect();
    let age_w = cells.iter().map(|c| c.0.len()).max().unwrap_or(0);
    let label_w = cells.iter().map(|c| c.2.len()).max().unwrap_or(0);
    cells
        .iter()
        .map(|(age, run, label, id, title)| {
            format!("{age:>age_w$}  {run:<7}  {label:<label_w$}  {id}  {title}")
        })
        .collect::<Vec<_>>()
        .join("\n")
}
