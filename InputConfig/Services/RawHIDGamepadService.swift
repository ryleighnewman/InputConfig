import Foundation
import IOKit
import IOKit.hid
import GameController
import Combine
import IOBluetooth

/// Enumerates HID gamepads via IOKit and reads their input reports
/// directly, bypassing Apple's GameController framework. This is how
/// InputConfig supports controllers that GameController can't see:
/// 8BitDo Ultimate 2C in XInput mode, DInput-mode pads, the GameCube
/// adapter, the Switch 2 Pro Controller, fight sticks, wheels, etc.
/// (Xbox 360 style XUSB pads are not HID and never reach it.)
///
/// Architecture overview:
///
///   1. `IOHIDManager` is configured with a match dictionary covering
///      Generic Desktop / Joystick + Generic Desktop / Gamepad usage
///      pages. Whenever a matching device appears the connect handler
///      fires.
///   2. For each device we look up a `ControllerProfile` from
///      `ControllerProfileDatabase`. If we find one we install an input
///      report callback and start parsing. If no profile matches we
///      record the device but skip input until we add a descriptor
///      parser (see `HIDDescriptorParser`).
///   3. The input report callback runs on IOKit's runloop thread
///      (the main runloop in our case). It calls a `nonisolated`
///      handler that decodes the report off-actor and writes the
///      resulting state into the lock-protected `RawHIDGamepad`. No
///      Task/main-actor hop on the hot path.
///   4. `GameControllerService` polls the published gamepad list each
///      half second to slot them in alongside the GCControllers + Steam
///      Controller, and queries `state(for:)` from its mapping
///      pipeline.
@MainActor
final class RawHIDGamepadService: ObservableObject {

    static let shared = RawHIDGamepadService()

    /// All gamepads we have seen and successfully started reading.
    /// Published so the controller list UI and `GameControllerService`
    /// can react to attach / detach.
    @Published private(set) var connectedGamepads: [RawHIDGamepad] = []

    /// HID devices we found but couldn't identify with a hand-coded
    /// profile. Kept for diagnostic display in Settings → Devices.
    @Published private(set) var unidentifiedDevices: [UnidentifiedDevice] = []

    struct UnidentifiedDevice: Identifiable, Equatable {
        let id: UInt64
        let vendorID: Int32
        let productID: Int32
        let productName: String
    }

