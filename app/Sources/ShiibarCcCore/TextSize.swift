// The text size of the popover and the window (DESIGN.md §4.5 "text size",
// §4.6 "text size", §8.52, §9): one integer setting, the body text size in
// points. Every scaled dimension of the two surfaces is its value at 13
// (docs/window-design.html) times `ratio`. Persistence (UserDefaults), the
// keys and the Settings field live in ShiibarCcApp; the range, the stored-
// value interpretation, the key steps, the field's parsing and the widths
// that follow the ratio live here so tests can pin them to the spec.

import Foundation

public struct TextSize: Equatable, Hashable, Sendable {
    /// §9: smallest value (points).
    public static let minimum = 9
    /// §9: largest value (points).
    public static let maximum = 18
    /// §9: default value, the ⌘0 target, and the size every base dimension
    /// is given at (ratio 1).
    public static let base = 13
    public static let `default` = TextSize(clamping: base)

    /// §4.5 / §9: the popover width and the two-column list column width at
    /// the base size.
    public static let surfaceWidthAtBase: Double = 420
    /// §4.5 / §9: the two-column threshold is the list column width plus
    /// this (780pt at the base size). It is the right column's minimum
    /// width, the same value as the window's minimum width.
    public static let twoColumnPaneAllowance: Double = 360

    /// The body text size in points, always within `minimum...maximum`.
    public let points: Int

    /// A value inside the range: out-of-range input becomes the nearer end.
    public init(clamping points: Int) {
        self.points = min(max(points, Self.minimum), Self.maximum)
    }

    /// The scale factor of every scaled dimension: `points / 13`.
    public var ratio: Double { Self.ratio(forPoints: Double(points)) }

    /// The scale factor of a body size given in points (the web page takes
    /// the size as a number).
    public static func ratio(forPoints points: Double) -> Double {
        points / Double(base)
    }

    // MARK: Stored value

    /// The value a stored UserDefaults entry stands for (§4.5): a missing or
    /// non-numeric entry is the default; a non-integer is rounded half away
    /// from zero; out of range is the nearer end. The caller does not write
    /// the result back (the stored entry stays until the next change).
    public static func fromStored(_ stored: Double?) -> TextSize {
        guard let stored, stored.isFinite else { return .default }
        let rounded = stored.rounded(.toNearestOrAwayFromZero)
        if rounded <= Double(minimum) { return TextSize(clamping: minimum) }
        if rounded >= Double(maximum) { return TextSize(clamping: maximum) }
        return TextSize(clamping: Int(rounded))
    }

    // MARK: Keys (⌘= / ⌘− / ⌘0)

    /// ⌘= / ⌘+: one larger, or nil at the maximum (nothing changes).
    public var larger: TextSize? {
        points < Self.maximum ? TextSize(clamping: points + 1) : nil
    }

    /// ⌘−: one smaller, or nil at the minimum (nothing changes).
    public var smaller: TextSize? {
        points > Self.minimum ? TextSize(clamping: points - 1) : nil
    }

    /// ⌘0: the default, or nil when already there (nothing changes).
    public var reset: TextSize? {
        self == .default ? nil : .default
    }

    // MARK: Settings field

    /// Why the Settings field's text was rejected (§4.5 "Settings window").
    public enum InputError: Error, Equatable, Sendable {
        case notWholeNumber
        case outOfRange

        /// The line shown under the description.
        public var message: String {
            switch self {
            case .notWholeNumber: return "Enter a whole number"
            case .outOfRange: return "Enter a number from \(TextSize.minimum) to \(TextSize.maximum)"
            }
        }
    }

    /// The Settings field's text as a value (§4.5 "Settings window"):
    /// surrounding whitespace is ignored; anything but a run of ASCII digits
    /// (a sign included) is not a whole number; a run of digits outside the
    /// range (however long) is out of range.
    public static func parse(_ text: String) -> Result<TextSize, InputError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return .failure(.notWholeNumber)
        }
        guard let value = Int(trimmed), (minimum...maximum).contains(value) else {
            return .failure(.outOfRange)
        }
        return .success(TextSize(clamping: value))
    }

    // MARK: Widths that follow the ratio

    /// §4.5: the popover width, 420pt at 13, rounded to a whole point.
    public var popoverWidth: Double {
        (Self.surfaceWidthAtBase * ratio).rounded(.toNearestOrAwayFromZero)
    }

    /// §4.5 / §9: the default list column width in two columns, the same
    /// value as the popover width.
    public var listColumnWidth: Double { popoverWidth }

    /// §4.5 / §9: the window shows two columns at or above this width.
    public var twoColumnMinimumWidth: Double { listColumnWidth + Self.twoColumnPaneAllowance }
}
