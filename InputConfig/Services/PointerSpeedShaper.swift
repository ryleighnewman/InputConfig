import Foundation
import CoreGraphics

/// Pointer speed on the Mac's own mouse and trackpad, when a preset asks for
/// it (Apply to my mouse and trackpad, under Pointer speed).
///
/// Measured on a Magic Trackpad, Nov 7 2026 (pointerprobe, twice): a real
/// move comes from process 0 and its deltas always flow. Its location is not
/// to be trusted: with nothing shaping it is where the move ends, but while
/// this shaper warps the pointer macOS keeps reporting the last warp point
/// and the cursor stays there until moved. So the shaper keeps the pointer's
/// place itself and never reads the location: each move's delta is scaled,
/// reversed or steadied and added to that place, the cursor is warped there
/// and the event carries it with its delta to match. After a pause, or when
/// this app put the pointer somewhere since (a stick row, a confine), the
/// place starts from where the cursor is. Moves another app posts (Screen
/// Sharing, an accessibility pointer) pass untouched. Moves InputConfig
/// posts itself pass untouched, and so does everything while InputConfig is
/// in front, so the slider that set the speed is reached at the normal one.
/// Built like MouseWheelShaper: a tap on its own thread, kept while the
/// preset is held back (`passing`) and turned off while it would only pass.
final class PointerSpeedShaper: @unchecked Sendable {
    static let shared = PointerSpeedShaper()
    private let lock = NSLock()
    private var speed = 1.0
    private var reverseX = false
    private var reverseY = false
    /// 0 off, up to 1: the share of the last smoothed move each new move
    /// keeps (see `steadied`).
    private var steadying = 0.0
    /// The smoothed move so far; tap thread only.
    private var smoothed = CGVector(dx: 0, dy: 0)
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var active = false
    private var selfInFront = false
    private var passing = false
    private var failureLogged = false
    private var disabledOnPurpose = false
    private let enableLock = NSLock()
    /// The pointer's place as this shaper put it, and when; tap thread only.
    private var placed: CGPoint?
    private var placedAt: TimeInterval = 0
    /// A pause this long starts the smoothing and the delta fractions over.
    /// A point this app placed longer ago than that is started from only
    /// while the cursor is still within `resyncDistance` of it (and the move).
    static let resyncAfter: TimeInterval = 0.25
    static let resyncDistance: CGFloat = 64
    /// The fraction of each axis' scaled delta not yet written to the
    /// event's whole-number delta fields; tap thread only.
    private var carryX = 0.0
    private var carryY = 0.0

    /// The move events the tap reads: the plain move and the three drags.
    static let eventMask: CGEventMask =
        (1 << CGEventType.mouseMoved.rawValue) |
        (1 << CGEventType.leftMouseDragged.rawValue) |
        (1 << CGEventType.rightMouseDragged.rawValue) |
        (1 << CGEventType.otherMouseDragged.rawValue)

    private init() {}

    /// Where a move lands at `speed`: from `start`, `delta` times the speed.
    /// Kept on the screen it ends on.
    static func scaledLocation(from start: CGPoint, delta: CGVector, speed: Double, within bounds: CGRect?) -> CGPoint {
        var p = CGPoint(x: start.x + delta.dx * speed, y: start.y + delta.dy * speed)
        if let b = bounds, !b.isNull, !b.isEmpty {
            p.x = min(max(p.x, b.minX), b.maxX - 1)
            p.y = min(max(p.y, b.minY), b.maxY - 1)
        }
        return p
    }

    /// Where a move ends, given whether the scaled point lies on a display.
    /// On one it is kept as it is, fractions and all: pulling it back to the
    /// last whole point of the screen would hold a slow move at the seam to
    /// the next display, a fraction short of it on every event. Off every
    /// display it is kept on the screen the move started on.
    static func landing(from start: CGPoint, delta: CGVector, speed: Double, onDisplay: Bool, startBounds: CGRect?) -> CGPoint {
        guard !onDisplay else { return scaledLocation(from: start, delta: delta, speed: speed, within: nil) }
        var p = scaledLocation(from: start, delta: delta, speed: speed, within: startBounds)
        // That clamp ends one whole point inside the far edge. A start
        // already within the last point is not pulled back by it, or
        // pushing on against the edge of the desktop would tremble by the
        // fraction.
        if delta.dx * speed > 0 { p.x = max(p.x, start.x) }
        if delta.dy * speed > 0 { p.y = max(p.y, start.y) }
        return p
    }

