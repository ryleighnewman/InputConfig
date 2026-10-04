import Foundation
import CoreGraphics
import IOKit.hid

extension ControllerLayout {
    /// Unrecognized controller: a raw HID device no catalog model matches.
    /// It is not a body. Drawing an Xbox or PlayStation outline for a pad we
    /// know nothing about put controls where the hardware has none, so this
    /// layout is a neutral, labeled grid built from what the device's own
    /// read plan says it sends:
    /// - each complete stick pair (axes 0 and 1, axes 2 and 3) as a small stick
    /// - each hat, and each D-pad sent as buttons or axis halves, as a D-pad
    /// - every other axis as a bar named by its HID usage (Z, Rz, Slider,
    ///   Throttle, ...), bipolar or 0 to 1 as the decoder scales it
    /// - every button as a numbered key, inspector line "Button N (HID
    ///   button M)" where M is the Button page usage the descriptor gives
    ///   that bit (N + 1 when the descriptor is not at hand)
    ///
    /// The indices are the ones HIDReportDecoder.decodeGeneric writes:
    /// Button.index into buttons, Axis.index into axes, Hat.index and
    /// DpadButton.hatIndex into hats. HIDDescriptorParser.buildLayout
    /// numbers a descriptor read (Button page in bit order, then Consumer
    /// and Generic Desktop buttons from 8; axes 0 and 1 X and Y, 2 and 3
    /// the right stick, 4 and 5 triggers, 6 and up the rest), and
    /// SDLGameControllerDB.layout numbers an SDL read (standard slots,
    /// unmapped controls on the extra slots). Both reach this file as a
    /// HIDExtendedLayout, so one generator covers them, plus the bit by
    /// bit fallback for a device connected by hand with no usable
    /// descriptor.
    ///
    /// `unrecognizedHID` is the catalog entry: the same grid for a typical
    /// unknown pad (two sticks, one hat, twelve buttons), drawn when a group
    /// names this model with nothing connected. A connected device gets
    /// `generatedUnrecognizedHID(for:)`. No match rules: it is the fallback
    /// when nothing else matches. It is the one canvas that may later let a
    /// user drag controls into place, keyed by VID:PID, since there is no
    /// real outline to be true to.
    static let unrecognizedHID = unrecognizedHIDGrid(UnrecognizedHIDInventory.typicalPad)

    // MARK: - Generator

    /// The grid for a connected raw HID pad, from its profile's read plan and
    /// its report descriptor (for the HID usage of each button).
    static func generatedUnrecognizedHID(for pad: RawHIDGamepad) -> ControllerLayout {
        guard let profile = pad.profile else { return unrecognizedHID }
        let descriptor = IOHIDDeviceGetProperty(pad.device, kIOHIDReportDescriptorKey as CFString) as? Data
        return generatedUnrecognizedHID(profile: profile, descriptor: descriptor)
    }

    /// The grid for a raw HID profile. A hand coded report layout (XInput,
    /// DualShock 3, Switch 2) has its own catalog model, so only a generic
    /// layout is drawn this way; anything else gets the typical grid.
    static func generatedUnrecognizedHID(profile: ControllerProfile, descriptor: Data?) -> ControllerLayout {
        guard case .generic(let generic) = profile.layout else { return unrecognizedHID }
        let plan = HIDExtendedLayoutRegistry.extended(for: generic)
        let source: UnrecognizedHIDInventory.Source
        if profile.identifier.hasPrefix("sdl-") {
            source = .sdl
        } else if profile.identifier.hasPrefix("raw-hid-") {
            source = .bitField
        } else {
            source = .descriptor
        }
        return unrecognizedHIDGrid(UnrecognizedHIDInventory(plan: plan, descriptor: descriptor, source: source))
    }

    /// What an unrecognized device sends, in InputConfig's slots.
    struct UnrecognizedHIDInventory: Sendable {
        enum Source: Sendable { case descriptor, sdl, bitField }

        struct Axis: Sendable {
            var index: Int
            var usagePage: Int
            var usage: Int
            var unipolar: Bool
            var digitalButton: Int?
        }

        struct Button: Sendable {
            var index: Int
            /// The inspector line ("Button 3 (HID button 4)").
            var label: String
        }

        struct Hat: Sendable {
            var index: Int
            var note: String
        }

        var source: Source
        var buttons: [Button]
        var axes: [Axis]
        var hats: [Hat]

