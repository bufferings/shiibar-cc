// Whether a surface counted as key when the mouse button went down
// (DESIGN.md §4.5 "row selection" / "row click"). The decision feeds
// `UnifiedListEvent.pointerDown`.
//
// Reading the window's key status when the press is handled is not enough.
// A click on a window of an inactive app also activates the app, and AppKit
// can make the app's window key while it processes that activation, before
// the mouse-down event itself is dispatched. The window then already reads
// as key although it was not key when the user pressed. The press carries the time it happened (`NSEvent.timestamp`, in
// the system-uptime timebase); a key status gained at or after that time was
// gained by this very click, so the surface did not count as key.

import Foundation

public enum SurfaceKeyAtPress {
    /// - Parameters:
    ///   - isKeyNow: the window's key status when the press is handled.
    ///   - becameKeyAt: when the window last became key (system uptime,
    ///     seconds); nil when unknown.
    ///   - pressedAt: the press's own time (`NSEvent.timestamp`).
    public static func wasKey(isKeyNow: Bool, becameKeyAt: TimeInterval?, pressedAt: TimeInterval) -> Bool {
        guard isKeyNow else { return false }
        guard let becameKeyAt else { return true }
        return becameKeyAt < pressedAt
    }
}
