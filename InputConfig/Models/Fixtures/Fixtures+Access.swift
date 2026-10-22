import Foundation

/// PlayStation Access controller (054C:0E5F): input reports (0x01 USB 64
/// bytes, 0x31 Bluetooth 78 bytes), the 956 byte stored profiles and the
/// feature report commands. Byte values come from accessports.log
/// (2026-10-18 and 10-19 on Ryleigh's unit) and the layouts in titania,
/// jfedor/ps-access and nsfm/dualsense-ts; no whole report was ever logged,
/// so every input fixture is reconstructed until the hidcapture hook
/// replaces it. Bluetooth CRCs: seed 0xA1 over bytes 0 to 73, little
/// endian at 74 (recomputed by the bench lint).
extension HIDFixtureCorpus {
    private static func accessCitation(_ locator: String, date: String = "2026-10-18") -> HIDFixture.Citation {
        HIDFixture.Citation(source: "accessports.log, titania access_input_msg, dualsense-ts access_hid.ts", locator: locator, date: date)
    }

    private static func accessInput(_ id: String, bt: Bool = false, reportID: UInt8? = nil, _ hex: String,
                                    _ expect: [HIDFixture.Expect], _ locator: String,
                                    status: HIDFixture.Status = .reconstructed) -> HIDFixture {
        HIDFixture(id: id, device: "PlayStation Access", transport: bt ? .bluetooth : .usb, route: .accessPorts,
                   reportID: reportID ?? (bt ? 0x31 : 0x01), hex: hex, expect: expect, status: status,
                   citation: accessCitation(locator))
    }

