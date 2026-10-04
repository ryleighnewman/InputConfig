import Foundation
import CoreGraphics

extension ControllerLayout {
    /// Nintendo Switch Pro Controller (HAC-013, 057E:2009), 152 mm wide and
    /// 106 mm tall, read through GameController as an extendedGamepad. The
    /// raw HID service waits for and defers to a GameController listing, so
    /// the SDL row is only the fallback read.
    ///
    /// Face buttons use the POSITIONAL numbering: btn 0 the bottom button
    /// (B), 1 the right (A), 2 the left (Y), 3 the top (X).
    /// GameController names a Switch pad's buttons by their printed letter,
    /// and GameControllerService.faceButtonsByPosition swaps them into place
    /// for the .switchPro brand. The SDL rows number them by position too.
    static let switchPro = ControllerLayout(
        id: .switchPro,
        displayName: "Switch Pro Controller",
        maker: .nintendo,
        family: .nintendo,
        // No C, GL or GR (the Switch 2 Pro has those), no touchpad or mute.
        modelNames: ButtonNames.ModelNames(absent: [13, 15, 16, 17, 18, 19, 20, 21]),
        aspect: 152.0 / 106.0,
        topStrip: 0.2,
        backStrip: 0,
        silhouette: Silhouette(front: switchProFront,
                               top: Silhouette.roundedRectOps(corner: 0.2, inset: 0.04)),
        controls: switchProControls,
        offBody: [
            OffBodyInput(serialized: "mtn gyroX +", reason: "Gyroscope inside the body, read once GameController motion is switched on"),
            OffBodyInput(serialized: "mtn gyroY +", reason: "Gyroscope inside the body, read once GameController motion is switched on"),
            OffBodyInput(serialized: "mtn gyroZ +", reason: "Gyroscope inside the body, read once GameController motion is switched on"),
            OffBodyInput(serialized: "mtn accelX +", reason: "Accelerometer inside the body, read through GameController"),
            OffBodyInput(serialized: "mtn accelY +", reason: "Accelerometer inside the body, read through GameController"),
            OffBodyInput(serialized: "mtn accelZ +", reason: "Accelerometer inside the body, read through GameController"),
            OffBodyInput(serialized: "mtn rollAngle +", reason: "Tilt angle the app integrates from the gyroscope"),
            OffBodyInput(serialized: "mtn pitchAngle +", reason: "Tilt angle the app integrates from the gyroscope"),
            OffBodyInput(serialized: "mtn yawAngle +", reason: "Turn angle the app integrates from the gyroscope"),
        ],
        // GameController calls it "Switch Pro Controller"; a Switch 2 Pro
        // Controller ("Switch 2 Pro Controller") does not contain that text.
        // Read raw, it is matched by its USB IDs; the brand alone is not
        // used because every Nintendo pad read raw (the Switch 2 Pro, the
        // Switch Online pads) also gets the .switchPro brand.
        match: [
            [.gcProductCategoryContains("Switch Pro")],
            [.vidPid(vendor: 0x057E, products: [0x2009])],
        ],
        matchPriority: 10,
        approximate: true,
        sources: [
            "nintendo.com Pro Controller parts page (front: Capture, HOME, sticks, A/B/X/Y, Control Pad, -, +, NFC; top: L, R, ZL, ZR, USB-C, SYNC, player and recharge LEDs; 106 x 152 x 60 mm)",
            "SDL src/joystick/hidapi/SDL_hidapi_switch.c and gamecontrollerdb.txt (positional face buttons)",
            "Product photos of the HAC-013 for placement",
        ]
    )

    /// The front outline: a broad flat top with rounded shoulders, sides
    /// that run almost straight down into long, round-ended grips, and a
    /// shallow arch between the grips under the D-pad and right stick.
    static let switchProFront: [PathOp] = Silhouette.symmetric([
        .move(0.5, 0.03),
        .curve(0.17, 0.022, c1x: 0.36, c1y: 0.026, c2x: 0.23, c2y: 0.018),
        .curve(0.022, 0.2, c1x: 0.08, c1y: 0.03, c2x: 0.03, c2y: 0.1),
        .curve(0.04, 0.74, c1x: 0.012, c1y: 0.38, c2x: 0.018, c2y: 0.6),
        .curve(0.165, 0.99, c1x: 0.06, c1y: 0.9, c2x: 0.1, c2y: 0.99),
        .curve(0.29, 0.92, c1x: 0.23, c1y: 0.99, c2x: 0.275, c2y: 0.965),
        .curve(0.385, 0.765, c1x: 0.305, c1y: 0.86, c2x: 0.335, c2y: 0.785),
        .curve(0.5, 0.735, c1x: 0.425, c1y: 0.75, c2x: 0.465, c2y: 0.735),
    ])

