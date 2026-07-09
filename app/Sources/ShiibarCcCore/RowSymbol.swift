// Dropdown row leading status symbol (DESIGN.md §4.5, menubar-design.html's
// dropdown section): empty circle = idle / circle + bold "!" = waiting /
// rotating spinner = working. The actual drawing lives in the app layer
// (`RowSymbolView`, SwiftUI shapes render fine inside the dropdown window —
// unlike the tray, see `TrayIconRenderer`'s header comment); this is just
// the pure `AgentStatus -> symbol kind` selection, kept separately testable
// per the M5 T9 brief.

import Foundation

/// Which of the three row symbols to draw for a given status. `nil` for
/// `.unknown` — callers already exclude unknown-status agents from both the
/// flat (`Sorting.newestFirst`) and grouped (`Grouping.groupedRows`) row
/// lists, so this is never actually looked up for one in practice; it's
/// still handled explicitly rather than defaulting silently to some symbol.
public enum RowSymbolKind: Equatable, Sendable {
    case idle
    case waiting
    case working
}

public enum RowSymbol {
    public static func kind(for status: AgentStatus) -> RowSymbolKind? {
        switch status {
        case .idle: return .idle
        case .waiting: return .waiting
        case .working: return .working
        case .unknown: return nil
        }
    }
}
