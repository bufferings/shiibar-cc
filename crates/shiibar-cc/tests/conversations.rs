//! Conversations end-to-end tests (M34, DESIGN.md §4.4/§4.6): the library
//! API with fully injected dependencies (temp transcript/sessions dirs,
//! temp DB path, fake liveness probe), plus black-box runs of the compiled
//! binary for the exit-code and JSON contracts.
//!
//! Fixtures are small hand-written jsonl strings true to the real
//! transcript structure (uuid / parentUuid / isSidechain / block-array
//! content), written into temp dirs at runtime — no machine paths, no real
//! user data, and the flock is always on the injected DB path, never the
//! real state dir.

use shiibar_cc::conversations::{
    Deps, ProgressEvent, SearchError, db, live::LivenessProbe, lock, run_index, run_search,
    run_show,
};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, SystemTime};

// ---------- fixtures ----------

struct FakeProbe {
    live: Vec<i32>,
}

impl LivenessProbe for FakeProbe {
    fn is_live_claude(&self, pid: i32) -> bool {
        self.live.contains(&pid)
    }
}

struct Fixture {
    _dir: tempfile::TempDir,
    projects: PathBuf,
    sessions: PathBuf,
    db_path: PathBuf,
}

impl Fixture {
    fn new() -> Fixture {
        let dir = tempfile::tempdir().unwrap();
        let projects = dir.path().join("projects");
        let sessions = dir.path().join("sessions");
        let db_path = dir.path().join("state/conversations-index.db");
        fs::create_dir_all(&projects).unwrap();
        fs::create_dir_all(&sessions).unwrap();
        Fixture {
            _dir: dir,
            projects,
            sessions,
            db_path,
        }
    }

    fn deps(&self) -> Deps {
        self.deps_with_probe(FakeProbe { live: vec![] })
    }

    fn deps_with_probe(&self, probe: FakeProbe) -> Deps {
        Deps {
            projects_dir: self.projects.clone(),
            sessions_dir: self.sessions.clone(),
            db_path: self.db_path.clone(),
            probe: Box::new(probe),
        }
    }

    /// Write `<projects>/<slug>/<session_id>.jsonl` and pin its mtime so
    /// ordering and diff tests are deterministic.
    fn write_transcript(&self, slug: &str, session_id: &str, lines: &[String], mtime_secs: u64) {
        let dir = self.projects.join(slug);
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join(format!("{session_id}.jsonl"));
        fs::write(&path, lines.join("\n")).unwrap();
        let mtime = SystemTime::UNIX_EPOCH + Duration::from_secs(mtime_secs);
        let f = fs::OpenOptions::new().write(true).open(&path).unwrap();
        f.set_modified(mtime).unwrap();
    }

