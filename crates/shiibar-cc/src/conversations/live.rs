//! live/past flag source: `~/.claude/sessions/<pid>.json` (DESIGN.md §4.6,
//! §7-6). The registry's key is the file NAME (= pid); a reused pid is
//! self-resolving because the new claude process overwrites the file, so
//! the content always belongs to the current occupant.
//!
//! Liveness is the two-step check from §4.6 — `kill(pid, 0)` says the pid
//! is alive AND the process name is `claude` — done with syscalls only (no
//! subprocess). The check is injectable so tests never probe real
//! processes.

use serde_json::Value;
use std::collections::HashSet;
use std::path::Path;

/// Injectable process-liveness check (tests substitute this; the real one
/// is [`RealLiveness`]).
pub trait LivenessProbe {
    /// True iff `pid` is a live process named `claude`.
    fn is_live_claude(&self, pid: i32) -> bool;
}

/// Session ids of running claude processes: every `<pid>.json` whose file
/// name parses as a positive pid AND passes the liveness probe contributes
/// its `sessionId`. Files with a non-numeric or non-positive name are
/// leftovers and are skipped WITHOUT probing — passing 0 to `kill` would
/// signal-check the whole process group and misreport (M34 brief).
pub fn live_session_ids(sessions_dir: &Path, probe: &dyn LivenessProbe) -> HashSet<String> {
    let mut out = HashSet::new();
    let Ok(entries) = std::fs::read_dir(sessions_dir) else {
        return out; // no directory = no live sessions
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Some(stem) = path.file_stem().and_then(|s| s.to_str()) else {
            continue;
        };
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let Ok(pid) = stem.parse::<i32>() else {
            continue; // non-numeric name: residue
        };
        if pid <= 0 {
            continue; // never reaches kill(2) (see above)
        }
        if !probe.is_live_claude(pid) {
            continue;
        }
        let Ok(content) = std::fs::read_to_string(&path) else {
            continue;
        };
        let Ok(value) = serde_json::from_str::<Value>(&content) else {
            continue; // malformed registry file: skip
        };
        if let Some(session_id) = value.get("sessionId").and_then(Value::as_str) {
            out.insert(session_id.to_string());
        }
    }
    out
}

/// The real probe: `kill(pid, 0)` + the process name — both plain
/// syscalls, no subprocess (DESIGN.md §4.6).
pub struct RealLiveness;

impl LivenessProbe for RealLiveness {
    fn is_live_claude(&self, pid: i32) -> bool {
        // kill(pid, 0) == 0 means the process exists and is signalable by
        // us (same user — which is what the per-user registry implies).
        // Any failure, including EPERM (someone else's process reused the
        // pid), counts as not ours.
        if unsafe { libc::kill(pid, 0) } != 0 {
            return false;
        }
        process_name(pid).as_deref() == Some("claude")
    }
}

/// Process name for `pid`: the basename of argv[0], read via
/// `sysctl(KERN_PROCARGS2)`. This matches what ps's COMM column shows —
/// the source of §7-6's "the process name is claude" observation.
/// `p_comm` / libproc's `proc_name` are NOT usable here: claude overwrites
/// its process title with its version string (observed "2.1.207", M34),
/// and its executable is the versioned binary
/// (`.../claude/versions/<version>`), so only argv[0] carries "claude".
fn process_name(pid: i32) -> Option<String> {
    let mut buf = vec![0u8; sysctl_argmax()?];
    let mut mib: [libc::c_int; 3] = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid];
    let mut len = buf.len();
    let rc = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            mib.len() as libc::c_uint,
            buf.as_mut_ptr() as *mut libc::c_void,
            &mut len,
            std::ptr::null_mut(),
            0,
        )
    };
    if rc != 0 || len <= 4 {
        return None;
    }
    // Layout: int32 argc | exec path NUL | NUL padding | argv[0] NUL | ...
    let bytes = &buf[4..len];
    let exec_end = bytes.iter().position(|&b| b == 0)?;
    let mut start = exec_end;
    while start < bytes.len() && bytes[start] == 0 {
        start += 1;
    }
    if start >= bytes.len() {
        return None;
    }
    let end = start + bytes[start..].iter().position(|&b| b == 0)?;
    let argv0 = std::str::from_utf8(&bytes[start..end]).ok()?;
    let name = argv0.rsplit('/').next().unwrap_or(argv0);
    Some(name.to_string())
}

