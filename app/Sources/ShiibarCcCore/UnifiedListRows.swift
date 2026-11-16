// Row models for the single list shown by the popover and the window
// (DESIGN.md §4.5 "the list has two sections" / "Running rows" / "action
// buttons", §4.6 "History section" / "stars" / "search scope", §8.49).
// Everything a row view draws is precomputed here: three text lines, the
// leading slot (status symbol or star) and the unreviewed emphasis. Each row
// also carries the two action buttons the bottom panel shows while it is
// selected (enabled state, tooltip and the CLI call they make); the row card
// itself shows none of them (§4.5 "action buttons"). The view layer only
// lays these out.

import Foundation

/// The two list sections, top to bottom (§4.5).
public enum UnifiedListSection: Equatable, Sendable {
    case running
    case history

    /// Section heading text (bold, followed by the row count — §4.5).
    public var title: String {
        switch self {
        case .running: return "Running"
        case .history: return "History"
        }
    }
}

/// A row's identity. Selection is held by target for Running rows and by
/// session_id for History rows (§4.5 "row selection").
public enum UnifiedRowKey: Hashable, Sendable {
    case running(target: String)
    case history(sessionID: String)
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

/// The row's leading slot (§4.5/§4.6): the status symbol on Running rows,
/// the star on History rows.
public enum RowLeadingSlot: Equatable, Sendable {
    /// Running row: status symbol, plus the red badge when unreviewed.
    case status(RowSymbolKind, unreviewed: Bool)
    /// History row: a filled yellow star when starred (always visible); when
    /// not starred, an outline star shown only while the row is hovered.
    /// Clicking the slot toggles the star and never selects the row (§4.6).
    case star(isStarred: Bool)

    /// Tooltip of the star slot (§4.6: `Star` / `Unstar`), nil for status.
    public var tooltip: String? {
        switch self {
        case .status: return nil
        case .star(let isStarred): return isStarred ? "Unstar" : "Star"
        }
    }
}

/// One card in the list (§4.5/§4.6).
public struct UnifiedListRow: Equatable, Identifiable, Sendable {
    public let id: UnifiedRowKey
    public let section: UnifiedListSection
    /// May be empty on a Running row (§4.5 "row click").
    public let sessionID: String
    /// Raw cwd (nil or empty when unknown).
    public let cwd: String?
    /// Line 1.
    public let line1: String
    /// §4.5: unreviewed = line 1 in bold (plus the badge in `leading`).
    public let isLine1Bold: Bool
    /// The two-component folder label (§4.5 "display label").
    public let label: String
    public let elapsedSeconds: Int64
    /// Line 2: `label · elapsed`, plus ` · running` on a live History row.
    public let line2: String
    /// Whether line 2 ends with the faint `running` mark (§4.6) — lets the
    /// view style that trailing word; it is already part of `line2`.
    public let showsRunningMark: Bool
    /// Line 3 without the `❯` marker, newlines already replaced by spaces.
    /// nil = draw an empty line (no marker) so row heights stay equal.
    public let lastPrompt: String?
    public let leading: RowLeadingSlot
    /// The bottom panel's primary button while this row is selected: Jump
    /// (Running, or disabled Jump for a live History row) or Resume.
    public let primaryButton: RowButton
    /// The bottom panel's Branch button while this row is selected.
    public let branchButton: RowButton
    /// Conversation pane header line 1 (§4.6): the conversation title. For a
    /// row with an empty session_id it is the row's line 1 (§4.5).
    public let headerTitle: String
    /// Conversation pane header line 2 (§4.6): the full home-relative path
    /// plus `· <elapsed> ago`.
    public let headerSubtitle: String

    /// §4.5/§4.6: the marker drawn before line 3 when `lastPrompt` is set.
    public static let promptMarker = "\u{276F}"

    /// §4.5 "the row's `>` button": its tooltip (one column only).
    public static let openTooltip = "Open"

    public init(
        id: UnifiedRowKey,
        section: UnifiedListSection,
        sessionID: String,
        cwd: String?,
        line1: String,
        isLine1Bold: Bool,
        label: String,
        elapsedSeconds: Int64,
        line2: String,
        showsRunningMark: Bool,
        lastPrompt: String?,
        leading: RowLeadingSlot,
        primaryButton: RowButton,
        branchButton: RowButton,
        headerTitle: String,
        headerSubtitle: String
    ) {
        self.id = id
        self.section = section
        self.sessionID = sessionID
        self.cwd = cwd
        self.line1 = line1
        self.isLine1Bold = isLine1Bold
        self.label = label
        self.elapsedSeconds = elapsedSeconds
        self.line2 = line2
        self.showsRunningMark = showsRunningMark
        self.lastPrompt = lastPrompt
        self.leading = leading
        self.primaryButton = primaryButton
        self.branchButton = branchButton
        self.headerTitle = headerTitle
        self.headerSubtitle = headerSubtitle
    }

