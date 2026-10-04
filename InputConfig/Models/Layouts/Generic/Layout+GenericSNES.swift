import Foundation
import CoreGraphics

extension ControllerLayout {
    /// A wired USB SNES-style pad (Tomee, Retrolink, iBuffalo, Kiwitata and
    /// the many unbranded copies): the flat Super Nintendo dog-bone, about
    /// 144 mm wide and 61 mm tall, with a +Control Pad on the left lobe, an
    /// A, B, X, Y diamond on the right lobe (X top, A right, B bottom, Y
    /// left), angled SELECT and START pills in the middle, L and R on the
    /// top corners, and the USB cable leaving the top edge between them.
    /// No sticks, triggers, HOME, motion or rumble.
    ///
    /// Not matched to a connected pad by rules: it is the fallback a group
    /// infers (a descriptor with no sticks and an axis D-pad) or the one a
    /// user picks, so it has no match rules.
    ///
    /// Read raw by RawHIDGamepadService, one of two ways:
    /// - rawSDL: a bundled SDL GameControllerDB row (Tomee 12BD:D015, NEXT
    ///   0810:E501, Retrolink 0079:0011, iBuffalo 0583:2060). SDL rows name
    ///   the face buttons by position, so btn 0 is the bottom button (B), 1
    ///   the right (A), 2 the left (Y), 3 the top (X), L 4, R 5, SELECT 8,
    ///   START 9. The row's axis D-pad (dpup:-a1 and so on) is folded into
    ///   hat 0 and its axes are not reported as axes.
    /// - rawDescriptor: no row, so HIDDescriptorParser numbers the buttons
    ///   in HID order and the D-pad stays the X and Y axes (axes 0 and 1).
    ///   The common clone chips send HID button 1 X, 2 A, 3 B, 4 Y, 5 L,
    ///   6 R, 9 SELECT, 10 START (the order every SDL row above decodes),
    ///   so btn 0 X, 1 A, 2 B, 3 Y, 4 L, 5 R, 8 SELECT, 9 START. Other
    ///   chips number them differently (iBuffalo sends A, B, X, Y first);
    ///   those positions are an estimate.
    ///
    /// The positional numbering is the Nintendo scheme every Nintendo
    /// layout uses (btn 0 bottom, 1 right, 2 left, 3 top).
    static let genericSNES = ControllerLayout(
        id: .genericSNES,
        displayName: "SNES-style USB pad",
        maker: .generic,
        family: .nintendo,
        // SELECT and START are printed where a Switch pad has Minus and
        // Plus, and it has nothing on the other Switch slots.
        modelNames: ButtonNames.ModelNames(renamed: [8: "Select", 9: "Start"],
                                           short: [8: "SEL", 9: "STRT"],
                                           absent: [6, 7, 10, 11, 12, 13, 14, 15, 16, 17]),
        aspect: 144.0 / 61.0,
        topStrip: 0.14,
        backStrip: 0,
        silhouette: Silhouette(front: genericSNESFront, top: genericSNESTop),
        controls: genericSNESControls,
        offBody: genericSNESOffBody,
        approximate: true,
        sources: [
            "dimensions.com SNES Controller: 144 mm wide, 61 mm tall (USB copies follow the same shell)",
            "SDL gamecontrollerdb.txt macOS rows bundled in SDLGameControllerDBData.swift: Tomee SNES Controller 12BD:D015, NEXT SNES Controller 0810:E501, Retrolink SNES Controller 0079:0011, iBuffalo Super Famicom Controller 0583:2060",
            "adafruit.com product 6285, USB Game Controller with SNES-like Layout: D-pad, L and R, Select and Start, A, B, X, Y",
            "pishop.us SNES Retro Game Controller USB product photos for placement",
            "Super Famicom and PAL SNES button colors: A red, B yellow, X blue, Y green, copied by most USB clones",
        ]
    )

    /// The front outline: two round lobes the full height of the pad, a
    /// waist whose top edge dips a little and whose bottom arches up.
    static let genericSNESFront: [PathOp] = Silhouette.symmetric([
        .move(0.5, 0.07),
        .curve(0.21, 0.01, c1x: 0.4, c1y: 0.07, c2x: 0.3, c2y: 0.01),
        .curve(0.008, 0.5, c1x: 0.097, c1y: 0.01, c2x: 0.008, c2y: 0.23),
        .curve(0.21, 0.99, c1x: 0.008, c1y: 0.77, c2x: 0.097, c2y: 0.99),
        .curve(0.5, 0.87, c1x: 0.31, c1y: 0.99, c2x: 0.4, c2y: 0.87),
    ])

