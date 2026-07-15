import XCTest
@testable import ShiibarCcApp

/// Launch-safety regression guard: `AppDelegate.init` runs during the App
/// struct's body evaluation, BEFORE NSApplication is set up — anything on
/// that path that touches process-global app state (the implicitly
/// unwrapped `NSApp`, key windows, ...) traps at every launch, as the
/// round-7 `hasClosableWindow` initializer did (5 crash reports/minute in
/// the field). This constructs the real init chain cold.
///
/// What this CAN catch: a trap or assertion anywhere in the
/// AppDelegate/AppState/AppMenuModel construction chain, and any future
/// eager call of the injected key-window provider during init. What it
/// CANNOT catch: an `NSApp` access that happens NOT to trap because some
/// earlier test in this process already initialized NSApplication (test
/// order is not controllable) — the structural rule "init reads no global
/// app state, providers run only from post-launch callbacks" is the real
/// protection; this guard makes violations loud in most runs instead of at
/// the owner's launch.
@MainActor
final class LaunchSafetyTests: XCTestCase {
    func testAppDelegateInitChainConstructsCold() {
        // The exact objects the real launch constructs, in the same order
        // (AppState, AppMenuModel, MainMenuPruner — see AppDelegate.init).
        let delegate = AppDelegate()
        XCTAssertNotNil(delegate.state)
        // Launch truth: no windows exist yet, nothing is closable.
        XCTAssertFalse(delegate.appMenuModel.hasClosableWindow)
    }

    func testAppMenuModelInitNeverCallsTheKeyWindowProvider() {
        let state = AppState(helpersDirectory: nil)
        var providerCalls = 0
        let model = AppMenuModel(state: state, keyWindowProvider: {
            providerCalls += 1
            return true
        })
        XCTAssertEqual(providerCalls, 0,
                       "the key-window provider must only run from NSWindow notifications, never during init")
        XCTAssertFalse(model.hasClosableWindow)
    }
}
