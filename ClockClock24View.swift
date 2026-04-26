// ClockClock24View.swift
// ClockClock24
//
// A macOS screen saver inspired by Humans Since 1982's ClockClock 24 sculpture.
// Twenty-four analog clocks are arranged in a 3-row × 8-column grid (four digits,
// each 3 rows × 2 columns). The screensaver runs on a continuous 60-second cycle:
//   • Time Display (0–20 s): transitions to the current time then holds for legibility.
//   • Choreography (20–60 s): four randomised kinetic patterns, 10 s each.
//
// Architecture:
//   ClockClock24View (ScreenSaverView) — owns the 3×8 grid of ClockView subviews,
//       manages the 60-second cycle, and dispatches choreography patterns.
//   ClockView (NSView) — a single analog clock face supporting timed animations
//       (animateTo/tick) and direct-drive (drive) for choreography.
//   HandPosition — caseless enum namespace holding canonical hand positions and
//       digit shapes for HH:MM display.
//
// Reference: github.com/ArnaudSpanneut/ClockClock24

import ScreenSaver
import Cocoa

// MARK: - Types

struct ClockConfig: Equatable, Sendable {
    let hours: CGFloat
    let minutes: CGFloat
}

typealias DigitLine  = [ClockConfig]
typealias DigitShape = [DigitLine]
typealias ClockTimer = [DigitShape]

// MARK: - Hand Positions & Digit Shapes

/// Degrees follow clock convention: 0/360 = 12 o'clock, increasing clockwise.
/// Each digit is encoded as 3 rows × 2 clocks matching the reference implementation.
private enum HandPosition {

    static let deactivateTopRight    = ClockConfig(hours: 45,  minutes: 45)
    static let deactivateBottomRight = ClockConfig(hours: 135, minutes: 135)
    static let deactivateBottomLeft  = ClockConfig(hours: 225, minutes: 225)
    static let deactivateTopLeft     = ClockConfig(hours: 315, minutes: 315)

    static let verticalLine = ClockConfig(hours: 360, minutes: 180)

    static let top    = ClockConfig(hours: 360, minutes: 360)
    static let right  = ClockConfig(hours: 90,  minutes: 90)
    static let bottom = ClockConfig(hours: 180, minutes: 180)
    static let left   = ClockConfig(hours: 270, minutes: 270)

    static let angleTopLeft     = ClockConfig(hours: 360, minutes: 270)
    static let angleTopRight    = ClockConfig(hours: 90,  minutes: 360)
    static let angleBottomLeft  = ClockConfig(hours: 270, minutes: 180)
    static let angleBottomRight = ClockConfig(hours: 180, minutes: 90)

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

// MARK: - Choreography Patterns
//
// Each pattern is a pure function: (elapsed seconds since launch, row, col) → ClockConfig.
// Angles are raw accumulated values (not clamped to 0–360); sin/cos in drawHand handles
// periodicity correctly. Using launch-relative time keeps the floats small.

private typealias ChoreographyPattern = (_ t: TimeInterval, _ row: Int, _ col: Int) -> ClockConfig

// Target rotation speed: 22–36 °/s (one full revolution every 10–16 s).
// Research on smooth-pursuit eye tracking and kinetic-art perception places
// the "satisfying" sweet spot here — slow enough to follow, fast enough to
// feel alive. Above ~40 °/s the eye switches to saccades and the motion
// starts to feel hectic rather than meditative.

/// Hour sweeps left → right; minute sweeps right → left.
/// Opposite directions, different speeds, independent sine modulation.
private func patternSweepWave(_ t: TimeInterval, _ row: Int, _ col: Int) -> ClockConfig {
    let h = CGFloat(t *  36 + Double(col) *  20 + sin(t * 0.5 + Double(col) * 0.8) * 18
                   + Double(row) *  8)
    let m = CGFloat(t * -22 + Double(col) * -15 + sin(t * 0.4 + Double(row) * 1.0) * 14
                   + Double(row) * -10)
    return ClockConfig(hours: h, minutes: m)
}

/// Hour rotates clockwise from polar angle; minute counter-clockwise from the
/// inverted polar angle — hands open and close like slow scissors.
private func patternPinwheel(_ t: TimeInterval, _ row: Int, _ col: Int) -> ClockConfig {
    let base = atan2(Double(col) - 3.5, Double(row) - 1.0) * (180.0 / .pi)
    let h = CGFloat( base + t *  30)
    let m = CGFloat(-base + t * -20)
    return ClockConfig(hours: h, minutes: m)
}

/// Hour ripples outward from centre; minute ripples inward.
/// The two pulses move through each other in opposite radial directions.
private func patternRadialPulse(_ t: TimeInterval, _ row: Int, _ col: Int) -> ClockConfig {
    let dist = sqrt(pow(Double(col) - 3.5, 2) + pow(Double(row) - 1.0, 2))
    let h = CGFloat(t *  32 - dist * 18)
    let m = CGFloat(t * -22 + dist * 24)
    return ClockConfig(hours: h, minutes: m)
}

/// Hour cascades along the main diagonal; minute along the anti-diagonal.
/// Crossing wavefronts give each clock a continuously changing opening angle.
private func patternCascade(_ t: TimeInterval, _ row: Int, _ col: Int) -> ClockConfig {
    let h = CGFloat(t *  28 + Double( col + row * 2) * 10)
    let m = CGFloat(t * -18 + Double(col * 2 - row)  * 12)
    return ClockConfig(hours: h, minutes: m)
}

private let kChoreographyPatterns: [ChoreographyPattern] = [
    patternSweepWave,
    patternPinwheel,
    patternRadialPulse,
    patternCascade,
]

// MARK: - ScreenSaver View

@objc(ClockClock24View)
final class ClockClock24View: ScreenSaverView {

