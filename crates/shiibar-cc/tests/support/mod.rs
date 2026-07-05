//! Black-box test harness: spawn the real, compiled `shiibar-ccd` binary
//! bound to a temp `SHIIBAR_CC_STATE_DIR`, and drive real `shiibar-cc`
//! subcommands against it as subprocesses — exactly the exit-code contract
//! a user/script observes (DESIGN.md §4.4). `shiibar-ccd` is a dev-dependency
//! of this crate solely so Cargo builds it and exposes
//! `CARGO_BIN_EXE_shiibar-ccd` to these tests.
#![allow(dead_code)]

use shiibar_cc_proto::{Request, codec};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

/// `shiibar-ccd` is a *dependency* crate's binary, not this package's own —
/// unlike `CARGO_BIN_EXE_shiibar-cc` (used below), Cargo does not expose a
/// `CARGO_BIN_EXE_shiibar-ccd` env var for it (that guarantee only covers
/// binaries of the package currently being compiled). Both binaries land
/// in the same build output directory, though, so the sibling path next
/// to our own binary is reliable — except when `shiibar-cc`'s tests are
/// run in isolation before `shiibar-ccd` has ever been built, hence the
/// fallback build below.
fn shiibar_ccd_bin_path() -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_BIN_EXE_shiibar-cc"))
        .parent()
        .expect("CARGO_BIN_EXE_shiibar-cc has a parent dir")
        .to_path_buf();
    let bin = dir.join("shiibar-ccd");
    if !bin.exists() {
        let workspace_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .and_then(Path::parent)
            .expect("crates/shiibar-cc has a workspace root two levels up")
            .to_path_buf();
        let status = Command::new(env!("CARGO"))
            .args(["build", "-p", "shiibar-ccd", "--bin", "shiibar-ccd"])
            .current_dir(workspace_root)
            .status()
            .expect("failed to invoke cargo to build shiibar-ccd");
        assert!(
            status.success(),
            "cargo build -p shiibar-ccd --bin shiibar-ccd failed"
        );
    }
    bin
}

pub struct TestDaemon {
    pub state_dir: PathBuf,
    pub sock_path: PathBuf,
    child: Child,
}

impl TestDaemon {
    /// Spawn the real `shiibar-ccd --foreground` binary against a fresh temp
    /// dir, and wait for its socket to appear.
    pub fn start(state_dir: &Path) -> Self {
        let child = Command::new(shiibar_ccd_bin_path())
            .arg("--foreground")
            .env("SHIIBAR_CC_STATE_DIR", state_dir)
            .env("SHIIBAR_CC_LOG", "error")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn shiibar-ccd");

        let sock_path = state_dir.join("shiibar-ccd.sock");
        let deadline = Instant::now() + Duration::from_secs(5);
        while !sock_path.exists() {
            assert!(
                Instant::now() < deadline,
                "shiibar-ccd never created its socket"
            );
            std::thread::sleep(Duration::from_millis(10));
        }

        Self {
            state_dir: state_dir.to_path_buf(),
            sock_path,
            child,
        }
    }

    /// Send a raw `report` request directly to the socket (fire-and-forget,
    /// bypassing `shiibar-cc report`'s hook-JSON parsing — this harness
    /// just needs to put the daemon into a known state).
    pub fn report(&self, payload: shiibar_cc_proto::ReportPayload) {
        let mut stream = UnixStream::connect(&self.sock_path).expect("connect for report");
        let line = codec::encode_line(&Request::Report(payload)).expect("encode report");
        stream.write_all(line.as_bytes()).expect("write report");
    }

    pub fn remove(&self, target: &str) {
        let mut stream = UnixStream::connect(&self.sock_path).expect("connect for remove");
        let req = Request::Remove {
            target: target.to_string(),
        };
        let line = codec::encode_line(&req).expect("encode remove");
        stream.write_all(line.as_bytes()).expect("write remove");
        let mut reader = BufReader::new(stream);
        let mut resp = String::new();
        reader.read_line(&mut resp).expect("read remove ack");
    }
}

impl Drop for TestDaemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

pub fn report_payload(
    event: shiibar_cc_proto::HookEvent,
    target: &str,
    cwd: &str,
    ts: i64,
) -> shiibar_cc_proto::ReportPayload {
    shiibar_cc_proto::ReportPayload {
        event,
        target: target.to_string(),
        session_id: "sess-1".to_string(),
        cwd: cwd.to_string(),
        transcript_path: None,
        ts,
        source: None,
        notification_type: None,
        message: None,
        prompt: None,
        background_tasks: None,
        last_assistant_message: None,
    }
}

pub struct CliOutcome {
    pub code: i32,
    pub stdout: String,
    pub stderr: String,
}

/// Run the real `shiibar-cc` binary with `args`, pointed at `state_dir`.
pub fn shiibar_cc(state_dir: &Path, args: &[&str]) -> CliOutcome {
    let output = Command::new(env!("CARGO_BIN_EXE_shiibar-cc"))
        .args(args)
        .env("SHIIBAR_CC_STATE_DIR", state_dir)
        .output()
        .expect("spawn shiibar-cc");
    CliOutcome {
        code: output.status.code().unwrap_or(-1),
        stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
    }
}
