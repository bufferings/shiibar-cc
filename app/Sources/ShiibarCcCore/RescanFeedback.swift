// Manual Rescan (`shiibar-cc reconcile` from the dropdown's ⌄ menu) transient
// feedback (DESIGN.md §4.5, §9): decides what the topbar should show, and for
// how long, given the rescan's lifecycle. Pure state only, same split as
// NotificationLogic's delayed re-check — the Timer/DispatchQueue that clears
// a terminal state after `displaySeconds` lives in the app layer (AppState).

import Foundation

/// One state of the transient "Rescanning… / ✓ Rescan done / Rescan failed"
/// text shown next to the ⌄ button. `nil` (no case) means nothing is shown;
/// callers model "no feedback" as an `Optional<RescanFeedback>` rather than
/// adding an `.idle` case here.
public enum RescanFeedback: Equatable, Sendable {
    case running
    case success
    case failure

    /// How long a terminal state (`.success` / `.failure`) stays on screen
    /// before it's cleared (§9: Rescan transient-display duration = 2
    /// seconds). Not consulted for `.running`, which stays until the run
    /// finishes.
    public static let displaySeconds: Double = 2

    /// The feedback for a finished manual reconcile run, given its exit
    /// code. Returns `nil` for exit 3 (TCC): that failure keeps going
    /// through the existing warning-row path (`AppState.noteExitCode`)
    /// unchanged (M5 T2 brief) and must not also flash "Rescan failed" here.
    public static func forFinishedExitCode(_ exitCode: Int32) -> RescanFeedback? {
        switch exitCode {
        case 0: return .success
        case 3: return nil
        default: return .failure
        }
    }
}
