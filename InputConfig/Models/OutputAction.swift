import Foundation

/// Represents an output action type
enum OutputType: String, Codable, CaseIterable, Identifiable {
    case key = "key"
    case mouseButton = "mbt"
    case mouseMotion = "mou"
    case mouseWheel = "whe"
    case mouseWheelStep = "whs"
    case midiNote = "mni"
    case midiCC = "mcc"
    case midiPitchBend = "mpb"
    case midiProgramChange = "mpc"
    case midiTransport = "mtr"
    case typeText = "txt"
    case appAction = "app"
    /// Absolute system volume: the Mac's output level follows the bound
    /// input's position 1-to-1. Built for continuous sources - a MIDI
    /// knob, the pitch wheel, aftertouch, or a controller trigger. Unlike
    /// the volume KEYS, which nudge in steps, this is a fader.
    case absoluteVolume = "avl"
    /// A named system function: volume nudges, media keys, brightness,
    /// Mission Control, lock screen, a Siri Shortcut, opening an app or
    /// URL. Fires on press; the specific function lives in
    /// `systemActionKind` with an optional string parameter in `text`.
    case systemAction = "sys"
    /// Colors the controller's light bar (DualSense, DualShock 4): the
    /// color rides in `lightColor`, and `lightMode` says whether it shows
    /// while the input is held, stays until something else changes it, or
    /// switches the rainbow on and off. Posts no events.
    case lightBar = "lit"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .key: return String(localized: "Keyboard Key")
        case .typeText: return String(localized: "Type Text")
        case .appAction: return String(localized: "App Action")
        case .absoluteVolume: return String(localized: "System Volume (follows input)")
        case .systemAction: return String(localized: "System Function")
        case .lightBar: return String(localized: "Light Bar Color")
        case .mouseButton: return String(localized: "Mouse Button")
        case .mouseMotion: return String(localized: "Mouse Motion")
        case .mouseWheel: return String(localized: "Mouse Wheel")
        case .mouseWheelStep: return String(localized: "Mouse Wheel Step")
        case .midiNote: return String(localized: "MIDI Note")
        case .midiCC: return String(localized: "MIDI CC (Control Change)")
        case .midiPitchBend: return String(localized: "MIDI Pitch Bend")
        case .midiProgramChange: return String(localized: "MIDI Program Change")
        case .midiTransport: return String(localized: "MIDI Transport")
        }
    }

    var isMIDI: Bool {
        switch self {
        case .midiNote, .midiCC, .midiPitchBend, .midiProgramChange, .midiTransport: return true
        default: return false
        }
    }
}

/// Which MIDI real-time transport message to send. The DAW typically responds
/// by playing, stopping, or continuing playback at its current position.
enum MIDITransport: String, Codable, CaseIterable, Identifiable {
    case start = "start"
    case stop = "stop"
    case `continue` = "continue"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .start: return String(localized: "Start")
        case .stop: return String(localized: "Stop")
        case .continue: return String(localized: "Continue")
        }
    }

    /// The MIDI real-time status byte for this transport message.
    var statusByte: UInt8 {
        switch self {
        case .start: return 0xFA
        case .stop: return 0xFC
        case .continue: return 0xFB
        }
    }
}

