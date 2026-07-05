//! `shiibar-cc list [--json]` (DESIGN.md §4.4): `--json` forwards the wire
//! `list` response verbatim; the default text form is an aligned
//! "status / label / elapsed time / target" table.

use crate::exitcode;
use shiibar_cc_client::label::format_cwd_label;
use shiibar_cc_proto::{Agent, ListResponse, Request, Status};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

pub struct ListReport {
    pub exit_code: i32,
    /// Already newline-free text ready to `println!`, if any (empty output
    /// on error).
    pub stdout: String,
    pub stderr: Option<String>,
}

pub fn run_list(socket_path: &Path, json: bool) -> ListReport {
    if json {
        match shiibar_cc_client::connection::request_raw(socket_path, &Request::List) {
            Ok(line) => ListReport {
                exit_code: exitcode::OK,
                stdout: line.trim_end().to_string(),
                stderr: None,
            },
            Err(e) => ListReport {
                exit_code: exitcode::ERROR,
                stdout: String::new(),
                stderr: Some(format!("shiibar-cc list: {e}")),
            },
        }
    } else {
        match shiibar_cc_client::connection::request::<ListResponse>(socket_path, &Request::List) {
            Ok(resp) => ListReport {
                exit_code: exitcode::OK,
                stdout: format_table(&resp.agents, now_epoch_secs()),
                stderr: None,
            },
            Err(e) => ListReport {
                exit_code: exitcode::ERROR,
                stdout: String::new(),
                stderr: Some(format!("shiibar-cc list: {e}")),
            },
        }
    }
}

fn now_epoch_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn status_label(status: Status) -> &'static str {
    match status {
        Status::Idle => "idle",
        Status::Working => "working",
        Status::Waiting => "waiting",
        Status::Unknown => "unknown",
    }
}

/// Text-form status cell (DESIGN.md / M1M2 respec brief): an unreviewed
/// entry gets a trailing `*` (e.g. `waiting*`) — the only thing the plain
/// `list` text form has room for to surface "you haven't seen this yet"
/// without a color-capable terminal.
fn status_cell(status: Status, unreviewed: bool) -> String {
    if unreviewed {
        format!("{}*", status_label(status))
    } else {
        status_label(status).to_string()
    }
}

/// "3s" / "5m" / "2h" / "4d" — coarse, single-unit elapsed time.
pub fn format_elapsed(secs: i64) -> String {
    let secs = secs.max(0);
    if secs < 60 {
        format!("{secs}s")
    } else if secs < 3600 {
        format!("{}m", secs / 60)
    } else if secs < 86400 {
        format!("{}h", secs / 3600)
    } else {
        format!("{}d", secs / 86400)
    }
}

fn format_table(agents: &[Agent], now: i64) -> String {
    if agents.is_empty() {
        return "(no agents)".to_string();
    }

    let rows: Vec<(String, String, String, &str)> = agents
        .iter()
        .map(|a| {
            (
                status_cell(a.status, a.unreviewed),
                format_cwd_label(&a.cwd),
                format_elapsed(now - a.since),
                a.target.as_str(),
            )
        })
        .collect();

    let status_w = rows.iter().map(|r| r.0.len()).max().unwrap_or(0);
    let label_w = rows.iter().map(|r| r.1.len()).max().unwrap_or(0);
    let elapsed_w = rows.iter().map(|r| r.2.len()).max().unwrap_or(0);

    rows.iter()
        .map(|(status, label, elapsed, target)| {
            format!("{status:status_w$}  {label:label_w$}  {elapsed:>elapsed_w$}  {target}")
        })
        .collect::<Vec<_>>()
        .join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use shiibar_cc_proto::Status;

    fn agent(target: &str, status: Status, cwd: &str, since: i64) -> Agent {
        agent_with_flag(target, status, false, cwd, since)
    }

    fn agent_with_flag(target: &str, status: Status, unreviewed: bool, cwd: &str, since: i64) -> Agent {
        Agent {
            target: target.to_string(),
            status,
            unreviewed,
            session_id: "s".into(),
            cwd: cwd.to_string(),
            task: None,
            message: None,
            last_assistant_message: None,
            created_at: since,
            last_report_at: since,
            since,
            last_seen: since,
        }
    }

    #[test]
    fn format_elapsed_buckets() {
        assert_eq!(format_elapsed(5), "5s");
        assert_eq!(format_elapsed(90), "1m");
        assert_eq!(format_elapsed(3661), "1h");
        assert_eq!(format_elapsed(90000), "1d");
    }

    #[test]
    fn empty_table_says_so() {
        assert_eq!(format_table(&[], 100), "(no agents)");
    }

    #[test]
    fn table_has_one_aligned_row_per_agent() {
        let agents = vec![
            agent("t1", Status::Waiting, "/home/x/a/b", 90),
            agent("t2", Status::Idle, "/home/x/c", 40),
        ];
        let table = format_table(&agents, 100);
        let lines: Vec<&str> = table.lines().collect();
        assert_eq!(lines.len(), 2);
        assert!(lines[0].starts_with("waiting"));
        assert!(lines[0].ends_with("t1"));
        assert!(lines[1].starts_with("idle   ")); // padded to "waiting"'s width
    }

    #[test]
    fn unreviewed_entries_get_a_trailing_asterisk_in_text_form() {
        let agents = vec![
            agent_with_flag("t1", Status::Waiting, true, "/proj/a", 90),
            agent_with_flag("t2", Status::Idle, true, "/proj/b", 40),
            agent("t3", Status::Idle, "/proj/c", 40),
        ];
        let table = format_table(&agents, 100);
        let lines: Vec<&str> = table.lines().collect();
        assert!(lines[0].starts_with("waiting*"));
        assert!(lines[1].starts_with("idle*"));
        assert!(lines[2].starts_with("idle "), "reviewed entry has no asterisk: {:?}", lines[2]);
    }
}
