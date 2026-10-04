import Foundation
import CoreGraphics

extension ControllerLayout {
    /// 8BitDo Ultimate 2C Wireless (2.4G and Bluetooth, Windows and Android).
    /// Xbox-style offset sticks on a rounder, Switch Pro-like body: the left
    /// stick high on the left, the D-pad low toward the center, the face
    /// diamond high on the right (Xbox order, letters printed monochrome) and
    /// the right stick low toward the center. The center has a round Home
    /// button with the pixel-heart logo and a ring light (the status LED), the
    /// View (minus) and Menu (plus) buttons either side of it, and below them
    /// the square mapping button, the mapping indicator LED and the star
    /// (turbo) button. The top edge has LB and RB over Hall effect triggers,
    /// with the L4 and R4 "fast bumpers" tucked under the inner ends of the
    /// bumpers, inboard of the triggers; the pair button, USB-C port and power
    /// light sit at the center of the top edge. The only thing on the back is
    /// the Bluetooth / 2.4G mode switch. No back paddles, no Profile button.
    ///
    /// Front positions are measured from 8BitDo's own part diagram in the
    /// Ultimate 2C Wireless manual (outline 800 by 562 units, so the aspect
    /// is 1.42). The top strip follows the manual's rear view; depths on it
    /// are estimates.
    ///
    /// Inputs. macOS does not list this pad in GameController, so InputConfig
    /// reads it raw. Bluetooth (2DC8:301B) and 2DC8:301D use the bundled SDL
    /// rows (SDLGameControllerDBData.swift, "8BitDo Ultimate 2C"), mapped by
    /// SDLGameControllerDB.buttonSlots: a b0 to btn 0, b b1 to 1, x b3 to 2,
    /// y b4 to 3, leftshoulder b6 to 4, rightshoulder b7 to 5, back b10 to 8,
    /// start b11 to 9, guide b12 to 10, leftstick b13 to 11, rightstick b14
    /// to 12, the D-pad h0 to hat 0, sticks a0 to a3 to axes 0 to 3,
    /// lefttrigger a5 to axis 4 and righttrigger a4 to axis 5, each with a
    /// digital copy on btn 6 and 7 (the row names no trigger button). The row
    /// calls L4 paddle2 (b2) and R4 paddle1 (b5), which land on btn 16 and 17;
    /// they are top bumpers, not back paddles. 2DC8:310A (the pad in X mode
    /// over USB or its 2.4G receiver) is the hand-coded XInput profile
    /// (ControllerProfileDatabase, HIDReportDecoder.decodeXInput): the same
    /// slots for every standard control, and no bit for L4 or R4.
    static let eightBitDoUltimate2C = ControllerLayout(
        id: .eightBitDoUltimate2C,
        displayName: "8BitDo Ultimate 2C",
        maker: .eightBitDo,
        family: .xbox,
        modelNames: ButtonNames.ModelNames(renamed: [10: "Home", 16: "L4", 17: "R4"],
                                           short: [10: "Home", 16: "L4", 17: "R4"],
                                           absent: [13, 14, 15, 18, 19]),
        aspect: 1.42,
        topStrip: 0.22,
        backStrip: 0.24,
        silhouette: Silhouette(front: Silhouette.symmetric(eightBitDoUltimate2CFrontLeft),
                               top: Silhouette.roundedRectOps(corner: 0.18, inset: 0.04),
                               back: Silhouette.roundedRectOps(corner: 0.2, inset: 0.04)),
        controls: eightBitDoUltimate2CControls,
        offBody: [
            OffBodyInput(serialized: "btn 22",
                         reason: "Raw SDL read only: report bit b8, which the row does not name, put on an extra slot. On 8BitDo's DInput report it is usually the digital LT bit, so it may press with the left trigger (not confirmed on this pad)", copy: true),
            OffBodyInput(serialized: "btn 23",
                         reason: "Raw SDL read only: report bit b9, which the row does not name, put on an extra slot. On 8BitDo's DInput report it is usually the digital RT bit, so it may press with the right trigger (not confirmed on this pad)", copy: true),
        ],
        // Raw IDs only: the pad never reaches GameController. 0x301B is the
        // Bluetooth identity and 0x301D the other identity the SDL rows name;
        // 0x310A is the 2C in X mode. The plain Ultimate and Ultimate C use
        // other product IDs (0x3011 to 0x3017, and 0x3106 in X mode).
        match: [
            [.vidPid(vendor: 0x2DC8, products: [0x301B, 0x301D, 0x310A])],
        ],
        matchPriority: 30,
        approximate: true,
        sources: [
            "8BitDo Ultimate 2C Wireless Controller manual, part diagrams (download.8bitdo.com/Manual/Controller/Ultimate/Ultimate-2C-Wireless-Controller.pdf)",
            "8bitdo.com Ultimate 2C Wireless Controller product page (Hall effect sticks and triggers, remappable L4 and R4 fast bumpers)",
            "hlplanet.com and nintendolife.com Ultimate 2C reviews (L4 and R4 under the bumpers, inboard of the triggers)",
            "github.com/xsyetopz/OpenJoystickDriver issues 34 and 41 (2DC8:301B Bluetooth report; L4 and R4 on button bits 2 and 5)",
            "github.com/libsdl-org/SDL issue 12219 (2DC8:310A over USB and 2.4G, 2DC8:301B over Bluetooth)",
            "SDL gamecontrollerdb Mac rows for 2DC8:301B and 2DC8:301D (bundled in SDLGameControllerDBData.swift)",
        ]
    )

