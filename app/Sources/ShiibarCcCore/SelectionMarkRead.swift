// Lowering the unreviewed flag by a lasting selection, and the pieces the
// app needs around a target change (DESIGN.md §4.5 "operations that lower
// the unreviewed flag", "desktop notifications": `rekey` and notification
// clicks; §8.66):
//  1. When a Running row the user selected has stayed selected for the §9
//     time, the app runs `shiibar-cc seen <target>` if the row is unreviewed
//     at that moment. Selecting does not lower it by itself.
//  2. A `rekey` moves an entry to a new target; the app remembers old -> new
//     for the notifications it already delivered.
//  3. A `seen` the app runs can race a `rekey` of its target; the app then
//     sends `seen` once more to the new target.
//  4. A notification click either jumps (the target can be jumped to) or
//     selects the row in the list.

import Foundation

public enum SelectionMarkRead {
    /// §9: how long a selection the user made must last before the row's
    /// unreviewed flag is lowered.
    public static let delaySeconds: Double = 1

    /// How one event touched the selection, as far as the timer cares.
    public enum Trigger: Equatable, Sendable {
        /// An operation §4.5 counts as the user selecting the row: a row
        /// click (a gray selected row's click and a double-click included),
        /// ↑ / ↓, Enter selecting the first row, switching to the previous
        /// / next conversation on the detail page, Enter showing the
        /// conversation of a row that cannot be jumped to, and a
        /// notification click that selects the row.
        case userSelection
        /// A click on the selected row shown in accent: it deselects the
        /// row (once no double-click can follow), so the timer stops at
        /// the click.
        case deselectClick
        /// The popover or the window closed.
        case surfaceClosed
        /// The selected entry moved to a new target (`rekey`): the
        /// selection carries over and a running timer keeps running.
        case rekey
        /// Anything else: a selection kept from before, or one carried over
        /// by the list's own rules (e.g. a History row that moved into
        /// Running after Resume).
        case other
    }

    public enum Decision: Equatable, Sendable {
        /// Start measuring from now (a running timer starts over).
        case start
        case cancel
        /// Leave the timer as it is.
        case keep
    }

    /// Whether the event starts, cancels, or keeps the timer (§4.5
    /// "operations that lower the unreviewed flag"). `before` / `after`
    /// are the selected row's key around the event.
    ///
    /// - A user selection starts the timer only on a Running row; on any
    ///   other row there is nothing to lower, so a running timer stops.
    /// - Closing the surface and a deselecting click stop it.
    /// - A `rekey` keeps it (the selection moved with the entry).
    /// - Otherwise the timer keeps running while the selection stays on the
    ///   same row, and stops when the selection moved or was cleared. A
    ///   selection the user did not make never starts it.
    public static func decide(trigger: Trigger, before: UnifiedRowKey?, after: UnifiedRowKey?) -> Decision {
        switch trigger {
        case .userSelection:
            if case .running = after { return .start }
            return .cancel
        case .deselectClick, .surfaceClosed:
            return .cancel
        case .rekey:
            return .keep
        case .other:
            return before == after ? .keep : .cancel
        }
    }

    /// When the time has passed: the target to run `seen` for, or nil.
    /// Only a Running row that is unreviewed at this moment (§4.5: whether
    /// the row is unreviewed is decided when the time has passed, not when
    /// it was selected). Not while the selected row has ended and awaits
    /// the History refetch — its entry is gone.
    public static func targetToMarkRead(selection: UnifiedRowKey?, awaitingRefetch: Bool, agents: [Agent]) -> String? {
        guard !awaitingRefetch, case .running(let target) = selection,
              agents.contains(where: { $0.target == target && $0.unreviewed }) else { return nil }
        return target
    }
}

/// Old target -> new target for every `rekey` the app received (§4.5
/// "desktop notifications"). A delivered notification keeps the target it
/// was delivered for; its click reads it through this map. Kept until the
/// app quits.
///
/// The destination of the most recent re-key is always terminal: it is an
/// entry's current target, so it has no outgoing mapping. That keeps the
/// map free of cycles, and every target that was ever a source of an entry
/// resolves to that entry's current target.
public struct TargetRekeyMap: Equatable, Sendable {
    private var next: [String: String] = [:]

    public init() {}

    public var count: Int { next.count }

    /// An entry moved from `from` to `to`. `to` is now an entry's current
    /// target, so a mapping out of it (left from when an earlier re-key
    /// moved an entry away from `to`) is removed first.
    public mutating func record(from: String, to: String) {
        guard from != to else { return }
        next.removeValue(forKey: to)
        next[from] = to
    }

