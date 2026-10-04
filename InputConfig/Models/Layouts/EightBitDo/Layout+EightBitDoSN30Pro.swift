import Foundation
import CoreGraphics

extension ControllerLayout {
    /// 8BitDo SN30 Pro (the original, without the plus), 144 x 63.5 x 33 mm:
    /// a Super Nintendo dog bone with no grips. Read through GameController
    /// in its macOS mode (START + A), or raw through the bundled SDL rows
    /// (2DC8:6001 wired, 2DC8:6101 over Bluetooth) when GameController does
    /// not list it.
    ///
    /// Face buttons are numbered by position, as on the Pro 2: btn 0 the B
    /// (bottom), 1 the A (right), 2 the Y (left), 3 the X (top). The SDL rows
    /// number them that way (SDL a is the bottom button), and SDL's own
    /// GameController backend treats an 8BitDo's buttonA as the bottom
    /// button; whether Apple numbers this pad by position or by the printed
    /// letter is not confirmed on hardware.
    ///
    /// L2 and R2 are digital. GameController reads them as 0 or 1 into axis
    /// 4 and 5 and btn 6 and 7; the SDL rows map them to btn 6 and 7 only.
    ///
    /// The four mode LEDs sit on the bottom edge (nearest the player), which
    /// no face draws; they are not reported to the Mac anyway.
    static let eightBitDoSN30Pro = ControllerLayout(
        id: .eightBitDoSN30Pro,
        displayName: "8BitDo SN30 Pro",
        maker: .eightBitDo,
        family: nil,
        aspect: 144.0 / 63.5,
        topStrip: 0.2,
        backStrip: 0,
        silhouette: Silhouette(front: eightBitDoSN30ProFront, top: eightBitDoSN30ProTop),
        controls: eightBitDoSN30ProControls,
        // GameController calls it "8Bitdo SN30 Pro" or "8BitDo SN30 Pro".
        // That text is also inside "8BitDo SN30 Pro+", and no rule can say
        // "does not contain", so this layout sits below the Pro 2 / SN30 Pro+
        // layout's priority and the Plus resolves there. Read raw, it is
        // matched by its own USB IDs (the Plus is 6002 and 6102).
        match: [
            [.brand(.eightBitDo), .gcVendorNameContains("SN30 Pro")],
            [.vidPid(vendor: 0x2DC8, products: [0x6001, 0x6101])],
        ],
        matchPriority: 4,
        approximate: true,
        sources: [
            "8bitdo.com SN30 Pro product page (144 x 63.5 x 33 mm, Home and Star buttons, Switch, X-input and D-input modes)",
            "8BitDo SN30 Pro instruction manual (START + A for macOS mode, STAR for turbo and Switch screenshot, HOME LED, PAIR, POWER LED)",
            "hackinformer.com SN30/SF30 Pro review (Star under the D-pad, Home under the face buttons, sticks below both, Select and Start shifted up; L, L2, R, R2 on top with PAIR, USB-C and an LED between them; four LEDs on the bottom edge)",
            "SDL gamecontrollerdb.txt macOS rows 2DC8:6001 and 2DC8:6101 (positional face buttons, digital L2/R2 on b8/b9, guide:b2 only on 6101)",
        ]
    )

    /// The front outline: two round lobes the full height of the pad, joined
    /// by a slightly narrower middle, as on the Super Nintendo controller.
    static let eightBitDoSN30ProFront: [PathOp] = Silhouette.symmetric([
        .move(0.5, 0.035),
        .curve(0.22, 0.008, c1x: 0.4, c1y: 0.035, c2x: 0.3, c2y: 0.008),
        .curve(0.008, 0.5, c1x: 0.103, c1y: 0.008, c2x: 0.008, c2y: 0.228),
        .curve(0.22, 0.992, c1x: 0.008, c1y: 0.772, c2x: 0.103, c2y: 0.992),
        .curve(0.5, 0.955, c1x: 0.3, c1y: 0.992, c2x: 0.4, c2y: 0.955),
    ])

    /// The top edge seen from above: about 25 mm deep with round ends.
    static let eightBitDoSN30ProTop: [PathOp] = [
        .move(0.08, 0.06), .line(0.92, 0.06), .quad(0.98, 0.36, cx: 0.98, cy: 0.06), .line(0.98, 0.64),
        .quad(0.92, 0.94, cx: 0.98, cy: 0.94), .line(0.08, 0.94), .quad(0.02, 0.64, cx: 0.02, cy: 0.94),
        .line(0.02, 0.36), .quad(0.08, 0.06, cx: 0.02, cy: 0.06), .close,
    ]

