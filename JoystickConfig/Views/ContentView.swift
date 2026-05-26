import SwiftUI
import GameController

/// Notifications used by the macOS menu bar (Controller and View menus)
/// to drive UI actions on the active ContentView. Posted from
/// JoystickConfigMain's `.commands`; handled by `onReceive` blocks in
/// ContentView below.
extension Notification.Name {
    static let joystickConfigShowStats              = Notification.Name("JoystickConfig.ShowStats")
    static let joystickConfigToggleActivePreset     = Notification.Name("JoystickConfig.ToggleActive")
    static let joystickConfigOpenTouchpadCalibration = Notification.Name("JoystickConfig.OpenTouchpadCal")
    static let joystickConfigOpenMotionCalibration   = Notification.Name("JoystickConfig.OpenMotionCal")
    static let joystickConfigStartTutorial          = Notification.Name("JoystickConfig.StartTutorial")
    static let joystickConfigScrollToPreset         = Notification.Name("JoystickConfig.ScrollToPreset")
}

struct ContentView: View {
    @EnvironmentObject var presetStore: PresetStore
    @EnvironmentObject var controllerService: GameControllerService
    @EnvironmentObject var mappingEngine: MappingEngine
    @EnvironmentObject var eightBitDoDetector: EightBitDoDetector

    @State private var selectedPresetId: UUID?
    @State private var editingPreset: Preset?
    @State private var newlyCreatedPresetId: UUID?
    @State private var showingImportSheet = false
    @State private var presentedDemoKind: FeatureDemoKind?
    @State private var showingStats: Bool = false
    @State private var showingSettingsSheet: Bool = false
    @State private var showingTouchpadCalibrationFromMenu: Bool = false
    @State private var showingMotionCalibrationFromMenu: Bool = false
    /// Carries a preset waiting for the user to acknowledge a calibration
    /// prompt before its mapping engine starts.
    @State private var pendingActivation: (preset: Preset, reqs: CalibrationRequirements)?
    /// Tracks whether the mapping engine was running when the user opened the
    /// preset editor, so we can flag that in the editor's banner and decide
    /// whether to offer to re-activate on close.
    @State private var engineWasRunningBeforeEdit: Bool = false
    /// When the user clicks an input on the Live Visualizer, we stash the
    /// jump target here. The PresetEditorView sheet reads this on appear and
    /// scrolls + pulses the matching binding row.
    @State private var pendingEditorJump: EditorJumpTarget?
    /// Preset queued for confirm-delete. Drives the .confirmationDialog so
    /// users can't permanently wipe a preset with a single misclick.
    @State private var presetPendingDelete: Preset?
    /// Shown when the Trash disclosure in the sidebar is expanded.
    @State private var showingTrashDisclosure: Bool = false
    /// Briefly set to a preset UUID when we want the sidebar row to
    /// flash. Cleared after the animation completes.
    @State private var flashingPresetID: UUID?
    /// Live map of tutorial-anchor ids to their global frames. Refreshed
    /// by .onPreferenceChange so the spotlight overlay tracks UI moves.
    @State private var tutorialAnchors: [String: CGRect] = [:]
    /// Shared tutorial controller - drives both the spotlight overlay
    /// (here in the main window) and the floating tutorial card panel.
    @StateObject private var tutorialState = TutorialState.shared
    /// Index of the welcome-page feature card currently being showcased
    /// by the tutorial. Drives a pulsing highlight + auto-opens its demo
    /// sheet during the "example presets" tutorial step.
    @State private var tutorialFeatureSpotlight: FeatureDemoKind?

