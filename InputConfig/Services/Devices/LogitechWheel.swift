import Foundation

/// Logitech's force feedback wheels, read raw: what the generic descriptor
/// parser needs to read them the way the Linux driver (hid-lg4ff.c,
/// hid-lg.c) and SDL (SDL_hidapi_lg4ff.c) do.
///
/// - Every one of the older wheels describes gas and brake as one combined
///   axis and carries each pedal on its own in two later bytes, which the
///   kernel's fixed descriptors (hid-lg.c *_rdesc_fixed) name and the
///   lgff_wheel_adapter structs confirm byte for byte. Those two fields
///   are added here by hand, per model, and the combined axis dropped.
/// - A G29, G27, G25, Driving Force GT or Driving Force Pro starts in
///   Driving Force EX compatibility mode (046D:C294) unless Logitech's
///   software switches it, and a wheel another host switched down can sit
///   in a lower mode (a G29 as a G27). The 7 byte switch commands and the
///   bcdDevice masks are SDL's; the G923 for PlayStation (046D:C267)
///   switches with its own command on report 0x30 (new-lg4ff) and comes
///   back as the classic G923 (046D:C266).
/// - In every report the pedals follow the steering in the order gas,
///   brake, clutch, and rest at their maximum (255 released). They are put
///   on one plan for every model: steering axis 0, brake axis 4, gas axis 5
///   (the trigger slots, 0 at rest and 1 fully pressed), clutch axis 1.
enum LogitechWheel {
    static let vendor: Int32 = 0x046D

    /// Every wheel this file knows, by product ID.
    static let products: Set<Int32> = [0xC20E, 0xC293, 0xC294, 0xC295, 0xC298, 0xC299, 0xC29A, 0xC29B,
                                       0xC24F, 0xC266, 0xC267, 0xCA03, 0xCA04]

    static func isWheel(vendor v: Int32, product p: Int32) -> Bool { v == vendor && products.contains(p) }

    /// How far each wheel turns lock to lock, in degrees, for the Live
    /// Visualizer: 900 for the wheels `rangeCommands` sets to 900, the fixed
    /// range of the older ones (hid-lg4ff.c lg4ff_devices: Driving Force
    /// and MOMO 270, Formula 180). The Formula Vibration's range is in no
    /// source on disk; 240 is a guess.
    static func rotationDegrees(product: Int32) -> Double? {
        switch product {
        case 0xC294: return 270
        case 0xC298, 0xC299, 0xC29A, 0xC29B, 0xC24F, 0xC266: return 900
        case 0xC295, 0xCA03: return 270
        case 0xC20E, 0xC293: return 180
        case 0xCA04: return 240
        default: return nil
        }
    }

    /// The commands that set a wheel's range to 900 degrees, as SDL sends
    /// them when it opens one (SDL_hidapi_lg4ff.c, range command at init):
    /// one for the G29, G923, G27, G25 and Driving Force GT (hid-lg4ff.c
    /// lg4ff_set_range_g25: F8 81 lo hi), a coarse and a fine one for the
    /// Driving Force Pro, which otherwise starts at 200. nil for any other
    /// wheel, whose range stays as it is.
    static func rangeCommands(product: Int32) -> [[UInt8]]? {
        switch product {
        case 0xC24F, 0xC29B, 0xC299, 0xC29A, 0xC266:
            return [[0xF8, 0x81, 0x84, 0x03, 0x00, 0x00, 0x00]]
        case 0xC298:
            return [[0xF8, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00], [0x81, 0x0B, 0x00, 0x00, 0x00, 0x00, 0x00]]
        default:
            return nil
        }
    }

    // MARK: - Separate pedals

