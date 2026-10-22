import Foundation

/// Contour ShuttleXpress and 3Dconnexion SpaceMouse reports through the
/// descriptor parser and MacroPadLayouts. The descriptors are built from
/// the field lists in the sources (opencontourshuttle's dump of the
/// ShuttleXpress: Wheel and Dial 8 bit relative, 13 buttons; spacenavd and
/// pyspacemouse: split translation and rotation reports of three INT16, a
/// combined 12 byte report on the wireless models, report 3 buttons).
extension HIDFixtureCorpus {
    /// Consumer Control application: Wheel (shuttle, byte 0), Dial (jog,
    /// byte 1, wrap), a padding byte, 13 buttons and 3 padding bits.
    static let contourDescriptor: [UInt8] = [
        0x05, 0x0C, 0x09, 0x01, 0xA1, 0x01,
        0x05, 0x01, 0x09, 0x38, 0x15, 0x80, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06,   // Wheel, rel
        0x09, 0x37, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x81, 0x0E,                                 // Dial, rel, wrap
        0x75, 0x08, 0x95, 0x01, 0x81, 0x01,                                                   // padding byte
        0x05, 0x09, 0x19, 0x01, 0x29, 0x0D, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x0D, 0x81, 0x02,   // 13 buttons
        0x75, 0x03, 0x95, 0x01, 0x81, 0x01,
        0xC0,
    ]
    /// SpaceNavigator: report 1 X Y Z, report 2 Rx Ry Rz, INT16 flagged
    /// relative (the descriptor bug), report 3 two buttons.
    static let spaceNavigatorDescriptor: [UInt8] = [
        0x05, 0x01, 0x09, 0x08, 0xA1, 0x01,
        0x85, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x32, 0x16, 0x00, 0xFE, 0x26, 0xFF, 0x01, 0x75, 0x10, 0x95, 0x03, 0x81, 0x06,
        0x85, 0x02, 0x09, 0x33, 0x09, 0x34, 0x09, 0x35, 0x75, 0x10, 0x95, 0x03, 0x81, 0x06,
        0x85, 0x03, 0x05, 0x09, 0x19, 0x01, 0x29, 0x02, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x02, 0x81, 0x02,
        0x75, 0x06, 0x95, 0x01, 0x81, 0x01,
        0xC0,
    ]
    /// SpaceMouse Wireless: one report 1 with all six INT16 axes.
    static let spaceMouseWirelessDescriptor: [UInt8] = [
        0x05, 0x01, 0x09, 0x08, 0xA1, 0x01,
        0x85, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x32, 0x09, 0x33, 0x09, 0x34, 0x09, 0x35,
        0x16, 0x00, 0xFE, 0x26, 0xFF, 0x01, 0x75, 0x10, 0x95, 0x06, 0x81, 0x02,
        0x85, 0x03, 0x05, 0x09, 0x19, 0x01, 0x29, 0x02, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x02, 0x81, 0x02,
        0x75, 0x06, 0x95, 0x01, 0x81, 0x01,
        0xC0,
    ]

    private static func pad(_ id: String, device: String, descriptor: [UInt8], vid: Int32, pid: Int32, _ bytes: [UInt8],
                            _ expect: [HIDFixture.Expect], _ locator: String, status: HIDFixture.Status = .reconstructed) -> HIDFixture {
        HIDFixture(id: id, device: device, transport: .usb,
                   route: .descriptor(name: id, bytes: descriptor, vendorID: vid, productID: pid, version: 0),
                   reportID: bytes.first ?? 0, hex: HIDFixture.hex(bytes), expect: expect, status: status,
                   citation: HIDFixture.Citation(source: "opencontourshuttle, hid-shuttlepro.c, shuttlepro-report.h; spacenavd dev.c, pyspacemouse devices.toml", locator: locator, date: "2026-10-20"))
    }
    private static func le(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }

