// The command-key grammar of the popover and the window: the text size of
// the popover and the window (⌘= / ⌘+ / ⌘− / ⌘0, decided by the typed
// character — DESIGN.md §4.5 "text size"), the conversation pane's find
// navigation (⌘G = next match / ⇧⌘G = previous match, §4.6 / §8.38(7)),
// ⌘F and ⌘R (Refresh, §4.5 "key operations" / §4.6). `UnifiedListKeys.decide` folds this in for the popover and the window
// (§4.5 "key operations"); this mapping decides — kept in Core so "what
// consumes which key" is pinned by tests, including the pass-throughs (⌘C
// must never be captured here; it belongs to the message pane).

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
    /// ⌘R — Refresh, the same operation as the ⌄ menu's Refresh (§4.5
    /// "key operations" / "⌄ menu", §4.6).
    case refresh
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
        case "r":
            return hasShift ? nil : .refresh
        default:
            return nil
        }
    }
}
