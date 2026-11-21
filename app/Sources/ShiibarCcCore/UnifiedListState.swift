// The single state shared by the popover and the window (DESIGN.md §4.5
// "the popover and the window share one state" / "switching by width" /
// "row selection" / "row click" / "row double-click" / "opening the detail
// page" / "collapsing sections" / "row drag" / "key operations", §4.6
// "display state rules" / "History refetch triggers" / "bottom panel" /
// "stars", §8.49, §8.59, §8.60). A value type driven by explicit events; each
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
/// ends can carry the selection over to the Starred or Recent row with the
/// same session_id (§4.5).
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

/// Why a press on a row does not start a drag (§4.5 "row drag": rows that
/// cannot be dragged). Shown near the pointer as one line.
public enum RowDragRefusal: Equatable, Sendable {
    /// A Running row.
    case running
    /// Any row while searching.
    case searching
    /// A Recent row while the Starred section is not shown (no Starred
    /// rows): there is nowhere to drop it.
    case noStarredSection

    public var text: String {
        switch self {
        case .running: return "Running is ordered automatically"
        case .searching: return "Clear the search to reorder"
        case .noStarredSection: return "Click the star to add it to Starred"
        }
    }
}

/// The reason on screen; `id` matches `.dragRefusalDismissDue(id:)` to the
/// schedule that set it.
public struct DragRefusalNotice: Equatable, Sendable {
    public let id: Int
    public let refusal: RowDragRefusal

    public var text: String { refusal.text }
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
    /// Enter with list focus and no selection (§4.5 "key operations"): the
    /// first row is selected, as Enter in the search field does (no rows:
    /// nothing).
    case selectFirstRow
    /// → with list focus, and the bottom panel's View button (§4.5 "opening
    /// the detail page"): the one-column list page opens the detail page of
    /// the selected row.
    case openDetail
    /// The detail page's back button and ← with list focus.
    case back
    /// Enter with list focus on a row whose primary button is the disabled
    /// Jump of a row the app cannot jump to (`RowButton.isUndrivableJump`):
    /// show its conversation instead (§4.5 "row double-click", "key
    /// operations") — the one-column list page opens the detail page, two
    /// columns move focus to the conversation pane, and the one-column
    /// detail page does nothing. Any other row: nothing.
    case showConversation
    /// ⌘F.
    case focusSearch
    /// The global hotkey opened the popover or brought the window forward
    /// (§4.5 "global hotkey", §8.66): focus goes to the list and the
    /// selection stays as it is (none stays none); with no rows the search
    /// field takes focus instead. On the one-column detail page the page
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
    /// pending deselect and the click sequence are dropped, a row drag is
    /// cancelled, and the reason a row cannot be dragged goes away.
    case surfaceHidden
    /// The column mode of the visible surface changed.
    case columnsChanged(ColumnMode)
    /// A click on a Starred or Recent row's star (never selects — §4.6).
    case starToggled(sessionID: String)
    /// A click on a heading (§4.5 "collapsing sections"): it opens or
    /// closes — only the first click of consecutive clicks (the click count
    /// comes from the press, `.pointerDown`), and nothing while searching.
    /// The focus and the other sections' selection stay; the surface
    /// becomes key.
    case headingClicked(ListHeading)
    /// The mouse button went down on a row: whether on its star, the
    /// system's click count, and where (any fixed coordinates, used only to
    /// measure the distance the pointer moves). The second (or later) press
    /// of a multi-click on a selected Starred or Recent row cancels that
    /// row's pending deselect: the deselect never runs while the button is
    /// held (§4.5 "row double-click" / "row drag").
    case rowPressed(UnifiedRowKey, clickCount: Int, onStar: Bool, x: Double, y: Double)
    /// The pointer moved with the button still down after `.rowPressed`
    /// (same coordinates). Once it is §9's distance away, the press is
    /// decided once: it starts a row drag — doing what a click does at that
    /// point (selects the row when it is not selected, focuses the list),
    /// and the press is no click afterwards — or, on a row that cannot be
    /// dragged, the reason is shown (§4.5 "row drag").
    case rowPressDragged(x: Double, y: Double)
    /// The button went up after `.rowPressed`.
    case rowPressReleased
    /// The time the reason stays on screen has passed
    /// (`.scheduleDragRefusalDismiss`).
    case dragRefusalDismissDue(id: Int)
    /// The pointer of the drag is at `hit` (moved, or the list changed or
    /// scrolled under it).
    case cardDragMoved(ListPointerHit)
    /// The button was released: the drop runs when there is a target;
    /// otherwise the drag is cancelled.
    case cardDragEnded
    /// The drag ends with nothing changed (Esc, or another cancel trigger
    /// the app sees — §4.5 "row drag": cancel).
    case cardDragCancelled
    /// The search text became valid (true: a 2+ character term) or stopped
    /// being valid (false). "Searching" (§4.5 "collapsing sections" / "row
    /// drag") follows this at once — before the search result arrives, and
    /// also when the search fails.
    case queryValidityChanged(Bool)
    /// A click on a row's more button (§4.6 "Archive"): opens the row's
    /// menu (`.showRowMenu`) — never selects, never counts toward a
    /// double-click, never starts a drag — unless the click continues a
    /// click sequence begun on a heading (§4.5 "collapsing sections").
    case moreButtonClicked(UnifiedRowKey)
    /// `Archive` chosen in a row's menu (§4.6 "Archive").
    case archiveRequested(sessionID: String)
    /// `Unarchive` chosen in an Archive view row's menu.
    case unarchiveRequested(sessionID: String)
    /// The ⌄ menu's `Archived` (§4.5 "⌄ menu"): shows the Archive view, or
    /// returns to the normal list while the Archive view is shown.
    case archivedMenuItemChosen
    /// A click on the Archive view's band (§4.6 "Archive view"): returns to
    /// the normal list — only the first click of consecutive clicks, like a
    /// heading. The keyboard focus stays; the surface becomes key.
    case archiveHeadingClicked
    /// Esc while the Archive view is shown: return to the normal list.
    case leaveArchiveView
    /// The §9 time has passed since the timer with this id started
    /// (`markReadTimerID`): the selected Running row is marked read when it
    /// is unreviewed now (`.markRead`). A timer that was cancelled or
    /// started over ignores its answer.
    case markReadDue(id: Int)
    /// The daemon moved an entry from one target to another (an
    /// `agent_removed` with reason `rekey` — §4.5 "desktop notifications").
    /// Send this before the agent table with the new target: the row is not
    /// treated as gone, its selection and the conversation pane carry over,
    /// and a running mark-read timer keeps running (it marks the new
    /// target).
    case targetRekeyed(from: String, to: String)
    /// A notification of a session the app cannot jump to was clicked, and
    /// the surface is open (§4.5 "notification click"). In order: back to
    /// the normal list, open Running, clear the search text
    /// (`hasSearchText`: the search field has any text), back to the list
    /// page when the one-column detail page shows another conversation,
    /// select the row (a selected row stays selected), start the mark-read
    /// timer over, scroll the row into view, focus the list. Nothing when
    /// the entry is gone.
    case notificationClicked(target: String, hasSearchText: Bool)
    /// Whether the terminal chosen in Settings > Terminal can be used was
    /// decided again (§4.5 "Settings window" > Terminal): while it cannot,
    /// every row's Resume and Branch are disabled with the reason as the
    /// tooltip (§4.6 "Resume and Branch").
    case resumeTerminalAvailabilityChanged(ResumeTerminalAvailability)
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
    /// Persist the stars' ordered list (`StarredSessions.save`).
    case persistStars([String])
    /// Persist the set of closed headings (`CollapsedSections.save`).
    case persistCollapsedSections(Set<ListHeading>)
    /// Persist the archived conversations (`ArchivedSessions.save`).
    case persistArchive([String])
    /// Open the menu of this row's more button at the button (§4.6
    /// "Archive"); its items are the row's `menuItems`.
    case showRowMenu(UnifiedRowKey)
    /// The Archive view was shown: keep the normal list's scroll position
    /// and show the Archive view from its top (§4.6 "Archive view").
    case scrollListToTop
    /// The normal list is back: restore the scroll position it had when the
    /// Archive view was shown.
    case restoreListScroll
    /// Make the visible surface the key window without moving the keyboard
    /// focus (a click on a section heading — §4.5 "collapsing sections").
    case makeSurfaceKey
    /// Run a row verb; feed the exit code to `RowInvocationOutcome.classify`.
    case invoke(RowInvocation)
    /// Answer with `.deferredDeselectDue(id:)` once the system double-click
    /// interval has passed since the press (`pressedAt`, system uptime;
    /// nil = from now) — §4.5 "row double-click". A cancelled deselect
    /// ignores the answer, so the timer itself never needs cancelling.
    case scheduleDeferredDeselect(id: Int, pressedAt: TimeInterval?)
    /// Answer with `.dragRefusalDismissDue(id:)` after `afterSeconds` (§9:
    /// the reason a row cannot be dragged stays this long).
    case scheduleDragRefusalDismiss(id: Int, afterSeconds: Double)
    case closePopover
    /// Run `shiibar-cc seen <target>`: the selected row's selection lasted
    /// the §9 time and the row is unreviewed (§4.5 "operations that lower
    /// the unreviewed flag").
    case markRead(target: String)
    /// Empty the search field (a notification click — §4.5 "notification
    /// click"). The state already counts the search as ended.
    case clearSearchText
    /// Run Refresh (§4.6: the search and `shiibar-cc reconcile`), the same
    /// as the header row's Refresh button.
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

