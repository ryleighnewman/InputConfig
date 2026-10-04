import Foundation
import CoreGraphics

extension ControllerLayout {
    /// Thrustmaster T.16000M (and T.16000M FCS), USB 044F:B10A. A symmetric,
    /// ambidextrous Hall effect stick on a near square base (220 mm wide,
    /// 214 mm deep).
    ///
    /// Drawn from above, the pilot at the bottom, as the user manual's
    /// figure 3 shows it:
    /// - top band: the grip head seen from above. The trigger (1) points
    ///   away from the pilot, the 8-way hat sits on top, the ridged buttons
    ///   3 and 4 flank it, and button 2 is on the head's rear face under the
    ///   hat.
    /// - front: the base. The stick gate (X/Y) in the middle, the twist
    ///   rudder (Rz) on the hand rest just behind it, the throttle lever in
    ///   its slot at the pilot's edge, and the two 2 by 3 button clusters
    ///   either side of the stick.
    /// - back: the underside, with the RIGHT HANDED / LEFT HANDED switch.
    ///
    /// Read path: raw HID only. GameController does not list flight sticks
    /// and Thrustmaster is not in RawHIDGamepadService.gameControllerVendors,
    /// ControllerProfileDatabase has no entry and the SDL data has no row, so
    /// HIDDescriptorParser builds the profile from the descriptor: 16
    /// Button page bits are btn 0 to 15 in order (printed numbers are one
    /// higher), the hat is hat 0, X and Y are axes 0 and 1, Rz has no partner
    /// so it takes the first free stick slot, axis 2, and the Slider (0x36)
    /// takes trigger slot 4 as a 0...1 axis. With 16 buttons nothing is
    /// mirrored onto buttons 6 and 7.
    ///
    /// The green backlight in the stick's boot (lit while the stick moves)
    /// is not an input and is not drawn.
    static let thrustmasterT16000M = ControllerLayout(
        id: .thrustmasterT16000M,
        displayName: "Thrustmaster T.16000M",
        maker: .arcadeAndSim,
        family: nil,
        modelNames: ButtonNames.ModelNames(renamed: t16000mButtonNames),
        aspect: 1.03,
        topStrip: 0.3,
        backStrip: 0.12,
        silhouette: Silhouette(front: t16000mBase, top: t16000mHead,
                               back: Silhouette.roundedRectOps(corner: 0.08, inset: 0.04)),
        controls: t16000mControls,
        match: [[.vidPid(vendor: 0x044F, products: [0xB10A])]],
        matchPriority: 10,
        approximate: true,
        sources: [
            "Thrustmaster T.16000M user manual, ts.thrustmaster.com/download/accessories/Manuals/T16000M/T16000M-User_manual.pdf (figures 1 to 4: control callouts, button numbering per handedness, axis ranges)",
            "thrustmaster.com/en-us/products/t-16000m-fcs product page and gallery photos (pilot view and three quarter views)",
            "Thrustmaster T.16000M FCS specifications: 220 x 214 x 242 mm (width, depth, height)",
            "InputConfig HIDDescriptorParser.swift axis and button slot assignment (buttons in bit order, Rz to slot 2, Slider to slot 4)",
        ]
    )

    /// Every button's name, by its printed (one based) number: the
    /// generic raw HID names are zero based ("Button 0").
    static let t16000mButtonNames: [Int: String] = Dictionary(uniqueKeysWithValues: (0..<16).map { i in
        (i, i == 0 ? "Trigger" : "Button \(i + 1)")
    })

    /// The base from above: a slightly curved far edge, full sides, and a
    /// broad rounded front lip at the pilot's edge where the throttle sits.
    static let t16000mBase: [PathOp] = Silhouette.symmetric([
        .move(0.5, 0.03),
        .curve(0.14, 0.08, c1x: 0.33, c1y: 0.03, c2x: 0.2, c2y: 0.04),
        .curve(0.03, 0.3, c1x: 0.07, c1y: 0.12, c2x: 0.035, c2y: 0.2),
        .curve(0.02, 0.78, c1x: 0.025, c1y: 0.45, c2x: 0.01, c2y: 0.65),
        .curve(0.16, 0.97, c1x: 0.03, c1y: 0.9, c2x: 0.08, c2y: 0.96),
        .curve(0.5, 0.99, c1x: 0.28, c1y: 0.985, c2x: 0.4, c2y: 0.99),
    ])

