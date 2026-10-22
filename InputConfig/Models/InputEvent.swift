import Foundation

/// Represents a joystick input event type
enum InputType: String, Codable, CaseIterable, Identifiable {
    case button = "btn"
    case axis = "axi"
    case hat = "hat"
    /// Multi-touch trackpad surface on DualSense / DualShock 4. Reports
    /// per-frame X/Y deltas while a finger is in contact.
    case touchpad = "tpd"
    /// Tap on a user-defined region of the touchpad. Behaves like a button:
    /// pressed while any finger is inside the region, released on exit.
    case touchpadRegion = "tpr"
    /// Motion sensors (gyroscope + accelerometer). Behaves like a half-axis:
    /// tilt forward on the X axis yields a positive value, tilt backward
    /// yields a negative value. Available on controllers whose `motion`
    /// property is non-nil (DualSense, DualShock 4, Switch Pro, Joy-Con).
    case motion = "mtn"
    /// Key on an external keyboard (anything reported through IOHIDManager
    /// as a Generic Desktop / Keyboard usage). Behaves like a button; the
    /// HID usage code is stored in `index`.
    case extKey = "ekb"
    /// Button or axis on an external mouse. `extMouseKind` discriminates
    /// between button, scroll, and motion sub-roles. Motion / scroll
    /// behave as half-axes; button behaves like a button.
    case extMouse = "ems"
    /// A user-defined rectangular zone on the Mac display, evaluated
    /// against the cursor's current position. Same model as
    /// `.touchpadRegion` but the "finger" is the mouse cursor -
    /// lets a Mac trackpad / mouse user reuse the region-binding
    /// workflow without DualSense hardware.
    case cursorRegion = "crg"
    /// A user-defined rectangular zone on a joystick stick's X/Y
    /// plane. Lets the user bind diagonal/quadrant deflections
    /// directly (e.g. "stick pushed to upper-right corner") instead
    /// of having to combine separate axis + or axis - half-bindings.
    /// Index = stick index (0 = left, 1 = right).
    case stickRegion = "srg"
    /// Quick gesture on the controller's touchpad surface: two-finger
    /// tap, two-finger swipes, etc. Stored discriminator is in
    /// `touchpadGestureKind`. Behaves like a button - fires for one
    /// poll frame when the gesture is recognized.
    case touchpadGesture = "tpg"
    /// A physical tap on the Mac's own chassis, read from the built-in
    /// accelerometer. `index` carries the tap count, 1 to 5.
    case chassisTap = "cht"
    /// A gesture made with a stick: one or more flicks (out past a set
    /// reach, then back to the middle) in chosen directions or into stick
    /// zones, such as pulling the stick straight back twice. `index` is the
    /// stick (0 left, 1 right), `gestureSteps` the flicks in order. Fires
    /// like a quick button press when the last flick lands.
    case stickGesture = "sgs"
    /// A message from an external MIDI device (keyboard, pad controller,
    /// knob box). Notes and pads behave like buttons; CC knobs, pitch
    /// bend, and aftertouch behave like analog axes. `index` carries the
    /// note or CC number, `midiChannel` the 1-16 channel (nil = any),
    /// and `midiKind` which message family it is.
    case midi = "mid"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .button: return String(localized: "Button")
        case .axis: return String(localized: "Axis")
        case .hat: return String(localized: "Hat")
        case .touchpad: return String(localized: "Touchpad")
        case .touchpadRegion: return String(localized: "Touchpad region")
        case .motion: return String(localized: "Motion")
        case .extKey: return String(localized: "Keyboard Key")
        case .extMouse: return String(localized: "Mouse")
        case .cursorRegion: return String(localized: "Screen region")
        case .stickRegion: return String(localized: "Stick region")
        case .stickGesture: return String(localized: "Stick gesture")
        case .touchpadGesture: return String(localized: "Touchpad Gesture")
        case .chassisTap: return String(localized: "Tap the Mac")
        case .midi: return "MIDI"
        }
    }
}

/// Recognized gesture kinds for an `.touchpadGesture` input. Detected
/// by `TouchpadService`'s gesture state machine - the model just stores
/// the discriminator.
enum TouchpadGestureKind: String, Codable, CaseIterable, Identifiable {
    /// Two fingers touch and lift within ~250 ms with very little
    /// movement on either contact. The most useful "modifier" gesture
    /// because it's instantly recognizable and doesn't conflict with
    /// scrolling / region taps.
    case twoFingerTap
    /// One finger lands and lifts within ~300 ms with little movement
    /// and without the pad being pressed down. Distinct from the
    /// touchpad press (button 13), which is a physical click.
    case oneFingerTap
    /// Two one-finger taps in quick succession (the second lands within
    /// 350 ms of the first lifting).
    case doubleTap

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .twoFingerTap: return String(localized: "Two-finger tap")
        case .oneFingerTap: return String(localized: "Touchpad tap (one finger)")
        case .doubleTap: return String(localized: "Touchpad double tap")
        }
    }
}

