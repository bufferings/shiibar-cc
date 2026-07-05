//! Exit codes shared by every subcommand except `report` (DESIGN.md §4.4:
//! `report` always exits 0, hooks must never see a "failure").

/// Success.
pub const OK: i32 = 0;
/// Connection / internal error, including "daemon absent" (reason on stderr).
pub const ERROR: i32 = 1;
/// No matching agent (for `wait`: the target was removed before matching,
/// DESIGN.md §4.4).
pub const NOT_FOUND: i32 = 2;
/// osascript Automation (TCC) permission denied.
pub const TCC_DENIED: i32 = 3;
/// `wait` timed out.
pub const TIMEOUT: i32 = 124;
