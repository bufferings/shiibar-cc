import XCTest
@testable import ConversationsWebPaneKit

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

    /// Runs `deliver` (a load or an update, plus any other calls made before
    /// the render) and waits for the first render that follows. When the
    /// controller re-injected the rendered generation because its
    /// acknowledgement was late (DESIGN.md §8.38), the page renders that
    /// generation a second time; this also waits for that render, so that it
    /// cannot arrive later and fulfill an expectation the test sets up next
    /// (for example the re-render after a recovery). Once a generation is
    /// acknowledged the controller no longer re-injects it, so checking
    /// `retriedLoadGeneration` after the first render is enough.
    /// `onRendered` stays assigned to this helper's handler afterwards.
    @MainActor
    func waitForRender(
        of controller: WebPaneController, description: String = "rendered",
        timeout: TimeInterval = 20, after deliver: () -> Void
    ) {
        var generations: [Int] = []
        var onRepeatedRender: (() -> Void)?
        let rendered = renderExpectation(description: description)
        controller.onRendered = { [weak controller] _ in
            generations.append(controller?.lastRenderedAck?.generation ?? 0)
            rendered.fulfill()
            onRepeatedRender?()
        }
        deliver()
        wait(for: [rendered], timeout: timeout)

        guard let generation = generations.first,
              controller.retriedLoadGeneration >= generation else { return }
        let renderedTwice = { generations.filter { $0 == generation }.count >= 2 }
        guard !renderedTwice() else { return }
        let repeated = renderExpectation(description: "\(description) (re-injected generation \(generation))")
        onRepeatedRender = { if renderedTwice() { repeated.fulfill() } }
        wait(for: [repeated], timeout: timeout)
    }
}
