import Foundation

/// Switch 2 Pro, GameCube and stick decoding, moved out of HIDReportDecoder.swift.
extension HIDReportDecoder {
    // MARK: - Switch 2 Pro Controller layout

    /// The input report a started Switch 2 Pro Controller streams, about 60
    /// a second. Anything else it sends (command replies, other formats) is
    /// not a controller state and must not be decoded as one, or every
    /// button would read as released for a frame.
    static func isSwitch2ProInputReport(_ report: Data) -> Bool {
        (report.count >= 12 && report.first == 0x09) || (report.count >= 63 && report.first == 0x05)
    }

    /// The 64 byte format SDL asks every Switch 2 controller for (report
    /// 0x05, set with command 0x03/0x0A payload 05): buttons at 5 to 8,
    /// sticks at 11 to 16, the sensor timestamp at 0x2B and the IMU at 0x31
    /// to 0x3C (SDL_hidapi_switch2.c HandleSwitchProState and the sensor
    /// block after it). The enabler asks the Pro for this format too, so its
    /// motion sensors, which the start-up sequence switches on, are read.
    /// The short format 0x09 (`decodeSwitch2ProShort`) is still decoded in
    /// case a controller keeps sending it.
    static func decodeSwitch2Pro(report: Data, into state: inout ControllerState) {
        guard isSwitch2ProInputReport(report) else { return }
        if report.first == 0x09 { decodeSwitch2ProShort(report: report, into: &state); return }
        let bytes = Array(report)
        let d5 = UInt16(bytes[5]), d6 = UInt16(bytes[6]), d7 = UInt16(bytes[7]), d8 = UInt16(bytes[8])
        // [5] Y, X, B, A (SDL WEST, NORTH, SOUTH, EAST), R (bit 6), ZR (bit 7)
        state.buttons[2] = bit(d5, 0)    // Y
        state.buttons[3] = bit(d5, 1)    // X
        state.buttons[0] = bit(d5, 2)    // B
        state.buttons[1] = bit(d5, 3)    // A
        state.buttons[5] = bit(d5, 6)    // R
        state.buttons[7] = bit(d5, 7)    // ZR
        // [6] Minus, Plus, right stick press, left stick press, Home, Capture, C
        state.buttons[8] = bit(d6, 0)    // Minus
        state.buttons[9] = bit(d6, 1)    // Plus
        state.buttons[12] = bit(d6, 2)   // right stick press
        state.buttons[11] = bit(d6, 3)   // left stick press
        state.buttons[10] = bit(d6, 4)   // Home
        state.buttons[14] = bit(d6, 5)   // Capture
        state.buttons[15] = bit(d6, 6)   // C
        // [7] D-pad down, up, right, left; L (bit 6), ZL (bit 7)
        state.buttons[4] = bit(d7, 6)    // L
        state.buttons[6] = bit(d7, 7)    // ZL
        // [8] GR (bit 0), GL (bit 1)
        state.buttons[17] = bit(d8, 0)   // GR, the right back button
        state.buttons[16] = bit(d8, 1)   // GL, the left back button

        state.axes[4] = state.buttons[6] ?? 0
        state.axes[5] = state.buttons[7] ?? 0

        let down = bit(d7, 0), up = bit(d7, 1), right = bit(d7, 2), left = bit(d7, 3)
        state.hats[0] = (x: (left > 0.5 && right > 0.5) ? 0 : right - left,
                         y: (up > 0.5 && down > 0.5) ? 0 : up - down)

        let cal = Switch2Calibration.current(product: 0x2069)
        let leftStick = switch2Stick(bytes[11], bytes[12], bytes[13], calibration: cal?.left)
        let rightStick = switch2Stick(bytes[14], bytes[15], bytes[16], calibration: cal?.right)
        state.axes[0] = leftStick.x
        state.axes[1] = -leftStick.y
        state.axes[2] = rightStick.x
        state.axes[3] = -rightStick.y

        decodeSwitch2Motion(bytes, into: &state)
    }

