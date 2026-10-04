import Foundation
import GameController

/// Lays out the controls a controller actually has as rows under section
/// headings ("Left stick", "Buttons", "D-pad"...), each row waiting for an
/// output. Nothing is guessed on the output side: the point is to have every
/// control of the device in front of you, organized, ready to bind.
///
/// What counts as "actually has" comes from what the controller reports to
/// macOS (`ControllerInfo`: its button element names, whether it has a
/// touchpad or motion sensors), with one correction: the PlayStation Access
/// Controller reports itself as a full gamepad, but physically it is one
/// stick and eight button sockets around the PS and Options buttons, so it
/// gets that layout plus the inputs its profiles can assign.
enum ControllerScaffold {

    /// One control: its input, the heading it sits under, and a plain name
    /// for the row's note.
    struct Control: Equatable {
        let input: String
        let section: String
        let name: String
    }

    enum SectionName {
        static let leftStick = "Left stick"
        static let rightStick = "Right stick"
        static let stick = "Stick"
        static let triggers = "Triggers"
        static let buttons = "Buttons"
        static let menuButtons = "Menu buttons"
        static let extras = "Paddles and extras"
        static let dpad = "D-pad"
        static let touchpad = "Touchpad"
        static let motion = "Motion"
    }

    // MARK: - Building blocks

    private static func stick(_ section: String, axes: (x: Int, y: Int), label: String) -> [Control] {
        [
            Control(input: "axi \(axes.x) -", section: section, name: "\(label) left"),
            Control(input: "axi \(axes.x) +", section: section, name: "\(label) right"),
            Control(input: "axi \(axes.y) -", section: section, name: "\(label) up"),
            Control(input: "axi \(axes.y) +", section: section, name: "\(label) down"),
        ]
    }

    /// The two analog trigger rows, named the way the family prints them.
    private static func triggers(_ family: FaceLetters?) -> [Control] {
        let left = family.flatMap { ButtonNames.short(6, family: $0) } ?? "LT / L2"
        let right = family.flatMap { ButtonNames.short(7, family: $0) } ?? "RT / R2"
        return [
            Control(input: "axi 4 +", section: SectionName.triggers, name: "Left trigger (\(left)), analog pull"),
            Control(input: "axi 5 +", section: SectionName.triggers, name: "Right trigger (\(right)), analog pull"),
        ]
    }

    private static let dpad: [Control] = [
        Control(input: "hat 0 U", section: SectionName.dpad, name: "D-pad up"),
        Control(input: "hat 0 D", section: SectionName.dpad, name: "D-pad down"),
        Control(input: "hat 0 L", section: SectionName.dpad, name: "D-pad left"),
        Control(input: "hat 0 R", section: SectionName.dpad, name: "D-pad right"),
    ]

    private static let touchpad: [Control] = [
        Control(input: "tpd 0 x -", section: SectionName.touchpad, name: "Touchpad finger left"),
        Control(input: "tpd 0 x +", section: SectionName.touchpad, name: "Touchpad finger right"),
        Control(input: "tpd 0 y -", section: SectionName.touchpad, name: "Touchpad finger up"),
        Control(input: "tpd 0 y +", section: SectionName.touchpad, name: "Touchpad finger down"),
        Control(input: "btn 13", section: SectionName.touchpad, name: "Touchpad press"),
        Control(input: "tpg oneFingerTap", section: SectionName.touchpad, name: "Touchpad tap (one finger)"),
        Control(input: "tpg twoFingerTap", section: SectionName.touchpad, name: "Two-finger tap"),
        Control(input: "tpg doubleTap", section: SectionName.touchpad, name: "Touchpad double tap"),
    ]

    private static let motion: [Control] = [
        Control(input: "mtn gyroY -", section: SectionName.motion, name: "Tilt left"),
        Control(input: "mtn gyroY +", section: SectionName.motion, name: "Tilt right"),
        Control(input: "mtn gyroX +", section: SectionName.motion, name: "Tilt up (nose up)"),
        Control(input: "mtn gyroX -", section: SectionName.motion, name: "Tilt down (nose down)"),
    ]

    /// Standard button indices and the heading each goes under; the names
    /// come from ButtonNames. Digital trigger presses (6, 7) are left out
    /// when the analog triggers are present, since those cover the same
    /// pull. 16 to 19 are the Xbox Elite's paddles (P1 and P2 on the
    /// right) and the DualSense Edge's back buttons (16 left, 17 right).
    private static let standardButtons: [(index: Int, section: String)] = [
        (0, SectionName.buttons), (1, SectionName.buttons), (2, SectionName.buttons), (3, SectionName.buttons),
        (4, SectionName.buttons), (5, SectionName.buttons), (6, SectionName.buttons), (7, SectionName.buttons),
        (11, SectionName.buttons), (12, SectionName.buttons),
        (8, SectionName.menuButtons), (9, SectionName.menuButtons), (10, SectionName.menuButtons),
        (14, SectionName.menuButtons), (15, SectionName.menuButtons),
        (16, SectionName.extras), (17, SectionName.extras), (18, SectionName.extras), (19, SectionName.extras),
        (20, SectionName.extras), (21, SectionName.extras),
    ]