    /// The lines above the button row that say why a shown button is
    /// disabled (`BottomPanelButtons.disabledReasons`); empty while the
    /// buttons are not shown, so the placeholders never carry a reason.
    public var disabledReasons: [String] { buttons?.disabledReasons ?? [] }

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

    /// The disabled buttons' reasons (`RowButton.disabledReason`), one line
    /// each above the button row, primary button's first. Two buttons
    /// disabled for the same reason (an unusable terminal disables both
    /// Resume and Branch) give one entry. Empty when no button has a reason.
    public var disabledReasons: [String] {
        var reasons: [String] = []
        for reason in [primary.disabledReason, branch.disabledReason].compactMap({ $0 })
        where !reasons.contains(reason) {
            reasons.append(reason)
        }
        return reasons
    }
}

/// The conversation pane's native parts (§4.6 header / find bar / bottom
/// panel). The message surface itself is the WKWebView page.
public struct ConversationPaneModel: Equatable, Sendable {
    /// The row the pane shows (buttons already disabled while awaiting the
    /// refetch after a Running row ended).
    public let row: UnifiedListRow
    /// The header's first line (§4.6): the row's folder label · elapsed ago.
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

/// What the conversation pane shows after `conversations show` (§4.6
/// "conversation pane"): the messages; the centered `No conversation to
/// show` line for a Running row's conversation the index does not have yet
/// (no message sent — §4.6 "index contents", §8.64); or a one-line error
/// (exit 2 on a History or Archive view row, any other failure).
public enum ConversationShowOutcome: Equatable, Sendable {
    case messages
    case noConversation
    /// Exit 2: not in the index.
    case unavailable
    case failed

    /// `isRunningRow`: the selected row is a Running row.
    public static func classify(exitCode: Int32, isRunningRow: Bool) -> ConversationShowOutcome {
        switch exitCode {
        case 0: return .messages
        case 2: return isRunningRow ? .noConversation : .unavailable
        default: return .failed
        }
    }
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
    /// Whether the terminal Resume and Branch open in can be used (§4.5
    /// "Settings window" > Terminal); applied to every row's buttons.
    public private(set) var resumeTerminalAvailability: ResumeTerminalAvailability = .available
    /// The latest delivered search result; nil before the first delivery and
    /// during a full index build.
    public private(set) var history: [ConversationSummary]?
    /// Whether `history` came from a query with a valid term.
    public private(set) var historyIsFiltered = false
    public private(set) var stars: StarredList
    /// The remembered closed headings (§4.5 "collapsing sections"). Kept
    /// while searching and for headings not shown.
    public private(set) var collapsedSections: Set<ListHeading>
    public private(set) var isFullBuild = false
    /// The archived conversations (§4.6 "Archive"). Never holds a live one:
    /// every rebuild drops those (the automatic unarchive).
    public private(set) var archived: ArchivedList

    // MARK: View state

    /// The normal list or the Archive view (§4.6 "Archive view"), shared by
    /// the popover and the window and never persisted.
    public private(set) var listMode: ListMode = .normal

    public private(set) var columns: ColumnMode = .one
    /// Meaningful in one column only; normalized to `.list` in two columns.
    public private(set) var page: ListPage = .list
    /// nil after launch until the user selects a row (§4.5).
    public private(set) var selection: RowSelection?
    /// The running mark-read timer (§4.5 "operations that lower the
    /// unreviewed flag"); nil = none. A new id means the timer started (or
    /// started over): the app answers `.markReadDue(id:)` after
    /// `SelectionMarkRead.delaySeconds`.
    public private(set) var markReadTimerID: Int?
    private var nextMarkReadTimerID = 0
    /// Set when a notification click cleared the search while the shown
    /// result is still the filtered one: Running shows every row until the
    /// next search result arrives, so the clicked row is in the list at
    /// once (§4.5 "notification click").
    private var runningFilterSuspended = false
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
    /// The system click count of the latest press in a click sequence
    /// that started with a heading click; nil = none.
    private var headingClickCount: Int?
    /// The current press continues a click sequence that started with a
    /// heading click: it does nothing, whatever is under the pointer, since
    /// the first click may have moved what is there (§4.5 "collapsing
    /// sections").
    private var pressContinuesHeadingClick = false
    /// The current press started a row drag, so its click (if one
    /// arrives) is not a click (§4.5 "row drag": start).
    private var pressStartedDrag = false
    /// The row drag in progress; nil = none.
    public private(set) var cardDrag: CardDrag?
    /// The press on a row not yet decided as a drag or not (`.rowPressed`);
    /// nil once decided, released, or without one.
    private var rowPress: RowPress?
    /// The reason a row cannot be dragged, while on screen (§4.5 "row
    /// drag": rows that cannot be dragged).
    public private(set) var dragRefusal: DragRefusalNotice?
    private var nextRefusalID = 0

