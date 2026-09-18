import Foundation
import QuartzCore

/// Moves the pointer for stick-driven mouse motion on a thread of its own.
///
/// The mapping engine polls on the main thread, and the main thread is also
/// where SwiftUI lays the window out. When the window is busy (the Live
/// Visualizer redrawing, a long list reflowing) the poll timer fires late,
/// and pointer motion posted from those polls arrives in bursts: a stutter,
/// felt most in exactly the situation the app is for, steering another app
/// from a controller.
///
/// So the engine no longer posts stick motion itself. Each poll it hands
/// this pump a velocity, in pixels per second, and the pump integrates it on
/// a 120 Hz timer of its own, on a queue the window cannot block. A late
/// poll then only delays a change of speed; the pointer keeps gliding at the
/// last speed in between. Gyro aim and stick or dial scrolling are rates too
/// and take the same path; touchpad and drive-mode deltas are per-frame
/// displacements and still go straight to the simulator.
final class MouseMotionPump: @unchecked Sendable {
    static let shared = MouseMotionPump()

    private let queue = DispatchQueue(label: "com.inputconfig.mousepump", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var velocityX: Float = 0     // px/s
    private var velocityY: Float = 0
    private var carryX: Float = 0
    private var carryY: Float = 0
    private var scrollVelocityX: Float = 0   // scroll units/s
    private var scrollVelocityY: Float = 0
    private var scrollCarryX: Float = 0
    private var scrollCarryY: Float = 0
    private var scrolledUnits: Int = 0
    private var lastTick: Double = 0
    private var running = false
    /// Exact displacement still owed to the pointer (gyro path). Every pixel
    /// handed in is eventually posted, spread over the interval between
    /// feeds so it looks like continuous motion at 240 Hz instead of a step
    /// per poll. Nothing is ever dropped, so a movement and its reverse still
    /// sum to zero.
    private var owedX: Float = 0
    private var owedY: Float = 0
    private var lastFeed: Double = 0
    private var feedInterval: Double = 1.0 / 120.0
    /// Pixels moved since the engine last asked; the engine records them
    /// into Statistics on the main thread.
    private var movedPixels: Int = 0

    /// Pixels moved since the previous call.
    func takeMovedPixels() -> Int {
        lock.lock(); defer { lock.unlock() }
        let n = movedPixels
        movedPixels = 0
        return n
    }

    private init() {}

    /// Add an exact pixel displacement to be paid out over the next feed
    /// interval. Used by motion bindings, whose per-poll delta is an angle
    /// the controller actually turned.
    func addDisplacement(x: Float, y: Float) {
        guard x.isFinite, y.isFinite, x != 0 || y != 0 else { return }
        let now = CACurrentMediaTime()
        lock.lock()
        owedX += x; owedY += y
        if lastFeed > 0 {
            // Track the real feed cadence so a late poll pays out over the
            // gap it actually left instead of landing as one jump.
            let gap = min(0.05, max(1.0 / 240.0, now - lastFeed))
            feedInterval = feedInterval * 0.7 + gap * 0.3
        }
        lastFeed = now
        lock.unlock()
    }

    /// Set the current stick velocity. Zero stops the pointer.
    func setVelocity(x: Float, y: Float) {
        lock.lock()
        velocityX = x.isFinite ? x : 0
        velocityY = y.isFinite ? y : 0
        lock.unlock()
    }

    /// Set the current stick or dial scroll velocity. Zero stops it.
    func setScrollVelocity(x: Float, y: Float) {
        lock.lock()
        scrollVelocityX = x.isFinite ? x : 0
        scrollVelocityY = y.isFinite ? y : 0
        lock.unlock()
    }

    /// Scroll units sent since the previous call.
    func takeScrolledUnits() -> Int {
        lock.lock(); defer { lock.unlock() }
        let n = scrolledUnits
        scrolledUnits = 0
        return n
    }

    func start() {
        lock.lock()
        if running { lock.unlock(); return }
        running = true
        carryX = 0; carryY = 0; lastTick = 0
        lock.unlock()
        // Strict: the timer must not be coalesced with others when the app
        // is in the background, which is where this pump matters most.
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .microseconds(250))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        lock.lock()
        running = false
        velocityX = 0; velocityY = 0; carryX = 0; carryY = 0; lastTick = 0
        owedX = 0; owedY = 0; lastFeed = 0
        scrollVelocityX = 0; scrollVelocityY = 0; scrollCarryX = 0; scrollCarryY = 0
        lock.unlock()
    }

    private func tick() {
        let now = CACurrentMediaTime()
        lock.lock()
        let dt: Float
        if lastTick == 0 { dt = 1.0 / 120.0 } else { dt = Float(min(0.05, max(0, now - lastTick))) }
        lastTick = now
        let vx = velocityX, vy = velocityY
        // Pay out the owed displacement in proportion to the time passed,
        // finishing within about one feed interval; the last sliver goes
        // whole so nothing lingers.
        var payX: Float = 0, payY: Float = 0
        if owedX != 0 || owedY != 0 {
            let frac = Float(min(1.0, Double(dt) / feedInterval))
            payX = owedX * frac; payY = owedY * frac
            if abs(owedX - payX) < 0.01 { payX = owedX }
            if abs(owedY - payY) < 0.01 { payY = owedY }
            owedX -= payX; owedY -= payY
        }
        var wholeX = 0, wholeY = 0
        if vx == 0 && vy == 0 && payX == 0 && payY == 0 {
            // Idle: keep the carry so a paused movement resumes exactly, but
            // drop it once the pointer has been still for a while so an old
            // half pixel does not appear out of nowhere.
            if now - lastFeed > 0.5 { carryX = 0; carryY = 0 }
        } else {
            let totalX = carryX + vx * dt + payX
            let totalY = carryY + vy * dt + payY
            wholeX = Int(max(-4096, min(4096, totalX)))
            wholeY = Int(max(-4096, min(4096, totalY)))
            carryX = totalX - Float(wholeX)
            carryY = totalY - Float(wholeY)
            movedPixels += abs(wholeX) + abs(wholeY)
        }
        let sx = scrollVelocityX, sy = scrollVelocityY
        var scrollX: Int32 = 0, scrollY: Int32 = 0
        if sx == 0 && sy == 0 {
            scrollCarryX = 0; scrollCarryY = 0
        } else {
            let totalX = scrollCarryX + sx * dt
            let totalY = scrollCarryY + sy * dt
            scrollX = Int32(max(-4096, min(4096, totalX)))
            scrollY = Int32(max(-4096, min(4096, totalY)))
            scrollCarryX = totalX - Float(scrollX)
            scrollCarryY = totalY - Float(scrollY)
            scrolledUnits += Int(abs(scrollX) + abs(scrollY))
        }
        lock.unlock()
        if wholeX != 0 || wholeY != 0 {
            InputSimulator.shared.moveMouse(deltaX: wholeX, deltaY: wholeY)
        }
        if scrollX != 0 || scrollY != 0 {
            InputSimulator.shared.scrollWheel(deltaX: scrollX, deltaY: scrollY)
        }
    }
}
