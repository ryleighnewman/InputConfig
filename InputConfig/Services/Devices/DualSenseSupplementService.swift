import Foundation
import IOKit
import IOKit.hid

/// Reads DualSense / DualSense Edge controllers directly via IOKit HID
/// alongside Apple's GameController framework, parsing the Edge's
/// exclusive buttons (paddles, FN, mute) that Apple's GC framework
/// does not expose. Standard buttons keep flowing through GCController;
/// the Edge extras come from here and are merged into the slot's
/// ControllerState by GameControllerService.
///
/// Follows the same pattern as `SteamControllerService`: a plain
/// `final class` declared `@unchecked Sendable`, with all mutable
/// state guarded by a single `NSLock`. Avoids the @MainActor /
/// nonisolated mismatch that surfaces under Swift 6 strict
/// concurrency when a C HID callback tries to reach back into an
/// @MainActor singleton.
final class DualSenseSupplementService: @unchecked Sendable {

    static let shared = DualSenseSupplementService()

    /// Called, off the main thread, when a pad's supplement buttons change.
    /// Set once at startup by GameControllerService; read under `lock`.
    var onStateChange: (() -> Void)?

    /// Sony VID + the two DualSense PIDs we care about (base + Edge).
    /// The PlayStation Access controller (0x0E5F) is deliberately absent: its
    /// input report is not the DualSense layout, so reading byte 10/11 as
    /// buttons[2] would publish garbage as PS / mute / paddle presses.
    private static let vendorID: Int32 = 0x054C
    private static let dualSensePIDs: Set<Int32> = [0x0CE6, 0x0DF2]
    /// DualShock 4 v1, v2 and the DS4 USB wireless adapter. Only the PS
    /// button is read from these (bit 0 of buttons[2]; the rest of that byte
    /// is touchpad click plus a frame counter), for the same reason as the
    /// DualSense: newer macOS can swallow the Home press for Game Mode.
    private static let dualShock4PIDs: Set<Int32> = [0x05C4, 0x09CC, 0x0BA0]

    /// Logical button slots the supplement publishes. These match the
    /// indices `cacheExtraButtons` reserves so the binding pipeline
    /// can pick them up without remapping.
    ///   15 = Microphone / Mute
    ///   16 = Left Paddle
    ///   17 = Right Paddle
    ///   20 = FN1 (left function)
    ///   21 = FN2 (right function)
    enum SupplementButton: Int {
        case mute = 15
        case leftPaddle = 16
        case rightPaddle = 17
        case leftFunction = 20
        case rightFunction = 21
    }

    /// Toggle that controls whether we NSLog raw report bytes for
    /// debugging. Off in shipping builds. The byte offsets for the
    /// buttons we DO support (PS, Mute) are already locked in below.
    nonisolated(unsafe) static var logRawBytes: Bool = false

    // MARK: - State (lock-guarded)

    private let lock = NSLock()
    private var manager: IOHIDManager?
    private var liveDevices: [UInt64: IOHIDDevice] = [:]
    /// Location ID per device object, cached at attach. Removal resolves the
    /// location from here instead of re-reading the property from the
    /// departing device, which IOKit often fails; the old early return on
    /// that failure leaked the handle and left paddles latched down.
    private var deviceToLocation: [ObjectIdentifier: UInt64] = [:]
    /// Product ID per location, so the report parser knows DS4 from DualSense.
    private var productIDs: [UInt64: Int32] = [:]
    /// Which physical pad each location is, for per-slot lookups.
    private var identities: [UInt64: SonyPadIdentity] = [:]
    private var reportBuffers: [UInt64: UnsafeMutablePointer<UInt8>] = [:]
    private var supplementalState: [UInt64: [Int: Float]] = [:]
    private var lastLoggedByte11: [UInt64: UInt8] = [:]
    private var reportCounter: [UInt64: Int] = [:]
    /// Timestamp of the last streamed (callback-delivered) input report per
    /// device. The poll timer stands down while the stream is alive.
    private var lastStreamAt: [UInt64: TimeInterval] = [:]
    /// GET_REPORT poll timer, running while any DualSense is attached.
    private var pollTimer: DispatchSourceTimer?
    /// Location-report keys whose first poll result has been logged.
    private var pollHealthLogged: Set<String> = []
    private var pollTickCount: Int = 0
    private let pollQueue = DispatchQueue(label: "com.inputconfig.dsedgepoll")
    /// Last-seen bytes 8-49 EXCLUDING known counter slots so we log
    /// any change that could be the Edge's paddle/FN bits without
    /// also logging every counter increment 250×/sec.
    private var lastSignificantBytes: [UInt64: [UInt8]] = [:]
    private let reportBufferSize = 78