    private struct RowPress: Equatable, Sendable {
        let key: UnifiedRowKey
        let clickCount: Int
        let onStar: Bool
        let x: Double
        let y: Double
    }

    // MARK: Derived rows

    /// Every section's rows, closed sections included.
    public private(set) var runningRows: [UnifiedListRow] = []
    /// Starred rows, in the stars' order (no cap — §4.6 "Starred section").
    public private(set) var starredRows: [UnifiedListRow] = []
    /// The Recent rows: at most `RecentDisplayLimit.maxRows`, taken from
    /// the head of the full order (§4.6). Everything that consumes rows
    /// (blocks, ↑ / ↓, position, selection) sees only these.
    public private(set) var recentRows: [UnifiedListRow] = []
    /// How many Recent rows the cap hides (0 when none).
    public private(set) var hiddenRecentCount = 0
    /// The Archive view's rows: at most `RecentDisplayLimit.maxRows`, from
    /// the head of the archived order (§4.6 "Archive view").
    public private(set) var archivedRows: [UnifiedListRow] = []
    /// How many archived rows the cap hides (0 when none).
    public private(set) var hiddenArchivedCount = 0

    public init(
        home: String?,
        now: Int64,
        stars: StarredList = StarredList(),
        collapsedSections: Set<ListHeading> = [],
        archived: ArchivedList = ArchivedList()
    ) {
        self.home = home
        self.now = now
        self.stars = stars
        self.collapsedSections = collapsedSections
        self.archived = archived
    }

    // MARK: Derived properties

    /// Searching (§4.5 "collapsing sections", §4.6 "search scope"): the
    /// search text is valid. Running and History show open whatever is
    /// remembered, the headings do not toggle, and no row can be dragged.
    public var isSearching: Bool { isQueryValid }
    /// The search text is valid (`.queryValidityChanged`).
    public private(set) var isQueryValid = false

    /// The Archive view is shown (§4.6 "Archive view").
    public var isArchiveView: Bool { listMode == .archive }

    /// The search field's placeholder (§4.6 "search field" / "Archive
    /// view").
    public var searchPlaceholder: String {
        isArchiveView ? "Search archived" : "Search (2+ characters)"
    }

    /// Every row of a section, shown or not.
    public func rows(of section: UnifiedListSection) -> [UnifiedListRow] {
        switch section {
        case .running: return runningRows
        case .starred: return starredRows
        case .recent: return recentRows
        case .archived: return archivedRows
        }
    }

    /// Whether a section's rows are on screen (§4.5 "collapsing sections"):
    /// not when the section is closed, and Starred and Recent not while
    /// History is closed. While History stands for the Recent heading (no
    /// Starred rows), Recent shows only while both are open — the same
    /// rule. Every section of the normal list while searching. The Archive
    /// view shows its own rows only, whatever is remembered (§4.6 "Archive
    /// view").
    public func isSectionShown(_ section: UnifiedListSection) -> Bool {
        if isArchiveView { return section == .archived }
        guard let heading = ListHeading(section) else { return false }
        if isSearching { return true }
        switch section {
        case .running:
            return !collapsedSections.contains(.running)
        case .starred, .recent, .archived:
            return !collapsedSections.contains(.history) && !collapsedSections.contains(heading)
        }
    }

    /// Every row shown, in on-screen order (Running, Starred, Recent),
    /// without the rows of closed sections (§4.5 "collapsing sections":
    /// they count as not in the list). ↑ / ↓, the list's first row and the
    /// detail page's position move within this list.
    public var visibleRows: [UnifiedListRow] {
        UnifiedListSection.allCases.filter(isSectionShown).flatMap(rows(of:))
    }

    /// The History heading stands for the Recent heading: Starred has no
    /// rows and Recent has some (§4.5 "the list has three sections").
    public var historyHeadingIsRecentHeading: Bool {
        starredRows.isEmpty && !recentRows.isEmpty
    }

    /// Whether a heading is drawn open (§4.5 "collapsing sections"). While
    /// the History heading stands for the Recent heading, it is open only
    /// while both History and Recent are. Every heading while searching.
    public func isHeadingOpen(_ heading: ListHeading) -> Bool {
        if isSearching { return true }
        if heading == .history, historyHeadingIsRecentHeading {
            return !collapsedSections.contains(.history) && !collapsedSections.contains(.recent)
        }
        return !collapsedSections.contains(heading)
    }

    /// The Running mark (§4.5 "collapsing sections"): while Running is
    /// closed — not while searching, not in the Archive view — orange when
    /// a row is waiting, else the accent color when a row is unreviewed,
    /// else none (`StateDot`, the tray dot's priority).
    public var runningAttentionMark: StateDot? {
        guard !isArchiveView, !isSectionShown(.running) else { return nil }
        var hasWaiting = false
        var hasUnreviewed = false
        for row in runningRows {
            if case .status(let kind, let unreviewed) = row.symbol {
                hasWaiting = hasWaiting || kind == .waiting
                hasUnreviewed = hasUnreviewed || unreviewed
            }
        }
        return StateDot.of(hasWaiting: hasWaiting, hasUnreviewed: hasUnreviewed)
    }

    /// The Running mark is shown (in either color).
    public var showsRunningAttentionMark: Bool { runningAttentionMark != nil }

    /// The Recent heading's count (§4.5 "row counts", §4.6 "Recent
    /// section"): the row count, or `first 100` while the cap leaves rows
    /// out.
    public var recentCountText: String {
        hiddenRecentCount > 0 ? "first \(RecentDisplayLimit.maxRows)" : "\(recentRows.count)"
    }

