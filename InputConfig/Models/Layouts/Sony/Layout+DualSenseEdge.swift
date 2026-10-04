import Foundation
import CoreGraphics

extension ControllerLayout {
    /// PlayStation DualSense Edge (CFI-ZCP1), read through GameController
    /// (GCDualSenseGamepad) with DualSenseSupplementService adding PS, mute,
    /// both Fn buttons and both back buttons from raw report byte buttons[2]
    /// (USB report 0x01 byte 10, Bluetooth report 0x31 byte 11), the same
    /// bits SDL_hidapi_ps5.c reads.
    ///
    /// Same shell as the DualSense (160 mm wide, 106 mm deep). Positions are
    /// measured from Sony's part diagrams in the Edge instruction manual
    /// (pages 9 and 10); the back face is transcribed from Sony's rear view,
    /// which is drawn from behind, so it is mirrored here to read as held.
    /// The face symbols are printed monochrome, so the face buttons have no
    /// tint.
    static let dualSenseEdge = ControllerLayout(
        id: .dualSenseEdge,
        displayName: "DualSense Edge",
        maker: .sony,
        family: .playstation,
        aspect: 1.5,
        topStrip: 0.2,
        backStrip: 0.42,
        silhouette: Silhouette(
            front: Silhouette.gamepad(gripLength: 0.36, waist: 0.69, shoulder: 0.35, gripWidth: 0.21,
                                      flare: 0.01, topDip: 0.0).front,
            top: Silhouette.roundedRectOps(corner: 0.18, inset: 0.04),
            back: Silhouette.symmetric(dualSenseEdgeBackLeftHalf)
        ),
        touchSurfaces: [
            TouchSurfaceSpec(surface: 0, controlID: "touchpad", name: "Touchpad", outline: .dualSenseFlare,
                             aspect: 1920.0 / 1080.0, maxFingers: 2, pressIndex: 13),
        ],
        controls: dualSenseEdgeControls,
        // The Edge's name carries "Edge" in GameController's product category
        // or vendor name, which a plain DualSense never does. The raw
        // product ID 054C:0DF2 covers a pad read outside GameController.
        match: [
            [.brand(.dualSense), .gcProductCategoryContains("Edge")],
            [.brand(.dualSense), .gcVendorNameContains("Edge")],
            [.brand(.dualSense), .gcHasElement("Left Paddle")],
            [.vidPid(vendor: 0x054C, products: [0x0DF2])],
        ],
        matchPriority: 20,
        approximate: true,
        sources: [
            "Sony DualSense Edge Wireless Controller Instruction Manual CFI-ZCP1, pages 6, 7, 9 and 10 (playstation.com)",
            "playstation.com: How to set DualSense Edge wireless controller profiles and settings",
            "SDL src/joystick/hidapi/SDL_hidapi_ps5.c (Edge Fn and back button bits)",
        ]
    )

    /// The back as held, traced from Sony's rear diagram (mirrored; the
    /// outline is symmetric, so only the controls change sides). Drawn a
    /// little shorter than true so the back strip stays compact.
    static let dualSenseEdgeBackLeftHalf: [PathOp] = [
        .move(0.5, 0.02),
        .line(0.27, 0.02),
        // The L2 trigger hump rising over the top edge.
        .quad(0.19, 0.005, cx: 0.24, cy: 0.005),
        .quad(0.125, 0.05, cx: 0.14, cy: 0.005),
        // Outer side, widest about two thirds of the way down.
        .curve(0.008, 0.55, c1x: 0.08, c1y: 0.15, c2x: 0.02, c2y: 0.4),
        .curve(0.075, 0.99, c1x: 0.0, c1y: 0.78, c2x: 0.02, c2y: 0.96),
        // Grip tip, then the inner edge up to the flat center bottom.
        .quad(0.13, 0.98, cx: 0.105, cy: 1.0),
        .curve(0.25, 0.675, c1x: 0.17, c1y: 0.92, c2x: 0.2, c2y: 0.7),
        .quad(0.29, 0.665, cx: 0.26, cy: 0.665),
        .line(0.5, 0.665),
    ]

