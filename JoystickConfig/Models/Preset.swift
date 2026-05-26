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
        self.r = UInt8(max(0, min(255, Int(floatR * 255))))
        self.g = UInt8(max(0, min(255, Int(floatG * 255))))
        self.b = UInt8(max(0, min(255, Int(floatB * 255))))
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

/// A single step in a macro sequence
struct MacroStep: Identifiable, Codable, Hashable {
    let id: UUID
    var action: OutputAction      // What to do
    var delayMs: Int              // Delay BEFORE this step in milliseconds
    var holdMs: Int               // How long to hold (for press actions)

    init(action: OutputAction, delayMs: Int = 50, holdMs: Int = 50) {
        self.id = UUID()
        self.action = action
        self.delayMs = delayMs
        self.holdMs = holdMs
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
    let id: UUID
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
    var sensitivityCurve: SensitivityCurve?  // Response curve for analog inputs
    var repeatCount: Int?        // Number of times to repeat outputs (nil = 1, 0 = infinite while held)
    var repeatDelayMs: Int?      // Delay between repeats in ms (default 100)

    // Variable sensitivity: scale output magnitude by axis depth (0 to 1).
    // When false, the configured speed/value is used at full magnitude after the deadzone.
    var variableSensitivity: Bool?

    // Feedback options
    var hapticEnabled: Bool?     // Vibrate the controller when this binding fires
    var hapticIntensity: Float?  // 0.0 to 1.0, default 0.6
    var speechEnabled: Bool?     // Speak a phrase when this binding fires
    var speechText: String?      // Phrase to speak (defaults to the input name)
    var speechDestination: SpeechDestination?  // Where to play the speech

    // Macro sequence (overrides outputs when set)
    var macroSteps: [MacroStep]?

    init(input: InputEvent, outputs: [OutputAction] = []) {
        self.id = UUID()
        self.input = input
        self.outputs = outputs
    }

    init(id: UUID = UUID(), input: InputEvent, outputs: [OutputAction],
         deadzone: Float? = nil, outerDeadzone: Float? = nil, invertAxis: Bool? = nil, toggleMode: Bool? = nil,
         turboEnabled: Bool? = nil, turboRate: Int? = nil, sensitivityCurve: SensitivityCurve? = nil,
         repeatCount: Int? = nil, repeatDelayMs: Int? = nil,
         variableSensitivity: Bool? = nil,
         hapticEnabled: Bool? = nil, hapticIntensity: Float? = nil,
         speechEnabled: Bool? = nil, speechText: String? = nil,
         speechDestination: SpeechDestination? = nil,
         macroSteps: [MacroStep]? = nil) {
        self.id = id
        self.input = input
        self.outputs = outputs
        self.deadzone = deadzone
        self.outerDeadzone = outerDeadzone
        self.invertAxis = invertAxis
        self.toggleMode = toggleMode
        self.turboEnabled = turboEnabled
        self.turboRate = turboRate
        self.sensitivityCurve = sensitivityCurve
        self.repeatCount = repeatCount
        self.repeatDelayMs = repeatDelayMs
        self.variableSensitivity = variableSensitivity
        self.hapticEnabled = hapticEnabled
        self.hapticIntensity = hapticIntensity
        self.speechEnabled = speechEnabled
        self.speechText = speechText
        self.speechDestination = speechDestination
        self.macroSteps = macroSteps
    }
}

/// A joystick mapping group (one physical controller's bindings)
struct JoystickMapping: Identifiable, Codable, Hashable {
    let id: UUID
    var tag: String
    var bindings: [BindingModel]
    var isExpanded: Bool

    init(tag: String = "", bindings: [BindingModel] = [], isExpanded: Bool = true) {
        self.id = UUID()
        self.tag = tag
        self.bindings = bindings
        self.isExpanded = isExpanded
    }

    enum CodingKeys: String, CodingKey {
        case id, tag, bindings, isExpanded
    }
}

/// A complete preset containing name, tag, and joystick mappings
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
    /// RGB light-bar color override stored as 0-255 components. When non-nil
    /// the mapping engine paints the controller's light bar with this color
    /// while the preset is active, and reverts to the slot's general color
    /// when the preset stops. Optional so older files decode cleanly.
    var lightBarColor: RGBLightColor?
    /// Brightness override applied alongside `lightBarColor` (0 = off,
    /// 1 = dim, 2 = bright). nil = inherit the slot's current brightness.
    var lightBarBrightness: Int?

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

