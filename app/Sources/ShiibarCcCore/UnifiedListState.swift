// The single state shared by the popover and the window (DESIGN.md §4.5
// "the popover and the window share one state" / "switching by width" /
// "row selection" / "row click" / "row double-click" / "opening the detail
// page" / "key operations", §4.6 "display state rules" / "History refetch
// triggers" / "bottom panel", §8.49, §8.59). A value type driven by explicit events; each
// event returns the side effects the app must perform. The app holds ONE
// instance (e.g. in an ObservableObject), feeds it daemon updates, search
// results, clock ticks and user input, and renders from its derived
// properties. Views make no decisions of their own.
//
// Columns: the popover is always `.one`; the window reports its width class.
// The popover and the window are never shown at the same time (a tray click
// while the window is open raises the window — §4.5), so the app sends
// `.columnsChanged` whenever the visible surface or the window width class
// changes.

import Foundation

/// The selected row: its key, plus its session_id so a Running row that
/// ends can carry the selection over to the History row with the same
/// session_id (§4.5).
public struct RowSelection: Equatable, Sendable {
    public let key: UnifiedRowKey
    public let sessionID: String

    public init(key: UnifiedRowKey, sessionID: String) {
        self.key = key
        self.sessionID = sessionID
    }
}

/// The mouse press that a row click belongs to (`.pointerDown`).
public struct PointerPress: Equatable, Sendable {
    /// The selection was shown active (accent) as the button went down.
    public let selectionActive: Bool
    /// The system's click count of the press (`NSEvent.clickCount`): 2 for
    /// the second press of a double-click.
    public let clickCount: Int
    /// The press's own time (`NSEvent.timestamp`, system uptime seconds);
    /// nil when unknown.
    public let pressedAt: TimeInterval?
    /// ⌘ was held at the press. On the second click of a double-click it
    /// runs Branch instead of Jump / Resume (§4.5 "row double-click").
    public let commandKey: Bool

    public init(selectionActive: Bool, clickCount: Int, pressedAt: TimeInterval?, commandKey: Bool = false) {
        self.selectionActive = selectionActive
        self.clickCount = clickCount
        self.pressedAt = pressedAt
        self.commandKey = commandKey
    }
}

/// A click on a selected row shown in accent that deselects it once it is
/// certain no double-click follows (§4.5 "row double-click").
public struct PendingDeselect: Equatable, Sendable {
    /// Matches `.deferredDeselectDue(id:)` to the schedule that set it.
    public let id: Int
    public let key: UnifiedRowKey
}

