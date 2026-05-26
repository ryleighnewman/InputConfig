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

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .button: return "Button"
        case .axis: return "Axis"
        case .hat: return "Hat"
        case .touchpad: return "Touchpad"
        case .touchpadRegion: return "Touchpad Region"
        case .motion: return "Motion"
        }
    }
}

/// Which motion-sensor channel a `.motion` input reads.
///
///   .gyroX        - rotation around the controller's X axis (pitch up/down)
///   .gyroY        - rotation around the Y axis (yaw left/right)
///   .gyroZ        - rotation around the Z axis (roll left/right)
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
        case .gyroX:      return "Gyro X (pitch rate)"
        case .gyroY:      return "Gyro Y (yaw rate)"
        case .gyroZ:      return "Gyro Z (roll rate)"
        case .accelX:     return "Accel X"
        case .accelY:     return "Accel Y"
        case .accelZ:     return "Accel Z"
        case .rollAngle:  return "Roll angle"
        case .pitchAngle: return "Pitch angle"
        case .yawAngle:   return "Yaw angle"
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
        case .x: return "X (left/right)"
        case .y: return "Y (up/down)"
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
        case .up: return "Up"
        case .right: return "Right"
        case .down: return "Down"
        case .left: return "Left"
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
    /// Motion-sensor channel for `.motion` inputs.
    var motionChannel: MotionChannel?

    var displayName: String {
        switch type {
        case .button:
            return "Button \(index)"
        case .axis:
            let dir = axisDirection?.displayName ?? "+"
            return "Axis \(index) \(dir)"
        case .hat:
            let dir = hatDirection?.displayName ?? "Up"
            return "Hat \(index) \(dir)"
        case .touchpad:
            let finger = (touchpadFinger ?? 0) + 1
            let axis = touchpadAxis?.rawValue.uppercased() ?? "X"
            let dir = axisDirection?.displayName ?? "+"
            return "Touchpad F\(finger) \(axis) \(dir)"
        case .touchpadRegion:
            // The region name lives in TouchpadService; we resolve it where
            // we have access (BindingRowView). The serialized id is enough
            // for storage but not human-friendly, so just show "Region".
            return "Touchpad Region"
        case .motion:
            let ch = motionChannel?.displayName ?? "Motion"
            let dir = axisDirection?.displayName ?? "+"
            return "\(ch) \(dir)"
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
            return "tpd \(finger) \(axis) \(dir)"
        case .touchpadRegion:
            // Region UUIDs are stored as 32-char lowercase hex (no dashes)
            // to keep the binding key short. Missing IDs serialize to all-zeros.
            let raw = (touchpadRegionID ?? UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)))
                .uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            return "tpr \(raw)"
        case .motion:
            let ch = motionChannel?.rawValue ?? "gyroY"
            let dir = axisDirection?.rawValue ?? "+"
            return "mtn \(ch) \(dir)"
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
                  let finger = Int(parts[1]),
                  let axis = TouchpadAxis(rawValue: parts[2]) else { return nil }
            let dir = AxisDirection(rawValue: parts[3]) ?? .positive
            return InputEvent(type: .touchpad, index: finger,
                              axisDirection: dir,
                              touchpadFinger: finger,
                              touchpadAxis: axis)
        case "tpr":
            guard parts.count >= 2 else { return nil }
            // Restore canonical UUID format from the 32-char compact form.
            let raw = parts[1]
            guard raw.count == 32 else { return nil }
            let dashed = "\(raw.prefix(8))-\(raw.dropFirst(8).prefix(4))-\(raw.dropFirst(12).prefix(4))-\(raw.dropFirst(16).prefix(4))-\(raw.dropFirst(20).prefix(12))"
            guard let uuid = UUID(uuidString: dashed.uppercased()) else { return nil }
            return InputEvent(type: .touchpadRegion, index: 0,
                              touchpadRegionID: uuid)
        case "mtn":
            guard parts.count >= 3,
                  let channel = MotionChannel(rawValue: parts[1]) else { return nil }
            let dir = AxisDirection(rawValue: parts[2]) ?? .positive
            return InputEvent(type: .motion, index: 0,
                              axisDirection: dir,
                              motionChannel: channel)
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

    static func touchpadRegion(_ id: UUID) -> InputEvent {
        InputEvent(type: .touchpadRegion, index: 0, touchpadRegionID: id)
    }

    static func motion(_ channel: MotionChannel, direction: AxisDirection) -> InputEvent {
        InputEvent(type: .motion, index: 0,
                   axisDirection: direction, motionChannel: channel)
    }
}
