// Decoding for the `shiibar-cc conversations` CLI JSON (DESIGN.md §4.4/§4.6).
// The app is a display client over the CLI: it shells out to `conversations
// search|show|index --json` and decodes these shapes. The JSON is the
// stable public contract (snake_case keys, epoch seconds, unknown fields
// ignored — §4.2's forward-compat rule applied to conversations); the DB
// schema behind it is private to the Rust conversations module.

import Foundation

/// One row of `conversations search --json`
/// (`{"session_id","cwd","title","updated_at","live"}`, §4.4). `title` is
/// nullable — the folder-label fallback is the display side's job (§4.6).
public struct ConversationSummary: Codable, Equatable, Identifiable {
    public let sessionID: String
    public let cwd: String?
    public let title: String?
    public let updatedAt: Int64
    public let live: Bool

    public var id: String { sessionID }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd
        case title
        case updatedAt = "updated_at"
        case live
    }

    public init(sessionID: String, cwd: String?, title: String?, updatedAt: Int64, live: Bool) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.title = title
        self.updatedAt = updatedAt
        self.live = live
    }
}

/// The `conversations search --json` envelope (`{"conversations":[...]}`).
public struct ConversationSearchResult: Codable, Equatable {
    public let conversations: [ConversationSummary]

    public init(conversations: [ConversationSummary]) {
        self.conversations = conversations
    }

    /// Decode one `search --json` line. Returns nil on malformed input
    /// (the caller keeps the previous list — §4.6's "a transient failure
    /// mid-typing must not wipe the list").
    public static func decode(_ jsonLine: String) -> ConversationSearchResult? {
        guard let data = jsonLine.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ConversationSearchResult.self, from: data)
    }
}

/// One message of `conversations show --json`
/// (`{"seq","role"("user"|"assistant"),"text"}`, §4.4). `text` is the full
/// message — truncation/folding is the display side's job (§4.6).
public struct ConversationMessage: Codable, Equatable, Identifiable {
    public let seq: Int64
    public let role: String
    public let text: String

    public var id: Int64 { seq }

    enum CodingKeys: String, CodingKey {
        case seq
        case role
        case text
    }

    public init(seq: Int64, role: String, text: String) {
        self.seq = seq
        self.role = role
        self.text = text
    }
}

/// The `conversations show --json` payload
/// (`{"session_id","cwd","title","messages":[...]}`, §4.4).
public struct ConversationDetail: Codable, Equatable {
    public let sessionID: String
    public let cwd: String?
    public let title: String?
    public let messages: [ConversationMessage]

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd
        case title
        case messages
    }

    public init(sessionID: String, cwd: String?, title: String?, messages: [ConversationMessage]) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.title = title
        self.messages = messages
    }

    public static func decode(_ jsonLine: String) -> ConversationDetail? {
        guard let data = jsonLine.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ConversationDetail.self, from: data)
    }
}

/// One `conversations index --json` progress line (§4.4). `start` can appear
/// more than once in a stream and counters are non-monotonic (a build owner
/// hands off to another — §4.6's relay), so a consumer must always render
/// the latest line rather than assume progress only grows.
public enum IndexProgressEvent: Equatable {
    case start(total: Int)
    case progress(done: Int, total: Int)
    case done(indexed: Int, removed: Int)
    case error(message: String)

    private struct Raw: Decodable {
        let event: String
        let total: Int?
        let done: Int?
        let indexed: Int?
        let removed: Int?
        let message: String?
    }

    /// Decode one NDJSON line. Returns nil for a blank or malformed line
    /// (skipped, not fatal).
    public static func decode(_ jsonLine: String) -> IndexProgressEvent? {
        let trimmed = jsonLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return nil }
        switch raw.event {
        case "start":
            return .start(total: raw.total ?? 0)
        case "progress":
            return .progress(done: raw.done ?? 0, total: raw.total ?? 0)
        case "done":
            return .done(indexed: raw.indexed ?? 0, removed: raw.removed ?? 0)
        case "error":
            return .error(message: raw.message ?? "")
        default:
            return nil
        }
    }
}