    /// The heading a button goes under on a family's numbering: the Steam
    /// Controllers number theirs their own way (the 2015 model's 8 to 11 are
    /// the left trackpad's edges, the 2026 model's 14 to 17 its back
    /// buttons), so the standard table would file them wrongly.
    private static func buttonSection(_ index: Int, family: FaceLetters?) -> String {
        if family == .steamController {
            switch SteamControllerButton(rawValue: index) {
            case .rightTrigger?, .leftTrigger?: return SectionName.triggers
            case .rightBumper?, .leftBumper?: return "Bumpers"
            case .y?, .b?, .x?, .a?, .stickClick?: return SectionName.buttons
            case .dpadUp?, .dpadRight?, .dpadLeft?, .dpadDown?, .leftPadClick?, .leftPadTouch?: return "Left trackpad"
            case .rightPadClick?, .rightPadTouch?: return "Right trackpad"
            case .back?, .steam?, .forward?: return SectionName.menuButtons
            case .leftGrip?, .rightGrip?: return "Grips"
            default: return SectionName.extras
            }
        }
        if family == .gameCube {
            switch index {
            case 9, 10, 14: return SectionName.menuButtons
            default: return SectionName.buttons   // A to Y, L, Z, the clicks, C, ZL
            }
        }
        if family == .steamController2026 {
            switch index {
            case 0...7, 11, 12: return SectionName.buttons
            case 8, 9, 10, 13: return SectionName.menuButtons
            case 14...17: return "Back buttons"
            case 18, 20: return "Left trackpad"
            case 19, 21: return "Right trackpad"
            case 22...25: return "Touch sensors"
            default: return SectionName.extras
            }
        }
        return standardButtons.first(where: { $0.index == index })?.section ?? SectionName.extras
    }

    /// The heading an axis goes under on a family's numbering.
    private static func axisSection(_ index: Int, family: FaceLetters?) -> String {
        switch (family, index) {
        case (.steamController?, 0), (.steamController?, 1): return SectionName.stick
        case (.steamController?, 2), (.steamController?, 3): return "Right trackpad"
        case (.steamController?, 6), (.steamController?, 7): return "Left trackpad"
        case (.steamController2026?, 6), (.steamController2026?, 7), (.steamController2026?, 10): return "Left trackpad"
        case (.steamController2026?, 8), (.steamController2026?, 9), (.steamController2026?, 11): return "Right trackpad"
        case (_, 0), (_, 1): return SectionName.leftStick
        case (_, 2), (_, 3): return SectionName.rightStick
        case (_, 4), (_, 5): return SectionName.triggers
        default: return "Axes"
        }
    }

    private static func button(_ index: Int) -> Control {
        Control(input: "btn \(index)", section: buttonSection(index, family: nil), name: standardName(index))
    }

    // MARK: - What the device presents

    /// The controls a slot's device actually reports, gathered from the
    /// service that drives it: the GameController framework's element list
    /// and motion object, a raw HID gamepad's decoded layout, the Steam
    /// Controller's own report, or the Mac's mouse. Nothing here is assumed
    /// from a name; a gyro is offered only when the device publishes one.
    struct DeviceCapabilities {
        var deviceName: String
        /// The family the rows are named and filed in (see ButtonNames).
        var family: FaceLetters? = nil
        /// Where the model differs from its family (a DualShock 4's Share).
        var model: ButtonNames.ModelNames = .none
        var sticks: [(section: String, x: Int, y: Int, label: String)] = []
        var triggers = false
        var dpad = false
        var buttons: [(index: Int, name: String)] = []
        var touchpad = false
        /// The button the touchpad's press reads: 13 on PlayStation pads,
        /// the right trackpad click on the 2026 Steam Controller (13 there is
        /// Quick Access).
        var touchpadPressIndex = 13
        /// Trackpads read as touch surfaces besides (or instead of) the
        /// PlayStation touchpad: both pads on either Steam Controller.
        var trackpads: [(surface: Int, name: String, press: Int?)] = []
        var gyro = false
        var mouse = false
        var macTaps = false
        /// Analog inputs past the standard six: an extra trigger or a
        /// pedal plugged into an adaptive controller.
        var extraAxes: [(index: Int, name: String)] = []
        /// A steering wheel on axi 0, and its pedals (gas, brake, clutch on
        /// LogitechWheel's plan), read like triggers.
        var steering = false
        var pedals: [(index: Int, name: String)] = []
        /// Why the list is empty or partial, for the prompt.
        var note: String? = nil
        /// "a" / "an" before the device name, or nothing when the name
        /// already reads as a phrase ("the mouse", "a standard controller").
        var deviceArticle: String {
            let lower = deviceName.lowercased()
            if lower.hasPrefix("a ") || lower.hasPrefix("an ") || lower.hasPrefix("the ") { return "" }
            return "aeiou".contains(lower.first ?? "x") ? "an" : "a"
        }