    /// The list page, top to bottom (§4.5 "the list has three sections" /
    /// "collapsing sections" / "row drag", §4.6 "search scope"): the
    /// headings shown, the frames of rows, and the `N more` line. A section
    /// without rows is not shown, heading included; a closed heading shows
    /// alone.
    public var blocks: [ListBlock] {
        if isArchiveView { return archiveBlocks }
        var blocks: [ListBlock] = []
        let drag = cardDrag
        if isSearching {
            // §4.5 "collapsing sections": the bands keep their shape while
            // searching, without the chevron and the Running mark.
            if !runningRows.isEmpty {
                blocks.append(.heading(ListHeadingModel(
                    heading: .running, style: .band, countText: "\(runningRows.count)", isCollapsible: false)))
                blocks.append(.frame(ListFrameModel(id: .running, rows: runningRows)))
            }
            let history = starredRows + recentRows
            if !history.isEmpty {
                // §4.6 "search scope": one frame, Starred rows first; the
                // count is both sections' rows, `first` while the cap
                // leaves Recent rows out.
                let count = hiddenRecentCount > 0 ? "first \(history.count)" : "\(history.count)"
                blocks.append(.heading(ListHeadingModel(
                    heading: .history, style: .band, countText: count, isCollapsible: false)))
                blocks.append(.frame(ListFrameModel(id: .history, rows: history)))
                if let more = hiddenRecentText { blocks.append(.moreLine(more)) }
            }
            return blocks
        }
        if !runningRows.isEmpty {
            let open = isHeadingOpen(.running)
            blocks.append(.heading(ListHeadingModel(
                heading: .running, style: .band, countText: "\(runningRows.count)", isOpen: open,
                attentionMark: runningAttentionMark)))
            if open { blocks.append(.frame(ListFrameModel(id: .running, rows: runningRows))) }
        }
        guard !starredRows.isEmpty || !recentRows.isEmpty else { return blocks }
        let historyOpen = isHeadingOpen(.history)
        if historyHeadingIsRecentHeading {
            blocks.append(.heading(ListHeadingModel(
                heading: .history, style: .band, countText: recentCountText, isOpen: historyOpen)))
            if historyOpen {
                blocks.append(.frame(ListFrameModel(id: .recent, rows: recentRows)))
                if let more = hiddenRecentText { blocks.append(.moreLine(more)) }
            }
            return blocks
        }
        blocks.append(.heading(ListHeadingModel(heading: .history, style: .band, countText: nil, isOpen: historyOpen)))
        guard historyOpen else { return blocks }
        let starredOpen = isHeadingOpen(.starred)
        blocks.append(.heading(ListHeadingModel(
            heading: .starred, style: .sub, countText: "\(starredRows.count)", isOpen: starredOpen,
            hint: drag?.section == .recent ? ListHeadingModel.starHint : nil,
            isDropTarget: drag?.indicator == .heading(.starred))))
        if starredOpen {
            var lineShown = false
            if case .line = drag?.indicator { lineShown = true }
            blocks.append(.frame(ListFrameModel(
                id: .starred, rows: starredRows, isEmphasized: drag?.section == .recent && lineShown)))
        }
        if !recentRows.isEmpty {
            let recentOpen = isHeadingOpen(.recent)
            blocks.append(.heading(ListHeadingModel(
                heading: .recent, style: .sub, countText: recentCountText, isOpen: recentOpen,
                hint: drag?.section == .starred ? ListHeadingModel.unstarHint : nil,
                isDropTarget: drag?.indicator == .heading(.recent))))
            if recentOpen {
                blocks.append(.frame(ListFrameModel(id: .recent, rows: recentRows)))
                if let more = hiddenRecentText { blocks.append(.moreLine(more)) }
            }
        }
        return blocks
    }

    /// The Archive view, top to bottom (§4.6 "Archive view"): the band, then
    /// the archived rows in one frame and the `N more` line below it — or,
    /// with no row matching the search, one line under the band.
    /// Before the first search result (and during a full index build) the
    /// band has no count and nothing is under it, as the normal list shows
    /// nothing while it loads.
    private var archiveBlocks: [ListBlock] {
        let countText: String?
        if history == nil {
            countText = nil
        } else if hiddenArchivedCount > 0 {
            countText = "first \(RecentDisplayLimit.maxRows)"
        } else {
            countText = "\(archivedRows.count)"
        }
        var blocks: [ListBlock] = [.archiveHeading(ArchiveHeadingModel(countText: countText))]
        if !archivedRows.isEmpty {
            blocks.append(.frame(ListFrameModel(id: .archived, rows: archivedRows)))
            if let more = hiddenArchivedText { blocks.append(.moreLine(more)) }
        } else if !isFullBuild, history != nil, historyIsFiltered {
            // Only a filtered result can leave the Archive view without rows:
            // a browse result prunes every archived conversation it does not
            // hold, and a live one is unarchived.
            blocks.append(.emptyLine("No matching conversations"))
        }
        return blocks
    }

    /// The headings shown, top to bottom (`blocks`).
    public var headings: [ListHeadingModel] {
        blocks.compactMap { block in
            if case .heading(let model) = block { return model }
            return nil
        }
    }

    /// A row drawn faded during a row drag (§4.5 "row drag"): Running and
    /// Recent rows — they are never a drop position — except the dragged
    /// row itself.
    public func isRowDimmed(_ row: UnifiedListRow) -> Bool {
        guard let drag = cardDrag else { return false }
        return row.id != drag.key && row.section != .starred
    }

    public var isAwaitingRefetch: Bool { awaitingRefetchRow != nil }

    /// The selected row's primary button is the disabled Jump of a row the
    /// app cannot jump to, so Enter and a double-click show its
    /// conversation instead (§4.5 "row double-click", "key operations").
    /// Assumption: not while awaiting the History refetch — the session has
    /// ended and every button is disabled meanwhile (§4.5 "row selection").
    public var selectedRowShowsConversation: Bool {
        guard awaitingRefetchRow == nil, let row = selectedRow else { return false }
        return row.primaryButton.isUndrivableJump
    }

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

    /// The empty-state line (§4.6): only when every section is empty (a
    /// closed section's rows count as rows), never
    /// during a full index build, and never before a search result has been
    /// delivered (`history` is nil until the first delivery after launch).
    /// "Searching" means the shown result came from a query with a valid
    /// term (assumption: a query with only 1-character words shows the
    /// browse list, so it reads as empty).
    /// Archived conversations do not count (§4.6 "empty state"). nil in the
    /// Archive view, whose line sits under its band (`blocks`).
    public var emptyStateText: String? {
        guard !isArchiveView, !isFullBuild, history != nil, runningRows.isEmpty, starredRows.isEmpty,
              recentRows.isEmpty
        else { return nil }
        return historyIsFiltered ? "No matching conversations" : "No conversations"
    }

    /// The line below the Recent rows' frame when the cap hides rows (§4.6
    /// "Recent section"); nil when nothing is hidden, and while the Recent
    /// rows are not shown (§4.5 "collapsing sections"). Not a row: it is
    /// never selectable.
    public var hiddenRecentText: String? {
        guard hiddenRecentCount > 0, isSectionShown(.recent) else { return nil }
        return hiddenRowsText(hiddenRecentCount)
    }

    /// The line below the Archive view's frame when the cap hides rows (the
    /// Recent rule — §4.6 "Archive view"); nil outside the Archive view.
    public var hiddenArchivedText: String? {
        guard hiddenArchivedCount > 0, isArchiveView else { return nil }
        return hiddenRowsText(hiddenArchivedCount)
    }

    private func hiddenRowsText(_ count: Int) -> String {
        let hint = historyIsFiltered ? "refine your search" : "search to narrow down"
        return "\(count) more \u{2014} \(hint)"
    }

