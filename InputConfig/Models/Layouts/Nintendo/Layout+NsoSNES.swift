import Foundation
import CoreGraphics

extension ControllerLayout {
    /// Super Nintendo Entertainment System Controller for Nintendo Switch
    /// (Nintendo Switch Online, 057E:2017), about 144 mm wide and 61 mm tall:
    /// the flat SNES dog-bone with a +Control Pad on the left lobe, A, B, X
    /// and Y on the right lobe, angled SELECT and START pills in the middle,
    /// and L and R on the top corners. The Switch version adds small ZL and
    /// ZR buttons on the top edge inboard of L and R, a USB-C port and
    /// recharge LED on the top edge, and a SYNC button and player LEDs on
    /// the front below SELECT and START. It has no HOME, Capture, sticks,
    /// motion or rumble.
    ///
    /// Read two ways. When GameController lists it (macOS 13 and later list
    /// the Switch Online SNES pad), it is read as a GameController pad; when
    /// it does not, RawHIDGamepadService reads it raw through the bundled SDL
    /// row "NSO SNES Controller" (a:b0, b:b1, x:b2, y:b3, leftshoulder:b4,
    /// rightshoulder:b5, lefttrigger:b6, righttrigger:b15, back:b8,
    /// start:b9, D-pad on hat 0).
    ///
    /// Face buttons use the POSITIONAL numbering: btn 0 the bottom button
    /// (B), 1 the right (A), 2 the left (Y), 3 the top (X). The SDL row
    /// already numbers them by position. The GameController path is being
    /// changed to positional for every Nintendo pad; today it swaps the
    /// letters into place only for the .switchPro and .joyConPair brands
    /// (GameControllerService.faceButtonsByPosition).
    static let nsoSNES = ControllerLayout(
        id: .nsoSNES,
        displayName: "SNES Controller (Switch Online)",
        maker: .nintendo,
        family: .nintendo,
        // SELECT and START are what the pad prints where a Switch pad has
        // Minus and Plus, and it has none of the Switch pads' other buttons.
        modelNames: ButtonNames.ModelNames(renamed: [8: "Select", 9: "Start"],
                                           short: [8: "SEL", 9: "STRT"],
                                           absent: [10, 11, 12, 13, 14, 15, 16, 17]),
        aspect: 144.0 / 61.0,
        topStrip: 0.14,
        backStrip: 0,
        silhouette: Silhouette(front: nsoSNESFront, top: nsoSNESTop),
        controls: nsoSNESControls,
        offBody: nsoSNESOffBody,
        // Raw HID: its USB IDs. GameController: the name says SNES and the
        // brand is the one a listed Switch Online pad gets (.mfiGeneric when
        // its name has no "Nintendo", .switchPro when it does). A raw third
        // party SNES pad ("Tomee SNES Controller") is branded .unknown, so
        // it falls through to the generic SNES layout.
        match: [
            [.vidPid(vendor: 0x057E, products: [0x2017])],
            // Through GameController only under a Switch brand, the pads
            // whose face buttons are read by position as drawn here.
            [.gcVendorNameContains("SNES"), .brand(.switchPro)],
            [.gcProductCategoryContains("SNES"), .brand(.switchPro)],
        ],
        matchPriority: 20,
        readability: .partial("Wired USB-C start-up not sent: InputConfig reads it over Bluetooth only"),
        approximate: true,
        sources: [
            "Nintendo support: Super Nintendo Entertainment System Nintendo Classics controller diagram (a_id 47358): +Control Pad, L, ZL, Recharge LED, USB-C, ZR, R, A/B/X/Y, SELECT, SYNC, Player LED, START",
            "dimensions.com SNES Controller: 144 mm wide, 61 mm tall",
            "9to5toys SNES controller for Switch review: SELECT and START sit right above the new pairing indicator on the front",
            "SDL gamecontrollerdb.txt macOS row 030000007e0500001720000001000000 (NSO SNES Controller), bundled in SDLGameControllerDBData.swift",
            "Product photos of the Switch Online SNES controller for placement",
        ]
    )

    /// The front outline: two round lobes, each a half circle the full
    /// height of the pad, joined by a waist whose top edge dips a little and
    /// whose bottom edge arches up between the grips.
    static let nsoSNESFront: [PathOp] = Silhouette.symmetric([
        .move(0.5, 0.06),
        .curve(0.21, 0.01, c1x: 0.4, c1y: 0.06, c2x: 0.3, c2y: 0.01),
        .curve(0.008, 0.5, c1x: 0.098, c1y: 0.01, c2x: 0.008, c2y: 0.229),
        .curve(0.21, 0.99, c1x: 0.008, c1y: 0.771, c2x: 0.098, c2y: 0.99),
        .curve(0.5, 0.86, c1x: 0.31, c1y: 0.99, c2x: 0.4, c2y: 0.86),
    ])

    /// The top edge from above: full thickness at the lobes, thinner across
    /// the middle on the rear side, the front side nearly straight.
    static let nsoSNESTop: [PathOp] = Silhouette.symmetric([
        .move(0.5, 0.22),
        .curve(0.08, 0.05, c1x: 0.35, c1y: 0.2, c2x: 0.2, c2y: 0.05),
        .curve(0.012, 0.5, c1x: 0.035, c1y: 0.05, c2x: 0.012, c2y: 0.25),
        .curve(0.08, 0.96, c1x: 0.012, c1y: 0.75, c2x: 0.035, c2y: 0.96),
        .curve(0.5, 0.88, c1x: 0.2, c1y: 0.96, c2x: 0.35, c2y: 0.88),
    ])

