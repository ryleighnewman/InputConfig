import Foundation
import CoreGraphics

extension ControllerLayout {
    /// Google Stadia Controller (H2B, 18D1:9400), 163 mm wide, 105 mm tall
    /// and 65 mm deep. GameController does not list it, so the raw HID
    /// service reads it through the bundled SDL row
    /// (SDLGameControllerDBData.swift:138) on USB and Bluetooth alike.
    ///
    /// The SDL row names b0 to b10. HIDDescriptorParser.sdlElements sorts the
    /// descriptor's button usages by number, so the ones the row leaves out
    /// land on the extra slots from 22 (SDLGameControllerDB.swift:244-249):
    /// Assistant (usage 0x11) btn 22, Capture (0x12) btn 23, the two digital
    /// trigger bits (0x13, 0x14) btn 24 and 25, and the Consumer usages
    /// Play/Pause, Volume Up and Volume Down btn 26, 27 and 28. The analog
    /// triggers also press btn 6 and 7 (SDLGameControllerDB.swift:238-242).
    ///
    /// `inputs` is the raw SDL read, the only one today. `pathInputs` gives
    /// what the GameController path would number if Apple ever listed the
    /// pad: Capture by name on btn 14, Assistant on the first dynamic slot.
    ///
    /// The bottom edge (not drawn) holds the microphone and the 3.5 mm
    /// headset jack, which works over USB only and is not an input.
    static let stadia = ControllerLayout(
        id: .stadia,
        displayName: "Stadia Controller",
        maker: .google,
        family: .stadia,
        modelNames: ButtonNames.ModelNames(renamed: [22: "Assistant", 23: "Capture"],
                                           short: [22: "Assistant", 23: "Capture"],
                                           absent: [13, 14, 15]),
        aspect: 163.0 / 105.0,
        topStrip: 0.22,
        backStrip: 0,
        silhouette: Silhouette(front: stadiaFront,
                               top: Silhouette.roundedRectOps(corner: 0.22, inset: 0.04)),
        controls: stadiaControls,
        offBody: [
            OffBodyInput(serialized: "btn 24", reason: "Digital trigger bit (HID button usage 0x13), a copy of a full L2 or R2 pull on the raw SDL read", copy: true),
            OffBodyInput(serialized: "btn 25", reason: "Digital trigger bit (HID button usage 0x14), a copy of a full L2 or R2 pull on the raw SDL read", copy: true),
            OffBodyInput(serialized: "btn 26", reason: "Play/Pause media key declared in the descriptor; no physical control sends it"),
            OffBodyInput(serialized: "btn 27", reason: "Volume Up media key declared in the descriptor; no physical control sends it"),
            OffBodyInput(serialized: "btn 28", reason: "Volume Down media key declared in the descriptor; no physical control sends it"),
        ],
        // Read raw, it is recognized by its USB IDs (Bluetooth reports the
        // same pair). The brand comes from the name "Stadia", which no other
        // pad uses, so it also covers a GameController listing.
        match: [
            [.vidPid(vendor: 0x18D1, products: [0x9400])],
            [.brand(.stadia)],
            [.gcProductCategoryContains("Stadia")],
        ],
        matchPriority: 10,
        approximate: true,
        sources: [
            "support.google.com/stadia/answer/9565956 (Stadia Controller features and specifications: 163 x 105 x 65 mm; front: D-pad, sticks, A/B/X/Y, Stadia button with status light; top: Options, Menu, Assistant, Capture, bumpers, triggers, USB-C; bottom: microphone, headset jack)",
            "SDL gamecontrollerdb.txt Google Stadia Controller rows and src/joystick/hidapi/SDL_hidapi_stadia.c (button bits: Capture 0x01, Assistant 0x02 of byte 2)",
            "denilson.sa.nom.br/gamepad-cheatsheet/Google_Stadia.html",
            "Product photos of the Stadia Controller for placement",
        ],
        // Written for the raw read, the only one today (Capture on 23).
        modelNamesPaths: [.rawSDL]
    )

    /// The front outline: a wide, nearly flat top edge with round shoulders,
    /// sides that run down into thick, rounded grips angled slightly out,
    /// and a broad shallow arch between the grips under the sticks.
    static let stadiaFront: [PathOp] = Silhouette.symmetric([
        .move(0.5, 0.035),
        .curve(0.15, 0.03, c1x: 0.36, c1y: 0.035, c2x: 0.22, c2y: 0.02),
        .curve(0.02, 0.24, c1x: 0.07, c1y: 0.04, c2x: 0.025, c2y: 0.12),
        .curve(0.065, 0.86, c1x: 0.012, c1y: 0.45, c2x: 0.025, c2y: 0.72),
        .curve(0.235, 0.955, c1x: 0.1, c1y: 0.975, c2x: 0.18, c2y: 0.995),
        .curve(0.36, 0.775, c1x: 0.29, c1y: 0.915, c2x: 0.315, c2y: 0.8),
        .curve(0.5, 0.735, c1x: 0.4, c1y: 0.75, c2x: 0.45, c2y: 0.735),
    ])

