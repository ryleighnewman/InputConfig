import Foundation

/// Xbox One, Series and Elite Series 2 pads over Bluetooth, read raw when
/// GameController does not list one: the hand written layout SDL_hidapi_xboxone.c
/// (HandleButtons16, HandleButtons, HandleGuidePacket, HandleBatteryState)
/// and xpadneo (events.c, power.c, docs/descriptors) agree on.
///
/// Report 0x01: sticks as four little endian 16 bit values at 1 to 8
/// (0 up or left, 65535 down or right), LT and RT 10 bit at 9 to 12, the
/// hat at 13 (1 north clockwise to 8, 0 released), then the buttons:
/// - 16 bytes (One S in Windows mode): byte 14 A B X Y LB RB View Menu
///   as bits 0 to 7, byte 15 LS RS as bits 0 and 1; Guide in report 0x02.
/// - 17 bytes and longer (the unified BLE descriptor, One S Linux mode,
///   Elite 2): byte 14 A 0x01 B 0x02 X 0x08 Y 0x10 LB 0x40 RB 0x80, byte
///   15 View 0x04 Menu 0x08 Xbox 0x10 LS 0x20 RS 0x40, byte 16 bit 0 the
///   Consumer record: Share on a Series pad, a second View on a One S.
/// - Elite Series 2: paddles P1 to P4 as bits 0 to 3 and the profile 0 to
///   3 at (33, 35) in the 55 byte report (firmware 4.7), (17, 19) in the
///   39 byte one (4.8), (19, 17) in the 20 byte one (5.11 and later);
///   the paddles are reported only on profile 0, as SDL does.
/// Report 0x02: byte 1 bit 0 is the Xbox button. Report 0x04: battery.
enum XboxBluetoothLayout {
    static let vendorID: Int32 = 0x045E
    /// One S (02E0 Windows mode, 02FD Linux mode), Elite 2 (0B05, 0B22),
    /// Adaptive (0B0C), Series X|S (0B13, 0B20), 0B21 Adaptive BLE.
    static let productIDs: Set<Int32> = [0x02E0, 0x02FD, 0x0B05, 0x0B0C, 0x0B13, 0x0B20, 0x0B21, 0x0B22]
    static let shareProductIDs: Set<Int32> = [0x0B13, 0x0B20, 0x0B22]
    static let eliteProductIDs: Set<Int32> = [0x0B05, 0x0B22]

    static func isXboxBluetooth(vendorID vid: Int32, productID pid: Int32) -> Bool {
        vid == vendorID && productIDs.contains(pid)
    }

    static let buttonNames: [String] = [
        "A", "B", "X", "Y", "LB", "RB", "LT", "RT", "View", "Menu", "Xbox", "LS", "RS",
        "Button 13", "Share", "Button 15", "P1", "P2", "P3", "P4",
    ]

    static func profile(productID: Int32, productName: String) -> ControllerProfile {
        ControllerProfile(
            identifier: "xbox-bluetooth-\(productID)",
            displayName: productName,
            vendorID: vendorID,
            productMatches: [.exact(productID)],
            layout: .xboxBluetooth(share: shareProductIDs.contains(productID)),
            physicalButtonNames: buttonNames,
            requiredTransport: "Bluetooth"
        )
    }

    /// Where an Elite Series 2 report of this length keeps its paddles and profile.
    static func elitePaddleBytes(length: Int) -> (paddles: Int, profile: Int)? {
        switch length {
        case 55: return (33, 35)
        case 39: return (17, 19)
        case 20: return (19, 17)
        default: return nil
        }
    }

