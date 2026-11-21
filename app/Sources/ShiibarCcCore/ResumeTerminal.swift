// Which terminal Resume and Branch open in (DESIGN.md §4.5 "Settings window"
// > Terminal, §4.6 "Resume and Branch", §8.66, §9): the Settings window's
// `Terminal` row. The decisions are pure and live here so tests can pin
// them — the first value at launch (with the one-time migration of the old
// key), whether the chosen terminal can be used, and the messages shown when
// it cannot. The app target looks up installed apps and keeps the observable
// state.
//
// The bundle ids and the Ghostty minimum version are app-side constants
// (§8.66: an exception to keeping terminal knowledge in the terminal modules
// of `shiibar-cc-client`; they are not AppleScript or id-format knowledge).

import Foundation

/// The terminal Resume and Branch open a new window in (§4.5/§4.6). The raw
/// value is both the stored UserDefaults value and the `--terminal` value
/// passed to `shiibar-cc resume` (§9).
public enum ResumeTerminal: String, CaseIterable, Equatable, Sendable {
    case iterm2
    case appleTerminal = "apple-terminal"
    case ghostty

    /// UserDefaults key of the setting (§9).
    public static let defaultsKey = "cc.shiibar.resumeTerminal"
    /// The key the app used to remember the last observed terminal kind.
    /// Read once at launch to pick the first value, and removed at every
    /// launch (§4.5 "Settings window" > Terminal: one-time migration of the
    /// storage format, §8.66).
    public static let legacyObservedTerminalKey = "cc.shiibar.lastObservedTerminal"

    /// The `--terminal` value (§4.6: iTerm2 = `iterm2`, Terminal =
    /// `apple-terminal`, Ghostty = `ghostty`).
    public var cliValue: String { rawValue }

    /// The segment's title (§4.5 table: iTerm2 / Terminal / Ghostty).
    public var displayName: String {
        switch self {
        case .iterm2: return "iTerm2"
        case .appleTerminal: return "Terminal"
        case .ghostty: return "Ghostty"
        }
    }

    /// The bundle id the installed app is looked up by (§9).
    public var bundleIdentifier: String {
        switch self {
        case .iterm2: return "com.googlecode.iterm2"
        case .appleTerminal: return "com.apple.Terminal"
        case .ghostty: return "com.mitchellh.ghostty"
        }
    }

    /// The minimum Ghostty version (§9): the first version whose AppleScript
    /// `terminal` has `tty`.
    public static let ghosttyMinimumVersion = TerminalVersion(major: 1, minor: 4, patch: 0)

    /// A stored value read as a setting: one of the three choices, else nil
    /// (a value that is none of them counts as not stored — §4.5).
    public static func decode(_ stored: Any?) -> ResumeTerminal? {
        (stored as? String).flatMap(ResumeTerminal.init(rawValue:))
    }

    /// The first value (§4.5 "Settings window" > Terminal): the old key's
    /// value when it is `iterm2` or `apple-terminal`, else iTerm2 when it is
    /// installed, else Terminal. Ghostty is never the first value (it has a
    /// minimum version, so it is the user's choice). `isITerm2Installed` is
    /// asked only when the old key does not decide.
    public static func firstValue(legacy: Any?, isITerm2Installed: () -> Bool) -> ResumeTerminal {
        if let legacy = decode(legacy), legacy != .ghostty {
            return legacy
        }
        return isITerm2Installed() ? .iterm2 : .appleTerminal
    }

    /// The launch-time step (§4.5): when no valid value is stored, decide the
    /// first value once and store it; the old key is removed whether or not
    /// a value was stored. Returns the setting's value.
    @discardableResult
    public static func prepareAtLaunch(
        defaults: UserDefaults,
        isInstalled: (ResumeTerminal) -> Bool
    ) -> ResumeTerminal {
        let legacy = defaults.object(forKey: legacyObservedTerminalKey)
        defaults.removeObject(forKey: legacyObservedTerminalKey)
        if let stored = decode(defaults.object(forKey: defaultsKey)) {
            return stored
        }
        let first = firstValue(legacy: legacy, isITerm2Installed: { isInstalled(.iterm2) })
        save(first, to: defaults)
        return first
    }

    /// The stored setting; iTerm2 when nothing valid is stored (only before
    /// `prepareAtLaunch` has run).
    public static func load(from defaults: UserDefaults) -> ResumeTerminal {
        decode(defaults.object(forKey: defaultsKey)) ?? .iterm2
    }

