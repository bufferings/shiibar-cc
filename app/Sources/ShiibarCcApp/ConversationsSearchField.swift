// The header row's search field (DESIGN.md §4.6 "search field" /
// §8.38(12); visual spec: docs/window-design.html `.search`). The app draws
// the field itself — the rounded card-colored ground, its 1pt border and the
// magnifier icon, and the clear button while the field holds text — with a
// borderless text field inside: the system search field's bezel does not
// take the height it is given. No focus ring, no recent-searches menu.
//
// The representable treats IME composition explicitly — while marked text is
// active the query binding is NOT updated (no search dispatches on
// half-composed text), and the commit always propagates the final string.
// SwiftUI's TextField gave no access to the marked-text state. It also
// carries the focus requests (§4.5: on popover open and ⌘F the field takes
// focus with the caret at the end of the kept text, without selecting it).

import AppKit
import ShiibarCcCore
import SwiftUI

struct ConversationsSearchField: NSViewRepresentable {
    @Binding var text: String
    let isEnabled: Bool
    /// Changes when a focus request fires; the field takes first responder
    /// on change if its window is on screen.
    let focusToken: Int
    /// false while the list page is under the one-column detail page: Tab
    /// and Shift-Tab skip the field, which stays mounted there (§4.5 "key
    /// operations"). Focus requests and clicks are not affected.
    var isKeyViewLoopMember = true
    /// The text size's scale (§4.5 "text size"): the field's height, text,
    /// magnifier and clear button follow it.
    var scale: SurfaceScale = .base

    static let placeholder = "Search (2+ characters)"

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> SearchFieldView {
        let view = SearchFieldView()
        view.scale = scale
        view.textField.delegate = context.coordinator
        context.coordinator.view = view
        // The clear button feeds the emptied text through the same handler
        // as a keyboard edit, so the search, its debounce and the selection
        // react exactly as when the text is deleted with keys (§4.6).
        view.onTextCleared = { [weak coordinator = context.coordinator] in
            coordinator?.handleTextChange("", isComposing: false)
        }
        // `lastFocusToken` stays 0: a request issued before this field
        // existed (the popover's view is built on its first show) is still
        // honored by the first update.
        return view
    }

