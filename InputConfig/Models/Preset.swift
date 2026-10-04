import Foundation

/// Per-preset light-bar color override. Stored as 0-255 RGB so it
/// round-trips through JSON without floating-point precision drift.
struct RGBLightColor: Codable, Hashable {
    var r: UInt8
    var g: UInt8
    var b: UInt8

    /// Helpers for SwiftUI's Color <-> bytes round-trip.
    var floatR: Float { Float(r) / 255 }
    var floatG: Float { Float(g) / 255 }
    var floatB: Float { Float(b) / 255 }

    init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r; self.g = g; self.b = b
    }

    init(floatR: Float, floatG: Float, floatB: Float) {
        // Rounded, not truncated: 0.4 * 255 = 101.99... truncated to 101,
        // so every read-back-and-store cycle darkened the color one step.
        func byte(_ v: Float) -> UInt8 { v.isFinite ? UInt8(max(0, min(255, (v * 255).rounded()))) : 0 }
        self.r = byte(floatR)
        self.g = byte(floatG)
        self.b = byte(floatB)
    }
}

/// Sensitivity curve for analog inputs
enum SensitivityCurve: String, Codable, CaseIterable, Identifiable {
    case linear = "linear"
    case exponential = "exponential"
    case aggressive = "aggressive"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .linear: return "Linear"
        case .exponential: return "Smooth"
        case .aggressive: return "Aggressive"
        }
    }

    func apply(_ value: Float) -> Float {
        switch self {
        case .linear: return value
        case .exponential: return value * value * (value > 0 ? 1 : -1)
        case .aggressive:
            let sign: Float = value >= 0 ? 1 : -1
            let abs = abs(value)
            return sign * sqrt(abs)
        }
    }
}

/// How a macro step treats its action: a full press-and-release tap (the
/// default), a press that stays held while later steps run, or the release
/// of an earlier held step. Hold and release kinds let one macro produce
/// chords like Cmd+C: Cmd hold down, C tap, Cmd release.
enum MacroStepKind: String, Codable, CaseIterable, Identifiable {
    case tap
    case down
    case up
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .tap: return "Tap"
        case .down: return "Hold down"
        case .up: return "Release"
        }
    }
}

/// A single step in a macro sequence
struct MacroStep: Identifiable, Codable, Hashable {
    let id: UUID
    var action: OutputAction      // What to do
    var delayMs: Int              // Delay BEFORE this step in milliseconds
    var holdMs: Int               // How long to hold (for press actions)
    var eventKind: MacroStepKind? // nil decodes as .tap, so old presets are unchanged
    /// Modifier keys (HID codes: Control, Option, Shift, Command) held with a
    /// key step, so one step can be a shortcut such as Command V. nil for a
    /// plain key, and for every step saved before this existed.
    var modifiers: [Int]?

    init(action: OutputAction, delayMs: Int = 50, holdMs: Int = 50,
         eventKind: MacroStepKind? = nil, modifiers: [Int]? = nil) {
        self.id = UUID()
        self.action = action
        self.delayMs = delayMs
        self.holdMs = holdMs
        self.eventKind = eventKind
        self.modifiers = modifiers
    }

    /// What the step presses: its modifiers first, then its action.
    var pressedActions: [OutputAction] {
        guard action.type == .key, let modifiers, !modifiers.isEmpty else { return [action] }
        return modifiers.map { OutputAction(type: .key, keyCode: $0) } + [action]
    }
}

/// Destination for spoken feedback when a binding fires
enum SpeechDestination: String, Codable, CaseIterable, Identifiable {
    case mac = "mac"
    case controller = "controller"
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .mac: return "Mac Speakers"
        case .controller: return "Controller Speaker"
        }
    }
}

/// A single input-to-output binding
struct BindingModel: Identifiable, Codable, Hashable {
    /// A var only so `duplicated()` can copy every field and change this one.
    fileprivate(set) var id: UUID
    var input: InputEvent
    var outputs: [OutputAction]

    // Advanced options
    var deadzone: Float?         // Inner axis deadzone (0.0-0.9), nil = use default 0.25
                                 // Magnitudes below this are treated as zero.
    var outerDeadzone: Float?    // Optional outer/saturation deadzone (0.1-1.0). When set,
                                 // magnitudes ABOVE this clamp to full output. The active
                                 // range becomes [inner, outer] mapped linearly to [0, 1].
    var invertAxis: Bool?        // Invert axis direction
    var toggleMode: Bool?        // Toggle on/off instead of hold
    var turboEnabled: Bool?      // Rapid fire mode
    var turboRate: Int?          // Turbo presses per second (default 10)
    /// Auto-click settings on top of turbo. Interval in ms takes precedence
    /// over `turboRate` when set (an auto-clicker thinks in ms, not Hz);
    /// jitter adds a random +/- to every gap so the clicks are not perfectly
    /// regular; maxCount stops the run after that many presses (0 or nil is
    /// unlimited). All optional so old presets decode unchanged.
    var turboIntervalMs: Int?
    var turboJitterMs: Int?
    var turboMaxCount: Int?
    var sensitivityCurve: SensitivityCurve?  // Response curve for analog inputs
    var repeatCount: Int?        // Times to repeat outputs (nil or <= 1 fires once; > 1 repeats that many times)
    var repeatDelayMs: Int?      // Delay between repeats in ms (default 100)

    // Variable sensitivity: scale output magnitude by axis depth (0 to 1).
    // When false, the configured speed/value is used at full magnitude after the deadzone.
    var variableSensitivity: Bool?

    /// Ramp-up, in milliseconds: a stick row that moves the pointer starts at
    /// a fraction of its speed and eases up to full speed over this long of
    /// holding, so a short push makes a small, controllable move and only a
    /// held push travels fast. nil or 0 is off (every preset before 1.6).
    var rampMs: Int?

    // Feedback options
    var hapticEnabled: Bool?     // Vibrate the controller when this binding fires
    var hapticIntensity: Float?  // 0.0 to 1.0, default 0.6
    /// How long the vibration lasts, in milliseconds. nil (or under 60 ms)
    /// is the original short transient tap; longer values play a continuous
    /// rumble of that length. Optional so old presets decode unchanged.
    var hapticDurationMs: Int?
    var speechEnabled: Bool?     // Speak a phrase when this binding fires
    var speechText: String?      // Phrase to speak (defaults to the input name)
    var speechDestination: SpeechDestination?  // Where to play the speech

    // Macro sequence (overrides outputs when set)
    var macroSteps: [MacroStep]?

    /// When true, releasing the input stops the rest of a running macro
    /// chain and releases any held steps. nil decodes as false.
    var macroInterruptOnRelease: Bool?

    // Tap-vs-hold: when set, holding the input past holdThresholdMs fires
    // these outputs (released when the input releases); letting go sooner
    // fires `outputs` as a quick tap instead. nil keeps the plain immediate
    // behavior with zero added latency.
    var holdOutputs: [OutputAction]?
    var holdThresholdMs: Int?

    // Double-tap: when set, two presses inside doubleTapWindowMs fire these
    // outputs; a single tap fires `outputs` once the window lapses.
    var doubleTapOutputs: [OutputAction]?
    var doubleTapWindowMs: Int?

    /// Short, human-readable note describing what this binding does, shown in
    /// the editor row beneath the mapping (e.g. "Jump", "Sprint / hold to run").
    /// The Smart Preset Maker fills this in per-binding from the preset profile
    /// so every row explains itself, instead of one giant info dump on the
    /// preset's notes box. Optional + synthesized Codable means older preset
    /// files (no "note" key) decode with nil, so existing user presets that
    /// people created or edited are never lost on upgrade.
    var note: String?

    /// Section heading this row sits under in the editor ("Left stick",
    /// "Buttons", or whatever the user named it). Rows with the same section
    /// in a row share one heading; nil rows have none. Optional so older
    /// preset files decode unchanged.
    var section: String?

    /// Chord: when set, this row only fires while the modifier control is
    /// also held (Triangle + D-pad up). A plain row on the same input is
    /// suppressed while the chord is satisfied, so the two do not both
    /// fire. nil (every existing preset) keeps the plain behavior.
    var modifierInput: InputEvent?
    /// Mouse middle and side buttons only: while the preset runs, apps stop
    /// seeing the button, so it does only what this row says (a side
    /// button no longer also goes Back). nil = off.
    var blockOriginal: Bool?
    /// Key outputs held by this row repeat like a held key (see
    /// InputSimulator). nil = off, as for every preset before 1.6; true
    /// turns it on for this row.
    var keyRepeat: Bool?
    /// Chords with more than one held control. A row can require up to three
    /// controls held together; `modifierInput` stays as the first of them so
    /// presets written before this field still load and still save readably.
    var extraModifierInputs: [InputEvent]?

    /// Every control this row needs held, in order. Empty means it fires on
    /// its own.
    var modifiers: [InputEvent] {
        var out: [InputEvent] = []
        if let first = modifierInput { out.append(first) }
        out.append(contentsOf: extraModifierInputs ?? [])
        return out
    }

    /// Replace the held-control list, keeping the first in `modifierInput`.
    mutating func setModifiers(_ list: [InputEvent]) {
        let capped = Array(list.prefix(BindingModel.maxModifiers))
        modifierInput = capped.first
        extraModifierInputs = capped.count > 1 ? Array(capped.dropFirst()) : nil
    }

    static let maxModifiers = 3

    init(input: InputEvent, outputs: [OutputAction] = []) {
        self.id = UUID()
        self.input = input
        self.outputs = outputs
    }

