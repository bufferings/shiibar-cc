// The one owner of the Conversations body text size (DESIGN.md §4.6/§4.5):
// cmd-plus / cmd-minus / cmd-0 on the Conversations window and the Settings
// window's Conversations stepper all read and write THIS object, so both
// UIs stay live-synced (a change from either side republishes immediately).
// Persisted in UserDefaults (§8.9: app UX settings are UserDefaults); the
// range/step/default numbers live in ShiibarCcCore.ConversationsTextSize,
// pinned to §9 by tests.

import Foundation
import ShiibarCcCore

@MainActor
final class ConversationsTextSizeStore: ObservableObject {
    /// UserDefaults key for the persisted body size (points).
    static let defaultsKey = "cc.shiibar.conversationsTextSize"

    /// Current body size (points), always within the §9 range.
    @Published private(set) var size: Double

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.object(forKey: Self.defaultsKey) as? Double
        self.size = ConversationsTextSize.clamp(stored ?? ConversationsTextSize.defaultSize)
    }

    /// Set an explicit size (Settings stepper); clamped and persisted.
    func set(_ value: Double) {
        let clamped = ConversationsTextSize.clamp(value)
        guard clamped != size else { return }
        size = clamped
        defaults.set(clamped, forKey: Self.defaultsKey)
    }

    /// cmd-plus: one step larger (§4.6).
    func increase() { set(ConversationsTextSize.increased(size)) }

    /// cmd-minus: one step smaller (§4.6).
    func decrease() { set(ConversationsTextSize.decreased(size)) }

    /// cmd-0: back to the §9 default.
    func reset() { set(ConversationsTextSize.defaultSize) }
}
