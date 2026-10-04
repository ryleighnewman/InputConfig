import Foundation
import CoreGraphics

extension ControllerLayout {
    /// Xbox One Wireless Controller, models 1537 (2013, micro-USB only) and
    /// 1708 (2016, adds Bluetooth and a 3.5 mm jack), 153 by 102 mm. Read
    /// through GameController as a GCXboxGamepad. Over USB both speak GIP,
    /// which GameController reads on macOS 15 and later only; a 1708 still on
    /// its first Bluetooth firmware (045E:02E0) is not listed by
    /// GameController and is read through the bundled SDL rows instead, on
    /// the same indices.
    ///
    /// Recognized as an Xbox pad with no Share button and no paddles, below
    /// the Series and Elite layouts, so a Series pad that never reports
    /// Share (older firmware or macOS) also lands here: the model is not
    /// reported, only the elements.
    static let xboxOne = ControllerLayout(
        id: .xboxOne,
        displayName: "Xbox One Controller",
        maker: .microsoft,
        family: .xbox,
        // No Share button, no paddles, no touchpad or mute.
        modelNames: ButtonNames.ModelNames(absent: [13, 14, 15, 16, 17, 18, 19, 20, 21]),
        aspect: 1.5,
        topStrip: 0.2,
        backStrip: 0,
        silhouette: Silhouette(front: Silhouette.symmetric(xboxOneLeftHalf),
                               top: Silhouette.roundedRectOps(corner: 0.18, inset: 0.04)),
        controls: xboxOneControls,
        match: [
            // GameController: an Xbox pad without the Series' Share button
            // or the Elite's paddles.
            [.brand(.xbox), .gcLacksElement("Button Share"), .gcLacksElement("Paddle 1")],
            // Raw HID (SDL rows): 1537 USB (02D1, 02DD), 1708 USB (02EA),
            // 1708 Bluetooth on its two classic firmwares (02E0, 02FD) and
            // on the 2021 BLE firmware (0B20, SDL's XBOX_ONE_S_REV2_BLE).
            [.vidPid(vendor: 0x045E, products: [0x02D1, 0x02DD, 0x02E0, 0x02EA, 0x02FD, 0x0B20])],
        ],
        matchPriority: 5,
        readability: .partial("USB needs macOS 15 or later (GIP). The 1708 also works over Bluetooth on every supported macOS; the 1537 has no Bluetooth."),
        approximate: true,
        sources: [
            "dimensions.com/element/xbox-one-controller (152.9 by 101.9 by 61 mm)",
            "en.wikipedia.org/wiki/Xbox_Wireless_Controller (1537 and 1708 revisions)",
            "support.xbox.com Get to know your Xbox Wireless Controller (button and port placement)",
            "SDL src/joystick/usb_ids.h (Xbox One product IDs)",
        ]
    )

    /// The front outline's left half: a flat top that dips slightly at the
    /// Xbox button, broad rounded shoulders where the bumpers wrap, sides
    /// that widen a little toward the grips, round grip ends, and an arch
    /// between the grips about three quarters of the way down.
    static let xboxOneLeftHalf: [PathOp] = [
        .move(0.5, 0.05),
        .curve(0.20, 0.03, c1x: 0.40, c1y: 0.045, c2x: 0.28, c2y: 0.024),
        .curve(0.035, 0.26, c1x: 0.09, c1y: 0.038, c2x: 0.045, c2y: 0.13),
        .curve(0.06, 0.90, c1x: 0.02, c1y: 0.45, c2x: 0.02, c2y: 0.78),
        .curve(0.27, 0.90, c1x: 0.10, c1y: 1.01, c2x: 0.23, c2y: 1.01),
        .curve(0.40, 0.75, c1x: 0.31, c1y: 0.80, c2x: 0.34, c2y: 0.755),
        .curve(0.5, 0.735, c1x: 0.44, c1y: 0.745, c2x: 0.47, c2y: 0.735),
    ]

