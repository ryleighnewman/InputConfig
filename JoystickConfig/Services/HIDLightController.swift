import Foundation
import GameController
import IOKit
import IOKit.hid

/// Controls DualSense / DualShock 4 light bars by invoking a helper tool
/// that runs as a separate process, kills the gamecontrolleragentd to release
/// the HID device, and sends the output report matching HIDAPI/SDL2 format.
final class HIDLightController: @unchecked Sendable {
    nonisolated(unsafe) static let shared = HIDLightController()

    private let queue = DispatchQueue(label: "com.joystickconfig.hidlight")
    /// Last (r, g, b, brightness) we actually sent to the helper. Used
    /// to skip redundant spawns when the requested color matches what
    /// the controller already has - the connect-time retry pattern in
    /// GameControllerService used to spawn the helper 3 times per
    /// controller per plug-in, even when nothing changed.
    private var lastWritten: (r: UInt8, g: UInt8, b: UInt8, br: UInt8)?
    private let lastWrittenLock = NSLock()

    /// Single-flight guard. Only one helper process may run at a time.
    /// Spawning several concurrently makes them fight over seizing the
    /// controller and leaves the light in a stuck/wrong state (the
    /// "breaks after a few window clicks" bug). Rapid requests while a
    /// helper is running are coalesced into `pendingColor`, and only the
    /// most recent one runs when the current helper exits. Accessed only
    /// on `queue`, so no extra lock is needed.
    private var helperRunning = false
    private var pendingColor: (r: UInt8, g: UInt8, b: UInt8, br: UInt8)?

    private init() {}

    /// Set light color with brightness. Brightness: 0=off, 1=dim, 2=bright.
    ///
    /// Pass `force: true` to bypass the dedupe and re-send even if the
    /// color is unchanged. Used when macOS has reset the light behind our
    /// back (e.g. gamecontrolleragentd repaints the player color when the
    /// app loses focus), so we need to re-assert the same color.
    func setLightColor(red: UInt8, green: UInt8, blue: UInt8, brightness: UInt8 = 2, force: Bool = false) {
        // Skip the spawn entirely when the requested state matches the
        // last successful write. Saves three subprocess spawns per
        // controller-connect retry burst.
        if !force {
            lastWrittenLock.lock()
            let same = lastWritten.map {
                $0.r == red && $0.g == green && $0.b == blue && $0.br == brightness
            } ?? false
            lastWrittenLock.unlock()
            guard !same else { return }
        } else {
            // Clear the cache so the dedupe doesn't suppress this write.
            lastWrittenLock.lock()
            lastWritten = nil
            lastWrittenLock.unlock()
        }

        queue.async { [weak self] in
            guard let self = self else { return }
            // Single-flight: if a helper is already running, just remember
            // the latest requested color and let the running helper's
            // completion pick it up. This collapses a burst of focus-change
            // re-asserts into at most one follow-up spawn.
            if self.helperRunning {
                self.pendingColor = (red, green, blue, brightness)
                return
            }
            self.helperRunning = true
            self.runHelper(red: red, green: green, blue: blue, brightness: brightness)
        }
    }