        var isEmpty: Bool {
            sticks.isEmpty && !triggers && !dpad && buttons.isEmpty && !touchpad && !gyro && !mouse && !macTaps
                && !steering && pedals.isEmpty
        }

        /// A one-line inventory for the prompt: "stick, 8 buttons, PS and
        /// Options".
        var summary: String {
            var parts: [String] = []
            if steering { parts.append("wheel") }
            if !pedals.isEmpty { parts.append(pedals.count == 1 ? "1 pedal" : "\(pedals.count) pedals") }
            parts += sticks.map { $0.label.lowercased() }
            if triggers { parts.append("triggers") }
            if dpad { parts.append("D-pad") }
            if !buttons.isEmpty { parts.append(buttons.count == 1 ? "1 button" : "\(buttons.count) buttons") }
            if touchpad { parts.append("touchpad") }
            if gyro { parts.append("gyro") }
            if mouse { parts.append("mouse buttons, movement, and scroll") }
            if !extraAxes.isEmpty {
                parts.append(extraAxes.count == 1 ? "1 extra analog input"
                             : "\(extraAxes.count) extra analog inputs")
            }
            if macTaps { parts.append("taps on the Mac") }
            return parts.joined(separator: ", ")
        }
    }

    /// Why the capabilities are being read. `layout` is the editor's
    /// automatic layout: it takes the shape of the device as a person holds
    /// it, so the PlayStation Access Controller comes out as one stick and
    /// eight sockets. `mirror` is the Live Visualizer: it shows everything
    /// the device reports, because any of it can arrive (an Access
    /// Controller's sockets can be assigned to the D-pad or the triggers,
    /// and a second stick can be plugged into its expansion port), and a
    /// control that fires but is not drawn looks like the app is broken.
    enum Purpose { case layout, mirror }

