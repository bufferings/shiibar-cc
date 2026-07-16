// Drives the Conversations window (DESIGN.md §4.6, M35 T4–T7): it owns the
// list/preview state and turns user actions into `shiibar-cc conversations`
// subprocess calls via `ConversationsRunner`, decoding the JSON with the
// ShiibarCcCore wire types. It holds NO transcript/SQLite knowledge — the app
// is a display client over the CLI (§4.6).
//
// The four — and only four — refresh triggers (§4.6): window open, keystroke
// (debounced), the ⟳ button, and a successful Resume. Nothing else changes
// the list; there is no file watching (no FSEvents). List and preview are
// separate state: a list refresh never touches the preview except to clear
// it when the selected conversation drops out of the results.

import AppKit
import Combine
import ConversationsWebPaneKit
import Foundation
import os
import ShiibarCcCore

private let conversationsLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "cc.shiibar.menubar",
    category: "conversations"
)

@MainActor
final class ConversationsViewModel: ObservableObject {
    // MARK: - List (left pane)

    /// The current query text (bound to the search field).
    @Published var query: String = ""
    /// The visible list (all conversations, live included — §4.6).
    @Published private(set) var summaries: [ConversationSummary] = []
    /// Status line text (§4.6): counts, build progress, or an error.
    @Published private(set) var statusText: String = ""
    /// Empty-list message shown in the rows area, or nil when there are rows
    /// (or during a full build, when only progress shows).
    @Published private(set) var listEmptyMessage: String?
    /// Disable the search field during a full index build (§4.6/T7).
    @Published private(set) var searchDisabled = false
    /// ⌘F focus requests (§4.6/§8.41): incremented per press; the search
    /// field representable observes the change and takes first responder.
    @Published private(set) var searchFocusToken = 0

    /// ⌘F while the Conversations window is key: focus the search field.
    func focusSearchField() {
        searchFocusToken += 1
    }
    /// A ⟳ refresh is in flight (§4.6/§8.38(8)): the button disables and
    /// the status line says so — a press always visibly reacts, and repeat
    /// presses during the run are ignored.
    @Published private(set) var isRefreshing = false
    /// Post-refresh transient (§4.6/§9: "Updated · N conversations" for the
    /// same 2 seconds as the Rescan transient), shown instead of the counts.
    private var updatedTransientText: String?
    private var updatedTransientTask: Task<Void, Never>?
    /// When the current ⟳ run started (§8.44: the rotation's phase is
    /// anchored here so it always begins upright). Non-nil for exactly as
    /// long as the button spins; the view reads it to drive the rotation.
    @Published private(set) var refreshStartedAt: Date?
    /// When the current ⟳ run's result landed (§8.44): the rotation keeps
    /// turning past this to the next whole-turn boundary before settling.
    /// Nil while the run is still in flight.
    @Published private(set) var refreshRunEndedAt: Date?
    private var refreshCompletionTask: Task<Void, Never>?

    // MARK: - Preview (right pane)

    /// Selected conversation id (selection is kept by session_id so a list
    /// refresh doesn't drop it — §4.6).
    @Published private(set) var selectedSessionID: String?
    /// The loaded conversation (full text, oldest-first).
    @Published private(set) var detail: ConversationDetail?
    /// The messages prepared for display (§4.6 rendering grammar): Markdown
    /// blocks plus the rendered text that hit offsets and the fold boundary
    /// are counted on. Always parallel to `detail.messages`.
    @Published private(set) var renderedMessages: [RenderedMessage] = []
    /// All in-body hits for the current query, document order. Offsets are
    /// in each message's rendered text (§4.6).
    @Published private(set) var hits: [ConversationHit] = []
    /// Index into `hits` of the current position (nil = no hits / no bar).
    @Published private(set) var currentHitIndex: Int?
    /// The message page (§4.6 rendering engine / §8.38): renders the
    /// conversation, owns fold/expand state and the in-page scroll, and
    /// reports the scroll anchor back for §4.6 scroll memory. Core stays
    /// authoritative — this view model passes it Core's computed hits,
    /// boundaries, and badge inputs.
    let webPane = WebPaneController()