/// Which family of MIDI message an `.midi` input listens for.
enum MIDIInputKind: String, Codable, CaseIterable, Identifiable {
    /// Note on / off. Fires like a button while the key or pad is held.
    case note
    /// Control Change (knobs, sliders, sustain pedals, mod wheel).
    /// Continuous, so it can drive an axis as well as a threshold.
    case cc
    /// Pitch bend wheel. Center-detented, so it reads as a bipolar axis.
    case pitchBend
    /// Program Change - fires momentarily like a button press.
    case programChange
    /// Channel aftertouch (pressure applied after the key is down).
    case aftertouch
    /// System Real-Time transport: Start, Continue, or Stop from a
    /// sequencer, drum machine, or DAW. `index` carries the status byte
    /// (0xFA Start, 0xFB Continue, 0xFC Stop); there is no channel.
    /// Fires momentarily like Program Change.
    case transport

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .note:          return String(localized: "Note")
        case .cc:            return String(localized: "Control Change")
        case .pitchBend:     return String(localized: "Pitch Bend")
        case .programChange: return String(localized: "Program Change")
        case .aftertouch:    return String(localized: "Aftertouch")
        case .transport:     return String(localized: "Transport")
        }
    }

    /// Start, Continue, or Stop for a transport status byte.
    static func transportName(_ status: Int) -> String {
        switch status {
        case 0xFB: return String(localized: "Continue")
        case 0xFC: return String(localized: "Stop")
        default:   return String(localized: "Start")
        }
    }

    /// True when the message carries a continuous value that can drive an
    /// analog output (mouse motion, scroll) rather than only a press.
    var isContinuous: Bool {
        switch self {
        case .cc, .pitchBend, .aftertouch: return true
        case .note, .programChange, .transport: return false
        }
    }

    /// True when the message has a per-message number (note number, CC
    /// number). Pitch bend and aftertouch are per-channel, so their
    /// number field is unused.
    var usesNumber: Bool {
        switch self {
        case .note, .cc, .programChange, .transport: return true
        case .pitchBend, .aftertouch:                return false
        }
    }
}

/// How a `.midi` Control Change binding interprets the knob or slider.
/// Only meaningful when `midiKind == .cc`; every other message family
/// ignores it.
enum MIDICCMode: String, Codable, CaseIterable, Identifiable {
    /// The 1.2 behavior and the default: fires like a switch once the
    /// value passes the halfway point. Right for sustain pedals and
    /// on/off style CCs.
    case threshold
    /// Speed-from-center: the knob's center (64) is zero, distance from
    /// center sets the output speed, side sets the direction, and the
    /// binding's deadzone keeps it silent near center. Behaves like an
    /// analog stick axis, including variable-speed mouse and scroll.
    case centered
    /// Relative nudges: each turn fires the outputs as short pulses,
    /// clockwise for the + direction and counterclockwise for -. Built
    /// for volume-up/down, brightness, and stepped scrolling.
    case relative

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .threshold: return String(localized: "Switch (past halfway)")
        case .centered:  return String(localized: "Dial (speed from center)")
        case .relative:  return String(localized: "Turn (nudge per step)")
        }
    }

    /// Short badge used inside the row's display name.
    var badge: String? {
        switch self {
        case .threshold: return nil
        case .centered:  return String(localized: "Dial")
        case .relative:  return String(localized: "Turn")
        }
    }
}

/// Sub-role of an `.extMouse` input. Maps the same physical mouse onto
/// multiple bindable sources without exploding the InputType enum.
enum ExtMouseKind: String, Codable, CaseIterable, Identifiable {
    case button
    case moveX
    case moveY
    case scrollX
    case scrollY
    /// Force Touch trackpad pressure as a threshold input: fires while the
    /// press force is past the threshold. Mac trackpads report continuous
    /// pressure through NSEvent while pressed.
    case pressure
    /// Force Click (pressure stage 2): the deliberate deep press.
    case deepPress
    /// Two clicks of the same button in quick succession, as macOS counts
    /// them (a double tap with tap-to-click on a trackpad is the same
    /// thing). Fires once, briefly, on the second click.
    case doubleClick
    /// Fingers are on the trackpad or Magic Mouse scrolling, from the
    /// moment the gesture begins until the fingers lift and any momentum
    /// runs out. A wheel mouse never reports this.
    case scrollGesture
    /// A pen on a tablet (Wacom, Huion, XP-Pen, Gaomon): the tip's pressure
    /// 0 to 1 past a light threshold.
    case penPressure
    /// The pen's tilt, -1 to 1 each way; a direction row fires past a quarter.
    case penTiltX
    case penTiltY
    /// The pen's barrel buttons, by number from the tablet's bitmask.
    case penButton
    /// The eraser end is the one near the tablet.
    case penEraser
    /// A pen is within reach of the tablet.
    case penInRange

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .button:  return String(localized: "Button")
        case .moveX:   return String(localized: "Move X")
        case .moveY:   return String(localized: "Move Y")
        case .scrollX: return String(localized: "Scroll X")
        case .scrollY: return String(localized: "Scroll Y")
        case .pressure: return String(localized: "Pressure (Force Touch)")
        case .deepPress: return String(localized: "Deep Press")
        case .doubleClick: return String(localized: "Double click")
        case .scrollGesture: return String(localized: "Scroll gesture")
        case .penPressure: return String(localized: "Pen pressure")
        case .penTiltX: return String(localized: "Pen tilt X")
        case .penTiltY: return String(localized: "Pen tilt Y")
        case .penButton: return String(localized: "Pen button")
        case .penEraser: return String(localized: "Pen eraser")
        case .penInRange: return String(localized: "Pen in range")
        }
    }
}

