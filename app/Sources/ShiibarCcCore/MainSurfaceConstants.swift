// Numbers, persisted keys, and size arithmetic for the popover and the
// window (DESIGN.md §4.5 / §8.49 / §9). Reading screens, applying frames,
// firing haptics and the UserDefaults IO live in the app target; the values
// and the decisions live here so tests can pin them to §9.

import Foundation

/// UserDefaults keys and the window frame autosave name (M44 brief, global
/// rules).
public enum MainSurfaceDefaultsKeys {
    /// Remembered popover height (points, Double).
    public static let popoverHeight = "cc.shiibar.popoverHeight"
    /// Remembered two-column list column width (points, Double). Absent
    /// while the width follows the text size (§4.5 "column boundary drag").
    public static let listColumnWidth = "cc.shiibar.listColumnWidth"
    /// Window pin ("Keep on top"), Bool.
    public static let windowKeepOnTop = "cc.shiibar.windowKeepOnTop"
    /// Starred conversation session IDs, [String].
    public static let starredSessionIDs = "cc.shiibar.starredSessionIDs"
    /// `NSWindow.setFrameAutosaveName` for the single window.
    public static let mainWindowFrameAutosaveName = "cc.shiibar.mainWindow"
}

/// The window pin (§4.5 "pin (Keep on Top)"): default OFF; only the window
/// level changes while ON.
public enum WindowKeepOnTop {
    /// §4.5: default OFF. A missing UserDefaults value must read as this.
    public static let defaultEnabled = false
}

/// Refresh cadence while the popover or the window is visible (§4.5
/// "updates while visible", §9).
public enum MainSurfaceRefresh {
    /// §9: re-take the elapsed-time base every 60 seconds while visible.
    public static let elapsedIntervalSeconds: Double = 60
    /// §9 / §4.6 "History refetch triggers": after a Running row disappears,
    /// History is refetched at once and once more after this delay (the
    /// ending process may still be alive at the first fetch, so the
    /// conversation would still read as live).
    public static let endedRowSecondRefetchSeconds: Double = 2
}

/// The History section's display cap (§4.6 "History section", §9).
public enum HistoryDisplayLimit {
    /// §9: History shows at most this many rows (after the Running
    /// exclusion and the starred-first order). The Running section is never
    /// capped, and the cap applies to display only — the search result
    /// itself (star pruning, Running titles, the result count) is whole.
    public static let maxRows = 100
}

/// Column count of the single layout (§4.5 "switching by width").
public enum ColumnMode: Equatable, Sendable {
    /// List page and detail page, one at a time. The popover is always this.
    case one
    /// List column on the left, conversation pane on the right.
    case two

    /// The column mode for a window content width (§4.5/§9: two columns at
    /// the default list column width + 360pt or wider — 780pt at text size
    /// 13 — one column below; a remembered width does not move it). The popover never calls this — it is always `.one`.
    public static func forWindowWidth(_ width: Double, textSize: TextSize) -> ColumnMode {
        width >= textSize.twoColumnMinimumWidth ? .two : .one
    }
}

/// Window and layout sizes (§9).
public enum MainWindowMetrics {
    /// §9: first-open window size (centered on the display, §4.5).
    public static let initialWidth: Double = 420
    public static let initialHeight: Double = 640
    /// §9: minimum window size.
    public static let minimumWidth: Double = 360
    public static let minimumHeight: Double = 300
    /// §9: page slide duration (ease-in-out) in one-column mode.
    public static let pageSlideSeconds: Double = 0.22
}

/// Popover height rules (§4.5 "popover", §9). The width follows the text
/// size (`TextSize.popoverWidth`); the heights below do not.
public enum PopoverHeight {
    /// §9: first-open height, also the snap target while dragging.
    public static let initial: Double = 640
    /// §9: minimum height.
    public static let minimum: Double = 300
    /// §9: the bottom drag area's height.
    public static let dragHandleHeight: Double = 8
    /// §9: while dragging, a height within this distance of `initial`
    /// (inclusive) snaps to `initial`.
    public static let snapDistance: Double = 12

    /// Clamp a height into [minimum, maximum]. `maximum` is the tallest
    /// height that fits the display's visible area (computed by the app from
    /// the screen). When the display is shorter than `minimum`, fitting the
    /// display wins.
    public static func clamp(_ height: Double, maximum: Double) -> Double {
        min(max(height, minimum), maximum)
    }

    /// The height to open with (§4.5/§9): the remembered height when one
    /// exists (non-nil and > 0), else `initial`, clamped. A remembered value
    /// above the maximum opens at the maximum; the stored value itself is
    /// NOT rewritten (§9) — this function has no side effects, the caller
    /// must not persist its result.
    public static func heightToOpen(stored: Double?, maximum: Double) -> Double {
        let desired: Double
        if let stored, stored > 0 {
            desired = stored
        } else {
            desired = initial
        }
        return clamp(desired, maximum: maximum)
    }

    /// Whether a cursor-following height is inside the snap range (§9:
    /// within 12pt of `initial`, inclusive).
    public static func isInSnapRange(_ height: Double) -> Bool {
        abs(height - initial) <= snapDistance
    }
}

