// The row drag's decisions (DESIGN.md §4.5 "row drag", §8.60, §9). The
// drag is an in-app operation tracked from mouse events — no system drag
// and drop, no pasteboard. The app target reports geometry (the list's
// elements in list-content coordinates, y growing downward, and the
// pointer) and draws; everything decided from that geometry lives here:
// where the pointer is, the drop target and its indicator, and the
// auto-scroll speed. The drag's state, when a press becomes a drag, and the
// drop's effect on the stars live in `UnifiedListState`.

import Foundation

/// §9 values of the row drag.
public enum CardDragMetrics {
    /// §9: a press becomes a drag once the pointer is this far from where
    /// the button went down (does not follow the text size).
    public static let startDistance: Double = 4
    /// §9: the row image that follows the pointer.
    public static let ghostOpacity: Double = 0.92
    /// §9: the dragged row left in place.
    public static let liftedOpacity: Double = 0.35
    /// §9: the rows that cannot be a drop position (Running and Recent rows
    /// other than the dragged one).
    public static let dimmedOpacity: Double = 0.4
    /// §9: how long the reason a row cannot be dragged stays on screen.
    public static let refusalSeconds: Double = 2
    /// §9: the auto-scroll zone at each end of the list at text size 13
    /// (it follows the text size).
    public static let autoScrollZoneAtBase: Double = 40
    /// §9: the auto-scroll speed at the list's edge and at the zone's inner
    /// end, points per second (they do not follow the text size).
    public static let autoScrollEdgeSpeed: Double = 1200
    public static let autoScrollInnerSpeed: Double = 120

    /// Whether the pointer has moved far enough from the press to start a
    /// drag (§4.5 "row drag": start).
    public static func hasMovedFarEnough(fromX: Double, fromY: Double, toX: Double, toY: Double) -> Bool {
        let dx = toX - fromX
        let dy = toY - fromY
        return (dx * dx + dy * dy).squareRoot() >= startDistance
    }
}

/// §4.5 "row drag" / "auto-scroll": while the pointer is within the zone at
/// the top or the bottom of the list, the list scrolls that way. The speed
/// changes linearly from the edge speed at the list's edge to the inner
/// speed at the zone's inner end.
public enum CardDragAutoScroll {
    /// The zone's depth for a text size (§9: 40pt at 13, by ratio).
    public static func zone(textSize: TextSize) -> Double {
        CardDragMetrics.autoScrollZoneAtBase * textSize.ratio
    }

    /// The scroll velocity in points per second: negative scrolls toward
    /// the top, positive toward the bottom, 0 outside both zones.
    /// `pointerY` is measured from the top of the list's visible area,
    /// whose height is `viewportHeight`. A pointer above the top edge or
    /// below the bottom edge keeps the edge speed that way, wherever it is
    /// horizontally (§4.5 "row drag": auto-scroll, §9).
    public static func velocity(pointerY: Double, viewportHeight: Double, textSize: TextSize) -> Double {
        guard viewportHeight > 0 else { return 0 }
        if pointerY < 0 { return -CardDragMetrics.autoScrollEdgeSpeed }
        if pointerY > viewportHeight { return CardDragMetrics.autoScrollEdgeSpeed }
        let zone = zone(textSize: textSize)
        let fromTop = pointerY
        let fromBottom = viewportHeight - pointerY
        if fromTop <= zone {
            return -speed(distanceFromEdge: fromTop, zone: zone)
        }
        if fromBottom <= zone {
            return speed(distanceFromEdge: fromBottom, zone: zone)
        }
        return 0
    }

    private static func speed(distanceFromEdge: Double, zone: Double) -> Double {
        let edge = CardDragMetrics.autoScrollEdgeSpeed
        let inner = CardDragMetrics.autoScrollInnerSpeed
        return edge - (edge - inner) * (distanceFromEdge / zone)
    }
}

/// One element of the list as drawn: a heading (its click area), a row
/// (rows of one frame touch each other — no gap between them), the Recent
/// `N more` line, or a row's star box (the star's click area — a press
/// there never starts a drag). Coordinates are list-content coordinates.
public enum ListElementKind: Hashable, Sendable {
    case heading(ListHeading)
    case row(UnifiedRowKey)
    case moreLine
    case star(UnifiedRowKey)
}