    enum CodingKeys: String, CodingKey {
        case id, name, tag, joysticks, filename, isActive, createdAt, modifiedAt
        case groupID, notes, lightBarColor, lightBarBrightness
    }

    /// Custom Codable init so older preset files without `notes`,
    /// `lightBarColor`, or `lightBarBrightness` keys still decode cleanly
    /// (the synthesized Codable would otherwise require every key).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.tag = try c.decode(String.self, forKey: .tag)
        self.joysticks = try c.decode([JoystickMapping].self, forKey: .joysticks)
        self.filename = try c.decode(String.self, forKey: .filename)
        self.isActive = try c.decode(Bool.self, forKey: .isActive)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.modifiedAt = try c.decode(Date.self, forKey: .modifiedAt)
        self.groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
        self.notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        self.lightBarColor = try c.decodeIfPresent(RGBLightColor.self, forKey: .lightBarColor)
        self.lightBarBrightness = try c.decodeIfPresent(Int.self, forKey: .lightBarBrightness)
    }

    static func generateFilename() -> String {
        // Use a fresh UUID so two presets generated in the same second can't
        // collide on disk. Previously the format was "yyyyMMdd_HH-mm-ss.json",
        // which clobbered all-but-the-last-seeded preset during fresh-install
        // seeding (22 presets land within the same second).
        return UUID().uuidString + ".json"
    }

    /// Sort all bindings in all joystick groups alphabetically by input type then index
    mutating func sortBindings() {
        for i in joysticks.indices {
            joysticks[i].bindings.sort { a, b in
                let typeOrder: [InputType: Int] = [.button: 0, .axis: 1, .hat: 2]
                let aType = typeOrder[a.input.type] ?? 0
                let bType = typeOrder[b.input.type] ?? 0
                if aType != bType { return aType < bType }
                return a.input.index < b.input.index
            }
        }
    }
}

// MARK: - Legacy Format Support (Joystick Mapper JSON)

extension Preset {
    /// Parse from legacy Joystick Mapper JSON format
    static func fromLegacyJSON(_ data: Data, filename: String = "") -> Preset? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
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

                // Sort bindings by type then index
                bindings.sort { a, b in
                    let typeOrder: [InputType: Int] = [.button: 0, .axis: 1, .hat: 2, .touchpad: 3, .touchpadRegion: 4, .motion: 5]
                    let aType = typeOrder[a.input.type] ?? 0
                    let bType = typeOrder[b.input.type] ?? 0
                    if aType != bType { return aType < bType }
                    return a.input.index < b.input.index
                }

                joystickMappings.append(JoystickMapping(tag: joyTag, bindings: bindings))
            }
        }

        return Preset(name: name, tag: tag, joysticks: joystickMappings, filename: filename)
    }

    /// Export to legacy Joystick Mapper JSON format
    func toLegacyJSON() -> Data? {
        var root: [String: Any] = [
            "name": name,
            "tag": tag,
        ]

        var joystickArray: [[String: Any]] = []
        for joystick in joysticks {
            var bindsDict: [String: [String]] = [:]

            for binding in joystick.bindings {
                let key = binding.input.serialized
                let values = binding.outputs.map { $0.serialized }
                if bindsDict[key] != nil {
                    bindsDict[key]?.append(contentsOf: values)
                } else {
                    bindsDict[key] = values
                }
            }

            joystickArray.append([
                "tag": joystick.tag,
                "binds": bindsDict,
            ])
        }

        root["joysticks"] = joystickArray

        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
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

    /// Convert a preset from this controller type to another
    static func convert(preset: Preset, from source: ControllerType, to destination: ControllerType) -> Preset {
        let sourceMap = source.standardMapping
        let destMap = destination.standardMapping

        // Build reverse map: source input string -> standard key
        var reverseSource: [String: String] = [:]
        for (key, value) in sourceMap {
            reverseSource[value] = key
        }

        var converted = preset
        converted.name = preset.name
        converted.tag = "\(destination.rawValue) (converted from \(source.rawValue))"

        for i in converted.joysticks.indices {
            var newBindings: [BindingModel] = []
            for binding in converted.joysticks[i].bindings {
                let inputStr = binding.input.serialized
                if let standardKey = reverseSource[inputStr],
                   let destInputStr = destMap[standardKey],
                   let newInput = InputEvent.parse(destInputStr) {
                    newBindings.append(BindingModel(input: newInput, outputs: binding.outputs))
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

    init(id: UUID = UUID(), name: String, sortOrder: Int = 0, isExpanded: Bool = true) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.isExpanded = isExpanded
    }
}
