// Row models for the single list shown by the popover and the window
// (DESIGN.md §4.5 "the list has three sections" / "Running rows" / "action
// buttons" / "collapsing sections", §4.6 "Starred section" / "Recent
// section" / "stars" / "search scope", §8.49, §8.60). "History rows" are
// the Starred and Recent rows together (§4.5).
// Everything a row view draws is precomputed here: three text lines, the
// symbol-and-time column (status symbol with the unreviewed dot, or star,
// and the elapsed time). Each row also carries the two action buttons the bottom panel shows while it is
// selected (enabled state, tooltip and the CLI call they make); the row
// itself shows none of them (§4.5 "action buttons"). The view layer only
// lays these out.

import Foundation

/// The row sections. The normal list shows the first three, top to bottom
/// (§4.5 "the list has three sections"): Running, then Starred and Recent
/// under the History heading. The Archive view shows `archived` alone
/// (§4.6 "Archive view").
public enum UnifiedListSection: CaseIterable, Equatable, Hashable, Sendable {
    case running
    case starred
    case recent
    /// The Archive view's rows: archived conversations from the search
    /// result.
    case archived

    /// The normal list's sections, top to bottom.
    public static let normalList: [UnifiedListSection] = [.running, .starred, .recent]
}

/// The four headings that open and close (§4.5 "collapsing sections"):
/// the three sections and History, which groups Starred and Recent. In the
/// list's top-to-bottom order. The raw value is the name in the remembered
/// set of closed headings.
public enum ListHeading: String, CaseIterable, Equatable, Hashable, Sendable {
    case running
    case history
    case starred
    case recent

    public var title: String {
        switch self {
        case .running: return "Running"
        case .history: return "History"
        case .starred: return "Starred"
        case .recent: return "Recent"
        }
    }

    /// The heading of a normal list section; nil for the Archive view's
    /// rows, which have no heading that opens or closes (§4.5 "collapsing
    /// sections").
    public init?(_ section: UnifiedListSection) {
        switch section {
        case .running: self = .running
        case .starred: self = .starred
        case .recent: self = .recent
        case .archived: return nil
        }
    }
}

/// A row's identity. Selection is held by target for Running rows and by
/// session_id for Starred and Recent rows (§4.5 "row selection"). Starred
/// and Recent rows share one key, so a conversation that moves between the
/// two sections (a star change) keeps its selection.
public enum UnifiedRowKey: Hashable, Sendable {
    case running(target: String)
    /// A Starred or Recent row: a conversation from the search result.
    case conversation(sessionID: String)
}

/// The three verbs the bottom panel can show for the selected row (§4.5/§4.6).
public enum RowButtonKind: Equatable, Sendable {
    case jump
    case resume
    case branch

    /// The verb as a word: the bottom panel's button title and the default
    /// tooltip.
    public var title: String {
        switch self {
        case .jump: return "Jump"
        case .resume: return "Resume"
        case .branch: return "Branch"
        }
    }

    /// The key shown inside the button after the title (§4.6 "bottom
    /// panel"): Enter for the primary button, ⌘Enter for Branch — the keys
    /// that run them with list focus (§4.5 "key operations"). Shown also
    /// while the button is disabled.
    public var shortcut: String {
        switch self {
        case .jump, .resume: return "\u{21A9}"
        case .branch: return "\u{2318}\u{21A9}"
        }
    }
}

/// The CLI call behind an enabled button (§4.5 "Jump", §4.6 "Resume and
/// Branch"). The app maps these to `shiibar-cc focus <target>` /
/// `shiibar-cc resume --cwd <cwd> --terminal <t> [--fork] <session_id>`.
public enum RowInvocation: Equatable, Sendable {
    case jump(target: String)
    case resume(sessionID: String, cwd: String)
    case branch(sessionID: String, cwd: String)
}

/// One bottom-panel action button. Disabled exactly when there is no
/// invocation.
public struct RowButton: Equatable, Sendable {
    public let kind: RowButtonKind
    public let invocation: RowInvocation?
    public let tooltip: String

    public var isEnabled: Bool { invocation != nil }

    public init(kind: RowButtonKind, invocation: RowInvocation?, tooltip: String) {
        self.kind = kind
        self.invocation = invocation
        self.tooltip = tooltip
    }

    /// §4.6: tooltip of the disabled Jump on a live conversation that stays
    /// in History (running in a terminal this app cannot drive — §8.11).
    public static let untrackedRunningTooltip = "Running in a terminal Shiibar CC can't drive"

    /// The same button, disabled (tooltip unchanged).
    public func disabled() -> RowButton {
        RowButton(kind: kind, invocation: nil, tooltip: tooltip)
    }
}