    /// Reads a slot's device through the services. `presetFamily` is the
    /// preset's Buttons choice: it names the rows unless the connected pad
    /// numbers its buttons differently, and it shapes an empty slot.
    @MainActor
    static func capabilities(service: GameControllerService, slot: Int,
                             inputKind: SlotInputKind,
                             purpose: Purpose = .layout,
                             presetFamily: FaceLetters? = nil) -> DeviceCapabilities {
        let macTaps = ChassisTapService.shared.isAvailable

        switch inputKind {
        case .mouse:
            var caps = DeviceCapabilities(deviceName: "the mouse")
            caps.mouse = true
            caps.macTaps = macTaps
            return caps
        case .screen:
            // A display has no buttons to lay out; its regions are drawn
            // from a Screen region row's Options.
            var caps = DeviceCapabilities(deviceName: "the screen")
            caps.macTaps = macTaps
            caps.note = "Screen regions are areas of a display. Add a Screen region row and draw its regions from the row's Options."
            return caps
        case .keyboard:
            var caps = DeviceCapabilities(deviceName: "the keyboard")
            caps.macTaps = macTaps
            caps.note = "Keys are added by pressing them: add a row and click Scan."
            return caps
        case .midi:
            return DeviceCapabilities(deviceName: "MIDI",
                                      note: "MIDI notes and knobs are added by playing them: add a row and click Scan.")
        case .touchpad, .controller, .auto:
            break
        }

        // Steam Controller: its own report, decoded by SteamControllerService.
        if service.steamControllerSlot == slot {
            return steam2015Capabilities()   // no gyro reaches the engine from this driver
        }

        let connected = service.rawHIDGamepadSlots[slot] != nil || service.controllerDetails[slot] != nil
            || slot < service.connectedControllers.count
        let fam = ButtonNames.resolve(preset: presetFamily, device: service.namingFamily(forSlot: slot),
                                      connected: connected)
        let model = fam == service.namingFamily(forSlot: slot) ? service.modelNames(forSlot: slot) : .none

        // Raw HID gamepad: exactly what its decoder produces.
        if let gamepad = service.rawHIDGamepadSlots[slot] {
            var caps = DeviceCapabilities(deviceName: gamepad.displayName, family: fam, model: model)
            let names = gamepad.profile?.physicalButtonNames ?? []
            switch gamepad.profile?.layout {
            case .xinput:
                caps.sticks = twoSticks
                caps.triggers = true
                caps.dpad = true
                caps.buttons = [0, 1, 2, 3, 4, 5, 8, 9, 10, 11, 12].map { ($0, standardName($0, fam)) }
            case .dualShock3:
                caps.sticks = twoSticks
                caps.triggers = true
                caps.dpad = true
                caps.buttons = (0...12).map { ($0, standardName($0, fam, model)) }
            case .streamDeck(let format):
                let first = ControllerProfile.StreamDeckFormat.firstSlot
                caps.buttons = (first..<first + format.keys).map { ($0, $0 < names.count ? names[$0] : "Key \($0 - first + 1)") }
            case .switch2GameCube:
                // Main stick, C-stick, L and R, the D-pad, and the buttons
                // the decoder fills.
                caps.sticks = [(SectionName.leftStick, 0, 1, "Control stick"),
                               (SectionName.rightStick, 2, 3, "C-stick")]
                caps.triggers = true
                caps.dpad = true
                caps.buttons = [0, 1, 2, 3, 5, 9, 10, 14, 15, 16].map { ($0, standardName($0, fam)) }
            case .steamController2026:
                caps = steam2026Capabilities(deviceName: gamepad.displayName)
            case .switch2Pro:
                caps.sticks = twoSticks
                caps.triggers = true
                caps.dpad = true
                caps.buttons = (0...12).map { ($0, standardName($0, fam)) }
                    + [14, 15, 16, 17].map { ($0, $0 < names.count ? names[$0] : "Button \($0)") }
            case .generic(let layout):
                let axisCount = layout.axisByteOffsets.count
                let reportedAxes = Set((layout.extended?.reports ?? []).flatMap(\.axes).map(\.index))
                if gamepad.profile?.identifier.hasPrefix("logitech-wheel-") == true {
                    // A wheel: steering and pedals, not a stick (axi 1 is the clutch).
                    caps.steering = reportedAxes.contains(0)
                    caps.pedals = [(5, "Gas"), (4, "Brake"), (1, "Clutch")].filter { reportedAxes.contains($0.0) }
                } else if fam == .gameCube {
                    caps.sticks = gameCubeSticks
                } else {
                    if axisCount >= 2 { caps.sticks.append((SectionName.leftStick, 0, 1, "Left stick")) }
                    if axisCount >= 4 { caps.sticks.append((SectionName.rightStick, 2, 3, "Right stick")) }
                }
                // A wheel's pedals sit on the trigger axes; listed once, as pedals.
                caps.triggers = !layout.triggerByteOffsets.isEmpty && caps.pedals.isEmpty
                let reports = layout.extended?.reports ?? []
                caps.dpad = layout.hatBitOffset != nil || layout.hatByteOffset != nil
                    || reports.contains { !$0.dpadButtons.isEmpty }
                // A GameControllerDB layout puts buttons on their standard
                // slots, which need not run 0, 1, 2 in a row.
                var indices = reports.isEmpty
                    ? Array(0..<layout.buttonBitOffsets.count)
                    : Array(Set(reports.flatMap(\.buttons).map(\.index))).sorted()
                // A GameCube pad's L reads at 4 and 6 and its clicks repeat
                // the analog triggers; offered as the Switch 2 model's are.
                if fam == .gameCube { indices.removeAll { $0 == 4 || (caps.triggers && ($0 == 6 || $0 == 7)) } }
                // A GameControllerDB row and the GameCube adapter put the
                // buttons on known slots, so they take the family's names;
                // a pad read from its descriptor alone keeps its own.
                let known = (gamepad.profile?.identifier.hasPrefix("sdl-") ?? false) || fam == .gameCube
                caps.buttons = indices.map { i in
                    if known, fam == .gameCube || i <= 21 { return (i, standardName(i, fam, model)) }
                    return (i, i < names.count ? names[i] : "Button \(i)")
                }
            case nil:
                break
            }
            return caps
        }

        // GameController framework: the element list is the inventory.
        if slot < service.connectedControllers.count {
            let controller = service.connectedControllers[slot]
            let info = service.controllerDetails[slot]
            let name = info?.name ?? controller.vendorName ?? "Controller"
            var caps = DeviceCapabilities(deviceName: name, family: fam, model: model)
            // A gyro only when the controller publishes rotation rate,
            // which is what the motion inputs read.
            caps.gyro = controller.motion?.hasRotationRate ?? false
            caps.touchpad = info?.hasTouchpad ?? false

            // PlayStation Access Controller: one stick, eight button
            // sockets, PS and Options in the middle. macOS reports a full
            // gamepad because the sockets can be assigned to any input.
            if purpose == .layout,
               controller.productCategory.localizedCaseInsensitiveContains("access")
                || name.localizedCaseInsensitiveContains("access controller") {
                applyAccessControllerLayout(&caps, family: fam ?? .playstation)
                return caps
            }

            let elements = Set(controller.physicalInputProfile.buttons.keys)

            // Xbox Adaptive Controller: the unit itself has two large
            // buttons, a D-pad, View, Menu and Xbox, but its 3.5 mm jacks
            // and USB ports stand in for X, Y, the bumpers, the triggers,
            // both sticks and the stick clicks, so all of those get rows.
            // Anything past that arrives through the accessory watch as an
            // extra button or axis and is offered then. The mirror purpose
            // keeps the full shape so the visualizer draws what is reported.
            if purpose == .layout,
               (controller.productCategory + " " + name).localizedCaseInsensitiveContains("adaptive") {
                caps.sticks = twoSticks
                caps.triggers = true
                caps.dpad = true
                caps.buttons = [0, 1, 2, 3, 4, 5, 11, 12, 8, 9, 10].map { ($0, standardName($0, fam, model)) }
                var extraNames: [Int: String] = [:]
                for extra in service.extraButtonsSnapshot(for: slot) where extra.index > 12 && extra.index != 13 {
                    extraNames[extra.index] = extra.label
                }
                caps.buttons += extraNames.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
                caps.extraAxes = service.extraAxesSnapshot(for: slot).map { ($0.index, $0.label) }
                return caps
            }

            if elements.contains("Left Thumbstick Up") {
                caps.sticks.append((SectionName.leftStick, 0, 1, "Left stick"))
            }
            if elements.contains("Right Thumbstick Up") {
                caps.sticks.append((SectionName.rightStick, 2, 3, "Right stick"))
            }
            caps.triggers = elements.contains("Left Trigger") || elements.contains("Right Trigger")
            caps.dpad = elements.contains("Direction Pad Up")
            // Index -> name. A standard index keeps its cross-platform name;
            // anything past the block keeps the name the device gave it (a
            // paddle, P1 on an 8BitDo, a socket on an adaptive pad).
            var namesByIndex: [Int: String] = [:]
            for element in elements.sorted() {
                guard let index = GameControllerService.publicKnownButtonMap[element] else { continue }
                if caps.triggers && (index == 6 || index == 7) { continue }
                if index == 13 { continue }   // touchpad press goes with the touchpad
                if namesByIndex[index] == nil {
                    namesByIndex[index] = standardButtons.contains(where: { $0.index == index }) ? standardName(index, fam, model) : element
                }
            }
            // Extras past the standard block keep the name the device gave
            // them: an unknown button cached at 20 is not an Edge Fn button.
            for extra in service.extraButtonsSnapshot(for: slot) where namesByIndex[extra.index] == nil && extra.index != 13 {
                namesByIndex[extra.index] = extra.index <= 12 ? standardName(extra.index, fam, model) : extra.label
            }
            // An Xbox Elite names its paddles by where they sit.
            if controller.extendedGamepad is GCXboxGamepad {
                for index in 16...19 where namesByIndex[index] != nil {
                    namesByIndex[index] = ButtonNames.xbox[index]
                }
            }
            caps.buttons = namesByIndex.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
            caps.extraAxes = service.extraAxesSnapshot(for: slot).map { ($0.index, $0.label) }
            return caps
        }

        // No GameController object but the slot still has a device on
        // record (a marketing capture, a pad whose details came from
        // elsewhere): build from what those details say it has.
        if let info = service.controllerDetails[slot] {
            var caps = DeviceCapabilities(deviceName: info.name, family: fam, model: model)
            caps.gyro = info.supportsMotion
            caps.touchpad = info.hasTouchpad
            if purpose == .layout, info.name.localizedCaseInsensitiveContains("access controller") {
                applyAccessControllerLayout(&caps, family: fam ?? .playstation)
                return caps
            }
            // The real stick and trigger counts when the device gave them:
            // axisCount is the top index, so one stick plus two triggers
            // reads 6 there and would wrongly offer a right stick.
            let stickAxes = info.stickAxisCount ?? info.axisCount
            if stickAxes >= 2 { caps.sticks.append((SectionName.leftStick, 0, 1, "Left stick")) }
            if stickAxes >= 4 { caps.sticks.append((SectionName.rightStick, 2, 3, "Right stick")) }
            caps.triggers = info.triggerCount.map { $0 > 0 } ?? (info.axisCount >= 6)
            caps.dpad = true
            // Positions first, because a device on this path reports its
            // buttons by index; then any named extra the map knows (a
            // paddle, an FN button) that sits past the standard block.
            // Only the standard block is implied by a count; anything past
            // it (a paddle, an FN button) has to be named by the device.
            var namesByIndex: [Int: String] = [:]
            for index in 0..<min(max(info.buttonCount, 4), 13) { namesByIndex[index] = standardName(index, fam, model) }
            for name in info.physicalButtonNames {
                if let index = GameControllerService.publicKnownButtonMap[name], namesByIndex[index] == nil {
                    namesByIndex[index] = standardButtons.contains(where: { $0.index == index }) ? standardName(index, fam, model) : name
                }
            }
            if caps.triggers { namesByIndex[6] = nil; namesByIndex[7] = nil }
            namesByIndex[13] = nil   // touchpad press has its own widget
            for extra in service.extraButtonsSnapshot(for: slot) where namesByIndex[extra.index] == nil && extra.index != 13 {
                namesByIndex[extra.index] = extra.index <= 12 ? standardName(extra.index, fam, model) : extra.label
            }
            caps.buttons = namesByIndex.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
            return caps
        }

        // Nothing in the slot: a standard gamepad, and say so. The
        // visualizer lands here when no device is connected, which is what
        // keeps a preset page from showing an empty panel.
        // A preset made for a pad with its own numbering is drawn as that
        // pad, since its rows are on that numbering.
        let empty = "No controller is connected to this slot; this is the layout the preset was made for."
        switch fam {
        case .steamController?:
            var caps = steam2015Capabilities()
            caps.note = empty
            return caps
        case .steamController2026?:
            var caps = steam2026Capabilities(deviceName: "Steam Controller (2026)")
            caps.note = empty
            return caps
        case .gameCube?:
            var caps = DeviceCapabilities(deviceName: "a GameCube controller", family: fam)
            caps.sticks = gameCubeSticks
            caps.triggers = true
            caps.dpad = true
            caps.buttons = [0, 1, 2, 3, 5, 9].map { ($0, standardName($0, fam)) }
            caps.note = empty
            return caps
        default:
            break
        }
        var caps = DeviceCapabilities(deviceName: "a standard controller", family: fam)
        caps.sticks = twoSticks
        caps.triggers = true
        caps.dpad = true
        caps.buttons = [0, 1, 2, 3, 4, 5, 11, 12, 8, 9, 10].map { ($0, standardName($0, fam)) }
        caps.note = "No controller is connected to this slot; this is a standard layout."
        return caps
    }

