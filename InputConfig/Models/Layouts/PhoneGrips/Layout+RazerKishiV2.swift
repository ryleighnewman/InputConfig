import Foundation
import CoreGraphics

extension ControllerLayout {
    /// Razer Kishi V2 (RZ06-0418 Android, RZ06-0419 iPhone Lightning,
    /// RZ06-0511 USB-C, and the V2 Pro, which shares the body). Two grip
    /// halves on a telescoping bridge, drawn at the spread of a 6.1 inch
    /// phone (about 234 x 92 mm). Positions are measured from the line art
    /// in Razer's master guide, which matches the product photos.
    ///
    /// Read through GameController as a generic MFi pad
    /// (ControllerTypeDetector gives .mfiGeneric, so no naming family): face
    /// buttons A B X Y as btn 0 to 3 in Xbox positions, buttonOptions 8,
    /// buttonMenu 9, buttonHome 10, stick clicks 11 and 12, triggers on axes
    /// 4 and 5 with digital copies 6 and 7, the D-pad on hat 0.
    static let razerKishiV2 = ControllerLayout(
        id: .razerKishiV2,
        displayName: "Razer Kishi V2",
        maker: .phoneGrip,
        family: nil,
        aspect: 2.52,
        topStrip: 0.15,
        backStrip: 0,
        silhouette: Silhouette(front: Silhouette.symmetric(kishiV2FrontLeft),
                               top: Silhouette.symmetric(kishiV2TopLeft)),
        controls: kishiV2Controls,
        // By name only: the Kishi V2 has no GameController element of its
        // own, and the original Kishi (Gamevice built) and the Kishi Ultra
        // never say "Kishi V2". On a raw HID read the product name lands in
        // productCategory. Priority above the Xbox Series rule, which the
        // Xbox edition (Share plus an Xbox button) would otherwise take.
        match: [
            [.gcVendorNameContains("Kishi V2")],
            [.gcProductCategoryContains("Kishi V2")],
        ],
        matchPriority: 40,
        readability: .partial("L4 and R4 are remapped in Razer Nexus and never reach the Mac, and the Lightning model cannot plug into a Mac at all"),
        approximate: true,
        sources: [
            "Razer Kishi V2 Pro for Android master guide (dl.razerzone.com/master-guides/RazerKishiV2ProforAndroid), section 1 device layout",
            "razer.com Kishi V2 for Android product photos (220608-kishi-v2-android-1500x1000-1.jpg)",
            "Razer Kishi V2 support page RZ06-04180, RZ06-04190 (button list: Options, Share, Nexus, Menu, L4/R4)",
            "Razer spec sheet: 92.2 mm tall, 180.7 mm collapsed, 265.6 mm extended, 33.9 mm deep",
            "appleinsider.com Kishi V2 review (2022)",
        ]
    )

    /// The front outline's left half: from the bridge's top edge on the
    /// center line, out to the left grip, around it, and back along the
    /// bridge's bottom edge. The hump on the grip's top is the L1 and L2
    /// stack seen from the front.
    static let kishiV2FrontLeft: [PathOp] = [
        .move(0.5, 0.345),
        .line(0.2, 0.345),
        .line(0.2, 0.15),
        .quad(0.185, 0.115, cx: 0.2, cy: 0.115),
        .curve(0.1, 0.03, c1x: 0.18, c1y: 0.04, c2x: 0.14, c2y: 0.03),
        .curve(0.045, 0.12, c1x: 0.06, c1y: 0.03, c2x: 0.045, c2y: 0.07),
        .curve(0.0, 0.7, c1x: 0.02, c1y: 0.2, c2x: 0.0, c2y: 0.45),
        .curve(0.07, 0.995, c1x: 0.0, c1y: 0.9, c2x: 0.02, c2y: 0.99),
        .line(0.17, 0.995),
        .quad(0.2, 0.93, cx: 0.2, cy: 0.995),
        .line(0.2, 0.71),
        .line(0.5, 0.71),
    ]

    /// The top outline's left half: the grip's full depth, and the bridge
    /// as a thin bar at the rear (the phone rests in front of it).
    static let kishiV2TopLeft: [PathOp] = [
        .move(0.5, 0.1),
        .line(0.2, 0.1),
        .line(0.2, 0.08),
        .quad(0.17, 0.04, cx: 0.2, cy: 0.04),
        .line(0.06, 0.04),
        .curve(0.02, 0.5, c1x: 0.03, c1y: 0.04, c2x: 0.02, c2y: 0.2),
        .curve(0.07, 0.96, c1x: 0.02, c1y: 0.8, c2x: 0.03, c2y: 0.96),
        .line(0.18, 0.96),
        .quad(0.2, 0.92, cx: 0.2, cy: 0.96),
        .line(0.2, 0.38),
        .line(0.5, 0.38),
    ]

