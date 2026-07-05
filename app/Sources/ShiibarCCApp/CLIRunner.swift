// Subprocess calls into the `shiibar-cc` CLI (DESIGN.md §4.5): focus,
// reconcile, and the front-most-check `focused` used for delayed-notification
// suppression. Exit codes per DESIGN.md §4.4: 0 success, 2 not found, 3
// TCC (osascript permission) error.
//
// Every failure (nonzero exit, or failure to launch at all) is recorded to
// os_log with the exit code and (bounded) stderr — §4.5: subprocess
// failures must never be silently swallowed. The menu bar app needs its
// OWN Automation (TCC) permission for iTerm2, separate from any terminal's,
// so an app-run `reconcile`/`focus` can fail with exit 3 even though the
// same command works from a shell; the log line tells the two failure
// shapes apart (a run that exited nonzero logs code + stderr; a subprocess
// that never ran logs a launch failure; no line at all means the call path
// never executed).

import Foundation
import os
import ShiibarCCCore

/// os_log sink for subprocess diagnostics. Subsystem = the bundle id
/// (`cc.shiibar.menubar` in the installed .app; same literal as fallback in
/// dev builds, where Bundle.main has no identifier), category "subprocess".
/// Inspect with:
///   log show --last 1h --predicate 'subsystem == "cc.shiibar.menubar" AND category == "subprocess"'
private let subprocessLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "cc.shiibar.menubar",
    category: "subprocess"
)

/// Bound on how much captured stderr goes into a log line.
private let stderrLogLimitBytes = 500

struct CLIRunResult {
    let exitCode: Int32
    let stdout: String
    /// Captured stderr, truncated to `stderrLogLimitBytes`.
    let stderr: String
}

enum CLIRunner {
    /// Absolute path in a `.app` build, bare name (PATH lookup) in
    /// development (task brief M4 §1 / HelperPathResolver).
    static func shiibarCcPath(helpersDirectory: URL?) -> String {
        HelperPathResolver.resolvedPath(for: .shiibarCc, helpersDirectory: helpersDirectory)
    }

    @discardableResult
    static func run(_ arguments: [String], helpersDirectory: URL?) -> CLIRunResult {
        let process = Process()
        let path = shiibarCcPath(helpersDirectory: helpersDirectory)
        if path.contains("/") {
            process.executableURL = URL(fileURLWithPath: path)
        } else {
            // Development: resolve via PATH, same as a shell would.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [path] + arguments
        }
        if process.arguments == nil {
            process.arguments = arguments
        }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let commandLine = "shiibar-cc " + arguments.joined(separator: " ")
        do {
            try process.run()
        } catch {
            subprocessLog.error(
                "failed to launch \(commandLine, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return CLIRunResult(exitCode: 1, stdout: "", stderr: "")
        }
        process.waitUntilExit()
        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: stderrData.prefix(stderrLogLimitBytes), encoding: .utf8)
            ?? String(decoding: stderrData.prefix(stderrLogLimitBytes), as: UTF8.self)
        if process.terminationStatus != 0 {
            subprocessLog.error(
                "\(commandLine, privacy: .public) exited \(process.terminationStatus): \(stderr, privacy: .public)"
            )
        }
        return CLIRunResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    /// `shiibar-cc focus <target>` (dropdown row click, §4.5).
    static func focus(target: String, helpersDirectory: URL?) -> CLIRunResult {
        run(["focus", target], helpersDirectory: helpersDirectory)
    }

    /// `shiibar-cc focus -` (⌄ menu "Back", §4.5/§8.4).
    static func focusBack(helpersDirectory: URL?) -> CLIRunResult {
        run(["focus", "-"], helpersDirectory: helpersDirectory)
    }

    /// `shiibar-cc reconcile` (startup / reconnect / ⌄ menu "Rescan", §3.5/§4.5).
    static func reconcile(helpersDirectory: URL?) -> CLIRunResult {
        run(["reconcile"], helpersDirectory: helpersDirectory)
    }

    /// `shiibar-cc focused` — front-most iTerm2 session's target, used to
    /// suppress a delayed notification for a target the user already
    /// jumped to (§4.5). Exit code 2 (no match) is a normal "not
    /// foreground" outcome, not an error; exit 3 (TCC) must reach the
    /// caller so the warning row can trigger (§4.5), hence the exit code
    /// is returned alongside the target.
    static func focusedTarget(helpersDirectory: URL?) -> (target: String?, exitCode: Int32) {
        let result = run(["focused"], helpersDirectory: helpersDirectory)
        guard result.exitCode == 0 else { return (nil, result.exitCode) }
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty ? nil : trimmed, 0)
    }
}
