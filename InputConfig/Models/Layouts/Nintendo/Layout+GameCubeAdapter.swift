import Foundation
import CoreGraphics

extension ControllerLayout {
    /// Nintendo GameCube Controller (DOL-003, and the WaveBird, which reads the
    /// same) on the GameCube Controller Adapter (WUP-028, 057E:0337), about
    /// 140 mm wide and 100 mm from the shoulder edge to the grip ends.
    ///
    /// Read through the raw HID path, not GameController: RawHIDGamepadService
    /// sends the 0x13 start command and each port gets its own slot with
    /// ControllerProfileDatabase.gameCubeAdapterPort(_:), decoding input report
    /// 0x21 the way SDL's HIDAPI GameCube driver does. The device's name in the
    /// list carries the port number ("GameCube Controller Adapter (port 2)");
    /// the drawing is the same for every port.
    ///
    /// Indices on that profile (the same as the Switch 2 GameCube model's, so a
    /// preset moves between them): A btn 0, B btn 1, X btn 2, Y btn 3, Z btn 5,
    /// L full-press click btn 6 (and btn 4, see offBody), R full-press click
    /// btn 7, Start btn 9, D-pad hat 0, Control Stick axi 0/1, C-Stick axi 2/3
    /// (both with Y flipped so up reads negative), analog L axi 4, analog R axi 5.
    /// These are the GameCube's own letters, not the positional Switch scheme:
    /// A is the big center button, B sits to its lower left.
    static let gameCubeAdapter = ControllerLayout(
        id: .gameCubeAdapter,
        displayName: "GameCube Controller (USB adapter)",
        maker: .nintendo,
        family: .gameCube,
        // The adapter's pads have none of the Switch 2 model's extras.
        modelNames: ButtonNames.ModelNames(absent: [10, 14, 15, 16]),
        aspect: 140.0 / 100.0,
        topStrip: 0.2,
        backStrip: 0,
        silhouette: Silhouette(front: gameCubeFront,
                               top: Silhouette.roundedRectOps(corner: 0.22, inset: 0.04)),
        controls: gameCubeAdapterControls,
        offBody: [
            OffBodyInput(serialized: "btn 4",
                         reason: "A second copy of the L full-press click (bit 19), kept so a bumper row and a trigger-click row both fire from L", copy: true),
        ],
        // Each port's profile is "nintendo-gamecube-adapter-port1" to "-port4".
        // The adapter is read raw and gets the .switchPro brand from Nintendo's
        // vendor ID, so the brand is not used here; the identifier and the USB
        // IDs keep it apart from the Switch Pro (057E:2009) and the Switch 2
        // GameCube controller (its own switch2GameCube profile).
        match: [
            [.rawProfileIdentifier("nintendo-gamecube-adapter")],
            [.vidPid(vendor: 0x057E, products: [0x0337])],
        ],
        matchPriority: 30,
        approximate: true,
        sources: [
            "Wikipedia, GameCube controller (DOL-003): 140 x 100 x 65 mm, control placement",
            "dimensions.com GameCube Controller: 5.5 x 4 x 2.5 in",
            "SDL src/joystick/hidapi/SDL_hidapi_gamecube.c (report 0x21 port blocks, button bits)",
            "Product photos of the DOL-003 and WaveBird for placement",
        ]
    )

    /// The front outline seen from above as held: a wide body with a flat,
    /// slightly dipped top edge (the cable leaves at the center), big rounded
    /// shoulders under the L and R triggers, sides that bulge out and run
    /// into short, fat, round grips, and a broad arch between the grips just
    /// below the D-pad and C-Stick.
    static let gameCubeFront: [PathOp] = Silhouette.symmetric([
        .move(0.5, 0.035),
        .curve(0.2, 0.02, c1x: 0.38, c1y: 0.04, c2x: 0.28, c2y: 0.015),
        .curve(0.02, 0.22, c1x: 0.09, c1y: 0.025, c2x: 0.025, c2y: 0.1),
        .curve(0.04, 0.78, c1x: 0.012, c1y: 0.38, c2x: 0.015, c2y: 0.62),
        .curve(0.2, 0.99, c1x: 0.06, c1y: 0.92, c2x: 0.12, c2y: 0.99),
        .curve(0.39, 0.86, c1x: 0.29, c1y: 0.99, c2x: 0.37, c2y: 0.94),
        .curve(0.5, 0.73, c1x: 0.41, c1y: 0.77, c2x: 0.45, c2y: 0.73),
    ])

