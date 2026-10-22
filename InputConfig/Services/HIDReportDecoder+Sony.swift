import Foundation

/// DualShock 3 report decoding.
extension HIDReportDecoder {
    // MARK: - DualShock 3 layout

    /// Sony DualShock 3 input report 0x01, 49 bytes with the report ID at
    /// [0], as IOKit delivers it (hid-sony.c sixaxis_raw_event: anything
    /// but 49 bytes of report 0x01 is dropped; SDL_hidapi_ps3.c handles
    /// the state report alone). Buttons at 2 and 3, PS at 4, sticks 6 to 9,
    /// the ten pressures at 14 to 25, battery at 30, the accelerometer and
    /// gyro big endian at 41 to 48.
    ///
    /// Axes 6 to 15 are the pressures in SDL's order (Cross, Circle,
    /// Square, Triangle, L1, R1, Up, Down, Left, Right), 0 to 1. Motion is
    /// the accelerometer in g with the kernel's signs (113 counts per g,
    /// centered on 511; X = word - 511, Y and Z = 511 - word).
    static func decodeDualShock3(report: Data, into state: inout ControllerState) {
        let bytes = Array(report)
        guard bytes.count >= 49, bytes[0] == 0x01 else { return }
        // A report whose byte 1 is 0xFF is not a state report (SDL drops
        // these too); decoded, it could read as stray presses.
        if bytes[1] == 0xFF { return }

        let b2 = bytes[2]
        let b3 = bytes[3]

        // Byte 2 bits: Select(0), L3(1), R3(2), Start(3), D-Pad U(4), D-Pad R(5), D-Pad D(6), D-Pad L(7)
        state.buttons[8]  = bit(UInt16(b2), 0)  // Select
        state.buttons[11] = bit(UInt16(b2), 1)  // L3
        state.buttons[12] = bit(UInt16(b2), 2)  // R3
        state.buttons[9]  = bit(UInt16(b2), 3)  // Start
        // D-pad to hat[0] (matches MFi convention), up positive.
        let ds3Up = bit(UInt16(b2), 4)
        let ds3Right = bit(UInt16(b2), 5)
        let ds3Down = bit(UInt16(b2), 6)
        let ds3Left = bit(UInt16(b2), 7)
        state.hats[0] = (x: ds3Right - ds3Left, y: ds3Up - ds3Down)

        // Byte 3 bits: L2(0), R2(1), L1(2), R1(3), Triangle(4), Circle(5), Cross(6), Square(7)
        state.buttons[6]  = bit(UInt16(b3), 0)  // L2 (digital)
        state.buttons[7]  = bit(UInt16(b3), 1)  // R2 (digital)
        state.buttons[4]  = bit(UInt16(b3), 2)  // L1
        state.buttons[5]  = bit(UInt16(b3), 3)  // R1
        state.buttons[3]  = bit(UInt16(b3), 4)  // Triangle
        state.buttons[1]  = bit(UInt16(b3), 5)  // Circle
        state.buttons[0]  = bit(UInt16(b3), 6)  // Cross
        state.buttons[2]  = bit(UInt16(b3), 7)  // Square

        // PS button at byte 4 bit 0
        state.buttons[10] = bit(UInt16(bytes[4]), 0)

        // Sticks: bytes 6-9, unsigned 8-bit centered at 0x80
        state.axes[0] = unsignedToSigned(bytes[6])
        state.axes[1] = unsignedToSigned(bytes[7])
        state.axes[2] = unsignedToSigned(bytes[8])
        state.axes[3] = unsignedToSigned(bytes[9])

        // Analog trigger pressures
        state.axes[4] = Float(bytes[18]) / 255.0
        state.axes[5] = Float(bytes[19]) / 255.0

        // The other pressures, SDL_hidapi_ps3.c button_axis_offsets order.
        let pressureBytes = [24, 23, 25, 22, 20, 21, 14, 16, 17, 15]
        for (i, at) in pressureBytes.enumerated() {
            state.axes[6 + i] = Float(bytes[at]) / 255.0
        }

        // Accelerometer, big endian 10 bit words around 511.
        func word(_ i: Int) -> Float { Float(Int(bytes[i]) << 8 | Int(bytes[i + 1])) }
        let perG: Float = 113
        state.motion[.accelX] = (word(41) - 511) / perG
        state.motion[.accelZ] = (511 - word(43)) / perG
        state.motion[.accelY] = (511 - word(45)) / perG
    }

    /// Battery byte 30 of the DualShock 3 report (hid-sony.c
    /// sixaxis_parse_report): 0xEE charging, 0xEF full, else an index into
    /// 0, 1, 25, 50, 75, 100 percent. nil for a report that is not a state.
    static func dualShock3Battery(report: Data) -> (level: Int, state: String)? {
        let bytes = Array(report)
        guard bytes.count >= 49, bytes[0] == 0x01, bytes[1] != 0xFF else { return nil }
        switch bytes[30] {
        case 0xEE: return (100, "Charging")
        case 0xEF: return (100, "Full")
        case 0...5: return ([0, 1, 25, 50, 75, 100][Int(bytes[30])], "Discharging")
        default: return nil
        }
    }
}

