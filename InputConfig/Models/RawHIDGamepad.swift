import Foundation
import IOKit
import IOKit.hid
import QuartzCore

/// A HID gamepad that InputConfig is reading directly via IOKit
/// (i.e. *not* through Apple's GameController framework). The Steam
/// Controller has its own dedicated service; this type covers
/// everything else: 8BitDo in XInput mode, Xbox 360 wired pads,
/// PowerA/Hori/MadCatz Xbox-compatibles, Logitech F310/F710, etc.
///
/// The instance owns the underlying `IOHIDDevice` for the duration of
/// its lifetime. `state` is lock-protected: the input report callback is
/// serviced on the main runloop (where the IOHIDManager is scheduled), the
/// same context the mapping engine reads from, and the lock keeps it safe if
/// the device is ever scheduled on a background queue instead.
final class RawHIDGamepad: Identifiable, @unchecked Sendable {

    /// The device's IORegistry entry ID. In-memory only: it changes on every
    /// reconnect, so nothing persists it (remembered devices use VID:PID plus
    /// serial, presets use `persistentIdentifier`).
    let id: UInt64
    let vendorID: Int32
    let productID: Int32
    let productName: String
    let manufacturer: String?
    let transport: String           // "USB", "Bluetooth", etc.
    let profile: ControllerProfile?

    /// Underlying HID device. Held strongly so it isn't released while
    /// the input report callback is registered.
    let device: IOHIDDevice

    private let lock = NSLock()
    private var _state = ControllerState()

    init(device: IOHIDDevice,
         id: UInt64,
         vendorID: Int32,
         productID: Int32,
         productName: String,
         manufacturer: String?,
         transport: String,
         profile: ControllerProfile?) {
        self.device = device
        self.id = id
        self.vendorID = vendorID
        self.productID = productID
        self.productName = productName
        self.manufacturer = manufacturer
        self.transport = transport
        self.profile = profile
    }

    /// Atomic snapshot of the latest decoded controller state. Safe to
    /// call from any thread.
    var state: ControllerState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    /// Merge a decoded report into the published state. Called from the
    /// HID report callback after `HIDReportDecoder` finishes its work.
    /// Every control the report carries overwrites its entry; controls it
    /// doesn't carry keep their last value. Single-report pads write every
    /// control each time, so this is the same as replacing; devices that
    /// split controls across report IDs (a SpaceMouse) keep translation
    /// while a rotation report arrives, and a report the decoder ignores
    /// (battery, sensor, wrong length) no longer blanks the whole state.
    /// Everything back to rest: an emptied GameCube port, a wake.
    func resetState() {
        lock.lock()
        _state = ControllerState()
        pulses = [:]
        pulseGeneration &+= 1
        lock.unlock()
        imu.dropTurn()
    }

    func updateState(_ newValue: ControllerState) {
        // A report that carries motion is a fresh IMU sample, so its rates
        // are not read as a stalled link's.
        if !newValue.motion.isEmpty { imu.markReport() }
        lock.lock()
        _state.buttons.merge(newValue.buttons) { _, new in new }
        _state.axes.merge(newValue.axes) { _, new in new }
        _state.hats.merge(newValue.hats) { _, new in new }
        _state.motion.merge(newValue.motion) { _, new in new }
        _state.motionAngle.merge(newValue.motionAngle) { _, new in new }
        _state.motionCorrection.merge(newValue.motionCorrection) { _, new in new }
        _state.motionAbsolute.merge(newValue.motionAbsolute) { _, new in new }
        lock.unlock()
    }

    // MARK: Short presses (Stream Deck + turns and touch strip)

    /// How long a pulse holds its button, and the gap before the next one
    /// on the same button. Both outlast one poll at the engine's 30 Hz idle
    /// rate, so the press and the release between two pulses are each seen.
    static let pulseHold: TimeInterval = 0.05
    static let pulseGap: TimeInterval = 0.04
    /// Pulses waiting behind the one held, per button. A fast spin sends
    /// more turns than can be pressed one by one; past this many they are
    /// dropped, so a dial does not keep firing after it stops.
    static let pulseQueueLimit = 3

