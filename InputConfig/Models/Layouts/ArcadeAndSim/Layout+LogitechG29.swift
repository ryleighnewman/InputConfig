import Foundation
import CoreGraphics

extension ControllerLayout {
    /// Logitech G29 Driving Force (and the G923 for PlayStation and PC, which
    /// has the same rim and hub), drawn as a kit: the wheel seen from the
    /// driver's seat, the floor pedals below it on the left and the optional
    /// Driving Force Shifter on the right. The wheel is to scale, measured
    /// from Logitech's straight-on product photo: a round rim about 26 cm
    /// across with a wide opening above the hub, the D-pad on the left wing,
    /// the PlayStation face buttons on the right wing, the shift lights at
    /// the top of the hub, L2 and R2 beside the horn, L3 and R3 on the spoke
    /// edges, the plus and minus rocker lower left, the red 24-position dial
    /// with Enter lower right, and Share, Options and PS stacked on the
    /// bottom spoke. The pedal unit (428 mm wide in life) and the shifter are
    /// drawn smaller than the wheel so the kit fits one canvas; their own
    /// proportions are kept. The two shift paddles are on the back strip.
    ///
    /// Read path. GameController never lists a wheel as a GCController (it
    /// has a separate GCRacingWheel API the app does not use), there is no
    /// ControllerProfileDatabase or GameControllerDB row, so the wheel is
    /// read raw: RawHIDGamepadService matches its Generic Desktop Joystick
    /// collection and HIDDescriptorParser.buildLayout builds a generic plan.
    /// The native report (SDL_hidapi_lg4ff.c, lgff_wheel_adapter reports.h)
    /// is a 4-bit hat, then 25 button bits, a 16-bit steering X and three
    /// 8-bit pedals. Buttons keep descriptor bit order: Cross 0, Square 1,
    /// Circle 2, Triangle 3, right paddle 4, left paddle 5, R2 6, L2 7,
    /// Share 8, Options 9, R3 10, L3 11, shifter gears 1 to 6 on 12 to 17,
    /// reverse 18, plus 19, minus 20, dial clockwise 21, dial
    /// counterclockwise 22, Enter 23, PS 24. The pedals are Y clutch, Z gas
    /// and Rz brake (oversteer's device.py treats the G29 and G923 as its
    /// canonical X wheel, Z throttle, Rz brake, Y clutch; CARLA's G29 config
    /// agrees with throttle 2 and brake 3). LogitechWheel puts every
    /// Logitech wheel's pedals on one plan: gas axi 5, brake axi 4, clutch
    /// axi 1, each 0 released and 1 floored (the wheel sends 255 released).
    /// A G29 in Driving Force EX compatibility mode (046D:C294) is switched
    /// to this native mode when it connects, as Linux and SDL do.
    static let logitechG29 = ControllerLayout(
        id: .logitechG29,
        displayName: "Logitech G29 / G923",
        maker: .arcadeAndSim,
        family: nil,
        modelNames: ButtonNames.ModelNames(renamed: [
            0: "Cross", 1: "Square", 2: "Circle", 3: "Triangle",
            4: "Right paddle", 5: "Left paddle", 6: "R2", 7: "L2",
            8: "Share", 9: "Options", 10: "R3", 11: "L3",
            12: "Gear 1", 13: "Gear 2", 14: "Gear 3", 15: "Gear 4", 16: "Gear 5", 17: "Gear 6",
            18: "Reverse", 19: "Plus", 20: "Minus",
            21: "Dial clockwise", 22: "Dial counterclockwise", 23: "Enter", 24: "PS",
        ]),
        aspect: 0.794,
        topStrip: 0,
        backStrip: 0.3,
        silhouette: Silhouette(front: logitechG29Front),
        controls: logitechG29Controls,
        variants: [
            LayoutVariant(id: "g29", displayName: "G29 Driving Force", isDefault: true),
            LayoutVariant(id: "g923", displayName: "G923 for PlayStation and PC"),
        ],
        // Native mode only: G29 046D:C24F; G923 for PlayStation and PC
        // 046D:C266 (its report read as the G29's; lgff_wheel_adapter reads
        // the G923 with the G29 struct). The G923's PlayStation mode is not
        // read: switching it out needs a command this app does not send.
        // Compatibility mode 046D:C294 is left out on purpose: the
        // same ID is the old Driving Force EX, and its report is laid out
        // differently (13 buttons, hat in byte 2). The G923 for Xbox
        // (C26E) and the G920 start in Xbox mode, which is not HID.
        match: [[.vidPid(vendor: 0x046D, products: [0xC24F, 0xC266])]],
        matchPriority: 20,
        readability: .partial("Read with the switch on the wheel set to PS3: InputConfig switches it out of compatibility mode when it connects. Set to PS4 (046D:C260) it is not read. The shift lights and force feedback are not used"),
        approximate: true,
        sources: [
            "logitechg.com Driving Force G29 product page: front product photo (hub positions measured from it) and specifications (wheel 260 x 270 x 278 mm, pedals 428.5 x 311 x 167 mm)",
            "github.com/libsdl-org/SDL src/joystick/hidapi/SDL_hidapi_lg4ff.c (G29 report: hat, 25 buttons from bit 4, X in bytes 4 and 5, pedals in bytes 6 to 8)",
            "github.com/sonik-br/lgff_wheel_adapter reports.h g29_report_t (button bit names, gas, brake and clutch byte order)",
            "github.com/berarma/oversteer device.py (G29 axes: ABS_Z throttle, ABS_RZ brake, ABS_Y clutch, pedals 255 at rest) and wheel_ids.py",
            "github.com/carla-simulator/carla wheel_config.ini (G29 throttle axis 2, brake axis 3)",
            "github.com/karrvel/g29-mac (macOS: Joystick collection, C294 compatibility mode, no GCRacingWheel input use)",
            "logitechg.com Driving Force Shifter (reverse: push down and select sixth)",
            "InputConfig/Services/HIDDescriptorParser.swift buildLayout axis slots and button bit order",
        ],
        // The G29 is set to 900 degrees when it opens (LogitechWheel
        // .rangeCommands); the G923 is sent no range command, so it is
        // drawn as how far toward full lock.
        variantSteeringDegrees: ["g29": 900]
    )