    /// Inputs are GameControllerService.readControllerState's: A B X Y btn 0
    /// to 3, LB RB 4 and 5, LT RT axes 4 and 5 with digital copies 6 and 7,
    /// View (buttonOptions) 8, Menu 9, Xbox (buttonHome) 10, stick clicks
    /// 11 and 12, sticks axes 0 to 3, D-pad hat 0. The SDL rows for this pad
    /// map to the same slots (SDLGameControllerDB.buttonSlots and axisSlots).
    static let xboxOneControls: [PlacedControl] = [
        // Top: triggers behind, bumpers wrapping the front corners, the
        // micro-USB port at the center with the pair button to its left.
        PlacedControl(id: "lt", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.22, y: 0.175), size: 0.15, height: 0.13,
                      shape: .roundedRect(corner: 0.35), inputs: .trigger(axis: 4, digital: 6), callout: .above),
        PlacedControl(id: "rt", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.78, y: 0.175), size: 0.15, height: 0.13,
                      shape: .roundedRect(corner: 0.35), inputs: .trigger(axis: 5, digital: 7), callout: .above),
        PlacedControl(id: "lb", kind: .shoulder, face: .top, center: CGPoint(x: 0.2, y: 0.75), size: 0.2, height: 0.045,
                      shape: .capsule(angleDegrees: 0), inputs: .button(4), callout: .below),
        PlacedControl(id: "rb", kind: .shoulder, face: .top, center: CGPoint(x: 0.8, y: 0.75), size: 0.2, height: 0.045,
                      shape: .capsule(angleDegrees: 0), inputs: .button(5), callout: .below),
        PlacedControl(id: "pair", kind: .other, face: .top, center: CGPoint(x: 0.43, y: 0.62), size: 0.03,
                      printed: "Pair", readable: .notReported("The pair button is handled by the controller and never reaches the Mac"),
                      callout: .above),
        PlacedControl(id: "usb", kind: .port, face: .top, center: CGPoint(x: 0.5, y: 0.62), size: 0.05, height: 0.02,
                      shape: .roundedRect(corner: 0.3), note: "Micro-USB"),
        // Front: the Xbox button high in the center.
        PlacedControl(id: "xbox", kind: .homeButton, center: CGPoint(x: 0.5, y: 0.18), size: 0.095, symbol: "logo.xbox",
                      inputs: .button(10), note: "InputConfig turns off the system gesture so a preset gets the press", callout: .above),
        // Left stick high on the left, D-pad lower and further in.
        PlacedControl(id: "lstick", kind: .stick, center: CGPoint(x: 0.26, y: 0.335), size: 0.135,
                      inputs: .stick(x: 0, y: 1, press: 11), callout: .above),
        PlacedControl(id: "dpad", kind: .dpad, center: CGPoint(x: 0.37, y: 0.605), size: 0.145, shape: .crossPad,
                      inputs: .hat(0), callout: .below),
        // View and Menu: small round buttons either side, below the Xbox button.
        PlacedControl(id: "view", kind: .menuButton, center: CGPoint(x: 0.41, y: 0.365), size: 0.045,
                      symbol: "rectangle.on.rectangle", inputs: .button(8), callout: .below),
        PlacedControl(id: "menu", kind: .menuButton, center: CGPoint(x: 0.59, y: 0.365), size: 0.045,
                      symbol: "line.3.horizontal", inputs: .button(9), callout: .below),
        // Right stick lower and in; the face buttons high on the right.
        PlacedControl(id: "rstick", kind: .stick, center: CGPoint(x: 0.635, y: 0.605), size: 0.135,
                      inputs: .stick(x: 2, y: 3, press: 12), callout: .below),
        PlacedControl(id: "y", kind: .faceButton, center: CGPoint(x: 0.745, y: 0.262), size: 0.072, tint: .xboxYellow,
                      inputs: .button(3), callout: .above),
        PlacedControl(id: "x", kind: .faceButton, center: CGPoint(x: 0.68, y: 0.36), size: 0.072, tint: .xboxBlue,
                      inputs: .button(2), callout: .left),
        PlacedControl(id: "b", kind: .faceButton, center: CGPoint(x: 0.81, y: 0.36), size: 0.072, tint: .xboxRed,
                      inputs: .button(1), callout: .right),
        PlacedControl(id: "a", kind: .faceButton, center: CGPoint(x: 0.745, y: 0.458), size: 0.072, tint: .xboxGreen,
                      inputs: .button(0), callout: .below),
    ]
}
