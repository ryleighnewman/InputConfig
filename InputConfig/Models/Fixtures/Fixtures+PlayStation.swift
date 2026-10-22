import Foundation

/// DualSense, DualSense Edge and DualShock 3 reports. The DualSense
/// fixtures exercise the supplement reader's buttons[2] byte (PS, mute,
/// Fn, paddles) on every transport and report shape; the DualShock 3
/// fixtures exercise the raw decoder. Layouts: hid-playstation.c
/// dualsense_input_report, SDL_hidapi_ps5.c PS5StatePacket_t and
/// PS5SimpleStatePacket_t, hid-sony.c sixaxis_raw_event,
/// SDL_hidapi_ps3.c button_axis_offsets.
extension HIDFixtureCorpus {
    private static let dualSense: Int32 = 0x0CE6
    private static let dualSenseEdge: Int32 = 0x0DF2
    private static let dualShock3: Int32 = 0x0268

    /// USB 0x01 at rest: sticks 0x80, seq 0x2A, hat released (8), touch
    /// contacts inactive (0x80), status 0x18 (battery level 8, charging) 0x08 (USB).
    static let dualSenseUSBRest: [UInt8] = {
        var r = [UInt8](repeating: 0, count: 64)
        r[0] = 0x01; r[1] = 0x80; r[2] = 0x80; r[3] = 0x80; r[4] = 0x80
        r[7] = 0x2A; r[8] = 0x08
        r[12] = 0x40; r[13] = 0x42; r[14] = 0x0F
        r[29] = 0x48; r[30] = 0xE8; r[31] = 0x01; r[33] = 0x80; r[37] = 0x80
        r[53] = 0x18; r[54] = 0x08
        return r
    }()

    /// USB 0x01 with every control on: sticks to the corners, triggers
    /// full, hat north (0) with the four face buttons (0xF0), the rest of
    /// the buttons in [9], PS and mute in [10].
    static func dualSenseUSBEverything(buttons2: UInt8) -> [UInt8] {
        var r = dualSenseUSBRest
        r[1] = 0x00; r[2] = 0x00; r[3] = 0xFF; r[4] = 0xFF; r[5] = 0xFF; r[6] = 0xFF
        r[8] = 0xF0; r[9] = 0xFF; r[10] = buttons2
        return r
    }

