import Foundation
import CoreGraphics

extension ControllerLayout {
    /// Xbox Adaptive Controller (model 1835), a flat 292 by 130 by 23 mm
    /// slab laid on a table or lap, read through GameController as an Xbox
    /// extended gamepad (ControllerTypeDetector gives it brand .xbox).
    ///
    /// The front is the top surface as it lies in front of the player: two
    /// 100 mm domes fill the right two thirds (left dome A, right dome B), a
    /// D-pad sits in a round recess in the lower left, and above it a small
    /// group holds the Xbox button, View and Menu below it, then the battery
    /// light, the three profile lights and the Profile button. The top strip
    /// is the rear edge seen from above: the DC power jack and USB-C port at
    /// the left, the nineteen 3.5 mm jacks, and the pair button at the right.
    /// The USB-A ports (left and right stick devices) and the headset jack
    /// are on the two ends; they are drawn at the ends of the strip.
    ///
    /// Positions are measured from a straight-down photo of the unit
    /// (Inclusive Game Lab, Wikimedia Commons) and the jack order from a
    /// photo of its rear edge, but the photos are not calibrated drawings, so
    /// the layout stays approximate. The jack order and the upper left group
    /// are the parts most worth checking against a real unit.
    ///
    /// Inputs: the XAC sends one fixed Xbox report, so every jack and USB
    /// port reads as the standard input it stands in for, through the typed
    /// extendedGamepad read (GameControllerService.readControllerState):
    /// btn 0 to 12, axes 0/1 and 2/3 for the sticks, 4 and 5 for the
    /// triggers, hat 0 for the D-pad. Nothing in the report says which jack
    /// fired: the left dome and the A jack both send btn 0. Jacks that share
    /// an input with a built-in control are declared as overlays of it.
    static let xboxAdaptive = ControllerLayout(
        id: .xboxAdaptive,
        displayName: "Xbox Adaptive Controller",
        maker: .microsoft,
        family: .xbox,
        // No Share, touchpad, mute, paddles or Fn buttons.
        modelNames: ButtonNames.ModelNames(absent: [13, 14, 15, 16, 17, 18, 19, 20, 21]),
        aspect: 2.25,
        topStrip: 0.16,
        backStrip: 0,
        silhouette: Silhouette(front: xboxAdaptiveFrontOps, top: xboxAdaptiveTopOps),
        controls: xboxAdaptiveControls,
        // GameController names the unit "Xbox Adaptive Controller". The name
        // is matched with "Xbox" in it so PDP's One-Handed Joystick Adaptive
        // Controller (0E6F:02B6) never lands here. Raw HID fallback by
        // product ID: USB, classic Bluetooth and BLE.
        match: [
            [.brand(.xbox), .gcVendorNameContains("Xbox Adaptive")],
            [.gcProductCategoryContains("Xbox Adaptive")],
            [.vidPid(vendor: 0x045E, products: [0x0B0A, 0x0B0C, 0x0B21])],
        ],
        // Above the Xbox One (5), Series (10) and Elite (30) layouts, whose
        // element rules an XAC can also satisfy.
        matchPriority: 40,
        readability: .partial("The Profile button, profile lights and pair button never reach the Mac, and a jack reads as the same input as the built-in control it stands in for"),
        approximate: true,
        sources: [
            "commons.wikimedia.org InclusiveGameLab Xbox-Adaptive-Controller 4 CC-BY-SA 01 (straight-down photo: positions of the domes, D-pad, Xbox, View, Menu, Profile and the jack labels along the rear edge)",
            "commons.wikimedia.org InclusiveGameLab Xbox-Adaptive-Controller 4 CC-BY-SA 02 (rear edge photo: pair button, 19 jacks, USB-C, 5 V DC jack in order)",
            "commons.wikimedia.org Xbox Adaptive Controller V&A (angled photo of the upper left group)",
            "en.wikipedia.org Xbox Adaptive Controller (292 x 130 x 23 mm, 100 mm domes, USB-A and headset jack on the left end, USB-A on the right end)",
            "xbox.com Xbox Adaptive Controller product page (19 jacks, 2 USB ports, built-in Profile button, three profiles)",
            "gameaccess.info Overview of using the Xbox Adaptive Controller (X1 left joystick, X2 right joystick, sync button on the back)",
            "SDL src/joystick/controller_list.h (045E:0B0A, 0B0C, 0B21)",
        ]
    )