/// The symbol at the top of the row's symbol-and-time column (§4.5 "the
/// list has three sections", §4.6 "stars" / "Archive"): the status symbol
/// on Running rows, the star (left of the more button) on the normal list's
/// Starred and Recent rows, and nothing but the more button on the Archive
/// view's rows. The star is smaller than the status symbol and centered in
/// a box of the same size (§9).
public enum RowColumnSymbol: Equatable, Sendable {
    /// Running row: status symbol, plus the accent-color dot when
    /// unreviewed.
    case status(RowSymbolKind, unreviewed: Bool)
    /// Starred row (`isStarred`): a filled yellow star, always visible.
    /// Recent row: an outline star shown only while the row is hovered.
    /// Clicking the star toggles it and never selects the row (§4.6).
    case star(isStarred: Bool)
    /// Archive view row: no star; the column's top is the more button alone
    /// (§4.6 "Archive view").
    case moreButtonOnly

    /// Tooltip of the star (§4.6: `Star` / `Unstar`), nil otherwise.
    public var tooltip: String? {
        switch self {
        case .status, .moreButtonOnly: return nil
        case .star(let isStarred): return isStarred ? "Unstar" : "Star"
        }
    }

    /// The symbol boxes at the top of the column, left to right (§4.5 "the
    /// list has three sections"): the more button's box sits at the column's
    /// right end, where a Running row's status symbol sits, and the star's
    /// box left of it.
    public var boxes: [RowColumnBox] {
        switch self {
        case .status: return [.status]
        case .star: return [.star, .moreButton]
        case .moreButtonOnly: return [.moreButton]
        }
    }
}

/// One symbol box at the top of a row's symbol-and-time column (§9: every
/// box is the status symbol's size).
public enum RowColumnBox: Equatable, Sendable {
    case status
    case star
    case moreButton
}

/// The command of a row's more-button menu item (§4.6 "Archive").
public enum RowMenuCommand: Equatable, Sendable {
    case archive
    case unarchive
}

/// One item of the menu the more button opens (§4.6 "Archive"): the title
/// and the enabled flag, decided apart from the menu that shows them.
public struct RowMenuItem: Equatable, Sendable {
    public let command: RowMenuCommand
    public let title: String
    public let isEnabled: Bool

    public init(command: RowMenuCommand, title: String, isEnabled: Bool) {
        self.command = command
        self.title = title
        self.isEnabled = isEnabled
    }

    /// The normal list's Starred and Recent rows: `Archive`, disabled on a
    /// live conversation's row (the `· running` mark) so a session that
    /// runs is never taken off the list (§4.6 "Archive").
    public static func archive(isEnabled: Bool) -> RowMenuItem {
        RowMenuItem(command: .archive, title: "Archive", isEnabled: isEnabled)
    }

    /// The Archive view's rows.
    public static let unarchive = RowMenuItem(command: .unarchive, title: "Unarchive", isEnabled: true)
}

/// The more button's texts (§4.6 "Archive").
public enum RowMoreButton {
    public static let tooltip = "More"
    public static let accessibilityLabel = "More actions"
}

/// One row in the list (§4.5/§4.6).
public struct UnifiedListRow: Equatable, Identifiable, Sendable {
    public let id: UnifiedRowKey
    public let section: UnifiedListSection
    /// May be empty on a Running row (§4.5 "row click").
    public let sessionID: String
    /// Raw cwd (nil or empty when unknown).
    public let cwd: String?
    /// The row's bold middle line (§4.5): the conversation title, or the
    /// `message` on a waiting Running row. Unreviewed is shown only by the
    /// dot in `symbol`, never by this line's weight.
    public let title: String
    /// The two-component folder label (§4.5 "display label").
    public let label: String
    public let elapsedSeconds: Int64
    /// The elapsed time at the bottom of the symbol-and-time column (§4.5),
    /// never truncated.
    public let elapsedText: String
    /// The row's top line: the label, plus ` · running` on a live History
    /// row (§4.5 / §4.6; the elapsed time is in the symbol-and-time column
    /// instead).
    public let labelLine: String
    /// Whether `labelLine` ends with the faint `running` mark (§4.6) — lets
    /// the view style that trailing word; it is already part of `labelLine`.
    public let showsRunningMark: Bool
    /// The row's bottom line: the last prompt, newlines already replaced by
    /// spaces. nil = draw an empty line so row heights stay equal.
    public let lastPrompt: String?
    public let symbol: RowColumnSymbol
    /// The more button's menu (§4.6 "Archive"); empty on a Running row,
    /// which has no more button.
    public let menuItems: [RowMenuItem]
    /// The bottom panel's primary button while this row is selected: Jump
    /// (Running, or disabled Jump for a live History row) or Resume.
    public let primaryButton: RowButton
    /// The bottom panel's Branch button while this row is selected.
    public let branchButton: RowButton
    /// The conversation pane header's title (§4.6, below the label line):
    /// the conversation title. For a row with an empty session_id it is the
    /// row's `title` (§4.5).
    public let headerTitle: String
    /// The conversation pane header's top line (§4.6, above the title): the
    /// row's folder label (`label`, without the `running` mark) plus
    /// `· <elapsed> ago`, so the header shows the row's text in the row's
    /// order.
    public let headerLabelAndElapsed: String