/// Which motion-sensor channel a `.motion` input reads.
///
///   .gyroX        - rotation around the controller's X axis (pitch): + is nose up
///   .gyroY        - sideways tilt (roll): + is the right side down
///   .gyroZ        - turning flat like a torch (yaw about the real vertical): + is a turn to the right
///
/// Signs were checked by hand on a DualSense through GCMotion on the Mac.
/// The bundled presets bind gyroY + to pointer right (straight) and gyroX +
/// to pointer up (crossed, since screen Y grows downward).
///   .accelX/Y/Z   - linear acceleration on the matching axis (gravity removed)
///   .rollAngle    - absolute attitude roll (Euler)
///   .pitchAngle   - absolute attitude pitch
///   .yawAngle     - absolute attitude yaw
enum MotionChannel: String, Codable, CaseIterable, Identifiable {
    case gyroX
    case gyroY
    case gyroZ
    case accelX
    case accelY
    case accelZ
    case rollAngle
    case pitchAngle
    case yawAngle

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gyroX:      return String(localized: "Gyro X")
        case .gyroY:      return String(localized: "Gyro Y")
        case .gyroZ:      return String(localized: "Gyro Z")
        case .accelX:     return String(localized: "Accel X")
        case .accelY:     return String(localized: "Accel Y")
        case .accelZ:     return String(localized: "Accel Z")
        case .rollAngle:  return String(localized: "Roll angle")
        case .pitchAngle: return String(localized: "Pitch angle")
        case .yawAngle:   return String(localized: "Yaw angle")
        }
    }

    /// Fuller description used in the dropdown menu so the picker
    /// label stays short but the menu items remain self-explanatory.
    var menuDescription: String {
        switch self {
        case .gyroX:      return String(localized: "Gyro X (pitch rate)")
        case .gyroY:      return String(localized: "Gyro Y (sideways tilt)")
        case .gyroZ:      return String(localized: "Gyro Z (turn)")
        default:          return displayName
        }
    }
}

/// Which axis of the touchpad surface the binding follows. X moves horizontal,
/// Y moves vertical. Combined with `AxisDirection` to pick a half-axis.
enum TouchpadAxis: String, Codable, CaseIterable, Identifiable {
    case x = "x"
    case y = "y"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .x: return String(localized: "X (left/right)")
        case .y: return String(localized: "Y (up/down)")
        }
    }
}

/// Direction for axis inputs
enum AxisDirection: String, Codable, CaseIterable, Identifiable {
    case positive = "+"
    case negative = "-"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .positive: return "+"
        case .negative: return "-"
        }
    }

    /// As VoiceOver says it: a voice drops a lone "-", so both halves of a
    /// stick sounded the same.
    var spokenName: String {
        switch self {
        case .positive: return String(localized: "plus")
        case .negative: return String(localized: "minus")
        }
    }
}

/// Direction for hat (D-pad) inputs
enum HatDirection: String, Codable, CaseIterable, Identifiable {
    case up = "U"
    case right = "R"
    case down = "D"
    case left = "L"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .up: return String(localized: "Up")
        case .right: return String(localized: "Right")
        case .down: return String(localized: "Down")
        case .left: return String(localized: "Left")
        }
    }
}

/// Represents a specific joystick input (button press, axis movement, or hat direction)
struct InputEvent: Codable, Hashable, Identifiable {
    var id: String { serialized }

    var type: InputType
    var index: Int
    var axisDirection: AxisDirection?
    var hatDirection: HatDirection?
    /// Touchpad finger index (0 = primary, 1 = secondary). Only valid for `.touchpad`.
    var touchpadFinger: Int?
    /// Touchpad axis (X or Y). Only valid for `.touchpad`.
    var touchpadAxis: TouchpadAxis?
    /// ID of the user-defined touchpad region. Only valid for `.touchpadRegion`.
    /// Serialized as a hex UUID string in the binding JSON.
    var touchpadRegionID: UUID?
    /// ID of the user-defined cursor region. Only valid for `.cursorRegion`.
    /// Same on-disk format as `touchpadRegionID` - kept on a separate
    /// field so the two region kinds don't collide in tooling.
    var cursorRegionID: UUID?
    /// Recognized touchpad gesture (two-finger tap, etc.). Only valid
    /// for `.touchpadGesture`. Stored as the raw enum string in JSON
    /// so older saves without the field decode as nil.
    var touchpadGestureKind: TouchpadGestureKind?
    /// Motion-sensor channel for `.motion` inputs.
    var motionChannel: MotionChannel?
    /// Stable ID of the external keyboard / mouse the binding listens to.
    /// `nil` means "any" matching device. Only valid for `.extKey` /
    /// `.extMouse`. Serialized as "any" when nil to keep the binding
    /// string portable across machines.
    var extDeviceID: String?
    /// Sub-role for `.extMouse` inputs.
    var extMouseKind: ExtMouseKind?
    /// ID of the user-defined stick region. Only valid for `.stickRegion`.
    /// Same on-disk format as `touchpadRegionID`; the stickIndex (left
    /// vs right stick) is carried in the InputEvent's `index` field.
    var stickRegionID: UUID?
    /// Which MIDI message family this input listens for. Only valid for
    /// `.midi`.
    var midiKind: MIDIInputKind?
    /// MIDI channel 1-16, or nil for "any channel". Only valid for `.midi`.
    var midiChannel: Int?
    /// Stable ID of the MIDI source endpoint this binding listens to.
    /// nil means "any connected MIDI device", which is the friendly
    /// default: a preset keeps working when the user plugs in a
    /// different keyboard. Only valid for `.midi`.
    var midiDeviceID: String?
    /// Knob interpretation for `.cc` bindings. nil decodes as
    /// `.threshold`, so presets saved before this field existed keep
    /// their exact behavior.
    var midiCCMode: MIDICCMode?
    /// Turn-mode sensitivity: raw CC units of travel per nudge. nil means
    /// the default of 4 (a full knob sweep is about 32 nudges). Smaller
    /// is finer. Only meaningful when `midiCCMode == .relative`.
    var midiTurnStep: Int?
    /// Which touch surface a touchpad input reads: nil or 0 the main one
    /// (a PlayStation touchpad, a Steam Controller's right trackpad), 1 the
    /// second (a Steam Controller's left trackpad). Serialized as a
    /// trailing " s1" only for surface 1, so every older row is unchanged.
    var touchpadSurface: Int? = nil
    /// The flicks of a `.stickGesture`, in order.
    var gestureSteps: [GestureStep]? = nil

