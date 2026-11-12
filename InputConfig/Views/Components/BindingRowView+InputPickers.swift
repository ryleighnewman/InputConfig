import SwiftUI
import Combine
import UniformTypeIdentifiers

// BindingRowView, the input side: type, index, scan, zone and MIDI pickers. Split from
// BindingRowView.swift, where the type and its state live, so a Debug build type-checks it in parallel
// with the rest.

extension BindingRowView {
    // MARK: - Dropdown search

    /// The input type menu's choices, for its Search.
    var inputTypeSearchChoices: [MenuSearchChoice] {
        let sections: [(LocalizedStringResource, [InputType])] = [
            ("Controller", [.button, .axis, .hat, .stickGesture, .buttonSequence]),
            ("Touchpad", [.touchpad, .touchpadRegion, .touchpadGesture]),
            ("This Mac", TapTheMac.canOffer || binding.input.type == .chassisTap ? [.chassisTap] : []),
            ("Motion", [.motion]),
            ("Keyboard and mouse", [.extKey, .extMouse, .keySequence]),
            ("Screen", [.cursorRegion, .screenPixel, .screenText]),
            ("Voice", [.voicePhrase]),
            ("MIDI", [.midi]),
        ]
        return sections.flatMap { section, types in
            types.map { type in
                MenuSearchChoice(title: Self.inputTypeMenuName(type), path: String(localized: section)) { chooseInputType(type) }
            }
        }
    }

    /// The button menu's choices: this controller's extras, the standard
    /// names, then every index.
    private var buttonIndexSearchChoices: [MenuSearchChoice] {
        var out = extraButtons.map { extra in
            MenuSearchChoice(title: String(localized: "\(extra.label) (#\(extra.index))"),
                             path: String(localized: "This controller")) { binding.input.index = extra.index }
        }
        out += familyButtonLabels.map { entry in
            MenuSearchChoice(title: String(localized: "\(entry.label) (#\(entry.index))"),
                             path: String(localized: "Standard")) { binding.input.index = entry.index }
        }
        for group in 0..<4 {
            let path = MenuSearchChoice.path(String(localized: "All indices"),
                                             String(localized: "Buttons \(group * 32) to \(group * 32 + 31)"))
            out += ((group * 32)..<(group * 32 + 32)).map { i in
                MenuSearchChoice(title: String(localized: "Button \(i)"), path: path,
                                 keywords: buttonMenuLabel(for: i)) { binding.input.index = i }
            }
        }
        return out
    }

    private func axisChoiceTitle(_ i: Int) -> String {
        ButtonNames.axisName(i, family: presetButtonFamily).map { "\($0) (#\(i))" } ?? String(localized: "Axis #\(i)")
    }

    private func axisSearchChoices(_ pick: @escaping (Int) -> Void) -> [MenuSearchChoice] {
        (0..<16).map { i in MenuSearchChoice(title: axisChoiceTitle(i)) { pick(i) } }
    }

    private func chooseMotionChannel(_ channel: MotionChannel) {
        binding.input.motionChannel = channel
        // Measured from the grip is for tilt angles only.
        if ![.pitchAngle, .rollAngle, .yawAngle].contains(channel) { binding.fromNeutral = nil }
    }

    // MARK: - Index Picker (fixed width)

