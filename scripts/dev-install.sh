#!/usr/bin/env bash
# shiibar-cc install (M2 binaries+hooks, extended in M4 with .app bundling,
# M6 hooks distribution moved to a Claude Code plugin):
# build the menu bar app + shiibar-ccd/shiibar-cc in release mode, bundle
# them into "Shiibar CC.app" (Contents/Helpers/), ad-hoc sign with a stable
# local identity, symlink ~/.local/bin/shiibar-cc to the bundled binary,
# register the app as a Login Item (by launching it once — the app
# auto-registers via SMAppService on first launch only and never
# re-registers after a user turns it off, DESIGN.md §4.5), and print
# the two-command guidance for installing the hooks plugin.
#
# This script never touches ~/.claude/settings.json itself: hooks are
# shipped as a Claude Code plugin (this repository doubles as the
# marketplace, DESIGN.md §4.1/§8.19), so Claude Code — not this script —
# merges the plugin's hooks into the user's settings when they run
# `claude plugin install`. There is no JSON to hand-merge or print here anymore.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${SHIIBAR_CC_BIN_DIR:-$HOME/.local/bin}"
APP_DIR="${SHIIBAR_CC_APP_DIR:-$HOME/Applications}"
APP_NAME="Shiibar CC.app"
APP_PATH="$APP_DIR/$APP_NAME"
# Fresh CFBundleVersion per install: icon/metadata caches (LaunchServices,
# iconservices) key on bundle id + version, so a constant version can pin
# stale state — e.g. the pre-icon registration — forever.
BUILD_STAMP="$(date +%Y%m%d%H%M%S)"

# shellcheck source=scripts/lib/signing.sh
source "$ROOT/scripts/lib/signing.sh"
# shellcheck source=scripts/lib/bundle.sh
source "$ROOT/scripts/lib/bundle.sh"
# shellcheck source=scripts/lib/app-lifecycle.sh
source "$ROOT/scripts/lib/app-lifecycle.sh"

echo "==> Building shiibar-ccd / shiibar-cc (release)..."
(cd "$ROOT" && cargo build --release -p shiibar-ccd -p shiibar-cc)

echo "==> Building the menu bar app (release)..."
(cd "$ROOT/app" && swift build -c release)
APP_BIN_DIR="$(cd "$ROOT/app" && swift build -c release --show-bin-path)"

# A reinstall over a running app must stop it first: the `open` at the end
# only foregrounds an already-running instance (it never restarts it), so
# the old process would keep serving a stale bundle — and its surviving
# daemon would keep running the old binary image (stop_app_and_daemon,
# scripts/lib/app-lifecycle.sh). A fresh install has nothing to stop and
# this is a fast no-op.
echo "==> Stopping the running app/daemon (if any)"
stop_app_and_daemon "$APP_PATH"

echo "==> Assembling $APP_PATH"
# CFBundleShortVersionString: the workspace version with a -dev suffix, so a
# locally built bundle is distinguishable from a release build in the About
# panel (release builds pass the bare number via build-release-app.sh).
# CFBundleVersion stays a per-install timestamp for the cache-busting reason
# above. assemble_app_bundle (scripts/lib/bundle.sh) also generates the icon.
SHORT_VERSION="$(read_workspace_version "$ROOT/Cargo.toml")-dev"
assemble_app_bundle \
  "$APP_PATH" \
  "$APP_BIN_DIR/ShiibarCcApp" \
  "$ROOT/target/release/shiibar-ccd" \
  "$ROOT/target/release/shiibar-cc" \
  "$SHORT_VERSION" \
  "$BUILD_STAMP"

echo "==> Code signing (stable local identity, so rebuilds don't reset notification permission — DESIGN.md §4.5)"
SIGN_ID="$(find_signing_identity || true)"
if [ -z "$SIGN_ID" ]; then
  echo "    no existing '$SIGNING_IDENTITY_CN' codesigning identity — creating one (one-time; see scripts/lib/make-local-signing-identity.sh)."
  "$ROOT/scripts/lib/make-local-signing-identity.sh" "$SIGNING_IDENTITY_CN" || true
  SIGN_ID="$(find_signing_identity || true)"
fi

# NO entitlements are requested. com.apple.developer.usernotifications.
# time-sensitive is a *restricted* entitlement: without an Apple-issued
# provisioning profile, AMFI refuses to spawn a binary that carries it
# (launch fails with RBSRequestErrorDomain Code=5 / POSIX 153 — confirmed
# on a real install). Locally-signed builds therefore ship without it; the
# app still sets the time-sensitive interruption level at runtime, which
# the system silently downgrades to a normal alert when unentitled
# (DESIGN.md §4.5's Focus/DND breakthrough just doesn't apply to this
# local, non-distributed build). Signing itself (helpers first, bundle last)
# lives in sign_app_bundle (scripts/lib/bundle.sh); no extra flags here, so
# the local build gets a plain signature (no hardened runtime / timestamp).

