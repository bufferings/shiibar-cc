// The WKWebView host for the Conversations message page (DESIGN.md §4.6
// "rendering engine", §8.38). This kit owns the page lifecycle, the bridge,
// and the copy verbs; the payload shape and every semantic boundary come
// from ShiibarCcCore (ConversationsWebPayload — Core is authoritative, the
// page never recomputes).
//
// Security discipline (§4.6/§8.38): content crosses the bridge as
// double-encoded JSON — the payload is JSON-encoded, that string is
// JSON-encoded again into a JS string literal, and the page JSON.parses it,
// so evaluateJavaScript only ever interpolates a JSONEncoder-produced
// literal (quotes/backslashes/control chars/U+2028-9 escaped by
// construction). The page carries a per-load nonce'd CSP (default-src
// 'none'); the navigation delegate cancels everything except the initial
// load and opens content links in the default browser; the data store is
// non-persistent.
//
// Bridge surface — native -> JS: load / setHits / jump / setSize / setTheme
// / selectionRanges. JS -> native: ready / rendered / hitsApplied /
// selection / anchor / error. Every JS-side exception and every
// evaluateJavaScript failure lands in the unified log (category "webpane")
// — nothing breaks silently.

import AppKit
import Foundation
import os
import ShiibarCcCore
import SwiftUI
// @preconcurrency: WKNavigationDelegate's completion-handler requirements
// predate Sendable annotations in WebKit's headers.
@preconcurrency import WebKit

private let webPaneLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "cc.shiibar.menubar",
    category: "webpane"
)

// MARK: - Controller

@MainActor
public final class WebPaneController: NSObject, ObservableObject {
    public let webView: PaneWebView

    /// Scroll anchor per §4.6 scroll memory: the topmost visible message's
    /// seq, reported by the page (message granularity).
    public var onAnchor: ((Int64) -> Void)?
    /// Page load/render timing (logged; also used by tests).
    public var onRendered: ((Double) -> Void)?
    public var onHitsApplied: ((Double) -> Void)?

    /// The page's last rendered ack, with the JS-side geometry it reported
    /// (§8.38(8) blank-pane diagnosis: a DOM that rendered into a zero-size
    /// viewport is visible here and in the notice log).
    public struct RenderedAck: Equatable {
        public let generation: Int
        public let documentHeight: Double
        public let viewportWidth: Double
        public let viewportHeight: Double
    }

    public private(set) var lastRenderedAck: RenderedAck?

    /// Whether the page currently has a non-collapsed selection — kept
    /// current by the page's selectionchange events so menu validation
    /// (Copy enabled/disabled) can answer synchronously (§4.6).
    public private(set) var pageHasSelection = false

    /// How a clicked content link reaches the outside world (§4.6: the page
    /// never navigates; http/https links open in the default browser).
    /// Injectable so tests can spy on it instead of launching the user's
    /// real browser — tests must never touch machine state outside their
    /// sandbox (the same principle as the temp-state-dir rule).
    public var openExternalURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// Where Copy as Markdown writes. Injectable for the same sandbox rule:
    /// tests use a uniquely named pasteboard, never the user's general one.
    /// (Plain Copy never comes through here — it is WebKit's own `copy:`.)
    public var pasteboard: NSPasteboard = .general

    /// How ⌘C reaches WebKit (§4.6/§8.38(6): Copy just invokes the standard
    /// `copy:` — rich formats included, no writing path of our own).
    /// Injectable as the test seam: the key test verifies the key REACHES
    /// this dispatch; WebKit's own clipboard writing is not re-tested.
    public lazy var dispatchCopy: () -> Void = { [weak self] in
        guard let self else { return }
        NSApp.sendAction(#selector(NSText.copy(_:)), to: self.webView, from: nil)
    }

    /// The conversation currently in the page — Copy as Markdown serializes
    /// from the block structure the display was built from (§4.6).
    private var loadedRendered: [RenderedMessage] = []

    private var pageReady = false
    private var queuedScripts: [String] = []
    private let bridge = BridgeHandler()

    // Delivery reliability (§8.38(7), M39 T5 "blank pane"): every load
    // carries a generation number the page echoes back in its rendered ack.
    // If the ack for the newest generation does not arrive within a short
    // window, the load is re-injected ONCE and the miss is logged. The
    // latest scripts are also kept for full replay after a WebContent
    // process termination (a known way to end up with a silently blank
    // web view until the next interaction).
    private var loadGeneration = 0
    private var ackedLoadGeneration = 0
    private var retriedLoadGeneration = 0
    /// The newest generation the zero-viewport self-heal re-injected for
    /// (once per generation — never a loop).
    private var selfHealedGeneration = 0
    /// State recorded while the view had zero bounds (§8.38(8) field-
    /// confirmed: a load dispatched into a 0x0 view renders, acks, and
    /// never paints). Flushed on the first nonzero layout.
    private var heldForLayout = false
    private var lastLoadScript: String?
    private var lastHitsScript: String?
    private var lastSizeScript: String?
    private var lastThemeScript: String?

    override public init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false
        webView = PaneWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.controller = self
        bridge.owner = self
        configuration.userContentController.add(bridge, name: "shiibar")
        webView.navigationDelegate = bridge
        // The pane sits on the window's normal background (§4.6: the reading
        // surface is the plain window background).
        webView.setValue(false, forKey: "drawsBackground")
        webView.loadHTMLString(pageHTML(), baseURL: nil)
    }

