import Foundation
import CoreBluetooth

/// Switch 2 controllers over Bluetooth LE: the Pro Controller, the GameCube
/// controller and the Joy-Con 2, each on its own.
///
/// macOS has no driver for them: paired or not, they never become HID
/// devices, so neither GameController nor IOHIDManager lists them. They
/// speak a custom GATT service instead, and CoreBluetooth alone reaches it
/// (caqlayan/procon2-mac BLEController.swift, which this follows; the
/// handles and UUIDs come from darthcloud/BlueRetro sw2.h and
/// Nohzockt/Switch2-Controllers). Each input notification is the body of
/// USB input report 0x05 without the report ID, so the report is rebuilt
/// with the ID in front and read by the same decoders as over USB, motion
/// sensors included.
///
/// Off by default, switched on in Settings, Devices: scanning asks the
/// system for Bluetooth access (NSBluetoothAlwaysUsageDescription), which
/// nobody without one of these controllers should be asked for. While on,
/// the central scans whenever no controller is connected, connects to every
/// Switch 2 controller it finds, and lists each as a raw pad with the
/// transport "Bluetooth LE". Not checked on a controller: none was on hand.
final class Switch2BluetoothService: NSObject, @unchecked Sendable {
    static let shared = Switch2BluetoothService()

    static let enabledKey = "InputConfig.switch2Bluetooth"

    nonisolated(unsafe) static let nintendoService = CBUUID(string: "AB7DE9BE-89FE-49AD-828F-118F09DF7FD0")
    /// Input reports, notify (BlueRetro handle 0x000A).
    nonisolated(unsafe) static let inputCharacteristic = CBUUID(string: "AB7DE9BE-89FE-49AD-828F-118F09DF7FD2")
    /// The command channel, write without response (handle 0x0014).
    nonisolated(unsafe) static let commandCharacteristic = CBUUID(string: "649D4AC9-8EB7-4E6C-AF44-1EA54FE5F005")

    static let vendorID: Int32 = 0x057E

    /// The player 1 light, so the controller shows it is connected: the
    /// USB LED command with the interface byte 0x01 for Bluetooth
    /// (BlueRetro sw2.c sw2_set_leds).
    static let playerOneLightCommand: [UInt8] = [0x09, 0x91, 0x01, 0x07, 0x00, 0x08, 0x00, 0x00,
                                                 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]

    /// The product behind an advertisement. Nintendo's manufacturer data
    /// (ndeadly/switch2_controller_research bluetooth_interface.md), as
    /// CoreBluetooth hands it with the company ID in front: bytes 0 and 1
    /// company 0x0553, 2 to 4 fixed 01 00 03, 5 and 6 the vendor 0x057E
    /// little endian, 7 and 8 the product little endian (69 20 is the Pro
    /// Controller 0x2069). The name is the fallback (procon2-mac matches
    /// "Pro Controller", "Joy-Con" and "Nintendo"). Nil for anything that
    /// is not a Switch 2 controller the app reads.
    static let products: Set<Int32> = [Int32(Switch2USBEnabler.proControllerProductID), Int32(Switch2USBEnabler.gameCubeProductID),
                                       Int32(Switch2USBEnabler.joyConLeftProductID), Int32(Switch2USBEnabler.joyConRightProductID)]
    static func productID(name: String?, manufacturerData: Data?) -> Int32? {
        if let m = manufacturerData, m.count >= 9, m[0] == 0x53, m[1] == 0x05, m[5] == 0x7E, m[6] == 0x05 {
            let pid = Int32(m[7]) | Int32(m[8]) << 8
            return products.contains(pid) ? pid : nil
        }
        let n = (name ?? "").lowercased()
        if n.contains("joy-con") || n.contains("joycon") {
            if n.contains("(l)") || n.hasSuffix(" l") { return Int32(Switch2USBEnabler.joyConLeftProductID) }
            if n.contains("(r)") || n.hasSuffix(" r") { return Int32(Switch2USBEnabler.joyConRightProductID) }
            return nil
        }
        if n.contains("gamecube") { return Int32(Switch2USBEnabler.gameCubeProductID) }
        if n.contains("pro controller") { return Int32(Switch2USBEnabler.proControllerProductID) }
        return nil
    }