    static let stadiaControls: [PlacedControl] = [
        // Top: L1 and R1 along the front lip, the large analog L2 and R2
        // behind them, the USB-C port in the middle of the top edge.
        PlacedControl(id: "l2", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.2, y: 0.1864), size: 0.16, height: 0.13,
                      shape: .roundedRect(corner: 0.35), inputs: .trigger(axis: 4, digital: 6),
                      note: "Brake usage on the raw read; a separate digital bit also lands on btn 24 or 25", callout: .above),
        PlacedControl(id: "r2", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.8, y: 0.1864), size: 0.16, height: 0.13,
                      shape: .roundedRect(corner: 0.35), inputs: .trigger(axis: 5, digital: 7),
                      note: "Accelerator usage on the raw read; a separate digital bit also lands on btn 24 or 25", callout: .above),
        PlacedControl(id: "l1", kind: .shoulder, face: .top, center: CGPoint(x: 0.2, y: 0.76), size: 0.18, height: 0.045,
                      shape: .capsule(angleDegrees: 0), inputs: .button(4), callout: .below),
        PlacedControl(id: "r1", kind: .shoulder, face: .top, center: CGPoint(x: 0.8, y: 0.76), size: 0.18, height: 0.045,
                      shape: .capsule(angleDegrees: 0), inputs: .button(5), callout: .below),
        PlacedControl(id: "usb-c", kind: .port, face: .top, center: CGPoint(x: 0.5, y: 0.5), size: 0.05, height: 0.02,
                      shape: .roundedRect(corner: 0.45), note: "USB-C for charging and wired play"),

        // Front, left lobe: the one-piece D-pad high.
        PlacedControl(id: "dpad", kind: .dpad, center: CGPoint(x: 0.215, y: 0.35), size: 0.15, shape: .crossPad,
                      inputs: .hat(0), callout: .below),

        // Front, right lobe: A bottom, B right, X left, Y top, one color.
        PlacedControl(id: "y", kind: .faceButton, center: CGPoint(x: 0.785, y: 0.245), size: 0.064,
                      inputs: .button(3), callout: .above),
        PlacedControl(id: "x", kind: .faceButton, center: CGPoint(x: 0.715, y: 0.35), size: 0.064,
                      inputs: .button(2), callout: .left),
        PlacedControl(id: "b", kind: .faceButton, center: CGPoint(x: 0.855, y: 0.35), size: 0.064,
                      inputs: .button(1), callout: .right),
        PlacedControl(id: "a", kind: .faceButton, center: CGPoint(x: 0.785, y: 0.455), size: 0.064,
                      inputs: .button(0), callout: .below),

        // Sticks: symmetric, below and inboard of the D-pad and face buttons.
        PlacedControl(id: "lstick", kind: .stick, center: CGPoint(x: 0.355, y: 0.585), size: 0.135,
                      inputs: .stick(x: 0, y: 1, press: 11), callout: .below),
        PlacedControl(id: "rstick", kind: .stick, center: CGPoint(x: 0.645, y: 0.585), size: 0.135,
                      inputs: .stick(x: 2, y: 3, press: 12), callout: .below),

        // Center: Options and Menu high, the Stadia button between and a
        // little lower with its status light around it, Assistant and
        // Capture below Options and Menu.
        PlacedControl(id: "options", kind: .menuButton, center: CGPoint(x: 0.415, y: 0.235), size: 0.036,
                      symbol: "ellipsis", inputs: .button(8), callout: .above),
        PlacedControl(id: "menu", kind: .menuButton, center: CGPoint(x: 0.585, y: 0.235), size: 0.036,
                      symbol: "line.3.horizontal", inputs: .button(9), callout: .above),
        PlacedControl(id: "status-light", kind: .light, center: CGPoint(x: 0.5, y: 0.29), size: 0.072,
                      readable: .notReported("The status light shows pairing and charge; InputConfig neither reads nor sets it"),
                      overlayOf: "stadia"),
        PlacedControl(id: "stadia", kind: .homeButton, center: CGPoint(x: 0.5, y: 0.29), size: 0.056,
                      symbol: "house", inputs: .button(10),
                      note: "Printed with the Stadia logo", callout: .below),
        PlacedControl(id: "assistant", kind: .menuButton, center: CGPoint(x: 0.435, y: 0.375), size: 0.034,
                      symbol: "ellipsis.bubble", inputs: .button(22),
                      pathInputs: [.gameController: .button(20)],
                      note: "Read raw as the first extra button (btn 22); a GameController read would give it the first dynamic slot (btn 20)",
                      callout: .below),
        PlacedControl(id: "capture", kind: .menuButton, center: CGPoint(x: 0.565, y: 0.375), size: 0.034,
                      symbol: "camera.viewfinder", inputs: .button(23),
                      pathInputs: [.gameController: .button(14)],
                      note: "Read raw as the second extra button (btn 23); a GameController read names it Capture on btn 14",
                      callout: .below),
    ]
}