    /// The front outline's left half, traced from the manual: a flat top edge
    /// with the bumper lip rising over each shoulder, a long gently curved
    /// side, round grips that hang down and splay a little, and a flat arch
    /// between them.
    static let eightBitDoUltimate2CFrontLeft: [PathOp] = [
        .move(0.5, 0.02),
        .line(0.31, 0.02),
        // The LB lip over the left shoulder.
        .curve(0.236, 0.0, c1x: 0.29, c1y: 0.02, c2x: 0.27, c2y: 0.0),
        .curve(0.1, 0.103, c1x: 0.19, c1y: 0.0, c2x: 0.13, c2y: 0.05),
        // The side, widest low on the grip.
        .curve(0.032, 0.317, c1x: 0.07, c1y: 0.15, c2x: 0.045, c2y: 0.24),
        .curve(0.0, 0.744, c1x: 0.015, c1y: 0.45, c2x: 0.0, c2y: 0.62),
        // The grip's rounded end.
        .curve(0.1175, 1.0, c1x: 0.0, c1y: 0.88, c2x: 0.06, c2y: 0.99),
        .curve(0.145, 0.957, c1x: 0.13, c1y: 1.0, c2x: 0.14, c2y: 0.975),
        // The grip's inner edge up to the flat arch.
        .curve(0.265, 0.708, c1x: 0.18, c1y: 0.88, c2x: 0.23, c2y: 0.76),
        .quad(0.32, 0.69, cx: 0.285, cy: 0.69),
        .line(0.5, 0.69),
    ]

