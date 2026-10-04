import Foundation
import CoreGraphics

extension ControllerLayout {
    /// Xbox Wireless Controller (Series X|S, model 1914), read through
    /// GameController as a GCXboxGamepad. About 153 mm wide and 104 mm from
    /// the top edge to the grip bottoms. Offset sticks: left stick high on
    /// the left, ABXY high on the right, the hybrid D-pad and the right stick
    /// low toward the center. View, Share and Menu sit under the Xbox button,
    /// Share centered and a little lower. Nothing is on the back but the AA
    /// battery door, so there is no back strip.
    ///
    /// Inputs (GameControllerService.readControllerState): A B X Y btn 0 to 3,
    /// LB RB btn 4 and 5, LT RT axis 4 and 5 with digital copies btn 6 and 7,
    /// View (buttonOptions) btn 8, Menu btn 9, Xbox (buttonHome) btn 10, stick
    /// clicks btn 11 and 12, sticks axis 0/1 and 2/3 (down positive), D-pad
    /// hat 0, Share ("Button Share" in knownButtonMap) btn 14. The raw HID
    /// fallback (only when GameController never lists the pad) uses the
    /// bundled SDL rows, which put every control on the same indices; Share
    /// lands on 14 only where the row names it as misc1.
    static let xboxSeries = ControllerLayout(
        id: .xboxSeries,
        displayName: "Xbox Wireless Controller (Series X|S)",
        maker: .microsoft,
        family: .xbox,
        modelNames: ButtonNames.ModelNames(absent: [13, 15, 16, 17, 18, 19, 20, 21]),
        aspect: 1.47,
        topStrip: 0.22,
        backStrip: 0,
        silhouette: Silhouette(front: Silhouette.symmetric(xboxSeriesFrontLeft),
                               top: Silhouette.symmetric(xboxSeriesTopLeft)),
        controls: xboxSeriesControls,
        // Share is what tells a Series pad from an Xbox One pad on the same
        // GameController profile; the Elite Series 2 has paddles and no Share.
        // Raw: 0x0B12 is the Series pad on USB, 0x0B13 on Bluetooth LE.
        // 0x0B20 is the Xbox One S pad on its BLE firmware, so it is not here.
        match: [
            [.brand(.xbox), .gcHasElement("Button Share"), .gcLacksElement("Paddle 1"), .gcLacksElement("Button Paddle 1")],
            [.vidPid(vendor: 0x045E, products: [0x0B12, 0x0B13])],
        ],
        matchPriority: 10,
        approximate: true,
        sources: [
            "xbox.com Xbox Wireless Controller product page and support article on pairing (pair button on the top edge, left of the USB-C port)",
            "Wikipedia: Xbox Wireless Controller (153 x 102 to 104 x 61 mm)",
            "dimensiva.com Xbox Series X Controller dimensions",
            "SDL src/joystick/usb_ids.h (0x0B12 Series USB, 0x0B13 Series BLE, 0x0B20 One S BLE)",
            "SDL gamecontrollerdb Mac rows for 045E:0B13 (bundled in SDLGameControllerDBData.swift)",
        ]
    )

    /// The front outline's left half: a nearly straight top edge with a slight
    /// dip at the center, round shoulders where the bumpers wrap, a gentle
    /// side bulge, thick grips that hang down and slightly out, and a wide
    /// shallow arch between them (the 3.5 mm jack sits at its center).
    static let xboxSeriesFrontLeft: [PathOp] = [
        .move(0.5, 0.035),
        .curve(0.22, 0.02, c1x: 0.40, c1y: 0.035, c2x: 0.30, c2y: 0.015),
        .curve(0.03, 0.2, c1x: 0.11, c1y: 0.025, c2x: 0.045, c2y: 0.09),
        .curve(0.035, 0.62, c1x: 0.012, c1y: 0.33, c2x: 0.015, c2y: 0.5),
        .curve(0.10, 0.96, c1x: 0.05, c1y: 0.76, c2x: 0.06, c2y: 0.9),
        .curve(0.27, 0.93, c1x: 0.15, c1y: 1.0, c2x: 0.24, c2y: 0.99),
        .curve(0.36, 0.765, c1x: 0.30, c1y: 0.86, c2x: 0.32, c2y: 0.79),
        .curve(0.5, 0.725, c1x: 0.40, c1y: 0.735, c2x: 0.45, c2y: 0.725),
    ]

    /// The shoulder seen from above, left half: the rear edge recessed at the
    /// center around the USB-C port, the triggers' housings behind the
    /// bumpers, and the rounded corners the bumpers wrap.
    static let xboxSeriesTopLeft: [PathOp] = [
        .move(0.5, 0.2),
        .curve(0.32, 0.1, c1x: 0.42, c1y: 0.2, c2x: 0.37, c2y: 0.1),
        .curve(0.12, 0.06, c1x: 0.25, c1y: 0.06, c2x: 0.18, c2y: 0.04),
        .curve(0.02, 0.6, c1x: 0.04, c1y: 0.1, c2x: 0.01, c2y: 0.35),
        .curve(0.1, 0.97, c1x: 0.03, c1y: 0.85, c2x: 0.06, c2y: 0.97),
        .line(0.5, 0.97),
    ]

