import Foundation
import GameController
import IOBluetooth
import AppKit

/// Saves a wireless controller's battery: disconnects one that has sat
/// unused for the time set in Settings, Devices, and tries to reconnect
/// paired controllers when InputConfig opens, when the Mac wakes and when a
/// preset starts. Both are off by default.
///
/// Unused means no button pressed, no stick or trigger moved past a third
/// of its travel, nothing on the D-pad. Motion sensors do not count: a pad
/// on a table reports a little gyro noise forever. Disconnecting uses the
/// same path as a controller's Disconnect button (it closes the Bluetooth
/// link, as System Settings does), so a controller on a cable is never
/// touched. Reconnecting can only reach a controller that is switched on
/// and waiting for its host; most controllers wake only from their own
/// button, which is why it is an attempt and says so.
final class ControllerPowerService: @unchecked Sendable {
    static let shared = ControllerPowerService()

    static let idleDisconnectKey = "InputConfig.idleDisconnect"
    static let idleMinutesKey = "InputConfig.idleDisconnectMinutes"
    static let whileRunningKey = "InputConfig.idleDisconnectWhileRunning"
    static let autoReconnectKey = "InputConfig.autoReconnect"
    static let minuteChoices = [5, 10, 15, 30, 60]
    static let defaultMinutes = 15

    private let lock = NSLock()
    /// Last real input per GameController pad and per raw pad key.
    private var lastGC: [ObjectIdentifier: Date] = [:]
    private var lastRaw: [UInt64: Date] = [:]
    /// Pads that cannot be disconnected by an app (a cable), skipped until
    /// they connect again.
    private var cannot: Set<ObjectIdentifier> = []
    private var rawCannot: Set<UInt64> = []
    /// Bluetooth addresses disconnected for idleness, and when, so a
    /// reconnect attempt right after does not bring them straight back.
    private var idledAt: [String: Date] = [:]
    /// The last reconnect attempt per address.
    private var triedAt: [String: Date] = [:]
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private let reconnector = Reconnector()

    private init() {}

    // MARK: - Settings

    var idleDisconnectOn: Bool { UserDefaults.standard.bool(forKey: Self.idleDisconnectKey) }
    var idleMinutes: Int {
        let m = UserDefaults.standard.integer(forKey: Self.idleMinutesKey)
        return Self.minuteChoices.contains(m) ? m : Self.defaultMinutes
    }
    /// Off by default: a controller stays connected while a preset runs.
    var disconnectWhileRunning: Bool { UserDefaults.standard.bool(forKey: Self.whileRunningKey) }
    var autoReconnectOn: Bool { UserDefaults.standard.bool(forKey: Self.autoReconnectKey) }

    // MARK: - Lifecycle

