import Foundation
import CoreGraphics

extension ControllerLayout {
    /// A single Joy-Con (L) (HAC-015, 057E:2006), 102 x 35.9 x 28.4 mm,
    /// drawn held sideways: the flat SL/SR rail on top, the stick on the
    /// left, the four arrow buttons right of center.
    ///
    /// Read only through GameController. macOS names it "Nintendo Switch
    /// Joy-Con (L)" and gives it no extendedGamepad, so it goes down the
    /// profile-only path: each button takes its knownButtonMap index (or a
    /// dynamic one from 20 up), the stick arrives as "Direction Pad" on axes
    /// 0 and 1 (Y flipped) and on hat 0, and the raw HID read is switched off
    /// for this device (RawHIDGamepadService treats 057E:2006 as listed by
    /// GameController), so L and ZL never reach the app.
    ///
    /// Arrow buttons are numbered by the names Apple gives them (SDL
    /// confirms A south, B west, X east, Y north on a single Joy-Con), as
    /// the profile-only read and 1.5 number them: btn 0 the bottom button
    /// (the Left arrow), 1 the left (Up arrow), 2 the right (Down arrow),
    /// 3 the top (Right arrow).
    ///
    /// Drawn sideways, as it is held alone. A group stored as "upright"
    /// by an earlier build falls back to this drawing.
    static let joyConLeft = ControllerLayout(
        id: .joyConLeft,
        displayName: "Joy-Con (L)",
        maker: .nintendo,
        family: .nintendo,
        modelNames: ButtonNames.ModelNames(
            renamed: [0: "Left arrow", 1: "Up arrow", 2: "Down arrow", 3: "Right arrow", 4: "SL", 5: "SR", 8: "Minus", 9: "Minus", 10: "Capture"],
            short: [4: "SL", 5: "SR"],
            absent: [6, 7, 12, 13, 15, 16, 17, 18, 19]),
        aspect: 102.0 / 35.9,
        topStrip: 0.14,
        backStrip: 0.27,
        silhouette: Silhouette(front: joyConLeftSideways, top: joyConLeftRail, back: joyConLeftSideways),
        controls: joyConLeftControls,
        offBody: [
            OffBodyInput(serialized: "mtn gyroX +", reason: "Gyroscope inside the body, read through GameController motion"),
            OffBodyInput(serialized: "mtn gyroY +", reason: "Gyroscope inside the body, read through GameController motion"),
            OffBodyInput(serialized: "mtn gyroZ +", reason: "Gyroscope inside the body, read through GameController motion"),
            OffBodyInput(serialized: "mtn accelX +", reason: "Accelerometer inside the body, read through GameController"),
            OffBodyInput(serialized: "mtn accelY +", reason: "Accelerometer inside the body, read through GameController"),
            OffBodyInput(serialized: "mtn accelZ +", reason: "Accelerometer inside the body, read through GameController"),
            OffBodyInput(serialized: "mtn rollAngle +", reason: "Tilt angle the app integrates from the gyroscope"),
            OffBodyInput(serialized: "mtn pitchAngle +", reason: "Tilt angle the app integrates from the gyroscope"),
            OffBodyInput(serialized: "mtn yawAngle +", reason: "Turn angle the app integrates from the gyroscope"),
        ],
        // GameController's product category is exactly "Nintendo Switch
        // Joy-Con (L)". The fused pair is "(L/R)" and a Joy-Con 2 says
        // "Joy-Con 2", so neither contains "Joy-Con (L)".
        match: [
            [.brand(.joyConLeft), .gcProductCategoryContains("Joy-Con (L)")],
        ],
        matchPriority: 10,
        readability: .partial("L and ZL never reach the Mac; Minus, Capture and the stick press indices are unverified on hardware"),
        approximate: true,
        sources: [
            "nintendo.com Joy-Con specifications (102 x 35.9 x 28.4 mm; stick, four buttons, L/ZL, SL/SR, Minus, Capture, SYNC, player lights)",
            "SDL src/joystick/apple/SDL_mfijoystick.m (product category names; single Joy-Con A south, B west, X east, Y north; Direction Pad as the left stick)",
            "SDL src/joystick/hidapi/SDL_hidapi_switch.c (sideways mini mode: SL and SR as shoulders, Minus as Start, Capture as Guide)",
            "Product photos of the Joy-Con (L) for placement",
        ]
    )

    /// Sideways front: a straight rail along the top with small corners,
    /// and the outer shell along the bottom, gently bowed, meeting both
    /// ends in large round corners.
    static let joyConLeftSideways: [PathOp] = [
        .move(0.04, 0.02),
        .line(0.96, 0.02),
        .quad(0.99, 0.1, cx: 0.99, cy: 0.02),
        .line(0.99, 0.5),
        .curve(0.84, 0.98, c1x: 0.99, c1y: 0.8, c2x: 0.93, c2y: 0.98),
        .quad(0.16, 0.98, cx: 0.5, cy: 1.0),
        .curve(0.01, 0.5, c1x: 0.07, c1y: 0.98, c2x: 0.01, c2y: 0.8),
        .line(0.01, 0.1),
        .quad(0.04, 0.02, cx: 0.01, cy: 0.02),
        .close,
    ]

