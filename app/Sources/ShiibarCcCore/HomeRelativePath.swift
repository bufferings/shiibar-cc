// Home-relative full path for the Conversations preview header (DESIGN.md
// §4.6 / conversations-design.html: the right pane's second line is the
// FULL home-relative path — `~/Documents/blog` form — plus elapsed time,
// deliberately more detailed than the list's two-component folder label so
// the resume destination is unambiguous). The list rows use `CwdLabel`
// instead (last two components). Ported here rather than delegated to a
// subprocess: it runs per selection in the view.

import Foundation

public enum HomeRelativePath {
    /// Format `path` for display. When `path` is the home directory or under
    /// it, the home prefix collapses to `~` (`~/Documents/blog`); otherwise
    /// the absolute path is returned unchanged. `home` nil/empty => the
    /// absolute path.
    public static func format(_ path: String, home: String?) -> String {
        guard let home, !home.isEmpty else { return path }
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            let suffix = path[path.index(path.startIndex, offsetBy: home.count)...]
            return "~" + suffix
        }
        return path
    }
}