extension HIDReportDecoder {
    // MARK: - DualShock 4 layout (Sony's pads and third party PS4 class pads)

    /// DualShock 4 input: USB report 0x01, 64 bytes, the common section at
    /// [1] (hid-playstation.c dualshock4_input_report_common; SDL
    /// PS4StatePacket_t): LX LY RX RY at 1 to 4; [5] hat in the low nibble
    /// (0 N to 7 NW, 8 released) and Square 0x10, Cross 0x20, Circle 0x40,
    /// Triangle 0x80; [6] L1 0x01, R1 0x02, L2 0x04, R2 0x08, Share 0x10,
    /// Options 0x20, L3 0x40, R3 0x80; [7] PS 0x01, touchpad 0x02, counter
    /// above; [8] L2 and [9] R2 analog. Over Bluetooth report 0x11 is 78
    /// bytes with the same section at [3] and the 0xA1 CRC at 74.
    /// Indices: Cross 0, Circle 1, Square 2, Triangle 3, L1 4, R1 5, L2 6,
    /// R2 7, Share 8, Options 9, PS 10, L3 11, R3 12, touchpad 13. A pad
    /// that sets only the digital L2 or R2 bit (a Victrix stick) forces the
    /// trigger axis full, as SDL does.
    static func decodeDualShock4(report: Data, into state: inout ControllerState) {
        let bytes = Array(report)
        let base: Int
        switch bytes.first {
        case 0x01 where bytes.count >= 10: base = 1
        case 0x11 where bytes.count == 78:
            guard SonyBluetoothCRC.inputReportIsWhole(bytes) else { return }
            base = 3
        default: return
        }
        decodePlayStationCommon(bytes, sticks: base, buttons: base + 4, triggers: base + 7, into: &state)
    }

    /// Third party PS5 class pads (SDL PS5StatePacketAlt_t): report 0x01
    /// with sticks at 1 to 4, triggers at 5 and 6, a counter at 7 and the
    /// DualSense button bytes at 8 to 10 (same bits as the DualShock 4's,
    /// with mute 0x04 in the third).
    static func decodeDualSenseAlt(report: Data, into state: inout ControllerState) {
        let bytes = Array(report)
        guard bytes.first == 0x01, bytes.count >= 11 else { return }
        decodePlayStationCommon(bytes, sticks: 1, buttons: 8, triggers: 5, into: &state)
        state.buttons[15] = bit(UInt16(bytes[10]), 2)   // mute
    }

    private static func decodePlayStationCommon(_ bytes: [UInt8], sticks: Int, buttons: Int, triggers: Int, into state: inout ControllerState) {
        guard bytes.count > max(sticks + 3, buttons + 2, triggers + 1) else { return }
        state.axes[0] = unsignedToSigned(bytes[sticks])
        state.axes[1] = unsignedToSigned(bytes[sticks + 1])
        state.axes[2] = unsignedToSigned(bytes[sticks + 2])
        state.axes[3] = unsignedToSigned(bytes[sticks + 3])
        let b0 = UInt16(bytes[buttons]), b1 = UInt16(bytes[buttons + 1]), b2 = UInt16(bytes[buttons + 2])
        state.buttons[2] = bit(b0, 4)    // Square
        state.buttons[0] = bit(b0, 5)    // Cross
        state.buttons[1] = bit(b0, 6)    // Circle
        state.buttons[3] = bit(b0, 7)    // Triangle
        state.buttons[4] = bit(b1, 0)    // L1
        state.buttons[5] = bit(b1, 1)    // R1
        state.buttons[8] = bit(b1, 4)    // Share or Create
        state.buttons[9] = bit(b1, 5)    // Options
        state.buttons[11] = bit(b1, 6)   // L3
        state.buttons[12] = bit(b1, 7)   // R3
        state.buttons[10] = bit(b2, 0)   // PS
        state.buttons[13] = bit(b2, 1)   // touchpad click
        let l2Bit = bit(b1, 2), r2Bit = bit(b1, 3)
        let l2 = max(Float(bytes[triggers]) / 255, l2Bit)
        let r2 = max(Float(bytes[triggers + 1]) / 255, r2Bit)
        state.axes[4] = l2
        state.axes[5] = r2
        state.buttons[6] = l2Bit > 0.5 || l2 > 0.12 ? 1 : 0
        state.buttons[7] = r2Bit > 0.5 || r2 > 0.12 ? 1 : 0
        switch b0 & 0x0F {
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
    }
}
