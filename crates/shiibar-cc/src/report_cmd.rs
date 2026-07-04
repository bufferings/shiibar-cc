//! `shiibar-cc report <event>` (DESIGN.md §4.1/§4.4, implemented in M1).
//! Moved here unchanged in behavior from the M1 `main.rs` (only the socket
//! path resolution now goes through `shiibar_cc_client::connection`, removing
//! the duplicate copy that used to live in this crate — DESIGN.md §4.3 M2
//! brief: "clean it up if it duplicates the M1 shiibar-cc side").

use shiibar_cc_proto::{HookEvent, ReportPayload, Request, codec, extract};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// hooks send timeout (§9).
const SEND_TIMEOUT: Duration = Duration::from_secs(1);

/// Always succeeds from the caller's point of view: `report` is the sole
/// exception to the normal exit-code rules (§4.4) and must exit 0 no
/// matter what (daemon absent, malformed input, timeout, ...) so hooks are
/// never blocked or shown a hook "failure".
pub fn run(event_arg: Option<String>, socket_path: &Path) {
    let Some(event_arg) = event_arg else {
        eprintln!("shiibar-cc report: missing <event> argument");
        return;
    };
    let event = match parse_event(&event_arg) {
        Some(e) => e,
        None => {
            eprintln!("shiibar-cc report: unknown event '{event_arg}'");
            return;
        }
    };

    let mut raw_stdin = String::new();
    if let Err(e) = std::io::stdin().read_to_string(&mut raw_stdin) {
        eprintln!("shiibar-cc report: failed to read stdin: {e}");
        return;
    }
    let raw: serde_json::Value = match serde_json::from_str(&raw_stdin) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("shiibar-cc report: invalid hook JSON on stdin: {e}");
            return;
        }
    };

    // Target generation rule (§2/§4.1): the UUID half of $ITERM_SESSION_ID
    // (`wNtNpN:UUID`). No $ITERM_SESSION_ID (or one with no `:`) means this
    // session isn't in iTerm2 at all (§8.11) — build_report signals that
    // with `Ok(None)`, and the report is dropped without ever touching the
    // socket (still exit 0, per this command's always-succeed contract).
    let iterm_session_id = std::env::var("ITERM_SESSION_ID").ok();
    let now = now_epoch_secs();

    let payload = match extract::build_report(event, &raw, iterm_session_id.as_deref(), now) {
        Ok(Some(p)) => p,
        Ok(None) => return, // outside iTerm2: drop, no fallback target (§8.11)
        Err(e) => {
            eprintln!("shiibar-cc report: {e}");
            return;
        }
    };

    // From here on, failures (no daemon, timeout, broken pipe, ...) are
    // expected/routine and must stay silent (§4.1: hooks must not be
    // disturbed by shiibar-ccd being absent).
    send_with_timeout(payload, socket_path.to_path_buf());
}

fn parse_event(s: &str) -> Option<HookEvent> {
    serde_json::from_value(serde_json::Value::String(s.to_string())).ok()
}

fn now_epoch_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Best-effort, bounded to ~1s total (§9). Connecting to a Unix socket
/// either succeeds or fails near-instantly, so a real hang would only come
/// from a stalled daemon; run the attempt on a side thread and give up
/// (silently) once the deadline passes, regardless of outcome.
fn send_with_timeout(payload: ReportPayload, socket_path: std::path::PathBuf) {
    let (tx, rx) = std::sync::mpsc::channel();
    let handle = std::thread::spawn(move || {
        let _ = tx.send(try_send(payload, &socket_path));
    });
    let _ = rx.recv_timeout(SEND_TIMEOUT);
    // Not joined on purpose: if try_send is still stuck past the deadline,
    // waiting on it would defeat the whole point of the timeout. The
    // process exits right after this call, tearing the thread down with it.
    drop(handle);
}

fn try_send(payload: ReportPayload, socket_path: &Path) -> std::io::Result<()> {
    let mut stream = UnixStream::connect(socket_path)?;
    let line = codec::encode_line(&Request::Report(payload)).map_err(std::io::Error::other)?;
    stream.write_all(line.as_bytes())?;
    Ok(())
}
