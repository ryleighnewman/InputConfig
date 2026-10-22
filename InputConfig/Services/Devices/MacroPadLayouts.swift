import Foundation

/// Jog and shuttle controllers and 6DoF mice read through the descriptor
/// parser, corrected where their descriptors lie (proto-streamdeck-macropads.md
/// sections 6 to 9):
/// - Contour ShuttleXpress and ShuttlePRO v2 (0B33:0020, 0030): the shuttle
///   ring (Generic Desktop Wheel, flagged relative) is a held position -7
///   to 7 that springs back; the jog (Dial, flagged relative and wrap) is a
///   position counter that wraps at 256, whose delta is Int8(new - old).
/// - 3Dconnexion SpaceMouse family (046D multi axis controllers and 256F):
///   the six axes are flagged relative on several models (a descriptor bug
///   the kernel fixes with a BPF program) but hold their value while the cap
///   is deflected, full deflection about plus or minus 350 (spacenavd,
///   pyspacemouse). Translation X Y to axes 0 and 1, rotation Rx Ry to 2 and
///   3, Z and Rz to 6 and 7.
enum MacroPadLayouts {
    static let contourVendor: Int32 = 0x0B33
    static let spaceMouseVendors: Set<Int32> = [0x046D, 0x256F]
    static let spaceMouseRange = 350
    static let contourShuttleAxis = 6
    static let contourJogAxis = 7

    static func isContour(vendorID v: Int32, productID p: Int32) -> Bool { v == contourVendor }

    /// A 3Dconnexion device is one whose plan has Generic Desktop X and Rx
    /// (a 6DoF cap); the CadMouse and keyboards on the same vendor ID do not.
    static func isSpaceMouse(vendorID v: Int32, _ layout: HIDExtendedLayout) -> Bool {
        guard spaceMouseVendors.contains(v) else { return false }
        let usages = Set(layout.reports.flatMap(\.axes).filter { $0.usagePage == 0x01 }.map(\.usage))
        return usages.isSuperset(of: [0x30, 0x31, 0x32, 0x33, 0x34, 0x35])
    }

    static func applies(vendorID v: Int32, productID p: Int32, _ layout: HIDExtendedLayout) -> Bool {
        isContour(vendorID: v, productID: p) || isSpaceMouse(vendorID: v, layout)
    }

    static func normalize(_ layout: HIDExtendedLayout, vendorID v: Int32, productID p: Int32) -> HIDExtendedLayout {
        if isContour(vendorID: v, productID: p) { return contour(layout) }
        if isSpaceMouse(vendorID: v, layout) { return spaceMouse(layout) }
        return layout
    }

    private static func contour(_ layout: HIDExtendedLayout) -> HIDExtendedLayout {
        var out = layout
        for r in out.reports.indices {
            for a in out.reports[r].axes.indices {
                let axis = out.reports[r].axes[a]
                guard axis.usagePage == 0x01 else { continue }
                switch axis.usage {
                case 0x38:   // the shuttle ring: a held signed position
                    out.reports[r].axes[a].relative = false
                    out.reports[r].axes[a].wrapCounter = false
                    out.reports[r].axes[a].isSigned = true
                    out.reports[r].axes[a].logicalMin = -7
                    out.reports[r].axes[a].logicalMax = 7
                    out.reports[r].axes[a].index = contourShuttleAxis
                    out.reports[r].axes[a].unipolar = false
                    out.reports[r].axes[a].digitalButton = nil
                case 0x37:   // the jog wheel: a wrapping counter
                    out.reports[r].axes[a].relative = true
                    out.reports[r].axes[a].wrapCounter = true
                    out.reports[r].axes[a].isSigned = false
                    out.reports[r].axes[a].logicalMin = 0
                    out.reports[r].axes[a].logicalMax = 255
                    out.reports[r].axes[a].index = contourJogAxis
                    out.reports[r].axes[a].unipolar = false
                    out.reports[r].axes[a].digitalButton = nil
                default: break
                }
            }
            out.reports[r].axes.sort { $0.index < $1.index }
        }
        return out
    }

    private static func spaceMouse(_ layout: HIDExtendedLayout) -> HIDExtendedLayout {
        var out = layout
        let slots: [Int: Int] = [0x30: 0, 0x31: 1, 0x33: 2, 0x34: 3, 0x32: 6, 0x35: 7]
        for r in out.reports.indices {
            for a in out.reports[r].axes.indices {
                let axis = out.reports[r].axes[a]
                guard axis.usagePage == 0x01, let slot = slots[axis.usage] else { continue }
                out.reports[r].axes[a].relative = false
                out.reports[r].axes[a].wrapCounter = false
                out.reports[r].axes[a].isSigned = true
                out.reports[r].axes[a].logicalMin = -spaceMouseRange
                out.reports[r].axes[a].logicalMax = spaceMouseRange
                out.reports[r].axes[a].index = slot
                out.reports[r].axes[a].unipolar = false
                out.reports[r].axes[a].digitalButton = nil
            }
            out.reports[r].axes.sort { $0.index < $1.index }
        }
        return out
    }
}