    /// The IMU block of report 0x05, bytes 0x31 to 0x3C, as SDL reads it
    /// (SDL_hidapi_switch2.c, the sensor block of HandleStatePacket):
    /// accelerometer words at 0x31, 0x33, 0x35 and gyro words at 0x37,
    /// 0x39, 0x3B, int16 little endian. SDL hands out accel (w31, w35,
    /// -w33) and gyro (w37, w3B, -w39) in its frame (X right, Y up, Z toward
    /// the player); in the controller's frame the shared IMU code expects
    /// (X right, Y away from the player, Z up) that is X = w31, Y = w33,
    /// Z = w35, same for the gyro. Scales: 8 g full scale, and 2000 degrees
    /// per second (SDL's 34.8 rad/s coefficient; it switches to 40 when the
    /// timestamp rate reads off, UNVERIFIED here). A report whose
    /// accelerometer words are all zero has the IMU off; nothing is set, so
    /// gravity is not learned as zero.
    static func decodeSwitch2Motion(_ bytes: [UInt8], into state: inout ControllerState) {
        guard bytes.count >= 0x3D else { return }
        func s16(_ i: Int) -> Float { Float(Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8)) }
        let ax = s16(0x31), ay = s16(0x33), az = s16(0x35)
        guard ax != 0 || ay != 0 || az != 0 else { return }
        let accelScale: Float = 8.0 / 32767.0
        let gyroScale: Float = 34.8 / 32767.0
        state.motion[.accelX] = ax * accelScale
        state.motion[.accelY] = ay * accelScale
        state.motion[.accelZ] = az * accelScale
        state.motion[.gyroX] = s16(0x37) * gyroScale
        state.motion[.gyroY] = s16(0x39) * gyroScale
        state.motion[.gyroZ] = s16(0x3B) * gyroScale
    }

    /// Switch 2 Pro Controller, USB, report 0x09. Offsets after the report
    /// ID byte, as measured on the hardware by the community (see
    /// Switch2USBEnabler):
    ///   [2] B, A, Y, X, R, ZR, Plus, right stick press (bit 0 first)
    ///   [3] D-pad down, right, left, up, L, ZL, Minus, left stick press
    ///   [4] Home, Capture, GR, GL, C
    ///   [5...7] left stick, [8...10] right stick: 12-bit X and Y packed into
    ///   three bytes, about 2048 at rest and about 1650 from rest to full
    ///   tilt, Y larger when pushed up.
    static func decodeSwitch2ProShort(report: Data, into state: inout ControllerState) {
        guard report.count >= 12, report.first == 0x09 else { return }
        let bytes = Array(report)
        // Payload index k is byte k + 1, after the report ID.
        let b2 = UInt16(bytes[3]), b3 = UInt16(bytes[4]), b4 = UInt16(bytes[5])

        // Face buttons by position, as everywhere in the app: the bottom
        // one is 0, and on a Nintendo pad that is B.
        state.buttons[0] = bit(b2, 0)    // B
        state.buttons[1] = bit(b2, 1)    // A
        state.buttons[2] = bit(b2, 2)    // Y
        state.buttons[3] = bit(b2, 3)    // X
        state.buttons[5] = bit(b2, 4)    // R
        state.buttons[7] = bit(b2, 5)    // ZR
        state.buttons[9] = bit(b2, 6)    // Plus
        state.buttons[12] = bit(b2, 7)   // right stick press
        state.buttons[4] = bit(b3, 4)    // L
        state.buttons[6] = bit(b3, 5)    // ZL
        state.buttons[8] = bit(b3, 6)    // Minus
        state.buttons[11] = bit(b3, 7)   // left stick press
        state.buttons[10] = bit(b4, 0)   // Home
        state.buttons[14] = bit(b4, 1)   // Capture
        state.buttons[17] = bit(b4, 2)   // GR, the right back button
        state.buttons[16] = bit(b4, 3)   // GL, the left back button
        state.buttons[15] = bit(b4, 4)   // C

        // ZL and ZR are plain buttons; as trigger axes they read all or nothing.
        state.axes[4] = state.buttons[6] ?? 0
        state.axes[5] = state.buttons[7] ?? 0

        // D-pad to the hat, up positive (the engine's convention).
        let down = bit(b3, 0), right = bit(b3, 1), left = bit(b3, 2), up = bit(b3, 3)
        let hatX: Float = (left > 0.5 && right > 0.5) ? 0 : (right - left)
        let hatY: Float = (up > 0.5 && down > 0.5) ? 0 : (up - down)
        state.hats[0] = (x: hatX, y: hatY)

        // Sticks. Up is negative in the app, so Y is flipped.
        let cal = Switch2Calibration.current(product: 0x2069)
        let leftStick = switch2Stick(bytes[6], bytes[7], bytes[8], calibration: cal?.left)
        let rightStick = switch2Stick(bytes[9], bytes[10], bytes[11], calibration: cal?.right)
        state.axes[0] = leftStick.x
        state.axes[1] = -leftStick.y
        state.axes[2] = rightStick.x
        state.axes[3] = -rightStick.y
    }

    /// The GameCube controller for Switch 2's input report: 0x05, 64 bytes.
    static func isSwitch2GameCubeInputReport(_ report: Data) -> Bool {
        report.count >= 63 && report.first == 0x05
    }

    /// GameCube controller for Switch 2, USB, report 0x05, with the offsets
    /// SDL's Switch 2 driver reads (SDL_hidapi_switch2.c HandleGameCubeState,
    /// zlib license), counted from the report ID byte:
    ///   [5] B, X, Y, A (bits 0 to 3: SDL_hidapi_switch2.c HandleGameCubeState
    ///   WEST, NORTH, SOUTH, EAST with SDL's GameCube face mapping a:b1,
    ///   b:b3, x:b0, y:b2), R click (bit 6), Z (bit 7). UNVERIFIED on a pad:
    ///   the 0x09 format of the same pad is letter ordered B, A, Y, X.
    ///   [6] Start (bit 1), Home (bit 4), Capture (bit 5), C (bit 6)
    ///   [7] D-pad down, up, right, left (bits 0 to 3), L click (bit 6), ZL (bit 7)
    ///   [11...13] control stick, [14...16] C-stick: 12-bit X and Y as on the Pro
    ///   [61] analog L, [62] analog R, rest about 30 to 40, full near 232
    /// Indices are the GameCube ones both GameCube decoders share, so a
    /// preset moves between this pad and the adapter: A 0, B 1, X 2, Y 3,
    /// L click 4 and 6, Z 5, R click 7, Start 9, Home 10, Capture 14, C 15,
    /// ZL 16, the C-stick as the right stick, L and R on axes 4 and 5.
    /// Needs a hardware check: no pad was on hand.
    static func decodeSwitch2GameCube(report: Data, into state: inout ControllerState) {
        guard isSwitch2GameCubeInputReport(report) else { return }
        let bytes = Array(report)
        let d5 = UInt16(bytes[5]), d6 = UInt16(bytes[6]), d7 = UInt16(bytes[7])
        state.buttons[0] = bit(d5, 3)    // A
        state.buttons[1] = bit(d5, 0)    // B
        state.buttons[2] = bit(d5, 1)    // X
        state.buttons[3] = bit(d5, 2)    // Y
        state.buttons[5] = bit(d5, 7)    // Z
        state.buttons[7] = bit(d5, 6)    // R click
        state.buttons[9] = bit(d6, 1)    // Start
        state.buttons[10] = bit(d6, 4)   // Home
        state.buttons[14] = bit(d6, 5)   // Capture
        state.buttons[15] = bit(d6, 6)   // C
        state.buttons[4] = bit(d7, 6)    // L click
        state.buttons[6] = bit(d7, 6)    // L click
        state.buttons[16] = bit(d7, 7)   // ZL

        // Analog L and R. The rest point comes from the pad's flash (SDL
        // MapTriggerAxis, 232 full); without it anything up to 40 counts as
        // at rest. The click at the end of the pull reads as fully pressed.
        let cal = Switch2Calibration.current(product: 0x2073)
        func trigger(_ raw: UInt8, zero: Int, click: Float) -> Float {
            let v = max(0, min(1, (Float(raw) - Float(zero)) / Float(232 - zero)))
            return click > 0.5 ? 1 : v
        }
        state.axes[4] = trigger(bytes[61], zero: cal?.triggerZeroL ?? Switch2Calibration.fallbackTriggerZero, click: state.buttons[4] ?? 0)
        state.axes[5] = trigger(bytes[62], zero: cal?.triggerZeroR ?? Switch2Calibration.fallbackTriggerZero, click: state.buttons[7] ?? 0)

        let down = bit(d7, 0), up = bit(d7, 1), right = bit(d7, 2), left = bit(d7, 3)
        state.hats[0] = (x: (left > 0.5 && right > 0.5) ? 0 : right - left,
                         y: (up > 0.5 && down > 0.5) ? 0 : up - down)

        // Sticks. Up is negative in the app, so Y is flipped.
        let control = switch2Stick(bytes[11], bytes[12], bytes[13], calibration: cal?.left)
        let cStick = switch2Stick(bytes[14], bytes[15], bytes[16], calibration: cal?.right)
        state.axes[0] = control.x
        state.axes[1] = -control.y
        state.axes[2] = cStick.x
        state.axes[3] = -cStick.y

        // The same IMU block as the Pro (SDL sends sensors for every Switch 2
        // controller, the GameCube pad included).
        decodeSwitch2Motion(bytes, into: &state)
    }

    /// Joy-Con 2 (L) or (R) on its own, report 0x05, held sideways with the
    /// rail (SL, SR) on top as Nintendo shows it: the stick and the IMU are
    /// turned with the pad, and the buttons take the numbering of the first
    /// Joy-Con drawings (Layout+JoyConLeft, Layout+JoyConRight), so those
    /// drawings light up. Bits from SDL_hidapi_switch2.c's
    /// HandleMiniControllerStateL and R and the shared button table:
    ///   left:  [6] bit0 Minus, bit3 stick press, bit5 Capture; [7] bit0 Down,
    ///          bit1 Up, bit2 Right, bit3 Left, bit4 SR, bit5 SL, bit6 L,
    ///          bit7 ZL; [8] bit1 GL; stick at 11 to 13
    ///   right: [5] bit0 Y, bit1 X, bit2 B, bit3 A, bit4 SR, bit5 SL, bit6 R,
    ///          bit7 ZR; [6] bit1 Plus, bit2 stick press, bit4 Home, bit6 C;
    ///          [8] bit0 GR; stick at 14 to 16
    /// Indices: left arrows Left 0, Up 1, Down 2, Right 3; right A 0, B 1,
    /// X 2, Y 3; SL 4, SR 5; L or R 6; ZL or ZR 7; Minus 8; Plus 9; Home 10;
    /// left stick press 11; right stick press 12; Capture 14; C 15; GL 16;
    /// GR 17. Not checked on a Joy-Con 2: none was on hand.
    static func decodeSwitch2JoyCon(report: Data, left: Bool, into state: inout ControllerState) {
        guard isSwitch2GameCubeInputReport(report) else { return }
        let bytes = Array(report)
        let d5 = UInt16(bytes[5]), d6 = UInt16(bytes[6]), d7 = UInt16(bytes[7]), d8 = UInt16(bytes[8])
        let cal = Switch2Calibration.current(product: left ? 0x2066 : 0x2067)
        if left {
            state.buttons[0] = bit(d7, 3)    // Left arrow
            state.buttons[1] = bit(d7, 1)    // Up arrow
            state.buttons[2] = bit(d7, 0)    // Down arrow
            state.buttons[3] = bit(d7, 2)    // Right arrow
            state.buttons[5] = bit(d7, 4)    // SR
            state.buttons[4] = bit(d7, 5)    // SL
            state.buttons[6] = bit(d7, 6)    // L
            state.buttons[7] = bit(d7, 7)    // ZL
            state.buttons[8] = bit(d6, 0)    // Minus
            state.buttons[11] = bit(d6, 3)   // stick press
            state.buttons[14] = bit(d6, 5)   // Capture
            state.buttons[16] = bit(d8, 1)   // GL
            // Rail up means the pad is turned a quarter turn
            // counterclockwise: upright right is now up, upright up is left.
            let raw = switch2Stick(bytes[11], bytes[12], bytes[13], calibration: cal?.left)
            state.axes[0] = -raw.y
            state.axes[1] = -raw.x
        } else {
            state.buttons[3] = bit(d5, 0)    // Y
            state.buttons[2] = bit(d5, 1)    // X
            state.buttons[1] = bit(d5, 2)    // B
            state.buttons[0] = bit(d5, 3)    // A
            state.buttons[5] = bit(d5, 4)    // SR
            state.buttons[4] = bit(d5, 5)    // SL
            state.buttons[6] = bit(d5, 6)    // R
            state.buttons[7] = bit(d5, 7)    // ZR
            state.buttons[9] = bit(d6, 1)    // Plus
            state.buttons[12] = bit(d6, 2)   // stick press
            state.buttons[10] = bit(d6, 4)   // Home
            state.buttons[15] = bit(d6, 6)   // C
            state.buttons[17] = bit(d8, 0)   // GR
            // A quarter turn clockwise: upright up is now right, upright
            // right is down.
            let raw = switch2Stick(bytes[14], bytes[15], bytes[16], calibration: cal?.right)
            state.axes[0] = raw.y
            state.axes[1] = raw.x
        }
        state.axes[4] = state.buttons[7] ?? 0

        // The IMU block, turned with the pad (the same quarter turns as the
        // stick, in the frame X right, Y away, Z up).
        var upright = ControllerState()
        decodeSwitch2Motion(bytes, into: &upright)
        guard !upright.motion.isEmpty else { return }
        for (x, y) in [(MotionChannel.accelX, MotionChannel.accelY), (.gyroX, .gyroY)] {
            let ux = upright.motion[x] ?? 0, uy = upright.motion[y] ?? 0
            if left { upright.motion[x] = -uy; upright.motion[y] = ux } else { upright.motion[x] = uy; upright.motion[y] = -ux }
        }
        state.motion = upright.motion
    }

    /// One stick: 12-bit X from the first byte and the low half of the
    /// second, 12-bit Y from the high half of the second and the third,
    /// scaled so full tilt is about 1.
    static func switch2Stick(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, calibration: Switch2Calibration.Stick? = nil) -> (x: Float, y: Float) {
        let rawX = Int(b0) | (Int(b1 & 0x0F) << 8)
        let rawY = Int(b1 >> 4) | (Int(b2) << 4)
        if let calibration { return (calibration.mapX(rawX), calibration.mapY(rawY)) }
        // Fallback with no flash read. Not clamped here: the pad's own rest
        // is taken off next (RawHIDGamepad.removeStickRest, which clamps),
        // so a stick resting off center still reaches full both ways.
        let x = Float(rawX - Switch2Calibration.fallbackCenter) / Float(Switch2Calibration.fallbackSpan)
        let y = Float(rawY - Switch2Calibration.fallbackCenter) / Float(Switch2Calibration.fallbackSpan)
        return (max(-1.2, min(1.2, x)), max(-1.2, min(1.2, y)))
    }
}