    // Byte 17 (USB) = sockets, 18 = center, stick press, PS, Profile.
    // Expected stick values use centered(v) = (v - 128) / 127.5.
    static let access: [HIDFixture] = [
        // F1: rest with a stick in E1, profile 1, charging 25 percent.
        accessInput("access.usb.rest.e1stick",
            """
            01 80 80 80 80 00 00 00 08 00 00 00 00 00 00 00 00 00 82 81 7f 80 00 00 00 00 00 00 00 00 00 00
            00 00 00 00 00 12 00 00 01 00 00 00 00 00 00 00 00 03 00 00 00 00 00 00 00 00 00 00 00 00 00 00
            """,
            [.accessPort(1, .stick), .accessPort(2, nil), .accessPort(3, nil), .accessPort(4, nil),
             .axis(6, 0.016, tolerance: 0.005), .axis(7, 0.008, tolerance: 0.005),
             .axis(8, -0.008, tolerance: 0.005), .axis(9, 0, tolerance: 0.005),
             .axisAbsent(10), .axisAbsent(12), .axisAbsent(14),
             .activeProfile(1), .switchingDisabled(false), .battery(level: 25, state: "charging"),
             .custom("buttons=")],
            "17:30:57 rest 19=130 20=129 21=127 22=128, 17:23 byte 50 = 3, byte 38 0x12"),

        // F2: the same over Bluetooth, tag 0x10 at [1], CRC valid.
        accessInput("access.bt.rest.e1stick", bt: true,
            """
            31 10 80 80 80 80 00 00 00 08 00 00 00 00 00 00 00 00 00 82 81 7f 80 00 00 00 00 00 00 00 00 00
            00 00 00 00 00 00 12 00 00 01 00 00 00 00 00 00 00 00 03 00 00 00 00 00 00 00 00 00 00 00 00 00
            00 00 00 00 00 00 00 00 00 00 66 2d b3 fd
            """,
            [.accessPort(1, .stick), .axis(6, 0.016, tolerance: 0.005), .axis(7, 0.008, tolerance: 0.005),
             .axis(8, -0.008, tolerance: 0.005), .axis(9, 0, tolerance: 0.005), .activeProfile(1),
             .switchingDisabled(false), .battery(level: 25, state: "charging"), .crcValid(true)],
            "F1 shifted up one byte; CRC computed (zlib, seed 0xA1), no Bluetooth capture exists yet"),

        // F3: everything pressed. Sockets 1 to 8, center, stick press, PS,
        // Profile; stick 255/0; E1 stick 255/0; E2 trigger 255; E3 button
        // pressed (0x80 0x80); E4 stick 0/255; profile 3 with switching off
        // (0x0B); battery full (0x2A).
        accessInput("access.bt.allpressed", bt: true,
            """
            31 20 80 80 80 80 00 00 00 08 00 00 00 00 00 00 00 ff 0f ff 00 ff 00 ff 00 80 80 00 ff 00 00 00
            00 00 00 00 00 00 2a 00 00 0b 31 00 00 00 00 00 00 00 23 00 00 00 00 00 00 00 00 00 00 00 00 00
            00 00 00 00 00 00 00 00 00 00 86 98 56 bf
            """,
            [.custom("buttons=40,41,42,43,44,45,46,47,48,49,50,51,58"),
             .axis(6, 0.996, tolerance: 0.005), .axis(7, -1, tolerance: 0.005),
             .axis(8, 0.996, tolerance: 0.005), .axis(9, -1, tolerance: 0.005),
             .axis(10, 1, tolerance: 0.001), .axisAbsent(11), .axisAbsent(12), .axisAbsent(13),
             .axis(14, -1, tolerance: 0.005), .axis(15, 0.996, tolerance: 0.005),
             .accessPort(1, .stick), .accessPort(2, .trigger), .accessPort(3, .button), .accessPort(4, .stick),
             .activeProfile(3), .switchingDisabled(true), .battery(level: 100, state: "full"), .crcValid(true)],
            "layout per titania and dualsense-ts; values chosen, CRC computed"),

        // F3bad: the same frame with its last CRC byte wrong: dropped.
        accessInput("access.bt.allpressed.badcrc", bt: true,
            """
            31 20 80 80 80 80 00 00 00 08 00 00 00 00 00 00 00 ff 0f ff 00 ff 00 ff 00 80 80 00 ff 00 00 00
            00 00 00 00 00 00 2a 00 00 0b 31 00 00 00 00 00 00 00 23 00 00 00 00 00 00 00 00 00 00 00 00 00
            00 00 00 00 00 00 00 00 00 00 86 98 56 40
            """,
            [.ignored, .crcValid(false)],
            "hid-playstation.c ps_check_crc32 drops a frame that fails the CRC"),

        // F4: F3 over USB, trailer bytes 56 to 63 from the dualsense-ts idle dump.
        accessInput("access.usb.allpressed",
            """
            01 80 80 80 80 00 00 00 08 00 00 00 00 00 00 00 ff 0f ff 00 ff 00 ff 00 80 80 00 ff 00 00 00 00
            00 00 00 00 00 2a 00 00 0b 31 00 00 00 00 00 00 00 23 00 00 00 00 00 00 a1 da 70 37 c6 2b 01 05
            """,
            [.custom("buttons=40,41,42,43,44,45,46,47,48,49,50,51,58"),
             .axis(6, 0.996, tolerance: 0.005), .axis(7, -1, tolerance: 0.005), .axis(10, 1, tolerance: 0.001),
             .axis(14, -1, tolerance: 0.005), .axis(15, 0.996, tolerance: 0.005),
             .accessPort(1, .stick), .accessPort(2, .trigger), .accessPort(3, .button), .accessPort(4, .stick),
             .activeProfile(3), .switchingDisabled(true), .battery(level: 100, state: "full")],
            "F3 shifted down one byte"),

        // F5: the compact Bluetooth report before the wake (DualSense simple shape).
        accessInput("access.bt.compact.beforewake", bt: true, reportID: 0x01,
            "01 80 80 80 80 08 00 00 00 00",
            [.ignored],
            "SDL_hidapi_ps5.c PS5SimpleStatePacket_t, 10 bytes"),

        // F6a and F6b: the E3 flap pair measured 18:35:24.903 onward (E2 holds
        // a stick, E3's nibble alternates 3 and 0 on consecutive reports).
        accessInput("access.usb.flap.e3present",
            """
            01 80 80 80 80 00 00 00 08 00 00 00 00 00 00 00 00 00 82 81 00 00 81 80 80 80 00 00 00 00 00 00
            00 00 00 00 00 12 00 00 01 03 00 00 00 00 00 00 00 30 00 00 00 00 00 00 00 00 00 00 00 00 00 00
            """,
            [.accessPort(2, .stick), .accessPort(3, .stick), .axis(10, 0.008, tolerance: 0.005), .axis(11, 0, tolerance: 0.005),
             .axis(12, 0, tolerance: 0.005), .axis(13, 0, tolerance: 0.005)],
            "18:35:24.903 to 18:37:21.060, 14,521 alternations"),
        accessInput("access.usb.flap.e3absent",
            """
            01 80 80 80 80 00 00 00 08 00 00 00 00 00 00 00 00 00 82 81 00 00 81 80 00 00 00 00 00 00 00 00
            00 00 00 00 00 12 00 00 01 00 00 00 00 00 00 00 00 30 00 00 00 00 00 00 00 00 00 00 00 00 00 00
            """,
            [.accessPort(2, .stick), .accessPort(3, nil), .axisAbsent(12), .axisAbsent(13)],
            "18:35:24.907, the other half of the flap"),

        // F7: an invalid plug in E4 (nibble 4, measured mid insertion).
        accessInput("access.usb.e4.invalidplug",
            """
            01 80 80 80 80 00 00 00 08 00 00 00 00 00 00 00 00 00 82 81 00 00 00 00 00 00 00 00 00 00 00 00
            00 00 00 00 00 12 00 00 01 40 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
            """,
            [.accessPort(4, .invalidPlug), .axisAbsent(14), .axisAbsent(15), .buttonAbsent(59), .accessPort(1, nil)],
            "\"byte 42 first moved: rest 0 now 4\" on the E4 insertion; dualsense-ts type value 4 = Invalid"),

        // F9: rest with a stick in E2 (18:32:46 and 18:35:24).
        accessInput("access.usb.rest.e2stick",
            """
            01 80 80 80 80 00 00 00 08 00 00 00 00 00 00 00 00 00 81 81 00 00 81 80 00 00 00 00 00 00 00 00
            00 00 00 00 00 12 00 00 01 00 00 00 00 00 00 00 00 30 00 00 00 00 00 00 00 00 00 00 00 00 00 00
            """,
            [.accessPort(2, .stick), .accessPort(1, nil), .axis(6, 0.008, tolerance: 0.005), .axis(7, 0.008, tolerance: 0.005),
             .axis(10, 0.008, tolerance: 0.005), .axis(11, 0, tolerance: 0.005), .axisAbsent(8), .axisAbsent(9), .custom("buttons=")],
            "18:32:46 \"19=129 20=129 21=0 22=0 23=129 24=128\", byte 49 = 0x30"),

        // F10: a stick in E4 deflected, profile 2 (18:38 to 18:39).
        accessInput("access.usb.e4stick.deflected",
            """
            01 80 80 80 80 00 00 00 08 00 00 00 00 00 00 00 00 00 81 81 00 00 00 00 00 00 b3 60 00 00 00 00
            00 00 00 00 00 12 00 00 02 30 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
            """,
            [.accessPort(4, .stick), .axis(14, 0.4, tolerance: 0.005), .axis(15, -0.251, tolerance: 0.005), .activeProfile(2)],
            "\"axis 14 in use (byte 27 rest 128 now 179)\", \"axis 15 (byte 28 rest 128 now 96)\", byte 42 = 0x30, byte 41 = 2"),

        // F11: a button device in E2, pressed (0x80 0x80), and released.
        accessInput("access.usb.e2button.pressed",
            """
            01 80 80 80 80 00 00 00 08 00 00 00 00 00 00 00 00 00 82 81 00 00 80 80 00 00 00 00 00 00 00 00
            00 00 00 00 00 12 00 00 01 00 00 00 00 00 00 00 00 10 00 00 00 00 00 00 00 00 00 00 00 00 00 00
            """,
            [.accessPort(2, .button), .button(57, 1), .axisAbsent(10), .axisAbsent(11)],
            "18:32:13 \"byte 23 rest 0 now 128\", \"byte 24 rest 0 now 128\", then \"E2 holds a button\""),
        accessInput("access.usb.e2button.released",
            """
            01 80 80 80 80 00 00 00 08 00 00 00 00 00 00 00 00 00 82 81 00 00 00 00 00 00 00 00 00 00 00 00
            00 00 00 00 00 12 00 00 01 00 00 00 00 00 00 00 00 10 00 00 00 00 00 00 00 00 00 00 00 00 00 00
            """,
            [.accessPort(2, .button), .buttonAbsent(57), .custom("buttons=")],
            "F11 with bytes 22 and 23 at 0"),

        // F12: profile byte 0 (after a 0x05 0x00 command, which the app never sends).
        accessInput("access.usb.profile.zero",
            """
            01 80 80 80 80 00 00 00 08 00 00 00 00 00 00 00 00 00 82 81 7f 80 00 00 00 00 00 00 00 00 00 00
            00 00 00 00 00 12 00 00 00 00 00 00 00 00 00 00 00 03 00 00 00 00 00 00 00 00 00 00 00 00 00 00
            """,
            [.activeProfile(0), .switchingDisabled(false)],
            "jfedor PROTOCOL.md: data 39 is 0 after 0x05 0x00"),

        // Reserved bits 4 to 7 of byte 18 are never buttons 52 to 55.
        accessInput("access.usb.reservedbits",
            """
            01 80 80 80 80 00 00 00 08 00 00 00 00 00 00 00 00 f0 82 81 7f 80 00 00 00 00 00 00 00 00 00 00
            00 00 00 00 00 12 00 00 01 00 00 00 00 00 00 00 00 03 00 00 00 00 00 00 00 00 00 00 00 00 00 00
            """,
            [.custom("buttons="), .buttonAbsent(52), .buttonAbsent(55)],
            "titania playstation_access_raw_button bits 12 to 15 reserved"),

        // F8: wrong lengths are not input reports.
        accessInput("access.bt.wronglength.63", bt: true,
            "31 10 " + String(repeating: "00 ", count: 61),
            [.ignored], "a 63 byte 0x31 is not the 78 byte input report", status: .verified),
        accessInput("access.usb.wronglength.65",
            "01 80 " + String(repeating: "00 ", count: 63),
            [.ignored], "a 65 byte 0x01 is not the 64 byte input report", status: .verified),

        // P1: her unit's Profile 1 as the reader parsed it on 10/18.
        HIDFixture(id: "access.profile.1.herunit", device: "PlayStation Access", transport: .feature,
                   route: .accessProfile(number: 1), reportID: 0x61, hex: HIDFixture.hex(accessProfile1Blob),
                   expect: [.custom("name=Profile 1"), .custom("number=1"), .custom("orientation=0"),
                            .custom("portActions=2:10,3:9,4:11"), .custom("stickAssignments=0:1,1:1"), .custom("toggles=")],
                   status: .reconstructed,
                   citation: accessCitation("profile 1 \"Profile 1\": socket 1=L3 ... E1=left stick E2=R1 E3=L1 E4=L2; uuid a24e4c67eb3a7048a9306875e4f73675; saved 1792081777977", date: "2026-10-19")),

        // P0: the built in base profile as logged.
        HIDFixture(id: "access.profile.0.base", device: "PlayStation Access", transport: .feature,
                   route: .accessProfile(number: 0), reportID: 0x61, hex: HIDFixture.hex(accessProfile0Blob),
                   expect: [.custom("name="), .custom("number=0"), .custom("portActions="), .custom("stickAssignments=0:1")],
                   status: .reconstructed,
                   citation: accessCitation("profile 0: socket 5=Circle socket 7=Options center=Cross stick press=L3", date: "2026-10-19")),

        // Pbad: zeros never parse.
        HIDFixture(id: "access.profile.zeros.rejected", device: "PlayStation Access", transport: .feature,
                   route: .accessProfile(number: 1), reportID: 0x61, hex: String(repeating: "00 ", count: 956),
                   expect: [.ignored], status: .verified,
                   citation: accessCitation("blob byte 0 must be 0x02 (jfedor PROTOCOL.md, titania)")),

        // Feature report commands, the exact 64 byte buffers (report ID first).
        HIDFixture(id: "access.cmd.read.profile1", device: "PlayStation Access", transport: .feature,
                   route: .outputReport(builder: .accessRead(number: 1)), reportID: 0x60, hex: "",
                   expect: [.bytes([0x60, 0x10] + [UInt8](repeating: 0, count: 62))], status: .verified,
                   citation: accessCitation("jfedor PROTOCOL.md read command 0x10 + N - 1; echo check 2026-10-18")),
        HIDFixture(id: "access.cmd.read.base", device: "PlayStation Access", transport: .feature,
                   route: .outputReport(builder: .accessRead(number: 0)), reportID: 0x60, hex: "",
                   expect: [.bytes([0x60, 0x0F] + [UInt8](repeating: 0, count: 62))], status: .verified,
                   citation: accessCitation("jfedor PROTOCOL.md base profile command 0x0F; read live 2026-10-19")),
        HIDFixture(id: "access.cmd.setactive.2", device: "PlayStation Access", transport: .feature,
                   route: .outputReport(builder: .accessSetActive(2)), reportID: 0x60, hex: "",
                   expect: [.bytes([0x60, 0x05, 0x02] + [UInt8](repeating: 0, count: 61))], status: .unverified,
                   citation: accessCitation("jfedor buildSetActiveCommand; never sent from this app")),
        HIDFixture(id: "access.cmd.write.profile1.packet0", device: "PlayStation Access", transport: .feature,
                   route: .outputReport(builder: .accessWrite(number: 1, blob: accessProfile1Blob, packet: 0)), reportID: 0x60, hex: "",
                   expect: [.bytes([0x60, 0x09, 0x00] + Array(accessProfile1Blob[0..<56]) + [UInt8](repeating: 0, count: 5))], status: .unverified,
                   citation: accessCitation("jfedor PROTOCOL.md write opcode 0x08 + N, 56 bytes per packet; never sent from this app")),
        HIDFixture(id: "access.cmd.write.profile1.packet17", device: "PlayStation Access", transport: .feature,
                   route: .outputReport(builder: .accessWrite(number: 1, blob: accessProfile1Blob, packet: 17)), reportID: 0x60, hex: "",
                   expect: [.bytes([0x60, 0x09, 0x11] + Array(accessProfile1Blob[952..<956]) + [0x0C, 0x47, 0xBA, 0xD3] + [UInt8](repeating: 0, count: 53))], status: .unverified,
                   citation: accessCitation("CRC-32 (zlib) of the 956 bytes = 0xD3BA470C, little endian at payload offset 6 of the last packet (jfedor, titania)")),
        HIDFixture(id: "access.cmd.write.base.refused", device: "PlayStation Access", transport: .feature,
                   route: .outputReport(builder: .accessWrite(number: 0, blob: accessProfile0Blob, packet: 0)), reportID: 0x60, hex: "",
                   expect: [.custom("count=0")], status: .verified,
                   citation: accessCitation("opcode 0x08 names nothing in any source; the base profile is never written")),
    ]