    static let nsoSNESControls: [PlacedControl] = [
        // Top edge, left to right: L, ZL, recharge LED, USB-C, ZR, R.
        // L and R wrap the top corners; ZL and ZR are the small Switch
        // additions just inboard of them.
        PlacedControl(id: "l", kind: .shoulder, face: .top, center: CGPoint(x: 0.16, y: 0.6), size: 0.19, height: 0.05,
                      shape: .capsule(angleDegrees: 0), inputs: .button(4), callout: .below),
        PlacedControl(id: "zl", kind: .shoulder, face: .top, center: CGPoint(x: 0.3, y: 0.4), size: 0.055, height: 0.03,
                      shape: .roundedRect(corner: 0.35),
                      inputs: ControlInputs(buttons: [6], axes: [.analog(4)]),
                      pathInputs: [.rawSDL: .button(6)],
                      note: "Digital. GameController reads it as the left trigger (btn 6 and axis 4 at 0 or 1); the raw SDL read gives btn 6 only",
                      callout: .above),
        PlacedControl(id: "recharge-led", kind: .light, face: .top, center: CGPoint(x: 0.44, y: 0.45), size: 0.014,
                      readable: .notReported("The recharge LED is driven by the controller while charging; it is not an input")),
        PlacedControl(id: "usb-c", kind: .port, face: .top, center: CGPoint(x: 0.5, y: 0.45), size: 0.062, height: 0.021,
                      shape: .roundedRect(corner: 0.45),
                      note: "USB-C for charging. InputConfig sends no USB start-up command, so wired play may read nothing"),
        PlacedControl(id: "zr", kind: .shoulder, face: .top, center: CGPoint(x: 0.7, y: 0.4), size: 0.055, height: 0.03,
                      shape: .roundedRect(corner: 0.35),
                      inputs: ControlInputs(buttons: [7], axes: [.analog(5)]),
                      pathInputs: [.rawSDL: .button(7)],
                      note: "Digital. GameController reads it as the right trigger (btn 7 and axis 5 at 0 or 1); the raw SDL read gives btn 7 only (HID button 15)",
                      callout: .above),
        PlacedControl(id: "r", kind: .shoulder, face: .top, center: CGPoint(x: 0.84, y: 0.6), size: 0.19, height: 0.05,
                      shape: .capsule(angleDegrees: 0), inputs: .button(5), callout: .below),

        // Front, left lobe: the +Control Pad, centered in the lobe.
        PlacedControl(id: "dpad", kind: .dpad, center: CGPoint(x: 0.205, y: 0.5), size: 0.15, shape: .crossPad,
                      inputs: .hat(0), callout: .below),

        // Front, middle: SELECT and START, angled pills rising to the right.
        PlacedControl(id: "select", kind: .menuButton, center: CGPoint(x: 0.44, y: 0.6), size: 0.08, height: 0.03,
                      shape: .capsule(angleDegrees: -40), printed: "SEL", inputs: .button(8),
                      note: "SELECT, the Minus button to a Switch", callout: .below),
        PlacedControl(id: "start", kind: .menuButton, center: CGPoint(x: 0.56, y: 0.6), size: 0.08, height: 0.03,
                      shape: .capsule(angleDegrees: -40), printed: "STRT", inputs: .button(9),
                      note: "START, the Plus button to a Switch", callout: .below),

        // Front, below SELECT and START: SYNC and the four player LEDs.
        PlacedControl(id: "sync", kind: .other, center: CGPoint(x: 0.455, y: 0.79), size: 0.02,
                      printed: "SYNC",
                      readable: .notReported("The controller handles SYNC itself for pairing; it never reaches the Mac")),
        PlacedControl(id: "player-leds", kind: .light, center: CGPoint(x: 0.545, y: 0.79), size: 0.07, height: 0.012,
                      shape: .capsule(angleDegrees: 0),
                      readable: .notReported("InputConfig sends no player LED command to this pad, so it neither reads nor sets them")),

        // Front, right lobe: the A/B/X/Y diamond in the Super Famicom and
        // PAL colors the Switch version prints. Positional numbering (see
        // the note at the top).
        PlacedControl(id: "x", kind: .faceButton, center: CGPoint(x: 0.79, y: 0.33), size: 0.072, tint: .snesBlue,
                      inputs: .button(3), note: "Top button", callout: .above),
        PlacedControl(id: "y", kind: .faceButton, center: CGPoint(x: 0.715, y: 0.5), size: 0.072, tint: .snesGreen,
                      inputs: .button(2), note: "Left button", callout: .left),
        PlacedControl(id: "a", kind: .faceButton, center: CGPoint(x: 0.865, y: 0.5), size: 0.072, tint: .snesRed,
                      inputs: .button(1), note: "Right button", callout: .right),
        PlacedControl(id: "b", kind: .faceButton, center: CGPoint(x: 0.79, y: 0.67), size: 0.072, tint: .snesYellow,
                      inputs: .button(0), note: "Bottom button", callout: .below),
    ]

    /// What the raw SDL read adds beyond the row: the Switch simple report
    /// declares 16 buttons and four stick axes, and SDLGameControllerDB puts
    /// every one the row leaves out on the extra slots. None has a control
    /// on this pad, so they never change.
    static let nsoSNESOffBody: [OffBodyInput] = {
        let why = "Raw SDL read only: a report field the SDL row leaves out (the Switch report's unused bits), which this pad never sets"
        let buttons = (22...27).map { OffBodyInput(serialized: "btn \($0)", reason: why) }
        let axisWhy = "Raw SDL read only: a stick axis the Switch report declares and the SNES pad does not have; it rests at center"
        let axes = (6...9).flatMap { i in ["+", "-"].map { OffBodyInput(serialized: "axi \(i) \($0)", reason: axisWhy) } }
        return buttons + axes
    }()
}
