//! shiibarctl: CLI for shiibard (report / list / wait / watch / focus / ...).
//!
//! Spec: docs/DESIGN.md §4.4. M1 implements only the `report` subcommand;
//! everything else is out of scope until M2 (no stubs either, per the M1
//! task brief).

use shiibar_proto::{codec, extract, HookEvent, Request, ReportPayload};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// hooks 送信タイムアウト (§9).
const SEND_TIMEOUT: Duration = Duration::from_secs(1);

fn main() {
    let mut args = std::env::args().skip(1);
    match args.next().as_deref() {
        Some("report") => {
            // §4.4: `report` is the one exception to normal exit codes — it
            // must always exit 0 (daemon absent, timeout, malformed input),
            // so hooks are never blocked or shown a hook "failure".
            run_report(args.next());
            std::process::exit(0);
        }
        _ => {
            eprintln!("usage: shiibarctl report <event>");
            eprintln!("(other subcommands are not implemented yet — see docs/tasks/M1.md)");
            std::process::exit(1);
        }
    }
}

fn run_report(event_arg: Option<String>) {
    let Some(event_arg) = event_arg else {
        eprintln!("shiibarctl report: missing <event> argument");
        return;
    };
    let event = match parse_event(&event_arg) {
        Some(e) => e,
        None => {
            eprintln!("shiibarctl report: unknown event '{event_arg}'");
            return;
        }
    };

    let mut raw_stdin = String::new();
    if let Err(e) = std::io::stdin().read_to_string(&mut raw_stdin) {
        eprintln!("shiibarctl report: failed to read stdin: {e}");
        return;
    }
    let raw: serde_json::Value = match serde_json::from_str(&raw_stdin) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("shiibarctl report: invalid hook JSON on stdin: {e}");
            return;
        }
    };

    // Target generation rule (§4.1): $ITERM_SESSION_ID verbatim, else
    // `session:<session_id>`.
    let iterm_session_id = std::env::var("ITERM_SESSION_ID").ok();
    let now = now_epoch_secs();

    let payload = match extract::build_report(event, &raw, iterm_session_id.as_deref(), now) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("shiibarctl report: {e}");
            return;
        }
    };

    // From here on, failures (no daemon, timeout, broken pipe, ...) are
    // expected/routine and must stay silent (§4.1: hooks must not be
    // disturbed by shiibard being absent).
    send_with_timeout(payload);
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

fn socket_path() -> PathBuf {
    let root = std::env::var_os("SHIIBAR_STATE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            let home = std::env::var_os("HOME")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("."));
            home.join(".local/state/shiibar")
        });
    root.join("shiibard.sock")
}

/// Best-effort, bounded to ~1s total (§9). Connecting to a Unix socket
/// either succeeds or fails near-instantly, so a real hang would only come
/// from a stalled daemon; run the attempt on a side thread and give up
/// (silently) once the deadline passes, regardless of outcome.
fn send_with_timeout(payload: ReportPayload) {
    let (tx, rx) = std::sync::mpsc::channel();
    let handle = std::thread::spawn(move || {
        let _ = tx.send(try_send(payload));
    });
    let _ = rx.recv_timeout(SEND_TIMEOUT);
    // Not joined on purpose: if try_send is still stuck past the deadline,
    // waiting on it would defeat the whole point of the timeout. The
    // process exits right after this call, tearing the thread down with it.
    drop(handle);
}

fn try_send(payload: ReportPayload) -> std::io::Result<()> {
    let mut stream = UnixStream::connect(socket_path())?;
    let line = codec::encode_line(&Request::Report(payload)).map_err(std::io::Error::other)?;
    stream.write_all(line.as_bytes())?;
    Ok(())
}
