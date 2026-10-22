import Foundation

/// XInput report decoding, moved out of HIDReportDecoder.swift.
extension HIDReportDecoder {
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
        // A 20 byte report is a state only with the 0x00 0x14 header
        // (xpad.c xpad360_process_packet, SDL HandleStatePacket); any other
        // 20 byte message (LED echo, receiver presence) is not input. The
        // headerless form is accepted at 14 to 19 bytes only.
        if allBytes.count >= 20 {
            guard allBytes[0] == 0x00, allBytes[1] == 0x14 else { return }
        }
        let hasHeader = allBytes.count >= 20
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
}
