import Foundation
import CoreGraphics

extension ControllerLayout {
    /// PlayStation DualShock 4 (CUH-ZCT1 and CUH-ZCT2), read through
    /// GameController as a GCDualShockGamepad. The raw HID path never opens
    /// it: RawHIDGamepadService treats 054C:05C4, 09CC and 0BA0 as listed by
    /// GameController. About 162 mm wide and 98 mm tall seen from the front,
    /// so the front face is 1.65 wide per unit of height.
    static let dualShock4 = ControllerLayout(
        id: .dualShock4,
        displayName: "DualShock 4",
        maker: .sony,
        family: .playstation,
        modelNames: .of(brand: .dualShock4, dualShock3: false),
        aspect: 1.65,
        topStrip: 0.2,
        silhouette: Silhouette(front: Silhouette.symmetric(dualShock4LeftHalf),
                               top: Silhouette.roundedRectOps(corner: 0.18, inset: 0.04)),
        touchSurfaces: [
            // GameController reports the pad as -1...1 on both axes; the
            // sensor is 1920 by 942 native units, about 52 by 25 mm.
            TouchSurfaceSpec(surface: 0, controlID: "touchpad", name: "Touchpad", outline: .ds4ConvexBottom,
                             aspect: 1920.0 / 942.0, maxFingers: 2, pressIndex: 13),
        ],
        controls: dualShock4Controls,
        variants: [
            LayoutVariant(id: "zct2", displayName: "CUH-ZCT2 (2016)", isDefault: true),
            LayoutVariant(id: "zct1", displayName: "CUH-ZCT1 (2013)"),
        ],
        offBody: MotionChannel.allCases.map {
            OffBodyInput(serialized: "mtn \($0.rawValue) +",
                         reason: "Motion sensors inside the body (3-axis gyro and accelerometer), read through GameController")
        },
        match: [
            [.gcProductCategoryContains("DualShock 4")],
            // The brand alone also fires for a pad whose name says
            // "DualShock 3", so ask for the touchpad too.
            [.brand(.dualShock4), .gcHasElement("Touchpad Button")],
            [.vidPid(vendor: 0x054C, products: [0x05C4, 0x09CC, 0x0BA0])],
        ],
        matchPriority: 10,
        approximate: true,
        sources: [
            "Sony DualShock 4 specifications: 162 x 52 x 98 mm, 2-point capacitive touchpad with click (psu.com, Feb 2013)",
            "playstation.com DualShock 4 wireless controller product page and parts guide",
            "SDL src/joystick/hidapi/SDL_hidapi_ps4.c (touchpad 1920 x 942, two contacts)",
            "SDL src/joystick/usb_ids.h (054c:05c4 the first DualShock 4, CUH-ZCT1; 054c:09cc the 2016 model, CUH-ZCT2)",
        ],
        productVariants: [0x054C << 16 | 0x05C4: "zct1", 0x054C << 16 | 0x09CC: "zct2"]
    )

    /// The front outline's left half: a flat top edge, broad rounded
    /// shoulders, near-vertical sides and long grips that end in rounded
    /// tips, with a shallow arch between them under the speaker.
    static let dualShock4LeftHalf: [PathOp] = [
        .move(0.5, 0.025),
        .curve(0.16, 0.035, c1x: 0.38, c1y: 0.025, c2x: 0.24, c2y: 0.025),
        .curve(0.012, 0.32, c1x: 0.06, c1y: 0.045, c2x: 0.012, c2y: 0.15),
        .curve(0.07, 0.93, c1x: 0.012, c1y: 0.55, c2x: 0.035, c2y: 0.82),
        .curve(0.25, 0.93, c1x: 0.10, c1y: 1.0, c2x: 0.22, c2y: 1.0),
        .curve(0.36, 0.79, c1x: 0.28, c1y: 0.87, c2x: 0.31, c2y: 0.81),
        .curve(0.5, 0.75, c1x: 0.41, c1y: 0.765, c2x: 0.46, c2y: 0.75),
    ]

