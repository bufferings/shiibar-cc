#!/bin/sh
# Thin wrapper invoked by Claude Code hooks (see settings-snippet.json).
# All parsing/normalization/target-generation happens in `shiibar-cc report`
# (Rust) — this script only forwards stdin and the event name. No external
# tools (nc/jq) are used (DESIGN.md §4.1, §8.6).
#
# Must never disturb Claude Code: if `shiibar-cc` isn't on PATH, or it
# fails for any reason, this script still exits 0.

event="$1"

if ! command -v shiibar-cc >/dev/null 2>&1; then
    exit 0
fi

shiibar-cc report "$event" || true
exit 0
