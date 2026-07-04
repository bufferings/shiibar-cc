//! Black-box exit-code contract tests (DESIGN.md §4.4), against the real
//! compiled `shiibar-cc` and (where needed) a real `shiibar-ccd` subprocess:
//! "daemon absent" => 1 for every subcommand except `report`; `wait`'s
//! full 0/1/2/124 spread; selector resolution (exact match / `.` / no
//! match / ambiguous).
//!
//! `focus`'s 2/3 (no matching iTerm2 session / TCC denied) are NOT tested
//! here — they require injecting a fake `AppleScriptRunner`, which only
//! the library-level tests in `src/focus_cmd.rs` can do (this binary
//! always uses the real `osascript`, out of scope for automated tests).

mod support;

use shiibar_cc_proto::{HookEvent, NotificationType, SessionStartSource};
use std::process::{Command, Stdio};
use support::{TestDaemon, report_payload, shiibar_cc};

fn tempdir() -> tempfile::TempDir {
    tempfile::tempdir().unwrap()
}

// ---- daemon absent => exit 1, for every subcommand but `report` ----

#[test]
fn list_exits_1_when_daemon_absent() {
    let dir = tempdir();
    let out = shiibar_cc(dir.path(), &["list"]);
    assert_eq!(out.code, 1);
    assert!(!out.stderr.is_empty());
}

#[test]
fn watch_exits_1_when_daemon_absent() {
    let dir = tempdir();
    let out = shiibar_cc(dir.path(), &["watch"]);
    assert_eq!(out.code, 1);
}

#[test]
fn remove_exits_1_when_daemon_absent() {
    let dir = tempdir();
    let out = shiibar_cc(dir.path(), &["remove", "some-target"]);
    assert_eq!(out.code, 1);
}

#[test]
fn wait_exits_1_when_daemon_absent() {
    let dir = tempdir();
    let out = shiibar_cc(
        dir.path(),
        &["wait", "some-target", "--status", "waiting", "--timeout", "2"],
    );
    assert_eq!(out.code, 1);
}

#[test]
fn doctor_exits_1_when_daemon_absent() {
    let dir = tempdir();
    let out = shiibar_cc(dir.path(), &["doctor"]);
    assert_eq!(out.code, 1);
    assert!(out.stdout.contains("[fail]"));
}

#[test]
fn resume_exits_1_when_daemon_absent() {
    let dir = tempdir();
    let out = shiibar_cc(dir.path(), &["resume"]);
    assert_eq!(out.code, 1);
    assert!(!out.stderr.is_empty());
}

#[test]
fn doctor_exits_0_when_daemon_is_reachable() {
    let dir = tempdir();
    let daemon = TestDaemon::start(dir.path());
    let out = shiibar_cc(&daemon.state_dir, &["doctor"]);
    assert_eq!(out.code, 0, "stdout={} stderr={}", out.stdout, out.stderr);
    assert!(out.stdout.contains("[ok]   daemon reachable"));
}

// ---- wait: 0 / 2 / 124 (1 is covered above) ----

#[test]
fn wait_exits_0_when_already_in_the_wanted_status() {
    let dir = tempdir();
    let daemon = TestDaemon::start(dir.path());
    let mut payload = report_payload(HookEvent::Notification, "t-waiting", "/proj/a", 1);
    payload.notification_type = Some(NotificationType::PermissionPrompt);
    payload.message = Some("Bash: rm -rf /".to_string());
    daemon.report(payload);
    std::thread::sleep(std::time::Duration::from_millis(100));

    let out = shiibar_cc(
        &daemon.state_dir,
        &["wait", "t-waiting", "--status", "waiting", "--timeout", "5"],
    );
    assert_eq!(out.code, 0, "stderr={}", out.stderr);
}

#[test]
fn wait_exits_124_on_timeout() {
    let dir = tempdir();
    let daemon = TestDaemon::start(dir.path());
    let out = shiibar_cc(
        &daemon.state_dir,
        &[
            "wait",
            "never-appears",
            "--status",
            "waiting",
            "--timeout",
            "1",
        ],
    );
    assert_eq!(out.code, 124, "stderr={}", out.stderr);
}

#[test]
fn wait_exits_2_when_the_target_is_removed_while_waiting() {
    let dir = tempdir();
    let daemon = TestDaemon::start(dir.path());
    let mut payload = report_payload(HookEvent::SessionStart, "t-removed", "/proj/b", 1);
    payload.source = Some(SessionStartSource::Startup);
    daemon.report(payload);
    std::thread::sleep(std::time::Duration::from_millis(100));

    let out = std::thread::scope(|scope| {
        scope.spawn(|| {
            std::thread::sleep(std::time::Duration::from_millis(300));
            daemon.remove("t-removed");
        });
        shiibar_cc(
            &daemon.state_dir,
            &["wait", "t-removed", "--status", "waiting", "--timeout", "5"],
        )
    });
    assert_eq!(out.code, 2, "stderr={}", out.stderr);
}

// ---- selector resolution: exact / `.` / no match / ambiguous ----

#[test]
fn remove_exits_2_when_selector_matches_nothing() {
    let dir = tempdir();
    let daemon = TestDaemon::start(dir.path());
    let out = shiibar_cc(&daemon.state_dir, &["remove", "no-such-target"]);
    assert_eq!(out.code, 2);
}