    public init(
        id: UnifiedRowKey,
        section: UnifiedListSection,
        sessionID: String,
        cwd: String?,
        title: String,
        label: String,
        elapsedSeconds: Int64,
        labelLine: String,
        showsRunningMark: Bool,
        lastPrompt: String?,
        symbol: RowColumnSymbol,
        primaryButton: RowButton,
        branchButton: RowButton,
        headerTitle: String,
        headerLabelAndElapsed: String,
        menuItems: [RowMenuItem] = []
    ) {
        self.id = id
        self.section = section
        self.sessionID = sessionID
        self.cwd = cwd
        self.title = title
        self.label = label
        self.elapsedSeconds = elapsedSeconds
        self.elapsedText = ElapsedTime.format(seconds: elapsedSeconds)
        self.labelLine = labelLine
        self.showsRunningMark = showsRunningMark
        self.lastPrompt = lastPrompt
        self.symbol = symbol
        self.menuItems = menuItems
        self.primaryButton = primaryButton
        self.branchButton = branchButton
        self.headerTitle = headerTitle
        self.headerLabelAndElapsed = headerLabelAndElapsed
    }

    /// The same row with both buttons disabled (used while a selected
    /// Running row that just ended awaits the History refetch — §4.5).
    func withButtonsDisabled() -> UnifiedListRow {
        UnifiedListRow(
            id: id, section: section, sessionID: sessionID, cwd: cwd, title: title,
            label: label, elapsedSeconds: elapsedSeconds, labelLine: labelLine,
            showsRunningMark: showsRunningMark, lastPrompt: lastPrompt, symbol: symbol,
            primaryButton: primaryButton.disabled(), branchButton: branchButton.disabled(),
            headerTitle: headerTitle, headerLabelAndElapsed: headerLabelAndElapsed,
            menuItems: menuItems
        )
    }
}

/// The look of a heading (§4.5 "the list has three sections", §8.63;
/// window-design.html `.rows .sec`, `.sec.sub`).
public enum ListHeadingStyle: Equatable, Sendable {
    /// Running and History: a band across the list's whole width, with a
    /// line along its top and bottom edges. Kept while searching, without
    /// the chevron and the Running mark (§4.5 "collapsing sections").
    case band
    /// Starred and Recent: text and a line, no ground, with the smaller
    /// spacing of the headings under History.
    case sub
}

/// One heading as shown (§4.5 "the list has three sections" / "collapsing
/// sections" / "row drag").
public struct ListHeadingModel: Equatable, Identifiable, Sendable {
    public var id: ListHeading { heading }
    public let heading: ListHeading
    public let style: ListHeadingStyle
    /// The text after the bold name: the row count, `first 100` while the
    /// Recent cap leaves rows out, or nil for no count (§4.5 "row counts").
    public let countText: String?
    /// Shown open: the chevron points down and the name is in the primary
    /// color. A closed heading has a right-pointing chevron and the name in
    /// the secondary color.
    public let isOpen: Bool
    /// The chevron is shown and a click opens or closes: not while
    /// searching.
    public let isCollapsible: Bool
    /// The Running mark before the name (Running only, while it is closed
    /// and has a waiting or unreviewed row): orange when a row is waiting,
    /// else the accent color (§4.5 "collapsing sections"). Nil = no mark.
    public let attentionMark: StateDot?
    /// The accent hint left of the chevron during a row drag (`Drop here to
    /// star` / `Drop here to unstar`).
    public let hint: String?
    /// The heading is emphasized as the row drag's drop target.
    public let isDropTarget: Bool

    public init(
        heading: ListHeading,
        style: ListHeadingStyle,
        countText: String?,
        isOpen: Bool = true,
        isCollapsible: Bool = true,
        attentionMark: StateDot? = nil,
        hint: String? = nil,
        isDropTarget: Bool = false
    ) {
        self.heading = heading
        self.style = style
        self.countText = countText
        self.isOpen = isOpen
        self.isCollapsible = isCollapsible
        self.attentionMark = attentionMark
        self.hint = hint
        self.isDropTarget = isDropTarget
    }

    public var title: String { heading.title }

    /// The Running mark is shown (in either color).
    public var showsAttentionMark: Bool { attentionMark != nil }

    /// §4.5 "row drag": the hint on the Starred heading while a Recent row
    /// is dragged.
    public static let starHint = "Drop here to star"
    /// §4.5 "row drag": the hint on the Recent heading while a Starred row
    /// is dragged.
    public static let unstarHint = "Drop here to unstar"
}