    init(id: UUID = UUID(), input: InputEvent, outputs: [OutputAction],
         deadzone: Float? = nil, outerDeadzone: Float? = nil, invertAxis: Bool? = nil, toggleMode: Bool? = nil,
         turboEnabled: Bool? = nil, turboRate: Int? = nil,
         turboIntervalMs: Int? = nil, turboJitterMs: Int? = nil, turboMaxCount: Int? = nil,
         sensitivityCurve: SensitivityCurve? = nil,
         repeatCount: Int? = nil, repeatDelayMs: Int? = nil,
         variableSensitivity: Bool? = nil,
         rampMs: Int? = nil,
         hapticEnabled: Bool? = nil, hapticIntensity: Float? = nil,
         hapticDurationMs: Int? = nil,
         speechEnabled: Bool? = nil, speechText: String? = nil,
         speechDestination: SpeechDestination? = nil,
         macroSteps: [MacroStep]? = nil,
         macroInterruptOnRelease: Bool? = nil,
         holdOutputs: [OutputAction]? = nil,
         holdThresholdMs: Int? = nil,
         doubleTapOutputs: [OutputAction]? = nil,
         doubleTapWindowMs: Int? = nil,
         modifierInput: InputEvent? = nil,
         extraModifierInputs: [InputEvent]? = nil,
         note: String? = nil,
         section: String? = nil) {
        self.id = id
        self.input = input
        self.outputs = outputs
        self.deadzone = deadzone
        self.outerDeadzone = outerDeadzone
        self.invertAxis = invertAxis
        self.toggleMode = toggleMode
        self.turboEnabled = turboEnabled
        self.turboRate = turboRate
        self.turboIntervalMs = turboIntervalMs
        self.turboJitterMs = turboJitterMs
        self.turboMaxCount = turboMaxCount
        self.sensitivityCurve = sensitivityCurve
        self.repeatCount = repeatCount
        self.repeatDelayMs = repeatDelayMs
        self.variableSensitivity = variableSensitivity
        self.rampMs = rampMs
        self.hapticEnabled = hapticEnabled
        self.hapticIntensity = hapticIntensity
        self.hapticDurationMs = hapticDurationMs
        self.speechEnabled = speechEnabled
        self.speechText = speechText
        self.speechDestination = speechDestination
        self.macroSteps = macroSteps
        self.macroInterruptOnRelease = macroInterruptOnRelease
        self.holdOutputs = holdOutputs
        self.holdThresholdMs = holdThresholdMs
        self.doubleTapOutputs = doubleTapOutputs
        self.doubleTapWindowMs = doubleTapWindowMs
        self.modifierInput = modifierInput
        self.extraModifierInputs = extraModifierInputs
        self.note = note
        self.section = section
    }

    /// Full-fidelity copy with a fresh identity: the whole row, so a field
    /// added later cannot be missed. The field-by-field version dropped
    /// whatever its list lacked (the chord's second button once, then
    /// Block original and key repeat in 1.6).
    func duplicated() -> BindingModel {
        var copy = self
        copy.id = UUID()
        return copy
    }
}

/// Kind of input device a slot represents. Drives the Live Visualizer
/// layout: a slot whose `inputKind = .keyboard` swaps the controller
/// widgets for a keyboard-style chip layout, etc. `.auto` (default for
/// existing presets) infers from the bindings' type majority.
enum SlotInputKind: String, Codable, Hashable, CaseIterable {
    case auto       // pick layout from the bindings' types
    case controller // game controller widgets
    case keyboard   // bound-keys chip map
    case touchpad   // touchpad surface + regions + finger trails
    case mouse      // bound mouse buttons / axes
    case midi       // MIDI instrument: keys, knobs, wheels, event log
    case screen     // a display: screen regions the pointer enters
}

extension JoystickMapping {
    /// What a group reads when that is not a game controller: the kind it
    /// is set to, or on Automatic the Mac input every row comes from.
    /// nil for a controller group. Headers and chips name this instead of
    /// whichever pad happens to be plugged in.
    var macInputName: String? {
        switch inputKind {
        case .keyboard: return "Keyboard"
        case .mouse: return "Mouse"
        case .screen: return "Screen"
        case .midi: return "MIDI"
        case .controller, .touchpad: return nil
        case .auto: break
        }
        guard !bindings.isEmpty else { return nil }
        var kinds: [String] = []
        for b in bindings {
            let kind: String
            switch b.input.type {
            case .extKey: kind = "Keyboard"
            case .extMouse: kind = "Mouse"
            case .cursorRegion: kind = "Screen"
            case .midi: kind = "MIDI"
            default: return nil
            }
            if !kinds.contains(kind) { kinds.append(kind) }
        }
        let ordered = ["Keyboard", "Mouse", "Screen", "MIDI"].filter(kinds.contains)
        guard let first = ordered.first else { return nil }
        if ordered.count == 1 { return first }
        let rest = ordered.dropFirst().map { $0 == "MIDI" ? $0 : $0.lowercased() }
        return rest.count == 1 ? "\(first) and \(rest[0])"
            : "\(first), " + rest.dropLast().joined(separator: ", ") + " and \(rest.last!)"
    }

    /// The symbol for `macInputName`.
    var macInputSymbol: String {
        switch macInputName {
        case "Mouse"?: return "computermouse"
        case "Screen"?: return "display"
        case "MIDI"?: return "pianokeys"
        default: return "keyboard"
        }
    }
}

/// A joystick mapping group (one physical controller's bindings)
struct JoystickMapping: Identifiable, Codable, Hashable {
    let id: UUID
    var tag: String
    var bindings: [BindingModel]
    var isExpanded: Bool
    /// Optional user-provided name for this joystick slot, e.g.
    /// "Player 1 - Steve's controller". When set, takes priority over
    /// the auto-derived controller product name in the UI. nil = fall
    /// back to the connected controller's product name (e.g. "DualSense
    /// Wireless Controller") or "Joystick #N" if no controller is bound
    /// to that slot. Stored separately from `tag` (which is a free-form
    /// description / comment).
    var customName: String?
    /// Kind of input device this slot represents. Picking a keyboard /
    /// mouse / specific controller from the slot menu sets this so the
    /// Live Visualizer can swap to the matching layout. Defaults to
    /// `.auto` so existing preset files decode unchanged.
    var inputKind: SlotInputKind = .auto
    /// The device these rows were scanned from: vendor and product plus a
    /// salted hash of its serial (see `GameControllerService.deviceFingerprint`).
    /// Meaningful only on this Mac, so exports and shares leave it out.
    /// Recorded when a row is scanned from this slot's controller; nil in
    /// presets made before 1.6 and for slots never scanned. Informational
    /// for now: rows still follow the slot number.
    var deviceFingerprint: String?
    /// The controller model this group is set up for (ControllerModelID raw
    /// value), chosen in the Live Visualizer's Controller picker. The
    /// visualizer draws it when no controller is connected. nil in presets
    /// made before 1.6; an id a later build wrote is kept as it is.
    var controllerModel: String?
    /// Group fields this build has no key for (written by a newer version),
    /// kept and written back so saving here does not delete them.
    var extraFields: [String: JSONValue] = [:]
    /// Rows this build could not read (written by a newer version), kept
    /// exactly as they were and written back after `bindings`, so saving
    /// the preset here does not delete them.
    var unreadableRows: [JSONValue] = []

