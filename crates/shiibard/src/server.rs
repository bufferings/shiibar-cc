//! Unix socket server: startup sequence (stale-socket / dup-instance
//! detection, §4.2 運用), the accept loop, and per-connection request
//! handling (§4.2 プロトコル契約).

use crate::core::{BroadcastEvent, Core, SWEEP_INTERVAL_SECS};
use crate::paths::StateDir;
use shiibar_proto::{codec, ErrorResponse, Request, SubscribeEvent};
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::Notify;

/// A live daemon already owns the socket (§4.2 起動シーケンス).
#[derive(Debug)]
pub struct AlreadyRunning;

impl std::fmt::Display for AlreadyRunning {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "shiibard is already running (existing daemon responded)")
    }
}

impl std::error::Error for AlreadyRunning {}

const PROBE_TIMEOUT: Duration = Duration::from_millis(500);

/// Startup sequence (§4.2): if the socket path exists, probe it. A real
/// response means another daemon is live -> refuse to start. No response
/// (connect failure or timeout) means it's a stale file from a crashed
/// daemon -> unlink and bind fresh.
pub async fn bind(state_dir: &StateDir) -> anyhow::Result<UnixListener> {
    state_dir.ensure()?;
    let sock_path = state_dir.socket();

    if sock_path.exists() {
        if probe_existing(&sock_path).await {
            return Err(AlreadyRunning.into());
        }
        std::fs::remove_file(&sock_path)?;
    }

    let listener = UnixListener::bind(&sock_path)?;
    Ok(listener)
}

async fn probe_existing(sock_path: &Path) -> bool {
    let Ok(Ok(mut stream)) = tokio::time::timeout(PROBE_TIMEOUT, UnixStream::connect(sock_path)).await
    else {
        return false;
    };
    if stream.write_all(b"{\"cmd\":\"info\"}\n").await.is_err() {
        return false;
    }
    let mut reader = BufReader::new(&mut stream);
    let mut line = String::new();
    matches!(
        tokio::time::timeout(PROBE_TIMEOUT, reader.read_line(&mut line)).await,
        Ok(Ok(n)) if n > 0
    )
}

/// Run the stale-entry sweep every `SWEEP_INTERVAL_SECS` (§9) until shutdown.
/// Callers should also sweep once explicitly at startup (§4.2).
pub async fn run_sweep_loop(core: Arc<Mutex<Core>>, shutdown: Arc<Notify>) {
    let mut interval = tokio::time::interval(Duration::from_secs(SWEEP_INTERVAL_SECS));
    loop {
        tokio::select! {
            _ = shutdown.notified() => return,
            _ = interval.tick() => {
                core.lock().expect("core mutex poisoned").sweep_stale();
            }
        }
    }
}

/// Accept loop. Returns once `shutdown` is notified (by a `shutdown`
/// request) and unlinks the socket file on the way out.
pub async fn serve(listener: UnixListener, core: Arc<Mutex<Core>>, shutdown: Arc<Notify>, sock_path: std::path::PathBuf) {
    loop {
        tokio::select! {
            _ = shutdown.notified() => break,
            accepted = listener.accept() => {
                match accepted {
                    Ok((stream, _addr)) => {
                        let core = core.clone();
                        let shutdown = shutdown.clone();
                        tokio::spawn(async move {
                            handle_connection(stream, core, shutdown).await;
                        });
                    }
                    Err(_) => continue,
                }
            }
        }
    }
    let _ = std::fs::remove_file(&sock_path);
}

