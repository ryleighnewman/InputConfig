import Foundation
import CoreGraphics

extension ControllerLayout {
    /// Nintendo 64 Controller for Nintendo Switch Online (HAC-044, 057E:2019),
    /// the three-pronged "trident" pad: 160 mm wide and 152.6 mm tall seen
    /// face on, 66.7 mm deep. Nintendo's NSO edition keeps the original
    /// controls and adds Capture and HOME on the face, a small ZR beside R,
    /// and USB-C, SYNC, player and recharge LEDs along the top edge.
    ///
    /// How it is read. GameController lists the NSO pads on macOS 13 and
    /// later; RawHIDGamepadService then defers only when GameController's
    /// vendorName equals the HID product name ("N64 Controller"), since there
    /// are no keywords for 0x2019. Otherwise it is read raw in the Switch
    /// "simple" report through the bundled SDL row
    /// (SDLGameControllerDBData.swift:220), which is the path these indices
    /// are verified on:
    ///   a:b1 -> btn 0 (N64 A), b:b0 -> btn 1 (N64 B),
    ///   leftshoulder:b4 -> 4 (L), rightshoulder:b5 -> 5 (R),
    ///   lefttrigger:b6 -> 6 (Z), righttrigger:b10 -> 7 (ZR),
    ///   start:b9 -> 9, guide:b12 -> 10 (HOME), misc1:b13 -> 14 (Capture),
    ///   leftx:a0, lefty:a1 -> axes 0 and 1, D-pad h0 -> hat 0.
    /// The row maps the C buttons as half right-stick axes (-righty:b2,
    /// -rightx:b3, +righty:b7, +rightx:b8). SDLGameControllerDB.layout drops
    /// those targets, so the four buttons fall onto the extra slots in
    /// descriptor order: C-Up 22, C-Left 23, C-Down 24, C-Right 25.
    ///
    /// Nintendo positional scheme: the N64 has only two face buttons, A
    /// (lower, the main button) and B (up and to its left). A is the bottom
    /// button and reads btn 0; B reads btn 1 on the SDL row. How Apple's
    /// GameController maps this pad is not confirmed, so the face and C
    /// buttons are marked conditional.
    ///
    /// Every legend is printed or a symbol, because a raw read brands any
    /// 0x057E pad .switchPro and the Switch family would name btn 0 "B".
    static let nsoN64 = ControllerLayout(
        id: .nsoN64,
        displayName: "Nintendo 64 Controller (Switch Online)",
        maker: .nintendo,
        family: nil,
        modelNames: ButtonNames.ModelNames(
            renamed: [0: "A", 1: "B", 4: "L", 5: "R", 6: "Z", 7: "ZR", 9: "START", 10: "HOME", 14: "Capture",
                      22: "C-Up", 23: "C-Left", 24: "C-Down", 25: "C-Right"],
            short: [4: "L", 5: "R", 6: "Z", 7: "ZR", 9: "Start", 10: "Home"],
            absent: [2, 3, 8, 11, 12, 13, 15, 16, 17, 18, 19, 20, 21]),
        aspect: 160.0 / 152.6,
        topStrip: 0.2,
        backStrip: 0.18,
        silhouette: Silhouette(front: nsoN64Front,
                               top: Silhouette.roundedRectOps(corner: 0.2, inset: 0.04),
                               back: Silhouette.roundedRectOps(corner: 0.25, inset: 0.04)),
        controls: nsoN64Controls,
        offBody: [
            OffBodyInput(serialized: "btn 26", reason: "Raw SDL read only: the report's unused right stick click bit (b11), put on an extra slot. Never pressed"),
            OffBodyInput(serialized: "btn 27", reason: "Raw SDL read only: an unused bit in the simple report (b14), put on an extra slot. Never pressed"),
            OffBodyInput(serialized: "btn 28", reason: "Raw SDL read only: an unused bit in the simple report (b15), put on an extra slot. Never pressed"),
            OffBodyInput(serialized: "axi 6 +", reason: "Raw SDL read only: the report's right stick X field. The N64 pad has no second stick, so it rests at center"),
            OffBodyInput(serialized: "axi 7 +", reason: "Raw SDL read only: the report's right stick Y field. The N64 pad has no second stick, so it rests at center"),
        ],
        // Read raw: its USB IDs. Through GameController: the name Apple
        // gives it. Neither matches a Switch Pro Controller, an 8BitDo or a
        // Hyperkin N64 adapter.
        match: [
            [.vidPid(vendor: 0x057E, products: [0x2019])],
            [.gcVendorNameContains("N64 Controller")],
        ],
        matchPriority: 30,
        readability: .partial("Wired USB-C start-up not sent: InputConfig reads it over Bluetooth only"),
        approximate: true,
        sources: [
            "Nintendo support: Nintendo 64 Controller Diagram (parts 1 to 16: Control Pad, L, USB-C, Capture, SYNC, player LED, recharge LED, HOME, ZR, R, C buttons, A, B, START, Control Stick, Z on the underside)",
            "dimensions.com Nintendo 64 Controller (160 mm wide, 152.6 mm tall, 66.7 mm deep)",
            "SDL gamecontrollerdb.txt macOS row 030000007e0500001920000001000000 (NSO N64 Controller)",
            "OpenEmu-Silicon PR 732 (057E:2019 \"N64 Controller\", Pro Controller button bits, no right stick)",
            "BlueRetro discussion 783 (NSO N64 button bits)",
            "Product photos of the original NUS-005 and the NSO edition for placement",
        ]
    )