public enum UnifiedListEvent: Equatable, Sendable {
    /// The daemon's agent table changed (snapshot / status_changed /
    /// agent_removed already applied by the app — pass the whole table).
    case agentsUpdated([Agent])
    /// A `conversations search` finished. `isFiltered` = the query had a
    /// valid (2+ character) term; false for the browse (empty-query) list.
    case historyDelivered([ConversationSummary], isFiltered: Bool)
    /// A History fetch (search, or the index run before it) ended in error.
    /// The previous result stays (§4.6).
    case historyFetchFailed
    /// A full index build started (true) or ended (false). While it runs,
    /// History is hidden and the empty-state line is suppressed (§4.6).
    case fullBuildChanged(Bool)
    /// Re-take the elapsed-time base (on show, then every 60s — §4.5/§9).
    case clockTicked(now: Int64)
    /// A click on a row outside its star (§4.5 "row click"): selects the row, in one column and in two, and moves focus
    /// to the list. A click on the selected row deselects it only when the
    /// selection was shown active (accent) as the mouse button went down
    /// (`.pointerDown`); a click on a gray selected row keeps it and only
    /// moves focus. Never opens the detail page.
    ///
    /// The press's click count tells the clicks of a double-click apart
    /// (§4.5 "row double-click"): the second click on the same row selects
    /// it, moves focus to the list and runs the primary button (Jump /
    /// Resume) like Enter with list focus — or Branch like ⌘Enter when ⌘ is
    /// held at that second press; further clicks of the same sequence do
    /// not run either again. Because a double-click never deselects,
    /// the deselect of a single click on an accent row waits until no
    /// second click can follow (`.scheduleDeferredDeselect`). Without a
    /// press (no `.pointerDown`) no second click can follow, so it
    /// deselects at once.
    case rowClicked(UnifiedRowKey)
    /// ↑ on the list: the previous row.
    case moveUp
    /// ↓ on the list: the next row.
    case moveDown
    /// ⌥↑ on the one-column detail page and the detail header's "Previous
    /// conversation": the previous row's conversation (selection moves too).
    case previousConversation
    /// ⌥↓ and the detail header's "Next conversation".
    case nextConversation
    /// Enter in the search field (§4.5 "key operations"): focus moves to the
    /// list; with no selection the first row is selected (no rows: nothing).
    case enterFromSearchField
    /// → with list focus, and the bottom panel's View button (§4.5 "opening
    /// the detail page"): the one-column list page opens the detail page of
    /// the selected row.
    case openDetail
    /// The detail page's back button and ← with list focus.
    case back
    /// ⌘F.
    case focusSearch
    /// The global hotkey opened the popover or brought the window forward
    /// (§4.5 "global hotkey"): focus goes to the list by the rule of Enter in
    /// the search field (no selection: the first row is selected; no rows:
    /// the search field instead). On the one-column detail page the page
    /// stays and the conversation pane takes focus.
    case openedByHotKey
    /// The search field gained (true) or lost (false) keyboard focus on the
    /// visible surface.
    case searchFieldFocusChanged(Bool)
    /// The visible surface (the popover's window or the main window) became
    /// key (true) or stopped being key (false).
    case surfaceKeyChanged(Bool)
    /// The left mouse button went down on the visible surface, before the
    /// click reaches any view: whether the surface was key and whether the
    /// search field had focus at that moment. AppKit can make the window key
    /// or move the first responder before a row's click action runs, so
    /// the row click that follows decides from this snapshot (§4.5 "row
    /// click": only a row shown in accent deselects).
    ///
    /// `clickCount` is the system's click count of the press, `pressedAt`
    /// its own time (`NSEvent.timestamp`) and `commandKey` whether ⌘ was
    /// held; see `PointerPress`.
    case pointerDown(
        surfaceKey: Bool, searchFieldFocused: Bool, clickCount: Int = 1, pressedAt: TimeInterval? = nil,
        commandKey: Bool = false)
    /// The system double-click interval since the press of a deferred
    /// deselect has passed (`.scheduleDeferredDeselect`): no second click
    /// came, so the row deselects — unless the deselect was cancelled
    /// meanwhile (a second click, another selection change or page change,
    /// or the surface closed).
    case deferredDeselectDue(id: Int)
    /// The visible surface closed (popover closed / window closed): a
    /// pending deselect and the click sequence are dropped.
    case surfaceHidden
    /// The column mode of the visible surface changed.
    case columnsChanged(ColumnMode)
    /// A click on a History row's star (never selects — §4.6).
    case starToggled(sessionID: String)
}

public enum UnifiedListEffect: Equatable, Sendable {
    /// The conversation pane now shows this conversation: run
    /// `conversations show` (§4.6). Never emitted for an empty session_id,
    /// and not emitted while the shown conversation stays the same.
    case loadConversation(sessionID: String)
    /// Scroll the list by the minimum amount that brings the selected row
    /// fully into view (no-op when it already is — §4.5).
    case scrollSelectionIntoView
    /// Move keyboard focus to the search field (caret at the end of the
    /// text).
    case focusSearchField
    /// Move keyboard focus to the list: the search field resigns (no caret).
    case focusList
    /// Move keyboard focus to the conversation pane (one column: the detail
    /// page opened).
    case focusConversationPane
    /// Re-run the search with the current query (§4.6 trigger: a Running row
    /// disappeared). Answer with `.historyDelivered` or `.historyFetchFailed`.
    case refetchHistory
    /// Re-run the search once more after `afterSeconds` (§4.6: the second
    /// refetch after a Running row disappeared; §9 delay). A newer schedule
    /// may replace a pending one.
    case refetchHistoryLater(afterSeconds: Double)
    /// Persist the star set (`StarredSessions.save`).
    case persistStars(Set<String>)
    /// Run a row verb; feed the exit code to `RowInvocationOutcome.classify`.
    case invoke(RowInvocation)
    /// Answer with `.deferredDeselectDue(id:)` once the system double-click
    /// interval has passed since the press (`pressedAt`, system uptime;
    /// nil = from now) — §4.5 "row double-click". A cancelled deselect
    /// ignores the answer, so the timer itself never needs cancelling.
    case scheduleDeferredDeselect(id: Int, pressedAt: TimeInterval?)
    case closePopover
    /// Run Refresh (§4.6: the search and `shiibar-cc reconcile`), the same
    /// as the header row's ⟳.
    case refresh
    case nextMatch
    case previousMatch
    case increaseTextSize
    case decreaseTextSize
    case resetTextSize
}

/// What the conversation pane area shows.
public enum ConversationPaneContent: Equatable, Sendable {
    /// One column, list page: no pane on screen.
    case hidden
    /// Two columns with no selection: only the centered line (§4.5).
    case noSelection
    case conversation(ConversationPaneModel)

