import SwiftUI

/// A single binding row with fixed-width columns for consistent alignment.
struct BindingRowView: View {
    @SwiftUI.Binding var binding: BindingModel
    let onScan: () -> Void
    let onRemove: () -> Void
    var onDuplicate: (() -> Void)?
    var isHighlighted: Bool = false
    /// 1-based position of this binding within its joystick group. Drives the
    /// "#N" chip at the start of every row so the Live Visualizer can refer
    /// to a specific row by number.
    var displayNumber: Int = 0
    /// True while this row is the target of a jump-to-binding pulse triggered
    /// by clicking on the Live Visualizer. Shows a yellow ring for ~1.2 s.
    var isPulsing: Bool = false

    @State private var showAdvanced = false
    @State private var showMacroEditor = false
    @State private var showDeadzoneCalibration = false

    /// Live mirrors of slider values, updated every drag tick so the value
    /// shown next to each slider follows the thumb in real time. The
    /// underlying BindingModel still only commits on slider release to keep
    /// the editor's re-render chain off the per-frame hot path.
    @State private var liveSpeed: [Int: Double] = [:]
    @State private var liveHaptic: Double?
    @State private var liveDeadzone: Double?

    // Fixed column widths for perfect alignment
    private let dragWidth: CGFloat = 16
    private let scanColWidth: CGFloat = 54
    private let typeColWidth: CGFloat = 78
    private let indexColWidth: CGFloat = 98
    private let dirColWidth: CGFloat = 58
    private let arrowWidth: CGFloat = 24
    private let outTypeColWidth: CGFloat = 130
    private let actionsWidth: CGFloat = 48
    private let colGap: CGFloat = 8

    /// Total width of input columns (for sub-row indentation)
    private var inputColumnsWidth: CGFloat {
        dragWidth + scanColWidth + typeColWidth + indexColWidth + dirColWidth + arrowWidth + colGap * 6
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Primary row
            HStack(spacing: colGap) {
                // Row number chip - matches the number shown in the Live
                // Visualizer popover so users can find the right row when
                // they click an input on the visualizer.
                if displayNumber > 0 {
                    Text("#\(displayNumber)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.12))
                        )
                        .frame(minWidth: 28, alignment: .leading)
                }

                // Drag handle
                Image(systemName: "line.3.horizontal")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: dragWidth)

                // COL 1: Scan
                Button("Scan", action: onScan)
                    .font(.caption2)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .frame(width: scanColWidth, alignment: .center)

                // COL 2: Input Type
                Picker("", selection: $binding.input.type) {
                    ForEach(InputType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: typeColWidth, alignment: .leading)

                // COL 3: Index
                indexPicker
                    .frame(width: indexColWidth, alignment: .leading)

                // COL 4: Direction (or empty spacer for Button type)
                directionPicker
                    .frame(width: dirColWidth, alignment: .leading)

                // Arrow
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: arrowWidth)

                // COL 5: Output Type
                if !binding.outputs.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: outputIcon(for: binding.outputs[0]))
                            .font(.caption)
                            .foregroundStyle(outputColor(for: binding.outputs[0]))
                            .frame(width: 14)

                        Picker("", selection: firstOutputTypeBinding) {
                            ForEach(OutputType.allCases) { type in
                                Text(type.displayName).tag(type)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                    }
                    .frame(width: outTypeColWidth, alignment: .leading)

                    // COL 6: Output Value (flexible)
                    outputValueControls(at: 0)

                    if binding.outputs.count > 1 {
                        Button {
                            removeOutput(at: 0)
                        } label: {
                            Image(systemName: "xmark.circle")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer(minLength: 4)

                // COL 7: Actions
                HStack(spacing: 3) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            binding.outputs.append(OutputAction(type: .key, keyCode: 4))
                        }
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .help("Add output")

                    if let onDuplicate {
                        CopyIconButton(action: onDuplicate,
                                       helpText: "Duplicate this binding")
                    }

                    Button(action: onRemove) {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red.opacity(0.7))
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
                .frame(width: actionsWidth + 18, alignment: .trailing)
            }

            // Secondary output sub-rows
            secondaryOutputRows

            // Advanced options
            advancedSection
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHighlighted ? Color.green.opacity(0.18) : Color.secondary.opacity(0.05))
                // Instant fade-in (so quick taps feel snappy), longer fade-out (so the
// green dwell tracks the latched visibility period from
// GameControllerService.rawActiveExpiry).
.animation(isHighlighted ? .linear(duration: 0.0) : .easeOut(duration: 0.18),
           value: isHighlighted)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isHighlighted ? Color.green.opacity(0.4) : Color.clear, lineWidth: 1.5)
                // Instant fade-in (so quick taps feel snappy), longer fade-out (so the