    init(tag: String = "", bindings: [BindingModel] = [], isExpanded: Bool = true,
         customName: String? = nil, inputKind: SlotInputKind = .auto) {
        self.id = UUID()
        self.tag = tag
        self.bindings = bindings
        self.isExpanded = isExpanded
        self.customName = customName
        self.inputKind = inputKind
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, tag, bindings, isExpanded, customName, inputKind, deviceFingerprint, controllerModel
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A hand-written file may leave out the group id; give it a new one.
        self.id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        self.tag = try c.decodeIfPresent(String.self, forKey: .tag) ?? ""
        // Rows are decoded one at a time. A row this build cannot read,
        // typically an input or output type added by a newer version, is
        // dropped and counted rather than taking the whole preset with it.
        // Before, one unknown enum value anywhere in the file threw out of
        // the array decode and the preset silently vanished from the sidebar.
        //
        // An unreadable row is kept as raw JSON and written back, so a newer
        // build's rows survive a save here. A value even that cannot hold
        // (a number outside Double's range) stops the walk: a failed decode
        // does not advance the container, so looping on it never ended and
        // the file hung the app on every launch.
        var rows: [BindingModel] = []
        var kept: [JSONValue] = []
        var dropped = 0
        if var list = try? c.nestedUnkeyedContainer(forKey: .bindings) {
            while !list.isAtEnd {
                if let row = try? list.decode(BindingModel.self) {
                    rows.append(row)
                } else if let raw = try? list.decode(JSONValue.self) {
                    // A hand-written row may leave out its ids (Help invites
                    // editing the files); given new ones it reads fine.
                    if let minted = Self.mintingMissingIDs(raw),
                       let data = try? JSONEncoder().encode(minted),
                       let row = try? JSONDecoder().decode(BindingModel.self, from: data) {
                        rows.append(row)
                    } else {
                        kept.append(raw)
                    }
                } else {
                    dropped += max(1, (list.count ?? list.currentIndex + 1) - list.currentIndex)
                    break
                }
            }
        }
        // A row pasted twice keeps one id; the engine keys every row's state
        // by it, so the copy gets its own.
        var seenIDs = Set<UUID>()
        for i in rows.indices where !seenIDs.insert(rows[i].id).inserted {
            rows[i].id = UUID()
        }
        self.bindings = rows
        self.unreadableRows = kept
        if !kept.isEmpty { Self.keptRowsDuringDecode += kept.count }
        if dropped > 0 { Self.droppedRowsDuringDecode += dropped }
        self.isExpanded = (try? c.decodeIfPresent(Bool.self, forKey: .isExpanded)) ?? true
        self.customName = try? c.decodeIfPresent(String.self, forKey: .customName)
        // try?: a slot kind added by a newer build must not make the preset unreadable.
        self.inputKind = (try? c.decodeIfPresent(SlotInputKind.self, forKey: .inputKind)) ?? .auto
        self.deviceFingerprint = try? c.decodeIfPresent(String.self, forKey: .deviceFingerprint)
        self.controllerModel = try? c.decodeIfPresent(String.self, forKey: .controllerModel)
        let known = Set(CodingKeys.allCases.map(\.stringValue))
        if let all = try? decoder.container(keyedBy: AnyCodingKey.self) {
            for key in all.allKeys where !known.contains(key.stringValue) {
                if let value = try? all.decode(JSONValue.self, forKey: key) { extraFields[key.stringValue] = value }
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(tag, forKey: .tag)
        var list = c.nestedUnkeyedContainer(forKey: .bindings)
        for row in bindings { try list.encode(row) }
        for raw in unreadableRows { try list.encode(raw) }
        try c.encode(isExpanded, forKey: .isExpanded)
        try c.encodeIfPresent(customName, forKey: .customName)
        try c.encode(inputKind, forKey: .inputKind)
        try c.encodeIfPresent(deviceFingerprint, forKey: .deviceFingerprint)
        try c.encodeIfPresent(controllerModel, forKey: .controllerModel)
        if !extraFields.isEmpty {
            var extra = encoder.container(keyedBy: AnyCodingKey.self)
            for (key, value) in extraFields { try extra.encode(value, forKey: AnyCodingKey(key)) }
        }
    }

    /// Rows skipped by the last decode passes, for the store to report.
    /// Reset by whoever reads it.
    nonisolated(unsafe) static var droppedRowsDuringDecode = 0
    /// Unreadable rows kept as raw JSON by the last decode passes.
    nonisolated(unsafe) static var keptRowsDuringDecode = 0
}

/// Any JSON value, kept as it was read, so parts of a file this build
/// cannot interpret are written back unchanged instead of deleted.
extension JoystickMapping {
    /// The row with an id added wherever the row, an output or a macro step
    /// has none, or nil when nothing was missing.
    static func mintingMissingIDs(_ row: JSONValue) -> JSONValue? {
        guard case .object(var dict) = row else { return nil }
        var changed = false
        func withID(_ value: JSONValue) -> JSONValue {
            guard case .object(var o) = value else { return value }
            if o["id"] == nil { o["id"] = .string(UUID().uuidString); changed = true }
            if let action = o["action"], case .object = action { o["action"] = withID(action) }
            return .object(o)
        }
        if dict["id"] == nil { dict["id"] = .string(UUID().uuidString); changed = true }
        for key in ["outputs", "holdOutputs", "doubleTapOutputs", "macroSteps"] {
            if case .array(let list)? = dict[key] { dict[key] = .array(list.map(withID)) }
        }
        return changed ? .object(dict) : nil
    }
}

enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

/// A coding key for field names not known at compile time.
struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// Per-preset automation: side effects that fire on preset activation
/// (auto-open an app) plus cursor utilities that only apply while the
/// preset is running (confine, recenter, hide). Lives on the preset so
/// each game / workflow gets its own choices; global Settings stays
/// out of the way.
struct PresetAutomation: Codable, Hashable {
    /// Posix path or bundle identifier of an app to launch when the
    /// preset activates. Empty string = no auto-launch. Examples:
    /// "/Applications/Steam.app", "com.valvesoftware.steam".
    var launchAppPath: String = ""
    /// Optional URL to open after launching the app (e.g. a steam://
    /// link to start a specific game). Empty = nothing.
    var launchURL: String = ""

    /// Confine the cursor away from screen edges while this preset
    /// runs. Same behavior as the global CursorGuard toggle, just
    /// preset-scoped.
    var confineCursor: Bool = false
    var confineBufferPx: Double = 24

    /// Periodically warp the cursor back to the center of its screen.
    var autoRecenterCursor: Bool = false
    var autoRecenterIntervalMs: Double = 500

    /// Hide the OS cursor for the duration of the preset.
    var hideCursorWhileActive: Bool = false

    /// Cursor sensitivity multiplier applied to mouse-move outputs the
    /// preset fires (independent of macOS pointer-speed slider).
    var sensitivityMultiplier: Double = 1.0

    /// The same for scrolling: multiplies every stick, dial and touchpad
    /// scroll the preset makes. Set from the preset's own page, next to the
    /// pointer speed, so no row has to be opened to change either.
    var scrollMultiplier: Double = 1.0

    /// Bundle identifiers of apps that automatically activate this preset
    /// when one of them comes to the front (gated by the global toggle in
    /// Settings). Optional, not defaulted, so preset files saved before
    /// this field existed decode unchanged.
    var autoActivateBundleIDs: [String]?

    /// The D-pad counts one direction at a time: the direction pressed first
    /// keeps the pad until it is let go, and a diagonal that is pressed
    /// straight away waits until it settles on one side. A quick press on
    /// many pads grazes the neighboring direction, which fired two rows at
    /// once (Copy and Cut, a page and a tab). Optional so older files and
    /// presets that never set it are unchanged; nil is off.
    var dpadOneDirection: Bool?
}

extension PresetAutomation {
    enum CodingKeys: String, CodingKey {
        case launchAppPath, launchURL, confineCursor, confineBufferPx
        case autoRecenterCursor, autoRecenterIntervalMs, hideCursorWhileActive
        case sensitivityMultiplier, autoActivateBundleIDs
        case scrollMultiplier
        case dpadOneDirection
    }

    /// Lenient decode: each field falls back to its default when missing.
    /// Swift's synthesized Decodable emits `decode` (not decodeIfPresent) for
    /// non-optional stored properties and throws keyNotFound on an absent key,
    /// which would take the whole Preset decode down and silently drop the
    /// preset from the sidebar. Adding one new automation field in a future
    /// build must never vanish a user's existing presets. Matches DriveConfig.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var a = PresetAutomation()
        a.launchAppPath = try c.decodeIfPresent(String.self, forKey: .launchAppPath) ?? a.launchAppPath
        a.launchURL = try c.decodeIfPresent(String.self, forKey: .launchURL) ?? a.launchURL
        a.confineCursor = try c.decodeIfPresent(Bool.self, forKey: .confineCursor) ?? a.confineCursor
        a.confineBufferPx = try c.decodeIfPresent(Double.self, forKey: .confineBufferPx) ?? a.confineBufferPx
        a.autoRecenterCursor = try c.decodeIfPresent(Bool.self, forKey: .autoRecenterCursor) ?? a.autoRecenterCursor
        a.autoRecenterIntervalMs = try c.decodeIfPresent(Double.self, forKey: .autoRecenterIntervalMs) ?? a.autoRecenterIntervalMs
        a.hideCursorWhileActive = try c.decodeIfPresent(Bool.self, forKey: .hideCursorWhileActive) ?? a.hideCursorWhileActive
        a.sensitivityMultiplier = try c.decodeIfPresent(Double.self, forKey: .sensitivityMultiplier) ?? a.sensitivityMultiplier
        a.scrollMultiplier = try c.decodeIfPresent(Double.self, forKey: .scrollMultiplier) ?? a.scrollMultiplier
        a.autoActivateBundleIDs = try c.decodeIfPresent([String].self, forKey: .autoActivateBundleIDs) ?? a.autoActivateBundleIDs
        a.dpadOneDirection = try c.decodeIfPresent(Bool.self, forKey: .dpadOneDirection)
        self = a
    }
}

/// A complete preset containing name, tag, and joystick mappings
/// One-stick "drive" mapping: turns a single analog stick into a full
/// vehicle control scheme the way a power wheelchair drives from one
/// joystick. Stick X steers, stick Y is throttle forward and brake back,
/// and a gesture (snapping the stick to the back wall a few times) shifts
/// between Drive and Reverse. Output is keyboard + mouse, so variable
/// throttle on a binary key is produced by fast on/off pulsing (PWM): the
/// further you push, the larger the share of each pulse cycle the key is
/// held, which most keyboard-driveable games read as proportional speed.
///
/// Every field has a default so older preset files (which have no
/// `driveConfig` key at all) decode cleanly.
struct DriveConfig: Codable, Hashable {
    /// Master switch. When false the engine ignores the whole block.
    var enabled: Bool = false
    /// Controller slot (0-3) the drive stick lives on.
    var slot: Int = 0
    /// Axis indices on that controller: X steers, Y is throttle/brake.
    var steerAxis: Int = 0
    var throttleAxis: Int = 1
    /// Some sticks report "up" as negative; flip per stick.
    var invertSteer: Bool = false
    var invertThrottle: Bool = false
    /// Center deadzone applied to both axes (0-1).
    var deadzone: Double = 0.12

    enum SteerMode: String, Codable, CaseIterable, Identifiable {
        case mouse, keys
        var id: String { rawValue }
        var displayName: String { self == .mouse ? "Mouse (analog)" : "Keys (A / D)" }
    }
    /// Steering output: analog mouse-X (smooth) or left/right keys (pulsed).
    var steerMode: SteerMode = .mouse
    /// Mouse pixels per frame at full lock when steerMode == .mouse.
    var steerMouseSpeed: Double = 18
    /// HID usage codes for key steering (default A / D).
    var steerLeftKey: Int = 4
    var steerRightKey: Int = 7

    /// HID usage codes for motion. Default W accelerate, S brake.
    var accelKey: Int = 26
    var brakeKey: Int = 22
    /// Key used to move while in Reverse gear. Defaults to the brake key
    /// (S), which many games treat as reverse once stopped.
    var reverseKey: Int = 22
    /// Response curve exponent for throttle (1 = linear, >1 = gentler off
    /// center for fine low-speed control).
    var throttleCurve: Double = 1.0
    /// Response curve exponent for steering (1 = linear, >1 = gentle center,
    /// progressive lock toward the edges).
    var steerCurve: Double = 1.0
    /// When true the throttle axis is a unipolar trigger that rests at one
    /// end (its whole range maps to forward; there is no backward, so the
    /// reverse gesture is disabled). When false it is a centered stick.
    var throttleIsTrigger: Bool = false
    /// Optional active slow-down: while the stick sits centered in Drive,
    /// hold the brake lightly so the vehicle decelerates instead of coasting,
    /// the way a power wheelchair stops when you release the stick. Off by
    /// default. `coastBrakeStrength` is the held brake duty (0-1).
    var coastBrake: Bool = false
    var coastBrakeStrength: Double = 0.5
    /// PWM cycle length in poll ticks (at 120 Hz, 6 ticks = 20 Hz pulsing).
    var pwmPeriodTicks: Int = 6

    /// Reverse gesture: snap the stick fully back `reverseTapCount` times
    /// within `reverseWindowMs` to shift into Reverse; push fully forward to
    /// shift back to Drive. `gestureThreshold` is the fraction of full
    /// deflection that counts as hitting the "wall".
    var reverseGestureEnabled: Bool = true
    var reverseTapCount: Int = 2
    var reverseWindowMs: Int = 700
    var gestureThreshold: Double = 0.85
}

extension DriveConfig {
    enum CodingKeys: String, CodingKey {
        case enabled, slot, steerAxis, throttleAxis, invertSteer, invertThrottle
        case deadzone, steerMode, steerMouseSpeed, steerLeftKey, steerRightKey
        case accelKey, brakeKey, reverseKey, throttleCurve, pwmPeriodTicks
        case reverseGestureEnabled, reverseTapCount, reverseWindowMs, gestureThreshold
        case steerCurve, throttleIsTrigger, coastBrake, coastBrakeStrength
    }