    private init() {}

    // MARK: - Lifecycle

    /// Open the DualSense raw HID device in-process, non-seize, alongside
    /// gamecontrollerd. This is the only route to the Edge's extra buttons
    /// on modern macOS: Apple's GameController profile for the DualSense
    /// Edge exposes NO paddle / FN / mute buttons (verified against the
    /// live profile dump - standard buttons + touchpad + Home only, and
    /// the leftPaddleButton-style KVC keys are absent).
    ///
    /// Both transports deliver input reports to this in-process reader,
    /// sandbox included - verified live over Bluetooth (0x31 reports,
    /// FN presses decoded) and historically over USB (PS/mute). A BT
    /// connection can occasionally wedge into delivering no reports
    /// (power-cycling the controller clears it); the GET_REPORT poll
    /// below covers that case, so the extras keep working regardless.
    ///
    /// The old conflict that parked this service (starving the separate
    /// touchpad helper's feed) is gone with the helper: GameController's
    /// touchpadPrimary bridge is the touch source.
    func start() {
        let enableLegacyOpen = true
        NSLog("[DualSenseSupplement] start() - opening DualSense raw HID (USB extras reader)")

        if enableLegacyOpen {
            lock.lock()
            let alreadyStarted = (manager != nil)
            lock.unlock()
            guard !alreadyStarted else { return }

            let mgr = IOHIDManagerCreate(kCFAllocatorDefault,
                                         IOOptionBits(kIOHIDOptionsTypeNone))
            var matches: [[String: Any]] = []
            for pid in Self.dualSensePIDs.union(Self.dualShock4PIDs) {
                matches.append([
                    kIOHIDVendorIDKey as String: Self.vendorID,
                    kIOHIDProductIDKey as String: pid
                ])
            }
            IOHIDManagerSetDeviceMatchingMultiple(mgr, matches as CFArray)
            // Common modes, so attach/detach and reports keep arriving while
            // a menu is open or a window is being resized (both run the main
            // run loop in tracking mode, which the default mode excludes).
            IOHIDManagerScheduleWithRunLoop(mgr,
                                            CFRunLoopGetMain(),
                                            CFRunLoopMode.commonModes.rawValue)
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            IOHIDManagerRegisterDeviceMatchingCallback(mgr, { context, _, _, device in
                guard let context else { return }
                let svc = Unmanaged<DualSenseSupplementService>.fromOpaque(context).takeUnretainedValue()
                svc.handleAttached(device)
            }, selfPtr)
            IOHIDManagerRegisterDeviceRemovalCallback(mgr, { context, _, _, device in
                guard let context else { return }
                let svc = Unmanaged<DualSenseSupplementService>.fromOpaque(context).takeUnretainedValue()
                svc.handleDetached(device)
            }, selfPtr)
            IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            lock.lock()
            manager = mgr
            lock.unlock()
        }

        NSLog("[DualSenseSupplement] manager opened, watching Sony VID 0x054C")
    }

