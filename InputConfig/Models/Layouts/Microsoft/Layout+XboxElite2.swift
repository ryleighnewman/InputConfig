import Foundation
import CoreGraphics

extension ControllerLayout {
    /// Xbox Elite Wireless Controller Series 2 (model 1797), read through
    /// GameController as a GCXboxGamepad (Bluetooth, and USB on macOS 15 and
    /// later). The classic offset Xbox body at 153 by 102 mm: left stick high
    /// above an inboard D-pad, A B X Y high on the right above an inboard
    /// right stick, Xbox button top center, View and Menu either side of the
    /// Elite's profile button with its three profile lights above it. The
    /// face letters are printed in one color, not the standard pad's green,
    /// red, blue and yellow. Four paddle sockets and two three-position
    /// trigger stops are on the back.
    ///
    /// Inputs: buttons 0 to 12, axes 0 to 5 and hat 0 come from the typed
    /// extendedGamepad read (GameControllerService.readControllerState). The
    /// paddles are the physical profile's "Paddle 1" to "Paddle 4", which
    /// knownButtonMap puts on 16 to 19 (Apple's Paddle 1 is P1 upper right,
    /// 2 is P2 lower right, 3 is P3 upper left, 4 is P4 lower left, as SDL's
    /// mfi driver also reads them). The raw SDL fallback maps an Elite row's
    /// paddles to the same 16 to 19 (SDLGameControllerDB.xboxPaddleSlots).
    static let xboxElite2 = ControllerLayout(
        id: .xboxElite2,
        displayName: "Xbox Elite Series 2",
        maker: .microsoft,
        family: .xbox,
        // No Share button (the center button is the profile button), no
        // touchpad, no mute, no Fn buttons.
        modelNames: ButtonNames.ModelNames(absent: [13, 14, 15, 20, 21]),
        aspect: 1.5,
        topStrip: 0.2,
        backStrip: 0.5,
        silhouette: xboxElite2Body,
        controls: xboxElite2Controls,
        variants: [
            LayoutVariant(id: "standard", displayName: "Elite Series 2", isDefault: true),
            LayoutVariant(id: "core", displayName: "Elite Series 2 Core, no paddles fitted"),
        ],
        match: [
            [.brand(.xbox), .gcHasElement("Paddle 1")],
            [.brand(.xbox), .gcHasElement("Button Paddle 1")],
            // Raw HID fallback, only when GameController does not list the
            // pad: Elite Series 2 over USB, classic Bluetooth and BLE.
            [.vidPid(vendor: 0x045E, products: [0x0B00, 0x0B05, 0x0B22])],
        ],
        matchPriority: 30,
        readability: .partial("The paddles read only on the default profile; the profile button, profile lights, trigger stops and pair button never reach the Mac"),
        approximate: true,
        sources: [
            "xbox.com Elite Wireless Controller Series 2 product page (paddles, profile button, hair trigger locks, 3 profiles plus default)",
            "en.wikipedia.org Xbox Wireless Controller (153 x 102 x 61 mm body; Elite Series 2 profile button between View and Menu; three-level trigger locks)",
            "gameaccess.info Xbox Elite Wireless Controller Series 2 (hair trigger switches on the back, three settings)",
            "Apple GameController GCXboxGamepad.h (paddleButton1 to 4, default profile only)",
            "SDL src/joystick/apple/SDL_mfijoystick.m (Paddle 1 to 4 as P1 to P4)",
            "SDL gamecontrollerdb rows 030000005e040000050b and 030000005e040000220b (Mac OS X)",
        ]
    )

    /// The Xbox body: wide shoulders, a shallow arch between long grips, and
    /// a dip in the top edge at the USB-C port. The back is the same outline
    /// seen from behind as held.
    static let xboxElite2Body: Silhouette = {
        let body = Silhouette.gamepad(gripLength: 0.34, waist: 0.77, shoulder: 0.55, gripWidth: 0.23, flare: 0.02, topDip: 0.04)
        return Silhouette(front: body.front, top: body.top, back: body.front)
    }()

