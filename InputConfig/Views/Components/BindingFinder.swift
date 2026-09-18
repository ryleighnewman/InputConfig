import SwiftUI

/// One row of the preset as the search sees it.
struct PresetSearchHit: Identifiable {
    let id: UUID
    let joystickIndex: Int
    let rowNumber: Int
    let inputSerialized: String
    /// "A / Cross  →  Space"
    let title: String
    /// Where it lives and what the note says: "Input device 0 › Buttons · Jump".
    let detail: String
    let searchText: String
}

enum PresetSearch {

    /// Extra words a row should match on, so a control found under one name
    /// is found under every name people use for it. Searching is the only
    /// consumer: none of this is shown anywhere.
    static func aliases(for binding: BindingModel) -> String {
        var words: [String] = []
        func add(_ s: String...) { words.append(contentsOf: s) }
        switch binding.input.type {
        case .button:
            switch binding.input.index {
            case 0:  add("a", "cross", "x button", "south", "bottom face")
            case 1:  add("b", "circle", "o", "east", "right face")
            case 2:  add("x", "square", "west", "left face")
            case 3:  add("y", "triangle", "north", "top face")
            case 4:  add("lb", "l1", "left bumper", "left shoulder", "l")
            case 5:  add("rb", "r1", "right bumper", "right shoulder", "r")
            case 6:  add("lt", "l2", "left trigger", "zl")
            case 7:  add("rt", "r2", "right trigger", "zr")
            case 8:  add("back", "select", "share", "create", "view", "minus", "options")
            case 9:  add("start", "menu", "options", "plus")
            case 10: add("home", "ps", "playstation", "guide", "xbox button", "logo")
            case 11: add("l3", "left stick click", "left stick button", "ls")
            case 12: add("r3", "right stick click", "right stick button", "rs")
            case 13: add("touchpad", "touch pad", "pad press", "click the pad")
            case 14: add("share", "create", "capture")
            case 15: add("mute", "microphone", "mic")
            case 16: add("left paddle", "p1", "back paddle")
            case 17: add("right paddle", "p2", "back paddle")
            case 18: add("paddle 3", "p3")
            case 19: add("paddle 4", "p4")
            case 20: add("fn1", "fn 1", "function button")
            case 21: add("fn2", "fn 2", "function button")
            default: break
            }
        case .axis:
            let positive = binding.input.axisDirection != .negative
            switch binding.input.index {
            case 0: add("left stick", "ls", "left thumbstick", positive ? "right" : "left")
            case 1: add("left stick", "ls", "left thumbstick", positive ? "down" : "up")
            case 2: add("right stick", "rs", "right thumbstick", positive ? "right" : "left")
            case 3: add("right stick", "rs", "right thumbstick", positive ? "down" : "up")
            case 4: add("lt", "l2", "left trigger", "zl", "analog trigger")
            case 5: add("rt", "r2", "right trigger", "zr", "analog trigger")
            default: add("axis", "analog")
            }
        case .hat:
            add("dpad", "d-pad", "direction pad", "hat")
            switch binding.input.hatDirection {
            case .up: add("up", "north")
            case .down: add("down", "south")
            case .left: add("left", "west")
            case .right: add("right", "east")
            case nil: break
            }
        case .motion:
            add("gyro", "gyroscope", "motion", "tilt", "aim")
            switch binding.input.motionChannel {
            case .gyroX: add("pitch", "up down", "nose")
            case .gyroY: add("roll", "sideways", "left right", "yaw")
            case .gyroZ: add("turn", "yaw", "twist")
            case .accelX, .accelY, .accelZ: add("accelerometer", "shake")
            default: break
            }
        case .touchpad, .touchpadRegion, .touchpadGesture:
            add("touchpad", "touch pad", "trackpad", "finger", "swipe", "tap", "zone", "region")
        case .chassisTap:
            add("tap the mac", "knock", "chassis", "macbook", "case")
        case .extKey:
            add("keyboard", "key", "mac keyboard")
        case .extMouse:
            add("mouse", "pointer", "wheel", "scroll")
        case .midi:
            add("midi", "note", "cc", "knob", "pad", "fader")
        case .cursorRegion:
            add("screen region", "corner", "hot corner", "pointer area", "display", "monitor", "cursor region")
        case .stickRegion:
            add("stick zone", "stick region", "thumbstick area")
        }
        // Outputs people name differently from the menu wording.
        for o in binding.outputs + (binding.holdOutputs ?? []) + (binding.doubleTapOutputs ?? []) {
            switch o.type {
            case .mouseButton:
                add("click", "mouse")
                switch o.mouseButtonIndex ?? 0 {
                case 0: add("left click", "primary click")
                case 1: add("right click", "secondary click", "context menu")
                case 2: add("middle click")
                default: break
                }
            case .mouseMotion: add("pointer", "cursor", "move the mouse")
            case .mouseWheel, .mouseWheelStep: add("scroll", "wheel")
            case .key: add("key", "keystroke", "keyboard")
            case .typeText: add("type", "text", "phrase")
            case .appAction: add("app action", "inputconfig")
            case .systemAction: add("system", "mac", "shortcut")
            case .midiNote, .midiCC, .midiPitchBend, .midiProgramChange, .midiTransport: add("midi")
            case .absoluteVolume: add("volume")
            }
        }
        if binding.turboEnabled == true { add("turbo", "rapid fire", "repeat") }
        if binding.toggleMode == true { add("toggle", "sticky", "latch") }
        if binding.macroSteps?.isEmpty == false { add("macro", "sequence", "chain") }
        if !binding.modifiers.isEmpty { add("chord", "combo", "modifier", "held together") }
        return words.joined(separator: " ")
    }

