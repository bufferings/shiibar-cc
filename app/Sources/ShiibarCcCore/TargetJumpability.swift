// Whether the app can jump to a session's terminal tab, decided from the
// target's prefix alone (DESIGN.md §2, §4.2 "protocol contract": target
// kinds). This is the one piece of target-format knowledge the app holds —
// an exception §2 lists to keeping terminal knowledge in the client's
// terminal modules. The wire carries no "jumpable" field (§8.66), so the
// app decides it here, with the same outcome as the client's routing
// (§4.3 "routing rules"):
//   - `iterm2:` / `apple-terminal:` / `ghostty:` — jumpable;
//   - a target without `:` — jumpable (a bare iTerm2 UUID, the
//     pre-prefix / hand-typed compatible form);
//   - a `wNtNpN:UUID` target — jumpable (a hand-pasted
//     `$ITERM_SESSION_ID`, routed to iTerm2);
//   - `process:` and every other prefix — not jumpable.

import Foundation

public enum TargetJumpability {
    /// The prefixes of the supported terminals (§2).
    static let jumpablePrefixes = ["iterm2:", "apple-terminal:", "ghostty:"]

    /// Whether `target` names a session the app can jump to (§2 / §4.2).
    /// The empty string and `wNtNpN:` with nothing after the `:` are not
    /// jumpable: the client's routing has no session to jump to for them
    /// (§4.3: "no match").
    public static func canJump(_ target: String) -> Bool {
        if jumpablePrefixes.contains(where: { target.hasPrefix($0) }) {
            return true
        }
        guard let colon = target.firstIndex(of: ":") else {
            return !target.isEmpty
        }
        let prefix = target[..<colon]
        let rest = target[target.index(after: colon)...]
        return !rest.isEmpty && isWindowTabPanePrefix(prefix)
    }

    /// `w<digits>t<digits>p<digits>` — the position part of
    /// `$ITERM_SESSION_ID` (§2, §4.3).
    private static func isWindowTabPanePrefix(_ prefix: Substring) -> Bool {
        var rest = prefix
        for letter in ["w", "t", "p"] as [Character] {
            guard rest.first == letter else { return false }
            rest = rest.dropFirst()
            let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
            guard !digits.isEmpty else { return false }
            rest = rest.dropFirst(digits.count)
        }
        return rest.isEmpty
    }
}