    /// The top edge from above: full thickness at the lobes, thinner across
    /// the middle on the rear side.
    static let genericSNESTop: [PathOp] = Silhouette.symmetric([
        .move(0.5, 0.24),
        .curve(0.08, 0.06, c1x: 0.35, c1y: 0.22, c2x: 0.2, c2y: 0.06),
        .curve(0.012, 0.5, c1x: 0.035, c1y: 0.06, c2x: 0.012, c2y: 0.25),
        .curve(0.08, 0.95, c1x: 0.012, c1y: 0.75, c2x: 0.035, c2y: 0.95),
        .curve(0.5, 0.88, c1x: 0.2, c1y: 0.95, c2x: 0.35, c2y: 0.88),
    ])

    static let genericSNESControls: [PlacedControl] = [
        // Top edge: L and R wrap the top corners; the cable leaves between.
        PlacedControl(id: "l", kind: .shoulder, face: .top, center: CGPoint(x: 0.16, y: 0.6), size: 0.19, height: 0.05,
                      shape: .capsule(angleDegrees: 0), inputs: .button(4), callout: .below),
        PlacedControl(id: "cable", kind: .port, face: .top, center: CGPoint(x: 0.5, y: 0.4), size: 0.03, height: 0.03,
                      shape: .circle, note: "The USB cable leaves the top edge here; it is not an input"),
        PlacedControl(id: "r", kind: .shoulder, face: .top, center: CGPoint(x: 0.84, y: 0.6), size: 0.19, height: 0.05,
                      shape: .capsule(angleDegrees: 0), inputs: .button(5), callout: .below),

        // Front, left lobe: the +Control Pad. An SDL row folds the axis
        // D-pad into hat 0; with no row it stays axes 0 and 1.
        PlacedControl(id: "dpad", kind: .dpad, center: CGPoint(x: 0.205, y: 0.5), size: 0.15, shape: .crossPad,
                      inputs: ControlInputs(axes: [.x(0), .y(1)], hat: 0),
                      pathInputs: [.rawSDL: .hat(0), .rawDescriptor: ControlInputs(axes: [.x(0), .y(1)])],
                      note: "Sent as the X and Y axes. Hat 0 when an SDL row knows the pad, axes 0 and 1 when it does not",
                      callout: .below),

        // Front, middle: SELECT and START, angled pills rising to the right.
        PlacedControl(id: "select", kind: .menuButton, center: CGPoint(x: 0.44, y: 0.6), size: 0.08, height: 0.03,
                      shape: .capsule(angleDegrees: -40), printed: "SEL", inputs: .button(8),
                      note: "SELECT", callout: .below),
        PlacedControl(id: "start", kind: .menuButton, center: CGPoint(x: 0.56, y: 0.6), size: 0.08, height: 0.03,
                      shape: .capsule(angleDegrees: -40), printed: "STRT", inputs: .button(9),
                      note: "START", callout: .below),

        // Front, right lobe: the diamond in the Super Famicom colors most
        // clones print. Positional numbering on the SDL path (see the top);
        // the descriptor path is the common clone chip's HID order.
        PlacedControl(id: "x", kind: .faceButton, center: CGPoint(x: 0.79, y: 0.33), size: 0.072, printed: "X",
                      tint: .snesBlue, inputs: .button(3), pathInputs: [.rawDescriptor: .button(0)],
                      note: "Top button. Btn 0 when no SDL row knows the pad", callout: .above),
        PlacedControl(id: "y", kind: .faceButton, center: CGPoint(x: 0.715, y: 0.5), size: 0.072, printed: "Y",
                      tint: .snesGreen, inputs: .button(2), pathInputs: [.rawDescriptor: .button(3)],
                      note: "Left button. Btn 3 when no SDL row knows the pad", callout: .left),
        PlacedControl(id: "a", kind: .faceButton, center: CGPoint(x: 0.865, y: 0.5), size: 0.072, printed: "A",
                      tint: .snesRed, inputs: .button(1), pathInputs: [.rawDescriptor: .button(1)],
                      note: "Right button", callout: .right),
        PlacedControl(id: "b", kind: .faceButton, center: CGPoint(x: 0.79, y: 0.67), size: 0.072, printed: "B",
                      tint: .snesYellow, inputs: .button(0), pathInputs: [.rawDescriptor: .button(2)],
                      note: "Bottom button. Btn 2 when no SDL row knows the pad", callout: .below),
    ]

    /// Buttons the clone chips declare but do not wire: HID buttons 7 and 8
    /// sit between R and SELECT. With no SDL row they read as btn 6 and 7;
    /// with a row (which names b8 and b9 as SELECT and START) they land on
    /// the first extra slots. None ever presses.
    static let genericSNESOffBody: [OffBodyInput] = [
        OffBodyInput(serialized: "btn 6", reason: "Descriptor read only: HID button 7, declared by the clone chip but not wired to a control"),
        OffBodyInput(serialized: "btn 7", reason: "Descriptor read only: HID button 8, declared by the clone chip but not wired to a control"),
        OffBodyInput(serialized: "btn 22", reason: "SDL read only: HID button 7, which the row leaves out and the pad never presses"),
        OffBodyInput(serialized: "btn 23", reason: "SDL read only: HID button 8, which the row leaves out and the pad never presses"),
    ]
}