    /// The trident: a broad top with rounded shoulders, then three prongs.
    /// The outer prongs run almost straight down from the body's sides; the
    /// center prong, under the Control Stick, ends a little higher. The
    /// notches between the prongs reach up to about 58 percent of the height.
    static let nsoN64Front: [PathOp] = Silhouette.symmetric([
        .move(0.5, 0.025),
        .curve(0.14, 0.03, c1x: 0.36, c1y: 0.015, c2x: 0.22, c2y: 0.012),
        .curve(0.012, 0.2, c1x: 0.06, c1y: 0.045, c2x: 0.015, c2y: 0.1),
        .curve(0.04, 0.88, c1x: 0.008, c1y: 0.45, c2x: 0.02, c2y: 0.7),
        .curve(0.15, 0.99, c1x: 0.055, c1y: 0.96, c2x: 0.1, c2y: 0.995),
        .curve(0.25, 0.93, c1x: 0.2, c1y: 0.985, c2x: 0.24, c2y: 0.965),
        .curve(0.32, 0.62, c1x: 0.265, c1y: 0.82, c2x: 0.29, c2y: 0.68),
        .curve(0.375, 0.64, c1x: 0.335, c1y: 0.575, c2x: 0.365, c2y: 0.58),
        .curve(0.42, 0.92, c1x: 0.385, c1y: 0.7, c2x: 0.4, c2y: 0.85),
        .curve(0.5, 0.965, c1x: 0.435, c1y: 0.955, c2x: 0.47, c2y: 0.965),
    ])

