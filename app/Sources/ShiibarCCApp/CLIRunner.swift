// Subprocess calls into the `shiibar-cc` CLI (DESIGN.md §4.5): focus,
// reconcile, and the front-most-check `focused` used for delayed-notification
// suppression. Exit codes per DESIGN.md §4.4: 0 success, 2 not found, 3
// TCC (osascript permission) error.

import Foundation
import ShiibarCCCore

struct CLIRunResult {
    let exitCode: Int32
    let stdout: String
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
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return CLIRunResult(exitCode: 1, stdout: "")
        }
        process.waitUntilExit()
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: data, encoding: .utf8) ?? ""
        return CLIRunResult(exitCode: process.terminationStatus, stdout: stdout)
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
    /// foreground" outcome, not an error.
    static func focusedTarget(helpersDirectory: URL?) -> String? {
        let result = run(["focused"], helpersDirectory: helpersDirectory)
        guard result.exitCode == 0 else { return nil }
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
