import Foundation
import CoreGraphics

extension ControllerLayout {
    /// 8BitDo Lite 2 (2DC8:5112) and the original 8BitDo Lite (2020): the
    /// same flat, gripless Switch Lite style slab, 120 x 66 mm, with the left
    /// thumb control high on the left, the direction pad low and inboard, the
    /// A/B/X/Y diamond high on the right, and the right thumb control low and
    /// inboard. Minus, the mode switch and Plus sit in a row near the top
    /// edge, Star and Home in the two lower corners. L and R wrap the top
    /// corners; ZL and ZR sit behind them.
    ///
    /// Variants: the Lite 2 has two real thumbsticks and a cross D-pad; the
    /// original Lite has two cross pads in the stick places (each sends the
    /// stick axes and clicks as L3 or R3) and a four-button direction pad.
    /// The canvas draws one control set for both, sized for the Lite 2.
    ///
    /// How each one is read today:
    /// - Switch mode (S): the pad says it is a Nintendo Pro Controller
    ///   (057E:2009), GameController lists it, and the Switch Pro layout is
    ///   drawn instead of this one. That read is positional (btn 0 bottom,
    ///   1 right, 2 left, 3 top) and gives Star as Capture on btn 14.
    /// - Lite 2 in D mode: RawHIDGamepadService reads it through the
    ///   bundled SDL macOS rows (SDLGameControllerDBData.swift:40-41). Those
    ///   rows are positional too (a south, b east, x west, y north), so
    ///   `inputs` below is that read: B 0, A 1, Y 2, X 3, L 4, R 5, ZL axis 4
    ///   plus btn 6, ZR axis 5 plus btn 7, Minus 8, Plus 9, Home 10, stick
    ///   clicks 11 and 12, the D-pad on hat 0.
    /// - Original Lite in X mode over Bluetooth ("8BitDo Lite gamepad"): no
    ///   macOS SDL row exists, so the descriptor parser numbers its buttons
    ///   in report bit order. `pathInputs[.rawDescriptor]` assumes 8BitDo's
    ///   usual D-input bit order (the one SDL's Windows row for the Lite 2
    ///   spells out: A b0, B b1, X b3, Y b4, L b6, R b7, ZL b8, ZR b9,
    ///   Minus b10, Plus b11, Home b12, L3 b13, R3 b14). Not confirmed on
    ///   hardware.
    ///
    /// The Lite SE has the same shell but a different face (every shoulder
    /// button and separate L3/R3 buttons on the front), so it has its own
    /// layout below, `eightBitDoLiteSE`.
    static let eightBitDoLite = ControllerLayout(
        id: .eightBitDoLite,
        displayName: "8BitDo Lite 2 / Lite",
        maker: .eightBitDo,
        family: .nintendo,
        modelNames: ButtonNames.ModelNames(renamed: [14: "Star"], short: [14: "Star"], absent: [13, 15, 16, 17]),
        aspect: 120.0 / 65.95,
        topStrip: 0.2,
        backStrip: 0,
        silhouette: Silhouette(front: eightBitDoLiteFront, top: eightBitDoLiteTop),
        controls: eightBitDoLiteControls,
        variants: [
            LayoutVariant(id: "lite2", displayName: "Lite 2, thumbsticks", isDefault: true),
            LayoutVariant(id: "lite", displayName: "Lite (2020), cross pads as sticks"),
        ],
        // The Lite 2 read raw has its USB IDs; the original Lite is known
        // only by its Bluetooth name. "8BitDo Lite 2" and "8BitDo Lite
        // gamepad" do not occur in "8BitDo Lite SE", and a bare "Lite" is
        // avoided because it also matches "Elite". In Switch mode either pad
        // reports itself as a Pro Controller and matches the Switch Pro.
        offBody: [
            OffBodyInput(serialized: "btn 24", reason: "Probable digital copy of the left trigger: the report's bit b8, which the macOS row leaves out, lands on an extra slot", copy: true),
            OffBodyInput(serialized: "btn 25", reason: "Probable digital copy of the right trigger: the report's bit b9, which the macOS row leaves out, lands on an extra slot", copy: true),
        ],
        match: [
            [.vidPid(vendor: 0x2DC8, products: [0x5112])],
            [.gcProductCategoryContains("8BitDo Lite 2")],
            [.gcProductCategoryContains("8BitDo Lite gamepad")],
            [.gcVendorNameContains("8BitDo Lite 2")],
            [.gcVendorNameContains("8BitDo Lite gamepad")],
        ],
        matchPriority: 10,
        readability: .partial("Star reaches the Mac only in Switch mode; the original Lite is read in descriptor order, which is unconfirmed"),
        approximate: true,
        sources: [
            "8bitdo.com/lite2 (120 x 65.95 x 35.45 mm; S-input and D-input; product photos used for placement)",
            "support.8bitdo.com/faq/lite.html (original Lite: S and X modes, cross pads click as L3/R3, Star is Capture on Switch and Turbo elsewhere)",
            "tech-fairy.com 8BitDo Lite review photos (original Lite face layout)",
            "SDL gamecontrollerdb.txt rows for 2DC8:5112 and 2DC8:5111 (macOS and Windows)",
        ],
        // The Star rename and the missing stick clicks fit GameController and
        // the SDL rows; read from the descriptor the clicks are 13 and 14.
        modelNamesPaths: [.gameController, .rawSDL]
    )

