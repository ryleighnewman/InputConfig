import Foundation
import CoreGraphics

extension ControllerLayout {
    /// Backbone One (Lightning and USB-C, 1st and 2nd generation, standard
    /// and PlayStation Edition), and the Backbone Pro as a variant. A phone
    /// cradle: two narrow grips about 42 mm wide and 105 mm tall clamp the
    /// ends of a phone held sideways. Measured from the iFixit teardown's
    /// front photo of the collapsed unit (176 mm wide collapsed), drawn here
    /// with a large phone in, about 241 mm by 105 mm.
    ///
    /// Left grip: the stick high and outboard, the cross D-pad below it, then
    /// the Options button (an ellipsis) low on the outer side and the Capture
    /// button (a corner-bracket square) a little higher on the inner side.
    /// Right grip: A B X Y high, the right stick below them, then the orange
    /// Backbone button low on the inner side and the Menu button (three
    /// lines) lower on the outer side. Bumpers on top of each grip, Hall
    /// effect triggers behind them.
    ///
    /// Inputs on the GameController path (GameControllerService
    /// readControllerState): A B X Y btn 0 to 3 by position, bumpers 4 and 5,
    /// triggers axes 4 and 5 with digital copies 6 and 7, buttonOptions 8,
    /// buttonMenu 9, buttonHome 10, stick clicks 11 and 12, sticks axes 0 to
    /// 3, D-pad hat 0. The Capture button is the profile's "Button Share"
    /// (SDL's mfi driver skips that name on a Backbone because the Backbone
    /// app claims it), which knownButtonMap puts on 14. The PlayStation
    /// Edition reports productCategory "DualSense", so the app names its
    /// buttons in the PlayStation family (face glyphs, L1, Options) with no
    /// change here; it has no touchpad, light bar or mute button.
    ///
    /// Over USB as raw HID, the bundled SDL rows for vendor 0x358A
    /// (SDLGameControllerDBData.swift:108-112) put every named control on
    /// the same slots; some rows report the triggers as plain buttons 6 and 7
    /// with no axis, and none of them names the Capture button.
    static let backboneOne = ControllerLayout(
        id: .backboneOne,
        displayName: "Backbone One",
        maker: .phoneGrip,
        family: nil,
        // The buttons as Backbone prints and names them; no touchpad, mute,
        // paddles or Fn buttons.
        modelNames: ButtonNames.ModelNames(renamed: [8: "Options", 9: "Menu", 10: "Backbone", 14: "Capture"],
                                           absent: [13, 15, 16, 17, 18, 19, 20, 21]),
        aspect: 2.3,
        topStrip: 0.14,
        // The back is only drawn for the Backbone Pro's M1 and M2. The back
        // rect is 0.76 of the width, so 0.76 / 2.3 keeps the front's shape.
        backStrip: 0.33,
        silhouette: backboneOneBody,
        controls: backboneOneControls,
        variants: [
            LayoutVariant(id: "standard", displayName: "Backbone One", isDefault: true),
            LayoutVariant(id: "playstation", displayName: "Backbone One PlayStation Edition"),
            LayoutVariant(id: "pro", displayName: "Backbone Pro"),
        ],
        match: [
            // GameController: SDL recognizes the grip by a vendorName that
            // starts "Backbone One" (SDL_mfijoystick.m IsControllerBackboneOne),
            // including the PlayStation Edition, whose productCategory says
            // DualSense; the higher priority keeps it off the DualSense layout.
            [.gcVendorNameContains("Backbone")],
            // Raw HID over USB: Backbone's vendor ID (the SDL rows' 8a35).
            [.vendor(0x358A)],
        ],
        matchPriority: 40,
        readability: .partial("Capture reads only when GameController lists the pad; read raw over USB it has no place of its own. The Backbone Pro's M1 and M2 copy other buttons"),
        approximate: true,
        sources: [
            "iFixit Backbone One Teardown (front photo of the collapsed unit; left board: D-pad, screenshot and option domes; right board: A B X Y, Backbone and option domes; Hall effect triggers)",
            "help.backbone.com How big is the Backbone One controller (176 mm collapsed, 265 mm fully extended)",
            "AppleInsider Backbone One 2nd gen review (ellipsis, square capture, hamburger menu and orange Backbone button)",
            "help.backbone.com Backbone One PlayStation Edition PS App Shortcut (Options is the ellipsis on the left)",
            "SDL src/joystick/apple/SDL_mfijoystick.m (vendorName prefix Backbone One, productCategory DualSense, Button Share)",
            "SDL gamecontrollerdb Mac OS X rows for 358a:0102, 0201, 0202, 0302 and 0402",
            "SDL src/joystick/usb_ids.h (358a:0104 Backbone One PlayStation Edition, 358a:0304 its second generation)",
        ],
        productVariants: [0x358A << 16 | 0x0104: "playstation", 0x358A << 16 | 0x0304: "playstation"]
    )

