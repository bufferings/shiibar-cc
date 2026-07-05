#!/usr/bin/env bash
# Removes what scripts/install.sh placed: the shiibar-cc.app bundle, its
# Login Item registration, the ~/.local/bin symlinks/report.sh, and prints
# guidance for removing the hooks block from ~/.claude/settings.json
# (never edited automatically — see install.sh's comment for why).

set -euo pipefail

BIN_DIR="${SHIIBAR_CC_BIN_DIR:-$HOME/.local/bin}"
APP_DIR="${SHIIBAR_CC_APP_DIR:-$HOME/Applications}"
APP_NAME="shiibar-cc.app"
APP_PATH="$APP_DIR/$APP_NAME"
BUNDLE_ID="cc.shiibar.menubar"

if [ -d "$APP_PATH" ]; then
  echo "==> Quitting $APP_NAME (stops the bundled daemon too, DESIGN.md §8.8)"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  sleep 1

  echo "==> Deregistering the Login Item"
  # SMAppService.unregister() only works from inside the still-installed
  # bundle (DESIGN.md §4.5 daemon/app lifecycle), so launch it briefly with
  # a flag that does that and exits instead of starting the menu bar app.
  open -W -a "$APP_PATH" --args --unregister-login-item 2>/dev/null || true

  echo "==> Removing $APP_PATH"
  rm -rf "$APP_PATH"
else
  echo "no $APP_PATH found — skipping app/Login Item removal"
fi

for f in shiibar-ccd shiibar-cc report.sh; do
  path="$BIN_DIR/$f"
  if [ -e "$path" ] || [ -L "$path" ]; then
    rm -f "$path"
    echo "removed $path"
  fi
done

SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ] && grep -q "report.sh" "$SETTINGS" 2>/dev/null; then
  echo
  echo "$SETTINGS still references report.sh."
  echo "Remove the SessionStart/UserPromptSubmit/PostToolUse/PostToolUseFailure/"
  echo "Notification/Stop/SessionEnd hook entries that call report.sh by hand"
  echo "(see hooks/settings-snippet.json for exactly which ones shiibar-cc added)."
fi

echo
echo "Note: this does not touch ~/.local/state/shiibar-cc/ (state.json,"
echo "logs), nor the local code-signing identity created by"
echo "scripts/lib/make-local-signing-identity.sh (it's harmless to keep, and"
echo "reused if you reinstall). Remove them yourself if you want a full clean:"
echo "  rm -rf ~/.local/state/shiibar-cc"
echo "  security delete-certificate -c shiibar-cc-local-signing"
