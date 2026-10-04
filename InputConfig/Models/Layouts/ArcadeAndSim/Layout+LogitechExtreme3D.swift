import Foundation
import CoreGraphics

extension ControllerLayout {
    /// Logitech Extreme 3D Pro (046D:C215), a right-hand flight stick read
    /// on the raw HID path. No hand-coded profile and no SDL row exist for
    /// it, so HIDDescriptorParser builds its profile from the descriptor:
    /// buttons 0 to 11 in bit order (printed 1 to 12), the 8-way hat on
    /// hat 0, X and Y on axes 0 and 1, the Rz twist on the first free stick
    /// slot (axis 2), and the Slider throttle on trigger slot 4, unipolar.
    /// With 12 Button-page buttons nothing is mirrored onto buttons 6 and 7.
    ///
    /// The front face is the stick seen from the pilot's seat, a little from
    /// above: the grip head at the top (hat with buttons 3 to 6 around it),
    /// the grip below it with the thumb button on its left, and the wide
    /// base at the bottom, its 2 by 3 button block on the left and the
    /// throttle lever on the edge nearest the pilot. The trigger faces away
    /// from the pilot; it is drawn on the grip, x-ray style.
    static let logitechExtreme3D = ControllerLayout(
        id: .logitechExtreme3D,
        displayName: "Logitech Extreme 3D Pro",
        maker: .arcadeAndSim,
        family: nil,
        // Logitech prints numbers: button 1 is the trigger, 2 the thumb button.
        modelNames: ButtonNames.ModelNames(renamed: Dictionary(uniqueKeysWithValues: (0...11).map {
            ($0, $0 == 0 ? "Trigger (1)" : ($0 == 1 ? "Thumb button (2)" : "Button \($0 + 1)"))
        })),
        aspect: 0.78,
        topStrip: 0,
        backStrip: 0,
        silhouette: Silhouette(front: extreme3DOutline),
        controls: extreme3DControls,
        match: [[.vidPid(vendor: 0x046D, products: [0xC215])]],
        matchPriority: 10,
        approximate: true,
        sources: [
            "logitechg.com Extreme 3D Pro product page (12 buttons, 8-way hat, twist rudder, throttle)",
            "simflight.com Logitech Extreme 3D Pro review (2011): 2 by 3 base block left of the stick, head buttons around the hat, thumb button 2 on the left, throttle between pilot and stick",
            "ifixit.com Device: Logitech Extreme 3D Pro (throttle lever on the front of the device, six base buttons)",
            "pcgamesn.com Extreme 3D Pro review (200 by 200 mm base)",
            "le3dp report struct (x:10 y:10 hat:4 twist:8 buttons_a:8 slider:8 buttons_b:4)",
        ]
    )

    /// One outline: the grip head, the grip with its palm rest flaring to
    /// the right, and the base seen from behind and slightly above.
    static let extreme3DOutline: [PathOp] = [
        .move(0.55, 0.015),
        // Head, right side.
        .curve(0.80, 0.115, c1x: 0.70, c1y: 0.015, c2x: 0.80, c2y: 0.05),
        .curve(0.67, 0.24, c1x: 0.80, c1y: 0.19, c2x: 0.73, c2y: 0.225),
        // Grip, right side, then the palm rest.
        .curve(0.66, 0.40, c1x: 0.655, c1y: 0.30, c2x: 0.65, c2y: 0.35),
        .curve(0.73, 0.55, c1x: 0.70, c1y: 0.45, c2x: 0.74, c2y: 0.50),
        .curve(0.71, 0.595, c1x: 0.725, c1y: 0.58, c2x: 0.72, c2y: 0.59),
        // Base: far edge right, right side, near edge, left side, far edge left.
        .line(0.90, 0.59),
        .curve(0.98, 0.68, c1x: 0.96, c1y: 0.59, c2x: 0.98, c2y: 0.62),
        .line(0.99, 0.92),
        .curve(0.92, 0.985, c1x: 0.99, c1y: 0.975, c2x: 0.96, c2y: 0.985),
        .line(0.08, 0.985),
        .curve(0.01, 0.92, c1x: 0.04, c1y: 0.985, c2x: 0.01, c2y: 0.975),
        .line(0.02, 0.68),
        .curve(0.10, 0.59, c1x: 0.02, c1y: 0.62, c2x: 0.04, c2y: 0.59),
        .line(0.41, 0.595),
        // Grip, left side, back up to the head.
        .curve(0.44, 0.40, c1x: 0.43, c1y: 0.53, c2x: 0.445, c2y: 0.46),
        .curve(0.43, 0.24, c1x: 0.435, c1y: 0.33, c2x: 0.44, c2y: 0.28),
        .curve(0.30, 0.115, c1x: 0.37, c1y: 0.225, c2x: 0.30, c2y: 0.19),
        .curve(0.55, 0.015, c1x: 0.30, c1y: 0.05, c2x: 0.40, c2y: 0.015),
        .close,
    ]