/// A system-level function a binding can trigger. Grouped for the picker:
/// sound, media, display, Mac shortcuts, and automation. The three
/// automation kinds carry a string parameter (shortcut name, app name or
/// path, URL) in the output's `text` field.
enum SystemActionKind: String, Codable, CaseIterable, Identifiable {
    // Sound
    case volumeUp = "vup"
    case volumeDown = "vdn"
    case muteToggle = "mut"
    // Media
    case playPause = "ply"
    case nextTrack = "nxt"
    case previousTrack = "prv"
    // Display
    case brightnessUp = "bup"
    case brightnessDown = "bdn"
    case keyboardBrightnessUp = "kbu"
    case keyboardBrightnessDown = "kbd"
    // Accessibility
    case startDictation = "dct"
    case speakSelection = "spk"
    case zoomToggle = "zom"
    case zoomIn = "zmi"
    case zoomOut = "zmo"
    // Mac
    case missionControl = "mct"
    case launchpad = "lpd"
    case spotlight = "spt"
    case lockScreen = "lck"
    case screenshotMenu = "scr"
    // Automation
    case runShortcut = "sct"
    case openApp = "opa"
    case openURL = "our"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .volumeUp: return String(localized: "Volume Up")
        case .volumeDown: return String(localized: "Volume Down")
        case .muteToggle: return String(localized: "Mute / Unmute")
        case .playPause: return String(localized: "Play / Pause")
        case .nextTrack: return String(localized: "Next Track")
        case .previousTrack: return String(localized: "Previous Track")
        case .brightnessUp: return String(localized: "Brightness Up")
        case .brightnessDown: return String(localized: "Brightness Down")
        case .keyboardBrightnessUp: return String(localized: "Keyboard Brightness Up")
        case .keyboardBrightnessDown: return String(localized: "Keyboard Brightness Down")
        case .startDictation: return String(localized: "Start Dictation")
        case .speakSelection: return String(localized: "Speak Selection")
        case .zoomToggle: return String(localized: "Zoom On / Off")
        case .zoomIn: return String(localized: "Zoom In")
        case .zoomOut: return String(localized: "Zoom Out")
        case .missionControl: return String(localized: "Mission Control")
        case .launchpad:
            if #available(macOS 26, *) { return String(localized: "Apps (Launchpad)") }
            return String(localized: "Launchpad")
        case .spotlight: return String(localized: "Spotlight Search")
        case .lockScreen: return String(localized: "Lock Screen")
        case .screenshotMenu: return String(localized: "Screenshot Menu")
        case .runShortcut: return String(localized: "Run Siri Shortcut")
        case .openApp: return String(localized: "Open App")
        case .openURL: return String(localized: "Open URL")
        }
    }

    /// True when the kind needs a user-supplied string parameter.
    var needsParameter: Bool {
        switch self {
        case .runShortcut, .openApp, .openURL: return true
        default: return false
        }
    }

    var iconName: String {
        switch self {
        case .volumeUp: return "speaker.plus.fill"
        case .volumeDown: return "speaker.minus.fill"
        case .muteToggle: return "speaker.slash.fill"
        case .playPause: return "playpause.fill"
        case .nextTrack: return "forward.fill"
        case .previousTrack: return "backward.fill"
        case .brightnessUp: return "sun.max.fill"
        case .brightnessDown: return "sun.min.fill"
        case .keyboardBrightnessUp: return "keyboard.badge.ellipsis"
        case .keyboardBrightnessDown: return "keyboard"
        case .startDictation: return "mic.fill"
        case .speakSelection: return "speaker.wave.2.fill"
        case .zoomToggle: return "plus.magnifyingglass"
        case .zoomIn: return "plus.magnifyingglass"
        case .zoomOut: return "minus.magnifyingglass"
        case .missionControl: return "rectangle.3.group.fill"
        case .launchpad: return "square.grid.3x3.fill"
        case .spotlight: return "magnifyingglass"
        case .lockScreen: return "lock.fill"
        case .screenshotMenu: return "camera.viewfinder"
        case .runShortcut: return "sparkles.rectangle.stack.fill"
        case .openApp: return "arrow.up.forward.app.fill"
        case .openURL: return "safari.fill"
        }
    }

    /// Section header the kind appears under in the output picker.
    var category: String {
        switch self {
        case .volumeUp, .volumeDown, .muteToggle: return String(localized: "Sound")
        case .playPause, .nextTrack, .previousTrack: return String(localized: "Media")
        case .brightnessUp, .brightnessDown,
             .keyboardBrightnessUp, .keyboardBrightnessDown: return String(localized: "Display")
        case .startDictation, .speakSelection,
             .zoomToggle, .zoomIn, .zoomOut: return String(localized: "Accessibility")
        case .missionControl, .launchpad, .spotlight, .lockScreen, .screenshotMenu: return String(localized: "Mac")
        case .runShortcut, .openApp, .openURL: return String(localized: "Automation")
        }
    }

    /// One line under the name in the picker, for the kinds that depend on a
    /// macOS setting being switched on.
    var requirementNote: String? {
        switch self {
        case .startDictation:
            return String(localized: "Needs Dictation switched on in System Settings, Keyboard")
        case .speakSelection:
            return String(localized: "Needs Accessibility, Spoken Content, Speak selection switched on")
        case .zoomToggle, .zoomIn, .zoomOut:
            return String(localized: "Needs Accessibility, Zoom, Use keyboard shortcuts to zoom switched on")
        default:
            return nil
        }
    }

    /// Picker order, grouped by category.
    static let grouped: [(category: String, kinds: [SystemActionKind])] = [
        (String(localized: "Sound"), [.volumeUp, .volumeDown, .muteToggle]),
        (String(localized: "Media"), [.playPause, .nextTrack, .previousTrack]),
        (String(localized: "Display"), [.brightnessUp, .brightnessDown,
                     .keyboardBrightnessUp, .keyboardBrightnessDown]),
        (String(localized: "Accessibility"), [.startDictation, .speakSelection,
                           .zoomToggle, .zoomIn, .zoomOut]),
        (String(localized: "Mac"), [.missionControl, .launchpad, .spotlight, .lockScreen, .screenshotMenu]),
        (String(localized: "Automation"), [.runShortcut, .openApp, .openURL]),
    ]
}

