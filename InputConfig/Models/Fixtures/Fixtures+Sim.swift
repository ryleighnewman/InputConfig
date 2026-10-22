import Foundation

/// Sim racing, flight and arcade hardware read through the descriptor
/// parser and the GameControllerDB rows. The GP2040-CE Switch mode
/// descriptor is the board's own (gp2040ce/SwitchDescriptors.h), presented
/// as 0F0D:0092 version 0x0100, which matches the Hori Pokken row exactly.
extension HIDFixtureCorpus {
    /// gp2040ce/SwitchDescriptors.h switch_report_descriptor: 16 buttons,
    /// a 4 bit hat plus 4 constant bits, X Y Z Rz bytes, a vendor byte.
    static let gp2040SwitchDescriptor: [UInt8] = [0x05, 0x01, 0x09, 0x05, 0xA1, 0x01, 0x15, 0x00, 0x25, 0x01, 0x35, 0x00, 0x45, 0x01, 0x75, 0x01, 0x95, 0x10, 0x05, 0x09, 0x19, 0x01, 0x01, 0x29, 0x10, 0x10, 0x81, 0x02, 0x05, 0x01, 0x25, 0x07, 0x46, 0x3B, 0x01, 0x75, 0x04, 0x95, 0x01, 0x65, 0x14, 0x09, 0x39, 0x81, 0x42, 0x65, 0x00, 0x95, 0x01, 0x81, 0x01, 0x26, 0xFF, 0x00, 0x46, 0xFF, 0x00, 0x09, 0x30, 0x09, 0x31, 0x09, 0x32, 0x09, 0x35, 0x75, 0x08, 0x95, 0x04, 0x81, 0x02, 0x06, 0x00, 0xFF, 0xFF, 0x09, 0x20, 0x20, 0x95, 0x01, 0x81, 0x02, 0x0A, 0x21, 0x26, 0x26, 0x95, 0x08, 0x91, 0x02, 0xC0]

    private static func gpSwitch(_ id: String, _ bytes: [UInt8], _ expect: [HIDFixture.Expect], _ locator: String) -> HIDFixture {
        HIDFixture(id: id, device: "GP2040-CE (Switch mode)", transport: .usb,
                   route: .descriptor(name: "gp2040ce-switch", bytes: gp2040SwitchDescriptor, vendorID: 0x0F0D, productID: 0x0092, version: 0x0100),
                   reportID: 0, hex: HIDFixture.hex(bytes), expect: expect, status: .verified,
                   citation: HIDFixture.Citation(source: "gp2040ce/SwitchDescriptors.h; SDLGameControllerDBData Hori Pokken row", locator: locator, date: "2026-10-20"))
    }

    static let sim: [HIDFixture] = simWheels + [
        gpSwitch("gp2040.switch.rest", [0x00, 0x00, 0x08, 0x80, 0x80, 0x80, 0x80, 0x00],
                 [.buttonAbsent(0), .buttonAbsent(11), .hat(0, x: 0, y: 0), .axis(0, 0, tolerance: 0.01), .axis(3, 0, tolerance: 0.01)], "SW-1"),
        gpSwitch("gp2040.switch.everything", [0xFF, 0x3F, 0x02, 0xFF, 0xFF, 0xFF, 0xFF, 0x00],
                 (0...12).map { .button($0, 1) } + [.button(14, 1), .hat(0, x: 1, y: 0),
                  .axis(0, 1, tolerance: 0.01), .axis(1, 1, tolerance: 0.01), .axis(2, 1, tolerance: 0.01), .axis(3, 1, tolerance: 0.01)],
                 "SW-2: Y B A X L R ZL ZR minus plus L3 R3 Home Capture; the row names the first ten, the completion adds L3 11, R3 12, Home 10, Capture 14; the sticks the row never names take slots 0 to 3"),
        gpSwitch("gp2040.switch.vendorbyte", [0x00, 0x00, 0x08, 0x80, 0x80, 0x80, 0x80, 0xFF],
                 [.buttonAbsent(0), .buttonAbsent(22), .axis(0, 0, tolerance: 0.01)], "SW-3: the vendor byte is nothing"),
        gpSwitch("gp2040.switch.leftstick.down", [0x00, 0x00, 0x08, 0x80, 0xFF, 0x80, 0x80, 0x00],
                 [.axis(1, 1, tolerance: 0.01), .axis(0, 0, tolerance: 0.01)], "Y 0xFF is down, positive in the app"),
    ]

