import SwiftUI

/// What a control shows on the canvas: the legend the layout prints, or the
/// family's name for its input (ButtonNames), with PlayStation's face glyphs
/// as symbols and compass letters under Positions.
enum CanvasLegend {
    static func legend(for c: PlacedControl, in layout: ControllerLayout,
                       family: FaceLetters?, model: ButtonNames.ModelNames,
                       choice: FaceLetters = FaceLetters.current) -> (text: String?, symbol: String?) {
        if let symbol = c.symbol { return (nil, symbol) }
        // Compass letters on the face buttons of every pad under Positions.
        // Not on a button the model renames: its index is not where the
        // standard compass puts it (a single Joy-Con, an N64 pad).
        if choice == .positions, c.kind == .faceButton, let b = c.inputs.buttons.first, model.renamed[b] == nil,
           let compass = ButtonNames.positionName(b, family: family) {
            return (String(compass.prefix(1)), nil)
        }
        // An Xbox-style pad under the Nintendo or PlayStation face letters
        // (many 8BitDo pads report as Xbox pads but print B on the bottom):
        // the letters the setting gives, as the rows and VoiceOver say them.
        if c.kind == .faceButton, family == .xbox, choice == .nintendo || choice == .playstation,
           let b = c.inputs.buttons.first, (0...3).contains(b) {
            if choice == .playstation { return (nil, ["xmark", "circle", "square", "triangle"][b]) }
            return (ButtonNames.label(b, family: family, model: model, choice: choice), nil)
        }
        if let printed = c.printed { return (printed, nil) }
        switch c.kind {
        case .faceButton:
            guard let b = c.inputs.buttons.first else { return (nil, nil) }
            if family == .playstation {
                switch b {
                case 0: return (nil, "xmark")
                case 1: return (nil, "circle")
                case 2: return (nil, "square")
                case 3: return (nil, "triangle")
                default: break
                }
            }
            let name = ButtonNames.label(b, family: family, model: model, choice: choice)
            return (name.count <= 3 ? name : String(name.prefix(1)), nil)
        case .shoulder, .menuButton, .homeButton:
            guard let b = c.inputs.buttons.first else { return (nil, nil) }
            if family != .steamController, (4...10).contains(b), let s = ButtonNames.short(b, family: family, model: model) {
                return (s, nil)
            }
            return (ButtonNames.label(b, family: family, model: model, choice: choice), nil)
        case .trigger:
            if let digital = c.inputs.digitalCopy, (6...7).contains(digital), family != .steamController,
               let s = ButtonNames.short(digital, family: family, model: model) {
                return (s, nil)
            }
            if let b = c.inputs.buttons.first, (6...7).contains(b), let s = ButtonNames.short(b, family: family, model: model) {
                return (s, nil)
            }
            if let a = c.inputs.axes.first?.index { return (a == 4 ? "LT" : (a == 5 ? "RT" : nil), nil) }
            return (nil, nil)
        case .paddle, .gripButton:
            guard let b = c.inputs.buttons.first else { return (nil, nil) }
            return (ButtonNames.label(b, family: family, model: model, choice: choice), nil)
        default:
            return (nil, nil)
        }
    }

    /// A layout id in words, for a control with no other name:
    /// "lgripTouch" is "Left grip touch", "usb-c" "USB-C", "player-leds"
    /// "Player LEDs".
    static func words(_ id: String) -> String {
        var raw = id
        // "lgripTouch", "rpadClick": a side letter run into a camel-case word.
        if let first = raw.first, first == "l" || first == "r", raw.dropFirst().first?.isLowercase == true,
           raw.contains(where: \.isUppercase), !raw.contains("-") {
            raw = (first == "l" ? "left-" : "right-") + raw.dropFirst()
        }
        var spaced = ""
        for ch in raw {
            if ch == "-" || ch == "_" || ch == "." { spaced.append(" "); continue }
            if ch.isUppercase, let last = spaced.last, last != " " { spaced.append(" ") }
            spaced.append(contentsOf: String(ch).lowercased())
        }
        let acronyms: [String: String] = ["usb": "USB", "usbc": "USB-C", "led": "LED", "leds": "LEDs", "nfc": "NFC",
                                          "ir": "IR", "dc": "DC", "ps": "PS", "fn": "Fn"]
        var tokens = spaced.split(separator: " ").map(String.init)
        // "usb c" is one word.
        if let i = tokens.firstIndex(of: "usb"), i + 1 < tokens.count, tokens[i + 1] == "c" {
            tokens.replaceSubrange(i...(i + 1), with: ["usbc"])
        }
        tokens = tokens.map { acronyms[$0] ?? $0 }
        guard let head = tokens.first else { return id }
        tokens[0] = head.prefix(1).uppercased() + head.dropFirst()
        return tokens.joined(separator: " ")
    }
}

#if DEBUG
/// Renders every catalog layout to PNG files (light and dark, idle and with
/// every control pressed) for layout review without a screen recording.
@MainActor
enum LayoutSnapshots {
    /// `post inputconfig.debug.layoutshots [model-id]` writes PNGs to the
    /// app's tmp/layout-shots folder.
    static func installHook() {
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("inputconfig.debug.layoutshots"),
                                                            object: nil, queue: .main) { note in
            let only = note.object as? String
            MainActor.assumeIsolated {
                let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("layout-shots")
                let names = renderAll(to: dir, only: only)
                try? names.joined(separator: "\n").write(to: dir.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
            }
        }
    }

