import Foundation
import CoreGraphics

extension ControllerLayout {
    /// 8BitDo Pro 3, in D mode (the mode switch position 8BitDo gives for
    /// Apple devices). Read through GameController as an extendedGamepad
    /// with four extra elements, "L4 Button", "R4 Button", "M1 Button" and
    /// "M2 Button", or raw through the bundled SDL row for 2DC8:6009 when
    /// GameController does not list the pad.
    ///
    /// It keeps the Pro 2's shell and front arrangement, so the outline and
    /// the front positions are the Pro 2's (not measured on the Pro 3), with
    /// what the Pro 3 adds: L4 and R4 beside the bumpers on the top edge,
    /// the PL and PR paddles inside the grips on the back, the switches that
    /// turn the triggers between Hall effect and tactile, and the headphone
    /// jack. The face buttons are magnetic and swap between the Nintendo and
    /// Xbox arrangements; they are drawn as shipped, Nintendo style.
    ///
    /// Numbering, the same on both paths: L4 16, R4 17, PL 18, PR 19. Read
    /// raw, the SDL row gives L4 and R4 as paddle2 and paddle1 (b16, b17)
    /// and PL and PR as paddle4 and paddle3 (b5, b2), where SDL's 8BitDo
    /// driver reads the back buttons. On GameController, "M2 Button" is the
    /// left paddle: a Pro 3 read both ways sent the press GameController
    /// named M2 as raw button 5, the row's lower left paddle.
    static let eightBitDoPro3 = ControllerLayout(
        id: .eightBitDoPro3,
        displayName: "8BitDo Pro 3",
        maker: .eightBitDo,
        family: nil,
        modelNames: ButtonNames.ModelNames(
            renamed: [4: "L", 5: "R", 6: "L2", 7: "R2", 8: "Select", 9: "Start", 10: "Home",
                      11: "L3", 12: "R3", 16: "L4", 17: "R4", 18: "PL", 19: "PR"],
            short: [4: "L", 5: "R", 6: "L2", 7: "R2", 8: "Select", 9: "Start", 10: "Home",
                    11: "L3", 12: "R3", 16: "L4", 17: "R4", 18: "PL", 19: "PR"],
            absent: [13, 14, 15, 20, 21]
        ),
        aspect: 1032.0 / 673.0,
        topStrip: 0.2,
        backStrip: 0.5,
        silhouette: Silhouette(front: eightBitDoPro2Front,
                               top: Silhouette.roundedRectOps(corner: 0.2, inset: 0.04),
                               back: eightBitDoPro2Front),
        controls: eightBitDoPro3Controls,
        // GameController names it "8BitDo Pro 3" plus a color ("8BitDo Pro
        // 3 Grise"); its four extra elements tell it apart from a Pro 2,
        // whose back buttons are "Back Left Button 0" and "Back Right Button
        // 0". Read raw, by the product ID of its SDL row.
        match: [
            [.brand(.eightBitDo), .gcVendorNameContains("8BitDo Pro 3")],
            [.brand(.eightBitDo), .gcProductCategoryContains("8BitDo Pro 3")],
            [.brand(.eightBitDo), .gcHasElement("L4 Button"), .gcHasElement("M1 Button")],
            [.vidPid(vendor: 0x2DC8, products: [0x6009])],
        ],
        matchPriority: 21,
        approximate: true,
        sources: [
            "8bitdo.com/pro3 and 8bitdo.com/apple: L4 and R4, two back paddles, Hall effect and tactile trigger switches, three profiles, the 3.5 mm jack, the D mode switch position for Apple devices",
            "nintendolife.com Pro 3 review: L4 and R4 on the top edge beside the bumpers, PL and PR on the back, magnetic swappable face buttons, symmetric sticks",
            "SDL gamecontrollerdb.txt macOS row for 8BitDo Pro 3 (2DC8:6009): paddle1 b17, paddle2 b16, paddle3 b2, paddle4 b5",
            "github.com/ryleighnewman/InputConfig/pull/9 screenshots: GameController's extra elements M1, M2, L4 and R4, and the M2 press read raw as button 5",
        ]
    )

