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

    /// Sony VID + the two DualSense PIDs we care about (base + Edge).
    private static let vendorID: Int32 = 0x054C
    private static let dualSensePIDs: Set<Int32> = [0x0CE6, 0x0DF2]

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
    private var reportBuffers: [UInt64: UnsafeMutablePointer<UInt8>] = [:]
    private var supplementalState: [UInt64: [Int: Float]] = [:]
    private var lastLoggedByte11: [UInt64: UInt8] = [:]
    private var reportCounter: [UInt64: Int] = [:]
    /// Last-seen bytes 8-49 EXCLUDING known counter slots so we log
    /// any change that could be the Edge's paddle/FN bits without
    /// also logging every counter increment 250×/sec.
    private var lastSignificantBytes: [UInt64: [UInt8]] = [:]
    private let reportBufferSize = 78

    private init() {}

    // MARK: - Lifecycle

    /// Defer to TouchpadHelper as the canonical reader of DualSense
    /// raw HID. When TouchpadHelper retains the device (which it does
    /// whenever the live visualizer is on screen or a touchpad-using
    /// preset is active), our parallel IOHIDDevice open appears to
    /// starve the helper of input reports on some macOS versions -
    /// the user sees the touchpad swipe trail go dead. To avoid that
    /// regression we skip starting our own device handle entirely;
    /// the proper long-term fix is to push PS/mute parsing INTO
    /// TouchpadHelper and consume the bits via TouchpadService.
    func start() {
        // PS/mute bridging is being moved into TouchpadHelper so a
        // single process holds the DualSense device handle - having
        // both us AND the helper open the same device in non-seize
        // mode caused the touchpad swipe trail to die for the user.
        // While that move is in flight, leave this service dormant.
        // `supplementalState` stays empty and `anySupplementalButtons()`
        // returns []; the merge in GameControllerService.readControllerState
        // is a no-op when the dictionary is empty.
        let enableLegacyOpen = false
        NSLog("[DualSenseSupplement] start() - device open deferred; TouchpadHelper now owns DualSense raw HID")

        if enableLegacyOpen {
            lock.lock()
            let alreadyStarted = (manager != nil)
            lock.unlock()
            guard !alreadyStarted else { return }

            let mgr = IOHIDManagerCreate(kCFAllocatorDefault,
                                         IOOptionBits(kIOHIDOptionsTypeNone))
            var matches: [[String: Any]] = []
            for pid in Self.dualSensePIDs {
                matches.append([
                    kIOHIDVendorIDKey as String: Self.vendorID,
                    kIOHIDProductIDKey as String: pid
                ])
            }
            IOHIDManagerSetDeviceMatchingMultiple(mgr, matches as CFArray)
            IOHIDManagerScheduleWithRunLoop(mgr,
                                            CFRunLoopGetMain(),
                                            CFRunLoopMode.defaultMode.rawValue)
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
        reportBuffers.removeAll()
        supplementalState.removeAll()
        lastLoggedByte11.removeAll()
        manager = nil
        lock.unlock()

        for (_, device) in devices {
            IOHIDDeviceUnscheduleFromRunLoop(device,
                                             CFRunLoopGetMain(),
                                             CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        for (_, buf) in buffers { buf.deallocate() }
        if let mgr {
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerUnscheduleFromRunLoop(mgr,
                                              CFRunLoopGetMain(),
                                              CFRunLoopMode.defaultMode.rawValue)
        }
    }

    // MARK: - Device lifecycle (called from IOKit callbacks - any thread)

    private func handleAttached(_ device: IOHIDDevice) {
        guard let locRef = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber else { return }
        let location = locRef.uint64Value

        lock.lock()
        let already = (liveDevices[location] != nil)
        lock.unlock()
        guard !already else { return }

        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            NSLog("[DualSenseSupplement] open failed for location 0x%llX: %d", location, openResult)
            return
        }

        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: reportBufferSize)
        buf.initialize(repeating: 0, count: reportBufferSize)

        lock.lock()
        liveDevices[location] = device
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
        IOHIDDeviceScheduleWithRunLoop(device,
                                       CFRunLoopGetMain(),
                                       CFRunLoopMode.defaultMode.rawValue)

        let productName = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "?"
        NSLog("[DualSenseSupplement] attached %@ (loc=0x%llX)", productName, location)
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
        guard let locRef = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber else { return }
        let location = locRef.uint64Value

        lock.lock()
        let dev = liveDevices.removeValue(forKey: location)
        let buf = reportBuffers.removeValue(forKey: location)
        supplementalState.removeValue(forKey: location)
        lastLoggedByte11.removeValue(forKey: location)
        lock.unlock()

        if let dev {
            IOHIDDeviceUnscheduleFromRunLoop(dev,
                                             CFRunLoopGetMain(),
                                             CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if let buf { buf.deallocate() }
        NSLog("[DualSenseSupplement] detached (loc=0x%llX)", location)
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
        guard length >= 11 else { return }

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

        // Only handle the standard USB report ID. Bluetooth wraps in
        // 0x31 with an offset header and we don't parse that here.
        guard reportPointer[0] == 0x01 else { return }

        // Byte 10 carries PS/Home, Touchpad press, and Mute as three
        // bits. The PS bit was empirically verified at bit 0 by
        // observing 16+ press/release transitions in the user's USB
        // stream. Mute is documented at bit 2 in the standard
        // DualSense layout.
        let byte10 = reportPointer[10]
        let psDown = (byte10 & 0x01) != 0
        let muteDown = (byte10 & 0x04) != 0

        // DualSense Edge paddles + FN buttons are NOT present in the
        // standard USB input report - the controller's firmware
        // internally remaps them to face buttons / shoulders before
        // transmission. Empirically verified by pressing each Edge
        // accessory and observing zero byte changes anywhere in the
        // report. Unlocking the Edge's extended profile mode would
        // require an undocumented feature-report command we don't
        // have. Users should configure paddle mapping via the Edge's
        // built-in profile editor on PS5 instead.
        var snapshot: [Int: Float] = [:]
        // Index 10 = Home/PS - merging here lets us fire the binding
        // even when Apple's GameController framework swallows the PS
        // event for system-level Game Mode handling on macOS 26+.
        snapshot[10]                              = psDown   ? 1.0 : 0.0
        snapshot[SupplementButton.mute.rawValue]  = muteDown ? 1.0 : 0.0

        lock.lock()
        supplementalState[locationID] = snapshot
        lock.unlock()
    }

    // MARK: - Lookup helpers

    /// Returns the union of supplemental button states across all
    /// attached DualSenses. Acceptable when there's only one (the
    /// common case).
    func anySupplementalButtons() -> [Int: Float] {
        lock.lock()
        let snapshot = supplementalState
        lock.unlock()
        var merged: [Int: Float] = [:]
        for (_, buttons) in snapshot {
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