    private func runHelper(red: UInt8, green: UInt8, blue: UInt8, brightness: UInt8) {
        guard let helperURL = helperPath() else {
            #if DEBUG
            print("[HIDLight] LightHelper not found in bundle")
            #endif
            queue.async { [weak self] in self?.helperFinished(success: false) }
            return
        }

        let task = Process()
        task.executableURL = helperURL
        // "shared" mode: the helper opens the controller non-exclusively
        // and writes the LED report WITHOUT killing gamecontrolleragentd.
        // Confirmed to reach the DualSense LED with no flicker and no
        // controller-input interruption, so we use it for every write -
        // initial sets, preset flashes, and focus-change re-asserts alike.
        // The helper's legacy killall+seize path stays in place as a
        // fallback but is no longer invoked from here.
        task.arguments = [String(red), String(green), String(blue), String(brightness), "shared"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        // Async exit notification so we don't block this serial queue
        // for the helper's ~1.2 s lifetime. Previously `waitUntilExit`
        // would head-of-line block every subsequent light change,
        // causing visible color-cycle stutter.
        task.terminationHandler = { [weak self] proc in
            guard let self = self else { return }
            let ok = proc.terminationStatus == 0
            if ok {
                self.lastWrittenLock.lock()
                self.lastWritten = (red, green, blue, brightness)
                self.lastWrittenLock.unlock()
            }
            // Release the single-flight slot and run any coalesced
            // follow-up. Hop back onto `queue` so helperRunning /
            // pendingColor stay single-threaded.
            self.queue.async { self.helperFinished(success: ok) }
        }

        do {
            try task.run()
            // Don't `waitUntilExit()`. The serial queue stays free to
            // process the next color change; the terminationHandler
            // releases the single-flight slot when the helper exits.
        } catch {
            #if DEBUG
            print("[HIDLight] Helper launch failed: \(error)")
            #endif
            queue.async { [weak self] in self?.helperFinished(success: false) }
        }
    }

    /// Called on `queue` when a helper process exits (or fails to launch).
    /// Frees the single-flight slot and immediately spawns the most recent
    /// coalesced color, if any.
    private func helperFinished(success: Bool) {
        helperRunning = false
        guard let next = pendingColor else { return }
        pendingColor = nil
        helperRunning = true
        runHelper(red: next.r, green: next.g, blue: next.b, brightness: next.br)
    }

    private func helperPath() -> URL? {
        // App bundle MacOS directory
        if let bundlePath = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("LightHelper") {
            if FileManager.default.isExecutableFile(atPath: bundlePath.path) {
                return bundlePath
            }
        }
        // Resources
        if let resourcePath = Bundle.main.url(forResource: "LightHelper", withExtension: nil) {
            return resourcePath
        }
        // Development fallback
        let devPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("LightHelper/LightHelper")
        if FileManager.default.isExecutableFile(atPath: devPath.path) {
            return devPath
        }
        return nil
    }
}

/// Writes DualSense / DualShock 4 light-bar colors directly from the app
/// process, in shared (non-seize) mode - no LightHelper subprocess and no
/// gamecontrolleragentd kill. Spawning the helper per frame is far too slow
/// to look smooth, so the high-frequency RGB cycle drives this instead.
///
/// Devices are opened once (shared, coexisting with the system daemon) and
/// the handles reused for fast repeated writes. All IOKit access is
/// serialized on a private queue, so call `open`/`write`/`close` from any
/// thread. `write` lazily opens if needed, so a bare `write` also works.
final class InProcessLightWriter: @unchecked Sendable {
    nonisolated(unsafe) static let shared = InProcessLightWriter()

    private let queue = DispatchQueue(label: "com.joystickconfig.inproclight")
    private var devices: [(dev: IOHIDDevice, pid: Int32, isBT: Bool)] = []
    private var sequenceTag: UInt8 = 0

    private static let sonyVID: Int32 = 0x054C
    private static let dualSensePIDs: Set<Int32> = [0x0CE6, 0x0DF2]
    private static let ds4PIDs: Set<Int32> = [0x05C4, 0x09CC]

    private init() {}

    /// Enumerate and open every connected DualSense / DS4 in shared mode.
    /// Safe to call repeatedly; re-opens from scratch each time so it also
    /// serves as a "rescan after hotplug" call.
    func open()  { queue.async { [weak self] in self?.reopenLocked() } }

    /// Close every opened controller. Call when the cycle stops so we don't
    /// hold the devices open indefinitely.
    func close() { queue.async { [weak self] in self?.closeLocked() } }