public struct ListElementExtent: Equatable, Sendable {
    public let kind: ListElementKind
    public let top: Double
    public let bottom: Double
    public let minX: Double
    public let maxX: Double

    public init(kind: ListElementKind, top: Double, bottom: Double, minX: Double, maxX: Double) {
        self.kind = kind
        self.top = top
        self.bottom = bottom
        self.minX = minX
        self.maxX = maxX
    }

    func contains(x: Double, y: Double) -> Bool {
        x >= minX && x < maxX && y >= top && y < bottom
    }
}

/// Where the pointer is during a drag.
public enum ListPointerHit: Equatable, Sendable {
    /// Over an element (by height: the list's side paddings count as the
    /// element's row). `upperHalf` = above the element's vertical middle.
    case element(ListElementKind, upperHalf: Bool)
    /// Between two elements; `above` / `below` are the neighbors (nil above
    /// the first element or below the last).
    case gap(above: ListElementKind?, below: ListElementKind?)
    /// Outside the list's visible area.
    case outside
}

public enum ListPointerHitTest {
    /// The element at `y` (list-content coordinates). `insideList` = the
    /// pointer is inside the list's visible area. Star boxes are ignored
    /// (the row under them counts).
    public static func hit(y: Double, insideList: Bool, elements: [ListElementExtent]) -> ListPointerHit {
        guard insideList else { return .outside }
        let rows = elements.filter {
            if case .star = $0.kind { return false }
            return true
        }.sorted { $0.top < $1.top }
        if let element = rows.first(where: { y >= $0.top && y < $0.bottom }) {
            return .element(element.kind, upperHalf: y < (element.top + element.bottom) / 2)
        }
        let above = rows.last(where: { $0.bottom <= y })?.kind
        let below = rows.first(where: { $0.top > y })?.kind
        return .gap(above: above, below: below)
    }

    /// The row a press at (x, y) lands on, and whether it lands on the row's
    /// star box; nil off every row.
    public static func pressedRow(x: Double, y: Double, elements: [ListElementExtent]) -> (key: UnifiedRowKey, onStar: Bool)? {
        for element in elements {
            guard case .row(let key) = element.kind, element.contains(x: x, y: y) else { continue }
            let onStar = elements.contains { $0.kind == .star(key) && $0.contains(x: x, y: y) }
            return (key, onStar)
        }
        return nil
    }
}

/// What a drop does (§4.5 "row drag": drop).
public enum CardDropTarget: Equatable, Sendable {
    /// Into Starred, right before the conversation with this session_id
    /// (nil = at the end of the stars' list).
    case starred(before: String?)
    /// Into Recent: the star is removed (a Starred row only).
    case unstar
}

/// How the drop target is shown (§4.5 "row drag" table; window-design.html
/// "collapsing sections and the row drag"). The target follows from the
/// indicator alone (`target`), so while a line is shown, the line's place
/// is where the drop puts the row.
public enum CardDropIndicator: Equatable, Sendable {
    /// The line at the top edge of this Starred row (between it and the
    /// row above it, on the divider) — nil: at the bottom edge of the last
    /// Starred row.
    case line(before: String?)
    /// The heading emphasized: a closed Starred (the end of Starred), or
    /// Recent (the star is removed).
    case heading(ListHeading)

    public var target: CardDropTarget? {
        switch self {
        case .line(let before): return .starred(before: before)
        case .heading(.starred): return .starred(before: nil)
        case .heading(.recent): return .unstar
        case .heading: return nil
        }
    }
}

/// A row drag in progress.
public struct CardDrag: Equatable, Sendable {
    /// The dragged row.
    public let key: UnifiedRowKey
    public let sessionID: String
    /// The section the drag started in (Starred or Recent).
    public let section: UnifiedListSection
    /// nil = no drop target (a release cancels).
    public internal(set) var indicator: CardDropIndicator?
    /// The latest pointer position, kept so a change of the list recomputes
    /// the target from it.
    public internal(set) var lastHit: ListPointerHit?

    public init(key: UnifiedRowKey, sessionID: String, section: UnifiedListSection) {
        self.key = key
        self.sessionID = sessionID
        self.section = section
    }

    /// What the drop does now (derived from the indicator).
    public var target: CardDropTarget? { indicator?.target }
}

