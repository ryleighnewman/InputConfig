import Foundation

/// Elgato Stream Deck input reports, per model, from Elgato's HID
/// documentation (hid-general, hid-stream-deck-plus, hid-stream-deck-plus-xl)
/// and the python-elgato-streamdeck and node-elgato-stream-deck readers.
/// Report 0x01; gen1 (Original 0x0060, Minis) puts the keys from byte 1,
/// gen2 puts a command byte at 1 (0x00 keys, 0x02 touch strip, 0x03 dials),
/// a little endian length at 2 and 3, and the keys from byte 4. Keys land
/// on slots 22 and up, then dial presses, dial turns, the strip gestures.
extension HIDFixtureCorpus {
    private static func deck(_ id: String, pid: Int32, _ bytes: [UInt8], _ expect: [HIDFixture.Expect],
                             _ locator: String, status: HIDFixture.Status = .verified) -> HIDFixture {
        HIDFixture(id: id, device: String(format: "Stream Deck %04X", pid), transport: .usb,
                   route: .rawHID(vendorID: 0x0FD9, productID: pid, transport: nil),
                   reportID: bytes.first ?? 0x01, hex: HIDFixture.hex(bytes), expect: expect, status: status,
                   citation: HIDFixture.Citation(source: "Elgato HID documentation; python-elgato-streamdeck", locator: locator, date: "2026-10-20"))
    }
    private static func keys(_ pressed: [Int], of count: Int) -> [HIDFixture.Expect] {
        (0..<count).map { pressed.contains($0) ? .button(22 + $0, 1) : .buttonAbsent(22 + $0) }
    }
    private static func gen2(_ keys: Int, pressed: [Int]) -> [UInt8] {
        [0x01, 0x00, UInt8(keys), 0x00] + (0..<keys).map { pressed.contains($0) ? 1 : 0 }
    }
    private static func padded(_ bytes: [UInt8], to length: Int = 512) -> [UInt8] {
        bytes + [UInt8](repeating: 0, count: max(0, length - bytes.count))
    }

