// ClockClock24View.swift
// ClockClock24
//
// A macOS screen saver inspired by Humans Since 1982's ClockClock 24 sculpture.
// Twenty-four analog clocks are arranged in a 3-row × 8-column grid (four digits,
// each 3 rows × 2 columns). Clock hands rotate to form the digits of the current
// time (HH:MM), updating every minute with a smooth ease-in-out animation.
//
// Architecture:
//   ClockClock24View (ScreenSaverView) — owns the 3×8 grid of ClockView subviews,
//       draws the gray wall background and dark panel, and schedules minute ticks.
//   ClockView (NSView) — a single analog clock face that animates two hands
//       (hour/minute) toward target angles using clockwise-only rotation.
//   HandPosition — caseless enum namespace holding the 13 canonical hand positions
//       and the 10 digit shapes that map positions onto the grid.
//
// Reference: github.com/ArnaudSpanneut/ClockClock24

import ScreenSaver
import Cocoa

// MARK: - Types

/// Describes the target angle (in degrees, 0 = 12 o'clock, clockwise) for
/// both hands of a single clock.
struct ClockConfig: Equatable, Sendable {
    let hours: CGFloat
    let minutes: CGFloat
}

/// Two clocks side-by-side forming one row of a digit.
typealias DigitLine = [ClockConfig]
/// Three rows of clock pairs that visually form a single digit (0–9).
typealias DigitShape = [DigitLine]
/// Four digit shapes representing the current time (HH:MM).
typealias ClockTimer = [DigitShape]

// MARK: - Hand Positions & Digit Shapes

/// Canonical hand positions and digit shape definitions.
///
/// Degrees follow clock convention: 0/360 = 12 o'clock, increasing clockwise.
/// Each digit is encoded as 3 rows × 2 clocks matching the reference implementation.
private enum HandPosition {

    // MARK: Deactivated (hands hidden toward corners)

    static let deactivateTopRight    = ClockConfig(hours: 45,  minutes: 45)
    static let deactivateBottomRight = ClockConfig(hours: 135, minutes: 135)
    static let deactivateBottomLeft  = ClockConfig(hours: 225, minutes: 225)
    static let deactivateTopLeft     = ClockConfig(hours: 315, minutes: 315)

    // MARK: Lines

    static let verticalLine = ClockConfig(hours: 360, minutes: 180)

    // MARK: Cardinal Directions (both hands pointing the same way)

    static let top    = ClockConfig(hours: 360, minutes: 360)
    static let right  = ClockConfig(hours: 90,  minutes: 90)
    static let bottom = ClockConfig(hours: 180, minutes: 180)
    static let left   = ClockConfig(hours: 270, minutes: 270)

    // MARK: Corner Angles (hands form a 90° corner)

    static let angleTopLeft     = ClockConfig(hours: 360, minutes: 270)
    static let angleTopRight    = ClockConfig(hours: 90,  minutes: 360)
    static let angleBottomLeft  = ClockConfig(hours: 270, minutes: 180)
    static let angleBottomRight = ClockConfig(hours: 180, minutes: 90)

    // MARK: Digit Shapes (0–9)

    static let digitShapes: [DigitShape] = [
        // 0
        [[angleBottomRight, angleBottomLeft],
         [verticalLine,     verticalLine],
         [angleTopRight,    angleTopLeft]],
        // 1
        [[deactivateBottomLeft, bottom],
         [deactivateBottomLeft, verticalLine],
         [deactivateBottomLeft, top]],
        // 2
        [[right,            angleBottomLeft],
         [angleBottomRight, angleTopLeft],
         [angleTopRight,    left]],
        // 3
        [[right, angleBottomLeft],
         [right, angleTopLeft],
         [right, angleTopLeft]],
        // 4
        [[bottom,               bottom],
         [angleTopRight,        verticalLine],
         [deactivateBottomLeft, top]],
        // 5
        [[angleBottomRight, left],
         [angleTopRight,    angleBottomLeft],
         [right,            angleTopLeft]],
        // 6
        [[angleBottomRight, left],
         [verticalLine,     angleBottomLeft],
         [angleTopRight,    angleTopLeft]],
        // 7
        [[right,                angleBottomLeft],
         [deactivateBottomLeft, verticalLine],
         [deactivateBottomLeft, top]],
        // 8
        [[angleBottomRight, angleBottomLeft],
         [angleTopRight,    angleTopLeft],
         [angleTopRight,    angleTopLeft]],
        // 9
        [[angleBottomRight, angleBottomLeft],
         [angleTopRight,    verticalLine],
         [right,            angleTopLeft]],
    ]
}

// MARK: - Helpers

