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
/// its lifetime. `state` is lock-protected: the input report callback runs
/// on the raw HID report thread (`RawHIDReportThread`, where the devices
/// are scheduled) and the mapping engine reads on the main thread.
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
    /// A descriptor pad's relative axes (a knob's turns), from its profile.
    /// Worked out once: each report rebuilt the list (a flatMap, a filter,
    /// a Set and a sort, about six allocations) up to 1000 times a second,
    /// unchanged reports included.
    let relativeAxes: [Int]

    /// The relative axis slots of a profile's descriptor plan; none for a
    /// hand-coded layout of another kind.
    static func relativeAxisSlots(of profile: ControllerProfile?) -> [Int] {
        guard case .generic(let generic)? = profile?.layout else { return [] }
        return HIDExtendedLayoutRegistry.extended(for: generic).relativeAxisSlots
    }

    /// Underlying HID device. Held strongly so it isn't released while
    /// the input report callback is registered. nil for a synthetic pad
    /// (the test bench and the replay hook), which no report is ever sent to.
    let device: IOHIDDevice?

    /// The Switch 2 stick calibration once it has been read; nil until then.
    var switch2Calibration: Switch2Calibration?

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
        self.relativeAxes = Self.relativeAxisSlots(of: profile)
    }

    /// A pad with no device behind it, fed reports by the bench or the
    /// replay hook.
    init(testProfile: ControllerProfile, vendorID: Int32, productID: Int32,
         transport: String, id: UInt64, productName: String? = nil) {
        self.device = nil
        self.id = id
        self.vendorID = vendorID
        self.productID = productID
        self.productName = productName ?? testProfile.displayName
        self.manufacturer = nil
        self.transport = transport
        self.profile = testProfile
        self.relativeAxes = Self.relativeAxisSlots(of: testProfile)
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
        counters = [:]
        pulses = [:]
        axisResetPending = []
        pulseGeneration &+= 1
        lock.unlock()
        imu.dropTurn()
    }

    /// The last counter value per wrapping axis (a jog wheel), to take deltas.
    private var counters: [Int: Int] = [:]

    func updateState(_ newValue: ControllerState) {
        // A wrapping counter (a Contour jog): the delta since the last
        // report, Int8 wrapped, becomes a push in its direction; the first
        // report only sets the reference.
        if !newValue.relativeSteps.isEmpty {
            var pushes = ControllerState()
            var pushed: [Int] = []
            lock.lock()
            for (axis, raw) in newValue.relativeSteps {
                if let old = counters[axis] {
                    let delta = Int(Int8(truncatingIfNeeded: raw - old))
                    if delta != 0 { pushes.axes[axis] = delta > 0 ? 1 : -1; pushed.append(axis) }
                }
                counters[axis] = raw
            }
            lock.unlock()
            if !pushed.isEmpty { updateState(pushes, pulsingAxes: pushed) }
        }
        // A report that carries motion is a fresh IMU sample, so its rates
        // are not read as a stalled link's.
        if !newValue.motion.isEmpty { imu.markReport() }
        ControllerPowerService.shared.noteRaw(key: id, state: newValue)
        let source = ObjectIdentifier(self)
        let watched = DirectPadActivity.shared.watches(source)
        lock.lock()
        let moved = watched && Self.movesControls(newValue, over: _state)
        _state.buttons.merge(newValue.buttons) { _, new in new }
        _state.axes.merge(newValue.axes) { _, new in new }
        _state.hats.merge(newValue.hats) { _, new in new }
        _state.motion.merge(newValue.motion) { _, new in new }
        _state.motionAngle.merge(newValue.motionAngle) { _, new in new }
        _state.motionCorrection.merge(newValue.motionCorrection) { _, new in new }
        _state.motionAbsolute.merge(newValue.motionAbsolute) { _, new in new }
        lock.unlock()
        if moved { DirectPadActivity.shared.noteChange(source) }
    }

    /// Whether a decoded report moves a button, axis or hat off the value
    /// it holds. Motion is left out: an IMU pad reports a new sample every
    /// time, and a pad lying still lets the engine's poll rest.
    nonisolated static func movesControls(_ new: ControllerState, over old: ControllerState) -> Bool {
        new.buttons.contains { old.buttons[$0.key] != $0.value }
            || new.axes.contains { old.axes[$0.key] != $0.value }
            || new.hats.contains { key, hat in old.hats[key].map { $0.x != hat.x || $0.y != hat.y } ?? true }
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
    /// each as its own press instead of one long hold. Any thread: the
    /// state is under the lock and the release is queued on the main queue.
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
            DirectPadActivity.shared.noteChange(ObjectIdentifier(self))
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

    /// Per relative axis, when it was last pushed, and whether its return
    /// to rest is already scheduled: one main-queue block per axis rather
    /// than one per report, which a trackpad or mouse sends hundreds of
    /// times a second while it moves.
    private var axisLastPush: [Int: TimeInterval] = [:]
    private var axisResetPending: Set<Int> = []

    /// A mouse, trackpad or other pointer, by its primary usage: it moves
    /// the pointer by itself, so the visualizer does not redraw for its
    /// motion (the pointer moving to a click kept the panel redrawing).
    lazy var isPointingDevice: Bool = {
        guard let device else { return false }
        let page = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? NSNumber)?.intValue ?? 0
        let usage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? NSNumber)?.intValue ?? 0
        return (page == 0x01 && (usage == 0x01 || usage == 0x02)) || (page == 0x0D && usage == 0x05)
    }()

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
                axisLastPush[axis] = CACurrentMediaTime()
                let schedule = axisResetPending.insert(axis).inserted
                let resetGeneration = pulseGeneration
                lock.unlock()
                DirectPadActivity.shared.noteChange(ObjectIdentifier(self))
                if schedule { scheduleAxisReset(axis, after: Self.pulseHold, generation: resetGeneration) }
            }
        }
        updateState(decoded)
    }

    /// Back to rest once the axis has had no push for `pulseHold`; a push
    /// meanwhile moves the reset on rather than queuing another block.
    private func scheduleAxisReset(_ axis: Int, after delay: TimeInterval, generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            // Reset since (resetState clears the pending set): a new push
            // has its own block.
            guard self.pulseGeneration == generation else { self.lock.unlock(); return }
            let since = CACurrentMediaTime() - (self.axisLastPush[axis] ?? 0)
            if since < Self.pulseHold {
                self.lock.unlock()
                self.scheduleAxisReset(axis, after: Self.pulseHold - since, generation: generation)
                return
            }
            self._state.axes[axis] = 0
            self.axisResetPending.remove(axis)
            self.lock.unlock()
        }
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

