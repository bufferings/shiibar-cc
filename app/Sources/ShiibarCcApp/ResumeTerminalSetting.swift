// Settings > General > Terminal (DESIGN.md §4.5 "Settings window" >
// Terminal, §4.6 "Resume and Branch", §8.66): the terminal Resume and Branch
// open in, persisted in UserDefaults, and whether it can be used. The rules
// live in `ResumeTerminal` / `ResumeTerminalAvailability` (ShiibarCcCore);
// this object holds the observable value, looks up installed apps by bundle
// id through an injected lookup, and decides availability again on the three
// triggers: the app becoming active (observed here), a surface showing
// (`attach(to:)`) and the Settings window showing
// (`SettingsWindowModel.windowShown()`).

import AppKit
import Combine
import ShiibarCcCore

/// Finds an installed app by bundle id (nil when none has it).
typealias InstalledTerminalAppLookup = (_ bundleIdentifier: String) -> InstalledTerminalApp?

enum InstalledTerminalApps {
    /// The app's bundle found by Launch Services, and its
    /// `CFBundleShortVersionString` (§4.5: no AppleScript, no terminal is
    /// launched).
    static func live(_ bundleIdentifier: String) -> InstalledTerminalApp? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        let version = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return InstalledTerminalApp(shortVersion: version)
    }
}

@MainActor
final class ResumeTerminalSetting: ObservableObject {
    @Published private(set) var terminal: ResumeTerminal
    @Published private(set) var availability: ResumeTerminalAvailability

    private let defaults: UserDefaults
    private let lookup: InstalledTerminalAppLookup
    private let center: NotificationCenter
    private var activeObserver: NSObjectProtocol?
    private var subscriptions: Set<AnyCancellable> = []

    /// Created at app launch: decides and stores the first value when none
    /// is stored and removes the old key (§4.5), then decides availability.
    /// `center` delivers `NSApplication.didBecomeActiveNotification`.
    init(defaults: UserDefaults, lookup: @escaping InstalledTerminalAppLookup, center: NotificationCenter) {
        self.defaults = defaults
        self.lookup = lookup
        self.center = center
        let terminal = ResumeTerminal.prepareAtLaunch(defaults: defaults) { candidate in
            lookup(candidate.bundleIdentifier) != nil
        }
        self.terminal = terminal
        self.availability = ResumeTerminalAvailability.evaluate(terminal, lookup: lookup)
        // No queue: AppKit posts it on the main thread.
        activeObserver = center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAvailability() }
        }
    }

    deinit {
        if let activeObserver { center.removeObserver(activeObserver) }
    }

    /// The `--terminal` value Resume and Branch pass (§4.6).
    var cliValue: String { terminal.cliValue }

    /// A pick in the segmented control: stored and applied at once (§4.5);
    /// every choice can be picked whether or not it is installed.
    func select(_ terminal: ResumeTerminal) {
        self.terminal = terminal
        ResumeTerminal.save(terminal, to: defaults)
        refreshAvailability()
    }

    /// Connect the popover and the window (§4.6 "Resume and Branch"): Resume
    /// and Branch pass this setting's value as `--terminal`, their enabled
    /// state follows availability, and every surface show decides
    /// availability again (after the show's existing work).
    func attach(to surface: MainSurfaceModel) {
        surface.resumeTerminal = { [weak self] in self?.cliValue ?? ResumeTerminal.iterm2.cliValue }
        let previous = surface.onSurfaceShown
        surface.onSurfaceShown = { [weak self] in
            previous()
            self?.refreshAvailability()
        }
        // `$availability` emits the current value on subscription, then
        // each new value.
        $availability
            .removeDuplicates()
            .sink { [weak surface] availability in surface?.resumeTerminalAvailabilityChanged(availability) }
            .store(in: &subscriptions)
    }

    /// Decide again whether the chosen terminal can be used (§4.5: when the
    /// Settings window shows, when the popover or the window shows, and when
    /// the app becomes active).
    func refreshAvailability() {
        let next = ResumeTerminalAvailability.evaluate(terminal, lookup: lookup)
        if next != availability { availability = next }
    }
}
