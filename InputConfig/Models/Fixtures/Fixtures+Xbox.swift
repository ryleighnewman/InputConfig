import Foundation

/// XInput class (XUSB) 20 byte state reports through the app's fixed
/// `.xinput` layout: xpad.c xpad360_process_packet, SDL_hidapi_xbox360.c
/// HandleStatePacket, GP2040-CE XInputDescriptors.h. On stock macOS no
/// wired Xbox 360 class device reaches IOKit as HID, so these are the
/// decoder's reference, reachable through Steam's virtual pad.
extension HIDFixtureCorpus {
    private static func xusb(_ id: String, _ bytes: [UInt8], _ expect: [HIDFixture.Expect], _ locator: String,
                             status: HIDFixture.Status = .verified) -> HIDFixture {
        HIDFixture(id: id, device: "Xbox 360 (XUSB)", transport: .usb,
                   route: .rawHID(vendorID: 0x045E, productID: 0x028E, transport: "USB"),
                   reportID: 0x00, hex: HIDFixture.hex(bytes), expect: expect, status: status,
                   citation: HIDFixture.Citation(source: "xpad.c xpad360_process_packet; SDL_hidapi_xbox360.c; gp2040ce XInputDescriptors.h", locator: locator, date: "2026-10-20"))
    }
    private static func x20(_ b: [UInt8]) -> [UInt8] { [0x00, 0x14] + b + [UInt8](repeating: 0, count: 18 - b.count) }