    static let xboxElite2Controls: [PlacedControl] = [
        // Top: triggers at the rear, bumpers wrapping the front corners, the
        // pair button just left of the USB-C port.
        PlacedControl(id: "lt", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.21, y: 0.2075), size: 0.15, height: 0.13,
                      shape: .roundedRect(corner: 0.35), inputs: .trigger(axis: 4, digital: 6),
                      note: "The left trigger stop on the back can shorten its travel", callout: .above),
        PlacedControl(id: "rt", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.79, y: 0.2075), size: 0.15, height: 0.13,
                      shape: .roundedRect(corner: 0.35), inputs: .trigger(axis: 5, digital: 7),
                      note: "The right trigger stop on the back can shorten its travel", callout: .above),
        PlacedControl(id: "lb", kind: .shoulder, face: .top, center: CGPoint(x: 0.21, y: 0.76), size: 0.24, height: 0.05,
                      shape: .capsule(angleDegrees: 0), inputs: .button(4), callout: .below),
        PlacedControl(id: "rb", kind: .shoulder, face: .top, center: CGPoint(x: 0.79, y: 0.76), size: 0.24, height: 0.05,
                      shape: .capsule(angleDegrees: 0), inputs: .button(5), callout: .below),
        PlacedControl(id: "pair", kind: .other, face: .top, center: CGPoint(x: 0.43, y: 0.55), size: 0.035, height: 0.018,
                      shape: .capsule(angleDegrees: 0),
                      readable: .notReported("The pair button is handled by the controller's radio and is not sent to the Mac")),
        PlacedControl(id: "usbc", kind: .port, face: .top, center: CGPoint(x: 0.5, y: 0.55), size: 0.06, height: 0.02,
                      shape: .roundedRect(corner: 0.5), note: "USB-C"),

        // Front, left wing: the stick high and outboard, the D-pad lower and inboard.
        PlacedControl(id: "lstick", kind: .stick, center: CGPoint(x: 0.265, y: 0.34), size: 0.135,
                      inputs: .stick(x: 0, y: 1, press: 11), note: "Swappable toppers and adjustable tension", callout: .below),
        PlacedControl(id: "dpad", kind: .dpad, center: CGPoint(x: 0.375, y: 0.575), size: 0.125, shape: .crossPad,
                      inputs: .hat(0), note: "Swappable: cross or faceted dish", callout: .below),

        // Front, right wing: A B X Y printed in one color, the right stick below and inboard.
        PlacedControl(id: "y", kind: .faceButton, center: CGPoint(x: 0.735, y: 0.235), size: 0.066,
                      inputs: .button(3), callout: .above),
        PlacedControl(id: "x", kind: .faceButton, center: CGPoint(x: 0.665, y: 0.34), size: 0.066,
                      inputs: .button(2), callout: .left),
        PlacedControl(id: "b", kind: .faceButton, center: CGPoint(x: 0.805, y: 0.34), size: 0.066,
                      inputs: .button(1), callout: .right),
        PlacedControl(id: "a", kind: .faceButton, center: CGPoint(x: 0.735, y: 0.445), size: 0.066,
                      inputs: .button(0), callout: .below),
        PlacedControl(id: "rstick", kind: .stick, center: CGPoint(x: 0.625, y: 0.575), size: 0.135,
                      inputs: .stick(x: 2, y: 3, press: 12), note: "Swappable toppers and adjustable tension", callout: .below),

        // Front, center: Xbox button, profile lights, View, profile button, Menu.
        PlacedControl(id: "xbox", kind: .homeButton, center: CGPoint(x: 0.5, y: 0.19), size: 0.095,
                      inputs: .button(10), callout: .above),
        PlacedControl(id: "profileLights", kind: .light, center: CGPoint(x: 0.5, y: 0.33), size: 0.045, height: 0.012,
                      shape: .capsule(angleDegrees: 0),
                      readable: .notReported("The three profile lights show the onboard profile; the Mac cannot read or set them"),
                      note: "No light lit is the default profile, the only one whose paddles reach the Mac"),
        PlacedControl(id: "view", kind: .menuButton, center: CGPoint(x: 0.42, y: 0.36), size: 0.042,
                      symbol: "rectangle.on.rectangle", inputs: .button(8), callout: .below),
        PlacedControl(id: "profile", kind: .menuButton, center: CGPoint(x: 0.5, y: 0.41), size: 0.05, height: 0.022,
                      shape: .capsule(angleDegrees: 0),
                      readable: .notReported("The profile button switches the controller's onboard profile and is not sent to the Mac"),
                      note: "Switches between the default profile and three custom ones"),
        PlacedControl(id: "menu", kind: .menuButton, center: CGPoint(x: 0.58, y: 0.36), size: 0.042,
                      symbol: "line.3.horizontal", inputs: .button(9), callout: .below),

        // Back, as held (player's left on the left): the trigger stops behind
        // each trigger, the upper paddles sweeping outward, the lower paddles
        // along the inside of each grip.
        PlacedControl(id: "triggerStopLeft", kind: .slider, face: .back, center: CGPoint(x: 0.25, y: 0.22), size: 0.03, height: 0.065,
                      shape: .capsule(angleDegrees: 0),
                      readable: .notReported("A mechanical three-position stop that shortens the left trigger's travel; nothing is sent")),
        PlacedControl(id: "triggerStopRight", kind: .slider, face: .back, center: CGPoint(x: 0.75, y: 0.22), size: 0.03, height: 0.065,
                      shape: .capsule(angleDegrees: 0),
                      readable: .notReported("A mechanical three-position stop that shortens the right trigger's travel; nothing is sent")),
        PlacedControl(id: "p3", kind: .paddle, face: .back, center: CGPoint(x: 0.3, y: 0.52), size: 0.12, height: 0.05,
                      shape: .capsule(angleDegrees: -20), printed: "P3", inputs: .button(18),
                      readable: .conditional("Default profile only (no profile light lit)"),
                      note: "Upper left. In a custom profile it copies another button and sends nothing of its own",
                      callout: .below, variants: ["standard"]),
        PlacedControl(id: "p4", kind: .paddle, face: .back, center: CGPoint(x: 0.33, y: 0.73), size: 0.05, height: 0.09,
                      shape: .capsule(angleDegrees: 20), printed: "P4", inputs: .button(19),
                      readable: .conditional("Default profile only (no profile light lit)"),
                      note: "Lower left. In a custom profile it copies another button and sends nothing of its own",
                      callout: .below, variants: ["standard"]),
        PlacedControl(id: "p1", kind: .paddle, face: .back, center: CGPoint(x: 0.7, y: 0.52), size: 0.12, height: 0.05,
                      shape: .capsule(angleDegrees: 20), printed: "P1", inputs: .button(16),
                      readable: .conditional("Default profile only (no profile light lit)"),
                      note: "Upper right. In a custom profile it copies another button and sends nothing of its own",
                      callout: .below, variants: ["standard"]),
        PlacedControl(id: "p2", kind: .paddle, face: .back, center: CGPoint(x: 0.67, y: 0.73), size: 0.05, height: 0.09,
                      shape: .capsule(angleDegrees: -20), printed: "P2", inputs: .button(17),
                      readable: .conditional("Default profile only (no profile light lit)"),
                      note: "Lower right. In a custom profile it copies another button and sends nothing of its own",
                      callout: .below, variants: ["standard"]),
    ]
}