    /// §4.5: the two-column right column's text while nothing is selected.
    public static let noSelectionText = "No conversation selected"
}

/// One button position of the bottom panel's right side (§4.6 "bottom
/// panel"), left to right: View (one-column list page only), Branch, then
/// the primary button at the right end.
public enum BottomPanelSlot: Equatable, Sendable {
    case view
    case branch
    case primary
}

/// The bottom panel (§4.6 "bottom panel"): the key hints on the left (one
/// column only) and the selected row's action buttons on the right (§4.5
/// "action buttons"). Shown at the bottom of the one-column list page and of
/// the conversation pane; the same view and the same button positions in
/// both places.
public struct BottomPanelModel: Equatable, Sendable {
    /// Left side; empty in the two-column right column.
    public let hints: [KeyHint]
    /// Right side; nil while the buttons are not shown (`showsButtons`). The
    /// panel keeps its height either way (§4.6).
    public let buttons: BottomPanelButtons?
    /// The panel's button positions, left to right. The same whether or not
    /// the buttons are shown, so the hidden buttons keep the layout.
    public let slots: [BottomPanelSlot]

    public init(hints: [KeyHint], buttons: BottomPanelButtons?, showsViewButton: Bool) {
        self.hints = hints
        self.buttons = buttons
        self.slots = BottomPanelModel.slots(showsViewButton: showsViewButton)
    }

    /// §4.6 "bottom panel" / §8.59: View sits left of Branch on the
    /// one-column list page only. The detail page and the two-column right
    /// column already show the conversation, so they have no View.
    public static func slots(showsViewButton: Bool) -> [BottomPanelSlot] {
        (showsViewButton ? [.view] : []) + [.branch, .primary]
    }

    /// The View button's title and its key, shown inside the button like the
    /// other buttons' shortcuts (§4.6: `View →`). View is never disabled.
    public static let viewTitle = "View"
    public static let viewShortcut = "\u{2192}"

    /// Whether the panel shows the selected row's buttons (§4.6 "bottom
    /// panel", §8.55): only while a row is selected and the search field
    /// does not have focus — there, Enter moves focus to the list and
    /// ⌘Enter does nothing, so every button on screen is one the keys run.
    /// The same rule in one column and in two.
    public static func showsButtons(hasSelection: Bool, searchFieldFocused: Bool) -> Bool {
        hasSelection && !searchFieldFocused
    }
}

/// The selected row's two action buttons: Branch, then the primary button at
/// the right end (§4.6).
public struct BottomPanelButtons: Equatable, Sendable {
    /// Right end: Resume or Jump (or the disabled Jump).
    public let primary: RowButton
    /// Left of the primary button.
    public let branch: RowButton

    public init(primary: RowButton, branch: RowButton) {
        self.primary = primary
        self.branch = branch
    }

    /// The selected row's buttons as displayed (disabled while awaiting the
    /// refetch after a selected Running row ended — §4.5).
    public init(row: UnifiedListRow) {
        self.init(primary: row.primaryButton, branch: row.branchButton)
    }
}

/// The conversation pane's native parts (§4.6 header / find bar / bottom
/// panel). The message surface itself is the WKWebView page.
public struct ConversationPaneModel: Equatable, Sendable {
    /// The row the pane shows (buttons already disabled while awaiting the
    /// refetch after a Running row ended).
    public let row: UnifiedListRow
    /// The header's first line (§4.6): the card's folder label · elapsed ago.
    public var labelAndElapsed: String { row.headerLabelAndElapsed }
    /// The header's second line (§4.6): the title.
    public var title: String { row.headerTitle }
    /// false for a row with an empty session_id: show `noMessagesText` in
    /// the message surface instead of running `show` (§4.5).
    public let showsMessages: Bool
    /// One column: the back button, the position and the prev/next buttons.
    public let showsBackButton: Bool
    /// `2 / 4` (one column only; hidden while awaiting the refetch — §4.5).
    public let positionText: String?
    /// The detail header's prev / next buttons (disabled at the ends).
    public let canGoPrevious: Bool
    public let canGoNext: Bool
    /// One column: the find bar shows `Matches for “term”` at its left end
    /// and the counter / control at its right end (§4.6; `FindBarQueryText`).
    public let showsQueryInFindBar: Bool
    /// Bottom panel, right end: Resume or Jump (or the disabled Jump).
    public let primaryButton: RowButton
    /// Bottom panel, left of the primary button.
    public let branchButton: RowButton
    /// Bottom panel, left side (one column only).
    public let hints: [KeyHint]
    /// Bottom panel: the buttons are shown (`BottomPanelModel.showsButtons`;
    /// false while the search field has focus).
    public let showsButtons: Bool

