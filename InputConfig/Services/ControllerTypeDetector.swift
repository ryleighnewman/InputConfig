import Foundation
import GameController

/// Identifies the brand and family of a connected controller from the
/// information exposed by GameController. Used to display familiar button
/// labels (Nintendo, PlayStation, Xbox layouts) and to drive controller-
/// specific help links.
enum ControllerBrand: String, CaseIterable {
    case dualSense       // PS5 DualSense and DualSense Edge
    case dualShock4      // PS4 DualShock 4
    case accessController // PlayStation Access controller: one stick, eight button sockets
    case xbox            // Xbox One, Series S/X, Elite
    case switchPro       // Nintendo Switch Pro Controller
    case joyConLeft      // Single Joy-Con (left)
    case joyConRight     // Single Joy-Con (right)
    case joyConPair      // Two Joy-Cons fused as one virtual controller (iOS 16+/macOS 13+)
    case stadia          // Google Stadia controller
    case eightBitDo      // 8BitDo Pro 2, Ultimate, SN30, etc. in Apple mode
    case steamController // Valve Steam Controller (read via raw HID, NOT MFi)
    case mfiGeneric      // Generic MFi gamepad
    case unknown

    var displayName: String {
        switch self {
        case .dualSense:   return "DualSense"
        case .dualShock4:  return "DualShock 4"
        case .accessController: return "Access Controller"
        case .xbox:        return "Xbox"
        case .switchPro:   return "Switch Pro"
        case .joyConLeft:  return "Joy-Con (L)"
        case .joyConRight: return "Joy-Con (R)"
        case .joyConPair:  return "Joy-Con Pair"
        case .stadia:      return "Stadia"
        case .eightBitDo:  return "8BitDo"
        case .steamController: return "Steam Controller"
        case .mfiGeneric:  return "Generic Gamepad"
        case .unknown:     return "Controller"
        }
    }

    /// The hardware manufacturer (who makes the device), as opposed to
    /// `displayName` which is the product/model line. Shown in the
    /// controller info popover's "Brand" row - a DualSense's brand is
    /// Sony, not "DualSense".
    var manufacturer: String {
        switch self {
        case .dualSense, .dualShock4,
             .accessController:                     return "Sony"
        case .xbox:                                 return "Microsoft"
        case .switchPro, .joyConLeft,
             .joyConRight, .joyConPair:             return "Nintendo"
        case .stadia:                               return "Google"
        case .eightBitDo:                           return "8BitDo"
        case .steamController:                      return "Valve"
        case .mfiGeneric:                           return "MFi"
        case .unknown:                              return "Unknown"
        }
    }

    /// Has a customizable RGB light bar (Sony controllers only).
    var hasLightBar: Bool {
        switch self {
        case .dualSense, .dualShock4: return true
        default: return false
        }
    }

    /// Has a clickable touchpad surface (Sony controllers only).
    var hasTouchpad: Bool {
        switch self {
        case .dualSense, .dualShock4: return true
        default: return false
        }
    }

    /// Has gyro / accelerometer motion sensors InputConfig reads. Sony pads
    /// only, matching Help and the Motion Cursor notes; the Smart Preset
    /// Maker offered gyro aim on Nintendo pads that the rest of the app
    /// says are not supported. A connected pad that does report motion
    /// still works in any motion row.
    var hasMotion: Bool {
        switch self {
        case .dualSense, .dualShock4: return true
        default: return false
        }
    }

    /// Short human summary of the controller's special capabilities, for the
    /// Smart Preset Maker so it only surfaces options the hardware supports.
    var capabilitySummary: String {
        var caps: [String] = []
        if hasLightBar { caps.append("light bar") }
        if hasTouchpad { caps.append("touchpad") }
        if hasMotion { caps.append("motion / gyro") }
        return caps.isEmpty ? "standard buttons & sticks" : caps.joined(separator: " · ")
    }

    /// Whether the four face buttons use Nintendo naming (B/A/Y/X) instead
    /// of the PlayStation/Xbox style (A/B/X/Y).
    var usesNintendoLayout: Bool {
        switch self {
        case .switchPro, .joyConLeft, .joyConRight, .joyConPair:
            return true
        default:
            return false
        }
    }

    /// Whether this is a single Joy-Con (which has a unique button layout
    /// since it is only half of a normal controller).
    var isSingleJoyCon: Bool {
        switch self {
        case .joyConLeft, .joyConRight: return true
        default: return false
        }
    }
}

