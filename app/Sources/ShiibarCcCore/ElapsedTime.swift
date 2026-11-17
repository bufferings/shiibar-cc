// Elapsed-time formatting for the bottom of a list row's symbol-and-time
// column (DESIGN.md §4.5) and the pane header's `<elapsed> ago`
// (window-design.html). DESIGN.md does not pin an exact format (only the
// mockup's example values like "2m" / "1h"); this picks the coarsest unit
// that keeps at least one digit of precision, which matches every example
// in the mockup.

import Foundation

public enum ElapsedTime {
    public static func format(seconds: Int64) -> String {
        let seconds = max(0, seconds)
        if seconds < 60 {
            return "\(seconds)s"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "\(hours)h"
        }
        let days = hours / 24
        return "\(days)d"
    }
}