#[test]
fn remove_succeeds_with_an_exact_target_selector() {
    let dir = tempdir();
    let daemon = TestDaemon::start(dir.path());
    let mut payload = report_payload(HookEvent::SessionStart, "t-exact", "/proj/c", 1);
    payload.source = Some(SessionStartSource::Startup);
    daemon.report(payload);
    std::thread::sleep(std::time::Duration::from_millis(100));

    let out = shiibar_cc(&daemon.state_dir, &["remove", "t-exact"]);
    assert_eq!(out.code, 0, "stderr={}", out.stderr);
}

#[test]
fn dot_selector_resolves_by_current_directory() {
    let dir = tempdir();
    let daemon = TestDaemon::start(dir.path());
    let cwd = tempdir();
    // Canonicalize: macOS's tempdir often lives under a symlinked prefix
    // (`/var` -> `/private/var`), and `std::env::current_dir()` inside the
    // spawned process reports the resolved path — so the `cwd` recorded
    // by a report must match that, or `.` resolution never matches (this
    // is purely a test-harness wrinkle; real hook `cwd` values and the
    // CLI's `current_dir()` are always consistent with each other).
    let canonical_cwd = cwd.path().canonicalize().unwrap();
    let mut payload = report_payload(
        HookEvent::SessionStart,
        "t-dot",
        canonical_cwd.to_str().unwrap(),
        1,
    );
    payload.source = Some(SessionStartSource::Startup);
    daemon.report(payload);
    std::thread::sleep(std::time::Duration::from_millis(100));

    let output = Command::new(env!("CARGO_BIN_EXE_shiibar-cc"))
        .args(["remove", "."])
        .current_dir(cwd.path())
        .env("SHIIBAR_CC_STATE_DIR", &daemon.state_dir)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .unwrap();
    assert_eq!(output.code(), Some(0));
}

#[test]
fn dot_selector_is_exit_1_when_ambiguous() {
    let dir = tempdir();
    let daemon = TestDaemon::start(dir.path());
    let cwd = tempdir();
    let canonical_cwd = cwd.path().canonicalize().unwrap();
    for (i, target) in ["t-a", "t-b"].iter().enumerate() {
        let mut payload = report_payload(
            HookEvent::SessionStart,
            target,
            canonical_cwd.to_str().unwrap(),
            1 + i as i64,
        );
        payload.source = Some(SessionStartSource::Startup);
        daemon.report(payload);
    }
    std::thread::sleep(std::time::Duration::from_millis(150));

    let output = Command::new(env!("CARGO_BIN_EXE_shiibar-cc"))
        .args(["remove", "."])
        .current_dir(cwd.path())
        .env("SHIIBAR_CC_STATE_DIR", &daemon.state_dir)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .unwrap();
    assert_eq!(output.code(), Some(1));
}

// ---- list ----

#[test]
fn list_json_forwards_the_wire_response() {
    let dir = tempdir();
    let daemon = TestDaemon::start(dir.path());
    let mut payload = report_payload(HookEvent::SessionStart, "t-json", "/proj/d", 1);
    payload.source = Some(SessionStartSource::Startup);
    daemon.report(payload);
    std::thread::sleep(std::time::Duration::from_millis(100));

    let out = shiibar_cc(&daemon.state_dir, &["list", "--json"]);
    assert_eq!(out.code, 0);
    let value: serde_json::Value = serde_json::from_str(out.stdout.trim()).expect("valid JSON");
    assert_eq!(value["ok"], true);
    assert_eq!(value["agents"][0]["target"], "t-json");
}

#[test]
fn list_text_form_shows_status_and_target() {
    let dir = tempdir();
    let daemon = TestDaemon::start(dir.path());
    let mut payload = report_payload(HookEvent::SessionStart, "t-text", "/proj/e", 1);
    payload.source = Some(SessionStartSource::Startup);
    daemon.report(payload);
    std::thread::sleep(std::time::Duration::from_millis(100));

    let out = shiibar_cc(&daemon.state_dir, &["list"]);
    assert_eq!(out.code, 0);
    assert!(out.stdout.contains("idle"));
    assert!(out.stdout.contains("t-text"));
}

// ---- resume: exit 2 (no candidates), against the real daemon ----
//
// `resume`'s success path (a candidate actually selected and `open_tab`
// invoked) needs a fake `AppleScriptRunner` + `SelectionRunner`, which only
// the library-level tests in `src/resume_cmd.rs` can inject (this binary
// always uses real `fzf`/`osascript`). What's testable black-box here is
// the "zero candidates" short-circuit, which returns before either is ever
// touched.

#[test]
fn resume_exits_2_when_there_is_no_session_history() {
    let dir = tempdir();
    let daemon = TestDaemon::start(dir.path());
    let out = shiibar_cc(&daemon.state_dir, &["resume"]);
    assert_eq!(out.code, 2, "stderr={}", out.stderr);
}

#[test]
fn resume_exits_2_when_every_known_session_is_currently_running() {
    let dir = tempdir();
    let daemon = TestDaemon::start(dir.path());
    let mut payload = report_payload(HookEvent::SessionStart, "t-running", "/proj/f", 1);
    payload.source = Some(SessionStartSource::Startup);
    daemon.report(payload);
    std::thread::sleep(std::time::Duration::from_millis(100));

    // SessionStart already wrote a `sessions.jsonl` line (§4.2 Operations),
    // so the still-running session is also a history entry — the case this
    // test exercises: a history entry whose session_id is currently running
    // must be excluded from `resume`'s candidates.

    let out = shiibar_cc(&daemon.state_dir, &["resume"]);
    assert_eq!(out.code, 2, "stderr={}", out.stderr);
}
