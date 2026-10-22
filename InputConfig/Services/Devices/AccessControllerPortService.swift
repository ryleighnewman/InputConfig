import Foundation
import IOKit
import IOKit.hid
import os

/// Reads the PlayStation Access controller's own report directly via IOKit
/// HID, alongside Apple's GameController framework. GameController gives an
/// Access controller the DualSense shape and reports only what the
/// controller's active profile maps onto that shape: a stick or switch in
/// an expansion port, and the buttons as the controller itself numbers
/// them, never reach any app through it. Everything the controller reports
/// comes from here and is merged into the slot's ControllerState by
/// GameControllerService.
///
/// Layout, Bluetooth input report 0x31 (78 bytes, report ID in byte 0).
/// Over USB the report is 0x01, 64 bytes, and every offset is one less.
/// Measured on a real controller over both, and matching the layouts
/// published by titania (access_input_msg), dualsense-ts and ps-access:
///   2...7    the stick, second stick and triggers as the profile maps them
///   9...11   the buttons as the profile maps them (GameController reads
///            2...11)
///   17       sockets 1...8, one bit each, in order
///   18       bit 0 center button, 1 stick press, 2 PS, 3 Profile
///   19...20  the stick itself, X and Y, 0...255 with 128 at rest
///   21...28  E1, E2, E3, E4: X and Y, two bytes each, in order
///   38       battery, the DualSense nibbles
///   41       bits 0...2 the active profile, 1...3; bit 3 profile switching off
///   42       E3 type in the low nibble, E4 type in the high
///   44...45  the mapped left stick, 48...49 the mapped right stick (copies)
///   50       E1 type in the low nibble, E2 type in the high
///   1, 8, 13...16, 57...64, 74...77 counters, a clock and a checksum
/// Port types: 0 nothing, 1 button, 2 trigger, 3 stick, told by the
/// controller itself the moment something is plugged in.
///
/// Over USB the controller also answers for its three stored profiles
/// through feature reports 0x60 (command) and 0x61 (data): what each
/// socket and port sends, by name. Read once per connection, never written.
///
/// Same pattern as `DualSenseSupplementService`: a plain final class,
/// `@unchecked Sendable`, all mutable state behind one NSLock.
final class AccessControllerPortService: @unchecked Sendable {

    static let shared = AccessControllerPortService()

    /// What the reader finds, readable with `log stream --predicate 'subsystem == "com.inputconfig"'`.
    private static let log = Logger(subsystem: "com.inputconfig", category: "AccessPorts")

    private static let vendorID: Int32 = 0x054C
    private static let accessPID: Int32 = 0x0E5F

    /// (report ID, length, offset to add to the Bluetooth byte numbers)
    private static let formats: [(id: UInt8, length: Int, shift: Int)] = [
        (0x31, 78, 0),    // Bluetooth
        (0x01, 64, -1),   // USB
    ]

    // MARK: - Layout (Bluetooth byte numbers)

    static let buttonBytes = [17, 18]
    static let stickBytes = (x: 19, y: 20)
    static let batteryByte = 38
    static let profileByte = 41
    /// The type nibbles: E1 and E2 share byte 50, E3 and E4 share byte 42.
    static func typeByte(forPort port: Int) -> Int { port <= 2 ? 50 : 42 }
    static func typeNibble(_ value: UInt8, port: Int) -> UInt8 { (value >> UInt8(port % 2 == 1 ? 0 : 4)) & 0xF }
    static let portCount = 4
    static func portBytes(_ port: Int) -> (x: Int, y: Int) { (21 + (port - 1) * 2, 22 + (port - 1) * 2) }

    /// Indices published to the slot. Axes: 6 and 7 the stick itself, then
    /// two per port from 8. Buttons: the controller's own bits from 40
    /// (sockets 1...8, center, stick press, PS, Profile), a button in a
    /// port from 56 (E1 first).
    static let stickAxes = (x: 6, y: 7)
    static func portAxes(_ port: Int) -> (x: Int, y: Int) { (8 + (port - 1) * 2, 9 + (port - 1) * 2) }
    static let buttonBase = 40
    static let portButtonBase = 56

    /// What is plugged into an expansion port, as the controller reports it.
    enum PortDevice: Equatable, CustomStringConvertible {
        case stick, trigger, button
        /// Nibble 4: something is in the port that the controller does not
        /// recognize, or a plug half seated (seen once mid insertion on
        /// 2026-10-18). Nothing is read from it.
        case invalidPlug
        init?(nibble: UInt8) {
            switch nibble {
            case 1: self = .button
            case 2: self = .trigger
            case 3: self = .stick
            case 4: self = .invalidPlug
            default: return nil
            }
        }
        var description: String {
            switch self {
            case .stick: return "stick"; case .trigger: return "trigger"; case .button: return "button"
            case .invalidPlug: return "invalid plug"
            }
        }
    }

    /// The battery byte (Bluetooth 38, USB 37), the DualSense nibbles as
    /// hid-playstation.c dualsense_parse_report reads them: low nibble the
    /// level in tenths (n * 10 + 5, capped at 100), high nibble 0
    /// discharging, 1 charging, 2 full, anything else a fault.
    struct Battery: Equatable {
        enum State: String { case discharging, charging, full, fault }
        var level: Int
        var state: State
        init(byte: UInt8) {
            switch byte >> 4 {
            case 0: state = .discharging; level = min(100, Int(byte & 0x0F) * 10 + 5)
            case 1: state = .charging; level = min(100, Int(byte & 0x0F) * 10 + 5)
            case 2: state = .full; level = 100
            default: state = .fault; level = 0
            }
        }
    }

    static func axisLabel(_ index: Int) -> String {
        switch index {
        case stickAxes.x: return String(localized: "Stick X")
        case stickAxes.y: return String(localized: "Stick Y")
        case 8..<(8 + portCount * 2):
            let port = (index - 8) / 2 + 1
            return (index - 8) % 2 == 0 ? String(localized: "E\(port) X") : String(localized: "E\(port) Y")
        default: return String(localized: "Axis \(index)")
        }
    }

    static func buttonLabel(_ index: Int) -> String {
        if index >= portButtonBase, index < portButtonBase + portCount {
            return String(localized: "E\(index - portButtonBase + 1) button")
        }
        switch index - buttonBase {
        case 0...7: return String(localized: "Socket \(index - buttonBase + 1)")
        case 8: return String(localized: "Center button")
        case 9: return String(localized: "Stick press")
        case 10: return String(localized: "PS button")
        case 11: return String(localized: "Profile button")
        default: return String(localized: "Button \(index)")
        }
    }

