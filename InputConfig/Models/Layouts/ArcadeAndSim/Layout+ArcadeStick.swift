import Foundation
import CoreGraphics

extension ControllerLayout {
    /// Arcade fight stick with a lever, PlayStation style, drawn after the
    /// Qanba Obsidian 2 (486 x 260 mm): the wide flat box with chamfered
    /// corners, textured side wings around a glossy art panel, a ball-top
    /// lever in the left half, eight 30 mm buttons in the Taito Vewlix
    /// layout (the first column dropped, the top row shifted right), the
    /// function bar along the rear of the panel (PS, L3, Turbo, Create,
    /// Mute, R3, Options, then the DP/LS/RS, platform and lock switches)
    /// and the touchpad in the rear right corner. The button grid uses the
    /// exact Vewlix offsets from the lever (Jasen's Customs
    /// FightStickLayoutProject vewlix_s_8button.dxf), which match the
    /// Obsidian 2 photo. Other sticks put their function buttons elsewhere.
    ///
    /// Read paths. GameController never lists these sticks; they are read
    /// raw. `inputs` is the raw SDL read, used for the sticks whose USB IDs
    /// have a bundled SDL GameControllerDB row (the match list below): those
    /// rows put Cross on btn 0, Circle 1, Square 2, Triangle 3, L1 4, R1 5,
    /// L2 6, R2 7, Share or Create 8, Options 9, PS 10, L3 11, R3 12 and the
    /// touchpad click 13, and the lever's D-pad on hat 0.
    /// `pathInputs[.rawDescriptor]` is the plain descriptor read of any other
    /// PS3 or PS4 class stick (and GP2040-CE boards in DInput mode), which
    /// numbers the button bits in report order: Square 0, Cross 1, Circle 2,
    /// Triangle 3, L1 to R2 4 to 7, Share 8, Options 9, L3 10, R3 11, PS 12,
    /// touchpad 13. That numbering is the PS3 and DS4 report order and is
    /// not verified on every board, so it is approximate.
    static let arcadeStick = ControllerLayout(
        id: .arcadeStick,
        displayName: "Arcade stick",
        maker: .arcadeAndSim,
        family: .playstation,
        aspect: 1.88,
        topStrip: 0,
        backStrip: 0,
        silhouette: Silhouette(front: arcadeStickFront),
        touchSurfaces: [
            TouchSurfaceSpec(surface: 0, controlID: "touchpad", name: "Touchpad", outline: .rect,
                             aspect: 2.0, maxFingers: 2, pressIndex: 13),
        ],
        controls: arcadeStickControls,
        variants: [
            LayoutVariant(id: "ps4", displayName: "PS4 or PS5 stick (touchpad)", isDefault: true),
            LayoutVariant(id: "ps3", displayName: "PS3 stick"),
            LayoutVariant(id: "ps4kicks", displayName: "PS4 stick, L2 and R2 also as buttons 22 and 23"),
        ],
        offBody: [
            OffBodyInput(serialized: "btn 22", reason: "Raw SDL read only: the L2 button bit on rows that read L2 as axis 4 (Mad Catz TE S+ PS4, Qanba Drone, Razer Panthera PS4), so L2 also lands here; the PS4 kicks variant draws it on L2", copy: true),
            OffBodyInput(serialized: "btn 23", reason: "Raw SDL read only: the R2 button bit on rows that read R2 as axis 5, so R2 also lands here; the PS4 kicks variant draws it on R2", copy: true),
            OffBodyInput(serialized: "axi 6 +", reason: "Raw SDL read only: on the Hori Fighting Stick mini 4, PDP 0E6F:0109 and Victrix rows, which name no stick axes, the lever's X in LS mode lands on the extra axes"),
            OffBodyInput(serialized: "axi 7 +", reason: "Raw SDL read only: on the same rows, the lever's Y in LS mode"),
        ],
        // Raw HID USB IDs of the fight sticks with a bundled SDL row (IDs as
        // decoded from the row GUIDs, little-endian): Qanba Dragon PS3
        // 2C22:2502 and Drone 2C22:2000; Mad Catz TE S+ PS3 0738:3384 and
        // PS4 0738:8384; Hori Fighting Stick mini 4 PS4 0F0D:0087 and PS3
        // 0F0D:0088; Razer Panthera PS4 1532:0401 and PS3 1532:0402; PDP
        // Versus Fighting PS3 0E6F:0109; Victrix Pro FS PS4 0E6F:0203 and
        // 0E6F:0207. The Hori RAP for Switch (0F0D:00AA) is left out: its row
        // is Nintendo ordered. Leverless boards are a separate model.
        match: [
            [.vidPid(vendor: 0x2C22, products: [0x2502, 0x2000])],
            [.vidPid(vendor: 0x0738, products: [0x3384, 0x8384])],
            [.vidPid(vendor: 0x0F0D, products: [0x0087, 0x0088])],
            [.vidPid(vendor: 0x1532, products: [0x0401, 0x0402])],
            [.vidPid(vendor: 0x0E6F, products: [0x0109, 0x0203, 0x0207])],
        ],
        matchPriority: 20,
        readability: .partial("Read in PS3 or PS4 mode. PC mode on most sticks is XInput, which macOS does not read; Turbo, Mute and the switches act inside the stick"),
        approximate: true,
        sources: [
            "qanbausa.com/obsidian-2 (48.6 x 26 x 11.6 cm) and arcadeshock.com Obsidian 2 top view photo",
            "github.com/JasensCustoms/FightStickLayoutProject dxf/vewlix_s_8button.dxf (Vewlix offsets from the lever)",
            "slagcoin.com/joystick/layout.html (Vewlix and button spacing)",
            "InputConfig/Services/SDLGameControllerDBData.swift fight stick rows",
            "GP2040-CE GamepadState.h and HIDDriver.cpp (DInput button order)",
        ],
        // The PS3 sticks have no touchpad.
        productVariants: [0x2C22 << 16 | 0x2502: "ps3", 0x0738 << 16 | 0x3384: "ps3", 0x0F0D << 16 | 0x0088: "ps3",
                          0x1532 << 16 | 0x0402: "ps3", 0x0E6F << 16 | 0x0109: "ps3",
                          // SDL rows that read L2 and R2 as axes 4 and 5, so their
                          // button bits land on the extra slots 22 and 23.
                          0x0738 << 16 | 0x8384: "ps4kicks", 0x2C22 << 16 | 0x2000: "ps4kicks",
                          0x1532 << 16 | 0x0401: "ps4kicks"]
    )