    /// The same row with both buttons disabled (used while a selected
    /// Running row that just ended awaits the History refetch — §4.5).
    func withButtonsDisabled() -> UnifiedListRow {
        UnifiedListRow(
            id: id, section: section, sessionID: sessionID, cwd: cwd, line1: line1,
            isLine1Bold: isLine1Bold, label: label, elapsedSeconds: elapsedSeconds, line2: line2,
            showsRunningMark: showsRunningMark, lastPrompt: lastPrompt, leading: leading,
            primaryButton: primaryButton.disabled(), branchButton: branchButton.disabled(),
            headerTitle: headerTitle, headerSubtitle: headerSubtitle
        )
    }
}

/// A non-empty section with its rows (§4.5: an empty section is not shown,
/// heading included).
public struct UnifiedListSectionModel: Equatable, Identifiable, Sendable {
    public var id: UnifiedListSection { section }
    public let section: UnifiedListSection
    public let rows: [UnifiedListRow]

    public var title: String { section.title }
    /// The heading's row count: the number of rows shown, which is the
    /// filtered count while searching (§4.6 "search scope").
    public var count: Int { rows.count }
}

/// Star set rules (§4.6 "stars"). Stars are an app display setting: a set of
/// session IDs persisted in UserDefaults (`MainSurfaceDefaultsKeys`).
public enum StarredSessions {
    /// Toggle one session's star.
    public static func toggled(_ stars: Set<String>, sessionID: String) -> Set<String> {
        var result = stars
        if result.contains(sessionID) {
            result.remove(sessionID)
        } else {
            result.insert(sessionID)
        }
        return result
    }

    /// §4.6: when an empty-query (browse) list is fetched, drop the stars of
    /// session IDs that are not in it (the transcript was deleted). Never
    /// call this with a filtered (search) result.
    public static func pruned(_ stars: Set<String>, browseResults: [ConversationSummary]) -> Set<String> {
        let present = Set(browseResults.map(\.sessionID))
        return stars.intersection(present)
    }

    /// Read the persisted set from an injected `UserDefaults`.
    public static func load(from defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: MainSurfaceDefaultsKeys.starredSessionIDs) ?? [])
    }

    /// Persist the set (sorted for a deterministic stored value).
    public static func save(_ stars: Set<String>, to defaults: UserDefaults) {
        defaults.set(stars.sorted(), forKey: MainSurfaceDefaultsKeys.starredSessionIDs)
    }
}

/// Builds the two sections from the daemon's agent list and the latest
/// search result (§4.5/§4.6).
public enum UnifiedListBuilder {
    /// Replace every newline with a space so the text shows on one line
    /// (§4.5: the newlines in `task` become spaces).
    public static func singleLine(_ text: String) -> String {
        String(text.map { $0.isNewline ? " " : $0 })
    }

    /// Line 1 of a Running row (§4.5): `message` while waiting; otherwise
    /// the conversation title (from the search result with the same
    /// session_id); while no title is available, `task`; failing that, the
    /// label (§3.6).
    ///
    /// Assumption (spec silent): a waiting row with no `message` falls back
    /// through the same title -> task -> label chain. `task` used as a
    /// fallback is made single-line like line 3.
    public static func runningLine1(agent: Agent, title: String?, label: String) -> String {
        if agent.status == .waiting, let message = agent.message, !message.isEmpty {
            return singleLine(message)
        }
        return runningTitle(agent: agent, title: title, label: label)
    }

    /// The conversation title of a Running row without the waiting override:
    /// title -> task -> label. Used for the pane header (§4.6: header line 1
    /// is the title).
    static func runningTitle(agent: Agent, title: String?, label: String) -> String {
        if let title, !title.isEmpty {
            return singleLine(title)
        }
        if let task = agent.task, !task.isEmpty {
            return singleLine(task)
        }
        return label
    }

    /// `label · elapsed` (§4.5 line 2).
    static func line2(label: String, elapsedSeconds: Int64, runningMark: Bool) -> String {
        var text = "\(label) \u{00B7} \(ElapsedTime.format(seconds: elapsedSeconds))"
        if runningMark {
            text += " \u{00B7} running"
        }
        return text
    }

