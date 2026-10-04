import Foundation
import CoreGraphics

extension ControllerLayout {
    /// Joy-Con 2 (L) and (R) held together as one pad, for Nintendo Switch 2.
    /// InputConfig cannot read them: they connect over a custom Nintendo
    /// Bluetooth LE protocol that macOS has no driver for, so neither
    /// GameController nor IOHIDManager ever lists them, and the app has no
    /// CoreBluetooth reader. Over USB, Switch2USBEnabler starts only the
    /// Switch 2 Pro (0x2069) and the GameCube pad (0x2073). So every control
    /// is drawn dashed and the layout has no match rules: it is only shown
    /// when someone picks it by hand.
    ///
    /// Drawn like the first Joy-Con pair: the two real controllers side by
    /// side, rails facing, not one merged body. Each Joy-Con 2 is 116 mm tall
    /// by 41.4 mm wide by 30.7 mm deep at its thickest (Nintendo's spec,
    /// stick tip to ZL or ZR); the left one spans x 0 to 0.34 and the right
    /// one 0.66 to 1.00, so the face is about 121.8 mm wide by 116 mm tall.
    ///
    /// When a reader lands, face buttons must use the POSITIONAL scheme every
    /// Nintendo layout uses (btn 0 bottom B, 1 right A, 2 left Y, 3 top X),
    /// as the GameController path for Nintendo pads is being changed to it.
    ///
    /// Not drawn: the release buttons on the back of each Joy-Con 2 (a
    /// mechanical magnet latch), the mouse feet on the rails, the NFC reader
    /// under the right stick, and the six-axis motion sensor inside each
    /// half. None of them is a control the Mac could report.
    static let joyCon2Pair = ControllerLayout(
        id: .joyCon2Pair,
        displayName: "Joy-Con 2 pair",
        maker: .nintendo,
        family: .nintendo,
        aspect: 121.8 / 116.0,
        topStrip: 0.25,
        backStrip: 0.5,
        silhouette: joyCon2PairSilhouette,
        controls: joyCon2PairControls,
        match: [],
        readability: .notReadable("InputConfig cannot read Joy-Con 2 yet"),
        approximate: true,
        sources: [
            "nintendo.com Nintendo Switch 2 tech specs (Joy-Con 2: 116 x 41.4 x 30.7 mm; console 116 x 272 x 13.9 mm)",
            "en-americas-support.nintendo.com Joy-Con 2 Diagram (answer 68499): front, back and rail parts",
            "en-americas-support.nintendo.com Joy-Con 2 Charging Grip Diagram (answer 68607): GL and GR on the back",
            "nintendosoup.com: the Joy-Con 2 Charging Grip adds GL and GR like the Switch 2 Pro",
            "Joy-Con 2 product photos (front, rail and top views)",
            "SDL src/joystick/hidapi/SDL_hidapi_switch2.c (Joy-Con 2 buttons, digital ZL and ZR, grip buttons)",
        ]
    )

    // MARK: - Outline

    /// The left Joy-Con 2's front: large, nearly circular corners on the
    /// outer edge, the flat magnetic rail with small corners on the inside
    /// (x 0.34).
    private static let joyCon2PairLeftFront: [PathOp] = [
        .move(0.15, 0.01),
        .line(0.328, 0.01),
        .quad(0.34, 0.022, cx: 0.34, cy: 0.01),
        .line(0.34, 0.978),
        .quad(0.328, 0.99, cx: 0.34, cy: 0.99),
        .line(0.15, 0.99),
        .curve(0.008, 0.845, c1x: 0.07, c1y: 0.99, c2x: 0.008, c2y: 0.925),
        .line(0.008, 0.155),
        .curve(0.15, 0.01, c1x: 0.008, c1y: 0.075, c2x: 0.07, c2y: 0.01),
        .close,
    ]