    /// The grip head from above, about 60 mm across: a rounded front with
    /// the trigger ahead of it, the wings that carry buttons 3 and 4, and a
    /// taper toward the rear where button 2 faces the pilot.
    static let t16000mHead: [PathOp] = Silhouette.symmetric([
        .move(0.5, 0.2),
        .curve(0.375, 0.3, c1x: 0.43, c1y: 0.2, c2x: 0.39, c2y: 0.22),
        .curve(0.355, 0.6, c1x: 0.36, c1y: 0.4, c2x: 0.352, c2y: 0.5),
        .curve(0.42, 0.88, c1x: 0.36, c1y: 0.72, c2x: 0.39, c2y: 0.82),
        .curve(0.5, 0.98, c1x: 0.445, c1y: 0.94, c2x: 0.47, c2y: 0.98),
    ])

    static let t16000mControls: [PlacedControl] = [
        // Top band: the grip head from above, the trigger farthest from the pilot.
        PlacedControl(id: "trigger", kind: .trigger(.digital), face: .top, center: CGPoint(x: 0.5, y: 0.167), size: 0.07, height: 0.045,
                      shape: .roundedRect(corner: 0.4), printed: "1", inputs: .button(0),
                      note: "Digital trigger on the front of the grip", callout: .above),
        // The 8-way hat reads as hat 0. Drawn as a D-pad so its directions
        // light; the canvas draws a .hat control as a plain button.
        PlacedControl(id: "hat", kind: .dpad, face: .top, center: CGPoint(x: 0.5, y: 0.45), size: 0.09, shape: .crossPad,
                      inputs: .hat(0), note: "8-way point of view hat", callout: .below),
        PlacedControl(id: "b3", kind: .gripButton, face: .top, center: CGPoint(x: 0.39, y: 0.5), size: 0.055, height: 0.085,
                      shape: .roundedRect(corner: 0.35), printed: "3", inputs: .button(2), callout: .above),
        PlacedControl(id: "b4", kind: .gripButton, face: .top, center: CGPoint(x: 0.61, y: 0.5), size: 0.055, height: 0.085,
                      shape: .roundedRect(corner: 0.35), printed: "4", inputs: .button(3), callout: .above),
        PlacedControl(id: "b2", kind: .gripButton, face: .top, center: CGPoint(x: 0.5, y: 0.817), size: 0.065, height: 0.045,
                      shape: .roundedRect(corner: 0.35), printed: "2", inputs: .button(1),
                      note: "On the rear of the head, under the hat, for the thumb", callout: .below),

        // Front: the base from above. The stick gate at the center.
        PlacedControl(id: "stick", kind: .stick, center: CGPoint(x: 0.5, y: 0.4), size: 0.2,
                      inputs: .stick(x: 0, y: 1, press: nil),
                      note: "Hall effect X and Y, 14 bit; forward reads up", callout: .below),
        // Twisting the grip (rudder) is Rz, which the descriptor parser
        // puts on axis 2. The manual marks 255 at the left end of the twist
        // and 0 at the right, so a right twist reads negative.
        PlacedControl(id: "twist", kind: .dial, center: CGPoint(x: 0.5, y: 0.585), size: 0.26, height: 0.05,
                      shape: .capsule(angleDegrees: 0), printed: "Twist", inputs: ControlInputs(axes: [.x(2)]),
                      note: "Twist rudder (Rz), on the hand rest", callout: .below),
        // The throttle lever slides fore and aft in a slot at the pilot's
        // edge. Slider 0x36 reads as unipolar axis 4; the manual marks the
        // forward (+) end 0, so full throttle reads 0.
        PlacedControl(id: "throttle", kind: .slider, center: CGPoint(x: 0.5, y: 0.8), size: 0.065, height: 0.17,
                      shape: .roundedRect(corner: 0.35), printed: "Throttle", inputs: ControlInputs(axes: [.analog(4)]),
                      note: "Throttle lever; forward reads 0 and back reads full", callout: .below),

        // Left cluster (RIGHT HANDED setting): far row 5, 6, 7 from the
        // outside in, near row 10, 9, 8. The rows step toward the pilot
        // nearer the stick.
        PlacedControl(id: "b5", kind: .key, center: CGPoint(x: 0.125, y: 0.26), size: 0.058, height: 0.06,
                      shape: .roundedRect(corner: 0.25), printed: "5", inputs: .button(4),
                      note: "LEFT HANDED on the base switch swaps the two clusters", callout: .below),
        PlacedControl(id: "b6", kind: .key, center: CGPoint(x: 0.191, y: 0.275), size: 0.058, height: 0.06,
                      shape: .roundedRect(corner: 0.25), printed: "6", inputs: .button(5),
                      note: "LEFT HANDED on the base switch swaps the two clusters", callout: .below),
        PlacedControl(id: "b7", kind: .key, center: CGPoint(x: 0.257, y: 0.29), size: 0.058, height: 0.06,
                      shape: .roundedRect(corner: 0.25), printed: "7", inputs: .button(6),
                      note: "LEFT HANDED on the base switch swaps the two clusters", callout: .below),
        PlacedControl(id: "b10", kind: .key, center: CGPoint(x: 0.125, y: 0.38), size: 0.058, height: 0.06,
                      shape: .roundedRect(corner: 0.25), printed: "10", inputs: .button(9),
                      note: "LEFT HANDED on the base switch swaps the two clusters", callout: .below),
        PlacedControl(id: "b9", kind: .key, center: CGPoint(x: 0.191, y: 0.395), size: 0.058, height: 0.06,
                      shape: .roundedRect(corner: 0.25), printed: "9", inputs: .button(8),
                      note: "LEFT HANDED on the base switch swaps the two clusters", callout: .below),
        PlacedControl(id: "b8", kind: .key, center: CGPoint(x: 0.257, y: 0.41), size: 0.058, height: 0.06,
                      shape: .roundedRect(corner: 0.25), printed: "8", inputs: .button(7),
                      note: "LEFT HANDED on the base switch swaps the two clusters", callout: .below),

        // Right cluster (RIGHT HANDED setting), the mirror: far row 13, 12,
        // 11 from the inside out, near row 14, 15, 16.
        PlacedControl(id: "b11", kind: .key, center: CGPoint(x: 0.875, y: 0.26), size: 0.058, height: 0.06,
                      shape: .roundedRect(corner: 0.25), printed: "11", inputs: .button(10),
                      note: "LEFT HANDED on the base switch swaps the two clusters", callout: .below),
        PlacedControl(id: "b12", kind: .key, center: CGPoint(x: 0.809, y: 0.275), size: 0.058, height: 0.06,
                      shape: .roundedRect(corner: 0.25), printed: "12", inputs: .button(11),
                      note: "LEFT HANDED on the base switch swaps the two clusters", callout: .below),
        PlacedControl(id: "b13", kind: .key, center: CGPoint(x: 0.743, y: 0.29), size: 0.058, height: 0.06,
                      shape: .roundedRect(corner: 0.25), printed: "13", inputs: .button(12),
                      note: "LEFT HANDED on the base switch swaps the two clusters", callout: .below),
        PlacedControl(id: "b16", kind: .key, center: CGPoint(x: 0.875, y: 0.38), size: 0.058, height: 0.06,
                      shape: .roundedRect(corner: 0.25), printed: "16", inputs: .button(15),
                      note: "LEFT HANDED on the base switch swaps the two clusters", callout: .below),
        PlacedControl(id: "b15", kind: .key, center: CGPoint(x: 0.809, y: 0.395), size: 0.058, height: 0.06,
                      shape: .roundedRect(corner: 0.25), printed: "15", inputs: .button(14),
                      note: "LEFT HANDED on the base switch swaps the two clusters", callout: .below),
        PlacedControl(id: "b14", kind: .key, center: CGPoint(x: 0.743, y: 0.41), size: 0.058, height: 0.06,
                      shape: .roundedRect(corner: 0.25), printed: "14", inputs: .button(13),
                      note: "LEFT HANDED on the base switch swaps the two clusters", callout: .below),

        // Back: the underside. The handedness switch remaps the base
        // clusters inside the stick and sends nothing itself.
        PlacedControl(id: "hand-switch", kind: .other, face: .back, center: CGPoint(x: 0.22, y: 0.55), size: 0.07, height: 0.03,
                      shape: .capsule(angleDegrees: 0), printed: "L R",
                      readable: .notReported("A slide switch under the base: LEFT HANDED swaps which cluster reads 5 to 10 and which 11 to 16. It sends no input."),
                      note: "Right or left handed button selector", callout: .below),
    ]
}