    private static let cols   = 8
    private static let rows   = 3
    private static let digits = 4

    // 60-second cycle timings
    private static let cycleDuration:     TimeInterval = 60
    private static let timeDisplayWindow: TimeInterval = 20  // 0–20 s: show time
    private static let timeAnimDuration:  TimeInterval = 1.5

    private static let wallGradient = NSGradient(
        starting: NSColor(white: 0.92, alpha: 1),
        ending:   NSColor(white: 0.72, alpha: 1)
    )
    private static let panelColor  = NSColor(white: 0.06, alpha: 1)
    private static let shadowColor = NSColor(white: 0, alpha: 0.5).cgColor

    private var grid: [[ClockView]] = []
    private var currentTimer: ClockTimer = currentTimeDigits()

    // Cycle state
    private var timeOrigin:           TimeInterval = 0     // launch epoch for pattern functions
    private var cycleStart:           TimeInterval = 0     // start of current 60 s cycle (relative)
    private var timeDisplayApplied:   Bool         = false
    private var choreoPatternIndex:   Int          = 0     // one pattern for the full 40 s
    // Per-clock angle offsets computed at the choreography entry point so hands
    // begin exactly where the time-display animation left them — no jump.
    private var choreoOffsetH: [[CGFloat]] = []
    private var choreoOffsetM: [[CGFloat]] = []
    private var choreoOffsetsReady:   Bool         = false

    // MARK: Initialization

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 60.0
        setupGrid()
        timeOrigin = Date.timeIntervalSinceReferenceDate
        cycleStart = 0
        currentTimer = currentTimeDigits()
        applyTimer(currentTimer, animated: false)
        timeDisplayApplied = true
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

    /// Layout: digit[d] / row[r] / col[c] → grid[r][d * 2 + c]
    private func applyTimer(_ timer: ClockTimer, animated: Bool) {
        let duration: TimeInterval = animated ? Self.timeAnimDuration : 0
        for d in 0..<Self.digits {
            for r in 0..<Self.rows {
                for c in 0..<2 {
                    grid[r][d * 2 + c].animateTo(timer[d][r][c], duration: duration)
                }
            }
        }
    }

    // MARK: ScreenSaverView Overrides

    override func startAnimation() { super.startAnimation() }
    override func stopAnimation()  { super.stopAnimation() }

    override func animateOneFrame() {
        let now    = Date.timeIntervalSinceReferenceDate - timeOrigin
        var cycleT = now - cycleStart

        // Cycle boundary: pick a new random pattern and clear the offset cache
        if cycleT >= Self.cycleDuration {
            cycleStart           = now
            cycleT               = 0
            timeDisplayApplied   = false
            choreoOffsetsReady   = false
            currentTimer         = currentTimeDigits()
            choreoPatternIndex   = Int.random(in: 0..<kChoreographyPatterns.count)
        }

        if cycleT < Self.timeDisplayWindow {
            // ── Time display phase (0–20 s) ─────────────────────────────
            if !timeDisplayApplied {
                applyTimer(currentTimer, animated: true)
                timeDisplayApplied = true
            }
            for row in grid { row.forEach { $0.tick() } }
        } else {
            // ── Choreography phase (20–60 s) ────────────────────────────
            // On the very first choreography frame, snapshot the current hand
            // angles and compute per-clock offsets so the pattern starts
            // exactly where the time-display animation left off — no jump.
            if !choreoOffsetsReady {
                let fn = kChoreographyPatterns[choreoPatternIndex]
                choreoOffsetH = (0..<Self.rows).map { r in
                    (0..<Self.cols).map { c in
                        grid[r][c].curH - fn(now, r, c).hours
                    }
                }
                choreoOffsetM = (0..<Self.rows).map { r in
                    (0..<Self.cols).map { c in
                        grid[r][c].curM - fn(now, r, c).minutes
                    }
                }
                choreoOffsetsReady = true
            }
            driveChoreography(elapsed: now)
        }
    }

