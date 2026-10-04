import Foundation
import CoreGraphics

// What a controller looks like and which InputConfig inputs each of its
// controls produces, so the Live Visualizer draws the pad you hold and not a
// generic template. One `ControllerLayout` per model, each in its own file
// under Models/Layouts/<Maker>/, collected by ControllerLayoutCatalog.
//
// Coordinates. Every face is its own 0...1 square in x and y:
// - front: x 0 is the player's left, y 0 the edge farthest from the player
//   (where the bumpers are), y 1 the edge nearest the player (the grips).
// - top: the shoulder edge seen from above, x as on the front, y 0 the rear
//   edge, y 1 the edge that meets the front face. Bumpers and triggers.
// - back: the underside drawn as held, an x-ray: x 0 is still the player's
//   left, so a left paddle is at a small x. Paddles and back buttons.
// A control's `size` is its width (and height, unless `height` is set) as a
// fraction of the controller's width, so a stick of size 0.14 is the same
// size on every face. The face's height in points is width / aspect for the
// front, width * topStrip for the top, and width * backStrip for the back.

/// A controller model, stable across releases: it is what a group stores
/// (JoystickMapping.controllerModel). A dotted suffix names a variant of the
/// same hardware ("joycon-left.upright"). Unknown strings from a later build
/// load and save unchanged.
struct ControllerModelID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(_ raw: String) { rawValue = raw }

    /// The model without its variant.
    var base: ControllerModelID { ControllerModelID(String(rawValue.split(separator: ".").first ?? "")) }
    /// The variant after the dot, if any.
    var variant: String? {
        let parts = rawValue.split(separator: ".", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : nil
    }
    var description: String { rawValue }

    init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

extension ControllerModelID {
    static let steamController2026 = ControllerModelID("steam-2026")
    static let steamController2015 = ControllerModelID("steam-2015")
    static let dualSense = ControllerModelID("dualsense")
    static let dualSenseEdge = ControllerModelID("dualsense-edge")
    static let dualShock4 = ControllerModelID("dualshock-4")
    static let dualShock3 = ControllerModelID("dualshock-3")
    static let psAccess = ControllerModelID("ps-access")
    static let xboxSeries = ControllerModelID("xbox-series")
    static let xboxOne = ControllerModelID("xbox-one")
    static let xboxElite2 = ControllerModelID("xbox-elite-2")
    static let xboxAdaptive = ControllerModelID("xbox-adaptive")
    static let switchPro = ControllerModelID("switch-pro")
    static let switch2Pro = ControllerModelID("switch2-pro")
    static let joyConPair = ControllerModelID("joycon-pair")
    static let joyConLeft = ControllerModelID("joycon-left")
    static let joyConRight = ControllerModelID("joycon-right")
    static let joyCon2Pair = ControllerModelID("joycon2-pair")
    static let gameCubeSwitch2 = ControllerModelID("gamecube-switch2")
    static let gameCubeAdapter = ControllerModelID("gamecube-adapter")
    static let nsoN64 = ControllerModelID("nso-n64")
    static let nsoSNES = ControllerModelID("nso-snes")
    static let nsoGenesis = ControllerModelID("nso-genesis")
    static let stadia = ControllerModelID("stadia")
    static let eightBitDoUltimate = ControllerModelID("8bitdo-ultimate")
    static let eightBitDoUltimate2C = ControllerModelID("8bitdo-ultimate-2c")
    static let eightBitDoPro2 = ControllerModelID("8bitdo-pro2")
    static let eightBitDoPro3 = ControllerModelID("8bitdo-pro3")
    static let eightBitDoSN30Pro = ControllerModelID("8bitdo-sn30pro")
    static let eightBitDoMicro = ControllerModelID("8bitdo-micro")
    static let eightBitDoLite = ControllerModelID("8bitdo-lite")
    static let eightBitDoLiteSE = ControllerModelID("8bitdo-lite-se")
    static let eightBitDoArcade = ControllerModelID("8bitdo-arcade")
    static let backboneOne = ControllerModelID("backbone-one")
    static let razerKishiV2 = ControllerModelID("razer-kishi-v2")
    static let gameSirG8 = ControllerModelID("gamesir-g8")
    static let genericGamepad = ControllerModelID("generic-gamepad")
    static let genericSNES = ControllerModelID("generic-snes")
    static let arcadeStick = ControllerModelID("arcade-stick")
    static let leverless = ControllerModelID("leverless")
    static let logitechExtreme3D = ControllerModelID("logitech-extreme-3d")
    static let thrustmasterT16000M = ControllerModelID("thrustmaster-t16000m")
    static let logitechG29 = ControllerModelID("logitech-g29")
    static let logitechWheel = ControllerModelID("logitech-wheel")
    static let thrustmasterT300 = ControllerModelID("thrustmaster-t300")
    static let unrecognizedHID = ControllerModelID("unrecognized-hid")
}

/// Who makes it, for the picker's sections.
enum Maker: String, CaseIterable, Sendable {
    case sony, microsoft, nintendo, valve, google, eightBitDo, phoneGrip, arcadeAndSim, generic

    var title: String {
        switch self {
        case .sony: return "PlayStation"
        case .microsoft: return "Xbox"
        case .nintendo: return "Nintendo"
        case .valve: return "Valve"
        case .google: return "Google"
        case .eightBitDo: return "8BitDo"
        case .phoneGrip: return "Phone grips"
        case .arcadeAndSim: return "Arcade, flight and racing"
        case .generic: return "Other"
        }
    }
}

enum LayoutFace: String, Sendable { case front, top, back }

enum TriggerKind: Sendable { case analog, digital }

/// What a control is, which decides the widget that draws it.
enum ControlKind: Sendable, Equatable {
    case stick
    case trackpad
    case dpad
    case faceButton
    case menuButton
    case homeButton
    case shoulder
    case trigger(TriggerKind)
    case paddle
    case gripButton
    case light
    case slider
    case dial
    case key
    case pedal
    case wheel
    case hat
    case lever
    case port
    case other
}

/// The outline a widget draws.
enum ControlShape: Sendable, Equatable {
    case circle
    case capsule(angleDegrees: Double)
    case roundedRect(corner: Double)
    case squircle
    case trapezoid(topWidthRatio: Double)
    case crossPad
    case fourButtonPad
    case hybridDish
    case disc
    case octagonGate
}

/// Whether macOS reports the control to InputConfig.
enum Readability: Sendable, Equatable {
    case read
    /// Drawn dashed: the hardware has it, but it never reaches the app.
    case notReported(String)
    /// Read only in some setups (a mode switch, a firmware, Bluetooth only).
    case conditional(String)
}

/// How the app reads a connected pad, for inputs that differ by path.
enum ReadPath: Hashable, Sendable { case gameController, rawProfile, rawSDL, rawDescriptor, steamHelper }

enum AxisRole: Sendable, Equatable { case x, y, analog }

/// One axis a control drives.
struct AxisRef: Sendable, Equatable {
    var index: Int
    var role: AxisRole
    var unipolar: Bool = false
    static func x(_ i: Int) -> AxisRef { AxisRef(index: i, role: .x) }
    static func y(_ i: Int) -> AxisRef { AxisRef(index: i, role: .y) }
    static func analog(_ i: Int) -> AxisRef { AxisRef(index: i, role: .analog, unipolar: true) }
}

/// The InputConfig inputs a control produces.
struct ControlInputs: Sendable, Equatable {
    var buttons: [Int] = []
    var axes: [AxisRef] = []
    var hat: Int? = nil
    /// The button a stick or pad press sends.
    var press: Int? = nil
    /// The capacitive touch button (2026 Steam Controller sticks and grips).
    var touch: Int? = nil
    /// The axis a pad's pressure reads.
    var pressure: Int? = nil
    /// The digital copy of an analog trigger (btn 6 and 7).
    var digitalCopy: Int? = nil
    /// The touch surface a trackpad feeds (0 the main one, 1 the second).
    var surface: Int? = nil
    /// Buttons that are clicks on the edges of a pad (the 2015 Steam
    /// Controller's left pad D-pad).
    var edgeClicks: [Int]? = nil
    /// One direction of `hat`, for a control that is only that direction
    /// (the Xbox Adaptive's D-pad jacks).
    var hatDirection: HatDirection? = nil

    static let none = ControlInputs()
    static func button(_ i: Int) -> ControlInputs { ControlInputs(buttons: [i]) }
    static func stick(x: Int, y: Int, press: Int?) -> ControlInputs { ControlInputs(axes: [.x(x), .y(y)], press: press) }
    static func trigger(axis: Int, digital: Int?) -> ControlInputs { ControlInputs(axes: [.analog(axis)], digitalCopy: digital) }
    static func hat(_ i: Int) -> ControlInputs { ControlInputs(hat: i) }

    /// Every button index this control can send.
    var allButtons: [Int] {
        buttons + [press, touch, digitalCopy].compactMap { $0 } + (edgeClicks ?? [])
    }
}

/// A color a pad prints on a control. Nil means monochrome.
enum LayoutColor: Sendable, Equatable {
    case xboxGreen, xboxRed, xboxBlue, xboxYellow
    case psBlue, psRed, psPink, psGreen
    case gameCubeGreen, gameCubeRed
    case snesRed, snesYellow, snesBlue, snesGreen
    case gray
}

/// Which side of the control its function caption prefers.
enum CalloutSide: Sendable { case below, above, left, right, auto }

/// One control placed on a face.
struct PlacedControl: Sendable, Identifiable {
    var id: String
    var kind: ControlKind
    var face: LayoutFace = .front
    /// Center, 0...1 on its face (see the coordinate notes at the top).
    var center: CGPoint
    /// Width as a fraction of the controller's width.
    var size: CGFloat
    /// Height as a fraction of the controller's width, when not `size`.
    var height: CGFloat? = nil
    var shape: ControlShape = .circle
    /// What is printed on it. Nil means the family's name (ButtonNames).
    var printed: String? = nil
    /// An SF Symbol drawn instead of text (a share or home icon).
    var symbol: String? = nil
    var tint: LayoutColor? = nil
    var inputs: ControlInputs = .none
    /// Inputs that differ on a read path (a raw SDL row numbers a button
    /// differently than GameController does).
    var pathInputs: [ReadPath: ControlInputs] = [:]
    var readable: Readability = .read
    /// One line for the inspector ("Assignable in the controller's
    /// settings", "Reads as the left trackpad's D-pad").
    var note: String? = nil
    var callout: CalloutSide = .auto
    /// The id of a control this one sits on top of (a trackpad over its
    /// click), the only overlap validation allows.
    var overlayOf: String? = nil
    /// The variants this control exists on; nil means all of them.
    var variants: Set<String>? = nil
    /// What it is called in its inspector and to VoiceOver, for a control
    /// with nothing printed and no button name ("Left grip sensor").
    var name: String? = nil
    /// The key column its caption goes in, when the half of the canvas it
    /// sits in is the wrong one (a port left of its body's middle on a
    /// drawing whose body is off center); nil goes by the half.
    var keySide: CalloutSide? = nil

    /// Something the Mac reads: not a port, a light or a control that is
    /// not reported.
    var isMeaningful: Bool {
        if case .notReported = readable { return false }
        switch kind { case .port, .light: return false; default: return true }
    }

    func inputs(on path: ReadPath?) -> ControlInputs {
        path.flatMap { pathInputs[$0] } ?? inputs
    }
}

/// The shape a touch surface is drawn in.
enum TouchOutline: Sendable, Equatable { case rect, roundedSquare, circle, dualSenseFlare, ds4ConvexBottom }

/// A trackpad or touchpad as an input surface.
struct TouchSurfaceSpec: Sendable, Equatable {
    var surface: Int
    /// The PlacedControl that draws it.
    var controlID: String
    var name: String
    var outline: TouchOutline
    /// Width over height.
    var aspect: Double
    var maxFingers: Int
    var hasPressure: Bool = false
    var pressIndex: Int? = nil
    var touchIndex: Int? = nil
    var positionAxes: (x: Int, y: Int)? = nil
    var pressureAxis: Int? = nil
    var edgeClicks: [Int]? = nil
    var rotationDegrees: Double = 0

    static func == (l: Self, r: Self) -> Bool {
        l.surface == r.surface && l.controlID == r.controlID && l.name == r.name && l.outline == r.outline
            && l.aspect == r.aspect && l.maxFingers == r.maxFingers && l.hasPressure == r.hasPressure
            && l.pressIndex == r.pressIndex && l.touchIndex == r.touchIndex
            && l.positionAxes?.x == r.positionAxes?.x && l.positionAxes?.y == r.positionAxes?.y
            && l.pressureAxis == r.pressureAxis && l.edgeClicks == r.edgeClicks
            && l.rotationDegrees == r.rotationDegrees
    }
}

/// An input the pad sends that has no place on its body (a mode switch, a
/// state bit), with why.
struct OffBodyInput: Sendable {
    var serialized: String
    var reason: String
    /// A copy of a drawn control or a state bit, never a press of its own:
    /// left out of the canvas's "Also reported" line. Anything else the pad
    /// sends there (a function a profile gave a socket) is listed.
    var copy: Bool = false
}

/// How a connected device is recognized as this model. Rules inside one
/// array must all hold; any one array matching is enough.
enum MatchRule: Sendable {
    /// ControllerProfile.identifier prefix of the raw HID profile.
    case rawProfileIdentifier(String)
    case rawProfileLayout(String)
    case vidPid(vendor: Int, products: [Int])
    case vendor(Int)
    case gcProductCategoryContains(String)
    case gcVendorNameContains(String)
    case gcHasElement(String)
    case gcLacksElement(String)
    case brand(ControllerBrand)
    case steamHelper
}

enum ModelReadability: Sendable, Equatable {
    case full
    case partial(String)
    case notReadable(String)
}

struct LayoutVariant: Sendable {
    var id: String
    var displayName: String
    var isDefault: Bool = false
}

/// One controller model: what it looks like, what its controls send, and
/// how a connected one is recognized.
struct ControllerLayout: Sendable, Identifiable {
    var id: ControllerModelID
    var displayName: String
    var maker: Maker
    /// The naming family (ButtonNames) its legends follow.
    var family: FaceLetters?
    var modelNames: ButtonNames.ModelNames = .none
    /// Front face width over height.
    var aspect: CGFloat
    /// Top strip height as a fraction of the width (0 when nothing is on top).
    var topStrip: CGFloat = 0.2
    /// Back strip height as a fraction of the width (0 when nothing is on the back).
    var backStrip: CGFloat = 0
    var silhouette: Silhouette
    var touchSurfaces: [TouchSurfaceSpec] = []
    var controls: [PlacedControl]
    var variants: [LayoutVariant] = []
    var offBody: [OffBodyInput] = []
    var match: [[MatchRule]] = []
    /// Higher wins when two layouts match.
    var matchPriority: Int = 0
    var readability: ModelReadability = .full
    /// Positions are estimated, not measured from the hardware.
    var approximate: Bool = false
    /// Read by the app but not yet tested on hardware. In Release builds the
    /// drawing is hidden (the device gets the generic drawing) unless the
    /// hidden setting turns it on; see ControllerLayoutCatalog. The reading
    /// itself is the same either way.
    var experimental: Bool { ControllerLayoutCatalog.experimentalIDs.contains(id) }
    /// False for a model whose layout is not written yet: the canvas then
    /// draws the generic body with a note.
    var isComplete: Bool = true
    var sources: [String] = []
    /// The read paths `modelNames` is written for; nil means every path.
    /// A model whose numbering differs by path names only the one it fits.
    var modelNamesPaths: Set<ReadPath>? = nil
    /// The variant drawn for a connected pad from one maker, by USB vendor
    /// ID, when the group has not chosen one.
    var vendorVariants: [Int: String] = [:]
    /// The same by USB vendor and product, as vendor << 16 | product; it
    /// wins over `vendorVariants`.
    var productVariants: [Int: String] = [:]
    /// How far a wheel turns lock to lock, in degrees, so the drawing shows
    /// its angle; nil shows how far toward full lock instead.
    var steeringDegrees: Double? = nil
    /// The same for a model drawn as one of several variants.
    var variantSteeringDegrees: [String: Double] = [:]

    /// The steering range for the variant drawn.
    func steeringDegrees(variant: String?) -> Double? {
        (variant ?? defaultVariant).flatMap { variantSteeringDegrees[$0] } ?? steeringDegrees
    }

    /// The model names for a pad read on `path`.
    func modelNames(on path: ReadPath?) -> ButtonNames.ModelNames {
        guard let only = modelNamesPaths else { return modelNames }
        return path.map(only.contains) == true ? modelNames : .none
    }

    /// A placeholder for a model not drawn yet.
    static func stub(id: ControllerModelID, displayName: String, maker: Maker, family: FaceLetters?,
                     match: [[MatchRule]] = []) -> ControllerLayout {
        ControllerLayout(id: id, displayName: displayName, maker: maker, family: family, aspect: 1.5,
                         silhouette: .gamepad(), controls: [], match: match, isComplete: false)
    }

    func controls(on face: LayoutFace, variant: String? = nil) -> [PlacedControl] {
        controls.filter { c in
            guard c.face == face else { return false }
            guard let only = c.variants else { return true }
            guard let v = variant ?? defaultVariant else { return true }
            return only.contains(v)
        }
    }

    /// The variant drawn when none is chosen.
    var defaultVariant: String? { (variants.first { $0.isDefault } ?? variants.first)?.id }

    /// The variant when this layout still has it, else nil (a choice an
    /// earlier build stored, such as the Joy-Con's old "upright").
    func known(_ variant: String?) -> String? {
        variant.flatMap { v in variants.contains { $0.id == v } ? v : nil }
    }

    /// A strip is drawn only when it holds something the Mac reads: one of
    /// nothing but ports, lights and controls that send nothing is clutter.
    func hasTop(variant: String?) -> Bool { topStrip > 0 && controls(on: .top, variant: variant).contains(where: \.isMeaningful) }
    func hasBack(variant: String?) -> Bool { backStrip > 0 && controls(on: .back, variant: variant).contains(where: \.isMeaningful) }
    var hasTop: Bool { hasTop(variant: defaultVariant) }
    var hasBack: Bool { hasBack(variant: defaultVariant) }

    /// This layout with each control's inputs as a read path gives them.
    func reading(on path: ReadPath?) -> ControllerLayout {
        guard let path else { return self }
        var copy = self
        copy.modelNames = modelNames(on: path)
        copy.controls = controls.map { c in
            var c = c
            c.inputs = c.inputs(on: path)
            return c
        }
        return copy
    }

    func control(_ id: String) -> PlacedControl? { controls.first { $0.id == id } }
    func surface(forControl id: String) -> TouchSurfaceSpec? { touchSurfaces.first { $0.controlID == id } }
}
