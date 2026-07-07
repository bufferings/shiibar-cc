// Standard notification sound catalog logic (DESIGN.md §4.5 "Settings
// window" / §8.26): turning a raw directory listing of
// /System/Library/Sounds into the sorted, extension-stripped names shown in
// the Waiting/Done sound pickers, plus the default name and the single-item
// fallback catalog used when enumeration fails (never crash, §4.5). The
// actual FileManager enumeration is I/O and lives in the app layer
// (ShiibarCcApp's SoundEnumerator) — this file is only the pure, testable
// part.

import Foundation

public enum SoundCatalog {
    /// Default sound for both Waiting and Done (DESIGN.md §4.5/§9: both
    /// default to Glass — keeps the pre-M14 notification sound unchanged).
    public static let defaultSoundName = "Glass"

    /// Fallback catalog used when enumerating /System/Library/Sounds fails,
    /// or yields nothing (DESIGN.md §4.5: if enumeration fails, fall back to
    /// a single choice of Glass only — never crash).
    public static let fallback = [defaultSoundName]

    /// Turn raw filenames (as returned by a directory listing) into the
    /// sorted, extension-stripped, de-duplicated display names for the
    /// picker (DESIGN.md §4.5: show the extension-stripped names sorted).
    public static func names(fromFilenames filenames: [String]) -> [String] {
        let stripped = filenames.map { filename in
            URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        }
        return Array(Set(stripped)).sorted()
    }
}
