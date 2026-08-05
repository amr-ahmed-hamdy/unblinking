import AppKit

/// Draws the menu bar eye.
///
/// The eye is the whole idea: an eye that never closes is a Mac that never sleeps. So the
/// off state is a *closed* eye, and the active states are open ones.
///
/// Two rendering modes, on purpose:
///
/// - **Off** is a monochrome *template* image, so macOS tints it like every other menu bar
///   icon and it recedes. Off should be unremarkable.
/// - **Active** is full colour with a halo that breathes. Active should be impossible to
///   scan past, because the whole point of this app is that you never silently leave your
///   Mac awake.
///
/// The eye deliberately does **not** blink. A closed-eye frame is pixel-for-pixel the off
/// state, so a blinking icon would flash "asleep" every few seconds — exactly the confusion
/// this app exists to remove. Urgency is carried by colour and tempo instead.
@MainActor
enum EyeIcon {
    enum State: Hashable {
        /// Closed eye — nothing is being kept awake.
        case off
        /// Open orange eye, slow breath — assertions held.
        case on
        /// Open red eye at double tempo — lid-close sleep is disabled system-wide, the one
        /// state that can genuinely flatten a battery in a closed bag.
        case onClosedLid
    }

    /// Taller than the eye so the glow has somewhere to go without clipping against the
    /// 24pt menu bar. Constant across states, so the status item never jumps width.
    static let canvasSize = NSSize(width: 22, height: 22)

    static let framesPerSecond: Double = 12

    /// One full cycle of the calm breath: 36 frames at 12fps = 3s.
    static let frameCount = 36

    /// The urgent breath runs at double speed — 18 frames, 1.5s. A divisor of
    /// `frameCount`, so both tempos return to zero together and the loop stays seamless.
    private static let urgentPeriod = 18

    /// Used when animation is off or Reduce Motion is on: part-way up the breath, so a
    /// static icon still reads as lit rather than dimmed out.
    static let staticFrame = frameCount / 4

    private static let orangeLow = NSColor(srgbRed: 1.00, green: 0.50, blue: 0.06, alpha: 1)
    private static let orangeHigh = NSColor(srgbRed: 1.00, green: 0.74, blue: 0.22, alpha: 1)
    private static let redLow = NSColor(srgbRed: 0.86, green: 0.10, blue: 0.08, alpha: 1)
    private static let redHigh = NSColor(srgbRed: 1.00, green: 0.34, blue: 0.16, alpha: 1)

    /// The eye is authored in an 18×18 space, centred in the larger canvas.
    private static let designSize: CGFloat = 18
    private static var inset: CGFloat { (canvasSize.width - designSize) / 2 }

    private static var cache: [Key: NSImage] = [:]

    private struct Key: Hashable {
        let style: IconStyle
        let state: State
        let frame: Int
    }

    static func image(style: IconStyle, state: State, frame: Int = 0) -> NSImage {
        // Only Vivid varies frame to frame; the others collapse to one cached image.
        let normalizedFrame = (state == .off || !style.isAnimated) ? 0 : frame % frameCount
        let key = Key(style: style, state: state, frame: normalizedFrame)
        if let cached = cache[key] { return cached }

        let image = NSImage(size: canvasSize, flipped: false) { rect in
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: rect.minX, yBy: rect.minY)
            transform.scaleX(by: rect.width / canvasSize.width,
                             yBy: rect.height / canvasSize.height)
            transform.concat()
            draw(style: style, state: state, frame: normalizedFrame)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }

