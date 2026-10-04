import Foundation
import GameController

/// Which controller model the Live Visualizer draws for a slot, and why.
struct ResolvedLayout {
    enum Source { case connected, groupChoice, inferred, familyDefault }
    let layout: ControllerLayout
    /// The variant drawn (the group's choice, else the layout's default).
    var variant: String? = nil
    /// How the connected pad is read, for inputs that differ by path.
    var readPath: ReadPath? = nil
    let source: Source
    /// One line under the drawing when it is not simply the connected pad.
    let note: String?
}

/// Recognizes a connected controller as a catalog model, and picks a model
/// for a group with nothing connected: the group's choice, else what its
/// rows and Buttons family suggest.
@MainActor
enum ControllerLayoutResolver {

    static func resolve(service: GameControllerService, slot: Int, group: JoystickMapping?, preset: Preset) -> ResolvedLayout? {
        let connected = service.controllerDetails[slot] != nil || service.rawHIDGamepadSlots[slot] != nil
            || slot == service.steamControllerSlot
        let chosenID = group?.controllerModel.map(ControllerModelID.init(rawValue:))
        if connected {
            let path = readPath(service: service, slot: slot)
            let matched = match(service: service, slot: slot)
            // A pad no layout recognizes: a GameController pad is drawn as
            // the standard gamepad; a device read from its own report
            // descriptor keeps the drawing built from what it reports.
            // A pad read raw that no layout knows, on a group set to a model
            // (a SNES-style USB pad set to the SNES layout): that model.
            let chosenLayout = chosenID.flatMap(ControllerLayoutCatalog.layout)
            // A model chosen from the panel's menu is drawn even with another
            // pad connected: the menu refused the change while one was
            // plugged in. Automatic (no model) draws the pad as itself.
            if let chosen = chosenID, let chosenLayout, chosen.base != matched?.id {
                let here = matched?.displayName ?? service.controllerDetails[slot]?.name ?? "controller"
                return ResolvedLayout(layout: chosenLayout, variant: chosenLayout.known(chosen.variant) ?? chosenLayout.defaultVariant,
                                      readPath: path, source: .groupChoice,
                                      note: "Drawn as the \(chosenLayout.displayName) chosen for this group; the connected \(here) lights it. Choose Automatic to draw the connected controller.")
            }
            // A preset made for one controller (FPS (Xbox) with a DualSense
            // plugged in) is drawn as that controller, lit by the pad that is
            // here: the drawing showed the DualSense under Xbox rows. Only
            // between pads that number their controls the same way.
            if chosenID == nil, let group, let targetID = target(group: group, preset: preset),
               let target = ControllerLayoutCatalog.layout(targetID), matched?.id != target.id,
               !sameKind(matched, target), matched?.family?.isSteam != true, matched?.family != .gameCube {
                let here = matched?.displayName ?? service.controllerDetails[slot]?.name ?? "controller"
                return ResolvedLayout(layout: target, variant: target.defaultVariant, readPath: path, source: .inferred,
                                      note: "Drawn as the \(target.displayName) this preset is made for; the connected \(here) lights it. Pick it under Controllers to draw it as itself.")
            }
            guard let layout = matched ?? (path == .gameController ? ControllerLayoutCatalog.layout(.genericGamepad) : chosenLayout)
            else { return nil }
            var note: String? = matched == nil ? "Model not recognized; showing a standard gamepad." : nil
            if matched == nil, path != .gameController, let chosenLayout {
                note = "Model not recognized; showing the \(chosenLayout.displayName), the controller this group is set to."
            }
            let facts = Facts(service: service, slot: slot)
            let variant = (chosenID?.base == layout.id ? chosenID?.variant : nil)
                ?? connectedVariant(layout, vendor: facts.vendor, product: facts.product)
            return ResolvedLayout(layout: layout, variant: layout.known(variant) ?? layout.defaultVariant, readPath: path,
                                  source: .connected, note: note)
        }
        if let chosen = chosenID, let layout = ControllerLayoutCatalog.layout(chosen) {
            return ResolvedLayout(layout: layout, variant: layout.known(chosen.variant) ?? layout.defaultVariant, source: .groupChoice,
                                  note: "Not connected. Showing the \(layout.displayName), the controller this group is set to.")
        }
        if let group, let id = infer(group: group, preset: preset), let layout = ControllerLayoutCatalog.layout(id) {
            return ResolvedLayout(layout: layout, variant: layout.defaultVariant, source: .inferred,
                                  note: "Not connected. Showing the \(layout.displayName), from this preset's rows.")
        }
        return nil
    }

