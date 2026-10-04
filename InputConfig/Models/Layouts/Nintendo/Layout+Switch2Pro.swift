import Foundation
import CoreGraphics

extension ControllerLayout {
    /// Switch 2 Pro Controller (product 0x2069), read raw over a USB-C cable
    /// after Switch2USBEnabler starts it (HIDReportDecoder.decodeSwitch2Pro,
    /// input report 0x09). macOS GameController does not list it, so the raw
    /// path is the only one and no pathInputs are needed.
    ///
    /// Nintendo face buttons use the POSITIONAL scheme, as every Nintendo
    /// layout does: btn 0 is the bottom button (B), 1 the right (A), 2 the
    /// left (Y), 3 the top (X). The raw decoder already numbers them this way,
    /// and the GameController path for the other Nintendo pads is moving to it.
    ///
    /// Body: 148 mm wide by 105 mm tall (Nintendo's spec), laid out like the
    /// first Switch Pro Controller. Left stick high on the left with the
    /// +Control Pad below and inboard of it; A, B, X, Y high on the right with
    /// the right stick below and inboard. Minus and Plus at the top of the
    /// center column, Capture and HOME below them, the NFC touchpoint between,
    /// and the new C button centered below. GL and GR sit on the back of the
    /// grips under the middle fingers.
    static let switch2Pro = ControllerLayout(
        id: .switch2Pro,
        displayName: "Switch 2 Pro Controller",
        maker: .nintendo,
        family: .nintendo,
        aspect: 148.0 / 105.0,
        topStrip: 0.22,
        backStrip: 0.42,
        silhouette: Silhouette(front: switch2ProFront, top: switch2ProTop, back: switch2ProFront),
        controls: switch2ProControls,
        // The raw profile names it; the vendor and product IDs back that up.
        // GameControllerService gives this pad the .switchPro brand, so this
        // must outrank any Switch Pro rule that matches on brand alone.
        match: [
            [.rawProfileLayout("switch2Pro")],
            [.vidPid(vendor: 0x057E, products: [0x2069])],
            // If a macOS release lists it in GameController (the raw read
            // then steps aside for it).
            [.brand(.switchPro), .gcHasElement("Button A"), .gcVendorNameContains("Switch 2")],
            [.brand(.switchPro), .gcHasElement("Button A"), .gcProductCategoryContains("Switch 2")],
        ],
        matchPriority: 30,
        readability: .partial("USB only, experimental: no Bluetooth, motion, NFC or rumble"),
        approximate: true,
        sources: [
            "nintendo.com Switch 2 Pro Controller main specifications (105 x 148 x 60.2 mm)",
            "en-americas-support.nintendo.com Nintendo Switch 2 Pro Controller Diagram (answer 68527)",
            "github.com/caqlayan/procon2-mac README protocol notes (USB report 0x09 button bits)",
            "SDL src/joystick/hidapi/SDL_hidapi_switch2.c",
        ]
    )

    /// The front outline, reused for the back (an x-ray as held is the same
    /// outline, since the body is symmetric). Long, wide grips and a high
    /// arch between them, just under the D-pad and right stick.
    private static let switch2ProFront: [PathOp] =
        Silhouette.gamepad(gripLength: 0.38, waist: 0.70, shoulder: 0.5, gripWidth: 0.22, flare: 0.02, topDip: 0.01).front

    /// The top edge seen from above: thick at the sides where ZL and ZR bulge
    /// back over the grips, thin in the middle where the USB-C port is.
    private static let switch2ProTop: [PathOp] = Silhouette.symmetric([
        .move(0.5, 0.36),
        .curve(0.34, 0.12, c1x: 0.42, c1y: 0.36, c2x: 0.38, c2y: 0.14),
        .curve(0.06, 0.12, c1x: 0.26, c1y: 0.04, c2x: 0.12, c2y: 0.04),
        .curve(0.02, 0.6, c1x: 0.02, c1y: 0.22, c2x: 0.015, c2y: 0.42),
        .curve(0.12, 0.96, c1x: 0.025, c1y: 0.85, c2x: 0.06, c2y: 0.96),
        .line(0.5, 0.96),
    ])

