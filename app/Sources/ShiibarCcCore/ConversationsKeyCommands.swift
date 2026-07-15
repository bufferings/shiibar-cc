// The Conversations window's key-command grammar (DESIGN.md §4.6): text
// size (⌘+ / ⌘− / ⌘0) and find navigation (⌘G = next match / ⇧⌘G =
// previous match, §8.38(7)). The window-scoped event monitor (app side)
// feeds key facts in; this mapping decides — kept in Core so "what consumes
// which key" is pinned by tests, including the pass-throughs (⌘C must
// never be captured here; it belongs to the message pane).

import Foundation

public enum ConversationsKeyCommand: Equatable {
    case increaseTextSize
    case decreaseTextSize
    case resetTextSize
    /// ⌘G — toward newer hits (the › segment).
    case nextMatch
    /// ⇧⌘G — toward older hits (the ‹ segment).
    case previousMatch
    /// ⌘F — focus the search field (§4.6/§8.41).
    case focusSearch
}

public enum ConversationsKeyCommands {
    /// Map a key event to a window command, or nil = pass the event through.
    /// `charactersIgnoringModifiers` is AppKit's value (shift still applies:
    /// shift-g arrives as "G", shift-minus as "_" — which is why ⌘− takes
    /// no shift while ⌘+ does: "+" IS shift-equals on most layouts).
    /// `hasOtherModifiers` = option/control/function chords, never consumed.
    public static func command(
        charactersIgnoringModifiers: String?,
        hasCommand: Bool,
        hasShift: Bool,
        hasOtherModifiers: Bool
    ) -> ConversationsKeyCommand? {
        guard hasCommand, !hasOtherModifiers, let key = charactersIgnoringModifiers else { return nil }
        switch key {
        case "+", "=":
            return .increaseTextSize
        case "-":
            return .decreaseTextSize
        case "0":
            return .resetTextSize
        case "g":
            return hasShift ? nil : .nextMatch
        case "G":
            // Shift produced the uppercase form; require it for coherence.
            return hasShift ? .previousMatch : nil
        case "f":
            return hasShift ? nil : .focusSearch
        default:
            return nil
        }
    }
}
