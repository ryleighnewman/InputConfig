import Foundation

/// One raw report with what the app must make of it. The corpus in
/// Models/Fixtures feeds these through the real decoders from the test
/// bench, so every byte offset the app relies on is exercised without
/// hardware. Hex strings, not byte arrays: a report pastes unchanged from
/// `log stream`, the capture hook or a Wireshark dump and diffs as one line.
struct HIDFixture: Identifiable {
    enum Transport: String { case usb, bluetooth, dongle, helperLine, feature, cgEvent }

    /// verified = captured on hardware or a primary source byte for byte;
    /// reconstructed = assembled from logged scalars plus a documented
    /// layout; unverified = a single secondary source (recorded as info).
    enum Status: String { case verified, reconstructed, unverified }

    /// Which decoder the bench hands the bytes to.
    enum Route {
        /// ControllerProfileDatabase lookup, then HIDReportDecoder.decode.
        case rawHID(vendorID: Int32, productID: Int32, transport: String?)
        /// HIDDescriptorParser.parseExtended on `bytes`, then decodeGeneric.
        case descriptor(name: String, bytes: [UInt8], vendorID: Int32, productID: Int32, version: Int32)
        /// AccessControllerPortService.decode.
        case accessPorts
        /// parseProfile, encode round trip, writePackets, setActiveCommand.
        case accessProfile(number: Int)
        /// DualSenseSupplementService static button decode.
        case dualSenseSupplement(productID: Int32)
        /// DualSenseEdgeProfiles.parse on three 64-byte reports concatenated.
        case edgeProfile
        /// The Steam Controller helper's report parser.
        case steamHelperReport
        /// SteamControllerService state line parser.
        case steamHelperLine
        /// EightBitDoDetector mode from a product ID and name.
        case eightBitDoMode(productID: Int32, name: String, listed: Bool)
        /// Golden bytes from a pure output builder.
        case outputReport(builder: OutputBuilder)
        /// ExternalInputDeviceService static decoders.
        case externalInput
    }

    enum Expect: Equatable {
        case button(Int, Float), buttonAbsent(Int)
        case axis(Int, Float, tolerance: Float), axisAbsent(Int)
        case hat(Int, x: Float, y: Float)
        case motion(MotionChannel, Float, tolerance: Float)
        case relativeSteps(Int, Int)
        case accessPort(Int, AccessControllerPortService.PortDevice?)
        case activeProfile(Int), switchingDisabled(Bool), battery(level: Int, state: String)
        case supplementByte(UInt8?)
        /// decode returns nil or leaves the state untouched.
        case ignored
        /// Output reports: the exact buffer handed to HIDWrite.
        case bytes([UInt8])
        case bytesPrefix([UInt8])
        case crcValid(Bool)
        /// A named "key=value" check against the facts a route reports.
        case custom(String)
    }

    struct Citation {
        let source: String
        let locator: String
        let date: String
    }

    /// "access.usb.rest.e1stick" or "sim.g923.switch".
    let id: String
    let device: String
    let transport: Transport
    let route: Route
    let reportID: UInt8
    /// The IOHID callback buffer exactly, report ID first; spaces, newlines
    /// and 0x prefixes are ignored.
    let hex: String
    let expect: [Expect]
    let status: Status
    let citation: Citation

    var bytes: [UInt8] { HIDFixture.parse(hex) }

    /// Bytes from a hex string, tolerant of spaces, newlines, commas and 0x
    /// prefixes. An unparsable string gives an empty array; the lint uses
    /// `parseStrict` to tell the two apart.
    static func parse(_ hex: String) -> [UInt8] {
        parseStrict(hex) ?? []
    }