    static let accessSequences: [HIDSequenceFixture] = []

    /// Profile 1 of her unit: name "Profile 1", UUID a24e4c67..., sockets 1
    /// to 8 = L3, Left, Right, Circle, Triangle, Square, Up, Down, center
    /// Cross, stick press Options, the stick and E1 as the left stick, E2
    /// R1, E3 L1, E4 L2 (digital), saved 1792081777977. zlib CRC-32 0xD3BA470C.
    static let accessProfile1Blob: [UInt8] = {
        var p = [UInt8](repeating: 0, count: 956)
        p[0] = 0x02
        for (i, u) in "Profile 1".utf16.enumerated() { p[4 + 2 * i] = UInt8(u & 0xFF); p[5 + 2 * i] = UInt8(u >> 8) }
        let uuid: [UInt8] = [0xa2, 0x4e, 0x4c, 0x67, 0xeb, 0x3a, 0x70, 0x48, 0xa9, 0x30, 0x68, 0x75, 0xe4, 0xf7, 0x36, 0x75]
        for (i, b) in uuid.enumerated() { p[84 + i] = b }
        for (b, code) in [13, 7, 8, 1, 3, 4, 5, 6, 2, 15].enumerated() { p[100 + b * 5] = UInt8(code) }
        p[152] = 0x01; p[153] = 0x01
        p[197] = 0x01; p[198] = 0x01
        p[242] = 0x03; p[244] = 0x0A
        p[287] = 0x03; p[289] = 0x09
        p[332] = 0x03; p[334] = 0x0B
        for (i, b) in [0x39, 0xd5, 0x65, 0x40, 0xa1, 0x01, 0x00, 0x00].enumerated() { p[948 + i] = UInt8(b) }
        return p
    }()

    /// The built in base profile as logged: socket 5 Circle, socket 7
    /// Options, center Cross, stick press L3, the stick as the left stick.
    static let accessProfile0Blob: [UInt8] = {
        var p = [UInt8](repeating: 0, count: 956)
        p[0] = 0x02
        p[120] = 0x01; p[130] = 0x0F; p[140] = 0x02; p[145] = 0x0D
        p[152] = 0x01; p[153] = 0x01
        return p
    }()
}
