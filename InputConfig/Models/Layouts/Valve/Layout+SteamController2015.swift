import Foundation
import CoreGraphics

extension ControllerLayout {
    /// The original Steam Controller (Valve, 2015), wired 28DE:1102 or its
    /// wireless dongle 28DE:1142. Neither GameController nor the raw HID
    /// gamepad path reads it: SteamControllerHelper opens its vendor
    /// interface and SteamControllerService.makeControllerState builds the
    /// slot's state on the controller's own numbering:
    ///   btn 0 RT full-pull click, 1 LT full-pull click, 2 RB, 3 LB,
    ///   4 Y, 5 B, 6 X, 7 A, 8 to 11 left pad edge clicks (up, right, left,
    ///   down), 12 Back, 13 Steam, 14 Start, 15 left grip, 16 right grip,
    ///   17 left pad click, 18 right pad click, 19 left pad touch,
    ///   20 right pad touch, 21 stick click, 22 internal stick-active flag.
    ///   axi 0/1 stick, 2/3 right pad, 4/5 analog triggers, 6/7 left pad;
    ///   hat 0 synthesized from btn 8 to 11.
    ///
    /// Positions are measured from Valve's straight-on store render: two
    /// big round pads in the upper lobes, Back, Steam and Start between
    /// them, the stick low and inboard on the left, ABXY mirrored on the
    /// right, and handles that splay outward below. The pads are Cirque
    /// 40 mm sensors; their coordinates are rotated 15 degrees on the body
    /// (SDL turns the left pad back by -15 and the right by +15), which
    /// InputConfig does not undo.
    static let steamController2015 = ControllerLayout(
        id: .steamController2015,
        displayName: "Steam Controller (2015)",
        maker: .valve,
        family: .steamController,
        aspect: 1.5,
        topStrip: 0.22,
        backStrip: 0.3,
        silhouette: Silhouette(front: steam2015Front, top: steam2015Top, back: steam2015Front),
        touchSurfaces: [
            TouchSurfaceSpec(surface: 0, controlID: "rpad", name: "Right trackpad", outline: .circle,
                             aspect: 1, maxFingers: 1, pressIndex: 18, touchIndex: 20,
                             positionAxes: (x: 2, y: 3), rotationDegrees: 15),
            TouchSurfaceSpec(surface: 1, controlID: "lpad", name: "Left trackpad", outline: .circle,
                             aspect: 1, maxFingers: 1, pressIndex: 17, touchIndex: 19,
                             positionAxes: (x: 6, y: 7), edgeClicks: [8, 9, 10, 11], rotationDegrees: -15),
        ],
        controls: steam2015Controls,
        offBody: [
            OffBodyInput(serialized: "btn 22", reason: "Internal flag: the left pad and the stick are in use together (hardware bit 23), used to split their shared axes", copy: true),
            OffBodyInput(serialized: "mtn gyroX +", reason: "Gyroscope inside the body: the helper parses it but does not switch IMU reports on yet, so no motion reaches presets"),
            OffBodyInput(serialized: "mtn gyroY +", reason: "Gyroscope inside the body: the helper parses it but does not switch IMU reports on yet, so no motion reaches presets"),
            OffBodyInput(serialized: "mtn gyroZ +", reason: "Gyroscope inside the body: the helper parses it but does not switch IMU reports on yet, so no motion reaches presets"),
            OffBodyInput(serialized: "mtn accelX +", reason: "Accelerometer inside the body: not read yet"),
            OffBodyInput(serialized: "mtn accelY +", reason: "Accelerometer inside the body: not read yet"),
            OffBodyInput(serialized: "mtn accelZ +", reason: "Accelerometer inside the body: not read yet"),
        ],
        // Only the helper's virtual slot is this controller; it is also the
        // only slot given the .steamController brand. The USB IDs cover a
        // raw read should one ever list it (they are 2015 only: the 2026
        // controller is 0x1302 to 0x1305).
        match: [
            [.steamHelper],
            [.brand(.steamController)],
            [.vidPid(vendor: 0x28DE, products: [0x1102, 0x1142])],
        ],
        matchPriority: 20,
        readability: .partial("Read by InputConfig's Steam Controller helper over USB or the wireless dongle. Both trackpads are touch surfaces (the right one the main, the left the second); the gyro, haptics and Bluetooth LE mode are not used"),
        approximate: true,
        sources: [
            "store.steampowered.com/app/353370 (Valve's straight-on product render)",
            "SDL src/joystick/hidapi/SDL_hidapi_steam.c (button masks, 15 degree pad rotation)",
            "SDL src/joystick/hidapi/SDL_hidapi_steam.c (report layout, left pad and stick multiplexing)",
            "Steam Community: Cirque TM040040 40 mm trackpad in the Steam Controller",
        ]
    )

