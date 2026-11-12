import Foundation
import CoreGraphics

extension ControllerLayout {
    /// 8BitDo Ultimate 2 Wireless (2024): the controller with the Fire Ring
    /// lights around both sticks, a 2.4G adapter that docks in its charging
    /// stand, and a BT and 2.4G mode switch on the back. Every place is
    /// measured off the front, back and top drawings in 8BitDo's own manual
    /// (Ultimate-2-Wireless-Controller-EN.pdf) and normalized to the body
    /// the drawing shows; the body outline is the 8BitDo Ultimate's, which
    /// this controller's drawing follows.
    ///
    /// Front: the left stick high and far out, the D-pad and the right
    /// stick level lower down, the Xbox face diamond (Y top, B right, A
    /// bottom, X left). The center runs View, Home and Menu in one row, the
    /// Square button under View, Star under Menu beside X, and the Profile
    /// button with its three lights in the middle. Back: PL behind the left
    /// grip and PR behind the right, a trigger mode switch behind each
    /// trigger, the mode switch between the grips. Top: L4 beside LT and R4
    /// beside RT, USB-C in the middle with the pair button and power light.
    ///
    /// Inputs. In BT mode it is 2DC8:6012 to the Mac, read from its own
    /// report as SDL's 8BitDo driver reads it (ReportLayout.eightBitDo):
    /// btn 0 to 12, L4 16, R4 17, PL 18, PR 19, sticks 0 to 3, triggers 4
    /// and 5, hat 0. The Square and Star buttons have no bit in that report.
    /// In 2.4G mode the adapter is an XInput device that macOS does not read.
    static let eightBitDoUltimate2Wireless = ControllerLayout(
        id: .eightBitDoUltimate2Wireless,
        displayName: "8BitDo Ultimate 2 Wireless",
        maker: .eightBitDo,
        family: nil,
        modelNames: ButtonNames.ModelNames(renamed: [16: "L4", 17: "R4", 18: "PL", 19: "PR"],
                                           short: [16: "L4", 17: "R4", 18: "PL", 19: "PR"],
                                           absent: [13, 14, 15, 20, 21]),
        aspect: 147.0 / 104.0,
        topStrip: 0.2,
        backStrip: 0.535,
        silhouette: Silhouette(front: eightBitDoUltimateFront,
                               top: Silhouette.roundedRectOps(corner: 0.2, inset: 0.04),
                               back: eightBitDoUltimateFront),
        controls: eightBitDoUltimate2WirelessControls,
        match: [
            // The raw 2DC8:6012 read only: GameController, if it ever lists
            // this pad, numbers its back buttons differently (not measured).
            [.vidPid(vendor: 0x2DC8, products: [0x6012])],
        ],
        matchPriority: 21,
        readability: .partial("With the mode switch on BT every button but Square and Star reaches the Mac. In 2.4G mode the adapter is an XInput device macOS does not read."),
        approximate: true,
        sources: [
            "download.8bitdo.com Ultimate-2-Wireless-Controller-EN.pdf (front, back and top drawings: home, view, menu, square, star, profile, L4, R4, PL, PR, trigger mode switches, mode switch, pair, USB-C; Windows 2.4G and Android Bluetooth only)",
            "SDL_hidapi_8bitdo.c (libsdl-org/SDL main, 2026-11-07): USB_PRODUCT_8BITDO_ULTIMATE2_WIRELESS 0x6012, HandleStatePacket byte table, 34 byte reports and motors from firmware 1.03",
        ]
    )