    /// The wheel's outline (rim, the opening above the hub, the two lower
    /// openings either side of the bottom spoke), the horn ring, the pedal
    /// unit and the shifter base. Holes run the opposite way round to the
    /// rim so the nonzero fill leaves them open; the horn ring runs the
    /// same way, so it only adds a line. Built in widths (the face is 1.26
    /// widths tall) and divided down to face coordinates.
    static let logitechG29Front: [PathOp] = [
            // Rim, outer edge (round, about 26 cm across)
            .move(0.5, 0.0119),
            .curve(0.93, 0.3533, c1x: 0.7375, c1y: 0.0119, c2x: 0.93, c2y: 0.1648),
            .curve(0.5, 0.6948, c1x: 0.93, c1y: 0.5419, c2x: 0.7375, c2y: 0.6948),
            .curve(0.07, 0.3533, c1x: 0.2625, c1y: 0.6948, c2x: 0.07, c2y: 0.5419),
            .curve(0.5, 0.0119, c1x: 0.07, c1y: 0.1648, c2x: 0.2625, c2y: 0.0119),
            .close,
            // The opening above the hub
            .move(0.5, 0.077),
            .curve(0.1564, 0.3097, c1x: 0.329, c1y: 0.077, c2x: 0.1834, c2y: 0.1756),
            .line(0.215, 0.266),
            .quad(0.36, 0.2326, cx: 0.26, cy: 0.2303),
            .quad(0.445, 0.2588, cx: 0.41, cy: 0.2326),
            .quad(0.5, 0.2501, cx: 0.47, cy: 0.2477),
            .quad(0.555, 0.2588, cx: 0.53, cy: 0.2477),
            .quad(0.64, 0.2326, cx: 0.59, cy: 0.2326),
            .quad(0.785, 0.266, cx: 0.74, cy: 0.2303),
            .line(0.8436, 0.3097),
            .curve(0.5, 0.077, c1x: 0.8166, c1y: 0.1756, c2x: 0.671, c2y: 0.077),
            .close,
            // The lower left opening, between the hub, the bottom spoke and the rim
            .move(0.405, 0.4923),
            .quad(0.33, 0.4764, cx: 0.37, cy: 0.5082),
            .quad(0.3, 0.4208, cx: 0.3, cy: 0.4605),
            .line(0.1625, 0.4208),
            .curve(0.445, 0.6262, c1x: 0.1965, c1y: 0.5279, c2x: 0.3076, c2y: 0.6087),
            .line(0.435, 0.5082),
            .quad(0.405, 0.4923, cx: 0.435, cy: 0.4923),
            .close,
            // The lower right opening (the mirror, traced the same way round)
            .move(0.595, 0.4923),
            .quad(0.565, 0.5082, cx: 0.565, cy: 0.4923),
            .line(0.555, 0.6262),
            .curve(0.8375, 0.4208, c1x: 0.6924, c1y: 0.6087, c2x: 0.8035, c2y: 0.5279),
            .line(0.7, 0.4208),
            .quad(0.67, 0.4764, cx: 0.7, cy: 0.4605),
            .quad(0.595, 0.4923, cx: 0.63, cy: 0.5082),
            .close,
            // The center horn ring with the PlayStation logo (no button)
            .move(0.5, 0.2779),
            .curve(0.6, 0.3573, c1x: 0.5552, c1y: 0.2779, c2x: 0.6, c2y: 0.3134),
            .curve(0.5, 0.4367, c1x: 0.6, c1y: 0.4012, c2x: 0.5552, c2y: 0.4367),
            .curve(0.4, 0.3573, c1x: 0.4448, c1y: 0.4367, c2x: 0.4, c2y: 0.4012),
            .curve(0.5, 0.2779, c1x: 0.4, c1y: 0.3134, c2x: 0.4448, c2y: 0.2779),
            .close,
            // Pedal unit (428 mm wide in life), drawn smaller than the wheel to fit
            .move(0.085, 0.7265),
            .line(0.615, 0.7265),
            .quad(0.65, 0.7543, cx: 0.65, cy: 0.7265),
            .line(0.65, 0.9607),
            .quad(0.615, 0.9885, cx: 0.65, cy: 0.9885),
            .line(0.085, 0.9885),
            .quad(0.05, 0.9607, cx: 0.05, cy: 0.9885),
            .line(0.05, 0.7543),
            .quad(0.085, 0.7265, cx: 0.05, cy: 0.7265),
            .close,
            // Driving Force Shifter base
            .move(0.745, 0.7345),
            .line(0.935, 0.7345),
            .quad(0.965, 0.7583, cx: 0.965, cy: 0.7345),
            .line(0.965, 0.9647),
            .quad(0.935, 0.9885, cx: 0.965, cy: 0.9885),
            .line(0.745, 0.9885),
            .quad(0.715, 0.9647, cx: 0.715, cy: 0.9885),
            .line(0.715, 0.7583),
            .quad(0.745, 0.7345, cx: 0.715, cy: 0.7345),
            .close,
    ]

