// Logging the windows the app did not create (DESIGN.md §4.5 "making
// failures visible", §8.65): the system can show a panel inside the app's
// process (for example for a text field), and the panel's class name in
// the log tells which feature it belongs to. The windows the app shows in
// normal use are not logged. Logging never changes a window's display,
// focus or level.

import Foundation

/// What a window shown in the app's process is, as far as the log rule
/// cares.
public enum ShownWindowKind: Equatable, Sendable {
    /// The popover's window, or a window that hosts the popover.
    case popover
    /// The app's own window (the list in the window form).
    case mainWindow
    /// The Settings window.
    case settings
    /// The standard About panel.
    case aboutPanel
    /// A menu (the ⌄ menu, a row's more-button menu, the app menu, a
    /// popup button's menu).
    case menu
    /// A tooltip.
    case tooltip
    /// The menu bar icon's window.
    case statusItem
    /// Anything else: a window the app did not create.
    case other
}

public enum UnownedWindowLog {
    /// Whether a window just shown gets its log line: only a window the app
    /// did not create, and only once while it stays shown.
    public static func shouldRecord(kind: ShownWindowKind, recordedWhileShown: Bool) -> Bool {
        kind == .other && !recordedWhileShown
    }

    /// The kind of a window the app holds no handle for, from its class
    /// name only: menus, tooltips, the popover's own windows and the menu
    /// bar icon's window; anything else is `.other`. The window level is
    /// not used: a system panel can be shown at the same level as a menu,
    /// and excluding by level would leave exactly that panel unlogged
    /// (DESIGN.md §4.5 "making failures visible"). The app's own windows
    /// (the main window, the popover's content window, Settings, the About
    /// panel, the status item's window) are recognized by identity before
    /// this is asked.
    public static func kind(className: String) -> ShownWindowKind {
        if className.contains("Menu") { return .menu }
        if className.contains("ToolTip") || className.contains("Tooltip") { return .tooltip }
        if className.contains("Popover") { return .popover }
        if className.contains("StatusBar") || className.contains("StatusItem") { return .statusItem }
        return .other
    }

    /// When the on-screen windows are listed after the popover or the
    /// window is shown, in seconds (DESIGN.md §9).
    public static let scanDelays: [Double] = [0.5, 2]

    /// Stands in for the class name of an on-screen window that no
    /// `NSWindow` of the app corresponds to.
    public static let noNSWindowClassName = "<no NSWindow>"

    /// The log line: class name, size and level.
    public static func line(className: String, width: Double, height: Double, level: Int) -> String {
        "window not created by the app shown: class=\(className) size=\(Int(width.rounded()))x\(Int(height.rounded())) level=\(level)"
    }
}

/// One window of the app's process found in the on-screen window list,
/// with what the app knows about it.
public struct ScannedWindow: Equatable, Sendable {
    /// The window number (shared by the window list and `NSWindow`).
    public let number: Int
    /// The matching `NSWindow`'s class name; nil when none matches.
    public let className: String?
    /// The matching window's kind (`.other` when no `NSWindow` matches).
    public let kind: ShownWindowKind
    public let width: Double
    public let height: Double
    public let level: Int

    public init(number: Int, className: String?, kind: ShownWindowKind, width: Double, height: Double, level: Int) {
        self.number = number
        self.className = className
        self.kind = kind
        self.width = width
        self.height = height
        self.level = level
    }
}

/// Remembers which windows were logged while shown, so each one is logged
/// once per showing, whichever detection found it (the window
/// notifications or the on-screen window list): a window hidden and shown
/// again (AppKit may reuse a panel instance) is logged again. Windows are
/// identified by their window number.
public struct UnownedWindowTracker: Sendable {
    private var recorded: Set<Int> = []

    public init() {}

    /// A window became visible: returns true when it must be logged now.
    public mutating func windowShown(_ number: Int, kind: ShownWindowKind) -> Bool {
        let record = UnownedWindowLog.shouldRecord(kind: kind, recordedWhileShown: recorded.contains(number))
        if record { recorded.insert(number) }
        return record
    }

    /// The window is no longer shown (ordered out or closed).
    public mutating func windowHidden(_ number: Int) {
        recorded.remove(number)
    }

    /// The on-screen window list of the app's process: every listed window
    /// counts as shown, and a logged window missing from the list as
    /// hidden. Returns the lines to log.
    public mutating func scanned(_ windows: [ScannedWindow]) -> [String] {
        let listed = Set(windows.map(\.number))
        recorded = recorded.intersection(listed)
        return windows.compactMap { window in
            guard windowShown(window.number, kind: window.className == nil ? .other : window.kind) else { return nil }
            return UnownedWindowLog.line(
                className: window.className ?? UnownedWindowLog.noNSWindowClassName,
                width: window.width, height: window.height, level: window.level)
        }
    }
}
