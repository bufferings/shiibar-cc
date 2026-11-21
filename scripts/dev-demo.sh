#!/usr/bin/env bash
# Screenshot environment for the README (or any visual check), isolated from
# the developer's real sessions and conversations.
#
#   start    Creates a demo root (a demo HOME with sample conversation
#            transcripts and a demo state dir) and a copy of the installed
#            app with its own bundle identifier, quits the running Shiibar CC
#            app and its daemon, and launches the copy with HOME and
#            SHIIBAR_CC_STATE_DIR pointing into the demo root, and with a stub
#            `claude` first on PATH. The copy spawns its bundled daemon on the
#            demo state dir and lists only the sample conversations.
#   stage    Registers three Running rows in the demo daemon: waiting
#            (+unreviewed), working, and idle (reviewed).
#   banner   Registers one more session that finishes, so the app shows a
#            completion notification banner.
#   cleanup  Stops the demo app, its daemon and the placeholder processes,
#            deletes the demo defaults domain, the app copy and the demo
#            root, resets the Automation (AppleEvents) permission of the demo
#            bundle identifier, and relaunches the installed app normally.
#
# Why a copy with its own bundle identifier: the app keeps its settings in
# the UserDefaults domain of its bundle identifier, and when the full
# conversation list loads it drops the stars and archive entries of
# conversations that are not in it. Run on the real domain with the demo
# HOME, it would rewrite the real stars and archive lists. The copy uses
# DEMO_ID's domain, which start creates and cleanup deletes; the real
# domain is never read or written.
#
# The copy lives in DEMO_APP_DIR under ~/Library/Caches, not in the demo
# root: the notification service does not accept a client whose bundle is
# under /tmp (no permission prompt, no banners). It is registered with
# LaunchServices and launched with `open`, which passes the demo environment
# with --env.
#
# The demo root lives in /tmp with a short name: the daemon's Unix socket
# path inside it must fit in sun_path (104 bytes on macOS). Its location is
# kept in POINTER_FILE (per user, under ~/Library/Caches) so later
# subcommands find it.
#
# SHIIBAR_CC_DEMO_NO_APP=1 skips making the app copy and stopping, launching
# or relaunching any app. `cleanup` still removes a leftover copy (refusing
# while it runs) and the demo defaults domain. Use it to exercise the data
# and daemon parts against a daemon started by hand on the demo state dir
# (`SHIIBAR_CC_STATE_DIR=<root>/state shiibar-ccd --foreground`).
# SHIIBAR_CC_DEMO_CLI overrides the shiibar-cc binary used for the reports
# (default: the copy's bundled one, else the installed app's, else
# shiibar-cc on PATH).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${SHIIBAR_CC_APP_DIR:-$HOME/Applications}"
APP_PATH="$APP_DIR/Shiibar CC.app"
HELPER="$ROOT_DIR/scripts/lib/demo-helper.py"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
DEMO_ID="cc.shiibar.menubar.demo"
# File name of the copy. CFBundleName and CFBundleDisplayName stay
# "Shiibar CC", so the menu and the notification banners look like the
# installed app's.
DEMO_APP_NAME="Shiibar CC Demo.app"
# $HOME is the home of the person running this script (the demo HOME is only
# passed to the processes the demo starts).
DEMO_APP_DIR="$HOME/Library/Caches/$DEMO_ID"
DEMO_APP="$DEMO_APP_DIR/$DEMO_APP_NAME"
DEMO_APP_EXE="$DEMO_APP/Contents/MacOS/ShiibarCcApp"
# A sibling of DEMO_APP_DIR, not inside it: that directory is removed and
# recreated with the copy.
POINTER_FILE="$HOME/Library/Caches/$DEMO_ID.current"
DEMO_PREFIX="/tmp/shiibar-cc-demo."
NO_APP="${SHIIBAR_CC_DEMO_NO_APP:-0}"

# Must match the session ids in scripts/lib/demo-helper.py.
SID_WORK="6f1c2a94-3b7e-4c51-9d02-1a8e5b7c3f01"
SID_IDLE="6f1c2a94-3b7e-4c51-9d02-1a8e5b7c3f02"
SID_WAIT="6f1c2a94-3b7e-4c51-9d02-1a8e5b7c3f03"
SID_BANNER="6f1c2a94-3b7e-4c51-9d02-1a8e5b7c3f04"
# History conversations shown in Starred, top to bottom.
SID_STARRED=("6f1c2a94-3b7e-4c51-9d02-1a8e5b7c3f05" "6f1c2a94-3b7e-4c51-9d02-1a8e5b7c3f08")

