// cwd -> display label formatting (DESIGN.md §4.5): show only the last two
// path components (or fewer, if the path is shorter), computed on the
// home-relative path when `cwd` is under the home directory (no `~/`
// prefix — it carried no information since everything lives under home;
// `cwd` == home itself still shows as `~`). This is a
// direct port of `shiibar-cc-client::label::format_cwd_label` (Rust) — the
// spec (§4.5) requires the CLI and the app to agree on the exact same
// rule, and since the app can't share that Rust crate (§8.5), the rule is
// duplicated here deliberately (not delegated to a subprocess call, since
// this needs to run per-row on every dropdown redraw).

import Foundation

public enum CwdLabel {
    /// Format `cwd` for display. `home` is `$HOME` (or nil if unknown/empty,
    /// in which case this always falls back to "last two path components,
    /// no prefix" — mirrors the Rust implementation's documented fallback
    /// for a cwd outside the home directory).
    public static func format(cwd: String, home: String?) -> String {
        let isHomeRelative: Bool = {
            guard let home, !home.isEmpty else { return false }
            return cwd == home || cwd.hasPrefix(home + "/")
        }()

        let componentSource: Substring
        if isHomeRelative, let home {
            componentSource = cwd[cwd.index(cwd.startIndex, offsetBy: home.count)...]
        } else {
            componentSource = cwd[...]
        }

        let components = componentSource.split(separator: "/", omittingEmptySubsequences: true)
        let tailStart = max(0, components.count - 2)
        let tail = components[tailStart...].joined(separator: "/")

        if isHomeRelative && tail.isEmpty {
            return "~"
        }
        return tail
    }
}
