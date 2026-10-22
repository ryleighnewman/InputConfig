import Foundation
import IOKit.hid

/// Third party PlayStation pads and sticks (Hori, Nacon, Razer, PDP,
/// Victrix, Qanba, Mad Catz, PowerA, Mayflash, GP2040-CE boards) speak the
/// DualShock 4 or DualSense protocol and answer feature report 0x03 with
/// their capabilities, as SDL_hidapi_ps4.c and SDL_hidapi_ps5.c read it:
/// 48 bytes, [2] 0x27 for the PS4 family and 0x28 for the PS5 family, [4]
/// capabilities (0x02 sensors, 0x04 light bar, 0x08 vibration, 0x40
/// touchpad), [5] the device type (0 gamepad, 1 guitar, 2 drums, 4 dance
/// pad, 6 wheel, 7 arcade stick, 8 flight stick).
enum PlayStationCapabilityProbe {
    enum Family: String { case playStation4, playStation5 }
    enum DeviceType: UInt8 { case gamepad = 0, guitar = 1, drums = 2, dancePad = 4, wheel = 6, arcadeStick = 7, flightStick = 8 }

    struct Capabilities: Equatable {
        var family: Family
        var deviceType: DeviceType?
        var sensors: Bool
        var lightBar: Bool
        var vibration: Bool
        var touchpad: Bool
    }

    static let featureReportID: CFIndex = 0x03
    static let featureReportLength = 48

    /// The vendors SDL asks (HIDAPI_SupportsPlaystationDetection in
    /// SDL_hidapijoystick.c): CRKD, DragonRise, Corsair, Hori, Mad Catz,
    /// Mayflash, Nacon (two IDs), PDP, PowerA (two IDs), Qanba, Red Octane,
    /// ShanWan (two IDs), Zeroplus, plus GP2040-CE's own IDs (0x1209
    /// Generic, 0x2B81 PS5 mode). Razer is NOT asked: some Razer devices
    /// lock up or reset on the query (SDL issues 6733 and 6799); its pads
    /// come in by product ID through the class sets. Logitech and
    /// Thrustmaster are wheels and are read by their own plans.
    static let vendors: Set<Int32> = [0x3651, 0x0079, 0x1B1C, 0x0F0D, 0x0738, 0x33DF, 0x146B, 0x3285, 0x0E6F,
                                      0x24C6, 0x20D6, 0x2C22, 0x1430, 0x2563, 0x20BC, 0x0C12, 0x1209, 0x2B81]

    static func shouldProbe(vendorID: Int32, productID: Int32) -> Bool {
        if vendors.contains(vendorID) { return true }
        let id = Int(vendorID) << 16 | Int(productID)
        return SDLGameControllerDB.playStation4Class.contains(id) || SDLGameControllerDB.playStation5Class.contains(id)
    }

    /// Decodes a feature report 0x03 answer; nil when it is not one.
    static func parse(_ bytes: [UInt8]) -> Capabilities? {
        guard bytes.count >= featureReportLength, bytes[0] == 0x03 else { return nil }
        let family: Family
        switch bytes[2] {
        case 0x27: family = .playStation4
        case 0x28: family = .playStation5
        default: return nil
        }
        let caps = bytes[4]
        return Capabilities(family: family, deviceType: DeviceType(rawValue: bytes[5]),
                            sensors: caps & 0x02 != 0, lightBar: caps & 0x04 != 0,
                            vibration: caps & 0x08 != 0, touchpad: caps & 0x40 != 0)
    }

    /// Opens the device briefly and reads the capability report. Logs the
    /// answer or the refusal; nil when the pad does not speak the protocol.
    static func probe(_ device: IOHIDDevice, name: String) -> Capabilities? {
        let opened = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard opened == kIOReturnSuccess else {
            ActivityLog.shared.info("Devices", "\(name): could not open it to ask for its PlayStation capability report (error \(opened))")
            return nil
        }
        defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
        var buf = [UInt8](repeating: 0, count: featureReportLength)
        var len: CFIndex = CFIndex(featureReportLength)
        let got = buf.withUnsafeMutableBufferPointer { p in
            HIDRead.getReport(device, kIOHIDReportTypeFeature, featureReportID, p.baseAddress!, &len)
        }
        guard got == kIOReturnSuccess else {
            ActivityLog.shared.info("Devices", "\(name): no PlayStation capability report (feature 0x03 refused, error \(got))")
            return nil
        }
        let caps = parse(Array(buf.prefix(Int(len))))
        if let caps {
            ActivityLog.shared.info("Devices", "\(name): \(caps.family == .playStation4 ? "PS4" : "PS5") protocol, \(caps.deviceType.map { "\($0)" } ?? "device type \(buf[5])")\(caps.touchpad ? ", touchpad" : "")\(caps.sensors ? ", motion" : "")")
        } else {
            ActivityLog.shared.info("Devices", "\(name): feature 0x03 answered \(len) bytes with [2] = \(String(format: "0x%02X", buf[2])), not a PlayStation capability report")
        }
        return caps
    }

    /// The fixed layout profile for a pad that answered.
    static func profile(for caps: Capabilities, vendorID: Int32, productID: Int32, productName: String) -> ControllerProfile {
        return ControllerProfile(
            identifier: "\(caps.family == .playStation4 ? "ps4" : "ps5")-class-\(vendorID)-\(productID)",
            displayName: productName,
            vendorID: vendorID,
            productMatches: [.exact(productID)],
            layout: caps.family == .playStation4 ? .dualShock4 : .dualSenseAlt,
            physicalButtonNames: ControllerProfileDatabase.dualShock4ButtonNames
        )
    }
}