    // MARK: Native -> JS

    /// Render a conversation. `anchorSeq` is the remembered scroll position
    /// (§4.6: per conversation, message granularity; the memory wins over
    /// the bottom-default initial position).
    public func load(
        messages: [ConversationMessage], rendered: [RenderedMessage],
        anchorSeq: Int64?, elapsed: String? = nil
    ) {
        loadedRendered = rendered
        loadGeneration += 1
        let generation = loadGeneration
        let payload = ConversationsWebPayload.payload(messages: messages, rendered: rendered, elapsed: elapsed)
        let script = "shiibarAPI.load(JSON.parse(\(doubleEncoded(payload))), \(anchorSeq.map(String.init) ?? "null"), \(generation))"
        lastLoadScript = script
        lastHitsScript = nil // hits for the previous conversation must not replay
        // §8.38(8), field-confirmed: a load dispatched while the view has
        // zero bounds renders into a 0x0 viewport, acks, and WebKit never
        // repaints once real bounds arrive. Hold the state instead and
        // flush it on the first nonzero layout. Routine dispatches log
        // nothing (§4.6 logging policy: only anomalies name themselves).
        guard isDisplayable else {
            heldForLayout = true
            let bounds = webView.bounds.size
            webPaneLog.notice("load gen \(generation) held (bounds=\(Int(bounds.width))x\(Int(bounds.height)) window=\(self.webView.window != nil))")
            return
        }
        run(script)
        scheduleLoadAckCheck(generation)
    }

    /// Mirror Core's hits (already UTF-16-converted with hidden flags).
    public func setHits(_ hits: [ConversationHit], rendered: [RenderedMessage], current: Int?) {
        let payload = ConversationsWebPayload.hits(hits, rendered: rendered)
        let script = "shiibarAPI.setHits(JSON.parse(\(doubleEncoded(payload))), \(current.map(String.init) ?? "-1"))"
        lastHitsScript = script
        if isDisplayable { run(script) } else { heldForLayout = true }
    }

    /// ▲▼ navigation: the page scrolls to the hit and auto-expands a folded
    /// one (§4.6) — the hidden flag it acts on is Core's.
    public func jump(to index: Int) {
        run("shiibarAPI.jump(\(index))")
    }

    /// ⌘± / Settings text size (§4.6): the value flows into the page's CSS
    /// variable; code blocks derive their -1.5pt in CSS (§9).
    public func setTextSize(_ points: Double) {
        let script = "shiibarAPI.setSize(\(points))"
        lastSizeScript = script
        if isDisplayable { run(script) } else { heldForLayout = true }
    }

    /// Appearance sync (§4.5 override included): an explicit attribute so
    /// the page follows the app, not just the system.
    public func setDarkTheme(_ dark: Bool) {
        let script = "shiibarAPI.setTheme(\(dark))"
        lastThemeScript = script
        if isDisplayable { run(script) } else { heldForLayout = true }
    }

    /// Whether dispatching into the page can produce a visible paint:
    /// nonzero bounds. (Window attachment is logged for diagnosis but not
    /// gated on — SwiftUI sizes the view only after attaching it, and the
    /// offscreen test harness sizes without a window.)
    private var isDisplayable: Bool {
        webView.bounds.width > 0 && webView.bounds.height > 0
    }

    /// First nonzero layout (or any later geometry change while state is
    /// held): flush the latest theme/size/load/hits into the page — the
    /// same replay set the process-termination recovery uses (§8.38(8)).
    fileprivate func flushHeldStateIfNeeded() {
        guard heldForLayout, isDisplayable else { return }
        heldForLayout = false
        let bounds = webView.bounds.size
        webPaneLog.notice("flushing held pane state at bounds=\(Int(bounds.width))x\(Int(bounds.height)) gen=\(self.loadGeneration)")
        for script in [lastThemeScript, lastSizeScript, lastLoadScript, lastHitsScript].compactMap({ $0 }) {
            run(script)
        }
        if lastLoadScript != nil {
            scheduleLoadAckCheck(loadGeneration)
        }
    }