    static let kishiV2Controls: [PlacedControl] = [
        // Top: triggers at the rear, the L4 and R4 nubs on the inner corner
        // between trigger and bumper, bumpers at the front edge.
        PlacedControl(id: "l2", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.128, y: 0), size: 0.16, height: 0.11,
                      shape: .roundedRect(corner: 0.35), inputs: .trigger(axis: 4, digital: 6), callout: .above),
        PlacedControl(id: "r2", kind: .trigger(.analog), face: .top, center: CGPoint(x: 0.872, y: 0), size: 0.16, height: 0.11,
                      shape: .roundedRect(corner: 0.35), inputs: .trigger(axis: 5, digital: 7), callout: .above),
        PlacedControl(id: "l4", kind: .shoulder, face: .top, center: CGPoint(x: 0.14, y: 0.5), size: 0.024, height: 0.026,
                      shape: .roundedRect(corner: 0.3), printed: "L4",
                      readable: .notReported("Remapped in Razer Nexus: it copies another button and is not its own GameController element"),
                      callout: .right),
        PlacedControl(id: "r4", kind: .shoulder, face: .top, center: CGPoint(x: 0.86, y: 0.5), size: 0.024, height: 0.026,
                      shape: .roundedRect(corner: 0.3), printed: "R4",
                      readable: .notReported("Remapped in Razer Nexus: it copies another button and is not its own GameController element"),
                      callout: .left),
        PlacedControl(id: "l1", kind: .shoulder, face: .top, center: CGPoint(x: 0.085, y: 0.76), size: 0.08, height: 0.03,
                      shape: .capsule(angleDegrees: 0), inputs: .button(4), callout: .below),
        PlacedControl(id: "r1", kind: .shoulder, face: .top, center: CGPoint(x: 0.915, y: 0.76), size: 0.08, height: 0.03,
                      shape: .capsule(angleDegrees: 0), inputs: .button(5), callout: .below),

        // Left grip: stick on top, Options (an ellipsis) at its inner
        // lower corner, the D-pad on a round base, Share (a capture frame)
        // at the bottom inner corner.
        PlacedControl(id: "lstick", kind: .stick, center: CGPoint(x: 0.108, y: 0.262), size: 0.075,
                      inputs: .stick(x: 0, y: 1, press: 11), callout: .left),
        PlacedControl(id: "options", kind: .menuButton, center: CGPoint(x: 0.155, y: 0.381), size: 0.029,
                      symbol: "ellipsis", inputs: .button(8), callout: .right),
        PlacedControl(id: "dpad", kind: .dpad, center: CGPoint(x: 0.113, y: 0.565), size: 0.105, shape: .crossPad,
                      inputs: .hat(0), callout: .left),
        PlacedControl(id: "share", kind: .menuButton, center: CGPoint(x: 0.156, y: 0.839), size: 0.029,
                      symbol: "viewfinder", inputs: .button(14),
                      readable: .conditional("Reads as btn 14 only when GameController lists it as Button Share; Razer Nexus may claim it for screenshots"),
                      callout: .right),

        // Right grip: A B X Y (white letters on black, no color) on top,
        // the status light, the stick, then Nexus and Menu stacked at the
        // inner bottom.
        PlacedControl(id: "y", kind: .faceButton, center: CGPoint(x: 0.891, y: 0.174), size: 0.035, printed: "Y",
                      inputs: .button(3), callout: .above),
        PlacedControl(id: "x", kind: .faceButton, center: CGPoint(x: 0.856, y: 0.265), size: 0.035, printed: "X",
                      inputs: .button(2), callout: .left),
        PlacedControl(id: "b", kind: .faceButton, center: CGPoint(x: 0.928, y: 0.265), size: 0.035, printed: "B",
                      inputs: .button(1), callout: .right),
        PlacedControl(id: "a", kind: .faceButton, center: CGPoint(x: 0.891, y: 0.354), size: 0.035, printed: "A",
                      inputs: .button(0), callout: .below),
        PlacedControl(id: "status", kind: .light, center: CGPoint(x: 0.937, y: 0.427), size: 0.012,
                      readable: .notReported("Status light for power and connection; macOS cannot read or set it"),
                      callout: .right),
        PlacedControl(id: "rstick", kind: .stick, center: CGPoint(x: 0.891, y: 0.565), size: 0.075,
                      inputs: .stick(x: 2, y: 3, press: 12), callout: .right),
        PlacedControl(id: "nexus", kind: .homeButton, center: CGPoint(x: 0.864, y: 0.725), size: 0.029,
                      symbol: "arrow.right.circle", inputs: .button(10),
                      readable: .conditional("Reads as btn 10 only when GameController reports it as buttonHome; on a phone it opens Razer Nexus. The Xbox edition has an Xbox button here"),
                      callout: .left),
        PlacedControl(id: "menu", kind: .menuButton, center: CGPoint(x: 0.854, y: 0.839), size: 0.029,
                      symbol: "line.3.horizontal", inputs: .button(9), callout: .left),
    ]
}
