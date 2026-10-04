import Foundation
import CoreGraphics

extension ControllerLayout {
    /// Nintendo GameCube Controller for Nintendo Switch 2 (product 0x2073),
    /// read raw over a USB-C cable after Switch2USBEnabler starts it
    /// (HIDReportDecoder.decodeSwitch2GameCube, input report 0x05). macOS
    /// GameController does not list it and the SDL row for 057E:2073 is never
    /// reached, so the raw profile is the only path and no pathInputs are
    /// needed.
    ///
    /// Numbering is the GameCube one both GameCube decoders share, not the
    /// Nintendo positional scheme: A 0, B 1, X 2, Y 3, Z 5, L click 6 (and 4),
    /// R click 7, Start 9, Home 10, Capture 14, C 15, ZL 16, the control stick
    /// on axes 0 and 1, the C-stick on 2 and 3, L and R on axes 4 and 5.
    ///
    /// Body: the classic GameCube bean, about 140 mm wide. The large octagonal
    /// control stick gate is high on the left lobe; the small +Control Pad
    /// sits on a round bulb below and inboard of it, split from the outer
    /// handle by a notch. The right lobe holds the big green A with the small
    /// red B low on its left, the kidney X curving around its right side and
    /// the kidney Y over its top; the yellow C-stick sits on the right bulb,
    /// mirroring the +Control Pad. START/PAUSE is alone on the bridge above the
    /// narrow arch between the grips. Positions are measured from Nintendo's
    /// own diagram of this controller (a front view from slightly above), with
    /// the vertical foreshortening taken out.
    ///
    /// Top, left to right as Nintendo's diagram numbers them: the L trigger
    /// wrapping the rear left corner with the new ZL in front of it, Capture,
    /// SYNC, the USB-C port with the player LEDs behind it, the charge LED,
    /// HOME with C in front of it, and the R trigger with the long Z in front
    /// of it. Neither stick clicks and there is no Minus button.
    static let gameCubeSwitch2 = ControllerLayout(
        id: .gameCubeSwitch2,
        displayName: "GameCube Controller (Switch 2)",
        maker: .nintendo,
        family: .gameCube,
        aspect: 1.45,
        topStrip: 0.26,
        backStrip: 0,
        silhouette: Silhouette(front: gameCubeSwitch2Front, top: gameCubeSwitch2Top),
        controls: gameCubeSwitch2Controls,
        // L also reads as btn 4 so a bumper row fires from it; it has no
        // place of its own on the body.
        offBody: [
            OffBodyInput(serialized: "btn 4", reason: "Legacy alias of the L full-press click (also btn 6), kept so older bumper rows still fire", copy: true),
        ],
        // The raw profile names it; the vendor and product IDs back that up.
        // 0x2073 is only this controller, so neither rule matches the Switch 2
        // Pro Controller (0x2069) or the GameCube adapter (0x0337).
        match: [
            [.rawProfileLayout("switch2GameCube")],
            [.vidPid(vendor: 0x057E, products: [0x2073])],
        ],
        matchPriority: 30,
        readability: .partial("Experimental, USB only: read from its report 0x05 the way SDL reads it, analog L and R included; not yet checked on a real pad"),
        approximate: true,
        sources: [
            "en-americas-support.nintendo.com Nintendo GameCube Controller Diagram (answer 68429, the Switch 2 model)",
            "nintendo.com/au/support/articles/nintendo-gamecube-controller-diagram (diagram image bee-gc-controller-diagram)",
            "nintendolife.com review: Nintendo Switch Online GameCube Controller (top edge buttons, USB-C in the middle)",
            "en.wikipedia.org GameCube controller (140 x 100 x 65 mm)",
            "SDL src/joystick/hidapi/SDL_hidapi_switch2.c (HandleGameCubeState)",
        ]
    )