    /// The original Steam Controller on its own numbering.
    private static func steam2015Capabilities() -> DeviceCapabilities {
        var caps = DeviceCapabilities(deviceName: "Steam Controller", family: .steamController)
        caps.sticks = [(SectionName.stick, 0, 1, "Stick")]
        // The round pads are touch surfaces (finger movement, taps), not
        // sticks: their rows read the finger's motion, like a trackpad.
        caps.trackpads = [(0, "Right trackpad", SteamControllerButton.rightPadClick.rawValue),
                          (1, "Left trackpad", SteamControllerButton.leftPadClick.rawValue)]
        caps.triggers = true
        caps.dpad = true
        caps.buttons = ButtonNames.labels(for: .steamController).map { ($0.index, $0.label) }
        return caps
    }

    /// The 2026 Steam Controller on its decoder's numbering.
    private static func steam2026Capabilities(deviceName: String) -> DeviceCapabilities {
        var caps = DeviceCapabilities(deviceName: deviceName, family: .steamController2026)
        caps.sticks = twoSticks
        caps.triggers = true
        caps.dpad = true
        caps.gyro = true
        // The square pads are touch surfaces (finger movement, taps, press).
        caps.trackpads = [(0, "Right trackpad", 19), (1, "Left trackpad", 18)]
        caps.buttons = ButtonNames.labels(for: .steamController2026).map { ($0.index, $0.label) }
        caps.extraAxes = [10, 11].map { ($0, ButtonNames.axisName($0, family: .steamController2026) ?? "Axis \($0)") }
        return caps
    }