    private var manager: IOHIDManager?
    /// Open gamepads keyed by the IORegistry entry ID of the HID interface
    /// (see `deviceKey`), not the bus location: every interface of a USB
    /// device shares one location, so a two-port adapter or a dongle with
    /// several gamepad interfaces lost all but one, and a Bluetooth pad
    /// that reconnected before its old device object went away collided
    /// with itself. The entry ID is the same for every IOHIDDevice object
    /// made for one interface (this service's and the registry's), and new
    /// for every reconnect.
    private var openDevices: [UInt64: RawHIDGamepad] = [:]
    /// Interfaces opened by hand or remembered from an earlier manual
    /// connection. These stay open even if GameController lists the device.
    private var forcedKeys: Set<UInt64> = []
    /// Logitech wheels sent the native-mode switch, by location, and when:
    /// within half a minute the same wheel is not switched again (it is
    /// read as it is if the switch did nothing); a later plug-in is.
    private var wheelsSwitched: [UInt64: Date] = [:]
    /// Interfaces waiting a moment for GameController to claim them.
    private var awaitingGameController: Set<UInt64> = []
    /// How long to give GameController to list a controller from a vendor
    /// it supports before this service reads the device itself.
    private let gameControllerGrace: TimeInterval = 1.5
    /// Pads GameController itself supports by name get longer: at login or
    /// on a Bluetooth reconnect it can take a few seconds to list one, and
    /// reading it here meanwhile drove slot 0 with generic numbers, then
    /// handed it back mid-press.
    private func grace(vendorID: Int32, productID: Int32) -> TimeInterval {
        Self.gameControllerKeywords(vendorID: vendorID, productID: productID) != nil ? 4 : gameControllerGrace
    }
    private var gcObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    /// Commands some pads need before they send anything.
    private func sendStartupCommands(_ device: IOHIDDevice, profile: ControllerProfile?,
                                     vendorID: Int32, productID: Int32) {
        // A DualShock 3 on USB stays silent until the host puts it in
        // operational mode. SDL_hidapi_ps3.c (and the kernel) read feature
        // reports 0xF2 (17 bytes) and 0xF5 (8 bytes), then send a one-byte
        // output report, which ShanWan clones skip (it sets them rumbling
        // non-stop). The 0xF4 feature report this app sent before follows
        // as a fallback. Without any of it the pad enumerates, opens, and
        // never emits a single input report.
        if let p = profile, case .dualShock3 = p.layout {
            var f2 = [UInt8](repeating: 0, count: 17), f2Length = CFIndex(f2.count)
            IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0xF2, &f2, &f2Length)
            var f5 = [UInt8](repeating: 0, count: 8), f5Length = CFIndex(f5.count)
            IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0xF5, &f5, &f5Length)
            let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? ""
            let shanWan = vendorID == 0x2563 || vendorID == 0x20BC
                || (vendorID == 0x054C && name.lowercased().hasPrefix("shanwan"))
            if !shanWan {
                var poke: [UInt8] = [0xF5]
                IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0xF5, &poke, poke.count)
            }
            var enable: [UInt8] = [0x42, 0x0C, 0x00, 0x00]
            IOHIDDeviceSetReport(device,
                                 kIOHIDReportTypeFeature,
                                 0xF4,
                                 &enable,
                                 enable.count)
        }
        // A Logitech wheel in its own mode: its range set to 900 degrees as
        // SDL does when it opens one, so the angle the Live Visualizer
        // shows is the wheel's real one.
        if vendorID == LogitechWheel.vendor, let commands = LogitechWheel.rangeCommands(product: productID) {
            for command in commands {
                var bytes = command
                IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, &bytes, bytes.count)
            }
        }
        // The Switch 2 Pro Controller is silent in the same way, but its
        // start-up commands go to a separate USB interface, not through HID.
        if let p = profile, p.layout == .switch2Pro || p.layout == .switch2GameCube {
            Switch2USBEnabler.shared.enableConnectedControllers()
        }
        // The 2026 Steam Controller sends its gyro and accelerometer only
        // when asked, and only while something reads it.
        if let p = profile, p.layout == .steamController2026 {
            applySteam2026IMU(device)
            if steam2026LizardOff { sendSteam2026Setting(device, setting: 9, value: 0) }
            ensureSteam2026LizardTimer()
        }
        // The GameCube controller adapter (WUP-028) reports nothing until
        // the host sends the one-byte 0x13 start command on its output
        // endpoint.
        if vendorID == 0x057E && productID == 0x0337 {
            var start: [UInt8] = [0x13]
            let kr = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x13, &start, start.count)
            if kr != kIOReturnSuccess {
                ActivityLog.shared.warning("Devices", "GameCube adapter did not accept its start command (\(kr))")
            }
        }
    }
    private var reportBuffers: [UInt64: UnsafeMutablePointer<UInt8>] = [:]
    private var reportBufferSizes: [UInt64: Int] = [:]
    /// Floor for per-device report buffer allocation. Devices that
    /// report a larger `kIOHIDMaxInputReportSizeKey` get a buffer
    /// matched to their declared maximum so fight-stick HID reports
    /// (up to ~128 bytes) aren't truncated mid-decode.
    private let minimumReportBufferSize = 64

    /// Maps the raw IOHIDDevice pointer identity to its interface key so
    /// the nonisolated callback can find the matching gamepad without
    /// taking a lock or rummaging through ObservableObject state.
    /// Access serialized via `deviceLookupLock`.
    nonisolated(unsafe) private var deviceToKey: [ObjectIdentifier: UInt64] = [:]
    private let deviceLookupLock = NSLock()

    /// Same idea for the gamepad itself - the report callback needs to
    /// reach the RawHIDGamepad to write its updated state without
    /// hopping to the main actor each frame.
    nonisolated(unsafe) private var gamepadsByKey: [UInt64: RawHIDGamepad] = [:]

    /// Ports 2 to 4 of a GameCube controller adapter, by adapter key and
    /// port. The adapter sends all four ports in one report; port 1 is the
    /// adapter's own gamepad, and each other port becomes its own gamepad
    /// (sharing the adapter's device) while a pad is plugged into it.
    /// Access serialized via `deviceLookupLock`.
    nonisolated(unsafe) private var gameCubePorts: [UInt64: [Int: RawHIDGamepad]] = [:]
    /// Extra players of a two-player adapter, by interface key and report
    /// ID; see HIDDescriptorParser.playerLayouts. Under deviceLookupLock.
    nonisolated(unsafe) private var playerPads: [UInt64: [Int: RawHIDGamepad]] = [:]
    /// Who reads raw pads right now ("engine", "live"); reports are only
    /// decoded while someone does. Under deviceLookupLock.
    nonisolated(unsafe) private var decodeReasons: Set<String> = []
    /// The last report of each ID from each interface, kept undecoded so
    /// reading can start from where every control sits. Under deviceLookupLock.
    nonisolated(unsafe) private var lastReports: [UInt64: [UInt32: [UInt8]]] = [:]

    // MARK: 2026 Steam Controller

    /// 0x1302 wired, 0x1303 Bluetooth, 0x1304 and 0x1305 the Puck dongles.
    nonisolated static let steamController2026Products: [Int32] = [0x1302, 0x1303, 0x1304, 0x1305]
    nonisolated static func isSteamController2026Dongle(_ productID: Int32) -> Bool {
        productID == 0x1304 || productID == 0x1305
    }
    /// Puck slots with no controller in them: open, so their reports are
    /// heard, but not offered as controllers. Under deviceLookupLock.
    nonisolated(unsafe) private var dormantKeys: Set<UInt64> = []
    /// Lizard mode (the controller's own mouse and keys) is off while a
    /// preset runs. The controller turns it back on by itself when the
    /// command stops coming, so it is sent again every 2 seconds.
    nonisolated(unsafe) private var steam2026LizardOff = false
    nonisolated(unsafe) private var steam2026LizardTimer: DispatchSourceTimer?
    /// A running rumble, re-sent every 40 ms: the controller stops on its
    /// own about 50 ms after the last command.
    nonisolated(unsafe) private var steam2026Rumble: [UInt64: (timer: DispatchSourceTimer, until: TimeInterval)] = [:]

    /// The 2026 controller's writes and their timers run here, off the main
    /// thread: a blocking write over Bluetooth stalled the poll loop.
    nonisolated static let steam2026Queue = DispatchQueue(label: "InputConfig.steamController2026")

    /// One settings write (feature report 1, message 0x87).
    nonisolated private func sendSteam2026Setting(_ device: IOHIDDevice, setting: UInt8, value: UInt16) {
        var report = [UInt8](repeating: 0, count: 64)
        report[0] = 0x01
        report[1] = 0x87                 // set settings values
        report[2] = 3                    // one setting: number, then a 16-bit value
        report[3] = setting
        report[4] = UInt8(value & 0xFF)
        report[5] = UInt8(value >> 8)
        // On the controller's own queue: a feature write over Bluetooth
        // waits for the controller's answer, and on the main thread that
        // wait stalled the engine's poll.
        let r = report
        Self.steam2026Queue.async {
            var bytes = r
            IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0x01, &bytes, bytes.count)
        }
    }

    /// Every open 2026 Steam Controller with a controller in it.
    nonisolated private func activeSteam2026Pads() -> [RawHIDGamepad] {
        deviceLookupLock.lock()
        defer { deviceLookupLock.unlock() }
        return gamepadsByKey.filter { key, pad in
            pad.profile?.layout == .steamController2026 && !dormantKeys.contains(key)
        }.map(\.value)
    }

    /// Turn the controllers' own mouse and keys off (a preset runs) or back on.
    nonisolated func setSteamController2026LizardOff(_ off: Bool) {
        deviceLookupLock.lock()
        let changed = steam2026LizardOff != off
        steam2026LizardOff = off
        deviceLookupLock.unlock()
        for pad in activeSteam2026Pads() {
            sendSteam2026Setting(pad.device, setting: 9, value: off ? 0 : 1)   // lizard mode
        }
        _ = changed
        // Always: a pad may have arrived since the last call.
        ensureSteam2026LizardTimer()
    }

    /// The keep-alive runs only while lizard mode is wanted off and a 2026
    /// controller is there; it stops itself when the last one goes.
    nonisolated private func ensureSteam2026LizardTimer() {
        Self.steam2026Queue.async { [weak self] in
            guard let self else { return }
            self.deviceLookupLock.lock()
            let off = self.steam2026LizardOff
            self.deviceLookupLock.unlock()
            let wanted = off && !self.activeSteam2026Pads().isEmpty
            if !wanted {
                self.steam2026LizardTimer?.cancel()
                self.steam2026LizardTimer = nil
                return
            }
            guard self.steam2026LizardTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: Self.steam2026Queue)
            timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(200))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                // A tick queued just as the preset stopped must not turn
                // lizard mode back off after the "on" write.
                self.deviceLookupLock.lock()
                let stillOff = self.steam2026LizardOff
                self.deviceLookupLock.unlock()
                guard stillOff else { return }
                let pads = self.activeSteam2026Pads()
                if pads.isEmpty { self.ensureSteam2026LizardTimer(); return }
                for pad in pads { self.sendSteam2026Setting(pad.device, setting: 9, value: 0) }
            }
            timer.resume()
            self.steam2026LizardTimer = timer
        }
    }

    /// The gyro and accelerometer stream only while something reads the
    /// pads: at about 250 reports a second they kept the main thread busy
    /// and the controller's battery draining with nothing running.
    nonisolated private func applySteam2026IMU(_ device: IOHIDDevice? = nil) {
        deviceLookupLock.lock()
        let on = !decodeReasons.isEmpty
        deviceLookupLock.unlock()
        let devices = device.map { [$0] } ?? activeSteam2026Pads().map(\.device)
        for d in devices { sendSteam2026Setting(d, setting: 48, value: on ? 0x18 : 0) }
    }

    /// Rumble both motors at `intensity` (0 to 1) for `durationMs`.
    nonisolated func rumbleSteamController2026(gamepadID: UInt64, intensity: Float, durationMs: Int) {
        deviceLookupLock.lock()
        let pad = gamepadsByKey[gamepadID]
        deviceLookupLock.unlock()
        guard let pad, pad.profile?.layout == .steamController2026 else { return }
        let speed = UInt16(max(0, min(1, intensity)) * 65535)
        let until = ProcessInfo.processInfo.systemUptime + Double(max(60, durationMs)) / 1000
        Self.steam2026Queue.async { [weak self] in
            guard let self else { return }
            self.steam2026Rumble[gamepadID]?.timer.cancel()
            let timer = DispatchSource.makeTimerSource(queue: Self.steam2026Queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(40), leeway: .milliseconds(5))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let done = ProcessInfo.processInfo.systemUptime >= until
                self.writeSteam2026Rumble(pad.device, speed: done ? 0 : speed)
                if done {
                    self.steam2026Rumble[gamepadID]?.timer.cancel()
                    self.steam2026Rumble[gamepadID] = nil
                }
            }
            self.steam2026Rumble[gamepadID] = (timer, until)
            timer.resume()
        }
    }

    /// Stop every rumble now (an emergency stop, a disconnect).
    nonisolated func stopSteamController2026Rumble() {
        Self.steam2026Queue.async { [weak self] in
            guard let self else { return }
            for (id, entry) in self.steam2026Rumble {
                entry.timer.cancel()
                self.deviceLookupLock.lock()
                let pad = self.gamepadsByKey[id]
                self.deviceLookupLock.unlock()
                if let pad { self.writeSteam2026Rumble(pad.device, speed: 0) }
            }
            self.steam2026Rumble.removeAll()
        }
    }

    /// Output report 0x80: type, intensity, then each motor's speed and gain.
    nonisolated private func writeSteam2026Rumble(_ device: IOHIDDevice, speed: UInt16) {
        let lo = UInt8(speed & 0xFF), hi = UInt8(speed >> 8)
        var report: [UInt8] = [0x80, 0x00, 0x00, 0x00, lo, hi, 0x00, lo, hi, 0x00]
        IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x80, &report, report.count)
    }

    nonisolated private func dormantSteam2026(_ key: UInt64) -> Bool {
        deviceLookupLock.lock(); defer { deviceLookupLock.unlock() }
        return dormantKeys.contains(key)
    }

    /// A Puck slot gains or loses its controller.
    private func setSteam2026Dormant(_ key: UInt64, _ dormant: Bool) {
        deviceLookupLock.lock()
        let was = dormantKeys.contains(key)
        if dormant { dormantKeys.insert(key) } else { dormantKeys.remove(key) }
        let lizardOff = steam2026LizardOff
        deviceLookupLock.unlock()
        guard was != dormant, let pad = openDevices[key] else { return }
        if dormant {
            pad.resetState()
            // Its saved reports would bring the empty slot back on the next
            // decode start, then take it away again.
            deviceLookupLock.lock()
            lastReports.removeValue(forKey: key)
            deviceLookupLock.unlock()
            connectedGamepads.removeAll { $0.id == key }
            ActivityLog.shared.info("Devices", "A Steam Controller left the Steam Controller Puck")
        } else {
            applySteam2026IMU(pad.device)
            if lizardOff { sendSteam2026Setting(pad.device, setting: 9, value: 0) }
            ensureSteam2026LizardTimer()
            if !connectedGamepads.contains(where: { $0.id == key }) { connectedGamepads.append(pad) }
            ActivityLog.shared.info("Devices", "A Steam Controller connected through the Steam Controller Puck")
        }
    }

    /// A 2026 Steam Controller report: state, battery, or the Puck saying
    /// a controller came or went.
    nonisolated private func handleSteam2026Report(_ data: Data, key: UInt64, gamepad: RawHIDGamepad, profile: ControllerProfile) {
        guard let id = data.first else { return }
        deviceLookupLock.lock()
        let dormant = dormantKeys.contains(key)
        deviceLookupLock.unlock()
        switch id {
        case 0x42, 0x45, 0x47:
            if dormant {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.setSteam2026Dormant(key, false) }
                }
            }
            var state = HIDReportDecoder.decode(report: data, profile: profile)
            state.motion = gamepad.processMotion(state.motion)
            gamepad.updateState(state)
        case 0x43 where data.count >= 3:
            // Charge state 2 is charging, 4 charged on the cable.
            gamepad.setBattery(level: Int(data[2]), charging: data[1] == 2 || data[1] == 4)
        case 0x46, 0x79:
            guard data.count >= 2, data[1] == 1 || data[1] == 2 else { return }
            let gone = data[1] == 1
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.setSteam2026Dormant(key, gone) }
            }
        default:
            break
        }
    }

    /// Reports arrive at up to 1000 a second; with no preset, editor,
    /// visualizer or scan reading them they are not decoded. A pad goes
    /// back to rest when reading stops, so nothing is held over, and when
    /// reading starts again each interface's last reports are decoded: a
    /// throttle, a latched switch or a held hat that sends nothing until it
    /// moves read at rest after every preset switch.
    func setDecodingWanted(_ wanted: Bool, reason: String) {
        deviceLookupLock.lock()
        let before = !decodeReasons.isEmpty
        if wanted { decodeReasons.insert(reason) } else { decodeReasons.remove(reason) }
        let now = !decodeReasons.isEmpty
        let pads = allPadsLocked()
        let saved = (!before && now) ? lastReports : [:]
        deviceLookupLock.unlock()
        if before != now { applySteam2026IMU() }
        if before && !now { pads.forEach { $0.resetState() } }
        for (key, reports) in saved {
            for id in reports.keys.sorted() {
                guard let bytes = reports[id] else { continue }
                decodeReport(Data(bytes), key: key)
            }
        }
    }

    /// Every pad: each interface's own, the extra players, the GameCube ports.
    nonisolated private func allPadsLocked() -> [RawHIDGamepad] {
        Array(gamepadsByKey.values) + playerPads.values.flatMap(\.values) + gameCubePorts.values.flatMap(\.values)
    }
    /// Adapters with a port change already on its way to the main actor,
    /// so a burst of reports queues one update, not one per report.
    nonisolated(unsafe) private var gameCubePortSyncPending: Set<UInt64> = []

    private init() { }

    // MARK: - Public lifecycle

    /// Build the IOHIDManager and start observing the bus. Idempotent;
    /// safe to call from app startup.
    func start() {
        guard manager == nil else { return }

        let mgr = IOHIDManagerCreate(kCFAllocatorDefault,
                                     IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr

        // Match against the two Generic Desktop usage values that all
        // HID gamepads identify with. Joystick = 0x04, Gamepad = 0x05.
        let joystickMatch: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: 0x01,
            kIOHIDDeviceUsageKey as String: 0x04,
        ]
        let gamepadMatch: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: 0x01,
            kIOHIDDeviceUsageKey as String: 0x05,
        ]
        // Multi-axis Controller (0x08): some wheels, yokes, and HOTAS
        // devices identify with this usage instead of Joystick/Gamepad
        // and would otherwise never trigger the attach callback.
        let multiAxisMatch: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: 0x01,
            kIOHIDDeviceUsageKey as String: 0x08,
        ]
        // Simulation Controls page (0x02): flight sticks, rudder pedals,
        // throttles, and some wheels declare their top-level collection
        // here (Flight Simulation Device, Automobile Simulation Device,
        // and so on) instead of on Generic Desktop.
        let simulationMatch: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: 0x02,
        ]
        // The 2026 Steam Controller's controller interface is vendor
        // defined, so it is matched by product; its keyboard and mouse
        // interfaces (lizard mode) are left alone at attach.
        let steam2026Matches: [[String: Any]] = Self.steamController2026Products.map {
            [kIOHIDVendorIDKey as String: 0x28DE, kIOHIDProductIDKey as String: Int($0)]
        }
        let matches: [[String: Any]] = [joystickMatch, gamepadMatch, multiAxisMatch, simulationMatch] + steam2026Matches
        IOHIDManagerSetDeviceMatchingMultiple(mgr, matches as CFArray)

        IOHIDManagerScheduleWithRunLoop(mgr,
                                        CFRunLoopGetMain(),
                                        CFRunLoopMode.commonModes.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { context, _, _, device in
            guard let context = context else { return }
            let svc = Unmanaged<RawHIDGamepadService>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in svc.handleDeviceAttached(device) }
        }, selfPtr)

        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { context, _, _, device in
            guard let context = context else { return }
            let svc = Unmanaged<RawHIDGamepadService>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in svc.handleDeviceDetached(device) }
        }, selfPtr)

        // No IOHIDManagerOpen: it opened every matched device, including a
        // composite keyboard or mouse that also lists a gamepad collection,
        // and opening one of those raises the Input Monitoring prompt.
        // Attach callbacks arrive without it, and handleDeviceAttached opens
        // each device it reads on its own.

        // A controller GameController lists after this service opened it
        // (GameController can attach a moment later) is handed back to it,
        // so the same pad does not drive two slots.
        // After sleep a DualShock 3, a Switch 2 controller or the GameCube
        // adapter can be back in its silent state while still enumerated:
        // send their start-up commands again, and let go of the state held
        // from before the sleep.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Every pad, the extra players and GameCube ports included,
                // and the saved reports from before the sleep.
                self.deviceLookupLock.lock()
                let pads = self.allPadsLocked()
                self.lastReports.removeAll()
                self.deviceLookupLock.unlock()
                pads.forEach { $0.resetState() }
                for pad in self.openDevices.values {
                    self.sendStartupCommands(pad.device, profile: pad.profile,
                                             vendorID: pad.vendorID, productID: pad.productID)
                }
            }
        }
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryInputMonitoringPads() }
        }
        gcObserver = NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.yieldToGameController() }
        }
    }

    /// True for a device macOS opens only with Input Monitoring: one it
    /// marks as needing it, or one with a keyboard or keypad collection.
    /// Devices already told about needing Input Monitoring this session.
    private static var inputMonitoringNoted: Set<UInt64> = []
    /// Pads left unread for want of Input Monitoring, read as soon as it is
    /// allowed (checked each time the app comes to the front), with no
    /// replug or relaunch. Main actor only.
    private var awaitingInputMonitoring: [UInt64: IOHIDDevice] = [:]
    private var activeObserver: NSObjectProtocol?

    /// Reads the pads that were waiting for Input Monitoring, once it is on.
    private func retryInputMonitoringPads() {
        guard !awaitingInputMonitoring.isEmpty,
              IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else { return }
        let waiting = awaitingInputMonitoring
        awaitingInputMonitoring.removeAll()
        for (_, device) in waiting {
            if handleDeviceAttached(device), let info = readDeviceInfo(device) {
                ActivityLog.shared.info("Devices", "Input Monitoring is on: reading \(info.productName) now")
            }
        }
    }

    /// True when the device can be opened only with Input Monitoring and
    /// it is not granted.
    nonisolated static func blockedByInputMonitoring(_ device: IOHIDDevice) -> Bool {
        needsInputMonitoring(device) && IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted
    }

    nonisolated static func needsInputMonitoring(_ device: IOHIDDevice) -> Bool {
        if (IOHIDDeviceGetProperty(device, "RequiresTCCAuthorization" as CFString) as? NSNumber)?.boolValue == true {
            return true
        }
        let pairs = IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Any]] ?? []
        return pairs.contains { pair in
            let page = (pair[kIOHIDDeviceUsagePageKey as String] as? NSNumber)?.intValue
            let usage = (pair[kIOHIDDeviceUsageKey as String] as? NSNumber)?.intValue
            return page == 0x01 && (usage == 0x06 || usage == 0x07)
        }
    }

    /// Tear everything down. Mostly for tests; the singleton stays
    /// alive for the app's lifetime in production.
    ///
    /// Order matters: clear the lookup tables BEFORE closing devices
    /// so any callback already in flight on the HID thread can't
    /// resolve a gamepad and reach a soon-to-be-deallocated object.
    /// Closing the device while the callback holds a stale pointer is
    /// the classic use-after-free this dance avoids.
    func stop() {
        deviceLookupLock.lock()
        deviceToKey.removeAll()
        gamepadsByKey.removeAll()
        gameCubePorts.removeAll()
        gameCubePortSyncPending.removeAll()
        deviceLookupLock.unlock()
        if let gcObserver { NotificationCenter.default.removeObserver(gcObserver) }
        gcObserver = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        forcedKeys.removeAll()
        awaitingGameController.removeAll()

        for (_, gamepad) in openDevices {
            IOHIDDeviceUnscheduleFromRunLoop(gamepad.device,
                                             CFRunLoopGetMain(),
                                             CFRunLoopMode.commonModes.rawValue)
            IOHIDDeviceClose(gamepad.device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        for (_, buf) in reportBuffers { buf.deallocate() }
        reportBuffers.removeAll()
        reportBufferSizes.removeAll()
        openDevices.removeAll()
        connectedGamepads = []
        unidentifiedDevices = []

        if let mgr = manager {
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerUnscheduleFromRunLoop(mgr,
                                              CFRunLoopGetMain(),
                                              CFRunLoopMode.commonModes.rawValue)
            manager = nil
        }
    }

    /// Read the latest decoded state for a gamepad.
    func state(for gamepad: RawHIDGamepad) -> ControllerState {
        return gamepad.state
    }

    // MARK: - Device lifecycle

    // MARK: - Manual connection (InputConfig ▸ Devices)

    /// True when the HID interface behind this device object is open and
    /// being read, whichever IOHIDDevice object it was opened through.
    /// True when this interface was connected by hand (or remembered from a
    /// hand connection), not opened on its own through a profile.
    func wasConnectedByHand(_ device: IOHIDDevice) -> Bool {
        guard let key = openDevices.first(where: { $0.value.device === device })?.key ?? Self.deviceKey(device) else { return false }
        return forcedKeys.contains(key)
    }

    func isOpen(_ device: IOHIDDevice) -> Bool {
        if openDevices.values.contains(where: { $0.device === device }) { return true }
        guard let key = Self.deviceKey(device) else { return false }
        return openDevices[key] != nil
    }

    /// True when any of these interfaces (one physical device's, from
    /// `HIDDeviceRegistry.devices(for:)`) is being read. Per device, so one
    /// of two identical pads is not shown as connected because of the other.
    func isReading(anyOf devices: [IOHIDDevice]) -> Bool {
        devices.contains { isOpen($0) }
    }

    /// True when a gamepad with this vendor and product is being read,
    /// whichever interface object it was opened through. Matches every
    /// identical device; prefer `isReading(anyOf:)` for one device.
    func isReading(vendorID: Int32, productID: Int32) -> Bool {
        connectedGamepads.contains { $0.vendorID == vendorID && $0.productID == productID }
    }

    /// Connect a device the user picked from the Devices menu. Skips the
    /// "leave it to the GameController framework" wait, and when neither
    /// a profile nor the descriptor parser can describe the reports, reads
    /// them raw: every bit of the report becomes a button, so the scanner
    /// still finds whichever bit a control flips. A device GameController
    /// already lists is refused: reading it here too doubles every input.
    @discardableResult
    func adopt(_ device: IOHIDDevice, remember: Bool = true) -> Bool {
        guard let info = readDeviceInfo(device) else { return false }
        if isListedByGameController(device) {
            ActivityLog.shared.info("Devices", "Not connecting \(info.productName) by hand: macOS GameController already reads it")
            return false
        }
        // A pad that also presents a keyboard can only be opened with Input
        // Monitoring; say that, once, instead of blaming another app.
        if Self.needsInputMonitoring(device),
           IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            if !Self.inputMonitoringNoted.contains(info.key) {
                Self.inputMonitoringNoted.insert(info.key)
                ActivityLog.shared.info("Devices", "\(info.productName) also acts as a keyboard or mouse, so macOS lets InputConfig read it only with Input Monitoring (System Settings, Privacy & Security)")
            }
            awaitingInputMonitoring[info.key] = device
            return false
        }
        if isOpen(device) {
            ActivityLog.shared.info("Devices", "\(info.productName) is already being read; nothing to connect")
            if remember { HIDDeviceRegistry.remember(device, true) }
            forcedKeys.insert(info.key)
            return false
        }
        let opened = handleDeviceAttached(device, forced: true)
        if opened {
            if remember {
                HIDDeviceRegistry.remember(device, true)
            }
            ActivityLog.shared.info("Devices", "Connected \(info.productName) (\(info.transport)) by hand")
        } else if !isOpen(device) {
            ActivityLog.shared.error("Devices", "Could not open \(info.productName); another app or driver may hold it")
        }
        return opened
    }

    /// Stop reading a device the user connected by hand and forget it.
    func release(_ device: IOHIDDevice) {
        if let info = readDeviceInfo(device) {
            HIDDeviceRegistry.remember(device, false)
            ActivityLog.shared.info("Devices", "Disconnected \(info.productName)")
        }
        handleDeviceDetached(device)
    }

    /// Stop reading every open interface of one physical device (its
    /// interfaces from `HIDDeviceRegistry.devices(for:)`) and forget the
    /// manual connection. Other devices with the same vendor and product
    /// are left alone.
    func release(devices: [IOHIDDevice]) {
        var logged = false
        for device in devices {
            HIDDeviceRegistry.remember(device, false)
            guard isOpen(device) else { continue }
            if !logged, let info = readDeviceInfo(device) {
                ActivityLog.shared.info("Devices", "Disconnected \(info.productName)")
                logged = true
            }
            handleDeviceDetached(device)
        }
    }

    /// Stop reading every open interface of this vendor/product and forget
    /// the manual connection. Affects every identical device; prefer
    /// `release(devices:)` for one device.
    func release(vendorID: Int32, productID: Int32) {
        for gamepad in openDevices.values where gamepad.vendorID == vendorID && gamepad.productID == productID {
            HIDDeviceRegistry.remember(gamepad.device, false)
            ActivityLog.shared.info("Devices", "Disconnected \(gamepad.productName)")
            handleDeviceDetached(gamepad.device)
        }
        var set = HIDDeviceRegistry.rememberedPairs()
        set.remove(HIDDeviceRegistry.pairKey(vendorID: vendorID, productID: productID))
        UserDefaults.standard.set(Array(set).sorted(), forKey: HIDDeviceRegistry.rememberedKey)
    }

    /// Called by `HIDDeviceRegistry` when any HID device leaves. Devices
    /// outside this service's gamepad filter were opened through the
    /// registry's device object, so only the registry sees them go.
    func deviceWentAway(_ device: IOHIDDevice) {
        guard isOpen(device) else { return }
        handleDeviceDetached(device)
    }

    /// Returns true when the device ended up open and reading.
    @discardableResult
    private func handleDeviceAttached(_ device: IOHIDDevice, forced: Bool = false,
                                      afterGameControllerWait: Bool = false) -> Bool {
        guard let info = readDeviceInfo(device) else { return false }
        // A device the user connected by hand before is treated as forced
        // every time it comes back.
        let forced = forced || HIDDeviceRegistry.isRemembered(device)

        if openDevices[info.key] != nil {
            if forced { forcedKeys.insert(info.key) }
            return false
        }

        if !forced {
            if isListedByGameController(device) {
                awaitingGameController.remove(info.key)
                return false
            }
            // GameController often lists a controller a moment after IOKit
            // reports it. For vendors it supports, and any gamepad macOS
            // says GameController reads, wait briefly and look again before
            // reading the device here.
            let gameControllerSupports = Self.gameControllerSupports(device, vendorID: info.vendorID)
            if !afterGameControllerWait && (Self.gameControllerVendors.contains(info.vendorID) || gameControllerSupports) {
                awaitingGameController.insert(info.key)
                DispatchQueue.main.asyncAfter(deadline: .now() + grace(vendorID: info.vendorID, productID: info.productID)) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.awaitingGameController.remove(info.key) != nil else { return }
                        if self.handleDeviceAttached(device, afterGameControllerWait: true) {
                            ActivityLog.shared.info("Devices", "Reading \(info.productName) directly: GameController does not list it")
                        }
                    }
                }
                return false
            }
            awaitingGameController.remove(info.key)
            // A gamepad GameController reads under another name than its
            // HID one (the name match above misses it): left to
            // GameController while it lists a controller, or every press
            // arrived twice, on two slots with two layouts (an 8BitDo's
            // back button as RB on the second). Connecting it from the
            // Devices menu still reads it here.
            if gameControllerSupports, !GCController.controllers().isEmpty {
                ActivityLog.shared.info("Devices", "Not reading \(info.productName) directly: macOS GameController supports it. Connect it from the Devices menu to read it here instead")
                return false
            }
        }

        // A Bluetooth pad that reconnects can attach before the removal of
        // its previous connection is delivered. The old interface at the
        // same location with the same identity is gone from the registry,
        // so close it now rather than leave a dead slot behind.
        for stale in openDevices.values where stale.id != info.key
            && stale.vendorID == info.vendorID && stale.productID == info.productID
            && Self.location(of: stale.device) == info.locationID
            && !Self.isLive(stale.device) {
            handleDeviceDetached(stale.device)
        }

        // A Logitech wheel in Driving Force EX compatibility mode: switched to
        // its own mode, as Linux and SDL do. It re-attaches under its own
        // product ID moments later and is read then. Once per connection; if
        // it does not come back, it is read as it is.
        if LogitechWheel.isWheel(vendor: info.vendorID, product: info.productID),
           wheelsSwitched[info.locationID].map({ Date().timeIntervalSince($0) > 30 }) ?? true {
            let bcd = (IOHIDDeviceGetProperty(device, kIOHIDVersionNumberKey as CFString) as? NSNumber)?.intValue ?? 0
            if let switchTo = LogitechWheel.nativeModeCommand(product: info.productID, bcdDevice: bcd) {
                wheelsSwitched[info.locationID] = Date()
                var bytes = switchTo.bytes
                // A report can only be sent to an open device; it is closed
                // again at once, since the wheel re-attaches as a new one.
                var kr = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
                if kr == kIOReturnSuccess {
                    kr = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, &bytes, bytes.count)
                    IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
                }
                ActivityLog.shared.info("Devices", kr == kIOReturnSuccess
                    ? "\(info.productName): a Logitech \(switchTo.name) in compatibility mode; switched it to its own mode"
                    : "\(info.productName): could not switch the \(switchTo.name) out of compatibility mode (error \(kr)); reading it as it is")
                if kr == kIOReturnSuccess {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self, Self.isLive(device) else { return }
                            _ = self.handleDeviceAttached(device, forced: forced, afterGameControllerWait: true)
                        }
                    }
                    return false
                }
            }
        }

        // First pass: hand-coded profile lookup, for the few controllers
        // whose reports the descriptor does not describe (8BitDo XInput,
        // GameCube adapter, Switch 2 Pro, DualShock 3).
        var profile = ControllerProfileDatabase.profile(
            forVendor: info.vendorID,
            product: info.productID,
            transport: info.transport
        )

        // The 2026 Steam Controller: only its controller interface, not the
        // keyboard and mouse it offers for lizard mode.
        if profile?.layout == .steamController2026 {
            // Over Bluetooth every collection can come as one device whose
            // first collection is the keyboard, so the usage pairs count too.
            let page = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? NSNumber)?.intValue ?? 0
            let usage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? NSNumber)?.intValue ?? 0
            let pairs = (IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Any]]) ?? []
            let vendorPair = pairs.contains { (($0[kIOHIDDeviceUsagePageKey as String] as? NSNumber)?.intValue ?? 0) >= 0xFF00 }
            guard page >= 0xFF00 || vendorPair || (page == 0x01 && (usage == 0x04 || usage == 0x05)) else {
                ActivityLog.shared.info("Devices", "\(info.productName): skipped an interface that is only its keyboard or mouse (lizard mode)")
                return false
            }
            // The Puck's pogo-pin interface (vendor page 0xFF00, usage 2)
            // is the charging contact, not a controller; SDL and the kernel
            // skip it too.
            if Self.isSteamController2026Dongle(info.productID), page == 0xFF00, usage == 0x02 {
                ActivityLog.shared.info("Devices", "\(info.productName): skipped the Puck's charging contact interface")
                return false
            }
        }

        // A Logitech wheel: its own descriptor, with the separate pedal
        // fields added where it names only a combined axis, and steering
        // and pedals on the one wheel plan (LogitechWheel). Ahead of the
        // GameControllerDB, whose rows treat a wheel as a gamepad.
        if profile == nil, LogitechWheel.isWheel(vendor: info.vendorID, product: info.productID),
           let original = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data,
           let parsed = HIDDescriptorParser.parseExtended(original) {
            let pedals = LogitechWheel.addSeparatePedals(parsed, descriptorLength: original.count,
                                                         vendor: info.vendorID, product: info.productID)
            let wheel = LogitechWheel.normalize(pedals, product: info.productID)
            var layout = wheel.legacyLayout
            layout.extended = wheel
            profile = ControllerProfile(
                identifier: "logitech-wheel-\(info.productID)",
                displayName: info.productName,
                vendorID: info.vendorID,
                productMatches: [.exact(info.productID)],
                layout: .generic(layout),
                physicalButtonNames: genericButtonNames(count: layout.buttonBitOffsets.count)
            )
        }

        // Second pass: SDL's GameControllerDB, which knows which of a
        // DirectInput pad's buttons is A, which axis is the right stick, and
        // so on, for pads whose descriptors only say "button 3".
        if profile == nil,
           let descriptor = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data {
            let version = (IOHIDDeviceGetProperty(device, kIOHIDVersionNumberKey as CFString) as? NSNumber)?.int32Value
            profile = SDLGameControllerDB.profile(descriptor: descriptor,
                                                  vendorID: info.vendorID,
                                                  productID: info.productID,
                                                  version: version,
                                                  productName: info.productName)
            if profile != nil {
                ActivityLog.shared.info("Devices", "\(info.productName): button names from the SDL GameControllerDB")
            }
        }

        // Third pass: if nothing above matched, ask the HID descriptor
        // parser to synthesize a generic layout. This lets unknown gamepads
        // work without code changes: older retro pads, racing wheels, and
        // the long tail of obscure controllers users report.
        if profile == nil {
            if let descriptor = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data,
               let layout = HIDDescriptorParser.parse(descriptor) {
                profile = ControllerProfile(
                    identifier: "generic-hid-\(info.vendorID)-\(info.productID)",
                    displayName: info.productName,
                    vendorID: info.vendorID,
                    productMatches: [.exact(info.productID)],
                    layout: .generic(layout),
                    physicalButtonNames: genericButtonNames(count: layout.buttonBitOffsets.count)
                )
            }
        }

        // Last resort for a manual connection: no layout at all, so read
        // the report as a bit field. reportSize 1 lets any report length
        // through the decoder's guard; bits past the payload are skipped.
        if profile == nil && forced {
            let declared = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? NSNumber)?.intValue ?? 8
            let bits = max(8, min(declared, 16)) * 8
            let raw = ControllerProfile.GenericLayout(
                buttonBitOffsets: Array(0..<bits),
                axisByteOffsets: [], axisByteWidths: [], axisIsSignedFlags: [],
                hatByteOffset: nil, triggerByteOffsets: [],
                reportSize: 1, hasReportID: false)
            profile = ControllerProfile(
                identifier: "raw-hid-\(info.vendorID)-\(info.productID)",
                displayName: info.productName,
                vendorID: info.vendorID,
                productMatches: [.exact(info.productID)],
                layout: .generic(raw),
                physicalButtonNames: (0..<bits).map { "Bit \($0)" }
            )
            ActivityLog.shared.warning("Devices", "\(info.productName) has no readable layout; reading its reports bit by bit")
        }

        if profile == nil {
            let undef = UnidentifiedDevice(
                id: info.key,
                vendorID: info.vendorID,
                productID: info.productID,
                productName: info.productName
            )
            // Cache the object->key mapping for unidentified devices too,
            // so detach can resolve the key and remove the published slot.
            // Without this, unplugged unidentified devices lingered forever.
            deviceLookupLock.lock()
            deviceToKey[ObjectIdentifier(device)] = info.key
            deviceLookupLock.unlock()
            if !unidentifiedDevices.contains(undef) {
                unidentifiedDevices.append(undef)
            }
            return false
        }

        // A device with a keyboard or keypad collection (some arcade sticks
        // and macro pads list one beside the gamepad) can be opened only
        // with Input Monitoring, which InputConfig asks for only when the
        // person clicks that pad in the Devices menu; opening it without
        // that would raise the prompt on its own. Its keys still reach
        // presets through the Accessibility event path.
        // Where the person already allowed Input Monitoring (1.5 read these
        // pads then), it is read as before. The check never prompts.
        if Self.needsInputMonitoring(device),
           IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            ActivityLog.shared.info("Devices", "Not reading \(info.productName) directly: it also acts as a keyboard or mouse, which needs Input Monitoring")
            // Read as soon as Input Monitoring is allowed.
            awaitingInputMonitoring[info.key] = device
            return false
        }

        // Open the device. Pass kIOHIDOptionsTypeNone so other consumers
        // (including macOS background services) can keep reading the
        // same device. Empirically this is what we need for 8BitDo
        // controllers to work alongside system controller agents.
        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else { return false }

        sendStartupCommands(device, profile: profile, vendorID: info.vendorID, productID: info.productID)

        // Player 1 of an SDL-matched multi-player adapter: the other
        // players' reports go to their own pads, so their controls are not
        // listed as player 1's extra buttons and axes, which never fired.
        if let current = profile, current.identifier.hasPrefix("sdl-"),
           case .generic(let mainLayout) = current.layout, var plan = mainLayout.extended,
           let descriptor = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data {
            let playerIDs = Set(HIDDescriptorParser.playerLayouts(descriptor).map(\.reportID))
            if !playerIDs.isEmpty {
                plan.reports.removeAll { $0.reportID.map { playerIDs.contains($0) } ?? false }
                var generic = plan.legacyLayout
                generic.extended = plan
                let topButton = plan.reports.flatMap(\.buttons).map(\.index).max() ?? -1
                profile = ControllerProfile(
                    identifier: current.identifier,
                    displayName: current.displayName,
                    vendorID: current.vendorID,
                    productMatches: current.productMatches,
                    layout: .generic(generic),
                    physicalButtonNames: SDLGameControllerDB.buttonNames(count: topButton + 1))
            }
        }

        let gamepad = RawHIDGamepad(
            device: device,
            id: info.key,
            vendorID: info.vendorID,
            productID: info.productID,
            productName: info.productName,
            manufacturer: info.manufacturer,
            transport: info.transport,
            profile: profile
        )
        openDevices[info.key] = gamepad
        if forced { forcedKeys.insert(info.key) }

        // Build a callback lookup table so the report handler can
        // resolve `sender → gamepad` in O(1) without touching @Published
        // state or hopping to the main actor.
        // A second (third...) player on the same interface gets a pad of
        // its own, read from its own report ID.
        var players: [Int: RawHIDGamepad] = [:]
        if case .generic(let mainLayout)? = profile?.layout,
           let descriptor = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data {
            let playerLayouts = HIDDescriptorParser.playerLayouts(descriptor)
            let playerIDs = Set(playerLayouts.map(\.reportID))
            // A pad matched by its SDL GameControllerDB row: each other
            // player is read with player 1's mapped report under its own
            // ID, so its face buttons and right stick match player 1's. The
            // plain descriptor layout put them elsewhere and named them
            // "Button 0".
            let sdlPlan = (profile?.identifier.hasPrefix("sdl-") == true) ? mainLayout.extended : nil
            let sdlPrimary = sdlPlan?.reports.first { $0.reportID.map { !playerIDs.contains($0) } ?? false }
            for (n, player) in playerLayouts.enumerated() {
                let number = n + 2
                var layout = player.layout
                var names = genericButtonNames(count: player.layout.buttonBitOffsets.count)
                if let sdlPlan, var report = sdlPrimary, let primaryID = report.reportID,
                   HIDDescriptorParser.reportsShareLayout(descriptor, primaryID, player.reportID) {
                    report.reportID = player.reportID
                    let plan = HIDExtendedLayout(usesReportIDs: sdlPlan.usesReportIDs, reports: [report])
                    layout = plan.legacyLayout
                    layout.extended = plan
                    names = profile?.physicalButtonNames ?? names
                }
                players[player.reportID] = RawHIDGamepad(
                    device: device,
                    id: info.key ^ (UInt64(0x10 + n) << 56),
                    vendorID: info.vendorID,
                    productID: info.productID,
                    productName: "\(info.productName) (player \(number))",
                    manufacturer: info.manufacturer,
                    transport: info.transport,
                    profile: ControllerProfile(
                        identifier: "generic-hid-\(info.vendorID)-\(info.productID)-player\(number)",
                        displayName: "\(info.productName) (player \(number))",
                        vendorID: info.vendorID,
                        productMatches: [.exact(info.productID)],
                        layout: .generic(layout),
                        physicalButtonNames: names
                    )
                )
            }
            if !players.isEmpty {
                ActivityLog.shared.info("Devices", "\(info.productName): \(players.count + 1) players on one connection, each in its own slot")
            }

        }

        deviceLookupLock.lock()
        deviceToKey[ObjectIdentifier(device)] = info.key
        gamepadsByKey[info.key] = gamepad
        playerPads[info.key] = players.isEmpty ? nil : players
        deviceLookupLock.unlock()
        // Now that it is listed, a 2026 pad that arrived while a preset
        // runs gets its lizard-mode keep-alive (the start-up check ran
        // before it was listed and saw no pad).
        if gamepad.profile?.layout == .steamController2026 { ensureSteam2026LizardTimer() }

        // Query the device's declared max input report size. Fight
        // sticks and racing wheels can declare 128+ byte reports; a
        // fixed 64-byte buffer truncates them mid-decode and produces
        // wrong state. Fall back to our floor for devices that don't
        // declare the key.
        let declaredMax = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? NSNumber)?.intValue ?? 0
        let bufferSize = max(minimumReportBufferSize, declaredMax)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        buffer.initialize(repeating: 0, count: bufferSize)
        reportBuffers[info.key] = buffer
        reportBufferSizes[info.key] = bufferSize

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device,
            buffer,
            bufferSize,
            rawHIDInputReportCallback,
            selfPtr
        )
        IOHIDDeviceScheduleWithRunLoop(device,
                                       CFRunLoopGetMain(),
                                       CFRunLoopMode.commonModes.rawValue)

        // A Puck slot waits for a controller before it is offered as one.
        if profile?.layout == .steamController2026 && Self.isSteamController2026Dongle(info.productID) {
            deviceLookupLock.lock()
            dormantKeys.insert(info.key)
            deviceLookupLock.unlock()
        } else {
            connectedGamepads.append(gamepad)
        }
        connectedGamepads.append(contentsOf: players.sorted { $0.key < $1.key }.map(\.value))
        unidentifiedDevices.removeAll { $0.id == info.key }
        return true
    }

    private func handleDeviceDetached(_ device: IOHIDDevice) {
        // A pad still waiting for Input Monitoring is no longer there to read.
        awaitingInputMonitoring = awaitingInputMonitoring.filter { $0.value !== device }
        // Resolve the key from the cached table rather than re-reading it
        // from the dying device. IOKit frequently fails property reads for
        // an already-departed USB device, and the old early-return on that
        // failure leaked the report buffer, device handle, lookup entries, and
        // the published slot. Clear lookup tables FIRST so an in-flight HID
        // callback can't resolve a gamepad and dereference a soon-to-be-
        // released IOHIDDevice.
        //
        // The key names one interface connection, so only the entry for the
        // interface that is leaving is cleared: a reconnected pad or the
        // other port of a two-port adapter at the same location is kept.
        deviceLookupLock.lock()
        let cachedKey = deviceToKey.removeValue(forKey: ObjectIdentifier(device))
        let key = cachedKey ?? Self.deviceKey(device)
        var portIDs: Set<UInt64> = []
        if let key {
            gamepadsByKey.removeValue(forKey: key)
            portIDs = Set((gameCubePorts.removeValue(forKey: key) ?? [:]).values.map(\.id))
            portIDs.formUnion((playerPads.removeValue(forKey: key) ?? [:]).values.map(\.id))
            lastReports.removeValue(forKey: key)
            dormantKeys.remove(key)
            gameCubePortSyncPending.remove(key)
            // The same interface may be known under another device object
            // (this service's and the registry's); drop those too.
            for (object, value) in deviceToKey where value == key {
                deviceToKey.removeValue(forKey: object)
            }
        }
        deviceLookupLock.unlock()

        guard let key else { return }

        forcedKeys.remove(key)
        awaitingGameController.remove(key)
        if let gamepad = openDevices.removeValue(forKey: key) {
            IOHIDDeviceUnscheduleFromRunLoop(gamepad.device,
                                             CFRunLoopGetMain(),
                                             CFRunLoopMode.commonModes.rawValue)
            IOHIDDeviceClose(gamepad.device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if let buf = reportBuffers.removeValue(forKey: key) {
            buf.deallocate()
        }
        reportBufferSizes.removeValue(forKey: key)
        connectedGamepads.removeAll { $0.id == key || portIDs.contains($0.id) }
        unidentifiedDevices.removeAll { $0.id == key }
    }

    /// Adds or removes the gamepads for ports 2 to 4 of a GameCube adapter
    /// to match which ports have a pad plugged in.
    private func syncGameCubePorts(key: UInt64, occupied: Set<Int>) {
        deviceLookupLock.lock()
        gameCubePortSyncPending.remove(key)
        var ports = gameCubePorts[key] ?? [:]
        deviceLookupLock.unlock()
        guard let adapter = openDevices[key] else { return }

        var added: [RawHIDGamepad] = []
        var removedIDs: Set<UInt64> = []
        for port in 2...4 {
            if occupied.contains(port), ports[port] == nil {
                // A distinct ID per port; registry entry IDs never use the top byte.
                let pad = RawHIDGamepad(
                    device: adapter.device,
                    id: key ^ (UInt64(port) << 56),
                    vendorID: adapter.vendorID,
                    productID: adapter.productID,
                    productName: adapter.productName,
                    manufacturer: adapter.manufacturer,
                    transport: adapter.transport,
                    profile: ControllerProfileDatabase.gameCubeAdapterPort(port)
                )
                ports[port] = pad
                added.append(pad)
                ActivityLog.shared.info("Devices", "GameCube adapter: controller plugged into port \(port)")
            } else if !occupied.contains(port), let pad = ports.removeValue(forKey: port) {
                removedIDs.insert(pad.id)
                ActivityLog.shared.info("Devices", "GameCube adapter: controller unplugged from port \(port)")
            }
        }

        deviceLookupLock.lock()
        gameCubePorts[key] = ports.isEmpty ? nil : ports
        deviceLookupLock.unlock()
        if !removedIDs.isEmpty { connectedGamepads.removeAll { removedIDs.contains($0.id) } }
        connectedGamepads.append(contentsOf: added)
    }

    /// Close every automatically opened gamepad that GameController now
    /// lists. Devices connected by hand stay open.
    private func yieldToGameController() {
        for gamepad in openDevices.values {
            // A pad GameController supports by name that was connected by
            // hand during its grace wait (it seemed to do nothing) is handed
            // back too, and forgotten, or it was read twice from then on.
            let gameControllerPad = Self.gameControllerKeywords(vendorID: gamepad.vendorID,
                                                                productID: gamepad.productID) != nil
            guard !forcedKeys.contains(gamepad.id) || gameControllerPad else { continue }
            guard isListedByGameController(gamepad.device) else { continue }
            if forcedKeys.contains(gamepad.id) { HIDDeviceRegistry.remember(gamepad.device, false) }
            ActivityLog.shared.info("Devices", "GameController now reads \(gamepad.productName); stopped reading it directly")
            handleDeviceDetached(gamepad.device)
        }
    }

    // MARK: - Report dispatch (non-isolated)

    /// Decode a raw HID input report and write the result into the
    /// matching `RawHIDGamepad`. Called from `rawHIDInputReportCallback`
    /// on IOKit's runloop thread; deliberately non-isolated so we
    /// don't pay a Task creation cost for every report.
    nonisolated func dispatchReport(deviceRef: IOHIDDevice,
                                    reportID: UInt32,
                                    reportPointer: UnsafeMutablePointer<UInt8>,
                                    length: CFIndex) {
        deviceLookupLock.lock()
        let key = deviceToKey[ObjectIdentifier(deviceRef)]
        let decoding = !decodeReasons.isEmpty
        let known = key.map { gamepadsByKey[$0] != nil } ?? false
        // Copied in place, so a steady stream allocates nothing.
        if let key, known {
            lastReports[key, default: [:]][reportID, default: []]
                .overwrite(with: UnsafeBufferPointer(start: reportPointer, count: length))
        }
        let isAdapter = key.flatMap { gamepadsByKey[$0] }.map {
            $0.vendorID == 0x057E && $0.productID == ControllerProfileDatabase.gameCubeAdapterProductID
        } ?? false
        let steam2026 = key.flatMap { gamepadsByKey[$0] }.flatMap { pad in
            pad.profile?.layout == .steamController2026 ? pad : nil
        }
        deviceLookupLock.unlock()

        guard let key, known else { return }
        let data = Data(bytes: reportPointer, count: length)
        // Nobody reading: skip the work, except the GameCube adapter's port
        // bookkeeping, which decides which ports show as pads. It decodes
        // nothing then.
        guard decoding else {
            if isAdapter { dispatchGameCubePorts(data, key: key, decode: false) }
            // A Puck slot still notices a controller arriving or leaving.
            if let pad = steam2026, let profile = pad.profile, data.first != 0x42, data.first != 0x45, data.first != 0x47 {
                handleSteam2026Report(data, key: key, gamepad: pad, profile: profile)
            } else if steam2026 != nil, dormantSteam2026(key) {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.setSteam2026Dormant(key, false) }
                }
            }
            return
        }
        decodeReport(data, key: key)
    }

    /// Decode one report into its pad (or the player pad its ID belongs to).
    nonisolated private func decodeReport(_ data: Data, key: UInt64) {
        deviceLookupLock.lock()
        let gamepad = gamepadsByKey[key]
        let players = playerPads[key]
        deviceLookupLock.unlock()
        guard let gamepad, let profile = gamepad.profile else { return }
        if profile.layout == .steamController2026 {
            handleSteam2026Report(data, key: key, gamepad: gamepad, profile: profile)
            return
        }
        // Another player's report: its own pad decodes it.
        if let players, let id = data.first, let player = players[Int(id)], let playerProfile = player.profile {
            player.updateState(HIDReportDecoder.decode(report: data, profile: playerProfile))
            return
        }
        // A Switch 2 controller also sends replies and other report kinds;
        // only its input report is a controller state.
        if profile.layout == .switch2Pro, !HIDReportDecoder.isSwitch2ProInputReport(data) { return }
        if profile.layout == .switch2GameCube, !HIDReportDecoder.isSwitch2GameCubeInputReport(data) { return }
        let isGameCubeAdapter = gamepad.vendorID == 0x057E
            && gamepad.productID == ControllerProfileDatabase.gameCubeAdapterProductID
        // The adapter's own slot is port 1, there whether or not a pad is
        // plugged into it. An empty port reads as zero bytes, which decoded
        // as both sticks pegged down-left; it reads as a pad at rest
        // instead, like ports 2 to 4, which are only read when occupied.
        if isGameCubeAdapter, data.first == 0x21,
           !ControllerProfileDatabase.gameCubeAdapterPortOccupied(data, port: 1) {
            // Reset, not merge: an empty state merged into the last one
            // left a button held when the pad was unplugged held for good.
            gamepad.resetState()
        } else if profile.layout == .switch2Pro || profile.layout == .switch2GameCube {
            var decoded = HIDReportDecoder.decode(report: data, profile: profile)
            gamepad.removeStickRest(&decoded)
            gamepad.updateState(decoded)
        } else {
            gamepad.updateState(HIDReportDecoder.decode(report: data, profile: profile))
        }

        if isGameCubeAdapter {
            dispatchGameCubePorts(data, key: key, decode: true)
        }
    }

    /// Ports 2 to 4 of a GameCube adapter: decode each occupied port into
    /// its own gamepad, and ask the main actor to add or remove a port's
    /// gamepad when a pad is plugged in or pulled out.
    nonisolated private func dispatchGameCubePorts(_ data: Data, key: UInt64, decode: Bool) {
        guard data.first == 0x21, data.count >= 37 else { return }
        deviceLookupLock.lock()
        let ports = gameCubePorts[key] ?? [:]
        let pending = gameCubePortSyncPending.contains(key)
        deviceLookupLock.unlock()

        var occupied: Set<Int> = []
        var changed = false
        for port in 2...4 {
            let isOccupied = ControllerProfileDatabase.gameCubeAdapterPortOccupied(data, port: port)
            if isOccupied { occupied.insert(port) }
            if let pad = ports[port], let profile = pad.profile {
                if isOccupied {
                    if decode { pad.updateState(HIDReportDecoder.decode(report: data, profile: profile)) }
                } else {
                    changed = true
                }
            } else if isOccupied {
                changed = true
            }
        }
        guard changed, !pending else { return }
        deviceLookupLock.lock()
        gameCubePortSyncPending.insert(key)
        deviceLookupLock.unlock()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.syncGameCubePorts(key: key, occupied: occupied)
            }
        }
    }

    // MARK: - Helpers

    private struct DeviceInfo {
        /// IORegistry entry ID of the HID interface: see `deviceKey`.
        let key: UInt64
        let locationID: UInt64
        let vendorID: Int32
        let productID: Int32
        let productName: String
        let manufacturer: String?
        let transport: String
    }

    private func readDeviceInfo(_ device: IOHIDDevice) -> DeviceInfo? {
        guard let vidRef = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber,
              let pidRef = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber,
              let locRef = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber,
              let key = Self.deviceKey(device) else {
            return nil
        }
        let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String)
            ?? "HID Gamepad"
        let mfr = IOHIDDeviceGetProperty(device, kIOHIDManufacturerKey as CFString) as? String
        let transport = (IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String)
            ?? "Unknown"

        return DeviceInfo(
            key: key,
            locationID: locRef.uint64Value,
            vendorID: vidRef.int32Value,
            productID: pidRef.int32Value,
            productName: name,
            manufacturer: mfr,
            transport: transport
        )
    }

    /// Friendly placeholder names for descriptor-synthesized profiles
    /// where we don't know which physical button is which. The
    /// binding editor displays these in the input scanner.
    private func genericButtonNames(count: Int) -> [String] {
        return (0..<max(count, 1)).map { "Button \($0)" }
    }

    /// IORegistry entry ID of the HID interface service behind a device
    /// object. Identical for every IOHIDDevice made for that interface,
    /// unique per interface, and new each time the device connects.
    nonisolated static func deviceKey(_ device: IOHIDDevice) -> UInt64? {
        let service = IOHIDDeviceGetService(device)
        guard service != 0 else { return nil }
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS, id != 0 else { return nil }
        return id
    }

    nonisolated static func location(of device: IOHIDDevice) -> UInt64? {
        (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber)?.uint64Value
    }

    /// False once the interface behind a device object has been removed
    /// from the IORegistry, even if its removal callback has not run yet.
    nonisolated static func isLive(_ device: IOHIDDevice) -> Bool {
        let service = IOHIDDeviceGetService(device)
        guard service != 0 else { return false }
        return IORegistryEntryInPlane(service, kIOServicePlane) != 0
    }

    /// Vendors whose controllers GameController reads on current macOS
    /// (Microsoft, Sony, Nintendo, Google, Amazon). Devices from these get
    /// a short wait for GameController before this service reads them.
    static let gameControllerVendors: Set<Int32> = [0x045E, 0x054C, 0x057E, 0x18D1, 0x1949]

    /// Whether macOS says GameController reads this device itself
    /// (GCController.supportsHIDDevice), asked only for an ordinary gamepad
    /// (HID usage Game Pad) from a vendor not handled above: those keep
    /// their own rules, with the pads read here on purpose (Xbox 360,
    /// DualShock 3), and wheels and joysticks are read here by design.
    static func gameControllerSupports(_ device: IOHIDDevice, vendorID: Int32) -> Bool {
        guard !gameControllerVendors.contains(vendorID) else { return false }
        let page = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? NSNumber)?.intValue ?? 0
        let usage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? NSNumber)?.intValue ?? 0
        guard page == 0x01, usage == 0x05 else { return false }
        return GCController.supportsHIDDevice(device)
    }

    /// True when Apple's GameController framework currently lists a
    /// controller that is this device. Only an actual listing counts: a
    /// vendor-wide rule used to skip every Microsoft, Sony, Nintendo,
    /// Google, and Amazon device, which left the GameCube adapter, the
    /// Nintendo Switch Online pads, the PlayStation Access controller, and
    /// the Stadia controller in Bluetooth mode unread by anything.
    func isListedByGameController(_ device: IOHIDDevice) -> Bool {
        guard let vid = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber)?.int32Value,
              let pid = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber)?.int32Value else {
            return false
        }
        let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? ""
        return Self.gameControllerLists(vendorID: vid, productID: pid, productName: name)
    }

    /// GameController does not expose vendor and product IDs, so a listing
    /// is matched by name: known controllers by the words GameController
    /// uses for them, anything else by an exact product name match.
    static func gameControllerLists(vendorID: Int32, productID: Int32, productName: String) -> Bool {
        listingController(vendorID: vendorID, productID: productID, productName: productName) != nil
    }

    /// The name GameController shows for this device, when it lists it. A
    /// slot pinned to the HID product name ("Wireless Controller" for a
    /// DualShock 4) matched every "... Wireless Controller" pad instead.
    func gameControllerName(for device: IOHIDDevice) -> String? {
        guard let vid = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber)?.int32Value,
              let pid = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber)?.int32Value else {
            return nil
        }
        let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? ""
        return Self.listingController(vendorID: vid, productID: pid, productName: name)?.vendorName
    }

    private static func listingController(vendorID: Int32, productID: Int32, productName: String) -> GCController? {
        let controllers = GCController.controllers()
        guard !controllers.isEmpty else { return nil }
        func normalized(_ s: String) -> String {
            s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let keywords = gameControllerKeywords(vendorID: vendorID, productID: productID)
        let name = normalized(productName)
        return controllers.first { controller in
            let vendorName = controller.vendorName ?? ""
            if let keywords {
                let haystack = normalized(vendorName + " " + controller.productCategory)
                return keywords.contains { haystack.contains($0) }
            }
            return !name.isEmpty && normalized(vendorName) == name
        }
    }

    /// Xbox One, Series, Elite and Adaptive controller product IDs (USB and
    /// Bluetooth).
    private static let xboxProductIDs: Set<Int32> = [
        0x02D1, 0x02DD, 0x02E0, 0x02E3, 0x02EA, 0x02FD, 0x02FF,
        0x0B00, 0x0B05, 0x0B0A, 0x0B0C, 0x0B12, 0x0B13, 0x0B20, 0x0B21, 0x0B22,
    ]

    /// Words GameController uses for a known controller, or nil to fall
    /// back to an exact name match. Kept specific per product so, for
    /// example, a listed Switch Pro Controller does not hide a Switch 2 Pro
    /// Controller or a Nintendo Switch Online pad.
    static func gameControllerKeywords(vendorID: Int32, productID: Int32) -> [String]? {
        switch (vendorID, productID) {
        case (0x057E, 0x2069): return ["switch 2", "pro controller 2"]
        case (0x057E, 0x2009): return ["switch pro", "pro controller"]
        case (0x057E, 0x2006), (0x057E, 0x2007), (0x057E, 0x200E): return ["joy-con"]
        case (0x054C, 0x0CE6), (0x054C, 0x0DF2): return ["dualsense"]
        case (0x054C, 0x05C4), (0x054C, 0x09CC), (0x054C, 0x0BA0): return ["dualshock 4"]
        case (0x054C, 0x0268): return ["dualshock 3"]
        case (0x054C, 0x0E5F): return ["access controller"]
        // Not the HID pads 1.5 always read beside a listed Xbox pad: the
        // Xbox 360 HID IDs and their wireless receiver.
        case (0x045E, 0x028E), (0x045E, 0x028F), (0x045E, 0x02A1): return nil
        // Only the Xbox One, Series, Elite and Adaptive pads. Any other
        // Microsoft device (a SideWinder joystick) matched as soon as any
        // Xbox pad was listed, and was hidden and closed.
        case (0x045E, let pid) where Self.xboxProductIDs.contains(pid): return ["xbox"]
        case (0x18D1, 0x9400): return ["stadia"]
        case (0x1949, _): return ["luna"]
        default: return nil
        }
    }
}

