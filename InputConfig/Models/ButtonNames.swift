import Foundation

/// What each controller family calls its buttons, by InputConfig index, so
/// the editor, the Live Visualizer and the automatic rows all name a
/// button the way it is printed on the pad. One table per family; the
/// families are the preset Buttons choices (see FaceLetters).
///
/// Index meanings follow the app's standard numbering (0 is the bottom
/// face button, 4 and 5 the bumpers, 8 the left center button, 9 the right
/// one, 10 the home button), except where a controller's decoder numbers
/// its own: the 2015 Steam Controller (SteamControllerButton), the 2026
/// Steam Controller past 12, and the GameCube controllers.
///
/// One rule for the Face button names setting, used by every surface: a
/// known family names its buttons as printed, and the setting decides the
/// face letters for a pad of no known family and for the Xbox family,
/// since many 8BitDo pads printed B on the bottom report themselves as
/// Xbox pads. Positions puts compass names on the face buttons of every pad.
enum ButtonNames {

    /// The full name of a button for a family, or nil when the family has
    /// no name of its own for that index (the generic name is used then).
    static func name(_ index: Int, family: FaceLetters) -> String? {
        table(for: family)[index]
    }

    /// Every named button of a family, lowest index first: what the
    /// editor's button menu lists for a preset made for that family.
    static func all(for family: FaceLetters) -> [(index: Int, label: String)] {
        table(for: family).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// The name every surface shows for a button: the family's own, with
    /// the Face button names setting applied by the rule above, and a
    /// model's own names (a DualShock 4's Share) on top.
    static func label(_ index: Int, family: FaceLetters?, model: ModelNames = .none,
                      choice: FaceLetters = FaceLetters.current) -> String {
        if let renamed = model.renamed[index] { return renamed }
        let fam = family.flatMap { $0 == .automatic || $0 == .positions ? nil : $0 }
        if choice == .positions || family == .positions, let compass = positionName(index, family: fam) {
            return compass
        }
        if index < 4, fam == nil || fam == .xbox, choice == .playstation || choice == .nintendo,
           let face = FaceLetters.genericName(index, choice: choice) {
            return face
        }
        if let fam, let named = name(index, family: fam) { return named }
        if fam == nil, let face = FaceLetters.genericName(index, choice: choice) { return face }
        return combined[index] ?? "Button \(index)"
    }

    /// An input's name for lists and search: a button or axis by the
    /// family's name ("Cross", "L2 +"), anything else as it always reads.
    static func inputName(_ event: InputEvent, family: FaceLetters?, model: ModelNames = .none) -> String {
        switch event.type {
        case .button:
            return label(event.index, family: family, model: model)
        case .axis:
            guard let name = axisName(event.index, family: family) else { return event.displayName }
            return "\(name) \(event.axisDirection?.displayName ?? "+")"
        case .touchpad where family?.isSteam == true:
            let pad = event.touchpadSurface == 1 ? "Left trackpad" : "Right trackpad"
            let positive = event.axisDirection != .negative
            let dir = event.touchpadAxis == .y ? (positive ? "down" : "up") : (positive ? "right" : "left")
            return "\(pad) slide \(dir)"
        case .touchpadGesture where family?.isSteam == true:
            let pad = event.touchpadSurface == 1 ? "Left trackpad" : "Right trackpad"
            let kind: String
            switch event.touchpadGestureKind {
            case .doubleTap?: kind = "double tap"
            case .twoFingerTap?: kind = "two-finger tap"
            case .oneFingerTap?, nil: kind = "tap"
            }
            return "\(pad) \(kind)"
        default:
            return event.displayName
        }
    }

    /// The buttons a family lists, named by `label`, without the ones the
    /// model does not have.
    static func labels(for family: FaceLetters?, model: ModelNames = .none,
                       choice: FaceLetters = FaceLetters.current) -> [(index: Int, label: String)] {
        let fam = family.flatMap { $0 == .automatic || $0 == .positions ? nil : $0 }
        return all(for: fam ?? .automatic)
            .filter { !model.absent.contains($0.index) }
            .map { ($0.index, label($0.index, family: family, model: model, choice: choice)) }
    }

    /// The compass name of a face button on a family's numbering: the
    /// 2015 Steam Controller has its face buttons at 4 to 7, and a GameCube
    /// pad has B (1) on the left of A and X (2) on the right.
    static func positionName(_ index: Int, family: FaceLetters?) -> String? {
        if family == .gameCube {
            return [0: "South", 1: "West", 2: "East", 3: "North"][index]
        }
        if family == .steamController {
            let steam: [Int: Int] = [SteamControllerButton.a.rawValue: 0, SteamControllerButton.b.rawValue: 1,
                                     SteamControllerButton.x.rawValue: 2, SteamControllerButton.y.rawValue: 3]
            return steam[index].flatMap { FaceLetters.positionName($0) }
        }
        return FaceLetters.positionName(index)
    }

    /// Short labels for the visualizer's shoulder, trigger and center
    /// buttons (4, 5, 6, 7, 8, 9, 10), by standard position; nil where the
    /// family has no such button. A nil family gets names that fit any pad.
    static func short(_ index: Int, family: FaceLetters?, model: ModelNames = .none) -> String? {
        if let renamed = model.short[index] { return renamed }
        switch family {
        case .playstation?:
            return [4: "L1", 5: "R1", 6: "L2", 7: "R2", 8: "Create", 9: "Options", 10: "PS"][index]
        case .stadia?:
            return [4: "L1", 5: "R1", 6: "L2", 7: "R2", 8: "Options", 9: "Menu", 10: "Stadia"][index]
        case .nintendo?:
            return [4: "L", 5: "R", 6: "ZL", 7: "ZR", 8: "\u{2212}", 9: "+", 10: "Home"][index]
        case .gameCube?:
            return [4: "L", 5: "Z", 6: "L", 7: "R", 9: "Start", 10: "Home"][index]
        case .steamController2026?:
            return [4: "L1", 5: "R1", 6: "L2", 7: "R2", 8: "View", 9: "Menu", 10: "Steam"][index]
        case .steamController?:
            // Standard positions, drawn through the 2015 numbering.
            return [4: "LB", 5: "RB", 6: "LT", 7: "RT", 8: "Back", 9: "Start", 10: "Steam"][index]
        case .xbox?:
            return [4: "LB", 5: "RB", 6: "LT", 7: "RT", 8: "View", 9: "Menu", 10: "Xbox"][index]
        case .automatic?, .positions?, nil:
            return [4: "LB", 5: "RB", 6: "LT", 7: "RT", 8: "Select", 9: "Start", 10: "Home"][index]
        }
    }

    /// An axis's name for a family: the sticks, the triggers as that family
    /// prints them, and the Steam Controllers' trackpads. Nil past what the
    /// family has (an extra axis keeps its number), and nil for every axis
    /// when no family is known, since a flight stick or wheel reports its
    /// twist and pedals on the same indices.
    static func axisName(_ index: Int, family: FaceLetters?) -> String? {
        guard let fam = family else { return nil }
        switch (fam, index) {
        case (.steamController, 0): return "Stick X"
        case (.steamController, 1): return "Stick Y"
        case (.steamController, 2): return "Right trackpad X"
        case (.steamController, 3): return "Right trackpad Y"
        case (.steamController, 6), (.steamController2026, 6): return "Left trackpad X"
        case (.steamController, 7), (.steamController2026, 7): return "Left trackpad Y"
        case (.steamController2026, 8): return "Right trackpad X"
        case (.steamController2026, 9): return "Right trackpad Y"
        case (.steamController2026, 10): return "Left trackpad pressure"
        case (.steamController2026, 11): return "Right trackpad pressure"
        case (.gameCube, 0): return "Control stick X"
        case (.gameCube, 1): return "Control stick Y"
        case (.gameCube, 2): return "C-stick X"
        case (.gameCube, 3): return "C-stick Y"
        case (.gameCube, 4): return "L (analog)"
        case (.gameCube, 5): return "R (analog)"
        case (_, 0): return "Left stick X"
        case (_, 1): return "Left stick Y"
        case (_, 2): return "Right stick X"
        case (_, 3): return "Right stick Y"
        case (.automatic, 4), (.positions, 4): return "Left trigger"
        case (.automatic, 5), (.positions, 5): return "Right trigger"
        case (_, 4): return short(6, family: fam)
        case (_, 5): return short(7, family: fam)
        default: return nil
        }
    }

    /// The family a connected controller names its buttons in, from its
    /// brand, or nil when its brand prints them either way.
    static func family(forBrand brand: ControllerBrand, steam2026: Bool = false) -> FaceLetters? {
        if steam2026 { return .steamController2026 }
        switch brand {
        case .dualSense, .dualShock4, .accessController: return .playstation
        case .xbox: return .xbox
        case .switchPro, .joyConLeft, .joyConRight, .joyConPair: return .nintendo
        case .stadia: return .stadia
        case .steamController: return .steamController
        default: return nil
        }
    }

    /// Whether a family numbers its buttons its own way, so a row written
    /// for it means a different control on any other pad.
    static func ownNumbering(_ family: FaceLetters?) -> Bool {
        family == .steamController || family == .steamController2026 || family == .gameCube
    }

    /// The family a slot's rows are named in. The preset's Buttons choice
    /// wins, except where the connected pad and the preset number their
    /// buttons differently (a Steam Controller preset on an Xbox pad):
    /// then the names follow the pad, because a row fires from whatever
    /// control sends its index.
    static func resolve(preset: FaceLetters?, device: FaceLetters?, connected: Bool) -> FaceLetters? {
        let pinned = preset.flatMap { $0 == .automatic ? nil : $0 }
        guard connected else { return pinned ?? device }
        if ownNumbering(device) { return device }
        if let pinned, ownNumbering(pinned) { return device }
        return pinned ?? device
    }

    /// Where one model differs from its family's table: the name it prints
    /// on a button, and the buttons it does not have.
    struct ModelNames: Equatable {
        var renamed: [Int: String] = [:]
        var short: [Int: String] = [:]
        var absent: Set<Int> = []
        static let none = ModelNames()

        /// A DualShock 4 prints SHARE where a DualSense prints Create, and a
        /// DualShock 3 has SELECT and START; neither has the DualSense's
        /// mute button or the Edge's back and Fn buttons.
        static func of(brand: ControllerBrand?, dualShock3: Bool) -> ModelNames {
            if dualShock3 {
                return ModelNames(renamed: [8: "Select", 9: "Start"], short: [8: "Select", 9: "Start"],
                                  absent: [13, 15, 16, 17, 20, 21])
            }
            if brand == .dualShock4 {
                return ModelNames(renamed: [8: "Share"], short: [8: "Share"], absent: [15, 16, 17, 20, 21])
            }
            return .none
        }
    }

    private static func table(for family: FaceLetters) -> [Int: String] {
        switch family {
        case .xbox: return xbox
        case .playstation: return playStation
        case .nintendo: return nintendo
        case .stadia: return stadia
        case .gameCube: return gameCube
        case .steamController: return steam2015
        case .steamController2026: return steam2026
        case .positions: return positions
        case .automatic: return combined
        }
    }

    /// No family chosen and none known: both common names.
    static let combined: [Int: String] = [
        0: "A / Cross", 1: "B / Circle", 2: "X / Square", 3: "Y / Triangle",
        4: "LB / L1", 5: "RB / R1", 6: "LT / L2 (digital)", 7: "RT / R2 (digital)",
        8: "Back / Share / Select", 9: "Start / Options", 10: "Home / PS / Guide",
        11: "L3 (left stick click)", 12: "R3 (right stick click)", 13: "Touchpad press",
        14: "Share (where exposed)", 15: "Microphone / Mute",
        16: "Left back button / Elite P1 (upper right)", 17: "Right back button / Elite P2 (lower right)",
        18: "Elite P3 (upper left)", 19: "Elite P4 (lower left)",
        20: "FN 1 / Left Function", 21: "FN 2 / Right Function",
    ]

    static let xbox: [Int: String] = [
        0: "A", 1: "B", 2: "X", 3: "Y",
        4: "LB", 5: "RB", 6: "LT (digital)", 7: "RT (digital)",
        8: "View", 9: "Menu", 10: "Xbox button",
        11: "Left stick press", 12: "Right stick press",
        14: "Share",
        // Elite paddles: P1 and P2 on the right, P3 and P4 on the left.
        16: "Paddle P1 (upper right)", 17: "Paddle P2 (lower right)",
        18: "Paddle P3 (upper left)", 19: "Paddle P4 (lower left)",
    ]

    static let playStation: [Int: String] = [
        0: "Cross", 1: "Circle", 2: "Square", 3: "Triangle",
        4: "L1", 5: "R1", 6: "L2 (digital)", 7: "R2 (digital)",
        8: "Create / Share", 9: "Options", 10: "PS button",
        11: "L3 (left stick press)", 12: "R3 (right stick press)",
        13: "Touchpad press", 15: "Mute",
        // DualSense Edge: two back buttons and two Fn buttons.
        16: "Left back button (Edge)", 17: "Right back button (Edge)",
        20: "Left Fn (Edge)", 21: "Right Fn (Edge)",
    ]

    static let nintendo: [Int: String] = [
        0: "B", 1: "A", 2: "Y", 3: "X",
        4: "L", 5: "R", 6: "ZL", 7: "ZR",
        8: "Minus", 9: "Plus", 10: "Home",
        11: "Left stick press", 12: "Right stick press",
        14: "Capture",
        // Switch 2 Pro Controller: C and the two back buttons.
        15: "C", 16: "GL (left back button)", 17: "GR (right back button)",
    ]

    static let stadia: [Int: String] = [
        0: "A", 1: "B", 2: "X", 3: "Y",
        4: "L1", 5: "R1", 6: "L2 (digital)", 7: "R2 (digital)",
        8: "Options", 9: "Menu", 10: "Stadia button",
        11: "L3 (left stick press)", 12: "R3 (right stick press)",
        14: "Capture",
    ]

    /// The GameCube controller, on the numbering both GameCube decoders
    /// use (the adapter's ports and the Switch 2 model): A is the big
    /// button, L reads at 4 and 6 so a bumper row and a trigger-click row
    /// both fire from it, and the Switch 2 model adds Home, Capture, C, ZL.
    static let gameCube: [Int: String] = [
        0: "A", 1: "B", 2: "X", 3: "Y",
        4: "L (as a bumper)", 5: "Z",
        6: "L (full press)", 7: "R (full press)",
        9: "Start", 10: "Home (Switch 2 model)",
        14: "Capture (Switch 2 model)", 15: "C (Switch 2 model)", 16: "ZL (Switch 2 model)",
    ]

    /// Face buttons by compass point; everything else keeps both names.
    static let positions: [Int: String] = {
        var t = combined
        t[0] = "South"; t[1] = "East"; t[2] = "West"; t[3] = "North"
        return t
    }()

    /// The original Steam Controller, on its own numbering.
    static let steam2015: [Int: String] = Dictionary(uniqueKeysWithValues:
        SteamControllerButton.allCases.filter { $0 != .stickActive }.map { ($0.bindingIndex, $0.displayName) })

    /// The 2026 Steam Controller, on the numbering its decoder uses.
    static let steam2026: [Int: String] = Dictionary(uniqueKeysWithValues:
        ControllerProfileDatabase.steamController2026ButtonNames.enumerated().map { ($0.offset, $0.element) })
}
