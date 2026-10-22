import Foundation
import IOKit.hid
import os

/// The DualSense Edge's four stored profiles, read over USB through feature
/// reports 0x70 to 0x7B: three 64-byte reports per profile, in the order
/// FN + Triangle (0x70), FN + Square (0x73), FN + Cross (0x76) and
/// FN + Circle (0x79). Read once per connection, never written. The layout
/// follows the open DualSense Edge profile editors (steffalon's web app,
/// ds-edge-configurator); the controller itself names the slots.
///
/// What the app does with it: show which profiles the pad carries and what
/// each remaps, so a user whose Edge swaps two buttons can see why a row
/// fires from the other button. The Edge applies the profile inside the
/// controller, so what GameController reports is already remapped.
enum DualSenseEdgeProfiles {

    private static let log = Logger(subsystem: "com.inputconfig", category: "EdgeProfiles")

    /// The combination that switches to a profile on the pad.
    enum Slot: Int, CaseIterable {
        case triangle = 0x70, square = 0x73, cross = 0x76, circle = 0x79
        var name: String {
            switch self {
            case .triangle: return String(localized: "FN + Triangle")
            case .square: return String(localized: "FN + Square")
            case .cross: return String(localized: "FN + Cross")
            case .circle: return String(localized: "FN + Circle")
            }
        }
    }

    /// The pad's own button codes in a profile's map: the index is the
    /// physical button, the value what it sends.
    static let buttonNames: [Int: String] = [
        0x00: "Up", 0x01: "Left", 0x02: "Down", 0x03: "Right", 0x04: "Circle", 0x05: "Cross",
        0x06: "Square", 0x07: "Triangle", 0x08: "R1", 0x09: "R2", 0x0A: "R3", 0x0B: "L1",
        0x0C: "L2", 0x0D: "L3", 0x0E: "Left paddle", 0x0F: "Right paddle", 0x10: "Options", 0x11: "Touchpad",
    ]

    static let stickCurveNames: [Int: String] = [
        0: "Default", 1: "Quick", 2: "Precise", 3: "Steady", 4: "Digital", 5: "Dynamic",
    ]

    struct Profile: Equatable {
        var slot: Slot
        /// False for a slot the pad lists but nothing was saved into.
        var assigned: Bool
        var name: String
        /// Sixteen entries, physical button to the code it sends, in the
        /// pad's order: Up, Left, Down, Right, Circle, Cross, Square,
        /// Triangle, R1, R2, R3, L1, L2, L3, left paddle, right paddle.
        var buttonMap: [Int]
        var leftTrigger: (min: Int, max: Int)
        var rightTrigger: (min: Int, max: Int)
        var leftStickCurve: Int
        var rightStickCurve: Int

        static func == (a: Profile, b: Profile) -> Bool {
            a.slot == b.slot && a.assigned == b.assigned && a.name == b.name && a.buttonMap == b.buttonMap
                && a.leftTrigger == b.leftTrigger && a.rightTrigger == b.rightTrigger
                && a.leftStickCurve == b.leftStickCurve && a.rightStickCurve == b.rightStickCurve
        }

        /// The buttons this profile sends as something else, as
        /// "Cross sends Circle", for the controller's description.
        var remaps: [String] {
            buttonMap.enumerated().compactMap { index, code in
                guard code != index, code != 0xFF, let from = DualSenseEdgeProfiles.buttonNames[index],
                      let to = DualSenseEdgeProfiles.buttonNames[code] else { return nil }
                return "\(from) sends \(to)"
            }
        }
    }

    /// Reads every profile the pad answers for. USB only: the reports are
    /// not in the Bluetooth descriptor.
    static func read(_ device: IOHIDDevice) -> [Profile] {
        var out: [Profile] = []
        for slot in Slot.allCases {
            var buffers: [[UInt8]] = []
            for id in slot.rawValue..<(slot.rawValue + 3) {
                var buf = [UInt8](repeating: 0, count: 64)
                var len: CFIndex = 64
                let got = buf.withUnsafeMutableBufferPointer { p in
                    IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(id), p.baseAddress!, &len)
                }
                guard got == kIOReturnSuccess, len == 64 else { buffers = []; break }
                buffers.append(buf)
            }
            guard buffers.count == 3, let profile = parse(buffers, slot: slot) else {
                log.notice("\(slot.name, privacy: .public): no answer")
                continue
            }
            out.append(profile)
            log.notice("\(slot.name, privacy: .public): \(profile.assigned ? "\"\(profile.name)\"" : "unassigned", privacy: .public) \(profile.remaps.joined(separator: ", "), privacy: .public) triggers L \(profile.leftTrigger.min, privacy: .public)...\(profile.leftTrigger.max, privacy: .public) R \(profile.rightTrigger.min, privacy: .public)...\(profile.rightTrigger.max, privacy: .public) sticks \(stickCurveNames[profile.leftStickCurve] ?? "?", privacy: .public)/\(stickCurveNames[profile.rightStickCurve] ?? "?", privacy: .public)")
        }
        return out
    }

    /// The three reports of one slot, each with its report ID in byte 0.
    static func parse(_ b: [[UInt8]], slot: Slot) -> Profile? {
        guard b.count == 3, b.allSatisfy({ $0.count == 64 }) else { return nil }
        // A slot nothing was saved into reads 0x10 in its second byte.
        let assigned = b[0][1] != 0x10
        var name = ""
        if assigned {
            // UTF-16LE: 27 characters in the first report from byte 6, 13
            // more in the second from byte 2.
            var units: [UInt16] = []
            for i in stride(from: 6, to: 60, by: 2) { units.append(UInt16(b[0][i]) | UInt16(b[0][i + 1]) << 8) }
            for i in stride(from: 2, to: 28, by: 2) { units.append(UInt16(b[1][i]) | UInt16(b[1][i + 1]) << 8) }
            for u in units {
                if u == 0 { break }
                if let scalar = Unicode.Scalar(u) { name.unicodeScalars.append(scalar) }
            }
        }
        let map = assigned ? Array(b[2][10..<26]).map(Int.init) : Array(0..<16)
        return Profile(slot: slot, assigned: assigned, name: name, buttonMap: map,
                       leftTrigger: (Int(b[2][4]), Int(b[2][5])), rightTrigger: (Int(b[2][6]), Int(b[2][7])),
                       leftStickCurve: Int(b[2][30]), rightStickCurve: Int(b[2][32]))
    }
}