    /// Per button: whether a pulse is held or in its gap, and how many wait.
    private var pulses: [Int: (busy: Bool, waiting: Int)] = [:]
    /// Bumped by `resetState`, so pulses already scheduled do nothing.
    private var pulseGeneration = 0

    /// Press each button briefly, for a control that sends one event and
    /// no release (a dial turn, a touch strip tap). A pulse on a button
    /// still pressed from the last one waits its turn, so a binding sees
    /// each as its own press instead of one long hold. Call on the main
    /// thread, where the HID report callback runs.
    func pulse(_ indices: [Int]) {
        for index in indices {
            lock.lock()
            var entry = pulses[index] ?? (false, 0)
            if entry.busy {
                entry.waiting = min(entry.waiting + 1, Self.pulseQueueLimit)
                pulses[index] = entry
                lock.unlock()
                continue
            }
            pulses[index] = (true, entry.waiting)
            _state.buttons[index] = 1
            let generation = pulseGeneration
            lock.unlock()
            schedulePulseRelease(index, generation: generation)
        }
    }

    /// Merge a decoded report whose `oneShots` buttons are single events:
    /// each one the report presses becomes a pulse, and the report's own
    /// value for them (released by any other report) is left out, so a
    /// report arriving mid-pulse does not cut it short.
    func updateState(_ newValue: ControllerState, pulsing oneShots: [Int]) {
        var decoded = newValue
        let fired = oneShots.filter { (decoded.buttons.removeValue(forKey: $0) ?? 0) > 0.5 }
        updateState(decoded)
        if !fired.isEmpty { pulse(fired) }
    }

    /// Per relative axis, bumped on each push so only the latest release acts.
    private var axisPulseGeneration: [Int: Int] = [:]

    /// Merge a decoded report whose `axes` are relative (a knob's turns).
    /// A report that turns one pushes it to full tilt for a moment, then it
    /// returns to rest; a report with no turn leaves a push already under
    /// way to finish, and a later turn the other way replaces it.
    func updateState(_ newValue: ControllerState, pulsingAxes axes: [Int]) {
        var decoded = newValue
        for axis in axes {
            guard let value = decoded.axes.removeValue(forKey: axis) else { continue }
            if abs(value) > 0.5 {
                lock.lock()
                _state.axes[axis] = value
                axisPulseGeneration[axis, default: 0] += 1
                let generation = axisPulseGeneration[axis] ?? 0
                let resetGeneration = pulseGeneration
                lock.unlock()
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.pulseHold) { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    defer { self.lock.unlock() }
                    guard self.pulseGeneration == resetGeneration,
                          self.axisPulseGeneration[axis] == generation else { return }
                    self._state.axes[axis] = 0
                }
            }
        }
        updateState(decoded)
    }

    private func schedulePulseRelease(_ index: Int, generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pulseHold) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard self.pulseGeneration == generation else { self.lock.unlock(); return }
            self._state.buttons[index] = 0
            var entry = self.pulses[index] ?? (false, 0)
            let again = entry.waiting > 0
            if again { entry.waiting -= 1 } else { entry.busy = false }
            self.pulses[index] = entry
            self.lock.unlock()
            guard again else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.pulseGap) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                guard self.pulseGeneration == generation else { self.lock.unlock(); return }
                self._state.buttons[index] = 1
                self.lock.unlock()
                self.schedulePulseRelease(index, generation: generation)
            }
        }
    }

    // MARK: Stick rest points (Switch 2)

    /// How far each stick axis reads from zero at rest, learned once per
    /// connection. The Switch 2 decoders assume every stick rests at the
    /// middle of its range (2048); a real one rests a little off, which read
    /// as a slow drift. SDL reads the pad's calibration from its flash; this
    /// takes the rest point from the first reports with every axis near the
    /// middle and removes it from each reading after.
    private var stickRest: [Int: Float]?

    func removeStickRest(_ state: inout ControllerState) {
        lock.lock()
        defer { lock.unlock() }
        if stickRest == nil {
            var rest: [Int: Float] = [:]
            for axis in 0...3 { if let v = state.axes[axis], abs(v) < 0.12 { rest[axis] = v } }
            guard rest.count == 4 else {
                for axis in 0...3 { if let v = state.axes[axis] { state.axes[axis] = max(-1, min(1, v)) } }
                return
            }
            stickRest = rest
        }
        for (axis, offset) in stickRest ?? [:] {
            if let v = state.axes[axis] { state.axes[axis] = max(-1, min(1, v - offset)) }
        }
    }

    // MARK: Motion and battery (the 2026 Steam Controller)

    private var _battery: (level: Int, state: String)?
    /// The pad's own IMU, for pads read directly (the 2026 Steam Controller).
    let imu = DirectIMU()

    func rezeroGyro() -> Bool { imu.rezeroGyro() }
    func processMotion(_ raw: [MotionChannel: Float]) -> [MotionChannel: Float] { imu.processMotion(raw) }
    func takeMotionAngle() -> [MotionChannel: Float] { imu.takeMotionAngle() }

    /// Percent and whether it is charging, once the controller has said.
    /// The state is the one GameController pads report: Charging, Full,
    /// Discharging or Unknown.
    var battery: (level: Int, state: String)? {
        lock.lock(); defer { lock.unlock() }
        return _battery
    }

    func setBattery(level: Int, state: String) {
        lock.lock(); _battery = (max(0, min(100, level)), state); lock.unlock()
    }

    /// Stable identifier the preset store can persist bindings against.
    /// Combines vendor + product so the same physical model on a
    /// different USB port still picks up its existing bindings.
    var persistentIdentifier: String {
        let vid = String(format: "%04X", UInt16(truncatingIfNeeded: vendorID))
        let pid = String(format: "%04X", UInt16(truncatingIfNeeded: productID))
        return "hid:\(vid):\(pid)"
    }

    /// Display label shown in the controller chip popover and binding
    /// editor. Prefers the profile's display name, falls back to the
    /// HID-reported product string.
    var displayName: String {
        return profile?.displayName ?? productName
    }
}

