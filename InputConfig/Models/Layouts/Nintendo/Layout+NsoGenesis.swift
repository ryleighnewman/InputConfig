import Foundation
import CoreGraphics

extension ControllerLayout {
    /// SEGA Genesis Control Pad for Nintendo Switch Online (057E:201E), a
    /// wireless replica of the Model 1 three-button pad: the wide kidney body
    /// with short round grips, the big round D-pad in its chrome ring on the
    /// left, A, B and C rising to the right in a glossy well, and START above
    /// them. Nintendo moved its own buttons off the face: Capture, the USB-C
    /// port and HOME sit along the top edge, MODE on the top right shoulder,
    /// and the player LEDs and SYNC on the underside.
    ///
    /// Read paths. There is no SDL GameControllerDB row for this pad on
    /// macOS, so read raw it gets the plain descriptor layout: the Switch
    /// Bluetooth descriptor's simple report (ID 0x3F) with 16 button bits
    /// in Switch order (B, A, Y, X, L, R, ZL, ZR, Minus, Plus, LS, RS,
    /// HOME, Capture), one hat and four 16-bit stick axes. The pad puts
    /// each of its buttons on a Switch button bit (Linux hid-nintendo
    /// gencon_button_mappings): A on A, B on B, C on R, START on Plus,
    /// MODE on ZR, and on the six-button pad X on X, Y on Y, Z on L.
    ///
    /// Face buttons use the POSITIONAL numbering shared by every Nintendo
    /// pad (btn 0 the bottom button, 1 the right): B rides the Switch B bit
    /// (btn 0) and A the Switch A bit (btn 1). The GameController path is
    /// being changed to positional now, so `inputs` assumes GameController
    /// lists the pad with its Switch bits on the matching extendedGamepad
    /// elements; `pathInputs[.rawDescriptor]` holds the raw read where it
    /// differs (HOME and Capture).
    static let nsoGenesis = ControllerLayout(
        id: .nsoGenesis,
        displayName: "SEGA Genesis Control Pad (Switch Online)",
        maker: .nintendo,
        family: nil,
        // Read raw from its descriptor, it reports the Switch bits it rides
        // on; these name them for what this pad prints.
        modelNames: ButtonNames.ModelNames(renamed: [0: "B", 1: "A", 2: "Y", 3: "X", 12: "HOME", 13: "Capture", 9: "START", 7: "MODE", 5: "C"],
                                           absent: [6, 8, 10, 11, 14, 15, 16, 17]),
        aspect: 1.8,
        topStrip: 0.16,
        backStrip: 0.22,
        silhouette: Silhouette(front: nsoGenesisFront,
                               top: nsoGenesisTop,
                               back: Silhouette.roundedRectOps(corner: 0.2, inset: 0.04)),
        controls: nsoGenesisControls,
        variants: [
            LayoutVariant(id: "three-button", displayName: "Genesis (3 buttons)", isDefault: true),
            LayoutVariant(id: "six-button", displayName: "Mega Drive (6 buttons, Japan)"),
        ],
        offBody: nsoGenesisOffBody,
        // Raw HID: its USB IDs. GameController: its name, and only on a
        // listed pad (one with a "Button A" element), so a raw HID pad
        // from another maker whose product name says Genesis is not drawn
        // as this one.
        match: [
            [.vidPid(vendor: 0x057E, products: [0x201E])],
            // Through GameController only under a Switch brand, the pads
            // whose face buttons are read by position as drawn here.
            [.brand(.switchPro), .gcVendorNameContains("MD/Gen")],
            [.brand(.switchPro), .gcVendorNameContains("Genesis")],
            [.brand(.switchPro), .gcVendorNameContains("Mega Drive")],
            [.brand(.switchPro), .gcProductCategoryContains("Genesis")],
        ],
        matchPriority: 20,
        readability: .partial("Read over Bluetooth. Over USB-C InputConfig sends the pad no start-up handshake, so a wired pad likely reports nothing"),
        approximate: true,
        sources: [
            "nintendo.com SEGA Genesis Control Pad product photos (front view and front angle view) for placement and outline",
            "Nintendo Support: SEGA Genesis Control Pad Diagram (D-pad, Capture, HOME, MODE, START, A, B, C; Recharge LED and USB-C on top; Player LED and SYNC on the bottom)",
            "Nintendo Support: SEGA Genesis Control Pad Overview and FAQ (three-button model in the Americas, six-button model in Japan)",
            "Linux drivers/hid/hid-nintendo.c gencon_button_mappings (A, B, C, X, Y, Z, Mode, Start, Home, Capture to Switch bits)",
            "SDL_GameControllerDB: only a Linux row for 057E:201E, none for macOS",
            "Switch Bluetooth HID descriptor (dekuNukem Nintendo_Switch_Reverse_Engineering): simple report 0x3F",
        ],
        modelNamesPaths: [.rawDescriptor]
    )

