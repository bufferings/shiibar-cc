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

/// Environment for every subprocess the app runs (CLIRunner's helpers AND
/// the spawned daemon): the inherited environment with an augmented PATH.
///
/// An app launched from Finder/Login Items inherits launchd's minimal PATH
/// (`/usr/bin:/bin:/usr/sbin:/sbin`). The `shiibar-cc` helper itself is
/// called by absolute path, but `shiibar-cc reconcile` internally spawns
/// `claude` via PATH — and claude's native install location is
/// `~/.local/bin`, which the minimal PATH lacks. On-device evidence: in
/// that environment reconcile printed "scan was incomplete; sent
/// complete:false" and exited 0, silently reducing every app-run reconcile
/// to a no-op (the §3.5 degrade is correct CLI behavior; the app just has
/// to provide a PATH where claude can be found). Homebrew's bin dirs are
/// appended for good measure; duplicate entries are harmless.
enum SubprocessEnvironment {
    static func withAugmentedPath() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extras = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        let current = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = current + ":" + extras.joined(separator: ":")
        return environment
    }
}

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

    /// `expectedExitCodes`: exit codes that are NORMAL outcomes for this
    /// call site (per DESIGN.md §4.4 semantics), logged at debug instead of
    /// error so routine probes don't pollute the error log (e.g. `focused`
    /// exits 2 whenever iTerm2 simply isn't frontmost). Exit 3 (TCC) is
    /// never expected anywhere — it always error-logs, and callers raise
    /// the warning row from the returned exit code regardless of logging.
    @discardableResult
    static func run(
        _ arguments: [String],
        helpersDirectory: URL?,
        expectedExitCodes: Set<Int32> = [0]
    ) -> CLIRunResult {
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
        process.environment = SubprocessEnvironment.withAugmentedPath()
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
        let exitCode = process.terminationStatus
        if exitCode != 0 {
            if expectedExitCodes.contains(exitCode) {
                subprocessLog.debug(
                    "\(commandLine, privacy: .public) exited \(exitCode) (expected outcome): \(stderr, privacy: .public)"
                )
            } else {
                subprocessLog.error(
                    "\(commandLine, privacy: .public) exited \(exitCode): \(stderr, privacy: .public)"
                )
            }
        } else if !stderr.isEmpty {
            // Success with a warning on stderr: notably `shiibar-cc
            // reconcile` exits 0 but prints "scan was incomplete; sent
            // complete:false" when the gather degraded (§3.5 — the CLI
            // contract is correct, but a permanently degraded backstop must
            // not be invisible). Info level: visible with `log show --info`,
            // out of the error stream.
            subprocessLog.info(
                "\(commandLine, privacy: .public) succeeded with stderr output: \(stderr, privacy: .public)"
            )
        }
        return CLIRunResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
    }

    /// `shiibar-cc focus <target>` (dropdown row click, §4.5). Exit 2
    /// ("no match", §4.4) is expected: the target's tab can close in the
    /// window between the row rendering and the click (the stale-row race
    /// is designed in — `agent_removed` cleans the row up right after).
    static func focus(target: String, helpersDirectory: URL?) -> CLIRunResult {
        run(["focus", target], helpersDirectory: helpersDirectory, expectedExitCodes: [0, 2])
    }

    /// `shiibar-cc reconcile` (startup / reconnect / ⌄ menu "Rescan",
    /// §3.5/§4.5). Only 0 is expected: any failure (1 = daemon/gather
    /// error, 3 = TCC) silently loses the backstop and must error-log.
    static func reconcile(helpersDirectory: URL?) -> CLIRunResult {
        run(["reconcile"], helpersDirectory: helpersDirectory)
    }

    /// `shiibar-cc focused` — front-most iTerm2 session's target, used to
    /// suppress a delayed notification for a target the user already
    /// jumped to (§4.5). Exit 2 ("none", §4.4) is the routine outcome
    /// whenever iTerm2 isn't frontmost — expected, so the probe doesn't
    /// pollute the error log. Exit 3 (TCC) must reach the caller so the
    /// warning row can trigger (§4.5), hence the exit code is returned
    /// alongside the target.
    static func focusedTarget(helpersDirectory: URL?) -> (target: String?, exitCode: Int32) {
        let result = run(["focused"], helpersDirectory: helpersDirectory, expectedExitCodes: [0, 2])
        guard result.exitCode == 0 else { return (nil, result.exitCode) }
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty ? nil : trimmed, 0)
    }
}