// MARK: - C callback bridge

/// Free function called by IOKit on the runloop thread when a HID
/// input report arrives. Hands off to the service's nonisolated
/// `dispatchReport` so decoding happens immediately without a
/// main-actor hop.
private func rawHIDInputReportCallback(context: UnsafeMutableRawPointer?,
                                       result: IOReturn,
                                       sender: UnsafeMutableRawPointer?,
                                       type: IOHIDReportType,
                                       reportID: UInt32,
                                       report: UnsafeMutablePointer<UInt8>,
                                       reportLength: CFIndex) {
    guard result == kIOReturnSuccess else { return }
    guard let context = context, let sender = sender else { return }
    let svc = Unmanaged<RawHIDGamepadService>.fromOpaque(context).takeUnretainedValue()
    let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
    svc.dispatchReport(deviceRef: device,
                       reportID: reportID,
                       reportPointer: report,
                       length: reportLength)
}

private extension Array where Element == UInt8 {
    /// Replace the contents, reusing the storage when the length matches.
    mutating func overwrite(with source: UnsafeBufferPointer<UInt8>) {
        guard count == source.count, let base = source.baseAddress else {
            self = Array(source)
            return
        }
        withUnsafeMutableBufferPointer { $0.baseAddress?.update(from: base, count: source.count) }
    }
}

