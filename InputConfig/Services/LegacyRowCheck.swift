import AppKit
import Combine
import GameController
import IOKit.hid

/// Rows recorded before 1.6 that 1.6 reads from another button: a Switch Pro
/// Controller's or Joy-Con pair's face buttons (1.6 numbers them by
/// position, 1.5 by the printed letter) and an 8BitDo pad's two back buttons
/// (1.6 reads them as 16 and 17, 1.5 as unknown extras at 20 and 21).
///
/// 1.5 wrote nothing that says which pad a group's rows came from, so the
/// presets that were on disk when 1.6 first ran are remembered, and the
/// first time one of those pads connects the ones with such rows are listed,
/// each with a checkbox, and fixed for the ones ticked. A preset left as it
/// was is not offered for that kind again, until "Check older presets
/// again" in Settings.
///
/// Pads 1.5 read from their report descriptor (generic USB pads, 8BitDo
/// pads in D-input, arcade encoders, Logitech wheels) are numbered another
/// way in 1.6; their rows are moved by where each control sits in the
/// report (see Numbering15). A wheel 1.6 switches to its own mode reports
/// differently altogether, so for it the presets are only named.
@MainActor
final class LegacyRowCheck {
    static let shared = LegacyRowCheck()

    enum Kind: String, CaseIterable {
        case switchFaces, eightBitDoBack, rawPads, switchedWheel
        /// The presets still to offer for this kind, by id.
        var pendingKey: String { "InputConfig.legacyRowCheck.\(rawValue).pending" }
    }

    /// Adds presets made before 1.6 (on disk when 1.6 first ran, or
    /// restored from a 1.5 backup) to every kind's list, with their rows as
    /// they were then, so a row scanned again in 1.6 is left alone and the
    /// rest are still offered. Presets already offered are not added back.
    static func rememberOlder(_ presets: [Preset]) {
        guard !presets.isEmpty else { return }
        let defaults = UserDefaults.standard
        let ids = presets.map(\.id.uuidString)
        for kind in Kind.allCases {
            var pending = Set(defaults.stringArray(forKey: kind.pendingKey) ?? [])
            let offered = Set(defaults.stringArray(forKey: offeredKey(kind)) ?? [])
            pending.formUnion(ids.filter { !offered.contains($0) })
            defaults.set(Array(pending), forKey: kind.pendingKey)
        }
        var rows = defaults.dictionary(forKey: rowsKey) as? [String: [String]] ?? [:]
        for p in presets {
            rows[p.id.uuidString] = p.joysticks.flatMap(\.bindings).map { rowKey($0) }
        }
        defaults.set(rows, forKey: rowsKey)
        olderInputs = nil
    }

    /// Each remembered preset's rows when it was remembered, as row id and
    /// input; a row whose input changed since was recorded in 1.6.
    nonisolated static let rowsKey = "InputConfig.legacyRowCheck.rows"
    private static func rowKey(_ row: BindingModel) -> String { "\(row.id.uuidString)|\(row.input.serialized)" }

    /// The rows of a group that are as they were before 1.6: those in the
    /// snapshot, or, with none (an earlier 1.6 build), every row of a group
    /// nothing was scanned into.
    private static func olderRows(_ group: JoystickMapping, snapshot: Set<String>?) -> [BindingModel] {
        guard let snapshot else { return group.deviceFingerprint == nil ? group.bindings : [] }
        return group.bindings.filter { snapshot.contains(rowKey($0)) }
    }

    /// Every row of a preset made before 1.6, as its input was then, by
    /// row id; read once and kept, for the engine's per-frame checks.
    nonisolated(unsafe) private static var olderInputs: [UUID: String]?

    /// Whether a row is as it was recorded before 1.6 (same row, same
    /// input). Such a row keeps 1.5's touchpad vertical speed.
    nonisolated static func isOlderRow(_ row: BindingModel) -> Bool {
        if olderInputs == nil {
            var map: [UUID: String] = [:]
            for keys in (UserDefaults.standard.dictionary(forKey: rowsKey) as? [String: [String]] ?? [:]).values {
                for key in keys {
                    let parts = key.split(separator: "|", maxSplits: 1)
                    if parts.count == 2, parts[1].hasPrefix("tpd"), let id = UUID(uuidString: String(parts[0])) {
                        map[id] = String(parts[1])
                    }
                }
            }
            olderInputs = map
        }
        return olderInputs?[row.id] == row.input.serialized
    }

    /// Takes converted rows out of a preset's snapshot, so they no longer
    /// count as made before 1.6. A whole-axis row converted for a USB pad
    /// keeps its input and only flips Invert; still in the snapshot, Check
    /// Older Presets Again offered it again and flipped it back.
    private static func forget(_ rows: Set<UUID>, in presetID: UUID) {
        guard !rows.isEmpty else { return }
        let defaults = UserDefaults.standard
        var all = defaults.dictionary(forKey: rowsKey) as? [String: [String]] ?? [:]
        guard let keys = all[presetID.uuidString] else { return }
        all[presetID.uuidString] = keys.filter { key in
            !rows.contains { key.hasPrefix($0.uuidString + "|") }
        }
        defaults.set(all, forKey: rowsKey)
        olderInputs = nil
    }

    private static func snapshot(for id: UUID) -> Set<String>? {
        (UserDefaults.standard.dictionary(forKey: rowsKey) as? [String: [String]])?[id.uuidString].map(Set.init)
    }