    /// The front: wide upper lobes for the pads, a flat top edge, and two
    /// handles that splay outward around a shallow U.
    static let steam2015Front: [PathOp] = Silhouette.symmetric([
        .move(0.5, 0.015),
        .curve(0.2, 0.025, c1x: 0.38, c1y: 0.012, c2x: 0.28, c2y: 0.015),
        .curve(0.06, 0.22, c1x: 0.11, c1y: 0.035, c2x: 0.065, c2y: 0.11),
        .curve(0.01, 0.72, c1x: 0.05, c1y: 0.38, c2x: 0.0, c2y: 0.55),
        .curve(0.09, 0.985, c1x: 0.015, c1y: 0.88, c2x: 0.04, c2y: 0.98),
        .curve(0.215, 0.93, c1x: 0.15, c1y: 0.995, c2x: 0.2, c2y: 0.97),
        .curve(0.33, 0.68, c1x: 0.24, c1y: 0.82, c2x: 0.28, c2y: 0.70),
        .curve(0.5, 0.665, c1x: 0.38, c1y: 0.665, c2x: 0.45, c2y: 0.665),
    ])

    /// The top edge from above: rounded trigger housings at each end and a
    /// slight dip at the center rear where the Micro-USB port is.
    static let steam2015Top: [PathOp] = Silhouette.symmetric([
        .move(0.5, 0.14),
        .curve(0.2, 0.06, c1x: 0.4, c1y: 0.14, c2x: 0.3, c2y: 0.05),
        .curve(0.04, 0.42, c1x: 0.1, c1y: 0.07, c2x: 0.04, c2y: 0.2),
        .curve(0.1, 0.95, c1x: 0.04, c1y: 0.7, c2x: 0.06, c2y: 0.92),
        .curve(0.5, 0.96, c1x: 0.25, c1y: 0.97, c2x: 0.4, c2y: 0.96),
    ])

