import SwiftUI
import Combine
import UniformTypeIdentifiers

// BindingRowView, the row's layout and its note line. Split from BindingRowView.swift, where the type
// and its state live, so a Debug build type-checks it in parallel with the rest.

extension BindingRowView {
    var rowBody: some View {
        #if DEBUG
        if RowA11yProbe.sink != nil {
            RowA11yProbe.record(binding.id, [("row", rowAccessibilityLabel), ("type", typeMenuTitle),
                                             ("indexLabel", indexPickerAccessibilityLabel), ("indexValue", indexPickerAccessibilityValue),
                                             ("directionLabel", directionPickerAccessibilityLabel),
                                             ("directionValue", directionPickerAccessibilityValue),
                                             ("output", binding.outputs.first.map { outputMenuTitle($0) } ?? "")])
        }
        #endif
        return VStack(alignment: .leading, spacing: 0) {
            // Primary row
            HStack(spacing: colGap) {
                // Drag handle, far left so the row reads handle, number, then
                // the binding itself. This is the only drag source on the
                // row, so menus and text never start a drag by accident.
                // A direct drag gesture, not `.onDrag`. An NSItemProvider drag
                // hands the reorder to AppKit's drag session: the pointer gets
                // a small snapshot of the handle instead of the row, and every
                // reorder decision has to round-trip through a DropDelegate,
                // which is what made dragging feel heavy and detached. The
                // gesture lets the parent lift the whole row under the pointer
                // and move it in place.
                Image(systemName: "line.3.horizontal")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: dragWidth, height: 22)
                    .contentShape(Rectangle())
                    .overlay(
                        // An AppKit tracking view, not a SwiftUI DragGesture.
                        // Two reasons. A SwiftUI gesture is torn down whenever
                        // the row's body re-runs, so anything that changes the
                        // row mid-drag - folding its Options away, the list
                        // reordering - silently cancels the drag and the row
                        // is left stranded. And SwiftUI reports translation in
                        // a space that moves with the row we are offsetting,
                        // which makes the reading feed on its own output and
                        // the row shake. This view persists across body
                        // updates and measures against the screen.
                        RowDragHandle(
                            onBegan: {
                                if showAdvanced {
                                    var t = Transaction()
                                    t.disablesAnimations = true
                                    withTransaction(t) { showAdvanced = false }
                                }
                            },
                            onChanged: { onDragChanged?($0) },
                            onEnded: { onDragEnded?() }
                        )
                    )
                    .help("Drag to reorder")
                    .accessibilityLabel("Reorder handle")
                    .accessibilityHint("Drag to reorder, or use Move Up and Move Down")
                    // Without dragging: a right-click menu (pointer, dwell and
                    // Voice Control), the arrow keys once focused (keyboard),
                    // and actions (VoiceOver, Switch Control).
                    .contextMenu {
                        Button("Move Up") { onMove?(-1) }
                        Button("Move Down") { onMove?(1) }
                        // The macro as the Text pane writes it, for a
                        // message or a note, without opening the row.
                        if binding.macroSteps?.isEmpty == false {
                            Button("Copy macro as text") { copyMacroText() }
                        }
                    }
                    .focusable(onMove != nil)
                    .onKeyPress(.upArrow) { onMove?(-1); return onMove == nil ? .ignored : .handled }
                    .onKeyPress(.downArrow) { onMove?(1); return onMove == nil ? .ignored : .handled }
                    .accessibilityAction(named: "Move Up") { onMove?(-1) }
                    .accessibilityAction(named: "Move Down") { onMove?(1) }

                // Row number chip - matches the number shown in the Live
                // Visualizer popover so users can find the right row when
                // they click an input on the visualizer.
                if displayNumber > 0 {
                    Text("#\(displayNumber)")
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.12))
                        )
                        .frame(width: numberColWidth, alignment: .leading)
                }

                // Non-color firing cue: the green highlight alone isn't
                // distinguishable with Differentiate Without Color on, so add
                // a bolt while the row is firing. VoiceOver hears the firing
                // state from the Input box's value, hence the hidden marker.
                if isHighlighted && differentiateWithoutColor {
                    Image(systemName: "bolt.fill")
                        .font(.callout)
                        .iconTint(.green)
                        .accessibilityHidden(true)
                }

                // INPUT box: scan + type + index + direction, enclosed so
                // the row reads as "this input" -> "these outputs".
                HStack(spacing: gap) {
                // COL 1: Scan
                Button("Scan", action: onScan)
                    .buttonStyle(.solidSecondaryCompact)
                    .frame(width: scanColWidth, alignment: .center)
                    .focused($keyboardFocus)
                    .accessibilityLabel("Scan binding \(displayNumber)")
                    .accessibilityInputLabels([Text("Scan"), Text("Scan binding \(displayNumber)")])
                    .accessibilityHint("Press a button, key, or axis on your controller to record this binding")

                // COL 2: Input Type. A lazy Menu (matching KeyCodePicker and
                // the index picker) instead of Picker: NSPopUpButton-backed
                // Pickers pre-build every item on row creation, which made
                // scrolling the binding list hitch as rows materialized.
                // Grouped so the first decision on every row is no longer an
                // undifferentiated 11-item list.
                SearchableMenu(choices: { inputTypeSearchChoices }) {
                    Section("Controller") {
                        inputTypeChoice(.button)
                        inputTypeChoice(.axis)
                        inputTypeChoice(.hat)
                        inputTypeChoice(.stickGesture)
                        inputTypeChoice(.buttonSequence)
                    }
                    Section("Touchpad") {
                        inputTypeChoice(.touchpad)
                        inputTypeChoice(.touchpadRegion)
                        inputTypeChoice(.touchpadGesture)
                    }
                    // Not offered where it cannot work, but a row already on
                    // it keeps its own choice in the menu.
                    if TapTheMac.canOffer || binding.input.type == .chassisTap {
                        Section("This Mac") {
                            inputTypeChoice(.chassisTap)
                        }
                    }
                    Section("Motion") {
                        inputTypeChoice(.motion)
                    }
                    Section("Keyboard and mouse") {
                        inputTypeChoice(.extKey)
                        inputTypeChoice(.extMouse)
                        inputTypeChoice(.keySequence)
                    }
                    // Stick zones and trigger bands are part of an axis, picked
                    // in the axis menu; a screen region is its own input.
                    Section("Screen") {
                        inputTypeChoice(.cursorRegion)
                        inputTypeChoice(.screenPixel)
                        inputTypeChoice(.screenText)
                    }
                    Section("Voice") {
                        inputTypeChoice(.voicePhrase)
                    }
                    Section("MIDI") {
                        inputTypeChoice(.midi)
                    }
                } label: {
                    menuChevronLabel(typeMenuTitle)
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .frame(width: typeColWidth, alignment: .leading)
                .accessibilityLabel("Input type")
                .accessibilityValue(typeMenuTitle)
                // Voice Control answers to the word shown first.
                .accessibilityInputLabels([Text(typeMenuTitle), Text("Input type"),
                                           Text("Input type \(displayNumber)")])

                // COL 3: Index
                indexPicker
                    .frame(width: indexColWidth, alignment: .leading)
                    .accessibilityLabel(indexPickerAccessibilityLabel)
                    .accessibilityValue(indexPickerAccessibilityValue)
                    .accessibilityInputLabels([Text(indexPickerAccessibilityValue), Text(indexPickerAccessibilityLabel)])

                // COL 4: Direction (or empty spacer for Button type)
                directionPicker
                    .frame(width: dirColWidth, alignment: .leading)
                    .accessibilityLabel(directionPickerAccessibilityLabel)
                    .accessibilityValue(directionPickerAccessibilityValue)
                    .accessibilityInputLabels([Text(directionPickerAccessibilityValue), Text(directionPickerAccessibilityLabel)])

                }
                .padding(.horizontal, Self.boxPadH)
                .padding(.vertical, Self.boxPadV)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Input")
                .accessibilityValue(isHighlighted ? String(localized: "Firing") : "")

                // Fixed-position arrow right after the input columns. The two
                // flexible `maxWidth: .infinity` halves that used to center it
                // forced SwiftUI to renegotiate each row's width with repeated
                // sizeThatFits probes; on a large preset that pegged the main
                // thread solid. Only the output side stays flexible now, so the
                // row lays out in a single pass.
                firingArrow

                // OUTPUT box: icon + type + value, with any extra outputs
                // stacked beneath inside the same box. Row actions sit
                // outside it at the trailing edge.
                VStack(alignment: .leading, spacing: 4) {
                // A macro row's output is its macro: said first, so a row
                // can be the macro alone, with outputs only if wanted too.
                // An older row can hold a macro and outputs together: the
                // macro first, the outputs under it as what else is sent.
                if macroEditorShown && !binding.outputs.isEmpty {
                    macroOutputChip
                    Text("Also sent on the same press:")
                        .font(.caption)
                        .foregroundStyle(.hint)
                        .padding(.leading, 16 + gap)
                }
                HStack(spacing: gap) {
                if binding.outputs.isEmpty && macroEditorShown {
                    macroOutputLine
                } else if binding.outputs.isEmpty {
                    // A row laid out by "every control" waits here for its
                    // output; picking one creates it with that type's
                    // defaults, and the normal controls take over.
                    outputMenu(select: { type in
                            var action = OutputAction(type: .key, keyCode: 4)
                            action.type = type
                            action.fillDefaultsForType()
                            binding.outputs = [action]
                        }, selectSystemKind: { kind in
                            var action = OutputAction(type: .systemAction, keyCode: 4)
                            action.systemActionKind = kind
                            binding.outputs = [action]
                        }, setParameter: { text in
                            guard !binding.outputs.isEmpty else { return }
                            binding.outputs[0].text = text
                        }, setAppAction: { kind, presetID in
                            var action = OutputAction(type: .appAction)
                            action.appActionKind = kind
                            action.targetPresetID = presetID
                            binding.outputs = [action]
                        }, setKey: { code in
                            binding.outputs = [OutputAction(type: .key, keyCode: code)]
                        }) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle")
                            Text(macroEditorShown ? String(localized: "Also send an output") : String(localized: "Choose an output"))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .font(.callout)
                        .foregroundStyle(macroEditorShown ? Color.secondary : Color.accentColor)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityLabel(macroEditorShown ? "Also send an output" : "Choose an output")
                }
                if !binding.outputs.isEmpty {
                    HStack(spacing: gap) {
                        outputIconCell(for: binding.outputs[0])

                        outputMenu(select: { firstOutputTypeBinding.wrappedValue = $0 },
                                   selectSystemKind: { kind in
                                       guard !binding.outputs.isEmpty else { return }
                                       binding.outputs[0].type = .systemAction
                                       binding.outputs[0].systemActionKind = kind
                                   },
                                   setParameter: { text in
                                       guard !binding.outputs.isEmpty else { return }
                                       binding.outputs[0].text = text
                                   },
                                   setAppAction: { kind, presetID in
                                       guard !binding.outputs.isEmpty else { return }
                                       binding.outputs[0].type = .appAction
                                       binding.outputs[0].appActionKind = kind
                                       // Speed means percent or spot here; a new
                                       // action starts at its own default.
                                       binding.outputs[0].speed = nil
                                       binding.outputs[0].targetPresetID = presetID
                                   },
                                   setKey: { code in
                                       guard !binding.outputs.isEmpty else { return }
                                       binding.outputs[0].type = .key
                                       binding.outputs[0].keyCode = code
                                   },
                                   keyInShortcut: OutputAction.isShortcut(Array(binding.outputs.dropFirst()))) {
                            menuChevronLabel(outputMenuTitle(binding.outputs[0]))
                        }
                        .menuStyle(.borderlessButton)
                        .controlSize(.small)
                        .accessibilityLabel("Output type")
                        .accessibilityValue(outputMenuTitle(binding.outputs[0]))
                        .accessibilityInputLabels([Text(outputMenuTitle(binding.outputs[0])), Text("Output type"),
                                                   Text("Output type \(displayNumber)")])
                    }
                    .frame(width: outTypeColWidth, alignment: .leading)

                    // Output value (flexible)
                    outputValueControls(at: 0)

                    // The last output can go too on a macro row: the macro
                    // is then the whole row.
                    if binding.outputs.count > 1 || macroEditorShown {
                        Button {
                            if binding.outputs.count > 1 { removeOutput(at: 0) } else { binding.outputs = [] }
                        } label: {
                            Image(systemName: "xmark.circle")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove this output")
                    }
                }
                Spacer(minLength: 0)
                }
                secondaryOutputRows
                if !binding.outputs.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            binding.outputs.append(OutputAction(type: .key, keyCode: 4))
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle")
                            Text("Add another output")
                        }
                        .font(.callout)
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 16 + gap)
                    .padding(.top, 2)
                    .accessibilityLabel("Add output")
                    .accessibilityInputLabels([Text("Add output"), Text("Add output \(displayNumber)")])
                }
                }
                .padding(.horizontal, Self.boxPadH)
                .padding(.vertical, Self.boxPadV)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Output")

                // Actions: copy and delete. Adding an output is a labeled
                // button under the outputs, not a corner icon.
                HStack(spacing: 3) {
                    if let onDuplicate {
                        CopyIconButton(action: onDuplicate,
                                       helpText: "Duplicate this binding",
                                       announcement: nil)
                            .accessibilityLabel("Duplicate this binding")
                    }

                    Button(action: onRemove) {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red.opacity(0.7))
                            .font(.callout)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove binding")
                    .accessibilityInputLabels([Text("Remove binding"), Text("Remove binding \(displayNumber)")])
                }
                .frame(width: actionsWidth + 18, alignment: .trailing)
            }

            // Tap the Mac reads a sensor only some MacBooks have; the row says so.
            if binding.input.type == .chassisTap {
                HStack(alignment: .firstTextBaseline, spacing: colGap) {
                    Color.clear.frame(width: numberColWidth, height: 1)
                    Text(Self.tapTheMacDisclaimer)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 3)
            }

            // Advanced options
            advancedSection

            // Per-binding note: a short line describing what this control
            // does, under Options so the mapping and its options read as
            // one block. Smart presets auto-fill it; users can edit or add
            // their own.
            noteRow
                .padding(.top, 5)
                .padding(.bottom, 1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHighlighted ? Color.green.opacity(0.18) : Color(nsColor: .controlBackgroundColor).opacity(0.45))
                // Instant fade-in (so quick taps feel snappy), longer fade-out (so the
