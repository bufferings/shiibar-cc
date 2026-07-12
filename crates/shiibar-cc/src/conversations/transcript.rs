//! Transcript (`~/.claude/projects/<slug>/<session_id>.jsonl`) parsing:
//! one file's content -> one extracted conversation (DESIGN.md §4.6).
//!
//! This file is the only place that knows the transcript's line format —
//! a read-only dependency on a non-public format (DESIGN.md §4.6, design
//! principle 2). Everything here is defensive: a line that fails to parse
//! (broken, or the in-progress tail of a live session), an unknown line
//! type, or a missing field is skipped and extraction continues.
//!
//! Extraction rule (DESIGN.md §4.6):
//! - The leaf is the last complete, non-sidechain `user`/`assistant` line
//!   in the file (in an append-only tree the last appended node is always
//!   on the currently active branch; a rewind just appends a new branch).
//! - Walk `parentUuid` from the leaf. The chain may pass through non-
//!   utterance nodes (`system`, `attachment`, ... also carry
//!   `uuid`/`parentUuid` — verified on real transcripts, M34). If a parent
//!   is missing, treat the current node as the root and stop.
//! - Keep only human utterances (user) and Claude's text replies
//!   (assistant text blocks), in appearance order.

use serde_json::Value;
use std::collections::{HashMap, HashSet};

/// One kept utterance, in appearance order along the active path.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Message {
    pub role: Role,
    pub text: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    User,
    Assistant,
}

impl Role {
    pub fn as_str(self) -> &'static str {
        match self {
            Role::User => "user",
            Role::Assistant => "assistant",
        }
    }
}

/// Everything the index stores per conversation, extracted from one file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Extracted {
    /// Last `custom-title` -> last `ai-title` -> head of the first user
    /// prompt -> None (DESIGN.md §4.6; the folder-label fallback is the
    /// display side's job).
    pub title: Option<String>,
    pub cwd: Option<String>,
    pub messages: Vec<Message>,
}

/// Head of the first user prompt used as the title fallback: first line,
/// at most this many characters (mirrors §9's task truncation length; the
/// spec fixes no constant for this fallback, see the M34 report).
const TITLE_FALLBACK_MAX_CHARS: usize = 80;

/// User lines whose (string) content starts with one of these tags are
/// machinery, not human utterances: automatic wake-ups and slash-command
/// records (DESIGN.md §4.6's exclusion list; tag set verified against the
/// real corpus, M34).
const EXCLUDED_USER_PREFIXES: &[&str] = &[
    "<task-notification>",
    "<command-name>",
    "<command-message>",
    "<local-command-stdout>",
    "<local-command-caveat>",
];

/// Per-line data kept for `user` / `assistant` lines while scanning.
struct Utterance {
    role: Role,
    /// `None` = the line is on the tree but is not a kept utterance
    /// (tool_result, excluded tag, meta-injected, no text blocks, ...).
    text: Option<String>,
    cwd: Option<String>,
}