    /// The front outline, traced from Nintendo's front photo: a broad top
    /// that falls away to round outer lobes, short grips with round ends,
    /// and a wide shallow arch between them.
    static let nsoGenesisFront: [PathOp] = Silhouette.symmetric([
        .move(0.5, 0.02),
        .curve(0.1, 0.13, c1x: 0.32, c1y: 0.015, c2x: 0.18, c2y: 0.06),
        .curve(0.015, 0.5, c1x: 0.04, c1y: 0.2, c2x: 0.01, c2y: 0.36),
        .curve(0.09, 0.93, c1x: 0.02, c1y: 0.68, c2x: 0.05, c2y: 0.85),
        .curve(0.215, 0.975, c1x: 0.12, c1y: 0.99, c2x: 0.18, c2y: 1.0),
        .curve(0.33, 0.78, c1x: 0.255, c1y: 0.95, c2x: 0.28, c2y: 0.82),
        .curve(0.5, 0.72, c1x: 0.38, c1y: 0.74, c2x: 0.44, c2y: 0.72),
    ])

    /// The top edge seen from above: the rear edge bows out in the middle
    /// and rounds off into the lobes.
    static let nsoGenesisTop: [PathOp] = Silhouette.symmetric([
        .move(0.5, 0.05),
        .curve(0.08, 0.3, c1x: 0.3, c1y: 0.04, c2x: 0.14, c2y: 0.12),
        .curve(0.02, 0.75, c1x: 0.03, c1y: 0.42, c2x: 0.015, c2y: 0.6),
        .quad(0.1, 0.96, cx: 0.03, cy: 0.95),
        .line(0.5, 0.96),
    ])

