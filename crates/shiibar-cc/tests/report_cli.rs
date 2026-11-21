//! `shiibar-cc report` contract tests (§4.4): always exits 0 (daemon
//! absent, malformed input, ...), and when a daemon *is* listening, the
//! bytes it sends are a valid `report` request with the right target, pid
//! and event (§4.1). The case where no ancestor has a controlling terminal
//! (every event but SessionEnd is dropped; SessionEnd is sent without a
//! target or pid) runs the report detached from the test runner: in a new
//! session with no pty, and orphaned so that its only ancestor is the
//! process tree root. Otherwise the walk would reach the test runner, whose
//! controlling terminal depends on how the tests were started.
//!
//! No shiibar-ccd here (out of scope for shiibar-cc, and unnecessary): a
//! minimal `std::os::unix::net::UnixListener` mock is enough to observe
//! what shiibar-cc actually writes to the socket.

use std::io::{Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::net::UnixListener;
use std::os::unix::process::CommandExt;
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

/// The terminal environment variables `shiibar-cc report` classifies on
/// (§4.1). The child never inherits the developer's own values: the test's
/// outcome must not depend on which terminal it happens to run in.
const TERMINAL_ENV_VARS: [&str; 3] = ["TERM_PROGRAM", "TERM_PROGRAM_VERSION", "ITERM_SESSION_ID"];

/// A pseudo-terminal whose slave becomes the child's controlling terminal,
/// so the report's ancestor walk (§4.1) finds a terminal at the report
/// process itself. Without it the outcome would depend on whether the test
/// runner has a controlling terminal (a CI runner has none).
struct Pty {
    master: OwnedFd,
    slave: OwnedFd,
}

impl Pty {
    fn open() -> Self {
        let mut master: libc::c_int = -1;
        let mut slave: libc::c_int = -1;
        // SAFETY: openpty writes two valid fds on success; the name, termios
        // and winsize arguments are optional and passed as null.
        let rc = unsafe {
            libc::openpty(
                &mut master,
                &mut slave,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        assert_eq!(rc, 0, "openpty failed: {}", std::io::Error::last_os_error());
        // SAFETY: both fds were just returned by openpty and are owned here.
        unsafe {
            Pty {
                master: OwnedFd::from_raw_fd(master),
                slave: OwnedFd::from_raw_fd(slave),
            }
        }
    }

    /// The slave's `/dev/ttysNNN` path, the form the report puts in
    /// `apple-terminal:` / `ghostty:` targets (§2).
    fn slave_path(&self) -> String {
        // SAFETY: ttyname returns a pointer to a static buffer (or null); it
        // is copied out immediately.
        let ptr = unsafe { libc::ttyname(self.slave.as_raw_fd()) };
        assert!(!ptr.is_null(), "ttyname failed");
        unsafe { std::ffi::CStr::from_ptr(ptr) }.to_str().unwrap().to_string()
    }
}

struct ReportRun {
    code: i32,
    elapsed: Duration,
    pid: u32,
}

/// Run `shiibar-cc report <event>` with `stdin_bytes` on stdin, the given
/// terminal environment variables (all others of `TERMINAL_ENV_VARS`
/// removed), and, when `pty` is given, that pty as the child's controlling
/// terminal (a new session acquiring it).
fn run_report(
    event: &str,
    stdin_bytes: &[u8],
    state_dir: &std::path::Path,
    env: &[(&str, &str)],
    pty: Option<&Pty>,
) -> ReportRun {
    let mut cmd = Command::new(bin());
    cmd.arg("report")
        .arg(event)
        .env("SHIIBAR_CC_STATE_DIR", state_dir)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    for name in TERMINAL_ENV_VARS {
        cmd.env_remove(name);
    }
    for (name, value) in env {
        cmd.env(name, value);
    }
    if let Some(pty) = pty {
        let slave = pty.slave.as_raw_fd();
        // SAFETY: only async-signal-safe calls (setsid, ioctl) run between
        // fork and exec.
        unsafe {
            cmd.pre_exec(move || {
                if libc::setsid() < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                if libc::ioctl(slave, libc::TIOCSCTTY as _, 0) < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
    }

    let start = Instant::now();
    let mut child = cmd.spawn().expect("spawn shiibar-cc");
    let pid = child.id();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(stdin_bytes)
        .expect("write stdin");
    let status = child.wait().expect("wait for shiibar-cc");
    ReportRun {
        code: status.code().unwrap_or(-1),
        elapsed: start.elapsed(),
        pid,
    }
}

/// Run `report` under a controlling terminal with a mock daemon listening,
/// and return the run plus everything the child wrote to the socket.
fn capture_report(event: &str, fixture: &str, env: &[(&str, &str)]) -> (ReportRun, String, String) {
    let dir = tempfile::tempdir().unwrap();
    let sock_path = dir.path().join("shiibar-ccd.sock");
    let listener = UnixListener::bind(&sock_path).unwrap();
    listener.set_nonblocking(true).unwrap();
    let pty = Pty::open();
    // Read before the run: the tty is revoked when the child, its session
    // leader, exits.
    let tty = pty.slave_path();

    let stdin = std::fs::read(fixture_path(fixture)).unwrap();
    let run = run_report(event, &stdin, dir.path(), env, Some(&pty));
    assert_eq!(run.code, 0);

    // The child has exited, so a connection it made is already queued; the
    // deadline only turns a missing connection into a failure, not a hang.
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut stream = loop {
        match listener.accept() {
            Ok((stream, _)) => break stream,
            Err(_) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(10)),
            Err(e) => panic!("report never connected to the socket: {e}"),
        }
    };
    stream.set_nonblocking(false).unwrap();
    let mut written = String::new();
    stream.read_to_string(&mut written).expect("read what the report wrote");
    drop(pty.master);
    (run, written, tty)
}

fn decode_single_report(written: &str) -> shiibar_cc_proto::ReportPayload {
    let lines: Vec<&str> = written.lines().collect();
    assert_eq!(lines.len(), 1, "exactly one NDJSON line expected, got {written:?}");
    let request: shiibar_cc_proto::Request =
        shiibar_cc_proto::codec::decode_line(lines[0]).expect("valid Request line");
    let shiibar_cc_proto::Request::Report(payload) = request else {
        panic!("expected a report request, got {request:?}");
    };
    payload
}

/// §4.1/§4.4: with a controlling terminal the report is built and sent
/// (as a `process:` target here); with no daemon listening, the send fails
/// silently and the command still exits 0 within the send timeout.
#[test]
fn exits_0_when_daemon_is_absent() {
    let dir = tempfile::tempdir().unwrap();
    let pty = Pty::open();
    let stdin = std::fs::read(fixture_path("session_start_startup.json")).unwrap();
    let run = run_report("SessionStart", &stdin, dir.path(), &[("TERM_PROGRAM", "vscode")], Some(&pty));
    assert_eq!(run.code, 0);
    assert!(
        run.elapsed < Duration::from_secs(3),
        "should give up around the 1s send timeout, took {:?}",
        run.elapsed
    );
}

#[test]
fn exits_0_on_malformed_stdin() {
    let dir = tempfile::tempdir().unwrap();
    let pty = Pty::open();
    let run = run_report("SessionStart", b"not json at all", dir.path(), &[], Some(&pty));
    assert_eq!(run.code, 0);
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
    let (run, written, _tty) = capture_report(
        "UserPromptSubmit",
        "user_prompt_submit.json",
        &[("TERM_PROGRAM", "iTerm.app"), ("ITERM_SESSION_ID", "w0t0p0:D2DA6A1F-TEST")],
    );
    let payload = decode_single_report(&written);
    // Target is the prefixed `iterm2:<UUID>` (§2/§4.1) — the UUID is the
    // `:`-onward half of $ITERM_SESSION_ID (not the whole string), so it
    // matches what iterm2_targets derives.
    assert_eq!(payload.target.as_deref(), Some("iterm2:D2DA6A1F-TEST"));
    assert_eq!(payload.event, shiibar_cc_proto::HookEvent::UserPromptSubmit);
    // The walk starts at the report process, which here owns the terminal.
    assert_eq!(payload.pid, Some(run.pid));
    // Values from the real captured fixture (fixtures/README.md).
    assert_eq!(
        payload.prompt.as_deref(),
        Some("Show me this project's file list with ls")
    );
    assert_eq!(payload.session_id, "f27c326c-213e-4728-a79c-f0f8f3afa0f2");
}

/// §4.1: a terminal that is not one of the supported three is tracked by
/// the pid of the process owning the terminal — one `process:` report line,
/// not a drop. An inherited `$ITERM_SESSION_ID` must not turn it into an
/// iTerm2 target (§7-1).
#[test]
fn unsupported_terminal_sends_one_process_report_line() {
    let (run, written, _tty) = capture_report(
        "SessionStart",
        "session_start_startup.json",
        &[("TERM_PROGRAM", "vscode"), ("ITERM_SESSION_ID", "w0t0p0:D2DA6A1F-TEST")],
    );
    let payload = decode_single_report(&written);
    assert_eq!(payload.target, Some(format!("process:{}", run.pid)));
    assert_eq!(payload.pid, Some(run.pid));
    assert_eq!(payload.event, shiibar_cc_proto::HookEvent::SessionStart);
}

#[test]
fn missing_term_program_sends_a_process_report() {
    let (run, written, _tty) = capture_report("SessionStart", "session_start_startup.json", &[]);
    let payload = decode_single_report(&written);
    assert_eq!(payload.target, Some(format!("process:{}", run.pid)));
    assert_eq!(payload.pid, Some(run.pid));
}

/// §4.1: iTerm.app without a usable `$ITERM_SESSION_ID` is no longer
/// dropped; it falls back to the `process:` target.
#[test]
fn iterm_without_a_usable_session_id_sends_a_process_report() {
    for env in [
        &[("TERM_PROGRAM", "iTerm.app")][..],
        &[("TERM_PROGRAM", "iTerm.app"), ("ITERM_SESSION_ID", "not-the-right-shape")][..],
    ] {
        let (run, written, _tty) = capture_report("SessionStart", "session_start_startup.json", env);
        let payload = decode_single_report(&written);
        assert_eq!(payload.target, Some(format!("process:{}", run.pid)), "env {env:?}");
    }
}

#[test]
fn apple_terminal_sends_the_controlling_tty_as_target() {
    let (run, written, tty) = capture_report(
        "SessionStart",
        "session_start_startup.json",
        &[("TERM_PROGRAM", "Apple_Terminal")],
    );
    let payload = decode_single_report(&written);
    assert_eq!(payload.target, Some(format!("apple-terminal:{tty}")));
    assert_eq!(payload.pid, Some(run.pid));
}

/// §4.1: Ghostty is keyed by tty only from 1.4.0 on (non-release builds
/// compare the part before `-` / `+`); older Ghostty falls back to `process:`.
#[test]
fn ghostty_sends_a_tty_target_only_from_the_minimum_version() {
    let (run, written, tty) = capture_report(
        "SessionStart",
        "session_start_startup.json",
        &[("TERM_PROGRAM", "ghostty"), ("TERM_PROGRAM_VERSION", "1.4.0-main+abc1234")],
    );
    let payload = decode_single_report(&written);
    assert_eq!(payload.target, Some(format!("ghostty:{tty}")));
    assert_eq!(payload.pid, Some(run.pid));

    let (run, written, _tty) = capture_report(
        "SessionStart",
        "session_start_startup.json",
        &[("TERM_PROGRAM", "ghostty"), ("TERM_PROGRAM_VERSION", "1.3.1")],
    );
    let payload = decode_single_report(&written);
    assert_eq!(payload.target, Some(format!("process:{}", run.pid)));
}

/// Run `shiibar-cc report <event>` with no controlling terminal anywhere up
/// its ancestry, the situation a SessionEnd hook is in after its terminal
/// window was closed: an intermediate `sh`, made a session leader with no
/// controlling terminal, starts the report in the background and exits, so
/// the report is orphaned to the process tree root (which has no
/// controlling terminal) before it reads stdin. The report only walks its
/// ancestry after stdin reaches EOF, so writing stdin after `sh` has exited
/// makes the outcome independent of the test runner's own terminal.
///
/// Returns everything the report wrote to the mock daemon's socket (empty
/// when it dropped the report).
fn capture_detached_report(event: &str, fixture: &str, env: &[(&str, &str)]) -> String {
    let dir = tempfile::tempdir().unwrap();
    let sock_path = dir.path().join("shiibar-ccd.sock");
    let listener = UnixListener::bind(&sock_path).unwrap();
    listener.set_nonblocking(true).unwrap();

    let mut cmd = Command::new("/bin/sh");
    // `<&0` keeps the pipe as the background job's stdin (a non-interactive
    // shell would otherwise give it /dev/null).
    cmd.arg("-c")
        .arg(r#""$0" report "$1" <&0 &"#)
        .arg(bin())
        .arg(event)
        .env("SHIIBAR_CC_STATE_DIR", dir.path())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    for name in TERMINAL_ENV_VARS {
        cmd.env_remove(name);
    }
    for (name, value) in env {
        cmd.env(name, value);
    }
    // SAFETY: only the async-signal-safe setsid runs between fork and exec.
    unsafe {
        cmd.pre_exec(|| {
            if libc::setsid() < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut shell = cmd.spawn().expect("spawn sh");
    let mut stdin = shell.stdin.take().unwrap();
    let mut stdout = shell.stdout.take().unwrap();
    let status = shell.wait().expect("wait for sh");
    assert!(status.success(), "sh failed: {status:?}");

    // `sh` has exited, so the report is now orphaned.
    stdin
        .write_all(&std::fs::read(fixture_path(fixture)).unwrap())
        .expect("write stdin");
    drop(stdin);
    // The report holds the other end of stdout; EOF means it has exited.
    let mut ignored = Vec::new();
    stdout.read_to_end(&mut ignored).expect("wait for the report to exit");

    match listener.accept() {
        Ok((mut stream, _)) => {
            stream.set_nonblocking(false).unwrap();
            let mut written = String::new();
            stream.read_to_string(&mut written).expect("read what the report wrote");
            written
        }
        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => String::new(),
        Err(e) => panic!("accept failed: {e}"),
    }
}

/// Every terminal environment the target classification distinguishes.
const DETACHED_ENVS: [&[(&str, &str)]; 5] = [
    &[("TERM_PROGRAM", "iTerm.app"), ("ITERM_SESSION_ID", "w0t0p0:D2DA6A1F-TEST")],
    &[("TERM_PROGRAM", "Apple_Terminal")],
    &[("TERM_PROGRAM", "ghostty"), ("TERM_PROGRAM_VERSION", "1.4.0")],
    &[("TERM_PROGRAM", "vscode")],
    &[],
];

/// A closed terminal window leaves the `claude` process without a
/// controlling terminal when its SessionEnd hook runs: the SessionEnd is
/// still sent, without a target or pid, whatever the environment claims,
/// so the daemon can remove the entry by session_id (§4.2).
#[test]
fn session_end_with_no_controlling_terminal_anywhere_sends_a_targetless_report() {
    for env in DETACHED_ENVS {
        let written = capture_detached_report("SessionEnd", "session_end.json", env);
        let payload = decode_single_report(&written);
        assert_eq!(payload.event, shiibar_cc_proto::HookEvent::SessionEnd, "env {env:?}");
        assert_eq!(payload.target, None, "env {env:?}");
        assert_eq!(payload.pid, None, "env {env:?}");
        assert_eq!(payload.session_id, "4aca25f3-dd52-4cf9-af50-6a5afe8da2f0", "env {env:?}");
        assert!(!written.contains("\"target\""), "target must be omitted, got {written:?}");
    }
}

/// §4.1/§8.66: every other event from a process with no controlling
/// terminal anywhere up its ancestry is dropped without touching the socket.
#[test]
fn other_events_with_no_controlling_terminal_anywhere_are_dropped() {
    for (event, fixture) in [
        ("SessionStart", "session_start_startup.json"),
        ("UserPromptSubmit", "user_prompt_submit.json"),
        ("Stop", "stop_no_background_tasks.json"),
    ] {
        for env in DETACHED_ENVS {
            let written = capture_detached_report(event, fixture, env);
            assert_eq!(written, "", "{event} env {env:?} must be dropped");
        }
    }
}