/// One IMU read directly from a pad's reports (the 2026 and 2015 Steam
/// Controllers), in the controller's own frame (X right, Y away from the
/// player, Z up out of the face), turned into the app's motion channels
/// the way GameController pads deliver them. Thread safe: reports arrive
/// on the HID or helper thread, the engine reads on the main thread.
final class DirectIMU: @unchecked Sendable {
    private let lock = NSLock()

    private var pendingAngle: [MotionChannel: Float] = [:]
    private var lastMotionAt: TimeInterval = 0
    private var gravity: (x: Float, y: Float, z: Float)?
    private var gyroBias: [MotionChannel: Float] = [:]
    private var stillSince: TimeInterval = 0
    private var lastRawGyro: [MotionChannel: Float] = [:]
    /// The raw gyro averaged over about half a second, and how much it
    /// wobbles around that average: a hand is never this steady, so a slow
    /// deliberate turn is not mistaken for the sensor's rest.
    private var meanRawGyro: [MotionChannel: Float] = [:]
    private var gyroJitter: [MotionChannel: Float] = [:]
    /// The turn about the vertical since the last re-zero, for Yaw angle
    /// rows: no sensor gives a heading, so it is the gyro's sum.
    private var yawTotal: Float = 0

    /// Re-zero on request (a Re-zero motion row or the calibration button):
    /// a pad lying still takes its current reading as the gyro's rest, at
    /// once rather than after the second the learning waits. Turn gathered
    /// so far is dropped. False when the pad is moving, which keeps the
    /// learned zero.
    func rezeroGyro() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        pendingAngle.removeAll(keepingCapacity: true)
        yawTotal = 0
        guard !lastRawGyro.isEmpty, stillSince > 0, now - stillSince > 0.25 else { return false }
        for (c, v) in lastRawGyro { gyroBias[c] = meanRawGyro[c] ?? v }
        return true
    }

    /// One IMU sample from a pad read directly, in the controller's own
    /// frame (X right, Y away from the player, Z up out of the face). The
    /// gyro loses the bias it shows at rest (learned while the controller
    /// lies still) and the accelerometer loses gravity (a slow average of
    /// it). Returned in the app's channels, as GameController pads deliver
    /// them: gyro X pitch (nose up positive), gyro Y sideways tilt (right
    /// side down positive), gyro Z turn about the real vertical (turn right
    /// positive, from gravity), and acceleration
    /// without gravity. The turn since the last report is kept for the
    /// engine's next read.
    func processMotion(_ raw: [MotionChannel: Float]) -> [MotionChannel: Float] {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        var out = raw
        let dt = lastMotionAt > 0 ? Float(min(0.05, max(0, now - lastMotionAt))) : 0
        lastMotionAt = now

        var up: (x: Float, y: Float, z: Float)?
        var onlyGravity = true
        if let ax = raw[.accelX], let ay = raw[.accelY], let az = raw[.accelZ] {
            let total = (ax * ax + ay * ay + az * az).squareRoot()
            var g = gravity ?? (ax, ay, az)
            let k: Float = 0.02
            g = (g.x + (ax - g.x) * k, g.y + (ay - g.y) * k, g.z + (az - g.z) * k)
            gravity = g
            // User acceleration in the controller's frame, signed as the
            // GameController path's is: this sensor reports the force that
            // holds it up (+1 g up at rest) where GameController reports
            // gravity's pull (-1 g), so the difference is turned around, or
            // an Accel row fired on the opposite movement.
            out[.accelX] = -(ax - g.x)
            out[.accelY] = -(ay - g.y)
            out[.accelZ] = -(az - g.z)
            let mag = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
            if mag > 0.5 { up = (g.x / mag, g.y / mag, g.z / mag) }
            // Gravity alone: the reading's size matches its own average
            // within 5 percent (relative, so the sensor's scale does not
            // matter).
            onlyGravity = total.isFinite && mag > 0 && abs(total - mag) < 0.05 * mag
            // Tilt angles from the gravity direction, scaled as the
            // GameController path's: pitch (nose up) over a quarter turn,
            // roll (right side down) over a half.
            if let u = up {
                out[.pitchAngle] = atan2(u.y, (u.x * u.x + u.z * u.z).squareRoot()) / (.pi / 2)
                out[.rollAngle] = atan2(-u.x, (u.y * u.y + u.z * u.z).squareRoot()) / .pi
            }
        }

        let gyro: [MotionChannel] = [.gyroX, .gyroY, .gyroZ]
        for c in gyro { if let v = raw[c] { lastRawGyro[c] = v } }
        // A 0.5 s average and its wobble, as the GameController path keeps.
        let alpha: Float = dt > 0 ? 1 - expf(-dt / 0.5) : 1
        for c in gyro {
            guard let v = raw[c], v.isFinite else { continue }
            let mean = (meanRawGyro[c] ?? v) + (v - (meanRawGyro[c] ?? v)) * alpha
            meanRawGyro[c] = mean
            gyroJitter[c] = (gyroJitter[c] ?? 0) + (abs(v - mean) - (gyroJitter[c] ?? 0)) * alpha
        }
        // Still: steady (no tremor) and the accelerometer reading gravity
        // alone. A slow aim held for a second used to count, and was folded
        // into the zero: the pointer stopped mid-aim and then crept back.
        // Not "near the zero", which a large starting offset fails forever
        // (it was never learned, and Re-zero always said moving).
        let still = onlyGravity && gyro.allSatisfy { (gyroJitter[$0] ?? 1) < 0.006 }
        if still {
            if stillSince == 0 { stillSince = now }
            // After a second without movement, the average is the bias.
            if now - stillSince > 1 {
                for c in gyro { gyroBias[c, default: 0] += ((meanRawGyro[c] ?? raw[c] ?? 0) - (gyroBias[c] ?? 0)) * 0.02 }
            }
        } else {
            stillSince = 0
        }
        guard raw[.gyroX] != nil else { return out }
        let wx = (raw[.gyroX] ?? 0) - (gyroBias[.gyroX] ?? 0)
        let wy = (raw[.gyroY] ?? 0) - (gyroBias[.gyroY] ?? 0)
        let wz = (raw[.gyroZ] ?? 0) - (gyroBias[.gyroZ] ?? 0)
        // A turn to the right is clockwise from above: negative about up.
        let worldYaw = up.map { -(wx * $0.x + wy * $0.y + wz * $0.z) } ?? -wz
        // Gyro Y is sideways tilt, right side down positive (a right-hand
        // turn about the forward axis), as on GameController pads.
        let channels: [(MotionChannel, Float)] = [(.gyroX, wx), (.gyroY, wy), (.gyroZ, worldYaw)]
        for (c, rate) in channels {
            out[c] = rate
            if dt > 0, abs(rate) > 0.006 { pendingAngle[c, default: 0] += rate * dt }
        }
        if dt > 0, abs(worldYaw) > 0.006 {
            yawTotal += worldYaw * dt
            if yawTotal > .pi { yawTotal -= 2 * .pi } else if yawTotal < -.pi { yawTotal += 2 * .pi }
        }
        out[.yawAngle] = yawTotal / .pi
        return out
    }

    /// The turn since the last call, cleared as it is read.
    /// Turn older than a quarter second is dropped, as the Game Controller
    /// path's drainGyro does: piled up while nothing read it (the pad
    /// switched off, the engine not yet started), it jumped the pointer.
    func takeMotionAngle() -> [MotionChannel: Float] {
        lock.lock()
        defer { lock.unlock() }
        let now = CACurrentMediaTime()
        let stale = now - lastAngleTake > 0.25
        lastAngleTake = now
        let out = stale ? [:] : pendingAngle
        pendingAngle.removeAll(keepingCapacity: true)
        return out
    }
    private var lastAngleTake: CFTimeInterval = 0

    /// A gyro rate with no report behind it for longer than this reads as
    /// rest, as a GameController pad's does (GameControllerService
    /// drainGyro): a link that stalls mid-turn held a motion row's key until
    /// the next report, however long that took.
    /// Wider than drainGyro's 50 ms: a Bluetooth link spaces reports out
    /// more, and a rate zeroed between two of them would flicker a row.
    static let staleAfter: TimeInterval = 0.15

    /// When the last report with motion reached the pad, for one whose
    /// samples arrive already processed.
    private var lastReportAt: TimeInterval = 0
    func markReport() {
        lock.lock(); lastReportAt = ProcessInfo.processInfo.systemUptime; lock.unlock()
    }

    /// Seconds since the last IMU sample, or infinity before the first.
    var reportAge: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        let last = max(lastMotionAt, lastReportAt)
        return last > 0 ? ProcessInfo.processInfo.systemUptime - last : .infinity
    }

    /// The motion channels as a reader should see them: the gyro rates at
    /// rest when reports have stopped. Acceleration and angles are left as
    /// they are.
    func freshMotion(_ motion: [MotionChannel: Float]) -> [MotionChannel: Float] {
        guard reportAge > Self.staleAfter else { return motion }
        var out = motion
        for c in [MotionChannel.gyroX, .gyroY, .gyroZ] where out[c] != nil { out[c] = 0 }
        return out
    }

    /// Turn gathered so far is dropped (a reset, a wake).
    func dropTurn() {
        lock.lock(); pendingAngle.removeAll(keepingCapacity: true); lock.unlock()
    }

    /// The same unit waking (a wireless 2015 pad's power cycle): the
    /// gravity learned before is dropped, since it was put down and picked
    /// up in another pose, but its gyro rest is kept, which a held pad
    /// could take a long while to learn again.
    func forgetGravity() {
        lock.lock()
        pendingAngle.removeAll(keepingCapacity: true)
        lastMotionAt = 0
        lastReportAt = 0
        gravity = nil
        stillSince = 0
        lock.unlock()
    }

    /// Everything learned forgotten, for a controller switched off or
    /// replaced: gravity learned lying flat read as a shake when the pad
    /// was picked up tilted, and one unit's gyro rest crept another's.
    func reset() {
        lock.lock()
        pendingAngle.removeAll(keepingCapacity: true)
        lastMotionAt = 0
        lastReportAt = 0
        gravity = nil
        gyroBias.removeAll(keepingCapacity: true)
        stillSince = 0
        lastRawGyro.removeAll(keepingCapacity: true)
        meanRawGyro.removeAll(keepingCapacity: true)
        gyroJitter.removeAll(keepingCapacity: true)
        yawTotal = 0
        lock.unlock()
    }
}
