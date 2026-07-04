#!/usr/bin/env bash
# Optional dogfooding helper (DESIGN.md §5, M2): rebuild debug binaries and
# tell you to restart the manually-run `shiibard --foreground` (daemon
# lifecycle is deliberately manual until M4's menu bar app, §8.8 — this
# script does not kill/respawn it for you, since that's usually running in
# a terminal tab you're watching logs in).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Building shiibard / shiibarctl (debug)..."
(cd "$ROOT" && cargo build -p shiibard -p shiibarctl)

echo
echo "Built:"
echo "  $ROOT/target/debug/shiibard"
echo "  $ROOT/target/debug/shiibarctl"
echo
echo "If shiibard --foreground is running, Ctrl-C it and re-run it to pick"
echo "up the new build (state.json / sessions.jsonl persist across restarts)."
