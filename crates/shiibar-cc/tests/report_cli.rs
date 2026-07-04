//! `shiibar-cc report` contract tests (§4.4): always exits 0 (daemon
//! absent, malformed input, ...), and when a daemon *is* listening, the
//! bytes it sends are a valid `report` request with the right target/event.
//!
//! No shiibar-ccd here (out of scope for shiibar-cc, and unnecessary): a
//! minimal `std::os::unix::net::UnixListener` mock is enough to observe
//! what shiibar-cc actually writes to the socket.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

fn bin() -> &'static str {
    env!("CARGO_BIN_EXE_shiibar-cc")
}

fn fixture_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../fixtures")
        .join(name)
}

fn run_report(
    event: &str,
    stdin_bytes: &[u8],
    state_dir: &std::path::Path,
    iterm_session_id: Option<&str>,
) -> (i32, Duration) {
    let mut cmd = Command::new(bin());
    cmd.arg("report")
        .arg(event)
        .env("SHIIBAR_CC_STATE_DIR", state_dir)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    match iterm_session_id {
        Some(v) => cmd.env("ITERM_SESSION_ID", v),
        None => cmd.env_remove("ITERM_SESSION_ID"),
    };

    let start = Instant::now();
    let mut child = cmd.spawn().expect("spawn shiibar-cc");
    child
        .stdin
        .take()
        .unwrap()
        .write_all(stdin_bytes)
        .expect("write stdin");
    let status = child.wait().expect("wait for shiibar-cc");
    (status.code().unwrap_or(-1), start.elapsed())
}

#[test]
fn exits_0_when_daemon_is_absent() {
    let dir = tempfile::tempdir().unwrap();
    let stdin = std::fs::read(fixture_path("session_start_startup.json")).unwrap();
    let (code, elapsed) = run_report("SessionStart", &stdin, dir.path(), None);
    assert_eq!(code, 0);
    assert!(
        elapsed < Duration::from_secs(3),
        "should give up around the 1s send timeout, took {elapsed:?}"
    );
}

#[test]
fn exits_0_on_malformed_stdin() {
    let dir = tempfile::tempdir().unwrap();
    let (code, _) = run_report("SessionStart", b"not json at all", dir.path(), None);
    assert_eq!(code, 0);
}

#[test]
fn exits_0_when_event_argument_is_missing() {
    let dir = tempfile::tempdir().unwrap();
    let status = Command::new(bin())
        .arg("report")
        .env("SHIIBAR_CC_STATE_DIR", dir.path())
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .and_then(|mut c| {
            drop(c.stdin.take());
            c.wait()
        })
        .unwrap();
    assert_eq!(status.code(), Some(0));
}

#[test]
fn other_subcommands_exit_nonzero_when_the_daemon_is_absent() {
    // `list` is implemented (M2), but with no daemon listening at
    // SHIIBAR_CC_STATE_DIR it must exit 1 (§4.4: "connection / internal error,
    // including daemon absent") rather than 0 — `report`'s always-exit-0
    // rule is the one deliberate exception (§4.4).
    let dir = tempfile::tempdir().unwrap();
    let status = Command::new(bin())
        .arg("list")
        .env("SHIIBAR_CC_STATE_DIR", dir.path())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .unwrap();
    assert_ne!(status.code(), Some(0));
}

#[test]
fn delivers_a_valid_report_request_with_target_from_iterm_session_id() {
    let dir = tempfile::tempdir().unwrap();
    let sock_path = dir.path().join("shiibar-ccd.sock");
    let listener = UnixListener::bind(&sock_path).unwrap();

    let accept_thread = std::thread::spawn(move || {
        let (stream, _) = listener.accept().expect("accept one connection");
        let mut reader = BufReader::new(stream);
        let mut line = String::new();
        reader.read_line(&mut line).expect("read line");
        line
    });

    let stdin = std::fs::read(fixture_path("user_prompt_submit.json")).unwrap();
    let (code, _) = run_report(
        "UserPromptSubmit",
        &stdin,
        dir.path(),
        Some("w0t0p0:D2DA6A1F-TEST"),
    );
    assert_eq!(code, 0);

    let line = accept_thread.join().expect("mock listener thread panicked");
    let request: shiibar_cc_proto::Request =
        shiibar_cc_proto::codec::decode_line(&line).expect("valid Request line");
    let shiibar_cc_proto::Request::Report(payload) = request else {
        panic!("expected a report request, got {request:?}");
    };
    // Target is the bare UUID half only (§2/§4.1) — not the whole
    // $ITERM_SESSION_ID string, so it matches what iterm_targets derives.
    assert_eq!(payload.target, "D2DA6A1F-TEST");
    assert_eq!(payload.event, shiibar_cc_proto::HookEvent::UserPromptSubmit);
    assert_eq!(
        payload.prompt.as_deref(),
        Some("Implement the focus AppleScript")
    );
    assert_eq!(payload.session_id, "11111111-1111-1111-1111-111111111111");
}

/// §8.11: outside iTerm2 (no `$ITERM_SESSION_ID`), there is no fallback
/// target — the report is dropped before ever touching the socket. Still
/// exits 0 (this command's always-succeed contract, §4.4).
#[test]
fn drops_the_report_without_connecting_when_there_is_no_iterm_session_id() {
    let dir = tempfile::tempdir().unwrap();
    let sock_path = dir.path().join("shiibar-ccd.sock");
    let listener = UnixListener::bind(&sock_path).unwrap();
    listener.set_nonblocking(true).unwrap();

    let stdin = std::fs::read(fixture_path("session_start_startup.json")).unwrap();
    let (code, _) = run_report("SessionStart", &stdin, dir.path(), None);
    assert_eq!(code, 0);

    // Bounded, but generous, window to prove a connection *never* arrives —
    // not a synchronization mechanism, just there to catch a regression
    // reliably rather than racing the child process.
    let deadline = Instant::now() + Duration::from_millis(500);
    let mut connected = false;
    while Instant::now() < deadline {
        if listener.accept().is_ok() {
            connected = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(!connected, "a dropped report must never connect to the socket at all");
}

/// Same drop rule, but for an `$ITERM_SESSION_ID` that doesn't contain the
/// documented `wNtNpN:UUID` `:` separator at all — treated the same as
/// absent rather than guessed at (§4.1).
#[test]
fn drops_the_report_when_iterm_session_id_has_no_colon() {
    let dir = tempfile::tempdir().unwrap();
    let stdin = std::fs::read(fixture_path("session_start_startup.json")).unwrap();
    let (code, _) = run_report("SessionStart", &stdin, dir.path(), Some("not-the-right-shape"));
    assert_eq!(code, 0);
}
