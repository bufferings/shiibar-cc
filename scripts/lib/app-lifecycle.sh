# Stopping a running "Shiibar CC.app" (and its daemon) before replacing it.
# Sourced by scripts/install.sh and scripts/dev-reload.sh. Expects BUNDLE_ID,
# so source scripts/lib/bundle.sh first.
#
# Why this exists: quitting the app does NOT reliably stop its daemon.
# "App quit stops the daemon" (DESIGN.md §8.8) is implemented as a
# fire-and-forget shutdown send from applicationShouldTerminate, which
# immediately returns .terminateNow — the async send races process exit and
# can lose (observed on-device: the daemon survived two dev-reloads in a
# row). A surviving daemon means a relaunched app ATTACHES to a process
# still running the pre-replace binary image, and the update silently does
# nothing for the daemon. The same applies to `open` at the end of
# install.sh: with the old instance still running it only foregrounds it.
# So: quit the app, then make sure the daemon is really gone — graceful
# socket shutdown ({"cmd":"shutdown"}, DESIGN.md §4.2) first, then SIGTERM,
# then SIGKILL. Force-killing is safe: the daemon persists state.json on
# every mutation, and on startup it handles a pre-existing socket file
# (connect test -> no answer -> take over; both §4.2).

# Poll until no process matches the pgrep -f pattern in $1, checking every
# 0.2s for up to $2 attempts. Returns 0 once nothing matches, 1 if
# something still matches after the last attempt.
wait_for_gone() {
  local pattern="$1" attempts="$2" i
  for ((i = 0; i < attempts; i++)); do
    if ! pgrep -f "$pattern" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  ! pgrep -f "$pattern" >/dev/null 2>&1
}

# stop_app_and_daemon <app_path>
#
# Quits a running app instance launched from <app_path> (skipped when none
# is running — a quit AppleEvent to a non-running app would launch it just
# to quit it), then makes sure the bundled daemon is gone per the escalation
# described above.
stop_app_and_daemon() {
  local app_path="$1"
  local app_exe_pattern="$app_path/Contents/MacOS/ShiibarCcApp"
  local daemon_pattern="$app_path/Contents/Helpers/shiibar-ccd"
  local state_dir="${SHIIBAR_CC_STATE_DIR:-$HOME/.local/state/shiibar-cc}"
  local sock="$state_dir/shiibar-ccd.sock"

  if pgrep -f "$app_exe_pattern" >/dev/null 2>&1; then
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    if ! wait_for_gone "$app_exe_pattern" 25; then
      echo "warning: the app is still running 5s after the quit AppleEvent;" >&2
      echo "continuing anyway (the steps below do not need it gone, but the" >&2
      echo "relaunch at the end may just foreground the old instance)." >&2
    fi
  fi

  if [ -S "$sock" ]; then
    printf '{"cmd":"shutdown"}\n' | nc -U -w 2 "$sock" >/dev/null 2>&1 || true
  fi
  if ! wait_for_gone "$daemon_pattern" 15; then
    echo "warning: the daemon is still running after the graceful shutdown" >&2
    echo "request; sending SIGTERM." >&2
    pkill -f "$daemon_pattern" 2>/dev/null || true
    if ! wait_for_gone "$daemon_pattern" 10; then
      echo "warning: the daemon survived SIGTERM; sending SIGKILL. State is" >&2
      echo "safe: state.json is persisted on every mutation (DESIGN.md §4.2)." >&2
      # shellcheck disable=SC2046 -- word-splitting the PID list is intended
      kill -9 $(pgrep -f "$daemon_pattern" || true) 2>/dev/null || true
    fi
  fi
}
