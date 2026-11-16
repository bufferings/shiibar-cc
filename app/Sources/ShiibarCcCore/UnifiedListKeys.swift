// Key interpretation for the popover and the window (DESIGN.md §4.5 "key
// operations" table, §4.6 text size / hit navigation / ⌘F, §8.49). The app's
// key monitor runs BEFORE the focused view (also when the search field has
// focus), turns the NSEvent into `ListKey` + `ListKeyModifiers`, builds the
// context from `UnifiedListState.keyContext(...)`, and obeys the decision:
//   - `.passThrough`: hand the event on unchanged (normal text editing in
//     the search field, Tab, ⌘C, Space / Page Down scrolling the
//     conversation pane, ...);
//   - `.passToConversationPane`: hand the event on to the conversation
//     pane's web view, making it the first responder first when it is not
//     (↑ / ↓ on the one-column detail page scroll the conversation);
//   - `.ignore`: swallow the event and do nothing (a key the table assigns
//     but that has no effect in this context — e.g. Esc in the window must
//     not reach the search field, which would clear the query; ↑ / ↓ in the
//     search field must not move its caret);
//   - `.perform(command)`: swallow and run `UnifiedListState.perform`.
// The table has two columns: "the search field has focus" and "the list has
// focus" (= the search field does not have focus, including the detail page
// and the conversation pane having focus). The existing
// `ConversationsKeyCommands` grammar (text size, ⌘G / ⇧⌘G, ⌘F) is folded in
// here.

import Foundation

/// The keys the table assigns. Every other key arrives as `.other`.
public enum ListKey: Equatable, Sendable {
    case upArrow
    case downArrow
    case leftArrow
    case rightArrow
    /// Return and keypad Enter.
    case returnKey
    case escape
    /// Delete (backspace) and forward delete.
    case delete
    /// Any other key, with AppKit's `charactersIgnoringModifiers`.
    case other(charactersIgnoringModifiers: String?)
}

/// Device-independent modifiers. The app must NOT map AppKit's `.function`
/// / `.numericPad` flags here: arrow keys always carry them.
public struct ListKeyModifiers: OptionSet, Equatable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = ListKeyModifiers(rawValue: 1 << 0)
    public static let shift = ListKeyModifiers(rawValue: 1 << 1)
    public static let option = ListKeyModifiers(rawValue: 1 << 2)
    public static let control = ListKeyModifiers(rawValue: 1 << 3)
}

/// Which page is showing in one-column mode (§4.5 "switching by width").
/// Always `.list` in two-column mode.
public enum ListPage: Equatable, Sendable {
    case list
    case detail
}

/// Everything the key decision depends on.
public struct ListKeyContext: Equatable, Sendable {
    public var columns: ColumnMode
    public var page: ListPage
    /// The search field has keyboard focus (false = "the list has focus").
    public var searchFieldFocused: Bool
    /// The list shows at least one row.
    public var hasRows: Bool
    public var hasSelection: Bool
    /// The selected row's primary button (Jump / Resume) is enabled.
    public var primaryEnabled: Bool
    /// The selected row's Branch is enabled.
    public var branchEnabled: Bool
    /// The conversation pane is on screen (one column: detail page; two
    /// columns: a row is selected).
    public var conversationPaneVisible: Bool
    /// Keys go to the popover (true) or to the window (false).
    public var isPopover: Bool
    /// An input method has uncommitted (marked) text.
    public var hasMarkedText: Bool

    public init(
        columns: ColumnMode,
        page: ListPage,
        searchFieldFocused: Bool,
        hasRows: Bool,
        hasSelection: Bool,
        primaryEnabled: Bool,
        branchEnabled: Bool,
        conversationPaneVisible: Bool,
        isPopover: Bool,
        hasMarkedText: Bool
    ) {
        self.columns = columns
        self.page = page
        self.searchFieldFocused = searchFieldFocused
        self.hasRows = hasRows
        self.hasSelection = hasSelection
        self.primaryEnabled = primaryEnabled
        self.branchEnabled = branchEnabled
        self.conversationPaneVisible = conversationPaneVisible
        self.isPopover = isPopover
        self.hasMarkedText = hasMarkedText
    }
}