        /// A typical unknown DirectInput pad, for the catalog entry.
        static let typicalPad = UnrecognizedHIDInventory(
            source: .descriptor,
            buttons: (0..<12).map { Button(index: $0, label: "Button \($0) (HID button \($0 + 1))") },
            axes: [
                Axis(index: 0, usagePage: 0x01, usage: 0x30, unipolar: false, digitalButton: nil),
                Axis(index: 1, usagePage: 0x01, usage: 0x31, unipolar: false, digitalButton: nil),
                Axis(index: 2, usagePage: 0x01, usage: 0x32, unipolar: false, digitalButton: nil),
                Axis(index: 3, usagePage: 0x01, usage: 0x35, unipolar: false, digitalButton: nil),
            ],
            hats: [Hat(index: 0, note: "Hat switch 0, 8 directions")]
        )

        init(source: Source, buttons: [Button], axes: [Axis], hats: [Hat]) {
            self.source = source
            self.buttons = buttons
            self.axes = axes
            self.hats = hats
        }

        /// From a read plan. The descriptor, when given, names each button
        /// by the usage its bit carries; the plan itself keeps only bit
        /// offsets for buttons.
        init(plan: HIDExtendedLayout, descriptor: Data?, source: Source) {
            self.source = source
            var usageAt: [String: (page: Int, usage: Int)] = [:]
            func key(_ report: Int?, _ bit: Int) -> String { "\(report ?? -1):\(bit)" }
            if source != .bitField, let descriptor, let elements = HIDDescriptorParser.sdlElements(descriptor) {
                for b in elements.buttons { usageAt[key(b.reportID, b.bitOffset)] = (b.usagePage, b.usage) }
            }

            var buttons: [Int: Button] = [:]
            var axes: [Int: Axis] = [:]
            var hats: [Int: Hat] = [:]
            for report in plan.reports {
                for b in report.buttons where buttons[b.index] == nil {
                    let label: String
                    switch source {
                    case .bitField:
                        label = "Bit \(b.bitOffset) of the report"
                    case .descriptor, .sdl:
                        if let u = usageAt[key(report.reportID, b.bitOffset)] {
                            label = "Button \(b.index) (\(UnrecognizedHIDInventory.buttonUsageName(page: u.page, usage: u.usage)))"
                        } else if source == .descriptor {
                            label = "Button \(b.index) (HID button \(b.index + 1))"
                        } else {
                            label = "Button \(b.index)"
                        }
                    }
                    buttons[b.index] = Button(index: b.index, label: label)
                }
                for a in report.axes where axes[a.index] == nil {
                    axes[a.index] = Axis(index: a.index, usagePage: a.usagePage, usage: a.usage,
                                         unipolar: a.unipolar, digitalButton: a.digitalButton)
                }
                for h in report.hats where hats[h.index] == nil {
                    hats[h.index] = Hat(index: h.index, note: "Hat switch \(h.index), \(h.directions) directions")
                }
                for d in report.dpadButtons where hats[d.hatIndex] == nil {
                    let how = d.axisHalf == nil ? "four buttons" : "two axes"
                    hats[d.hatIndex] = Hat(index: d.hatIndex, note: "D-pad sent as \(how), read as hat \(d.hatIndex)")
                }
            }
            self.buttons = buttons.values.sorted { $0.index < $1.index }
            self.axes = axes.values.sorted { $0.index < $1.index }
            self.hats = hats.values.sorted { $0.index < $1.index }
        }

        static func buttonUsageName(page: Int, usage: Int) -> String {
            switch page {
            case 0x09:
                return "HID button \(usage)"
            case 0x0C:
                switch usage {
                case 0x223: return "Consumer Home"
                case 0x224: return "Consumer Back"
                case 0x40: return "Consumer Menu"
                default: return String(format: "Consumer 0x%X", usage)
                }
            case 0x01:
                switch usage {
                case 0x3D: return "HID Start"
                case 0x3E: return "HID Select"
                case 0x85: return "HID System Main Menu"
                case 0x90: return "HID D-pad up"
                case 0x91: return "HID D-pad down"
                case 0x92: return "HID D-pad right"
                case 0x93: return "HID D-pad left"
                default: return String(format: "Generic Desktop 0x%X", usage)
                }
            default:
                return String(format: "page 0x%X usage 0x%X", page, usage)
            }
        }

