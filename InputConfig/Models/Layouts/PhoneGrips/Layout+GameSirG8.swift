import Foundation
import CoreGraphics

extension ControllerLayout {
    /// GameSir G8 Galileo, the telescoping USB-C phone controller (217 x 107
    /// x 54 mm closed, 110 to 185 mm phones). Drawn holding a 6.1 inch phone,
    /// about 258 mm across, so the front is about 2.6 times as wide as tall.
    /// Each grip is a full console style half that hangs well below the
    /// phone. Left grip: View at the inner top corner beside the phone, the
    /// left stick high, the D-pad below it, then Capture and M side by side
    /// (the mode light sits beside M). Right grip: Menu at the inner top
    /// corner, A B X Y high (printed in two shades of purple, not Xbox
    /// colors, so no tint), the right stick below, then the round GameSir
    /// (Home) button, ringed by the connection light. LB and LT on top of
    /// each grip. L4 and R4 are small square buttons on the back of each
    /// grip, where the middle fingers rest.
    ///
    /// Positions are measured from GameSir's straight-on product render
    /// (gamesir.com) and its rear photo; the lights are not drawn because
    /// the app cannot read or set them.
    ///
    /// Inputs: the G8 is read through GameController as a generic extended
    /// gamepad (ControllerTypeDetector gives .mfiGeneric), so
    /// GameControllerService.readControllerState numbers it: A B X Y btn 0
    /// to 3 by position (A bottom, B right, X left, Y top), LB RB btn 4 and
    /// 5, LT RT axis 4 and 5 with digital copies btn 6 and 7, View
    /// (buttonOptions) btn 8, Menu btn 9, Home (buttonHome) btn 10, stick
    /// clicks btn 11 and 12, sticks axis 0/1 and 2/3, D-pad hat 0. Capture
    /// reaches btn 14 only if macOS lists it as a Share or Capture element
    /// (knownButtonMap and the name fallback in cacheExtraButtons). M, L4 and
    /// R4 are firmware keys: M programs L4 and R4 (hold M and L4 or R4, then
    /// press the button to copy), and the Mac then sees the copied button,
    /// never L4 or R4 themselves. Holding View and Menu for two seconds
    /// switches the controller's mode, which changes how it presents itself.
    static let gameSirG8 = ControllerLayout(
        id: .gameSirG8,
        displayName: "GameSir G8 Galileo",
        maker: .phoneGrip,
        family: .xbox,
        modelNames: ButtonNames.ModelNames(renamed: [10: "Home", 14: "Capture"], short: [10: "Home"],
                                           absent: [13, 15, 16, 17, 18, 19, 20, 21]),
        aspect: 2.6,
        topStrip: 0.2,
        backStrip: 0.24,
        silhouette: Silhouette(
            front: Silhouette.symmetric(gameSirG8FrontLeft) + gameSirG8Screen,
            top: Silhouette.symmetric(gameSirG8TopLeft),
            back: Silhouette.symmetric(gameSirG8BackLeft)
        ),
        controls: gameSirG8Controls,
        // GameController names the pad by its USB product string, and a raw
        // HID read by its manufacturer and product strings; both carry
        // GameSir and G8. No other catalog model says either.
        match: [
            [.gcVendorNameContains("GameSir"), .gcVendorNameContains("G8")],
            [.gcProductCategoryContains("GameSir"), .gcProductCategoryContains("G8")],
            [.gcVendorNameContains("GameSir"), .gcProductCategoryContains("G8")],
        ],
        matchPriority: 10,
        approximate: true,
        sources: [
            "gamesir.com G8 Galileo product page (front render, rear photo, specifications: 217 x 107 x 54 mm, 2 back buttons, Hall effect sticks and triggers)",
            "gamesir.com G8 Galileo page: iPhone 15 users, View plus Menu held 2 seconds switches modes",
            "GameSir G8 Galileo user manual (manuals.plus): View, LS, D-pad, mode light, Capture, M; Menu, ABXY, RS, connection light, Home; L4 and R4 on the back; M plus L4 or R4 to program",
            "techaeris.com G8 Galileo review (button list, back buttons on each grip)",
            "androidpolice.com G8 Galileo review (M at the bottom left, full size grips)",
        ]
    )

