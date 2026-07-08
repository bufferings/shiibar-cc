# Cask template for the bufferings/homebrew-tap release of Shiibar CC.
#
# This file is a template, not a valid cask: {{VERSION}} and {{SHA256}} are
# placeholders substituted by .github/workflows/bump-cask.yml when it renders
# this file into Casks/shiibar-cc.rb in the bufferings/homebrew-tap repository
# on every published (non-prerelease) GitHub Release. ci.yml renders it with
# dummy values and runs `brew style --cask` on the result so a syntax error
# here fails CI instead of surfacing only at bump time.
#
# arm64-only: there is no Intel build (no Intel Mac or CI runner to verify one
# on), so this cask intentionally omits an Intel/x86_64 variant rather than
# promising support that has never been tested. A source build from the
# repository is the alternative for Intel Macs.
cask "shiibar-cc" do
  version "{{VERSION}}"
  sha256 "{{SHA256}}"

  url "https://github.com/bufferings/shiibar-cc/releases/download/v#{version}/shiibar-cc-#{version}-arm64.zip"
  name "Shiibar CC"
  desc "Menu bar app that tracks Claude Code status and jumps to its iTerm2 tab"
  homepage "https://github.com/bufferings/shiibar-cc"

  depends_on macos: :ventura
  depends_on arch:  :arm64

  app "Shiibar CC.app"
  binary "#{appdir}/Shiibar CC.app/Contents/Helpers/shiibar-cc"
  binary "#{appdir}/Shiibar CC.app/Contents/Helpers/shiibar-ccd"

  postflight do
    # Best-effort install/update of the hooks plugin from the Claude Code
    # CLI. Every step is allowed to fail without failing the cask install
    # or upgrade (the caveats below spell out the two-command manual
    # fallback): `claude` itself may not be installed, the plugin commands
    # may error, etc.
    # Written as a shell script (not Cask's Ruby system_command helpers)
    # because the logic needs a PATH-independent `claude` resolution,
    # grep-based settings checks, and command chaining that reads far
    # more clearly as shell than as a chain of Ruby system_command calls.
    script = <<~SH
      claude_bin=""
      if command -v claude >/dev/null 2>&1; then
        claude_bin="$(command -v claude)"
      elif [ -x "$HOME/.local/bin/claude" ]; then
        # `brew install` postflight scripts run outside the user's login
        # shell, so PATH does not include whatever an interactive shell's
        # rc file adds. $HOME/.local/bin is where the Claude Code CLI's own
        # installer places the binary, so check it directly as a fallback
        # rather than trusting PATH alone.
        claude_bin="$HOME/.local/bin/claude"
      fi

      # No claude CLI found at all: nothing to do here, the caveats' manual
      # fallback is the catch-all.
      if [ -z "$claude_bin" ]; then
        exit 0
      fi

      # Three-way branch on the shiibar-cc@shiibar-cc entry in enabledPlugins
      # (DESIGN.md §8.28). Matched with grep, not jq, since jq may not be
      # installed (scripts/dev-install.sh has the same grep fallback for the
      # `true` value):
      #
      # 1. No entry: first install — add the marketplace and install the
      #    plugin.
      # 2. Entry with value `true` (plugin enabled): refresh the hooks so a
      #    `brew upgrade` delivers them together with the app, without
      #    depending on the user's marketplace auto-update setting (off by
      #    default for third-party marketplaces). Both commands are needed,
      #    in this order — verified against the real CLI: `marketplace
      #    update` only refreshes the marketplace clone (the installed
      #    plugin stays at its old version), and `plugin update` only
      #    installs the newest version already present in that clone (it
      #    does not refresh the clone itself).
      # 3. Entry with any other value (e.g. `false`): do nothing — never
      #    re-enable or refresh a plugin the user deliberately disabled or
      #    removed.
      settings="$HOME/.claude/settings.json"
      if [ -f "$settings" ] && grep -q '"shiibar-cc@shiibar-cc"[[:space:]]*:' "$settings"; then
        if grep -q '"shiibar-cc@shiibar-cc"[[:space:]]*:[[:space:]]*true' "$settings"; then
          "$claude_bin" plugin marketplace update shiibar-cc || true
          "$claude_bin" plugin update shiibar-cc@shiibar-cc || true
        fi
        exit 0
      fi

      "$claude_bin" plugin marketplace add bufferings/shiibar-cc || true
      "$claude_bin" plugin install shiibar-cc@shiibar-cc || true
    SH

    system_command "/bin/bash", args: ["-c", script]
  end

  uninstall quit: "cc.shiibar.menubar"

  zap trash: [
    "~/.local/state/shiibar-cc",
    "~/Library/Preferences/cc.shiibar.menubar.plist",
    "~/Library/Saved Application State/cc.shiibar.menubar.savedState",
  ]

  caveats do
    <<~EOS
      Shiibar CC tried to install its Claude Code hooks plugin automatically
      (skipped if it was already installed, disabled, or removed; skipped if
      the claude CLI wasn't found). While the plugin stays enabled, every
      brew upgrade of this cask also updates the hooks to match the app
      (running Claude Code sessions pick that up on their next restart).
      To install the plugin yourself, or if the automatic install didn't
      work:

        claude plugin marketplace add bufferings/shiibar-cc
        claude plugin install shiibar-cc@shiibar-cc

      Open Shiibar CC once to grant the notification and iTerm2 Automation
      permissions it needs (it registers itself as a Login Item on that
      first launch too). Then verify everything end to end from the ⌄ menu's
      Setup Check, or from a terminal:

        shiibar-cc doctor

      To remove the hooks plugin: claude plugin uninstall shiibar-cc

      The notification permission has no removal command — revoke it
      yourself from System Settings > Notifications > Shiibar CC.
    EOS
  end
end
