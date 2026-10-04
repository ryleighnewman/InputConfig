import SwiftUI
import Carbon.HIToolbox

/// Payload that asks the editor to scroll to and highlight a specific
/// binding row. Posted from the Live Visualizer popovers via the
/// `inputConfigJumpToBinding` notification and routed in by ContentView.
struct EditorJumpTarget: Equatable, Hashable {
    /// Joystick index the visualizer click came from. The editor uses this
    /// to disambiguate when multiple joystick groups all bind the same input
    /// (e.g. two controllers each mapping Button A).
    let joystickIndex: Int
    /// Serialized form of the InputEvent (e.g. "axi 0 +", "btn 5"). Matched
    /// against every binding's `input.serialized` to locate the right row.
    let inputSerialized: String
    /// The exact row, when known (a search hit): a chord row has the same
    /// input text as the plain row, and the first match won.
    var bindingID: UUID? = nil
    /// Something to do on arrival besides scrolling to the row.
    var action: EditorJumpAction? = nil
    /// Re-triggers the jump even when the user clicks the same widget twice
    /// in a row. Equatable comparison includes this token.
    var token: UUID = UUID()
}

/// What a jump into the editor does on arrival.
enum EditorJumpAction: Hashable {
    /// Add a Screen region row to the group and open the region drawing
    /// sheet; the region drawn there is attached to the new row.
    case addScreenRegion
}

/// Full-featured preset editor with joystick groups and bindings.
/// Shows live input highlighting via mappingEngine environment object.
struct PresetEditorView: View {
    @State var preset: Preset
    /// The running engine follows the draft live while this preset runs,
    /// so a change shows at once (with Override, or on the pointer and
    /// lights) instead of only after the editor closes. Cancel puts the
    /// saved preset back on the engine.
    @EnvironmentObject private var liveEngine: MappingEngine
    @State private var liveApplyTask: Task<Void, Never>?
    /// Whether this preset was running when the editor opened, so Cancel
    /// can start it again if an edit stopped it.
    @State private var runningAtOpen = false
    /// Set once Save or Cancel has put the regions back.
    @State private var regionsRestored = false

    /// True when the mapping engine was active at the moment the editor
    /// opened. Drives the "Engine paused while editing" banner so the user
    /// sees why their preset stopped firing inputs.
    var enginePausedNotice: Bool = false
    /// Optional jump-to-row request set by ContentView when the user clicks
    /// an input on the Live Visualizer. nil for a normal open.
    var pendingJump: EditorJumpTarget? = nil
    let onSave: (Preset) -> Void

    @EnvironmentObject var controllerService: GameControllerService
    // PresetEditorView itself never reads the mapping engine; only the child
    // JoystickGroupView rows do, and they inherit it from the sheet-level
    // injection in ContentView. Subscribing here rebuilt the ENTIRE editor body
    // on every 10-30 Hz engine publish while a preset was active.
    @EnvironmentObject var presetStore: PresetStore
    // The mapping engine is not observed here: only the paused banner reads
    // it, and observing it re-ran the whole editor, every group and row
    // included, on each of its debug log flushes while a preset ran.
    @Environment(\.dismiss) private var dismiss

    @State private var scanningBinding: (joystickIndex: Int, bindingIndex: Int)?
    /// True while the scan is for a row's chord control rather than its input.
    @State private var scanningModifier = false
    /// The chord slot a modifier scan replaces; nil adds a new one.
    @State private var scanningModifierSlot: Int?
    /// Whether this editor holds a cursor-tracking claim. Begin and end
    /// used to be decided separately from whether regions existed at open
    /// and at close, so drawing a first region or deleting the last one
    /// ended tracking the editor never began (freezing a running preset's
    /// regions) or left the 60 Hz timer running forever.
    @State private var trackingCursor = false
    @State private var confirmingCancel = false

    /// Edits to the rows, or to the zones and regions, which live in the
    /// region services while the editor is open and never marked it dirty.
    private var hasUnsavedChanges: Bool {
        // Compared with the preset as opened, not by the undo history:
        // collapsing a device group, or the old placeholder tag being
        // cleared, is not an edit and must not ask to save.
        if let opened = openedPreset {
            if Self.ignoringLayout(preset) != Self.ignoringLayout(opened) { return true }
        } else if !undoStack.isEmpty {
            return true
        }
        guard Preset.regionWorkingSetOwner == preset.id else { return false }
        var probe = preset
        probe.captureRegionsFromServices()
        return probe.touchpadRegions != preset.touchpadRegions
            || probe.cursorRegions != preset.cursorRegions
            || probe.stickRegions != preset.stickRegions
    }
    @State private var showingScanOverlay = false

    /// Identifies which header text field (if any) currently owns the
    /// keyboard focus. Used to:
    /// 1. Let the user click anywhere outside the field to deselect it.
    /// 2. Force focus off when a scan starts, so keypresses don't type
    ///    into the name/tag field while the user is trying to scan
    ///    a controller input.
    @FocusState private var focusedHeaderField: HeaderField?
    private enum HeaderField: Hashable { case name, tag }
    @State private var preSortSnapshot: [JoystickMapping]?
    @State private var postSortSnapshot: [JoystickMapping]?
    /// UUID of the binding row currently pulsing yellow because we just
    /// jumped to it. nil when no pulse is active.
    @State private var pulsingBindingID: UUID?
    /// The row a jump is heading for, built ahead of the staged reveal.
    @State private var revealBindingID: UUID?
    /// The latest jump, so a quicker second click cancels the first.
    @State private var jumpToken = 0
    /// "Draw a screen region" from the visualizer: the drawing sheet, the
    /// row waiting for its region, and the regions there were before.
    @State private var drawingScreenRegions = false
    @State private var regionRowAwaitingRegion: UUID?
    @State private var regionsBeforeDrawing: Set<UUID> = []
    /// A jump requested by the finder (the parent's `pendingJump` is a plain
    /// input, so the editor keeps its own for rows it adds itself).
    @State private var finderJump: EditorJumpTarget?
    /// After a directional scan we pop a confirmation dialog asking whether
    /// to wire the input directly to mouse motion or just record it raw and
    /// let the user assign an output manually.
    @State private var pendingScanMapping: PendingScanMapping?
    /// Touchpad scan: the candidates the overlay saw (press, tap, two-finger
    /// tap), for the "which one did you mean" dialog.
    @State private var pendingTouchpadChoice: [InputEvent]?

    /// Carries the scan result + the binding location through the
    /// confirmation dialog. We have to keep these together because
    /// confirmationDialog's button closures need the data captured at the
    /// time of presentation.
    private struct PendingScanMapping: Identifiable {
        let id = UUID()
        let event: InputEvent
        let joystickIndex: Int
        let bindingIndex: Int
        /// True for axis + touchpad. We don't prompt on plain button taps.
        let isDirectional: Bool
        /// True only for touchpad inputs - drives the "Calibrate touchpad
        /// first" hint and the optional Region path.
        let isTouchpad: Bool
    }

    // Unlimited undo/redo: every time the preset changes we push the
    // previous state onto undoStack. Redo is populated when the user
    // undoes - undoing pushes the current state onto redoStack so they
    // can redo back up the chain. A small flag `isApplyingHistory`
    // prevents the change observer from re-recording history during
    // undo/redo itself.
    @State private var undoStack: [Preset] = []
    @State private var redoStack: [Preset] = []
    @State private var isApplyingHistory: Bool = false
    @State private var lastSnapshot: Preset? = nil
    /// The preset as it was when the editor opened.
    @State private var openedPreset: Preset?

    /// The preset with what is only view state set aside: whether each
    /// device group is expanded, and the old placeholder tag.
    private static func ignoringLayout(_ p: Preset) -> Preset {
        var copy = p
        for i in copy.joysticks.indices {
            copy.joysticks[i].isExpanded = true
            if copy.joysticks[i].tag == "Add bindings here" { copy.joysticks[i].tag = "" }
        }
        return copy
    }

    /// Drives the Calibrate Touchpad sheet. Only shown when at least one
    /// connected controller reports a touchpad (DualSense, DualSense Edge,
    /// DualShock 4, etc.).
    @State private var showingTouchpadCalibration: Bool = false
    /// Drives the Calibrate Motion sheet from the toolbar button.
    @State private var showingMotionCalibration: Bool = false
    /// Drives the Calibrate Taps sheet. Only offered on Macs that publish
    /// the chassis accelerometer; checked once so the toolbar never hits
    /// IOKit on every body pass.
    @State private var showingTapCalibration: Bool = false
    @State private var hasChassisTapSensor: Bool = ChassisTapService.shared.isAvailable
    /// True when a motion input was scanned but no controller is yet
    /// calibrated. Drives an alert that offers to jump into calibration.
    @State private var pendingMotionCalibrationOffer: Bool = false

