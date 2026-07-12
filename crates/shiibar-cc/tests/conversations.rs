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
    assert_eq!(events.first(), Some(&ProgressEvent::Start { total: 1 }));
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
    db.reset_progress(7).unwrap(); // done=0 / total=7
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
        relayed.contains(&ProgressEvent::Start { total: 7 }),
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
        &simple_conversation("find this marker", "ok"),
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
    assert_eq!(v["session_id"], "abc-123");
    assert_eq!(v["messages"][0]["seq"], 0);
    assert_eq!(v["messages"][0]["role"], "user");
    assert_eq!(v["messages"][0]["text"], "the question");
    assert_eq!(v["messages"][1]["role"], "assistant");

    let missing = run_binary(home.path(), &["show", "no-such-id"]);
    assert_eq!(missing.code, 2);
    assert!(!missing.stderr.is_empty());
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
    let last = events.last().unwrap();
    assert_eq!(last["event"], "done");
    assert_eq!(last["indexed"], 1);
    assert_eq!(last["removed"], 0);
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
