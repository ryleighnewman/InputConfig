import Foundation
import IOKit.hid

/// Pure builders for the reports RawHIDGamepadService sends when a pad connects.
enum RawHIDStartupCommands {
    /// One thing the service does at start-up, in order: a feature read
    /// whose result is discarded, or a report write.
    enum Step: Equatable {
        case getFeature(id: CFIndex, length: Int)
        case set(type: IOHIDReportType, id: CFIndex, bytes: [UInt8])
    }

    /// The start-up steps for one pad, in the order they are sent.
    /// `productName` is the device's raw HID product string (the ShanWan
    /// check reads it), not the display name.
    static func steps(for profile: ControllerProfile?, vendorID: Int32, productID: Int32,
                      productName: String = "") -> [Step] {
        var steps: [Step] = []
        // A DualShock 3 on USB stays silent until the host puts it in
        // operational mode. SDL_hidapi_ps3.c (and the kernel) read feature
        // reports 0xF2 (17 bytes) and 0xF5 (8 bytes), then send a one-byte
        // output report, which ShanWan clones skip (it sets them rumbling
        // non-stop). The 0xF4 feature report this app sent before follows
        // as a fallback. Without any of it the pad enumerates, opens, and
        // never emits a single input report.
        if let p = profile, case .dualShock3 = p.layout {
            steps.append(.getFeature(id: 0xF2, length: 17))
            steps.append(.getFeature(id: 0xF5, length: 8))
            let shanWan = vendorID == 0x2563 || vendorID == 0x20BC
                || (vendorID == 0x054C && productName.lowercased().hasPrefix("shanwan"))
            if !shanWan {
                steps.append(.set(type: kIOHIDReportTypeOutput, id: 0xF5, bytes: [0xF5]))
            }
            steps.append(.set(type: kIOHIDReportTypeFeature, id: 0xF4, bytes: [0x42, 0x0C, 0x00, 0x00]))
        }
        // A Logitech wheel in its own mode: its range set to 900 degrees as
        // SDL does when it opens one, so the angle the Live Visualizer
        // shows is the wheel's real one.
        if vendorID == LogitechWheel.vendor, let commands = LogitechWheel.rangeCommands(product: productID) {
            for command in commands {
                steps.append(.set(type: kIOHIDReportTypeOutput, id: 0, bytes: command))
            }
        }
        // The GameCube controller adapter (WUP-028) reports nothing until
        // the host sends the one-byte 0x13 start command on its output
        // endpoint.
        if vendorID == 0x057E && productID == 0x0337 {
            steps.append(.set(type: kIOHIDReportTypeOutput, id: 0x13, bytes: [0x13]))
        }
        return steps
    }

    /// Only the reports written, for the bench's output fixtures.
    static func reports(for profile: ControllerProfile?, vendorID: Int32, productID: Int32,
                        productName: String = "") -> [(type: IOHIDReportType, id: CFIndex, bytes: [UInt8])] {
        steps(for: profile, vendorID: vendorID, productID: productID, productName: productName).compactMap { step in
            if case .set(let type, let id, let bytes) = step { return (type, id, bytes) }
            return nil
        }
    }

    /// True for the GameCube adapter's start command, the one write whose
    /// refusal the service reports.
    static func isGameCubeStart(_ step: Step, vendorID: Int32, productID: Int32) -> Bool {
        guard vendorID == 0x057E && productID == 0x0337 else { return false }
        if case .set(_, 0x13, _) = step { return true }
        return false
    }
}
