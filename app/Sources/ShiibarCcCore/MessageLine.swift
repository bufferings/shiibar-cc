// The fixed footer's message line (DESIGN.md §4.5 "fixed footer", §4.6
// "message line") and the outcome rules of the row verbs (§4.5 "popover" /
// "action buttons", §4.6 "Resume and Branch" / "Jump"). Timers that clear a
// transient after §9's 2 seconds live in the app; the texts, the priority
// and the success / failure decisions live here.

import Foundation

/// A transient message of the message line (§4.5 "fixed footer", §4.6
/// "search field" / "message line"): the Refresh states. The app holds at
/// most one; a newer transient replaces an older one.
public enum MessageTransient: Equatable, Sendable {
    /// Refresh in flight (until the ⟳ rotation stops).
    case refreshing
    /// Refresh finished: the search and the reconcile both succeeded.
    case refreshDone
    /// Refresh finished: the search succeeded and the reconcile failed with
    /// an error other than TCC (exit 3).
    case refreshFailed

    public var text: String {
        switch self {
        case .refreshing:
            return "Refreshing\u{2026}"
        case .refreshDone:
            return "\u{2713} Refresh done"
        case .refreshFailed:
            return "Refresh failed"
        }
    }

    /// §9: how long a finished Refresh's transient stays (`.refreshing`
    /// stays until the run ends).
    public static let displaySeconds: Double = 2
}

/// What a finished Refresh shows (DESIGN.md §4.6 "search field" table),
/// from the results of its search and its `shiibar-cc reconcile`:
///
/// | search  | reconcile         | shown                                    |
/// |---------|-------------------|------------------------------------------|
/// | success | exit 0            | `✓ Refresh done` (transient)             |
/// | success | exit 3 (TCC)      | no transient; the TCC warning row        |
/// | success | any other failure | `Refresh failed` (transient)             |
/// | failure | any               | no transient (the search pipeline shows  |
/// |         |                   | `Search failed`); also the TCC warning   |
/// |         |                   | row when the reconcile exited 3          |
///
/// The `Search failed` error itself is set by the search pipeline for every
/// search trigger (§4.6), so it is not part of this decision.
public struct RefreshOutcome: Equatable, Sendable {
    /// The transient that replaces `Refreshing…`; nil = the line clears.
    public let transient: MessageTransient?
    /// The reconcile hit the Automation permission error (exit 3): raise the
    /// shared warning row (§4.5 "making failures visible").
    public let raisesAutomationWarning: Bool

    public init(transient: MessageTransient?, raisesAutomationWarning: Bool) {
        self.transient = transient
        self.raisesAutomationWarning = raisesAutomationWarning
    }

    public static func decide(searchSucceeded: Bool, reconcileExitCode: Int32) -> RefreshOutcome {
        let permissionDenied = reconcileExitCode == 3
        guard searchSucceeded else {
            return RefreshOutcome(transient: nil, raisesAutomationWarning: permissionDenied)
        }
        switch reconcileExitCode {
        case 0:
            return RefreshOutcome(transient: .refreshDone, raisesAutomationWarning: false)
        case 3:
            return RefreshOutcome(transient: nil, raisesAutomationWarning: true)
        default:
            return RefreshOutcome(transient: .refreshFailed, raisesAutomationWarning: false)
        }
    }
}

/// Errors the message line shows. An error clears on the next successful
/// fetch (§4.6); clearing is the app's job.
public enum MessageLineError: Equatable, Sendable {
    case indexFailed
    case searchFailed
    case jumpFailed
    case resumeFailed
    case branchFailed

    public var text: String {
        switch self {
        case .indexFailed: return "Indexing failed"
        case .searchFailed: return "Search failed"
        case .jumpFailed: return "Jump failed"
        case .resumeFailed: return "Resume failed"
        case .branchFailed: return "Branch failed"
        }
    }
}

public enum MessageLine {
    /// `Indexing N of M…` (§4.6; window-design.html writes the count with a
    /// thousands separator: `Indexing 340 of 4,200…`).
    public static func indexProgressText(done: Int, total: Int) -> String {
        "Indexing \(grouped(done)) of \(grouped(total))\u{2026}"
    }

    /// The line to show, or nil to hide the line (§4.6 priority: index
    /// progress > error > transient).
    public static func text(indexProgress: (done: Int, total: Int)?, error: MessageLineError?, transient: MessageTransient?) -> String? {
        if let indexProgress {
            return indexProgressText(done: indexProgress.done, total: indexProgress.total)
        }
        if let error {
            return error.text
        }
        return transient?.text
    }

    private static func grouped(_ value: Int) -> String {
        let digits = String(value.magnitude)
        var out = ""
        for (index, character) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 {
                out.append(",")
            }
            out.append(character)
        }
        return value < 0 ? "-" + out : out
    }
}

/// What the app does after a row verb's subprocess exits (§4.5 / §4.6).
public enum RowInvocationOutcome: Equatable, Sendable {
    /// Exit 0: the popover closes (the window stays). Resume / Branch re-run
    /// the search right after (`refetchHistory`); Jump does not.
    case succeeded(refetchHistory: Bool)
    /// Jump exit 2 (no such tab): no error, the popover stays open.
    case targetNotFound
    /// Exit 3 (TCC): the shared warning row; the popover stays open.
    case permissionDenied
    /// Any other failure: show `error` on the message line; the popover stays
    /// open. (The exit code and stderr go to os_log — app side.)
    case failed(MessageLineError)

    /// Whether the popover closes after this outcome.
    public var closesPopover: Bool {
        if case .succeeded = self { return true }
        return false
    }

    public static func classify(_ invocation: RowInvocation, exitCode: Int32) -> RowInvocationOutcome {
        switch (invocation, exitCode) {
        case (.jump, 0):
            return .succeeded(refetchHistory: false)
        case (.resume, 0), (.branch, 0):
            return .succeeded(refetchHistory: true)
        case (.jump, 2):
            return .targetNotFound
        case (_, 3):
            return .permissionDenied
        case (.jump, _):
            return .failed(.jumpFailed)
        case (.resume, _):
            return .failed(.resumeFailed)
        case (.branch, _):
            return .failed(.branchFailed)
        }
    }
}