    static let eightBitDoSN30ProControls: [PlacedControl] = [
        // Top: L and R wrap the front lip of each lobe, the smaller digital
        // L2 and R2 are stacked behind them.
        PlacedControl(id: "l2", kind: .trigger(.digital), face: .top, center: CGPoint(x: 0.18, y: 0.1375), size: 0.15, height: 0.13,
                      shape: .roundedRect(corner: 0.35), printed: "L2", inputs: .trigger(axis: 4, digital: 6),
                      pathInputs: [.rawSDL: .button(6)],
                      note: "Digital: reads all or nothing. A raw SDL read gives btn 6 only", callout: .above),
        PlacedControl(id: "r2", kind: .trigger(.digital), face: .top, center: CGPoint(x: 0.82, y: 0.1375), size: 0.15, height: 0.13,
                      shape: .roundedRect(corner: 0.35), printed: "R2", inputs: .trigger(axis: 5, digital: 7),
                      pathInputs: [.rawSDL: .button(7)],
                      note: "Digital: reads all or nothing. A raw SDL read gives btn 7 only", callout: .above),
        PlacedControl(id: "l", kind: .shoulder, face: .top, center: CGPoint(x: 0.17, y: 0.75), size: 0.2, height: 0.045,
                      shape: .capsule(angleDegrees: 0), printed: "L", inputs: .button(4), callout: .below),
        PlacedControl(id: "r", kind: .shoulder, face: .top, center: CGPoint(x: 0.83, y: 0.75), size: 0.2, height: 0.045,
                      shape: .capsule(angleDegrees: 0), printed: "R", inputs: .button(5), callout: .below),
        // Top center, between the shoulders: PAIR, the USB-C port, and the
        // power LED.
        PlacedControl(id: "pair", kind: .other, face: .top, center: CGPoint(x: 0.41, y: 0.5), size: 0.035, height: 0.025,
                      shape: .roundedRect(corner: 0.45), printed: "PAIR",
                      readable: .notReported("The controller handles PAIR itself for Bluetooth pairing; it never reaches the Mac")),
        PlacedControl(id: "usb-c", kind: .port, face: .top, center: CGPoint(x: 0.5, y: 0.5), size: 0.065, height: 0.022,
                      shape: .roundedRect(corner: 0.45), note: "USB-C for charging and wired play"),
        PlacedControl(id: "power-led", kind: .light, face: .top, center: CGPoint(x: 0.58, y: 0.5), size: 0.015,
                      readable: .notReported("The power LED shows battery and charging; InputConfig neither reads nor sets it")),

        // Front, left lobe: the D-pad high, the Star button under it.
        PlacedControl(id: "dpad", kind: .dpad, center: CGPoint(x: 0.22, y: 0.37), size: 0.15, shape: .crossPad,
                      inputs: .hat(0), callout: .below),
        PlacedControl(id: "star", kind: .menuButton, center: CGPoint(x: 0.225, y: 0.775), size: 0.042,
                      symbol: "star",
                      readable: .notReported("Star sets turbo in the controller's firmware (Screenshot in Switch mode); it is not reported to the Mac"),
                      callout: .below),

        // Front, right lobe: the A/B/X/Y diamond, printed letters, one color,
        // numbered by position (see the note at the top).
        PlacedControl(id: "x", kind: .faceButton, center: CGPoint(x: 0.778, y: 0.205), size: 0.066,
                      printed: "X", inputs: .button(3),
                      note: "Top button", callout: .above),
        PlacedControl(id: "y", kind: .faceButton, center: CGPoint(x: 0.701, y: 0.378), size: 0.066,
                      printed: "Y", inputs: .button(2),
                      note: "Left button", callout: .left),
        PlacedControl(id: "a", kind: .faceButton, center: CGPoint(x: 0.855, y: 0.378), size: 0.066,
                      printed: "A", inputs: .button(1),
                      note: "Right button", callout: .right),
        PlacedControl(id: "b", kind: .faceButton, center: CGPoint(x: 0.778, y: 0.551), size: 0.066,
                      printed: "B", inputs: .button(0),
                      note: "Bottom button", callout: .below),
        PlacedControl(id: "home", kind: .homeButton, center: CGPoint(x: 0.775, y: 0.775), size: 0.048,
                      symbol: "house", inputs: .button(10), pathInputs: [.rawSDL: ControlInputs(buttons: [10, 22])],
                      note: "Its LED blinks when turbo is set. Raw on the wired 6001 row, which names no guide, Home lands on the first extra slot, btn 22; the Bluetooth 6101 row reads it as btn 10",
                      callout: .below),

        // Center: Select and Start slanted as on the Super Nintendo pad,
        // shifted up to make room for the sticks below them.
        PlacedControl(id: "select", kind: .menuButton, center: CGPoint(x: 0.43, y: 0.36), size: 0.07, height: 0.026,
                      shape: .capsule(angleDegrees: -35), printed: "SEL", inputs: .button(8), callout: .above),
        PlacedControl(id: "start", kind: .menuButton, center: CGPoint(x: 0.57, y: 0.36), size: 0.07, height: 0.026,
                      shape: .capsule(angleDegrees: -35), printed: "STA", inputs: .button(9), callout: .above),

        // Lower center: the two small sticks side by side.
        PlacedControl(id: "lstick", kind: .stick, center: CGPoint(x: 0.37, y: 0.7), size: 0.105,
                      inputs: .stick(x: 0, y: 1, press: 11), callout: .below),
        PlacedControl(id: "rstick", kind: .stick, center: CGPoint(x: 0.63, y: 0.7), size: 0.105,
                      inputs: .stick(x: 2, y: 3, press: 12), callout: .below),
    ]
}