/// How a light bar output uses its color.
enum LightOutputMode: String, Codable, CaseIterable, Identifiable {
    /// The color shows while the input is held, then the light goes back
    /// to what it was showing (a standing color, the preset's color, a
    /// rainbow, or the controller's own color).
    case whileHeld = "held"
    /// The color stays until another light output changes it or the
    /// preset stops.
    case set = "set"
    /// Each press switches the rainbow cycle on or off.
    case rainbowToggle = "rainbow"

    var id: String { rawValue }

    /// A mode added by a newer build reads as While Held, the one that
    /// always puts the light back, instead of making the row unreadable.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = LightOutputMode(rawValue: raw) ?? .whileHeld
    }

    var displayName: String {
        switch self {
        case .whileHeld: return String(localized: "While held")
        case .set: return String(localized: "Set and keep")
        case .rainbowToggle: return String(localized: "Rainbow on / off")
        }
    }
}

extension RGBLightColor {
    /// The named colors the preset's light bar picker offers, in its order.
    static let namedSwatches: [(name: String, color: RGBLightColor)] = [
        (String(localized: "Red"), RGBLightColor(r: 255, g: 0, b: 0)),
        (String(localized: "Orange"), RGBLightColor(r: 255, g: 89, b: 0)),
        (String(localized: "Yellow"), RGBLightColor(r: 255, g: 179, b: 0)),
        (String(localized: "Green"), RGBLightColor(r: 0, g: 255, b: 0)),
        (String(localized: "Cyan"), RGBLightColor(r: 0, g: 255, b: 255)),
        (String(localized: "Blue"), RGBLightColor(r: 0, g: 0, b: 255)),
        (String(localized: "Purple"), RGBLightColor(r: 128, g: 0, b: 255)),
        (String(localized: "Pink"), RGBLightColor(r: 255, g: 0, b: 153)),
        (String(localized: "White"), RGBLightColor(r: 255, g: 255, b: 255)),
        (String(localized: "Off"), RGBLightColor(r: 0, g: 0, b: 0)),
    ]

    /// The swatch name this color matches, or the nearest one for a
    /// custom color, so a row reads "red" rather than three numbers.
    var nearestName: String {
        func distance(_ c: RGBLightColor) -> Int {
            let dr = Int(r) - Int(c.r), dg = Int(g) - Int(c.g), db = Int(b) - Int(c.b)
            return dr * dr + dg * dg + db * db
        }
        return Self.namedSwatches.min { distance($0.color) < distance($1.color) }?.name ?? String(localized: "Custom")
    }

    /// True when the color is exactly one of the named swatches.
    var isNamedSwatch: Bool { Self.namedSwatches.contains { $0.color == self } }
}

/// Mouse motion / wheel axis
enum MouseAxis: Int, Codable, CaseIterable {
    case horizontal = 0
    case vertical = 1

    var displayName: String {
        switch self {
        case .horizontal: return String(localized: "Horizontal")
        case .vertical: return String(localized: "Vertical")
        }
    }
}

/// Mouse motion / wheel direction
enum MouseDirection: String, Codable, CaseIterable {
    case positive = "+"
    case negative = "-"