    /// The feature flags each controller type is given at start, as the
    /// console does (ndeadly commands.md): bit 0 buttons, bit 1 sticks,
    /// bit 2 the IMU, bit 5 rumble, bit 4 the Joy-Con 2 mouse sensor. Set
    /// with 0x0C/0x02, then confirmed with 0x0C/0x04; interface byte 0x01
    /// for Bluetooth. Without bit 2 the motion bytes of report 0x05 stay zero.
    static func featureFlags(productID: Int32) -> UInt8 {
        switch Int(productID) {
        case Switch2USBEnabler.joyConLeftProductID, Switch2USBEnabler.joyConRightProductID: return 0x37
        case Switch2USBEnabler.gameCubeProductID: return 0x27
        default: return 0x2F
        }
    }
    static func featureCommands(productID: Int32) -> [[UInt8]] {
        let flags = featureFlags(productID: productID)
        return [[0x0C, 0x91, 0x01, 0x02, 0x00, 0x04, 0x00, 0x00, flags, 0x00, 0x00, 0x00],
                [0x0C, 0x91, 0x01, 0x04, 0x00, 0x04, 0x00, 0x00, flags, 0x00, 0x00, 0x00]]
    }

    /// The HID report a notification stands for: input report 0x05 with
    /// the ID in front, as the USB decoders read it.
    static func report(fromNotification value: Data) -> Data {
        var out = Data([0x05])
        out.append(value)
        return out
    }

    // MARK: - State

    private let queue = DispatchQueue(label: "com.inputconfig.switch2-bluetooth", qos: .userInitiated)
    private let lock = NSLock()
    private var central: CBCentralManager?
    private var enabled = false
    private struct Link {
        let peripheral: CBPeripheral
        let productID: Int32
        let name: String
        var key: UInt64?
        var command: CBCharacteristic?
    }
    private var links: [UUID: Link] = [:]
    private var pending: [UUID: CBPeripheral] = [:]

    private override init() { super.init() }

    /// Starts when the setting is on, at app launch.
    func startIfEnabled() {
        if UserDefaults.standard.bool(forKey: Self.enabledKey) { setEnabled(true) }
    }

    /// The Settings toggle. On: a central is made and scans. Off: every
    /// controller is dropped and the central released.
    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        lock.lock()
        enabled = on
        if on, central == nil {
            central = CBCentralManager(delegate: self, queue: queue)
            lock.unlock()
            Switch2BluetoothStatus.post(String(localized: "Looking for a Switch 2 controller…"))
            return
        }
        let c = central
        let open = links
        if !on { central = nil; links = [:]; pending = [:] }
        lock.unlock()
        guard !on else { return }
        c?.stopScan()
        for link in open.values {
            c?.cancelPeripheralConnection(link.peripheral)
            if let key = link.key { detach(key) }
        }
        Switch2BluetoothStatus.post(nil)
    }

    /// Closes the link of the controller listed under `key` (idle
    /// disconnect). The search starts again when the link is gone.
    func disconnect(key: UInt64) {
        lock.lock()
        let peripheral = links.values.first { $0.key == key }?.peripheral
        let c = central
        lock.unlock()
        if let peripheral { c?.cancelPeripheralConnection(peripheral) }
    }

    private func scan(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        // The service is not in the advertisement, so every peripheral is
        // looked at and filtered by name and manufacturer data.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        Switch2BluetoothStatus.post(String(localized: "Looking for a Switch 2 controller…"))
    }

    private func attach(productID: Int32, name: String, id: UUID) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let key = RawHIDGamepadService.shared.attachExternalPad(vendorID: Self.vendorID, productID: productID,
                                                                        transport: "Bluetooth LE", productName: name)
                self.lock.lock()
                self.links[id]?.key = key
                self.lock.unlock()
                if key == nil {
                    ActivityLog.shared.warning("Devices", "\(name): no profile for product \(String(format: "0x%04X", productID)) over Bluetooth LE")
                } else {
                    ActivityLog.shared.info("Devices", "\(name): connected over Bluetooth LE, read from report 0x05")
                }
            }
        }
    }

    private func detach(_ key: UInt64) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { RawHIDGamepadService.shared.detachExternalPad(key: key) }
        }
    }

    private func inject(_ key: UInt64, _ data: Data) {
        let bytes = [UInt8](Self.report(fromNotification: data))
        DispatchQueue.main.async {
            MainActor.assumeIsolated { RawHIDGamepadService.shared.injectExternal(key: key, reportID: 0x05, bytes: bytes) }
        }
    }
}