    @ViewBuilder
    var indexPicker: some View {
        switch binding.input.type {
        case .stickGesture:
            stickGesturePicker
        case .buttonSequence:
            buttonSequencePicker
        case .keySequence:
            keySequencePicker
        case .chassisTap:
            Menu {
                Button("Single tap") { binding.input.index = 1 }
                Button("Double tap") { binding.input.index = 2 }
                Button("Triple tap") { binding.input.index = 3 }
                Button("Quadruple tap") { binding.input.index = 4 }
                Button("Quintuple tap") { binding.input.index = 5 }
            } label: {
                menuChevronLabel(chassisTapLabel)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)

        case .button:
            // Three sections in priority order:
            // 1. "This Controller" - dynamically discovered extras
            //    (paddles, FN, mute, Home, touchpad) for the slot's
            //    connected controller. Lets users pick by physical
            //    name instead of guessing the index.
            // 2. "Standard" - canonical MFi labels for the well-known
            //    button indices (A/B/X/Y, LB/RB, Start/Back/Home...).
            // 3. "All Indices" - generic Button 0-63 fallback.
            SearchableMenu(choices: { buttonIndexSearchChoices }) {
                if !extraButtons.isEmpty {
                    Section("This controller") {
                        // extraButtonsSnapshot already returns the array sorted
                        // by index, so iterate it directly instead of re-sorting
                        // on every row render.
                        ForEach(extraButtons) { extra in
                            Button("\(extra.label) (#\(extra.index))") {
                                binding.input.index = extra.index
                            }
                        }
                    }
                }
                Section("Standard") {
                    ForEach(familyButtonLabels, id: \.index) { entry in
                        Button("\(entry.label) (#\(entry.index))") {
                            binding.input.index = entry.index
                        }
                    }
                }
                // Joysticks, flight sticks, and button boxes can report up
                // to 128 buttons; grouped by 32 so the menu stays short.
                Section("All indices") {
                    ForEach(0..<4, id: \.self) { group in
                        Menu("Buttons \(group * 32) to \(group * 32 + 31)") {
                            ForEach((group * 32)..<(group * 32 + 32), id: \.self) { i in
                                Button("Button \(i)") { binding.input.index = i }
                            }
                        }
                    }
                }
            } label: {
                menuLabel(buttonMenuLabel(for: binding.input.index))
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

        case .axis:
            // Named for the controller family (Left stick X, L2, Right
            // trackpad X on a Steam Controller), the number kept beside it.
            SearchableMenu(choices: { axisSearchChoices { setAxisIndex($0) } }) {
                ForEach(0..<16, id: \.self) { i in
                    Button(axisChoiceTitle(i)) {
                        setAxisIndex(i)
                    }
                }
            } label: {
                menuLabel(ButtonNames.axisName(binding.input.index, family: presetButtonFamily) ?? String(localized: "Axis #\(binding.input.index)"))
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

        case .hat:
            Picker("Hat", selection: $binding.input.index) {
                ForEach(0..<16, id: \.self) { i in
                    Text("Hat #\(i)").tag(i)
                }
                // A number from a file past the list, so the picker is not blank.
                if !(0..<16).contains(binding.input.index) {
                    Text("Hat #\(binding.input.index)").tag(binding.input.index)
                }
            }
            .labelsHidden()
            .controlSize(.small)

        case .touchpad:
            if presetButtonFamily?.isSteam == true {
                // A Steam Controller pad reads one finger; the choice is
                // which pad.
                steamPadPicker
            } else {
                // Touchpad "index" represents the finger slot (0 or 1).
                Picker("Finger", selection: touchpadFingerBinding) {
                    Text("Finger 1").tag(0)
                    Text("Finger 2").tag(1)
                }
                .labelsHidden()
                .controlSize(.small)
            }

        case .motion:
            // Pick the motion channel. Menu items use the long
            // `menuDescription` ("Gyro Z (roll rate)") so users
            // recognize the axis, but the closed-button label shows
            // the short `displayName` ("Gyro Z") so it fits the
            // fixed-width index column without overlapping the next
            // column.
            SearchableMenu(choices: {
                MotionChannel.allCases.map { channel in
                    MenuSearchChoice(title: channel.menuDescription, keywords: channel.displayName) { chooseMotionChannel(channel) }
                } + MotionSetup.allCases.map { setup in
                    MenuSearchChoice(title: setup.title, path: String(localized: "Set Up Full Gyro")) {
                        MotionSetupAction.perform?(binding.id, setup)
                    }
                }
            }) {
                ForEach(MotionChannel.allCases) { channel in
                    Button(channel.menuDescription) { chooseMotionChannel(channel) }
                }
                Divider()
                motionSetupSection
            } label: {
                menuLabel((binding.input.motionChannel ?? .gyroY).displayName)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

        case .touchpadRegion:
            // Pick from defined regions by name; the zones are drawn in this
            // group's Zones section, a click away.
            Menu {
                let regions = TouchpadService.shared.allRegions()
                if regions.isEmpty {
                    Text("This preset has no touchpad regions yet")
                    Button("Draw touchpad regions\u{2026}") { showZones(.touchpad) }
                } else if regions.contains(where: { $0.surface == 1 }) || presetButtonFamily?.isSteam == true {
                    // A Steam Controller: each trackpad's own regions; the
                    // region picked says which pad the row reads.
                    Section(String(localized: "Right trackpad")) {
                        ForEach(regions.filter { $0.surface != 1 }) { region in
                            Button {
                                binding.input.touchpadRegionID = region.id
                                binding.input.touchpadSurface = nil
                            } label: { regionMenuLabel(region) }
                        }
                    }
                    Section(String(localized: "Left trackpad")) {
                        ForEach(regions.filter { $0.surface == 1 }) { region in
                            Button {
                                binding.input.touchpadRegionID = region.id
                                binding.input.touchpadSurface = 1
                            } label: { regionMenuLabel(region) }
                        }
                    }
                    Divider()
                    Button("Edit touchpad regions\u{2026}") { showZones(binding.input.touchpadSurface == 1 ? .leftTrackpad : .touchpad) }
                } else {
                    ForEach(regions) { region in
                        Button {
                            binding.input.touchpadRegionID = region.id
                        } label: {
                            regionMenuLabel(region)
                        }
                    }
                    Divider()
                    Button("Edit touchpad regions\u{2026}") { showZones(.touchpad) }
                }
            } label: {
                regionMenuLabel(name: touchpadRegionDisplayName,
                                colorIndex: touchpadRegionColorIndex)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

        case .cursorRegion:
            // Parallel to `.touchpadRegion` but the regions are screen-space
            // zones tracked against the macOS cursor position.
            Menu {
                let regions = CursorRegionService.shared.allRegions()
                if regions.isEmpty {
                    Text("No screen regions yet")
                } else {
                    // Grouped by the display each region belongs to, so
                    // "Top left" on the built-in screen and "Top left" on
                    // the external one are never confused.
                    ForEach(Self.screenRegionSections(regions), id: \.title) { section in
                        Section(section.title) {
                            ForEach(section.regions) { region in
                                Button {
                                    binding.input.cursorRegionID = region.id
                                } label: {
                                    regionMenuLabel(region)
                                }
                            }
                        }
                    }
                }
                Divider()
                Button("Edit screen regions…") {
                    showZones(.screen)
                }
            } label: {
                regionMenuLabel(name: cursorRegionDisplayName,
                                colorIndex: cursorRegionColorIndex)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

        case .screenPixel:
            // The preset's screen color watches, then the sheet that adds
            // and edits them (ScreenPixelsView).
            Menu {
                let watches = ScreenPixelService.shared.allWatches()
                if watches.isEmpty {
                    Text("No screen colors yet")
                } else {
                    ForEach(watches) { w in
                        Button {
                            binding.input.screenPixelID = w.id
                            clearHoldIfOneShot()
                        } label: {
                            Label {
                                Text(w.shownName)
                            } icon: {
                                Image(systemName: "circle.fill")
                                    .foregroundStyle(Color(red: Double(w.red) / 255, green: Double(w.green) / 255, blue: Double(w.blue) / 255))
                            }
                        }
                    }
                }
                Divider()
                Button("Edit screen colors…") {
                    ShowScreenColorsRequest(bindingID: binding.id).post()
                }
            } label: {
                HStack(spacing: 4) {
                    if let w = screenPixelWatch {
                        Circle()
                            .fill(Color(red: Double(w.red) / 255, green: Double(w.green) / 255, blue: Double(w.blue) / 255))
                            .frame(width: 9, height: 9)
                            .overlay(Circle().stroke(Color.primary.opacity(0.35), lineWidth: 0.5))
                    }
                    menuLabel(screenPixelDisplayName)
                }
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

        case .screenText:
            // The preset's screen text watches, then the sheet (ScreenTextsView).
            Menu {
                let watches = ScreenTextService.shared.allWatches()
                if watches.isEmpty {
                    Text("No screen text yet")
                } else {
                    ForEach(watches) { w in
                        Button {
                            binding.input.screenTextID = w.id
                            clearHoldIfOneShot()
                        } label: { regionMenuLabel(name: w.shownName, colorIndex: w.colorIndex) }
                    }
                }
                Divider()
                Button("Edit screen text…") { ShowScreenTextsRequest(bindingID: binding.id).post() }
            } label: {
                regionMenuLabel(name: screenTextDisplayName, colorIndex: screenTextWatch?.colorIndex)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

        case .voicePhrase:
            // The preset's voice phrases, then the sheet (VoicePhrasesView).
            Menu {
                let phrases = VoicePhraseService.shared.allPhrases()
                if phrases.isEmpty {
                    Text("No voice phrases yet")
                } else {
                    ForEach(phrases) { p in
                        Button { binding.input.voicePhraseID = p.id } label: { regionMenuLabel(name: p.shownName, colorIndex: p.colorIndex) }
                    }
                }
                Divider()
                Button("Edit voice phrases…") { ShowVoicePhrasesRequest(bindingID: binding.id).post() }
            } label: {
                regionMenuLabel(name: voicePhraseDisplayName, colorIndex: voicePhrase?.colorIndex)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

        case .stickRegion:
            // A zone row's stick or trigger. Only the zone's own stick, or its own trigger: picking one
            // makes the row a direction row on it again.
            Menu {
                ForEach(zoneRowAxes, id: \.self) { i in
                    Button(axisChoiceTitle(i)) {
                        useWholeAxis(index: i)
                    }
                }
            } label: {
                menuLabel(zoneRowStickName)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

        case .extKey:
            // HID usage code. Most users won't remember a code by number, so
            // we surface a Scan affordance: if the user clicks "Scan" the next
            // physical key press on any detected keyboard becomes the binding.
            SearchableMenu(choices: {
                let common = String(localized: "Common keys")
                return commonHIDKeys.map { entry in
                    MenuSearchChoice(title: KeyCodeMap.name(for: entry.code), path: common,
                                     keywords: entry.label) { binding.input.index = entry.code }
                } + [MenuSearchChoice(title: String(localized: "Press any key on detected keyboard\u{2026}"),
                                      path: String(localized: "Scan")) { scanForExternalKey() }]
            }) {
                Section("Common keys") {
                    ForEach(commonHIDKeys, id: \.code) { entry in
                        Button("\(KeyCodeMap.name(for: entry.code)) (code \(entry.code))") {
                            binding.input.index = entry.code
                        }
                    }
                }
                Section("Scan") {
                    Button("Press any key on detected keyboard…") {
                        scanForExternalKey()
                    }
                }
            } label: {
                menuLabel(externalScanning ? String(localized: "Press a key\u{2026} \(externalScanLeft)")
                          : externalScanTimedOut ? String(localized: "Timed out")
                          : KeyCodeMap.name(for: binding.input.index))
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

        case .extMouse:
            // Sub-kind: button vs motion vs scroll.
            Menu {
                ForEach(ExtMouseKind.allCases) { kind in
                    Button(kind.displayName) {
                        // Block was set for the old kind; a move or scroll
                        // row cannot block, and a stale flag came back on. A
                        // button and its double click both block.
                        let old = binding.input.extMouseKind ?? .button
                        if kind != old, kind != .button, kind != .doubleClick { binding.blockOriginal = nil }
                        binding.input.extMouseKind = kind
                        // Reset the index for kinds that don't need one.
                        if kind != .button && kind != .doubleClick { binding.input.index = 0 }
                        // A move or scroll row reads one way, the "+" it
                        // shows; with none stored it fired both ways.
                        if kind != .button && kind != .doubleClick, binding.input.axisDirection == nil {
                            binding.input.axisDirection = .positive
                        }
                        // A double click or a notch is never held: no hold,
                        // turbo or Only while held is left on it unseen.
                        if kind != old {
                            clearHoldIfOneShot()
                            if MappingEngine.isNeverHeld(binding.input) { binding.macroInterruptOnRelease = nil }
                        }
                    }
                }
            } label: {
                menuLabel((binding.input.extMouseKind ?? .button).displayName)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

        case .touchpadGesture:
            // The gesture kind discriminator (two-finger tap, etc.). A
            // Steam Controller pad reads one finger, so it has no
            // two-finger tap, and the row also picks the pad.
            let steam = presetButtonFamily?.isSteam == true
            Menu {
                ForEach(TouchpadGestureKind.allCases.filter { !steam || $0 != .twoFingerTap }) { kind in
                    Button(kind.displayName) {
                        binding.input.touchpadGestureKind = kind
                    }
                }
                if steam {
                    Divider()
                    Button("Right trackpad") { binding.input.touchpadSurface = nil }
                    Button("Left trackpad") { binding.input.touchpadSurface = 1 }
                }
            } label: {
                menuLabel((steam ? (binding.input.touchpadSurface == 1 ? String(localized: "Left: ") : String(localized: "Right: ")) : "")
                          + (binding.input.touchpadGestureKind?.displayName ?? String(localized: "Two-finger tap")))
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

        case .midi:
            midiIndexPicker
        }
    }

    /// Which Steam Controller trackpad a touchpad row reads.
    private var steamPadPicker: some View {
        Picker("Pad", selection: SwiftUI.Binding(
            get: { binding.input.touchpadSurface ?? 0 },
            set: { new in
                binding.input.touchpadSurface = new == 1 ? 1 : nil
                binding.input.touchpadFinger = 0
                binding.input.index = 0
            })) {
            Text("Right pad").tag(0)
            Text("Left pad").tag(1)
        }
        .labelsHidden()
        .controlSize(.small)
        .accessibilityLabel("Trackpad")
    }

    /// The most-used HID Keyboard / Keypad usage codes for the dropdown, and
    /// the Globe key, tapped or held as fn.
    private var commonHIDKeys: [(label: String, code: Int)] {
        [
            ("A", 4), ("S", 22), ("D", 7), ("W", 26),
            ("Space", 44), ("Return", 40), ("Escape", 41), ("Tab", 43),
            ("Left", 80), ("Right", 79), ("Up", 82), ("Down", 81),
            ("Globe", KeyCodeMap.globeKeyCode), ("fn", KeyCodeMap.globeFnCode)
        ]
    }

    /// Watches `ExternalInputDeviceService.events` for one key-down then
    /// assigns it as this binding's input. Guaranteed to cancel via a
    /// scheduled timer even if no key is ever pressed - earlier versions
    /// relied on a `Date()` check inside the sink, which only ran when
    /// the subject fired, leaking the subscription forever if nothing
    /// happened. Also single-shot: re-clicking Scan cancels the previous
    /// listener via the static reference so multiple rows can't pile up.
    /// What macOS calls each mouse button number.
    static func mouseButtonName(_ index: Int) -> String {
        switch index {
        case 0: return String(localized: "Left click")
        case 1: return String(localized: "Right click")
        case 2: return String(localized: "Middle click")
        default: return String(localized: "Button \(index &+ 1)")
        }
    }

    private func scanForExternalKey() {
        scanExternal(keyboard: true) { event in
            guard case .keyDown(let dev, let code) = event else { return nil }
            // With VoiceOver on, Control and Option are its own keys: the
            // next VoiceOver command bound Control or Option to the row.
            // Caps Lock too, which VoiceOver can use as its modifier.
            if NSWorkspace.shared.isVoiceOverEnabled, [57, 224, 226, 228, 230].contains(code) { return nil }
            // fn comes first on a Globe tap too, whose own key follows the
            // release: fn alone is taken only if that key does not come.
            if code == KeyCodeMap.globeFnCode {
                DispatchQueue.main.async {
                    let at = Date()
                    Self.pendingFnAt = at
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        guard Self.pendingFnAt == at, externalScanning else { return }
                        Self.pendingFnAt = nil
                        binding.input.index = code
                        binding.input.extDeviceID = dev
                        Self.announce(String(localized: "Set to \(HotKeySpec.spokenKey(KeyCodeMap.name(for: code)))"))
                        Self.cancelActiveScan()
                    }
                }
                return nil
            }
            DispatchQueue.main.async { Self.pendingFnAt = nil }
            return (code, dev)
        }
    }
    private static var pendingFnAt: Date?

    private func scanForExternalMouseButton() {
        scanExternal(mouse: true) { event in
            if case .mouseButtonDown(let dev, let b) = event { return (b, dev) }
            return nil
        }
    }

    /// Watches `ExternalInputDeviceService.events` for the first event
    /// `pick` accepts and assigns it as this binding's input. The monitor
    /// is held open for the scan and let go when it ends, so scanning
    /// works with no preset running. Guaranteed to cancel via a scheduled
    /// timer even if nothing is ever pressed, and single-shot: a new Scan
    /// cancels the previous listener via the static reference.
    private func scanExternal(mouse: Bool = false, keyboard: Bool = false,
                              pick: @escaping (ExternalInputDeviceService.Event) -> (Int, String)?) {
        Self.cancelActiveScan()
        let svc = ExternalInputDeviceService.shared
        svc.retain("scan", mouse: mouse, keyboard: keyboard, movement: false)
        // Shown on the row's menu and spoken, since keys and clicks in this
        // window go to the scan until it ends.
        externalScanning = true
        externalScanTimedOut = false
        Self.activeScanRowID = binding.id
        Self.activeScanEnded = { externalScanning = false }
        let scanSeconds = ScanTiming.macInputSeconds
        externalScanLeft = scanSeconds
        Self.activeScanTick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            externalScanLeft = max(0, externalScanLeft - 1)
        }
        let ends = String(localized: "Scan ends in \(scanSeconds) seconds.")
        Self.announce(keyboard ? String(localized: "Press the key to use. \(ends)") : String(localized: "Press the mouse button to use. \(ends)"))
        let captured: (Int) -> Void = { index in
            Self.announce(String(localized: "Set to \(keyboard ? HotKeySpec.spokenKey(KeyCodeMap.name(for: index)) : Self.mouseButtonName(index))"))
        }
        // A press already down when Scan was clicked must not count, so
        // events in the first instant are ignored.
        let armedAt = Date().addingTimeInterval(0.15)
        let cancellable = svc.events.sink { event in
            guard Date() >= armedAt, let (index, dev) = pick(event) else { return }
            DispatchQueue.main.async {
                binding.input.index = index
                binding.input.extDeviceID = dev
                captured(index)
                // The service's tap can hear the press before the window
                // does: the window's copy must still be taken, or Escape
                // also canceled the editor and Return pressed Save.
                Self.cancelActiveScan(swallowingInFlight: true)
            }
        }
        Self.activeScanCancellable = cancellable
        // While a key scan runs, keys typed in this window are taken here
        // and kept from the editor, so Escape, Return, Space and Tab bind
        // instead of closing the sheet or pressing a button. This also
        // hears keys without the Accessibility permission, which the
        // service's monitors need.
        if keyboard {
            Self.activeScanKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { ev in
                // A row binds one key, never a Command combination, so
                // Command shortcuts keep working while a scan runs.
                if ev.modifierFlags.contains(.command) { return ev }
                if ev.type == .keyDown, !ev.isARepeat, Date() >= armedAt {
                    let hid = ExternalInputDeviceService.inputCode(forVirtualKeyCode: Int(ev.keyCode))
                    let event = ExternalInputDeviceService.Event.keyDown(
                        deviceID: ExternalInputDeviceService.builtInKeyboardID, hidCode: hid)
                    if let (index, dev) = pick(event) {
                        binding.input.index = index
                        binding.input.extDeviceID = dev
                        captured(index)
                        DispatchQueue.main.async { Self.cancelActiveScan() }
                    }
                }
                return nil
            }
        }
        // The same for a mouse button scan: a click in this window is taken
        // here, not also sent to the button under the pointer.
        if mouse {
            let types: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown,
                                                .leftMouseUp, .rightMouseUp, .otherMouseUp]
            Self.activeScanMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: types) { ev in
                guard Date() >= armedAt else { return ev }
                if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(ev.type) {
                    let button = ev.type == .leftMouseDown ? 0 : (ev.type == .rightMouseDown ? 1 : ev.buttonNumber)
                    let event = ExternalInputDeviceService.Event.mouseButtonDown(
                        deviceID: ExternalInputDeviceService.builtInMouseID, button: button)
                    if let (index, dev) = pick(event) {
                        binding.input.index = index
                        binding.input.extDeviceID = dev
                        captured(index)
                        DispatchQueue.main.async { Self.cancelActiveScan() }
                    }
                }
                return nil
            }
        }
        // A hard deadline (5 seconds unless Settings changed it). Fires on
        // the main run loop so it always runs even if no events arrive.
        Self.activeScanTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(scanSeconds), repeats: false) { _ in
            Self.announce(String(localized: "Scan timed out. Nothing was set."))
            NSSound.beep()
            Self.cancelActiveScan()
            // Seen on the row for a few seconds, not only spoken.
            externalScanTimedOut = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { externalScanTimedOut = false }
        }
    }

    /// Single global slot for the active "scan for keyboard key" listener.
    /// Static so re-clicking Scan on a different row always cancels the
    /// previous subscription instead of stacking them.
    private static var activeScanCancellable: AnyCancellable?
    private static var activeScanTimer: Timer?
    private static var activeScanTick: Timer?
    private static var activeScanKeyMonitor: Any?
    private static var activeScanMouseMonitor: Any?
    /// The row whose scan is running, so only that row's disappearance
    /// ends it.
    static var activeScanRowID: UUID?
    /// Clears the scanning row's "Press a key" label when the scan ends.
    private static var activeScanEnded: (() -> Void)?

    static func announce(_ text: String, priority: NSAccessibilityPriorityLevel = .high) {
        guard let window = NSApp?.keyWindow ?? NSApp?.mainWindow else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: priority.rawValue])
    }

    /// Cancel any in-flight external-input scan. Called from
    /// `.onDisappear` so a row that goes away mid-scan doesn't keep
    /// the static timer/subscription alive and fire its 5-second
    /// deadline writing into a now-dead `@Binding`.
    /// A short-lived local monitor that takes the press a scan just bound,
    /// when the window gets its copy after the scan has ended.
    private static var inFlightSwallower: Any?

    static func cancelActiveScan(swallowingInFlight: Bool = false) {
        if swallowingInFlight, activeScanKeyMonitor != nil || activeScanMouseMonitor != nil {
            if let old = inFlightSwallower { NSEvent.removeMonitor(old) }
            var types: NSEvent.EventTypeMask = []
            if activeScanKeyMonitor != nil { types.formUnion([.keyDown, .keyUp]) }
            if activeScanMouseMonitor != nil {
                types.formUnion([.leftMouseDown, .rightMouseDown, .otherMouseDown,
                                 .leftMouseUp, .rightMouseUp, .otherMouseUp])
            }
            let swallower = NSEvent.addLocalMonitorForEvents(matching: types) { ev in
                ev.type == .keyDown && ev.modifierFlags.contains(.command) ? ev : nil
            }
            inFlightSwallower = swallower
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                guard let swallower, let current = inFlightSwallower as AnyObject?, current === swallower as AnyObject else { return }
                NSEvent.removeMonitor(swallower)
                inFlightSwallower = nil
            }
        } else if let old = inFlightSwallower {
            // A new scan or a plain cancel: nothing is in flight to take.
            NSEvent.removeMonitor(old)
            inFlightSwallower = nil
        }
        activeScanCancellable?.cancel()
        activeScanCancellable = nil
        activeScanTimer?.invalidate()
        activeScanTimer = nil
        activeScanTick?.invalidate()
        activeScanTick = nil
        if let monitor = activeScanKeyMonitor {
            NSEvent.removeMonitor(monitor)
            activeScanKeyMonitor = nil
        }
        if let monitor = activeScanMouseMonitor {
            NSEvent.removeMonitor(monitor)
            activeScanMouseMonitor = nil
        }
        ExternalInputDeviceService.shared.release("scan")
        activeScanRowID = nil
        let ended = activeScanEnded
        activeScanEnded = nil
        ended?()
    }

    private var touchpadRegionDisplayName: String {
        if let id = binding.input.touchpadRegionID,
           let r = TouchpadService.shared.region(with: id) {
            return r.shownName
        }
        return String(localized: "Pick region")
    }

    private var cursorRegionDisplayName: String {
        if let id = binding.input.cursorRegionID,
           let r = CursorRegionService.shared.region(with: id) {
            if let d = r.display { return String(localized: "\(r.shownName) on \(d.name)") }
            return r.shownName
        }
        return String(localized: "Pick a screen region")
    }

    private var screenTextWatch: ScreenTextWatch? {
        guard let id = binding.input.screenTextID else { return nil }
        return ScreenTextService.shared.watch(with: id)
    }

    private var screenTextDisplayName: String {
        if let w = screenTextWatch {
            if let d = w.display { return String(localized: "\(w.shownName) on \(d.name)") }
            return w.shownName
        }
        return String(localized: "Pick a screen text")
    }

    private var voicePhrase: VoicePhrase? {
        guard let id = binding.input.voicePhraseID else { return nil }
        return VoicePhraseService.shared.phrase(with: id)
    }

    private var voicePhraseDisplayName: String {
        voicePhrase?.shownName ?? String(localized: "Pick a voice phrase")
    }

    private var screenPixelWatch: ScreenPixelWatch? {
        guard let id = binding.input.screenPixelID else { return nil }
        return ScreenPixelService.shared.watch(with: id)
    }

    private var screenPixelDisplayName: String {
        if let w = screenPixelWatch {
            if let d = w.display { return String(localized: "\(w.shownName) on \(d.name)") }
            return w.shownName
        }
        return String(localized: "Pick a screen color")
    }

    /// Regions that apply to every display first, then one group per
    /// display, in the order the displays are attached.
    static func screenRegionSections(_ regions: [TouchpadRegion]) -> [(title: String, regions: [TouchpadRegion])] {
        var out: [(String, [TouchpadRegion])] = []
        let any = regions.filter { $0.display == nil }
        if !any.isEmpty { out.append((String(localized: "Every display"), any)) }
        var seen: [DisplayKey] = []
        for r in regions {
            guard let d = r.display, !seen.contains(d) else { continue }
            seen.append(d)
            let attached = CursorRegionService.shared.isDisplayAttached(d)
            out.append((attached ? d.name : String(localized: "\(d.name) (not connected)"), regions.filter { $0.display == d }))
        }
        return out
    }

    /// Palette slot of the chosen region, so the row can show the same
    /// color the maps draw it in. Nil when no region is chosen yet.
    private var cursorRegionColorIndex: Int? {
        guard let id = binding.input.cursorRegionID,
              let r = CursorRegionService.shared.region(with: id) else { return nil }
        return r.colorIndex
    }

    private var touchpadRegionColorIndex: Int? {
        guard let id = binding.input.touchpadRegionID,
              let r = TouchpadService.shared.region(with: id) else { return nil }
        return r.colorIndex
    }

    /// The type column's name: a stick zone or trigger band is shown as the
    /// Axis it belongs to.
    var typeMenuTitle: String {
        binding.input.type == .stickRegion ? InputType.axis.displayName : binding.input.type.displayName
    }

    /// How this zone shares its stick with the stick's direction rows, said
    /// plainly with the rows it overlaps, and the switch to let both fire.
    @ViewBuilder
    var zoneSharingOptions: some View {
        let shares = binding.zoneSharesStick != false
        let rows = zoneOverlap.map { "#\($0)" }.joined(separator: ", ")
        VStack(alignment: .leading, spacing: 6) {
            Text(isBandRow
                 ? (zoneOverlap.isEmpty
                    ? String(localized: "No other row on this control reaches into this band.")
                    : zoneOverlap.count == 1
                    ? (shares
                       ? String(localized: "This band overlaps row \(rows). While the control is inside it, this row and that row both fire.")
                       : String(localized: "This band overlaps row \(rows). While the control is inside it, only this row fires; that row waits until the control leaves the band."))
                    : shares
                    ? String(localized: "This band overlaps rows \(rows). While the control is inside it, this row and those rows all fire.")
                    : String(localized: "This band overlaps rows \(rows). While the control is inside it, only this row fires; those rows wait until the control leaves the band."))
                 : zoneOverlap.isEmpty
                 ? String(localized: "No direction row on this stick reaches into this region.")
                 : zoneOverlap.count == 1
                 ? (shares
                    ? String(localized: "This region overlaps row \(rows). While the stick is inside it, this row and that row both fire.")
                    : String(localized: "This region overlaps row \(rows). While the stick is inside it, only this row fires; that row waits until the stick leaves the region."))
                 : shares
                 ? String(localized: "This region overlaps rows \(rows). While the stick is inside it, this row and those rows all fire.")
                 : String(localized: "This region overlaps rows \(rows). While the stick is inside it, only this row fires; those rows wait until the stick leaves the region."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !zoneZoneOverlap.isEmpty {
                let zoneRows = zoneZoneOverlap.map { "#\($0)" }.joined(separator: ", ")
                Text(zoneZoneOverlap.count == 1
                     ? String(localized: "It also overlaps the region of row \(zoneRows). Where the two meet, both rows fire.")
                     : String(localized: "It also overlaps the regions of rows \(zoneRows). Where they meet, each of those rows fires too."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let shareExplanation = isBandRow
                ? String(localized: "Off: inside the band only this row fires, the way a chord takes over its button's plain row. On: the band and the other rows both fire.")
                : String(localized: "Off: inside the region only this row fires, the way a chord takes over its button's plain row. On: the region and the direction rows both fire.")
            Toggle(isOn: SwiftUI.Binding(
                get: { binding.zoneSharesStick != false },
                set: { binding.zoneSharesStick = $0 ? nil : false })) {
                Text(isBandRow
                     ? String(localized: "Let the control's other rows fire in this band too")
                     : String(localized: "Let the stick's direction rows fire in this region too"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .help(shareExplanation)
            .accessibilityInputLabels([Text("Let rows fire"), Text("Share")])
            .accessibilityHint(shareExplanation)
        }
    }

    /// The zones a row on this axis can use instead of a direction: the
    /// plane zones of the stick the axis belongs to, and the axis's own
    /// bands, with the way to draw more.
    @ViewBuilder
    private func zoneChoices(forAxis axis: Int) -> some View {
        let svc = StickRegionService.shared
        let stick: Int? = (0...1).contains(axis) ? 0 : ((2...3).contains(axis) ? 1 : nil)
        let plane = stick.map { svc.regions(forStick: $0) } ?? []
        let bandKey = StickRegionService.bandKeyBase + axis
        let bands = svc.regions(forStick: bandKey)
        if !plane.isEmpty, let stick {
            Section(stick == 1 ? String(localized: "Right stick regions") : String(localized: "Left stick regions")) {
                ForEach(plane) { region in
                    Button { chooseZone(key: stick, region.id) } label: { regionMenuLabel(region) }
                }
            }
        }
        if !bands.isEmpty {
            Section(String(localized: "\(StickRegionService.axisDisplayName(axis)) regions")) {
                ForEach(bands) { region in
                    Button { chooseZone(key: bandKey, region.id) } label: { regionMenuLabel(region) }
                }
            }
        }
        Button(plane.isEmpty && bands.isEmpty
               ? String(localized: "Draw a region on this stick or trigger\u{2026}")
               : String(localized: "Edit regions\u{2026}")) {
            showZones(ZonePart(regionKey: zonesSheetKey))
        }
    }

    /// The zones sheet's tab for an axis: its stick, or its own bands.
    private func zonesKey(forAxis axis: Int) -> Int {
        if (0...1).contains(axis) { return 0 }
        if (2...3).contains(axis) { return 1 }
        return StickRegionService.bandKeyBase + axis
    }

    /// The axis a zone row stands for, for its zone menu: the axis it came
    /// from, or the stick's X axis, or the band's own axis.
    /// The key the zones sheet opens on: a zone row's own zone key, else
    /// the key of the row's axis.
    var zonesSheetKey: Int {
        binding.input.type == .stickRegion ? binding.input.index : zonesKey(forAxis: binding.input.index)
    }

    var zoneRowAxis: Int {
        let key = binding.input.index
        if StickRegionService.isBandKey(key) { return key - StickRegionService.bandKeyBase }
        return axisBeforeZone?.index ?? (key == 1 ? 2 : 0)
    }

    /// The axes a zone row can go back to: its stick's X and Y, or the
    /// band's own axis.
    private var zoneRowAxes: [Int] {
        let key = binding.input.index
        if StickRegionService.isBandKey(key) { return [key - StickRegionService.bandKeyBase] }
        return key == 1 ? [2, 3] : [0, 1]
    }

    private var zoneRowStickName: String {
        let key = binding.input.index
        if StickRegionService.isBandKey(key) {
            return StickRegionService.axisDisplayName(key - StickRegionService.bandKeyBase)
        }
        return key == 1 ? String(localized: "Right stick") : String(localized: "Left stick")
    }

    /// The zone's own name, for the direction column.
    private var stickRegionShortName: String {
        if let id = binding.input.stickRegionID, let lookup = StickRegionService.shared.region(with: id) {
            return lookup.region.shownName
        }
        return String(localized: "Pick a region")
    }

    /// The row fires while its stick or trigger is inside the zone.
    private func chooseZone(key: Int, _ id: UUID) {
        if binding.input.type != .stickRegion {
            // A row becoming a zone takes over its stick; Options can let it
            // share. A zone row moved to another region keeps its choice.
            binding.zoneSharesStick = false
        }
        if binding.input.type == .axis {
            axisBeforeZone = (binding.input.index, binding.input.axisDirection, binding.invertAxis)
            // Invert would turn the zone half a turn round.
            binding.invertAxis = nil
        }
        binding.input.type = .stickRegion
        Self.clearOptionsWithoutControls(&binding)
        binding.input.index = key
        binding.input.stickRegionID = id
        binding.input.axisDirection = nil
    }

    /// Back from a zone to the whole axis it was on: a stick's X axis, or
    /// the band's own axis.
    func useWholeAxis(index: Int? = nil, direction: AxisDirection? = nil) {
        let axis = index ?? zoneRowAxis
        let before = axisBeforeZone
        binding.input.type = .axis
        binding.input.stickRegionID = nil
        binding.input.index = axis
        binding.input.axisDirection = direction ?? (before?.index == axis ? before?.direction : nil) ?? .positive
        if before?.index == axis { binding.invertAxis = before?.invert }
        // Back on a trigger, a band's Invert has no toggle and the row
        // would never fire.
        if axis == 4 || axis == 5 { binding.invertAxis = nil }
        axisBeforeZone = nil
    }

    private var stickRegionColorIndex: Int? {
        guard let id = binding.input.stickRegionID,
              let found = StickRegionService.shared.region(with: id) else { return nil }
        return found.region.colorIndex
    }

    /// Canonical labels for the standard 22 MFi button slots. Surfaced
    /// in the button index picker so users see "A / Cross (#0)" instead
    /// of just "Button 0". Indices 16-21 cover DualSense Edge paddles
    /// and Function buttons. The four face buttons follow the Face button
    /// letters setting (B / Cross on the bottom for Nintendo-lettered pads).
    static var standardButtonLabels: [(index: Int, label: String)] { standardButtonLabels(for: nil) }

    /// The same, named for a controller family when one is known (the
    /// preset's, or the connected controller's): L1 on a PlayStation pad,
    /// ZL on a Switch pad, Quick Access on a 2026 Steam Controller. With
    /// none, both common names, the face buttons per Settings.
    static func standardButtonLabels(for family: FaceLetters?,
                                     model: ButtonNames.ModelNames = .none) -> [(index: Int, label: String)] {
        ButtonNames.labels(for: family, model: model)
    }

    /// The Standard list for this row's slot: its family, its model's own
    /// names, the Face button names setting.
    var familyButtonLabels: [(index: Int, label: String)] {
        // A pad read from its descriptor alone has no A or Cross: its
        // buttons are named as Scan and the Automatic rows name them.
        if let names = deviceButtonNames { return names.enumerated().map { (index: $0.offset, label: $0.element) } }
        return Self.standardButtonLabels(for: presetButtonFamily, model: buttonModelNames)
    }

    /// Closed-menu label. Prefers the connected controller's named
    /// extra (e.g. "Left Paddle") for the active index, falls back to
    /// a canonical standard label, otherwise the bare "Button N".
    func buttonMenuLabel(for index: Int) -> String {
        if let extra = extraButtons.first(where: { $0.index == index }) {
            return extra.label
        }
        if let std = familyButtonLabels.first(where: { $0.index == index }) {
            return std.label
        }
        return String(localized: "Button \(index)")
    }

    /// "Single tap" / "Double tap" / "Triple tap" for the index column.
    /// Said wherever a Tap the Mac row or the feature is shown.
    static var tapTheMacDisclaimer: String {
        String(localized: "Works only on some MacBooks: tested on M4 MacBooks; it did not work on an M1 Pro in our testing.")
    }

    private var chassisTapLabel: String {
        TapCalibrationView.gestureName(max(1, min(5, binding.input.index)))
    }

    private var stickRegionDisplayName: String {
        if let id = binding.input.stickRegionID,
           let lookup = StickRegionService.shared.region(with: id) {
            let stick = StickRegionService.isBandKey(lookup.stickIndex)
                ? StickRegionService.axisDisplayName(lookup.stickIndex - StickRegionService.bandKeyBase)
                : (lookup.stickIndex == 1 ? String(localized: "Right") : String(localized: "Left"))
            return "\(stick): \(lookup.region.shownName)"
        }
        return String(localized: "Pick stick region")
    }

    /// MIDI: the first column picks the message family and its number
    /// (note or CC). Pitch bend and aftertouch are per-channel, so they
    /// have no number and the menu collapses to just the family.
    @ViewBuilder
    private var midiIndexPicker: some View {
        SearchableMenu(choices: {
            let message = String(localized: "Message")
            var out = MIDIInputKind.allCases.map { kind in
                MenuSearchChoice(title: kind.displayName, path: message) { chooseMIDIKind(kind) }
            }
            let kind = binding.input.midiKind ?? .note
            out += Self.midiNumberChoices(for: kind).map { pair in
                MenuSearchChoice(title: pair.1, path: kind.displayName) { binding.input.index = pair.0 }
            }
            return out
        }) {
            Section("Message") {
                ForEach(MIDIInputKind.allCases) { kind in
                    Button(kind.displayName) { chooseMIDIKind(kind) }
                }
            }
            let kind = binding.input.midiKind ?? .note
            if kind.usesNumber {
                Section(kind == .note ? String(localized: "Note") : (kind == .cc ? String(localized: "Controller") : (kind == .transport ? String(localized: "Transport") : String(localized: "Program")))) {
                    // Live devices make Scan the better path, so this menu
                    // stays short: common values, not all 128.
                    ForEach(Self.midiNumberChoices(for: kind), id: \.0) { pair in
                        Button(pair.1) { binding.input.index = pair.0 }
                    }
                }
            }
        } label: {
            menuChevronLabel(midiIndexLabel)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
    }

    private func chooseMIDIKind(_ kind: MIDIInputKind) {
        // The type it already is: the number stays (CC 74 became CC 1).
        guard kind != (binding.input.midiKind ?? .note) else { return }
        binding.input.midiKind = kind
        // Reset the number to something sensible for the
        // new family so the row never shows "CC 60".
        if kind == .note { binding.input.index = 60 }
        else if kind == .cc { binding.input.index = 1 }
        else if kind == .transport { binding.input.index = 0xFA; binding.input.midiChannel = nil }
        else { binding.input.index = 0 }
        // Pressure only rises; a "-" row sent its outputs
        // nothing but 0.
        if kind == .aftertouch { binding.input.axisDirection = .positive }
        clearOptionsForOneShotMIDI()
    }

    /// A message or knob mode that is never held (Turn, Program change,
    /// Transport) drops the hold, turbo and Only while held it cannot use,
    /// as the mouse kind menu does.
    private func clearOptionsForOneShotMIDI() {
        clearHoldIfOneShot()
        if MappingEngine.isNeverHeld(binding.input) { binding.macroInterruptOnRelease = nil }
    }

    private var midiIndexLabel: String {
        let kind = binding.input.midiKind ?? .note
        switch kind {
        case .note:          return MIDIService.noteName(binding.input.index)
        case .cc:            return String(localized: "CC \(binding.input.index)")
        case .programChange: return String(localized: "Prog \(binding.input.index)")
        case .pitchBend:     return String(localized: "Pitch Bend")
        case .aftertouch:    return String(localized: "Aftertouch")
        case .transport:     return MIDIInputKind.transportName(binding.input.index)
        }
    }

    /// Menu choices per message family. Notes span a usable keyboard
    /// range; CC lists the controllers people actually bind.
    private static func midiNumberChoices(for kind: MIDIInputKind) -> [(Int, String)] {
        switch kind {
        case .note:
            return (36...84).map { ($0, MIDIService.noteName($0)) }
        case .cc:
            var out = MIDIService.commonCCs.map { ($0.number, String(localized: "CC \($0.number): \($0.name)")) }
            let common = Set(MIDIService.commonCCs.map(\.number))
            out += (0...127).filter { !common.contains($0) }.map { ($0, String(localized: "CC \($0)")) }
            return out
        case .programChange:
            return (0...127).map { ($0, String(localized: "Program \($0)")) }
        case .transport:
            return [0xFA, 0xFB, 0xFC].map { ($0, MIDIInputKind.transportName($0)) }
        case .pitchBend, .aftertouch:
            return []
        }
    }

    /// Menu titles for the MIDI device list. Two identical keyboards
    /// share a name, so repeats get a number ("Launchkey 2") to tell
    /// them apart.
    static func midiDeviceTitles(_ devices: [MIDIInputService.Device]) -> [(device: MIDIInputService.Device, title: String)] {
        var totals: [String: Int] = [:]
        for d in devices { totals[d.name, default: 0] += 1 }
        var seen: [String: Int] = [:]
        return devices.map { d in
            guard (totals[d.name] ?? 0) > 1 else { return (d, d.name) }
            seen[d.name, default: 0] += 1
            return (d, "\(d.name) \(seen[d.name] ?? 1)")
        }
    }

    /// MIDI: the second column picks the channel (or Any).
    @ViewBuilder
    private var midiChannelPicker: some View {
        SearchableMenu(choices: { midiChannelSearchChoices }) {
            // Device section first: this is where users look to confirm
            // their MIDI keyboard was detected at all.
            Section("Device") {
                Button("Any device") { binding.input.midiDeviceID = nil }
                let devices = MIDIInputService.shared.connectedDevices()
                if devices.isEmpty {
                    Text("No MIDI devices detected")
                } else {
                    ForEach(Self.midiDeviceTitles(devices), id: \.device.id) { entry in
                        Button(entry.title) { binding.input.midiDeviceID = entry.device.id }
                    }
                }
            }
            // Transport messages have no channel, so only the device applies.
            if (binding.input.midiKind ?? .note) != .transport {
                Button("Any channel") { binding.input.midiChannel = nil }
                Section("Channel") {
                    ForEach(1...16, id: \.self) { ch in
                        Button("Channel \(ch)") { binding.input.midiChannel = ch }
                    }
                }
            }
            // Knob interpretation, for CC only: Switch (the default,
            // fires past halfway), Dial (speed from center, like a stick
            // axis), or Turn (relative nudges per step of rotation).
            if (binding.input.midiKind ?? .note) == .cc {
                Section("Knob mode") {
                    ForEach(MIDICCMode.allCases) { mode in
                        Button(mode.displayName) {
                            // Store nil for the default so pre-existing
                            // bindings keep byte-identical serialization.
                            binding.input.midiCCMode = (mode == .threshold) ? nil : mode
                            clearOptionsForOneShotMIDI()
                        }
                    }
                }
                if binding.input.midiCCMode == .relative {
                    Section("Turn step") {
                        Button("Fine (2 units per nudge)")   { binding.input.midiTurnStep = 2 }
                        Button("Normal (4 units per nudge)") { binding.input.midiTurnStep = nil }
                        Button("Coarse (8 units per nudge)") { binding.input.midiTurnStep = 8 }
                        Button("Chunky (16 units per nudge)") { binding.input.midiTurnStep = 16 }
                    }
                }
            }
            // Continuous controllers can be bound as a half-axis, so
            // offer the direction alongside the channel rather than
            // adding a fourth column just for MIDI.
            if (binding.input.midiKind ?? .note).isContinuous, binding.input.midiKind != .aftertouch {
                Section("Direction") {
                    ForEach(AxisDirection.allCases) { dir in
                        Button(dir.displayName) { binding.input.axisDirection = dir }
                    }
                }
            }
        } label: {
            menuChevronLabel(midiChannelLabel)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
    }

    /// The channel menu's choices, for its Search.
    private var midiChannelSearchChoices: [MenuSearchChoice] {
        let kind = binding.input.midiKind ?? .note
        let deviceMenu = String(localized: "Device")
        var out = [MenuSearchChoice(title: String(localized: "Any device"), path: deviceMenu) { binding.input.midiDeviceID = nil }]
        out += Self.midiDeviceTitles(MIDIInputService.shared.connectedDevices()).map { entry in
            MenuSearchChoice(title: entry.title, path: deviceMenu) { binding.input.midiDeviceID = entry.device.id }
        }
        if kind != .transport {
            out.append(MenuSearchChoice(title: String(localized: "Any channel")) { binding.input.midiChannel = nil })
            // Typed: assigned to an optional below, the element was inferred
            // as Int? and the title read "Channel Optional(3)".
            out += (1...16).map { (ch: Int) in
                MenuSearchChoice(title: String(localized: "Channel \(ch)"), path: String(localized: "Channel")) { binding.input.midiChannel = ch }
            }
        }
        if kind == .cc {
            out += MIDICCMode.allCases.map { mode in
                MenuSearchChoice(title: mode.displayName, path: String(localized: "Knob mode")) {
                    binding.input.midiCCMode = (mode == .threshold) ? nil : mode
                    clearOptionsForOneShotMIDI()
                }
            }
            if binding.input.midiCCMode == .relative {
                let step = String(localized: "Turn step")
                out += [
                    MenuSearchChoice(title: String(localized: "Fine (2 units per nudge)"), path: step) { binding.input.midiTurnStep = 2 },
                    MenuSearchChoice(title: String(localized: "Normal (4 units per nudge)"), path: step) { binding.input.midiTurnStep = nil },
                    MenuSearchChoice(title: String(localized: "Coarse (8 units per nudge)"), path: step) { binding.input.midiTurnStep = 8 },
                    MenuSearchChoice(title: String(localized: "Chunky (16 units per nudge)"), path: step) { binding.input.midiTurnStep = 16 },
                ]
            }
        }
        if kind.isContinuous, binding.input.midiKind != .aftertouch {
            out += AxisDirection.allCases.map { dir in
                MenuSearchChoice(title: dir.displayName, path: String(localized: "Direction")) { binding.input.axisDirection = dir }
            }
        }
        return out
    }

    /// Channel-column label: channel (or Any), prefixed with the knob
    /// mode badge when a CC binding uses a non-default mode, so a Dial
    /// or Turn binding is recognizable without opening the menu.
    private var midiChannelLabel: String {
        if (binding.input.midiKind ?? .note) == .transport {
            guard let id = binding.input.midiDeviceID else { return String(localized: "Any device") }
            return MIDIInputService.shared.connectedDevices().first { $0.id == id }?.name ?? String(localized: "Missing device")
        }
        var ch = binding.input.midiChannel.map { String(localized: "Ch \($0)") } ?? String(localized: "Any ch")
        // A row pinned to one device says which, or that it is missing,
        // since it fires for nothing else.
        if let id = binding.input.midiDeviceID {
            let device = MIDIInputService.shared.connectedDevices().first { $0.id == id }
            ch = "\(device?.name ?? String(localized: "Missing device")), \(ch)"
        }
        // A knob or bend row's direction, so a "+" and a "-" row on the
        // same control do not look the same.
        let kind = binding.input.midiKind ?? .note
        if kind.isContinuous, kind != .aftertouch, let dir = binding.input.axisDirection {
            ch += " \(dir.displayName)"
        }
        if kind == .cc, let badge = binding.input.midiCCMode?.badge {
            return "\(badge), \(ch)"
        }
        return ch
    }

    // MARK: - Index / Direction Accessibility

    /// Spoken role name for the index picker, matching whatever the closed
    /// menu is actually choosing for the current input type. VoiceOver reads
    /// this before the value so the control never announces a bare number.
    var indexPickerAccessibilityLabel: String {
        switch binding.input.type {
        case .button: return String(localized: "Button")
        case .axis: return String(localized: "Axis")
        case .hat: return String(localized: "Hat")
        case .touchpad: return String(localized: "Finger")
        case .motion: return String(localized: "Motion channel")
        case .touchpadRegion: return String(localized: "Touchpad region")
        case .cursorRegion: return String(localized: "Screen region")
        case .screenPixel: return String(localized: "Screen color")
        case .screenText: return String(localized: "Screen text")
        case .voicePhrase: return String(localized: "Voice phrase")
        case .stickRegion: return String(localized: "Stick or axis")
        case .stickGesture: return String(localized: "Flicks")
        case .buttonSequence: return String(localized: "Presses")
        case .keySequence: return String(localized: "Keys")
        case .extKey: return String(localized: "Key")
        case .extMouse: return String(localized: "Mouse input")
        case .touchpadGesture: return String(localized: "Gesture")
        case .chassisTap: return String(localized: "Tap count")
        case .midi: return String(localized: "MIDI message")
        }
    }

    /// Current selection spoken as the index picker's value. Mirrors the
    /// closed-menu label text for each input type.
    var indexPickerAccessibilityValue: String {
        switch binding.input.type {
        case .button:
            return buttonMenuLabel(for: binding.input.index)
        case .axis:
            // As the closed menu reads: the family's name for the axis.
            return ButtonNames.axisName(binding.input.index, family: presetButtonFamily)
                ?? String(localized: "Axis \(binding.input.index)")
        case .hat:
            return String(localized: "Hat \(binding.input.index)")
        case .touchpad:
            // A Steam row names its pad, as the picker on screen does.
            if presetButtonFamily?.isSteam == true { return binding.input.touchpadSurface == 1 ? String(localized: "Left pad") : String(localized: "Right pad") }
            return (binding.input.touchpadFinger ?? binding.input.index) == 1 ? String(localized: "Finger 2") : String(localized: "Finger 1")
        case .motion:
            return (binding.input.motionChannel ?? .gyroY).displayName
        case .touchpadRegion:
            return touchpadRegionDisplayName
        case .cursorRegion:
            return cursorRegionDisplayName
        case .screenPixel:
            return screenPixelDisplayName
        case .screenText:
            return screenTextDisplayName
        case .voicePhrase:
            return voicePhraseDisplayName
        case .chassisTap:
            return chassisTapLabel
        case .stickRegion:
            return zoneRowStickName
        case .stickGesture:
            return binding.input.displayName
        case .buttonSequence:
            return sequenceLabel
        case .keySequence:
            return keySequenceLabel
        case .midi:
            return binding.input.displayName
        case .extKey:
            return HotKeySpec.spokenKey(KeyCodeMap.name(for: binding.input.index))
        case .extMouse:
            return (binding.input.extMouseKind ?? .button).displayName
        case .touchpadGesture:
            let kind = binding.input.touchpadGestureKind?.displayName ?? String(localized: "Two-finger tap")
            if presetButtonFamily?.isSteam == true {
                return (binding.input.touchpadSurface == 1 ? String(localized: "Left trackpad, ") : String(localized: "Right trackpad, ")) + kind
            }
            return kind
        }
    }

    /// Spoken role name for the direction column. Some input types host a
    /// device picker or a compound axis picker here instead of a plain
    /// direction, so the label follows what the column actually controls.
    var directionPickerAccessibilityLabel: String {
        switch binding.input.type {
        case .extKey:
            return String(localized: "Keyboard device")
        case .extMouse:
            switch binding.input.extMouseKind ?? .button {
            case .button, .doubleClick: return String(localized: "Mouse button")
            case .moveX, .moveY, .scrollX, .scrollY: return String(localized: "Direction")
            case .pressure, .deepPress, .scrollGesture: return String(localized: "Mouse input")
            case .penTiltX, .penTiltY: return String(localized: "Direction")
            case .penButton: return String(localized: "Pen button")
            case .penPressure, .penEraser, .penInRange: return String(localized: "Pen input")
            }
        case .touchpad:
            return String(localized: "Axis and direction")
        case .stickRegion:
            return String(localized: "Region")
        case .midi:
            // The column holds the channel (or, for Transport, the device).
            return (binding.input.midiKind ?? .note) == .transport ? String(localized: "Device") : String(localized: "Channel")
        default:
            return String(localized: "Direction")
        }
    }

    /// Current selection spoken as the direction column's value, matching the
    /// closed-menu label for the active input type.
    var directionPickerAccessibilityValue: String {
        switch binding.input.type {
        case .stickRegion:
            return stickRegionShortName
        case .button, .touchpadRegion, .cursorRegion, .screenPixel, .screenText, .voicePhrase, .stickGesture, .buttonSequence, .keySequence, .touchpadGesture, .chassisTap:
            return String(localized: "Not applicable")
        case .midi:
            let device = binding.input.midiDeviceID.map { id in
                MIDIInputService.shared.connectedDevices().first { $0.id == id }?.name ?? String(localized: "Missing device")
            }
            if (binding.input.midiKind ?? .note) == .transport { return device ?? String(localized: "Any device") }
            let channel = binding.input.midiChannel.map { String(localized: "Channel \($0)") } ?? String(localized: "Any channel")
            return device.map { "\($0), \(channel)" } ?? channel
        case .axis, .motion:
            if binding.input.type == .axis, binding.input.axisDirection == nil { return AxisDirection.bothSpokenName }
            return axisDirectionBinding.wrappedValue.spokenName
        case .hat:
            return hatDirectionBinding.wrappedValue.displayName
        case .touchpad:
            let axisLabel = (binding.input.touchpadAxis ?? .x).rawValue.uppercased()
            let dirLabel = (binding.input.axisDirection ?? .positive).spokenName
            return "\(axisLabel) \(dirLabel)"
        case .extKey:
            return externalDeviceLabel(kind: .keyboard)
        case .extMouse:
            switch binding.input.extMouseKind ?? .button {
            case .button, .doubleClick: return Self.mouseButtonName(binding.input.index)
            case .moveX, .moveY, .scrollX, .scrollY:
                return (binding.input.axisDirection ?? .positive).spokenName
            case .pressure, .deepPress: return String(localized: "Built-in trackpad")
            case .scrollGesture: return String(localized: "Trackpad or Magic Mouse")
            case .penTiltX, .penTiltY: return (binding.input.axisDirection ?? .positive).spokenName
            case .penButton: return String(localized: "Pen button \(binding.input.index + 1)")
            case .penPressure, .penEraser, .penInRange: return String(localized: "Pen tablet")
            }
        }
    }

    // MARK: - Direction Picker (fixed width, empty for buttons)

    @ViewBuilder
    var directionPicker: some View {
        switch binding.input.type {
        case .button, .chassisTap:
            // Empty placeholder to keep column width consistent
            Color.clear

        case .axis:
            // How the stick fires this row: one direction, or a zone drawn on
            // it. Both are here, side by side, so they read as the two ways
            // to use a stick. Lazy Menu for the same scroll-perf reason as
            // the type menus: NSPopUpButtons pre-build on row creation.
            Menu {
                Section("Direction") {
                    ForEach(AxisDirection.allCases) { dir in
                        Button(dir.displayName) { axisDirectionBinding.wrappedValue = dir }
                    }
                    // A trigger only ever moves one way.
                    if !isTriggerAxis {
                        Button(AxisDirection.bothDisplayName) { binding.input.axisDirection = nil }
                    }
                }
                zoneChoices(forAxis: binding.input.index)
            } label: {
                menuChevronLabel(binding.input.axisDirection?.displayName ?? AxisDirection.bothDisplayName)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)

        case .hat:
            Menu {
                ForEach(HatDirection.allCases) { dir in
                    Button(dir.displayName) { hatDirectionBinding.wrappedValue = dir }
                }
            } label: {
                menuChevronLabel(hatDirectionBinding.wrappedValue.displayName)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)

        case .touchpadRegion:
            // Region inputs are button-like; no direction picker needed.
            Color.clear

        case .cursorRegion:
            // Same shape as `.touchpadRegion`: button-like, no direction.
            Color.clear

        case .screenPixel:
            // Button-like too; Match or Change is the watch's own setting.
            Color.clear

        case .screenText, .voicePhrase:
            Color.clear

        case .stickGesture:
            // The stick is picked in the flicks menu.
            Color.clear

        case .buttonSequence:
            // The buttons are picked in the presses menu.
            Color.clear

        case .keySequence:
            // The keys are picked in the keys menu.
            Color.clear

        case .stickRegion:
            // A region row: said as a region ("Region: Up"), so it never
            // reads as the plain direction of the same name, with the
            // region's color beside it, which opens it in the Regions editor.
            HStack(spacing: 4) {
                if let colorIndex = stickRegionColorIndex {
                    Button {
                        showZones(ZonePart(regionKey: binding.input.index))
                    } label: {
                        regionSwatch(colorIndex)
                            .padding(3)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show this region in the Regions editor")
                    .accessibilityLabel("Show region \(stickRegionShortName)")
                    .accessibilityInputLabels([Text("Show region"), Text("Show region \(stickRegionShortName)")])
                }
                Menu {
                    Section("Direction") {
                        ForEach(AxisDirection.allCases) { dir in
                            Button(dir.displayName) { useWholeAxis(direction: dir) }
                        }
                    }
                    zoneChoices(forAxis: zoneRowAxis)
                } label: {
                    menuLabel(binding.input.stickRegionID == nil ? stickRegionShortName
                              : String(localized: "Region: \(stickRegionShortName)"))
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .accessibilityLabel(directionPickerAccessibilityLabel)
                .accessibilityValue(directionPickerAccessibilityValue)
                .accessibilityInputLabels([Text(directionPickerAccessibilityValue), Text(directionPickerAccessibilityLabel)])
            }
            // Two controls: the column's name goes on the menu, and the
            // jump button keeps its own.
            .accessibilityElement(children: .contain)

        case .motion:
            // Motion inputs read like axes: pick + or - polarity.
            Picker("Motion direction", selection: axisDirectionBinding) {
                ForEach(AxisDirection.allCases) { dir in
                    Text(dir.displayName).tag(dir)
                }
            }
            .labelsHidden()
            .controlSize(.small)

        case .touchpad:
            // For touchpad, the direction picker is a compound: X/Y axis +
            // half-axis direction. We render it as a single Menu so it fits
            // in the existing column width.
            Menu {
                Section("X (left/right)") {
                    Button("X +  (right)") { setTouchpad(axis: .x, dir: .positive) }
                    Button("X \u{2212}  (left)") { setTouchpad(axis: .x, dir: .negative) }
                }
                Section("Y (up/down)") {
                    Button("Y +  (down)") { setTouchpad(axis: .y, dir: .positive) }
                    Button("Y \u{2212}  (up)")   { setTouchpad(axis: .y, dir: .negative) }
                }
            } label: {
                let axisLabel = (binding.input.touchpadAxis ?? .x).rawValue.uppercased()
                let dirLabel = (binding.input.axisDirection ?? .positive).displayName
                menuLabel("\(axisLabel) \(dirLabel)")
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

        case .extKey:
            // Device picker: which specific keyboard, or "Any".
            externalDeviceMenu(kind: .keyboard)

        case .extMouse:
            // For mouse buttons, this column picks button index (1..8).
            // For motion / scroll, it picks the + / - half-axis direction
            // and shows the device picker via an inline Menu.
            switch binding.input.extMouseKind ?? .button {
            case .button, .doubleClick:
                // Buttons are numbered the way macOS reports them: 0 is the
                // main click, 1 the secondary, 2 the middle, then the side
                // buttons. The menu names them so nobody has to know that.
                SearchableMenu(choices: {
                    (0..<32).map { btn in
                        MenuSearchChoice(title: Self.mouseButtonName(btn),
                                         path: btn < 8 ? "" : String(localized: "More buttons")) { binding.input.index = btn }
                    } + [MenuSearchChoice(title: String(localized: "Scan: press a mouse button\u{2026}")) { scanForExternalMouseButton() }]
                }) {
                    ForEach(0..<8, id: \.self) { btn in
                        Button(Self.mouseButtonName(btn)) { binding.input.index = btn }
                    }
                    // Gaming mice with many side keys report buttons past
                    // 8; macOS numbers them up to 32.
                    Menu("More buttons") {
                        ForEach(8..<32, id: \.self) { btn in
                            Button(Self.mouseButtonName(btn)) { binding.input.index = btn }
                        }
                    }
                    Divider()
                    Button("Scan: press a mouse button…") { scanForExternalMouseButton() }
                    Divider()
                    Section("Device") { externalDeviceMenuItems(kind: .mouse) }
                } label: {
                    menuLabel(externalScanning ? String(localized: "Press a button\u{2026} \(externalScanLeft)")
                              : externalScanTimedOut ? String(localized: "Timed out")
                              : Self.mouseButtonName(binding.input.index))
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .fixedSize()
            case .moveX, .moveY, .scrollX, .scrollY:
                Menu {
                    Button("+") { binding.input.axisDirection = .positive }
                    Button("\u{2212}") { binding.input.axisDirection = .negative }
                    Divider()
                    Section("Device") { externalDeviceMenuItems(kind: .mouse) }
                } label: {
                    menuLabel((binding.input.axisDirection ?? .positive).displayName)
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .fixedSize()
            case .pressure, .deepPress:
                // Force Touch inputs are built-in-trackpad only: no button
                // index or direction to pick.
                Text("Built-in trackpad")
                    .font(.callout)
                    .foregroundStyle(.hint)
                    .fixedSize()
            case .scrollGesture:
                Text("Trackpad or Magic Mouse")
                    .font(.callout)
                    .foregroundStyle(.hint)
                    .fixedSize()
            case .penTiltX, .penTiltY:
                Menu {
                    Button("+") { binding.input.axisDirection = .positive }
                    Button("\u{2212}") { binding.input.axisDirection = .negative }
                } label: {
                    menuLabel((binding.input.axisDirection ?? .positive).displayName)
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .fixedSize()
            case .penButton:
                Menu {
                    ForEach(0..<8, id: \.self) { btn in
                        Button(String(localized: "Pen button \(btn + 1)")) { binding.input.index = btn }
                    }
                } label: {
                    menuLabel(String(localized: "Pen button \(binding.input.index + 1)"))
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .fixedSize()
            case .penPressure, .penEraser, .penInRange:
                Text("Pen tablet")
                    .font(.callout)
                    .foregroundStyle(.hint)
                    .fixedSize()
            }

        case .touchpadGesture:
            // Gesture bindings have no direction. Render an empty
            // spacer so the column width stays aligned with the rest
            // of the rows.
            Color.clear.frame(width: 0, height: 0)

        case .midi:
            // MIDI reuses this column for the channel (plus the
            // direction for continuous messages), so a note binding
            // reads "C3 / Any ch" across the two columns.
            midiChannelPicker
        }
    }

    /// Borderless menu for picking which detected external device this
    /// binding targets, including an "Any" sentinel. No `.fixedSize()`
    /// here on purpose: the parent HStack column width must clip the
    /// menu so a long device name (e.g. "Built-in Keyboard") doesn't
    /// run into the next picker.
    @ViewBuilder
    private func externalDeviceMenu(kind: ExternalInputDeviceService.Kind) -> some View {
        Menu {
            externalDeviceMenuItems(kind: kind)
        } label: {
            menuLabel(externalDeviceLabel(kind: kind))
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
    }

    /// Computes the human label for the device-picker button. Pulled out of
    /// the `Menu`'s `label:` ViewBuilder closure because mixing assignment
    /// statements with view-builder syntax doesn't compile cleanly.
    private func externalDeviceLabel(kind: ExternalInputDeviceService.Kind) -> String {
        if let id = binding.input.extDeviceID,
           let name = ExternalInputDeviceService.shared.deviceName(for: id) {
            return name
        }
        return kind.anyDevice
    }

    @ViewBuilder
    private func externalDeviceMenuItems(kind: ExternalInputDeviceService.Kind) -> some View {
        Button(kind.anyDevice) {
            binding.input.extDeviceID = nil
        }
        let matching = ExternalInputDeviceService.shared.devices.filter { $0.kind == kind }
        if matching.isEmpty {
            Text("No detected devices")
        } else {
            ForEach(matching) { device in
                Button(device.productName) {
                    binding.input.extDeviceID = device.id
                }
            }
        }
    }
}