    /// Presets are stored as "+" / "-", but a file that was hand-edited (or
    /// written by an older tool) can carry the long spelling. Reading it
    /// strictly would throw and quietly cost the binding its row, which
    /// looks to a person like "this direction just stopped working", so the
    /// long forms are accepted too.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw.lowercased() {
        case "+", "positive": self = .positive
        case "-", "negative": self = .negative
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Unknown mouse direction \(raw)"))
        }
    }

    var displayName: String {
        switch self {
        case .positive: return "+"
        case .negative: return "-"
        }
    }

    /// For mouse motion display
    func axisDirectionName(axis: MouseAxis) -> String {
        switch (axis, self) {
        case (.vertical, .negative): return String(localized: "Up")
        case (.horizontal, .positive): return String(localized: "Right")
        case (.vertical, .positive): return String(localized: "Down")
        case (.horizontal, .negative): return String(localized: "Left")
        }
    }
}

/// Represents a single output action (keyboard key, mouse button, mouse movement, MIDI message, etc.)
/// Internal app actions a binding can trigger: runtime control of InputConfig
/// itself from the controller. The escape hatch matters most for users who
/// cannot reach the menu bar or a keyboard chord mid-session.
enum AppActionKind: String, Codable, CaseIterable, Identifiable {
    case activatePreset = "act"
    case nextPreset = "next"
    case previousPreset = "prev"
    case deactivate = "off"
    case togglePauseOutputs = "pause"
    /// Gyro ratchet: motion bindings on this controller stop moving the
    /// cursor while the input is held, so the controller can be re-aimed
    /// without dragging the view. Nothing happens on release.
    case holdMuteMotion = "mutemotion"
    /// Motion on and off by a press: one press stops the motion rows (the
    /// pointer stays where it is), the next starts them again from where
    /// the controller is then. Starts on with every preset.
    case toggleMotion = "togglemotion"
    /// Motion only while held: the motion rows move nothing unless this is
    /// held, the way Steam Input's "gyro on while touching" works.
    case holdEnableMotion = "holdmotion"
    /// Stop everything now: halt the engine, release every held key, button
    /// and note, and deactivate the preset. Never starts anything.
    case emergencyStop = "estop"
    /// Snapshot the pressing controller's current gyro and accelerometer
    /// reading as its new resting zero, the same thing the editor's Quick
    /// Zero button does, from a button you can reach mid-session.
    case rezeroMotion = "rezero"
    /// Put the pointer in the middle of the screen it is on. Pairs with
    /// Re-zero Motion on the same button for gyro pointing: the controller
    /// at rest becomes "pointer at center" again in one press.
    case centerPointer = "center"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .activatePreset: return String(localized: "Activate Preset")
        case .nextPreset: return String(localized: "Next Preset (in this folder)")
        case .previousPreset: return String(localized: "Previous Preset (in this folder)")
        case .deactivate: return String(localized: "Deactivate")
        case .togglePauseOutputs: return String(localized: "Pause / Resume Outputs")
        case .holdMuteMotion: return String(localized: "Pause Motion While Held")
        case .toggleMotion: return String(localized: "Motion On / Off")
        case .holdEnableMotion: return String(localized: "Motion Only While Held")
        case .emergencyStop: return String(localized: "Emergency Stop (release everything)")
        case .rezeroMotion: return String(localized: "Re-zero Motion (this controller)")
        case .centerPointer: return String(localized: "Center Pointer on Screen")
        }
    }
}

extension OutputAction {
    /// Whether a row's outputs form a Command or Control shortcut, which
    /// sends its letter and punctuation keys by character.
    static func isShortcut(_ outputs: [OutputAction]) -> Bool {
        outputs.contains { $0.type == .key && KeyCodeMap.shortcutModifierCodes.contains($0.keyCode ?? -1) }
    }

    /// The names of a row's outputs as sent: "Command (Left) + Z" for Undo
    /// on every keyboard layout.
    static func names(_ outputs: [OutputAction]) -> [String] {
        let shortcut = isShortcut(outputs)
        return outputs.map { o in
            if o.type == .key, let code = o.keyCode { return KeyCodeMap.outputName(for: code, inShortcut: shortcut) }
            return o.displayName
        }
    }
}

struct OutputAction: Codable, Hashable, Identifiable {
    let id: UUID