    /// The front outline's left half, with the phone filling the middle:
    /// the phone's top edge, the notch where the phone's corner meets the
    /// grip, the grip's rounded peak a little above the phone, the outer
    /// side bulging out as it falls, the grip tip well below the phone, and
    /// the inner edge rising to the rail under the phone.
    static let gameSirG8FrontLeft: [PathOp] = [
        .move(0.5, 0.022),
        .line(0.25, 0.022),
        .quad(0.214, 0.06, cx: 0.214, cy: 0.022),
        .curve(0.165, 0.002, c1x: 0.205, c1y: 0.02, c2x: 0.19, c2y: 0.0),
        .curve(0.084, 0.106, c1x: 0.13, c1y: 0.005, c2x: 0.10, c2y: 0.05),
        .curve(0.021, 0.475, c1x: 0.06, c1y: 0.2, c2x: 0.035, c2y: 0.37),
        .curve(0.0, 0.78, c1x: 0.008, c1y: 0.58, c2x: 0.0, c2y: 0.7),
        .curve(0.06, 1.0, c1x: 0.0, c1y: 0.92, c2x: 0.025, c2y: 1.0),
        .curve(0.125, 0.92, c1x: 0.095, c1y: 1.0, c2x: 0.11, c2y: 0.97),
        .curve(0.18, 0.766, c1x: 0.14, c1y: 0.86, c2x: 0.16, c2y: 0.79),
        .quad(0.225, 0.745, cx: 0.2, cy: 0.745),
        .line(0.5, 0.745),
    ]

    /// The phone's screen between the grips, so the cradle reads as holding
    /// a phone. Corners are drawn round on the 2.6 to 1 face.
    static let gameSirG8Screen: [PathOp] = [
        .move(0.27, 0.06), .line(0.73, 0.06), .quad(0.75, 0.112, cx: 0.75, cy: 0.06),
        .line(0.75, 0.648), .quad(0.73, 0.7, cx: 0.75, cy: 0.7), .line(0.27, 0.7),
        .quad(0.25, 0.648, cx: 0.25, cy: 0.7), .line(0.25, 0.112), .quad(0.27, 0.06, cx: 0.25, cy: 0.06),
        .close,
    ]

    /// The top seen from above: each grip is deep (54 mm), the phone and the
    /// telescoping rail between them are a thin slab along the front.
    static let gameSirG8TopLeft: [PathOp] = [
        .move(0.5, 0.5),
        .line(0.226, 0.5),
        .line(0.226, 0.16),
        .quad(0.18, 0.04, cx: 0.226, cy: 0.04),
        .line(0.08, 0.04),
        .curve(0.012, 0.45, c1x: 0.03, c1y: 0.04, c2x: 0.012, c2y: 0.2),
        .curve(0.07, 0.96, c1x: 0.012, c1y: 0.8, c2x: 0.03, c2y: 0.96),
        .line(0.2, 0.96),
        .quad(0.226, 0.88, cx: 0.226, cy: 0.96),
        .line(0.5, 0.88),
    ]

    /// The back as held: a flat shell behind the phone, the grips rising a
    /// little above it and hanging below it.
    static let gameSirG8BackLeft: [PathOp] = [
        .move(0.5, 0.08),
        .line(0.21, 0.08),
        .curve(0.10, 0.02, c1x: 0.17, c1y: 0.08, c2x: 0.14, c2y: 0.02),
        .curve(0.01, 0.45, c1x: 0.04, c1y: 0.02, c2x: 0.01, c2y: 0.2),
        .curve(0.09, 0.98, c1x: 0.01, c1y: 0.75, c2x: 0.03, c2y: 0.98),
        .curve(0.2, 0.82, c1x: 0.15, c1y: 0.98, c2x: 0.18, c2y: 0.9),
        .line(0.5, 0.82),
    ]