# A missing stable identity is a hard error by default: silently falling
# back to ad-hoc would reset the notification permission on every rebuild,
# defeating the whole point (DESIGN.md §4.5). Escape hatch for a conscious
# choice: SHIIBAR_CC_ALLOW_ADHOC=1.
if [ -n "$SIGN_ID" ]; then
  sign_app_bundle "$SIGN_ID" "$APP_PATH"
  echo "    signed with local identity $SIGN_ID"
  echo "    note: the first launch may show a keychain prompt asking to let"
  echo "    codesign/the app use the signing key — choose 'Always Allow'."
elif [ "${SHIIBAR_CC_ALLOW_ADHOC:-0}" = "1" ]; then
  echo "    warning: SHIIBAR_CC_ALLOW_ADHOC=1 — signing ad-hoc. Notification" >&2
  echo "    permission will reset on the next rebuild (DESIGN.md §4.5)." >&2
  sign_app_bundle "-" "$APP_PATH"
else
  echo "error: no stable '$SIGNING_IDENTITY_CN' codesigning identity is available," >&2
  echo "and creating one failed (see the messages above from" >&2
  echo "scripts/lib/make-local-signing-identity.sh for what to fix — typically the" >&2
  echo "certificate trust step in Keychain Access)." >&2
  echo >&2
  echo "Re-run this script after fixing it, or, to consciously accept ad-hoc" >&2
  echo "signing (notification permission resets on every rebuild):" >&2
  echo "  SHIIBAR_CC_ALLOW_ADHOC=1 scripts/dev-install.sh" >&2
  exit 1
fi

echo "==> Pointing $BIN_DIR/shiibar-cc / shiibar-ccd at the bundled binaries"
mkdir -p "$BIN_DIR"
rm -f "$BIN_DIR/shiibar-cc" "$BIN_DIR/shiibar-ccd"
ln -s "$APP_PATH/Contents/Helpers/shiibar-cc" "$BIN_DIR/shiibar-cc"
ln -s "$APP_PATH/Contents/Helpers/shiibar-ccd" "$BIN_DIR/shiibar-ccd"

echo
echo "Installed:"
echo "  $APP_PATH"
echo "  $BIN_DIR/shiibar-cc -> $APP_PATH/Contents/Helpers/shiibar-cc"
echo "  $BIN_DIR/shiibar-ccd -> $APP_PATH/Contents/Helpers/shiibar-ccd"

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
PLUGIN_KEY="shiibar-cc@shiibar-cc"

plugin_installed=0
if [ -f "$SETTINGS" ]; then
  if command -v jq >/dev/null 2>&1; then
    if [ "$(jq -r --arg k "$PLUGIN_KEY" '.enabledPlugins[$k] // false' "$SETTINGS" 2>/dev/null)" = "true" ]; then
      plugin_installed=1
    fi
  elif grep -q "\"$PLUGIN_KEY\"[[:space:]]*:[[:space:]]*true" "$SETTINGS" 2>/dev/null; then
    plugin_installed=1
  fi
fi

echo
echo "==> hooks setup"
if [ "$plugin_installed" -eq 1 ]; then
  echo "$PLUGIN_KEY is already enabled in $SETTINGS — nothing to do."
else
  echo "Install the hooks plugin (this repository is its own marketplace,"
  echo "DESIGN.md §4.1):"
  echo
  echo "  claude plugin marketplace add bufferings/shiibar-cc"
  echo "  claude plugin install shiibar-cc@shiibar-cc"
fi

echo
echo "==> Re-registering with LaunchServices (icon cache, DEVELOPMENT.md's"
echo "    icon notes item 5 — harmless no-op if lsregister isn't at this path)"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -f "$APP_PATH"
else
  echo "    $LSREGISTER not found — skipping (install continues)"
fi

echo
echo "==> app / daemon"
echo "Launching $APP_PATH once (registers it as a Login Item and starts the"
echo "daemon, DESIGN.md §4.5/§8.8 — no more manual 'shiibar-ccd --foreground')."
open "$APP_PATH"
echo
echo "Then check everything end to end with:"
echo "  $BIN_DIR/shiibar-cc doctor"
echo
echo "First launch: macOS will prompt for a notification permission and,"
echo "the first time focus/reconcile runs osascript against iTerm2, an"
echo "Automation permission prompt. Grant both — see menubar-design.html"
echo "for what a denied/disconnected state looks like in the dropdown."
