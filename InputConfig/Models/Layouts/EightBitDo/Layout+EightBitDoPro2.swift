import Foundation
import CoreGraphics

extension ControllerLayout {
    /// 8BitDo Pro 2 (and the SN30 Pro+ it grew out of), in D mode, the mode
    /// 8BitDo's manual gives for Apple devices. Read through GameController
    /// as an extendedGamepad, or raw through the bundled SDL rows (2DC8:6006
    /// "8BitDo Pro 2", 2DC8:6002 and 6102 "8BitDo SN30 Pro Plus") when
    /// GameController does not list the pad.
    ///
    /// Positions are measured from the front and rear diagrams in 8BitDo's
    /// Pro 2 instruction manual (the outline is 1032 by 673 units there, so
    /// aspect 1.53). The rear diagram is drawn from behind, so it is mirrored
    /// here to read as held: P2 sits on the left grip, P1 on the right. The
    /// SN30 Pro+ variant uses the same shell and front arrangement without
    /// the Profile button, its LEDs, the back buttons and the mode switch;
    /// its positions are taken from the Pro 2, not measured.
    ///
    /// Face buttons are printed Nintendo style in one color: X top, Y left,
    /// A right, B bottom. They use the POSITIONAL numbering (btn 0 the bottom
    /// button B, 1 the right A, 2 the left Y, 3 the top X). The SDL rows
    /// number them by position (a:b1 is the bottom button). GameController
    /// is read as buttonA 0 to buttonY 3 with no 8BitDo swap
    /// (GameControllerService.faceButtonsByPosition swaps only Switch pads),
    /// and SDL's own GameController backend treats an 8BitDo's buttonA as
    /// the bottom button too, but whether Apple names this pad's buttons by
    /// position or by the printed letter is not confirmed on hardware.
    static let eightBitDoPro2 = ControllerLayout(
        id: .eightBitDoPro2,
        displayName: "8BitDo Pro 2 / SN30 Pro+",
        maker: .eightBitDo,
        family: nil,
        modelNames: ButtonNames.ModelNames(
            renamed: [4: "L", 5: "R", 6: "L2", 7: "R2", 8: "Select", 9: "Start", 10: "Home",
                      11: "L3", 12: "R3", 16: "P2", 17: "P1"],
            short: [4: "L", 5: "R", 6: "L2", 7: "R2", 8: "Select", 9: "Start", 10: "Home",
                    11: "L3", 12: "R3", 16: "P2", 17: "P1"],
            absent: [13, 14, 15, 18, 19, 20, 21]
        ),
        aspect: 1032.0 / 673.0,
        topStrip: 0.2,
        // The rear is drawn a little shorter than true (0.65) so the back
        // strip stays compact; the outline is the same symmetric shell.
        backStrip: 0.5,
        silhouette: Silhouette(front: eightBitDoPro2Front,
                               top: Silhouette.roundedRectOps(corner: 0.2, inset: 0.04),
                               back: eightBitDoPro2Front),
        controls: eightBitDoPro2Controls,
        variants: [
            LayoutVariant(id: "pro2", displayName: "Pro 2", isDefault: true),
            LayoutVariant(id: "sn30proplus", displayName: "SN30 Pro+"),
        ],
        // GameController names the pad "8BitDo Pro 2" or "8BitDo SN30 Pro+".
        // "8BitDo Pro 2" is spelled out so the N30 Pro 2 ("8BitDo N30 Pro 2")
        // does not match, and "SN30 Pro+" or "SN30 Pro Plus" so the original
        // SN30 Pro does not. A Pro 2 whose name says neither is still known
        // by its back buttons; the Ultimate's Bluetooth model, which also has
        // back buttons, reports a Share button the Pro 2 lacks. Read raw, the
        // pad is matched by the product IDs SDL gives these models.
        offBody: [
            OffBodyInput(serialized: "btn 22", reason: "Read raw: on the Pro 2 the left trigger's digital bit (b8), which its row leaves out, so it fires with L2; on the SN30 Pro+ an unused bit", copy: true),
            OffBodyInput(serialized: "btn 23", reason: "Read raw: on the Pro 2 the right trigger's digital bit (b9), which its row leaves out, so it fires with R2; on the SN30 Pro+ an unused bit", copy: true),
        ],
        match: [
            [.brand(.eightBitDo), .gcVendorNameContains("8BitDo Pro 2")],
            [.brand(.eightBitDo), .gcProductCategoryContains("8BitDo Pro 2")],
            [.brand(.eightBitDo), .gcHasElement("Back Left Button 0"), .gcLacksElement("Button Share")],
            [.brand(.eightBitDo), .gcVendorNameContains("SN30 Pro+")],
            [.brand(.eightBitDo), .gcVendorNameContains("SN30 Pro Plus")],
            [.brand(.eightBitDo), .gcProductCategoryContains("SN30 Pro+")],
            [.vidPid(vendor: 0x2DC8, products: [0x6003, 0x6006])],
            [.vidPid(vendor: 0x2DC8, products: [0x6002, 0x6102])],
        ],
        matchPriority: 20,
        approximate: true,
        sources: [
            "8BitDo Pro 2 Bluetooth gamepad instruction manual (download.8bitdo.com/Manual/Controller/Pro2/Pro2_Manual.pdf): front and rear part diagrams, D mode for Apple devices, turbo on Star",
            "8BitDo Pro 2 product page and FAQ (8bitdo.com/pro2, support.8bitdo.com/faq/pro2.html)",
            "goughlui.com Pro 2 review: Pair button left and charge LED right of the top USB-C port",
            "SDL gamecontrollerdb.txt macOS rows for 8BitDo Pro 2 and SN30 Pro Plus; SDL src/joystick/usb_ids.h and SDL_hidapi_8bitdo.c (Pro 2 product IDs 6003 and 6006)",
            "SDL src/joystick/apple/SDL_mfijoystick.m (an 8BitDo's GameController buttonA read as the bottom button)",
        ],
        // Pro 2 wired and Bluetooth (SDL usb_ids.h), SN30 Pro+ wired and Bluetooth.
        productVariants: [0x2DC8 << 16 | 0x6003: "pro2", 0x2DC8 << 16 | 0x6006: "pro2",
                          0x2DC8 << 16 | 0x6002: "sn30proplus", 0x2DC8 << 16 | 0x6102: "sn30proplus"]
    )