    static let gameSirG8Controls: [PlacedControl] = [
        // Top: the triggers behind, the bumpers along the front edge of each grip.
        PlacedControl(id: "lt", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.16, y: 0.17), size: 0.15, height: 0.11,
                      shape: .roundedRect(corner: 0.35), inputs: .trigger(axis: 4, digital: 6),
                      note: "Hall effect; a key combination switches it to a hair trigger in firmware", callout: .above),
        PlacedControl(id: "rt", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.84, y: 0.17), size: 0.15, height: 0.11,
                      shape: .roundedRect(corner: 0.35), inputs: .trigger(axis: 5, digital: 7),
                      note: "Hall effect; a key combination switches it to a hair trigger in firmware", callout: .above),
        PlacedControl(id: "lb", kind: .shoulder, face: .top, center: CGPoint(x: 0.135, y: 0.75), size: 0.11, height: 0.035,
                      shape: .capsule(angleDegrees: 0), inputs: .button(4), callout: .below),
        PlacedControl(id: "rb", kind: .shoulder, face: .top, center: CGPoint(x: 0.865, y: 0.75), size: 0.11, height: 0.035,
                      shape: .capsule(angleDegrees: 0), inputs: .button(5), callout: .below),

        // Left grip: View in the inner top corner, the stick high, the D-pad
        // below it, Capture and M side by side under the D-pad.
        PlacedControl(id: "view", kind: .menuButton, center: CGPoint(x: 0.183, y: 0.11), size: 0.028,
                      symbol: "rectangle.on.rectangle", inputs: .button(8),
                      note: "Held with Menu for two seconds, switches the controller's mode", callout: .above),
        PlacedControl(id: "lstick", kind: .stick, center: CGPoint(x: 0.129, y: 0.215), size: 0.08,
                      inputs: .stick(x: 0, y: 1, press: 11), callout: .below),
        PlacedControl(id: "dpad", kind: .dpad, center: CGPoint(x: 0.129, y: 0.495), size: 0.085, shape: .crossPad,
                      inputs: .hat(0), callout: .below),
        PlacedControl(id: "capture", kind: .menuButton, center: CGPoint(x: 0.106, y: 0.695), size: 0.026, height: 0.02,
                      shape: .roundedRect(corner: 0.3), symbol: "camera", inputs: .button(14),
                      readable: .conditional("Only when macOS lists it as a Share or Capture button"), callout: .below),
        PlacedControl(id: "m", kind: .menuButton, center: CGPoint(x: 0.136, y: 0.695), size: 0.026, height: 0.02,
                      shape: .roundedRect(corner: 0.3), printed: "M",
                      readable: .notReported("A firmware key: it programs L4 and R4 and never reaches the Mac"),
                      callout: .below),

        // Right grip: Menu in the inner top corner, the face buttons high,
        // the stick below them, the GameSir (Home) button under the stick.
        PlacedControl(id: "menu", kind: .menuButton, center: CGPoint(x: 0.82, y: 0.11), size: 0.028,
                      symbol: "line.3.horizontal", inputs: .button(9), callout: .above),
        PlacedControl(id: "y", kind: .faceButton, center: CGPoint(x: 0.876, y: 0.14), size: 0.032,
                      inputs: .button(3), callout: .above),
        PlacedControl(id: "x", kind: .faceButton, center: CGPoint(x: 0.845, y: 0.218), size: 0.032,
                      inputs: .button(2), callout: .left),
        PlacedControl(id: "b", kind: .faceButton, center: CGPoint(x: 0.913, y: 0.231), size: 0.032,
                      inputs: .button(1), callout: .right),
        PlacedControl(id: "a", kind: .faceButton, center: CGPoint(x: 0.88, y: 0.3), size: 0.032,
                      inputs: .button(0),
                      note: "A firmware key combination swaps A with B and X with Y; the Mac then sees the swapped button",
                      callout: .below),
        PlacedControl(id: "rstick", kind: .stick, center: CGPoint(x: 0.877, y: 0.479), size: 0.08,
                      inputs: .stick(x: 2, y: 3, press: 12), callout: .below),
        PlacedControl(id: "home", kind: .homeButton, center: CGPoint(x: 0.877, y: 0.695), size: 0.032,
                      symbol: "house", inputs: .button(10),
                      readable: .conditional("Only when macOS gives the pad a Home button"), callout: .below),

        // Back, as held: L4 behind the left grip, R4 behind the right.
        PlacedControl(id: "l4", kind: .paddle, face: .back, center: CGPoint(x: 0.14, y: 0.6), size: 0.04, height: 0.035,
                      shape: .roundedRect(corner: 0.3), printed: "L4",
                      readable: .notReported("Copies another button in the controller's firmware (hold M and L4, then press that button); the Mac sees the copied button"),
                      callout: .below),
        PlacedControl(id: "r4", kind: .paddle, face: .back, center: CGPoint(x: 0.86, y: 0.6), size: 0.04, height: 0.035,
                      shape: .roundedRect(corner: 0.3), printed: "R4",
                      readable: .notReported("Copies another button in the controller's firmware (hold M and R4, then press that button); the Mac sees the copied button"),
                      callout: .below),
    ]
}