    private static let gameCubeSticks: [(section: String, x: Int, y: Int, label: String)] = [
        (SectionName.leftStick, 0, 1, "Control stick"),
        (SectionName.rightStick, 2, 3, "C-stick"),
    ]

    /// PlayStation Access Controller: one stick and eight button sockets
    /// around PS and Options. Its on-device profiles can assign a socket to
    /// a trigger or a stick click, and a stick in the expansion port can act
    /// as the right stick, so those get rows too. The two center buttons
    /// report as Options (8), Menu (9), or Home (10) depending on the
    /// profile; all three are offered so whichever one it sends has a row.
    private static func applyAccessControllerLayout(_ caps: inout DeviceCapabilities, family: FaceLetters?) {
        caps.sticks = [(SectionName.stick, 0, 1, "Stick"),
                       (SectionName.rightStick, 2, 3, "Right stick")]
        caps.triggers = true
        caps.family = family
        caps.buttons = [0, 1, 2, 3, 4, 5, 11, 12, 8, 9, 10].map { ($0, standardName($0, family)) }
    }

    private static let twoSticks: [(section: String, x: Int, y: Int, label: String)] = [
        (SectionName.leftStick, 0, 1, "Left stick"),
        (SectionName.rightStick, 2, 3, "Right stick"),
    ]

    /// A button's name: the family's own (L1 on a PlayStation pad, ZL on a
    /// Switch pad) when the family is known, else both common names, with
    /// the Face button names setting applied (see ButtonNames.label).
    private static func standardName(_ index: Int, _ family: FaceLetters? = nil,
                                     _ model: ButtonNames.ModelNames = .none) -> String {
        ButtonNames.label(index, family: family, model: model)
    }