    // MARK: - Connected

    /// How the pad in a slot is read.
    static func readPath(service: GameControllerService, slot: Int) -> ReadPath {
        if slot == service.steamControllerSlot { return .steamHelper }
        if let pad = service.rawHIDGamepadSlots[slot] {
            if case .generic? = pad.profile?.layout {
                return (pad.profile?.identifier.hasPrefix("sdl-") ?? false) ? .rawSDL : .rawDescriptor
            }
            return .rawProfile
        }
        return .gameController
    }

    /// `match`, remembered per slot and device, for callers that ask often
    /// (the editor's naming on every redraw).
    private static var matchCache: [String: ControllerModelID?] = [:]
    static func cachedMatch(service: GameControllerService, slot: Int) -> ControllerLayout? {
        // The pad itself, not only its name: an Xbox One and a Series pad
        // share one name.
        let pad = slot < service.connectedControllers.count ? ObjectIdentifier(service.connectedControllers[slot]).hashValue : 0
        let key = "\(slot)|\(service.controllerDetails[slot]?.name ?? "")|\(service.rawHIDGamepadSlots[slot]?.id ?? 0)|\(slot == service.steamControllerSlot)|\(pad)"
        if let hit = matchCache[key] { return hit.flatMap(ControllerLayoutCatalog.layout) }
        let found = match(service: service, slot: slot)
        if matchCache.count > 64 { matchCache.removeAll() }
        matchCache[key] = found?.id
        return found
    }

    /// The catalog model a connected pad is, by its match rules, highest
    /// priority first.
    static func match(service: GameControllerService, slot: Int) -> ControllerLayout? {
        match(facts: Facts(service: service, slot: slot))
    }

    /// The variant a connected device is drawn as by its USB IDs: its
    /// product's, else its vendor's; nil leaves the default.
    nonisolated static func connectedVariant(_ layout: ControllerLayout, vendor: Int?, product: Int?) -> String? {
        let byProduct = vendor.flatMap { v in product.flatMap { layout.productVariants[v << 16 | $0] } }
        return byProduct ?? vendor.flatMap { layout.vendorVariants[$0] }
    }

    /// The catalog model a device with these facts is. DeviceIdentityTests
    /// feeds it the identities real devices present.
    /// Hidden experimental drawings are skipped, so such a device gets the
    /// generic drawing (its reading is unchanged).
    nonisolated static func match(facts: Facts) -> ControllerLayout? {
        matchIncludingHidden(facts: facts).flatMap { ControllerLayoutCatalog.isShown($0) ? $0 : nil }
    }

    /// The catalog model a device is, shown or not: for marking a device
    /// read by an experimental path.
    nonisolated static func matchIncludingHidden(facts: Facts) -> ControllerLayout? {
        ControllerLayoutCatalog.all
            .filter { !$0.match.isEmpty }
            .sorted { $0.matchPriority > $1.matchPriority }
            .first { layout in layout.match.contains { rules in rules.allSatisfy { facts.holds($0) } } }
    }

    /// Whether the device in a slot is read by a path not yet tested on
    /// hardware (its model is experimental).
    static func readsExperimentally(service: GameControllerService, slot: Int) -> Bool {
        matchIncludingHidden(facts: Facts(service: service, slot: slot))?.experimental == true
    }

    /// What is known about a slot's device, for the match rules.
    struct Facts {
        var brand: ControllerBrand?
        var profileIdentifier: String?
        var profileLayout: String?
        var vendor: Int?
        var product: Int?
        var productCategory = ""
        var vendorName = ""
        var elements: Set<String> = []
        var isSteamHelper = false
        /// Read through GameController (or the Quick Tour's stand-in for
        /// such a pad), the only path that lists elements: on any other
        /// path an empty list says nothing about what the pad lacks.
        var isGameController = false

        /// A device described directly (the tests' real identities).
        init(brand: ControllerBrand? = nil, profileIdentifier: String? = nil, profileLayout: String? = nil,
             vendor: Int? = nil, product: Int? = nil, productCategory: String = "", vendorName: String = "",
             elements: Set<String> = [], isSteamHelper: Bool = false, isGameController: Bool = false) {
            self.brand = brand; self.profileIdentifier = profileIdentifier; self.profileLayout = profileLayout
            self.vendor = vendor; self.product = product; self.productCategory = productCategory
            self.vendorName = vendorName; self.elements = elements; self.isSteamHelper = isSteamHelper
            self.isGameController = isGameController
        }

