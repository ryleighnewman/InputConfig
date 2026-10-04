import Foundation
import CoreGraphics

extension ControllerLayout {
    /// 8BitDo Ultimate (2022): the 2.4G controller, the Bluetooth controller
    /// (both with a charging dock) and the Wired controller share one body,
    /// 147 by 104 mm. Placement is traced from 8BitDo's own manual drawings
    /// (Ultimate Bluetooth and Ultimate Wired): the left stick high and far
    /// out, the D-pad and right stick level with each other lower down, the
    /// face diamond high on the right. The center column runs Home (the
    /// 8BitDo heart, ringed by the status light), then minus, Star and plus
    /// in one row, then the Profile button with its three profile lights
    /// under it. Two paddles, P1 and P2, sit on the back.
    ///
    /// Printing: the 2.4G and Wired controllers print Xbox letters (Y top,
    /// B right, A bottom, X left); the Bluetooth controller prints Nintendo
    /// letters (X top, A right, B bottom, Y left). There is no separate
    /// Capture button on any of them: the Star button acts as Capture in
    /// Switch mode. The face buttons carry no printed letter here, so the
    /// Face button names setting picks the letters for the model in hand.
    ///
    /// Inputs. Every path numbers the face buttons by position (btn 0 the
    /// bottom button, 1 right, 2 left, 3 top):
    /// - GameController (the 2.4G controller over Bluetooth in the mode
    ///   8BitDo lists for Apple devices): the typed extendedGamepad read,
    ///   btn 0 to 12, axes 0 to 5, hat 0, and the back buttons on 16 and 17
    ///   when the pad lists them (knownButtonMap reads Back Left and Right
    ///   Button 0 there). Star and Profile are not sent.
    /// - Raw HID through the bundled SDL rows for 2DC8:3011, 3012 and 3013
    ///   (D-input mode): paddle1 (P1) on btn 17 and paddle2 (P2) on btn 16
    ///   (SDLGameControllerDB.buttonSlots), misc1 on btn 14 on the 3011 and
    ///   3013 rows, triggers on axes 4 and 5 with digital copies 6 and 7.
    ///   Report bits a row does not name land on btn 22 and up (offBody).
    /// - X-input mode is an XUSB device that macOS does not read.
    /// In Switch mode the Bluetooth controller is a Switch Pro Controller to
    /// the Mac and is drawn as one.
    static let eightBitDoUltimate = ControllerLayout(
        id: .eightBitDoUltimate,
        displayName: "8BitDo Ultimate",
        maker: .eightBitDo,
        family: nil,
        // No touchpad, mute, second paddle pair or Fn buttons.
        modelNames: ButtonNames.ModelNames(renamed: [14: "Star", 16: "P2", 17: "P1"],
                                           short: [14: "Star", 16: "P2", 17: "P1"],
                                           absent: [13, 15, 18, 19, 20, 21]),
        aspect: 147.0 / 104.0,
        topStrip: 0.2,
        // The back is drawn at 0.76 of the width; this keeps its outline in
        // proportion with the front.
        backStrip: 0.535,
        silhouette: Silhouette(front: eightBitDoUltimateFront,
                               top: Silhouette.roundedRectOps(corner: 0.2, inset: 0.04),
                               back: eightBitDoUltimateFront),
        controls: eightBitDoUltimateControls,
        variants: [
            LayoutVariant(id: "24g", displayName: "Ultimate 2.4G (X and D mode switch, Xbox letters)", isDefault: true),
            LayoutVariant(id: "bluetooth", displayName: "Ultimate Bluetooth (Bluetooth and 2.4G switch, Nintendo letters)"),
            LayoutVariant(id: "wired", displayName: "Ultimate Wired (Xbox letters, no dock)"),
        ],
        offBody: [
            OffBodyInput(serialized: "btn 22", reason: "Raw HID extra slot: an unnamed report bit. On the 3011 and 3013 rows an unused face bit, on the 3012 row the left trigger's digital bit, which fires with LT", copy: true),
            OffBodyInput(serialized: "btn 23", reason: "Raw HID extra slot: an unnamed report bit. On the 3011 and 3013 rows an unused face bit, on the 3012 row the right trigger's digital bit, which fires with RT", copy: true),
            OffBodyInput(serialized: "btn 24", reason: "Raw HID extra slot on the 3011 and 3013 rows: the left trigger's digital bit, which fires with LT", copy: true),
            OffBodyInput(serialized: "btn 25", reason: "Raw HID extra slot on the 3011 and 3013 rows: the right trigger's digital bit, which fires with RT", copy: true),
        ],
        // Read raw, by the D-input USB IDs the bundled SDL rows cover (the
        // Ultimate 2C, 301B and 301D, has its own layout). Listed by
        // GameController, by the name 8BitDo gives it; the 2C, Ultimate 2
        // and Ultimate C names do not contain these phrases.
        match: [
            [.vidPid(vendor: 0x2DC8, products: [0x3011, 0x3012, 0x3013])],
            // Wired in X-input mode, read by the XInput report decoder.
            [.vidPid(vendor: 0x2DC8, products: [0x3106])],
            [.gcVendorNameContains("8BitDo Ultimate Wireless")],
            [.gcVendorNameContains("8BitDo Ultimate Wired")],
            [.gcVendorNameContains("8BitDo Ultimate 2.4G")],
            [.gcVendorNameContains("8BitDo Ultimate Bluetooth")],
        ],
        matchPriority: 20,
        readability: .partial("P1 and P2 reach the Mac in D-input mode through the raw HID read, and through GameController when it lists them; Star only in D-input mode. The Profile button, mode switch and lights never do. X-input mode is read on a USB cable, not through the 2.4G receiver"),
        approximate: true,
        sources: [
            "8bitdo.com Ultimate Bluetooth and Ultimate 2.4G product pages (147.0 x 104.0 x 61.5 mm, two back buttons, profile switch with 3 profiles, 2-way mode switch)",
            "download.8bitdo.com Manual/Controller/Ultimate/Ultimate-Bluetooth-Controller.pdf (front, top and back drawings: home, star, minus, plus, profile, profile LED, status LED, power LED, pair, mode switch, charging contacts, P1, P2)",
            "download.8bitdo.com Manual/Controller/Ultimate/Ultimate-Wired-Controller.pdf (same front with Y B A X printing, view and menu, P1 and P2, no switch)",
            "8BitDo Ultimate 2.4G manual parts list (home, star, view, profile, menu, mode switch X and D, charging contacts, power, status and profile LEDs)",
            "SDL gamecontrollerdb rows 03000000c82d00001130, 1230 and 1330 (Mac OS X)",
        ]
    )