/// What a consumed key does.
public enum ListKeyCommand: Equatable, Sendable {
    /// ↑ with list focus on the list (one-column list page, two columns):
    /// previous row.
    case moveUp
    /// ↓ with list focus on the list: next row.
    case moveDown
    /// ⌥↑ with list focus on the one-column detail page: show the previous
    /// row's conversation (the selection moves too).
    case previousConversation
    /// ⌥↓ with list focus on the one-column detail page: the next row's
    /// conversation.
    case nextConversation
    /// Enter in the search field: focus moves to the list; with no
    /// selection, the first row is selected.
    case enterFromSearchField
    /// Enter with list focus: the selected row's primary button (Jump /
    /// Resume).
    case primary
    /// ⌘Enter with list focus: the selected row's Branch.
    case branch
    /// → with list focus on the one-column list page: open the detail page.
    case openDetail
    /// ← with list focus on the one-column detail page: back to the list
    /// page.
    case back
    /// ⌘G: next hit in the conversation.
    case nextMatch
    /// ⇧⌘G: previous hit.
    case previousMatch
    /// ⌘F with list focus: focus the search field (one-column detail page:
    /// back to the list page first).
    case focusSearch
    /// Esc in the popover.
    case closePopover
    case increaseTextSize
    case decreaseTextSize
    case resetTextSize
}

public enum ListKeyDecision: Equatable, Sendable {
    case passThrough
    /// Hand the event on to the conversation pane's web view (made the first
    /// responder first when it is not), which scrolls the conversation with
    /// the key (its standard behavior).
    case passToConversationPane
    case ignore
    case perform(ListKeyCommand)
}

public enum UnifiedListKeys {
    /// Decide what a key event does (§4.5 table). Rules:
    /// - marked text: every key goes to the input method (Enter commits,
    ///   ↑ / ↓ pick candidates);
    /// - ↑ / ↓ without modifiers: consumed with no effect in the search
    ///   field; with list focus on the one-column detail page, handed to the
    ///   conversation pane (scrolling, like Space and Page Up / Page Down);
    ///   with list focus elsewhere, always consumed (moving at an edge, or
    ///   with no rows, does nothing);
    /// - ⌥↑ / ⌥↓: text editing in the search field; with list focus, the
    ///   previous / next conversation on the one-column detail page (at an
    ///   end, nothing), consumed with no effect elsewhere;
    /// - Enter in the search field: focus to the list (selecting the first
    ///   row when nothing is selected); with no rows, consumed with no
    ///   effect. Enter with list focus: the primary button when a row is
    ///   selected and the button is enabled; otherwise consumed with no
    ///   effect;
    /// - ⌘Enter: consumed with no effect in the search field; with list
    ///   focus, Branch when a row is selected and Branch is enabled,
    ///   otherwise consumed with no effect;
    /// - → / ← without modifiers: text editing in the search field; with
    ///   list focus, open the detail page / back to the list page in one
    ///   column, consumed with no effect elsewhere;
    /// - a character or Delete: not assigned in either focus state — text
    ///   editing in the search field; with list focus the focused view gets
    ///   it unchanged (the conversation pane scrolls with Space; see
    ///   `isTyping` for the app's no-beep guard);
    /// - Esc: closes the popover; consumed with no effect in the window;
    /// - ⌘G / ⇧⌘G: only while the conversation pane is visible (consumed
    ///   otherwise);
    /// - ⌘F: with list focus only (consumed with no effect in the search
    ///   field); ⌘+ / ⌘− / ⌘0: always;
    /// - any other key or modifier combination passes through.
    public static func decide(key: ListKey, modifiers: ListKeyModifiers, context: ListKeyContext) -> ListKeyDecision {
        if context.hasMarkedText {
            return .passThrough
        }
        let inSearchField = context.searchFieldFocused
        switch key {
        case .upArrow, .downArrow:
            let onDetailPage = context.columns == .one && context.page == .detail
            if modifiers == [.option] {
                if inSearchField { return .passThrough }
                guard onDetailPage else { return .ignore }
                return .perform(key == .upArrow ? .previousConversation : .nextConversation)
            }
            guard modifiers.isEmpty else { return .passThrough }
            if inSearchField { return .ignore }
            if onDetailPage { return .passToConversationPane }
            return .perform(key == .upArrow ? .moveUp : .moveDown)
        case .returnKey:
            if modifiers.isEmpty {
                if inSearchField {
                    return (context.hasSelection || context.hasRows) ? .perform(.enterFromSearchField) : .ignore
                }
                return (context.hasSelection && context.primaryEnabled) ? .perform(.primary) : .ignore
            }
            if modifiers == [.command] {
                if inSearchField { return .ignore }
                return (context.hasSelection && context.branchEnabled) ? .perform(.branch) : .ignore
            }
            return .passThrough
        case .rightArrow:
            guard modifiers.isEmpty, !inSearchField else { return .passThrough }
            let opens = context.columns == .one && context.page == .list && context.hasSelection
            return opens ? .perform(.openDetail) : .ignore
        case .leftArrow:
            guard modifiers.isEmpty, !inSearchField else { return .passThrough }
            let backs = context.columns == .one && context.page == .detail
            return backs ? .perform(.back) : .ignore
        case .delete:
            return .passThrough
        case .escape:
            guard modifiers.isEmpty else { return .passThrough }
            return context.isPopover ? .perform(.closePopover) : .ignore
        case .other(let characters):
            if let command = ConversationsKeyCommands.command(
                charactersIgnoringModifiers: characters,
                hasCommand: modifiers.contains(.command),
                hasShift: modifiers.contains(.shift),
                hasOtherModifiers: modifiers.contains(.option) || modifiers.contains(.control)
            ) {
                switch command {
                case .increaseTextSize: return .perform(.increaseTextSize)
                case .decreaseTextSize: return .perform(.decreaseTextSize)
                case .resetTextSize: return .perform(.resetTextSize)
                case .focusSearch: return inSearchField ? .ignore : .perform(.focusSearch)
                case .nextMatch:
                    return context.conversationPaneVisible ? .perform(.nextMatch) : .ignore
                case .previousMatch:
                    return context.conversationPaneVisible ? .perform(.previousMatch) : .ignore
                }
            }
            return .passThrough
        }
    }

