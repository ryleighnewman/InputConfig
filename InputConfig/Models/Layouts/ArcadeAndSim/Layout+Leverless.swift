import Foundation
import CoreGraphics

extension ControllerLayout {
    /// A leverless (all-button, Hit Box style) fight controller running
    /// GP2040-CE, the open firmware on the Snack Box Micro, the Flatbox, the
    /// Haute42 boxes and most DIY leverless builds. One flat slab played
    /// lying on a table: Left, Down and Right sit side by side at the upper
    /// left under the left ring, middle and index fingers (the A S D of
    /// W A S D), with Right a little lower; Up is the big button low and
    /// toward the center under the left thumb; the eight attack buttons
    /// fill the right half in two staggered rows of four; a row of six small
    /// function buttons runs along the rear edge at the upper left.
    ///
    /// Positions are measured from the open source Flatbox rev5 (jfedor2,
    /// CC BY-SA 4.0), a GP2040-CE leverless whose KiCad board gives every
    /// switch center in millimeters: board 210 by 120 mm, case taken as
    /// 216 by 126 mm (3 mm walls). Caps are drawn 24 mm and Up 30 mm, the
    /// Snack Box Micro sizes. Commercial boxes (Hit Box, Snack Box Micro)
    /// keep the same arrangement at slightly different pitches, and some put
    /// the function buttons on the rear wall instead of the face, so the
    /// layout stays approximate.
    ///
    /// Inputs, in GP2040-CE's Generic (HID) mode, USB 10C4:82C0, product
    /// "GP2040-CE (Generic)". GameController never lists it, so the raw HID
    /// descriptor path reads it (HIDDescriptorParser numbers the 32
    /// Button-page bits in report order with no remapping). HIDDriver.cpp
    /// packs the bits with GamepadState.h's masks, so InputConfig sees:
    /// btn 0 B3 (Square), 1 B1 (Cross), 2 B2 (Circle), 3 B4 (Triangle),
    /// 4 L1, 5 R1, 6 L2, 7 R2, 8 S1, 9 S2, 10 L3, 11 R3, 12 A1 (Home),
    /// 13 A2, 14 A3, 15 A4, 16 Up, 17 Down, 18 Left, 19 Right, 20 to 31
    /// E1 to E12. Every direction is sent twice: as hat 0 and as its button
    /// (16 to 19). X, Y, Z and Rz are declared and read as axes 0 to 3; they
    /// rest centered unless the board's D-pad mode is LS or RS.
    ///
    /// Other modes: PS3 mode enumerates as a DualShock 3 (054C:0268,
    /// "GP2040-CE (PS3)") and is read by the DualShock 3 decoder (the
    /// .rawProfile path): btn 0 Cross, 1 Circle, 2 Square, 3 Triangle,
    /// 4 to 9 as above, 10 PS, 11 L3, 12 R3, L2 and R2 on axes 4 and 5 with
    /// btn 6 and 7, hat 0 only; the touchpad bit (A2) is not decoded. The
    /// PS4, PS5 and Switch Pro modes, when GameController lists them, number
    /// the same way with A2 on btn 13 (touchpad). PS4 mode imitates a Razer
    /// Panthera (1532:0401); when the bundled SDL row for that stick reads
    /// it (.rawSDL), the numbering is the same again, and the raw L2 and R2
    /// bits the row leaves unmapped land on btn 22 and 23. XInput mode is
    /// the XUSB class, which the Mac cannot read.
    static let leverless = ControllerLayout(
        id: .leverless,
        displayName: "Leverless controller",
        maker: .arcadeAndSim,
        family: nil,
        // GP2040-CE's own names on the Generic mode numbering, the path the
        // match rules mostly land on.
        modelNames: ButtonNames.ModelNames(renamed: [
            0: "B3 (Square)", 1: "B1 (Cross)", 2: "B2 (Circle)", 3: "B4 (Triangle)",
            4: "L1", 5: "R1", 6: "L2", 7: "R2",
            8: "S1 (Select)", 9: "S2 (Start)", 10: "L3", 11: "R3",
            12: "A1 (Home)", 13: "A2 (Capture / Touchpad)", 14: "A3", 15: "A4",
            16: "Up (button copy)", 17: "Down (button copy)", 18: "Left (button copy)", 19: "Right (button copy)",
            20: "E1", 21: "E2", 22: "E3", 23: "E4", 24: "E5", 25: "E6",
            26: "E7", 27: "E8", 28: "E9", 29: "E10", 30: "E11", 31: "E12",
        ]),
        aspect: 1.71,
        topStrip: 0,
        backStrip: 0,
        silhouette: Silhouette(front: leverlessFrontOps),
        controls: leverlessControls,
        offBody: [
            OffBodyInput(serialized: "btn 14", reason: "GP2040-CE A3, an extra function input; wired only on some boards"),
            OffBodyInput(serialized: "btn 15", reason: "GP2040-CE A4, an extra function input; wired only on some boards"),
            OffBodyInput(serialized: "btn 20", reason: "GP2040-CE E1, an extra input; wired only on some boards"),
            OffBodyInput(serialized: "btn 21", reason: "GP2040-CE E2, an extra input; wired only on some boards"),
            OffBodyInput(serialized: "btn 22", reason: "GP2040-CE E3, an extra input; wired only on some boards"),
            OffBodyInput(serialized: "btn 23", reason: "GP2040-CE E4, an extra input; wired only on some boards"),
            OffBodyInput(serialized: "btn 24", reason: "GP2040-CE E5, an extra input; wired only on some boards"),
            OffBodyInput(serialized: "btn 25", reason: "GP2040-CE E6, an extra input; wired only on some boards"),
            OffBodyInput(serialized: "btn 26", reason: "GP2040-CE E7, an extra input; wired only on some boards"),
            OffBodyInput(serialized: "btn 27", reason: "GP2040-CE E8, an extra input; wired only on some boards"),
            OffBodyInput(serialized: "btn 28", reason: "GP2040-CE E9, an extra input; wired only on some boards"),
            OffBodyInput(serialized: "btn 29", reason: "GP2040-CE E10, an extra input; wired only on some boards"),
            OffBodyInput(serialized: "btn 30", reason: "GP2040-CE E11, an extra input; wired only on some boards"),
            OffBodyInput(serialized: "btn 31", reason: "GP2040-CE E12, an extra input; wired only on some boards"),
            OffBodyInput(serialized: "axi 0 +", reason: "Left stick X: Left and Right move it (minus and plus) when the board's D-pad mode is LS; centered in the default DP mode"),
            OffBodyInput(serialized: "axi 1 +", reason: "Left stick Y: Up and Down move it (minus and plus) when the board's D-pad mode is LS; centered in the default DP mode"),
            OffBodyInput(serialized: "axi 2 +", reason: "Right stick X: Left and Right move it (minus and plus) when the board's D-pad mode is RS; centered in the default DP mode"),
            OffBodyInput(serialized: "axi 3 +", reason: "Right stick Y: Up and Down move it (minus and plus) when the board's D-pad mode is RS; centered in the default DP mode"),
        ],
        // GP2040-CE has no VID:PID of its own for every mode, so it is known
        // by its USB product string ("GP2040-CE (Generic)", "GP2040-CE (PS3)",
        // "GP2040-CE (PS4)"), which the raw HID path reports as the product
        // name and GameController as the vendor name, and by the 10C4:82C0
        // identity its Generic and PS3 alternate modes use.
        match: [
            [.gcProductCategoryContains("GP2040")],
            [.gcVendorNameContains("GP2040")],
            [.gcProductCategoryContains("Snack Box")],
            [.gcVendorNameContains("Snack Box")],
            [.vidPid(vendor: 0x10C4, products: [0x82C0])],
        ],
        // Above the DualShock 3 (30), whose 054C:0268 rule a board in PS3
        // mode also meets, and above the brand rules of the pads the PS4,
        // PS5 and Switch Pro modes imitate.
        matchPriority: 45,
        readability: .partial("Read in GP2040-CE's Generic and PS3 modes (and the modes GameController lists); XInput mode is not readable, and the button numbers change with the mode"),
        approximate: true,
        sources: [
            "github.com/jfedor2/flatbox hardware-rev5 KiCad board (switch centers in mm, board edge 210 x 120 mm, six function tact switches and their nets)",
            "GP2040-CE configs/FlatboxRev5/BoardConfig.h (which function switch is S1, S2, A1, A2, L3, R3)",
            "GP2040-CE headers/drivers/hid/HIDDescriptors.h and src/drivers/hid/HIDDriver.cpp (Generic mode descriptor, 10C4:82C0, 32 buttons plus hat plus X Y Z Rz, button packing)",
            "GP2040-CE headers/gamepad/GamepadState.h (GAMEPAD_MASK bit numbers)",
            "GP2040-CE headers/drivers/ps3/PS3Descriptors.h (PS3 mode identity and report)",
            "GP2040-CE headers/buttonlayouts.h BUTTON_GROUP_STICKLESS (the firmware's own leverless drawing)",
            "thearcadestick.com Snack Box Micro review (24 mm main buttons, 30 mm Up, six function buttons plus an LED button)",
            "hitboxarcade.com Hit Box info page (Left, Down, Right side by side, Up at the bottom)",
        ],
        // GameController and the SDL rows number it differently (see the
        // pathInputs), so these names only fit the Generic mode descriptor.
        modelNamesPaths: [.rawDescriptor]
    )