    // Stream Deck + slots: keys 22 to 29, dial presses 30 to 33, turns 34 to
    // 41 (left, right per dial), strip tap 42, long press 43, swipe left 44,
    // swipe right 45.
    static let elgato: [HIDFixture] = elgatoSiblings + [
        // 15 key gen2 (MK.2 0x0080; also 0x006D, 0x00A5, 0x00B9, 0x00E4)
        deck("elgato.mk2.rest", pid: 0x0080, gen2(15, pressed: []), keys([], of: 15), "hid-general Key / Button Press State Change, offset 0x04"),
        deck("elgato.mk2.key1", pid: 0x0080, gen2(15, pressed: [0]), keys([0], of: 15), "key 1 at byte 4"),
        deck("elgato.mk2.key15", pid: 0x0080, gen2(15, pressed: [14]), keys([14], of: 15), "key 15 at byte 18"),
        deck("elgato.mk2.all", pid: 0x0080, gen2(15, pressed: Array(0..<15)), keys(Array(0..<15), of: 15), "every key byte 1"),
        deck("elgato.mk2.encoderreport.nodials", pid: 0x0080, [0x01, 0x03, 0x05, 0x00, 0x01, 0x01, 0x00, 0x00, 0x00], [.ignored], "a dial report on a model without dials writes nothing"),
        deck("elgato.mk2.short", pid: 0x0080, [0x01, 0x00], [.ignored], "two bytes carry no keys"),
        deck("elgato.mk2.wrongid", pid: 0x0080, [0x02, 0x00, 0x0F, 0x00, 0x01] + [UInt8](repeating: 0, count: 14), [.ignored], "only report 0x01 is input"),
        deck("elgato.e4.module15.key15", pid: 0x00E4, gen2(15, pressed: [14]), keys([14], of: 15), "Module 15 Scissor, node modelInfo.ts 0x00E4", status: .unverified),

        // Original 2017 (0x0060): keys from byte 1, each row of 5 mirrored.
        deck("elgato.original.key1", pid: 0x0060, [0x01, 0x00, 0x00, 0x00, 0x00, 0x01] + [UInt8](repeating: 0, count: 11),
             [.button(22, 1), .buttonAbsent(26)], "gen1: key 1 is the fifth byte of row one (mirrored columns)"),
        deck("elgato.original.key5", pid: 0x0060, [0x01, 0x01] + [UInt8](repeating: 0, count: 15),
             [.button(26, 1), .buttonAbsent(22)], "gen1: byte 1 is key 5"),
        deck("elgato.original.key15", pid: 0x0060, [0x01] + [UInt8](repeating: 0, count: 10) + [0x01] + [UInt8](repeating: 0, count: 5),
             [.button(36, 1)], "gen1: byte 11 is key 15 (row three, mirrored)"),

        // Mini (0x0063): keys from byte 1, 65 byte fixed report.
        deck("elgato.mini.key6", pid: 0x0063, padded([0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01], to: 65), [.button(27, 1), .buttonAbsent(22)], "hid-stream-deck-mini fixed 65 byte structure, key 6 at byte 6"),

        // XL (0x006C)
        deck("elgato.xl.key32", pid: 0x006C, gen2(32, pressed: [31]), [.button(53, 1), .buttonAbsent(22)], "key 32 at byte 35"),
        deck("elgato.xl.all", pid: 0x006C, gen2(32, pressed: Array(0..<32)), keys(Array(0..<32), of: 32), "every key"),
        deck("elgato.xl.truncated35", pid: 0x006C, Array(gen2(32, pressed: [0]).prefix(35)), [.ignored], "35 bytes cannot carry 32 keys"),

        // Stream Deck + (0x0084)
        deck("elgato.plus.keys.rest", pid: 0x0084, gen2(8, pressed: []), keys([], of: 8) + [.buttonAbsent(34), .buttonAbsent(42)], "hid-stream-deck-plus keys"),
        deck("elgato.plus.key3", pid: 0x0084, gen2(8, pressed: [2]), [.button(24, 1), .buttonAbsent(22)], "the example in the Plus documentation"),
        deck("elgato.plus.dial2.press.9bytes", pid: 0x0084, [0x01, 0x03, 0x05, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00],
             [.button(31, 1), .buttonAbsent(30), .buttonAbsent(32), .buttonAbsent(33), .buttonAbsent(22)], "Encoders State Change at content length (4 + encoders + 1)"),
        deck("elgato.plus.dial2.press.padded", pid: 0x0084, padded([0x01, 0x03, 0x05, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00]),
             [.button(31, 1), .buttonAbsent(30)], "the same report padded to 512"),
        deck("elgato.plus.dial2.release", pid: 0x0084, [0x01, 0x03, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
             [.buttonAbsent(30), .buttonAbsent(31), .buttonAbsent(32), .buttonAbsent(33)], "press state 0"),
        deck("elgato.plus.dials.allpressed", pid: 0x0084, [0x01, 0x03, 0x05, 0x00, 0x00, 0x01, 0x01, 0x01, 0x01],
             [.button(30, 1), .button(31, 1), .button(32, 1), .button(33, 1)], "four presses"),
        deck("elgato.plus.dial4.cw", pid: 0x0084, [0x01, 0x03, 0x05, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01],
             [.button(41, 1), .buttonAbsent(40), .buttonAbsent(34)], "ROTATE: positive is clockwise"),
        deck("elgato.plus.dial1.ccw2", pid: 0x0084, [0x01, 0x03, 0x05, 0x00, 0x01, 0xFE, 0x00, 0x00, 0x00],
             [.button(34, 1), .buttonAbsent(35)], "ROTATE: INT8 -2 is two counterclockwise ticks (one pulse today)"),
        deck("elgato.plus.dials.opposite", pid: 0x0084, [0x01, 0x03, 0x05, 0x00, 0x01, 0xFF, 0x00, 0x00, 0x03],
             [.button(34, 1), .button(41, 1)], "two dials in one report"),
        deck("elgato.plus.dials.int8extremes", pid: 0x0084, [0x01, 0x03, 0x05, 0x00, 0x01, 0x7F, 0x80, 0x00, 0x00],
             [.button(35, 1), .button(36, 1)], "0x7F clockwise, 0x80 counterclockwise"),
        deck("elgato.plus.dials.nochange", pid: 0x0084, [0x01, 0x03, 0x05, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00], [.ignored], "a rotate report of zeros"),
        deck("elgato.plus.strip.tap", pid: 0x0084, [0x01, 0x02, 0x0A, 0x00, 0x01, 0x00, 0x90, 0x01, 0x32, 0x00],
             [.button(42, 1), .buttonAbsent(43)], "TAP at (400, 50), payload length 0x0A"),
        deck("elgato.plus.strip.longpress", pid: 0x0084, [0x01, 0x02, 0x0A, 0x00, 0x02, 0x00, 0x90, 0x01, 0x32, 0x00],
             [.button(43, 1), .buttonAbsent(42)], "PRESS (long)"),
        deck("elgato.plus.strip.flickright", pid: 0x0084, [0x01, 0x02, 0x0E, 0x00, 0x03, 0x00, 0x64, 0x00, 0x32, 0x00, 0xBC, 0x02, 0x32, 0x00],
             [.button(45, 1), .buttonAbsent(44)], "FLICK from x 100 to x 700"),
        deck("elgato.plus.strip.flickleft", pid: 0x0084, [0x01, 0x02, 0x0E, 0x00, 0x03, 0x00, 0xBC, 0x02, 0x32, 0x00, 0x64, 0x00, 0x32, 0x00],
             [.button(44, 1), .buttonAbsent(45)], "FLICK from x 700 to x 100"),
        deck("elgato.plus.strip.flick.endianness", pid: 0x0084, [0x01, 0x02, 0x0E, 0x00, 0x03, 0x00, 0x05, 0x01, 0x32, 0x00, 0x01, 0x02, 0x32, 0x00],
             [.button(45, 1)], "261 to 513 is rightward; a big endian misread would say left"),
        deck("elgato.plus.strip.flick.vertical", pid: 0x0084, [0x01, 0x02, 0x0E, 0x00, 0x03, 0x00, 0x2C, 0x01, 0x0A, 0x00, 0x2C, 0x01, 0x5A, 0x00],
             [.ignored], "end x equals start x: no swipe"),
        deck("elgato.plus.strip.flick.truncated", pid: 0x0084, [0x01, 0x02, 0x0E, 0x00, 0x03, 0x00, 0x64, 0x00, 0x32, 0x00], [.ignored], "a flick needs 12 bytes"),
        deck("elgato.plus.strip.unknowntype", pid: 0x0084, [0x01, 0x02, 0x0A, 0x00, 0x09, 0x00, 0x90, 0x01, 0x32, 0x00], [.ignored], "touch type 9 is nothing"),
        deck("elgato.plus.unknowncommand", pid: 0x0084, [0x01, 0x05, 0x00, 0x00], [.ignored], "command 5 is nothing"),
        deck("elgato.plus.nfc", pid: 0x0084, [0x01, 0x04, 0x04, 0x00, 0x41, 0x42, 0x43, 0x44], [.ignored], "NFC report on a Plus writes nothing"),
        deck("elgato.plus.wrongid", pid: 0x0084, [0x02, 0x03, 0x05, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01], [.ignored], "only report 0x01"),

        // Neo (0x009A): 8 keys then the two touch points.
        deck("elgato.neo.key8", pid: 0x009A, gen2(10, pressed: [7]), [.button(29, 1)], "key 8 at byte 11"),
        deck("elgato.neo.lefttouch", pid: 0x009A, gen2(10, pressed: [8]), [.button(30, 1)], "left touch point at byte 12", status: .unverified),
        deck("elgato.neo.righttouch", pid: 0x009A, gen2(10, pressed: [9]), [.button(31, 1)], "right touch point at byte 13", status: .unverified),
        deck("elgato.neo.eightbytes", pid: 0x009A, gen2(8, pressed: [0]), [.ignored], "12 bytes cannot carry the Neo's 10 controls"),

        // Pedal (0x0086)
        deck("elgato.pedal.left", pid: 0x0086, [0x01, 0x00, 0x03, 0x00, 0x01, 0x00, 0x00], [.button(22, 1), .buttonAbsent(23)], "left pedal byte 4"),
        deck("elgato.pedal.middle", pid: 0x0086, [0x01, 0x00, 0x03, 0x00, 0x00, 0x01, 0x00], [.button(23, 1)], "middle pedal byte 5"),
        deck("elgato.pedal.right", pid: 0x0086, [0x01, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01], [.button(24, 1)], "right pedal byte 6"),

        // Stream Deck + XL (0x00C6): keys 22 to 57, presses 58 to 63, turns 64 to 75, strip 76 to 79.
        deck("elgato.plusxl.key36", pid: 0x00C6, gen2(36, pressed: [35]), [.button(57, 1), .buttonAbsent(22)], "hid-stream-deck-plus-xl: 36 keys", status: .unverified),
        deck("elgato.plusxl.dial1.press", pid: 0x00C6, [0x01, 0x03, 0x07, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00], [.button(58, 1)], "6 encoders", status: .unverified),
        deck("elgato.plusxl.dial6.cw", pid: 0x00C6, [0x01, 0x03, 0x07, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01], [.button(75, 1)], "dial 6 clockwise", status: .unverified),
        deck("elgato.plusxl.strip.tap", pid: 0x00C6, [0x01, 0x02, 0x10, 0x00, 0x01, 0x00, 0x4C, 0x04, 0x32, 0x00] + [UInt8](repeating: 0, count: 10),
             [.button(76, 1)], "tap at x 1100 with length field 0x10", status: .unverified),
        deck("elgato.plusxl.strip.flickleft", pid: 0x00C6, [0x01, 0x02, 0x0E, 0x00, 0x03, 0x00, 0x7E, 0x04, 0x32, 0x00, 0x32, 0x00, 0x32, 0x00],
             [.button(78, 1)], "flick 1150 to 50", status: .unverified),

        // Studio (0x00AA): keys 22 to 53, presses 54 and 55, turns 56 to 59.
        deck("elgato.studio.key32", pid: 0x00AA, gen2(32, pressed: [31]), [.button(53, 1)], "python StreamDeckStudio.py 32 keys", status: .unverified),
        deck("elgato.studio.dial2.press", pid: 0x00AA, [0x01, 0x03, 0x03, 0x00, 0x00, 0x00, 0x01], [.button(55, 1)], "2 encoders", status: .unverified),
        deck("elgato.studio.dial1.ccw", pid: 0x00AA, [0x01, 0x03, 0x03, 0x00, 0x01, 0xFF, 0x00], [.button(56, 1)], "dial 1 counterclockwise", status: .unverified),
        deck("elgato.studio.nfc", pid: 0x00AA, [0x01, 0x04, 0x04, 0x00, 0x41, 0x42, 0x43, 0x44], [.ignored], "NFC read writes nothing", status: .unverified),
    ]

    /// The sibling product IDs of each family decode the same bytes.
    static let elgatoSiblings: [HIDFixture] =
        [Int32(0x0090), 0x00B3, 0x00B8].map { pid in
            deck("elgato.\(String(format: "%04x", pid)).mini.key6", pid: pid, padded([0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01], to: 65), [.button(27, 1), .buttonAbsent(22)], "Mini family: key 6 at byte 6")
        } + [Int32(0x006D), 0x00A5, 0x00B9].map { pid in
            deck("elgato.\(String(format: "%04x", pid)).15key.key15", pid: pid, gen2(15, pressed: [14]), [.button(36, 1), .buttonAbsent(22)], "15 key gen2: key 15 at byte 18")
        } + [Int32(0x008F), 0x00BA].map { pid in
            deck("elgato.\(String(format: "%04x", pid)).xl.key32", pid: pid, gen2(32, pressed: [31]), [.button(53, 1), .buttonAbsent(22)], "XL family: key 32 at byte 35")
        }

    static let elgatoSequences: [HIDSequenceFixture] = [
        HIDSequenceFixture(id: "elgato.plus.dial4.turn.pulses", route: .rawHID(vendorID: 0x0FD9, productID: 0x0084, transport: nil),
                           steps: [
                               .init(delayMs: 0, reportID: 0x01, hex: HIDFixture.hex([0x01, 0x03, 0x05, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01]), expect: [.button(41, 1)]),
                               .init(delayMs: 120, reportID: 0x01, hex: "", expect: [.buttonAbsent(41)]),
                               .init(delayMs: 0, reportID: 0x01, hex: HIDFixture.hex([0x01, 0x03, 0x05, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01]), expect: [.button(41, 1)]),
                               .init(delayMs: 10, reportID: 0x01, hex: HIDFixture.hex(gen2(8, pressed: [2])), expect: [.button(41, 1), .button(24, 1)]),
                               .init(delayMs: 120, reportID: 0x01, hex: "", expect: [.buttonAbsent(41), .button(24, 1)]),
                           ], status: .verified,
                           citation: HIDFixture.Citation(source: "RawHIDGamepad.pulse (hold 50 ms); gaps-elgato F-PL-23 and F-PL-26", locator: "a turn is a short press; a key report mid pulse does not cut it short", date: "2026-10-20")),
    ]
}
