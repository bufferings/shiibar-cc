// The working row's glyph-cycle spinner (DESIGN.md §4.5 "updates while
// visible", §8.57, §9) as a layer-backed AppKit view.
//
// The glyph switching runs as a Core Animation keyframe animation on the
// layer's `contents`, so once the animation is added, the render server
// switches the frames and the app's main thread does no per-frame work.
// The keyframe times and frames come from `GlyphCycleSpinner.keyframes`.
//
// Drawing:
// - Each glyph is rendered once, off-screen by SwiftUI, as
//   `Text(glyph).font(.system(size:))` in a size x size frame (the same
//   view the idle glyph is), at the window's backing scale. Only the
//   image's alpha is used.
// - The glyph images act as the mask of a layer filled with the label
//   color, the color SwiftUI's `Color.primary` resolves to. The fill is
//   resolved for the view's effective appearance and re-resolved when that
//   appearance changes; the images themselves carry no color, so a
//   light/dark switch never re-renders them.
// - The images are re-rendered when the symbol size (text size setting)
//   or the backing scale (window moved to a display with a different
//   scale) changes.
//
// Phase: every row anchors its animation to a period boundary on the
// shared media clock (`CACurrentMediaTime`), so all rows show the same
// glyph at the same time, including a row added later.
//
// Lifecycle: Core Animation drops a layer's animations when the layer
// leaves the window's layer tree, so the animation is added again whenever
// the view moves into a window, and replaced whenever its images change.
// Replacing it keeps the phase, because the phase comes from the clock.

import AppKit
import QuartzCore
import ShiibarCcCore
import SwiftUI

struct WorkingSpinnerView: NSViewRepresentable {
    let glyphFontSize: CGFloat
    let size: CGFloat
    let spinning: Bool

    func makeNSView(context: Context) -> WorkingSpinnerNSView {
        let view = WorkingSpinnerNSView()
        view.configure(glyphFontSize: glyphFontSize, size: size, spinning: spinning)
        return view
    }

    func updateNSView(_ nsView: WorkingSpinnerNSView, context: Context) {
        nsView.configure(glyphFontSize: glyphFontSize, size: size, spinning: spinning)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WorkingSpinnerNSView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}

final class WorkingSpinnerNSView: NSView {
    static let animationKey = "glyphCycle"

    /// Filled with the label color; masked by `glyphLayer`.
    let colorLayer = CALayer()
    /// Carries the current glyph image (and the keyframe animation) as
    /// the mask of `colorLayer`.
    let glyphLayer = CALayer()

    private(set) var glyphFontSize: CGFloat = 0
    private(set) var size: CGFloat = 0
    private(set) var spinning = false
    private var renderedScale: CGFloat = 0
    private(set) var glyphImages: [CGImage] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        colorLayer.mask = glyphLayer
        glyphLayer.contentsGravity = .resize
        layer?.addSublayer(colorLayer)
        layoutLayers()
        applyColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(glyphFontSize: CGFloat, size: CGFloat, spinning: Bool) {
        let imagesChanged = glyphFontSize != self.glyphFontSize || size != self.size
        let spinningChanged = spinning != self.spinning
        self.glyphFontSize = glyphFontSize
        self.size = size
        self.spinning = spinning
        if imagesChanged {
            renderImages()
        } else if spinningChanged {
            refreshAnimation()
        }
    }

    // The symbol is decoration inside the row; clicks belong to the row.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        applyColor()
    }

    override func layout() {
        super.layout()
        layoutLayers()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutLayers()
    }

    private func layoutLayers() {
        withoutImplicitAnimations {
            colorLayer.frame = bounds
            glyphLayer.frame = colorLayer.bounds
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if backingScale != renderedScale {
            renderImages()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColor()
        if backingScale != renderedScale {
            renderImages()
        } else {
            refreshAnimation()
        }
    }

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    private func applyColor() {
        var color: CGColor = NSColor.labelColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor.labelColor.cgColor
        }
        withoutImplicitAnimations {
            colorLayer.backgroundColor = color
        }
    }

    private func renderImages() {
        let scale = backingScale
        renderedScale = scale
        glyphImages = GlyphCycleSpinner.glyphs.compactMap {
            GlyphImageRenderer.image(glyph: $0, fontSize: glyphFontSize, boxSize: size, scale: scale)
        }
        withoutImplicitAnimations {
            colorLayer.contentsScale = scale
            glyphLayer.contentsScale = scale
        }
        refreshAnimation()
    }

    /// Sets the still frame for the current time and, while spinning in a
    /// window, (re)adds the keyframe animation anchored to the shared clock.
    private func refreshAnimation() {
        glyphLayer.removeAnimation(forKey: Self.animationKey)
        guard glyphImages.count == GlyphCycleSpinner.glyphs.count else { return }
        let now = CACurrentMediaTime()
        withoutImplicitAnimations {
            glyphLayer.contents = glyphImages[GlyphCycleSpinner.frameIndex(atReferenceTime: now)]
        }
        guard spinning, window != nil else { return }
        glyphLayer.add(Self.makeAnimation(images: glyphImages, layer: glyphLayer, now: now), forKey: Self.animationKey)
    }

    /// A repeating discrete keyframe animation over `contents`, whose
    /// begin time is the start of the current period on the media clock so
    /// every row's animation is in phase (DESIGN.md §4.5).
    static func makeAnimation(images: [CGImage], layer: CALayer, now: CFTimeInterval) -> CAKeyframeAnimation {
        let keyframes = GlyphCycleSpinner.keyframes
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.calculationMode = .discrete
        animation.values = keyframes.frameIndices.map { images[$0] }
        animation.keyTimes = keyframes.keyTimes.map { NSNumber(value: $0) }
        animation.duration = GlyphCycleSpinner.periodSeconds
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        animation.beginTime = layer.convertTime(GlyphCycleSpinner.periodStart(atOrBefore: now), from: nil)
        return animation
    }

    private func withoutImplicitAnimations(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}

/// Renders one status glyph exactly as the SwiftUI row draws it:
/// `Text(glyph).font(.system(size: fontSize))` centered in a
/// boxSize x boxSize frame, rendered off-screen by SwiftUI itself so the
/// font, fallback font, baseline and centering are the ones the idle
/// glyph gets (Core Text's own line metrics place fallback-font glyphs
/// such as these dingbats differently). The glyph is drawn in black; only
/// the image's alpha (the glyph's coverage) matters, since the image is
/// used as a mask.
@MainActor
enum GlyphImageRenderer {
    static func image(glyph: String, fontSize: CGFloat, boxSize: CGFloat, scale: CGFloat) -> CGImage? {
        guard boxSize > 0, scale > 0 else { return nil }
        let renderer = ImageRenderer(content:
            Text(glyph)
                .font(.system(size: fontSize))
                .foregroundStyle(Color.black)
                .frame(width: boxSize, height: boxSize)
        )
        renderer.scale = scale
        return renderer.cgImage
    }
}