extension Switch2BluetoothService: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            scan(central)
        case .poweredOff:
            Switch2BluetoothStatus.post(String(localized: "Bluetooth is off"))
        case .unauthorized:
            Switch2BluetoothStatus.post(String(localized: "Bluetooth is not allowed for InputConfig; allow it in System Settings, Privacy & Security, Bluetooth"))
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        guard let productID = Self.productID(name: name, manufacturerData: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data) else { return }
        lock.lock()
        guard enabled, links[peripheral.identifier] == nil, pending[peripheral.identifier] == nil else { lock.unlock(); return }
        pending[peripheral.identifier] = peripheral
        let display = name ?? ControllerProfileDatabase.profile(forVendor: Self.vendorID, product: productID)?.displayName ?? "Switch 2 controller"
        links[peripheral.identifier] = Link(peripheral: peripheral, productID: productID, name: display, key: nil, command: nil)
        lock.unlock()
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        lock.lock(); pending.removeValue(forKey: peripheral.identifier); lock.unlock()
        peripheral.discoverServices([Self.nintendoService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        lock.lock()
        pending.removeValue(forKey: peripheral.identifier)
        links.removeValue(forKey: peripheral.identifier)
        lock.unlock()
        scan(central)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        lock.lock()
        let link = links.removeValue(forKey: peripheral.identifier)
        let on = enabled
        lock.unlock()
        if let key = link?.key { detach(key) }
        if let link { ActivityLog.shared.info("Devices", "\(link.name): Bluetooth LE link closed") }
        if on { scan(central) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.nintendoService }) else {
            ActivityLog.shared.warning("Devices", "\(peripheral.name ?? "Switch 2 controller"): no Nintendo service over Bluetooth LE")
            return
        }
        peripheral.discoverCharacteristics(nil, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let characteristics = service.characteristics ?? []
        guard let input = characteristics.first(where: { $0.uuid == Self.inputCharacteristic })
                ?? characteristics.first(where: { $0.properties.contains(.notify) }) else { return }
        peripheral.setNotifyValue(true, for: input)
        let command = characteristics.first { $0.uuid == Self.commandCharacteristic }
        lock.lock()
        links[peripheral.identifier]?.command = command
        let link = links[peripheral.identifier]
        let anyOpen = !links.isEmpty
        lock.unlock()
        if let command, let link {
            // The feature flags (motion on), then the player light, on the
            // basic command channel, where BlueRetro sends its lights and
            // flash reads.
            let type: CBCharacteristicWriteType = command.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
            for bytes in Self.featureCommands(productID: link.productID) + [Self.playerOneLightCommand] {
                peripheral.writeValue(Data(bytes), for: command, type: type)
            }
        }
        if let link { attach(productID: link.productID, name: link.name, id: peripheral.identifier) }
        if anyOpen { Switch2BluetoothStatus.post(String(localized: "Connected")) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.inputCharacteristic || characteristic.properties.contains(.notify),
              let value = characteristic.value, value.count >= 16 else { return }
        lock.lock()
        let key = links[peripheral.identifier]?.key
        lock.unlock()
        guard let key else { return }
        inject(key, value)
    }
}

/// The one line Settings shows about the Bluetooth LE search.
@MainActor
final class Switch2BluetoothStatus: ObservableObject {
    static let shared = Switch2BluetoothStatus()
    @Published private(set) var text: String?
    /// Set from the Bluetooth queue; lands on the main actor.
    nonisolated static func post(_ text: String?) {
        DispatchQueue.main.async { MainActor.assumeIsolated { Switch2BluetoothStatus.shared.text = text } }
    }
}
