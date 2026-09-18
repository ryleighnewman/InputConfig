import SwiftUI
import SceneKit
import Metal
import GameController

/// Notifications used by the macOS menu bar (Controller and View menus)
/// to drive UI actions on the active ContentView. Posted from
/// InputConfigMain's `.commands`; handled by `onReceive` blocks in
/// ContentView below.
extension Notification.Name {
    static let inputConfigShowStats              = Notification.Name("InputConfig.ShowStats")
    static let inputConfigOpenAbout              = Notification.Name("InputConfig.OpenAbout")
    static let inputConfigOpenSmartMaker         = Notification.Name("InputConfig.OpenSmartMaker")
    static let inputConfigToggleActivePreset     = Notification.Name("InputConfig.ToggleActive")
    static let inputConfigOpenTouchpadCalibration = Notification.Name("InputConfig.OpenTouchpadCal")
    static let inputConfigOpenMotionCalibration   = Notification.Name("InputConfig.OpenMotionCal")
    static let inputConfigStartTutorial          = Notification.Name("InputConfig.StartTutorial")
    static let inputConfigScrollToPreset         = Notification.Name("InputConfig.ScrollToPreset")
    /// Fired by the Quick Tour when it needs the PresetDetailView's
    /// internal ScrollView to scroll down to the Live Visualizer
    /// section. The detail view listens and expands the disclosure
    /// before scrolling.
    static let inputConfigScrollToVisualizer     = Notification.Name("InputConfig.ScrollToVisualizer")
    /// Tour scrolls the preset-detail back up to the top (header /
    /// Activate button area).
    static let inputConfigScrollToTop            = Notification.Name("InputConfig.ScrollToTop")
    /// Tour scrolls the preset editor's binding list to its
    /// Automation panel at the bottom.
    static let inputConfigScrollToAutomation     = Notification.Name("InputConfig.ScrollToAutomation")
    /// Tour scrolls the editor's binding list back to the top so the
    /// first binding row + its Options disclosure are visible.
    static let inputConfigScrollToFirstBinding   = Notification.Name("InputConfig.ScrollToFirstBinding")
    /// Tour fires this with a binding UUID; the matching
    /// BindingRowView flips its showAdvanced flag so the user sees
    /// the Options disclosure expand on its own.
    static let inputConfigExpandBindingOptions   = Notification.Name("InputConfig.ExpandBindingOptions")
}

/// Opens Settings on the About tab when the Help window asks for it. Lives in
/// its own modifier because ContentView's body is already at the Swift
/// type-checker's limit; an inline onReceive here fails to compile.
private struct OpenAboutObserver: ViewModifier {
    @Binding var tab: SettingsView.SettingsTab?
    func body(content: Content) -> some View {
        content.onReceive(
            NotificationCenter.default.publisher(for: .inputConfigOpenAbout)
        ) { _ in tab = .about }
    }
}

struct ContentView: View {
    @EnvironmentObject var presetStore: PresetStore
    @EnvironmentObject var controllerService: GameControllerService
    @EnvironmentObject var mappingEngine: MappingEngine
    @EnvironmentObject var eightBitDoDetector: EightBitDoDetector
    @ObservedObject private var accessibility = AccessibilityPermissionService.shared

    @State private var selectedPresetId: UUID?
    @State private var showAccessibilityAlert = false
    /// Proactive, reassuring Accessibility explainer shown on launch when the
    /// permission isn't granted yet, so people aren't left with non-working
    /// mappings just because macOS never surfaced its own prompt.
    @State private var showingAccessibilityIntro = false
    /// User opt-out for the launch explainer above. The persistent banner and
    /// the on-activation alert still cover them if they later need it.
    @AppStorage("suppressAccessibilityIntro") private var suppressAccessibilityIntro = false
    /// The welcome sheet has been shown once on this Mac.
    @AppStorage("InputConfig.welcomeIntroSeen") private var welcomeIntroSeen = false
    @State private var showingWelcomeIntro = false
    /// Shows the developer activity log pinned under the detail pane. Off by
    /// default so the shipping UI is clean; toggled from Settings → Advanced.
    @AppStorage("InputConfig.showDebugLog") private var showDebugLog = true
    @State private var showingSmartMaker = false
    /// The bundle's marketing version, e.g. "1.3".
    static var currentShortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    @State private var editingPreset: Preset?
    /// What's New popup: shown once when the app runs a version the user
    /// hasn't seen. Empty string = fresh install (stamp silently, no popup -
    /// the welcome screen already explains the app).
    @AppStorage("InputConfig.lastSeenVersion") private var lastSeenVersion: String = ""
    /// Version the user last saw notes for, so the popup can list every
    /// release since. nil shows only the current release.
    @State private var whatsNewSince: String?

