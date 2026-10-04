import Foundation
import CoreGraphics

extension ControllerLayout {
    /// A single Joy-Con (R) (HAC-016, 057E:2007), 102 x 35.9 x 28.4 mm,
    /// drawn held sideways, the way macOS models it: the flat SL/SR rail on
    /// top, the stick left of center, the A/B/X/Y diamond right of center,
    /// Plus in the top right corner, HOME up and to the left of the stick.
    /// Turning the upright Joy-Con a quarter turn clockwise puts its top end
    /// (R and ZR) on the right and its bottom end (the IR camera) on the left.
    ///
    /// Read only through GameController. macOS names it "Nintendo Switch
    /// Joy-Con (R)" and gives it no extendedGamepad, so it goes down the
    /// profile-only path (GameControllerService.cacheExtraButtons and the
    /// else branch of readControllerState): each button takes its
    /// knownButtonMap index, the stick arrives as "Direction Pad" on axes 0
    /// and 1 (Y flipped by profileAxisSign) and on hat 0, and the raw HID
    /// read is switched off for this device (RawHIDGamepadService counts
    /// 057E:2007 as listed by GameController), so R, ZR and the stick press
    /// never reach the app. Motion is filled only for extendedGamepad pads,
    /// so the gyro and accelerometer are never read either.
    ///
    /// Face buttons use the POSITIONAL numbering as held sideways: btn 0 the
    /// bottom button (A), 1 the right (X), 2 the left (B), 3 the top (Y).
    /// SDL (SDL_mfijoystick.m) confirms Apple names a single Joy-Con's
    /// buttons by their printed letter: Button A south, Button B west, Button
    /// X east, Button Y north. The profile-only read numbers them by those
    /// names (B on btn 1, X on btn 2), as 1.5 did, and the drawing follows
    /// it so rows made on 1.5 keep their buttons.
    ///
    /// Drawn sideways, as it is held alone. A group stored as "upright"
    /// by an earlier build falls back to this drawing.
    static let joyConRight = ControllerLayout(
        id: .joyConRight,
        displayName: "Joy-Con (R)",
        maker: .nintendo,
        family: .nintendo,
        modelNames: ButtonNames.ModelNames(
            renamed: [0: "A", 1: "B", 2: "X", 3: "Y", 4: "SL", 5: "SR"],
            short: [4: "SL", 5: "SR"],
            absent: [6, 7, 8, 11, 12, 13, 14, 15, 16, 17, 18, 19]),
        aspect: 102.0 / 35.9,
        topStrip: 0.14,
        backStrip: 0.27,
        silhouette: Silhouette(front: joyConRightSideways, top: joyConRightRail, back: joyConRightSideways),
        controls: joyConRightControls,
        // GameController's product category is exactly "Nintendo Switch
        // Joy-Con (R)". The fused pair is "(L/R)" and a Joy-Con 2 says
        // "Joy-Con 2", so neither contains "Joy-Con (R)".
        match: [
            [.brand(.joyConRight), .gcProductCategoryContains("Joy-Con (R)")],
        ],
        matchPriority: 10,
        readability: .partial("R, ZR, the stick press and motion never reach the Mac on a single Joy-Con (R)"),
        approximate: true,
        sources: [
            "nintendo.com Joy-Con specifications (102 x 35.9 x 28.4 mm)",
            "nintendo.com Joy-Con controller diagram (front: R, Plus, A/B/X/Y, stick, HOME; rail top to bottom: SR, player LEDs, SYNC, SL; back: ZR, IR motion camera)",
            "SDL src/joystick/apple/SDL_mfijoystick.m (product category \"Nintendo Switch Joy-Con (R)\"; Button B maps west and Button X east on a single Joy-Con)",
            "SDL src/joystick/hidapi/SDL_hidapi_switch.c (sideways mini mode: SL and SR as shoulders, Plus as Start, HOME as Guide)",
            "Product photos of the Joy-Con (R) for placement",
        ]
    )

    /// Sideways front: the straight rail along the top with small corners,
    /// and the outer shell along the bottom, straight between two large
    /// (about 15 mm) round corners at each end.
    static let joyConRightSideways: [PathOp] = [
        .move(0.02, 0.01),
        .line(0.98, 0.01),
        .quad(0.993, 0.045, cx: 0.993, cy: 0.01),
        .line(0.993, 0.572),
        .curve(0.846, 0.99, c1x: 0.993, c1y: 0.803, c2x: 0.927, c2y: 0.99),
        .line(0.154, 0.99),
        .curve(0.007, 0.572, c1x: 0.073, c1y: 0.99, c2x: 0.007, c2y: 0.803),
        .line(0.007, 0.045),
        .quad(0.02, 0.01, cx: 0.007, cy: 0.01),
        .close,
    ]

