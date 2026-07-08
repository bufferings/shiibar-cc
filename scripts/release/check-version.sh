#!/usr/bin/env bash
# Guard that a release tag matches the shipped version: compares the tag
# (vX.Y.Z, with the leading v stripped) against the root Cargo.toml
# [workspace.package] version AND the plugin manifest's version
# (plugin/.claude-plugin/plugin.json). A three-way mismatch prints the
# offending values and exits non-zero, so a release workflow fails fast
# before building anything.
#
# The plugin.json version bump is the gate that makes Claude Code pick up
# new hooks (it keeps serving the cached plugin otherwise), so it must land
# in the same release commit as the tag and Cargo.toml bump (DESIGN.md §4.1,
# §8.28 version-operation paragraph).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=scripts/lib/bundle.sh
source "$ROOT/scripts/lib/bundle.sh"

# Read the "version" field from plugin/.claude-plugin/plugin.json with
# grep/sed rather than jq, matching read_workspace_version's no-jq-dependency
# approach in scripts/lib/bundle.sh.
read_plugin_version() {
  local plugin_json="$1"
  grep '"version"' "$plugin_json" | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/'
}

TAG="${1:?usage: check-version.sh <tag> (e.g. v0.1.0)}"
TAG_VERSION="${TAG#v}"
CARGO_VERSION="$(read_workspace_version "$ROOT/Cargo.toml")"
PLUGIN_VERSION="$(read_plugin_version "$ROOT/plugin/.claude-plugin/plugin.json")"

if [ "$TAG_VERSION" != "$CARGO_VERSION" ]; then
  echo "error: tag version does not match Cargo.toml [workspace.package] version:" >&2
  echo "  tag:        $TAG (version $TAG_VERSION)" >&2
  echo "  Cargo.toml: $CARGO_VERSION" >&2
  exit 1
fi

if [ "$TAG_VERSION" != "$PLUGIN_VERSION" ]; then
  echo "error: tag version does not match plugin.json version:" >&2
  echo "  tag:         $TAG (version $TAG_VERSION)" >&2
  echo "  plugin.json: $PLUGIN_VERSION" >&2
  exit 1
fi

echo "version match: $CARGO_VERSION"
