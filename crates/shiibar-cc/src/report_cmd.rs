//! `shiibar-cc report <event>` (DESIGN.md §4.1/§4.4).

use shiibar_cc_proto::extract::ProcInfo;
use shiibar_cc_proto::{HookEvent, ReportPayload, Request, codec, extract};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// hooks send timeout (§9).
const SEND_TIMEOUT: Duration = Duration::from_secs(1);

/// Always succeeds from the caller's point of view: `report` is the sole
/// exception to the normal exit-code rules (§4.4) and must exit 0 no
/// matter what (daemon absent, malformed input, timeout, ...) so hooks are
/// never blocked or shown a hook "failure".
pub fn run(event_arg: Option<String>, socket_path: &Path) {
    let Some(event_arg) = event_arg else {
        eprintln!("shiibar-cc report: missing <event> argument");
        return;
    };
    let event = match parse_event(&event_arg) {
        Some(e) => e,
        None => {
            eprintln!("shiibar-cc report: unknown event '{event_arg}'");
            return;
        }
    };

    let mut raw_stdin = String::new();
    if let Err(e) = std::io::stdin().read_to_string(&mut raw_stdin) {
        eprintln!("shiibar-cc report: failed to read stdin: {e}");
        return;
    }
    let raw: serde_json::Value = match serde_json::from_str(&raw_stdin) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("shiibar-cc report: invalid hook JSON on stdin: {e}");
            return;
        }
    };

    // Target generation (§4.1): every report first walks the process
    // ancestry for the first process with a controlling terminal (the
    // `claude` process running the session) — whatever $TERM_PROGRAM says,
    // iTerm.app included. Its pid goes on every report; its tty keys the
    // Terminal.app and Ghostty targets. If the walk finds no terminal within
    // its limit (§9) the session has none and isn't tracked (§8.66):
    // build_report signals that with `Ok(None)`, and the report is dropped
    // without touching the socket (still exit 0, per this command's
    // always-succeed contract). The one exception is SessionEnd: a closed
    // terminal window leaves the `claude` process without a controlling
    // terminal by the time its SessionEnd hook runs, so build_report returns
    // it without a target or pid and it is sent for the daemon to match by
    // session_id (§4.2). This is the only place these env vars are read; the
    // classification rule itself lives entirely in build_report.
    let term_program = std::env::var("TERM_PROGRAM").ok();
    let term_program_version = std::env::var("TERM_PROGRAM_VERSION").ok();
    let iterm_session_id = std::env::var("ITERM_SESSION_ID").ok();
    let env = extract::HookEnv {
        term_program: term_program.as_deref(),
        term_program_version: term_program_version.as_deref(),
        iterm_session_id: iterm_session_id.as_deref(),
    };
    let controlling = resolve_controlling_process();
    let now = now_epoch_secs();

    let payload = match extract::build_report(event, &raw, &env, controlling.as_ref(), now) {
        Ok(Some(p)) => p,
        // No controlling terminal up the ancestry, on an event other than
        // SessionEnd: drop (§4.1/§8.66).
        Ok(None) => return,
        Err(e) => {
            eprintln!("shiibar-cc report: {e}");
            return;
        }
    };

    // From here on, failures (no daemon, timeout, broken pipe, ...) are
    // expected/routine and must stay silent (§4.1: hooks must not be
    // disturbed by shiibar-ccd being absent).
    send_with_timeout(payload, socket_path.to_path_buf());
}

fn parse_event(s: &str) -> Option<HookEvent> {
    serde_json::from_value(serde_json::Value::String(s.to_string())).ok()
}

fn now_epoch_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Find the process this hook runs under (§4.1): walk from this process
/// toward the tree root and take the first process that has a controlling
/// terminal (the hook process and `report.sh`'s shell are detached from it —
/// `??` in `ps`). The per-process lookup is `proc_pidinfo(PROC_PIDTBSDINFO)`
/// (libproc): a single in-process syscall per hop that yields both the
/// parent pid and the controlling tty device, so the walk stays inside the
/// hooks' 1-second budget (§4.1) with no `ps` subprocess. `None` means no
/// controlling terminal was found within the walk's limit — the report is
/// then dropped (§4.1/§8.66), except a SessionEnd, which is sent without a
/// target or pid.
fn resolve_controlling_process() -> Option<extract::ControllingProcess> {
    extract::controlling_process_from_ancestor_walk(std::process::id() as i32, proc_info)
}