    /// Lenient decode: every field falls back to its default when missing.
    /// Without this, a present-but-partial `driveConfig` object (hand-edited
    /// file or a forward/backward schema change) would throw and take the
    /// whole Preset decode down with it, silently dropping the preset. The
    /// default `init()` (all defaults) and memberwise init stay available
    /// because this lives in an extension. Matches the rest of the model.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var d = DriveConfig()
        d.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        d.slot = try c.decodeIfPresent(Int.self, forKey: .slot) ?? d.slot
        d.steerAxis = try c.decodeIfPresent(Int.self, forKey: .steerAxis) ?? d.steerAxis
        d.throttleAxis = try c.decodeIfPresent(Int.self, forKey: .throttleAxis) ?? d.throttleAxis
        d.invertSteer = try c.decodeIfPresent(Bool.self, forKey: .invertSteer) ?? d.invertSteer
        d.invertThrottle = try c.decodeIfPresent(Bool.self, forKey: .invertThrottle) ?? d.invertThrottle
        d.deadzone = try c.decodeIfPresent(Double.self, forKey: .deadzone) ?? d.deadzone
        // try?: a steering mode added by a newer build falls back to the default.
        d.steerMode = ((try? c.decodeIfPresent(SteerMode.self, forKey: .steerMode)) ?? nil) ?? d.steerMode
        d.steerMouseSpeed = try c.decodeIfPresent(Double.self, forKey: .steerMouseSpeed) ?? d.steerMouseSpeed
        d.steerLeftKey = try c.decodeIfPresent(Int.self, forKey: .steerLeftKey) ?? d.steerLeftKey
        d.steerRightKey = try c.decodeIfPresent(Int.self, forKey: .steerRightKey) ?? d.steerRightKey
        d.accelKey = try c.decodeIfPresent(Int.self, forKey: .accelKey) ?? d.accelKey
        d.brakeKey = try c.decodeIfPresent(Int.self, forKey: .brakeKey) ?? d.brakeKey
        d.reverseKey = try c.decodeIfPresent(Int.self, forKey: .reverseKey) ?? d.reverseKey
        d.throttleCurve = try c.decodeIfPresent(Double.self, forKey: .throttleCurve) ?? d.throttleCurve
        d.pwmPeriodTicks = try c.decodeIfPresent(Int.self, forKey: .pwmPeriodTicks) ?? d.pwmPeriodTicks
        d.reverseGestureEnabled = try c.decodeIfPresent(Bool.self, forKey: .reverseGestureEnabled) ?? d.reverseGestureEnabled
        d.reverseTapCount = try c.decodeIfPresent(Int.self, forKey: .reverseTapCount) ?? d.reverseTapCount
        d.reverseWindowMs = try c.decodeIfPresent(Int.self, forKey: .reverseWindowMs) ?? d.reverseWindowMs
        d.gestureThreshold = try c.decodeIfPresent(Double.self, forKey: .gestureThreshold) ?? d.gestureThreshold
        d.steerCurve = try c.decodeIfPresent(Double.self, forKey: .steerCurve) ?? d.steerCurve
        d.throttleIsTrigger = try c.decodeIfPresent(Bool.self, forKey: .throttleIsTrigger) ?? d.throttleIsTrigger
        d.coastBrake = try c.decodeIfPresent(Bool.self, forKey: .coastBrake) ?? d.coastBrake
        d.coastBrakeStrength = try c.decodeIfPresent(Double.self, forKey: .coastBrakeStrength) ?? d.coastBrakeStrength
        self = d
    }
}

