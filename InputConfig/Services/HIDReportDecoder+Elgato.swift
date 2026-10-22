import Foundation

/// Stream Deck report decoding, moved out of HIDReportDecoder.swift.
extension HIDReportDecoder {
    /// Elgato Stream Deck key states (see `StreamDeckFormat`). A report
    /// that is not a key report leaves the keys alone: a Plus sends its
    /// dials and touch strip on the same ID with another type byte, read by
    /// `decodeStreamDeckDialsAndStrip`, and other models' are ignored.
    static func decodeStreamDeck(report: Data, format: ControllerProfile.StreamDeckFormat,
                                 into state: inout ControllerState) {
        let bytes = Array(report)
        guard bytes.count >= 2, bytes[0] == 0x01 else { return }
        // Byte 1 of a gen2 report says what it carries: 0x00 keys, 0x02 the
        // touch strip, 0x03 the dials. Those two are short (an encoder
        // report is 4 + dials + 1 bytes, Elgato's HID documentation), so
        // the key length is required of key reports only.
        if format.keyOffset >= 4, bytes[1] != 0x00 {
            if format.dials > 0 || format.touchStrip { decodeStreamDeckDialsAndStrip(bytes, format: format, into: &state) }
            return
        }
        guard bytes.count >= format.keyOffset + format.keys else { return }
        let cols = format.mirrorColumns
        for key in 0..<format.keys {
            let source = cols > 0 ? (key - key % cols) + (cols - 1 - key % cols) : key
            state.buttons[ControllerProfile.StreamDeckFormat.firstSlot + key] =
                bytes[format.keyOffset + source] != 0 ? 1 : 0
        }
        // A turn or a gesture lasts until the next report.
        for slot in format.oneShotSlots { state.buttons[slot] = 0 }
    }

    /// The Stream Deck + dials (byte 1 = 3) and touch strip (byte 1 = 2),
    /// per python-elgato-streamdeck's StreamDeckPlus. Byte 4 says what
    /// happened. Dials: 0 is the four push states in bytes 5 to 8, 1 is a
    /// turn, each of those bytes a signed count of steps, positive
    /// clockwise. Touch strip: 1 a short tap, 2 a long press, 3 a swipe from
    /// the x in bytes 6 and 7 to the x in bytes 10 and 11 (little endian).
    /// A turn or gesture has no release of its own, so it is pressed for
    /// this report only and every other report from the Plus lets it go;
    /// the raw HID service turns it into a timed short press.
    private static func decodeStreamDeckDialsAndStrip(_ bytes: [UInt8], format: ControllerProfile.StreamDeckFormat,
                                                      into state: inout ControllerState) {
        guard bytes.count >= 5 else { return }
        var fired: Set<Int> = []
        switch bytes[1] {
        case 0x03 where format.dials > 0 && bytes.count >= 5 + format.dials:
            for dial in 0..<format.dials {
                let value = bytes[5 + dial]
                if bytes[4] == 0x00 {
                    state.buttons[format.dialPressSlot(dial)] = value != 0 ? 1 : 0
                } else if bytes[4] == 0x01 {
                    let steps = Int8(bitPattern: value)
                    if steps < 0 { fired.insert(format.dialTurnSlot(dial, clockwise: false)) }
                    if steps > 0 { fired.insert(format.dialTurnSlot(dial, clockwise: true)) }
                }
            }
        case 0x02 where format.touchStrip:
            switch bytes[4] {
            case 1: fired.insert(format.stripSlot(.tap))
            case 2: fired.insert(format.stripSlot(.longPress))
            case 3 where bytes.count >= 12:
                let start = Int(bytes[6]) | Int(bytes[7]) << 8
                let end = Int(bytes[10]) | Int(bytes[11]) << 8
                // A swipe that ends where it started went neither way.
                if end < start { fired.insert(format.stripSlot(.swipeLeft)) }
                if end > start { fired.insert(format.stripSlot(.swipeRight)) }
            default: break
            }
        default:
            return
        }
        for slot in format.oneShotSlots { state.buttons[slot] = fired.contains(slot) ? 1 : 0 }
    }
}
