// The one model behind the popover and the window (DESIGN.md §4.5 "the
// popover and the window share one state", §4.6, §8.49). It holds the single
// `UnifiedListState` (Core), feeds it events (daemon updates, search
// results, clock ticks, user input), executes the effects it returns, and
// runs the subprocess pipelines around it: `conversations index --json` on
// open, the debounced `conversations search`, `conversations show` for the
// conversation pane, and the row verbs (focus / resume / resume --fork).
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

    /// The single state machine (§4.5). Views read `sections`,
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

    // MARK: - ⟳ (§4.6 / §8.44)

    @Published private(set) var isRefreshing = false
    /// Non-nil exactly while the ⟳ glyph spins (phase anchor, §8.44).
    @Published private(set) var refreshStartedAt: Date?
    /// When the ⟳ run's result landed (nil while in flight).
    @Published private(set) var refreshRunEndedAt: Date?

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

    // MARK: - Surfaces

    /// The surface on screen (the popover and the window are never shown at
    /// the same time — §4.5 "tray icon click").
    @Published private(set) var visibleSurface: MainSurface?
    /// The window's own column mode (from its width — §4.5 / §9).
    private(set) var windowColumns: ColumnMode = .one
    /// Window pin (§4.5 "pin (Keep on Top)"), persisted.
    @Published private(set) var keepOnTop: Bool

    // MARK: - Callbacks into the AppKit layer (set by `MainSurfaceController`)

    var onClosePopover: () -> Void = {}
    var onOpenInWindow: () -> Void = {}
    var onPresentMenu: (_ anchor: NSView, _ surface: MainSurface) -> Void = { _, _ in }
    var onKeepOnTopChanged: (Bool) -> Void = { _ in }
    /// Move keyboard focus to the list on this surface: the search field
    /// resigns first responder, so its caret disappears (§4.5 "key
    /// operations").
    var onFocusList: (MainSurface) -> Void = { _ in }
    /// Called every time a surface is shown (AppState: re-evaluate the
    /// notification permission — §4.5).
    var onSurfaceShown: () -> Void = {}

    // MARK: - Injected dependencies

    var launchers: ConversationsLaunchers
    /// Run a row verb's `shiibar-cc` arguments; the completion receives the
    /// exit code on the main actor.
    var runCommand: (_ arguments: [String], _ completion: @escaping @MainActor (Int32) -> Void) -> Void
    /// The `--terminal` value for Resume / Branch (§4.6, `ResumeTerminal`).
    var resumeTerminal: () -> String
    /// Exit 3 from a row verb (§4.5: the shared TCC warning row).
    var onPermissionDenied: () -> Void = {}
    var helpersDirectory: URL?
    private let defaults: UserDefaults
    private let clock: () -> Date
    /// Run an action on the main actor after a delay (the second History
    /// refetch after a Running row ended — §4.6 / §9). Injected for tests.
    private let schedule: (_ seconds: Double, _ action: @escaping @MainActor () -> Void) -> Void
    /// The system double-click interval (`NSEvent.doubleClickInterval`) and
    /// the system uptime clock the press times use (`NSEvent.timestamp`):
    /// a single click's deselect of an accent row waits for the interval
    /// after its press (§4.5 "row double-click"). Injected for tests.
    private let doubleClickInterval: () -> TimeInterval
    private let uptime: () -> TimeInterval
    private let textSize: ConversationsTextSizeStore

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
    private var refreshCompletionTask: Task<Void, Never>?
    private var clockTimer: Timer?
    private var subscriptions: Set<AnyCancellable> = []

    init(
        home: String?,
        defaults: UserDefaults,
        textSize: ConversationsTextSizeStore,
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
        self.launchers = launchers
        self.runCommand = runCommand
        self.resumeTerminal = resumeTerminal
        self.clock = clock
        self.schedule = schedule
        self.doubleClickInterval = doubleClickInterval
        self.uptime = uptime
        self.webPaneFactory = webPaneFactory
        let now = Int64(clock().timeIntervalSince1970)
        self.list = UnifiedListState(home: home, now: now, stars: StarredSessions.load(from: defaults))
        // A missing key reads as false == `WindowKeepOnTop.defaultEnabled`.
        self.keepOnTop = defaults.object(forKey: MainSurfaceDefaultsKeys.windowKeepOnTop) as? Bool
            ?? WindowKeepOnTop.defaultEnabled
        textSize.$size
            .removeDuplicates()
            .sink { [weak self] size in
                guard let self, self.webPaneCreated else { return }
                self.webPane.setTextSize(size)
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
        pane.setTextSize(textSize.size)
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

    /// Manual Rescan feedback (§4.5): shares the message line's transient
    /// tier with the ⟳ transients (a newer one replaces an older one).
    func showRescanFeedback(_ feedback: RescanFeedback?) {
        guard let feedback else {
            if case .rescan = transient { setTransient(nil) }
            return
        }
        setTransient(.rescan(feedback), autoClear: feedback != .running)
    }

    // MARK: - Surfaces

    /// A surface appeared (popover shown / window opened): re-take the
    /// elapsed base and run it every minute while visible, re-evaluate the
    /// notification permission, and run index -> search (§4.5 "updates
    /// while visible", §4.6 "when the popover or the window opens").
    func surfaceDidShow(_ surface: MainSurface) {
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
        guard visibleSurface == surface else { return }
        visibleSurface = nil
        send(.surfaceHidden)
        clockTimer?.invalidate()
        clockTimer = nil
    }

    /// The window's width class changed (§4.5 "switching by width").
    func windowColumnsChanged(_ columns: ColumnMode) {
        windowColumns = columns
        if visibleSurface == .window {
            send(.columnsChanged(columns))
        }
    }

    var isSpinnerActive: Bool { visibleSurface != nil }

    // MARK: - User input

    func rowClicked(_ key: UnifiedRowKey) { send(.rowClicked(key)) }
    /// The row's `>` button (one column — §4.5).
    func rowOpenClicked(_ key: UnifiedRowKey) { send(.rowOpenClicked(key)) }
    func starClicked(sessionID: String) { send(.starToggled(sessionID: sessionID)) }
    func backClicked() { send(.back) }
    func previousConversationClicked() { send(.previousConversation) }
    func nextConversationClicked() { send(.nextConversation) }

    /// A bottom-panel button (acts on the selected row — §4.5 "action
    /// buttons").
    func buttonClicked(_ button: RowButton) {
        guard let invocation = button.invocation else { return }
        run([.invoke(invocation)])
    }

    func openInWindowClicked() { onOpenInWindow() }

    func menuClicked(anchor: NSView, surface: MainSurface) { onPresentMenu(anchor, surface) }

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
    /// deferred deselect (§4.5 "row double-click"). Presses on a surface
    /// that is not on screen are ignored.
    func pointerDown(
        surface: MainSurface,
        surfaceWasKey: Bool,
        searchFieldFocused: Bool,
        clickCount: Int = 1,
        pressedAt: TimeInterval? = nil
    ) {
        guard visibleSurface == surface else { return }
        send(.pointerDown(surfaceKey: surfaceWasKey, searchFieldFocused: searchFieldFocused,
                          clickCount: clickCount, pressedAt: pressedAt))
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

    // MARK: - ⟳

    /// ⟳ (§4.6): re-run the same query now. Presses during a run are
    /// ignored (§8.38(8)).
    func refreshClicked() {
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshStartedAt = clock()
        refreshRunEndedAt = nil
        setTransient(.refreshing, autoClear: false)
        debounceTask?.cancel()
        performSearch()
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
            case .invoke(let invocation):
                invoke(invocation)
            case .scheduleDeferredDeselect(let id, let pressedAt):
                // Measured from the press (§4.5): the click action runs on
                // mouse-up, part of the interval has already passed.
                let elapsed = pressedAt.map { max(0, uptime() - $0) } ?? 0
                schedule(max(0, doubleClickInterval() - elapsed)) { [weak self] in
                    self?.send(.deferredDeselectDue(id: id))
                }
            case .closePopover:
                onClosePopover()
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
        DispatchQueue.main.asyncAfter(deadline: .now() + MessageTransient.displaySeconds) { [weak self] in
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
        let finishedRefresh = isRefreshing
        guard result.exitCode == 0, let decoded = ConversationSearchResult.decode(result.stdout) else {
            // §4.6: keep the previous result, show the error.
            messageError = .searchFailed
            send(.historyFetchFailed)
            if finishedRefresh { settleRefreshAtWholeTurn(successCount: nil) }
            return
        }
        // §4.6: an error clears on the next successful fetch.
        messageError = nil
        send(.historyDelivered(decoded.conversations, isFiltered: filtered))
        if finishedRefresh {
            settleRefreshAtWholeTurn(successCount: list.searchResultCount)
        }
    }

    /// §8.44: the ⟳ in-flight look lasts until the rotation reaches its next
    /// whole-turn boundary at or after max(run end, one turn), then the
    /// `Updated · N conversations` transient (success) takes over.
    private func settleRefreshAtWholeTurn(successCount: Int?) {
        guard let startedAt = refreshStartedAt else { return }
        let now = clock()
        refreshRunEndedAt = now
        let runEndElapsed = now.timeIntervalSince(startedAt)
        let stopElapsed = ConversationsRefreshSpin.stopElapsedSeconds(runEndSeconds: runEndElapsed)
        let remaining = max(0, stopElapsed - runEndElapsed)
        refreshCompletionTask?.cancel()
        refreshCompletionTask = Task { [weak self] in
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                if Task.isCancelled { return }
            }
            guard let self else { return }
            self.isRefreshing = false
            self.refreshStartedAt = nil
            self.refreshRunEndedAt = nil
            if let count = successCount {
                self.setTransient(.updated(count: count), autoClear: true)
            } else if self.transient == .refreshing {
                self.setTransient(nil)
            }
        }
    }

    // MARK: - Conversation pane (show) — §4.6

    private func loadConversation(_ sessionID: String) {
        detail = nil
        renderedMessages = []
        hits = []
        currentHitIndex = nil
        paneLoadError = nil
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
        switch result.exitCode {
        case 0:
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
        case 2:
            // Assumption (§4.6 gives no wording): the one-line texts below.
            paneLoadError = Self.unavailableText
        default:
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