    /// An entry is registered or reported under `target`: `target` is a
    /// current target, not a former one. A mapping out of it (a new session
    /// that reuses an old `process:<pid>` target) is removed, so the new
    /// entry is not redirected to another entry.
    public mutating func targetIsCurrent(_ target: String) {
        next.removeValue(forKey: target)
    }

    /// The current target of `target`: the mappings followed one after
    /// another (A -> B, then B -> C reads A as C). The walk is bounded by
    /// the number of mappings as a safety net; `record` never creates a
    /// cycle.
    public func resolve(_ target: String) -> String {
        var current = target
        var steps = 0
        while steps < next.count, let following = next[current] {
            current = following
            steps += 1
        }
        return current
    }

    /// Every former target that resolves to `target` (`target` itself not
    /// included), sorted: the targets an entry's notifications may have
    /// been delivered under before its re-keys.
    public func sources(resolvingTo target: String) -> [String] {
        next.keys.filter { $0 != target && resolve($0) == target }.sorted()
    }
}

/// The `seen` subprocesses the app runs, for the resend after a `rekey`
/// (§4.5 "operations that lower the unreviewed flag": a `rekey` of the
/// target between the start and the end of a `seen` makes the app send
/// `seen` once more to the new target when it has finished, if that entry
/// is unreviewed). A `rekey` outside that period sends nothing, so a flag
/// raised later is not lowered.
public struct SeenRequestTracker: Equatable, Sendable {
    private struct Request: Equatable, Sendable {
        /// The target the request currently refers to: its own target, or
        /// the latest `rekey` of it while it runs.
        var current: String
        var rekeyed: Bool
    }

    private var requests: [Int: Request] = [:]
    private var nextID = 0

    public init() {}

    /// A `seen` for `target` started; pass the returned id to `finished`.
    public mutating func started(target: String) -> Int {
        nextID += 1
        requests[nextID] = Request(current: target, rekeyed: false)
        return nextID
    }

    /// A `rekey` arrived: every running request for `from` now refers to
    /// `to`.
    public mutating func rekeyed(from: String, to: String) {
        for (id, request) in requests where request.current == from {
            requests[id] = Request(current: to, rekeyed: true)
        }
    }

    /// The `seen` with this id ended: the target to send `seen` to once
    /// more, or nil — only when its target was rekeyed while it ran and the
    /// new target's entry is unreviewed now.
    public mutating func finished(id: Int, agents: [Agent]) -> String? {
        guard let request = requests.removeValue(forKey: id), request.rekeyed,
              agents.contains(where: { $0.target == request.current && $0.unreviewed }) else { return nil }
        return request.current
    }

    /// Whether any `seen` is running (for tests).
    public var isEmpty: Bool { requests.isEmpty }
}

/// What a notification click does with its target, after reading it
/// through the `rekey` map (§4.5 "notification click"): jump when the app
/// can jump to the target, otherwise select the Running row in the list.
public enum NotificationClickAction: Equatable, Sendable {
    /// Run `shiibar-cc focus <target>`.
    case focus(target: String)
    /// Open the surface and select the row (`UnifiedListEvent.notificationClicked`).
    case selectRow(target: String)

    public static func decide(target: String) -> NotificationClickAction {
        TargetJumpability.canJump(target) ? .focus(target: target) : .selectRow(target: target)
    }
}

/// How the app handles an `agent_removed` (§4.2, §4.5 "desktop
/// notifications"): a `rekey` with its new target moves the entry; every
/// other event removes it. A `rekey` without `to` is malformed and is a
/// removal swept like `remove` (§4.2: an unknown reason counts as
/// `remove`).
public enum AgentRemovalHandling: Equatable, Sendable {
    case rekey(to: String)
    /// Remove the entry; `sweepReason` is the reason for the notification
    /// cleanup rule (`NotificationCleanupRule`).
    case remove(sweepReason: RemovalReason)

    public static func decide(reason: RemovalReason, to: String?) -> AgentRemovalHandling {
        if reason == .rekey {
            if let to { return .rekey(to: to) }
            return .remove(sweepReason: .remove)
        }
        return .remove(sweepReason: reason)
    }

    /// The agent table after a `rekey` from `from` to `to`: when an entry
    /// under `to` already exists, the one under `from` is dropped (the
    /// daemon merged them); otherwise the entry under `from` takes `to`
    /// with every other attribute kept.
    public static func agentsAfterRekey(_ agents: [Agent], from: String, to: String) -> [Agent] {
        guard from != to else { return agents }
        if agents.contains(where: { $0.target == to }) {
            return agents.filter { $0.target != from }
        }
        return agents.map { $0.target == from ? $0.withTarget(to) : $0 }
    }
}