    // MARK: Delivery verification (§8.38(7))

    /// If the page has not acked `generation` shortly after injection,
    /// re-inject the latest load once and log — a payload must never be
    /// silently lost (the "blank pane until an interaction" report).
    private func scheduleLoadAckCheck(_ generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            guard self.loadGeneration == generation else { return } // superseded
            guard self.ackedLoadGeneration < generation else { return } // rendered
            guard self.retriedLoadGeneration < generation else {
                webPaneLog.error("load generation \(generation) still unacked after retry")
                return
            }
            self.retriedLoadGeneration = generation
            webPaneLog.error("load generation \(generation) was not acked; re-injecting once")
            if let script = self.lastLoadScript {
                self.run(script)
                if let hits = self.lastHitsScript { self.run(hits) }
                self.scheduleLoadAckCheck(generation)
            }
        }
    }

    /// WebContent process died (the classic silently-blank web view): reload
    /// the page and replay the latest state once it reports ready.
    fileprivate func recoverFromProcessTermination() {
        webPaneLog.error("WebContent process terminated; reloading the pane")
        pageReady = false
        queuedScripts = [lastThemeScript, lastSizeScript, lastLoadScript, lastHitsScript].compactMap { $0 }
        webView.loadHTMLString(pageHTML(), baseURL: nil)
    }

    // MARK: Copy verbs (§4.6 "selection and copy")

    /// Copy as Markdown (⇧⌘C / menu, §4.6): the SELECTED RANGE serialized
    /// back to Markdown from the block structure and inline styles the
    /// display used (Core's serializer). Copying is selection-only
    /// (§8.38(6)); with no selection this writes nothing.
    public func copyAsMarkdown() {
        evaluate("JSON.stringify(shiibarAPI.selectionRanges())") { [weak self] result in
            guard let self else { return }
            let ranges = Self.decodeSelectionRanges(result as? String)
            guard !ranges.isEmpty else { return }
            // Page offsets are UTF-16; Core serializes at Character offsets
            // (the same boundary conversion as the payload, §8.38).
            var parts: [String] = []
            for range in ranges.sorted(by: { $0.m < $1.m }) {
                guard self.loadedRendered.indices.contains(range.m) else { continue }
                let rendered = self.loadedRendered[range.m]
                let text = rendered.renderedText
                let start = ConversationsMarkdownSerializer.characterOffset(utf16Offset: range.s, in: text)
                let end = ConversationsMarkdownSerializer.characterOffset(utf16Offset: range.s + range.l, in: text)
                let markdown = ConversationsMarkdownSerializer.markdown(rendered: rendered, start: start, end: end)
                if !markdown.isEmpty { parts.append(markdown) }
            }
            self.writePasteboard(parts.joined(separator: "\n\n"))
        }
    }

    private func writePasteboard(_ string: String) {
        guard !string.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    private struct SelectionRange: Decodable {
        let m: Int
        let s: Int
        let l: Int
    }

    private static func decodeSelectionRanges(_ json: String?) -> [SelectionRange] {
        guard let json, let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([SelectionRange].self, from: data) else { return [] }
        return decoded
    }

    // MARK: Bridge plumbing

    /// Double-encoded JSON (see the file header) — the only interpolation
    /// evaluateJavaScript ever receives.
    private func doubleEncoded(_ value: some Encodable) -> String {
        let inner = ConversationsWebPayload.encodeJSON(value)
        guard let outer = try? JSONEncoder().encode(inner),
              let literal = String(data: outer, encoding: .utf8) else {
            return "\"{}\""
        }
        return literal
    }

    private func run(_ script: String) {
        if pageReady {
            evaluate(script, completion: nil)
        } else {
            queuedScripts.append(script)
        }
    }

    /// evaluateJavaScript with mandatory error logging (§8.38: nothing
    /// breaks silently).
    private func evaluate(_ script: String, completion: (@MainActor (Any?) -> Void)?) {
        webView.evaluateJavaScript(script) { result, error in
            if let error {
                webPaneLog.error("evaluateJavaScript failed: \(String(describing: error), privacy: .public)")
            }
            if let completion {
                Task { @MainActor in completion(result) }
            }
        }
    }

    fileprivate func handle(_ body: [String: Any]) {
        switch body["type"] as? String {
        case "ready":
            pageReady = true
            for script in queuedScripts { evaluate(script, completion: nil) }
            queuedScripts = []
        case "rendered":
            let ms = body["ms"] as? Double ?? 0
            let generation = (body["gen"] as? Int) ?? 0
            ackedLoadGeneration = max(ackedLoadGeneration, generation)
            let ack = RenderedAck(
                generation: generation,
                documentHeight: body["docH"] as? Double ?? -1,
                viewportWidth: body["vw"] as? Double ?? -1,
                viewportHeight: body["vh"] as? Double ?? -1
            )
            lastRenderedAck = ack
            // Belt-and-suspenders (§8.38(8)): a render into a zero-height
            // viewport while the native view HAS real bounds is the blank
            // pane; re-inject the latest load once per generation.
            if ack.viewportHeight <= 0, isDisplayable,
               generation == loadGeneration, let script = lastLoadScript {
                if selfHealedGeneration < generation {
                    selfHealedGeneration = generation
                    webPaneLog.notice("ack gen \(generation) had zero viewport with nonzero bounds; re-injecting once")
                    run(script)
                    if let hits = lastHitsScript { run(hits) }
                } else {
                    webPaneLog.notice("ack gen \(generation) still zero viewport after self-heal; leaving it")
                }
            }
            onRendered?(ms)
        case "hitsApplied":
            onHitsApplied?(body["ms"] as? Double ?? 0)
        case "selection":
            pageHasSelection = body["has"] as? Bool ?? false
        case "anchor":
            if let seq = body["seq"] as? Int64 ?? (body["seq"] as? Int).map(Int64.init) {
                onAnchor?(seq)
            }
        case "error":
            let message = body["message"] as? String ?? "unknown"
            webPaneLog.error("page error: \(message, privacy: .public)")
        default:
            webPaneLog.error("unknown bridge message: \(String(describing: body), privacy: .public)")
        }
    }

    /// One random nonce per controller INSTANCE, not per load: WebKit
    /// carries the first about:blank document's CSP across a second
    /// loadHTMLString (measured — a fresh nonce left the recovery page's
    /// script silently blocked), so the recovery reload must present the
    /// same nonce. Still unguessable, and the CSP remains defense-in-depth:
    /// content can never become markup at all (textContent-only).
    private let pageNonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")

    private func pageHTML() -> String {
        pageTemplate.replacingOccurrences(of: "__NONCE__", with: pageNonce)
    }
}

