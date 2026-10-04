import Foundation
import CoreGraphics

extension ControllerLayout {
    /// PlayStation Access controller (CFI-ZAC1, 054C:0E5F), drawn from above
    /// lying flat in Sony's default Left orientation (stick base on the left,
    /// sockets 2, 3 and 4 nearest the player). About 191 x 141 x 39 mm: a
    /// round body 141 mm across with the stick dome joined to its left side
    /// by a short plate.
    ///
    /// The pad never reports a socket, only the DualSense function its
    /// active profile gives that socket. GameController reads it as an
    /// extended gamepad (GameControllerService.readControllerState: buttonA
    /// btn 0, buttonB 1, buttonMenu 9, buttonHome 10, left stick axi 0/1);
    /// the raw HID fallback uses the SDL row "PS5 Access Controller"
    /// (SDLGameControllerDBData.swift:240), which lands on the same indices.
    /// So each control below carries the input of Sony's base profile, the
    /// one the controller ships with: Cross on the center button, Circle on
    /// socket 5, Options on socket 7, the stick as the left stick. Every
    /// other function a profile can assign is listed in offBody.
    /// No touch surface, mute, motion or light writes on either path
    /// (GameControllerService.swift:837-841, HIDLightController.swift:392);
    /// the touch pad button's function, btn 13, is read when a profile puts
    /// it on a socket.
    static let psAccess = ControllerLayout(
        id: .psAccess,
        displayName: "PlayStation Access controller",
        maker: .sony,
        family: .playstation,
        modelNames: ButtonNames.ModelNames(renamed: [8: "Create"], short: [8: "Create"],
                                           absent: [15, 16, 17, 20, 21]),
        aspect: 191.0 / 141.0,
        // The top strip is the port side (opposite the stick) seen head on,
        // as Sony's Figure 10 draws it, spanning the round body's width.
        topStrip: 0.12,
        backStrip: 0,
        silhouette: Silhouette(front: psAccessFront, top: psAccessPortSide),
        controls: psAccessControls,
        offBody: psAccessAssignable,
        match: [
            [.brand(.accessController)],
            [.gcProductCategoryContains("Access Controller")],
            [.gcVendorNameContains("Access Controller")],
            [.vidPid(vendor: 0x054C, products: [0x0E5F])],
        ],
        // Above the DualSense (10): GameController may model the Access as a
        // DualSense, and a raw read without the name falls back to the
        // DualShock 4 brand.
        matchPriority: 20,
        readability: .partial("Reads the DualSense functions the active profile sends, not which socket, port or stick sent them. The Profile button never reaches the Mac"),
        approximate: true,
        sources: [
            "playstation.com support: How to connect an Access controller (base profile: Options socket 7, Circle socket 5, Cross center button, left stick; sockets numbered counterclockwise from the one nearest the stick)",
            "playstation.com Access controller product page images (top view used for the dome, plate, socket ring, PS logo and PROFILE positions)",
            "Access Controller for PlayStation 5 Expansion Port Specifications v1.00, Figure 10 (E1, E2, USB-C, E3, E4 on the side opposite the stick)",
            "PlayStation Blog, The Access controller for PS5 starter's guide (approx. 141 x 39 x 191 mm, four 3.5 mm ports, USB-C)",
            "SDL gamecontrollerdb row 0300004b4c0500005f0e000000010000 PS5 Access Controller",
        ]
    )

    /// From above: the round body (70 mm radius), the stick dome (27 mm
    /// radius) on its left, and the 37 mm plate between them, as one
    /// outline; then the light ring around the center button as a second
    /// ring, so the black center disc reads inside the socket ring.
    static let psAccessFront: [PathOp] = [
        .move(0.2774, 0.3688),
        .curve(0.6798, 0.008, c1x: 0.3259, c1y: 0.129, c2x: 0.4979, c2y: -0.0252),
        .curve(0.9974, 0.5, c1x: 0.8616, c1y: 0.0411, c2x: 0.9974, c2y: 0.2514),
        .curve(0.6798, 0.992, c1x: 0.9974, c1y: 0.7486, c2x: 0.8616, c2y: 0.9589),
        .curve(0.2774, 0.6312, c1x: 0.4979, c1y: 1.0252, c2x: 0.3259, c2y: 0.871),
        .line(0.2443, 0.6312),
        .curve(0.0893, 0.678, c1x: 0.2046, c1y: 0.6884, c2x: 0.1431, c2y: 0.7069),
        .curve(0.0, 0.5, c1x: 0.0354, c1y: 0.6491, c2x: 0.0, c2y: 0.5785),
        .curve(0.0893, 0.322, c1x: 0.0, c1y: 0.4215, c2x: 0.0354, c2y: 0.3509),
        .curve(0.2443, 0.3688, c1x: 0.1431, c1y: 0.2931, c2x: 0.2046, c2y: 0.3116),
        .close,
        // The light ring around the center button (about 81 mm across).
        .move(0.8442, 0.5),
        .curve(0.6309, 0.789, c1x: 0.8442, c1y: 0.6596, c2x: 0.7487, c2y: 0.789),
        .curve(0.4175, 0.5, c1x: 0.5131, c1y: 0.789, c2x: 0.4175, c2y: 0.6596),
        .curve(0.6309, 0.211, c1x: 0.4175, c1y: 0.3404, c2x: 0.5131, c2y: 0.211),
        .curve(0.8442, 0.5, c1x: 0.7487, c1y: 0.211, c2x: 0.8442, c2y: 0.3404),
        .close,
    ]

