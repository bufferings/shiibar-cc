# shiibar-cc

macOS menu bar app + CLI that tracks Claude Code agent status (working / waiting / idle, plus an unreviewed flag) via hooks and jumps to the corresponding iTerm2 tab.

## Source of truth

- **Behavior spec**: `docs/DESIGN.md`. The state transition table (§3.4) IS the test spec. Protocol wire format is §4.2. Constants are §9.
- **Visual spec**: `docs/menubar-design.html` (menu bar / dropdown design).
- **Dev procedures**: `docs/DEVELOPMENT.md`.
- **Decision log**: `docs/DESIGN.md` §8. Read it BEFORE "improving" anything. The non-goals (tmux support, other agents, terminal abstraction layers, config files, launchd) are deliberate decisions with recorded reconsideration conditions. Do not implement them, even if it seems helpful.

## Rules for implementation work

- Work from the task brief in `docs/tasks/` for your milestone. Stay inside its scope.
  Briefs with a completed Status line at the top are historical records — never re-execute them.
- If the spec is ambiguous, contradictory, or wrong: **stop and report** the issue in your final summary. Do not invent behavior or silently deviate.
- Language: **Japanese is allowed ONLY in `docs/`**. Everything else — source code, code comments,
  doc comments, test names, string literals, log messages, commit messages, fixtures — MUST be English.
  When a comment needs to reference a spec rule written in Japanese, translate it to English and cite the
  section number (e.g. `// prefer a false alarm over a miss (DESIGN.md §3.4)`), do not paste the Japanese.
- Never hardcode machine-specific absolute paths (`/Users/<name>/...`, real `$HOME`) anywhere in the repo,
  including test fixtures and test cases. Use a neutral placeholder (e.g. `/Users/example/...`) or, better,
  a path built at runtime from a temp dir. Fixtures and tests must be portable across machines.
- Tests must mirror DESIGN.md §3.4 exactly (table-driven). Never weaken a test or the spec to make an implementation pass.
- All state paths go through the state dir (`SHIIBAR_CC_STATE_DIR` override, default `~/.local/state/shiibar-cc/`). Tests MUST use a temp state dir and never touch the real one.
- iTerm2 / AppleScript knowledge lives ONLY in the iterm module of `shiibar-cc-client` (design principle 2).
- Do not edit `docs/DESIGN.md` §8 (decision log). Propose spec changes in your summary instead.

## Rules for documentation work

- **Write for the repo-only reader.** Every sentence in a doc must be meaningful to someone who sees
  nothing but this repository. Before writing a sentence, ask: "what can a repo-only reader do with this?"
  If the answer is nothing, don't write it.
- Concretely, never write: references to superseded or never-implemented past designs; doc version
  numbers ("v1", "2nd edition") or revision-history phrasing ("changed from...", "fully revised");
  pointers to artifacts outside the repo (session mockups, conversations); deictic phrasing that only
  works inside a conversation ("this time", "as discussed"). Docs state the current agreed content,
  in present tense.
  Exceptions: `docs/DESIGN.md` §8 (decision log — history is its purpose) and completed migration
  briefs in `docs/tasks/` where the transition itself is the subject.
- **After ANY doc edit** (`docs/`, `CLAUDE.md`, READMEs), before committing: have a separate review
  agent check the changed docs against this section (repo-only reader test, plus stale cross-references
  to files/sections that no longer exist). Do not skip this because the change "looks trivial".

## Don't trust your training knowledge for anything versioned or external

Your knowledge has a cutoff months in the past. Crate versions, Rust releases, macOS/AppleScript
behavior, and especially the Claude Code hook payload spec all move. Never state a version, API shape,
or hook-field fact from memory — verify against the real thing and cite how you checked:

- Crate / toolchain versions: `cargo search <crate>`, `Cargo.lock`, `rustup check` — not recall.
- Claude Code hook payloads (event names, fields like `notification_type` / `background_tasks` /
  `source`, whether `PostToolUseFailure` fires): confirm against captured real payloads in `fixtures/`
  or current official docs, not memory. See DESIGN.md §7-3 for the fields still pending real-log checks.
- When you can't verify, say so explicitly rather than asserting — don't call something "latest" or
  "correct" from training data.

## Commands

```sh
cargo build                 # workspace build
cargo test                  # all tests
cargo clippy --all-targets  # keep it warning-free
(cd app && swift build)     # menu bar app build (CLT is enough)
(cd app && swift test)      # app unit tests (requires full Xcode, not just CLT)
SHIIBAR_CC_LOG=debug cargo run -p shiibar-ccd -- --foreground   # run daemon with logs
```

Toolchain is pinned by `rust-toolchain.toml` (rustup picks it up automatically).