/// Which rows a frame holds.
public enum ListFrameID: Hashable, Sendable {
    case running
    case starred
    case recent
    /// While searching: the Starred rows, then the Recent rows, in one frame
    /// under the History heading (§4.6 "search scope").
    case history
    /// The Archive view's rows (§4.6 "Archive view").
    case archived
}

/// The band at the top of the Archive view (§4.6 "Archive view"): a
/// left-pointing chevron, the name and the count; no chevron at the right
/// end. A click anywhere on it returns to the normal list.
public struct ArchiveHeadingModel: Equatable, Sendable {
    /// The row count, `first 100` while the cap leaves rows out, or nil
    /// before the first search result.
    public let countText: String?

    public init(countText: String?) {
        self.countText = countText
    }

    public static let title = "Archived"
}

/// The rows of one section in one frame, separated by divider lines
/// (§4.5 "the list has three sections").
public struct ListFrameModel: Equatable, Identifiable, Sendable {
    public let id: ListFrameID
    public let rows: [UnifiedListRow]
    /// The frame's border is emphasized: a Recent row is dragged and the
    /// drop target is shown by a line in this frame (§4.5 "row drag").
    public let isEmphasized: Bool

    public init(id: ListFrameID, rows: [UnifiedListRow], isEmphasized: Bool = false) {
        self.id = id
        self.rows = rows
        self.isEmphasized = isEmphasized
    }
}

public enum ListBlockID: Hashable, Sendable {
    case heading(ListHeading)
    case archiveHeading
    case frame(ListFrameID)
    case moreLine
    case emptyLine
}

/// One element of the list page, top to bottom: a heading, a frame of rows,
/// or the `N more` line below the Recent rows (§4.6 "Recent section"). The
/// Archive view has its band, its frame, its `N more` line, or the line
/// that says no archived conversation matches (§4.6 "Archive view").
public enum ListBlock: Equatable, Identifiable, Sendable {
    case heading(ListHeadingModel)
    case archiveHeading(ArchiveHeadingModel)
    case frame(ListFrameModel)
    case moreLine(String)
    /// One line under the Archive view's band while no row is shown.
    case emptyLine(String)

    public var id: ListBlockID {
        switch self {
        case .heading(let model): return .heading(model.heading)
        case .archiveHeading: return .archiveHeading
        case .frame(let model): return .frame(model.id)
        case .moreLine: return .moreLine
        case .emptyLine: return .emptyLine
        }
    }

    /// The block is drawn as a band (§4.5 "the list has three sections").
    public var isBand: Bool {
        switch self {
        case .heading(let model): return model.style == .band
        case .archiveHeading: return true
        case .frame, .moreLine, .emptyLine: return false
        }
    }
}

/// The stars (§4.6 "stars", §8.60): an ordered list of session IDs, the
/// Starred section's order. Stars are an app display setting persisted in
/// UserDefaults (`StarredSessions`).
///
/// A list read from the unordered set an earlier app version stored
/// (`isUnordered`) is shown newest first, in the search result's order,
/// until it is saved as an ordered list: when an empty-query list is
/// fetched (`pruned`), or at the first star change before that.
public struct StarredList: Equatable, Sendable, ExpressibleByArrayLiteral {
    /// The session IDs, each once. While `isUnordered`, sorted by session ID
    /// (no meaning as an order).
    public private(set) var sessionIDs: [String]
    /// Read from the unordered set and not yet saved as an ordered list.
    public private(set) var isUnordered: Bool

    /// An ordered list; a repeated session ID keeps its first position only.
    public init(_ sessionIDs: [String] = []) {
        var seen = Set<String>()
        self.sessionIDs = sessionIDs.filter { seen.insert($0).inserted }
        self.isUnordered = false
    }

    public init(arrayLiteral sessionIDs: String...) {
        self.init(sessionIDs)
    }

    /// The stars of an unordered set (§4.6 "stars": the unordered stored
    /// value).
    public static func unordered(_ sessionIDs: Set<String>) -> StarredList {
        var list = StarredList(sessionIDs.sorted())
        list.isUnordered = true
        return list
    }

    public func contains(_ sessionID: String) -> Bool {
        sessionIDs.contains(sessionID)
    }

    /// The ordered list this list stands for, given the fetched search
    /// result: itself when ordered; for an unordered list, the conversations
    /// in `results` newest first (the result's own order), then the others
    /// by session ID (§4.6 "stars").
    public func materialized(results: [ConversationSummary]) -> StarredList {
        guard isUnordered else { return self }
        var ordered: [String] = []
        var placed = Set<String>()
        for summary in results where contains(summary.sessionID) && placed.insert(summary.sessionID).inserted {
            ordered.append(summary.sessionID)
        }
        ordered += sessionIDs.filter { !placed.contains($0) }.sorted()
        return StarredList(ordered)
    }

