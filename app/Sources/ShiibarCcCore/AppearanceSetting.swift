// Appearance setting (DESIGN.md §4.5 Settings > General "Appearance",
// §8.30, M27 T5): System / Light / Dark, default System. The app applies it
// as `NSApp.appearance` the moment it's picked, persists it in UserDefaults
// (via `rawValue`), and re-applies it at launch. This type holds the
// view-free half — the persisted-string and appearance-name mappings — so
// they can be unit-tested; the one AppKit call lives in `AppState`.

import Foundation

public enum AppearanceSetting: String, CaseIterable {
    case system
    case light
    case dark

    /// §4.5: default System = follow the OS.
    public static let defaultSetting: AppearanceSetting = .system

    /// Settings-window popup label (UI wording is English, §4.5).
    /// `allCases` order is the popup order: the default first.
    public var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// The `NSAppearance.Name` rawValue to apply, or nil for "follow the
    /// OS" (`NSApp.appearance = nil`). Stored as plain strings because
    /// this target is Foundation-only; the test target imports AppKit and
    /// asserts these equal `NSAppearance.Name.aqua/.darkAqua` (also
    /// verified on-device, macOS 14, M27).
    public var nsAppearanceNameRawValue: String? {
        switch self {
        case .system: return nil
        case .light: return "NSAppearanceNameAqua"
        case .dark: return "NSAppearanceNameDarkAqua"
        }
    }
}