# shellcheck source=scripts/lib/signing.sh
source "$ROOT_DIR/scripts/lib/signing.sh"

# shellcheck source=scripts/lib/bundle.sh
source "$ROOT_DIR/scripts/lib/bundle.sh"
# shellcheck source=scripts/lib/app-lifecycle.sh
source "$ROOT_DIR/scripts/lib/app-lifecycle.sh"

die() {
  echo "dev-demo.sh: $*" >&2
  exit 1
}

# The current demo root, or empty when there is none or the pointer is not
# trusted. A root is accepted only when the pointer is a regular file (not a
# symlink) and the recorded path is DEMO_PREFIX followed by one name of
# letters and digits (the mktemp suffix), naming a directory that is not a
# symlink and is owned by the current user. Anything else is ignored, so
# cleanup deletes no other directory.
demo_root() {
  local root suffix
  if [ -L "$POINTER_FILE" ]; then
    echo "dev-demo.sh: ignoring $POINTER_FILE: it is a symlink" >&2
    return 0
  fi
  [ -f "$POINTER_FILE" ] || return 0
  root="$(cat "$POINTER_FILE")"
  suffix="${root#"$DEMO_PREFIX"}"
  if [ "$suffix" = "$root" ] || ! [[ "$suffix" =~ ^[A-Za-z0-9]+$ ]]; then
    echo "dev-demo.sh: ignoring $POINTER_FILE: unexpected root '$root'" >&2
    return 0
  fi
  if [ ! -d "$root" ] || [ -L "$root" ] || [ ! -O "$root" ]; then
    return 0
  fi
  printf '%s\n' "$root"
}

require_root() {
  local root
  root="$(demo_root)"
  [ -n "$root" ] || die "no demo environment; run 'dev-demo.sh start' first"
  printf '%s\n' "$root"
}

# Sets CLI to the shiibar-cc binary for the reports. Called as a plain
# statement (not in a command substitution) so a missing binary stops the
# script.
CLI=""
resolve_cli() {
  if [ -n "${SHIIBAR_CC_DEMO_CLI:-}" ]; then
    CLI="$SHIIBAR_CC_DEMO_CLI"
  elif [ -x "$DEMO_APP/Contents/Helpers/shiibar-cc" ]; then
    CLI="$DEMO_APP/Contents/Helpers/shiibar-cc"
  elif [ -x "$APP_PATH/Contents/Helpers/shiibar-cc" ]; then
    CLI="$APP_PATH/Contents/Helpers/shiibar-cc"
  else
    CLI="$(command -v shiibar-cc || true)"
  fi
  [ -n "$CLI" ] || die "shiibar-cc not found (install the app or set SHIIBAR_CC_DEMO_CLI)"
}

# Runs shiibar-cc against the demo daemon only (after resolve_cli).
demo_cli() { # demo_cli <root> <args...>
  local root="$1"
  shift
  HOME="$root/home" SHIIBAR_CC_STATE_DIR="$root/state" "$CLI" "$@"
}

wait_for_socket() { # wait_for_socket <root> <attempts of 0.2s>
  local sock="$1/state/shiibar-ccd.sock" i
  for ((i = 0; i < $2; i++)); do
    [ -S "$sock" ] && return 0
    sleep 0.2
  done
  return 1
}

wait_for_pattern() { # wait_for_pattern <pgrep -f pattern> <attempts of 0.2s>
  local i
  for ((i = 0; i < $2; i++)); do
    pgrep -f "$1" >/dev/null 2>&1 && return 0
    sleep 0.2
  done
  return 1
}

placeholder_pattern() { # placeholder_pattern <root> [name]
  printf '%s\n' "demo-helper.py placeholder --root $1 --name ${2:-}"
}

# Kills placeholder processes of this demo root (all of them, or one name).
kill_placeholders() { # kill_placeholders <root> [name]
  local pattern
  pattern="$(placeholder_pattern "$1" "${2:-}")"
  pkill -f "$pattern" 2>/dev/null || true
  wait_for_gone "$pattern" 25 || pkill -9 -f "$pattern" 2>/dev/null || true
}

