//! shiibar-ccd entrypoint: argument parsing and wiring only — behavior lives
//! in the library (see `lib.rs`).

use shiibar_ccd::clock::SystemClock;
use shiibar_ccd::core::Core;
use shiibar_ccd::logging::Logger;
use shiibar_ccd::paths::StateDir;
use shiibar_ccd::server::{self, AlreadyRunning};
use std::sync::{Arc, Mutex};

fn print_usage_and_exit() -> ! {
    eprintln!("usage: shiibar-ccd --foreground");
    std::process::exit(1);
}

#[tokio::main]
async fn main() {
    // `--foreground` is the only supported mode in M1 (no launchd /
    // self-daemonizing fork is in scope, §8.8) — accepted so the
    // documented invocation (`shiibar-ccd --foreground`) doesn't error, but
    // there is currently no other mode to contrast it with.
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.as_slice() {
        [] => {}
        [flag] if flag == "--foreground" => {}
        _ => print_usage_and_exit(),
    }

    let logger = Logger::from_env();
    let state_dir = match StateDir::from_env() {
        Ok(d) => d,
        Err(e) => {
            eprintln!("shiibar-ccd: {e}");
            std::process::exit(1);
        }
    };

    let listener = match server::bind(&state_dir).await {
        Ok(l) => l,
        Err(e) if e.downcast_ref::<AlreadyRunning>().is_some() => {
            eprintln!("shiibar-ccd: {e}");
            std::process::exit(1);
        }
        Err(e) => {
            eprintln!("shiibar-ccd: failed to start: {e}");
            std::process::exit(1);
        }
    };

    let (events_tx, _rx) = tokio::sync::broadcast::channel(shiibar_ccd::core::BROADCAST_CAPACITY);
    let core = match Core::load(&state_dir, Arc::new(SystemClock), logger.clone(), events_tx) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("shiibar-ccd: failed to load state: {e}");
            std::process::exit(1);
        }
    };
    let core = Arc::new(Mutex::new(core));

    // Sweep once at startup (§4.2), then every 60s (§9).
    core.lock().expect("core mutex poisoned").sweep_stale();

    let shutdown = Arc::new(tokio::sync::Notify::new());
    tokio::spawn(server::run_sweep_loop(core.clone(), shutdown.clone()));

    logger.info(format_args!("shiibar-ccd listening on {}", state_dir.socket().display()));
    server::serve(listener, core, shutdown, state_dir.socket()).await;
    logger.info(format_args!("shiibar-ccd shutting down"));
}
