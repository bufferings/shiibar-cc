//! `shiibar-cc doctor` (DESIGN.md §4.4): checks socket connectivity / hooks
//! configuration / PATH / osascript TCC permission, and reports on all of
//! them (rather than stopping at the first failure — the whole point is
//! "which of these is broken?"). Every check target (socket path, the
//! `settings.json` path, the `PATH` search list, the AppleScript runner) is
//! an explicit parameter so this is fully unit-testable without touching
//! the real environment.

use crate::exitcode;
use shiibar_cc_client::iterm::{AppleScriptRunner, ItermError, ProbeOutcome, probe};
use shiibar_cc_proto::{InfoResponse, Request};
use std::ffi::OsStr;
use std::path::Path;

pub struct DoctorReport {
    pub lines: Vec<String>,
    pub exit_code: i32,
}

pub fn run_doctor(
    socket_path: &Path,
    settings_path: &Path,
    path_env: Option<&OsStr>,
    runner: &dyn AppleScriptRunner,
) -> DoctorReport {
    let mut lines = Vec::new();
    // Daemon reachability is the one check that decides the exit code
    // (DESIGN.md §4.4's common exit-code table: 1 = "connection / internal
    // error, including daemon absent"). Every other check here is advisory: doctor's job
    // is to show every problem in one pass, not to gate on all of them.
    let mut exit_code = exitcode::OK;

    match shiibar_cc_client::connection::request::<InfoResponse>(socket_path, &Request::Info) {
        Ok(info) => {
            lines.push(format!(
                "[ok]   daemon reachable at {} (version {}, started_at {})",
                socket_path.display(),
                info.version,
                info.started_at
            ));
            match info.last_report_at {
                Some(ts) => lines.push(format!("[ok]   last report received at {ts}")),
                None => lines
                    .push("[warn] daemon is up but has not received any report yet".to_string()),
            }
        }
        Err(e) => {
            lines.push(format!(
                "[fail] daemon not reachable at {}: {e} (start it with `shiibar-ccd --foreground`)",
                socket_path.display()
            ));
            exit_code = exitcode::ERROR;
        }
    }

    match hooks_configured(settings_path) {
        Ok(true) => lines.push(format!(
            "[ok]   hooks configured in {}",
            settings_path.display()
        )),
        Ok(false) => lines.push(format!(
            "[warn] hooks not found in {} (see scripts/install.sh / hooks/settings-snippet.json)",
            settings_path.display()
        )),
        Err(e) => lines.push(format!(
            "[warn] could not read {}: {e}",
            settings_path.display()
        )),
    }

    if shiibar_cc_on_path(path_env).is_some() {
        lines.push("[ok]   shiibar-cc is on PATH".to_string());
    } else {
        lines.push("[warn] shiibar-cc is not on PATH (hooks/report.sh needs it)".to_string());
    }

    match probe(runner) {
        Ok(ProbeOutcome::Granted) => lines.push(
            "[ok]   osascript can control iTerm2 (Automation permission granted)".to_string(),
        ),
        Ok(ProbeOutcome::NotRunning) => lines
            .push("[info] iTerm2 is not running; Automation permission not checked".to_string()),
        Err(ItermError::PermissionDenied) => lines.push(
            "[warn] osascript Automation permission for iTerm2 is denied \
             (System Settings > Privacy & Security > Automation)"
                .to_string(),
        ),
        Err(e) => lines.push(format!("[warn] could not probe iTerm2: {e}")),
    }

    DoctorReport { lines, exit_code }
}

fn hooks_configured(settings_path: &Path) -> std::io::Result<bool> {
    if !settings_path.exists() {
        return Ok(false);
    }
    let content = std::fs::read_to_string(settings_path)?;
    Ok(content.contains("report.sh"))
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
    fn hooks_check_reads_the_given_settings_path() {
        let dir = tempfile::tempdir().unwrap();
        let settings_path = dir.path().join("settings.json");
        std::fs::write(
            &settings_path,
            r#"{"hooks":{"Stop":[{"hooks":[{"command":"report.sh Stop"}]}]}}"#,
        )
        .unwrap();
        assert!(hooks_configured(&settings_path).unwrap());

        let missing = dir.path().join("nope.json");
        assert!(!hooks_configured(&missing).unwrap());
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
}