    /// The front outline, traced from 8BitDo's diagram: a broad SNES style
    /// upper body with the L and R bumpers standing up at the top corners,
    /// long grips that hang almost straight down, and the two stick housings
    /// bulging into the arch between the grips.
    static let eightBitDoPro2Front: [PathOp] = Silhouette.symmetric([
        .move(0.5, 0.018),
        .line(0.331, 0.018),
        // The L bumper standing proud of the top edge.
        .line(0.331, 0.004),
        .line(0.215, 0.003),
        .quad(0.128, 0.032, cx: 0.16, cy: 0.003),
        // Outer side, then down the grip.
        .curve(0.044, 0.227, c1x: 0.09, c1y: 0.06, c2x: 0.06, c2y: 0.15),
        .curve(0.004, 0.70, c1x: 0.028, c1y: 0.32, c2x: 0.008, c2y: 0.55),
        .curve(0.107, 0.998, c1x: 0.0, c1y: 0.86, c2x: 0.04, c2y: 0.998),
        // Grip tip, then the inner edge up to the stick housing.
        .curve(0.2, 0.86, c1x: 0.16, c1y: 0.998, c2x: 0.19, c2y: 0.92),
        .curve(0.31, 0.614, c1x: 0.215, c1y: 0.76, c2x: 0.255, c2y: 0.65),
        .quad(0.358, 0.632, cx: 0.33, cy: 0.632),
        .quad(0.438, 0.565, cx: 0.425, cy: 0.632),
        .line(0.5, 0.563),
    ])