    /// Whether the key types text (a character or Delete, without Command
    /// or Control — Shift and Option still produce characters). `decide`
    /// passes these through; with list focus the table assigns them nothing
    /// (§4.5), so the app swallows them when no view that takes them has
    /// focus (the window itself would answer with the system beep). With the
    /// conversation pane focused they reach the web view (Space scrolls).
    public static func isTyping(key: ListKey, modifiers: ListKeyModifiers) -> Bool {
        guard !modifiers.contains(.command), !modifiers.contains(.control) else { return false }
        switch key {
        case .delete: return true
        case .other(let characters): return isTextInput(characters)
        default: return false
        }
    }

    /// Whether the key produces text: a non-empty string without control
    /// characters (Tab, ...) and outside AppKit's function-key range
    /// (U+F700–U+F8FF: arrows, F-keys, Home, ...).
    static func isTextInput(_ characters: String?) -> Bool {
        guard let characters, !characters.isEmpty else { return false }
        return characters.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            if value < 0x20 || value == 0x7F { return false }
            if (0xF700...0xF8FF).contains(value) { return false }
            return true
        }
    }
}

/// One key hint in the footer or the bottom panel (§4.5 "key hints", §4.6
/// "bottom panel"): a key chip followed by an action name. The hints show
/// the movement keys only; the action keys are shown inside the bottom
/// panel's buttons (`RowButtonKind.shortcut`) while the list has focus.
public struct KeyHint: Equatable, Sendable {
    public let key: String
    public let label: String

    public init(key: String, label: String) {
        self.key = key
        self.label = label
    }

    /// Enter in the search field: focus moves to the list.
    public static let list = KeyHint(key: "\u{21A9}", label: "List")
    public static let move = KeyHint(key: "\u{2191}\u{2193}", label: "Move")
    public static let open = KeyHint(key: "\u{2192}", label: "Open")
    public static let prevNext = KeyHint(key: "\u{2325}\u{2191}\u{2193}", label: "Prev / Next")
    public static let back = KeyHint(key: "\u{2190}", label: "Back")
}

public enum KeyHints {
    /// The list's key hints — §4.5 "key hints": the left side of the
    /// one-column list page's bottom panel, and the left column's footer in
    /// two columns:
    /// - the search field has focus: `↩ List` only (one and two columns);
    /// - the list has focus: `↑↓ Move`, then — one column only, and only
    ///   while a row is selected — `→ Open`.
    public static func footer(columns: ColumnMode, hasSelection: Bool, listFocused: Bool) -> [KeyHint] {
        guard listFocused else { return [.list] }
        var hints: [KeyHint] = [.move]
        if columns == .one && hasSelection {
            hints.append(.open)
        }
        return hints
    }

    /// The conversation pane's bottom panel, left side (§4.6): `⌥↑↓ Prev /
    /// Next` / `← Back` in the one-column detail page, nothing in two
    /// columns. (The one-column list page's bottom panel uses `footer`.)
    public static func bottomPanel(columns: ColumnMode) -> [KeyHint] {
        columns == .one ? [.prevNext, .back] : []
    }
}