    /// Write an LED color to every opened controller. RGB + brightness byte
    /// match the LightHelper report layout. Cheap enough to call at 60 Hz.
    func write(red: UInt8, green: UInt8, blue: UInt8, brightness: UInt8 = 2) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.devices.isEmpty { self.reopenLocked() }
            self.writeLocked(red: red, green: green, blue: blue, brightness: brightness)
        }
    }

    // MARK: - queue-only internals

    private func reopenLocked() {
        closeLocked()
        let matching = IOServiceMatching(kIOHIDDeviceKey) as NSMutableDictionary
        matching[kIOHIDVendorIDKey as String] = Self.sonyVID
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer { IOObjectRelease(entry); entry = IOIteratorNext(iterator) }
            guard let pidRef = IORegistryEntryCreateCFProperty(entry, kIOHIDProductIDKey as CFString, kCFAllocatorDefault, 0) else { continue }
            let pid = (pidRef.takeUnretainedValue() as! NSNumber).int32Value
            guard Self.dualSensePIDs.contains(pid) || Self.ds4PIDs.contains(pid) else { continue }
            guard let dev = IOHIDDeviceCreate(kCFAllocatorDefault, entry) else { continue }
            // Shared (non-exclusive) open: coexists with gamecontrolleragentd.
            guard IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { continue }
            var isBT = false
            if let tRef = IORegistryEntryCreateCFProperty(entry, kIOHIDTransportKey as CFString, kCFAllocatorDefault, 0) {
                isBT = ((tRef.takeUnretainedValue() as? String) ?? "").lowercased().contains("bluetooth")
            }
            devices.append((dev, pid, isBT))
        }
    }

    private func closeLocked() {
        for d in devices { IOHIDDeviceClose(d.dev, 0) }
        devices.removeAll()
    }

    private func writeLocked(red: UInt8, green: UInt8, blue: UInt8, brightness: UInt8) {
        for d in devices {
            let isDS = Self.dualSensePIDs.contains(d.pid)
            if isDS && !d.isBT {
                var data = [UInt8](repeating: 0, count: 48)
                data[0] = 0x02; data[2] = 0x04; data[39] = 0x06; data[42] = 0x02
                data[43] = brightness; data[45] = red; data[46] = green; data[47] = blue
                IOHIDDeviceSetReport(d.dev, kIOHIDReportTypeOutput, 0x02, data, data.count)
            } else if isDS && d.isBT {
                var data = [UInt8](repeating: 0, count: 79)
                data[0] = 0x31
                sequenceTag = (sequenceTag &+ 1) & 0x0F
                data[1] = (sequenceTag << 4) | 0x02
                data[2] = 0x00; data[3] = 0x04; data[40] = 0x06; data[43] = 0x02
                data[44] = brightness; data[46] = red; data[47] = green; data[48] = blue
                let crc = Self.crc32([0xA2, 0x31] + Array(data[1..<75]))
                data[75] = UInt8(crc & 0xFF); data[76] = UInt8((crc >> 8) & 0xFF)
                data[77] = UInt8((crc >> 16) & 0xFF); data[78] = UInt8((crc >> 24) & 0xFF)
                IOHIDDeviceSetReport(d.dev, kIOHIDReportTypeOutput, 0x31, data, data.count)
            } else if Self.ds4PIDs.contains(d.pid) && !d.isBT {
                var data = [UInt8](repeating: 0, count: 32)
                data[0] = 0x05; data[1] = 0x07; data[6] = red; data[7] = green; data[8] = blue
                IOHIDDeviceSetReport(d.dev, kIOHIDReportTypeOutput, 0x05, data, data.count)
            } else if Self.ds4PIDs.contains(d.pid) && d.isBT {
                var data = [UInt8](repeating: 0, count: 79)
                data[0] = 0x11; data[1] = 0xC0; data[2] = 0x20; data[3] = 0xF3; data[4] = 0x04
                data[7] = red; data[8] = green; data[9] = blue
                let crc = Self.crc32([0xA2, 0x11] + Array(data[1..<75]))
                data[75] = UInt8(crc & 0xFF); data[76] = UInt8((crc >> 8) & 0xFF)
                data[77] = UInt8((crc >> 16) & 0xFF); data[78] = UInt8((crc >> 24) & 0xFF)
                IOHIDDeviceSetReport(d.dev, kIOHIDReportTypeOutput, 0x11, data, data.count)
            }
        }
    }

    private static func crc32(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1 != 0) ? (crc >> 1) ^ 0xEDB88320 : crc >> 1 }
        }
        return crc ^ 0xFFFFFFFF
    }
}
