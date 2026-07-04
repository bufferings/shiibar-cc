// Daemon reconnect backoff (DESIGN.md §4.5/§9): 1s, doubling, capped at 30s.

import Foundation

public enum ReconnectBackoff {
    public static let capSeconds: Double = 30

    /// Delay before reconnect attempt number `attempt` (0-based: `attempt`
    /// 0 is the first retry after a disconnect). §9: "1s -> doubling ->
    /// capped at 30s", i.e. 1, 2, 4, 8, 16, 30, 30, ...
    public static func delay(forAttempt attempt: Int) -> Double {
        guard attempt >= 0 else { return 1 }
        let doubled = pow(2.0, Double(attempt))
        return min(doubled, capSeconds)
    }

    /// The first `count` delays, for table-driven testing of the whole
    /// sequence at once.
    public static func sequence(count: Int) -> [Double] {
        (0..<count).map(delay(forAttempt:))
    }
}