    /// Called once the bus services are up. Cheap when both settings are
    /// off: one 30 second timer that returns at once.
    @MainActor func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdle() }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // Asleep is not unused: every pad starts its count again.
            self?.resetAll()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                MainActor.assumeIsolated { self?.attemptReconnect(reason: "wake") }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            MainActor.assumeIsolated { self?.attemptReconnect(reason: "launch") }
        }
    }

    /// A setting changed: counts start again, so turning it on never
    /// disconnects a pad at once for time it sat before.
    func settingsChanged() { resetAll() }

    private func resetAll() {
        let now = Date()
        lock.lock()
        for k in lastGC.keys { lastGC[k] = now }
        for k in lastRaw.keys { lastRaw[k] = now }
        lock.unlock()
    }

    // MARK: - Activity

    /// A GameController element changed. Counts only a real use.
    func noteActivity(controller: GCController?, element: GCControllerElement) {
        guard let controller, Self.isRealUse(element) else { return }
        let id = ObjectIdentifier(controller)
        lock.lock(); lastGC[id] = Date(); lock.unlock()
    }

    /// The Access controller's own report showed a press or the stick
    /// moved (its sockets may be mapped to nothing GameController shows).
    func noteAccessActivity() {
        let now = Date()
        let ids = GCController.controllers()
            .filter { ControllerTypeDetector.detect($0) == .accessController }
            .map(ObjectIdentifier.init)
        guard !ids.isEmpty else { return }
        lock.lock(); for id in ids { lastGC[id] = now }; lock.unlock()
    }

    /// A raw pad's decoded state: counted when it shows a real use.
    func noteRaw(key: UInt64, state: ControllerState) {
        guard Self.isRealUse(state) else { return }
        lock.lock(); lastRaw[key] = Date(); lock.unlock()
    }

    static func isRealUse(_ element: GCControllerElement) -> Bool {
        switch element {
        case let b as GCControllerButtonInput: return b.isPressed || b.value > 0.33
        case let d as GCControllerDirectionPad: return max(abs(d.xAxis.value), abs(d.yAxis.value)) > 0.33
        case let a as GCControllerAxisInput: return abs(a.value) > 0.33
        default: return false
        }
    }

    /// Pure, for the bench: a button down, a stick or trigger past a third,
    /// or the D-pad off center. Motion does not count.
    static func isRealUse(_ state: ControllerState) -> Bool {
        if state.buttons.values.contains(where: { $0 > 0.5 }) { return true }
        for i in 0..<6 { if let v = state.axes[i], abs(v) > 0.33 { return true } }
        return state.hats.values.contains { $0.x != 0 || $0.y != 0 }
    }

    /// Pure, for the bench: whether a pad unused for `idle` seconds goes.
    static func shouldDisconnect(idle: TimeInterval, minutes: Int, presetRunning: Bool, whileRunning: Bool) -> Bool {
        if presetRunning && !whileRunning { return false }
        return idle >= TimeInterval(minutes * 60)
    }

    #if DEBUG
    /// Seconds since the pad's last real use, for enginestate.
    func debugIdleSeconds(_ controller: GCController) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return lastGC[ObjectIdentifier(controller)].map { Int(Date().timeIntervalSince($0)) }
    }
    #endif

    // MARK: - Idle check

    @MainActor private func checkIdle() {
        let pads = GCController.controllers()
        let raws = RawHIDGamepadService.shared.connectedGamepads
        let now = Date()
        lock.lock()
        // Forget pads that left; a new one starts its count now.
        let live = Set(pads.map(ObjectIdentifier.init))
        lastGC = lastGC.filter { live.contains($0.key) }
        cannot = cannot.intersection(live)
        for id in live where lastGC[id] == nil { lastGC[id] = now }
        let liveRaw = Set(raws.map(\.id))
        lastRaw = lastRaw.filter { liveRaw.contains($0.key) }
        rawCannot = rawCannot.intersection(liveRaw)
        for id in liveRaw where lastRaw[id] == nil { lastRaw[id] = now }
        lock.unlock()

        guard idleDisconnectOn else { return }
        let running = MappingEngine.current?.isRunning == true
        if running && !disconnectWhileRunning {
            // In use with a preset: the count starts again when it stops.
            resetAll()
            return
        }
        let minutes = idleMinutes
        for pad in pads {
            let id = ObjectIdentifier(pad)
            lock.lock()
            let last = lastGC[id] ?? now
            let skip = cannot.contains(id)
            lock.unlock()
            guard !skip, Self.shouldDisconnect(idle: now.timeIntervalSince(last), minutes: minutes,
                                               presetRunning: running, whileRunning: disconnectWhileRunning) else { continue }
            let name = pad.vendorName ?? String(localized: "The controller")
            switch RawHIDGamepadService.shared.disconnect(gameController: pad) {
            case .disconnected:
                announce(name, minutes: minutes)
            case .cannot:
                // A cable, or macOS refused: not tried again until it
                // connects anew.
                lock.lock(); cannot.insert(id); lock.unlock()
            }
        }
        for pad in raws {
            let bluetooth = pad.transport.localizedCaseInsensitiveContains("bluetooth")
            lock.lock()
            let last = lastRaw[pad.id] ?? now
            let skip = rawCannot.contains(pad.id)
            lock.unlock()
            guard bluetooth, !skip, Self.shouldDisconnect(idle: now.timeIntervalSince(last), minutes: minutes,
                                                          presetRunning: running, whileRunning: disconnectWhileRunning) else { continue }
            if pad.transport == "Bluetooth LE", pad.id >> 48 == RawHIDGamepadService.externalKeyBase >> 48 {
                Switch2BluetoothService.shared.disconnect(key: pad.id)
                announce(pad.displayName, minutes: minutes)
                continue
            }
            switch RawHIDGamepadService.shared.disconnect(gamepad: pad) {
            case .disconnected: announce(pad.displayName, minutes: minutes)
            case .cannot: lock.lock(); rawCannot.insert(pad.id); lock.unlock()
            }
        }
    }

    @MainActor private func announce(_ name: String, minutes: Int) {
        let line = String(localized: "\(name) was disconnected after \(minutes) minutes unused, to save its battery")
        ActivityLog.shared.info("Devices", line)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: line, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        // Its address, so a reconnect attempt now does not undo this.
        let wanted = name.lowercased()
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        if let match = paired.first(where: { ($0.name ?? "").lowercased() == wanted }), let address = match.addressString {
            lock.lock(); idledAt[address] = Date(); lock.unlock()
        }
    }

    // MARK: - Reconnect

    /// Pure, for the bench: a paired Bluetooth device that is a controller.
    /// The class of device says peripheral (major 5) and joystick or gamepad
    /// (minor low bits 1 or 2); a Bluetooth LE pad has no class, so its name
    /// decides.
    static func looksLikeController(major: UInt32, minor: UInt32, name: String) -> Bool {
        if major == 5, [1, 2].contains(minor & 0x0F) { return true }
        let n = name.lowercased()
        return ["controller", "dualsense", "dualshock", "xbox", "joy-con", "gamepad", "8bitdo", "stadia", "access"]
            .contains { n.contains($0) }
    }

    /// Asks every paired controller that is not connected to connect. A
    /// pad switched off does not answer, which costs nothing but a few
    /// seconds of the radio.
    @MainActor func attemptReconnect(reason: String) {
        guard autoReconnectOn else { return }
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let now = Date()
        for device in paired where !device.isConnected() {
            guard Self.looksLikeController(major: device.deviceClassMajor, minor: device.deviceClassMinor, name: device.name ?? ""),
                  let address = device.addressString else { continue }
            lock.lock()
            let idled = idledAt[address].map { now.timeIntervalSince($0) < 120 } ?? false
            let recent = triedAt[address].map { now.timeIntervalSince($0) < 60 } ?? false
            if !idled && !recent { triedAt[address] = now }
            lock.unlock()
            // Just put to sleep for idleness, or tried a moment ago: left be.
            guard !idled, !recent else { continue }
            _ = device.openConnection(reconnector)
        }
        if reason == "preset" { Switch2BluetoothService.shared.startIfEnabled() }
    }

    /// A preset started: a paired controller that is waiting may connect.
    @MainActor func presetStarted() {
        guard autoReconnectOn, GCController.controllers().isEmpty else { return }
        attemptReconnect(reason: "preset")
    }

    /// IOBluetooth's connection callback; only a success is worth a line.
    private final class Reconnector: NSObject {
        @objc func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
            guard status == kIOReturnSuccess, let device else { return }
            ActivityLog.shared.info("Devices", String(localized: "Reconnected \(device.name ?? String(localized: "a controller"))"))
        }
    }
}
