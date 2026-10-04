import Foundation
import CoreGraphics

extension ControllerLayout {
    /// 8BitDo Micro (72 x 40.7 x 14.1 mm, 2DC8:9020): a flat pocket pad with
    /// no grips and no sticks. D-pad on the left, a Nintendo-order A/B/X/Y
    /// diamond on the right, Minus, Plus, Star and Home in the middle, and
    /// L, L2, R2, R side by side along the top edge with USB-C between them.
    /// The S/D/K mode switch and the Pair button sit on the bottom edge.
    ///
    /// Recognized in D mode only, where RawHIDGamepadService reads it through
    /// the bundled SDL macOS row (SDLGameControllerDBData, "8BitDo Micro").
    /// That row numbers the face buttons by position, which is also the
    /// POSITIONAL scheme the GameController path uses for Nintendo-style pads:
    /// btn 0 the bottom button (B), 1 the right (A), 2 the left (Y), 3 the
    /// top (X). In S mode the Micro claims to be a Switch Pro Controller and
    /// is drawn as one; in K mode it is a Bluetooth keyboard.
    ///
    /// Positions are measured from 8BitDo's straight-on product renders and
    /// scaled to the published 72 x 40.7 x 14.1 mm.
    static let eightBitDoMicro = ControllerLayout(
        id: .eightBitDoMicro,
        displayName: "8BitDo Micro",
        maker: .eightBitDo,
        family: .nintendo,
        modelNames: ButtonNames.ModelNames(renamed: [6: "L2", 7: "R2", 14: "Star"],
                                           short: [6: "L2", 7: "R2"],
                                           absent: [11, 12, 13, 15, 16, 17]),
        aspect: 72.0 / 40.7,
        topStrip: 0.2,
        backStrip: 0,
        silhouette: Silhouette(front: eightBitDoMicroFront, top: eightBitDoMicroTop),
        controls: eightBitDoMicroControls,
        offBody: [
            OffBodyInput(serialized: "btn 24",
                         reason: "Probable digital copy of L2: the report's L2 bit (SDL b8), which the macOS row leaves out, lands on an extra slot. L2 already reads as axis 4 and btn 6", copy: true),
            OffBodyInput(serialized: "btn 25",
                         reason: "Probable digital copy of R2: the report's R2 bit (SDL b9), which the macOS row leaves out, lands on an extra slot. R2 already reads as axis 5 and btn 7", copy: true),
        ],
        // D mode reports 2DC8:9020 as "8BitDo Micro gamepad" over USB and
        // Bluetooth alike. The name rule catches a firmware that changes the
        // product ID. A GameController pad has no vendor ID in the match
        // facts, so neither rule can catch a Switch Pro Controller.
        match: [
            [.vidPid(vendor: 0x2DC8, products: [0x9020])],
            [.vendor(0x2DC8), .gcProductCategoryContains("Micro")],
            // Through GameController the USB IDs are not known; its name is.
            [.gcVendorNameContains("8BitDo Micro")],
        ],
        matchPriority: 20,
        readability: .partial("Read in D mode. Star is the controller's own turbo key there and is never reported; S mode reads as a Switch Pro Controller and K mode as a keyboard"),
        approximate: false,
        sources: [
            "8bitdo.com/micro (72 x 40.7 x 14.1 mm, 24.8 g, 16 buttons; front, top edge and bottom edge product renders)",
            "manual.8bitdo.com/micro (line drawings of the front and the bottom edge: S/D/K switch, Pair button, power/status LED)",
            "support.8bitdo.com/faq/micro.html (Star is the turbo key in D mode; Minus + D-pad for 5 s picks D-pad, left stick or right stick)",
            "SDL gamecontrollerdb.txt 8BitDo Micro rows (macOS: triggers on a4/a5; Linux and Windows: triggers on b8/b9)",
        ]
    )

    /// A rounded rectangle whose corners are circular on a face that is not
    /// square: rx and ry are the corner radius as fractions of the face's
    /// width and height.
    private static func eightBitDoMicroRoundedRect(rx: CGFloat, ry: CGFloat, insetX ix: CGFloat, insetY iy: CGFloat) -> [PathOp] {
        let k: CGFloat = 0.5523
        let a = ix, t = iy, u = 1 - iy
        // The left half; symmetric() mirrors it around x 0.5.
        return Silhouette.symmetric([
            .move(0.5, t),
            .line(a + rx, t),
            .curve(a, t + ry, c1x: a + rx * (1 - k), c1y: t, c2x: a, c2y: t + ry * (1 - k)),
            .line(a, u - ry),
            .curve(a + rx, u, c1x: a, c1y: u - ry * (1 - k), c2x: a + rx * (1 - k), c2y: u),
            .line(0.5, u),
        ])
    }

    /// The front: a flat slab with large, nearly circular corners (about
    /// 10 mm on a 72 mm body) and straight sides.
    static let eightBitDoMicroFront: [PathOp] =
        eightBitDoMicroRoundedRect(rx: 0.14, ry: 0.25, insetX: 0.01, insetY: 0.01)

    /// The top edge seen from above: a 14 mm thick bar with fully rounded ends.
    static let eightBitDoMicroTop: [PathOp] =
        eightBitDoMicroRoundedRect(rx: 0.07, ry: 0.36, insetX: 0.01, insetY: 0.04)