/// Changes on the pads GameController does not report (raw HID pads, the
/// Steam Controller, racing wheels), for the engine's idle poll. A
/// GameController pad wakes the resting poll through its change handler;
/// these had no such path, so a preset reading one never rested. Their
/// reports land on whatever thread reads them (main today, a reader thread
/// if the HID manager moves), so the time of the last change and the wake
/// are kept under one lock here, and the wake always reaches the engine
/// through the main queue, never from inside a report callback. Only the
/// sources the running preset reads count.
final class DirectPadActivity: @unchecked Sendable {
    static let shared = DirectPadActivity()

    /// How a wake gets to the main thread; the bench holds it to count.
    private let post: @Sendable (@escaping @Sendable () -> Void) -> Void

    init(post: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.post = post
    }

    private let lock = NSLock()
    /// The pads, the Steam Controller service and the wheels the running
    /// preset reads, by object. Under `lock`.
    private var watched: Set<ObjectIdentifier> = []
    /// When a watched source last moved, on CACurrentMediaTime. Under `lock`.
    private var lastChange: CFTimeInterval = 0
    /// The engine's poll is resting, so a change wakes it. Under `lock`.
    private var resting = false
    /// A wake is on its way to main; changes meanwhile only stamp the time.
    /// Under `lock`.
    private var wakePending = false
    /// The engine's wake, run on main. Under `lock`.
    private var wake: (@MainActor () -> Void)?

    func setWake(_ handler: (@MainActor () -> Void)?) {
        lock.lock(); wake = handler; lock.unlock()
    }

    func watch(_ sources: Set<ObjectIdentifier>) {
        lock.lock(); watched = sources; lock.unlock()
    }

    func setResting(_ on: Bool) {
        lock.lock(); resting = on; lock.unlock()
    }

    /// Back to nothing watched, no wake: the engine stopped.
    func reset() {
        lock.lock()
        watched = []
        wake = nil
        resting = false
        wakePending = false
        lastChange = 0
        lock.unlock()
    }

    func watches(_ source: ObjectIdentifier) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return watched.contains(source)
    }

    var lastChangeTime: CFTimeInterval {
        lock.lock(); defer { lock.unlock() }
        return lastChange
    }

    /// A source moved a control. Any thread.
    func noteChange(_ source: ObjectIdentifier) {
        lock.lock()
        guard watched.contains(source) else { lock.unlock(); return }
        lastChange = CACurrentMediaTime()
        let send = resting && !wakePending && wake != nil
        if send { wakePending = true }
        lock.unlock()
        guard send else { return }
        post { [self] in
            lock.lock()
            wakePending = false
            // Read again on arrival: the poll may have woken by itself.
            let handler = resting ? wake : nil
            lock.unlock()
            MainActor.assumeIsolated { handler?() }
        }
    }
}
