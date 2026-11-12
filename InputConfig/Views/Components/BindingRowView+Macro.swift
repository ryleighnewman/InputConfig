import SwiftUI
import Combine
import UniformTypeIdentifiers

// BindingRowView, the macro editor, its text pane and steps. Split from BindingRowView.swift, where
// the type and its state live, so a Debug build type-checks it in parallel with the rest.

extension BindingRowView {
    // MARK: - Macro Editor

    var macroEditorSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // When it runs comes first: it is part of what the macro is, not
            // a detail tucked beside the Add button.
            HStack(spacing: 8) {
                Text("When it runs")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Picker("When it runs", selection: macroRunModeBinding) {
                    Text("Every step, each time it is pressed").tag(0)
                    // Not on a control that is never held (a spoken phrase,
                    // a gesture, a tap, a knob turn, a sequence): its release
                    // lands a poll or two after the press and cut the chain
                    // after its first step. Not on a toggle either: the
                    // engine's toggle branch never reads the flag.
                    if macroHoldStopOffered {
                        Text("Only while held; letting go stops it").tag(1)
                    }
                    Text("Again and again, until pressed again").tag(2)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .hoverHelp("Each time it is pressed: one press plays every step. Only while held: letting go stops the rest of the steps and releases any held keys. Until pressed again: the steps play over and over, with the Repeat wait between passes, and the next press stops them.")
                Spacer()
            }

            HStack(spacing: 8) {
                Text("Playback")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Picker("Playback speed", selection: macroSpeedBinding) {
                    Text("Quarter speed").tag(0.25)
                    Text("Half speed").tag(0.5)
                    Text("As recorded").tag(1.0)
                    Text("1.5 times").tag(1.5)
                    Text("Double speed").tag(2.0)
                    Text("Four times").tag(4.0)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .hoverHelp("Every wait and hold is divided by this.")
                Picker("Random timing", selection: macroJitterBinding) {
                    Text("Exact timing").tag(0)
                    Text("Vary by 10%").tag(10)
                    Text("Vary by 25%").tag(25)
                    Text("Vary by 50%").tag(50)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .hoverHelp("Each wait and hold is stretched or shortened by up to this much at random, so a replay does not land on the same milliseconds every time.")
                Spacer()
                // The macro as a text file: the same lines the Text view
                // shows, to keep, share or bring into another row.
                Menu {
                    Button("Export as text file\u{2026}") { exportMacroTextFile() }
                        .disabled(binding.macroSteps?.isEmpty != false)
                    Button("Import text file\u{2026}") { importMacroTextFile() }
                    Divider()
                    Button("Copy as text") { copyMacroText() }
                        .disabled(binding.macroSteps?.isEmpty != false)
                    Button("Paste text") { pasteMacroText() }
                } label: {
                    Label("File", systemImage: "doc.text")
                        .font(.callout)
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .fixedSize()
                .accessibilityLabel("Macro file")
                .hoverHelp("Save this macro as a plain text file, bring one in, or copy and paste it as text.")
                // The same steps as a list of controls or as plain lines
                // (cmd c, wait 300, type "hello") to read, edit and share.
                Picker("Show steps as", selection: $macroShowsText) {
                    Text("List").tag(false)
                    Text("Text").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityLabel("Show steps as")
                .hoverHelp("List shows each step as controls. Text shows the same steps as plain lines, one step per line, to read, edit, copy or paste.")
            }

            if macroShowsText {
                macroTextPane
            } else if let steps = binding.macroSteps, !steps.isEmpty {
                macroStepsList(steps)
            } else {
                Text("No steps yet. Record them, or add the first step.")
                    .font(.callout)
                    .foregroundStyle(.hint)
            }

            HStack(spacing: 8) {
                if !macroShowsText {
                // Pick what the new step does right away, from the same list
                // each step's own menu has.
                Menu {
                    Button("Key") { addMacroStep(.key) }
                    Button("Mouse button") { addMacroStep(.mouseButton) }
                    Button("Type text") { addMacroStep(.typeText) }
                    Button("Scroll") { addMacroStep(.scroll) }
                    Button("Move pointer by") { addMacroStep(.nudge) }
                    Button("System function") { addMacroStep(.system) }
                    Divider()
                    Button("Wait") { addMacroStep(.wait) }
                    Button("Move pointer") { addMacroStep(.moveTo) }
                    Button("Wait for screen") { addMacroStep(.waitFor) }
                } label: {
                    Label("Add a step", systemImage: "plus.circle")
                        .font(.callout)
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .fixedSize()
                .disabled((binding.macroSteps?.count ?? 0) >= MacroRecording.maxSteps)
                .accessibilityLabel("Add a step")
                .hoverHelp("Adds a step at the end: a key, a click, text, a scroll, a system function, a pause, a pointer move or a wait for the screen.")

                // Press the keys once and the steps write themselves, with
                // the timing they were pressed with.
                Button {
                    MacroRecorderService.shared.room = MacroRecording.maxSteps - (binding.macroSteps?.count ?? 0)
                    showMacroRecorder = true
                } label: {
                    Label("Record steps\u{2026}", systemImage: "record.circle")
                        .font(.callout)
                }
                .buttonStyle(.solidSecondaryCompact)
                .disabled((binding.macroSteps?.count ?? 0) >= MacroRecording.maxSteps)
                .hoverHelp("Press keys and mouse buttons in another app; each press becomes a step with its timing.")
                }

                // Hear the steps without activating the preset: three
                // seconds to switch to the app they are for.
                Button {
                    // A click during the count stops it as well: the button
                    // was disabled for those three seconds, so the second
                    // click the help promised was impossible until the
                    // steps were already typing into the other app.
                    if macroPlaying || macroPlayCountdown > 0 {
                        stopMacroPlayOnce(stopChain: true)
                    } else {
                        playMacroOnce()
                    }
                } label: {
                    Label(macroPlayCountdown > 0 ? String(localized: "Playing in \(macroPlayCountdown)\u{2026}")
                          : macroPlaying ? String(localized: "Stop playing")
                          : String(localized: "Play once"),
                          systemImage: macroPlaying || macroPlayCountdown > 0 ? "stop.circle" : "play.circle")
                        .font(.callout)
                }
                .buttonStyle(.solidSecondaryCompact)
                .disabled(!macroPlaying && macroPlayCountdown == 0 && (binding.macroSteps?.isEmpty ?? true))
                .accessibilityHint(macroPlayCountdown > 0 ? String(localized: "Stops the count") : "")
                .hoverHelp("Counts three seconds while you switch to the app the macro is for, then plays every step once at the row's speed. Click again, or press Escape with InputConfig in front, to stop the count or the playback; from the other app, the emergency stop ends it.")
            }
            .sheet(isPresented: $showMacroRecorder) {
                MacroRecorderView(appending: binding.macroSteps?.isEmpty == false) { recorded in
                    var steps = binding.macroSteps ?? []
                    let had = steps.count
                    // Over the room, glide points go first, so the presses
                    // the person made are kept and only the path thins.
                    var take = recorded
                    let room = max(0, MacroRecording.maxSteps - had)
                    // A glide is a move another move follows, whatever its
                    // timing: with Keep the recorded timing off every move
                    // has no hold, and thinning by hold cut presses instead.
                    while take.count > room,
                          let glide = take.indices.first(where: { take[$0].eventKind == .moveTo && $0 + 1 < take.count && take[$0 + 1].eventKind == .moveTo }) {
                        // Its wait and glide time go to the next move, which
                        // then glides over the joined time: dropped, clicks
                        // recorded 3 s apart played 0.15 s apart.
                        take[glide + 1].delayMs = min(take[glide + 1].delayMs + take[glide].delayMs, 30_000)
                        take[glide + 1].holdMs = min(take[glide + 1].holdMs + take[glide].holdMs, 30_000)
                        take.remove(at: glide)
                    }
                    steps.append(contentsOf: take)
                    // Held to the most a macro takes, as Apply text is; a
                    // longer one from 1.8 keeps what it had.
                    binding.macroSteps = Array(steps.prefix(max(MacroRecording.maxSteps, had)))
                    binding.turboEnabled = nil
                    let added = (binding.macroSteps?.count ?? had) - had
                    AccessibilityNotification.Announcement(String(localized: "\(added) recorded steps added")).post()
                }
                .glassBackground()
            }


        }
    }

    private func macroStepsList(_ steps: [MacroStep]) -> some View {
        VStack(spacing: 3) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                macroStepRow(index: index, step: step)
            }
        }
    }

    /// A step is two lines: what it does, then when. The timing used to sit
    /// on the same line as bare "50 50" fields, because their Wait and Hold
    /// labels were the first thing squeezed out of a narrow output column.
    private func macroStepRow(index: Int, step: MacroStep) -> some View {
        // The step's own text line, as the Text pane writes it, so the two
        // panes read the same and VoiceOver hears the step in one phrase.
        let line = MacroText.writeLine(step, watches: macroTextWatches)
        let kind = step.eventKind ?? .tap
        return VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
            Text("\(index + 1).")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.hint)
                .frame(width: 18)

            // One menu for what the step does: the things it can press,
            // then the steps that press nothing. Two menus (Tap, Hold down,
            // Wait... beside Key, Mouse, Text...) asked the same question twice.
            Picker("Step", selection: macroStepChoiceBinding(at: index)) {
                Text("Key").tag(MacroStepChoice.key)
                Text("Mouse button").tag(MacroStepChoice.mouseButton)
                Text("Type text").tag(MacroStepChoice.typeText)
                Text("Scroll").tag(MacroStepChoice.scroll)
                Text("Move pointer by").tag(MacroStepChoice.nudge)
                Text("System function").tag(MacroStepChoice.system)
                Divider()
                Text("Wait").tag(MacroStepChoice.wait)
                Text("Move pointer").tag(MacroStepChoice.moveTo)
                Text("Wait for screen").tag(MacroStepChoice.waitFor)
                // A step from a file this menu cannot name, so it is not blank.
                if macroStepChoice(for: step) == .other { Text("Other").tag(MacroStepChoice.other) }
            }
            .labelsHidden()
            .controlSize(.small)
            // The output column gives a step about 520 px at a 1300 px
            // window: this and the widths below keep every step in it.
            .frame(width: 116 * max(1, textScale))
            .accessibilityLabel("Step \(index + 1)")
            .hoverHelp("What this step does: press a key or a mouse button, type text, scroll, run a system function, wait, move the pointer, or wait for something on the screen.")

            // Only a key or a mouse button can be held across later steps.
            if step.action.type == .key || step.action.type == .mouseButton, (step.eventKind ?? .tap).presses {
                Picker("Press", selection: macroStepKindBinding(at: index)) {
                    Text("Tap").tag(MacroStepKind.tap)
                    Text("Hold down").tag(MacroStepKind.down)
                    Text("Release").tag(MacroStepKind.up)
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 84 * max(1, textScale))
                .accessibilityLabel("Step \(index + 1) press")
                .hoverHelp("Tap presses and lets go. Hold down keeps it pressed while the next steps run, for a chord or a drag; a later Release step lets it go.")
            }
            if kind == .wait {
                macroMsField(macroDelayBinding(at: index), label: "Wait, milliseconds")
            }

            if !(step.eventKind ?? .tap).presses {
                macroStepKindEditors(index: index, step: step)
            } else if step.action.type == .key {
                KeyCodePicker(selectedCode: macroStepKeyBinding(at: index),
                              inShortcut: !(macroStep(at: index)?.modifiers ?? []).allSatisfy { !KeyCodeMap.shortcutModifierCodes.contains($0) },
                              voiceRole: "Step \(index + 1) key")
                    .frame(width: 80 * max(1, textScale))
                    .accessibilityLabel("Step \(index + 1) key")
                ShortcutModifierToggles(outputs: macroStepShortcutBinding(at: index), defaultKey: 4)
            } else if step.action.type == .mouseButton {
                Picker("Mouse button", selection: macroStepMouseBtnBinding(at: index)) {
                    ForEach(0..<6, id: \.self) { i in
                        Text(mouseButtonName(i)).tag(i)
                    }
                    // A button from a file past the list, so the picker is not blank.
                    let current = step.action.mouseButtonIndex ?? 0
                    if !(0..<6).contains(current) {
                        Text(mouseButtonName(current)).tag(current)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 90 * max(1, textScale))
            } else if step.action.type == .typeText {
                TextField("Text to type", text: macroStepTextBinding(at: index))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(minWidth: 140, maxWidth: 260)
                    .accessibilityLabel("Step \(index + 1) text")
            } else if step.action.type == .mouseWheelStep {
                Picker("Scroll direction", selection: macroStepScrollBinding(at: index)) {
                    Text("Up").tag("1 -")
                    Text("Down").tag("1 +")
                    Text("Left").tag("0 -")
                    Text("Right").tag("0 +")
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                TextField("", value: macroStepCountBinding(at: index), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 44 * max(1, textScale))
                    .controlSize(.small)
                    .multilineTextAlignment(.center)
                    .accessibilityLabel("Step \(index + 1) lines")
                fieldLabel("lines")
            } else if step.action.type == .mouseStep {
                Picker("Pointer direction", selection: stepDirectionBinding(
                    get: { macroStep(at: index)?.action },
                    set: { change in
                        guard var steps = binding.macroSteps, index < steps.count else { return }
                        change(&steps[index].action)
                        binding.macroSteps = steps
                    })) {
                    stepDirectionChoices
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                TextField("", value: macroStepDistanceBinding(at: index), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 52 * max(1, textScale))
                    .controlSize(.small)
                    .multilineTextAlignment(.center)
                    .accessibilityLabel("Step \(index + 1) distance in points")
                fieldLabel("pt")
            } else if step.action.type == .systemAction {
                Picker("System action", selection: macroStepSystemKindBinding(at: index)) {
                    ForEach(SystemActionKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                // Narrow enough, with its text field, to keep the step
                // inside the output column: wider pushed the whole sheet
                // past the window.
                .frame(width: 110 * max(1, textScale))
                if [.runShortcut, .openApp, .openURL].contains(step.action.systemActionKind ?? .playPause) {
                    TextField(step.action.systemActionKind == .openURL ? "https:// or any URL scheme"
                              : step.action.systemActionKind == .openApp ? "App name or full path" : "Shortcut name",
                              text: macroStepTextBinding(at: index))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(minWidth: 80, idealWidth: 110, maxWidth: 240)
                }
            }

            Spacer(minLength: 8)

            // The same four buttons at the end of every step, in one column.
            HStack(spacing: 6) {
                Button { moveMacroStep(at: index, by: -1) } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(index == 0)
                .hoverHelp("Move step up")
                .accessibilityLabel("Move step \(index + 1) up")

                Button { moveMacroStep(at: index, by: 1) } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(index >= (binding.macroSteps?.count ?? 0) - 1)
                .hoverHelp("Move step down")
                .accessibilityLabel("Move step \(index + 1) down")

                Button { duplicateMacroStep(at: index) } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .disabled((binding.macroSteps?.count ?? 0) >= MacroRecording.maxSteps)
                .hoverHelp("Duplicate step")
                .accessibilityLabel("Duplicate step \(index + 1)")

                Button {
                    var steps = binding.macroSteps ?? []
                    guard index < steps.count else { return }
                    steps.remove(at: index)
                    binding.macroSteps = steps.isEmpty ? nil : steps
                    AccessibilityNotification.Announcement(String(localized: "Step \(index + 1) removed")).post()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .hoverHelp("Remove step")
                .accessibilityLabel("Remove step \(index + 1)")
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        // When it plays, under what it does. A Wait step is nothing but
        // its pause, so its field sits on the first line after its menu.
        if kind != .wait {
            HStack(spacing: 4) {
                Spacer().frame(width: 24)
                fieldLabel("Wait")
                macroMsField(macroDelayBinding(at: index), label: "Wait before step \(index + 1), milliseconds", voiceName: "Wait")
                switch kind {
                case .moveTo: fieldLabel("before it, then glide over")
                case .waitFor: fieldLabel("before it, then wait up to")
                case .tap where step.action.type == .key || step.action.type == .mouseButton: fieldLabel("before it, then hold for")
                default: fieldLabel("before it")
                }
                // What the step does after it starts.
            switch kind {
            case .moveTo:
                macroMsField(macroHoldBinding(at: index), label: "Glide time, milliseconds")
            case .waitFor:
                macroMsField(macroStepTimeoutBinding(at: index), label: "Wait at most, milliseconds", width: 60, unit: "ms, then")
                Picker("After the timeout", selection: macroStepTimeoutModeBinding(at: index)) {
                    Text("skip the rest").tag(false)
                    Text("go on anyway").tag(true)
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .hoverHelp("What happens when the screen never shows it within the time: the rest of the macro is skipped, or plays regardless.")
            case .tap where step.action.type == .key || step.action.type == .mouseButton:
                // A hold means something only for a tapped key or button.
                macroMsField(macroHoldBinding(at: index), label: "Hold this step, milliseconds", voiceName: "Hold")
            default:
                EmptyView()
            }

            }
        }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(index + 1)")
        .accessibilityValue(Text(verbatim: line))
    }

    /// A milliseconds field and its unit, the one shape every step's
    /// timing takes.
    /// `voiceName` is the short word Voice Control can say for it ("click
    /// Wait"), as 1.8 had.
    private func macroMsField(_ value: SwiftUI.Binding<Int>, label: LocalizedStringKey, width: CGFloat = 52,
                              unit: LocalizedStringKey = "ms", voiceName: LocalizedStringKey? = nil) -> some View {
        HStack(spacing: 3) {
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: width * max(1, textScale))
                .controlSize(.small)
                .multilineTextAlignment(.center)
                .accessibilityLabel(label)
                .accessibilityInputLabels(voiceName.map { [Text($0), Text(label)] } ?? [Text(label)])
            fieldLabel(unit)
        }
    }

    /// The Add a step menu: a new step at the end, already the kind picked.
    private func addMacroStep(_ choice: MacroStepChoice) {
        var steps = binding.macroSteps ?? []
        guard steps.count < MacroRecording.maxSteps else { return }
        steps.append(MacroStep(action: OutputAction(type: .key, keyCode: 4)))
        binding.macroSteps = steps
        binding.turboEnabled = nil
        if choice != .key { macroStepChoiceBinding(at: steps.count - 1).wrappedValue = choice }
        AccessibilityNotification.Announcement(String(localized: "Step \(steps.count) added")).post()
    }

    private func moveMacroStep(at index: Int, by offset: Int) {
        guard var steps = binding.macroSteps else { return }
        let target = index + offset
        guard steps.indices.contains(index), steps.indices.contains(target) else { return }
        steps.swapAt(index, target)
        binding.macroSteps = steps
        AccessibilityNotification.Announcement(String(localized: "Moved to step \(target + 1)")).post()
    }

    private func duplicateMacroStep(at index: Int) {
        guard var steps = binding.macroSteps, steps.indices.contains(index), steps.count < MacroRecording.maxSteps else { return }
        let src = steps[index]
        let copy = MacroStep(action: src.action, delayMs: src.delayMs, holdMs: src.holdMs,
                             eventKind: src.eventKind, modifiers: src.modifiers,
                             count: src.count, watchID: src.watchID, timeoutMs: src.timeoutMs,
                             continueOnTimeout: src.continueOnTimeout)
        steps.insert(copy, at: index + 1)
        binding.macroSteps = steps
        AccessibilityNotification.Announcement(String(localized: "Step duplicated as step \(index + 2)")).post()
    }

    // MARK: - Macro text

    /// The steps as plain lines: edited here, parsed a moment after each
    /// keystroke, and written back to the row only by Apply text. Its own
    /// view, so typing re-evaluates the pane and not this row.
    private var macroTextPane: some View {
        MacroTextPaneView(
            pane: macroPane, scale: textScale, rowState: MacroTextRowState(row: binding),
            reviewLine: { macroTextReviewLine($0) },
            apply: { applyMacroText() },
            discard: { loadMacroText() },
            appeared: {
                // Lines still unapplied survive a trip to the List view. A paste
                // or import from there arrives with the pane, before any change.
                // Just filled by a paste or an import from the List view: a
                // reload here erased the message saying why it failed.
                if macroTextJustShown { macroTextJustShown = false; if macroText != macroTextWritten { holdMacroText() } }
                else if macroText == macroTextWritten { loadMacroText() } else { holdMacroText() }
            },
            edited: {
                scheduleMacroTextParse()
                holdMacroText()
            },
            rowChanged: {
                // A step added or recorded in the Steps pane, or a picker moved:
                // a pane nobody has edited follows the row.
                if macroText == macroTextWritten { loadMacroText() }
            })
    }

    /// The preset's screen colors then screen texts, each with its saved
    /// name, for the writer's `wait for` lines and the parser's lookup.
    private var macroTextWatches: [(id: UUID, name: String)] {
        ScreenPixelService.shared.allWatches().map { (id: $0.id, name: $0.name) }
            + ScreenTextService.shared.allWatches().map { (id: $0.id, name: $0.name) }
    }

    /// The row's steps and settings as text. With the heading for the
    /// clipboard; without it in the pane, where the row already names its
    /// input and a comment line would only draw the parser's note.
    private func writtenMacroText(heading: Bool) -> String {
        // In the pane the row's settings are the pickers right above it,
        // so only a copy for the clipboard carries them as lines.
        MacroText.write(steps: binding.macroSteps ?? [], options: heading ? MacroTextOptions(row: binding) : nil,
                        watches: macroTextWatches, heading: heading ? binding.input.displayName : nil)
    }

    private func parseMacroText(_ text: String) -> MacroTextResult { parseMacroText(text, for: binding) }

    private func parseMacroText(_ text: String, for row: BindingModel) -> MacroTextResult {
        MacroText.parse(text, watches: macroTextWatches, currentOptions: MacroTextOptions(row: row),
                        currentCount: row.macroSteps?.count ?? 0, isToggle: row.toggleMode == true,
                        neverHeld: MappingEngine.isNeverHeld(row.input))
    }

    /// Refills the pane from the row and parses at once.
    private func loadMacroText() {
        macroTextParseTask?.cancel()
        let text = writtenMacroText(heading: false)
        macroTextWritten = text
        macroText = text
        macroTextResult = parseMacroText(text)
        macroTextOpenerArmed = false
        macroTextStaleArmed = false
        macroTextNote = nil
        macroTextBaseSteps = binding.macroSteps
        EditorInlineEdit.dropPane(binding.id)
    }

    /// Parses a moment after the last keystroke. Nothing is applied: the
    /// row changes only when Apply text is clicked.
    private func scheduleMacroTextParse() {
        macroTextOpenerArmed = false
        macroTextStaleArmed = false
        macroTextParseTask?.cancel()
        let text = macroText
        macroTextParseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, text == macroText else { return }
            macroTextResult = parseMacroText(text)
        }
    }

    /// The import review's wording for the steps that open or type
    /// something, so a pasted macro is read before it is kept.
    private func macroTextReviewLine(_ steps: [MacroStep]) -> String {
        var lines = steps.map(\.action).filter(\.opensSomething).map(\.importReviewLine)
        if SpotlightChord.inMacro(steps, spotlightKey: false) {
            lines.append(String(localized: "Opens Spotlight with Command Space"))
        }
        let list = lines.joined(separator: ", ")
        return String(localized: "This macro opens or types something: \(list). Click Apply anyway to keep it.")
    }

    /// Lines waiting for Apply count for the editor's Save, Quit and
    /// Cancel, the pane shown or not: an import left here was gone with no
    /// word. Clean lines are written by a Save that comes first; the rest
    /// are asked about.
    private func holdMacroText() {
        guard macroText != macroTextWritten else {
            EditorInlineEdit.dropPane(binding.id)
            return
        }
        // Each closure reads the row the editor hands it, as the draft
        // holds it, never this view's binding (see HeldPane).
        let family = presetButtonFamily
        EditorInlineEdit.holdPane(binding.id, EditorInlineEdit.HeldPane(
            wait: { row in macroTextWait(for: row, family: family) },
            write: { row, confirmed in macroTextChange(for: row, family: family, confirmed: confirmed) },
            lostLine: { row in
                String(localized: "Lines not applied in the macro on \(Self.macroTextRowName(row, family: family)) are not saved.")
            }))
    }

    private static func macroTextRowName(_ row: BindingModel, family: FaceLetters?) -> String {
        MappingEngine.spokenInputName(row.input, family: family)
    }

    /// Steps added, recorded or removed in the List view after the pane's
    /// text was written from them.
    private var macroTextIsStale: Bool { binding.macroSteps != macroTextBaseSteps }

    /// Every reason the pane's lines cannot be written without a yes, for
    /// the row as the draft holds it; Apply asks the same questions one
    /// at a time.
    private func macroTextWait(for row: BindingModel, family: FaceLetters?) -> EditorInlineEdit.HeldPane.Wait {
        let name = Self.macroTextRowName(row, family: family)
        let result = parseMacroText(macroText, for: row)
        if result.hasErrors {
            return .blocked(String(localized: "The macro on \(name) has a line with a problem, so its lines cannot be saved. Keep editing to fix the line, or save without them."))
        }
        var reasons: [String] = []
        if row.macroSteps != macroTextBaseSteps {
            reasons.append(String(localized: "The steps of the macro on \(name) changed in the List view after its lines were written. Applying the lines replaces those steps."))
        }
        if result.needsSecondClick {
            reasons.append(macroTextReviewLine(result.steps))
        }
        return reasons.isEmpty ? .clean : .needsYes(reasons)
    }

    /// The change the pane's lines make to the row, for a Save or Quit
    /// that came first: clean lines, or, `confirmed`, lines the person
    /// said yes to. Nil when they must not be written.
    private func macroTextChange(for row: BindingModel, family: FaceLetters?, confirmed: Bool) -> ((inout BindingModel) -> Void)? {
        guard macroText != macroTextWritten else { return nil }
        switch macroTextWait(for: row, family: family) {
        case .clean: break
        case .needsYes: guard confirmed else { return nil }
        case .blocked: return nil
        }
        let result = parseMacroText(macroText, for: row)
        return { row in Self.writeMacroResult(result, to: &row) }
    }

    private func writeMacroResult(_ result: MacroTextResult) {
        var row = binding
        Self.writeMacroResult(result, to: &row)
        binding = row
        loadMacroText()
    }

    private static func writeMacroResult(_ result: MacroTextResult, to row: inout BindingModel) {
        row.macroSteps = result.steps.isEmpty ? nil : result.steps
        if !result.steps.isEmpty { row.turboEnabled = nil }
        if let options = result.options { options.apply(to: &row) }
    }

    /// Writes the text back to the row: the steps and the option lines in
    /// one assignment, so the editor's undo takes them back together. A
    /// text that opens or types something asks once more first.
    private func applyMacroText() {
        macroTextParseTask?.cancel()
        let result = parseMacroText(macroText)
        macroTextResult = result
        guard !result.hasErrors else { return }
        // Steps changed in the List view since: say so once, then replace.
        if macroTextIsStale && !macroTextStaleArmed {
            macroTextStaleArmed = true
            let line = String(localized: "The steps changed in the List view after these lines were written. Apply anyway replaces them.")
            macroTextNote = (macroText, line)
            AccessibilityNotification.Announcement(line).post()
            return
        }
        if result.needsSecondClick && !macroTextOpenerArmed {
            macroTextOpenerArmed = true
            AccessibilityNotification.Announcement(macroTextReviewLine(result.steps)).post()
            return
        }
        macroTextOpenerArmed = false
        writeMacroResult(result)
        let count = result.steps.count
        AccessibilityNotification.Announcement(count == 1 ? String(localized: "Applied, 1 step")
                                               : String(localized: "Applied, \(count) steps")).post()
    }

    /// One block on the clipboard: `# Macro on <input>`, the option lines,
    /// the steps. Shared by Copy text and the row's Copy macro as text.
    func copyMacroText() {
        // A step's number still being typed is written on the next turn,
        // after its field lets go, so the copy waits for it.
        if let window = NSApp.keyWindow, window.firstResponder is NSText {
            window.makeFirstResponder(nil)
            DispatchQueue.main.async { copyMacroTextNow() }
            return
        }
        copyMacroTextNow()
    }

    private func copyMacroTextNow() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(writtenMacroText(heading: true), forType: .string)
        AccessibilityNotification.Announcement(String(localized: "Copied")).post()
    }

    /// Like the recorder: appended after the row's steps, or the whole pane
    /// when the row has none. Of several blocks the first is used. The
    /// block's heading goes, since the row names its own input; appended, its
    /// option lines go too, as they belong to the macro it came from.
    private func pasteMacroText() {
        pasteMacroText(NSPasteboard.general.string(forType: .string) ?? "",
                       empty: String(localized: "The clipboard has no macro text to paste."))
    }

    /// A plain text file of macro lines, named for the row's input.
    private func exportMacroTextFile() {
        if let window = NSApp.keyWindow, window.firstResponder is NSText {
            window.makeFirstResponder(nil)
            DispatchQueue.main.async { exportMacroTextFile() }
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let name = ShippedText.t(binding.note ?? "").isEmpty ? binding.input.displayName : ShippedText.t(binding.note ?? "")
        panel.nameFieldStringValue = (String(localized: "\(name) macro") + ".txt").replacingOccurrences(of: "/", with: "-")
        panel.message = String(localized: "Choose where to save the macro")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try writtenMacroText(heading: true).write(to: url, atomically: true, encoding: .utf8)
            AccessibilityNotification.Announcement(String(localized: "Macro saved")).post()
        } catch {
            let alert = NSAlert()
            alert.messageText = String(localized: "Could not save the file there")
            alert.informativeText = String(localized: "Choose another folder, such as Documents or the Desktop.")
            alert.runModal()
        }
    }

    /// A macro text file into this row, through the Text view: the lines
    /// are checked as they are when pasted, and Apply writes them, so a
    /// file with a mistake shows the line instead of changing the row.
    private func importMacroTextFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(localized: "Choose a macro text file")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // A macro is a few kilobytes; a large file is something else.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 512_000, let text = try? String(contentsOf: url, encoding: .utf8) else {
            showMacroTextPane()
            let line = String(localized: "That file is not a macro text file.")
            macroTextNote = (macroText, line)
            AccessibilityNotification.Announcement(line).post()
            return
        }
        pasteMacroText(text, empty: String(localized: "That file has no macro lines."))
    }

    /// Switches to the Text view with the row's steps in the pane, for a
    /// paste or a file from the List view; the pane keeps what is put in
    /// it now, which differs from what was written.
    private func showMacroTextPane() {
        guard !macroShowsText else { return }
        // Lines held from an earlier visit to the Text view stay: they are
        // what a paste appends to, and replacing them lost them unasked.
        if macroText == macroTextWritten { loadMacroText() }
        macroTextJustShown = true
        macroShowsText = true
    }

    private func pasteMacroText(_ source: String, empty: String) {
        showMacroTextPane()
        let blocks = MacroText.blocks(source)
        guard let first = blocks.first else {
            macroTextNote = (macroText, empty)
            AccessibilityNotification.Announcement(empty).post()
            return
        }
        let appending = binding.macroSteps?.isEmpty == false
        let lines = first.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
            if trimmed.hasPrefix("# macro on") { return false }
            guard appending, let colon = trimmed.firstIndex(of: ":") else { return true }
            let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
            return !["when", "speed", "vary", "repeat"].contains(key)
        }
        let pasted = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
        let base = macroText.trimmingCharacters(in: .newlines)
        let text = appending && !base.isEmpty ? base + "\n" + pasted : pasted
        macroTextParseTask?.cancel()
        macroText = text
        holdMacroText()
        let result = parseMacroText(text)
        macroTextResult = result
        let note = blocks.count > 1 ? String(localized: "\(blocks.count) macros on the clipboard; the first was pasted.") : nil
        macroTextNote = note.map { (text, $0) }
        AccessibilityNotification.Announcement(note ?? result.summary).post()
    }

    // MARK: - Macro Bindings

    /// A key step as a shortcut, for its modifier toggles: the step's held
    /// modifiers, then its key.
    private func macroStepShortcutBinding(at index: Int) -> SwiftUI.Binding<[OutputAction]?> {
        SwiftUI.Binding(
            get: {
                guard let steps = binding.macroSteps, steps.indices.contains(index) else { return nil }
                return steps[index].pressedActions
            },
            set: { newValue in
                guard var steps = binding.macroSteps, steps.indices.contains(index), let newValue else { return }
                let held = ShortcutOutputs.held(in: newValue)
                steps[index].modifiers = held.isEmpty ? nil : ShortcutOutputs.modifierOrder.filter { held.contains($0) }
                steps[index].action.keyCode = ShortcutOutputs.key(of: newValue, default: steps[index].action.keyCode ?? 4)
                binding.macroSteps = steps
            }
        )
    }

    /// Whether "Only while held; letting go stops it" means anything on
    /// this row: the control must be held, and the press mode must not be
    /// a toggle (the engine's toggle branch ends a chain on the next press).
    private var macroHoldStopOffered: Bool {
        !neverHeld && binding.toggleMode != true
    }

    /// 0 every press, 1 only while held, 2 until pressed again. A stored
    /// stop-on-release flag on a row where it is not offered reads as 0.
    private var macroRunModeBinding: SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: {
                if binding.macroLoop == true { return 2 }
                return binding.macroInterruptOnRelease == true && macroHoldStopOffered ? 1 : 0
            },
            set: {
                binding.macroInterruptOnRelease = $0 == 1 ? true : nil
                binding.macroLoop = $0 == 2 ? true : nil
            }
        )
    }

    /// The step at `index`, or nil once it has been removed. A field
    /// committing while its step is deleted would otherwise trap.
    private func macroStep(at index: Int) -> MacroStep? {
        guard let steps = binding.macroSteps, steps.indices.contains(index) else { return nil }
        return steps[index]
    }

    /// What a step does, as the step menu lists it.
    enum MacroStepChoice: Hashable { case key, mouseButton, typeText, scroll, nudge, system, wait, moveTo, waitFor, other }

    private func macroStepChoice(for step: MacroStep) -> MacroStepChoice {
        switch step.eventKind ?? .tap {
        case .wait: return .wait
        case .moveTo: return .moveTo
        case .waitFor: return .waitFor
        default: break
        }
        switch step.action.type {
        case .key: return .key
        case .mouseButton: return .mouseButton
        case .typeText: return .typeText
        case .mouseWheelStep: return .scroll
        case .mouseStep: return .nudge
        case .systemAction: return .system
        default: return .other
        }
    }

    /// Sets the kind and the type together through their own bindings, so
    /// each keeps the clean-up it does (defaults, a Tap for a type that
    /// cannot be held).
    private func macroStepChoiceBinding(at index: Int) -> SwiftUI.Binding<MacroStepChoice> {
        SwiftUI.Binding(
            get: { macroStep(at: index).map(macroStepChoice(for:)) ?? .key },
            set: { choice in
                switch choice {
                case .wait: macroStepKindBinding(at: index).wrappedValue = .wait
                case .moveTo: macroStepKindBinding(at: index).wrappedValue = .moveTo
                case .waitFor: macroStepKindBinding(at: index).wrappedValue = .waitFor
                case .other: break
                case .key, .mouseButton, .typeText, .scroll, .nudge, .system:
                    if !((macroStep(at: index)?.eventKind ?? .tap).presses) {
                        macroStepKindBinding(at: index).wrappedValue = .tap
                    }
                    let type: OutputType = switch choice {
                    case .key: .key
                    case .mouseButton: .mouseButton
                    case .typeText: .typeText
                    case .scroll: .mouseWheelStep
                    case .nudge: .mouseStep
                    default: .systemAction
                    }
                    if macroStep(at: index)?.action.type != type {
                        macroStepTypeBinding(at: index).wrappedValue = type
                    }
                }
            }
        )
    }

    private func macroStepKindBinding(at index: Int) -> SwiftUI.Binding<MacroStepKind> {
        SwiftUI.Binding(
            get: { macroStep(at: index)?.eventKind ?? .tap },
            set: {
                guard var steps = binding.macroSteps, index < steps.count else { return }
                steps[index].eventKind = ($0 == .tap) ? nil : $0
                // A recorded Move pointer step carries a pointer motion
                // action, which no Step type offers and the engine's press
                // ignores: switched to a pressing kind, the type picker was
                // blank and the step ran as nothing. It becomes the key the
                // picker shows, as a new step does.
                let stepTypes: Set<OutputType> = [.key, .mouseButton, .typeText, .mouseWheelStep, .mouseStep, .systemAction]
                if $0.presses, !stepTypes.contains(steps[index].action.type) {
                    steps[index].action.type = .key
                    steps[index].action.fillDefaultsForType()
                }
                binding.macroSteps = steps
            }
        )
    }

    private func macroStepTypeBinding(at index: Int) -> SwiftUI.Binding<OutputType> {
        SwiftUI.Binding(
            get: { macroStep(at: index)?.action.type ?? .key },
            set: {
                guard var steps = binding.macroSteps, index < steps.count else { return }
                steps[index].action.type = $0
                steps[index].action.fillDefaultsForType()
                if $0 == .systemAction, steps[index].action.systemActionKind == nil { steps[index].action.systemActionKind = .playPause }
                if $0 == .mouseWheelStep, steps[index].count == nil { steps[index].count = 3 }
                // Hold down and Release are for keys and mouse buttons only
                // (see the Step action picker): a step changed to Type Text,
                // Scroll or System goes back to Tap, which is how it runs.
                if $0 != .key, $0 != .mouseButton, let kind = steps[index].eventKind, kind == .down || kind == .up {
                    steps[index].eventKind = nil
                }
                binding.macroSteps = steps
            }
        )
    }

    /// The editors of a step that presses nothing: a point for Move
    /// pointer, a watch for Wait for screen; Wait has only its time.
    @ViewBuilder
    private func macroStepKindEditors(index: Int, step: MacroStep) -> some View {
        switch step.eventKind ?? .tap {
        case .moveTo:
            fieldLabel("X")
            TextField("", value: macroStepPointBinding(at: index, axis: 0), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 50 * max(1, textScale))
                .controlSize(.small)
                .multilineTextAlignment(.center)
                .accessibilityLabel("Step \(index + 1) X")
            fieldLabel("Y")
            TextField("", value: macroStepPointBinding(at: index, axis: 1), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 50 * max(1, textScale))
                .controlSize(.small)
                .multilineTextAlignment(.center)
                .accessibilityLabel("Step \(index + 1) Y")
            Button(macroPointCountdown > 0 ? String(localized: "\(macroPointCountdown)…") : String(localized: "Use the pointer in 3 s")) {
                // A click during the count stops it, so a count started by
                // mistake does not overwrite the point with wherever the
                // pointer happens to be.
                if macroPointCountdown > 0 {
                    cancelMacroPointPick()
                } else {
                    pickMacroPoint(for: index)
                }
            }
            .buttonStyle(.solidSecondaryCompact)
            .accessibilityHint(macroPointCountdown > 0 ? String(localized: "Stops the count") : "")
            .hoverHelp("Counts three seconds (ten with Switch Control) while you move the pointer to the spot, then takes its position. Click again to stop the count.")
        case .waitFor:
            Picker("Screen watch", selection: macroStepWatchBinding(at: index)) {
                Text("Choose a color or text").tag(UUID?.none)
                ForEach(ScreenPixelService.shared.allWatches()) { watch in
                    Text(String(localized: "Color: \(watch.shownName)")).tag(UUID?.some(watch.id))
                }
                ForEach(ScreenTextService.shared.allWatches()) { watch in
                    Text(String(localized: "Text: \(watch.shownName)")).tag(UUID?.some(watch.id))
                }
                // A watch from a file or a deleted one, so the picker is not blank.
                if let id = step.watchID,
                   ScreenPixelService.shared.watch(with: id) == nil,
                   ScreenTextService.shared.watch(with: id) == nil {
                    Text("Missing watch").tag(UUID?.some(id))
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 200 * max(1, textScale))
            .hoverHelp("One of this preset's screen colors or screen texts, from the Screen Colors and Screen Text sheets. The macro goes on when it shows.")
        default:
            EmptyView()
        }
    }

    /// Plays the row's steps once after a three second count, so the
    /// pointer and the keys land in the app they are meant for. The count
    /// is spoken, and the task is kept so a click, Escape, the emergency
    /// stop or the editor closing can end it before anything is sent.
    private func playMacroOnce() {
        // A number still being typed in a step lands first (read 3 s later).
        NSApp.keyWindow?.makeFirstResponder(nil)
        guard binding.macroSteps?.isEmpty == false else { return }
        macroPlayTask?.cancel()
        macroStopRequested = false
        macroPlayCountdown = 3
        // Escape anywhere in the sheet stops the count or the playback;
        // the button alone needs focus, which the user has likely moved.
        // Command combinations pass, as the scan's monitor lets them.
        if macroPlayEscapeMonitor == nil {
            macroPlayEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53, !event.modifierFlags.contains(.command) else { return event }
                stopMacroPlayOnce(stopChain: true)
                return nil
            }
        }
        Self.announce(String(localized: "Switch to the app the macro is for. Playing in 3 seconds."))
        macroPlayTask = Task { @MainActor in
            for n in stride(from: 2, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                macroPlayCountdown = n
                // Queued behind the instruction rather than cutting it off.
                if n > 0 { Self.announce("\(n)", priority: .medium) }
            }
            // Re-read: the steps may change while the count runs. The
            // editor may also have closed (OpenEditor.current goes nil
            // with it): then nothing plays into the front app.
            guard !Task.isCancelled, OpenEditor.current != nil,
                  let engine = MappingEngine.current,
                  let steps = binding.macroSteps, !steps.isEmpty else { endMacroPlayOnce(); return }
            // Another row's Play once may still be running; the engine
            // keeps one editor chain, so this one does not claim its state.
            guard !engine.editorPlaybackRunning else {
                AccessibilityNotification.Announcement(String(localized: "Another row is still playing")).post()
                endMacroPlayOnce()
                return
            }
            // The preset's Scroll speed, so a Scroll step plays as it will
            // once the preset runs, not at a speed cached from the last one.
            // Locked or asleep since the count began: nothing plays there.
            guard engine.playMacroFromEditor(steps, speed: binding.macroSpeed ?? 1,
                                             jitterPercent: binding.macroJitterPercent ?? 0,
                                             scrollMultiplier: presetScrollMultiplier) else {
                endMacroPlayOnce()
                AccessibilityNotification.Announcement(String(localized: "Playback stopped")).post()
                return
            }
            AccessibilityNotification.Announcement(String(localized: "Playing \(steps.count) steps")).post()
            macroPlaying = true
            while engine.editorPlaybackRunning, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
            }
            if Task.isCancelled { return }
            endMacroPlayOnce()
            // The end was silent: the button label went back to Play once,
            // which VoiceOver does not read from the other app, while held
            // steps may still have been letting go.
            // A lock or sleep cuts the chain too, and sets nothing here.
            let cut = macroStopRequested || MappingEngine.current?.editorPlaybackWasCut == true
            AccessibilityNotification.Announcement(cut
                ? String(localized: "Playback stopped")
                : String(localized: "Finished playing")).post()
        }
    }