struct Preset: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var tag: String
    var joysticks: [JoystickMapping]
    var filename: String
    var isActive: Bool
    var createdAt: Date
    var modifiedAt: Date
    /// Optional group this preset belongs to in the sidebar. `nil` means
    /// the preset shows in the default "Ungrouped" section. Codable safe -
    /// older preset files without this key just decode with `nil` here.
    var groupID: UUID?
    /// Free-form per-preset notes shown on the detail page. Stays empty
    /// unless the user writes something. Codable-optional so older preset
    /// files decode without the field.
    var notes: String = ""

    /// The regions this preset draws: zones on the DualSense touchpad, areas
    /// of the screen for the pointer, and zones on each stick (keyed by stick
    /// index as a string, "0" left and "1" right). They belong to the preset
    /// and travel with it in the file. The region services only ever hold
    /// the copies of the preset that is running or being edited.
    var touchpadRegions: [TouchpadRegion] = []
    var cursorRegions: [TouchpadRegion] = []
    var stickRegions: [String: [TouchpadRegion]] = [:]
    /// Written with every save; see `currentFormatVersion`.
    var formatVersion: Int = Preset.currentFormatVersion
    /// The version the file it was read from said, for telling a file
    /// written before 1.6 on import. Not saved.
    var writtenByFormatVersion: Int = Preset.currentFormatVersion
    /// Explicit position among its siblings (same folder, or ungrouped).
    ///
    /// `nil` means "this file predates manual ordering". Those presets fall
    /// back to newest-modified-first, exactly as before, and are assigned a
    /// real value the first time the library loads, so old preset files keep
    /// working and keep their familiar order.
    var sortOrder: Int?
    /// System-wide chord that switches to this preset. Pressing it while
    /// this preset is already the active one stops it instead. Optional, so
    /// presets saved before this existed decode unchanged.
    var activateHotKey: HotKeySpec?
    /// RGB light-bar color override stored as 0-255 components. When non-nil
    /// the mapping engine paints the controller's light bar with this color
    /// while the preset is active, and reverts to the slot's general color
    /// when the preset stops. Optional so older files decode cleanly.
    var lightBarColor: RGBLightColor?
    /// Brightness override applied alongside `lightBarColor` (0 = off,
    /// 1 = dim, 2 = bright). nil = inherit the slot's current brightness.
    var lightBarBrightness: Int?
    /// Rainbow (the RGB cycle) on the light bar while the preset runs, in
    /// place of `lightBarColor`. nil or false: no rainbow. Optional so
    /// older files decode unchanged.
    var lightBarRainbow: Bool?
    /// How fast that rainbow cycles: 1 is one full loop every 3 seconds,
    /// the same scale as the controller menu's speed slider
    /// (`lightBarRainbowSpeedRange`). nil is 1.
    var lightBarRainbowSpeed: Double?
    /// The speed slider's range, which a file's value is held to.
    static let lightBarRainbowSpeedRange: ClosedRange<Double> = 0.25...6.0

    /// Per-preset automation: cursor confine + recenter, hide cursor,
    /// auto-open an application on activate. Lives on the preset (not
    /// global Settings) because these are inherently per-game choices -
    /// the cursor confinement for an FPS preset shouldn't follow you
    /// into a desktop-tool preset. Optional so older preset files
    /// decode cleanly with defaults.
    var automation: PresetAutomation = PresetAutomation()

    /// The controller family this preset is made for (Xbox, PlayStation,
    /// Nintendo). Its face and menu buttons are named and drawn that way in
    /// the Live Visualizer and the editor, whatever pad is connected. nil
    /// (or Automatic) follows the connected controller and Settings.
    /// Optional, so older preset files decode unchanged.
    var buttonFamily: FaceLetters?
    /// The family in place before the Live Visualizer's Controller menu
    /// first set one, so Automatic can put it back: nil when nothing is
    /// held, "" for none, else the family's raw value.
    var familyBeforeModel: String?

    /// One-stick driving scheme for this preset. nil / disabled for the
    /// vast majority of presets; opt-in per game. Optional so older preset
    /// files decode cleanly.
    var driveConfig: DriveConfig?

    /// Top-level fields and joystick groups this build could not read
    /// (written by a newer version), kept as they were and written back on
    /// save so a round trip through this build does not delete them.
    var extraFields: [String: JSONValue] = [:]
    var unreadableJoysticks: [JSONValue] = []

    init(name: String = "New Preset", tag: String = "No tag", joysticks: [JoystickMapping] = [],
         filename: String = "", isActive: Bool = false, groupID: UUID? = nil) {
        self.id = UUID()
        self.name = name
        self.tag = tag
        self.joysticks = joysticks
        self.filename = filename.isEmpty ? Preset.generateFilename() : filename
        self.isActive = isActive
        self.createdAt = Date()
        self.modifiedAt = Date()
        self.groupID = groupID
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, tag, joysticks, filename, isActive, createdAt, modifiedAt
        case groupID, notes, lightBarColor, lightBarBrightness, automation, driveConfig
        case sortOrder
        case touchpadRegions, cursorRegions, stickRegions
        // Was missing here, so the synthesized encode(to:) silently dropped
        // every per-preset shortcut on save and init(from:) never read one
        // back. Setting a preset shortcut appeared to work and then did
        // nothing, because it never reached disk.
        case activateHotKey
        case formatVersion
        case buttonFamily
        case familyBeforeModel
        case lightBarRainbow, lightBarRainbowSpeed
    }

    /// The on-disk format this file was written in. Absent means 1. Read
    /// so a later change of meaning has somewhere to branch, and so a much
    /// newer file can be recognized instead of misread.
    /// 2 from 1.6: a file with less was written before 1.6, so an import
    /// gets the 1.6 upgrades and the Switch and 8BitDo row check. 1.5
    /// reads a newer version as far as it understands it.
    static let currentFormatVersion = 2

    /// Custom Codable init so older preset files without `notes`,
    /// `lightBarColor`, or `lightBarBrightness` keys still decode cleanly
    /// (the synthesized Codable would otherwise require every key).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        // Only the id and the name are genuinely required. Everything else
        // has a sensible default, so a hand-edited file or one written by a
        // build that stopped emitting a field still loads.
        self.tag = (try? c.decodeIfPresent(String.self, forKey: .tag)) ?? ""
        // One group at a time: a group this build cannot read is kept raw
        // instead of making the whole preset unreadable.
        var groups: [JoystickMapping] = []
        var rawGroups: [JSONValue] = []
        if var list = try? c.nestedUnkeyedContainer(forKey: .joysticks) {
            while !list.isAtEnd {
                if let group = try? list.decode(JoystickMapping.self) {
                    groups.append(group)
                } else if let raw = try? list.decode(JSONValue.self) {
                    rawGroups.append(raw)
                } else {
                    break
                }
            }
        }
        // Row ids are unique across the whole preset too: the engine keys
        // per-row state by id alone, so a slot copied by hand shared its
        // toggles and held keys with the slot it came from.
        var seenRowIDs = Set<UUID>()
        for g in groups.indices {
            for r in groups[g].bindings.indices where !seenRowIDs.insert(groups[g].bindings[r].id).inserted {
                groups[g].bindings[r].id = UUID()
            }
        }
        self.joysticks = groups
        self.unreadableJoysticks = rawGroups
        self.filename = try c.decodeIfPresent(String.self, forKey: .filename) ?? "\(id.uuidString).json"
        self.isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
        // Dates are metadata and never block a load: a file written by
        // another tool (or edited by hand) may carry ISO 8601 strings, which
        // failed the whole import as "doesn't match the preset schema".
        func date(_ key: CodingKeys) -> Date? {
            if let d = try? c.decodeIfPresent(Date.self, forKey: key) { return d }
            guard let text = try? c.decodeIfPresent(String.self, forKey: key) else { return nil }
            let iso = ISO8601DateFormatter()
            if let d = iso.date(from: text) { return d }
            iso.formatOptions.insert(.withFractionalSeconds)
            return iso.date(from: text)
        }
        self.createdAt = date(.createdAt) ?? Date()
        self.modifiedAt = date(.modifiedAt) ?? createdAt
        let version = (try? c.decodeIfPresent(Int.self, forKey: .formatVersion)) ?? 1
        // A newer file keeps its version: what this build does not
        // understand is written back unchanged (see extraFields), so the
        // newer build still recognizes its own file.
        self.formatVersion = max(version, Self.currentFormatVersion)
        self.writtenByFormatVersion = version
        if version > Self.currentFormatVersion {
            NSLog("Preset \(name): written by a newer format (\(version)); reading what this build understands")
        }
        self.groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
        self.notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        // Optional parts decode leniently: one field a newer build shaped
        // differently must not make the whole preset unreadable.
        self.lightBarColor = (try? c.decodeIfPresent(RGBLightColor.self, forKey: .lightBarColor)) ?? nil
        self.lightBarBrightness = (try? c.decodeIfPresent(Int.self, forKey: .lightBarBrightness)) ?? nil
        self.lightBarRainbow = (try? c.decodeIfPresent(Bool.self, forKey: .lightBarRainbow)) ?? nil
        self.lightBarRainbowSpeed = (try? c.decodeIfPresent(Double.self, forKey: .lightBarRainbowSpeed)) ?? nil
        self.automation = ((try? c.decodeIfPresent(PresetAutomation.self, forKey: .automation)) ?? nil)
            ?? PresetAutomation()
        self.driveConfig = (try? c.decodeIfPresent(DriveConfig.self, forKey: .driveConfig)) ?? nil
        self.activateHotKey = (try? c.decodeIfPresent(HotKeySpec.self, forKey: .activateHotKey)) ?? nil
        self.sortOrder = (try? c.decodeIfPresent(Int.self, forKey: .sortOrder)) ?? nil
        self.touchpadRegions = try c.decodeIfPresent([TouchpadRegion].self, forKey: .touchpadRegions) ?? []
        self.cursorRegions = try c.decodeIfPresent([TouchpadRegion].self, forKey: .cursorRegions) ?? []
        self.stickRegions = try c.decodeIfPresent([String: [TouchpadRegion]].self, forKey: .stickRegions) ?? [:]
        // try?: a family written by a newer build must not stop the preset loading.
        self.buttonFamily = (try? c.decodeIfPresent(FaceLetters.self, forKey: .buttonFamily)) ?? nil
        // Kept as written, so saving here does not drop it; a family picked
        // in this build replaces it (see encode).
        if buttonFamily == nil, let raw = try? c.decodeIfPresent(JSONValue.self, forKey: .buttonFamily) {
            extraFields[CodingKeys.buttonFamily.stringValue] = raw
        }
        self.familyBeforeModel = (try? c.decodeIfPresent(String.self, forKey: .familyBeforeModel)) ?? nil

        // Keep any field this build has no key for.
        let known = Set(CodingKeys.allCases.map(\.stringValue))
        if let all = try? decoder.container(keyedBy: AnyCodingKey.self) {
            for key in all.allKeys where !known.contains(key.stringValue) {
                if let value = try? all.decode(JSONValue.self, forKey: key) {
                    extraFields[key.stringValue] = value
                }
            }
        }        // A hostile or damaged file cannot carry a value that traps later
        // (a negative controller slot, an infinite deadzone, a huge number).
        clampInPlace()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(tag, forKey: .tag)
        var list = c.nestedUnkeyedContainer(forKey: .joysticks)
        for group in joysticks { try list.encode(group) }
        for raw in unreadableJoysticks { try list.encode(raw) }
        try c.encode(filename, forKey: .filename)
        try c.encode(isActive, forKey: .isActive)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(modifiedAt, forKey: .modifiedAt)
        try c.encodeIfPresent(groupID, forKey: .groupID)
        try c.encode(notes, forKey: .notes)
        try c.encodeIfPresent(lightBarColor, forKey: .lightBarColor)
        try c.encodeIfPresent(lightBarBrightness, forKey: .lightBarBrightness)
        try c.encodeIfPresent(lightBarRainbow, forKey: .lightBarRainbow)
        try c.encodeIfPresent(lightBarRainbowSpeed, forKey: .lightBarRainbowSpeed)
        try c.encode(automation, forKey: .automation)
        try c.encodeIfPresent(driveConfig, forKey: .driveConfig)
        try c.encodeIfPresent(sortOrder, forKey: .sortOrder)
        try c.encode(touchpadRegions, forKey: .touchpadRegions)
        try c.encode(cursorRegions, forKey: .cursorRegions)
        try c.encode(stickRegions, forKey: .stickRegions)
        try c.encodeIfPresent(activateHotKey, forKey: .activateHotKey)
        try c.encode(formatVersion, forKey: .formatVersion)
        try c.encodeIfPresent(buttonFamily, forKey: .buttonFamily)
        try c.encodeIfPresent(familyBeforeModel, forKey: .familyBeforeModel)
        if !extraFields.isEmpty {
            var extra = encoder.container(keyedBy: AnyCodingKey.self)
            for (key, value) in extraFields
            where !(key == CodingKeys.buttonFamily.stringValue && buttonFamily != nil) {
                try extra.encode(value, forKey: AnyCodingKey(key))
            }
        }
    }

    // MARK: - Regions and the services

    /// Hand this preset's regions to the services, which is what makes
    /// them the ones the engine tests against and the editor shows.
    /// Which preset's regions the shared services are holding right now.
    /// The services are one working set shared by the running preset and
    /// the editor, so whoever loaded last owns them. Capturing without
    /// checking this wrote preset C's zones into preset A's file when a
    /// hotkey switched presets while A's editor was open.
    @MainActor
    static var regionWorkingSetOwner: UUID?

    @MainActor
    func applyRegionsToServices() {
        TouchpadService.shared.load(touchpadRegions)
        CursorRegionService.shared.load(cursorRegions)
        var byStick: [Int: [TouchpadRegion]] = [0: [], 1: []]
        for (key, list) in stickRegions { if let i = Int(key) { byStick[i] = list } }
        StickRegionService.shared.load(byStick)
        Self.regionWorkingSetOwner = id
    }

    /// Take whatever the services hold back into this preset; the editor
    /// calls it on Save after the region editors have been at work. Only
    /// when the working set is still this preset's: if another preset was
    /// loaded in the meantime, this preset keeps the regions it already
    /// has rather than adopting a stranger's.
    @MainActor
    mutating func captureRegionsFromServices() {
        guard Self.regionWorkingSetOwner == id else {
            ActivityLog.shared.warning("Presets", "Kept \(name)'s own regions on save: another preset's regions were loaded in the meantime")
            return
        }
        touchpadRegions = TouchpadService.shared.allRegions()
        cursorRegions = CursorRegionService.shared.allRegions()
        var keyed: [String: [TouchpadRegion]] = [:]
        for (i, list) in StickRegionService.shared.regionsByStick where !list.isEmpty { keyed["\(i)"] = list }
        stickRegions = keyed
    }

    /// Region ids the bindings refer to, by kind, for the migration that
    /// moves old app-wide regions into the presets that use them.
    var referencedRegionIDs: (touchpad: Set<UUID>, cursor: Set<UUID>, stick: Set<UUID>) {
        var t = Set<UUID>(), c = Set<UUID>(), st = Set<UUID>()
        for j in joysticks { for b in j.bindings {
            if let id = b.input.touchpadRegionID { t.insert(id) }
            if let id = b.input.cursorRegionID { c.insert(id) }
            if let id = b.input.stickRegionID { st.insert(id) }
        } }
        return (t, c, st)
    }

    static func generateFilename() -> String {
        // Use a fresh UUID so two presets generated in the same second can't
        // collide on disk. Previously the format was "yyyyMMdd_HH-mm-ss.json",
        // which clobbered all-but-the-last-seeded preset during fresh-install
        // seeding (22 presets land within the same second).
        return UUID().uuidString + ".json"
    }

    /// Sort all bindings in all joystick groups alphabetically by
    /// input type then index. Every InputType must appear in the
    /// type-order table so new input categories (motion, touchpad,
    /// external key/mouse, cursor region, MIDI) don't all silently
    /// collapse to `0` and intermix with buttons in the editor list.
    /// Whether activating this preset produces any output: it has at least
    /// one binding, or one-stick driving is enabled. Menu-bar activation and
    /// the engine both gate on this, so a pure drive preset stays reachable.
    var isRunnable: Bool {
        joysticks.contains { !$0.bindings.isEmpty } || driveConfig?.enabled == true
    }

    mutating func sortBindings() {
        for i in joysticks.indices {
            // Within each section, sections kept in their order.
            var sectionRank: [String: Int] = [:]
            for row in joysticks[i].bindings where sectionRank[row.section ?? ""] == nil {
                sectionRank[row.section ?? ""] = sectionRank.count
            }
            joysticks[i].bindings.sort { a, b in
                let sa = sectionRank[a.section ?? ""] ?? 0, sb = sectionRank[b.section ?? ""] ?? 0
                if sa != sb { return sa < sb }
                let aType = Self.sortOrder(for: a.input.type)
                let bType = Self.sortOrder(for: b.input.type)
                if aType != bType { return aType < bType }
                if a.input.index != b.input.index { return a.input.index < b.input.index }
                return Self.directionRank(a.input) < Self.directionRank(b.input)
            }
        }
    }

    /// The order of rows on one input that differ only by direction: an
    /// axis minus before plus, the D-pad up, down, left, right, touch by
    /// finger then axis. Without it they kept whatever order they came in,
    /// which for the built-ins was a dictionary's, different on every launch.
    static func directionRank(_ e: InputEvent) -> Int {
        let dir = e.axisDirection == .negative ? 0 : (e.axisDirection == .positive ? 1 : 2)
        switch e.type {
        case .hat:
            switch e.hatDirection {
            case .up?: return 0
            case .down?: return 1
            case .left?: return 2
            case .right?: return 3
            case nil: return 4
            }
        case .touchpad:
            // Clamped: a hostile file's huge finger number must not overflow.
            return min(max(e.touchpadFinger ?? 0, 0), 9) * 6 + (e.touchpadAxis == .y ? 3 : 0) + dir
        default:
            return dir
        }
    }

    /// Authoritative type-sort order. Every InputType case is listed
    /// so the comparator never falls through to a default of 0.
    private static func sortOrder(for type: InputType) -> Int {
        switch type {
        case .button:          return 0
        case .axis:            return 1
        case .hat:             return 2
        case .touchpad:        return 3
        case .touchpadRegion:  return 4
        case .touchpadGesture: return 5
        case .motion:          return 6
        case .extKey:          return 7
        case .extMouse:        return 8
        case .cursorRegion:    return 9
        case .stickRegion:     return 10
        case .midi:            return 11
        case .chassisTap:      return 12
        }
    }
}