    static let macroPads: [HIDFixture] = [
        pad("contour.shuttle.plus3.button9", device: "Contour ShuttlePRO v2", descriptor: contourDescriptor, vid: 0x0B33, pid: 0x0030,
            [0x03, 0x7F, 0x00, 0x00, 0x02],
            [.axis(6, 3.0 / 7.0, tolerance: 0.01), .button(9, 1), .buttonAbsent(0), .buttonAbsent(8)], "shuttle +3 of 7 is held; byte 4 bit 1 is the tenth button (index 9)"),
        pad("contour.shuttle.minus7", device: "Contour ShuttlePRO v2", descriptor: contourDescriptor, vid: 0x0B33, pid: 0x0030,
            [0xF9, 0x00, 0x00, 0x00, 0x00], [.axis(6, -1, tolerance: 0.01)], "INT8 -7 is full counterclockwise"),
        pad("contour.rest", device: "Contour ShuttlePRO v2", descriptor: contourDescriptor, vid: 0x0B33, pid: 0x0030,
            [0x00, 0x00, 0x00, 0x00, 0x00], [.axis(6, 0, tolerance: 0.001), .axisAbsent(7), .relativeSteps(7, 0)], "the jog counter is published as a counter, not an axis"),
        pad("spacenavigator.translation", device: "3Dconnexion SpaceNavigator", descriptor: spaceNavigatorDescriptor, vid: 0x046D, pid: 0xC626,
            [0x01] + le(350) + le(0) + le(-350 & 0xFFFF),
            [.axis(0, 1, tolerance: 0.01), .axis(1, 0, tolerance: 0.01), .axis(6, -1, tolerance: 0.01), .axisAbsent(2)], "report 1: X +350 full, Z -350; held, not pulsed"),
        pad("spacenavigator.rotation", device: "3Dconnexion SpaceNavigator", descriptor: spaceNavigatorDescriptor, vid: 0x046D, pid: 0xC626,
            [0x02] + le(0) + le(175) + le(-350 & 0xFFFF),
            [.axis(2, 0, tolerance: 0.01), .axis(3, 0.5, tolerance: 0.01), .axis(7, -1, tolerance: 0.01), .axisAbsent(0)], "report 2: Rx Ry Rz on 2, 3 and 7"),
        pad("spacenavigator.buttons", device: "3Dconnexion SpaceNavigator", descriptor: spaceNavigatorDescriptor, vid: 0x046D, pid: 0xC626,
            [0x03, 0x01], [.button(0, 1), .buttonAbsent(1), .axisAbsent(0)], "report 3: left button"),
        pad("spacemouse.wireless.combined", device: "3Dconnexion SpaceMouse Wireless", descriptor: spaceMouseWirelessDescriptor, vid: 0x256F, pid: 0xC62E,
            [0x01] + le(0) + le(350) + le(0) + le(0) + le(0) + le(0),
            [.axis(1, 1, tolerance: 0.01), .axis(0, 0, tolerance: 0.01)], "combined report 1: Y +350"),
    ]

    static let macroPadsSequences: [HIDSequenceFixture] = [
        HIDSequenceFixture(id: "contour.jog.wrap", route: .descriptor(name: "contour-jog", bytes: contourDescriptor, vendorID: 0x0B33, productID: 0x0030, version: 0),
                           steps: [
                               .init(delayMs: 0, reportID: 0, hex: "00 FE 00 00 00", expect: [.axisAbsent(7)]),
                               .init(delayMs: 0, reportID: 0, hex: "00 01 00 00 00", expect: [.axis(7, 1, tolerance: 0.001)]),
                               .init(delayMs: 120, reportID: 0, hex: "", expect: [.axis(7, 0, tolerance: 0.001)]),
                               .init(delayMs: 0, reportID: 0, hex: "00 00 00 00 00", expect: [.axis(7, -1, tolerance: 0.001)]),
                               .init(delayMs: 0, reportID: 0, hex: "00 00 00 00 00", expect: [.axis(7, -1, tolerance: 0.001)]),
                           ], status: .reconstructed,
                           citation: HIDFixture.Citation(source: "hid-shuttlepro.c: jog delta is Int8(new - old)", locator: "254 to 1 is +3, not -253; 1 to 0 is -1; the same counter again is no turn (push still held)", date: "2026-10-20")),
    ]
}
