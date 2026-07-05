//! `shiibar-cc doctor` (DESIGN.md §4.4): checks socket connectivity / hooks
//! configuration / PATH / osascript TCC permission, and reports on all of
//! them (rather than stopping at the first failure — the whole point is
//! "which of these is broken?"). Every check target (socket path, the
//! `settings.json` path, the `PATH` search list, the AppleScript runner) is
//! an explicit parameter so this is fully unit-testable without touching
//! the real environment.
//!
//! Each check produces a [`CheckRecord`]; the human-readable text form and
//! `--json` (`{"checks":[...]}`, DESIGN.md §4.4 — read by the app's Setup
//! Check window, §4.5) are both derived from the same records, so the two
//! outputs can never drift from each other's judgement of ok/warn/fail.

use crate::exitcode;
use serde::{Serialize, Serializer};
use shiibar_cc_client::iterm::{AppleScriptRunner, ItermError, ProbeOutcome, probe};
use shiibar_cc_proto::{InfoResponse, Request};
use std::ffi::OsStr;
use std::path::Path;

pub struct DoctorReport {
    pub lines: Vec<String>,
    pub exit_code: i32,
}

/// ok / warn / fail per DESIGN.md §4.4's JSON schema. `Info` is an extra
/// internal state for the one line that isn't a problem at all (iTerm2
/// isn't running, so the TCC probe wasn't attempted) — the human text shows
/// a distinct `[info]` tag, but since the spec's JSON schema only has three
/// values it serializes the same as `Ok`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CheckStatus {
    Ok,
    Info,
    Warn,
    Fail,
}

impl CheckStatus {
    fn human_tag(self) -> &'static str {
        match self {
            CheckStatus::Ok => "[ok]  ",
            CheckStatus::Info => "[info]",
            CheckStatus::Warn => "[warn]",
            CheckStatus::Fail => "[fail]",
        }
    }

    fn json_str(self) -> &'static str {
        match self {
            CheckStatus::Ok | CheckStatus::Info => "ok",
            CheckStatus::Warn => "warn",
            CheckStatus::Fail => "fail",
        }
    }
}

impl Serialize for CheckStatus {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.json_str())
    }
}

/// One check's result. `hint` is a short actionable pointer split out of
/// the summary where the existing human text already embedded one
/// parenthetically (e.g. "start it with `shiibar-ccd --foreground`");
/// checks with nothing actionable to add (an `ok`, or an error with no
/// known fix) leave it `None`.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct CheckRecord {
    pub id: &'static str,
    pub status: CheckStatus,
    pub summary: String,
    pub hint: Option<String>,
}

impl CheckRecord {
    fn new(id: &'static str, status: CheckStatus, summary: String, hint: Option<&str>) -> Self {
        CheckRecord {
            id,
            status,
            summary,
            hint: hint.map(str::to_string),
        }
    }

    /// Reconstructs the original single-line human text: `[tag] summary
    /// (hint)`, or `[tag] summary` when there's no hint.
    fn line(&self) -> String {
        match &self.hint {
            Some(h) => format!("{} {} ({h})", self.status.human_tag(), self.summary),
            None => format!("{} {}", self.status.human_tag(), self.summary),
        }
    }
}

#[derive(Serialize)]
struct DoctorJson<'a> {
    checks: &'a [CheckRecord],
}

/// `{"checks":[...]}` per DESIGN.md §4.4.
pub fn checks_to_json(checks: &[CheckRecord]) -> String {
    serde_json::to_string(&DoctorJson { checks })
        .expect("CheckRecord serialization is infallible (plain strings/enums)")
}

/// Exit-code semantics are unchanged from before this was split into
/// records (DESIGN.md §4.4's common table: 1 = "connection / internal
/// error, including daemon absent"). Every other check is advisory: doctor's
/// job is to show every problem in one pass, not to gate on all of them.
/// `--json` uses the same rule (§4.4: "exit code の意味は人間向けと同じ").
pub fn exit_code_for(checks: &[CheckRecord]) -> i32 {
    let daemon_unreachable = checks
        .iter()
        .any(|c| c.id == "daemon" && c.status == CheckStatus::Fail);
    if daemon_unreachable {
        exitcode::ERROR
    } else {
        exitcode::OK
    }
}

