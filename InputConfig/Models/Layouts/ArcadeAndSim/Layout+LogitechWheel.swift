import Foundation
import CoreGraphics

extension ControllerLayout {
    /// Logitech's other force feedback wheels: the G27, G25, Driving Force
    /// GT, Driving Force Pro, Driving Force and Driving Force EX, MOMO Force
    /// and MOMO Racing, Formula Vibration and the Wingman Formula pair.
    ///
    /// They are read raw on the plan LogitechWheel gives every Logitech
    /// wheel: steering axi 0, brake axi 4, gas axi 5, clutch axi 1 (each
    /// pedal 0 released, 1 floored), the D-pad on hat 0, and the buttons in
    /// report bit order. Their buttons differ by model and none is named in
    /// a way the Mac can tell apart, so each is drawn as a numbered key in
    /// that order, the count right for the model; the variant is picked
    /// from the product ID. The real-descriptor tests in WheelDescriptorTests
    /// decode the G27, G25, Driving Force GT, Driving Force and Driving Force
    /// Pro on this plan. The MOMO, Formula Vibration and Wingman Formula
    /// wheels describe gas and brake as one combined axis, read as one
    /// centered axis on axi 1 (gas one way, brake the other).
    static let logitechWheel = ControllerLayout(
        id: .logitechWheel,
        displayName: "Logitech wheel",
        maker: .arcadeAndSim,
        family: nil,
        modelNames: ButtonNames.ModelNames(renamed: Dictionary(uniqueKeysWithValues: (0..<23).map { ($0, "Button \($0 + 1)") })),
        aspect: 0.85,
        topStrip: 0,
        backStrip: 0,
        silhouette: Silhouette(front: Silhouette.ellipseOps()),
        controls: logitechWheelControls,
        variants: logitechWheelModels.map { LayoutVariant(id: $0.id, displayName: $0.name, isDefault: $0.id == "g27") },
        match: [[.vidPid(vendor: 0x046D, products: [0xC29B, 0xC299, 0xC29A, 0xC298, 0xC294, 0xCA03, 0xC295, 0xCA04, 0xC20E, 0xC293])]],
        matchPriority: 15,
        readability: .partial("Read as a generic HID joystick. A G27, G25, Driving Force GT or Driving Force Pro in compatibility mode is switched to its own mode when it connects, so all its buttons and full steering are read. Force feedback and the G27's shift lights are not used"),
        approximate: true,
        sources: [
            "github.com/sonik-br/lgff_wheel_adapter usb_descriptors.h and reports.h (each wheel's real report descriptor and report layout)",
            "SDL src/joystick/hidapi/SDL_hidapi_lg4ff.c (report parsing and mode switch commands)",
        ],
        productVariants: [
            0x046D << 16 | 0xC29B: "g27", 0x046D << 16 | 0xC299: "g25", 0x046D << 16 | 0xC29A: "dfgt",
            0x046D << 16 | 0xC298: "dfp", 0x046D << 16 | 0xC294: "df", 0x046D << 16 | 0xCA03: "momo",
            0x046D << 16 | 0xC295: "momof", 0x046D << 16 | 0xCA04: "fv", 0x046D << 16 | 0xC20E: "formula",
            0x046D << 16 | 0xC293: "formula",
        ],
        // The G27, G25, Driving Force GT and Driving Force Pro are set to 900
        // degrees when they open (LogitechWheel.rangeCommands); the older
        // wheels have one fixed range.
        variantSteeringDegrees: ["g27": 900, "g25": 900, "dfgt": 900, "dfp": 900, "df": 270, "momo": 240, "momof": 240, "fv": 240]
    )

    /// Each model: its button count, and whether it has a clutch and a D-pad.
    static let logitechWheelModels: [(id: String, name: String, buttons: Int, clutch: Bool, hat: Bool)] = [
        ("g27", "G27", 23, true, true),
        ("g25", "G25", 19, true, true),
        ("dfgt", "Driving Force GT", 21, false, true),
        ("dfp", "Driving Force Pro", 14, false, true),
        ("df", "Driving Force or Driving Force EX", 12, false, true),
        ("momo", "MOMO Racing", 10, false, false),
        ("momof", "MOMO Force", 8, false, false),
        ("fv", "Formula Vibration", 12, false, true),
        ("formula", "Wingman Formula (Force) GP", 6, false, false),
    ]

    static let logitechWheelControls: [PlacedControl] = {
        let models = logitechWheelModels
        func with(_ test: ((id: String, name: String, buttons: Int, clutch: Bool, hat: Bool)) -> Bool) -> Set<String> {
            Set(models.filter(test).map(\.id))
        }
        var list: [PlacedControl] = [
            PlacedControl(id: "rim", kind: .wheel, center: CGPoint(x: 0.5, y: 0.36), size: 0.56, shape: .circle,
                          printed: "Wheel", inputs: ControlInputs(axes: [.x(0)]),
                          note: "Steering, on axis 0 at the wheel's full resolution", callout: .below),
            PlacedControl(id: "dpad", kind: .dpad, center: CGPoint(x: 0.5, y: 0.36), size: 0.13, shape: .crossPad,
                          inputs: .hat(0), callout: .below, overlayOf: "rim", variants: with { $0.hat }, name: "D-pad"),
            PlacedControl(id: "clutch", kind: .pedal, center: CGPoint(x: 0.38, y: 0.87), size: 0.09, height: 0.15,
                          shape: .roundedRect(corner: 0.18), printed: "Clutch", inputs: ControlInputs(axes: [.analog(1)]),
                          note: "Reads 0 released and 1 floored, like a trigger", callout: .below, variants: with { $0.clutch }),
            PlacedControl(id: "brake", kind: .pedal, center: CGPoint(x: 0.5, y: 0.87), size: 0.09, height: 0.15,
                          shape: .roundedRect(corner: 0.18), printed: "Brake", inputs: ControlInputs(axes: [.analog(4)]),
                          note: "Reads 0 released and 1 floored, like a trigger", callout: .below),
            PlacedControl(id: "gas", kind: .pedal, center: CGPoint(x: 0.62, y: 0.87), size: 0.09, height: 0.15,
                          shape: .roundedRect(corner: 0.18), printed: "Gas", inputs: ControlInputs(axes: [.analog(5)]),
                          note: "Reads 0 released and 1 floored, like a trigger", callout: .below),
        ]
        // The buttons in report order, odd numbers down the left edge and
        // even down the right, so each has its own level line in the key
        // whatever the model's count. Their places on the wheel differ by
        // model and are not drawn.
        for i in 0..<23 {
            let row = i / 2
            list.append(PlacedControl(
                id: "b\(i + 1)", kind: .key,
                center: CGPoint(x: i % 2 == 0 ? 0.16 : 0.84, y: 0.06 + CGFloat(row) * 0.064),
                size: 0.055, shape: .roundedRect(corner: 0.3), printed: "\(i + 1)", inputs: .button(i),
                callout: .below, variants: with { $0.buttons > i }, name: "Button \(i + 1)"))
        }
        return list
    }()
}