    private static func offeredKey(_ kind: Kind) -> String { "InputConfig.legacyRowCheck.\(kind.rawValue).offered" }

    private weak var store: PresetStore?
    private weak var service: GameControllerService?
    private var watch: AnyCancellable?
    private var activeWatch: NSObjectProtocol?
    private var retry: Timer?
    private var asking = false

    /// The raw pad being offered for, with 1.5's numbering of it.
    struct RawPad {
        let name: String
        let old: Numbering15.Layout
        let new: HIDExtendedLayout
        func move(_ e: InputEvent) -> Numbering15.Moved? { Numbering15.translate(e, old: old, new: new) }
    }
    private var rawPad: RawPad?
    private var wheelName: String?

    /// Wheels that 1.6 switches out of compatibility mode, by the product
    /// ID they come back with: 1.5 read them as 046D:C294.
    static let switchedWheelProducts: Set<Int32> = [0xC298, 0xC299, 0xC29A, 0xC29B, 0xC24F]

    /// Lists every preset made before 1.6 again for every kind, so each is
    /// offered the next time its controller connects. Returns how many.
    @discardableResult
    func checkAgain() -> Int {
        let defaults = UserDefaults.standard
        var count = 0
        for kind in Kind.allCases {
            let offered = Set(defaults.stringArray(forKey: Self.offeredKey(kind)) ?? [])
            let pending = Set(defaults.stringArray(forKey: kind.pendingKey) ?? []).union(offered)
            count = max(count, pending.count)
            defaults.set(Array(pending), forKey: kind.pendingKey)
            defaults.removeObject(forKey: Self.offeredKey(kind))
        }
        check()
        return count
    }

