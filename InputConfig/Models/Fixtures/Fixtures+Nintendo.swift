import Foundation

/// Switch 2 Pro Controller (report 0x09), GameCube controller for Switch 2
/// (report 0x05) and the WUP-028 GameCube adapter (report 0x21), through
/// the raw decoders. Sources: SDL_hidapi_switch2.c, procon2-mac
/// InputReport.swift, ikz87 enable_hid.py, SDL_hidapi_gamecube.c.
extension HIDFixtureCorpus {
    /// A 12 bit stick pair packed Nintendo style: X low byte, then Y low
    /// nibble over X high nibble, then Y high byte.
    static func switch2Stick(_ x: Int, _ y: Int) -> [UInt8] {
        [UInt8(x & 0xFF), UInt8((y & 0x0F) << 4 | (x >> 8) & 0x0F), UInt8(y >> 4)]
    }
    private static let center = 2048, full = 2048 + 1650, empty = 2048 - 1650

    private static func pro(_ id: String, _ head: [UInt8], _ expect: [HIDFixture.Expect], _ locator: String,
                            status: HIDFixture.Status = .reconstructed, length: Int = 64) -> HIDFixture {
        HIDFixture(id: id, device: "Switch 2 Pro Controller", transport: .usb,
                   route: .rawHID(vendorID: 0x057E, productID: 0x2069, transport: "USB"),
                   reportID: head.first ?? 0, hex: HIDFixture.hex(head + [UInt8](repeating: 0, count: max(0, length - head.count))),
                   expect: expect, status: status,
                   citation: HIDFixture.Citation(source: "procon2-mac InputReport.swift; ikz87 enable_hid.py; SDL_hidapi_switch2.c", locator: locator, date: "2026-10-20"))
    }
    private static func proReport(counter: UInt8, b3: UInt8 = 0, b4: UInt8 = 0, b5: UInt8 = 0,
                                  left: [UInt8] = switch2Stick(2048, 2048), right: [UInt8] = switch2Stick(2048, 2048)) -> [UInt8] {
        [0x09, counter, 0x00, b3, b4, b5] + left + right
    }