pub fn run_doctor_checks(
    socket_path: &Path,
    settings_path: &Path,
    path_env: Option<&OsStr>,
    runner: &dyn AppleScriptRunner,
) -> Vec<CheckRecord> {
    let mut checks = Vec::new();

    match shiibar_cc_client::connection::request::<InfoResponse>(socket_path, &Request::Info) {
        Ok(info) => {
            checks.push(CheckRecord::new(
                "daemon",
                CheckStatus::Ok,
                format!(
                    "daemon reachable at {} (version {}, started_at {})",
                    socket_path.display(),
                    info.version,
                    info.started_at
                ),
                None,
            ));
            match info.last_report_at {
                Some(ts) => checks.push(CheckRecord::new(
                    "last_report",
                    CheckStatus::Ok,
                    format!("last report received at {ts}"),
                    None,
                )),
                None => checks.push(CheckRecord::new(
                    "last_report",
                    CheckStatus::Warn,
                    "daemon is up but has not received any report yet".to_string(),
                    None,
                )),
            }
        }
        Err(e) => {
            checks.push(CheckRecord::new(
                "daemon",
                CheckStatus::Fail,
                format!(
                    "daemon not reachable at {}: {e}",
                    socket_path.display()
                ),
                Some("start it with `shiibar-ccd --foreground`"),
            ));
        }
    }

    match hooks_plugin_enabled(settings_path) {
        Ok(true) => checks.push(CheckRecord::new(
            "hooks",
            CheckStatus::Ok,
            format!(
                "{HOOKS_PLUGIN_KEY} is enabled in {}",
                settings_path.display()
            ),
            None,
        )),
        Ok(false) => checks.push(CheckRecord::new(
            "hooks",
            CheckStatus::Warn,
            format!(
                "{HOOKS_PLUGIN_KEY} is not enabled in {}",
                settings_path.display()
            ),
            Some(
                "run `/plugin marketplace add bufferings/shiibar-cc` then \
                 `/plugin install shiibar-cc@shiibar-cc`",
            ),
        )),
        Err(e) => checks.push(CheckRecord::new(
            "hooks",
            CheckStatus::Warn,
            format!("could not read {}: {e}", settings_path.display()),
            None,
        )),
    }

    if shiibar_cc_on_path(path_env).is_some() {
        checks.push(CheckRecord::new(
            "path",
            CheckStatus::Ok,
            "shiibar-cc is on PATH".to_string(),
            None,
        ));
    } else {
        checks.push(CheckRecord::new(
            "path",
            CheckStatus::Warn,
            "shiibar-cc is not on PATH".to_string(),
            Some("plugin/hooks/report.sh needs it"),
        ));
    }

    match probe(runner) {
        Ok(ProbeOutcome::Granted) => checks.push(CheckRecord::new(
            "tcc",
            CheckStatus::Ok,
            "osascript can control iTerm2 (Automation permission granted)".to_string(),
            None,
        )),
        Ok(ProbeOutcome::NotRunning) => checks.push(CheckRecord::new(
            "tcc",
            CheckStatus::Info,
            "iTerm2 is not running; Automation permission not checked".to_string(),
            None,
        )),
        Err(ItermError::PermissionDenied) => checks.push(CheckRecord::new(
            "tcc",
            CheckStatus::Warn,
            "osascript Automation permission for iTerm2 is denied".to_string(),
            Some("System Settings > Privacy & Security > Automation"),
        )),
        Err(e) => checks.push(CheckRecord::new(
            "tcc",
            CheckStatus::Warn,
            format!("could not probe iTerm2: {e}"),
            None,
        )),
    }

    checks
}

pub fn run_doctor(
    socket_path: &Path,
    settings_path: &Path,
    path_env: Option<&OsStr>,
    runner: &dyn AppleScriptRunner,
) -> DoctorReport {
    let checks = run_doctor_checks(socket_path, settings_path, path_env, runner);
    let exit_code = exit_code_for(&checks);
    let lines = checks.iter().map(CheckRecord::line).collect();
    DoctorReport { lines, exit_code }
}

/// The key `enabledPlugins` uses for the hooks plugin: `<plugin>@<marketplace>`
/// (DESIGN.md §4.1/§4.4/§8.19; both names are `shiibar-cc`).
const HOOKS_PLUGIN_KEY: &str = "shiibar-cc@shiibar-cc";

