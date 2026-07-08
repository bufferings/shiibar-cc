# Single source of truth for assembling and signing "Shiibar CC.app".
# Sourced (not executed) by scripts/dev-install.sh, scripts/dev-reload.sh,
# and scripts/release/build-release-app.sh so local install, dev-reload,
# and the release build share one bundle layout and one signing order.
#
# The .app is a LSUIElement menu bar app whose two Rust helpers live under
# Contents/Helpers/ (DESIGN.md §4.5). Signing has to cover EVERY executable
# in the bundle, not just the main app — for notarization the helpers need
# the hardened runtime too, so callers pass their extra codesign flags and
# this library applies them to all three codesign invocations.

# Absolute directory of this library, resolved at source time so the icon
# generator (scripts/generate-app-icon.swift) can be found regardless of the
# caller's working directory.
_BUNDLE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BUNDLE_ID="cc.shiibar.menubar"

# Read the workspace version from the root Cargo.toml's [workspace.package]
# section (the single source of truth for the app version). Scoped to that
# section so it never picks up a dependency's `version = ...`.
read_workspace_version() {
  local cargo_toml="$1"
  awk '
    /^\[workspace\.package\]/ { in_section = 1; next }
    /^\[/ { in_section = 0 }
    in_section && /^version[[:space:]]*=/ {
      gsub(/^version[[:space:]]*=[[:space:]]*"/, "")
      gsub(/".*$/, "")
      print
      exit
    }
  ' "$cargo_toml"
}

# assemble_app_bundle <app_path> <app_bin> <ccd_bin> <cc_bin> <version> <bundle_version>
#
# Builds the whole bundle from scratch: fresh Contents/MacOS + Contents/Helpers,
# the three binaries installed 755, the Info.plist (with the two version fields
# parameterized), and the generated app icon under Contents/Resources.
assemble_app_bundle() {
  local app_path="$1" app_bin="$2" ccd_bin="$3" cc_bin="$4"
  local version="$5" bundle_version="$6"

  rm -rf "$app_path"
  mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Helpers"

  install -m 755 "$app_bin" "$app_path/Contents/MacOS/ShiibarCcApp"
  install -m 755 "$ccd_bin" "$app_path/Contents/Helpers/shiibar-ccd"
  install -m 755 "$cc_bin" "$app_path/Contents/Helpers/shiibar-cc"

  cat > "$app_path/Contents/Info.plist" <<PLIST
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
	<string>$version</string>
	<key>CFBundleVersion</key>
	<string>$bundle_version</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>© 2026 Mitsuyuki Shiiba — MIT OR Apache-2.0</string>
</dict>
</plist>
PLIST

  # Generate the icon in a self-contained subshell so its EXIT trap for the
  # temp workdir is local and never clobbers a trap the caller may have set.
  # (DESIGN.md §4.5, docs/tasks/M5.md T10.)
  (
    icon_workdir="$(mktemp -d)"
    trap 'rm -rf "$icon_workdir"' EXIT
    swift "$_BUNDLE_LIB_DIR/../generate-app-icon.swift" "$icon_workdir"
    iconutil -c icns "$icon_workdir/AppIcon.iconset" -o "$icon_workdir/AppIcon.icns"
    mkdir -p "$app_path/Contents/Resources"
    install -m 644 "$icon_workdir/AppIcon.icns" "$app_path/Contents/Resources/AppIcon.icns"
  )
}

# sign_app_bundle <identity> <app_path> [extra codesign flags...]
#
# Signs the two Helpers binaries individually, then the bundle itself last
# (inside-out so the enclosing signature seals the already-signed helpers).
# Any extra flags (e.g. --options runtime --timestamp for notarization) are
# applied to ALL THREE codesign calls, since every executable in the bundle
# must satisfy the same requirements.
sign_app_bundle() {
  local identity="$1" app_path="$2"
  shift 2
  codesign --force --sign "$identity" "$@" "$app_path/Contents/Helpers/shiibar-ccd"
  codesign --force --sign "$identity" "$@" "$app_path/Contents/Helpers/shiibar-cc"
  codesign --force --sign "$identity" "$@" --identifier "$BUNDLE_ID" "$app_path"
}