    /// The slab: a rounded rectangle with 8.6 mm corners on a 216 by 126 mm
    /// body, so the corner is 0.04 of the width and 0.068 of the height.
    private static let leverlessFrontOps: [PathOp] = {
        let i: CGFloat = 0.01, rx: CGFloat = 0.04, ry: CGFloat = 0.068
        let a = i, b = 1 - i
        return [
            .move(a + rx, a), .line(b - rx, a), .quad(b, a + ry, cx: b, cy: a),
            .line(b, b - ry), .quad(b - rx, b, cx: b, cy: b),
            .line(a + rx, b), .quad(a, b - ry, cx: a, cy: b),
            .line(a, a + ry), .quad(a + rx, a, cx: a, cy: a), .close,
        ]
    }()

    /// Controls. Main buttons are `.key`, not `.faceButton`: the attack grid
    /// is not a compass diamond, so the Positions setting must not letter
    /// them South, East, West, North.
    private static let leverlessControls: [PlacedControl] = [
        // MARK: Function row along the rear edge, upper left (Flatbox
        // order: S2, S1, A1, then A2, L3, R3 after a small gap). Captions
        // alternate above and below so neighbors do not collide.
        PlacedControl(id: "s2", kind: .menuButton, center: CGPoint(x: 0.086, y: 0.127), size: 0.032,
                      printed: "S2", inputs: .button(9), note: "Start / Options / Plus", callout: .above),
        PlacedControl(id: "s1", kind: .menuButton, center: CGPoint(x: 0.132, y: 0.127), size: 0.032,
                      printed: "S1", inputs: .button(8), note: "Select / Share / Minus", callout: .below),
        PlacedControl(id: "a1", kind: .homeButton, center: CGPoint(x: 0.178, y: 0.127), size: 0.032,
                      printed: "A1", inputs: .button(12), pathInputs: [.rawProfile: .button(10), .gameController: .button(10), .rawSDL: .button(10)],
                      note: "Home / PS / Guide", callout: .above),
        PlacedControl(id: "a2", kind: .menuButton, center: CGPoint(x: 0.238, y: 0.127), size: 0.032,
                      printed: "A2", inputs: .button(13), pathInputs: [.rawProfile: ControlInputs.none, .gameController: .button(13), .rawSDL: .button(13)],
                      note: "Capture / Touchpad. PS3 mode sends it, but the DualShock 3 decoder does not read that bit",
                      callout: .below),
        PlacedControl(id: "l3", kind: .menuButton, center: CGPoint(x: 0.285, y: 0.127), size: 0.032,
                      printed: "L3", inputs: .button(10), pathInputs: [.rawProfile: .button(11), .gameController: .button(11), .rawSDL: .button(11)],
                      note: "Left stick press", callout: .above),
        PlacedControl(id: "r3", kind: .menuButton, center: CGPoint(x: 0.331, y: 0.127), size: 0.032,
                      printed: "R3", inputs: .button(11), pathInputs: [.rawProfile: .button(12), .gameController: .button(12), .rawSDL: .button(12)],
                      note: "Right stick press", callout: .below),

        // MARK: Directions, left hand. Hat 0 on every path; the Generic mode
        // also sends each as a button, which is what lights it here.
        PlacedControl(id: "left", kind: .key, center: CGPoint(x: 0.098, y: 0.302), size: 0.111,
                      symbol: "arrowtriangle.left.fill", inputs: ControlInputs(buttons: [18], hat: 0, hatDirection: .left),
                      pathInputs: [.rawProfile: ControlInputs(hat: 0, hatDirection: .left),
                                   .gameController: ControlInputs(hat: 0, hatDirection: .left),
                                   .rawSDL: ControlInputs(hat: 0, hatDirection: .left)],
                      note: "Hat 0 left; Generic mode also sends btn 18. Ring finger", callout: .below),
        PlacedControl(id: "down", kind: .key, center: CGPoint(x: 0.233, y: 0.303), size: 0.111,
                      symbol: "arrowtriangle.down.fill", inputs: ControlInputs(buttons: [17], hat: 0, hatDirection: .down),
                      pathInputs: [.rawProfile: ControlInputs(hat: 0, hatDirection: .down),
                                   .gameController: ControlInputs(hat: 0, hatDirection: .down),
                                   .rawSDL: ControlInputs(hat: 0, hatDirection: .down)],
                      note: "Hat 0 down; Generic mode also sends btn 17. Middle finger", callout: .below),
        PlacedControl(id: "right", kind: .key, center: CGPoint(x: 0.356, y: 0.393), size: 0.111,
                      symbol: "arrowtriangle.right.fill", inputs: ControlInputs(buttons: [19], hat: 0, hatDirection: .right),
                      pathInputs: [.rawProfile: ControlInputs(hat: 0, hatDirection: .right),
                                   .gameController: ControlInputs(hat: 0, hatDirection: .right),
                                   .rawSDL: ControlInputs(hat: 0, hatDirection: .right)],
                      note: "Hat 0 right; Generic mode also sends btn 19. Index finger", callout: .below),
        PlacedControl(id: "up", kind: .key, center: CGPoint(x: 0.437, y: 0.814), size: 0.139,
                      symbol: "arrowtriangle.up.fill", inputs: ControlInputs(buttons: [16], hat: 0, hatDirection: .up),
                      pathInputs: [.rawProfile: ControlInputs(hat: 0, hatDirection: .up),
                                   .gameController: ControlInputs(hat: 0, hatDirection: .up),
                                   .rawSDL: ControlInputs(hat: 0, hatDirection: .up)],
                      note: "Hat 0 up; Generic mode also sends btn 16. Left thumb; wins over Down by default (SOCD)",
                      callout: .below),

        // MARK: Attack grid, right hand. Top row: B3, B4, R1, L1 (punches);
        // bottom row: B1, B2, R2, L2 (kicks). Top captions go above, bottom
        // ones below, because the rows are staggered closer than a caption.
        PlacedControl(id: "b3", kind: .key, center: CGPoint(x: 0.518, y: 0.302), size: 0.111,
                      printed: "B3", inputs: .button(0), pathInputs: [.rawProfile: .button(2), .gameController: .button(2), .rawSDL: .button(2)],
                      note: "Square / X / Y; light punch", callout: .above),
        PlacedControl(id: "b4", kind: .key, center: CGPoint(x: 0.641, y: 0.211), size: 0.111,
                      printed: "B4", inputs: .button(3), note: "Triangle / Y / X; medium punch", callout: .above),
        PlacedControl(id: "r1", kind: .key, center: CGPoint(x: 0.775, y: 0.21), size: 0.111,
                      printed: "R1", inputs: .button(5), note: "R1 / RB / R; heavy punch", callout: .above),
        PlacedControl(id: "l1", kind: .key, center: CGPoint(x: 0.909, y: 0.212), size: 0.111,
                      printed: "L1", inputs: .button(4), note: "L1 / LB / L", callout: .above),
        PlacedControl(id: "b1", kind: .key, center: CGPoint(x: 0.492, y: 0.549), size: 0.111,
                      printed: "B1", inputs: .button(1), pathInputs: [.rawProfile: .button(0), .gameController: .button(0), .rawSDL: .button(0)],
                      note: "Cross / A / B; light kick", callout: .below),
        PlacedControl(id: "b2", kind: .key, center: CGPoint(x: 0.615, y: 0.461), size: 0.111,
                      printed: "B2", inputs: .button(2), pathInputs: [.rawProfile: .button(1), .gameController: .button(1), .rawSDL: .button(1)],
                      note: "Circle / B / A; medium kick", callout: .below),
        PlacedControl(id: "r2", kind: .key, center: CGPoint(x: 0.749, y: 0.461), size: 0.111,
                      printed: "R2", inputs: .button(7),
                      pathInputs: [.rawProfile: .trigger(axis: 5, digital: 7), .gameController: .trigger(axis: 5, digital: 7),
                                   .rawSDL: ControlInputs(buttons: [23], axes: [.analog(5)], digitalCopy: 7)],
                      note: "R2 / RT / ZR; heavy kick. Digital: other modes report it as a trigger at 0 or full", callout: .below),
        PlacedControl(id: "l2", kind: .key, center: CGPoint(x: 0.884, y: 0.461), size: 0.111,
                      printed: "L2", inputs: .button(6),
                      pathInputs: [.rawProfile: .trigger(axis: 4, digital: 6), .gameController: .trigger(axis: 4, digital: 6),
                                   .rawSDL: ControlInputs(buttons: [22], axes: [.analog(4)], digitalCopy: 6)],
                      note: "L2 / LT / ZL. Digital: other modes report it as a trigger at 0 or full", callout: .below),
    ]
}
