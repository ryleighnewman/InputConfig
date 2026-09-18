import Foundation
import IOKit
import IOKit.hid
import Combine

/// Every external HID device the system can see, grouped by transport, for
/// the InputConfig ▸ Devices menu. This is the "I plugged it in and nothing
/// happened" escape hatch: a device that neither the GameController
/// framework nor the gamepad-usage filter in `RawHIDGamepadService` picked
/// up can be connected by hand from the menu, and the choice is remembered
/// by vendor and product ID so it reconnects on its own next time.
///
/// The manager here matches every HID device but is never opened:
/// enumeration and attach / detach callbacks work without `IOHIDManagerOpen`,
/// and not opening means no Input Monitoring prompt for the keyboards and
/// mice in the list. Opening happens only in `RawHIDGamepadService.adopt`,
/// for the one device the user picked, and never for keyboard or pointer
/// interfaces (those need Input Monitoring, which the App Store build does
/// not request; keyboards and mice already reach presets through the
/// Accessibility event path).
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
        case gamepad      // Generic Desktop joystick / gamepad / multi-axis
        case keyboard     // Generic Desktop keyboard / keypad
        case pointer      // Generic Desktop mouse / pointer, digitizers
        case consumer     // Consumer page (media keys, remotes)
        case vendor       // Vendor-defined page
        case other

        /// Interfaces InputConfig may open without Input Monitoring.
        var adoptable: Bool {
            switch self {
            case .gamepad, .vendor, .other: return true
            case .keyboard, .pointer, .consumer: return false
            }
        }

        var label: String {
            switch self {
            case .gamepad: return "game controller"
            case .keyboard: return "keyboard"
            case .pointer: return "mouse or trackpad"
            case .consumer: return "arrives as media keys: bind Keyboard Key › Play / Pause"
            case .vendor: return "vendor-specific device"
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
        /// The kinds of the interfaces this device exposes, best first.
        let kinds: [Kind]

        var primaryKind: Kind { kinds.first ?? .other }
        var adoptableKind: Kind? { kinds.first(where: { $0.adoptable }) }

        static func == (l: Entry, r: Entry) -> Bool {
            l.id == r.id && l.name == r.name && l.transport == r.transport
        }
    }

    @Published private(set) var entries: [Entry] = []

    private var manager: IOHIDManager?
    /// Interfaces per entry, in adoption priority order.
    private var interfaces: [String: [(kind: Kind, device: IOHIDDevice)]] = [:]
    private var entryIDByDevice: [ObjectIdentifier: String] = [:]

    /// Vendor/product pairs the user connected by hand. Persisted so the
    /// device reconnects on its own the next time it is plugged in.
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
    }

    func entries(on transport: Transport) -> [Entry] {
        entries.filter { $0.transport == transport }
    }

    /// The interface to open for an entry: the gamepad interface when there
    /// is one, else the first vendor-defined or unclassified one.
    func adoptableDevice(for entry: Entry) -> IOHIDDevice? {
        interfaces[entry.id]?.first(where: { $0.kind.adoptable })?.device
    }

    /// Every interface of an entry, so "in use" can be answered for any of
    /// them (the gamepad service may hold its own reference to the device).
    func devices(for entry: Entry) -> [IOHIDDevice] {
        interfaces[entry.id]?.map(\.device) ?? []
    }

    // MARK: - Remembered manual connections

    static func rememberedPairs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: rememberedKey) ?? [])
    }

    static func pairKey(vendorID: Int32, productID: Int32) -> String {
        String(format: "%04x:%04x", vendorID, productID)
    }

    static func remember(vendorID: Int32, productID: Int32, _ on: Bool) {
        var set = rememberedPairs()
        let key = pairKey(vendorID: vendorID, productID: productID)
        if on { set.insert(key) } else { set.remove(key) }
        UserDefaults.standard.set(Array(set).sorted(), forKey: rememberedKey)
    }

    static func isRemembered(vendorID: Int32, productID: Int32) -> Bool {
        rememberedPairs().contains(pairKey(vendorID: vendorID, productID: productID))
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
        // Built-in parts of the Mac (keyboard, trackpad, sensors, Touch
        // Bar) and the virtual devices macOS creates are not something a
        // user would connect; only external hardware belongs in the menu.
        if builtIn { return }
        // The one virtual device worth showing: macOS creates "Headset
        // Audio" (a consumer-control device on the "Audio" transport) for the
        // buttons and tap gestures of a connected Bluetooth headset or
        // hearing aid. Its presses arrive as media keys, so list it under
        // Bluetooth and say how to bind it.
        let isHeadsetBridge = usagePage == 0x0C && vid == 0
            && transportRaw.lowercased() == "audio"
            && (name ?? "").localizedCaseInsensitiveContains("headset")
        if transport == .other && !isHeadsetBridge {
            let internalTransports = ["spu", "spi", "spmi", "fifo", "virtual", "airplay", ""]
            if internalTransports.contains(transportRaw.lowercased()) { return }
            if vid == 0 { return }
        }
        if isHeadsetBridge { transport = .bluetooth }

        let kind: Kind
        switch (usagePage, usage) {
        case (0x01, 0x04), (0x01, 0x05), (0x01, 0x08): kind = .gamepad
        case (0x01, 0x06), (0x01, 0x07): kind = .keyboard
        case (0x01, 0x01), (0x01, 0x02), (0x0D, _): kind = .pointer
        case (0x0C, _): kind = .consumer
        case (0xFF00...0xFFFF, _): kind = .vendor
        default: kind = .other
        }

        let manufacturer = (prop(kIOHIDManufacturerKey) as? String)?.trimmingCharacters(in: .whitespaces)
        let serial = (prop(kIOHIDSerialNumberKey) as? String) ?? ""
        let location = (prop(kIOHIDLocationIDKey) as? NSNumber)?.uint64Value ?? 0
        // One entry per physical device: same vendor, product, and either
        // the same serial or the same bus location.
        let entryID = String(format: "%04x:%04x:%@", vid, pid, serial.isEmpty ? String(location) : serial)
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
        // Best interface first: gamepad, then vendor, then the rest.
        func rank(_ k: Kind) -> Int {
            switch k { case .gamepad: return 0; case .vendor: return 1; case .other: return 2
                       case .consumer: return 3; case .keyboard: return 4; case .pointer: return 5 }
        }
        list.sort { rank($0.kind) < rank($1.kind) }
        interfaces[entryID] = list

        let entry = Entry(id: entryID, name: displayName, vendorID: vid, productID: pid,
                          transport: transport, kinds: list.map(\.kind))
        if let i = entries.firstIndex(where: { $0.id == entryID }) {
            entries[i] = entry
        } else {
            entries.append(entry)
            entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        // A device the user connected by hand before comes back on its own.
        if kind.adoptable, Self.isRemembered(vendorID: vid, productID: pid),
           !RawHIDGamepadService.shared.isOpen(device) {
            RawHIDGamepadService.shared.adopt(device, remember: false)
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
}
