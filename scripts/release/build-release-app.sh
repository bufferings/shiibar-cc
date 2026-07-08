#!/usr/bin/env bash
# Build, assemble, and sign a release "Shiibar CC.app" into <out_dir>.
# Used by .github/workflows/release.yml (and runnable locally with an ad-hoc
# identity for a bundle-layout smoke test). Both the CFBundleShortVersionString
# and CFBundleVersion are set to <version> — unlike the local install, a
# release keeps the version stamped on a build identical to what gets
# smoke-tested and published.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=scripts/lib/bundle.sh
source "$ROOT/scripts/lib/bundle.sh"

VERSION="${1:?usage: build-release-app.sh <version> <out_dir>}"
OUT_DIR="${2:?usage: build-release-app.sh <version> <out_dir>}"
APP_PATH="$OUT_DIR/Shiibar CC.app"

mkdir -p "$OUT_DIR"

echo "==> Building shiibar-ccd / shiibar-cc (release)..."
(cd "$ROOT" && cargo build --release --locked -p shiibar-ccd -p shiibar-cc)

echo "==> Building the menu bar app (release)..."
(cd "$ROOT/app" && swift build -c release)
APP_BIN_DIR="$(cd "$ROOT/app" && swift build -c release --show-bin-path)"

echo "==> Assembling $APP_PATH (version $VERSION)"
assemble_app_bundle \
  "$APP_PATH" \
  "$APP_BIN_DIR/ShiibarCcApp" \
  "$ROOT/target/release/shiibar-ccd" \
  "$ROOT/target/release/shiibar-cc" \
  "$VERSION" \
  "$VERSION"

# Signing identity: an explicit override (SHIIBAR_CC_SIGN_IDENTITY, including
# ad-hoc "-") wins — CI passes the imported Developer ID hash, and it doubles
# as a local escape hatch. Otherwise resolve the "Developer ID Application"
# identity from the keychain.
if [ -n "${SHIIBAR_CC_SIGN_IDENTITY:-}" ]; then
  IDENTITY="$SHIIBAR_CC_SIGN_IDENTITY"
else
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep 'Developer ID Application' \
    | head -1 \
    | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+([0-9A-Fa-f]+)[[:space:]].*$/\1/')"
  if [ -z "$IDENTITY" ]; then
    echo "error: no 'Developer ID Application' codesigning identity found, and" >&2
    echo "SHIIBAR_CC_SIGN_IDENTITY is not set." >&2
    exit 1
  fi
fi

echo "==> Code signing with $IDENTITY (hardened runtime)"
if [ "$IDENTITY" = "-" ]; then
  # Ad-hoc signatures cannot use a secure timestamp server, so drop
  # --timestamp; the hardened runtime option still applies. Ad-hoc is for
  # local bundle-layout smoke tests only, never a notarizable artifact.
  sign_app_bundle "$IDENTITY" "$APP_PATH" --options runtime
else
  sign_app_bundle "$IDENTITY" "$APP_PATH" --options runtime --timestamp
fi

echo "==> Verifying the signature (codesign --verify --deep --strict)"
codesign --verify --deep --strict "$APP_PATH"

echo "Built $APP_PATH"
