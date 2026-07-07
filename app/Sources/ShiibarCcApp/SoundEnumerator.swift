// Enumerates /System/Library/Sounds at runtime for the Settings window's
// Waiting/Done sound pickers (DESIGN.md §4.5/§8.26). This is the I/O half —
// the directory listing itself, via `FileManager` — of a split with
// ShiibarCcCore's `SoundCatalog`, which does the pure, testable part
// (extension-stripping, sorting, de-duplication, and the fallback value).

import Foundation
import ShiibarCcCore

enum SoundEnumerator {
    static let soundsDirectory = "/System/Library/Sounds"

    /// The sorted, extension-stripped sound names to offer in the pickers.
    /// Falls back to `SoundCatalog.fallback` (Glass only) if the directory
    /// can't be listed, or lists nothing — DESIGN.md §4.5: if enumeration
    /// fails, fall back to a single choice of Glass only (never crash).
    static func availableSoundNames() -> [String] {
        guard let filenames = try? FileManager.default.contentsOfDirectory(atPath: soundsDirectory) else {
            return SoundCatalog.fallback
        }
        let names = SoundCatalog.names(fromFilenames: filenames)
        return names.isEmpty ? SoundCatalog.fallback : names
    }
}