// green dwell tracks the latched visibility period from
// GameControllerService.rawActiveExpiry).
.animation(isHighlighted ? .linear(duration: 0.0) : .easeOut(duration: 0.18),
           value: isHighlighted)
        )
        .overlay(
            // Jump-to-binding pulse: bright yellow ring that fades out
            // after the user clicks an input on the Live Visualizer.
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isPulsing ? Color.yellow.opacity(0.85) : Color.clear, lineWidth: 2.5)
                .animation(.easeOut(duration: 0.6), value: isPulsing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .sheet(isPresented: $showDeadzoneCalibration) {
            DeadzoneCalibrationView(
                axisIndex: binding.input.index,
                deadzone: deadzoneCalibrationBinding,
                outerDeadzone: outerDeadzoneBinding,
                isInverted: binding.invertAxis ?? false,
                onClose: { showDeadzoneCalibration = false }
            )
        }
    }

    // MARK: - Index Picker (fixed width)

    @ViewBuilder
    private var indexPicker: some View {
        switch binding.input.type {
        case .button:
            // Use Menu instead of Picker so 64 button-index items only
            // instantiate when the menu is opened, not on every editor render.
            Menu {
                ForEach(0..<64, id: \.self) { i in
                    Button("Button \(i)") { binding.input.index = i }
                }
            } label: {
                menuLabel("Button \(binding.input.index)")
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

        case .axis:
            Menu {
                ForEach(0..<16, id: \.self) { i in
                    Button("Axis #\(i)") { binding.input.index = i }
                }
            } label: {
                menuLabel("Axis #\(binding.input.index)")
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

        case .hat:
            Picker("", selection: $binding.input.index) {
                ForEach(0..<16, id: \.self) { i in
                    Text("Hat #\(i)").tag(i)
                }
            }
            .labelsHidden()
            .controlSize(.small)

        case .touchpad:
            // Touchpad "index" represents the finger slot (0 or 1).
            Picker("", selection: touchpadFingerBinding) {
                Text("Finger 1").tag(0)
                Text("Finger 2").tag(1)
            }
            .labelsHidden()
            .controlSize(.small)

        case .motion:
            // Pick the motion channel (gyro X/Y/Z, accel X/Y/Z, attitude
            // roll/pitch/yaw). Direction picker handles + / -.
            Menu {
                ForEach(MotionChannel.allCases) { channel in
                    Button(channel.displayName) {
                        binding.input.motionChannel = channel
                    }
                }
            } label: {
                menuLabel((binding.input.motionChannel ?? .gyroY).displayName)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

        case .touchpadRegion:
            // Pick from defined regions by name. If none are defined yet, the
            // menu shows a hint so users know to open Calibrate Touchpad.
            Menu {
                let regions = TouchpadService.shared.allRegions()
                if regions.isEmpty {
                    Text("No regions defined")
                    Text("Open Calibrate Touchpad to add some")
                } else {
                    ForEach(regions) { region in
                        Button(region.name) {
                            binding.input.touchpadRegionID = region.id
                        }
                    }
                }
            } label: {
                menuLabel(touchpadRegionDisplayName)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()
        }
    }

    private var touchpadRegionDisplayName: String {
        if let id = binding.input.touchpadRegionID,
           let r = TouchpadService.shared.region(with: id) {
            return r.name
        }
        return "Pick region"
    }

    // MARK: - Direction Picker (fixed width, empty for buttons)

    @ViewBuilder
    private var directionPicker: some View {
        switch binding.input.type {
        case .button:
            // Empty placeholder to keep column width consistent
            Color.clear

        case .axis:
            Picker("", selection: axisDirectionBinding) {
                ForEach(AxisDirection.allCases) { dir in
                    Text(dir.displayName).tag(dir)
                }
            }
            .labelsHidden()
            .controlSize(.small)

        case .hat:
            Picker("", selection: hatDirectionBinding) {
                ForEach(HatDirection.allCases) { dir in
                    Text(dir.displayName).tag(dir)
                }
            }
            .labelsHidden()
            .controlSize(.small)

        case .touchpadRegion:
            // Region inputs are button-like; no direction picker needed.
            Color.clear

        case .motion:
            // Motion inputs read like axes: pick + or - polarity.
            Picker("", selection: axisDirectionBinding) {
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
        }
    }

    private func setTouchpad(axis: TouchpadAxis, dir: AxisDirection) {
        binding.input.touchpadAxis = axis
        binding.input.axisDirection = dir
    }

    private var touchpadFingerBinding: SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.input.touchpadFinger ?? binding.input.index },
            set: { newValue in
                binding.input.touchpadFinger = newValue
                binding.input.index = newValue
            }
        )
    }

    // MARK: - Output Value Controls

    @ViewBuilder
    private func outputValueControls(at index: Int) -> some View {
        let actionBinding = outputBinding(at: index)

        switch binding.outputs[index].type {
        case .key:
            KeyCodePicker(selectedCode: keyCodeBinding(at: index))

        case .mouseButton:
            // Lazy Menu: only builds the 32 button options when opened.
            Menu {
                ForEach(0..<32, id: \.self) { i in
                    Button(mouseButtonName(i)) {
                        binding.outputs[index].mouseButtonIndex = i
                    }
                }
            } label: {
                menuLabel(mouseButtonName(binding.outputs[index].mouseButtonIndex ?? 0))
            }
            .menuStyle(.borderlessButton)
            .frame(minWidth: 120)
            .controlSize(.small)

        case .mouseMotion, .mouseWheel:
            HStack(spacing: 8) {
                Picker("", selection: mouseAxisDirBinding(at: index)) {
                    Text("Up").tag("1 -")
                    Text("Right").tag("0 +")
                    Text("Down").tag("1 +")
                    Text("Left").tag("0 -")
                }
                .labelsHidden()
                .frame(width: 72)
                .controlSize(.small)

                Text("Speed")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                ThrottledSlider(
                    value: speedBinding(at: index),
                    in: 1...50,
                    step: 1,
                    onLiveChange: { liveSpeed[index] = $0 }
                )
                    .frame(minWidth: 80, idealWidth: 100)

                TextField("", value: liveSpeedBinding(at: index), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 44)
                    .controlSize(.small)
                    .multilineTextAlignment(.center)
            }

        case .mouseWheelStep:
            Picker("", selection: mouseAxisDirBinding(at: index)) {
                Text("Up").tag("1 -")
                Text("Right").tag("0 +")
                Text("Down").tag("1 +")
                Text("Left").tag("0 -")
            }
            .labelsHidden()
            .frame(width: 70)
            .controlSize(.small)

        case .midiNote:
            HStack(spacing: 6) {
                Text("Note")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                // Lazy Menu so the 128 note options only build when opened.
                Menu {
                    ForEach(MIDIService.notePickerLabels, id: \.number) { entry in
                        Button(entry.label) {
                            binding.outputs[index].midiNote = entry.number
                        }
                    }
                } label: {
                    let current = binding.outputs[index].midiNote ?? 60
                    menuLabel("\(MIDIService.noteName(current)) (\(current))")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 100)
                .controlSize(.small)

                Text("Vel")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                TextField("", value: midiVelocityBinding(at: index), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 44)
                    .controlSize(.small)
                    .multilineTextAlignment(.center)

                Text("Ch")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Picker("", selection: midiChannelBinding(at: index)) {
                    ForEach(1...16, id: \.self) { c in
                        Text("\(c)").tag(c)
                    }
                }
                .labelsHidden()
                .frame(width: 50)
                .controlSize(.small)
            }

        case .midiCC:
            HStack(spacing: 6) {
                Text("CC")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                // Lazy Menu so the 128 CC options only build when opened.
                Menu {
                    ForEach(MIDIService.ccPickerLabels, id: \.number) { entry in
                        Button(entry.label) {
                            binding.outputs[index].midiCCNumber = entry.number
                        }
                    }
                } label: {
                    let current = binding.outputs[index].midiCCNumber ?? 1
                    let label = MIDIService.ccNameByNumber[current].map { "\(current) - \($0)" } ?? "\(current)"
                    menuLabel(label)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 160)
                .controlSize(.small)

                Text("Ch")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Picker("", selection: midiChannelBinding(at: index)) {
                    ForEach(1...16, id: \.self) { c in
                        Text("\(c)").tag(c)
                    }
                }
                .labelsHidden()
                .frame(width: 50)
                .controlSize(.small)
            }

        case .midiPitchBend:
            HStack(spacing: 6) {
                Text("Ch")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Picker("", selection: midiChannelBinding(at: index)) {
                    ForEach(1...16, id: \.self) { c in
                        Text("\(c)").tag(c)
                    }
                }
                .labelsHidden()
                .frame(width: 50)
                .controlSize(.small)
                Text("Use with a continuous axis for smooth bend.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

        case .midiProgramChange:
            HStack(spacing: 6) {
                Text("Program")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Menu {
                    ForEach(0...127, id: \.self) { p in
                        Button("\(p)") { binding.outputs[index].midiProgramNumber = p }
                    }
                } label: {
                    menuLabel("\(binding.outputs[index].midiProgramNumber ?? 0)")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 70)
                .controlSize(.small)

                Text("Ch")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Picker("", selection: midiChannelBinding(at: index)) {
                    ForEach(1...16, id: \.self) { c in
                        Text("\(c)").tag(c)
                    }
                }
                .labelsHidden()
                .frame(width: 50)
                .controlSize(.small)
            }

        case .midiTransport:
            HStack(spacing: 6) {
                Text("Action")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Picker("", selection: midiTransportBinding(at: index)) {
                    ForEach(MIDITransport.allCases) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                .labelsHidden()
                .frame(width: 100)
                .controlSize(.small)
                Text("Sends a real-time transport message to the DAW.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Secondary Outputs

    @ViewBuilder
    private var secondaryOutputRows: some View {
        if binding.outputs.count > 1 {
            ForEach(Array(binding.outputs.enumerated().dropFirst()), id: \.element.id) { index, output in
                secondaryOutputRow(index: index, output: output)
            }
        }
    }

    private func secondaryOutputRow(index: Int, output: OutputAction) -> some View {
        HStack(spacing: colGap) {
            Color.clear.frame(width: inputColumnsWidth)

            Text("+")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            HStack(spacing: 4) {
                Image(systemName: outputIcon(for: output))
                    .font(.caption)
                    .foregroundStyle(outputColor(for: output))
                    .frame(width: 14)

                Picker("", selection: outputTypeBinding(at: index)) {
                    ForEach(OutputType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
            }
            .frame(width: outTypeColWidth, alignment: .leading)

            outputValueControls(at: index)

            Button {
                removeOutput(at: index)
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 4)
        }
        .padding(.top, 4)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Advanced Section

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showAdvanced {
                advancedOptionsRow
                    .padding(.top, 6)
            }

            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showAdvanced.toggle() }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                            .font(.system(size: 7))
                        Text(hasAdvancedOptions ? "Options *" : "Options")
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(hasAdvancedOptions ? Color.blue : Color.gray.opacity(0.4))
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Advanced Options

    private var hasAdvancedOptions: Bool {
        binding.deadzone != nil || binding.invertAxis == true ||
        binding.toggleMode == true || binding.turboEnabled == true ||
        binding.sensitivityCurve != nil || (binding.repeatCount ?? 1) > 1 ||
        (binding.macroSteps?.isEmpty == false) ||
        binding.variableSensitivity != nil ||
        binding.hapticEnabled == true || binding.speechEnabled == true
    }

    @ViewBuilder
    private var advancedOptionsRow: some View {
        // Vertical list. One option per line keeps the row readable and
        // matches the way the macro toggle now behaves.
        VStack(alignment: .leading, spacing: 4) {
            if binding.input.type == .axis {
                advancedAxisOptions
            }
            advancedModeOptions
            advancedFeedbackOptions

            if binding.speechEnabled == true {
                speechDetailRow
            }

            if showMacroEditor {
                macroEditorSection
            }
        }
        .padding(.leading, dragWidth + colGap)
    }

    @ViewBuilder
    private var advancedFeedbackOptions: some View {
        // Haptic toggle
        Toggle(isOn: hapticBinding) {
            HStack(spacing: 3) {
                Image(systemName: "waveform")
                    .font(.system(size: 8))
                Text("Vibrate")
                    .font(.system(size: 9))
            }
            .foregroundStyle(.secondary)
        }
        .toggleStyle(.checkbox)
        .controlSize(.mini)
        .help("Vibrate the controller when this binding fires (DualSense, DualSense Edge, and similar).")

        if binding.hapticEnabled == true {
            HStack(spacing: 4) {
                Text("Strength")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                ThrottledSlider(
                    value: hapticIntensityBinding,
                    in: 0.1...1.0,
                    step: 0.05,
                    onLiveChange: { liveHaptic = $0 }
                )
                    .frame(width: 60)
                Text(String(format: "%.0f%%", (liveHaptic ?? Double(binding.hapticIntensity ?? 0.6)) * 100))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 30)
            }
        }

        // Speech toggle
        Toggle(isOn: speechBinding) {
            HStack(spacing: 3) {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 8))
                Text("Speak")
                    .font(.system(size: 9))
            }
            .foregroundStyle(.secondary)
        }
        .toggleStyle(.checkbox)
        .controlSize(.mini)
        .help("Speak a phrase out loud when this binding fires.")
    }

    @ViewBuilder
    private var speechDetailRow: some View {
        HStack(spacing: 10) {
            Text("Phrase")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            TextField("Phrase to speak", text: speechTextBinding)
                .textFieldStyle(.roundedBorder)
                .controlSize(.mini)
                .frame(maxWidth: 200)

            Text("Output")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Picker("", selection: speechDestinationBinding) {
                Text("Mac").tag(SpeechDestination.mac)
                Text("Controller").tag(SpeechDestination.controller)
            }
            .labelsHidden()
            .controlSize(.mini)
            .frame(width: 110)
            Spacer()
        }
    }

    @ViewBuilder
    private var advancedAxisOptions: some View {
        // Deadzone
        HStack(spacing: 4) {
            Text("Deadzone")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            ThrottledSlider(
                value: deadzoneBinding,
                in: 0.01...0.9,
                step: 0.01,
                onLiveChange: { liveDeadzone = $0 }
            )
                .frame(width: 70)
            let dzPct = String(format: "%.0f%%", (liveDeadzone ?? Double(binding.deadzone ?? 0.25)) * 100)
            Text(dzPct)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 30)
            // Visible "Calibrate" button. The icon differs for triggers
            // (1D pressure gauge) vs joysticks (2D circle) so the user
            // can tell at a glance which kind of input this binding uses.
            Button {
                showDeadzoneCalibration = true
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: isTriggerAxis ? "gauge.with.dots.needle.50percent" : "dot.circle.and.hand.point.up.left.fill")
                        .font(.system(size: 9))
                    Text("Calibrate")
                        .font(.system(size: 9))
                }
                .foregroundStyle(.tint)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .help(isTriggerAxis
                  ? "Open the trigger pressure calibration view."
                  : "Calibrate the joystick by moving it around in a circle.")
        }

        // Invert
        Toggle(isOn: invertBinding) {
            Text("Invert")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .toggleStyle(.checkbox)
        .controlSize(.mini)

        // Curve
        HStack(spacing: 4) {
            Text("Curve")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Picker("", selection: curveBinding) {
                Text("Linear").tag(SensitivityCurve.linear)
                Text("Smooth").tag(SensitivityCurve.exponential)
                Text("Aggressive").tag(SensitivityCurve.aggressive)
            }
            .labelsHidden()
            .controlSize(.mini)
            .frame(width: 80)
        }

        // Variable Sensitivity (scale output by axis depth)
        Toggle(isOn: variableSensitivityBinding) {
            Text("Variable")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .toggleStyle(.checkbox)
        .controlSize(.mini)
        .help("Scale output speed by how far the joystick or trigger is pushed.")
    }

    @ViewBuilder
    private var advancedModeOptions: some View {
        Toggle(isOn: toggleBinding) {
            Text("Toggle")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .toggleStyle(.checkbox)
        .controlSize(.mini)

        Toggle(isOn: turboBinding) {
            Text("Turbo")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .toggleStyle(.checkbox)
        .controlSize(.mini)

        if binding.turboEnabled == true {
            HStack(spacing: 3) {
                TextField("", value: turboRateBinding, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 36)
                    .controlSize(.mini)
                    .multilineTextAlignment(.center)
                Text("/s")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }

        // Repeat count
        HStack(spacing: 3) {
            Text("Repeat")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            TextField("", value: repeatCountBinding, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 36)
                .controlSize(.mini)
                .multilineTextAlignment(.center)
            Text("×")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }

        if (binding.repeatCount ?? 1) > 1 {
            HStack(spacing: 3) {
                Text("Delay")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                TextField("", value: repeatDelayBinding, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 40)
                    .controlSize(.mini)
                    .multilineTextAlignment(.center)
                Text("ms")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }

        // Macro toggle - opens the macro editor below the row when on.
        // Matches the visual style of the other toggles in this section.
        Toggle(isOn: macroToggleBinding) {
            HStack(spacing: 3) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 8))
                Text("Macro")
                    .font(.system(size: 9))
            }
            .foregroundStyle(binding.macroSteps?.isEmpty == false ? Color.orange : .secondary)
        }
        .toggleStyle(.checkbox)
        .controlSize(.mini)
    }

    /// Bridges the macro toggle to the existing `showMacroEditor` state.
    /// Turning the toggle on opens the editor; turning it off hides it
    /// (but does not delete any existing macro steps).
    private var macroToggleBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { showMacroEditor },
            set: { showMacroEditor = $0 }
        )
    }

    // MARK: - Advanced Bindings

    private var deadzoneBinding: SwiftUI.Binding<Double> {
        SwiftUI.Binding(
            get: { Double(binding.deadzone ?? 0.25) },
            set: { binding.deadzone = Float($0) }
        )
    }

    /// Triggers live on axis indices 4 (left) and 5 (right) by convention.
    /// Used to switch the Calibrate button icon between trigger gauge and
    /// joystick circle styles.
    private var isTriggerAxis: Bool {
        binding.input.type == .axis && (binding.input.index == 4 || binding.input.index == 5)
    }

    /// Like `deadzoneBinding` but always writes the value (even the 0.25 default).
    /// The calibration view always wants to persist what the user picked so the
    /// next time they open the editor the slider matches what they set.
    private var deadzoneCalibrationBinding: SwiftUI.Binding<Double> {
        SwiftUI.Binding(
            get: { Double(binding.deadzone ?? 0.25) },
            set: { binding.deadzone = Float($0) }
        )
    }

    /// Outer deadzone binding for the calibration sheet. Defaults to 1.0
    /// (no saturation), which the view interprets as "no outer ring".
    private var outerDeadzoneBinding: SwiftUI.Binding<Double> {
        SwiftUI.Binding(
            get: { Double(binding.outerDeadzone ?? 1.0) },
            set: { binding.outerDeadzone = $0 >= 0.99 ? nil : Float($0) }
        )
    }

    private var invertBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { binding.invertAxis ?? false },
            set: { binding.invertAxis = $0 ? true : nil }
        )
    }

    private var toggleBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { binding.toggleMode ?? false },
            set: {
                binding.toggleMode = $0 ? true : nil
                if $0 { binding.turboEnabled = nil } // Mutually exclusive
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
            set: { binding.repeatCount = $0 <= 1 ? nil : max(1, min(100, $0)) }
        )
    }

    private var repeatDelayBinding: SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.repeatDelayMs ?? 100 },
            set: { binding.repeatDelayMs = max(10, min(5000, $0)) }
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

    private var hapticBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { binding.hapticEnabled ?? false },
            set: { binding.hapticEnabled = $0 ? true : nil }
        )
    }

    private var hapticIntensityBinding: SwiftUI.Binding<Double> {
        SwiftUI.Binding(
            get: { Double(binding.hapticIntensity ?? 0.6) },
            set: { binding.hapticIntensity = Float($0) }
        )
    }

    private var speechBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { binding.speechEnabled ?? false },
            set: { binding.speechEnabled = $0 ? true : nil }
        )
    }

    private var speechTextBinding: SwiftUI.Binding<String> {
        SwiftUI.Binding(
            get: { binding.speechText ?? "" },
            set: { binding.speechText = $0.isEmpty ? nil : $0 }
        )
    }

    private var speechDestinationBinding: SwiftUI.Binding<SpeechDestination> {
        SwiftUI.Binding(
            get: { binding.speechDestination ?? .mac },
            set: { binding.speechDestination = $0 == .mac ? nil : $0 }
        )
    }

    // MARK: - Macro Editor

    private var macroEditorSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Macro Sequence")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    var steps = binding.macroSteps ?? []
                    steps.append(MacroStep(action: OutputAction(type: .key, keyCode: 4)))
                    binding.macroSteps = steps
                } label: {
                    Label("Add Step", systemImage: "plus.circle")
                        .font(.system(size: 9))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            if let steps = binding.macroSteps, !steps.isEmpty {
                macroStepsList(steps)
            } else {
                Text("No steps. Add steps to create a macro sequence that fires on press.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            Text("Macros override normal outputs. Each step fires in sequence with configurable delays.")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.04)))
    }

    private func macroStepsList(_ steps: [MacroStep]) -> some View {
        VStack(spacing: 3) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                macroStepRow(index: index, step: step)
            }
        }
    }

    private func macroStepRow(index: Int, step: MacroStep) -> some View {
        HStack(spacing: 6) {
            Text("\(index + 1).")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 18)

            Picker("", selection: macroStepTypeBinding(at: index)) {
                ForEach(OutputType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .labelsHidden()
            .controlSize(.mini)
            .frame(width: 100)

            if step.action.type == .key {
                KeyCodePicker(selectedCode: macroStepKeyBinding(at: index))
                    .frame(width: 90)
            } else if step.action.type == .mouseButton {
                Picker("", selection: macroStepMouseBtnBinding(at: index)) {
                    ForEach(0..<6, id: \.self) { i in
                        Text(mouseButtonName(i)).tag(i)
                    }
                }
                .labelsHidden()
                .controlSize(.mini)
                .frame(width: 90)
            }

            HStack(spacing: 2) {
                Text("Wait")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                TextField("", value: macroDelayBinding(at: index), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 36)
                    .controlSize(.mini)
                    .multilineTextAlignment(.center)
                Text("ms")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 2) {
                Text("Hold")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                TextField("", value: macroHoldBinding(at: index), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 36)
                    .controlSize(.mini)
                    .multilineTextAlignment(.center)
                Text("ms")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }

            Button {
                var steps = binding.macroSteps ?? []
                guard index < steps.count else { return }
                steps.remove(at: index)
                binding.macroSteps = steps.isEmpty ? nil : steps
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Spacer()
        }
    }

    // MARK: - Macro Bindings

    private func macroStepTypeBinding(at index: Int) -> SwiftUI.Binding<OutputType> {
        SwiftUI.Binding(
            get: { binding.macroSteps?[index].action.type ?? .key },
            set: {
                guard var steps = binding.macroSteps, index < steps.count else { return }
                steps[index].action.type = $0
                binding.macroSteps = steps
            }
        )
    }

    private func macroStepKeyBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.macroSteps?[index].action.keyCode ?? 4 },
            set: {
                guard var steps = binding.macroSteps, index < steps.count else { return }
                steps[index].action.keyCode = $0
                binding.macroSteps = steps
            }
        )
    }

    private func macroStepMouseBtnBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.macroSteps?[index].action.mouseButtonIndex ?? 0 },
            set: {
                guard var steps = binding.macroSteps, index < steps.count else { return }
                steps[index].action.mouseButtonIndex = $0
                binding.macroSteps = steps
            }
        )
    }

    private func macroDelayBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.macroSteps?[index].delayMs ?? 50 },
            set: {
                guard var steps = binding.macroSteps, index < steps.count else { return }
                steps[index].delayMs = max(0, min(10000, $0))
                binding.macroSteps = steps
            }
        )
    }

    private func macroHoldBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.macroSteps?[index].holdMs ?? 50 },
            set: {
                guard var steps = binding.macroSteps, index < steps.count else { return }
                steps[index].holdMs = max(0, min(10000, $0))
                binding.macroSteps = steps
            }
        )
    }

    // MARK: - Helpers

    /// Compact label used by Menu-style controls so they look like Pickers
    /// but with lazy contents. Shows the current value and a chevron.
    @ViewBuilder
    private func menuLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
        }
    }

    private func outputIcon(for action: OutputAction) -> String {
        switch action.type {
        case .key: return "keyboard"
        case .mouseButton, .mouseMotion, .mouseWheel, .mouseWheelStep: return "computermouse"
        case .midiNote: return "music.note"
        case .midiCC: return "slider.horizontal.3"
        case .midiPitchBend: return "waveform.path"
        case .midiProgramChange: return "guitars"
        case .midiTransport: return "playpause"
        }
    }

    private func outputColor(for action: OutputAction) -> Color {
        switch action.type {
        case .key: return .orange
        case .mouseButton, .mouseMotion, .mouseWheel, .mouseWheelStep: return .purple
        case .midiNote, .midiCC, .midiPitchBend, .midiProgramChange, .midiTransport: return .pink
        }
    }

    private func mouseButtonName(_ index: Int) -> String {
        switch index {
        case 0: return "0 - Main Click"
        case 1: return "1 - Secondary"
        case 2: return "2 - Middle"
        case 3: return "3 - Back"
        case 4: return "4 - Forward"
        case 5: return "5 - Extra"
        default: return "\(index)"
        }
    }

    // MARK: - Bindings

    private var axisDirectionBinding: SwiftUI.Binding<AxisDirection> {
        SwiftUI.Binding(
            get: { binding.input.axisDirection ?? .positive },
            set: { binding.input.axisDirection = $0 }
        )
    }

    private var hatDirectionBinding: SwiftUI.Binding<HatDirection> {
        SwiftUI.Binding(
            get: { binding.input.hatDirection ?? .up },
            set: { binding.input.hatDirection = $0 }
        )
    }

    private var firstOutputTypeBinding: SwiftUI.Binding<OutputType> {
        SwiftUI.Binding(
            get: { binding.outputs.first?.type ?? .key },
            set: { binding.outputs[0].type = $0 }
        )
    }

    private func outputBinding(at index: Int) -> SwiftUI.Binding<OutputAction> {
        SwiftUI.Binding(
            get: { binding.outputs[index] },
            set: { binding.outputs[index] = $0 }
        )
    }

    private func outputTypeBinding(at index: Int) -> SwiftUI.Binding<OutputType> {
        SwiftUI.Binding(
            get: { binding.outputs[index].type },
            set: { binding.outputs[index].type = $0 }
        )
    }

    private func keyCodeBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.outputs[index].keyCode ?? 4 },
            set: { binding.outputs[index].keyCode = $0 }
        )
    }

    private func mouseButtonBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.outputs[index].mouseButtonIndex ?? 0 },
            set: { binding.outputs[index].mouseButtonIndex = $0 }
        )
    }

    private func mouseAxisDirBinding(at index: Int) -> SwiftUI.Binding<String> {
        SwiftUI.Binding(
            get: {
                let axis = binding.outputs[index].mouseAxis?.rawValue ?? 1
                let dir = binding.outputs[index].mouseDirection?.rawValue ?? "-"
                return "\(axis) \(dir)"
            },
            set: { newValue in
                let parts = newValue.split(separator: " ")
                if parts.count >= 2,
                   let axisVal = Int(parts[0]),
                   let axis = MouseAxis(rawValue: axisVal) {
                    binding.outputs[index].mouseAxis = axis
                    binding.outputs[index].mouseDirection = MouseDirection(rawValue: String(parts[1]))
                }
            }
        )
    }

    private func speedBinding(at index: Int) -> SwiftUI.Binding<Double> {
        SwiftUI.Binding(
            get: { Double(binding.outputs[index].speed ?? 6) },
            set: { binding.outputs[index].speed = Int($0) }
        )
    }

    private func speedIntBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.outputs[index].speed ?? 6 },
            set: { binding.outputs[index].speed = max(1, min(50, $0)) }
        )
    }

    /// TextField binding that reads from the live drag mirror so the box
    /// updates while the user is sliding, and writes go to both the mirror
    /// and the underlying preset (so typing into the field still works).
    private func liveSpeedBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: {
                if let live = liveSpeed[index] { return Int(live) }
                return binding.outputs[index].speed ?? 6
            },
            set: { newValue in
                let clamped = max(1, min(50, newValue))
                binding.outputs[index].speed = clamped
                liveSpeed[index] = Double(clamped)
            }
        )
    }

    // MARK: - MIDI Bindings

    private func midiNoteBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.outputs[index].midiNote ?? 60 },
            set: { binding.outputs[index].midiNote = max(0, min(127, $0)) }
        )
    }

    private func midiVelocityBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.outputs[index].midiVelocity ?? 100 },
            set: { binding.outputs[index].midiVelocity = max(0, min(127, $0)) }
        )
    }

    private func midiCCNumberBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.outputs[index].midiCCNumber ?? 1 },
            set: { binding.outputs[index].midiCCNumber = max(0, min(127, $0)) }
        )
    }

    private func midiChannelBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.outputs[index].midiChannel ?? 1 },
            set: { binding.outputs[index].midiChannel = max(1, min(16, $0)) }
        )
    }

    private func midiTransportBinding(at index: Int) -> SwiftUI.Binding<MIDITransport> {
        SwiftUI.Binding(
            get: { binding.outputs[index].midiTransport ?? .start },
            set: { binding.outputs[index].midiTransport = $0 }
        )
    }

    private func removeOutput(at index: Int) {
        withAnimation(.easeInOut(duration: 0.2)) {
            binding.outputs.remove(at: index)
        }
    }
}