/// Builds a `ClockTimer` (four digit shapes) from the current system time.
private func currentTimeDigits() -> ClockTimer {
    let cal = Calendar.current
    let now = Date()
    let h = cal.component(.hour,   from: now)
    let m = cal.component(.minute, from: now)
    return [
        HandPosition.digitShapes[h / 10],
        HandPosition.digitShapes[h % 10],
        HandPosition.digitShapes[m / 10],
        HandPosition.digitShapes[m % 10],
    ]
}

/// Returns the accumulated angle that rotates `current` clockwise to `targetDeg`.
/// Hands always rotate forward; they never spin backwards.
private func clockwiseAngle(from current: CGFloat, to targetDeg: CGFloat) -> CGFloat {
    let norm  = current.truncatingRemainder(dividingBy: 360)
    let base  = norm < 0 ? norm + 360 : norm
    var delta = targetDeg - base
    if delta < 0 { delta += 360 }
    return current + delta
}

// MARK: - ScreenSaver View

@objc(ClockClock24View)
final class ClockClock24View: ScreenSaverView {

    // Layout: 4 digits × 2 cols × 3 rows = 24 clocks
    private static let cols   = 8
    private static let rows   = 3
    private static let digits = 4

    // Drawing constants (allocated once, reused every frame)
    private static let wallGradient = NSGradient(
        starting: NSColor(white: 0.92, alpha: 1),
        ending:   NSColor(white: 0.72, alpha: 1)
    )
    private static let panelColor  = NSColor(white: 0.06, alpha: 1)
    private static let shadowColor = NSColor(white: 0, alpha: 0.5).cgColor

    private var grid: [[ClockView]] = []
    private var currentTimer: ClockTimer = currentTimeDigits()
    private var minuteTimer: Foundation.Timer?

    // MARK: Initialization

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 60.0
        setupGrid()
        applyTimer(currentTimer, animated: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Grid Setup

    private func setupGrid() {
        let padding: CGFloat = isPreview ? 1 : 3
        let hInset  = max(bounds.width  * 0.18, 40)
        let vInset  = max(bounds.height * 0.22, 40)
        let ncols   = CGFloat(Self.cols)
        let nrows   = CGFloat(Self.rows)

        let availW = bounds.width  - 2 * hInset - (ncols - 1) * padding
        let availH = bounds.height - 2 * vInset - (nrows - 1) * padding
        let size   = min(availW / ncols, availH / nrows)

        let totalW = size * ncols + (ncols - 1) * padding
        let totalH = size * nrows + (nrows - 1) * padding
        let x0     = (bounds.width  - totalW) / 2
        let y0     = (bounds.height - totalH) / 2

        for row in 0..<Self.rows {
            var rowViews: [ClockView] = []
            for col in 0..<Self.cols {
                let x = x0 + CGFloat(col) * (size + padding)
                // NSView origin is bottom-left; row 0 is visually top, so flip Y
                let y = y0 + CGFloat(Self.rows - 1 - row) * (size + padding)
                let clock = ClockView(frame: NSRect(x: x, y: y, width: size, height: size))
                rowViews.append(clock)
                addSubview(clock)
            }
            grid.append(rowViews)
        }
    }

    // MARK: Timer → Grid

    /// Maps digit shapes onto the clock grid.
    /// Layout: digit[d] / row[r] / col[c] → grid[r][d * 2 + c]
    private func applyTimer(_ timer: ClockTimer, animated: Bool) {
        let duration: TimeInterval = animated ? 1.5 : 0
        for d in 0..<Self.digits {
            for r in 0..<Self.rows {
                for c in 0..<2 {
                    grid[r][d * 2 + c].animateTo(timer[d][r][c], duration: duration)
                }
            }
        }
    }

    // MARK: Minute Sync

    /// Schedules a one-shot timer that fires at the next minute boundary.
    private func scheduleMinuteTick() {
        minuteTimer?.invalidate()
        let secs  = Calendar.current.component(.second, from: Date())
        let delay = TimeInterval(max(60 - secs, 1))
        minuteTimer = Foundation.Timer.scheduledTimer(
            withTimeInterval: delay,
            repeats: false
        ) { [weak self] _ in
            self?.onMinuteTick()
        }
    }

    @objc private func onMinuteTick() {
        let next = currentTimeDigits()
        if next != currentTimer {
            applyTimer(next, animated: true)
            currentTimer = next
        }
        scheduleMinuteTick()
    }

    // MARK: ScreenSaverView Overrides

    override func startAnimation() {
        super.startAnimation()
        scheduleMinuteTick()
    }

    override func stopAnimation() {
        super.stopAnimation()
        minuteTimer?.invalidate()
        minuteTimer = nil
    }

    override func animateOneFrame() {
        for row in grid { row.forEach { $0.tick() } }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Gray gradient wall
        Self.wallGradient?.draw(in: bounds, angle: 135)

        // Calculate panel rect from the clock grid bounds
        guard let firstRow = grid.first, let lastRow = grid.last,
              let topLeft = firstRow.first, let topRight = firstRow.last,
              let bottomRight = lastRow.last else { return }

        let panelPad: CGFloat = isPreview ? 8 : 20
        let panelRect = NSRect(
            x: topLeft.frame.minX - panelPad,
            y: bottomRight.frame.minY - panelPad,
            width: topRight.frame.maxX - topLeft.frame.minX + 2 * panelPad,
            height: topLeft.frame.maxY - bottomRight.frame.minY + 2 * panelPad
        )

        // Draw panel with drop shadow
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 5, height: -8), blur: 24, color: Self.shadowColor)
        Self.panelColor.setFill()
        NSBezierPath(roundedRect: panelRect, xRadius: 3, yRadius: 3).fill()
        ctx.restoreGState()