    // MARK: - Private state

    private weak var appState: AppState?
    private var helpersDirectory: URL? { appState?.helpersDirectory }
    var home: String? { appState?.home }

    /// Per-conversation scroll memory (message granularity, §4.6), fed by
    /// the page's anchor reports. Discarded when the window closes
    /// (`windowClosed`).
    private var scrollMemory: [String: Int64] = [:]

    /// Whether the visible results came from a real search (filtering) vs
    /// browse (empty query) — decides the status-line shape.
    private var resultsAreFiltered = false
    /// Denominator M for "N of M conversations" — the most recent browse
    /// total (§4.6: the last full count).
    private var browseTotal = 0
    /// Transient index-build progress text, shown ahead of counts.
    private var indexProgressText: String?
    /// Transient error text, shown ahead of counts (but behind progress).
    private var errorText: String?

    private var debounceTask: Task<Void, Never>?
    private var searchProcess: ConversationsProcess?
    private var showProcess: ConversationsProcess?
    private var indexProcess: ConversationsProcess?
    private var searchGeneration = 0
    private var showGeneration = 0

    /// Injectable launcher for the list-search subprocess (M39 T7: the
    /// search pipeline must be drivable by tests with a stubbed runner).
    /// Production default is the real subprocess runner.
    var searchProcessLauncher: (
        _ arguments: [String],
        _ helpersDirectory: URL?,
        _ completion: @escaping @MainActor (CLIRunResult) -> Void
    ) -> ConversationsProcess? = ConversationsRunner.run

    /// Injectable launcher for the show subprocess (mirrors
    /// `searchProcessLauncher`): auto-select-on-open (§4.6/§8.46) drives a
    /// `show` exactly as a click does, so tests must be able to observe that
    /// fetch with a stubbed runner rather than launch a real subprocess.
    /// Production default is the real subprocess runner.
    var showProcessLauncher: (
        _ arguments: [String],
        _ helpersDirectory: URL?,
        _ completion: @escaping @MainActor (CLIRunResult) -> Void
    ) -> ConversationsProcess? = ConversationsRunner.run

    /// Injectable launcher for the index-on-open streaming subprocess
    /// (mirrors `searchProcessLauncher`): the auto-select-on-open flow
    /// (§4.6/§8.46) begins with `conversations index --json`, so tests must
    /// be able to drive an open without launching a real subprocess.
    /// Production default is the real streaming runner.
    var indexProcessLauncher: (
        _ arguments: [String],
        _ helpersDirectory: URL?,
        _ onLine: @escaping @MainActor (String) -> Void,
        _ completion: @escaping @MainActor (Int32) -> Void
    ) -> ConversationsProcess? = ConversationsRunner.runStreaming

    /// A window-open auto-select is pending (§4.6/§8.46): set when the window
    /// opens, consumed by the FIRST list delivery of that open (including the
    /// late delivery after a full index build). It is the ONLY auto-select
    /// trigger — keystroke/⟳ deliveries never set it, so they cannot select
    /// on the user's behalf.
    private var pendingAutoSelectOnOpen = false

    init(appState: AppState?) {
        self.appState = appState
        refreshStatus()
        webPane.onAnchor = { [weak self] seq in
            guard let self, let selectedSessionID = self.selectedSessionID else { return }
            self.scrollMemory[selectedSessionID] = seq
        }
    }

    // MARK: - Lifecycle (window open/close)

    /// Window opened (§4.6/T7): run `conversations index --json` for visible
    /// progress, disabling the search field during a full build, then run a
    /// search for the current query once the index is caught up.
    func windowOpened() {
        errorText = nil
        // Arm auto-select for this open (DESIGN.md §4.6/§8.46): the first list
        // delivery selects the newest row when nothing is selected. A held
        // selection survives reopen, so the delivery's nil check leaves it be.
        pendingAutoSelectOnOpen = true
        runIndexThenSearch()
    }

