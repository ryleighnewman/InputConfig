import SwiftUI

/// One row of the preset as the search sees it.
struct PresetSearchHit: Identifiable {
    let id: UUID
    let joystickIndex: Int
    let rowNumber: Int
    let inputSerialized: String
    /// "A / Cross  →  Space"
    let title: String
    /// Where it lives and what the note says: "Input device 0 › Buttons, Jump".
    let detail: String
    let searchText: String
}

enum PresetSearch {

    /// Extra words a row should match on, so a control found under one name
    /// is found under every name people use for it. Searching is the only
    /// consumer: none of this is shown anywhere.
    static func aliases(for binding: BindingModel, presetName: ((UUID) -> String?)? = nil) -> String {
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
        case .stickGesture:
            add("stick gesture", "flick", "double flick", "snap", "stick swipe")
        }
        // Outputs people name differently from the menu wording.
        for o in binding.outputs + (binding.holdOutputs ?? []) + (binding.doubleTapOutputs ?? []) {
            switch o.type {
            case .mouseButton:
                add("click", "mouse")
                // The picker's own words too, so a row found by what it shows.
                switch o.mouseButtonIndex ?? 0 {
                case 0: add("left click", "primary click", "main click", String(localized: "0: Main Click"))
                case 1: add("right click", "secondary click", "context menu", "secondary", String(localized: "1: Secondary"))
                case 2: add("middle click", "middle", String(localized: "2: Middle"))
                case 3: add("back", String(localized: "3: Back"))
                case 4: add("forward", String(localized: "4: Forward"))
                case 5: add("extra", String(localized: "5: Extra"))
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
            case .lightBar: add("light bar", "rgb", "color", "led", "rainbow")
            }
        }
        // What the row shows in full, not its short previews: a macro's
        // steps, the whole text a Type Text output types, a system action's
        // parameter, and the preset an Activate Preset output starts.
        for step in binding.macroSteps ?? [] { add(OutputAction.names(step.pressedActions).joined(separator: " ")) }
        for o in binding.outputs + (binding.holdOutputs ?? []) + (binding.doubleTapOutputs ?? []) {
            if let text = o.text, !text.isEmpty { add(text) }
            if let target = o.targetPresetID, let name = presetName?(target) { add(name) }
        }
        if binding.turboEnabled == true { add("turbo", "rapid fire", "repeat") }
        if binding.toggleMode == true { add("toggle", "sticky", "latch") }
        if binding.macroSteps?.isEmpty == false { add("macro", "sequence", "chain") }
        if !binding.modifiers.isEmpty { add("chord", "combo", "modifier", "held together") }
        return words.joined(separator: " ")
    }

    /// Every row in the preset, in order, with the text search matches against.
    /// `naming` gives each group's family and model names, the editor's
    /// own; without it, the preset's Buttons choice.
    static func index(_ preset: Preset,
                      naming: ((Int) -> (family: FaceLetters?, model: ButtonNames.ModelNames))? = nil,
                      presetName: ((UUID) -> String?)? = nil) -> [PresetSearchHit] {
        var out: [PresetSearchHit] = []
        for (g, joystick) in preset.joysticks.enumerated() {
            let names = naming?(g) ?? (family: preset.buttonFamily, model: .none)
            for (i, b) in joystick.bindings.enumerated() {
                let outputs = b.outputs.isEmpty ? String(localized: "nothing bound") : OutputAction.names(b.outputs).joined(separator: " + ")
                var parts: [String] = []
                if let hold = b.holdOutputs, !hold.isEmpty {
                    let names = OutputAction.names(hold).joined(separator: " + ")
                    parts.append(String(localized: "hold: \(names)"))
                }
                if let dbl = b.doubleTapOutputs, !dbl.isEmpty {
                    let names = OutputAction.names(dbl).joined(separator: " + ")
                    parts.append(String(localized: "double tap: \(names)"))
                }
                if let steps = b.macroSteps, !steps.isEmpty { parts.append((steps.count == 1 ? String(localized: "macro, 1 step") : String(localized: "macro, \(steps.count) steps"))) }
                if !b.modifiers.isEmpty {
                    let held = b.modifiers.map { ButtonNames.inputName($0, family: names.family, model: names.model) }
                        .joined(separator: " + ")
                    parts.append(String(localized: "while holding \(held)"))
                }
                let inputName = ButtonNames.inputName(b.input, family: names.family, model: names.model)
                var title = String(localized: "\(inputName)  →  \(outputs)")
                if !parts.isEmpty { title += "  (" + parts.joined(separator: "; ") + ")" }
                var place = [String(localized: "Input device \(g)")]
                if let s = b.section, !s.isEmpty { place.append(ControllerScaffold.shownSection(s)) }
                var detail = place.joined(separator: " \u{203A} ")
                if let note = b.note, !note.isEmpty { detail += ", " + ShippedText.t(note) }
                let text = (title + " " + detail + " " + b.input.serialized + " " + b.input.displayName + " "
                            + aliases(for: b, presetName: presetName)).lowercased()
                out.append(PresetSearchHit(id: b.id, joystickIndex: g, rowNumber: i + 1,
                                           inputSerialized: b.input.serialized,
                                           title: title, detail: detail, searchText: text))
            }
        }
        return out
    }