    /// The slab: a long rectangle with small rounded corners, plus the round
    /// recess the D-pad sits in.
    static let xboxAdaptiveFrontOps: [PathOp] = [
        .move(0.018, 0.009),
        .line(0.982, 0.009),
        .quad(0.996, 0.041, cx: 0.996, cy: 0.009),
        .line(0.996, 0.959),
        .quad(0.982, 0.991, cx: 0.996, cy: 0.991),
        .line(0.018, 0.991),
        .quad(0.004, 0.959, cx: 0.004, cy: 0.991),
        .line(0.004, 0.041),
        .quad(0.018, 0.009, cx: 0.004, cy: 0.009),
        .close,
        // D-pad recess, about 40 mm across.
        .move(0.103, 0.579),
        .curve(0.171, 0.732, c1x: 0.1406, c1y: 0.579, c2x: 0.171, c2y: 0.6475),
        .curve(0.103, 0.885, c1x: 0.171, c1y: 0.8165, c2x: 0.1406, c2y: 0.885),
        .curve(0.035, 0.732, c1x: 0.0654, c1y: 0.885, c2x: 0.035, c2y: 0.8165),
        .curve(0.103, 0.579, c1x: 0.035, c1y: 0.6475, c2x: 0.0654, c2y: 0.579),
        .close,
    ]

    /// The rear edge seen from above: a thin strip with small corners.
    static let xboxAdaptiveTopOps: [PathOp] = [
        .move(0.018, 0.03),
        .line(0.982, 0.03),
        .quad(0.996, 0.12, cx: 0.996, cy: 0.03),
        .line(0.996, 0.88),
        .quad(0.982, 0.97, cx: 0.996, cy: 0.97),
        .line(0.018, 0.97),
        .quad(0.004, 0.88, cx: 0.004, cy: 0.97),
        .line(0.004, 0.12),
        .quad(0.018, 0.03, cx: 0.004, cy: 0.03),
        .close,
    ]

    /// The rear edge's sockets left to right as the player sees them, at an
    /// even 12.6 mm pitch (x = 0.042 + i * 0.0432). Estimated order, read
    /// from the labels molded along the top surface's rear edge.
    private static func xboxAdaptiveJackX(_ i: Int) -> CGFloat { 0.042 + CGFloat(i) * 0.0432 }

    private static let sharedJackNote = "Shares its input with the built-in control; the controller does not say which one fired"