    private static let logitechG29PedalNote = "Reads 0 released and 1 floored, like a trigger"
    private static let logitechG29ShifterNote = "Only with the Driving Force Shifter plugged into the wheel base"

    /// Every control of the kit. The hub is drawn half again its true size
    /// about its own center, so its buttons read at a glance; the rim and
    /// pedals keep their scale. Hub controls sit on the rim's box, so they
    /// are overlays of it.
    static let logitechG29Controls: [PlacedControl] = [
        // The rim is the steering input: 900 degrees lock to lock.
        PlacedControl(id: "rim", kind: .wheel, center: CGPoint(x: 0.5, y: 0.3533), size: 0.86, shape: .circle,
                      printed: "Wheel", inputs: ControlInputs(axes: [.x(0)]),
                      note: "Steering, 900 degrees lock to lock: 0 centered, -1 full left, +1 full right", callout: .below),
        // Top of the hub: the shift lights (five pairs, green to red).
        PlacedControl(id: "shift-lights", kind: .light, center: CGPoint(x: 0.5, y: 0.1977), size: 0.177, height: 0.0195,
                      shape: .capsule(angleDegrees: 0),
                      readable: .notReported("The shift lights are an output games drive with Logitech's own commands; InputConfig never sends them"),
                      callout: .above, overlayOf: "rim"),
        // Left wing: the D-pad.
        PlacedControl(id: "dpad", kind: .dpad, center: CGPoint(x: 0.2459, y: 0.2325), size: 0.108, shape: .crossPad,
                      inputs: .hat(0), callout: .below, overlayOf: "rim"),
        // Right wing: the face buttons, black with white glyphs. Square is
        // btn 1 and Circle btn 2 here (the wheel's own bit order), so each
        // carries its glyph rather than the PlayStation family's numbering.
        PlacedControl(id: "triangle", kind: .faceButton, center: CGPoint(x: 0.749, y: 0.1958), size: 0.045,
                      symbol: "triangle", inputs: .button(3), callout: .above, overlayOf: "rim"),
        PlacedControl(id: "square", kind: .faceButton, center: CGPoint(x: 0.6999, y: 0.2295), size: 0.045,
                      symbol: "square", inputs: .button(1), callout: .left, overlayOf: "rim"),
        PlacedControl(id: "circle", kind: .faceButton, center: CGPoint(x: 0.7993, y: 0.2295), size: 0.045,
                      symbol: "circle", inputs: .button(2), callout: .right, overlayOf: "rim"),
        PlacedControl(id: "cross", kind: .faceButton, center: CGPoint(x: 0.749, y: 0.2653), size: 0.045,
                      symbol: "xmark", inputs: .button(0), callout: .below, overlayOf: "rim"),
        // Beside the horn: L2 and R2, small blue buttons (not triggers).
        PlacedControl(id: "l2", kind: .menuButton, center: CGPoint(x: 0.2821, y: 0.3401), size: 0.042, height: 0.0375,
                      shape: .roundedRect(corner: 0.3), printed: "L2", tint: .psBlue, inputs: .button(7),
                      note: "A button on the wheel; the pedals are separate axes", callout: .above, overlayOf: "rim"),
        PlacedControl(id: "r2", kind: .menuButton, center: CGPoint(x: 0.7179, y: 0.3401), size: 0.042, height: 0.0375,
                      shape: .roundedRect(corner: 0.3), printed: "R2", tint: .psBlue, inputs: .button(6),
                      note: "A button on the wheel; the pedals are separate axes", callout: .above, overlayOf: "rim"),
        // On the lower edges of the side spokes: L3 and R3, also blue.
        PlacedControl(id: "l3", kind: .menuButton, center: CGPoint(x: 0.2007, y: 0.4138), size: 0.057, height: 0.033,
                      shape: .roundedRect(corner: 0.3), printed: "L3", tint: .psBlue, inputs: .button(11),
                      callout: .above, overlayOf: "rim"),
        PlacedControl(id: "r3", kind: .menuButton, center: CGPoint(x: 0.7993, y: 0.4138), size: 0.057, height: 0.033,
                      shape: .roundedRect(corner: 0.3), printed: "R3", tint: .psBlue, inputs: .button(10),
                      callout: .above, overlayOf: "rim"),
        // Lower left: the plus and minus rocker.
        PlacedControl(id: "plus", kind: .menuButton, center: CGPoint(x: 0.3233, y: 0.4569), size: 0.099, height: 0.042,
                      shape: .roundedRect(corner: 0.45), symbol: "plus", inputs: .button(19), callout: .above, overlayOf: "rim"),
        PlacedControl(id: "minus", kind: .menuButton, center: CGPoint(x: 0.3233, y: 0.4978), size: 0.099, height: 0.042,
                      shape: .roundedRect(corner: 0.45), symbol: "minus", inputs: .button(20), callout: .below, overlayOf: "rim"),
        // Lower right: the red 24-position dial. Each detent sends a short
        // pulse on btn 21 (clockwise) or btn 22 (counterclockwise); the ring
        // is drawn as its two turning directions either side of Enter.
        PlacedControl(id: "dial-ccw", kind: .other, center: CGPoint(x: 0.6042, y: 0.4711), size: 0.03, height: 0.093,
                      shape: .capsule(angleDegrees: 0), symbol: "arrow.counterclockwise", tint: .psRed, inputs: .button(22),
                      note: "One short press per detent of the red dial", callout: .above, overlayOf: "rim"),
        PlacedControl(id: "enter", kind: .other, center: CGPoint(x: 0.6703, y: 0.4711), size: 0.096,
                      symbol: "return", inputs: .button(23), note: "The button in the middle of the red dial",
                      callout: .below, overlayOf: "rim"),
        PlacedControl(id: "dial-cw", kind: .other, center: CGPoint(x: 0.7362, y: 0.4711), size: 0.03, height: 0.093,
                      shape: .capsule(angleDegrees: 0), symbol: "arrow.clockwise", tint: .psRed, inputs: .button(21),
                      note: "One short press per detent of the red dial", callout: .below, overlayOf: "rim"),
        // Bottom spoke: Share, Options and PS stacked (printed SHARE, OPTION
        // and the PlayStation logo).
        PlacedControl(id: "share", kind: .menuButton, center: CGPoint(x: 0.5, y: 0.4907), size: 0.06, height: 0.036,
                      shape: .roundedRect(corner: 0.3), symbol: "square.and.arrow.up", inputs: .button(8),
                      callout: .above, overlayOf: "rim"),
        PlacedControl(id: "options", kind: .menuButton, center: CGPoint(x: 0.5, y: 0.5377), size: 0.06, height: 0.036,
                      shape: .roundedRect(corner: 0.3), symbol: "line.3.horizontal", inputs: .button(9),
                      callout: .below, overlayOf: "rim"),
        PlacedControl(id: "ps", kind: .homeButton, center: CGPoint(x: 0.5, y: 0.591), size: 0.06, height: 0.036,
                      shape: .roundedRect(corner: 0.3), printed: "PS", inputs: .button(24),
                      callout: .below, overlayOf: "rim"),
        // Floor pedals, left to right: clutch, brake, gas.
        PlacedControl(id: "clutch", kind: .pedal, center: CGPoint(x: 0.217, y: 0.8099), size: 0.093, height: 0.15,
                      shape: .roundedRect(corner: 0.18), printed: "Clutch", inputs: ControlInputs(axes: [.analog(1)]),
                      note: logitechG29PedalNote, callout: .below),
        PlacedControl(id: "brake", kind: .pedal, center: CGPoint(x: 0.35, y: 0.8099), size: 0.093, height: 0.15,
                      shape: .roundedRect(corner: 0.18), printed: "Brake", inputs: ControlInputs(axes: [.analog(4)]),
                      note: logitechG29PedalNote, callout: .below),
        PlacedControl(id: "gas", kind: .pedal, center: CGPoint(x: 0.483, y: 0.8099), size: 0.093, height: 0.15,
                      shape: .roundedRect(corner: 0.18), printed: "Gas", inputs: ControlInputs(axes: [.analog(5)]),
                      note: logitechG29PedalNote, callout: .below),
        // Driving Force Shifter, an H gate: 1, 3, 5 forward, 2, 4, 6 back.
        // Reverse is pushing the lever down and selecting sixth, drawn
        // under 6.
        PlacedControl(id: "gear1", kind: .key, center: CGPoint(x: 0.77, y: 0.7821), size: 0.042, shape: .roundedRect(corner: 0.3),
                      printed: "1", inputs: .button(12), readable: .conditional(logitechG29ShifterNote), callout: .below),
        PlacedControl(id: "gear2", kind: .key, center: CGPoint(x: 0.77, y: 0.8694), size: 0.042, shape: .roundedRect(corner: 0.3),
                      printed: "2", inputs: .button(13), readable: .conditional(logitechG29ShifterNote), callout: .below),
        PlacedControl(id: "gear3", kind: .key, center: CGPoint(x: 0.84, y: 0.7821), size: 0.042, shape: .roundedRect(corner: 0.3),
                      printed: "3", inputs: .button(14), readable: .conditional(logitechG29ShifterNote), callout: .below),
        PlacedControl(id: "gear4", kind: .key, center: CGPoint(x: 0.84, y: 0.8694), size: 0.042, shape: .roundedRect(corner: 0.3),
                      printed: "4", inputs: .button(15), readable: .conditional(logitechG29ShifterNote), callout: .below),
        PlacedControl(id: "gear5", kind: .key, center: CGPoint(x: 0.91, y: 0.7821), size: 0.042, shape: .roundedRect(corner: 0.3),
                      printed: "5", inputs: .button(16), readable: .conditional(logitechG29ShifterNote), callout: .below),
        PlacedControl(id: "gear6", kind: .key, center: CGPoint(x: 0.91, y: 0.8694), size: 0.042, shape: .roundedRect(corner: 0.3),
                      printed: "6", inputs: .button(17), readable: .conditional(logitechG29ShifterNote), callout: .below),
        PlacedControl(id: "reverse", kind: .key, center: CGPoint(x: 0.91, y: 0.9449), size: 0.042, shape: .roundedRect(corner: 0.3),
                      printed: "R", inputs: .button(18), readable: .conditional(logitechG29ShifterNote),
                      note: "Push the lever down and select sixth", callout: .below),
        // Back, as held: the two metal shift paddles behind the side spokes,
        // their tips leaning in toward the top of the rim.
        PlacedControl(id: "paddle-left", kind: .paddle, face: .back, center: CGPoint(x: 0.172, y: 0.5), size: 0.065, height: 0.26,
                      shape: .capsule(angleDegrees: 10), symbol: "chevron.down", inputs: .button(5),
                      note: "Left paddle, the downshift in most games", callout: .below),
        PlacedControl(id: "paddle-right", kind: .paddle, face: .back, center: CGPoint(x: 0.828, y: 0.5), size: 0.065, height: 0.26,
                      shape: .capsule(angleDegrees: -10), symbol: "chevron.up", inputs: .button(4),
                      note: "Right paddle, the upshift in most games", callout: .below),
    ]
}
