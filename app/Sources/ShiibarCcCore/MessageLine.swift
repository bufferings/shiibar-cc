// The fixed footer's message line (DESIGN.md §4.5 "fixed footer", §4.6
// "message line") and the outcome rules of the row verbs (§4.5 "popover" /
// "action buttons", §4.6 "Resume and Branch" / "Jump"). Timers that clear a
// transient after §9's 2 seconds live in the app; the texts, the priority
// and the success / failure decisions live here.

import Foundation

/// A transient message (§4.6: `Refreshing…` / `Updated · N conversations` /
/// the Rescan results). The app holds at most one; a newer transient
/// replaces an older one (assumption — §4.6 ranks them in one tier).
public enum MessageTransient: Equatable, Sendable {
    /// ⟳ in flight.
    case refreshing
    /// ⟳ finished; `count` = the search result size, Running rows included.
    case updated(count: Int)
    /// Manual Rescan state (§4.5).
    case rescan(RescanFeedback)

    public var text: String {
        switch self {
        case .refreshing:
            return "Refreshing\u{2026}"
        case .updated(let count):
            return "Updated \u{00B7} \(count) conversations"
        case .rescan(.running):
            return "Rescanning\u{2026}"
        case .rescan(.success):
            return "\u{2713} Rescan done"
        case .rescan(.failure):
            return "Rescan failed"
        }
    }

    /// §9: how long a finished transient stays (`.refreshing` and
    /// `.rescan(.running)` stay until the run ends).
    public static let displaySeconds: Double = RescanFeedback.displaySeconds
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