    /// The outline: a chamfered box, plus the art panel between the side
    /// wings as a second outline.
    static let arcadeStickFront: [PathOp] = [
        .move(0.032, 0.01), .line(0.968, 0.01), .line(0.99, 0.051), .line(0.99, 0.949),
        .line(0.968, 0.99), .line(0.032, 0.99), .line(0.01, 0.949), .line(0.01, 0.051), .close,
        .move(0.118, 0.171), .line(0.882, 0.171), .quad(0.888, 0.182, cx: 0.888, cy: 0.171),
        .line(0.888, 0.897), .quad(0.882, 0.908, cx: 0.888, cy: 0.908), .line(0.118, 0.908),
        .quad(0.112, 0.897, cx: 0.112, cy: 0.908), .line(0.112, 0.182), .quad(0.118, 0.171, cx: 0.112, cy: 0.171),
        .close,
    ]

    static let arcadeStickControls: [PlacedControl] = [
        // The lever: a ball top on a digital 8-way lever.
        PlacedControl(id: "lever", kind: .lever, center: CGPoint(x: 0.374, y: 0.426), size: 0.075,
                      inputs: ControlInputs(axes: [.x(0), .y(1), .x(2), .y(3)], hat: 0),
                      note: "DP mode sends the D-pad (hat 0); LS mode the left stick (axes 0 and 1); RS mode the right stick (axes 2 and 3)",
                      callout: .below),

        // Vewlix grid, top row: Square, Triangle, R1, L1 (the punches).
        PlacedControl(id: "square", kind: .faceButton, center: CGPoint(x: 0.51, y: 0.388), size: 0.062,
                      inputs: .button(2), pathInputs: [.rawDescriptor: .button(0)],
                      note: "Light punch in most fighting games", callout: .above),
        PlacedControl(id: "triangle", kind: .faceButton, center: CGPoint(x: 0.578, y: 0.334), size: 0.062,
                      inputs: .button(3),
                      note: "Medium punch in most fighting games", callout: .above),
        PlacedControl(id: "r1", kind: .faceButton, center: CGPoint(x: 0.652, y: 0.334), size: 0.062,
                      printed: "R1", inputs: .button(5),
                      note: "Heavy punch in most fighting games", callout: .above),
        PlacedControl(id: "l1", kind: .faceButton, center: CGPoint(x: 0.726, y: 0.334), size: 0.062,
                      printed: "L1", inputs: .button(4),
                      note: "Fourth punch column: all punches or a game macro", callout: .above),

        // Bottom row: Cross, Circle, R2, L2 (the kicks).
        PlacedControl(id: "cross", kind: .faceButton, center: CGPoint(x: 0.496, y: 0.534), size: 0.062,
                      inputs: .button(0), pathInputs: [.rawDescriptor: .button(1)],
                      note: "Light kick in most fighting games", callout: .below),
        PlacedControl(id: "circle", kind: .faceButton, center: CGPoint(x: 0.564, y: 0.484), size: 0.062,
                      inputs: .button(1), pathInputs: [.rawDescriptor: .button(2)],
                      note: "Medium kick in most fighting games", callout: .below),
        PlacedControl(id: "r2", kind: .faceButton, center: CGPoint(x: 0.638, y: 0.484), size: 0.062,
                      printed: "R2", inputs: ControlInputs(buttons: [7], axes: [.analog(5)]),
                      note: "Heavy kick in most fighting games",
                      callout: .below, variants: ["ps4", "ps3"]),
        PlacedControl(id: "r2.kicks", kind: .faceButton, center: CGPoint(x: 0.638, y: 0.484), size: 0.062,
                      printed: "R2", inputs: ControlInputs(buttons: [7, 23], axes: [.analog(5)]),
                      note: "Heavy kick in most fighting games. This stick's SDL row reads R2 as axis 5 and also presses btn 23",
                      callout: .below, variants: ["ps4kicks"], name: "R2"),
        PlacedControl(id: "l2", kind: .faceButton, center: CGPoint(x: 0.712, y: 0.484), size: 0.062,
                      printed: "L2", inputs: ControlInputs(buttons: [6], axes: [.analog(4)]),
                      note: "Fourth kick column: all kicks or a game macro",
                      callout: .below, variants: ["ps4", "ps3"]),
        PlacedControl(id: "l2.kicks", kind: .faceButton, center: CGPoint(x: 0.712, y: 0.484), size: 0.062,
                      printed: "L2", inputs: ControlInputs(buttons: [6, 22], axes: [.analog(4)]),
                      note: "Fourth kick column: all kicks or a game macro. This stick's SDL row reads L2 as axis 4 and also presses btn 22",
                      callout: .below, variants: ["ps4kicks"], name: "L2"),

        // Function bar along the rear of the panel, left to right as printed.
        PlacedControl(id: "ps", kind: .homeButton, center: CGPoint(x: 0.379, y: 0.113), size: 0.026,
                      inputs: .button(10), pathInputs: [.rawDescriptor: .button(12)],
                      note: "Disabled by the tournament lock on most sticks", callout: .above),
        PlacedControl(id: "l3", kind: .menuButton, center: CGPoint(x: 0.419, y: 0.113), size: 0.029, height: 0.015,
                      shape: .roundedRect(corner: 0.25), printed: "L3",
                      inputs: .button(11), pathInputs: [.rawDescriptor: .button(10)],
                      note: "On the Victrix and PDP Versus rows, which leave it out, read on b10 as in every DualShock-order stick", callout: .below),
        PlacedControl(id: "turbo", kind: .menuButton, center: CGPoint(x: 0.451, y: 0.113), size: 0.029, height: 0.015,
                      shape: .roundedRect(corner: 0.25), printed: "TB",
                      readable: .notReported("Turbo is set inside the stick: hold it and press a button to make that button repeat. It sends no input of its own"),
                      callout: .above),
        PlacedControl(id: "create", kind: .menuButton, center: CGPoint(x: 0.482, y: 0.113), size: 0.029, height: 0.015,
                      shape: .roundedRect(corner: 0.25), symbol: "square.and.arrow.up",
                      inputs: .button(8), note: "Create on PS5 sticks, Share on PS4, Select on PS3", callout: .above),
        PlacedControl(id: "mute", kind: .menuButton, center: CGPoint(x: 0.511, y: 0.113), size: 0.029, height: 0.015,
                      shape: .roundedRect(corner: 0.25), printed: "MUTE",
                      readable: .notReported("Mutes the headset jack inside the stick; no bundled SDL row reads it"),
                      callout: .below),
        PlacedControl(id: "r3", kind: .menuButton, center: CGPoint(x: 0.543, y: 0.113), size: 0.029, height: 0.015,
                      shape: .roundedRect(corner: 0.25), printed: "R3",
                      inputs: .button(12), pathInputs: [.rawDescriptor: .button(11)],
                      note: "On the Victrix and PDP Versus rows, which leave it out, read on b11 as in every DualShock-order stick", callout: .below),
        PlacedControl(id: "options", kind: .menuButton, center: CGPoint(x: 0.602, y: 0.113), size: 0.04, height: 0.021,
                      shape: .roundedRect(corner: 0.25), symbol: "line.3.horizontal",
                      inputs: .button(9), note: "Options on PS4 and PS5 sticks, Start on PS3", callout: .above),
        PlacedControl(id: "mode-switch", kind: .slider, center: CGPoint(x: 0.628, y: 0.107), size: 0.012, height: 0.022,
                      shape: .roundedRect(corner: 0.3),
                      readable: .notReported("DP, LS, RS switch: sets whether the lever sends the D-pad (hat 0), the left stick or the right stick. Its position is not reported"),
                      callout: .below),
        PlacedControl(id: "platform-switch", kind: .slider, center: CGPoint(x: 0.655, y: 0.107), size: 0.012, height: 0.022,
                      shape: .roundedRect(corner: 0.3),
                      readable: .notReported("PS5, PS4, PC switch. Only the PlayStation modes are read here; PC mode is XInput on most sticks, which macOS does not read"),
                      callout: .above),
        PlacedControl(id: "lock-switch", kind: .slider, center: CGPoint(x: 0.682, y: 0.107), size: 0.012, height: 0.022,
                      shape: .roundedRect(corner: 0.3),
                      readable: .notReported("Tournament lock: disables Create, Options, PS and the touchpad inside the stick. Not reported"),
                      callout: .below),

        // Touchpad in the rear right corner: its click is read, its touches
        // are not (no raw path parses a licensed stick's touch data).
        PlacedControl(id: "touchpad", kind: .trackpad, center: CGPoint(x: 0.797, y: 0.109), size: 0.116, height: 0.058,
                      shape: .roundedRect(corner: 0.08), inputs: ControlInputs(press: 13, surface: 0),
                      note: "Click only. Finger positions are not read. On the Qanba Drone, whose row leaves it out, read on b13 as in a DualShock 4",
                      callout: .below, variants: ["ps4", "ps4kicks"]),
    ]
}