    /// The left Joy-Con 2 seen from above: rear edge at y 0 where ZL bulges
    /// back, the outer rear corner rounded with the curved back, the rail
    /// flat on the inside.
    private static let joyCon2PairLeftTop: [PathOp] = [
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

    /// The Joy-Con 2 Charging Grip from behind, as held: a broad top, a
    /// rounded handle behind each Joy-Con 2, and a shallow arch between the
    /// handles. It is the only part of the pair with anything on the back.
    private static let joyCon2PairGripBack: [PathOp] = Silhouette.symmetric([
        .move(0.5, 0.05),
        .line(0.14, 0.04),
        .curve(0.02, 0.22, c1x: 0.06, c1y: 0.04, c2x: 0.02, c2y: 0.1),
        .curve(0.04, 0.82, c1x: 0.02, c1y: 0.5, c2x: 0.025, c2y: 0.7),
        .curve(0.2, 0.97, c1x: 0.06, c1y: 0.94, c2x: 0.13, c2y: 0.98),
        .curve(0.34, 0.86, c1x: 0.27, c1y: 0.96, c2x: 0.31, c2y: 0.9),
        .curve(0.5, 0.76, c1x: 0.39, c1y: 0.79, c2x: 0.45, c2y: 0.76),
    ])

    /// The right Joy-Con 2 is the left one mirrored across the center line.
    private static func joyCon2PairMirrored(_ ops: [PathOp]) -> [PathOp] {
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

    /// Two separate bars on the front and on the top with the gap between;
    /// the Charging Grip's back below.
    private static let joyCon2PairSilhouette = Silhouette(
        front: joyCon2PairLeftFront + joyCon2PairMirrored(joyCon2PairLeftFront),
        top: joyCon2PairLeftTop + joyCon2PairMirrored(joyCon2PairLeftTop),
        back: joyCon2PairGripBack
    )

    // MARK: - Controls

    private static let joyCon2NoReader = "macOS has no driver for Joy-Con 2 and InputConfig has no Joy-Con 2 reader yet"

    private static let joyCon2PairControls: [PlacedControl] = [
        // Top: L and R along the front edge, ZL and ZR behind them. ZL and ZR
        // are on or off buttons on the Joy-Con 2, as on the first Joy-Con.
        PlacedControl(id: "zl", kind: .trigger(.digital), face: .top, center: CGPoint(x: 0.17, y: 0.23), size: 0.22, height: 0.13,
                      shape: .roundedRect(corner: 0.35), printed: "ZL",
                      readable: .notReported(joyCon2NoReader), note: "Digital: fully pressed or released", callout: .above),
        PlacedControl(id: "zr", kind: .trigger(.digital), face: .top, center: CGPoint(x: 0.83, y: 0.23), size: 0.22, height: 0.13,
                      shape: .roundedRect(corner: 0.35), printed: "ZR",
                      readable: .notReported(joyCon2NoReader), note: "Digital: fully pressed or released", callout: .above),
        PlacedControl(id: "l", kind: .shoulder, face: .top, center: CGPoint(x: 0.165, y: 0.74), size: 0.25, height: 0.055,
                      shape: .capsule(angleDegrees: 0), printed: "L",
                      readable: .notReported(joyCon2NoReader), callout: .below),
        PlacedControl(id: "r", kind: .shoulder, face: .top, center: CGPoint(x: 0.835, y: 0.74), size: 0.25, height: 0.055,
                      shape: .capsule(angleDegrees: 0), printed: "R",
                      readable: .notReported(joyCon2NoReader), callout: .below),

        // Joy-Con 2 (L), top to bottom: Minus at the inner top corner, the
        // stick in the upper third, the four separate direction buttons in
        // the lower half, Capture below them toward the rail.
        PlacedControl(id: "minus", kind: .menuButton, center: CGPoint(x: 0.245, y: 0.085), size: 0.042,
                      symbol: "minus", readable: .notReported(joyCon2NoReader), callout: .above),
        PlacedControl(id: "lstick", kind: .stick, center: CGPoint(x: 0.165, y: 0.29), size: 0.15,
                      readable: .notReported(joyCon2NoReader), note: "Clicks in as the left stick button", callout: .below),
        PlacedControl(id: "dpad", kind: .dpad, center: CGPoint(x: 0.165, y: 0.575), size: 0.22, shape: .fourButtonPad,
                      readable: .notReported(joyCon2NoReader), note: "Four separate direction buttons, not a cross", callout: .below),
        PlacedControl(id: "capture", kind: .menuButton, center: CGPoint(x: 0.24, y: 0.825), size: 0.045,
                      shape: .roundedRect(corner: 0.22), symbol: "camera",
                      readable: .notReported(joyCon2NoReader), callout: .below),

        // Joy-Con 2 (R): Plus at the inner top corner, the face buttons in
        // the upper third, the stick in the lower half (so the sticks are
        // staggered, left high and right low), HOME toward the rail below
        // the stick and the new C button directly under HOME.
        PlacedControl(id: "plus", kind: .menuButton, center: CGPoint(x: 0.755, y: 0.085), size: 0.042,
                      symbol: "plus", readable: .notReported(joyCon2NoReader), callout: .above),
        PlacedControl(id: "x", kind: .faceButton, center: CGPoint(x: 0.83, y: 0.2), size: 0.068,
                      printed: "X", readable: .notReported(joyCon2NoReader), callout: .above),
        PlacedControl(id: "y", kind: .faceButton, center: CGPoint(x: 0.748, y: 0.288), size: 0.068,
                      printed: "Y", readable: .notReported(joyCon2NoReader), callout: .left),
        PlacedControl(id: "a", kind: .faceButton, center: CGPoint(x: 0.912, y: 0.288), size: 0.068,
                      printed: "A", readable: .notReported(joyCon2NoReader), callout: .right),
        PlacedControl(id: "b", kind: .faceButton, center: CGPoint(x: 0.83, y: 0.376), size: 0.068,
                      printed: "B", readable: .notReported(joyCon2NoReader), callout: .below),
        PlacedControl(id: "rstick", kind: .stick, center: CGPoint(x: 0.835, y: 0.585), size: 0.15,
                      readable: .notReported(joyCon2NoReader), note: "Clicks in as the right stick button", callout: .below),
        PlacedControl(id: "home", kind: .homeButton, center: CGPoint(x: 0.765, y: 0.79), size: 0.055,
                      symbol: "house", readable: .notReported(joyCon2NoReader), callout: .above),
        PlacedControl(id: "c", kind: .menuButton, center: CGPoint(x: 0.765, y: 0.88), size: 0.04,
                      printed: "C", readable: .notReported(joyCon2NoReader),
                      note: "GameChat on the console", callout: .below),

        // Rails, as drawn upright. Along each rail from the stick end: SL or
        // SR, the optical mouse sensor just past SL, the four player LEDs,
        // SYNC, then the other shoulder. Joy-Con 2 (L) has SL at the top and
        // SR at the bottom; Joy-Con 2 (R) has SR at the top and SL at the
        // bottom, so the sensor sits next to SL on both.
        PlacedControl(id: "sl-left", kind: .shoulder, center: CGPoint(x: 0.335, y: 0.2), size: 0.018, height: 0.15,
                      shape: .capsule(angleDegrees: 0), printed: "SL",
                      readable: .notReported(joyCon2NoReader), note: "A shoulder button when one Joy-Con 2 is held sideways",
                      callout: .left),
        PlacedControl(id: "mouse-left", kind: .other, center: CGPoint(x: 0.335, y: 0.36), size: 0.02,
                      readable: .notReported("No InputConfig input can carry a controller's optical mouse movement"),
                      note: "Optical mouse sensor: slide the Joy-Con 2 rail down on a table", callout: .left),
        PlacedControl(id: "leds-left", kind: .light, center: CGPoint(x: 0.335, y: 0.48), size: 0.012, height: 0.06,
                      shape: .capsule(angleDegrees: 0),
                      readable: .notReported("Player LEDs are output only, and InputConfig has no Joy-Con 2 output path"),
                      callout: .left),
        PlacedControl(id: "sync-left", kind: .other, center: CGPoint(x: 0.335, y: 0.6), size: 0.02,
                      readable: .notReported("The SYNC button only pairs the Joy-Con 2; no API reports it"), callout: .left),
        PlacedControl(id: "sr-left", kind: .shoulder, center: CGPoint(x: 0.335, y: 0.8), size: 0.018, height: 0.15,
                      shape: .capsule(angleDegrees: 0), printed: "SR",
                      readable: .notReported(joyCon2NoReader), note: "A shoulder button when one Joy-Con 2 is held sideways",
                      callout: .left),
        PlacedControl(id: "sr-right", kind: .shoulder, center: CGPoint(x: 0.665, y: 0.2), size: 0.018, height: 0.15,
                      shape: .capsule(angleDegrees: 0), printed: "SR",
                      readable: .notReported(joyCon2NoReader), note: "A shoulder button when one Joy-Con 2 is held sideways",
                      callout: .right),
        PlacedControl(id: "sync-right", kind: .other, center: CGPoint(x: 0.665, y: 0.4), size: 0.02,
                      readable: .notReported("The SYNC button only pairs the Joy-Con 2; no API reports it"), callout: .right),
        PlacedControl(id: "leds-right", kind: .light, center: CGPoint(x: 0.665, y: 0.52), size: 0.012, height: 0.06,
                      shape: .capsule(angleDegrees: 0),
                      readable: .notReported("Player LEDs are output only, and InputConfig has no Joy-Con 2 output path"),
                      callout: .right),
        PlacedControl(id: "mouse-right", kind: .other, center: CGPoint(x: 0.665, y: 0.64), size: 0.02,
                      readable: .notReported("No InputConfig input can carry a controller's optical mouse movement"),
                      note: "Optical mouse sensor: slide the Joy-Con 2 rail down on a table", callout: .right),
        PlacedControl(id: "sl-right", kind: .shoulder, center: CGPoint(x: 0.665, y: 0.8), size: 0.018, height: 0.15,
                      shape: .capsule(angleDegrees: 0), printed: "SL",
                      readable: .notReported(joyCon2NoReader), note: "A shoulder button when one Joy-Con 2 is held sideways",
                      callout: .right),

        // Back, as held: GL and GR are on the back of the Joy-Con 2 Charging
        // Grip (sold separately), under the middle fingers. The grip that
        // comes with the console has neither.
        PlacedControl(id: "gl", kind: .paddle, face: .back, center: CGPoint(x: 0.19, y: 0.42), size: 0.042, height: 0.08,
                      shape: .capsule(angleDegrees: 0), printed: "GL",
                      readable: .notReported(joyCon2NoReader), note: "On the Joy-Con 2 Charging Grip only", callout: .below),
        PlacedControl(id: "gr", kind: .paddle, face: .back, center: CGPoint(x: 0.81, y: 0.42), size: 0.042, height: 0.08,
                      shape: .capsule(angleDegrees: 0), printed: "GR",
                      readable: .notReported(joyCon2NoReader), note: "On the Joy-Con 2 Charging Grip only", callout: .below),
    ]
}