    var displayName: String {
        switch type {
        case .button:
            return String(localized: "Button \(index)")
        case .axis:
            let dir = axisDirection?.displayName ?? "+"
            return String(localized: "Axis \(index) \(dir)")
        case .hat:
            let dir = hatDirection?.displayName ?? String(localized: "Up")
            return String(localized: "Hat \(index) \(dir)")
        case .touchpad:
            let finger = min(max(touchpadFinger ?? 0, 0), 9) + 1
            let axis = touchpadAxis?.rawValue.uppercased() ?? "X"
            let dir = axisDirection?.displayName ?? "+"
            return touchpadSurface == 1
                ? String(localized: "Left trackpad F\(finger) \(axis) \(dir)")
                : String(localized: "Touchpad F\(finger) \(axis) \(dir)")
        case .touchpadRegion:
            // The region name lives in TouchpadService; we resolve it where
            // we have access (BindingRowView). The serialized id is enough
            // for storage but not human-friendly, so just show "Region".
            return String(localized: "Touchpad region")
        case .motion:
            let ch = motionChannel?.displayName ?? String(localized: "Motion")
            let dir = axisDirection?.displayName ?? "+"
            return "\(ch) \(dir)"
        case .extKey:
            // What the keycap shows under the current layout, or the key's
            // name in the app's language.
            return KeyCodeMap.name(for: index)
        case .extMouse:
            let kind = extMouseKind?.displayName ?? String(localized: "Button")
            switch extMouseKind ?? .button {
            case .button:
                return String(localized: "Mouse Button \(index &+ 1)")  // counted from 1, as the row and mouse map do
            case .moveX, .moveY, .scrollX, .scrollY:
                let dir = axisDirection?.displayName ?? "+"
                return String(localized: "Mouse \(kind) \(dir)")
            case .pressure:
                return String(localized: "Trackpad Pressure")
            case .deepPress:
                return String(localized: "Trackpad Deep Press")
            case .doubleClick:
                return String(localized: "Mouse Double Click \(index &+ 1)")
            case .scrollGesture:
                return String(localized: "Scroll Gesture")
            case .penPressure:
                return String(localized: "Pen Pressure")
            case .penTiltX:
                return String(localized: "Pen Tilt \(axisDirection?.displayName ?? "+")")
            case .penTiltY:
                return String(localized: "Pen Tilt \(axisDirection == .negative ? "Up" : "Down")")
            case .penButton:
                return String(localized: "Pen Button \(index &+ 1)")
            case .penEraser:
                return String(localized: "Pen Eraser")
            case .penInRange:
                return String(localized: "Pen In Range")
            }
        case .cursorRegion:
            // Like `.touchpadRegion`, the human name lives in the
            // CursorRegionService and is resolved in the binding row.
            return String(localized: "Screen region")
        case .stickRegion:
            if StickRegionService.isBandKey(index) {
                return String(localized: "\(StickRegionService.axisDisplayName(index - StickRegionService.bandKeyBase)) region")
            }
            return index == 1 ? String(localized: "Right stick region") : String(localized: "Left stick region")
        case .stickGesture:
            let stick = index == 1 ? String(localized: "Right stick") : String(localized: "Left stick")
            return String(localized: "\(stick) gesture: \(GestureStep.describe(gestureSteps ?? []))")
        case .touchpadGesture:
            return touchpadGestureKind?.displayName ?? String(localized: "Touchpad Gesture")
        case .chassisTap:
            switch index {
            case 2:  return String(localized: "Double tap the Mac")
            case 3:  return String(localized: "Triple tap the Mac")
            case 4:  return String(localized: "Quadruple tap the Mac")
            case 5:  return String(localized: "Quintuple tap the Mac")
            default: return String(localized: "Tap the Mac")
            }
        case .midi:
            let kind = midiKind ?? .note
            let chan = midiChannel.map { String(localized: "ch\($0)") } ?? String(localized: "any ch")
            switch kind {
            case .note:
                return String(localized: "MIDI \(MIDIService.noteName(index)) (\(chan))")
            case .cc:
                let dir = axisDirection.map { " \($0.displayName)" } ?? ""
                let mode = (midiCCMode?.badge).map { " \($0)" } ?? ""
                return String(localized: "MIDI CC \(index)\(mode)\(dir) (\(chan))")
            case .programChange:
                return String(localized: "MIDI Program \(index) (\(chan))")
            case .pitchBend:
                let dir = axisDirection.map { " \($0.displayName)" } ?? ""
                return String(localized: "MIDI Pitch Bend\(dir) (\(chan))")
            case .aftertouch:
                return String(localized: "MIDI Aftertouch (\(chan))")
            case .transport:
                return String(localized: "MIDI \(MIDIInputKind.transportName(index))")
            }
        }
    }