    /// hid-lg.c momo2_rdesc_fixed: the kernel's fixed MOMO Racing descriptor
    /// (X 10 bit, 10 buttons, vendor bits, vendor byte 3, Y gas byte 4, Z
    /// brake byte 5, vendor byte 6). Its length is not the original's, so
    /// the separate pedal table does not fire and the normalize order
    /// (gas then brake, by report order) is what the fixture checks.
    static let momoRacingFixedDescriptor: [UInt8] = [0x05, 0x01, 0x09, 0x04, 0xA1, 0x01, 0xA1, 0x02, 0x95, 0x01, 0x75, 0x0A, 0x15, 0x00, 0x26, 0xFF, 0x03, 0x35, 0x00, 0x46, 0xFF, 0x03, 0x09, 0x30, 0x81, 0x02, 0x95, 0x0A, 0x75, 0x01, 0x25, 0x01, 0x45, 0x01, 0x05, 0x09, 0x19, 0x01, 0x29, 0x0A, 0x81, 0x02, 0x06, 0x00, 0xFF, 0x09, 0x00, 0x95, 0x04, 0x81, 0x02, 0x95, 0x01, 0x75, 0x08, 0x26, 0xFF, 0x00, 0x46, 0xFF, 0x00, 0x09, 0x01, 0x81, 0x02, 0x05, 0x01, 0x09, 0x31, 0x81, 0x02, 0x09, 0x32, 0x81, 0x02, 0x06, 0x00, 0xFF, 0x09, 0x00, 0x81, 0x02, 0xC0, 0xA1, 0x02, 0x09, 0x02, 0x95, 0x07, 0x91, 0x02, 0xC0, 0xC0]
    /// hid-tmff2 hid-tmt300rs.c t300rs_rdesc_nrm_fixed: report 7 with X 16
    /// bit, then Rz brake, Z gas, Y clutch 0 to 1023 in 16 bit fields, a
    /// constant 16 bit field, 13 buttons, 11 constant bits, a hat.
    static let t300Descriptor: [UInt8] = [0x05, 0x01, 0x09, 0x04, 0xA1, 0x01, 0x09, 0x01, 0xA1, 0x00, 0x85, 0x07, 0x09, 0x30, 0x15, 0x00, 0x27, 0xFF, 0xFF, 0x00, 0x00, 0x35, 0x00, 0x47, 0xFF, 0xFF, 0x00, 0x00, 0x75, 0x10, 0x95, 0x01, 0x81, 0x02, 0x09, 0x35, 0x26, 0xFF, 0x03, 0x46, 0xFF, 0x03, 0x81, 0x02, 0x09, 0x32, 0x81, 0x02, 0x09, 0x31, 0x81, 0x02, 0x81, 0x03, 0x05, 0x09, 0x19, 0x01, 0x29, 0x0D, 0x25, 0x01, 0x45, 0x01, 0x75, 0x01, 0x95, 0x0D, 0x81, 0x02, 0x75, 0x0B, 0x95, 0x01, 0x81, 0x03, 0x05, 0x01, 0x09, 0x39, 0x25, 0x07, 0x46, 0x3B, 0x01, 0x55, 0x00, 0x65, 0x14, 0x75, 0x04, 0x81, 0x42, 0x65, 0x00, 0x81, 0x03, 0x85, 0x60, 0x06, 0x00, 0xFF, 0x09, 0x60, 0x75, 0x08, 0x95, 0x3F, 0x26, 0xFF, 0x7F, 0x15, 0x00, 0x46, 0xFF, 0x7F, 0x36, 0x00, 0x80, 0x91, 0x02, 0x85, 0x02, 0x09, 0x02, 0x81, 0x02, 0x09, 0x14, 0x85, 0x14, 0x81, 0x02, 0xC0, 0xC0]