    /// Drives all 24 clocks with the single active pattern, shifted by the
    /// per-clock entry offsets so motion is continuous from the time display.
    private func driveChoreography(elapsed: TimeInterval) {
        let fn = kChoreographyPatterns[choreoPatternIndex]
        for r in 0..<Self.rows {
            for c in 0..<Self.cols {
                let raw = fn(elapsed, r, c)
                grid[r][c].drive(ClockConfig(
                    hours:   raw.hours   + choreoOffsetH[r][c],
                    minutes: raw.minutes + choreoOffsetM[r][c]
                ))
            }
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        Self.wallGradient?.draw(in: bounds, angle: 135)

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

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 5, height: -8), blur: 24, color: Self.shadowColor)
        Self.panelColor.setFill()
        NSBezierPath(roundedRect: panelRect, xRadius: 3, yRadius: 3).fill()
        ctx.restoreGState()

        Self.panelColor.setFill()
        NSBezierPath(roundedRect: panelRect, xRadius: 3, yRadius: 3).fill()

    }
}

// MARK: - Clock Face View

final class ClockView: NSView {

    // Centered soft radial gradient: lighter core fading to near-black edge; no ring
    private static let faceGradient = NSGradient(starting: NSColor(white: 0.10, alpha: 1),
                                                 ending:   NSColor(white: 0.02, alpha: 1))
    // Matte light gray — reads as material rather than pure emission
    private static let handColor    = NSColor(white: 0.88, alpha: 1)

    private var startH: CGFloat = HandPosition.deactivateBottomLeft.hours
    private var startM: CGFloat = HandPosition.deactivateBottomLeft.minutes
    fileprivate var curH: CGFloat = HandPosition.deactivateBottomLeft.hours
    fileprivate var curM: CGFloat = HandPosition.deactivateBottomLeft.minutes
    private var dstH:   CGFloat = HandPosition.deactivateBottomLeft.hours
    private var dstM:   CGFloat = HandPosition.deactivateBottomLeft.minutes
    private var t0:     TimeInterval = 0
    private var dur:    TimeInterval = 0
    private var animating = false

    override init(frame: NSRect) { super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Timed animation (time display phase)

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

    private func easeInOut(_ t: CGFloat) -> CGFloat {
        t < 0.5 ? 2 * t * t : 1 - (-2 * t + 2) * (-2 * t + 2) / 2
    }

    // MARK: Direct drive (choreography phase)

    /// Sets hand angles immediately, bypassing the animation system.
    /// Clears animating flag so a subsequent tick() call is a no-op.
    func drive(_ config: ClockConfig) {
        curH      = config.hours
        curM      = config.minutes
        animating = false
        setNeedsDisplay(bounds)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let cx = bounds.midX
        let cy = bounds.midY
        let r  = min(bounds.width, bounds.height) / 2 - 1.0

        // ── Face: centered radial gradient, no border or ring ──────────
        Self.faceGradient?.draw(
            in: NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: 2*r, height: 2*r)),
            relativeCenterPosition: NSPoint(x: 0, y: 0))

        // ── Hands: single continuous L-shape ────────────────────────────
        // Round cap → pill ends. Round join → smooth filleted inner corner.
        // No pivot dot, no junction disc, no shadow — flat and clean.
        let handW = max(r * 0.26, 2.5)
        Self.handColor.setStroke()
        drawHandsUnified(cx: cx, cy: cy,
                         degreesH: curH, degreesM: curM,
                         length: r * 0.78, width: handW)
    }

    /// Draws both hands as one continuous polyline: tipH → pivot → tipM.
    /// .butt cap   → flat perpendicular cut at each outer tip.
    /// .round join → smooth filleted corner at the pivot — no visible joint.
    /// setStroke() must be called by the caller before invoking this.
    private func drawHandsUnified(cx: CGFloat, cy: CGFloat,
                                  degreesH: CGFloat, degreesM: CGFloat,
                                  length: CGFloat, width: CGFloat) {
        let radH = degreesH * .pi / 180
        let radM = degreesM * .pi / 180
        let path = NSBezierPath()
        path.move(to: NSPoint(x: cx + length * sin(radH), y: cy + length * cos(radH)))
        path.line(to: NSPoint(x: cx, y: cy))
        path.line(to: NSPoint(x: cx + length * sin(radM), y: cy + length * cos(radM)))
        path.lineWidth     = width
        path.lineCapStyle  = .butt
        path.lineJoinStyle = .round
        path.stroke()
    }
}

// MARK: - Preview

@available(macOS 14.0, *)
#Preview {
    ClockClock24View(frame: NSRect(x: 0, y: 0, width: 700, height: 400), isPreview: true)!
}