    static let extreme3DControls: [PlacedControl] = [
        // Head: the 8-way hat in the middle, 5 and 6 on the far side of it,
        // 3 and 4 on the near side. The hat is drawn as a D-pad so its
        // directions light from hat 0.
        PlacedControl(id: "hat", kind: .dpad, center: CGPoint(x: 0.55, y: 0.07), size: 0.1, shape: .crossPad,
                      inputs: .hat(0), note: "8-way hat: a diagonal lights two arrows", callout: .above),
        PlacedControl(id: "b5", kind: .key, center: CGPoint(x: 0.39, y: 0.07), size: 0.07,
                      printed: "5", inputs: .button(4), callout: .above),
        PlacedControl(id: "b6", kind: .key, center: CGPoint(x: 0.71, y: 0.07), size: 0.07,
                      printed: "6", inputs: .button(5), callout: .above),
        PlacedControl(id: "b3", kind: .key, center: CGPoint(x: 0.39, y: 0.16), size: 0.07,
                      printed: "3", inputs: .button(2), callout: .below),
        PlacedControl(id: "b4", kind: .key, center: CGPoint(x: 0.71, y: 0.16), size: 0.07,
                      printed: "4", inputs: .button(3), callout: .below),
        // Grip: thumb button 2 on the left side under the head, the trigger
        // on the far side under the index finger.
        PlacedControl(id: "thumb", kind: .gripButton, center: CGPoint(x: 0.44, y: 0.27), size: 0.055, height: 0.085,
                      shape: .capsule(angleDegrees: 0), printed: "2", inputs: .button(1), callout: .below),
        PlacedControl(id: "trigger", kind: .trigger(.digital), center: CGPoint(x: 0.60, y: 0.27), size: 0.09, height: 0.065,
                      shape: .roundedRect(corner: 0.35), printed: "1", inputs: .button(0),
                      note: "On the front of the grip, facing away from you", callout: .below),
        // The whole grip: X and Y tilt, and the twist rudder (Rz, axis 2).
        // The twist is listed with the x role so both of its directions
        // count as this control's inputs; the canvas moves the stick dot
        // from the first x axis (axis 0) only.
        PlacedControl(id: "stick", kind: .stick, center: CGPoint(x: 0.55, y: 0.45), size: 0.18,
                      inputs: ControlInputs(axes: [.x(0), .y(1), AxisRef(index: 2, role: .x)]),
                      note: "Twisting the grip is axis 2 (rudder)", callout: .below),
        // Base: buttons 7 to 12 in two columns of three, 7 and 8 farthest
        // from the pilot.
        PlacedControl(id: "b7", kind: .key, center: CGPoint(x: 0.11, y: 0.67), size: 0.06,
                      printed: "7", inputs: .button(6), callout: .below),
        PlacedControl(id: "b8", kind: .key, center: CGPoint(x: 0.23, y: 0.67), size: 0.06,
                      printed: "8", inputs: .button(7), callout: .below),
        PlacedControl(id: "b9", kind: .key, center: CGPoint(x: 0.11, y: 0.76), size: 0.06,
                      printed: "9", inputs: .button(8), callout: .below),
        PlacedControl(id: "b10", kind: .key, center: CGPoint(x: 0.23, y: 0.76), size: 0.06,
                      printed: "10", inputs: .button(9), callout: .below),
        PlacedControl(id: "b11", kind: .key, center: CGPoint(x: 0.11, y: 0.85), size: 0.06,
                      printed: "11", inputs: .button(10), callout: .below),
        PlacedControl(id: "b12", kind: .key, center: CGPoint(x: 0.23, y: 0.85), size: 0.06,
                      printed: "12", inputs: .button(11), callout: .below),
        // Throttle lever (marked + and -) on the base edge nearest the
        // pilot. The Slider usage lands on trigger slot 4 as 0...1.
        PlacedControl(id: "throttle", kind: .slider, center: CGPoint(x: 0.36, y: 0.895), size: 0.05, height: 0.1,
                      shape: .roundedRect(corner: 0.4), inputs: ControlInputs(axes: [.analog(4)]),
                      note: "+ end reads 0", callout: .below),
    ]
}