    static let dualShock4Controls: [PlacedControl] = [
        // Top: triggers at the rear corners, bumpers in front of them, and
        // the light bar across the rear edge, split by the micro USB port.
        PlacedControl(id: "l2", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.2, y: 0.1825), size: 0.15, height: 0.13,
                      shape: .roundedRect(corner: 0.35), inputs: .trigger(axis: 4, digital: 6), callout: .above),
        PlacedControl(id: "r2", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.8, y: 0.1825), size: 0.15, height: 0.13,
                      shape: .roundedRect(corner: 0.35), inputs: .trigger(axis: 5, digital: 7), callout: .above),
        PlacedControl(id: "l1", kind: .shoulder, face: .top, center: CGPoint(x: 0.2, y: 0.74), size: 0.15, height: 0.04,
                      shape: .capsule(angleDegrees: 0), inputs: .button(4), callout: .below),
        PlacedControl(id: "r1", kind: .shoulder, face: .top, center: CGPoint(x: 0.8, y: 0.74), size: 0.15, height: 0.04,
                      shape: .capsule(angleDegrees: 0), inputs: .button(5), callout: .below),
        PlacedControl(id: "lightbar.left", kind: .light, face: .top, center: CGPoint(x: 0.4, y: 0.14), size: 0.14, height: 0.014,
                      shape: .capsule(angleDegrees: 0), note: "Light bar, output only: shows the preset's light color"),
        PlacedControl(id: "usb", kind: .port, face: .top, center: CGPoint(x: 0.5, y: 0.14), size: 0.045, height: 0.016,
                      shape: .roundedRect(corner: 0.3), note: "Micro USB port"),
        PlacedControl(id: "lightbar.right", kind: .light, face: .top, center: CGPoint(x: 0.6, y: 0.14), size: 0.14, height: 0.014,
                      shape: .capsule(angleDegrees: 0), note: "Light bar, output only: shows the preset's light color"),

        // Front, upper band: Share, the touchpad (with the CUH-ZCT2's light
        // strip along its top edge), Options.
        PlacedControl(id: "lightstrip", kind: .light, center: CGPoint(x: 0.5, y: 0.045), size: 0.24, height: 0.007,
                      shape: .capsule(angleDegrees: 0),
                      note: "CUH-ZCT2 only: the light bar shows through a strip on the touchpad", variants: ["zct2"]),
        PlacedControl(id: "share", kind: .menuButton, center: CGPoint(x: 0.29, y: 0.2), size: 0.03, height: 0.045,
                      shape: .capsule(angleDegrees: 0), symbol: "square.and.arrow.up", inputs: .button(8),
                      note: "SHARE; GameController reports it as its Options button", callout: .above),
        PlacedControl(id: "touchpad", kind: .trackpad, center: CGPoint(x: 0.5, y: 0.185), size: 0.32, height: 0.15,
                      shape: .roundedRect(corner: 0.12), inputs: ControlInputs(press: 13, surface: 0), callout: .below),
        PlacedControl(id: "options", kind: .menuButton, center: CGPoint(x: 0.71, y: 0.2), size: 0.03, height: 0.045,
                      shape: .capsule(angleDegrees: 0), symbol: "line.3.horizontal", inputs: .button(9),
                      note: "OPTIONS; GameController reports it as its Menu button", callout: .above),

        // Left wing: the four separate arrows, joined under one cross.
        PlacedControl(id: "dpad", kind: .dpad, center: CGPoint(x: 0.19, y: 0.37), size: 0.16, shape: .crossPad,
                      inputs: .hat(0), callout: .below),

        // Right wing: the face buttons in Sony's colors.
        PlacedControl(id: "triangle", kind: .faceButton, center: CGPoint(x: 0.81, y: 0.245), size: 0.062, tint: .psGreen,
                      inputs: .button(3), callout: .above),
        PlacedControl(id: "square", kind: .faceButton, center: CGPoint(x: 0.735, y: 0.37), size: 0.062, tint: .psPink,
                      inputs: .button(2), callout: .left),
        PlacedControl(id: "circle", kind: .faceButton, center: CGPoint(x: 0.885, y: 0.37), size: 0.062, tint: .psRed,
                      inputs: .button(1), callout: .right),
        PlacedControl(id: "cross", kind: .faceButton, center: CGPoint(x: 0.81, y: 0.495), size: 0.062, tint: .psBlue,
                      inputs: .button(0), callout: .below),

        // Center: both sticks low and symmetric, the PS button between them.
        PlacedControl(id: "lstick", kind: .stick, center: CGPoint(x: 0.335, y: 0.6), size: 0.13,
                      inputs: .stick(x: 0, y: 1, press: 11), callout: .below),
        PlacedControl(id: "rstick", kind: .stick, center: CGPoint(x: 0.665, y: 0.6), size: 0.13,
                      inputs: .stick(x: 2, y: 3, press: 12), callout: .below),
        PlacedControl(id: "ps", kind: .homeButton, center: CGPoint(x: 0.5, y: 0.55), size: 0.055,
                      inputs: .button(10), note: "macOS opens Launchpad on the PS button unless a preset uses it", callout: .above),
    ]
}