pub fn extract(content: &str) -> Extracted {
    // uuid -> parentUuid for EVERY uuid-bearing line (any type), so the
    // parent walk can pass through system/attachment nodes.
    let mut parents: HashMap<String, Option<String>> = HashMap::new();
    let mut utterances: HashMap<String, Utterance> = HashMap::new();
    // File order of user/assistant lines, for the cwd fallback below.
    let mut utterance_order: Vec<String> = Vec::new();
    let mut leaf: Option<String> = None;
    let mut last_ai_title: Option<String> = None;
    let mut last_custom_title: Option<String> = None;

    for line in content.lines() {
        // Broken lines and the in-progress tail of a live session fail to
        // parse; skip and continue (DESIGN.md §4.6).
        let Ok(value) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        let Some(obj) = value.as_object() else {
            continue;
        };
        let line_type = obj.get("type").and_then(Value::as_str);

        // Record the tree edge for every uuid-bearing line regardless of
        // type (the active path passes through system/attachment nodes).
        if let Some(uuid) = obj.get("uuid").and_then(Value::as_str) {
            let parent = obj
                .get("parentUuid")
                .and_then(Value::as_str)
                .map(str::to_string);
            parents.insert(uuid.to_string(), parent);
        }

        match line_type {
            Some("ai-title") => {
                if let Some(t) = obj.get("aiTitle").and_then(Value::as_str) {
                    last_ai_title = non_empty(t);
                }
            }
            Some("custom-title") => {
                if let Some(t) = obj.get("customTitle").and_then(Value::as_str) {
                    last_custom_title = non_empty(t);
                }
            }
            Some(t @ ("user" | "assistant")) => {
                let Some(uuid) = obj.get("uuid").and_then(Value::as_str) else {
                    continue;
                };
                let sidechain = obj
                    .get("isSidechain")
                    .and_then(Value::as_bool)
                    .unwrap_or(false);
                let role = if t == "user" {
                    Role::User
                } else {
                    Role::Assistant
                };
                let text = match role {
                    Role::User => user_text(obj),
                    Role::Assistant => assistant_text(obj),
                };
                let cwd = obj
                    .get("cwd")
                    .and_then(Value::as_str)
                    .and_then(non_empty_str);
                // Sidechain lines (subagent conversations) never become
                // the leaf and never contribute utterances (DESIGN.md
                // §4.6), but their tree edge was recorded above.
                if !sidechain {
                    utterances.insert(uuid.to_string(), Utterance { role, text, cwd });
                    utterance_order.push(uuid.to_string());
                    leaf = Some(uuid.to_string());
                }
            }
            // Unknown / other line types: skip (edge already recorded).
            _ => {}
        }
    }

    // Walk parentUuid from the leaf; missing parent = root, stop there.
    let mut path: Vec<String> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    let mut cursor = leaf;
    while let Some(id) = cursor {
        if !seen.insert(id.clone()) {
            break; // cycle guard (defensive; never observed)
        }
        let parent = parents.get(&id).cloned().flatten();
        path.push(id);
        cursor = match parent {
            Some(p) if parents.contains_key(&p) => Some(p),
            _ => None,
        };
    }
    path.reverse(); // chronological order

    let mut messages: Vec<Message> = Vec::new();
    let mut cwd: Option<String> = None;
    for id in &path {
        let Some(u) = utterances.get(id) else {
            continue; // a system/attachment node on the path
        };
        if cwd.is_none() {
            cwd = u.cwd.clone();
        }
        if let Some(text) = &u.text {
            messages.push(Message {
                role: u.role,
                text: text.clone(),
            });
        }
    }
    // cwd fallback: any (non-sidechain) user/assistant line in file order,
    // for files whose active path carries no cwd.
    if cwd.is_none() {
        cwd = utterance_order
            .iter()
            .find_map(|id| utterances.get(id).and_then(|u| u.cwd.clone()));
    }

    let title = last_custom_title
        .or(last_ai_title)
        .or_else(|| first_prompt_title(&messages));

    Extracted {
        title,
        cwd,
        messages,
    }
}

/// Title fallback: head (first line, truncated) of the first user
/// utterance on the active path.
fn first_prompt_title(messages: &[Message]) -> Option<String> {
    let first = messages.iter().find(|m| m.role == Role::User)?;
    let head = first.text.trim().lines().next()?.trim();
    if head.is_empty() {
        return None;
    }
    Some(head.chars().take(TITLE_FALLBACK_MAX_CHARS).collect())
}

/// Extract the human utterance from a `user` line, or `None` when the line
/// is machinery: tool results, meta-injected content (`isMeta`: image
/// placeholders, skill instruction injections), slash-command records, and
/// automatic `<task-notification>` wake-ups (DESIGN.md §4.6; the
/// discrimination rules were confirmed on the real corpus, M34).
fn user_text(obj: &serde_json::Map<String, Value>) -> Option<String> {
    if obj.get("isMeta").and_then(Value::as_bool) == Some(true) {
        return None;
    }
    let content = obj.get("message")?.get("content")?;
    let text = match content {
        Value::String(s) => s.clone(),
        Value::Array(blocks) => {
            // A tool_result block means the whole line is a tool result.
            if blocks
                .iter()
                .any(|b| b.get("type").and_then(Value::as_str) == Some("tool_result"))
            {
                return None;
            }
            join_text_blocks(blocks)?
        }
        _ => return None,
    };
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return None;
    }
    if EXCLUDED_USER_PREFIXES
        .iter()
        .any(|p| trimmed.starts_with(p))
    {
        return None;
    }
    Some(text)
}

