@testable import ShiibarCcCore

/// Shared fixtures for the unified-list tests (M44 T1). Paths use the neutral
/// `/Users/example` home.
enum UL {
    static let home = "/Users/example"
    static let now: Int64 = 10_000
    /// §4.6 / §9: a Running row disappearing refetches History now and
    /// once more 2 seconds later.
    static let endedRowRefetches: [UnifiedListEffect] = [.refetchHistory, .refetchHistoryLater(afterSeconds: 2)]

    static func agent(
        _ target: String,
        status: AgentStatus = .idle,
        session: String,
        cwd: String = "/Users/example/demo/api",
        task: String? = nil,
        message: String? = nil,
        unreviewed: Bool = false,
        createdAt: Int64 = 0,
        since: Int64 = 9_760
    ) -> Agent {
        Agent(
            target: target,
            status: status,
            unreviewed: unreviewed,
            sessionId: session,
            cwd: cwd,
            task: task,
            message: message,
            createdAt: createdAt,
            since: since,
            lastSeen: 0
        )
    }

    static func summary(
        _ sessionID: String,
        cwd: String? = "/Users/example/demo/web",
        title: String? = "Title",
        updatedAt: Int64 = 9_000,
        live: Bool = false,
        lastPrompt: String? = nil
    ) -> ConversationSummary {
        ConversationSummary(
            sessionID: sessionID,
            cwd: cwd,
            title: title,
            updatedAt: updatedAt,
            live: live,
            lastPrompt: lastPrompt
        )
    }
}