    /// Decodes one input report into the state (only the controls the
    /// report carries, so 0x02 and 0x04 merge with 0x01).
    static func decode(report: Data, share: Bool, into state: inout ControllerState) {
        let b = Array(report)
        guard let id = b.first else { return }
        func on(_ byte: Int, _ mask: UInt8) -> Float { b[byte] & mask != 0 ? 1 : 0 }
        switch id {
        case 0x02:
            guard b.count >= 2 else { return }
            state.buttons[10] = on(1, 0x01)
        case 0x01:
            guard b.count >= 16 else { return }
            func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
            func stick(_ i: Int) -> Float { max(-1, min(1, Float(u16(i)) / 65535 * 2 - 1)) }
            state.axes[0] = stick(1)
            state.axes[1] = stick(3)
            state.axes[2] = stick(5)
            state.axes[3] = stick(7)
            let lt = min(1, Float(u16(9) & 0x3FF) / 1023), rt = min(1, Float(u16(11) & 0x3FF) / 1023)
            state.axes[4] = lt
            state.axes[5] = rt
            state.buttons[6] = lt > 0.12 ? 1 : 0
            state.buttons[7] = rt > 0.12 ? 1 : 0
            switch b[13] {
            case 1: state.hats[0] = (0, 1)
            case 2: state.hats[0] = (0.707, 0.707)
            case 3: state.hats[0] = (1, 0)
            case 4: state.hats[0] = (0.707, -0.707)
            case 5: state.hats[0] = (0, -1)
            case 6: state.hats[0] = (-0.707, -0.707)
            case 7: state.hats[0] = (-1, 0)
            case 8: state.hats[0] = (-0.707, 0.707)
            default: state.hats[0] = (0, 0)
            }
            if b.count == 16 {
                state.buttons[0] = on(14, 0x01); state.buttons[1] = on(14, 0x02)
                state.buttons[2] = on(14, 0x04); state.buttons[3] = on(14, 0x08)
                state.buttons[4] = on(14, 0x10); state.buttons[5] = on(14, 0x20)
                state.buttons[8] = on(14, 0x40); state.buttons[9] = on(14, 0x80)
                state.buttons[11] = on(15, 0x01); state.buttons[12] = on(15, 0x02)
                return
            }
            state.buttons[0] = on(14, 0x01); state.buttons[1] = on(14, 0x02)
            state.buttons[2] = on(14, 0x08); state.buttons[3] = on(14, 0x10)
            state.buttons[4] = on(14, 0x40); state.buttons[5] = on(14, 0x80)
            state.buttons[9] = on(15, 0x08); state.buttons[10] = on(15, 0x10)
            state.buttons[11] = on(15, 0x20); state.buttons[12] = on(15, 0x40)
            let record = b.count >= 17 ? on(16, 0x01) : 0
            if share {
                state.buttons[8] = on(15, 0x04)
                state.buttons[14] = record
            } else {
                // One S: View is byte 15 bit 2 on firmware 5 and the AC Back
                // bit at byte 16 on 4.8 (SDL ORs them).
                state.buttons[8] = max(on(15, 0x04), record)
            }
            if let elite = elitePaddleBytes(length: b.count), b.count > max(elite.paddles, elite.profile) {
                let profile = Int(b[elite.profile] & 0x03)
                let paddles = profile == 0 ? b[elite.paddles] : 0
                state.buttons[16] = paddles & 0x01 != 0 ? 1 : 0
                state.buttons[17] = paddles & 0x02 != 0 ? 1 : 0
                state.buttons[18] = paddles & 0x04 != 0 ? 1 : 0
                state.buttons[19] = paddles & 0x08 != 0 ? 1 : 0
            }
        default:
            return
        }
    }

    /// Report 0x04 byte 1 (xpadneo power.c; SDL HandleBatteryState): bit 7
    /// online, bit 4 charging, bits 3 and 2 the mode (0 USB, 1 battery, 2
    /// Play and Charge), bits 1 and 0 the level (0 low 10, 1 normal 40, 2
    /// high 70, 3 full 100). nil for anything that is not a battery report.
    static func battery(report: Data) -> (level: Int, state: String)? {
        let b = Array(report)
        guard b.count >= 2, b[0] == 0x04 else { return nil }
        let v = b[1]
        guard v & 0x80 != 0 else { return nil }
        let level = [10, 40, 70, 100][Int(v & 0x03)]
        let charging = v & 0x10 != 0
        let mode = (v >> 2) & 0x03
        let state = charging ? "Charging" : (mode == 0 ? "Full" : "Discharging")
        return (level, state)
    }

    /// Output report 0x03 as SDL and xpadneo send it: the motor mask, the
    /// four magnitudes 0 to 100 (left trigger, right trigger, strong, weak),
    /// duration 0xFF, delay 0, loop count 0xEB. Documented; the app does
    /// not write to an Xbox pad while GameController owns it.
    static func rumbleReport(strong: Int, weak: Int, leftTrigger: Int, rightTrigger: Int) -> [UInt8] {
        func pct(_ v: Int) -> UInt8 { UInt8(max(0, min(100, v))) }
        var mask: UInt8 = 0
        if rightTrigger > 0 { mask |= 0x04 }
        if leftTrigger > 0 { mask |= 0x08 }
        if leftTrigger == 0 && rightTrigger == 0 { mask = 0x0F } else { mask |= (strong > 0 ? 0x02 : 0) | (weak > 0 ? 0x01 : 0) }
        return [0x03, mask, pct(leftTrigger), pct(rightTrigger), pct(strong), pct(weak), 0xFF, 0x00, 0xEB]
    }
}
