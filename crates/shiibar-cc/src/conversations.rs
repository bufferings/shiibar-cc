//! Claude Code conversation-file layout knowledge (DESIGN.md §4.4 resume /
//! §7-3): a resumable conversation lives at
//! `~/.claude/projects/<slug>/<session_id>.jsonl`, where `slug` is the
//! session's cwd with every `/` replaced by `-` (verified on a real
//! machine 2026-07-05: `/Users/example/my/proj` -> `-Users-example-my-proj`).
//!
//! Subagent sessions (Task-tool children) inherit `$ITERM_SESSION_ID`,
//! fire hooks, and land in the sessions history with their own session_id
//! — but have no conversation file, so `claude --resume <id>` fails with
//! "No conversation found" (§7-3). This module is what lets `resume`
//! filter those out.
//!
//! This is knowledge about *Claude's* storage layout, so it lives in the
//! shiibar-cc crate (not shiibar-cc-client's iterm module, which is
//! iTerm2-only knowledge — design principle 2).

use std::path::{Path, PathBuf};

/// Derive the `~/.claude/projects/` directory name for a session cwd:
/// every `/` becomes `-` (the observed rule — an absolute path therefore
/// yields a leading `-`).
///
/// Only the `/` -> `-` replacement is applied, exactly as observed. Other
/// characters (including `.`) are left untouched: whether Claude escapes
/// dots or anything else could not be verified against a real layout, and
/// guessing an extra rule risks resolving to a wrong-but-existing
/// directory. A wrong slug that resolves to a *nonexistent* directory is
/// harmless — `is_resumable` fails open on that (§4.4).
pub fn project_slug(cwd: &str) -> String {
    cwd.replace('/', "-")
}

/// Whether `session_id` under `cwd` should be offered as a resume
/// candidate, judged by conversation-file presence (§4.4):
///
/// - project dir missing / not a directory -> **true** (fail-open: a
///   Claude-side layout change must degrade to "extra candidates", never
///   to "no candidates");
/// - project dir present, `<session_id>.jsonl` present -> true;
/// - project dir present, `<session_id>.jsonl` missing -> **false** (this
///   is the subagent-session case, §7-3).
pub fn is_resumable(projects_root: &Path, cwd: &str, session_id: &str) -> bool {
    let project_dir = projects_root.join(project_slug(cwd));
    if !project_dir.is_dir() {
        return true;
    }
    project_dir.join(format!("{session_id}.jsonl")).is_file()
}

/// The real projects root: `<home>/.claude/projects`. Injectable everywhere
/// else (tests pass a temp dir); this is only the production default —
/// deliberately not an env var (§8.9).
pub fn default_projects_root(home_dir: &Path) -> PathBuf {
    home_dir.join(".claude").join("projects")
}

#[cfg(test)]
mod tests {
    use super::*;

    // ---- project_slug ----

    #[test]
    fn slug_replaces_every_slash_with_a_dash() {
        assert_eq!(
            project_slug("/Users/example/my/proj"),
            "-Users-example-my-proj"
        );
    }

    #[test]
    fn slug_with_a_trailing_slash_keeps_the_trailing_dash() {
        // Derived mechanically from the observed rule ("/" -> "-"). Real
        // hook cwds never carry a trailing slash, and if this shape is ever
        // wrong the resulting directory simply won't exist -> fail-open.
        assert_eq!(project_slug("/Users/example/proj/"), "-Users-example-proj-");
    }

    #[test]
    fn slug_leaves_dots_untouched() {
        // Dot handling is unverified against a real layout (see the fn
        // comment): only the observed "/" rule is applied.
        assert_eq!(
            project_slug("/Users/example/my.dotted/proj"),
            "-Users-example-my.dotted-proj"
        );
    }

    // ---- is_resumable ----

    #[test]
    fn candidate_with_an_existing_conversation_file_is_resumable() {
        let root = tempfile::tempdir().unwrap();
        let project_dir = root.path().join("-proj-a");
        std::fs::create_dir_all(&project_dir).unwrap();
        std::fs::write(project_dir.join("s-1.jsonl"), "{}\n").unwrap();
        assert!(is_resumable(root.path(), "/proj/a", "s-1"));
    }

    #[test]
    fn candidate_missing_its_conversation_file_under_an_existing_project_dir_is_not_resumable() {
        // The subagent-session case (§7-3): the project dir exists (the
        // parent session has a conversation there) but this session_id has
        // no .jsonl of its own.
        let root = tempfile::tempdir().unwrap();
        let project_dir = root.path().join("-proj-a");
        std::fs::create_dir_all(&project_dir).unwrap();
        std::fs::write(project_dir.join("parent-session.jsonl"), "{}\n").unwrap();
        assert!(!is_resumable(root.path(), "/proj/a", "s-subagent"));
    }

    #[test]
    fn candidate_whose_project_dir_does_not_exist_is_kept_fail_open() {
        let root = tempfile::tempdir().unwrap();
        assert!(
            is_resumable(root.path(), "/proj/never-seen", "s-1"),
            "an unresolvable project dir must not exclude the candidate (§4.4 fail-open)"
        );
    }

    #[test]
    fn nonexistent_projects_root_keeps_everything_fail_open() {
        let dir = tempfile::tempdir().unwrap();
        let missing_root = dir.path().join("no-such-projects-root");
        assert!(is_resumable(&missing_root, "/proj/a", "s-1"));
    }

    #[test]
    fn default_projects_root_is_home_claude_projects() {
        assert_eq!(
            default_projects_root(Path::new("/Users/example")),
            PathBuf::from("/Users/example/.claude/projects")
        );
    }
}