    static let eightBitDoMicroControls: [PlacedControl] = [
        // Top edge, left to right as held: L wraps the left corner, L2 sits
        // just inboard, USB-C in the middle, then R2 and R. All four are
        // digital. L2 and R2 read 0 or 1 on axis 4 and 5, and the decoder
        // presses btn 6 and 7 with them (SDLGameControllerDB digitalButton).
        PlacedControl(id: "l", kind: .shoulder, face: .top, center: CGPoint(x: 0.142, y: 0.5), size: 0.25, height: 0.08,
                      shape: .roundedRect(corner: 0.3), inputs: .button(4), callout: .above),
        PlacedControl(id: "l2", kind: .trigger(.digital), face: .top, center: CGPoint(x: 0.317, y: 0.5), size: 0.075, height: 0.08,
                      shape: .roundedRect(corner: 0.3), printed: "L2", inputs: .trigger(axis: 4, digital: 6),
                      note: "A digital button: axis 4 jumps from 0 to full, with btn 6", callout: .below),
        PlacedControl(id: "usb-c", kind: .port, face: .top, center: CGPoint(x: 0.5, y: 0.5), size: 0.124, height: 0.04,
                      shape: .roundedRect(corner: 0.5), note: "USB-C for charging and wired play"),
        PlacedControl(id: "r2", kind: .trigger(.digital), face: .top, center: CGPoint(x: 0.683, y: 0.5), size: 0.075, height: 0.08,
                      shape: .roundedRect(corner: 0.3), printed: "R2", inputs: .trigger(axis: 5, digital: 7),
                      note: "A digital button: axis 5 jumps from 0 to full, with btn 7", callout: .below),
        PlacedControl(id: "r", kind: .shoulder, face: .top, center: CGPoint(x: 0.858, y: 0.5), size: 0.25, height: 0.08,
                      shape: .roundedRect(corner: 0.3), inputs: .button(5), callout: .above),

        // Front, left: the D-pad. Hold Minus with D-pad left or right for
        // 5 s and it reports as the left stick (axis 0 and 1) or the right
        // stick (axis 2 and 3) instead of the hat; Minus with up restores it.
        PlacedControl(id: "dpad", kind: .dpad, center: CGPoint(x: 0.236, y: 0.497), size: 0.27, shape: .crossPad,
                      inputs: ControlInputs(axes: [.x(0), .y(1), .x(2), .y(3)], hat: 0),
                      note: "Hat 0. In stick mode (Minus + D-pad left or right for 5 s) it moves axis 0 and 1 or 2 and 3 instead",
                      callout: .below),

        // Front, center: Minus and Plus with the status LED between them,
        // Star and Home lower down.
        PlacedControl(id: "minus", kind: .menuButton, center: CGPoint(x: 0.398, y: 0.279), size: 0.066,
                      symbol: "minus", inputs: .button(8), callout: .above),
        PlacedControl(id: "led", kind: .light, center: CGPoint(x: 0.499, y: 0.279), size: 0.016,
                      readable: .notReported("The power and status LED is driven by the controller; the Mac neither reads nor sets it")),
        PlacedControl(id: "plus", kind: .menuButton, center: CGPoint(x: 0.601, y: 0.279), size: 0.066,
                      symbol: "plus", inputs: .button(9), callout: .above),
        PlacedControl(id: "star", kind: .menuButton, center: CGPoint(x: 0.437, y: 0.702), size: 0.086,
                      symbol: "star.fill", inputs: .button(14), pathInputs: [.rawSDL: .none],
                      readable: .conditional("S mode only, where GameController reports it as Capture (btn 14). In D mode it is the controller's turbo key and sends nothing"),
                      note: "Turbo: hold a button, then press Star", callout: .below),
        PlacedControl(id: "home", kind: .homeButton, center: CGPoint(x: 0.562, y: 0.702), size: 0.086,
                      symbol: "house", inputs: .button(10),
                      note: "Printed with the 8BitDo pixel heart. Press to power on, hold 3 s to power off", callout: .below),

        // Front, right: the A/B/X/Y diamond, Nintendo order. Positional
        // numbering (see the note at the top).
        PlacedControl(id: "x", kind: .faceButton, center: CGPoint(x: 0.763, y: 0.306), size: 0.102,
                      printed: "X", inputs: .button(3), note: "Top button", callout: .above),
        PlacedControl(id: "y", kind: .faceButton, center: CGPoint(x: 0.661, y: 0.494), size: 0.102,
                      printed: "Y", inputs: .button(2), note: "Left button", callout: .left),
        PlacedControl(id: "a", kind: .faceButton, center: CGPoint(x: 0.869, y: 0.494), size: 0.102,
                      printed: "A", inputs: .button(1), note: "Right button", callout: .right),
        PlacedControl(id: "b", kind: .faceButton, center: CGPoint(x: 0.763, y: 0.687), size: 0.102,
                      printed: "B", inputs: .button(0), note: "Bottom button", callout: .below),

        // Bottom edge (the edge nearest the player), drawn at the front's
        // lower rim: the S/D/K mode slider in the middle, Pair to its right.
        PlacedControl(id: "mode-switch", kind: .other, center: CGPoint(x: 0.5, y: 0.962), size: 0.075, height: 0.03,
                      shape: .capsule(angleDegrees: 0), printed: "SDK",
                      readable: .notReported("The S/D/K slider picks what the controller pretends to be: S a Switch Pro Controller, D this HID gamepad, K a keyboard. It is never an input"),
                      note: "On the bottom edge"),
        PlacedControl(id: "pair", kind: .other, center: CGPoint(x: 0.66, y: 0.962), size: 0.04,
                      readable: .notReported("Hold Pair for 1 s to start Bluetooth pairing; the controller handles it itself"),
                      note: "On the bottom edge"),
    ]
}
