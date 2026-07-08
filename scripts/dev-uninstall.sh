#!/usr/bin/env bash
# Removes what scripts/dev-install.sh placed, plus a full teardown: the
# "Shiibar CC.app" bundle, its Login Item registration, the ~/.local/bin
# symlinks, the state dir, the Login Item UserDefaults flag, the local
# code-signing identity, and the iTerm2 Automation TCC grant. This used to
# be a separate `--purge` stage, but dev-install.sh can already recreate
# everything here from scratch, so there was no real use for a lighter
# "temporarily remove" step — see DESIGN.md §8.20. The notification
# permission has no CLI removal API and is called out at the end as a
# manual step (System Settings > Notifications).
#
# Hooks are no longer this script's concern: they ship as a Claude Code
# plugin (DESIGN.md §4.1/§8.19), so removing them is `claude plugin uninstall
# shiibar-cc` — this script just prints that reminder rather than touching
# ~/.claude/settings.json itself.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ $# -gt 0 ]; then
  echo "usage: $(basename "$0")" >&2
  exit 1
fi

# shellcheck source=scripts/lib/signing.sh
source "$ROOT/scripts/lib/signing.sh"

BIN_DIR="${SHIIBAR_CC_BIN_DIR:-$HOME/.local/bin}"
APP_DIR="${SHIIBAR_CC_APP_DIR:-$HOME/Applications}"
APP_NAME="Shiibar CC.app"
APP_PATH="$APP_DIR/$APP_NAME"
BUNDLE_ID="cc.shiibar.menubar"
STATE_DIR="${SHIIBAR_CC_STATE_DIR:-$HOME/.local/state/shiibar-cc}"

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

for f in shiibar-ccd shiibar-cc; do
  path="$BIN_DIR/$f"
  if [ -e "$path" ] || [ -L "$path" ]; then
    rm -f "$path"
    echo "removed $path"
  fi
done

echo "==> Removing state dir $STATE_DIR"
rm -rf "$STATE_DIR"

echo "==> Removing Login Item auto-registration flag"
defaults delete cc.shiibar.menubar 2>/dev/null \
  && echo "removed cc.shiibar.menubar UserDefaults domain" \
  || echo "no cc.shiibar.menubar UserDefaults domain found — nothing to remove"

echo "==> Removing the local code-signing identity ($SIGNING_IDENTITY_CN)"
security delete-certificate -c "$SIGNING_IDENTITY_CN" 2>/dev/null \
  && echo "removed the $SIGNING_IDENTITY_CN certificate/identity" \
  || echo "no $SIGNING_IDENTITY_CN certificate found — nothing to remove"

echo "==> Resetting the iTerm2 Automation (AppleEvents) TCC grant"
tccutil reset AppleEvents "$BUNDLE_ID" 2>/dev/null \
  && echo "reset AppleEvents TCC grant for $BUNDLE_ID" \
  || echo "tccutil reported nothing to reset for $BUNDLE_ID"

echo
echo "==> hooks"
echo "This script does not touch ~/.claude/settings.json — the hooks are a"
echo "Claude Code plugin (DESIGN.md §4.1/§8.19). Remove them with:"
echo "  claude plugin uninstall shiibar-cc"

echo
echo "Note: the notification permission cannot be removed programmatically"
echo "(no CLI/API for it). Remove it yourself: System Settings > Notifications >"
echo "Shiibar CC > Remove, or just leave it — it's harmless if you reinstall."