/// §4.5 "row drag" table: the drop target for a pointer position.
public struct CardDropResolver: Equatable, Sendable {
    /// The section the drag started in.
    public let source: UnifiedListSection
    /// Session IDs of the Starred rows shown, top to bottom (empty while
    /// Starred is closed or not shown).
    public let shownStarred: [String]
    /// The Starred heading is on screen (History is open and Starred has
    /// rows).
    public let starredHeadingShown: Bool
    /// The Recent heading is on screen (it is shown only while Starred has
    /// rows, and History is open).
    public let recentHeadingShown: Bool
    /// The section of every row on screen.
    public let rowSections: [UnifiedRowKey: UnifiedListSection]

    public init(
        source: UnifiedListSection,
        shownStarred: [String],
        starredHeadingShown: Bool,
        recentHeadingShown: Bool,
        rowSections: [UnifiedRowKey: UnifiedListSection]
    ) {
        self.source = source
        self.shownStarred = shownStarred
        self.starredHeadingShown = starredHeadingShown
        self.recentHeadingShown = recentHeadingShown
        self.rowSections = rowSections
    }

    /// The part of the list an element belongs to, for the drop table.
    private enum Region {
        case running
        case historyHeading
        case starred
        case recent
    }

    /// The drop indicator at `hit` (§4.5 "row drag": gaps between elements
    /// and the list's ends). A gap belongs to the element above it: from the
    /// Starred heading down to the Recent heading the previous target holds
    /// (while it still exists); a gap in Recent is Recent; one in Running,
    /// or below the History heading, has no target. Above the first element
    /// counts as that element's upper half, below the last element as the
    /// last element's lower half.
    public func resolve(_ hit: ListPointerHit?, previous: CardDropIndicator?) -> CardDropIndicator? {
        guard let hit else { return nil }
        switch hit {
        case .outside:
            return nil
        case .gap(let above, let below):
            guard let above else {
                guard let below else { return nil }
                return resolveElement(below, upperHalf: true)
            }
            guard below != nil else { return resolveElement(above, upperHalf: false) }
            switch region(of: above) {
            // An element that left the list (the list changed under the
            // pointer) keeps what still holds until the pointer is
            // reported again.
            case .starred, nil: return previous.flatMap(validated)
            case .recent: return resolveElement(.moreLine, upperHalf: false)
            case .running, .historyHeading: return nil
            }
        case .element(let kind, let upperHalf):
            return resolveElement(kind, upperHalf: upperHalf)
        }
    }

    private func resolveElement(_ kind: ListElementKind, upperHalf: Bool) -> CardDropIndicator? {
        switch region(of: kind) {
        case .running, .historyHeading, nil:
            return nil
        case .recent:
            // Recent's order is newest first, so no line: the heading is
            // emphasized (§4.5, §8.60). A Recent row has nowhere to go.
            return source == .starred && recentHeadingShown ? .heading(.recent) : nil
        case .starred:
            if case .heading = kind {
                if let first = shownStarred.first { return .line(before: first) }
                // A closed Starred takes a Recent row at its end, while its
                // heading is still on screen (a stale hit may name a heading
                // that is gone).
                return starredHeadingShown && source == .recent ? .heading(.starred) : nil
            }
            guard case .row(let key) = kind, case .conversation(let sessionID) = key,
                  let index = shownStarred.firstIndex(of: sessionID) else { return nil }
            if upperHalf {
                return .line(before: sessionID)
            }
            return .line(before: shownStarred.indices.contains(index + 1) ? shownStarred[index + 1] : nil)
        }
    }

    private func region(of kind: ListElementKind) -> Region? {
        switch kind {
        case .heading(.running): return .running
        case .heading(.history): return .historyHeading
        case .heading(.starred): return .starred
        case .heading(.recent): return .recent
        case .row(let key), .star(let key):
            switch rowSections[key] {
            case .running: return .running
            case .starred: return .starred
            case .recent: return .recent
            case nil: return nil
            }
        case .moreLine: return .recent
        }
    }

    /// The previous indicator, when what it points at is still on screen.
    private func validated(_ previous: CardDropIndicator) -> CardDropIndicator? {
        switch previous {
        case .line(let before):
            if let before { return shownStarred.contains(before) ? previous : nil }
            return shownStarred.isEmpty ? nil : previous
        case .heading(.starred):
            return starredHeadingShown && shownStarred.isEmpty && source == .recent ? previous : nil
        case .heading(.recent):
            return source == .starred && recentHeadingShown ? previous : nil
        case .heading:
            return nil
        }
    }
}