    /// Brief toast shown after the Quick Zero toolbar button fires so
    /// users get visible confirmation that the snapshot calibration
    /// landed (the actual save is silent on disk).
    @State private var showQuickZeroToast: Bool = false
    @State private var quickZeroToastMessage: String = ""

    /// True when any connected controller has a touchpad surface. The
    /// Calibrate Touchpad toolbar button is hidden otherwise.
    private var hasTouchpadCapableController: Bool {
        controllerService.controllerDetails.values.contains { $0.hasTouchpad }
    }

    /// True when any connected controller exposes motion sensors. Drives
    /// the Calibrate Motion toolbar button's visibility.
    private var hasMotionCapableController: Bool {
        controllerService.controllerDetails.values.contains { $0.supportsMotion }
    }

    var body: some View {
        editorBody
            // Every row names the face buttons for the family this preset is for.
            .environment(\.presetButtonFamily, preset.buttonFamily)
    }

    @ViewBuilder private var editorBody: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                // Plain VStack, deliberately NOT lazy. The editor has only a
                // handful of top-level sections, but one of them (a joystick
                // group) can be thousands of points tall. LazyVStack's item
                // phase tracking oscillates on huge children during fast
                // scrolling (LazyLayoutViewCache.updateItemPhase kept
                // re-dirtying the graph mid-layout), hanging the app. Eager
                // layout is deterministic and converges in one pass.
                VStack(alignment: .leading, spacing: 16) {
                    if enginePausedNotice {
                        EnginePausedBanner()
                    }

                    // Search the rows of this preset; a click scrolls to the row.
                    PresetSearchBar(preset: preset, naming: { [controllerService, preset] g in
                        let slots = controllerService.effectiveSlots(for: preset.joysticks)
                        return controllerService.naming(forSlot: slots[g] ?? g, presetFamily: preset.buttonFamily)
                    }) { hit in
                        finderJump = EditorJumpTarget(joystickIndex: hit.joystickIndex, inputSerialized: hit.inputSerialized,
                                                      bindingID: hit.id)
                    }

                    headerSection

                    if preset.joysticks.contains(where: { $0.bindings.contains { $0.input.type == .chassisTap } }) {
                        ChassisTapWarning(sensorPresent: hasChassisTapSensor)
                    }

                    Divider()

                    ForEach(preset.joysticks.indices, id: \.self) { index in
                        // Guard the subscript: while a group is being removed, a
                        // retained JoystickGroupView can re-render (on a live
                        // controller publish) with a now-out-of-range index.
                        if preset.joysticks.indices.contains(index) {
                            let joystick = preset.joysticks[index]
                            JoystickGroupView(
                                joystick: binding(for: index),
                                joystickIndex: index,
                                controllerName: controllerService.controllerName(at: index),
                                onAddBinding: { addBinding(to: index) },
                                onRemoveBinding: { bindIdx in removeBinding(at: bindIdx, from: index) },
                                onDuplicateBinding: { bindIdx in duplicateBinding(at: bindIdx, in: index) },
                                onScanInput: { bindIdx in startScan(joystickIndex: index, bindingIndex: bindIdx) },
                                onScanModifierInput: { bindIdx, slot in startScan(joystickIndex: index, bindingIndex: bindIdx, forModifier: true, modifierSlot: slot) },
                                onSortBindings: { sortBindings(in: index) },
                                onDuplicate: { duplicateJoystick(at: index) },
                                onRemoveJoystick: { removeJoystick(at: index) },
                                pulsingBindingID: pulsingBindingID,
                                revealThrough: revealBindingID,
                                revealAll: revealBindingID.map { id in
                                    (preset.joysticks.firstIndex { $0.bindings.contains { $0.id == id } } ?? -1) > index
                                } ?? false,
                                resolvedSlot: controllerService.effectiveSlots(for: preset.joysticks)[index],
                                // Plain values so the row views stay free of
                                // store subscriptions; used by the App Action
                                // output's target-preset picker.
                                availablePresets: presetStore.presets.map { (id: $0.id, name: $0.name) }
                            )
                            .id(joystick.id)
                        }
                    }
                    // Suppress the implicit remove transition so a deleted group
                    // is not retained (and re-rendered against a stale index)
                    // during a fade, mirroring the bindings list.
                    .animation(nil, value: preset.joysticks.count)

                    Button {
                        withAnimation {
                            preset.joysticks.append(JoystickMapping(tag: ""))
                        }
                    } label: {
                        Label("Add a new Input Device", systemImage: "plus.circle")
                            .frame(maxWidth: .infinity)
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: Metrics.innerRadius, style: .continuous)
                                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [6]))
                                    .foregroundStyle(.green.opacity(0.5))
                            )
                    }
                    .buttonStyle(.plain)

                    Divider()
                        .padding(.vertical, 8)

                    // Per-preset Automation: cursor / gaming utilities + auto-
                    // launch an app on activation. The collapsed state
                    // is a single-line summary; expanding reveals the
                    // toggles + path picker.
                    PresetAutomationSection(automation: $preset.automation)
                        .id("editor-automation")

                    // MARK: Accessibility Tools Suite
                    // Alternative-input schemes built for accessibility, with
                    // One-Stick Driving as the first tool. Anchored at the
                    // bottom as its own named category so it reads as a suite
                    // that will grow, not a stray extra.
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "figure.roll")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Accessibility Tools Suite")
                                    .font(.callout.weight(.semibold))
                                Text("Alternative input schemes built for accessibility.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isHeader)

                        DriveModeSection(driveConfig: $preset.driveConfig)
                            .id("editor-drive")
                    }
                    .padding(.top, 6)
                }
                .padding(20)
                // Transparent tap-anywhere layer that releases keyboard
                // focus from the Name / Tag fields. Child controls
                // (TextFields, Buttons, Pickers) hit-test first and keep
                // their normal click behavior; only a click on empty
                // editor whitespace falls through here.
                .background(
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { focusedHeaderField = nil }
                )
                .background(ScrollContentPrewarmer().frame(width: 0, height: 0))
            }
            // Content dissolves under the (now background-free) toolbar so the
            // top of the box reads like the glass body, matching the main
            // window instead of a distinct toolbar band.
            .headerFade()
            .background(NoInitialTextFocus().frame(width: 0, height: 0))
            .navigationTitle("Edit Bindings & Mappings")
            .overlay(alignment: .top) {
                // Brief confirmation toast for the Quick Zero toolbar
                // button. Calibration save is silent on disk; the toast
                // gives the user visible confirmation the click took
                // effect. Auto-dismisses ~2 s after quickZeroGyro fires.
                if showQuickZeroToast {
                    Text(quickZeroToastMessage)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .liquidGlass(in: Capsule())
                        .overlay(Capsule().stroke(Color.accentColor.opacity(0.4), lineWidth: 1))
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .accessibilityLabel(quickZeroToastMessage)
                        .accessibilityAddTraits(.isStaticText)
                }
            }
            .animation(.easeOut(duration: 0.2), value: showQuickZeroToast)
            .onAppear {
                // Saved and opened again: the undo history from before the
                // Save comes back, so Undo still steps back to how the
                // preset was. It closed with the editor before, and a change
                // just saved could only be taken back from Previous versions.
                if lastSnapshot == nil, undoStack.isEmpty, let kept = EditorHistory.history(for: preset) {
                    undoStack = kept
                }
                if lastSnapshot == nil { lastSnapshot = preset }
                if openedPreset == nil {
                    openedPreset = preset
                    runningAtOpen = liveEngine.isRunning && presetStore.activePresetId == preset.id
                }
                // Load your Shortcuts and applications now, in the
                // background, so the output menu opens instantly later.
                SystemListsCache.shared.refreshIfStale()
                // Screen region rows light as the pointer moves, which needs
                // the cursor sampled while the editor is open.
                updateCursorTracking()
                controllerService.retainLiveInput("editor")
                // The region editors and the row pickers work on the
                // services' working set: make it this preset's.
                preset.applyRegionsToServices()
                // Knocks should light up rows while the editor is open,
                // preset active or not. (Scan does not pick up taps.)
                // Only while the preset has a tap row: the accelerometer ran at
                // about 800 Hz for every preset being edited.
                updateTapSensor()
                updateKeyboardMouseMonitor()
                OpenEditor.current = OpenEditor(
                    name: { preset.name },
                    isDirty: { hasUnsavedChanges },
                    save: {
                        preset.captureRegionsFromServices()
                        EditorHistory.keep(undoStack, savedAs: preset)
                        onSave(preset)
                        restoreRunningPresetRegions(savedDraft: preset)
                    },
                    discard: { restoreRunningPresetRegions() },
                    close: { dismiss() },
                    presetID: preset.id,
                    draft: { preset },
                    edit: { change in change(&preset) })
            }
            .onDisappear {
                // Closed some other way than Save or Cancel (the Quick Start
                // tour, a window closing): the running preset's regions go
                // back, or its screen corners and zones did nothing until it
                // was started again.
                if !regionsRestored { restoreRunningPresetRegions() }
                OpenEditor.current = nil
                // A preset file opened while the editor was up.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { OpenedPresetFiles.flush() }
                ChassisTapService.shared.release("editor")
                ExternalInputDeviceService.shared.release(Self.externalHold)
                if trackingCursor {
                    CursorRegionService.shared.endTracking()
                    trackingCursor = false
                }
                controllerService.releaseLiveInput("editor")
            }
            .onChange(of: preset) { _, _ in recordHistory(); scheduleLiveApply() }
            .onChange(of: preset.cursorRegions.isEmpty) { _, _ in updateCursorTracking() }
            .modifier(EditorLiveHooks(hasTapRows: hasTapRows, keyboardMouseRows: keyboardMouseRows,
                                      onTapRowsChange: updateTapSensor,
                                      onKeyboardMouseChange: updateKeyboardMouseMonitor,
                                      drawingScreenRegions: $drawingScreenRegions,
                                      onDrawingDismiss: attachDrawnRegion))
            // While the editor is open, regions drawn in the sheet live in
            // the service and reach `preset` only on Save, so watch there too
            // or the first region's row did not light until a reopen.
            .onReceive(CursorRegionService.shared.$regions.map(\.isEmpty).removeDuplicates()) { _ in
                updateCursorTracking()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        // Nothing to lose: close. Otherwise ask, since Cancel
                        // and Escape used to throw away every change silently.
                        if hasUnsavedChanges {
                            confirmingCancel = true
                        } else {
                            restoreRunningPresetRegions()
                            dismiss()
                        }
                    }
                        .keyboardShortcut(.cancelAction)
                        .confirmationDialog("Save the changes to \u{201C}\(preset.name)\u{201D}?",
                                            isPresented: $confirmingCancel, titleVisibility: .visible) {
                            Button("Save") {
                                preset.captureRegionsFromServices()
                                EditorHistory.keep(undoStack, savedAs: preset)
                                onSave(preset)
                                restoreRunningPresetRegions(savedDraft: preset)
                                dismiss()
                            }
                            Button("Don\u{2019}t Save", role: .destructive) {
                                restoreRunningPresetRegions()
                                dismiss()
                            }
                            Button("Keep Editing", role: .cancel) {}
                        }
                        .buttonStyle(.solidSecondary)
                        .spotlightAnchor(SpotlightID.editorCancel)
                        .accessibilityLabel("Cancel editing")
                        .accessibilityHint("Closes the editor, asking first if there are unsaved changes")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        // Zones drawn while editing live in the services;
                        // take them into the preset so they save with it.
                        preset.captureRegionsFromServices()
                        EditorHistory.keep(undoStack, savedAs: preset)
                        onSave(preset)
                        restoreRunningPresetRegions(savedDraft: preset)
                        dismiss()
                    }
                    .buttonStyle(.solid)
                    // Command S, so Save is in reach even when the sheet is
                    // wider than the screen at a large Text Size.
                    .keyboardShortcut("s", modifiers: .command)
                    .spotlightAnchor(SpotlightID.editorSave)
                    .accessibilityLabel("Save preset")
                    .accessibilityHint("Saves the current bindings and closes the editor")
                }
                // Undo / Redo. Available everywhere in the editor and bound
                // to the standard Cmd+Z / Cmd+Shift+Z shortcuts. One item, so
                // the two stay together and in sight.
                ToolbarItemGroup(placement: .automatic) {
                    Button {
                        performUndo()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.solidSecondaryCompact)
                    .disabled(undoStack.isEmpty)
                    .keyboardShortcut("z", modifiers: .command)
                    .help("Undo")
                    .accessibilityLabel("Undo")
                    Button {
                        performRedo()
                    } label: {
                        Image(systemName: "arrow.uturn.forward")
                    }
                    .buttonStyle(.solidSecondaryCompact)
                    .disabled(redoStack.isEmpty)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .help("Redo")
                    .accessibilityLabel("Redo")
                }
                // A quiet way to help, beside undo and redo. Help opens in its
                // own window, so it works with the editor open; reaching out
                // goes to the project's issue page.
                ToolbarItem(placement: .automatic) {
                    // Short, and allowed to give way: at its full length
                    // and fixed size it took the room the toolbar had, and
                    // macOS moved Undo and Redo out of sight into the
                    // overflow menu.
                    HStack(spacing: 4) {
                        Text("Need help?")
                            .foregroundStyle(.secondary)
                        Button("Open Help") { HelpGuideWindowController.shared.show() }
                            .buttonStyle(.link)
                        Text("or please")
                            .foregroundStyle(.secondary)
                        Link("reach out", destination: URL(string: "https://github.com/ryleighnewman/InputConfig/issues")!)
                    }
                    .font(.callout)
                    .lineLimit(1)
                    .padding(.leading, 6)
                    .help("Trouble connecting a device or need help? Open Help, or please reach out")
                    .accessibilityElement(children: .contain)
                }
                // Touchpad calibration button - only visible when a
                // touchpad-capable controller (DualSense / DS4) is connected.
                // Calibrators (touchpad, motion, quick zero, taps) live in the
                // Options of the rows they tune; nothing on the toolbar.
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Sort All Bindings") {
                            preSortSnapshot = preset.joysticks
                            withAnimation { preset.sortBindings() }
                            postSortSnapshot = preset.joysticks
                        }

                        // Only while nothing has changed since the sort:
                        // later, it rolled back every edit made after it.
                        if preSortSnapshot != nil, postSortSnapshot == preset.joysticks {
                            Button("Undo Sort") {
                                if let snapshot = preSortSnapshot {
                                    withAnimation { preset.joysticks = snapshot }
                                    preSortSnapshot = nil
                                }
                            }
                        }

                        Divider()
                        Menu("Convert Controller Type…") {
                            ForEach(ControllerType.allCases.filter { !$0.conversionTargets.isEmpty }) { source in
                                Menu("From \(source.rawValue)") {
                                    ForEach(source.conversionTargets) { dest in
                                        Button("To \(dest.rawValue)") {
                                            preset = ControllerType.convert(preset: preset, from: source, to: dest)
                                        }
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.16), in: Capsule())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More: sort, undo sort, convert controller type")
                    .accessibilityLabel("More actions")
                    .accessibilityHint("Sort all bindings, undo sort, or convert controller type")
                }
            }
            .toolbarBackground(.hidden, for: .windowToolbar)
            .sheet(isPresented: $showingTouchpadCalibration) {
                TouchpadCalibrationView()
                    .environmentObject(presetStore)
                    .glassBackground()
            }
            .sheet(isPresented: $showingMotionCalibration) {
                MotionCalibrationView()
                    .environmentObject(controllerService)
                    .glassBackground()
            }
            .sheet(isPresented: $showingTapCalibration) {
                TapCalibrationView()
                    .glassBackground(windowTint: 0.3)   // as translucent as the main window
            }
            #if DEBUG
            // `post inputconfig.debug.editorsheet tap|motion` opens one of
            // the editor's own sheets, so they can be captured from outside.
            .onReceive({ () -> NotificationCenter.Publisher in
                DebugHookRelay.shared.ensure("inputconfig.debug.editorsheet")
                return NotificationCenter.default.publisher(for: Notification.Name("inputconfig.debug.editorsheet"))
            }()) { note in
                switch (note.object as? String) ?? "" {
                case "tap": showingTapCalibration = true
                case "motion": showingMotionCalibration = true
                default: break
                }
            }
            // `post inputconfig.debug.enrichrow <row number>` fills that row
            // of the first group, in memory only, with a combination the
            // engine really runs: a tap, a different action when held, a
            // double tap, and feedback. `enrichrow "macro <row number>"`
            // turns the same row into a macro instead, since a macro takes
            // the row over. Both exist so the Options panel can be captured
            // populated.
            .onReceive({ () -> NotificationCenter.Publisher in
                DebugHookRelay.shared.ensure("inputconfig.debug.enrichrow")
                return NotificationCenter.default.publisher(for: Notification.Name("inputconfig.debug.enrichrow"))
            }()) { note in
                enrichRowForCapture((note.object as? String) ?? "")
            }
            #endif
            .alert("Calibrate motion first?",
                   isPresented: $pendingMotionCalibrationOffer) {
                Button("Calibrate now") {
                    showingMotionCalibration = true
                }
                Button("Skip", role: .cancel) { }
            } message: {
                Text("You just scanned a gyroscope input. Without calibration, a still controller will still slowly drift the cursor. Run a 2-second calibration to set the resting zero.")
            }
            // Touchpad scan: a press and a tap feel the same under a finger, so
            // the person picks. Every option is offered; the ones the pad
            // actually reported are marked.
            .confirmationDialog(
                "Touchpad: which one?",
                isPresented: Binding(get: { pendingTouchpadChoice != nil },
                                     set: { if !$0 { pendingTouchpadChoice = nil } }),
                titleVisibility: .visible
            ) {
                if let seen = pendingTouchpadChoice {
                    let options: [InputEvent] = [
                        InputEvent.button(13),
                        InputEvent.touchpadGesture(.oneFingerTap),
                        InputEvent.touchpadGesture(.doubleTap),
                        InputEvent.touchpadGesture(.twoFingerTap),
                    ]
                    ForEach(options, id: \.serialized) { option in
                        let detected = seen.contains(where: { $0.serialized == option.serialized })
                        Button(touchpadOptionLabel(option) + (detected ? " (detected)" : "")) {
                            pendingTouchpadChoice = nil
                            handleScannedInput(option)
                        }
                    }
                    Button("Cancel", role: .cancel) { pendingTouchpadChoice = nil }
                }
            } message: {
                Text("A press is the pad clicked down; a tap is a finger touching and lifting without a click; a double tap is two of those quickly. Pick the one this row should react to. For a double press, keep the press and turn on When double tapped, do something else under Extra actions in the row's Options.")
            }
            // Post-scan prompt for axis + touchpad inputs: offer to auto-wire
            // the matching mouse motion, or keep the input raw so the user
            // can choose an output manually. For touchpad inputs we also
            // surface a one-tap "Calibrate first" shortcut so the resulting
            // mouse motion uses the user's actual touchpad bounds.
            .confirmationDialog(
                pendingScanMapping?.event.displayName ?? "Scanned input",
                isPresented: Binding(
                    get: { pendingScanMapping != nil },
                    set: { newValue in
                        if newValue == false { pendingScanMapping = nil }
                    }
                ),
                titleVisibility: .visible
            ) {
                if let pending = pendingScanMapping {
                    Button("Auto-map to mouse motion") {
                        applyScanMapping(pending, kind: .mouse)
                        pendingScanMapping = nil
                    }
                    if pending.isTouchpad {
                        Button("Calibrate touchpad first…") {
                            // Leave the raw input on the binding; user can
                            // come back and auto-map after calibrating.
                            applyScanMapping(pending, kind: .raw)
                            pendingScanMapping = nil
                            showingTouchpadCalibration = true
                        }
                    }
                    Button("Keep raw, I'll pick the output", role: .cancel) {
                        applyScanMapping(pending, kind: .raw)
                        pendingScanMapping = nil
                    }
                }
            } message: {
                if let pending = pendingScanMapping {
                    if pending.isTouchpad {
                        Text("This is a touchpad input. Auto-map sends mouse motion in the matching direction. If your touchpad hasn't been calibrated yet, calibrating first will make the cursor speed feel right.")
                    } else {
                        Text("Auto-map sends mouse motion in the matching direction. Keep raw to wire your own output (key, MIDI, macro, etc.).")
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: PresetEditorView.debugStartScanNotification)) { _ in
                #if DEBUG
                if !preset.joysticks.isEmpty, !preset.joysticks[0].bindings.isEmpty {
                    startScan(joystickIndex: 0, bindingIndex: 0)
                }
                #endif
            }
            .overlay {
                if showingScanOverlay {
                    ScanOverlayView(
                        controllerService: controllerService,
                        onInputDetected: { event in
                            handleScannedInput(event)
                        },
                        onCancel: {
                            showingScanOverlay = false
                            controllerService.stopScanning()
                        },
                        onTouchpadChoice: { candidates in
                            showingScanOverlay = false
                            controllerService.stopScanning()
                            // The chord scan has no ambiguity to resolve.
                            if scanningModifier, let first = candidates.first {
                                handleScannedInput(first)
                            } else {
                                pendingTouchpadChoice = candidates
                            }
                        }
                    )
                }
            }
            // Honor a pending jump-to-binding when the editor first appears,
            // and also any time ContentView updates the target (e.g. the user
            // clicks another input on the Live Visualizer while the editor is
            // already open).
            .onAppear {
                if let target = pendingJump {
                    performJump(to: target, using: proxy, sheetOpening: true)
                }
            }
            .onChange(of: finderJump) { _, newValue in
                if let target = newValue {
                    performJump(to: target, using: proxy)
                }
            }
            .onChange(of: pendingJump) { _, newValue in
                if let target = newValue {
                    performJump(to: target, using: proxy)
                }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: .inputConfigScrollToAutomation)) { _ in
                withAnimation(.easeInOut(duration: 0.6)) {
                    proxy.scrollTo("editor-automation", anchor: .top)
                }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: .inputConfigScrollToFirstBinding)) { _ in
                // Scroll to the first binding's ID so the Options
                // disclosure is in view. preset.joysticks.first?.bindings.first
                // gives the row's id; ForEach in JoystickGroupView
                // applies .id(binding.id) so this resolves.
                if let firstID = preset.joysticks.first?.bindings.first?.id {
                    withAnimation(.easeInOut(duration: 0.6)) {
                        proxy.scrollTo(firstID, anchor: .center)
                    }
                }
            }
            }  // ScrollViewReader
        }
    }

    // MARK: - Jump-to-binding

    /// Locate the binding row matching the jump target's joystick + input
    /// and scroll/pulse it. Walks the joystick group first to honor the
    /// click's controller-of-origin, then falls back to *any* joystick
    /// group that binds the same input.
    /// Snapshot every motion-capable connected controller's current
    /// gyro+accel reading and save it as their new resting baseline.
    /// One-frame variant of the multi-second still-hold capture in
    /// MotionCalibrationView; intended for quick re-zero when the
    /// controller is already at rest.
    /// After the editor closes, the services go back to holding the
    /// running preset's regions (or the just-saved preset's, when it is the
    /// one running), so a preset edited while another runs never leaves its
    /// zones behind in the engine.
    /// Hold a cursor-tracking claim exactly while this preset has screen
    /// regions, so their rows light as the pointer moves.
    private func updateCursorTracking() {
        let wants = !preset.cursorRegions.isEmpty || !CursorRegionService.shared.regions.isEmpty
        if wants && !trackingCursor {
            CursorRegionService.shared.beginTracking()
            trackingCursor = true
        } else if !wants && trackingCursor {
            CursorRegionService.shared.endTracking()
            trackingCursor = false
        }
    }

    #if DEBUG
    /// See `inputconfig.debug.enrichrow`.
    private func enrichRowForCapture(_ spec: String) {
        let words = spec.split(separator: " ")
        let asMacro = words.first == "macro"
        guard let n = Int(words.last ?? ""), !preset.joysticks.isEmpty,
              preset.joysticks[0].bindings.indices.contains(n - 1) else { return }
        var row = preset.joysticks[0].bindings[n - 1]
        row.turboEnabled = nil
        row.repeatCount = nil
        if words.first == "clipboard" {
            // Poster 03: a clipboard button where every setting runs on the
            // same press. Command and C together copy; it fires only while
            // L1 is held too; holding pastes and a double tap selects all;
            // a rumble and a spoken "Done" on every press.
            let cmd = { (key: Int) in [OutputAction(type: .key, keyCode: 227), OutputAction(type: .key, keyCode: key)] }
            row.outputs = cmd(6)
            row.macroSteps = nil
            row.turboEnabled = nil
            row.repeatCount = nil
            row.holdOutputs = cmd(25)
            row.holdThresholdMs = 400
            row.doubleTapOutputs = cmd(4)
            row.doubleTapWindowMs = 300
            if let l1 = InputEvent.parse("btn 4") { row.setModifiers([l1]) }
            row.hapticEnabled = true
            row.hapticIntensity = 0.7
            row.speechEnabled = true
            row.speechText = "Done"
            preset.joysticks[0].bindings[n - 1] = row
            return
        }
        if words.first == "classic" {
            // Poster 03 as 1.5 showed it: the row's own outputs, Repeats
            // while held twice per press, a double tap that sends Return, a
            // two-step Command C macro, and "Copied" with a 70% rumble.
            row.turboEnabled = true
            row.repeatCount = 2
            row.repeatDelayMs = 100
            row.holdOutputs = nil
            row.holdThresholdMs = nil
            row.doubleTapOutputs = [OutputAction(type: .key, keyCode: 40)]
            row.doubleTapWindowMs = 300
            row.macroSteps = [
                MacroStep(action: OutputAction(type: .key, keyCode: 227), delayMs: 0, holdMs: 40),
                MacroStep(action: OutputAction(type: .key, keyCode: 6), delayMs: 30, holdMs: 40),
            ]
            row.hapticEnabled = true
            row.hapticIntensity = 0.7
            row.speechEnabled = true
            row.speechText = "Copied"
            preset.joysticks[0].bindings[n - 1] = row
            return
        }
        if words.first == "copy" {
            // A one-button copy: Command and C go down together, the copy
            // repeats while the button is held, and it says "Copied" with a
            // rumble. Repeating runs on its own, so no hold, double tap or
            // macro sits beside it.
            row.outputs = [OutputAction(type: .key, keyCode: 227), OutputAction(type: .key, keyCode: 6)]
            row.macroSteps = nil
            row.holdOutputs = nil
            row.holdThresholdMs = nil
            row.doubleTapOutputs = nil
            row.doubleTapWindowMs = nil
            row.turboEnabled = true
            row.hapticEnabled = true
            row.hapticIntensity = 0.7
            row.speechEnabled = true
            row.speechText = "Copied"
            preset.joysticks[0].bindings[n - 1] = row
            return
        }
        if asMacro {
            row.holdOutputs = nil
            row.holdThresholdMs = nil
            row.doubleTapOutputs = nil
            row.doubleTapWindowMs = nil
            row.macroSteps = [
                MacroStep(action: OutputAction(type: .key, keyCode: 227), delayMs: 0, holdMs: 40),
                MacroStep(action: OutputAction(type: .key, keyCode: 6), delayMs: 30, holdMs: 40),
            ]
        } else {
            row.macroSteps = nil
            row.holdOutputs = [OutputAction(type: .key, keyCode: 41)]
            row.holdThresholdMs = 400
            row.doubleTapOutputs = [OutputAction(type: .key, keyCode: 40)]
            row.doubleTapWindowMs = 300
        }
        row.hapticEnabled = true
        row.hapticIntensity = 0.7
        row.speechEnabled = true
        row.speechText = "Sent"
        preset.joysticks[0].bindings[n - 1] = row
    }
    #endif

    /// The running engine takes the draft after a short pause, so typing in
    /// a field or dragging a slider reloads once at the end, not every step.
    /// An edit that would leave no rows, or take away the pointer or the
    /// navigation keys the saved preset has, is held until Save: the engine
    /// keeps the last version that still had them, so Undo, Cancel and Save
    /// stay in reach from the controller.
    private func scheduleLiveApply() {
        let draft = preset
        liveApplyTask?.cancel()
        liveApplyTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, liveEngine.isRunning,
                  presetStore.activePresetId == draft.id else { return }
            let saved = presetStore.presets.first(where: { $0.id == draft.id }) ?? draft
            if MappingEngine.draftKeepsWayOut(saved: saved, draft: draft) {
                if liveEngine.editorDraftHeld { liveEngine.editorDraftHeld = false }
                liveEngine.reload(with: draft)
            } else if !liveEngine.editorDraftHeld {
                liveEngine.editorDraftHeld = true
            }
        }
    }

    private func restoreRunningPresetRegions(savedDraft: Preset? = nil) {
        regionsRestored = true
        liveApplyTask?.cancel()
        liveEngine.editorDraftHeld = false
        // Closed without saving: the engine, which followed the draft, goes
        // back to the saved preset, and starts it again if an edit stopped it.
        if savedDraft == nil, let saved = presetStore.presets.first(where: { $0.id == preset.id }) {
            if liveEngine.isRunning {
                liveEngine.reload(with: saved)
            } else if runningAtOpen {
                MenuBarController.activate(saved, store: presetStore, engine: liveEngine, background: true)
            }
        }
        if let running = presetStore.presets.first(where: { $0.isActive }) {
            if let savedDraft, savedDraft.id == running.id {
                savedDraft.applyRegionsToServices()
            } else {
                running.applyRegionsToServices()
            }
        } else if let savedDraft {
            savedDraft.applyRegionsToServices()
        } else if let stored = presetStore.presets.first(where: { $0.id == preset.id }) {
            // Discarded with nothing running: the working set goes back to
            // the saved regions. Left holding the discarded draft, the
            // touchpad sheet opened later saved it into the preset.
            stored.applyRegionsToServices()
        }
    }

    private func quickZeroGyro() {
        var count = 0
        var moving = 0
        // Through the service's re-zero: it averages the recent gyro
        // samples and only stores a zero from a pad that is still. One raw
        // sample, taken whatever the pad was doing, stored the noise or
        // the movement as rest.
        for slot in controllerService.connectedControllers.indices {
            guard controllerService.rezeroMotion(slot: slot) else { continue }
            if controllerService.lastRezeroStoredZero { count += 1 } else { moving += 1 }
        }
        quickZeroToastMessage = count == 0 && moving == 0
            ? "No motion-capable controller connected"
            : count == 0
                ? "The controller was moving. Hold it still and try again"
                : "Gyro zeroed on \(count) controller\(count == 1 ? "" : "s")"
        showQuickZeroToast = true
        // The toast is a transient overlay VoiceOver would otherwise miss.
        // Announce the same message so the outcome reaches VoiceOver users.
        AccessibilityNotification.Announcement(quickZeroToastMessage).post()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            showQuickZeroToast = false
        }
    }

    private var hasTapRows: Bool {
        preset.joysticks.contains { $0.bindings.contains { $0.input.type == .chassisTap } }
    }

    /// Whether rows read the Mac's keyboard and its mouse.
    private var keyboardMouseRows: [Bool] {
        let types = preset.joysticks.flatMap(\.bindings).map(\.input.type)
        return [types.contains(.extKey), types.contains(.extMouse)]
    }

    private static let externalHold = "editor"

    /// Keys and mouse buttons light their rows while the editor is open,
    /// preset running or not: the keyboard and mouse are only listened to
    /// while something asks, and nothing asked while editing, so a row
    /// whose key was just scanned stayed dark when the key was pressed.
    private func updateKeyboardMouseMonitor() {
        let rows = keyboardMouseRows
        if rows.contains(true) {
            ExternalInputDeviceService.shared.retain(Self.externalHold, mouse: rows[1], keyboard: rows[0])
        } else {
            ExternalInputDeviceService.shared.release(Self.externalHold)
        }
    }

    private func updateTapSensor() {
        if hasChassisTapSensor && hasTapRows {
            ChassisTapService.shared.retain("editor")
        } else {
            ChassisTapService.shared.release("editor")
        }
    }

    /// One smooth sequence: let the sheet finish sliding in (scrolling
    /// during the slide is what stuttered), glide the row to the middle,
    /// then light it once it has arrived and hold the light long enough to
    /// find it.
    private func performJump(to target: EditorJumpTarget, using proxy: ScrollViewProxy, sheetOpening: Bool = false) {
        if target.action == .addScreenRegion {
            addScreenRegionRow(group: target.joystickIndex, using: proxy, sheetOpening: sheetOpening)
            return
        }
        guard let bindingID = locateBindingID(for: target) else { return }
        // A collapsed group has no rows to scroll to; open it first.
        if let g = preset.joysticks.firstIndex(where: { $0.bindings.contains { $0.id == bindingID } }),
           !preset.joysticks[g].isExpanded {
            preset.joysticks[g].isExpanded = true
        }
        jumpToken &+= 1
        let token = jumpToken
        pulsingBindingID = nil
        revealBindingID = bindingID
        // On open, after the sheet has slid in and its rows are all built
        // (the group builds them in batches just after the slide).
        let settle = sheetOpening ? 0.6 : 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
            guard token == jumpToken else { return }
            withAnimation(.smooth(duration: 0.55)) {
                proxy.scrollTo(bindingID, anchor: .center)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + settle + 0.4) {
            guard token == jumpToken else { return }
            pulsingBindingID = bindingID
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + settle + 0.4 + 2.2) {
            guard token == jumpToken, pulsingBindingID == bindingID else { return }
            pulsingBindingID = nil
        }
    }

    /// The visualizer's "Draw a screen region": a Screen region row in the
    /// slot's group, scrolled to and lit, then the drawing sheet; when the
    /// sheet closes, the row takes the first region it does not have yet.
    private func addScreenRegionRow(group: Int, using proxy: ScrollViewProxy, sheetOpening: Bool) {
        if preset.joysticks.isEmpty { preset.joysticks.append(JoystickMapping(tag: "", bindings: [])) }
        let g = min(max(group, 0), preset.joysticks.count - 1)
        var row = BindingModel(input: InputEvent(type: .cursorRegion, index: 0), outputs: [])
        row.section = "Screen regions"
        preset.joysticks[g].bindings.append(row)
        preset.joysticks[g].isExpanded = true
        regionRowAwaitingRegion = row.id
        regionsBeforeDrawing = Set(CursorRegionService.shared.allRegions().map(\.id))
        performJump(to: EditorJumpTarget(joystickIndex: g, inputSerialized: row.input.serialized, bindingID: row.id),
                    using: proxy, sheetOpening: sheetOpening)
        DispatchQueue.main.asyncAfter(deadline: .now() + (sheetOpening ? 0.9 : 0.5)) { drawingScreenRegions = true }
    }

    /// After the drawing sheet closes: the waiting row takes the region
    /// drawn there (or, failing that, the first one no row uses yet).
    private func attachDrawnRegion() {
        guard let rowID = regionRowAwaitingRegion else { return }
        regionRowAwaitingRegion = nil
        let regions = CursorRegionService.shared.allRegions()
        let used = Set(preset.joysticks.flatMap(\.bindings).compactMap(\.input.cursorRegionID))
        guard let region = regions.first(where: { !regionsBeforeDrawing.contains($0.id) })
                ?? regions.first(where: { !used.contains($0.id) }) else {
            // Nothing drawn and nothing free: the waiting row goes, rather
            // than staying as an empty row the editor would save.
            for g in preset.joysticks.indices {
                preset.joysticks[g].bindings.removeAll { $0.id == rowID && $0.outputs.isEmpty }
            }
            return
        }
        for g in preset.joysticks.indices {
            if let i = preset.joysticks[g].bindings.firstIndex(where: { $0.id == rowID }) {
                preset.joysticks[g].bindings[i].input.cursorRegionID = region.id
            }
        }
    }

    private func locateBindingID(for target: EditorJumpTarget) -> UUID? {
        if let id = target.bindingID,
           preset.joysticks.contains(where: { $0.bindings.contains { $0.id == id } }) {
            return id
        }
        // 1) Prefer a binding in the joystick group that matches the
        // visualizer's controller slot.
        if target.joystickIndex < preset.joysticks.count {
            let group = preset.joysticks[target.joystickIndex]
            if let hit = group.bindings.first(where: { $0.input.serialized == target.inputSerialized }) {
                return hit.id
            }
        }
        // 2) Fall back: search every joystick for any binding that matches.
        for group in preset.joysticks {
            if let hit = group.bindings.first(where: { $0.input.serialized == target.inputSerialized }) {
                return hit.id
            }
        }
        return nil
    }

    // MARK: - Engine Paused Banner

    /// Yellow banner at the top of the editor while a preset is being edited
    /// over a running engine. Outputs are paused (no cursor motion, no
    /// keystrokes, no MIDI) but the engine keeps polling inputs so the green
    /// row highlight still fires when you press a button on the controller.
    /// Outputs resume automatically when the editor closes.

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Name:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
                TextField("Preset Name", text: $preset.name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedHeaderField, equals: .name)
            }
            HStack {
                Text("Tag:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
                TextField("Tag / Description", text: $preset.tag)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedHeaderField, equals: .tag)
            }
            HStack(spacing: 8) {
                Text("Key:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
                if let spec = preset.activateHotKey {
                    HotKeyRecorderField(spec: spec, label: "Preset shortcut") { preset.activateHotKey = $0 }
                        // Undo and Redo change the chord from outside.
                        .id(spec)
                    Button("Remove") { preset.activateHotKey = nil }
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if PresetHotKeyService.conflicts(for: spec, excluding: preset.id,
                                                     in: presetStore.presets) {
                        Label("Another shortcut already uses this", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    } else if PresetHotKeyService.shared.failed.contains(preset.id),
                              preset.activateHotKey == presetStore.presets.first(where: { $0.id == preset.id })?.activateHotKey {
                        Label("Another app already uses this shortcut", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    } else {
                        Text("Switches to this preset from anywhere. Press it again to stop.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button("Add a shortcut") {
                        preset.activateHotKey = HotKeySpec(
                            keyCode: UInt32(kVK_ANSI_1),
                            modifiers: UInt32(controlKey | optionKey | cmdKey))
                    }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(Color.accentColor)
                    Text("A system-wide key that turns this preset on.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Undo / Redo

    /// Record the previous preset value before a change. Called from the
    /// editor's `.onChange(of: preset)` observer. Skips recording when
    /// `isApplyingHistory` is true so undo/redo themselves don't pollute
    /// the history. Redo is cleared on any fresh edit, like every other
    /// editor on the planet.
    private func recordHistory() {
        guard !isApplyingHistory else { return }
        if let previous = lastSnapshot, previous != preset,
           Self.ignoringLayout(previous) != Self.ignoringLayout(preset) {
            undoStack.append(previous)
            // Bound the history so a long editing session can't grow an
            // unbounded stack of whole-preset deep copies.
            if undoStack.count > 100 {
                undoStack.removeFirst(undoStack.count - 100)
            }
            redoStack.removeAll()
        }
        lastSnapshot = preset
    }

    private func performUndo() {
        guard let previous = undoStack.popLast() else { return }
        isApplyingHistory = true
        redoStack.append(preset)
        preset = previous
        lastSnapshot = previous
        DispatchQueue.main.async { isApplyingHistory = false }
    }

    private func performRedo() {
        guard let next = redoStack.popLast() else { return }
        isApplyingHistory = true
        undoStack.append(preset)
        preset = next
        lastSnapshot = next
        DispatchQueue.main.async { isApplyingHistory = false }
    }

    // MARK: - Binding Helpers

    private func binding(for joystickIndex: Int) -> SwiftUI.Binding<JoystickMapping> {
        // Bounds-safe: a binding captured by a group that is mid-removal must
        // never trap if it is read once more before SwiftUI tears the row down.
        SwiftUI.Binding(
            get: { preset.joysticks.indices.contains(joystickIndex)
                   ? preset.joysticks[joystickIndex] : JoystickMapping() },
            set: { if preset.joysticks.indices.contains(joystickIndex) {
                       preset.joysticks[joystickIndex] = $0 } }
        )
    }

    private func addBinding(to joystickIndex: Int) {
        withAnimation {
            let newBinding = BindingModel(
                input: InputEvent.button(0),
                outputs: [OutputAction(type: .key, keyCode: 4)]
            )
            preset.joysticks[joystickIndex].bindings.append(newBinding)
        }
    }

    private func removeBinding(at bindingIndex: Int, from joystickIndex: Int) {
        withAnimation {
            preset.joysticks[joystickIndex].bindings.remove(at: bindingIndex)
        }
    }

    private func duplicateBinding(at bindingIndex: Int, in joystickIndex: Int) {
        withAnimation {
            let original = preset.joysticks[joystickIndex].bindings[bindingIndex]
            // duplicated() carries every advanced field; the bare
            // initializer silently dropped turbo, macros, deadzone, etc.
            let clone = original.duplicated()
            preset.joysticks[joystickIndex].bindings.insert(clone, at: bindingIndex + 1)
        }
    }

    private func sortBindings(in joystickIndex: Int) {
        // Delegate to the model's authoritative sort which covers every
        // InputType case. Earlier this view had its own truncated
        // table (button/axis/hat only) that silently collapsed every
        // other input type to slot 0 in the editor list.
        // Within each section, sections kept in their order, so a heading
        // never splits into two runs.
        withAnimation {
            let rows = preset.joysticks[joystickIndex].bindings
            var sectionRank: [String: Int] = [:]
            for row in rows where sectionRank[row.section ?? ""] == nil {
                sectionRank[row.section ?? ""] = sectionRank.count
            }
            preset.joysticks[joystickIndex].bindings.sort { a, b in
                let sa = sectionRank[a.section ?? ""] ?? 0, sb = sectionRank[b.section ?? ""] ?? 0
                if sa != sb { return sa < sb }
                let aOrder = Self.bindingSortOrder(for: a.input.type)
                let bOrder = Self.bindingSortOrder(for: b.input.type)
                if aOrder != bOrder { return aOrder < bOrder }
                return a.input.index < b.input.index
            }
        }
    }

    private static func bindingSortOrder(for type: InputType) -> Int {
        switch type {
        case .button:          return 0
        case .axis:            return 1
        case .hat:             return 2
        case .touchpad:        return 3
        case .touchpadRegion:  return 4
        case .touchpadGesture: return 5
        case .motion:          return 6
        case .extKey:          return 7
        case .extMouse:        return 8
        case .cursorRegion:    return 9
        case .stickRegion:     return 10
        case .midi:            return 11
        case .chassisTap:      return 12
        }
    }

    private func duplicateJoystick(at index: Int) {
        withAnimation {
            let source = preset.joysticks[index]
            // Carry the slot's own settings across too. Rebuilding from just
            // (tag, bindings) dropped customName and inputKind, so a
            // duplicated slot lost its name and reverted to auto-detect.
            var clone = JoystickMapping(
                tag: source.tag,
                bindings: source.bindings.map { $0.duplicated() },
                isExpanded: source.isExpanded
            )
            clone.customName = source.customName
            clone.inputKind = source.inputKind
            // And the model it is drawn and named as, its device
            // fingerprint, and what this build could not read in it.
            clone.controllerModel = source.controllerModel
            clone.deviceFingerprint = source.deviceFingerprint
            clone.extraFields = source.extraFields
            clone.unreadableRows = source.unreadableRows
            preset.joysticks.insert(clone, after: index)
        }
    }

    private func removeJoystick(at index: Int) {
        withAnimation {
            preset.joysticks.remove(at: index)
        }
    }

    // MARK: - Scanning

    /// DEBUG: open a scan on the first row, so the scanner can be exercised
    /// and the scan overlay captured for marketing without a human click.
    static let debugStartScanNotification = Notification.Name("InputConfig.DebugStartScan")

    private func startScan(joystickIndex: Int, bindingIndex: Int, forModifier: Bool = false, modifierSlot: Int? = nil) {
        scanningModifier = forModifier
        scanningModifierSlot = forModifier ? modifierSlot : nil
        // Release any keyboard focus from the Name / Tag fields so that
        // pressing keys during scan doesn't accidentally type into them.
        // (The user's intent during a scan is to identify a controller
        // input, not to edit the preset name.)
        focusedHeaderField = nil
        scanningBinding = (joystickIndex, bindingIndex)
        showingScanOverlay = true
        controllerService.startScanning { event in
            // Input received - handled in handleScannedInput
        }
    }

    private func touchpadOptionLabel(_ e: InputEvent) -> String {
        if e.type == .button { return "Touchpad press (click the pad down)" }
        switch e.touchpadGestureKind {
        case .oneFingerTap: return "Touchpad tap (one finger)"
        case .doubleTap: return "Touchpad double tap"
        case .twoFingerTap: return "Two-finger tap"
        default: return e.displayName
        }
    }

    private func handleScannedInput(_ event: InputEvent) {
        guard let scanning = scanningBinding else { return }
        if scanningModifier {
            // Chord control: anything the scanner can see qualifies, since
            // the engine checks the modifier with the same code as a row
            // input. The row's own input is left alone.
            // Scan from an existing slot's menu replaces that control;
            // the Scan button adds to the chord, up to three.
            var row = preset.joysticks[scanning.joystickIndex].bindings[scanning.bindingIndex]
            var mods = row.modifiers
            // Any MIDI device, as for a row input: pinned to one CoreMIDI ID,
            // the chord never fired after a re-pair or on another Mac.
            var event = event
            if event.type == .midi { event.midiDeviceID = nil }
            if let slot = scanningModifierSlot, mods.indices.contains(slot) {
                mods[slot] = event
            } else {
                mods.append(event)
            }
            row.setModifiers(mods)
            scanningModifierSlot = nil
            preset.joysticks[scanning.joystickIndex].bindings[scanning.bindingIndex] = row
            showingScanOverlay = false
            controllerService.stopScanning()
            scanningBinding = nil
            scanningModifier = false
            return
        }
        // Always record the input on the binding so the row reflects what
        // the user just scanned.
        // A scanned MIDI row keeps its channel but listens to any device,
        // as Help says: CoreMIDI's device IDs differ on another Mac and
        // after a Bluetooth re-pair, and a pinned row then never fired.
        // A device is pinned only when picked from the row's menu.
        var scanned = event
        if scanned.type == .midi { scanned.midiDeviceID = nil }
        // A knob scanned onto a row that already reads a knob keeps how the
        // row reads it (Switch, Dial or Turn, its direction and step): the
        // built-in MIDI decks' Turn pairs both became Switch rows.
        let previous = preset.joysticks[scanning.joystickIndex].bindings[scanning.bindingIndex].input
        if scanned.type == .midi, previous.type == .midi, scanned.midiKind == previous.midiKind,
           scanned.midiKind == .cc || scanned.midiKind == .pitchBend {
            scanned.midiCCMode = previous.midiCCMode
            scanned.axisDirection = previous.axisDirection
            scanned.midiTurnStep = previous.midiTurnStep
        }
        preset.joysticks[scanning.joystickIndex].bindings[scanning.bindingIndex].input = scanned
        // Remember which device these rows came from, when the press came
        // from the controller this group drives: its pinned controller, or
        // the slot it falls back to, not simply the slot with its number.
        let drivenSlot = controllerService.effectiveSlots(for: preset.joysticks)[scanning.joystickIndex]
            ?? scanning.joystickIndex
        if controllerService.lastScanSlot == drivenSlot,
           let fingerprint = controllerService.deviceFingerprint(forSlot: drivenSlot),
           preset.joysticks[scanning.joystickIndex].deviceFingerprint != fingerprint {
            preset.joysticks[scanning.joystickIndex].deviceFingerprint = fingerprint
        }
        showingScanOverlay = false
        controllerService.stopScanning()

        // Motion-scanned input: gate on calibration. If no motion-capable
        // controller has been calibrated, prompt the user to run calibration
        // first - tilt-to-aim feels wrong otherwise.
        if event.type == .motion {
            let anyCalibrated = controllerService.connectedControllers.contains { ctrl in
                let key = MotionCalibrationService.identityKey(for: ctrl)
                return MotionCalibrationService.shared.isCalibrated(forKey: key)
            }
            if !anyCalibrated {
                // Show ONLY the calibration offer, not the auto-map dialog on
                // top of it. The motion input is already recorded on the
                // binding; the user calibrates first, then wires the output.
                pendingMotionCalibrationOffer = true
                scanningBinding = nil
                return
            }
        }

        // For axis + touchpad + motion inputs, offer to auto-wire the
        // output. Plain button presses don't get this dialog - the user
        // already knows it's a button-style binding.
        let isAxis = event.type == .axis
        let isTouchpad = event.type == .touchpad
        let isMotion = event.type == .motion
        if isAxis || isTouchpad || isMotion {
            pendingScanMapping = PendingScanMapping(
                event: event,
                joystickIndex: scanning.joystickIndex,
                bindingIndex: scanning.bindingIndex,
                isDirectional: true,
                isTouchpad: isTouchpad
            )
        }

        scanningBinding = nil
    }

    /// Apply the user's choice from the post-scan confirmation dialog.
    /// `.mouse` auto-wires a mouse-motion output in the matching direction;
    /// `.raw` keeps just the recorded input and lets the user pick an output
    /// manually. Used by both the axis-scan and touchpad-scan flows.
    private enum ScanAutoMapping { case mouse, raw }

    private func applyScanMapping(_ pending: PendingScanMapping, kind: ScanAutoMapping) {
        switch kind {
        case .raw:
            // Nothing to do - the input is already recorded.
            return
        case .mouse:
            // Translate the input direction into a sensible mouseMotion
            // output. Standard convention: axis 0/touchpad-X → horizontal,
            // axis 1/touchpad-Y → vertical. Direction flows straight from
            // the scanned event's axisDirection.
            let mouseAxis: MouseAxis
            let mouseDirection: MouseDirection
            switch pending.event.type {
            case .axis:
                // Even axes (0, 2, 4) are X-style, odd (1, 3) Y-style in MFi.
                mouseAxis = (pending.event.index % 2 == 0) ? .horizontal : .vertical
                mouseDirection = (pending.event.axisDirection == .negative) ? .negative : .positive
            case .touchpad:
                mouseAxis = (pending.event.touchpadAxis == .y) ? .vertical : .horizontal
                mouseDirection = (pending.event.axisDirection == .negative) ? .negative : .positive
            case .motion:
                // Gyro Y (yaw rate) -> horizontal mouse, Gyro X (pitch)
                // -> vertical mouse. Z (roll) is unusual to bind so we
                // default to horizontal too. Matches the Showcase: Gyro
                // Aim preset's defaults.
                switch pending.event.motionChannel {
                case .gyroY, .yawAngle:
                    mouseAxis = .horizontal
                case .gyroX, .pitchAngle:
                    mouseAxis = .vertical
                default:
                    mouseAxis = .horizontal
                }
                // Yaw is straight (a positive gyro Y rate is a turn to the
                // right); pitch is crossed (a positive gyro X rate is nose
                // up, screen Y grows downward). See MotionChannel.
                let crossed = (pending.event.motionChannel == .gyroX || pending.event.motionChannel == .pitchAngle)
                let inputPositive = pending.event.axisDirection != .negative
                mouseDirection = (inputPositive != crossed) ? .positive : .negative
            default:
                return
            }
            let speed: Int
            switch pending.event.type {
            case .touchpad: speed = 12
            case .motion:   speed = 14  // Gyro is sensitive; lower-than-stick speed feels right.
            default:        speed = 18
            }
            let output = OutputAction(type: .mouseMotion,
                                      mouseAxis: mouseAxis,
                                      mouseDirection: mouseDirection,
                                      speed: speed)
            preset.joysticks[pending.joystickIndex].bindings[pending.bindingIndex].outputs = [output]
            // Sensible defaults to make this feel like the showcase preset.
            var binding = preset.joysticks[pending.joystickIndex].bindings[pending.bindingIndex]
            binding.variableSensitivity = true
            if pending.event.type == .axis {
                // Mild smooth curve + moderate deadzone for joysticks.
                binding.deadzone = 0.10
                binding.sensitivityCurve = .exponential
            }
            preset.joysticks[pending.joystickIndex].bindings[pending.bindingIndex] = binding
        }
    }
}

// Helper extension for inserting after an index
private extension Array {
    mutating func insert(_ element: Element, after index: Int) {
        let insertIndex = Swift.min(index + 1, count)
        insert(element, at: insertIndex)
    }
}


// MARK: - Initial focus

/// Stops AppKit handing the freshly presented sheet's keyboard focus to the
/// preset-name field.
///
/// Nobody opens the binding editor to rename the preset, so the focus was
/// unwanted to begin with, and it was expensive: a focused `TextField` puts
/// AppKit's field editor - the window's only `cursorUpdate` tracking area -
/// inside the scrolling content. Every frame that content moves, AppKit marks
/// tracking regions dirty and resets the cursor, and a customized pointer
/// (Accessibility > Display > Pointer) makes each of those resets regenerate
/// and re-upload the cursor images to WindowServer. That showed up as
/// `displayCycleUpdateStructuralRegions -> NSCursor set ->
/// SLSRegisterCursorWithImages` eating roughly half the editor's scroll time.
///
/// Clicking the field still focuses it normally.
private struct NoInitialTextFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> ClearFocusView { ClearFocusView() }
    func updateNSView(_ nsView: ClearFocusView, context: Context) {}

    final class ClearFocusView: NSView {
        private var done = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !done, let window else { return }
            done = true
            window.initialFirstResponder = nil
            // SwiftUI installs the field editor after the sheet is on screen,
            // so clear once now and once on the next turn of the run loop.
            clear(window)
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                window.initialFirstResponder = nil
                self.clear(window)
            }
        }

        private func clear(_ window: NSWindow) {
            if window.firstResponder is NSText {
                window.makeFirstResponder(nil)
            }
        }
    }
}

/// One line under the header when this preset binds Tap the Mac but the
/// sensor cannot be heard: absent on this Mac, or macOS refused the wake and
/// nothing is arriving. Polled every couple of seconds since the tap service
/// is not observable.
private struct ChassisTapWarning: View {
    let sensorPresent: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var message: String? {
        guard sensorPresent else {
            return "This Mac has no motion sensor, so the Tap the Mac bindings will not fire."
        }
        let s = ChassisTapService.shared.calibrationSnapshot(window: 0)
        if s.running && s.wakeDenied && s.silence > 0.5 {
            return "macOS refused to switch the motion sensor on, so taps are not being heard right now."
        }
        if s.running && s.notResponding {
            return "The motion sensor on this Mac is not responding, so taps are not being heard."
        }
        return nil
    }
}

/// Yellow banner at the top of the editor while a preset is being edited
/// over a running engine. Its own view, so only it observes the engine.
private struct EnginePausedBanner: View {
    @EnvironmentObject private var mappingEngine: MappingEngine

    /// Whether the running preset's pointer rows still work in the editor.
    private var pointerPasses: Bool { mappingEngine.editorPassthroughApplies }
    private var overridden: Bool { mappingEngine.editorOverride }

    private var held: Bool { mappingEngine.editorDraftHeld }

    private var title: String {
        if held { return "This change waits for Save, so you can still get around" }
        if overridden { return "The controller works while editing" }
        return pointerPasses ? "Paused while editing, except the pointer and Escape, Return, Tab, arrows and Space" : "Outputs paused while editing"
    }

    private var detail: String {
        if held {
            return "Your edits apply to the running preset as you make them, but this one would leave it with no rows, or take away the pointer or the Escape, Return, Tab, arrow and Space rows, and then the controller could not reach Undo, Cancel or Save. The running preset keeps its last version until you save."
        }
        if overridden {
            return "Override is on: the running preset sends everything, keys and MIDI included, while the editor is open. Scan still holds outputs back while it listens. Your edits apply as you make them; Cancel puts the saved preset back."
        }
        return pointerPasses
            ? "Other keys and MIDI are paused while editing. The controller still moves the pointer, clicks, scrolls, and sends Escape, Return, Tab, the arrows and Space, so Save and Cancel stay in reach. Inputs still highlight rows. Override lets the running preset work fully while you edit."
            : "Outputs paused while editing. Inputs still highlight rows; the cursor, keystrokes, and MIDI resume when you close the editor. Override lets the running preset work fully while you edit."
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: overridden ? "play.circle.fill" : "pause.circle.fill")
                .font(.callout)
                .iconTint(overridden ? .green : .yellow)
            Text(title)
                .font(.callout.weight(.semibold))
            Button(overridden ? "Pause Again" : "Override") {
                mappingEngine.editorOverride.toggle()
            }
            .buttonStyle(.solidSecondaryCompact)
            .controlSize(.small)
            .help(overridden ? "Pause the running preset's outputs while the editor is open"
                             : "Let the running preset work fully while the editor is open")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill((overridden ? Color.green : Color.yellow).opacity(0.15))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke((overridden ? Color.green : Color.yellow).opacity(0.55), lineWidth: 1)
        )
        .frame(maxWidth: .infinity)
        .help(detail)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(detail)
    }
}

/// The editor's live-input hooks and the region drawing sheet the
/// visualizer's "Draw a screen region" opens, in one modifier so the
/// editor's long modifier chain stays cheap to type-check.
private struct EditorLiveHooks: ViewModifier {
    let hasTapRows: Bool
    let keyboardMouseRows: [Bool]
    let onTapRowsChange: () -> Void
    let onKeyboardMouseChange: () -> Void
    @Binding var drawingScreenRegions: Bool
    let onDrawingDismiss: () -> Void
    func body(content: Content) -> some View {
        content
            .onChange(of: hasTapRows) { _, _ in onTapRowsChange() }
            .onChange(of: keyboardMouseRows) { _, _ in onKeyboardMouseChange() }
            .sheet(isPresented: $drawingScreenRegions, onDismiss: onDrawingDismiss) {
                CursorRegionsView().glassBackground()
            }
    }
}

/// Asks the editor's scroll view to draw all of its rows once they are
/// built, instead of only the visible ones. AppKit draws content beyond the
/// visible area only while the app is idle, which right after the editor
/// opens it is not, so the first scroll drew each row as it came into view
/// and dropped frames; every later scroll was smooth.
private struct ScrollContentPrewarmer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { PrewarmView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class PrewarmView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            // After the rows' staged build (JoystickGroupView's reveal).
            for delay in [1.0, 2.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let scroll = self?.enclosingScrollView, let document = scroll.documentView else { return }
                    document.prepareContent(in: document.bounds)
                }
            }
        }
    }
}


/// Each preset's editor undo history, kept for the app session when the
/// editor saves, so opening the editor again can still undo what was saved.
/// Used only while the preset is still exactly as that Save left it.
@MainActor
enum EditorHistory {
    private static var kept: [UUID: (undo: [Preset], savedAs: Preset)] = [:]

    static func keep(_ undo: [Preset], savedAs preset: Preset) {
        guard !undo.isEmpty else { kept[preset.id] = nil; return }
        kept[preset.id] = (Array(undo.suffix(100)), preset)
    }

    static func history(for preset: Preset) -> [Preset]? {
        guard let entry = kept[preset.id], comparable(entry.savedAs) == comparable(preset) else { return nil }
        return entry.undo
    }

    /// The content only: the store stamps the save time and owns whether
    /// it runs, and a group's open or closed state is not an edit.
    private static func comparable(_ p: Preset) -> Preset {
        var copy = p
        copy.modifiedAt = Date(timeIntervalSince1970: 0)
        copy.isActive = false
        copy.sortOrder = nil
        for i in copy.joysticks.indices { copy.joysticks[i].isExpanded = true }
        return copy
    }
}