    // MARK: - Profiles

    /// What a stored profile makes of each control: the DualSense function
    /// each socket, the center button, the stick press and each port sends.
    /// Keeps the 956 bytes it was read from, so a save changes only the
    /// fields the app edits and leaves the rest (UUID, stick tuning) as the
    /// PS5 wrote them.
    struct Profile: Equatable, Identifiable {
        var id: Int { number }
        var number: Int
        var name: String
        /// Action codes by slot: sockets 1...8, 9 the center button, 10 the
        /// stick press. Absent means nothing.
        var buttonActions: [Int: Int] = [:]
        /// The PS5's Assign Simultaneous Press: a second function sent with
        /// the first, by the same slots.
        var secondaryActions: [Int: Int] = [:]
        /// Controller Orientation: where the stick sits, 0 below the
        /// buttons, 1 to the right, 2 above, 3 to the left. Stored in every
        /// stick record; the PS5 shows it for the controller as a whole.
        var orientation: Int = 0
        /// Toggle (press on, press off) by the same slots, 11...14 for E1...E4.
        var toggles: Set<Int> = []
        /// What each port is set up as: 0 the stick itself, 1...4 E1...E4.
        var ports: [Int: PortConfig] = [:]
        /// The bytes as read, nil for a profile the app made up.
        var bytes: [UInt8]? = nil

        enum PortConfig: Equatable {
            /// Nothing set up: an empty port, or one the profile ignores.
            case empty
            /// 1 the left stick, 2 the right stick.
            case stick(assignment: Int)
            /// A button or switch, with the action it sends and a second
            /// one pressed with it (0 for none); analog for a trigger or
            /// pedal that reports how far it is pressed.
            case button(code: Int, secondary: Int, analog: Bool)
        }

        /// Action codes for a port set up as a button, by port 1...4.
        var portActions: [Int: Int] {
            var out: [Int: Int] = [:]
            for (port, config) in ports { if case .button(let code, _, _) = config, code != 0 { out[port] = code } }
            return out
        }
        /// 1 left stick, 2 right stick, for the stick itself (0) and ports
        /// set up as sticks.
        var stickAssignments: [Int: Int] {
            var out: [Int: Int] = [:]
            for (port, config) in ports { if case .stick(let a) = config { out[port] = a } }
            return out
        }

        static func == (a: Profile, b: Profile) -> Bool {
            a.number == b.number && a.name == b.name && a.buttonActions == b.buttonActions && a.secondaryActions == b.secondaryActions
                && a.toggles == b.toggles && a.ports == b.ports && a.orientation == b.orientation
        }

        /// The slot's button index a profile action lands on, as
        /// GameController reports it. The four D-pad directions are a hat,
        /// not a button, and 0 is nothing.
        static func buttonIndex(ofAction code: Int) -> Int? {
            switch code {
            case 1: return 1      // Circle
            case 2: return 0      // Cross
            case 3: return 3      // Triangle
            case 4: return 2      // Square
            case 9: return 4      // L1
            case 10: return 5     // R1
            case 11: return 6     // L2
            case 12: return 7     // R2
            case 13: return 11    // L3
            case 14: return 12    // R3
            case 15: return 9     // Options
            case 16: return 8     // Create
            case 17: return 10    // PS
            case 18: return 13    // Touchpad
            default: return nil
            }
        }

        /// Every action a socket or port can be given, in the PS5's order,
        /// with 0 for nothing.
        static let actionCodes: [Int] = [0, 2, 1, 4, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18]

        static func actionName(_ code: Int) -> String? {
            let names: [Int: String] = [0: String(localized: "Nothing"), 1: String(localized: "Circle"), 2: String(localized: "Cross"),
                                        3: String(localized: "Triangle"), 4: String(localized: "Square"), 5: String(localized: "Up"),
                                        6: String(localized: "Down"), 7: String(localized: "Left"), 8: String(localized: "Right"),
                                        9: "L1", 10: "R1", 11: "L2", 12: "R2", 13: "L3", 14: "R3", 15: String(localized: "Options"),
                                        16: String(localized: "Create"), 17: String(localized: "PS"), 18: String(localized: "Touchpad")]
            return names[code]
        }

        static func slotName(_ slot: Int) -> String {
            switch slot {
            case 1...8: return String(localized: "Socket \(slot)")
            case 9: return String(localized: "Center button")
            case 10: return String(localized: "Stick press")
            default: return String(localized: "Slot \(slot)")
            }
        }

        /// The profile's name, or the PS5's default for the slot.
        var shownName: String { name.isEmpty ? String(localized: "Profile \(number)") : name }
    }

    enum ProfileError: Error, LocalizedError {
        case notConnected, bluetooth, switchingDisabled, refused(String), verifyFailed
        var errorDescription: String? {
            switch self {
            case .switchingDisabled: return String(localized: "Profile switching is turned off on the controller (a PS5 setting); the Profile button and this app cannot change it until it is turned on again.")
            case .notConnected: return String(localized: "The Access controller is not connected.")
            case .bluetooth: return String(localized: "Profiles can be read and changed over USB-C only; over Bluetooth, switch with the controller's Profile button.")
            case .refused(let why): return String(localized: "The controller refused the write (\(why)).")
            case .verifyFailed: return String(localized: "The controller stored something other than what was sent; nothing else was changed.")
            }
        }
    }

    private static let commandReport: CFIndex = 0x60
    private static let dataReport: CFIndex = 0x61
    private static let profileSize = 956
    private static let profileChunks = 18
    private static let chunkSize = 56

    // MARK: - State (lock-guarded)

    private final class Pad {
        /// nil for a DEBUG synthetic pad that is fed reports by hand.
        let device: IOHIDDevice?
        let identity: SonyPadIdentity
        let buffer: UnsafeMutablePointer<UInt8>
        let overUSB: Bool
        var axes: [Int: Float] = [:]
        var buttons: [Int: Float] = [:]
        /// Every button index seen pressed this connection, for the extras row.
        var seenButtons: Set<Int> = []
        var portDevices: [Int: PortDevice] = [:]
        /// Per port, the type the last reports agreed on and for how many
        /// reports in a row; a port changes only after `portSettleReports`.
        var portCandidates: [Int: (device: PortDevice?, count: Int)] = [:]
        var portLoggedAt: [Int: TimeInterval] = [:]
        var activeProfile = 0
        var switchingDisabled = false
        var battery: Battery?
        var profiles: [Int: Profile] = [:]
        var reportsSeen = 0
        /// Every report, decoded or not: a Bluetooth pad still on its
        /// compact report counts here and nowhere else.
        var rawReportsSeen = 0
        var firstReportLogged = false
        init(device: IOHIDDevice?, identity: SonyPadIdentity, buffer: UnsafeMutablePointer<UInt8>, overUSB: Bool) {
            self.device = device; self.identity = identity; self.buffer = buffer; self.overUSB = overUSB
        }
    }

