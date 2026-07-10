// "Keep on Top" (DESIGN.md §4.5/§8.33, M30): an app-menu toggle that keeps
// the Agents window at the floating window level while ON — and ONLY the
// level; Space-following (collectionBehavior) stays untouched, a separate
// kind of pushiness §8.33 deliberately keeps out. Default OFF: §8.30
// rejected always-on-top as a DEFAULT (an uninvited squatter); an explicit
// user toggle doesn't contradict that. Persisted in UserDefaults and
// re-applied on every open; toggling applies immediately to a visible
// window. This type holds the view-free default so it can be pinned by a
// test; the UserDefaults IO and the NSWindow.Level application live in
// `AppState` (AppKit, not testable in this target).

import Foundation

public enum AgentsWindowKeepOnTop {
    /// §8.33: default OFF — turning it on is always the user's explicit
    /// act. A missing UserDefaults value must read as this.
    public static let defaultEnabled = false
}