    /// Pane header line 2 (§4.6; window-design.html shows
    /// `~/work/demo/menubar-app · 3h ago`). Assumption: with no cwd only the
    /// elapsed part is shown.
    static func headerSubtitle(cwd: String?, home: String?, elapsedSeconds: Int64) -> String {
        let elapsed = "\(ElapsedTime.format(seconds: elapsedSeconds)) ago"
        guard let cwd, !cwd.isEmpty else { return elapsed }
        return "\(HomeRelativePath.format(cwd, home: home)) \u{00B7} \(elapsed)"
    }

    /// Build one Running row (§4.5). `title` is the matched search result's
    /// title, if any. Returns nil for an `.unknown` status (clients ignore
    /// unknown statuses — §4.2).
    public static func runningRow(agent: Agent, title: String?, now: Int64, home: String?) -> UnifiedListRow? {
        guard let symbol = RowSymbol.kind(for: agent.status) else { return nil }
        let label = CwdLabel.format(cwd: agent.cwd, home: home)
        let elapsed = max(0, now - agent.since)
        let line1 = runningLine1(agent: agent, title: title, label: label)
        let prompt = agent.task.flatMap { $0.isEmpty ? nil : singleLine($0) }
        let primary = ConversationAction.derive(forRunningAgent: agent)
            .button(sessionID: agent.sessionId, cwd: agent.cwd)
        let branch = ConversationAction.branchButton(sessionID: agent.sessionId, cwd: agent.cwd)
        return UnifiedListRow(
            id: .running(target: agent.target),
            section: .running,
            sessionID: agent.sessionId,
            cwd: agent.cwd,
            line1: line1,
            isLine1Bold: agent.unreviewed,
            label: label,
            elapsedSeconds: elapsed,
            line2: line2(label: label, elapsedSeconds: elapsed, runningMark: false),
            showsRunningMark: false,
            lastPrompt: prompt,
            leading: .status(symbol, unreviewed: agent.unreviewed),
            primaryButton: primary,
            branchButton: branch,
            headerTitle: agent.sessionId.isEmpty ? line1 : runningTitle(agent: agent, title: title, label: label),
            headerSubtitle: headerSubtitle(cwd: agent.cwd, home: home, elapsedSeconds: elapsed)
        )
    }

    /// Build one History row (§4.6). The summary is never one that matches a
    /// Running row (those are excluded before this), so a `live` summary is
    /// a conversation running in a terminal this app cannot drive.
    ///
    /// Assumption (spec silent): with no title and no cwd, line 1 is empty.
    public static func historyRow(
        summary: ConversationSummary,
        isStarred: Bool,
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
        return UnifiedListRow(
            id: .history(sessionID: summary.sessionID),
            section: .history,
            sessionID: summary.sessionID,
            cwd: summary.cwd,
            line1: title,
            isLine1Bold: false,
            label: label,
            elapsedSeconds: elapsed,
            line2: line2(label: label, elapsedSeconds: elapsed, runningMark: summary.live),
            showsRunningMark: summary.live,
            lastPrompt: prompt,
            leading: .star(isStarred: isStarred),
            primaryButton: primary,
            branchButton: branch,
            headerTitle: title,
            headerSubtitle: headerSubtitle(cwd: summary.cwd, home: home, elapsedSeconds: elapsed)
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

    /// The History section's rows (§4.6): the search result minus every
    /// conversation whose session_id matches a Running row (any tracked
    /// agent — the exclusion applies on every render), starred first, each
    /// group in the result's own order (`updated_at` descending, as search
    /// returns it).
    public static func historyRows(
        results: [ConversationSummary]?,
        agents: [Agent],
        stars: Set<String>,
        now: Int64,
        home: String?
    ) -> [UnifiedListRow] {
        guard let results else { return [] }
        // Only agents that produce a Running row exclude (an unknown status
        // has no row, so its conversation must not vanish from both sections).
        let runningIDs = Set(
            agents.filter { $0.status != .unknown }.map(\.sessionId).filter { !$0.isEmpty }
        )
        let remaining = results.filter { !runningIDs.contains($0.sessionID) }
        let starred = remaining.filter { stars.contains($0.sessionID) }
        let others = remaining.filter { !stars.contains($0.sessionID) }
        return (starred + others).map { summary in
            historyRow(summary: summary, isStarred: stars.contains(summary.sessionID), now: now, home: home)
        }
    }
}