async fn handle_connection(stream: UnixStream, core: Arc<Mutex<Core>>, shutdown: Arc<Notify>) {
    let (read_half, mut write_half) = stream.into_split();
    let mut reader = BufReader::new(read_half);
    let mut line = String::new();

    let n = match reader.read_line(&mut line).await {
        Ok(n) => n,
        Err(_) => return,
    };
    if n == 0 {
        // Peer connected and closed without sending anything: nothing to do.
        return;
    }

    let request: Request = match codec::decode_line(&line) {
        Ok(r) => r,
        Err(e) => {
            let resp = ErrorResponse::new(format!("invalid request: {e}"));
            if let Ok(out) = codec::encode_line(&resp) {
                let _ = write_half.write_all(out.as_bytes()).await;
            }
            return;
        }
    };

    match request {
        Request::Report(payload) => {
            core.lock().expect("core mutex poisoned").handle_report(payload);
            // No response (§4.2: fire-and-forget).
        }
        Request::List => {
            let resp = core.lock().expect("core mutex poisoned").handle_list();
            respond(&mut write_half, &resp).await;
        }
        Request::Sessions => {
            let resp = core.lock().expect("core mutex poisoned").handle_sessions();
            respond(&mut write_half, &resp).await;
        }
        Request::Info => {
            let resp = core.lock().expect("core mutex poisoned").handle_info();
            respond(&mut write_half, &resp).await;
        }
        Request::Remove { target } => {
            core.lock().expect("core mutex poisoned").handle_remove(&target);
            respond(&mut write_half, &shiibar_proto::AckResponse::default()).await;
        }
        Request::Seen { target } => {
            core.lock().expect("core mutex poisoned").handle_seen(&target);
            respond(&mut write_half, &shiibar_proto::AckResponse::default()).await;
        }
        Request::Shutdown => {
            respond(&mut write_half, &shiibar_proto::AckResponse::default()).await;
            shutdown.notify_waiters();
        }
        Request::Subscribe => {
            handle_subscribe(reader, write_half, core, shutdown).await;
        }
    }
}

async fn respond<T: serde::Serialize>(write_half: &mut tokio::net::unix::OwnedWriteHalf, resp: &T) {
    if let Ok(out) = codec::encode_line(resp) {
        let _ = write_half.write_all(out.as_bytes()).await;
    }
}

async fn handle_subscribe(
    mut reader: BufReader<tokio::net::unix::OwnedReadHalf>,
    mut write_half: tokio::net::unix::OwnedWriteHalf,
    core: Arc<Mutex<Core>>,
    shutdown: Arc<Notify>,
) {
    // Subscribe to live updates *before* reading the snapshot, so nothing
    // that lands between the two is missed (§4.2).
    let (snapshot, mut rx) = {
        let core = core.lock().expect("core mutex poisoned");
        (core.snapshot(), core.events_tx.subscribe())
    };

    let snapshot_event = SubscribeEvent::Snapshot { agents: snapshot };
    if !write_event(&mut write_half, &snapshot_event).await {
        return;
    }

    let mut discard = String::new();
    loop {
        tokio::select! {
            _ = shutdown.notified() => return,
            recv = rx.recv() => {
                match recv {
                    Ok(BroadcastEvent::StatusChanged(agent)) => {
                        if !write_event(&mut write_half, &SubscribeEvent::StatusChanged { agent }).await {
                            return;
                        }
                    }
                    Ok(BroadcastEvent::AgentRemoved { target }) => {
                        if !write_event(&mut write_half, &SubscribeEvent::AgentRemoved { target }).await {
                            return;
                        }
                    }
                    // Slow subscriber: bounded channel overflowed (§4.2).
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => return,
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => return,
                }
            }
            read = reader.read_line(&mut discard) => {
                match read {
                    Ok(0) | Err(_) => return, // peer disconnected
                    Ok(_) => { discard.clear(); } // subscribe connections are push-only; ignore stray input
                }
            }
        }
    }
}

async fn write_event(write_half: &mut tokio::net::unix::OwnedWriteHalf, event: &SubscribeEvent) -> bool {
    match codec::encode_line(event) {
        Ok(out) => write_half.write_all(out.as_bytes()).await.is_ok(),
        Err(_) => false,
    }
}
