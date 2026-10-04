import Foundation
import CoreGraphics

extension ControllerLayout {
    /// Two original Joy-Con (L and R) held together as one pad, read through
    /// GameController, which fuses them into one GCExtendedGamepad whose
    /// productCategory is "Nintendo Switch Joy-Con (L/R)".
    ///
    /// Drawn as the two real controllers side by side, rails facing each
    /// other, not as one merged body. Each Joy-Con is 102 mm tall by 35.9 mm
    /// wide by 28.4 mm deep; the left one spans x 0 to 0.34 and the right one
    /// 0.66 to 1.00, so the whole face is about 105.6 mm wide by 102 mm tall.
    ///
    /// Face buttons use the POSITIONAL scheme (btn 0 bottom B, 1 right A,
    /// 2 left Y, 3 top X), because the GameController path is being changed
    /// to positional for Nintendo pads. Until that lands, readControllerState
    /// reads buttonA (the physical A on the right) into btn 0.
    ///
    /// Not reported to the Mac: SL and SR on both rails, the sync buttons, and
    /// motion (Apple reports no Joy-Con gyro or accelerometer).
    static let joyConPair = ControllerLayout(
        id: .joyConPair,
        displayName: "Joy-Con pair",
        maker: .nintendo,
        family: .nintendo,
        // No C, GL or GR (the Switch 2 Pro has those), no touchpad or mute.
        modelNames: ButtonNames.ModelNames(absent: [13, 15, 16, 17, 18, 19, 20, 21]),
        aspect: 1.035,
        topStrip: 0.26,
        backStrip: 0,
        silhouette: joyConPairSilhouette,
        controls: joyConPairControls,
        match: [[.gcProductCategoryContains("Switch Joy-Con (L/R)")]],
        matchPriority: 10,
        readability: .partial("macOS does not report SL, SR or Joy-Con motion"),
        approximate: true,
        sources: [
            "nintendo.com Joy-Con specifications (102 x 35.9 x 28.4 mm)",
            "Nintendo Switch Joy-Con product photos (front, rail and top views)",
            "SDL src/joystick/apple/SDL_mfijoystick.m (productCategory \"Nintendo Switch Joy-Con (L/R)\", Home never held on the pair)",
            "SDL src/joystick/hidapi/SDL_hidapi_switch.c (SL and SR bits, digital ZL and ZR)",
        ]
    )

    // MARK: - Outline

    /// The left Joy-Con's front: large radius corners on the outer edge, the
    /// flat rail edge with small corners on the inside (x 0.34).
    private static let joyConPairLeftFront: [PathOp] = [
        .move(0.15, 0.01),
        .line(0.328, 0.01),
        .quad(0.34, 0.022, cx: 0.34, cy: 0.01),
        .line(0.34, 0.978),
        .quad(0.328, 0.99, cx: 0.34, cy: 0.99),
        .line(0.15, 0.99),
        .curve(0.008, 0.843, c1x: 0.072, c1y: 0.99, c2x: 0.008, c2y: 0.924),
        .line(0.008, 0.157),
        .curve(0.15, 0.01, c1x: 0.008, c1y: 0.076, c2x: 0.072, c2y: 0.01),
        .close,
    ]

    /// The left Joy-Con seen from above: rear edge at y 0, the outer rear
    /// corner rounded with the curved back, the rail flat on the inside.
    private static let joyConPairLeftTop: [PathOp] = [
        .move(0.10, 0.04),
        .line(0.328, 0.04),
        .quad(0.34, 0.09, cx: 0.34, cy: 0.04),
        .line(0.34, 0.91),
        .quad(0.328, 0.96, cx: 0.34, cy: 0.96),
        .line(0.06, 0.96),
        .quad(0.008, 0.80, cx: 0.008, cy: 0.96),
        .line(0.008, 0.40),
        .curve(0.10, 0.04, c1x: 0.008, c1y: 0.15, c2x: 0.04, c2y: 0.04),
        .close,
    ]

    /// The right Joy-Con is the left one mirrored across the center line.
    private static func joyConPairMirrored(_ ops: [PathOp]) -> [PathOp] {
        ops.map { op in
            switch op {
            case .move(let x, let y): return .move(1 - x, y)
            case .line(let x, let y): return .line(1 - x, y)
            case .quad(let x, let y, let cx, let cy): return .quad(1 - x, y, cx: 1 - cx, cy: cy)
            case .curve(let x, let y, let c1x, let c1y, let c2x, let c2y):
                return .curve(1 - x, y, c1x: 1 - c1x, c1y: c1y, c2x: 1 - c2x, c2y: c2y)
            case .close: return .close
            }
        }
    }

    /// Two separate bars on the front and on the top, with the gap between.
    private static let joyConPairSilhouette = Silhouette(
        front: joyConPairLeftFront + joyConPairMirrored(joyConPairLeftFront),
        top: joyConPairLeftTop + joyConPairMirrored(joyConPairLeftTop),
        back: nil
    )

    // MARK: - Controls

