// The Settings window's Global shortcut field (DESIGN.md §4.5 "Settings
// window" > General > Global shortcut). It shows `GlobalShortcutRecorder`'s
// text and × button and forwards input to `GlobalHotKeyModel`; it decides
// nothing itself. While recording, an event monitor takes every key press
// before the Settings window's other shortcuts (⌘W, ⌘, ...) and the
// focused view, and a press of the mouse outside the field abandons the
// recording, as does the window stopping being key or closing.

import AppKit
import ShiibarCcCore
import SwiftUI

struct GlobalShortcutRow: View {
    @ObservedObject var hotKey: GlobalHotKeyModel

    static let label = "Global shortcut"

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(Self.label) {
                GlobalShortcutField(hotKey: hotKey)
            }
            if let hint = hotKey.recorder.hint {
                Text(hint.text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct GlobalShortcutField: View {
    @ObservedObject var hotKey: GlobalHotKeyModel

    private static let minimumWidth: CGFloat = 120
    private static let height: CGFloat = 22
    private static let cornerRadius: CGFloat = 6
    private static let horizontalPadding: CGFloat = 8

    var body: some View {
        let recorder = hotKey.recorder
        HStack(spacing: 4) {
            Text(recorder.fieldText)
                .font(.system(size: 12))
                .foregroundStyle(recorder.isRecording || recorder.registered == nil ? .secondary : .primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
            if recorder.showsClearButton {
                // Holds the × button's place in the layout; the live button
                // sits above the click view (below).
                clearButton.hidden()
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        .frame(minWidth: Self.minimumWidth, minHeight: Self.height)
        .fixedSize()
        .background(
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .strokeBorder(
                    recorder.isRecording ? Color.accentColor : Color(nsColor: .separatorColor),
                    lineWidth: recorder.isRecording ? 2 : 1)
        )
        // The click is taken by an AppKit view over the whole field, not a
        // SwiftUI tap gesture: in the grouped Form, SwiftUI puts a text
        // interaction view over the field's text that swallows the click
        // before a tap gesture sees it.
        .overlay(ShortcutFieldInput(hotKey: hotKey, isRecording: recorder.isRecording))
        .overlay(alignment: .trailing) {
            if recorder.showsClearButton {
                clearButton.padding(.trailing, Self.horizontalPadding)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(GlobalShortcutRow.label)
        .accessibilityValue(recorder.fieldText)
    }

    private var clearButton: some View {
        Button {
            hotKey.clearClicked()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Clear shortcut")
    }
}

/// The field's input: a press on the field (outside the × button, which
/// sits above it) and, while recording, the event monitors. It has the
/// field's frame, which also tells a press inside the field from one outside
/// it.
private struct ShortcutFieldInput: NSViewRepresentable {
    let hotKey: GlobalHotKeyModel
    let isRecording: Bool

    func makeNSView(context: Context) -> ShortcutFieldInputView {
        ShortcutFieldInputView()
    }

    func updateNSView(_ view: ShortcutFieldInputView, context: Context) {
        view.hotKey = hotKey
        view.setRecording(isRecording)
    }

    static func dismantleNSView(_ view: ShortcutFieldInputView, coordinator: ()) {
        view.setRecording(false)
    }
}

final class ShortcutFieldInputView: NSView {
    weak var hotKey: GlobalHotKeyModel?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    /// The first click on an inactive Settings window reaches the field too.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        hotKey?.fieldClicked()
    }

    func setRecording(_ recording: Bool) {
        if recording {
            guard keyMonitor == nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let hotKey = self.hotKey, event.window === self.window else { return event }
                hotKey.keyPressed(
                    keyCode: event.keyCode,
                    modifiers: GlobalHotKeyModel.modifiers(of: event.modifierFlags),
                    keyName: GlobalHotKeyModel.keyName(of: event))
                return nil
            }
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                guard let self else { return event }
                if !self.contains(event) { self.hotKey?.recordingAbandoned() }
                return event
            }
            if let window {
                resignObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didResignKeyNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.hotKey?.recordingAbandoned() }
                }
            }
        } else {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
            keyMonitor = nil
            mouseMonitor = nil
            resignObserver = nil
        }
    }

    /// Whether a mouse press lands on the field.
    private func contains(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        let point = convert(event.locationInWindow, from: nil)
        return bounds.contains(point)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, keyMonitor != nil {
            setRecording(false)
            hotKey?.recordingAbandoned()
        }
    }
}