    /// Two grips with the phone between them. The grips' inner edges are
    /// straight where they clamp the phone; their bottoms hang below it. The
    /// top strip shows the grips from above with the phone and the bridge
    /// behind it; the back shows the grips and the telescoping bridge.
    static let backboneOneBody: Silhouette = {
        let leftGrip: [PathOp] = [
            .move(0.172, 0.015),
            .line(0.04, 0.015),
            .quad(0.004, 0.10, cx: 0.004, cy: 0.015),
            .curve(0.006, 0.72, c1x: 0.002, c1y: 0.35, c2x: 0.002, c2y: 0.6),
            .curve(0.085, 0.985, c1x: 0.012, c1y: 0.9, c2x: 0.045, c2y: 0.985),
            .curve(0.18, 0.80, c1x: 0.135, c1y: 0.985, c2x: 0.18, c2y: 0.9),
            .line(0.18, 0.05),
            .quad(0.172, 0.015, cx: 0.18, cy: 0.015),
            .close,
        ]
        func mirrored(_ ops: [PathOp]) -> [PathOp] {
            ops.map { op in
                switch op {
                case .move(let x, let y): return .move(1 - x, y)
                case .line(let x, let y): return .line(1 - x, y)
                case .quad(let x, let y, let cx, let cy): return .quad(1 - x, y, cx: 1 - cx, cy: cy)
                case .curve(let x, let y, let c1x, let c1y, let c2x, let c2y):
                    return .curve(1 - x, y, c1x: 1 - c1x, c1y: c1y, c2x: 1 - c2x, c2y: c2y)
                case .close: return .close
                }
            }
        }
        func rect(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, rx: CGFloat, ry: CGFloat) -> [PathOp] {
            [.move(x0 + rx, y0), .line(x1 - rx, y0), .quad(x1, y0 + ry, cx: x1, cy: y0), .line(x1, y1 - ry),
             .quad(x1 - rx, y1, cx: x1, cy: y1), .line(x0 + rx, y1), .quad(x0, y1 - ry, cx: x0, cy: y1),
             .line(x0, y0 + ry), .quad(x0 + rx, y0, cx: x0, cy: y0), .close]
        }
        let grips = leftGrip + mirrored(leftGrip)
        // The phone, centered on the passthrough connector a little above
        // the grips' middle.
        let phone = rect(0.184, 0.06, 0.816, 0.78, rx: 0.04, ry: 0.095)
        let topLeft = rect(0.006, 0.06, 0.18, 0.94, rx: 0.03, ry: 0.3)
        let top = topLeft + mirrored(topLeft) + rect(0.18, 0.3, 0.82, 0.78, rx: 0.0, ry: 0.0)
        let bridge = rect(0.18, 0.3, 0.82, 0.62, rx: 0.0, ry: 0.0)
        return Silhouette(front: grips + phone, top: top, back: grips + bridge)
    }()