    /// One star toggled by a click on the star (§4.6 "stars"): a new star is
    /// added at the end; a removed star leaves the others in their order.
    /// An unordered list is ordered first (`materialized`).
    public func toggled(_ sessionID: String, results: [ConversationSummary]) -> StarredList {
        var ids = materialized(results: results).sessionIDs
        if let index = ids.firstIndex(of: sessionID) {
            ids.remove(at: index)
        } else {
            ids.append(sessionID)
        }
        return StarredList(ids)
    }

    /// The star removed (a Starred row dropped on Recent — §4.5 "row
    /// drag"); nil when it is not starred.
    public func removing(_ sessionID: String, results: [ConversationSummary]) -> StarredList? {
        guard contains(sessionID) else { return nil }
        return toggled(sessionID, results: results)
    }

    /// A row dropped on Starred (§4.5 "row drag" / "drop"): `sessionID`
    /// placed right before `before` (nil = at the end), starred if it was
    /// not. Conversations not shown in Starred keep their place in the list.
    /// `shown` is Starred's displayed order (session IDs). nil when the
    /// displayed order does not change — a row dropped where it already
    /// shows changes and saves nothing, even with a hidden (running) star
    /// next to it — or when `before` is not in the list.
    public func moving(
        _ sessionID: String, before: String?, shown: [String], results: [ConversationSummary]
    ) -> StarredList? {
        let current = materialized(results: results).sessionIDs
        guard before != sessionID else { return nil }
        if shown.contains(sessionID) {
            var reordered = shown.filter { $0 != sessionID }
            if let before, let index = reordered.firstIndex(of: before) {
                reordered.insert(sessionID, at: index)
            } else {
                reordered.append(sessionID)
            }
            if reordered == shown { return nil }
        }
        var ids = current.filter { $0 != sessionID }
        if let before {
            guard let index = ids.firstIndex(of: before) else { return nil }
            ids.insert(sessionID, at: index)
        } else {
            ids.append(sessionID)
        }
        return ids == current ? nil : StarredList(ids)
    }

    /// §4.6: when an empty-query (browse) list is fetched, drop the stars of
    /// session IDs that are not in it (the transcript was deleted); the
    /// others keep their order. An unordered list becomes ordered here,
    /// newest first. Returns nil when nothing changes (nothing to save).
    /// Never call this with a filtered (search) result.
    public func pruned(browseResults: [ConversationSummary]) -> StarredList? {
        let present = Set(browseResults.map(\.sessionID))
        let ordered = materialized(results: browseResults)
        let result = StarredList(ordered.sessionIDs.filter { present.contains($0) })
        return result == self ? nil : result
    }
}

/// Reading and writing the stars (§4.6 "stars") in an injected
/// `UserDefaults`.
public enum StarredSessions {
    /// The stored ordered list (`MainSurfaceDefaultsKeys.starredSessionList`)
    /// when it is an array of strings (a repeated session ID counts once);
    /// otherwise the unordered set an earlier app version stored
    /// (`starredSessionIDs`), read but never removed; otherwise none.
    public static func load(from defaults: UserDefaults) -> StarredList {
        if let ordered = defaults.object(forKey: MainSurfaceDefaultsKeys.starredSessionList) as? [String] {
            return StarredList(ordered)
        }
        if let unordered = defaults.stringArray(forKey: MainSurfaceDefaultsKeys.starredSessionIDs) {
            return .unordered(Set(unordered))
        }
        return StarredList()
    }

    /// Persist the ordered list. The unordered set's key is left as it is.
    public static func save(_ sessionIDs: [String], to defaults: UserDefaults) {
        defaults.set(sessionIDs, forKey: MainSurfaceDefaultsKeys.starredSessionList)
    }
}

/// The archived conversations (§4.6 "Archive", §8.63): an ordered list of
/// session IDs, the most recently archived first — the Archive view's
/// order. Archive is an app display setting persisted in UserDefaults
/// (`ArchivedSessions`), like the stars.
public struct ArchivedList: Equatable, Sendable, ExpressibleByArrayLiteral {
    /// The session IDs, each once, newest archive first.
    public private(set) var sessionIDs: [String]

    /// A repeated session ID keeps its first position only.
    public init(_ sessionIDs: [String] = []) {
        var seen = Set<String>()
        self.sessionIDs = sessionIDs.filter { seen.insert($0).inserted }
    }

    public init(arrayLiteral sessionIDs: String...) {
        self.init(sessionIDs)
    }

    public var isEmpty: Bool { sessionIDs.isEmpty }

    public func contains(_ sessionID: String) -> Bool {
        sessionIDs.contains(sessionID)
    }

    /// `Archive`: the conversation goes to the head of the list; one that
    /// is already archived keeps its place.
    public func archiving(_ sessionID: String) -> ArchivedList {
        guard !contains(sessionID) else { return self }
        return ArchivedList([sessionID] + sessionIDs)
    }