/// Extract Claude's text reply from an `assistant` line: the text blocks
/// only — thinking, tool_use, fallback and any unknown block types are
/// skipped (DESIGN.md §4.6). `None` when the line has no text.
fn assistant_text(obj: &serde_json::Map<String, Value>) -> Option<String> {
    let content = obj.get("message")?.get("content")?;
    let text = match content {
        // Not observed in real transcripts (assistant content is always a
        // block array), accepted defensively.
        Value::String(s) => s.clone(),
        Value::Array(blocks) => join_text_blocks(blocks)?,
        _ => return None,
    };
    if text.trim().is_empty() {
        return None;
    }
    Some(text)
}

/// Join the `text` blocks of a content array (real lines carry at most one
/// text block each — verified on the corpus — but join defensively).
fn join_text_blocks(blocks: &[Value]) -> Option<String> {
    let texts: Vec<&str> = blocks
        .iter()
        .filter(|b| b.get("type").and_then(Value::as_str) == Some("text"))
        .filter_map(|b| b.get("text").and_then(Value::as_str))
        .collect();
    if texts.is_empty() {
        return None;
    }
    Some(texts.join("\n\n"))
}

fn non_empty(s: &str) -> Option<String> {
    let t = s.trim();
    if t.is_empty() {
        None
    } else {
        Some(t.to_string())
    }
}

