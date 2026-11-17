import XCTest

@testable import ShiibarCcCore

/// Key interpretation (M44 T1; DESIGN.md §4.5 "key operations" table): every
/// table row × focus location (search field / list) × columns × page ×
/// rows present × selection × button enabled/disabled × marked text ×
/// popover/window, checked against an oracle written row by row from the
/// table.
final class UnifiedListKeysTests: XCTestCase {
    private struct KeyCase {
        let name: String
        let key: ListKey
        let modifiers: ListKeyModifiers
    }

    /// One entry per table row (↑ / ↓, ⌥↑ / ⌥↓, → / ←, ⌘G / ⇧⌘G split; typing as a
    /// letter, a shifted letter, an option character, Space and Delete),
    /// plus ⇧⌘Enter (not assigned) and the text-size grammar.
    private let tableKeys: [KeyCase] = [
        KeyCase(name: "↑", key: .upArrow, modifiers: []),
        KeyCase(name: "↓", key: .downArrow, modifiers: []),
        KeyCase(name: "⌥↑", key: .upArrow, modifiers: [.option]),
        KeyCase(name: "⌥↓", key: .downArrow, modifiers: [.option]),
        KeyCase(name: "Enter", key: .returnKey, modifiers: []),
        KeyCase(name: "⌘Enter", key: .returnKey, modifiers: [.command]),
        KeyCase(name: "⇧⌘Enter", key: .returnKey, modifiers: [.command, .shift]),
        KeyCase(name: "→", key: .rightArrow, modifiers: []),
        KeyCase(name: "←", key: .leftArrow, modifiers: []),
        KeyCase(name: "a", key: .other(charactersIgnoringModifiers: "a"), modifiers: []),
        KeyCase(name: "⇧A", key: .other(charactersIgnoringModifiers: "A"), modifiers: [.shift]),
        KeyCase(name: "⌥a", key: .other(charactersIgnoringModifiers: "a"), modifiers: [.option]),
        KeyCase(name: "Space", key: .other(charactersIgnoringModifiers: " "), modifiers: []),
        KeyCase(name: "Delete", key: .delete, modifiers: []),
        KeyCase(name: "⌘G", key: .other(charactersIgnoringModifiers: "g"), modifiers: [.command]),
        KeyCase(name: "⇧⌘G", key: .other(charactersIgnoringModifiers: "G"), modifiers: [.command, .shift]),
        KeyCase(name: "⌘F", key: .other(charactersIgnoringModifiers: "f"), modifiers: [.command]),
        KeyCase(name: "⌘R", key: .other(charactersIgnoringModifiers: "r"), modifiers: [.command]),
        KeyCase(name: "Esc", key: .escape, modifiers: []),
        KeyCase(name: "⌘+", key: .other(charactersIgnoringModifiers: "+"), modifiers: [.command, .shift]),
        KeyCase(name: "⌘=", key: .other(charactersIgnoringModifiers: "="), modifiers: [.command]),
        KeyCase(name: "⌘−", key: .other(charactersIgnoringModifiers: "-"), modifiers: [.command]),
        KeyCase(name: "⌘0", key: .other(charactersIgnoringModifiers: "0"), modifiers: [.command]),
    ]

