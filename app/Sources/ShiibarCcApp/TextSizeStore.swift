// The one owner of the text size of the popover and the window (DESIGN.md
// §4.5 "text size", §8.52): ⌘= / ⌘− / ⌘0 in the popover and the window and
// the Settings window's Text size field all read and write THIS object, so
// every surface follows a change at once. Persisted in UserDefaults (§8.9:
// app UX settings are UserDefaults); the range, the steps, the stored-value
// interpretation and the field's parsing live in ShiibarCcCore.TextSize.

import Combine
import Foundation
import ShiibarCcCore

@MainActor
final class TextSizeStore: ObservableObject {
    /// UserDefaults key for the persisted text size (whole points). The key
    /// keeps its name so a value saved for the conversation pane's body size
    /// carries over (§8.52).
    static let defaultsKey = "cc.shiibar.conversationsTextSize"

    /// Current text size, always within the §9 range.
    @Published private(set) var size: TextSize

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // The stored entry is interpreted, never rewritten here: it changes
        // only with the next applied value (§4.5).
        let stored = (defaults.object(forKey: Self.defaultsKey) as? NSNumber)?.doubleValue
        self.size = TextSize.fromStored(stored)
    }

    /// Apply a value (Settings field or stepper, keys): persisted as a whole
    /// number when it differs from the current value. Returns whether it
    /// changed.
    @discardableResult
    func apply(_ value: TextSize) -> Bool {
        guard value != size else { return false }
        size = value
        defaults.set(value.points, forKey: Self.defaultsKey)
        return true
    }

    /// ⌘= / ⌘+: one larger; nothing at the maximum.
    func increase() {
        if let next = size.larger { apply(next) }
    }

    /// ⌘−: one smaller; nothing at the minimum.
    func decrease() {
        if let next = size.smaller { apply(next) }
    }

    /// ⌘0: back to 13; nothing when already there.
    func reset() {
        if let next = size.reset { apply(next) }
    }
}
