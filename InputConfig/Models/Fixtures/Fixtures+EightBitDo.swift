import Foundation

/// 8BitDo pads read from their own report, after SDL's 8BitDo driver
/// (SDL_hidapi_8bitdo.c, HIDAPI_Driver8BitDo_HandleStatePacket, libsdl-org
/// SDL main on 2026-11-07). No whole report was logged from a real pad, so
/// each is built from SDL's byte table and marked reconstructed.
extension HIDFixtureCorpus {
    private static func ultimate2(_ id: String, _ bytes: [UInt8], _ expect: [HIDFixture.Expect], _ locator: String) -> HIDFixture {
        HIDFixture(id: id, device: "8BitDo Ultimate 2 Wireless", transport: .bluetooth,
                   route: .rawHID(vendorID: 0x2DC8, productID: 0x6012, transport: nil),
                   reportID: bytes.first ?? 0, hex: HIDFixture.hex(bytes), expect: expect, status: .reconstructed,
                   citation: HIDFixture.Citation(source: "SDL_hidapi_8bitdo.c HandleStatePacket", locator: locator, date: "2026-11-07"))
    }

    /// A firmware 1.03 report (34 bytes, ID 0x03): D-pad centered (8),
    /// sticks at 0x7F, triggers released.
    static func ultimate2Report(hat: UInt8 = 8, sticks: [UInt8] = [0x7F, 0x7F, 0x7F, 0x7F], rt: UInt8 = 0, lt: UInt8 = 0,
                                face: UInt8 = 0, system: UInt8 = 0, back: UInt8 = 0) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: 34)
        r[0] = 0x03; r[1] = hat
        r[2] = sticks[0]; r[3] = sticks[1]; r[4] = sticks[2]; r[5] = sticks[3]
        r[6] = rt; r[7] = lt; r[8] = face; r[9] = system; r[10] = back
        return r
    }

    static let eightBitDo: [HIDFixture] = [
        ultimate2("ultimate2w.rest", ultimate2Report(),
                  [.buttonAbsent(0), .buttonAbsent(16), .axis(0, 0, tolerance: 0.001), .axis(3, 0, tolerance: 0.001),
                   .axis(4, 0, tolerance: 0.001), .hat(0, x: 0, y: 0)], "rest: 0x7F sticks, hat 8"),
        ultimate2("ultimate2w.face", ultimate2Report(face: 0x01 | 0x02 | 0x08 | 0x10),
                  [.button(0, 1), .button(1, 1), .button(2, 1), .button(3, 1), .buttonAbsent(18), .buttonAbsent(19)],
                  "byte 8: A 0x01, B 0x02, X 0x08, Y 0x10"),
        ultimate2("ultimate2w.shoulders.pl.pr", ultimate2Report(face: 0x04 | 0x20 | 0x40 | 0x80),
                  [.button(4, 1), .button(5, 1), .button(18, 1), .button(19, 1), .buttonAbsent(0)],
                  "byte 8: PR 0x04, PL 0x20, LB 0x40, RB 0x80"),
        ultimate2("ultimate2w.system", ultimate2Report(system: 0x04 | 0x08 | 0x10 | 0x20 | 0x40),
                  [.button(8, 1), .button(9, 1), .button(10, 1), .button(11, 1), .button(12, 1)],
                  "byte 9: View 0x04, Menu 0x08, Home 0x10, L3 0x20, R3 0x40"),
        ultimate2("ultimate2w.back", ultimate2Report(back: 0x03),
                  [.button(16, 1), .button(17, 1)], "byte 10: L4 0x01, R4 0x02"),
        ultimate2("ultimate2w.triggers.swapped", ultimate2Report(rt: 0xFF, lt: 0x00),
                  [.axis(5, 1, tolerance: 0.001), .axis(4, 0, tolerance: 0.001), .button(7, 1), .buttonAbsent(6)],
                  "byte 6 is the RIGHT trigger, byte 7 the left"),
        ultimate2("ultimate2w.sticks.ends", ultimate2Report(sticks: [0x00, 0xFF, 0xFF, 0x00]),
                  [.axis(0, -1, tolerance: 0.001), .axis(1, 1, tolerance: 0.001), .axis(2, 1, tolerance: 0.001), .axis(3, -1, tolerance: 0.001)],
                  "0x00 full left or up, 0xFF full right or down"),
        ultimate2("ultimate2w.hat.upright", ultimate2Report(hat: 1),
                  [.hat(0, x: 0.707, y: 0.707)], "byte 1 value 1: up and right"),
    ]
}
