import Foundation

/// Logitech's force feedback wheels, read raw: what the generic descriptor
/// parser needs to read them the way SDL (SDL_hidapi_lg4ff.c, zlib
/// license) does.
///
/// - The Driving Force (046D:C294) and Driving Force Pro (046D:C298)
///   describe gas and brake as one combined axis. Their reports also carry
///   each pedal on its own, in bytes 5 and 6, which is where SDL reads
///   them; those two fields are added here by hand. The other older wheels
///   (Formula GP, Formula Force GP, MOMO, MOMO Racing, Formula Vibration)
///   are read as their descriptors describe them, with the combined pedal
///   axis as one centered axis.
/// - A G29, G27, G25, Driving Force GT or Driving Force Pro starts in
///   Driving Force EX compatibility mode (046D:C294) unless Logitech's
///   software switches it. SDL sends a 7-byte command that switches it to
///   its own native mode, which re-attaches it under its own product ID
///   with all its buttons and full steering resolution. The real wheel
///   behind C294 is told by its bcdDevice, with SDL's masks.
/// - In every Logitech wheel's report the pedals follow the steering in the
///   order gas, brake, clutch, and rest at their maximum (255 released).
///   They are put on one plan for every model: steering axi 0, brake axi 4,
///   gas axi 5 (the trigger slots, 0 at rest and 1 fully pressed), clutch
///   axi 1 (also 0 at rest, 1 pressed).
enum LogitechWheel {
    static let vendor: Int32 = 0x046D

    /// Every wheel this file knows, by product ID.
    static let products: Set<Int32> = [0xC20E, 0xC293, 0xC294, 0xC295, 0xC298, 0xC299, 0xC29A, 0xC29B,
                                       0xC24F, 0xC266, 0xCA03, 0xCA04]

    /// Older wheels whose descriptor has gas and brake as one combined axis
    /// and no separate pedal fields this app knows: that axis is read as
    /// one centered axis.
    static let combinedPedalProducts: Set<Int32> = [0xC20E, 0xC293, 0xC295, 0xCA03, 0xCA04]

    static func isWheel(vendor v: Int32, product p: Int32) -> Bool { v == vendor && products.contains(p) }

    /// How far each wheel turns lock to lock, in degrees, for the Live
    /// Visualizer: 900 for the wheels `rangeCommands` sets to 900, the fixed
    /// range of the older ones, nil where it is not known (the G923, which
    /// is sent no range command).
    static func rotationDegrees(product: Int32) -> Double? {
        switch product {
        case 0xC294: return 270
        case 0xC298, 0xC299, 0xC29A, 0xC29B, 0xC24F: return 900
        case 0xC295, 0xCA03, 0xCA04: return 240
        default: return nil
        }
    }

    /// The commands that set a wheel's range to 900 degrees, as SDL sends
    /// them when it opens one (SDL_hidapi_lg4ff.c, range command at init):
    /// one for the G29, G27, G25 and Driving Force GT, a coarse and a fine
    /// one for the Driving Force Pro, which otherwise starts at 200. nil
    /// for any other wheel, whose range stays as it is.
    static func rangeCommands(product: Int32) -> [[UInt8]]? {
        switch product {
        case 0xC24F, 0xC29B, 0xC299, 0xC29A:
            return [[0xF8, 0x81, 0x84, 0x03, 0x00, 0x00, 0x00]]
        case 0xC298:
            return [[0xF8, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00], [0x81, 0x0B, 0x00, 0x00, 0x00, 0x00, 0x00]]
        default:
            return nil
        }
    }

    // MARK: - Separate pedals

    /// The Driving Force and Driving Force Pro descriptors, at the lengths
    /// those wheels report, name one combined pedal axis. Their reports
    /// carry gas in byte 5 and brake in byte 6 as well, 8 bits each, 255
    /// released (SDL_hidapi_lg4ff.c reads the same bytes). For those two,
    /// the combined axis is dropped and the two pedals are added, so
    /// `normalize` puts them on the gas and brake slots. Any other
    /// descriptor is left as parsed.
    private static let separatePedalWheels: [Int32: Int] = [0xC294: 130, 0xC298: 97]

