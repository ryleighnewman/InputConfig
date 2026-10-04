import Foundation
import CoreGraphics

extension ControllerLayout {
    /// Standard gamepad: the last-resort dual-analog body, drawn as a
    /// Logitech F310 (the F510 and F710 share its shell). Any pad that
    /// reads the standard slots fits it: A 0, B 1, X 2, Y 3, LB 4, RB 5,
    /// LT 6, RT 7, Back 8, Start 9, Home 10, L3 11, R3 12, sticks on axes
    /// 0 to 3, analog triggers on 4 and 5, the D-pad on hat 0. That is what
    /// GameControllerService.readControllerState gives an extended gamepad
    /// and what SDLGameControllerDB.buttonSlots and axisSlots give a raw
    /// HID pad with an SDL row.
    ///
    /// Variant f310 is the F310, F510 or F710 in D mode (046D:C216, C218,
    /// C219). RawHIDGamepadService reads it directly (Logitech is not in
    /// gameControllerVendors), through its SDL rows
    /// (SDLGameControllerDBData.swift:170-178): a b1, b b2, x b0, y b3,
    /// LB b4, RB b5, LT b6, RT b7, back b8, start b9, L3 b10, R3 b11, the
    /// D-pad on h0, sticks a0 to a3. In D mode the triggers are plain
    /// buttons (6 and 7, no axes), the Logitech button sends nothing (the
    /// rows have no guide), and MODE only swaps the D-pad and the left
    /// stick inside the pad. In X mode the pad is an XInput device the Mac
    /// does not read at all.
    ///
    /// Logitech gives 142 mm across and 98 mm from the top edge to the grip
    /// tips (75 mm thick), so the front face is 1.45 wide per unit of
    /// height. Face letters follow Settings > Face button names, so the
    /// face buttons carry no printed letters or tints here: the F310 prints
    /// Xbox-colored A, B, X and Y, but this body also stands in for pads
    /// that print other letters.
    static let genericGamepad = ControllerLayout(
        id: .genericGamepad,
        displayName: "Standard gamepad",
        maker: .generic,
        family: nil,
        aspect: 1.45,
        topStrip: 0.2,
        backStrip: 0.1,
        silhouette: Silhouette(front: Silhouette.symmetric(genericGamepadLeftHalf),
                               top: Silhouette.roundedRectOps(corner: 0.18, inset: 0.04),
                               back: Silhouette.roundedRectOps(corner: 0.3, inset: 0.04)),
        controls: genericGamepadControls,
        variants: [
            LayoutVariant(id: "standard", displayName: "Standard gamepad", isDefault: true),
            LayoutVariant(id: "f310", displayName: "Logitech F310, F510 or F710 in D mode"),
        ],
        match: [
            // D mode only: F310 C216, F510 C218, F710 C219. The older
            // Logitech Dual Action and RumblePad 2 share these IDs and the
            // same SDL numbering on a very similar body.
            [.vidPid(vendor: 0x046D, products: [0xC216, 0xC218, 0xC219])],
        ],
        matchPriority: 5,
        approximate: true,
        sources: [
            "Logitech Gamepad F310 Technical Specifications (support.logi.com): 142 x 98 x 75 mm, XInput and DirectInput modes",
            "Getting started with Logitech Gamepad F310 (logitech.com/assets/35017/gamepad-f310-gsw.pdf): features, Mode button and status light, Logitech button with no function in DirectInput",
            "Using the Mode button on my F310 gamepad (support.logi.com)",
            "SDL GameControllerDB macOS rows for 046D:C216, C218, C219 (SDLGameControllerDBData.swift)",
        ],
        // Its only match rules are Logitech's D mode IDs.
        vendorVariants: [0x046D: "f310"]
    )

    /// The front outline's left half: a broad, nearly flat top edge,
    /// rounded shoulders where the bumpers wrap the corners, sides that
    /// run straight down into long grips with rounded tips, and an arch
    /// between the grips just under the sticks.
    static let genericGamepadLeftHalf: [PathOp] = [
        .move(0.5, 0.03),
        .curve(0.17, 0.035, c1x: 0.38, c1y: 0.025, c2x: 0.25, c2y: 0.02),
        .curve(0.02, 0.3, c1x: 0.07, c1y: 0.05, c2x: 0.025, c2y: 0.16),
        .curve(0.05, 0.93, c1x: 0.012, c1y: 0.55, c2x: 0.02, c2y: 0.82),
        .curve(0.24, 0.92, c1x: 0.08, c1y: 1.0, c2x: 0.21, c2y: 1.0),
        .curve(0.34, 0.76, c1x: 0.27, c1y: 0.85, c2x: 0.3, c2y: 0.78),
        .curve(0.5, 0.73, c1x: 0.39, c1y: 0.74, c2x: 0.45, c2y: 0.73),
    ]