    /// Ends Play once. During the count this cancels it. During playback,
    /// with stopChain, it asks the engine to halt the chain, and the watch
    /// in playMacroOnce announces the end once the chain has let go.
    /// Called by the second click, Escape, the emergency stop (the count
    /// only: the stop already ended the chain and announced itself) and,
    /// with tearDown, by the row leaving with the editor, where nothing
    /// is left to watch the chain.
    func stopMacroPlayOnce(stopChain: Bool, tearDown: Bool = false) {
        if macroPlayCountdown > 0 {
            macroPlayTask?.cancel()
            endMacroPlayOnce()
            AccessibilityNotification.Announcement(String(localized: "Play once canceled")).post()
            return
        }
        guard macroPlaying, stopChain else { return }
        macroStopRequested = true
        MappingEngine.current?.stopEditorPlayback()
        if tearDown {
            macroPlayTask?.cancel()
            endMacroPlayOnce()
            AccessibilityNotification.Announcement(String(localized: "Playback stopped")).post()
        }
    }

    /// Clears the Play once count, the playing flag and the Escape monitor.
    private func endMacroPlayOnce() {
        macroPlayTask = nil
        macroPlayCountdown = 0
        macroPlaying = false
        if let monitor = macroPlayEscapeMonitor {
            NSEvent.removeMonitor(monitor)
            macroPlayEscapeMonitor = nil
        }
    }

