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
