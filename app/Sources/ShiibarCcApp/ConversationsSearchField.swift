// The Conversations search field (DESIGN.md §4.6/§8.38(12)): an
// NSSearchField-backed representable that treats IME composition
// explicitly — while marked text is active the query binding is NOT
// updated (no search dispatches on half-composed text), and the commit
// always propagates the final string. SwiftUI's TextField gave no access
// to the marked-text state, which is one third of the field-confirmed
// search-miss root cause (with NFC normalization on both sides being the
// other two). Also carries the ⌘F focus request (§8.41).

import AppKit
import SwiftUI

struct ConversationsSearchField: NSViewRepresentable {
    @Binding var text: String
    let isEnabled: Bool
    /// Changes when ⌘F fires; the field takes first responder on change.
    let focusToken: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search (2+ characters)"
        field.font = .systemFont(ofSize: 12)
        field.controlSize = .small
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.textBinding = $text
        field.isEnabled = isEnabled
        // Never clobber an active composition from the binding side.
        if field.stringValue != text, !context.coordinator.isComposing(field) {
            field.stringValue = text
        }
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            // ⌘F (§8.41): focus the field. Deferred a tick — updateNSView
            // runs mid view-update, and responder changes inside it are
            // unreliable.
            DispatchQueue.main.async { [weak field] in
                guard let field, let window = field.window else { return }
                window.makeFirstResponder(field)
            }
        }
    }

    /// The marked-text decision lives in `handleTextChange` so tests can
    /// drive the composing -> commit transition without a window/IME.
    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var textBinding: Binding<String>
        var lastFocusToken = 0

        init(text: Binding<String>) {
            self.textBinding = text
        }

        /// Whether the field's editor currently holds marked (uncommitted
        /// IME) text.
        func isComposing(_ field: NSTextField) -> Bool {
            (field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            handleTextChange(field.stringValue, isComposing: isComposing(field))
        }

        /// §4.6: never dispatch while composing; always dispatch on commit.
        /// (The commit fires controlTextDidChange once more with the marked
        /// text resolved, so gating here is sufficient for both halves.)
        func handleTextChange(_ newText: String, isComposing: Bool) {
            guard !isComposing else { return }
            if textBinding.wrappedValue != newText {
                textBinding.wrappedValue = newText
            }
        }
    }
}