enum ControllerTypeDetector {
    /// Inspect a GCController and return our best guess at its brand. Apple
    /// surfaces brand information through `vendorName` and `productCategory`,
    /// neither of which is fully standardized, so we match on substrings.
    ///
    /// On macOS 13+ Apple's GameController framework exposes the Switch Pro
    /// Controller and Joy-Cons as MFi-compatible extended gamepads with
    /// product categories that include "Joy-Con" or "Switch". Stadia, 8BitDo,
    /// and Xbox controllers identify similarly. For anything that does not
    /// match a known brand we fall back to `.mfiGeneric` so the UI still
    /// renders sensible labels.
    static func detect(_ controller: GCController) -> ControllerBrand {
        let profile: GamepadProfile = {
            switch controller.extendedGamepad {
            case is GCDualSenseGamepad: return .dualSense
            case is GCDualShockGamepad: return .dualShock
            case is GCXboxGamepad: return .xbox
            case .some: return .extended
            case nil: return .none
            }
        }()
        return detect(category: controller.productCategory, vendor: controller.vendorName ?? "", profile: profile)
    }

    /// The GameController profile class a pad comes with.
    enum GamepadProfile: Sendable { case dualSense, dualShock, xbox, extended, none }

    /// The brand from what GameController says about a pad: its product
    /// category, its name and its profile class. Separate from the
    /// GCController so DeviceIdentityTests runs this same logic on the
    /// identities real pads present.
    static func detect(category: String, vendor: String, profile: GamepadProfile) -> ControllerBrand {
        let named = brand(fromName: "\(vendor.lowercased()) \(category.lowercased())")
        // 8BitDo, Nintendo and PlayStation names decide first.
        if let named, named != .xbox, named != .stadia { return named }

        // By profile as well as name: GameController models the PlayStation
        // Access Controller (and any pad whose name says neither) through
        // these, so they get PlayStation labels either way.
        if profile == .dualSense { return .dualSense }
        if profile == .dualShock { return .dualShock4 }
        // Xbox family: by name, or by the Xbox profile GameController gives
        // every Xbox Wireless Controller whatever it is called.
        if named == .xbox || profile == .xbox { return .xbox }
        if named == .stadia { return .stadia }

        // Anything else that conforms to GCExtendedGamepad is a generic MFi controller.
        if profile != .none { return .mfiGeneric }
        return .unknown
    }

    /// The brand a controller's name (vendor and product category) says,
    /// or nil when the name says none. The Test Bench checks this same
    /// function, so its brand tests exercise the shipped logic.
    static func brand(fromName name: String) -> ControllerBrand? {
        let combined = name.lowercased()

        // 8BitDo first: in its other modes an 8BitDo pad can report an Xbox
        // or Switch Pro name, and it should still read as an 8BitDo when
        // its own name says so.
        if combined.contains("8bitdo") || combined.contains("8-bit") {
            return .eightBitDo
        }

        // Nintendo Switch family
        if combined.contains("joy-con") || combined.contains("joycon") {
            if combined.contains("(l)") || combined.contains("left") {
                return .joyConLeft
            } else if combined.contains("(r)") || combined.contains("right") {
                return .joyConRight
            } else if combined.contains("pair") || combined.contains("combined") {
                return .joyConPair
            }
            // If we cannot determine left/right, fall through to pair as the
            // closest catch-all.
            return .joyConPair
        }

        if combined.contains("switch pro") || combined.contains("pro controller") ||
           combined.contains("nintendo") {
            return .switchPro
        }

        // PlayStation family. The Access controller first: GameController
        // may model it as a DualSense, yet it has no light bar, touchpad or
        // motion sensors, and the PlayStation FPS preset does not fit it.
        if combined.contains("access controller") {
            return .accessController
        }
        if combined.contains("dualsense") || combined.contains("dual sense") {
            return .dualSense
        }
        if combined.contains("dualshock") || combined.contains("ds4") || combined.contains("wireless controller") && combined.contains("sony") {
            return .dualShock4
        }

        // Xbox family by name.
        if combined.contains("xbox") || combined.contains("xinput") {
            return .xbox
        }

        // Google Stadia
        if combined.contains("stadia") {
            return .stadia
        }
        return nil
    }
}

