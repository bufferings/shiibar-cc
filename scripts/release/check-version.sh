#!/usr/bin/env bash
# Guard that a release tag matches the shipped version: compares the tag
# (vX.Y.Z, with the leading v stripped) against the root Cargo.toml
# [workspace.package] version. A mismatch prints both values and exits
# non-zero, so a release workflow fails fast before building anything.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=scripts/lib/bundle.sh
source "$ROOT/scripts/lib/bundle.sh"

TAG="${1:?usage: check-version.sh <tag> (e.g. v0.1.0)}"
TAG_VERSION="${TAG#v}"
CARGO_VERSION="$(read_workspace_version "$ROOT/Cargo.toml")"

if [ "$TAG_VERSION" != "$CARGO_VERSION" ]; then
  echo "error: tag version does not match Cargo.toml [workspace.package] version:" >&2
  echo "  tag:        $TAG (version $TAG_VERSION)" >&2
  echo "  Cargo.toml: $CARGO_VERSION" >&2
  exit 1
fi

echo "version match: $CARGO_VERSION"
