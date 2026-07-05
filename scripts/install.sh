#!/usr/bin/env bash
# shiibar-cc install (M2 binaries+hooks, extended in M4 with .app bundling):
# build the menu bar app + shiibar-ccd/shiibar-cc in release mode, bundle
# them into ShiibarCC.app (Contents/Helpers/), ad-hoc sign with a stable
# local identity, symlink ~/.local/bin/shiibar-cc to the bundled binary,
# register the app as a Login Item (by launching it once — the app
# auto-registers via SMAppService on first launch only and never
# re-registers after a user turns it off, DESIGN.md §4.5), and print
# hooks configuration guidance.
#
# Deliberately does NOT touch ~/.claude/settings.json: merging hooks into
# a user's existing settings safely (preserving unrelated hooks/config,
# never producing invalid JSON) needs a real JSON merge, and bash has no
# reliable dependency-free way to do that. See the M2 completion report
# for this decision. This script only prints the snippet and a suggested
# copy-paste path.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${SHIIBAR_CC_BIN_DIR:-$HOME/.local/bin}"
APP_DIR="${SHIIBAR_CC_APP_DIR:-$HOME/Applications}"
APP_NAME="ShiibarCC.app"
APP_PATH="$APP_DIR/$APP_NAME"
OLD_APP_PATH="$APP_DIR/shiibar-cc.app"
BUNDLE_ID="cc.shiibar.menubar"

# shellcheck source=scripts/lib/signing.sh
source "$ROOT/scripts/lib/signing.sh"

echo "==> Building shiibar-ccd / shiibar-cc (release)..."
(cd "$ROOT" && cargo build --release -p shiibar-ccd -p shiibar-cc)

echo "==> Building the menu bar app (release)..."
(cd "$ROOT/app" && swift build -c release)
APP_BIN_DIR="$(cd "$ROOT/app" && swift build -c release --show-bin-path)"

if [ -d "$OLD_APP_PATH" ]; then
  echo "==> Removing stale $OLD_APP_PATH (pre-rename bundle, T1)"
  rm -rf "$OLD_APP_PATH"
fi

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
	<string>1</string>
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
install -m 755 "$ROOT/hooks/report.sh" "$BIN_DIR/report.sh"

echo
echo "Installed:"
echo "  $APP_PATH"
echo "  $BIN_DIR/shiibar-cc -> $APP_PATH/Contents/Helpers/shiibar-cc"
echo "  $BIN_DIR/shiibar-ccd -> $APP_PATH/Contents/Helpers/shiibar-ccd"
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