    static let xboxSeriesControls: [PlacedControl] = [
        // Top: the impulse triggers behind, the bumpers wrapping the front
        // corners, the pair button and USB-C port at the center of the edge.
        PlacedControl(id: "lt", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.22, y: 0.2164), size: 0.15, height: 0.13,
                      shape: .roundedRect(corner: 0.35), inputs: .trigger(axis: 4, digital: 6), callout: .above),
        PlacedControl(id: "rt", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.78, y: 0.2164), size: 0.15, height: 0.13,
                      shape: .roundedRect(corner: 0.35), inputs: .trigger(axis: 5, digital: 7), callout: .above),
        PlacedControl(id: "lb", kind: .shoulder, face: .top, center: CGPoint(x: 0.2, y: 0.74), size: 0.21, height: 0.045,
                      shape: .capsule(angleDegrees: -6), inputs: .button(4), callout: .below),
        PlacedControl(id: "rb", kind: .shoulder, face: .top, center: CGPoint(x: 0.8, y: 0.74), size: 0.21, height: 0.045,
                      shape: .capsule(angleDegrees: 6), inputs: .button(5), callout: .below),
        PlacedControl(id: "pair", kind: .menuButton, face: .top, center: CGPoint(x: 0.44, y: 0.36), size: 0.026,
                      readable: .notReported("The pair button is handled by the controller's radio for pairing; macOS never reports it"),
                      callout: .below),
        PlacedControl(id: "usb", kind: .port, face: .top, center: CGPoint(x: 0.5, y: 0.36), size: 0.055, height: 0.02,
                      shape: .roundedRect(corner: 0.5), note: "USB-C port for charging and wired play", callout: .below),

        // Front, upper band: the Xbox button near the top edge, View and
        // Menu either side below it, Share centered between and lower.
        PlacedControl(id: "xbox", kind: .homeButton, center: CGPoint(x: 0.5, y: 0.18), size: 0.09,
                      symbol: "logo.xbox", inputs: .button(10),
                      note: "Its white light is not controllable from the Mac. InputConfig turns off the system gesture so presses reach the app",
                      callout: .above),
        PlacedControl(id: "view", kind: .menuButton, center: CGPoint(x: 0.42, y: 0.355), size: 0.045,
                      symbol: "rectangle.on.rectangle", inputs: .button(8), callout: .above),
        PlacedControl(id: "menu", kind: .menuButton, center: CGPoint(x: 0.58, y: 0.355), size: 0.045,
                      symbol: "line.3.horizontal", inputs: .button(9), callout: .above),
        PlacedControl(id: "share", kind: .menuButton, center: CGPoint(x: 0.5, y: 0.43), size: 0.05, height: 0.03,
                      shape: .capsule(angleDegrees: 0), symbol: "square.and.arrow.up", inputs: .button(14),
                      note: "Read through GameController. On the raw Bluetooth fallback only firmware rows that name it reach btn 14",
                      callout: .below),

        // Left wing: the stick high on the left.
        PlacedControl(id: "lstick", kind: .stick, center: CGPoint(x: 0.255, y: 0.36), size: 0.15,
                      inputs: .stick(x: 0, y: 1, press: 11), callout: .below),

        // Right wing: ABXY in Xbox colors.
        PlacedControl(id: "y", kind: .faceButton, center: CGPoint(x: 0.745, y: 0.275), size: 0.062, printed: "Y", tint: .xboxYellow,
                      inputs: .button(3), callout: .above),
        PlacedControl(id: "x", kind: .faceButton, center: CGPoint(x: 0.688, y: 0.36), size: 0.062, printed: "X", tint: .xboxBlue,
                      inputs: .button(2), callout: .left),
        PlacedControl(id: "b", kind: .faceButton, center: CGPoint(x: 0.802, y: 0.36), size: 0.062, printed: "B", tint: .xboxRed,
                      inputs: .button(1), callout: .right),
        PlacedControl(id: "a", kind: .faceButton, center: CGPoint(x: 0.745, y: 0.445), size: 0.062, printed: "A", tint: .xboxGreen,
                      inputs: .button(0), callout: .below),

        // Lower center: the faceted hybrid D-pad and the right stick.
        PlacedControl(id: "dpad", kind: .dpad, center: CGPoint(x: 0.37, y: 0.605), size: 0.15, shape: .hybridDish,
                      inputs: .hat(0), callout: .below),
        PlacedControl(id: "rstick", kind: .stick, center: CGPoint(x: 0.63, y: 0.605), size: 0.15,
                      inputs: .stick(x: 2, y: 3, press: 12), callout: .below),
    ]
}