    /// Per wheel: the length of the original report descriptor the kernel
    /// gates its fixup on (hid-lg.c lg_report_fixup), the byte of the
    /// combined pedal axis, and the bytes of gas and brake, 8 bits each,
    /// 255 released (hid-lg.c df_rdesc_fixed, dfp_rdesc_fixed,
    /// momo_rdesc_fixed, momo2_rdesc_fixed, ffg_rdesc_fixed, fg_rdesc_fixed,
    /// fv_rdesc_fixed; lgff_wheel_adapter reports.h agrees on every byte).
    struct PedalBytes: Equatable { let descriptorLength: Int; let combined: Int; let gas: Int; let brake: Int }
    static let separatePedalWheels: [Int32: PedalBytes] = [
        0xC294: PedalBytes(descriptorLength: 130, combined: 3, gas: 5, brake: 6),   // Driving Force, Driving Force EX
        0xC298: PedalBytes(descriptorLength: 97, combined: 4, gas: 5, brake: 6),    // Driving Force Pro
        0xCA04: PedalBytes(descriptorLength: 130, combined: 3, gas: 5, brake: 6),   // Formula Vibration
        0xC295: PedalBytes(descriptorLength: 87, combined: 3, gas: 4, brake: 5),    // MOMO Force
        0xCA03: PedalBytes(descriptorLength: 87, combined: 3, gas: 4, brake: 5),    // MOMO Racing
        0xC293: PedalBytes(descriptorLength: 85, combined: 3, gas: 4, brake: 5),    // Formula Force GP
        0xC20E: PedalBytes(descriptorLength: 82, combined: 2, gas: 3, brake: 4),    // Formula GP
    ]

    /// Drops the combined pedal axis and adds gas and brake for the wheels
    /// whose descriptor names only the combined one. Any other descriptor
    /// is left as parsed.
    static func addSeparatePedals(_ layout: HIDExtendedLayout, descriptorLength: Int,
                                  vendor v: Int32, product p: Int32) -> HIDExtendedLayout {
        guard v == vendor, let pedals = separatePedalWheels[p], pedals.descriptorLength == descriptorLength,
              let r = layout.reports.firstIndex(where: { $0.reportID == nil }) else { return layout }
        var out = layout
        // The combined axis by position (which usage each original gives it
        // is only documented for the DF and DFP: Y), and by usage Y as before.
        out.reports[r].axes.removeAll { ($0.bitOffset == pedals.combined * 8 && $0.bitSize == 8) || ($0.usagePage == 0x01 && $0.usage == 0x31) }
        for (byte, usage) in [(pedals.gas, 0x32), (pedals.brake, 0x35)] where !out.reports[r].axes.contains(where: { $0.bitOffset == byte * 8 }) {
            out.reports[r].axes.append(HIDExtendedLayout.Axis(
                bitOffset: byte * 8, bitSize: 8, logicalMin: 0, logicalMax: 255, isSigned: false,
                usagePage: 0x01, usage: usage, index: 0, unipolar: false, digitalButton: nil))
        }
        out.reports[r].payloadSize = max(out.reports[r].payloadSize, pedals.brake + 1)
        return out
    }

    // MARK: - Steering and pedals