    public static func save(_ terminal: ResumeTerminal, to defaults: UserDefaults) {
        defaults.set(terminal.rawValue, forKey: defaultsKey)
    }
}

/// A terminal version as `major.minor.patch` (§4.1 `TERM_PROGRAM_VERSION`
/// rule, also used for the installed Ghostty's `CFBundleShortVersionString`
/// — §4.5): only the part before the first `-` or `+` counts, and it must be
/// exactly three dot-separated decimal numbers.
public struct TerminalVersion: Comparable, Equatable, Sendable {
    public let major: UInt64
    public let minor: UInt64
    public let patch: UInt64

    public init(major: UInt64, minor: UInt64, patch: UInt64) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// `1.4.0` and `1.4.0-main+abc1234` read as 1.4.0; anything other than
    /// three decimal numbers in front of the first `-` / `+` reads as nil.
    public static func parse(_ text: String) -> TerminalVersion? {
        let head = text.prefix { $0 != "-" && $0 != "+" }
        let parts = head.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [UInt64] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ ("0"..."9").contains($0) }),
                  let number = UInt64(part) else { return nil }
            numbers.append(number)
        }
        return TerminalVersion(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    public static func < (lhs: TerminalVersion, rhs: TerminalVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// An installed app as found by its bundle id: the bundle's
/// `CFBundleShortVersionString`, nil when the bundle has none.
public struct InstalledTerminalApp: Equatable, Sendable {
    public let shortVersion: String?

    public init(shortVersion: String?) {
        self.shortVersion = shortVersion
    }
}

/// Whether the chosen terminal can be used (§4.5 "Settings window" >
/// Terminal), and the messages when it cannot.
public enum ResumeTerminalAvailability: Equatable, Sendable {
    case available
    /// The app is not installed (iTerm2 or Ghostty).
    case notInstalled(ResumeTerminal)
    /// The installed Ghostty is older than the minimum version (§9), or its
    /// version cannot be read by the §4.1 rule.
    case ghosttyTooOld

    /// Decide from the installed app found by the terminal's bundle id
    /// (`lookup` returns nil when no app has that id). Terminal is part of
    /// macOS and is always usable, so it is not looked up. A running Ghostty
    /// older than an installed one that meets the minimum is not detected
    /// here (the CLI's exit 1 shows in the message line instead — §4.5).
    public static func evaluate(
        _ terminal: ResumeTerminal,
        lookup: (_ bundleIdentifier: String) -> InstalledTerminalApp?
    ) -> ResumeTerminalAvailability {
        switch terminal {
        case .appleTerminal:
            return .available
        case .iterm2:
            return lookup(terminal.bundleIdentifier) == nil ? .notInstalled(.iterm2) : .available
        case .ghostty:
            guard let app = lookup(terminal.bundleIdentifier) else { return .notInstalled(.ghostty) }
            guard let version = app.shortVersion.flatMap(TerminalVersion.parse),
                  version >= ResumeTerminal.ghosttyMinimumVersion else { return .ghosttyTooOld }
            return .available
        }
    }

    public var isAvailable: Bool { self == .available }

    /// The one line under the `Terminal` row's description (§4.5); nil
    /// while usable.
    public var settingsMessage: String? {
        switch self {
        case .available: return nil
        case .notInstalled(let terminal): return "\(terminal.displayName) is not installed"
        case .ghosttyTooOld: return "Ghostty 1.4.0 or later is required"
        }
    }

    /// The tooltip of the disabled Resume and Branch (§4.6 "Resume and
    /// Branch"); nil while usable.
    public var buttonTooltip: String? {
        settingsMessage.map { "\($0) \u{2014} choose a terminal in Settings" }
    }
}

// MARK: - Resume and Branch while the terminal cannot be used (§4.5 "action
// buttons", §4.6 "Resume and Branch")

extension RowButton {
    /// Resume and Branch are disabled while the chosen terminal cannot be
    /// used, with the reason as the tooltip — also when the button is
    /// already disabled for a missing cwd or session_id (the terminal's
    /// reason wins, §4.6). Jump is unaffected (it goes to the terminal the
    /// session runs in, not the setting's).
    public func applying(_ availability: ResumeTerminalAvailability) -> RowButton {
        guard kind != .jump, let tooltip = availability.buttonTooltip else { return self }
        return RowButton(kind: kind, invocation: nil, tooltip: tooltip)
    }
}