        // Redraw panel surface without shadow
        Self.panelColor.setFill()
        NSBezierPath(roundedRect: panelRect, xRadius: 3, yRadius: 3).fill()
    }
}

// MARK: - Clock Face View

/// A single analog clock with two hands (hour and minute) that animate
/// toward target angles using clockwise-only rotation and ease-in-out timing.
final class ClockView: NSView {

    // Drawing constants
    private static let faceColor = NSColor(white: 0.05, alpha: 1)
    private static let handColor = NSColor(white: 0.92, alpha: 1)

    // Animation state
    private var startH: CGFloat = HandPosition.deactivateBottomLeft.hours
    private var startM: CGFloat = HandPosition.deactivateBottomLeft.minutes
    private var curH:   CGFloat = HandPosition.deactivateBottomLeft.hours
    private var curM:   CGFloat = HandPosition.deactivateBottomLeft.minutes
    private var dstH:   CGFloat = HandPosition.deactivateBottomLeft.hours
    private var dstM:   CGFloat = HandPosition.deactivateBottomLeft.minutes
    private var t0:     TimeInterval = 0
    private var dur:    TimeInterval = 0
    private var animating = false

    override init(frame: NSRect) { super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Animation

    /// Sets a new target configuration and begins animating toward it.
    func animateTo(_ config: ClockConfig, duration: TimeInterval) {
        startH = curH
        startM = curM
        dstH   = clockwiseAngle(from: curH, to: config.hours)
        dstM   = clockwiseAngle(from: curM, to: config.minutes)
        dur    = duration
        t0     = Date.timeIntervalSinceReferenceDate
        if duration == 0 {
            curH = dstH; curM = dstM
            setNeedsDisplay(bounds)
        } else {
            animating = true
        }
    }

    /// Advances the animation by one frame. Called at 60 FPS by the screen saver.
    func tick() {
        guard animating else { return }
        let elapsed = Date.timeIntervalSinceReferenceDate - t0
        if elapsed >= dur {
            curH = dstH; curM = dstM
            animating = false
        } else {
            let e = easeInOut(CGFloat(elapsed / dur))
            curH = startH + (dstH - startH) * e
            curM = startM + (dstM - startM) * e
        }
        setNeedsDisplay(bounds)
    }

    /// Quadratic ease-in-out: accelerates then decelerates.
    private func easeInOut(_ t: CGFloat) -> CGFloat {
        t < 0.5 ? 2 * t * t : 1 - (-2 * t + 2) * (-2 * t + 2) / 2
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let cx = bounds.midX
        let cy = bounds.midY
        let r  = min(bounds.width, bounds.height) / 2 - 1.0

        // Recessed clock face
        let face = NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
        Self.faceColor.setFill()
        face.fill()

        // Clock hands
        let handW = max(r * 0.22, 2.0)
        drawHand(cx: cx, cy: cy, degrees: curH, length: r * 0.88, width: handW)
        drawHand(cx: cx, cy: cy, degrees: curM, length: r * 0.88, width: handW)
    }

    /// Draws a single clock hand from the center outward.
    ///
    /// - Parameters:
    ///   - cx: Center X of the clock face.
    ///   - cy: Center Y of the clock face.
    ///   - degrees: Hand angle (0 = 12 o'clock, clockwise).
    ///   - length: Distance from center to hand tip.
    ///   - width: Stroke width of the hand.
    private func drawHand(cx: CGFloat, cy: CGFloat, degrees: CGFloat,
                          length: CGFloat, width: CGFloat) {
        let rad = degrees * .pi / 180
        let ex  = cx + length * sin(rad)
        let ey  = cy + length * cos(rad)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: cx, y: cy))
        path.line(to: NSPoint(x: ex, y: ey))
        path.lineWidth    = width
        path.lineCapStyle = .round
        Self.handColor.setStroke()
        path.stroke()
    }
}

// MARK: - Preview

@available(macOS 14.0, *)
#Preview {
    ClockClock24View(frame: NSRect(x: 0, y: 0, width: 700, height: 400), isPreview: true)!
}