// green dwell tracks the latched visibility period from
// GameControllerService.rawActiveExpiry).
.animation(isHighlighted ? .linear(duration: 0.0) : .easeOut(duration: 0.18),
           value: isHighlighted)
        )
        .overlay(
            // A hairline edge makes each row its own box even when the fill
            // is close to the sheet behind it.
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isHighlighted ? Color.green.opacity(0.4) : Color.primary.opacity(0.09),
                              lineWidth: isHighlighted ? 1.5 : 1)
                // Instant fade-in (so quick taps feel snappy), longer fade-out (so the
// green dwell tracks the latched visibility period from
// GameControllerService.rawActiveExpiry).
.animation(isHighlighted ? .linear(duration: 0.0) : .easeOut(duration: 0.18),
           value: isHighlighted)
        )
        .overlay(
            // Jump-to-binding highlight after a click on the Live Visualizer
            // or a search result: a solid yellow ring over a yellow wash,
            // eased in quickly, held while the row is the target, and faded
            // out slowly so the eye lands on it.
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.yellow.opacity(isPulsing ? 0.18 : 0))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.yellow.opacity(isPulsing ? 1 : 0), lineWidth: 3))
                .allowsHitTesting(false)
                .animation(isPulsing ? .easeIn(duration: 0.2) : .easeOut(duration: 1.1), value: isPulsing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .debugExpandOptions($showAdvanced)
        .modifier(DebugToggleOptionsModifier(displayNumber: displayNumber, toggle: toggleOptions, adjustLive: { showDeadzoneCalibration = true }))
        .sheet(isPresented: $showDeadzoneCalibration) {
            DeadzoneCalibrationView(
                axisIndex: binding.input.type == .stickRegion ? zoneRowAxis : binding.input.index,
                deadzone: deadzoneCalibrationBinding,
                outerDeadzone: outerDeadzoneBinding,
                isInverted: binding.invertAxis ?? false,
                onClose: { showDeadzoneCalibration = false },
                slot: slot,
                rowID: binding.id,
                zonesKey: zonesSheetKey,
                direction: binding.input.type == .axis ? binding.input.axisDirection : nil,
                fullTravel: binding.fullTravel == true,
                regionID: binding.input.type == .stickRegion ? binding.input.stickRegionID : nil
            )
            .glassBackground()
        }
        // The group's Regions section sends you back here.
        .modifier(RevealRowOnRequest(rowID: binding.id))
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name("InputConfig.ExpandBindingOptions"))) { note in
            // Tutorial / external trigger to auto-expand this row's
            // Options disclosure so the user sees what's inside
            // without having to click. Notification's object is the
            // target binding's UUID; we only react if it matches us.
            if let id = note.object as? UUID, id == binding.id {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.4)) { showAdvanced = true }
            }
        }
        // The live mirrors only follow a drag. Once the row's committed
        // values change (a release, Undo, Stick settings) or Options
        // closes, drop them so a readout never shows an old value.
        .onChange(of: binding) { _, _ in clearLiveMirrors() }
        .onChange(of: showAdvanced) { _, open in if !open { clearLiveMirrors() } }
        .onDisappear {
            // Cancel any in-flight scan when this row goes away.
            // Without this, closing the editor mid-scan leaves the
            // static timer/subscription alive; when its 5-second
            // deadline fires it writes into a `@Binding` whose source
            // is gone, routing the keypress to a stale preset draft.
            // Only the row that is scanning: any other row leaving the
            // list (scrolled away, collapsed) must not end its scan.
            if Self.activeScanRowID == binding.id { Self.cancelActiveScan() }
            // The rows sit in a plain VStack, so this is the editor closing
            // (or the row deleted), not a scroll. A Play once count or chain
            // that outlived the editor typed and clicked into the front app
            // with its Stop button gone; a pointer count wrote into a draft
            // that was discarded.
            if macroPlayCountdown > 0 || macroPlaying { stopMacroPlayOnce(stopChain: true, tearDown: true) }
            cancelMacroPointPick()
            // A fixed-point count too: it went on after the editor closed
            // and said "Spot set" for a spot written into a discarded draft.
            clickPointToken = nil
            clickPointLeft = nil
            clickPointTarget = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: EmergencyStopService.stoppedNotification)
            .receive(on: DispatchQueue.main)) { _ in
            // The emergency stop bumps the engine generation, but a count
            // still waiting read nothing from the engine and played anyway.
            if macroPlayCountdown > 0 { stopMacroPlayOnce(stopChain: false) }
            // Cut by the stop, not finished: said so when the watch ends.
            if macroPlaying { macroStopRequested = true }
        }
        // Undo after Output, Macro: the steps went and the outputs came
        // back, and the row still showed "Macro, no steps yet".
        .onChange(of: binding.macroSteps == nil) { _, gone in if gone { showMacroEditor = false; resetMacroTextPane() } }
        // The row's input picked onto one of its own held controls, from any
        // menu: dropped from the chord, as Scan and the chord menu do.
        .onChange(of: binding.input.serialized) { _, input in
            let kept = binding.modifiers.filter { $0.serialized != input }
            if kept.count != binding.modifiers.count { binding.setModifiers(kept) }
        }
        .onChange(of: binding.outputs.isEmpty) { _, empty in
            if !empty, binding.macroSteps?.isEmpty != false { showMacroEditor = false }
        }
    }


    /// A button or key sequence, which the app does not call a gesture.
    var isPressSequence: Bool { [.buttonSequence, .keySequence].contains(binding.input.type) }

    var rowAccessibilityLabel: String {
        let input = MappingEngine.spokenInputName(binding.input, family: presetButtonFamily)
        let count = binding.macroSteps?.count ?? 0
        // A macro and outputs on one row: both play, so both are said.
        let macroPart = count == 1 ? String(localized: "Macro, 1 step") : String(localized: "Macro, \(count) steps")
        let names = OutputAction.names(binding.outputs).map(HotKeySpec.spokenKey).joined(separator: " + ")
        let outputs = !binding.outputs.isEmpty ? (count > 0 ? "\(macroPart), \(names)" : names)
            : count == 1 ? String(localized: "Macro, 1 step") : count > 0 ? String(localized: "Macro, \(count) steps") : String(localized: "nothing bound")
        return String(localized: "Row \(displayNumber), \(input) to \(outputs)")
    }

    // MARK: - Per-binding note

    /// Bridges the optional `binding.note` to a non-optional String the
    /// TextField can edit. Writing an all-whitespace value clears it back to
    /// nil so empty notes don't bloat the saved preset.
    private var noteBinding: SwiftUI.Binding<String> {
        // A built-in row's note shows in the app's language and stays
        // English on disk unless the person changes it.
        SwiftUI.Binding(
            get: { ShippedText.t(binding.note ?? "") },
            set: { newValue in
                guard newValue != ShippedText.t(binding.note ?? "") else { return }
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                binding.note = trimmed.isEmpty ? nil : newValue
            }
        )
    }


    @ViewBuilder
    private var noteRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: colGap) {
            // "Notes" sits in the number column so the line is labeled the
            // same way the primary row is numbered; the text itself starts
            // under the Scan column.
            Text("Notes")
                .font(.callout)
                .foregroundStyle(.hint)
                .frame(width: numberColWidth, alignment: .leading)
            Group {
            if editingNote {
                TextField("Add a note (what this control does)", text: noteBinding)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .foregroundStyle((binding.note?.isEmpty ?? true) ? AnyShapeStyle(.hint) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .focused($noteFieldFocused)
                    .onSubmit {
                        editingNote = false
                        EditorInlineEdit.clear(binding.id)
                        DispatchQueue.main.async { noteButtonFocused = true }
                    }
                    .onChange(of: noteFieldFocused) { _, focused in
                        if !focused { editingNote = false; EditorInlineEdit.clear(binding.id) }
                    }
            } else {
                Button {
                    editingNote = true
                    DispatchQueue.main.async { noteFieldFocused = true }
                    EditorInlineEdit.begin(binding.id) {
                        editingNote = false
                        DispatchQueue.main.async { noteButtonFocused = true }
                        return true
                    }
                } label: {
                    Text((binding.note?.isEmpty ?? true)
                         ? String(localized: "Add a note (what this control does)")
                         : ShippedText.t(binding.note ?? ""))
                        .font(.callout)
                        .foregroundStyle((binding.note?.isEmpty ?? true) ? AnyShapeStyle(.hint) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused($noteButtonFocused)
                .accessibilityLabel("Note")
                .accessibilityInputLabels([Text("Note"), Text((binding.note?.isEmpty ?? true) ? String(localized: "Add a note") : ShippedText.t(binding.note ?? ""))])
                .accessibilityValue((binding.note?.isEmpty ?? true) ? String(localized: "empty") : ShippedText.t(binding.note ?? ""))
                .accessibilityHint("Edit the note for this binding")
            }
            }
            // A faint wash of the accent color so the note reads as its
            // own field without a border.
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.accentColor.opacity(0.07)))
        }
        .padding(.leading, dragWidth + colGap)
        .padding(.top, 3)
    }
}