/// One process's parent pid + controlling tty path via
/// `proc_pidinfo(PROC_PIDTBSDINFO)`. Impure (inspects the live process
/// table); the pure walk that drives it (`controlling_process_from_ancestor_walk`) is what
/// the unit tests exercise. Returns `None` if the pid can't be inspected
/// (exited, or not permitted).
fn proc_info(pid: i32) -> Option<ProcInfo> {
    // SAFETY: `proc_pidinfo` fills a caller-owned, correctly sized
    // `proc_bsdinfo`; we check its return equals the struct size before
    // reading any field, and only read plain integer fields.
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_bsdinfo>() as libc::c_int;
    let written = unsafe {
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDTBSDINFO,
            0,
            &mut info as *mut _ as *mut libc::c_void,
            size,
        )
    };
    if written != size {
        return None;
    }
    Some(ProcInfo {
        ppid: info.pbi_ppid as i32,
        tty: tty_path_for_dev(info.e_tdev),
    })
}

/// `NODEV` (`(dev_t)-1`) as the unsigned `e_tdev` field carries it: a
/// process with no controlling terminal.
const NODEV_U32: u32 = u32::MAX;

/// Turn a controlling-tty device number into its `/dev/ttysNNN` path
/// (§2/§7-7) via `devname(3)`, or `None` when the process has no controlling
/// terminal. AppleScript's `tty of tab` reports this same `/dev/ttysNNN`
/// form, so the two sides match without further normalization (§7-7).
fn tty_path_for_dev(e_tdev: u32) -> Option<String> {
    if e_tdev == NODEV_U32 {
        return None;
    }
    // SAFETY: `devname` returns a pointer into a static buffer (or null); we
    // copy it out immediately into an owned CStr/String and never retain the
    // raw pointer.
    let name_ptr = unsafe { libc::devname(e_tdev as libc::dev_t, libc::S_IFCHR) };
    if name_ptr.is_null() {
        return None;
    }
    let name = unsafe { std::ffi::CStr::from_ptr(name_ptr) }
        .to_str()
        .ok()?;
    if name.is_empty() || name == "??" {
        return None;
    }
    Some(format!("/dev/{name}"))
}

/// Best-effort, bounded to ~1s total (§9). Connecting to a Unix socket
/// either succeeds or fails near-instantly, so a real hang would only come
/// from a stalled daemon; run the attempt on a side thread and give up
/// (silently) once the deadline passes, regardless of outcome.
fn send_with_timeout(payload: ReportPayload, socket_path: std::path::PathBuf) {
    let (tx, rx) = std::sync::mpsc::channel();
    let handle = std::thread::spawn(move || {
        let _ = tx.send(try_send(payload, &socket_path));
    });
    let _ = rx.recv_timeout(SEND_TIMEOUT);
    // Not joined on purpose: if try_send is still stuck past the deadline,
    // waiting on it would defeat the whole point of the timeout. The
    // process exits right after this call, tearing the thread down with it.
    drop(handle);
}

fn try_send(payload: ReportPayload, socket_path: &Path) -> std::io::Result<()> {
    let mut stream = UnixStream::connect(socket_path)?;
    let line = codec::encode_line(&Request::Report(payload)).map_err(std::io::Error::other)?;
    stream.write_all(line.as_bytes())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn proc_info_reads_the_current_process_and_reports_a_real_parent() {
        // Self-check of the libproc `proc_pidinfo(PROC_PIDTBSDINFO)` layer:
        // reading THIS process's own info must succeed and report a positive
        // parent pid (the test runner). This exercises the struct layout and
        // the syscall wiring the pure ancestor walk depends on; it only reads
        // the current process's info, mutating nothing. (Same read-only,
        // own-process precedent as the conversations live/past self-check.)
        let info = proc_info(std::process::id() as i32).expect("own process must be inspectable");
        assert!(info.ppid > 0, "a running process has a real parent pid");
        // The controlling tty may be present or absent depending on how the
        // test harness was launched; whatever it is, it must be a `/dev/`
        // path when present (never a bare name or the `??` sentinel).
        if let Some(tty) = info.tty {
            assert!(tty.starts_with("/dev/"), "tty must be an absolute /dev path, got {tty:?}");
        }
    }

    #[test]
    fn tty_path_for_dev_maps_nodev_to_none() {
        assert_eq!(tty_path_for_dev(NODEV_U32), None);
    }

    #[test]
    fn ancestor_walk_from_this_process_terminates_within_the_limit() {
        // End-to-end over the real process tree using the real libproc
        // lookup: the walk must terminate (return Some or None) without
        // panicking or looping — it can't exceed the step bound.
        let _ = resolve_controlling_process();
    }
}