    static let nsoN64Controls: [PlacedControl] = [
        // Top edge, left to right as Nintendo's diagram numbers it: L, the
        // USB-C port, SYNC, the player and recharge LEDs, ZR, R.
        PlacedControl(id: "l", kind: .shoulder, face: .top, center: CGPoint(x: 0.15, y: 0.7), size: 0.17, height: 0.05,
                      shape: .capsule(angleDegrees: 0), printed: "L", inputs: .button(4), callout: .below),
        PlacedControl(id: "r", kind: .shoulder, face: .top, center: CGPoint(x: 0.85, y: 0.7), size: 0.17, height: 0.05,
                      shape: .capsule(angleDegrees: 0), printed: "R", inputs: .button(5), callout: .below),
        PlacedControl(id: "zr", kind: .shoulder, face: .top, center: CGPoint(x: 0.73, y: 0.38), size: 0.06, height: 0.032,
                      shape: .capsule(angleDegrees: 0), printed: "ZR", inputs: .button(7),
                      note: "Added for Switch games; the original N64 pad has no ZR", callout: .above),
        PlacedControl(id: "usb-c", kind: .port, face: .top, center: CGPoint(x: 0.36, y: 0.45), size: 0.05, height: 0.02,
                      shape: .roundedRect(corner: 0.45), note: "USB-C for charging and pairing"),
        PlacedControl(id: "sync", kind: .other, face: .top, center: CGPoint(x: 0.46, y: 0.45), size: 0.025,
                      printed: "SYNC",
                      readable: .notReported("The controller handles SYNC itself for pairing; it never reaches the Mac")),
        PlacedControl(id: "player-leds", kind: .light, face: .top, center: CGPoint(x: 0.535, y: 0.45), size: 0.07, height: 0.012,
                      shape: .capsule(angleDegrees: 0),
                      readable: .notReported("InputConfig neither reads nor sets the player LEDs on this pad")),
        PlacedControl(id: "charge-led", kind: .light, face: .top, center: CGPoint(x: 0.605, y: 0.45), size: 0.016,
                      readable: .notReported("The recharge LED is driven by the controller itself")),

        // Front, top center: the NSO edition's Capture and HOME.
        PlacedControl(id: "capture", kind: .menuButton, center: CGPoint(x: 0.4, y: 0.1), size: 0.042,
                      shape: .roundedRect(corner: 0.2), symbol: "camera", inputs: .button(14),
                      note: "SDL misc1 (b13) on a raw read; macOS keeps its screenshot gesture off it while InputConfig reads the pad",
                      callout: .below),
        PlacedControl(id: "home", kind: .homeButton, center: CGPoint(x: 0.6, y: 0.1), size: 0.048,
                      symbol: "house", inputs: .button(10), callout: .below),

        // Left wing: the +Control Pad.
        PlacedControl(id: "dpad", kind: .dpad, center: CGPoint(x: 0.175, y: 0.34), size: 0.16, shape: .crossPad,
                      inputs: .hat(0), callout: .below),

        // Center: the red START button, the Control Stick where the center
        // prong meets the body. The stick has no click.
        PlacedControl(id: "start", kind: .menuButton, center: CGPoint(x: 0.5, y: 0.275), size: 0.07,
                      printed: "S", tint: .snesRed, inputs: .button(9), note: "START", callout: .below),
        PlacedControl(id: "stick", kind: .stick, center: CGPoint(x: 0.5, y: 0.525), size: 0.15, shape: .octagonGate,
                      inputs: .stick(x: 0, y: 1, press: nil), note: "Control Stick in an octagonal gate; it does not click",
                      callout: .below),

        // Right wing: blue A low, green B up and to its left, and the four
        // yellow C buttons in a diamond above and right of A.
        PlacedControl(id: "a", kind: .faceButton, center: CGPoint(x: 0.755, y: 0.41), size: 0.085,
                      printed: "A", tint: .snesBlue, inputs: .button(0),
                      readable: .conditional("btn 0 on the raw SDL read (a:b1). The GameController mapping of this pad is unconfirmed"),
                      callout: .below),
        PlacedControl(id: "b", kind: .faceButton, center: CGPoint(x: 0.665, y: 0.33), size: 0.085,
                      printed: "B", tint: .snesGreen, inputs: .button(1),
                      readable: .conditional("btn 1 on the raw SDL read (b:b0). The GameController mapping of this pad is unconfirmed"),
                      callout: .above),
        PlacedControl(id: "c-up", kind: .faceButton, center: CGPoint(x: 0.85, y: 0.19), size: 0.06,
                      symbol: "arrowtriangle.up.fill", tint: .snesYellow, inputs: .button(22),
                      readable: .conditional("Raw SDL read: the row's -righty:b2 is dropped, so C-Up lands on the first extra slot, btn 22"),
                      callout: .above),
        PlacedControl(id: "c-left", kind: .faceButton, center: CGPoint(x: 0.775, y: 0.269), size: 0.06,
                      symbol: "arrowtriangle.left.fill", tint: .snesYellow, inputs: .button(23),
                      readable: .conditional("Raw SDL read: the row's -rightx:b3 is dropped, so C-Left lands on extra slot btn 23"),
                      callout: .below),
        PlacedControl(id: "c-right", kind: .faceButton, center: CGPoint(x: 0.925, y: 0.269), size: 0.06,
                      symbol: "arrowtriangle.right.fill", tint: .snesYellow, inputs: .button(25),
                      readable: .conditional("Raw SDL read: the row's +rightx:b8 is dropped, so C-Right lands on extra slot btn 25"),
                      callout: .below),
        PlacedControl(id: "c-down", kind: .faceButton, center: CGPoint(x: 0.85, y: 0.347), size: 0.06,
                      symbol: "arrowtriangle.down.fill", tint: .snesYellow, inputs: .button(24),
                      readable: .conditional("Raw SDL read: the row's +righty:b7 is dropped, so C-Down lands on extra slot btn 24"),
                      callout: .below),

        // Back: the Z trigger on the underside of the center prong, behind
        // the Control Stick. Digital.
        PlacedControl(id: "z", kind: .trigger(.digital), face: .back, center: CGPoint(x: 0.5, y: 0.45), size: 0.1, height: 0.075,
                      shape: .roundedRect(corner: 0.35), printed: "Z", inputs: .button(6),
                      note: "Z trigger under the center grip; SDL lefttrigger (b6), digital", callout: .below),
    ]
}
