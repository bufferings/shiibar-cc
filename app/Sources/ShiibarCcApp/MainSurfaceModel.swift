// The one model behind the popover and the window (DESIGN.md §4.5 "the
// popover and the window share one state", §4.6, §8.49). It holds the single
// `UnifiedListState` (Core), feeds it events (daemon updates, search
// results, clock ticks, user input), executes the effects it returns, and
// runs the subprocess pipelines around it: `conversations index --json` on
// open, the debounced `conversations search`, `conversations show` for the
// conversation pane, the row verbs (focus / resume / resume --fork), and
// Refresh (the search plus `shiibar-cc reconcile` — §4.6).
// Both surfaces' views render from this object only; decisions live in Core.
//
// Every outward action is injectable (subprocess launchers, the row-verb
// runner, UserDefaults, the clock) so tests drive it with spies and never
// touch the real CLI, state dir, or defaults.

import AppKit
import Combine
import ConversationsWebPaneKit
import Foundation
import os
import ShiibarCcCore

private let surfaceLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "cc.shiibar.menubar",
    category: "conversations"
)

/// Which surface shows the shared layout.
enum MainSurface: Equatable {
    case popover
    case window
}

/// One warning row of the fixed footer (§4.5 "making failures visible").
enum SurfaceWarning: Equatable, Hashable {
    case disconnected
    case notificationsDenied
    case automationPermission

    var text: String {
        switch self {
        case .disconnected: return "Disconnected from daemon \u{2014} reconnecting\u{2026}"
        case .notificationsDenied: return "Notifications permission denied"
        case .automationPermission: return "Automation permission needed (run \"shiibar-cc doctor\")"
        }
    }
}

/// The subprocess launchers the model uses (production: `ConversationsRunner`).
struct ConversationsLaunchers {
    typealias OneShot = (
        _ arguments: [String],
        _ helpersDirectory: URL?,
        _ completion: @escaping @MainActor (CLIRunResult) -> Void
    ) -> ConversationsProcess?
    typealias Streaming = (
        _ arguments: [String],
        _ helpersDirectory: URL?,
        _ onLine: @escaping @MainActor (String) -> Void,
        _ completion: @escaping @MainActor (Int32) -> Void
    ) -> ConversationsProcess?

    var search: OneShot
    var show: OneShot
    var index: Streaming

    static let live = ConversationsLaunchers(
        search: ConversationsRunner.run,
        show: ConversationsRunner.run,
        index: ConversationsRunner.runStreaming
    )
}

@MainActor
final class MainSurfaceModel: ObservableObject {
    // MARK: - Shared list state

    /// The single state machine (§4.5). Views read `blocks`,
    /// `emptyStateText`, `footerHints`, `paneContent` from here.
    @Published private(set) var list: UnifiedListState