    static let steam2015Controls: [PlacedControl] = [
        // Top: bumpers wrap the front corners, the long-travel analog
        // triggers sit behind them and click at the end of the pull.
        PlacedControl(id: "lt", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.23, y: 0.2391), size: 0.15, height: 0.13,
                      shape: .roundedRect(corner: 0.35), inputs: .trigger(axis: 4, digital: 1),
                      note: "Analog pull on axis 4; the full-pull click is button 1", callout: .above),
        PlacedControl(id: "rt", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.77, y: 0.2391), size: 0.15, height: 0.13,
                      shape: .roundedRect(corner: 0.35), inputs: .trigger(axis: 5, digital: 0),
                      note: "Analog pull on axis 5; the full-pull click is button 0", callout: .above),
        PlacedControl(id: "lb", kind: .shoulder, face: .top, center: CGPoint(x: 0.2, y: 0.72), size: 0.2, height: 0.045,
                      shape: .capsule(angleDegrees: 0), printed: "LB", inputs: .button(3), callout: .below),
        PlacedControl(id: "rb", kind: .shoulder, face: .top, center: CGPoint(x: 0.8, y: 0.72), size: 0.2, height: 0.045,
                      shape: .capsule(angleDegrees: 0), printed: "RB", inputs: .button(2), callout: .below),
        PlacedControl(id: "usb", kind: .port, face: .top, center: CGPoint(x: 0.5, y: 0.45), size: 0.05, height: 0.018,
                      shape: .roundedRect(corner: 0.3), note: "Micro-USB charging and wired port"),

        // Upper lobes: the two trackpads. The left one carries a raised
        // cross; its edge clicks are the D-pad.
        PlacedControl(id: "lpad", kind: .trackpad, center: CGPoint(x: 0.227, y: 0.275), size: 0.205,
                      inputs: ControlInputs(axes: [.x(6), .y(7)], press: 17, touch: 19, surface: 1),
                      note: "Second touch surface; its position is also on axes 6 and 7, shared with the stick in hardware", callout: .above),
        PlacedControl(id: "dpad", kind: .dpad, center: CGPoint(x: 0.227, y: 0.275), size: 0.14, shape: .crossPad,
                      inputs: ControlInputs(hat: 0, edgeClicks: [8, 9, 10, 11]),
                      note: "Clicks on the left trackpad's edges; hat 0 is built from them", callout: .below, overlayOf: "lpad"),
        PlacedControl(id: "rpad", kind: .trackpad, center: CGPoint(x: 0.773, y: 0.275), size: 0.205,
                      inputs: ControlInputs(axes: [.x(2), .y(3)], press: 18, touch: 20, surface: 0),
                      note: "Main touch surface; its position is also on axes 2 and 3", callout: .above),

        // Center bridge: Back (left arrow), Steam, Start (right arrow).
        PlacedControl(id: "back", kind: .menuButton, center: CGPoint(x: 0.414, y: 0.264), size: 0.056, height: 0.032,
                      shape: .capsule(angleDegrees: 0), symbol: "arrowtriangle.left.fill", inputs: .button(12), callout: .below),
        PlacedControl(id: "steam", kind: .homeButton, center: CGPoint(x: 0.5, y: 0.238), size: 0.075,
                      printed: "Steam", inputs: .button(13), callout: .above),
        PlacedControl(id: "start", kind: .menuButton, center: CGPoint(x: 0.586, y: 0.264), size: 0.056, height: 0.032,
                      shape: .capsule(angleDegrees: 0), symbol: "arrowtriangle.right.fill", inputs: .button(14), callout: .below),

        // Lower center: the stick under the left pad, ABXY under the right.
        PlacedControl(id: "stick", kind: .stick, center: CGPoint(x: 0.372, y: 0.479), size: 0.13,
                      inputs: .stick(x: 0, y: 1, press: 21), note: "Reads zero while the left pad alone is touched", callout: .below),
        PlacedControl(id: "y", kind: .faceButton, center: CGPoint(x: 0.62, y: 0.396), size: 0.045, tint: .xboxYellow,
                      inputs: .button(4), callout: .above),
        PlacedControl(id: "x", kind: .faceButton, center: CGPoint(x: 0.564, y: 0.479), size: 0.045, tint: .xboxBlue,
                      inputs: .button(6), callout: .left),
        PlacedControl(id: "b", kind: .faceButton, center: CGPoint(x: 0.676, y: 0.479), size: 0.045, tint: .xboxRed,
                      inputs: .button(5), callout: .right),
        PlacedControl(id: "a", kind: .faceButton, center: CGPoint(x: 0.62, y: 0.562), size: 0.045, tint: .xboxGreen,
                      inputs: .button(7), callout: .below),

        // Back, as held: the long grip buttons down the back of each handle,
        // following the handles' outward splay.
        PlacedControl(id: "lgrip", kind: .gripButton, face: .back, center: CGPoint(x: 0.15, y: 0.7), size: 0.04, height: 0.11,
                      shape: .capsule(angleDegrees: 12), printed: "LG", inputs: .button(15), callout: .below),
        PlacedControl(id: "rgrip", kind: .gripButton, face: .back, center: CGPoint(x: 0.85, y: 0.7), size: 0.04, height: 0.11,
                      shape: .capsule(angleDegrees: -12), printed: "RG", inputs: .button(16), callout: .below),
    ]
}