    /// Takes the pointer's position a few seconds from now for a Move
    /// pointer step, so the pointer can be put on the spot first. Spoken,
    /// and longer under Switch Control, as the output-level Set spot is:
    /// the number on a button nobody has focused said nothing, and the
    /// spot was taken before a glided pointer could reach it.
    private func pickMacroPoint(for index: Int) {
        // By id: the step may move or go while the count runs.
        guard let stepID = macroStep(at: index)?.id else { return }
        macroPointTask?.cancel()
        let total = NSWorkspace.shared.isSwitchControlEnabled ? 10 : 3
        macroPointCountdown = total
        Self.announce(String(localized: "Move the pointer to the spot. Taken in \(total) seconds."))
        macroPointTask = Task { @MainActor in
            for n in stride(from: total - 1, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                macroPointCountdown = n
                // Queued behind the instruction rather than cutting it off.
                if n > 0, n <= 2 { Self.announce("\(n)", priority: .medium) }
            }
            macroPointTask = nil
            let loc = NSEvent.mouseLocation
            let height = NSScreen.screens.first?.frame.height ?? 0
            guard var steps = binding.macroSteps, let index = steps.firstIndex(where: { $0.id == stepID }) else { return }
            steps[index].action.clickX = Double(loc.x).rounded()
            steps[index].action.clickY = Double(height - loc.y).rounded()
            binding.macroSteps = steps
            AccessibilityNotification.Announcement(String(localized: "Point taken: \(Int(loc.x)), \(Int(height - loc.y))")).post()
        }
    }

