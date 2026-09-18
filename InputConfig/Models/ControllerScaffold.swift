import Foundation

/// Lays out the controls a controller actually has as rows under section
/// headings ("Left stick", "Buttons", "D-pad"...), each row waiting for an
/// output. Nothing is guessed on the output side: the point is to have every
/// control of the device in front of you, organised, ready to bind.
///
/// What counts as "actually has" comes from what the controller reports to
/// macOS (`ControllerInfo`: its button element names, whether it has a
/// touchpad or motion sensors), with one correction: the PlayStation Access
/// Controller reports itself as a full gamepad, but physically it is one
/// stick and eight button sockets around the PS and Options buttons, so it
/// gets that layout.
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

    private static let triggers: [Control] = [
        Control(input: "axi 4 +", section: SectionName.triggers, name: "Left trigger (L2), analogue pull"),
        Control(input: "axi 5 +", section: SectionName.triggers, name: "Right trigger (R2), analogue pull"),
    ]

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
        Control(input: "mtn gyroY -", section: SectionName.motion, name: "Turn left"),
        Control(input: "mtn gyroY +", section: SectionName.motion, name: "Turn right"),
        Control(input: "mtn gyroX +", section: SectionName.motion, name: "Tilt up (nose up)"),
        Control(input: "mtn gyroX -", section: SectionName.motion, name: "Tilt down (nose down)"),
    ]

    /// Standard button indices, their names, and which heading each goes
    /// under. Digital trigger presses (6, 7) are left out when the analogue
    /// triggers are present, since those cover the same pull.
    private static let standardButtons: [(index: Int, name: String, section: String)] = [
        (0, "A / Cross", SectionName.buttons),
        (1, "B / Circle", SectionName.buttons),
        (2, "X / Square", SectionName.buttons),
        (3, "Y / Triangle", SectionName.buttons),
        (4, "LB / L1", SectionName.buttons),
        (5, "RB / R1", SectionName.buttons),
        (6, "LT / L2 press", SectionName.buttons),
        (7, "RT / R2 press", SectionName.buttons),
        (11, "L3 (left stick click)", SectionName.buttons),
        (12, "R3 (right stick click)", SectionName.buttons),
        (8, "Back / Share / Options", SectionName.menuButtons),
        (9, "Start / Menu", SectionName.menuButtons),
        (10, "Home / PS", SectionName.menuButtons),
        (14, "Share / Create", SectionName.menuButtons),
        (15, "Microphone / Mute", SectionName.menuButtons),
        (16, "Left paddle", SectionName.extras),
        (17, "Right paddle", SectionName.extras),
        (18, "Paddle 3", SectionName.extras),
        (19, "Paddle 4", SectionName.extras),
        (20, "FN 1 / Left function", SectionName.extras),
        (21, "FN 2 / Right function", SectionName.extras),
    ]

    private static func button(_ index: Int, fallbackName: String? = nil) -> Control {
        if let std = standardButtons.first(where: { $0.index == index }) {
            return Control(input: "btn \(index)", section: std.section, name: std.name)
        }
        return Control(input: "btn \(index)", section: SectionName.extras,
                       name: fallbackName ?? "Button \(index)")
    }

    // MARK: - What the device presents

    /// The controls a slot's device actually reports, gathered from the
    /// service that drives it: the GameController framework's element list
    /// and motion object, a raw HID gamepad's decoded layout, the Steam
    /// Controller's own report, or the Mac's mouse. Nothing here is assumed
    /// from a name; a gyro is offered only when the device publishes one.
    struct DeviceCapabilities {
        var deviceName: String
        var sticks: [(section: String, x: Int, y: Int, label: String)] = []
        var triggers = false
        var dpad = false
        var buttons: [(index: Int, name: String)] = []
        var touchpad = false
        var gyro = false
        var mouse = false
        var macTaps = false
        /// Analogue inputs past the standard six: an extra trigger or a
        /// pedal plugged into an adaptive controller.
        var extraAxes: [(index: Int, name: String)] = []
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
        }

        /// A one-line inventory for the prompt: "stick, 8 buttons, PS and
        /// Options".
        var summary: String {
            var parts: [String] = []
            parts += sticks.map { $0.label.lowercased() }
            if triggers { parts.append("triggers") }
            if dpad { parts.append("D-pad") }
            if !buttons.isEmpty { parts.append(buttons.count == 1 ? "1 button" : "\(buttons.count) buttons") }
            if touchpad { parts.append("touchpad") }
            if gyro { parts.append("gyro") }
            if mouse { parts.append("mouse buttons, movement, and scroll") }
            if !extraAxes.isEmpty {
                parts.append(extraAxes.count == 1 ? "1 extra analogue input"
                             : "\(extraAxes.count) extra analogue inputs")
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

    /// Reads a slot's device through the services.
    @MainActor
    static func capabilities(service: GameControllerService, slot: Int,
                             inputKind: SlotInputKind,
                             purpose: Purpose = .layout) -> DeviceCapabilities {
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
            var caps = DeviceCapabilities(deviceName: "Steam Controller")
            caps.sticks = [
                (SectionName.stick, 0, 1, "Stick"),
                ("Right trackpad", 2, 3, "Right trackpad"),
                ("Left trackpad", 6, 7, "Left trackpad"),
            ]
            caps.triggers = true
            caps.dpad = true
            caps.buttons = SteamControllerButton.allCases
                .filter { $0 != .stickActive }
                .map { ($0.bindingIndex, $0.displayName) }
            return caps   // no gyro reaches the engine from this driver
        }

        // Raw HID gamepad: exactly what its decoder produces.
        if let gamepad = service.rawHIDGamepadSlots[slot] {
            var caps = DeviceCapabilities(deviceName: gamepad.displayName)
            let names = gamepad.profile?.physicalButtonNames ?? []
            switch gamepad.profile?.layout {
            case .xinput:
                caps.sticks = twoSticks
                caps.triggers = true
                caps.dpad = true
                caps.buttons = [0, 1, 2, 3, 4, 5, 8, 9, 10, 11, 12].map { ($0, standardName($0)) }
            case .dualShock3:
                caps.sticks = twoSticks
                caps.triggers = true
                caps.dpad = true
                caps.buttons = (0...12).map { ($0, standardName($0)) }
            case .generic(let layout):
                let axisCount = layout.axisByteOffsets.count
                if axisCount >= 2 { caps.sticks.append((SectionName.leftStick, 0, 1, "Left stick")) }
                if axisCount >= 4 { caps.sticks.append((SectionName.rightStick, 2, 3, "Right stick")) }
                caps.triggers = !layout.triggerByteOffsets.isEmpty
                caps.dpad = layout.hatBitOffset != nil || layout.hatByteOffset != nil
                caps.buttons = (0..<layout.buttonBitOffsets.count).map { i in
                    (i, i < names.count ? names[i] : "Button \(i)")
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
            var caps = DeviceCapabilities(deviceName: name)
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
                caps.sticks = [(SectionName.stick, 0, 1, "Stick")]
                // The two centre buttons report differently depending on the
                // on-device profile: Options (8), Menu (9), or Home (10).
                // All three are offered so whichever one this controller
                // sends has a row.
                caps.buttons = (0...7).map { ($0, standardName($0)) }
                    + [(8, standardName(8)), (9, standardName(9)), (10, standardName(10))]
                return caps
            }

            let elements = Set(controller.physicalInputProfile.buttons.keys)

            // Xbox Adaptive Controller: macOS presents a full gamepad because
            // every port can be assigned to any input, but the unit itself
            // has two large buttons, a D-pad, View, Menu and Xbox. Anything
            // plugged into a port arrives through the accessory watch as an
            // extra button or axis and is offered then. The mirror purpose
            // keeps the full shape so the visualizer draws what is reported.
            if purpose == .layout,
               (controller.productCategory + " " + name).localizedCaseInsensitiveContains("adaptive") {
                caps.dpad = elements.contains("Direction Pad Up")
                caps.buttons = [(0, standardName(0)), (1, standardName(1)),
                                (8, standardName(8)), (9, standardName(9)), (10, standardName(10))]
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
                    namesByIndex[index] = standardButtons.contains(where: { $0.index == index }) ? standardName(index) : element
                }
            }
            for extra in service.extraButtonsSnapshot(for: slot) where namesByIndex[extra.index] == nil && extra.index != 13 {
                namesByIndex[extra.index] = standardButtons.contains(where: { $0.index == extra.index }) ? standardName(extra.index) : extra.label
            }
            caps.buttons = namesByIndex.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
            caps.extraAxes = service.extraAxesSnapshot(for: slot).map { ($0.index, $0.label) }
            return caps
        }

        // No GameController object but the slot still has a device on
        // record (a marketing capture, a pad whose details came from
        // elsewhere): build from what those details say it has.
        if let info = service.controllerDetails[slot] {
            var caps = DeviceCapabilities(deviceName: info.name)
            caps.gyro = info.supportsMotion
            caps.touchpad = info.hasTouchpad
            if purpose == .layout, info.name.localizedCaseInsensitiveContains("access controller") {
                caps.sticks = [(SectionName.stick, 0, 1, "Stick")]
                caps.buttons = (0...7).map { ($0, standardName($0)) }
                    + [(8, standardName(8)), (9, standardName(9)), (10, standardName(10))]
                return caps
            }
            if info.axisCount >= 2 { caps.sticks.append((SectionName.leftStick, 0, 1, "Left stick")) }
            if info.axisCount >= 4 { caps.sticks.append((SectionName.rightStick, 2, 3, "Right stick")) }
            caps.triggers = info.axisCount >= 6
            caps.dpad = true
            // Positions first, because a device on this path reports its
            // buttons by index; then any named extra the map knows (a
            // paddle, an FN button) that sits past the standard block.
            // Only the standard block is implied by a count; anything past
            // it (a paddle, an FN button) has to be named by the device.
            var namesByIndex: [Int: String] = [:]
            for index in 0..<min(max(info.buttonCount, 4), 13) { namesByIndex[index] = standardName(index) }
            for name in info.physicalButtonNames {
                if let index = GameControllerService.publicKnownButtonMap[name], namesByIndex[index] == nil {
                    namesByIndex[index] = standardButtons.contains(where: { $0.index == index }) ? standardName(index) : name
                }
            }
            if caps.triggers { namesByIndex[6] = nil; namesByIndex[7] = nil }
            namesByIndex[13] = nil   // touchpad press has its own widget
            for extra in service.extraButtonsSnapshot(for: slot) where namesByIndex[extra.index] == nil && extra.index != 13 {
                namesByIndex[extra.index] = standardButtons.contains(where: { $0.index == extra.index }) ? standardName(extra.index) : extra.label
            }
            caps.buttons = namesByIndex.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
            return caps
        }

        // Nothing in the slot: a standard gamepad, and say so. The
        // visualizer lands here when no device is connected, which is what
        // keeps a preset page from showing an empty panel.
        var caps = DeviceCapabilities(deviceName: "a standard controller")
        caps.sticks = twoSticks
        caps.triggers = true
        caps.dpad = true
        caps.buttons = [0, 1, 2, 3, 4, 5, 11, 12, 8, 9, 10].map { ($0, standardName($0)) }
        caps.note = "No controller is connected to this slot; this is a standard layout."
        return caps
    }

    private static let twoSticks: [(section: String, x: Int, y: Int, label: String)] = [
        (SectionName.leftStick, 0, 1, "Left stick"),
        (SectionName.rightStick, 2, 3, "Right stick"),
    ]

    private static func standardName(_ index: Int) -> String {
        standardButtons.first(where: { $0.index == index })?.name ?? "Button \(index)"
    }

    // MARK: - Per-device layout

    /// Rows for everything the device presents, under a heading per part.
    static func controls(for caps: DeviceCapabilities) -> [Control] {
        var out: [Control] = []
        for s in caps.sticks { out += stick(s.section, axes: (s.x, s.y), label: s.label) }
        if caps.triggers { out += triggers }
        if caps.dpad { out += dpad }
        for b in caps.buttons {
            if let std = standardButtons.first(where: { $0.index == b.index }) {
                out.append(Control(input: "btn \(b.index)", section: std.section, name: b.name))
            } else {
                out.append(Control(input: "btn \(b.index)", section: SectionName.extras, name: b.name))
            }
        }
        for axis in caps.extraAxes {
            out.append(Control(input: "axi \(axis.index) +", section: SectionName.extras,
                               name: "\(axis.name), pushed"))
            out.append(Control(input: "axi \(axis.index) -", section: SectionName.extras,
                               name: "\(axis.name), pulled back"))
        }
        if caps.touchpad { out += touchpad }
        if caps.gyro { out += motion }
        if caps.mouse {
            out += [
                Control(input: "ems button 0 + any", section: "Mouse buttons", name: "Left button"),
                Control(input: "ems button 1 + any", section: "Mouse buttons", name: "Right button"),
                Control(input: "ems button 2 + any", section: "Mouse buttons", name: "Middle button"),
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
        out += triggers
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
        let taken = Set(existing.map { $0.input.serialized })
        var out: [BindingModel] = []
        for c in controls {
            guard !taken.contains(c.input), let input = InputEvent.parse(c.input) else { continue }
            var binding = BindingModel(input: input, outputs: [])
            binding.note = c.name
            binding.section = c.section
            out.append(binding)
        }
        return out
    }

    // MARK: - Sorting existing rows into sections

    /// The heading a row belongs under, from its input alone. Used to sort
    /// a preset that was built by hand into sections after the fact.
    static func section(for input: InputEvent) -> String {
        switch input.type {
        case .axis:
            switch input.index {
            case 0, 1: return SectionName.leftStick
            case 2, 3: return SectionName.rightStick
            case 4, 5: return SectionName.triggers
            default: return "Axes"
            }
        case .button:
            if let std = standardButtons.first(where: { $0.index == input.index }) { return std.section }
            return SectionName.extras
        case .hat: return SectionName.dpad
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
    static func grouped(_ bindings: [BindingModel]) -> [BindingModel] {
        let order = [SectionName.leftStick, SectionName.rightStick, SectionName.stick,
                     SectionName.triggers, SectionName.dpad, SectionName.buttons,
                     SectionName.menuButtons, SectionName.extras, SectionName.touchpad,
                     SectionName.motion]
        var tagged = bindings
        for i in tagged.indices { tagged[i].section = section(for: tagged[i].input) }
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
