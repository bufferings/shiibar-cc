// First-launch-only Login Item auto-registration decision (DESIGN.md §4.5):
// auto-registration may fire at most once, ever — recorded in UserDefaults
// (`cc.shiibar.didAutoRegisterLoginItem`, app layer) regardless of outcome —
// so a user's later choice to turn "Start at Login" off is never overwritten
// by a subsequent launch. This file holds only the pure branching
// (unit-testable without `ServiceManagement`); the actual `SMAppService`
// calls live in the app layer (ShiibarCcApp).

public enum LoginItemAutoRegistration {
    /// Whether this launch should call `SMAppService.mainApp.register()` as
    /// the one-time auto-registration.
    ///
    /// - `didAutoRegisterAlready`: the UserDefaults flag — once the
    ///   first-launch check has run (any outcome), this is `true` forever.
    /// - `runningFromBundle`: only a `.app`-bundled launch is eligible
    ///   (`swift run` dev builds are a no-op, same as the old behavior).
    /// - `currentlyEnabled`: `SMAppService.mainApp.status == .enabled` — skip
    ///   the redundant register call if the Login Item is already enabled.
    public static func shouldAutoRegister(
        didAutoRegisterAlready: Bool,
        runningFromBundle: Bool,
        currentlyEnabled: Bool
    ) -> Bool {
        guard runningFromBundle, !didAutoRegisterAlready else { return false }
        return !currentlyEnabled
    }
}