    fn write_pid_file(&self, pid: i32, session_id: &str) {
        fs::write(
            self.sessions.join(format!("{pid}.json")),
            format!(r#"{{"pid":{pid},"sessionId":"{session_id}","cwd":"/Users/example/p"}}"#),
        )
        .unwrap();
    }
}

fn user_line(uuid: &str, parent: Option<&str>, text: &str) -> String {
    let parent_json = match parent {
        Some(p) => format!("\"{p}\""),
        None => "null".to_string(),
    };
    format!(
        r#"{{"type":"user","uuid":"{uuid}","parentUuid":{parent_json},"isSidechain":false,"cwd":"/Users/example/project","message":{{"role":"user","content":{}}}}}"#,
        serde_json::to_string(text).unwrap()
    )
}

fn assistant_line(uuid: &str, parent: Option<&str>, text: &str) -> String {
    let parent_json = match parent {
        Some(p) => format!("\"{p}\""),
        None => "null".to_string(),
    };
    format!(
        r#"{{"type":"assistant","uuid":"{uuid}","parentUuid":{parent_json},"isSidechain":false,"cwd":"/Users/example/project","message":{{"role":"assistant","content":[{{"type":"text","text":{}}}]}}}}"#,
        serde_json::to_string(text).unwrap()
    )
}

fn simple_conversation(question: &str, answer: &str) -> Vec<String> {
    vec![
        user_line("u1", None, question),
        assistant_line("a1", Some("u1"), answer),
    ]
}

fn search_ids(deps: &Deps, query: Option<&str>) -> Vec<String> {
    run_search(deps, query, &mut || {})
        .unwrap()
        .into_iter()
        .map(|r| r.session_id)
        .collect()
}

// ---------- indexing and browse ----------

#[test]
fn browse_lists_all_conversations_newest_first() {
    let fx = Fixture::new();
    fx.write_transcript(
        "slug-a",
        "older",
        &simple_conversation("first topic", "ok"),
        1_000,
    );
    fx.write_transcript(
        "slug-a",
        "newest",
        &simple_conversation("third topic", "ok"),
        3_000,
    );
    fx.write_transcript(
        "slug-b",
        "middle",
        &simple_conversation("second topic", "ok"),
        2_000,
    );
    let deps = fx.deps();
    assert_eq!(search_ids(&deps, None), vec!["newest", "middle", "older"]);
}

#[test]
fn index_emits_start_progress_shape_and_is_idempotent() {
    let fx = Fixture::new();
    fx.write_transcript("slug", "s1", &simple_conversation("hello", "world"), 1_000);
    let deps = fx.deps();
    let mut events = Vec::new();
    run_index(&deps, &mut |e| events.push(e)).unwrap();
    assert_eq!(
        events.first(),
        Some(&ProgressEvent::Start {
            total: 1,
            full_build: true
        })
    );
    assert_eq!(
        events.last(),
        Some(&ProgressEvent::Done {
            indexed: 1,
            removed: 0
        })
    );
    // Second run: nothing changed, still succeeds, indexes nothing.
    let mut events = Vec::new();
    run_index(&deps, &mut |e| events.push(e)).unwrap();
    assert_eq!(
        events.last(),
        Some(&ProgressEvent::Done {
            indexed: 0,
            removed: 0
        })
    );
}

#[test]
fn subagent_transcripts_below_the_session_level_are_not_conversations() {
    let fx = Fixture::new();
    fx.write_transcript(
        "slug",
        "real",
        &simple_conversation("real one", "ok"),
        1_000,
    );
    // <slug>/<session>/subagents/agent-x.jsonl — deeper than the §4.6
    // source pattern; must not appear as a conversation.
    let deep = fx.projects.join("slug/real/subagents");
    fs::create_dir_all(&deep).unwrap();
    fs::write(
        deep.join("agent-x.jsonl"),
        simple_conversation("subagent chatter", "ok").join("\n"),
    )
    .unwrap();
    let deps = fx.deps();
    assert_eq!(search_ids(&deps, None), vec!["real"]);
}

// ---------- diff updates ----------

#[test]
fn changed_added_and_removed_files_are_reflected() {
    let fx = Fixture::new();
    fx.write_transcript(
        "slug",
        "s1",
        &simple_conversation("original topic", "ok"),
        1_000,
    );
    fx.write_transcript("slug", "gone", &simple_conversation("doomed", "ok"), 1_500);
    let deps = fx.deps();
    assert_eq!(search_ids(&deps, Some("original")), vec!["s1"]);
    assert_eq!(search_ids(&deps, Some("doomed")), vec!["gone"]);

    // Change s1 (content + mtime), add s2, remove "gone".
    fx.write_transcript(
        "slug",
        "s1",
        &simple_conversation("replacement topic", "ok"),
        2_000,
    );
    fx.write_transcript("slug", "s2", &simple_conversation("brand new", "ok"), 3_000);
    fs::remove_file(fx.projects.join("slug/gone.jsonl")).unwrap();

    assert_eq!(search_ids(&deps, Some("replacement")), vec!["s1"]);
    assert!(search_ids(&deps, Some("original")).is_empty());
    assert_eq!(search_ids(&deps, Some("brand")), vec!["s2"]);
    assert!(search_ids(&deps, Some("doomed")).is_empty());
    assert_eq!(search_ids(&deps, None), vec!["s2", "s1"]);
}

#[test]
fn unchanged_stat_means_no_reread() {
    // Same (path, mtime, size): the file is NOT re-read (§4.6 stat sweep).
    let fx = Fixture::new();
    let original = simple_conversation("stable topic", "ok");
    fx.write_transcript("slug", "s1", &original, 1_000);
    let deps = fx.deps();
    assert_eq!(search_ids(&deps, Some("stable")), vec!["s1"]);

    // Rewrite with SAME byte length and pin the SAME mtime: index must
    // keep the old extraction (proof that unchanged stats skip the file).
    let swapped = simple_conversation("stible topic", "ok"); // same length
    fx.write_transcript("slug", "s1", &swapped, 1_000);
    assert_eq!(search_ids(&deps, Some("stable")), vec!["s1"]);
    assert!(search_ids(&deps, Some("stible")).is_empty());
}

// ---------- files without a human utterance (§4.6 "index contents") ----------

/// A transcript that only ran a slash command: the command record and its
/// output are excluded from the utterance sequence (§4.6).
fn slash_command_only() -> Vec<String> {
    vec![
        r#"{"type":"user","uuid":"cn","parentUuid":null,"isSidechain":false,"cwd":"/Users/example/project","message":{"role":"user","content":"<command-name>/model</command-name>"}}"#.to_string(),
        r#"{"type":"user","uuid":"cs","parentUuid":"cn","isSidechain":false,"cwd":"/Users/example/project","message":{"role":"user","content":"<local-command-stdout>Set model</local-command-stdout>"}}"#.to_string(),
    ]
}

fn title_only() -> Vec<String> {
    vec![r#"{"type":"custom-title","customTitle":"Named only","sessionId":"x"}"#.to_string()]
}

fn assistant_only() -> Vec<String> {
    vec![assistant_line("a1", None, "a reply with no prompt")]
}

/// No utterance line at all: only bookkeeping records.
fn no_utterance_lines() -> Vec<String> {
    vec![r#"{"type":"file-history-snapshot","messageId":"m1"}"#.to_string()]
}

fn unregistered_ids(db_path: &Path) -> Vec<String> {
    let conn = rusqlite::Connection::open(db_path).unwrap();
    let mut stmt = conn
        .prepare("SELECT session_id FROM unregistered_files ORDER BY session_id")
        .unwrap();
    stmt.query_map([], |row| row.get::<_, String>(0))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap()
}

fn done_event(deps: &Deps) -> ProgressEvent {
    let mut events = Vec::new();
    run_index(deps, &mut |e| events.push(e)).unwrap();
    *events.last().unwrap()
}

#[test]
fn transcripts_without_a_human_utterance_are_not_conversations() {
    let fx = Fixture::new();
    fx.write_transcript("slug", "slash", &slash_command_only(), 1_000);
    fx.write_transcript("slug", "titled", &title_only(), 1_100);
    fx.write_transcript("slug", "reply", &assistant_only(), 1_200);
    fx.write_transcript("slug", "bare", &no_utterance_lines(), 1_300);
    fx.write_transcript(
        "slug",
        "real",
        &simple_conversation("project question", "ok"),
        900,
    );
    let deps = fx.deps();

    // Browse and query alike leave them out; the real conversation's
    // result is the same as without them.
    assert_eq!(search_ids(&deps, None), vec!["real"]);
    assert!(search_ids(&deps, Some("Named")).is_empty());
    assert!(search_ids(&deps, Some("reply")).is_empty());
    assert_eq!(search_ids(&deps, Some("example")), vec!["real"]);
    let rows = run_search(&deps, Some("project"), &mut || {}).unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].session_id, "real");
    assert_eq!(rows[0].last_prompt.as_deref(), Some("project question"));

    // show answers as for an id that is not in the index (exit 2).
    for id in ["slash", "titled", "reply", "bare"] {
        assert!(run_show(&deps, id).unwrap().is_none(), "{id}");
    }
    assert!(run_show(&deps, "real").unwrap().is_some());
}

#[test]
fn a_file_that_gains_a_human_utterance_is_registered_on_the_next_catch_up() {
    let fx = Fixture::new();
    fx.write_transcript("slug", "s1", &slash_command_only(), 1_000);
    let deps = fx.deps();
    assert!(search_ids(&deps, None).is_empty());

    let mut lines = slash_command_only();
    lines.push(user_line("u1", Some("cs"), "now a real prompt"));
    fx.write_transcript("slug", "s1", &lines, 2_000);
    assert_eq!(search_ids(&deps, None), vec!["s1"]);
    assert_eq!(search_ids(&deps, Some("real prompt")), vec!["s1"]);
    let shown = run_show(&deps, "s1").unwrap().expect("registered");
    assert_eq!(shown.messages[0].text, "now a real prompt");
    assert!(unregistered_ids(&fx.db_path).is_empty());
}

#[test]
fn a_conversation_that_loses_its_human_utterances_is_removed_and_counted() {
    let fx = Fixture::new();
    fx.write_transcript("slug", "s1", &simple_conversation("soon gone", "ok"), 1_000);
    let deps = fx.deps();
    run_index(&deps, &mut |_| {}).unwrap();
    assert_eq!(search_ids(&deps, None), vec!["s1"]);

    // A rewind or rewrite can leave the file without a human utterance.
    fx.write_transcript("slug", "s1", &assistant_only(), 2_000);
    assert_eq!(
        done_event(&deps),
        ProgressEvent::Done {
            indexed: 1,
            removed: 1
        }
    );
    assert!(search_ids(&deps, None).is_empty());
    assert!(search_ids(&deps, Some("soon")).is_empty());
    assert!(run_show(&deps, "s1").unwrap().is_none());
}

#[test]
fn an_unchanged_unregistered_file_is_not_re_read() {
    let fx = Fixture::new();
    let original = vec![user_line("u1", None, "<command-name>/stat</command-name>")];
    fx.write_transcript("slug", "s1", &original, 1_000);
    let deps = fx.deps();
    run_index(&deps, &mut |_| {}).unwrap();
    assert_eq!(unregistered_ids(&fx.db_path), vec!["s1"]);

    // Nothing changed: the catch-up re-reads nothing.
    let mut events = Vec::new();
    run_index(&deps, &mut |e| events.push(e)).unwrap();
    assert_eq!(
        events.first(),
        Some(&ProgressEvent::Start {
            total: 0,
            full_build: false
        })
    );
    assert_eq!(
        events.last(),
        Some(&ProgressEvent::Done {
            indexed: 0,
            removed: 0
        })
    );

    // Same byte length, same pinned mtime, now with a human utterance:
    // the file is still not re-read (proof that the recorded stat skips it).
    let swapped = vec![user_line("u1", None, "a plain prompt that is thirty four")];
    assert_eq!(swapped[0].len(), original[0].len());
    fx.write_transcript("slug", "s1", &swapped, 1_000);
    assert!(search_ids(&deps, None).is_empty());
}

#[test]
fn a_deleted_unregistered_file_loses_its_record_without_counting_as_removed() {
    let fx = Fixture::new();
    fx.write_transcript("slug", "s1", &title_only(), 1_000);
    fx.write_transcript("slug", "real", &simple_conversation("kept", "ok"), 900);
    let deps = fx.deps();
    run_index(&deps, &mut |_| {}).unwrap();
    assert_eq!(unregistered_ids(&fx.db_path), vec!["s1"]);

    fs::remove_file(fx.projects.join("slug/s1.jsonl")).unwrap();
    assert_eq!(
        done_event(&deps),
        ProgressEvent::Done {
            indexed: 0,
            removed: 0
        }
    );
    assert!(unregistered_ids(&fx.db_path).is_empty());
    assert_eq!(search_ids(&deps, None), vec!["real"]);
}

// ---------- live/past ----------

#[test]
fn live_flag_follows_the_pid_registry_and_probe() {
    let fx = Fixture::new();
    fx.write_transcript(
        "slug",
        "session-live",
        &simple_conversation("hi", "ok"),
        1_000,
    );
    fx.write_pid_file(4242, "session-live");

    let deps = fx.deps_with_probe(FakeProbe { live: vec![4242] });
    let rows = run_search(&deps, None, &mut || {}).unwrap();
    assert!(rows[0].live);

    // Process died: next catch-up flips the flag back.
    let deps = fx.deps_with_probe(FakeProbe { live: vec![] });
    let rows = run_search(&deps, None, &mut || {}).unwrap();
    assert!(!rows[0].live);
}

// ---------- search semantics ----------

#[test]
fn multi_term_query_is_an_and_across_mixed_term_lengths() {
    let fx = Fixture::new();
    fx.write_transcript(
        "slug",
        "both",
        &simple_conversation("the zq marker and the sqlite word", "ok"),
        3_000,
    );
    fx.write_transcript(
        "slug",
        "only-short",
        &simple_conversation("the zq marker alone", "ok"),
        2_000,
    );
    fx.write_transcript(
        "slug",
        "only-long",
        &simple_conversation("the sqlite word alone", "ok"),
        1_000,
    );
    let deps = fx.deps();
    // "zq" (2 chars -> LIKE) AND "sqlite" (3+ -> MATCH): intersection.
    assert_eq!(search_ids(&deps, Some("zq sqlite")), vec!["both"]);
    assert_eq!(search_ids(&deps, Some("zq")), vec!["both", "only-short"]);
    assert_eq!(search_ids(&deps, Some("sqlite")), vec!["both", "only-long"]);
    assert!(search_ids(&deps, Some("zq sqlite missing")).is_empty());
}

#[test]
fn terms_match_across_title_cwd_and_body_combined() {
    // AND semantics are over the COMBINED title+cwd+body (§4.6): here one
    // term hits the title, the other the body.
    let fx = Fixture::new();
    let mut lines = simple_conversation("some plain question", "a body keyword answer");
    lines.push(
        r#"{"type":"ai-title","aiTitle":"Refactor the widget pipeline","sessionId":"s1"}"#
            .to_string(),
    );
    fx.write_transcript("slug", "s1", &lines, 1_000);
    let deps = fx.deps();
    assert_eq!(search_ids(&deps, Some("widget keyword")), vec!["s1"]);
    // cwd matches too (fixture cwd is /Users/example/project).
    assert_eq!(search_ids(&deps, Some("example/project")), vec!["s1"]);
}

#[test]
fn two_char_like_terms_escape_wildcards() {
    let fx = Fixture::new();
    fx.write_transcript(
        "slug",
        "literal",
        &simple_conversation("progress: 5% done", "ok"),
        2_000,
    );
    fx.write_transcript(
        "slug",
        "other",
        &simple_conversation("progress: 5x done", "ok"),
        1_000,
    );
    let deps = fx.deps();
    // "5%" must match the literal percent sign only, not "5<anything>".
    assert_eq!(search_ids(&deps, Some("5%")), vec!["literal"]);
    // "_d" must match the literal underscore only.
    fx.write_transcript(
        "slug",
        "underscore",
        &simple_conversation("a_d marker", "ok"),
        3_000,
    );
    fx.write_transcript(
        "slug",
        "plain",
        &simple_conversation("aXd marker", "ok"),
        500,
    );
    assert_eq!(search_ids(&deps, Some("_d")), vec!["underscore"]);
}

#[test]
fn match_terms_are_quoted_against_fts5_query_syntax() {
    let fx = Fixture::new();
    fx.write_transcript(
        "slug",
        "s1",
        &simple_conversation(r#"he said "hello" and left"#, "the abc* pattern"),
        1_000,
    );
    let deps = fx.deps();
    // Embedded double quote must not break the query.
    assert_eq!(
        search_ids(&deps, Some(r#"said"hello"#)),
        Vec::<String>::new()
    );
    assert_eq!(search_ids(&deps, Some(r#""hello""#)), vec!["s1"]);
    // "abc*" is a literal, not a prefix query: "abcX" must not match.
    fx.write_transcript(
        "slug",
        "s2",
        &simple_conversation("the abcX pattern", "ok"),
        2_000,
    );
    assert_eq!(search_ids(&deps, Some("abc*")), vec!["s1"]);
    // Operator words are literals inside the phrase.
    assert!(search_ids(&deps, Some("NEAR(")).is_empty());
}

#[test]
fn search_is_case_insensitive_on_both_paths() {
    let fx = Fixture::new();
    fx.write_transcript(
        "slug",
        "s1",
        &simple_conversation("Rust and SQLite together", "ok"),
        1_000,
    );
    let deps = fx.deps();
    assert_eq!(search_ids(&deps, Some("rust")), vec!["s1"]); // MATCH path
    assert_eq!(search_ids(&deps, Some("sqlite")), vec!["s1"]);
    assert_eq!(search_ids(&deps, Some("RU")), vec!["s1"]); // LIKE path (ASCII fold)
}

#[test]
fn multibyte_terms_search_by_character_count() {
    // Two CJK characters = one valid 2-char term (LIKE path); three = the
    // MATCH path. Text uses escapes to keep this file ASCII-only.
    let fx = Fixture::new();
    let text = "prefix \u{691c}\u{7d22}\u{6a5f}\u{80fd} suffix"; // "search feature" in Japanese
    fx.write_transcript("slug", "jp", &simple_conversation(text, "ok"), 1_000);
    let deps = fx.deps();
    assert_eq!(search_ids(&deps, Some("\u{691c}\u{7d22}")), vec!["jp"]);
    assert_eq!(
        search_ids(&deps, Some("\u{691c}\u{7d22}\u{6a5f}")),
        vec!["jp"]
    );
    assert!(search_ids(&deps, Some("\u{6a5f}\u{691c}")).is_empty());
}

#[test]
fn query_trim_split_and_short_term_rules() {
    let fx = Fixture::new();
    fx.write_transcript(
        "slug",
        "s1",
        &simple_conversation("alpha beta", "ok"),
        1_000,
    );
    let deps = fx.deps();
    // Surrounding ASCII + ideographic whitespace is trimmed; terms split.
    assert_eq!(
        search_ids(&deps, Some(" \u{3000}alpha\u{3000}beta ")),
        vec!["s1"]
    );
    // 1-char terms are ignored (query is effectively "alpha").
    assert_eq!(search_ids(&deps, Some("a alpha")), vec!["s1"]);
    // Blank query = browse.
    assert_eq!(search_ids(&deps, Some(" \u{3000} ")), vec!["s1"]);
    // No valid term at all = QueryTooShort, not a silent empty result.
    match run_search(&deps, Some("a b"), &mut || {}) {
        Err(SearchError::QueryTooShort) => {}
        other => panic!("expected QueryTooShort, got {other:?}"),
    }
}

#[test]
fn zero_matches_is_a_success_with_an_empty_list() {
    let fx = Fixture::new();
    fx.write_transcript("slug", "s1", &simple_conversation("something", "ok"), 1_000);
    let deps = fx.deps();
    assert_eq!(search_ids(&deps, Some("nomatchword")), Vec::<String>::new());
}

// ---------- show ----------

#[test]
fn show_returns_the_full_utterance_sequence_without_the_meta_row() {
    let fx = Fixture::new();
    let mut lines = vec![
        user_line("u1", None, "first question"),
        assistant_line("a1", Some("u1"), "first answer"),
        user_line("u2", Some("a1"), "second question"),
        assistant_line("a2", Some("u2"), "second answer"),
    ];
    lines
        .push(r#"{"type":"ai-title","aiTitle":"A searchable title","sessionId":"s1"}"#.to_string());
    fx.write_transcript("slug", "s1", &lines, 1_000);
    let deps = fx.deps();
    run_index(&deps, &mut |_| {}).unwrap();

    let shown = run_show(&deps, "s1")
        .unwrap()
        .expect("indexed conversation");
    assert_eq!(shown.title.as_deref(), Some("A searchable title"));
    assert_eq!(shown.cwd.as_deref(), Some("/Users/example/project"));
    let seq: Vec<(i64, &str, &str)> = shown
        .messages
        .iter()
        .map(|m| (m.seq, m.role.as_str(), m.text.as_str()))
        .collect();
    assert_eq!(
        seq,
        vec![
            (0, "user", "first question"),
            (1, "assistant", "first answer"),
            (2, "user", "second question"),
            (3, "assistant", "second answer"),
        ]
    );
}

#[test]
fn show_updated_at_equals_the_search_value_for_the_same_conversation() {
    // §4.4: show's updated_at is the value search returns for the same
    // conversation, so the pane can age the end marker from show alone.
    let fx = Fixture::new();
    fx.write_transcript("slug", "s1", &simple_conversation("older one", "ok"), 1_000);
    fx.write_transcript("slug", "s2", &simple_conversation("newer one", "ok"), 2_000);
    let deps = fx.deps();
    run_index(&deps, &mut |_| {}).unwrap();

    let rows = run_search(&deps, None, &mut || {}).unwrap();
    assert_eq!(rows.len(), 2);
    for row in &rows {
        let shown = run_show(&deps, &row.session_id).unwrap().expect("indexed");
        assert_eq!(shown.updated_at, row.updated_at, "{}", row.session_id);
    }
    // The two conversations differ, so equality is not a shared constant.
    assert_ne!(rows[0].updated_at, rows[1].updated_at);
}

#[test]
fn show_does_not_catch_up() {
    let fx = Fixture::new();
    fx.write_transcript(
        "slug",
        "s1",
        &simple_conversation("before edit", "ok"),
        1_000,
    );
    let deps = fx.deps();
    run_index(&deps, &mut |_| {}).unwrap();
    // Change the transcript afterwards: show still answers from the DB.
    fx.write_transcript(
        "slug",
        "s1",
        &simple_conversation("after edit", "ok"),
        2_000,
    );
    let shown = run_show(&deps, "s1").unwrap().unwrap();
    assert_eq!(shown.messages[0].text, "before edit");
}

#[test]
fn show_unknown_session_is_not_found() {
    let fx = Fixture::new();
    fx.write_transcript("slug", "s1", &simple_conversation("hello", "ok"), 1_000);
    let deps = fx.deps();
    run_index(&deps, &mut |_| {}).unwrap();
    assert!(run_show(&deps, "no-such-id").unwrap().is_none());
}

#[test]
fn show_with_no_database_yet_is_not_found() {
    let fx = Fixture::new();
    let deps = fx.deps();
    assert!(run_show(&deps, "anything").unwrap().is_none());
}

// ---------- rebuilds ----------

#[test]
fn schema_version_mismatch_triggers_a_full_rebuild() {
    let fx = Fixture::new();
    fx.write_transcript(
        "slug",
        "s1",
        &simple_conversation("survives rebuild", "ok"),
        1_000,
    );
    let deps = fx.deps();
    run_index(&deps, &mut |_| {}).unwrap();

    // Sabotage the schema version.
    let conn = rusqlite::Connection::open(&fx.db_path).unwrap();
    conn.execute(
        "UPDATE meta SET value='999999' WHERE key='schema_version'",
        [],
    )
    .unwrap();
    drop(conn);

    let mut full_build_seen = false;
    let rows = run_search(&deps, Some("survives"), &mut || full_build_seen = true).unwrap();
    assert_eq!(rows.len(), 1);
    assert!(full_build_seen, "version mismatch must be a full build");
    assert_eq!(rows[0].last_prompt.as_deref(), Some("survives rebuild"));
}

#[test]
fn a_previous_schema_without_last_prompt_is_rebuilt_and_gains_it() {
    // Simulate an index written by the previous schema (version 2, no
    // `last_prompt` column): the next search must detect the version
    // mismatch, rebuild in full, and answer with `last_prompt` filled in.
    let fx = Fixture::new();
    fx.write_transcript(
        "slug",
        "s1",
        &[
            user_line("u1", None, "older prompt"),
            assistant_line("a1", Some("u1"), "answer"),
            user_line("u2", Some("a1"), "newest prompt\nwith a second line"),
        ],
        1_000,
    );
    let deps = fx.deps();
    run_index(&deps, &mut |_| {}).unwrap();

    let conn = rusqlite::Connection::open(&fx.db_path).unwrap();
    conn.execute_batch(
        "ALTER TABLE conversations DROP COLUMN last_prompt;
         UPDATE meta SET value='2' WHERE key='schema_version';",
    )
    .unwrap();
    drop(conn);

    let mut full_build_seen = false;
    let rows = run_search(&deps, None, &mut || full_build_seen = true).unwrap();
    assert!(
        full_build_seen,
        "an older schema version must be a full build"
    );
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].last_prompt.as_deref(), Some("newest prompt"));

    // Converged: the following search is an ordinary diff catch-up.
    let mut second_full_build = false;
    run_search(&deps, None, &mut || second_full_build = true).unwrap();
    assert!(!second_full_build);
}

#[test]
fn a_previous_schema_index_holding_a_conversation_without_a_human_utterance_drops_it() {
    // An index written by the previous schema (version 3) registered every
    // file as a conversation. The version mismatch rebuilds it in full, and
    // the rebuild leaves the utterance-less file out (§4.6 "index contents").
    let fx = Fixture::new();
    fx.write_transcript("slug", "ghost", &title_only(), 2_000);
    fx.write_transcript("slug", "real", &simple_conversation("kept", "ok"), 1_000);
    let deps = fx.deps();
    run_index(&deps, &mut |_| {}).unwrap();

    let conn = rusqlite::Connection::open(&fx.db_path).unwrap();
    conn.execute_batch(
        "DROP TABLE unregistered_files;
         INSERT INTO conversations(session_id, path, mtime_ns, size, cwd, title, live, updated_at, last_prompt)
             VALUES('ghost', '/Users/example/ghost.jsonl', 0, 0, NULL, 'Named only', 0, 2000, NULL);
         UPDATE meta SET value='3' WHERE key='schema_version';",
    )
    .unwrap();
    drop(conn);
    assert!(run_show(&deps, "ghost").unwrap().is_some());

    let mut full_build_seen = false;
    let ids: Vec<String> = run_search(&deps, None, &mut || full_build_seen = true)
        .unwrap()
        .into_iter()
        .map(|r| r.session_id)
        .collect();
    assert!(
        full_build_seen,
        "an older schema version must be a full build"
    );
    assert_eq!(ids, vec!["real"]);
    assert!(run_show(&deps, "ghost").unwrap().is_none());
    assert_eq!(unregistered_ids(&fx.db_path), vec!["ghost"]);
}

#[test]
fn corrupt_database_file_is_rebuilt_automatically() {
    let fx = Fixture::new();
    fx.write_transcript(
        "slug",
        "s1",
        &simple_conversation("after corruption", "ok"),
        1_000,
    );
    fs::create_dir_all(fx.db_path.parent().unwrap()).unwrap();
    fs::write(&fx.db_path, "this is not a sqlite database at all").unwrap();

    let deps = fx.deps();
    let mut full_build_seen = false;
    let rows = run_search(&deps, Some("corruption"), &mut || full_build_seen = true).unwrap();
    assert_eq!(rows.len(), 1);
    assert!(full_build_seen, "corruption recovery must be a full build");
}

// ---------- permissions ----------

#[test]
fn state_dir_is_0700_and_db_file_is_0600() {
    use std::os::unix::fs::PermissionsExt;
    let fx = Fixture::new();
    fx.write_transcript("slug", "s1", &simple_conversation("hello", "ok"), 1_000);
    let deps = fx.deps();
    run_index(&deps, &mut |_| {}).unwrap();
    let dir_mode = fs::metadata(fx.db_path.parent().unwrap())
        .unwrap()
        .permissions()
        .mode();
    assert_eq!(dir_mode & 0o777, 0o700);
    let db_mode = fs::metadata(&fx.db_path).unwrap().permissions().mode();
    assert_eq!(db_mode & 0o777, 0o600);
}

// ---------- flock exclusion and progress relay ----------

#[test]
fn waiting_index_relays_the_holders_progress() {
    let fx = Fixture::new();
    fx.write_transcript("slug", "s1", &simple_conversation("hello", "ok"), 1_000);
    let deps = fx.deps();
    run_index(&deps, &mut |_| {}).unwrap(); // create the DB + schema

    // Pose as a running builder: hold the lock and record progress.
    let lock_path = lock::lock_path_for(&fx.db_path);
    let held = lock::try_acquire(&lock_path).unwrap().expect("lock free");
    let (mut db, _) = db::open_rw(&fx.db_path).unwrap();
    db.reset_progress(7, true).unwrap(); // done=0 / total=7, full build
    drop(db);

    // A second index (same deps, separate thread) must wait AND relay.
    let (event_tx, event_rx) = std::sync::mpsc::channel::<ProgressEvent>();
    let projects = fx.projects.clone();
    let sessions = fx.sessions.clone();
    let db_path = fx.db_path.clone();
    let waiter = std::thread::spawn(move || {
        let deps = Deps {
            projects_dir: projects,
            sessions_dir: sessions,
            db_path,
            probe: Box::new(FakeProbe { live: vec![] }),
        };
        run_index(&deps, &mut |e| {
            let _ = event_tx.send(e);
        })
    });

    // Expect the relayed progress of the fake builder while the lock is
    // still held (generous deadline; poll cadence is 250ms).
    let mut relayed = Vec::new();
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    while std::time::Instant::now() < deadline {
        if let Ok(e) = event_rx.recv_timeout(Duration::from_millis(100)) {
            relayed.push(e);
            if relayed.contains(&ProgressEvent::Progress { done: 0, total: 7 }) {
                break;
            }
        }
    }
    assert!(
        relayed.contains(&ProgressEvent::Start {
            total: 7,
            full_build: true
        }),
        "expected a relayed start, got {relayed:?}"
    );
    assert!(
        relayed.contains(&ProgressEvent::Progress { done: 0, total: 7 }),
        "expected relayed progress, got {relayed:?}"
    );

    drop(held); // hand over the lock
    waiter.join().unwrap().unwrap();
    // After the handover the waiter runs its own catch-up: its own
    // (re)start line and final done must have arrived too.
    let mut rest: Vec<ProgressEvent> = event_rx.try_iter().collect();
    let mut all = relayed;
    all.append(&mut rest);
    assert!(
        matches!(all.last(), Some(ProgressEvent::Done { .. })),
        "expected a final done event, got {all:?}"
    );
}

// ---------- full_build flag on `start` (§4.4) ----------

fn first_start(deps: &Deps) -> ProgressEvent {
    let mut events = Vec::new();
    run_index(deps, &mut |e| events.push(e)).unwrap();
    *events
        .iter()
        .find(|e| matches!(e, ProgressEvent::Start { .. }))
        .expect("a start event")
}

#[test]
fn first_build_start_is_a_full_build() {
    let fx = Fixture::new();
    fx.write_transcript("slug", "s1", &simple_conversation("hello", "ok"), 1_000);
    assert_eq!(
        first_start(&fx.deps()),
        ProgressEvent::Start {
            total: 1,
            full_build: true
        }
    );
}

#[test]
fn incremental_catch_up_start_is_not_a_full_build() {
    let fx = Fixture::new();
    fx.write_transcript("slug", "s1", &simple_conversation("hello", "ok"), 1_000);
    let deps = fx.deps();
    run_index(&deps, &mut |_| {}).unwrap();
    // One changed and one new transcript: a non-zero total, still an
    // incremental catch-up.
    fx.write_transcript("slug", "s1", &simple_conversation("hello", "more"), 2_000);
    fx.write_transcript("slug", "s2", &simple_conversation("another", "ok"), 3_000);
    assert_eq!(
        first_start(&deps),
        ProgressEvent::Start {
            total: 2,
            full_build: false
        }
    );
    // Nothing changed: total 0, not a full build either.
    assert_eq!(
        first_start(&deps),
        ProgressEvent::Start {
            total: 0,
            full_build: false
        }
    );
}

#[test]
fn schema_mismatch_rebuild_start_is_a_full_build() {
    let fx = Fixture::new();
    fx.write_transcript("slug", "s1", &simple_conversation("hello", "ok"), 1_000);
    let deps = fx.deps();
    run_index(&deps, &mut |_| {}).unwrap();
    let conn = rusqlite::Connection::open(&fx.db_path).unwrap();
    conn.execute(
        "UPDATE meta SET value='999999' WHERE key='schema_version'",
        [],
    )
    .unwrap();
    drop(conn);
    assert_eq!(
        first_start(&deps),
        ProgressEvent::Start {
            total: 1,
            full_build: true
        }
    );
}

#[test]
fn corruption_recovery_start_is_a_full_build() {
    let fx = Fixture::new();
    fx.write_transcript("slug", "s1", &simple_conversation("hello", "ok"), 1_000);
    fs::create_dir_all(fx.db_path.parent().unwrap()).unwrap();
    fs::write(&fx.db_path, "this is not a sqlite database at all").unwrap();
    assert_eq!(
        first_start(&fx.deps()),
        ProgressEvent::Start {
            total: 1,
            full_build: true
        }
    );
}

#[test]
fn relayed_start_carries_the_builders_incremental_flag() {
    let fx = Fixture::new();
    fx.write_transcript("slug", "s1", &simple_conversation("hello", "ok"), 1_000);
    let deps = fx.deps();
    run_index(&deps, &mut |_| {}).unwrap();

    // Pose as an incremental builder holding the lock.
    let lock_path = lock::lock_path_for(&fx.db_path);
    let held = lock::try_acquire(&lock_path).unwrap().expect("lock free");
    let (mut db, _) = db::open_rw(&fx.db_path).unwrap();
    db.reset_progress(3, false).unwrap();
    drop(db);

    let (event_tx, event_rx) = std::sync::mpsc::channel::<ProgressEvent>();
    let projects = fx.projects.clone();
    let sessions = fx.sessions.clone();
    let db_path = fx.db_path.clone();
    let waiter = std::thread::spawn(move || {
        let deps = Deps {
            projects_dir: projects,
            sessions_dir: sessions,
            db_path,
            probe: Box::new(FakeProbe { live: vec![] }),
        };
        run_index(&deps, &mut |e| {
            let _ = event_tx.send(e);
        })
    });

    let mut relayed = Vec::new();
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    while std::time::Instant::now() < deadline {
        if let Ok(e) = event_rx.recv_timeout(Duration::from_millis(100)) {
            relayed.push(e);
            if matches!(e, ProgressEvent::Start { .. }) {
                break;
            }
        }
    }
    assert_eq!(
        relayed.first(),
        Some(&ProgressEvent::Start {
            total: 3,
            full_build: false
        }),
        "got {relayed:?}"
    );
    drop(held);
    waiter.join().unwrap().unwrap();
}

#[test]
fn relay_reads_a_missing_flag_as_incremental() {
    // A meta table with counters but no full_build flag (written by a
    // builder that predates the flag) reads as an incremental build.
    let fx = Fixture::new();
    fx.write_transcript("slug", "s1", &simple_conversation("hello", "ok"), 1_000);
    let deps = fx.deps();
    run_index(&deps, &mut |_| {}).unwrap();
    let conn = rusqlite::Connection::open(&fx.db_path).unwrap();
    conn.execute("DELETE FROM meta WHERE key='progress_full_build'", [])
        .unwrap();
    drop(conn);
    let progress = db::open_ro(&fx.db_path).unwrap().read_progress().unwrap();
    assert!(!progress.full_build);
}

// ---------- black-box binary contract (exit codes + JSON shapes) ----------

struct BinOutput {
    code: i32,
    stdout: String,
    stderr: String,
}

/// Run the compiled `shiibar-cc conversations ...` with HOME and the state
/// dir redirected into a temp dir.
fn run_binary(home: &Path, args: &[&str]) -> BinOutput {
    let out = Command::new(env!("CARGO_BIN_EXE_shiibar-cc"))
        .arg("conversations")
        .args(args)
        .env("HOME", home)
        .env("SHIIBAR_CC_STATE_DIR", home.join("state"))
        .output()
        .expect("spawn shiibar-cc");
    BinOutput {
        code: out.status.code().unwrap_or(-1),
        stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
    }
}

fn write_home_transcript(home: &Path, session_id: &str, lines: &[String]) {
    let dir = home.join(".claude/projects/-Users-example-project");
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join(format!("{session_id}.jsonl")), lines.join("\n")).unwrap();
}

#[test]
fn binary_search_json_has_the_contract_fields() {
    let home = tempfile::tempdir().unwrap();
    write_home_transcript(
        home.path(),
        "abc-123",
        &[
            user_line("u1", None, "find this marker"),
            assistant_line("a1", Some("u1"), "ok"),
            user_line("u2", Some("a1"), "the last prompt\nsecond line"),
        ],
    );
    let out = run_binary(home.path(), &["search", "marker", "--json"]);
    assert_eq!(out.code, 0, "stderr: {}", out.stderr);
    let v: serde_json::Value = serde_json::from_str(out.stdout.trim()).unwrap();
    let conv = &v["conversations"][0];
    assert_eq!(conv["session_id"], "abc-123");
    assert_eq!(conv["cwd"], "/Users/example/project");
    assert!(conv["title"].is_string());
    assert!(conv["updated_at"].is_i64());
    assert_eq!(conv["live"], false);
    // §4.4: head (first line) of the LAST human utterance.
    assert_eq!(conv["last_prompt"], "the last prompt");
}

#[test]
fn binary_search_and_show_leave_out_a_transcript_without_a_human_utterance() {
    // §4.4 / §4.6 "index contents": a file without a human utterance is
    // not a conversation — absent from search, exit 2 from show.
    let home = tempfile::tempdir().unwrap();
    write_home_transcript(
        home.path(),
        "no-prompt",
        &[
            r#"{"type":"ai-title","aiTitle":"Only a title","sessionId":"no-prompt"}"#.to_string(),
            assistant_line("a1", None, "an answer without any prompt"),
        ],
    );
    write_home_transcript(
        home.path(),
        "with-prompt",
        &simple_conversation("a real prompt", "ok"),
    );
    let out = run_binary(home.path(), &["search", "--json"]);
    assert_eq!(out.code, 0, "stderr: {}", out.stderr);
    let v: serde_json::Value = serde_json::from_str(out.stdout.trim()).unwrap();
    let ids: Vec<&str> = v["conversations"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["session_id"].as_str().unwrap())
        .collect();
    assert_eq!(ids, vec!["with-prompt"]);

    let missing = run_binary(home.path(), &["show", "no-prompt", "--json"]);
    assert_eq!(missing.code, 2);
    assert!(!missing.stderr.is_empty());
}

#[test]
fn binary_search_too_short_query_exits_1_with_the_message() {
    let home = tempfile::tempdir().unwrap();
    let out = run_binary(home.path(), &["search", "x"]);
    assert_eq!(out.code, 1);
    assert!(
        out.stderr
            .contains("query too short (minimum 2 characters)"),
        "stderr: {}",
        out.stderr
    );
}

#[test]
fn binary_search_zero_matches_exits_0() {
    let home = tempfile::tempdir().unwrap();
    let out = run_binary(home.path(), &["search", "nothing-matches", "--json"]);
    assert_eq!(out.code, 0);
    let v: serde_json::Value = serde_json::from_str(out.stdout.trim()).unwrap();
    assert_eq!(v["conversations"].as_array().unwrap().len(), 0);
}

#[test]
fn binary_show_json_has_the_contract_fields_and_exit_codes() {
    let home = tempfile::tempdir().unwrap();
    write_home_transcript(
        home.path(),
        "abc-123",
        &simple_conversation("the question", "the answer"),
    );
    // Populate the index (show itself never catches up).
    assert_eq!(run_binary(home.path(), &["index"]).code, 0);

    let out = run_binary(home.path(), &["show", "abc-123", "--json"]);
    assert_eq!(out.code, 0, "stderr: {}", out.stderr);
    let v: serde_json::Value = serde_json::from_str(out.stdout.trim()).unwrap();
    let mut keys: Vec<&str> = v.as_object().unwrap().keys().map(String::as_str).collect();
    keys.sort_unstable();
    assert_eq!(
        keys,
        vec!["cwd", "messages", "session_id", "title", "updated_at"]
    );
    assert_eq!(v["session_id"], "abc-123");
    assert_eq!(v["cwd"], "/Users/example/project");
    assert!(v["title"].is_string());
    assert!(v["updated_at"].is_i64());
    assert_eq!(v["messages"][0]["seq"], 0);
    assert_eq!(v["messages"][0]["role"], "user");
    assert_eq!(v["messages"][0]["text"], "the question");
    assert_eq!(v["messages"][1]["role"], "assistant");

    let missing = run_binary(home.path(), &["show", "no-such-id"]);
    assert_eq!(missing.code, 2);
    assert!(!missing.stderr.is_empty());
}

#[test]
fn binary_show_json_updated_at_equals_the_search_updated_at() {
    // §4.4: show's updated_at is the same value search returns for the
    // same conversation.
    let home = tempfile::tempdir().unwrap();
    write_home_transcript(
        home.path(),
        "abc-123",
        &simple_conversation("the question", "the answer"),
    );
    let search = run_binary(home.path(), &["search", "--json"]);
    assert_eq!(search.code, 0, "stderr: {}", search.stderr);
    let sv: serde_json::Value = serde_json::from_str(search.stdout.trim()).unwrap();
    let searched = sv["conversations"][0]["updated_at"].as_i64().unwrap();

    let show = run_binary(home.path(), &["show", "abc-123", "--json"]);
    assert_eq!(show.code, 0, "stderr: {}", show.stderr);
    let v: serde_json::Value = serde_json::from_str(show.stdout.trim()).unwrap();
    assert_eq!(v["updated_at"].as_i64(), Some(searched));
}

#[test]
fn binary_index_json_streams_events() {
    let home = tempfile::tempdir().unwrap();
    write_home_transcript(
        home.path(),
        "abc-123",
        &simple_conversation("hello", "world"),
    );
    let out = run_binary(home.path(), &["index", "--json"]);
    assert_eq!(out.code, 0, "stderr: {}", out.stderr);
    let events: Vec<serde_json::Value> = out
        .stdout
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    assert_eq!(events.first().unwrap()["event"], "start");
    assert_eq!(events.first().unwrap()["total"], 1);
    // First build ever = full build (§4.4).
    assert_eq!(events.first().unwrap()["full_build"], true);
    let last = events.last().unwrap();
    assert_eq!(last["event"], "done");
    assert_eq!(last["indexed"], 1);
    assert_eq!(last["removed"], 0);

    // A second run with a new transcript is an incremental catch-up: the
    // start line carries full_build false even with a non-zero total.
    write_home_transcript(home.path(), "def-456", &simple_conversation("again", "ok"));
    let out = run_binary(home.path(), &["index", "--json"]);
    assert_eq!(out.code, 0, "stderr: {}", out.stderr);
    let first: serde_json::Value =
        serde_json::from_str(out.stdout.lines().next().unwrap()).unwrap();
    assert_eq!(first["event"], "start");
    assert_eq!(first["total"], 1);
    assert_eq!(first["full_build"], false);
}

#[test]
fn binary_usage_errors_exit_1() {
    let home = tempfile::tempdir().unwrap();
    assert_eq!(run_binary(home.path(), &[]).code, 1);
    assert_eq!(run_binary(home.path(), &["unknownverb"]).code, 1);
    assert_eq!(run_binary(home.path(), &["show"]).code, 1); // missing id
    assert_eq!(run_binary(home.path(), &["index", "extra"]).code, 1);
}

// ---------- deps wiring sanity ----------

#[test]
fn same_session_id_under_two_slugs_keeps_the_newer_file() {
    let fx = Fixture::new();
    fx.write_transcript(
        "slug-a",
        "dup",
        &simple_conversation("older variant", "ok"),
        1_000,
    );
    fx.write_transcript(
        "slug-b",
        "dup",
        &simple_conversation("newer variant", "ok"),
        2_000,
    );
    let deps = fx.deps();
    assert_eq!(search_ids(&deps, Some("newer")), vec!["dup"]);
    assert!(search_ids(&deps, Some("older")).is_empty());
    assert_eq!(search_ids(&deps, None), vec!["dup"]); // exactly one row
}