    /// Stops a running Use the pointer count and leaves the point as it was.
    func cancelMacroPointPick() {
        guard macroPointCountdown > 0 else { return }
        macroPointTask?.cancel()
        macroPointTask = nil
        macroPointCountdown = 0
        AccessibilityNotification.Announcement(String(localized: "Count stopped")).post()
    }

    private func macroStepTextBinding(at index: Int) -> SwiftUI.Binding<String> {
        SwiftUI.Binding(
            get: { macroStep(at: index)?.action.text ?? "" },
            set: {
                guard var steps = binding.macroSteps, index < steps.count else { return }
                steps[index].action.text = $0
                binding.macroSteps = steps
            }
        )
    }

    private func macroStepCountBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { macroStep(at: index)?.count ?? 1 },
            set: {
                guard var steps = binding.macroSteps, index < steps.count else { return }
                steps[index].count = Self.clamped($0, 1...100)
                binding.macroSteps = steps
            }
        )
    }

    /// "axis direction" for the scroll picker, as the row's own wheel editor.
    private func macroStepDistanceBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { macroStep(at: index)?.action.resolvedStepDistance ?? OutputAction.defaultStepDistance },
            set: { value in
                guard var steps = binding.macroSteps, index < steps.count else { return }
                steps[index].action.speed = min(max(value, OutputAction.stepDistanceRange.lowerBound), OutputAction.stepDistanceRange.upperBound)
                binding.macroSteps = steps
            }
        )
    }

    private func macroStepScrollBinding(at index: Int) -> SwiftUI.Binding<String> {
        SwiftUI.Binding(
            get: {
                let a = macroStep(at: index)?.action
                return "\((a?.mouseAxis ?? .vertical).rawValue) \((a?.mouseDirection ?? .negative).rawValue)"
            },
            set: {
                let parts = $0.split(separator: " ")
                guard parts.count == 2, let axis = Int(parts[0]).flatMap(MouseAxis.init(rawValue:)),
                      let direction = MouseDirection(rawValue: String(parts[1])),
                      var steps = binding.macroSteps, index < steps.count else { return }
                steps[index].action.mouseAxis = axis
                steps[index].action.mouseDirection = direction
                binding.macroSteps = steps
            }
        )
    }

    private func macroStepSystemKindBinding(at index: Int) -> SwiftUI.Binding<SystemActionKind> {
        SwiftUI.Binding(
            get: { macroStep(at: index)?.action.systemActionKind ?? .playPause },
            set: {
                guard var steps = binding.macroSteps, index < steps.count else { return }
                steps[index].action.systemActionKind = $0
                binding.macroSteps = steps
            }
        )
    }

    private func macroStepPointBinding(at index: Int, axis: Int) -> SwiftUI.Binding<Double> {
        SwiftUI.Binding(
            get: { (axis == 0 ? macroStep(at: index)?.action.clickX : macroStep(at: index)?.action.clickY) ?? 0 },
            set: {
                guard var steps = binding.macroSteps, index < steps.count, $0.isFinite else { return }
                // Held to the range a file is: a 20-digit number trapped when
                // the step was written as text on the next render.
                let v = min(max($0, -100_000), 100_000)
                if axis == 0 { steps[index].action.clickX = v } else { steps[index].action.clickY = v }
                binding.macroSteps = steps
            }
        )
    }

    private func macroStepWatchBinding(at index: Int) -> SwiftUI.Binding<UUID?> {
        SwiftUI.Binding(
            get: { macroStep(at: index)?.watchID },
            set: {
                guard var steps = binding.macroSteps, index < steps.count else { return }
                steps[index].watchID = $0
                binding.macroSteps = steps
            }
        )
    }

    private func macroStepTimeoutModeBinding(at index: Int) -> SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { macroStep(at: index)?.continueOnTimeout ?? false },
            set: {
                guard var steps = binding.macroSteps, index < steps.count else { return }
                steps[index].continueOnTimeout = $0 ? true : nil
                binding.macroSteps = steps
            }
        )
    }

    private func macroStepTimeoutBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { macroStep(at: index)?.timeoutMs ?? 10_000 },
            set: {
                guard var steps = binding.macroSteps, index < steps.count else { return }
                steps[index].timeoutMs = Self.clamped($0, 100...60_000)
                binding.macroSteps = steps
            }
        )
    }

    private var macroSpeedBinding: SwiftUI.Binding<Double> {
        SwiftUI.Binding(
            get: {
                let v = binding.macroSpeed ?? 1
                return [0.25, 0.5, 1, 1.5, 2, 4].min { abs($0 - v) < abs($1 - v) } ?? 1
            },
            set: { binding.macroSpeed = abs($0 - 1) < 0.001 ? nil : $0 }
        )
    }

    private var macroJitterBinding: SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: {
                let v = binding.macroJitterPercent ?? 0
                return [0, 10, 25, 50].min { abs($0 - v) < abs($1 - v) } ?? 0
            },
            set: { binding.macroJitterPercent = $0 == 0 ? nil : $0 }
        )
    }

    private func macroStepKeyBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { macroStep(at: index)?.action.keyCode ?? 4 },
            set: {
                guard var steps = binding.macroSteps, index < steps.count else { return }
                steps[index].action.keyCode = $0
                binding.macroSteps = steps
            }
        )
    }

    private func macroStepMouseBtnBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { macroStep(at: index)?.action.mouseButtonIndex ?? 0 },
            set: {
                guard var steps = binding.macroSteps, index < steps.count else { return }
                steps[index].action.mouseButtonIndex = $0
                binding.macroSteps = steps
            }
        )
    }

    private func macroDelayBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { macroStep(at: index)?.delayMs ?? 50 },
            set: {
                guard var steps = binding.macroSteps, index < steps.count else { return }
                steps[index].delayMs = max(0, min(30000, $0))
                binding.macroSteps = steps
            }
        )
    }

    private func macroHoldBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { macroStep(at: index)?.holdMs ?? 50 },
            set: {
                guard var steps = binding.macroSteps, index < steps.count else { return }
                steps[index].holdMs = max(0, min(30000, $0))
                binding.macroSteps = steps
            }
        )
    }
}