    /// The rail seen from above: a long strip with rounded ends.
    static let joyConLeftRail: [PathOp] = [
        .move(0.04, 0.08),
        .line(0.96, 0.08),
        .quad(0.99, 0.35, cx: 0.99, cy: 0.08),
        .line(0.99, 0.65),
        .quad(0.96, 0.92, cx: 0.99, cy: 0.92),
        .line(0.04, 0.92),
        .quad(0.01, 0.65, cx: 0.01, cy: 0.92),
        .line(0.01, 0.35),
        .quad(0.04, 0.08, cx: 0.01, cy: 0.08),
        .close,
    ]

    static let joyConLeftControls: [PlacedControl] = [
        // Top (the rail): SL near the left end, SR near the right, the four
        // player lights and the small SYNC button between them.
        PlacedControl(id: "sl", kind: .shoulder, face: .top, center: CGPoint(x: 0.23, y: 0.5), size: 0.15, height: 0.035,
                      shape: .capsule(angleDegrees: 0), printed: "SL", inputs: .button(4),
                      readable: .conditional("Reads as btn 4 if macOS names it Left Shoulder, as SDL expects; a dynamic btn from 20 up if it is Left Side Button"),
                      callout: .above),
        PlacedControl(id: "sr", kind: .shoulder, face: .top, center: CGPoint(x: 0.77, y: 0.5), size: 0.15, height: 0.035,
                      shape: .capsule(angleDegrees: 0), printed: "SR", inputs: .button(5),
                      readable: .conditional("Reads as btn 5 if macOS names it Right Shoulder, as SDL expects; a dynamic btn from 20 up if it is Right Side Button"),
                      callout: .above),
        PlacedControl(id: "player-leds", kind: .light, face: .top, center: CGPoint(x: 0.47, y: 0.5), size: 0.1, height: 0.012,
                      shape: .capsule(angleDegrees: 0),
                      readable: .notReported("The player lights are not a GameController light, so InputConfig neither reads nor sets them")),
        PlacedControl(id: "sync", kind: .other, face: .top, center: CGPoint(x: 0.6, y: 0.5), size: 0.025,
                      readable: .notReported("The Joy-Con handles SYNC itself for pairing; it never reaches the Mac")),

        // Front, left end: L sits on the end of the body (the top edge when
        // upright). macOS does not expose it on a single Joy-Con.
        PlacedControl(id: "l", kind: .shoulder, center: CGPoint(x: 0.022, y: 0.36), size: 0.025, height: 0.15,
                      shape: .capsule(angleDegrees: 0), printed: "L",
                      readable: .notReported("GameController does not expose L on a single Joy-Con, and the raw HID read is switched off for it")),

        // Front: Minus in the corner by the rail, the stick, the arrow
        // diamond (positional numbering, see the note at the top), Capture
        // near the right end.
        PlacedControl(id: "minus", kind: .menuButton, center: CGPoint(x: 0.085, y: 0.27), size: 0.05,
                      symbol: "minus", inputs: ControlInputs(buttons: [9, 8]),
                      readable: .conditional("Unverified on hardware: btn 9 if macOS names it Button Menu (SDL reads it as Start), btn 8 if Button Options"),
                      callout: .below),
        PlacedControl(id: "stick", kind: .stick, center: CGPoint(x: 0.29, y: 0.53), size: 0.15,
                      inputs: ControlInputs(axes: [.x(0), .y(1)], hat: 0, press: 11),
                      note: "macOS reports it as Direction Pad: axes 0 and 1 and hat 0. The press is btn 11 if named Left Thumbstick Button (unverified)",
                      callout: .below),
        PlacedControl(id: "up", kind: .faceButton, center: CGPoint(x: 0.49, y: 0.53), size: 0.078,
                      symbol: "arrowtriangle.up.fill", inputs: .button(1),
                      readable: .conditional("Unverified on hardware: Apple's Button B"),
                      note: "Left button when held sideways", callout: .below),
        PlacedControl(id: "right", kind: .faceButton, center: CGPoint(x: 0.58, y: 0.28), size: 0.078,
                      symbol: "arrowtriangle.right.fill", inputs: .button(3),
                      readable: .conditional("Unverified on hardware: Apple's Button Y"),
                      note: "Top button when held sideways", callout: .above),
        PlacedControl(id: "down", kind: .faceButton, center: CGPoint(x: 0.67, y: 0.53), size: 0.078,
                      symbol: "arrowtriangle.down.fill", inputs: .button(2),
                      readable: .conditional("Unverified on hardware: Apple's Button X"),
                      note: "Right button when held sideways", callout: .below),
        PlacedControl(id: "left", kind: .faceButton, center: CGPoint(x: 0.58, y: 0.78), size: 0.078,
                      symbol: "arrowtriangle.left.fill", inputs: .button(0),
                      readable: .conditional("Unverified on hardware: Apple's Button A"),
                      note: "Bottom button when held sideways", callout: .below),
        PlacedControl(id: "capture", kind: .menuButton, center: CGPoint(x: 0.79, y: 0.34), size: 0.06,
                      shape: .roundedRect(corner: 0.2), symbol: "camera", inputs: ControlInputs(buttons: [14, 10]),
                      readable: .conditional("Unverified on hardware: btn 14 if macOS names it Button Share or Button Capture, btn 10 if Button Home (SDL reads it as Guide)"),
                      callout: .below),

        // Back, as held: ZL behind L at the left end.
        PlacedControl(id: "zl", kind: .trigger(.digital), face: .back, center: CGPoint(x: 0.07, y: 0.5), size: 0.083, height: 0.18,
                      shape: .roundedRect(corner: 0.35), printed: "ZL",
                      readable: .notReported("GameController does not expose ZL on a single Joy-Con, and the raw HID read is switched off for it")),
    ]
}
