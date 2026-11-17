import AppKit
import QuartzCore
import ShiibarCcCore
import SwiftUI
import XCTest
@testable import ShiibarCcApp

/// The working row spinner (DESIGN.md §4.5 "updates while visible", §8.57,
/// §9): a discrete Core Animation keyframe animation that exists only while
/// spinning in a window, survives the view leaving and re-entering a
/// window, stays in phase across rows, and draws the glyphs where the
/// SwiftUI text rendering of the same glyph would. The window is never
/// ordered onto the screen.
@MainActor
final class WorkingSpinnerViewTests: XCTestCase {
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: true
        )
        // ARC holds the reference; release-on-close would double-free.
        window.isReleasedWhenClosed = false
        return window
    }

    private func makeView(size: CGFloat = 20, spinning: Bool) -> WorkingSpinnerNSView {
        let view = WorkingSpinnerNSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.configure(glyphFontSize: size * 15.5 / 20, size: size, spinning: spinning)
        return view
    }

    private func animation(of view: WorkingSpinnerNSView) -> CAKeyframeAnimation? {
        view.glyphLayer.animation(forKey: WorkingSpinnerNSView.animationKey) as? CAKeyframeAnimation
    }

    func testSpinningInAWindowRunsADiscreteRepeatingKeyframeAnimation() throws {
        let window = makeWindow()
        let view = makeView(spinning: true)
        window.contentView?.addSubview(view)

        let animation = try XCTUnwrap(animation(of: view))
        XCTAssertEqual(animation.keyPath, "contents")
        XCTAssertEqual(animation.calculationMode, .discrete)
        XCTAssertEqual(animation.duration, GlyphCycleSpinner.periodSeconds)
        XCTAssertEqual(animation.repeatCount, .infinity)
        let keyframes = GlyphCycleSpinner.keyframes
        XCTAssertEqual(animation.keyTimes?.map(\.doubleValue), keyframes.keyTimes)
        XCTAssertEqual(animation.values?.count, keyframes.frameIndices.count)
        for (value, index) in zip(animation.values ?? [], keyframes.frameIndices) {
            XCTAssertTrue((value as CFTypeRef) === view.glyphImages[index], "each keyframe shows the image of its frame")
        }
    }

    func testNotSpinningHasNoAnimation() {
        // Spinning only while the surface is visible and the row is
        // working; otherwise no animation runs (DESIGN.md §4.5).
        let window = makeWindow()
        let view = makeView(spinning: false)
        window.contentView?.addSubview(view)
        XCTAssertNil(animation(of: view))
        XCTAssertNotNil(view.glyphLayer.contents, "a still frame is shown while not spinning")
    }

    func testStoppingRemovesTheAnimationAndRestartingAddsIt() {
        let window = makeWindow()
        let view = makeView(spinning: true)
        window.contentView?.addSubview(view)
        XCTAssertNotNil(animation(of: view))

        view.configure(glyphFontSize: view.glyphFontSize, size: view.size, spinning: false)
        XCTAssertNil(animation(of: view))

        view.configure(glyphFontSize: view.glyphFontSize, size: view.size, spinning: true)
        XCTAssertNotNil(animation(of: view))
    }

    func testOutsideAWindowNoAnimationIsAdded() {
        // Core Animation drops animations of layers outside a window's
        // layer tree, so the view adds its animation on entering a window.
        let view = makeView(spinning: true)
        XCTAssertNil(animation(of: view))
    }

    func testReenteringAWindowAddsTheAnimationAgain() {
        let window = makeWindow()
        let view = makeView(spinning: true)
        window.contentView?.addSubview(view)
        view.removeFromSuperview()
        // Stand in for Core Animation dropping the animation of a layer
        // that left the window's layer tree.
        view.glyphLayer.removeAllAnimations()

        window.contentView?.addSubview(view)
        XCTAssertNotNil(animation(of: view), "the animation must run again after the view re-enters a window")
    }

    func testRowsStartedAtDifferentTimesAreInPhase() throws {
        // Every row's animation begins on a period boundary of the shared
        // media clock, so a row added later shows the same glyph.
        let window = makeWindow()
        let first = makeView(spinning: true)
        window.contentView?.addSubview(first)
        let second = makeView(spinning: true)
        window.contentView?.addSubview(second)

        let period = GlyphCycleSpinner.periodSeconds
        for view in [first, second] {
            let begin = try XCTUnwrap(animation(of: view)).beginTime
            let mediaBegin = view.glyphLayer.convertTime(begin, to: nil)
            let periods = mediaBegin / period
            XCTAssertEqual(periods, periods.rounded(), accuracy: 1e-9, "begin time must be a period boundary")
            XCTAssertLessThanOrEqual(mediaBegin, CACurrentMediaTime())
            XCTAssertGreaterThan(mediaBegin, CACurrentMediaTime() - 2 * period)
        }
    }

    func testTextSizeChangeRendersTheGlyphsAtTheNewSize() throws {
        let window = makeWindow()
        let view = makeView(size: 20, spinning: true)
        window.contentView?.addSubview(view)
        let scale = window.backingScaleFactor
        XCTAssertEqual(view.glyphImages.first?.width, Int((20 * scale).rounded(.up)))

        view.configure(glyphFontSize: 30 * 15.5 / 20, size: 30, spinning: true)
        XCTAssertEqual(view.glyphImages.first?.width, Int((30 * scale).rounded(.up)))
        let animation = try XCTUnwrap(animation(of: view))
        XCTAssertTrue((animation.values?.first as CFTypeRef?) === view.glyphImages[0], "the animation must show the re-rendered images")
    }

    func testFillFollowsTheEffectiveAppearance() throws {
        // The glyphs are drawn in the label color (what SwiftUI's
        // Color.primary resolves to) for the view's appearance.
        let view = makeView(spinning: false)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            view.appearance = appearance
            view.viewDidChangeEffectiveAppearance()
            var expected: CGColor?
            appearance.performAsCurrentDrawingAppearance { expected = NSColor.labelColor.cgColor }
            XCTAssertEqual(view.colorLayer.backgroundColor, expected, "fill for \(name.rawValue)")
        }
    }

    func testTheMaskedColorLayerIsPartOfTheViewsLayerTree() throws {
        // Without this the glyph would never reach the screen.
        let window = makeWindow()
        let view = makeView(spinning: true)
        window.contentView?.addSubview(view)
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.colorLayer.superlayer === view.layer)
        XCTAssertTrue(view.colorLayer.mask === view.glyphLayer)
        XCTAssertEqual(view.colorLayer.frame, view.bounds)
        XCTAssertEqual(view.glyphLayer.frame, view.colorLayer.bounds)
    }

    func testDoesNotInterceptClicks() {
        let view = makeView(spinning: true)
        XCTAssertNil(view.hitTest(NSPoint(x: 10, y: 10)))
    }

    /// The glyph image covers the same pixels as SwiftUI's
    /// `Text(glyph).font(.system(size:))` centered in the same frame, so
    /// the working symbol keeps the idle symbol's size and position.
    func testGlyphImagesMatchTheSwiftUITextRendering() throws {
        let box: CGFloat = 20
        let fontSize = box * 15.5 / 20
        let scale: CGFloat = 2
        for glyph in GlyphCycleSpinner.glyphs {
            let ours = try XCTUnwrap(GlyphImageRenderer.image(glyph: glyph, fontSize: fontSize, boxSize: box, scale: scale))
            let renderer = ImageRenderer(content:
                Text(glyph).font(.system(size: fontSize)).foregroundStyle(Color.black)
                    .frame(width: box, height: box)
            )
            renderer.scale = scale
            let reference = try XCTUnwrap(renderer.cgImage)
            let a = try XCTUnwrap(AlphaStats(ours))
            let b = try XCTUnwrap(AlphaStats(reference))
            XCTAssertEqual(a.width, b.width)
            XCTAssertEqual(a.coverage, b.coverage, accuracy: b.coverage * 0.05 + 1, "ink amount of \(glyph)")
            XCTAssertEqual(a.centroidX, b.centroidX, accuracy: 0.5, "horizontal position of \(glyph)")
            XCTAssertEqual(a.centroidY, b.centroidY, accuracy: 0.5, "vertical position of \(glyph)")
        }
    }
}

/// Total alpha and alpha-weighted centroid of an image, in pixels from the
/// top-left corner.
private struct AlphaStats {
    let width: Int
    let coverage: Double
    let centroidX: Double
    let centroidY: Double

    init?(_ image: CGImage) {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var total = 0.0
        var sumX = 0.0
        var sumY = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let alpha = Double(pixels[(y * width + x) * 4 + 3]) / 255
                total += alpha
                sumX += alpha * Double(x)
                sumY += alpha * Double(y)
            }
        }
        guard total > 0 else { return nil }
        self.width = width
        coverage = total
        centroidX = sumX / total
        centroidY = sumY / total
    }
}