    /// Where a real move starts: where this app last put the pointer, if it
    /// did since this shaper's own place was stamped; else that place while
    /// the cursor is on it; else the cursor. The app's point counts only
    /// while fresh or with the cursor still about there: an old one, with
    /// the pointer moved since by something this shaper never saw, pulled
    /// the first move back to it (moveMouse guards its tracked point alike).
    static func start(appPoint: CGPoint?, appAt: TimeInterval, placed: CGPoint?, placedAt: TimeInterval,
                      cursor: CGPoint, raw: CGVector, now: TimeInterval) -> CGPoint {
        let reach = hypot(raw.dx, raw.dy)
        if let p = appPoint, appAt > placedAt + 0.0005,
           now - appAt <= resyncAfter || hypot(cursor.x - p.x, cursor.y - p.y) <= reach + resyncDistance {
            return p
        }
        // The cursor is where this shaper put it, or that plus this very
        // move (macOS reports either): carry on from the kept place.
        if let p = placed, hypot(cursor.x - p.x, cursor.y - p.y) <= reach + 2 { return p }
        // Something else moved the pointer (another device while this was
        // idle, an app): start from where it is.
        return cursor
    }

    /// The whole part of a scaled delta, for the event's delta fields, which
    /// hold whole numbers: a fraction written to them was cut off, so at
    /// half speed a one pixel move read as no move at all. The cut part
    /// waits in `carry` for the next move.
    static func deltaCarry(_ d: Double, carry: inout Double) -> Int64 {
        let total = carry + d
        guard total.isFinite, abs(total) < 1_000_000 else { carry = 0; return 0 }
        let whole = total.rounded(.towardZero)
        carry = total - whole
        return Int64(whole)
    }

    func setSelfInFront(_ front: Bool) {
        lock.lock(); selfInFront = front; lock.unlock()
        applyTapEnabled()
    }

    private func applyTapEnabled() {
        enableLock.lock(); defer { enableLock.unlock() }
        lock.lock()
        guard let tap else { lock.unlock(); return }
        let off = passing
        let change = off != disabledOnPurpose
        disabledOnPurpose = off
        lock.unlock()
        if change { CGEvent.tapEnable(tap: tap, enable: !off) }
    }

    /// The highest steadying keeps this share of the last move, so even the
    /// strongest setting still follows the hand.
    static let maxCarry = 0.85

    /// A move smoothed into the ones before it: the new delta blended with
    /// the last smoothed one by `steadying`, which steadies a shaking hand
    /// at the cost of a short lag. 0 passes the move as it came.
    static func steadied(_ d: CGVector, previous: CGVector, steadying: Double) -> CGVector {
        let k = max(0, min(1, steadying)) * maxCarry
        return CGVector(dx: previous.dx * k + d.dx * (1 - k), dy: previous.dy * k + d.dy * (1 - k))
    }

    /// Nothing asked of it removes the tap. `passing` keeps it but lets
    /// every move by.
    func configure(speed: Double, reverseX: Bool = false, reverseY: Bool = false, steadying: Double = 0,
                   passing: Bool = false) {
        lock.lock()
        self.passing = passing
        self.speed = speed
        self.reverseX = reverseX
        self.reverseY = reverseY
        self.steadying = steadying
        let wanted = speed != 1 || reverseX || reverseY || steadying > 0
        let was = active
        active = wanted
        lock.unlock()
        if wanted && !was { remove(); install(); return }
        if !wanted { if was { remove() }; return }
        applyTapEnabled()
        lock.lock()
        let tap = self.tap, offOnPurpose = disabledOnPurpose
        lock.unlock()
        if let tap, !offOnPurpose, !CGEvent.tapIsEnabled(tap: tap) { remove(); install() }
    }

