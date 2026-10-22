import Foundation

/// Steam Controller 2026 report decoding, moved out of HIDReportDecoder.swift.
extension HIDReportDecoder {
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
}