    /// The search field's text (§4.6 "search field"): debounced search plus
    /// instant hit recomputation in the conversation pane.
    @Published var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            queryDidChange()
        }
    }

    /// The list scroll position (§4.5: shared by the popover and the
    /// window). Written by the visible surface's list as it scrolls and
    /// restored by a surface's list when that surface is shown. Deliberately
    /// not published: a scroll tick must not re-render the surfaces.
    var listScrollAnchor: ListScrollAnchor?
    /// The normal list's scroll position, kept while the Archive view is
    /// shown (§4.6 "Archive view": back on the normal list, it returns
    /// there).
    private var normalListScrollAnchor: ListScrollAnchor?
    /// Scroll the list to its top (the Archive view was shown).
    @Published private(set) var scrollToTopRequest = 0
    /// Scroll the list back to `listScrollAnchor` (the normal list is back).
    @Published private(set) var scrollRestoreRequest = 0
    /// Set from a switch to or from the Archive view until the visible
    /// surface's list has scrolled for it: until then the list records no
    /// scroll position, so the one just set is not replaced by the other
    /// view's offset.
    private(set) var isListScrollRestorePending = false

    /// The visible surface's list carried out the scroll the switch asked
    /// for.
    func listScrollRestoreDone() { isListScrollRestorePending = false }

    // MARK: - Fixed footer

    @Published private(set) var warnings: [SurfaceWarning] = []
    @Published private(set) var indexProgress: IndexProgress?
    @Published private(set) var messageError: MessageLineError?
    @Published private(set) var transient: MessageTransient?

    struct IndexProgress: Equatable {
        let done: Int
        let total: Int
    }

    /// The message line (§4.6 priority), nil = the line is hidden.
    var messageText: String? {
        MessageLine.text(
            indexProgress: indexProgress.map { (done: $0.done, total: $0.total) },
            error: messageError,
            transient: transient
        )
    }

    // MARK: - Refresh: the header row's Refresh button and ⌘R (§4.5 / §4.6)

    /// From the start of a Refresh until both its search and its reconcile
    /// have finished. The header row's Refresh button is disabled and turns
    /// meanwhile (`RefreshButtonState`).
    @Published private(set) var isRefreshing = false

    // MARK: - Conversation pane

    /// The message page (§4.6 rendering engine). One instance; whichever
    /// surface is visible hosts its web view. Created on first use: the
    /// model is constructed during `AppDelegate.init`, before NSApplication
    /// exists, where no web view may be built.
    private(set) lazy var webPane: WebPaneController = makeWebPane()
    private var webPaneCreated = false
    private let webPaneFactory: @MainActor () -> WebPaneController
    /// One-line error for the message surface (§4.6: show exit 2 / exit 1).
    @Published private(set) var paneLoadError: String?
    /// The message surface shows `No conversation to show`: show exited 2
    /// for a Running row's conversation (§4.6 "conversation pane"). Not
    /// updated on its own — a new selection of the row or Refresh runs show
    /// again.
    @Published private(set) var paneShowsNoConversation = false
    /// All in-body hits of the current query, document order (§4.6).
    @Published private(set) var hits: [ConversationHit] = []
    @Published private(set) var currentHitIndex: Int?

    /// The find bar's counter (§4.6 "hit navigation"): `N of M`, N counted
    /// from the oldest hit as 1; nil while there is no hit.
    var hitCounterText: String? {
        guard !hits.isEmpty else { return nil }
        return "\((currentHitIndex ?? 0) + 1) of \(hits.count)"
    }

    // MARK: - Requests to the views (tokens: a change = act once)

    /// Focus the search field with the caret at the end (§4.5 popover open,
    /// ⌘F) — per surface, so a request meant for one surface never fires
    /// later on the other surface's field. (Moving focus to the list is an
    /// immediate AppKit action: `onFocusList`.)
    @Published private(set) var searchFocusRequests: [MainSurface: Int] = [:]
    /// Scroll the list by the minimum amount that shows the selected row.
    @Published private(set) var scrollSelectionRequest = 0
    /// Move keyboard focus to the conversation pane (§4.5 popover open on
    /// the detail page) — per surface.
    @Published private(set) var paneFocusRequests: [MainSurface: Int] = [:]
    /// Re-attach the shared web view to the visible surface's pane host.
    @Published private(set) var paneAttachRequest = 0

    /// The row whose more-button menu is open (§4.6 "Archive": its box gets
    /// a pale gray ground meanwhile); nil while none is.
    @Published private(set) var openRowMenuKey: UnifiedRowKey?
    /// The more button that was clicked last: where its menu opens.
    private weak var pendingMoreButtonAnchor: NSView?

    // MARK: - Surfaces

    /// The surface on screen (the popover and the window are never shown at
    /// the same time — §4.5 "tray icon click").
    @Published private(set) var visibleSurface: MainSurface?
    /// The window's own column mode (from its width — §4.5 / §9).
    private(set) var windowColumns: ColumnMode = .one
    /// Window pin (§4.5 "pin (Keep on Top)"), persisted.
    @Published private(set) var keepOnTop: Bool
    /// The window is in macOS full screen (reported by the controller from
    /// the window's full-screen transitions; false while the window is
    /// closed). The popover is never full screen: read it through
    /// `isFullScreen(_:)`.
    @Published private(set) var windowFullScreen = false
    /// The height of a title bar the system keeps over the full-screen
    /// window's content (`WindowFullScreenInset`); always 0 outside full
    /// screen, where the layout draws under the title bar on purpose.
    @Published private(set) var windowFullScreenTopInset: Double = 0
    /// The surface form (§4.5 "surface form"), persisted. Changed only by
    /// `Open in window` and `Open in popover`.
    @Published private(set) var surfaceForm: SurfaceForm

    // MARK: - Callbacks into the AppKit layer (set by `MainSurfaceController`)

    var onClosePopover: () -> Void = {}
    var onOpenInWindow: () -> Void = {}
    /// `Open in popover`, in its order (§4.5 "header row"): close the
    /// window, then (the model saves the form) show the popover.
    var onCloseWindowForPopover: () -> Void = {}
    var onShowPopoverFromWindow: () -> Void = {}
    var onPresentMenu: (_ anchor: NSView, _ surface: MainSurface) -> Void = { _, _ in }
    /// Open a row's more-button menu with these items at `anchor` (§4.6
    /// "Archive"); `completion` receives the chosen item's command, or nil
    /// when the menu closes without a choice.
    var onPresentRowMenu: (
        _ items: [RowMenuItem], _ anchor: NSView, _ surface: MainSurface,
        _ completion: @escaping @MainActor (RowMenuCommand?) -> Void
    ) -> Void = { _, _, _, completion in completion(nil) }
    var onKeepOnTopChanged: (Bool) -> Void = { _ in }
    /// Move keyboard focus to the list on this surface: the search field
    /// resigns first responder, so its caret disappears (§4.5 "key
    /// operations").
    var onFocusList: (MainSurface) -> Void = { _ in }
    /// Make this surface's window key without moving the keyboard focus (a
    /// click on a heading — §4.5 "collapsing sections").
    var onMakeSurfaceKey: (MainSurface) -> Void = { _ in }
    /// Called every time a surface is shown (AppState: re-evaluate the
    /// notification permission — §4.5).
    var onSurfaceShown: () -> Void = {}

    // MARK: - Injected dependencies

    var launchers: ConversationsLaunchers
    /// Run `shiibar-cc` with these arguments (the row verbs, and `reconcile`
    /// for Refresh); the completion receives the exit code on the main
    /// actor.
    var runCommand: (_ arguments: [String], _ completion: @escaping @MainActor (Int32) -> Void) -> Void
    /// The `--terminal` value for Resume / Branch (§4.6, `ResumeTerminal`).
    var resumeTerminal: () -> String
    /// Exit 3 from a row verb or from Refresh's reconcile (§4.5: the shared
    /// TCC warning row).
    var onPermissionDenied: () -> Void = {}
    var helpersDirectory: URL?
    private let defaults: UserDefaults
    private let clock: () -> Date
    /// Run an action on the main actor after a delay (the second History
    /// refetch after a Running row ended, and the end of a finished
    /// Refresh's transient — §4.6 / §9). Injected for tests.
    private let schedule: (_ seconds: Double, _ action: @escaping @MainActor () -> Void) -> Void
    /// The system double-click interval (`NSEvent.doubleClickInterval`) and
    /// the system uptime clock the press times use (`NSEvent.timestamp`):
    /// a single click's deselect of an accent row waits for the interval
    /// after its press (§4.5 "row double-click"). Injected for tests.
    private let doubleClickInterval: () -> TimeInterval
    private let uptime: () -> TimeInterval
    /// The text size of both surfaces (DESIGN.md §4.5 "text size"); the
    /// roots observe it for the scale and the widths.
    let textSize: TextSizeStore
    /// The window's two-column list column width (DESIGN.md §4.5 "column
    /// boundary drag"), persisted in the same defaults as the rest.
    let listColumnWidth: ListColumnWidthStore

    // MARK: - Private pipeline state

    private var detail: ConversationDetail?
    private var renderedMessages: [RenderedMessage] = []
    /// Per-conversation scroll memory (message granularity, §4.6), kept
    /// until the app quits (§4.5).
    private var scrollMemory: [String: Int64] = [:]
    private var debounceTask: Task<Void, Never>?
    private var searchProcess: ConversationsProcess?
    private var showProcess: ConversationsProcess?
    private var indexProcess: ConversationsProcess?
    private var searchGeneration = 0
    private var showGeneration = 0
    private var indexGeneration = 0
    private var transientGeneration = 0
    private var delayedRefetchGeneration = 0
    /// The current Refresh's search result (true = success); nil until it
    /// lands.
    private var refreshSearchSucceeded: Bool?
    /// The current Refresh's reconcile exit code; nil until it lands.
    private var refreshReconcileExitCode: Int32?
    private var refreshGeneration = 0
    /// Refresh found `No conversation to show`: show runs again once the
    /// Refresh's search has landed.
    private var reloadShowAfterRefreshSearch = false
    private var clockTimer: Timer?
    private var subscriptions: Set<AnyCancellable> = []

    init(
        home: String?,
        defaults: UserDefaults,
        textSize: TextSizeStore,
        launchers: ConversationsLaunchers = .live,
        runCommand: @escaping (_ arguments: [String], _ completion: @escaping @MainActor (Int32) -> Void) -> Void,
        resumeTerminal: @escaping () -> String = { ResumeTerminal.iterm2 },
        clock: @escaping () -> Date = Date.init,
        schedule: @escaping (_ seconds: Double, _ action: @escaping @MainActor () -> Void) -> Void = MainSurfaceModel.scheduleOnMain,
        doubleClickInterval: @escaping () -> TimeInterval = { NSEvent.doubleClickInterval },
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        webPaneFactory: @escaping @MainActor () -> WebPaneController = { WebPaneController() }
    ) {
        self.defaults = defaults
        self.textSize = textSize
        self.listColumnWidth = ListColumnWidthStore(defaults: defaults)
        self.launchers = launchers
        self.runCommand = runCommand
        self.resumeTerminal = resumeTerminal
        self.clock = clock
        self.schedule = schedule
        self.doubleClickInterval = doubleClickInterval
        self.uptime = uptime
        self.webPaneFactory = webPaneFactory
        let now = Int64(clock().timeIntervalSince1970)
        self.list = UnifiedListState(
            home: home, now: now,
            stars: StarredSessions.load(from: defaults),
            collapsedSections: CollapsedSections.load(from: defaults),
            archived: ArchivedSessions.load(from: defaults))
        // A missing key reads as false == `WindowKeepOnTop.defaultEnabled`.
        self.keepOnTop = defaults.object(forKey: MainSurfaceDefaultsKeys.windowKeepOnTop) as? Bool
            ?? WindowKeepOnTop.defaultEnabled
        self.surfaceForm = SurfaceForm.fromStored(defaults.object(forKey: MainSurfaceDefaultsKeys.surfaceForm))
        textSize.$size
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] size in
                // The column count does not follow the text size (the
                // two-column threshold is fixed — §9); the list column's
                // width does, in `SurfaceColumns`.
                guard let self else { return }
                if self.webPaneCreated {
                    self.webPane.setTextSize(Double(size.points))
                }
            }
            .store(in: &subscriptions)
    }

    /// Production `schedule`: the main queue after `seconds`.
    nonisolated static func scheduleOnMain(_ seconds: Double, _ action: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated { action() }
        }
    }

    private func makeWebPane() -> WebPaneController {
        let pane = webPaneFactory()
        webPaneCreated = true
        pane.onAnchor = { [weak self] seq in
            guard let self, let sessionID = self.list.selection?.sessionID, !sessionID.isEmpty else { return }
            self.scrollMemory[sessionID] = seq
        }
        pane.setTextSize(Double(textSize.size.points))
        return pane
    }

    deinit {
        clockTimer?.invalidate()
    }

    // MARK: - Inputs from AppState

    /// The daemon's agent table changed (§4.5 Running rows).
    func agentsUpdated(_ agents: [Agent]) {
        send(.agentsUpdated(agents))
    }

    func setWarnings(_ warnings: [SurfaceWarning]) {
        if warnings != self.warnings { self.warnings = warnings }
    }

    // MARK: - Surfaces

    /// A surface appeared (popover shown / window opened): re-take the
    /// elapsed base and run it every minute while visible, re-evaluate the
    /// notification permission, and run index -> search (§4.5 "updates
    /// while visible", §4.6 "when the popover or the window opens").
    func surfaceDidShow(_ surface: MainSurface) {
        // A direct switch (`Open in window`, when the popover's close report
        // arrives after the window is shown): the old surface counts as
        // hidden first, so a pending deselect and the
        // other per-press state end as on any close (§4.5 "row
        // double-click"). Its own close report, which can arrive after
        // this, is then a no-op.
        if let previous = visibleSurface, previous != surface {
            surfaceDidHide(previous)
        }
        visibleSurface = surface
        send(.columnsChanged(surface == .popover ? .one : windowColumns))
        send(.clockTicked(now: nowSeconds()))
        startClockTimer()
        paneAttachRequest += 1
        onSurfaceShown()
        runIndexThenSearch()
    }

    /// The window became key (§4.6: index then search when the window
    /// becomes key). The first key after opening counts as the open.
    func windowDidBecomeKey() {
        if visibleSurface != .window {
            surfaceDidShow(.window)
        } else {
            runIndexThenSearch()
        }
    }

    func surfaceDidHide(_ surface: MainSurface) {
        // A boundary drag cannot outlive the window: closing it while the
        // mouse is held ends the drag without remembering the width.
        if surface == .window {
            listColumnWidth.cancelDrag()
            // A window closed while in full screen reports no exit; the
            // controller reads the state again when it reopens.
            windowFullScreenChanged(false)
        }
        guard visibleSurface == surface else { return }
        visibleSurface = nil
        send(.surfaceHidden)
        clockTimer?.invalidate()
        clockTimer = nil
    }

    /// The window's content width changed (§4.5 "switching by width"): the
    /// column mode for it.
    func windowWidthChanged(_ width: Double) {
        windowColumnsChanged(ColumnMode.forWindowWidth(width))
    }

    /// The window's width class changed (§4.5 "switching by width").
    func windowColumnsChanged(_ columns: ColumnMode) {
        windowColumns = columns
        // §4.5: a boundary drag ends without being remembered when the
        // window leaves two columns.
        if columns == .one {
            listColumnWidth.cancelDrag()
        }
        if visibleSurface == .window {
            send(.columnsChanged(columns))
        }
    }

    var isSpinnerActive: Bool { visibleSurface != nil }

    // MARK: - User input

    func rowClicked(_ key: UnifiedRowKey) { send(.rowClicked(key)) }
    func starClicked(sessionID: String) { send(.starToggled(sessionID: sessionID)) }

    /// A click on a heading (§4.5 "collapsing sections"; Core decides
    /// whether it toggles).
    func headingClicked(_ heading: ListHeading) { send(.headingClicked(heading)) }

    /// A click on a row's more button (§4.6 "Archive"); `anchor` is the
    /// button's view, where the menu opens. Core decides whether it opens.
    func moreButtonClicked(_ key: UnifiedRowKey, anchor: NSView?) {
        pendingMoreButtonAnchor = anchor
        send(.moreButtonClicked(key))
    }

    /// The ⌄ menu's `Archived` (§4.5 "⌄ menu").
    func archivedMenuItemChosen() { send(.archivedMenuItemChosen) }

    /// A click on the Archive view's band (§4.6 "Archive view").
    func archiveHeadingClicked() { send(.archiveHeadingClicked) }

    // MARK: - Row drag (§4.5 "row drag")

    /// The button went down on a row; `x` / `y` are window coordinates.
    func rowPressed(_ key: UnifiedRowKey, clickCount: Int, onStar: Bool, x: Double, y: Double) {
        send(.rowPressed(key, clickCount: clickCount, onStar: onStar, x: x, y: y))
    }

    /// The pointer moved with the button held after `rowPressed` (window
    /// coordinates). Core decides once whether the press becomes a drag or
    /// shows why the row cannot be dragged.
    func rowPressDragged(x: Double, y: Double) { send(.rowPressDragged(x: x, y: y)) }

    func rowPressReleased() { send(.rowPressReleased) }

    /// The drag's pointer is at `hit`. Sent only when it changes: every
    /// event re-publishes the state.
    func cardDragMoved(_ hit: ListPointerHit) {
        guard list.cardDrag != nil, list.cardDrag?.lastHit != hit else { return }
        send(.cardDragMoved(hit))
    }

    func cardDragEnded() { send(.cardDragEnded) }

    func cardDragCancelled() {
        guard list.cardDrag != nil else { return }
        send(.cardDragCancelled)
    }
    func backClicked() { send(.back) }
    func previousConversationClicked() { send(.previousConversation) }
    func nextConversationClicked() { send(.nextConversation) }

    /// The bottom panel's View button (one-column list page): the same as →
    /// with list focus — the selected row's detail page opens (§4.5 "opening
    /// the detail page", §4.6 "bottom panel").
    func viewClicked() { send(.openDetail) }

    /// A bottom-panel button (acts on the selected row — §4.5 "action
    /// buttons").
    func buttonClicked(_ button: RowButton) {
        guard let invocation = button.invocation else { return }
        run([.invoke(invocation)])
    }

    /// `Open in window` (§4.5 "header row"): the form becomes the window
    /// form (saved at once), then the popover closes and the window opens.
    func openInWindowClicked() {
        setSurfaceForm(.window)
        onOpenInWindow()
    }

    /// `Open in popover` (§4.5 "header row"): the window closes, the form
    /// becomes the popover form (saved at once), and the popover opens.
    func openInPopoverClicked() {
        onCloseWindowForPopover()
        setSurfaceForm(.popover)
        onShowPopoverFromWindow()
    }

    private func setSurfaceForm(_ form: SurfaceForm) {
        surfaceForm = form
        defaults.set(form.rawValue, forKey: MainSurfaceDefaultsKeys.surfaceForm)
    }

    func menuClicked(anchor: NSView, surface: MainSurface) { onPresentMenu(anchor, surface) }

    /// Whether `surface` is in full screen: only the window can be.
    func isFullScreen(_ surface: MainSurface) -> Bool {
        surface == .window && windowFullScreen
    }

    /// The space `surface` leaves at its top for a title bar kept on
    /// screen in full screen (0 for the popover and outside full screen).
    func topInset(for surface: MainSurface) -> Double {
        surface == .window ? windowFullScreenTopInset : 0
    }

    /// The window entered or left full screen. Leaving it also drops the
    /// top inset.
    func windowFullScreenChanged(_ fullScreen: Bool) {
        if windowFullScreen != fullScreen { windowFullScreen = fullScreen }
        if !fullScreen { windowTopInsetChanged(0) }
    }

    /// The title bar height over the full-screen window's content
    /// (`WindowFullScreenInset.topInset`); ignored outside full screen.
    func windowTopInsetChanged(_ inset: Double) {
        let value = windowFullScreen ? max(0, inset) : 0
        if windowFullScreenTopInset != value { windowFullScreenTopInset = value }
    }

    func keepOnTopClicked() {
        keepOnTop.toggle()
        defaults.set(keepOnTop, forKey: MainSurfaceDefaultsKeys.windowKeepOnTop)
        onKeepOnTopChanged(keepOnTop)
    }

    /// What the key monitor does with the event it routed here.
    enum KeyRouting: Equatable {
        /// Hand the event on to the focused view unchanged.
        case passThrough
        /// Hand the event on to the conversation pane's web view, making it
        /// the first responder first when it is not (↑ / ↓ scroll the
        /// one-column detail page — §4.5).
        case passToConversationPane
        /// Swallow the event (handled, or assigned with no effect here).
        case consumed
    }

    /// A key event routed by the key monitor (§4.5 "key operations").
    /// `searchFieldFocused` is where the focus is at the time of the event.
    func handleKey(
        key: ListKey,
        modifiers: ListKeyModifiers,
        surface: MainSurface,
        hasMarkedText: Bool,
        searchFieldFocused: Bool
    ) -> KeyRouting {
        if list.isSearchFieldFocused != searchFieldFocused {
            send(.searchFieldFocusChanged(searchFieldFocused))
        }
        // A key event reaches the key window only.
        if visibleSurface == surface, !list.isSurfaceKey {
            send(.surfaceKeyChanged(true))
        }
        let context = list.keyContext(isPopover: surface == .popover, hasMarkedText: hasMarkedText)
        switch UnifiedListKeys.decide(key: key, modifiers: modifiers, context: context) {
        case .passThrough:
            return .passThrough
        case .passToConversationPane:
            return .passToConversationPane
        case .ignore:
            return .consumed
        case .perform(let command):
            keySurface = surface
            defer { keySurface = nil }
            run(list.perform(command))
            return .consumed
        }
    }

    /// The search field gained or lost keyboard focus (the AppKit layer
    /// observes the first responder). Reports from a surface that is not on
    /// screen are ignored.
    func searchFieldFocusChanged(surface: MainSurface, focused: Bool) {
        guard visibleSurface == surface, list.isSearchFieldFocused != focused else { return }
        send(.searchFieldFocusChanged(focused))
    }

    /// The surface's window became key or stopped being key (§4.5 "row
    /// selection": the selection is gray while the surface is not key).
    /// Reports from a surface that is not on screen are ignored.
    func surfaceKeyChanged(surface: MainSurface, isKey: Bool) {
        guard visibleSurface == surface, list.isSurfaceKey != isKey else { return }
        send(.surfaceKeyChanged(isKey))
    }

    /// The left mouse button went down on the surface, before AppKit
    /// dispatches the click (the AppKit layer's event monitor): the key
    /// status and the search field's focus at that moment decide what a
    /// click on the selected row does (§4.5 "row click"); the system click
    /// count and the press time tell a double-click apart and time the
    /// deferred deselect, and ⌘ at the second press makes a double-click run
    /// Branch (§4.5 "row double-click"). Presses on a surface that is not on
    /// screen are ignored.
    func pointerDown(
        surface: MainSurface,
        surfaceWasKey: Bool,
        searchFieldFocused: Bool,
        clickCount: Int = 1,
        pressedAt: TimeInterval? = nil,
        commandKey: Bool = false
    ) {
        guard visibleSurface == surface else { return }
        send(.pointerDown(surfaceKey: surfaceWasKey, searchFieldFocused: searchFieldFocused,
                          clickCount: clickCount, pressedAt: pressedAt, commandKey: commandKey))
    }

    /// Focus requests issued by the AppKit layer when a surface opens
    /// (§4.5: list page -> search field, detail page -> conversation pane).
    func requestInitialFocus() {
        let surface = visibleSurface ?? .popover
        if list.columns == .one && list.page == .detail {
            paneFocusRequests[surface, default: 0] += 1
        } else {
            searchFocusRequests[surface, default: 0] += 1
        }
    }

    /// The global hotkey opened the popover or brought the window forward
    /// (§4.5 "global hotkey"): the list takes focus instead of the search
    /// field (Core decides — `UnifiedListEvent.openedByHotKey`).
    func openedByHotKey() {
        send(.openedByHotKey)
    }

    // MARK: - Refresh

    /// Refresh (§4.6), from the header row's Refresh button and from ⌘R:
    /// re-run the search with the same query (History) and run `shiibar-cc
    /// reconcile` (Running), then wait for both. A Refresh while one is in
    /// flight does nothing.
    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshSearchSucceeded = nil
        refreshReconcileExitCode = nil
        refreshGeneration += 1
        let generation = refreshGeneration
        setTransient(.refreshing, autoClear: false)
        debounceTask?.cancel()
        performSearch()
        // §4.6 "conversation pane": `No conversation to show` is not updated
        // on its own; Refresh runs show again — once its search has landed,
        // since show reads the index as it is and the search catches it up.
        reloadShowAfterRefreshSearch = paneShowsNoConversation
        runCommand(CLIRunner.reconcileArguments) { [weak self] exitCode in
            guard let self, generation == self.refreshGeneration, self.isRefreshing else { return }
            self.refreshReconcileExitCode = exitCode
            self.settleRefreshIfFinished()
        }
    }

    // MARK: - Hit navigation (§4.6)

    func navigateToOlderHit() {
        if let target = ConversationsHitNavigation.previous(current: currentHitIndex, count: hits.count) {
            jumpToHit(target)
        }
    }

    func navigateToNewerHit() {
        if let target = ConversationsHitNavigation.next(current: currentHitIndex, count: hits.count) {
            jumpToHit(target)
        }
    }

    // MARK: - Events and effects

    private func send(_ event: UnifiedListEvent) {
        run(list.handle(event))
        // `No conversation to show` belongs to a Running row. When a Running
        // row that ended hands its selection to the History row with the
        // same session_id, the shown conversation stays the same (no load
        // effect), so the pane loads it again.
        if paneShowsNoConversation, list.isConversationPaneVisible, let selection = list.selection,
           case .conversation = selection.key, !selection.sessionID.isEmpty {
            loadConversation(selection.sessionID)
        }
    }

    /// The surface whose key event is being handled (focus effects go
    /// there); otherwise the visible surface.
    private var keySurface: MainSurface?

    private var focusSurface: MainSurface? { keySurface ?? visibleSurface }

    private func run(_ effects: [UnifiedListEffect]) {
        for effect in effects {
            switch effect {
            case .loadConversation(let sessionID):
                loadConversation(sessionID)
            case .scrollSelectionIntoView:
                scrollSelectionRequest += 1
            case .focusSearchField:
                searchFocusRequests[focusSurface ?? .popover, default: 0] += 1
            case .focusList:
                if let surface = focusSurface { onFocusList(surface) }
            case .focusConversationPane:
                if let surface = focusSurface { paneFocusRequests[surface, default: 0] += 1 }
            case .refetchHistory:
                performSearch()
            case .refetchHistoryLater(let seconds):
                // A newer schedule replaces a pending one (§4.6: overlapping
                // triggers may coalesce).
                delayedRefetchGeneration += 1
                let generation = delayedRefetchGeneration
                schedule(seconds) { [weak self] in
                    guard let self, generation == self.delayedRefetchGeneration else { return }
                    self.performSearch()
                }
            case .persistStars(let stars):
                StarredSessions.save(stars, to: defaults)
            case .persistCollapsedSections(let sections):
                CollapsedSections.save(sections, to: defaults)
            case .persistArchive(let sessionIDs):
                ArchivedSessions.save(sessionIDs, to: defaults)
            case .showRowMenu(let key):
                presentRowMenu(for: key)
            case .scrollListToTop:
                normalListScrollAnchor = listScrollAnchor
                listScrollAnchor = nil
                isListScrollRestorePending = true
                scrollToTopRequest += 1
            case .restoreListScroll:
                let anchor = normalListScrollAnchor
                normalListScrollAnchor = nil
                isListScrollRestorePending = true
                if let anchor, list.visibleRows.contains(where: { $0.id == anchor.key }) {
                    listScrollAnchor = anchor
                    scrollRestoreRequest += 1
                } else {
                    // Never scrolled, or its row left the normal list: the
                    // normal list starts at its top rather than at the
                    // Archive view's offset.
                    listScrollAnchor = nil
                    scrollToTopRequest += 1
                }
            case .makeSurfaceKey:
                if let surface = focusSurface { onMakeSurfaceKey(surface) }
            case .invoke(let invocation):
                invoke(invocation)
            case .scheduleDragRefusalDismiss(let id, let seconds):
                schedule(seconds) { [weak self] in
                    self?.send(.dragRefusalDismissDue(id: id))
                }
            case .scheduleDeferredDeselect(let id, let pressedAt):
                // Measured from the press (§4.5): the click action runs on
                // mouse-up, part of the interval has already passed.
                let elapsed = pressedAt.map { max(0, uptime() - $0) } ?? 0
                schedule(max(0, doubleClickInterval() - elapsed)) { [weak self] in
                    self?.send(.deferredDeselectDue(id: id))
                }
            case .closePopover:
                onClosePopover()
            case .refresh:
                refresh()
            case .nextMatch:
                navigateToNewerHit()
            case .previousMatch:
                navigateToOlderHit()
            case .increaseTextSize:
                textSize.increase()
            case .decreaseTextSize:
                textSize.decrease()
            case .resetTextSize:
                textSize.reset()
            }
        }
    }

    /// Opens the row's menu at its more button (§4.6 "Archive"). The items
    /// are the row's at this moment; a choice is sent to Core, which applies
    /// the state rules then (a conversation that became live meanwhile is
    /// unarchived again).
    private func presentRowMenu(for key: UnifiedRowKey) {
        guard let anchor = pendingMoreButtonAnchor, let surface = focusSurface,
              let row = list.visibleRows.first(where: { $0.id == key }), !row.menuItems.isEmpty else { return }
        let sessionID = row.sessionID
        openRowMenuKey = key
        onPresentRowMenu(row.menuItems, anchor, surface) { [weak self] command in
            guard let self else { return }
            self.openRowMenuKey = nil
            switch command {
            case .archive: self.send(.archiveRequested(sessionID: sessionID))
            case .unarchive: self.send(.unarchiveRequested(sessionID: sessionID))
            case nil: break
            }
        }
    }

    private func nowSeconds() -> Int64 {
        Int64(clock().timeIntervalSince1970)
    }

    /// §4.5 / §9: re-take the elapsed base every 60 seconds while visible.
    private func startClockTimer() {
        clockTimer?.invalidate()
        clockTimer = Timer.scheduledTimer(withTimeInterval: MainSurfaceRefresh.elapsedIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.send(.clockTicked(now: self.nowSeconds()))
            }
        }
    }

    private func setTransient(_ value: MessageTransient?, autoClear: Bool = false) {
        transientGeneration += 1
        let generation = transientGeneration
        transient = value
        guard autoClear, value != nil else { return }
        // §9: a finished Refresh's transient stays this long. A newer
        // transient replaces it and is not cleared by this timer.
        schedule(MessageTransient.displaySeconds) { [weak self] in
            guard let self, self.transientGeneration == generation else { return }
            self.transient = nil
        }
    }

    // MARK: - Index on open (§4.6)

    private func runIndexThenSearch() {
        indexProcess?.cancel()
        indexGeneration += 1
        let generation = indexGeneration
        indexProcess = launchers.index(
            ["conversations", "index", "--json"],
            helpersDirectory,
            { [weak self] line in
                guard let self, generation == self.indexGeneration else { return }
                self.handleIndexLine(line)
            },
            { [weak self] code in
                guard let self, generation == self.indexGeneration else { return }
                self.handleIndexFinished(code)
            }
        )
    }

    private func handleIndexLine(_ line: String) {
        guard let event = IndexProgressEvent.decode(line) else { return }
        switch event {
        case .start(let total, let fullBuild):
            // Only a full build (§4.4 `full_build`) hides History and
            // disables the search field (§4.6 / §8.34). An incremental
            // catch-up keeps the previous History, selection and page. The
            // latest start wins (a relayed stream can hand over builders).
            if fullBuild != list.isFullBuild {
                send(.fullBuildChanged(fullBuild))
            }
            noteIndexProgress(done: 0, total: total)
        case .progress(let done, let total):
            noteIndexProgress(done: done, total: total)
        case .done:
            indexProgress = nil
        case .error(let message):
            surfaceLog.error("index error: \(message, privacy: .public)")
        }
    }

    /// The message line's `Indexing N of M…` (§4.6). A warm index reports
    /// total 0 and stays silent.
    private func noteIndexProgress(done: Int, total: Int) {
        guard total > 0 else { return }
        indexProgress = IndexProgress(done: done, total: total)
    }

    private func handleIndexFinished(_ code: Int32) {
        indexProgress = nil
        if list.isFullBuild {
            send(.fullBuildChanged(false))
        }
        guard code == 0 else {
            // §4.6: show the error; the previous History stays (none if
            // there was none). Recovery comes with the next trigger.
            messageError = .indexFailed
            send(.historyFetchFailed)
            return
        }
        performSearch()
    }

    // MARK: - Search (§4.6)

    private func queryDidChange() {
        // "Searching" follows the search text at once (§4.5 "collapsing
        // sections"): Running and History show open, headings and drags
        // stop, and a drag in progress is cancelled, before any result
        // arrives.
        let valid = ConversationsQuery.shouldIssueSearch(query.precomposedStringWithCanonicalMapping)
        if valid != list.isQueryValid {
            send(.queryValidityChanged(valid))
        }
        // Highlights and the counter follow the query at once, without
        // moving the scroll (§4.6).
        recomputeHits()
        pushHitsToPane(scrollToCurrent: false)
        guard !list.isFullBuild else {
            surfaceLog.notice("keystroke dropped: search disabled during index build")
            return
        }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ConversationsConstants.searchDebounceSeconds * 1_000_000_000))
            if Task.isCancelled { return }
            self?.performSearch()
        }
    }

    /// Run `conversations search [<query>] --json` for the current query;
    /// a query without a valid term browses (§4.6). Cancels any in-flight
    /// search (several triggers coalesce into the newest run).
    private func performSearch() {
        // NFC before dispatch (§4.6 / §8.38(12)); the CLI normalizes too.
        let raw = query.precomposedStringWithCanonicalMapping
        let issue = ConversationsQuery.shouldIssueSearch(raw)
        searchProcess?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        surfaceLog.notice(
            "search gen \(generation) dispatch chars=\(raw.count) terms=\(ConversationsQuery.validTerms(raw).count) browse=\(!issue)"
        )
        var arguments = ["conversations", "search"]
        if issue { arguments.append(raw) }
        arguments.append("--json")
        searchProcess = launchers.search(arguments, helpersDirectory) { [weak self] result in
            guard let self else { return }
            guard generation == self.searchGeneration else {
                surfaceLog.notice("search gen \(generation) result dropped as stale (current gen \(self.searchGeneration))")
                return
            }
            surfaceLog.notice("search gen \(generation) result exit=\(result.exitCode) bytes=\(result.stdout.utf8.count)")
            self.handleSearchResult(result, filtered: issue)
        }
    }

    private func handleSearchResult(_ result: CLIRunResult, filtered: Bool) {
        guard result.exitCode == 0, let decoded = ConversationSearchResult.decode(result.stdout) else {
            // §4.6: keep the previous result, show the error.
            messageError = .searchFailed
            send(.historyFetchFailed)
            noteRefreshSearchFinished(succeeded: false)
            return
        }
        // §4.6: an error clears on the next successful fetch.
        messageError = nil
        send(.historyDelivered(decoded.conversations, isFiltered: filtered))
        noteRefreshSearchFinished(succeeded: true)
    }

    /// The first search result to land during a Refresh is the Refresh's
    /// search (a newer search trigger replaces the Refresh's own run, and
    /// its result stands for it).
    private func noteRefreshSearchFinished(succeeded: Bool) {
        guard isRefreshing, refreshSearchSucceeded == nil else { return }
        refreshSearchSucceeded = succeeded
        if reloadShowAfterRefreshSearch {
            reloadShowAfterRefreshSearch = false
            if paneShowsNoConversation, let sessionID = list.selection?.sessionID, !sessionID.isEmpty {
                loadConversation(sessionID)
            }
        }
        settleRefreshIfFinished()
    }

    /// §4.6: once both the search and the reconcile have finished, the
    /// outcome of §4.6's table replaces `Refreshing…` at once (no minimum
    /// display time).
    private func settleRefreshIfFinished() {
        guard isRefreshing,
              let searchSucceeded = refreshSearchSucceeded,
              let reconcileExitCode = refreshReconcileExitCode else { return }
        let outcome = RefreshOutcome.decide(searchSucceeded: searchSucceeded, reconcileExitCode: reconcileExitCode)
        if outcome.raisesAutomationWarning {
            onPermissionDenied()
        }
        isRefreshing = false
        if let transient = outcome.transient {
            setTransient(transient, autoClear: true)
        } else if transient == .refreshing {
            setTransient(nil)
        }
    }

    // MARK: - Conversation pane (show) — §4.6

    private func loadConversation(_ sessionID: String) {
        detail = nil
        renderedMessages = []
        hits = []
        currentHitIndex = nil
        paneLoadError = nil
        paneShowsNoConversation = false
        showProcess?.cancel()
        showGeneration += 1
        let generation = showGeneration
        showProcess = launchers.show(["conversations", "show", sessionID, "--json"], helpersDirectory) { [weak self] result in
            guard let self, generation == self.showGeneration,
                  self.list.selection?.sessionID == sessionID else { return }
            self.handleShowResult(result, sessionID: sessionID)
        }
    }

    private func handleShowResult(_ result: CLIRunResult, sessionID: String) {
        var isRunningRow = false
        if case .running = list.selection?.key { isRunningRow = true }
        switch ConversationShowOutcome.classify(exitCode: result.exitCode, isRunningRow: isRunningRow) {
        case .messages:
            guard let loaded = ConversationDetail.decode(result.stdout) else {
                paneLoadError = Self.loadFailedText
                return
            }
            paneLoadError = nil
            detail = loaded
            renderedMessages = loaded.messages.map { RenderedMessage(role: $0.role, text: $0.text) }
            recomputeHits()
            let updatedAt = list.history?.first { $0.sessionID == sessionID }?.updatedAt
            let elapsed = updatedAt.map { ElapsedTime.format(seconds: nowSeconds() - $0) }
            webPane.load(
                messages: loaded.messages, rendered: renderedMessages,
                anchorSeq: scrollMemory[sessionID], elapsed: elapsed
            )
            pushHitsToPane(scrollToCurrent: scrollMemory[sessionID] == nil)
        case .noConversation:
            paneLoadError = nil
            paneShowsNoConversation = true
        case .unavailable:
            // Assumption (§4.6 gives no wording): the one-line texts below.
            paneLoadError = Self.unavailableText
        case .failed:
            paneLoadError = Self.loadFailedText
        }
    }

    static let unavailableText = "Conversation no longer available"
    static let loadFailedText = "Failed to load conversation"

    private func recomputeHits() {
        guard detail != nil else {
            hits = []
            currentHitIndex = nil
            return
        }
        let terms = ConversationsQuery.validTerms(query.precomposedStringWithCanonicalMapping)
        hits = ConversationHits.locations(messageTexts: renderedMessages.map(\.renderedText), terms: terms)
        // §4.6: the initial position is the latest hit.
        currentHitIndex = hits.isEmpty ? nil : hits.count - 1
    }

    private func pushHitsToPane(scrollToCurrent: Bool) {
        guard detail != nil else { return }
        webPane.setHits(hits, rendered: renderedMessages, current: currentHitIndex)
        if scrollToCurrent, let currentHitIndex {
            webPane.jump(to: currentHitIndex)
        }
    }

    private func jumpToHit(_ index: Int) {
        guard hits.indices.contains(index) else { return }
        currentHitIndex = index
        webPane.jump(to: index)
    }

    // MARK: - Row verbs (§4.5 "action buttons", §4.6 "Resume and Branch" / "Jump")

    private func invoke(_ invocation: RowInvocation) {
        let arguments = invocation.cliArguments(terminal: resumeTerminal())
        runCommand(arguments) { [weak self] exitCode in
            self?.handleInvocationFinished(invocation, exitCode: exitCode)
        }
    }

    private func handleInvocationFinished(_ invocation: RowInvocation, exitCode: Int32) {
        let outcome = RowInvocationOutcome.classify(invocation, exitCode: exitCode)
        switch outcome {
        case .succeeded(let refetch):
            if refetch {
                performSearch()
            }
        case .targetNotFound:
            break
        case .permissionDenied:
            onPermissionDenied()
        case .failed(let error):
            messageError = error
        }
        if outcome.closesPopover, visibleSurface == .popover {
            onClosePopover()
        }
    }
}
