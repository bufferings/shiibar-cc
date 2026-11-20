import AppKit
import ShiibarCcCore
import SwiftUI
import XCTest
@testable import ShiibarCcApp

/// The ⌄ menu's Settings… / Setup Check… need SwiftUI's `openWindow`, which
/// the root view of a surface hands over when it appears. Either surface can
/// be the first to appear after launch (the window form opens the window
/// without the popover ever showing), so both root views must hand it over.
/// Each root view is hosted in a window ordered in at an offscreen position
/// without activating the app or becoming key. No subprocess, state dir or
/// `UserDefaults.standard` is used.
@MainActor
final class SurfaceSceneOpenerTests: XCTestCase {
    /// Keeps the frame given to it: AppKit would move a window placed
    /// outside every screen back onto one.
    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private var window: NSWindow?

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    override func tearDown() {
        window?.orderOut(nil)
        window = nil
        super.tearDown()
    }

    private func makeModel(defaults: InMemoryDefaults) -> MainSurfaceModel {
        MainSurfaceModel(
            home: "/Users/example",
            defaults: defaults,
            textSize: TextSizeStore(defaults: defaults),
            launchers: ConversationsLaunchers(
                search: { _, _, _ in ConversationsProcess(process: Process()) },
                show: { _, _, _ in ConversationsProcess(process: Process()) },
                index: { _, _, _, _ in ConversationsProcess(process: Process()) }
            ),
            runCommand: { _, _ in },
            schedule: { _, _ in }
        )
    }

    func testEachSurfaceRootViewHandsOverTheSceneOpener() {
        for surface in [MainSurface.window, .popover] {
            let model = makeModel(defaults: InMemoryDefaults())
            var resolved = 0
            let hosting = NSHostingView(rootView: MainSurfaceController.surfaceRootView(model: model, surface: surface) { _ in
                resolved += 1
            })
            hosting.sizingOptions = []
            hosting.safeAreaRegions = []
            let window = OffscreenWindow(
                contentRect: NSRect(x: -40000, y: -40000, width: 420, height: 640),
                styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.setFrameOrigin(NSPoint(x: -40000, y: -40000))
            self.window = window
            window.orderFrontRegardless()
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline, resolved == 0 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            XCTAssertGreaterThan(resolved, 0, "\(surface): the opener is handed over when the surface appears")
            window.orderOut(nil)
            self.window = nil
        }
    }
}