    func install(store: PresetStore, service: GameControllerService) {
        self.store = store
        self.service = service
        guard watch == nil else { return }
        // A build before this one kept a single list and a done flag.
        let defaults = UserDefaults.standard
        if let old = defaults.stringArray(forKey: "InputConfig.presetsFromBefore16") {
            for kind in Kind.allCases where !defaults.bool(forKey: "InputConfig.legacyRowCheck.\(kind.rawValue).done") {
                defaults.set(old, forKey: kind.pendingKey)
            }
            defaults.removeObject(forKey: "InputConfig.presetsFromBefore16")
            for kind in Kind.allCases { defaults.removeObject(forKey: "InputConfig.legacyRowCheck.\(kind.rawValue).done") }
        }
        // Kinds added after a 1.6 build already ran start from the presets
        // the first kinds were given (the ones made before 1.6).
        let first = Set((defaults.stringArray(forKey: Kind.switchFaces.pendingKey) ?? [])
                        + (defaults.stringArray(forKey: Self.offeredKey(.switchFaces)) ?? []))
        for kind in [Kind.rawPads, .switchedWheel] where defaults.object(forKey: kind.pendingKey) == nil
            && defaults.object(forKey: Self.offeredKey(kind)) == nil && !first.isEmpty {
            defaults.set(Array(first), forKey: kind.pendingKey)
        }
        watch = service.$controllerDetails
            .debounce(for: .seconds(1.5), scheduler: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.check() } }
    }

    // MARK: - Which groups

    /// Whether a group could hold rows recorded on that pad: nothing in it
    /// was scanned in 1.6 (no fingerprint), it reads a controller, and any
    /// device it is set to is that kind of pad.
    private static func candidate(_ group: JoystickMapping, kind: Kind, family: FaceLetters?, snapshot: Set<String>?,
                                  pad: RawPad? = nil, wheel: String? = nil) -> Bool {
        guard group.inputKind == .auto || group.inputKind == .controller else { return false }
        let name = (group.customName ?? "").lowercased()
        let inputs = olderRows(group, snapshot: snapshot).flatMap { [$0.input] + $0.modifiers }
        let rows = inputs.filter { $0.type == .button }.map(\.index)
        // A group set to another device by name was not made on this pad.
        func pinnedElsewhere(_ device: String) -> Bool {
            let d = device.lowercased()
            return group.inputKind == .controller && !name.isEmpty && !d.contains(name) && !name.contains(d)
        }
        switch kind {
        case .rawPads:
            guard let pad, !pinnedElsewhere(pad.name) else { return false }
            if family == .playstation || family == .nintendo { return false }
            // Something on this pad really moves.
            return inputs.contains { e in [.button, .axis, .hat].contains(e.type) && pad.move(e).map { $0.input != e || $0.flipsAxis } == true }
        case .switchedWheel:
            guard let wheel, !pinnedElsewhere(wheel) else { return false }
            return inputs.contains { $0.type == .button || $0.type == .axis }
        case .switchFaces:
            if group.inputKind == .controller, !name.isEmpty, !(name.contains("pro controller") || name.contains("joy-con")) { return false }
            return rows.contains { (0...3).contains($0) }
        case .eightBitDoBack:
            if family == .playstation || name.contains("dualsense") { return false }
            if group.inputKind == .controller, !name.isEmpty, !name.contains("8bitdo") { return false }
            return rows.contains { $0 == 20 || $0 == 21 } && !rows.contains { $0 == 16 || $0 == 17 }
        }
    }

    /// Whether a preset looks made for that pad, so its box starts ticked:
    /// its name, its button names or a group's device says so. Anything
    /// else starts clear, since swapping a preset made on another pad would
    /// break it; being the last preset run is no evidence of the pad.
    private func looksMade(for kind: Kind, _ preset: Preset) -> Bool {
        let words = ([preset.name] + preset.joysticks.compactMap(\.customName)).joined(separator: " ").lowercased()
        switch kind {
        case .switchFaces:
            if preset.buttonFamily == .nintendo { return true }
            return ["switch", "nintendo", "joy-con", "joycon", "pro controller"].contains(where: { Self.hasWord(words, $0) })
        case .eightBitDoBack:
            return words.contains("8bitdo") || words.contains("8 bitdo")
        case .rawPads:
            // A distinctive word of the pad's name ("F310", "SNES",
            // "8BitDo") in the preset's name or a group's device. Short and
            // common words ("Pro", "Generic") matched presets like Logic Pro.
            let skip: Set<String> = ["controller", "gamepad", "wireless", "joystick", "usb", "the", "and", "game", "pad",
                                     "generic", "wired", "mode", "input", "plus", "mini", "lite", "edition"]
            let padWords = (padName ?? "").lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
                .filter { $0.count >= 4 && !skip.contains($0) }
            return padWords.contains { Self.hasWord(words, $0) }
        case .switchedWheel:
            return false
        }
    }

    /// Whole words only: "switch" but not "switcher".
    private static func hasWord(_ text: String, _ word: String) -> Bool {
        text.range(of: "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b", options: .regularExpression) != nil
    }

    static func fix(_ group: inout JoystickMapping, kind: Kind, snapshot: Set<String>? = nil, pad: RawPad? = nil) {
        let older = Set(olderRows(group, snapshot: snapshot).map(\.id))
        if kind == .rawPads, let pad {
            for r in group.bindings.indices where older.contains(group.bindings[r].id) {
                let row = group.bindings[r]
                if let moved = pad.move(row.input) {
                    group.bindings[r].input = moved.input
                    if moved.flipsAxis { group.bindings[r].invertAxis = !(row.invertAxis ?? false) }
                }
                let mods = row.modifiers.map { pad.move($0)?.input ?? $0 }
                if mods != row.modifiers { group.bindings[r].setModifiers(mods) }
            }
            return
        }
        func moved(_ e: InputEvent) -> InputEvent {
            guard e.type == .button else { return e }
            var out = e
            switch kind {
            case .switchFaces where (0...3).contains(e.index): out.index = [1, 0, 3, 2][e.index]
            case .eightBitDoBack where e.index == 20 || e.index == 21: out.index = e.index - 4
            default: break
            }
            return out
        }
        for r in group.bindings.indices where older.contains(group.bindings[r].id) {
            let row = group.bindings[r]
            group.bindings[r].input = moved(row.input)
            let mods = row.modifiers.map(moved)
            if mods != row.modifiers { group.bindings[r].setModifiers(mods) }
        }
    }

    /// The pending presets that still have such rows. Pending presets that
    /// no longer do are dropped from the list: rows added since are 1.6 rows.
    private func affected(_ kind: Kind) -> [(preset: Preset, groups: [UUID])] {
        guard let store else { return [] }
        let defaults = UserDefaults.standard
        let pending = Set(defaults.stringArray(forKey: kind.pendingKey) ?? [])
        guard !pending.isEmpty else { return [] }
        let list: [(preset: Preset, groups: [UUID])] = store.presets.compactMap { p in
            guard pending.contains(p.id.uuidString) else { return nil }
            let snap = Self.snapshot(for: p.id)
            let groups = p.joysticks.filter { Self.candidate($0, kind: kind, family: p.buttonFamily, snapshot: snap,
                                                             pad: rawPad, wheel: wheelName) }.map(\.id)
            return groups.isEmpty ? nil : (p, groups)
        }
        // Presets gone or without such rows leave the list; ones in the
        // trash stay, so Put Back can still be offered.
        let trashed = Set(store.recentlyDeleted.map(\.preset.id.uuidString)
                          + store.deletedFolders.flatMap(\.presets).map(\.id.uuidString))
        let keep = Set(list.map(\.preset.id.uuidString)).union(pending.intersection(trashed))
        // Only for the fixed kinds: a preset whose rows do not move on this
        // raw pad may have been made on another one.
        if keep != pending, kind == .switchFaces || kind == .eightBitDoBack {
            defaults.set(Array(keep), forKey: kind.pendingKey)
        }
        return list
    }

    // MARK: - Asking

    /// The pad is here, read the way 1.6 changed. Only GameController reads
    /// a Switch pad's face buttons by position, so a Nintendo pad read raw
    /// (the GameCube adapter, a Switch 2 Pro on USB) is not one.
    private func present(_ kind: Kind) -> Bool {
        guard let service else { return false }
        switch kind {
        case .switchFaces:
            return service.connectedControllers.contains {
                let brand = ControllerTypeDetector.detect($0)
                return brand == .switchPro || brand == .joyConPair
            }
        case .eightBitDoBack:
            return service.connectedControllers.contains { c in
                let buttons = c.physicalInputProfile.buttons
                return buttons["Back Left Button 0"] != nil || buttons["Back Right Button 0"] != nil
            }
        case .rawPads:
            rawPad = service.rawHIDGamepadSlots.sorted { $0.key < $1.key }.lazy.compactMap { Self.rawPad(for: $0.value) }.first
            return rawPad != nil
        case .switchedWheel:
            wheelName = service.rawHIDGamepadSlots.values.first {
                $0.vendorID == 0x046D && Self.switchedWheelProducts.contains($0.productID)
            }?.displayName
            return wheelName != nil
        }
    }

    /// A pad 1.5 read from its descriptor and 1.6 reads another way, with
    /// both numberings; nil for anything else.
    static func rawPad(for pad: RawHIDGamepad) -> RawPad? {
        guard Numbering15.readFromDescriptor(vendor: pad.vendorID, product: pad.productID),
              !(pad.vendorID == 0x046D && switchedWheelProducts.contains(pad.productID)),
              case .generic(let layout)? = pad.profile?.layout, let new = layout.extended,
              let descriptor = IOHIDDeviceGetProperty(pad.device, kIOHIDReportDescriptorKey as CFString) as? Data,
              let old = Numbering15.parse(descriptor) else { return nil }
        return RawPad(name: pad.displayName, old: old, new: new)
    }

    private func check() {
        guard !asking else { return }
        defer {
            // Nothing left to ask: no reason to keep looking.
            if !asking, !Kind.allCases.contains(where: { present($0) && !affected($0).isEmpty }) {
                retry?.invalidate(); retry = nil
            }
        }
        for kind in Kind.allCases where present(kind) {
            let list = affected(kind)
            guard !list.isEmpty else { continue }
            // Not over another app (a game in front), and not under an open
            // editor, whose own copy of a preset would overwrite the fix.
            guard NSApplication.shared.isActive, OpenEditor.current == nil else {
                waitForChance()
                return
            }
            retry?.invalidate(); retry = nil
            asking = true
            RunLoop.main.perform(inModes: [.default]) { [weak self] in
                MainActor.assumeIsolated { self?.ask(kind, list) }
            }
            return
        }
    }

    /// Looks again when the app comes to the front, and every few seconds
    /// while it is in front with an editor open.
    private func waitForChance() {
        if activeWatch == nil {
            activeWatch = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.check() }
                }
            }
        }
        guard retry == nil else { return }
        retry = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if NSApplication.shared.isActive, OpenEditor.current == nil { self.check() }
            }
        }
        retry?.tolerance = 1
    }

    /// The raw pad's name, for the alert's wording.
    private var padName: String? {
        #if DEBUG
        if let debugPadName { return debugPadName }
        #endif
        return rawPad?.name
    }

    #if DEBUG
    private var debugPadName: String?

    /// Marketing capture: shows one kind's alert as it appears, over three
    /// example presets, and changes nothing whatever is answered
    /// (`post inputconfig.debug.legacyalert switchFaces`).
    func debugPreview(_ name: String) {
        guard let kind = Kind(rawValue: name), !asking else { return }
        let names: [String]
        switch kind {
        case .switchFaces: names = ["Switch Pro Desktop", "Mario Kart 8 Deluxe", "Web Browsing"]
        case .eightBitDoBack: names = ["8BitDo Couch Browsing", "Hollow Knight", "Media Controller"]
        case .rawPads, .switchedWheel: names = ["Racing with the USB Gamepad", "Desktop Navigation", "Stardew Valley"]
        }
        debugPadName = kind == .rawPads ? "USB Gamepad" : nil
        if kind == .switchedWheel { wheelName = "G29 Driving Force Racing Wheel" }
        asking = true
        ask(kind, names.map { (preset: Preset(name: $0), groups: [UUID]()) }, preview: true)
        debugPadName = nil
    }
    #endif

    private func ask(_ kind: Kind, _ list: [(preset: Preset, groups: [UUID])], preview: Bool = false) {
        defer { asking = false }
        let alert = NSAlert()
        let defaults = UserDefaults.standard
        let listed = Set(list.map(\.preset.id.uuidString))
        func markOffered() {
            defaults.set(Array(Set(defaults.stringArray(forKey: kind.pendingKey) ?? []).subtracting(listed)), forKey: kind.pendingKey)
            defaults.set(Array(Set(defaults.stringArray(forKey: Self.offeredKey(kind)) ?? []).union(listed)), forKey: Self.offeredKey(kind))
        }
        if kind == .switchedWheel {
            // Its own mode reports every control differently, so the rows
            // cannot be moved; the presets are named so they can be rescanned.
            let wheel = wheelName ?? "This wheel"
            alert.messageText = "Rescan wheel rows in older presets"
            alert.informativeText = "InputConfig 1.6 switches \(wheel) to its own mode, as Logitech's software does: the pedals read 0 to 1 on their own axes and the buttons have new numbers. Rows recorded on it before 1.6 need to be scanned again in:\n\n" + list.map(\.preset.name).joined(separator: "\n")
            alert.addButton(withTitle: "OK")
            alert.runModal()
            if preview { return }
            markOffered()
            ActivityLog.shared.info("Presets", "Named the presets with \(wheel) rows from before 1.6 to rescan")
            return
        }
        switch kind {
        case .switchFaces:
            alert.messageText = "Update Switch rows in older presets?"
            alert.informativeText = "InputConfig 1.6 reads the face buttons of a Switch Pro Controller and Joy-Cons by position, so A is the button on the right. Rows recorded on one of these controllers before 1.6 would now fire from the button beside it. Tick the presets you made on this controller; swapping A with B and X with Y keeps their rows on the buttons you pressed."
            alert.addButton(withTitle: "Swap in Ticked Presets")
        case .eightBitDoBack:
            alert.messageText = "Update 8BitDo back button rows in older presets?"
            alert.informativeText = "InputConfig 1.6 reads an 8BitDo controller's two back buttons as back buttons. Rows recorded on them before 1.6 used other numbers and no longer fire. Tick the presets you made on this controller to move those rows to the back buttons."
            alert.addButton(withTitle: "Move in Ticked Presets")
        case .rawPads, .switchedWheel:
            let pad = padName ?? "this controller"
            alert.messageText = "Update rows for \(pad) in older presets?"
            alert.informativeText = "InputConfig 1.6 numbers the buttons and sticks of \(pad) the way it numbers other controllers, and pushing a stick up reads as up. Rows recorded on it before 1.6 would fire from other controls. Tick the presets you made on this controller to move their rows to the controls you pressed."
            alert.addButton(withTitle: "Update Ticked Presets")
        }
        alert.addButton(withTitle: "Leave Them As They Are")

        // One checkbox per preset, in a scroll view past a handful.
        let boxes: [NSButton] = list.map { item in
            let box = NSButton(checkboxWithTitle: item.preset.name, target: nil, action: nil)
            box.state = looksMade(for: kind, item.preset) ? .on : .off
            return box
        }
        // The first button does nothing with nothing ticked, so it is off
        // until a box is: pressing Return on an all-clear list used to
        // count as an answer.
        let watcher = TickWatcher(boxes: boxes, button: alert.buttons[0])
        boxes.forEach { $0.target = watcher; $0.action = #selector(TickWatcher.changed) }
        watcher.changed()
        let stack = NSStackView(views: boxes)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 2, bottom: 4, right: 2)
        let fitting = stack.fittingSize
        let height = min(fitting.height, 220)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: height))
        scroll.hasVerticalScroller = fitting.height > 220
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        if fitting.height <= 220 {
            stack.frame = NSRect(x: 0, y: 0, width: 300, height: fitting.height)
            alert.accessoryView = stack
        } else {
            // Flipped, so the list starts at the top of the scroll view.
            let page = FlippedView(frame: NSRect(x: 0, y: 0, width: 300, height: fitting.height))
            stack.frame = page.bounds
            page.addSubview(stack)
            scroll.documentView = page
            alert.accessoryView = scroll
        }

        let answer = alert.runModal()
        withExtendedLifetime(watcher) {}
        if preview { return }
        // Answered: none of these is offered for this kind again, until
        // Check Older Presets Again in Settings.
        markOffered()

        let ticked = Set(zip(list, boxes).filter { $0.1.state == .on }.map(\.0.preset.id))
        guard answer == .alertFirstButtonReturn, !ticked.isEmpty, let store else {
            let what = kind == .switchFaces ? "Switch face buttons" : kind == .eightBitDoBack ? "8BitDo back buttons" : (rawPad?.name ?? "raw pad")
            ActivityLog.shared.info("Presets", "Left the rows recorded before 1.6 as they were (\(what))")
            return
        }
        for item in list where ticked.contains(item.preset.id) {
            guard var preset = store.presets.first(where: { $0.id == item.preset.id }) else { continue }
            let snap = Self.snapshot(for: preset.id)
            var converted = Set<UUID>()
            for g in preset.joysticks.indices where item.groups.contains(preset.joysticks[g].id)
                && Self.candidate(preset.joysticks[g], kind: kind, family: preset.buttonFamily, snapshot: snap, pad: rawPad) {
                converted.formUnion(Self.olderRows(preset.joysticks[g], snapshot: snap).map(\.id))
                Self.fix(&preset.joysticks[g], kind: kind, snapshot: snap, pad: rawPad)
            }
            store.savePreset(preset)
            Self.forget(converted, in: preset.id)
            switch kind {
            case .switchFaces:
                ActivityLog.shared.info("Presets", "Swapped A with B and X with Y in \(preset.name), for rows recorded on a Switch pad before 1.6")
            case .eightBitDoBack:
                ActivityLog.shared.info("Presets", "Moved the 8BitDo back button rows in \(preset.name) to the numbers 1.6 reads")
            case .rawPads, .switchedWheel:
                ActivityLog.shared.info("Presets", "Moved the rows in \(preset.name) recorded on \(rawPad?.name ?? "a raw pad") before 1.6 to the controls 1.6 reads")
            }
        }
    }
}

