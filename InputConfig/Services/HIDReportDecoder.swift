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
        case .switch2Pro:
            decodeSwitch2Pro(report: report, into: &state)
        case .switch2GameCube:
            decodeSwitch2GameCube(report: report, into: &state)
        case .steamController2026:
            decodeSteamController2026(report: report, into: &state)
        case .streamDeck(let format):
            decodeStreamDeck(report: report, format: format, into: &state)
        case .generic(let layout):
            decodeGeneric(report: report, layout: layout, into: &state)
        }
        return state
    }

    // MARK: - XInput layout

    /// Standard 20-byte Xbox 360 / XInput-over-HID report. The first
    /// byte is usually a report ID (0x00) or "message type" header;
    /// the next byte is sometimes the packet length (0x14). We support
    /// both forms by sniffing the layout at run time.
    ///
    /// Canonical Xbox 360 wired controller layout (post-header):
    ///   byte 0-1: 16-bit button bitfield (little endian)
    ///   byte 2:   left trigger (0-255)
    ///   byte 3:   right trigger (0-255)
    ///   byte 4-5: LX signed 16-bit LE
    ///   byte 6-7: LY signed 16-bit LE (positive = up)
    ///   byte 8-9: RX
    ///   byte 10-11: RY
    static func decodeXInput(report: Data, into state: inout ControllerState) {
        // Determine where the payload starts. Xbox 360 wired controllers
        // prefix reports with a 2-byte header (message type 0x00 +
        // length 0x14). 8BitDo "XInput mode" controllers usually skip
        // the header and start directly with the button bitfield.
        // Detect by sniffing for the header bytes rather than guessing
        // by length - some firmware emits 15-19 byte compact reports
        // that the old length-only check routed wrong.
        let allBytes = Array(report)
        guard allBytes.count >= 14 else { return }
        let hasHeader = allBytes.count >= 20
            && allBytes[0] == 0x00
            && allBytes[1] == 0x14
        let bytes = hasHeader ? Array(allBytes.dropFirst(2)) : allBytes
        guard bytes.count >= 12 else { return }

        // Buttons (16-bit bitfield, little endian)
        let buttons = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)

        // D-pad bits go into the hat (matches MFi convention - the
        // visualizer's DPadWidget reads state.hats[0] and bindings to
        // .hat events fire from here too).
        //
        // Simultaneous opposite presses (e.g. flaky d-pad reporting
        // Up+Down) used to produce y=0 which is indistinguishable from
        // "neutral". Detect that and report a small sentinel deflection
        // so the user can SEE the contradiction in the visualizer.
        let dpadUp = bit(buttons, 0)
        let dpadDown = bit(buttons, 1)
        let dpadLeft = bit(buttons, 2)
        let dpadRight = bit(buttons, 3)
        let hatX: Float = (dpadLeft > 0.5 && dpadRight > 0.5) ? 0 : (dpadRight - dpadLeft)
        // Up-positive, matching the GC-framework / Steam / engine convention
        // (this was inverted, so d-pad Up on XInput pads read as Down).
        let hatY: Float = (dpadUp > 0.5 && dpadDown > 0.5) ? 0 : (dpadUp - dpadDown)
        state.hats[0] = (x: hatX, y: hatY)

        // XInput button bit positions (canonical Xbox 360 mapping)
        state.buttons[9]  = bit(buttons, 4)   // Start
        state.buttons[8]  = bit(buttons, 5)   // Back
        state.buttons[11] = bit(buttons, 6)   // L3
        state.buttons[12] = bit(buttons, 7)   // R3
        state.buttons[4]  = bit(buttons, 8)   // LB
        state.buttons[5]  = bit(buttons, 9)   // RB
        state.buttons[10] = bit(buttons, 10)  // Guide / Home
        state.buttons[0]  = bit(buttons, 12)  // A
        state.buttons[1]  = bit(buttons, 13)  // B
        state.buttons[2]  = bit(buttons, 14)  // X
        state.buttons[3]  = bit(buttons, 15)  // Y

        // Triggers (analog 0-255). Also report as digital "button
        // pressed" when > 30/255 so digital trigger bindings still
        // fire on controllers without dedicated trigger buttons.
        let lt = Float(bytes[2]) / 255.0
        let rt = Float(bytes[3]) / 255.0
        state.axes[4] = lt
        state.axes[5] = rt
        state.buttons[6] = lt > 0.12 ? 1.0 : 0.0
        state.buttons[7] = rt > 0.12 ? 1.0 : 0.0

        // Sticks. XInput's Y is positive = up. InputConfig uses
        // positive = down (matches GameController framework), so flip Y.
        state.axes[0] = signedInt16(bytes[4], bytes[5])
        state.axes[1] = -signedInt16(bytes[6], bytes[7])
        state.axes[2] = signedInt16(bytes[8], bytes[9])
        state.axes[3] = -signedInt16(bytes[10], bytes[11])
    }

    // MARK: - DualShock 3 layout

    /// Sony DualShock 3 HID input report (USB). 49 bytes after the
    /// report ID. Buttons live in bytes 2-3, hat in byte 2 lower nibble,
    /// pressure-sensitive buttons in bytes 14-25, sticks in bytes 6-9.
    static func decodeDualShock3(report: Data, into state: inout ControllerState) {
        let bytes = Array(report)
        guard bytes.count >= 26 else { return }

        // The canonical DS3 offsets (buttons in bytes 2-3, PS at 4,
        // sticks 6-9, trigger pressures 18-19) already count the leading
        // 0x01 report ID as byte 0, and IOKit includes that ID byte in
        // the delivered buffer. base = 0 when the ID is present; if a
        // transport strips it, every offset shifts down one. The old
        // base = 1 double-counted the ID and read every control from
        // the wrong byte.
        let base = bytes[0] == 0x01 ? 0 : -1
        guard bytes.count >= base + 26 else { return }
        // A report whose byte 1 is 0xFF is not a state report (SDL drops
        // these too); decoded, it could read as stray presses.
        if base == 0 && bytes[1] == 0xFF { return }

        let b2 = bytes[base + 2]
        let b3 = bytes[base + 3]

        // Byte 2 bits: Select(0), L3(1), R3(2), Start(3), D-Pad U(4), D-Pad R(5), D-Pad D(6), D-Pad L(7)
        state.buttons[8]  = bit(UInt16(b2), 0)  // Select
        state.buttons[11] = bit(UInt16(b2), 1)  // L3
        state.buttons[12] = bit(UInt16(b2), 2)  // R3
        state.buttons[9]  = bit(UInt16(b2), 3)  // Start
        // D-pad to hat[0] (matches MFi convention)
        let ds3Up = bit(UInt16(b2), 4)
        let ds3Right = bit(UInt16(b2), 5)
        let ds3Down = bit(UInt16(b2), 6)
        let ds3Left = bit(UInt16(b2), 7)
        state.hats[0] = (
            x: ds3Right - ds3Left,
            // Up-positive (was inverted; see XInput note above).
            y: ds3Up - ds3Down
        )

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
        let b4 = bytes[base + 4]
        state.buttons[10] = bit(UInt16(b4), 0)

        // Sticks: bytes 6-9, unsigned 8-bit centered at 0x80
        state.axes[0] = unsignedToSigned(bytes[base + 6])
        state.axes[1] = unsignedToSigned(bytes[base + 7])
        state.axes[2] = unsignedToSigned(bytes[base + 8])
        state.axes[3] = unsignedToSigned(bytes[base + 9])

        // Analog trigger pressures (DS3 pressure-sensitive buttons)
        let l2Analog = Float(bytes[base + 18]) / 255.0
        let r2Analog = Float(bytes[base + 19]) / 255.0
        state.axes[4] = l2Analog
        state.axes[5] = r2Analog
    }

    // MARK: - Switch 2 Pro Controller layout

    /// The input report a started Switch 2 Pro Controller streams, about 60
    /// a second. Anything else it sends (command replies, other formats) is
    /// not a controller state and must not be decoded as one, or every
    /// button would read as released for a frame.
    static func isSwitch2ProInputReport(_ report: Data) -> Bool {
        report.count >= 12 && report.first == 0x09
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
    static func decodeSwitch2Pro(report: Data, into state: inout ControllerState) {
        guard isSwitch2ProInputReport(report) else { return }
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
        let leftStick = switch2Stick(bytes[6], bytes[7], bytes[8])
        let rightStick = switch2Stick(bytes[9], bytes[10], bytes[11])
        state.axes[0] = leftStick.x
        state.axes[1] = -leftStick.y
        state.axes[2] = rightStick.x
        state.axes[3] = -rightStick.y
    }

    /// Report IDs of the 2026 Steam Controller that carry its state. 0x43 is
    /// battery, 0x46 and 0x79 the Puck's wireless status.
    static let steamController2026StateIDs: Set<UInt8> = [0x42, 0x45, 0x47]

    /// The 2026 Steam Controller's state report, after SDL's Triton driver:
    /// report ID, sequence number, a 32-bit button field, then signed 16-bit
    /// little-endian triggers, sticks, both trackpads with pressure, and the
    /// IMU. Report 0x47 adds a trackpad timestamp, which moves the trackpads
    /// two bytes on; the IMU lands at the same offsets in all three.
    ///
    /// Indices: the standard slots 0 to 12 (View is Back, Menu is Start), 13
    /// Quick Access, 14 to 17 the back buttons L4 R4 L5 R5, 18 and 19 the
    /// trackpad clicks, 20 and 21 trackpad touch, 22 and 23 stick touch, 24
    /// and 25 grip touch. Axes 0 to 5 as usual, 6 to 9 the left and right
    /// trackpads (Y down positive, at rest when not touched), 10 and 11
    /// trackpad pressure. Motion rates in radians per second and g.
    static func decodeSteamController2026(report: Data, into state: inout ControllerState) {
        let bytes = Array(report)
        guard bytes.count >= 46, steamController2026StateIDs.contains(bytes[0]) else { return }
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func s16(_ i: Int) -> Float { Float(Int16(bitPattern: UInt16(u16(i)))) }
        let buttons = UInt32(bytes[2]) | UInt32(bytes[3]) << 8 | UInt32(bytes[4]) << 16 | UInt32(bytes[5]) << 24
        func on(_ mask: UInt32) -> Float { buttons & mask != 0 ? 1 : 0 }

        state.buttons[0] = on(0x0000_0001)      // A
        state.buttons[1] = on(0x0000_0002)      // B
        state.buttons[2] = on(0x0000_0004)      // X
        state.buttons[3] = on(0x0000_0008)      // Y
        state.buttons[4] = on(0x0008_0000)      // L
        state.buttons[5] = on(0x0000_0200)      // R
        state.buttons[8] = on(0x0000_4000)      // View, on the left (SDL: Back)
        state.buttons[9] = on(0x0000_0040)      // Menu, on the right (SDL: Start)
        state.buttons[10] = on(0x0001_0000)     // Steam
        state.buttons[11] = on(0x0000_8000)     // L3
        state.buttons[12] = on(0x0000_0020)     // R3
        state.buttons[13] = on(0x0000_0010)     // Quick Access
        state.buttons[14] = on(0x0002_0000)     // L4
        state.buttons[15] = on(0x0000_0080)     // R4
        state.buttons[16] = on(0x0004_0000)     // L5
        state.buttons[17] = on(0x0000_0100)     // R5
        state.buttons[18] = on(0x0400_0000)     // left trackpad click
        state.buttons[19] = on(0x0040_0000)     // right trackpad click
        let leftTouch = on(0x0200_0000), rightTouch = on(0x0020_0000)
        state.buttons[20] = leftTouch
        state.buttons[21] = rightTouch
        state.buttons[22] = on(0x0100_0000)     // left stick touch
        state.buttons[23] = on(0x0010_0000)     // right stick touch
        state.buttons[24] = on(0x2000_0000)     // left grip touch
        state.buttons[25] = on(0x1000_0000)     // right grip touch

        // Triggers run 0 to 32767; the click at the end of the pull counts
        // as fully pressed.
        let lt = max(0, min(1, s16(6) / 32767)), rt = max(0, min(1, s16(8) / 32767))
        state.axes[4] = lt
        state.axes[5] = rt
        state.buttons[6] = on(0x0800_0000) > 0 ? 1 : lt
        state.buttons[7] = on(0x0080_0000) > 0 ? 1 : rt

        // Sticks: up is positive on the wire, negative in the app.
        state.axes[0] = max(-1, min(1, s16(10) / 32767))
        state.axes[1] = max(-1, min(1, -s16(12) / 32767))
        state.axes[2] = max(-1, min(1, s16(14) / 32767))
        state.axes[3] = max(-1, min(1, -s16(16) / 32767))

        // D-pad to the hat, up positive (the engine's convention).
        let up = on(0x0000_2000), down = on(0x0000_0400), left = on(0x0000_1000), right = on(0x0000_0800)
        state.hats[0] = (x: (left > 0.5 && right > 0.5) ? 0 : right - left,
                         y: (up > 0.5 && down > 0.5) ? 0 : up - down)

        // Trackpads, two bytes later in report 0x47.
        let pad = bytes[0] == 0x47 ? 20 : 18
        state.axes[6] = leftTouch > 0 ? max(-1, min(1, s16(pad) / 32767)) : 0
        state.axes[7] = leftTouch > 0 ? max(-1, min(1, -s16(pad + 2) / 32767)) : 0
        state.axes[8] = rightTouch > 0 ? max(-1, min(1, s16(pad + 6) / 32767)) : 0
        state.axes[9] = rightTouch > 0 ? max(-1, min(1, -s16(pad + 8) / 32767)) : 0
        state.axes[10] = leftTouch > 0 ? min(1, Float(u16(pad + 4)) / 32768) : 0
        state.axes[11] = rightTouch > 0 ? min(1, Float(u16(pad + 10)) / 32768) : 0

        // IMU: gyro at 2000 degrees per second full scale, accelerometer at
        // 2 g, in the controller's own frame: X right, Y away from the
        // player, Z up out of the face (SDL turns Z into its "up" and Y into
        // "toward the player"). RawHIDGamepad.processMotion turns these into
        // the app's channels and takes gravity and the rest bias out.
        let gyroScale = Float(2000.0 / 32768.0 * Double.pi / 180.0)
        state.motion[.gyroX] = s16(40) * gyroScale
        state.motion[.gyroY] = s16(42) * gyroScale
        state.motion[.gyroZ] = s16(44) * gyroScale
        state.motion[.accelX] = s16(34) / 16384
        state.motion[.accelY] = s16(36) / 16384
        state.motion[.accelZ] = s16(38) / 16384
    }

    /// The GameCube controller for Switch 2's input report: 0x05, 64 bytes.
    static func isSwitch2GameCubeInputReport(_ report: Data) -> Bool {
        report.count >= 63 && report.first == 0x05
    }

    /// GameCube controller for Switch 2, USB, report 0x05, with the offsets
    /// SDL's Switch 2 driver reads (SDL_hidapi_switch2.c HandleGameCubeState,
    /// zlib license), counted from the report ID byte:
    ///   [5] Y, X, B, A (bits 0 to 3), R click (bit 6), Z (bit 7)
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
        state.buttons[1] = bit(d5, 2)    // B
        state.buttons[2] = bit(d5, 1)    // X
        state.buttons[3] = bit(d5, 0)    // Y
        state.buttons[5] = bit(d5, 7)    // Z
        state.buttons[7] = bit(d5, 6)    // R click
        state.buttons[9] = bit(d6, 1)    // Start
        state.buttons[10] = bit(d6, 4)   // Home
        state.buttons[14] = bit(d6, 5)   // Capture
        state.buttons[15] = bit(d6, 6)   // C
        state.buttons[4] = bit(d7, 6)    // L click
        state.buttons[6] = bit(d7, 6)    // L click
        state.buttons[16] = bit(d7, 7)   // ZL

        // Analog L and R. SDL takes each one's rest point from the pad's
        // flash; without it, anything up to 40 counts as at rest. The click
        // at the end of the pull reads as fully pressed.
        func trigger(_ raw: UInt8, click: Float) -> Float {
            let v = max(0, min(1, (Float(raw) - 40) / (232 - 40)))
            return click > 0.5 ? 1 : v
        }
        state.axes[4] = trigger(bytes[61], click: state.buttons[4] ?? 0)
        state.axes[5] = trigger(bytes[62], click: state.buttons[7] ?? 0)

        let down = bit(d7, 0), up = bit(d7, 1), right = bit(d7, 2), left = bit(d7, 3)
        state.hats[0] = (x: (left > 0.5 && right > 0.5) ? 0 : right - left,
                         y: (up > 0.5 && down > 0.5) ? 0 : up - down)

        // Sticks. Up is negative in the app, so Y is flipped.
        let control = switch2Stick(bytes[11], bytes[12], bytes[13])
        let cStick = switch2Stick(bytes[14], bytes[15], bytes[16])
        state.axes[0] = control.x
        state.axes[1] = -control.y
        state.axes[2] = cStick.x
        state.axes[3] = -cStick.y
    }

    /// Elgato Stream Deck key states (see `StreamDeckFormat`). A report
    /// that is not a key report (a Plus sends its dials and touch strip on
    /// the same ID with another type byte) leaves the state alone.
    static func decodeStreamDeck(report: Data, format: ControllerProfile.StreamDeckFormat,
                                 into state: inout ControllerState) {
        let bytes = Array(report)
        guard bytes.first == 0x01, bytes.count >= format.keyOffset + format.keys else { return }
        if format.keyOffset >= 4, bytes[1] != 0x00 { return }
        let cols = format.mirrorColumns
        for key in 0..<format.keys {
            let source = cols > 0 ? (key - key % cols) + (cols - 1 - key % cols) : key
            state.buttons[ControllerProfile.StreamDeckFormat.firstSlot + key] =
                bytes[format.keyOffset + source] != 0 ? 1 : 0
        }
    }

    /// One stick: 12-bit X from the first byte and the low half of the
    /// second, 12-bit Y from the high half of the second and the third,
    /// scaled so full tilt is about 1.
    private static func switch2Stick(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8) -> (x: Float, y: Float) {
        let rawX = Int(b0) | (Int(b1 & 0x0F) << 8)
        let rawY = Int(b1 >> 4) | (Int(b2) << 4)
        let x = Float(rawX - 2048) / 1650
        let y = Float(rawY - 2048) / 1650
        return (max(-1, min(1, x)), max(-1, min(1, y)))
    }

    // MARK: - Generic layout

    static func decodeGeneric(report: Data,
                              layout: ControllerProfile.GenericLayout,
                              into state: inout ControllerState) {
        decodeGeneric(report: report,
                      plan: HIDExtendedLayoutRegistry.extended(for: layout),
                      into: &state)
    }

    /// Decodes one input report with the parser's full plan. Only the
    /// controls this report carries are written, so a device that splits
    /// its controls across report IDs (a SpaceMouse sends translation,
    /// rotation, and buttons separately) fills the rest of the state from
    /// its other reports; `RawHIDGamepad.updateState` merges them. A
    /// report ID the plan doesn't know (battery, sensor, vendor) writes
    /// nothing, rather than phantom input.
    static func decodeGeneric(report: Data,
                              plan: HIDExtendedLayout,
                              into state: inout ControllerState) {
        let bytes = Array(report)
        var offset = 0
        let entry: HIDExtendedLayout.Report
        if plan.usesReportIDs {
            guard !bytes.isEmpty, let found = plan.report(forID: Int(bytes[0])) else { return }
            entry = found
            offset = 1
        } else {
            guard let found = plan.reports.first else { return }
            entry = found
        }
        guard bytes.count >= offset + entry.payloadSize else { return }
        let payloadCount = bytes.count - offset

        // Buttons
        for button in entry.buttons {
            guard let raw = readBits(bytes, offset, payloadCount, button.bitOffset, button.bitSize) else { continue }
            state.buttons[button.index] = Int(raw) > button.pressAbove ? 1.0 : 0.0
        }

        // Axes, each scaled by its own declared logical range and read
        // through a bit window, so 10/12/14-bit packed axes, 32-bit axes,
        // and ranges like 0..1023 or -350..350 all reach full scale.
        // Y stays positive = down, the same as the GameController,
        // XInput, DualShock 3, and Switch 2 paths.
        for axis in entry.axes {
            guard axis.logicalMax > axis.logicalMin,
                  let raw = readBits(bytes, offset, payloadCount, axis.bitOffset, axis.bitSize) else { continue }
            var v = Int(raw)
            if axis.isSigned {
                let signBit = 1 << (axis.bitSize - 1)
                if v & signBit != 0 { v -= 1 << axis.bitSize }
            }
            let lo = axis.logicalMin, hi = axis.logicalMax
            var value: Float
            if axis.unipolar {
                value = max(0, min(1, Float(v - lo) / Float(hi - lo)))
                if axis.inverted { value = 1 - value }
            } else {
                // Center on the upper middle value (128 for 0..255, 0 for
                // signed ranges) and scale each side separately, so rest
                // reads exactly 0 and both ends reach exactly -1 and +1.
                let center = lo + (hi - lo + 1) / 2
                let span = Float(v >= center ? max(1, hi - center) : max(1, center - lo))
                value = max(-1, min(1, Float(v - center) / span))
                if axis.inverted { value = -value }
            }
            state.axes[axis.index] = value
            if let b = axis.digitalButton {
                state.buttons[b] = value > 0.12 ? 1.0 : 0.0
            }
        }

        // Hat switches, each into its own hats[i]. Honor the declared
        // logical minimum: pads that use 1..8 with 0 as null would
        // otherwise read rotated 45 degrees with the resting value
        // decoding as a held North. A 4-way hat (0..3) steps 90 degrees
        // per value, so its direction doubles onto the 8-way table.
        for hat in entry.hats {
            // 8-bit hats keep the direction in the low nibble with
            // padding above, so only the low 4 bits are read.
            guard let raw = readBits(bytes, offset, payloadCount, hat.bitOffset, min(hat.bitSize, 4)) else { continue }
            var direction = Int(raw) - hat.logicalMin
            if hat.directions == 4 {
                direction = (0...3).contains(direction) ? direction * 2 : -1
            }
            // Standard 8-direction encoding after normalization
            // (0=N, 1=NE, ..., 7=NW; anything else = center).
            // Up-positive convention (N = +1), matching GC framework,
            // Steam, and the engine's hat matching.
            let i = hat.index
            switch direction {
            case 0: setHat(&state, i, x: 0, y: 1)               // N
            case 1: setHat(&state, i, x: 0.707, y: 0.707)       // NE
            case 2: setHat(&state, i, x: 1, y: 0)               // E
            case 3: setHat(&state, i, x: 0.707, y: -0.707)      // SE
            case 4: setHat(&state, i, x: 0, y: -1)              // S
            case 5: setHat(&state, i, x: -0.707, y: -0.707)     // SW
            case 6: setHat(&state, i, x: -1, y: 0)              // W
            case 7: setHat(&state, i, x: -0.707, y: 0.707)      // NW
            default: setHat(&state, i, x: 0, y: 0)
            }
        }

        // A D-pad that sends each direction as a button, folded into its
        // hat with up positive like the hats above.
        if !entry.dpadButtons.isEmpty {
            var pads: [Int: (x: Float, y: Float)] = [:]
            for pad in entry.dpadButtons {
                let pressed: Bool
                if let half = pad.axisHalf {
                    // Half of an axis: pressed past the middle of that half.
                    guard var v = readBits(bytes, offset, payloadCount, pad.bitOffset, half.bitSize).map({ Int($0) })
                    else { continue }
                    if half.isSigned {
                        let signBit = 1 << (half.bitSize - 1)
                        if v & signBit != 0 { v -= 1 << half.bitSize }
                    }
                    let lo = half.logicalMin, hi = half.logicalMax
                    let center = lo + (hi - lo + 1) / 2
                    let span = Float(v >= center ? max(1, hi - center) : max(1, center - lo))
                    let value = Float(v - center) / span
                    pressed = half.positive ? value > 0.5 : value < -0.5
                } else {
                    guard let raw = readBits(bytes, offset, payloadCount, pad.bitOffset, pad.bitSize) else { continue }
                    pressed = Int(raw) > pad.pressAbove
                }
                var hat = pads[pad.hatIndex] ?? (0, 0)
                if pressed {
                    switch pad.direction {
                    case .up: hat.y += 1
                    case .down: hat.y -= 1
                    case .left: hat.x -= 1
                    case .right: hat.x += 1
                    }
                }
                pads[pad.hatIndex] = hat
            }
            for (i, hat) in pads { setHat(&state, i, x: hat.x, y: hat.y) }
        }
    }

    /// Reads `bitSize` bits (1...32) starting `bitOffset` bits into the
    /// payload, little endian. Nil when the field runs past the report.
    @inline(__always)
    private static func readBits(_ bytes: [UInt8], _ base: Int, _ payloadCount: Int,
                                 _ bitOffset: Int, _ bitSize: Int) -> UInt64? {
        guard bitSize >= 1 && bitSize <= 32, bitOffset >= 0 else { return nil }
        let first = bitOffset / 8
        let last = (bitOffset + bitSize - 1) / 8
        guard last < payloadCount else { return nil }
        var window: UInt64 = 0
        for k in 0...(last - first) {
            window |= UInt64(bytes[base + first + k]) << UInt64(8 * k)
        }
        return (window >> UInt64(bitOffset % 8)) & ((UInt64(1) << UInt64(bitSize)) - 1)
    }

    // MARK: - Helpers

    @inline(__always)
    private static func bit(_ value: UInt16, _ pos: Int) -> Float {
        return ((value >> pos) & 0x01) == 1 ? 1.0 : 0.0
    }

    @inline(__always)
    private static func signedInt16(_ low: UInt8, _ high: UInt8) -> Float {
        let raw = Int16(bitPattern: UInt16(low) | (UInt16(high) << 8))
        // Map -32768...32767 to -1.0...1.0, with a small deadzone clamp.
        return max(-1.0, min(1.0, Float(raw) / 32767.0))
    }

    @inline(__always)
    private static func unsignedToSigned(_ value: UInt8) -> Float {
        // 0...255 with 128 = center → -1.0 ... 1.0.
        // Divide by 127 (not 128) so the maximum positive raw value
        // (255) maps to exactly +1.0; with 128 it would max at
        // +0.992 and the visualizer's "at limit" detection never
        // fires. Negative max (0) maps to -1.008, which we clamp.
        return max(-1.0, min(1.0, (Float(value) - 128.0) / 127.0))
    }

    @inline(__always)
    private static func setHat(_ state: inout ControllerState, _ index: Int, x: Float, y: Float) {
        state.hats[index] = (x: x, y: y)
    }
}