    /// The selected row's look (§4.5 "row selection"): accent while the
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
            primaryShowsConversation: selectedRowShowsConversation,
            branchEnabled: row?.branchButton.isEnabled ?? false,
            conversationPaneVisible: isConversationPaneVisible,
            isPopover: isPopover,
            hasMarkedText: hasMarkedText,
            cardDragging: cardDrag != nil,
            isArchiveView: isArchiveView
        )
    }

    /// Whether a press on `key` may start a row drag once it moves far
    /// enough (§4.5 "row drag": start): a Starred or Recent row on screen,
    /// not on its star, not while searching, a Recent row only while the
    /// Starred section is shown, and not the second (or later) press of a
    /// double-click on that row. `clickCount` is the system's click count
    /// of the press.
    public func canStartCardDrag(key: UnifiedRowKey, clickCount: Int, onStar: Bool) -> Bool {
        guard !isArchiveView, !onStar, cardDrag == nil, dragRefusal(key: key, onStar: onStar) == nil,
              let row = visibleRows.first(where: { $0.id == key }), !row.sessionID.isEmpty else { return false }
        return !isRepeatPress(on: key, clickCount: clickCount)
    }

    /// The press is the second (or later) press of a double-click on `key`.
    private func isRepeatPress(on key: UnifiedRowKey, clickCount: Int) -> Bool {
        guard clickCount > 1, let sequence = clickSequence else { return false }
        return sequence.row == key
    }

    /// Why a press on `key` cannot start a drag (§4.5 "row drag": rows that
    /// cannot be dragged); nil on the star or the more button, on a row not
    /// on screen, on the Archive view's rows (they cannot be dragged and no
    /// reason is shown — §4.6 "Archive view"), and on a row that can be
    /// dragged. When several apply, the first of: a Running row, searching,
    /// a Recent row while Starred has no rows.
    public func dragRefusal(key: UnifiedRowKey, onStar: Bool) -> RowDragRefusal? {
        guard !isArchiveView, !onStar, let row = visibleRows.first(where: { $0.id == key }) else { return nil }
        if row.section == .running { return .running }
        if isSearching { return .searching }
        if row.section == .recent, starredRows.isEmpty { return .noStarredSection }
        return nil
    }

    // MARK: Events

    /// Apply one event; returns the effects to perform, in order.
    @discardableResult
    public mutating func handle(_ event: UnifiedListEvent) -> [UnifiedListEffect] {
        let before = Observation(self)
        let archivedBefore = archived
        let starsBefore = stars
        var effects: [UnifiedListEffect] = []
        var movedSelection = false
        var markReadTrigger = SelectionMarkRead.Trigger.other
        /// The event operated on the selected row and kept it selected
        /// (beyond what `markReadTrigger == .userSelection` covers).
        var operatedOnSelectedRow = false

        switch event {
        case .agentsUpdated(let newAgents):
            applyAgents(newAgents, effects: &effects)

        case .historyDelivered(let results, let isFiltered):
            history = results
            historyIsFiltered = isFiltered
            runningFilterSuspended = false
            if !isFiltered, let pruned = stars.pruned(browseResults: results) {
                stars = pruned
                effects.append(.persistStars(stars.sessionIDs))
            }
            if !isFiltered, let pruned = archived.pruned(browseResults: results) {
                archived = pruned
            }
            rebuild()
            if let pending = awaitingRefetchRow {
                // The refetch completed: keep the selection on the Starred
                // or Recent row with the same session_id, else deselect —
                // also when that row is in a closed section (§4.5).
                awaitingRefetchRow = nil
                let key = UnifiedRowKey.conversation(sessionID: pending.sessionID)
                if visibleRows.contains(where: { $0.id == key }) {
                    selection = RowSelection(key: key, sessionID: pending.sessionID)
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

        case .resumeTerminalAvailabilityChanged(let availability):
            resumeTerminalAvailability = availability
            rebuild()

        case .rowClicked(let key):
            // §4.5 "row click": select; the selected row deselects only when
            // it was shown in accent at the press — a gray selected row keeps
            // its selection and only gains focus. The detail page opens with
            // View or → (§4.5 "opening the detail page").
            let press = pointerPress
            pointerPress = nil
            if pressContinuesHeadingClick {
                pressContinuesHeadingClick = false
                clickSequence = nil
                break
            }
            headingClickCount = nil
            if pressStartedDrag {
                // §4.5 "row drag": the press that started a drag is no
                // click, and no click sequence continues from it.
                pressStartedDrag = false
                clickSequence = nil
                break
            }
            let wasActive = press?.selectionActive ?? isSelectionActive
            guard let row = visibleRows.first(where: { $0.id == key }) else {
                clickSequence = nil
                break
            }
            switch clickOrdinal(on: key, clickCount: press?.clickCount ?? 1) {
            case 1:
                if selection?.key == key {
                    // §4.5: a click on the selected row that keeps it (gray)
                    // counts as selecting it again; the accent row's click
                    // deselects it, so the mark-read timer stops.
                    markReadTrigger = wasActive ? .deselectClick : .userSelection
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
                    markReadTrigger = .userSelection
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
                markReadTrigger = .userSelection
                effects.append(.focusList)
                if press?.commandKey != true, selectedRowShowsConversation {
                    // §4.5 "row double-click": a row the app cannot jump to
                    // shows its conversation instead of the disabled Jump.
                    showSelectedConversation(effects: &effects)
                    break
                }
                let button = press?.commandKey == true ? selectedRow?.branchButton : selectedRow?.primaryButton
                if let invocation = button?.invocation {
                    effects.append(.invoke(invocation))
                }
            default:
                // Clicks 3+ of the sequence: never run Jump / Resume again.
                if selection?.key != key {
                    select(row)
                }
                markReadTrigger = .userSelection
                effects.append(.focusList)
            }

        case .moveUp, .moveDown:
            movedSelection = move(up: event == .moveUp)
            if movedSelection { markReadTrigger = .userSelection }

        case .previousConversation, .nextConversation:
            // The same row step as ↑ / ↓; only offered on the one-column
            // detail page (§4.5 "key operations").
            movedSelection = move(up: event == .previousConversation)
            if movedSelection { markReadTrigger = .userSelection }

        case .enterFromSearchField:
            if selection == nil {
                guard let first = visibleRows.first else { break }
                select(first)
                movedSelection = true
                markReadTrigger = .userSelection
            }
            effects.append(.focusList)

        case .selectFirstRow:
            guard selection == nil, let first = visibleRows.first else { break }
            select(first)
            movedSelection = true
            markReadTrigger = .userSelection

        case .openDetail:
            guard columns == .one, page == .list, selection != nil else { break }
            page = .detail

        case .back:
            if columns == .one {
                page = .list
            }

        case .showConversation:
            if selectedRowShowsConversation {
                showSelectedConversation(effects: &effects)
                // §4.5: Enter on a row that cannot be jumped to counts as
                // selecting it again, on every page.
                markReadTrigger = .userSelection
            }

        case .focusSearch:
            if columns == .one {
                page = .list
            }
            effects.append(.focusSearchField)

        case .openedByHotKey:
            // §4.5 "global hotkey" / §8.66: the selection never changes.
            if columns == .one && page == .detail {
                effects.append(.focusConversationPane)
            } else if selection != nil || !visibleRows.isEmpty {
                effects.append(.focusList)
            } else {
                effects.append(.focusSearchField)
            }

        case .searchFieldFocusChanged(let focused):
            isSearchFieldFocused = focused

        case .surfaceKeyChanged(let key):
            isSurfaceKey = key
            if !key {
                // §4.5 "row drag": cancelled when the window stops being
                // key, and a press not yet decided starts nothing.
                cardDrag = nil
                rowPress = nil
            }

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
            pressStartedDrag = false
            pressContinuesHeadingClick = clickCount > 1 && headingClickCount == clickCount - 1
            headingClickCount = pressContinuesHeadingClick ? clickCount : nil
            // §4.5 "row drag": the next press clears the reason a row
            // cannot be dragged.
            dragRefusal = nil

        case .deferredDeselectDue(let id):
            guard let pending = pendingDeselect, pending.id == id else { break }
            pendingDeselect = nil
            if selection?.key == pending.key {
                deselect()
            }

        case .surfaceHidden:
            markReadTrigger = .surfaceClosed
            // §4.6 "Archive view": not remembered — closing the surface
            // (switching the form included) returns to the normal list.
            leaveArchiveView(effects: &effects)
            pendingDeselect = nil
            pointerPress = nil
            clickSequence = nil
            headingClickCount = nil
            pressContinuesHeadingClick = false
            pressStartedDrag = false
            cardDrag = nil
            rowPress = nil
            dragRefusal = nil

        case .columnsChanged(let newColumns):
            guard newColumns != columns else { break }
            columns = newColumns
            // one(detail) -> two: same selection, shown in the right column.
            // two -> one: the list page, selection kept (§4.5).
            page = .list

        case .starToggled(let sessionID):
            // A star click that continues a click sequence begun on a
            // heading does nothing: the toggle may have moved this star under
            // the pointer (§4.5 "collapsing sections"). The sequence keeps
            // counting, so later clicks of it do nothing either.
            if pressContinuesHeadingClick {
                pressContinuesHeadingClick = false
                pointerPress = nil
                break
            }
            guard !isArchiveView else { break }
            // §4.6 "stars": shown at once, without a new search; a new star
            // goes to the end of Starred. A row that moves into a closed
            // section deselects (§4.5 "row selection").
            if !sessionID.isEmpty, selection?.sessionID == sessionID {
                operatedOnSelectedRow = true
            }
            stars = stars.toggled(sessionID, results: history ?? [])
            effects.append(.persistStars(stars.sessionIDs))
            rebuild()
            reconcileSelection()

        case .headingClicked(let heading):
            let press = pointerPress
            pointerPress = nil
            clickSequence = nil
            // §4.5 "collapsing sections": a click on a heading of a window
            // that is not key makes it key, also when nothing toggles.
            effects.append(.makeSurfaceKey)
            let continues = pressContinuesHeadingClick
            pressContinuesHeadingClick = false
            headingClickCount = press?.clickCount ?? 1
            // Only the first click of consecutive clicks toggles, and
            // nothing toggles while searching (Running and History show
            // open). The Archive view has no heading that toggles.
            guard !continues, !isSearching, !isArchiveView else { break }
            if heading == .history, historyHeadingIsRecentHeading {
                // The History heading stands for the Recent heading: open
                // closes History; closed opens both, so the click always
                // shows the rows (§4.5, §8.60).
                if isHeadingOpen(.history) {
                    collapsedSections.insert(.history)
                } else {
                    collapsedSections.remove(.history)
                    collapsedSections.remove(.recent)
                }
            } else if collapsedSections.contains(heading) {
                collapsedSections.remove(heading)
            } else {
                collapsedSections.insert(heading)
            }
            if !isSectionShown(.running), awaitingRefetchRow != nil {
                // The selected Running row that just ended belongs to the
                // section being closed.
                deselect()
            }
            effects.append(.persistCollapsedSections(collapsedSections))
            reconcileSelection()

        case .rowPressed(let key, let clickCount, let onStar, let x, let y):
            rowPress = RowPress(key: key, clickCount: clickCount, onStar: onStar, x: x, y: y)
            // §4.5 "row double-click" / "row drag": the deselect of a
            // Starred or Recent row never runs while the button is down.
            if !onStar, clickCount > 1, let pending = pendingDeselect, pending.key == key,
               visibleRows.first(where: { $0.id == key })?.section != .running {
                pendingDeselect = nil
            }

        case .rowPressDragged(let x, let y):
            guard let press = rowPress,
                  CardDragMetrics.hasMovedFarEnough(fromX: press.x, fromY: press.y, toX: x, toY: y) else { break }
            // One decision per press; a press that continues a heading
            // click does nothing (§4.5 "collapsing sections").
            rowPress = nil
            guard !pressContinuesHeadingClick else { break }
            if canStartCardDrag(key: press.key, clickCount: press.clickCount, onStar: press.onStar),
               let row = visibleRows.first(where: { $0.id == press.key }) {
                pressStartedDrag = true
                // §4.5 "row drag": no deselect from this press, and what a
                // click does at the press: select an unselected row, focus
                // the list.
                pendingDeselect = nil
                if selection?.key != press.key {
                    select(row)
                }
                // Only Starred and Recent rows start a drag, so this
                // selection has nothing to lower (§4.5).
                markReadTrigger = .userSelection
                effects.append(.focusList)
                cardDrag = CardDrag(key: press.key, sessionID: row.sessionID, section: row.section)
            } else if !isRepeatPress(on: press.key, clickCount: press.clickCount),
                      let refusal = dragRefusal(key: press.key, onStar: press.onStar) {
                // The second (or later) press of a double-click shows no
                // reason (§4.5 "row drag").
                nextRefusalID += 1
                dragRefusal = DragRefusalNotice(id: nextRefusalID, refusal: refusal)
                effects.append(.scheduleDragRefusalDismiss(
                    id: nextRefusalID, afterSeconds: CardDragMetrics.refusalSeconds))
            }

        case .rowPressReleased:
            rowPress = nil

        case .dragRefusalDismissDue(let id):
            if dragRefusal?.id == id {
                dragRefusal = nil
            }

        case .cardDragMoved(let hit):
            guard var drag = cardDrag else { break }
            drag.lastHit = hit
            cardDrag = drag

        case .cardDragEnded:
            guard let drag = cardDrag else { break }
            cardDrag = nil
            if let target = drag.target {
                drop(drag, on: target, effects: &effects)
            }

        case .cardDragCancelled:
            cardDrag = nil

        case .queryValidityChanged(let valid):
            guard valid != isQueryValid else { break }
            isQueryValid = valid
            // Searching ends: a selected row in a closed section deselects
            // (§4.5 "collapsing sections").
            reconcileSelection()

        case .moreButtonClicked(let key):
            // Like the star: a click continuing a click sequence begun on a
            // heading does nothing (§4.5 "collapsing sections").
            if pressContinuesHeadingClick {
                pressContinuesHeadingClick = false
                pointerPress = nil
                break
            }
            // §4.6 "Archive": a surface that is not key becomes key, and the
            // same click opens the menu.
            effects.append(.makeSurfaceKey)
            if let row = visibleRows.first(where: { $0.id == key }), !row.menuItems.isEmpty {
                effects.append(.showRowMenu(key))
                if selection?.key == key {
                    operatedOnSelectedRow = true
                }
            }

        case .archiveRequested(let sessionID):
            // A live conversation is never archived (§4.6 "Archive"): a
            // choice from a menu opened before it became live changes
            // nothing — not even its star.
            guard !sessionID.isEmpty,
                  !UnifiedListBuilder.liveSessionIDs(agents: agents, results: history).contains(sessionID)
            else { break }
            // §4.6 "Archive": off the normal list at once (no new search);
            // a starred conversation loses its star.
            archived = archived.archiving(sessionID)
            if let unstarred = stars.removing(sessionID, results: history ?? []) {
                stars = unstarred
                effects.append(.persistStars(stars.sessionIDs))
            }
            rebuild()
            reconcileSelection()

        case .unarchiveRequested(let sessionID):
            // §4.6 "Archive view": the conversation goes back to Recent (its
            // star does not come back).
            archived = archived.unarchiving(sessionID)
            rebuild()
            reconcileSelection()

        case .archivedMenuItemChosen:
            if isArchiveView {
                leaveArchiveView(effects: &effects)
            } else {
                enterArchiveView(effects: &effects)
            }

        case .archiveHeadingClicked:
            // The band acts like a heading for the click sequence: only the
            // first click of consecutive clicks returns to the normal list,
            // since that click changes what is under the pointer (§4.5
            // "collapsing sections").
            let press = pointerPress
            pointerPress = nil
            clickSequence = nil
            effects.append(.makeSurfaceKey)
            let continues = pressContinuesHeadingClick
            pressContinuesHeadingClick = false
            headingClickCount = press?.clickCount ?? 1
            guard !continues else { break }
            leaveArchiveView(effects: &effects)

        case .leaveArchiveView:
            leaveArchiveView(effects: &effects)

        case .markReadDue(let id):
            guard id == markReadTimerID else { break }
            markReadTimerID = nil
            if let target = SelectionMarkRead.targetToMarkRead(
                selection: selection?.key, awaitingRefetch: awaitingRefetchRow != nil, agents: agents) {
                effects.append(.markRead(target: target))
            }

        case .targetRekeyed(let from, let to):
            markReadTrigger = .rekey
            applyRekey(from: from, to: to)

        case .notificationClicked(let target, let hasSearchText):
            if openRowForNotification(target: target, hasSearchText: hasSearchText, effects: &effects) {
                movedSelection = true
                markReadTrigger = .userSelection
            }

        }

        // §4.6 "Archive view": once no conversation is archived (the last
        // Unarchive, the automatic unarchive, pruning), the normal list is
        // back. The selected row left the Archive view before this, so it
        // is already deselected.
        if isArchiveView, archived.isEmpty {
            leaveArchiveView(effects: &effects)
        }
        if archived != archivedBefore {
            effects.append(.persistArchive(archived.sessionIDs))
        }
        // The rebuild can drop a star (an archived conversation never keeps
        // one): persist the stars as they ended up.
        if stars != starsBefore, !effects.contains(.persistStars(stars.sessionIDs)) {
            effects.append(.persistStars(stars.sessionIDs))
        }

        updateCardDrag()

        let after = Observation(self)
        // A pending deselect belongs to the selection and page the click
        // saw: any other change of either cancels it (another row clicked,
        // ↑ / ↓, the row left the list, the detail page opened). A `rekey`
        // renames the pending deselect's row along with the selection.
        if pendingDeselect != nil, markReadTrigger != .rekey,
           after.selectionKey != before.selectionKey || after.page != before.page {
            pendingDeselect = nil
        }
        // An operation on the selected row that keeps it selected cancels
        // it too: the user acted on the row after the click, so the click's
        // deselect would undo that (selecting it again — a gray click,
        // Enter showing the conversation, a notification click — its menu,
        // its star).
        if markReadTrigger == .userSelection || operatedOnSelectedRow {
            pendingDeselect = nil
        }
        switch SelectionMarkRead.decide(
            trigger: markReadTrigger, before: before.selectionKey, after: after.selectionKey) {
        case .start:
            nextMarkReadTimerID += 1
            markReadTimerID = nextMarkReadTimerID
        case .cancel:
            markReadTimerID = nil
        case .keep:
            break
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
        case .cancelCardDrag: return handle(.cardDragCancelled)
        case .enterFromSearchField: return handle(.enterFromSearchField)
        case .selectFirstRow: return handle(.selectFirstRow)
        case .openDetail: return handle(.openDetail)
        case .back: return handle(.back)
        case .focusSearch: return handle(.focusSearch)
        case .showConversation: return handle(.showConversation)
        case .primary:
            return runOnSelectedRow(selectedRow?.primaryButton.invocation)
        case .branch:
            return runOnSelectedRow(selectedRow?.branchButton.invocation)
        case .nextMatch: return [.nextMatch]
        case .previousMatch: return [.previousMatch]
        case .closePopover: return [.closePopover]
        case .leaveArchiveView: return handle(.leaveArchiveView)
        case .refresh: return [.refresh]
        case .increaseTextSize: return [.increaseTextSize]
        case .decreaseTextSize: return [.decreaseTextSize]
        case .resetTextSize: return [.resetTextSize]
        }
    }

    // MARK: Internals

    /// A button of the selected row run by key (Enter / ⌘Enter): it acts
    /// on the selected row and keeps it selected, so a pending deselect of
    /// that row is cancelled. A disabled button runs nothing and changes
    /// nothing.
    private mutating func runOnSelectedRow(_ invocation: RowInvocation?) -> [UnifiedListEffect] {
        guard let invocation else { return [] }
        pendingDeselect = nil
        return [.invoke(invocation)]
    }

    /// A `rekey` (§4.5 "desktop notifications" / "row selection"): the
    /// entry keeps every attribute under its new target, so the agent table
    /// that follows has the same rows; the selection, a pending deselect
    /// and a click sequence on the row move with it.
    private mutating func applyRekey(from: String, to: String) {
        guard from != to else { return }
        agents = AgentRemovalHandling.agentsAfterRekey(agents, from: from, to: to)
        let old = UnifiedRowKey.running(target: from)
        let new = UnifiedRowKey.running(target: to)
        if let current = selection, current.key == old {
            selection = RowSelection(key: new, sessionID: current.sessionID)
        }
        if let pending = pendingDeselect, pending.key == old {
            pendingDeselect = PendingDeselect(id: pending.id, key: new)
        }
        if let sequence = clickSequence, sequence.row == old {
            clickSequence = ClickSequence(row: new, baseCount: sequence.baseCount)
        }
        rebuild()
        if awaitingRefetchRow == nil {
            reconcileSelection()
        }
    }

    /// The list part of a notification click on a session the app cannot
    /// jump to (§4.5 "notification click"), in the spec's order. Returns
    /// whether the row is selected. False when the entry is gone or unknown
    /// (nothing changed), or when its row is still not in the list after
    /// the steps above (the Archive view left, Running opened, the search
    /// cleared, the detail page of another conversation left — those
    /// changes stay, but nothing is selected).
    private mutating func openRowForNotification(
        target: String, hasSearchText: Bool, effects: inout [UnifiedListEffect]
    ) -> Bool {
        guard agents.contains(where: { $0.target == target && $0.status != .unknown }) else { return false }
        leaveArchiveView(effects: &effects)
        if collapsedSections.contains(.running) {
            collapsedSections.remove(.running)
            effects.append(.persistCollapsedSections(collapsedSections))
        }
        if hasSearchText {
            effects.append(.clearSearchText)
            isQueryValid = false
            // The filtered result stays until the browse result arrives;
            // Running must not hide the row meanwhile.
            if historyIsFiltered { runningFilterSuspended = true }
            rebuild()
        }
        let key = UnifiedRowKey.running(target: target)
        if columns == .one, page == .detail, selection?.key != key {
            page = .list
        }
        guard let row = visibleRows.first(where: { $0.id == key }) else { return false }
        if selection?.key != key {
            select(row)
        }
        effects.append(.focusList)
        return true
    }

    /// Show the selected row's conversation in place of its disabled Jump
    /// (§4.5 "row double-click"): open the detail page on the one-column
    /// list page (like View), move focus to the conversation pane in two
    /// columns, and do nothing on the one-column detail page (the
    /// conversation is already on screen).
    private mutating func showSelectedConversation(effects: inout [UnifiedListEffect]) {
        switch columns {
        case .one:
            if page == .list {
                page = .detail
            }
        case .two:
            effects.append(.focusConversationPane)
        }
    }

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

    /// Recompute every section's rows. First the automatic unarchive (§4.6
    /// "Archive"): a live conversation is never archived, so whenever the
    /// agents, the search result or the archived list change, a live one
    /// leaves the archived list; then an archived conversation's star goes
    /// (`handle` persists both changes).
    private mutating func rebuild() {
        let live = UnifiedListBuilder.liveSessionIDs(agents: agents, results: history)
        if archived.sessionIDs.contains(where: live.contains) {
            archived = archived.removing(live)
        }
        // An archived conversation has no star (§4.6 "Archive"); stored
        // values holding both lose the star, so an Unarchive never brings a
        // hidden star back.
        for sessionID in archived.sessionIDs where stars.contains(sessionID) {
            if let unstarred = stars.removing(sessionID, results: history ?? []) {
                stars = unstarred
            }
        }
        let availability = resumeTerminalAvailability
        runningRows = UnifiedListBuilder.runningRows(
            agents: agents, results: history, isFiltered: historyIsFiltered && !runningFilterSuspended,
            now: now, home: home
        ).map { $0.applying(availability) }
        let conversations = UnifiedListBuilder.conversationRows(
            results: history, agents: agents, stars: stars, archived: archived, now: now, home: home
        )
        starredRows = conversations.starred.map { $0.applying(availability) }
        recentRows = Array(conversations.recent.prefix(RecentDisplayLimit.maxRows)).map { $0.applying(availability) }
        hiddenRecentCount = conversations.recent.count - recentRows.count
        let archivedAll = UnifiedListBuilder.archivedRows(
            results: history, agents: agents, archived: archived, now: now, home: home
        )
        archivedRows = Array(archivedAll.prefix(RecentDisplayLimit.maxRows)).map { $0.applying(availability) }
        hiddenArchivedCount = archivedAll.count - archivedRows.count
    }

    /// Show the Archive view (§4.6 "Archive view"; the ⌄ menu's item is
    /// disabled while nothing is archived). A selected row that is not in
    /// it deselects; the view starts at its top.
    private mutating func enterArchiveView(effects: inout [UnifiedListEffect]) {
        guard !isArchiveView, !archived.isEmpty else { return }
        listMode = .archive
        cardDrag = nil
        rowPress = nil
        dragRefusal = nil
        deselectUnlessShown()
        effects.append(.scrollListToTop)
    }

    /// Back to the normal list (§4.6 "Archive view"): a selected row that
    /// is not in it deselects (one column: the list page), and the normal
    /// list's scroll position comes back.
    private mutating func leaveArchiveView(effects: inout [UnifiedListEffect]) {
        guard isArchiveView else { return }
        listMode = .normal
        deselectUnlessShown()
        effects.append(.restoreListScroll)
    }

    /// After switching between the normal list and the Archive view: the
    /// selection stays only on a row shown in the list now (§4.6 "Archive
    /// view": selection after switching).
    private mutating func deselectUnlessShown() {
        guard let current = selection else { return }
        if awaitingRefetchRow != nil || !visibleRows.contains(where: { $0.id == current.key }) {
            deselect()
        }
    }

    /// After every event: a drag ends when searching starts or when the
    /// dragged row is no longer among the shown rows of the section it
    /// started in (§4.5 "row drag": cancel); otherwise its target is worked
    /// out again from the pointer, since the list may have changed. A held
    /// target is one indicator, so its line and its drop position cannot
    /// part when rows come or go next to the line.
    private mutating func updateCardDrag() {
        guard var drag = cardDrag else { return }
        let stillShown = isSectionShown(drag.section) && rows(of: drag.section).contains { $0.id == drag.key }
        guard !isSearching, stillShown else {
            cardDrag = nil
            return
        }
        drag.indicator = dropResolver(source: drag.section).resolve(drag.lastHit, previous: drag.indicator)
        cardDrag = drag
    }

    /// The drop table's inputs for the list as shown (§4.5 "row drag").
    func dropResolver(source: UnifiedListSection) -> CardDropResolver {
        let historyOpen = !isSearching && !collapsedSections.contains(.history)
        let starredHeadingShown = historyOpen && !starredRows.isEmpty
        var rowSections: [UnifiedRowKey: UnifiedListSection] = [:]
        for row in visibleRows {
            rowSections[row.id] = row.section
        }
        return CardDropResolver(
            source: source,
            shownStarred: isSectionShown(.starred) ? starredRows.map(\.sessionID) : [],
            starredHeadingShown: starredHeadingShown,
            recentHeadingShown: starredHeadingShown && !recentRows.isEmpty,
            rowSections: rowSections)
    }

    /// §4.5 "row drag": drop. A move that leaves the order as it is changes
    /// (and saves) nothing. The moved row keeps its selection unless it
    /// lands in a closed section.
    private mutating func drop(_ drag: CardDrag, on target: CardDropTarget, effects: inout [UnifiedListEffect]) {
        let results = history ?? []
        let changed: StarredList?
        switch target {
        case .starred(let before):
            changed = stars.moving(drag.sessionID, before: before, shown: starredRows.map(\.sessionID), results: results)
        case .unstar:
            changed = drag.section == .starred ? stars.removing(drag.sessionID, results: results) : nil
        }
        guard let changed else { return }
        stars = changed
        effects.append(.persistStars(stars.sessionIDs))
        rebuild()
        reconcileSelection()
    }

    /// §4.5: a selected row that is no longer in the list deselects (no other
    /// row gets selected) — a row in a closed section counts as not in the
    /// list. A Running row keyed by target picks up a changed session_id. A
    /// selected Starred or Recent row whose conversation moved to Running
    /// (e.g. after Resume) keeps the selection — and the shown page — on the
    /// Running row with the same session_id, while Running is open.
    private mutating func reconcileSelection() {
        guard awaitingRefetchRow == nil, let current = selection else { return }
        if let row = visibleRows.first(where: { $0.id == current.key }) {
            if row.sessionID != current.sessionID {
                selection = RowSelection(key: current.key, sessionID: row.sessionID)
            }
        } else if case .conversation = current.key,
                  !current.sessionID.isEmpty,
                  isSectionShown(.running),
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
