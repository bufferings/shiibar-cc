//! shiibar daemon: holds agent state and broadcasts events over a Unix
//! socket.
//!
//! Spec: docs/DESIGN.md §3 (state model), §4.2 (protocol, operations).
//!
//! Split into a lib + thin `main.rs` so integration tests (`tests/`) can
//! drive a real in-process server (bind a listener in a temp state dir,
//! connect real `tokio::net::UnixStream` clients) without spawning the
//! compiled binary.

pub mod clock;
pub mod core;
pub mod logging;
pub mod paths;
pub mod sessions;
pub mod server;
pub mod state;
pub mod transitions;
