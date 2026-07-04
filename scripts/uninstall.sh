#!/usr/bin/env bash
# Removes what scripts/install.sh placed under ~/.local/bin, and prints
# guidance for removing the hooks block from ~/.claude/settings.json
# (again, never edited automatically — see install.sh's comment for why).

set -euo pipefail

BIN_DIR="${SHIIBAR_BIN_DIR:-$HOME/.local/bin}"

for f in shiibard shiibarctl report.sh; do
  path="$BIN_DIR/$f"
  if [ -e "$path" ]; then
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
  echo "(see hooks/settings-snippet.json for exactly which ones shiibar added)."
fi

echo
echo "Note: this does not touch ~/.local/state/shiibar/ (state.json,"
echo "sessions.jsonl, logs). Remove that directory yourself if you want to"
echo "drop resume history / logs too."
