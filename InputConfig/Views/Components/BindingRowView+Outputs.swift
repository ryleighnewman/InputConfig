import SwiftUI
import Combine
import UniformTypeIdentifiers

// BindingRowView, the output side: value controls, extra outputs, the options box and output menus.
// Split from BindingRowView.swift, where the type and its state live, so a Debug build type-checks it
// in parallel with the rest.

extension BindingRowView {
    func setTouchpad(axis: TouchpadAxis, dir: AxisDirection) {
        binding.input.touchpadAxis = axis
        binding.input.axisDirection = dir
    }

    var touchpadFingerBinding: SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.input.touchpadFinger ?? binding.input.index },
            set: { newValue in
                binding.input.touchpadFinger = newValue
                binding.input.index = newValue
            }
        )
    }

    // MARK: - Output Value Controls

    private func appActionKindBinding(at index: Int, in list: OutputList = .main) -> SwiftUI.Binding<AppActionKind> {
        SwiftUI.Binding(
            get: { output(at: index, in: list)?.appActionKind ?? .togglePauseOutputs },
            set: { kind in updateOutput(index, in: list) {
                // Precision's percent is not a spot number, nor the reverse.
                if $0.appActionKind != kind { $0.speed = nil }
                $0.appActionKind = kind
            } }
        )
    }

    private func targetPresetBinding(at index: Int, in list: OutputList = .main) -> SwiftUI.Binding<UUID?> {
        SwiftUI.Binding(
            get: { output(at: index, in: list)?.targetPresetID },
            set: { id in updateOutput(index, in: list) { $0.targetPresetID = id } }
        )
    }

    func outputTextBinding(at index: Int, in list: OutputList = .main) -> SwiftUI.Binding<String> {
        SwiftUI.Binding(
            get: { output(at: index, in: list)?.text ?? "" },
            set: { text in updateOutput(index, in: list) { $0.text = text.isEmpty ? nil : text } }
        )
    }

    /// The controls for one output's value, in any of the row's output
    /// lists: the main action, or the hold or double-tap action.
    @ViewBuilder
    func outputValueControls(at index: Int, in list: OutputList = .main) -> some View {
        // During an animated removal SwiftUI briefly retains the outgoing row
        // with its now-stale index; guard so the output lookups and the
        // per-control get closures never trap on an out-of-range index.
        if let current = output(at: index, in: list) {
            outputValueControlsBody(at: index, current: current, in: list)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func outputValueControlsBody(at index: Int, current: OutputAction, in list: OutputList) -> some View {
        switch current.type {
        case .key:
            // Command or Control among the other outputs: this key, once
            // picked, is sent as a shortcut by its character.
            KeyCodePicker(selectedCode: keyCodeBinding(at: index, in: list),
                          inShortcut: OutputAction.isShortcut(outputs(in: list).enumerated()
                              .filter { $0.offset != index }.map(\.element)))
                .accessibilityLabel("Key")

        case .absoluteVolume:
            // No parameters: the fader simply follows the input's
            // position. Explain the pairing so it isn't a mystery row.
            Text("Volume follows this control's position, 0 to 100%")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize()

        case .systemAction:
            systemActionControls(at: index, in: list)

        case .lightBar:
            lightBarControls(at: index, current: current, in: list)

        case .controllerProfile:
            Picker("Profile action", selection: SwiftUI.Binding(
                get: { current.resolvedProfileAction },
                set: { action in updateOutput(index, in: list) { $0.profileAction = action } })) {
                ForEach(ControllerProfileAction.allCases) { action in
                    Text(action.menuName).tag(action)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 120 * max(1, textScale))
            .hoverHelp("Switches the profile a PlayStation Access controller has active, as its Profile button does. Over USB-C; over Bluetooth the controller takes only its own button.")

        case .typeText:
            TextField("Text to type", text: outputTextBinding(at: index, in: list))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(minWidth: 140)
                .hoverHelp("Typed exactly as written when the input is pressed. Capitals, symbols, and any language work.")

        case .appAction:
            HStack(spacing: 6) {
                Picker("", selection: appActionKindBinding(at: index, in: list)) {
                    ForEach(appActionKinds(for: list)) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                    // A kind from a file this list does not offer still shows.
                    if let kept = current.appActionKind, !appActionKinds(for: list).contains(kept) {
                        Text(kept.displayName).tag(kept)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 160 * max(1, textScale))
                .accessibilityLabel("App action")
                if current.appActionKind == .activatePreset {
                    Picker("", selection: targetPresetBinding(at: index, in: list)) {
                        Text("Choose preset…").tag(UUID?.none)
                        ForEach(availablePresets, id: \.id) { entry in
                            Text(entry.name).tag(UUID?.some(entry.id))
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(minWidth: 130)
                    .accessibilityLabel("Target preset")
                }
                if current.appActionKind == .holdPrecision {
                    TextField("Speed", value: appActionNumberBinding(at: index, in: list, range: 5...90, fallback: 25), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 48 * max(1, textScale))
                        .controlSize(.small)
                        .multilineTextAlignment(.center)
                        .accessibilityLabel("Speed while held, percent")
                        .hoverHelp("Pointer speed while this is held, as a share of normal speed (5 to 90 percent). A Mouse Motion Step keeps its set distance.")
                    fieldLabel("% speed")
                }
                if current.appActionKind == .savePointer || current.appActionKind == .returnPointer {
                    Picker("Spot", selection: appActionNumberBinding(at: index, in: list, range: 1...3, fallback: 1)) {
                        Text("Spot 1").tag(1)
                        Text("Spot 2").tag(2)
                        Text("Spot 3").tag(3)
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityLabel("Pointer spot")
                }
            }

        case .mouseButton:
            // Lazy Menu: only builds the 32 button options when opened.
            SearchableMenu(choices: {
                (0..<32).map { i in
                    MenuSearchChoice(title: mouseButtonName(i)) { updateOutput(index, in: list) { $0.mouseButtonIndex = i } }
                }
            }) {
                ForEach(0..<32, id: \.self) { i in
                    Button(mouseButtonName(i)) {
                        updateOutput(index, in: list) { $0.mouseButtonIndex = i }
                    }
                }
            } label: {
                menuLabel(mouseButtonName(current.mouseButtonIndex ?? 0))
            }
            .menuStyle(.borderlessButton)
            .frame(minWidth: 120)
            .controlSize(.small)
            clickPointControls(at: index, in: list)

        case .mouseMotion, .mouseWheel:
            // Compact horizontal: direction, then slider, then numeric
            // readout. The "Speed" word was previously here as a label but
            // it pushed the row over the editor's minWidth on smaller
            // windows and clipped neighboring columns; the icon-style
            // gauge symbol now hints at what the slider controls without
            // adding meaningful width.
            HStack(spacing: 6) {
                Picker("Pointer direction", selection: mouseAxisDirBinding(at: index, in: list)) {
                    Text("Up").tag("1 -")
                    Text("Right").tag("0 +")
                    Text("Down").tag("1 +")
                    Text("Left").tag("0 -")
                }
                .labelsHidden()
                // Sized to its longest direction: "Nach oben" and "Nach
                // unten" must not both cut to "Nach…".
                .fixedSize()
                .controlSize(.small)

                Image(systemName: "speedometer")
                    .font(.callout)
                    .foregroundStyle(.hint)
                    .accessibilityHidden(true)
                    .fixedSize()
                    .hoverHelp("Output speed")

                ThrottledSlider("Output speed",
                    value: speedBinding(at: index, in: list),
                    in: 1...50,
                    step: 1,
                    onLiveChange: { liveSpeed[liveSpeedKey(index, list)] = $0 }
                )
                    .frame(minWidth: 60, idealWidth: 90)
                    .accessibilityValue(String(localized: "Speed \(Int(speedBinding(at: index, in: list).wrappedValue))"))

                TextField("Speed", value: liveSpeedBinding(at: index, in: list), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56 * max(1, textScale))
                    .controlSize(.small)
                    .multilineTextAlignment(.center)
            }

        case .mouseWheelStep:
            Picker("Pointer direction", selection: mouseAxisDirBinding(at: index, in: list)) {
                Text("Up").tag("1 -")
                Text("Right").tag("0 +")
                Text("Down").tag("1 +")
                Text("Left").tag("0 -")
            }
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)

        case .mouseStep:
            HStack(spacing: 6) {
                Picker("Pointer direction", selection: stepDirectionBinding(get: { output(at: index, in: list) },
                                                                          set: { change in updateOutput(index, in: list, change) })) {
                    stepDirectionChoices
                }
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)

                TextField("Distance", value: stepDistanceBinding(at: index, in: list), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56 * max(1, textScale))
                    .controlSize(.small)
                    .multilineTextAlignment(.center)
                    .hoverHelp("How far the pointer moves on each press, in points (1 to 500).")
                Text("pt")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

        case .midiNote:
            HStack(spacing: 6) {
                fieldLabel("Note")
                // Lazy Menu so the 128 note options only build when opened.
                SearchableMenu(choices: {
                    MIDIService.notePickerLabels.map { entry in
                        MenuSearchChoice(title: entry.label) { updateOutput(index, in: list) { $0.midiNote = entry.number } }
                    }
                }) {
                    ForEach(MIDIService.notePickerLabels, id: \.number) { entry in
                        Button(entry.label) {
                            updateOutput(index, in: list) { $0.midiNote = entry.number }
                        }
                    }
                } label: {
                    let note = current.midiNote ?? 60
                    menuLabel("\(MIDIService.noteName(note)) (\(note))")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 100 * max(1, textScale))
                .controlSize(.small)

                fieldLabel("Vel")
                // A MIDI note row can pass on how hard its key was struck.
                // Not one with hold, double or triple tap actions: its tap
                // fires later as a pulse, past the struck velocity.
                let asPlayedOffered = list == .main && binding.input.type == .midi
                    && (binding.input.midiKind ?? .note) == .note
                    && (binding.holdOutputs ?? []).isEmpty && (binding.doubleTapOutputs ?? []).isEmpty
                    && (binding.tripleTapOutputs ?? []).isEmpty
                    // A stored count counts only where Repeat runs: on a
                    // Toggle row it does not, and the note plays as struck.
                    && !((binding.repeatCount ?? 1) > 1 && repeatApplies && binding.macroSteps?.isEmpty != false)
                if asPlayedOffered {
                    Picker("Velocity", selection: SwiftUI.Binding(
                        get: { current.velocityFromInput == true },
                        set: { asPlayed in updateOutput(index, in: list) { $0.velocityFromInput = asPlayed ? true : nil } })) {
                        Text("As played").tag(true)
                        Text("Fixed").tag(false)
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .hoverHelp("As played sends each note as loud as the key that played it. Fixed always sends the number beside it.")
                }
                // The number shows whenever As played is not in use, so a
                // row whose input stopped being a MIDI note can still set it.
                if current.velocityFromInput != true || !asPlayedOffered {
                    TextField("Velocity", value: midiVelocityBinding(at: index, in: list), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 44 * max(1, textScale))
                        .controlSize(.small)
                        .multilineTextAlignment(.center)
                }

                fieldLabel("Ch")
                Picker("MIDI channel", selection: midiChannelBinding(at: index, in: list)) {
                    ForEach(1...16, id: \.self) { c in
                        Text("\(c)").tag(c)
                    }
                }
                .labelsHidden()
                .frame(width: 50 * max(1, textScale))
                .controlSize(.small)
            }

        case .midiCC:
            HStack(spacing: 6) {
                fieldLabel("CC")
                // Lazy Menu so the 128 CC options only build when opened.
                SearchableMenu(choices: {
                    MIDIService.ccPickerLabels.map { entry in
                        MenuSearchChoice(title: entry.label) { updateOutput(index, in: list) { $0.midiCCNumber = entry.number } }
                    }
                }) {
                    ForEach(MIDIService.ccPickerLabels, id: \.number) { entry in
                        Button(entry.label) {
                            updateOutput(index, in: list) { $0.midiCCNumber = entry.number }
                        }
                    }
                } label: {
                    let cc = current.midiCCNumber ?? 1
                    let label = MIDIService.ccNameByNumber[cc].map { "\(cc): \($0)" } ?? "\(cc)"
                    menuLabel(label)
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                // Flexible, not fixed: at the sheet's minimum width a fixed
                // 160 pushed the whole row past the sheet edge, clipping the
                // section labels on the left and the delete buttons on the
                // right for every row in a MIDI preset.
                .frame(minWidth: 96, idealWidth: 160)
                .controlSize(.small)

                fieldLabel("Ch")
                Picker("MIDI channel", selection: midiChannelBinding(at: index, in: list)) {
                    ForEach(1...16, id: \.self) { c in
                        Text("\(c)").tag(c)
                    }
                }
                .labelsHidden()
                .frame(width: 50 * max(1, textScale))
                .controlSize(.small)

                // A press sends this value (an axis or a MIDI knob follows
                // its own position instead). A hold or double tap action,
                // and the tap of a row that has them, is a press either way.
                let followsPosition = (binding.input.type == .axis || MappingEngine.isContinuousMIDI(binding.input))
                    && list == .main && binding.holdOutputs == nil && binding.doubleTapOutputs == nil && binding.tripleTapOutputs == nil
                if !followsPosition {
                    fieldLabel("Value")
                    TextField("", value: SwiftUI.Binding(
                        get: { current.midiCCValue ?? 127 },
                        set: { v in updateOutput(index, in: list) { $0.midiCCValue = max(0, min(127, v)) } }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 44 * max(1, textScale))
                    .controlSize(.small)
                    .accessibilityLabel("CC value sent on press")
                    .help("The value sent on press; letting go sends 0.")
                }
            }

        case .midiPitchBend:
            HStack(spacing: 6) {
                fieldLabel("Ch")
                Picker("MIDI channel", selection: midiChannelBinding(at: index, in: list)) {
                    ForEach(1...16, id: \.self) { c in
                        Text("\(c)").tag(c)
                    }
                }
                .labelsHidden()
                .frame(width: 50 * max(1, textScale))
                .controlSize(.small)
                Text("Use with a continuous axis for smooth bend.")
                    .font(.callout)
                    .foregroundStyle(.hint)
            }

        case .midiProgramChange:
            HStack(spacing: 6) {
                fieldLabel("Program")
                SearchableMenu(choices: {
                    (0...127).map { (p: Int) in
                        MenuSearchChoice(title: "\(p)") { updateOutput(index, in: list) { $0.midiProgramNumber = p } }
                    }
                }) {
                    ForEach(0...127, id: \.self) { p in
                        Button("\(p)") { updateOutput(index, in: list) { $0.midiProgramNumber = p } }
                    }
                } label: {
                    menuLabel("\(current.midiProgramNumber ?? 0)")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 70)
                .controlSize(.small)

                fieldLabel("Ch")
                Picker("MIDI channel", selection: midiChannelBinding(at: index, in: list)) {
                    ForEach(1...16, id: \.self) { c in
                        Text("\(c)").tag(c)
                    }
                }
                .labelsHidden()
                .frame(width: 50 * max(1, textScale))
                .controlSize(.small)
            }

        case .midiTransport:
            HStack(spacing: 6) {
                fieldLabel("Action")
                Picker("Transport message", selection: midiTransportBinding(at: index, in: list)) {
                    ForEach(MIDITransport.allCases) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                .labelsHidden()
                .frame(width: 100 * max(1, textScale))
                .controlSize(.small)
                Text("Sends a real-time transport message to the DAW.")
                    .font(.callout)
                    .foregroundStyle(.hint)
            }
        }
    }

    // MARK: - Light bar output

    /// A double tap is one short pulse, so its light keeps the color
    /// rather than showing it for a moment (the engine does the same).
    private func lightModes(for list: OutputList) -> [LightOutputMode] {
        list == .doubleTap || list == .tripleTap ? [.set, .rainbowToggle] : LightOutputMode.allCases
    }

    private func lightModeBinding(at index: Int, in list: OutputList) -> SwiftUI.Binding<LightOutputMode> {
        SwiftUI.Binding(
            get: {
                let mode = output(at: index, in: list)?.resolvedLightMode ?? .whileHeld
                return (list == .doubleTap || list == .tripleTap) && mode == .whileHeld ? .set : mode
            },
            set: { mode in updateOutput(index, in: list) { $0.lightMode = mode } }
        )
    }

    private func lightColorBinding(at index: Int, in list: OutputList) -> SwiftUI.Binding<Color> {
        SwiftUI.Binding(
            get: {
                let c = output(at: index, in: list)?.resolvedLightColor ?? OutputAction.defaultLightColor
                return Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
            },
            set: { value in
                let ns = NSColor(value).usingColorSpace(.sRGB) ?? NSColor(value)
                let rgb = RGBLightColor(floatR: Float(ns.redComponent),
                                        floatG: Float(ns.greenComponent),
                                        floatB: Float(ns.blueComponent))
                updateOutput(index, in: list) { $0.lightColor = rgb }
            }
        )
    }

    /// A colored dot for a swatch menu item. Menus draw SF Symbols as
    /// templates, so the dot is drawn into a plain image instead.
    private static func swatchDot(_ c: RGBLightColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255,
                    blue: CGFloat(c.b) / 255, alpha: 1).setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Mode, then (unless it is the rainbow) the color: a color well and
    /// the light bar picker's named swatches.
    @ViewBuilder
    private func lightBarControls(at index: Int, current: OutputAction, in list: OutputList) -> some View {
        HStack(spacing: 6) {
            Picker("Light bar mode", selection: lightModeBinding(at: index, in: list)) {
                ForEach(lightModes(for: list)) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 130 * max(1, textScale))

            if current.resolvedLightMode != .rainbowToggle {
                ColorPicker("", selection: lightColorBinding(at: index, in: list), supportsOpacity: false)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel("Light bar color")

                SearchableMenu(choices: {
                    RGBLightColor.namedSwatches.map { swatch in
                        MenuSearchChoice(title: swatch.name) { updateOutput(index, in: list) { $0.lightColor = swatch.color } }
                    }
                }) {
                    ForEach(RGBLightColor.namedSwatches, id: \.name) { swatch in
                        Button {
                            updateOutput(index, in: list) { $0.lightColor = swatch.color }
                        } label: {
                            Label {
                                Text(swatch.name)
                            } icon: {
                                Image(nsImage: Self.swatchDot(swatch.color))
                            }
                        }
                    }
                } label: {
                    let c = current.resolvedLightColor
                    menuLabel(c.isNamedSwatch ? c.nearestName : String(localized: "Custom"))
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .frame(width: 84 * max(1, textScale))
                .accessibilityLabel("Light bar swatches")
            } else {
                Text("Speed follows the rainbow setting")
                    .font(.callout)
                    .foregroundStyle(.hint)
                    .fixedSize()
            }
        }
        .hoverHelp("Only a DualSense or DualShock 4 has a color light bar. The color goes to this row's controller; a keyboard, mouse or MIDI row colors every light bar.")
    }

    // MARK: - Secondary Outputs

    @ViewBuilder
    var secondaryOutputRows: some View {
        if binding.outputs.count > 1 {
            ForEach(Array(binding.outputs.enumerated().dropFirst()), id: \.element.id) { index, output in
                secondaryOutputRow(index: index, output: output)
            }
        }
    }

    /// One output line under the first: "+", icon, type menu, value
    /// controls and a remove button. The extra actions' editors are built
    /// from these too, every line of them, including the first: it has no
    /// "+" (nothing comes before it) and no remove button while it is the
    /// only output, the same as the main row's first output.
    func secondaryOutputRow(index: Int, output: OutputAction, in list: OutputList = .main) -> some View {
        let current = self.output(at: index, in: list)
        let removable = index > 0 || outputs(in: list).count > 1
        return HStack(spacing: gap) {
            Text(index > 0 ? "+" : "")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(index == 0)

            HStack(spacing: gap) {
                outputIconCell(for: output)

                outputMenu(select: { outputTypeBinding(at: index, in: list).wrappedValue = $0 },
                           selectSystemKind: { kind in
                               updateOutput(index, in: list) {
                                   $0.type = .systemAction
                                   $0.systemActionKind = kind
                               }
                           },
                           setParameter: { text in
                               updateOutput(index, in: list) { $0.text = text }
                           },
                           setAppAction: { kind, presetID in
                               updateOutput(index, in: list) {
                                   $0.type = .appAction
                                   $0.appActionKind = kind
                                   $0.speed = nil
                                   $0.targetPresetID = presetID
                               }
                           },
                           setKey: { code in
                               updateOutput(index, in: list) {
                                   $0.type = .key
                                   $0.keyCode = code
                               }
                           },
                           keyInShortcut: OutputAction.isShortcut(outputs(in: list).enumerated()
                               .filter { $0.offset != index }.map(\.element)),
                           list: list) {
                    menuChevronLabel(current.map(outputMenuTitle) ?? OutputType.key.displayName)
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .accessibilityLabel("Output type")
                .accessibilityValue(current.map(outputMenuTitle) ?? OutputType.key.displayName)
                .accessibilityInputLabels([Text(current.map(outputMenuTitle) ?? OutputType.key.displayName), Text("Output type")])
            }
            .frame(width: outTypeColWidth, alignment: .leading)

            outputValueControls(at: index, in: list)

            if removable {
                Button {
                    removeOutput(at: index, in: list)
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove this output")
            }

            Spacer(minLength: 0)
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// An output's icon in a fixed cell, scaled to fit it. SF Symbols vary
    /// a lot in width, and letting each one take its natural size put the
    /// menu after a wide symbol visibly further right than after a narrow
    /// one; the cell makes the icon-to-menu distance the same on every row.
    func outputIconCell(for output: OutputAction) -> some View {
        Image(systemName: outputIcon(for: output))
            .resizable()
            .scaledToFit()
            .foregroundStyle(outputColor(for: output))
            .frame(width: iconCell - 4, height: 13)
            .frame(width: iconCell, height: 18)
            // The menu beside it names the output.
            .accessibilityHidden(true)
    }

    // MARK: - Advanced Section

    var advancedSection: some View {
        #if DEBUG
        if RowA11yProbe.sink != nil {
            RowA11yProbe.record(binding.id, [("optionsValue", showAdvanced ? String(localized: "Expanded")
                                                : (advancedOptionsSummary.isEmpty ? String(localized: "Collapsed") : advancedOptionsSummary)),
                                             ("optionsBold", hasAdvancedOptions ? "yes" : "no"),
                                             ("optionsText", hasAdvancedOptions ? advancedOptionsSummary : optionsHint)])
        }
        #endif
        return VStack(alignment: .leading, spacing: 0) {
            // The button comes first so it stays put; the panel unfolds
            // below it.
            HStack {
                Button {
                    toggleOptions()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.forward")
                            .font(.callout)
                            // Turned to point down when open. SwiftUI mirrors
                            // the rotation in right-to-left too, so 90 is right
                            // for the forward chevron both ways.
                            .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                        Text("Options")
                            .font(.callout)
                    }
                    // Teal, the app icon's own family: apart from the blue
                    // links and the purple Automation; bold once something
                    // in it is set.
                    .foregroundStyle(Self.optionsTeal)
                    .fontWeight(hasAdvancedOptions ? .semibold : .regular)
                    .fixedSize()
                }
                .buttonStyle(.plain)
                // Open or closed, and what is set, for VoiceOver: the chevron's
                // turn and the summary beside it are visual only.
                .accessibilityLabel("Options")
                .accessibilityInputLabels([Text("Options"), Text("Options \(displayNumber)")])
                .accessibilityValue(showAdvanced ? String(localized: "Expanded")
                                    : (advancedOptionsSummary.isEmpty ? String(localized: "Collapsed") : advancedOptionsSummary))
                .accessibilityHint("Shows this row's deadzone, press mode, macro, feedback and extra actions")
                // Collapsed summary of WHICH options are set, replacing the
                // old bare asterisk that said only that something was; with
                // nothing set, what opening it offers, in parentheses.
                if !showAdvanced {
                    Text(hasAdvancedOptions ? advancedOptionsSummary : optionsHint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // Part of the button's target: a click on the
                        // summary opens Options too. The button above is
                        // what VoiceOver reads.
                        .contentShape(Rectangle())
                        .onTapGesture { toggleOptions() }
                        .accessibilityHidden(true)
                }
                Spacer()
            }
            // Options starts in the number column, directly under "#n" and
            // the "Notes" label, so the three lines of a row share one edge.
            .padding(.leading, dragWidth + colGap)
            .padding(.top, 4)

            if showAdvanced {
                advancedOptionsRow
                    // Full width on purpose: the left column sits under the
                    // row's Input column and the right under its Output.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 12)
                    .padding(.top, 6)
                    // The row's clip shape trims the panel while it slides
                    // out from under the button, so opening reads as a fold.
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    /// Animated open and close. Only the drag handle folds the panel
    /// without animation, because it must be instant for the reorder to
    /// start on the right frame.
    func toggleOptions() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            showAdvanced.toggle()
        }
    }

    // MARK: - Advanced Options

    private var hasAdvancedOptions: Bool {
        !binding.modifiers.isEmpty ||
        binding.deadzone != nil || binding.invertAxis == true || fullTravelShown || fromNeutralShown ||
        binding.toggleMode == true || binding.turboEnabled == true ||
        binding.sensitivityCurve != nil || (binding.repeatCount ?? 1) > 1 ||
        (binding.macroSteps?.isEmpty == false) ||
        binding.variableSensitivity != nil || (binding.rampMs ?? 0) > 0 ||
        binding.holdOutputs != nil || binding.doubleTapOutputs != nil || binding.tripleTapOutputs != nil ||
        binding.hapticEnabled == true || binding.speechEnabled == true ||
        binding.outerDeadzone != nil ||
        (binding.keyRepeat == true && showsKeyRepeatToggle) || (binding.blockOriginal == true && showsBlockOriginalToggle) ||
        (binding.blockOriginal == true && showsBlockKeyToggle) ||
        (binding.blockOriginal == true && showsBlockSequenceToggle) ||
        (binding.blockHeldControls == true && !blockableHeldControls.isEmpty) ||
        (binding.input.type == .stickRegion && binding.zoneSharesStick == false)
    }

    /// What Options holds for this kind of row, shown beside the closed
    /// disclosure while nothing is set, so the row says what it can do.
    /// System teal is about 2.4:1 on a light card, short of the 4.5:1 body
    /// text needs; light appearances get a deeper teal (about 5:1), dark
    /// ones keep the system color.
    static let optionsTeal = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .systemTeal
            : NSColor(srgbRed: 0, green: 0.42, blue: 0.48, alpha: 1)
    })

    private var optionsHint: String {
        switch binding.input.type {
        case .axis, .motion:
            // The row's own default: a gyro pointer row works at 5%, not 25%.
            let pct = Int(((binding.deadzone.map(Double.init) ?? defaultDeadzone) * 100).rounded())
            return pct == 25 ? String(localized: "(open to edit the deadzone, 25% now, sensitivity and inversion)")
                : String(localized: "(open to edit the deadzone, \(pct)% now, sensitivity and inversion)")
        default:
            return String(localized: "(open to edit how it fires; a macro, feedback and extra actions are in the output menu)")
        }
    }

    /// One-line summary of the configured advanced options, shown next to
    /// the collapsed disclosure. Built from the same fields
    /// `hasAdvancedOptions` checks.
    private var advancedOptionsSummary: String {
        var parts: [String] = []
        if let dz = binding.deadzone {
            parts.append(String(localized: "Deadzone \(Int((dz * 100).rounded()))%"))
        } else if binding.input.type == .axis {
            // Shown at the default too, so the setting is visible without opening Options.
            parts.append(String(localized: "Deadzone 25%"))
        }
        if binding.invertAxis == true { parts.append(String(localized: "Inverted")) }
        if let full = binding.outerDeadzone, binding.input.type == .axis {
            parts.append(String(localized: "Full push at \(Int((full * 100).rounded()))%"))
        }
        if binding.input.type == .stickRegion, binding.zoneSharesStick == false {
            parts.append(isBandRow ? String(localized: "Takes over the control") : String(localized: "Takes over the stick"))
        }
        if binding.keyRepeat == true, showsKeyRepeatToggle { parts.append(String(localized: "Repeats keys")) }
        if binding.blockOriginal == true, showsBlockOriginalToggle { parts.append(String(localized: "Blocks the button")) }
        if binding.blockOriginal == true, showsBlockKeyToggle { parts.append(String(localized: "Blocks the key")) }
        if binding.blockOriginal == true, showsBlockSequenceToggle { parts.append(String(localized: "Blocks its keys")) }
        if binding.blockHeldControls == true, !blockableHeldControls.isEmpty { parts.append(String(localized: "Blocks the held control")) }
        if !zoneTakenBy.isEmpty {
            parts.append(String(localized: "Waits in region of \(zoneTakenBy.map { "#\($0)" }.joined(separator: ", "))"))
        }
        if fullTravelShown { parts.append(String(localized: "Whole travel")) }
        if fromNeutralShown { parts.append(String(localized: "From the grip")) }
        if let curve = binding.sensitivityCurve, curve != .linear {
            parts.append(curve == .exponential ? String(localized: "Smooth curve") : String(localized: "Aggressive curve"))
        }
        if binding.variableSensitivity == true { parts.append(String(localized: "Variable")) }
        if let r = binding.rampMs, r > 0 { parts.append(String(format: String(localized: "Ramp-up %.3g s"), locale: .current, Double(r) / 1000)) }
        if !binding.modifiers.isEmpty {
            parts.append(String(localized: "With \(binding.modifiers.map { modifierName($0) }.joined(separator: " + "))"))
        }
        if binding.toggleMode == true && binding.turboEnabled == true {
            parts.append(String(localized: "Auto every \(turboIntervalMs) ms"))
        } else {
            if binding.toggleMode == true { parts.append(String(localized: "Toggle")) }
            if binding.turboEnabled == true { parts.append(String(localized: "Every \(turboIntervalMs) ms")) }
        }
        if let n = binding.turboMaxCount, n > 0, binding.turboEnabled == true { parts.append(String(localized: "\(n)x then stop")) }
        // A looping macro ignores the count: until pressed again is the end.
        if (binding.repeatCount ?? 1) > 1, repeatApplies, binding.macroLoop != true { parts.append(String(localized: "Repeat x\(binding.repeatCount ?? 1)")) }
        if let steps = binding.macroSteps, !steps.isEmpty {
            parts.append(steps.count == 1 ? String(localized: "Macro 1 step") : String(localized: "Macro \(steps.count) steps"))
        }
        if let hold = binding.holdOutputs, !hold.isEmpty {
            parts.append(String(localized: "Hold \(OutputAction.names(hold).joined(separator: " + "))"))
        }
        if let double = binding.doubleTapOutputs, !double.isEmpty {
            parts.append(String(localized: "2x \(OutputAction.names(double).joined(separator: " + "))"))
        }
        if let triple = binding.tripleTapOutputs, !triple.isEmpty {
            parts.append(String(localized: "3x \(OutputAction.names(triple).joined(separator: " + "))"))
        }
        if binding.hapticEnabled == true {
            if let ms = binding.hapticDurationMs, ms >= FeedbackService.transientCutoffMs {
                parts.append(String(localized: "Vibrate \(hapticDurationLabel(Double(ms)))"))
            } else {
                parts.append(String(localized: "Vibrate"))
            }
        }
        if binding.speechEnabled == true { parts.append(String(localized: "Speak")) }
        return parts.joined(separator: ", ")
    }

    /// Where the row's arrow sits, measured from the row's left edge; the
    /// options divider goes exactly under it.
    private var arrowCenterX: CGFloat {
        let boxEnd: CGFloat = BindingRowView.inputBoxLeading(scale: textScale) + BindingRowView.inputBoxWidth(scale: textScale)
        let half: CGFloat = BindingRowView.arrowSlotWidth / 2
        // The column constants overshoot the arrow's real center by 15 pt
        // (the input box lays out narrower than the sum of its column
        // widths). Measured off a render: arrow at 1185 px, divider at 1215,
        // at 1.97 px per point.
        return boxEnd + half - 15
    }

    /// The row's small live picture, the way into the full Adjust live
    /// sheet. Follows the sliders while they move.
    private var rowPreview: some View {
        MiniDeadzonePreview(
            axisIndex: binding.input.type == .stickRegion ? zoneRowAxis : binding.input.index,
            direction: binding.input.type == .axis ? binding.input.axisDirection : nil,
            bothWays: binding.input.type == .axis && binding.input.axisDirection == nil && !isTriggerAxis,
            inner: liveDeadzone ?? Double(binding.deadzone.map(Double.init) ?? defaultDeadzone),
            outer: liveOuterDeadzone ?? Double(binding.outerDeadzone ?? 1.0),
            isInverted: binding.invertAxis == true,
            slot: slot,
            zoneID: binding.input.type == .stickRegion ? binding.input.stickRegionID : nil,
            fullTravel: binding.fullTravel == true
        ) {
            showDeadzoneCalibration = true
        }
    }

    private var advancedOptionsRow: some View {
        // Two columns under the row's own Input and Output headings, split by
        // a divider that sits on the row's arrow: how the control is read on
        // the left, what the row sends on the right.
        let leftWidth = max(220, arrowCenterX - optionsInset - 0.5)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) { inputSideOptions }
                    .frame(width: leftWidth - 16, alignment: .leading)
                    .padding(.trailing, 16)
                Divider()
                VStack(alignment: .leading, spacing: 8) { outputSideOptions }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, Self.arrowSlotWidth / 2 + 4)
            }
        }
        .padding(.leading, optionsInset)
    }

    /// Repeat keys while held, and Block the button's own action, where
    /// each applies. Shown in the stick options and, for buttons, keys,
    /// mouse buttons and every other press input, in their own Press box:
    /// living only in the stick options, neither was reachable on the rows
    /// that need them most.
    private var showsKeyRepeatToggle: Bool {
        binding.toggleMode != true && binding.turboEnabled != true && binding.macroSteps == nil
            && (binding.outputs + (binding.holdOutputs ?? [])).contains(where: { output in
                // A key that can repeat: not a modifier, and an ordinary key
                // (media, volume, brightness and Globe keys never repeat).
                output.type == .key && output.keyCode.map {
                    !(224...231).contains($0) && KeyCodeMap.hidToVirtualKeyCode[$0] != nil
                } == true
            })
    }

    private var showsBlockOriginalToggle: Bool {
        // Only Any mouse or the Mac's own: the engine blocks nothing on a
        // row set to one particular mouse.
        binding.input.type == .extMouse && [.button, .doubleClick].contains(binding.input.extMouseKind ?? .button)
            && binding.input.index >= 2
            && [nil, "any", ExternalInputDeviceService.builtInMouseID].contains(binding.input.extDeviceID)
    }

    /// An ordinary key on any keyboard (or the Mac's own): modifiers and
    /// media keys are never held back, and a row set to one particular
    /// keyboard cannot be told apart by the tap.
    private var showsBlockKeyToggle: Bool {
        binding.input.type == .extKey
            && MappingEngine.keyCanBlock(binding.input.index)
            && [nil, "any", ExternalInputDeviceService.builtInKeyboardID].contains(binding.input.extDeviceID)
            && MappingEngine.chordIsReadable(binding.modifiers)
    }

    /// A key sequence with at least one key the tap can hold back.
    private var showsBlockSequenceToggle: Bool {
        binding.input.type == .keySequence
            && (binding.input.sequenceSteps ?? []).contains(where: MappingEngine.keyCanBlock)
            && MappingEngine.chordIsReadable(binding.modifiers)
    }

    /// Block a key sequence's keys: typing them only plays the sequence.
    @ViewBuilder
    private var blockSequenceToggle: some View {
        Toggle(isOn: blockOriginalBinding) {
            Text("Block the keys' own actions")
                .font(.callout)
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .hoverHelp("While this preset runs, apps stop seeing the keys in this sequence, so typing them only plays it. Each key is held back even outside a finished sequence, since a key cannot be known to start one until the next arrives. With a Second control, only while that control is held. Stop the preset and the keys work as usual. Modifier keys are never held back, and a password field always gets the keys.")
        blockCaption(sequenceBlockNames, on: binding.blockOriginal == true, chord: true)
    }

    /// The keys of this row's sequence the block covers, once each.
    private var sequenceBlockNames: [String] {
        var seen = Set<Int>()
        return (binding.input.sequenceSteps ?? []).filter { MappingEngine.keyCanBlock($0) && seen.insert($0).inserted }
            .map { KeyCodeMap.name(for: $0) }
    }

    /// Under a block toggle: what it does, in the control's own name.
    /// `chord`: the block follows the row's Second control, so the line
    /// says it holds only while that control is held.
    func blockCaption(_ names: [String], on: Bool, chord: Bool = false) -> some View {
        let list = LocalizedList.and(names)
        // A pad's Second control cannot be read from the tap: a mouse row
        // then blocks on every press.
        let held = chord && MappingEngine.chordIsReadable(binding.modifiers) ? binding.modifiers.map { modifierName($0) } : []
        let text: String
        if on, held.count == 1 {
            text = String(localized: "Other apps do not see \(list) while \(LocalizedList.and(held)) is held.", comment: "Under a block toggle that is on; a key or button name, then the held control")
        } else if on, held.count > 1 {
            text = String(localized: "Other apps do not see \(list) while \(LocalizedList.and(held)) are held.", comment: "Under a block toggle that is on; a key or button name, then the held controls")
        } else if on {
            text = String(localized: "Other apps do not see \(list) while this preset runs.", comment: "Under a block toggle that is on; a key or button name, or a list of them")
        } else if names.count == 1 {
            text = String(localized: "\(list) also does its own action in other apps.", comment: "Under a block toggle that is off; one key or button name")
        } else {
            text = String(localized: "\(list) also do their own actions in other apps.", comment: "Under a block toggle that is off; a list of key names")
        }
        return Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 20)
    }

    /// The row's Second control keys and buttons that can be held back.
    var blockableHeldControls: [InputEvent] {
        binding.modifiers.filter(MappingEngine.heldControlCanBlock)
    }

    @ViewBuilder
    var pressRowToggles: some View {
        // Held keys repeat like a real key. Offered where it can apply: a
        // plain press row with a non-modifier key among its outputs.
        if showsKeyRepeatToggle {
            Toggle(isOn: keyRepeatBinding) {
                Text("Repeat keys while held")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .hoverHelp("Like holding a key on a keyboard: after a moment the key repeats, at the speed set in System Settings, Keyboard. Off, a held key stays down as one press, which games expect.")
        }

        // Block the original: middle and side mouse buttons only, so a
        // bound side button stops also going Back in a browser. Main and
        // secondary click are never offered, so a click can't be lost.
        if showsBlockOriginalToggle {
            Toggle(isOn: blockOriginalBinding) {
                Text("Block the button's own action")
                    .font(.callout)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .hoverHelp("While this preset runs, apps stop seeing this button, so it does only what this row says. A side button no longer also goes Back in a browser. With a Second control that is a key or mouse button, the button is held back only while that control is held; with a controller button, it is held back on every press. Stop the preset and the button works as usual.")
            blockCaption([binding.input.displayName], on: binding.blockOriginal == true, chord: true)
        }

        // Block the key: an ordinary key on any keyboard, so W mapped to
        // Up Arrow no longer also types W. Modifiers are never offered.
        if showsBlockKeyToggle {
            Toggle(isOn: blockOriginalBinding) {
                Text("Block the key's own action")
                    .font(.callout)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .hoverHelp("While this preset runs, apps stop seeing this key, so it does only what this row says: W mapped to Up Arrow no longer also types W. With a Second control, the key is held back only while that control is held. Stop the preset and the key works as usual. Modifier keys are never held back, a key pressed with Command, Control or Option passes through unless the Second control is that key, and a password field always gets the key.")
            blockCaption([binding.input.displayName], on: binding.blockOriginal == true, chord: true)
        }

    }

    /// Left column: everything about reading the control.
    @ViewBuilder
    private var inputSideOptions: some View {
        if binding.input.type == .motion {
            optionsBox("Motion") {
                MotionRowPanel(
                    slot: slot,
                    channel: binding.input.motionChannel ?? .gyroY,
                    direction: binding.input.axisDirection,
                    invert: binding.invertAxis ?? false,
                    deadzone: liveDeadzone ?? binding.deadzone.map(Double.init)
                        ?? (MappingEngine.drivesPointer(binding) ? 0.05 : MappingEngine.motionSwitchDeadzone),
                    fromNeutral: binding.fromNeutral == true,
                    drivesPointer: MappingEngine.drivesPointer(binding))
                advancedAxisOptions
            }
        } else if binding.input.type == .axis {
            optionsBox(isTriggerAxis ? "Trigger" : "Stick") {
                HStack(alignment: .top, spacing: 12) {
                    rowPreview
                    VStack(alignment: .leading, spacing: 8) { advancedAxisOptions }
                }
            }
        } else if binding.input.type == .stickRegion {
            optionsBox(isBandRow ? "Band" : "Stick region") {
                HStack(alignment: .top, spacing: 12) {
                    if !isBandRow { rowPreview }
                    VStack(alignment: .leading, spacing: 8) {
                        zoneSharingOptions
                        advancedAxisOptions
                    }
                }
            }
        } else if binding.input.type == .stickGesture {
            optionsBox("Stick gesture") { stickGestureOptions }
        } else if binding.input.type == .buttonSequence {
            optionsBox("Button sequence") { buttonSequenceOptions }
        } else if binding.input.type == .keySequence {
            optionsBox("Key sequence") {
                VStack(alignment: .leading, spacing: 8) {
                    buttonSequenceOptions
                    if showsBlockSequenceToggle { blockSequenceToggle }
                }
            }
        } else if binding.input.type == .touchpad {
            optionsBox("Finger movement") { advancedAxisOptions }
        }
        if ![.motion, .axis, .stickRegion, .stickGesture, .buttonSequence, .keySequence, .touchpad].contains(binding.input.type),
           showsKeyRepeatToggle || showsBlockOriginalToggle || showsBlockKeyToggle {
            optionsBox("Press") {
                VStack(alignment: .leading, spacing: 8) { pressRowToggles }
            }
        }
        // Calibration and zones are for a PlayStation touchpad; a Steam
        // Controller's pads report their edges already, and zones are on the
        // main surface only.
        if [.touchpad, .touchpadRegion, .touchpadGesture].contains(binding.input.type),
           binding.input.touchpadSurface != 1, presetButtonFamily?.isSteam != true {
            optionsBox("Touchpad") {
                HStack(spacing: 10) {
                    Text("Draw tap regions on the touchpad; each one works like a button.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    TouchpadRegionsButton { showZones(.touchpad) }
                }
            }
        }
        if binding.input.type == .chassisTap {
            optionsBox("Tap the Mac") {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Watch your knocks on a live trace and set how firm a tap has to be. The setting is shared by every preset.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(Self.tapTheMacDisclaimer)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    TapCalibrateButton()
                }
            }
        }
        // Keyboard and mouse rows too: Scan takes a key or button from any
        // device, so Left Command can gate a middle click.
        if binding.input.type != .midi {
            optionsBox("Second control") { modifierPicker }
        }
        // A direction row can wait for a region of its own stick or trigger.
        if binding.input.type == .axis, gateRegionKey != nil {
            optionsBox("Region") { regionGatePicker }
        }
    }

    /// Right column: everything about what the row sends.
    @ViewBuilder
    private var outputSideOptions: some View {
        optionsBox("How it fires") { pressBehaviorOptions }
        // Each box below shows only when the row does that thing; the
        // output menu is where a macro, feedback or an extra action is
        // chosen, and choosing one opens its box here.
        if macroEditorShown {
            optionsBox("Macro", spotlightID: "macro") { macroEditorSection }
        }
        if binding.hapticEnabled == true || binding.speechEnabled == true {
            optionsBox("Feedback", spotlightID: "feedback") {
                advancedFeedbackOptions
                if binding.speechEnabled == true {
                    speechDetailRow
                }
            }
        }
        // Last, because a full output editor can open inside it.
        if binding.holdOutputs != nil || binding.doubleTapOutputs != nil || binding.tripleTapOutputs != nil {
            optionsBox("Extra actions", spotlightID: "extra") { tapHoldOptions }
        }
    }

    /// Opens Options and points at the box a choice just turned on.
    func spotlight(_ box: String) {
        showAdvanced = true
        spotlightGlow = nil
        spotlightBox = box
    }

    /// One area of the Options panel: its title at the top-left and its
    /// controls inside one rounded box, so each area reads as a unit
    /// instead of a run of headings and hairlines.
    private func optionsBox<Content: View>(_ title: LocalizedStringKey, spotlightID: String? = nil,
                                           @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.12), lineWidth: 1))
        .overlay {
            if let spotlightID, spotlightGlow == spotlightID {
                OptionsSpotlight(sweeps: !reduceMotion) {
                    if spotlightGlow == spotlightID { spotlightGlow = nil }
                }
            }
        }
        .background(ScrollIntoViewAnchor(active: spotlightID != nil && spotlightBox == spotlightID) {
            spotlightBox = nil
            spotlightGlow = spotlightID
        })
    }

    /// A short label beside a parameter field. Fixed so it never wraps
    /// letter-by-letter when the output column gets narrow.
    func fieldLabel(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.hint)
            .fixedSize()
            .lineLimit(1)
    }

    @ViewBuilder
    private var advancedFeedbackOptions: some View {
        // Haptic toggle
        Toggle(isOn: hapticBinding) {
            HStack(spacing: 3) {
                Image(systemName: "waveform")
                    .font(.callout)
                    .accessibilityHidden(true)
                Text("Vibrate")
                    .font(.callout)
            }
            .foregroundStyle(.secondary)
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .hoverHelp("Vibrate the controller when this binding fires (DualSense, DualSense Edge, and similar).")

        if binding.hapticEnabled == true {
            HStack(spacing: 4) {
                Text("Strength")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ThrottledSlider("Vibration strength",
                    value: hapticIntensityBinding,
                    in: 0.1...1.0,
                    step: 0.05,
                    onLiveChange: { liveHaptic = $0 }
                )
                    .frame(width: 60)
                    .accessibilityValue(String(localized: "\(Int(((liveHaptic ?? Double(binding.hapticIntensity ?? 0.6)) * 100).rounded())) percent"))
                    .voiceNames("Strength", "Vibration strength")
                percentField("Strength percent",
                             shown: liveHaptic ?? Double(binding.hapticIntensity ?? 0.6),
                             range: 0.1...1.0, style: .hint, width: 30) {
                    liveHaptic = $0
                    hapticIntensityBinding.wrappedValue = $0
                }
            }
            HStack(spacing: 4) {
                Text("Duration")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ThrottledSlider("Vibration duration",
                    value: hapticDurationBinding,
                    in: 0...Double(FeedbackService.maxDurationMs),
                    step: 20,
                    onLiveChange: { liveHapticDuration = $0 }
                )
                    .frame(width: 60)
                    .accessibilityValue(spokenHapticDuration(liveHapticDuration ?? Double(binding.hapticDurationMs ?? FeedbackService.defaultDurationMs)))
                    .voiceNames("Duration", "Vibration duration")
                Text(hapticDurationLabel(liveHapticDuration ?? Double(binding.hapticDurationMs ?? FeedbackService.defaultDurationMs)))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.hint)
                    // Room for "Tap" and the unit in every language.
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: 44, alignment: .leading)
            }
            .hoverHelp("Tap is a single short pulse. Longer settings rumble for that long, up to two seconds.")
        }

        // Speech toggle
        Toggle(isOn: speechBinding) {
            HStack(spacing: 3) {
                Image(systemName: "speaker.wave.2")
                    .font(.callout)
                    .accessibilityHidden(true)
                Text("Speak")
                    .font(.callout)
            }
            .foregroundStyle(.secondary)
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .hoverHelp("Speak a phrase out loud when this binding fires.")
    }

    @ViewBuilder
    private var speechDetailRow: some View {
        HStack(spacing: 10) {
            Text("Phrase")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Phrase to speak", text: speechTextBinding)
                .focused($phraseFocused)
                .voiceNames("Phrase", "Phrase to speak")
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(maxWidth: 200)

            // No Mac / Controller picker: macOS has no public way to send
            // speech to a controller's speaker, so it always follows the
            // Mac's sound output and the choice did nothing.
            Spacer()
        }
    }

    /// What an extra action can send. A double tap is one short pulse, so
    /// pointer motion and continuous scrolling would do nothing there; a
    /// hold runs them every poll while held. The volume fader follows the
    /// control's position, so it belongs to the main action only, and Pause
    /// Motion While Held is read from the row's main outputs only. A light
    /// bar color suits every list (a double tap's keeps its color, see
    /// lightModes(for:)), so it is offered everywhere.
    private func offersOutputType(_ type: OutputType, in list: OutputList) -> Bool {
        // A hold keeps moving or scrolling while held (the engine runs a
        // held action's pointer motion every poll); a double tap is a
        // single pulse, so it has no motion to give.
        list == .main || (list == .hold && type != .absoluteVolume)
            || ![.mouseMotion, .mouseWheel, .absoluteVolume].contains(type)
    }

    private func appActionKinds(for list: OutputList) -> [AppActionKind] {
        // The held gates act only while the row's own input is held.
        list == .main ? AppActionKind.allCases : AppActionKind.allCases.filter { $0 != .holdMuteMotion && $0 != .holdEnableMotion && $0 != .holdPrecision }
    }

    /// Output-type menu grouped Keyboard / Mouse / MIDI / App, so keyboard-
    /// and-mouse users stop wading through DAW terminology on every choice.
    /// Shared by the primary and secondary output menus and the extra
    /// actions' menus, which leave out what a hold or double tap cannot
    /// send; built lazily on open like KeyCodePicker, so rows render
    /// without pre-building it.
    @ViewBuilder
    private func outputTypeMenuItems(select: @escaping (OutputType) -> Void,
                                     selectSystemKind: @escaping (SystemActionKind) -> Void,
                                     setParameter: @escaping (String) -> Void = { _ in },
                                     setAppAction: @escaping (AppActionKind, UUID?) -> Void = { _, _ in },
                                     setKey: @escaping (Int) -> Void = { _ in },
                                     keyInShortcut: Bool = false,
                                     list: OutputList = .main) -> some View {
        // A macro is what the row sends, so it is an output to pick.
        if list == .main {
            Section("Macro") {
                Button("Macro, a sequence of steps") { makeMacroOutput() }
            }
        }
        Section("Keyboard") {
            Menu(OutputType.key.displayName) {
                Button("Choose on the row\u{2026}") { select(.key) }
                Divider()
                ForEach(KeyCodeMap.groups, id: \.self) { group in
                    Menu(group) {
                        ForEach(KeyCodeMap.allKeys.filter { $0.group == group }) { key in
                            Button(KeyCodeMap.outputName(for: key.code, inShortcut: keyInShortcut)) { setKey(key.code) }
                                .accessibilityLabel(HotKeySpec.spokenKey(KeyCodeMap.outputName(for: key.code, inShortcut: keyInShortcut)))
                        }
                    }
                }
            }
            Button(OutputType.typeText.displayName) { select(.typeText) }
        }
        Section("Mouse") {
            Button(OutputType.mouseButton.displayName) { select(.mouseButton) }
            if offersOutputType(.mouseMotion, in: list) {
                Button(OutputType.mouseMotion.displayName) { select(.mouseMotion) }
            }
            if offersOutputType(.mouseWheel, in: list) {
                Button(OutputType.mouseWheel.displayName) { select(.mouseWheel) }
            }
            Button(OutputType.mouseWheelStep.displayName) { select(.mouseWheelStep) }
            Button(OutputType.mouseStep.displayName) { select(.mouseStep) }
        }
        // MIDI and the System functions open as submenus: listed in full
        // the menu ran taller than a laptop screen and its last entries
        // (Open App, Open URL, Run Siri Shortcut) sat below the bottom.
        Section("MIDI") {
            Menu("MIDI Output") {
                Button(OutputType.midiNote.displayName) { select(.midiNote) }
                Button(OutputType.midiCC.displayName) { select(.midiCC) }
                Button(OutputType.midiPitchBend.displayName) { select(.midiPitchBend) }
                Button(OutputType.midiProgramChange.displayName) { select(.midiProgramChange) }
                Button(OutputType.midiTransport.displayName) { select(.midiTransport) }
            }
        }
        Section("App") {
            Menu(OutputType.appAction.displayName) {
                ForEach(appActionKinds(for: list)) { kind in
                    if kind == .activatePreset {
                        Menu(kind.displayName) {
                            if availablePresets.isEmpty {
                                Text("No other presets yet")
                            } else {
                                ForEach(availablePresets, id: \.id) { entry in
                                    Button(entry.name) { setAppAction(kind, entry.id) }
                                }
                            }
                        }
                    } else {
                        Button(kind.displayName) { setAppAction(kind, nil) }
                    }
                }
            }
        }
        // Feedback and the extra actions belong to the whole row, so only
        // the main action's menus offer them.
        if list == .main {
            Section("Feedback") {
                // A row can do nothing but vibrate or speak: the engine fires
                // feedback on every press whether or not the row has outputs.
                Button(vibrateChoiceTitle) { turnOnVibrate() }
                Button(speakChoiceTitle) { turnOnSpeech() }
            }
            // Same rules as the Options panel: hold and double tap work on a
            // plain row (not toggle or repeat, not a macro), and a macro takes
            // over the row. These shortcuts used to make rows that did nothing.
            Section("Extra actions") {
                let hasMacro = binding.macroSteps?.isEmpty == false
                Button("Different action when held\u{2026}") { addHoldAction() }
                    .disabled(hasMacro || neverHeld)
                Button("Action on a double tap\u{2026}") { addDoubleTapAction() }
                    .disabled(hasMacro)
                Button("Action on a triple tap\u{2026}") { addTripleTapAction() }
                    .disabled(hasMacro)
            }
        }
        // Every list may color the light: a hold shows it while held, and a
        // double tap keeps it (see lightModes(for:)).
        if offersOutputType(.lightBar, in: list) {
            Section("Controller") {
                Button {
                    select(.lightBar)
                } label: {
                    Label(OutputType.lightBar.displayName, systemImage: "light.beacon.max.fill")
                }
                Button {
                    select(.controllerProfile)
                } label: {
                    Label(OutputType.controllerProfile.displayName, systemImage: "person.crop.rectangle.stack")
                }
            }
        }
        Section("System") {
            if offersOutputType(.absoluteVolume, in: list) {
                Button(OutputType.absoluteVolume.displayName) { select(.absoluteVolume) }
            }
            Menu(OutputType.systemAction.displayName) {
                ForEach(SystemActionKind.grouped, id: \.category) { group in
                    Menu(group.category) {
                        // Run Shortcut and Open App pick the action here; the
                        // Shortcut or app is chosen beside the output. Every
                        // row's menu used to hold every installed app and
                        // Shortcut, thousands of menu items built for each row,
                        // which slowed the editor's open and its first scroll.
                        ForEach(group.kinds) { kind in
                            Button {
                                selectSystemKind(kind)
                            } label: {
                                Label(kind.displayName, systemImage: kind.iconName)
                            }
                        }
                    }
                }
            }
        }
    }

    private var vibrateChoiceTitle: String {
        binding.hapticEnabled == true ? String(localized: "Vibrate (on)") : String(localized: "Vibrate the controller")
    }

    private var speakChoiceTitle: String {
        binding.speechEnabled == true ? String(localized: "Speak a phrase (on)") : String(localized: "Speak a phrase")
    }

    private func turnOnVibrate() {
        binding.hapticEnabled = true
        if binding.hapticIntensity == nil { binding.hapticIntensity = 0.6 }
        spotlight("feedback")
    }

    private func turnOnSpeech() {
        binding.speechEnabled = true
        spotlight("feedback")
    }

    private func addHoldAction() {
        binding.toggleMode = nil
        binding.turboEnabled = nil
        if binding.holdOutputs?.isEmpty != false {
            binding.holdOutputs = [OutputAction(type: .key, keyCode: 41)]
        }
        if binding.holdThresholdMs == nil { binding.holdThresholdMs = 300 }
        openExtraActions()
    }

    private func addDoubleTapAction() {
        binding.toggleMode = nil
        binding.turboEnabled = nil
        if binding.doubleTapOutputs?.isEmpty != false {
            binding.doubleTapOutputs = [OutputAction(type: .key, keyCode: 40)]
        }
        if binding.doubleTapWindowMs == nil { binding.doubleTapWindowMs = 300 }
        openExtraActions()
    }

    private func addTripleTapAction() {
        binding.toggleMode = nil
        binding.turboEnabled = nil
        if binding.tripleTapOutputs?.isEmpty != false {
            binding.tripleTapOutputs = [OutputAction(type: .key, keyCode: 40)]
        }
        if binding.doubleTapWindowMs == nil { binding.doubleTapWindowMs = 300 }
        openExtraActions()
    }

    /// The Macro choice in the output menu: the row's output becomes its
    /// macro. A key or button it sent becomes the first step.
    private func makeMacroOutput() {
        startMacro()
        showMacroEditor = true
        binding.outputs = []
    }

    /// Any other choice in a macro row's output menu: the macro goes, and
    /// the row sends that instead (Undo brings the steps back).
    func leaveMacroOutput() {
        binding.macroSteps = nil
        binding.macroInterruptOnRelease = nil
        binding.macroLoop = nil
        showMacroEditor = false
        // Its unapplied Text lines go with the macro, as a deleted row's do:
        // held, Save's first button put the macro back over the key picked.
        resetMacroTextPane()
    }

    func resetMacroTextPane() {
        macroTextParseTask?.cancel()
        macroText = ""
        macroTextWritten = ""
        macroTextBaseSteps = nil
        macroTextResult = nil
        macroTextNote = nil
        EditorInlineEdit.dropPane(binding.id)
    }

    private func startMacro() {
        if binding.macroSteps?.isEmpty != false {
            // A step presses a key or a button; any other first
            // output would make a step that does nothing.
            // A shortcut row (Command + C) keeps its modifiers on the step,
            // and every other key or button it sent becomes a step of its
            // own: the first key alone was kept and the rest dropped.
            let pressable = binding.outputs.filter { $0.type == .key || $0.type == .mouseButton }
            let isModifier: (OutputAction) -> Bool = { $0.type == .key && (224...231).contains($0.keyCode ?? 0) }
            let mods = pressable.filter(isModifier).compactMap(\.keyCode)
            let rest = pressable.filter { !isModifier($0) }
            if rest.isEmpty {
                let seed = pressable.first ?? OutputAction(type: .key, keyCode: 44)
                binding.macroSteps = [MacroStep(action: seed)]
            } else {
                binding.macroSteps = rest.map {
                    MacroStep(action: $0, modifiers: $0.type == .key && !mods.isEmpty ? mods : nil)
                }
            }
            binding.holdOutputs = nil
            binding.doubleTapOutputs = nil
            binding.tripleTapOutputs = nil
            binding.turboEnabled = nil
        }
        spotlight("macro")
    }

    /// An output dropdown: the grouped menu, with Search over all of it.
    func outputMenu<MenuLabel: View>(select: @escaping (OutputType) -> Void,
                                             selectSystemKind: @escaping (SystemActionKind) -> Void,
                                             setParameter: @escaping (String) -> Void = { _ in },
                                             setAppAction: @escaping (AppActionKind, UUID?) -> Void = { _, _ in },
                                             setKey: @escaping (Int) -> Void = { _ in },
                                             keyInShortcut: Bool = false,
                                             list: OutputList = .main,
                                             @ViewBuilder label: @escaping () -> MenuLabel) -> some View {
        SearchableMenu(choices: {
            outputSearchChoices(select: select, selectSystemKind: selectSystemKind, setAppAction: setAppAction,
                                setKey: setKey, keyInShortcut: keyInShortcut, list: list)
        }) {
            outputTypeMenuItems(select: select, selectSystemKind: selectSystemKind, setParameter: setParameter,
                                setAppAction: setAppAction, setKey: setKey, keyInShortcut: keyInShortcut, list: list)
        } label: {
            label()
        }
    }

    /// Everything outputTypeMenuItems offers, nested choices included, in
    /// its order, for the dropdown's Search.
    private func outputSearchChoices(select: @escaping (OutputType) -> Void,
                                     selectSystemKind: @escaping (SystemActionKind) -> Void,
                                     setAppAction: @escaping (AppActionKind, UUID?) -> Void,
                                     setKey: @escaping (Int) -> Void,
                                     keyInShortcut: Bool,
                                     list: OutputList) -> [MenuSearchChoice] {
        typealias C = MenuSearchChoice
        var out: [C] = []
        let keyboard = String(localized: "Keyboard")
        let keyMenu = C.path(keyboard, OutputType.key.displayName)
        out.append(C(title: OutputType.key.displayName, path: keyboard) { select(.key) })
        for group in KeyCodeMap.groups {
            for key in KeyCodeMap.keysByGroup[group] ?? [] {
                let name = KeyCodeMap.outputName(for: key.code, inShortcut: keyInShortcut)
                out.append(C(title: name, path: C.path(keyMenu, group),
                             keywords: key.name + " " + HotKeySpec.spokenKey(name)) { setKey(key.code) })
            }
        }
        out.append(C(title: OutputType.typeText.displayName, path: keyboard) { select(.typeText) })
        let mouse = String(localized: "Mouse")
        for type in [OutputType.mouseButton, .mouseMotion, .mouseWheel, .mouseWheelStep, .mouseStep] where offersOutputType(type, in: list) {
            out.append(C(title: type.displayName, path: mouse) { select(type) })
        }
        let midi = String(localized: "MIDI")
        for type in [OutputType.midiNote, .midiCC, .midiPitchBend, .midiProgramChange, .midiTransport] {
            out.append(C(title: type.displayName, path: midi) { select(type) })
        }
        let appMenu = C.path(String(localized: "App"), OutputType.appAction.displayName)
        for kind in appActionKinds(for: list) {
            if kind == .activatePreset {
                for entry in availablePresets {
                    out.append(C(title: entry.name, path: C.path(appMenu, kind.displayName)) { setAppAction(kind, entry.id) })
                }
            } else {
                out.append(C(title: kind.displayName, path: appMenu) { setAppAction(kind, nil) })
            }
        }
        if list == .main {
            let feedback = String(localized: "Feedback")
            out.append(C(title: vibrateChoiceTitle, path: feedback) { turnOnVibrate() })
            out.append(C(title: speakChoiceTitle, path: feedback) { turnOnSpeech() })
            let extra = String(localized: "Extra actions")
            let hasMacro = binding.macroSteps?.isEmpty == false
            if !hasMacro && !neverHeld {
                out.append(C(title: String(localized: "Different action when held\u{2026}"), path: extra) { addHoldAction() })
            }
            if !hasMacro {
                out.append(C(title: String(localized: "Action on a double tap\u{2026}"), path: extra) { addDoubleTapAction() })
                out.append(C(title: String(localized: "Action on a triple tap\u{2026}"), path: extra) { addTripleTapAction() })
            }
            out.append(C(title: String(localized: "Macro, a sequence of steps"), path: String(localized: "Macro")) { makeMacroOutput() })
        }
        if offersOutputType(.lightBar, in: list) {
            out.append(C(title: OutputType.lightBar.displayName, path: String(localized: "Controller"),
                         systemImage: "light.beacon.max.fill") { select(.lightBar) })
            out.append(C(title: OutputType.controllerProfile.displayName, path: String(localized: "Controller"),
                         systemImage: "person.crop.rectangle.stack") { select(.controllerProfile) })
        }
        let system = String(localized: "System")
        if offersOutputType(.absoluteVolume, in: list) {
            out.append(C(title: OutputType.absoluteVolume.displayName, path: system) { select(.absoluteVolume) })
        }
        for group in SystemActionKind.grouped {
            for kind in group.kinds {
                out.append(C(title: kind.displayName, path: C.path(system, group.category),
                             systemImage: kind.iconName) { selectSystemKind(kind) })
            }
        }
        return out
    }
}