    /// Window closed (§4.6): scroll memory is discarded; cancel any in-flight
    /// subprocesses so a terminated run can't land on a torn-down window.
    func windowClosed() {
        scrollMemory.removeAll()
        debounceTask?.cancel()
        searchProcess?.cancel()
        showProcess?.cancel()
        indexProcess?.cancel()
    }

    // MARK: - Index-on-open (T7)

    private func runIndexThenSearch() {
        indexProcess?.cancel()
        indexProcess = indexProcessLauncher(
            ["conversations", "index", "--json"],
            helpersDirectory,
            { [weak self] line in self?.handleIndexLine(line) },
            { [weak self] code in self?.handleIndexFinished(code) }
        )
    }

    private func handleIndexLine(_ line: String) {
        guard let event = IndexProgressEvent.decode(line) else { return }
        switch event {
        case .start(let total):
            enterFullBuildIfNeeded(done: 0, total: total)
        case .progress(let done, let total):
            enterFullBuildIfNeeded(done: done, total: total)
        case .done:
            // Progress ends; `handleIndexFinished` runs the search.
            indexProgressText = nil
        case .error(let message):
            conversationsLog.error("index error: \(message, privacy: .public)")
            // Surfaced as the finished-error path below.
        }
    }

    /// A build with real work to do (total > 0) is a full build: disable the
    /// search field and show progress only, no partial list (§4.6/§8.34). A
    /// warm index reports total 0 and stays imperceptible.
    private func enterFullBuildIfNeeded(done: Int, total: Int) {
        guard total > 0 else { return }
        if !searchDisabled {
            searchDisabled = true
            summaries = []
            listEmptyMessage = nil
        }
        indexProgressText = "Indexing \(done) of \(total)\u{2026}"
        refreshStatus()
    }

    private func handleIndexFinished(_ code: Int32) {
        indexProgressText = nil
        searchDisabled = false
        if code != 0 {
            // §4.6: an index error shows an error with NO list.
            summaries = []
            resultsAreFiltered = false
            listEmptyMessage = nil
            errorText = "Indexing failed"
            // The open produced no list, so its auto-select shot is spent
            // (§4.6/§8.46): recovery is a later trigger, which never selects.
            pendingAutoSelectOnOpen = false
            refreshStatus()
            return
        }
        // Caught up — populate the list for the current query.
        performSearch()
    }

    // MARK: - Search (list) — triggers: keystroke, ⟳, resume, post-index

