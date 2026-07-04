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
  # is the fallback if that lookup fails (loud warning below — it resets
  # the notification permission). Same layering as install.sh: helpers and
  # app signed individually, and NO entitlements — the time-sensitive
  # entitlement is restricted, and AMFI refuses to launch a locally-signed
  # binary that carries it (RBSRequestErrorDomain Code=5 / POSIX 153; see
  # install.sh).
  sign_all() {
    local identity="$1"
    codesign --force --sign "$identity" "$APP_PATH/Contents/Helpers/shiibar-ccd"
    codesign --force --sign "$identity" "$APP_PATH/Contents/Helpers/shiibar-cc"
    codesign --force --sign "$identity" --identifier "$BUNDLE_ID" "$APP_PATH"
  }
  SIGN_ID="$(codesign -dvv "$APP_PATH" 2>&1 | awk -F'=' '/^Authority=/{print $2; exit}')"
  if [ -n "${SIGN_ID:-}" ] && [ "$SIGN_ID" != "adhoc" ]; then
    sign_all "$SIGN_ID" || {
      echo "warning: re-signing with '$SIGN_ID' failed; falling back to ad-hoc." >&2
      echo "Notification permission will reset — re-run scripts/install.sh to fix" >&2
      echo "the stable identity (DESIGN.md §4.5)." >&2
      sign_all "-"
    }
  else
    echo "warning: the installed bundle was ad-hoc signed; keeping ad-hoc." >&2
    echo "Notification permission resets on every reload like this — run" >&2
    echo "scripts/install.sh to set up the stable identity (DESIGN.md §4.5)." >&2
    sign_all "-"
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
