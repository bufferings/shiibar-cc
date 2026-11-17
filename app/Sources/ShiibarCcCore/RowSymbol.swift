// Running row status symbol, at the top of the row's symbol-and-time column
// (DESIGN.md §4.5 "Running rows",
// window-design.html): dim static ✻ = idle / outlined speech bubble + bold
// "!" = waiting / glyph-cycle spinner = working. The actual drawing lives in
// the app layer (`RowSymbolView`); this is just the pure
// `AgentStatus -> symbol kind` selection, kept separately testable.

import Foundation

/// Which of the three row symbols to draw for a given status. `nil` for
/// `.unknown` — `UnifiedListBuilder.runningRow` drops unknown-status agents
/// on exactly this nil (clients ignore unknown statuses — §4.2), rather
/// than defaulting silently to some symbol.
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
