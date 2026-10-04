import Foundation
import CoreGraphics

extension ControllerLayout {
    /// PlayStation DualSense (CFI-ZCT1), read through GameController. The
    /// reference layout: the others follow its conventions.
    static let dualSense = ControllerLayout(
        id: .dualSense,
        displayName: "DualSense",
        maker: .sony,
        family: .playstation,
        modelNames: ButtonNames.ModelNames(absent: [16, 17, 20, 21]),
        aspect: 1.5,
        topStrip: 0.2,
        silhouette: .gamepad(gripLength: 0.36, waist: 0.66, shoulder: 0.35, gripWidth: 0.21, flare: 0.01, topDip: 0.0),
        touchSurfaces: [
            TouchSurfaceSpec(surface: 0, controlID: "touchpad", name: "Touchpad", outline: .dualSenseFlare,
                             aspect: 1920.0 / 1080.0, maxFingers: 2, pressIndex: 13),
        ],
        controls: dualSenseCore,
        match: [[.brand(.dualSense), .gcLacksElement("Left Paddle")], [.vidPid(vendor: 0x054C, products: [0x0CE6])]],
        matchPriority: 10,
        sources: ["playstation.com DualSense product page", "SDL src/joystick/hidapi/SDL_hidapi_ps5.c"]
    )

    /// The DualSense's controls, shared with the Edge.
    static let dualSenseCore: [PlacedControl] = [
        // Top: bumpers nearest the front, triggers behind them.
        PlacedControl(id: "l2", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.2, y: 0.175), size: 0.16, height: 0.13,
                      shape: .roundedRect(corner: 0.35), inputs: .trigger(axis: 4, digital: 6), callout: .above),
        PlacedControl(id: "r2", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.8, y: 0.175), size: 0.16, height: 0.13,
                      shape: .roundedRect(corner: 0.35), inputs: .trigger(axis: 5, digital: 7), callout: .above),
        PlacedControl(id: "l1", kind: .shoulder, face: .top, center: CGPoint(x: 0.2, y: 0.75), size: 0.16, height: 0.045,
                      shape: .capsule(angleDegrees: 0), inputs: .button(4), callout: .below),
        PlacedControl(id: "r1", kind: .shoulder, face: .top, center: CGPoint(x: 0.8, y: 0.75), size: 0.16, height: 0.045,
                      shape: .capsule(angleDegrees: 0), inputs: .button(5), callout: .below),
        // Front, upper band: Create, touchpad (with its light bar), Options.
        PlacedControl(id: "create", kind: .menuButton, center: CGPoint(x: 0.25, y: 0.13), size: 0.035, height: 0.05,
                      shape: .capsule(angleDegrees: 0), symbol: "square.and.arrow.up", inputs: .button(8), callout: .left),
        PlacedControl(id: "touchpad", kind: .trackpad, center: CGPoint(x: 0.5, y: 0.2), size: 0.34, height: 0.14,
                      shape: .roundedRect(corner: 0.15), inputs: ControlInputs(press: 13, surface: 0), callout: .above),
        // The light bar shows along both sides of the touchpad.
        PlacedControl(id: "lightbar.left", kind: .light, center: CGPoint(x: 0.3235, y: 0.2), size: 0.011, height: 0.12,
                      shape: .capsule(angleDegrees: 0), note: "Light bar, output only: shows the preset's light color"),
        PlacedControl(id: "lightbar.right", kind: .light, center: CGPoint(x: 0.6765, y: 0.2), size: 0.011, height: 0.12,
                      shape: .capsule(angleDegrees: 0), note: "Light bar, output only: shows the preset's light color"),
        PlacedControl(id: "options", kind: .menuButton, center: CGPoint(x: 0.75, y: 0.13), size: 0.035, height: 0.05,
                      shape: .capsule(angleDegrees: 0), symbol: "line.3.horizontal", inputs: .button(9), callout: .right),
        // Left wing: the four separate arrows.
        PlacedControl(id: "dpad", kind: .dpad, center: CGPoint(x: 0.2, y: 0.34), size: 0.15, shape: .crossPad,
                      inputs: .hat(0), callout: .below),
        // Right wing: the face buttons.
        PlacedControl(id: "triangle", kind: .faceButton, center: CGPoint(x: 0.8, y: 0.235), size: 0.058, tint: .psGreen,
                      inputs: .button(3), callout: .above),
        PlacedControl(id: "square", kind: .faceButton, center: CGPoint(x: 0.733, y: 0.34), size: 0.058, tint: .psPink,
                      inputs: .button(2), callout: .left),
        PlacedControl(id: "circle", kind: .faceButton, center: CGPoint(x: 0.867, y: 0.34), size: 0.058, tint: .psRed,
                      inputs: .button(1), callout: .right),
        PlacedControl(id: "cross", kind: .faceButton, center: CGPoint(x: 0.8, y: 0.445), size: 0.058, tint: .psBlue,
                      inputs: .button(0), callout: .below),
        // Center: sticks, PS button between them, mute below.
        PlacedControl(id: "lstick", kind: .stick, center: CGPoint(x: 0.355, y: 0.56), size: 0.12,
                      inputs: .stick(x: 0, y: 1, press: 11), callout: .below),
        PlacedControl(id: "rstick", kind: .stick, center: CGPoint(x: 0.645, y: 0.56), size: 0.12,
                      inputs: .stick(x: 2, y: 3, press: 12), callout: .below),
        PlacedControl(id: "ps", kind: .homeButton, center: CGPoint(x: 0.5, y: 0.53), size: 0.05,
                      inputs: .button(10), note: "macOS opens Launchpad on the PS button unless a preset uses it", callout: .above),
        PlacedControl(id: "mute", kind: .menuButton, center: CGPoint(x: 0.5, y: 0.64), size: 0.055, height: 0.022,
                      shape: .capsule(angleDegrees: 0), symbol: "mic.slash", inputs: .button(15),
                      pathInputs: [.rawSDL: .button(14)], callout: .below, name: "Mute"),
    ]
}