    func updateNSView(_ view: SearchFieldView, context: Context) {
        let field = view.textField
        context.coordinator.textBinding = $text
        view.scale = scale
        field.isEnabled = isEnabled
        field.isKeyViewLoopMember = isKeyViewLoopMember
        // Never clobber an active composition from the binding side.
        if field.stringValue != text, !context.coordinator.isComposing(field) {
            field.stringValue = text
        }
        view.updateClearButton()
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
        /// The field whose clear button follows each edit.
        weak var view: SearchFieldView?

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
            // The button follows the visible text, marked text included.
            view?.updateClearButton()
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
/// focus" (it, or its field editor, is the first responder — §4.5), and so
/// the field can leave the key view loop while it is not shown.
final class SearchTextField: NSTextField {
    /// false: the window's Tab / Shift-Tab traversal skips the field. AppKit
    /// takes a view that other views cover (not hidden) as a key view, both
    /// for `selectNextKeyView` / `selectPreviousKeyView` and for a Tab typed
    /// in the conversation pane's web view (checked on macOS 27.2.1,
    /// 2026-11-18). The field still accepts first responder for a focus
    /// request or a click.
    var isKeyViewLoopMember = true

    override var canBecomeKeyView: Bool {
        isKeyViewLoopMember && super.canBecomeKeyView
    }
}

/// The drawn search field (window-design.html `.search`): at text size 13,
/// 24pt tall, the 13pt magnifier, the 12pt text and the 12pt clear button;
/// those follow the text size (`scale`, §4.5 "text size"). Radius 6, the
/// card color with a 1pt border, 8pt horizontal padding, 6pt from the
/// magnifier to the text and from the text to the clear button stay fixed.
/// The clear button sits at the right padding while the field holds text.
/// A click anywhere on the ground focuses the text field.
final class SearchFieldView: NSView {
    static let cornerRadius: CGFloat = 6
    static let horizontalPadding: CGFloat = 8
    static let iconTextSpacing: CGFloat = 6
    /// `.search` flex gap between the text and the clear button.
    static let clearButtonSpacing: CGFloat = 6

    /// The text size's scale. Setting it updates the font, the height, the
    /// icon, the clear button and the constraints that depend on them.
    var scale: SurfaceScale = .base {
        didSet {
            guard scale != oldValue else { return }
            applyScale()
        }
    }

    let textField = SearchTextField()
    let clearButton = SearchClearButton()
    /// Propagates the emptied text after the clear button empties the field.
    var onTextCleared: () -> Void = {}
    /// Puts keyboard focus in the text field after a clear. Replaceable so
    /// the clear can be checked without a window on screen.
    var focusTextField: (SearchFieldView) -> Void = { $0.focusWithCaretAtEnd() }

    /// The text field's trailing edge: at the right padding while the clear
    /// button is hidden (no room is reserved for it), and short of the
    /// button while it is shown, so typed text never runs under it.
    private var textTrailingToPadding: NSLayoutConstraint!
    private var textTrailingToClearButton: NSLayoutConstraint!
    private var textLeading: NSLayoutConstraint!
    private var clearButtonWidth: NSLayoutConstraint!
    private var clearButtonHeight: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        textField.placeholderString = ConversationsSearchField.placeholder
        textField.font = .systemFont(ofSize: scale.searchFieldFont)
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

        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.target = self
        clearButton.action = #selector(clearButtonPressed)
        clearButton.isHidden = true
        addSubview(clearButton)

        textLeading = textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: textLeadingInset)
        textTrailingToPadding = textField.trailingAnchor.constraint(
            equalTo: trailingAnchor, constant: -Self.horizontalPadding)
        textTrailingToClearButton = textField.trailingAnchor.constraint(
            equalTo: clearButton.leadingAnchor, constant: -Self.clearButtonSpacing)
        clearButtonWidth = clearButton.widthAnchor.constraint(equalToConstant: scale.searchClearButton)
        clearButtonHeight = clearButton.heightAnchor.constraint(equalToConstant: scale.searchClearButton)
        NSLayoutConstraint.activate([
            textLeading,
            textTrailingToPadding,
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalPadding),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButtonWidth,
            clearButtonHeight,
        ])
    }

    /// The text starts after the padding, the magnifier and the gap.
    private var textLeadingInset: CGFloat {
        Self.horizontalPadding + scale.searchIcon + Self.iconTextSpacing
    }

    private func applyScale() {
        textField.font = .systemFont(ofSize: scale.searchFieldFont)
        textLeading.constant = textLeadingInset
        clearButtonWidth.constant = scale.searchClearButton
        clearButtonHeight.constant = scale.searchClearButton
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
        clearButton.needsDisplay = true
    }

    /// Shows or hides the clear button for the field's current text (marked
    /// text included) and enabled state, and moves the text field's
    /// trailing edge to match.
    func updateClearButton() {
        let shown = SearchFieldClearButton.isShown(text: textField.stringValue, isEnabled: textField.isEnabled)
        guard clearButton.isHidden == shown else { return }
        clearButton.isHidden = !shown
        // Deactivate before activating so the two never conflict.
        if shown {
            textTrailingToPadding.isActive = false
            textTrailingToClearButton.isActive = true
        } else {
            textTrailingToClearButton.isActive = false
            textTrailingToPadding.isActive = true
        }
    }

    /// Empties the field — an IME composition in progress is discarded, not
    /// committed — propagates the empty text, and puts focus in the field.
    @objc func clearButtonPressed() {
        if let editor = textField.currentEditor() as? NSTextView, editor.hasMarkedText() {
            // Empty the editor before ending the composition, so ending it
            // has no composed text left to commit and report as a change.
            editor.inputContext?.discardMarkedText()
            editor.string = ""
            editor.unmarkText()
        }
        textField.stringValue = ""
        onTextCleared()
        updateClearButton()
        focusTextField(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// y-down, like the `SurfaceIcon` paths.
    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: scale.searchFieldHeight)
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
                y: (bounds.height - scale.searchIcon) / 2,
                width: scale.searchIcon, height: scale.searchIcon)
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.addPath(SurfaceIcon.search.path(in: iconRect).cgPath)
            context.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
            context.setLineWidth(scale.searchIconLine)
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

/// The search field's clear button (window-design.html `.search .clr`): a
/// filled circle (12pt at text size 13) in the secondary label color with a × in the opaque
/// control background color (the card color is translucent on dark and
/// would not show on the circle). Mouse only — it never takes keyboard
/// focus, so the caret stays in the text field while the button is clicked.
final class SearchClearButton: NSButton {
    /// The ×'s strokes on a 16-unit box, and their width in those units.
    static let crossStrokes: [(CGPoint, CGPoint)] = [
        (CGPoint(x: 5.6, y: 5.6), CGPoint(x: 10.4, y: 10.4)),
        (CGPoint(x: 10.4, y: 5.6), CGPoint(x: 5.6, y: 10.4)),
    ]
    static let crossLineWidth: CGFloat = 1.6

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        refusesFirstResponder = true
        toolTip = "Clear"
        setAccessibilityLabel("Clear search")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { false }
    override var canBecomeKeyView: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // Colors resolve against this view's appearance (light / dark).
        effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            let side = min(bounds.width, bounds.height)
            let box = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
            context.setFillColor(NSColor.secondaryLabelColor.cgColor)
            context.fillEllipse(in: box)

            // The 16-unit box maps onto the circle; the × is symmetric, so
            // the y direction does not matter.
            let scale = side / 16
            for (from, to) in Self.crossStrokes {
                context.move(to: CGPoint(x: box.minX + from.x * scale, y: box.minY + from.y * scale))
                context.addLine(to: CGPoint(x: box.minX + to.x * scale, y: box.minY + to.y * scale))
            }
            context.setStrokeColor(NSColor.controlBackgroundColor.cgColor)
            context.setLineWidth(Self.crossLineWidth * scale)
            context.setLineCap(.round)
            context.strokePath()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