    static let nsoGenesisControls: [PlacedControl] = [
        // Top edge, left to right: Capture, USB-C with the recharge LED
        // just in front of it, HOME, and MODE on the right shoulder.
        PlacedControl(id: "capture", kind: .menuButton, face: .top, center: CGPoint(x: 0.336, y: 0.45), size: 0.036,
                      shape: .roundedRect(corner: 0.25), symbol: "camera", inputs: .button(14),
                      pathInputs: [.rawDescriptor: .button(13)],
                      note: "Capture: btn 14 through GameController, btn 13 read raw (the Switch Capture bit)", callout: .above, name: "Capture"),
        PlacedControl(id: "usb-c", kind: .port, face: .top, center: CGPoint(x: 0.5, y: 0.45), size: 0.06, height: 0.018,
                      shape: .roundedRect(corner: 0.45), note: "USB-C for charging and pairing to a console"),
        PlacedControl(id: "charge-led", kind: .light, face: .top, center: CGPoint(x: 0.5, y: 0.78), size: 0.012,
                      readable: .notReported("The recharge LED shows charging on its own; it is not an input")),
        PlacedControl(id: "home", kind: .homeButton, face: .top, center: CGPoint(x: 0.664, y: 0.45), size: 0.036,
                      symbol: "house", inputs: .button(10),
                      pathInputs: [.rawDescriptor: .button(12)],
                      note: "HOME: btn 10 through GameController, btn 12 read raw (the Switch HOME bit)", callout: .above, name: "HOME"),
        PlacedControl(id: "mode", kind: .menuButton, face: .top, center: CGPoint(x: 0.84, y: 0.42), size: 0.11, height: 0.03,
                      shape: .capsule(angleDegrees: 0), printed: "MODE", inputs: .button(7),
                      note: "Sends the Switch ZR bit. On a Switch it returns to the game list", callout: .above),

        // Front, left: the round D-pad disc inside its chrome ring.
        PlacedControl(id: "dpad", kind: .dpad, center: CGPoint(x: 0.235, y: 0.477), size: 0.22, shape: .disc,
                      inputs: .hat(0), note: "One round disc that rocks in eight directions", callout: .below),

        // Front, right: START above the button well, A, B and C rising to
        // the right inside it. Letters printed in red.
        PlacedControl(id: "start", kind: .menuButton, center: CGPoint(x: 0.704, y: 0.211), size: 0.085, height: 0.035,
                      shape: .capsule(angleDegrees: -22), symbol: "line.3.horizontal", inputs: .button(9),
                      note: "START, sent as the Switch Plus bit", callout: .above, name: "START"),
        PlacedControl(id: "a", kind: .faceButton, center: CGPoint(x: 0.67, y: 0.576), size: 0.085,
                      printed: "A", tint: .snesRed, inputs: .button(1),
                      note: "Sends the Switch A bit (btn 1, the right position)", callout: .below),
        PlacedControl(id: "b", kind: .faceButton, center: CGPoint(x: 0.768, y: 0.48), size: 0.085,
                      printed: "B", tint: .snesRed, inputs: .button(0),
                      note: "Sends the Switch B bit (btn 0, the bottom position)", callout: .below),
        PlacedControl(id: "c", kind: .faceButton, center: CGPoint(x: 0.874, y: 0.408), size: 0.085,
                      printed: "C", tint: .snesRed, inputs: .button(5),
                      note: "Sends the Switch R bit (btn 5)", callout: .below),

        // Six-button Mega Drive pad (Japan) only: X, Y and Z in a row above
        // A, B and C. Unverified placement.
        PlacedControl(id: "x", kind: .faceButton, center: CGPoint(x: 0.62, y: 0.40), size: 0.065,
                      printed: "X", inputs: .button(3),
                      note: "Six-button pad only. Sends the Switch X bit", callout: .below, variants: ["six-button"]),
        PlacedControl(id: "y", kind: .faceButton, center: CGPoint(x: 0.72, y: 0.315), size: 0.065,
                      printed: "Y", inputs: .button(2),
                      note: "Six-button pad only. Sends the Switch Y bit", callout: .below, variants: ["six-button"]),
        PlacedControl(id: "z", kind: .faceButton, center: CGPoint(x: 0.83, y: 0.245), size: 0.065,
                      printed: "Z", inputs: .button(4),
                      note: "Six-button pad only. Sends the Switch L bit", callout: .below, variants: ["six-button"]),

        // Underside: the player LEDs and SYNC. Exact spot unconfirmed.
        PlacedControl(id: "player-leds", kind: .light, face: .back, center: CGPoint(x: 0.46, y: 0.5), size: 0.07, height: 0.012,
                      shape: .capsule(angleDegrees: 0),
                      readable: .notReported("The player LEDs are set by a console; InputConfig neither reads nor sets them")),
        PlacedControl(id: "sync", kind: .other, face: .back, center: CGPoint(x: 0.56, y: 0.5), size: 0.025,
                      printed: "SYNC",
                      readable: .notReported("The pad handles SYNC itself for pairing; it never reaches the Mac")),
    ]

    /// Inputs the raw descriptor read declares that no control on this pad
    /// sends. Bits 2, 3 and 4 (X, Y, Z) are placed on the six-button pad.
    static let nsoGenesisOffBody: [OffBodyInput] = {
        let why = "Declared but not on this controller: the Switch report the pad shares has this "
        return [
            OffBodyInput(serialized: "btn 6", reason: why + "ZL bit (raw descriptor read)"),
            OffBodyInput(serialized: "btn 8", reason: why + "Minus bit (raw descriptor read)"),
            OffBodyInput(serialized: "btn 10", reason: why + "left stick click bit (raw descriptor read)"),
            OffBodyInput(serialized: "btn 11", reason: why + "right stick click bit (raw descriptor read)"),
            OffBodyInput(serialized: "btn 14", reason: why + "spare bit 15 (raw descriptor read; through GameController btn 14 is Capture)"),
            OffBodyInput(serialized: "btn 15", reason: why + "spare bit 16 (raw descriptor read)"),
            OffBodyInput(serialized: "axi 0 +", reason: why + "left stick X axis (raw descriptor read)"),
            OffBodyInput(serialized: "axi 1 +", reason: why + "left stick Y axis (raw descriptor read)"),
            OffBodyInput(serialized: "axi 2 +", reason: why + "right stick X axis (raw descriptor read)"),
            OffBodyInput(serialized: "axi 3 +", reason: why + "right stick Y axis (raw descriptor read)"),
        ]
    }()
}
