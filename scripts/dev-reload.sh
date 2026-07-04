#!/usr/bin/env bash
# Dogfooding helper (DESIGN.md §5): rebuild debug binaries + the menu bar
# app. Two modes:
#   - No installed shiibar-cc.app (scripts/install.sh not run yet, or
#     removed): just rebuilds, and daemon lifecycle stays manual per §4.2 —
#     run `shiibar-ccd --foreground` yourself, then `swift run` the app
#     against it (it attaches instead of spawning, task brief M4 §1).
#   - An installed shiibar-cc.app exists: quits it (stopping its daemon,
#     §8.8), swaps in the freshly built binaries in place, re-signs with
#     whatever identity the bundle already used (or falls back to ad-hoc),
#     and relaunches it — a hot-swap for daily dogfooding without re-running
#     the full scripts/install.sh (which also re-bundles Info.plist etc).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${SHIIBAR_CC_APP_DIR:-$HOME/Applications}"
APP_NAME="shiibar-cc.app"
APP_PATH="$APP_DIR/$APP_NAME"
BUNDLE_ID="cc.shiibar.menubar"

echo "==> Building shiibar-ccd / shiibar-cc (debug)..."
(cd "$ROOT" && cargo build -p shiibar-ccd -p shiibar-cc)

echo "==> Building the menu bar app (debug)..."
(cd "$ROOT/app" && swift build)
APP_BIN_DIR="$(cd "$ROOT/app" && swift build --show-bin-path)"

echo
echo "Built:"
echo "  $ROOT/target/debug/shiibar-ccd"
echo "  $ROOT/target/debug/shiibar-cc"
echo "  $APP_BIN_DIR/ShiibarCCApp"

if [ -d "$APP_PATH" ]; then
  echo
  echo "==> Hot-swapping the installed $APP_NAME"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  sleep 1

  install -m 755 "$APP_BIN_DIR/ShiibarCCApp" "$APP_PATH/Contents/MacOS/ShiibarCCApp"
  install -m 755 "$ROOT/target/debug/shiibar-ccd" "$APP_PATH/Contents/Helpers/shiibar-ccd"
  install -m 755 "$ROOT/target/debug/shiibar-cc" "$APP_PATH/Contents/Helpers/shiibar-cc"

  # Re-sign with whatever this bundle was already signed with, so its
  # notification-permission identity doesn't move (DESIGN.md §4.5); ad-hoc
  # is the safe fallback if that lookup fails.
  SIGN_ID="$(codesign -dvv "$APP_PATH" 2>&1 | awk -F'=' '/^Authority=/{print $2; exit}')"
  if [ -n "${SIGN_ID:-}" ] && [ "$SIGN_ID" != "adhoc" ]; then
    codesign --force --deep --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP_PATH" || \
      codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP_PATH"
  else
    codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP_PATH"
  fi

  echo "==> Relaunching $APP_PATH"
  open "$APP_PATH"
else
  echo
  echo "No installed $APP_PATH (run scripts/install.sh, or dogfood without"
  echo "installing):"
  echo "  1. shiibar-ccd --foreground              # manual daemon, §4.2"
  echo "  2. swift run --package-path app ShiibarCCApp   # attaches, doesn't spawn"
fi