    /// A slab with round corners: `rx` and `ry` are the corner radius in
    /// face units across and down, so the corners stay circular on a face
    /// that is wider than tall.
    private static func eightBitDoLiteSlab(rx: CGFloat, ry: CGFloat, insetX ix: CGFloat, insetY iy: CGFloat) -> [PathOp] {
        let l = ix, r = 1 - ix, t = iy, b = 1 - iy
        let k: CGFloat = 0.448   // a quarter circle's control point pull
        return [
            .move(l + rx, t),
            .line(r - rx, t),
            .curve(r, t + ry, c1x: r - rx * k, c1y: t, c2x: r, c2y: t + ry * k),
            .line(r, b - ry),
            .curve(r - rx, b, c1x: r, c1y: b - ry * k, c2x: r - rx * k, c2y: b),
            .line(l + rx, b),
            .curve(l, b - ry, c1x: l + rx * k, c1y: b, c2x: l, c2y: b - ry * k),
            .line(l, t + ry),
            .curve(l + rx, t, c1x: l, c1y: t + ry * k, c2x: l + rx * k, c2y: t),
            .close,
        ]
    }

    /// The face: a gripless rectangle with corners of about 13 mm radius.
    static let eightBitDoLiteFront: [PathOp] = eightBitDoLiteSlab(rx: 0.11, ry: 0.2, insetX: 0.01, insetY: 0.015)
    /// The top edge seen from above: a thin bar with round ends.
    static let eightBitDoLiteTop: [PathOp] = eightBitDoLiteSlab(rx: 0.05, ry: 0.3, insetX: 0.01, insetY: 0.04)

