//! Shared harness for shiibar-ccd integration tests: spin up a real in-process
//! server bound to a temp state dir, and talk to it over real
//! `tokio::net::UnixStream` connections — exactly what `shiibar-cc` and a
//! subscriber do, just without spawning the compiled binaries.
#![allow(dead_code)]

use shiibar_ccd::clock::Clock;
use shiibar_ccd::core::Core;
use shiibar_ccd::logging::{Level, Logger};
use shiibar_ccd::paths::StateDir;
use shiibar_ccd::server;
use shiibar_cc_proto::{codec, Request, SubscribeEvent};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::Notify;
use tokio::task::JoinHandle;

pub struct TestDaemon {
    pub sock_path: PathBuf,
    pub core: Arc<Mutex<Core>>,
    shutdown: Arc<Notify>,
    serve_task: JoinHandle<()>,
}

impl TestDaemon {
    /// Start a real server bound inside `dir` (a temp `SHIIBAR_CC_STATE_DIR`).
    pub async fn start(dir: &std::path::Path, clock: Arc<dyn Clock>) -> Self {
        let state_dir = StateDir::new(dir);
        let listener = server::bind(&state_dir)
            .await
            .expect("bind should succeed in a fresh temp dir");
        let (events_tx, _rx) = tokio::sync::broadcast::channel(shiibar_ccd::core::BROADCAST_CAPACITY);
        let mut core = Core::load(&state_dir, clock, Logger::new(Level::Debug), events_tx)
            .expect("Core::load should succeed");
        core.sweep_stale(); // startup sweep, mirroring main.rs
        let core = Arc::new(Mutex::new(core));
        let shutdown = Arc::new(Notify::new());
        let sock_path = state_dir.socket();
        let serve_task = tokio::spawn(server::serve(
            listener,
            core.clone(),
            shutdown.clone(),
            sock_path.clone(),
        ));
        Self {
            sock_path,
            core,
            shutdown,
            serve_task,
        }
    }

    /// Send `{"cmd":"shutdown"}`, wait for the ack, and wait for the accept
    /// loop to actually exit (so a second daemon can safely bind the same
    /// socket path right after).
    pub async fn shutdown_and_join(self) {
        let _ack: serde_json::Value = self.request(&Request::Shutdown).await.expect("shutdown ack");
        let _ = tokio::time::timeout(Duration::from_secs(5), self.serve_task).await;
    }

    /// One-shot request/response over a fresh connection (list / info /
    /// remove / seen).
    pub async fn request<T: serde::de::DeserializeOwned>(&self, req: &Request) -> anyhow::Result<T> {
        let mut stream = UnixStream::connect(&self.sock_path).await?;
        let line = codec::encode_line(req)?;
        stream.write_all(line.as_bytes()).await?;
        let mut reader = BufReader::new(stream);
        let mut resp_line = String::new();
        reader.read_line(&mut resp_line).await?;
        Ok(codec::decode_line(&resp_line)?)
    }

    /// Send a `report` (fire-and-forget: write one line, then close).
    pub async fn report(&self, payload: shiibar_cc_proto::ReportPayload) {
        let mut stream = UnixStream::connect(&self.sock_path)
            .await
            .expect("connect for report");
        let line = codec::encode_line(&Request::Report(payload)).expect("encode report");
        stream.write_all(line.as_bytes()).await.expect("write report");
        // Drop closes the connection (EOF), as a real report client does.
    }

    /// Open a `subscribe` connection and return a cursor over its event
    /// stream. Ordering is read directly off the stream (no sleeping).
    pub async fn subscribe(&self) -> SubscribeCursor {
        let mut stream = UnixStream::connect(&self.sock_path)
            .await
            .expect("connect for subscribe");
        let line = codec::encode_line(&Request::Subscribe).expect("encode subscribe");
        stream.write_all(line.as_bytes()).await.expect("write subscribe");
        SubscribeCursor {
            reader: BufReader::new(stream),
        }
    }
}

pub struct SubscribeCursor {
    reader: BufReader<UnixStream>,
}

impl SubscribeCursor {
    /// Read the next event, failing the test (via panic) if none arrives
    /// within a generous bound — this is a safety net for a broken test,
    /// not a synchronization mechanism (§ no sleep-based sync).
    pub async fn next_event(&mut self) -> SubscribeEvent {
        let mut line = String::new();
        let n = tokio::time::timeout(Duration::from_secs(5), self.reader.read_line(&mut line))
            .await
            .expect("timed out waiting for a subscribe event")
            .expect("read_line failed");
        assert!(n > 0, "subscribe stream closed unexpectedly");
        codec::decode_line(&line).expect("valid SubscribeEvent line")
    }
}

/// Read one hand-written hook JSON fixture from the workspace `fixtures/`
/// directory.
pub fn load_fixture(name: &str) -> serde_json::Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../fixtures")
        .join(name);
    let contents = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("failed to read fixture {}: {e}", path.display()));
    serde_json::from_str(&contents).unwrap_or_else(|e| panic!("invalid JSON in {}: {e}", path.display()))
}
