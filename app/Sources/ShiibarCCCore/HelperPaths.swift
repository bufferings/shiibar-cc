// Which absolute path to invoke for the bundled `shiibar-cc` / `shiibar-ccd`
// binaries (DESIGN.md §4.5 "同梱"): when running as a `.app`, always the
// bundled `Contents/Helpers/<binary>` absolute path (PATH-independent); in
// development (`swift run`, before `.app` bundling exists) fall back to the
// bare binary name, resolved via PATH by the subprocess launcher. This is
// the one place that difference is allowed to live (task brief M4 §1).

import Foundation

public enum HelperBinary: String, Sendable {
    case shiibarCc = "shiibar-cc"
    case shiibarCcd = "shiibar-ccd"
}

public enum HelperPathResolver {
    /// - Parameter helpersDirectory: the `.app`'s `Contents/Helpers`
    ///   directory, if running inside a bundle; `nil` in development.
    /// - Returns: an absolute path when `helpersDirectory` is given,
    ///   otherwise the bare binary name (for PATH lookup by the process
    ///   launcher).
    public static func resolvedPath(for binary: HelperBinary, helpersDirectory: URL?) -> String {
        guard let helpersDirectory else {
            return binary.rawValue
        }
        return helpersDirectory.appendingPathComponent(binary.rawValue).path
    }
}