        /// An axis's HID usage: the full name and a legend of at most four
        /// characters.
        static func axisUsageName(page: Int, usage: Int) -> (name: String, short: String) {
            switch (page, usage) {
            case (0x01, 0x30): return ("X", "X")
            case (0x01, 0x31): return ("Y", "Y")
            case (0x01, 0x32): return ("Z", "Z")
            case (0x01, 0x33): return ("Rx", "Rx")
            case (0x01, 0x34): return ("Ry", "Ry")
            case (0x01, 0x35): return ("Rz", "Rz")
            case (0x01, 0x36): return ("Slider", "Sldr")
            case (0x01, 0x37): return ("Dial", "Dial")
            case (0x01, 0x38): return ("Wheel", "Whl")
            case (0x02, 0xBA): return ("Rudder", "Rudr")
            case (0x02, 0xBB): return ("Throttle", "Thr")
            case (0x02, 0xC4): return ("Accelerator", "Gas")
            case (0x02, 0xC5): return ("Brake", "Brk")
            case (0x02, 0xC8): return ("Steering", "Str")
            default: return ("axis", "Axis")
            }
        }
    }

    /// Most keys drawn; the rest are listed off the body.
    private static let unrecognizedHIDMaxKeys = 128

    /// Lays the inventory out on one plain panel: sticks, D-pads and axis
    /// bars in rows across the middle, then the numbered keys in columns
    /// down both edges (even indexes left, odd right), so each key has its own level
    /// line to the Live Visualizer's key. Past 32 keys each edge has two
    /// columns, the inner one half a row lower so its lines pass between
    /// the outer keys. Positions are worked out in units of the face's
    /// width and divided by its height at the end, so each control keeps
    /// its size whatever the row count.
    static func unrecognizedHIDGrid(_ inv: UnrecognizedHIDInventory) -> ControllerLayout {
        var controls: [PlacedControl] = []
        var y: CGFloat = 0.035

        // Sticks: a pair only when both of its axes are there.
        let axisByIndex = Dictionary(inv.axes.map { ($0.index, $0) }, uniquingKeysWith: { a, _ in a })
        var stickAxes = Set<Int>()
        var sticks: [(x: UnrecognizedHIDInventory.Axis, y: UnrecognizedHIDInventory.Axis)] = []
        for (xi, yi) in [(0, 1), (2, 3)] {
            if let ax = axisByIndex[xi], let ay = axisByIndex[yi], !ax.unipolar, !ay.unipolar {
                sticks.append((x: ax, y: ay))
                stickAxes.formUnion([xi, yi])
            }
        }
        let bars = inv.axes.filter { !stickAxes.contains($0.index) }
        let buttonIndices = Set(inv.buttons.map(\.index))

        // Row band 1: sticks and D-pads, five to a row.
        var roundControls: [PlacedControl] = []
        for s in sticks {
            let nx = UnrecognizedHIDInventory.axisUsageName(page: s.x.usagePage, usage: s.x.usage).name
            let ny = UnrecognizedHIDInventory.axisUsageName(page: s.y.usagePage, usage: s.y.usage).name
            roundControls.append(PlacedControl(id: "stick.\(s.x.index)", kind: .stick, center: CGPoint(x: 0, y: 0), size: 0.1,
                                       inputs: .stick(x: s.x.index, y: s.y.index, press: nil),
                                       note: "Stick: axes \(s.x.index) and \(s.y.index) (HID \(nx) and \(ny)); a click, if any, is one of the keys",
                                       callout: .below))
        }
        for h in inv.hats {
            roundControls.append(PlacedControl(id: "hat.\(h.index)", kind: .dpad, center: CGPoint(x: 0, y: 0), size: 0.1, shape: .crossPad,
                                       inputs: .hat(h.index), note: h.note, callout: .below))
        }
        if !roundControls.isEmpty {
            let perRow = 3, pitch: CGFloat = 0.17, size: CGFloat = 0.1, rowH: CGFloat = 0.155
            for start in stride(from: 0, to: roundControls.count, by: perRow) {
                let row = Array(roundControls[start..<min(start + perRow, roundControls.count)])
                let x0 = 0.5 - CGFloat(row.count - 1) * pitch / 2
                for (n, placed) in row.enumerated() {
                    var c = placed
                    c.center = CGPoint(x: x0 + CGFloat(n) * pitch, y: y + size / 2)
                    controls.append(c)
                }
                y += rowH
            }
        }

        // Row band 2: every other axis as a bar named by its usage.
        if !bars.isEmpty {
            let perRow = 6, pitch: CGFloat = 0.088, width: CGFloat = 0.034, barHeight: CGFloat = 0.1, rowH: CGFloat = 0.155
            for start in stride(from: 0, to: bars.count, by: perRow) {
                let row = Array(bars[start..<min(start + perRow, bars.count)])
                let x0 = 0.5 - CGFloat(row.count - 1) * pitch / 2
                for (n, a) in row.enumerated() {
                    let name = UnrecognizedHIDInventory.axisUsageName(page: a.usagePage, usage: a.usage)
                    // A mirror button only where no real button sits on it.
                    let mirror = a.digitalButton.flatMap { buttonIndices.contains($0) ? nil : $0 }
                    var inputs = ControlInputs(axes: [a.unipolar ? AxisRef.analog(a.index) : AxisRef.x(a.index)])
                    inputs.digitalCopy = mirror
                    var note = "Axis \(a.index): HID \(name.name), " + (a.unipolar ? "0 to 1" : "-1 to 1")
                    if let mirror { note += "; also presses btn \(mirror) past 12 percent" }
                    controls.append(PlacedControl(id: "axis.\(a.index)", kind: .slider,
                                                  center: CGPoint(x: x0 + CGFloat(n) * pitch, y: y + barHeight / 2),
                                                  size: width, height: barHeight, shape: .roundedRect(corner: 0.3),
                                                  printed: name.short, inputs: inputs, note: note, callout: .below))
                }
                y += rowH
            }
        }

        // The buttons as numbered keys, in index order, down both edges,
        // below the sticks and bars so every line to the key runs level.
        let drawn = Array(inv.buttons.prefix(unrecognizedHIDMaxKeys))
        let keysTop = y
        var keysBottom: CGFloat = 0
        if !drawn.isEmpty {
            let size: CGFloat = 0.05, rowH: CGFloat = 0.075
            let double = drawn.count > 32
            for (n, b) in drawn.enumerated() {
                let left = n % 2 == 0
                let inner = double && (n / 2) % 2 == 1
                let row = double ? CGFloat(n / 4) + (inner ? 0.5 : 0) : CGFloat(n / 2)
                let x: CGFloat = inner ? 0.13 : 0.045
                let cy = keysTop + row * rowH + size / 2
                keysBottom = max(keysBottom, cy + size / 2)
                controls.append(PlacedControl(id: "btn.\(b.index)", kind: .key,
                                              center: CGPoint(x: left ? x : 1 - x, y: cy),
                                              size: size, shape: .roundedRect(corner: 0.25),
                                              printed: "\(b.index)", inputs: .button(b.index),
                                              note: b.label, callout: left ? .left : .right))
            }
        }
        y = max(y, keysBottom) + 0.015

        // A short device still gets a panel that reads as one: at most
        // about 3.5 times as wide as tall, content centered in it.
        let height = max(y, 0.28)
        let shift = (height - y) / 2
        for i in controls.indices {
            controls[i].center = CGPoint(x: controls[i].center.x, y: (controls[i].center.y + shift) / height)
        }

        let offBody = inv.buttons.dropFirst(unrecognizedHIDMaxKeys).map {
            OffBodyInput(serialized: "btn \($0.index)", reason: "\($0.label): past the \(unrecognizedHIDMaxKeys) keys the grid draws")
        }

        let readability: ModelReadability
        switch inv.source {
        case .bitField:
            readability = .partial("No usable descriptor: the report is read bit by bit, so each key is one bit, not a known button")
        case .descriptor, .sdl:
            readability = .full
        }

        return ControllerLayout(
            id: .unrecognizedHID,
            displayName: "Unrecognized controller",
            maker: .generic,
            family: nil,
            aspect: 1 / height,
            topStrip: 0,
            backStrip: 0,
            // A plain panel, not a controller outline.
            silhouette: Silhouette(front: Silhouette.roundedRectOps(corner: 0.03, inset: 0.01)),
            controls: controls,
            offBody: Array(offBody),
            readability: readability,
            sources: [
                "USB HID Usage Tables 1.5 (usb.org): Generic Desktop axes and hat switch, Simulation Controls, Button and Consumer pages",
                "HIDDescriptorParser.buildLayout and SDLGameControllerDB.layout: the slots each read path assigns",
                "HIDReportDecoder.decodeGeneric: buttons, axes and hats written by index",
            ]
        )
    }
}