    var type: OutputType
    var keyCode: Int?
    var mouseButtonIndex: Int?
    /// Optional fixed screen point for a mouse button output, in CoreGraphics
    /// coordinates (origin top-left of the main display). When set the
    /// pointer is moved there before the click, which is what an auto-clicker
    /// parked on a button on screen needs. nil clicks wherever the pointer is.
    var clickX: Double?
    var clickY: Double?
    var mouseAxis: MouseAxis?
    var mouseDirection: MouseDirection?
    var speed: Int?

    // MIDI-specific fields (only used when type is one of the MIDI cases).
    // midiNote/midiCC values are 0-127. midiChannel is 1-16 (stored as 0-15
    // internally to match the MIDI spec).
    var midiNote: Int?         // 0-127, e.g. 60 = middle C
    var midiVelocity: Int?     // 0-127
    var midiCCNumber: Int?     // 0-127, e.g. 1 = modulation, 7 = volume, 11 = expression
    var midiCCValue: Int?      // 0-127 (used for fixed-value CC presses; variable axes drive it dynamically)
    var midiChannel: Int?      // 1-16 (defaults to 1 if nil)
    var midiProgramNumber: Int?  // 0-127, used for Program Change messages
    var midiTransport: MIDITransport?  // Start, Stop, Continue for transport bindings

    /// Literal text typed when a .typeText output fires (press only).
    var text: String?

    /// Which internal app action a .appAction output performs, and the
    /// preset it targets when the kind is .activatePreset.
    var appActionKind: AppActionKind?
    var targetPresetID: UUID?

    /// Which system function a .systemAction output performs. The
    /// parameter for Run Shortcut / Open App / Open URL rides in `text`.
    var systemActionKind: SystemActionKind?

    /// The color and mode of a .lightBar output.
    var lightColor: RGBLightColor?
    var lightMode: LightOutputMode?

    init(type: OutputType, keyCode: Int? = nil, mouseButtonIndex: Int? = nil,
         mouseAxis: MouseAxis? = nil, mouseDirection: MouseDirection? = nil, speed: Int? = nil,
         midiNote: Int? = nil, midiVelocity: Int? = nil,
         midiCCNumber: Int? = nil, midiCCValue: Int? = nil,
         midiChannel: Int? = nil,
         midiProgramNumber: Int? = nil,
         midiTransport: MIDITransport? = nil,
         text: String? = nil,
         appActionKind: AppActionKind? = nil,
         targetPresetID: UUID? = nil,
         systemActionKind: SystemActionKind? = nil,
         lightColor: RGBLightColor? = nil,
         lightMode: LightOutputMode? = nil) {
        self.id = UUID()
        self.type = type
        self.keyCode = keyCode
        self.mouseButtonIndex = mouseButtonIndex
        self.mouseAxis = mouseAxis
        self.mouseDirection = mouseDirection
        self.speed = speed
        self.midiNote = midiNote
        self.midiVelocity = midiVelocity
        self.midiCCNumber = midiCCNumber
        self.midiCCValue = midiCCValue
        self.midiChannel = midiChannel
        self.midiProgramNumber = midiProgramNumber
        self.midiTransport = midiTransport
        self.text = text
        self.appActionKind = appActionKind
        self.targetPresetID = targetPresetID
        self.systemActionKind = systemActionKind
        self.lightColor = lightColor
        self.lightMode = lightMode
    }