    private static func wheel(_ id: String, device: String, descriptor: [UInt8], vid: Int32, pid: Int32, _ bytes: [UInt8],
                              _ expect: [HIDFixture.Expect], _ locator: String, status: HIDFixture.Status) -> HIDFixture {
        HIDFixture(id: id, device: device, transport: .usb,
                   route: .descriptor(name: id, bytes: descriptor, vendorID: vid, productID: pid, version: 0),
                   reportID: bytes.first ?? 0, hex: HIDFixture.hex(bytes), expect: expect, status: status,
                   citation: HIDFixture.Citation(source: "hid-lg.c; hid-tmff2 hid-tmt300rs.c; lgff_wheel_adapter reports.h", locator: locator, date: "2026-10-20"))
    }
    /// T300 report 7: X LE16, Rz LE16, Z LE16, Y LE16, a constant LE16, 3 button bytes, a hat byte.
    private static func t300Report(x: Int, brake: Int, gas: Int, clutch: Int, buttons: UInt16 = 0, hat: UInt8 = 8) -> [UInt8] {
        func le(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        return [0x07] + le(x) + le(brake) + le(gas) + le(clutch) + [0, 0] + [UInt8(buttons & 0xFF), UInt8(buttons >> 8), 0] + [hat]
    }

    static let simWheels: [HIDFixture] = [
        wheel("momo.racing.fixed.rest", device: "Logitech MOMO Racing", descriptor: momoRacingFixedDescriptor, vid: 0x046D, pid: 0xCA03,
              [0x00, 0x02, 0x00, 0x7F, 0xFF, 0xFF, 0x00],
              [.axis(0, 0, tolerance: 0.01), .axis(4, 0, tolerance: 0.01), .axis(5, 0, tolerance: 0.01), .buttonAbsent(0), .custom("duplicateAxes=")],
              "MOMO2-1 with the kernel's fixed descriptor: pedals 255 released", status: .reconstructed),
        wheel("momo.racing.fixed.everything", device: "Logitech MOMO Racing", descriptor: momoRacingFixedDescriptor, vid: 0x046D, pid: 0xCA03,
              [0xFF, 0xFF, 0x0F, 0x7F, 0x00, 0x00, 0x00],
              (0...9).map { .button($0, 1) } + [.axis(0, 1, tolerance: 0.01), .axis(4, 1, tolerance: 0.01), .axis(5, 1, tolerance: 0.01)],
              "MOMO2-2: X full, ten buttons, both pedals floored (0)", status: .reconstructed),
        wheel("t300.rest", device: "Thrustmaster T300 RS", descriptor: t300Descriptor, vid: 0x044F, pid: 0xB66E,
              t300Report(x: 0x8000, brake: 1023, gas: 1023, clutch: 1023),
              [.axis(0, 0, tolerance: 0.01), .axis(1, 0, tolerance: 0.01), .axis(4, 0, tolerance: 0.01), .axis(5, 0, tolerance: 0.01),
               .axisAbsent(2), .axisAbsent(3), .hat(0, x: 0, y: 0), .custom("duplicateAxes=")],
              "T300-1 with the pedals at 1023 (the assumed rest end)", status: .unverified),
        wheel("t300.everything", device: "Thrustmaster T300 RS", descriptor: t300Descriptor, vid: 0x044F, pid: 0xB66E,
              t300Report(x: 0xFFFF, brake: 0, gas: 0, clutch: 0, buttons: 0x1FFF, hat: 2),
              (0...12).map { .button($0, 1) } + [.axis(0, 1, tolerance: 0.01), .axis(1, 1, tolerance: 0.01), .axis(4, 1, tolerance: 0.01), .axis(5, 1, tolerance: 0.01), .hat(0, x: 1, y: 0)],
              "T300-2: full lock right, every button, every pedal floored (0), hat east", status: .unverified),
        wheel("t300.brake.half", device: "Thrustmaster T300 RS", descriptor: t300Descriptor, vid: 0x044F, pid: 0xB66E,
              t300Report(x: 0x8000, brake: 511, gas: 1023, clutch: 1023),
              [.axis(4, 0.5, tolerance: 0.01), .axis(5, 0, tolerance: 0.01)], "T300-3: brake half way", status: .unverified),
    ]

    static let simSequences: [HIDSequenceFixture] = []
}