    static let dualSenseEdgeControls: [PlacedControl] = [
        // Top: bumpers nearest the front, triggers behind them, USB-C (with
        // the connector housing lock) in the middle.
        PlacedControl(id: "l2", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.2, y: 0.175), size: 0.16, height: 0.13,
                      shape: .roundedRect(corner: 0.35), inputs: .trigger(axis: 4, digital: 6),
                      note: "Travel set by the L2 stop slider on the back", callout: .above),
        PlacedControl(id: "r2", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.8, y: 0.175), size: 0.16, height: 0.13,
                      shape: .roundedRect(corner: 0.35), inputs: .trigger(axis: 5, digital: 7),
                      note: "Travel set by the R2 stop slider on the back", callout: .above),
        PlacedControl(id: "l1", kind: .shoulder, face: .top, center: CGPoint(x: 0.2, y: 0.75), size: 0.16, height: 0.045,
                      shape: .capsule(angleDegrees: 0), inputs: .button(4), callout: .below),
        PlacedControl(id: "r1", kind: .shoulder, face: .top, center: CGPoint(x: 0.8, y: 0.75), size: 0.16, height: 0.045,
                      shape: .capsule(angleDegrees: 0), inputs: .button(5), callout: .below),
        PlacedControl(id: "usb", kind: .port, face: .top, center: CGPoint(x: 0.5, y: 0.55), size: 0.07, height: 0.025,
                      shape: .roundedRect(corner: 0.4), note: "USB-C, with the connector housing that locks the cable"),

        // Front, upper band: Create, touchpad (light bar strips along its
        // sides), Options. Sony's diagram puts Create and Options just
        // outside the touchpad's upper corners.
        PlacedControl(id: "create", kind: .menuButton, center: CGPoint(x: 0.245, y: 0.13), size: 0.035, height: 0.05,
                      shape: .capsule(angleDegrees: 0), symbol: "square.and.arrow.up", inputs: .button(8), callout: .left),
        PlacedControl(id: "touchpad", kind: .trackpad, center: CGPoint(x: 0.5, y: 0.2), size: 0.35, height: 0.14,
                      shape: .roundedRect(corner: 0.15), inputs: ControlInputs(press: 13, surface: 0), callout: .above),
        PlacedControl(id: "lightbar.left", kind: .light, center: CGPoint(x: 0.3185, y: 0.2), size: 0.011, height: 0.12,
                      shape: .capsule(angleDegrees: 0), note: "Light bar, output only: shows the preset's light color"),
        PlacedControl(id: "lightbar.right", kind: .light, center: CGPoint(x: 0.6815, y: 0.2), size: 0.011, height: 0.12,
                      shape: .capsule(angleDegrees: 0), note: "Light bar, output only: shows the preset's light color"),
        PlacedControl(id: "options", kind: .menuButton, center: CGPoint(x: 0.755, y: 0.13), size: 0.035, height: 0.05,
                      shape: .capsule(angleDegrees: 0), symbol: "line.3.horizontal", inputs: .button(9),
                      note: "Fn + Options opens the controller's profile settings", callout: .right),

        // Left wing: the four separate arrows.
        PlacedControl(id: "dpad", kind: .dpad, center: CGPoint(x: 0.2, y: 0.34), size: 0.15, shape: .crossPad,
                      inputs: .hat(0), note: "Fn + up or down sets headset volume; Fn + left or right sets audio balance",
                      callout: .below),

        // Right wing: the face buttons, printed monochrome.
        PlacedControl(id: "triangle", kind: .faceButton, center: CGPoint(x: 0.8, y: 0.235), size: 0.058,
                      inputs: .button(3), callout: .above),
        PlacedControl(id: "square", kind: .faceButton, center: CGPoint(x: 0.733, y: 0.34), size: 0.058,
                      inputs: .button(2), callout: .left),
        PlacedControl(id: "circle", kind: .faceButton, center: CGPoint(x: 0.867, y: 0.34), size: 0.058,
                      inputs: .button(1), callout: .right),
        PlacedControl(id: "cross", kind: .faceButton, center: CGPoint(x: 0.8, y: 0.445), size: 0.058,
                      inputs: .button(0), callout: .below),

        // Center: sticks on swappable modules, PS between them, mute below.
        PlacedControl(id: "lstick", kind: .stick, center: CGPoint(x: 0.343, y: 0.56), size: 0.12,
                      inputs: .stick(x: 0, y: 1, press: 11), callout: .below),
        PlacedControl(id: "rstick", kind: .stick, center: CGPoint(x: 0.657, y: 0.56), size: 0.12,
                      inputs: .stick(x: 2, y: 3, press: 12), callout: .below),
        PlacedControl(id: "ps", kind: .homeButton, center: CGPoint(x: 0.5, y: 0.53), size: 0.05,
                      inputs: .button(10), note: "macOS opens Launchpad on the PS button unless a preset uses it", callout: .above),
        PlacedControl(id: "mute", kind: .menuButton, center: CGPoint(x: 0.5, y: 0.635), size: 0.055, height: 0.022,
                      shape: .capsule(angleDegrees: 0), symbol: "mic.slash", inputs: .button(15),
                      pathInputs: [.rawSDL: .button(14)], callout: .below, name: "Mute"),

        // Edge only: a small ridged Fn button directly below each stick, on
        // the lower edge of the front cover.
        PlacedControl(id: "fnLeft", kind: .menuButton, center: CGPoint(x: 0.343, y: 0.72), size: 0.05, height: 0.02,
                      shape: .roundedRect(corner: 0.35), printed: "Fn", inputs: .button(20), pathInputs: [.rawSDL: .none],
                      note: "Fn with Triangle, Circle, Cross or Square switches the controller's profile; Fn + Options opens profile settings; Fn + D-pad sets headset volume and balance. A row bound to Fn plus a face button also switches profile.",
                      callout: .below, name: "Left Fn"),
        PlacedControl(id: "fnRight", kind: .menuButton, center: CGPoint(x: 0.657, y: 0.72), size: 0.05, height: 0.02,
                      shape: .roundedRect(corner: 0.35), printed: "Fn", inputs: .button(21), pathInputs: [.rawSDL: .none],
                      note: "Fn with Triangle, Circle, Cross or Square switches the controller's profile; Fn + Options opens profile settings; Fn + D-pad sets headset volume and balance. A row bound to Fn plus a face button also switches profile.",
                      callout: .below, name: "Right Fn"),

        // Back, as held: the stop sliders just inside each trigger, the two
        // back button sockets on the inner grips, the reset pinhole and the
        // RELEASE latch in the center.
        PlacedControl(id: "l2Stop", kind: .slider, face: .back, center: CGPoint(x: 0.32, y: 0.17), size: 0.025, height: 0.075,
                      shape: .capsule(angleDegrees: 0),
                      readable: .notReported("Mechanical three-position stop for L2: it shortens the trigger's travel and sends nothing")),
        PlacedControl(id: "r2Stop", kind: .slider, face: .back, center: CGPoint(x: 0.68, y: 0.17), size: 0.025, height: 0.075,
                      shape: .capsule(angleDegrees: 0),
                      readable: .notReported("Mechanical three-position stop for R2: it shortens the trigger's travel and sends nothing")),
        PlacedControl(id: "backLeft", kind: .paddle, face: .back, center: CGPoint(x: 0.342, y: 0.47), size: 0.065,
                      printed: "LB", inputs: .button(16), pathInputs: [.rawSDL: .none],
                      readable: .conditional("Reported only in the default profile (Fn + Triangle)"),
                      note: "Half dome or lever back button. In a custom profile the controller sends the button it is assigned to instead.",
                      callout: .below),
        PlacedControl(id: "backRight", kind: .paddle, face: .back, center: CGPoint(x: 0.658, y: 0.47), size: 0.065,
                      printed: "RB", inputs: .button(17), pathInputs: [.rawSDL: .none],
                      readable: .conditional("Reported only in the default profile (Fn + Triangle)"),
                      note: "Half dome or lever back button. In a custom profile the controller sends the button it is assigned to instead.",
                      callout: .below),
        PlacedControl(id: "reset", kind: .other, face: .back, center: CGPoint(x: 0.483, y: 0.45), size: 0.014,
                      readable: .notReported("Reset pinhole: press with a pin to reset the controller")),
        PlacedControl(id: "release", kind: .other, face: .back, center: CGPoint(x: 0.5, y: 0.606), size: 0.06, height: 0.02,
                      shape: .capsule(angleDegrees: 0),
                      readable: .notReported("RELEASE latch: frees the front cover to swap the stick modules")),
    ]
}