    static let backboneOneControls: [PlacedControl] = [
        // Top: Hall effect triggers at the rear of each grip, bumpers in front.
        PlacedControl(id: "lt", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.135, y: 0.0622), size: 0.17, height: 0.12,
                      shape: .roundedRect(corner: 0.35), inputs: .trigger(axis: 4, digital: 6),
                      note: "Analog over GameController; some USB rows send it as a plain button", callout: .above),
        PlacedControl(id: "rt", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.865, y: 0.0622), size: 0.17, height: 0.12,
                      shape: .roundedRect(corner: 0.35), inputs: .trigger(axis: 5, digital: 7),
                      note: "Analog over GameController; some USB rows send it as a plain button", callout: .above),
        PlacedControl(id: "lb", kind: .shoulder, face: .top, center: CGPoint(x: 0.1, y: 0.74), size: 0.11, height: 0.03,
                      shape: .capsule(angleDegrees: 0), inputs: .button(4), callout: .below),
        PlacedControl(id: "rb", kind: .shoulder, face: .top, center: CGPoint(x: 0.9, y: 0.74), size: 0.11, height: 0.03,
                      shape: .capsule(angleDegrees: 0), inputs: .button(5), callout: .below),

        // Left grip: stick high and outboard, D-pad below, Options and
        // Capture near the bottom.
        PlacedControl(id: "lstick", kind: .stick, center: CGPoint(x: 0.058, y: 0.188), size: 0.068,
                      inputs: .stick(x: 0, y: 1, press: 11), callout: .below),
        PlacedControl(id: "dpad", kind: .dpad, center: CGPoint(x: 0.077, y: 0.536), size: 0.11, shape: .crossPad,
                      inputs: .hat(0), callout: .below),
        PlacedControl(id: "capture", kind: .menuButton, center: CGPoint(x: 0.125, y: 0.739), size: 0.03,
                      symbol: "viewfinder", inputs: .button(14),
                      pathInputs: [.rawSDL: .none],
                      readable: .conditional("Read when GameController lists it as Button Share; the USB SDL rows do not name it, so raw HID puts it on an extra slot from 22"),
                      note: "Records with a press and takes a screenshot with a hold in the Backbone app", callout: .below),
        PlacedControl(id: "options", kind: .menuButton, center: CGPoint(x: 0.04, y: 0.783), size: 0.03,
                      symbol: "ellipsis", inputs: .button(8), callout: .below),

        // Right grip: A B X Y high, printed in one color (PlayStation glyphs
        // on the PlayStation Edition), the right stick below them.
        PlacedControl(id: "y", kind: .faceButton, center: CGPoint(x: 0.923, y: 0.154), size: 0.033,
                      inputs: .button(3), callout: .above, variants: ["standard", "pro"]),
        PlacedControl(id: "x", kind: .faceButton, center: CGPoint(x: 0.881, y: 0.246), size: 0.033,
                      inputs: .button(2), callout: .left, variants: ["standard", "pro"]),
        PlacedControl(id: "b", kind: .faceButton, center: CGPoint(x: 0.969, y: 0.246), size: 0.033,
                      inputs: .button(1), callout: .right, variants: ["standard", "pro"]),
        PlacedControl(id: "a", kind: .faceButton, center: CGPoint(x: 0.923, y: 0.336), size: 0.033,
                      inputs: .button(0), callout: .below, variants: ["standard", "pro"]),
        PlacedControl(id: "triangle", kind: .faceButton, center: CGPoint(x: 0.923, y: 0.154), size: 0.033,
                      symbol: "triangle", inputs: .button(3), callout: .above, variants: ["playstation"], name: "Triangle"),
        PlacedControl(id: "square", kind: .faceButton, center: CGPoint(x: 0.881, y: 0.246), size: 0.033,
                      symbol: "square", inputs: .button(2), callout: .left, variants: ["playstation"], name: "Square"),
        PlacedControl(id: "circle", kind: .faceButton, center: CGPoint(x: 0.969, y: 0.246), size: 0.033,
                      symbol: "circle", inputs: .button(1), callout: .right, variants: ["playstation"], name: "Circle"),
        PlacedControl(id: "cross", kind: .faceButton, center: CGPoint(x: 0.923, y: 0.336), size: 0.033,
                      symbol: "xmark", inputs: .button(0), callout: .below, variants: ["playstation"], name: "Cross"),
        PlacedControl(id: "rstick", kind: .stick, center: CGPoint(x: 0.909, y: 0.551), size: 0.068,
                      inputs: .stick(x: 2, y: 3, press: 12), callout: .below),
        // The orange Backbone button inboard, Menu outboard and lower.
        PlacedControl(id: "backbone", kind: .homeButton, center: CGPoint(x: 0.887, y: 0.745), size: 0.03,
                      symbol: "house", inputs: .button(10),
                      readable: .conditional("Read as the Home button through GameController and over USB; on a phone the Backbone app claims it"),
                      note: "Opens the Backbone app on a phone; held, it is the PS button on the PlayStation Edition", callout: .below),
        PlacedControl(id: "menu", kind: .menuButton, center: CGPoint(x: 0.956, y: 0.797), size: 0.03,
                      symbol: "line.3.horizontal", inputs: .button(9), callout: .below),

        // Back, as held: the Backbone Pro's two back buttons where the middle
        // fingers rest. Positions are estimates.
        PlacedControl(id: "m1", kind: .paddle, face: .back, center: CGPoint(x: 0.1, y: 0.6), size: 0.03, height: 0.05,
                      shape: .capsule(angleDegrees: 0), printed: "M1",
                      readable: .conditional("Unassigned unless set in the Backbone app, and then it copies another button"),
                      note: "Backbone Pro only; sends nothing of its own", callout: .below, variants: ["pro"]),
        PlacedControl(id: "m2", kind: .paddle, face: .back, center: CGPoint(x: 0.9, y: 0.6), size: 0.03, height: 0.05,
                      shape: .capsule(angleDegrees: 0), printed: "M2",
                      readable: .conditional("Unassigned unless set in the Backbone app, and then it copies another button"),
                      note: "Backbone Pro only; sends nothing of its own", callout: .below, variants: ["pro"]),
    ]
}