    /// Serialize to the original Joystick Mapper format: "btn 0", "axi 1 +", "hat 0 U",
    /// plus our extension: "tpd <finger 0|1> <axis x|y> <dir + or ->".
    var serialized: String {
        switch type {
        case .button:
            return "btn \(index)"
        case .axis:
            return "axi \(index) \(axisDirection?.rawValue ?? "+")"
        case .hat:
            return "hat \(index) \(hatDirection?.rawValue ?? "U")"
        case .touchpad:
            let finger = touchpadFinger ?? 0
            let axis = touchpadAxis?.rawValue ?? "x"
            let dir = axisDirection?.rawValue ?? "+"
            return "tpd \(finger) \(axis) \(dir)" + (touchpadSurface == 1 ? " s1" : "")
        case .touchpadRegion:
            // Region UUIDs are stored as 32-char lowercase hex (no dashes)
            // to keep the binding key short. Missing IDs serialize to all-zeros.
            let raw = (touchpadRegionID ?? UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)))
                .uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            // A Steam Controller's left trackpad, as touchpad rows mark it;
            // an older build reads the region and ignores the mark.
            return "tpr \(raw)" + (touchpadSurface == 1 ? " s1" : "")
        case .motion:
            let ch = motionChannel?.rawValue ?? "gyroY"
            let dir = axisDirection?.rawValue ?? "+"
            return "mtn \(ch) \(dir)"
        case .extKey:
            // "ekb <hid_code> <deviceID|any>"
            let dev = extDeviceID ?? "any"
            return "ekb \(index) \(dev)"
        case .extMouse:
            // "ems <kind> <indexOrZero> <dir> <deviceID|any>"
            let kind = (extMouseKind ?? .button).rawValue
            let dir = axisDirection?.rawValue ?? "+"
            let dev = extDeviceID ?? "any"
            return "ems \(kind) \(index) \(dir) \(dev)"
        case .cursorRegion:
            // "crg <32-char hex UUID>" - same format as .touchpadRegion's
            // "tpr" entry but lives in a separate namespace so the two
            // can't be confused at parse time.
            let raw = (cursorRegionID ?? UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)))
                .uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            return "crg \(raw)"
        case .stickRegion:
            // "srg <stickIndex> <32-char hex UUID>"
            let raw = (stickRegionID ?? UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)))
                .uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            return "srg \(index) \(raw)"
        case .stickGesture:
            // "sgs <stick> <step>.<step>" e.g. "sgs 0 d.d", pulled back twice
            let steps = (gestureSteps ?? []).map(\.token).joined(separator: ".")
            return "sgs \(index) \(steps.isEmpty ? "-" : steps)"
        case .touchpadGesture:
            // "tpg <kind>" e.g. "tpg twoFingerTap"
            return "tpg \(touchpadGestureKind?.rawValue ?? "twoFingerTap")" + (touchpadSurface == 1 ? " s1" : "")
        case .chassisTap:
            // "cht <count>" e.g. "cht 2" for a double tap
            return "cht \(index)"
        case .midi:
            // "mid <kind> <number> <channel|any> <dir> <deviceID|any>"
            // e.g. "mid note 60 any + any", "mid cc 74 1 + any"
            let kind = (midiKind ?? .note).rawValue
            let chan = midiChannel.map(String.init) ?? "any"
            let dir = axisDirection?.rawValue ?? "+"
            let dev = midiDeviceID ?? "any"
            // The mode token is appended only for non-default modes so the
            // serialized keys of every pre-existing binding stay identical.
            if let mode = midiCCMode, mode != .threshold {
                return "mid \(kind) \(index) \(chan) \(dir) \(dev) \(mode.rawValue)"
            }
            return "mid \(kind) \(index) \(chan) \(dir) \(dev)"
        }
    }

    /// Parse from serialized format
    static func parse(_ string: String) -> InputEvent? {
        let parts = string.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return nil }

        switch parts[0] {
        case "btn":
            guard let index = Int(parts[1]) else { return nil }
            return InputEvent(type: .button, index: index)
        case "axi":
            guard parts.count >= 3, let index = Int(parts[1]) else { return nil }
            let dir = AxisDirection(rawValue: parts[2]) ?? .positive
            return InputEvent(type: .axis, index: index, axisDirection: dir)
        case "hat":
            guard parts.count >= 3, let index = Int(parts[1]) else { return nil }
            let dir = HatDirection(rawValue: parts[2]) ?? .up
            return InputEvent(type: .hat, index: index, hatDirection: dir)
        case "tpd":
            guard parts.count >= 4,
                  let finger = Int(parts[1]), (0...9).contains(finger),
                  let axis = TouchpadAxis(rawValue: parts[2]) else { return nil }
            let dir = AxisDirection(rawValue: parts[3]) ?? .positive
            var event = InputEvent(type: .touchpad, index: finger,
                                   axisDirection: dir,
                                   touchpadFinger: finger,
                                   touchpadAxis: axis)
            if parts.count >= 5, parts[4] == "s1" { event.touchpadSurface = 1 }
            return event
        case "tpr":
            guard parts.count >= 2 else { return nil }
            // Restore canonical UUID format from the 32-char compact form.
            let raw = parts[1]
            guard raw.count == 32 else { return nil }
            let dashed = "\(raw.prefix(8))-\(raw.dropFirst(8).prefix(4))-\(raw.dropFirst(12).prefix(4))-\(raw.dropFirst(16).prefix(4))-\(raw.dropFirst(20).prefix(12))"
            guard let uuid = UUID(uuidString: dashed.uppercased()) else { return nil }
            var event = InputEvent(type: .touchpadRegion, index: 0,
                                   touchpadRegionID: uuid)
            if parts.count >= 3, parts[2] == "s1" { event.touchpadSurface = 1 }
            return event
        case "mtn":
            guard parts.count >= 3,
                  let channel = MotionChannel(rawValue: parts[1]) else { return nil }
            let dir = AxisDirection(rawValue: parts[2]) ?? .positive
            return InputEvent(type: .motion, index: 0,
                              axisDirection: dir,
                              motionChannel: channel)
        case "ekb":
            // "ekb <hid_code> <deviceID|any>"
            guard parts.count >= 3, let code = Int(parts[1]) else { return nil }
            let device = parts[2] == "any" ? nil : parts[2]
            return InputEvent(type: .extKey, index: code, extDeviceID: device)
        case "ems":
            // "ems <kind> <indexOrZero> <dir> <deviceID|any>"
            guard parts.count >= 5,
                  let kind = ExtMouseKind(rawValue: parts[1]),
                  let idx = Int(parts[2]) else { return nil }
            let dir = AxisDirection(rawValue: parts[3]) ?? .positive
            let device = parts[4] == "any" ? nil : parts[4]
            return InputEvent(type: .extMouse, index: idx,
                              axisDirection: dir,
                              extDeviceID: device,
                              extMouseKind: kind)
        case "crg":
            // "crg <32-char hex UUID>"
            guard parts.count >= 2 else { return nil }
            let raw = parts[1]
            guard raw.count == 32 else { return nil }
            let dashed = "\(raw.prefix(8))-\(raw.dropFirst(8).prefix(4))-\(raw.dropFirst(12).prefix(4))-\(raw.dropFirst(16).prefix(4))-\(raw.dropFirst(20).prefix(12))"
            guard let uuid = UUID(uuidString: dashed.uppercased()) else { return nil }
            return InputEvent(type: .cursorRegion, index: 0,
                              cursorRegionID: uuid)
        case "srg":
            // "srg <stickIndex> <32-char hex UUID>"
            guard parts.count >= 3,
                  let stickIdx = Int(parts[1]) else { return nil }
            let raw = parts[2]
            guard raw.count == 32 else { return nil }
            let dashed = "\(raw.prefix(8))-\(raw.dropFirst(8).prefix(4))-\(raw.dropFirst(12).prefix(4))-\(raw.dropFirst(16).prefix(4))-\(raw.dropFirst(20).prefix(12))"
            guard let uuid = UUID(uuidString: dashed.uppercased()) else { return nil }
            return InputEvent(type: .stickRegion, index: stickIdx,
                              stickRegionID: uuid)
        case "sgs":
            guard parts.count >= 3, let stick = Int(parts[1]), (0...1).contains(stick) else { return nil }
            let steps = parts[2].split(separator: ".").compactMap { GestureStep(token: String($0)) }
            return InputEvent(type: .stickGesture, index: stick, gestureSteps: Array(steps.prefix(GestureStep.maxSteps)))
        case "tpg":
            // "tpg <kind>" e.g. "tpg twoFingerTap"
            guard parts.count >= 2,
                  let kind = TouchpadGestureKind(rawValue: parts[1]) else { return nil }
            var event = InputEvent(type: .touchpadGesture, index: 0,
                                   touchpadGestureKind: kind)
            if parts.count >= 3, parts[2] == "s1" { event.touchpadSurface = 1 }
            return event
        case "cht":
            // "cht <count>"
            guard parts.count >= 2, let count = Int(parts[1]) else { return nil }
            // Up to five taps, as the detector counts and the editor offers;
            // clamped to three, quadruple and quintuple rows read "cht 4"
            // and "cht 5" as a triple tap.
            return InputEvent(type: .chassisTap, index: max(1, min(5, count)))
        case "mid":
            // "mid <kind> <number> <channel|any> <dir> <deviceID|any>"
            guard parts.count >= 3,
                  let kind = MIDIInputKind(rawValue: parts[1]),
                  let number = Int(parts[2]) else { return nil }
            let channel: Int? = parts.count > 3 ? Int(parts[3]) : nil
            let dir: AxisDirection = (parts.count > 4
                ? AxisDirection(rawValue: parts[4]) : nil) ?? .positive
            let device: String? = (parts.count > 5 && parts[5] != "any") ? parts[5] : nil
            let ccMode: MIDICCMode? = parts.count > 6 ? MIDICCMode(rawValue: parts[6]) : nil
            return InputEvent(type: .midi, index: number,
                              axisDirection: dir,
                              midiKind: kind,
                              midiChannel: channel,
                              midiDeviceID: device,
                              midiCCMode: ccMode)
        default:
            return nil
        }
    }

    static func button(_ index: Int) -> InputEvent {
        InputEvent(type: .button, index: index)
    }

    static func axis(_ index: Int, direction: AxisDirection) -> InputEvent {
        InputEvent(type: .axis, index: index, axisDirection: direction)
    }

    static func hat(_ index: Int, direction: HatDirection) -> InputEvent {
        InputEvent(type: .hat, index: index, hatDirection: direction)
    }

    static func touchpad(finger: Int, axis: TouchpadAxis, direction: AxisDirection) -> InputEvent {
        InputEvent(type: .touchpad, index: finger,
                   axisDirection: direction,
                   touchpadFinger: finger,
                   touchpadAxis: axis)
    }

    /// `count` is how many taps make the gesture, 1 to 5.
    static func chassisTap(_ count: Int) -> InputEvent {
        InputEvent(type: .chassisTap, index: count)
    }

    static func touchpadRegion(_ id: UUID) -> InputEvent {
        InputEvent(type: .touchpadRegion, index: 0, touchpadRegionID: id)
    }

    static func cursorRegion(_ id: UUID) -> InputEvent {
        InputEvent(type: .cursorRegion, index: 0, cursorRegionID: id)
    }

    static func stickRegion(stickIndex: Int, id: UUID) -> InputEvent {
        InputEvent(type: .stickRegion, index: stickIndex, stickRegionID: id)
    }

    static func stickGesture(stick: Int, _ steps: [GestureStep]) -> InputEvent {
        InputEvent(type: .stickGesture, index: stick, gestureSteps: steps)
    }

    static func touchpadGesture(_ kind: TouchpadGestureKind) -> InputEvent {
        InputEvent(type: .touchpadGesture, index: 0, touchpadGestureKind: kind)
    }

    static func motion(_ channel: MotionChannel, direction: AxisDirection) -> InputEvent {
        InputEvent(type: .motion, index: 0,
                   axisDirection: direction, motionChannel: channel)
    }

    /// A MIDI input. `number` is the note or CC number (ignored for pitch
    /// bend and aftertouch, which are per-channel). `channel` nil means any.
    static func midi(_ kind: MIDIInputKind,
                     number: Int,
                     channel: Int? = nil,
                     direction: AxisDirection = .positive,
                     deviceID: String? = nil,
                     ccMode: MIDICCMode? = nil) -> InputEvent {
        InputEvent(type: .midi, index: number,
                   axisDirection: direction,
                   midiKind: kind,
                   midiChannel: channel,
                   midiDeviceID: deviceID,
                   midiCCMode: ccMode)
    }

    static func extKey(hidCode: Int, deviceID: String? = nil) -> InputEvent {
        InputEvent(type: .extKey, index: hidCode, extDeviceID: deviceID)
    }

    static func extMouseButton(_ button: Int, deviceID: String? = nil) -> InputEvent {
        InputEvent(type: .extMouse, index: button,
                   extDeviceID: deviceID, extMouseKind: .button)
    }

    static func extMouseMotion(_ kind: ExtMouseKind,
                               direction: AxisDirection,
                               deviceID: String? = nil) -> InputEvent {
        InputEvent(type: .extMouse, index: 0,
                   axisDirection: direction,
                   extDeviceID: deviceID,
                   extMouseKind: kind)
    }
}

