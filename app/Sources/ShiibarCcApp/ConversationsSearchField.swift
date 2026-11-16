// The header row's search field (DESIGN.md §4.6 "search field" /
// §8.38(12); visual spec: docs/window-design.html `.search`). The app draws
// the field itself — the rounded card-colored ground, its 1pt border and the
// magnifier icon — with a borderless text field inside: the system search
// field's bezel does not take the height it is given. No focus ring, no
// cancel button, no recent-searches menu.
//
// The representable treats IME composition explicitly — while marked text is
// active the query binding is NOT updated (no search dispatches on
// half-composed text), and the commit always propagates the final string.
// SwiftUI's TextField gave no access to the marked-text state. It also
// carries the focus requests (§4.5: on popover open and ⌘F the field takes
// focus with the caret at the end of the kept text, without selecting it).

import AppKit
import SwiftUI

struct ConversationsSearchField: NSViewRepresentable {
    @Binding var text: String
    let isEnabled: Bool
    /// Changes when a focus request fires; the field takes first responder
    /// on change if its window is on screen.
    let focusToken: Int

    static let placeholder = "Search (2+ characters)"

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> SearchFieldView {
        let view = SearchFieldView()
        view.textField.delegate = context.coordinator
        // `lastFocusToken` stays 0: a request issued before this field
        // existed (the popover's view is built on its first show) is still
        // honored by the first update.
        return view
    }

    func updateNSView(_ view: SearchFieldView, context: Context) {
        let field = view.textField
        context.coordinator.textBinding = $text
        field.isEnabled = isEnabled
        // Never clobber an active composition from the binding side.
        if field.stringValue != text, !context.coordinator.isComposing(field) {
            field.stringValue = text
        }
        if context.coordinator.lastFocusToken != focusToken {
            // Record the request even when this field is not on screen (the
            // other surface's field handles it), so it never fires late.
            context.coordinator.lastFocusToken = focusToken
            // Deferred a tick — updateNSView runs mid view-update, and
            // responder changes inside it are unreliable.
            DispatchQueue.main.async { [weak view] in
                guard let view, let window = view.window, window.isVisible else { return }
                view.focusWithCaretAtEnd()
            }
        }
    }

    /// The marked-text decision lives in `handleTextChange` so tests can
    /// drive the composing -> commit transition without a window/IME.
    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
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

/// The search field's text field: borderless, no ground, no focus ring. A
/// class of its own so the key monitor can tell "the search field has
/// focus" (it, or its field editor, is the first responder — §4.5).
final class SearchTextField: NSTextField {}

/// The drawn search field (window-design.html `.search`): 24pt tall, radius
/// 6, the card color with a 1pt border, 8pt horizontal padding, the 13pt
/// magnifier, 6pt to the 12pt text. A click anywhere on the ground focuses
/// the text field.
final class SearchFieldView: NSView {
    static let height: CGFloat = 24
    static let cornerRadius: CGFloat = 6
    static let horizontalPadding: CGFloat = 8
    static let iconSize: CGFloat = 13
    static let iconTextSpacing: CGFloat = 6
    static let fontSize: CGFloat = 12
    /// `SurfaceIconView`'s stroke for the 15pt icons, scaled to 13pt.
    static let iconLineWidth: CGFloat = 1.4

    let textField = SearchTextField()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        textField.placeholderString = ConversationsSearchField.placeholder
        textField.font = .systemFont(ofSize: Self.fontSize)
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.usesSingleLineMode = true
        textField.lineBreakMode = .byClipping
        textField.cell?.isScrollable = true
        textField.cell?.wraps = false
        textField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textField)
        let leading = Self.horizontalPadding + Self.iconSize + Self.iconTextSpacing
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalPadding),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// y-down, like the `SurfaceIcon` paths.
    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Colors resolve against this view's appearance (light / dark).
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let ground = bounds.insetBy(dx: 0.5, dy: 0.5)
            let shape = NSBezierPath(roundedRect: ground, xRadius: Self.cornerRadius - 0.5, yRadius: Self.cornerRadius - 0.5)
            SurfaceColors.cardNSColor.setFill()
            shape.fill()
            SurfaceColors.cardBorderNSColor.setStroke()
            shape.lineWidth = 1
            shape.stroke()

            let iconRect = CGRect(
                x: Self.horizontalPadding,
                y: (bounds.height - Self.iconSize) / 2,
                width: Self.iconSize, height: Self.iconSize)
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.addPath(SurfaceIcon.search.path(in: iconRect).cgPath)
            context.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
            context.setLineWidth(Self.iconLineWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// A click on the ground outside the text field focuses it.
    override func mouseDown(with event: NSEvent) {
        guard textField.isEnabled else { return }
        focusWithCaretAtEnd()
    }

    /// Focus the text field with the caret at the end of its text (not a
    /// select-all — §4.5).
    func focusWithCaretAtEnd() {
        guard let window, window.makeFirstResponder(textField) else { return }
        let end = textField.stringValue.utf16.count
        textField.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
    }
}
