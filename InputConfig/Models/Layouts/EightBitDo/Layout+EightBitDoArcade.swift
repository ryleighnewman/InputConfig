import Foundation
import CoreGraphics

extension ControllerLayout {
    /// 8BitDo Arcade Stick for Switch and Windows (2020, FCC ID 2AOWF-ARCADE),
    /// a flat box 303 x 203 mm on the top panel. Positions are measured from
    /// the FCC external photo of the top panel (taken at a slight angle, so
    /// they are close but not exact).
    ///
    /// The top panel, as held: a function band along the far edge (from the
    /// left: the S / OFF / X mode knob, the LS / DP / RS stick knob, then the
    /// green pair, yellow star and blue home buttons; below them the four
    /// player LEDs, the BT / 2.4G slide switch, SELECT and START; P1 and P2
    /// at the far right). Below the band, the lever in a round plate on the
    /// left and eight 30 mm buttons in a Vewlix block on a black deck on the
    /// right (the first column sits lower). A plain wrist rest runs along
    /// the near edge.
    ///
    /// The button legends are lit from underneath and change with the mode
    /// switch: Y X R L over B A ZR ZL in S mode, X Y RB LB over A B RT LT in
    /// X mode. Both put the same function in the same place, so the inputs
    /// below use the positional numbering (btn 0 the bottom face button, 1
    /// the right, 2 the left, 3 the top) that the app uses for Nintendo pads
    /// (GameController path being changed to positional now) and that it
    /// already gets from an Xbox-style pad. The legends follow the person's
    /// Face button names setting, since the stick prints both.
    ///
    /// How a Mac sees it:
    /// - S mode (Bluetooth, the 2.4G receiver, or USB) claims to be a
    ///   Nintendo Switch Pro Controller (057E:2009). Nothing it reports
    ///   tells the two apart, so it is drawn as the Switch Pro Controller.
    /// - X mode over Bluetooth pairs as "8BitDo Arcade Stick" (8BitDo's
    ///   manual), which is what this layout matches.
    /// - X mode over the 2.4G receiver or a USB cable speaks XInput over the
    ///   vendor-class XUSB interface, which IOHIDManager never sees.
    static let eightBitDoArcade = ControllerLayout(
        id: .eightBitDoArcade,
        displayName: "8BitDo Arcade Stick",
        maker: .eightBitDo,
        family: nil,
        modelNames: ButtonNames.ModelNames(absent: [13, 14, 15, 16, 17, 18, 19, 20, 21]),
        aspect: 303.0 / 203.0,
        topStrip: 0,
        backStrip: 0,
        silhouette: Silhouette(front: eightBitDoArcadeFront),
        controls: eightBitDoArcadeControls,
        // The name only: S mode reports a Switch Pro Controller's identity,
        // and "8BitDo F30 Arcade Stick" (an older, different stick) does not
        // contain this text. A raw HID read puts the product string in
        // productCategory; GameController puts it in vendorName.
        match: [
            [.gcProductCategoryContains("8BitDo Arcade Stick")],
            [.gcVendorNameContains("8BitDo Arcade Stick")],
        ],
        matchPriority: 20,
        readability: .partial("X mode over Bluetooth only. S mode reads as a Switch Pro Controller and is drawn as one; X mode through the 2.4G receiver or a USB cable is XInput, which macOS does not report"),
        approximate: true,
        sources: [
            "FCC ID 2AOWF-ARCADE external photos (top panel view with a millimeter ruler)",
            "FCC ID 2AOWF-ARCADE user manual: mode switch S / OFF / X, connection switch BT / 2.4G, control stick switch LS / DP / RS, star button turbo, P1 and P2 macros, X mode Bluetooth pairs as 8BitDo Arcade Stick",
            "8bitdo.com/arcade-stick (303 x 203 x 111.5 mm, P1 / P2 macro buttons, LED legends that change with the mode)",
            "support.8bitdo.com/faq/arcade-stick.html (P1 and P2 are macro buttons set in 8BitDo Ultimate Software)",
            "Reviews (Shacknews, Grandpa Gaming): knobs at the top left, P1 and P2 at the top right, Vewlix button layout, lit legends; green pair, yellow star, blue home",
        ]
    )

