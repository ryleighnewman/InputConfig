import Foundation
import CoreGraphics

extension ControllerLayout {
    /// PlayStation DualShock 3 (CECHZC2), read only on the raw HID path over
    /// USB (ControllerProfileDatabase "sony-dualshock-3", decoded by
    /// HIDReportDecoder.decodeDualShock3). GameController never lists it and
    /// Bluetooth is not supported. The classic DualShock body, about 160 mm
    /// wide by 97 mm deep: a broad flat top, two long grips with a deep arch
    /// between them, the D-pad and the action buttons level in the upper
    /// wings, SELECT and START between them, the PS button below those, and
    /// the two sticks low and inward just above the arch.
    ///
    /// What the decoder reads: btn 0 to 12, hat 0, axes 0 to 5. Every
    /// action button, the D-pad arrows, L1 and R1 are pressure-sensitive on
    /// the hardware, but only L2 and R2 pressure (report bytes 18 and 19) is
    /// read; the other ten pressures, the SIXAXIS motion sensor, battery,
    /// rumble and the port lights are not.
    static let dualShock3 = ControllerLayout(
        id: .dualShock3,
        displayName: "DualShock 3",
        maker: .sony,
        family: .playstation,
        modelNames: ButtonNames.ModelNames.of(brand: nil, dualShock3: true),
        aspect: 1.65,
        topStrip: 0.2,
        backStrip: 0.16,
        silhouette: Silhouette(
            front: Silhouette.symmetric([
                // Top center, the slight dip at the USB connector.
                .move(0.5, 0.05),
                // Out along the flat top to the shoulder.
                .curve(0.24, 0.03, c1x: 0.4, c1y: 0.05, c2x: 0.32, c2y: 0.03),
                // The rounded shoulder corner.
                .curve(0.06, 0.17, c1x: 0.14, c1y: 0.03, c2x: 0.08, c2y: 0.08),
                // Down the side, easing outward to the grip.
                .curve(0.025, 0.55, c1x: 0.04, c1y: 0.28, c2x: 0.02, c2y: 0.42),
                // The grip's outer edge down to its rounded end.
                .curve(0.12, 0.97, c1x: 0.03, c1y: 0.75, c2x: 0.06, c2y: 0.95),
                .curve(0.245, 0.92, c1x: 0.18, c1y: 0.99, c2x: 0.225, c2y: 0.97),
                // Up the grip's inner edge.
                .curve(0.315, 0.765, c1x: 0.265, c1y: 0.86, c2x: 0.29, c2y: 0.79),
                // The arch under the sticks to the center line.
                .curve(0.5, 0.72, c1x: 0.37, c1y: 0.735, c2x: 0.44, c2y: 0.72),
            ]),
            top: Silhouette.roundedRectOps(corner: 0.18, inset: 0.04),
            back: Silhouette.roundedRectOps(corner: 0.3, inset: 0.04)
        ),
        controls: [
            // Top: L1 and R1 flat, nearest the face; the curved L2 and R2
            // triggers behind them; the Mini-USB connector between.
            PlacedControl(id: "l2", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.2, y: 0.15), size: 0.15, height: 0.13,
                          shape: .roundedRect(corner: 0.35), inputs: .trigger(axis: 4, digital: 6),
                          note: "Pressure is read (report byte 18)", callout: .above),
            PlacedControl(id: "r2", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.8, y: 0.15), size: 0.15, height: 0.13,
                          shape: .roundedRect(corner: 0.35), inputs: .trigger(axis: 5, digital: 7),
                          note: "Pressure is read (report byte 19)", callout: .above),
            PlacedControl(id: "l1", kind: .shoulder, face: .top, center: CGPoint(x: 0.2, y: 0.72), size: 0.16, height: 0.05,
                          shape: .capsule(angleDegrees: 0), inputs: .button(4),
                          note: "Pressure-sensitive; only on and off is read", callout: .below),
            PlacedControl(id: "r1", kind: .shoulder, face: .top, center: CGPoint(x: 0.8, y: 0.72), size: 0.16, height: 0.05,
                          shape: .capsule(angleDegrees: 0), inputs: .button(5),
                          note: "Pressure-sensitive; only on and off is read", callout: .below),
            PlacedControl(id: "usb", kind: .port, face: .top, center: CGPoint(x: 0.5, y: 0.5), size: 0.045, height: 0.02,
                          shape: .roundedRect(corner: 0.2), note: "Mini-USB. The app reads this pad over USB only"),