    static let eightBitDoPro3Controls: [PlacedControl] = [
        // Top: L2 and R2 behind the bumpers, L4 and R4 inboard of the
        // bumpers, the Pair button and the USB-C port along the middle.
        PlacedControl(id: "l2", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.22, y: 0.195), size: 0.15, height: 0.13,
                      shape: .roundedRect(corner: 0.35), printed: "L2", inputs: .trigger(axis: 4, digital: 6),
                      note: "Hall effect or tactile, set by the switch on the back",
                      callout: .above),
        PlacedControl(id: "r2", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.78, y: 0.195), size: 0.15, height: 0.13,
                      shape: .roundedRect(corner: 0.35), printed: "R2", inputs: .trigger(axis: 5, digital: 7),
                      note: "Hall effect or tactile, set by the switch on the back",
                      callout: .above),
        PlacedControl(id: "l", kind: .shoulder, face: .top, center: CGPoint(x: 0.2, y: 0.76), size: 0.16, height: 0.045,
                      shape: .capsule(angleDegrees: 0), printed: "L", inputs: .button(4), callout: .below),
        PlacedControl(id: "r", kind: .shoulder, face: .top, center: CGPoint(x: 0.8, y: 0.76), size: 0.16, height: 0.045,
                      shape: .capsule(angleDegrees: 0), printed: "R", inputs: .button(5), callout: .below),
        PlacedControl(id: "l4", kind: .shoulder, face: .top, center: CGPoint(x: 0.335, y: 0.76), size: 0.06, height: 0.04,
                      shape: .roundedRect(corner: 0.4), printed: "L4", inputs: .button(16),
                      readable: .conditional("Btn 16 on both paths: GameController's L4 Button, or read raw its SDL row's b16"),
                      note: "If 8BitDo's software or the controller maps it to another button, the Mac receives that button instead",
                      callout: .below),
        PlacedControl(id: "r4", kind: .shoulder, face: .top, center: CGPoint(x: 0.665, y: 0.76), size: 0.06, height: 0.04,
                      shape: .roundedRect(corner: 0.4), printed: "R4", inputs: .button(17),
                      readable: .conditional("Btn 17 on both paths: GameController's R4 Button, or read raw its SDL row's b17"),
                      note: "If 8BitDo's software or the controller maps it to another button, the Mac receives that button instead",
                      callout: .below),
        PlacedControl(id: "pair", kind: .other, face: .top, center: CGPoint(x: 0.44, y: 0.55), size: 0.03, height: 0.02,
                      shape: .roundedRect(corner: 0.4), printed: "PAIR",
                      readable: .notReported("Pair puts the controller in Bluetooth pairing mode; it never reaches the Mac")),
        PlacedControl(id: "usb-c", kind: .port, face: .top, center: CGPoint(x: 0.5, y: 0.55), size: 0.055, height: 0.022,
                      shape: .roundedRect(corner: 0.45), note: "USB-C for charging and wired play"),

        // Front, left: the D-pad high, Star below it.
        PlacedControl(id: "dpad", kind: .dpad, center: CGPoint(x: 0.225, y: 0.257), size: 0.155, shape: .crossPad,
                      inputs: .hat(0), callout: .below),
        PlacedControl(id: "star", kind: .menuButton, center: CGPoint(x: 0.225, y: 0.506), size: 0.044,
                      symbol: "star",
                      readable: .notReported("Star sets turbo and confirms button mapping on the controller itself; it is not sent to the Mac"),
                      callout: .below),

        // Front, center: Select (minus) and Start (plus), the sticks below.
        PlacedControl(id: "select", kind: .menuButton, center: CGPoint(x: 0.453, y: 0.25), size: 0.073, height: 0.024,
                      shape: .capsule(angleDegrees: 0), symbol: "minus", inputs: .button(8), callout: .above),
        PlacedControl(id: "start", kind: .menuButton, center: CGPoint(x: 0.545, y: 0.25), size: 0.073, height: 0.024,
                      shape: .capsule(angleDegrees: 0), symbol: "plus", inputs: .button(9), callout: .above),
        PlacedControl(id: "lstick", kind: .stick, center: CGPoint(x: 0.358, y: 0.476), size: 0.125,
                      inputs: .stick(x: 0, y: 1, press: 11), callout: .below),
        PlacedControl(id: "rstick", kind: .stick, center: CGPoint(x: 0.642, y: 0.476), size: 0.125,
                      inputs: .stick(x: 2, y: 3, press: 12), callout: .below),
        PlacedControl(id: "profile", kind: .menuButton, center: CGPoint(x: 0.499, y: 0.478), size: 0.044, height: 0.024,
                      shape: .capsule(angleDegrees: 0),
                      readable: .notReported("Profile switches between the controller's three button profiles; it is not sent to the Mac"),
                      callout: .below),

        // Front, right: the face buttons, Nintendo style as shipped.
        PlacedControl(id: "x", kind: .faceButton, center: CGPoint(x: 0.772, y: 0.153), size: 0.068, printed: "X",
                      inputs: .button(3), callout: .above),
        PlacedControl(id: "y", kind: .faceButton, center: CGPoint(x: 0.695, y: 0.257), size: 0.068, printed: "Y",
                      inputs: .button(2), callout: .left),
        PlacedControl(id: "a", kind: .faceButton, center: CGPoint(x: 0.85, y: 0.257), size: 0.068, printed: "A",
                      inputs: .button(1), callout: .right),
        PlacedControl(id: "b", kind: .faceButton, center: CGPoint(x: 0.772, y: 0.361), size: 0.068, printed: "B",
                      inputs: .button(0),
                      note: "The face buttons are magnetic and can be swapped to the Xbox arrangement; the Mac reads them by position",
                      callout: .below),
        PlacedControl(id: "home", kind: .homeButton, center: CGPoint(x: 0.773, y: 0.505), size: 0.048,
                      symbol: "house", inputs: .button(10), callout: .below),

        // Back, as held: PL inside the left grip, PR inside the right, the
        // trigger switches above them, the mode switch and the headphone
        // jack in the middle.
        PlacedControl(id: "pl", kind: .paddle, face: .back, center: CGPoint(x: 0.27, y: 0.5), size: 0.07, height: 0.12,
                      shape: .capsule(angleDegrees: 20), printed: "PL", inputs: .button(18),
                      readable: .conditional("Btn 18 on both paths: GameController's M2 Button, or read raw its SDL row's b5"),
                      note: "If 8BitDo's software or the controller maps it to another button, the Mac receives that button instead",
                      callout: .below),
        PlacedControl(id: "pr", kind: .paddle, face: .back, center: CGPoint(x: 0.73, y: 0.5), size: 0.07, height: 0.12,
                      shape: .capsule(angleDegrees: -20), printed: "PR", inputs: .button(19),
                      readable: .conditional("Btn 19 on both paths: GameController's M1 Button, or read raw its SDL row's b2"),
                      note: "If 8BitDo's software or the controller maps it to another button, the Mac receives that button instead",
                      callout: .below),
        PlacedControl(id: "trigger-switch-left", kind: .slider, face: .back, center: CGPoint(x: 0.25, y: 0.2), size: 0.05, height: 0.02,
                      shape: .capsule(angleDegrees: 0),
                      readable: .notReported("Turns L2 between Hall effect and tactile; it sends nothing")),
        PlacedControl(id: "trigger-switch-right", kind: .slider, face: .back, center: CGPoint(x: 0.75, y: 0.2), size: 0.05, height: 0.02,
                      shape: .capsule(angleDegrees: 0),
                      readable: .notReported("Turns R2 between Hall effect and tactile; it sends nothing")),
        PlacedControl(id: "mode-switch", kind: .slider, face: .back, center: CGPoint(x: 0.5, y: 0.45), size: 0.065, height: 0.022,
                      shape: .capsule(angleDegrees: 0), printed: "MODE",
                      readable: .notReported("The mode switch picks how the controller presents itself; it sends nothing. D is the mode for a Mac")),
        PlacedControl(id: "audio", kind: .port, face: .back, center: CGPoint(x: 0.5, y: 0.53), size: 0.03,
                      note: "3.5 mm headphone jack"),
    ]
}