    /// The pane's bottom panel: the shown row's buttons unless the search
    /// field has focus.
    public var bottomPanel: BottomPanelModel {
        BottomPanelModel(
            hints: hints,
            buttons: showsButtons ? BottomPanelButtons(primary: primaryButton, branch: branchButton) : nil,
            showsViewButton: false)
    }

    public static let noMessagesText = "No conversation to show"
    public static let backTooltip = "Back"
    public static let previousTooltip = "Previous conversation"
    public static let nextTooltip = "Next conversation"
}

/// The one-column detail page's find bar sentence (§4.6 "hit navigation"):
/// `Matches for` (secondary color) followed by the query in typographic
/// quotes (primary color, middle-truncated when long).
public enum FindBarQueryText {
    public static let prefix = "Matches for"

    /// The query as typed, trimmed at both ends, in “ ”.
    public static func quotedTerm(_ query: String) -> String {
        "\u{201C}\(query.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}"
    }
}

public struct UnifiedListState: Equatable, Sendable {
    // MARK: Inputs

    public let home: String?
    public private(set) var now: Int64
    public private(set) var agents: [Agent] = []
    /// The latest delivered search result; nil before the first delivery and
    /// during a full index build.
    public private(set) var history: [ConversationSummary]?
    /// Whether `history` came from a query with a valid term.
    public private(set) var historyIsFiltered = false
    public private(set) var stars: Set<String>
    public private(set) var isFullBuild = false

    // MARK: View state

    public private(set) var columns: ColumnMode = .one
    /// Meaningful in one column only; normalized to `.list` in two columns.
    public private(set) var page: ListPage = .list
    /// nil after launch until the user selects a row (§4.5).
    public private(set) var selection: RowSelection?
    /// Set while the selected Running row has disappeared and the History
    /// refetch it triggered has not completed (§4.5): a snapshot of the row
    /// with its buttons disabled.
    public private(set) var awaitingRefetchRow: UnifiedListRow?
    /// The search field has keyboard focus on the visible surface (false =
    /// "the list has focus" — §4.5 "key operations").
    public private(set) var isSearchFieldFocused = false
    /// The visible surface is the key window (§4.5 "row selection": the
    /// selection is gray while it is not).
    public private(set) var isSurfaceKey = true
    /// The last mouse press on the surface (`.pointerDown`); consumed by
    /// the next `.rowClicked`. nil = no pending press (the current look
    /// decides, and no second click can follow).
    public private(set) var pointerPress: PointerPress?
    /// Whether the selection was shown active when the mouse button last
    /// went down on the surface; nil = no pending press.
    public var selectionActiveAtPointerDown: Bool? { pointerPress?.selectionActive }
    /// A single click's deselect waiting for the double-click interval to
    /// pass (§4.5 "row double-click"); nil = none.
    public private(set) var pendingDeselect: PendingDeselect?
    private var nextDeselectID = 0
    /// The row the current click sequence (consecutive presses counted by
    /// the system) started on, and the system click count just before it.
    /// A press counted as the second click but landing on another row
    /// starts a new sequence there (a plain click on that row).
    private var clickSequence: ClickSequence?

    private struct ClickSequence: Equatable, Sendable {
        let row: UnifiedRowKey
        let baseCount: Int
    }

    // MARK: Derived rows

    public private(set) var runningRows: [UnifiedListRow] = []
    /// The History rows shown: at most `HistoryDisplayLimit.maxRows`, taken
    /// from the head of the full order (§4.6). Everything that consumes rows
    /// (sections, ↑ / ↓, position, selection) sees only these.
    public private(set) var historyRows: [UnifiedListRow] = []
    /// How many History rows the cap hides (0 when none).
    public private(set) var hiddenHistoryCount = 0

    public init(home: String?, now: Int64, stars: Set<String> = []) {
        self.home = home
        self.now = now
        self.stars = stars
    }

    // MARK: Derived properties

    /// Every row shown, in on-screen order (Running, then History). ↑ / ↓
    /// and the detail page's position move within this list.
    public var visibleRows: [UnifiedListRow] { runningRows + historyRows }

    /// The non-empty sections (§4.5: an empty section is hidden, heading
    /// included).
    public var sections: [UnifiedListSectionModel] {
        var result: [UnifiedListSectionModel] = []
        if !runningRows.isEmpty {
            result.append(UnifiedListSectionModel(section: .running, rows: runningRows))
        }
        if !historyRows.isEmpty {
            result.append(UnifiedListSectionModel(section: .history, rows: historyRows,
                                                  hiddenCount: hiddenHistoryCount))
        }
        return result
    }

