#!/usr/bin/env bash
# Stages demo sessions for the README screenshots (or any visual check):
# replays fake hook JSON into the REAL daemon (the fake-replay technique in
# DEVELOPMENT.md's hooks section) so the dropdown shows a waiting / working /
# idle mix without arranging real sessions.
#
# NOTE: the app's periodic reconcile prunes these fake sessions within ~60s
# (they don't exist in `claude agents`). Stage, then shoot immediately.
# Re-run `stage` any time; run `cleanup` when done (or just let reconcile
# eat them).
set -euo pipefail

U_WAIT="d3b07384-0000-4000-8000-aaaaaaaaaaa1"
U_WORK="d3b07384-0000-4000-8000-aaaaaaaaaaa2"
U_IDLE="d3b07384-0000-4000-8000-aaaaaaaaaaa3"
U_BANR="d3b07384-0000-4000-8000-aaaaaaaaaaa4"

report() { # report <slot(wNtNpN)> <uuid> <event> <json>
  TERM_PROGRAM="iTerm.app" ITERM_SESSION_ID="$1:$2" \
    shiibar-cc report "$3" <<<"$4" >/dev/null
}

start_and_prompt() { # <slot> <uuid> <cwd> <prompt>
  report "$1" "$2" SessionStart "{\"session_id\":\"$2\",\"cwd\":\"$3\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}"
  report "$1" "$2" UserPromptSubmit "{\"session_id\":\"$2\",\"cwd\":\"$3\",\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"$4\"}"
}

case "${1:-}" in
stage)
  # working: spinner glyph cycling
  start_and_prompt w0t1p0 "$U_WORK" "/Users/example/projects/blog" \
    "Draft a post about the new release pipeline"
  # idle, reviewed (no badge): finished and seen
  start_and_prompt w0t2p0 "$U_IDLE" "/Users/example/projects/dotfiles" \
    "Clean up the zsh aliases"
  report w0t2p0 "$U_IDLE" Stop "{\"session_id\":\"$U_IDLE\",\"cwd\":\"/Users/example/projects/dotfiles\",\"hook_event_name\":\"Stop\",\"background_tasks\":[],\"last_assistant_message\":\"Done — removed 12 stale aliases.\"}"
  shiibar-cc seen "$U_IDLE" >/dev/null
  # waiting + unreviewed (red badge). Staged last: its banner pops ~3s later
  start_and_prompt w0t3p0 "$U_WAIT" "/Users/example/projects/shiibar-cc" \
    "Run the release checklist"
  report w0t3p0 "$U_WAIT" Notification "{\"session_id\":\"$U_WAIT\",\"cwd\":\"/Users/example/projects/shiibar-cc\",\"hook_event_name\":\"Notification\",\"notification_type\":\"permission_prompt\",\"message\":\"Claude needs your permission to use Bash\"}"
  echo "Staged. Shoot the dropdown NOW (reconcile prunes these in ~60s)."
  echo "A waiting banner (with sound) pops in ~3s — dismiss it or use it."
  ;;
banner)
  start_and_prompt w0t4p0 "$U_BANR" "/Users/example/projects/shiibar-cc" \
    "Update the README screenshots"
  report w0t4p0 "$U_BANR" Stop "{\"session_id\":\"$U_BANR\",\"cwd\":\"/Users/example/projects/shiibar-cc\",\"hook_event_name\":\"Stop\",\"background_tasks\":[],\"last_assistant_message\":\"Both screenshots are updated and the README renders nicely.\"}"
  echo "Completion banner pops in ~3s. Shoot it."
  ;;
cleanup)
  for u in "$U_WAIT" "$U_WORK" "$U_IDLE" "$U_BANR"; do
    shiibar-cc remove "$u" >/dev/null 2>&1 || true
  done
  echo "Removed the fake sessions."
  ;;
*)
  echo "usage: dev-demo.sh stage|banner|cleanup" >&2
  exit 1
  ;;
esac