/// Which names the four face buttons are shown with. InputConfig names
/// buttons by position (button 0 is the bottom one); what differs between
/// pads is the letter printed there: A on Xbox-style pads, B on Switch pads
/// and on the many 8BitDo pads printed Nintendo style. The Switch family is
/// detected; an 8BitDo usually reports itself as an Xbox pad, so its owner
/// picks in Settings. Positions names them by compass point instead (South
/// is the bottom button on every pad), for anyone who finds letters that
/// move between controllers harder to keep straight. Only the names shown
/// change, never a preset.
enum FaceLetters: String, CaseIterable, Identifiable, Codable {
    case automatic, xbox, playstation, nintendo, positions
    /// Families a preset can be made for, beyond the face letters: each
    /// names every button its own way (see ButtonNames).
    case stadia, steamController, steamController2026, gameCube
    var id: String { rawValue }

    /// The choices for Settings' Face button names, which sets letters
    /// for any pad; the controller families are a preset's choice.
    static let settingsChoices: [FaceLetters] = [.automatic, .xbox, .playstation, .nintendo, .positions]

    /// The choices for a preset's Buttons picker, with their menu titles.
    static let presetChoices: [FaceLetters] = [.automatic, .xbox, .playstation, .nintendo, .stadia,
                                               .gameCube, .steamController, .steamController2026]

    var menuTitle: String {
        switch self {
        case .automatic: return "Automatic"
        case .xbox: return "Xbox"
        case .playstation: return "PlayStation"
        case .nintendo: return "Nintendo"
        case .positions: return "Positions"
        case .stadia: return "Stadia"
        case .steamController: return "Steam Controller (2015)"
        case .steamController2026: return "Steam Controller (2026)"
        case .gameCube: return "GameCube"
        }
    }

    /// The family a preset made for this brand is named in, or nil when the
    /// brand prints its buttons either way (8BitDo, generic pads) and the
    /// connected controller and Settings should decide. Same mapping as
    /// ButtonNames.family(forBrand:).
    static func family(for brand: ControllerBrand) -> FaceLetters? {
        ButtonNames.family(forBrand: brand)
    }
    var isSteam: Bool { self == .steamController || self == .steamController2026 }

    static let defaultsKey = "InputConfig.faceLetters"

    static var current: FaceLetters {
        FaceLetters(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .automatic
    }

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .xbox: return "Xbox: A on the bottom"
        case .playstation: return "PlayStation: Cross on the bottom"
        case .nintendo: return "Nintendo: B on the bottom"
        case .positions: return "Positions: North, South, East, West"
        case .stadia: return "Stadia"
        case .steamController: return "Steam Controller (2015)"
        case .steamController2026: return "Steam Controller (2026)"
        case .gameCube: return "GameCube"
        }
    }

    /// Whether a pad of this brand shows B / A / Y / X. PlayStation pads keep
    /// their symbols whatever letters are chosen.
    static func nintendo(for brand: ControllerBrand, choice: FaceLetters = current) -> Bool {
        if brand == .dualSense || brand == .dualShock4 || brand == .accessController { return false }
        switch choice {
        case .automatic: return brand.usesNintendoLayout
        case .xbox, .playstation, .positions, .stadia, .steamController, .steamController2026, .gameCube: return false
        case .nintendo: return true
        }
    }

    /// Whether a pad's face buttons are named Cross, Circle, Square, and
    /// Triangle: always on a PlayStation pad, and on any pad when that is
    /// the choice.
    static func playStation(for brand: ControllerBrand, choice: FaceLetters = current) -> Bool {
        brand == .dualSense || brand == .dualShock4 || brand == .accessController || choice == .playstation
    }

    /// The compass name of a face button (0 is the bottom one), or nil for
    /// any other button.
    static func positionName(_ index: Int) -> String? {
        switch index {
        case 0: return "South"
        case 1: return "East"
        case 2: return "West"
        case 3: return "North"
        default: return nil
        }
    }

    /// One letter for the visualizer's round buttons: S, E, W, N.
    static func positionInitial(_ index: Int) -> String? {
        positionName(index).map { String($0.prefix(1)) }
    }

    /// The editor's name for a face button of a pad with no known family:
    /// both names ("A / Cross") on Automatic, else the chosen letters; nil
    /// for the other buttons.
    static func genericName(_ index: Int, choice: FaceLetters = current) -> String? {
        if choice == .positions { return positionName(index) }
        if choice == .xbox || choice == .nintendo {
            return ButtonNames.name(index, family: choice).flatMap { index < 4 ? $0 : nil }
        }
        if choice == .playstation {
            switch index {
            case 0: return "Cross"
            case 1: return "Circle"
            case 2: return "Square"
            case 3: return "Triangle"
            default: return nil
            }
        }
        return index < 4 ? ButtonNames.combined[index] : nil
    }
}