    public var isAwaitingRefetch: Bool { awaitingRefetchRow != nil }

    /// The selected row as displayed (the disabled snapshot while awaiting
    /// the refetch).
    public var selectedRow: UnifiedListRow? {
        if let awaitingRefetchRow { return awaitingRefetchRow }
        guard let selection else { return nil }
        return visibleRows.first { $0.id == selection.key }
    }

    /// Whether the list is on screen (two columns, or the list page).
    public var isListVisible: Bool { columns == .two || page == .list }

    /// Whether the conversation pane shows a conversation.
    public var isConversationPaneVisible: Bool {
        selection != nil && (columns == .two || page == .detail)
    }

    /// The empty-state line (§4.6): only when both sections are empty, never
    /// during a full index build, and never before a search result has been
    /// delivered (`history` is nil until the first delivery after launch).
    /// "Searching" means the shown result came from a query with a valid
    /// term (assumption: a query with only 1-character words shows the
    /// browse list, so it reads as empty).
    public var emptyStateText: String? {
        guard !isFullBuild, history != nil, runningRows.isEmpty, historyRows.isEmpty else { return nil }
        return historyIsFiltered ? "No matching conversations" : "No conversations"
    }

    /// The line under the last History card when the cap hides rows (§4.6;
    /// window-design.html "hidden conversation count"); nil when nothing is
    /// hidden. Not a row: it is never selectable.
    public var hiddenHistoryText: String? {
        guard hiddenHistoryCount > 0 else { return nil }
        let hint = historyIsFiltered ? "refine your search" : "search to narrow down"
        return "\(hiddenHistoryCount) more \u{2014} \(hint)"
    }

    /// The selected card's look (§4.5 "row selection"): accent while the
    /// keys act on the list — the surface is key and the list has focus —
    /// and gray while the search field has focus or the surface is not key.
    public var isSelectionActive: Bool { isSurfaceKey && !isSearchFieldFocused }

    /// The list's key hints (§4.5 "key hints"): the two-column left
    /// column's footer, and the left side of the one-column list page's
    /// bottom panel. They follow the search field's focus only.
    public var footerHints: [KeyHint] {
        KeyHints.footer(listFocused: !isSearchFieldFocused)
    }

    /// The bottom panel of the one-column list page (§4.6 "bottom panel"):
    /// the list's key hints on the left, the selected row's buttons on the
    /// right — View, Branch, the primary button — (none while nothing is
    /// selected or the search field has focus).
    /// nil in two columns, where the left column's footer shows the key
    /// hints only and the buttons live in the right column's pane (§4.5 "key
    /// hints").
    public var listBottomPanel: BottomPanelModel? {
        guard columns == .one else { return nil }
        let row = selectedRow
        let shows = BottomPanelModel.showsButtons(hasSelection: row != nil, searchFieldFocused: isSearchFieldFocused)
        return BottomPanelModel(
            hints: footerHints,
            buttons: shows ? row.map(BottomPanelButtons.init(row:)) : nil,
            showsViewButton: true)
    }

    /// The pane area's content for the current columns / page / selection.
    public var paneContent: ConversationPaneContent {
        if columns == .one && page == .list { return .hidden }
        guard let row = selectedRow else {
            // Two columns without a selection. (One column never shows the
            // detail page without one: deselecting returns to the list.)
            return columns == .two ? .noSelection : .hidden
        }
        let rows = visibleRows
        let index = awaitingRefetchRow == nil ? rows.firstIndex { $0.id == row.id } : nil
        let oneColumn = columns == .one
        return .conversation(ConversationPaneModel(
            row: row,
            showsMessages: !row.sessionID.isEmpty,
            showsBackButton: oneColumn,
            positionText: (oneColumn ? index : nil).map { "\($0 + 1) / \(rows.count)" },
            canGoPrevious: oneColumn && (index.map { $0 > 0 } ?? false),
            canGoNext: oneColumn && (index.map { $0 < rows.count - 1 } ?? false),
            showsQueryInFindBar: oneColumn,
            primaryButton: row.primaryButton,
            branchButton: row.branchButton,
            hints: KeyHints.bottomPanel(columns: columns),
            showsButtons: BottomPanelModel.showsButtons(hasSelection: true, searchFieldFocused: isSearchFieldFocused)
        ))
    }

