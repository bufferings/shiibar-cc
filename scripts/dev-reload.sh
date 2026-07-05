#!/usr/bin/env bash
# Dogfooding helper (DESIGN.md §5): rebuild debug binaries + the menu bar
# app. Two modes:
#   - No installed shiibar-cc.app (scripts/install.sh not run yet, or
#     removed): just rebuilds, and daemon lifecycle stays manual per §4.2 —
#     run `shiibar-ccd --foreground` yourself, then `swift run` the app
#     against it (it attaches instead of spawning, task brief M4 §1).
#   - An installed shiibar-cc.app exists: quits it, makes sure its daemon is
#     really gone (see the comment at the quit block for why this script owns
#     that), swaps in the freshly built binaries in place, re-signs with the
#     stable local identity from the keychain (or falls back to ad-hoc),
#     and relaunches it — a hot-swap for daily dogfooding without re-running
#     the full scripts/install.sh (which also re-bundles Info.plist etc).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${SHIIBAR_CC_APP_DIR:-$HOME/Applications}"
APP_NAME="shiibar-cc.app"
APP_PATH="$APP_DIR/$APP_NAME"
BUNDLE_ID="cc.shiibar.menubar"

# shellcheck source=scripts/lib/signing.sh
source "$ROOT/scripts/lib/signing.sh"

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

  # Poll until no process matches the pgrep -f pattern in $1, checking every
  # 0.2s for up to $2 attempts. Returns 0 once nothing matches, 1 if
  # something still matches after the last attempt.
  wait_for_gone() {
    local pattern="$1" attempts="$2" i
    for ((i = 0; i < attempts; i++)); do
      if ! pgrep -f "$pattern" >/dev/null 2>&1; then
        return 0
      fi
      sleep 0.2
    done
    ! pgrep -f "$pattern" >/dev/null 2>&1
  }

  # Quitting the app does NOT reliably stop its daemon, so this script owns
  # daemon termination. "App quit stops the daemon" (DESIGN.md §8.8) is
  # implemented as a fire-and-forget shutdown send from
  # applicationShouldTerminate, which immediately returns .terminateNow —
  # the async send races process exit and can lose (observed on-device: the
  # daemon survived two dev-reloads in a row). A surviving daemon means the
  # relaunched app ATTACHES to a process still running the pre-swap binary
  # image, and the reload silently does nothing for the daemon. So: quit the
  # app, then make sure the daemon is really gone before swapping binaries —
  # graceful socket shutdown ({"cmd":"shutdown"}, DESIGN.md §4.2) first,
  # then SIGTERM, then SIGKILL. Force-killing is safe: the daemon persists
  # state.json on every mutation, and on startup it handles a pre-existing
  # socket file (connect test -> no answer -> take over; both §4.2).
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  APP_EXE_PATTERN="$APP_PATH/Contents/MacOS/ShiibarCCApp"
  if ! wait_for_gone "$APP_EXE_PATTERN" 25; then
    echo "warning: the app is still running 5s after the quit AppleEvent;" >&2
    echo "continuing anyway (the binary swap below does not need it gone," >&2
    echo "but the relaunch at the end may just foreground the old instance)." >&2
  fi

  STATE_DIR="${SHIIBAR_CC_STATE_DIR:-$HOME/.local/state/shiibar-cc}"
  SOCK="$STATE_DIR/shiibar-ccd.sock"
  DAEMON_PATTERN="$APP_PATH/Contents/Helpers/shiibar-ccd"
  if [ -S "$SOCK" ]; then
    printf '{"cmd":"shutdown"}\n' | nc -U -w 2 "$SOCK" >/dev/null 2>&1 || true
  fi
  if ! wait_for_gone "$DAEMON_PATTERN" 15; then
    echo "warning: the daemon is still running after the graceful shutdown" >&2
    echo "request; sending SIGTERM." >&2
    pkill -f "$DAEMON_PATTERN" 2>/dev/null || true
    if ! wait_for_gone "$DAEMON_PATTERN" 10; then
      echo "warning: the daemon survived SIGTERM; sending SIGKILL. State is" >&2
      echo "safe: state.json is persisted on every mutation (DESIGN.md §4.2)." >&2
      # shellcheck disable=SC2046 -- word-splitting the PID list is intended
      kill -9 $(pgrep -f "$DAEMON_PATTERN" || true) 2>/dev/null || true
    fi
  fi

  install -m 755 "$APP_BIN_DIR/ShiibarCCApp" "$APP_PATH/Contents/MacOS/ShiibarCCApp"
  install -m 755 "$ROOT/target/debug/shiibar-ccd" "$APP_PATH/Contents/Helpers/shiibar-ccd"
  install -m 755 "$ROOT/target/debug/shiibar-cc" "$APP_PATH/Contents/Helpers/shiibar-cc"

  # Re-sign with the stable local identity looked up from the keychain by
  # common name (scripts/lib/signing.sh — same lookup scripts/install.sh
  # uses), NOT by reading the identity back off this bundle. Reading it off
  # the bundle used to be how this worked, and it was broken: by this point
  # the `install` calls above have already swapped in freshly built
  # binaries, and on Apple Silicon the toolchain ad-hoc-signs every fresh
  # build (`codesign -dvv` on a fresh swift/cargo build output shows
  # `Signature=adhoc`, `flags=0x20002(adhoc,linker-signed)` — no `Authority=`
  # line). So a post-swap `codesign -dvv "$APP_PATH"` lookup always came back
  # empty, meaning this script ALWAYS took the "ad-hoc" branch below and
  # re-signed ad-hoc — resetting the notification permission on every single
  # reload regardless of whether a stable identity existed, and doing so
  # silently (the "installed bundle was ad-hoc signed" warning is a lie the
  # moment a stable identity actually exists in the keychain). Worse, it was
  # sticky: once a bundle had been re-signed ad-hoc this way, a bundle-derived
  # lookup could never see the stable identity again on a later run, even
  # though it was still sitting in the keychain the whole time. Looking the
  # identity up in the keychain instead sidesteps all of that.
  #
  # Same layering as install.sh: helpers and app signed individually, and NO
  # entitlements — the time-sensitive entitlement is restricted, and AMFI
  # refuses to launch a locally-signed binary that carries it
  # (RBSRequestErrorDomain Code=5 / POSIX 153; see install.sh).
  sign_all() {
    local identity="$1"
    codesign --force --sign "$identity" "$APP_PATH/Contents/Helpers/shiibar-ccd"
    codesign --force --sign "$identity" "$APP_PATH/Contents/Helpers/shiibar-cc"
    codesign --force --sign "$identity" --identifier "$BUNDLE_ID" "$APP_PATH"
  }
  SIGN_ID="$(find_signing_identity || true)"
  if [ -n "$SIGN_ID" ]; then
    sign_all "$SIGN_ID" || {
      echo "warning: re-signing with '$SIGN_ID' failed; falling back to ad-hoc." >&2
      echo "Notification permission will reset — re-run scripts/install.sh to fix" >&2
      echo "the stable identity (DESIGN.md §4.5)." >&2
      sign_all "-"
    }
  else
    echo "warning: no stable '$SIGNING_IDENTITY_CN' codesigning identity exists" >&2
    echo "in the keychain; signing ad-hoc. Notification permission will reset on" >&2
    echo "every reload like this — run scripts/install.sh to set up the stable" >&2
    echo "identity (DESIGN.md §4.5)." >&2
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
