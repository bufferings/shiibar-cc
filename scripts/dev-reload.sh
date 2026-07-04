#!/usr/bin/env bash
# Optional dogfooding helper (DESIGN.md §5, M2): rebuild debug binaries and
# tell you to restart the manually-run `shiibar-ccd --foreground` (daemon
# lifecycle is deliberately manual until M4's menu bar app, §8.8 — this
# script does not kill/respawn it for you, since that's usually running in
# a terminal tab you're watching logs in).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Building shiibar-ccd / shiibar-cc (debug)..."
(cd "$ROOT" && cargo build -p shiibar-ccd -p shiibar-cc)

echo
echo "Built:"
echo "  $ROOT/target/debug/shiibar-ccd"
echo "  $ROOT/target/debug/shiibar-cc"
echo
echo "If shiibar-ccd --foreground is running, Ctrl-C it and re-run it to pick"
echo "up the new build (state.json / sessions.jsonl persist across restarts)."