    static let eightBitDoUltimate2WirelessControls: [PlacedControl] = [
        // Top, as held: LT and RT at the rear corners with L4 and R4 just
        // inboard of them, LB and RB along the front lip, USB-C in the
        // middle with the pair button on its left and the power light on
        // its right.
        PlacedControl(id: "lt", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.2, y: 0.175), size: 0.15, height: 0.13,
                      shape: .roundedRect(corner: 0.35), inputs: .trigger(axis: 4, digital: 6),
                      note: "Hall effect or tactile, set by the switch on the back", callout: .above),
        PlacedControl(id: "rt", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.8, y: 0.175), size: 0.15, height: 0.13,
                      shape: .roundedRect(corner: 0.35), inputs: .trigger(axis: 5, digital: 7),
                      note: "Hall effect or tactile, set by the switch on the back", callout: .above),
        PlacedControl(id: "l4", kind: .shoulder, face: .top, center: CGPoint(x: 0.33, y: 0.3), size: 0.06, height: 0.04,
                      shape: .roundedRect(corner: 0.4), printed: "L4", inputs: .button(16),
                      callout: .above),
        PlacedControl(id: "r4", kind: .shoulder, face: .top, center: CGPoint(x: 0.67, y: 0.3), size: 0.06, height: 0.04,
                      shape: .roundedRect(corner: 0.4), printed: "R4", inputs: .button(17),
                      callout: .above),
        PlacedControl(id: "lb", kind: .shoulder, face: .top, center: CGPoint(x: 0.2, y: 0.76), size: 0.15, height: 0.045,
                      shape: .capsule(angleDegrees: 0), inputs: .button(4), callout: .below),
        PlacedControl(id: "rb", kind: .shoulder, face: .top, center: CGPoint(x: 0.8, y: 0.76), size: 0.15, height: 0.045,
                      shape: .capsule(angleDegrees: 0), inputs: .button(5), callout: .below),
        PlacedControl(id: "pair", kind: .other, face: .top, center: CGPoint(x: 0.445, y: 0.5), size: 0.022, height: 0.022,
                      readable: .notReported("The pair button is handled by the controller's radio and is not sent to the Mac")),
        PlacedControl(id: "usbc", kind: .port, face: .top, center: CGPoint(x: 0.5, y: 0.5), size: 0.06, height: 0.016,
                      shape: .roundedRect(corner: 0.5), note: "USB-C"),
        PlacedControl(id: "powerLight", kind: .light, face: .top, center: CGPoint(x: 0.578, y: 0.5), size: 0.012,
                      readable: .notReported("The power light shows charge and power; the Mac cannot read or set it")),

        // Front, left: the stick high and far out, the D-pad lower and inboard.
        PlacedControl(id: "lstick", kind: .stick, center: CGPoint(x: 0.206, y: 0.289), size: 0.108,
                      inputs: .stick(x: 0, y: 1, press: 11), callout: .below),
        PlacedControl(id: "dpad", kind: .dpad, center: CGPoint(x: 0.356, y: 0.548), size: 0.155, shape: .crossPad,
                      inputs: .hat(0), callout: .below),

        // Front, right: Y top, B right, A bottom, X left, and the right
        // stick lower and inboard, level with the D-pad.
        PlacedControl(id: "y", kind: .faceButton, center: CGPoint(x: 0.78, y: 0.189), size: 0.066, printed: "Y",
                      inputs: .button(3), callout: .above),
        PlacedControl(id: "x", kind: .faceButton, center: CGPoint(x: 0.705, y: 0.304), size: 0.066, printed: "X",
                      inputs: .button(2), callout: .left),
        PlacedControl(id: "b", kind: .faceButton, center: CGPoint(x: 0.855, y: 0.304), size: 0.066, printed: "B",
                      inputs: .button(1), callout: .right),
        PlacedControl(id: "a", kind: .faceButton, center: CGPoint(x: 0.78, y: 0.419), size: 0.066, printed: "A",
                      inputs: .button(0), callout: .below),
        PlacedControl(id: "rstick", kind: .stick, center: CGPoint(x: 0.621, y: 0.556), size: 0.108,
                      inputs: .stick(x: 2, y: 3, press: 12), callout: .below),

        // Front, center: View, Home and Menu in a row; Square under View,
        // Star beside X; the Profile button and its lights in the middle.
        PlacedControl(id: "view", kind: .menuButton, center: CGPoint(x: 0.358, y: 0.159), size: 0.05,
                      symbol: "minus", inputs: .button(8), note: "View", callout: .above),
        PlacedControl(id: "home", kind: .homeButton, center: CGPoint(x: 0.489, y: 0.159), size: 0.066,
                      symbol: "heart", inputs: .button(10), note: "Printed with the 8BitDo pixel heart. Press to power on, hold 3 s to power off", callout: .above),
        PlacedControl(id: "menu", kind: .menuButton, center: CGPoint(x: 0.621, y: 0.159), size: 0.05,
                      symbol: "plus", inputs: .button(9), note: "Menu", callout: .above),
        PlacedControl(id: "square", kind: .menuButton, center: CGPoint(x: 0.419, y: 0.285), size: 0.045,
                      symbol: "square.fill",
                      readable: .notReported("Square maps buttons on the controller itself, with L4, R4, PL or PR; it is not sent to the Mac")),
        PlacedControl(id: "star", kind: .menuButton, center: CGPoint(x: 0.567, y: 0.304), size: 0.045,
                      symbol: "star",
                      readable: .notReported("Star sets turbo on the controller itself; it is not sent to the Mac"),
                      note: "Turbo: hold a button and press Star"),
        PlacedControl(id: "profile", kind: .menuButton, center: CGPoint(x: 0.489, y: 0.415), size: 0.055, height: 0.032,
                      shape: .capsule(angleDegrees: 0),
                      readable: .notReported("The Profile button switches the controller's three onboard profiles and is not sent to the Mac")),
        PlacedControl(id: "profileLights", kind: .light, center: CGPoint(x: 0.489, y: 0.55), size: 0.014, height: 0.05,
                      shape: .capsule(angleDegrees: 0),
                      readable: .notReported("The three profile lights show the onboard profile; the Mac cannot read or set them")),

        // Back, as held (player's left on the left): PL and PR behind the
        // grips, a trigger mode switch behind each trigger, the BT and 2.4G
        // mode switch between the grips.
        PlacedControl(id: "pl", kind: .paddle, face: .back, center: CGPoint(x: 0.297, y: 0.476), size: 0.073, height: 0.11,
                      shape: .roundedRect(corner: 0.45), printed: "PL", inputs: .button(18),
                      note: "Left back button. In a custom profile it can copy another button", callout: .below),
        PlacedControl(id: "pr", kind: .paddle, face: .back, center: CGPoint(x: 0.703, y: 0.476), size: 0.073, height: 0.11,
                      shape: .roundedRect(corner: 0.45), printed: "PR", inputs: .button(19),
                      note: "Right back button. In a custom profile it can copy another button", callout: .below),
        PlacedControl(id: "ltSwitch", kind: .other, face: .back, center: CGPoint(x: 0.344, y: 0.184), size: 0.04, height: 0.018,
                      shape: .capsule(angleDegrees: 0),
                      readable: .notReported("Turns the trigger between Hall effect and tactile; it sends nothing")),
        PlacedControl(id: "rtSwitch", kind: .other, face: .back, center: CGPoint(x: 0.656, y: 0.184), size: 0.04, height: 0.018,
                      shape: .capsule(angleDegrees: 0),
                      readable: .notReported("Turns the trigger between Hall effect and tactile; it sends nothing")),
        PlacedControl(id: "modeSwitch", kind: .other, face: .back, center: CGPoint(x: 0.5, y: 0.46), size: 0.04, height: 0.018,
                      shape: .capsule(angleDegrees: 0),
                      readable: .notReported("The mode switch changes how the controller identifies itself; the switch itself is not sent")),
    ]
}