/// Keeps the alert's first button off while no box is ticked.
private final class TickWatcher: NSObject {
    let boxes: [NSButton]
    weak var button: NSButton?
    init(boxes: [NSButton], button: NSButton) {
        self.boxes = boxes
        self.button = button
    }
    @objc func changed() {
        button?.isEnabled = boxes.contains { $0.state == .on }
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}


// MARK: - 1.5 numbering of pads read from their report descriptor

/// How InputConfig 1.5 numbered a pad it read from its HID report
/// descriptor (every raw pad without a hand-made profile): buttons in bit
/// order, sticks in byte order with Y and Ry flipped to up-positive,
/// sliders on axes 4 and 5 (and buttons 6 and 7), one hat. 1.6 reads many
/// of these pads through SDL's database or its own descriptor reader, so
/// rows recorded in 1.5 are paired with 1.6's by where each control sits
/// in the report. The parser is 1.5's own, unchanged.
enum Numbering15 {
    struct Layout {
        var buttonBitOffsets: [Int]
        var axisByteOffsets: [Int]
        var axisUsages: [Int]
        var hatByteOffset: Int?
        var triggerByteOffsets: [Int]
        var hatBitOffset: Int?
        var reportID: Int?
    }

    /// The pads 1.5 decoded with a hand-made profile; every other raw pad
    /// went through the descriptor (1.5 ControllerProfileDatabase).
    static func readFromDescriptor(vendor: Int32, product: Int32) -> Bool {
        switch (vendor, product) {
        case (0x2DC8, 0x3000...0x31FF), (0x045E, 0x028E), (0x045E, 0x028F), (0x045E, 0x02A1),
             (0x046D, 0xC21F), (0x24C6, 0x5300...0x55FF), (0x0738, 0x4700...0x47FF), (0x054C, 0x0268):
            return false
        default:
            return true
        }
    }

