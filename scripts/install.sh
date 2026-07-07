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
# `/plugin install`. There is no JSON to hand-merge or print here anymore.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${SHIIBAR_CC_BIN_DIR:-$HOME/.local/bin}"
APP_DIR="${SHIIBAR_CC_APP_DIR:-$HOME/Applications}"
APP_NAME="Shiibar CC.app"
APP_PATH="$APP_DIR/$APP_NAME"
BUNDLE_ID="cc.shiibar.menubar"
# Fresh CFBundleVersion per install: icon/metadata caches (LaunchServices,
# iconservices) key on bundle id + version, so a constant version can pin
# stale state — e.g. the pre-icon registration — forever.
BUILD_STAMP="$(date +%Y%m%d%H%M%S)"

# shellcheck source=scripts/lib/signing.sh
source "$ROOT/scripts/lib/signing.sh"

echo "==> Building shiibar-ccd / shiibar-cc (release)..."
(cd "$ROOT" && cargo build --release -p shiibar-ccd -p shiibar-cc)

echo "==> Building the menu bar app (release)..."
(cd "$ROOT/app" && swift build -c release)
APP_BIN_DIR="$(cd "$ROOT/app" && swift build -c release --show-bin-path)"

echo "==> Assembling $APP_PATH"
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Helpers"

install -m 755 "$APP_BIN_DIR/ShiibarCcApp" "$APP_PATH/Contents/MacOS/ShiibarCcApp"
install -m 755 "$ROOT/target/release/shiibar-ccd" "$APP_PATH/Contents/Helpers/shiibar-ccd"
install -m 755 "$ROOT/target/release/shiibar-cc" "$APP_PATH/Contents/Helpers/shiibar-cc"

cat > "$APP_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>ShiibarCcApp</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleName</key>
	<string>Shiibar CC</string>
	<key>CFBundleDisplayName</key>
	<string>Shiibar CC</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>$BUILD_STAMP</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>Personal tool, not distributed.</string>
</dict>
</plist>
PLIST

echo "==> Generating app icon (DESIGN.md §4.5, docs/tasks/M5.md T10)"
ICON_WORKDIR="$(mktemp -d)"
trap 'rm -rf "$ICON_WORKDIR"' EXIT
swift "$ROOT/scripts/generate-app-icon.swift" "$ICON_WORKDIR"
iconutil -c icns "$ICON_WORKDIR/AppIcon.iconset" -o "$ICON_WORKDIR/AppIcon.icns"
mkdir -p "$APP_PATH/Contents/Resources"
install -m 644 "$ICON_WORKDIR/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"

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
# local, non-distributed build).
sign_all() {
  local identity="$1"
  codesign --force --sign "$identity" "$APP_PATH/Contents/Helpers/shiibar-ccd"
  codesign --force --sign "$identity" "$APP_PATH/Contents/Helpers/shiibar-cc"
  codesign --force --sign "$identity" --identifier "$BUNDLE_ID" "$APP_PATH"
}

# A missing stable identity is a hard error by default: silently falling
# back to ad-hoc would reset the notification permission on every rebuild,
# defeating the whole point (DESIGN.md §4.5). Escape hatch for a conscious
# choice: SHIIBAR_CC_ALLOW_ADHOC=1.
if [ -n "$SIGN_ID" ]; then
  sign_all "$SIGN_ID"
  echo "    signed with local identity $SIGN_ID"
  echo "    note: the first launch may show a keychain prompt asking to let"
  echo "    codesign/the app use the signing key — choose 'Always Allow'."
elif [ "${SHIIBAR_CC_ALLOW_ADHOC:-0}" = "1" ]; then
  echo "    warning: SHIIBAR_CC_ALLOW_ADHOC=1 — signing ad-hoc. Notification" >&2
  echo "    permission will reset on the next rebuild (DESIGN.md §4.5)." >&2
  sign_all "-"
else
  echo "error: no stable '$SIGNING_IDENTITY_CN' codesigning identity is available," >&2
  echo "and creating one failed (see the messages above from" >&2
  echo "scripts/lib/make-local-signing-identity.sh for what to fix — typically the" >&2
  echo "certificate trust step in Keychain Access)." >&2
  echo >&2
  echo "Re-run this script after fixing it, or, to consciously accept ad-hoc" >&2
  echo "signing (notification permission resets on every rebuild):" >&2
  echo "  SHIIBAR_CC_ALLOW_ADHOC=1 scripts/install.sh" >&2
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
  echo "Install the hooks plugin from inside a Claude Code session (this"
  echo "repository is its own marketplace, DESIGN.md §4.1):"
  echo
  echo "  /plugin marketplace add bufferings/shiibar-cc"
  echo "  /plugin install shiibar-cc@shiibar-cc"
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