    static let eightBitDoLiteControls: [PlacedControl] = [
        // Top: L and R wrap the front corners; on the Lite 2 the shaped ZL
        // and ZR triggers sit under and behind them. They are digital: the
        // SDL row reads them as axes that jump from 0 to 1.
        PlacedControl(id: "zl", kind: .trigger(.digital), face: .top, center: CGPoint(x: 0.2, y: 0.15), size: 0.15, height: 0.13,
                      shape: .roundedRect(corner: 0.35), inputs: .trigger(axis: 4, digital: 6),
                      pathInputs: [.rawDescriptor: .button(8)],
                      note: "Digital. The original Lite has a small ZL inboard of L on the same edge", callout: .above),
        PlacedControl(id: "zr", kind: .trigger(.digital), face: .top, center: CGPoint(x: 0.8, y: 0.15), size: 0.15, height: 0.13,
                      shape: .roundedRect(corner: 0.35), inputs: .trigger(axis: 5, digital: 7),
                      pathInputs: [.rawDescriptor: .button(9)],
                      note: "Digital. The original Lite has a small ZR inboard of R on the same edge", callout: .above),
        PlacedControl(id: "l", kind: .shoulder, face: .top, center: CGPoint(x: 0.15, y: 0.74), size: 0.2, height: 0.045,
                      shape: .capsule(angleDegrees: 0), inputs: .button(4),
                      pathInputs: [.rawDescriptor: .button(6)], callout: .below),
        PlacedControl(id: "r", kind: .shoulder, face: .top, center: CGPoint(x: 0.85, y: 0.74), size: 0.2, height: 0.045,
                      shape: .capsule(angleDegrees: 0), inputs: .button(5),
                      pathInputs: [.rawDescriptor: .button(7)], callout: .below),
        PlacedControl(id: "usb-c", kind: .port, face: .top, center: CGPoint(x: 0.47, y: 0.5), size: 0.06, height: 0.022,
                      shape: .roundedRect(corner: 0.45), note: "USB-C for charging and wired play"),
        PlacedControl(id: "pair", kind: .other, face: .top, center: CGPoint(x: 0.56, y: 0.5), size: 0.025,
                      readable: .notReported("The pair button starts Bluetooth pairing inside the controller; it never reaches the Mac")),

        // Front, left: the thumbstick (a cross pad on the original Lite)
        // high, the D-pad low and inboard.
        PlacedControl(id: "lstick", kind: .stick, center: CGPoint(x: 0.173, y: 0.37), size: 0.13,
                      inputs: .stick(x: 0, y: 1, press: 11),
                      pathInputs: [.rawDescriptor: .stick(x: 0, y: 1, press: 13)],
                      callout: .below, variants: ["lite2"]),
        PlacedControl(id: "lstick.lite", kind: .stick, center: CGPoint(x: 0.173, y: 0.37), size: 0.165, shape: .crossPad,
                      inputs: .stick(x: 0, y: 1, press: 11),
                      pathInputs: [.rawDescriptor: .stick(x: 0, y: 1, press: 13)],
                      note: "A cross pad that sends the left stick axes and clicks as L3", callout: .below,
                      variants: ["lite"], name: "Left stick"),
        PlacedControl(id: "dpad", kind: .dpad, center: CGPoint(x: 0.34, y: 0.675), size: 0.165, shape: .crossPad,
                      inputs: .hat(0), callout: .below, variants: ["lite2"]),
        PlacedControl(id: "dpad.lite", kind: .dpad, center: CGPoint(x: 0.34, y: 0.675), size: 0.165, shape: .fourButtonPad,
                      inputs: .hat(0), note: "Four separate round buttons", callout: .below, variants: ["lite"], name: "D-pad"),

        // Front, right: A/B/X/Y high, the right thumbstick low and inboard.
        // Positional numbering on every path (see the note at the top).
        PlacedControl(id: "x", kind: .faceButton, center: CGPoint(x: 0.812, y: 0.27), size: 0.058,
                      inputs: .button(3), pathInputs: [.rawDescriptor: .button(3)], note: "Top button", callout: .above),
        PlacedControl(id: "y", kind: .faceButton, center: CGPoint(x: 0.747, y: 0.385), size: 0.058,
                      inputs: .button(2), pathInputs: [.rawDescriptor: .button(4)], note: "Left button", callout: .left),
        PlacedControl(id: "a", kind: .faceButton, center: CGPoint(x: 0.877, y: 0.385), size: 0.058,
                      inputs: .button(1), pathInputs: [.rawDescriptor: .button(0)], note: "Right button", callout: .right),
        PlacedControl(id: "b", kind: .faceButton, center: CGPoint(x: 0.812, y: 0.5), size: 0.058,
                      inputs: .button(0), pathInputs: [.rawDescriptor: .button(1)], note: "Bottom button", callout: .below),
        PlacedControl(id: "rstick", kind: .stick, center: CGPoint(x: 0.65, y: 0.672), size: 0.13,
                      inputs: .stick(x: 2, y: 3, press: 12),
                      pathInputs: [.rawDescriptor: .stick(x: 2, y: 3, press: 14)],
                      callout: .below, variants: ["lite2"]),
        PlacedControl(id: "rstick.lite", kind: .stick, center: CGPoint(x: 0.65, y: 0.672), size: 0.165, shape: .crossPad,
                      inputs: .stick(x: 2, y: 3, press: 12),
                      pathInputs: [.rawDescriptor: .stick(x: 2, y: 3, press: 14)],
                      note: "A cross pad that sends the right stick axes and clicks as R3", callout: .below,
                      variants: ["lite"], name: "Right stick"),

        // Center row near the top edge: Minus, the mode switch, Plus.
        PlacedControl(id: "minus", kind: .menuButton, center: CGPoint(x: 0.34, y: 0.225), size: 0.048,
                      symbol: "minus", inputs: .button(8), pathInputs: [.rawDescriptor: .button(10)], callout: .above),
        PlacedControl(id: "mode", kind: .other, center: CGPoint(x: 0.49, y: 0.225), size: 0.05, height: 0.025,
                      shape: .capsule(angleDegrees: 0),
                      readable: .notReported("The mode switch (S or D on the Lite 2, S or X on the Lite) picks how the pad presents itself; it is not an input"),
                      callout: .above),
        PlacedControl(id: "plus", kind: .menuButton, center: CGPoint(x: 0.652, y: 0.225), size: 0.048,
                      symbol: "plus", inputs: .button(9), pathInputs: [.rawDescriptor: .button(11)], callout: .above),

        // Lower corners: Star on the left, Home on the right.
        PlacedControl(id: "star", kind: .menuButton, center: CGPoint(x: 0.19, y: 0.81), size: 0.042,
                      symbol: "star", inputs: .none, pathInputs: [.gameController: .button(14)],
                      readable: .conditional("Sent only in Switch mode, as Capture on btn 14. In D and X mode it is the turbo key, handled inside the controller"),
                      callout: .below),
        PlacedControl(id: "home", kind: .homeButton, center: CGPoint(x: 0.8, y: 0.8), size: 0.042,
                      symbol: "house", inputs: .button(10), pathInputs: [.rawDescriptor: .button(12)], callout: .below),
    ]