    /// Context for `UnifiedListKeys.decide`. The focus location is the
    /// state's `isSearchFieldFocused` (the app reports it before deciding).
    public func keyContext(isPopover: Bool, hasMarkedText: Bool) -> ListKeyContext {
        let row = selectedRow
        return ListKeyContext(
            columns: columns,
            page: page,
            searchFieldFocused: isSearchFieldFocused,
            hasRows: !visibleRows.isEmpty,
            hasSelection: selection != nil,
            primaryEnabled: row?.primaryButton.isEnabled ?? false,
            branchEnabled: row?.branchButton.isEnabled ?? false,
            conversationPaneVisible: isConversationPaneVisible,
            isPopover: isPopover,
            hasMarkedText: hasMarkedText
        )
    }

    // MARK: Events

    /// Apply one event; returns the effects to perform, in order.
    @discardableResult
    public mutating func handle(_ event: UnifiedListEvent) -> [UnifiedListEffect] {
        let before = Observation(self)
        var effects: [UnifiedListEffect] = []
        var movedSelection = false

        switch event {
        case .agentsUpdated(let newAgents):
            applyAgents(newAgents, effects: &effects)

        case .historyDelivered(let results, let isFiltered):
            history = results
            historyIsFiltered = isFiltered
            if !isFiltered {
                let pruned = StarredSessions.pruned(stars, browseResults: results)
                if pruned != stars {
                    stars = pruned
                    effects.append(.persistStars(stars))
                }
            }
            rebuild()
            if let pending = awaitingRefetchRow {
                // The refetch completed: keep the selection on the History
                // row with the same session_id, else deselect (§4.5).
                awaitingRefetchRow = nil
                if historyRows.contains(where: { $0.sessionID == pending.sessionID }) {
                    selection = RowSelection(key: .history(sessionID: pending.sessionID), sessionID: pending.sessionID)
                } else {
                    deselect()
                }
            }
            reconcileSelection()

        case .historyFetchFailed:
            // §4.5: a refetch that ends in error counts as "no row with the
            // same session_id".
            if awaitingRefetchRow != nil {
                deselect()
            }

        case .fullBuildChanged(let building):
            isFullBuild = building
            if building {
                // §4.6: no partial result during a full build — History is
                // hidden until the build completes and the search delivers.
                history = nil
                historyIsFiltered = false
                rebuild()
                if awaitingRefetchRow == nil {
                    reconcileSelection()
                }
            }

        case .clockTicked(let newNow):
            now = newNow
            rebuild()

        case .rowClicked(let key):
            // §4.5 "row click": select; the selected row deselects only when
            // it was shown in accent at the press — a gray selected row keeps
            // its selection and only gains focus. The detail page opens with
            // View or → (§4.5 "opening the detail page").
            let press = pointerPress
            pointerPress = nil
            let wasActive = press?.selectionActive ?? isSelectionActive
            guard let row = visibleRows.first(where: { $0.id == key }) else {
                clickSequence = nil
                break
            }
            switch clickOrdinal(on: key, clickCount: press?.clickCount ?? 1) {
            case 1:
                if selection?.key == key {
                    if wasActive {
                        if let press {
                            // §4.5 "row double-click": a double-click never
                            // deselects, so wait until none can follow.
                            nextDeselectID += 1
                            pendingDeselect = PendingDeselect(id: nextDeselectID, key: key)
                            effects.append(.scheduleDeferredDeselect(id: nextDeselectID, pressedAt: press.pressedAt))
                        } else {
                            deselect()
                        }
                    }
                } else {
                    select(row)
                }
                effects.append(.focusList)
            case 2:
                // §4.5 "row double-click": select, focus the list, then
                // what Enter with list focus does — ⌘Enter (Branch) when ⌘
                // is held at this second press — and nothing more when that
                // button is disabled. The first click's deselect is off.
                pendingDeselect = nil
                if selection?.key != key {
                    select(row)
                }
                effects.append(.focusList)
                let button = press?.commandKey == true ? selectedRow?.branchButton : selectedRow?.primaryButton
                if let invocation = button?.invocation {
                    effects.append(.invoke(invocation))
                }
            default:
                // Clicks 3+ of the sequence: never run Jump / Resume again.
                if selection?.key != key {
                    select(row)
                }
                effects.append(.focusList)
            }

        case .moveUp, .moveDown:
            movedSelection = move(up: event == .moveUp)

        case .previousConversation, .nextConversation:
            // The same row step as ↑ / ↓; only offered on the one-column
            // detail page (§4.5 "key operations").
            movedSelection = move(up: event == .previousConversation)

        case .enterFromSearchField:
            if selection == nil {
                guard let first = visibleRows.first else { break }
                select(first)
                movedSelection = true
            }
            effects.append(.focusList)

        case .openDetail:
            guard columns == .one, page == .list, selection != nil else { break }
            page = .detail

        case .back:
            if columns == .one {
                page = .list
            }

        case .focusSearch:
            if columns == .one {
                page = .list
            }
            effects.append(.focusSearchField)

        case .openedByHotKey:
            if columns == .one && page == .detail {
                effects.append(.focusConversationPane)
            } else if selection != nil {
                effects.append(.focusList)
            } else if let first = visibleRows.first {
                select(first)
                movedSelection = true
                effects.append(.focusList)
            } else {
                effects.append(.focusSearchField)
            }

        case .searchFieldFocusChanged(let focused):
            isSearchFieldFocused = focused

        case .surfaceKeyChanged(let key):
            isSurfaceKey = key

        case .pointerDown(let surfaceKey, let searchFieldFocused, let clickCount, let pressedAt, let commandKey):
            if pointerPress != nil {
                // The previous press reached no row (empty space, a button,
                // the star): a later press of the same system click count
                // does not continue a click sequence on a row.
                clickSequence = nil
            }
            pointerPress = PointerPress(
                selectionActive: surfaceKey && !searchFieldFocused,
                clickCount: clickCount,
                pressedAt: pressedAt,
                commandKey: commandKey)

        case .deferredDeselectDue(let id):
            guard let pending = pendingDeselect, pending.id == id else { break }
            pendingDeselect = nil
            if selection?.key == pending.key {
                deselect()
            }

        case .surfaceHidden:
            pendingDeselect = nil
            pointerPress = nil
            clickSequence = nil

        case .columnsChanged(let newColumns):
            guard newColumns != columns else { break }
            columns = newColumns
            // one(detail) -> two: same selection, shown in the right column.
            // two -> one: the list page, selection kept (§4.5).
            page = .list

        case .starToggled(let sessionID):
            stars = StarredSessions.toggled(stars, sessionID: sessionID)
            effects.append(.persistStars(stars))
            rebuild()
        }

        let after = Observation(self)
        // A pending deselect belongs to the selection and page the click
        // saw: any other change of either cancels it (another row clicked,
        // ↑ / ↓, the row left the list, the detail page opened).
        if pendingDeselect != nil,
           after.selectionKey != before.selectionKey || after.page != before.page {
            pendingDeselect = nil
        }
        if after.displayedSessionID != before.displayedSessionID,
           let sessionID = after.displayedSessionID, !sessionID.isEmpty {
            effects.append(.loadConversation(sessionID: sessionID))
        }
        if selection != nil, after.listVisible,
           (movedSelection || !before.listVisible) {
            effects.append(.scrollSelectionIntoView)
        }
        // One column: the keyboard follows the page (§4.5 "popover": the
        // detail page focuses the conversation pane). Back on the list page
        // the focus is the list — only ⌘F (and a click on the field) moves
        // it to the search field (§4.5 "key operations").
        if columns == .one, before.columns == .one, after.page != before.page {
            switch after.page {
            case .detail:
                effects.append(.focusConversationPane)
            case .list:
                if !effects.contains(.focusSearchField), !effects.contains(.focusList) {
                    effects.append(.focusList)
                }
            }
        }
        return effects
    }