# The fake iTerm2 session UUID of a demo session: its session id in upper
# case (iTerm2 UUIDs are upper case). It matches no real tab, so Jump on a
# demo row finds nothing.
iterm_uuid() { # iterm_uuid <session_id>
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

# The daemon target of a demo session; seen and remove take a target.
target_for() { # target_for <session_id>
  printf 'iterm2:%s\n' "$(iterm_uuid "$1")"
}

# Starts one placeholder session and waits until its hook reports were
# sent. The iTerm2 environment gives the row an iterm2:<UUID> target like a
# real iTerm2 tab.
start_placeholder() { # start_placeholder <root> <name> <slot> <session_id> <end>
  local root="$1" name="$2" slot="$3" sid="$4" end="$5" i
  local ready="$root/run/$name.ready"
  rm -f "$ready"
  TERM_PROGRAM="iTerm.app" ITERM_SESSION_ID="$slot:$(iterm_uuid "$sid")" \
    HOME="$root/home" SHIIBAR_CC_STATE_DIR="$root/state" \
    python3 "$HELPER" placeholder --root "$root" --name "$name" \
    --cli "$CLI" --session "$sid" --end "$end" \
    </dev/null >>"$root/run/$name.log" 2>&1
  # (The placeholder outlives this script; without the redirects it would
  # hold this script's stdout open, and `dev-demo.sh stage | ...` would hang.)
  for ((i = 0; i < 50; i++)); do
    [ -f "$ready" ] && return 0
    sleep 0.2
  done
  die "placeholder '$name' did not finish its reports (see $root/run/$name.log)"
}

# Removes a demo session from the daemon and kills its placeholder.
reset_session() { # reset_session <root> <name> <session_id>
  demo_cli "$1" remove "$(target_for "$3")" >/dev/null 2>&1 || true
  kill_placeholders "$1" "$2"
}

# The stub `claude` the demo app finds first on PATH. `shiibar-cc reconcile`
# runs `claude agents --json` through PATH; the real one lists no sessions
# under the demo HOME, so every reconcile would be a complete round with an
# empty live set and would remove the staged rows within about a minute.
# The stub prints nothing, so the gather cannot parse a session list and
# sends an incomplete round, which removes nothing. The CLI still exits 0 for
# an incomplete round, so the app shows no warning.
write_claude_stub() { # write_claude_stub <root>
  mkdir -p "$1/bin"
  cat >"$1/bin/claude" <<'EOF'
#!/bin/sh
# dev-demo.sh stub: no session list, so every reconcile is incomplete.
exit 1
EOF
  chmod 755 "$1/bin/claude"
}

# Deletes DEMO_APP_DIR after unregistering the copy from LaunchServices.
# Before deleting, the path must equal the literal demo location under a
# non-empty HOME, sit directly in $HOME/Library/Caches, end in DEMO_ID, and
# not be a symlink; otherwise the script stops without deleting anything.
remove_demo_app() {
  [ -n "$HOME" ] || die "HOME is empty; not removing the app copy"
  [ "$DEMO_APP_DIR" = "$HOME/Library/Caches/cc.shiibar.menubar.demo" ] \
    && [ "$(dirname "$DEMO_APP_DIR")" = "$HOME/Library/Caches" ] \
    && [ "$(basename "$DEMO_APP_DIR")" = "$DEMO_ID" ] \
    || die "unexpected app copy directory: $DEMO_APP_DIR"
  [ ! -L "$DEMO_APP_DIR" ] || die "$DEMO_APP_DIR is a symlink; not removing it"
  [ -e "$DEMO_APP_DIR" ] || return 0
  if [ -d "$DEMO_APP" ]; then
    "$LSREGISTER" -u "$DEMO_APP" >/dev/null 2>&1 || true
  fi
  rm -rf "$DEMO_APP_DIR"
  echo "Removed $DEMO_APP_DIR"
}

# Copies the installed app to DEMO_APP, gives the copy DEMO_ID, and signs it
# again (the Info.plist change breaks the original signature). The stable
# local identity is used when it exists, as dev-install.sh does, so the
# notification permission granted to DEMO_ID can carry over to the next
# demo; otherwise ad-hoc, which is enough for a copy deleted by cleanup.
make_demo_app() {
  local app="$DEMO_APP" identity
  remove_demo_app
  mkdir -p "$DEMO_APP_DIR"
  ditto "$APP_PATH" "$app"
  plutil -replace CFBundleIdentifier -string "$DEMO_ID" "$app/Contents/Info.plist"
  identity="$(find_signing_identity || true)"
  BUNDLE_ID="$DEMO_ID" sign_app_bundle "${identity:--}" "$app"
  codesign --verify --deep --strict "$app"
  echo "    signed with ${identity:-ad-hoc (no stable local identity)}"
}

# Refuses to go on unless the copy carries DEMO_ID: launching a bundle with
# the real identifier would use the real defaults domain.
assert_demo_bundle() { # assert_demo_bundle <app>
  local id
  id="$(plutil -extract CFBundleIdentifier raw "$1/Contents/Info.plist" 2>/dev/null || true)"
  if [ "$DEMO_ID" = "$BUNDLE_ID" ] || [ "$id" != "$DEMO_ID" ]; then
    die "refusing to launch $1: its CFBundleIdentifier is '$id', not '$DEMO_ID'"
  fi
}

# A fresh DEMO_ID domain, so screenshots use the default settings, plus:
# - didAutoRegisterLoginItem: the app registers itself as a Login Item on
#   its first bundled launch unless this is set (ShiibarCcMenuBarApp.swift,
#   performFirstLaunchLoginItemAutoRegistrationIfNeeded);
# - starredSessionList: the Starred section's session ids, top to bottom.
prepare_demo_defaults() {
  defaults delete "$DEMO_ID" >/dev/null 2>&1 || true
  defaults write "$DEMO_ID" cc.shiibar.didAutoRegisterLoginItem -bool true
  defaults write "$DEMO_ID" cc.shiibar.starredSessionList -array "${SID_STARRED[@]}"
}

# Deletes the DEMO_ID domain with `defaults delete` (through cfprefsd), then
# removes the empty plist file that `defaults delete` leaves behind.
delete_demo_defaults() {
  defaults delete "$DEMO_ID" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$DEMO_ID.plist"
}

reconcile_note() {
  cat <<'EOF'
The rows stay until `cleanup`: with the stub `claude`, every reconcile is
incomplete and removes nothing, and the daemon's stale sweep removes a row
only 24h after this `stage`. Their elapsed times keep growing; run `stage`
again to reset them.
EOF
}

cmd_start() {
  local root
  [ -z "$(demo_root)" ] || die "a demo environment already exists ($(demo_root)); run 'dev-demo.sh cleanup' first"
  command -v python3 >/dev/null || die "python3 is required"
  if [ "$NO_APP" != "1" ] && [ ! -x "$APP_PATH/Contents/MacOS/ShiibarCcApp" ]; then
    die "no installed app at $APP_PATH (run scripts/dev-install.sh)"
  fi
  if pgrep -f "$DEMO_APP_EXE" >/dev/null 2>&1; then
    die "a demo app is still running from $DEMO_APP; run 'dev-demo.sh cleanup' first"
  fi

  root="$(mktemp -d "${DEMO_PREFIX}XXXXXX")"
  mkdir -p "$root/home" "$root/state" "$root/run"
  write_claude_stub "$root"
  mkdir -p "$(dirname "$POINTER_FILE")"
  rm -f "$POINTER_FILE"
  (set -C && printf '%s\n' "$root" >"$POINTER_FILE")
  python3 "$HELPER" transcripts "$root/home"
  echo "==> Demo root: $root"

  prepare_demo_defaults

  if [ "$NO_APP" = "1" ]; then
    echo "SHIIBAR_CC_DEMO_NO_APP=1: not stopping or launching any app. Start a daemon with"
    echo "  SHIIBAR_CC_STATE_DIR=$root/state shiibar-ccd --foreground"
    echo "and put $root/bin first on PATH for any shiibar-cc reconcile."
    return 0
  fi

  echo "==> Copying the installed app to $DEMO_APP as $DEMO_ID"
  make_demo_app
  assert_demo_bundle "$DEMO_APP"

  echo "==> Stopping the running app/daemon (if any)"
  # From here until the demo app is up, a failure leaves the installed app
  # stopped; say how to get it back.
  trap 'echo "dev-demo.sh: start did not finish and the installed app is stopped; run '"'"'dev-demo.sh cleanup'"'"' to restore it." >&2' EXIT
  stop_app_and_daemon "$APP_PATH"

  echo "==> Launching the demo copy on the demo HOME and state dir"
  assert_demo_bundle "$DEMO_APP"
  "$LSREGISTER" -f "$DEMO_APP"
  # HOME, SHIIBAR_CC_STATE_DIR and PATH reach the app and, through it, the
  # daemon and every shiibar-cc subprocess it runs.
  open -n --env "HOME=$root/home" --env "SHIIBAR_CC_STATE_DIR=$root/state" \
    --env "PATH=$root/bin:$PATH" \
    --stdout "$root/run/app.log" --stderr "$root/run/app.log" "$DEMO_APP"
  # `open` returns once the launch is requested.
  if ! wait_for_pattern "$DEMO_APP_EXE" 50; then
    die "the demo app did not start (see $root/run/app.log)"
  fi
  if ! wait_for_socket "$root" 75; then
    die "the demo daemon did not come up (see $root/run/app.log and $root/state/)"
  fi
  # The app runs a reconcile right after connecting; it would remove rows
  # staged before it finishes.
  sleep 3
  trap - EXIT
  echo "Ready. Run 'dev-demo.sh stage' for the Running rows."
}

cmd_stage() {
  local root
  root="$(require_root)"
  wait_for_socket "$root" 1 || die "the demo daemon is not running ($root/state/shiibar-ccd.sock)"
  resolve_cli

  reset_session "$root" work "$SID_WORK"
  reset_session "$root" idle "$SID_IDLE"
  reset_session "$root" wait "$SID_WAIT"

  # working: spinner glyph cycling
  start_placeholder "$root" work w0t1p0 "$SID_WORK" none
  # idle, reviewed (no unreviewed dot): finished and seen
  start_placeholder "$root" idle w0t2p0 "$SID_IDLE" stop
  demo_cli "$root" seen "$(target_for "$SID_IDLE")" >/dev/null
  # waiting + unreviewed. Staged last: its banner pops about 3s later.
  start_placeholder "$root" wait w0t3p0 "$SID_WAIT" permission

  echo "Staged three Running rows. A waiting banner (with sound) pops in about 3s."
  reconcile_note
}

cmd_banner() {
  local root
  root="$(require_root)"
  wait_for_socket "$root" 1 || die "the demo daemon is not running ($root/state/shiibar-ccd.sock)"
  resolve_cli
  reset_session "$root" banner "$SID_BANNER"
  start_placeholder "$root" banner w0t4p0 "$SID_BANNER" stop
  echo "Completion banner pops in about 3s. Shoot it."
}

cmd_cleanup() {
  local root
  if [ "$NO_APP" = "1" ] && pgrep -f "$DEMO_APP_EXE" >/dev/null 2>&1; then
    die "the demo app is running from $DEMO_APP; run cleanup without SHIIBAR_CC_DEMO_NO_APP"
  fi
  root="$(demo_root)"
  if [ -n "$root" ]; then
    kill_placeholders "$root"
  fi

  if [ "$NO_APP" = "1" ]; then
    if [ -n "$root" ] && [ -S "$root/state/shiibar-ccd.sock" ]; then
      printf '{"cmd":"shutdown"}\n' | nc -U -w 2 "$root/state/shiibar-ccd.sock" >/dev/null 2>&1 || true
    fi
  else
    echo "==> Stopping the demo app/daemon (if any)"
    # stop_app_and_daemon quits by BUNDLE_ID and finds the processes by the
    # bundle path; both are the copy's here. Without a demo root (pointer
    # gone) there is no socket to ask, and its SIGTERM fallback applies.
    BUNDLE_ID="$DEMO_ID" SHIIBAR_CC_STATE_DIR="${root:-/nonexistent}/state" \
      stop_app_and_daemon "$DEMO_APP"
    # stop_app_and_daemon only warns when the app ignores the quit
    # AppleEvent. The copy must be gone before its bundle and its defaults
    # domain are deleted, and it holds nothing worth saving.
    pkill -f "$DEMO_APP_EXE" 2>/dev/null || true
    wait_for_gone "$DEMO_APP_EXE" 25 || pkill -9 -f "$DEMO_APP_EXE" 2>/dev/null || true
  fi

  remove_demo_app
  if [ -n "$root" ]; then
    rm -rf "$root"
    echo "Removed $root"
  else
    echo "No demo root found."
  fi
  rm -f "$POINTER_FILE"
  # After the demo app has stopped, so it cannot write the domain again.
  delete_demo_defaults
  tccutil reset AppleEvents "$DEMO_ID" >/dev/null 2>&1 || true
  echo "Deleted the $DEMO_ID defaults domain."

  if [ "$NO_APP" != "1" ] && [ -d "$APP_PATH" ]; then
    echo "==> Relaunching $APP_PATH"
    open "$APP_PATH"
  fi
  cat <<EOF
Left behind: if the demo app asked for notification permission, its entry
for $DEMO_ID stays in System Settings > Notifications (listed as
"Shiibar CC"); this script does not remove it.
EOF
}

case "${1:-}" in
  start) cmd_start ;;
  stage) cmd_stage ;;
  banner) cmd_banner ;;
  cleanup) cmd_cleanup ;;
  *)
    echo "usage: dev-demo.sh start|stage|banner|cleanup" >&2
    exit 1
    ;;
esac