    var body: some View {
        NavigationSplitView {
            sidebarView
        } detail: {
            detailView
        }
        // Kill the blue keyboard-focus ring that macOS draws around toolbar
        // buttons (including the system sidebar toggle and our Home button)
        // when they retain focus after a click.
        .focusEffectDisabled()
        .toolbar {
            // Sits immediately to the right of the traffic-light buttons on
            // macOS, which is what the user wanted ("next to the window
            // closer button"). Returns to the welcome screen.
            ToolbarItem(placement: .navigation) {
                Button {
                    selectedPresetId = nil
                } label: {
                    Label("Home", systemImage: "house.fill")
                }
                .help("Return to the welcome screen")
                .spotlightAnchor(SpotlightID.homeButton)
            }
            // Stats button sits next to Home (leading edge) so it never
            // pushes content like Activate / Edit toward the right side
            // of the title bar, and it can't visually collide with the
            // window edge.
            ToolbarItem(placement: .navigation) {
                Button {
                    showingStats = true
                } label: {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .symbolRenderingMode(.hierarchical)
                }
                .help("Show statistics")
                .spotlightAnchor(SpotlightID.statsButton)
            }

            // Trailing - settings shortcut only. Active-preset chip and
            // controller status pill were removed at the user's request -
            // active state lives elsewhere (sidebar status, preset row
            // green dot) and the toolbar reads cleaner without them.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingSettingsSheet = true
                } label: {
                    Image(systemName: "gear")
                        .symbolRenderingMode(.hierarchical)
                }
                .help("Settings")
                .spotlightAnchor(SpotlightID.settingsButton)
            }
        }
        .sheet(isPresented: $showingStats) {
            StatsView()
        }
        .sheet(isPresented: $showingSettingsSheet) {
            // Re-use the existing Settings TabView in a sheet so it's
            // reachable from the toolbar in addition to the standard
            // ⌘, menu shortcut.
            SettingsView()
                .environmentObject(presetStore)
                .environmentObject(controllerService)
                .frame(minWidth: 620, minHeight: 480)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingSettingsSheet = false }
                    }
                }
        }
        .sheet(isPresented: $showingTouchpadCalibrationFromMenu) {
            TouchpadCalibrationView()
        }
        .sheet(isPresented: $showingMotionCalibrationFromMenu) {
            MotionCalibrationView()
                .environmentObject(controllerService)
        }
        .alert(
            "Calibration recommended",
            isPresented: Binding(
                get: { pendingActivation != nil },
                set: { newValue in
                    if newValue == false { pendingActivation = nil }
                }
            ),
            presenting: pendingActivation
        ) { pending in
            // Always offer to activate anyway as a way out.
            if pending.reqs.needsMotion {
                Button("Calibrate Motion…") {
                    let toResume = pending.preset
                    pendingActivation = nil
                    showingMotionCalibrationFromMenu = true
                    // Note: we don't auto-resume activation after the user
                    // closes the calibration sheet - they probably want to
                    // check the result first. They can re-activate when
                    // they're ready.
                    _ = toResume
                }
            }
            if pending.reqs.needsTouchpad {
                Button("Calibrate Touchpad…") {
                    pendingActivation = nil
                    showingTouchpadCalibrationFromMenu = true
                }
            }
            Button("Activate Anyway") {
                let toStart = pending.preset
                pendingActivation = nil
                startEngine(with: toStart)
            }
            Button("Cancel", role: .cancel) {
                pendingActivation = nil
            }
        } message: { pending in
            if pending.reqs.needsMotion && pending.reqs.needsTouchpad {
                Text("This preset uses both motion and touchpad inputs. Calibrate them first so the cursor and aim feel right on your controller - JoystickConfig doesn't yet know your controller's resting drift or your touchpad's usable bounds.")
            } else if pending.reqs.needsMotion {
                Text("This preset binds gyroscope or accelerometer inputs and the connected motion-capable controller hasn't been calibrated yet. Calibrating sets the resting zero so a still controller doesn't move the cursor.")
            } else if pending.reqs.needsTouchpad {
                Text("This preset binds touchpad inputs and your touchpad bounds haven't been calibrated yet. Calibrating helps swipes feel uniform across the surface.")
            }
        }
        .confirmationDialog(
            "Delete preset?",
            isPresented: Binding(
                get: { presetPendingDelete != nil },
                set: { if !$0 { presetPendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: presetPendingDelete
        ) { preset in
            Button("Delete \"\(preset.name)\"", role: .destructive) {
                performPendingDelete()
            }
            Button("Cancel", role: .cancel) {
                presetPendingDelete = nil
            }
        } message: { preset in
            Text("\"\(preset.name)\" will be moved to the Trash at the bottom of the sidebar. Restore it from there any time.")
        }
        .modifier(TutorialPlumbing(
            state: tutorialState,
            anchors: $tutorialAnchors,
            onTutorialEnded: handleTutorialEnded
        ))
        .onReceive(NotificationCenter.default.publisher(for: .joystickConfigShowStats)) { _ in
            showingStats = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .joystickConfigToggleActivePreset)) { _ in
            // Toggle the sidebar-selected preset, if any.
            if let pid = selectedPresetId,
               let preset = presetStore.presets.first(where: { $0.id == pid }) {
                togglePreset(preset)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .joystickConfigOpenTouchpadCalibration)) { _ in
            showingTouchpadCalibrationFromMenu = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .joystickConfigOpenMotionCalibration)) { _ in
            showingMotionCalibrationFromMenu = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .joystickConfigStartTutorial)) { _ in
            startTutorial()
        }
        .onChange(of: editingPreset?.id) { _, newID in
            // Pause outputs (but keep the engine polling) so an active
            // preset's bindings don't fling the cursor / fire keystrokes /
            // send MIDI while the user is configuring or calibrating. The
            // engine keeps reading inputs so the green row highlight on each
            // binding still lights up when the user presses the controller.
            if newID != nil {
                engineWasRunningBeforeEdit = mappingEngine.isRunning
                mappingEngine.outputsPaused = true
            } else {
                mappingEngine.outputsPaused = false
            }
        }
        .sheet(item: $editingPreset, onDismiss: {
            // If the user cancelled a newly created preset, delete it
            if let newId = newlyCreatedPresetId {
                presetStore.deletePreset(presetStore.presets.first(where: { $0.id == newId })!)
                if selectedPresetId == newId { selectedPresetId = nil }
                newlyCreatedPresetId = nil
            }
            // Resume outputs when the editor closes.
            mappingEngine.outputsPaused = false
            engineWasRunningBeforeEdit = false
            // Clear any pending jump so re-opening the editor doesn't reuse
            // a stale target.
            pendingEditorJump = nil
        }) { preset in
            PresetEditorView(preset: preset,
                             enginePausedNotice: engineWasRunningBeforeEdit,
                             pendingJump: pendingEditorJump) { updated in
                newlyCreatedPresetId = nil // Saved successfully, don't delete
                presetStore.savePreset(updated)
                editingPreset = nil
            }
            .environmentObject(controllerService)
            .environmentObject(mappingEngine)
            .frame(minWidth: 1050, idealWidth: 1300, minHeight: 700, idealHeight: 800)
        }
        .onAppear {
            presetStore.reseedExamplePresets()
        }
        .sheet(item: $presentedDemoKind) { kind in
            FeatureDemoView(kind: kind) { presetName in
                // Jump-to-preset: select it, then ask the sidebar to
                // scroll into view + briefly flash green so the user
                // sees where it landed.
                if let preset = presetStore.presets.first(where: { $0.name == presetName }) {
                    selectedPresetId = preset.id
                    flashingPresetID = preset.id
                    NotificationCenter.default.post(
                        name: .joystickConfigScrollToPreset,
                        object: preset.id)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        if flashingPresetID == preset.id {
                            flashingPresetID = nil
                        }
                    }
                }
            }
        }
    }

    // MARK: - Sidebar

    @State private var creatingGroupForPreset: Preset?
    @State private var newGroupName: String = ""
    @State private var renamingGroup: PresetGroup?
    @State private var renameGroupName: String = ""
    /// The most recently created group ID. Drives a brief green-flash
    /// animation in the sidebar so the user's eye lands on the new entry.
    @State private var flashingGroupID: UUID?

    private var sidebarView: some View {
        VStack(spacing: 0) {
            controllerStatusBar

            ScrollViewReader { proxy in
            List(selection: $selectedPresetId) {
                // Render each user-defined group as a collapsible section.
                // .onMove makes the group order drag-rearrangeable; the
                // green-flash animation is driven by `flashingGroupID`.
                ForEach(presetStore.groups) { group in
                    groupSection(group)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(group.id == flashingGroupID
                                      ? Color.green.opacity(0.35)
                                      : Color.clear)
                                .animation(.easeOut(duration: 0.9),
                                           value: flashingGroupID)
                        )
                }
                .onMove { source, destination in
                    withAnimation(.spring(response: 0.35)) {
                        presetStore.moveGroups(fromOffsets: source, toOffset: destination)
                    }
                }

                // Default "Ungrouped" section if there are any ungrouped presets.
                let ungrouped = presetStore.presets(in: nil)
                if !ungrouped.isEmpty {
                    Section {
                        ForEach(ungrouped) { preset in
                            presetRow(for: preset)
                        }
                    } header: {
                        Text(presetStore.groups.isEmpty ? "Presets" : "Ungrouped")
                            .font(.caption)
                    }
                }

                // Trash - shown only when there's something in it. Each
                // entry has Restore + Permanently Delete actions. No TTL -
                // entries persist on disk until the user acts on them.
                if !presetStore.recentlyDeleted.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $showingTrashDisclosure) {
                            ForEach(presetStore.recentlyDeleted) { entry in
                                trashRow(entry: entry)
                            }
                            Button {
                                presetStore.emptyTrash()
                            } label: {
                                Label("Empty Trash", systemImage: "trash.slash")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .padding(.top, 4)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "trash")
                                    .foregroundStyle(.orange)
                                Text("Trash (\(presetStore.recentlyDeleted.count))")
                                    .font(.caption.weight(.semibold))
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .onReceive(NotificationCenter.default.publisher(for: .joystickConfigScrollToPreset)) { note in
                guard let id = note.object as? UUID else { return }
                withAnimation(.easeOut(duration: 0.35)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            } // ScrollViewReader

            bottomToolbar
        }
        .navigationTitle("Presets")
        .frame(minWidth: 280)
        .spotlightAnchor(SpotlightID.sidebar)
        .sheet(item: $creatingGroupForPreset) { preset in
            newGroupSheet(for: preset)
        }
        .sheet(item: $renamingGroup) { group in
            renameGroupSheet(for: group)
        }
    }

    @ViewBuilder
    private func groupSection(_ group: PresetGroup) -> some View {
        let presetsInGroup = presetStore.presets(in: group.id)
        DisclosureGroup(isExpanded: groupExpandedBinding(for: group)) {
            ForEach(presetsInGroup) { preset in
                presetRow(for: preset)
            }
            if presetsInGroup.isEmpty {
                Text("Drop a preset here to add it.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(group.name)
                    .font(.caption.weight(.semibold))
                Spacer()
            }
            .contextMenu {
                Button("Rename Group...") {
                    renameGroupName = group.name
                    renamingGroup = group
                }
                Button("Delete Group", role: .destructive) {
                    presetStore.deleteGroup(group.id)
                }
            }
        }
        // Allow dropping presets onto this group header to add them.
        .dropDestination(for: String.self) { items, _ in
            for item in items {
                if let uuid = UUID(uuidString: item) {
                    presetStore.setPresetGroup(uuid, groupID: group.id)
                }
            }
            return true
        }
    }

    /// Sidebar row for one deleted preset. Restore moves it back to the
    /// presets directory; the trash icon permanently nukes the entry.
    @ViewBuilder
    private func trashRow(entry: PresetStore.DeletedPreset) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.fill")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.preset.name)
                    .font(.caption)
                    .lineLimit(1)
                Text(trashDateString(entry.deletedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            Button {
                _ = presetStore.restoreDeleted(entry)
                selectedPresetId = entry.preset.id
            } label: {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            .buttonStyle(.plain)
            .help("Restore preset")
            Button {
                presetStore.permanentlyDelete(entry)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Permanently delete")
        }
        .padding(.vertical, 2)
    }

    private func trashDateString(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Deleted " + formatter.localizedString(for: date, relativeTo: Date())
    }

    @ViewBuilder
    private func presetRow(for preset: Preset) -> some View {
        PresetRowView(
            preset: preset,
            onActivate: { togglePreset(preset) },
            onEdit: { editingPreset = preset },
            onDuplicate: { _ = presetStore.duplicatePreset(preset) },
            onExport: { exportPreset(preset) },
            onShowInFinder: { showPresetInFinder(preset) },
            onShare: { sharePreset(preset) },
            onImport: { showingImportSheet = true },
            onDelete: { confirmDelete(preset) },
            onConvert: { source, dest in
                _ = presetStore.convertPreset(preset, from: source, to: dest)
            }
        )
        .tag(preset.id)
        .id(preset.id) // For ScrollViewReader.scrollTo
        .listRowBackground(
            // Brief flash when the user jumps here from a feature demo.
            RoundedRectangle(cornerRadius: 6)
                .fill(flashingPresetID == preset.id
                      ? Color.green.opacity(0.35)
                      : Color.clear)
                .animation(.easeOut(duration: 0.9), value: flashingPresetID)
        )
        .draggable(preset.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            // Drop one preset onto another → create new group with both
            for item in items {
                if let uuid = UUID(uuidString: item), uuid != preset.id {
                    creatingGroupForPreset = preset
                    newGroupName = "New Group"
                    // Stash the dragged preset id by piggybacking on the
                    // existing creatingGroupForPreset state - we'll use both
                    // ids when the sheet's Create button is tapped.
                    pendingGroupPresetIDs = [preset.id, uuid]
                }
            }
            return true
        }
        .contextMenu {
            Menu("Move to Group") {
                ForEach(presetStore.groups) { group in
                    Button(group.name) {
                        presetStore.setPresetGroup(preset.id, groupID: group.id)
                    }
                }
                if !presetStore.groups.isEmpty {
                    Divider()
                }
                Button("New Group...") {
                    creatingGroupForPreset = preset
                    newGroupName = "New Group"
                    pendingGroupPresetIDs = [preset.id]
                }
                if preset.groupID != nil {
                    Divider()
                    Button("Remove from Group") {
                        presetStore.setPresetGroup(preset.id, groupID: nil)
                    }
                }
            }
        }
    }

    @State private var pendingGroupPresetIDs: [UUID] = []

    @ViewBuilder
    private func newGroupSheet(for preset: Preset) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Group")
                .font(.headline)
            Text("Create a group to organize related presets together in the sidebar.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Group name", text: $newGroupName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") {
                    creatingGroupForPreset = nil
                    pendingGroupPresetIDs = []
                }
                .keyboardShortcut(.cancelAction)
                Button("Create") {
                    let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let resolved = name.isEmpty ? "New Group" : name
                    let newID = presetStore.createGroup(named: resolved,
                                                        includingPresets: pendingGroupPresetIDs)
                    creatingGroupForPreset = nil
                    pendingGroupPresetIDs = []
                    // Brief green flash on the new group in the sidebar.
                    flashingGroupID = newID
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) {
                        if flashingGroupID == newID { flashingGroupID = nil }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    @ViewBuilder
    private func renameGroupSheet(for group: PresetGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Group")
                .font(.headline)
            TextField("Group name", text: $renameGroupName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") {
                    renamingGroup = nil
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let name = renameGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty {
                        presetStore.renameGroup(group.id, to: name)
                    }
                    renamingGroup = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func groupExpandedBinding(for group: PresetGroup) -> SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { group.isExpanded },
            set: { _ in presetStore.toggleGroupExpanded(group.id) }
        )
    }

    private static let controllerColors: [Color] = [.green, .purple, .red, .orange, .cyan, .pink, .yellow, .mint]

    /// An 8BitDo controller is considered to be in the wrong mode if HID
    /// detection sees it but the GameController framework does not have a
    /// corresponding entry (or has fewer entries than the HID detector).
    private var eightBitDoModeWarning: EightBitDoDevice? {
        let hidDevices = eightBitDoDetector.detectedDevices
        guard !hidDevices.isEmpty else { return nil }
        // If at least one detected 8BitDo device is in a non-supported mode,
        // surface it. Apple mode controllers are also picked up by GCController,
        // so we only warn for the others.
        return hidDevices.first { !$0.mode.supportedByMacOS }
    }

    private var controllerStatusBar: some View {
        VStack(spacing: 0) {
            if let warning = eightBitDoModeWarning {
                eightBitDoWarningBanner(warning)
            }

            if controllerService.connectedControllers.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "gamecontroller")
                        .foregroundStyle(.secondary)
                    Text("No controllers connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            } else {
                ForEach(Array(controllerService.connectedControllers.enumerated()), id: \.offset) { index, controller in
                    ControllerChipView(
                        controller: controller,
                        index: index,
                        color: Self.controllerColors[index % Self.controllerColors.count],
                        info: controllerService.controllerDetails[index],
                        onSetLight: { r, g, b in
                            controllerService.stopRGBCycle(at: index)
                            controllerService.setControllerLight(at: index, red: r, green: g, blue: b)
                        },
                        onSetBrightness: { brightness in
                            controllerService.setControllerBrightness(at: index, brightness: brightness)
                        },
                        onToggleRGB: {
                            controllerService.toggleRGBCycle(at: index)
                        },
                        isRGBActive: controllerService.rgbCycleActive[index] == true,
                        onRefresh: {
                            controllerService.refreshControllers()
                        }
                    )
                }
            }

            if mappingEngine.isRunning {
                HStack(spacing: 6) {
                    Spacer()
                    Menu {
                        Button("Deactivate") {
                            if let active = presetStore.presets.first(where: { $0.isActive }) {
                                togglePreset(active)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                            Text("Active")
                                .font(.caption2)
                                .foregroundStyle(Color.green)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.1))
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
        }
        .background(.bar)
    }

    @ViewBuilder
    private func eightBitDoWarningBanner(_ device: EightBitDoDevice) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text("8BitDo controller detected in \(device.mode.rawValue) mode")
                    .font(.caption)
                    .foregroundStyle(.primary)
                Text("Switch to Apple mode (A on the back of the controller) for full Mac support.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Help") {
                HelpGuideWindowController.shared.show()
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.08))
    }

    private var bottomToolbar: some View {
        HStack(spacing: 10) {
            Menu {
                Button("New Preset") {
                    let preset = presetStore.createPreset()
                    selectedPresetId = preset.id
                    newlyCreatedPresetId = preset.id
                    editingPreset = preset
                }
                Button("New Group...") {
                    pendingGroupPresetIDs = []
                    newGroupName = "New Group"
                    // Use a dummy preset to drive the sheet item binding.
                    creatingGroupForPreset = presetStore.presets.first ?? Preset()
                }
            } label: {
                Image(systemName: "plus")
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)

            Spacer()

            Button {
                HelpGuideWindowController.shared.show()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 11))
                    Text("Help")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Link(destination: URL(string: "https://github.com/ryleighnewman/JoystickConfig")!) {
                Text("GitHub")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .underline(color: .secondary.opacity(0.5))
            }

            Button {
                TipJarWindowController.shared.show()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "heart")
                        .font(.system(size: 11))
                    Text("Support")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                showingImportSheet = true
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .fileImporter(
            isPresented: $showingImportSheet,
            allowedContentTypes: [.json, .plainText],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                for url in urls {
                    _ = presetStore.importLegacyPreset(from: url)
                }
            }
        }
    }

    // MARK: - Detail View

    @ViewBuilder
    private var detailView: some View {
        VStack(spacing: 0) {
            if let presetId = selectedPresetId,
               let preset = presetStore.presets.first(where: { $0.id == presetId }) {
                PresetDetailView(
                    preset: presetBinding(for: preset),
                    onEdit: { editingPreset = preset },
                    onToggle: { togglePreset(preset) },
                    onJumpToBinding: { target in
                        pendingEditorJump = target
                        editingPreset = preset
                    }
                )
                .environmentObject(mappingEngine)
                .environmentObject(controllerService)
                .environmentObject(presetStore)
            } else {
                welcomeView
            }

            // Log always visible at bottom
            Divider()
                .padding(.horizontal)
            DebugLogView()
                .environmentObject(mappingEngine)
                .padding(.vertical, 8)
        }
    }

    // MARK: - Welcome

    /// Shown in the detail area when no preset is selected. Acts as both a
    /// landing page and a feature index. Designed to be skim-able: an icon,
    /// a headline, a one-line subtitle, a feature grid, and a single call
    /// to action. Not a modal or popup - replaces the "Select a preset"
    /// placeholder when the user hasn't picked one yet.
    private var welcomeView: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Headline
                VStack(spacing: 10) {
                    Image(systemName: "gamecontroller")
                        .font(.system(size: 56))
                        .foregroundStyle(.tertiary)
                    Text("Welcome to JoystickConfig")
                        .font(.title2.weight(.semibold))
                    Text("Map any game controller to keyboard, mouse, and MIDI on macOS.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 24)

                // Quick actions
                HStack(spacing: 10) {
                    Button {
                        startTutorial()
                    } label: {
                        Label("Start Quick Tour", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.teal)
                    .help("Guided ~1 minute walkthrough of the major features")

                    Button {
                        let preset = presetStore.createPreset()
                        selectedPresetId = preset.id
                        editingPreset = preset
                    } label: {
                        Label("Create New Preset", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .spotlightAnchor(SpotlightID.createNew)

                    Button {
                        HelpGuideWindowController.shared.show()
                    } label: {
                        Label("Open Help Guide", systemImage: "questionmark.circle")
                    }
                    .buttonStyle(.bordered)
                }

                // Feature grid - each card opens an animated demo sheet
                // explaining the feature, with a button to jump to a matching
                // example preset.
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 220), spacing: 12)],
                    spacing: 12
                ) {
                    demoCard(kind: .keyboardMouse,
                             icon: "keyboard",
                             detail: "Map any button, trigger, or stick to keyboard keys, mouse buttons, mouse motion, or scroll wheel.",
                             tint: .orange)
                    demoCard(kind: .midi,
                             icon: "music.note.list",
                             detail: "Send Note, CC, and Pitch Bend through a virtual MIDI port to GarageBand, Logic, Ableton, and more.",
                             tint: .pink)
                    demoCard(kind: .variableSensitivity,
                             icon: "slider.horizontal.below.rectangle",
                             detail: "Joystick depth scales output speed. Pick linear, smooth, or aggressive curves per binding.",
                             tint: .blue)
                    demoCard(kind: .deadzone,
                             icon: "scope",
                             detail: "Live joystick visualizer with a draggable trail and slider to find the perfect deadzone.",
                             tint: .green)
                    demoCard(kind: .macros,
                             icon: "bolt.fill",
                             detail: "Chain keystrokes with custom timing, or rapid-fire any button at a configurable rate.",
                             tint: .yellow)
                    demoCard(kind: .haptic,
                             icon: "waveform",
                             detail: "Vibrate the controller when a binding fires. Works with DualSense, DualSense Edge, and similar.",
                             tint: .purple)
                    demoCard(kind: .speech,
                             icon: "speaker.wave.2.fill",
                             detail: "Speak a custom phrase on press through Mac speakers or the controller speaker.",
                             tint: .indigo)
                    demoCard(kind: .lightBar,
                             icon: "light.beacon.max.fill",
                             detail: "Pick a color with the picker, set brightness, or run an RGB cycle on DualSense controllers.",
                             tint: .red)
                    demoCard(kind: .controllers,
                             icon: "gamecontroller.fill",
                             detail: "DualSense, DualShock 4, Xbox, Switch Pro, Joy-Cons, Stadia, 8BitDo, and any MFi gamepad.",
                             tint: .cyan)
                    demoCard(kind: .touchpad,
                             icon: "rectangle.and.hand.point.up.left.fill",
                             detail: "DualSense and DualShock 4 touchpad surfaces can drive the mouse cursor.",
                             tint: .mint)
                    demoCard(kind: .gyro,
                             icon: "gyroscope",
                             detail: "Tilt-to-aim with the controller's gyroscope. Works on DualSense, DualSense Edge, DualShock 4, Switch Pro, and Joy-Con.",
                             tint: .teal)
                }
                .padding(.horizontal, 28)

                Text("Plug in a controller to get started. Open the Help menu for setup guides for every supported device.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 30)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Clickable feature card that opens the matching animated demo sheet.
    @ViewBuilder
    private func demoCard(kind: FeatureDemoKind, icon: String, detail: String, tint: Color) -> some View {
        let isHighlighted = tutorialFeatureSpotlight == kind
        return Button {
            presentedDemoKind = kind
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(kind.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Image(systemName: "play.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(tint.opacity(0.7))
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isHighlighted
                          ? tint.opacity(0.22)
                          : Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isHighlighted ? tint : Color.clear, lineWidth: 2)
            )
            .shadow(color: isHighlighted ? tint.opacity(0.5) : .clear,
                    radius: isHighlighted ? 12 : 0)
            .scaleEffect(isHighlighted ? 1.04 : 1.0)
            .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true),
                       value: isHighlighted)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        // Only the spotlighted card claims the anchor so the tutorial
        // spotlight ring lands on the right card.
        .modifier(ConditionalSpotlightAnchor(active: isHighlighted, id: SpotlightID.welcomeCard))
    }

    /// Helper because `.spotlightAnchor(...)` can't be conditionally
    /// applied directly inside a ViewBuilder; use a ViewModifier.
    private struct ConditionalSpotlightAnchor: ViewModifier {
        let active: Bool
        let id: String
        func body(content: Content) -> some View {
            if active {
                content.spotlightAnchor(id)
            } else {
                content
            }
        }
    }

    // MARK: - Helpers

    private func presetBinding(for preset: Preset) -> SwiftUI.Binding<Preset> {
        SwiftUI.Binding(
            get: { presetStore.presets.first(where: { $0.id == preset.id }) ?? preset },
            set: { newValue in
                presetStore.savePreset(newValue)
            }
        )
    }

    // MARK: - Actions

    /// Queue the preset for delete confirmation. The dialog is wired up via
    /// the main body's `.confirmationDialog(presenting:)`.
    private func confirmDelete(_ preset: Preset) {
        presetPendingDelete = preset
    }

    // MARK: - Quick Start tutorial

    /// Close any sheets opened by tutorial steps when the tour ends.
    /// Wired up through TutorialPlumbing so the heavy body chain doesn't
    /// hold yet another onChange.
    private func handleTutorialEnded() {
        tutorialFeatureSpotlight = nil
        editingPreset = nil
        showingMotionCalibrationFromMenu = false
        showingTouchpadCalibrationFromMenu = false
    }

    /// Kick off the guided tour. The first step's action fires immediately
    /// so the app responds the moment the user clicks "Start Tutorial".
    private func startTutorial() {
        // Make sure the welcome page is showing so the demo cards are
        // visible to spotlight.
        selectedPresetId = nil
        showingStats = false
        editingPreset = nil
        showingMotionCalibrationFromMenu = false
        showingTouchpadCalibrationFromMenu = false
        tutorialState.start(steps: tutorialSteps)
    }

    /// Pick the first non-empty preset we can find. Used by the tutorial
    /// to land the user on something meaningful even if their first
    /// preset is empty.
    private func tutorialDemoPreset() -> Preset? {
        return presetStore.presets.first(where: { !$0.joysticks.isEmpty })
            ?? presetStore.presets.first
    }

    /// Sequence of guided steps. Each action mutates ContentView state so
    /// the user sees the live app respond as the tour progresses; the
    /// spotlight references named anchors that ContentView attaches to
    /// the matching UI elements.
    private var tutorialSteps: [TutorialStep] {
        [
            TutorialStep(
                icon: "sparkles",
                tint: .teal,
                title: "Welcome to JoystickConfig",
                body: "This guided tour takes about a minute and walks through every major feature. We'll light up parts of the app as we go and show short animated examples. Hit Next to begin.",
                action: {
                    selectedPresetId = nil
                    showingStats = false
                }
            ),
            TutorialStep(
                icon: "house.fill",
                tint: .blue,
                title: "Home, Stats, and Settings",
                body: "The toolbar (top of the window) has three buttons: Home returns to this welcome page, the chart icon opens detailed Statistics, and the gear opens Settings.",
                spotlight: SpotlightID.homeButton,
                spotlightShape: .circle,
                tip: "Quick keyboard shortcuts: \u{2318}0 for Stats, \u{2318}, for Settings.",
                action: { selectedPresetId = nil }
            ),
            TutorialStep(
                icon: "list.bullet.rectangle",
                tint: .indigo,
                title: "Your preset library",
                body: "The sidebar lists every preset you've created, organized into groups. Each preset is one mapping configuration. Click the ellipsis icon next to a truncated description to read its full text.",
                spotlight: SpotlightID.sidebar,
                tip: "Drag a preset onto another to create a new group. Right-click for Activate / Edit / Duplicate / Delete.",
                action: { selectedPresetId = nil }
            ),
            TutorialStep(
                icon: "books.vertical.fill",
                tint: .orange,
                title: "Example presets to learn from",
                body: "The welcome page has a grid of feature-demo cards (Keyboard + Mouse, MIDI, Gyro Aim, Macros, and more). The pulsing card below is a live animated demo - clicking any card opens a full animation; the linked preset gives you a working setup to copy.",
                spotlight: SpotlightID.welcomeCard,
                tip: "Click the highlighted card to open its full animated demo + jump to the matching example preset.",
                action: {
                    selectedPresetId = nil
                    tutorialFeatureSpotlight = .gyro
                }
            ),
            TutorialStep(
                icon: "plus.rectangle.on.rectangle",
                tint: .green,
                title: "Create a preset",
                body: "Use the + button at the bottom of the sidebar to create a fresh preset, or the Create New Preset button on this welcome page. Each new preset starts with one empty joystick mapping you can add bindings to.",
                spotlight: SpotlightID.createNew,
                action: { selectedPresetId = nil }
            ),
            TutorialStep(
                icon: "rectangle.fill.on.rectangle.fill",
                tint: .teal,
                title: "Preset detail view",
                body: "Selecting a preset opens its detail page with usage stats, controller capabilities, storage location, version history, and a Live Visualizer.",
                spotlight: SpotlightID.detailHeader,
                action: {
                    if let p = tutorialDemoPreset() {
                        selectedPresetId = p.id
                    }
                }
            ),
            TutorialStep(
                icon: "play.fill",
                tint: .green,
                title: "Activate and Edit",
                body: "The green Activate button starts the mapping engine using this preset. Edit Bindings & Mappings opens the full editor where you wire inputs to outputs.",
                spotlight: SpotlightID.activateButton,
                tip: "Click the green dot in the sidebar next to a preset to toggle it without opening the detail page."
            ),
            TutorialStep(
                icon: "gamecontroller.fill",
                tint: .teal,
                title: "Live Visualizer",
                body: "The Live Visualizer mirrors your physical controller in real time. Press a button, move a stick, tilt the gyro - everything shows up here. Click any widget to inspect what it's bound to.",
                spotlight: SpotlightID.visualizer,
                demo: .buttonMapping,
                tip: "Use the +/- zoom slider in the visualizer header to resize the panel."
            ),
            TutorialStep(
                icon: "dot.circle.and.hand.point.up.left.fill",
                tint: .blue,
                title: "Analog sticks - smooth values",
                body: "Sticks aren't binary. Bindings to a stick axis read continuous values from -1 to +1, perfect for cursor speed, scroll speed, or any output that benefits from being proportional to how far you push.",
                demo: .analogStick,
                tip: "Pick from Linear, Smooth, or Aggressive curves in the editor's Advanced section."
            ),
            TutorialStep(
                icon: "arrow.up.and.down.text.horizontal",
                tint: .orange,
                title: "Pressure-sensitive triggers",
                body: "Triggers report analog magnitude too. Use Variable Sensitivity to scale output speed by how hard you press, or set custom deadzones so light touches don't register.",
                demo: .pressureTrigger,
                tip: "The orange tick on every trigger widget marks its current deadzone threshold."
            ),
            TutorialStep(
                icon: "gyroscope",
                tint: .purple,
                title: "Gyroscope motion",
                body: "Controllers with motion sensors (DualSense, DualShock 4, Switch Pro, Joy-Con) expose gyro and accelerometer data. Bind any motion channel to mouse motion for true 'gyro aim' across every app.",
                demo: .gyro,
                tip: "Run Controller \u{2192} Calibrate Motion once per controller so drift is corrected."
            ),
            TutorialStep(
                icon: "pencil.and.outline",
                tint: .blue,
                title: "Customize Layout",
                body: "In the visualizer's header, Customize Layout flips the panel into 'blueprint mode' with a faint grid. Drag any widget to rearrange it. The layout saves per controller model.",
                spotlight: SpotlightID.customizeButton,
                tip: "Click Reset (in edit mode) to put every widget back where it started."
            ),
            TutorialStep(
                icon: "light.beacon.max.fill",
                tint: .pink,
                title: "Per-preset light bar",
                body: "DualSense and DualShock 4 controllers have a built-in light bar. The strip on top of the visualizer lets you pick a color that's applied automatically whenever this preset activates.",
                spotlight: SpotlightID.lightBarStrip,
                demo: .lightBar,
                tip: "Deactivating the preset reverts the light to its general color."
            ),
            TutorialStep(
                icon: "note.text",
                tint: .yellow,
                title: "Per-preset notes",
                body: "Below the visualizer you'll find a free-form notes field. Use it to remember which game this preset is for, gotchas, control schemes, or anything else.",
                spotlight: SpotlightID.notesSection
            ),
            TutorialStep(
                icon: "slider.horizontal.3",
                tint: .indigo,
                title: "Edit Bindings & Mappings",
                body: "We just opened the editor for you. The card now floats above it. Each row is one binding - Scan to record an input, then pick what it should output: key, mouse, MIDI, macro chain, spoken text, and more. Look around, then click Next.",
                tip: "Numbered rows match the numbers in Live Visualizer popups.",
                action: {
                    tutorialFeatureSpotlight = nil
                    if let p = tutorialDemoPreset() {
                        selectedPresetId = p.id
                        editingPreset = p
                    }
                }
            ),
            TutorialStep(
                icon: "bolt.fill",
                tint: .yellow,
                title: "Macros and turbo",
                body: "Any binding can fire a macro: a sequence of keystrokes, mouse events, or MIDI notes with custom delays. Inside a row in the editor, expand Advanced and toggle Macro to chain steps together.",
                demo: .macroChain,
                tip: "Hold the button to repeat the macro - turbo at any frequency."
            ),
            TutorialStep(
                icon: "gyroscope",
                tint: .purple,
                title: "Calibrate Motion / Gyro",
                body: "We just opened motion calibration for you. Place the controller flat, then click Start Calibration. The how-to scrolls into view; click the green Start button to confirm and capture for 2 seconds.",
                tip: "Run once per controller. The recorded zero is per-device-identity.",
                action: {
                    editingPreset = nil
                    showingTouchpadCalibrationFromMenu = false
                    showingMotionCalibrationFromMenu = true
                }
            ),
            TutorialStep(
                icon: "rectangle.and.hand.point.up.left.fill",
                tint: .mint,
                title: "Calibrate Touchpad",
                body: "Touchpad calibration is next. Drag your finger across the entire surface so we learn the bounds, then save. You can also define named tap-zones for region-based bindings.",
                tip: "Calibrate motion AND touchpad once when you first plug in a new DualSense.",
                action: {
                    showingMotionCalibrationFromMenu = false
                    showingTouchpadCalibrationFromMenu = true
                }
            ),
            TutorialStep(
                icon: "chart.line.uptrend.xyaxis",
                tint: .purple,
                title: "Lifetime statistics",
                body: "The Statistics dashboard tracks lifetime usage - time connected, button presses, mouse pixels, top presets, and more. Click any tile to drill into a detailed breakdown with charts.",
                spotlight: SpotlightID.statsButton,
                spotlightShape: .circle,
                tip: "All stats are stored locally. Nothing leaves your Mac.",
                action: {
                    // Make sure prior sheets are closed before the next step
                    // highlights toolbar buttons.
                    showingMotionCalibrationFromMenu = false
                    showingTouchpadCalibrationFromMenu = false
                    editingPreset = nil
                }
            ),
            TutorialStep(
                icon: "gear",
                tint: .gray,
                title: "Settings & backup",
                body: "The gear icon opens Settings with Launch-at-Login, controller diagnostics, About, and a full Export Backup / Restore from Backup pair so you can move your config between Macs.",
                spotlight: SpotlightID.settingsButton,
                spotlightShape: .circle,
                action: {
                    showingMotionCalibrationFromMenu = false
                    showingTouchpadCalibrationFromMenu = false
                    editingPreset = nil
                }
            ),
            TutorialStep(
                icon: "questionmark.circle.fill",
                tint: .cyan,
                title: "Help guides",
                body: "The Help menu (\u{2318}?) opens an in-app guide with deeper docs on every feature, plus a separate Test Bench for diagnosing weird input behavior. The Quick Start Tour - this thing - is in there too if you ever want to repeat it."
            ),
            TutorialStep(
                icon: "checkmark.circle.fill",
                tint: .green,
                title: "You're all set",
                body: "That's the full tour. Build a preset, calibrate your controller, and have fun. If anything feels confusing, the Help menu has a guide for it.",
                action: { selectedPresetId = nil }
            )
        ]
    }

    /// Actually delete the queued preset. The store moves it to the
    /// on-disk trash where the sidebar's Trash section can restore it
    /// at any time.
    private func performPendingDelete() {
        guard let preset = presetPendingDelete else { return }
        if selectedPresetId == preset.id { selectedPresetId = nil }
        presetStore.deletePreset(preset)
        presetPendingDelete = nil
    }

    private func togglePreset(_ preset: Preset) {
        if preset.isActive {
            mappingEngine.stop()
            presetStore.deactivateAll()
            return
        }
        if preset.joysticks.isEmpty { return }
        // Gate: if this preset uses motion / touchpad bindings, ensure the
        // user has run the corresponding calibration. Missing calibration
        // makes the cursor / aim feel wrong on a brand-new controller.
        let needs = calibrationRequirements(for: preset)
        if needs.needsMotion || needs.needsTouchpad {
            pendingActivation = (preset: preset, reqs: needs)
            return
        }
        startEngine(with: preset)
    }

    private func startEngine(with preset: Preset) {
        mappingEngine.stop()
        presetStore.activatePreset(preset)
        mappingEngine.start(with: preset)
    }

    private struct CalibrationRequirements {
        var needsMotion: Bool
        var needsTouchpad: Bool
        var connectedMotionControllerUncalibrated: Bool
        var touchpadUncalibrated: Bool
    }

    /// Inspect the preset's bindings + the currently connected hardware and
    /// decide what calibration prompts (if any) are needed before activation.
    private func calibrationRequirements(for preset: Preset) -> CalibrationRequirements {
        let allBindings = preset.joysticks.flatMap(\.bindings)
        let usesMotion = allBindings.contains { $0.input.type == .motion }
        let usesTouchpad = allBindings.contains {
            $0.input.type == .touchpad || $0.input.type == .touchpadRegion
        }

        // Motion: needs calibration if any motion-capable connected
        // controller hasn't been calibrated yet.
        var motionUncalibrated = false
        if usesMotion {
            for controller in controllerService.connectedControllers {
                if controller.motion != nil {
                    let key = MotionCalibrationService.identityKey(for: controller)
                    if !MotionCalibrationService.shared.isCalibrated(forKey: key) {
                        motionUncalibrated = true
                        break
                    }
                }
            }
        }

        // Touchpad: needs calibration if no saved bounds exist.
        let touchpadUncalibrated = usesTouchpad
            && !TouchpadService.shared.currentCalibration().isUserCalibrated

        return CalibrationRequirements(
            needsMotion: usesMotion && motionUncalibrated,
            needsTouchpad: touchpadUncalibrated,
            connectedMotionControllerUncalibrated: motionUncalibrated,
            touchpadUncalibrated: touchpadUncalibrated
        )
    }

    private func exportPreset(_ preset: Preset) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(preset.name).json"
        if panel.runModal() == .OK, let url = panel.url {
            presetStore.exportPresetToFile(preset, to: url)
        }
    }

    private func showPresetInFinder(_ preset: Preset) {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let presetsDir = appSupport.appendingPathComponent("JoystickConfig/presets")
        let filePath = presetsDir.appendingPathComponent(preset.filename).path
        NSWorkspace.shared.selectFile(filePath, inFileViewerRootedAtPath: "")
    }

    private func sharePreset(_ preset: Preset) {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let presetsDir = appSupport.appendingPathComponent("JoystickConfig/presets")
        let fileURL = presetsDir.appendingPathComponent(preset.filename)

        let picker = NSSharingServicePicker(items: [fileURL])
        if let window = NSApp.keyWindow, let contentView = window.contentView {
            let frame = contentView.bounds
            let rect = NSRect(x: frame.midX, y: frame.midY, width: 1, height: 1)
            picker.show(relativeTo: rect, of: contentView, preferredEdge: .minY)
        }
    }
}

// MARK: - Controller Chip View

struct ControllerChipView: View {
    let controller: GCController
    let index: Int
    let color: Color
    let info: ControllerInfo?
    let onSetLight: (Float, Float, Float) -> Void
    let onSetBrightness: (UInt8) -> Void
    let onToggleRGB: () -> Void
    let isRGBActive: Bool
    let onRefresh: () -> Void

    @State private var showPopover = false

    // Accurate light bar colors tuned to match actual DualSense LED output
    private static let lightPresets: [(name: String, r: Float, g: Float, b: Float)] = [
        ("Red",    1.0, 0.0, 0.0),
        ("Orange", 1.0, 0.35, 0.0),
        ("Yellow", 1.0, 0.7, 0.0),
        ("Green",  0.0, 1.0, 0.0),
        ("Cyan",   0.0, 1.0, 1.0),
        ("Blue",   0.0, 0.0, 1.0),
        ("Purple", 0.5, 0.0, 1.0),
        ("Pink",   1.0, 0.0, 0.6),
        ("White",  1.0, 1.0, 1.0),
        ("Off",    0.0, 0.0, 0.0),
    ]

    @State private var customColor = Color.blue
    @State private var brightness: Double = 2
    @State private var uptimeTimer: Timer?
    @State private var uptimeText: String = ""

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            // Controller icon
            Image(systemName: "gamecontroller.fill")
                .font(.caption)
                .foregroundStyle(color)

            VStack(alignment: .leading, spacing: 0) {
                Text(controller.vendorName ?? "Controller \(index)")
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let info = info {
                    Text(shortDescription(info))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Battery indicator
            if let info = info, info.hasBattery, let level = info.batteryLevel {
                batteryView(level: level, state: info.batteryState)
            }

            // Light indicator
            if info?.hasLight == true {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.yellow.opacity(0.7))
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? color.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            showPopover.toggle()
        }
        .popover(isPresented: $showPopover, arrowEdge: .trailing) {
            controllerPopover
        }
    }

    private func shortDescription(_ info: ControllerInfo) -> String {
        var parts: [String] = []
        // Prefer the detected brand name (DualSense, Switch Pro, etc.) when we
        // know it, since it is friendlier than productCategory (which is often
        // just "Extended Gamepad" or similar).
        if info.brand != .unknown && info.brand != .mfiGeneric {
            parts.append(info.brand.displayName)
        } else {
            parts.append(info.productCategory)
        }
        parts.append("\(info.buttonCount) btns")
        parts.append("\(info.axisCount) axes")
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func batteryView(level: Float, state: String?) -> some View {
        HStack(spacing: 2) {
            let pct = Int(level * 100)
            let icon: String = {
                if state == "Charging" { return "battery.100percent.bolt" }
                if pct >= 75 { return "battery.100percent" }
                if pct >= 50 { return "battery.75percent" }
                if pct >= 25 { return "battery.50percent" }
                return "battery.25percent"
            }()
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(pct <= 20 ? .red : .secondary)
            Text("\(pct)%")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Popover

    private var controllerPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "gamecontroller.fill")
                    .font(.title3)
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.vendorName ?? "Controller \(index)")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text("Slot \(index)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !uptimeText.isEmpty {
                            Text("·")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text(uptimeText)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer()
            }

            Divider()

            // Details
            if let info = info {
                detailGrid(info)
            }

            // Light color picker
            if info?.hasLight == true {
                Divider()
                lightColorSection
            }

            // Available buttons
            if let info = info, !info.physicalButtonNames.isEmpty {
                Divider()
                DisclosureGroup {
                    Text(info.physicalButtonNames.joined(separator: ", "))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("Raw Buttons (\(info.physicalButtonNames.count))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tint(.secondary)
                .focusable(false)
                .focusEffectDisabled()
            }

            Divider()

            Button {
                onRefresh()
                showPopover = false
            } label: {
                Label("Refresh Controllers", systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { startUptimeTimer() }
        .onDisappear { uptimeTimer?.invalidate(); uptimeTimer = nil }
    }

    private func startUptimeTimer() {
        updateUptime()
        uptimeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in updateUptime() }
        }
    }

    private func updateUptime() {
        guard let info = info else { uptimeText = ""; return }
        let elapsed = Int(Date().timeIntervalSince(info.connectedAt))
        let h = elapsed / 3600
        let m = (elapsed % 3600) / 60
        let s = elapsed % 60
        if h > 0 {
            uptimeText = String(format: "%d:%02d:%02d connected", h, m, s)
        } else {
            uptimeText = String(format: "%d:%02d connected", m, s)
        }
    }

    @ViewBuilder
    private func detailGrid(_ info: ControllerInfo) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            detailRow("Brand", info.brand.displayName)
            detailRow("Type", info.productCategory)
            detailRow("Gamepad", info.hasExtendedGamepad ? "Extended" : "Basic")
            detailRow("Buttons", "\(info.buttonCount)")
            detailRow("Axes", "\(info.axisCount)")
            if info.supportsMotion {
                detailRow("Motion", "Gyro + Accelerometer")
            }
            if info.hasBattery {
                let level = info.batteryLevel.map { "\(Int($0 * 100))%" } ?? "N/A"
                let state = info.batteryState ?? "Unknown"
                detailRow("Battery", "\(level) (\(state))")
            }
            detailRow("Light Bar", info.hasLight ? "Supported" : "None")
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.caption)
        }
    }

    private var lightColorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Light Bar Color")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Preset color grid
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 8) {
                ForEach(Self.lightPresets, id: \.name) { preset in
                    let swatchColor = preset.name == "Off" ? Color.gray.opacity(0.3) :
                        Color(red: Double(preset.r), green: Double(preset.g), blue: Double(preset.b))
                    LightSwatchButton(
                        name: preset.name,
                        color: swatchColor,
                        action: { onSetLight(preset.r, preset.g, preset.b) }
                    )
                }
            }

            Divider()

            // Custom color picker
            HStack(spacing: 10) {
                Text("Custom Color")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                ColorPicker("", selection: $customColor, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 28, height: 28)

                Button("Apply") {
                    let nsColor = NSColor(customColor).usingColorSpace(.sRGB) ?? NSColor(customColor)
                    let r = Float(nsColor.redComponent)
                    let g = Float(nsColor.greenComponent)
                    let b = Float(nsColor.blueComponent)
                    onSetLight(r, g, b)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Divider()

            // Brightness control
            VStack(alignment: .leading, spacing: 4) {
                Text("Brightness")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Image(systemName: "light.min")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)

                    Picker("", selection: $brightness) {
                        Text("Off").tag(0.0)
                        Text("Dim").tag(1.0)
                        Text("Bright").tag(2.0)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: brightness) { _, newValue in
                        onSetBrightness(UInt8(newValue))
                    }

                    Image(systemName: "light.max")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            Divider()

            // RGB cycle mode
            Button {
                onToggleRGB()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isRGBActive ? "stop.circle.fill" : "rainbow")
                        .foregroundStyle(isRGBActive ? .red : .secondary)
                    Text(isRGBActive ? "Stop RGB Cycle" : "RGB Cycle")
                        .font(.caption)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(isRGBActive ? .red : .accentColor)
        }
    }
}

// MARK: - Light Swatch Button

private struct LightSwatchButton: View {
    let name: String
    let color: Color
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Circle()
                    .fill(color)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.primary.opacity(isHovering ? 0.4 : 0.12), lineWidth: isHovering ? 1.5 : 0.5)
                    )
                    .frame(width: 24, height: 24)
                    .shadow(color: color.opacity(isHovering ? 0.6 : 0.3), radius: isHovering ? 4 : 2)
                    .scaleEffect(isHovering ? 1.15 : 1.0)
                    .animation(.easeOut(duration: 0.15), value: isHovering)
                Text(name)
                    .font(.system(size: 8))
                    .foregroundStyle(isHovering ? .secondary : .tertiary)
            }
        }
        .buttonStyle(.plain)
        .focusable(false)
        .focusEffectDisabled()
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - Preset Row View