    /// A 1.6 reading of the control a 1.5 input was recorded on, and
    /// whether a row reading the whole axis must be inverted to keep its
    /// direction. Nil when 1.6 has no reading of that control.
    struct Moved: Equatable {
        var input: InputEvent
        var flipsAxis: Bool
    }

    static func translate(_ e: InputEvent, old: Layout, new: HIDExtendedLayout) -> Moved? {
        guard let report = new.reports.first(where: { $0.reportID == old.reportID })
                ?? (new.reports.count == 1 ? new.reports.first : nil) else { return nil }
        var out = e
        // A slider (1.5 axes 4 and 5, buttons 6 and 7).
        func slider(_ n: Int) -> Moved? {
            guard n >= 0, n < old.triggerByteOffsets.count,
                  let axis = report.axes.first(where: { $0.bitOffset == old.triggerByteOffsets[n] * 8 }) else { return nil }
            if e.type == .button {
                guard let button = axis.digitalButton else { return nil }
                out.index = button
                return Moved(input: out, flipsAxis: false)
            }
            if axis.unipolar && axis.inverted { return nil }
            out.type = .axis
            out.index = axis.index
            if axis.unipolar {
                out.axisDirection = e.axisDirection.map { _ in .positive }
            } else if axis.inverted {
                out.axisDirection = e.axisDirection.map { $0 == .positive ? .negative : .positive }
            }
            return Moved(input: out, flipsAxis: axis.inverted && e.axisDirection == nil)
        }
        switch e.type {
        case .button:
            if (6...7).contains(e.index), e.index - 6 < old.triggerByteOffsets.count { return slider(e.index - 6) }
            guard e.index >= 0, e.index < old.buttonBitOffsets.count else { return nil }
            let bit = old.buttonBitOffsets[e.index]
            if let b = report.buttons.first(where: { $0.bitOffset == bit }) {
                out.index = b.index
                return Moved(input: out, flipsAxis: false)
            }
            if let d = report.dpadButtons.first(where: { $0.bitOffset == bit && $0.axisHalf == nil }) {
                return Moved(input: hat(d, from: e), flipsAxis: false)
            }
            return nil
        case .axis:
            if (4...5).contains(e.index), e.index - 4 < old.triggerByteOffsets.count { return slider(e.index - 4) }
            guard e.index >= 0, e.index < old.axisByteOffsets.count else { return nil }
            let bit = old.axisByteOffsets[e.index] * 8
            let usage = e.index < old.axisUsages.count ? old.axisUsages[e.index] : 0
            let oldSign = usage == 0x31 || usage == 0x34 ? -1 : 1
            // Which way the raw value moves for this row: toward the top of
            // the field, or the bottom. A whole-axis row reads both ways.
            let rawHigh = (e.axisDirection ?? .positive) == .positive ? oldSign > 0 : oldSign < 0
            if let axis = report.axes.first(where: { $0.bitOffset == bit }) {
                out.index = axis.index
                if axis.unipolar {
                    // A 0 to 1 reading has only its pressed half.
                    guard e.axisDirection != nil, rawHigh == !axis.inverted else { return nil }
                    out.axisDirection = .positive
                    return Moved(input: out, flipsAxis: false)
                }
                let newSign = axis.inverted ? -1 : 1
                if let d = e.axisDirection {
                    out.axisDirection = (rawHigh == (newSign > 0)) ? .positive : .negative
                    _ = d
                    return Moved(input: out, flipsAxis: false)
                }
                return Moved(input: out, flipsAxis: oldSign != newSign)
            }
            if e.axisDirection != nil,
               let d = report.dpadButtons.first(where: { $0.bitOffset == bit && $0.axisHalf?.positive == rawHigh }) {
                return Moved(input: hat(d, from: e), flipsAxis: false)
            }
            return nil
        case .hat:
            guard e.index == 0, let bit = old.hatBitOffset,
                  let h = report.hats.first(where: { $0.bitOffset == bit }) else { return nil }
            out.index = h.index
            return Moved(input: out, flipsAxis: false)
        default:
            return Moved(input: e, flipsAxis: false)
        }
    }