    var displayName: String {
        switch type {
        case .key:
            if let code = keyCode {
                return KeyCodeMap.outputName(for: code, inShortcut: false)
            }
            return String(localized: "Key")
        case .mouseButton:
            if let btn = mouseButtonIndex {
                switch btn {
                case 0: return String(localized: "Mouse Click")
                case 1: return String(localized: "Right Click")
                case 2: return String(localized: "Middle Click")
                default: return String(localized: "Mouse \(btn)")
                }
            }
            return String(localized: "Mouse Button")
        case .mouseMotion:
            if let axis = mouseAxis, let dir = mouseDirection {
                let dirName = dir.axisDirectionName(axis: axis)
                let spd = speed ?? 6
                return String(localized: "Mouse \(dirName) (\(spd)x)")
            }
            return String(localized: "Mouse Motion")
        case .mouseWheel:
            if let axis = mouseAxis, let dir = mouseDirection {
                let dirName = dir.axisDirectionName(axis: axis)
                let spd = speed ?? 6
                return String(localized: "Scroll \(dirName) (\(spd)x)")
            }
            return String(localized: "Mouse Wheel")
        case .mouseWheelStep:
            if let axis = mouseAxis, let dir = mouseDirection {
                let dirName = dir.axisDirectionName(axis: axis)
                return String(localized: "Scroll Step \(dirName)")
            }
            return String(localized: "Mouse Wheel Step")
        case .midiNote:
            let note = midiNote ?? 60
            let ch = midiChannel ?? 1
            let noteName = MIDIService.noteName(note)
            return String(localized: "MIDI \(noteName), ch \(ch)")
        case .midiCC:
            let cc = midiCCNumber ?? 1
            let ch = midiChannel ?? 1
            return String(localized: "MIDI CC \(cc), ch \(ch)")
        case .midiPitchBend:
            let ch = midiChannel ?? 1
            return String(localized: "MIDI Pitch Bend, ch \(ch)")
        case .midiProgramChange:
            let prog = midiProgramNumber ?? 0
            let ch = midiChannel ?? 1
            return String(localized: "MIDI Program \(prog), ch \(ch)")
        case .midiTransport:
            let transportName = (midiTransport ?? .start).displayName
            return String(localized: "MIDI \(transportName)")
        case .typeText:
            let t = text ?? ""
            if t.isEmpty { return String(localized: "Type Text") }
            let preview = t.count > 18 ? String(t.prefix(18)) + "..." : t
            return String(localized: "Type \"\(preview)\"")
        case .appAction:
            return appActionKind?.displayName ?? String(localized: "App Action")
        case .absoluteVolume:
            return String(localized: "System Volume")
        case .systemAction:
            guard let kind = systemActionKind else { return String(localized: "System Function") }
            if kind.needsParameter, let t = text, !t.isEmpty {
                let preview = t.count > 18 ? String(t.prefix(18)) + "..." : t
                return "\(kind.displayName): \(preview)"
            }
            return kind.displayName
        case .lightBar:
            switch resolvedLightMode {
            case .rainbowToggle: return String(localized: "Light bar: rainbow on / off")
            case .whileHeld:
                let color = resolvedLightColor.nearestName.lowercased()
                return String(localized: "Light bar: \(color), while held")
            case .set:
                let color = resolvedLightColor.nearestName.lowercased()
                return String(localized: "Light bar: \(color), stays on")
            }
        }
    }

    /// The name written to the activity log: typed text, website
    /// addresses, app paths and Shortcut names are counted, not quoted,
    /// since a saved report goes wherever its owner sends it.
    var logName: String {
        switch type {
        case .typeText:
            return "Type Text (\((text ?? "").count) characters)"
        case .systemAction:
            guard let kind = systemActionKind else { return displayName }
            if kind.needsParameter, let t = text, !t.isEmpty { return "\(kind.displayName) (\(t.count) characters)" }
            return kind.displayName
        default:
            return displayName
        }
    }

    /// Serialize to original format: "key 26", "mbt 0", "mou 1 - 11", "whe 0 + 6", "whs 1 +"
    // MARK: Mouse defaults
    //
    // What the editor shows when a mouse field is unset: Main Click, and
    // vertical "Up" at speed 6. The engine and export read through these
    // too, so an output switched to a mouse type without touching its
    // pickers does what the row says instead of nothing.
    static let defaultMouseButton = 0
    static let defaultMouseAxis: MouseAxis = .vertical
    static let defaultMouseDirection: MouseDirection = .negative
    static let defaultMouseSpeed = 6

    var resolvedMouseButton: Int { mouseButtonIndex ?? Self.defaultMouseButton }
    var resolvedMouseAxis: MouseAxis { mouseAxis ?? Self.defaultMouseAxis }
    var resolvedMouseDirection: MouseDirection { mouseDirection ?? Self.defaultMouseDirection }

    /// A light bar output with no color set shows red, held.
    static let defaultLightColor = RGBLightColor(r: 255, g: 0, b: 0)
    var resolvedLightColor: RGBLightColor { lightColor ?? Self.defaultLightColor }
    var resolvedLightMode: LightOutputMode { lightMode ?? .whileHeld }