    /// Keystroke handler: debounce, then search (§9 200ms). No effect while
    /// the field is disabled during a full build.
    func queryChanged() {
        guard !searchDisabled else {
            // Named in the field trail: a keystroke landing during a full
            // index build issues no search (the post-build search covers it).
            conversationsLog.notice("keystroke dropped: search disabled during index build")
            return
        }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ConversationsConstants.searchDebounceSeconds * 1_000_000_000))
            if Task.isCancelled { return }
            self?.performSearch()
        }
    }

    /// ⟳ button (§4.6): re-run the same query immediately (picks up
    /// conversations finished elsewhere). Same grammar as Rescan. Repeat
    /// presses while a run is in flight are ignored (§8.38(8)).
    func refreshTapped() {
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshStartedAt = Date()
        refreshRunEndedAt = nil
        refreshStatus()
        debounceTask?.cancel()
        performSearch()
    }

    /// Run `conversations search [--json]` for the current query. An
    /// all-too-short query (no valid 2+ char term) browses instead of
    /// searching (§4.6). Cancels any in-flight search first.
    private func performSearch() {
        // NFC before dispatch (§4.6/§8.38(12), defense in depth — the CLI
        // normalizes too): IME text arrives decomposed on macOS, and the
        // index stores the composed form.
        let raw = query.precomposedStringWithCanonicalMapping
        let issue = ConversationsQuery.shouldIssueSearch(raw)
        searchProcess?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        // M39 T7 instrumentation (default level, content-free): the owner's
        // IME search miss did not reproduce in the pipeline tests, so the
        // dispatch/result trail must name the failing stage in the field.
        // Query CONTENT never enters the log — only shape.
        conversationsLog.notice(
            "search gen \(generation) dispatch chars=\(raw.count) terms=\(ConversationsQuery.validTerms(raw).count) browse=\(!issue)"
        )

        var arguments = ["conversations", "search"]
        if issue { arguments.append(raw) }
        arguments.append("--json")

        searchProcess = searchProcessLauncher(arguments, helpersDirectory) { [weak self] result in
            guard let self else { return }
            guard generation == self.searchGeneration else {
                conversationsLog.notice("search gen \(generation) result dropped as stale (current gen \(self.searchGeneration))")
                return
            }
            conversationsLog.notice("search gen \(generation) result exit=\(result.exitCode) bytes=\(result.stdout.utf8.count)")
            self.handleSearchResult(result, filtered: issue)
        }
    }

    private func handleSearchResult(_ result: CLIRunResult, filtered: Bool) {
        let finishedRefresh = isRefreshing
        if !finishedRefresh, updatedTransientText != nil {
            updatedTransientTask?.cancel()
            updatedTransientText = nil
        }
        guard result.exitCode == 0, let decoded = ConversationSearchResult.decode(result.stdout) else {
            // §4.6: a search error keeps the previous list and shows an error.
            errorText = "Search failed"
            // A failed open search delivered no list, so its auto-select shot
            // is spent (§4.6/§8.46): only "the open" may auto-select, never a
            // later recovery trigger.
            pendingAutoSelectOnOpen = false
            if finishedRefresh {
                // §8.43: even the failure settles only after the full turn.
                settleRefreshAtWholeTurn(successCount: nil)
            }
            refreshStatus()
            return
        }
        errorText = nil
        summaries = decoded.conversations
        resultsAreFiltered = filtered
        if !filtered {
            browseTotal = summaries.count
        }
        listEmptyMessage = summaries.isEmpty
            ? (filtered ? "No matching conversations" : "No conversations")
            : nil
        if finishedRefresh {
            settleRefreshAtWholeTurn(successCount: summaries.count)
        }
        // Auto-select the newest conversation on open (DESIGN.md §4.6/§8.46):
        // the first list delivery of an open selects the top row (the list is
        // always newest-first) when nothing is selected — same show fetch,
        // scroll-to-latest, and Resume panel as a click. This is the sole
        // auto-select trigger; keystroke/⟳ deliveries never arm the flag.
        // Zero conversations stays in the empty state. A held selection (a
        // reopen) is non-nil here, so it is left untouched. Runs before the
        // drop-out clear below so the just-selected newest — which is in the
        // results — is not immediately cleared.
        if pendingAutoSelectOnOpen {
            pendingAutoSelectOnOpen = false
            if selectedSessionID == nil, let newest = summaries.first {
                selectConversation(newest)
            }
        }
        // §4.6: clear the preview only when the selected conversation is no
        // longer in the results; otherwise the preview is untouched.
        if let selectedSessionID, !summaries.contains(where: { $0.sessionID == selectedSessionID }) {
            clearPreview()
        }
        refreshStatus()
    }

    /// §8.44: the search finishes in tens of milliseconds — too fast to
    /// perceive — so the in-flight look (rotating glyph + disabled button +
    /// "Refreshing…") persists until the rotation reaches its next whole-turn
    /// boundary at or after max(run end, one turn) (§9), so the arrow always
    /// settles upright with no visible jump. Only then does the button
    /// re-enable and the "Updated · N conversations" transient (success) or
    /// the error (nil count) take over. Re-clicks during the extended window
    /// stay ignored because `isRefreshing` holds until here.
    private func settleRefreshAtWholeTurn(successCount: Int?) {
        guard let startedAt = refreshStartedAt else { return }
        let now = Date()
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
                self.updatedTransientTask?.cancel()
                self.updatedTransientText = "Updated \u{00B7} \(count) conversations"
                self.updatedTransientTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(RescanFeedback.displaySeconds * 1_000_000_000))
                    if Task.isCancelled { return }
                    self?.updatedTransientText = nil
                    self?.refreshStatus()
                }
            }
            self.refreshStatus()
        }
    }

    // MARK: - Preview (show) — T5

    /// Load and display the full conversation (§4.6): fetch once with
    /// `conversations show --json`, oldest-first. Recompute hits, restore the
    /// remembered scroll or land at the initial position.
    func selectConversation(_ summary: ConversationSummary) {
        selectedSessionID = summary.sessionID
        showProcess?.cancel()
        showGeneration += 1
        let generation = showGeneration
        let sessionID = summary.sessionID

        showProcess = showProcessLauncher(
            ["conversations", "show", sessionID, "--json"],
            helpersDirectory
        ) { [weak self] result in
            guard let self, generation == self.showGeneration,
                  self.selectedSessionID == sessionID else { return }
            self.handleShowResult(result, sessionID: sessionID)
        }
    }

    private func handleShowResult(_ result: CLIRunResult, sessionID: String) {
        switch result.exitCode {
        case 0:
            guard let loaded = ConversationDetail.decode(result.stdout) else {
                errorText = "Failed to load conversation"
                refreshStatus()
                return
            }
            errorText = nil
            detail = loaded
            // Render once per load (§4.6): blocks + rendered text drive the
            // display, the hit offsets, and the fold boundary.
            renderedMessages = loaded.messages.map { RenderedMessage(role: $0.role, text: $0.text) }
            recomputeHits()
            // §4.6: the page renders and positions itself — the remembered
            // anchor (per conversation, message granularity) wins over the
            // bottom-default; hits land right after so the initial position
            // can be the latest hit.
            // The end marker's elapsed text (§4.6/§8.39) uses the same
            // formatting as the header, carried in the payload (simpler
            // than a bridge call; same load-time staleness as the header).
            let elapsed = summaries.first { $0.sessionID == sessionID }.map {
                ElapsedTime.format(seconds: Int64(Date().timeIntervalSince1970) - $0.updatedAt)
            }
            webPane.load(
                messages: loaded.messages, rendered: renderedMessages,
                anchorSeq: scrollMemory[sessionID], elapsed: elapsed
            )
            pushHitsToPane(scrollToCurrent: scrollMemory[sessionID] == nil)
            refreshStatus()
        case 2:
            // §4.6: not in the index (just deleted) — clear the preview, one
            // line in the status, keep the list.
            clearPreview()
            errorText = "Conversation no longer available"
            refreshStatus()
        default:
            // exit 1 (§4.6): show an error, keep the list.
            errorText = "Failed to load conversation"
            refreshStatus()
        }
    }

    private func clearPreview() {
        detail = nil
        renderedMessages = []
        hits = []
        currentHitIndex = nil
        selectedSessionID = nil
        webPane.load(messages: [], rendered: [], anchorSeq: nil)
    }

    // MARK: - Hit navigation (T5)

    /// Recompute hits for the current query over the loaded conversation's
    /// RENDERED texts (§4.6: positioning uses the displayed characters, not
    /// the raw transcript). Called after `show` and whenever the query
    /// changes. Sets the current position to the LATEST hit; the caller
    /// decides whether to move the scroll (it moves on select/restore, not on
    /// a query re-type).
    private func recomputeHits() {
        guard detail != nil else {
            hits = []
            currentHitIndex = nil
            return
        }
        // NFC here too (§8.38(12)): `show` now returns composed text, so
        // composed terms keep offsets exact.
        let terms = ConversationsQuery.validTerms(query.precomposedStringWithCanonicalMapping)
        hits = ConversationHits.locations(messageTexts: renderedMessages.map(\.renderedText), terms: terms)
        currentHitIndex = hits.isEmpty ? nil : hits.count - 1
    }

    /// Query changed while a conversation is open: recompute highlights and
    /// the counter, but DO NOT move the scroll (§4.6). Separate from the list
    /// search's debounce — highlighting is instant and local.
    func queryChangedForPreview() {
        recomputeHits()
        // §4.6: highlights and the counter refresh, the scroll does not move
        // — and an active selection survives (highlights are painted ranges,
        // not DOM structure — §8.38).
        pushHitsToPane(scrollToCurrent: false)
    }

    /// Mirror Core's hits into the page. `scrollToCurrent` jumps to the
    /// initial position (the latest hit) on a fresh load without scroll
    /// memory; a query re-type never moves the scroll (§4.6).
    private func pushHitsToPane(scrollToCurrent: Bool) {
        webPane.setHits(hits, rendered: renderedMessages, current: currentHitIndex)
        if scrollToCurrent, let currentHitIndex {
            webPane.jump(to: currentHitIndex)
        }
    }

    /// ‹ / ⇧⌘G — toward the older hit (lower document index). Clamped and
    /// ALWAYS jumping while hits exist (§4.6/§8.38(7)): the old guards
    /// skipped the jump entirely when the index had nowhere to move, which
    /// was the owner's "single hit / folded hit doesn't navigate" defect —
    /// the pane never got asked to scroll (or expand) at all.
    func navigateToOlderHit() {
        if let target = ConversationsHitNavigation.previous(current: currentHitIndex, count: hits.count) {
            jumpToHit(target)
        }
    }

    /// › / ⌘G — toward the newer hit (higher document index).
    func navigateToNewerHit() {
        if let target = ConversationsHitNavigation.next(current: currentHitIndex, count: hits.count) {
            jumpToHit(target)
        }
    }

    private func jumpToHit(_ index: Int) {
        guard hits.indices.contains(index) else { return }
        currentHitIndex = index
        // §4.6: the page scrolls to the hit and auto-expands a folded one —
        // acting on Core's hidden flag carried in the hits payload.
        webPane.jump(to: index)
    }

    // MARK: - Resume (T6)

    /// Whether a Resume button should show for `summary`: past only, and only
    /// when the cwd is known (resume needs an absolute cwd — §4.4).
    func canResume(_ summary: ConversationSummary) -> Bool {
        !summary.live && (summary.cwd?.isEmpty == false)
    }

    /// Resume a past conversation in a new terminal window (§4.6/T6):
    /// `shiibar-cc resume --cwd <cwd> --terminal <t> <session_id>` via the
    /// same subprocess mechanism as focus. The terminal `t` is decided by
    /// observation (§4.6): the newest agent entry's prefix, else the last
    /// observed kind, else `iterm2` — the app decides and passes it, resume
    /// makes no decision of its own (§4.4). The window stays open. On success,
    /// re-run the search so the resumed conversation flips to running.
    func resume(_ summary: ConversationSummary) {
        guard !summary.live, let cwd = summary.cwd, !cwd.isEmpty else { return }
        let sessionID = summary.sessionID
        let terminal = appState?.resumeTerminal ?? ResumeTerminal.iterm2
        DispatchQueue.global(qos: .userInitiated).async { [helpersDirectory] in
            let result = CLIRunner.run(
                ["resume", "--cwd", cwd, "--terminal", terminal, sessionID],
                helpersDirectory: helpersDirectory,
                expectedExitCodes: [0]
            )
            Task { @MainActor [weak self] in
                self?.handleResumeResult(result.exitCode)
            }
        }
    }

    private func handleResumeResult(_ exitCode: Int32) {
        switch exitCode {
        case 0:
            // §4.6: re-run the search so the resumed conversation shows as
            // running (and loses its Resume button).
            errorText = nil
            performSearch()
        case 3:
            // TCC — handled like a focus failure (§4.5): raise the shared
            // warning flag AND show it in this window's status line.
            appState?.tccWarning = true
            errorText = "Automation permission needed (run \"shiibar-cc doctor\")"
            refreshStatus()
        default:
            errorText = "Resume failed"
            refreshStatus()
        }
    }

    // MARK: - Status line

    private func refreshStatus() {
        if let indexProgressText {
            statusText = indexProgressText
            return
        }
        if isRefreshing {
            // §4.6: the press must visibly react even when the result set
            // ends up identical.
            statusText = "Refreshing\u{2026}"
            return
        }
        if let updatedTransientText {
            statusText = updatedTransientText
            return
        }
        if let errorText {
            statusText = errorText
            return
        }
        if resultsAreFiltered {
            statusText = "\(summaries.count) of \(browseTotal) conversations"
        } else {
            let running = summaries.filter(\.live).count
            statusText = "\(summaries.count) conversations (\(running) running)"
        }
    }
}
