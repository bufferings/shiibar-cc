//! shiibar-cc's command implementations, as a library: `main.rs` is a thin
//! wrapper (arg parsing + wiring the real `Osascript` runner + real env
//! paths), so integration tests can call these directly with injected
//! dependencies (fake `AppleScriptRunner`, temp socket/settings paths)
//! without spawning the compiled binary — required for exercising focus's
//! exit 2/3 without a real TCC-gated `osascript` (DESIGN.md / M2 task
//! brief).

pub mod conversations;
pub mod conversations_cmd;
pub mod doctor_cmd;
pub mod exitcode;
pub mod focus_cmd;
pub mod list_cmd;
pub mod reconcile_cmd;
pub mod remove_cmd;
pub mod report_cmd;
pub mod resume_cmd;
pub mod seen_cmd;
pub mod wait_cmd;
pub mod watch_cmd;