/// Checks whether the shiibar-cc hooks plugin is enabled, per DESIGN.md
/// §4.4: `settings.json` parses as JSON and its `enabledPlugins` object has
/// `HOOKS_PLUGIN_KEY` set to `true`. A missing file, unparseable JSON, or a
/// missing `enabledPlugins` object are all folded into "not installed" —
/// doctor has no finer-grained hint to offer for any of those cases. A read
/// error on an existing file is kept distinct (`Err`): "settings.json is
/// unreadable" needs a different remedy than "run /plugin install".
fn hooks_plugin_enabled(settings_path: &Path) -> std::io::Result<bool> {
    if !settings_path.exists() {
        return Ok(false);
    }
    let content = std::fs::read_to_string(settings_path)?;
    let Ok(value) = serde_json::from_str::<serde_json::Value>(&content) else {
        return Ok(false);
    };
    Ok(value
        .get("enabledPlugins")
        .and_then(|plugins| plugins.get(HOOKS_PLUGIN_KEY))
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false))
}

fn shiibar_cc_on_path(path_env: Option<&OsStr>) -> Option<std::path::PathBuf> {
    let path_env = path_env?;
    std::env::split_paths(path_env)
        .map(|dir| dir.join("shiibar-cc"))
        .find(|p| p.is_file())
}

#[cfg(test)]
mod tests {
    use super::*;
    use shiibar_cc_client::iterm::AppleScriptOutput;

    struct FakeRunner {
        output: AppleScriptOutput,
    }

    impl AppleScriptRunner for FakeRunner {
        fn run(&self, _script: &str) -> std::io::Result<AppleScriptOutput> {
            Ok(self.output.clone())
        }
    }

    fn out(success: bool, stdout: &str, stderr: &str) -> AppleScriptOutput {
        AppleScriptOutput {
            success,
            stdout: stdout.to_string(),
            stderr: stderr.to_string(),
        }
    }

    #[test]
    fn daemon_absent_is_the_only_thing_that_sets_exit_code_1() {
        let dir = tempfile::tempdir().unwrap();
        let runner = FakeRunner {
            output: out(true, "NOT_RUNNING\n", ""),
        };
        let report = run_doctor(
            &dir.path().join("no-socket"),
            &dir.path().join("settings.json"),
            None,
            &runner,
        );
        assert_eq!(report.exit_code, exitcode::ERROR);
        assert!(report.lines.iter().any(|l| l.starts_with("[fail]")));
    }

    #[test]
    fn hooks_check_is_ok_only_when_the_plugin_key_is_true() {
        let dir = tempfile::tempdir().unwrap();
        let settings_path = dir.path().join("settings.json");
        std::fs::write(
            &settings_path,
            r#"{"enabledPlugins":{"shiibar-cc@shiibar-cc":true}}"#,
        )
        .unwrap();
        assert!(hooks_plugin_enabled(&settings_path).unwrap());
    }

