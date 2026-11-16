// The list's scroll decisions (DESIGN.md §4.5 "row selection": reveal the
// selected row by the minimum scroll; "the popover and the window share one
// state": the list scroll position). The app target only reports geometry
// (the visible part of the list and the rows' frames, in list-content
// coordinates with y growing downward) and applies the offset decided here.

import Foundation

/// One row's vertical extent in list-content coordinates.
public struct ListRowExtent: Equatable, Sendable {
    public let key: UnifiedRowKey
    public let top: Double
    public let bottom: Double

    public init(key: UnifiedRowKey, top: Double, bottom: Double) {
        self.key = key
        self.top = top
        self.bottom = bottom
    }
}

/// The visible part of the list: the top offset, the viewport height, and
/// the height of the whole content.
public struct ListViewport: Equatable, Sendable {
    public let top: Double
    public let height: Double
    public let contentHeight: Double

    public init(top: Double, height: Double, contentHeight: Double) {
        self.top = top
        self.height = height
        self.contentHeight = contentHeight
    }

    /// The viewport of a scroll view whose clip view has content insets (an
    /// area the scroll view covers but something else draws over): only the
    /// unobscured part counts, so a row under an inset is never "visible",
    /// and two surfaces with different insets share the same top row.
    /// `clipTop` / `clipHeight` are the clip view's bounds.
    public init(clipTop: Double, clipHeight: Double, topInset: Double, bottomInset: Double, contentHeight: Double) {
        self.init(
            top: clipTop + topInset,
            height: max(0, clipHeight - topInset - bottomInset),
            contentHeight: contentHeight
        )
    }

    /// The clip view's bounds origin that puts `top` (an unobscured top
    /// offset, as decided here) at the bottom edge of the top inset.
    public static func clipTop(forTop top: Double, topInset: Double) -> Double {
        top - topInset
    }

    /// The largest valid top offset.
    public var maxTop: Double { max(0, contentHeight - height) }

    func clamped(_ value: Double) -> Double { min(max(0, value), maxTop) }
}

/// The shared list scroll position (§4.5): the row at the top edge of the
/// viewport and how far the viewport top is below that row's top (negative
/// when a section header above the row is visible). Kept by row, not by
/// pixel, so a History refetch that inserts rows above does not move what
/// the user was looking at.
public struct ListScrollAnchor: Equatable, Sendable {
    public let key: UnifiedRowKey
    public let offset: Double

    public init(key: UnifiedRowKey, offset: Double) {
        self.key = key
        self.offset = offset
    }

    /// The anchor of the current viewport: the first row (in display order)
    /// whose bottom is below the viewport top. Nil without rows.
    public static func capture(viewport: ListViewport, rows: [ListRowExtent]) -> ListScrollAnchor? {
        guard let row = rows.first(where: { $0.bottom > viewport.top }) ?? rows.last else { return nil }
        return ListScrollAnchor(key: row.key, offset: viewport.top - row.top)
    }

    /// The top offset that restores this anchor, or nil when its row is no
    /// longer in the list (the scroll stays where it is).
    public func restoredTop(viewport: ListViewport, rows: [ListRowExtent]) -> Double? {
        guard let row = rows.first(where: { $0.key == key }) else { return nil }
        return viewport.clamped(row.top + offset)
    }
}

/// §4.5 "row selection": when the selected row is outside the visible range,
/// scroll by the minimum amount that brings the whole row into view. The
/// first row of the whole list instead scrolls the list to its very top, even
/// when the row is already visible, so the section header above it shows.
public enum ListReveal {
    /// The new top offset, or nil when no scroll is needed. A row taller than
    /// the viewport aligns its top. `isFirstRow` marks the first row of the
    /// whole list (in display order): its target is the smallest valid top
    /// offset, and nil only when the list is already there.
    public static func revealTop(viewport: ListViewport, row: ListRowExtent, isFirstRow: Bool = false) -> Double? {
        if isFirstRow {
            let top = viewport.clamped(0)
            return top == viewport.top ? nil : top
        }
        let visibleBottom = viewport.top + viewport.height
        let target: Double
        if row.top < viewport.top || row.bottom - row.top > viewport.height {
            target = row.top
        } else if row.bottom > visibleBottom {
            target = row.bottom - viewport.height
        } else {
            return nil
        }
        let clamped = viewport.clamped(target)
        return clamped == viewport.top ? nil : clamped
    }
}