    // MARK: - Per-device layout

    /// Rows for everything the device presents, under a heading per part.
    static func controls(for caps: DeviceCapabilities) -> [Control] {
        var out: [Control] = []
        if caps.steering {
            out += [
                Control(input: "axi 0 -", section: "Wheel", name: "Steer left"),
                Control(input: "axi 0 +", section: "Wheel", name: "Steer right"),
            ]
        }
        for p in caps.pedals {
            out.append(Control(input: "axi \(p.index) +", section: "Pedals", name: "\(p.name) pressed"))
        }
        for s in caps.sticks { out += stick(s.section, axes: (s.x, s.y), label: s.label) }
        if caps.triggers { out += triggers(caps.family) }
        // The 2015 Steam Controller's D-pad is the left trackpad's edges,
        // which its buttons 8 to 11 already list.
        if caps.dpad, caps.family != .steamController { out += dpad }
        for b in caps.buttons {
            out.append(Control(input: "btn \(b.index)", section: buttonSection(b.index, family: caps.family), name: b.name))
        }
        for axis in caps.extraAxes {
            // A trackpad's pressure only rises, so it has no pulled-back row.
            if caps.family == .steamController2026 {
                out.append(Control(input: "axi \(axis.index) +", section: axisSection(axis.index, family: caps.family),
                                   name: "\(axis.name), pressed harder"))
                continue
            }
            out.append(Control(input: "axi \(axis.index) +", section: SectionName.extras,
                               name: "\(axis.name), pushed"))
            out.append(Control(input: "axi \(axis.index) -", section: SectionName.extras,
                               name: "\(axis.name), pulled back"))
        }
        for pad in caps.trackpads {
            let s = pad.surface == 1 ? " s1" : ""
            out += [
                Control(input: "tpd 0 x -\(s)", section: pad.name, name: "\(pad.name) slide left"),
                Control(input: "tpd 0 x +\(s)", section: pad.name, name: "\(pad.name) slide right"),
                Control(input: "tpd 0 y -\(s)", section: pad.name, name: "\(pad.name) slide up"),
                Control(input: "tpd 0 y +\(s)", section: pad.name, name: "\(pad.name) slide down"),
                Control(input: "tpg oneFingerTap\(s)", section: pad.name, name: "\(pad.name) tap"),
                Control(input: "tpg doubleTap\(s)", section: pad.name, name: "\(pad.name) double tap"),
            ]
            if let press = pad.press, !caps.buttons.contains(where: { $0.index == press }) {
                out.append(Control(input: "btn \(press)", section: pad.name, name: "\(pad.name) press"))
            }
        }
        if caps.touchpad {
            let listed = Set(caps.buttons.map(\.index))
            // The 2026 Steam Controller's touchpad input is its right trackpad.
            let rightPad = caps.family == .steamController2026
            out += touchpad.compactMap { control in
                let renamed = rightPad
                    ? Control(input: control.input, section: "Right trackpad",
                              name: control.name.replacingOccurrences(of: "Touchpad", with: "Right trackpad"))
                    : control
                guard control.input == "btn 13" else { return renamed }
                // A press the button list already names is not added twice.
                if caps.touchpadPressIndex != 13 {
                    return listed.contains(caps.touchpadPressIndex) ? nil
                        : Control(input: "btn \(caps.touchpadPressIndex)", section: renamed.section, name: renamed.name)
                }
                return control
            }
        }
        if caps.gyro { out += motion }
        if caps.mouse {
            out += [
                Control(input: "ems button 0 + any", section: "Mouse buttons", name: "Left button"),
                Control(input: "ems button 1 + any", section: "Mouse buttons", name: "Right button"),
                Control(input: "ems button 2 + any", section: "Mouse buttons", name: "Middle button"),
                Control(input: "ems button 3 + any", section: "Mouse buttons", name: "Back button"),
                Control(input: "ems button 4 + any", section: "Mouse buttons", name: "Forward button"),
                Control(input: "ems moveX 0 - any", section: "Mouse movement", name: "Move left"),
                Control(input: "ems moveX 0 + any", section: "Mouse movement", name: "Move right"),
                Control(input: "ems moveY 0 - any", section: "Mouse movement", name: "Move up"),
                Control(input: "ems moveY 0 + any", section: "Mouse movement", name: "Move down"),
                // Scroll signs are macOS's: a positive vertical delta is a
                // scroll up. These used to be named the other way round.
                Control(input: "ems scrollY 0 + any", section: "Scroll", name: "Scroll up"),
                Control(input: "ems scrollY 0 - any", section: "Scroll", name: "Scroll down"),
                Control(input: "ems scrollX 0 - any", section: "Scroll", name: "Scroll left"),
                Control(input: "ems scrollX 0 + any", section: "Scroll", name: "Scroll right"),
                Control(input: "ems scrollGesture 0 + any", section: "Scroll", name: "Scroll gesture (fingers scrolling)"),
                Control(input: "ems doubleClick 0 + any", section: "Mouse buttons", name: "Double click"),
            ]
        }
        if caps.macTaps {
            out += [
                Control(input: "cht 1", section: "Taps on the Mac", name: "Single tap"),
                Control(input: "cht 2", section: "Taps on the Mac", name: "Double tap"),
                Control(input: "cht 3", section: "Taps on the Mac", name: "Triple tap"),
                Control(input: "cht 4", section: "Taps on the Mac", name: "Quadruple tap"),
                Control(input: "cht 5", section: "Taps on the Mac", name: "Quintuple tap"),
            ]
        }
        return out
    }