    static let genericGamepadControls: [PlacedControl] = [
        // Top: triggers at the rear corners, bumpers in front of them, and
        // the USB cable leaving the middle of the rear edge.
        PlacedControl(id: "lt", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.2, y: 0.17), size: 0.15, height: 0.13,
                      shape: .roundedRect(corner: 0.35), inputs: .trigger(axis: 4, digital: 6), callout: .above,
                      variants: ["standard"]),
        PlacedControl(id: "rt", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.8, y: 0.17), size: 0.15, height: 0.13,
                      shape: .roundedRect(corner: 0.35), inputs: .trigger(axis: 5, digital: 7), callout: .above,
                      variants: ["standard"]),
        // The F310 in D mode: the same triggers, read as buttons only. The
        // digital copy slot carries the button so the legend and the
        // inspector name it as LT and RT.
        PlacedControl(id: "lt.f310", kind: .trigger(.digital), face: .top, center: CGPoint(x: 0.2, y: 0.17), size: 0.15, height: 0.13,
                      shape: .roundedRect(corner: 0.35), inputs: ControlInputs(digitalCopy: 6),
                      note: "On or off in D mode: the pad sends no trigger axis", callout: .above,
                      overlayOf: "lt", variants: ["f310"]),
        PlacedControl(id: "rt.f310", kind: .trigger(.digital), face: .top, center: CGPoint(x: 0.8, y: 0.17), size: 0.15, height: 0.13,
                      shape: .roundedRect(corner: 0.35), inputs: ControlInputs(digitalCopy: 7),
                      note: "On or off in D mode: the pad sends no trigger axis", callout: .above,
                      overlayOf: "rt", variants: ["f310"]),
        PlacedControl(id: "lb", kind: .shoulder, face: .top, center: CGPoint(x: 0.2, y: 0.74), size: 0.16, height: 0.04,
                      shape: .capsule(angleDegrees: 0), inputs: .button(4), callout: .below),
        PlacedControl(id: "rb", kind: .shoulder, face: .top, center: CGPoint(x: 0.8, y: 0.74), size: 0.16, height: 0.04,
                      shape: .capsule(angleDegrees: 0), inputs: .button(5), callout: .below),
        PlacedControl(id: "cable", kind: .port, face: .top, center: CGPoint(x: 0.5, y: 0.22), size: 0.03, height: 0.02,
                      shape: .roundedRect(corner: 0.4), note: "USB cable", variants: ["f310"]),

        // Front, left wing: the 8-way D-pad in its round recess.
        PlacedControl(id: "dpad", kind: .dpad, center: CGPoint(x: 0.21, y: 0.34), size: 0.155, shape: .crossPad,
                      inputs: .hat(0), callout: .below),

        // Right wing: the face buttons, by position (bottom 0, right 1,
        // left 2, top 3).
        PlacedControl(id: "y", kind: .faceButton, center: CGPoint(x: 0.79, y: 0.235), size: 0.062,
                      inputs: .button(3), callout: .above),
        PlacedControl(id: "x", kind: .faceButton, center: CGPoint(x: 0.72, y: 0.34), size: 0.062,
                      inputs: .button(2), pathInputs: [.rawDescriptor: .button(0)], callout: .left),
        PlacedControl(id: "b", kind: .faceButton, center: CGPoint(x: 0.86, y: 0.34), size: 0.062,
                      inputs: .button(1), pathInputs: [.rawDescriptor: .button(2)], callout: .right),
        PlacedControl(id: "a", kind: .faceButton, center: CGPoint(x: 0.79, y: 0.445), size: 0.062,
                      inputs: .button(0), pathInputs: [.rawDescriptor: .button(1)], callout: .below),

        // Center: BACK and START near the top edge, the round Logitech
        // (Home) button below and between them.
        PlacedControl(id: "back", kind: .menuButton, center: CGPoint(x: 0.41, y: 0.25), size: 0.05, height: 0.026,
                      shape: .capsule(angleDegrees: 0), printed: "BACK", inputs: .button(8), callout: .above),
        PlacedControl(id: "start", kind: .menuButton, center: CGPoint(x: 0.59, y: 0.25), size: 0.05, height: 0.026,
                      shape: .capsule(angleDegrees: 0), printed: "START", inputs: .button(9), callout: .above),
        PlacedControl(id: "home", kind: .homeButton, center: CGPoint(x: 0.5, y: 0.34), size: 0.058,
                      inputs: .button(10), note: "Home or Guide, on pads that report one", callout: .below,
                      variants: ["standard"]),
        PlacedControl(id: "logitech", kind: .homeButton, center: CGPoint(x: 0.5, y: 0.34), size: 0.058,
                      readable: .notReported("The Logitech button has no function in D mode and sends nothing"),
                      callout: .below, overlayOf: "home", variants: ["f310"]),

        // MODE and its status light, between the D-pad and the left stick.
        PlacedControl(id: "mode", kind: .menuButton, center: CGPoint(x: 0.405, y: 0.43), size: 0.034,
                      printed: "MODE",
                      readable: .notReported("Swaps the D-pad and the left stick inside the pad; never reported"),
                      callout: .left, variants: ["f310"]),
        PlacedControl(id: "mode.light", kind: .light, center: CGPoint(x: 0.445, y: 0.43), size: 0.012,
                      readable: .notReported("Lit while MODE has swapped the D-pad and the left stick; cannot be read or set"),
                      callout: .right, variants: ["f310"]),

        // Sticks low and level, just inside the grips.
        PlacedControl(id: "lstick", kind: .stick, center: CGPoint(x: 0.355, y: 0.6), size: 0.14,
                      inputs: .stick(x: 0, y: 1, press: 11), pathInputs: [.rawDescriptor: .stick(x: 0, y: 1, press: 10)], callout: .below),
        PlacedControl(id: "rstick", kind: .stick, center: CGPoint(x: 0.645, y: 0.6), size: 0.14,
                      inputs: .stick(x: 2, y: 3, press: 12), pathInputs: [.rawDescriptor: .stick(x: 2, y: 3, press: 11)], callout: .below),

        // Back, as held: the X/D input switch in the middle of the
        // underside, near the rear edge.
        PlacedControl(id: "xd.switch", kind: .slider, face: .back, center: CGPoint(x: 0.5, y: 0.35), size: 0.06, height: 0.025,
                      shape: .roundedRect(corner: 0.3), printed: "X D",
                      readable: .notReported("Input mode switch: the Mac reads the pad only in D; in X it is an XInput device macOS does not open"),
                      callout: .below, variants: ["f310"]),
    ]
}