    /// Puts the parsed plan on the one wheel convention (see above): the
    /// steering stays on axis 0; the pedals, in report order gas, brake,
    /// clutch, go to axes 5, 4 and 1, read 0 at rest and 1 fully pressed.
    /// Any other axis the parser had put on 1, 4 or 5 (a G25, G27 or G29
    /// analog shifter) moves to the first free slot from 6, so no two
    /// fields of one report share an index.
    static func normalize(_ layout: HIDExtendedLayout, product: Int32? = nil) -> HIDExtendedLayout {
        var out = layout
        // Every axis but the steering, across reports, in report order.
        var pedals: [(report: Int, axis: Int, offset: Int)] = []
        for (r, report) in out.reports.enumerated() {
            for (a, axis) in report.axes.enumerated() where !(axis.usagePage == 0x01 && axis.usage == 0x30) {
                pedals.append((r, a, axis.bitOffset))
            }
        }
        pedals.sort { ($0.report, $0.offset) < ($1.report, $1.offset) }
        let slots = [5, 4, 1]
        var taken: Set<Int> = [0]
        var assigned: Set<Int> = []
        for (n, p) in pedals.prefix(slots.count).enumerated() {
            out.reports[p.report].axes[p.axis].index = slots[n]
            out.reports[p.report].axes[p.axis].unipolar = true
            out.reports[p.report].axes[p.axis].inverted = true
            out.reports[p.report].axes[p.axis].digitalButton = nil
            taken.insert(slots[n])
            assigned.insert(p.report << 16 | p.axis)
        }
        var next = 6
        for r in out.reports.indices {
            for a in out.reports[r].axes.indices where !assigned.contains(r << 16 | a) {
                let axis = out.reports[r].axes[a]
                guard !(axis.usagePage == 0x01 && axis.usage == 0x30) else { continue }
                if taken.contains(axis.index) || axis.index < 6 {
                    while taken.contains(next) { next += 1 }
                    out.reports[r].axes[a].index = next
                    out.reports[r].axes[a].unipolar = false
                    out.reports[r].axes[a].inverted = false
                    out.reports[r].axes[a].digitalButton = nil
                }
                taken.insert(out.reports[r].axes[a].index)
            }
        }
        for r in out.reports.indices { out.reports[r].axes.sort { $0.index < $1.index } }
        return out
    }

    // MARK: - Native mode

    /// The command that switches a wheel in a compatibility mode to its own
    /// mode, the wheel's name, and the output report the command goes on (0
    /// for an unnumbered report). The bcdDevice masks and commands are
    /// SDL_hidapi_lg4ff.c's (IdentifyWheel, the switch commands), which
    /// check them for a wheel reporting as DF EX (C294), DFP (C298), DFGT
    /// (C29A), G25 (C299) or G27 (C29B), since a wheel another host
    /// switched down sits in that lower mode. The G923 PS (C267) switch is
    /// new-lg4ff's lg4ff_switch_from_ps_mode, on report 0x30. nil for a
    /// wheel already in its own mode.
    static func nativeModeCommand(product: Int32, bcdDevice: Int) -> (name: String, bytes: [UInt8], reportID: UInt8)? {
        if product == 0xC267 {
            return ("G923", [0xF8, 0x09, 0x07, 0x01, 0x01, 0x00, 0x00], 0x30)
        }
        let isG29 = bcdDevice & 0xFFF8 == 0x1350 || bcdDevice & 0xFF00 == 0x8900
        let isDFGT = bcdDevice & 0xFF00 == 0x1300
        let isG27 = bcdDevice & 0xFFF0 == 0x1230
        let isG25 = bcdDevice & 0xFF00 == 0x1200
        let isDFP = bcdDevice & 0xF000 == 0x1000
        let g29: (String, [UInt8], UInt8) = ("G29", [0xF8, 0x09, 0x05, 0x01, 0x01, 0x00, 0x00], 0)
        let dfgt: (String, [UInt8], UInt8) = ("Driving Force GT", [0xF8, 0x09, 0x03, 0x01, 0x00, 0x00, 0x00], 0)
        let g27: (String, [UInt8], UInt8) = ("G27", [0xF8, 0x09, 0x04, 0x01, 0x00, 0x00, 0x00], 0)
        let g25: (String, [UInt8], UInt8) = ("G25", [0xF8, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00], 0)
        let dfp: (String, [UInt8], UInt8) = ("Driving Force Pro", [0xF8, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00], 0)
        switch product {
        case 0xC294:
            if isG29 { return g29 }
            if isDFGT { return dfgt }
            if isG27 { return g27 }
            if isG25 { return g25 }
            if isDFP { return dfp }
            return nil
        case 0xC298:
            if isG29 { return g29 }
            if isG27 { return g27 }
            if isG25 { return g25 }
            if isDFGT { return dfgt }
            return nil
        case 0xC29A:
            return isG29 ? g29 : nil
        case 0xC299:
            if isG29 { return g29 }
            if isG27 { return g27 }
            return nil
        case 0xC29B:
            return isG29 ? g29 : nil
        default:
            return nil
        }
    }
}