struct PresetRowView: View {
    let preset: Preset
    let onActivate: () -> Void
    let onEdit: () -> Void
    let onDuplicate: () -> Void
    let onExport: () -> Void
    let onShowInFinder: () -> Void
    let onShare: () -> Void
    let onImport: () -> Void
    let onDelete: () -> Void
    let onConvert: (ControllerType, ControllerType) -> Void

    /// Toggled when the user clicks the trailing ellipsis next to a
    /// truncated description. Collapses back when toggled off, the row is
    /// deselected, or another row is selected.
    @State private var descriptionExpanded: Bool = false

    /// Whether the row should offer an expand toggle. We err on the side
    /// of showing it: any non-trivial tag (>= 16 chars, since sidebar
    /// width often clips around there) OR any notes content qualifies.
    /// 16 instead of 40 means narrow-sidebar users actually get the
    /// button when their text is in fact truncated.
    private var descriptionTruncates: Bool {
        preset.tag.count >= 16 || !preset.notes.isEmpty
    }

    var body: some View {
        // Two-tier layout: the main row stays a stable height; the
        // expanded description / notes appear in a separate block UNDER
        // the row. This way the row's name + circle + menu can never
        // drift upward when expansion happens - the new block just adds
        // height below them.
        VStack(alignment: .leading, spacing: 4) {
            mainRow
            if descriptionExpanded {
                expandedDetail
                    .padding(.leading, 34) // align with text column
                    .padding(.trailing, 8)
                    .transition(.opacity)
            }
        }
    }