extension Preset {
    /// The same preset under a fresh id and file name, every field kept.
    /// `id` is immutable, so the id is swapped through a Codable round trip.
    func withNewIdentity() -> Preset {
        var copy = self
        copy.filename = Preset.generateFilename()
        copy.isActive = false
        if let data = try? JSONEncoder().encode(copy),
           var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            dict["id"] = UUID().uuidString
            if let patched = try? JSONSerialization.data(withJSONObject: dict),
               let fresh = try? JSONDecoder().decode(Preset.self, from: patched) {
                return fresh
            }
        }
        return Preset(name: copy.name, tag: copy.tag, joysticks: copy.joysticks,
                      filename: copy.filename, isActive: false, groupID: copy.groupID)
    }
}

// MARK: - Import safety

extension OutputAction {
    /// Opens an app, a URL, or a Shortcut, or types text: things a shared
    /// preset should not do on a first press without the user having seen
    /// them. Spotlight and Launchpad count too, since a macro of Spotlight
    /// and a few keys opens any app.
    var opensSomething: Bool {
        if type == .typeText { return true }
        // A light bar color (and everything else outside System Functions)
        // opens nothing.
        guard type == .systemAction, let kind = systemActionKind else { return false }
        return kind == .runShortcut || kind == .openApp || kind == .openURL
            || kind == .spotlight || kind == .launchpad
    }

    /// Worth listing when a preset is imported: anything that opens
    /// something, and Type Text.
    var isAutomationAction: Bool { opensSomething || type == .typeText }

    /// Lock Screen and switching presets: listed on import, not removed.
    var isNotableOnImport: Bool {
        (type == .systemAction && systemActionKind == .lockScreen) || type == .appAction
    }

    /// One line for the import review, every character of it: a newline
    /// shows as a return mark, and a website shows its host first, since
    /// "https://good.example...@evil.invalid" names its real host last.
    var importReviewLine: String {
        let detail = (text ?? "").replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: " \u{21B5} ")
            .trimmingCharacters(in: .whitespaces)
        switch type {
        case .typeText:
            return detail.isEmpty ? "Types text" : "Types text: \(detail)"
        case .systemAction where systemActionKind == .openURL:
            let host = URL(string: (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines))?.host ?? "no host"
            return "Opens website on \(host): \(detail)"
        default:
            let what = type == .systemAction ? (systemActionKind?.displayName ?? "Action") : displayName
            return detail.isEmpty ? what : "\(what): \(detail)"
        }
    }
}

/// Command and Space, the Spotlight chord, in a row's outputs or a macro:
/// Spotlight and a few typed keys open any app, so it counts as an opener.
enum SpotlightChord {
    static let command: Set<Int> = [227, 231]
    static let space = 44
    static func inOutputs(_ outputs: [OutputAction]) -> Bool {
        let keys = Set(outputs.filter { $0.type == .key }.compactMap(\.keyCode))
        return keys.contains(space) && !keys.isDisjoint(with: command)
    }
    static func inMacro(_ steps: [MacroStep]) -> Bool {
        let commandStep = steps.contains { $0.action.type == .key && command.contains($0.action.keyCode ?? -1) }
        return steps.contains { step in
            step.action.type == .key && step.action.keyCode == space
                && (commandStep || !Set(step.modifiers ?? []).isDisjoint(with: command))
        }
    }
}

extension Preset {
    /// Every output in the preset: row outputs, hold and double-tap
    /// outputs, and macro steps.
    var allOutputs: [OutputAction] {
        var out: [OutputAction] = []
        for group in joysticks {
            for row in group.bindings {
                out += row.outputs
                out += row.holdOutputs ?? []
                out += row.doubleTapOutputs ?? []
                for step in row.macroSteps ?? [] { out.append(step.action) }
            }
        }
        return out
    }

    /// Whether running this preset needs the Accessibility permission: any
    /// output that posts a key, click, pointer move, scroll, or typed text
    /// (row, hold, double-tap, and macro outputs alike, and the system
    /// actions that work by posting a key), any Mac keyboard or mouse
    /// input, which is read through the same permission, and drive mode.
    var needsAccessibility: Bool {
        let quiet: Set<SystemActionKind> = [.openApp, .openURL, .runShortcut, .volumeUp, .volumeDown,
                                            .missionControl, .launchpad]
        let postsEvents = allOutputs.contains { output in
            switch output.type {
            case .key, .mouseButton, .mouseMotion, .mouseWheel, .mouseWheelStep, .typeText:
                return true
            case .systemAction:
                return !(output.systemActionKind.map(quiet.contains) ?? true)
            case .lightBar:
                // Writes to the controller, posts no event.
                return false
            default:
                return false
            }
        }
        if postsEvents || driveConfig?.enabled == true { return true }
        return joysticks.contains { group in
            group.bindings.contains { row in
                ([row.input] + row.modifiers).contains { $0.type == .extKey || $0.type == .extMouse }
            }
        }
    }

    /// Outputs an import review should show the user.
    var automationOutputs: [OutputAction] { allOutputs.filter(\.isAutomationAction) }

    /// Longest Type Text an import keeps.
    static let importTextLimit = 10_000

    /// Whether any row sends the Spotlight chord (row outputs or a macro).
    var hasSpotlightChord: Bool {
        joysticks.contains { g in
            g.bindings.contains { r in
                SpotlightChord.inOutputs(r.outputs) || SpotlightChord.inOutputs(r.holdOutputs ?? [])
                    || SpotlightChord.inOutputs(r.doubleTapOutputs ?? []) || SpotlightChord.inMacro(r.macroSteps ?? [])
            }
        }
    }

    /// Every macro, for the import review: its input and each step.
    var importMacroLines: [String] {
        joysticks.flatMap { g in
            g.bindings.compactMap { r -> String? in
                guard let steps = r.macroSteps, !steps.isEmpty else { return nil }
                let list = steps.map { step -> String in
                    let mods = (step.modifiers ?? []).map { KeyCodeMap.name(for: $0) }
                    let name = step.action.type == .typeText || step.action.type == .systemAction
                        ? step.action.importReviewLine : step.action.displayName
                    return (mods + [name]).joined(separator: " ")
                }
                return "Macro on \(r.input.displayName), \(steps.count) steps: " + list.joined(separator: ", ")
            }
        }
    }

    /// What the preset does to the pointer and drive mode, for the review.
    var importPointerLine: String? {
        var parts: [String] = []
        if automation.hideCursorWhileActive { parts.append("hides the pointer") }
        if automation.confineCursor { parts.append("keeps the pointer away from the screen edges") }
        if automation.autoRecenterCursor {
            parts.append("moves the pointer to the middle of the screen every \(Int(automation.autoRecenterIntervalMs)) ms")
        }
        if automation.sensitivityMultiplier != 1 { parts.append(String(format: "sets pointer speed to %.2fx", automation.sensitivityMultiplier)) }
        if automation.scrollMultiplier != 1 { parts.append(String(format: "sets scroll speed to %.2fx", automation.scrollMultiplier)) }
        if driveConfig?.enabled == true { parts.append("turns on drive mode, which holds keys from a stick") }
        guard !parts.isEmpty else { return nil }
        return "While running it " + parts.joined(separator: ", ") + "."
    }

    /// A preset from a file, made safe to add to the library: never marked
    /// running, no auto-launch app or URL, no automatic switching when an
    /// app comes to the front, no place in the sidebar order yet, and,
    /// when asked, without outputs that open apps, URLs, or Shortcuts.
    /// The preset's own hotkey is checked against the library by the store.
    func sanitizedForImport(removingOpeners: Bool, removingPointerSettings: Bool = false) -> Preset {
        var p = self
        // Typed text has no use past a few pages, and posting a huge one
        // held the main thread.
        for g in p.joysticks.indices {
            for r in p.joysticks[g].bindings.indices {
                func capped(_ o: OutputAction) -> OutputAction {
                    guard o.type == .typeText, let t = o.text, t.count > Self.importTextLimit else { return o }
                    var c = o
                    c.text = String(t.prefix(Self.importTextLimit))
                    return c
                }
                var row = p.joysticks[g].bindings[r]
                row.outputs = row.outputs.map(capped)
                row.holdOutputs = row.holdOutputs?.map(capped)
                row.doubleTapOutputs = row.doubleTapOutputs?.map(capped)
                row.macroSteps = row.macroSteps?.map { var s = $0; s.action = capped(s.action); return s }
                p.joysticks[g].bindings[r] = row
            }
        }
        if removingPointerSettings {
            // Hide, confine and recenter the pointer, its speed, and drive
            // mode act on the whole Mac as soon as the preset starts.
            p.automation.confineCursor = false
            p.automation.autoRecenterCursor = false
            p.automation.hideCursorWhileActive = false
            p.automation.sensitivityMultiplier = 1
            p.automation.scrollMultiplier = 1
            p.driveConfig?.enabled = false
        }
        p.isActive = false
        p.sortOrder = nil
        // The light bar's rainbow is the preset's look, like its color, and
        // comes along; its speed is held to the slider's range.
        p.lightBarRainbowSpeed = Self.clampedRainbowSpeed(p.lightBarRainbowSpeed)
        p.automation.launchAppPath = ""
        p.automation.launchURL = ""
        p.automation.autoActivateBundleIDs = nil
        // Nor the sharer's own system-wide shortcut: registered here unseen,
        // it took that chord from every app (a Command V one stopped paste).
        p.activateHotKey = nil
        // Device fingerprints only mean something on the Mac that made them.
        for g in p.joysticks.indices { p.joysticks[g].deviceFingerprint = nil }
        // Rows, groups and fields this build cannot read are not carried
        // in: they could hold an app or website opener that the review
        // below cannot show or remove, and a later build would run it.
        for g in p.joysticks.indices {
            p.joysticks[g].unreadableRows = []
            p.joysticks[g].extraFields = [:]
        }
        p.unreadableJoysticks = []
        p.extraFields = [:]
        if removingOpeners {
            for g in p.joysticks.indices {
                for r in p.joysticks[g].bindings.indices {
                    var row = p.joysticks[g].bindings[r]
                    // The Spotlight chord goes with them: its Space key.
                    func noSpotlight(_ list: [OutputAction]) -> [OutputAction] {
                        SpotlightChord.inOutputs(list) ? list.filter { !($0.type == .key && $0.keyCode == SpotlightChord.space) } : list
                    }
                    row.outputs = noSpotlight(row.outputs.filter { !$0.opensSomething })
                    row.holdOutputs = row.holdOutputs.map { noSpotlight($0.filter { !$0.opensSomething }) }
                    row.doubleTapOutputs = row.doubleTapOutputs.map { noSpotlight($0.filter { !$0.opensSomething }) }
                    row.macroSteps?.removeAll(where: { $0.action.opensSomething })
                    // A macro that opens Spotlight and types goes whole.
                    if let steps = row.macroSteps, SpotlightChord.inMacro(steps) { row.macroSteps = nil }
                    // No steps left is no macro: an empty list pressed the
                    // row's output and never let it go.
                    if row.macroSteps?.isEmpty == true { row.macroSteps = nil }
                    p.joysticks[g].bindings[r] = row
                }
            }
        }
        return p
    }
}