    /// Fill the fields the current type needs with the editor's defaults.
    /// Called whenever a row's output type changes.
    mutating func fillDefaultsForType() {
        switch type {
        case .key:
            // The key picker shows A with no key stored, and the row sent
            // nothing; it stores the A it shows.
            if keyCode == nil { keyCode = 4 }
        case .mouseButton:
            if mouseButtonIndex == nil { mouseButtonIndex = Self.defaultMouseButton }
        case .mouseMotion, .mouseWheel:
            if mouseAxis == nil { mouseAxis = Self.defaultMouseAxis }
            if mouseDirection == nil { mouseDirection = Self.defaultMouseDirection }
            if speed == nil { speed = Self.defaultMouseSpeed }
        case .mouseWheelStep:
            if mouseAxis == nil { mouseAxis = Self.defaultMouseAxis }
            if mouseDirection == nil { mouseDirection = Self.defaultMouseDirection }
        case .lightBar:
            if lightColor == nil { lightColor = Self.defaultLightColor }
            if lightMode == nil { lightMode = .whileHeld }
        default:
            break
        }
    }

    var serialized: String {
        switch type {
        case .key:
            return "key \(keyCode ?? 0)"
        case .mouseButton:
            return "mbt \(resolvedMouseButton)"
        case .mouseMotion:
            let a = resolvedMouseAxis.rawValue
            let d = resolvedMouseDirection.rawValue
            let s = speed ?? 6
            return "mou \(a) \(d) \(s)"
        case .mouseWheel:
            let a = resolvedMouseAxis.rawValue
            let d = resolvedMouseDirection.rawValue
            let s = speed ?? 6
            return "whe \(a) \(d) \(s)"
        case .mouseWheelStep:
            let a = resolvedMouseAxis.rawValue
            let d = resolvedMouseDirection.rawValue
            return "whs \(a) \(d)"
        case .midiNote:
            return "mni \(midiNote ?? 60) \(midiVelocity ?? 100) \(midiChannel ?? 1)"
        case .midiCC:
            return "mcc \(midiCCNumber ?? 1) \(midiCCValue ?? 127) \(midiChannel ?? 1)"
        case .midiPitchBend:
            return "mpb \(midiChannel ?? 1)"
        case .midiProgramChange:
            return "mpc \(midiProgramNumber ?? 0) \(midiChannel ?? 1)"
        case .midiTransport:
            return "mtr \(midiTransport?.rawValue ?? "start")"
        case .typeText:
            // Percent-encode so the space-delimited token format survives
            // arbitrary text (including spaces and quotes).
            let encoded = (text ?? "").addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            return "txt \(encoded)"
        case .appAction:
            let kind = (appActionKind ?? .togglePauseOutputs).rawValue
            if appActionKind == .activatePreset, let target = targetPresetID {
                return "app \(kind) \(target.uuidString)"
            }
            return "app \(kind)"
        case .absoluteVolume:
            return "avl"
        case .systemAction:
            let kind = (systemActionKind ?? .playPause).rawValue
            if let t = text, !t.isEmpty {
                let encoded = t.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
                return "sys \(kind) \(encoded)"
            }
            return "sys \(kind)"
        case .lightBar:
            // lit <held|set|rainbow> <r> <g> <b>
            let c = resolvedLightColor
            return "lit \(resolvedLightMode.rawValue) \(c.r) \(c.g) \(c.b)"
        }
    }

