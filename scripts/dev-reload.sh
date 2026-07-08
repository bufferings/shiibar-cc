#!/usr/bin/env bash
# Dogfooding helper (DESIGN.md §5): rebuild debug binaries + the menu bar
# app. Two modes:
#   - No installed "Shiibar CC.app" (scripts/dev-install.sh not run yet, or
#     removed): just rebuilds, and daemon lifecycle stays manual per §4.2 —
#     run `shiibar-ccd --foreground` yourself, then `swift run` the app
#     against it (it attaches instead of spawning, task brief M4 §1).
#   - An installed "Shiibar CC.app" exists: quits it, makes sure its daemon is
#     really gone (stop_app_and_daemon, scripts/lib/app-lifecycle.sh — see its
#     header for why quitting the app is not enough), swaps in the freshly
#     built binaries in place, re-signs with the
#     stable local identity from the keychain (or falls back to ad-hoc),
#     and relaunches it — a hot-swap for daily dogfooding without re-running
#     the full scripts/dev-install.sh (which also re-bundles Info.plist etc).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${SHIIBAR_CC_APP_DIR:-$HOME/Applications}"
APP_NAME="Shiibar CC.app"
APP_PATH="$APP_DIR/$APP_NAME"

# shellcheck source=scripts/lib/signing.sh
source "$ROOT/scripts/lib/signing.sh"
# BUNDLE_ID and sign_app_bundle come from bundle.sh (same signing order and
# bundle identity dev-install.sh uses).
# shellcheck source=scripts/lib/bundle.sh
source "$ROOT/scripts/lib/bundle.sh"
# shellcheck source=scripts/lib/app-lifecycle.sh
source "$ROOT/scripts/lib/app-lifecycle.sh"

echo "==> Building shiibar-ccd / shiibar-cc (debug)..."
(cd "$ROOT" && cargo build -p shiibar-ccd -p shiibar-cc)

echo "==> Building the menu bar app (debug)..."
(cd "$ROOT/app" && swift build)
APP_BIN_DIR="$(cd "$ROOT/app" && swift build --show-bin-path)"

echo
echo "Built:"
echo "  $ROOT/target/debug/shiibar-ccd"
echo "  $ROOT/target/debug/shiibar-cc"
echo "  $APP_BIN_DIR/ShiibarCcApp"

if [ -d "$APP_PATH" ]; then
  echo
  echo "==> Hot-swapping the installed $APP_NAME"

  # Quit the app and make sure its daemon is really gone before swapping
  # binaries (stop_app_and_daemon, scripts/lib/app-lifecycle.sh — see its
  # header for why quitting the app is not enough).
  stop_app_and_daemon "$APP_PATH"

  install -m 755 "$APP_BIN_DIR/ShiibarCcApp" "$APP_PATH/Contents/MacOS/ShiibarCcApp"
  install -m 755 "$ROOT/target/debug/shiibar-ccd" "$APP_PATH/Contents/Helpers/shiibar-ccd"
  install -m 755 "$ROOT/target/debug/shiibar-cc" "$APP_PATH/Contents/Helpers/shiibar-cc"

  # Re-sign with the stable local identity looked up from the keychain by
  # common name (scripts/lib/signing.sh — same lookup scripts/dev-install.sh
  # uses), NOT by reading the identity back off this bundle. Reading it off
  # the bundle used to be how this worked, and it was broken: by this point
  # the `install` calls above have already swapped in freshly built
  # binaries, and on Apple Silicon the toolchain ad-hoc-signs every fresh
  # build (`codesign -dvv` on a fresh swift/cargo build output shows
  # `Signature=adhoc`, `flags=0x20002(adhoc,linker-signed)` — no `Authority=`
  # line). So a post-swap `codesign -dvv "$APP_PATH"` lookup always came back
  # empty, meaning this script ALWAYS took the "ad-hoc" branch below and
  # re-signed ad-hoc — resetting the notification permission on every single
  # reload regardless of whether a stable identity existed, and doing so
  # silently (the "installed bundle was ad-hoc signed" warning is a lie the
  # moment a stable identity actually exists in the keychain). Worse, it was
  # sticky: once a bundle had been re-signed ad-hoc this way, a bundle-derived
  # lookup could never see the stable identity again on a later run, even
  # though it was still sitting in the keychain the whole time. Looking the
  # identity up in the keychain instead sidesteps all of that.
  #
  # Same layering as dev-install.sh: helpers and app signed individually, and NO
  # entitlements — the time-sensitive entitlement is restricted, and AMFI
  # refuses to launch a locally-signed binary that carries it
  # (RBSRequestErrorDomain Code=5 / POSIX 153; see dev-install.sh). sign_app_bundle
  # (scripts/lib/bundle.sh) implements that layering; no extra flags, so a
  # plain local signature like dev-install.sh's.
  SIGN_ID="$(find_signing_identity || true)"
  if [ -n "$SIGN_ID" ]; then
    sign_app_bundle "$SIGN_ID" "$APP_PATH" || {
      echo "warning: re-signing with '$SIGN_ID' failed; falling back to ad-hoc." >&2
      echo "Notification permission will reset — re-run scripts/dev-install.sh to fix" >&2
      echo "the stable identity (DESIGN.md §4.5)." >&2
      sign_app_bundle "-" "$APP_PATH"
    }
  else
    echo "warning: no stable '$SIGNING_IDENTITY_CN' codesigning identity exists" >&2
    echo "in the keychain; signing ad-hoc. Notification permission will reset on" >&2
    echo "every reload like this — run scripts/dev-install.sh to set up the stable" >&2
    echo "identity (DESIGN.md §4.5)." >&2
    sign_app_bundle "-" "$APP_PATH"
  fi

  echo "==> Relaunching $APP_PATH"
  open "$APP_PATH"
else
  echo
  echo "No installed $APP_PATH (run scripts/dev-install.sh, or dogfood without"
  echo "installing):"
  echo "  1. shiibar-ccd --foreground              # manual daemon, §4.2"
  echo "  2. swift run --package-path app ShiibarCcApp   # attaches, doesn't spawn"
fi
