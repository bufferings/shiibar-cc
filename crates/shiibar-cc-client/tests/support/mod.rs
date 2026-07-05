//! Minimal test-only harness: a real in-process shiibar-ccd bound to a temp
//! `SHIIBAR_CC_STATE_DIR`, run on its own OS thread with its own tokio
//! runtime, driven from the (synchronous) test thread over real
//! `std::os::unix::net::UnixStream` connections — i.e. exactly what
//! `shiibar-cc-client`'s blocking client code does. This lets `wait`'s
//! integration tests exercise the real M1 daemon rather than a mock
//! (DESIGN.md / M2 task brief: "the daemon should be the real M1 binary or
//! library, started against a temp SHIIBAR_CC_STATE_DIR, for integration
//! testing").
#![allow(dead_code)]

use shiibar_cc_proto::codec;
use shiibar_ccd::clock::SystemClock;
use shiibar_ccd::core::Core;
use shiibar_ccd::logging::{Level, Logger};
use shiibar_ccd::paths::StateDir;
use shiibar_ccd::server;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub struct TestDaemon {
    pub sock_path: PathBuf,
    _dir: tempfile::TempDir,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl TestDaemon {
    /// Start a real server bound inside a fresh temp dir.
    pub fn start() -> Self {
        let dir = tempfile::tempdir().expect("tempdir");
        let state_dir = StateDir::new(dir.path());
        let sock_path = state_dir.socket();

        let thread = std::thread::spawn(move || {
            let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
            rt.block_on(async move {
                let listener = server::bind(&state_dir)
                    .await
                    .expect("bind should succeed in a fresh temp dir");
                let (events_tx, _rx) =
                    tokio::sync::broadcast::channel(shiibar_ccd::core::BROADCAST_CAPACITY);
                let mut core = Core::load(
                    &state_dir,
                    Arc::new(SystemClock),
                    Logger::new(Level::Debug),
                    events_tx,
                )
                .expect("Core::load should succeed");
                core.sweep_stale();
                let core = Arc::new(Mutex::new(core));
                let shutdown = Arc::new(tokio::sync::Notify::new());
                let sock = state_dir.socket();
                server::serve(listener, core, shutdown, sock).await;
            });
        });

        // Wait for the socket file to show up (bind happens early in the
        // spawned thread's async block, well before this busy-wait would
        // ever time out in practice).
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while !sock_path.exists() {
            assert!(
                std::time::Instant::now() < deadline,
                "daemon never created its socket"
            );
            std::thread::sleep(Duration::from_millis(5));
        }

        Self {
            sock_path,
            _dir: dir,
            thread: Some(thread),
        }
    }

    /// Send a `report` (fire-and-forget: write one line, then close).
    pub fn report(&self, payload: shiibar_cc_proto::ReportPayload) {
        let mut stream = UnixStream::connect(&self.sock_path).expect("connect for report");
        let line =
            codec::encode_line(&shiibar_cc_proto::Request::Report(payload)).expect("encode report");
        stream.write_all(line.as_bytes()).expect("write report");
    }

    /// Send `{"cmd":"remove","target":...}` and wait for the ack.
    pub fn remove(&self, target: &str) {
        let mut stream = UnixStream::connect(&self.sock_path).expect("connect for remove");
        let req = shiibar_cc_proto::Request::Remove {
            target: target.to_string(),
        };
        let line = codec::encode_line(&req).expect("encode remove");
        stream.write_all(line.as_bytes()).expect("write remove");
        let mut reader = BufReader::new(stream);
        let mut resp = String::new();
        reader.read_line(&mut resp).expect("read remove ack");
    }

    /// Send `{"cmd":"shutdown"}`, wait for the ack, and join the daemon
    /// thread so a subsequent test can safely reuse the port/dir space.
    pub fn shutdown(mut self) {
        if let Ok(mut stream) = UnixStream::connect(&self.sock_path) {
            let line =
                codec::encode_line(&shiibar_cc_proto::Request::Shutdown).expect("encode shutdown");
            let _ = stream.write_all(line.as_bytes());
            let mut reader = BufReader::new(stream);
            let mut resp = String::new();
            let _ = reader.read_line(&mut resp);
        }
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

/// Build a minimal `ReportPayload` for test scenarios (only the fields the
/// state machine actually branches on need to be set per-call).
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
