#!/usr/bin/env bash
# shiibar M2 install: build shiibard/shiibarctl in release mode, place them
# (plus hooks/report.sh) under ~/.local/bin, and print hooks-configuration
# guidance. DESIGN.md §5 / §4.5 for what belongs here vs. M4:
#   - M2 (this script): binaries + hooks only. daemon lifecycle is manual
#     (`shiibard --foreground`, DESIGN.md §8.8) until the menu bar app
#     exists.
#   - M4: .app bundling, Login Items, and switching the CLI symlink target
#     to the .app's embedded binaries (DESIGN.md §4.5 "bundling").
#
# Deliberately does NOT touch ~/.claude/settings.json: merging hooks into
# a user's existing settings safely (preserving unrelated hooks/config,
# never producing invalid JSON) needs a real JSON merge, and bash has no
# reliable dependency-free way to do that. See the M2 completion report
# for this decision. This script only prints the snippet and a suggested
# copy-paste path.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${SHIIBAR_BIN_DIR:-$HOME/.local/bin}"

echo "==> Building shiibard / shiibarctl (release)..."
(cd "$ROOT" && cargo build --release -p shiibard -p shiibarctl)

echo "==> Installing to $BIN_DIR"
mkdir -p "$BIN_DIR"
install -m 755 "$ROOT/target/release/shiibard" "$BIN_DIR/shiibard"
install -m 755 "$ROOT/target/release/shiibarctl" "$BIN_DIR/shiibarctl"
install -m 755 "$ROOT/hooks/report.sh" "$BIN_DIR/report.sh"

echo
echo "Installed:"
echo "  $BIN_DIR/shiibard"
echo "  $BIN_DIR/shiibarctl"
echo "  $BIN_DIR/report.sh"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo
    echo "warning: $BIN_DIR is not on your PATH."
    echo "Add this to your shell profile:"
    echo "  export PATH=\"$BIN_DIR:\$PATH\""
    ;;
esac

SETTINGS="$HOME/.claude/settings.json"
echo
echo "==> hooks setup (manual step)"
if [ -f "$SETTINGS" ] && grep -q "report.sh" "$SETTINGS" 2>/dev/null; then
  echo "$SETTINGS already references report.sh — nothing to do."
else
  echo "Merge $ROOT/hooks/settings-snippet.json into $SETTINGS by hand"
  echo "(this script never edits it automatically, to avoid corrupting your"
  echo "existing hooks/config). The snippet:"
  echo
  cat "$ROOT/hooks/settings-snippet.json"
  echo
  if [ ! -f "$SETTINGS" ]; then
    echo "No $SETTINGS exists yet — you can just copy the snippet above to that path."
  elif command -v jq >/dev/null 2>&1; then
    echo "You have jq; a one-shot deep merge (review the result before trusting it):"
    echo "  jq -s '.[0] * .[1]' \"$SETTINGS\" \"$ROOT/hooks/settings-snippet.json\" > /tmp/shiibar-settings.json"
    echo "  diff \"$SETTINGS\" /tmp/shiibar-settings.json  # review"
    echo "  mv /tmp/shiibar-settings.json \"$SETTINGS\""
  fi
fi

echo
echo "==> daemon"
echo "shiibar has no launchd/background service yet (M2): start it manually"
echo "in a terminal you keep around, e.g. in an iTerm2 tab:"
echo "  $BIN_DIR/shiibard --foreground"
echo
echo "Then check everything end to end with:"
echo "  $BIN_DIR/shiibarctl doctor"
