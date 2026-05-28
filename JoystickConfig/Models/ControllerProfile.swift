import Foundation

/// Static description of how to decode a HID report for a specific
/// (vendor, product) pair. Lets `RawHIDGamepadService` pull buttons,
/// axes, triggers, and hat directions out of the raw byte stream
/// without needing to parse the device's HID descriptor at runtime.
///
/// Profiles are matched in order: vendor + product, then vendor + PID
/// range, then `ReportLayout.generic` falls back to descriptor parsing
/// at runtime (see `HIDDescriptorParser`).
struct ControllerProfile: Equatable {

    let identifier: String
    let displayName: String
    let vendorID: Int32
    let productMatches: [ProductMatch]
    let layout: ReportLayout
    let physicalButtonNames: [String]

    /// How to match a device's product ID against this profile.
    enum ProductMatch: Equatable {
        case exact(Int32)
        case range(ClosedRange<Int32>)

        func matches(_ pid: Int32) -> Bool {
            switch self {
            case .exact(let value): return pid == value
            case .range(let r): return r.contains(pid)
            }
        }
    }

    /// Pre-baked decoder layouts. Each case knows the byte offsets and
    /// bit positions for its specific report format.
    enum ReportLayout: Equatable {
        /// Standard Xbox 360 / XInput 20-byte report. Covers 8BitDo
        /// Ultimate 2C (XInput mode), generic Xbox 360 wired pads,
        /// Logitech F310/F710 in XInput mode, and most "PC Game
        /// Controller" wired pads that ship with XInput as default.
        case xinput

        /// Sony DualShock 3 HID layout (49-byte report). Buttons in
        /// bytes 2-4, sticks in 6-9, pressure-sensitive buttons in
        /// 14-25. Connected via USB only (Bluetooth requires pairing
        /// tools outside the app's scope).
        case dualShock3

        /// Layout synthesized at runtime by walking the HID descriptor.
        /// Used for unknown (vendor, product) pairs so the controller
        /// still works without a hand-coded entry.
        case generic(GenericLayout)
    }

    /// Output of `HIDDescriptorParser`. Encodes where buttons and axes
    /// live in the report for an arbitrary HID gamepad.
    struct GenericLayout: Equatable {
        var buttonBitOffsets: [Int]      // Bit index of each button in the report
        var axisByteOffsets: [Int]       // Byte offset of each axis
        var axisByteWidths: [Int]        // Per-axis: 1 (8-bit) or 2 (16-bit); parallel to axisByteOffsets
        var axisIsSignedFlags: [Bool]    // Per-axis: signed-centred-at-0 vs unsigned-centred-at-midpoint
        var hatByteOffset: Int?          // Byte that holds the 4-bit hat direction (8-direction or no-press = 0x0F)
        var triggerByteOffsets: [Int]    // Byte offsets of analogue triggers (0-255)
        var reportSize: Int              // Expected total bytes (excluding leading report ID if present)
        var hasReportID: Bool            // True if first byte is a report ID we should skip
    }
}

extension ControllerProfile {

    /// Returns true if this profile claims the given (vid, pid).
    func matches(vendorID vid: Int32, productID pid: Int32) -> Bool {
        guard vid == vendorID else { return false }
        return productMatches.contains { $0.matches(pid) }
    }
}