    static func addSeparatePedals(_ layout: HIDExtendedLayout, descriptorLength: Int,
                                  vendor v: Int32, product p: Int32) -> HIDExtendedLayout {
        guard v == vendor, separatePedalWheels[p] == descriptorLength,
              let r = layout.reports.firstIndex(where: { $0.reportID == nil }) else { return layout }
        var out = layout
        out.reports[r].axes.removeAll { $0.usagePage == 0x01 && $0.usage == 0x31 }
        for (byte, usage) in [(5, 0x32), (6, 0x35)] where !out.reports[r].axes.contains(where: { $0.bitOffset == byte * 8 }) {
            out.reports[r].axes.append(HIDExtendedLayout.Axis(
                bitOffset: byte * 8, bitSize: 8, logicalMin: 0, logicalMax: 255, isSigned: false,
                usagePage: 0x01, usage: usage, index: 0, unipolar: false, digitalButton: nil))
        }
        out.reports[r].payloadSize = max(out.reports[r].payloadSize, 7)
        return out
    }

    // MARK: - Steering and pedals

    /// Puts the parsed plan on the one wheel convention (see above): the
    /// steering stays on axi 0; the pedals, in report order gas, brake,
    /// clutch, go to axi 5, 4 and 1, read 0 at rest and 1 fully pressed.
    static func normalize(_ layout: HIDExtendedLayout, product: Int32? = nil) -> HIDExtendedLayout {
        var out = layout
        // An older wheel with one combined pedal axis: that axis rests in
        // the middle, so it goes on axi 1 as a centered axis (gas one way,
        // brake the other), not on a pedal slot that would read half
        // pressed at rest.
        if let product, combinedPedalProducts.contains(product) {
            for r in out.reports.indices {
                for a in out.reports[r].axes.indices where !(out.reports[r].axes[a].usagePage == 0x01 && out.reports[r].axes[a].usage == 0x30) {
                    out.reports[r].axes[a].index = 1
                    out.reports[r].axes[a].unipolar = false
                    out.reports[r].axes[a].digitalButton = nil
                }
                out.reports[r].axes.sort { $0.index < $1.index }
            }
            return out
        }
        // Every axis but the steering, across reports, in report order.
        var pedals: [(report: Int, axis: Int, offset: Int)] = []
        for (r, report) in out.reports.enumerated() {
            for (a, axis) in report.axes.enumerated() where !(axis.usagePage == 0x01 && axis.usage == 0x30) {
                pedals.append((r, a, axis.bitOffset))
            }
        }
        pedals.sort { ($0.report, $0.offset) < ($1.report, $1.offset) }
        let slots = [5, 4, 1]
        for (n, p) in pedals.prefix(slots.count).enumerated() {
            out.reports[p.report].axes[p.axis].index = slots[n]
            out.reports[p.report].axes[p.axis].unipolar = true
            out.reports[p.report].axes[p.axis].inverted = true
            out.reports[p.report].axes[p.axis].digitalButton = nil
        }
        for r in out.reports.indices { out.reports[r].axes.sort { $0.index < $1.index } }
        return out
    }

    // MARK: - Native mode

    /// The command that switches a wheel in Driving Force EX compatibility
    /// mode to its own mode, and the wheel's name, from its bcdDevice
    /// (masks and commands as SDL_hidapi_lg4ff.c checks and sends them).
    /// nil for a real Driving Force EX.
    static func nativeModeCommand(product: Int32, bcdDevice: Int) -> (name: String, bytes: [UInt8])? {
        guard product == 0xC294 else { return nil }
        if bcdDevice & 0xFFF8 == 0x1350 || bcdDevice & 0xFF00 == 0x8900 {
            return ("G29", [0xF8, 0x09, 0x05, 0x01, 0x01, 0x00, 0x00])
        }
        if bcdDevice & 0xFF00 == 0x1300 { return ("Driving Force GT", [0xF8, 0x09, 0x03, 0x01, 0x00, 0x00, 0x00]) }
        if bcdDevice & 0xFFF0 == 0x1230 { return ("G27", [0xF8, 0x09, 0x04, 0x01, 0x00, 0x00, 0x00]) }
        if bcdDevice & 0xFF00 == 0x1200 { return ("G25", [0xF8, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00]) }
        if bcdDevice & 0xF000 == 0x1000 { return ("Driving Force Pro", [0xF8, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00]) }
        return nil
    }
}