// MARK: - The web view subclass: context menu + shortcuts (§4.6)

/// The web view subclass owning the §4.6 copy grammar: a two-verb context
/// menu (via the public `NSView.willOpenMenu` hook) and the ⌘C / ⇧⌘C key
/// handling that this Edit-menu-less app (§4.5) cannot get from anywhere
/// else.
public final class PaneWebView: WKWebView {
    weak var controller: WebPaneController?

    /// Every geometry hook flushes held state (§8.38(8) blank-pane fix).
    /// Routine geometry changes log nothing (§4.6 logging policy) — the
    /// flush itself logs when it actually fires.
    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        noteGeometryChange()
    }

    override public func layout() {
        super.layout()
        noteGeometryChange()
    }

    /// setFrameSize fires in every hosting context (the layout pass does
    /// not reach unhosted views), so the held-state flush hangs off it too.
    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        noteGeometryChange()
    }

    private func noteGeometryChange() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        controller?.flushHeldStateIfNeeded()
    }

    override public func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)

        // §4.6/§8.38(6): the reading surface offers exactly two verbs,
        // ALWAYS — Copy (⌘C shown) and Copy as Markdown (⇧⌘C shown), both
        // disabled while nothing is selected. With a selection WebKit's own
        // Copy item is reused (never duplicated — it manages its enabled
        // state; found by identifier first because the action-selector
        // match missed it in the owner's smoke). Without one, WebKit
        // supplies no Copy item, so a disabled placeholder stands in
        // (harmless: keys are handled in performKeyEquivalent, never
        // through this menu — round 1's "swallowed ⌘C" was the missing
        // Edit menu, not the disabled item). Every other standard item
        // (Look Up, Translate, Search, Share, Speech, separators, ...) is
        // removed.
        let hasSelection = controller?.pageHasSelection == true
        let systemCopy = menu.items.first(where: Self.isSystemCopyItem)
        menu.removeAllItems()
        if let systemCopy {
            // Show the shortcut on the reused item (§4.6: ⌘C displayed).
            if systemCopy.keyEquivalent.isEmpty {
                systemCopy.keyEquivalent = "c"
                systemCopy.keyEquivalentModifierMask = [.command]
            }
            menu.addItem(systemCopy)
        } else {
            // action-less -> stays disabled under menu auto-enabling.
            let placeholder = NSMenuItem(title: "Copy", action: nil, keyEquivalent: "c")
            placeholder.keyEquivalentModifierMask = [.command]
            placeholder.isEnabled = false
            menu.addItem(placeholder)
        }
        let markdownItem = NSMenuItem(
            title: "Copy as Markdown",
            action: hasSelection ? #selector(copyAsMarkdownAction(_:)) : nil,
            keyEquivalent: "C" // uppercase = shift+c, shown as shift-cmd-C
        )
        markdownItem.keyEquivalentModifierMask = [.command, .shift]
        if hasSelection { markdownItem.target = self }
        markdownItem.isEnabled = hasSelection
        menu.addItem(markdownItem)
    }

    /// WebKit tags its menu items with stable identifiers; the Copy item's
    /// is "WKMenuItemIdentifierCopy". Matched first by identifier, then by
    /// the copy: selector, then by title as a last resort.
    private static func isSystemCopyItem(_ item: NSMenuItem) -> Bool {
        if item.identifier?.rawValue == "WKMenuItemIdentifierCopy" { return true }
        if item.action == #selector(NSText.copy(_:)) { return true }
        return item.title == "Copy" && item.action != nil
    }

    @objc private func copyAsMarkdownAction(_ sender: Any?) {
        controller?.copyAsMarkdown()
    }

    /// ⌘C and ⇧⌘C are handled by the pane itself (§4.6/§8.38); with the
    /// Edit menu back (§8.41) the pane claims them ONLY while it owns first
    /// responder — `NSWindow.performKeyEquivalent` walks the whole view
    /// tree, and the page's selection persists while the search field is
    /// being edited, so an unguarded override would steal the field's ⌘C.
    /// Copying stays selection-only (§8.38(6)): without a selection both
    /// shortcuts fall through untouched.
    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        guard let controller, controller.pageHasSelection, key == "c", ownsFirstResponder else {
            return super.performKeyEquivalent(with: event)
        }
        if flags == [.command, .shift] {
            controller.copyAsMarkdown()
            return true
        }
        if flags == [.command] {
            controller.dispatchCopy()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// First responder is this view or inside it (WebKit's content view).
    /// An unhosted view (the test harness) counts as owning focus.
    private var ownsFirstResponder: Bool {
        guard let window else { return true }
        guard let responder = window.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }
}