    /// Run a key command decided by `UnifiedListKeys.decide`.
    @discardableResult
    public mutating func perform(_ command: ListKeyCommand) -> [UnifiedListEffect] {
        switch command {
        case .moveUp: return handle(.moveUp)
        case .moveDown: return handle(.moveDown)
        case .previousConversation: return handle(.previousConversation)
        case .nextConversation: return handle(.nextConversation)
        case .enterFromSearchField: return handle(.enterFromSearchField)
        case .openDetail: return handle(.openDetail)
        case .back: return handle(.back)
        case .focusSearch: return handle(.focusSearch)
        case .primary:
            return selectedRow?.primaryButton.invocation.map { [.invoke($0)] } ?? []
        case .branch:
            return selectedRow?.branchButton.invocation.map { [.invoke($0)] } ?? []
        case .nextMatch: return [.nextMatch]
        case .previousMatch: return [.previousMatch]
        case .closePopover: return [.closePopover]
        case .refresh: return [.refresh]
        case .increaseTextSize: return [.increaseTextSize]
        case .decreaseTextSize: return [.decreaseTextSize]
        case .resetTextSize: return [.resetTextSize]
        }
    }

    // MARK: Internals

    private struct Observation {
        /// nil = no pane on screen; "" = a row without a session_id.
        let displayedSessionID: String?
        let selectionKey: UnifiedRowKey?
        let listVisible: Bool
        let columns: ColumnMode
        let page: ListPage

        init(_ state: UnifiedListState) {
            displayedSessionID = state.isConversationPaneVisible ? state.selection?.sessionID : nil
            selectionKey = state.selection?.key
            listVisible = state.isListVisible
            columns = state.columns
            page = state.page
        }
    }