fn non_empty_str(s: &str) -> Option<String> {
    if s.is_empty() {
        None
    } else {
        Some(s.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Fixture builders: hand-written lines true to the real structure
    // (uuid / parentUuid / isSidechain / block-array content, M34 brief).

    fn user_line(uuid: &str, parent: Option<&str>, text: &str) -> String {
        format!(
            r#"{{"type":"user","uuid":"{uuid}","parentUuid":{},"isSidechain":false,"cwd":"/Users/example/project","message":{{"role":"user","content":{}}}}}"#,
            json_opt(parent),
            serde_json::to_string(text).unwrap()
        )
    }

    fn assistant_text_line(uuid: &str, parent: Option<&str>, text: &str) -> String {
        format!(
            r#"{{"type":"assistant","uuid":"{uuid}","parentUuid":{},"isSidechain":false,"cwd":"/Users/example/project","message":{{"role":"assistant","content":[{{"type":"text","text":{}}}]}}}}"#,
            json_opt(parent),
            serde_json::to_string(text).unwrap()
        )
    }

    fn json_opt(v: Option<&str>) -> String {
        match v {
            Some(s) => format!("\"{s}\""),
            None => "null".to_string(),
        }
    }

    fn texts(e: &Extracted) -> Vec<(&'static str, String)> {
        e.messages
            .iter()
            .map(|m| (m.role.as_str(), m.text.clone()))
            .collect()
    }

    #[test]
    fn linear_conversation_is_extracted_in_order() {
        let content = [
            user_line("u1", None, "first question"),
            assistant_text_line("a1", Some("u1"), "first answer"),
            user_line("u2", Some("a1"), "second question"),
            assistant_text_line("a2", Some("u2"), "second answer"),
        ]
        .join("\n");
        let e = extract(&content);
        assert_eq!(
            texts(&e),
            vec![
                ("user", "first question".to_string()),
                ("assistant", "first answer".to_string()),
                ("user", "second question".to_string()),
                ("assistant", "second answer".to_string()),
            ]
        );
        assert_eq!(e.cwd.as_deref(), Some("/Users/example/project"));
    }

    #[test]
    fn rewind_branch_keeps_only_the_last_appended_branch() {
        // Two branches from the same parent (a1): the first branch
        // (u2a/a2a) was abandoned by a rewind; u2b/a2b was appended last
        // and is therefore the active branch (DESIGN.md §4.6).
        let content = [
            user_line("u1", None, "root question"),
            assistant_text_line("a1", Some("u1"), "root answer"),
            user_line("u2a", Some("a1"), "abandoned question"),
            assistant_text_line("a2a", Some("u2a"), "abandoned answer"),
            user_line("u2b", Some("a1"), "rewound question"),
            assistant_text_line("a2b", Some("u2b"), "rewound answer"),
        ]
        .join("\n");
        let e = extract(&content);
        assert_eq!(
            texts(&e),
            vec![
                ("user", "root question".to_string()),
                ("assistant", "root answer".to_string()),
                ("user", "rewound question".to_string()),
                ("assistant", "rewound answer".to_string()),
            ]
        );
    }

    #[test]
    fn missing_parent_truncates_the_path_at_that_node() {
        // u2's parent "ghost" never appears in the file: u2 becomes the
        // root of the recoverable path; u1 is unreachable.
        let content = [
            user_line("u1", None, "unreachable"),
            user_line("u2", Some("ghost"), "recovered root"),
            assistant_text_line("a2", Some("u2"), "recovered answer"),
        ]
        .join("\n");
        let e = extract(&content);
        assert_eq!(
            texts(&e),
            vec![
                ("user", "recovered root".to_string()),
                ("assistant", "recovered answer".to_string()),
            ]
        );
    }

    #[test]
    fn path_passes_through_system_and_attachment_nodes() {
        // Real pattern (M34 corpus check): the chain from the last
        // assistant line runs through system/attachment nodes.
        let content = [
            user_line("u1", None, "question"),
            r#"{"type":"attachment","uuid":"at1","parentUuid":"u1"}"#.to_string(),
            assistant_text_line("a1", Some("at1"), "answer"),
            r#"{"type":"system","uuid":"s1","parentUuid":"a1","isSidechain":false}"#.to_string(),
            user_line("u2", Some("s1"), "follow-up"),
        ]
        .join("\n");
        let e = extract(&content);
        assert_eq!(
            texts(&e),
            vec![
                ("user", "question".to_string()),
                ("assistant", "answer".to_string()),
                ("user", "follow-up".to_string()),
            ]
        );
    }

    #[test]
    fn sidechain_lines_are_excluded_and_never_become_the_leaf() {
        let content = [
            user_line("u1", None, "main question"),
            assistant_text_line("a1", Some("u1"), "main answer"),
            // Sidechain conversation appended after the main lines: must
            // not become the leaf (that would drop the whole main path).
            r#"{"type":"user","uuid":"sc1","parentUuid":null,"isSidechain":true,"message":{"role":"user","content":"subagent prompt"}}"#.to_string(),
            r#"{"type":"assistant","uuid":"sc2","parentUuid":"sc1","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"subagent reply"}]}}"#.to_string(),
        ]
        .join("\n");
        let e = extract(&content);
        assert_eq!(
            texts(&e),
            vec![
                ("user", "main question".to_string()),
                ("assistant", "main answer".to_string()),
            ]
        );
    }

    #[test]
    fn machinery_user_lines_are_excluded() {
        let tool_result = r#"{"type":"user","uuid":"tr","parentUuid":"a1","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"file contents"}]}}"#;
        let task_notification = r#"{"type":"user","uuid":"tn","parentUuid":"tr","isSidechain":false,"message":{"role":"user","content":"<task-notification>agent finished</task-notification>"}}"#;
        let command = r#"{"type":"user","uuid":"cn","parentUuid":"tn","isSidechain":false,"message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#;
        let command_stdout = r#"{"type":"user","uuid":"cs","parentUuid":"cn","isSidechain":false,"message":{"role":"user","content":"<local-command-stdout>output</local-command-stdout>"}}"#;
        let meta_injected = r#"{"type":"user","uuid":"mi","parentUuid":"cs","isSidechain":false,"isMeta":true,"message":{"role":"user","content":[{"type":"text","text":"Base directory for this skill: /Users/example/skill"}]}}"#;
        let empty = r#"{"type":"user","uuid":"em","parentUuid":"mi","isSidechain":false,"message":{"role":"user","content":"   "}}"#;
        let content = [
            user_line("u1", None, "real question"),
            assistant_text_line("a1", Some("u1"), "real answer"),
            tool_result.to_string(),
            task_notification.to_string(),
            command.to_string(),
            command_stdout.to_string(),
            meta_injected.to_string(),
            empty.to_string(),
            user_line("u2", Some("em"), "second real question"),
        ]
        .join("\n");
        let e = extract(&content);
        assert_eq!(
            texts(&e),
            vec![
                ("user", "real question".to_string()),
                ("assistant", "real answer".to_string()),
                ("user", "second real question".to_string()),
            ]
        );
    }

    #[test]
    fn user_text_blocks_with_images_keep_the_text() {
        let content = [
            r#"{"type":"user","uuid":"u1","parentUuid":null,"isSidechain":false,"cwd":"/Users/example/p","message":{"role":"user","content":[{"type":"image","source":{}},{"type":"text","text":"what is in this screenshot?"}]}}"#.to_string(),
        ]
        .join("\n");
        let e = extract(&content);
        assert_eq!(
            texts(&e),
            vec![("user", "what is in this screenshot?".to_string())]
        );
    }

    #[test]
    fn assistant_non_text_blocks_are_skipped() {
        let thinking = r#"{"type":"assistant","uuid":"a1","parentUuid":"u1","isSidechain":false,"message":{"role":"assistant","content":[{"type":"thinking","thinking":"hidden reasoning"}]}}"#;
        let tool_use = r#"{"type":"assistant","uuid":"a2","parentUuid":"a1","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{}}]}}"#;
        let fallback = r#"{"type":"assistant","uuid":"a3","parentUuid":"a2","isSidechain":false,"message":{"role":"assistant","content":[{"type":"fallback","from":{"model":"a"},"to":{"model":"b"}}]}}"#;
        let content = [
            user_line("u1", None, "question"),
            thinking.to_string(),
            tool_use.to_string(),
            fallback.to_string(),
            assistant_text_line("a4", Some("a3"), "visible answer"),
        ]
        .join("\n");
        let e = extract(&content);
        assert_eq!(
            texts(&e),
            vec![
                ("user", "question".to_string()),
                ("assistant", "visible answer".to_string()),
            ]
        );
    }

    #[test]
    fn broken_and_truncated_lines_are_skipped() {
        let content = [
            user_line("u1", None, "question"),
            "not json at all".to_string(),
            r#"{"type":"assistant","uuid":"a1","parentUuid":"u1","isSide"#.to_string(), // truncated tail
        ]
        .join("\n");
        let e = extract(&content);
        assert_eq!(texts(&e), vec![("user", "question".to_string())]);
    }

    #[test]
    fn title_prefers_custom_title_over_ai_title() {
        let content = [
            user_line("u1", None, "the question"),
            r#"{"type":"ai-title","aiTitle":"AI given title","sessionId":"s"}"#.to_string(),
            r#"{"type":"custom-title","customTitle":"Owner's title","sessionId":"s"}"#.to_string(),
        ]
        .join("\n");
        assert_eq!(extract(&content).title.as_deref(), Some("Owner's title"));
    }

    #[test]
    fn title_uses_the_last_ai_title() {
        let content = [
            user_line("u1", None, "the question"),
            r#"{"type":"ai-title","aiTitle":"first title","sessionId":"s"}"#.to_string(),
            r#"{"type":"ai-title","aiTitle":"current title","sessionId":"s"}"#.to_string(),
        ]
        .join("\n");
        assert_eq!(extract(&content).title.as_deref(), Some("current title"));
    }

    #[test]
    fn title_falls_back_to_the_first_user_prompt_head() {
        let long_first_line = "x".repeat(120);
        let content = [user_line(
            "u1",
            None,
            &format!("{long_first_line}\nsecond line"),
        )]
        .join("\n");
        let title = extract(&content).title.unwrap();
        assert_eq!(title, "x".repeat(80));
    }

    #[test]
    fn title_is_null_when_nothing_is_available() {
        let content = r#"{"type":"file-history-snapshot","messageId":"m1"}"#;
        assert_eq!(extract(content).title, None);
    }

    #[test]
    fn empty_file_extracts_to_nothing() {
        let e = extract("");
        assert_eq!(e.messages, vec![]);
        assert_eq!(e.title, None);
        assert_eq!(e.cwd, None);
    }
}