    private static func hat(_ d: HIDExtendedLayout.DpadButton, from e: InputEvent) -> InputEvent {
        var out = e
        out.type = .hat
        out.index = d.hatIndex
        out.axisDirection = nil
        switch d.direction {
        case .up: out.hatDirection = .up
        case .down: out.hatDirection = .down
        case .left: out.hatDirection = .left
        case .right: out.hatDirection = .right
        }
        return out
    }

    static func parse(_ descriptor: Data) -> Layout? {
        var state = ParseState()
        // Key nil = device without REPORT_ID items.
        var fieldsByReport: [Int?: [Field]] = [:]
        var cursorByReport: [Int?: Int] = [:]
        var currentReportID: Int? = nil

        let bytes = Array(descriptor)
        var i = 0
        while i < bytes.count {
            let prefix = bytes[i]
            i += 1

            // Long item prefix (1111 1110). Skip; format is different
            // and almost never used in gamepads. Clamp the advance to
            // bytes.count so a truncated descriptor with a malicious
            // longSize byte can't overshoot the buffer.
            if prefix == 0xFE {
                if i + 1 < bytes.count {
                    let longSize = Int(bytes[i])
                    i = min(bytes.count, i + 2 + longSize)
                } else {
                    break
                }
                continue
            }

            let dataSizeCode = prefix & 0x03
            let dataSize = dataSizeCode == 3 ? 4 : Int(dataSizeCode)
            let itemType = (prefix >> 2) & 0x03
            let itemTag = (prefix >> 4) & 0x0F

            // Read data payload (little endian)
            var rawData: UInt32 = 0
            if dataSize > 0 {
                guard i + dataSize <= bytes.count else { break }
                for b in 0..<dataSize {
                    rawData |= UInt32(bytes[i + b]) << (8 * b)
                }
                i += dataSize
            }

            // Some items (LOGICAL_MIN/MAX) carry signed values - sign
            // extend if the high bit is set. Guard `bits < 32` because
            // `UInt32.max << 32` is undefined behavior: for a full
            // 4-byte value the rawData is already 32 bits wide and the
            // bitPattern conversion handles the sign correctly without
            // extension.
            let signedData: Int = {
                guard dataSize > 0 else { return Int(rawData) }
                let bits = dataSize * 8
                if bits >= 32 {
                    return Int(Int32(bitPattern: rawData))
                }
                let signBit = UInt32(1) << (bits - 1)
                if rawData & signBit != 0 {
                    let extended = rawData | (UInt32.max << bits)
                    return Int(Int32(bitPattern: extended))
                }
                return Int(rawData)
            }()

            switch itemType {

            case 0: // Main
                switch itemTag {
                case 0x8: // INPUT
                    let dataFlag = rawData
                    let isConstant = (dataFlag & 0x01) != 0
                    let isVariable = (dataFlag & 0x02) != 0
                    let bitsPerEntry = state.reportSize

                    // Skip malformed descriptors that emit INPUT before
                    // REPORT_SIZE/REPORT_COUNT - they would overlay the
                    // previous entry at the same bit offset and produce
                    // garbage layouts. Better to bail than mis-decode.
                    // Also cap absurd values so a hostile descriptor
                    // (reportSize=0xFFFFFFFF, reportCount=0xFFFFFFFF)
                    // can't trap on integer overflow in the multiply.
                    guard state.reportSize > 0 && state.reportCount > 0,
                          state.reportSize <= 256,
                          state.reportCount <= 1024 else {
                        state.clearLocals()
                        break
                    }
                    let (mulResult, mulOverflow) = bitsPerEntry.multipliedReportingOverflow(by: state.reportCount)
                    if mulOverflow {
                        state.clearLocals()
                        break
                    }
                    let totalBits = mulResult

                    if !isConstant && isVariable {
                        // Distribute usages across the report count.
                        // If we have explicit usages they map 1:1; if
                        // we have a usage range (min/max), each entry
                        // gets a usage from the range.
                        let base = cursorByReport[currentReportID, default: 0]
                        for n in 0..<state.reportCount {
                            let usage = state.usage(forIndex: n)
                            fieldsByReport[currentReportID, default: []].append(Field(
                                bitOffset: base + n * bitsPerEntry,
                                bitSize: bitsPerEntry,
                                usagePage: state.usagePage,
                                usage: usage,
                                logicalMin: state.logicalMin,
                                logicalMax: state.logicalMax
                            ))
                        }
                    }

                    cursorByReport[currentReportID, default: 0] += totalBits
                    state.clearLocals()

                case 0x9, 0xB: // OUTPUT / FEATURE
                    // Output and feature reports occupy their own bit
                    // spaces. Advancing the INPUT cursor here shifted
                    // every later input field on devices with rumble or
                    // LED output items and inflated reportSize, so the
                    // decoder's size guard rejected every real report.
                    // (The old advance also multiplied unguarded, which
                    // a hostile descriptor could overflow.)
                    state.clearLocals()

                case 0xA: // COLLECTION
                    state.clearLocals()

                case 0xC: // END COLLECTION
                    state.clearLocals()

                default: break
                }

            case 1: // Global
                switch itemTag {
                case 0x0: state.usagePage = Int(rawData)
                case 0x1: state.logicalMin = signedData
                case 0x2: state.logicalMax = signedData
                case 0x7: state.reportSize = Int(rawData)
                case 0x8:
                    // REPORT_ID - the first byte of every report is the
                    // ID. Switch the active per-report bookkeeping; each
                    // report ID gets its own payload-relative cursor.
                    let id = Int(rawData)
                    // Fields recorded before the first REPORT_ID item
                    // (malformed but seen in the wild) belong to that
                    // first report; migrate them. Their offsets are
                    // already payload-relative so no shift is needed.
                    if currentReportID == nil {
                        if let orphans = fieldsByReport[Int?.none], !orphans.isEmpty {
                            fieldsByReport[id, default: []].append(contentsOf: orphans)
                            fieldsByReport[Int?.none] = nil
                        }
                        if let orphanCursor = cursorByReport[Int?.none] {
                            cursorByReport[id, default: 0] += orphanCursor
                            cursorByReport[Int?.none] = nil
                        }
                    }
                    currentReportID = id
                case 0x9: state.reportCount = Int(rawData)
                default: break
                }

            case 2: // Local
                switch itemTag {
                case 0x0: state.usages.append(Int(rawData))
                case 0x1: state.usageMin = Int(rawData)
                case 0x2: state.usageMax = Int(rawData)
                default: break
                }

            default: break
            }
        }

        // Build a candidate layout per input report and keep the one
        // with the richest control set, so a pad whose descriptor also
        // declares battery / sensor / vendor input reports decodes the
        // gamepad report and ignores the rest.
        var best: Layout? = nil
        var bestScore = -1
        for (key, flds) in fieldsByReport {
            guard let layout = buildLayout(from: flds,
                                           reportID: key,
                                           totalBits: cursorByReport[key] ?? 0) else { continue }
            let score = layout.buttonBitOffsets.count
                + layout.axisByteOffsets.count * 2
                + layout.triggerByteOffsets.count
                + (layout.hatByteOffset != nil ? 2 : 0)
            if score > bestScore {
                bestScore = score
                best = layout
            }
        }
        return best
    }