    private let lock = NSLock()
    /// Feature report exchanges with one controller, one at a time.
    private let profileQueue = DispatchQueue(label: "com.inputconfig.accessprofiles", qos: .userInitiated)
    private var manager: IOHIDManager?
    private var pads: [UInt64: Pad] = [:]
    private var deviceToLocation: [ObjectIdentifier: UInt64] = [:]
    private let reportBufferSize = 96
    /// How many consecutive reports must agree before a port's type is
    /// published: a half seated plug flapped between 3 and 0 every 4 ms for
    /// two minutes on 2026-10-18 (14,521 changes).
    static let portSettleReports = 25
    private var readerThread: Thread?
    private var readerRunLoop: CFRunLoop?

    private init() {}

    // MARK: - Lifecycle

    /// Opens every Access controller's raw HID device, non-seize, next to
    /// gamecontrollerd. Safe to call more than once.
    func start() {
        #if DEBUG
        if TestCapture.inTestRun { return }
        #endif
        lock.lock()
        let started = manager != nil
        lock.unlock()
        guard !started else { return }

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self else { ready.signal(); return }
            let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerSetDeviceMatching(mgr, [
                kIOHIDVendorIDKey as String: Self.vendorID,
                kIOHIDProductIDKey as String: Self.accessPID,
            ] as CFDictionary)
            let me = Unmanaged.passUnretained(self).toOpaque()
            IOHIDManagerRegisterDeviceMatchingCallback(mgr, { ctx, _, _, device in
                guard let ctx else { return }
                Unmanaged<AccessControllerPortService>.fromOpaque(ctx).takeUnretainedValue().handleAttached(device)
            }, me)
            IOHIDManagerRegisterDeviceRemovalCallback(mgr, { ctx, _, _, device in
                guard let ctx else { return }
                Unmanaged<AccessControllerPortService>.fromOpaque(ctx).takeUnretainedValue().handleDetached(device)
            }, me)
            let loop = CFRunLoopGetCurrent()!
            IOHIDManagerScheduleWithRunLoop(mgr, loop, CFRunLoopMode.defaultMode.rawValue)
            let result = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            self.lock.lock()
            self.manager = mgr
            self.readerRunLoop = loop
            self.lock.unlock()
            Self.log.notice("reader open: \(result, privacy: .public)")
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "com.inputconfig.accessports"
        thread.qualityOfService = .userInteractive
        readerThread = thread
        thread.start()
        ready.wait()
    }

    // MARK: - Device lifecycle (reader thread)

