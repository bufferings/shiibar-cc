import XCTest

extension XCTestCase {
    /// An expectation to fulfill from `WebPaneController.onRendered`. The page
    /// can report a render more than once per load: the controller re-injects
    /// a load whose acknowledgement is late (DESIGN.md §8.38), and the page
    /// then renders it again. A repeated `fulfill()` must not raise, so
    /// over-fulfillment is allowed; tests that count renders check the count
    /// themselves.
    func renderExpectation(description: String) -> XCTestExpectation {
        let rendered = expectation(description: description)
        rendered.assertForOverFulfill = false
        return rendered
    }
}
