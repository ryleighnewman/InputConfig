import Foundation
import IOKit
import IOUSBHost

/// Xbox 360 class controllers over USB, read here because macOS has no
/// driver for them: wired Xbox 360 pads, most third-party pads in their X
/// mode, and 2.4G adapters that present as one. Such a device is not HID.
/// Its controller interface is vendor class 0xFF, subclass 0x5D, protocol
/// 0x01, with one interrupt IN endpoint that sends a 20 byte state each
/// time it changes and one interrupt OUT endpoint that takes the ring
/// light and the motors. Everything sent and read follows Linux's xpad.c
/// (XTYPE_XBOX360): the start request, the light, the motors, and the
/// state layout `HIDReportDecoder.decodeXInput` reads.
///
/// Each controller is listed as a raw pad with the transport "USB" and its
/// reports go through the live dispatcher, like a Switch 2 controller over
/// Bluetooth LE. The Xbox 360 wireless receiver (protocol 0x81) frames its
/// reports differently and is not read. Off with
/// `defaults write com.inputconfig.app InputConfig.xinputUSB -bool NO`,
/// for someone who wants another app to hold these pads.
final class XInputUSBService: @unchecked Sendable {
    static let shared = XInputUSBService()

    static let enabledKey = "InputConfig.xinputUSB"
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    // MARK: - The protocol, as xpad.c has it

    /// The controller interface of an Xbox 360 class device.
    static func isControllerInterface(interfaceClass: Int, subclass: Int, protocol proto: Int) -> Bool {
        interfaceClass == 0xFF && subclass == 0x5D && proto == 0x01
    }

    /// The interrupt endpoints of one interface, found by walking the
    /// configuration descriptor: an interface descriptor (type 4) opens a
    /// section, endpoint descriptors (type 5) follow it. Only the first
    /// alternate setting counts. Nil when the interface has no interrupt IN
    /// endpoint; the OUT one is missing on a few pads with no light or
    /// motors, and those are still read.
    static func interruptEndpoints(configuration: [UInt8], interfaceNumber: Int) -> (input: UInt8, output: UInt8?)? {
        var input: UInt8?
        var output: UInt8?
        var inside = false
        var i = 0
        while i + 2 <= configuration.count {
            let length = Int(configuration[i])
            if length < 2 || i + length > configuration.count { break }
            let type = configuration[i + 1]
            if type == 0x04, length >= 9 {
                inside = Int(configuration[i + 2]) == interfaceNumber && configuration[i + 3] == 0
            } else if type == 0x05, inside, length >= 7, configuration[i + 3] & 0x03 == 0x03 {
                let address = configuration[i + 2]
                if address & 0x80 != 0 {
                    if input == nil { input = address }
                } else if output == nil {
                    output = address
                }
            }
            i += length
        }
        return input.map { ($0, output) }
    }

    /// A controller state: message type 0x00, length 0x14. The other
    /// messages on the same endpoint (the light's echo 0x01, the motors'
    /// 0x03, the headset's 0x08) are not input.
    static func isState(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 20 && bytes[0] == 0x00 && bytes[1] == 0x14
    }

    /// The request some third-party pads wait for before they report
    /// (xpad_start_input): vendor, device to host, to the interface,
    /// request 0x01, value 0x0100, 20 bytes back, which are not used.
    static let startRequest = IOUSBDeviceRequest(bmRequestType: 0xC1, bRequest: 0x01, wValue: 0x0100, wIndex: 0x0000, wLength: 20)

    /// The ring light: quarter `player` (1 to 4) blinks, then stays lit
    /// (xpad_identify_controller: command 2 to 5).
    static func lightCommand(player: Int) -> [UInt8] {
        [0x01, 0x03, UInt8((max(1, player) - 1) % 4 + 2)]
    }

