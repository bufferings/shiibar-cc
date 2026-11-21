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

/// The list focus owed to a window opened from closed by the hotkey, or by
/// a notification click on a session the app cannot jump to (§4.5 "global
/// hotkey", "notification click"). The focus moves once the window has
/// become key, so it acts on the first responder the window has after
/// being ordered in and made key rather than on a window that is still
/// being shown. Only the next become-key within `validSeconds` of the open
/// uses it; raising or closing the window, or a new open, drops it.
///
/// A notification click's row selection is part of the owed work, so it
/// is not dropped when the window does not become key in time: the
/// timeout (`timeoutDue`) runs it then.
public struct PendingListFocus: Equatable, Sendable {
    /// How long after the open a become-key still counts as the open's own:
    /// the switch to a regular app activates the app about 0.1 seconds after
    /// the open (`AppState`), and the window becomes key then. A later key
    /// change is the user's own and must not move the focus.
    public static let validSeconds: TimeInterval = 1

    /// What opened the window.
    public enum Purpose: Equatable, Sendable {
        /// The hotkey: focus the list (`openedByHotKey`).
        case hotKey
        /// A notification click: select the row and focus the list
        /// (`notificationClicked(target:)`).
        case notification(target: String)
    }

    private struct Pending: Equatable, Sendable {
        let purpose: Purpose
        let openedAt: TimeInterval
        let id: Int
    }

    private var pending: Pending?
    private var nextID = 0

    public init() {}

    public var isPending: Bool { pending != nil }

    /// The window was opened from closed at `now` (system uptime) for
    /// `purpose`. Returns the id to pass to `timeoutDue` after
    /// `validSeconds`.
    @discardableResult
    public mutating func opened(for purpose: Purpose, at now: TimeInterval) -> Int {
        nextID += 1
        pending = Pending(purpose: purpose, openedAt: now, id: nextID)
        return nextID
    }

    /// The window was raised, closed, or opened another way.
    public mutating func clear() {
        pending = nil
    }

    /// The window became key at `now`: what to run, or nil. Used at most
    /// once. Past `validSeconds` the key change is the user's own: a
    /// hotkey's pending focus is dropped, and a notification click's stays
    /// for its timeout.
    public mutating func windowBecameKey(at now: TimeInterval) -> Purpose? {
        guard let current = pending else { return nil }
        if now - current.openedAt <= Self.validSeconds {
            pending = nil
            return current.purpose
        }
        if case .hotKey = current.purpose { pending = nil }
        return nil
    }

    /// `validSeconds` passed since the open with this id: a notification
    /// click still pending runs now (the window did not become key in
    /// time); a hotkey's pending focus is dropped without running.
    public mutating func timeoutDue(id: Int) -> Purpose? {
        guard let current = pending, current.id == id else { return nil }
        pending = nil
        if case .notification = current.purpose { return current.purpose }
        return nil
    }
}
