import Foundation

/// Stateless decoder that turns a raw HID input report into a
/// `ControllerState` according to a profile's `ReportLayout`.
///
/// The mapping from button index to logical control follows the same
/// numbering InputConfig uses elsewhere:
///   0 = A,  1 = B,  2 = X,  3 = Y
///   4 = LB, 5 = RB, 6 = LT, 7 = RT
///   8 = Back/Select, 9 = Start, 10 = Home/Guide
///   11 = L3 (left stick click), 12 = R3 (right stick click)
///   13 = touchpad press, 14 = Share or Capture, 15 = Mute,
///   16-19 = paddles or back buttons, 20-21 = Fn buttons
///   The D-pad is hats[0]. The GameCube and Steam Controller decoders
///   number their own controls past the first few (see ButtonNames).
///
/// Axes (sticks positive = right and down on every path):
///   0 = LX, 1 = LY, 2 = RX, 3 = RY
///   4 = LT analog, 5 = RT analog (0...1)
///   6 and up = extra generic axes (sliders, dials, rudder, throttle)
enum HIDReportDecoder {

    static func decode(report: Data, profile: ControllerProfile) -> ControllerState {
        var state = ControllerState()
        switch profile.layout {
        case .xinput:
            decodeXInput(report: report, into: &state)
        case .dualShock3:
            decodeDualShock3(report: report, into: &state)
        case .dualShock4:
            decodeDualShock4(report: report, into: &state)
        case .dualSenseAlt:
            decodeDualSenseAlt(report: report, into: &state)
        case .xboxBluetooth(let share):
            XboxBluetoothLayout.decode(report: report, share: share, into: &state)
        case .switch2Pro:
            decodeSwitch2Pro(report: report, into: &state)
        case .switch2GameCube:
            decodeSwitch2GameCube(report: report, into: &state)
        case .switch2JoyConLeft:
            decodeSwitch2JoyCon(report: report, left: true, into: &state)
        case .switch2JoyConRight:
            decodeSwitch2JoyCon(report: report, left: false, into: &state)
        case .steamController2026:
            decodeSteamController2026(report: report, into: &state)
        case .eightBitDo:
            decodeEightBitDo(report: report, into: &state)
        case .streamDeck(let format):
            decodeStreamDeck(report: report, format: format, into: &state)
        case .generic(let layout):
            decodeGeneric(report: report, layout: layout, into: &state)
        }
        return state
    }


    // MARK: - Helpers

    @inline(__always)
    static func bit(_ value: UInt16, _ pos: Int) -> Float {
        return ((value >> pos) & 0x01) == 1 ? 1.0 : 0.0
    }

    @inline(__always)
    static func signedInt16(_ low: UInt8, _ high: UInt8) -> Float {
        let raw = Int16(bitPattern: UInt16(low) | (UInt16(high) << 8))
        // Map -32768...32767 to -1.0...1.0, with a small deadzone clamp.
        return max(-1.0, min(1.0, Float(raw) / 32767.0))
    }

    @inline(__always)
    static func unsignedToSigned(_ value: UInt8) -> Float {
        // 0...255 with 128 = center → -1.0 ... 1.0.
        // Divide by 127 (not 128) so the maximum positive raw value
        // (255) maps to exactly +1.0; with 128 it would max at
        // +0.992 and the visualizer's "at limit" detection never
        // fires. Negative max (0) maps to -1.008, which we clamp.
        return max(-1.0, min(1.0, (Float(value) - 128.0) / 127.0))
    }

    @inline(__always)
    static func setHat(_ state: inout ControllerState, _ index: Int, x: Float, y: Float) {
        state.hats[index] = (x: x, y: y)
    }
}

// MARK: - 8BitDo

extension HIDReportDecoder {
    /// The report IDs SDL's 8BitDo driver reads this way: 0x03 firmware
    /// without its enhanced mode, 0x04 enhanced over USB, 0x01 enhanced
    /// over Bluetooth.
    static let eightBitDoReportIDs: Set<UInt8> = [0x01, 0x03, 0x04]

    /// A stick byte as SDL reads it: 0x7F is the middle exactly, 0x00 full
    /// left or up, 0xFF full right or down.
    @inline(__always)
    static func eightBitDoStick(_ v: UInt8) -> Float {
        if v == 0x7F { return 0 }
        let d = Float(Int(v) - 0x7F)
        return max(-1, min(1, d < 0 ? d / 127 : d / 128))
    }

    /// SDL_hidapi_8bitdo.c, HIDAPI_Driver8BitDo_HandleStatePacket, for a
    /// pad with the extra buttons (Pro 2, Pro 3, Ultimate 2 Wireless): the
    /// face bits A 0x01, B 0x02, PR 0x04, X 0x08, Y 0x10, PL 0x20, LB 0x40,
    /// RB 0x80 at byte 8; View 0x04, Menu 0x08, Home 0x10, L3 0x20, R3 0x40
    /// at byte 9; L4 0x01, R4 0x02 at byte 10.
    static func decodeEightBitDo(report: Data, into state: inout ControllerState) {
        let b = Array(report)
        guard b.count >= 10, let id = b.first, eightBitDoReportIDs.contains(id) else { return }
        switch b[1] {
        case 0: state.hats[0] = (0, 1)
        case 1: state.hats[0] = (0.707, 0.707)
        case 2: state.hats[0] = (1, 0)
        case 3: state.hats[0] = (0.707, -0.707)
        case 4: state.hats[0] = (0, -1)
        case 5: state.hats[0] = (-0.707, -0.707)
        case 6: state.hats[0] = (-1, 0)
        case 7: state.hats[0] = (-0.707, 0.707)
        default: state.hats[0] = (0, 0)
        }
        state.axes[0] = eightBitDoStick(b[2])
        state.axes[1] = eightBitDoStick(b[3])
        state.axes[2] = eightBitDoStick(b[4])
        state.axes[3] = eightBitDoStick(b[5])
        let lt = Float(b[7]) / 255, rt = Float(b[6]) / 255
        state.axes[4] = lt
        state.axes[5] = rt
        state.buttons[6] = lt > 0.12 ? 1 : 0
        state.buttons[7] = rt > 0.12 ? 1 : 0
        let f = UInt16(b[8]), s = UInt16(b[9])
        state.buttons[0] = bit(f, 0)    // A (south)
        state.buttons[1] = bit(f, 1)    // B (east)
        state.buttons[19] = bit(f, 2)   // PR
        state.buttons[2] = bit(f, 3)    // X (west)
        state.buttons[3] = bit(f, 4)    // Y (north)
        state.buttons[18] = bit(f, 5)   // PL
        state.buttons[4] = bit(f, 6)    // LB
        state.buttons[5] = bit(f, 7)    // RB
        state.buttons[8] = bit(s, 2)    // View
        state.buttons[9] = bit(s, 3)    // Menu
        state.buttons[10] = bit(s, 4)   // Home
        state.buttons[11] = bit(s, 5)   // L3
        state.buttons[12] = bit(s, 6)   // R3
        if b.count > 10 {
            let x = UInt16(b[10])
            state.buttons[16] = bit(x, 0)   // L4
            state.buttons[17] = bit(x, 1)   // R4
        }
    }
}