    /// A standard extended gamepad, for a slot with nothing connected.
    static func standardGamepad() -> [Control] {
        var out = stick(SectionName.leftStick, axes: (0, 1), label: "Left stick")
        out += stick(SectionName.rightStick, axes: (2, 3), label: "Right stick")
        out += triggers(nil)
        out += dpad
        out += [0, 1, 2, 3, 4, 5, 11, 12, 8, 9, 10].map { button($0) }
        return out
    }

    /// Section headings the layout would produce, in order.
    static func sections(of controls: [Control]) -> [String] {
        var seen: [String] = []
        for c in controls where !seen.contains(c.section) { seen.append(c.section) }
        return seen
    }

    // MARK: - Rows

    /// Rows for the given controls (all of them, or one section), skipping
    /// inputs the group already has. Outputs are left empty: the row shows
    /// a "choose an output" menu until one is picked.
    static func bindings(for controls: [Control], existing: [BindingModel]) -> [BindingModel] {
        var taken = Set(existing.map { $0.input.serialized })
        var out: [BindingModel] = []
        for c in controls {
            // Once per input, also within one batch.
            guard !taken.contains(c.input), let input = InputEvent.parse(c.input) else { continue }
            taken.insert(c.input)
            var binding = BindingModel(input: input, outputs: [])
            binding.note = c.name
            binding.section = c.section
            out.append(binding)
        }
        return out
    }

    // MARK: - Sorting existing rows into sections

    /// The heading a row belongs under, from its input and the family its
    /// slot is numbered in. Used to sort a preset that was built by hand
    /// into sections after the fact.
    static func section(for input: InputEvent, family: FaceLetters? = nil) -> String {
        switch input.type {
        case .axis:
            return axisSection(input.index, family: family)
        case .button:
            return buttonSection(input.index, family: family)
        case .hat: return SectionName.dpad
        // `where` binds to the last pattern only, so each case states it.
        case .touchpad where family?.isSteam == true, .touchpadGesture where family?.isSteam == true:
            return input.touchpadSurface == 1 ? "Left trackpad" : "Right trackpad"
        case .touchpad, .touchpadRegion, .touchpadGesture: return SectionName.touchpad
        case .motion: return SectionName.motion
        case .stickRegion: return "Stick regions"
        case .extKey: return "Keyboard"
        case .extMouse: return "Mouse"
        case .cursorRegion: return "Screen regions"
        case .midi: return "MIDI"
        case .chassisTap: return "Mac taps"
        }
    }

    /// Tags every row with the section its input belongs to and orders the
    /// rows so each section is contiguous, keeping the relative order of
    /// rows inside a section.
    static func grouped(_ bindings: [BindingModel], family: FaceLetters? = nil) -> [BindingModel] {
        let order = ["Wheel", "Pedals", SectionName.leftStick, SectionName.rightStick, SectionName.stick,
                     "Left trackpad", "Right trackpad",
                     SectionName.triggers, SectionName.dpad, "Bumpers", SectionName.buttons,
                     "Back buttons", "Grips", SectionName.menuButtons, SectionName.extras,
                     SectionName.touchpad, "Touch sensors", SectionName.motion]
        var tagged = bindings
        // A wheel's Wheel and Pedals headings stay: by number its axes would
        // read as a stick and triggers.
        for i in tagged.indices where tagged[i].section != "Wheel" && tagged[i].section != "Pedals" {
            tagged[i].section = section(for: tagged[i].input, family: family)
        }
        var headings: [String] = []
        for b in tagged where !headings.contains(b.section ?? "") { headings.append(b.section ?? "") }
        headings.sort { a, b in
            let ia = order.firstIndex(of: a) ?? order.count
            let ib = order.firstIndex(of: b) ?? order.count
            return ia == ib ? a < b : ia < ib
        }
        var out: [BindingModel] = []
        for h in headings { out += tagged.filter { ($0.section ?? "") == h } }
        return out
    }
}