    /// The §4.5 table, transcribed: left column = the search field has
    /// focus, right column = the list has focus.
    private func expected(_ name: String, _ c: ListKeyContext) -> ListKeyDecision {
        if c.hasMarkedText { return .passThrough } // everything goes to the input method
        let field = c.searchFieldFocused
        switch name {
        // Search field: nothing (swallowed — no caret move, no selection
        // move, no focus move). List: move the selection; the one-column
        // detail page scrolls the conversation (the pane's standard
        // behavior, like Space and Page Up / Page Down).
        case "↑", "↓":
            if field { return .ignore }
            if c.columns == .one && c.page == .detail { return .passToConversationPane }
            return .perform(name == "↑" ? .moveUp : .moveDown)
        // Search field: text editing (not intercepted). List: the one-column
        // detail page switches to the previous / next row's conversation;
        // nothing anywhere else.
        case "⌥↑", "⌥↓":
            if field { return .passThrough }
            guard c.columns == .one && c.page == .detail else { return .ignore }
            return .perform(name == "⌥↑" ? .previousConversation : .nextConversation)
        case "Enter":
            if field {
                // Focus to the list (selecting the first row when nothing is
                // selected); no rows: nothing.
                return (c.hasSelection || c.hasRows) ? .perform(.enterFromSearchField) : .ignore
            }
            // Jump / Resume, every page; nothing without a selection or
            // with a disabled button.
            return (c.hasSelection && c.primaryEnabled) ? .perform(.primary) : .ignore
        case "⌘Enter":
            // Search field: nothing. List: Branch.
            if field { return .ignore }
            return (c.hasSelection && c.branchEnabled) ? .perform(.branch) : .ignore
        case "⇧⌘Enter":
            return .passThrough
        case "→":
            if field { return .passThrough } // caret movement
            return (c.columns == .one && c.page == .list && c.hasSelection) ? .perform(.openDetail) : .ignore
        case "←":
            if field { return .passThrough }
            return (c.columns == .one && c.page == .detail) ? .perform(.back) : .ignore
        case "a", "⇧A", "⌥a", "Space", "Delete":
            // Search field: text editing. List: the table assigns nothing;
            // the focused view gets the key unchanged (the conversation pane
            // scrolls with Space) and the app swallows it when no view takes
            // it (`isTyping`).
            return .passThrough
        case "⌘G": return c.conversationPaneVisible ? .perform(.nextMatch) : .ignore
        case "⇧⌘G": return c.conversationPaneVisible ? .perform(.previousMatch) : .ignore
        case "⌘F": return field ? .ignore : .perform(.focusSearch)
        // Refresh with either focus and on every page (§4.6).
        case "⌘R": return .perform(.refresh)
        case "Esc": return c.isPopover ? .perform(.closePopover) : .ignore
        case "⌘+", "⌘=": return .perform(.increaseTextSize)
        case "⌘−": return .perform(.decreaseTextSize)
        case "⌘0": return .perform(.resetTextSize)
        default:
            XCTFail("unknown key \(name)")
            return .passThrough
        }
    }