    /// The front outline: two round upper lobes, each lower side split into
    /// an outer handle and an inner bulb (the +Control Pad on the left, the
    /// C-stick on the right), and a narrow arch under the START/PAUSE bridge.
    private static let gameCubeSwitch2Front: [PathOp] = Silhouette.symmetric([
        .move(0.5, 0.02),
        // Top edge, falling slightly to the upper left corner.
        .curve(0.16, 0.06, c1x: 0.36, c1y: 0.02, c2x: 0.24, c2y: 0.03),
        // Round upper lobe around the control stick.
        .curve(0.008, 0.40, c1x: 0.06, c1y: 0.1, c2x: 0.008, c2y: 0.24),
        // Outer side of the handle.
        .curve(0.03, 0.92, c1x: 0.008, c1y: 0.62, c2x: 0.006, c2y: 0.82),
        // Rounded handle bottom.
        .curve(0.13, 0.95, c1x: 0.06, c1y: 1.02, c2x: 0.115, c2y: 1.0),
        // Inner side of the handle, up to the notch.
        .curve(0.18, 0.74, c1x: 0.15, c1y: 0.88, c2x: 0.165, c2y: 0.76),
        // The +Control Pad bulb: down its outer side, round its bottom.
        .curve(0.33, 0.965, c1x: 0.2, c1y: 0.84, c2x: 0.25, c2y: 0.965),
        .curve(0.463, 0.7, c1x: 0.42, c1y: 0.965, c2x: 0.47, c2y: 0.85),
        // Up its inner side to the bridge.
        .curve(0.43, 0.525, c1x: 0.462, c1y: 0.6, c2x: 0.45, c2y: 0.55),
        // The arch under START/PAUSE.
        .curve(0.5, 0.48, c1x: 0.45, c1y: 0.495, c2x: 0.47, c2y: 0.48),
    ])

    /// The shoulder edge seen from above: rounded rear corners where L and R
    /// wrap the lobes, a gentle hump in the middle around the USB-C port.
    private static let gameCubeSwitch2Top: [PathOp] = Silhouette.symmetric([
        .move(0.5, 0.06),
        .curve(0.3, 0.1, c1x: 0.42, c1y: 0.06, c2x: 0.36, c2y: 0.08),
        .curve(0.03, 0.45, c1x: 0.12, c1y: 0.06, c2x: 0.03, c2y: 0.2),
        .curve(0.1, 0.96, c1x: 0.03, c1y: 0.78, c2x: 0.05, c2y: 0.96),
        .line(0.5, 0.96),
    ])