    /// The same state over Bluetooth: 0x31, sequence tag at [1], payload
    /// two bytes later, CRC sealed.
    static func dualSenseBT(from usb: [UInt8], tag: UInt8) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: 78)
        r[0] = 0x31; r[1] = tag
        for i in 1..<64 { r[i + 1] = usb[i] }
        SonyBluetoothCRC.sealInputReport(&r)
        return r
    }

    private static func supplement(_ id: String, pid: Int32, bt: Bool, _ bytes: [UInt8], _ expect: [HIDFixture.Expect],
                                   _ locator: String, status: HIDFixture.Status = .reconstructed) -> HIDFixture {
        HIDFixture(id: id, device: pid == dualSenseEdge ? "DualSense Edge" : "DualSense", transport: bt ? .bluetooth : .usb,
                   route: .dualSenseSupplement(productID: pid), reportID: bytes.first ?? 0, hex: HIDFixture.hex(bytes),
                   expect: expect, status: status,
                   citation: HIDFixture.Citation(source: "hid-playstation.c, SDL_hidapi_ps5.c, nondebug/dualsense; Edge bits measured 2026-08-17", locator: locator, date: "2026-10-20"))
    }

    private static func ds3(_ id: String, _ bytes: [UInt8], _ expect: [HIDFixture.Expect], _ locator: String,
                            status: HIDFixture.Status = .reconstructed) -> HIDFixture {
        HIDFixture(id: id, device: "DualShock 3", transport: .usb,
                   route: .rawHID(vendorID: 0x054C, productID: dualShock3, transport: "USB"),
                   reportID: bytes.first ?? 0, hex: HIDFixture.hex(bytes), expect: expect, status: status,
                   citation: HIDFixture.Citation(source: "hid-sony.c sixaxis_raw_event; SDL_hidapi_ps3.c", locator: locator, date: "2026-10-20"))
    }

    /// DualShock 3 report 0x01, 49 bytes: sticks 0x80, battery 5, the
    /// accelerometer words 511 (0 g).
    static let dualShock3Rest: [UInt8] = {
        var r = [UInt8](repeating: 0, count: 49)
        r[0] = 0x01; r[6] = 0x80; r[7] = 0x80; r[8] = 0x80; r[9] = 0x80; r[30] = 0x05
        for i in stride(from: 41, to: 49, by: 2) { r[i] = 0x01; r[i + 1] = 0xFF }
        return r
    }()
    static let dualShock3Everything: [UInt8] = {
        var r = dualShock3Rest
        r[2] = 0x3F; r[3] = 0xFF; r[4] = 0x01
        r[6] = 0xFF; r[7] = 0x00; r[8] = 0x00; r[9] = 0xFF
        for i in 14...25 { r[i] = 0xFF }
        r[30] = 0xEE
        return r
    }()

    static let playStation: [HIDFixture] = playStationThirdParty + [
        // DualSense supplement: buttons[2] at USB [10], Bluetooth [11].
        supplement("dualsense.usb.rest", pid: dualSense, bt: false, dualSenseUSBRest, [.supplementByte(0x00)], "D-01 rest"),
        supplement("dualsense.usb.everything.plain", pid: dualSense, bt: false, dualSenseUSBEverything(buttons2: 0x07),
                   [.supplementByte(0x07)], "D-02: PS, touchpad, mute"),
        supplement("dualsense.usb.everything.edge", pid: dualSenseEdge, bt: false, dualSenseUSBEverything(buttons2: 0xF7),
                   [.supplementByte(0xF7)], "D-03: PS, mute, Fn left 0x10, Fn right 0x20, paddles 0x40 and 0x80 (SDL ps5, DS_EDGE_BUTTONS)"),
        supplement("dualsense.bt.everything.edge", pid: dualSenseEdge, bt: true, dualSenseBT(from: dualSenseUSBEverything(buttons2: 0xF7), tag: 0x51),
                   [.supplementByte(0xF7), .crcValid(true)], "D-04: 0x31 with the 0xA1 CRC; buttons[2] at [11]"),
        supplement("dualsense.bt.everything.edge.corrupt", pid: dualSenseEdge, bt: true, {
            var r = dualSenseBT(from: dualSenseUSBEverything(buttons2: 0xF7), tag: 0x51); r[11] = 0xE7; return r
        }(), [.ignored], "D-05: one bit flipped after the CRC was computed: the frame is dropped"),
        supplement("dualsense.bt.rest", pid: dualSense, bt: true, dualSenseBT(from: dualSenseUSBRest, tag: 0x02), [.supplementByte(0x00)], "D-06"),
        supplement("dualsense.bt.rest.77bytes", pid: dualSense, bt: true, Array(dualSenseBT(from: dualSenseUSBRest, tag: 0x02).prefix(77)), [.ignored], "D-07: wrong length"),
        supplement("dualsense.bt.compact.ps", pid: dualSense, bt: true, [0x01, 0x80, 0x80, 0x80, 0x80, 0x08, 0x00, 0x01, 0x00, 0x00],
                   [.supplementByte(0x01)], "D-08: PS5SimpleStatePacket_t, buttons[2] at [7], PS is bit 0"),
        supplement("dualsense.bt.simple78.ps", pid: dualSense, bt: true, [0x01, 0x80, 0x80, 0x80, 0x80, 0x08, 0x00, 0x01, 0x00, 0x00] + [UInt8](repeating: 0, count: 68),
                   [.supplementByte(0x01)], "D-09: the 78 byte simple report SDL also treats as simple"),
        supplement("dualsense.bt.compact.countermasked", pid: dualSense, bt: true, [0x01, 0x80, 0x80, 0x80, 0x80, 0x08, 0x00, 0xFD, 0x00, 0x00],
                   [.supplementByte(0x01)], "the counter in bits 2 to 7 of the simple report never reads as mute or paddles"),
        supplement("dualsense.usb.wronglength", pid: dualSense, bt: false, Array(dualSenseUSBRest.prefix(20)), [.ignored], "a 20 byte 0x01 is neither the 64 byte nor the simple report"),

        // DualShock 3 raw decoder.
        ds3("ds3.usb.rest", dualShock3Rest,
            [.buttonAbsent(0), .buttonAbsent(10), .hat(0, x: 0, y: 0), .axis(0, 0, tolerance: 0.001), .axis(1, 0, tolerance: 0.001),
             .axis(4, 0, tolerance: 0.001), .axis(6, 0, tolerance: 0.001), .motion(.accelX, 0, tolerance: 0.001), .motion(.accelZ, 0, tolerance: 0.001)],
            "S3-01: battery 5, accelerometer words 511"),
        ds3("ds3.usb.everything", dualShock3Everything,
            (0...12).map { .button($0, 1) } + [.hat(0, x: 1, y: 1), .axis(0, 1, tolerance: 0.001), .axis(1, -1, tolerance: 0.001),
             .axis(2, -1, tolerance: 0.001), .axis(3, 1, tolerance: 0.001), .axis(4, 1, tolerance: 0.001), .axis(5, 1, tolerance: 0.001),
             .axis(6, 1, tolerance: 0.001), .axis(15, 1, tolerance: 0.001)],
            "S3-02: [2] 0x3F, [3] 0xFF, PS, sticks to the corners, every pressure 0xFF, battery 0xEE"),
        ds3("ds3.usb.bogusff", { var r = dualShock3Rest; r[1] = 0xFF; r[3] = 0xFF; return r }(), [.ignored], "S3-03: [1] 0xFF is not a state report (SDL, hid-sony.c)"),
        ds3("ds3.usb.short26", Array(dualShock3Everything.prefix(26)), [.ignored], "S3-04: the report is 49 bytes"),
        ds3("ds3.usb.wrongid", { var r = dualShock3Everything; r[0] = 0x00; return r }(), [.ignored], "S3-05: only report 0x01 is a state (hid-sony.c rd[0] != 0x01 returns)"),
        ds3("ds3.usb.pressures.order", {
            var r = dualShock3Rest; r[24] = 0xFF; r[22] = 0x80; r[14] = 0x40; return r
        }(), [.axis(6, 1, tolerance: 0.001), .axis(9, 0.502, tolerance: 0.002), .axis(12, 0.251, tolerance: 0.002), .axis(7, 0, tolerance: 0.001)],
            "SDL button_axis_offsets: Cross 24, Triangle 22, Up 14 on axes 6, 9, 12"),
        ds3("ds3.usb.accel.onegx", { var r = dualShock3Rest; r[41] = 0x02; r[42] = 0x70; return r }(),
            [.motion(.accelX, 1, tolerance: 0.01)], "word 624 = 511 + 113 counts: 1 g on X (hid-sony.c SIXAXIS_ACC_RES_PER_G)"),
    ]

    /// Third party PS4 class stick (Razer Panthera 1532:0401, GP2040-CE's
    /// PS4 identity) and a PS5 class pad (GP2040-CE PS5 mode 2B81:0101),
    /// through the layouts the capability probe selects.
    private static func ps4(_ id: String, _ bytes: [UInt8], _ expect: [HIDFixture.Expect], _ locator: String,
                            status: HIDFixture.Status = .verified) -> HIDFixture {
        HIDFixture(id: id, device: "PS4 class arcade stick", transport: .usb,
                   route: .rawHID(vendorID: 0x1532, productID: 0x0401, transport: "USB"), reportID: bytes.first ?? 0,
                   hex: HIDFixture.hex(bytes + [UInt8](repeating: 0, count: max(0, 64 - bytes.count))), expect: expect, status: status,
                   citation: HIDFixture.Citation(source: "SDL_hidapi_ps4.c PS4StatePacket_t and HandleStatePacket 1120 to 1127; gp2040ce PS4Descriptors.h", locator: locator, date: "2026-10-20"))
    }
    static let playStationThirdParty: [HIDFixture] = [
        ps4("ps4class.rest", [0x01, 0x80, 0x80, 0x80, 0x80, 0x08, 0x00, 0x00, 0x00, 0x00],
            [.buttonAbsent(0), .buttonAbsent(13), .hat(0, x: 0, y: 0), .axis(0, 0, tolerance: 0.001), .axis(4, 0, tolerance: 0.001)], "PS4S-1"),
        ps4("ps4class.everything", [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xF2, 0xFF, 0x03, 0xFF, 0xFF],
            (0...13).map { .button($0, 1) } + [.hat(0, x: 1, y: 0), .axis(4, 1, tolerance: 0.001), .axis(5, 1, tolerance: 0.001), .axis(0, 1, tolerance: 0.001)],
            "PS4S-2: Sony numbering, hat east"),
        ps4("ps4class.victrix.digitaltriggers", [0x01, 0x80, 0x80, 0x80, 0x80, 0x08, 0x0C, 0x00, 0x00, 0x00],
            [.button(6, 1), .button(7, 1), .axis(4, 1, tolerance: 0.001), .axis(5, 1, tolerance: 0.001)],
            "PS4S-3: the digital L2 and R2 bits alone force the triggers full (SDL 1120 to 1127)"),
        ps4("ps4class.counteronly", [0x01, 0x80, 0x80, 0x80, 0x80, 0x08, 0x00, 0xFC, 0x00, 0x00],
            [.buttonAbsent(10), .buttonAbsent(13), .buttonAbsent(0)], "PS4S-4: bits 2 to 7 of byte 7 are the counter"),
        ps4("ps4class.wrongid", [0x05, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF], [.ignored], "only report 0x01 (and 0x11 over Bluetooth) is a state"),
        HIDFixture(id: "ps5class.gp2040.everything", device: "PS5 class pad (GP2040-CE)", transport: .usb,
                   route: .rawHID(vendorID: 0x2B81, productID: 0x0101, transport: "USB"), reportID: 0x01,
                   hex: HIDFixture.hex([0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0xF2, 0xFF, 0x07] + [UInt8](repeating: 0, count: 53)),
                   expect: (0...13).map { .button($0, 1) } + [.button(15, 1), .hat(0, x: 1, y: 0), .axis(4, 1, tolerance: 0.001), .axis(5, 1, tolerance: 0.001)],
                   status: .reconstructed,
                   citation: HIDFixture.Citation(source: "SDL_hidapi_ps5.c PS5StatePacketAlt_t", locator: "sticks 1 to 4, triggers 5 and 6, counter 7, buttons 8 to 10 (mute 0x04)", date: "2026-10-20")),
        HIDFixture(id: "ps.capability.ps4.arcadestick", device: "PS4 class arcade stick", transport: .feature,
                   route: .outputReport(builder: .accessRead(number: 1)), reportID: 0x03, hex: "", expect: [.custom("count=64")], status: .verified,
                   citation: HIDFixture.Citation(source: "placeholder", locator: "see the probe parse checks in the bench", date: "2026-10-20")),
    ]

    static let playStationSequences: [HIDSequenceFixture] = []
}