/// One bottom-edge drag of the popover (§4.5 "popover"): the height follows
/// the cursor, snaps to the initial height while within the snap range, and
/// fires one haptic (`NSHapticFeedbackManager` `.alignment`) each time the
/// drag ENTERS the range. The app creates one at mouse-down, feeds every
/// drag event, applies `height`, and persists the last `height` at
/// mouse-up.
public struct PopoverHeightDrag: Equatable, Sendable {
    /// The popover height at mouse-down.
    public let startHeight: Double
    /// Whether the previous update was inside the snap range.
    public private(set) var isSnapped: Bool
    /// The height to apply now.
    public private(set) var height: Double

    public init(startHeight: Double) {
        self.startHeight = startHeight
        self.height = startHeight
        // Starting inside the range does not count as entering it: a haptic
        // fires only on a transition from outside to inside.
        self.isSnapped = PopoverHeight.isInSnapRange(startHeight)
    }

    /// Feed the cursor's vertical travel since mouse-down (positive = the
    /// bottom edge moved down = taller). Returns whether to fire the haptic
    /// now. The raw (cursor-following) height decides the snap; the result
    /// is then clamped to [minimum, maximum].
    public mutating func update(dragDelta: Double, maximum: Double) -> Bool {
        let raw = startHeight + dragDelta
        let inRange = PopoverHeight.isInSnapRange(raw)
        let entered = inRange && !isSnapped
        isSnapped = inRange
        height = PopoverHeight.clamp(inRange ? PopoverHeight.initial : raw, maximum: maximum)
        return entered
    }

    /// The height to remember when the drag ends, or nil when the drag did
    /// not change the height (a click without a drag must not replace the
    /// stored height with the display-clamped one — §9).
    public var heightToPersist: Double? {
        height != startHeight ? height : nil
    }
}

/// The two-column list column width (§4.5 "switching by width" / "column
/// boundary drag", §8.53, §9). Without a remembered width the column takes
/// the default width, which follows the text size; a remembered width wins
/// over the text size. The two-column threshold stays on the default width
/// (`ColumnMode.forWindowWidth`) whatever is remembered. Everything here is
/// used in two columns only.
public enum ListColumnWidth {
    /// §9: the narrowest list column.
    public static let minimum: Double = 280
    /// §9: the right column keeps at least this width, the 1pt boundary
    /// line included, so the widest list column is the window width minus
    /// this.
    public static let paneMinimum: Double = TextSize.twoColumnPaneAllowance
    /// §9: the drag area's width, centered on the 1pt boundary line (4pt
    /// on each side).
    public static let dragAreaWidth: Double = 8

    /// The default width: the text size's list column width (420pt at 13).
    public static func defaultWidth(textSize: TextSize) -> Double {
        textSize.listColumnWidth
    }

    /// The widest list column for a window content width (the right column
    /// keeps `paneMinimum`).
    public static func maximum(windowWidth: Double) -> Double {
        windowWidth - paneMinimum
    }

    /// Clamp a width into [minimum, window width − paneMinimum]. When the
    /// maximum is below the minimum, the minimum wins (§4.5).
    public static func clamp(_ width: Double, windowWidth: Double) -> Double {
        max(min(width, maximum(windowWidth: windowWidth)), minimum)
    }

    /// The remembered width a stored UserDefaults entry stands for: nil
    /// (no remembered width) for a missing entry, a non-number (a Boolean
    /// included), a non-finite number, or a number at or below 0. The
    /// caller does not write the result back.
    public static func fromStored(_ stored: Any?) -> Double? {
        guard let number = stored as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value > 0 else { return nil }
        return value
    }

    /// The width to show (§4.5): the remembered width clamped into the
    /// range for the window width, or the default width when nothing is
    /// remembered. No side effects: the clamped value is never persisted,
    /// so widening the window brings the remembered width back.
    public static func shown(remembered: Double?, windowWidth: Double, textSize: TextSize) -> Double {
        guard let remembered else { return defaultWidth(textSize: textSize) }
        return clamp(remembered, windowWidth: windowWidth)
    }
}

/// One drag of the column boundary (§4.5 "column boundary drag"): the width
/// follows the cursor from the width shown at mouse-down, clamped into the
/// range for the window width of that moment (after overshooting an end and
/// coming back, the boundary follows the pointer again). The app creates
/// one at mouse-down, feeds every drag event, shows `width`, and persists
/// `widthToPersist` at mouse-up.
public struct ListColumnWidthDrag: Equatable, Sendable {
    /// The shown width at mouse-down.
    public let startWidth: Double
    /// The width to show now.
    public private(set) var width: Double

    public init(startWidth: Double) {
        self.startWidth = startWidth
        self.width = startWidth
    }

    /// Feed the cursor's horizontal travel since mouse-down in screen
    /// coordinates (positive = rightward = wider).
    public mutating func update(dragDelta: Double, windowWidth: Double) {
        width = ListColumnWidth.clamp(startWidth + dragDelta, windowWidth: windowWidth)
    }

    /// The width to remember when the drag ends, rounded to a whole point,
    /// or nil when the rounded end width equals the rounded shown width at
    /// the start (a click without movement, a drag back to where it began,
    /// or a drag of under half a point). Such a drag therefore neither
    /// stores a clamped value nor stops the width following the text size.
    public var widthToPersist: Double? {
        let end = width.rounded(.toNearestOrAwayFromZero)
        return end != startWidth.rounded(.toNearestOrAwayFromZero) ? end : nil
    }
}