    static let gameCubeAdapterControls: [PlacedControl] = [
        // Top: the big analog L and R triggers wrap the rear corners, each with
        // a digital click at the end of its travel. Z is a small digital button
        // on top of the right shoulder, in front of R and toward the center
        // (purple on the indigo pad; the palette has no purple, so untinted).
        PlacedControl(id: "l", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.2, y: 0.23), size: 0.2, height: 0.13,
                      shape: .roundedRect(corner: 0.4), inputs: .trigger(axis: 4, digital: 6),
                      note: "Analog L; pressed all the way it clicks, which reads as btn 6 (and btn 4)", callout: .above),
        PlacedControl(id: "r", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.8, y: 0.23), size: 0.2, height: 0.13,
                      shape: .roundedRect(corner: 0.4), inputs: .trigger(axis: 5, digital: 7),
                      note: "Analog R; pressed all the way it clicks, which reads as btn 7", callout: .above),
        PlacedControl(id: "z", kind: .shoulder, face: .top, center: CGPoint(x: 0.74, y: 0.76), size: 0.14, height: 0.04,
                      shape: .capsule(angleDegrees: 0), inputs: .button(5), callout: .below),

        // Left: the Control Stick high on the left, in its octagonal gate, with
        // no press. The small +Control Pad sits lower and inward.
        PlacedControl(id: "stick", kind: .stick, center: CGPoint(x: 0.22, y: 0.34), size: 0.2, shape: .octagonGate,
                      inputs: .stick(x: 0, y: 1, press: nil), callout: .below),
        PlacedControl(id: "dpad", kind: .dpad, center: CGPoint(x: 0.33, y: 0.69), size: 0.105, shape: .crossPad,
                      inputs: .hat(0), callout: .below),

        // Center: START/PAUSE, a small round button.
        PlacedControl(id: "start", kind: .menuButton, center: CGPoint(x: 0.5, y: 0.4), size: 0.05,
                      symbol: "playpause", inputs: .button(9), note: "Printed START/PAUSE", callout: .below),

        // Right: the large green A, red B to its lower left, and the gray
        // kidney-shaped X (right of A) and Y (above A) curving around it.
        PlacedControl(id: "a", kind: .faceButton, center: CGPoint(x: 0.77, y: 0.4), size: 0.135, tint: .gameCubeGreen,
                      inputs: .button(0), callout: .below),
        PlacedControl(id: "b", kind: .faceButton, center: CGPoint(x: 0.665, y: 0.53), size: 0.07, tint: .gameCubeRed,
                      inputs: .button(1), callout: .left),
        PlacedControl(id: "x", kind: .faceButton, center: CGPoint(x: 0.89, y: 0.36), size: 0.06, height: 0.12,
                      shape: .capsule(angleDegrees: -15), inputs: .button(2), callout: .below),
        PlacedControl(id: "y", kind: .faceButton, center: CGPoint(x: 0.765, y: 0.245), size: 0.12, height: 0.06,
                      shape: .capsule(angleDegrees: -15), inputs: .button(3), callout: .above),

        // The yellow C-Stick low on the right grip, mirroring the D-pad, with
        // no press.
        PlacedControl(id: "cstick", kind: .stick, center: CGPoint(x: 0.665, y: 0.7), size: 0.13, shape: .octagonGate,
                      printed: "C", inputs: .stick(x: 2, y: 3, press: nil), callout: .below),
    ]
}