    /// 8BitDo Lite SE (2DC8:5111), 120 x 66 x 26.35 mm: the Lite 2's shell
    /// with every button on the face for players with limited mobility. On
    /// the left, L2 and L sit above and inboard of a diamond of four round
    /// direction buttons; on the right, R2 and R above and inboard of the
    /// A/B/X/Y diamond. Minus, the S/D switch and Plus run along the top,
    /// separate L3 and R3 buttons sit under the logo, the two sticks low in
    /// the middle, Star and Home in the lower corners, and four player
    /// lights between the sticks.
    ///
    /// Read in D mode through the bundled SDL macOS rows
    /// (SDLGameControllerDBData.swift:42-43), the same numbering as the
    /// Lite 2: positional face buttons, L2 on axis 4 plus btn 6, R2 on axis
    /// 5 plus btn 7. In Switch mode it is a Pro Controller to the Mac and the
    /// Switch Pro layout is drawn.
    static let eightBitDoLiteSE = ControllerLayout(
        id: .eightBitDoLiteSE,
        displayName: "8BitDo Lite SE",
        maker: .eightBitDo,
        family: .nintendo,
        modelNames: ButtonNames.ModelNames(renamed: [6: "L2", 7: "R2", 14: "Star"], short: [6: "L2", 7: "R2", 14: "Star"],
                                           absent: [13, 15, 16, 17]),
        aspect: 120.0 / 66.0,
        topStrip: 0.12,
        backStrip: 0,
        silhouette: Silhouette(front: eightBitDoLiteFront, top: eightBitDoLiteTop),
        controls: eightBitDoLiteSEControls,
        offBody: [
            OffBodyInput(serialized: "btn 24", reason: "Probable digital copy of the left trigger: the report's bit b8, which the macOS row leaves out, lands on an extra slot", copy: true),
            OffBodyInput(serialized: "btn 25", reason: "Probable digital copy of the right trigger: the report's bit b9, which the macOS row leaves out, lands on an extra slot", copy: true),
        ],
        match: [
            [.vidPid(vendor: 0x2DC8, products: [0x5111])],
            [.gcProductCategoryContains("8BitDo Lite SE")],
            [.gcVendorNameContains("8BitDo Lite SE")],
        ],
        matchPriority: 11,
        readability: .partial("Star reaches the Mac only in Switch mode, when the pad is drawn as a Pro Controller"),
        approximate: true,
        sources: [
            "8bitdo.com/lite-se (120 x 66 x 26.35 mm; every button on the face; separate L3 and R3; product photos used for placement)",
            "tech-fairy.com 8BitDo Lite SE review",
            "SDL gamecontrollerdb.txt rows for 2DC8:5111",
        ]
    )

