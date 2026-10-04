import Foundation
import CoreGraphics

extension ControllerLayout {
    /// Thrustmaster T300 RS (and T300 RS GT Edition) with its stock 28 cm
    /// wheel and the T3PA pedal set, drawn as a kit seen from the driver's
    /// seat: the round rim and its hub on top, the pedals below (the pedal
    /// set is drawn smaller than life so it fits under the rim). The back
    /// strip holds what sits behind the rim: the two shift paddles on the
    /// wheel, and L3, R3, MODE and the USB switch on the base's front.
    ///
    /// Read path: raw HID descriptor (no profile, no GameControllerDB row).
    /// Inputs follow the normal PC mode descriptor (044F:B66E): X steering
    /// on axi 0, then the slot rules put Y (clutch) on axi 1, Z (gas) on
    /// axi 2 and Rz (brake) on axi 3; 13 buttons in the order Thrustmaster's
    /// PC mapping numbers them (1 to 13 there, 0 to 12 here) and one hat.
    /// The pedals are 10 bit bipolar axes, so each rests at one end.
    static let thrustmasterT300 = ControllerLayout(
        id: .thrustmasterT300,
        displayName: "Thrustmaster T300 RS",
        maker: .arcadeAndSim,
        family: nil,
        // Thrustmaster's own names, by its PC button numbering.
        modelNames: ButtonNames.ModelNames(renamed: [0: "L1 (left paddle)", 1: "R1 (right paddle)", 2: "Triangle", 3: "Square",
                                                     4: "Circle", 5: "Cross", 6: "Share", 7: "Options", 8: "R2", 9: "L2",
                                                     10: "L3", 11: "R3", 12: "PS"]),
        aspect: 0.8,
        topStrip: 0,
        backStrip: 0.24,
        silhouette: Silhouette(front: t300FrontOps, back: Silhouette.roundedRectOps(corner: 0.12, inset: 0.04)),
        controls: t300Controls,
        // Only its own ID. 044F:B65D, the generic "Thrustmaster FFB Wheel"
        // a T300 stays at on a Mac, is shared by other Thrustmaster wheels,
        // so a wheel there is drawn as this model only when its group is
        // set to it.
        match: [[.vidPid(vendor: 0x044F, products: [0xB66E])]],
        matchPriority: 5,
        readability: .partial("Read as a generic HID joystick. On a Mac the wheel stays in its generic mode (044F:B65D, shared with other Thrustmaster wheels) because InputConfig never sends the model switch, so it is drawn as a T300 only when its group is set to this model, and the layout is not verified there. In the PS4/PS5 switch position the wheel and pedals are not declared at all. Set the base switch to PC."),
        approximate: true,
        sources: [
            "Thrustmaster T300 RS GT Edition user manual (ts.thrustmaster.com/download/accessories/Manuals/T300RS/T300_RS_GT_manual.pdf), pages 2, 3, 12 (PC button mapping) and 17 (MODE + L3 + R3 on the base)",
            "hid-tmff2 src/tmt300rs/hid-tmt300rs.c (normal mode report descriptor: X wheel, Rz brake, Z gas, Y clutch, 13 buttons, hat)",
            "Linux drivers/hid/hid-thrustmaster.c (044F:B65D generic mode and the model switch request)",
        ],
        steeringDegrees: 1080
    )

    // MARK: - Outline

    /// Rim, hub with its spokes, the center boss, and the pedal set's base.
    /// The rim's outer edge and the hub run one way and the rim's inner edge
    /// the other, so the rim opening stays open under nonzero fill.
    static let t300FrontOps: [PathOp] = t300RimOuter + t300RimInner + Silhouette.symmetric(t300HubLeft) + t300Boss + t300PedalBase

    /// Rim, 28 cm across, centered at x 0.5, y 0.344 (radius 0.41 widths).
    static let t300RimOuter: [PathOp] = [
        .move(0.5, 0.016),
        .curve(0.09, 0.344, c1x: 0.2736, c1y: 0.016, c2x: 0.09, c2y: 0.1628),
        .curve(0.5, 0.672, c1x: 0.09, c1y: 0.5252, c2x: 0.2736, c2y: 0.672),
        .curve(0.91, 0.344, c1x: 0.7264, c1y: 0.672, c2x: 0.91, c2y: 0.5252),
        .curve(0.5, 0.016, c1x: 0.91, c1y: 0.1628, c2x: 0.7264, c2y: 0.016),
        .close,
    ]

