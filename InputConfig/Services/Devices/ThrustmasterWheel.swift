import Foundation

/// Thrustmaster wheel bases in their native (PC) mode, read through the
/// descriptor parser, put on the one wheel convention the app uses for
/// Logitech wheels: steering on axis 0, clutch on 1, brake on 4, gas on 5,
/// each pedal 0 released and 1 floored. The fixed descriptors in hid-tmff2
/// (hid-tmt300rs.c, hid-tmt248.c, hid-tmtx.c, hid-tmtsxw.c, hid-tmtspc.c)
/// name X 16 bit, then Rz (brake), Z (gas), Y (clutch) 0 to 1023; without
/// this they paired onto the stick slots and read full deflection at rest.
///
/// UNVERIFIED: which end of 0 to 1023 a Thrustmaster pedal rests at. The
/// Logitech convention (released = maximum) is assumed, so `inverted` is
/// set; if a pedal reads 1 at rest, that assumption is wrong and this is
/// the one line to flip.
enum ThrustmasterWheel {
    static let vendor: Int32 = 0x044F
    /// T300 RS (B66E), T300 RS GT and Ferrari (B66F), T300 PS4 mode (B66D),
    /// TX (B669), TS-XW (B692), TS-PC Racer (B689), T150 (B677), TMX (B67F),
    /// T248 (B696), T500 RS (B65E).
    static let products: Set<Int32> = [0xB66E, 0xB66F, 0xB66D, 0xB669, 0xB692, 0xB689, 0xB677, 0xB67F, 0xB696, 0xB65E]
    /// A base in boot (compatibility) mode, which Thrustmaster's tool or a
    /// console switches to native mode; not readable as a wheel.
    static let bootModeProduct: Int32 = 0xB65D
    static let pedalsRestAtMaximum = true

    static func isWheel(vendor v: Int32, product p: Int32) -> Bool { v == vendor && products.contains(p) }

    static func normalize(_ layout: HIDExtendedLayout) -> HIDExtendedLayout {
        var out = layout
        let slots: [Int: Int] = [0x30: 0, 0x35: 4, 0x32: 5, 0x31: 1]   // X, Rz brake, Z gas, Y clutch
        var taken: Set<Int> = []
        var next = 6
        for r in out.reports.indices {
            for a in out.reports[r].axes.indices {
                let axis = out.reports[r].axes[a]
                if axis.usagePage == 0x01, let slot = slots[axis.usage], !taken.contains(slot) {
                    out.reports[r].axes[a].index = slot
                    out.reports[r].axes[a].unipolar = slot != 0
                    out.reports[r].axes[a].inverted = slot != 0 && pedalsRestAtMaximum
                    out.reports[r].axes[a].digitalButton = nil
                    taken.insert(slot)
                } else {
                    while taken.contains(next) || next < 6 { next += 1 }
                    out.reports[r].axes[a].index = next
                    out.reports[r].axes[a].unipolar = false
                    out.reports[r].axes[a].inverted = false
                    out.reports[r].axes[a].digitalButton = nil
                    taken.insert(next)
                }
            }
            out.reports[r].axes.sort { $0.index < $1.index }
        }
        return out
    }
}
