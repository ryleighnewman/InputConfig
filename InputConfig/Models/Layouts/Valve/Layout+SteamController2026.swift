import Foundation
import CoreGraphics

extension ControllerLayout {
    /// Steam Controller (Valve, 2026), 159 by 111 by 57 mm. Read directly over
    /// raw HID on a USB cable (28DE:1302), Bluetooth (1303) or the Steam
    /// Controller Puck (1304, 1305): ControllerProfileDatabase's
    /// "valve-steam-controller-2026" profile hands reports 0x42, 0x45 and 0x47
    /// to HIDReportDecoder.decodeSteamController2026, which follows SDL's
    /// Triton driver. GameController does not list it.
    ///
    /// Inputs, as the decoder writes them:
    ///   btn 0 to 3 A B X Y, 4 L1, 5 R1, 6 and 7 the digital copies of the
    ///   triggers (the end click, else the analog value), 8 View (left),
    ///   9 Menu (right), 10 Steam, 11 and 12 L3 and R3, 13 Quick Access,
    ///   14 L4, 15 R4, 16 L5, 17 R5, 18 and 19 left and right trackpad click,
    ///   20 and 21 trackpad touch, 22 and 23 stick touch, 24 and 25 grip touch.
    ///   axi 0 to 3 the sticks, 4 and 5 the triggers, 6/7 the left trackpad,
    ///   8/9 the right trackpad (Y down positive, 0 when not touched),
    ///   10 and 11 trackpad pressure. hat 0 is the D-pad. Gyro and
    ///   accelerometer go through RawHIDGamepad.processMotion.
    /// View is bit 0x4000 and Menu bit 0x40; SDL's constant names read the
    /// other way round, but the open firmware's devicetree puts View on the
    /// left, which is how the decoder numbers them.
    ///
    /// Positions are measured from Valve's straight-on store render (the
    /// front) and iFixit's straight-on photo of the back cover; the top is
    /// from GIGAZINE's photo of the shoulder edge. The body is a Steam Deck
    /// without the screen: a flat top edge, sides that widen toward the
    /// bottom, and two short grips around a shallow arch. Upper band: the
    /// D-pad and the A B X Y diamond in the outer corners, View and Menu
    /// small capsules near the top edge, the round Steam button between the
    /// sticks. Lower band: two 34.5 mm square trackpads, each turned about
    /// 7 degrees so its top leans toward the center, with the three-dot
    /// Quick Access button between them. SDL does not rotate the pad
    /// coordinates, so the surfaces keep rotation 0.
    static let steamController2026 = ControllerLayout(
        id: .steamController2026,
        displayName: "Steam Controller (2026)",
        maker: .valve,
        family: .steamController2026,
        aspect: 159.0 / 111.0,
        topStrip: 0.22,
        backStrip: 0.53,
        silhouette: Silhouette(front: steam2026Front, top: steam2026Top, back: steam2026Front),
        touchSurfaces: [
            TouchSurfaceSpec(surface: 0, controlID: "rpad", name: "Right trackpad", outline: .roundedSquare,
                             aspect: 1, maxFingers: 1, hasPressure: true, pressIndex: 19, touchIndex: 21,
                             positionAxes: (x: 8, y: 9), pressureAxis: 11, rotationDegrees: 0),
            TouchSurfaceSpec(surface: 1, controlID: "lpad", name: "Left trackpad", outline: .roundedSquare,
                             aspect: 1, maxFingers: 1, hasPressure: true, pressIndex: 18, touchIndex: 20,
                             positionAxes: (x: 6, y: 7), pressureAxis: 10, rotationDegrees: 0),
        ],
        controls: steam2026Controls,
        // The raw profile, or its USB IDs. A raw 2026 pad is also given the
        // .steamController brand (GameControllerService), which the 2015
        // layout matches, so this one must rank above it.
        match: [
            [.rawProfileLayout("steamController2026")],
            [.rawProfileIdentifier("valve-steam-controller-2026")],
            [.vidPid(vendor: 0x28DE, products: [0x1302, 0x1303, 0x1304, 0x1305])],
        ],
        matchPriority: 30,
        readability: .partial("Read directly over USB, Bluetooth or the Puck while Steam is closed; Steam takes the controller over while it runs, and the haptics are not used"),
        approximate: true,
        sources: [
            "store.steampowered.com/hardware/steamcontroller (Valve's straight-on product render)",
            "en.wikipedia.org Steam Controller (2026) (111 x 159 x 57 mm, 34.5 mm square trackpads, L1 R1 L2 R2 L4 R4 L5 R5, capacitive grip sensors)",
            "pcgamer.com Steam Controller (2026) review",
            "ifixit.com Steam Controller (2nd Gen, 2026) Back Cover Replacement (straight-on back photo, L4 L5 R4 R5 legends)",
            "gigazine.net Steam Controller hands-on (shoulder edge photo with L1 L2 R1 R2 legends and the USB-C port)",
            "SDL src/joystick/hidapi/SDL_hidapi_steam_triton.c (button masks, trackpads, pressure)",
        ]
    )