    /// The body: a rounded box, with the panel seams printed on the real
    /// stick drawn as inner outlines (the function band, the lever plate
    /// with its round ring, the black button deck, and the wrist rest), so
    /// it reads as this stick at a glance.
    static let eightBitDoArcadeFront: [PathOp] =
        Silhouette.roundedRectOps(corner: 0.025, inset: 0.01)
        + eightBitDoArcadePanel(0.031, 0.042, 0.969, 0.238, corner: 0.012)    // function band
        + eightBitDoArcadePanel(0.031, 0.247, 0.373, 0.747, corner: 0.012)    // lever plate
        + eightBitDoArcadeRing(cx: 0.203, cy: 0.499, rx: 0.137, ry: 0.201)    // ring around the lever
        + eightBitDoArcadePanel(0.377, 0.251, 0.969, 0.739, corner: 0.008)    // black button deck
        + eightBitDoArcadePanel(0.031, 0.755, 0.969, 0.951, corner: 0.012)    // wrist rest

    /// A rounded rectangle seam, clockwise like the outline so the body
    /// fill has no holes.
    private static func eightBitDoArcadePanel(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat,
                                              corner r: CGFloat) -> [PathOp] {
        [.move(x0 + r, y0), .line(x1 - r, y0), .quad(x1, y0 + r, cx: x1, cy: y0), .line(x1, y1 - r),
         .quad(x1 - r, y1, cx: x1, cy: y1), .line(x0 + r, y1), .quad(x0, y1 - r, cx: x0, cy: y1),
         .line(x0, y0 + r), .quad(x0 + r, y0, cx: x0, cy: y0), .close]
    }

    /// An ellipse seam, clockwise.
    private static func eightBitDoArcadeRing(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat) -> [PathOp] {
        let k: CGFloat = 0.5523
        return [.move(cx, cy - ry),
                .curve(cx + rx, cy, c1x: cx + k * rx, c1y: cy - ry, c2x: cx + rx, c2y: cy - k * ry),
                .curve(cx, cy + ry, c1x: cx + rx, c1y: cy + k * ry, c2x: cx + k * rx, c2y: cy + ry),
                .curve(cx - rx, cy, c1x: cx - k * rx, c1y: cy + ry, c2x: cx - rx, c2y: cy + k * ry),
                .curve(cx, cy - ry, c1x: cx - rx, c1y: cy - k * ry, c2x: cx - k * rx, c2y: cy - ry),
                .close]
    }