    func stop() {
        lock.lock()
        let devices = liveDevices
        let buffers = reportBuffers
        let mgr = manager
        liveDevices.removeAll()
        deviceToLocation.removeAll()
        productIDs.removeAll()
        identities.removeAll()
        reportBuffers.removeAll()
        supplementalState.removeAll()
        lastLoggedByte11.removeAll()
        lastStreamAt.removeAll()
        let poll = pollTimer
        pollTimer = nil
        manager = nil
        lock.unlock()
        poll?.cancel()

        for (_, device) in devices {
            IOHIDDeviceUnscheduleFromRunLoop(device,
                                             CFRunLoopGetMain(),
                                             CFRunLoopMode.commonModes.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        for (_, buf) in buffers { buf.deallocate() }
        if let mgr {
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerUnscheduleFromRunLoop(mgr,
                                              CFRunLoopGetMain(),
                                              CFRunLoopMode.commonModes.rawValue)
        }
    }

    // MARK: - Device lifecycle (called from IOKit callbacks - any thread)

    private func handleAttached(_ device: IOHIDDevice) {
        guard let locRef = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber else { return }
        let location = locRef.uint64Value
        let pid = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber)?.int32Value ?? 0

        lock.lock()
        let existing = liveDevices[location]
        lock.unlock()
        if let existing {
            // The same device object announced twice: nothing to do.
            if CFEqual(existing, device) { return }
            // A Bluetooth reconnect can arrive before the old connection's
            // removal and reuse its location ID. The stored handle is the
            // dead connection, so close it and take the new one; the late
            // removal for the old object is then ignored (see handleDetached).
            NSLog("[DualSenseSupplement] replacing stale device at loc=0x%llX", location)
            tearDown(location: location)
        }

        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            NSLog("[DualSenseSupplement] open failed for location 0x%llX: %d", location, openResult)
            // A stale device may have been torn down above; with nothing
            // left the poll must stop, not tick with no pad.
            stopPollingIfIdle()
            return
        }

        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: reportBufferSize)
        buf.initialize(repeating: 0, count: reportBufferSize)

        let identity = SonyPadIdentity.of(device: device)
        lock.lock()
        liveDevices[location] = device
        deviceToLocation[ObjectIdentifier(device)] = location
        productIDs[location] = pid
        identities[location] = identity
        reportBuffers[location] = buf
        supplementalState[location] = [:]
        lock.unlock()

        // Use the location ID directly as the callback context. Safe
        // because the ID is just a UInt64 packed into the pointer
        // bits; no object lifetime to manage.
        let locationCookie = UnsafeMutableRawPointer(bitPattern: UInt(location))
        IOHIDDeviceRegisterInputReportCallback(
            device,
            buf,
            reportBufferSize,
            dualSenseSupplementCallback,
            locationCookie
        )
        // The report stream (about 250 a second on USB) is taken only
        // while something reads the pads; see setPollingWanted.
        lock.lock()
        let takeStream = pollingWanted
        if takeStream { scheduledStreams.insert(location) }
        lock.unlock()
        if takeStream {
            IOHIDDeviceScheduleWithRunLoop(device,
                                           CFRunLoopGetMain(),
                                           CFRunLoopMode.commonModes.rawValue)
        }