    /// The front: a flat top edge with rounded corners, sides that widen
    /// toward the bottom, and short grips around a shallow, flat arch.
    static let steam2026Front: [PathOp] = Silhouette.symmetric([
        .move(0.5, 0.012),
        .line(0.27, 0.012),
        .curve(0.106, 0.095, c1x: 0.17, c1y: 0.012, c2x: 0.128, c2y: 0.04),
        .curve(0.012, 0.7, c1x: 0.06, c1y: 0.24, c2x: 0.015, c2y: 0.52),
        .curve(0.125, 0.988, c1x: 0.009, c1y: 0.93, c2x: 0.05, c2y: 0.988),
        .curve(0.237, 0.796, c1x: 0.175, c1y: 0.988, c2x: 0.195, c2y: 0.84),
        .curve(0.5, 0.775, c1x: 0.26, c1y: 0.777, c2x: 0.4, c2y: 0.775),
    ])

    /// The shoulder edge from above: the trigger housings stand out behind
    /// a straight bar that carries the USB-C port at the center.
    static let steam2026Top: [PathOp] = Silhouette.symmetric([
        .move(0.5, 0.3),
        .line(0.33, 0.3),
        .curve(0.24, 0.07, c1x: 0.28, c1y: 0.3, c2x: 0.29, c2y: 0.07),
        .curve(0.04, 0.4, c1x: 0.1, c1y: 0.06, c2x: 0.04, c2y: 0.2),
        .curve(0.1, 0.95, c1x: 0.04, c1y: 0.75, c2x: 0.06, c2y: 0.93),
        .curve(0.5, 0.96, c1x: 0.25, c1y: 0.97, c2x: 0.4, c2y: 0.96),
    ])