    private static let gameCubeSwitch2Controls: [PlacedControl] = [
        // Top: L and R wrap the rear corners. They are analog with a click at
        // the bottom of the pull, but the decoder only reads the clicks, so
        // axes 4 and 5 are 0 or 1 copies of btn 6 and 7.
        PlacedControl(id: "l", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.17, y: 0.2431), size: 0.18, height: 0.13,
                      shape: .roundedRect(corner: 0.45), inputs: .trigger(axis: 4, digital: 6),
                      note: "Analog on the controller, read as 0 or 1 from its full-press click for now (also btn 4)", callout: .above),
        PlacedControl(id: "r", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.83, y: 0.2431), size: 0.18, height: 0.13,
                      shape: .roundedRect(corner: 0.45), inputs: .trigger(axis: 5, digital: 7),
                      note: "Analog on the controller, read as 0 or 1 from its full-press click for now", callout: .above),
        // ZL, new on this model, sits on the front edge in front of L; the
        // long Z sits in the same place in front of R.
        PlacedControl(id: "zl", kind: .shoulder, face: .top, center: CGPoint(x: 0.15, y: 0.82), size: 0.065, height: 0.035,
                      shape: .capsule(angleDegrees: 0), printed: "ZL", inputs: .button(16), callout: .below),
        PlacedControl(id: "z", kind: .shoulder, face: .top, center: CGPoint(x: 0.845, y: 0.8), size: 0.16, height: 0.045,
                      shape: .capsule(angleDegrees: 0), inputs: .button(5), callout: .below),
        // Top center, flush and the body's color.
        PlacedControl(id: "capture", kind: .menuButton, face: .top, center: CGPoint(x: 0.355, y: 0.25), size: 0.036, height: 0.028,
                      shape: .roundedRect(corner: 0.25), symbol: "camera", inputs: .button(14), callout: .above),
        PlacedControl(id: "sync", kind: .other, face: .top, center: CGPoint(x: 0.41, y: 0.52), size: 0.024,
                      readable: .notReported("SYNC pairs the controller over Bluetooth and has no bit in report 0x05")),
        PlacedControl(id: "player-leds", kind: .light, face: .top, center: CGPoint(x: 0.5, y: 0.34), size: 0.1, height: 0.012,
                      shape: .capsule(angleDegrees: 0),
                      readable: .notReported("Output only: InputConfig lights player 1 when it starts the controller")),
        PlacedControl(id: "usbc", kind: .port, face: .top, center: CGPoint(x: 0.5, y: 0.66), size: 0.07, height: 0.022,
                      shape: .capsule(angleDegrees: 0), note: "The cable InputConfig reads this controller over"),
        PlacedControl(id: "charge-led", kind: .light, face: .top, center: CGPoint(x: 0.58, y: 0.5), size: 0.014,
                      readable: .notReported("A charging light, not an input")),
        PlacedControl(id: "home", kind: .homeButton, face: .top, center: CGPoint(x: 0.643, y: 0.28), size: 0.036,
                      symbol: "house", inputs: .button(10), callout: .above),
        PlacedControl(id: "c", kind: .menuButton, face: .top, center: CGPoint(x: 0.64, y: 0.64), size: 0.036,
                      shape: .roundedRect(corner: 0.25), printed: "C", inputs: .button(15),
                      note: "GameChat on the console; any function here", callout: .below),

        // Front, left: the big octagonal control stick high on the lobe, the
        // small +Control Pad on the bulb below and inboard.
        PlacedControl(id: "stick", kind: .stick, center: CGPoint(x: 0.18, y: 0.45), size: 0.19, shape: .octagonGate,
                      inputs: .stick(x: 0, y: 1, press: nil),
                      note: "No click. Scaled with the Pro Controller's range, so full tilt may read short of 1", callout: .below),
        PlacedControl(id: "dpad", kind: .dpad, center: CGPoint(x: 0.334, y: 0.78), size: 0.13, shape: .crossPad,
                      inputs: .hat(0), callout: .below),

        // Center: START/PAUSE alone on the bridge.
        PlacedControl(id: "start", kind: .menuButton, center: CGPoint(x: 0.5, y: 0.405), size: 0.045,
                      symbol: "playpause", inputs: .button(9), callout: .below),

        // Front, right: big A, small B low on its left, kidney X around its
        // right side, kidney Y over its top.
        PlacedControl(id: "a", kind: .faceButton, center: CGPoint(x: 0.813, y: 0.44), size: 0.12, tint: .gameCubeGreen,
                      inputs: .button(0), callout: .below),
        PlacedControl(id: "b", kind: .faceButton, center: CGPoint(x: 0.687, y: 0.53), size: 0.075, tint: .gameCubeRed,
                      inputs: .button(1), callout: .below),
        PlacedControl(id: "x", kind: .faceButton, center: CGPoint(x: 0.925, y: 0.4), size: 0.06, height: 0.11,
                      shape: .capsule(angleDegrees: -12), inputs: .button(2), callout: .below),
        PlacedControl(id: "y", kind: .faceButton, center: CGPoint(x: 0.835, y: 0.27), size: 0.105, height: 0.06,
                      shape: .capsule(angleDegrees: -10), inputs: .button(3), callout: .above),

        // Front, right bulb: the yellow C-stick in its own octagonal gate.
        PlacedControl(id: "cstick", kind: .stick, center: CGPoint(x: 0.662, y: 0.77), size: 0.15, shape: .octagonGate,
                      printed: "C", tint: .snesYellow, inputs: .stick(x: 2, y: 3, press: nil),
                      note: "No click. Scaled with the Pro Controller's range, so full tilt may read short of 1", callout: .below),
    ]
}