// MARK: - Disconnect

extension RawHIDGamepadService {
    /// What a Disconnect did, worded for the chip that asked.
    enum DisconnectOutcome {
        case disconnected
        /// Nothing an app can do (a cable), or macOS refused: the line says
        /// what to do instead.
        case cannot(String)
    }

    /// Disconnects the controller GameController reads as `controller`: a
    /// Bluetooth pad drops its connection, as from System Settings; a wired
    /// one cannot be disconnected by an app, and the line says so.
    func disconnect(gameController controller: GCController) -> DisconnectOutcome {
        let name = controller.vendorName ?? "The controller"
        let registry = HIDDeviceRegistry.shared
        // The physical device GameController lists as this controller.
        var interfaces: [IOHIDDevice] = []
        var transport: HIDDeviceRegistry.Transport?
        for t in HIDDeviceRegistry.Transport.allCases {
            for entry in registry.entries(on: t) {
                let devices = registry.devices(for: entry)
                if devices.contains(where: { listedController(for: $0) === controller }) {
                    interfaces = devices
                    transport = t
                    break
                }
            }
            if transport != nil { break }
        }
        if transport == .usb {
            return .cannot("\(name) is connected by cable. Unplug it to disconnect it.")
        }
        return disconnectBluetooth(interfaces: interfaces, name: name)
    }