    static let switchProControls: [PlacedControl] = [
        // Top: L and R are long bumpers along the front lip, ZL and ZR the
        // larger digital triggers behind them. ZL and ZR read 0 or 1 on axis
        // 4 and 5 and press btn 6 and 7 (GameControllerService reads the
        // trigger value into both).
        PlacedControl(id: "zl", kind: .trigger(.digital), face: .top, center: CGPoint(x: 0.19, y: 0.1825), size: 0.15, height: 0.13,
                      shape: .roundedRect(corner: 0.35), inputs: .trigger(axis: 4, digital: 6),
                      pathInputs: [.rawSDL: .button(6)],
                      note: "Digital: reads all or nothing. A raw SDL read gives btn 6 only on a USB row", callout: .above),
        PlacedControl(id: "zr", kind: .trigger(.digital), face: .top, center: CGPoint(x: 0.81, y: 0.1825), size: 0.15, height: 0.13,
                      shape: .roundedRect(corner: 0.35), inputs: .trigger(axis: 5, digital: 7),
                      pathInputs: [.rawSDL: .button(7)],
                      note: "Digital: reads all or nothing. A raw SDL read gives btn 7 only on a USB row", callout: .above),
        PlacedControl(id: "l", kind: .shoulder, face: .top, center: CGPoint(x: 0.21, y: 0.76), size: 0.18, height: 0.045,
                      shape: .capsule(angleDegrees: 0), inputs: .button(4), callout: .below),
        PlacedControl(id: "r", kind: .shoulder, face: .top, center: CGPoint(x: 0.79, y: 0.76), size: 0.18, height: 0.045,
                      shape: .capsule(angleDegrees: 0), inputs: .button(5), callout: .below),
        // Top center: player LEDs, the USB-C port, and SYNC beside it.
        PlacedControl(id: "player-leds", kind: .light, face: .top, center: CGPoint(x: 0.42, y: 0.45), size: 0.07, height: 0.012,
                      shape: .capsule(angleDegrees: 0),
                      readable: .notReported("The player LEDs are not a GameController light, so InputConfig neither reads nor sets them")),
        PlacedControl(id: "usb-c", kind: .port, face: .top, center: CGPoint(x: 0.5, y: 0.45), size: 0.05, height: 0.02,
                      shape: .roundedRect(corner: 0.45), note: "USB-C for charging and wired play"),
        PlacedControl(id: "sync", kind: .other, face: .top, center: CGPoint(x: 0.565, y: 0.45), size: 0.025,
                      printed: "SYNC",
                      readable: .notReported("The controller handles SYNC itself for pairing; it never reaches the Mac")),

        // Front, left: the stick high, the Control Pad below and inboard.
        PlacedControl(id: "lstick", kind: .stick, center: CGPoint(x: 0.255, y: 0.33), size: 0.13,
                      inputs: .stick(x: 0, y: 1, press: 11), callout: .below),
        PlacedControl(id: "dpad", kind: .dpad, center: CGPoint(x: 0.37, y: 0.565), size: 0.14, shape: .crossPad,
                      inputs: .hat(0), callout: .below),

        // Front, right: the A/B/X/Y diamond high, the right stick below and
        // inboard. Positional numbering (see the note at the top).
        PlacedControl(id: "x", kind: .faceButton, center: CGPoint(x: 0.755, y: 0.225), size: 0.058,
                      inputs: .button(3), note: "Top button", callout: .above),
        PlacedControl(id: "y", kind: .faceButton, center: CGPoint(x: 0.689, y: 0.32), size: 0.058,
                      inputs: .button(2), note: "Left button", callout: .left),
        PlacedControl(id: "a", kind: .faceButton, center: CGPoint(x: 0.821, y: 0.32), size: 0.058,
                      inputs: .button(1), note: "Right button", callout: .right),
        PlacedControl(id: "b", kind: .faceButton, center: CGPoint(x: 0.755, y: 0.415), size: 0.058,
                      inputs: .button(0), note: "Bottom button", callout: .below),
        PlacedControl(id: "rstick", kind: .stick, center: CGPoint(x: 0.63, y: 0.565), size: 0.13,
                      inputs: .stick(x: 2, y: 3, press: 12), callout: .below),

        // Center: Minus and Plus on top, Capture and HOME below them, the
        // NFC touchpoint between Minus and Plus.
        PlacedControl(id: "minus", kind: .menuButton, center: CGPoint(x: 0.385, y: 0.2), size: 0.034,
                      symbol: "minus", inputs: .button(8), callout: .above),
        PlacedControl(id: "plus", kind: .menuButton, center: CGPoint(x: 0.615, y: 0.2), size: 0.034,
                      symbol: "plus", inputs: .button(9), callout: .above),
        PlacedControl(id: "nfc", kind: .other, center: CGPoint(x: 0.5, y: 0.2), size: 0.1, height: 0.06,
                      shape: .roundedRect(corner: 0.3),
                      readable: .notReported("The NFC touchpoint reads amiibo for the console; it is not an input")),
        PlacedControl(id: "capture", kind: .menuButton, center: CGPoint(x: 0.43, y: 0.335), size: 0.038,
                      shape: .roundedRect(corner: 0.2), symbol: "camera", inputs: .button(14),
                      pathInputs: [.rawSDL: .button(22)],
                      readable: .conditional("GameController reports it as Button Share (btn 14). The SDL row has no Capture, so a raw read puts it on the first extra slot, usually btn 22"),
                      note: "macOS keeps its screenshot gesture off this button while InputConfig reads the pad", callout: .below),
        PlacedControl(id: "home", kind: .homeButton, center: CGPoint(x: 0.57, y: 0.335), size: 0.045,
                      symbol: "house", inputs: .button(10),
                      note: "macOS keeps its system gesture off HOME while InputConfig reads the pad", callout: .below),
    ]
}