    /// Every reachable context: the detail page exists only in one column
    /// and only with a selection; a selection needs rows except while a
    /// just-ended Running row awaits the refetch (selected but not listed);
    /// buttons are enabled only with a selection.
    private var contexts: [ListKeyContext] {
        var result: [ListKeyContext] = []
        let bools = [false, true]
        for columns in [ColumnMode.one, .two] {
            for page in (columns == .one ? [ListPage.list, .detail] : [.list]) {
                for hasSelection in bools {
                    if page == .detail && !hasSelection { continue }
                    for hasRows in bools {
                        for primaryEnabled in (hasSelection ? bools : [false]) {
                            for branchEnabled in (hasSelection ? bools : [false]) {
                                for searchFieldFocused in bools {
                                    for hasMarkedText in bools {
                                        for isPopover in (columns == .one ? bools : [false]) {
                                            let paneVisible = columns == .two ? hasSelection : page == .detail
                                            result.append(ListKeyContext(
                                                columns: columns, page: page,
                                                searchFieldFocused: searchFieldFocused, hasRows: hasRows,
                                                hasSelection: hasSelection,
                                                primaryEnabled: primaryEnabled, branchEnabled: branchEnabled,
                                                conversationPaneVisible: paneVisible, isPopover: isPopover,
                                                hasMarkedText: hasMarkedText))
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return result
    }

    func testTableRowsAcrossEveryContext() {
        let all = contexts
        // Per focus × marked text (4 combinations): one column list page
        // (no selection 2 rows-states × 2 surfaces + selection 2 × 4 buttons
        // × 2) = 20, detail page 2 × 4 × 2 = 16, two columns 2 + 2 × 4 = 10.
        XCTAssertEqual(all.count, (20 + 16 + 10) * 4)
        for keyCase in tableKeys {
            for context in all {
                XCTAssertEqual(
                    UnifiedListKeys.decide(key: keyCase.key, modifiers: keyCase.modifiers, context: context),
                    expected(keyCase.name, context),
                    "\(keyCase.name) in \(context)")
            }
        }
    }

    /// Unassigned keys and modifier combinations pass through in both focus
    /// states.
    func testUnassignedKeysPassThrough() {
        let cases: [(String, ListKey, ListKeyModifiers)] = [
            ("Tab", .other(charactersIgnoringModifiers: "\t"), []),
            ("⇧Tab", .other(charactersIgnoringModifiers: "\u{19}"), [.shift]),
            ("F5 (function-key range)", .other(charactersIgnoringModifiers: "\u{F708}"), []),
            ("Home (function-key range)", .other(charactersIgnoringModifiers: "\u{F729}"), []),
            ("Page Down (pane scrolling)", .other(charactersIgnoringModifiers: "\u{F72D}"), []),
            ("Space (pane scrolling)", .other(charactersIgnoringModifiers: " "), []),
            ("a", .other(charactersIgnoringModifiers: "a"), []),
            ("Delete", .delete, []),
            ("empty characters", .other(charactersIgnoringModifiers: ""), []),
            ("nil characters", .other(charactersIgnoringModifiers: nil), []),
            ("⌘C (pane copy)", .other(charactersIgnoringModifiers: "c"), [.command]),
            ("⇧⌘C (copy as Markdown)", .other(charactersIgnoringModifiers: "C"), [.command, .shift]),
            ("⌘A", .other(charactersIgnoringModifiers: "a"), [.command]),
            ("⌃a", .other(charactersIgnoringModifiers: "a"), [.control]),
            ("⌘Delete", .delete, [.command]),
            ("⌃Delete", .delete, [.control]),
            ("⇧Enter", .returnKey, [.shift]),
            ("⌥Enter", .returnKey, [.option]),
            ("⌃⌘Enter", .returnKey, [.command, .control]),
            ("⇧⌘Enter (not assigned)", .returnKey, [.command, .shift]),
            ("⌘↑", .upArrow, [.command]),
            ("⇧↓ (extend text selection)", .downArrow, [.shift]),
            ("⇧⌥↑ (extend text selection)", .upArrow, [.option, .shift]),
            ("⌘⌥↓", .downArrow, [.option, .command]),
            ("⌘→", .rightArrow, [.command]),
            ("⇧←", .leftArrow, [.shift]),
            ("⌥→", .rightArrow, [.option]),
            ("⌘Esc", .escape, [.command]),
            ("⌥⌘G", .other(charactersIgnoringModifiers: "g"), [.command, .option]),
            ("⌥⌘F", .other(charactersIgnoringModifiers: "f"), [.command, .option]),
            ("⇧⌘F", .other(charactersIgnoringModifiers: "F"), [.command, .shift]),
            ("⇧⌘R", .other(charactersIgnoringModifiers: "R"), [.command, .shift]),
            ("⌥⌘R", .other(charactersIgnoringModifiers: "r"), [.command, .option]),
            ("⌃⌘R", .other(charactersIgnoringModifiers: "r"), [.command, .control]),
            ("r", .other(charactersIgnoringModifiers: "r"), []),
        ]
        for searchFieldFocused in [false, true] {
            for (columns, page) in [(ColumnMode.one, ListPage.list), (.one, .detail), (.two, .list)] {
                let context = ListKeyContext(
                    columns: columns, page: page, searchFieldFocused: searchFieldFocused, hasRows: true,
                    hasSelection: true, primaryEnabled: true, branchEnabled: true,
                    conversationPaneVisible: columns == .two || page == .detail,
                    isPopover: columns == .one, hasMarkedText: false)
                for (name, key, modifiers) in cases {
                    XCTAssertEqual(UnifiedListKeys.decide(key: key, modifiers: modifiers, context: context), .passThrough,
                                   "\(name), search field focused: \(searchFieldFocused), \(columns) \(page)")
                }
            }
        }
    }

    /// §4.5 "key operations": ⌘R runs Refresh while the search field has
    /// focus, while the list has focus and on the one-column detail page,
    /// in the popover and in the window; while an input method has
    /// uncommitted text it goes to the input method, like every other key.
    func testCommandRRefreshesInEveryFocusAndPage() {
        struct Case {
            let name: String
            let columns: ColumnMode
            let page: ListPage
            let searchFieldFocused: Bool
            let hasMarkedText: Bool
            let isPopover: Bool
            let expected: ListKeyDecision
        }
        let cases = [
            Case(name: "popover list page, search field", columns: .one, page: .list, searchFieldFocused: true,
                 hasMarkedText: false, isPopover: true, expected: .perform(.refresh)),
            Case(name: "popover list page, list", columns: .one, page: .list, searchFieldFocused: false,
                 hasMarkedText: false, isPopover: true, expected: .perform(.refresh)),
            Case(name: "popover detail page", columns: .one, page: .detail, searchFieldFocused: false,
                 hasMarkedText: false, isPopover: true, expected: .perform(.refresh)),
            Case(name: "window two columns, search field", columns: .two, page: .list, searchFieldFocused: true,
                 hasMarkedText: false, isPopover: false, expected: .perform(.refresh)),
            Case(name: "window two columns, list", columns: .two, page: .list, searchFieldFocused: false,
                 hasMarkedText: false, isPopover: false, expected: .perform(.refresh)),
            Case(name: "window one-column detail page", columns: .one, page: .detail, searchFieldFocused: false,
                 hasMarkedText: false, isPopover: false, expected: .perform(.refresh)),
            Case(name: "marked text in the search field", columns: .one, page: .list, searchFieldFocused: true,
                 hasMarkedText: true, isPopover: true, expected: .passThrough),
        ]
        for c in cases {
            let context = ListKeyContext(
                columns: c.columns, page: c.page, searchFieldFocused: c.searchFieldFocused, hasRows: true,
                hasSelection: c.page == .detail, primaryEnabled: c.page == .detail, branchEnabled: c.page == .detail,
                conversationPaneVisible: c.page == .detail, isPopover: c.isPopover, hasMarkedText: c.hasMarkedText)
            XCTAssertEqual(UnifiedListKeys.decide(key: .other(charactersIgnoringModifiers: "r"), modifiers: [.command],
                                                  context: context), c.expected, c.name)
        }
    }

    func testMarkedTextPassesEveryKey() {
        for searchFieldFocused in [false, true] {
            let context = ListKeyContext(
                columns: .two, page: .list, searchFieldFocused: searchFieldFocused, hasRows: true,
                hasSelection: true, primaryEnabled: true, branchEnabled: true,
                conversationPaneVisible: true, isPopover: false, hasMarkedText: true)
            let keys: [ListKey] = [.upArrow, .downArrow, .leftArrow, .rightArrow, .returnKey, .escape, .delete,
                                   .other(charactersIgnoringModifiers: "a")]
            for key in keys {
                XCTAssertEqual(UnifiedListKeys.decide(key: key, modifiers: [], context: context), .passThrough, "\(key)")
            }
            XCTAssertEqual(UnifiedListKeys.decide(key: .returnKey, modifiers: [.command], context: context), .passThrough)
        }
    }

    /// The keys the app swallows with list focus when no view that takes
    /// typing has focus (§4.5 "typing / Delete: nothing" with list focus).
    func testTypingClassification() {
        let typing: [(String, ListKey, ListKeyModifiers)] = [
            ("a", .other(charactersIgnoringModifiers: "a"), []),
            ("⇧A", .other(charactersIgnoringModifiers: "A"), [.shift]),
            ("⌥a", .other(charactersIgnoringModifiers: "a"), [.option]),
            ("Space", .other(charactersIgnoringModifiers: " "), []),
            ("Delete", .delete, []),
            ("⇧Delete", .delete, [.shift]),
        ]
        for (name, key, modifiers) in typing {
            XCTAssertTrue(UnifiedListKeys.isTyping(key: key, modifiers: modifiers), name)
        }
        let notTyping: [(String, ListKey, ListKeyModifiers)] = [
            ("⌘C", .other(charactersIgnoringModifiers: "c"), [.command]),
            ("⌃a", .other(charactersIgnoringModifiers: "a"), [.control]),
            ("⌘Delete", .delete, [.command]),
            ("Tab", .other(charactersIgnoringModifiers: "\t"), []),
            ("Page Down (function-key range)", .other(charactersIgnoringModifiers: "\u{F72D}"), []),
            ("↑", .upArrow, []),
            ("→", .rightArrow, []),
            ("Enter", .returnKey, []),
            ("Esc", .escape, []),
        ]
        for (name, key, modifiers) in notTyping {
            XCTAssertFalse(UnifiedListKeys.isTyping(key: key, modifiers: modifiers), name)
        }
    }

    func testTextInputClassification() {
        for text in ["a", "Z", "1", " ", "\u{00E5}", "\u{3042}", "\u{1F600}"] {
            XCTAssertTrue(UnifiedListKeys.isTextInput(text), text.debugDescription)
        }
        for text in [nil, "", "\t", "\r", "\u{1B}", "\u{7F}", "\u{F700}", "\u{F703}", "\u{F8FF}"] as [String?] {
            XCTAssertFalse(UnifiedListKeys.isTextInput(text), String(describing: text?.debugDescription))
        }
    }

    // MARK: - Key hints (§4.5 "key hints", §4.6 "bottom panel")

    func testFooterHints() {
        let cases: [(String, ColumnMode, Bool, Bool, [KeyHint])] = [
            // (name, columns, hasSelection, listFocused, hints)
            ("one column, no selection, list focus", .one, false, true, [.move]),
            ("one column, no selection, search field focus", .one, false, false, [.list]),
            ("one column, selection, list focus", .one, true, true, [.move, .open]),
            ("one column, selection, search field focus", .one, true, false, [.list]),
            ("two columns, no selection, list focus", .two, false, true, [.move]),
            ("two columns, no selection, search field focus", .two, false, false, [.list]),
            ("two columns, selection, list focus", .two, true, true, [.move]),
            ("two columns, selection, search field focus", .two, true, false, [.list]),
        ]
        for (name, columns, hasSelection, listFocused, hints) in cases {
            XCTAssertEqual(KeyHints.footer(columns: columns, hasSelection: hasSelection, listFocused: listFocused), hints, name)
        }
    }

    func testHintStrings() {
        XCTAssertEqual(KeyHint.list, KeyHint(key: "↩", label: "List"))
        XCTAssertEqual(KeyHint.move, KeyHint(key: "↑↓", label: "Move"))
        XCTAssertEqual(KeyHint.open, KeyHint(key: "→", label: "Open"))
        XCTAssertEqual(KeyHint.prevNext, KeyHint(key: "⌥↑↓", label: "Prev / Next"))
        XCTAssertEqual(KeyHint.back, KeyHint(key: "←", label: "Back"))
        XCTAssertEqual(KeyHints.bottomPanel(columns: .one), [.prevNext, .back])
        XCTAssertEqual(KeyHints.bottomPanel(columns: .two), [])
    }

    /// §4.6 "bottom panel": the shortcut inside each button.
    func testButtonShortcutLabels() {
        XCTAssertEqual(RowButtonKind.resume.shortcut, "↩")
        XCTAssertEqual(RowButtonKind.jump.shortcut, "↩")
        XCTAssertEqual(RowButtonKind.branch.shortcut, "⌘↩")
        XCTAssertEqual(RowButtonKind.resume.title, "Resume")
        XCTAssertEqual(RowButtonKind.jump.title, "Jump")
        XCTAssertEqual(RowButtonKind.branch.title, "Branch")
    }
}
