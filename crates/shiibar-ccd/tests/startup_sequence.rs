//! Startup-sequence tests (DESIGN.md §4.2 Operations): if the socket path
//! already exists, the daemon probes it — a live response means another
//! daemon owns it (refuse to start, `AlreadyRunning`); no response means a
//! stale file from a crashed daemon (unlink and bind fresh). Also asserts
//! that a graceful shutdown unlinks the socket file (relied upon by the
//! stale-vs-live distinction, but previously never asserted directly).

mod support;

use shiibar_cc_proto::{InfoResponse, Request};
use shiibar_ccd::clock::SystemClock;
use shiibar_ccd::paths::StateDir;
use shiibar_ccd::server;
use std::sync::Arc;
use support::TestDaemon;

#[tokio::test]
async fn stale_socket_file_is_unlinked_and_bind_succeeds() {
    let dir = tempfile::tempdir().unwrap();
    let state_dir = StateDir::new(dir.path());
    state_dir.ensure().unwrap();

    // A bound-then-dropped listener leaves the socket file on disk with
    // nothing accepting behind it — exactly what a crashed daemon leaves.
    let sock_path = state_dir.socket();
    {
        let _stale = std::os::unix::net::UnixListener::bind(&sock_path).unwrap();
    }
    assert!(sock_path.exists(), "precondition: stale socket file exists");

    // Startup must probe, get no response, unlink, and bind fresh (§4.2) —
    // TestDaemon::start goes through the real server::bind.
    let daemon = TestDaemon::start(dir.path(), Arc::new(SystemClock)).await;
    let info: InfoResponse = daemon
        .request(&Request::Info)
        .await
        .expect("daemon bound over the stale socket must answer info");
    assert!(info.ok);

    daemon.shutdown_and_join().await;
}

#[tokio::test]
async fn second_bind_against_a_live_daemon_is_refused_and_leaves_it_running() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = TestDaemon::start(dir.path(), Arc::new(SystemClock)).await;

    // Second startup against the same state dir: the probe reaches the
    // live daemon, so bind must refuse with AlreadyRunning (§4.2).
    let state_dir = StateDir::new(dir.path());
    let err = server::bind(&state_dir)
        .await
        .expect_err("second bind must refuse while a live daemon owns the socket");
    assert!(
        err.downcast_ref::<server::AlreadyRunning>().is_some(),
        "expected AlreadyRunning, got: {err}"
    );

    // The refused attempt must not have disturbed the first daemon: its
    // socket file is still there and it still answers.
    assert!(daemon.sock_path.exists());
    let info: InfoResponse = daemon
        .request(&Request::Info)
        .await
        .expect("first daemon must still answer after a refused second bind");
    assert!(info.ok);

    daemon.shutdown_and_join().await;
}

#[tokio::test]
async fn graceful_shutdown_unlinks_the_socket_file() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = TestDaemon::start(dir.path(), Arc::new(SystemClock)).await;
    let sock_path = daemon.sock_path.clone();
    assert!(sock_path.exists(), "precondition: socket exists while serving");

    // shutdown_and_join waits for the accept loop to actually exit, which
    // is where the unlink happens (server::serve's exit path).
    daemon.shutdown_and_join().await;
    assert!(
        !sock_path.exists(),
        "graceful shutdown must unlink the socket file (a leftover file would \
         be indistinguishable from a crash on next startup)"
    );
}