    /// `Unarchive` (and the automatic unarchive of a live conversation):
    /// the conversation leaves the list; the others keep their order.
    public func unarchiving(_ sessionID: String) -> ArchivedList {
        removing([sessionID])
    }

    /// Every conversation in `sessionIDs` leaves the list.
    public func removing(_ sessionIDs: Set<String>) -> ArchivedList {
        ArchivedList(self.sessionIDs.filter { !sessionIDs.contains($0) })
    }

    /// §4.6 "Archive": when an empty-query (browse) list is fetched, drop
    /// the session IDs that are not in it (the transcript was deleted).
    /// Returns nil when nothing changes. Never call this with a filtered
    /// (search) result.
    public func pruned(browseResults: [ConversationSummary]) -> ArchivedList? {
        let present = Set(browseResults.map(\.sessionID))
        let result = ArchivedList(sessionIDs.filter { present.contains($0) })
        return result == self ? nil : result
    }
}

/// Reading and writing the archived conversations (§4.6 "Archive") in an
/// injected `UserDefaults`.
public enum ArchivedSessions {
    /// The stored list (`MainSurfaceDefaultsKeys.archivedSessionList`) when
    /// it is an array of strings (a repeated session ID counts once);
    /// otherwise none.
    public static func load(from defaults: UserDefaults) -> ArchivedList {
        decode(defaults.object(forKey: MainSurfaceDefaultsKeys.archivedSessionList))
    }

    /// A stored value that is not an array of strings reads as none.
    public static func decode(_ stored: Any?) -> ArchivedList {
        guard let ids = stored as? [String] else { return ArchivedList() }
        return ArchivedList(ids)
    }

    public static func save(_ sessionIDs: [String], to defaults: UserDefaults) {
        defaults.set(sessionIDs, forKey: MainSurfaceDefaultsKeys.archivedSessionList)
    }
}

/// The remembered set of closed headings (Running, Starred, Recent,
/// History — §4.5 "collapsing sections"), shared by the popover and the
/// window, in an injected `UserDefaults`.
public enum CollapsedSections {
    /// The stored names (`MainSurfaceDefaultsKeys.collapsedSections`). A
    /// value that is not an array of strings reads as none (everything
    /// open); names other than the four headings' are ignored.
    public static func decode(_ stored: Any?) -> Set<ListHeading> {
        guard let names = stored as? [String] else { return [] }
        return Set(names.compactMap(ListHeading.init(rawValue:)))
    }

    public static func load(from defaults: UserDefaults) -> Set<ListHeading> {
        decode(defaults.object(forKey: MainSurfaceDefaultsKeys.collapsedSections))
    }

    /// Stored in the headings' top-to-bottom order.
    public static func save(_ headings: Set<ListHeading>, to defaults: UserDefaults) {
        let names = ListHeading.allCases.filter(headings.contains).map(\.rawValue)
        defaults.set(names, forKey: MainSurfaceDefaultsKeys.collapsedSections)
    }
}

/// Builds the three sections from the daemon's agent list and the latest
/// search result (§4.5/§4.6).
public enum UnifiedListBuilder {
    /// Replace every newline with a space so the text shows on one line
    /// (§4.5: the newlines in `task` become spaces).
    public static func singleLine(_ text: String) -> String {
        String(text.map { $0.isNewline ? " " : $0 })
    }

    /// The bold title line of a Running row (§4.5): `message` while waiting; otherwise
    /// the conversation title (from the search result with the same
    /// session_id); while no title is available, `task`; failing that, the
    /// label (§3.6).
    ///
    /// Assumption (spec silent): a waiting row with no `message` falls back
    /// through the same title -> task -> label chain. `task` used as a
    /// fallback is made single-line like the last prompt.
    public static func runningRowTitle(agent: Agent, title: String?, label: String) -> String {
        if agent.status == .waiting, let message = agent.message, !message.isEmpty {
            return singleLine(message)
        }
        return runningTitle(agent: agent, title: title, label: label)
    }

    /// The conversation title of a Running row without the waiting override:
    /// title -> task -> label. Used for the pane header (§4.6: the header's
    /// second line is the title).
    static func runningTitle(agent: Agent, title: String?, label: String) -> String {
        if let title, !title.isEmpty {
            return singleLine(title)
        }
        if let task = agent.task, !task.isEmpty {
            return singleLine(task)
        }
        return label
    }

    /// The label line (§4.5 / §4.6): the label, followed by ` · running` on a
    /// live History row. The elapsed time is not part of it (it is shown in
    /// the symbol-and-time column).
    static func labelLine(label: String, runningMark: Bool) -> String {
        var text = label
        if runningMark {
            text += " \u{00B7} running"
        }
        return text
    }