    /// Every row in the preset, in order, with the text search matches against.
    static func index(_ preset: Preset) -> [PresetSearchHit] {
        var out: [PresetSearchHit] = []
        for (g, joystick) in preset.joysticks.enumerated() {
            for (i, b) in joystick.bindings.enumerated() {
                let outputs = b.outputs.isEmpty ? "nothing bound" : b.outputs.map(\.displayName).joined(separator: " + ")
                var parts: [String] = []
                if let hold = b.holdOutputs, !hold.isEmpty { parts.append("hold: " + hold.map(\.displayName).joined(separator: " + ")) }
                if let dbl = b.doubleTapOutputs, !dbl.isEmpty { parts.append("double tap: " + dbl.map(\.displayName).joined(separator: " + ")) }
                if let steps = b.macroSteps, !steps.isEmpty { parts.append("macro, \(steps.count) steps") }
                if !b.modifiers.isEmpty { parts.append("while holding " + b.modifiers.map(\.displayName).joined(separator: " + ")) }
                var title = "\(b.input.displayName)  \u{2192}  \(outputs)"
                if !parts.isEmpty { title += "  (" + parts.joined(separator: "; ") + ")" }
                var place = ["Input device \(g)"]
                if let s = b.section, !s.isEmpty { place.append(s) }
                var detail = place.joined(separator: " \u{203A} ")
                if let note = b.note, !note.isEmpty { detail += " \u{00B7} " + note }
                let text = (title + " " + detail + " " + b.input.serialized + " " + aliases(for: b)).lowercased()
                out.append(PresetSearchHit(id: b.id, joystickIndex: g, rowNumber: i + 1,
                                           inputSerialized: b.input.serialized,
                                           title: title, detail: detail, searchText: text))
            }
        }
        return out
    }

    /// Every word typed must appear in the row's text.
    static func matches(_ hits: [PresetSearchHit], query: String) -> [PresetSearchHit] {
        let words = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        return hits.filter { h in words.allSatisfy { h.searchText.contains($0) } }
    }
}

/// The search field at the top of the editor: type, the matching rows of
/// this preset list underneath with what each one does, click one and the
/// editor scrolls to it. Up and Down move the highlight, Return goes.
struct PresetSearchBar: View {
    let preset: Preset
    let onGo: (PresetSearchHit) -> Void

    @State private var query = ""
    @State private var highlighted = 0

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        let hits: [PresetSearchHit] = trimmed.isEmpty ? [] : PresetSearch.matches(PresetSearch.index(preset), query: trimmed)
        VStack(alignment: .leading, spacing: 6) {
            searchField(hits)
            if !trimmed.isEmpty {
                // Same left edge as the text field, not the magnifier.
                results(hits)
                    .padding(.leading, 16 + 8)
            }
        }
    }

    private func searchField(_ hits: [PresetSearchHit]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            TextField("Search this preset: a button, a key, a note, anything in a row", text: $query)
                .textFieldStyle(.roundedBorder)
                .onChange(of: query) { _, _ in highlighted = 0 }
                .onSubmit { if hits.indices.contains(highlighted) { go(hits[highlighted]) } }
                .onKeyPress(.downArrow) {
                    guard !hits.isEmpty else { return .ignored }
                    highlighted = min(highlighted + 1, hits.count - 1); return .handled
                }
                .onKeyPress(.upArrow) {
                    guard !hits.isEmpty else { return .ignored }
                    highlighted = max(highlighted - 1, 0); return .handled
                }
                .onKeyPress(.escape) {
                    guard !query.isEmpty else { return .ignored }
                    query = ""; return .handled
                }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Clear search")
            }
        }
    }

    private func results(_ hits: [PresetSearchHit]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if hits.isEmpty {
                Text("No row in this preset matches \u{201C}\(trimmed)\u{201D}.")
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(hits.enumerated()), id: \.element.id) { i, h in
                            row(h, highlighted: i == highlighted)
                                .onTapGesture { go(h) }
                                // Deferred: the results list appears under the
                                // cursor as you type, so this hover can arrive
                                // in the middle of a layout pass, and writing
                                // state there aborts the SwiftUI update.
                                .onHover { inside in
                                    guard inside else { return }
                                    DispatchQueue.main.async { highlighted = i }
                                }
                        }
                    }
                }
                .frame(maxHeight: min(CGFloat(hits.count), 8) * 48 + 4)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        // Clip so the first and last rows' highlight follows the corners.
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
    }

    private func row(_ h: PresetSearchHit, highlighted: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text("#\(h.rowNumber)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(h.title).lineLimit(1)
                Text(h.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "arrow.turn.down.right")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlighted ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
    }

    private func go(_ h: PresetSearchHit) {
        query = ""
        onGo(h)
    }
}