    #[test]
    fn hooks_check_folds_every_not_installed_shape_into_the_same_result() {
        let dir = tempfile::tempdir().unwrap();

        // enabledPlugins present but the value is false.
        let disabled = dir.path().join("disabled.json");
        std::fs::write(
            &disabled,
            r#"{"enabledPlugins":{"shiibar-cc@shiibar-cc":false}}"#,
        )
        .unwrap();
        assert!(!hooks_plugin_enabled(&disabled).unwrap());

        // enabledPlugins present but missing our key.
        let other_plugin = dir.path().join("other-plugin.json");
        std::fs::write(&other_plugin, r#"{"enabledPlugins":{"some-other@mkt":true}}"#).unwrap();
        assert!(!hooks_plugin_enabled(&other_plugin).unwrap());

        // Valid JSON with no enabledPlugins object at all.
        let no_plugins_key = dir.path().join("no-plugins-key.json");
        std::fs::write(&no_plugins_key, r#"{"hooks":{}}"#).unwrap();
        assert!(!hooks_plugin_enabled(&no_plugins_key).unwrap());

        // Unparseable JSON.
        let invalid = dir.path().join("invalid.json");
        std::fs::write(&invalid, "not json").unwrap();
        assert!(!hooks_plugin_enabled(&invalid).unwrap());

        // File does not exist at all.
        let missing = dir.path().join("nope.json");
        assert!(!hooks_plugin_enabled(&missing).unwrap());
    }

    #[cfg(unix)]
    #[test]
    fn hooks_check_keeps_a_read_error_distinct_from_not_installed() {
        use std::os::unix::fs::PermissionsExt;

        let dir = tempfile::tempdir().unwrap();
        let unreadable = dir.path().join("unreadable.json");
        std::fs::write(&unreadable, r#"{"enabledPlugins":{}}"#).unwrap();
        std::fs::set_permissions(&unreadable, std::fs::Permissions::from_mode(0o000)).unwrap();

        assert!(hooks_plugin_enabled(&unreadable).is_err());
    }

    #[test]
    fn shiibar_cc_on_path_finds_an_executable_named_shiibar_cc() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("shiibar-cc"), "#!/bin/sh\n").unwrap();
        let path_env = std::env::join_paths([dir.path()]).unwrap();
        assert!(shiibar_cc_on_path(Some(&path_env)).is_some());

        let other_dir = tempfile::tempdir().unwrap();
        let other_path_env = std::env::join_paths([other_dir.path()]).unwrap();
        assert!(shiibar_cc_on_path(Some(&other_path_env)).is_none());
    }

    #[test]
    fn tcc_denied_probe_is_a_warning_not_a_failing_exit_code() {
        let dir = tempfile::tempdir().unwrap();
        let runner = FakeRunner {
            output: out(
                false,
                "",
                "Not authorized to send Apple events to iTerm2. (-1743)",
            ),
        };
        // Even with the daemon absent (exit 1) *and* TCC denied, doctor
        // still reports every line; only the daemon check moves the exit
        // code (§4.4 decision, see the M2 completion report).
        let report = run_doctor(
            &dir.path().join("no-socket"),
            &dir.path().join("settings.json"),
            None,
            &runner,
        );
        assert!(
            report
                .lines
                .iter()
                .any(|l| l.contains("Automation permission for iTerm2 is denied"))
        );
    }

    // ---- structured records / --json (DESIGN.md §4.4) ----

    #[test]
    fn human_line_reconstructs_summary_and_parenthetical_hint() {
        let denied = CheckRecord::new(
            "tcc",
            CheckStatus::Warn,
            "osascript Automation permission for iTerm2 is denied".to_string(),
            Some("System Settings > Privacy & Security > Automation"),
        );
        assert_eq!(
            denied.line(),
            "[warn] osascript Automation permission for iTerm2 is denied \
             (System Settings > Privacy & Security > Automation)"
        );

        let ok = CheckRecord::new(
            "path",
            CheckStatus::Ok,
            "shiibar-cc is on PATH".to_string(),
            None,
        );
        assert_eq!(ok.line(), "[ok]   shiibar-cc is on PATH");
    }

    #[test]
    fn info_status_serializes_as_ok_since_the_json_schema_has_no_fourth_value() {
        let record = CheckRecord::new(
            "tcc",
            CheckStatus::Info,
            "iTerm2 is not running; Automation permission not checked".to_string(),
            None,
        );
        let json = serde_json::to_string(&record).unwrap();
        assert!(json.contains(r#""status":"ok""#));
        // But the human tag stays distinct from a plain ok.
        assert!(record.line().starts_with("[info]"));
    }

    #[test]
    fn json_output_has_one_record_per_check_with_id_status_summary_hint() {
        let dir = tempfile::tempdir().unwrap();
        let runner = FakeRunner {
            output: out(true, "NOT_RUNNING\n", ""),
        };
        let checks = run_doctor_checks(
            &dir.path().join("no-socket"),
            &dir.path().join("settings.json"),
            None,
            &runner,
        );
        let json = checks_to_json(&checks);
        let value: serde_json::Value = serde_json::from_str(&json).unwrap();
        let array = value["checks"].as_array().unwrap();
        assert_eq!(array.len(), checks.len());

        let daemon = array
            .iter()
            .find(|c| c["id"] == "daemon")
            .expect("daemon check present");
        assert_eq!(daemon["status"], "fail");
        assert!(daemon["summary"].as_str().unwrap().contains("not reachable"));
        assert_eq!(
            daemon["hint"],
            "start it with `shiibar-ccd --foreground`"
        );

        let path_check = array
            .iter()
            .find(|c| c["id"] == "path")
            .expect("path check present");
        assert_eq!(path_check["status"], "warn");
        assert_eq!(path_check["hint"], "plugin/hooks/report.sh needs it");
    }

    #[test]
    fn json_exit_code_matches_human_exit_code() {
        let dir = tempfile::tempdir().unwrap();
        let runner = FakeRunner {
            output: out(true, "NOT_RUNNING\n", ""),
        };
        let checks = run_doctor_checks(
            &dir.path().join("no-socket"),
            &dir.path().join("settings.json"),
            None,
            &runner,
        );
        assert_eq!(exit_code_for(&checks), exitcode::ERROR);

        let report = run_doctor(
            &dir.path().join("no-socket"),
            &dir.path().join("settings.json"),
            None,
            &runner,
        );
        assert_eq!(report.exit_code, exit_code_for(&checks));
    }
}