        let productName = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "?"
        NSLog("[DualSenseSupplement] attached %@ (loc=0x%llX)", productName, location)
        startPollingIfNeeded()
        // Note: we previously tried sending feature / output reports
        // to "unlock" the DualSense Edge's paddle/FN bits in the
        // input report. Empirically verified that no candidate
        // command (0x80, 0x09, etc.) changed the report layout - the
        // Edge keeps internally remapping paddles to other buttons
        // regardless. Sony's actual extended-profile unlock is
        // undocumented. Leaving this comment as a breadcrumb for
        // future investigation.
    }

    private func handleDetached(_ device: IOHIDDevice) {
        // Resolve the location from the table cached at attach rather than
        // re-reading it from the departing device (that read often fails).
        lock.lock()
        let cached = deviceToLocation.removeValue(forKey: ObjectIdentifier(device))
        lock.unlock()
        guard let location = cached
                ?? (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber)?.uint64Value
        else { return }

        // Only tear down when the device leaving is the one stored for this
        // location. After a Bluetooth reconnect the stored device is the new
        // connection, and the old connection's late removal must not close it.
        lock.lock()
        let stored = liveDevices[location]
        lock.unlock()
        guard let stored, CFEqual(stored, device) else {
            NSLog("[DualSenseSupplement] ignoring removal of a replaced device (loc=0x%llX)", location)
            return
        }
        tearDown(location: location)
        stopPollingIfIdle()
        NSLog("[DualSenseSupplement] detached (loc=0x%llX)", location)
    }

    /// Close one location's device and drop all of its state, including the
    /// button snapshot, so a paddle held at the moment of removal does not
    /// stay pressed.
    private func tearDown(location: UInt64) {
        lock.lock()
        let dev = liveDevices.removeValue(forKey: location)
        let buf = reportBuffers.removeValue(forKey: location)
        if let dev { deviceToLocation.removeValue(forKey: ObjectIdentifier(dev)) }
        productIDs.removeValue(forKey: location)
        identities.removeValue(forKey: location)
        supplementalState.removeValue(forKey: location)
        lastLoggedByte11.removeValue(forKey: location)
        lastSignificantBytes.removeValue(forKey: location)
        reportCounter.removeValue(forKey: location)
        lastStreamAt.removeValue(forKey: location)
        scheduledStreams.remove(location)
        lock.unlock()

        if let dev {
            IOHIDDeviceUnscheduleFromRunLoop(dev,
                                             CFRunLoopGetMain(),
                                             CFRunLoopMode.commonModes.rawValue)
            IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        // Safe to free now: the device is unscheduled and closed, so no
        // report callback can write into this buffer any more.
        if let buf { buf.deallocate() }
    }

    // MARK: - Report dispatch (called from C callback)

    /// Parse one input report. DualSense base USB report (ID 0x01) layout:
    ///   byte 0:  report ID
    ///   bytes 1-6: sticks + triggers
    ///   byte 7:  counter
    ///   byte 8:  D-pad + face buttons
    ///   byte 9:  shoulders + Create + Options + L3 + R3
    ///   byte 10: PS, Touchpad, Mute (bit 0=PS, bit 1=touchpad, bit 2=mute)
    /// The DualSense Edge extends the report with paddle/FN bits; we
    /// log byte-11 changes when `logRawBytes` is on so the user can
    /// identify the correct offsets empirically.
    func handleReport(locationID: UInt64,
                      reportPointer: UnsafePointer<UInt8>,
                      length: Int) {
        guard length >= 8 else { return }

        // Mark the stream alive so the GET_REPORT poll stands down for
        // this device (streamed reports are lower-latency than polling).
        lock.lock()
        let firstStream = (lastStreamAt[locationID] == nil)
        lastStreamAt[locationID] = CFAbsoluteTimeGetCurrent()
        lock.unlock()
        if firstStream {
            NSLog("[DualSenseSupplement] stream ALIVE (loc=0x%llX) first report id=0x%02X len=%d",
                  locationID, reportPointer[0], length)
        }

        // Diagnostics. Capture button-candidate bytes 8-15 and
        // bytes 30-49 (where community-documented Edge profile bytes
        // tend to live). EXPLICITLY EXCLUDE:
        //   byte 7  - report counter
        //   byte 12 - secondary counter
        //   bytes 16-29 - motion sensor (gyro/accel/touchpad fingers)
        //                 change every report and would otherwise
        //                 drive the change detector to fire 250x/sec.
        if Self.logRawBytes && length >= 50 {
            // Bytes that are KNOWN counters / sensors and must be
            // excluded from the change detector. Build current state
            // from button-candidate bytes only.
            //   byte 8  = D-pad + face (standard)
            //   byte 9  = shoulders + menu (standard)
            //   byte 10 = PS / touchpad / mute (standard)
            //   byte 11 = candidate for Edge extras
            //   bytes 32-49 = deeper area where some firmwares
            //                 expose Edge profile bits
            // Excluded: 7 (counter), 12 (counter), 13-15 (timer),
            //           16-29 (motion sensors), 30-31 (counters).
            var current: [UInt8] = []
            for i in 8...11 { current.append(reportPointer[i]) }
            for i in 32..<min(50, length) { current.append(reportPointer[i]) }

            lock.lock()
            let prev = lastSignificantBytes[locationID]
            let changed = prev != current
            if changed { lastSignificantBytes[locationID] = current }
            reportCounter[locationID, default: 0] += 1
            let count = reportCounter[locationID] ?? 0
            let isHeartbeat = (count % 500) == 1   // every ~2s at 250 Hz
            lock.unlock()

            if changed || isHeartbeat {
                var winA: [String] = []
                for i in 8...11 { winA.append(String(format: "%02X", reportPointer[i])) }
                var winB: [String] = []
                for i in 32..<min(50, length) { winB.append(String(format: "%02X", reportPointer[i])) }
                let tag = changed ? "CHANGE" : "HEARTBEAT"
                NSLog("[DualSenseSupplement] %@ b[8..11]= %@ | b[32..%d]= %@",
                      tag, winA.joined(separator: " "), min(50, length), winB.joined(separator: " "))
            }
        }

        // buttons[2] of the report payload carries PS/Home (bit 0),
        // touchpad press (bit 1), Mute (bit 2), and on the DualSense
        // Edge the four extra hardware buttons in the high nibble.
        // The IOHID input buffer includes the report ID at [0], so:
        //   USB report 0x01: payload starts at [1], buttons[2] = [10].
        //     (PS at [10] bit 0 was verified over 16+ press/release
        //     transitions in a live USB stream.)
        //   BT report 0x31: ID at [0], sequence tag at [1], payload at
        //     [2], buttons[2] = [11]. Verified live over Bluetooth:
        //     an Edge FN press flips [11] bit 4 while the sticks sit at
        //     [2..5] and the d-pad hat idles as 0x08 at [9]. BT reports
        //     DO reach this second non-seize reader alongside the
        //     system daemon; a connection can wedge into delivering
        //     nothing (power-cycling the controller clears it), which
        //     is where the old "Bluetooth gives zero reports" belief
        //     came from.
        lock.lock()
        let isDS4 = Self.dualShock4PIDs.contains(productIDs[locationID] ?? 0)
        lock.unlock()
        guard let b2 = Self.buttons2(reportPointer, length: length, isDS4: isDS4) else { return }
        applyButtons2(b2, locationID: locationID)
    }

    /// Pull buttons[2] out of one input report (report ID at [0]), or nil
    /// for a report this reader does not decode.
    ///
    /// DualSense: USB 0x01 -> [10], BT 0x31 -> [11] (see above).
    /// DualShock 4: the payload is three bytes shorter at the front (no
    /// separate trigger bytes before the buttons), so buttons[2] is [7] in
    /// USB report 0x01 (also what a DS4 sends over Bluetooth before it is
    /// switched to full reports) and [9] in BT report 0x11, whose payload
    /// starts two bytes later. Only bit 0 (PS) is kept: bit 1 is the
    /// touchpad click GameController already reports, and bits 2-7 are a
    /// frame counter that would read as mute and paddle presses.
    ///
    /// A Bluetooth report (0x31, 0x11) counts only at its full 78 bytes with
    /// a good CRC, as SDL and the kernel check it: a damaged or short one
    /// read as PS, FN or paddle presses that never happened.
    private static func buttons2(_ r: UnsafePointer<UInt8>, length: Int, isDS4: Bool) -> UInt8? {
        if isDS4 {
            if r[0] == 0x01 && length > 7 { return r[7] & 0x01 }
            if r[0] == 0x11 && bluetoothReportIsWhole(r, length: length) { return r[9] & 0x01 }
            return nil
        }
        if r[0] == 0x01 && length > 10 { return r[10] }
        if r[0] == 0x31 && bluetoothReportIsWhole(r, length: length) { return r[11] }
        return nil
    }

    /// A Sony Bluetooth input report: 78 bytes, the last four a CRC-32 of
    /// the input header byte 0xA1 followed by the first 74.
    static func bluetoothReportIsWhole(_ r: UnsafePointer<UInt8>, length: Int) -> Bool {
        guard length == 78 else { return false }
        var crc: UInt32 = 0xFFFF_FFFF
        func add(_ byte: UInt8) { crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] }
        add(0xA1)
        for i in 0..<74 { add(r[i]) }
        crc ^= 0xFFFF_FFFF
        let sent = UInt32(r[74]) | UInt32(r[75]) << 8 | UInt32(r[76]) << 16 | UInt32(r[77]) << 24
        return crc == sent
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1 != 0) ? (c >> 1) ^ 0xEDB8_8320 : c >> 1 }
        return c
    }

    /// Decode one buttons[2] byte into the supplemental button snapshot.
    private func applyButtons2(_ b2: UInt8, locationID: UInt64) {
        let psDown   = (b2 & 0x01) != 0
        let muteDown = (b2 & 0x04) != 0
        // DualSense Edge extras, as SDL_hidapi_ps5.c reads them (same
        // byte as PS and mute, high nibble):
        //   bit 4 = left function (FN), bit 5 = right function (FN),
        //   bit 6 = left paddle,        bit 7 = right paddle.
        let fnLeft   = (b2 & 0x10) != 0
        let fnRight  = (b2 & 0x20) != 0
        let lPaddle  = (b2 & 0x40) != 0
        let rPaddle  = (b2 & 0x80) != 0

        var snapshot: [Int: Float] = [:]
        // Index 10 = Home/PS - merging here lets us fire the binding
        // even when Apple's GameController framework swallows the PS
        // event for system-level Game Mode handling on macOS 26+.
        snapshot[10]                                       = psDown   ? 1.0 : 0.0
        snapshot[SupplementButton.mute.rawValue]           = muteDown ? 1.0 : 0.0
        snapshot[SupplementButton.leftFunction.rawValue]   = fnLeft   ? 1.0 : 0.0
        snapshot[SupplementButton.rightFunction.rawValue]  = fnRight  ? 1.0 : 0.0
        snapshot[SupplementButton.leftPaddle.rawValue]     = lPaddle  ? 1.0 : 0.0
        snapshot[SupplementButton.rightPaddle.rawValue]    = rPaddle  ? 1.0 : 0.0

        lock.lock()
        // Only while the pad is still attached: a poll started before a
        // detach finished afterwards and wrote state back for a gone pad,
        // which read as a PS button held on the next pad.
        guard liveDevices[locationID] != nil else { lock.unlock(); return }
        let changed = (supplementalState[locationID] != snapshot)
        supplementalState[locationID] = snapshot
        let notify = changed ? onStateChange : nil
        lock.unlock()
        // GameController never reports these buttons, so this is the only
        // thing that can wake a resting engine for a quick paddle, FN, mute
        // or PS tap. Only on a change, never per report.
        notify?()

        // Change-gated diagnostic. Fires only on press/release edges of
        // the supplement buttons (a handful of events per session), so
        // it stays silent during the 130-250 Hz report stream while
        // giving `log stream` visibility into exactly which raw bits
        // the controller sends - the tool that finally mapped the Edge.
        if changed && b2 != 0 {
            NSLog("[DualSenseSupplement] buttons2=0x%02X ps=%d mute=%d fnL=%d fnR=%d padL=%d padR=%d",
                  b2, psDown ? 1 : 0, muteDown ? 1 : 0, fnLeft ? 1 : 0,
                  fnRight ? 1 : 0, lPaddle ? 1 : 0, rPaddle ? 1 : 0)
        }
    }

    // MARK: - GET_REPORT polling (the Bluetooth path)

    /// Poll the current input report with a synchronous GET_REPORT device
    /// request. Over Bluetooth the sandbox delivers NO streamed input
    /// reports to this app (or to its sandboxed helper) - but device
    /// requests go through: SetReport drives the light bar over BT today,
    /// and GetReport was verified live to return fresh 78-byte 0x31
    /// snapshots (the embedded counter advances between polls). 30 Hz gives
    /// worst-case ~33 ms latency on paddle presses, in line with a 30 Hz
    /// UI poll frame. The timer stands down per-device whenever streamed
    /// reports are flowing (USB), so the poll only pays for itself when it
    /// is the only source.
    /// The report stream and the poll run only while something reads the
    /// pads: a running preset ("engine"), or the editor, the visualizer or
    /// a scan ("live"). Idle, a wired pad woke the main thread about 250
    /// times a second, and a Bluetooth DualSense was asked for a report 30
    /// times a second, for buttons nothing read. DualSense and DualShock 4
    /// go through the same gate, so the editor and Scan see a DS4's PS
    /// press exactly as a running preset does.
    private var pollingWanted: Bool { !pollReasons.isEmpty }
    /// Read and written under lock.
    private var pollReasons: Set<String> = []
    func setPollingWanted(_ wanted: Bool, reason: String) {
        lock.lock()
        let before = pollingWanted
        if wanted { pollReasons.insert(reason) } else { pollReasons.remove(reason) }
        let now = pollingWanted
        guard now != before else { lock.unlock(); return }
        var changed = false
        if !now {
            // Nothing reads the pads now, so a button held at this moment
            // must not stay "pressed" and fire again on the next start.
            for loc in liveDevices.keys where !(supplementalState[loc] ?? [:]).isEmpty {
                supplementalState[loc] = [:]
                changed = true
            }
        }
        var toSchedule: [IOHIDDevice] = []
        var toUnschedule: [IOHIDDevice] = []
        for (loc, device) in liveDevices {
            if now, !scheduledStreams.contains(loc) {
                scheduledStreams.insert(loc); toSchedule.append(device)
            } else if !now, scheduledStreams.contains(loc) {
                scheduledStreams.remove(loc); toUnschedule.append(device)
            }
        }
        let notify = changed ? onStateChange : nil
        lock.unlock()
        for device in toSchedule {
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        }
        for device in toUnschedule {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        }
        notify?()
        if now { startPollingIfNeeded() } else { stopPollingIfIdle() }
    }
    /// Locations whose report stream is scheduled on the run loop. Read
    /// under lock.
    private var scheduledStreams: Set<UInt64> = []
    /// Live devices the poll should read. Call locked.
    private func pollableLocked() -> [UInt64: IOHIDDevice] {
        pollingWanted ? liveDevices : [:]
    }

    private func startPollingIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard pollTimer == nil, !pollableLocked().isEmpty else { return }
        let t = DispatchSource.makeTimerSource(queue: pollQueue)
        t.schedule(deadline: .now() + .milliseconds(33),
                   repeating: .milliseconds(33),
                   leeway: .milliseconds(8))
        t.setEventHandler { [weak self] in self?.pollTick() }
        pollTimer = t
        t.resume()
        NSLog("[DualSenseSupplement] GET_REPORT poll started (30 Hz)")
    }

    private func stopPollingIfIdle() {
        lock.lock()
        defer { lock.unlock() }
        guard pollableLocked().isEmpty, let t = pollTimer else { return }
        pollTimer = nil
        t.cancel()
        NSLog("[DualSenseSupplement] GET_REPORT poll stopped")
    }

    private func pollTick() {
        lock.lock()
        let targets = pollableLocked().filter { (loc, _) in
            // Stand down while streamed reports are arriving for this device.
            (CFAbsoluteTimeGetCurrent() - (lastStreamAt[loc] ?? 0)) > 1.0
        }
        pollTickCount += 1
        let tick = pollTickCount
        let liveCount = liveDevices.count
        let streamStamps = lastStreamAt.count
        lock.unlock()
        if tick == 1 || (Self.logRawBytes && tick % 150 == 0) {
            NSLog("[DualSenseSupplement] tick=%d live=%d targets=%d streamStamped=%d",
                  tick, liveCount, targets.count, streamStamps)
        }
        guard !targets.isEmpty else { return }

        var buf = [UInt8](repeating: 0, count: 96)
        for (location, device) in targets {
            lock.lock()
            let isDS4 = Self.dualShock4PIDs.contains(productIDs[location] ?? 0)
            lock.unlock()
            // Try the full BT report first, then the USB/simple report. A
            // DS4 is only asked for its simple report: its full BT report is
            // switched on by a feature request this reader never sends.
            let reportIDs: [CFIndex] = isDS4 ? [0x01] : [0x31, 0x01]
            for rid in reportIDs {
                var len: CFIndex = buf.count
                let gr = IOHIDDeviceGetReport(device, kIOHIDReportTypeInput, rid, &buf, &len)
                // One-shot health line so a silent poll is distinguishable
                // from a working poll with no buttons pressed.
                lock.lock()
                let firstForKey = !pollHealthLogged.contains("\(location)-\(rid)")
                if firstForKey { pollHealthLogged.insert("\(location)-\(rid)") }
                lock.unlock()
                if firstForKey {
                    NSLog("[DualSenseSupplement] poll id=0x%02lX -> %@ len=%ld", rid,
                          gr == kIOReturnSuccess ? "ok" : String(format: "0x%08X", UInt32(bitPattern: gr)), len)
                }
                guard gr == kIOReturnSuccess, len > 7 else { continue }
                // GetReport buffers carry the same layout as the streamed
                // callback buffer: report ID at [0].
                let parsed: UInt8? = buf.withUnsafeBufferPointer { p in
                    p.baseAddress.flatMap { Self.buttons2($0, length: min(Int(len), p.count), isDS4: isDS4) }
                }
                guard let b2 = parsed else { continue }
                applyButtons2(b2, locationID: location)
                break
            }
        }
    }

    // MARK: - Lookup helpers

    /// Supplemental buttons for one GameController slot's pad.
    ///
    /// `identity` is the slot's pad (nil when GameController does not say
    /// which HID device backs it) and `sonySlotCount` is how many Sony slots
    /// GameController has. The pad's own state is returned when a raw device
    /// matches it. Without a match the old merged state is returned only when
    /// there is exactly one Sony pad on both sides, so with two pads one
    /// pad's paddles can never fire bindings on the other's slot.
    func supplementalButtons(for identity: SonyPadIdentity?, sonySlotCount: Int) -> [Int: Float] {
        lock.lock()
        defer { lock.unlock() }
        if let identity,
           let loc = identities.first(where: { $0.value.matches(identity) })?.key {
            var out: [Int: Float] = [:]
            for (idx, val) in supplementalState[loc] ?? [:] where val > 0.5 { out[idx] = val }
            return out
        }
        // With one Sony pad in GameController, the merged state is that
        // pad's, as in 1.5. Counting raw devices too returned nothing when a
        // DS4 dongle with no pad (or a DS4 not yet listed) was also attached.
        guard sonySlotCount <= 1 else { return [:] }
        var merged: [Int: Float] = [:]
        for (_, buttons) in supplementalState {
            for (idx, val) in buttons where val > 0.5 {
                merged[idx] = val
            }
        }
        return merged
    }
}

// MARK: - C callback bridge

private func dualSenseSupplementCallback(context: UnsafeMutableRawPointer?,
                                         result: IOReturn,
                                         sender: UnsafeMutableRawPointer?,
                                         type: IOHIDReportType,
                                         reportID: UInt32,
                                         report: UnsafeMutablePointer<UInt8>,
                                         reportLength: CFIndex) {
    guard result == kIOReturnSuccess, let context else { return }
    let location = UInt64(UInt(bitPattern: context))
    DualSenseSupplementService.shared.handleReport(
        locationID: location,
        reportPointer: report,
        length: Int(reportLength)
    )
}
