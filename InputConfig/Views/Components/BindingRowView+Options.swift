import SwiftUI
import Combine
import UniformTypeIdentifiers

// BindingRowView, input type choice, tap and hold, axis, modifier, press and auto click options. Split
// from BindingRowView.swift, where the type and its state live, so a Debug build type-checks it in
// parallel with the rest.

extension BindingRowView {
    /// While a deadzone slider here is dragged, the row lights and a
    /// running preset fires by it, as with the full sheet's sliders.
    private func previewDeadzone() {
        let inner = liveDeadzone ?? Double(binding.deadzone.map(Double.init) ?? defaultDeadzone)
        let outer = liveOuterDeadzone ?? Double(binding.outerDeadzone ?? 1.0)
        MappingEngine.deadzonePreview = (binding.id, Float(inner), Float(outer))
    }

    func clearLiveMirrors() {
        // The dragged value is the row's own now (or the drag was dropped);
        // the full sheet clears its own preview when it closes.
        if !showDeadzoneCalibration, MappingEngine.deadzonePreview?.id == binding.id { MappingEngine.deadzonePreview = nil }
        if !liveSpeed.isEmpty { liveSpeed = [:] }
        if liveHaptic != nil { liveHaptic = nil }
        if liveHapticDuration != nil { liveHapticDuration = nil }
        if liveDeadzone != nil { liveDeadzone = nil }
        if liveOuterDeadzone != nil { liveOuterDeadzone = nil }
    }

    /// Selects an input type from the lazy type menu.
    /// Clears the options the row's input type has no control for, after a
    /// type change or a Scan: a stick's Invert, curve or deadzone carried
    /// to a button row could not be seen or changed there, yet the summary
    /// still listed it and Duplicate copied it on.
    static func clearOptionsWithoutControls(_ row: inout BindingModel) {
        let type = row.input.type
        // A scan onto an axis of another stick: its old region is not this one's.
        if type == .axis, let gate = row.onlyInRegion,
           let found = StickRegionService.shared.region(with: gate),
           found.stickIndex != StickRegionService.gateKey(forAxis: row.input.index) {
            row.onlyInRegion = nil
        }
        if type != .axis {
            row.onlyInRegion = nil
            row.sensitivityCurve = nil
            row.outerDeadzone = nil
            row.rampMs = nil
            row.variableSensitivity = nil
            row.fullTravel = nil
        }
        if ![.axis, .motion, .stickRegion, .touchpad, .stickGesture].contains(type) {
            row.deadzone = nil
            row.invertAxis = nil
        }
        if type != .motion { row.fromNeutral = nil }
    }

    func inputTypeChoice(_ type: InputType) -> some View {
        Button(Self.inputTypeMenuName(type)) { chooseInputType(type) }
    }

    /// An input type as its menu lists it: Hat says what a hat is, since
    /// not everyone knows the word. The row itself keeps the short name.
    static func inputTypeMenuName(_ type: InputType) -> String {
        type == .hat ? String(localized: "Hat (D-pad or thumb switch)") : type.displayName
    }

    /// Drop hold, hold threshold and turbo from a row whose input is a
    /// one-shot (MappingEngine.isOneShot). A screen text or pixel watch
    /// decides that by its mode, so the check runs once its id is set.
    func clearHoldIfOneShot() { Self.clearHoldIfOneShot(&binding) }

    static func clearHoldIfOneShot(_ row: inout BindingModel) {
        guard MappingEngine.isOneShot(row.input) else { return }
        row.holdOutputs = nil
        row.holdThresholdMs = nil
        row.turboEnabled = nil
    }

    func chooseInputType(_ type: InputType) {
        let previous = binding.input.type
        // A key scan running on this row would write a key code into the new
        // type's number.
        if type != previous, Self.activeScanRowID == binding.id { Self.cancelActiveScan() }
        binding.input.type = type
        if type != previous { Self.clearOptionsWithoutControls(&binding) }
        // A key row's keyboard is not a mouse: carried across, the row
        // waited on a device that never sends that kind and never fired.
        if type != previous, [.extKey, .extMouse].contains(previous) || [.extKey, .extMouse].contains(type) {
            binding.input.extDeviceID = nil
        }
        // A zone, key, mouse, MIDI or region row's number is not a
        // controller button: a band on L2 became "Button 104", which no
        // pad sends, and the row never fired.
        if type == .button, [.stickRegion, .extKey, .extMouse, .midi, .cursorRegion, .screenPixel, .screenText, .voicePhrase, .touchpadRegion].contains(previous) {
            binding.input.index = 0
            binding.input.stickRegionID = nil
            binding.input.cursorRegionID = nil
            binding.input.screenPixelID = nil
            binding.input.screenTextID = nil
            binding.input.voicePhraseID = nil
        }
        // The old index means something else in the new type: a tap row
        // made from Button 0 listened for zero taps, a touchpad row read
        // button 3 as its finger, and a hat past 15 had no picker entry.
        if type == .chassisTap, previous != .chassisTap { binding.input.index = 1 }
        // The other way too: a tap count is not a button number.
        if type == .button, previous == .chassisTap { binding.input.index = 0 }
        if type == .axis, previous == .stickRegion { useWholeAxis() }
        if type == .axis, previous == .stickGesture { binding.input.index = binding.input.index == 1 ? 2 : 0 }
        // A note number, key code or mouse button is not an axis.
        if type == .axis, [.midi, .extKey, .extMouse].contains(previous) { binding.input.index = 0 }
        // A key or mouse row starts where a new one does: the old number
        // was a controller button, a note or a tap count, not a key code.
        if type == .extKey, previous != .extKey { binding.input.index = 0 }
        if type == .extMouse, previous != .extMouse {
            binding.input.index = 0
            binding.input.extMouseKind = .button
        }
        // A control that is never held (MappingEngine.isOneShot) has no
        // hold or repeat: an Options setting carried over could not be
        // seen there, and a held action never fired.
        if type != previous { clearHoldIfOneShot() }
        if type != previous { binding.forgetInputBoundOptions() }
        // Variable and Ramp-up are shown on stick rows only; an Off
        // carried to a touchpad row could not be turned back on.
        if type == .touchpad, previous == .axis {
            binding.variableSensitivity = nil
            binding.rampMs = nil
        }
        if type == .touchpad, binding.input.touchpadFinger == nil {
            // A Steam pad reports one finger only.
            let steam = presetButtonFamily?.isSteam == true
            binding.input.touchpadFinger = !steam && (0...1).contains(binding.input.index) ? binding.input.index : 0
            if steam { binding.input.index = 0 }
        }
        if type == .hat, !(0...15).contains(binding.input.index) { binding.input.index = 0 }
        // A gesture is on a stick: a right stick axis row becomes a right
        // stick gesture, anything else the left stick.
        if type == .stickGesture, previous != .stickGesture {
            binding.input.index = previous == .axis && (2...3).contains(binding.input.index) ? 1
                : (previous == .stickRegion && binding.input.index == 1 ? 1 : 0)
            if binding.input.gestureSteps == nil { binding.input.gestureSteps = [] }
        }
        // A sequence starts with the button the row read, when it read one.
        // The other sequence type's codes mean something else here.
        // Leaving a sequence for another type: its steps are key codes or
        // button numbers, and kept they came back as the other kind's.
        if type != previous, [.buttonSequence, .keySequence].contains(previous),
           ![.buttonSequence, .keySequence].contains(type) {
            binding.input.sequenceSteps = nil
        }
        if type == .buttonSequence, previous != .buttonSequence {
            if binding.input.sequenceSteps == nil || previous == .keySequence {
                binding.input.sequenceSteps = previous == .button ? [binding.input.index] : []
            }
            binding.input.index = 0
        }
        if type == .keySequence, previous != .keySequence {
            if binding.input.sequenceSteps == nil || previous == .buttonSequence {
                binding.input.sequenceSteps = previous == .extKey ? [binding.input.index] : []
            }
            binding.input.index = 0
        }
        // Seed defaults when switching INTO MIDI so the row doesn't
        // inherit the previous type's index (button 0 would show as
        // note C-2) and so the message family is never nil.
        // A MIDI row has no Second control box, so a chord left from
        // another row could never be seen or removed; a key or mouse row
        // has one and keeps its chord.
        if type == .midi, !binding.modifiers.isEmpty {
            binding.setModifiers([])
        }
        if type == .extMouse, binding.input.axisDirection == nil {
            binding.input.axisDirection = .positive
        }
        if type == .midi {
            // No Invert or Deadzone controls on a MIDI row: an earlier
            // stick's would stay on, unseen.
            if previous != .midi {
                binding.invertAxis = nil
                binding.deadzone = nil
                binding.outerDeadzone = nil
                binding.sensitivityCurve = nil
                binding.variableSensitivity = nil
                binding.rampMs = nil
            }
            if binding.input.midiKind == nil {
                binding.input.midiKind = .note
                binding.input.index = 60          // middle C
            }
            if binding.input.axisDirection == nil {
                binding.input.axisDirection = .positive
            }
        }
        // Axis and Hat need the same treatment. Only Scan used to produce a
        // directed event, so a row switched to Axis by hand kept
        // axisDirection == nil, which the engine reads as "either
        // direction" while the picker renders "+". A Hat row left with
        // hatDirection == nil matched nothing at all and silently never
        // fired, even though the UI showed "Hat 0 Up".
        if type == .axis, binding.input.axisDirection == nil {
            binding.input.axisDirection = .positive
        }
        if type == .hat, binding.input.hatDirection == nil {
            binding.input.hatDirection = .up
        }
        // Motion and Touchpad rows show a default channel or axis but
        // the engine needs the real value, so a row switched by hand
        // read "Gyro Y +" or "X +" and never fired.
        if type == .motion {
            if binding.input.motionChannel == nil { binding.input.motionChannel = .gyroY }
            if binding.input.axisDirection == nil { binding.input.axisDirection = .positive }
        }
        if type == .touchpad {
            if binding.input.touchpadAxis == nil { binding.input.touchpadAxis = .x }
            if binding.input.axisDirection == nil { binding.input.axisDirection = .positive }
        }
        if type == .touchpadGesture, binding.input.touchpadGestureKind == nil {
            // A Steam pad reports one finger, so it cannot make a two-finger tap.
            binding.input.touchpadGestureKind = presetButtonFamily?.isSteam == true ? .oneFingerTap : .twoFingerTap
        }
    }