    private static let joyConPairControls: [PlacedControl] = [
        // Top: L and R along the front edge, ZL and ZR behind them. ZL and ZR
        // are on or off buttons; GameController sends 0 or 1 on axes 4 and 5.
        PlacedControl(id: "zl", kind: .trigger(.digital), face: .top, center: CGPoint(x: 0.17, y: 0.2338), size: 0.22, height: 0.13,
                      shape: .roundedRect(corner: 0.35), inputs: .trigger(axis: 4, digital: 6),
                      note: "Digital: reads fully pressed or released", callout: .above),
        PlacedControl(id: "zr", kind: .trigger(.digital), face: .top, center: CGPoint(x: 0.83, y: 0.2338), size: 0.22, height: 0.13,
                      shape: .roundedRect(corner: 0.35), inputs: .trigger(axis: 5, digital: 7),
                      note: "Digital: reads fully pressed or released", callout: .above),
        PlacedControl(id: "l", kind: .shoulder, face: .top, center: CGPoint(x: 0.165, y: 0.74), size: 0.25, height: 0.055,
                      shape: .capsule(angleDegrees: 0), inputs: .button(4), callout: .below),
        PlacedControl(id: "r", kind: .shoulder, face: .top, center: CGPoint(x: 0.835, y: 0.74), size: 0.25, height: 0.055,
                      shape: .capsule(angleDegrees: 0), inputs: .button(5), callout: .below),

        // Joy-Con (L), top to bottom: Minus at the inner top corner, the
        // stick, the four separate arrow buttons, Capture toward the rail.
        PlacedControl(id: "minus", kind: .menuButton, center: CGPoint(x: 0.245, y: 0.09), size: 0.045,
                      symbol: "minus", inputs: .button(8), callout: .above),
        PlacedControl(id: "lstick", kind: .stick, center: CGPoint(x: 0.17, y: 0.275), size: 0.14,
                      inputs: .stick(x: 0, y: 1, press: 11), callout: .below),
        PlacedControl(id: "dpad", kind: .dpad, center: CGPoint(x: 0.17, y: 0.575), size: 0.23, shape: .fourButtonPad,
                      inputs: .hat(0), note: "Four separate arrow buttons, read as one D-pad", callout: .below),
        PlacedControl(id: "capture", kind: .menuButton, center: CGPoint(x: 0.24, y: 0.82), size: 0.05,
                      shape: .roundedRect(corner: 0.22), symbol: "camera", inputs: .button(14),
                      note: "Reaches the app as the profile's Button Share", callout: .below),

        // Joy-Con (R): Plus at the inner top corner, the face buttons, the
        // stick, Home toward the rail. Positional numbering (see above).
        PlacedControl(id: "plus", kind: .menuButton, center: CGPoint(x: 0.755, y: 0.09), size: 0.045,
                      symbol: "plus", inputs: .button(9), callout: .above),
        PlacedControl(id: "x", kind: .faceButton, center: CGPoint(x: 0.83, y: 0.202), size: 0.068,
                      inputs: .button(3), callout: .above),
        PlacedControl(id: "y", kind: .faceButton, center: CGPoint(x: 0.75, y: 0.29), size: 0.068,
                      inputs: .button(2), callout: .left),
        PlacedControl(id: "a", kind: .faceButton, center: CGPoint(x: 0.91, y: 0.29), size: 0.068,
                      inputs: .button(1), callout: .right),
        PlacedControl(id: "b", kind: .faceButton, center: CGPoint(x: 0.83, y: 0.378), size: 0.068,
                      inputs: .button(0), callout: .below),
        PlacedControl(id: "rstick", kind: .stick, center: CGPoint(x: 0.83, y: 0.585), size: 0.14,
                      inputs: .stick(x: 2, y: 3, press: 12), callout: .below),
        PlacedControl(id: "home", kind: .homeButton, center: CGPoint(x: 0.765, y: 0.82), size: 0.06,
                      symbol: "house", inputs: .button(10),
                      readable: .conditional("GameController may never report the pair's Home button as held"),
                      note: "SDL skips it: on the pair, Home never shows as held down", callout: .below),

        // Rails: SL and SR on each inner edge, the sync button between them.
        // Joy-Con (L) has SL above SR; Joy-Con (R) has SR above SL.
        PlacedControl(id: "sl-left", kind: .shoulder, center: CGPoint(x: 0.335, y: 0.22), size: 0.018, height: 0.13,
                      shape: .capsule(angleDegrees: 0), printed: "SL",
                      readable: .notReported("macOS does not report SL and SR in pair mode"), callout: .left),
        PlacedControl(id: "sr-left", kind: .shoulder, center: CGPoint(x: 0.335, y: 0.74), size: 0.018, height: 0.13,
                      shape: .capsule(angleDegrees: 0), printed: "SR",
                      readable: .notReported("macOS does not report SL and SR in pair mode"), callout: .left),
        PlacedControl(id: "sync-left", kind: .other, center: CGPoint(x: 0.335, y: 0.47), size: 0.02,
                      readable: .notReported("The sync button only pairs the Joy-Con; no API reports it"), callout: .left),
        PlacedControl(id: "sr-right", kind: .shoulder, center: CGPoint(x: 0.665, y: 0.22), size: 0.018, height: 0.13,
                      shape: .capsule(angleDegrees: 0), printed: "SR",
                      readable: .notReported("macOS does not report SL and SR in pair mode"), callout: .right),
        PlacedControl(id: "sl-right", kind: .shoulder, center: CGPoint(x: 0.665, y: 0.74), size: 0.018, height: 0.13,
                      shape: .capsule(angleDegrees: 0), printed: "SL",
                      readable: .notReported("macOS does not report SL and SR in pair mode"), callout: .right),
        PlacedControl(id: "sync-right", kind: .other, center: CGPoint(x: 0.665, y: 0.47), size: 0.02,
                      readable: .notReported("The sync button only pairs the Joy-Con; no API reports it"), callout: .right),
    ]
}