    static let xbox: [HIDFixture] = xboxReference + xboxBluetooth + [
        xusb("xusb.rest", x20([]), [.buttonAbsent(0), .buttonAbsent(10), .hat(0, x: 0, y: 0), .axis(0, 0, tolerance: 0.001), .axis(4, 0, tolerance: 0.001)], "xusb-rest"),
        xusb("xusb.all", x20([0xF9, 0xF7, 0xFF, 0xFF, 0xFF, 0x7F, 0x00, 0x80, 0x00, 0x80, 0xFF, 0x7F]),
             (0...12).map { .button($0, 1) } + [.hat(0, x: 1, y: 1), .axis(0, 1, tolerance: 0.001), .axis(1, 1, tolerance: 0.001),
              .axis(2, -1, tolerance: 0.001), .axis(3, -1, tolerance: 0.001), .axis(4, 1, tolerance: 0.001), .axis(5, 1, tolerance: 0.001)],
             "xusb-all: buttons 0xF7F9, LY 0x8000 is down after the flip, RY 0x7FFF is up"),
        xusb("xusb.dpad.upleft.guide", x20([0x05, 0x04]), [.hat(0, x: -1, y: 1), .button(10, 1), .buttonAbsent(0), .buttonAbsent(9)], "bits 0 up, 2 left, 10 guide"),
        xusb("xusb.dpad.contradiction", x20([0x0F, 0x00]), [.hat(0, x: 0, y: 0)], "opposite directions cancel"),
        xusb("xusb.trigger.threshold", x20([0x00, 0x00, 0x1E, 0x1F]),
             [.axis(4, 0.1176, tolerance: 0.001), .buttonAbsent(6), .axis(5, 0.1216, tolerance: 0.001), .button(7, 1)], "digital trigger at 0.12"),
        xusb("xusb.header.start.a.rt", x20([0x10, 0x10, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x80]),
             [.button(9, 1), .button(0, 1), .axis(5, 1, tolerance: 0.001), .button(7, 1), .axis(4, 0, tolerance: 0.001), .buttonAbsent(6),
              .axis(0, 0, tolerance: 0.001), .axis(1, 1, tolerance: 0.001), .hat(0, x: 0, y: 0)], "F11a: Start, A, RT full, LY pushed down"),
        xusb("xusb.headerless14", [0x10, 0x04, 0xFF, 0x00, 0xFF, 0x7F, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
             [.button(0, 1), .button(10, 1), .axis(4, 1, tolerance: 0.001), .axis(5, 0, tolerance: 0.001), .axis(0, 1, tolerance: 0.001)],
             "the compact 8BitDo form; no capture shows a real device sends it", status: .unverified),
        xusb("xusb.nonstate3", [0x01, 0x03, 0x06], [.ignored], "a 3 byte LED or rumble echo"),
        xusb("xusb.wronglength19", Array(x20([0xF9, 0xF7, 0xFF, 0xFF, 0xFF, 0x7F, 0x00, 0x80, 0x00, 0x80, 0xFF, 0x7F]).prefix(19)),
             [.button(0, 1), .button(10, 1)], "19 bytes take the headerless path from byte 0: buttons 0x1400 read as A and Guide; no source shows a device sending 19", status: .unverified),
    ]

    /// The 8BitDo Ultimate in X mode (2DC8:3106) is an Xbox 360 class USB
    /// device macOS never exposes as HID; its profile is the XInput
    /// decoder's reference and this fixture documents the headerless
    /// 14 byte form the profile was written for.
    static let xboxReference: [HIDFixture] = [
        HIDFixture(id: "xusb.8bitdo.xmode.reference", device: "8BitDo Ultimate (X mode)", transport: .usb,
                   route: .rawHID(vendorID: 0x2DC8, productID: 0x3106, transport: "USB"), reportID: 0x00,
                   hex: HIDFixture.hex([0x10, 0x04, 0xFF, 0x00, 0xFF, 0x7F, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
                   expect: [.button(0, 1), .button(10, 1), .axis(4, 1, tolerance: 0.001)], status: .unverified,
                   citation: HIDFixture.Citation(source: "xpad.c XTYPE_XBOX360 for 2DC8; no HID capture exists", locator: "unreachable on stock macOS", date: "2026-10-20")),
    ]

    private static func xbt(_ id: String, pid: Int32, _ bytes: [UInt8], _ expect: [HIDFixture.Expect], _ locator: String,
                            status: HIDFixture.Status = .verified) -> HIDFixture {
        HIDFixture(id: id, device: String(format: "Xbox 045E:%04X (Bluetooth)", pid), transport: .bluetooth,
                   route: .rawHID(vendorID: 0x045E, productID: pid, transport: "Bluetooth"), reportID: bytes.first ?? 0,
                   hex: HIDFixture.hex(bytes), expect: expect, status: status,
                   citation: HIDFixture.Citation(source: "SDL_hidapi_xboxone.c HandleButtons, HandleButtons16; xpadneo docs/descriptors and events.c", locator: locator, date: "2026-10-20"))
    }
    /// A 17 byte report at rest, to patch per case.
    private static func xbRest(_ length: Int = 17) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: length)
        r[0] = 0x01; r[2] = 0x80; r[4] = 0x80; r[6] = 0x80; r[8] = 0x80
        return r
    }
    private static func xbAll(_ length: Int = 17) -> [UInt8] {
        var r = xbRest(length)
        for (i, b) in [0xFE, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xFE, 0xFF, 0xFF, 0x03, 0xFF, 0x03, 0x02, 0xDB, 0x7C].enumerated() { r[1 + i] = UInt8(b) }
        if length >= 17 { r[16] = 0x01 }
        return r
    }
    static let xboxBluetooth: [HIDFixture] = [
        xbt("xbs.rest", pid: 0x0B13, xbRest(), [.buttonAbsent(0), .buttonAbsent(14), .hat(0, x: 0, y: 0), .axis(0, 0, tolerance: 0.001), .axis(4, 0, tolerance: 0.001)], "xbs-rest"),
        xbt("xbs.all", pid: 0x0B13, xbAll(),
            [0, 1, 2, 3, 4, 5, 8, 9, 10, 11, 12, 14, 6, 7].map { .button($0, 1) } + [.hat(0, x: 0.707, y: 0.707),
             .axis(0, 1, tolerance: 0.001), .axis(1, -1, tolerance: 0.001), .axis(2, -1, tolerance: 0.001), .axis(3, 1, tolerance: 0.001),
             .axis(4, 1, tolerance: 0.001), .axis(5, 1, tolerance: 0.001)], "xbs-all: byte 14 0xDB, byte 15 0x7C, byte 16 bit 0 Share"),
        xbt("xbs.unusedbits", pid: 0x0B13, { var r = xbRest(); r[14] = 0x24; r[15] = 0x03; return r }(),
            (0...19).map { .buttonAbsent($0) }, "xbs-unused-bits: usages 3, 6, 9, 10 light nothing"),
        xbt("xbs.hat.east", pid: 0x0B13, { var r = xbRest(); r[13] = 3; return r }(), [.hat(0, x: 1, y: 0)], "hat 3 = east"),
        xbt("xbs.hat.released9", pid: 0x0B13, { var r = xbRest(); r[13] = 9; return r }(), [.hat(0, x: 0, y: 0)], "hat 9 is released"),
        xbt("xbs.capture.menu", pid: 0x0B13, [0x01, 0xEB, 0x7E, 0x5F, 0x80, 0xEB, 0x7F, 0x85, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x08, 0x00],
            [.button(9, 1), .buttonAbsent(8), .axis(0, -0.0084, tolerance: 0.0005), .axis(1, 0.0029, tolerance: 0.0005)], "btmon capture in xbxs.md, Menu held"),
        xbt("xbs.capture.share", pid: 0x0B13, [0x01, 0xEB, 0x7E, 0x5F, 0x80, 0xEB, 0x7F, 0x85, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01],
            [.button(14, 1), .buttonAbsent(8)], "btmon capture, Share: byte 16 bit 0"),
        xbt("xbs.capture.view", pid: 0x0B13, [0x01, 0xEB, 0x7E, 0x5F, 0x80, 0xEB, 0x7F, 0x85, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00],
            [.button(8, 1), .buttonAbsent(14)], "btmon capture, View: byte 15 bit 2"),
        xbt("xbs.triggers.half", pid: 0x0B13, { var r = xbRest(); r[9] = 0x00; r[10] = 0x02; r[11] = 0xFF; r[12] = 0x01; return r }(),
            [.axis(4, 0.5005, tolerance: 0.001), .axis(5, 0.4995, tolerance: 0.001), .button(6, 1), .button(7, 1)], "10 bit triggers"),
        xbt("xb1w.all.windowsmode", pid: 0x02E0, { var r = xbAll(16); r[13] = 0x05; r[14] = 0xFF; r[15] = 0x03; return r }(),
            [0, 1, 2, 3, 4, 5, 8, 9, 11, 12, 6, 7].map { .button($0, 1) } + [.buttonAbsent(10), .hat(0, x: 0, y: -1)], "xb1w-all: the 16 byte Windows map"),
        xbt("xb1w.dpad.vs.buttons", pid: 0x02E0, { var r = xbRest(16); r[13] = 0x01; r[14] = 0x04; return r }(),
            [.hat(0, x: 0, y: 1), .button(2, 1), .buttonAbsent(3)], "xb1w-dpad-vs-buttons: bit 14.2 is X in Windows mode"),
        xbt("xb1w.guide.report2", pid: 0x02E0, [0x02, 0x01], [.button(10, 1)], "report 0x02 bit 0 is the Xbox button"),
        xbt("xb1l.view.acback", pid: 0x02FD, { var r = xbRest(); r[16] = 0x01; return r }(), [.button(8, 1), .buttonAbsent(14)], "xb1l-view-acback: AC Back is View on a One S"),
        xbt("xb1l.view.sparse", pid: 0x02FD, { var r = xbRest(); r[15] = 0x04; return r }(), [.button(8, 1)], "xb1l-view-sparse: firmware 5 puts View at 15.2"),
        xbt("xb1l.guide.bit", pid: 0x02FD, { var r = xbRest(); r[15] = 0x10; return r }(), [.button(10, 1)], "xb1l-guide-bit"),
        xbt("xbe2.55.paddles.default", pid: 0x0B05, { var r = xbRest(55); r[33] = 0x0F; return r }(), [.button(16, 1), .button(17, 1), .button(18, 1), .button(19, 1)], "xbe2-55-paddles-default: profile 0"),
        xbt("xbe2.55.paddles.profile2", pid: 0x0B05, { var r = xbRest(55); r[33] = 0x0F; r[35] = 0x02; return r }(), [.buttonAbsent(16), .buttonAbsent(19)], "xbe2-55-paddles-profile2: paddles only on profile 0"),
        xbt("xbe2.55.p1only", pid: 0x0B05, { var r = xbRest(55); r[33] = 0x01; return r }(), [.button(16, 1), .buttonAbsent(17)], "xbe2-55-p1-only"),
        xbt("xbe2.39.paddles.default", pid: 0x0B05, { var r = xbRest(39); r[17] = 0x0F; return r }(), [.button(16, 1), .button(19, 1)], "xbe2-39-paddles-default (firmware 4.8)"),
        xbt("xbe2.39.paddles.profile1", pid: 0x0B05, { var r = xbRest(39); r[17] = 0x0F; r[19] = 0x01; return r }(), [.buttonAbsent(16)], "xbe2-39-paddles-profile1"),
        xbt("xbe2.20.paddles.default", pid: 0x0B22, { var r = xbRest(20); r[19] = 0x0F; return r }(), [.button(16, 1), .button(19, 1)], "xbe2-20-paddles-default (firmware 5.11)", status: .unverified),
        xbt("xbe2.20.paddles.profile3", pid: 0x0B22, { var r = xbRest(20); r[19] = 0x0F; r[17] = 0x03; return r }(), [.buttonAbsent(16)], "xbe2-20-paddles-profile3", status: .unverified),
        xbt("xbe2.ble.x.press", pid: 0x0B22, { var r = xbRest(); r[14] = 0x08; return r }(), [.button(2, 1), .buttonAbsent(3)], "xbe2-ble-x-press: X is bit 3 on the sparse map"),
        xbt("xbe2.ble.lb.press", pid: 0x0B22, { var r = xbRest(); r[14] = 0x40; return r }(), [.button(4, 1), .buttonAbsent(8)], "xbe2-ble-lb-press"),
        xbt("xbt.short15", pid: 0x0B13, Array(xbRest().prefix(15)), [.ignored], "fewer than 16 bytes is not a state"),
        HIDFixture(id: "out.xbox.bt.rumble", device: "Xbox (Bluetooth)", transport: .bluetooth,
                   route: .outputReport(builder: .xboxBluetoothRumble(strong: 100, weak: 50, lt: 0, rt: 0)), reportID: 0x03, hex: "",
                   expect: [.bytes([0x03, 0x0F, 0x00, 0x00, 0x64, 0x32, 0xFF, 0x00, 0xEB])], status: .verified,
                   citation: HIDFixture.Citation(source: "SDL_hidapi_xboxone.c SendBluetoothRumble; xpadneo rumble.c", locator: "documented, never sent while GameController owns the pad", date: "2026-10-20")),
        HIDFixture(id: "out.xbox.bt.rumble.triggers", device: "Xbox (Bluetooth)", transport: .bluetooth,
                   route: .outputReport(builder: .xboxBluetoothRumble(strong: 0, weak: 0, lt: 100, rt: 100)), reportID: 0x03, hex: "",
                   expect: [.bytes([0x03, 0x0C, 0x64, 0x64, 0x00, 0x00, 0xFF, 0x00, 0xEB])], status: .verified,
                   citation: HIDFixture.Citation(source: "xpadneo.h xpadneo_rumble_motors", locator: "mask bit 2 right trigger, bit 3 left trigger", date: "2026-10-20")),
    ]

    static let xboxSequences: [HIDSequenceFixture] = [
        HIDSequenceFixture(id: "xb1w.guide.merge", route: .rawHID(vendorID: 0x045E, productID: 0x02E0, transport: "Bluetooth"),
                           steps: [
                               .init(delayMs: 0, reportID: 0x01, hex: HIDFixture.hex({ var r = xbRest(16); r[14] = 0x01; return r }()), expect: [.button(0, 1)]),
                               .init(delayMs: 0, reportID: 0x02, hex: "02 01", expect: [.button(10, 1), .button(0, 1)]),
                               .init(delayMs: 0, reportID: 0x02, hex: "02 00", expect: [.buttonAbsent(10), .button(0, 1)]),
                               .init(delayMs: 0, reportID: 0x04, hex: "04 87", expect: [.button(0, 1)]),
                           ], status: .verified,
                           citation: HIDFixture.Citation(source: "SDL HandleGuidePacket; RawHIDGamepad.updateState merge", locator: "report 0x02 merges with 0x01; 0x04 touches no input", date: "2026-10-20")),
    ]
}