    static let eightBitDoPro2Controls: [PlacedControl] = [
        // Top: L2 and R2 behind the L and R bumpers, the Pair button, the
        // USB-C port and the power LED along the middle.
        PlacedControl(id: "l2", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.22, y: 0.195), size: 0.15, height: 0.13,
                      shape: .roundedRect(corner: 0.35), printed: "L2", inputs: .trigger(axis: 4, digital: 6),
                      note: "Analog. The Pro 2's SDL row reads it on axis 4 too; the SN30 Pro+ row makes it a plain button, btn 6 only",
                      callout: .above),
        PlacedControl(id: "r2", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.78, y: 0.195), size: 0.15, height: 0.13,
                      shape: .roundedRect(corner: 0.35), printed: "R2", inputs: .trigger(axis: 5, digital: 7),
                      note: "Analog. The Pro 2's SDL row reads it on axis 5 too; the SN30 Pro+ row makes it a plain button, btn 7 only",
                      callout: .above),
        PlacedControl(id: "l", kind: .shoulder, face: .top, center: CGPoint(x: 0.23, y: 0.76), size: 0.2, height: 0.045,
                      shape: .capsule(angleDegrees: 0), printed: "L", inputs: .button(4), callout: .below),
        PlacedControl(id: "r", kind: .shoulder, face: .top, center: CGPoint(x: 0.77, y: 0.76), size: 0.2, height: 0.045,
                      shape: .capsule(angleDegrees: 0), printed: "R", inputs: .button(5), callout: .below),
        PlacedControl(id: "pair", kind: .other, face: .top, center: CGPoint(x: 0.426, y: 0.55), size: 0.03, height: 0.02,
                      shape: .roundedRect(corner: 0.4), printed: "PAIR",
                      readable: .notReported("Pair puts the controller in Bluetooth pairing mode; it never reaches the Mac")),
        PlacedControl(id: "usb-c", kind: .port, face: .top, center: CGPoint(x: 0.5, y: 0.55), size: 0.055, height: 0.022,
                      shape: .roundedRect(corner: 0.45), note: "USB-C for charging and wired play"),
        PlacedControl(id: "power-led", kind: .light, face: .top, center: CGPoint(x: 0.564, y: 0.55), size: 0.015,
                      readable: .notReported("The power and charge LED is driven by the controller; InputConfig neither reads nor sets it")),

        // Front, left: the cross D-pad high, Star below it outboard of the
        // left stick.
        PlacedControl(id: "dpad", kind: .dpad, center: CGPoint(x: 0.225, y: 0.257), size: 0.155, shape: .crossPad,
                      inputs: .hat(0), callout: .below),
        PlacedControl(id: "star", kind: .menuButton, center: CGPoint(x: 0.225, y: 0.506), size: 0.044,
                      symbol: "star",
                      readable: .notReported("Star sets turbo on the controller itself (and is Capture in Switch mode); it is not sent to the Mac"),
                      callout: .below),

        // Front, center: Select (minus) and Start (plus) side by side in
        // their raised surround, the sticks below and inboard.
        PlacedControl(id: "select", kind: .menuButton, center: CGPoint(x: 0.453, y: 0.25), size: 0.073, height: 0.024,
                      shape: .capsule(angleDegrees: 0), symbol: "minus", inputs: .button(8), callout: .above),
        PlacedControl(id: "start", kind: .menuButton, center: CGPoint(x: 0.545, y: 0.25), size: 0.073, height: 0.024,
                      shape: .capsule(angleDegrees: 0), symbol: "plus", inputs: .button(9),
                      note: "Also the power button: press to turn on, hold three seconds to turn off", callout: .above),
        PlacedControl(id: "lstick", kind: .stick, center: CGPoint(x: 0.358, y: 0.476), size: 0.125,
                      inputs: .stick(x: 0, y: 1, press: 11), callout: .below),
        PlacedControl(id: "rstick", kind: .stick, center: CGPoint(x: 0.642, y: 0.476), size: 0.125,
                      inputs: .stick(x: 2, y: 3, press: 12), callout: .below),

        // Pro 2 only: the three profile LEDs and the Profile button between
        // the sticks.
        PlacedControl(id: "profile-leds", kind: .light, center: CGPoint(x: 0.499, y: 0.418), size: 0.044, height: 0.012,
                      shape: .capsule(angleDegrees: 0),
                      readable: .notReported("The profile LEDs show the controller's own profile; InputConfig neither reads nor sets them"),
                      variants: ["pro2"]),
        PlacedControl(id: "profile", kind: .menuButton, center: CGPoint(x: 0.499, y: 0.478), size: 0.044, height: 0.024,
                      shape: .capsule(angleDegrees: 0),
                      readable: .notReported("Profile switches the controller's own button profiles made in 8BitDo's Ultimate Software; it is not sent to the Mac"),
                      callout: .below, variants: ["pro2"]),

        // Front, right: the X/Y/A/B diamond, printed in one color.
        // Positional numbering (see the note at the top).
        PlacedControl(id: "x", kind: .faceButton, center: CGPoint(x: 0.772, y: 0.153), size: 0.068, printed: "X",
                      inputs: .button(3),
                      readable: .conditional("Top button, btn 3 by position. A raw SDL read is btn 3; on GameController it is btn 3 if Apple numbers this pad by position, btn 2 if by the printed letter (not yet confirmed)"),
                      callout: .above),
        PlacedControl(id: "y", kind: .faceButton, center: CGPoint(x: 0.695, y: 0.257), size: 0.068, printed: "Y",
                      inputs: .button(2),
                      readable: .conditional("Left button, btn 2 by position. A raw SDL read is btn 2; on GameController it is btn 2 if Apple numbers this pad by position, btn 3 if by the printed letter (not yet confirmed)"),
                      callout: .left),
        PlacedControl(id: "a", kind: .faceButton, center: CGPoint(x: 0.85, y: 0.257), size: 0.068, printed: "A",
                      inputs: .button(1),
                      readable: .conditional("Right button, btn 1 by position. A raw SDL read is btn 1; on GameController it is btn 1 if Apple numbers this pad by position, btn 0 if by the printed letter (not yet confirmed)"),
                      callout: .right),
        PlacedControl(id: "b", kind: .faceButton, center: CGPoint(x: 0.772, y: 0.361), size: 0.068, printed: "B",
                      inputs: .button(0),
                      readable: .conditional("Bottom button, btn 0 by position. A raw SDL read is btn 0; on GameController it is btn 0 if Apple numbers this pad by position, btn 1 if by the printed letter (not yet confirmed)"),
                      callout: .below),
        PlacedControl(id: "home", kind: .homeButton, center: CGPoint(x: 0.773, y: 0.505), size: 0.048,
                      symbol: "house", inputs: .button(10),
                      note: "The 8BitDo logo button; its ring LED blinks while a turbo button is held",
                      callout: .below),

        // Back, as held (8BitDo's rear diagram mirrored): P2 on the left
        // grip, P1 on the right, the S/A/D/X mode switch between them and
        // the status LED in the tab below. Pro 2 only.
        PlacedControl(id: "p2", kind: .paddle, face: .back, center: CGPoint(x: 0.259, y: 0.498), size: 0.07, height: 0.12,
                      shape: .capsule(angleDegrees: 20), printed: "P2", inputs: .button(16),
                      readable: .conditional("Btn 16 on both paths: GameController's Back Left Button 0, or read raw the report's PL bit (b5), where SDL's 8BitDo driver reads it"),
                      note: "If 8BitDo's Ultimate Software assigns it another button, the Mac receives that button instead",
                      callout: .below, variants: ["pro2"]),
        PlacedControl(id: "p1", kind: .paddle, face: .back, center: CGPoint(x: 0.741, y: 0.498), size: 0.07, height: 0.12,
                      shape: .capsule(angleDegrees: -20), printed: "P1", inputs: .button(17),
                      readable: .conditional("Btn 17 on both paths: GameController's Back Right Button 0, or read raw the report's PR bit (b2), where SDL's 8BitDo driver reads it"),
                      note: "If 8BitDo's Ultimate Software assigns it another button, the Mac receives that button instead",
                      callout: .below, variants: ["pro2"]),
        PlacedControl(id: "mode-switch", kind: .slider, face: .back, center: CGPoint(x: 0.5, y: 0.473), size: 0.065, height: 0.022,
                      shape: .capsule(angleDegrees: 0), printed: "SADX",
                      readable: .notReported("The S/A/D/X switch picks how the controller presents itself; it sends nothing. D is the mode for a Mac"),
                      variants: ["pro2"]),
        PlacedControl(id: "status-led", kind: .light, face: .back, center: CGPoint(x: 0.5, y: 0.548), size: 0.03, height: 0.01,
                      shape: .capsule(angleDegrees: 0),
                      readable: .notReported("The status LED shows the connection and mode; InputConfig neither reads nor sets it"),
                      variants: ["pro2"]),
    ]
}
