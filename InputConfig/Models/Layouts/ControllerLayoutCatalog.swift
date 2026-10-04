import Foundation

/// Every controller model the Live Visualizer can draw.
enum ControllerLayoutCatalog {
    static let all: [ControllerLayout] = [
        .steamController2026,
        .steamController2015,
        .dualSense,
        .dualSenseEdge,
        .dualShock4,
        .dualShock3,
        .psAccess,
        .xboxSeries,
        .xboxOne,
        .xboxElite2,
        .xboxAdaptive,
        .switchPro,
        .switch2Pro,
        .joyConPair,
        .joyConLeft,
        .joyConRight,
        .joyCon2Pair,
        .gameCubeSwitch2,
        .gameCubeAdapter,
        .nsoN64,
        .nsoSNES,
        .nsoGenesis,
        .stadia,
        .eightBitDoUltimate,
        .eightBitDoUltimate2C,
        .eightBitDoPro2,
        .eightBitDoPro3,
        .eightBitDoSN30Pro,
        .eightBitDoMicro,
        .eightBitDoLite,
        .eightBitDoLiteSE,
        .eightBitDoArcade,
        .backboneOne,
        .razerKishiV2,
        .gameSirG8,
        .genericGamepad,
        .genericSNES,
        .arcadeStick,
        .leverless,
        .logitechExtreme3D,
        .thrustmasterT16000M,
        .logitechG29,
        .logitechWheel,
        .thrustmasterT300,
        .unrecognizedHID,
    ]

    private static let byID: [ControllerModelID: ControllerLayout] =
        Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    /// Drawings for devices the app reads but that are not yet tested on
    /// hardware (12 Device Verification, Appendix A, not rated GREEN). In a
    /// Release build they are hidden: the device is still read the same
    /// way, and drawn with the generic drawing.
    static let experimentalIDs: Set<ControllerModelID> = [
        .dualShock3, .switch2Pro, .joyCon2Pair, .gameCubeSwitch2, .gameCubeAdapter,
        .nsoN64, .nsoSNES, .nsoGenesis,
        .eightBitDoUltimate, .eightBitDoPro3, .eightBitDoMicro, .eightBitDoLite, .eightBitDoLiteSE, .eightBitDoArcade,
        .backboneOne, .razerKishiV2, .gameSirG8,
        .arcadeStick, .leverless, .logitechExtreme3D, .thrustmasterT16000M,
        .logitechWheel, .thrustmasterT300,
    ]

    /// The hidden setting that shows experimental drawings in a Release
    /// build: defaults write com.inputconfig.app
    /// InputConfig.showExperimentalControllerDrawings -bool true
    nonisolated static let showExperimentalKey = "InputConfig.showExperimentalControllerDrawings"

    /// Whether experimental drawings are shown: only with the hidden setting
    /// on, in every build, so a Debug build shows what customers see. The
    /// test suites still render every drawing.
    nonisolated static var showsExperimental: Bool {
        #if DEBUG
        if NSClassFromString("XCTestCase") != nil { return true }
        #endif
        return UserDefaults.standard.bool(forKey: showExperimentalKey)
    }

    /// Whether a layout may be drawn now.
    nonisolated static func isShown(_ layout: ControllerLayout) -> Bool {
        !layout.experimental || showsExperimental
    }

    /// The layout for a model id (its variant ignored), or nil for an id a
    /// later build wrote, or for an experimental drawing that is hidden.
    static func layout(_ id: ControllerModelID) -> ControllerLayout? {
        byID[id.base].flatMap { isShown($0) ? $0 : nil }
    }

    /// The layout for a model id whether or not it is shown.
    static func anyLayout(_ id: ControllerModelID) -> ControllerLayout? { byID[id.base] }

    /// The picker's sections, in maker order, without hidden drawings.
    static var byMaker: [(maker: Maker, layouts: [ControllerLayout])] {
        Maker.allCases.compactMap { maker in
            let list = all.filter { $0.maker == maker && $0.id != .unrecognizedHID && isShown($0) }
            return list.isEmpty ? nil : (maker, list)
        }
    }
}