    /// Every word typed must appear in the row's text.
    static func matches(_ hits: [PresetSearchHit], query: String) -> [PresetSearchHit] {
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        return hits.filter { h in words.allSatisfy { h.searchText.contains($0) } }
    }
}

/// The search field at the top of the editor: type, the matching rows of
/// this preset list underneath with what each one does, click one and the
/// editor scrolls to it. Up and Down move the highlight, Return goes.
struct PresetSearchBar: View {
    @Environment(\.appTextScale) private var textScale
    let preset: Preset
    var naming: ((Int) -> (family: FaceLetters?, model: ButtonNames.ModelNames))? = nil
    /// Names the preset an Activate Preset output starts.
    var presetName: ((UUID) -> String?)? = nil
    let onGo: (PresetSearchHit) -> Void

    @State private var query = ""
    @State private var highlighted = 0
    /// The match count, said once typing pauses rather than on every key.
    @State private var countAnnouncement: DispatchWorkItem?
    /// Set while typing resets the highlight, which is not worth saying.
    @State private var highlightResetByTyping = false

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    /// Clears the open search, for the editor's Cancel: Escape is its
    /// shortcut, taken before the field hears the key. True when a search
    /// was cleared.
    static var clearActiveSearch: (() -> Bool)?

    var body: some View {
        let hits: [PresetSearchHit] = trimmed.isEmpty ? [] : PresetSearch.matches(PresetSearch.index(preset, naming: naming, presetName: presetName), query: trimmed)
        VStack(alignment: .leading, spacing: 6) {
            searchField(hits)
                .onAppear {
                    Self.clearActiveSearch = {
                        guard !query.isEmpty else { return false }
                        query = ""
                        return true
                    }
                }
                .onDisappear { Self.clearActiveSearch = nil }
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
                .onChange(of: query) { _, _ in
                    if highlighted != 0 { highlightResetByTyping = true }
                    highlighted = 0
                    // Spoken, since the list is otherwise silent: once, half
                    // a second after the last key, not over the typing echo.
                    countAnnouncement?.cancel()
                    guard !trimmed.isEmpty else { return }
                    let n = hits.count
                    let work = DispatchWorkItem {
                        AccessibilityNotification.Announcement(n == 0 ? String(localized: "No matching rows") : n == 1 ? String(localized: "1 matching row") : String(localized: "\(n) matching rows")).post()
                    }
                    countAnnouncement = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
                }
                .onChange(of: highlighted) { _, i in
                    if highlightResetByTyping { highlightResetByTyping = false; return }
                    if hits.indices.contains(i) {
                        AccessibilityNotification.Announcement(String(localized: "Row \(hits[i].rowNumber), \(HotKeySpec.spokenMarks(in: hits[i].title))")).post()
                    }
                }
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
                    .foregroundStyle(.hint)
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
                ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(hits.enumerated()), id: \.element.id) { i, h in
                            row(h, highlighted: i == highlighted)
                                .id(i)
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
                // Each row grows with Text Size, so its slot does too.
                .frame(maxHeight: min(CGFloat(hits.count), 8) * 48 * max(1, textScale) + 4)
                // The arrow keys' highlight stays in view (and where Zoom looks).
                .onChange(of: highlighted) { _, i in proxy.scrollTo(i) }
                }
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
                .frame(width: 34 * max(1, textScale), alignment: .trailing)
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
        // One element that acts as a button, for VoiceOver and Voice Control.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Row \(h.rowNumber), \(h.title), \(h.detail)")
        .accessibilityAction { go(h) }
    }

    private func go(_ h: PresetSearchHit) {
        query = ""
        onGo(h)
    }
}