    private static let switch2ProControls: [PlacedControl] = [
        // Top: ZL and ZR at the rear corners, L and R in front of them. ZL and
        // ZR are plain buttons: btn 6 and 7, with axis 4 and 5 as 0-or-1 copies.
        PlacedControl(id: "zl", kind: .trigger(.digital), face: .top, center: CGPoint(x: 0.2, y: 0.1609), size: 0.15, height: 0.13,
                      shape: .roundedRect(corner: 0.35), inputs: .trigger(axis: 4, digital: 6),
                      note: "Digital: reads as button 6, and as axis 4 at 0 or 1", callout: .above),
        PlacedControl(id: "zr", kind: .trigger(.digital), face: .top, center: CGPoint(x: 0.8, y: 0.1609), size: 0.15, height: 0.13,
                      shape: .roundedRect(corner: 0.35), inputs: .trigger(axis: 5, digital: 7),
                      note: "Digital: reads as button 7, and as axis 5 at 0 or 1", callout: .above),
        PlacedControl(id: "l", kind: .shoulder, face: .top, center: CGPoint(x: 0.22, y: 0.76), size: 0.18, height: 0.04,
                      shape: .capsule(angleDegrees: 0), inputs: .button(4), callout: .below),
        PlacedControl(id: "r", kind: .shoulder, face: .top, center: CGPoint(x: 0.78, y: 0.76), size: 0.18, height: 0.04,
                      shape: .capsule(angleDegrees: 0), inputs: .button(5), callout: .below),
        // Top center: SYNC, the USB-C port, the recharge LED, player LEDs.
        PlacedControl(id: "sync", kind: .other, face: .top, center: CGPoint(x: 0.4, y: 0.56), size: 0.025,
                      readable: .notReported("SYNC is handled by the controller itself and has no bit in report 0x09")),
        PlacedControl(id: "usbc", kind: .port, face: .top, center: CGPoint(x: 0.5, y: 0.56), size: 0.06, height: 0.022,
                      shape: .capsule(angleDegrees: 0), note: "The cable InputConfig reads this controller over"),
        PlacedControl(id: "recharge-led", kind: .light, face: .top, center: CGPoint(x: 0.585, y: 0.56), size: 0.014,
                      readable: .notReported("A charging light, not an input")),
        PlacedControl(id: "player-leds", kind: .light, face: .top, center: CGPoint(x: 0.5, y: 0.86), size: 0.07, height: 0.012,
                      shape: .capsule(angleDegrees: 0),
                      readable: .notReported("Output only: InputConfig lights player 1 when it starts the controller")),

        // Front, left: the stick high, the +Control Pad below and inboard.
        PlacedControl(id: "lstick", kind: .stick, center: CGPoint(x: 0.25, y: 0.3), size: 0.14,
                      inputs: .stick(x: 0, y: 1, press: 11), callout: .below),
        PlacedControl(id: "dpad", kind: .dpad, center: CGPoint(x: 0.36, y: 0.53), size: 0.145, shape: .crossPad,
                      inputs: .hat(0), callout: .below),

        // Front, right: the face buttons high, the right stick below and inboard.
        PlacedControl(id: "x", kind: .faceButton, center: CGPoint(x: 0.76, y: 0.2), size: 0.062,
                      inputs: .button(3), callout: .above),
        PlacedControl(id: "y", kind: .faceButton, center: CGPoint(x: 0.69, y: 0.3), size: 0.062,
                      inputs: .button(2), callout: .left),
        PlacedControl(id: "a", kind: .faceButton, center: CGPoint(x: 0.83, y: 0.3), size: 0.062,
                      inputs: .button(1), callout: .right),
        PlacedControl(id: "b", kind: .faceButton, center: CGPoint(x: 0.76, y: 0.4), size: 0.062,
                      inputs: .button(0), callout: .below),
        PlacedControl(id: "rstick", kind: .stick, center: CGPoint(x: 0.64, y: 0.53), size: 0.14,
                      inputs: .stick(x: 2, y: 3, press: 12), callout: .below),

        // Front, center column.
        PlacedControl(id: "minus", kind: .menuButton, center: CGPoint(x: 0.39, y: 0.17), size: 0.035,
                      symbol: "minus", inputs: .button(8), callout: .above),
        PlacedControl(id: "plus", kind: .menuButton, center: CGPoint(x: 0.61, y: 0.17), size: 0.035,
                      symbol: "plus", inputs: .button(9), callout: .above),
        PlacedControl(id: "capture", kind: .menuButton, center: CGPoint(x: 0.43, y: 0.29), size: 0.04,
                      shape: .roundedRect(corner: 0.25), symbol: "camera", inputs: .button(14), callout: .above),
        PlacedControl(id: "nfc", kind: .other, center: CGPoint(x: 0.5, y: 0.22), size: 0.07, height: 0.035,
                      shape: .roundedRect(corner: 0.3), printed: "NFC",
                      readable: .notReported("The NFC touchpoint reads amiibo for the console; InputConfig does not read it")),
        PlacedControl(id: "home", kind: .homeButton, center: CGPoint(x: 0.57, y: 0.29), size: 0.045,
                      symbol: "house", inputs: .button(10), callout: .above),
        PlacedControl(id: "c", kind: .menuButton, center: CGPoint(x: 0.5, y: 0.38), size: 0.035,
                      printed: "C", inputs: .button(15), note: "GameChat on the console; any function here", callout: .below),
        // The 6-axis sensor sits inside the body; the enabler switches it on,
        // but the decoder never reads it.
        PlacedControl(id: "gyro", kind: .other, center: CGPoint(x: 0.5, y: 0.6), size: 0.075, height: 0.03,
                      shape: .capsule(angleDegrees: 0), printed: "Gyro",
                      readable: .notReported("Motion sensors are enabled but not decoded yet, so they cannot be bound")),

        // Back, as held: GL under the left middle finger, GR under the right,
        // the audio jack on the bottom edge between the grips.
        PlacedControl(id: "gl", kind: .paddle, face: .back, center: CGPoint(x: 0.22, y: 0.48), size: 0.05, height: 0.075,
                      shape: .capsule(angleDegrees: 0), printed: "GL", inputs: .button(16),
                      note: "Bit position from community research, not yet confirmed on hardware", callout: .below),
        PlacedControl(id: "gr", kind: .paddle, face: .back, center: CGPoint(x: 0.78, y: 0.48), size: 0.05, height: 0.075,
                      shape: .capsule(angleDegrees: 0), printed: "GR", inputs: .button(17),
                      note: "Bit position from community research, not yet confirmed on hardware", callout: .below),
        PlacedControl(id: "audio", kind: .port, face: .back, center: CGPoint(x: 0.5, y: 0.64), size: 0.035, height: 0.018,
                      shape: .capsule(angleDegrees: 0), note: "3.5 mm audio jack on the bottom edge, not used by InputConfig"),
    ]
}
