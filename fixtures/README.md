# fixtures/ — hook payload provenance

Real Claude Code hook payloads, captured on a live machine on 2026-07-05
(a dedicated capture session driving each event on purpose; see
DESIGN.md §7-3 for what the capture campaign verified). The daemon's
integration tests (`crates/shiibar-ccd/tests/fixtures_replay.rs` and
friends) replay these through the same extraction pipeline the real
`shiibar-cc report` uses.

Sanitization applied to every captured file (CLAUDE.md rules — fixtures
must be portable and English-only); everything not listed here is
byte-real, including field order and fields shiibar-cc ignores
(`prompt_id`, `permission_mode`, `effort`, `tool_use_id`,
`stop_hook_active`, `session_crons`, `model`, ... — they prove
forward-compat ignoring works):

- The capture machine's real home directory was rewritten to
  `/Users/example` (also in the `-Users-example-...` transcript-path slug
  form) in every path-bearing value: `cwd`, `transcript_path`,
  `tool_input.command`, error text.
- Japanese string values translated to English, preserving meaning and
  shape: `prompt` in `user_prompt_submit.json`, `last_assistant_message`
  in both `stop_*.json` files. All other values were already English.
- The nonexistent target path in `post_tool_use_failure.json`'s
  `tool_input.file_path` was renamed to a neutral English path
  (`/no/such/path.txt`); the `error` text does not reference it.

| fixture | provenance |
| --- | --- |
| `session_start_startup.json` | captured 2026-07-05 (`SessionStart-111508-2347`) |
| `session_start_clear.json` | captured 2026-07-05 (`SessionStart-112046-2746`, fired by `/clear`) |
| `session_start_compact.json` | captured 2026-07-05 (`SessionStart-112222-2839`, fired by `/compact`) |
| `session_end.json` | captured 2026-07-05 (`SessionEnd-112233-2848`, `reason: "other"`) |
| `session_end_clear.json` | captured 2026-07-05 (`SessionEnd-112046-2735`, `reason: "clear"` — the SessionEnd half of a `/clear`) |
| `user_prompt_submit.json` | captured 2026-07-05 (`UserPromptSubmit-111518-2362`; prompt translated) |
| `post_tool_use.json` | captured 2026-07-05 (`PostToolUse-111523-2477`, Bash `ls`) |
| `post_tool_use_failure.json` | captured 2026-07-05 (`PostToolUseFailure-111547-2534`, Read of a nonexistent file). Note: real PostToolUseFailure payloads carry the failure text in an `error` field and have NO `tool_response` (all three captures agree); the Read capture was chosen over the Bash ones because its `error` text is self-contained |
| `notification_permission_prompt.json` | captured 2026-07-05 (`Notification-111544-2527`) |
| `notification_idle_prompt.json` | captured 2026-07-05 (`Notification-111755-2661`) |
| `notification_auth_success.json` | **hand-written, pending capture** — no `auth_success` notification was observed in the 2026-07-05 capture session |
| `stop_no_background_tasks.json` | captured 2026-07-05 (`Stop-111529-2484`, `background_tasks: []`; message translated) |
| `stop_with_background_tasks.json` | captured 2026-07-05 (`Stop-111655-2638`, one real background task: `id`/`type`/`status`/`description`/`command`; message translated) |