            // Front, top center: the four port indicators, numbered 1 to 4.
            PlacedControl(id: "portLights", kind: .light, center: CGPoint(x: 0.5, y: 0.06), size: 0.1, height: 0.018,
                          shape: .capsule(angleDegrees: 0), printed: "1 2 3 4",
                          readable: .notReported("No output report is sent, so the Mac never sets the port lights"),
                          note: "Port indicators 1 to 4"),
            // Left wing: four separate pressure-sensitive arrows.
            PlacedControl(id: "dpad", kind: .dpad, center: CGPoint(x: 0.205, y: 0.37), size: 0.165, shape: .fourButtonPad,
                          inputs: .hat(0), note: "Pressure-sensitive; pressure is not read", callout: .above),
            // Right wing: the action buttons, level with the D-pad.
            PlacedControl(id: "triangle", kind: .faceButton, center: CGPoint(x: 0.795, y: 0.255), size: 0.062, tint: .psGreen,
                          inputs: .button(3), note: "Pressure-sensitive; only on and off is read", callout: .above),
            PlacedControl(id: "square", kind: .faceButton, center: CGPoint(x: 0.725, y: 0.37), size: 0.062, tint: .psPink,
                          inputs: .button(2), note: "Pressure-sensitive; only on and off is read", callout: .left),
            PlacedControl(id: "circle", kind: .faceButton, center: CGPoint(x: 0.865, y: 0.37), size: 0.062, tint: .psRed,
                          inputs: .button(1), note: "Pressure-sensitive; only on and off is read", callout: .right),
            PlacedControl(id: "cross", kind: .faceButton, center: CGPoint(x: 0.795, y: 0.485), size: 0.062, tint: .psBlue,
                          inputs: .button(0), note: "Pressure-sensitive; only on and off is read", callout: .below),
            // Center: SELECT (a flat oblong) and START (a right-pointing
            // triangle) level with the wings, the PS button below them.
            PlacedControl(id: "select", kind: .menuButton, center: CGPoint(x: 0.405, y: 0.37), size: 0.05, height: 0.026,
                          shape: .capsule(angleDegrees: 0), printed: "SEL", inputs: .button(8), note: "SELECT", callout: .below, name: "Select"),
            PlacedControl(id: "start", kind: .menuButton, center: CGPoint(x: 0.595, y: 0.37), size: 0.05, height: 0.026,
                          shape: .capsule(angleDegrees: 0), symbol: "play.fill", inputs: .button(9),
                          note: "START, the triangular button", callout: .below),
            PlacedControl(id: "ps", kind: .homeButton, center: CGPoint(x: 0.5, y: 0.49), size: 0.062,
                          inputs: .button(10), callout: .above),
            // Lower center: the sticks, low and inward over the arch.
            PlacedControl(id: "lstick", kind: .stick, center: CGPoint(x: 0.35, y: 0.585), size: 0.13,
                          inputs: .stick(x: 0, y: 1, press: 11), callout: .below),
            PlacedControl(id: "rstick", kind: .stick, center: CGPoint(x: 0.65, y: 0.585), size: 0.13,
                          inputs: .stick(x: 2, y: 3, press: 12), callout: .below),
            // The SIXAXIS sensor is inside the body; drawn here so the
            // inspector can say it exists and is not read.
            PlacedControl(id: "sixaxis", kind: .other, center: CGPoint(x: 0.5, y: 0.615), size: 0.06, height: 0.022,
                          shape: .capsule(angleDegrees: 0), printed: "Gyro",
                          readable: .notReported("The SIXAXIS accelerometer and gyro (report bytes 41 to 48) are not decoded"),
                          note: "SIXAXIS motion sensor, inside the body"),

            // Back, as held: the reset pinhole beside L2, on the player's left.
            PlacedControl(id: "reset", kind: .other, face: .back, center: CGPoint(x: 0.24, y: 0.3), size: 0.025,
                          readable: .notReported("A hardware reset pinhole, not an input"),
                          note: "Reset button, near L2"),
        ],
        match: [
            [.rawProfileLayout("dualShock3")],
            [.vidPid(vendor: 0x054C, products: [0x0268])],
        ],
        // Above the DualShock 4: a DS3 read directly is branded .dualShock4
        // by the vendor fallback, so a brand rule there would also match it.
        matchPriority: 30,
        readability: .partial("USB only. Ten of the twelve button pressures, the SIXAXIS motion sensor, rumble and the port lights are not read"),
        approximate: true,
        sources: [
            "dimensions.com DualShock 3 Controller (160 x 97 x 55 mm)",
            "PlayStation DUALSHOCK 3 instruction manual CECHZC2 and PS3 user's guide (part names; reset button on the rear near L2)",
            "SDL src/joystick/hidapi/SDL_hidapi_ps3.c (HandleStatePacket byte offsets)",
            "SDL src/joystick/hidapi/SDL_hidapi_ps3.c (Sixaxis report and operational mode)",
        ]
    )
}