    /// The front outline: a broad, nearly flat top with the bumpers riding
    /// the corners, round shoulders, sides that bulge slightly to their
    /// widest just above the grips, short grips that splay outward to
    /// rounded tips, and a wide flat arch between them.
    static let eightBitDoUltimateFront: [PathOp] = Silhouette.symmetric([
        .move(0.5, 0.02),
        .curve(0.13, 0.05, c1x: 0.36, c1y: 0.02, c2x: 0.2, c2y: 0.025),
        .curve(0.03, 0.27, c1x: 0.075, c1y: 0.08, c2x: 0.045, c2y: 0.17),
        .curve(0.002, 0.72, c1x: 0.012, c1y: 0.4, c2x: 0.0, c2y: 0.58),
        .curve(0.125, 0.995, c1x: 0.005, c1y: 0.86, c2x: 0.06, c2y: 0.985),
        .curve(0.145, 0.98, c1x: 0.133, c1y: 1.0, c2x: 0.14, c2y: 0.992),
        .line(0.24, 0.735),
        .curve(0.3, 0.69, c1x: 0.255, c1y: 0.705, c2x: 0.27, c2y: 0.69),
        .line(0.5, 0.69),
    ])

    static let eightBitDoUltimateControls: [PlacedControl] = [
        // Top: analog triggers at the rear corners, bumpers along the front
        // lip, and on the dock models the USB-C port with the pair button on
        // the player's left of it and the power light on the right.
        PlacedControl(id: "lt", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.2, y: 0.175), size: 0.15, height: 0.13,
                      shape: .roundedRect(corner: 0.35), inputs: .trigger(axis: 4, digital: 6), callout: .above),
        PlacedControl(id: "rt", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.8, y: 0.175), size: 0.15, height: 0.13,
                      shape: .roundedRect(corner: 0.35), inputs: .trigger(axis: 5, digital: 7), callout: .above),
        PlacedControl(id: "lb", kind: .shoulder, face: .top, center: CGPoint(x: 0.2, y: 0.76), size: 0.15, height: 0.045,
                      shape: .capsule(angleDegrees: 0), inputs: .button(4), callout: .below),
        PlacedControl(id: "rb", kind: .shoulder, face: .top, center: CGPoint(x: 0.8, y: 0.76), size: 0.15, height: 0.045,
                      shape: .capsule(angleDegrees: 0), inputs: .button(5), callout: .below),
        PlacedControl(id: "pair", kind: .other, face: .top, center: CGPoint(x: 0.44, y: 0.5), size: 0.022, height: 0.012,
                      shape: .capsule(angleDegrees: 0),
                      readable: .notReported("The pair button is handled by the controller's radio and is not sent to the Mac"),
                      variants: ["bluetooth"]),
        PlacedControl(id: "usbc", kind: .port, face: .top, center: CGPoint(x: 0.5, y: 0.5), size: 0.06, height: 0.016,
                      shape: .roundedRect(corner: 0.5), note: "USB-C. The Wired controller has its fixed cable here"),
        PlacedControl(id: "powerLight", kind: .light, face: .top, center: CGPoint(x: 0.56, y: 0.5), size: 0.012,
                      readable: .notReported("The power light shows charge and power; the Mac cannot read or set it"),
                      variants: ["24g", "bluetooth"]),

        // Front, left: the stick high and far out, the D-pad lower and inboard.
        PlacedControl(id: "lstick", kind: .stick, center: CGPoint(x: 0.21, y: 0.276), size: 0.108,
                      inputs: .stick(x: 0, y: 1, press: 11), note: "Hall effect stick", callout: .below),
        PlacedControl(id: "dpad", kind: .dpad, center: CGPoint(x: 0.359, y: 0.506), size: 0.155, shape: .crossPad,
                      inputs: .hat(0), callout: .below),

        // Front, right: the face diamond high, the right stick lower and
        // inboard, level with the D-pad. Positional numbering (see the top).
        PlacedControl(id: "top", kind: .faceButton, center: CGPoint(x: 0.783, y: 0.176), size: 0.066,
                      inputs: .button(3), note: "Top button: Y on the 2.4G and Wired, X on the Bluetooth controller", callout: .above),
        PlacedControl(id: "left", kind: .faceButton, center: CGPoint(x: 0.712, y: 0.278), size: 0.066,
                      inputs: .button(2), note: "Left button: X on the 2.4G and Wired, Y on the Bluetooth controller", callout: .left),
        PlacedControl(id: "right", kind: .faceButton, center: CGPoint(x: 0.854, y: 0.278), size: 0.066,
                      inputs: .button(1), note: "Right button: B on the 2.4G and Wired, A on the Bluetooth controller", callout: .right),
        PlacedControl(id: "bottom", kind: .faceButton, center: CGPoint(x: 0.783, y: 0.381), size: 0.066,
                      inputs: .button(0), note: "Bottom button: A on the 2.4G and Wired, B on the Bluetooth controller", callout: .below),
        PlacedControl(id: "rstick", kind: .stick, center: CGPoint(x: 0.633, y: 0.506), size: 0.108,
                      inputs: .stick(x: 2, y: 3, press: 12), note: "Hall effect stick", callout: .below),

        // Front, center column: Home, then minus, Star and plus in a row,
        // then the Profile button and its three profile lights.
        PlacedControl(id: "home", kind: .homeButton, center: CGPoint(x: 0.5, y: 0.151), size: 0.066,
                      symbol: "heart", inputs: .button(10),
                      note: "The 8BitDo heart. The status light rings it", callout: .above),
        PlacedControl(id: "minus", kind: .menuButton, center: CGPoint(x: 0.424, y: 0.278), size: 0.05,
                      symbol: "minus", inputs: .button(8),
                      note: "View on the 2.4G and Wired, Select on the Bluetooth controller", callout: .above),
        PlacedControl(id: "star", kind: .menuButton, center: CGPoint(x: 0.5, y: 0.278), size: 0.05,
                      symbol: "star", inputs: .button(14),
                      pathInputs: [.gameController: .none, .rawProfile: .none],
                      readable: .conditional("Read only in D-input mode, where the SDL row's misc1 puts it on btn 14 (on the 3011 and 3013 receivers; which center button misc1 is was not confirmed on hardware). In the other modes the controller keeps it for turbo, or uses it as Capture in Switch mode"),
                      note: "Turbo: hold a button and press Star", callout: .below),
        PlacedControl(id: "plus", kind: .menuButton, center: CGPoint(x: 0.576, y: 0.278), size: 0.05,
                      symbol: "plus", inputs: .button(9),
                      note: "Menu on the 2.4G and Wired, Start on the Bluetooth controller", callout: .above),
        PlacedControl(id: "profile", kind: .menuButton, center: CGPoint(x: 0.5, y: 0.384), size: 0.055, height: 0.032,
                      shape: .capsule(angleDegrees: 0),
                      readable: .notReported("The Profile button switches the controller's three onboard profiles and is not sent to the Mac"),
                      note: "Switches between the default and three custom profiles"),
        PlacedControl(id: "profileLights", kind: .light, center: CGPoint(x: 0.5, y: 0.506), size: 0.014, height: 0.05,
                      shape: .capsule(angleDegrees: 0),
                      readable: .notReported("The three profile lights show the onboard profile; the Mac cannot read or set them"),
                      note: "No light lit is the default profile"),

        // Back, as held (player's left on the left): P2 behind the left
        // grip, P1 behind the right one, the mode switch between them with
        // the dock's charging contacts under it, and the player lights on
        // the edge between the grips.
        PlacedControl(id: "p2", kind: .paddle, face: .back, center: CGPoint(x: 0.26, y: 0.495), size: 0.073, height: 0.11,
                      shape: .roundedRect(corner: 0.45), printed: "P2", inputs: .button(16),
                      pathInputs: [.rawProfile: .none],
                      readable: .conditional("Btn 16: in D-input mode as SDL paddle2, and through GameController when it lists the pad's back buttons. Not sent in X-input mode"),
                      note: "Left back button. In a custom profile it can copy another button", callout: .below),
        PlacedControl(id: "p1", kind: .paddle, face: .back, center: CGPoint(x: 0.74, y: 0.495), size: 0.073, height: 0.11,
                      shape: .roundedRect(corner: 0.45), printed: "P1", inputs: .button(17),
                      pathInputs: [.rawProfile: .none],
                      readable: .conditional("Btn 17: in D-input mode as SDL paddle1, and through GameController when it lists the pad's back buttons. Not sent in X-input mode"),
                      note: "Right back button. In a custom profile it can copy another button", callout: .below),
        PlacedControl(id: "modeSwitch", kind: .other, face: .back, center: CGPoint(x: 0.5, y: 0.431), size: 0.04, height: 0.018,
                      shape: .capsule(angleDegrees: 0),
                      readable: .notReported("The mode switch changes how the controller identifies itself; the switch itself is not sent"),
                      note: "X and D on the 2.4G controller, Bluetooth and 2.4G on the Bluetooth controller",
                      variants: ["24g", "bluetooth"]),
        PlacedControl(id: "chargingContacts", kind: .port, face: .back, center: CGPoint(x: 0.5, y: 0.507), size: 0.05, height: 0.012,
                      shape: .roundedRect(corner: 0.5), note: "Charging contacts for the dock",
                      variants: ["24g", "bluetooth"]),
        PlacedControl(id: "playerLights", kind: .light, face: .back, center: CGPoint(x: 0.5, y: 0.665), size: 0.04, height: 0.008,
                      shape: .capsule(angleDegrees: 0),
                      readable: .notReported("The four player lights face you from the edge between the grips; the Mac cannot read or set them"),
                      variants: ["bluetooth"]),
    ]
}