    /// The rim's inner edge (the grip is about 18 percent of the radius).
    static let t300RimInner: [PathOp] = [
        .move(0.5, 0.076),
        .curve(0.835, 0.344, c1x: 0.685, c1y: 0.076, c2x: 0.835, c2y: 0.196),
        .curve(0.5, 0.612, c1x: 0.835, c1y: 0.492, c2x: 0.685, c2y: 0.612),
        .curve(0.165, 0.344, c1x: 0.315, c1y: 0.612, c2x: 0.165, c2y: 0.492),
        .curve(0.5, 0.076, c1x: 0.165, c1y: 0.196, c2x: 0.315, c2y: 0.076),
        .close,
    ]

    /// The hub's left half: the plate's top edge out to the upper spoke at
    /// about 10 o'clock, down the rim to the thumb slot, the lower spoke at
    /// about 8 o'clock, the plate's bottom edge, and the bottom spoke down
    /// to 6 o'clock. Points on the rim follow its inner edge.
    static let t300HubLeft: [PathOp] = [
        .move(0.5, 0.2522),
        .curve(0.3196, 0.2456, c1x: 0.4344, c1y: 0.2522, c2x: 0.3688, c2y: 0.2554),
        .line(0.1954, 0.2325),
        .quad(0.1715, 0.3965, cx: 0.1503, cy: 0.3114),
        .line(0.2417, 0.3965),
        .quad(0.2351, 0.508, cx: 0.254, cy: 0.4752),
        .quad(0.2819, 0.5474, cx: 0.256, cy: 0.5296),
        .quad(0.3524, 0.4424, cx: 0.3278, cy: 0.4818),
        .quad(0.4385, 0.4326, cx: 0.3934, cy: 0.4326),
        .line(0.4385, 0.6074),
        .quad(0.5, 0.612, cx: 0.469, cy: 0.612),
    ]

    /// The round center boss (the logo over the quick release).
    static let t300Boss: [PathOp] = [
        .move(0.5, 0.2968),
        .curve(0.441, 0.344, c1x: 0.4674, c1y: 0.2968, c2x: 0.441, c2y: 0.3179),
        .curve(0.5, 0.3912, c1x: 0.441, c1y: 0.3701, c2x: 0.4674, c2y: 0.3912),
        .curve(0.559, 0.344, c1x: 0.5326, c1y: 0.3912, c2x: 0.559, c2y: 0.3701),
        .curve(0.5, 0.2968, c1x: 0.559, c1y: 0.3179, c2x: 0.5326, c2y: 0.2968),
        .close,
    ]

    /// The T3PA's floor plate under the three pedals.
    static let t300PedalBase: [PathOp] = [
        .move(0.15, 0.72), .line(0.85, 0.72), .quad(0.88, 0.744, cx: 0.88, cy: 0.72), .line(0.88, 0.964),
        .quad(0.85, 0.988, cx: 0.88, cy: 0.988), .line(0.15, 0.988), .quad(0.12, 0.964, cx: 0.12, cy: 0.988),
        .line(0.12, 0.744), .quad(0.15, 0.72, cx: 0.12, cy: 0.72), .close,
    ]

    // MARK: - Controls