    static let eightBitDoArcadeControls: [PlacedControl] = [
        // Function band, first row: the two rotary knobs, then pair, star
        // and home. The knobs and pair are handled by the stick itself.
        PlacedControl(id: "mode-knob", kind: .other, center: CGPoint(x: 0.067, y: 0.09), size: 0.055,
                      printed: "S/X",
                      readable: .notReported("Mode knob, S / OFF / X: picks the Switch or X-input identity, or turns the stick off. It sends nothing"),
                      note: "S mode reads as a Switch Pro Controller; X mode is read over Bluetooth only"),
        PlacedControl(id: "stick-knob", kind: .other, center: CGPoint(x: 0.133, y: 0.09), size: 0.055,
                      printed: "DP",
                      readable: .notReported("Control stick knob, LS / DP / RS: sets whether the lever sends the left stick, the D-pad or the right stick. It sends nothing itself")),
        PlacedControl(id: "pair", kind: .other, center: CGPoint(x: 0.203, y: 0.09), size: 0.06,
                      printed: "PAIR", tint: .xboxGreen,
                      readable: .notReported("Pair button: held for 3 seconds it starts Bluetooth or receiver pairing, handled in the stick")),
        PlacedControl(id: "star", kind: .other, center: CGPoint(x: 0.271, y: 0.09), size: 0.06,
                      printed: "\u{2605}", tint: .xboxYellow,
                      readable: .notReported("Star button: sets turbo and button swap, handled in firmware. It never reaches the Mac")),
        PlacedControl(id: "home", kind: .homeButton, center: CGPoint(x: 0.34, y: 0.09), size: 0.06,
                      symbol: "house", tint: .xboxBlue, inputs: .button(10),
                      note: "Also wakes the stick and reconnects it", callout: .above),

        // Function band, second row: player LEDs, the BT / 2.4G slide
        // switch, SELECT and START.
        PlacedControl(id: "player-leds", kind: .light, center: CGPoint(x: 0.064, y: 0.188), size: 0.03,
                      shape: .roundedRect(corner: 0.3),
                      readable: .notReported("Four player LEDs, which also show pairing and battery. The stick drives them itself")),
        PlacedControl(id: "connection-switch", kind: .other, center: CGPoint(x: 0.203, y: 0.189), size: 0.053, height: 0.027,
                      shape: .capsule(angleDegrees: 0), printed: "BT",
                      readable: .notReported("Connection switch, BT / 2.4G: picks Bluetooth or the 2.4G receiver. It sends nothing")),
        PlacedControl(id: "select", kind: .menuButton, center: CGPoint(x: 0.274, y: 0.192), size: 0.055, height: 0.027,
                      shape: .capsule(angleDegrees: 0), printed: "SEL", inputs: .button(8),
                      note: "Printed SELECT; Minus in S mode, View in X mode", callout: .below),
        PlacedControl(id: "start", kind: .menuButton, center: CGPoint(x: 0.337, y: 0.192), size: 0.055, height: 0.027,
                      shape: .capsule(angleDegrees: 0), printed: "STRT", inputs: .button(9),
                      note: "Printed START; Plus in S mode, Menu in X mode", callout: .below),

        // Function band, far right: the two macro buttons.
        PlacedControl(id: "p1", kind: .other, center: CGPoint(x: 0.786, y: 0.157), size: 0.08,
                      printed: "P1",
                      readable: .notReported("Macro button: sends nothing of its own, only the buttons 8BitDo Ultimate Software assigns to it")),
        PlacedControl(id: "p2", kind: .other, center: CGPoint(x: 0.899, y: 0.157), size: 0.08,
                      printed: "P2",
                      readable: .notReported("Macro button: sends nothing of its own, only the buttons 8BitDo Ultimate Software assigns to it")),

        // The lever, in the middle of its round plate. What it sends depends
        // on the stick knob: DP the D-pad (hat 0), LS the left stick (axes 0
        // and 1), RS the right stick (axes 2 and 3). Through GameController
        // a digital lever reads as full-scale axis values.
        PlacedControl(id: "lever", kind: .lever, center: CGPoint(x: 0.203, y: 0.499), size: 0.13,
                      inputs: ControlInputs(axes: [.x(0), .y(1), .x(2), .y(3)], hat: 0),
                      readable: .conditional("The stick knob decides what the lever sends: DP the D-pad (hat 0), LS the left stick (axes 0 and 1), RS the right stick (axes 2 and 3)"),
                      callout: .below),

        // The Vewlix block: the first column sits lower than the other
        // three. Top row, left to right: Y X R L in S mode, X Y RB LB in X
        // mode. Positional face numbering (see the note at the top).
        PlacedControl(id: "top-1", kind: .faceButton, center: CGPoint(x: 0.515, y: 0.445), size: 0.1,
                      inputs: .button(2), note: "Left face button: Y in S mode, X in X mode", callout: .below),
        PlacedControl(id: "top-2", kind: .faceButton, center: CGPoint(x: 0.625, y: 0.377), size: 0.1,
                      inputs: .button(3), note: "Top face button: X in S mode, Y in X mode", callout: .below),
        PlacedControl(id: "top-3", kind: .shoulder, center: CGPoint(x: 0.744, y: 0.377), size: 0.1,
                      inputs: .button(5), note: "R in S mode, RB in X mode", callout: .below),
        PlacedControl(id: "top-4", kind: .shoulder, center: CGPoint(x: 0.861, y: 0.377), size: 0.1,
                      inputs: .button(4), note: "L in S mode, LB in X mode", callout: .below),

        // Bottom row, left to right: B A ZR ZL in S mode, A B RT LT in X
        // mode. The last two are digital buttons the pad reports as
        // triggers, so they read 0 or 1 on axis 5 and 4 and press btn 7
        // and 6.
        PlacedControl(id: "bottom-1", kind: .faceButton, center: CGPoint(x: 0.491, y: 0.633), size: 0.1,
                      inputs: .button(0), note: "Bottom face button: B in S mode, A in X mode", callout: .below),
        PlacedControl(id: "bottom-2", kind: .faceButton, center: CGPoint(x: 0.602, y: 0.568), size: 0.1,
                      inputs: .button(1), note: "Right face button: A in S mode, B in X mode", callout: .below),
        PlacedControl(id: "bottom-3", kind: .trigger(.digital), center: CGPoint(x: 0.721, y: 0.568), size: 0.1,
                      inputs: .trigger(axis: 5, digital: 7),
                      note: "ZR in S mode, RT in X mode. A digital button: reads all or nothing", callout: .below),
        PlacedControl(id: "bottom-4", kind: .trigger(.digital), center: CGPoint(x: 0.839, y: 0.568), size: 0.1,
                      inputs: .trigger(axis: 4, digital: 6),
                      note: "ZL in S mode, LT in X mode. A digital button: reads all or nothing", callout: .below),
    ]
}
