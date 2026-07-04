# shiibar

macOS menu bar app + CLI that tracks Claude Code agent status (idle / working / blocked / done) via hooks and jumps to the corresponding iTerm2 tab.

## Source of truth

- **Behavior spec**: `docs/DESIGN.md`. The state transition table (§3.1) IS the test spec. Protocol wire format is §4.2. Constants are §9.
- **Visual spec**: `docs/menubar-design.html` (menu bar / dropdown design).
- **Dev procedures**: `docs/DEVELOPMENT.md`.
- **Decision log**: `docs/DESIGN.md` §8. Read it BEFORE "improving" anything. The non-goals (tmux support, other agents, terminal abstraction layers, config files, launchd) are deliberate decisions with recorded reconsideration conditions. Do not implement them, even if it seems helpful.

## Rules for implementation work

- Work from the task brief in `docs/tasks/` for your milestone. Stay inside its scope.
- If the spec is ambiguous, contradictory, or wrong: **stop and report** the issue in your final summary. Do not invent behavior or silently deviate.
- Language: **Japanese is allowed ONLY in `docs/`**. Everything else — source code, code comments,
  doc comments, test names, string literals, log messages, commit messages, fixtures — MUST be English.
  When a comment needs to reference a spec rule written in Japanese, translate it to English and cite the
  section number (e.g. `// prefer a false alarm over a miss (DESIGN.md §3.1)`), do not paste the Japanese.
- Never hardcode machine-specific absolute paths (`/Users/<name>/...`, real `$HOME`) anywhere in the repo,
  including test fixtures and test cases. Use a neutral placeholder (e.g. `/Users/example/...`) or, better,
  a path built at runtime from a temp dir. Fixtures and tests must be portable across machines.
- Tests must mirror DESIGN.md §3.1 exactly (table-driven). Never weaken a test or the spec to make an implementation pass.
- All state paths go through the state dir (`SHIIBAR_STATE_DIR` override, default `~/.local/state/shiibar/`). Tests MUST use a temp state dir and never touch the real one.
- iTerm2 / AppleScript knowledge lives ONLY in the iterm module of `shiibar-client` (design principle 2).
- Do not edit `docs/DESIGN.md` §8 (decision log). Propose spec changes in your summary instead.

## Commands

```sh
cargo build                 # workspace build
cargo test                  # all tests
cargo clippy --all-targets  # keep it warning-free
SHIIBAR_LOG=debug cargo run -p shiibard -- --foreground   # run daemon with logs
```

Toolchain is pinned by `rust-toolchain.toml` (rustup picks it up automatically).
