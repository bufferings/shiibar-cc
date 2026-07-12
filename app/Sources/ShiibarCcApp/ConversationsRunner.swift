// Async, line-streaming, cancellable subprocess runner for the Conversations
// window (DESIGN.md §4.6, task brief M35 T2). The dropdown's `CLIRunner` is
// synchronous and buffers the whole output — unusable here, where the window
// must: read `conversations index --json` progress line-by-line while it
// runs; terminate an in-flight `conversations search` when a newer keystroke
// arrives (SIGTERM mid-catch-up is safe — the SQLite discipline in §4.6
// leaves the index consistent); and, for `show`, collect a payload that can
// reach ~280KB (§7-6) without deadlocking on a full pipe. So stdout is
// drained continuously (not only at exit), which both streams lines and
// keeps the child from blocking.
//
// Path resolution and the augmented-PATH environment are shared with
// `CLIRunner` (`shiibarCcPath` / `SubprocessEnvironment`): absolute path in a
// `.app`, `/usr/bin/env` PATH lookup in a dev build.

import Foundation
import os

/// os_log sink for the conversations runner, same subsystem/category
/// convention as `CLIRunner`'s `subprocessLog`.
///   log show --last 1h --predicate 'subsystem == "cc.shiibar.menubar" AND category == "conversations"'
private let conversationsRunnerLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "cc.shiibar.menubar",
    category: "conversations"
)

/// A running `shiibar-cc conversations` subprocess. `cancel()` sends SIGTERM;
/// `wasCancelled` lets the caller ignore the completion of a run it
/// deliberately terminated (the view model also guards with a generation
/// token). `@unchecked Sendable`: all mutable state is guarded by `lock`.
final class ConversationsProcess: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var cancelledFlag = false

    init(process: Process) {
        self.process = process
    }

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledFlag
    }

    /// Terminate the subprocess (§4.6: a search cancelled mid-catch-up is
    /// safe). Idempotent; a no-op once the process has already exited.
    func cancel() {
        lock.lock()
        cancelledFlag = true
        let running = process.isRunning
        lock.unlock()
        if running {
            process.terminate()
        }
    }
}

enum ConversationsRunner {
    /// Bound on captured stderr surfaced to a completion (matches
    /// `CLIRunner.stderrLogLimitBytes`).
    private static let stderrLimitBytes = 500

    /// Launch a streaming run: `onLine` fires on the main actor for each
    /// complete stdout line as it arrives (index progress), `completion`
    /// fires once on the main actor with the exit code. Returns nil if the
    /// process failed to even launch (completion is still called with exit
    /// 1). Used for `conversations index --json`.
    @discardableResult
    static func runStreaming(
        arguments: [String],
        helpersDirectory: URL?,
        onLine: @escaping @MainActor (String) -> Void,
        completion: @escaping @MainActor (Int32) -> Void
    ) -> ConversationsProcess? {
        let process = Process()
        configure(process, arguments: arguments, helpersDirectory: helpersDirectory)
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let queue = DispatchQueue(label: "cc.shiibar.menubar.conversations-runner.stream")
        var pending = Data()

        func drain(_ data: Data, flushRemainder: Bool) {
            pending.append(data)
            while let newlineIndex = pending.firstIndex(of: 0x0A) {
                let lineData = pending.subdata(in: pending.startIndex..<newlineIndex)
                pending.removeSubrange(pending.startIndex...newlineIndex)
                emit(lineData, onLine)
            }
            if flushRemainder {
                emit(pending, onLine)
                pending.removeAll()
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            queue.async { drain(data, flushRemainder: false) }
        }

        process.terminationHandler = { proc in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            let rest = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let code = proc.terminationStatus
            queue.async {
                drain(rest, flushRemainder: true)
                Task { @MainActor in completion(code) }
            }
        }

        return launch(process, arguments: arguments, completion: { completion($0) })
    }

    /// Launch a one-shot run: `completion` fires once on the main actor with
    /// the exit code and the full stdout/stderr. stdout is drained
    /// continuously so a large `show` payload can't deadlock on a full pipe.
    /// Returns nil if the process failed to launch (completion still called,
    /// exit 1). Used for `conversations search --json` and `show --json`.
    @discardableResult
    static func run(
        arguments: [String],
        helpersDirectory: URL?,
        completion: @escaping @MainActor (CLIRunResult) -> Void
    ) -> ConversationsProcess? {
        let process = Process()
        configure(process, arguments: arguments, helpersDirectory: helpersDirectory)
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let queue = DispatchQueue(label: "cc.shiibar.menubar.conversations-runner.oneshot")
        var collected = Data()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            queue.async { collected.append(data) }
        }

        process.terminationHandler = { proc in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            let rest = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let code = proc.terminationStatus
            queue.async {
                collected.append(rest)
                let stdout = String(data: collected, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData.prefix(stderrLimitBytes), encoding: .utf8) ?? ""
                Task { @MainActor in
                    completion(CLIRunResult(exitCode: code, stdout: stdout, stderr: stderr))
                }
            }
        }

        return launch(process, arguments: arguments) { code in
            completion(CLIRunResult(exitCode: code, stdout: "", stderr: ""))
        }
    }

    /// Decode one stdout line and hand it to `onLine` on the main actor,
    /// skipping empty lines.
    private static func emit(_ lineData: Data, _ onLine: @escaping @MainActor (String) -> Void) {
        guard !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { return }
        Task { @MainActor in onLine(line) }
    }

    /// Shared executable/arguments/environment setup (mirrors `CLIRunner`).
    private static func configure(_ process: Process, arguments: [String], helpersDirectory: URL?) {
        let path = CLIRunner.shiibarCcPath(helpersDirectory: helpersDirectory)
        if path.contains("/") {
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
        } else {
            // Development: resolve via PATH, same as a shell would.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [path] + arguments
        }
        process.environment = SubprocessEnvironment.withAugmentedPath()
    }

    /// Run the configured process, logging and reporting a launch failure as
    /// exit 1 (§4.6: subprocess failures must never be silently swallowed).
    private static func launch(
        _ process: Process,
        arguments: [String],
        completion: @escaping @MainActor (Int32) -> Void
    ) -> ConversationsProcess? {
        do {
            try process.run()
        } catch {
            let commandLine = "shiibar-cc " + arguments.joined(separator: " ")
            conversationsRunnerLog.error(
                "failed to launch \(commandLine, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            Task { @MainActor in completion(1) }
            return nil
        }
        return ConversationsProcess(process: process)
    }
}