    static let eightBitDoLiteSEControls: [PlacedControl] = [
        // Top edge: only the port and the pair button.
        PlacedControl(id: "usb-c", kind: .port, face: .top, center: CGPoint(x: 0.47, y: 0.5), size: 0.06, height: 0.022,
                      shape: .roundedRect(corner: 0.45), note: "USB-C for charging and wired play"),
        PlacedControl(id: "pair", kind: .other, face: .top, center: CGPoint(x: 0.56, y: 0.5), size: 0.025,
                      readable: .notReported("The pair button starts Bluetooth pairing inside the controller; it never reaches the Mac")),

        // Left cluster: L2 and L, then the four direction buttons. The
        // D-pad's arms are drawn at the four buttons' places.
        PlacedControl(id: "zl", kind: .trigger(.digital), center: CGPoint(x: 0.213, y: 0.197), size: 0.058,
                      shape: .circle, printed: "L2", inputs: .trigger(axis: 4, digital: 6),
                      note: "Digital, on the face. Reads as ZL", callout: .above),
        PlacedControl(id: "l", kind: .shoulder, center: CGPoint(x: 0.276, y: 0.313), size: 0.058,
                      shape: .circle, printed: "L", inputs: .button(4), note: "On the face", callout: .right),
        PlacedControl(id: "dpad", kind: .dpad, center: CGPoint(x: 0.145, y: 0.43), size: 0.19, shape: .fourButtonPad,
                      inputs: .hat(0), note: "Four separate round buttons", callout: .below),

        // Center: Minus, the S/D switch, Plus, then L3 and R3 under the logo.
        PlacedControl(id: "minus", kind: .menuButton, center: CGPoint(x: 0.343, y: 0.2), size: 0.05,
                      symbol: "minus", inputs: .button(8), callout: .above),
        PlacedControl(id: "mode", kind: .other, center: CGPoint(x: 0.503, y: 0.2), size: 0.05, height: 0.025,
                      shape: .capsule(angleDegrees: 0),
                      readable: .notReported("The S/D switch picks how the pad presents itself; it is not an input"),
                      callout: .above),
        PlacedControl(id: "plus", kind: .menuButton, center: CGPoint(x: 0.657, y: 0.2), size: 0.05,
                      symbol: "plus", inputs: .button(9), callout: .above),
        // L3 and R3 send the same buttons as the stick clicks. Marked as
        // overlays of the sticks so the shared index is allowed.
        PlacedControl(id: "l3", kind: .menuButton, center: CGPoint(x: 0.432, y: 0.442), size: 0.048,
                      printed: "L3", inputs: .button(11), note: "Same button as pressing the left stick",
                      callout: .below, overlayOf: "lstick"),
        PlacedControl(id: "r3", kind: .menuButton, center: CGPoint(x: 0.567, y: 0.442), size: 0.048,
                      printed: "R3", inputs: .button(12), note: "Same button as pressing the right stick",
                      callout: .below, overlayOf: "rstick"),

        // Right cluster: R2 and R, then A/B/X/Y (positional numbering).
        PlacedControl(id: "zr", kind: .trigger(.digital), center: CGPoint(x: 0.789, y: 0.205), size: 0.058,
                      shape: .circle, printed: "R2", inputs: .trigger(axis: 5, digital: 7),
                      note: "Digital, on the face. Reads as ZR", callout: .above),
        PlacedControl(id: "r", kind: .shoulder, center: CGPoint(x: 0.722, y: 0.317), size: 0.058,
                      shape: .circle, printed: "R", inputs: .button(5), note: "On the face", callout: .left),
        PlacedControl(id: "x", kind: .faceButton, center: CGPoint(x: 0.853, y: 0.323), size: 0.058,
                      inputs: .button(3), note: "Top button", callout: .above),
        PlacedControl(id: "y", kind: .faceButton, center: CGPoint(x: 0.787, y: 0.438), size: 0.058,
                      inputs: .button(2), note: "Left button", callout: .left),
        PlacedControl(id: "a", kind: .faceButton, center: CGPoint(x: 0.917, y: 0.442), size: 0.058,
                      inputs: .button(1), note: "Right button", callout: .right),
        PlacedControl(id: "b", kind: .faceButton, center: CGPoint(x: 0.851, y: 0.558), size: 0.058,
                      inputs: .button(0), note: "Bottom button", callout: .below),

        // Low center: the two sticks, the player lights between them.
        PlacedControl(id: "lstick", kind: .stick, center: CGPoint(x: 0.343, y: 0.687), size: 0.13,
                      inputs: .stick(x: 0, y: 1, press: 11), callout: .below),
        PlacedControl(id: "rstick", kind: .stick, center: CGPoint(x: 0.654, y: 0.69), size: 0.13,
                      inputs: .stick(x: 2, y: 3, press: 12), callout: .below),
        PlacedControl(id: "player-leds", kind: .light, center: CGPoint(x: 0.497, y: 0.872), size: 0.1, height: 0.012,
                      shape: .capsule(angleDegrees: 0),
                      readable: .notReported("The four player lights are set by the controller; InputConfig neither reads nor sets them")),

        // Lower corners: Star on the left, Home on the right.
        PlacedControl(id: "star", kind: .menuButton, center: CGPoint(x: 0.18, y: 0.808), size: 0.05,
                      symbol: "star", inputs: .none, pathInputs: [.gameController: .button(14)],
                      readable: .conditional("Sent only in Switch mode, as Capture on btn 14. In D mode it is the turbo key, handled inside the controller"),
                      callout: .below),
        PlacedControl(id: "home", kind: .homeButton, center: CGPoint(x: 0.815, y: 0.813), size: 0.05,
                      symbol: "house", inputs: .button(10), callout: .below),
    ]
}
