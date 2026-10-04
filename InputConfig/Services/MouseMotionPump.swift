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
/// last speed in between, but only for a few missed polls. A speed older
/// than `velocityLease` is braked to a stop, because the poll that would
/// have said "the stick was let go" is exactly the one that is late, and
/// gliding on through a long stall carried the pointer past its target.
/// Gyro aim and stick or dial scrolling are rates too and take the same
/// path; touchpad and drive-mode deltas are per-frame displacements and
/// still go straight to the simulator.
final class MouseMotionPump: @unchecked Sendable {
    static let shared = MouseMotionPump()

    private let queue = DispatchQueue(label: "com.inputconfig.mousepump", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var velocityX: Float = 0     // px/s
    private var velocityY: Float = 0
    /// When the engine last set each speed. Polls come every 8.3 ms; a speed
    /// not refreshed for `velocityLease` starts braking with a time constant
    /// of `brakeTau`, so a stall can add at most a few frames of motion.
    private var velocityAt: Double = 0
    private var scrollVelocityAt: Double = 0
    /// At least 30 ms, and one and a half poll intervals: at a 30 Hz poll a
    /// fixed 30 ms lease braked the pointer at the end of every frame, a
    /// steady stutter. Set from the engine's poll rate (`setPollInterval`).
    private var velocityLease: Double = 0.030
    private let brakeTau: Double = 0.015
    private var carryX: Float = 0
    private var carryY: Float = 0
    private var scrollVelocityX: Float = 0   // scroll units/s
    private var scrollVelocityY: Float = 0
    private var scrollCarryX: Float = 0
    private var scrollCarryY: Float = 0
    private var scrolledUnits: Int = 0
    private var lastTick: Double = 0
    private var running = false
    /// The timer is suspended while nothing moves: a stick at rest, no gyro
    /// motion owed, no scroll. It used to tick 125 times a second for as
    /// long as a pointer preset was on, stick or no stick, which was most of
    /// what the app cost while it sat in the background. Any new speed or
    /// displacement wakes it on the spot.
    private var sleeping = false
    /// When the pump last had anything to do.
    private var lastBusy: Double = 0
    /// How long the pump stays awake with nothing to do before it sleeps.
    private let sleepAfter: Double = 0.25
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

    #if DEBUG
    /// Tests only: whether the timer is suspended for lack of anything to do.
    var debugIsSleeping: Bool {
        lock.lock(); defer { lock.unlock() }
        return sleeping
    }
    #endif

    /// Resume a sleeping timer. Called with the lock held; the next tick
    /// then measures its time step from scratch, so the pointer does not
    /// jump by the whole time it slept.
    private func wakeLocked() {
        guard sleeping, running, let timer else { return }
        sleeping = false
        lastTick = 0
        timer.resume()
    }

    /// Add an exact pixel displacement to be paid out over the next feed
    /// interval. Used by motion bindings, whose per-poll delta is an angle
    /// the controller actually turned.
    func addDisplacement(x: Float, y: Float) {
        guard x.isFinite, y.isFinite, x != 0 || y != 0 else { return }
        let now = CACurrentMediaTime()
        lock.lock()
        owedX += x; owedY += y
        wakeLocked()
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
        let now = CACurrentMediaTime()
        lock.lock()
        velocityX = x.isFinite ? x : 0
        velocityY = y.isFinite ? y : 0
        velocityAt = now
        if velocityX != 0 || velocityY != 0 { wakeLocked() }
        lock.unlock()
    }

    /// Set the current stick or dial scroll velocity. Zero stops it.
    func setScrollVelocity(x: Float, y: Float) {
        let now = CACurrentMediaTime()
        lock.lock()
        scrollVelocityX = x.isFinite ? x : 0
        scrollVelocityY = y.isFinite ? y : 0
        scrollVelocityAt = now
        if scrollVelocityX != 0 || scrollVelocityY != 0 { wakeLocked() }
        lock.unlock()
    }

    /// The engine's poll interval, so the lease covers one whole frame.
    func setPollInterval(_ interval: TimeInterval) {
        lock.lock()
        velocityLease = max(0.030, interval * 1.5)
        lock.unlock()
    }

    /// 1 while a speed is fresh; past the lease, an exponential brake toward 0.
    private func leaseFactor(setAt: Double, now: Double) -> Float {
        guard setAt > 0 else { return 1 }
        let stale = now - setAt - velocityLease
        guard stale > 0 else { return 1 }
        let k = exp(-stale / brakeTau)
        return k < 0.02 ? 0 : Float(k)
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
        sleeping = false
        carryX = 0; carryY = 0; lastTick = 0
        lastBusy = CACurrentMediaTime()
        // Strict: the timer must not be coalesced with others when the app
        // is in the background, which is where this pump matters most.
        // Created and stored under the lock, since tick() and the wake path
        // read it there to suspend and resume it.
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .microseconds(250))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
        lock.unlock()
    }

    func stop() {
        lock.lock()
        running = false
        // A suspended dispatch source must be resumed before it is canceled
        // and released; releasing a suspended one is a crash. With running
        // false no tick can suspend it again after this.
        if sleeping, let timer { timer.resume() }
        sleeping = false
        let t = timer
        timer = nil
        velocityX = 0; velocityY = 0; carryX = 0; carryY = 0; lastTick = 0
        velocityAt = 0; scrollVelocityAt = 0
        owedX = 0; owedY = 0; lastFeed = 0
        scrollVelocityX = 0; scrollVelocityY = 0; scrollCarryX = 0; scrollCarryY = 0
        lock.unlock()
        t?.cancel()
    }

    private func tick() {
        let now = CACurrentMediaTime()
        lock.lock()
        let dt: Float
        if lastTick == 0 { dt = 1.0 / 120.0 } else { dt = Float(min(0.05, max(0, now - lastTick))) }
        lastTick = now
        let brake = leaseFactor(setAt: velocityAt, now: now)
        let vx = velocityX * brake, vy = velocityY * brake
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
        let scrollBrake = leaseFactor(setAt: scrollVelocityAt, now: now)
        let sx = scrollVelocityX * scrollBrake, sy = scrollVelocityY * scrollBrake
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
        let busy = vx != 0 || vy != 0 || owedX != 0 || owedY != 0 || sx != 0 || sy != 0
            || wholeX != 0 || wholeY != 0
        if busy {
            lastBusy = now
        } else if running, now - lastBusy > sleepAfter, !sleeping, let timer {
            sleeping = true
            timer.suspend()
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