    /// nil when the string has a non-hex character or an odd digit count.
    static func parseStrict(_ hex: String) -> [UInt8]? {
        var digits: [UInt8] = []
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",_"))
        for token in hex.components(separatedBy: separators) where !token.isEmpty {
            var body = Substring(token)
            if body.hasPrefix("0x") || body.hasPrefix("0X") { body = body.dropFirst(2) }
            for character in body {
                guard let value = character.hexDigitValue else { return nil }
                digits.append(UInt8(value))
            }
        }
        guard digits.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(digits.count / 2)
        var i = 0
        while i < digits.count {
            out.append(digits[i] << 4 | digits[i + 1])
            i += 2
        }
        return out
    }

    /// Two lowercase digits per byte, space separated.
    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}

/// Ordered reports where behavior depends on history: dedupe, pulses, rest
/// learning, port sync, debounce, replay.
struct HIDSequenceFixture: Identifiable {
    struct Step {
        let delayMs: Int
        let reportID: UInt8
        let hex: String
        let expect: [HIDFixture.Expect]
    }
    let id: String
    let route: HIDFixture.Route
    let steps: [Step]
    let status: HIDFixture.Status
    let citation: HIDFixture.Citation
}

/// One pure builder per writer, so the bench asserts the bytes the app
/// sends. `OutputBuilders.bytes(for:)` (Fixtures+Output.swift) resolves
/// each case to the static builder that owns it.
enum OutputBuilder {
    case dualSenseLight(pid: Int32, transport: String, rgb: (UInt8, UInt8, UInt8), brightness: UInt8, setup: Bool, motors: (UInt8, UInt8)?, sequence: UInt8)
    case triggerEffect(left: Int, right: Int, bluetooth: Bool, sequence: UInt8)
    case dualShock4Light(transport: String, rgb: (UInt8, UInt8, UInt8), motors: (UInt8, UInt8)?)
    case rawStartup(vendorID: Int32, productID: Int32, layout: String)
    case logitechRange(productID: Int32)
    case logitechNativeMode(productID: Int32, bcdDevice: Int)
    case switch2Commands(productID: Int32)
    case switch2Calibration(address: UInt32)
    case switch2PlayerLED(player: Int)
    case steam2026Setting(setting: UInt8, value: UInt16)
    case steam2026Rumble(speed: UInt16)
    case steam2026LizardOn
    case steamHelperFeature(name: String)
    case accessRead(number: Int)
    case accessWrite(number: Int, blob: [UInt8], packet: Int)
    case accessSetActive(Int)
    case accessLED(rgb: (UInt8, UInt8, UInt8), player: UInt8)
    case xboxBluetoothRumble(strong: UInt8, weak: UInt8, lt: UInt8, rt: UInt8)

    /// Every case name, for the coverage line; kept in the enum's order.
    static let caseNames: [String] = [
        "dualSenseLight", "triggerEffect", "dualShock4Light", "rawStartup",
        "logitechRange", "logitechNativeMode",
        "switch2Commands", "switch2Calibration", "switch2PlayerLED",
        "steam2026Setting", "steam2026Rumble", "steam2026LizardOn",
        "steamHelperFeature",
        "accessRead", "accessWrite", "accessSetActive", "accessLED",
        "xboxBluetoothRumble",
    ]

    var caseName: String {
        switch self {
        case .dualSenseLight: return "dualSenseLight"
        case .triggerEffect: return "triggerEffect"
        case .dualShock4Light: return "dualShock4Light"
        case .rawStartup: return "rawStartup"
        case .logitechRange: return "logitechRange"
        case .logitechNativeMode: return "logitechNativeMode"
        case .switch2Commands: return "switch2Commands"
        case .switch2Calibration: return "switch2Calibration"
        case .switch2PlayerLED: return "switch2PlayerLED"
        case .steam2026Setting: return "steam2026Setting"
        case .steam2026Rumble: return "steam2026Rumble"
        case .steam2026LizardOn: return "steam2026LizardOn"
        case .steamHelperFeature: return "steamHelperFeature"
        case .accessRead: return "accessRead"
        case .accessWrite: return "accessWrite"
        case .accessSetActive: return "accessSetActive"
        case .accessLED: return "accessLED"
        case .xboxBluetoothRumble: return "xboxBluetoothRumble"
        }
    }
}