    /// True when the app has been in use for a while, which tells an upgrade
    /// apart from a first run when no last-seen version is stored. Uses the
    /// support directory's creation date because it predates every setting.
    static var looksLikeExistingInstall: Bool {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return false }
        let appDir = support.appendingPathComponent("InputConfig", isDirectory: true)
        guard let created = try? appDir.resourceValues(
            forKeys: [.creationDateKey]).creationDate else { return false }
        return Date().timeIntervalSince(created) > 600
    }
    @State private var showingWhatsNew: Bool = false
    @State private var newlyCreatedPresetId: UUID?
    @State private var showingImportSheet = false
    @State private var presentedDemoKind: FeatureDemoKind?
    @State private var showingStats: Bool = false
    /// The settings sheet, presented item-style so the tab travels WITH
    /// the presentation: nil = closed, otherwise the tab to open on.
    /// (A Bool + separate tab state raced: SwiftUI could present with the
    /// sheet content closure from the previous body pass, ignoring a tab
    /// set in the same tick.)
    @State private var settingsSheetTab: SettingsView.SettingsTab? = nil
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
                .accessibilityLabel("Home")
                .accessibilityHint("Returns to the welcome screen")
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
                .accessibilityLabel("Statistics")
                .accessibilityHint("Opens the lifetime statistics dashboard")
            }

            // Trailing - settings shortcut only. Active-preset chip and
            // controller status pill were removed at the user's request -
            // active state lives elsewhere (sidebar status, preset row
            // green dot) and the toolbar reads cleaner without them.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    settingsSheetTab = .general
                } label: {
                    Image(systemName: "gear")
                        .symbolRenderingMode(.hierarchical)
                }
                .help("Settings")
                .spotlightAnchor(SpotlightID.settingsButton)
                .accessibilityLabel("Settings")
                .accessibilityHint("Opens app settings")
            }
        }
        .safeAreaInset(edge: .top) { accessibilityBanner }
        // Hierarchical rendering across the whole app: every colored SF Symbol
        // draws its tint at varying opacities (transparency in the secondary
        // layers) instead of one flat solid fill. Set once at the root; the
        // environment value propagates into every sheet and popover too.
        .symbolRenderingMode(.hierarchical)
        .alert("Accessibility access needed", isPresented: $showAccessibilityAlert) {
            Button("Open Accessibility Settings") { accessibility.openSystemSettings() }
            Button("Not Now", role: .cancel) { }
        } message: {
            Text("To send the keyboard and mouse actions in this preset, turn on InputConfig under System Settings → Privacy & Security → Accessibility. Your mappings will start working as soon as you do.")
        }
        .sheet(isPresented: $showingStats) {
            StatsView()
                .glassBackground()
        }
        .modifier(ReviewPromptPresenter())
        .sheet(isPresented: $showingSmartMaker) {
            SmartPresetMakerView { preset in
                selectedPresetId = preset.id
                flashingPresetID = preset.id
                NotificationCenter.default.post(name: .inputConfigScrollToPreset, object: preset.id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if flashingPresetID == preset.id {
                        withAnimation(.easeOut(duration: 0.9)) { flashingPresetID = nil }
                    }
                }
            }
            .environmentObject(presetStore)
            .environmentObject(controllerService)
            .glassBackground()
        }
        .sheet(item: $settingsSheetTab) { tab in
            // Done lives in a translucent footer inside the sheet rather than
            // the system confirmation bar, which draws its own opaque
            // background and broke the frosted look at the bottom of Settings.
            VStack(spacing: 0) {
                SettingsView(initialTab: tab)
                    .environmentObject(presetStore)
                    .environmentObject(controllerService)
                Divider()
                HStack {
                    Spacer()
                    Button("Done") { settingsSheetTab = nil }
                        .buttonStyle(.solid)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .frame(minWidth: 620, minHeight: 480)
            .glassBackground()
        }
        .sheet(isPresented: $showingTouchpadCalibrationFromMenu) {
            TouchpadCalibrationView()
                .environmentObject(presetStore)
                .glassBackground()
        }
        .sheet(isPresented: $showingMotionCalibrationFromMenu) {
            MotionCalibrationView()
                .environmentObject(controllerService)
                .glassBackground()
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
                Text("This preset uses both motion and touchpad inputs. Calibrate them first so the cursor and aim feel right on your controller - InputConfig doesn't yet know your controller's resting drift or your touchpad's usable bounds.")
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
        .modifier(OpenAboutObserver(tab: $settingsSheetTab))
        .modifier(TutorialPlumbing(
            state: tutorialState,
            anchors: $tutorialAnchors,
            onTutorialEnded: handleTutorialEnded
        ))
        .onReceive(NotificationCenter.default.publisher(for: .inputConfigShowStats)) { _ in
            showingStats = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .inputConfigOpenSmartMaker)) { _ in
            showingSmartMaker = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .inputConfigToggleActivePreset)) { _ in
            // Toggle the sidebar-selected preset, if any.
            if let pid = selectedPresetId,
               let preset = presetStore.presets.first(where: { $0.id == pid }) {
                togglePreset(preset)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .inputConfigOpenTouchpadCalibration)) { _ in
            showingTouchpadCalibrationFromMenu = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .inputConfigOpenMotionCalibration)) { _ in
            showingMotionCalibrationFromMenu = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .inputConfigStartTutorial)) { _ in
            startTutorial()
        }
        .onChange(of: tutorialState.isActive) { _, active in
            // When the tutorial ends (Finish, Skip, or natural end),
            // restore the controller list so the synthetic Edge entry
            // disappears alongside the tutorial.
            if !active && controllerService.tutorialFakeControllerActive {
                controllerService.disableTutorialFakeController()
            }
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
        .sheet(isPresented: $showingWhatsNew, onDismiss: {
            lastSeenVersion = Self.currentShortVersion
        }) {
            WhatsNewView(since: whatsNewSince)
                .glassBackground()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: MenuBarController.showWhatsNewNotification)) { _ in
            // Opened by hand from the menu bar: show this release's notes.
            whatsNewSince = nil
            showingWhatsNew = true
        }
        .onAppear {
            let current = Self.currentShortVersion
            if lastSeenVersion.isEmpty {
                // No stored version means one of two very different things:
                // a genuine first run, or an upgrade from a build that
                // shipped before this popup existed. Treating both as a
                // first run is what silently swallowed the release notes
                // for everyone who was already using the app.
                if Self.looksLikeExistingInstall {
                    whatsNewSince = nil
                    showingWhatsNew = true
                } else {
                    lastSeenVersion = current
                }
            } else if lastSeenVersion != current {
                // Show everything released since they last looked, so
                // skipping a version does not skip its notes.
                whatsNewSince = lastSeenVersion
                showingWhatsNew = true
            }
        }
        .sheet(item: $editingPreset, onDismiss: handleEditorDismiss) { preset in
            PresetEditorView(preset: preset,
                             enginePausedNotice: engineWasRunningBeforeEdit,
                             pendingJump: pendingEditorJump) { updated in
                newlyCreatedPresetId = nil // Saved successfully, don't delete
                presetStore.savePreset(updated)
                // If the edited preset is the one currently running, restart the
                // engine with the new value so it rebuilds its binding caches;
                // otherwise edits would not take effect until the next activation.
                if mappingEngine.isRunning && presetStore.activePresetId == updated.id {
                    mappingEngine.start(with: updated)
                }
                editingPreset = nil
            }
            .environmentObject(controllerService)
            .environmentObject(mappingEngine)
            .environmentObject(presetStore)
            // 1240, not 1150: the sheet takes exactly its minimum (the rows
            // scroll, so nothing reports an ideal width), and MIDI rows need
            // about 70 pt more than key rows. At 1150 every row in a MIDI
            // preset ran past both edges of the sheet.
            .frame(minWidth: 1240, idealWidth: 1340, minHeight: 700, idealHeight: 800)
            .glassBackground()
        }
        .onAppear {
            presetStore.reseedExamplePresets()
            // Proactively explain + offer Accessibility on launch if it isn't
            // granted, since macOS doesn't always surface its own prompt and
            // the app's mappings can't fire without it.
            accessibility.refresh()
            // First launch: the welcome first, then the permission ask
            // follows from its button. Later launches: the permission ask
            // alone, if it is still needed.
            if !welcomeIntroSeen {
                showingWelcomeIntro = true
            } else if !accessibility.isTrusted && !suppressAccessibilityIntro {
                showingAccessibilityIntro = true
            }
        }
        // The close hook drops What's New too; its state lives here, not
        // in the hook modifier. A modifier rather than one more closure on
        // this chain, which the type-checker could not finish.
        .modifier(DebugCloseWhatsNew(showing: $showingWhatsNew))
        .modifier(FirstRunSheets(showingWelcome: $showingWelcomeIntro,
                                 showingAccessibility: $showingAccessibilityIntro,
                                 welcome: { AnyView(welcomeIntroSheet) },
                                 accessibilityIntro: { AnyView(accessibilityIntroSheet) }))
        .sheet(item: $presentedDemoKind) { kind in
            FeatureDemoView(
                kind: kind,
                onJumpToPreset: { presetName in
                    presentedDemoKind = nil
                    jumpToPreset(named: presetName)
                },
                onOpenStatistics: {
                    // Dismiss this sheet first, then present the stats sheet.
                    // Two sheets can't be presented from the same view at once.
                    presentedDemoKind = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showingStats = true }
                },
                onOpenSettings: {
                    presentedDemoKind = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { settingsSheetTab = .general }
                },
                presetForConnectedController: {
                    let brand = controllerService.controllerDetails[0]?.brand ?? .unknown
                    return ExamplePresets.exampleName(for: brand)
                }
            )
            .glassBackground()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: GlobalHotKeyService.toggleNotification)) { _ in
            handleGlobalHotkeyToggle()
        }
        .modifier(DebugAutomationHooks(
            presetStore: presetStore,
            selectedPresetId: $selectedPresetId,
            editingPreset: $editingPreset,
            showingSmartMaker: $showingSmartMaker,
            showingStats: $showingStats,
            settingsSheetTab: $settingsSheetTab,
            showingMotion: $showingMotionCalibrationFromMenu,
            showingTouchpad: $showingTouchpadCalibrationFromMenu,
            presentedDemoKind: $presentedDemoKind,
            onToggle: { togglePreset($0) }
        ))
        .debugFakeController(controllerService)
        .debugCaptureSheets()
    }

    /// Fired by the global keyboard shortcut. If a preset is currently active,
    /// stop it; otherwise re-activate the most recently used preset (falling
    /// back to the first preset). Goes through the same togglePreset path so
    /// calibration gates and the Accessibility prompt still apply.
    private func handleGlobalHotkeyToggle() {
        if let active = presetStore.presets.first(where: { $0.isActive }) {
            togglePreset(active)
            return
        }
        let target = presetStore.lastActivatedPresetId
            .flatMap { id in presetStore.presets.first(where: { $0.id == id }) }
            ?? presetStore.presets.first
        if let target { togglePreset(target) }
    }

    /// Select a preset by name, scroll it into view, and briefly flash it
    /// green so the user sees where it landed. Shared by the feature-demo
    /// "Take me to an example" button and the per-controller example jump.
    private func jumpToPreset(named presetName: String) {
        guard let preset = presetStore.presets.first(where: { $0.name == presetName }) else { return }
        selectedPresetId = preset.id
        flashingPresetID = preset.id
        NotificationCenter.default.post(
            name: .inputConfigScrollToPreset,
            object: preset.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if flashingPresetID == preset.id {
                withAnimation(.easeOut(duration: 0.9)) { flashingPresetID = nil }
            }
        }
    }

    // MARK: - Sidebar

    @State private var creatingGroupForPreset: Preset?
    @State private var newGroupName: String = ""
    @State private var renamingGroup: PresetGroup?
    @State private var renameGroupName: String = ""
    @FocusState private var groupNameFocused: Bool
    /// The group whose color popover is open (nil = none). Drives a per-row
    /// popover with tinted swatches + the macOS color picker.
    @State private var colorEditingGroup: PresetGroup?
    /// Working color for the folder color picker's "Custom" well.
    @State private var folderPickerColor: Color = .accentColor
    /// The most recently created group ID. Drives a brief green-flash
    /// animation in the sidebar so the user's eye lands on the new entry.
    @State private var flashingGroupID: UUID?

    private var sidebarView: some View {
        VStack(spacing: 0) {
            controllerStatusBar

            ScrollViewReader { proxy in
            List(selection: $selectedPresetId) {
                // The user's own presets first, above the shipped folders,
                // with New Preset as the first row so making one is the most
                // obvious thing in the sidebar. Always shown, even when empty.
                Section {
                    Button {
                        createNewPreset()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                                .foregroundStyle(Color.accentColor)
                            Text("New Preset")
                                .font(.body.weight(.medium))
                            Spacer(minLength: 0)
                        }
                        // Sidebar rows sit at a minimum height and center
                        // their content in it, so the row insets alone cannot
                        // move the label; this pushes it down until the room
                        // above matches the room below.
                        .padding(.top, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 2, trailing: 2))
                    .selectionDisabled()
                    .accessibilityHint("Creates a preset and opens it in the editor")

                    ForEach(presetStore.presets(in: nil)) { preset in
                        presetRow(for: preset, leadingInset: 8)
                    }
                    topLevelFolders(presetStore.userTopLevelGroups, builtIn: false)

                    // The shipped library, under a heading of its own. It is
                    // a plain row rather than a second section header so the
                    // space above and below New Preset comes out the same;
                    // the list pads a section header more than it pads a
                    // row. Only a heading: these are ordinary presets in the
                    // user's own folder, edits stick, a preset moved out
                    // stays out, and updates never rewrite them.
                    Text("Built-in Presets")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .listRowInsets(EdgeInsets(top: 0, leading: -12, bottom: 10, trailing: 2))
                        .selectionDisabled()
                        .accessibilityAddTraits(.isHeader)
                    topLevelFolders(presetStore.builtInTopLevelGroups, builtIn: true)
                } header: {
                    Text("My Presets")
                        .font(.caption)
                }

                // Trash - shown only when there's something in it. Each
                // entry has Restore + Permanently Delete actions. No TTL -
                // entries persist on disk until the user acts on them.
                if !presetStore.recentlyDeleted.isEmpty || !presetStore.deletedFolders.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $showingTrashDisclosure) {
                            ForEach(presetStore.deletedFolders) { entry in
                                trashFolderRow(entry: entry)
                                    .selectionDisabled()
                            }
                            ForEach(presetStore.recentlyDeleted) { entry in
                                trashRow(entry: entry)
                                    .selectionDisabled()
                            }
                            Button {
                                presetStore.emptyTrash()
                            } label: {
                                Label("Empty Trash", systemImage: "trash.slash")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.solidSecondaryCompact)
                            .padding(.top, 4)
                            .selectionDisabled()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "trash")
                                    .foregroundStyle(.orange)
                                Text("Trash (\(presetStore.recentlyDeleted.count + presetStore.deletedFolders.count))")
                                    .font(.caption.weight(.semibold))
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                            // A selection-disabled row does not toggle its
                            // disclosure on a label click, so the label does.
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showingTrashDisclosure.toggle()
                                }
                            }
                        }
                        // The trash is not a preset: clicking it must not
                        // clear the selection and bounce the window to the
                        // home screen.
                        .selectionDisabled()
                    }
                }
            }
            .listStyle(.sidebar)
            // The list's disclosure chevrons sit at a fixed column the row
            // insets cannot move, so the whole list steps in 12 pt: the
            // folder outlines then sit 20 pt from the window edge, matching
            // their distance to the panel's divider on the right, with the
            // chevrons inside them.
            .padding(.leading, 12)
            .scrollContentBackground(.hidden)
            .onReceive(NotificationCenter.default.publisher(for: .inputConfigScrollToPreset)) { note in
                guard let id = note.object as? UUID else { return }
                withAnimation(.easeOut(duration: 0.35)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .inputConfigImportedPreset)) { note in
                // Newly imported preset hint: select, scroll, flash.
                // The flash uses the same flashingPresetID state the
                // FeatureDemo "jump to preset" flow already uses, so
                // the visual treatment matches across the app.
                guard let id = note.object as? UUID else { return }
                selectedPresetId = id
                flashingPresetID = id
                withAnimation(.easeOut(duration: 0.35)) {
                    proxy.scrollTo(id, anchor: .center)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if flashingPresetID == id {
                        withAnimation(.easeOut(duration: 0.9)) { flashingPresetID = nil }
                    }
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
                .glassBackground()
        }
        .sheet(item: $renamingGroup) { group in
            renameGroupSheet(for: group)
                .glassBackground()
        }
    }

    /// Render a folder and everything under it. Recursive: a folder's content
    /// is its child folders (each rendered by another `groupSection` call) and
    /// then its own presets, so folders can nest to any depth. Returns AnyView
    /// because an opaque `some View` can't reference itself recursively.
    private func groupSection(_ group: PresetGroup, depth: Int = 0,
                              outline: FolderOutlineContext? = nil) -> AnyView {
        let presetsInGroup = presetStore.presets(in: group.id)
        let childGroups = presetStore.subgroups(of: group.id)
        // Which piece of the enclosing top-level folder's outline a row draws.
        func role(for id: AnyHashable) -> FolderOutlineRole? {
            guard let outline else { return nil }
            return outline.lastRowID == id ? .bottom : .middle
        }
        return AnyView(
            DisclosureGroup(isExpanded: groupExpandedBinding(for: group)) {
                // Nested folders first, then this folder's own presets.
                ForEach(childGroups) { sub in
                    // A nested folder header is a middle row of the top-level
                    // box, or its bottom when it is the last thing showing.
                    let subHeaderRole: FolderOutlineRole? =
                        (outline != nil && !sub.isExpanded) ? role(for: AnyHashable(sub.id))
                        : (outline != nil ? .middle : nil)
                    groupSection(sub, depth: depth + 1, outline: outline)
                        .listRowBackground(outline.map { FolderOutlineSegment(role: subHeaderRole ?? .middle, color: $0.color) })
                }
                ForEach(presetsInGroup) { preset in
                    presetRow(for: preset,
                              outline: outline.map { (role(for: AnyHashable(preset.id)) ?? .middle, $0.color) })
                }
                if childGroups.isEmpty && presetsInGroup.isEmpty {
                    // The placeholder closes the box only when it is the last
                    // thing showing; an empty subfolder above its parent's own
                    // presets is a middle row.
                    Text("Drop a preset here, or add a subfolder.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 4)
                        .listRowBackground(outline.map {
                            FolderOutlineSegment(role: role(for: AnyHashable("empty-\(group.id.uuidString)")) ?? .middle, color: $0.color)
                        })
                }
            } label: {
                let tint = groupTintColor(for: group)
                HStack(spacing: 6) {
                    Image(systemName: tint == nil ? "folder" : "folder.fill")
                        .font(.caption)
                        // Liquid-glass folder chips: a vertical gradient of the
                        // folder's own color (bright where light would catch the
                        // top edge, deeper toward the base) rendered genuinely
                        // see-through, so the frosted sidebar reads through the
                        // icon instead of it sitting as a flat paint chip.
                        .foregroundStyle(
                            tint.map { c in
                                AnyShapeStyle(LinearGradient(
                                    colors: [c.opacity(0.95), c.opacity(0.45)],
                                    startPoint: .top, endPoint: .bottom))
                            } ?? AnyShapeStyle(.secondary)
                        )
                        .opacity(tint == nil ? 1 : 0.75)
                    Text(group.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                // Keep the folder icon tight to the disclosure arrow. Nesting
                // depth is already conveyed by the List's own per-level indent,
                // so no extra manual left-indent is added here.
                .padding(.leading, 2)
                .contentShape(Rectangle())
                .contextMenu {
                    Button("Rename Folder…") {
                        renameGroupName = group.name
                        renamingGroup = group
                    }
                    Button("Folder Color…") {
                        colorEditingGroup = group
                    }
                    Button("New Subfolder…") {
                        let id = presetStore.createGroup(named: "New Folder", parentID: group.id)
                        presetStore.setGroupExpanded(group.id, true)
                        if let g = presetStore.groups.first(where: { $0.id == id }) {
                            renameGroupName = g.name
                            renamingGroup = g
                        }
                    }
                    Menu("Move to Folder") {
                        Button("Top Level (no parent)") {
                            presetStore.setGroupParent(group.id, parentID: nil)
                        }
                        let targets = eligibleParentFolders(for: group)
                        if !targets.isEmpty {
                            Divider()
                            ForEach(targets) { target in
                                Button(target.name) {
                                    presetStore.setGroupParent(group.id, parentID: target.id)
                                    presetStore.setGroupExpanded(target.id, true)
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Delete Folder", role: .destructive) {
                        presetStore.deleteGroup(group.id)
                    }
                }
                .popover(isPresented: Binding(
                    get: { colorEditingGroup?.id == group.id },
                    set: { if !$0 { colorEditingGroup = nil } }
                ), arrowEdge: .trailing) {
                    folderColorPopover(for: group)
                }
            }
            // Allow dropping presets onto this folder header to add them.
            .dropDestination(for: String.self) { items, _ in
                for item in items {
                    if let uuid = UUID(uuidString: item) {
                        presetStore.setPresetGroup(uuid, groupID: group.id)
                    }
                }
                return true
            }
        )
    }

    /// Folders this folder may be moved into: every folder except itself and
    /// its own descendants (moving into those would create a cycle).
    /// Every folder with its ancestors in the name ("Gaming / First-Person"),
    /// sorted by that path, for the preset row's Move to Group menu.
    private var groupPathChoices: [(id: UUID, path: String)] {
        let byID = Dictionary(uniqueKeysWithValues: presetStore.groups.map { ($0.id, $0) })
        func path(_ g: PresetGroup) -> String {
            var parts = [g.name]
            var cursor = g.parentID
            var hops = 0
            while let pid = cursor, let parent = byID[pid], hops < 8 {
                parts.insert(parent.name, at: 0)
                cursor = parent.parentID
                hops += 1
            }
            return parts.joined(separator: " / ")
        }
        return presetStore.groups
            .map { ($0.id, path($0)) }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    private func eligibleParentFolders(for group: PresetGroup) -> [PresetGroup] {
        presetStore.groups
            .filter { !presetStore.isGroup($0.id, descendantOfOrEqualTo: group.id) }
            .sorted { $0.name < $1.name }
    }

    /// Map a `PresetGroup.color` value to a SwiftUI Color, or nil for no
    /// tint. Accepts both a named palette color and a "#RRGGBB" hex string
    /// (chosen via the macOS color picker). Kept in the view layer so the
    /// model stays AppKit / Color agnostic.
    /// The id of the last row a top-level folder currently shows, so that
    /// row can close the folder's outline. Children render as nested folders
    /// first, then presets, so the last preset wins; otherwise the last
    /// nested folder, descending into it while it is expanded; otherwise the
    /// folder's own header (empty or collapsed).
    private func lastVisibleRowID(in group: PresetGroup) -> AnyHashable {
        guard group.isExpanded else { return AnyHashable(group.id) }
        let presets = presetStore.presets(in: group.id)
        if let last = presets.last { return AnyHashable(last.id) }
        let subs = presetStore.subgroups(of: group.id)
        if let lastSub = subs.last {
            return lastSub.isExpanded ? lastVisibleRowID(in: lastSub) : AnyHashable(lastSub.id)
        }
        return AnyHashable("empty-\(group.id.uuidString)")
    }

    private func groupTintColor(for group: PresetGroup) -> Color? {
        guard let value = group.color else { return nil }
        if value.hasPrefix("#") { return Self.color(fromHex: value) }
        return namedColor(value)
    }

    /// Palette name -> Color (the fixed `PresetGroup.colorOptions` set).
    private func namedColor(_ name: String) -> Color? {
        switch name {
        case "blue":   return .blue
        case "purple": return .purple
        case "pink":   return .pink
        case "red":    return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green":  return .green
        case "teal":   return .teal
        case "indigo": return .indigo
        case "brown":  return .brown
        default:       return nil
        }
    }

    /// Parse "#RRGGBB" into an sRGB Color. nil on malformed input.
    static func color(fromHex hex: String) -> Color? {
        var s = Substring(hex)
        if s.hasPrefix("#") { s = s.dropFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return Color(.sRGB,
                     red: Double((v >> 16) & 0xFF) / 255.0,
                     green: Double((v >> 8) & 0xFF) / 255.0,
                     blue: Double(v & 0xFF) / 255.0)
    }

    /// Serialize a Color to "#RRGGBB" (sRGB) for storage in PresetGroup.color.
    static func hexString(from color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        let r = max(0, min(255, Int(round(ns.redComponent * 255))))
        let g = max(0, min(255, Int(round(ns.greenComponent * 255))))
        let b = max(0, min(255, Int(round(ns.blueComponent * 255))))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Folder-color editor popover: tinted palette swatches (so the colors
    /// are actually visible) plus a macOS ColorPicker for any custom color
    /// (stored as hex). Also offers None / Restore Default.
    @ViewBuilder
    private func folderColorPopover(for group: PresetGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Folder Color")
                .font(.subheadline.weight(.semibold))

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 10) {
                ForEach(PresetGroup.colorOptions, id: \.self) { name in
                    Button {
                        presetStore.setGroupColor(group.id, color: name)
                        colorEditingGroup = nil
                    } label: {
                        Circle()
                            .fill(namedColor(name) ?? .gray)
                            .frame(width: 24, height: 24)
                            .overlay(
                                Circle().strokeBorder(
                                    Color.primary.opacity(group.color == name ? 0.9 : 0.15),
                                    lineWidth: group.color == name ? 2 : 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(name.capitalized)
                    .accessibilityLabel(name.capitalized)
                    .accessibilityAddTraits(group.color == name ? [.isSelected] : [])
                }
            }

            Divider()

            // Any custom color via the native macOS color picker.
            HStack(spacing: 10) {
                ColorPicker("", selection: $folderPickerColor, supportsOpacity: false)
                    .labelsHidden()
                Text("Custom color")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Apply") {
                    presetStore.setGroupColor(group.id, color: Self.hexString(from: folderPickerColor))
                    colorEditingGroup = nil
                }
                .buttonStyle(.solidCompact)
            }

            Divider()

            HStack {
                Button("None") {
                    presetStore.setGroupColor(group.id, color: nil)
                    colorEditingGroup = nil
                }
                .buttonStyle(.solidSecondaryCompact)
                if ExamplePresets.groupDefaultColors[group.name] != nil {
                    Button("Restore Default") {
                        presetStore.applyDefaultGroupColor(group.id)
                        colorEditingGroup = nil
                    }
                    .buttonStyle(.solidSecondaryCompact)
                }
                Spacer()
            }
            .font(.caption)
        }
        .padding(14)
        .frame(width: 250)
        .onAppear {
            folderPickerColor = groupTintColor(for: group) ?? .accentColor
        }
    }

    /// Sidebar row for one deleted preset. Restore moves it back to the
    /// presets directory; the trash icon permanently nukes the entry.
    @ViewBuilder
    /// A trashed folder: put back restores the folder, its subfolders, and
    /// every preset that was inside.
    private func trashFolderRow(entry: PresetStore.DeletedFolder) -> some View {
        let count = entry.presets.count
        return HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(.caption)
                    .lineLimit(1)
                Text("\(count) preset\(count == 1 ? "" : "s") \u{00B7} \(trashDateString(entry.deletedAt))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            Button {
                presetStore.restoreDeletedFolder(entry)
            } label: {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.green)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Put back the folder and everything in it")
            .accessibilityLabel("Put back folder")
            Button {
                presetStore.permanentlyDeleteFolder(entry)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.red.opacity(0.8))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Delete the folder and its presets permanently")
            .accessibilityLabel("Delete folder permanently")
        }
        .padding(.vertical, 3)
    }

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
                    .font(.system(size: 16))
                    .foregroundStyle(.green)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Put back")
            .accessibilityLabel("Put back preset")
            Button {
                presetStore.permanentlyDelete(entry)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.red.opacity(0.8))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Delete permanently")
            .accessibilityLabel("Delete preset permanently")
        }
        .padding(.vertical, 3)
    }

    private func trashDateString(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Deleted " + formatter.localizedString(for: date, relativeTo: Date())
    }

    @ViewBuilder
    private func presetRow(for preset: Preset, leadingInset: CGFloat = -18,
                           outline: (FolderOutlineRole, Color)? = nil) -> some View {
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
            },
            groupChoices: groupPathChoices,
            currentGroupID: preset.groupID,
            onMoveToGroup: { target in
                presetStore.setPresetGroup(preset.id, groupID: target)
                if let target { presetStore.setGroupExpanded(target, true) }
            },
            onNewGroup: {
                creatingGroupForPreset = preset
                newGroupName = "New Group"
                pendingGroupPresetIDs = [preset.id]
            }
        )
        .tag(preset.id)
        .id(preset.id) // For ScrollViewReader.scrollTo
        // List(.sidebar) default row insets give the row a fat
        // leading gutter (~16pt) which pushes the active-indicator
        // dot well away from the left edge. The DisclosureGroup
        // wrapping the group additionally indents children by the
        // disclosure-triangle width. Push hard with a generous
        // negative leading inset so the active dot sits flush with
        // the group disclosure column, and zero out the trailing
        // inset so the ellipsis sits flush with the right edge of
        // the sidebar.
        .listRowInsets(EdgeInsets(top: 2, leading: leadingInset,
                                  bottom: 2, trailing: 2))
        .listRowBackground(
            ZStack {
                // The enclosing folder's outline piece, if this row is in one.
                if let outline {
                    FolderOutlineSegment(role: outline.0, color: outline.1)
                }
                // Brief flash when the user jumps here from a feature demo;
                // otherwise a steady green hint marks the actively running
                // preset. Matches the system selection pill exactly: same
                // continuous-corner curvature and the same inset, so the green
                // hint sits in the identical box the blue selection draws.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(flashingPresetID == preset.id
                          ? Color.green.opacity(0.35)
                          : (preset.isActive ? Color.green.opacity(0.16) : Color.clear))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1)
                // Deliberately NO implicit .animation here: List reuses row
                // views while scrolling, and an animation keyed on isActive /
                // flashingPresetID replayed the green fade on whichever preset
                // was recycled into the old active row's slot (a green flash
                // ~2/3 down the list while scrolling). The flash fade-out is
                // driven explicitly with withAnimation where the flash clears.
            }
        )
        .draggable(preset.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            // Drop one preset onto another → put it at that row's position.
            // Reorders inside a folder and moves between folders with the same
            // gesture. This used to create a new folder from the two presets,
            // which meant there was no way to reorder at all; that action is
            // still on the row's context menu as "New Group…".
            var handled = false
            for item in items {
                if let uuid = UUID(uuidString: item), uuid != preset.id {
                    presetStore.movePreset(uuid, toPositionOf: preset.id)
                    handled = true
                }
            }
            return handled
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
                Button("New Group…") {
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

    /// Whether the welcome screen's release-notes popover is open.
    @State private var showWelcomeChangelog = false

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
                .buttonStyle(.solidSecondary)
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
                .focused($groupNameFocused)
            HStack {
                Spacer()
                Button("Cancel") {
                    renamingGroup = nil
                }
                .buttonStyle(.solidSecondary)
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let name = renameGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty {
                        presetStore.renameGroup(group.id, to: name)
                    }
                    renamingGroup = nil
                }
                .buttonStyle(.solid)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            // Async so the sheet's field is in the window before focusing.
            DispatchQueue.main.async { groupNameFocused = true }
        }
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

            if controllerService.connectedControllers.isEmpty
                && controllerService.rawHIDGamepadSlots.isEmpty
                && !controllerService.debugMarketingFakeActive {
                HStack(spacing: 6) {
                    ControllerGlyph(height: 13)
                        .foregroundStyle(.secondary)
                    Text("No controllers connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            } else {
                #if DEBUG
                if controllerService.debugMarketingFakeActive {
                    ForEach(controllerService.controllerDetails.keys.sorted(), id: \.self) { idx in
                        ControllerChipView(
                            controller: nil, index: idx,
                            color: Self.controllerColors[idx % Self.controllerColors.count],
                            info: controllerService.controllerDetails[idx],
                            onSetLight: { _, _, _ in }, onSetBrightness: { _ in },
                            onToggleRGB: {}, isRGBActive: false, onRefresh: {},
                            onOpenExample: {}, rgbSpeed: $controllerService.rgbCycleSpeed)
                    }
                }
                #endif
                ForEach(Array(controllerService.connectedControllers.enumerated()), id: \.element) { index, controller in
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
                        },
                        onOpenExample: {
                            let brand = controllerService.controllerDetails[index]?.brand ?? .unknown
                            jumpToPreset(named: ExamplePresets.exampleName(for: brand))
                        },
                        rgbSpeed: $controllerService.rgbCycleSpeed
                    )
                }

                // Raw HID gamepads (8BitDo XInput, Xbox 360 wired,
                // Logitech F310/F710, generic descriptor-parsed pads).
                // They don't fit the MFi GCController chip (no battery,
                // no light bar), so render a simpler chip per slot.
                ForEach(rawHIDSortedSlots, id: \.slot) { entry in
                    rawHIDChip(slot: entry.slot, gamepad: entry.gamepad)
                }
            }

            // The "● Active" status pill that used to live here was
            // redundant: the same state is already shown by the green
            // dot next to the active preset in the sidebar, by the
            // Deactivate button in the preset detail header, AND by
            // the menu bar icon's dropdown. Three indicators for the
            // same fact was visual noise.
        }
        .background(.clear)
    }

    /// Sorted (slot index, gamepad) pairs for the raw HID controllers
    /// rendered in the status bar. Stable ordering keeps the chip
    /// layout from jittering when the dictionary's hash order changes.
    private var rawHIDSortedSlots: [(slot: Int, gamepad: RawHIDGamepad)] {
        return controllerService.rawHIDGamepadSlots
            .map { (slot: $0.key, gamepad: $0.value) }
            .sorted { $0.slot < $1.slot }
    }

    @ViewBuilder
    private func rawHIDChip(slot: Int, gamepad: RawHIDGamepad) -> some View {
        let color = Self.controllerColors[slot % Self.controllerColors.count]
        HStack(spacing: 8) {
            ControllerGlyph(height: 11)
                .foregroundStyle(color)

            VStack(alignment: .leading, spacing: 0) {
                Text(gamepad.displayName)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text("Slot \(slot + 1)")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text("·")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text("Raw HID")
                        .font(.system(size: 9))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .foregroundStyle(.purple)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }

            Spacer()

            Text(gamepad.transport)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .padding(.trailing, 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func eightBitDoWarningBanner(_ device: EightBitDoDevice) -> some View {
        // If InputConfig's raw-HID layer is already reading this
        // controller directly, the warning is misleading - the device
        // is fully usable in its current mode. Suppress the banner.
        let isHandledByRawHID = controllerService.rawHIDGamepadSlots.values
            .contains { $0.vendorID == EightBitDoDetector.vendorID
                && $0.productID == device.productID }

        if !isHandledByRawHID {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text("8BitDo controller detected in \(device.mode.rawValue) mode")
                        .font(.caption)
                        .foregroundStyle(.primary)
                    Text(eightBitDoGuidance(for: device))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Help") {
                    HelpGuideWindowController.shared.show()
                }
                .buttonStyle(.solidSecondaryCompact)
                .controlSize(.mini)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08))
        }
    }

    /// Tailored mode-switch guidance per model. Some 8BitDo controllers
    /// have no physical mode switch and a few (e.g. Ultimate 2C wired)
    /// have no Apple mode at all, so the generic "flip to A on the back"
    /// instruction was misleading users into thinking the app was broken.
    private func eightBitDoGuidance(for device: EightBitDoDevice) -> String {
        let name = device.productName.lowercased()
        if name.contains("ultimate 2c") || name.contains("ultimate2c") {
            return "The Ultimate 2C wired model has no Apple mode. Hold Y while plugging in USB to switch to Switch mode (macOS reads this natively), or update InputConfig - the latest build reads this controller directly in any mode."
        }
        if name.contains("ultimate") {
            return "Set the back switch to A for Apple mode. If your model has no slider, hold B while turning on for Apple mode. Switch mode (S) also works on macOS Ventura+."
        }
        return "Switch to Apple mode (A on the back of the controller) for full Mac support. If your model has no slider, hold B while turning on."
    }

    /// The top-level folders of one sidebar list, each a collapsible
    /// section with the folder's outline, drag-reorderable within the list.
    @ViewBuilder
    private func topLevelFolders(_ folders: [PresetGroup], builtIn: Bool) -> some View {
        ForEach(folders) { group in
            // One outline per top-level folder, in the folder's own color,
            // around the header and everything under it. List rows are
            // separate cells, so each row draws its piece: the header the
            // top edge and corners, the rows below the sides, the last
            // visible row the bottom. Collapsed, the header draws the box.
            let outline = FolderOutlineContext(
                color: groupTintColor(for: group) ?? .secondary,
                lastRowID: lastVisibleRowID(in: group))
            let headerRole: FolderOutlineRole =
                outline.lastRowID == AnyHashable(group.id) ? .single : .top
            groupSection(group, depth: 0, outline: outline)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(group.id == flashingGroupID
                              ? Color.green.opacity(0.35)
                              : Color.clear)
                        .animation(.easeOut(duration: 0.9),
                                   value: flashingGroupID)
                )
                .listRowBackground(FolderOutlineSegment(role: headerRole, color: outline.color))
                // Pull the row's leading edge left so List's default sidebar
                // indent doesn't leave a fat empty gap to the left of the
                // disclosure chevron.
                .listRowInsets(EdgeInsets(top: 2, leading: -6,
                                          bottom: 2, trailing: 6))
        }
        .onMove { source, destination in
            withAnimation(.spring(response: 0.35)) {
                presetStore.moveTopLevelGroups(builtIn: builtIn, fromOffsets: source, toOffset: destination)
            }
        }
    }

    /// New Preset from the sidebar: create it, select it, open the editor.
    private func createNewPreset() {
        let preset = presetStore.createPreset()
        selectedPresetId = preset.id
        newlyCreatedPresetId = preset.id
        editingPreset = preset
    }

    private var bottomToolbar: some View {
        HStack(spacing: 10) {
            Menu {
                Button("New Preset") { createNewPreset() }
                Button("New Group…") {
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
            .accessibilityLabel("Add")
            .accessibilityHint("Add a new preset or group")

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
                .fixedSize()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Help")
            .accessibilityHint("Opens the in-app help guide")

            Link(destination: URL(string: "https://github.com/ryleighnewman/InputConfig")!) {
                Text("GitHub")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .accessibilityLabel("GitHub")
            .accessibilityHint("Opens the project's GitHub repository in your browser")

            Button {
                TipJarWindowController.shared.show()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "heart")
                        .font(.system(size: 11))
                    Text("Donate")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .fixedSize()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Donate to InputConfig")
            .accessibilityHint("Opens the tip jar")

            Spacer()

            Button {
                showingImportSheet = true
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .spotlightAnchor(SpotlightID.importButton)
            .accessibilityLabel("Import preset")
            .accessibilityHint("Pick a preset JSON file to add to the library")
        }
        // The three text links never wrap onto two lines in a narrow
        // sidebar; the spacers give way first.
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.clear)
        .fileImporter(
            isPresented: $showingImportSheet,
            allowedContentTypes: [.json, .plainText],
            allowsMultipleSelection: true
        ) { result in
            // Hand the URLs to the review sheet instead of importing
            // silently. The user gets a chance to rename or skip each
            // entry, and broken files are surfaced with a specific
            // error message instead of vanishing.
            if case .success(let urls) = result {
                presetStore.previewImports(from: urls)
            }
        }
        .sheet(isPresented: Binding(
            get: { !presetStore.importReviewQueue.isEmpty },
            set: { if !$0 { presetStore.cancelImportReview() } }
        )) {
            ImportReviewSheet()
                .environmentObject(presetStore)
                .glassBackground()
        }
    }

    // MARK: - Detail View

    @ViewBuilder
    private var detailView: some View {
        VStack(spacing: 0) {
            // The scrolling detail content gets the canonical header fade so it
            // dissolves into the window vibrancy under the transparent titlebar
            // instead of colliding with the toolbar. Applied once here so both
            // PresetDetailView and welcomeView inherit it; the developer log
            // below sits outside the faded region.
            Group {
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
                    // Key the detail view to the preset identity. Without this,
                    // switching presets reuses the same view instance and the
                    // editable title TextField animates/morphs from the old
                    // name to the new one - with .title2 that mid-flight
                    // reflow renders as a "downward distortion" of the title.
                    // A stable id gives each preset a fresh header instead.
                    .id(presetId)
                } else {
                    welcomeView
                }
            }
            .headerFade()

            // Developer log: on by default, at the bottom, with a Settings
            // switch for people who want the room.
            // Hidden on the home screen; every preset page carries it.
            if showDebugLog && selectedPresetId != nil {
                Divider()
                    .padding(.horizontal)
                DebugLogView(onHome: false)
                    .environmentObject(mappingEngine)
                    .environmentObject(controllerService)
                    .padding(.vertical, 8)
            }
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
                    ControllerGlyph(height: 42)
                        .foregroundStyle(.tertiary)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Welcome to InputConfig")
                            .font(.title2.weight(.semibold))
                        // Small grey version on the same line, which doubles
                        // as the release-notes button (same pattern as the
                        // sibling app's home header).
                        Button { showWelcomeChangelog = true } label: {
                            Text(Changelog.currentVersion)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("What's new in this version")
                        .accessibilityLabel("Version \(Changelog.currentVersion), what's new")
                        .popover(isPresented: $showWelcomeChangelog, arrowEdge: .bottom) {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 14) {
                                    Text("What's new").font(.headline)
                                    ForEach(Changelog.entries) { entry in
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(entry.version)
                                                .font(.subheadline.weight(.semibold))
                                            ForEach(entry.points, id: \.self) { point in
                                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                                    Text("\u{2022}").foregroundStyle(.secondary)
                                                    Text(point).font(.callout)
                                                        .fixedSize(horizontal: false, vertical: true)
                                                }
                                            }
                                        }
                                    }
                                }
                                .padding(16)
                                .frame(width: 380, alignment: .leading)
                            }
                            .frame(maxHeight: 460)
                        }
                    }
                    Text("Advanced Input Configuration")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 24)

                // Quick actions, in two rows: the two creation buttons on top,
                // the two help / onboarding buttons underneath.
                VStack(spacing: 10) {
                    // Row 1: create a preset, or build one with the wizard.
                    // Each row is a centerd flow, so a narrow window wraps
                    // its buttons onto another line instead of squeezing.
                    CenteredFlow(spacing: 10) {
                        Button {
                            let preset = presetStore.createPreset()
                            selectedPresetId = preset.id
                            // Mark this as freshly-created so an editor
                            // Cancel deletes the empty draft instead of
                            // leaving it lingering in the sidebar.
                            newlyCreatedPresetId = preset.id
                            editingPreset = preset
                        } label: {
                            Label("Create New Preset", systemImage: "plus")
                        }
                        .buttonStyle(.solid)
                        .spotlightAnchor(SpotlightID.createNew)

                        // Smart Preset Maker: guided wizard, as a quiet secondary
                        // capsule so it doesn't overpower the creation action.
                        Button {
                            showingSmartMaker = true
                        } label: {
                            Label("Smart Preset Maker", systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.solidSecondary)
                        .help("Answer a few quick questions and we'll build a tailored preset for your game, app, or workflow")
                    }

                    // Row 2: onboarding + docs, underneath the creation buttons.
                    CenteredFlow(spacing: 10) {
                        Button("Quick Start Guide") {
                            startTutorial()
                        }
                        // Sized to match the other welcome buttons. The hero
                        // glass CTA (GlassCTAButton) is reserved for standalone
                        // primary surfaces, not this grid of equal actions.
                        .buttonStyle(SolidButton(tint: .teal))
                        .help("Guided walkthrough of every major feature with click animations")

                        Button {
                            HelpGuideWindowController.shared.show()
                        } label: {
                            Label("Open Help Guide", systemImage: "questionmark.circle")
                        }
                        .buttonStyle(.solidSecondary)

                        Button {
                            settingsSheetTab = .about
                        } label: {
                            Label("About", systemImage: "info.circle")
                        }
                        .buttonStyle(.solidSecondary)
                        .help("The story behind InputConfig, the changelog, and ways to say hi")
                    }
                }

                // A literal horizontal bracket over the grid with its title
                // in the gap, grey like the caption text.
                BracketHeader(title: "Feature Showcases")
                    .padding(.top, 6)
                    .padding(.horizontal, 28)

                // Feature grid - each card opens an animated demo sheet
                // explaining the feature, with a button to jump to a matching
                // example preset. Four columns at the default window size; a
                // card never goes under 210 pt wide, so a narrower window or
                // a wider sidebar drops to three columns and the cards move
                // down instead of their text squeezing.
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 210), spacing: 12)],
                    spacing: 12
                ) {
                    demoCard(kind: .keyboardMouse,
                             icon: "keyboard",
                             detail: "Map any button, trigger, or stick to keyboard keys, mouse buttons, mouse motion, or scroll wheel.",
                             tint: .orange)
                    demoCard(kind: .controllers,
                             icon: "gamecontroller.fill",
                             detail: "DualSense, DualShock 4, Xbox, Switch Pro, Joy-Cons, Stadia, 8BitDo, and any MFi gamepad.",
                             tint: .cyan)
                    demoCard(kind: .chassisTap,
                             icon: "hand.tap.fill",
                             detail: "Knock on your MacBook. Two taps or three on the palm rest or lid fire any output, with no controller or cable needed.",
                             tint: .mint)
                    demoCard(kind: .midiInput,
                             icon: "pianokeys",
                             detail: "Use a MIDI keyboard or knob box as input, no controller needed. Knobs can switch, scroll with speed, nudge in steps, or work the Mac's volume like a fader.",
                             tint: .pink)
                    demoCard(kind: .midi,
                             icon: "music.note.list",
                             detail: "Send Note, CC, and Pitch Bend through a virtual MIDI port to GarageBand, Logic, Ableton, and more.",
                             tint: .pink)
                    demoCard(kind: .systemControl,
                             icon: "gearshape.2.fill",
                             detail: "Outputs can run the Mac itself: volume, mute, media keys, brightness, Mission Control, lock screen, Siri Shortcuts, open any app or URL.",
                             tint: .teal)
                    demoCard(kind: .siriShortcuts,
                             icon: "sparkles.rectangle.stack.fill",
                             detail: "Run any Siri Shortcut from any input: scenes, timers, Do Not Disturb, whole automations - one press, no focus stolen.",
                             tint: .indigo)
                    demoCard(kind: .inputRemap,
                             icon: "keyboard.badge.ellipsis",
                             detail: "The Mac's keyboard as an input: letters, both sides of every modifier, the top row's brightness, media, and volume keys, and F13 to F19, all live on a drawn keyboard.",
                             tint: .orange)
                    demoCard(kind: .macTrackpad,
                             icon: "rectangle.and.hand.point.up.left.fill",
                             detail: "Trackpad and Magic Mouse as inputs: clicks, side and middle buttons, scroll in four directions, double clicks, scroll gestures, and force click, all drawn live.",
                             tint: .mint)
                    demoCard(kind: .modifierHolds,
                             icon: "command",
                             detail: "Hold a modifier on its own to run the Mac. Command, Option, and Shift keep every shortcut; only a long hold or a double tap alone fires.",
                             tint: .indigo)
                    demoCard(kind: .variableSensitivity,
                             icon: "slider.horizontal.below.rectangle",
                             detail: "Joystick depth scales output speed. Pick linear, smooth, or aggressive curves per binding.",
                             tint: .blue)
                    demoCard(kind: .deadzone,
                             icon: "scope",
                             detail: "Live joystick visualizer with a draggable trail and slider to find the perfect deadzone.",
                             tint: .green)
                    demoCard(kind: .toggleMode,
                             icon: "switch.2",
                             detail: "Press once to latch on, press again to release. Sticky modifiers, push-to-talk, auto-run.",
                             tint: .orange)
                    demoCard(kind: .macros,
                             icon: "bolt.fill",
                             detail: "Chain keystrokes with custom timing, or rapid-fire any button at a configurable rate.",
                             tint: .yellow)
                    demoCard(kind: .stackedOutputs,
                             icon: "square.stack.3d.up.fill",
                             detail: "One press fires key + click + MIDI + speech in parallel. Different from a macro - all at once, not in sequence.",
                             tint: .blue)
                    demoCard(kind: .holdDoubleTap,
                             icon: "hand.tap.fill",
                             detail: "Press, hold, and double-tap each fire their own outputs. One button, three actions, adjustable timing.",
                             tint: .blue)
                    demoCard(kind: .appAutoSwitch,
                             icon: "app.connected.to.app.below.fill",
                             detail: "Presets activate themselves when their app comes to the front - the game preset in the game, the DAW preset in the DAW.",
                             tint: .green)
                    demoCard(kind: .autoLaunch,
                             icon: "app.badge.fill",
                             detail: "Per-preset Automation & Gaming Utilities: open an app on activate, confine the cursor, hide the system pointer.",
                             tint: .green)
                    demoCard(kind: .touchpad,
                             icon: "rectangle.and.hand.point.up.left.fill",
                             detail: "DualSense and DualShock 4 touchpad surfaces can drive the mouse cursor.",
                             tint: .mint)
                    demoCard(kind: .touchpadRegions,
                             icon: "rectangle.split.2x2.fill",
                             detail: "Carve the DualSense touchpad into zones that each fire their own binding, with a pulse when you hit one.",
                             tint: .orange)
                    demoCard(kind: .gyro,
                             icon: "gyroscope",
                             detail: "Tilt-to-aim with the controller's gyroscope. Works on DualSense, DualSense Edge, and DualShock 4.",
                             tint: .teal)
                    demoCard(kind: .cursorRegions,
                             icon: "rectangle.dashed",
                             detail: "Draw screen regions that act as inputs: the cursor entering one can press keys, run macros, or fire anything else.",
                             tint: .purple)
                    demoCard(kind: .haptic,
                             icon: "waveform",
                             detail: "Vibrate the controller when a binding fires. Works with DualSense, DualSense Edge, and similar.",
                             tint: .purple)
                    demoCard(kind: .speech,
                             icon: "speaker.wave.2.fill",
                             detail: "Speak a custom phrase on press through Mac speakers or the controller speaker.",
                             tint: .indigo)
                    demoCard(kind: .midiCC,
                             icon: "dial.high.fill",
                             detail: "Sticks and triggers send continuous MIDI Control Change values. Soft knobs for your DAW.",
                             tint: .purple)
                    demoCard(kind: .stats,
                             icon: "chart.bar.fill",
                             detail: "Lifetime counts of presses, motion, scrolls, and MIDI events with most-used inputs and presets. All local, no telemetry.",
                             tint: .brown)
                    demoCard(kind: .lightBar,
                             icon: "light.beacon.max.fill",
                             detail: "Pick a color with the picker, set brightness, or run an RGB cycle on DualSense controllers.",
                             tint: .red)
                }
                .padding(.horizontal, 28)

                QuickTipsPill()
                    .padding(.horizontal, 40)

                Text("Plug in a controller to get started. Open the Help menu for setup guides for every supported device.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                // Sister-app shoutout, anchoring the bottom of the homepage.
                // Mirrors the shoutout YapToText's About page gives
                // InputConfig, so the two apps point at each other.
                HStack(spacing: 14) {
                    Image("YapToTextIcon")
                        .resizable().scaledToFit()
                        .frame(width: 48, height: 48)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Like InputConfig? Try YapToText.")
                            .font(.callout.weight(.semibold))
                        Text("From the same developer: ultra-powerful dictation, processed entirely on your Mac, with advanced customization for exactly how you work. Free, private, and completely offline.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 10)
                    Link(destination: URL(string: "https://apps.apple.com/us/app/yaptotext/id6786382289?mt=12")!) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.forward.app")
                            Text("App Store")
                        }
                        .font(.callout)
                    }
                    .help("Opens YapToText on the Mac App Store. It's free.")
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.secondary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
                )
                .padding(.horizontal, 28)
                .padding(.bottom, 30)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Clickable feature card that opens the matching animated demo sheet.
    @ViewBuilder
    private func demoCard(kind: FeatureDemoKind, icon: String, detail: String, tint: Color) -> some View {
        FeatureCardButton(kind: kind, icon: icon, detail: detail, tint: tint,
                          isHighlighted: tutorialFeatureSpotlight == kind) {
            presentedDemoKind = kind
        }
        .modifier(ConditionalSpotlightAnchor(
            active: tutorialFeatureSpotlight == kind,
            id: SpotlightID.welcomeCard))
    }

    /// Stand-alone home-screen feature card with the same hover lift /
    /// tint / scale treatment the Statistics dashboard uses on its
    /// tiles. Lifted out of `demoCard` because tracking a hover state
    /// requires its own `@State`, and embedding @State inside a
    /// `@ViewBuilder func` doesn't compose well.
    private struct FeatureCardButton: View {
        @Environment(\.appReduceMotion) private var appReduceMotion
        let kind: FeatureDemoKind
        let icon: String
        let detail: String
        let tint: Color
        let isHighlighted: Bool
        let onTap: () -> Void
        @State private var hovering: Bool = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            // TimelineView gives us a continuous time stream so the
            // spotlight pulse actually loops while `isHighlighted` is
            // true. (`.animation(...repeatForever..., value:)` keyed
            // on a Bool only fires on the transition and doesn't
            // actually animate - SwiftUI sees no value change to
            // interpolate against, so the card just sat there.)
            // Reduce Motion pauses the timeline and pins the pulse at
            // fully highlighted instead of looping.
            TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                    paused: !isHighlighted || reduceMotion || appReduceMotion)) { context in
                let pulse: Double = {
                    guard isHighlighted else { return 0 }
                    if reduceMotion { return 1.0 }
                    return (sin(context.date.timeIntervalSinceReferenceDate * 2.4) + 1) / 2
                }()
                Button(action: onTap) {
                    cardLabel(pulse: pulse)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .onHover { hovering = $0 }
            }
        }

        @ViewBuilder
        private func cardLabel(pulse: Double) -> some View {
            // Pre-compute everything that depends on `pulse` so the
            // modifier chain sees plain Color / CGFloat / Double
            // values. Inline ternary arithmetic was timing out the
            // type-checker.
            let fillColor: Color = {
                if isHighlighted { return tint.opacity(0.18 + 0.18 * pulse) }
                if hovering { return tint.opacity(0.16) }
                return Color.clear
            }()
            let strokeColor: Color = {
                if isHighlighted { return tint.opacity(0.7 + 0.3 * pulse) }
                if hovering { return tint.opacity(0.55) }
                return Color.clear
            }()
            let strokeWidth: CGFloat = isHighlighted
                ? CGFloat(1.5 + pulse)
                : 1
            let shadowColor: Color = isHighlighted
                ? tint.opacity(0.3 + 0.5 * pulse)
                : Color.clear
            let shadowRadius: CGFloat = isHighlighted
                ? CGFloat(8.0 + 8.0 * pulse)
                : 0
            let scale: CGFloat = {
                if reduceMotion { return 1.0 }
                if isHighlighted { return CGFloat(1.0 + 0.05 * pulse) }
                if hovering { return 1.02 }
                return 1.0
            }()
            // Tint only lights up on hover or while the tour highlights
            // the card. At rest every tile's icon is neutral grey, so the
            // grid reads as one calm surface instead of a wall of color.
            let active: Bool = hovering || isHighlighted
            let iconColor: Color = active ? tint : Color.secondary.opacity(0.55)
            let chevronTint: Color = active ? tint : Color.secondary.opacity(0.45)
            return HStack(alignment: .top, spacing: 10) {
                IconView(name: icon, glyphHeight: 14)
                    .font(.system(size: 18))
                    .foregroundStyle(iconColor)
                    .frame(width: 24, height: 24)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(kind.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Image(systemName: "play.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(chevronTint)
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
                RoundedRectangle(cornerRadius: 10).fill(fillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(strokeColor, lineWidth: strokeWidth)
            )
            .shadow(color: shadowColor, radius: shadowRadius)
            .scaleEffect(scale)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
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
    /// Pulled out of the `.sheet(onDismiss:)` closure inline because
    /// stacking too many `.onChange` / `.onReceive` modifiers on the
    /// same view plus an inline multi-statement dismiss handler made
    /// SwiftUI's type-checker time out. As a plain method the body
    /// resolves instantly.
    private func handleEditorDismiss() {
        // If the user cancelled a newly created preset, delete it.
        // The hardDelete path skips trash so a "create + cancel"
        // cycle doesn't litter the Recently Deleted buffer with
        // empty drafts. The lookup is forgiving - if for any reason
        // the row is already gone we silently no-op instead of
        // crashing on a force-unwrap.
        if let newId = newlyCreatedPresetId {
            if let draft = presetStore.presets.first(where: { $0.id == newId }) {
                // Only discard PRISTINE drafts. If the user scanned or added
                // any bindings before pressing Escape, keep the preset;
                // hard-deleting it threw away real setup work.
                let isPristine = draft.joysticks.allSatisfy { $0.bindings.isEmpty }
                if isPristine {
                    presetStore.hardDeletePreset(draft)
                    if selectedPresetId == newId { selectedPresetId = nil }
                }
            } else if selectedPresetId == newId {
                selectedPresetId = nil
            }
            newlyCreatedPresetId = nil
        }
        // Resume outputs when the editor closes.
        mappingEngine.outputsPaused = false
        engineWasRunningBeforeEdit = false
        // Clear any pending jump so re-opening the editor doesn't reuse
        // a stale target.
        pendingEditorJump = nil
    }

    private func startTutorial() {
        // Make sure the welcome page is showing so the demo cards are
        // visible to spotlight.
        selectedPresetId = nil
        showingStats = false
        editingPreset = nil
        showingMotionCalibrationFromMenu = false
        showingTouchpadCalibrationFromMenu = false
        // Collapse the debug log so the welcome feature grid + Quick
        // Tour have full vertical room. The DebugLogView reads the
        // same @AppStorage key so this takes effect immediately.
        UserDefaults.standard.set(false, forKey: "InputConfig.debugLogExpanded")
        // Inject a synthetic DualSense Edge so all the visualizer
        // widgets (sticks / triggers / gyro / touchpad / paddles /
        // light bar) render during the tour even with no real
        // hardware plugged in. Cleaned up when the user finishes or
        // skips.
        controllerService.enableTutorialFakeController()
        tutorialState.start(steps: tutorialSteps)
    }

    /// Pick the first non-empty preset we can find. Used by the tutorial
    /// to land the user on something meaningful even if their first
    /// preset is empty.
    private func tutorialDemoPreset() -> Preset? {
        return presetStore.presets.first(where: { !$0.joysticks.isEmpty })
            ?? presetStore.presets.first
    }

    /// Pull the Minecraft seeded preset so the interactive walkthrough
    /// at the end of the tour has a concrete target. Falls back to any
    /// preset that mentions "Minecraft" in its name, then to the first
    /// non-empty preset, so the tour never dead-ends on a missing
    /// seed.
    private func tutorialMinecraftPreset() -> Preset? {
        if let p = presetStore.presets.first(where: { $0.name == "Minecraft" }) {
            return p
        }
        if let p = presetStore.presets.first(where: {
            $0.name.lowercased().contains("minecraft")
        }) {
            return p
        }
        return tutorialDemoPreset()
    }

    /// Tutorial helper: set the given preset's slot's inputKind via
    /// the store. Used by the Live Visualizer step to flip the demo
    /// preset's first slot into controller mode so the visualizer
    /// shows controller widgets even when no controller is connected.
    /// Idempotent - calling with the same kind a second time is a
    /// no-op write (still touches modifiedAt but harmless).
    fileprivate func tutorialSetSlotKind(presetID: UUID,
                                         slot: Int,
                                         kind: SlotInputKind) {
        guard var updated = presetStore.presets.first(where: { $0.id == presetID })
            else { return }
        while updated.joysticks.count <= slot {
            updated.joysticks.append(JoystickMapping(tag: ""))
        }
        updated.joysticks[slot].inputKind = kind
        updated.modifiedAt = Date()
        presetStore.savePreset(updated)
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
                title: "Welcome to InputConfig",
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
                body: "Below the toolbar is a grid of feature cards. Each opens a live animated demo and links to a working example preset. Watch the cursor land on the pulsing one.",
                spotlight: SpotlightID.welcomeCard,
                tip: "Click the highlighted card to open its full animated demo + jump to the matching example preset.",
                action: {
                    selectedPresetId = nil
                    editingPreset = nil
                    // Pulse the gyro card first, then send the
                    // simulated cursor to land on it so the user sees
                    // exactly which tile we mean.
                    tutorialFeatureSpotlight = .gyro
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        TutorialState.shared.simulateClickThen(
                            at: SpotlightID.welcomeCard
                        ) {
                            // Don't actually open the demo sheet -
                            // we're just visually pointing the user at
                            // the right card.
                        }
                    }
                }
            ),

            // ─── Open a preset and walk through the editor first ───

            TutorialStep(
                icon: "rectangle.fill.on.rectangle.fill",
                tint: .teal,
                title: "Preset detail page",
                body: "Watch the cursor glide to the sidebar and click a real preset. The detail page shows usage stats, controller capabilities, storage location, version history, an Activate button, and the Live Visualizer at the bottom.",
                spotlight: SpotlightID.sidebar,
                action: {
                    tutorialFeatureSpotlight = nil
                    TutorialState.shared.simulateClickThen(
                        at: SpotlightID.sidebar
                    ) {
                        if let p = tutorialDemoPreset() {
                            selectedPresetId = p.id
                        }
                    }
                }
            ),
            TutorialStep(
                icon: "slider.horizontal.3",
                tint: .indigo,
                title: "Edit the Preset",
                body: "Watch the cursor click the Edit button. The editor opens. Each row is one binding: Scan an input, then pick what it outputs (key, mouse, MIDI, macro, speech, more).",
                spotlight: SpotlightID.editButton,
                tip: "The engine pauses while the editor is open so scanning a key never fires it.",
                action: {
                    if let p = tutorialDemoPreset() {
                        selectedPresetId = p.id
                        TutorialState.shared.simulateClickThen(
                            at: SpotlightID.editButton
                        ) {
                            editingPreset = p
                        }
                    }
                }
            ),
            TutorialStep(
                icon: "bolt.fill",
                tint: .yellow,
                title: "Macros, turbo, and other Options",
                body: "Auto-expanding the first row's Options for you. Deadzone, Sensitivity, Variable Sensitivity, Toggle, Turbo, Macro chain, Spoken text, plus per-binding light and haptic overrides all live here.",
                demo: .macroChain,
                tip: "The same row supports stacked outputs. Click the + on the right to fire a key, click, and MIDI note from one press.",
                action: {
                    NotificationCenter.default.post(
                        name: .inputConfigScrollToFirstBinding, object: nil)
                    // After a brief pause for the scroll to land, ask
                    // the first row to expand its Options disclosure.
                    // It uses its own internal @State so this is the
                    // only way to drive it from outside.
                    if let firstID = tutorialDemoPreset()?
                        .joysticks.first?.bindings.first?.id {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                            NotificationCenter.default.post(
                                name: .inputConfigExpandBindingOptions,
                                object: firstID)
                        }
                    }
                }
            ),
            TutorialStep(
                icon: "tray.and.arrow.down.fill",
                tint: .blue,
                title: "Save, then close",
                body: "The Save and Cancel buttons sit at the bottom right of the editor sheet. Watch the cursor land on Save. The Modified timestamp updates the moment it fires. Then the cursor moves to Cancel.",
                spotlight: SpotlightID.editorSave,
                tip: "Cancel on a freshly-created preset hard-deletes it, with no Recently Deleted entry.",
                action: {
                    // Sequence: cursor to Save → 1.4s pause → cursor
                    // to Cancel → 0.6s pause → actually dismiss the
                    // editor. The user sees three discrete beats so
                    // each "click" registers.
                    TutorialState.shared.simulateClickThen(
                        at: SpotlightID.editorSave
                    ) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            TutorialState.shared.simulateClickThen(
                                at: SpotlightID.editorCancel
                            ) {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                    withAnimation { editingPreset = nil }
                                }
                            }
                        }
                    }
                }
            ),
            TutorialStep(
                icon: "play.fill",
                tint: .green,
                title: "Activate the preset",
                body: "Watch the cursor click the green Activate button. The engine starts. The light bar switches to this preset's color. Cursor utilities (confine, auto-recenter, hide) and the auto-launch app from Automation & Gaming Utilities all kick in. Click again to stop.",
                spotlight: SpotlightID.activateButton,
                tip: "Click the green dot in the sidebar next to a preset to toggle activation without opening the detail page.",
                action: {
                    editingPreset = nil
                    // Brief beat after the editor closes (previous step
                    // may have just dismissed it) before the cursor
                    // flies over.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        TutorialState.shared.simulateClickThen(
                            at: SpotlightID.activateButton
                        ) {
                            // Don't actually toggle - just point the
                            // user at the button. They activate when
                            // ready themselves.
                        }
                    }
                }
            ),

            // ─── Now show the Live Visualizer and its features ─────

            TutorialStep(
                icon: "gamecontroller.fill",
                tint: .teal,
                title: "Live Visualizer",
                body: "Scrolling you down to the Live Visualizer. It mirrors your physical controller in real time. Press a button, move a stick, or tilt the gyro and everything shows up here. Click any widget to inspect what it's bound to.",
                spotlight: SpotlightID.visualizer,
                demo: .buttonMapping,
                tip: "Use the +/- zoom slider in the visualizer header to resize the panel.",
                action: {
                    editingPreset = nil
                    // Auto-scroll the detail panel to the visualizer
                    // section. PresetDetailView listens for this and
                    // also expands the DisclosureGroup.
                    NotificationCenter.default.post(
                        name: .inputConfigScrollToVisualizer, object: nil)
                }
            ),
            TutorialStep(
                icon: "rectangle.3.group",
                tint: .blue,
                title: "Template picker, controller mode",
                body: "The visualizer can swap between controller widgets, a full macOS keyboard map, or a mouse diagram. I'm temporarily forcing the controller template here so you can see all the gamepad-specific widgets even without one connected.",
                spotlight: SpotlightID.templatePicker,
                tip: "Set per-slot from the editor too; the picker is a quick-switch at the visualizer level.",
                action: {
                    // Force controller layout on the demo preset's
                    // first slot so the next several steps have widgets
                    // to point at.
                    if let p = tutorialDemoPreset() {
                        tutorialSetSlotKind(presetID: p.id, slot: 0, kind: .controller)
                    }
                }
            ),
            TutorialStep(
                icon: "dot.circle.and.hand.point.up.left.fill",
                tint: .blue,
                title: "Analog sticks, click them in the visualizer",
                body: "The two stick widgets in the controller layout you can see now report continuous -1 to +1 values per axis, perfect for cursor speed, scroll speed, or anything proportional. Click a stick widget in the visualizer for the bound bindings + a jump-to-editor button.",
                demo: .analogStick,
                tip: "Pick from Linear, Smooth, or Aggressive curves in the editor's Advanced section."
            ),
            TutorialStep(
                icon: "arrow.up.and.down.text.horizontal",
                tint: .orange,
                title: "Triggers, pressure sensitive",
                body: "Trigger widgets show analog magnitude with the orange tick marking the binding's deadzone threshold. Click a trigger widget for its bindings popover. Use Variable Sensitivity in the editor to scale output speed by how hard you press.",
                demo: .pressureTrigger
            ),
            TutorialStep(
                icon: "gyroscope",
                tint: .purple,
                title: "Gyroscope motion",
                body: "Controllers with motion sensors (DualSense, DualShock 4, Switch Pro, Joy-Con) expose gyro + accelerometer data. The motion widget shows the controller orientation; clicking it offers Reset gyroscope to re-zero drift without leaving the visualizer.",
                demo: .gyro,
                tip: "Run Calibrate Motion once per controller so drift is corrected from the start."
            ),
            TutorialStep(
                icon: "pencil.and.outline",
                tint: .blue,
                title: "Edit Layout",
                body: "Watch the cursor click Edit Layout. The visualizer flips into 'blueprint mode' with a faint grid and a dashed yellow outline around every widget. Drag any widget to rearrange it.",
                spotlight: SpotlightID.customizeButton,
                tip: "Click Reset (in edit mode) to put every widget back where it started.",
                action: {
                    TutorialState.shared.simulateClickThen(
                        at: SpotlightID.customizeButton
                    ) {
                        // No-op - the user can toggle it themselves
                        // when they want to actually drag widgets.
                    }
                }
            ),
            TutorialStep(
                icon: "light.beacon.max.fill",
                tint: .pink,
                title: "Per-preset light bar",
                body: "DualSense and DualShock 4 have a light bar. The strip across the top of the visualizer lets you pick a color that's applied automatically while this preset is active. Click it to open the color picker. Deactivating the preset reverts the light.",
                spotlight: SpotlightID.lightBarStrip,
                demo: .lightBar
            ),
            TutorialStep(
                icon: "note.text",
                tint: .yellow,
                title: "Per-preset notes",
                body: "Below the visualizer is a free-form notes field. Use it to remember which game this preset is for, gotchas, control schemes, anything. Markdown isn't supported; plain text only.",
                spotlight: SpotlightID.notesSection
            ),
            TutorialStep(
                icon: "gyroscope",
                tint: .purple,
                title: "Calibrate Motion / Gyro",
                body: "Reach Calibrate Motion from the Controller menu (top of the screen). Place the controller flat, click Start Calibration, hold still for 2 s. Run once per controller; the recorded zero is per-device.",
                action: {
                    editingPreset = nil
                    showingTouchpadCalibrationFromMenu = false
                    // Brief beat so a previously-open sheet has time to
                    // dismiss before we present the next one - otherwise
                    // SwiftUI quietly skips the second presentation.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showingMotionCalibrationFromMenu = true
                    }
                }
            ),
            TutorialStep(
                icon: "rectangle.and.hand.point.up.left.fill",
                tint: .mint,
                title: "Calibrate Touchpad",
                body: "Touchpad Setup opens with a device picker at the top: DualSense, DualShock 4, or Mac Trackpad. Pick one, then sweep the surface to calibrate, or jump to Regions to define tap zones bound to keys.",
                action: {
                    showingMotionCalibrationFromMenu = false
                    // Brief delay so the previous sheet visibly closes
                    // before we open the next one - otherwise it looks
                    // like the same sheet just changed contents.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showingTouchpadCalibrationFromMenu = true
                    }
                }
            ),
            TutorialStep(
                icon: "chart.line.uptrend.xyaxis",
                tint: .purple,
                title: "Lifetime statistics",
                body: "The chart icon at the top of the window opens Statistics: lifetime usage, time connected, button presses, mouse pixels, top presets, and more. Click any tile for a detailed breakdown.",
                spotlight: SpotlightID.statsButton,
                spotlightShape: .circle,
                tip: "All stats are stored locally. Nothing leaves your Mac.",
                action: {
                    showingMotionCalibrationFromMenu = false
                    showingTouchpadCalibrationFromMenu = false
                    editingPreset = nil
                    TutorialState.shared.simulateClickThen(
                        at: SpotlightID.statsButton
                    ) {
                        showingStats = true
                    }
                }
            ),
            TutorialStep(
                icon: "gear",
                tint: .gray,
                title: "Settings & backup",
                body: "The gear icon opens Settings with Launch-at-Login, controller diagnostics, About, a Gaming Utilities panel, full Export Backup / Restore from Backup, and the App Store / open-source links. Cursor flies to the gear so you see where it is.",
                spotlight: SpotlightID.settingsButton,
                spotlightShape: .circle,
                action: {
                    showingMotionCalibrationFromMenu = false
                    showingTouchpadCalibrationFromMenu = false
                    editingPreset = nil
                    showingStats = false
                    TutorialState.shared.simulateClickThen(
                        at: SpotlightID.settingsButton
                    ) {
                        settingsSheetTab = .general
                    }
                }
            ),
            TutorialStep(
                icon: "questionmark.circle.fill",
                tint: .cyan,
                title: "Help guides",
                body: "Dismissing Settings for you. The Help menu (\u{2318}?) opens an in-app guide with deeper docs on every feature, plus a separate Test Bench. The Quick Start Tour itself is in there too if you ever want to repeat it.",
                action: {
                    showingMotionCalibrationFromMenu = false
                    showingTouchpadCalibrationFromMenu = false
                    editingPreset = nil
                    // The previous Settings step left the sheet open;
                    // close it before the Help menu reference makes
                    // sense to the user.
                    settingsSheetTab = nil
                    showingStats = false
                }
            ),
            TutorialStep(
                icon: "tray.and.arrow.down",
                tint: .blue,
                title: "Importing other presets",
                body: "Use the download icon at the bottom right of the sidebar to import preset JSON files. The Import Review sheet previews each file with a rename field, parse-error messages, and per-row skip. Nothing lands without confirmation.",
                spotlight: SpotlightID.importButton,
                tip: "Drag preset JSONs straight onto the icon to import them too.",
                action: {
                    settingsSheetTab = nil
                    showingStats = false
                }
            ),

            // ─── Interactive Minecraft walkthrough ─────────────────
            // From here on the tour stops *explaining* the app in
            // abstract terms and starts driving it. Each action()
            // closure mutates ContentView's @State so the user sees
            // the real UI respond - sidebar selection, editor sheet
            // opening, scrolling to specific binding rows, expanding
            // their Options disclosure - exactly what they would do
            // themselves when building a Minecraft preset from scratch.

            TutorialStep(
                icon: "cube.fill",
                tint: .green,
                title: "Hands-on: build a Minecraft preset",
                body: "Now the focused part. Instead of repeating things you already saw, we'll dig into the two trickiest parts of any preset: SCANNING a binding (recording a controller input) and BUILDING a MACRO (chaining keystrokes off one button). Both happen inside the editor for the Minecraft preset.",
                action: {
                    selectedPresetId = nil
                    editingPreset = nil
                    settingsSheetTab = nil
                    showingStats = false
                }
            ),
            TutorialStep(
                icon: "list.bullet.rectangle.portrait",
                tint: .teal,
                title: "Select the Minecraft preset",
                body: "Cursor goes to the sidebar, clicks Minecraft. The detail page loads with its 24 bindings, the DualSense Edge in the slot (synthetic for this tour), and the Minecraft automation rules already wired up.",
                spotlight: SpotlightID.sidebar,
                action: {
                    editingPreset = nil
                    TutorialState.shared.simulateClickThen(
                        at: SpotlightID.sidebar
                    ) {
                        if let mc = tutorialMinecraftPreset() {
                            selectedPresetId = mc.id
                            NotificationCenter.default.post(
                                name: .inputConfigScrollToPreset,
                                object: mc.id)
                        }
                    }
                }
            ),
            TutorialStep(
                icon: "slider.horizontal.3",
                tint: .orange,
                title: "Open the editor",
                body: "Cursor clicks Edit. The binding editor slides up over the detail page. The engine outputs pause automatically, so scanning a key here records it as a binding instead of firing a real keystroke.",
                spotlight: SpotlightID.editButton,
                action: {
                    if let mc = tutorialMinecraftPreset() {
                        selectedPresetId = mc.id
                        TutorialState.shared.simulateClickThen(
                            at: SpotlightID.editButton
                        ) {
                            editingPreset = mc
                        }
                    }
                }
            ),
            TutorialStep(
                icon: "rectangle.dashed",
                tint: .indigo,
                title: "Anatomy of a binding row",
                body: "Each row is one binding. Left to right: drag handle, Scan, Input Type, Input Index, Direction, then the arrow, then Output Type and Value, plus the add, duplicate, and delete cluster.",
                action: {
                    NotificationCenter.default.post(
                        name: .inputConfigScrollToFirstBinding, object: nil)
                }
            ),
            TutorialStep(
                icon: "dot.scope",
                tint: .red,
                title: "Scanning: record a binding from your controller",
                body: "Click Scan on a row. It glows for 5 seconds. Press the button, move the stick, or tilt the gyro you want to bind. The row fills in. Same scan works with external keyboards and mice.",
                tip: "Hold Shift or Cmd while scanning to add that modifier to the recorded input."
            ),
            TutorialStep(
                icon: "bolt.fill",
                tint: .yellow,
                title: "Macros: chain keystrokes off one button",
                body: "Auto-expanding the first row's Options again. Toggle Macro on to reveal a steps editor. Each step is one event plus an optional delay. The whole chain fires on press.",
                tip: "Combine Macro with a Toggle binding to flip a series on or off with one button.",
                action: {
                    NotificationCenter.default.post(
                        name: .inputConfigScrollToFirstBinding, object: nil)
                    if let firstID = tutorialMinecraftPreset()?
                        .joysticks.first?.bindings.first?.id {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                            NotificationCenter.default.post(
                                name: .inputConfigExpandBindingOptions,
                                object: firstID)
                        }
                    }
                }
            ),
            TutorialStep(
                icon: "plus.circle.fill",
                tint: .green,
                title: "Stacked outputs: one press, many actions",
                body: "The small + at the right of every binding row adds another output to the same input. One press can fire a key, a click, a MIDI note, and a spoken phrase together with independent per-output settings.",
                tip: "Use the X next to each output to delete it without touching the rest of the stack."
            ),
            TutorialStep(
                icon: "slider.horizontal.3",
                tint: .gray,
                title: "Automation & Gaming Utilities: per-preset side effects",
                body: "Scrolling down to Automation & Gaming Utilities. Fill in a launch path to auto-open the app on activate. Confine, auto-recenter, and Hide cursor toggles apply only while this preset is active.",
                action: {
                    NotificationCenter.default.post(
                        name: .inputConfigScrollToAutomation, object: nil)
                }
            ),
            TutorialStep(
                icon: "tray.and.arrow.down.fill",
                tint: .blue,
                title: "Save the Minecraft preset",
                body: "Cursor flies to Save (bottom right of the editor toolbar), then to Cancel, then the editor slides closed. Modified time updates, and the new bindings are on disk.",
                spotlight: SpotlightID.editorSave,
                action: {
                    TutorialState.shared.simulateClickThen(
                        at: SpotlightID.editorSave
                    ) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                            TutorialState.shared.simulateClickThen(
                                at: SpotlightID.editorCancel
                            ) {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                    withAnimation { editingPreset = nil }
                                }
                            }
                        }
                    }
                }
            ),
            TutorialStep(
                icon: "play.circle.fill",
                tint: .green,
                title: "Activate Minecraft mode",
                body: "Scrolling back up to the Activate button. Click it for real to start the engine, launch Minecraft, hide the cursor, and turn the lightbar green.",
                spotlight: SpotlightID.activateButton,
                tip: "Cmd-click the green dot in the sidebar to toggle activation without leaving the home screen.",
                action: {
                    NotificationCenter.default.post(
                        name: .inputConfigScrollToTop, object: nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        TutorialState.shared.simulateClickThen(
                            at: SpotlightID.activateButton
                        ) {
                            // No-op - user activates when they're ready
                            // to launch Minecraft.
                        }
                    }
                }
            ),

            // ─── Wrap-up ───────────────────────────────────────────

            TutorialStep(
                icon: "books.vertical.fill",
                tint: .orange,
                title: "Browse the example library",
                body: "Back on the home screen. The feature card grid is also a library. Every card opens an animated demo and links to a working example preset you can copy.",
                tip: "Each example preset is editable. Duplicate one as a starting point for your own.",
                action: {
                    selectedPresetId = nil
                    editingPreset = nil
                    showingStats = false
                    settingsSheetTab = nil
                    tutorialFeatureSpotlight = nil
                }
            ),
            TutorialStep(
                icon: "checkmark.circle.fill",
                tint: .green,
                title: "You're all set",
                body: "That's the full tour. You can now scan a binding, chain a macro, stack outputs, and set automation. Re-run any time from the Quick Start Guide button.",
                action: {
                    selectedPresetId = nil
                    editingPreset = nil
                }
            )
        ]
    }

    /// Actually delete the queued preset. The store moves it to the
    /// on-disk trash where the sidebar's Trash section can restore it
    /// at any time.
    private func performPendingDelete() {
        guard let preset = presetPendingDelete else { return }
        if selectedPresetId == preset.id { selectedPresetId = nil }
        // Stop the mapping engine BEFORE removing the preset. Earlier
        // versions called deletePreset → deactivateAll, which only
        // cleared the active flag but left the engine polling the now-
        // deleted preset, firing ghost outputs until the user stopped
        // it manually.
        if preset.isActive {
            mappingEngine.stop()
        }
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
        // The calibration gate is gone: the gyro zero learns itself while
        // the controller rests and pitch and roll are anchored to the
        // accelerometer, and a DualSense or DualShock touchpad read through
        // the GameController framework already spans the whole pad. The
        // alert it raised on every activation of a motion or touchpad preset
        // read as "the preset does not work". Calibration stays available in
        // each row's Options for the raw HID path and for people who want it.
        _ = calibrationRequirements(for: preset)
        startEngine(with: preset)
    }

    private func startEngine(with preset: Preset) {
        // An empty preset cannot do anything; activating it would show the
        // green active state over an engine with nothing to run.
        guard preset.joysticks.contains(where: { !$0.bindings.isEmpty }) else { return }
        mappingEngine.stop()
        presetStore.activatePreset(preset)
        mappingEngine.start(with: preset)
        // A preset that emits keyboard/mouse output needs Accessibility for
        // that output to reach other apps. If it isn't granted yet, prompt
        // the user the moment they activate such a preset.
        accessibility.refresh()
        if !accessibility.isTrusted, presetUsesKeyboardOrMouse(preset) {
            showAccessibilityAlert = true
        }
    }

    /// True if any binding in the preset outputs a keyboard or mouse action -
    /// the outputs that require Accessibility. MIDI, haptics, and speech do not.
    private func presetUsesKeyboardOrMouse(_ preset: Preset) -> Bool {
        for joystick in preset.joysticks {
            for binding in joystick.bindings {
                for output in binding.outputs {
                    switch output.type {
                    case .key, .mouseButton, .mouseMotion, .mouseWheel, .mouseWheelStep:
                        return true
                    default:
                        continue
                    }
                }
            }
        }
        return false
    }

    /// The currently-active preset, if any.
    private var runningPreset: Preset? {
        presetStore.presets.first(where: { $0.isActive })
    }

    /// Reassuring, proactive Accessibility explainer shown on launch when the
    /// permission isn't granted. Spells out exactly why the app needs it, that
    /// the use is Apple-approved for accessibility, and that nothing leaves the
    /// Mac, so people feel safe granting it and their mappings actually work.
    @ViewBuilder
    private var accessibilityIntroSheet: some View {
        VStack(spacing: 16) {
            Image(systemName: "accessibility")
                .font(.system(size: 46, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: 84, height: 84)
                .background(
                    Circle().fill(
                        LinearGradient(colors: [.blue, .indigo],
                                       startPoint: .top, endPoint: .bottom)
                    )
                )
                .padding(.top, 6)

            Text(accessibility.isTrusted ? "Accessibility Is On" : "Turn On Accessibility")
                .font(.title2.weight(.bold))

            Text("InputConfig uses macOS Accessibility to deliver the keyboard and mouse actions your controller is mapped to. This access has been approved by Apple for accessibility purposes and will allow additional functionality in the app. Your inputs stay on your Mac and are never sent anywhere.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if accessibility.isTrusted {
                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text("Granted. Every mapping can run.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("System Settings, Privacy & Security, Accessibility, then switch on InputConfig.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                if accessibility.isTrusted {
                    Button {
                        showingAccessibilityIntro = false
                    } label: {
                        Text("Done").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.solid)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button {
                        // requestAccess registers the app's row in the
                        // Accessibility pane and shows the system prompt.
                        // Only opening the pane landed users in a list with
                        // no InputConfig row to turn on. The sheet stays up
                        // and flips to Done the moment the switch is on.
                        accessibility.requestAccess()
                    } label: {
                        Text("Turn On Accessibility")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.solid)
                    .focusEffectDisabled()

                    // The two helpers for when the switch will not stick:
                    // reveal this copy of the app (wherever this build
                    // lives) to drag into the list, and re-read the state.
                    HStack(spacing: 8) {
                        Button {
                            accessibility.revealAppInFinder()
                        } label: {
                            Label("Show in Finder", systemImage: "folder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.solidSecondary)
                        .help("Reveals the app so you can drag it into the Accessibility list")
                        Button {
                            accessibility.refresh()
                        } label: {
                            Label("Recheck", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.solidSecondary)
                        .help("Re-read the permission after switching it on")
                    }

                    Button("Maybe Later") { showingAccessibilityIntro = false }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 2)

            if !accessibility.isTrusted {
                Text("If the switch does not stick, press Show in Finder and drag InputConfig from the Finder window into the Accessibility list in System Settings, then switch it on there.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .padding(28)
        .frame(width: 430)
    }

    /// First launch only: what the app is for and who made it, before the
    /// permission ask.
    private var welcomeIntroSheet: some View {
        VStack(spacing: 16) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)
                    .padding(.top, 4)
            }

            Text("Welcome to InputConfig")
                .font(.title2.weight(.bold))

            VStack(spacing: 10) {
                Text("InputConfig exists to be a powerful accessibility tool, made for the people who need it most. The idea is simple: any input can become any output.")
                Text("It was built by somebody who needed it, and it is in active development. If you ever need anything, or if something does not work, please reach out on GitHub or through the website so that it can be fixed. Here for you! :)")
                HStack(spacing: 14) {
                    Button {
                        HelpGuideWindowController.shared.show()
                    } label: {
                        Label("Help", systemImage: "questionmark.circle")
                    }
                    Link(destination: URL(string: "https://github.com/ryleighnewman/InputConfig/issues")!) {
                        Label("GitHub", systemImage: "ladybug")
                    }
                    Link(destination: URL(string: "https://inputconfig.com/help/")!) {
                        Label("inputconfig.com", systemImage: "safari")
                    }
                }
                .font(.callout)
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .foregroundStyle(Color.accentColor)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            Button {
                welcomeIntroSeen = true
                showingWelcomeIntro = false
                // Then the permission, if it is still needed.
                if !accessibility.isTrusted && !suppressAccessibilityIntro {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        showingAccessibilityIntro = true
                    }
                }
            } label: {
                Text("Let's Get Started").frame(maxWidth: .infinity)
            }
            .buttonStyle(.solid)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 430)
    }

    /// Top-of-window banner shown while a keyboard/mouse preset is active but
    /// Accessibility hasn't been granted, so the user sees why their mappings
    /// aren't landing and can fix it in one click. Collapses to nothing
    /// otherwise (zero-height safe-area inset).
    @ViewBuilder
    private var accessibilityBanner: some View {
        if !accessibility.isTrusted,
           let active = runningPreset, presetUsesKeyboardOrMouse(active) {
            HStack(spacing: 10) {
                Image(systemName: "accessibility")
                VStack(alignment: .leading, spacing: 1) {
                    Text("Accessibility access needed")
                        .font(.caption.weight(.semibold))
                    Text("Turn on InputConfig in Privacy & Security → Accessibility to send keyboard & mouse input.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.92))
                }
                Spacer(minLength: 8)
                Button("Open Settings") { accessibility.openSystemSettings() }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.white))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.orange)
        }
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

        // Touchpad: needs calibration only for the raw HID feed; the
        // GameController feed reports the whole pad already.
        let touchpadUncalibrated = usesTouchpad
            && !TouchpadService.shared.currentCalibration().isUserCalibrated
            && !TouchpadService.shared.isFedByGameController

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
        let presetsDir = appSupport.appendingPathComponent("InputConfig/presets")
        let filePath = presetsDir.appendingPathComponent(preset.filename).path
        NSWorkspace.shared.selectFile(filePath, inFileViewerRootedAtPath: "")
    }

    private func sharePreset(_ preset: Preset) {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let presetsDir = appSupport.appendingPathComponent("InputConfig/presets")
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
    /// Optional so the marketing capture pipeline can render a chip for a
    /// synthetic controller, which has no GCController behind it. Everything
    /// the chip draws comes from `info`; the controller is only consulted for
    /// its vendor name.
    let controller: GCController?
    let index: Int
    let color: Color
    let info: ControllerInfo?
    let onSetLight: (Float, Float, Float) -> Void
    let onSetBrightness: (UInt8) -> Void
    let onToggleRGB: () -> Void
    let isRGBActive: Bool
    let onRefresh: () -> Void
    /// Jump to the example preset that best matches this controller.
    let onOpenExample: () -> Void
    /// Live binding to the shared RGB cycle speed (the slider in the menu).
    @Binding var rgbSpeed: Double

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
            ControllerGlyph(height: 11)
                .foregroundStyle(color)

            VStack(alignment: .leading, spacing: 0) {
                Text(controller?.vendorName ?? info?.name ?? "Controller \(index)")
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
        .hoverFill(isHovering)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            showPopover.toggle()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(controller?.vendorName ?? info?.name ?? "Controller \(index)")
        .accessibilityValue(chipAccessibilityValue)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens controller light and settings")
        .popover(isPresented: $showPopover, arrowEdge: .trailing) {
            controllerPopover
        }
    }

    /// Battery and light status summarized for VoiceOver so the chip reads
    /// its full state without exposing the decorative indicators separately.
    private var chipAccessibilityValue: String {
        var parts: [String] = []
        if let info = info, info.hasBattery, let level = info.batteryLevel {
            parts.append("Battery \(Int(level * 100)) percent")
        }
        if info?.hasLight == true {
            parts.append("Light on")
        }
        return parts.joined(separator: ", ")
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
                ControllerGlyph(height: 16)
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller?.vendorName ?? info?.name ?? "Controller \(index)")
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

                // Every controller - including ones we don't recognize -
                // gets a one-tap jump to the example preset that best fits
                // it (unrecognized pads fall back to the DualSense layout).
                Button {
                    showPopover = false
                    onOpenExample()
                } label: {
                    Label("Take me to an example preset", systemImage: "sparkles")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.solidSecondaryCompact)
                .padding(.top, 2)
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
            .buttonStyle(.solidSecondaryCompact)
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
            detailRow("Brand", info.brand.manufacturer)
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
            Text("Light Bar")
                .font(.caption)
                .foregroundStyle(.secondary)

            // One grid of everything the light can be: the fixed colors,
            // a custom colour (the picker itself is the swatch, and applies
            // as soon as a colour is chosen), and Rainbow, which is the RGB
            // cycle. Picking any colour stops the cycle.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 8) {
                ForEach(Self.lightPresets, id: \.name) { preset in
                    let swatchColor = preset.name == "Off" ? Color.gray.opacity(0.3) :
                        Color(red: Double(preset.r), green: Double(preset.g), blue: Double(preset.b))
                    LightSwatchButton(
                        name: preset.name,
                        color: swatchColor,
                        action: {
                            if isRGBActive { onToggleRGB() }
                            onSetLight(preset.r, preset.g, preset.b)
                        }
                    )
                }
                // Custom: the color well is the swatch.
                VStack(spacing: 2) {
                    ColorPicker("", selection: $customColor, supportsOpacity: false)
                        .labelsHidden()
                        .scaleEffect(1.35)
                        .frame(width: 24, height: 24)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                        .shadow(color: customColor.opacity(0.3), radius: 2)
                        .accessibilityLabel("Custom light bar color")
                        .onChange(of: customColor) { _, value in
                            let nsColor = NSColor(value).usingColorSpace(.sRGB) ?? NSColor(value)
                            if isRGBActive { onToggleRGB() }
                            onSetLight(Float(nsColor.redComponent), Float(nsColor.greenComponent), Float(nsColor.blueComponent))
                        }
                    Text("Custom")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
                // Rainbow: the RGB cycle, as a swatch that stays lit while
                // it runs.
                Button {
                    onToggleRGB()
                } label: {
                    VStack(spacing: 2) {
                        Circle()
                            .fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                            .overlay(
                                Circle().strokeBorder(isRGBActive ? Color.white.opacity(0.9) : Color.primary.opacity(0.12),
                                                      lineWidth: isRGBActive ? 2 : 0.5)
                            )
                            .overlay(
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .opacity(isRGBActive ? 1 : 0)
                            )
                            .frame(width: 24, height: 24)
                            .shadow(color: .white.opacity(isRGBActive ? 0.5 : 0.2), radius: isRGBActive ? 4 : 2)
                        Text(isRGBActive ? "Stop" : "Rainbow")
                            .font(.system(size: 8))
                            .foregroundStyle(isRGBActive ? .secondary : .tertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isRGBActive ? "Stop RGB cycle" : "RGB cycle")
            }

            // Cycle speed, only while Rainbow is running.
            if isRGBActive {
                HStack(spacing: 8) {
                    Text("Speed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "tortoise")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Slider(value: $rgbSpeed, in: 0.25...6.0)
                        .accessibilityLabel("RGB cycle speed")
                        .accessibilityValue(String(format: "%.2f times normal", rgbSpeed))
                    Image(systemName: "hare")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            Divider()

            // Brightness control
            HStack(spacing: 8) {
                Text("Brightness")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                .accessibilityLabel("Light bar brightness")
                Image(systemName: "light.max")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .animation(.easeOut(duration: 0.18), value: isRGBActive)
    }
}

// MARK: - Light Swatch Button

private struct LightSwatchButton: View {
    let name: String
    let color: Color
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    .scaleEffect(!reduceMotion && isHovering ? 1.15 : 1.0)
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
    /// Every folder, as "Parent / Child" paths, for Move to Group.
    var groupChoices: [(id: UUID, path: String)] = []
    var currentGroupID: UUID? = nil
    var onMoveToGroup: (UUID?) -> Void = { _ in }
    var onNewGroup: () -> Void = { }

    /// Toggled when the user clicks the trailing ellipsis next to a
    /// truncated description. Collapses back when toggled off, the row is
    /// deselected, or another row is selected.
    @State private var descriptionExpanded: Bool = false

    /// Active state is normally conveyed only by the green row tint;
    /// with Differentiate Without Color on we add a glyph as well.
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    /// Whether the row should offer an expand toggle. We err on the side
    /// of showing it: any non-trivial tag (>= 16 chars, since sidebar
    /// width often clips around there) OR any notes content qualifies.
    /// 16 instead of 40 means narrow-sidebar users actually get the
    /// button when their text is in fact truncated.
    private var descriptionTruncates: Bool {
        preset.tag.count >= 16 || !preset.notes.isEmpty
    }

    var body: some View {
        // Single-line row: name on top, optional chevron beside the
        // truncated tag. Clicking the chevron pops up the full
        // description as a popover floating below the row. We use a
        // popover instead of inline expansion because List(.sidebar)
        // enforces a fixed row height that silently clips any
        // multi-line text - the popover floats outside the row
        // entirely and is guaranteed to show the full text.
        mainRow
    }

    /// Top half of the row: name, single-line description with the trailing
    /// ellipsis-toggle, then the trailing options Menu. Always the same
    /// height regardless of expansion.
    @ViewBuilder
    private var mainRow: some View {
        HStack(spacing: 6) {
            if preset.isActive && differentiateWithoutColor {
                Image(systemName: "play.fill")
                    .font(.caption2)
                    .iconTint(.green)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                    .font(.body)
                    .lineLimit(1)

                // Single-line tag preview. When it truncates, clicking it
                // (the ellipsis is the cue) floats the full description
                // below the row. A popover rather than growing the row:
                // List(.sidebar) clips multi-line rows.
                Text(preset.tag)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if descriptionTruncates { descriptionExpanded = true }
                    }
                    .popover(isPresented: $descriptionExpanded, arrowEdge: .bottom) {
                        descriptionPopover
                    }
                    .help(descriptionTruncates ? "Click to read the whole description" : "")
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(preset.isActive ? "Active" : "Inactive")
            .accessibilityAddTraits(preset.isActive ? [.isSelected] : [])
            .accessibilityAction(named: "Show full description") {
                if descriptionTruncates { descriptionExpanded = true }
            }

            Spacer(minLength: 4)

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

                Menu("Move to Group") {
                    ForEach(groupChoices, id: \.id) { choice in
                        Button {
                            onMoveToGroup(choice.id)
                        } label: {
                            if choice.id == currentGroupID {
                                Label(choice.path, systemImage: "checkmark")
                            } else {
                                Text(choice.path)
                            }
                        }
                        .disabled(choice.id == currentGroupID)
                    }
                    if !groupChoices.isEmpty { Divider() }
                    Button("New Group…") { onNewGroup() }
                    if currentGroupID != nil {
                        Button("Remove from Group") { onMoveToGroup(nil) }
                    }
                }

                Divider()

                Menu("Convert To…") {
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

                Button("Export…") {
                    onExport()
                }

                Button("Import Preset File…") {
                    onImport()
                }

                Divider()

                Button("Show in Finder") {
                    onShowInFinder()
                }

                Button("Share…") {
                    onShare()
                }

                Divider()

                Button("Delete", role: .destructive) {
                    onDelete()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12))
                    .foregroundColor(Color.gray.opacity(0.55))
                    .frame(width: 16, height: 22, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .frame(width: 16, alignment: .trailing)
            .accessibilityLabel("\(preset.name) options")
            .accessibilityHint("Activate, edit, duplicate, convert, share, or delete this preset")
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

            Menu("Convert To…") {
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

            Button("Export…") { onExport() }
            Button("Import Preset File…") { onImport() }

            Divider()

            Button("Show in Finder") { onShowInFinder() }
            Button("Share…") { onShare() }

            Divider()

            Button("Delete", role: .destructive) { onDelete() }
        }
    }

    /// Floating popover anchored to the chevron button. Renders OUTSIDE
    /// the List row container so the sidebar's fixed-row-height
    /// enforcement can't clip multi-line text. The popover has its
    /// own fixed width (280pt) and grows vertically with the content.
    @ViewBuilder
    private var descriptionPopover: some View {
        // Long notes scroll inside the popover instead of growing it past
        // the screen; the name and tag stay put above the scrolling part.
        VStack(alignment: .leading, spacing: 8) {
            Text(preset.name)
                .font(.headline)
            if !preset.tag.isEmpty {
                Text(preset.tag)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if !preset.notes.isEmpty {
                Divider()
                Text("Notes")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                ScrollView(.vertical) {
                    Text(preset.notes)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 6)
                }
                .frame(maxHeight: 360)
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
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

    // PresetDetailView does not read the mapping engine directly (the
    // visualizer it embeds gets the engine from a higher injection), so it
    // must NOT subscribe to it here: doing so rebuilt this whole detail body
    // at the engine's 10-30 Hz publish rate while a preset was active.
    @EnvironmentObject var controllerService: GameControllerService
    @EnvironmentObject var presetStore: PresetStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { detailProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Anchor for the Quick Tour's scroll-to-top.
                    Color.clear.frame(height: 0).id("detail-top")

                    // 1. Header (name, tag, Activate, Edit).
                    headerSection
                        .padding(.horizontal)
                        .padding(.top, 8)

                    // 2. Live Visualizer card.
                    // Tagged so the tour can scrollTo("visualizer-section")
                    // without having to fish through nested SwiftUI views.
                    Color.clear.frame(height: 0).id("visualizer-section")
                    visualizerCard
                        .padding(.horizontal)
                        .spotlightAnchor(SpotlightID.visualizer)

                    // 3. Joystick Slots card (mapping count + comment per
                    //    joystick group in the preset).
                    if !preset.joysticks.isEmpty {
                        joystickSlotsCard
                            .padding(.horizontal)
                    } else {
                        ContentUnavailableView {
                            Label { Text("No Input Mappings") } icon: { ControllerGlyph(height: 22) }
                        } description: {
                            Text("Edit this preset to add joystick mappings.")
                        }
                    }

                    // 4. Notes card. Personal context (which game, gotchas)
                    //    belongs right after the mappings, before the
                    //    technical file metadata below.
                    notesCard
                        .padding(.horizontal)
                        .spotlightAnchor(SpotlightID.notesSection)

                    // 5. Details card (Usage, Inputs, Outputs, Controllers,
                    //    Storage, version history).
                    detailsCard
                        .padding(.horizontal)
                }
                .padding(.vertical, 14)
            }
            .onReceive(NotificationCenter.default.publisher(
                for: .inputConfigScrollToVisualizer)) { _ in
                showVisualizer = true
                withAnimation(.easeOut(duration: 0.45)) {
                    detailProxy.scrollTo("visualizer-section", anchor: .top)
                }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: .inputConfigScrollToTop)) { _ in
                withAnimation(.easeOut(duration: 0.45)) {
                    detailProxy.scrollTo("detail-top", anchor: .top)
                }
            }
            } // ScrollViewReader

        }
        .navigationTitle(preset.name)
        .sheet(isPresented: $showingTouchpadCalFromDetail) {
            TouchpadCalibrationView()
                .environmentObject(presetStore)
                .glassBackground()
        }
        .sheet(isPresented: $showingMotionCalFromDetail) {
            MotionCalibrationView()
                .environmentObject(controllerService)
                .glassBackground()
        }
    }

    // MARK: - Section card helpers

    /// Wraps a section in a uniform Liquid Glass card. Used by every major
    /// section of the detail panel so they read as one related set and carry
    /// the same real glass as the rest of the app family (spec section 2).
    @ViewBuilder
    private func sectionCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            content()
        }
        .padding(Metrics.cardPad)
        .liquidGlass(in: RoundedRectangle(cornerRadius: Metrics.sectionRadius, style: .continuous))
    }

    /// Standard header row for a section card: tinted SF Symbol, title,
    /// optional trailing content (e.g. a chevron or status pill).
    @ViewBuilder
    private func sectionHeader<Trailing: View>(
        icon: String,
        title: String,
        tint: Color = .secondary,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        HStack(spacing: 6) {
            IconView(name: icon, glyphHeight: 12)
                .iconTint(tint)
                .font(.subheadline)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 4)
            trailing()
        }
    }

    // MARK: - Section: Header

    @ViewBuilder
    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Preset Name", text: $preset.name)
                    .font(.title2)
                    .fontWeight(.regular)
                    .textFieldStyle(.plain)
                    .lineLimit(1)
                TextField("Tag / Description", text: $preset.tag)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textFieldStyle(.plain)
                    .lineLimit(1)
            }
            Spacer()
            HStack(spacing: 8) {
                Button(action: onToggle) {
                    Label {
                        Text(preset.isActive ? "Deactivate" : "Activate")
                    } icon: {
                        // A filled triangle carries far more ink than the
                        // pencil beside it at the same point size, so it read
                        // as a bigger, heavier icon. Drawn a step smaller so
                        // the two buttons match.
                        Image(systemName: preset.isActive ? "stop.fill" : "play.fill")
                            .imageScale(.small)
                    }
                }
                .buttonStyle(SolidButton(tint: preset.isActive ? .red : .green))
                .spotlightAnchor(SpotlightID.activateButton)
                .accessibilityLabel(preset.isActive
                                    ? "Deactivate \(preset.name)"
                                    : "Activate \(preset.name)")
                .accessibilityHint(preset.isActive
                                   ? "Stops the mapping engine for this preset"
                                   : "Starts the mapping engine and applies this preset")

                Button(action: onEdit) {
                    Label("Edit", systemImage: "pencil")
                }
                .buttonStyle(.solidSecondary)
                .spotlightAnchor(SpotlightID.editButton)
                .accessibilityLabel("Edit bindings and mappings")
                .accessibilityHint("Opens the binding editor for this preset")
            }
        }
        .spotlightAnchor(SpotlightID.detailHeader)
    }

    // MARK: - Section: Live Visualizer card

    @ViewBuilder
    private var visualizerCard: some View {
        let slots = visualizerSlots
        sectionCard {
            // One row: title, the device chip when there is a single
            // visualizer, then its Edit Layout and zoom, then the chevron.
            // With several visualizers each gets its own chip row below.
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showVisualizer.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        IconView(name: "gamecontroller", glyphHeight: 12)
                            .iconTint(.teal)
                            .font(.subheadline)
                        Text("Live Visualizer")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showVisualizer
                                    ? "Collapse Live Visualizer"
                                    : "Expand Live Visualizer")

                if slots.count == 1, let only = slots.first {
                    visualizerDeviceChip(only)
                }
                Spacer(minLength: 4)
                if showVisualizer, slots.count == 1, let only = slots.first {
                    VisualizerHeaderControls(control: visualizerControl(for: only.slot))
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showVisualizer.toggle() }
                } label: {
                    Image(systemName: showVisualizer ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            }

            if showVisualizer {
                visualizerContent
            }
        }
    }

    /// True when the slot's template is the screen, chosen or inferred:
    /// every row is a screen region.
    private func slotShowsScreen(_ slot: Int) -> Bool {
        guard slot < preset.joysticks.count else { return false }
        let group = preset.joysticks[slot]
        if group.inputKind == .screen { return true }
        guard !group.bindings.isEmpty else { return false }
        return group.bindings.allSatisfy { $0.input.type == .cursorRegion }
    }

    /// "Input Device n", the controller's name, and its connection dot.
    private func visualizerDeviceChip(_ viz: VisualizerSlot) -> some View {
        HStack(spacing: 6) {
            Text("Input Device \(viz.idx)")
                .font(.caption2.weight(.semibold).monospaced())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
            if slotShowsScreen(viz.slot) {
                // The slot's input is a display, not a controller: naming
                // the controller here, with a connection dot, said the
                // screen regions belonged to it.
                Label("Screen", systemImage: "display")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let connected = controllerService.controllerDetails[viz.slot] != nil
                Text(connected ? controllerService.controllerName(at: viz.slot) : "No controller")
                    .font(.caption)
                    .foregroundStyle(connected ? .secondary : .tertiary)
                    .lineLimit(1)
                Circle()
                    .fill(connected ? Color.green : Color.red.opacity(0.7))
                    .frame(width: 7, height: 7)
                    .accessibilityLabel(connected ? "Connected" : "Disconnected")
            }
        }
    }

    /// One control state per visualizer slot, kept for the life of the
    /// detail view so Edit Layout and the zoom survive re-renders.
    private func visualizerControl(for slot: Int) -> VisualizerControlState {
        if let existing = visualizerControls.states[slot] { return existing }
        let fresh = VisualizerControlState()
        visualizerControls.states[slot] = fresh
        return fresh
    }

    /// Which visualizers the page shows: one per connected controller or
    /// per joystick group, whichever is more.
    private var visualizerSlots: [VisualizerSlot] {
        let connectedSlots = Array(controllerService.controllerDetails.keys).sorted()
        let presetJoystickCount = preset.joysticks.count
        let totalVisualizers = max(presetJoystickCount, connectedSlots.count)
        return (0..<totalVisualizers).map { idx in
            let connected = idx < connectedSlots.count
            let slot = connected ? connectedSlots[idx] : idx
            return VisualizerSlot(id: connected ? "slot-\(slot)" : "empty-\(idx)", idx: idx, slot: slot)
        }
    }

    /// The visualizer body extracted so it can be embedded directly in a
    /// section card (with our own collapse chevron) instead of a
    /// Stable identity for each visualizer row so a VirtualControllerView's
    /// @State (gyro integrator, etc.) tracks its controller, not its position.
    /// Keying the ForEach by array index let that state bleed onto a different
    /// controller when one connected or disconnected and shifted the slots.
    private struct VisualizerSlot: Identifiable {
        let id: String
        let idx: Int
        let slot: Int
    }

    /// DisclosureGroup whose chevron sat awkwardly next to the card.
    @ViewBuilder
    private var visualizerContent: some View {
        let connectedSlots = Array(controllerService.controllerDetails.keys).sorted()
        let presetJoystickCount = preset.joysticks.count
        let resolvedVisualizerSlots = visualizerSlots
        let presetUsesMIDI = preset.joysticks.contains { group in
            group.bindings.contains { $0.input.type == .midi }
        }
        if connectedSlots.isEmpty && presetJoystickCount == 0 && !presetUsesMIDI {
            Text("Connect a controller to see its live state here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(resolvedVisualizerSlots) { viz in
                    let slot = viz.slot
                    // With one visualizer the chip and controls sit on the
                    // card's title row; with several, each gets its own.
                    if resolvedVisualizerSlots.count > 1 {
                        HStack(spacing: 8) {
                            visualizerDeviceChip(viz)
                            Spacer()
                            VisualizerHeaderControls(control: visualizerControl(for: slot))
                        }
                    }
                    VirtualControllerView(
                        preset: preset,
                        onJump: { target in
                            onJumpToBinding(target)
                        },
                        fixedSlot: slot,
                        // The light bar picker opens from the strip on the
                        // controller drawing, the same grid as the controller
                        // popover, and pushes the color to the controller
                        // live while this preset is the active one.
                        trailing: {
                            PresetLightBarPopover(
                                color: $preset.lightBarColor,
                                brightness: $preset.lightBarBrightness,
                                onChanged: pushPresetLightBarLive)
                        },
                        lightBarTint: presetLightBarSwiftUIColor,
                        onChangeInputKind: { changedSlot, newKind in
                            updateSlotInputKind(
                                presetID: preset.id,
                                slot: changedSlot,
                                kind: newKind)
                        },
                        control: visualizerControl(for: slot)
                    )
                    .environmentObject(controllerService)
                }

            }
        }
    }

    // MARK: - Section: Joystick Slots card

    /// Compact summary of every joystick mapping in the preset, grouped
    /// into a single card instead of the loose stack of mini cards we
    /// used to render under the visualizer.
    @ViewBuilder
    private var joystickSlotsCard: some View {
        sectionCard {
            sectionHeader(icon: "rectangle.stack.fill",
                          title: "Joystick Slots",
                          tint: .indigo) {
                // Calibration shortcuts, so hardware tuning is reachable
                // right from the detail view instead of only inside the
                // editor's toolbar.
                if hasTouchpadCapableController || hasMotionCapableController {
                    Menu {
                        if hasTouchpadCapableController {
                            Button("Calibrate Touchpad…") { showingTouchpadCalFromDetail = true }
                        }
                        if hasMotionCapableController {
                            Button("Calibrate Motion…") { showingMotionCalFromDetail = true }
                        }
                    } label: {
                        Label("Calibrate", systemImage: "scope")
                            .font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Calibrate")
                    .accessibilityHint("Opens touchpad or motion calibration for the connected controller.")
                }
                Text("\(preset.joysticks.count) \(preset.joysticks.count == 1 ? "slot" : "slots")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            VStack(spacing: 6) {
                ForEach(Array(preset.joysticks.enumerated()), id: \.element.id) { index, joystick in
                    joystickSlotRow(index: index, joystick: joystick)
                }
            }
        }
    }

    @ViewBuilder
    private func joystickSlotRow(index: Int, joystick: JoystickMapping) -> some View {
        let bindingCount = joystick.bindings.count
        let hasComment = !joystick.tag.isEmpty && joystick.tag != "<write comments here>"

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(resolvedJoystickName(joystick: joystick, slot: index))
                    .font(.subheadline)
                if joystick.customName == nil {
                    Text("#\(index)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text("\(bindingCount) \(bindingCount == 1 ? "binding" : "bindings")")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if hasComment {
                Text(joystick.tag)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    // MARK: - Section: Details card

    @ViewBuilder
    private var detailsCard: some View {
        sectionCard {
            sectionHeader(icon: "info.circle.fill",
                          title: "Details",
                          tint: .blue)
            detailsSection
        }
    }

    // MARK: - Section: Notes card

    /// Notes section card. The internal `presetNotesSection` still
    /// renders the icon, label, and TextEditor; the surrounding
    /// sectionCard provides the consistent frame.
    @ViewBuilder
    private var notesCard: some View {
        sectionCard {
            presetNotesSection
        }
    }

    /// Resolve the display name for a joystick mapping slot. Priority:
    ///   1. The user's `customName` if they renamed it.
    ///   2. The currently-connected controller's product name for that
    ///      slot (e.g. "DualSense Wireless Controller").
    ///   3. The fallback "Joystick #N".
    private func resolvedJoystickName(joystick: JoystickMapping, slot: Int) -> String {
        if let custom = joystick.customName, !custom.isEmpty {
            return custom
        }
        // A slot whose input is the display is not the controller that
        // happens to be plugged in.
        if joystick.inputKind == .screen
            || (!joystick.bindings.isEmpty && joystick.bindings.allSatisfy { $0.input.type == .cursorRegion }) {
            return "Screen"
        }
        if let info = controllerService.controllerDetails[slot] {
            let trimmed = info.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return "Input Device \(slot)"
    }

    /// Apply the visualizer picker's choice back to the preset model
    /// and persist via the store. Auto-creates the joystick mapping
    /// for the slot if one doesn't exist yet (so the picker works on
    /// brand-new presets with no joysticks defined).
    fileprivate func updateSlotInputKind(presetID: UUID, slot: Int, kind: SlotInputKind) {
        guard preset.id == presetID else { return }
        var updated = preset
        while updated.joysticks.count <= slot {
            updated.joysticks.append(JoystickMapping(tag: ""))
        }
        updated.joysticks[slot].inputKind = kind
        updated.modifiedAt = Date()
        preset = updated
        presetStore.savePreset(updated)
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
                if controllerService.connectedControllers.isEmpty
                    && controllerService.rawHIDGamepadSlots.isEmpty
                    && !controllerService.debugMarketingFakeActive {
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
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
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
    /// Edit-mode and zoom state per visualizer slot. A plain box (not
    /// observed here) so creating a state object does not re-run this view;
    /// the title-row controls and the panel observe the objects themselves.
    @State private var visualizerControls = VisualizerControlBox()
    /// Focus state for the notes editor, so the placeholder hides as soon as
    /// the field is clicked rather than waiting for the first typed character.
    @FocusState private var notesFocused: Bool
    /// Calibration sheets launched from the Joystick Slots card header.
    @State private var showingTouchpadCalFromDetail = false
    @State private var showingMotionCalFromDetail = false

    /// True when any connected controller has a touchpad / motion sensors.
    /// Drives the Calibrate shortcut menu's visibility and contents.
    private var hasTouchpadCapableController: Bool {
        controllerService.controllerDetails.values.contains { $0.hasTouchpad }
    }
    private var hasMotionCapableController: Bool {
        controllerService.controllerDetails.values.contains { $0.supportsMotion }
    }
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
                                .buttonStyle(.plain)
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
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
        // Intentionally NOT keyed on preset.modifiedAt: that fired a synchronous
        // versions(for:) disk read on EVERY keystroke while editing the name,
        // tag, or notes. The list reloads on preset switch and on appear, which
        // is when this collapsed "Previous versions" group is actually viewed.
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
                    .iconTint(.yellow)
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
                .focused($notesFocused)
                .frame(minHeight: 60, maxHeight: 120)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.22), lineWidth: 0.5)
                )
                .overlay(alignment: .topLeading) {
                    if preset.notes.isEmpty && !notesFocused {
                        Text("Start typing…")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
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

    /// While this preset is the active one, the controller shows the
    /// override right away, mirroring what the engine does at start. With
    /// the override cleared, the controller goes back to its general color.
    private func pushPresetLightBarLive() {
        guard presetStore.activePresetId == preset.id else { return }
        let slots = controllerService.controllerDetails.keys.filter {
            controllerService.controllerDetails[$0]?.hasLight == true
        }
        if let rgb = preset.lightBarColor {
            controllerService.stopAllRGBCycles()
            let bri = preset.lightBarBrightness.map { UInt8(max(0, min(2, $0))) }
            for slot in slots {
                controllerService.applyTemporaryLight(
                    at: slot, red: rgb.floatR, green: rgb.floatG, blue: rgb.floatB, brightness: bri)
            }
        } else {
            controllerService.revertTemporaryLights()
        }
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
            IconView(name: icon, glyphHeight: 11)
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
            bullets.append("Touchpad zones: \(n) tap binding\(n == 1 ? "" : "s")")
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

}

// MARK: - Per-preset light bar popover

/// The light bar picker for one preset, opened from the strip on the Live
/// Visualizer's controller drawing. The same grid as the controller popover:
/// fixed colors, a Custom well that applies as soon as a colour is chosen,
/// then brightness. "Controller's colour" clears the override so the preset
/// leaves the light alone.
struct PresetLightBarPopover: View {
    @SwiftUI.Binding var color: RGBLightColor?
    @SwiftUI.Binding var brightness: Int?
    var onChanged: () -> Void = {}

    @State private var customColor = Color.blue

    private static let swatches: [(name: String, r: UInt8, g: UInt8, b: UInt8)] = [
        ("Red",    255, 0, 0),
        ("Orange", 255, 89, 0),
        ("Yellow", 255, 179, 0),
        ("Green",  0, 255, 0),
        ("Cyan",   0, 255, 255),
        ("Blue",   0, 0, 255),
        ("Purple", 128, 0, 255),
        ("Pink",   255, 0, 153),
        ("White",  255, 255, 255),
        ("Off",    0, 0, 0),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "light.beacon.max.fill")
                    .foregroundStyle(.pink)
                Text("Light bar for this preset")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if color != nil {
                    Button("Controller's color") {
                        color = nil
                        brightness = nil
                        onChanged()
                    }
                    .buttonStyle(.solidSecondaryCompact)
                    .controlSize(.small)
                    .help("Forget this preset's color and leave the light bar on the controller's general colour")
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 8) {
                ForEach(Self.swatches, id: \.name) { swatch in
                    let swatchColor = swatch.name == "Off" ? Color.gray.opacity(0.3) :
                        Color(red: Double(swatch.r) / 255, green: Double(swatch.g) / 255, blue: Double(swatch.b) / 255)
                    LightSwatchButton(name: swatch.name, color: swatchColor) {
                        set(RGBLightColor(r: swatch.r, g: swatch.g, b: swatch.b))
                    }
                }
                VStack(spacing: 2) {
                    ColorPicker("", selection: $customColor, supportsOpacity: false)
                        .labelsHidden()
                        .scaleEffect(1.35)
                        .frame(width: 24, height: 24)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                        .shadow(color: customColor.opacity(0.3), radius: 2)
                        .accessibilityLabel("Custom light bar color")
                        .onChange(of: customColor) { _, value in
                            let ns = NSColor(value).usingColorSpace(.sRGB) ?? NSColor(value)
                            set(RGBLightColor(floatR: Float(ns.redComponent),
                                              floatG: Float(ns.greenComponent),
                                              floatB: Float(ns.blueComponent)))
                        }
                    Text("Custom")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 8) {
                Text("Brightness")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: SwiftUI.Binding(
                    get: { brightness ?? 2 },
                    set: { brightness = $0; onChanged() })) {
                    Text("Off").tag(0)
                    Text("Dim").tag(1)
                    Text("Bright").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }

            Text(color == nil
                 ? "No color set: the controller keeps its general colour while this preset runs."
                 : "The controller switches to this color while the preset runs and goes back when it stops.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(width: 260)
        .onAppear {
            if let rgb = color {
                customColor = Color(red: Double(rgb.floatR), green: Double(rgb.floatG), blue: Double(rgb.floatB))
            }
        }
    }

    private func set(_ rgb: RGBLightColor) {
        color = rgb
        onChanged()
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
struct WrappingHStackLayout: Layout {
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

// The in-app "Update available" alert and its UpdateCheckService were
// removed: the Mac App Store delivers update notifications itself, and
// App Review guideline 2.4.5(vii) prohibits in-app update checks.

// MARK: - Smart Preset Maker (guided wizard)

/// Branching wizard that turns a few answers ("Play a game" -> "Roblox" ->
/// "Switch Pro") into a tailored preset, fusing a researched mapping profile
/// with the user's controller and chosen options. Generated presets carry
/// controller-aware setup notes and land in the sidebar where the user picks.
struct SmartPresetMakerView: View {
    @EnvironmentObject var presetStore: PresetStore
    @EnvironmentObject var controllerService: GameControllerService
    @Environment(\.dismiss) private var dismiss
    var onCreated: (Preset) -> Void

    enum Step: Int, CaseIterable { case category, item, controller, options, finish }

    @State private var step: Step = .category
    @State private var category: SmartPresetProfile.Category?
    @State private var profile: SmartPresetProfile?
    @State private var brand: ControllerBrand = .dualSense
    @State private var search = ""

    @State private var autoLaunch = false
    @State private var appPath = ""
    @State private var confine = false
    @State private var recenter = false
    @State private var hideCursor = false
    @State private var addTouchpad = true
    @State private var addGyro = true
    @State private var rumble = false
    @State private var lightColor: Color = .green

    @State private var name = ""
    @State private var groupID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView { content.padding(20).frame(maxWidth: .infinity, alignment: .leading) }
            Divider()
            footer
        }
        .frame(width: 580, height: 600)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .font(.title2)
                .iconTint(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text("Smart Preset Maker").font(.headline)
                Text(stepSubtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .accessibilityLabel("Close")
        }
        .padding(16)
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .category:   categoryStep
        case .item:       itemStep
        case .controller: controllerStep
        case .options:    optionsStep
        case .finish:     finishStep
        }
    }

    private var footer: some View {
        HStack {
            if step != .category {
                Button("Back") { back() }.buttonStyle(.solidSecondary)
            }
            Spacer()
            if step == .options {
                Button("Next") { step = .finish }.buttonStyle(.solid)
            } else if step == .finish {
                Button("Create Preset") { create() }
                    .buttonStyle(.solid)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
    }

    // MARK: Steps

    private var categoryStep: some View {
        VStack(spacing: 12) {
            Text("What do you want to do?").font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(SmartPresetProfile.Category.allCases) { cat in
                Button {
                    category = cat; search = ""; step = .item
                } label: {
                    HStack(spacing: 12) {
                        IconView(name: cat.systemImage, glyphHeight: 17).font(.title2).frame(width: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(catTitle(cat)).font(.headline)
                            Text(catDesc(cat)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var itemStep: some View {
        let items = (category.map { SmartPresetLibrary.profiles(in: $0) } ?? [])
            .filter {
                search.isEmpty
                || $0.displayName.localizedCaseInsensitiveContains(search)
                || $0.subtitle.localizedCaseInsensitiveContains(search)
            }
        return VStack(alignment: .leading, spacing: 10) {
            Text(category?.pluralPrompt ?? "Pick one").font(.title3.weight(.semibold))
            TextField("Search…", text: $search).textFieldStyle(.roundedBorder)
            if items.isEmpty {
                Text("No matches yet. More titles are added over time.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            }
            ForEach(items) { p in
                Button { select(p) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.displayName).font(.body.weight(.medium))
                            Text(p.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.05)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var controllerStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Which controller?").font(.title3.weight(.semibold))
            ForEach(controllerChoices, id: \.self) { b in
                Button {
                    brand = b
                    if let p = profile { name = "\(p.displayName) (\(b.displayName))" }
                    step = .options
                } label: {
                    HStack(spacing: 10) {
                        ControllerGlyph(height: 15).frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(b.displayName)
                                if connectedBrands.contains(b) {
                                    Text("Connected").font(.caption2)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Capsule().fill(Color.green.opacity(0.2)))
                                        .foregroundStyle(.green)
                                }
                            }
                            Text(b.capabilitySummary)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.05)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var optionsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Fine-tune").font(.title3.weight(.semibold))
            Toggle("Open the app automatically when this preset activates", isOn: $autoLaunch)
            if autoLaunch {
                HStack {
                    Text(appPath.isEmpty ? "No app chosen" : appPath)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose App…") { chooseApp() }.buttonStyle(.solidSecondaryCompact)
                }
            }
            Divider()
            Toggle("Confine the mouse to the screen (boundaries)", isOn: $confine)
            Toggle("Auto-recenter the cursor", isOn: $recenter)
            Toggle("Hide the cursor while active", isOn: $hideCursor)
            if brand.hasLightBar {
                Divider()
                HStack {
                    Text("Light bar color")
                    Spacer()
                    ColorPicker("", selection: $lightColor, supportsOpacity: false).labelsHidden()
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Label { Text("\(brand.displayName) supports: \(brand.capabilitySummary)") } icon: { ControllerGlyph(height: 10) }
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if brand.hasTouchpad {
                    Toggle("Use the touchpad as a trackpad (one finger points, two fingers scroll, tap to click)", isOn: $addTouchpad)
                }
                if brand.hasMotion, let p = profile, SmartPresetGenerator.usesMouseLook(p) {
                    Toggle("Gyro fine aim (tilting the pad nudges the aim on top of the stick)", isOn: $addGyro)
                }
                Toggle("Rumble when a trigger clicks", isOn: $rumble)
            }
            if let p = profile, !p.tips.isEmpty {
                Divider()
                Text("Tips").font(.caption.weight(.semibold))
                ForEach(p.tips, id: \.self) { tip in
                    Text("• \(tip)").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Name & save").font(.title3.weight(.semibold))
            TextField("Preset name", text: $name).textFieldStyle(.roundedBorder)
            Picker("Add to folder", selection: $groupID) {
                Text("My Presets").tag(UUID?.none)
                ForEach(presetStore.groups) { g in
                    Text(g.name).tag(UUID?.some(g.id))
                }
            }
            if let p = profile {
                VStack(alignment: .leading, spacing: 4) {
                    summaryRow("What", p.displayName)
                    summaryRow("Controller", brand.displayName)
                    summaryRow("Auto-launch", autoLaunch ? "Yes" : "No")
                    summaryRow("Mouse confine", confine ? "On" : "Off")
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
            }
            if let p = profile {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mapping preview").font(.caption.weight(.semibold))
                    ForEach(Array(p.bindings.prefix(6).enumerated()), id: \.offset) { _, b in
                        Text("\(SmartPresetGenerator.label(for: b.input, brand: brand))  →  \(b.note)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if p.bindings.count > 6 {
                        Text("+ \(p.bindings.count - 6) more bindings")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.04)))
            }
            Text("After it's created you can edit any binding. If a control doesn't respond, open the binding editor and tap Scan - controllers vary, so the preset notes list what each control should do.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Helpers

    private func back() {
        step = Step(rawValue: max(0, step.rawValue - 1)) ?? .category
    }

    private func select(_ p: SmartPresetProfile) {
        profile = p
        confine = p.confineCursor
        recenter = p.autoRecenter
        hideCursor = p.hideCursor
        autoLaunch = !p.appPath.isEmpty
        appPath = p.appPath
        lightColor = Color(.sRGB,
                           red: Double(p.light.r) / 255.0,
                           green: Double(p.light.g) / 255.0,
                           blue: Double(p.light.b) / 255.0)
        if let connected = connectedBrands.first { brand = connected }
        name = "\(p.displayName) (\(brand.displayName))"
        step = .controller
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["app"]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { appPath = url.path }
    }

    private func create() {
        guard let p = profile else { return }
        let ns = NSColor(lightColor).usingColorSpace(.sRGB) ?? NSColor(lightColor)
        let lc = SmartPresetProfile.Light(
            r: Int((ns.redComponent * 255).rounded()),
            g: Int((ns.greenComponent * 255).rounded()),
            b: Int((ns.blueComponent * 255).rounded()))
        let opts = SmartPresetGenerator.Options(
            name: name.trimmingCharacters(in: .whitespaces),
            groupID: groupID,
            autoLaunchApp: autoLaunch,
            appPathOverride: appPath.isEmpty ? nil : appPath,
            confineCursor: confine,
            autoRecenter: recenter,
            hideCursor: hideCursor,
            lightColor: lc,
            touchpadAsTrackpad: addTouchpad,
            gyroFineAim: addGyro,
            rumbleOnTriggers: rumble)
        let preset = SmartPresetGenerator.makePreset(from: p, brand: brand, options: opts)
        presetStore.savePreset(preset)
        onCreated(preset)
        dismiss()
    }

    private var connectedBrands: Set<ControllerBrand> {
        Set(controllerService.controllerDetails.values.map { $0.brand }.filter { $0 != .unknown })
    }

    private var controllerChoices: [ControllerBrand] {
        [.dualSense, .dualShock4, .xbox, .switchPro, .eightBitDo, .stadia, .mfiGeneric]
    }

    private var stepSubtitle: String {
        switch step {
        case .category:   return "Step 1 of 5 · Choose what you're setting up"
        case .item:       return "Step 2 of 5 · Pick the title"
        case .controller: return "Step 3 of 5 · Pick your controller"
        case .options:    return "Step 4 of 5 · Options"
        case .finish:     return "Step 5 of 5 · Name & save"
        }
    }

    private func catTitle(_ c: SmartPresetProfile.Category) -> String {
        switch c {
        case .game:     return "Play a game"
        case .app:      return "Work in an app"
        case .workflow: return "A workflow"
        }
    }

    private func catDesc(_ c: SmartPresetProfile.Category) -> String {
        switch c {
        case .game:     return "Roblox, Minecraft, Elden Ring, and more"
        case .app:      return "Blender, Photoshop, Word, video editors, and more"
        case .workflow: return "Desktop, web, media, presenting, accessibility"
        }
    }

    private func summaryRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
            Text(value)
        }
        .font(.caption)
    }
}


/// A quiet rotating pill of one-line feature tips, ported from YapToText's
/// QuickTipsPill. The text swaps on a slow clock with NO animated transaction
/// and the pill keeps a stable single-Text structure.
private struct QuickTipsPill: View {
    private static let tips: [String] = [
        "Press \u{2303}\u{2325}\u{2318}P anywhere to toggle your most recent preset, even while a game is in front (enable it in Settings).",
        "The Smart Preset Maker builds a tailored preset from a few questions: pick a game, answer, done.",
        "Gyro aim: bind gyro yaw to mouse X and pitch to mouse Y for motion aiming in any app.",
        "The DualSense touchpad can drive your Mac's cursor while a second finger scrolls.",
        "Turbo any button to rapid-fire it, or flip a binding to Toggle to latch it on and off.",
        "Macros chain keystrokes with per-step timing, and can mix keys, clicks, and MIDI in one sequence.",
        "Sticks and triggers can send MIDI notes and CC dials straight into GarageBand, Logic, or Ableton.",
        "A preset can auto-activate when its app comes to the front, then step aside when you leave.",
        "Set the DualSense light bar per preset so you can see which mapping is live from across the room.",
        "Everything runs and stays on your Mac. No telemetry, no account, nothing uploaded.",
        "Import presets with the tray icon in the bottom bar; export any preset from its right-click menu.",
        "Hide the Dock icon in Settings to run InputConfig as a quiet menu bar app.",
        "The editor has unlimited undo: \u{2318}Z and \u{2318}\u{21E7}Z work through every change.",
        "Click any control on the Live Visualizer to jump straight to its binding in the editor.",
    ]

    @State private var index = Int.random(in: 0..<QuickTipsPill.tips.count)
    @State private var rotator: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "lightbulb.max").iconTint(.accentColor).font(.caption)
            Text(Self.tips[index])
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(Color.secondary.opacity(0.06), in: Capsule())
        .overlay(Capsule().stroke(Color.secondary.opacity(0.12), lineWidth: 0.5))
        .onAppear {
            rotator?.cancel()
            rotator = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 9_000_000_000)
                    guard !Task.isCancelled else { return }
                    index = (index + 1) % Self.tips.count
                }
            }
        }
        .onDisappear { rotator?.cancel(); rotator = nil }
        .accessibilityLabel("Tip: \(Self.tips[index])")
    }
}

// MARK: - Debug automation hooks (marketing / QA)

/// DEBUG-only view modifier that lets the app be driven from the shell via
/// DistributedNotificationCenter, so marketing captures and QA can navigate
/// without clicking. Wrapped in `#if DEBUG` so none of it can ship in a
/// Release build. Where a command needs a target preset, its name rides in
/// the notification's `object` (distributed notifications carry a string
/// object across processes).
///
/// Commands (post the name; pass the preset name as the object where noted):
///   inputconfig.debug.welcome            show the welcome screen
///   inputconfig.debug.select    <name>   select a preset (detail view)
///   inputconfig.debug.edit      [name]   open the binding editor
///   inputconfig.debug.activate  [name]   activate a preset (engine running)
///   inputconfig.debug.deactivate         stop the active preset
///   inputconfig.debug.sheet     <which>  smartmaker|stats|settings|motion|touchpad
///   inputconfig.debug.demo      <kind>   open a feature demo by raw value
///   inputconfig.debug.closesheets        dismiss any open sheet
/// See `dnc(_:)`: bridges distributed debug notifications to the local
/// center with immediate delivery, whatever app is in front.
@MainActor
final class DebugHookRelay: NSObject {
    static let shared = DebugHookRelay()
    private var names: Set<String> = []
    func ensure(_ name: String) {
        guard !names.contains(name) else { return }
        names.insert(name)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(relay(_:)), name: Notification.Name(name), object: nil,
            suspensionBehavior: .deliverImmediately)
    }
    @objc private func relay(_ note: Notification) {
        let n = note
        Task { @MainActor in
            NotificationCenter.default.post(name: n.name, object: n.object, userInfo: n.userInfo)
        }
    }
}

struct DebugAutomationHooks: ViewModifier {
    let presetStore: PresetStore
    /// Only the debug state readout uses this; it reports what the app is
    /// seeing from the hardware.
    @EnvironmentObject var controllerService: GameControllerService
    @Binding var selectedPresetId: UUID?
    @Binding var editingPreset: Preset?
    @Binding var showingSmartMaker: Bool
    @Binding var showingStats: Bool
    @Binding var settingsSheetTab: SettingsView.SettingsTab?
    @Binding var showingMotion: Bool
    @Binding var showingTouchpad: Bool
    @Binding var presentedDemoKind: FeatureDemoKind?
    let onToggle: (Preset) -> Void

    func body(content: Content) -> some View {
        #if DEBUG
        content
            .onReceive(dnc("inputconfig.debug.welcome")) { _ in
                editingPreset = nil
                selectedPresetId = nil
            }
            .onReceive(dnc("inputconfig.debug.select")) { note in
                if let p = preset(note) {
                    editingPreset = nil
                    selectedPresetId = p.id
                }
            }
            .onReceive(dnc("inputconfig.debug.edit")) { note in
                if let p = preset(note) ?? selected() {
                    selectedPresetId = p.id
                    editingPreset = p
                }
            }
            .onReceive(dnc("inputconfig.debug.activate")) { note in
                if let p = preset(note) ?? selected() {
                    selectedPresetId = p.id
                    if !p.isActive { onToggle(p) }
                }
            }
            #if DEBUG
            .onReceive(dnc("inputconfig.debug.buzz")) { _ in
                if let c = controllerService.connectedControllers.first {
                    FeedbackService.shared.debugBuzzTest(controller: c)
                }
            }
            #endif
            .onReceive(dnc("inputconfig.debug.deactivate")) { _ in
                if let active = presetStore.presets.first(where: { $0.isActive }) {
                    onToggle(active)
                }
            }
            .onReceive(dnc("inputconfig.debug.sheet")) { note in
                closeSheets()
                editingPreset = nil
                switch note.object as? String {
                case "smartmaker": showingSmartMaker = true
                case "stats": showingStats = true
                case "settings": settingsSheetTab = .general
                case "about": settingsSheetTab = .about
                case "advanced": settingsSheetTab = .advanced
                // Exercises the exact call the Help window's "here" link makes,
                // so the cross-window path can be tested without pixel-clicking
                // a link in a window that keeps losing front position.
                case "aboutlink": MenuBarController.shared.openAboutPage()
                case "motion": showingMotion = true
                case "touchpad": showingTouchpad = true
                default: break
                }
            }
            .onReceive(dnc("inputconfig.debug.demo")) { note in
                closeSheets()
                if let raw = note.object as? String,
                   let kind = FeatureDemoKind(rawValue: raw) {
                    presentedDemoKind = kind
                }
            }
            .onReceive(dnc("inputconfig.debug.closesheets")) { _ in
                closeSheets()
            }
            .onReceive(dnc("inputconfig.debug.renderdemos")) { _ in
                // Offscreen frames of every feature demo, three per demo
                // 0.6 s apart, into the sandbox tmp: a way to review the
                // animations without the window being on screen.
                Task { @MainActor in
                    for kind in FeatureDemoKind.allCases {
                        for i in 0..<3 {
                            let renderer = ImageRenderer(content:
                                FeatureDemoView(kind: kind, onJumpToPreset: { _ in }, onOpenStatistics: {}, onOpenSettings: {})
                                    .frame(width: 560, height: 500)
                                    .background(Color(nsColor: .windowBackgroundColor))
                                    .environment(\.colorScheme, .dark))
                            renderer.scale = 2
                            if let cg = renderer.cgImage {
                                let rep = NSBitmapImageRep(cgImage: cg)
                                let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("demo_\(kind.rawValue)_\(i).png")
                                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                            }
                            try? await Task.sleep(nanoseconds: 600_000_000)
                        }
                    }
                }
            }
            .onReceive(dnc("inputconfig.debug.review")) { note in
                // "prompt" shows the card; "thanks" plays the thank-you.
                if (note.object as? String) == "thanks" {
                    ReviewPromptService.shared.accepted()
                } else {
                    ReviewPromptService.shared.present()
                }
            }
            .onReceive(dnc("inputconfig.debug.whatsnew")) { _ in
                // Exercises the real menu bar path: open the window, post
                // the request, let ContentView's observer present it.
                MenuBarController.shared.showWhatsNew()
            }
            .onReceive(dnc("inputconfig.debug.injecttap")) { note in
                // "<count>" or "<count>,<spacing ms>"
                let parts = ((note.object as? String) ?? "").split(separator: ",")
                let n = Int(parts.first ?? "") ?? 2
                let ms = parts.count > 1 ? (Double(parts[1]) ?? 150) : 150
                ChassisTapService.shared.injectSyntheticTaps(count: n, spacing: ms / 1000)
            }
            .onReceive(dnc("inputconfig.debug.scan")) { _ in
                NotificationCenter.default.post(
                    name: PresetEditorView.debugStartScanNotification, object: nil)
            }
            .onReceive(dnc("inputconfig.debug.presetorder")) { _ in
                var out = ""
                for g in presetStore.groups.sorted(by: { $0.sortOrder < $1.sortOrder }) {
                    out += "[\(g.name)]\n"
                    for p in presetStore.presets(in: g.id) {
                        out += "   \(p.sortOrder.map(String.init) ?? "-")  \(p.name)\n"
                    }
                }
                out += "[My Presets]\n"
                for p in presetStore.presets(in: nil) {
                    out += "   \(p.sortOrder.map(String.init) ?? "-")  \(p.name)\n"
                }
                try? out.write(toFile: NSTemporaryDirectory() + "presetorder.txt",
                               atomically: true, encoding: .utf8)
            }
            .onReceive(dnc("inputconfig.debug.movepreset")) { note in
                // "<dragged preset>,<target preset>" - exercises the exact
                // store call the row's dropDestination makes.
                let parts = ((note.object as? String) ?? "").split(separator: ",")
                guard parts.count == 2,
                      let drag = presetStore.presets.first(where: { $0.name == String(parts[0]) }),
                      let target = presetStore.presets.first(where: { $0.name == String(parts[1]) })
                else { return }
                presetStore.movePreset(drag.id, toPositionOf: target.id)
            }
            .onReceive(dnc("inputconfig.debug.tapstrikes")) { _ in
                try? ChassisTapService.shared.drainStrikes()
                    .write(toFile: NSTemporaryDirectory() + "tapstrikes.txt",
                           atomically: true, encoding: .utf8)
            }
            .onReceive(dnc("inputconfig.debug.tapcommits")) { _ in
                try? (ChassisTapService.shared.drainCommits() + "\n")
                    .write(toFile: NSTemporaryDirectory() + "tapcommits.txt",
                           atomically: true, encoding: .utf8)
            }
            .onReceive(dnc("inputconfig.debug.taptrace")) { note in
                let secs = Double((note.object as? String) ?? "") ?? 8
                ChassisTapService.shared.startTrace(seconds: secs,
                    path: NSTemporaryDirectory() + "taptrace.txt")
            }
            .onReceive(dnc("inputconfig.debug.tapstats")) { _ in
                let d = ChassisTapService.shared.drainDiagnostics()
                let line = "reports=\(d.reports) strikes=\(d.strikes) peak=\(String(format: "%.4f", d.peak))g noise=\(String(format: "%.4f", d.noise))g ready=\(d.ready) running=\(ChassisTapService.shared.isRunning) error=\(ChassisTapService.shared.lastError ?? "none") reasons=\(ChassisTapService.shared.activeReasons)"
                try? line.write(to: URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("tapstats.txt"), atomically: true, encoding: .utf8)
            }
            .onReceive(dnc("inputconfig.debug.systemaction")) { note in
                if let raw = note.object as? String,
                   let kind = SystemActionKind(rawValue: raw) {
                    SystemActionService.shared.perform(kind, parameter: nil)
                }
            }
            // Can this build actually read your Shortcuts and applications?
            // The sandbox decides, so it has to be measured, not assumed.
            .onReceive(dnc("inputconfig.debug.lists")) { _ in
                SystemListsCache.shared.refreshIfStale()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    let c = SystemListsCache.shared
                    let text = "shortcuts=\(c.shortcuts.count) apps=\(c.apps.count)\n"
                        + "first shortcuts: \(c.shortcuts.prefix(5).joined(separator: ", "))\n"
                        + "first apps: \(c.apps.prefix(5).joined(separator: ", "))\n"
                    try? text.write(to: URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("lists.txt"), atomically: true, encoding: .utf8)
                }
            }
            // What the light writer is holding, and what the slot is meant
            // to be showing. "peek" reports without firing anything.
            .onReceive(dnc("inputconfig.debug.light")) { note in
                let arg = (note.object as? String) ?? ""
                let peek = arg == "peek" || arg == "default"
                // "default" runs the slot-default path that used to steal the
                // preset's color, so the fix can be proved without a replug.
                if arg == "default" { controllerService.setControllerLight(at: 0) }
                if !peek, let c = controllerService.connectedControllers.first {
                    FeedbackService.shared.vibrate(controller: c, intensity: 0.8, durationMs: 1500)
                }
                let delay: Double = peek ? 0.0 : 0.4
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    let writer: String = InProcessLightWriter.shared.debugState
                    let details = controllerService.controllerDetails[0]
                    let hasLight: String = details.map { String($0.hasLight) } ?? "no slot 0"
                    let stored = controllerService.lightColors[0]
                    let storedText: String = stored.map { "(\($0.r),\($0.g),\($0.b))" } ?? "none"
                    var lines: [String] = []
                    lines.append("writer: " + writer)
                    lines.append("slot 0 hasLight: " + hasLight)
                    let gcLight = controllerService.connectedControllers.first?.light
                    let gcColor = gcLight.map { l in
                        String(format: "(%.0f,%.0f,%.0f)", l.color.red * 255, l.color.green * 255, l.color.blue * 255)
                    } ?? "nil"
                    lines.append("GCDeviceLight: \(gcLight == nil ? "not supported" : "supported") color \(gcColor)")
                    lines.append("slot 0 stored color: " + storedText)
                    lines.append("detail slots: \(Array(controllerService.controllerDetails.keys).sorted())")
                    lines.append("temp light calls: \(controllerService.debugTempLightLog)")
                    let act = presetStore.presets.first { $0.isActive }
                    let actColor = act?.lightBarColor.map { "(\($0.r),\($0.g),\($0.b))" } ?? "none"
                    lines.append("active preset: \(act?.name ?? "none") color \(actColor)")
                    let text: String = lines.joined(separator: "\n") + "\n"
                    try? text.write(to: URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("light.txt"), atomically: true, encoding: .utf8)
                }
            }
            // Drive a finger across the pad through the same entry point the
            // controller feeds, and report whether the pointer actually
            // moved. Tests the whole chain with no hardware in the loop.
            .onReceive(dnc("inputconfig.debug.swipe")) { note in
                // "<ms>": a sustained circular finger motion for that long,
                // at the pad's own 250 Hz, for profiling under load.
                if let ms = Int((note.object as? String) ?? ""), ms > 0 {
                    let steps = ms / 4
                    for i in 0...steps {
                        let t = Double(i) / 250.0
                        DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.004) {
                            TouchpadService.shared.ingestGameControllerTouchpad(
                                f0Active: i < steps,
                                f0NormalizedX: Float(0.5 * sin(t * 2.5)), f0NormalizedY: Float(0.4 * cos(t * 2.5)),
                                f1Active: false, f1NormalizedX: 0, f1NormalizedY: 0)
                        }
                    }
                    return
                }
                let start = NSEvent.mouseLocation
                var lines: [String] = ["start cursor \(Int(start.x)),\(Int(start.y))"]
                let steps = 30
                for i in 0...steps {
                    let t = Float(i) / Float(steps)
                    let x = -0.6 + 1.2 * t          // left edge to right edge
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.012) {
                        TouchpadService.shared.ingestGameControllerTouchpad(
                            f0Active: true, f0NormalizedX: x, f0NormalizedY: 0.1,
                            f1Active: false, f1NormalizedX: 0, f1NormalizedY: 0)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(steps) * 0.012 + 0.05) {
                    let mid = NSEvent.mouseLocation
                    lines.append("after swipe cursor \(Int(mid.x)),\(Int(mid.y))")
                    lines.append("moved dx=\(Int(mid.x - start.x)) dy=\(Int(mid.y - start.y))")
                    lines.append("fingerActive=\(TouchpadService.shared.isFingerActive(0))")
                    lines.append("peekDelta x=\(TouchpadService.shared.peekDelta(finger: 0, axis: .x))")
                    lines.append("samples=\(TouchpadService.shared.gameControllerSampleCount)")
                    TouchpadService.shared.ingestGameControllerTouchpad(
                        f0Active: false, f0NormalizedX: 0, f0NormalizedY: 0,
                        f1Active: false, f1NormalizedX: 0, f1NormalizedY: 0)
                    let text = lines.joined(separator: "\n") + "\n"
                    try? text.write(to: URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("swipe.txt"), atomically: true, encoding: .utf8)
                }
            }
            // Watch the raw gyro for a few seconds and report which axis a
            // movement lands on: "<ms>". Settles axis conventions by
            // measurement instead of by documentation.
            .onReceive(dnc("inputconfig.debug.gyrowatch")) { note in
                let ms = Int((note.object as? String) ?? "") ?? 4000
                var peak = SIMD3<Float>(0, 0, 0)
                var sumSigned = SIMD3<Float>(0, 0, 0)
                var accelMin = SIMD3<Float>(9, 9, 9), accelMax = SIMD3<Float>(-9, -9, -9)
                let ticks = max(1, ms / 33)
                for i in 0...ticks {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.033) {
                        guard let c = controllerService.connectedControllers.first, let m = c.motion else { return }
                        let r = SIMD3(Float(m.rotationRate.x), Float(m.rotationRate.y), Float(m.rotationRate.z))
                        peak = SIMD3(max(peak.x, abs(r.x)), max(peak.y, abs(r.y)), max(peak.z, abs(r.z)))
                        sumSigned += r * 0.033
                        let a = SIMD3(Float(m.acceleration.x), Float(m.acceleration.y), Float(m.acceleration.z))
                        accelMin = SIMD3(min(accelMin.x, a.x), min(accelMin.y, a.y), min(accelMin.z, a.z))
                        accelMax = SIMD3(max(accelMax.x, a.x), max(accelMax.y, a.y), max(accelMax.z, a.z))
                        if i == ticks {
                            let text = String(format: "peak rate  x=%.2f y=%.2f z=%.2f rad/s\nnet turn   x=%+.2f y=%+.2f z=%+.2f rad\naccel span x=%.2f y=%.2f z=%.2f g\n",
                                              peak.x, peak.y, peak.z, sumSigned.x, sumSigned.y, sumSigned.z,
                                              accelMax.x - accelMin.x, accelMax.y - accelMin.y, accelMax.z - accelMin.z)
                            try? text.write(to: URL(fileURLWithPath: NSTemporaryDirectory())
                                .appendingPathComponent("gyrowatch.txt"), atomically: true, encoding: .utf8)
                        }
                    }
                }
            }
            // Snapshot every SceneKit view on screen (the gyro controller
            // model) to gyro-N.png, so its look can be judged from outside.
            .onReceive(dnc("inputconfig.debug.gyrosnap")) { _ in
                func walk(_ v: NSView, _ out: inout [SCNView]) {
                    if let s = v as? SCNView { out.append(s) }
                    for c in v.subviews { walk(c, &out) }
                }
                var found: [SCNView] = []
                for w in NSApp.windows where w.isVisible { if let cv = w.contentView { walk(cv, &found) } }
                for (i, v) in found.enumerated() {
                    // Rendered large, off screen, so detail can be judged.
                    let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
                    renderer.scene = v.scene
                    renderer.pointOfView = v.pointOfView
                    renderer.autoenablesDefaultLighting = v.autoenablesDefaultLighting
                    if renderer.pointOfView == nil {
                        renderer.pointOfView = v.scene?.rootNode.childNodes(passingTest: { n, _ in n.camera != nil }).first
                    }
                    let img = renderer.snapshot(atTime: 0, with: CGSize(width: 1200, height: 800), antialiasingMode: .multisampling4X)
                    try? "\(found.count) scene views; image \(img.size) pov \(renderer.pointOfView != nil) lighting \(v.autoenablesDefaultLighting)\n".write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gyrosnap.txt"), atomically: true, encoding: .utf8)
                    guard let tiff = img.tiffRepresentation,
                          let rep = NSBitmapImageRep(data: tiff),
                          let png = rep.representation(using: .png, properties: [:]) else { continue }
                    try? png.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gyro-\(i).png"))
                }
            }
            // Size of the sheet in front, so a run over every showcase can
            // prove they all present at one size.
            // `post inputconfig.debug.auditpresets` checks every built-in
            // example and every Smart Preset profile mechanically and writes
            // tmp/audit.txt: inputs and outputs that fail to parse, rows that
            // send nothing, notes tables that name rows or presets that do
            // not exist, duplicate names, and profiles with no usable rows.
            .onReceive(dnc("inputconfig.debug.auditpresets")) { _ in
                var out: [String] = []
                let all = ExamplePresets.all
                let names = all.map(\.name)
                let dupes = Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
                if !dupes.isEmpty { out.append("DUPLICATE example names: \(dupes)") }
                for p in all {
                    var rowKeys: Set<String> = []
                    for g in p.joysticks {
                        for b in g.bindings {
                            let key = b.input.serialized
                            rowKeys.insert(key)
                            if InputEvent.parse(key)?.serialized != key { out.append("\(p.name): input does not round-trip: \(key)") }
                            let fires = !b.outputs.isEmpty || !(b.holdOutputs ?? []).isEmpty || !(b.doubleTapOutputs ?? []).isEmpty
                                || !(b.macroSteps ?? []).isEmpty || b.hapticEnabled == true || b.speechEnabled == true
                            if !fires { out.append("\(p.name): row sends nothing: \(key)") }
                            for o in b.outputs where OutputAction.parse(o.serialized)?.serialized != o.serialized {
                                out.append("\(p.name): output does not round-trip: \(o.serialized)")
                            }
                        }
                    }
                    if let notes = ExamplePresets.rowNotes[p.name] {
                        for k in notes.keys where !rowKeys.contains(k) { out.append("\(p.name): rowNotes names a row it does not have: \(k)") }
                    }
                    if ExamplePresets.presetNotes[p.name] == nil { out.append("\(p.name): no presetNotes entry") }
                    if ExamplePresets.groupAssignments[p.name] == nil { out.append("\(p.name): no group assignment") }
                }
                for k in ExamplePresets.rowNotes.keys where !names.contains(k) { out.append("rowNotes for unknown preset: \(k)") }
                for k in ExamplePresets.presetNotes.keys where !names.contains(k) { out.append("presetNotes for unknown preset: \(k)") }
                for k in ExamplePresets.groupAssignments.keys where !names.contains(k) { out.append("groupAssignments for unknown preset: \(k)") }
                for (k, v) in ExamplePresets.demoPresetNames where !names.contains(v) { out.append("demoPresetNames \(k) points at unknown preset: \(v)") }
                for kind in FeatureDemoKind.allCases {
                    if let key = kind.presetKey, ExamplePresets.demoPresetNames[key] == nil { out.append("showcase \(kind.rawValue) has no demo preset for key \(key)") }
                }
                let lib = SmartPresetLibrary.all
                let ids = lib.map(\.id)
                let dupIDs = Dictionary(grouping: ids, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
                if !dupIDs.isEmpty { out.append("DUPLICATE smart profile ids: \(dupIDs)") }
                var smartRows = 0
                for prof in lib {
                    var usable = 0
                    for b in prof.bindings {
                        if InputEvent.parse(b.input) == nil { out.append("smart \(prof.id): bad input \(b.input)") ; continue }
                        let outs = b.outputs.compactMap { OutputAction.parse($0) }
                        if outs.isEmpty { out.append("smart \(prof.id): row with no usable output: \(b.input) \(b.outputs)"); continue }
                        if outs.count != b.outputs.count { out.append("smart \(prof.id): some outputs failed to parse: \(b.input) \(b.outputs)") }
                        if b.note.trimmingCharacters(in: .whitespaces).isEmpty { out.append("smart \(prof.id): row without a note: \(b.input)") }
                        usable += 1
                    }
                    smartRows += usable
                    if usable == 0 { out.append("smart \(prof.id): NO usable rows") }
                    if prof.displayName.isEmpty { out.append("smart \(prof.id): empty display name") }
                    if !prof.appPath.isEmpty && !prof.appPath.hasSuffix(".app") { out.append("smart \(prof.id): odd appPath \(prof.appPath)") }
                    let inputs = prof.bindings.map(\.input)
                    let dupIn = Dictionary(grouping: inputs, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
                    if !dupIn.isEmpty { out.append("smart \(prof.id): input bound twice: \(dupIn)") }
                }
                out.insert("examples=\(all.count) smartProfiles=\(lib.count) smartRows=\(smartRows) findings=\(out.count)", at: 0)
                let text = out.joined(separator: "\n") + "\n"
                try? text.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("audit.txt"), atomically: true, encoding: .utf8)
            }
            // `post inputconfig.debug.rumblerig` plays ten variants in a row,
            // each announced by a light-bar colour, each a 100% buzz then a
            // 20% buzz, and writes the colour key to tmp/rig.txt. For
            // finding which part of the path is flattening the strength.
            .onReceive(dnc("inputconfig.debug.rumblerig")) { _ in
                let writer = InProcessLightWriter.shared
                let pad = controllerService.connectedControllers.first
                struct Variant { let name: String; let color: (UInt8, UInt8, UInt8); let setup: () -> Void; let buzz: (Float) -> Void }
                func plain(_ i: Float) { writer.vibrate(intensity: i, durationMs: 500) }
                let variants: [Variant] = [
                    Variant(name: "1 red: both flags, both motors (shipped)", color: (255, 0, 0),
                            setup: { InProcessLightWriter.debugVibrationMode = 0; InProcessLightWriter.debugMotorMask = 0 }, buzz: plain),
                    Variant(name: "2 orange: older flag only", color: (255, 110, 0),
                            setup: { InProcessLightWriter.debugVibrationMode = 1 }, buzz: plain),
                    Variant(name: "3 yellow: newer flag only", color: (255, 220, 0),
                            setup: { InProcessLightWriter.debugVibrationMode = 2 }, buzz: plain),
                    Variant(name: "4 green: strong (left) motor only", color: (0, 255, 0),
                            setup: { InProcessLightWriter.debugVibrationMode = 0; InProcessLightWriter.debugMotorMask = 1 }, buzz: plain),
                    Variant(name: "5 cyan: weak (right) motor only", color: (0, 220, 255),
                            setup: { InProcessLightWriter.debugMotorMask = 2 }, buzz: plain),
                    Variant(name: "6 blue: pulsed bursts 60 on 40 off", color: (0, 60, 255),
                            setup: { InProcessLightWriter.debugMotorMask = 0 }, buzz: { i in
                                for k in 0..<5 { DispatchQueue.main.asyncAfter(deadline: .now() + Double(k) * 0.1) { writer.vibrate(intensity: i, durationMs: 60) } }
                            }),
                    Variant(name: "7 purple: Apple light write right before", color: (170, 0, 255),
                            setup: {}, buzz: { i in
                                pad?.light?.color = GCColor(red: 0.67, green: 0, blue: 1)
                                writer.vibrate(intensity: i, durationMs: 500)
                            }),
                    Variant(name: "8 pink: 1500 ms long", color: (255, 60, 160),
                            setup: {}, buzz: { i in writer.vibrate(intensity: i, durationMs: 1500) }),
                    Variant(name: "9 white: Apple haptics (reference, repaints light)", color: (255, 255, 255),
                            setup: {}, buzz: { i in
                                if let pad { FeedbackService.shared.vibrateViaHaptics(controller: pad, intensity: i, durationMs: 500) }
                                // The engine must not outlive the buzz: while one exists the
                                // system holds the pad's output stream and flattens our motors.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { FeedbackService.shared.clearHapticEngines() }
                            }),
                    Variant(name: "10 teal: shipped path again (control)", color: (0, 180, 160),
                            setup: { InProcessLightWriter.debugVibrationMode = 0; InProcessLightWriter.debugMotorMask = 0 }, buzz: plain),
                ]
                var key = "Each variant: colour, then 100% for the buzz, then 20%. Variants 3.6 s apart.\n"
                for (n, v) in variants.enumerated() {
                    let t0 = Double(n) * (v.name.hasPrefix("8") ? 4.6 : 3.6)
                    key += v.name + "\n"
                    DispatchQueue.main.asyncAfter(deadline: .now() + t0) { NSLog("[RIG] %@", v.name); v.setup(); writer.startHold(red: v.color.0, green: v.color.1, blue: v.color.2) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + t0 + 0.7) { v.buzz(1.0) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + t0 + 2.0) { v.buzz(0.2) }
                }
                let total = Double(variants.count) * 3.6 + 2.5
                DispatchQueue.main.asyncAfter(deadline: .now() + total) {
                    InProcessLightWriter.debugVibrationMode = 0; InProcessLightWriter.debugMotorMask = 0
                    NSLog("[RIG] done")
                }
                try? key.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rig.txt"), atomically: true, encoding: .utf8)
            }
            // `post inputconfig.debug.buzzlevel <0-100>` runs the pad's motors
            // at that strength for 700 ms through the app's own report, and
            // writes the light writer's state to tmp/light.txt, so a strength
            // that feels wrong can be measured level by level.
            .onReceive(dnc("inputconfig.debug.buzzlevel")) { note in
                // "<pct>" or "<pct> both|legacy|new" to pick the vibration flags.
                let parts = ((note.object as? String) ?? "").split(separator: " ").map(String.init)
                let pct = Int(parts.first ?? "") ?? 100
                if pct < 0 {
                    // A dump only, no buzz.
                    let text = InProcessLightWriter.shared.debugState + "\n"
                    try? text.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("light.txt"), atomically: true, encoding: .utf8)
                    return
                }
                if parts.count > 1, parts[1] == "apple" {
                    // Apple's haptics engine on the same pad, for comparison.
                    if let pad = controllerService.connectedControllers.first {
                        FeedbackService.shared.vibrateViaHaptics(controller: pad, intensity: Float(max(0, min(100, pct))) / 100, durationMs: 700)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { FeedbackService.shared.clearHapticEngines() }
                    }
                    return
                }
                if parts.count > 1 {
                    InProcessLightWriter.debugVibrationMode = parts[1] == "legacy" ? 1 : (parts[1] == "new" ? 2 : 0)
                }
                InProcessLightWriter.shared.vibrate(intensity: Float(max(0, min(100, pct))) / 100, durationMs: 700)
                let text = "level=\(pct)\n" + InProcessLightWriter.shared.debugState + "\n"
                try? text.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("light.txt"), atomically: true, encoding: .utf8)
            }
            // `post inputconfig.debug.extstate` writes the keyboard / mouse
            // monitor's state to tmp/extstate.txt: permission, who holds
            // which monitor, and the live input set.
            .onReceive(dnc("inputconfig.debug.extstate")) { _ in
                let text = ExternalInputDeviceService.shared.debugState + "\n"
                try? text.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("extstate.txt"), atomically: true, encoding: .utf8)
            }
            .onReceive(dnc("inputconfig.debug.sheetsize")) { _ in
                var sheet = NSApp.keyWindow
                while let s = sheet?.attachedSheet { sheet = s }
                let size = sheet?.frame.size ?? .zero
                let text = String(format: "%.0f x %.0f\n", size.width, size.height)
                try? text.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sheetsize.txt"), atomically: true, encoding: .utf8)
            }
            // Write the 3D controller model out as a file that Quick Look
            // and any 3D tool can open, so it can be judged outside the app.
            .onReceive(dnc("inputconfig.debug.exportmodel")) { _ in
                let scene = SCNScene()
                let satin = SCNMaterial()
                satin.lightingModel = .physicallyBased
                satin.diffuse.contents = NSColor(white: 0.93, alpha: 1)
                satin.roughness.contents = 0.38
                let node = GlyphSolid.node(path: ControllerGlyphPath.bezier(), depth: 0.22, material: satin)
                scene.rootNode.addChildNode(node)
                let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                let usdz = dir.appendingPathComponent("controller.usdz")
                let ok = scene.write(to: usdz, options: nil, delegate: nil, progressHandler: nil)
                let stl = dir.appendingPathComponent("controller.stl")
                let okSTL = GlyphSolid.writeSTL(path: ControllerGlyphPath.bezier(), depth: 0.22, to: stl)
                try? "usdz=\(ok) stl=\(okSTL)\n".write(to: dir.appendingPathComponent("exportmodel.txt"), atomically: true, encoding: .utf8)
            }
            .onReceive(dnc("inputconfig.debug.panic")) { _ in
                EmergencyStopService.shared.stop(reason: .menu)
            }
            // Press and release one keyboard output by HID code ("230" for
            // right Option), the way a binding would, so the events the app
            // posts can be watched from outside without a controller.
            // Move the pointer by "dx,dy" pixels through the same path a stick
            // binding uses, or click "0" / "1" where it is, so the coordinate
            // flip can be checked from outside without a controller.
            .onReceive(dnc("inputconfig.debug.mouse")) { note in
                let parts = ((note.object as? String) ?? "").split(separator: ",").compactMap { Int($0) }
                guard parts.count == 2 else { return }
                InputSimulator.shared.moveMouse(deltaX: parts[0], deltaY: parts[1])
            }
            .onReceive(dnc("inputconfig.debug.click")) { note in
                let button = Int((note.object as? String) ?? "") ?? 0
                InputSimulator.shared.mouseButtonDown(button)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { InputSimulator.shared.mouseButtonUp(button) }
            }
            .onReceive(dnc("inputconfig.debug.key")) { note in
                guard let code = Int((note.object as? String) ?? "") else { return }
                InputSimulator.shared.keyDown(code)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { InputSimulator.shared.keyUp(code) }
            }
            .onReceive(dnc("inputconfig.debug.enginestate")) { _ in
                let running = MenuBarController.shared.debugEngineRunning
                let active = MenuBarController.shared.debugActivePresetName ?? "none"
                let held = InputSimulator.shared.debugHeldKeyCount
                let report = DebugStateReport.text(service: controllerService, running: running,
                                                   active: active, held: held)
                try? report.write(to: URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("enginestate.txt"),
                                  atomically: true, encoding: .utf8)
            }
            .onReceive(dnc("inputconfig.debug.capture")) { note in
                // In-process render of the frontmost sheet or window for
                // layout checks; "<name>-full" renders the whole scrolled
                // document. Needs no screen-recording grant.
                let name = (note.object as? String) ?? "icapture"
                let win = NSApp.windows.first { $0.isVisible && $0.attachedSheet != nil }?.attachedSheet
                    ?? NSApp.keyWindow ?? NSApp.mainWindow
                var target = win?.contentView
                if name.hasSuffix("-full"), let root = target {
                    func scrolls(_ v: NSView) -> [NSScrollView] {
                        (v as? NSScrollView).map { [$0] } ?? [] + v.subviews.flatMap(scrolls)
                    }
                    if let doc = scrolls(root).max(by: { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) })?.documentView {
                        target = doc
                    }
                }
                guard let view = target,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name + ".png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
        #else
        content
        #endif
    }

    #if DEBUG
    private func dnc(_ name: String) -> NotificationCenter.Publisher {
        // Distributed notifications are held back for an app that is not in
        // front unless the observer asks for immediate delivery, which the
        // Combine publisher cannot. The relay registers each hook name once
        // with `.deliverImmediately` and re-posts it in-process, so the
        // hooks keep working while another app is frontmost.
        DebugHookRelay.shared.ensure(name)
        return NotificationCenter.default.publisher(for: Notification.Name(name))
    }
    private func preset(_ note: Notification) -> Preset? {
        (note.object as? String).flatMap { n in
            presetStore.presets.first(where: { $0.name == n })
        }
    }
    private func selected() -> Preset? {
        selectedPresetId.flatMap { id in presetStore.presets.first(where: { $0.id == id }) }
    }
    private func closeSheets() {
        editingPreset = nil
        ReviewPromptService.shared.showPrompt = false
        showingSmartMaker = false
        showingStats = false
        settingsSheetTab = nil
        showingMotion = false
        showingTouchpad = false
        presentedDemoKind = nil
    }
    #endif
}

// MARK: - Debug marketing state (drives sub-views into capture-ready states)

#if DEBUG
/// A tiny shared, DEBUG-only observable that the marketing capture pipeline
/// toggles via DistributedNotificationCenter to put deep sub-views (the
/// binding editor's advanced options, the visualizer's edit-layout mode, the
/// One-Stick Driving arena) into a screenshot-ready state without clicking.
import Combine
@MainActor
final class DebugMarketing: ObservableObject {
    static let shared = DebugMarketing()
    @Published var expandOptions = false
    @Published var editLayout = false
    @Published var oneStick = false
    @Published var fakeController = false
    @Published var fakePress = false
    @Published var noFree = false
    @Published var vizScale: Double?
    private init() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("inputconfig.debug.fakecontroller"), object: nil, queue: .main) { [weak self] _ in
            self?.fakeController.toggle()
        }
        dnc.addObserver(forName: .init("inputconfig.debug.zoom"), object: nil, queue: .main) { [weak self] note in
            if let v = (note.object as? String).flatMap(Double.init) { self?.vizScale = v }
        }
        dnc.addObserver(forName: .init("inputconfig.debug.expandOptions"), object: nil, queue: .main) { [weak self] _ in
            self?.expandOptions.toggle()
        }
        dnc.addObserver(forName: .init("inputconfig.debug.editLayout"), object: nil, queue: .main) { [weak self] _ in
            self?.editLayout.toggle()
        }
        dnc.addObserver(forName: .init("inputconfig.debug.oneStick"), object: nil, queue: .main) { [weak self] _ in
            self?.oneStick.toggle()
        }
        // Live-usage pictures for the Mac-input visualizers:
        //   fakeext "<spec>"   light keys / mouse inputs for 8 s (see debugMark)
        //   swipe              start or stop a synthetic finger swipe on the pad
        //   pointer "fx fy"    warp the real pointer to a fraction of the main display
        dnc.addObserver(forName: .init("inputconfig.debug.fakeext"), object: nil, queue: .main) { note in
            ExternalInputDeviceService.shared.debugMark(spec: (note.object as? String) ?? "", seconds: 8)
        }
        dnc.addObserver(forName: .init("inputconfig.debug.swipe"), object: nil, queue: .main) { _ in
            TouchpadService.shared.debugSwipeStart = TouchpadService.shared.debugSwipeStart == nil ? Date() : nil
        }
        dnc.addObserver(forName: .init("inputconfig.debug.fakepress"), object: nil, queue: .main) { [weak self] _ in
            self?.fakePress.toggle()
        }
        dnc.addObserver(forName: .init("inputconfig.debug.nofree"), object: nil, queue: .main) { [weak self] _ in
            self?.noFree.toggle()
        }
        dnc.addObserver(forName: .init("inputconfig.debug.faketap"), object: nil, queue: .main) { _ in
            ChassisTapService.shared.debugInjectDoubleTap()
        }
        dnc.addObserver(forName: .init("inputconfig.debug.fakemidi"), object: nil, queue: .main) { _ in
            MIDIInputService.shared.debugToggleFakeInstrument()
        }
        dnc.addObserver(forName: .init("inputconfig.debug.pointer"), object: nil, queue: .main) { note in
            let parts = ((note.object as? String) ?? "").split(separator: " ").compactMap { Double($0) }
            guard parts.count == 2, let screen = NSScreen.screens.first else { return }
            let f = screen.frame
            CGWarpMouseCursorPosition(CGPoint(x: f.origin.x + f.width * parts[0], y: f.height * parts[1]))
        }
    }
}
#endif

extension View {
    /// DEBUG-only: expands this binding row's advanced options when the
    /// marketing pipeline toggles DebugMarketing.expandOptions. No-op in Release.
    @ViewBuilder func debugExpandOptions(_ showAdvanced: Binding<Bool>) -> some View {
        #if DEBUG
        onReceive(DebugMarketing.shared.$expandOptions) { if $0 { showAdvanced.wrappedValue = true } }
        #else
        self
        #endif
    }

    /// DEBUG-only: engages the visualizer's Edit Layout mode on toggle.
    @ViewBuilder func debugEditLayout(_ editMode: Binding<Bool>) -> some View {
        #if DEBUG
        onReceive(DebugMarketing.shared.$editLayout) { editMode.wrappedValue = $0 }
        #else
        self
        #endif
    }

    /// DEBUG-only: expands and enables the One-Stick Driving section + arena.
    @ViewBuilder func debugOneStick(expanded: Binding<Bool>, enable: Binding<Bool>) -> some View {
        #if DEBUG
        onReceive(DebugMarketing.shared.$oneStick) {
            if $0 { expanded.wrappedValue = true; enable.wrappedValue = true }
        }
        #else
        self
        #endif
    }

    /// DEBUG-only: injects / removes the two synthetic marketing controllers so
    /// captures show a populated sidebar and visualizer with no hardware.
    @ViewBuilder func debugFakeController(_ service: GameControllerService) -> some View {
        #if DEBUG
        onReceive(DebugMarketing.shared.$fakeController) { service.setMarketingFakeControllers($0) }
        .onReceive(DebugMarketing.shared.$fakePress) { service.marketingFakePress = $0 }
        #else
        self
        #endif
    }

    /// DEBUG-only: sets the live visualizer's zoom for marketing captures.
    @ViewBuilder func debugVizZoom(_ scale: Binding<Double>) -> some View {
        #if DEBUG
        onReceive(DebugMarketing.shared.$vizScale) { if let v = $0 { scale.wrappedValue = v } }
        #else
        self
        #endif
    }

    /// DEBUG-only: presents the deadzone-calibration and one-stick-driving
    /// views as standalone sheets for marketing capture. No-op in Release.
    @ViewBuilder func debugCaptureSheets() -> some View {
        #if DEBUG
        modifier(DebugCaptureSheets())
        #else
        self
        #endif
    }
}

#if DEBUG
/// DEBUG-only: drives the deadzone calibrator (joystick axis 0, trigger axis 4)
/// and the One-Stick Driving arena into standalone sheets via distributed
/// notifications, so marketing captures don't depend on fragile clicks.
///   inputconfig.debug.deadzone <axisIndex>   0/2 = stick, 4/5 = trigger
///   inputconfig.debug.drive                  one-stick driving arena
struct DebugCaptureSheets: ViewModifier {
    @State private var deadzoneAxis: Int?
    @State private var dz: Double = 0.18
    @State private var odz: Double = 0.9
    @State private var showDrive = false
    @State private var showScreenRegions = false
    @State private var driveCfg: DriveConfig? = {
        var c = DriveConfig(); c.enabled = true; return c
    }()

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(get: { deadzoneAxis != nil },
                                        set: { if !$0 { deadzoneAxis = nil } })) {
                if let ax = deadzoneAxis {
                    // Present exactly as the shipping path in BindingRowView does:
                    // no forced frame, so the sheet hugs its content. A
                    // minHeight here padded the sheet ~100pt taller than the
                    // content and every captured screenshot showed dead space
                    // that does not exist in the real app.
                    DeadzoneCalibrationView(axisIndex: ax, deadzone: $dz, outerDeadzone: $odz,
                                            isInverted: false, onClose: { deadzoneAxis = nil })
                        .glassBackground()
                }
            }
            .sheet(isPresented: $showScreenRegions) {
                CursorRegionsView().glassBackground()
            }
            .onReceive({ () -> NotificationCenter.Publisher in
                DebugHookRelay.shared.ensure("inputconfig.debug.screenregions")
                return NotificationCenter.default.publisher(for: Notification.Name("inputconfig.debug.screenregions"))
            }()) { _ in showScreenRegions = true }
            .sheet(isPresented: $showDrive) {
                // A ScrollView has no intrinsic height, so this one genuinely
                // needs a minHeight; without it the sheet collapses to a
                // sliver. Only the deadzone sheet was wrongly forced taller
                // than its content.
                ScrollView { DriveModeSection(driveConfig: $driveCfg).padding(28) }
                    .frame(minWidth: 760, minHeight: 720)
                    // Marketing capture only: suppress the macOS keyboard focus
                    // ring the sheet auto-draws on the disclosure control, which
                    // showed up as a stray bordered box over the section title.
                    .focusEffectDisabled()
                    .glassBackground()
            }
            // The close hook reaches these sheets too; they live here, not
            // on ContentView, so its closeSheets could not drop them.
            .onReceive(DistributedNotificationCenter.default().publisher(for: .init("inputconfig.debug.closesheets"))) { _ in
                deadzoneAxis = nil
                showDrive = false
                showScreenRegions = false
            }
            .onReceive(DistributedNotificationCenter.default().publisher(for: .init("inputconfig.debug.deadzone"))) { note in
                deadzoneAxis = (note.object as? String).flatMap { Int($0) } ?? 0
            }
            .onReceive(DistributedNotificationCenter.default().publisher(for: .init("inputconfig.debug.drive"))) { _ in
                showDrive = true
            }
    }
}
#endif

// MARK: - Folder outline (sidebar)

/// Which part of a folder's outline a List row draws.
enum FolderOutlineRole { case single, top, middle, bottom }

/// Passed down a top-level folder's rows: the folder's color and which row
/// closes the box.
/// A wrapping row of views, each line centerd. Lines break where the next
/// view would not fit, so buttons move down instead of squeezing.
struct CenteredFlow: Layout {
    var spacing: CGFloat = 10
    /// Rows are centered by default; `.leading` lines them up on the left.
    var alignment: HorizontalAlignment = .center

    private func lines(for subviews: Subviews, width: CGFloat) -> [[Int]] {
        var lines: [[Int]] = [[]]
        var x: CGFloat = 0
        for (i, s) in subviews.enumerated() {
            let w = s.sizeThatFits(.unspecified).width
            if x + w > width, !lines[lines.count - 1].isEmpty {
                lines.append([]); x = 0
            }
            lines[lines.count - 1].append(i)
            x += w + spacing
        }
        return lines
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width + spacing }
        var height: CGFloat = 0
        for line in lines(for: subviews, width: width) {
            height += line.map { subviews[$0].sizeThatFits(.unspecified).height }.max() ?? 0
            height += spacing
        }
        return CGSize(width: width, height: max(0, height - spacing))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(for: subviews, width: bounds.width) {
            let sizes = line.map { subviews[$0].sizeThatFits(.unspecified) }
            let lineWidth = sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, line.count - 1))
            let lineHeight = sizes.map(\.height).max() ?? 0
            var x = alignment == .leading ? bounds.minX : bounds.minX + (bounds.width - lineWidth) / 2
            for (k, i) in line.enumerated() {
                subviews[i].place(at: CGPoint(x: x, y: y + (lineHeight - sizes[k].height) / 2),
                                  proposal: ProposedViewSize(sizes[k]))
                x += sizes[k].width + spacing
            }
            y += lineHeight + spacing
        }
    }
}

/// A horizontal bracket that spans its width with a title sitting in the
/// middle of the bar: a hairline out to each end, a short tick turned down
/// at both ends toward whatever it groups. Grey, matching the caption text.
struct BracketHeader: View {
    let title: String
    var font: Font = .caption.weight(.semibold)
    private let tick: CGFloat = 8
    private let radius: CGFloat = 6
    private let gap: CGFloat = 10

    var body: some View {
        HStack(spacing: gap) {
            arm(leading: true)
            Text(title)
                .font(font)
                .foregroundStyle(.secondary)
                .fixedSize()
            arm(leading: false)
        }
        .frame(height: tick * 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }

    /// One half of the bar: the line along the top edge, and the tick at
    /// the outer end pointing down.
    private func arm(leading: Bool) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            // The bar runs through the title's centre line; the ticks
            // hang below it.
            let y = (geo.size.height / 2).rounded() + 0.5
            // The corner where the bar turns down is a quarter arc.
            let r = min(radius, tick)
            Path { p in
                if leading {
                    p.move(to: CGPoint(x: 0.5, y: y + tick))
                    p.addLine(to: CGPoint(x: 0.5, y: y + r))
                    p.addArc(center: CGPoint(x: 0.5 + r, y: y + r), radius: r,
                             startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
                    p.addLine(to: CGPoint(x: w, y: y))
                } else {
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: w - 0.5 - r, y: y))
                    p.addArc(center: CGPoint(x: w - 0.5 - r, y: y + r), radius: r,
                             startAngle: .degrees(270), endAngle: .degrees(360), clockwise: false)
                    p.addLine(to: CGPoint(x: w - 0.5, y: y + tick))
                }
            }
            .stroke(Color.secondary.opacity(0.55), lineWidth: 1)
        }
        .frame(maxWidth: .infinity)
    }
}

struct FolderOutlineContext {
    let color: Color
    let lastRowID: AnyHashable
}

/// One row's share of the folder outline: a faint tinted fill and a hairline
/// on the open edges, rounded at the folder's top and bottom corners. Rows
/// are contiguous cells, so the pieces meet into one box.
struct FolderOutlineSegment: View {
    let role: FolderOutlineRole
    let color: Color
    private let radius: CGFloat = 8
    /// 8 pt inside the cell on both sides. The list itself is padded 12 pt
    /// on the left (see `sidebarView`), so the line lands 20 pt from the
    /// window edge, the same as its right edge has to the panel's divider
    /// (8 pt to the scroll bar, then the bar).
    private let insetLeading: CGFloat = 0
    private let insetTrailing: CGFloat = 4.5
    /// Breathing room above a folder's top edge and below its bottom edge,
    /// so consecutive folders never touch. The bottom gap is the space
    /// between the last row's text and the line, plus the space to the next
    /// folder; keep the line clear of the row's text.
    private let gapTop: CGFloat = 3
    private let gapBottom: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width - insetLeading - insetTrailing
            let top: CGFloat = (role == .top || role == .single) ? gapTop : 0
            let bottom: CGFloat = (role == .bottom || role == .single) ? gapBottom : 0
            let h = geo.size.height - top - bottom
            edges(w: w, h: h)
                .stroke(color.opacity(0.18), lineWidth: 1)
                .frame(width: w, height: h)
                .offset(x: insetLeading, y: top)
        }
    }

    /// The outline's open path for this role; corners are quarter arcs so
    /// the top and bottom rows round exactly like a rounded rectangle would.
    private func edges(w: CGFloat, h: CGFloat) -> Path {
        var p = Path()
        let r = min(radius, h / 2)
        // Half-pixel alignment keeps the hairline crisp on the cell edge.
        let x0: CGFloat = 0.5, x1 = w - 0.5
        switch role {
        case .single:
            p.addRoundedRect(in: CGRect(x: x0, y: 0.5, width: x1 - x0, height: h - 1), cornerSize: CGSize(width: r, height: r))
        case .top:
            p.move(to: CGPoint(x: x0, y: h))
            p.addLine(to: CGPoint(x: x0, y: r + 0.5))
            p.addArc(center: CGPoint(x: x0 + r, y: r + 0.5), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            p.addLine(to: CGPoint(x: x1 - r, y: 0.5))
            p.addArc(center: CGPoint(x: x1 - r, y: r + 0.5), radius: r, startAngle: .degrees(270), endAngle: .degrees(360), clockwise: false)
            p.addLine(to: CGPoint(x: x1, y: h))
        case .middle:
            p.move(to: CGPoint(x: x0, y: 0)); p.addLine(to: CGPoint(x: x0, y: h))
            p.move(to: CGPoint(x: x1, y: 0)); p.addLine(to: CGPoint(x: x1, y: h))
        case .bottom:
            p.move(to: CGPoint(x: x0, y: 0))
            p.addLine(to: CGPoint(x: x0, y: h - r - 0.5))
            p.addArc(center: CGPoint(x: x0 + r, y: h - r - 0.5), radius: r, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
            p.addLine(to: CGPoint(x: x1 - r, y: h - 0.5))
            p.addArc(center: CGPoint(x: x1 - r, y: h - r - 0.5), radius: r, startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
            p.addLine(to: CGPoint(x: x1, y: 0))
        }
        return p
    }
}


/// Holder for per-slot visualizer control objects; see `visualizerControls`.
final class VisualizerControlBox {
    var states: [Int: VisualizerControlState] = [:]
}


/// The two first-run sheets, hung off the main view as one modifier so the
/// view's long modifier chain does not grow past what the type checker
/// will take.
private struct FirstRunSheets: ViewModifier {
    @Binding var showingWelcome: Bool
    @Binding var showingAccessibility: Bool
    let welcome: () -> AnyView
    let accessibilityIntro: () -> AnyView

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showingWelcome) { welcome().glassBackground() }
            .sheet(isPresented: $showingAccessibility) { accessibilityIntro().glassBackground() }
    }
}


#if DEBUG
/// What the app is seeing from the hardware, for the debug state hook.
/// Kept out of the view so the hook chain stays type-checkable.
@MainActor
enum DebugStateReport {
    static func text(service svc: GameControllerService, running: Bool,
                     active: String, held: Int) -> String {
        var out = "running=\(running) active=\(active) heldKeys=\(held)\n"
        out += "GCControllers: \(svc.connectedControllers.map { $0.vendorName ?? "?" })\n"
        for (slot, info) in svc.controllerDetails.sorted(by: { $0.key < $1.key }) {
            out += "slot \(slot) = \(info.name), buttons \(info.buttonCount), axes \(info.axisCount), motion \(info.supportsMotion), touchpad \(info.hasTouchpad)\n"
        }
        // Raw sensor truth, straight off GCMotion: whether the sensors are
        // switched on at all, and the unfiltered rotation rate. The live
        // rows below hide anything under 0.02, so a dead sensor and a
        // resting controller look identical there.
        for (slot, controller) in svc.connectedControllers.enumerated() {
            guard let m = controller.motion else { continue }
            if m.hasGravityAndUserAcceleration {
                // Gravity on a resting controller names the frame: the axis
                // carrying -1 is the one pointing up out of the face, which
                // is the axis a left / right turn rotates around.
                out += String(format: "gravity slot %d: x=%+.3f y=%+.3f z=%+.3f\n",
                              slot, m.gravity.x, m.gravity.y, m.gravity.z)
            }
            if m.hasAttitude {
                // Attitude is referenced to a frame whose Z is the azimuth
                // (up), per GCMotion.h. Rotating that reference up vector
                // back into the controller's own axes says which of the
                // controller's axes is currently pointing at the sky, which
                // is the axis a left / right turn rotates around.
                let q = m.attitude
                let (x, y, z, w) = (q.x, q.y, q.z, q.w)
                let ux = 2 * (x * z - w * y)
                let uy = 2 * (y * z + w * x)
                let uz = 1 - 2 * (x * x + y * y)
                out += String(format: "attitude slot %d: q=(%+.3f %+.3f %+.3f %+.3f) up-in-controller x=%+.3f y=%+.3f z=%+.3f\n",
                              slot, x, y, z, w, ux, uy, uz)
            }
            out += String(format: "motion slot %d: active=%@ manual=%@ hasRate=%@ rate x=%+.3f y=%+.3f z=%+.3f samples=%d\n",
                          slot, m.sensorsActive ? "yes" : "NO",
                          m.sensorsRequireManualActivation ? "yes" : "no",
                          m.hasRotationRate ? "yes" : "no",
                          m.rotationRate.x, m.rotationRate.y, m.rotationRate.z,
                          svc.debugGyroSampleCount(for: controller))
            let pk = svc.debugTakePeakRate(for: controller)
            let acc = m.acceleration
            out += String(format: "  peak |rate| since last read x=%.2f y=%.2f z=%.2f rad/s | raw accel x=%+.3f y=%+.3f z=%+.3f g\n",
                          pk.x, pk.y, pk.z, acc.x, acc.y, acc.z)
            out += "  " + svc.debugPitchFusion(for: controller) + "\n"
        }
        let presses = PhysicalPressLogStore.shared.recent.suffix(12)
        out += "recent physical presses (\(PhysicalPressLogStore.shared.recent.count) logged):\n"
        for p in presses {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            out += "  \(f.string(from: p.at))  \(p.name) -> index \(p.mappedIndex.map(String.init) ?? "-") on slot \(p.slot)\n"
        }
        // Touchpad truth: finger positions as the service holds them, the
        // regions it is testing against, and which it calls pressed.
        let tp = TouchpadService.shared
        let (regs, pressed) = tp.snapshotRegions()
        func fmt(_ p: (x: Int, y: Int)?) -> String { p.map { String(format: "(%d,%d)", $0.x, $0.y) } ?? "up" }
        out += "touchpad: f0 \(fmt(tp.currentPosition(finger: 0))) f1 \(fmt(tp.currentPosition(finger: 1))) regions \(regs.count) pressed \(pressed.count) gcFeed=\(tp.isFedByGameController) samples=\(tp.gameControllerSampleCount)\n"
        for r in regs {
            out += String(format: "  region %@ x %.2f-%.2f y %.2f-%.2f %@\n", r.name, r.minX, r.maxX, r.minY, r.maxY, pressed.contains(r.id) ? "PRESSED" : "")
        }
        // What the automatic layout would offer for each slot right now.
        for slot in svc.controllerDetails.keys.sorted() {
            let caps = ControllerScaffold.capabilities(service: svc, slot: slot, inputKind: .auto, purpose: .layout)
            out += "auto layout slot \(slot): sticks \(caps.sticks.map(\.3)) triggers=\(caps.triggers) dpad=\(caps.dpad) touchpad=\(caps.touchpad) gyro=\(caps.gyro)\n"
            out += "  buttons: " + caps.buttons.map { "\($0.0):\($0.1)" }.joined(separator: ", ") + "\n"
            if !caps.extraAxes.isEmpty { out += "  extra axes: \(caps.extraAxes.map(\.1))\n" }
        }
        for (slot, note) in svc.debugTouchpadInstall.sorted(by: { $0.key < $1.key }) {
            out += "  touchpad install slot \(slot): \(note)\n"
        }
        for (slot, controller) in svc.connectedControllers.enumerated() {
            if let ds = controller.extendedGamepad as? GCDualSenseGamepad {
                out += String(format: "  live touchpadPrimary slot %d: x=%+.3f y=%+.3f handler=%@\n", slot, ds.touchpadPrimary.xAxis.value, ds.touchpadPrimary.yAxis.value, ds.touchpadPrimary.valueChangedHandler != nil ? "set" : "NIL")
            }
        }
        for (slot, controller) in svc.connectedControllers.enumerated() {
            if let m = controller.motion, m.hasGravityAndUserAcceleration {
                out += String(format: "  gravity slot %d: x=%+.2f y=%+.2f z=%+.2f (which axis reads -1 is 'up' when the pad lies flat)\n", slot, m.gravity.x, m.gravity.y, m.gravity.z)
            } else if let m = controller.motion {
                out += String(format: "  accel slot %d: x=%+.2f y=%+.2f z=%+.2f\n", slot, m.acceleration.x, m.acceleration.y, m.acceleration.z)
            }
        }
        out += "live consumers: \(svc.debugLiveConsumers)\n"
        for (slot, st) in svc.currentStates.sorted(by: { $0.key < $1.key }) {
            let pressed = st.buttons.filter { $0.value > 0.5 }.keys.sorted()
            let axes = st.axes.filter { abs($0.value) > 0.15 }
                .map { "a\($0.key)=" + String(format: "%.2f", $0.value) }
                .sorted()
            let motion = st.motion.filter { abs($0.value) > 0.02 }
                .map { "\($0.key)=" + String(format: "%.2f", $0.value) }.sorted()
            out += "live slot \(slot): pressed \(pressed) axes \(axes.joined(separator: " "))"
            out += motion.isEmpty ? " motion none\n" : " motion \(motion.joined(separator: " "))\n"
        }
        return out
    }
}
#endif


/// `post inputconfig.debug.closesheets` also dismisses What's New.
private struct DebugCloseWhatsNew: ViewModifier {
    @Binding var showing: Bool
    func body(content: Content) -> some View {
        #if DEBUG
        content.onReceive(DistributedNotificationCenter.default().publisher(for: .init("inputconfig.debug.closesheets"))) { _ in
            showing = false
        }
        #else
        content
        #endif
    }
}