// MARK: - Legacy Format Support (Joystick Mapper JSON)

extension Preset {
    /// Parse from legacy Joystick Mapper JSON format
    static func fromLegacyJSON(_ data: Data, filename: String = "") -> Preset? {
        // Only the legacy shape: a "joysticks" list whose entries carry
        // "binds". Any other JSON object (a backup, a preset from a newer
        // build, an unrelated file) used to become an empty preset that
        // looked ready to import.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["joysticks"] as? [[String: Any]],
              list.contains(where: { $0["binds"] is [String: [String]] }) else {
            return nil
        }

        let name = json["name"] as? String ?? "Imported Preset"
        let tag = json["tag"] as? String ?? "No tag"

        var joystickMappings: [JoystickMapping] = []

        if let joysticks = json["joysticks"] as? [[String: Any]] {
            for joystick in joysticks {
                let joyTag = joystick["tag"] as? String ?? ""
                var bindings: [BindingModel] = []

                if let binds = joystick["binds"] as? [String: [String]] {
                    for (inputStr, outputStrs) in binds {
                        guard let input = InputEvent.parse(inputStr) else { continue }
                        let outputs = outputStrs.compactMap { OutputAction.parse($0) }
                        bindings.append(BindingModel(input: input, outputs: outputs))
                    }
                }

                // Sort bindings by type then index. Uses the same
                // authoritative order as sortBindings() so legacy
                // import doesn't end up with a different layout than
                // the editor would have produced.
                bindings.sort { a, b in
                    let aOrder = Self.sortOrder(for: a.input.type)
                    let bOrder = Self.sortOrder(for: b.input.type)
                    if aOrder != bOrder { return aOrder < bOrder }
                    if a.input.index != b.input.index { return a.input.index < b.input.index }
                    let ra = Self.directionRank(a.input), rb = Self.directionRank(b.input)
                    if ra != rb { return ra < rb }
                    return a.input.serialized < b.input.serialized
                }

                joystickMappings.append(JoystickMapping(tag: joyTag, bindings: bindings))
            }
        }

        // Nothing this build could read is not a preset.
        guard joystickMappings.contains(where: { !$0.bindings.isEmpty }) else { return nil }
        return Preset(name: name, tag: tag, joysticks: joystickMappings, filename: filename)
    }
}

// MARK: - Controller Type Conversion

/// Known controller types for preset conversion
enum ControllerType: String, CaseIterable, Identifiable {
    case xbox360 = "Xbox 360"
    case xboxOne = "Xbox One"
    case xboxSeries = "Xbox Series"
    case ps3 = "PS3"
    case ps4 = "PS4"
    case ps5 = "PS5"
    case switchPro = "Switch Pro"
    case generic = "Generic"

    var id: String { rawValue }

    /// The family a preset converted to this type names its buttons in.
    var buttonFamily: FaceLetters? {
        switch self {
        case .xbox360, .xboxOne, .xboxSeries: return .xbox
        case .ps3, .ps4, .ps5: return .playstation
        case .switchPro: return .nintendo
        case .generic: return nil
        }
    }

    /// Standard button/axis mapping for this controller type.
    /// Uses GCController extended gamepad indices.
    var standardMapping: [String: String] {
        let keys = ["a", "b", "x", "y", "lb", "rb", "lt", "rt",
                     "lclick", "rclick", "back", "start", "home",
                     "dpad_up", "dpad_down", "dpad_left", "dpad_right",
                     "ls_up", "ls_down", "ls_left", "ls_right",
                     "rs_up", "rs_down", "rs_left", "rs_right"]

        let values: [String]
        switch self {
        case .xbox360:
            values = ["btn 0", "btn 1", "btn 2", "btn 3",
                      "btn 4", "btn 5", "axi 4 +", "axi 5 +",
                      "btn 11", "btn 12", "btn 8", "btn 9", "btn 10",
                      "hat 0 U", "hat 0 D", "hat 0 L", "hat 0 R",
                      "axi 1 -", "axi 1 +", "axi 0 -", "axi 0 +",
                      "axi 3 -", "axi 3 +", "axi 2 -", "axi 2 +"]
        case .xboxOne, .xboxSeries:
            values = ["btn 0", "btn 1", "btn 2", "btn 3",
                      "btn 4", "btn 5", "axi 4 +", "axi 5 +",
                      "btn 11", "btn 12", "btn 8", "btn 9", "btn 10",
                      "hat 0 U", "hat 0 D", "hat 0 L", "hat 0 R",
                      "axi 1 -", "axi 1 +", "axi 0 -", "axi 0 +",
                      "axi 3 -", "axi 3 +", "axi 2 -", "axi 2 +"]
        case .ps3:
            values = ["btn 0", "btn 1", "btn 2", "btn 3",
                      "btn 4", "btn 5", "axi 4 +", "axi 5 +",
                      "btn 11", "btn 12", "btn 8", "btn 9", "btn 10",
                      "hat 0 U", "hat 0 D", "hat 0 L", "hat 0 R",
                      "axi 1 -", "axi 1 +", "axi 0 -", "axi 0 +",
                      "axi 3 -", "axi 3 +", "axi 2 -", "axi 2 +"]
        case .ps4, .ps5:
            // PS layout: Cross=btn0, Circle=btn1, Square=btn2, Triangle=btn3
            values = ["btn 0", "btn 1", "btn 2", "btn 3",
                      "btn 4", "btn 5", "axi 4 +", "axi 5 +",
                      "btn 11", "btn 12", "btn 8", "btn 9", "btn 10",
                      "hat 0 U", "hat 0 D", "hat 0 L", "hat 0 R",
                      "axi 1 -", "axi 1 +", "axi 0 -", "axi 0 +",
                      "axi 3 -", "axi 3 +", "axi 2 -", "axi 2 +"]
        case .switchPro:
            // Switch: B=btn0(confirm), A=btn1(cancel), Y=btn2, X=btn3
            values = ["btn 1", "btn 0", "btn 3", "btn 2",
                      "btn 4", "btn 5", "axi 4 +", "axi 5 +",
                      "btn 11", "btn 12", "btn 8", "btn 9", "btn 10",
                      "hat 0 U", "hat 0 D", "hat 0 L", "hat 0 R",
                      "axi 1 -", "axi 1 +", "axi 0 -", "axi 0 +",
                      "axi 3 -", "axi 3 +", "axi 2 -", "axi 2 +"]
        case .generic:
            values = ["btn 0", "btn 1", "btn 2", "btn 3",
                      "btn 4", "btn 5", "axi 4 +", "axi 5 +",
                      "btn 11", "btn 12", "btn 8", "btn 9", "btn 10",
                      "hat 0 U", "hat 0 D", "hat 0 L", "hat 0 R",
                      "axi 1 -", "axi 1 +", "axi 0 -", "axi 0 +",
                      "axi 3 -", "axi 3 +", "axi 2 -", "axi 2 +"]
        }

        var mapping: [String: String] = [:]
        for (key, value) in zip(keys, values) {
            mapping[key] = value
        }
        return mapping
    }

    /// Types a preset made for this one can be converted to with a real
    /// change. Every layout but Switch Pro shares one button map, so
    /// Xbox to PS5, say, changed nothing and only rewrote the tag.
    var conversionTargets: [ControllerType] { Self.targets[self] ?? [] }

    /// Worked out once: every sidebar row's Convert To menu asked for it on
    /// each redraw, building and comparing all the mapping tables each time.
    private static let targets: [ControllerType: [ControllerType]] = Dictionary(uniqueKeysWithValues:
        allCases.map { type in (type, allCases.filter { $0 != type && $0.standardMapping != type.standardMapping }) })

    /// Convert a preset from this controller type to another
    static func convert(preset: Preset, from source: ControllerType, to destination: ControllerType) -> Preset {
        let sourceMap = source.standardMapping
        let destMap = destination.standardMapping

        // Build reverse map: source input string -> standard key
        var reverseSource: [String: String] = [:]
        for (key, value) in sourceMap {
            reverseSource[value] = key
        }

        // The user's own name and tag stay as they are.
        var converted = preset

        for i in converted.joysticks.indices {
            var newBindings: [BindingModel] = []
            for binding in converted.joysticks[i].bindings {
                let inputStr = binding.input.serialized
                if let standardKey = reverseSource[inputStr],
                   let destInputStr = destMap[standardKey],
                   let newInput = InputEvent.parse(destInputStr) {
                    // Copy the whole row and swap only the input. The bare
                    // BindingModel(input:outputs:) initializer discards
                    // deadzone, toggle, turbo, macros, hold / double-tap,
                    // haptics, speech and the chord's modifier, so converting
                    // a preset between controller types silently gutted it.
                    var moved = binding.duplicated()
                    moved.input = newInput
                    // The chord's held controls move the same way, or a chord
                    // on a face button kept the old position (Switch B for
                    // the Xbox A it meant).
                    moved.setModifiers(binding.modifiers.map { modifier in
                        reverseSource[modifier.serialized]
                            .flatMap { destMap[$0] }
                            .flatMap(InputEvent.parse) ?? modifier
                    })
                    newBindings.append(moved)
                } else {
                    // Keep unmapped bindings as-is
                    newBindings.append(binding)
                }
            }
            converted.joysticks[i].bindings = newBindings
        }

        return converted
    }
}


