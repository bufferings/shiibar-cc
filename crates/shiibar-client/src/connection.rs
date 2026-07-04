//! Socket connection helpers: state dir / socket path resolution (mirrors
//! the M1 rule used by `shiibarctl report`) and a blocking one-shot
//! request/response round trip over the Unix socket, plus a `subscribe`
//! stream reader with an optional per-call deadline (used by `wait`).
//!
//! Every function that actually talks to the socket takes the socket path
//! as an explicit parameter rather than reading `SHIIBAR_STATE_DIR` itself.
//! This keeps them safe to unit-test in parallel (no process-wide env
//! mutation): callers resolve the path once (`resolve_socket_path`, which
//! *does* read the env var) and thread it through.

use serde::de::DeserializeOwned;
use shiibar_proto::{Request, SubscribeEvent, codec};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Instant;

/// Errors from talking to shiibard. Every variant maps to shiibarctl exit
/// code 1 ("connection / internal error, including daemon absent", DESIGN.md §4.4) unless a
/// caller specifically reinterprets it (e.g. `wait`'s timeout, which is
/// modeled as `Ok(WaitOutcome::TimedOut)`, not an error at all).
#[derive(Debug)]
pub enum ClientError {
    /// Couldn't even connect (daemon absent, stale/missing socket, ...).
    Connect(std::io::Error),
    /// Connected, but a later I/O operation failed.
    Io(std::io::Error),
    /// The daemon returned `{"ok":false,"error":...}`, or a line that
    /// doesn't decode as the type the caller expected.
    Protocol(String),
}

impl std::fmt::Display for ClientError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ClientError::Connect(e) => write!(f, "cannot connect to shiibard: {e}"),
            ClientError::Io(e) => write!(f, "connection to shiibard failed: {e}"),
            ClientError::Protocol(s) => write!(f, "{s}"),
        }
    }
}

impl std::error::Error for ClientError {}

/// Resolve the state directory root: `SHIIBAR_STATE_DIR` if set, else
/// `~/.local/state/shiibar` (same rule as M1's `shiibarctl report` and
/// shiibard's `StateDir::from_env`, DESIGN.md §2/§9).
pub fn resolve_state_dir() -> PathBuf {
    match std::env::var_os("SHIIBAR_STATE_DIR") {
        Some(v) => PathBuf::from(v),
        None => {
            let home = std::env::var_os("HOME")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("."));
            home.join(".local/state/shiibar")
        }
    }
}

pub fn resolve_socket_path() -> PathBuf {
    resolve_state_dir().join("shiibard.sock")
}

pub fn resolve_last_focus_path() -> PathBuf {
    resolve_state_dir().join("last_focus")
}

/// Connect to shiibard's socket at `socket_path`.
pub fn connect(socket_path: &Path) -> Result<UnixStream, ClientError> {
    UnixStream::connect(socket_path).map_err(ClientError::Connect)
}

/// One request, one response line, decoded as `T`. Not for `report`
/// (fire-and-forget, no response) or `subscribe` (streaming) — see
/// `Subscription` for the latter.
pub fn request<T: DeserializeOwned>(socket_path: &Path, req: &Request) -> Result<T, ClientError> {
    let line = request_raw(socket_path, req)?;
    let value: serde_json::Value = serde_json::from_str(line.trim_end())
        .map_err(|e| ClientError::Protocol(format!("invalid response from shiibard: {e}")))?;
    if value.get("ok").and_then(|v| v.as_bool()) == Some(false) {
        let msg = value
            .get("error")
            .and_then(|v| v.as_str())
            .unwrap_or("unknown error");
        return Err(ClientError::Protocol(format!(
            "shiibard returned an error: {msg}"
        )));
    }
    serde_json::from_value(value)
        .map_err(|e| ClientError::Protocol(format!("invalid response from shiibard: {e}")))
}

/// Same round trip as `request`, but hands back the raw response line
/// verbatim (used by `list --json`, which must forward the wire response
/// as-is, DESIGN.md §4.4).
pub fn request_raw(socket_path: &Path, req: &Request) -> Result<String, ClientError> {
    let mut stream = connect(socket_path)?;
    let line = codec::encode_line(req).map_err(|e| ClientError::Protocol(e.to_string()))?;
    stream.write_all(line.as_bytes()).map_err(ClientError::Io)?;
    let mut reader = BufReader::new(stream);
    let mut resp_line = String::new();
    let n = reader.read_line(&mut resp_line).map_err(ClientError::Io)?;
    if n == 0 {
        return Err(ClientError::Protocol(
            "shiibard closed the connection without a response".into(),
        ));
    }
    Ok(resp_line)
}

/// A held `subscribe` connection (DESIGN.md §4.2/§4.3): the first event is
/// always a snapshot, and callers pull further events one at a time.
pub struct Subscription {
    reader: BufReader<UnixStream>,
}

impl Subscription {
    pub fn open(socket_path: &Path) -> Result<Self, ClientError> {
        let mut stream = connect(socket_path)?;
        let line = codec::encode_line(&Request::Subscribe)
            .map_err(|e| ClientError::Protocol(e.to_string()))?;
        stream.write_all(line.as_bytes()).map_err(ClientError::Io)?;
        Ok(Self {
            reader: BufReader::new(stream),
        })
    }

    /// Read the next event. `deadline` of `None` blocks indefinitely;
    /// `Some(instant)` returns `Ok(None)` ("timed out") once it passes
    /// without a full line arriving.
    ///
    /// Assumes shiibard writes each NDJSON line in one `write_all` call
    /// (true today, and small enough that a local Unix socket delivers it
    /// as one chunk in practice) — so a read timeout never fires mid-line.
    pub fn next_event(
        &mut self,
        deadline: Option<Instant>,
    ) -> Result<Option<SubscribeEvent>, ClientError> {
        match deadline {
            Some(dl) => {
                let remaining = dl.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    return Ok(None);
                }
                self.reader
                    .get_ref()
                    .set_read_timeout(Some(remaining))
                    .map_err(ClientError::Io)?;
            }
            None => {
                self.reader
                    .get_ref()
                    .set_read_timeout(None)
                    .map_err(ClientError::Io)?;
            }
        }

        let mut line = String::new();
        match self.reader.read_line(&mut line) {
            Ok(0) => Err(ClientError::Protocol(
                "shiibard closed the subscribe connection".into(),
            )),
            Ok(_) => {
                let event = codec::decode_line(&line)
                    .map_err(|e| ClientError::Protocol(format!("invalid subscribe event: {e}")))?;
                Ok(Some(event))
            }
            Err(e)
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                Ok(None)
            }
            Err(e) => Err(ClientError::Io(e)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolve_socket_path_honors_state_dir_override() {
        // SAFETY: this test only reads the value back through the same
        // process-local env var it just set; it doesn't race other tests
        // over shared filesystem state (no test in this crate mutates
        // SHIIBAR_STATE_DIR concurrently with an assertion on it elsewhere
        // — this is the only test in this module).
        unsafe {
            std::env::set_var("SHIIBAR_STATE_DIR", "/tmp/shiibar-test-example");
        }
        assert_eq!(
            resolve_socket_path(),
            PathBuf::from("/tmp/shiibar-test-example/shiibard.sock")
        );
        unsafe {
            std::env::remove_var("SHIIBAR_STATE_DIR");
        }
    }
}