    private func install() {
        let thread = Thread { [weak self] in
            guard let self else { return }
            let callback: CGEventTapCallBack = { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                return Unmanaged<PointerSpeedShaper>.fromOpaque(info).takeUnretainedValue().handle(type, event)
            }
            guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                              options: .defaultTap, eventsOfInterest: Self.eventMask,
                                              callback: callback,
                                              userInfo: Unmanaged.passUnretained(self).toOpaque())
            else {
                self.lock.lock()
                if self.tap == nil { self.active = false }
                let firstFailure = !self.failureLogged
                self.failureLogged = true
                self.lock.unlock()
                if firstFailure {
                    ActivityLog.shared.warning("Pointer", "Pointer speed cannot reach the mouse and trackpad: the event tap could not be created; check Accessibility in System Settings")
                }
                return
            }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            let loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            self.lock.lock()
            guard self.active, self.tap == nil else {
                self.lock.unlock()
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
                return
            }
            self.tap = tap
            self.runLoop = loop
            self.failureLogged = false
            self.disabledOnPurpose = false
            self.lock.unlock()
            self.applyTapEnabled()
            CFRunLoopRun()
        }
        thread.name = "InputConfig.PointerSpeed"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func remove() {
        lock.lock()
        let tap = self.tap, loop = runLoop
        self.tap = nil
        runLoop = nil
        disabledOnPurpose = false
        lock.unlock()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let loop { CFRunLoopStop(loop) }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock(); let tap = self.tap, offOnPurpose = disabledOnPurpose; lock.unlock()
            if let tap, !offOnPurpose { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.eventSourceUserData) != InputSimulator.ownEventMarker else {
            return Unmanaged.passUnretained(event)
        }
        // Only the Mac's own mouse and trackpad (process 0); the DEBUG live
        // test marks its posted moves to stand in for them.
        #if DEBUG
        let standIn = event.getIntegerValueField(.eventSourceUserData) == Self.liveTestMarker
        #else
        let standIn = false
        #endif
        guard standIn || event.getIntegerValueField(.eventSourceUnixProcessID) == 0 else {
            return Unmanaged.passUnretained(event)
        }
        lock.lock()
        let speed = self.speed, skip = passing
        let flipX = reverseX, flipY = reverseY, steady = steadying
        lock.unlock()
        guard !skip, speed != 1 || flipX || flipY || steady > 0 else { return Unmanaged.passUnretained(event) }
        // A pen tablet or an absolute pointer reports where it is, not a
        // move: shaping it would fight the pen.
        let subtype = event.getIntegerValueField(.mouseEventSubtype)
        if subtype == Int64(CGEventMouseSubtype.tabletPoint.rawValue) || subtype == Int64(CGEventMouseSubtype.tabletProximity.rawValue) {
            return Unmanaged.passUnretained(event)
        }
        let rawX = event.getDoubleValueField(.mouseEventDeltaX)
        let rawY = event.getDoubleValueField(.mouseEventDeltaY)
        guard rawX != 0 || rawY != 0 else { return Unmanaged.passUnretained(event) }
        let now = ProcessInfo.processInfo.systemUptime
        let raw = CGVector(dx: rawX, dy: rawY)
        // Where the move starts: where this app last put the pointer, if it
        // did since; else this shaper's own place while moves keep coming;
        // else the cursor where it is (after a pause, or the first move).
        let app = InputSimulator.shared.lastPlacedPointer()
        let cursorNow = CGEvent(source: nil)?.location ?? event.location
        let start = Self.start(appPoint: app.point, appAt: app.at, placed: placed, placedAt: placedAt,
                               cursor: cursorNow, raw: raw, now: now)
        // A pause starts the smoothing over, so a new move is not pulled
        // toward the last one, and drops the delta fractions kept so far.
        if now - placedAt >= Self.resyncAfter {
            smoothed = CGVector(dx: 0, dy: 0)
            carryX = 0; carryY = 0
        }
        let move = steady > 0 ? Self.steadied(raw, previous: smoothed, steadying: steady) : raw
        smoothed = move
        let dx = flipX ? -move.dx : move.dx
        let dy = flipY ? -move.dy : move.dy
        // The screen the move ends on keeps the pointer.
        let rough = CGPoint(x: start.x + dx * speed, y: start.y + dy * speed)
        var displayID: CGDirectDisplayID = 0
        var count: UInt32 = 0
        let onDisplay = CGGetDisplaysWithPoint(rough, 1, &displayID, &count) == .success && count > 0
        // Off every screen: kept on the one the move started on.
        let startBounds: CGRect? = !onDisplay && CGGetDisplaysWithPoint(start, 1, &displayID, &count) == .success && count > 0
            ? CGDisplayBounds(displayID) : nil
        let target = Self.landing(from: start, delta: CGVector(dx: dx, dy: dy), speed: speed,
                                  onDisplay: onDisplay, startBounds: startBounds)
        placed = target
        placedAt = now
        event.location = target
        event.setIntegerValueField(.mouseEventDeltaX, value: Self.deltaCarry(dx * speed, carry: &carryX))
        event.setIntegerValueField(.mouseEventDeltaY, value: Self.deltaCarry(dy * speed, carry: &carryY))
        InputSimulator.shared.warpPointer(to: target)
        // Stamped after the warp, which stamps the app's own record: only a
        // later placement by someone else counts as moved elsewhere.
        placedAt = ProcessInfo.processInfo.systemUptime
        return Unmanaged.passUnretained(event)
    }