// MARK: - Preset Group

/// A user-named group of presets shown as a collapsible section in the
/// sidebar. Groups live in their own JSON file alongside the presets
/// directory so multiple presets can share a group without each preset
/// owning the metadata redundantly.
struct PresetGroup: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var sortOrder: Int
    var isExpanded: Bool
    /// User-pickable tint for the folder row in the sidebar. Stored as a
    /// stable name (matches `PresetGroup.colorOptions`) so it survives
    /// app updates and SwiftUI palette changes. nil means no tint, which
    /// renders as the neutral default.
    var color: String?
    /// Optional parent folder, enabling folders-inside-folders. nil means the
    /// folder is top-level. `sortOrder` orders siblings within the same
    /// parent. Optional + lenient Codable so older saves (no `parentID`)
    /// load as flat top-level folders, exactly as before.
    var parentID: UUID?
    /// True for the folders the app ships with. They sit under a Built-in
    /// Presets heading in the sidebar; the user's own folders sit under My
    /// Presets. Purely where the folder is listed: its presets are ordinary
    /// files, edits stick, moving a preset out sticks, and updates never
    /// touch them.
    var isBuiltIn: Bool = false

    init(id: UUID = UUID(), name: String, sortOrder: Int = 0,
         isExpanded: Bool = true, color: String? = nil, parentID: UUID? = nil,
         isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.isExpanded = isExpanded
        self.color = color
        self.parentID = parentID
        self.isBuiltIn = isBuiltIn
    }

    /// Lenient Codable so older saves (which don't have a `color` or
    /// `parentID` key) still load. New saves write them when set.
    enum CodingKeys: String, CodingKey {
        case id, name, sortOrder, isExpanded, color, parentID, isBuiltIn
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.sortOrder = (try? c.decode(Int.self, forKey: .sortOrder)) ?? 0
        self.isExpanded = (try? c.decode(Bool.self, forKey: .isExpanded)) ?? true
        self.color = try? c.decode(String.self, forKey: .color)
        self.parentID = try? c.decode(UUID.self, forKey: .parentID)
        self.isBuiltIn = (try? c.decode(Bool.self, forKey: .isBuiltIn)) ?? false
    }

    /// Palette of named colors the user can pick from. Each entry maps
    /// to a SwiftUI Color via `PresetGroup.color(named:)`. Kept in the
    /// model so the picker UI doesn't need its own hard-coded list.
    static let colorOptions: [String] = [
        "blue", "purple", "pink", "red", "orange",
        "yellow", "green", "teal", "indigo", "brown"
    ]
}

// MARK: - Safe ranges

private extension Comparable {
    func clamped(_ range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}

private func finite(_ v: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
    v.isFinite ? v.clamped(range) : fallback
}

extension OutputAction {
    /// Every number in range, so a damaged value cannot trap when used.
    func clampedValues() -> OutputAction {
        var o = self
        o.keyCode = o.keyCode?.clamped(0...0xFFFF)
        o.mouseButtonIndex = o.mouseButtonIndex?.clamped(0...31)
        o.clickX = o.clickX.map { finite($0, -100_000...100_000, 0) }
        o.clickY = o.clickY.map { finite($0, -100_000...100_000, 0) }
        o.speed = o.speed?.clamped(0...1000)
        o.midiNote = o.midiNote?.clamped(0...127)
        o.midiVelocity = o.midiVelocity?.clamped(0...127)
        o.midiCCNumber = o.midiCCNumber?.clamped(0...127)
        o.midiCCValue = o.midiCCValue?.clamped(0...127)
        o.midiChannel = o.midiChannel?.clamped(1...16)
        o.midiProgramNumber = o.midiProgramNumber?.clamped(0...127)
        // lightColor is three UInt8s (a file with 300 fails its decode and
        // the row is kept as written), so it has no range to clamp.
        return o
    }
}

extension InputEvent {
    /// Every number in a range nothing downstream can trap on.
    func clampedValues() -> InputEvent {
        var e = self
        e.index = e.index.clamped(0...0xFF_FFFF)
        e.touchpadFinger = e.touchpadFinger?.clamped(0...9)
        e.touchpadSurface = e.touchpadSurface?.clamped(0...1)
        e.midiChannel = e.midiChannel?.clamped(1...16)
        e.midiTurnStep = e.midiTurnStep?.clamped(1...32)
        return e
    }
}

extension TouchpadRegion {
    func clampedValues() -> TouchpadRegion {
        var r = self
        r.minX = finite(r.minX, 0...1, 0); r.maxX = finite(r.maxX, 0...1, 1)
        r.minY = finite(r.minY, 0...1, 0); r.maxY = finite(r.maxY, 0...1, 1)
        if r.minX > r.maxX { swap(&r.minX, &r.maxX) }
        if r.minY > r.maxY { swap(&r.minY, &r.maxY) }
        r.colorIndex = r.colorIndex.clamped(0...1000)
        return r
    }
}

extension Preset {
    /// The preset with every number in a safe range. Applied on decode, so
    /// a preset loaded from disk, imported, or restored from a backup
    /// cannot crash the app with a negative slot, a NaN, or a huge value.
    func clampedValues() -> Preset {
        var p = self
        p.clampInPlace()
        return p
    }

    /// A rainbow speed held to the slider's range; a NaN or infinite one is
    /// dropped (nil, the normal speed).
    static func clampedRainbowSpeed(_ speed: Double?) -> Double? {
        guard let speed, speed.isFinite else { return nil }
        return speed.clamped(lightBarRainbowSpeedRange)
    }

    mutating func clampInPlace() {
        func row(_ b: BindingModel) -> BindingModel {
            var b = b
            func f(_ v: Float?, _ r: ClosedRange<Float>) -> Float? {
                guard let v else { return nil }
                return v.isFinite ? v.clamped(r) : nil
            }
            // An empty macro is no macro (see sanitizedForImport).
            if b.macroSteps?.isEmpty == true { b.macroSteps = nil }
            // Input numbers from a file: a negative or huge index, finger,
            // surface or channel trapped in the 1.5 row check, the editor's
            // row label and the input names.
            b.input = b.input.clampedValues()
            b.modifierInput = b.modifierInput?.clampedValues()
            b.extraModifierInputs = b.extraModifierInputs?.map { $0.clampedValues() }
            b.deadzone = f(b.deadzone, 0...0.95)
            b.outerDeadzone = f(b.outerDeadzone, 0.05...1)
            b.hapticIntensity = f(b.hapticIntensity, 0...1)
            b.turboRate = b.turboRate?.clamped(1...100)
            b.turboIntervalMs = b.turboIntervalMs?.clamped(1...60_000)
            b.turboJitterMs = b.turboJitterMs?.clamped(0...10_000)
            b.turboMaxCount = b.turboMaxCount?.clamped(0...100_000)
            b.repeatCount = b.repeatCount?.clamped(0...1000)
            b.repeatDelayMs = b.repeatDelayMs?.clamped(0...60_000)
            b.rampMs = b.rampMs?.clamped(0...10_000)
            b.hapticDurationMs = b.hapticDurationMs?.clamped(0...10_000)
            b.holdThresholdMs = b.holdThresholdMs?.clamped(50...5000)
            b.doubleTapWindowMs = b.doubleTapWindowMs?.clamped(100...2000)
            b.outputs = b.outputs.map { $0.clampedValues() }
            b.holdOutputs = b.holdOutputs?.map { $0.clampedValues() }
            b.doubleTapOutputs = b.doubleTapOutputs?.map { $0.clampedValues() }
            b.macroSteps = b.macroSteps?.map { step in
                var s = step
                s.action = s.action.clampedValues()
                s.delayMs = s.delayMs.clamped(0...30_000)
                s.holdMs = s.holdMs.clamped(0...30_000)
                return s
            }
            return b
        }
        for g in joysticks.indices { joysticks[g].bindings = joysticks[g].bindings.map(row) }
        touchpadRegions = touchpadRegions.map { $0.clampedValues() }
        cursorRegions = cursorRegions.map { $0.clampedValues() }
        stickRegions = stickRegions.mapValues { $0.map { $0.clampedValues() } }
        automation.confineBufferPx = finite(automation.confineBufferPx, 1...200, 24)
        automation.autoRecenterIntervalMs = finite(automation.autoRecenterIntervalMs, 16...60_000, 500)
        automation.sensitivityMultiplier = finite(automation.sensitivityMultiplier, 0.05...20, 1)
        automation.scrollMultiplier = finite(automation.scrollMultiplier, 0.05...20, 1)
        lightBarBrightness = lightBarBrightness?.clamped(0...255)
        lightBarRainbowSpeed = Self.clampedRainbowSpeed(lightBarRainbowSpeed)
        if var d = driveConfig {
            d.slot = d.slot.clamped(0...31)
            d.steerAxis = d.steerAxis.clamped(0...31)
            d.throttleAxis = d.throttleAxis.clamped(0...31)
            d.deadzone = finite(d.deadzone, 0...0.95, 0.12)
            d.steerMouseSpeed = finite(d.steerMouseSpeed, 0...1000, 18)
            for k in [\DriveConfig.steerLeftKey, \.steerRightKey, \.accelKey, \.brakeKey, \.reverseKey] {
                d[keyPath: k] = d[keyPath: k].clamped(0...0xFFFF)
            }
            d.throttleCurve = finite(d.throttleCurve, 0.1...10, 1)
            d.steerCurve = finite(d.steerCurve, 0.1...10, 1)
            d.coastBrakeStrength = finite(d.coastBrakeStrength, 0...1, 0.5)
            d.pwmPeriodTicks = d.pwmPeriodTicks.clamped(1...100)
            d.reverseTapCount = d.reverseTapCount.clamped(1...10)
            d.reverseWindowMs = d.reverseWindowMs.clamped(100...5000)
            d.gestureThreshold = finite(d.gestureThreshold, 0...1, 0.85)
            driveConfig = d
        }
    }
}