    /// The pane header's top line (§4.6): the row's folder label, then the
    /// elapsed time (`demo/menubar-app · 3h ago`). The `running` mark is not
    /// part of it. Assumption: with an empty label (no cwd) only the elapsed
    /// part is shown.
    static func headerLabelAndElapsed(label: String, elapsedSeconds: Int64) -> String {
        let elapsed = "\(ElapsedTime.format(seconds: elapsedSeconds)) ago"
        guard !label.isEmpty else { return elapsed }
        return "\(label) \u{00B7} \(elapsed)"
    }

    /// Build one Running row (§4.5). `title` is the matched search result's
    /// title, if any. Returns nil for an `.unknown` status (clients ignore
    /// unknown statuses — §4.2).
    public static func runningRow(agent: Agent, title: String?, now: Int64, home: String?) -> UnifiedListRow? {
        guard let symbol = RowSymbol.kind(for: agent.status) else { return nil }
        let label = CwdLabel.format(cwd: agent.cwd, home: home)
        let elapsed = max(0, now - agent.since)
        let rowTitle = runningRowTitle(agent: agent, title: title, label: label)
        let prompt = agent.task.flatMap { $0.isEmpty ? nil : singleLine($0) }
        let primary = ConversationAction.derive(forRunningAgent: agent)
            .button(sessionID: agent.sessionId, cwd: agent.cwd)
        let branch = ConversationAction.branchButton(sessionID: agent.sessionId, cwd: agent.cwd)
        return UnifiedListRow(
            id: .running(target: agent.target),
            section: .running,
            sessionID: agent.sessionId,
            cwd: agent.cwd,
            title: rowTitle,
            label: label,
            elapsedSeconds: elapsed,
            labelLine: labelLine(label: label, runningMark: false),
            showsRunningMark: false,
            lastPrompt: prompt,
            symbol: .status(symbol, unreviewed: agent.unreviewed),
            primaryButton: primary,
            branchButton: branch,
            headerTitle: agent.sessionId.isEmpty ? rowTitle : runningTitle(agent: agent, title: title, label: label),
            headerLabelAndElapsed: headerLabelAndElapsed(label: label, elapsedSeconds: elapsed)
        )
    }

    /// Build one History row: a Starred row (`isStarred`) or a Recent row
    /// (§4.6 "Starred section": the same content and behavior as a Recent
    /// row, with the filled star).
    public static func historyRow(
        summary: ConversationSummary,
        isStarred: Bool,
        now: Int64,
        home: String?
    ) -> UnifiedListRow {
        historyRow(summary: summary, section: isStarred ? .starred : .recent, now: now, home: home)
    }

    /// Build one conversation row of `section` (Starred, Recent, or the
    /// Archive view — §4.6 "Archive view": the same lines, elapsed time and
    /// buttons as a Recent row; the column's top is the more button alone,
    /// whose menu is `Unarchive`). The summary is never one that matches a
    /// Running row (those are excluded before this), so a `live` summary is
    /// a conversation running in a terminal this app cannot drive.
    ///
    /// Assumption (spec silent): with no title and no cwd, the title is empty.
    public static func historyRow(
        summary: ConversationSummary,
        section: UnifiedListSection,
        now: Int64,
        home: String?
    ) -> UnifiedListRow {
        let label = summary.cwd.map { CwdLabel.format(cwd: $0, home: home) } ?? ""
        let elapsed = max(0, now - summary.updatedAt)
        let title: String
        if let raw = summary.title, !raw.isEmpty {
            title = singleLine(raw)
        } else {
            title = label
        }
        let prompt = summary.lastPrompt.flatMap { $0.isEmpty ? nil : singleLine($0) }
        // Matched live conversations are excluded, so `agents: []` leaves
        // exactly the History outcomes (§4.6): resume / resumeDisabled /
        // jumpDisabled.
        let primary = ConversationAction.derive(for: summary, agents: [])
            .button(sessionID: summary.sessionID, cwd: summary.cwd)
        let branch = ConversationAction.branchButton(sessionID: summary.sessionID, cwd: summary.cwd)
        let symbol: RowColumnSymbol
        let menu: [RowMenuItem]
        switch section {
        case .archived:
            symbol = .moreButtonOnly
            menu = [.unarchive]
        case .running, .starred, .recent:
            symbol = .star(isStarred: section == .starred)
            menu = [.archive(isEnabled: !summary.live)]
        }
        return UnifiedListRow(
            id: .conversation(sessionID: summary.sessionID),
            section: section,
            sessionID: summary.sessionID,
            cwd: summary.cwd,
            title: title,
            label: label,
            elapsedSeconds: elapsed,
            labelLine: labelLine(label: label, runningMark: summary.live),
            showsRunningMark: summary.live,
            lastPrompt: prompt,
            symbol: symbol,
            primaryButton: primary,
            branchButton: branch,
            headerTitle: title,
            headerLabelAndElapsed: headerLabelAndElapsed(label: label, elapsedSeconds: elapsed),
            menuItems: menu
        )
    }