    private func handleAttached(_ device: IOHIDDevice) {
        guard let loc = (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber)?.uint64Value else { return }
        lock.lock()
        let existingPad = pads[loc]
        lock.unlock()
        if let existingPad {
            if let existing = existingPad.device, CFEqual(existing, device) { return }
            tearDown(location: loc)   // a Bluetooth reconnect reusing the location
        }
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            Self.log.error("open failed at loc=\(loc, privacy: .public)")
            return
        }
        let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? "?"
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: reportBufferSize)
        buf.initialize(repeating: 0, count: reportBufferSize)
        let pad = Pad(device: device, identity: SonyPadIdentity.of(device: device), buffer: buf,
                      overUSB: transport.uppercased().contains("USB"))
        lock.lock()
        pads[loc] = pad
        deviceToLocation[ObjectIdentifier(device)] = loc
        let runLoop = readerRunLoop
        lock.unlock()
        IOHIDDeviceRegisterInputReportCallback(device, buf, reportBufferSize, accessPortCallback,
                                               UnsafeMutableRawPointer(bitPattern: UInt(loc)))
        if let runLoop { IOHIDDeviceScheduleWithRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue) }
        Self.log.notice("attached loc=\(loc, privacy: .public) over \(transport, privacy: .public)")
        if pad.overUSB {
            profileQueue.async { [weak self] in self?.readProfiles(pad) }
        } else {
            profileQueue.async { [weak self] in
                guard let self else { return }
                self.wakeBluetooth(pad, device: device)
                // Still on the compact report half a second later: once more.
                Thread.sleep(forTimeInterval: 0.5)
                self.lock.lock()
                let woke = pad.reportsSeen > 0
                self.lock.unlock()
                if !woke {
                    Self.log.notice("Bluetooth pad still compact after the wake; sending it again")
                    self.wakeBluetooth(pad, device: device)
                }
            }
        }
    }

    /// Over Bluetooth a Sony pad streams its compact report until a host
    /// reads a feature report. The DualSense answers 0x05 (calibration);
    /// the Access controller has no 0x05 (dualsense-ts feature table), so
    /// the reads SDL and the kernel make for every pad go first: 0x09 (MAC,
    /// 20 bytes) and 0x20 (firmware, 64 bytes), then 0x05 (41 bytes). Each
    /// result is logged so the first Bluetooth attach records which one
    /// this controller honors.
    private func wakeBluetooth(_ pad: Pad, device: IOHIDDevice) {
        for (id, size) in [(CFIndex(0x09), 20), (0x20, 64), (0x05, 41)] {
            var buf = [UInt8](repeating: 0, count: size)
            var len: CFIndex = CFIndex(size)
            let got = buf.withUnsafeMutableBufferPointer { p in
                HIDRead.getReport(device, kIOHIDReportTypeFeature, id, p.baseAddress!, &len)
            }
            if got == kIOReturnSuccess {
                Self.log.notice("wake: feature \(String(format: "0x%02X", id), privacy: .public) ok len \(len, privacy: .public)")
            } else {
                Self.log.notice("wake: feature \(String(format: "0x%02X", id), privacy: .public) refused \(String(format: "0x%08X", UInt32(bitPattern: got)), privacy: .public)")
            }
        }
    }

    private func handleDetached(_ device: IOHIDDevice) {
        lock.lock()
        let cached = deviceToLocation.removeValue(forKey: ObjectIdentifier(device))
        let stored = cached.flatMap { pads[$0]?.device }
        lock.unlock()
        guard let loc = cached, let stored, CFEqual(stored, device) else { return }
        tearDown(location: loc)
    }

    private func tearDown(location loc: UInt64) {
        lock.lock()
        let pad = pads.removeValue(forKey: loc)
        #if DEBUG
        syntheticLocations.remove(loc)
        #endif
        let runLoop = readerRunLoop
        lock.unlock()
        guard let pad else { return }
        if let device = pad.device {
            if let runLoop { IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue) }
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        pad.buffer.deallocate()
    }

    // MARK: - Profiles (reader thread, USB only)

    /// Reads the three stored profiles through feature reports 0x60 and
    /// 0x61: a one-byte command 0x10 + (N - 1), then 18 reads of 56 bytes
    /// each. Nothing is written to the controller's storage.
    private func readProfiles(_ pad: Pad) {
        guard let device = pad.device else { return }
        var found: [Int: Profile] = [:]
        var blobs: [Int: [UInt8]] = [:]
        // 0 is the controller's built-in base profile (command 0x0F): read
        // for the record, and as the check that the slot number is honored.
        for number in 0...3 {
            guard let bytes = readProfileBytes(device, number: number) else { continue }
            blobs[number] = bytes
            guard let profile = Self.parseProfile(bytes, number: number) else {
                Self.log.notice("profile \(number, privacy: .public): unexpected data, first byte \(bytes.first ?? 0, privacy: .public)")
                continue
            }
            found[number] = profile
            let sockets = (1...10).compactMap { s -> String? in
                guard let code = profile.buttonActions[s], let name = Profile.actionName(code) else { return nil }
                return "\(s <= 8 ? "socket \(s)" : s == 9 ? "center" : "stick press")=\(name)"
            }.joined(separator: " ")
            let ports = (1...4).compactMap { p -> String? in
                if let code = profile.portActions[p] { return "E\(p)=\(Profile.actionName(code) ?? String(code))" }
                if let s = profile.stickAssignments[p] { return "E\(p)=\(s == 1 ? "left stick" : "right stick")" }
                return nil
            }.joined(separator: " ")
            Self.log.notice("profile \(number, privacy: .public) \"\(profile.name, privacy: .public)\": \(sockets, privacy: .public) \(ports, privacy: .public)")
        }
        if let a = blobs[1], let b = blobs[2], let c = blobs[3] {
            Self.log.notice("profiles 1 to 3 \(a == b && b == c ? "are byte-identical copies" : "differ", privacy: .public); base profile \(blobs[0].map { $0 == a ? "matches profile 1" : "differs from profile 1" } ?? "not read", privacy: .public)")
        }
        lock.lock()
        pad.profiles = found
        lock.unlock()
    }

    private func readProfileBytes(_ device: IOHIDDevice, number: Int) -> [UInt8]? {
        // Whatever an earlier exchange left in the data register is read
        // off first: the register's third byte counts the chunks still to
        // come, and a command sent while it is not zero answers with the
        // leftovers of the last one.
        drain(device)
        // The command, with the report ID first, as every other report the
        // app sends (the echo check on 2026-10-18 proved the framing). A
        // controller that answers kIOReturnNotResponding (seen three times
        // in the 10/18 log) gets the same 64 bytes again after 20 ms, never
        // a differently framed buffer.
        let command = Self.readCommand(number: number)
        let expectedEcho = command[1]
        for attempt in 0..<3 {
            let sent = command.withUnsafeBufferPointer { p in
                HIDWrite.setReport(device, kIOHIDReportTypeFeature, Self.commandReport, p.baseAddress!, CFIndex(p.count))
            }
            guard sent == kIOReturnSuccess else {
                Self.log.notice("profile \(number, privacy: .public): command refused \(String(format: "0x%08X", UInt32(bitPattern: sent)), privacy: .public) (attempt \(attempt + 1, privacy: .public))")
                if sent == kIOReturnNotResponding { Thread.sleep(forTimeInterval: 0.02); continue }
                return nil
            }
            var out: [UInt8] = []
            var remaining: [Int] = []
            var echoed = true
            for _ in 0..<Self.profileChunks {
                var buf = [UInt8](repeating: 0, count: 64)
                var len: CFIndex = 64
                let got = buf.withUnsafeMutableBufferPointer { p in
                    HIDRead.getReport(device, kIOHIDReportTypeFeature, Self.dataReport, p.baseAddress!, &len)
                }
                guard got == kIOReturnSuccess, len >= 4 + Self.chunkSize else { echoed = false; break }
                // [0] report ID, [1] the command echoed, [2] chunks left, [4...] data.
                if buf[1] != expectedEcho { echoed = false; break }
                remaining.append(Int(buf[2]))
                out += buf[4..<(4 + Self.chunkSize)]
            }
            if echoed, out.count >= Self.profileSize {
                let uuid = out[84..<100].map { String(format: "%02x", $0) }.joined()
                let stamp = (948..<956).reversed().reduce(UInt64(0)) { $0 << 8 | UInt64(out[$1]) }
                Self.log.notice("profile \(number, privacy: .public) read: chunks left \(remaining.first ?? -1, privacy: .public) to \(remaining.last ?? -1, privacy: .public), uuid \(uuid, privacy: .public), saved \(stamp, privacy: .public)")
                return Array(out.prefix(Self.profileSize))
            }
            // Sent but not echoed: the register was busy; drain and try once more.
            drain(device)
        }
        return nil
    }

    /// The 64 byte feature report 0x60 that asks for a stored profile:
    /// 0x0F for the built in base profile, 0x10 + N - 1 for slot N.
    static func readCommand(number: Int) -> [UInt8] {
        var command = [UInt8](repeating: 0, count: 64)
        command[0] = UInt8(commandReport)
        command[1] = UInt8(number == 0 ? 0x0F : 0x10 + max(1, min(3, number)) - 1)
        return command
    }

    static func parseProfile(_ bytes: [UInt8], number: Int) -> Profile? {
        guard bytes.count >= profileSize, bytes[0] == 0x02 else { return nil }
        var name = ""
        for i in 0..<40 {
            let unit = UInt16(bytes[4 + 2 * i]) | UInt16(bytes[5 + 2 * i]) << 8
            if unit == 0 { break }
            if let scalar = Unicode.Scalar(unit) { name.unicodeScalars.append(scalar) }
        }
        var profile = Profile(number: number, name: name)
        profile.bytes = Array(bytes.prefix(profileSize))
        for b in 0..<10 {
            let code = Int(bytes[100 + b * 5]), second = Int(bytes[101 + b * 5])
            if code != 0 { profile.buttonActions[b + 1] = code }
            if second != 0 { profile.secondaryActions[b + 1] = second }
        }
        let toggleBits = UInt16(bytes[150]) | UInt16(bytes[151]) << 8
        for bit in 0..<14 where toggleBits & (1 << bit) != 0 { profile.toggles.insert(bit + 1) }
        for p in 0..<5 {
            let base = 152 + p * 45
            switch bytes[base] {
            case 0x01:
                profile.ports[p] = .stick(assignment: Int(bytes[base + 1]))
                if p == 0 { profile.orientation = Int(bytes[base + 2] & 0x03) }
            case 0x02, 0x03: profile.ports[p] = .button(code: Int(bytes[base + 2]), secondary: Int(bytes[base + 3]), analog: bytes[base] == 0x02)
            default: profile.ports[p] = Profile.PortConfig.empty
            }
        }
        return profile
    }

    /// The 956 bytes to store for a profile: the bytes it was read from
    /// with the edited fields written over them. The name, the button
    /// table's first action, the toggle bits and each port's type and
    /// setup change; a port that changes kind starts from a clean record.
    static func encode(_ profile: Profile) -> [UInt8] {
        var out = profile.bytes.map { Array($0.prefix(profileSize)) } ?? [UInt8](repeating: 0, count: profileSize)
        if out.count < profileSize { out += [UInt8](repeating: 0, count: profileSize - out.count) }
        out[0] = 0x02
        for i in 4..<84 { out[i] = 0 }
        for (i, unit) in profile.name.utf16.prefix(39).enumerated() {
            out[4 + 2 * i] = UInt8(unit & 0xFF); out[5 + 2 * i] = UInt8(unit >> 8)
        }
        for b in 0..<10 {
            out[100 + b * 5] = UInt8(clamping: profile.buttonActions[b + 1] ?? 0)
            out[101 + b * 5] = UInt8(clamping: profile.secondaryActions[b + 1] ?? 0)
        }
        var toggleBits: UInt16 = 0
        for slot in profile.toggles where (1...14).contains(slot) { toggleBits |= 1 << UInt16(slot - 1) }
        out[150] = UInt8(toggleBits & 0xFF); out[151] = UInt8(toggleBits >> 8)
        for port in 0..<5 {
            let base = 152 + port * 45
            let wasType = out[base]
            switch profile.ports[port] ?? Profile.PortConfig.empty {
            case .empty:
                for i in 0..<45 { out[base + i] = 0 }
            case .stick(let assignment):
                if wasType != 0x01 { for i in 0..<45 { out[base + i] = 0 } }
                out[base] = 0x01
                out[base + 1] = UInt8(clamping: assignment)
                out[base + 2] = UInt8(clamping: profile.orientation & 0x03)
            case .button(let code, let secondary, let analog):
                if wasType != 0x02 && wasType != 0x03 { for i in 0..<45 { out[base + i] = 0 } }
                out[base] = analog ? 0x02 : 0x03
                out[base + 2] = UInt8(clamping: code)
                out[base + 3] = UInt8(clamping: secondary)
            }
        }
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        for i in 0..<8 { out[948 + i] = UInt8((now >> (8 * UInt64(i))) & 0xFF) }
        return out
    }

    /// Standard CRC-32 (zlib), as the controller checks a written profile.
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            c ^= UInt32(b)
            for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        }
        return c ^ 0xFFFF_FFFF
    }

    /// The eighteen feature reports that store a profile, report ID first:
    /// 0x08 + N, the chunk index, 56 bytes of the profile; the last chunk
    /// carries the CRC of all 956 bytes, little-endian, at payload offset 6.
    static func writePackets(number: Int, bytes: [UInt8]) -> [[UInt8]] {
        // Slot 0 is the built in base profile: 0x08 is an opcode no source
        // names, so nothing is ever built for it.
        guard (1...3).contains(number) else { return [] }
        let crc = crc32(Array(bytes.prefix(profileSize)))
        return (0..<profileChunks).map { i in
            var packet = [UInt8](repeating: 0, count: 64)
            packet[0] = UInt8(commandReport)
            packet[1] = UInt8(0x08 + number)
            packet[2] = UInt8(i)
            for j in 0..<chunkSize where i * chunkSize + j < profileSize { packet[3 + j] = bytes[i * chunkSize + j] }
            if i == profileChunks - 1 {
                for k in 0..<4 { packet[1 + 6 + k] = UInt8((crc >> (8 * UInt32(k))) & 0xFF) }
            }
            return packet
        }
    }

    /// The Access controller's output report for its lights (titania
    /// access_output_msg, 32 bytes; dualsense-ts tested every LED): [1]
    /// the mutator (0x04 light ring, 0x10 player indicator, 0x01 profile
    /// LEDs, 0x08 reset to firmware default), [5] the player pattern 0 to
    /// 4, [6..8] R G B, [12] LED flags (bit 0 profile LEDs on, bit 4 status
    /// LED enable), [13] the profile LED mode, [23] the status LED. Byte 9
    /// bit 3 (override profile) is never set: titania says it bricks
    /// profiles. Over Bluetooth: 0x31, [1] 0x02, [2] the mutator, [3] scope
    /// 0x04, the USB payload from [4] (player at 6, RGB 7 to 9, flags 13,
    /// mode 14, status 24), CRC seed 0xA2 at 74; a dismiss frame
    /// ([2] 0xFF, [3] 0xFF) goes once after connect. Built for the bench and
    /// a hardware try; nothing sends it yet.
    static func ledReport(rgb: (r: UInt8, g: UInt8, b: UInt8)?, player: UInt8, profileLEDMode: UInt8? = nil,
                          statusLED: Bool = false, bluetooth: Bool = false) -> [UInt8] {
        var usb = [UInt8](repeating: 0, count: 32)
        usb[0] = 0x02
        var mutator: UInt8 = 0
        if let rgb { mutator |= 0x04; usb[6] = rgb.r; usb[7] = rgb.g; usb[8] = rgb.b }
        if player > 0 { mutator |= 0x10; usb[5] = min(4, player) }
        if let mode = profileLEDMode { mutator |= 0x01; usb[12] |= 0x01; usb[13] = min(3, mode) }
        if statusLED { mutator |= 0x01; usb[12] |= 0x10; usb[23] = 1 }
        usb[1] = mutator
        guard bluetooth else { return usb }
        var bt = [UInt8](repeating: 0, count: 78)
        bt[0] = 0x31; bt[1] = 0x02; bt[2] = mutator; bt[3] = 0x04
        // The USB payload one byte later: player at 6, RGB 7 to 9, flags
        // 13, mode 14, status 24 (dualsense-ts Bluetooth output section).
        for i in 4..<32 { bt[i + 1] = usb[i] }
        SonyBluetoothCRC.sealOutputReport(&bt)
        return bt
    }

    /// The Bluetooth frame sent once after connect before any LED write.
    static func ledDismissReport() -> [UInt8] {
        var bt = [UInt8](repeating: 0, count: 78)
        bt[0] = 0x31; bt[1] = 0x02; bt[2] = 0xFF; bt[3] = 0xFF
        SonyBluetoothCRC.sealOutputReport(&bt)
        return bt
    }

    /// The feature report that makes profile N the active one, the same
    /// thing the controller's Profile button does.
    static func setActiveCommand(_ number: Int) -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: 64)
        packet[0] = UInt8(commandReport)
        packet[1] = 0x05
        packet[2] = UInt8(max(1, min(3, number)))
        return packet
    }

    /// Reads the data register until it reports nothing left, so the next
    /// command answers for itself.
    private func drain(_ device: IOHIDDevice) {
        for _ in 0..<40 {
            var buf = [UInt8](repeating: 0, count: 64)
            var len: CFIndex = 64
            let got = buf.withUnsafeMutableBufferPointer { p in
                HIDRead.getReport(device, kIOHIDReportTypeFeature, Self.dataReport, p.baseAddress!, &len)
            }
            guard got == kIOReturnSuccess, len >= 3, buf[2] != 0 else { return }
        }
    }

    // MARK: - Profile commands (any thread; the work runs on profileQueue)

    /// Makes profile 1...3 the active one on the controller behind a slot.
    func setActiveProfile(_ number: Int, for identity: SonyPadIdentity?, accessSlotCount: Int,
                          completion: @escaping (Result<Void, ProfileError>) -> Void) {
        lock.lock()
        let pad = pad(for: identity, accessSlotCount: accessSlotCount)
        lock.unlock()
        guard let pad else { completion(.failure(.notConnected)); return }
        guard pad.overUSB else { completion(.failure(.bluetooth)); return }
        guard !pad.switchingDisabled else { completion(.failure(.switchingDisabled)); return }
        guard let device = pad.device else {
            // A synthetic pad has no controller to answer: it switches as the real one would.
            lock.lock(); pad.activeProfile = number; lock.unlock()
            completion(.success(())); return
        }
        profileQueue.async {
            let packet = Self.setActiveCommand(number)
            let sent = packet.withUnsafeBufferPointer { p in
                HIDWrite.setReport(device, kIOHIDReportTypeFeature, Self.commandReport, p.baseAddress!, CFIndex(p.count))
            }
            Self.log.notice("set active profile \(number, privacy: .public): \(sent == kIOReturnSuccess ? "sent" : "refused", privacy: .public)")
            completion(sent == kIOReturnSuccess ? .success(()) : .failure(.refused(String(format: "0x%08X", UInt32(bitPattern: sent)))))
        }
    }

    /// Stores a profile in its slot on the controller behind a slot, then
    /// reads it back and keeps it only when the controller stored exactly
    /// what was sent.
    func writeProfile(_ profile: Profile, for identity: SonyPadIdentity?, accessSlotCount: Int,
                      completion: @escaping (Result<Void, ProfileError>) -> Void) {
        lock.lock()
        let pad = pad(for: identity, accessSlotCount: accessSlotCount)
        lock.unlock()
        guard let pad else { completion(.failure(.notConnected)); return }
        guard pad.overUSB, (1...3).contains(profile.number) else { completion(.failure(.bluetooth)); return }
        guard let device = pad.device else {
            // A synthetic pad stores exactly what was sent, as a verified write does.
            let bytes = Self.encode(profile)
            guard let parsed = Self.parseProfile(bytes, number: profile.number) else { completion(.failure(.verifyFailed)); return }
            lock.lock(); pad.profiles[profile.number] = parsed; lock.unlock()
            completion(.success(())); return
        }
        profileQueue.async { [weak self] in
            guard let self else { return }
            let bytes = Self.encode(profile)
            self.drain(device)
            for packet in Self.writePackets(number: profile.number, bytes: bytes) {
                let sent = packet.withUnsafeBufferPointer { p in
                    HIDWrite.setReport(device, kIOHIDReportTypeFeature, Self.commandReport, p.baseAddress!, CFIndex(p.count))
                }
                guard sent == kIOReturnSuccess else {
                    Self.log.error("profile \(profile.number, privacy: .public) write refused at chunk \(packet[2], privacy: .public)")
                    completion(.failure(.refused(String(format: "0x%08X", UInt32(bitPattern: sent)))))
                    return
                }
            }
            // The controller stores the profile after the last chunk: wait
            // for its register to report nothing left, then read it back.
            Thread.sleep(forTimeInterval: 0.05)
            self.drain(device)
            guard let stored = self.readProfileBytes(device, number: profile.number) else {
                completion(.failure(.verifyFailed)); return
            }
            // The timestamp and anything the controller rewrites aside, the
            // edited fields must match.
            let same = stored[0..<948] == bytes[0..<948]
            if same, let parsed = Self.parseProfile(stored, number: profile.number) {
                self.lock.lock()
                pad.profiles[profile.number] = parsed
                self.lock.unlock()
                Self.log.notice("profile \(profile.number, privacy: .public) stored and read back")
                completion(.success(()))
            } else {
                Self.log.error("profile \(profile.number, privacy: .public) read back differs")
                self.readProfiles(pad)
                completion(.failure(.verifyFailed))
            }
        }
    }

    /// Reads the stored profiles again.
    func refreshProfiles(for identity: SonyPadIdentity?, accessSlotCount: Int) {
        lock.lock()
        let pad = pad(for: identity, accessSlotCount: accessSlotCount)
        lock.unlock()
        guard let pad, pad.overUSB else { return }
        profileQueue.async { [weak self] in self?.readProfiles(pad) }
    }

    // MARK: - Decoding (pure)

    /// Everything one input report says, in the slot's own terms.
    struct Decoded: Equatable {
        /// Buttons down: 40...51 the controller's own, 56...59 a button in a port.
        var buttons: Set<Int> = []
        /// 6 and 7 the stick itself, then a port's axes by what it holds.
        var axes: [Int: Float] = [:]
        /// What each port holds; an empty port is absent.
        var ports: [Int: PortDevice] = [:]
        /// 1...3, or 0 before the controller has said.
        var activeProfile = 0
        /// The PS5 setting that locks the Profile button (bit 3 of the
        /// profile byte); the 0x05 command is refused while it is on.
        var switchingDisabled = false
        var battery: Battery?
    }

    /// Decodes a Bluetooth (0x31, 78 bytes) or USB (0x01, 64 bytes) input
    /// report; nil for any other report, such as the 10-byte one a
    /// Bluetooth controller sends before it is woken.
    static func decode(_ bytes: [UInt8]) -> Decoded? {
        guard let first = bytes.first,
              let format = formats.first(where: { $0.length == bytes.count && first == $0.id }) else { return nil }
        // A Bluetooth frame carries its own CRC (seed 0xA1 over bytes 0 to
        // 73); the kernel and SDL drop a frame that fails it, and so does
        // this, or a damaged frame reads as socket presses and port changes.
        if first == 0x31, !SonyBluetoothCRC.inputReportIsWhole(bytes) { return nil }
        func raw(_ btByte: Int) -> UInt8? {
            let i = btByte + format.shift
            return i >= 0 && i < bytes.count ? bytes[i] : nil
        }
        func centered(_ v: UInt8) -> Float { max(-1, min(1, (Float(v) - 128) / 127.5)) }
        var d = Decoded()
        for (i, byte) in buttonBytes.enumerated() {
            guard var v = raw(byte) else { continue }
            // Bits 4 to 7 of the second byte are reserved (titania
            // playstation_access_raw_button), never buttons 52 to 55.
            if i == 1 { v &= 0x0F }
            for bit in 0..<8 where v & (1 << bit) != 0 { d.buttons.insert(buttonBase + i * 8 + bit) }
        }
        if let x = raw(stickBytes.x), let y = raw(stickBytes.y) {
            d.axes[stickAxes.x] = centered(x)
            d.axes[stickAxes.y] = centered(y)
        }
        if let p = raw(profileByte) {
            d.activeProfile = Int(p & 0x07)
            d.switchingDisabled = p & 0x08 != 0
        }
        if let b = raw(batteryByte) { d.battery = Battery(byte: b) }
        for port in 1...portCount {
            let axes = portAxes(port), at = portBytes(port)
            guard let typeValue = raw(typeByte(forPort: port)), let x = raw(at.x), let y = raw(at.y),
                  let device = PortDevice(nibble: typeNibble(typeValue, port: port)) else { continue }
            d.ports[port] = device
            switch device {
            case .stick:
                d.axes[axes.x] = centered(x)
                d.axes[axes.y] = centered(y)
            case .trigger:
                d.axes[axes.x] = Float(x) / 255
            case .button:
                if x != 0 || y != 0 { d.buttons.insert(portButtonBase + port - 1) }
            case .invalidPlug:
                break
            }
        }
        return d
    }

    // MARK: - Reports (reader thread)

    fileprivate func handleReport(location loc: UInt64, report: UnsafePointer<UInt8>, length: Int) {
        let bytes = Array(UnsafeBufferPointer(start: report, count: length))
        #if DEBUG
        if HIDCapture.target != nil, HIDCapture.matches(vendorID: Self.vendorID, productID: Self.accessPID) {
            HIDCapture.log("\(HIDCapture.elapsedMs) in \(String(format: "%02x", bytes.first ?? 0)) \(HIDCapture.hex(bytes))")
        }
        #endif
        lock.lock()
        defer { lock.unlock() }
        guard let pad = pads[loc] else { return }
        pad.rawReportsSeen += 1
        if !pad.firstReportLogged {
            pad.firstReportLogged = true
            Self.log.notice("first report id \(String(format: "0x%02X", bytes.first ?? 0), privacy: .public) length \(length, privacy: .public)")
        }
        guard let decoded = Self.decode(bytes) else {
            if pad.rawReportsSeen == 250, pad.reportsSeen == 0 {
                Self.log.notice("still compact after 250 reports (id \(String(format: "0x%02X", bytes.first ?? 0), privacy: .public), length \(length, privacy: .public))")
            }
            return
        }
        defer { pad.reportsSeen += 1 }
        if !decoded.buttons.isEmpty || decoded.axes.values.contains(where: { abs($0) > 0.33 }) {
            ControllerPowerService.shared.noteAccessActivity()
        }

        for index in decoded.buttons where pad.seenButtons.insert(index).inserted {
            Self.log.notice("\(Self.buttonLabel(index), privacy: .public) first pressed")
        }
        if decoded.activeProfile != pad.activeProfile {
            pad.activeProfile = decoded.activeProfile
            Self.log.notice("active profile \(decoded.activeProfile, privacy: .public)")
        }
        if decoded.switchingDisabled != pad.switchingDisabled {
            pad.switchingDisabled = decoded.switchingDisabled
            Self.log.notice("profile switching \(decoded.switchingDisabled ? "off" : "on", privacy: .public)")
        }
        pad.battery = decoded.battery

        // A port's type is published only once `portSettleReports` reports
        // in a row agree, so a half seated plug does not flap the drawing
        // and the extras row at report rate.
        let now = ProcessInfo.processInfo.systemUptime
        for port in 1...Self.portCount {
            let candidate = decoded.ports[port]
            var entry = pad.portCandidates[port] ?? (device: nil, count: 0)
            if entry.device == candidate { entry.count += 1 } else { entry = (candidate, 1) }
            pad.portCandidates[port] = entry
            guard entry.count >= Self.portSettleReports, pad.portDevices[port] != candidate else { continue }
            if let device = candidate { pad.portDevices[port] = device } else { pad.portDevices.removeValue(forKey: port) }
            if now - (pad.portLoggedAt[port] ?? 0) >= 1 {
                pad.portLoggedAt[port] = now
                if let device = candidate {
                    Self.log.notice("E\(port, privacy: .public) holds a \(device, privacy: .public)")
                } else {
                    Self.log.notice("E\(port, privacy: .public) is empty")
                }
            }
        }
        // Axes and buttons of a port follow the published type, not the
        // report's nibble of the moment.
        var axes = decoded.axes
        var buttons = decoded.buttons
        for port in 1...Self.portCount where pad.portDevices[port] == nil {
            let a = Self.portAxes(port)
            axes.removeValue(forKey: a.x); axes.removeValue(forKey: a.y)
            buttons.remove(Self.portButtonBase + port - 1)
        }
        pad.axes = axes
        pad.buttons = Dictionary(uniqueKeysWithValues: buttons.map { ($0, Float(1)) })
    }

    // MARK: - Synthetic pads (DEBUG)

    #if DEBUG
    /// Locations of pads installed by hand, never by IOKit.
    private var syntheticLocations: Set<UInt64> = []

    /// True while a synthetic pad is registered; GameControllerService
    /// merges a fake Access slot from this reader only then.
    var debugHasSyntheticPad: Bool {
        lock.lock(); defer { lock.unlock() }
        return !syntheticLocations.isEmpty
    }

    /// Registers a pad with no IOHIDDevice at `location`, so
    /// `pad(for: nil, accessSlotCount: 1)` finds it and `debugInject`
    /// can feed it reports through `handleReport`. The identity carries
    /// only the location. Reinstalling at the same location replaces.
    func debugInstallSyntheticPad(location: UInt64, overUSB: Bool, profiles: [Int: Profile] = [:]) {
        lock.lock()
        let existing = pads[location]
        lock.unlock()
        if existing != nil { tearDown(location: location) }
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: reportBufferSize)
        buf.initialize(repeating: 0, count: reportBufferSize)
        var identity = SonyPadIdentity()
        identity.locationID = location
        let pad = Pad(device: nil, identity: identity, buffer: buf, overUSB: overUSB)
        pad.profiles = profiles
        lock.lock()
        pads[location] = pad
        syntheticLocations.insert(location)
        lock.unlock()
        Self.log.notice("synthetic pad installed at loc=\(location, privacy: .public) over \(overUSB ? "USB" : "Bluetooth", privacy: .public)")
    }

    /// Feeds one raw input report (report ID first) to the pad at
    /// `location` through the same `handleReport` the IOKit callback
    /// uses, on the reader thread's run loop when it is running.
    func debugInject(location: UInt64, bytes: [UInt8]) {
        lock.lock()
        let runLoop = readerRunLoop
        lock.unlock()
        let deliver = { [self] in
            bytes.withUnsafeBufferPointer { p in
                guard let base = p.baseAddress else { return }
                handleReport(location: location, report: base, length: p.count)
            }
        }
        if let runLoop {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, deliver)
            CFRunLoopWakeUp(runLoop)
        } else {
            deliver()
        }
    }

    /// The same, delivered before returning, for the bench.
    func debugInjectNow(location: UInt64, bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { p in
            guard let base = p.baseAddress else { return }
            handleReport(location: location, report: base, length: p.count)
        }
    }

    /// Removes every synthetic pad; real pads are untouched.
    func debugRemoveSyntheticPads() {
        lock.lock()
        let locations = syntheticLocations
        syntheticLocations = []
        lock.unlock()
        for location in locations { tearDown(location: location) }
    }
    #endif

    // MARK: - Lookup (any thread)

    /// The Access controller behind a slot. `accessSlotCount` is how many
    /// Access controllers GameController lists: with one on each side they
    /// are the same controller even when the identities do not line up.
    private func pad(for identity: SonyPadIdentity?, accessSlotCount: Int) -> Pad? {
        if let identity, let pad = pads.values.first(where: { $0.identity.matches(identity) }) { return pad }
        guard accessSlotCount == 1, pads.count == 1 else { return nil }
        return pads.values.first
    }

    /// The stick and port axes of the Access controller in a slot.
    func axes(for identity: SonyPadIdentity?, accessSlotCount: Int) -> [Int: Float] {
        lock.lock(); defer { lock.unlock() }
        return pad(for: identity, accessSlotCount: accessSlotCount)?.axes ?? [:]
    }

    /// The controller's own buttons that are down right now.
    func buttons(for identity: SonyPadIdentity?, accessSlotCount: Int) -> [Int: Float] {
        lock.lock(); defer { lock.unlock() }
        return pad(for: identity, accessSlotCount: accessSlotCount)?.buttons ?? [:]
    }

    /// Every button pressed so far this connection, for the extras row.
    func seenButtons(for identity: SonyPadIdentity?, accessSlotCount: Int) -> [Int] {
        lock.lock(); defer { lock.unlock() }
        return pad(for: identity, accessSlotCount: accessSlotCount)?.seenButtons.sorted() ?? []
    }

    /// What is plugged into each expansion port (1...4); an empty port is absent.
    func portDevices(for identity: SonyPadIdentity?, accessSlotCount: Int) -> [Int: PortDevice] {
        lock.lock(); defer { lock.unlock() }
        return pad(for: identity, accessSlotCount: accessSlotCount)?.portDevices ?? [:]
    }

    /// The profile the controller has active (1...3), with what it maps
    /// when the controller is on USB and answered for it.
    func activeProfile(for identity: SonyPadIdentity?, accessSlotCount: Int) -> (number: Int, profile: Profile?) {
        lock.lock(); defer { lock.unlock() }
        guard let pad = pad(for: identity, accessSlotCount: accessSlotCount) else { return (0, nil) }
        return (pad.activeProfile, pad.profiles[pad.activeProfile])
    }

    /// Everything known about the controller's profiles: which is active,
    /// the three stored ones when read (USB), and whether this connection
    /// can read and change them.
    struct ProfileState: Equatable {
        var connected = false
        var overUSB = false
        var active = 0
        /// The controller refuses the 0x05 command while the PS5 setting
        /// that locks the Profile button is on.
        var switchingDisabled = false
        var profiles: [Int: Profile] = [:]
    }

    func profileState(for identity: SonyPadIdentity?, accessSlotCount: Int) -> ProfileState {
        lock.lock(); defer { lock.unlock() }
        guard let pad = pad(for: identity, accessSlotCount: accessSlotCount) else { return ProfileState() }
        return ProfileState(connected: true, overUSB: pad.overUSB, active: pad.activeProfile,
                            switchingDisabled: pad.switchingDisabled, profiles: pad.profiles)
    }

    /// The battery as the controller's own report says, for a slot whose
    /// GameController battery object is missing.
    func battery(for identity: SonyPadIdentity?, accessSlotCount: Int) -> Battery? {
        lock.lock(); defer { lock.unlock() }
        return pad(for: identity, accessSlotCount: accessSlotCount)?.battery
    }
}

// MARK: - C callback bridge

private func accessPortCallback(context: UnsafeMutableRawPointer?, result: IOReturn,
                                sender: UnsafeMutableRawPointer?, type: IOHIDReportType,
                                reportID: UInt32, report: UnsafeMutablePointer<UInt8>,
                                reportLength: CFIndex) {
    guard result == kIOReturnSuccess, let context else { return }
    AccessControllerPortService.shared.handleReport(location: UInt64(UInt(bitPattern: context)),
                                                    report: report, length: Int(reportLength))
}
