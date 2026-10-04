import Foundation
import IOKit
import IOKit.hid

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
        lock.unlock()
    }

    func updateState(_ newValue: ControllerState) {
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
            guard rest.count == 4 else { return }
            stickRest = rest
        }
        for (axis, offset) in stickRest ?? [:] {
            if let v = state.axes[axis] { state.axes[axis] = max(-1, min(1, v - offset)) }
        }
    }

    // MARK: Motion and battery (the 2026 Steam Controller)

    private var pendingAngle: [MotionChannel: Float] = [:]
    private var lastMotionAt: TimeInterval = 0
    private var _battery: (level: Int, charging: Bool)?
    private var gravity: (x: Float, y: Float, z: Float)?
    private var gyroBias: [MotionChannel: Float] = [:]
    private var stillSince: TimeInterval = 0

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
        if let ax = raw[.accelX], let ay = raw[.accelY], let az = raw[.accelZ] {
            var g = gravity ?? (ax, ay, az)
            let k: Float = 0.02
            g = (g.x + (ax - g.x) * k, g.y + (ay - g.y) * k, g.z + (az - g.z) * k)
            gravity = g
            // User acceleration in the controller's frame, the frame the
            // GameController path's accelerometer uses (X right, Y away from
            // the player, Z up).
            out[.accelX] = ax - g.x
            out[.accelY] = ay - g.y
            out[.accelZ] = az - g.z
            let mag = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
            if mag > 0.5 { up = (g.x / mag, g.y / mag, g.z / mag) }
        }

        let gyro: [MotionChannel] = [.gyroX, .gyroY, .gyroZ]
        let still = gyro.allSatisfy { abs((raw[$0] ?? 0) - (gyroBias[$0] ?? 0)) < 0.05 }
        if still {
            if stillSince == 0 { stillSince = now }
            // After a second without movement, the reading is the bias.
            if now - stillSince > 1 {
                for c in gyro { gyroBias[c, default: 0] += ((raw[c] ?? 0) - (gyroBias[c] ?? 0)) * 0.02 }
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
        return out
    }

    /// The turn since the last call, cleared as it is read.
    func takeMotionAngle() -> [MotionChannel: Float] {
        lock.lock()
        defer { lock.unlock() }
        let out = pendingAngle
        pendingAngle.removeAll(keepingCapacity: true)
        return out
    }

    /// Percent and whether it is charging, once the controller has said.
    var battery: (level: Int, charging: Bool)? {
        lock.lock(); defer { lock.unlock() }
        return _battery
    }

    func setBattery(level: Int, charging: Bool) {
        lock.lock(); _battery = (max(0, min(100, level)), charging); lock.unlock()
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