// MARK: - Stick gestures

/// The eight directions a stick can be flicked.
enum StickDirection: String, Codable, CaseIterable, Identifiable {
    case up = "u", down = "d", left = "l", right = "r"
    case upLeft = "ul", upRight = "ur", downLeft = "dl", downRight = "dr"

    var id: String { rawValue }

    /// Degrees counterclockwise from right, up is 90.
    var degrees: Double {
        switch self {
        case .right: return 0
        case .upRight: return 45
        case .up: return 90
        case .upLeft: return 135
        case .left: return 180
        case .downLeft: return 225
        case .down: return 270
        case .downRight: return 315
        }
    }

    var isDiagonal: Bool { [.upLeft, .upRight, .downLeft, .downRight].contains(self) }

    /// How far off its line a flick can land and still count: a straight
    /// direction takes its whole quarter, a diagonal the eighth around it.
    var tolerance: Double { isDiagonal ? 22.5 : 45 }

    var displayName: String {
        switch self {
        case .up: return String(localized: "Up")
        case .down: return String(localized: "Down")
        case .left: return String(localized: "Left")
        case .right: return String(localized: "Right")
        case .upLeft: return String(localized: "Up left")
        case .upRight: return String(localized: "Up right")
        case .downLeft: return String(localized: "Down left")
        case .downRight: return String(localized: "Down right")
        }
    }