    static let t300Controls: [PlacedControl] = [
        // Steering: the rim around the hub, its mark and angle turning with it.
        PlacedControl(id: "steering", kind: .wheel, center: CGPoint(x: 0.5, y: 0.35), size: 0.6,
                      shape: .circle, printed: "Steering", inputs: ControlInputs(axes: [.x(0)]),
                      note: "1080 degree rim, 16 bit X: left is minus, right is plus", callout: .below),
        // Hub, upper corners: L2 and R2 on the spoke bosses.
        PlacedControl(id: "l2", kind: .faceButton, center: CGPoint(x: 0.299, y: 0.269), size: 0.045,
                      printed: "L2", inputs: .button(9), callout: .above),
        PlacedControl(id: "r2", kind: .faceButton, center: CGPoint(x: 0.701, y: 0.269), size: 0.045,
                      printed: "R2", inputs: .button(8), callout: .above),
        // Hub, left of the boss: the D-pad.
        PlacedControl(id: "dpad", kind: .dpad, center: CGPoint(x: 0.387, y: 0.327), size: 0.07, shape: .crossPad,
                      inputs: .hat(0), callout: .below),
        // Hub, right of the boss: the PlayStation diamond, monochrome on this wheel.
        PlacedControl(id: "triangle", kind: .faceButton, center: CGPoint(x: 0.613, y: 0.309), size: 0.034,
                      symbol: "triangle", inputs: .button(2), callout: .above),
        PlacedControl(id: "square", kind: .faceButton, center: CGPoint(x: 0.577, y: 0.338), size: 0.034,
                      symbol: "square", inputs: .button(3), callout: .left),
        PlacedControl(id: "circle", kind: .faceButton, center: CGPoint(x: 0.649, y: 0.338), size: 0.034,
                      symbol: "circle", inputs: .button(4), callout: .right),
        PlacedControl(id: "cross", kind: .faceButton, center: CGPoint(x: 0.613, y: 0.366), size: 0.034,
                      symbol: "xmark", inputs: .button(5), callout: .below),
        // Hub, lower spokes: Share (Create on PS5) and Options; PS on the bottom spoke.
        PlacedControl(id: "share", kind: .menuButton, center: CGPoint(x: 0.369, y: 0.412), size: 0.045,
                      symbol: "square.and.arrow.up", inputs: .button(6), callout: .below),
        PlacedControl(id: "options", kind: .menuButton, center: CGPoint(x: 0.631, y: 0.412), size: 0.045,
                      symbol: "line.3.horizontal", inputs: .button(7), callout: .below),
        PlacedControl(id: "ps", kind: .homeButton, center: CGPoint(x: 0.5, y: 0.461), size: 0.03,
                      symbol: "playstation.logo", inputs: .button(12), callout: .below),
        // T3PA pedals, left to right: clutch, brake, gas (gas is the taller head).
        PlacedControl(id: "clutch", kind: .pedal, center: CGPoint(x: 0.27, y: 0.72), size: 0.12, height: 0.2,
                      shape: .roundedRect(corner: 0.18), printed: "Clutch",
                      inputs: ControlInputs(axes: [AxisRef(index: 1, role: .y, unipolar: false)]),
                      readable: .conditional("Only with a three pedal set such as the T3PA (T300 RS GT Edition); the T300 RS ships with two pedals"),
                      note: "Y axis, rests at one end. MODE + L3 + R3 on the base swaps it with the gas pedal", callout: .below),
        PlacedControl(id: "brake", kind: .pedal, center: CGPoint(x: 0.5, y: 0.72), size: 0.12, height: 0.2,
                      shape: .roundedRect(corner: 0.18), printed: "Brake",
                      inputs: ControlInputs(axes: [AxisRef(index: 3, role: .y, unipolar: false)]),
                      note: "Rz axis, rests at one end", callout: .below),
        PlacedControl(id: "gas", kind: .pedal, center: CGPoint(x: 0.73, y: 0.708), size: 0.12, height: 0.23,
                      shape: .roundedRect(corner: 0.18), printed: "Gas",
                      inputs: ControlInputs(axes: [AxisRef(index: 2, role: .y, unipolar: false)]),
                      note: "Z axis, rests at one end", callout: .below),

        // Back, as held: the paddles behind the upper spokes.
        PlacedControl(id: "lpaddle", kind: .paddle, face: .back, center: CGPoint(x: 0.184, y: 0.33), size: 0.09, height: 0.15,
                      shape: .roundedRect(corner: 0.45), printed: "L1", inputs: .button(0),
                      note: "Left shift paddle (downshift)", callout: .above),
        PlacedControl(id: "rpaddle", kind: .paddle, face: .back, center: CGPoint(x: 0.816, y: 0.33), size: 0.09, height: 0.15,
                      shape: .roundedRect(corner: 0.45), printed: "R1", inputs: .button(1),
                      note: "Right shift paddle (upshift)", callout: .above),
        // Base front, below the wheel shaft: the USB switch and MODE on the
        // left, L3 and R3 in the middle.
        PlacedControl(id: "usbSwitch", kind: .other, face: .back, center: CGPoint(x: 0.1, y: 0.74), size: 0.06, height: 0.025,
                      shape: .roundedRect(corner: 0.5), printed: "PC",
                      readable: .notReported("A slide switch on the base: PS5-PS4 or PC. It picks the USB mode and is never reported; use PC on a Mac"),
                      note: "On the base"),
        PlacedControl(id: "mode", kind: .menuButton, face: .back, center: CGPoint(x: 0.3, y: 0.74), size: 0.04,
                      printed: "MODE",
                      readable: .notReported("The base's MODE button and its light change the wheel's own settings and are not sent to the Mac"),
                      note: "On the base"),
        PlacedControl(id: "l3", kind: .menuButton, face: .back, center: CGPoint(x: 0.46, y: 0.74), size: 0.032,
                      printed: "L3", inputs: .button(10), note: "On the base, below the wheel shaft", callout: .above),
        PlacedControl(id: "r3", kind: .menuButton, face: .back, center: CGPoint(x: 0.54, y: 0.74), size: 0.032,
                      printed: "R3", inputs: .button(11), note: "On the base, below the wheel shaft", callout: .below),
    ]
}
