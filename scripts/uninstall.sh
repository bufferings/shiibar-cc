#!/usr/bin/env bash
# Removes what scripts/install.sh placed. Two stages:
#   - no arguments: the ShiibarCC.app bundle, its Login Item registration,
#     and the ~/.local/bin symlinks/report.sh. Easy to reverse (re-run
#     install.sh) — state dir, hooks config, keychain identity, and TCC
#     grants are all left alone. Prints guidance for removing the hooks
#     block from ~/.claude/settings.json (never edited automatically here
#     either — see install.sh's comment for why).
#   - --purge: everything above, plus a full teardown — removes the
#     shiibar-cc hook entries from ~/.claude/settings.json (via jq), the
#     state dir, the Login Item UserDefaults flag, the local code-signing
#     identity, and the iTerm2 Automation TCC grant. The notification
#     permission has no CLI removal API and is called out at the end as a
#     manual step (System Settings > Notifications).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PURGE=0
case "${1:-}" in
  "") ;;
  --purge) PURGE=1 ;;
  *)
    echo "usage: $(basename "$0") [--purge]" >&2
    exit 1
    ;;
esac

# shellcheck source=scripts/lib/signing.sh
source "$ROOT/scripts/lib/signing.sh"

BIN_DIR="${SHIIBAR_CC_BIN_DIR:-$HOME/.local/bin}"
APP_DIR="${SHIIBAR_CC_APP_DIR:-$HOME/Applications}"
APP_NAME="ShiibarCC.app"
APP_PATH="$APP_DIR/$APP_NAME"
BUNDLE_ID="cc.shiibar.menubar"
STATE_DIR="${SHIIBAR_CC_STATE_DIR:-$HOME/.local/state/shiibar-cc}"
SETTINGS="$HOME/.claude/settings.json"

# jq filter: drop any hook entry whose command references report.sh (that's
# how shiibar-cc's own hooks are identified — see hooks/settings-snippet.json),
# keeping every other hook entry, matcher group, and top-level setting
# untouched. A matcher group left with an empty "hooks" array is dropped, and
# an event left with no groups is dropped too, so a settings.json that had
# nothing but shiibar-cc's own hooks ends up with no "hooks" key at all
# rather than an empty husk.
HOOKS_PURGE_FILTER='
if has("hooks") then
  .hooks |= (
    with_entries(
      .value |= (
          map(.hooks |= map(select(((.command // "") | test("report\\.sh")) | not)))
        | map(select((.hooks // []) | length > 0))
      )
    )
    | with_entries(select((.value | length) > 0))
  )
  | if (.hooks | length) == 0 then del(.hooks) else . end
else
  .
end
'

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

if [ "$PURGE" -eq 1 ]; then
  echo "==> Removing shiibar-cc hooks from $SETTINGS"
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq not found — skipping automatic hooks removal."
    echo "Remove the SessionStart/UserPromptSubmit/PostToolUse/PostToolUseFailure/"
    echo "Notification/Stop/SessionEnd hook entries that call report.sh by hand"
    echo "(see hooks/settings-snippet.json for exactly which ones shiibar-cc added)."
  elif [ ! -f "$SETTINGS" ]; then
    echo "no $SETTINGS found — skipping hooks removal."
  else
    TMP_SETTINGS="$(mktemp)"
    if jq "$HOOKS_PURGE_FILTER" "$SETTINGS" > "$TMP_SETTINGS" 2>/dev/null; then
      cp "$SETTINGS" "$SETTINGS.bak"
      mv "$TMP_SETTINGS" "$SETTINGS"
      echo "removed shiibar-cc hook entries from $SETTINGS (backup: $SETTINGS.bak)"
    else
      echo "warning: jq could not process $SETTINGS (invalid JSON?) — leaving it untouched." >&2
      echo "Remove the report.sh hook entries by hand (see hooks/settings-snippet.json)." >&2
      rm -f "$TMP_SETTINGS"
    fi
  fi

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
  echo "Note: the notification permission cannot be removed programmatically"
  echo "(no CLI/API for it). Remove it yourself: System Settings > Notifications >"
  echo "Shiibar CC > Remove, or just leave it — it's harmless if you reinstall."
else
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
  echo "reused if you reinstall). Remove them yourself if you want a full clean,"
  echo "or re-run this script with --purge:"
  echo "  rm -rf ~/.local/state/shiibar-cc"
  echo "  security delete-certificate -c shiibar-cc-local-signing"
fi
