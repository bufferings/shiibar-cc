// When the app is a regular app, and when a hotkey-opened window moves the
// focus to the list (DESIGN.md §4.5 "the app is a regular app only while
// the window is open" / "global hotkey", §8.30 / §8.61). The activation
// policy calls and the focus moves live in the app; the decisions live here
// so tests pin them.

import Foundation

/// What keeps the app a regular app (§4.5 / §8.30): the open window, or —
/// after `Open in popover` closed the window — the popover that operation
/// opened. Returning to accessory while the popover is shown may deactivate
/// the app, which would close the popover; keeping the app regular until
/// the popover closes does not depend on that.
public struct RegularAppHold: Equatable, Sendable {
    public enum Holder: Equatable, Sendable {
        /// Accessory app.
        case none
        /// The window is open.
        case window
        /// `Open in popover` closed the window; the popover it opened is
        /// shown.
        case popoverFromWindow
    }

    public enum Effect: Equatable, Sendable {
        case switchToRegular
        case switchToAccessory
    }

    public private(set) var holder: Holder = .none

    public init() {}

    /// The window opened. From the popover `Open in popover` opened, the
    /// app is already regular: no second switch.
    public mutating func windowOpened() -> Effect? {
        let wasAccessory = holder == .none
        holder = .window
        return wasAccessory ? .switchToRegular : nil
    }

    /// The window closed. `forOpenInPopover`: the app stays regular until
    /// the popover that operation opens closes; every other close (red
    /// button, ⌘W, tray click, hotkey) returns to accessory at once.
    public mutating func windowClosed(forOpenInPopover: Bool) -> Effect? {
        guard holder == .window else { return nil }
        if forOpenInPopover {
            holder = .popoverFromWindow
            return nil
        }
        holder = .none
        return .switchToAccessory
    }

    /// The popover closed: back to accessory when it was the popover
    /// `Open in popover` opened.
    public mutating func popoverClosed() -> Effect? {
        guard holder == .popoverFromWindow else { return nil }
        holder = .none
        return .switchToAccessory
    }

    /// Whether the activation that completes a switch to a regular app may
    /// still run: only while the window it was for is open, so the app is
    /// never left active with no window after a quick close.
    public var allowsDeferredActivation: Bool { holder == .window }
}

/// The list focus owed to a window the hotkey opened from closed (§4.5
/// "global hotkey"). The focus moves once the window has become key, so
/// it acts on the first responder the window has after being ordered in
/// and made key rather than on a window that is still being shown. Only
/// the next become-key within `validSeconds` of the open uses it; raising
/// or closing the window, or a new open, drops it.
public struct HotKeyListFocusPending: Equatable, Sendable {
    /// How long after the open a become-key still counts as the open's own:
    /// the switch to a regular app activates the app about 0.1 seconds after
    /// the open (`AppState`), and the window becomes key then. A later key
    /// change is the user's own and must not move the focus.
    public static let validSeconds: TimeInterval = 1

    private var openedAt: TimeInterval?

    public init() {}

    public var isPending: Bool { openedAt != nil }

    /// The hotkey opened the window at `now` (system uptime).
    public mutating func openedByHotKey(at now: TimeInterval) {
        openedAt = now
    }

    /// The window was raised, closed, or opened another way.
    public mutating func clear() {
        openedAt = nil
    }

    /// The window became key at `now`: whether to move the focus to the
    /// list. The pending focus is used at most once, and dropped when it has
    /// expired.
    public mutating func windowBecameKey(at now: TimeInterval) -> Bool {
        guard let openedAt else { return false }
        self.openedAt = nil
        return now - openedAt <= Self.validSeconds
    }
}