    static let steam2026Controls: [PlacedControl] = [
        // Top: the triggers sit behind the bumpers at the outer corners;
        // the controller prints L1 L2 R1 R2 on them.
        PlacedControl(id: "l2", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.19, y: 0.175), size: 0.15, height: 0.13,
                      shape: .roundedRect(corner: 0.35), printed: "L2", inputs: .trigger(axis: 4, digital: 6),
                      note: "Analog pull on axis 4; button 6 is the end click, else the pull", callout: .above),
        PlacedControl(id: "r2", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.81, y: 0.175), size: 0.15, height: 0.13,
                      shape: .roundedRect(corner: 0.35), printed: "R2", inputs: .trigger(axis: 5, digital: 7),
                      note: "Analog pull on axis 5; button 7 is the end click, else the pull", callout: .above),
        PlacedControl(id: "l1", kind: .shoulder, face: .top, center: CGPoint(x: 0.19, y: 0.76), size: 0.18, height: 0.045,
                      shape: .capsule(angleDegrees: 0), printed: "L1", inputs: .button(4), callout: .below),
        PlacedControl(id: "r1", kind: .shoulder, face: .top, center: CGPoint(x: 0.81, y: 0.76), size: 0.18, height: 0.045,
                      shape: .capsule(angleDegrees: 0), printed: "R1", inputs: .button(5), callout: .below),
        PlacedControl(id: "usbc", kind: .port, face: .top, center: CGPoint(x: 0.5, y: 0.62), size: 0.05, height: 0.018,
                      shape: .roundedRect(corner: 0.5), note: "USB-C"),

        // Front, upper band: D-pad in the left corner, View and Menu near
        // the top edge, Steam between the sticks, A B X Y in the right corner
        // printed in one color.
        PlacedControl(id: "dpad", kind: .dpad, center: CGPoint(x: 0.188, y: 0.175), size: 0.15, shape: .crossPad,
                      inputs: .hat(0), callout: .below),
        PlacedControl(id: "view", kind: .menuButton, center: CGPoint(x: 0.32, y: 0.086), size: 0.06, height: 0.026,
                      shape: .capsule(angleDegrees: 0), symbol: "rectangle.on.rectangle", inputs: .button(8), callout: .above),
        PlacedControl(id: "steam", kind: .homeButton, center: CGPoint(x: 0.5, y: 0.175), size: 0.068,
                      printed: "Steam", inputs: .button(10), callout: .below),
        PlacedControl(id: "menu", kind: .menuButton, center: CGPoint(x: 0.68, y: 0.086), size: 0.06, height: 0.026,
                      shape: .capsule(angleDegrees: 0), symbol: "line.3.horizontal", inputs: .button(9), callout: .above),
        PlacedControl(id: "y", kind: .faceButton, center: CGPoint(x: 0.8125, y: 0.11), size: 0.058,
                      inputs: .button(3), callout: .above),
        PlacedControl(id: "x", kind: .faceButton, center: CGPoint(x: 0.754, y: 0.1855), size: 0.058,
                      inputs: .button(2), callout: .left),
        PlacedControl(id: "b", kind: .faceButton, center: CGPoint(x: 0.871, y: 0.1855), size: 0.058,
                      inputs: .button(1), callout: .right),
        PlacedControl(id: "a", kind: .faceButton, center: CGPoint(x: 0.8125, y: 0.261), size: 0.058,
                      inputs: .button(0), callout: .below),

        // The two TMR sticks, level and symmetric, with capacitive caps.
        PlacedControl(id: "lstick", kind: .stick, center: CGPoint(x: 0.354, y: 0.256), size: 0.115,
                      inputs: ControlInputs(axes: [.x(0), .y(1)], press: 11, touch: 22),
                      note: "Capacitive cap: touch is button 22", callout: .below),
        PlacedControl(id: "rstick", kind: .stick, center: CGPoint(x: 0.646, y: 0.256), size: 0.115,
                      inputs: ControlInputs(axes: [.x(2), .y(3)], press: 12, touch: 23),
                      note: "Capacitive cap: touch is button 23", callout: .below),

        // Front, lower band: the square trackpads under the sticks, Quick
        // Access between them.
        PlacedControl(id: "lpad", kind: .trackpad, center: CGPoint(x: 0.306, y: 0.545), size: 0.22, height: 0.22,
                      shape: .roundedRect(corner: 0.18),
                      inputs: ControlInputs(axes: [.x(6), .y(7)], press: 18, touch: 20, pressure: 10, surface: 1),
                      note: "Position on axes 6 and 7, pressure on axis 10; the second touch surface", callout: .below),
        PlacedControl(id: "quickAccess", kind: .menuButton, center: CGPoint(x: 0.5, y: 0.545), size: 0.07, height: 0.03,
                      shape: .capsule(angleDegrees: 0), symbol: "ellipsis", inputs: .button(13), callout: .below),
        PlacedControl(id: "rpad", kind: .trackpad, center: CGPoint(x: 0.694, y: 0.545), size: 0.22, height: 0.22,
                      shape: .roundedRect(corner: 0.18),
                      inputs: ControlInputs(axes: [.x(8), .y(9)], press: 19, touch: 21, pressure: 11, surface: 0),
                      note: "Position on axes 8 and 9, pressure on axis 11; the main touch surface", callout: .below),

        // Back, as held (player's left on the left): the capacitive grip
        // sensors, then L4 and R4 under the middle fingers and L5 and R5
        // lower and further out on each grip, following the grips' splay.
        PlacedControl(id: "lgripTouch", kind: .other, face: .back, center: CGPoint(x: 0.09, y: 0.8), size: 0.06, height: 0.14,
                      shape: .capsule(angleDegrees: 12), inputs: ControlInputs(touch: 24),
                      note: "Capacitive grip sensor: button 24 while a hand holds the left grip", callout: .below),
        PlacedControl(id: "rgripTouch", kind: .other, face: .back, center: CGPoint(x: 0.91, y: 0.8), size: 0.06, height: 0.14,
                      shape: .capsule(angleDegrees: -12), inputs: ControlInputs(touch: 25),
                      note: "Capacitive grip sensor: button 25 while a hand holds the right grip", callout: .below),
        PlacedControl(id: "l4", kind: .paddle, face: .back, center: CGPoint(x: 0.235, y: 0.505), size: 0.065, height: 0.075,
                      shape: .roundedRect(corner: 0.45), printed: "L4", inputs: .button(14), callout: .above),
        PlacedControl(id: "l5", kind: .paddle, face: .back, center: CGPoint(x: 0.182, y: 0.705), size: 0.065, height: 0.075,
                      shape: .roundedRect(corner: 0.45), printed: "L5", inputs: .button(16), callout: .above),
        PlacedControl(id: "r4", kind: .paddle, face: .back, center: CGPoint(x: 0.765, y: 0.505), size: 0.065, height: 0.075,
                      shape: .roundedRect(corner: 0.45), printed: "R4", inputs: .button(15), callout: .above),
        PlacedControl(id: "r5", kind: .paddle, face: .back, center: CGPoint(x: 0.818, y: 0.705), size: 0.065, height: 0.075,
                      shape: .roundedRect(corner: 0.45), printed: "R5", inputs: .button(17), callout: .above),
        PlacedControl(id: "puckContacts", kind: .port, face: .back, center: CGPoint(x: 0.5, y: 0.1), size: 0.07, height: 0.02,
                      shape: .roundedRect(corner: 0.5), note: "Charging contacts for the Steam Controller Puck"),
    ]
}