    /// Both motors, each 0 to 1: the big left one, then the small right one
    /// (xpad_play_effect, XTYPE_XBOX360).
    static func motorCommand(strong: Float, weak: Float) -> [UInt8] {
        func level(_ v: Float) -> UInt8 { UInt8(max(0, min(1, v)) * 255) }
        return [0x00, 0x08, 0x00, level(strong), level(weak), 0x00, 0x00, 0x00]
    }

    // MARK: - State

    private final class Pad {
        let id: UInt64              // registry entry ID of the interface
        let deviceID: UInt64        // registry entry ID of the USB device
        let name: String
        let interface: IOUSBHostInterface
        let input: IOUSBHostPipe
        let output: IOUSBHostPipe?
        let buffer: NSMutableData
        var key: UInt64?
        var closed = false
        var failures = 0
        var motorsStop: DispatchWorkItem?
        init(id: UInt64, deviceID: UInt64, name: String, interface: IOUSBHostInterface,
             input: IOUSBHostPipe, output: IOUSBHostPipe?, buffer: NSMutableData) {
            self.id = id; self.deviceID = deviceID; self.name = name; self.interface = interface
            self.input = input; self.output = output; self.buffer = buffer
        }
    }

    private let queue = DispatchQueue(label: "com.inputconfig.xinput-usb", qos: .userInitiated)
    /// Open pads by interface entry ID. Touched on `queue` only.
    private var pads: [UInt64: Pad] = [:]
    /// Interfaces that could not be opened, so each is said once. `queue`.
    private var refused: Set<UInt64> = []
    /// How often an interface was opened again after its read was cut off
    /// while it stayed plugged in (the Mac slept). Cleared by a read that
    /// works; three in a row and it is left closed. `queue`.
    private var reopened: [UInt64: Int] = [:]
    /// What the other threads ask: the devices read here, and the pad
    /// behind each key. Guarded by `lock`.
    private let lock = NSLock()
    private var deviceIDs: Set<UInt64> = []
    private var keys: [UInt64: UInt64] = [:]   // pad key to interface entry ID

    private init() {}

    /// Whether the USB device with this registry entry ID is read here,
    /// for the Devices menu: it is no longer a pad macOS cannot read.
    func reads(deviceID: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return deviceIDs.contains(deviceID)
    }

    /// Looks at the USB bus again: opens each controller interface that
    /// appeared and lets go of each that left. Called at start and on
    /// every vendor-class interface coming or going.
    func refresh() {
        guard Self.isEnabled else { return }
        queue.async { [weak self] in self?.scan() }
    }

