#!/usr/bin/env bash
# Print release notes for <tag> to stdout: one "- <subject>" line per commit
# between the previous tag and <tag>. Commits whose subject starts with
# "Close the M<number>" (milestone-close bookkeeping) are excluded. If there
# is no previous tag (the very first release), the whole history up to <tag>
# is used.
set -euo pipefail

TAG="${1:?usage: generate-release-notes.sh <tag>}"

# The most recent tag reachable before <tag>, if any. --abbrev=0 yields the
# tag name alone; a missing previous tag makes git describe fail, which we
# treat as "first release, use full history".
if PREV_TAG="$(git describe --tags --abbrev=0 "$TAG^" 2>/dev/null)"; then
  RANGE="$PREV_TAG..$TAG"
else
  RANGE="$TAG"
fi

git log --format='%s' "$RANGE" | while IFS= read -r subject; do
  case "$subject" in
    "Close the M"[0-9]*) continue ;;
  esac
  printf -- '- %s\n' "$subject"
done
