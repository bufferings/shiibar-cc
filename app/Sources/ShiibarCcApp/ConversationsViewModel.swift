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

    // MARK: - Preview (right pane)

    /// Selected conversation id (selection is kept by session_id so a list
    /// refresh doesn't drop it — §4.6).
    @Published private(set) var selectedSessionID: String?
    /// The loaded conversation (full text, oldest-first).
    @Published private(set) var detail: ConversationDetail?
    /// All in-body hits for the current query, document order.
    @Published private(set) var hits: [ConversationHit] = []
    /// Index into `hits` of the current position (nil = no hits / no bar).
    @Published private(set) var currentHitIndex: Int?
    /// Messages the user (or a ▲▼ jump) has expanded past the §9 fold.
    @Published private(set) var expandedMessageSeqs: Set<Int64> = []
    /// Two-way scroll anchor (message seq) for `scrollPosition(id:)`. Every
    /// change is remembered per conversation (§4.6 scroll memory).
    @Published var scrolledMessageID: Int64? {
        didSet {
            if let selectedSessionID, let scrolledMessageID {
                scrollMemory[selectedSessionID] = scrolledMessageID
            }
        }
    }

    // MARK: - Private state

    private weak var appState: AppState?
    private var helpersDirectory: URL? { appState?.helpersDirectory }
    var home: String? { appState?.home }

    /// Per-conversation scroll memory (message granularity, §4.6). Discarded
    /// when the window closes (`windowClosed`).
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

    init(appState: AppState) {
        self.appState = appState
        refreshStatus()
    }

    // MARK: - Lifecycle (window open/close)

    /// Window opened (§4.6/T7): run `conversations index --json` for visible
    /// progress, disabling the search field during a full build, then run a
    /// search for the current query once the index is caught up.
    func windowOpened() {
        errorText = nil
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
        indexProcess = ConversationsRunner.runStreaming(
            arguments: ["conversations", "index", "--json"],
            helpersDirectory: helpersDirectory,
            onLine: { [weak self] line in self?.handleIndexLine(line) },
            completion: { [weak self] code in self?.handleIndexFinished(code) }
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
        guard !searchDisabled else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ConversationsConstants.searchDebounceSeconds * 1_000_000_000))
            if Task.isCancelled { return }
            self?.performSearch()
        }
    }

    /// ⟳ button (§4.6): re-run the same query immediately (picks up
    /// conversations finished elsewhere). Same grammar as Rescan.
    func refreshTapped() {
        debounceTask?.cancel()
        performSearch()
    }

    /// Run `conversations search [--json]` for the current query. An
    /// all-too-short query (no valid 2+ char term) browses instead of
    /// searching (§4.6). Cancels any in-flight search first.
    private func performSearch() {
        let raw = query
        let issue = ConversationsQuery.shouldIssueSearch(raw)
        searchProcess?.cancel()
        searchGeneration += 1
        let generation = searchGeneration

        var arguments = ["conversations", "search"]
        if issue { arguments.append(raw) }
        arguments.append("--json")

        searchProcess = ConversationsRunner.run(
            arguments: arguments,
            helpersDirectory: helpersDirectory
        ) { [weak self] result in
            guard let self, generation == self.searchGeneration else { return }
            self.handleSearchResult(result, filtered: issue)
        }
    }

    private func handleSearchResult(_ result: CLIRunResult, filtered: Bool) {
        guard result.exitCode == 0, let decoded = ConversationSearchResult.decode(result.stdout) else {
            // §4.6: a search error keeps the previous list and shows an error.
            errorText = "Search failed"
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
        // §4.6: clear the preview only when the selected conversation is no
        // longer in the results; otherwise the preview is untouched.
        if let selectedSessionID, !summaries.contains(where: { $0.sessionID == selectedSessionID }) {
            clearPreview()
        }
        refreshStatus()
    }

    // MARK: - Preview (show) — T5

    /// Load and display the full conversation (§4.6): fetch once with
    /// `conversations show --json`, oldest-first. Recompute hits, restore the
    /// remembered scroll or land at the initial position.
    func selectConversation(_ summary: ConversationSummary) {
        selectedSessionID = summary.sessionID
        // New selection: reset per-conversation preview state before the
        // fetch lands.
        expandedMessageSeqs = []
        scrolledMessageID = nil
        showProcess?.cancel()
        showGeneration += 1
        let generation = showGeneration
        let sessionID = summary.sessionID

        showProcess = ConversationsRunner.run(
            arguments: ["conversations", "show", sessionID, "--json"],
            helpersDirectory: helpersDirectory
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
            recomputeHits()
            restoreScroll(sessionID: sessionID)
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
        hits = []
        currentHitIndex = nil
        expandedMessageSeqs = []
        selectedSessionID = nil
        scrolledMessageID = nil
    }

    // MARK: - Hit navigation (T5)

    /// Recompute hits for the current query over the loaded conversation
    /// (§4.6). Called after `show` and whenever the query changes. Sets the
    /// current position to the LATEST hit; the caller decides whether to move
    /// the scroll (it moves on select/restore, not on a query re-type).
    private func recomputeHits() {
        guard let detail else {
            hits = []
            currentHitIndex = nil
            return
        }
        let terms = ConversationsQuery.validTerms(query)
        hits = ConversationHits.locations(messageTexts: detail.messages.map(\.text), terms: terms)
        currentHitIndex = hits.isEmpty ? nil : hits.count - 1
    }

    /// Query changed while a conversation is open: recompute highlights and
    /// the counter, but DO NOT move the scroll (§4.6). Separate from the list
    /// search's debounce — highlighting is instant and local.
    func queryChangedForPreview() {
        recomputeHits()
    }

    /// ▲ — jump to the older hit (lower document index).
    func navigateToOlderHit() {
        guard let index = currentHitIndex, index > 0 else { return }
        jumpToHit(index - 1)
    }

    /// ▼ — jump to the newer hit (higher document index).
    func navigateToNewerHit() {
        guard let index = currentHitIndex, index < hits.count - 1 else { return }
        jumpToHit(index + 1)
    }

    private func jumpToHit(_ index: Int) {
        guard hits.indices.contains(index), let detail else { return }
        currentHitIndex = index
        let hit = hits[index]
        guard detail.messages.indices.contains(hit.messageIndex) else { return }
        let message = detail.messages[hit.messageIndex]
        // §4.6: a folded hit auto-expands on ▲▼ jump.
        if ConversationHits.requiresExpansion(hit: hit, messageText: message.text) {
            expandedMessageSeqs.insert(message.seq)
        }
        scrolledMessageID = message.seq
    }

    /// `Show full message` tap for one message (§4.6/§9 fold).
    func expandMessage(seq: Int64) {
        expandedMessageSeqs.insert(seq)
    }

    // MARK: - Resume (T6)

    /// Whether a Resume button should show for `summary`: past only, and only
    /// when the cwd is known (resume needs an absolute cwd — §4.4).
    func canResume(_ summary: ConversationSummary) -> Bool {
        !summary.live && (summary.cwd?.isEmpty == false)
    }

    /// Resume a past conversation in a new iTerm2 window (§4.6/T6):
    /// `shiibar-cc resume --cwd <cwd> <session_id>` via the same subprocess
    /// mechanism as focus. The window stays open. On success, re-run the
    /// search so the resumed conversation flips to running.
    func resume(_ summary: ConversationSummary) {
        guard !summary.live, let cwd = summary.cwd, !cwd.isEmpty else { return }
        let sessionID = summary.sessionID
        DispatchQueue.global(qos: .userInitiated).async { [helpersDirectory] in
            let result = CLIRunner.run(
                ["resume", "--cwd", cwd, sessionID],
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

    // MARK: - Scroll restore (T5)

    /// On (re)selection: the remembered scroll wins over the initial position
    /// (§4.6); otherwise land on the latest hit, or — with no hits — at the
    /// bottom (latest message) via the list's default bottom anchor (a nil
    /// anchor here).
    private func restoreScroll(sessionID: String) {
        if let remembered = scrollMemory[sessionID] {
            scrolledMessageID = remembered
        } else if let index = currentHitIndex, hits.indices.contains(index),
                  let detail, detail.messages.indices.contains(hits[index].messageIndex) {
            let hit = hits[index]
            let message = detail.messages[hit.messageIndex]
            if ConversationHits.requiresExpansion(hit: hit, messageText: message.text) {
                expandedMessageSeqs.insert(message.seq)
            }
            scrolledMessageID = message.seq
        } else {
            scrolledMessageID = nil // bottom (latest) via defaultScrollAnchor
        }
    }

    // MARK: - Status line

    private func refreshStatus() {
        if let indexProgressText {
            statusText = indexProgressText
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