    private func scan() {
        let matching = IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary
        matching["IOPropertyMatch"] = ["bInterfaceClass": 0xFF, "bInterfaceSubClass": 0x5D, "bInterfaceProtocol": 0x01]
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var present: Set<UInt64> = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS, id != 0 else { continue }
            present.insert(id)
            if pads[id] == nil, !refused.contains(id) { open(service, id: id) }
        }
        for (id, pad) in pads where !present.contains(id) { close(pad) }
        refused.formIntersection(present)
        reopened = reopened.filter { present.contains($0.key) }
    }

    private func open(_ service: io_service_t, id: UInt64) {
        func number(_ entry: io_registry_entry_t, _ key: String) -> Int? {
            (IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
        }
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(parent) }
        var deviceID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(parent, &deviceID)
        let vendorID = Int32(number(parent, "idVendor") ?? number(service, "idVendor") ?? 0)
        let productID = Int32(number(parent, "idProduct") ?? number(service, "idProduct") ?? 0)
        let name = ["USB Product Name", "kUSBProductString"].lazy.compactMap {
            IORegistryEntryCreateCFProperty(parent, $0 as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        }.first { !$0.isEmpty } ?? "Xbox 360 Controller"
        let interfaceNumber = number(service, "bInterfaceNumber") ?? 0

        func refuse(_ why: String) {
            guard refused.insert(id).inserted else { return }
            ActivityLog.shared.warning("Devices", "\(name): could not be read over USB (\(why))")
        }
        let interface: IOUSBHostInterface
        do {
            interface = try IOUSBHostInterface(__ioService: service, options: [], queue: queue, interestHandler: nil)
        } catch {
            // Another app holds the interface, most likely.
            refuse(error.localizedDescription)
            return
        }
        let config = interface.configurationDescriptor
        let total = Int(config.pointee.wTotalLength)
        let bytes = Array(UnsafeRawBufferPointer(start: UnsafeRawPointer(config), count: total))
        guard let endpoints = Self.interruptEndpoints(configuration: bytes, interfaceNumber: interfaceNumber),
              let input = try? interface.copyPipe(withAddress: Int(endpoints.input)) else {
            interface.destroy()
            refuse("its input endpoint was not found")
            return
        }
        let output = endpoints.output.flatMap { try? interface.copyPipe(withAddress: Int($0)) }
        let size = max(32, Int(input.descriptors.pointee.descriptor.wMaxPacketSize & 0x07FF))
        guard let buffer = NSMutableData(length: size) else { interface.destroy(); return }
        let pad = Pad(id: id, deviceID: deviceID, name: name, interface: interface, input: input, output: output, buffer: buffer)
        pads[id] = pad
        lock.lock(); deviceIDs.insert(deviceID); lock.unlock()

        // The request some pads wait for; a pad that does not know it
        // answers with a stall, which changes nothing.
        var transferred: UInt = 0
        try? interface.__send(Self.startRequest, data: NSMutableData(length: 20), bytesTransferred: &transferred, completionTimeout: 0.5)
        send(Self.lightCommand(player: 1), to: pad)

        let profile = Self.profile(vendorID: vendorID, productID: productID)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let key = RawHIDGamepadService.shared.attachExternalPad(profile: profile, vendorID: vendorID, productID: productID,
                                                                        transport: "USB", productName: name)
                self.queue.async {
                    guard !pad.closed else {
                        // Left while this hop was on its way.
                        DispatchQueue.main.async { MainActor.assumeIsolated { RawHIDGamepadService.shared.detachExternalPad(key: key) } }
                        return
                    }
                    pad.key = key
                    self.lock.lock(); self.keys[key] = pad.id; self.lock.unlock()
                    self.read(pad)
                }
                ActivityLog.shared.info("Devices", "\(name): read over USB as an Xbox 360 class controller")
                HIDDeviceRegistry.shared.refreshUnreadablePads()
            }
        }
    }

    /// The profile a controller is listed with: its own when the database
    /// has an XInput one for the model, else the Xbox 360 controller's.
    static func profile(vendorID: Int32, productID: Int32) -> ControllerProfile {
        if let own = ControllerProfileDatabase.profile(forVendor: vendorID, product: productID, transport: "USB"), own.layout == .xinput {
            return own
        }
        return ControllerProfileDatabase.profile(forVendor: 0x045E, product: 0x028E) ?? ControllerProfileDatabase.all[0]
    }

    /// One read is always waiting on the endpoint: a pad at rest sends
    /// nothing, so the request has no timeout (an interrupt pipe takes
    /// none), and each answer queues the next.
    private func read(_ pad: Pad) {
        guard !pad.closed else { return }
        do {
            try pad.input.enqueueIORequest(with: pad.buffer, completionTimeout: 0) { [weak self] status, count in
                guard let self, !pad.closed else { return }
                if status == kIOReturnSuccess {
                    pad.failures = 0
                    self.reopened[pad.id] = nil
                    let bytes = [UInt8](UnsafeRawBufferPointer(start: pad.buffer.bytes, count: min(count, pad.buffer.length)))
                    if Self.isState(bytes), let key = pad.key {
                        RawHIDGamepadService.shared.dispatchOnReportThread(key: key, reportID: 0, bytes: Array(bytes.prefix(20)))
                    }
                    self.read(pad)
                } else if status == kIOReturnAborted || status == kIOReturnNotAttached || status == kIOReturnNoDevice {
                    self.close(pad)
                    // Unplugged, the next look finds nothing. Still plugged
                    // in (sleep cuts a waiting read off without the pad
                    // leaving the bus), it is opened again there.
                    if self.reopened[pad.id, default: 0] < 3 {
                        self.reopened[pad.id, default: 0] += 1
                        self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.scan() }
                    }
                } else {
                    self.retry(pad)
                }
            }
        } catch {
            retry(pad)
        }
    }

    /// A read that failed for another reason (a stall, most often): the
    /// endpoint is cleared and asked again after a moment, and the pad is
    /// let go of after five failures in a row.
    private func retry(_ pad: Pad) {
        pad.failures += 1
        guard pad.failures <= 5 else { close(pad); return }
        try? pad.input.clearStall()
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.read(pad) }
    }

    private func close(_ pad: Pad) {
        guard !pad.closed else { return }
        pad.closed = true
        pad.motorsStop?.cancel()
        pads[pad.id] = nil
        lock.lock()
        deviceIDs.remove(pad.deviceID)
        if let key = pad.key { keys[key] = nil }
        lock.unlock()
        pad.interface.destroy()
        let key = pad.key, name = pad.name
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let key { RawHIDGamepadService.shared.detachExternalPad(key: key) }
                ActivityLog.shared.info("Devices", "\(name): disconnected")
                HIDDeviceRegistry.shared.refreshUnreadablePads()
            }
        }
    }

    /// One message to the OUT endpoint. `done` is signaled when it has
    /// gone out, or could not.
    private func send(_ command: [UInt8], to pad: Pad, done: DispatchSemaphore? = nil) {
        guard !pad.closed, let output = pad.output else { done?.signal(); return }
        do {
            try output.enqueueIORequest(with: NSMutableData(bytes: command, length: command.count), completionTimeout: 0) { _, _ in
                done?.signal()
            }
        } catch {
            done?.signal()
        }
    }

    // MARK: - Motors

    /// Whether the pad listed under `key` is one of these.
    func isPad(key: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return keys[key] != nil
    }

    /// Both motors at `intensity` (0 to 1) for `durationMs`, then off: a pad
    /// holds its motors until told otherwise. False when `key` is no pad
    /// read here.
    @discardableResult
    func rumble(key: UInt64, intensity: Float, durationMs: Int) -> Bool {
        lock.lock()
        let id = keys[key]
        lock.unlock()
        guard let id else { return false }
        queue.async { [weak self] in
            guard let self, let pad = self.pads[id] else { return }
            pad.motorsStop?.cancel()
            self.send(Self.motorCommand(strong: intensity, weak: intensity), to: pad)
            let stop = DispatchWorkItem { [weak self] in
                self?.send(Self.motorCommand(strong: 0, weak: 0), to: pad)
                pad.motorsStop = nil
            }
            pad.motorsStop = stop
            self.queue.asyncAfter(deadline: .now() + .milliseconds(max(60, durationMs)), execute: stop)
        }
        return true
    }

    /// Every motor off now (an emergency stop, quit). `wait` runs it before
    /// returning, for quit, where queued work would die with the process.
    func stopMotors(wait: Bool = false) {
        var sent: [DispatchSemaphore] = []
        let work = { [weak self] in
            guard let self else { return }
            for pad in self.pads.values {
                pad.motorsStop?.cancel()
                pad.motorsStop = nil
                let done = wait ? DispatchSemaphore(value: 0) : nil
                if let done { sent.append(done) }
                self.send(Self.motorCommand(strong: 0, weak: 0), to: pad, done: done)
            }
        }
        guard wait else { queue.async(execute: work); return }
        queue.sync(execute: work)
        // The messages go out on that queue, so they are waited for from
        // here, each for a fifth of a second at most.
        for done in sent { _ = done.wait(timeout: .now() + 0.2) }
    }
}
