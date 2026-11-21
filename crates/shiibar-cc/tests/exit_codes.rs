//! Black-box exit-code contract tests (DESIGN.md §4.4), against the real
//! compiled `shiibar-cc` and (where needed) a real `shiibar-ccd` subprocess:
//! "daemon absent" => 1 for every subcommand except `report` (`doctor` is
//! run through its library entry points, see below); `wait`'s
//! full 0/1/2/124 spread; selector resolution (exact match / `.` / no
//! match / ambiguous).
//!
//! `focus`'s 2/3 for a terminal target (no matching session / TCC denied)
//! are NOT tested here — they require injecting a fake `AppleScriptRunner`,
//! which only the library-level tests in `src/focus_cmd.rs` can do (this
//! binary always uses the real `osascript`, out of scope for automated
//! tests). A `process:` target is tested here: it is exit 2 before any
//! osascript would run (§4.4). Likewise `resume` is only exercised up to its
//! argument and cwd checks, which come before any osascript.

mod support;

use shiibar_cc::doctor_cmd::{
    DoctorReport, SpacesSettingReader, exit_code_for, run_doctor, run_doctor_checks,
};
use shiibar_cc_client::terminal::{AppleScriptOutput, AppleScriptRunner};
use shiibar_cc_proto::{HookEvent, NotificationType, ReconcileSession, SessionStartSource, Status};
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
fn seen_exits_1_when_daemon_absent() {
    let dir = tempdir();
    let out = shiibar_cc(dir.path(), &["seen", "some-target"]);
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

// `doctor` is exercised through its library entry points rather than the
// binary: the binary probes every supported terminal with the real
// `osascript` and reads the real `defaults` setting and `~/.claude`, which
// tests must never touch. The daemon side stays real (a `shiibar-ccd`
// subprocess on a temp state dir), so the exit code still reflects an actual
// connection attempt.

/// Answers every terminal probe as "not running", so no terminal is
/// contacted, and records the scripts it was given.
struct NotRunningScripts {
    scripts: std::cell::RefCell<Vec<String>>,
}

impl NotRunningScripts {
    fn new() -> Self {
        NotRunningScripts {
            scripts: std::cell::RefCell::new(Vec::new()),
        }
    }
}

impl AppleScriptRunner for NotRunningScripts {
    fn run(&self, script: &str) -> std::io::Result<AppleScriptOutput> {
        self.scripts.borrow_mut().push(script.to_string());
        Ok(AppleScriptOutput {
            success: true,
            stdout: "NOT_RUNNING\n".to_string(),
            stderr: String::new(),
        })
    }
}

/// Reports the Space-switch setting as on (the system default).
struct SpacesOn;

impl SpacesSettingReader for SpacesOn {
    fn read(&self) -> Option<String> {
        Some("1".to_string())
    }
}

/// Run doctor's human form and its `--json` form against `socket_path`,
/// with a settings file and PATH inside `dir`. Returns the human report and
/// the `--json` exit code.
fn run_doctor_both_forms(dir: &std::path::Path, socket_path: &std::path::Path) -> (DoctorReport, i32) {
    let settings_path = dir.join("settings.json");
    let runner = NotRunningScripts::new();
    let report = run_doctor(socket_path, &settings_path, None, &runner, &SpacesOn);
    let checks = run_doctor_checks(socket_path, &settings_path, None, &runner, &SpacesOn);
    assert!(
        !runner.scripts.borrow().is_empty(),
        "the terminal probes go through the injected runner"
    );
    (report, exit_code_for(&checks))
}

#[test]
fn doctor_exits_1_when_daemon_absent() {
    let dir = tempdir();
    let (report, json_code) = run_doctor_both_forms(dir.path(), &dir.path().join("shiibar-ccd.sock"));
    assert_eq!(report.exit_code, 1);
    assert_eq!(json_code, 1, "--json uses the same exit code (§4.4)");
    assert!(report.lines.iter().any(|l| l.starts_with("[fail]")), "{:?}", report.lines);
}

#[test]
fn doctor_exits_0_when_daemon_is_reachable() {
    let dir = tempdir();
    let daemon = TestDaemon::start(dir.path());
    let (report, json_code) = run_doctor_both_forms(dir.path(), &daemon.sock_path);
    assert_eq!(report.exit_code, 0, "{:?}", report.lines);
    assert_eq!(json_code, 0, "--json uses the same exit code (§4.4)");
    assert!(
        report.lines.iter().any(|l| l.starts_with("[ok]   daemon reachable")),
        "{:?}",
        report.lines
    );
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

#[test]
fn seen_exits_2_when_selector_matches_nothing() {
    let dir = tempdir();
    let daemon = TestDaemon::start(dir.path());
    let out = shiibar_cc(&daemon.state_dir, &["seen", "no-such-target"]);
    assert_eq!(out.code, 2);
}

#[test]
fn seen_succeeds_with_an_exact_target_selector() {
    let dir = tempdir();
    let daemon = TestDaemon::start(dir.path());
    let mut payload = report_payload(HookEvent::SessionStart, "t-seen", "/proj/f", 1);
    payload.source = Some(SessionStartSource::Startup);
    daemon.report(payload);
    std::thread::sleep(std::time::Duration::from_millis(100));

    let out = shiibar_cc(&daemon.state_dir, &["seen", "t-seen"]);
    assert_eq!(out.code, 0, "stderr={}", out.stderr);
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

// ---- `process:` targets (DESIGN.md §2/§4.4) ----

/// The stderr `focus` prints for a `process:` target (§4.4), as the
/// library defines it.
const PROCESS_TARGET_MESSAGE: &str = shiibar_cc::focus_cmd::PROCESS_TARGET_MESSAGE;

/// Register `target` with a SessionStart carrying `pid`, the way a hook in a
/// terminal shiibar can't drive reports it (§4.1).
fn register_process_session(daemon: &TestDaemon, target: &str, pid: u32, cwd: &str) {
    let mut payload = report_payload(HookEvent::SessionStart, target, cwd, 1);
    payload.source = Some(SessionStartSource::Startup);
    payload.pid = Some(pid);
    daemon.report(payload);
    std::thread::sleep(std::time::Duration::from_millis(100));
}

#[test]
fn focus_with_an_exact_process_target_is_exit_2_with_its_own_message() {
    // No daemon: an exact target never consults it (§4.4), and a
    // `process:` target is rejected before any osascript would run.
    let dir = tempdir();
    let out = shiibar_cc(dir.path(), &["focus", "process:48213"]);
    assert_eq!(out.code, 2, "stderr={}", out.stderr);
    assert_eq!(out.stderr.trim(), PROCESS_TARGET_MESSAGE);
    assert!(
        !out.stderr.contains("tab may be closed"),
        "must differ from the closed-tab message: {}",
        out.stderr
    );
}

#[test]
fn focus_dot_resolving_to_a_process_entry_is_exit_2_with_its_own_message() {
    let dir = tempdir();
    let daemon = TestDaemon::start(dir.path());
    let cwd = tempdir();
    // See `dot_selector_resolves_by_current_directory` for why the cwd is
    // canonicalized.
    let canonical_cwd = cwd.path().canonicalize().unwrap();
    register_process_session(&daemon, "process:48213", 48213, canonical_cwd.to_str().unwrap());

    let output = Command::new(env!("CARGO_BIN_EXE_shiibar-cc"))
        .args(["focus", "."])
        .current_dir(cwd.path())
        .env("SHIIBAR_CC_STATE_DIR", &daemon.state_dir)
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(output.status.code(), Some(2), "stderr={stderr}");
    assert_eq!(stderr.trim(), PROCESS_TARGET_MESSAGE);
}

#[test]
fn seen_works_on_a_process_target() {
    let dir = tempdir();
    let daemon = TestDaemon::start(dir.path());
    let mut payload = report_payload(HookEvent::Stop, "process:48213", "/proj/g", 1);
    payload.pid = Some(48213);
    daemon.report(payload);
    std::thread::sleep(std::time::Duration::from_millis(100));

    let before = shiibar_cc(&daemon.state_dir, &["list", "--json"]);
    let value: serde_json::Value = serde_json::from_str(before.stdout.trim()).unwrap();
    assert_eq!(value["agents"][0]["target"], "process:48213");
    assert_eq!(value["agents"][0]["unreviewed"], true, "a completed Stop raises the flag");

    let out = shiibar_cc(&daemon.state_dir, &["seen", "process:48213"]);
    assert_eq!(out.code, 0, "stderr={}", out.stderr);

    let after = shiibar_cc(&daemon.state_dir, &["list", "--json"]);
    let value: serde_json::Value = serde_json::from_str(after.stdout.trim()).unwrap();
    assert_eq!(value["agents"][0]["unreviewed"], false);
}

#[test]
fn remove_works_on_a_process_target() {
    let dir = tempdir();
    let daemon = TestDaemon::start(dir.path());
    register_process_session(&daemon, "process:48213", 48213, "/proj/h");

    let out = shiibar_cc(&daemon.state_dir, &["remove", "process:48213"]);
    assert_eq!(out.code, 0, "stderr={}", out.stderr);

    let list = shiibar_cc(&daemon.state_dir, &["list", "--json"]);
    let value: serde_json::Value = serde_json::from_str(list.stdout.trim()).unwrap();
    assert_eq!(value["agents"].as_array().unwrap().len(), 0);
}

#[test]
fn wait_works_on_a_process_target() {
    let dir = tempdir();
    let daemon = TestDaemon::start(dir.path());
    register_process_session(&daemon, "process:48213", 48213, "/proj/i");

    let out = shiibar_cc(
        &daemon.state_dir,
        &["wait", "process:48213", "--status", "idle", "--timeout", "5"],
    );
    assert_eq!(out.code, 0, "stderr={}", out.stderr);
}

#[test]
fn wait_on_the_old_target_ends_as_removed_when_the_entry_is_rekeyed() {
    // §3.6 "merging by pid": a complete reconcile that finds the session's
    // tty in a terminal scan rekeys the `process:` entry to the terminal
    // target. For a `wait` on the old target that is an `agent_removed`, so
    // it ends with exit 2 like any removal (§4.4).
    let dir = tempdir();
    let daemon = TestDaemon::start(dir.path());
    register_process_session(&daemon, "process:48213", 48213, "/proj/j");

    let out = std::thread::scope(|scope| {
        scope.spawn(|| {
            std::thread::sleep(std::time::Duration::from_millis(300));
            daemon.reconcile(
                true,
                vec![ReconcileSession {
                    target: "iterm2:REKEY-UUID".to_string(),
                    session_id: "sess-1".to_string(),
                    cwd: "/proj/j".to_string(),
                    status: Status::Idle,
                    waiting_for: None,
                    pid: Some(48213),
                    update_only: false,
                }],
            );
        });
        shiibar_cc(
            &daemon.state_dir,
            &["wait", "process:48213", "--status", "waiting", "--timeout", "5"],
        )
    });
    assert_eq!(out.code, 2, "stderr={}", out.stderr);

    // The entry lives on under the new target.
    let list = shiibar_cc(&daemon.state_dir, &["list", "--json"]);
    let value: serde_json::Value = serde_json::from_str(list.stdout.trim()).unwrap();
    let agents = value["agents"].as_array().unwrap();
    assert_eq!(agents.len(), 1);
    assert_eq!(agents[0]["target"], "iterm2:REKEY-UUID");
}

// ---- resume --terminal ghostty (DESIGN.md §4.4), up to the checks that
// precede any osascript ----

#[test]
fn resume_accepts_terminal_ghostty_and_checks_the_cwd_before_anything_else() {
    let dir = tempdir();
    let out = shiibar_cc(
        dir.path(),
        &["resume", "--cwd", "relative/path", "--terminal", "ghostty", "SESSION-1"],
    );
    assert_eq!(out.code, 1);
    assert!(
        out.stderr.contains("--cwd must be an absolute path"),
        "ghostty must be accepted as a --terminal value: {}",
        out.stderr
    );
}

#[test]
fn resume_usage_lists_ghostty() {
    let dir = tempdir();
    let out = shiibar_cc(dir.path(), &["resume"]);
    assert_eq!(out.code, 1);
    assert!(
        out.stderr
            .contains("usage: shiibar-cc resume --cwd <dir> [--terminal iterm2|apple-terminal|ghostty] [--fork] <session-id>"),
        "{}",
        out.stderr
    );
}
