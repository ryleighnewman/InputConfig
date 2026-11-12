import SwiftUI
import Combine
import UniformTypeIdentifiers

// BindingRowView, gestures, sequences, system actions and the output list helpers. Split from
// BindingRowView.swift, where the type and its state live, so a Debug build type-checks it in parallel
// with the rest.

extension BindingRowView {
    // MARK: - Helpers

    /// Compact label used by Menu-style controls so they look like Pickers
    /// but with lazy contents. Shows the current value and a chevron.
    @ViewBuilder
    /// The color a region is drawn in on the maps, as a small dot. Zones
    /// are told apart by color on the touchpad and screen maps, so the
    /// picker and the row show the same dot: matching them by name alone
    /// meant reading every name to find the one you just touched.
    func regionSwatch(_ colorIndex: Int) -> some View {
        Circle()
            .fill(regionPaletteColor(at: colorIndex))
            .frame(width: 9, height: 9)
            .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 0.5))
    }

    /// One region in a picker: its color, then its name.
    // MARK: - Stick gesture

    private var gestureSteps: [GestureStep] { binding.input.gestureSteps ?? [] }

    /// The flicks as arrows ("↓ ↓"), zones by name.
    private var gestureLabel: String {
        let stick = binding.input.index == 1 ? String(localized: "Right") : String(localized: "Left")
        if gestureSteps.isEmpty { return String(localized: "\(stick): pick flicks") }
        let parts = gestureSteps.map { step -> String in
            if let d = step.direction { return d.arrow }
            if let id = step.zone, let found = StickRegionService.shared.region(with: id) { return found.region.shownName }
            return "?"
        }
        return "\(stick): " + parts.joined(separator: " ")
    }

    static let gestureDirectionOrder: [StickDirection] = [.up, .down, .left, .right, .upLeft, .upRight, .downLeft, .downRight]

    var stickGesturePicker: some View {
        Menu {
            Picker("Stick", selection: SwiftUI.Binding(
                get: { binding.input.index == 1 ? 1 : 0 },
                set: { stick in
                    if stick != (binding.input.index == 1 ? 1 : 0) {
                        binding.input.gestureSteps = gestureSteps.filter { step in
                            guard let id = step.zone else { return true }
                            return StickRegionService.shared.region(with: id)?.stickIndex == stick
                        }
                    }
                    binding.input.index = stick
                })) {
                Text("Left stick").tag(0)
                Text("Right stick").tag(1)
            }
            .pickerStyle(.inline)
            Section("Add a flick") {
                ForEach(Self.gestureDirectionOrder) { d in
                    Button("\(d.arrow)  \(d.displayName)") { appendGestureStep(GestureStep(direction: d)) }
                }
                let zones = StickRegionService.shared.regions(forStick: binding.input.index == 1 ? 1 : 0)
                if !zones.isEmpty {
                    Menu("Into a region") {
                        ForEach(zones) { zone in
                            Button { appendGestureStep(GestureStep(zone: zone.id)) } label: { regionMenuLabel(zone) }
                        }
                    }
                }
            }
            .disabled(gestureSteps.count >= GestureStep.maxSteps)
            Section {
                Button("Record a gesture\u{2026}") { showGestureRecorder = true }
                Button("Remove the last flick") { binding.input.gestureSteps = Array(gestureSteps.dropLast()) }
                    .disabled(gestureSteps.isEmpty)
                Button("Clear") { binding.input.gestureSteps = [] }
                    .disabled(gestureSteps.isEmpty)
            }
        } label: {
            menuLabel(gestureLabel)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .accessibilityLabel("Stick gesture")
        .accessibilityValue(binding.input.displayName)
        .help("The flicks that make up this gesture, in order")
        .sheet(isPresented: $showGestureRecorder) { gestureRecorderSheet }
    }

    /// The recorder, with the row's own stick, timing and Invert.
    private var gestureRecorderSheet: some View {
        StickGestureRecorder(stick: binding.input.index == 1 ? 1 : 0, slot: slot,
                             reach: binding.gestureReach ?? 0.8,
                             longestFlickMs: binding.gestureFlickMs ?? 400,
                             windowMs: binding.gestureWindowMs ?? 600,
                             inverted: binding.invertAxis == true) { steps in
            binding.input.gestureSteps = steps
        }
        .glassBackground()
    }

    private func appendGestureStep(_ step: GestureStep) {
        guard gestureSteps.count < GestureStep.maxSteps else { return }
        binding.input.gestureSteps = gestureSteps + [step]
    }

    // MARK: - Button sequence

    private var sequenceSteps: [Int] { binding.input.sequenceSteps ?? [] }

    /// The buttons by the names the row's controller prints ("Down, Down, A").
    var sequenceLabel: String {
        if sequenceSteps.isEmpty { return String(localized: "Pick the presses") }
        return sequenceSteps.map(sequenceStepName).joined(separator: ", ")
    }

    /// A button's name, or a d-pad direction's.
    private func sequenceStepName(_ code: Int) -> String {
        if let direction = ButtonSequenceRecognizer.hatDirection(forCode: code) { return direction.displayName }
        // The pad's own names, as the row's button menu shows them.
        return buttonMenuLabel(for: code)
    }

    var buttonSequencePicker: some View {
        Menu {
            Section("Add a press") {
                ForEach([HatDirection.up, .down, .left, .right]) { direction in
                    Button(direction.displayName) {
                        guard sequenceSteps.count < InputEvent.maxSequenceSteps,
                              let code = ButtonSequenceRecognizer.hatCodes[direction] else { return }
                        binding.input.sequenceSteps = sequenceSteps + [code]
                    }
                }
                Divider()
                // The buttons this pad has, by its own names: 0 to 23 listed
                // ones it lacks and named others by the family.
                ForEach(familyButtonLabels.map(\.index) + extraButtons.map(\.index).filter { e in !familyButtonLabels.contains { $0.index == e } },
                        id: \.self) { i in
                    Button(buttonMenuLabel(for: i)) {
                        guard sequenceSteps.count < InputEvent.maxSequenceSteps else { return }
                        binding.input.sequenceSteps = sequenceSteps + [i]
                    }
                }
            }
            .disabled(sequenceSteps.count >= InputEvent.maxSequenceSteps)
            Section {
                Button("Record a sequence\u{2026}") { showSequenceRecorder = true }
                Button("Remove the last press") { binding.input.sequenceSteps = Array(sequenceSteps.dropLast()) }
                    .disabled(sequenceSteps.isEmpty)
                Button("Clear") { binding.input.sequenceSteps = [] }
                    .disabled(sequenceSteps.isEmpty)
            }
        } label: {
            menuLabel(sequenceLabel)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .accessibilityLabel("Button sequence")
        .accessibilityValue(sequenceLabel)
        .help("The buttons that make up this sequence, in order")
        .sheet(isPresented: $showSequenceRecorder) {
            ButtonSequenceRecorder(windowMs: binding.gestureWindowMs ?? 600, slot: slot,
                                   buttonName: { sequenceStepName($0) }) { steps in
                binding.input.sequenceSteps = steps
            }
            .glassBackground()
        }
    }

    // MARK: - Key sequence

    /// The keys by name ("J, K").
    var keySequenceLabel: String {
        if sequenceSteps.isEmpty { return String(localized: "Pick the keys") }
        return sequenceSteps.map { KeyCodeMap.name(for: $0) }.joined(separator: ", ")
    }

    var keySequencePicker: some View {
        Menu {
            Button("Record keys\u{2026}") { showKeySequenceRecorder = true }
            Button("Remove the last key") { binding.input.sequenceSteps = Array(sequenceSteps.dropLast()) }
                .disabled(sequenceSteps.isEmpty)
            Button("Clear") { binding.input.sequenceSteps = [] }
                .disabled(sequenceSteps.isEmpty)
        } label: {
            menuLabel(keySequenceLabel)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .accessibilityLabel("Key sequence")
        .accessibilityValue(keySequenceLabel)
        .help("The keys that make up this sequence, in order")
        .sheet(isPresented: $showKeySequenceRecorder) {
            KeySequenceRecorder(windowMs: binding.gestureWindowMs ?? 600) { steps in
                binding.input.sequenceSteps = steps
            }
            .glassBackground()
        }
    }

    @ViewBuilder
    var buttonSequenceOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(binding.input.type == .keySequence
                 ? "Each key must come within the time between presses of the one before. A wrong key starts the sequence over, and the row fires like a quick press on the last key."
                 : "Each press must come within the time between presses of the one before. A wrong button starts the sequence over, and the row fires like a quick press on the last button.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text("Time between presses")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("Time between presses in milliseconds", value: SwiftUI.Binding(
                    get: { binding.gestureWindowMs ?? 600 },
                    set: { binding.gestureWindowMs = Self.clamped($0, 150...3000) }), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60 * max(1, textScale))
                    .accessibilityHint("150 to 3000 milliseconds")
                Text("ms").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    var stickGestureOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("A flick goes out past the reach and comes back to the middle. Each flick must start within the time between flicks of the last one ending.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text("Reach")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ThrottledSlider("Reach", value: SwiftUI.Binding(
                    get: { binding.gestureReach ?? 0.8 },
                    set: { binding.gestureReach = abs($0 - 0.8) < 0.005 ? nil : $0 }),
                    in: 0.3...1.0, step: 0.05)
                    .frame(minWidth: 120, maxWidth: 200)
                Text((binding.gestureReach ?? 0.8).formatted(.percent.precision(.fractionLength(0))))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 40, alignment: .leading)
            }
            HStack(spacing: 6) {
                Text("Time between flicks")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("Time between flicks in milliseconds", value: SwiftUI.Binding(
                    get: { binding.gestureWindowMs ?? 600 },
                    set: { binding.gestureWindowMs = Self.clamped($0, 150...3000) }), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60 * max(1, textScale))
                    .accessibilityHint("150 to 3000 milliseconds")
                Text("ms").font(.callout).foregroundStyle(.secondary)
            }
            Toggle(isOn: SwiftUI.Binding(
                get: { (binding.gestureFlickMs ?? 400) > 0 },
                set: { binding.gestureFlickMs = $0 ? nil : 0 })) {
                Text("Quick flicks only")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .hoverHelp("A push held out longer than this is a push, not a flick, and starts the gesture over, so steering or pointing with the stick never counts.")
            if (binding.gestureFlickMs ?? 400) > 0 {
                HStack(spacing: 6) {
                    Text("Longest flick")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    TextField("Longest flick in milliseconds", value: SwiftUI.Binding(
                        get: { binding.gestureFlickMs ?? 400 },
                        set: { binding.gestureFlickMs = Self.clamped($0, 50...3000) }), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60 * max(1, textScale))
                        .accessibilityHint("50 to 3000 milliseconds")
                    Text("ms").font(.callout).foregroundStyle(.secondary)
                }
            }
            if gestureSteps.contains(where: { $0.direction == .down }) {
                Text("One-Stick Driving shifts into reverse on two snaps back. If this preset drives with the same stick, turn that off in its driving settings or use another gesture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle(isOn: invertBinding) {
                Text("Invert direction")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .help(invertExplanation)
        }
    }

    func regionMenuLabel(_ region: TouchpadRegion) -> some View {
        HStack(spacing: 6) {
            regionSwatch(region.colorIndex)
            Text(region.shownName)
        }
    }

    /// Menu label for a chosen region: the dot sits before the name.
    func regionMenuLabel(name: String, colorIndex: Int?) -> some View {
        HStack(spacing: 4) {
            if let colorIndex { regionSwatch(colorIndex) }
            menuLabel(name)
        }
    }

    func menuLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.up.chevron.down")
                .font(.callout)
                .foregroundStyle(.secondary)
                .layoutPriority(1)
        }
    }

    /// Parameter editor for .systemAction outputs. Parameterless kinds get
    /// a one-line explainer; Run Shortcut gets a text field plus a picker
    /// of the user's installed Shortcuts; Open App / Open URL get a field.
    @ViewBuilder
    func systemActionControls(at index: Int, in list: OutputList = .main) -> some View {
        let kind = output(at: index, in: list)?.systemActionKind ?? .playPause
        switch kind {
        case .runShortcut:
            HStack(spacing: 6) {
                TextField("Shortcut name", text: outputTextBinding(at: index, in: list))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(minWidth: 140)
                SystemListChooser(list: .shortcuts) { name in updateOutput(index, in: list) { $0.text = name } }
                    .accessibilityLabel("Choose a Shortcut")
                    .hoverHelp("Pick one of your installed Shortcuts.")
            }
        case .openApp:
            HStack(spacing: 6) {
                TextField("App name or full path", text: outputTextBinding(at: index, in: list))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(minWidth: 160)
                    .hoverHelp("An app name like Safari, a bundle identifier, or a full .app path.")
                SystemListChooser(list: .apps) { name in updateOutput(index, in: list) { $0.text = name } }
                    .accessibilityLabel("Choose an app")
                    .hoverHelp("Pick one of your installed applications.")
            }
        case .openURL:
            TextField("https:// or any URL scheme", text: outputTextBinding(at: index, in: list))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(minWidth: 160)
                .hoverHelp("Opens in the default handler. Any scheme works: https, mailto, facetime, shortcuts.")
        default:
            // Never .fixedSize() horizontally: that lets a long explainer
            // force the row wider than the editor sheet, which pushes the
            // whole scroll content sideways and clips it. Truncate instead.
            Text(systemActionExplainer(kind))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                // Whole on hover, since a large Text Size cuts off the shortcut.
                .help(systemActionExplainer(kind))
        }
    }

    private func systemActionExplainer(_ kind: SystemActionKind) -> String {
        switch kind {
        case .volumeUp, .volumeDown: return String(localized: "Nudges the Mac's volume one step per press")
        case .muteToggle: return String(localized: "Toggles the Mac's output mute")
        case .playPause, .nextTrack, .previousTrack: return String(localized: "Sends the keyboard's media key")
        case .brightnessUp, .brightnessDown: return String(localized: "Nudges the built-in display's brightness")
        case .missionControl: return String(localized: "Opens Mission Control")
        case .launchpad: return String(localized: "Opens Launchpad")
        case .spotlight: return String(localized: "Presses Cmd+Space")
        case .lockScreen: return String(localized: "Locks the screen (Ctrl+Cmd+Q)")
        case .screenshotMenu: return String(localized: "Opens the screenshot toolbar (Cmd+Shift+5)")
        case .keyboardBrightnessUp, .keyboardBrightnessDown:
            return String(localized: "Nudges the keyboard backlight")
        case .startDictation:
            return String(localized: "Presses the dictation key, same as F5")
        case .speakSelection: return String(localized: "Speaks the selected text (Option+Esc)")
        case .zoomToggle: return String(localized: "Turns screen zoom on and off (Option+Cmd+8)")
        case .zoomIn: return String(localized: "Zooms the screen in (Option+Cmd+=)")
        case .zoomOut: return String(localized: "Zooms the screen out (Option+Cmd+-)")
        case .runShortcut, .openApp, .openURL: return ""
        }
    }

    /// Title for the output-type menu. System Function rows show the
    /// specific function ("Volume Up"), not the generic category.
    func outputMenuTitle(_ output: OutputAction) -> String {
        if output.type == .systemAction, let kind = output.systemActionKind {
            return kind.displayName
        }
        return output.type.displayName
    }

    func outputIcon(for action: OutputAction) -> String {
        switch action.type {
        case .key: return "keyboard"
        case .typeText: return "text.cursor"
        case .appAction: return "arrow.triangle.2.circlepath"
        case .absoluteVolume: return "speaker.wave.2.fill"
        case .systemAction: return action.systemActionKind?.iconName ?? "gearshape.fill"
        case .lightBar: return action.resolvedLightMode == .rainbowToggle ? "rainbow" : "light.beacon.max.fill"
        case .controllerProfile: return "person.crop.rectangle.stack"
        case .mouseButton, .mouseMotion, .mouseWheel, .mouseWheelStep, .mouseStep: return "computermouse"
        case .midiNote: return "music.note"
        case .midiCC: return "slider.horizontal.3"
        case .midiPitchBend: return "waveform.path"
        case .midiProgramChange: return "guitars"
        case .midiTransport: return "playpause"
        }
    }

    func outputColor(for action: OutputAction) -> Color {
        switch action.type {
        case .key, .typeText: return .orange
        case .appAction: return .teal
        case .absoluteVolume: return .teal
        case .systemAction: return .teal
        case .lightBar, .controllerProfile: return .pink
        case .mouseButton, .mouseMotion, .mouseWheel, .mouseWheelStep, .mouseStep: return .purple
        case .midiNote, .midiCC, .midiPitchBend, .midiProgramChange, .midiTransport: return .pink
        }
    }

    func mouseButtonName(_ index: Int) -> String {
        switch index {
        case 0: return String(localized: "0: Main Click")
        case 1: return String(localized: "1: Secondary")
        case 2: return String(localized: "2: Middle")
        case 3: return String(localized: "3: Back")
        case 4: return String(localized: "4: Forward")
        case 5: return String(localized: "5: Extra")
        default: return "\(index)"
        }
    }

    // MARK: - Bindings

    var axisDirectionBinding: SwiftUI.Binding<AxisDirection> {
        SwiftUI.Binding(
            get: { binding.input.axisDirection ?? .positive },
            set: { binding.input.axisDirection = $0 }
        )
    }

    var hatDirectionBinding: SwiftUI.Binding<HatDirection> {
        SwiftUI.Binding(
            get: { binding.input.hatDirection ?? .up },
            set: { binding.input.hatDirection = $0 }
        )
    }

    var firstOutputTypeBinding: SwiftUI.Binding<OutputType> {
        SwiftUI.Binding(
            get: { binding.outputs.first?.type ?? .key },
            set: {
                guard !binding.outputs.isEmpty else { return }
                binding.outputs[0].type = $0
                binding.outputs[0].fillDefaultsForType()
            }
        )
    }

    // MARK: - Output lists

    /// Which of the row's output lists an output editor works on: the main
    /// action, or the extra action sent instead on a hold or a double tap.
    /// Every output control below takes one, so an extra action gets the
    /// same editor as the main action rather than a reduced copy of it.
    enum OutputList: Int { case main, hold, doubleTap, tripleTap }

    func outputs(in list: OutputList) -> [OutputAction] {
        switch list {
        case .main: return binding.outputs
        case .hold: return binding.holdOutputs ?? []
        case .doubleTap: return binding.doubleTapOutputs ?? []
        case .tripleTap: return binding.tripleTapOutputs ?? []
        }
    }

    /// Writes a list back. nil is an extra action's off switch, so an edit
    /// that lands after its toggle was turned off (a field committing on
    /// blur, a click point taken after the countdown) leaves it off.
    func setOutputs(_ value: [OutputAction], in list: OutputList) {
        switch list {
        case .main: binding.outputs = value
        case .hold: if binding.holdOutputs != nil { binding.holdOutputs = value }
        case .doubleTap: if binding.doubleTapOutputs != nil { binding.doubleTapOutputs = value }
        case .tripleTap: if binding.tripleTapOutputs != nil { binding.tripleTapOutputs = value }
        }
    }

    /// The live speed mirror's key: the main list keeps the bare index, and
    /// each extra list its own range, so two lists never share a readout.
    func liveSpeedKey(_ index: Int, _ list: OutputList) -> Int {
        list.rawValue * 1000 + index
    }

    /// The output at `index`, or nil once it has been removed. A field that
    /// commits while its output is deleted would otherwise trap past the
    /// end, or write into the output that moved into that place.
    func output(at index: Int, in list: OutputList = .main) -> OutputAction? {
        let all = outputs(in: list)
        return all.indices.contains(index) ? all[index] : nil
    }
    /// Changes the output at `index` if it is still there.
    func updateOutput(_ index: Int, in list: OutputList = .main, _ change: (inout OutputAction) -> Void) {
        var all = outputs(in: list)
        guard all.indices.contains(index) else { return }
        change(&all[index])
        setOutputs(all, in: list)
    }

    func outputTypeBinding(at index: Int, in list: OutputList = .main) -> SwiftUI.Binding<OutputType> {
        SwiftUI.Binding(
            get: { output(at: index, in: list)?.type ?? .key },
            set: { value in
                updateOutput(index, in: list) {
                    $0.type = value
                    $0.fillDefaultsForType()
                }
            }
        )
    }

    func keyCodeBinding(at index: Int, in list: OutputList = .main) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { output(at: index, in: list)?.keyCode ?? 4 },
            set: { value in updateOutput(index, in: list) { $0.keyCode = value } }
        )
    }

    func mouseAxisDirBinding(at index: Int, in list: OutputList = .main) -> SwiftUI.Binding<String> {
        SwiftUI.Binding(
            get: {
                let axis = output(at: index, in: list)?.mouseAxis?.rawValue ?? 1
                let dir = output(at: index, in: list)?.mouseDirection?.rawValue ?? "-"
                return "\(axis) \(dir)"
            },
            set: { newValue in
                let parts = newValue.split(separator: " ")
                if parts.count >= 2,
                   let axisVal = Int(parts[0]),
                   let axis = MouseAxis(rawValue: axisVal) {
                    updateOutput(index, in: list) {
                        $0.mouseAxis = axis
                        $0.mouseDirection = MouseDirection(rawValue: String(parts[1]))
                    }
                }
            }
        )
    }

    /// The eight directions a Mouse Motion Step offers, tagged as
    /// "axis direction" plus the up or down half of a diagonal.
    @ViewBuilder var stepDirectionChoices: some View {
        Text("Up").tag("1 -")
        Text("Down").tag("1 +")
        Text("Left").tag("0 -")
        Text("Right").tag("0 +")
        Divider()
        Text("Up-Left").tag("0 - -")
        Text("Up-Right").tag("0 + -")
        Text("Down-Left").tag("0 - +")
        Text("Down-Right").tag("0 + +")
    }

    func stepDirectionBinding(get: @escaping () -> OutputAction?,
                                      set: @escaping ((inout OutputAction) -> Void) -> Void) -> SwiftUI.Binding<String> {
        SwiftUI.Binding(
            get: {
                guard let o = get() else { return "0 +" }
                let base = "\(o.resolvedMouseAxis.rawValue) \(o.resolvedMouseDirection.rawValue)"
                if o.resolvedMouseAxis == .horizontal, let v = o.stepVertical { return base + " " + v.rawValue }
                return base
            },
            set: { tag in
                let parts = tag.split(separator: " ").map(String.init)
                guard parts.count >= 2, let axis = Int(parts[0]).flatMap(MouseAxis.init(rawValue:)),
                      let dir = MouseDirection(rawValue: parts[1]) else { return }
                set { o in
                    o.mouseAxis = axis
                    o.mouseDirection = dir
                    o.stepVertical = parts.count >= 3 ? MouseDirection(rawValue: parts[2]) : nil
                }
            }
        )
    }

    func appActionNumberBinding(at index: Int, in list: OutputList = .main,
                                        range: ClosedRange<Int>, fallback: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { min(max(output(at: index, in: list)?.speed ?? fallback, range.lowerBound), range.upperBound) },
            set: { value in updateOutput(index, in: list) { $0.speed = min(max(value, range.lowerBound), range.upperBound) } }
        )
    }

    func stepDistanceBinding(at index: Int, in list: OutputList = .main) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { output(at: index, in: list)?.resolvedStepDistance ?? OutputAction.defaultStepDistance },
            set: { value in updateOutput(index, in: list) {
                $0.speed = min(max(value, OutputAction.stepDistanceRange.lowerBound), OutputAction.stepDistanceRange.upperBound)
            } }
        )
    }

    func speedBinding(at index: Int, in list: OutputList = .main) -> SwiftUI.Binding<Double> {
        SwiftUI.Binding(
            get: { Double(output(at: index, in: list)?.speed ?? 6) },
            set: { value in updateOutput(index, in: list) { $0.speed = Int(value) } }
        )
    }

    /// TextField binding that reads from the live drag mirror so the box
    /// updates while the user is sliding, and writes go to both the mirror
    /// and the underlying preset (so typing into the field still works).
    func liveSpeedBinding(at index: Int, in list: OutputList = .main) -> SwiftUI.Binding<Int> {
        let key = liveSpeedKey(index, list)
        return SwiftUI.Binding(
            get: {
                if let live = liveSpeed[key] { return Int(live) }
                return output(at: index, in: list)?.speed ?? 6
            },
            set: { newValue in
                guard output(at: index, in: list) != nil else { return }
                let clamped = max(1, min(50, newValue))
                updateOutput(index, in: list) { $0.speed = clamped }
                liveSpeed[key] = Double(clamped)
            }
        )
    }

    // MARK: - MIDI Bindings

    func midiVelocityBinding(at index: Int, in list: OutputList = .main) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { output(at: index, in: list)?.midiVelocity ?? 100 },
            set: { value in updateOutput(index, in: list) { $0.midiVelocity = max(0, min(127, value)) } }
        )
    }

    func midiChannelBinding(at index: Int, in list: OutputList = .main) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { output(at: index, in: list)?.midiChannel ?? 1 },
            set: { value in updateOutput(index, in: list) { $0.midiChannel = max(1, min(16, value)) } }
        )
    }

    func midiTransportBinding(at index: Int, in list: OutputList = .main) -> SwiftUI.Binding<MIDITransport> {
        SwiftUI.Binding(
            get: { output(at: index, in: list)?.midiTransport ?? .start },
            set: { value in updateOutput(index, in: list) { $0.midiTransport = value } }
        )
    }

    func removeOutput(at index: Int, in list: OutputList = .main) {
        var all = outputs(in: list)
        guard all.indices.contains(index) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            all.remove(at: index)
            setOutputs(all, in: list)
        }
    }
}
