// State directory resolution (DESIGN.md §2/§9): `~/.local/state/shiibar-cc/`
// by default, overridable with `SHIIBAR_CC_STATE_DIR`. Mirrors
// `shiibar-ccd::paths::StateDir` (Rust) — the app needs the exact same
// socket path the daemon binds.

import Foundation

public enum StateDirectory {
    /// Resolve the state directory root from the environment, matching the
    /// Rust daemon/CLI's resolution rule exactly (`SHIIBAR_CC_STATE_DIR`,
    /// else `$HOME/.local/state/shiibar-cc`).
    public static func resolveRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let override = environment["SHIIBAR_CC_STATE_DIR"], !override.isEmpty {
            return override
        }
        guard let home = environment["HOME"], !home.isEmpty else {
            return nil
        }
        return home + "/.local/state/shiibar-cc"
    }

    public static func socketPath(root: String) -> String {
        root + "/shiibar-ccd.sock"
    }
}