    #if DEBUG
    /// Marks the live test's posted moves as stand-ins for the hardware.
    static let liveTestMarker: Int64 = 0x50_54_45_53_54
    /// The live check: real move events posted into the system from outside
    /// InputConfig's own marker, through the real tap and warp, and the
    /// cursor read back. `post inputconfig.debug.pointertest`; writes
    /// pointertest.txt in the app's tmp folder. Moves the pointer for about
    /// two seconds and puts it back.
    @MainActor static func runLiveTest() async -> String {
        let source = CGEventSource(stateID: .hidSystemState)
        func cursor() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }
        let home = cursor()
        let main = CGDisplayBounds(CGMainDisplayID())
        let start = CGPoint(x: main.midX, y: main.midY)
        var lines: [String] = []
        var allPass = true
        let cases: [(name: String, speed: Double, rx: Bool, ry: Bool)] = [
            ("half speed", 0.5, false, false), ("double speed", 2, false, false),
            ("reversed both ways", 1, true, true), ("half speed, left and right reversed", 0.5, true, false),
        ]
        for c in cases {
            shared.configure(speed: c.speed, reverseX: c.rx, reverseY: c.ry, passing: false)
            try? await Task.sleep(nanoseconds: 400_000_000)
            InputSimulator.shared.warpPointer(to: start)
            try? await Task.sleep(nanoseconds: 350_000_000)
            for _ in 0..<5 {
                // As the hardware reports a move (pointerprobe): the location
                // is where the move ends, from the pointer's place now.
                let now = cursor()
                let at = CGPoint(x: now.x + 10, y: now.y + 6)
                if let e = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: at, mouseButton: .left) {
                    e.setIntegerValueField(.mouseEventDeltaX, value: 10)
                    e.setIntegerValueField(.mouseEventDeltaY, value: 6)
                    e.setIntegerValueField(.eventSourceUserData, value: liveTestMarker)
                    e.post(tap: .cghidEventTap)
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            let got = cursor()
            let want = CGPoint(x: start.x + 50 * c.speed * (c.rx ? -1 : 1), y: start.y + 30 * c.speed * (c.ry ? -1 : 1))
            let ok = abs(got.x - want.x) <= 1.5 && abs(got.y - want.y) <= 1.5
            allPass = allPass && ok
            lines.append("\(ok ? "PASS" : "FAIL") \(c.name): moved \(Int(got.x - start.x)),\(Int(got.y - start.y)) want \(Int(want.x - start.x)),\(Int(want.y - start.y))")
        }
        shared.configure(speed: 1)
        MappingEngine.current?.applyScrollStyle()
        CGWarpMouseCursorPosition(home); CGAssociateMouseAndMouseCursorPosition(1)
        return (allPass ? "ALL PASS\n" : "FAILED\n") + lines.joined(separator: "\n") + "\n"
    }
    #endif

    #if DEBUG
    /// Records what the Mac's own mouse or trackpad move events carry, for
    /// four seconds: the event's location, its delta, the process that sent
    /// it, and where the cursor is at that moment. `post
    /// inputconfig.debug.pointerprobe`; writes pointerprobe.txt.
    nonisolated(unsafe) static var probeLines: [String] = []
    @MainActor static func runProbe(shapingAt speed: Double = 1) async -> String {
        probeLines = []
        // The raw events (the shaper aside), or with the shaper at `speed`
        // to see real moves continue from where it puts the pointer.
        shared.configure(speed: speed)
        defer { MappingEngine.current?.applyScrollStyle() }
        let callback: CGEventTapCallBack = { _, _, event, _ in
            if PointerSpeedShaper.probeLines.count < 60 {
                let l = event.location
                let now = CGEvent(source: nil)?.location ?? .zero
                PointerSpeedShaper.probeLines.append(String(format: "loc %.1f,%.1f  delta %.1f,%.1f  pid %lld  cursor %.1f,%.1f  mine %lld",
                    l.x, l.y, event.getDoubleValueField(.mouseEventDeltaX), event.getDoubleValueField(.mouseEventDeltaY),
                    event.getIntegerValueField(.eventSourceUnixProcessID), now.x, now.y,
                    event.getIntegerValueField(.eventSourceUserData) == InputSimulator.ownEventMarker ? 1 : 0))
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: eventMask, callback: callback, userInfo: nil) else { return "no tap" }
        // Ahead of the shaper's own tap when shaping, so the line shows the
        // move as the hardware sent it; the cursor column is where the
        // previous move was put.
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        // Up to a minute, until 40 moves are in.
        for _ in 0..<600 where probeLines.count < 40 { try? await Task.sleep(nanoseconds: 100_000_000) }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        CFMachPortInvalidate(tap)
        return probeLines.joined(separator: "\n") + "\n"
    }
    #endif
}