    /// The side wall opposite the stick, seen head on: the rim under the
    /// caps at the top, tapering toward the base.
    static let psAccessPortSide: [PathOp] = [
        .move(0.3, 0.1),
        .line(0.962, 0.1),
        .quad(0.997, 0.32, cx: 0.997, cy: 0.1),
        .quad(0.93, 0.9, cx: 0.99, cy: 0.9),
        .line(0.333, 0.9),
        .quad(0.266, 0.32, cx: 0.272, cy: 0.9),
        .quad(0.3, 0.1, cx: 0.266, cy: 0.1),
        .close,
    ]

    static let psAccessSocketNote = "The controller reports the function, not the socket; it lights when its assigned function fires."

    static let psAccessControls: [PlacedControl] = [
        // Stick dome, left. The stick has no click: L3 and R3 are functions
        // a socket or port can be given.
        PlacedControl(id: "stick", kind: .stick, center: CGPoint(x: 0.1414, y: 0.5), size: 0.17,
                      inputs: .stick(x: 0, y: 1, press: nil),
                      readable: .conditional("The left stick in the base profile; a profile can make it the right stick (axi 2 and 3)"),
                      note: "Takes the swappable stick caps; no click", callout: .above),
        // PS logo button on the dome's left wall.
        PlacedControl(id: "ps", kind: .homeButton, center: CGPoint(x: 0.0245, y: 0.5), size: 0.042,
                      inputs: .button(10),
                      readable: .notReported("macOS keeps the Access controller's PS button; it never reaches an app"),
                      callout: .below, name: "PS button"),
        // PROFILE on the dome's front right wall, the profile dots beside it.
        PlacedControl(id: "profile", kind: .menuButton, center: CGPoint(x: 0.236, y: 0.645), size: 0.052, height: 0.024,
                      shape: .capsule(angleDegrees: -40), printed: "P",
                      readable: .notReported("The controller switches among its three profiles itself; the press never reaches the Mac"),
                      note: "Profile button; the dots beside it show the active profile", callout: .below, name: "Profile button"),

        // Round body: the center button inside the light ring.
        PlacedControl(id: "center", kind: .faceButton, center: CGPoint(x: 0.6309, y: 0.5), size: 0.33,
                      symbol: "xmark", inputs: .button(0),
                      readable: .conditional("Cross in the base profile; another profile can give it any function"),
                      note: "Center button. The controller reports the function, not the button; it lights when its assigned function fires. Takes no caps",
                      callout: .below, name: "Center button"),

        // The eight sockets, numbered counterclockwise from the one nearest
        // the stick (the numbers are printed on the ring beside each). Each
        // is drawn as its cap lying along the ring.
        PlacedControl(id: "socket1", kind: .faceButton, center: CGPoint(x: 0.3429, y: 0.5), size: 0.126, height: 0.188,
                      shape: .capsule(angleDegrees: 0), printed: "1",
                      readable: .conditional("Assigned on the controller: the base profile leaves socket 1 empty"),
                      note: psAccessSocketNote, callout: .below, name: "Socket 1"),
        PlacedControl(id: "socket2", kind: .faceButton, center: CGPoint(x: 0.4273, y: 0.7758), size: 0.188, height: 0.126,
                      shape: .capsule(angleDegrees: 45), printed: "2",
                      readable: .conditional("Assigned on the controller: the base profile leaves socket 2 empty"),
                      note: psAccessSocketNote, callout: .below, name: "Socket 2"),
        PlacedControl(id: "socket3", kind: .faceButton, center: CGPoint(x: 0.6309, y: 0.8901), size: 0.188, height: 0.126,
                      shape: .capsule(angleDegrees: 0), printed: "3",
                      readable: .conditional("Assigned on the controller: the base profile leaves socket 3 empty"),
                      note: psAccessSocketNote, callout: .below, name: "Socket 3"),
        PlacedControl(id: "socket4", kind: .faceButton, center: CGPoint(x: 0.8345, y: 0.7758), size: 0.188, height: 0.126,
                      shape: .capsule(angleDegrees: -45), printed: "4",
                      readable: .conditional("Assigned on the controller: the base profile leaves socket 4 empty"),
                      note: psAccessSocketNote, callout: .below, name: "Socket 4"),
        PlacedControl(id: "socket5", kind: .faceButton, center: CGPoint(x: 0.9188, y: 0.5), size: 0.126, height: 0.188,
                      shape: .capsule(angleDegrees: 0), symbol: "circle", inputs: .button(1),
                      readable: .conditional("Circle in the base profile; another profile can give socket 5 any function"),
                      note: psAccessSocketNote, callout: .below, name: "Socket 5"),
        PlacedControl(id: "socket6", kind: .faceButton, center: CGPoint(x: 0.8345, y: 0.2242), size: 0.188, height: 0.126,
                      shape: .capsule(angleDegrees: 45), printed: "6",
                      readable: .conditional("Assigned on the controller: the base profile leaves socket 6 empty"),
                      note: psAccessSocketNote, callout: .above, name: "Socket 6"),
        PlacedControl(id: "socket7", kind: .faceButton, center: CGPoint(x: 0.6309, y: 0.1099), size: 0.188, height: 0.126,
                      shape: .capsule(angleDegrees: 0), symbol: "line.3.horizontal", inputs: .button(9),
                      readable: .conditional("Options in the base profile; another profile can give socket 7 any function"),
                      note: psAccessSocketNote, callout: .above, name: "Socket 7"),
        PlacedControl(id: "socket8", kind: .faceButton, center: CGPoint(x: 0.4273, y: 0.2242), size: 0.188, height: 0.126,
                      shape: .capsule(angleDegrees: -45), printed: "8",
                      readable: .conditional("Assigned on the controller: the base profile leaves socket 8 empty"),
                      note: psAccessSocketNote, callout: .above, name: "Socket 8"),

        // Top strip: the port side opposite the stick, head on. E1 is
        // nearest the player, E4 farthest; USB-C in the middle. E1 and E2
        // caption on the left, the side of USB-C they are on.
        PlacedControl(id: "e1", kind: .other, face: .top, center: CGPoint(x: 0.4645, y: 0.55), size: 0.042,
                      printed: "E1",
                      readable: .conditional("Assigned on the controller: a 3.5 mm button, trigger or stick device sends the function its profile gives this port"),
                      note: "Expansion port E1. The controller reports the function, not the port",
                      keySide: .left),
        PlacedControl(id: "e2", kind: .other, face: .top, center: CGPoint(x: 0.5477, y: 0.55), size: 0.042,
                      printed: "E2",
                      readable: .conditional("Assigned on the controller: a 3.5 mm button, trigger or stick device sends the function its profile gives this port"),
                      note: "Expansion port E2. The controller reports the function, not the port",
                      keySide: .left),
        PlacedControl(id: "usb", kind: .port, face: .top, center: CGPoint(x: 0.6309, y: 0.55), size: 0.05, height: 0.022,
                      shape: .capsule(angleDegrees: 0), printed: "USB",
                      readable: .notReported("USB-C for charging and the wired connection, not an input"),
                      note: "USB-C port"),
        PlacedControl(id: "e3", kind: .other, face: .top, center: CGPoint(x: 0.7141, y: 0.55), size: 0.042,
                      printed: "E3",
                      readable: .conditional("Assigned on the controller: a 3.5 mm button, trigger or stick device sends the function its profile gives this port"),
                      note: "Expansion port E3. The controller reports the function, not the port"),
        PlacedControl(id: "e4", kind: .other, face: .top, center: CGPoint(x: 0.7973, y: 0.55), size: 0.042,
                      printed: "E4",
                      readable: .conditional("Assigned on the controller: a 3.5 mm button, trigger or stick device sends the function its profile gives this port"),
                      note: "Expansion port E4. The controller reports the function, not the port"),
    ]

    /// The DualSense functions a profile can put on any socket, the center
    /// button, the stick or an expansion port. They have no fixed place.
    static let psAccessAssignable: [OffBodyInput] = {
        let why = "A function the active profile can give any socket, the center button, the stick or an expansion port"
        // 13 is the touch pad button's function: the controller has no
        // touch surface, but a profile can put the button on a socket.
        let buttons = [2, 3, 4, 5, 6, 7, 8, 11, 12, 13].map { OffBodyInput(serialized: "btn \($0)", reason: why) }
        let hat = ["U", "R", "D", "L"].map { OffBodyInput(serialized: "hat 0 \($0)", reason: why) }
        // The right stick both ways; L2 and R2 pull one way only.
        let rightStick = ["axi 2 +", "axi 2 -", "axi 3 +", "axi 3 -"].map { OffBodyInput(serialized: $0, reason: why) }
        let triggers = ["axi 4 +", "axi 5 +"].map { OffBodyInput(serialized: $0, reason: why) }
        return buttons + hat + rightStick + triggers
    }()
}