    /// An arrow for the compact row label.
    var arrow: String {
        switch self {
        case .up: return "\u{2191}"
        case .down: return "\u{2193}"
        case .left: return "\u{2190}"
        case .right: return "\u{2192}"
        case .upLeft: return "\u{2196}"
        case .upRight: return "\u{2197}"
        case .downLeft: return "\u{2199}"
        case .downRight: return "\u{2198}"
        }
    }

    /// Whether a flick whose farthest point was at this angle counts.
    func matches(degrees angle: Double) -> Bool {
        var d = (angle - degrees).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d < -180 { d += 360 }
        return abs(d) <= tolerance
    }
}

/// One flick of a stick gesture: toward a direction, or into a stick zone.
struct GestureStep: Codable, Hashable {
    var direction: StickDirection?
    var zone: UUID?

    static let maxSteps = 8

    init(direction: StickDirection) { self.direction = direction; self.zone = nil }
    init(zone: UUID) { self.direction = nil; self.zone = zone }

    /// "u", "dl", or "z" and the zone's id as 32 hex digits.
    var token: String {
        if let direction { return direction.rawValue }
        let raw = (zone ?? UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))).uuidString
            .lowercased().replacingOccurrences(of: "-", with: "")
        return "z" + raw
    }

    init?(token: String) {
        if let d = StickDirection(rawValue: token) { self.init(direction: d); return }
        guard token.hasPrefix("z") else { return nil }
        let raw = String(token.dropFirst())
        guard raw.count == 32 else { return nil }
        let dashed = "\(raw.prefix(8))-\(raw.dropFirst(8).prefix(4))-\(raw.dropFirst(12).prefix(4))-\(raw.dropFirst(16).prefix(4))-\(raw.dropFirst(20).prefix(12))"
        guard let id = UUID(uuidString: dashed.uppercased()) else { return nil }
        self.init(zone: id)
    }

    /// "Down, Down" or with zone names where they are known (on the main
    /// thread, where the zones live).
    static func describe(_ steps: [GestureStep]) -> String {
        if steps.isEmpty { return String(localized: "no flicks yet") }
        return steps.map { step in
            if let d = step.direction { return d.displayName }
            if let id = step.zone, Thread.isMainThread,
               let name = MainActor.assumeIsolated({ StickRegionService.shared.region(with: id)?.region.shownName }) {
                return name
            }
            return String(localized: "a region")
        }.joined(separator: ", ")
    }
}