        // Subtle is a template throughout, so macOS tints it like any other menu bar icon.
        // The colour styles are templates only when off, where they're monochrome anyway.
        image.isTemplate = (style == .subtle || state == .off)
        cache[key] = image
        return image
    }

    // MARK: - Drawing

    private static func draw(style: IconStyle, state: State, frame: Int) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        let transform = NSAffineTransform()
        transform.translateX(by: inset, yBy: inset)
        transform.concat()

        guard state != .off else {
            drawClosedEye(color: .black)
            return
        }

        if style == .subtle {
            // Template art, so colour carries no meaning — the lid state is distinguished
            // by a badge, and the iris is a ring rather than a disc so the open eye doesn't
            // read as a blank stare.
            drawOpenEye(iris: .black, glow: 0, hollowIris: true)
            if state == .onClosedLid { drawBadge(monochrome: true) }
            return
        }

        let urgent = (state == .onClosedLid)
        let low = urgent ? redLow : orangeLow
        let high = urgent ? redHigh : orangeHigh

        switch style {
        case .colour:
            // Held still, and held bright: parking a static icon at the dim end of the
            // breath would make it read as half-off.
            drawOpenEye(iris: blend(low, high, 0.6), glow: 0)
        case .vivid:
            let t = breath(frame: frame, period: urgent ? urgentPeriod : frameCount)
            // The urgent glow never falls fully dark and peaks brighter, so it still reads
            // as urgent at the bottom of its breath.
            drawOpenEye(iris: blend(low, high, t), glow: urgent ? 0.45 + t * 0.85 : t)
        case .subtle:
            break // handled above
        }
    }

    /// Smooth 0 → 1 → 0 across `period` frames, with no discontinuity at the wrap.
    private static func breath(frame: Int, period: Int) -> CGFloat {
        let t = CGFloat(frame % period) / CGFloat(period)
        return 0.5 - 0.5 * cos(t * 2 * .pi)
    }

    private static func blend(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        NSColor(
            srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t,
            green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
            blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t,
            alpha: 1
        )
    }

    // MARK: - Shapes

    private static let eyeWidth: CGFloat = 14
    private static let eyeCenterX: CGFloat = 9
    private static let eyeCenterY: CGFloat = 9
    private static let irisRadius: CGFloat = 3.3

    /// The almond outline: two mirrored curves meeting at the corners.
    private static func openEyePath() -> NSBezierPath {
        let path = NSBezierPath()
        let half = eyeWidth / 2
        let left = eyeCenterX - half
        let right = eyeCenterX + half
        let lift: CGFloat = 6.2

        path.move(to: NSPoint(x: left, y: eyeCenterY))
        path.curve(
            to: NSPoint(x: right, y: eyeCenterY),
            controlPoint1: NSPoint(x: eyeCenterX - eyeWidth * 0.28, y: eyeCenterY + lift),
            controlPoint2: NSPoint(x: eyeCenterX + eyeWidth * 0.28, y: eyeCenterY + lift)
        )
        path.curve(
            to: NSPoint(x: left, y: eyeCenterY),
            controlPoint1: NSPoint(x: eyeCenterX + eyeWidth * 0.28, y: eyeCenterY - lift),
            controlPoint2: NSPoint(x: eyeCenterX - eyeWidth * 0.28, y: eyeCenterY - lift)
        )
        path.close()
        return path
    }

    /// A single downward curve — a shut lid — plus three short lashes.
    private static func drawClosedEye(color: NSColor) {
        color.setStroke()

        let half = eyeWidth / 2
        let lid = NSBezierPath()
        lid.move(to: NSPoint(x: eyeCenterX - half, y: 10))
        lid.curve(
            to: NSPoint(x: eyeCenterX + half, y: 10),
            controlPoint1: NSPoint(x: eyeCenterX - eyeWidth * 0.30, y: 5),
            controlPoint2: NSPoint(x: eyeCenterX + eyeWidth * 0.30, y: 5)
        )
        lid.lineWidth = 1.5
        lid.lineCapStyle = .round
        lid.stroke()

        for offset in [-0.34, 0.0, 0.34] as [CGFloat] {
            let x = eyeCenterX + eyeWidth * offset
            let top: CGFloat = offset == 0 ? 6.35 : 7.0
            let lash = NSBezierPath()
            lash.move(to: NSPoint(x: x, y: top))
            lash.line(to: NSPoint(x: x, y: top - 1.6))
            lash.lineWidth = 1.25
            lash.lineCapStyle = .round
            lash.stroke()
        }
    }

    /// - Parameter hollowIris: draw the iris as a ring rather than a disc with a dark
    ///   pupil. Template images have no dark — only opaque and transparent — so a filled
    ///   iris there would be a featureless white blob.
    private static func drawOpenEye(iris: NSColor, glow: CGFloat, hollowIris: Bool = false) {
        // Halo built from stacked translucent discs — cheap, and unlike a blur it renders
        // identically at any scale.
        if glow > 0 {
            for ring in stride(from: 5, through: 1, by: -1) {
                let radius = irisRadius + CGFloat(ring) * 1.2
                iris.withAlphaComponent(0.105 * glow).setFill()
                NSBezierPath(ovalIn: NSRect(
                    x: eyeCenterX - radius,
                    y: eyeCenterY - radius,
                    width: radius * 2,
                    height: radius * 2
                )).fill()
            }
        }

        let eye = openEyePath()

        // Iris and pupil are clipped to the eye, so they can stay simple circles.
        NSGraphicsContext.saveGraphicsState()
        eye.setClip()

        let pupil = irisRadius * 0.42

        if hollowIris {
            // A stroked circle midway between iris and pupil radius gives the same
            // silhouette as a disc-with-pupil, without needing a second colour.
            iris.setStroke()
            let ringRadius = (irisRadius + pupil) / 2
            let ring = NSBezierPath(ovalIn: NSRect(
                x: eyeCenterX - ringRadius,
                y: eyeCenterY - ringRadius,
                width: ringRadius * 2,
                height: ringRadius * 2
            ))
            ring.lineWidth = irisRadius - pupil
            ring.stroke()
        } else {
            iris.setFill()
            NSBezierPath(ovalIn: NSRect(
                x: eyeCenterX - irisRadius,
                y: eyeCenterY - irisRadius,
                width: irisRadius * 2,
                height: irisRadius * 2
            )).fill()

            NSColor(white: 0.07, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(
                x: eyeCenterX - pupil,
                y: eyeCenterY - pupil,
                width: pupil * 2,
                height: pupil * 2
            )).fill()
        }

        NSGraphicsContext.restoreGraphicsState()

        iris.setStroke()
        eye.lineWidth = 1.5
        eye.lineJoinStyle = .round
        eye.stroke()
    }

    /// Marks closed-lid mode in the Subtle style, where colour can't carry the difference.
    private static func drawBadge(monochrome: Bool) {
        // Drawn in the canvas space rather than the eye's, so it sits in the corner.
        NSGraphicsContext.saveGraphicsState()
        let undo = NSAffineTransform()
        undo.translateX(by: -inset, yBy: -inset)
        undo.concat()

        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: 15.4, y: 15.4, width: 4.6, height: 4.6)).fill()

        NSGraphicsContext.restoreGraphicsState()
    }
}