    static func renderAll(to dir: URL, only: String? = nil) -> [String] {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var written: [String] = []
        for layout in ControllerLayoutCatalog.all where layout.isComplete && (only == nil || layout.id.rawValue == only) {
            for dark in [false, true] {
                for pressed in [false, true] {
                    var state = ControllerState()
                    if pressed {
                        for c in layout.controls {
                            for b in c.inputs.allButtons { state.buttons[b] = 1 }
                            for a in c.inputs.axes { state.axes[a.index] = a.role == .analog ? 0.7 : 0.5 }
                            if let h = c.inputs.hat { state.hats[h] = (1, 1) }
                        }
                    }
                    let canvas = ControllerCanvas(
                        layout: layout, state: state,
                        legend: { CanvasLegend.legend(for: $0, in: layout, family: layout.family, model: layout.modelNames, choice: .automatic) },
                        // A caption as long as a typical bound action, so
                        // crowding shows the way it does in the app.
                        caption: { c in c.kind == .port || c.kind == .light ? nil : "Left click" },
                        lightColor: .blue,
                        threshold: { _ in 0.25 },
                        inspect: { _, v in v })
                    let view = VStack(alignment: .leading, spacing: 6) {
                        Text("\(layout.displayName)  \(layout.id.rawValue)\(layout.approximate ? "  approximate" : "")")
                            .font(.system(size: 12, weight: .semibold))
                        canvas.frame(width: 640)
                    }
                    .padding(18)
                    .background(dark ? Color(white: 0.13) : Color(white: 0.96))
                    .environment(\.colorScheme, dark ? .dark : .light)
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 1.5
                    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                          let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:])
                    else { continue }
                    let name = "\(layout.id.rawValue)\(dark ? "-dark" : "")\(pressed ? "-pressed" : "").png"
                    let url = dir.appendingPathComponent(name)
                    try? png.write(to: url)
                    written.append(name)
                }
            }
        }
        // Every other variant too, dark and idle, for a look at each (the
        // key checker in KeyLayoutTests covers them all as well).
        for layout in ControllerLayoutCatalog.all where layout.isComplete && (only == nil || layout.id.rawValue == only) {
            for v in layout.variants where v.id != layout.defaultVariant {
                let canvas = ControllerCanvas(
                    layout: layout, variant: v.id, state: ControllerState(),
                    legend: { CanvasLegend.legend(for: $0, in: layout, family: layout.family, model: layout.modelNames, choice: .automatic) },
                    caption: { c in c.kind == .port || c.kind == .light ? nil : "Left click" },
                    lightColor: .blue,
                    threshold: { _ in 0.25 },
                    inspect: { _, v in v })
                let view = VStack(alignment: .leading, spacing: 6) {
                    Text("\(layout.displayName)  \(layout.id.rawValue).\(v.id)  \(v.displayName)")
                        .font(.system(size: 12, weight: .semibold))
                    canvas.frame(width: 640)
                }
                .padding(18)
                .background(Color(white: 0.13))
                .environment(\.colorScheme, .dark)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 1.5
                guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:])
                else { continue }
                let name = "variant-\(layout.id.rawValue).\(v.id).png"
                try? png.write(to: dir.appendingPathComponent(name))
                written.append(name)
            }
        }
        // Each drawing with captions as long as a real preset's, different
        // on each control, the way a busy preset fills the key.
        let actions = ["Aim down sights (right click)", "Fire (left click)", "Weapon slot 4", "Middle click (ping or melee)",
                       "Scoreboard (Tab)", "Menu (Escape)", "Next weapon (scroll up) +3", "Reload (R)", "Crouch (C)",
                       "Jump (Space)", "Strafe left (A) +4", "Look left +4", "Mission Control", "Command Shift Tab"]
        for layout in ControllerLayoutCatalog.all where layout.isComplete && (only == nil || layout.id.rawValue == only) {
            var byID: [String: String] = [:]
            for (n, c) in layout.controls.enumerated() { byID[c.id] = actions[n % actions.count] }
            let canvas = ControllerCanvas(
                layout: layout, state: ControllerState(),
                legend: { CanvasLegend.legend(for: $0, in: layout, family: layout.family, model: layout.modelNames, choice: .automatic) },
                caption: { c in c.kind == .port || c.kind == .light ? nil : byID[c.id] },
                lightColor: .white,
                threshold: { _ in 0.25 },
                inspect: { _, v in v })
            let view = VStack(alignment: .leading, spacing: 6) {
                Text("\(layout.displayName)  \(layout.id.rawValue)  long captions").font(.system(size: 12, weight: .semibold))
                canvas.frame(width: 640)
            }
            .padding(18)
            .background(Color(white: 0.13))
            .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1.5
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:])
            else { continue }
            let name = "long-\(layout.id.rawValue).png"
            try? png.write(to: dir.appendingPathComponent(name))
            written.append(name)
        }
        // Legends too long for their control at a readable size (7.5 pt at
        // a 520 pt wide drawing), for review.
        var tight: [String] = []
        for layout in ControllerLayoutCatalog.all where layout.isComplete {
            for c in layout.controls where c.isMeaningful {
                let lg = CanvasLegend.legend(for: c, in: layout, family: layout.family, model: layout.modelNames, choice: .automatic)
                guard let text = lg.text, lg.symbol == nil else { continue }
                let scale: CGFloat = c.face == .back ? 0.6 / 0.76 : 1
                let room = min(c.size, c.height ?? c.size) == c.size ? c.size * 520 * scale : c.size * 520 * scale
                let need = CaptionLayout.measure(text, fontSize: 7.5)
                if need > room + 2 { tight.append("\(layout.id.rawValue) \(c.id) \"\(text)\" needs \(Int(need)) has \(Int(room))") }
            }
        }
        try? (tight.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("legends.txt"), atomically: true, encoding: .utf8)
        let issues = LayoutValidation.validateAll().map(\.description)
        try? (issues.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("validation.txt"), atomically: true, encoding: .utf8)
        return written
    }
}
#endif
