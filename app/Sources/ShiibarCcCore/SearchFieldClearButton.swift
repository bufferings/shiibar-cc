// When the search field shows its clear button (DESIGN.md §4.6 "search
// field"): only while the field holds text, and never while the field is
// disabled (a full index build), because a disabled field cannot be edited.

public enum SearchFieldClearButton {
    /// - Parameters:
    ///   - text: the field's current text, including uncommitted IME
    ///     (marked) text, since that text is visible in the field.
    ///   - isEnabled: whether the field accepts input.
    public static func isShown(text: String, isEnabled: Bool) -> Bool {
        isEnabled && !text.isEmpty
    }
}