    /// The Running section's rows (§4.5/§4.6):
    /// - `created_at` descending (stable for ties);
    /// - while `isFiltered` (the shown result came from a query with a valid
    ///   term), only rows whose session_id is in `results` — rows with an
    ///   empty session_id are hidden;
    /// - unknown statuses dropped.
    public static func runningRows(
        agents: [Agent],
        results: [ConversationSummary]?,
        isFiltered: Bool,
        now: Int64,
        home: String?
    ) -> [UnifiedListRow] {
        let titles = Dictionary(
            (results ?? []).map { ($0.sessionID, $0.title) },
            uniquingKeysWith: { first, _ in first }
        )
        let resultIDs = Set((results ?? []).map(\.sessionID))
        return agents
            .enumerated()
            .sorted { lhs, rhs in
                lhs.element.createdAt != rhs.element.createdAt
                    ? lhs.element.createdAt > rhs.element.createdAt
                    : lhs.offset < rhs.offset
            }
            .map(\.element)
            .filter { agent in
                guard isFiltered else { return true }
                return !agent.sessionId.isEmpty && resultIDs.contains(agent.sessionId)
            }
            .compactMap { agent in
                runningRow(agent: agent, title: titles[agent.sessionId] ?? nil, now: now, home: home)
            }
    }

    /// The session IDs of the Running rows: only agents that produce a row
    /// count (an unknown status has none — §4.2).
    static func runningSessionIDs(agents: [Agent]) -> Set<String> {
        Set(agents.filter { $0.status != .unknown }.map(\.sessionId).filter { !$0.isEmpty })
    }

    /// The live conversations (§4.6 "Archive": automatic unarchive): the
    /// session_id of a Running row, or a search result that reports
    /// `live: true` (a conversation resumed in a terminal this app cannot
    /// drive has no Running row).
    public static func liveSessionIDs(agents: [Agent], results: [ConversationSummary]?) -> Set<String> {
        runningSessionIDs(agents: agents).union((results ?? []).filter(\.live).map(\.sessionID))
    }

    /// The Starred and Recent sections' rows (§4.6 "Starred section" /
    /// "Recent section"): the search result minus every conversation whose
    /// session_id matches a Running row (any tracked agent — the exclusion
    /// applies on every render) and minus the archived conversations.
    /// Starred: the starred conversations in the stars' order (an unordered
    /// list: newest first). Recent: the rest in the result's own order
    /// (`updated_at` descending, as search returns it), uncapped here.
    public static func conversationRows(
        results: [ConversationSummary]?,
        agents: [Agent],
        stars: StarredList,
        archived: ArchivedList = ArchivedList(),
        now: Int64,
        home: String?
    ) -> (starred: [UnifiedListRow], recent: [UnifiedListRow]) {
        guard let results else { return ([], []) }
        // Only agents that produce a Running row exclude (an unknown status
        // has no row, so its conversation must not vanish from every section).
        let runningIDs = runningSessionIDs(agents: agents)
        let archivedIDs = Set(archived.sessionIDs)
        let remaining = results.filter { !runningIDs.contains($0.sessionID) && !archivedIDs.contains($0.sessionID) }
        let order = stars.materialized(results: results).sessionIDs
        let rank = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let starred = remaining.enumerated()
            .filter { rank[$0.element.sessionID] != nil }
            .sorted { lhs, rhs in
                let left = rank[lhs.element.sessionID] ?? 0
                let right = rank[rhs.element.sessionID] ?? 0
                return left != right ? left < right : lhs.offset < rhs.offset
            }
            .map { historyRow(summary: $0.element, isStarred: true, now: now, home: home) }
        let recent = remaining
            .filter { rank[$0.sessionID] == nil }
            .map { historyRow(summary: $0, isStarred: false, now: now, home: home) }
        return (starred, recent)
    }

    /// The Archive view's rows (§4.6 "Archive view"): the archived
    /// conversations that are in the search result, in the archived list's
    /// order (newest archive first), uncapped here. A conversation of a
    /// Running row is never shown (it is live, so it is unarchived).
    public static func archivedRows(
        results: [ConversationSummary]?,
        agents: [Agent],
        archived: ArchivedList,
        now: Int64,
        home: String?
    ) -> [UnifiedListRow] {
        guard let results else { return [] }
        let runningIDs = runningSessionIDs(agents: agents)
        let byID = Dictionary(results.map { ($0.sessionID, $0) }, uniquingKeysWith: { first, _ in first })
        return archived.sessionIDs.compactMap { sessionID in
            guard !runningIDs.contains(sessionID), let summary = byID[sessionID] else { return nil }
            return historyRow(summary: summary, section: .archived, now: now, home: home)
        }
    }
}
