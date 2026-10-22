import Foundation

/// The 2026 Steam Controller's state reports (0x42, 0x45, 0x47) through
/// the raw decoder, after SDL's Triton driver (controller_structs.h
/// TritonMTUNoQuat32TS_t, SDL_hidapi_steam.c). Byte table verified
/// against the controller on 2026-10-19 (proto-valve 2.4).
extension HIDFixtureCorpus {
    private static func steam(_ id: String, _ bytes: [UInt8], _ expect: [HIDFixture.Expect], _ locator: String,
                              status: HIDFixture.Status = .verified) -> HIDFixture {
        HIDFixture(id: id, device: "Steam Controller (2026)", transport: .usb,
                   route: .rawHID(vendorID: 0x28DE, productID: 0x1302, transport: nil),
                   reportID: bytes.first ?? 0, hex: HIDFixture.hex(bytes), expect: expect, status: status,
                   citation: HIDFixture.Citation(source: "SDL controller_structs.h TritonMTUNoQuat32TS_t; proto-valve 2.4", locator: locator, date: "2026-10-20"))
    }
    private static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }

    /// 0x45 at rest, IMU on, controller flat: accel Z 16384 (1 g).
    static let steam2026Rest: [UInt8] = {
        var r = [UInt8](repeating: 0, count: 46)
        r[0] = 0x45; r[1] = 0x01
        r[30] = 0x10; r[31] = 0x27            // IMU timestamp 10000
        r[38] = 0x00; r[39] = 0x40            // accel Z 16384
        return r
    }()
    /// 0x42 with everything: buttons 0x3FFFFFFF, triggers and sticks at the
    /// ends, both pads touched with pressure, gyro X 2048.
    static let steam2026Everything: [UInt8] = {
        var r: [UInt8] = [0x42, 0x2A, 0xFF, 0xFF, 0xFF, 0x3F]
        r += le16(32767) + le16(32767)                        // triggers
        r += le16(32767) + le16(32767) + le16(-32768 & 0xFFFF) + le16(-32768 & 0xFFFF)   // LX LY RX RY
        r += le16(16384) + le16(16384) + le16(32768 & 0xFFFF)  // left pad x y pressure
        r += le16(-16384 & 0xFFFF) + le16(-16384 & 0xFFFF) + le16(16384)   // right pad
        r += [0x10, 0x27, 0x00, 0x00]                          // timestamp
        r += le16(0) + le16(0) + le16(16384)                   // accel
        r += le16(2048) + le16(0) + le16(0)                    // gyro
        r += [UInt8](repeating: 0, count: 8)                   // quaternion, unused
        return r
    }()

    static let valve: [HIDFixture] = [
        steam("steam2026.rest.45", steam2026Rest,
              [.buttonAbsent(0), .buttonAbsent(25), .axis(0, 0, tolerance: 0.001), .axis(6, 0, tolerance: 0.001), .axis(11, 0, tolerance: 0.001),
               .hat(0, x: 0, y: 0), .motion(.accelZ, 1, tolerance: 0.001), .motion(.gyroX, 0, tolerance: 0.001)], "F10a"),
        steam("steam2026.everything.42", steam2026Everything,
              (0...25).map { .button($0, 1) } + [.hat(0, x: 0, y: 0),
               .axis(0, 1, tolerance: 0.001), .axis(1, -1, tolerance: 0.001), .axis(2, -1, tolerance: 0.001), .axis(3, 1, tolerance: 0.001),
               .axis(4, 1, tolerance: 0.001), .axis(5, 1, tolerance: 0.001),
               .axis(6, 0.5, tolerance: 0.001), .axis(7, -0.5, tolerance: 0.001), .axis(8, -0.5, tolerance: 0.001), .axis(9, 0.5, tolerance: 0.001),
               .axis(10, 1, tolerance: 0.001), .axis(11, 0.5, tolerance: 0.001),
               .motion(.gyroX, 2.182, tolerance: 0.005), .motion(.accelZ, 1, tolerance: 0.001)], "F10b: 54 byte 0x42"),
        steam("steam2026.everything.47", {
            var r = Array(steam2026Everything.prefix(18)); r[0] = 0x47; r[1] = 0x2B
            r += [0x34, 0x12]                                   // trackpad timestamp
            r += Array(steam2026Everything[18..<30])            // pads
            r += [0x10, 0x27]                                   // 16 bit IMU timestamp
            r += Array(steam2026Everything[34..<46])            // accel and gyro
            return r
        }(), (0...25).map { .button($0, 1) } + [.axis(6, 0.5, tolerance: 0.001), .axis(9, 0.5, tolerance: 0.001), .axis(11, 0.5, tolerance: 0.001),
              .motion(.gyroX, 2.182, tolerance: 0.005)], "F10c: pads two bytes later, IMU at the same offsets"),
        steam("steam2026.touchgating", {
            var r = steam2026Rest
            for (i, b) in (le16(32767) + le16(32767) + le16(32767)).enumerated() { r[18 + i] = b }
            return r
        }(), [.axis(6, 0, tolerance: 0.001), .axis(7, 0, tolerance: 0.001), .axis(10, 0, tolerance: 0.001)], "F10d: pad values without the touch bit stay 0"),
        steam("steam2026.wronglength45", Array(steam2026Rest.prefix(45)), [.ignored], "F10f: fewer than 46 bytes"),
        steam("steam2026.notstate44", { var r = steam2026Rest; r[0] = 0x44; return r }(), [.ignored], "F10f: 0x44 is not a state report"),
        steam("steam2026.sequencewrap", { var r = steam2026Rest; r[1] = 0xFF; return r }(), [.motion(.accelZ, 1, tolerance: 0.001)], "F10e: the sequence byte is not gated"),
    ]

    static let valveSequences: [HIDSequenceFixture] = []
}