/// `kern.argmax`: the buffer size KERN_PROCARGS2 requires.
fn sysctl_argmax() -> Option<usize> {
    let mut mib: [libc::c_int; 2] = [libc::CTL_KERN, libc::KERN_ARGMAX];
    let mut value: libc::c_int = 0;
    let mut len = std::mem::size_of::<libc::c_int>();
    let rc = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            mib.len() as libc::c_uint,
            &mut value as *mut libc::c_int as *mut libc::c_void,
            &mut len,
            std::ptr::null_mut(),
            0,
        )
    };
    if rc == 0 && value > 0 {
        Some(value as usize)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::fs;

    /// Fake probe: records every probed pid, answers from a fixed set.
    struct FakeProbe {
        live: Vec<i32>,
        probed: RefCell<Vec<i32>>,
    }

    impl FakeProbe {
        fn new(live: &[i32]) -> Self {
            FakeProbe {
                live: live.to_vec(),
                probed: RefCell::new(Vec::new()),
            }
        }
    }

    impl LivenessProbe for FakeProbe {
        fn is_live_claude(&self, pid: i32) -> bool {
            self.probed.borrow_mut().push(pid);
            self.live.contains(&pid)
        }
    }

    fn write_pid_file(dir: &Path, name: &str, session_id: &str) {
        fs::write(
            dir.join(name),
            format!(
                r#"{{"pid":123,"sessionId":"{session_id}","cwd":"/Users/example/project","status":"idle"}}"#
            ),
        )
        .unwrap();
    }

    #[test]
    fn live_pid_contributes_its_session_id() {
        let dir = tempfile::tempdir().unwrap();
        write_pid_file(dir.path(), "1234.json", "session-live");
        let probe = FakeProbe::new(&[1234]);
        let ids = live_session_ids(dir.path(), &probe);
        assert_eq!(ids, HashSet::from(["session-live".to_string()]));
    }

    #[test]
    fn dead_pid_is_excluded() {
        let dir = tempfile::tempdir().unwrap();
        write_pid_file(dir.path(), "1234.json", "session-dead");
        let probe = FakeProbe::new(&[]);
        assert!(live_session_ids(dir.path(), &probe).is_empty());
    }

    #[test]
    fn residue_files_are_skipped_without_probing() {
        let dir = tempfile::tempdir().unwrap();
        write_pid_file(dir.path(), "0.json", "session-zero");
        write_pid_file(dir.path(), "-5.json", "session-negative");
        write_pid_file(dir.path(), "notapid.json", "session-nan");
        write_pid_file(dir.path(), "1234.txt", "session-wrong-ext");
        let probe = FakeProbe::new(&[0, -5, 1234]);
        assert!(live_session_ids(dir.path(), &probe).is_empty());
        assert!(
            probe.probed.borrow().is_empty(),
            "residue files must never reach kill(2)"
        );
    }

    #[test]
    fn pid_reuse_reads_the_current_occupants_session_id() {
        // The registry file name is the pid; after reuse the new claude
        // overwrote it, so reading the file yields the new session id.
        let dir = tempfile::tempdir().unwrap();
        write_pid_file(dir.path(), "1234.json", "session-old");
        write_pid_file(dir.path(), "1234.json", "session-new"); // overwrite
        let probe = FakeProbe::new(&[1234]);
        let ids = live_session_ids(dir.path(), &probe);
        assert_eq!(ids, HashSet::from(["session-new".to_string()]));
    }

    #[test]
    fn malformed_registry_file_is_skipped() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("1234.json"), "{broken").unwrap();
        let probe = FakeProbe::new(&[1234]);
        assert!(live_session_ids(dir.path(), &probe).is_empty());
    }

    #[test]
    fn missing_directory_means_no_live_sessions() {
        let dir = tempfile::tempdir().unwrap();
        let missing = dir.path().join("no-such-dir");
        let probe = FakeProbe::new(&[1]);
        assert!(live_session_ids(&missing, &probe).is_empty());
    }

    #[test]
    fn process_name_reads_argv0_basename_of_the_current_process() {
        // Self-check of the KERN_PROCARGS2 parsing: cargo launches this
        // test binary with argv[0] = its full path, so the parsed name
        // must equal the executable's file name.
        let expected = std::env::current_exe()
            .unwrap()
            .file_name()
            .unwrap()
            .to_string_lossy()
            .into_owned();
        let name = process_name(std::process::id() as i32).expect("own process name");
        assert_eq!(name, expected);
    }

    #[test]
    fn process_name_of_a_dead_pid_is_none() {
        // pid 1 is launchd (not ours, KERN_PROCARGS2 refuses) — but avoid
        // asserting on other real processes; use an impossible pid.
        assert_eq!(process_name(i32::MAX), None);
    }
}