    /// The rail seen from above: a long strip with rounded ends.
    static let joyConRightRail: [PathOp] = [
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

    static let joyConRightControls: [PlacedControl] = [
        // Top (the rail), left to right as held: SL, SYNC, the four player
        // lights, SR. Apple's profile names SL and SR Left Shoulder and
        // Right Shoulder, so they read as btn 4 and 5.
        PlacedControl(id: "sl", kind: .shoulder, face: .top, center: CGPoint(x: 0.25, y: 0.5), size: 0.14, height: 0.035,
                      shape: .capsule(angleDegrees: 0), printed: "SL", inputs: .button(4),
                      readable: .conditional("Reads as btn 4 if macOS names it Left Shoulder, as SDL expects; a dynamic btn from 20 up otherwise"),
                      callout: .above),
        PlacedControl(id: "sync", kind: .other, face: .top, center: CGPoint(x: 0.41, y: 0.5), size: 0.025,
                      readable: .notReported("The Joy-Con handles SYNC itself for pairing; it never reaches the Mac")),
        PlacedControl(id: "player-leds", kind: .light, face: .top, center: CGPoint(x: 0.56, y: 0.5), size: 0.1, height: 0.012,
                      shape: .capsule(angleDegrees: 0),
                      readable: .notReported("The player lights are not a GameController light, so InputConfig neither reads nor sets them")),
        PlacedControl(id: "sr", kind: .shoulder, face: .top, center: CGPoint(x: 0.75, y: 0.5), size: 0.14, height: 0.035,
                      shape: .capsule(angleDegrees: 0), printed: "SR", inputs: .button(5),
                      readable: .conditional("Reads as btn 5 if macOS names it Right Shoulder, as SDL expects; a dynamic btn from 20 up otherwise"),
                      callout: .above),

        // Front, left end: the IR motion camera window (the bottom end when
        // upright).
        PlacedControl(id: "ir-camera", kind: .other, center: CGPoint(x: 0.02, y: 0.5), size: 0.018, height: 0.12,
                      shape: .capsule(angleDegrees: 0),
                      readable: .notReported("macOS does not expose the IR motion camera")),

        // Front: HOME up and to the left of the stick, the stick left of
        // center (the NFC reader sits under it).
        PlacedControl(id: "home", kind: .homeButton, center: CGPoint(x: 0.18, y: 0.31), size: 0.062,
                      symbol: "house", inputs: .button(10),
                      note: "macOS keeps its system gesture off HOME while InputConfig reads the pad", callout: .below),
        PlacedControl(id: "stick", kind: .stick, center: CGPoint(x: 0.415, y: 0.5), size: 0.145,
                      inputs: ControlInputs(axes: [.x(0), .y(1)], hat: 0),
                      note: "macOS reports it as Direction Pad: axes 0 and 1 and hat 0. Its press is not in Apple's single Joy-Con profile",
                      callout: .below),

        // Front, right of center: the A/B/X/Y diamond, numbered by the
        // printed letter (see the note at the top). Y on top, B left, X
        // right, A bottom.
        PlacedControl(id: "y", kind: .faceButton, center: CGPoint(x: 0.71, y: 0.265), size: 0.066,
                      printed: "Y", inputs: .button(3), note: "Top button when held sideways", callout: .above),
        PlacedControl(id: "b", kind: .faceButton, center: CGPoint(x: 0.622, y: 0.5), size: 0.066,
                      printed: "B", inputs: .button(1),
                      note: "Left button when held sideways",
                      callout: .below),
        PlacedControl(id: "x", kind: .faceButton, center: CGPoint(x: 0.798, y: 0.5), size: 0.066,
                      printed: "X", inputs: .button(2),
                      note: "Right button when held sideways",
                      callout: .below),
        PlacedControl(id: "a", kind: .faceButton, center: CGPoint(x: 0.71, y: 0.735), size: 0.066,
                      printed: "A", inputs: .button(0), note: "Bottom button when held sideways", callout: .below),

        // Front, top right corner: Plus.
        PlacedControl(id: "plus", kind: .menuButton, center: CGPoint(x: 0.908, y: 0.28), size: 0.045,
                      symbol: "plus", inputs: .button(9), note: "Reaches the app as the profile's Button Menu", callout: .above),

        // Front, right end: R sits on the end of the body (the top end when
        // upright), toward the outer shell.
        PlacedControl(id: "r", kind: .shoulder, center: CGPoint(x: 0.976, y: 0.45), size: 0.022, height: 0.13,
                      shape: .capsule(angleDegrees: 0), printed: "R",
                      readable: .notReported("GameController does not expose R on a single Joy-Con, and the raw HID read is switched off for it")),

        // Motion sensors inside the body, never read on this path.
        PlacedControl(id: "gyro", kind: .other, center: CGPoint(x: 0.2, y: 0.72), size: 0.075, height: 0.028,
                      shape: .capsule(angleDegrees: 0), printed: "Gyro",
                      readable: .notReported("readControllerState fills motion only for extendedGamepad pads, and a single Joy-Con has none")),

        // Back, as held: ZR behind R at the right end, toward the outer shell.
        PlacedControl(id: "zr", kind: .trigger(.digital), face: .back, center: CGPoint(x: 0.92, y: 0.55), size: 0.085, height: 0.14,
                      shape: .roundedRect(corner: 0.35), printed: "ZR",
                      readable: .notReported("GameController does not expose ZR on a single Joy-Con, and the raw HID read is switched off for it")),
    ]
}