    /// Disconnects a pad this service reads: a Bluetooth one drops its
    /// connection; a wired one is no longer read (until it is plugged in
    /// again or connected from InputConfig > Devices).
    func disconnect(gamepad: RawHIDGamepad) -> DisconnectOutcome {
        let registry = HIDDeviceRegistry.shared
        let interfaces = HIDDeviceRegistry.Transport.allCases
            .flatMap { registry.entries(on: $0) }
            .map { registry.devices(for: $0) }
            .first { $0.contains { $0 === gamepad.device } } ?? [gamepad.device]
        if gamepad.transport.localizedCaseInsensitiveContains("bluetooth") {
            let outcome = disconnectBluetooth(interfaces: interfaces, name: gamepad.displayName)
            if case .disconnected = outcome { return outcome }
        }
        release(devices: interfaces)
        return .disconnected
    }

    private func listedController(for device: IOHIDDevice) -> GCController? {
        guard let vid = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber)?.int32Value,
              let pid = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber)?.int32Value else {
            return nil
        }
        let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? ""
        return Self.listingController(vendorID: vid, productID: pid, productName: name)
    }

    /// Closes the Bluetooth link of the device with these HID interfaces:
    /// found by the address its HID serial number carries, else by name
    /// among the connected paired devices.
    private func disconnectBluetooth(interfaces: [IOHIDDevice], name: String) -> DisconnectOutcome {
        var target: IOBluetoothDevice?
        for device in interfaces {
            guard let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String else { continue }
            let address = serial.replacingOccurrences(of: ":", with: "-")
            if address.count == 17, let bt = IOBluetoothDevice(addressString: address), bt.isConnected() {
                target = bt
                break
            }
        }
        if target == nil {
            let wanted = name.lowercased()
            let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
            target = paired.first { $0.isConnected() && ($0.name ?? "").lowercased() == wanted }
        }
        if let target, target.closeConnection() == kIOReturnSuccess {
            ActivityLog.shared.info("Devices", "Disconnected \(name)")
            return .disconnected
        }
        // Disconnecting is the one thing that uses Bluetooth directly, so
        // macOS may have asked about it first; a no there lands here.
        return .cannot("macOS did not let InputConfig disconnect \(name). If you were asked about Bluetooth, allow InputConfig in System Settings > Privacy & Security > Bluetooth. Or turn the controller off, or disconnect it in System Settings > Bluetooth.")
    }
}