    private mutating func applyAgents(_ newAgents: [Agent], effects: inout [UnifiedListEffect]) {
        let oldTargets = Set(agents.filter { $0.status != .unknown }.map(\.target))
        let newTargets = Set(newAgents.filter { $0.status != .unknown }.map(\.target))
        let selectedSnapshot = selectedRow
        agents = newAgents

        // §4.6 trigger: a Running row disappeared -> refetch History so the
        // ended conversation shows up there, now and once more after the §9
        // delay (the ending process may still read as live at first).
        if !oldTargets.subtracting(newTargets).isEmpty {
            effects.append(.refetchHistory)
            effects.append(.refetchHistoryLater(afterSeconds: MainSurfaceRefresh.endedRowSecondRefetchSeconds))
        }

        if let selection, case .running(let target) = selection.key {
            if newTargets.contains(target) {
                // Still running (or back again while awaiting): normal rules.
                awaitingRefetchRow = nil
            } else if awaitingRefetchRow == nil {
                if !selection.sessionID.isEmpty, let snapshot = selectedSnapshot {
                    // §4.5: keep the selection and the detail page until the
                    // refetch completes; buttons disabled meanwhile.
                    awaitingRefetchRow = snapshot.withButtonsDisabled()
                } else {
                    // Assumption: with an empty session_id no History row can
                    // ever match, so deselect at once.
                    deselect()
                }
            }
        }
        rebuild()
        if awaitingRefetchRow == nil {
            reconcileSelection()
        }
    }

    private mutating func rebuild() {
        runningRows = UnifiedListBuilder.runningRows(
            agents: agents, results: history, isFiltered: historyIsFiltered, now: now, home: home
        )
        let allHistoryRows = UnifiedListBuilder.historyRows(
            results: history, agents: agents, stars: stars, now: now, home: home
        )
        historyRows = Array(allHistoryRows.prefix(HistoryDisplayLimit.maxRows))
        hiddenHistoryCount = allHistoryRows.count - historyRows.count
    }

    /// §4.5: a selected row that is no longer in the list deselects (no other
    /// row gets selected). A Running row keyed by target picks up a changed
    /// session_id. A selected History row whose conversation moved to
    /// Running (e.g. after Resume) keeps the selection — and the shown page —
    /// on the Running row with the same session_id.
    private mutating func reconcileSelection() {
        guard awaitingRefetchRow == nil, let current = selection else { return }
        if let row = visibleRows.first(where: { $0.id == current.key }) {
            if row.sessionID != current.sessionID {
                selection = RowSelection(key: current.key, sessionID: row.sessionID)
            }
        } else if case .history = current.key,
                  !current.sessionID.isEmpty,
                  let running = runningRows.first(where: { $0.sessionID == current.sessionID }) {
            selection = RowSelection(key: running.id, sessionID: running.sessionID)
        } else {
            deselect()
        }
    }

    /// The click's position in its click sequence on `key` (1 = a single
    /// click or the first click; 2 = the second click of a double-click on
    /// the same row). `clickCount` is the system's count of the press; a
    /// press counted as a repeat but landing on another row than the
    /// sequence's starts a new sequence there.
    private mutating func clickOrdinal(on key: UnifiedRowKey, clickCount: Int) -> Int {
        if clickCount > 1, let sequence = clickSequence, sequence.row == key {
            return clickCount - sequence.baseCount
        }
        clickSequence = ClickSequence(row: key, baseCount: max(clickCount, 1) - 1)
        return 1
    }

    private mutating func select(_ row: UnifiedListRow) {
        selection = RowSelection(key: row.id, sessionID: row.sessionID)
        awaitingRefetchRow = nil
    }

    /// Deselect; a one-column detail page returns to the list page (§4.5).
    private mutating func deselect() {
        selection = nil
        awaitingRefetchRow = nil
        page = .list
    }

    /// ↑ / ↓ (§4.5). Returns whether the selection changed.
    private mutating func move(up: Bool) -> Bool {
        // Assumption (spec silent): while awaiting the refetch the selected
        // row is not in the list, so ↑ / ↓ do nothing until it resolves.
        guard awaitingRefetchRow == nil else { return false }
        let rows = visibleRows
        guard !rows.isEmpty else { return false }
        guard let current = selection, let index = rows.firstIndex(where: { $0.id == current.key }) else {
            // No selection: both keys select the first row.
            select(rows[0])
            return true
        }
        let target = up ? index - 1 : index + 1
        guard rows.indices.contains(target) else { return false }
        select(rows[target])
        return true
    }
}