// MARK: - Navigation policy + bridge handler

/// Separate NSObject so WKUserContentController's strong reference never
/// retains the controller (the classic WKScriptMessageHandler cycle).
private final class BridgeHandler: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    weak var owner: WebPaneController?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "shiibar", let body = message.body as? [String: Any] else { return }
        Task { @MainActor [weak owner] in owner?.handle(body) }
    }

    /// A dead WebContent process leaves the view blank until the next
    /// interaction — one suspected cause of the owner's white-pane report.
    /// Recovery is a page reload + state replay (§8.38(7)).
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor [weak owner] in owner?.recoverFromProcessTermination() }
    }

    /// §4.6: the page never navigates. The only allowed load is the initial
    /// loadHTMLString (about:blank); a clicked content link goes through the
    /// controller's injectable `openExternalURL` (http/https only —
    /// javascript:/file:/anything else is simply cancelled); everything else
    /// is cancelled.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.navigationType == .linkActivated {
            if let url = navigationAction.request.url,
               url.scheme == "https" || url.scheme == "http" {
                // Delegate callbacks arrive on the main thread; hop
                // explicitly for the main-actor-isolated owner.
                Task { @MainActor [weak owner] in owner?.openExternalURL(url) }
            }
            decisionHandler(.cancel)
            return
        }
        let isInitialLoad = navigationAction.request.url?.absoluteString == "about:blank"
        decisionHandler(isInitialLoad ? .allow : .cancel)
    }
}

// MARK: - SwiftUI wrapper

public struct WebPaneView: NSViewRepresentable {
    let controller: WebPaneController
    @Environment(\.colorScheme) private var colorScheme

    public init(controller: WebPaneController) {
        self.controller = controller
    }

    public func makeNSView(context: Context) -> WKWebView {
        controller.setDarkTheme(colorScheme == .dark)
        return controller.webView
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {
        // Appearance sync: colorScheme reflects the app's Appearance
        // override (§4.5) because the override sets NSApp.appearance, which
        // the SwiftUI environment follows.
        controller.setDarkTheme(colorScheme == .dark)
    }
}