    static let eightBitDoUltimate2CControls: [PlacedControl] = [
        // Top: Hall effect triggers at the outer corners, the bumpers along
        // the front of the shoulders, L4 and R4 behind the bumpers' inner
        // ends, and the pair button, USB-C port and power light at center.
        PlacedControl(id: "lt", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.165, y: 0.195), size: 0.12, height: 0.13,
                      shape: .roundedRect(corner: 0.35), inputs: .trigger(axis: 4, digital: 6),
                      note: "Hall effect", callout: .above),
        PlacedControl(id: "rt", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.835, y: 0.195), size: 0.12, height: 0.13,
                      shape: .roundedRect(corner: 0.35), inputs: .trigger(axis: 5, digital: 7),
                      note: "Hall effect", callout: .above),
        PlacedControl(id: "lb", kind: .shoulder, face: .top, center: CGPoint(x: 0.205, y: 0.78), size: 0.2, height: 0.045,
                      shape: .capsule(angleDegrees: -6), inputs: .button(4), callout: .below),
        PlacedControl(id: "rb", kind: .shoulder, face: .top, center: CGPoint(x: 0.795, y: 0.78), size: 0.2, height: 0.045,
                      shape: .capsule(angleDegrees: 6), inputs: .button(5), callout: .below),
        PlacedControl(id: "l4", kind: .shoulder, face: .top, center: CGPoint(x: 0.285, y: 0.36), size: 0.075, height: 0.045,
                      shape: .roundedRect(corner: 0.4), printed: "L4", inputs: .button(16),
                      pathInputs: [.rawProfile: .none],
                      readable: .conditional("Read over Bluetooth through the bundled SDL row (2DC8:301B, 301D); the XInput profile for 2DC8:310A has no bit for it"),
                      note: "Sends its own button until it is assigned on the pad (hold L4 and a button, then press the mapping button); then the Mac gets that button",
                      callout: .below),
        PlacedControl(id: "r4", kind: .shoulder, face: .top, center: CGPoint(x: 0.715, y: 0.36), size: 0.075, height: 0.045,
                      shape: .roundedRect(corner: 0.4), printed: "R4", inputs: .button(17),
                      pathInputs: [.rawProfile: .none],
                      readable: .conditional("Read over Bluetooth through the bundled SDL row (2DC8:301B, 301D); the XInput profile for 2DC8:310A has no bit for it"),
                      note: "Sends its own button until it is assigned on the pad (hold R4 and a button, then press the mapping button); then the Mac gets that button",
                      callout: .below),
        PlacedControl(id: "pair", kind: .other, face: .top, center: CGPoint(x: 0.441, y: 0.3), size: 0.022,
                      readable: .notReported("Bluetooth pairing and receiver re-pairing, handled by the controller's radio"),
                      callout: .left),
        PlacedControl(id: "usbc", kind: .port, face: .top, center: CGPoint(x: 0.5, y: 0.3), size: 0.065, height: 0.02,
                      shape: .roundedRect(corner: 0.5), note: "USB-C for charging and wired play", callout: .below),
        PlacedControl(id: "powerLight", kind: .light, face: .top, center: CGPoint(x: 0.558, y: 0.3), size: 0.016,
                      readable: .notReported("Red charge and low battery light, driven by the controller"),
                      callout: .right),

        // Front, center: Home with its ring light, View and Minus either side.
        PlacedControl(id: "home", kind: .homeButton, center: CGPoint(x: 0.5, y: 0.159), size: 0.069,
                      symbol: "heart", inputs: .button(10),
                      note: "The ring around it is the status light, driven by the controller. It also powers the pad on and off",
                      callout: .above),
        PlacedControl(id: "view", kind: .menuButton, center: CGPoint(x: 0.368, y: 0.159), size: 0.046,
                      symbol: "minus", inputs: .button(8), callout: .above),
        PlacedControl(id: "menu", kind: .menuButton, center: CGPoint(x: 0.632, y: 0.159), size: 0.046,
                      symbol: "plus", inputs: .button(9), callout: .above),
        // Below them: mapping button, mapping indicator, star.
        PlacedControl(id: "mapping", kind: .menuButton, center: CGPoint(x: 0.431, y: 0.265), size: 0.05,
                      symbol: "square.fill",
                      readable: .notReported("Assigns L4 and R4 on the controller itself; the pad never sends it"),
                      callout: .below),
        PlacedControl(id: "mappingLight", kind: .light, center: CGPoint(x: 0.5, y: 0.265), size: 0.014,
                      readable: .notReported("Mapping and turbo indicator, driven by the controller"),
                      callout: .below),
        PlacedControl(id: "star", kind: .menuButton, center: CGPoint(x: 0.569, y: 0.265), size: 0.05,
                      symbol: "star.fill",
                      readable: .notReported("Turbo: the controller handles it in firmware and never sends it"),
                      callout: .below),

        // Left wing: the stick high on the left.
        PlacedControl(id: "lstick", kind: .stick, center: CGPoint(x: 0.211, y: 0.28), size: 0.128,
                      inputs: .stick(x: 0, y: 1, press: 11), note: "Hall effect", callout: .below),

        // Right wing: ABXY in Xbox order, letters printed monochrome.
        PlacedControl(id: "y", kind: .faceButton, center: CGPoint(x: 0.786, y: 0.178), size: 0.068, printed: "Y",
                      inputs: .button(3), callout: .above),
        PlacedControl(id: "x", kind: .faceButton, center: CGPoint(x: 0.714, y: 0.279), size: 0.068, printed: "X",
                      inputs: .button(2), callout: .auto),
        PlacedControl(id: "b", kind: .faceButton, center: CGPoint(x: 0.857, y: 0.279), size: 0.068, printed: "B",
                      inputs: .button(1), callout: .right),
        PlacedControl(id: "a", kind: .faceButton, center: CGPoint(x: 0.786, y: 0.38), size: 0.068, printed: "A",
                      inputs: .button(0), callout: .below),

        // Lower center: the D-pad and the right stick.
        PlacedControl(id: "dpad", kind: .dpad, center: CGPoint(x: 0.3625, y: 0.507), size: 0.16, shape: .crossPad,
                      inputs: .hat(0), callout: .below),
        PlacedControl(id: "rstick", kind: .stick, center: CGPoint(x: 0.6375, y: 0.506), size: 0.128,
                      inputs: .stick(x: 2, y: 3, press: 12), note: "Hall effect", callout: .below),

        // Back: the connection switch, centered above the arch.
        PlacedControl(id: "modeSwitch", kind: .other, face: .back, center: CGPoint(x: 0.5, y: 0.5), size: 0.07, height: 0.03,
                      shape: .capsule(angleDegrees: 0),
                      readable: .notReported("Bluetooth or 2.4G: it changes how the pad identifies itself (Bluetooth is 2DC8:301B), it is not an input"),
                      callout: .below),
    ]
}