    private static func pro05(_ id: String, _ bytes: [UInt8], _ expect: [HIDFixture.Expect], _ locator: String,
                              status: HIDFixture.Status = .verified) -> HIDFixture {
        HIDFixture(id: id, device: "Switch 2 Pro Controller", transport: .usb,
                   route: .rawHID(vendorID: 0x057E, productID: 0x2069, transport: "USB"),
                   reportID: 0x05, hex: HIDFixture.hex(bytes), expect: expect, status: status,
                   citation: HIDFixture.Citation(source: "ndeadly/switch2_controller_research hid_reports.md report 0x05 (captures); SDL_hidapi_switch2.c HandleSwitchProState and sensor block (1184-1197); hifihedgehog/HIDMaestro issue 66 byte table", locator: locator, date: "2026-10-21"))
    }
    private static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    /// Report 0x05 for the Pro: buttons at 5 to 8, sticks at 11 and 14, the
    /// IMU words at 0x31 (accel X, Y, Z as the app's frame reads them) and
    /// 0x37 (gyro X, Y, Z), int16 little endian. A flat pad at rest reads
    /// 4096 on accel Z (8 g full scale over 32767).
    private static func pro05Report(b5: UInt8 = 0, b6: UInt8 = 0, b7: UInt8 = 0, b8: UInt8 = 0,
                                    left: [UInt8] = switch2Stick(2048, 2048), right: [UInt8] = switch2Stick(2048, 2048),
                                    accel: (Int, Int, Int) = (0, 0, 4096), gyro: (Int, Int, Int) = (0, 0, 0)) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 64)
        out[0] = 0x05; out[5] = b5; out[6] = b6; out[7] = b7; out[8] = b8
        for (i, b) in left.enumerated() { out[11 + i] = b }
        for (i, b) in right.enumerated() { out[14 + i] = b }
        out[0x2B] = 0x10; out[0x2C] = 0x27                      // sensor timestamp 10000
        for (i, b) in (le16(accel.0) + le16(accel.1) + le16(accel.2)).enumerated() { out[0x31 + i] = b }
        for (i, b) in (le16(gyro.0) + le16(gyro.1) + le16(gyro.2)).enumerated() { out[0x37 + i] = b }
        return out
    }

    private static func jc2(_ id: String, left: Bool, _ bytes: [UInt8], _ expect: [HIDFixture.Expect], _ locator: String) -> HIDFixture {
        HIDFixture(id: id, device: left ? "Joy-Con 2 (L)" : "Joy-Con 2 (R)", transport: .usb,
                   route: .rawHID(vendorID: 0x057E, productID: left ? 0x2066 : 0x2067, transport: "USB"),
                   reportID: 0x05, hex: HIDFixture.hex(bytes), expect: expect, status: .reconstructed,
                   citation: HIDFixture.Citation(source: "SDL_hidapi_switch2.c HandleMiniControllerStateL and R; proto-nintendo.md 4.5 button table", locator: locator, date: "2026-10-21"))
    }

    private static func gc2(_ id: String, _ bytes: [UInt8], _ expect: [HIDFixture.Expect], _ locator: String,
                            status: HIDFixture.Status = .unverified) -> HIDFixture {
        HIDFixture(id: id, device: "GameCube controller for Switch 2", transport: .usb,
                   route: .rawHID(vendorID: 0x057E, productID: 0x2073, transport: "USB"),
                   reportID: bytes.first ?? 0, hex: HIDFixture.hex(bytes), expect: expect, status: status,
                   citation: HIDFixture.Citation(source: "SDL_hidapi_switch2.c HandleGameCubeState and SDL_gamepad.c GameCube mapping", locator: locator, date: "2026-10-20"))
    }
    /// Report 0x05 with the given button bytes, sticks and triggers.
    private static func gc2Report(b5: UInt8 = 0, b6: UInt8 = 0, b7: UInt8 = 0,
                                  control: [UInt8] = switch2Stick(2048, 2048), cStick: [UInt8] = switch2Stick(2048, 2048),
                                  l: UInt8 = 0x28, r: UInt8 = 0x28) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 64)
        out[0] = 0x05; out[5] = b5; out[6] = b6; out[7] = b7
        for (i, b) in control.enumerated() { out[11 + i] = b }
        for (i, b) in cStick.enumerated() { out[14 + i] = b }
        out[61] = l; out[62] = r
        return out
    }

    private static func adapter(_ id: String, _ bytes: [UInt8], _ expect: [HIDFixture.Expect], _ locator: String,
                                status: HIDFixture.Status = .verified) -> HIDFixture {
        HIDFixture(id: id, device: "GameCube Controller Adapter (port 1)", transport: .usb,
                   route: .rawHID(vendorID: 0x057E, productID: 0x0337, transport: "USB"),
                   reportID: 0x21, hex: HIDFixture.hex(bytes), expect: expect, status: status,
                   citation: HIDFixture.Citation(source: "SDL_hidapi_gamecube.c HIDAPI_DriverGameCube_HandleJoystickPacket", locator: locator, date: "2026-10-20"))
    }
    /// Report 0x21 with port 1's nine bytes: status, buttons1, buttons2, X, Y, CX, CY, L, R.
    private static func adapterReport(_ port1: [UInt8]) -> [UInt8] {
        [0x21] + port1 + [UInt8](repeating: 0, count: 36 - port1.count)
    }

    static let nintendo: [HIDFixture] = [
        // Switch 2 Pro, report 0x05 (the format the enabler asks for since 1.8)
        pro05("switch2pro05.rest", pro05Report(),
              [.buttonAbsent(0), .buttonAbsent(1), .axis(0, 0, tolerance: 0.01), .axis(1, 0, tolerance: 0.01), .hat(0, x: 0, y: 0),
               .motion(.accelZ, 1, tolerance: 0.001), .motion(.accelX, 0, tolerance: 0.001), .motion(.gyroX, 0, tolerance: 0.001)],
              "F-SW2P5-1: flat at rest, accel Z 4096 = 1 g"),
        pro05("switch2pro05.a", pro05Report(b5: 0x08), [.button(1, 1), .buttonAbsent(0), .buttonAbsent(2), .buttonAbsent(3)], "F-SW2P5-2: A is byte 5 bit 3 (SDL EAST)"),
        pro05("switch2pro05.b", pro05Report(b5: 0x04), [.button(0, 1), .buttonAbsent(1)], "F-SW2P5-3: B is byte 5 bit 2 (SDL SOUTH)"),
        pro05("switch2pro05.everything", pro05Report(b5: 0xCF, b6: 0x7F, b7: 0xC2, b8: 0x03,
                                                     left: switch2Stick(full, full), right: switch2Stick(empty, empty)),
              [.button(0, 1), .button(1, 1), .button(2, 1), .button(3, 1), .button(4, 1), .button(5, 1), .button(6, 1), .button(7, 1),
               .button(8, 1), .button(9, 1), .button(10, 1), .button(11, 1), .button(12, 1), .button(14, 1), .button(15, 1), .button(16, 1), .button(17, 1),
               .axis(4, 1, tolerance: 0.001), .axis(5, 1, tolerance: 0.001), .hat(0, x: 0, y: 1),
               .axis(0, 1, tolerance: 0.05), .axis(1, -1, tolerance: 0.05), .axis(2, -1, tolerance: 0.05), .axis(3, 1, tolerance: 0.05)],
              "F-SW2P5-4: every button, D-pad up, left stick full right and up, right stick full left and down"),
        pro05("switch2pro05.dpad.downright", pro05Report(b7: 0x05), [.hat(0, x: 1, y: -1), .buttonAbsent(4)], "F-SW2P5-5: down bit 0, right bit 2"),
        pro05("switch2pro05.gyro", pro05Report(gyro: (9416, 1000, -1000)),
              [.motion(.gyroX, 10.0, tolerance: 0.02), .motion(.gyroY, 1.062, tolerance: 0.005), .motion(.gyroZ, -1.062, tolerance: 0.005), .motion(.accelZ, 1, tolerance: 0.001)],
              "F-SW2P5-6: 34.8 rad/s over 32767 counts; word 0x37 is X, 0x39 is Y (away), 0x3B is Z (up)"),
        pro05("switch2pro05.accel.noseup", pro05Report(accel: (0, 2896, 2896)),
              [.motion(.accelY, 0.707, tolerance: 0.002), .motion(.accelZ, 0.707, tolerance: 0.002)],
              "F-SW2P5-7: nose up 45 degrees puts half the reaction on Y"),
        pro05("switch2pro05.imu.off", pro05Report(accel: (0, 0, 0)), [.button(0, 0), .axis(0, 0, tolerance: 0.01)],
              "F-SW2P5-8: all-zero accelerometer is the IMU off; no motion fields are set"),
        // Joy-Con 2 (L) and (R) on their own, report 0x05, held sideways
        jc2("switch2jcl.rest", left: true, pro05Report(), [.buttonAbsent(0), .buttonAbsent(6), .axis(0, 0, tolerance: 0.01), .axis(1, 0, tolerance: 0.01), .motion(.accelZ, 1, tolerance: 0.001)],
            "F-JC2L-1: at rest, flat"),
        jc2("switch2jcl.arrows", left: true, pro05Report(b7: 0x0A), [.button(1, 1), .button(0, 1), .buttonAbsent(2), .buttonAbsent(3)],
            "F-JC2L-2: Up (bit 1) is index 1, Left (bit 3) is index 0"),
        jc2("switch2jcl.rail.l.zl.gl", left: true, pro05Report(b6: 0x29, b7: 0xF0, b8: 0x02),
            [.button(4, 1), .button(5, 1), .button(6, 1), .button(7, 1), .button(8, 1), .button(11, 1), .button(14, 1), .button(16, 1), .axis(4, 1, tolerance: 0.001)],
            "F-JC2L-3: SL bit 5 and SR bit 4 of byte 7, L bit 6, ZL bit 7; Minus, stick press, Capture in byte 6; GL byte 8 bit 1"),
        jc2("switch2jcl.stick.upright.right", left: true, pro05Report(left: switch2Stick(full, 2048)),
            [.axis(0, 0, tolerance: 0.05), .axis(1, -1, tolerance: 0.05)],
            "F-JC2L-4: a push to the upright right is up (negative Y) with the rail on top"),
        jc2("switch2jcl.imu.turned", left: true, pro05Report(accel: (4096, 0, 0)),
            [.motion(.accelY, 1, tolerance: 0.002), .motion(.accelX, 0, tolerance: 0.002)],
            "F-JC2L-5: upright X becomes Y (away) after the quarter turn counterclockwise"),
        jc2("switch2jcr.rest", left: false, pro05Report(), [.buttonAbsent(0), .buttonAbsent(6), .axis(0, 0, tolerance: 0.01), .motion(.accelZ, 1, tolerance: 0.001)],
            "F-JC2R-1: at rest, flat"),
        jc2("switch2jcr.face", left: false, pro05Report(b5: 0x0F), [.button(0, 1), .button(1, 1), .button(2, 1), .button(3, 1)],
            "F-JC2R-2: Y bit 0 is index 3, X bit 1 index 2, B bit 2 index 1, A bit 3 index 0"),
        jc2("switch2jcr.rail.r.zr.gr", left: false, pro05Report(b5: 0xF0, b6: 0x56, b8: 0x01),
            [.button(4, 1), .button(5, 1), .button(6, 1), .button(7, 1), .button(9, 1), .button(10, 1), .button(12, 1), .button(15, 1), .button(17, 1), .axis(4, 1, tolerance: 0.001)],
            "F-JC2R-3: SL bit 5, SR bit 4, R bit 6, ZR bit 7 of byte 5; Plus, stick press, Home, C in byte 6; GR byte 8 bit 0"),
        jc2("switch2jcr.stick.upright.up", left: false, pro05Report(right: switch2Stick(2048, full)),
            [.axis(0, 1, tolerance: 0.05), .axis(1, 0, tolerance: 0.05)],
            "F-JC2R-4: a push to the upright up is right with the rail on top"),
        jc2("switch2jcr.imu.turned", left: false, pro05Report(accel: (4096, 0, 0)),
            [.motion(.accelY, -1, tolerance: 0.002), .motion(.accelX, 0, tolerance: 0.002)],
            "F-JC2R-5: upright X becomes -Y after the quarter turn clockwise"),
        jc2("switch2jcl.report09.ignored", left: true, [0x09, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x08, 0x80, 0x00, 0x08, 0x80] + [UInt8](repeating: 0, count: 52), [.ignored],
            "F-JC2L-6: only 0x05 is a Joy-Con 2 state"),
        // Switch 2 Pro, report 0x09 (the short format, still decoded)
        pro("switch2pro.rest", proReport(counter: 0x00),
            [.buttonAbsent(0), .buttonAbsent(10), .axis(0, 0, tolerance: 0.001), .axis(1, 0, tolerance: 0.001), .axis(4, 0, tolerance: 0.001), .hat(0, x: 0, y: 0)], "F-SW2P-1"),
        pro("switch2pro.a", proReport(counter: 0x01, b3: 0x02), [.button(1, 1), .buttonAbsent(0), .buttonAbsent(2)], "F-SW2P-2: A is bit 1 of byte 3"),
        pro("switch2pro.everything", proReport(counter: 0x02, b3: 0xFF, b4: 0xFF, b5: 0x1F, left: switch2Stick(full, full), right: switch2Stick(empty, empty)),
            [0, 1, 2, 3, 5, 7, 9, 12, 4, 6, 8, 11, 10, 14, 17, 16, 15].map { .button($0, 1) }
            + [.axis(4, 1, tolerance: 0.001), .axis(5, 1, tolerance: 0.001), .hat(0, x: 0, y: 0),
               .axis(0, 1, tolerance: 0.001), .axis(1, -1, tolerance: 0.001), .axis(2, -1, tolerance: 0.001), .axis(3, 1, tolerance: 0.001)],
            "F-SW2P-3: opposite D-pad bits cancel; sticks at 2048 plus and minus 1650"),
        pro("switch2pro.dpad.up", proReport(counter: 0x03, b4: 0x08), [.hat(0, x: 0, y: 1), .buttonAbsent(4)], "F-SW2P-4"),
        pro("switch2pro.dpad.downright", proReport(counter: 0x04, b4: 0x03), [.hat(0, x: 1, y: -1)], "F-SW2P-5"),
        pro("switch2pro.zl.c.gl", proReport(counter: 0x05, b4: 0x20, b5: 0x18), [.button(6, 1), .button(15, 1), .button(16, 1), .axis(4, 1, tolerance: 0.001), .buttonAbsent(17)], "F-SW2P-6"),
        pro("switch2pro.gr.capture.home", proReport(counter: 0x06, b5: 0x07), [.button(10, 1), .button(14, 1), .button(17, 1), .buttonAbsent(16)], "F-SW2P-7"),
        pro("switch2pro.leftstick.right", proReport(counter: 0x07, left: switch2Stick(full, center)), [.axis(0, 1, tolerance: 0.001), .axis(1, 0, tolerance: 0.001)], "F-SW2P-8"),
        pro("switch2pro.leftstick.up", proReport(counter: 0x08, left: switch2Stick(center, full)), [.axis(1, -1, tolerance: 0.001), .axis(0, 0, tolerance: 0.001)], "F-SW2P-9: up is negative in the app"),
        pro("switch2pro.leftstick.half", proReport(counter: 0x09, left: switch2Stick(center + 825, center)), [.axis(0, 0.5, tolerance: 0.001)], "F-SW2P-10 with the fallback span 1650; the pad's flash calibration replaces this"),
        pro("switch2pro.wrongid", [0x21, 0x00, 0x00, 0x00, 0x00, 0xFF] + [UInt8](repeating: 0, count: 58), [.ignored], "F-SW2P-12: only 0x05 and 0x09 are the Pro's states", status: .verified),
        pro("switch2pro.short4", [0x09, 0x00, 0x00, 0x02], [.ignored], "F-SW2P-13: fewer than 12 bytes", status: .verified, length: 4),
        pro("switch2pro.minimum12", proReport(counter: 0x00, b3: 0x02), [.button(1, 1)], "F-SW2P-14: exactly 12 bytes decode", length: 12),

        // GameCube controller for Switch 2, report 0x05
        gc2("switch2gc.rest", gc2Report(), [.buttonAbsent(0), .axis(0, 0, tolerance: 0.001), .axis(4, 0, tolerance: 0.001), .axis(5, 0, tolerance: 0.001), .hat(0, x: 0, y: 0)], "F-GC2-1: triggers rest at 40"),
        gc2("switch2gc.everything", gc2Report(b5: 0xCF, b6: 0x72, b7: 0xCF, control: switch2Stick(full, full), cStick: switch2Stick(empty, empty), l: 0xE8, r: 0xE8),
            [0, 1, 2, 3, 5, 7, 9, 10, 14, 15, 4, 6, 16].map { .button($0, 1) }
            + [.axis(4, 1, tolerance: 0.001), .axis(5, 1, tolerance: 0.001), .hat(0, x: 0, y: 0),
               .axis(0, 1, tolerance: 0.001), .axis(1, -1, tolerance: 0.001), .axis(2, -1, tolerance: 0.001), .axis(3, 1, tolerance: 0.001)], "F-GC2-2"),
        gc2("switch2gc.a", gc2Report(b5: 0x08), [.button(0, 1), .buttonAbsent(1), .buttonAbsent(2), .buttonAbsent(3)], "F-GC2-3: A is bit 3 (code and SDL agree)"),
        gc2("switch2gc.b", gc2Report(b5: 0x01), [.button(1, 1), .buttonAbsent(3)], "F-GC2-4: SDL WEST slot, mapped b:b3 under the GameCube face style; a pad must confirm"),
        gc2("switch2gc.y", gc2Report(b5: 0x04), [.button(3, 1), .buttonAbsent(1)], "F-GC2-5: SDL SOUTH slot, mapped y:b2"),
        gc2("switch2gc.x", gc2Report(b5: 0x02), [.button(2, 1), .buttonAbsent(0)], "F-GC2-6"),
        gc2("switch2gc.clicks", gc2Report(b5: 0xC0, b7: 0xC0), [.button(5, 1), .button(7, 1), .button(4, 1), .button(6, 1), .button(16, 1), .axis(4, 1, tolerance: 0.001), .axis(5, 1, tolerance: 0.001)], "F-GC2-7: the clicks force the triggers full"),
        gc2("switch2gc.triggers.half", gc2Report(l: 0x88, r: 0x88), [.axis(4, 0.5, tolerance: 0.001), .axis(5, 0.5, tolerance: 0.001)], "F-GC2-8 with zero 40"),
        gc2("switch2gc.trigger.belowrest", gc2Report(l: 0x1E), [.axis(4, 0, tolerance: 0.001)], "F-GC2-9: clamped"),
        gc2("switch2gc.dpadleft.menu", gc2Report(b6: 0x72, b7: 0x08), [.hat(0, x: -1, y: 0), .button(9, 1), .button(10, 1), .button(14, 1), .button(15, 1)], "F-GC2-10"),
        gc2("switch2gc.cstick.down", gc2Report(cStick: switch2Stick(center, empty)), [.axis(3, 1, tolerance: 0.001), .axis(2, 0, tolerance: 0.001)], "F-GC2-11"),
        gc2("switch2gc.imu", { var r = gc2Report(); r[0x35] = 0x00; r[0x36] = 0x10; r[0x37] = 0xCC; r[0x38] = 0x0C; return r }(),
            [.motion(.accelZ, 1, tolerance: 0.001), .motion(.gyroX, 3.47, tolerance: 0.01)],
            "F-GC2-14: the same IMU block as the Pro: accel Z 4096, gyro X 3276 counts", status: .reconstructed),
        gc2("switch2gc.truncated62", Array(gc2Report(b5: 0xCF).prefix(62)), [.ignored], "F-GC2-12: fewer than 63 bytes", status: .verified),
        gc2("switch2gc.report09.ignored", proReport(counter: 0x00, b3: 0x02) + [UInt8](repeating: 0, count: 52), [.ignored], "F-GC2-13: 0x09 at the GameCube profile is not its state", status: .verified),

        // GameCube adapter WUP-028, port 1
        adapter("gcadapter.port1.rest", adapterReport([0x10, 0x00, 0x00, 0x80, 0x80, 0x80, 0x80, 0x20, 0x20]),
                [.buttonAbsent(0), .axis(0, 0, tolerance: 0.001), .axis(1, 0, tolerance: 0.001), .axis(4, 0, tolerance: 0.001), .hat(0, x: 0, y: 0)], "F-GCA-1: triggers below 40 clamp to 0"),
        adapter("gcadapter.port1.everything", adapterReport([0x10, 0x0F, 0x0F, 0xD8, 0xD8, 0x28, 0x28, 0xFF, 0xFF]),
                [0, 1, 2, 3, 9, 5, 7, 4, 6].map { .button($0, 1) }
                + [.axis(0, 1, tolerance: 0.001), .axis(1, -1, tolerance: 0.001), .axis(2, -1, tolerance: 0.001), .axis(3, 1, tolerance: 0.001),
                   .axis(4, 1, tolerance: 0.001), .axis(5, 1, tolerance: 0.001), .hat(0, x: 0, y: 0)], "F-GCA-2: 216 is full, Y up is the high value"),
        adapter("gcadapter.port1.dpad.up", adapterReport([0x10, 0x80, 0x00, 0x80, 0x80, 0x80, 0x80, 0x28, 0x28]), [.hat(0, x: 0, y: 1)], "F-GCA-3"),
        adapter("gcadapter.port1.dpad.leftdown", adapterReport([0x10, 0x50, 0x00, 0x80, 0x80, 0x80, 0x80, 0x28, 0x28]), [.hat(0, x: -1, y: -1)], "F-GCA-4"),
        adapter("gcadapter.port1.stick.halfright", adapterReport([0x10, 0x00, 0x00, 0xAC, 0x80, 0x80, 0x80, 0x28, 0x28]), [.axis(0, 0.5, tolerance: 0.001)], "F-GCA-5: 172 over 40 to 216"),
        adapter("gcadapter.port1.lclick", adapterReport([0x10, 0x00, 0x08, 0x80, 0x80, 0x80, 0x80, 0x28, 0x28]), [.button(4, 1), .button(6, 1), .axis(4, 0, tolerance: 0.001)], "F-GCA-6: the click does not force the analog L"),
        adapter("gcadapter.port1.trigger.overrange", adapterReport([0x10, 0x00, 0x00, 0x80, 0x80, 0x80, 0x80, 0xFF, 0x28]), [.axis(4, 1, tolerance: 0.001)], "F-GCA-14: clamped at 216"),
        adapter("gcadapter.wrongid", [0x22] + [UInt8](repeating: 0, count: 36), [.ignored], "F-GCA-13"),
    ]

    static let nintendoSequences: [HIDSequenceFixture] = [
        HIDSequenceFixture(id: "switch2pro.rest.learning", route: .rawHID(vendorID: 0x057E, productID: 0x2069, transport: "USB"),
                           steps: [
                               .init(delayMs: 0, reportID: 0x09, hex: HIDFixture.hex(proReport(counter: 0x10, left: switch2Stick(0x820, 0x7F0), right: switch2Stick(0x820, 0x7F0)) + [UInt8](repeating: 0, count: 52)),
                                     expect: [.axis(0, 0, tolerance: 0.02), .axis(1, 0, tolerance: 0.02), .axis(2, 0, tolerance: 0.02), .axis(3, 0, tolerance: 0.02)]),
                               .init(delayMs: 0, reportID: 0x09, hex: HIDFixture.hex(proReport(counter: 0x11, left: switch2Stick(0x820, 0x7F0), right: switch2Stick(0x820, 0x7F0)) + [UInt8](repeating: 0, count: 52)),
                                     expect: [.axis(0, 0, tolerance: 0.02)]),
                               .init(delayMs: 0, reportID: 0x09, hex: HIDFixture.hex(proReport(counter: 0x12, b3: 0xFF, b4: 0xFF, b5: 0x1F, left: switch2Stick(full, full), right: switch2Stick(empty, empty)) + [UInt8](repeating: 0, count: 52)),
                                     expect: [.axis(0, 1, tolerance: 0.03), .axis(1, -1, tolerance: 0.03), .button(1, 1)]),
                           ], status: .reconstructed,
                           citation: HIDFixture.Citation(source: "RawHIDGamepad.removeStickRest; gaps-nintendo F-SW2P-11", locator: "the rest offset 0.019 and -0.0097 is learned from the first report and removed", date: "2026-10-20")),
    ]
}