    /// Top half of the row: activation circle, name, single-line
    /// description with the trailing ellipsis-toggle, then the trailing
    /// options Menu. Always the same height regardless of expansion.
    @ViewBuilder
    private var mainRow: some View {
        HStack(spacing: 10) {
            ZStack {
                if preset.isActive {
                    Circle()
                        .fill(Color.green.opacity(0.25))
                        .frame(width: 24, height: 24)
                        .blur(radius: 4)
                    Circle()
                        .fill(Color.green)
                        .frame(width: 14, height: 14)
                        .shadow(color: Color.green.opacity(0.6), radius: 6, x: 0, y: 0)
                } else {
                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1.5)
                        .frame(width: 14, height: 14)
                }
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                    .font(.body)
                    .lineLimit(1)

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(preset.tag)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if descriptionTruncates {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                descriptionExpanded.toggle()
                            }
                        } label: {
                            Image(systemName: descriptionExpanded
                                  ? "chevron.up.circle.fill"
                                  : "ellipsis.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help(descriptionExpanded
                              ? "Collapse description"
                              : "Show full description")
                    }
                }
            }

            Spacer()

            // Options menu
            Menu {
                Button(preset.isActive ? "Deactivate" : "Activate") {
                    onActivate()
                }

                Button("Edit") {
                    onEdit()
                }

                Button("Duplicate") {
                    onDuplicate()
                }

                Divider()

                Menu("Convert To...") {
                    ForEach(ControllerType.allCases) { sourceType in
                        Menu("From \(sourceType.rawValue)") {
                            ForEach(ControllerType.allCases.filter { $0 != sourceType }) { destType in
                                Button("To \(destType.rawValue)") {
                                    onConvert(sourceType, destType)
                                }
                            }
                        }
                    }
                }

                Button("Export...") {
                    onExport()
                }

                Button("Import Preset File...") {
                    onImport()
                }

                Divider()

                Button("Show in Finder") {
                    onShowInFinder()
                }

                Button("Share...") {
                    onShare()
                }

                Divider()

                Button("Delete", role: .destructive) {
                    onDelete()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11))
                    .foregroundColor(Color.gray.opacity(0.5))
                    .frame(width: 22, height: 22)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .frame(width: 22)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button(preset.isActive ? "Deactivate" : "Activate") {
                onActivate()
            }

            Button("Edit") {
                onEdit()
            }

            Button("Duplicate") {
                onDuplicate()
            }

            Divider()

            Menu("Convert To...") {
                ForEach(ControllerType.allCases) { sourceType in
                    Menu("From \(sourceType.rawValue)") {
                        ForEach(ControllerType.allCases.filter { $0 != sourceType }) { destType in
                            Button("To \(destType.rawValue)") {
                                onConvert(sourceType, destType)
                            }
                        }
                    }
                }
            }

            Button("Export...") { onExport() }
            Button("Import Preset File...") { onImport() }

            Divider()

            Button("Show in Finder") { onShowInFinder() }
            Button("Share...") { onShare() }

            Divider()

            Button("Delete", role: .destructive) { onDelete() }
        }
    }

    /// Bottom block shown when descriptionExpanded is true: the full
    /// tag (multi-line) plus the preset's notes (if any). Indented to
    /// align with the description column in the main row.
    @ViewBuilder
    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 4) {
            if preset.tag.count >= 16 {
                Text(preset.tag)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !preset.notes.isEmpty {
                Text(preset.notes)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Preset Detail View

struct PresetDetailView: View {
    @SwiftUI.Binding var preset: Preset
    let onEdit: () -> Void
    let onToggle: () -> Void
    /// Asks ContentView to open the editor scrolled to a specific binding
    /// row. Forwarded down to VirtualControllerView, which fires this when
    /// the user taps a row inside any widget popover.
    var onJumpToBinding: (EditorJumpTarget) -> Void = { _ in }

    @EnvironmentObject var mappingEngine: MappingEngine
    @EnvironmentObject var controllerService: GameControllerService
    @EnvironmentObject var presetStore: PresetStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Header
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Preset Name", text: $preset.name)
                                .font(.title2)
                                .fontWeight(.regular)
                                .textFieldStyle(.plain)

                            TextField("Tag / Description", text: $preset.tag)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .textFieldStyle(.plain)
                        }

                        Spacer()

                        HStack(spacing: 8) {
                            Button(action: onToggle) {
                                Label(
                                    preset.isActive ? "Deactivate" : "Activate",
                                    systemImage: preset.isActive ? "stop.fill" : "play.fill"
                                )
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(preset.isActive ? .red : .green)
                            .controlSize(.regular)
                            .spotlightAnchor(SpotlightID.activateButton)

                            Button("Edit Bindings & Mappings", action: onEdit)
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                                .spotlightAnchor(SpotlightID.editButton)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .spotlightAnchor(SpotlightID.detailHeader)

                    Divider()
                        .padding(.horizontal)

                    detailsSection
                        .padding(.horizontal)

                    Divider()
                        .padding(.horizontal)

                    DisclosureGroup(isExpanded: $showVisualizer) {
                        // One visualizer per JOYSTICK in the preset. The
                        // preset model can target multiple controllers
                        // (one Joystick group per slot), so each joystick
                        // gets its own visualizer pinned to its slot.
                        // Falls back to "one per connected slot" when the
                        // preset has no joystick groups yet, so brand-new
                        // presets still surface something useful.
                        let connectedSlots = Array(controllerService.controllerDetails.keys).sorted()
                        let presetJoystickCount = preset.joysticks.count
                        let totalVisualizers = max(presetJoystickCount, connectedSlots.count)
                        if connectedSlots.isEmpty && presetJoystickCount == 0 {
                            Text("Connect a controller to see its live state here.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 8)
                        } else {
                            VStack(alignment: .leading, spacing: 14) {
                                ForEach(0..<totalVisualizers, id: \.self) { idx in
                                    // Joystick #idx is associated with
                                    // connected slot #idx by convention.
                                    let slot = idx < connectedSlots.count
                                        ? connectedSlots[idx]
                                        : idx
                                    HStack(spacing: 8) {
                                        Text("Joystick #\(idx)")
                                            .font(.caption2.weight(.semibold).monospaced())
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(
                                                Capsule().fill(Color.secondary.opacity(0.12))
                                            )
                                        Spacer()
                                    }
                                    VirtualControllerView(
                                        preset: preset,
                                        onJump: { target in
                                            onJumpToBinding(target)
                                        },
                                        fixedSlot: slot,
                                        trailing: {
                                            // Pops up from the on-controller
                                            // light-bar widget when clicked.
                                            if hasLightCapableController
                                                && slot == firstLightControllerIndex {
                                                presetLightBarSection
                                                    .frame(width: 280)
                                            }
                                        },
                                        lightBarTint: presetLightBarSwiftUIColor
                                    )
                                    .environmentObject(controllerService)
                                }
                            }
                            .padding(.top, 8)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "gamecontroller")
                                .foregroundStyle(.teal)
                            Text("Live Visualizer")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    .padding(.horizontal)
                    .spotlightAnchor(SpotlightID.visualizer)

                    Divider()
                        .padding(.horizontal)

                    presetNotesSection
                        .padding(.horizontal)
                        .spotlightAnchor(SpotlightID.notesSection)

                    // Joystick summary cards
                    ForEach(Array(preset.joysticks.enumerated()), id: \.element.id) { index, joystick in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Joystick #\(index)")
                                    .font(.subheadline)
                                Spacer()
                                Text("\(joystick.bindings.count) bindings")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }

                            if !joystick.tag.isEmpty && joystick.tag != "<write comments here>" {
                                Text(joystick.tag)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.4))
                        )
                        .padding(.horizontal)
                    }

                    if preset.joysticks.isEmpty {
                        ContentUnavailableView {
                            Label("No Joystick Mappings", systemImage: "gamecontroller")
                        } description: {
                            Text("Edit this preset to add joystick mappings.")
                        }
                    }
                }
                .padding(.vertical)
            }

        }
        .navigationTitle(preset.name)
    }

    // MARK: - Details

    /// Two-column metadata grid. Left column: Usage / Inputs / Outputs (what
    /// the preset asks for). Right column: Controllers / Storage (what the
    /// user's hardware + filesystem state look like). Saves vertical
    /// space versus the old stacked layout while keeping every datum.
    @ViewBuilder
    private var detailsSection: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 14) {
                detailsRow(title: "Usage", icon: "list.bullet.rectangle",
                           items: usageBullets)
                detailsRow(title: "Inputs", icon: "gamecontroller",
                           items: inputBullets)
                detailsRow(title: "Outputs", icon: "arrow.right.circle",
                           items: outputBullets)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 14) {
                if controllerService.connectedControllers.isEmpty {
                    detailsRow(title: "Controllers", icon: "antenna.radiowaves.left.and.right.slash",
                               items: ["No controllers currently connected."])
                } else {
                    detailsRow(title: "Controllers", icon: "antenna.radiowaves.left.and.right",
                               items: controllerBullets)
                }
                storageRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Storage section with Finder + version-history actions instead of a
    /// plain bullet list.
    @ViewBuilder
    private var storageRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc")
                .frame(width: 16)
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                Text("Storage")
                    .font(.caption.weight(.semibold))
                HStack(spacing: 6) {
                    Text("•").foregroundStyle(.tertiary)
                    Text(preset.filename)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Button {
                        revealInFinder()
                    } label: {
                        Label("Open in Finder", systemImage: "arrow.up.right.square")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                    }
                    .buttonStyle(.link)
                }
                HStack(spacing: 6) {
                    Text("•").foregroundStyle(.tertiary)
                    Text("Modified \(modifiedRelative)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                versionsDisclosure
            }
            Spacer(minLength: 0)
        }
    }

    @State private var showVersions: Bool = false
    @State private var showVisualizer: Bool = true
    /// Cached snapshot of the preset's version history. Loaded once per
    /// preset change instead of every render - the disk read + JSON decode
    /// inside `versions(for:)` is expensive enough that calling it on the
    /// SwiftUI render hot path was pegging the CPU once a controller was
    /// connected (each input poll triggered another full reload).
    @State private var cachedVersions: [PresetStore.PresetVersion] = []

    @ViewBuilder
    private var versionsDisclosure: some View {
        Group {
            if cachedVersions.isEmpty {
                HStack(spacing: 6) {
                    Text("•").foregroundStyle(.tertiary)
                    Text("No previous versions yet")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else {
                DisclosureGroup(isExpanded: $showVersions) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(cachedVersions) { version in
                            HStack(spacing: 6) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Text(versionLabel(version))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                                Button("Revert") {
                                    revertToVersion(version)
                                }
                                .buttonStyle(.link)
                                .font(.caption)
                            }
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    HStack(spacing: 6) {
                        Text("•").foregroundStyle(.tertiary)
                        Text("Previous versions (\(cachedVersions.count))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .controlSize(.small)
            }
        }
        .onAppear { reloadVersions() }
        .onChange(of: preset.id) { _, _ in reloadVersions() }
        .onChange(of: preset.modifiedAt) { _, _ in reloadVersions() }
    }

    private func reloadVersions() {
        cachedVersions = presetStore.versions(for: preset)
    }

    // MARK: - Per-preset Notes

    @ViewBuilder
    private var presetNotesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "note.text")
                    .foregroundStyle(.yellow)
                Text("Notes")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if !preset.notes.isEmpty {
                    Text("\(preset.notes.count) chars")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            // Plain TextEditor so users can paste multi-line context (which
            // controller this preset is for, what game, gotchas, etc.).
            // Persisted via the same `savePreset` path that the rest of the
            // detail page already uses on change.
            TextEditor(text: $preset.notes)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 60, maxHeight: 120)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.yellow.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.yellow.opacity(0.25), lineWidth: 0.5)
                )
                .overlay(alignment: .topLeading) {
                    if preset.notes.isEmpty {
                        Text("Free-form notes about this preset...")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Per-preset Light Bar override

    /// SwiftUI Color for the preset's light-bar override, if any. nil
    /// when no override is set - the visualizer's strip widget uses this
    /// to render its current state.
    private var presetLightBarSwiftUIColor: Color? {
        guard let rgb = preset.lightBarColor else { return nil }
        return Color(red: Double(rgb.floatR),
                     green: Double(rgb.floatG),
                     blue: Double(rgb.floatB))
    }

    /// Brightness override binding. Bridges the optional `Int?` in the model
    /// to a non-optional `Double` for the segmented picker. nil maps to 2
    /// (bright) which is the slot default.
    private var presetBrightnessBinding: SwiftUI.Binding<Double> {
        SwiftUI.Binding(
            get: { Double(preset.lightBarBrightness ?? 2) },
            set: { preset.lightBarBrightness = Int($0) }
        )
    }

    /// Color binding that round-trips between SwiftUI Color and the
    /// model's RGBLightColor (UInt8 components). Defaults to slot blue when
    /// the preset hasn't picked an override yet.
    private var presetColorBinding: SwiftUI.Binding<Color> {
        SwiftUI.Binding(
            get: {
                if let rgb = preset.lightBarColor {
                    return Color(red: Double(rgb.floatR),
                                 green: Double(rgb.floatG),
                                 blue: Double(rgb.floatB))
                }
                return .blue
            },
            set: { newColor in
                let ns = NSColor(newColor).usingColorSpace(.sRGB) ?? NSColor(newColor)
                preset.lightBarColor = RGBLightColor(
                    floatR: Float(ns.redComponent),
                    floatG: Float(ns.greenComponent),
                    floatB: Float(ns.blueComponent)
                )
            }
        )
    }

    @ViewBuilder
    private var presetLightBarSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "light.beacon.max.fill")
                    .foregroundStyle(.pink)
                Text("Light Bar for this preset")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if preset.lightBarColor != nil {
                    Button {
                        preset.lightBarColor = nil
                        preset.lightBarBrightness = nil
                    } label: {
                        Label("Clear override", systemImage: "arrow.uturn.backward")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Forget this preset's color and use the controller's general light instead")
                }
            }

            Text(preset.lightBarColor == nil
                 ? "No override set. The controller will keep its general color while this preset is active."
                 : "When this preset activates, the controller's light bar switches to this color. Deactivating reverts to the general color.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Visible warning so users don't think the color preview is
            // broken when nothing changes on the physical light bar until
            // the preset is activated.
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.yellow)
                    .font(.caption2)
                Text("Color only takes effect on the controller while this preset is activated. Hit Activate above to test it live.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.yellow.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.yellow.opacity(0.25), lineWidth: 0.5)
            )

            // Swatches grid - wraps to a second row in the narrow popover.
            // LazyVGrid with adaptive columns lets the swatches reflow when
            // the popover gets resized.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 28), spacing: 6)],
                      alignment: .leading, spacing: 6) {
                ForEach(lightBarPresets, id: \.name) { swatch in
                    Button {
                        presetColorBinding.wrappedValue = swatch.color
                    } label: {
                        Circle()
                            .fill(swatch.color)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help(swatch.name)
                }
            }

            // Custom color + brightness, each on their own row so the
            // labels can't get squeezed to vertical in a narrow popover.
            HStack(spacing: 8) {
                Text("Custom color")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)
                ColorPicker("", selection: presetColorBinding, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 28, height: 28)
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Text("Brightness")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)
                Picker("", selection: presetBrightnessBinding) {
                    Text("Off").tag(0.0)
                    Text("Dim").tag(1.0)
                    Text("Bright").tag(2.0)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.pink.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.pink.opacity(0.2), lineWidth: 0.5)
        )
    }

    private func versionLabel(_ v: PresetStore.PresetVersion) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        let bindings = v.preset.joysticks.flatMap(\.bindings).count
        return "\(formatter.string(from: v.savedAt))  •  \(bindings) binding\(bindings == 1 ? "" : "s")"
    }

    private func revertToVersion(_ v: PresetStore.PresetVersion) {
        presetStore.revertPreset(preset, to: v)
    }

    private func revealInFinder() {
        let url = presetStore.fileURL(for: preset)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @ViewBuilder
    private func detailsRow(title: String, icon: String, items: [String]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 16, alignment: .center)
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").foregroundStyle(.tertiary)
                        Text(item)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Detail bullet computation

    private var allBindings: [BindingModel] {
        preset.joysticks.flatMap(\.bindings)
    }

    private var usageBullets: [String] {
        // Tag already lives in the editable subtitle at the top - don't
        // restate it here.
        var bullets: [String] = []
        bullets.append("\(preset.joysticks.count) joystick mapping" +
                       (preset.joysticks.count == 1 ? "" : "s"))
        bullets.append("\(allBindings.count) total binding" +
                       (allBindings.count == 1 ? "" : "s"))
        return bullets
    }

    private var inputBullets: [String] {
        var counts: [InputType: Int] = [:]
        for b in allBindings { counts[b.input.type, default: 0] += 1 }
        var bullets: [String] = []
        if let n = counts[.button], n > 0 { bullets.append("Buttons: \(n) binding\(n == 1 ? "" : "s")") }
        if let n = counts[.axis], n > 0 { bullets.append("Axes: \(n) binding\(n == 1 ? "" : "s")") }
        if let n = counts[.hat], n > 0 { bullets.append("Hat (D-pad): \(n) binding\(n == 1 ? "" : "s")") }
        if let n = counts[.touchpad], n > 0 {
            bullets.append("Touchpad surface: \(n) binding\(n == 1 ? "" : "s") (DualSense / DualShock 4 only)")
        }
        if let n = counts[.touchpadRegion], n > 0 {
            bullets.append("Touchpad regions: \(n) tap binding\(n == 1 ? "" : "s")")
        }
        if bullets.isEmpty { bullets.append("No inputs bound yet.") }
        return bullets
    }

    private var outputBullets: [String] {
        var types: Set<OutputType> = []
        var haptic = 0
        var speech = 0
        var macro = 0
        var turbo = 0
        for b in allBindings {
            for o in b.outputs { types.insert(o.type) }
            if b.hapticEnabled == true { haptic += 1 }
            if b.speechEnabled == true { speech += 1 }
            if b.macroSteps?.isEmpty == false { macro += 1 }
            if b.turboEnabled == true { turbo += 1 }
        }
        var bullets: [String] = []
        if types.contains(.key) { bullets.append("Keyboard keystrokes") }
        if types.contains(.mouseButton) { bullets.append("Mouse buttons") }
        if types.contains(.mouseMotion) { bullets.append("Mouse motion") }
        if types.contains(.mouseWheel) || types.contains(.mouseWheelStep) { bullets.append("Scroll wheel") }
        if types.contains(.midiNote) || types.contains(.midiCC)
            || types.contains(.midiPitchBend) || types.contains(.midiProgramChange)
            || types.contains(.midiTransport) {
            bullets.append("MIDI (CoreMIDI virtual source)")
        }
        if haptic > 0 { bullets.append("Haptic feedback on \(haptic) binding\(haptic == 1 ? "" : "s")") }
        if speech > 0 { bullets.append("Spoken feedback on \(speech) binding\(speech == 1 ? "" : "s")") }
        if macro > 0 { bullets.append("Macros: \(macro)") }
        if turbo > 0 { bullets.append("Turbo: \(turbo)") }
        if bullets.isEmpty { bullets.append("No outputs configured.") }
        return bullets
    }

    private var controllerBullets: [String] {
        // Battery percentage and similar live state already shows in the
        // sidebar's controller status bar - we don't restate it here. This
        // section focuses on whether the connected hardware can run the
        // preset (button counts, special features, profile match).
        var bullets: [String] = []
        let sortedIndices = controllerService.controllerDetails.keys.sorted()
        for idx in sortedIndices {
            guard let info = controllerService.controllerDetails[idx] else { continue }
            var line = info.name
            if info.brand != .unknown {
                line += "  •  \(info.brand.displayName)"
            }
            bullets.append(line)
            var caps: [String] = []
            caps.append("\(info.buttonCount) buttons")
            caps.append("\(info.axisCount) axes")
            if info.hasTouchpad { caps.append("touchpad") }
            if info.hasLight { caps.append("light bar") }
            if info.hasAdaptiveTriggers { caps.append("adaptive triggers") }
            if info.supportsMotion { caps.append("motion sensors") }
            bullets.append("Capabilities: \(caps.joined(separator: ", "))")
            bullets.append("Profile: \(info.productCategory)" +
                           (info.hasExtendedGamepad ? "  •  extended MFi" : ""))
        }
        return bullets
    }

    private var modifiedRelative: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: preset.modifiedAt, relativeTo: Date())
    }

    // MARK: - Light Bar

    @State private var lightBarColor: Color = .blue
    @State private var lightBarBrightness: Double = 2
    @State private var lightBarApplyFlash = false

    private var hasLightCapableController: Bool {
        controllerService.controllerDetails.values.contains { $0.hasLight }
    }

    /// First controller slot that reports a light bar. Used as the target
    /// for the inline color/brightness controls. Multi-controller setups
    /// still apply only to one slot from here; richer per-controller control
    /// continues to live in the sidebar status popover.
    private var firstLightControllerIndex: Int? {
        controllerService.controllerDetails
            .filter { $0.value.hasLight }
            .keys
            .sorted()
            .first
    }

    /// Compact vertical version of the light-bar section designed to sit
    /// alongside the Live Visualizer instead of below it. Same controls,
    /// stacked tightly.
    @ViewBuilder
    private var lightBarSidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "light.beacon.max.fill")
                    .foregroundStyle(.pink)
                Text("Light Bar")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if lightBarApplyFlash {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
            }

            // Swatches in a 3-wide grid so the column stays narrow.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(lightBarPresets, id: \.name) { swatch in
                    Button {
                        lightBarColor = swatch.color
                        applyLightBar()
                    } label: {
                        Circle()
                            .fill(swatch.color)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help(swatch.name)
                }
            }

            HStack(spacing: 8) {
                ColorPicker("", selection: $lightBarColor, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 26, height: 26)
                Button("Apply") { applyLightBar() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            Picker("", selection: $lightBarBrightness) {
                Text("Off").tag(0.0)
                Text("Dim").tag(1.0)
                Text("Bright").tag(2.0)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: lightBarBrightness) { _, newValue in
                if let idx = firstLightControllerIndex {
                    controllerService.setControllerBrightness(at: idx, brightness: UInt8(newValue))
                }
            }

            Button {
                toggleRGBCycle()
            } label: {
                let cycling = isRGBCycleActive
                Label(cycling ? "Stop Cycle" : "RGB Cycle",
                      systemImage: cycling ? "stop.circle.fill" : "rainbow")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(isRGBCycleActive ? .red : .accentColor)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.pink.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.pink.opacity(0.2), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var lightBarSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "light.beacon.max.fill")
                    .foregroundStyle(.pink)
                Text("Light Bar")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if lightBarApplyFlash {
                    Label("Applied", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
            }

            // Preset swatches
            HStack(spacing: 8) {
                ForEach(lightBarPresets, id: \.name) { swatch in
                    Button {
                        lightBarColor = swatch.color
                        applyLightBar()
                    } label: {
                        Circle()
                            .fill(swatch.color)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help(swatch.name)
                }
                Spacer()
            }

            // Custom color row + brightness segmented control. Spacing is
            // tuned for visual breathing room - the segmented control sits
            // immediately to the right of Apply (separated by a divider)
            // rather than being pushed against the far edge of the panel.
            HStack(spacing: 12) {
                Text("Custom")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ColorPicker("", selection: $lightBarColor, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 28, height: 28)
                    .padding(.horizontal, 4)
                Button("Apply") { applyLightBar() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Divider()
                    .frame(height: 18)
                    .padding(.horizontal, 4)

                Text("Brightness")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $lightBarBrightness) {
                    Text("Off").tag(0.0)
                    Text("Dim").tag(1.0)
                    Text("Bright").tag(2.0)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
                .onChange(of: lightBarBrightness) { _, newValue in
                    if let idx = firstLightControllerIndex {
                        controllerService.setControllerBrightness(at: idx, brightness: UInt8(newValue))
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                let cycling = isRGBCycleActive
                Button {
                    toggleRGBCycle()
                } label: {
                    Label(cycling ? "Stop RGB Cycle" : "Start RGB Cycle",
                          systemImage: cycling ? "stop.circle.fill" : "rainbow")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(cycling ? .red : .accentColor)

                if cycling {
                    Text("Cycling through the spectrum every 1.5 s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    private var isRGBCycleActive: Bool {
        guard let idx = firstLightControllerIndex else { return false }
        return controllerService.rgbCycleActive[idx] == true
    }

    private func toggleRGBCycle() {
        guard let idx = firstLightControllerIndex else { return }
        controllerService.toggleRGBCycle(at: idx)
    }

    private var lightBarPresets: [(name: String, color: Color)] {
        [
            ("Red", .red), ("Orange", .orange), ("Yellow", .yellow),
            ("Green", .green), ("Cyan", .cyan), ("Blue", .blue),
            ("Purple", .purple), ("Pink", .pink), ("White", .white)
        ]
    }

    private func applyLightBar() {
        guard let idx = firstLightControllerIndex else { return }
        let ns = NSColor(lightBarColor).usingColorSpace(.sRGB) ?? NSColor(lightBarColor)
        let r = Float(ns.redComponent)
        let g = Float(ns.greenComponent)
        let b = Float(ns.blueComponent)
        controllerService.setControllerLight(at: idx, red: r, green: g, blue: b)

        withAnimation(.easeIn(duration: 0.15)) { lightBarApplyFlash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation(.easeOut(duration: 0.3)) { lightBarApplyFlash = false }
        }
    }
}

/// Compact capability-chip row that wraps to the next line when the
/// containing width runs out. Used by the controller status popover so the
/// chips never overlap or push other elements out of the popover.
struct FlowChipRow: View {
    let chips: [(String, Color)]

    var body: some View {
        if chips.isEmpty {
            EmptyView()
        } else {
            // Use SwiftUI's built-in flow layout (macOS 13+) - wraps chips
            // to multiple lines when they don't fit.
            FlowLayoutWrapper {
                ForEach(0..<chips.count, id: \.self) { i in
                    Text(chips[i].0)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(chips[i].1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(chips[i].1.opacity(0.15)))
                }
            }
        }
    }
}

/// Tiny flow-wrap container. We can't use SwiftUI 16+ `Layout` because the
/// app deploys to macOS 14, so this falls back to a stacked HStack + the
/// `_VariadicView` mechanism. For simplicity here we use a horizontal
/// wrap via `HStack` + `Spacer` controlled `FlexibleView`-style helper:
/// rendering one HStack per row, breaking on overflow. Implemented with
/// `GeometryReader` measurement.
fileprivate struct FlowLayoutWrapper<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        // The simplest workable wrap on macOS 14: a `WrappingHStack`
        // implemented via a `Layout` that arranges proposed sizes left to
        // right and breaks lines. macOS 14 *does* support `Layout`, so we
        // use it here without needing a deployment-target bump.
        WrappingHStackLayout(spacing: 4, lineSpacing: 4) {
            content
        }
    }
}

/// Left-to-right wrapping layout (the macOS equivalent of HTML's
/// inline-block + word-wrap). Each subview is given its ideal size; rows
/// break when the next subview would overflow.
fileprivate struct WrappingHStackLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxXSeen: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += rowHeight + lineSpacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            maxXSeen = max(maxXSeen, x)
            rowHeight = max(rowHeight, size.height)
        }
        let totalHeight = y + rowHeight
        return CGSize(width: min(maxWidth, maxXSeen), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.minX + maxWidth {
                y += rowHeight + lineSpacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                       proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