        @MainActor init(service: GameControllerService, slot: Int) {
            brand = service.controllerDetails[slot]?.brand
            isSteamHelper = slot == service.steamControllerSlot
            if let pad = service.rawHIDGamepadSlots[slot] {
                profileIdentifier = pad.profile?.identifier
                profileLayout = pad.profile.map { Self.layoutName($0.layout) }
                vendor = Int(pad.vendorID)
                product = Int(pad.productID)
                vendorName = pad.manufacturer ?? ""
                productCategory = pad.productName
            } else if slot < service.connectedControllers.count {
                let c = service.connectedControllers[slot]
                productCategory = c.productCategory
                vendorName = c.vendorName ?? ""
                elements = Set(c.physicalInputProfile.buttons.keys)
                isGameController = true
                // The pad's own brand: the slot's info can be the Quick
                // Tour's stand-in while this pad is still in the slot.
                brand = ControllerTypeDetector.detect(c)
            } else if !isSteamHelper, let info = service.controllerDetails[slot] {
                // A stand-in with no pad behind it (the Quick Tour's
                // DualSense Edge): its own description.
                productCategory = info.productCategory
                vendorName = info.name
                elements = Set(info.physicalButtonNames)
                isGameController = true
            }
        }

        static func layoutName(_ layout: ControllerProfile.ReportLayout) -> String {
            switch layout {
            case .xinput: return "xinput"
            case .dualShock3: return "dualShock3"
            case .switch2Pro: return "switch2Pro"
            case .switch2GameCube: return "switch2GameCube"
            case .steamController2026: return "steamController2026"
            case .streamDeck: return "streamDeck"
            case .generic: return "generic"
            }
        }

        func holds(_ rule: MatchRule) -> Bool {
            switch rule {
            case .rawProfileIdentifier(let prefix): return profileIdentifier?.hasPrefix(prefix) == true
            case .rawProfileLayout(let name): return profileLayout == name
            case .vidPid(let v, let products): return vendor == v && product.map(products.contains) == true
            case .vendor(let v): return vendor == v
            case .gcProductCategoryContains(let s): return productCategory.localizedCaseInsensitiveContains(s)
            case .gcVendorNameContains(let s): return vendorName.localizedCaseInsensitiveContains(s)
            case .gcHasElement(let e): return elements.contains(e)
            case .gcLacksElement(let e): return isGameController && !elements.contains(e)
            case .brand(let b): return brand == b
            case .steamHelper: return isSteamHelper
            }
        }
    }

    // MARK: - Inferred

    /// A model from a group's rows and the preset's Buttons family, for a
    /// group with nothing connected and no model chosen.
    /// The controller a preset is made for, when it names one: its Buttons
    /// family (FPS (Xbox) is Xbox) or a built-in made for one model.
    static func target(group: JoystickMapping, preset: Preset) -> ControllerModelID? {
        if let model = ExamplePresets.drawnModels[preset.name] { return model }
        switch preset.buttonFamily {
        case .xbox?, .playstation?, .nintendo?: return infer(group: group, preset: preset)
        default: return nil
        }
    }

    /// Two layouts of one kind: the same family, or for a model of no family
    /// (an 8BitDo pad) the same maker.
    private static func sameKind(_ a: ControllerLayout?, _ b: ControllerLayout) -> Bool {
        guard let a else { return false }
        if let family = b.family { return a.family == family }
        return a.maker == b.maker
    }

    static func infer(group: JoystickMapping, preset: Preset) -> ControllerModelID? {
        if let model = ExamplePresets.drawnModels[preset.name] { return model }
        let buttons = Set(group.bindings.filter { $0.input.type == .button }.map(\.input.index))
        let usesTouchpad = group.bindings.contains { [.touchpad, .touchpadRegion, .touchpadGesture].contains($0.input.type) }
        switch preset.buttonFamily {
        case .playstation?:
            return !buttons.isDisjoint(with: [16, 17, 20, 21]) ? .dualSenseEdge : .dualSense
        case .xbox?:
            return !buttons.isDisjoint(with: [16, 17, 18, 19]) ? .xboxElite2 : .xboxSeries
        case .nintendo?:
            return !buttons.isDisjoint(with: [15, 16, 17]) ? .switch2Pro : .switchPro
        case .gameCube?: return .gameCubeSwitch2
        case .stadia?: return .stadia
        case .steamController?: return .steamController2015
        case .steamController2026?: return .steamController2026
        case .automatic?, .positions?, nil:
            return usesTouchpad ? .dualSense : nil
        }
    }
}
