import Foundation
import IOKit
import IOKit.hid
import IOKit.usb
import Combine
import CryptoKit

/// A device's serial number (often its Bluetooth address) is never stored
/// or exported as it is. Everything that remembers one device (a preset's
/// device fingerprint, per-pad motion calibration, devices connected by
/// hand) keeps a salted hash instead. The salt is random per Mac and is
/// left out of backups, so a hash in a shared or backed-up file cannot be
/// matched to the device anywhere else.
enum DeviceSerial {
    static let saltKey = "InputConfig.deviceSerialSalt.v1"

    private static let salt: String = {
        if let existing = UserDefaults.standard.string(forKey: saltKey), !existing.isEmpty { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: saltKey)
        return fresh
    }()

    /// A short, stable stand-in for `serial` on this Mac.
    static func hashed(_ serial: String) -> String {
        let digest = SHA256.hash(data: Data((salt + "|" + serial).utf8))
        return "h" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// Every external HID device the system can see, grouped by transport, for
/// the InputConfig ▸ Devices menu. This is the "I plugged it in and nothing
/// happened" escape hatch: a device that neither the GameController
/// framework nor the gamepad-usage filter in `RawHIDGamepadService` picked
/// up can be connected by hand from the menu, and the choice is remembered
/// per device (vendor, product, and serial when it has one) so it
/// reconnects on its own next time.
///
/// The manager here matches every HID device but is never opened:
/// enumeration and attach / detach callbacks work without `IOHIDManagerOpen`,
/// and not opening means no Input Monitoring prompt for the keyboards and
/// mice in the list. Opening happens only in `RawHIDGamepadService.adopt`,
/// for the one device the user picked, and never for keyboard or pointer
/// interfaces (those need Input Monitoring, which the App Store build does
/// not request; keyboards and mice already reach presets through the
/// Accessibility event path).
///
/// It also watches the USB registry, read-only, for Xbox-style pads that
/// are not HID at all (XUSB and GIP vendor-class interfaces), so the menu
/// can say why they never show up instead of listing nothing.
@MainActor
final class HIDDeviceRegistry: ObservableObject {

    static let shared = HIDDeviceRegistry()

    enum Transport: String, CaseIterable {
        case bluetooth = "Bluetooth"
        case usb = "USB"
        case other = "Other"
    }

    /// What a device's primary usage says it is, which decides whether the
    /// menu offers to connect it.
    enum Kind {
        case gamepad      // Generic Desktop joystick / gamepad / multi-axis, Simulation Controls
        case keyboard     // Generic Desktop keyboard / keypad
        case pointer      // Generic Desktop mouse / pointer, digitizers
        case consumer     // Consumer page (media keys, remotes)
        case vendor       // Vendor-defined page
        case config       // Known configuration channel (VIA, Logitech HID++): never offered
        case other

        /// Interfaces InputConfig may open without Input Monitoring.
        var adoptable: Bool {
            switch self {
            case .gamepad, .vendor, .other: return true
            case .keyboard, .pointer, .consumer, .config: return false
            }
        }

        var label: String {
            switch self {
            case .gamepad: return "game controller"
            case .keyboard: return "keyboard, use Keyboard Key input"
            case .pointer: return "mouse, use Mouse input"
            case .consumer: return "arrives as media keys: bind Keyboard Key › Play / Pause"
            case .vendor: return "vendor-specific device"
            case .config: return "configuration channel"
            case .other: return "device"
            }
        }
    }

    /// One physical device. A controller often registers several HID
    /// interfaces (the gamepad report, a vendor channel, sometimes a
    /// keyboard for a media button); they are folded into one entry and the
    /// best interface is what `adopt` opens.
    struct Entry: Identifiable, Equatable {
        let id: String
        let name: String
        let vendorID: Int32
        let productID: Int32
        let transport: Transport

        /// The original Steam Controller (wired or its dongle): its own
        /// helper reads it, and its keyboard and mouse are only lizard mode.
        var isSteamController: Bool {
            vendorID == 0x28DE && [0x1102, 0x1142, 0x1302, 0x1303, 0x1304, 0x1305].contains(productID)
        }
        /// The kinds of the interfaces this device exposes, best first.
        let kinds: [Kind]

        /// What the device is to the user. A composite mouse, keyboard,
        /// macro pad, or pedal also exposes a vendor channel for its
        /// configuration software; it is still a mouse or keyboard, so that
        /// wins over the vendor channel.
        var primaryKind: Kind {
            if kinds.contains(.gamepad) { return .gamepad }
            if let input = HIDDeviceRegistry.keyboardOrPointer(kinds, name: name) { return input }
            return kinds.first ?? .other
        }

        /// The kind of interface the menu may open, or nil when the device
        /// is not switchable. A device with a keyboard or pointer interface
        /// and no gamepad interface reaches presets through the Keyboard Key
        /// or Mouse input types; opening its vendor channel reads the
        /// configuration protocol, not the buttons.
        var adoptableKind: Kind? { HIDDeviceRegistry.adoptableKind(kinds, name: name) }

        static func == (l: Entry, r: Entry) -> Bool {
            l.id == r.id && l.name == r.name && l.transport == r.transport && l.kinds == r.kinds
        }
    }

    /// A USB game controller macOS cannot read as HID at all. Listed in the
    /// menu, disabled, with the reason.
    struct UnreadablePad: Identifiable, Equatable {
        let id: UInt64
        let name: String
        let vendorID: Int32
        let productID: Int32
        let reason: String
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var unreadablePads: [UnreadablePad] = []

    private var manager: IOHIDManager?
    /// Interfaces per entry, in adoption priority order.
    private var interfaces: [String: [(kind: Kind, device: IOHIDDevice)]] = [:]
    private var entryIDByDevice: [ObjectIdentifier: String] = [:]

    private var usbNotifyPort: IONotificationPortRef?
    private var usbIterators: [io_iterator_t] = []
    /// Vendor:product pairs already written to the Activity Log as
    /// unreadable, so a replug does not repeat the message.
    private var loggedUnreadable: Set<String> = []

    /// Devices the user connected by hand. Persisted so the device
    /// reconnects on its own the next time it is plugged in.
    static let rememberedKey = "InputConfig.manualHIDDevices"

    private init() { }

    func start() {
        guard manager == nil else { return }
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr
        IOHIDManagerSetDeviceMatching(mgr, nil)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { context, _, _, device in
            guard let context else { return }
            let reg = Unmanaged<HIDDeviceRegistry>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in reg.attached(device) }
        }, selfPtr)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { context, _, _, device in
            guard let context else { return }
            let reg = Unmanaged<HIDDeviceRegistry>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in reg.detached(device) }
        }, selfPtr)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        // Deliberately not opened: see the type comment.
        startUSBWatch()
    }

    /// Rebuild the list from scratch. The callbacks keep it current; this
    /// is for the menu's Rescan item.
    func rescan() {
        guard let mgr = manager else { start(); return }
        interfaces.removeAll()
        entryIDByDevice.removeAll()
        entries.removeAll()
        for device in (IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>) ?? [] {
            attached(device)
        }
        refreshUnreadablePads()
    }

    func entries(on transport: Transport) -> [Entry] {
        entries.filter { $0.transport == transport }
    }

    /// The interface to open for an entry: the gamepad interface when there
    /// is one, else the first vendor-defined or unclassified one. Nil for a
    /// device that is not switchable (see `Entry.adoptableKind`).
    func adoptableDevice(for entry: Entry) -> IOHIDDevice? {
        guard let kind = entry.adoptableKind else { return nil }
        return interfaces[entry.id]?.first(where: { $0.kind == kind })?.device
    }

    /// Every interface of an entry, so "in use" can be answered for any of
    /// them (the gamepad service may hold its own reference to the device).
    func devices(for entry: Entry) -> [IOHIDDevice] {
        interfaces[entry.id]?.map(\.device) ?? []
    }

    /// True while this device object is one of the interfaces on the bus.
    func contains(_ device: IOHIDDevice) -> Bool {
        entryIDByDevice[ObjectIdentifier(device)] != nil
    }

    // MARK: - Kind rules

    /// For a device with keyboard or pointer interfaces, which one it is to
    /// the user. The name decides when it has both; otherwise keyboard,
    /// since macro pads and pedals send keys.
    nonisolated static func keyboardOrPointer(_ kinds: [Kind], name: String) -> Kind? {
        let hasKeyboard = kinds.contains(.keyboard)
        let hasPointer = kinds.contains(.pointer)
        switch (hasKeyboard, hasPointer) {
        case (false, false): return nil
        case (true, false): return .keyboard
        case (false, true): return .pointer
        case (true, true):
            // Most gaming mice and receivers add a keyboard interface for
            // their macro keys and never say "mouse" in their name, so a
            // device with both is a pointer unless it says it is a keyboard.
            let words = Set(name.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
            let keyboardWords: Set<String> = ["keyboard", "keypad", "keys", "numpad", "kb"]
            return words.isDisjoint(with: keyboardWords) ? .pointer : .keyboard
        }
    }

    nonisolated static func adoptableKind(_ kinds: [Kind], name: String) -> Kind? {
        if kinds.contains(.gamepad) { return .gamepad }
        if keyboardOrPointer(kinds, name: name) != nil { return nil }
        return kinds.first(where: { $0.adoptable })
    }

    // MARK: - Remembered manual connections

    static func rememberedPairs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: rememberedKey) ?? [])
    }

    /// The older, vendor and product only key. Still honored so devices
    /// connected by hand in an earlier version keep reconnecting.
    static func pairKey(vendorID: Int32, productID: Int32) -> String {
        String(format: "%04x:%04x", vendorID, productID)
    }

    /// The key a device is remembered by: vendor and product, the vendor
    /// ID source when the device reports one (a Bluetooth SIG vendor ID and
    /// a USB vendor ID with the same number are different companies), and
    /// the serial number when there is one, so two identical pads are
    /// remembered separately.
    static func rememberKey(for device: IOHIDDevice) -> String? {
        func prop(_ key: String) -> Any? { IOHIDDeviceGetProperty(device, key as CFString) }
        guard let vid = (prop(kIOHIDVendorIDKey) as? NSNumber)?.int32Value,
              let pid = (prop(kIOHIDProductIDKey) as? NSNumber)?.int32Value else { return nil }
        var key = pairKey(vendorID: vid, productID: pid)
        if let source = (prop(kIOHIDVendorIDSourceKey) as? NSNumber)?.intValue {
            key += "@\(source)"
        }
        let serial = ((prop(kIOHIDSerialNumberKey) as? String) ?? "")
            .trimmingCharacters(in: .whitespaces)
        if !serial.isEmpty { key += "#" + DeviceSerial.hashed(serial) }
        return key
    }

    static func remember(_ device: IOHIDDevice, _ on: Bool) {
        guard let key = rememberKey(for: device) else { return }
        var set = rememberedPairs()
        if on {
            // Only this device's own key. A backup adds the plain vendor and
            // product key for another Mac (see the backup in SettingsView);
            // writing it here connected every identical pad.
            set.insert(key)
        } else {
            set.remove(key)
            // Forgetting also drops an older vendor and product key for it.
            if let vid = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber)?.int32Value,
               let pid = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber)?.int32Value {
                set.remove(pairKey(vendorID: vid, productID: pid))
            }
        }
        UserDefaults.standard.set(Array(set).sorted(), forKey: rememberedKey)
    }

    static func isRemembered(_ device: IOHIDDevice) -> Bool {
        let set = rememberedPairs()
        guard !set.isEmpty, let key = rememberKey(for: device) else { return false }
        if set.contains(key) { return true }
        if let vid = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber)?.int32Value,
           let pid = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber)?.int32Value {
            return set.contains(pairKey(vendorID: vid, productID: pid))
        }
        return false
    }

    // MARK: - Callbacks

    private func attached(_ device: IOHIDDevice) {
        func prop(_ key: String) -> Any? { IOHIDDeviceGetProperty(device, key as CFString) }
        let builtIn = (prop("Built-In") as? Bool) ?? false
        let transportRaw = (prop(kIOHIDTransportKey) as? String) ?? ""
        let vid = (prop(kIOHIDVendorIDKey) as? NSNumber)?.int32Value ?? 0
        let pid = (prop(kIOHIDProductIDKey) as? NSNumber)?.int32Value ?? 0
        let usagePage = (prop(kIOHIDPrimaryUsagePageKey) as? NSNumber)?.intValue ?? 0
        let usage = (prop(kIOHIDPrimaryUsageKey) as? NSNumber)?.intValue ?? 0
        let name = (prop(kIOHIDProductKey) as? String)?.trimmingCharacters(in: .whitespaces)

        var transport: Transport
        switch transportRaw.lowercased() {
        case let t where t.hasPrefix("bluetooth"): transport = .bluetooth
        case "usb": transport = .usb
        default: transport = .other
        }
        // The one virtual device worth showing: macOS creates "Headset
        // Audio" (a consumer-control device on the "Audio" transport) for the
        // buttons and tap gestures of a connected Bluetooth headset or
        // hearing aid. Its presses arrive as media keys, so list it under
        // Bluetooth and say how to bind it. Checked before the built-in
        // filter: on some Macs this device reports Built-In.
        let isHeadsetBridge = usagePage == 0x0C && vid == 0
            && transportRaw.lowercased() == "audio"
            && (name ?? "").localizedCaseInsensitiveContains("headset")
        // Built-in parts of the Mac (keyboard, trackpad, sensors, Touch
        // Bar) and the virtual devices macOS creates are not something a
        // user would connect; only external hardware belongs in the menu.
        if builtIn && !isHeadsetBridge { return }
        if transport == .other && !isHeadsetBridge {
            let internalTransports = ["spu", "spi", "spmi", "fifo", "virtual", "airplay", ""]
            if internalTransports.contains(transportRaw.lowercased()) { return }
            if vid == 0 { return }
        }
        if isHeadsetBridge { transport = .bluetooth }

        var kind: Kind
        switch (usagePage, usage) {
        case (0x01, 0x04), (0x01, 0x05), (0x01, 0x08), (0x02, _): kind = .gamepad
        case (0x01, 0x06), (0x01, 0x07): kind = .keyboard
        case (0x01, 0x01), (0x01, 0x02), (0x0D, _): kind = .pointer
        case (0x0C, _): kind = .consumer
        // VIA / QMK raw HID, and Logitech HID++ (short and long report
        // channels): configuration protocols, never button input.
        case (0xFF60, _), (0xFF43, _): kind = .config
        case (0xFF00, _) where vid == 0x046D: kind = .config
        case (0xFF00...0xFFFF, _): kind = .vendor
        default: kind = .other
        }
        // A Stream Deck's key interface is on the Consumer page but sends
        // key states, not media keys; it is offered like a vendor device.
        if ControllerProfileDatabase.isStreamDeck(vendorID: vid, productID: pid) { kind = .vendor }
        // Another Elgato model is not media keys either; it is just not read
        // yet, so it gets the plain label.
        else if vid == ControllerProfileDatabase.streamDeckVendorID && kind == .consumer { kind = .other }
        // Jog and shuttle controllers (Contour ShuttleXpress and ShuttlePRO,
        // Griffin PowerMate) declare a Consumer collection but send their
        // buttons and wheels as ordinary fields that never become media keys,
        // so they are connected like a gamepad.
        if kind == .consumer && (vid == 0x0B33 || vid == 0x077D) { kind = .vendor }

        let manufacturer = (prop(kIOHIDManufacturerKey) as? String)?.trimmingCharacters(in: .whitespaces)
        let serial = (prop(kIOHIDSerialNumberKey) as? String) ?? ""
        let location = (prop(kIOHIDLocationIDKey) as? NSNumber)?.uint64Value ?? 0
        // One entry per physical device: same vendor, product, serial, and
        // bus location. The location too when there is a serial: identical
        // Arduino button boxes all carry the same serial, and folded into
        // one entry whose toggle opened only the first.
        let entryID = String(format: "%04x:%04x:%@", vid, pid,
                             serial.isEmpty ? String(location) : serial + "@" + String(location))
        let displayName: String = {
            if isHeadsetBridge { return "Bluetooth headset buttons" }
            if let name, !name.isEmpty { return name }
            if let manufacturer, !manufacturer.isEmpty { return "\(manufacturer) device" }
            return String(format: "HID device %04X:%04X", vid, pid)
        }()

        entryIDByDevice[ObjectIdentifier(device)] = entryID
        var list = interfaces[entryID] ?? []
        if !list.contains(where: { $0.device === device }) {
            list.append((kind, device))
        }
        // Best interface first: gamepad, then keyboard and pointer (what a
        // composite mouse or keyboard really is), then vendor, then the rest.
        func rank(_ k: Kind) -> Int {
            switch k { case .gamepad: return 0; case .keyboard: return 1; case .pointer: return 2
                       case .vendor: return 3; case .other: return 4; case .consumer: return 5
                       case .config: return 6 }
        }
        // Equal ranks by the interface's registry ID, not arrival order:
        // Rescan or a relaunch could make another interface the one kept
        // open, closing the one the rows were scanned on.
        func registryID(_ d: IOHIDDevice) -> UInt64 {
            var id: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(d), &id)
            return id
        }
        list.sort { rank($0.kind) != rank($1.kind) ? rank($0.kind) < rank($1.kind)
                                                    : registryID($0.device) < registryID($1.device) }
        interfaces[entryID] = list

        let entry = Entry(id: entryID, name: displayName, vendorID: vid, productID: pid,
                          transport: transport, kinds: list.map(\.kind))
        if let i = entries.firstIndex(where: { $0.id == entryID }) {
            entries[i] = entry
        } else {
            entries.append(entry)
            entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        // A device the user connected by hand before comes back on its own,
        // through its best interface only. Interfaces arrive one at a time,
        // so a lower-ranked one adopted before the best one showed up is
        // let go once the best one is here.
        if kind.adoptable, Self.isRemembered(device),
           let best = adoptableDevice(for: entry) {
            let gamepads = RawHIDGamepadService.shared
            if !gamepads.isOpen(best) {
                gamepads.adopt(best, remember: false)
            }
        }
        // Only the best interface stays open. A remembered composite device
        // whose vendor channel arrived before its keyboard interface had
        // that channel opened, and kept it, with no toggle to close it.
        let gamepads = RawHIDGamepadService.shared
        let bestDevice = adoptableDevice(for: entry)
        // Gamepad interfaces are left to the gamepad service's own rules.
        // The 2026 Steam Controller's vendor interfaces are opened by the
        // gamepad service on its own (the Puck has one per controller); the
        // registry closed them right after, and the controller never read.
        // Only interfaces connected by hand: one the gamepad service opened
        // on its own (a profile, a gamepad collection) is left to it.
        for other in list where other.device !== bestDevice && other.kind != .gamepad
            && gamepads.isOpen(other.device) && gamepads.wasConnectedByHand(other.device)
            && !entry.isSteamController {
            gamepads.deviceWentAway(other.device)
        }
    }

    private func detached(_ device: IOHIDDevice) {
        guard let entryID = entryIDByDevice.removeValue(forKey: ObjectIdentifier(device)) else { return }
        var list = interfaces[entryID] ?? []
        list.removeAll { $0.device === device }
        if list.isEmpty {
            interfaces.removeValue(forKey: entryID)
            entries.removeAll { $0.id == entryID }
        } else {
            interfaces[entryID] = list
            if let i = entries.firstIndex(where: { $0.id == entryID }) {
                let e = entries[i]
                entries[i] = Entry(id: e.id, name: e.name, vendorID: e.vendorID, productID: e.productID,
                                   transport: e.transport, kinds: list.map(\.kind))
            }
        }
        // Interfaces outside the gamepad filter were opened through this
        // registry's device object, so their teardown has to come from here.
        RawHIDGamepadService.shared.deviceWentAway(device)
    }

    // MARK: - Non-HID Xbox pads (read-only USB registry watch)

    /// Watch vendor-class USB interfaces come and go. Nothing is opened:
    /// the registry is only read, which the sandbox allows.
    private func startUSBWatch() {
        guard usbNotifyPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        usbNotifyPort = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { context, iterator in
            while case let obj = IOIteratorNext(iterator), obj != 0 { IOObjectRelease(obj) }
            guard let context else { return }
            let reg = Unmanaged<HIDDeviceRegistry>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in reg.refreshUnreadablePads() }
        }
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            guard let match = IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary? else { continue }
            // Inside IOPropertyMatch: a bare top-level bInterfaceClass is not a
            // key combination USB interface matching accepts, so it matched
            // nothing (see Switch2USBEnabler).
            match["IOPropertyMatch"] = ["bInterfaceClass": 0xFF]
            var iterator: io_iterator_t = 0
            let kr = IOServiceAddMatchingNotification(port, type, match, callback, selfPtr, &iterator)
            guard kr == KERN_SUCCESS else { continue }
            // Arm the notification by draining what is already there.
            while case let obj = IOIteratorNext(iterator), obj != 0 { IOObjectRelease(obj) }
            usbIterators.append(iterator)
        }
        refreshUnreadablePads()
    }

    /// Rebuild the list of Xbox-style USB pads macOS cannot read as HID:
    /// XUSB (class 0xFF, subclass 0x5D), used by Xbox 360 pads and most
    /// third-party XInput pads, and GIP (class 0xFF, subclass 0x47,
    /// protocol 0xD0), used by Xbox One and Series pads, which macOS 15
    /// and later reads through GameController.
    func refreshUnreadablePads() {
        guard let match = IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary? else { return }
        // Inside IOPropertyMatch, as above.
        match["IOPropertyMatch"] = ["bInterfaceClass": 0xFF]
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        let gipReadable = ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
        var found: [UInt64: UnreadablePad] = [:]

        while case let interface = IOIteratorNext(iterator), interface != 0 {
            defer { IOObjectRelease(interface) }
            func intProp(_ entry: io_registry_entry_t, _ key: String) -> Int? {
                (IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? NSNumber)?.intValue
            }
            let subclass = intProp(interface, "bInterfaceSubClass") ?? -1
            let proto = intProp(interface, "bInterfaceProtocol") ?? -1
            let isXUSB = subclass == 0x5D
            let isGIP = subclass == 0x47 && proto == 0xD0
            guard isXUSB || (isGIP && !gipReadable) else { continue }

            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(interface, kIOServicePlane, &parent) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(parent) }
            var parentID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(parent, &parentID)
            if found[parentID] != nil { continue }

            let vid = Int32(intProp(parent, "idVendor") ?? intProp(interface, "idVendor") ?? 0)
            let pid = Int32(intProp(parent, "idProduct") ?? intProp(interface, "idProduct") ?? 0)
            let productName = ["USB Product Name", "kUSBProductString"].lazy.compactMap {
                IORegistryEntryCreateCFProperty(parent, $0 as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String
            }.first
            let name = productName.flatMap { $0.isEmpty ? nil : $0 }
                ?? String(format: "USB controller %04X:%04X", vid, pid)
            let reason = isGIP
                ? "Xbox One or Series pad: update to macOS 15 to use it over USB, or use Bluetooth"
                : "Xbox 360 style pad: macOS cannot read it; if the pad has another mode (DInput, Switch) or Bluetooth, use that"
            found[parentID] = UnreadablePad(id: parentID, name: name, vendorID: vid, productID: pid, reason: reason)

            let logKey = HIDDeviceRegistry.pairKey(vendorID: vid, productID: pid)
            if !loggedUnreadable.contains(logKey) {
                loggedUnreadable.insert(logKey)
                ActivityLog.shared.warning("Devices", "\(name) (\(logKey)) is not a HID device. \(reason)")
            }
        }

        let pads = found.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        if pads != unreadablePads { unreadablePads = pads }
    }
}