    static let xboxAdaptiveControls: [PlacedControl] = [
        // MARK: Front, upper left group (estimated placement within the group)
        PlacedControl(id: "xbox", kind: .homeButton, center: CGPoint(x: 0.103, y: 0.175), size: 0.048,
                      symbol: "logo.xbox", inputs: .button(10),
                      note: "Lights while the controller is on; also the power button", callout: .above),
        PlacedControl(id: "view", kind: .menuButton, center: CGPoint(x: 0.063, y: 0.328), size: 0.04,
                      symbol: "rectangle.on.rectangle", inputs: .button(8), callout: .above),
        PlacedControl(id: "menu", kind: .menuButton, center: CGPoint(x: 0.144, y: 0.328), size: 0.04,
                      symbol: "line.3.horizontal", inputs: .button(9), callout: .below),
        PlacedControl(id: "battery-light", kind: .light, center: CGPoint(x: 0.063, y: 0.47), size: 0.01,
                      readable: .notReported("Battery and charging light; not an input")),
        PlacedControl(id: "profile-lights", kind: .light, center: CGPoint(x: 0.103, y: 0.487), size: 0.012, height: 0.03,
                      shape: .roundedRect(corner: 0.3),
                      readable: .notReported("Three lights show the active profile; the profile is not in the report GameController reads")),
        PlacedControl(id: "profile", kind: .menuButton, center: CGPoint(x: 0.144, y: 0.487), size: 0.04, printed: "P",
                      readable: .notReported("Switches among three stored profiles inside the controller; GameController does not expose it"),
                      note: "Profile button"),

        // MARK: Front, D-pad and the two domes
        PlacedControl(id: "dpad", kind: .dpad, center: CGPoint(x: 0.103, y: 0.732), size: 0.123, shape: .crossPad,
                      inputs: .hat(0), note: "Shares hat 0 with the four D-pad jacks", callout: .below),
        PlacedControl(id: "dome-left", kind: .faceButton, center: CGPoint(x: 0.393, y: 0.503), size: 0.344,
                      inputs: .button(0), note: "100 mm dome, A by default; shares btn 0 with the A jack", callout: .below, name: "Left dome (A)"),
        PlacedControl(id: "dome-right", kind: .faceButton, center: CGPoint(x: 0.789, y: 0.5), size: 0.346,
                      inputs: .button(1), note: "100 mm dome, B by default; shares btn 1 with the B jack", callout: .below, name: "Right dome (B)"),

        // MARK: Top strip (rear edge), left to right as the player sees it
        PlacedControl(id: "dc-power", kind: .port, face: .top, center: CGPoint(x: xboxAdaptiveJackX(0), y: 0.36), size: 0.022,
                      note: "5 V 2 A power input for accessories that draw more power"),
        PlacedControl(id: "usb-c", kind: .port, face: .top, center: CGPoint(x: xboxAdaptiveJackX(1), y: 0.36), size: 0.03, height: 0.012,
                      shape: .capsule(angleDegrees: 0), note: "USB-C charging and wired connection"),
        PlacedControl(id: "jack-dpad-left", kind: .other, face: .top, center: CGPoint(x: xboxAdaptiveJackX(2), y: 0.36), size: 0.026,
                      symbol: "arrowtriangle.left.fill", inputs: ControlInputs(hat: 0, hatDirection: .left),
                      note: "D-pad left (hat 0 left). " + sharedJackNote, callout: .above, overlayOf: "dpad"),
        PlacedControl(id: "jack-dpad-down", kind: .other, face: .top, center: CGPoint(x: xboxAdaptiveJackX(3), y: 0.36), size: 0.026,
                      symbol: "arrowtriangle.down.fill", inputs: ControlInputs(hat: 0, hatDirection: .down),
                      note: "D-pad down (hat 0 down). " + sharedJackNote, callout: .below, overlayOf: "dpad"),
        PlacedControl(id: "jack-dpad-up", kind: .other, face: .top, center: CGPoint(x: xboxAdaptiveJackX(4), y: 0.36), size: 0.026,
                      symbol: "arrowtriangle.up.fill", inputs: ControlInputs(hat: 0, hatDirection: .up),
                      note: "D-pad up (hat 0 up). " + sharedJackNote, callout: .above, overlayOf: "dpad"),
        PlacedControl(id: "jack-dpad-right", kind: .other, face: .top, center: CGPoint(x: xboxAdaptiveJackX(5), y: 0.36), size: 0.026,
                      symbol: "arrowtriangle.right.fill", inputs: ControlInputs(hat: 0, hatDirection: .right),
                      note: "D-pad right (hat 0 right). " + sharedJackNote, callout: .below, overlayOf: "dpad"),
        PlacedControl(id: "jack-ls", kind: .other, face: .top, center: CGPoint(x: xboxAdaptiveJackX(6), y: 0.36), size: 0.026,
                      printed: "LS", inputs: .button(11), note: "Left stick press: a switch plugged in here is the only way to send it",
                      callout: .above, name: "LS jack"),
        PlacedControl(id: "jack-lb", kind: .other, face: .top, center: CGPoint(x: xboxAdaptiveJackX(7), y: 0.36), size: 0.026,
                      printed: "LB", inputs: .button(4), callout: .below, name: "LB jack"),
        PlacedControl(id: "jack-xbox", kind: .other, face: .top, center: CGPoint(x: xboxAdaptiveJackX(8), y: 0.36), size: 0.026,
                      symbol: "logo.xbox", inputs: .button(10), note: sharedJackNote, callout: .above, overlayOf: "xbox", name: "Xbox button jack"),
        PlacedControl(id: "jack-x1", kind: .stick, face: .top, center: CGPoint(x: xboxAdaptiveJackX(9), y: 0.36), size: 0.026,
                      printed: "X1", inputs: ControlInputs(axes: [.x(0), .y(1)]),
                      readable: .conditional("An analog joystick plugged in here reads as the left stick; a switch sends whatever the Xbox Accessories app assigns it"),
                      callout: .below, name: "X1 jack (left stick)"),
        PlacedControl(id: "jack-x2", kind: .stick, face: .top, center: CGPoint(x: xboxAdaptiveJackX(10), y: 0.36), size: 0.026,
                      printed: "X2", inputs: ControlInputs(axes: [.x(2), .y(3)]),
                      readable: .conditional("An analog joystick plugged in here reads as the right stick; a switch sends whatever the Xbox Accessories app assigns it"),
                      callout: .above, name: "X2 jack (right stick)"),
        PlacedControl(id: "jack-view", kind: .other, face: .top, center: CGPoint(x: xboxAdaptiveJackX(11), y: 0.36), size: 0.026,
                      symbol: "rectangle.on.rectangle", inputs: .button(8), note: sharedJackNote, callout: .below, overlayOf: "view", name: "View jack"),
        PlacedControl(id: "jack-menu", kind: .other, face: .top, center: CGPoint(x: xboxAdaptiveJackX(12), y: 0.36), size: 0.026,
                      symbol: "line.3.horizontal", inputs: .button(9), note: sharedJackNote, callout: .above, overlayOf: "menu", name: "Menu jack"),
        PlacedControl(id: "jack-lt", kind: .trigger(.analog), face: .top, center: CGPoint(x: xboxAdaptiveJackX(13), y: 0.36), size: 0.026,
                      printed: "LT", inputs: .trigger(axis: 4, digital: 6),
                      note: "Analog jack: a proportional accessory gives a partial pull", callout: .below, name: "LT jack"),
        PlacedControl(id: "jack-rt", kind: .trigger(.analog), face: .top, center: CGPoint(x: xboxAdaptiveJackX(14), y: 0.36), size: 0.026,
                      printed: "RT", inputs: .trigger(axis: 5, digital: 7),
                      note: "Analog jack: a proportional accessory gives a partial pull", callout: .above, name: "RT jack"),
        PlacedControl(id: "jack-rb", kind: .other, face: .top, center: CGPoint(x: xboxAdaptiveJackX(15), y: 0.36), size: 0.026,
                      printed: "RB", inputs: .button(5), callout: .below, name: "RB jack"),
        PlacedControl(id: "jack-rs", kind: .other, face: .top, center: CGPoint(x: xboxAdaptiveJackX(16), y: 0.36), size: 0.026,
                      printed: "RS", inputs: .button(12), note: "Right stick press: a switch plugged in here is the only way to send it",
                      callout: .above, name: "RS jack"),
        PlacedControl(id: "jack-a", kind: .other, face: .top, center: CGPoint(x: xboxAdaptiveJackX(17), y: 0.36), size: 0.026,
                      printed: "A", inputs: .button(0), note: sharedJackNote, callout: .below, overlayOf: "dome-left", name: "A jack"),
        PlacedControl(id: "jack-b", kind: .other, face: .top, center: CGPoint(x: xboxAdaptiveJackX(18), y: 0.36), size: 0.026,
                      printed: "B", inputs: .button(1), note: sharedJackNote, callout: .above, overlayOf: "dome-right", name: "B jack"),
        PlacedControl(id: "jack-x", kind: .other, face: .top, center: CGPoint(x: xboxAdaptiveJackX(19), y: 0.36), size: 0.026,
                      printed: "X", inputs: .button(2), callout: .below, name: "X jack"),
        PlacedControl(id: "jack-y", kind: .other, face: .top, center: CGPoint(x: xboxAdaptiveJackX(20), y: 0.36), size: 0.026,
                      printed: "Y", inputs: .button(3), callout: .above, name: "Y jack"),
        PlacedControl(id: "pair", kind: .other, face: .top, center: CGPoint(x: xboxAdaptiveJackX(21), y: 0.36), size: 0.026,
                      printed: "Pair", readable: .notReported("Pairs the controller over Xbox Wireless or Bluetooth; not an input")),

        // MARK: Top strip ends: the side ports
        PlacedControl(id: "usb-left", kind: .stick, face: .top, center: CGPoint(x: 0.03, y: 0.76), size: 0.034,
                      inputs: ControlInputs(axes: [.x(0), .y(1)]),
                      note: "USB-A port on the left end: a joystick plugged in here is the left stick", callout: .below, name: "Left USB port (left stick)"),
        PlacedControl(id: "headset", kind: .port, face: .top, center: CGPoint(x: 0.075, y: 0.76), size: 0.018,
                      note: "3.5 mm stereo headset jack on the left end"),
        PlacedControl(id: "usb-right", kind: .stick, face: .top, center: CGPoint(x: 0.97, y: 0.76), size: 0.034,
                      inputs: ControlInputs(axes: [.x(2), .y(3)]),
                      note: "USB-A port on the right end: a joystick plugged in here is the right stick", callout: .below, name: "Right USB port (right stick)"),
    ]
}