    /// Shared label style for the lazy menus, matching KeyCodePicker.
    func menuChevronLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// The stick (0, 1) or band key (100 plus the axis) whose regions a
    /// direction row on this axis can wait for.
    var gateRegionKey: Int? {
        StickRegionService.gateKey(forAxis: binding.input.index)
    }

    /// A new axis on another stick or band drops the region the row waited
    /// in: it belongs to the old stick.
    func setAxisIndex(_ i: Int) {
        if StickRegionService.gateKey(forAxis: i) != StickRegionService.gateKey(forAxis: binding.input.index) {
            binding.onlyInRegion = nil
        }
        // A trigger has no Invert toggle: carried over, a + row never fired.
        // It reads 0 to 1, so a minus row (stick up) moved onto it never
        // fired either.
        if i == 4 || i == 5 {
            binding.invertAxis = nil
            if binding.input.axisDirection == .negative { binding.input.axisDirection = .positive }
        }
        binding.input.index = i
    }

    /// Anywhere, or only while the stick is inside one region.
    @ViewBuilder
    var regionGatePicker: some View {
        let key = gateRegionKey ?? 0
        let regions = StickRegionService.shared.regions(forStick: key)
        let chosen = binding.onlyInRegion.flatMap { id in regions.first { $0.id == id } }
        HStack(spacing: 8) {
            Menu {
                Button(String(localized: "Anywhere")) { binding.onlyInRegion = nil }
                if !regions.isEmpty { Divider() }
                ForEach(regions) { region in
                    Button { binding.onlyInRegion = region.id } label: { regionMenuLabel(region) }
                }
                Divider()
                Button("Draw a region on this stick or trigger\u{2026}") { showZones(ZonePart(regionKey: key)) }
            } label: {
                Text(chosen?.shownName ?? String(localized: "Anywhere"))
                    .font(.callout)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel("Region")
            .accessibilityValue(chosen?.shownName ?? String(localized: "Anywhere"))
            .accessibilityInputLabels([Text("Region"), Text(chosen?.shownName ?? String(localized: "Anywhere"))])
            Spacer(minLength: 0)
        }
        Text(chosen == nil
             ? String(localized: "Fires anywhere past the deadzone, or only inside a region you pick.")
             : String(localized: "Fires only while the stick is inside \(chosen?.shownName ?? "")."))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Shows one part's zones in this row's group, in the editor itself.
    func showZones(_ part: ZonePart) {
        ShowZonesRequest(bindingID: binding.id, part: part).post()
    }

    /// Opens Options on the Extra actions group, for the row menu's
    /// shortcuts that just turned one of them on.
    func openExtraActions() {
        spotlight("extra")
    }

    /// The extra actions, each an if-then: when the control is held, or
    /// double tapped, do something else. While a toggle is on, the full
    /// output editor the main action uses opens under it, over the hold or
    /// double-tap list, so the extra action can be any output, or several.
    /// Turning a toggle off removes that action. Disabled while a macro
    /// owns the binding, since the engine gives macros precedence.
    @ViewBuilder
    var tapHoldOptions: some View {
        let macroOwned = binding.macroSteps?.isEmpty == false
        let tapsLocked = macroOwned || pressMode == .toggle || pressMode == .turbo || pressMode == .autoClick
        // Two groups, each a caption, its switches, and the details of a
        // switch indented under it: what a hold does, then what taps do.
        VStack(alignment: .leading, spacing: 6) {
            Text("While held")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Toggle(isOn: holdEnabledBinding) {
                Text("When held, do something else")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.regular)
            .disabled(macroOwned || (neverHeld && binding.holdOutputs == nil))
            .help(isSequenceLike
                  ? (isPressSequence ? String(localized: "A sequence is not held, so it has no held action.")
                     : String(localized: "A gesture is not held, so it has no held action."))
                  : neverHeld
                  ? String(localized: "This control is not held, so it has no held action.")
                  : String(localized: "A quick tap sends the row's normal output. Holding past the time set here sends this action instead, held until you let go."))

            if binding.holdOutputs != nil {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("Holding past")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        TextField("Hold threshold in milliseconds", value: holdThresholdBinding, format: .number)
                            .accessibilityHint("50 to 5000 milliseconds")
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 56 * max(1, textScale))
                            .controlSize(.regular)
                            .multilineTextAlignment(.center)
                        Text("ms sends")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    extraOutputEditor(.hold)
                }
                .padding(.leading, 22)
                .disabled(macroOwned)
            }
        }

        Divider()
            .padding(.vertical, 2)

        VStack(alignment: .leading, spacing: 6) {
            Text("Taps")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Toggle(isOn: doubleTapEnabledBinding) {
                Text("When double tapped, do something else")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.regular)
            // The engine reads a double tap only on a plain or hold row, not
            // while the row toggles, repeats, or auto-clicks.
            .disabled(tapsLocked)
            .hoverHelp("Two quick taps send this action instead of the row's normal output. A single tap waits out the time set here before it sends.")

            if binding.doubleTapOutputs != nil {
                extraOutputEditor(.doubleTap)
                    .padding(.leading, 22)
                    .disabled(macroOwned)
            }

            Toggle(isOn: tripleTapEnabledBinding) {
                Text("When triple tapped, do something else")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.regular)
            .disabled(tapsLocked)
            .hoverHelp("Three quick taps send this action instead of the row's normal output. One or two taps wait out the time set here before they send.")

            if binding.tripleTapOutputs != nil {
                extraOutputEditor(.tripleTap)
                    .padding(.leading, 22)
                    .disabled(macroOwned)
            }

            // The window both tap actions count in: each tap inside it of
            // the one before adds to the chain.
            if binding.doubleTapOutputs != nil || binding.tripleTapOutputs != nil {
                HStack(spacing: 8) {
                    Text("Taps count together within")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    TextField("Tap window in milliseconds", value: doubleTapWindowBinding, format: .number)
                        .accessibilityHint("100 to 2000 milliseconds")
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 56 * max(1, textScale))
                        .controlSize(.regular)
                        .multilineTextAlignment(.center)
                    Text("ms")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 22)
                .padding(.top, 2)
                .disabled(macroOwned)
            }
        }
    }

    /// An extra action's outputs, edited with the main action's own output
    /// lines (see secondaryOutputRow), and an Add button in place of the
    /// plus at the end of the main row.
    private func extraOutputEditor(_ list: OutputList) -> some View {
        let items = outputs(in: list)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, output in
                secondaryOutputRow(index: index, output: output, in: list)
            }
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    setOutputs(outputs(in: list) + [OutputAction(type: .key, keyCode: 4)], in: list)
                }
            } label: {
                Label(items.isEmpty ? String(localized: "Add an output") : String(localized: "Add another output"), systemImage: "plus.circle")
                    .font(.callout)
            }
            .buttonStyle(.solidSecondaryCompact)
            .accessibilityLabel(extraListAddLabel(list))
            .accessibilityInputLabels([Text(items.isEmpty ? String(localized: "Add an output") : String(localized: "Add another output")),
                                       Text(extraListAddLabel(list))])
        }
    }

    private func extraListAddLabel(_ list: OutputList) -> String {
        switch list {
        case .hold: return String(localized: "Add an output to the hold action")
        case .tripleTap: return String(localized: "Add an output to the triple tap action")
        default: return String(localized: "Add an output to the double tap action")
        }
    }

    private var holdEnabledBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { binding.holdOutputs != nil },
            set: { on in
                if on {
                    // The same as picking "Different action when held" under
                    // How it fires: hold is one of the press modes, so toggle
                    // and repeat step aside.
                    pressModeBinding.wrappedValue = .hold
                } else {
                    binding.holdOutputs = nil
                    binding.holdThresholdMs = nil
                }
            }
        )
    }

    /// A typed number kept in range, saying so when it was moved: the field
    /// redrew silently and the person believed their value was set.
    static func clamped(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        let kept = min(range.upperBound, max(range.lowerBound, value))
        if kept != value {
            AccessibilityNotification.Announcement(String(localized: "Set to \(kept). The allowed range is \(range.lowerBound) to \(range.upperBound).")).post()
        }
        return kept
    }

    private var holdThresholdBinding: SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.holdThresholdMs ?? 300 },
            set: { binding.holdThresholdMs = Self.clamped($0, 50...5000) }
        )
    }

    private var doubleTapEnabledBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { binding.doubleTapOutputs != nil },
            set: { on in
                if on {
                    binding.doubleTapOutputs = [OutputAction(type: .key, keyCode: 4)]
                } else {
                    binding.doubleTapOutputs = nil
                    if binding.tripleTapOutputs == nil { binding.doubleTapWindowMs = nil }
                }
            }
        )
    }

    private var tripleTapEnabledBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { binding.tripleTapOutputs != nil },
            set: { on in
                if on {
                    binding.tripleTapOutputs = [OutputAction(type: .key, keyCode: 4)]
                    if binding.doubleTapWindowMs == nil { binding.doubleTapWindowMs = 300 }
                } else {
                    binding.tripleTapOutputs = nil
                    if binding.doubleTapOutputs == nil { binding.doubleTapWindowMs = nil }
                }
            }
        )
    }

    private var doubleTapWindowBinding: SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.doubleTapWindowMs ?? 300 },
            set: { binding.doubleTapWindowMs = Self.clamped($0, 100...2000) }
        )
    }

    /// Arrow between the input and output columns. While the row is firing
    /// it tints green and moves toward the output side, then settles back
    /// when the input releases.
    var firingArrow: some View {
        Image(systemName: "arrow.forward")
            .font(.callout)
            .foregroundStyle(isHighlighted ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary))
            // Static when Reduce Motion is on; the green tint alone signals firing.
            .offset(x: reduceMotion ? 0 : (arrowShoot ? 5 : -5))
            // One nudge toward the output while firing, not a loop: a
            // repeating animation redrew the whole editor at the display's
            // rate for as long as any row stayed lit (a resting stick past
            // its deadzone, a held touch sensor), which cost every frame of
            // scrolling.
            .animation(reduceMotion ? nil : (arrowShoot ? .easeOut(duration: 0.18) : .easeOut(duration: 0.15)),
                       value: arrowShoot)
            .frame(width: arrowWidth)
            .accessibilityHidden(true)
            .onChange(of: isHighlighted) { _, firing in
                arrowShoot = reduceMotion ? false : firing
            }
    }


    /// What the engine uses when the row sets no deadzone: 0.05 for a
    /// motion row that moves the pointer (it smooths below that), 0.25 for
    /// everything else. The slider showed 25% on gyro pointer rows, and
    /// lowering it made slow tilts more damped, not less.
    var defaultDeadzone: Double {
        binding.input.type == .motion && MappingEngine.drivesPointer(binding) ? 0.05 : 0.25
    }

    /// A zone on one axis's travel rather than on a stick's plane.
    var isBandRow: Bool {
        binding.input.type == .stickRegion && StickRegionService.isBandKey(binding.input.index)
    }

    @ViewBuilder
    var advancedAxisOptions: some View {
        // Deadzone: the setting people come to Options for, so it leads, is
        // labeled in full strength, and says in one line what it does.
        // Not on touchpad rows, nor on a band, which is its own threshold:
        // the engine never reads it there.
        if binding.input.type != .touchpad && !isBandRow {
        HStack(spacing: 4) {
            Text("Deadzone")
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
            ThrottledSlider("Deadzone",
                value: deadzoneBinding,
                in: 0.01...0.9,
                step: 0.01,
                onLiveChange: { liveDeadzone = $0; previewDeadzone() }
            )
                .frame(minWidth: 140, maxWidth: 220)
                .accessibilityValue(String(localized: "\(Int(((liveDeadzone ?? Double(binding.deadzone.map(Double.init) ?? defaultDeadzone)) * 100).rounded())) percent"))
            // The percent can be typed as well as dragged to, for Voice
            // Control and anyone who cannot land a slider within 1%.
            percentField("Deadzone percent",
                         shown: liveDeadzone ?? Double(binding.deadzone.map(Double.init) ?? defaultDeadzone),
                         range: 0.01...0.9, style: .secondary, width: 34) {
                liveDeadzone = $0
                deadzoneBinding.wrappedValue = $0
            }
        }
        }
        if binding.input.type == .axis {
            Text(isTriggerAxis
                 ? String(localized: "How far the trigger is pulled before this row reacts. Raise it if the row fires when a finger just rests on the trigger.")
                 : String(localized: "How far the stick moves before this row reacts. Raise it if the pointer or camera drifts when you let go; lower it if small pushes do nothing."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // The other side of a zone's takeover, said on the row it stops.
            if !zoneTakenBy.isEmpty {
                let rows = zoneTakenBy.map { "#\($0)" }.joined(separator: ", ")
                Text(zoneTakenBy.count == 1
                     ? String(localized: "Inside the region of row \(rows), this row waits while that row fires.")
                     : String(localized: "Inside the regions of rows \(rows), this row waits while those rows fire."))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        // Full push: the engine treats anything past this as all the way, so
        // a stick that no longer reaches its corners still gives full speed.
        if binding.input.type == .axis {
            HStack(spacing: 4) {
                Text("Full push at")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ThrottledSlider("Full push at",
                    value: outerDeadzoneBinding,
                    in: 0.2...1.0,
                    step: 0.01,
                    onLiveChange: { liveOuterDeadzone = $0; previewDeadzone() }
                )
                    .frame(minWidth: 140, maxWidth: 220)
                    .accessibilityValue(String(localized: "\(Int(((liveOuterDeadzone ?? Double(binding.outerDeadzone ?? 1.0)) * 100).rounded())) percent"))
                percentField("Full push percent",
                             shown: liveOuterDeadzone ?? Double(binding.outerDeadzone ?? 1.0),
                             range: 0.2...1.0, style: .hint, width: 30) {
                    liveOuterDeadzone = $0
                    outerDeadzoneBinding.wrappedValue = $0
                }
            }
            .hoverHelp("How far the control has to move to count as fully pushed. Past it the row keeps working, at full strength. Lower it for a worn stick or a short-throw trigger.")
        }

        pressRowToggles

        // Invert: the engine negates the axis before the row's + / - filter,
        // so this row answers to the opposite movement. A trigger only ever
        // moves one way, so there is nothing to invert on one.
        if !isTriggerAxis {
            Toggle(isOn: invertBinding) {
                Text("Invert direction")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .help(invertExplanation)
        }

        // Every motion row offers the ready-made sets of rows, for someone
        // who does not know which channel does what.
        if binding.input.type == .motion {
            Menu {
                ForEach(MotionSetup.allCases) { setup in
                    Button(setup.title) { MotionSetupAction.perform?(binding.id, setup) }
                }
            } label: {
                Label("Set Up Full Gyro", systemImage: "gyroscope")
                    .font(.callout)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()
            .help("Adds the rows a full motion setup needs to this device: gyro aim for the pointer, tilt to move with the arrow keys, or one row per shake and jab. Rows the device already has are skipped.")
        }

        // Tilt angle rows: level can be the grip instead of lying flat.
        if binding.input.type == .motion,
           [.pitchAngle, .rollAngle, .yawAngle].contains(binding.input.motionChannel ?? .gyroY) {
            Toggle(isOn: SwiftUI.Binding(
                get: { binding.fromNeutral == true },
                set: { binding.fromNeutral = $0 ? true : nil }
            )) {
                Text("Level is how you hold it")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .help("Measure the lean from where the controller is held, instead of from lying flat, so a normal grip reads as level. Level is taken when the preset starts, at a re-zero, and whenever motion comes back on after Pause Motion, Motion Only While Held or Motion On / Off.")
        }

        // A pedal, throttle or lever that rests at one end: the row reads
        // its whole travel. Not on the trigger slots, which already do.
        if binding.input.type == .axis, !isTriggerAxis, binding.input.axisDirection != .none,
           !axisAlreadyOneWay || binding.fullTravel == true {
            Toggle(isOn: SwiftUI.Binding(
                get: { binding.fullTravel == true },
                set: { binding.fullTravel = $0 ? true : nil }
            )) {
                Text("Rests at one end (pedal or throttle)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .help("For a pedal, throttle or lever that rests at one end: the row reads its whole travel, nothing at rest and full at the far end. Scan turns this on when the control was resting at an end.")
        }

        // Curve and Variable apply only on the engine's axis paths.
        if binding.input.type == .axis {
            // Curve
            HStack(spacing: 4) {
                Text("Curve")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Picker("Curve", selection: curveBinding) {
                    Text("Linear").tag(SensitivityCurve.linear)
                    Text("Smooth").tag(SensitivityCurve.exponential)
                    Text("Aggressive").tag(SensitivityCurve.aggressive)
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 80 * max(1, textScale))
            }
            .hoverHelp("How speed grows as you push: Linear is even, Smooth stays slow near the center for fine aim, Aggressive gets fast sooner.")

            // Variable Sensitivity (scale output by axis depth)
            Toggle(isOn: variableSensitivityBinding) {
                Text("Variable")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .hoverHelp("Scale output speed by how far the joystick or trigger is pushed.")

            // Ramp-up: pointer rows only. Starts slow and eases to full speed.
            if binding.outputs.contains(where: { $0.type == .mouseMotion }) {
                HStack(spacing: 4) {
                    Text("Ramp-up")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    // Throttled like the other editor sliders: a plain Slider
                    // saved the preset, and added an undo step, on every tick.
                    ThrottledSlider("Ramp-up", value: rampBinding, in: 0...1500, step: 50)
                        .controlSize(.small)
                        .frame(width: 110)
                        .accessibilityValue((binding.rampMs ?? 0) == 0 ? String(localized: "Off") : String(format: String(localized: "%.3g seconds"), locale: .current, Double(binding.rampMs ?? 0) / 1000))
                    Text((binding.rampMs ?? 0) == 0 ? String(localized: "Off") : String(format: String(localized: "%.3g s"), locale: .current, Double(binding.rampMs ?? 0) / 1000))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.hint)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(minWidth: 42, alignment: .leading)
                }
                .hoverHelp("The pointer starts at a fifth of its speed and builds to full speed over this long of holding the stick, so a short push makes a small move you can stop on a target. Off keeps the speed constant.")
            }
        }
    }

    /// A slider's percent, drawn as the plain number it always was but
    /// typable: click it, type 15 and press Return.
    func percentField<S: ShapeStyle>(_ label: LocalizedStringKey, shown: Double, range: ClosedRange<Double>,
                              style: S, width: CGFloat,
                              set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 0) {
            TextField(label, value: SwiftUI.Binding(
                get: { (shown * 100).rounded() },
                set: { set(min(range.upperBound, max(range.lowerBound, $0 / 100))) }),
                format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .labelsHidden()
                .accessibilityLabel(label)
            Text(verbatim: "%").accessibilityHidden(true)
        }
        .font(.callout.monospacedDigit())
        .foregroundStyle(style)
        // Room for "100%", growing with Text Size like the columns.
        .frame(width: (width + 10) * max(1, textScale))
    }

    private var rampBinding: SwiftUI.Binding<Double> {
        SwiftUI.Binding(
            get: { Double(binding.rampMs ?? 0) },
            set: { binding.rampMs = $0 < 25 ? nil : Int($0) }
        )
    }

    /// Chord picker: this row only fires while another control is held.
    /// Every row but MIDI. On keyboard and mouse rows the menu offers Scan
    /// only, since a controller button is read on a controller's own row.
    @ViewBuilder
    var modifierPicker: some View {
        let mods = binding.modifiers
        let modNames = LocalizedList.and(mods.map { modifierName($0) })
        ForEach(Array(mods.enumerated()), id: \.offset) { i, mod in
            HStack(spacing: 8) {
                Image(systemName: "plus.square.on.square")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(i == 0 ? String(localized: "While also holding") : String(localized: "and"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 118, alignment: .leading)
                modifierMenu(label: modifierName(mod), tinted: true, slot: i) { replaceModifier(at: i, with: $0) }
                Button {
                    var list = binding.modifiers
                    list.remove(at: i)
                    binding.setModifiers(list)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.hint)
                .accessibilityLabel(String(localized: "Remove \(modifierName(mod))", comment: "Takes a held control out of the chord; the control's name"))
            }
        }
        if mods.count < BindingModel.maxModifiers {
            HStack(spacing: 8) {
                Image(systemName: "plus.square.on.square")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(mods.isEmpty ? String(localized: "While also holding") : String(localized: "and"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 118, alignment: .leading)
                modifierMenu(label: mods.isEmpty ? String(localized: "Nothing\u{2026}") : String(localized: "Add another\u{2026}"), tinted: false, slot: nil) { event in
                    binding.setModifiers(binding.modifiers + [event])
                }
                Button("Scan") { onScanModifier(nil) }
                    .controlSize(.small)
                    .hoverHelp("Press or move any control on any connected device to add it to the list this row waits for.")
            }
        }
        Text(mods.isEmpty
             ? String(localized: "Waits for up to three other controls, held with this one.")
             : (mods.count == 1
                ? String(localized: "Fires only while \(modNames) is held. A plain row on the same control stays quiet while the chord is held.")
                : String(localized: "Fires only while \(modNames) are held. A plain row on the same control stays quiet while the chord is held.")))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if !blockableHeldControls.isEmpty {
            let names = blockableHeldControls.map { modifierName($0) }
            Toggle(isOn: SwiftUI.Binding(get: { binding.blockHeldControls == true },
                                         set: { binding.blockHeldControls = $0 ? true : nil })) {
                Text(names.count == 1 ? String(localized: "Block the held control's own action too")
                                      : String(localized: "Block the held controls' own actions too"))
                    .font(.callout)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .hoverHelp("While this preset runs, apps stop seeing the held key or button, so it only serves this chord: K held for W no longer types K. It is held back every time, even without the rest of the chord, since it goes down before the app can know what comes next. Modifier keys are never held back.")
            blockCaption(names, on: binding.blockHeldControls == true)
        }
    }

    /// The menu of controls a chord slot can take.
    private func modifierMenu(label: String, tinted: Bool, slot: Int?,
                              pick: @escaping (InputEvent) -> Void) -> some View {
        // Not the row's own control, nor one already held in another slot:
        // "A while holding A" silenced the plain A row for good, as Scan
        // already refuses.
        let taken = Set([binding.input.serialized] + binding.modifiers.enumerated()
            .filter { $0.offset != slot }.map { $0.element.serialized })
        let free: (Int) -> Bool = { !taken.contains(InputEvent(type: .button, index: $0).serialized) }
        let family = [.extKey, .extMouse].contains(binding.input.type) ? [] : familyButtonLabels.filter { free($0.index) }
        let extras = [.extKey, .extMouse].contains(binding.input.type) ? [] : extraButtons.filter { free($0.index) }
        return SearchableMenu(choices: {
            family.map { entry in
                MenuSearchChoice(title: buttonMenuLabel(for: entry.index)) { pick(InputEvent(type: .button, index: entry.index)) }
            } + extras.filter { e in !family.contains { $0.index == e.index } }.map { extra in
                MenuSearchChoice(title: extra.label) { pick(InputEvent(type: .button, index: extra.index)) }
            } + [MenuSearchChoice(title: String(localized: "Scan for any control\u{2026}")) { onScanModifier(slot) }]
        }) {
            ForEach(family, id: \.index) { entry in
                Button(buttonMenuLabel(for: entry.index)) {
                    pick(InputEvent(type: .button, index: entry.index))
                }
            }
            ForEach(extras.filter { e in !family.contains { $0.index == e.index } }, id: \.index) { extra in
                Button(extra.label) { pick(InputEvent(type: .button, index: extra.index)) }
            }
            if !family.isEmpty || !extras.isEmpty { Divider() }
            Button("Scan for any control\u{2026}") { onScanModifier(slot) }
        } label: {
            Text(label)
                .font(.callout)
                .foregroundStyle(tinted ? Color.accentColor : .primary)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .hoverHelp("A control this row waits for. Pick a controller button here, or Scan to use anything: a key, a mouse button, a MIDI pad, an accessory switch, a tap.")
    }

    private func replaceModifier(at index: Int, with event: InputEvent) {
        var list = binding.modifiers
        guard list.indices.contains(index) else { return }
        list[index] = event
        binding.setModifiers(list)
    }

    /// A held control in the words the rest of the row uses.
    func modifierName(_ m: InputEvent) -> String {
        m.type == .button ? buttonMenuLabel(for: m.index) : m.displayName
    }

    @ViewBuilder
    var pressBehaviorOptions: some View {
        // Toggle, turbo and hold are three mutually exclusive paths in the
        // engine (see pollControllers), so they belong in one menu rather
        // than as separate checkboxes that quietly override each other.
        // With a macro, only the modes the engine runs a macro in: turbo
        // and auto-click skipped the macro or sent both, and hold never ran.
        let hasMacro = binding.macroSteps?.isEmpty == false
        // A gesture is over the moment it lands: nothing is held, so the
        // modes that read a hold are not offered.
        let gesture = neverHeld
        Picker("Press mode", selection: pressModeBinding) {
            Text(gesture ? "Sends a quick press" : "Fires while held").tag(PressMode.normal)
            Text("Toggles on and off").tag(PressMode.toggle)
            if (!hasMacro && !gesture) || pressMode == .turbo {
                Text("Repeats while held").tag(PressMode.turbo)
            }
            if !hasMacro || pressMode == .autoClick {
                Text(gesture ? "Repeats until done again" : "Repeats until pressed again").tag(PressMode.autoClick)
            }
            if (!hasMacro && !gesture) || pressMode == .hold {
                Text("Different action when held").tag(PressMode.hold)
            }
        }
        .labelsHidden()
        .frame(width: 260 * max(1, textScale))
        .controlSize(.regular)
        .accessibilityInputLabels([Text(pressModeTitle), Text("Press mode")])
        .hoverHelp("What a press of this control does.")

        Text(hasMacro && ![PressMode.normal, .toggle].contains(pressMode)
             ? String(localized: "This row runs a macro, which only fires while held or toggles on and off. Pick one of those, or remove the macro.")
             : pressModeExplanation)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if binding.turboEnabled == true {
            autoClickOptions
        }

        // Repeat count: only where the engine uses it, a plain press or a
        // macro. Toggle, turbo, hold and double-tap rows ignored it while
        // the field and the summary said "Repeat x3".
        if repeatApplies {
        // A macro set to run until pressed again ignores the count (the
        // engine loops until the next press), but does use the wait between
        // passes, so the loop shows only the wait. The count field read
        // "3 times per press" while the run was endless, and the wait the
        // loop used was hidden until that ignored count was raised.
        let macroLoops = binding.macroLoop == true && binding.macroSteps?.isEmpty == false
        if !macroLoops {
        HStack(spacing: 6) {
            Text("Repeat")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("", value: repeatCountBinding, format: .number)
                .accessibilityLabel("Repeat count")
                .accessibilityHint("1 to 100")
                .textFieldStyle(.roundedBorder)
                .frame(width: 56 * max(1, textScale))
                .controlSize(.regular)
                .multilineTextAlignment(.center)
            Text((binding.repeatCount ?? 1) > 1 ? String(localized: "times per press") : String(localized: "time per press"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        }

        if (binding.repeatCount ?? 1) > 1 || macroLoops {
            HStack(spacing: 6) {
                Text("Wait")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("", value: repeatDelayBinding, format: .number)
                    .accessibilityLabel(macroLoops ? "Milliseconds between passes" : "Milliseconds between repeats")
                    .accessibilityHint("10 to 5000 milliseconds")
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56 * max(1, textScale))
                    .controlSize(.regular)
                    .multilineTextAlignment(.center)
                Text(macroLoops ? "ms between passes" : "ms between repeats")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        }

    }

    var repeatApplies: Bool {
        binding.macroSteps?.isEmpty == false
            || (pressMode == .normal && binding.holdOutputs == nil && binding.doubleTapOutputs == nil && binding.tripleTapOutputs == nil)
    }

    /// Macro toggle with its editor opening directly underneath.
    @ViewBuilder
    private var macroOptions: some View {
        Toggle(isOn: macroToggleBinding) {
            HStack(spacing: 5) {
                Image(systemName: "bolt.fill")
                    .font(.callout)
                    .accessibilityHidden(true)
                Text("Run a sequence of steps (macro)")
                    .font(.callout)
            }
            .foregroundStyle(binding.macroSteps?.isEmpty == false ? Color.orange : .secondary)
        }
        .toggleStyle(.checkbox)
        .controlSize(.regular)

        if macroEditorShown {
            macroEditorSection
        }
    }

    /// A macro row's output: Macro in the same menu every output has (pick
    /// another type and the row sends that instead), its step count, and
    /// the way to its steps.
    var macroOutputLine: some View {
        let count = binding.macroSteps?.count ?? 0
        return HStack(spacing: gap) {
            Image(systemName: "bolt.fill")
                .font(.callout)
                .foregroundStyle(Color.orange)
                .frame(width: 16)
                .accessibilityHidden(true)
            outputMenu(select: { type in
                    leaveMacroOutput()
                    var action = OutputAction(type: .key, keyCode: 4)
                    action.type = type
                    action.fillDefaultsForType()
                    binding.outputs = [action]
                }, selectSystemKind: { kind in
                    leaveMacroOutput()
                    var action = OutputAction(type: .systemAction, keyCode: 4)
                    action.systemActionKind = kind
                    binding.outputs = [action]
                }, setParameter: { _ in },
                setAppAction: { kind, presetID in
                    leaveMacroOutput()
                    var action = OutputAction(type: .appAction)
                    action.appActionKind = kind
                    action.targetPresetID = presetID
                    binding.outputs = [action]
                }, setKey: { code in
                    leaveMacroOutput()
                    binding.outputs = [OutputAction(type: .key, keyCode: code)]
                }) {
                menuChevronLabel(String(localized: "Macro"))
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .frame(width: outTypeColWidth - 16 - gap, alignment: .leading)
            .accessibilityLabel("Output type")
            .accessibilityValue("Macro")
            Text(count == 0 ? String(localized: "No steps yet") : count == 1 ? String(localized: "1 step") : String(localized: "\(count) steps"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(count == 0 ? String(localized: "Add steps") : String(localized: "Edit steps")) { spotlight("macro") }
                .buttonStyle(.solidSecondaryCompact)
                .controlSize(.small)
                .hoverHelp("Opens the Macro box in this row's Options, where the steps are.")
        }
    }

    /// The Output column's first line on a macro row.
    var macroOutputChip: some View {
        let count = binding.macroSteps?.count ?? 0
        return HStack(spacing: 5) {
            Image(systemName: "bolt.fill")
                .accessibilityHidden(true)
            Text(count == 0 ? String(localized: "Macro, no steps yet") : count == 1 ? String(localized: "Macro, 1 step") : String(localized: "Macro, \(count) steps"))
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(Color.orange)
        .padding(.leading, 16 + gap)
        .accessibilityElement(children: .combine)
        .hoverHelp("This row plays its macro, set up under Options. Any output listed below it is sent on the same press as well; remove it to keep only the macro.")
    }

    var macroEditorShown: Bool {
        showMacroEditor || macroPlaying || binding.macroSteps?.isEmpty == false
    }

    /// The four mutually exclusive things a press can do.
    enum PressMode: Hashable { case normal, toggle, turbo, autoClick, hold }

    private var pressMode: PressMode {
        if binding.toggleMode == true && binding.turboEnabled == true { return .autoClick }
        if binding.toggleMode == true { return .toggle }
        if binding.turboEnabled == true { return .turbo }
        if binding.holdOutputs != nil { return .hold }
        return .normal
    }

    // MARK: Auto-click

    /// The repeat settings every auto-clicker has: the gap between presses in
    /// milliseconds (with the rate it works out to), an optional random
    /// variation so the timing is not machine-perfect, and an optional stop
    /// after a number of presses.
    @ViewBuilder
    private var autoClickOptions: some View {
        HStack(spacing: 6) {
            Text("Every")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Repeat interval in milliseconds", value: turboIntervalBinding, format: .number)
                .accessibilityHint("5 to 60000 milliseconds")
                .textFieldStyle(.roundedBorder)
                .frame(width: 64 * max(1, textScale))
                .controlSize(.regular)
                .multilineTextAlignment(.center)
            Text("ms")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(String(format: String(localized: "(%.1f per second)"), locale: .current, 1000.0 / Double(max(5, turboIntervalMs))))
                .font(.callout)
                .foregroundStyle(.hint)
        }
        .hoverHelp("Time between presses. 100 ms is ten per second; 1000 ms is one per second.")
        HStack(spacing: 6) {
            Text("Vary by up to")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Random variation in milliseconds", value: turboJitterBinding, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 56 * max(1, textScale))
                .controlSize(.regular)
                .multilineTextAlignment(.center)
            Text("ms either way")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .hoverHelp("Adds a random amount, plus or minus, to every gap so the presses are not perfectly regular. 0 keeps them exact.")
        HStack(spacing: 6) {
            Text("Stop after")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Stop after this many presses", value: turboMaxCountBinding, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 56 * max(1, textScale))
                .controlSize(.regular)
                .multilineTextAlignment(.center)
            Text((binding.turboMaxCount ?? 0) > 0 ? String(localized: "presses") : String(localized: "presses (0 keeps going)"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .hoverHelp("Ends the run after this many presses. 0 means it keeps going until you release, or press again in toggle mode.")
    }

    /// Where a mouse button output clicks: wherever the pointer is, or a
    /// fixed point on screen captured from the pointer's current position.
    @ViewBuilder
    func clickPointControls(at index: Int, in list: OutputList = .main) -> some View {
        let current = output(at: index, in: list)
        let fixed = current?.clickX != nil
        Menu {
            Button("Where the pointer is") {
                // Also the way out of a fixed point being counted down: its
                // pending take is called off, or the spot was taken anyway.
                if clickPointTarget == "\(index)-\(list)" {
                    clickPointToken = nil
                    clickPointLeft = nil
                    clickPointTarget = nil
                }
                updateOutput(index, in: list) {
                    $0.clickX = nil
                    $0.clickY = nil
                }
            }
            Button("At a fixed point: the pointer's position in a few seconds") {
                captureClickPoint(at: index, in: list)
            }
        } label: {
            menuLabel((clickPointTarget == "\(index)-\(list)" ? clickPointLeft : nil).map { String(localized: "Taking the spot in \($0)\u{2026}") } ?? (fixed
                      ? String(format: String(localized: "at %.0f, %.0f"), locale: .current, current?.clickX ?? 0, current?.clickY ?? 0)
                      : String(localized: "at pointer")))
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .hoverHelp("Click wherever the pointer is, or always at one spot on screen. To set the spot, pick the second option and move the pointer there; a countdown shows on this menu and is spoken, and the spot is taken when it ends. Or type the spot in the X and Y fields.")
        if fixed {
            // The spot typed in directly, for anyone who cannot hold the
            // pointer still on a target through the countdown.
            HStack(spacing: 4) {
                Text("X").font(.caption).foregroundStyle(.secondary)
                TextField("X", value: clickCoordinate(index, \.clickX, in: list), format: .number.grouping(.never))
                    .frame(width: 56 * max(1, textScale))
                    .accessibilityLabel("Click point X, in points from the left of the main display")
                Text("Y").font(.caption).foregroundStyle(.secondary)
                TextField("Y", value: clickCoordinate(index, \.clickY, in: list), format: .number.grouping(.never))
                    .frame(width: 56 * max(1, textScale))
                    .accessibilityLabel("Click point Y, in points from the top of the main display")
            }
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
        }
    }

    private func clickCoordinate(_ index: Int, _ path: WritableKeyPath<OutputAction, Double?>,
                                 in list: OutputList = .main) -> SwiftUI.Binding<Double> {
        SwiftUI.Binding(
            get: { output(at: index, in: list)?[keyPath: path] ?? 0 },
            set: { value in
                updateOutput(index, in: list) { $0[keyPath: path] = max(-100_000, min(100_000, value.rounded())) }
            })
    }

    /// Records the pointer's position two seconds after the menu closes, so
    /// the user can move the pointer to the target first. Stored in
    /// CoreGraphics coordinates (origin top-left) to match the click events.
    private func captureClickPoint(at index: Int, in list: OutputList = .main) {
        // A countdown seen on the menu and spoken, so nobody is surprised
        // by when the spot is taken. Switch Control glides the pointer
        // slowly, so it gets longer.
        // The output is found by id at the end, so one removed or moved
        // above it meanwhile does not take the spot. Checked before any
        // countdown state is set, so a missing row leaves none behind.
        guard let outputID = output(at: index, in: list)?.id else { return }
        let total = NSWorkspace.shared.isSwitchControlEnabled ? 10 : 3
        Self.announce(String(localized: "Move the pointer to the spot. Taken in \(total) seconds."))
        clickPointLeft = total
        clickPointTarget = "\(index)-\(list)"
        // A second countdown started on any output cancels this one: the
        // token changes and the old blocks do nothing.
        let token = UUID()
        clickPointToken = token
        for step in 1..<total {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step)) {
                guard clickPointToken == token else { return }
                clickPointLeft = total - step
                // Queued behind the instruction rather than cutting it off.
                if total - step <= 2 { Self.announce("\(total - step)", priority: .medium) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(total)) {
            guard clickPointToken == token, OpenEditor.current != nil else { return }
            clickPointLeft = nil
            clickPointToken = nil
            guard let current = outputs(in: list).firstIndex(where: { $0.id == outputID }) else { return }
            let location = NSEvent.mouseLocation
            let height = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
            let x = Double(location.x.rounded()), y = Double((height - location.y).rounded())
            updateOutput(current, in: list) {
                $0.clickX = x
                $0.clickY = y
            }
            NSSound(named: "Tink")?.play()
            Self.announce(String(localized: "Spot set at \(Int(x)), \(Int(y))"))
        }
    }

    var turboIntervalMs: Int {
        if let ms = binding.turboIntervalMs, ms > 0 { return ms }
        return Int((1000.0 / Double(max(1, min(60, binding.turboRate ?? 10)))).rounded())
    }

    private var turboIntervalBinding: SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { turboIntervalMs },
            set: { ms in
                let clamped = Self.clamped(ms, 5...60_000)
                binding.turboIntervalMs = clamped
                // Keep the older rate field in step for anything that reads it.
                binding.turboRate = max(1, min(60, Int((1000.0 / Double(clamped)).rounded())))
            }
        )
    }

    private var turboJitterBinding: SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.turboJitterMs ?? 0 },
            set: { binding.turboJitterMs = $0 <= 0 ? nil : min(10_000, $0) }
        )
    }

    private var turboMaxCountBinding: SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.turboMaxCount ?? 0 },
            set: { binding.turboMaxCount = $0 <= 0 ? nil : min(100_000, $0) }
        )
    }

    /// Plain-language answer to "what does this do", under the menu.
    /// A stick gesture, a touchpad gesture, a tap on the Mac, a MIDI program
    /// change or transport message, or a knob in Turn mode: pressed for a
    /// moment and never held (MappingEngine.isOneShot), so hold, turbo and a
    /// held action never or always fired on them.
    var neverHeld: Bool {
        MappingEngine.isNeverHeld(binding.input)
    }

    /// A stick gesture, a button sequence or a key sequence: made, not held.
    private var isSequenceLike: Bool {
        [.stickGesture, .buttonSequence, .keySequence].contains(binding.input.type)
    }

    private var pressModeExplanation: String {
        if neverHeld, !isSequenceLike {
            switch pressMode {
            case .normal: return String(localized: "Each time it happens, the output is pressed and let go once.")
            case .toggle: return String(localized: "Each time it happens, the output turns on, and the next time off.")
            case .autoClick: return String(localized: "It starts the output firing over and over, and the next time stops it.")
            // A double click's 200 ms window does carry turbo's pulses.
            case .turbo where binding.input.type == .extMouse && binding.input.extMouseKind == .doubleClick:
                return String(localized: "Turbo fires only for the double click's moment, a few pulses at most.")
            case .turbo, .hold: return String(localized: "This control is not held, so this does nothing here. Pick another way for it to fire.")
            }
        }
        if isPressSequence {
            switch pressMode {
            case .normal: return String(localized: "Each time the sequence is made, the output is pressed and let go once.")
            case .toggle: return String(localized: "The sequence turns the output on and leaves it on. Making it again turns it off.")
            case .autoClick: return String(localized: "The sequence starts the output firing over and over, and making it again stops it.")
            case .turbo, .hold: return String(localized: "A sequence is not held, so this does nothing here. Pick another way for it to fire.")
            }
        }
        if isSequenceLike {
            switch pressMode {
            case .normal: return String(localized: "Each time the gesture is made, the output is pressed and let go once.")
            case .toggle: return String(localized: "The gesture turns the output on and leaves it on. Making it again turns it off.")
            case .autoClick: return String(localized: "The gesture starts the output firing over and over, and making it again stops it.")
            case .turbo, .hold: return String(localized: "A gesture is not held, so this does nothing here. Pick another way for it to fire.")
            }
        }
        switch pressMode {
        case .normal where binding.macroSteps?.isEmpty == false:
            // A macro plays its steps; nothing is held for the press.
            return String(localized: "Each press plays the macro's steps.")
        case .normal:
            return String(localized: "The output is held down for as long as you hold the control, and released when you let go.")
        case .toggle:
            return String(localized: "One press turns the output on and leaves it on. The next press turns it off.")
        case .turbo:
            return String(localized: "The output fires over and over while you hold the control, at the rate below.")
        case .autoClick:
            return String(localized: "Press once to start the output firing over and over, and press again to stop it. An auto-clicker: put a click on this row and it clicks for you.")
        case .hold:
            return String(localized: "A quick tap sends the normal output. Holding past the time set under Extra actions sends something else instead, so one control can do two jobs.")
        }
    }

    private var pressModeBinding: SwiftUI.Binding<PressMode> {
        SwiftUI.Binding(
            get: { pressMode },
            set: { mode in
                binding.toggleMode = (mode == .toggle || mode == .autoClick) ? true : nil
                binding.turboEnabled = (mode == .turbo || mode == .autoClick) ? true : nil
                if mode == .hold {
                    if binding.holdOutputs == nil {
                        binding.holdOutputs = [OutputAction(type: .key, keyCode: 225)]
                    }
                } else {
                    binding.holdOutputs = nil
                }
                // Toggle, repeat and auto-click never run a double tap; it
                // stayed on behind a disabled checkbox, and the summary still
                // said "2x".
                if mode == .toggle || mode == .turbo || mode == .autoClick {
                    binding.doubleTapOutputs = nil
                    binding.tripleTapOutputs = nil
                    binding.doubleTapWindowMs = nil
                }
                // A toggled macro ends on the next press, never on release:
                // the engine's toggle branch does not read stop-on-release,
                // so the flag only misreported the row's When it runs.
                if mode == .toggle || mode == .autoClick {
                    binding.macroInterruptOnRelease = nil
                }
            }
        )
    }

    /// Reflects the binding's ACTUAL macro state, not just editor
    /// visibility. The old bridge read a transient @State, so reopening a
    /// preset showed an unchecked box while a saved macro silently
    /// overrode the row's outputs, and unchecking did not disable it.
    /// Turning it on opens the step editor; turning it off removes the
    /// macro (recoverable with Undo, which restores the whole binding).
    private var macroToggleBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { binding.macroSteps?.isEmpty == false || showMacroEditor },
            set: { on in
                if on {
                    // Same as the Extra actions menu: a macro takes the
                    // row over, so repeat, hold and double tap step aside.
                    binding.turboEnabled = nil
                    binding.holdOutputs = nil
                    binding.doubleTapOutputs = nil
                    binding.tripleTapOutputs = nil
                    showMacroEditor = true
                } else {
                    binding.macroSteps = nil
                    showMacroEditor = false
                }
            }
        )
    }

    // MARK: - Advanced Bindings

    private var deadzoneBinding: SwiftUI.Binding<Double> {
        SwiftUI.Binding(
            get: { binding.deadzone.map(Double.init) ?? defaultDeadzone },
            set: {
                binding.deadzone = Float($0)
                // Full push stays past the deadzone, else nothing is in between.
                if let outer = binding.outerDeadzone, Double(outer) < $0 + 0.01 {
                    let raised = min(1.0, $0 + 0.01)
                    binding.outerDeadzone = raised >= 0.99 ? nil : Float(raised)
                }
            }
        )
    }

    /// Triggers live on axis indices 4 (left) and 5 (right) by convention.
    /// Used to switch the Calibrate button icon between trigger gauge and
    /// joystick circle styles.
    var invertExplanation: String {
        switch binding.input.type {
        case .motion: return String(localized: "Read the tilt the other way round: this row fires when the controller moves opposite to its named direction.")
        case .touchpad: return String(localized: "Read the finger the other way round: a swipe left counts as right and up as down for this row.")
        case .stickGesture:
            return String(localized: "Mirror the stick before reading the gesture: a flick up counts as down and a flick left as right.")
        case .stickRegion:
            return isBandRow
                ? String(localized: "Turn the travel over before checking the band, so a band at the top fires at the bottom.")
                : String(localized: "Mirror the stick before checking the region, so the region is entered from the opposite side.")
        default: return String(localized: "Read the stick backwards for this row: pushed left counts as right and up as down, and variable speed follows the reversed value. It is per row, so the row for the other direction is unaffected.")
        }
    }

    /// Ready-made motion rows for this row's group (see MotionSetup).
    @ViewBuilder
    var motionSetupSection: some View {
        Section("Set Up Full Gyro") {
            ForEach(MotionSetup.allCases) { setup in
                Button(setup.title) { MotionSetupAction.perform?(binding.id, setup) }
            }
        }
    }

    /// The two options as the engine uses them, and only where their
    /// toggles are shown.
    /// The pad behind the row reads this axis 0 to 1 already. Read through
    /// the engine's service, not observed, so rows do not redraw on input.
    private var axisAlreadyOneWay: Bool {
        guard binding.input.type == .axis, let service = MappingEngine.current?.controllerServiceForSettings else { return false }
        return service.axisReadsOneWay(slot: slot, index: binding.input.index)
    }

    var fullTravelShown: Bool {
        binding.fullTravel == true && binding.input.type == .axis && !isTriggerAxis && binding.input.axisDirection != .none
    }
    var fromNeutralShown: Bool {
        binding.fromNeutral == true && binding.input.type == .motion
            && [.pitchAngle, .rollAngle, .yawAngle].contains(binding.input.motionChannel ?? .gyroY)
    }

    var isTriggerAxis: Bool {
        binding.input.type == .axis && (binding.input.index == 4 || binding.input.index == 5)
    }

    /// Like `deadzoneBinding` but always writes the value (even the 0.25 default).
    /// The calibration view always wants to persist what the user picked so the
    /// next time they open the editor the slider matches what they set.
    var deadzoneCalibrationBinding: SwiftUI.Binding<Double> {
        SwiftUI.Binding(
            get: { Double(binding.deadzone ?? 0.25) },
            set: { binding.deadzone = Float($0) }
        )
    }

    /// Outer deadzone binding for the calibration sheet. Defaults to 1.0
    /// (no saturation), which the view interprets as "no outer ring".
    var outerDeadzoneBinding: SwiftUI.Binding<Double> {
        SwiftUI.Binding(
            get: { Double(binding.outerDeadzone ?? 1.0) },
            set: {
                binding.outerDeadzone = $0 >= 0.99 ? nil : Float($0)
                // The deadzone stays under the full push, within its slider.
                let inner = binding.deadzone.map(Double.init) ?? defaultDeadzone
                if inner > $0 - 0.01 {
                    binding.deadzone = Float(max(0.01, $0 - 0.01))
                }
            }
        )
    }

    var invertBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { binding.invertAxis ?? false },
            set: { binding.invertAxis = $0 ? true : nil }
        )
    }

    var keyRepeatBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            // Off unless turned on, as in 1.5: every row saved before 1.6
            // has no setting, and holding Command Tab or Return there must
            // not start repeating after the update.
            get: { binding.keyRepeat == true },
            set: { binding.keyRepeat = $0 ? true : nil }
        )
    }

    var blockOriginalBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { binding.blockOriginal ?? false },
            // Off is stored as false, not removed, so the 1.6 upgrade that
            // turns blocking on for never-set side-button rows (run again on
            // a backup restore) leaves a row the user turned off alone.
            set: { binding.blockOriginal = $0 }
        )
    }

    private var toggleBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { binding.toggleMode ?? false },
            set: {
                binding.toggleMode = $0 ? true : nil
                if $0 {
                    binding.turboEnabled = nil // Mutually exclusive
                    binding.macroInterruptOnRelease = nil
                }
            }
        )
    }

    private var turboBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { binding.turboEnabled ?? false },
            set: {
                binding.turboEnabled = $0 ? true : nil
                if $0 { binding.toggleMode = nil } // Mutually exclusive
            }
        )
    }

    private var turboRateBinding: SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.turboRate ?? 10 },
            set: { binding.turboRate = $0 }
        )
    }

    private var curveBinding: SwiftUI.Binding<SensitivityCurve> {
        SwiftUI.Binding(
            get: { binding.sensitivityCurve ?? .linear },
            set: { binding.sensitivityCurve = $0 == .linear ? nil : $0 }
        )
    }

    private var repeatCountBinding: SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.repeatCount ?? 1 },
            set: { binding.repeatCount = $0 <= 1 ? nil : Self.clamped($0, 1...100) }
        )
    }

    private var repeatDelayBinding: SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.repeatDelayMs ?? 100 },
            set: { binding.repeatDelayMs = Self.clamped($0, 10...5000) }
        )
    }

    private var variableSensitivityBinding: SwiftUI.Binding<Bool> {
        // Default: true when input is an axis (matches engine behavior), false otherwise
        let defaultValue = binding.input.type == .axis
        return SwiftUI.Binding(
            get: { binding.variableSensitivity ?? defaultValue },
            set: { binding.variableSensitivity = $0 == defaultValue ? nil : $0 }
        )
    }

    var hapticBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { binding.hapticEnabled ?? false },
            set: { binding.hapticEnabled = $0 ? true : nil }
        )
    }

    var hapticIntensityBinding: SwiftUI.Binding<Double> {
        SwiftUI.Binding(
            get: { Double(binding.hapticIntensity ?? 0.6) },
            set: { binding.hapticIntensity = Float($0) }
        )
    }

    var hapticDurationBinding: SwiftUI.Binding<Double> {
        SwiftUI.Binding(
            get: { Double(binding.hapticDurationMs ?? FeedbackService.defaultDurationMs) },
            set: { v in
                let ms = Int(v.rounded())
                // Under the transient cutoff means "a tap", which is the
                // default, so store nothing and keep the file as it was.
                binding.hapticDurationMs = ms < FeedbackService.transientCutoffMs ? nil : ms
            }
        )
    }

    /// The press mode picker's shown choice, which Voice Control answers to.
    private var pressModeTitle: String {
        switch pressMode {
        case .normal: return String(localized: "Fires while held")
        case .toggle: return String(localized: "Toggles on and off")
        case .turbo: return String(localized: "Repeats while held")
        case .autoClick: return String(localized: "Repeats until pressed again")
        case .hold: return String(localized: "Different action when held")
        }
    }

    /// The vibration length as VoiceOver says it, in words, not "ms".
    func spokenHapticDuration(_ ms: Double) -> String {
        if ms < Double(FeedbackService.transientCutoffMs) { return String(localized: "Tap") }
        if ms >= 1000 { return String(localized: "\((ms / 1000).formatted(.number.precision(.fractionLength(1)))) seconds") }
        return String(localized: "\(Int(ms)) milliseconds")
    }

    func hapticDurationLabel(_ ms: Double) -> String {
        ms < Double(FeedbackService.transientCutoffMs) ? String(localized: "Tap") :
            ms >= 1000 ? String(format: String(localized: "%.1f s"), locale: .current, ms / 1000) : String(localized: "\(Int(ms)) ms")
    }

    var speechBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { binding.speechEnabled ?? false },
            set: { binding.speechEnabled = $0 ? true : nil }
        )
    }

    var speechTextBinding: SwiftUI.Binding<String> {
        SwiftUI.Binding(
            // A built-in phrase in the app's language, English on disk.
            // Shown as typed while it is being typed: passing through a
            // shipped word ("Hello") swapped the field to its translation.
            get: { phraseFocused ? (binding.speechText ?? "") : ShippedText.phrase(binding.speechText ?? "") },
            set: { new in
                let shown = phraseFocused ? (binding.speechText ?? "") : ShippedText.phrase(binding.speechText ?? "")
                // Cut to the same limit a file's phrase is cut to on load.
                let capped = new.count > Preset.labelLengthLimit ? String(new.prefix(Preset.labelLengthLimit)) : new
                if capped != shown { binding.speechText = capped.isEmpty ? nil : capped }
            }
        )
    }

    private var speechDestinationBinding: SwiftUI.Binding<SpeechDestination> {
        SwiftUI.Binding(
            get: { binding.speechDestination ?? .mac },
            set: { binding.speechDestination = $0 == .mac ? nil : $0 }
        )
    }
}