/// Recognizes stick gestures from the stick's position, frame by frame. A
/// flick starts when the stick passes the reach and ends when it comes
/// back near the middle; a flick held out longer than the limit is a push,
/// not a flick, and starts the gesture over (so driving or pointing with
/// the stick held back never counts).
struct StickGestureRecognizer {
    /// Settings, from the row.
    var reach: Double = 0.8
    var windowMs: Int = 600
    var maxFlickMs: Int = 400

    private(set) var progress = 0
    private var out = false
    private var outStart: Double = 0
    private var peak = (x: 0.0, y: 0.0, m: 0.0)
    private var heldTooLong = false
    private var lastStepAt: Double = 0

    /// Distance from the middle that counts as back at rest.
    var restRadius: Double { min(0.35, reach * 0.5) }

    /// One frame. `x` runs left to right and `y` top to bottom, -1...1, as
    /// the app reads a stick. Returns true on the frame the last flick of
    /// `steps` lands. `matches` decides whether a flick's farthest point
    /// fits a step.
    mutating func feed(x: Double, y: Double, now: Double, steps: [GestureStep],
                       matches: (GestureStep, Double, Double) -> Bool) -> Bool {
        guard !steps.isEmpty, x.isFinite, y.isFinite else { return false }
        let m = hypot(x, y)
        if progress > 0, !out, now - lastStepAt > Double(windowMs) / 1000 { progress = 0 }
        if !out {
            if m >= reach {
                out = true; outStart = now; peak = (x, y, m); heldTooLong = false
            }
            return false
        }
        if m > peak.m { peak = (x, y, m) }
        if maxFlickMs > 0, now - outStart > Double(maxFlickMs) / 1000 {
            heldTooLong = true
            progress = 0
        }
        guard m <= restRadius else { return false }
        out = false
        if heldTooLong { return false }
        if matches(steps[progress], peak.x, peak.y) {
            progress += 1
            lastStepAt = now
            if progress >= steps.count { progress = 0; return true }
        } else {
            // A wrong flick starts over, and may itself be the first step.
            progress = matches(steps[0], peak.x, peak.y) ? 1 : 0
            lastStepAt = now
            if progress >= steps.count { progress = 0; return true }
        }
        return false
    }

    /// Forget a gesture under way.
    mutating func reset() { progress = 0; out = false; heldTooLong = false }

    /// Whether a flick's farthest point fits a step: a direction by angle,
    /// a zone by the zone's own shape.
    @MainActor
    static func stepMatches(_ step: GestureStep, x: Double, y: Double, stick: Int? = nil) -> Bool {
        if let d = step.direction {
            return d.matches(degrees: atan2(-y, x) * 180 / .pi)
        }
        if let id = step.zone, let found = StickRegionService.shared.region(with: id),
           !StickRegionService.isBandKey(found.stickIndex), stick == nil || found.stickIndex == stick {
            return found.region.contains(normalizedX: (x + 1) / 2, y: (y + 1) / 2)
        }
        return false
    }
}
