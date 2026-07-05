// Wire types mirroring the shiibar-ccd protocol (DESIGN.md §4.2). This is a
// hand-written Swift mirror of `shiibar-cc-proto` (Rust crates aren't shared
// with the Swift app, DESIGN.md §8.5 — NDJSON itself is the stable boundary).
//
// Forward compatibility rule (§4.2): a client must ignore unknown `event` /
// `status` / fields rather than fail the whole line. Every enum below has an
// `unknown` case reached only via a custom `Decodable` implementation (never
// producing a decode error for a value it doesn't recognize).

import Foundation

/// Agent status (§3.1): `idle` / `working` / `waiting`. `.unknown` is the
/// forward-compat fallback for a status string this build doesn't
/// recognize; shiibar-ccd itself never emits it.
public enum AgentStatus: String, Equatable, Sendable {
    case idle
    case working
    case waiting
    case unknown
}

extension AgentStatus: Decodable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentStatus(rawValue: raw) ?? .unknown
    }
}

extension AgentStatus: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Why an entry was deleted (§3.6, §4.2). `.unknown` is both the
/// `#[serde(other)]`-equivalent fallback for a reason string this build
/// doesn't recognize, and what a pre-M4 daemon's `agent_removed` (no
/// `reason` field at all) decodes to. Per §4.2, `.unknown` is treated the
/// same as `.remove` by consumers (see `NotificationCleanupRule`).
public enum RemovalReason: String, Equatable, Sendable {
    case sessionEnd = "session_end"
    case stale
    case remove
    case prune
    case unknown
}

extension RemovalReason: Decodable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RemovalReason(rawValue: raw) ?? .unknown
    }
}

/// A single agent entry as seen over the wire (§4.2 `list` / `snapshot` /
/// `status_changed`).
public struct Agent: Equatable, Decodable, Sendable {
    public let target: String
    public let status: AgentStatus
    public let unreviewed: Bool
    public let sessionId: String
    public let cwd: String
    public let task: String?
    public let message: String?
    /// Last assistant reply as of the most recent completion (§3.6),
    /// truncated to 200 chars (§9). `nil` while `working`, or before any
    /// completion has happened yet.
    public let lastAssistantMessage: String?
    public let since: Int64
    public let lastSeen: Int64

    private enum CodingKeys: String, CodingKey {
        case target, status, unreviewed
        case sessionId = "session_id"
        case cwd, task, message
        case lastAssistantMessage = "last_assistant_message"
        case since
        case lastSeen = "last_seen"
    }

    public init(
        target: String,
        status: AgentStatus,
        unreviewed: Bool,
        sessionId: String,
        cwd: String,
        task: String?,
        message: String?,
        lastAssistantMessage: String? = nil,
        since: Int64,
        lastSeen: Int64
    ) {
        self.target = target
        self.status = status
        self.unreviewed = unreviewed
        self.sessionId = sessionId
        self.cwd = cwd
        self.task = task
        self.message = message
        self.lastAssistantMessage = lastAssistantMessage
        self.since = since
        self.lastSeen = lastSeen
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decode(String.self, forKey: .target)
        status = try container.decode(AgentStatus.self, forKey: .status)
        unreviewed = try container.decode(Bool.self, forKey: .unreviewed)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        cwd = try container.decode(String.self, forKey: .cwd)
        task = try container.decodeIfPresent(String.self, forKey: .task)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        lastAssistantMessage = try container.decodeIfPresent(String.self, forKey: .lastAssistantMessage)
        since = try container.decode(Int64.self, forKey: .since)
        lastSeen = try container.decode(Int64.self, forKey: .lastSeen)
    }
}

/// Events pushed on a `subscribe` connection (§4.2). `.unknown` is the
/// forward-compat fallback for an `event` value this build doesn't
/// recognize (a future daemon version).
public enum SubscribeEvent: Equatable {
    case snapshot(agents: [Agent])
    case statusChanged(agent: Agent)
    case agentRemoved(target: String, reason: RemovalReason)
    case unknown
}

extension SubscribeEvent: Decodable {
    private enum CodingKeys: String, CodingKey {
        case event, agents, agent, target, reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let event = try container.decode(String.self, forKey: .event)
        switch event {
        case "snapshot":
            self = .snapshot(agents: try container.decode([Agent].self, forKey: .agents))
        case "status_changed":
            self = .statusChanged(agent: try container.decode(Agent.self, forKey: .agent))
        case "agent_removed":
            let target = try container.decode(String.self, forKey: .target)
            let reason = try container.decodeIfPresent(RemovalReason.self, forKey: .reason) ?? .unknown
            self = .agentRemoved(target: target, reason: reason)
        default:
            self = .unknown
        }
    }
}