    /// Parse from serialized format
    static func parse(_ string: String) -> OutputAction? {
        let parts = string.split(separator: " ").map(String.init)
        guard !parts.isEmpty else { return nil }

        switch parts[0] {
        case "key":
            guard parts.count >= 2, let code = Int(parts[1]) else { return nil }
            return OutputAction(type: .key, keyCode: code)
        case "mbt":
            guard parts.count >= 2, let btn = Int(parts[1]) else { return nil }
            return OutputAction(type: .mouseButton, mouseButtonIndex: btn)
        case "mou":
            guard parts.count >= 3,
                  let axisVal = Int(parts[1]),
                  let axis = MouseAxis(rawValue: axisVal) else { return nil }
            let dir = MouseDirection(rawValue: parts[2]) ?? .positive
            let spd = parts.count >= 4 ? Int(parts[3]) : nil
            return OutputAction(type: .mouseMotion, mouseAxis: axis, mouseDirection: dir, speed: spd)
        case "whe":
            guard parts.count >= 3,
                  let axisVal = Int(parts[1]),
                  let axis = MouseAxis(rawValue: axisVal) else { return nil }
            let dir = MouseDirection(rawValue: parts[2]) ?? .positive
            let spd = parts.count >= 4 ? Int(parts[3]) : nil
            return OutputAction(type: .mouseWheel, mouseAxis: axis, mouseDirection: dir, speed: spd)
        case "whs":
            guard parts.count >= 3,
                  let axisVal = Int(parts[1]),
                  let axis = MouseAxis(rawValue: axisVal) else { return nil }
            let dir = MouseDirection(rawValue: parts[2]) ?? .positive
            return OutputAction(type: .mouseWheelStep, mouseAxis: axis, mouseDirection: dir)
        case "mni":
            // mni <note> <velocity> <channel>
            guard parts.count >= 4,
                  let note = Int(parts[1]),
                  let vel = Int(parts[2]),
                  let ch = Int(parts[3]) else { return nil }
            return OutputAction(type: .midiNote, midiNote: note, midiVelocity: vel, midiChannel: ch)
        case "mcc":
            // mcc <ccNumber> <ccValue> <channel>
            guard parts.count >= 4,
                  let cc = Int(parts[1]),
                  let val = Int(parts[2]),
                  let ch = Int(parts[3]) else { return nil }
            return OutputAction(type: .midiCC, midiCCNumber: cc, midiCCValue: val, midiChannel: ch)
        case "mpb":
            // mpb <channel>
            guard parts.count >= 2, let ch = Int(parts[1]) else { return nil }
            return OutputAction(type: .midiPitchBend, midiChannel: ch)
        case "mpc":
            // mpc <program> <channel>
            guard parts.count >= 3,
                  let prog = Int(parts[1]),
                  let ch = Int(parts[2]) else { return nil }
            return OutputAction(type: .midiProgramChange, midiChannel: ch, midiProgramNumber: prog)
        case "mtr":
            // mtr <start|stop|continue>
            guard parts.count >= 2 else { return nil }
            let t = MIDITransport(rawValue: parts[1]) ?? .start
            return OutputAction(type: .midiTransport, midiTransport: t)
        case "avl":
            return OutputAction(type: .absoluteVolume)
        case "sys":
            guard parts.count >= 2, let kind = SystemActionKind(rawValue: parts[1]) else { return nil }
            let param = parts.count >= 3 ? parts[2].removingPercentEncoding : nil
            return OutputAction(type: .systemAction, text: param, systemActionKind: kind)
        case "lit":
            // lit <held|set|rainbow> [<r> <g> <b>]
            let mode = parts.count >= 2 ? (LightOutputMode(rawValue: parts[1]) ?? .whileHeld) : .whileHeld
            var color = OutputAction.defaultLightColor
            if parts.count >= 5, let r = Int(parts[2]), let g = Int(parts[3]), let b = Int(parts[4]) {
                color = RGBLightColor(r: UInt8(clamping: r), g: UInt8(clamping: g), b: UInt8(clamping: b))
            }
            return OutputAction(type: .lightBar, lightColor: color, lightMode: mode)
        case "txt":
            // txt <percent-encoded text>
            let decoded = parts.count >= 2 ? (parts[1].removingPercentEncoding ?? "") : ""
            return OutputAction(type: .typeText, text: decoded)
        case "app":
            // app <kind> [<target preset uuid>]
            guard parts.count >= 2, let kind = AppActionKind(rawValue: parts[1]) else { return nil }
            let target = parts.count >= 3 ? UUID(uuidString: parts[2]) : nil
            return OutputAction(type: .appAction, appActionKind: kind, targetPresetID: target)
        default:
            return nil
        }
    }

    // Custom coding to handle UUID stability. Every stored property must be
    // listed: a property left out of a hand-written key set is silently
    // never written, and `clickX` / `clickY` were exactly that, so a click
    // parked on a screen point was shown in the row and lost on relaunch.
    enum CodingKeys: String, CodingKey {
        case id, type, keyCode, mouseButtonIndex, clickX, clickY, mouseAxis, mouseDirection, speed
        case midiNote, midiVelocity, midiCCNumber, midiCCValue, midiChannel
        case midiProgramNumber, midiTransport
        case text
        case appActionKind, targetPresetID
        case systemActionKind
        case lightColor, lightMode
    }
}