    // MARK: - Field aggregation

    private struct Field {
        let bitOffset: Int
        let bitSize: Int
        let usagePage: Int
        let usage: Int
        let logicalMin: Int
        let logicalMax: Int
    }

    private static func buildLayout(from fields: [Field],
                                    reportID: Int?,
                                    totalBits: Int) -> Layout? {
        var buttons: [Int] = []
        // Triples kept together so per-axis width / signedness survive
        // the sort. Earlier versions stored single width/signed values
        // and the LAST axis won, which scrambled mixed 8/16-bit pads.
        var axesAggregated: [(byte: Int, width: Int, signed: Bool, usage: Int)] = []
        var triggers: [Int] = []
        var hatBit: Int? = nil
        var hatMin: Int = 0

        for field in fields {
            switch field.usagePage {
            case 0x09: // Button
                // Buttons are 1 bit each. The bitOffset is the offset
                // of the button in the report.
                if field.bitSize == 1 {
                    buttons.append(field.bitOffset)
                }
            case 0x01: // Generic Desktop
                switch field.usage {
                case 0x30, 0x31, 0x32, 0x33, 0x34, 0x35: // X, Y, Z, Rx, Ry, Rz
                    if field.bitOffset % 8 == 0 && field.bitSize % 8 == 0 {
                        // Trust logicalMin only when the declared range is
                        // sane. Cheap encoder boards (DragonRise and kin)
                        // ship inverted or degenerate min/max; treating
                        // those as signed produced garbage axes, so they
                        // degrade to unsigned-centered instead.
                        let saneRange = field.logicalMin < field.logicalMax
                        axesAggregated.append((
                            byte: field.bitOffset / 8,
                            width: field.bitSize / 8,
                            signed: saneRange && field.logicalMin < 0,
                            usage: field.usage
                        ))
                    }
                case 0x36, 0x37: // Slider, Dial - treat as trigger
                    if field.bitOffset % 8 == 0 && field.bitSize == 8 {
                        triggers.append(field.bitOffset / 8)
                    }
                case 0x39: // Hat switch
                    // Accept 4-bit AND 8-bit hats: some pads declare the hat as
                    // a full byte (0-7/8 in the low nibble, padding above). The
                    // decoder's windowed read masks with 0x0F, so an 8-bit hat
                    // decodes correctly from the same bitOffset; rejecting it
                    // left the D-pad completely dead on those controllers.
                    if field.bitSize == 4 || field.bitSize == 8 {
                        // Keep the absolute bit offset (hats often sit in
                        // the high nibble after 12 buttons) plus the
                        // declared logical minimum: many pads use 1..8
                        // with 0 as null, and assuming 0 = North both
                        // rotated every direction 45 degrees and decoded
                        // the resting state as a held North.
                        hatBit = field.bitOffset
                        hatMin = (0...1).contains(field.logicalMin) ? field.logicalMin : 0
                    }
                default: break
                }
            default: break
            }
        }

        // Only return a layout if we have at least the basics.
        guard !buttons.isEmpty || !axesAggregated.isEmpty else { return nil }

        let sortedAxes = axesAggregated.sorted { $0.byte < $1.byte }
        _ = (totalBits, hatMin)
        return Layout(
            buttonBitOffsets: buttons.sorted(),
            axisByteOffsets: sortedAxes.map(\.byte),
            axisUsages: sortedAxes.map(\.usage),
            hatByteOffset: hatBit.map { $0 / 8 },
            triggerByteOffsets: triggers.sorted(),
            hatBitOffset: hatBit,
            reportID: reportID
        )
    }

    // MARK: - Parse state

    private struct ParseState {
        var usagePage: Int = 0
        var usages: [Int] = []
        var usageMin: Int = 0
        var usageMax: Int = 0
        var logicalMin: Int = 0
        var logicalMax: Int = 0
        var reportSize: Int = 0
        var reportCount: Int = 0

        /// Usage assigned to the nth entry in a multi-count INPUT item.
        /// HID lets you either list explicit usages (one per entry) or
        /// give a usage range; we pick whichever was set most recently.
        func usage(forIndex n: Int) -> Int {
            if !usages.isEmpty {
                return usages[min(n, usages.count - 1)]
            }
            if usageMin != 0 || usageMax != 0 {
                return usageMin + n
            }
            return 0
        }

        mutating func clearLocals() {
            usages.removeAll(keepingCapacity: true)
            usageMin = 0
            usageMax = 0
        }
    }
}
