import SwiftUI
import SceneKit
import Metal
import GameController
import UniformTypeIdentifiers

/// Notifications used by the macOS menu bar (Controller and View menus)
/// to drive UI actions on the active ContentView. Posted from
/// InputConfigMain's `.commands`; handled by `onReceive` blocks in
/// ContentView below.
extension Notification.Name {
    static let inputConfigShowStats              = Notification.Name("InputConfig.ShowStats")
    static let inputConfigOpenAbout              = Notification.Name("InputConfig.OpenAbout")
    /// A quit (or a language restart) takes every sheet down first: macOS
    /// will not quit while one is up, and SwiftUI's own sheets are not
    /// found through AppKit's attached sheet.
    static let inputConfigCloseSheetsForQuit     = Notification.Name("InputConfig.CloseSheetsForQuit")
    static let inputConfigOpenSettings           = Notification.Name("InputConfig.OpenSettings")
    /// Cmd-N and the menu bar's New Preset: make one the way the sidebar does.
    static let inputConfigNewPreset              = Notification.Name("InputConfig.NewPreset")
    static let inputConfigOpenSmartMaker         = Notification.Name("InputConfig.OpenSmartMaker")
    static let inputConfigToggleActivePreset     = Notification.Name("InputConfig.ToggleActive")
    /// The Presets menu: an action on the selected preset or its folder, so
    /// everything the sidebar's right-click and ellipsis menus offer works
    /// from the keyboard and by voice. The object is a `SidebarCommand`.
    static let inputConfigSidebarCommand         = Notification.Name("InputConfig.SidebarCommand")
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
    /// Tour scrolls the preset page down to its notes.
    static let inputConfigScrollToNotes          = Notification.Name("InputConfig.ScrollToNotes")
    /// Posted at the start of a quit: drafts on the preset page commit now.
    static let inputConfigCommitDrafts           = Notification.Name("InputConfig.CommitDrafts")
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

/// Settings as a sheet, on the main window or over the open editor.
/// Done lives in a translucent footer inside the sheet rather than the
/// system confirmation bar, which draws its own opaque background and broke
/// the frosted look at the bottom of Settings.
struct SettingsSheet: View {
    let tab: SettingsView.SettingsTab
    let done: () -> Void
    @EnvironmentObject private var presetStore: PresetStore
    @EnvironmentObject private var controllerService: GameControllerService

    var body: some View {
        VStack(spacing: 0) {
            SettingsView(initialTab: tab)
                .environmentObject(presetStore)
                .environmentObject(controllerService)
            Divider()
            HStack {
                Spacer()
                Button("Done") { done() }
                    .buttonStyle(.solid)
                    .keyboardShortcut(.defaultAction)
                    .closesOnEscape { done() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(minWidth: SettingsView.preferredSize.width, minHeight: 360)
        .glassBackground()
    }
}

/// The mapping engine for views that only call it or read it in closures
/// and functions (ContentView, the binding editor). As an EnvironmentObject
/// it re-ran each of those whole bodies on every engine publish (start,
/// stop, pause, each live apply of an edit), though no body read it. A
/// class in the environment is not observed. The views that show engine
/// state keep observing it as an EnvironmentObject.
private struct UnobservedEngineKey: EnvironmentKey {
    static let defaultValue: MappingEngine? = nil
}
extension EnvironmentValues {
    var unobservedEngine: MappingEngine? {
        get { self[UnobservedEngineKey.self] }
        set { self[UnobservedEngineKey.self] = newValue }
    }
}

/// Takes the window's sheets down when the app is quitting.
private struct QuitSheetCloser: ViewModifier {
    let close: () -> Void
    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .inputConfigCloseSheetsForQuit)) { _ in close() }
    }
}

/// Opens Settings on the About tab when the Help window asks for it. Lives in
/// its own modifier because ContentView's body is already at the Swift
/// type-checker's limit; an inline onReceive here fails to compile.
private struct OpenAboutObserver: ViewModifier {
    @Binding var tab: SettingsView.SettingsTab?
    /// False while the editor or another sheet is up: a second sheet does
    /// not show over it, and the tab left set kept every later sheet,
    /// Settings included, from opening. The window still comes forward.
    let canPresent: () -> Bool
    func body(content: Content) -> some View {
        content.onReceive(
            NotificationCenter.default.publisher(for: .inputConfigOpenAbout)
        ) { _ in
            let pending = MenuBarController.takePendingMainAction(.about)
            // Settings already open on another tab moves to About.
            if canPresent() || tab != nil { tab = .about } else if pending { MenuBarController.pendingMainAction = nil }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .inputConfigOpenSettings)
        ) { _ in
            if MenuBarController.takePendingMainAction(.settings), canPresent() { tab = .general }
        }
    }
}

struct ContentView: View {
    @Environment(\.appReduceMotion) var sidebarAppReduceMotion
    @Environment(\.accessibilityReduceMotion) var sidebarSystemReduceMotion
    @Environment(\.appTextScale) var editorTextScale
    private var maxSheetWidth: CGFloat { max(900, (NSScreen.main?.visibleFrame.width ?? 1440) - 40) }
    @EnvironmentObject var presetStore: PresetStore
    @EnvironmentObject var controllerService: GameControllerService
    /// Not observed: every read is in a closure or a function, and the
    /// body only hands it on (unobservedEngine).
    @Environment(\.unobservedEngine) private var unobservedEngine
    var mappingEngine: MappingEngine { unobservedEngine! }
    @EnvironmentObject var eightBitDoDetector: EightBitDoDetector
    @ObservedObject var accessibility = AccessibilityPermissionService.shared

    /// The sidebar's selection, in an Observable object so a preset switch
    /// re-runs only the views that read the selected id (the two scopes in
    /// the body, and their content), not this whole window body with its
    /// toolbar, sheets and the developer log. Every use keeps its spelling
    /// through `selectedPresetId`. A read of it in this body (outside a
    /// SelectionScope) would bring the full re-run back on every switch.
    @State var selection = PresetSelection()
    var selectedPresetId: UUID? {
        get { selection.id }
        nonmutating set { selection.id = newValue }
    }
    /// For the sidebar List and the debug hooks, which take a Binding.
    var selectedPresetIdBinding: Binding<UUID?> { Bindable(selection).id }
    @State var showAccessibilityAlert = false
    /// A start from the global shortcut is in flight (its first-start
    /// confirmation may be up); a second press meanwhile is ignored.
    @State private var confirmingStart = false
    /// Proactive, reassuring Accessibility explainer shown on launch when the
    /// permission isn't granted yet, so people aren't left with non-working
    /// mappings just because macOS never surfaced its own prompt.
    @State var showingAccessibilityIntro = false
    /// User opt-out for the launch explainer above. The persistent banner and
    /// the on-activation alert still cover them if they later need it.
    @AppStorage("suppressAccessibilityIntro") var suppressAccessibilityIntro = false
    /// The welcome sheet has been shown once on this Mac.
    @AppStorage("InputConfig.welcomeIntroSeen") var welcomeIntroSeen = false
    @State var showingWelcomeIntro = false
    /// Shows the activity log pinned under the detail pane. On until turned
    /// off in Settings. The engine's detailed press lines, which cost CPU,
    /// follow this key only once it has been set by hand (it reads it as off
    /// when unset), so the default view stays cheap.
    @AppStorage("InputConfig.showDebugLog") private var showDebugLog = true
    @State var showingSmartMaker = false
    /// The bundle's marketing version, e.g. "1.3".
    static var currentShortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    @State var editingPreset: Preset?
    /// Name, tag and notes typed on the detail page and not saved yet;
    /// see `committed(_:)`.
    @State var pageDrafts = PresetPageDrafts()
    /// What's New popup: shown once when the app runs a version the user
    /// hasn't seen. Empty string = fresh install (stamp silently, no popup -
    /// the welcome screen already explains the app).
    /// Debug builds keep their own record. A dev build carries the version
    /// it is heading for, so on a Mac that runs both it stamped "seen" before
    /// the store update arrived and the store build's What's New never showed.
    #if DEBUG
    nonisolated static let lastSeenVersionKey = "InputConfig.lastSeenVersion.debug"
    #else
    nonisolated static let lastSeenVersionKey = "InputConfig.lastSeenVersion"
    #endif
    @AppStorage(ContentView.lastSeenVersionKey) private var lastSeenVersion: String = ""
    @AppStorage(SimpleLauncherView.enabledKey) private var simpleView = false
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
    /// Set while the quit path takes What's New down, so the release is
    /// not stamped as seen: it shows again at the next launch.
    @State private var whatsNewClosingForQuit = false
    @State var newlyCreatedPresetId: UUID?
    @State var showingImportSheet = false
    @State var presentedDemoKind: FeatureDemoKind?
    @State var showingStats: Bool = false
    var canPresentSheet: Bool { editingPreset == nil && !anotherSheetIsUp }

    /// A sheet asked for from a menu or the menu bar: only when none is up.
    private func requestSheet(_ kind: MenuBarController.PendingMainAction) {
        _ = MenuBarController.takePendingMainAction(kind)
        guard canPresentSheet else { return }
        switch kind {
        case .statistics: showingStats = true
        case .smartMaker: showingSmartMaker = true
        case .whatsNew: whatsNewSince = nil; showingWhatsNew = true
        default: break
        }
    }

    private func requestCalibration(touchpad: Bool) {
        // The touchpad is calibrated in the editor, in a group's Regions
        // section: the open editor's, else the shown or running preset's.
        if touchpad {
            if editingPreset != nil {
                ShowZonesRequest(groupIndex: 0, part: .touchpad).post()
                return
            }
            if canPresentSheet,
               let preset = presetStore.presets.first(where: { $0.id == selectedPresetId })
                    ?? presetStore.presets.first(where: { $0.isActive }) {
                let g = preset.joysticks.firstIndex { $0.bindings.contains {
                    [.touchpad, .touchpadRegion, .touchpadGesture].contains($0.input.type) } } ?? 0
                pendingEditorJump = EditorJumpTarget(joystickIndex: g, inputSerialized: "", action: .showZones(.touchpad))
                selectedPresetId = preset.id
                // The editor's Save writes its whole copy: with the page's
                // drafts in it, or it put the old name back.
                editingPreset = committed(preset)
                return
            }
        }
        guard canPresentSheet else { return }
        if touchpad { showingTouchpadCalibrationFromMenu = true } else { showingMotionCalibrationFromMenu = true }
    }

    /// Not over an open editor: closing it for the tour lost every unsaved
    /// change and left its draft regions live.
    private func requestTutorial() {
        guard !tutorialState.isActive else { return }
        guard OpenEditor.current == nil, !anotherSheetIsUp else {
            // Said and shown, not only a beep.
            let alert = NSAlert()
            alert.messageText = OpenEditor.current != nil
                ? String(localized: "Close the editor first, then start the tour.")
                : String(localized: "Close the open window first, then start the tour.")
            alert.runModal()
            return
        }
        startTutorial()
    }

    /// Every sheet this window can show, down for a quit.
    private func closeSheetsForQuit() {
        settingsSheetTab = nil
        showingStats = false
        showingSmartMaker = false
        if showingWhatsNew {
            // Forced down, not read: only Done stamps the release as seen.
            whatsNewClosingForQuit = true
            showingWhatsNew = false
        }
        showingWelcomeIntro = false
        showingAccessibilityIntro = false
        showingImportSheet = false
        presentedDemoKind = nil
        showingTrashSheet = false
        showingTouchpadCalibrationFromMenu = false
        showingMotionCalibrationFromMenu = false
        // The rest of what anotherSheetIsUp counts: left up, both terminate
        // tries were refused and a logout was told the quit was canceled.
        creatingGroupForPreset = nil
        renamingGroup = nil
        sidebarMoveTarget = nil
        showAccessibilityAlert = false
        presetPendingDelete = nil
        folderPendingDelete = nil
        confirmingEmptyTrash = false
        pendingPresetDelete = nil
        pendingFolderDelete = nil
        presetStore.importReviewQueue.removeAll()
    }

    /// What's New after an update, on the window's first appearance.
    private func showWhatsNewIfUpdated() {
        let current = Self.currentShortVersion
        // A first launch from a double-clicked preset file is still a first
        // launch: stamped now, or the next launch took it for an update,
        // skipped the Welcome for good and showed every release's notes.
        if lastSeenVersion.isEmpty && !Self.looksLikeExistingInstall { lastSeenVersion = current }
        // An opened file's review is the sheet this time; What's New
        // shows the next time the window does (the version is not
        // stamped). Both asked at once, one never showed and its flag
        // kept every later sheet from opening.
        if OpenedPresetFiles.hasPending || !presetStore.importReviewQueue.isEmpty { return }
        // The same for Settings or About asked from the menu bar or Help
        // before this window existed: that is the sheet this time.
        if MenuBarController.pendingMainAction == .settings || MenuBarController.pendingMainAction == .about { return }
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

    /// What's New closed: the version is seen, and an upgrade with
    /// Accessibility still off gets the intro that explains why no keys are
    /// sent, which waited for this sheet.
    private func afterWhatsNew() {
        if whatsNewClosingForQuit {
            whatsNewClosingForQuit = false
            return
        }
        lastSeenVersion = Self.currentShortVersion
        guard !accessibility.isTrusted, !suppressAccessibilityIntro else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if !anotherSheetIsUp, editingPreset == nil, !accessibility.isTrusted { showingAccessibilityIntro = true }
        }
    }

    /// Statistics, the maker or What's New asked for from the menu bar
    /// before this window existed.
    private func takePendingSheets() {
        for kind in [MenuBarController.PendingMainAction.statistics, .smartMaker, .whatsNew]
        where MenuBarController.pendingMainAction == kind {
            requestSheet(kind)
        }
    }

    /// True while a sheet other than the editor is up. New Preset waits
    /// for it, since a second sheet cannot show over it.
    var anotherSheetIsUp: Bool {
        showingStats || settingsSheetTab != nil || showingSmartMaker || showingWhatsNew
            || showingWelcomeIntro || showingAccessibilityIntro || showingImportSheet
            || presentedDemoKind != nil || showingTouchpadCalibrationFromMenu
            || showingMotionCalibrationFromMenu || !presetStore.importReviewQueue.isEmpty
            || creatingGroupForPreset != nil || renamingGroup != nil || sidebarMoveTarget != nil
            || showingTrashSheet || showAccessibilityAlert
            // The sidebar's own confirmations: a sheet asked for over one
            // popped up unasked after it closed.
            || presetPendingDelete != nil || folderPendingDelete != nil || confirmingEmptyTrash
            || pendingPresetDelete != nil || pendingFolderDelete != nil
    }
    /// The settings sheet, presented item-style so the tab travels WITH
    /// the presentation: nil = closed, otherwise the tab to open on.
    /// (A Bool + separate tab state raced: SwiftUI could present with the
    /// sheet content closure from the previous body pass, ignoring a tab
    /// set in the same tick.)
    @State var settingsSheetTab: SettingsView.SettingsTab? = nil
    @State var showingTouchpadCalibrationFromMenu: Bool = false
    @State var showingMotionCalibrationFromMenu: Bool = false
    /// Tracks whether the mapping engine was running when the user opened the
    /// preset editor, so we can flag that in the editor's banner and decide
    /// whether to offer to re-activate on close.
    /// Permanent deletes waiting for their confirmation.
    @State var confirmingEmptyTrash = false
    @State var pendingPresetDelete: UUID?
    @State var pendingFolderDelete: UUID?
    /// A sidebar folder waiting for Delete Folder to be confirmed.
    @State var folderPendingDelete: UUID?
    /// The preset the Quick Tour borrowed, as it was before, to put back.
    @State var tutorialPresetSnapshot: Preset?
    @Environment(\.openWindow) private var openWindow
    /// Whether outputs were already paused when the editor opened.
    @State var outputsPausedBeforeEdit = false
    /// The preset running when the editor opened: its pause comes back on
    /// close, but a preset started meanwhile starts live.
    @State private var presetRunningAtEdit: UUID?
    /// A pause still on when the editor closes (set from the menu bar or a
    /// Pause row) stays; a preset started meanwhile starts live; a running
    /// preset that the editor paused because its zones were swapped out for
    /// the edited preset's runs again.
    var pauseToRestoreAfterEdit: Bool {
        if editorPausedRunning { return outputsPausedBeforeEdit && mappingEngine.activePreset?.id == presetRunningAtEdit }
        return mappingEngine.outputsPaused && mappingEngine.activePreset?.id == presetRunningAtEdit
    }
    /// The editor paused a different running preset whose zones it swapped out.
    @State var editorPausedRunning = false
    @State var engineWasRunningBeforeEdit: Bool = false
    /// When the user clicks an input on the Live Visualizer, we stash the
    /// jump target here. The PresetEditorView sheet reads this on appear and
    /// scrolls + pulses the matching binding row.
    @State var pendingEditorJump: EditorJumpTarget?
    /// Preset queued for confirm-delete. Drives the .confirmationDialog so
    /// users can't permanently wipe a preset with a single misclick.
    @State var presetPendingDelete: Preset?
    /// Shown when the Trash disclosure in the sidebar is expanded.
    @State var showingTrashDisclosure: Bool = false
    /// Briefly set to a preset UUID when we want the sidebar row to
    /// flash. Cleared after the animation completes.
    @State var flashingPresetID: UUID?
    /// Live map of tutorial-anchor ids to their global frames. Refreshed
    /// by .onPreferenceChange so the spotlight overlay tracks UI moves.
    @State private var tutorialAnchors: [String: CGRect] = [:]
    /// Shared tutorial controller - drives both the spotlight overlay
    /// (here in the main window) and the floating tutorial card panel.
    @StateObject var tutorialState = TutorialState.shared
    /// Index of the welcome-page feature card currently being showcased
    /// by the tutorial. Drives a pulsing highlight + auto-opens its demo
    /// sheet during the "example presets" tutorial step.
    @State var tutorialFeatureSpotlight: FeatureDemoKind?

    var body: some View {
        let _ = LaunchSignpost.once("ContentView.body")
        #if DEBUG
        let _ = BodyRuns.note("ContentView")
        let _ = BodyRuns.printChangesIfAsked() ? Self._printChanges() : ()
        #endif
        NavigationSplitView {
            // The sidebar reads the selection (the List, each row's
            // highlight): it re-runs on a switch, as before; this body no
            // longer does.
            SelectionScope(selection: selection) { sidebarView }
        } detail: {
            detailView
        }
        // Simple View covers the library, so the window under it takes no
        // clicks, keyboard focus or VoiceOver.
        .disabled(simpleView)
        .accessibilityHidden(simpleView)
        .toolbar(simpleView ? .hidden : .automatic, for: .windowToolbar)
        .overlay {
            if simpleView {
                SimpleLauncherView(onToggle: { togglePreset($0) }, onLeave: { simpleView = false })
            }
        }
        // The focus ring stays on for the window: keyboard and Full Keyboard
        // Access users need to see where they are. Only the toolbar buttons,
        // which keep focus after a click, drop it.
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
                .focusRingForKeyboardUsers()
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
                .focusRingForKeyboardUsers()
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
            Button("Open Accessibility Settings") { accessibility.requestAccess() }
            Button("Not Now", role: .cancel) { }
        } message: {
            Text("To send the keyboard and mouse actions in this preset, turn on InputConfig under System Settings → Privacy & Security → Accessibility. Your mappings will start working as soon as you do.")
        }
        .sheet(isPresented: $showingStats) {
            StatsView()
                .glassBackground(windowTint: 0.38)
        }
        .modifier(ReviewPromptPresenter())
        .sheet(isPresented: $showingSmartMaker) {
            SmartPresetMakerView { preset in
                revealPreset(preset.id)
                announceOpened(preset)
                flashingPresetID = preset.id
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
            SettingsSheet(tab: tab) { settingsSheetTab = nil }
                .environmentObject(presetStore)
                .environmentObject(controllerService)
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
        .confirmationDialog(
            "Delete preset?",
            isPresented: Binding(
                get: { presetPendingDelete != nil },
                set: { if !$0 { presetPendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: presetPendingDelete
        ) { preset in
            Button("Delete \"\(preset.shownName)\"", role: .destructive) {
                performPendingDelete()
            }
            Button("Cancel", role: .cancel) {
                presetPendingDelete = nil
            }
        } message: { preset in
            Text("\"\(preset.shownName)\" will be moved to the Trash at the bottom of the sidebar. Restore it from there; the Trash keeps the last 60 presets.")
        }
        .modifier(OpenAboutObserver(tab: $settingsSheetTab,
                                    canPresent: { editingPreset == nil && !anotherSheetIsUp }))
        .modifier(QuitSheetCloser(close: closeSheetsForQuit))
        .modifier(TutorialPlumbing(
            state: tutorialState,
            anchors: $tutorialAnchors,
            onTutorialEnded: handleTutorialEnded
        ))
        // Each sheet only when none is up: a second sheet does not show,
        // and its flag left set kept every later sheet from opening.
        .onReceive(NotificationCenter.default.publisher(for: .inputConfigShowStats)) { _ in
            requestSheet(.statistics)
        }
        .onReceive(NotificationCenter.default.publisher(for: .inputConfigOpenSmartMaker)) { _ in
            requestSheet(.smartMaker)
        }
        .onReceive(NotificationCenter.default.publisher(for: .inputConfigToggleActivePreset)) { _ in
            // Toggle the sidebar-selected preset, if any.
            if let pid = selectedPresetId,
               let preset = presetStore.presets.first(where: { $0.id == pid }) {
                togglePreset(preset)
            } else if let running = presetStore.presets.first(where: { $0.isActive }) {
                // Nothing selected (the window was closed and made again):
                // the running preset is the one to stop.
                togglePreset(running)
            } else {
                NSSound.beep()
                AccessibilityNotification.Announcement(String(localized: "No preset selected")).post()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .inputConfigOpenTouchpadCalibration)) { _ in
            requestCalibration(touchpad: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .inputConfigOpenMotionCalibration)) { _ in
            requestCalibration(touchpad: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .inputConfigStartTutorial)) { _ in
            requestTutorial()
        }
        .onChange(of: tutorialState.isActive) { _, active in
            // When the tutorial ends (Finish, Skip, or natural end),
            // restore the controller list so the synthetic Edge entry
            // disappears alongside the tutorial.
            if !active && controllerService.tutorialFakeControllerActive {
                controllerService.disableTutorialFakeController()
            }
        }
        // A preset started while the editor is open on another one (a hotkey,
        // auto-switch, the menu bar) waits if it reads zones, since the
        // editor holds the other preset's zones in the shared lists.
        .modifier(ActivePresetWatch(id: presetStore.activePresetId, action: pauseZonePresetStartedBehindEditor))
        .onChange(of: editingPreset?.id) { _, newID in
            // A running preset keeps working while the editor is open (the
            // editor's bar warns and offers Deactivate); it is no longer
            // paused. Only a Scan holds outputs back while it listens
            // (editorScanGate, which runs with the override on). A pause the
            // user set from the menu bar stays, and survives the editor.
            if newID != nil {
                engineWasRunningBeforeEdit = mappingEngine.isRunning
                // A pause left from an earlier run counts only while something runs.
                outputsPausedBeforeEdit = mappingEngine.isRunning && mappingEngine.outputsPaused
                presetRunningAtEdit = mappingEngine.activePreset?.id
                mappingEngine.editorPointerPassthrough = !outputsPausedBeforeEdit
                mappingEngine.editorOpen = true
                // Editing a different preset swaps the shared zone and region
                // lists over to it, so a running preset that reads zones would
                // misfire: that one is paused while the editor is open, as
                // before (the pointer and navigation keys still pass).
                editorPausedRunning = mappingEngine.isRunning && presetRunningAtEdit != newID
                    && (mappingEngine.activePreset.map(Self.readsRegions) ?? false)
                let pause = outputsPausedBeforeEdit || editorPausedRunning
                mappingEngine.editorOverride = !pause
                mappingEngine.outputsPaused = pause
            } else {
                mappingEngine.editorPointerPassthrough = false
                mappingEngine.editorOpen = false
                mappingEngine.outputsPaused = pauseToRestoreAfterEdit
            }
        }
        .sheet(isPresented: $showingWhatsNew, onDismiss: afterWhatsNew) {
            WhatsNewView(since: whatsNewSince)
                .glassBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: .inputConfigNewPreset)) { _ in
            // Selected and open in the editor, and dropped again on Cancel,
            // instead of an empty "New Preset" left in the library. Not
            // over an editor that is already open.
            // The pending action is taken first, so one refused here does
            // not linger and make a preset unasked the next time the
            // window appears. Over another sheet the editor could not show,
            // and the running preset's outputs would pause behind it.
            let wanted = MenuBarController.takePendingMainAction(.newPreset)
            guard wanted, editingPreset == nil, !anotherSheetIsUp else { return }
            createNewPreset()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: MenuBarController.showWhatsNewNotification)) { _ in
            // Opened by hand from the menu bar: show this release's notes.
            requestSheet(.whatsNew)
        }
        .onAppear(perform: showWhatsNewIfUpdated)
        .sheet(item: $editingPreset, onDismiss: handleEditorDismiss) { preset in
            PresetEditorView(preset: preset,
                             enginePausedNotice: engineWasRunningBeforeEdit,
                             pendingJump: pendingEditorJump,
                             onToggleActive: { toggleEditedPreset($0) }) { updated in
                newlyCreatedPresetId = nil // Saved successfully, don't delete
                // Saving posts presetSavedNotification, which reloads the
                // engine when this is the running preset. A second start
                // here restarted it twice and counted two activations.
                presetStore.savePreset(updated)
                editingPreset = nil
            }
            .environmentObject(controllerService)
            .environmentObject(mappingEngine)
            .environment(\.unobservedEngine, mappingEngine)
            .environmentObject(presetStore)
            // 1240, not 1150: the sheet takes exactly its minimum (the rows
            // scroll, so nothing reports an ideal width), and MIDI rows need
            // about 70 pt more than key rows. At 1150 every row in a MIDI
            // preset ran past both edges of the sheet.
            // Wider at a larger Text Size, by what the scaled columns add.
            // Never wider than the screen: at Huge on a 13-inch laptop the
            // sheet ran off both edges and Save could not be reached.
            .frame(minWidth: min(1240 + BindingRowView.extraEditorWidth(scale: editorTextScale), maxSheetWidth),
                   idealWidth: min(1340 + BindingRowView.extraEditorWidth(scale: editorTextScale), maxSheetWidth),
                   maxWidth: .infinity,
                   // Never taller than the screen either: at 700 on a
                   // 13-inch laptop with the Dock shown, Save sat under it.
                   minHeight: Metrics.sheetHeight(ideal: 700, floor: 560),
                   idealHeight: Metrics.sheetHeight(ideal: 800, floor: 560),
                   maxHeight: .infinity)
            // Every size limit is given, so SwiftUI never measures the rows
            // to size the sheet: it measured all of them, every row's text
            // included, on each update to work out the window's limits.
            .glassBackground()
        }
        .onAppear {
            LaunchSignpost.once("ContentView.onAppear")
            // Hand the menu bar a way to reopen this window after it closes.
            MenuBarController.shared.openMainScene = { [openWindow] in openWindow(id: "main") }
            presetStore.reseedExamplePresets()
            // Proactively explain + offer Accessibility on launch if it isn't
            // granted, since macOS doesn't always surface its own prompt and
            // the app's mappings can't fire without it.
            accessibility.refresh()
            // First launch: the welcome first, then the permission ask
            // follows from its button. Later launches: the permission ask
            // alone, if it is still needed.
            // The welcome is for new installs. Someone updating from a version
            // before it existed got the welcome and What's New at once.
            // An upgrade is told by the version last seen: an older one, or
            // none at all on an install from before What's New existed. The
            // folder's age alone skipped the welcome for a new user who quit
            // before finishing it and came back ten minutes later, since a
            // first run stores this version straight away.
            // A menu bar Settings or New Preset that recreated this window.
            // Not over What's New, which is the sheet when it was asked
            // first; the menu's Settings or About is asked again later.
            if MenuBarController.takePendingMainAction(.settings), !showingWhatsNew { settingsSheetTab = .general }
            if MenuBarController.takePendingMainAction(.about), !showingWhatsNew { settingsSheetTab = .about }
            takePendingSheets()
            var openedEditor = false
            if MenuBarController.takePendingMainAction(.newPreset), editingPreset == nil, !anotherSheetIsUp {
                createNewPreset()
                openedEditor = true
            }
            let upgrading = lastSeenVersion.isEmpty
                ? Self.looksLikeExistingInstall
                : lastSeenVersion != Self.currentShortVersion
            if !welcomeIntroSeen && upgrading {
                welcomeIntroSeen = true
            }
            // anotherSheetIsUp covers Settings, an opened file's review and
            // a sheet asked for from the menu bar (takePendingSheets): two
            // sheets asked at once, one never showed.
            if openedEditor || anotherSheetIsUp || OpenedPresetFiles.hasPending {
                // The editor or an opened file's review is the sheet this
                // time; the intros wait.
            } else if upgrading {
                // What's New is the sheet; the Accessibility intro follows
                // when it closes (afterWhatsNew).
            } else if !welcomeIntroSeen {
                showingWelcomeIntro = true
            } else if !accessibility.isTrusted && !suppressAccessibilityIntro {
                showingAccessibilityIntro = true
            }
        }
        // The close hook drops What's New too; its state lives here, not
        // in the hook modifier. A modifier rather than one more closure on
        // this chain, which the type-checker could not finish.
        .modifier(DebugCloseWhatsNew(showing: $showingWhatsNew))
        // An opened preset's review waits while another sheet is up.
        .modifier(SheetStateRelay(up: anotherSheetIsUp))
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
                    // The 2026 Steam Controller shares the brand but has its
                    // own preset on the standard numbering.
                    let brand = controllerService.controllerDetails[0]?.brand ?? .unknown
                    return ExamplePresets.exampleName(for: brand, family: controllerService.namingFamily(forSlot: 0))
                }
            )
            .glassBackground()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: GlobalHotKeyService.toggleNotification)) { note in
            // Heard first here while the window exists; the menu bar's
            // listener steps aside for a press already handled.
            guard GlobalHotKeyService.claim(note) else { return }
            handleGlobalHotkeyToggle()
        }
        .modifier(DebugAutomationHooks(
            presetStore: presetStore,
            selection: selection,
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
        // A second press while the first-start confirmation is up would
        // queue a nested start once the modal ends; ignored instead.
        guard !confirmingStart else { return }
        let target = presetStore.lastActivatedPresetId
            .flatMap { id in presetStore.presets.first(where: { $0.id == id && $0.isRunnable }) }
            ?? presetStore.presets.first(where: \.isRunnable)
        // From the global shortcut, often with a game in front: the
        // pointer warning does not pull the app forward (the log says how
        // to stop), as for a preset's own shortcut.
        // From a run loop block, as MenuBarController does: the start can
        // run a modal confirmation, and modal inside the main-queue block
        // this notification arrives in held the queue (no Emergency Stop
        // chord).
        guard let id = target?.id else { return }
        confirmingStart = true
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated {
                defer { confirmingStart = false }
                // Waited for a modal: a preset it started meanwhile (the
                // crash alert's Start) stays, where a toggle stopped it.
                guard !presetStore.presets.contains(where: \.isActive) else { return }
                // Looked up again: the preset can be edited or deleted
                // between the key press and this block.
                guard let preset = presetStore.presets.first(where: { $0.id == id && $0.isRunnable }) else { return }
                togglePreset(preset, fromShortcut: true)
            }
        }
    }

    /// The page changed under the button that was pressed: say where it is.
    func announceOpened(_ preset: Preset) {
        AccessibilityNotification.Announcement(String(localized: "Opened \(preset.shownName). Activate is at the top of its page.")).post()
    }

    /// Select a preset by name, scroll it into view, and briefly flash it
    /// green so the user sees where it landed. Shared by the feature-demo
    /// "Take me to an example" button and the per-controller example jump.
    private func jumpToPreset(named presetName: String) {
        guard let preset = presetStore.presets.first(where: { $0.name == presetName }) else {
            // Deleted from the library: said, rather than nothing at all,
            // and shown, since the showcase sheet just closed with no sign.
            let line = String(localized: "\(ShippedText.t(presetName)) is not in your library. Settings, Advanced, Restore Built-in Presets puts it back.")
            AccessibilityNotification.Announcement(line).post()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let window = NSApp.keyWindow, window.attachedSheet == nil {
                    let alert = NSAlert()
                    alert.messageText = line
                    alert.beginSheetModal(for: window)
                } else {
                    // Not from this block: a modal here holds the main
                    // queue, and no Emergency Stop chord gets through.
                    RunLoop.main.perform(inModes: [.common]) {
                        MainActor.assumeIsolated {
                            let alert = NSAlert()
                            alert.messageText = line
                            alert.runModal()
                        }
                    }
                }
            }
            return
        }
        // revealPreset scrolls once the folders it opened are laid out; a
        // second scroll right away aimed at the closed folder first.
        revealPreset(preset.id)
        flashingPresetID = preset.id
        announceOpened(preset)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if flashingPresetID == preset.id {
                withAnimation(.easeOut(duration: 0.9)) { flashingPresetID = nil }
            }
        }
    }

    // MARK: - Sidebar

    @State var creatingGroupForPreset: Preset?
    @State var newGroupName: String = ""
    @State var renamingGroup: PresetGroup?
    @State var renameGroupName: String = ""
    @FocusState var groupNameFocused: Bool
    /// The group whose color popover is open (nil = none). Drives a per-row
    /// popover with tinted swatches + the macOS color picker.
    @State var colorEditingGroup: PresetGroup?
    /// Working color for the folder color picker's "Custom" well.
    @State var folderPickerColor: Color = .accentColor
    /// The most recently created group ID. Drives a brief green-flash
    /// animation in the sidebar so the user's eye lands on the new entry.
    @State var flashingGroupID: UUID?
    /// The folder header last clicked. Drawn inside the folder's own outline;
    /// the system selection pill sat at a different inset and radius and cut
    /// across the outline.
    @State var selectedFolderID: UUID?
    /// The preset or folder the Move to Folder sheet is moving.
    @State var sidebarMoveTarget: SidebarMoveTarget?
    /// The sidebar's search field.
    @State var sidebarQuery = ""
    /// Put Back from Trash, the keyboard path to one Trash entry.
    @State var showingTrashSheet = false
    /// Every folder as a path, for the rows' Move to Group menus; worked
    /// out again only when the folders change, not on every row.
    @State var groupPathMemo = GroupPathMemo()

    @State var pendingGroupPresetIDs: [UUID] = []
    /// Whether the welcome screen's release-notes popover is open.
    @State var showWelcomeChangelog = false
    var controllerStatusBar: some View {
        VStack(spacing: 0) {
            if let warning = eightBitDoModeWarning {
                eightBitDoWarningBanner(warning)
            }

            if controllerService.connectedControllers.isEmpty
                && controllerService.rawHIDGamepadSlots.isEmpty
                && controllerService.steamControllerSlot == nil
                && controllerService.racingWheelSlots.isEmpty
                && !controllerService.debugMarketingFakeActive {
                HStack(spacing: 6) {
                    ControllerGlyph(height: 13)
                        .foregroundStyle(.secondary)
                    Text("No controllers connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                // On the sidebar's one left edge, with the search field,
                // the headings and the folder outlines.
                .padding(.leading, 20)
                .padding(.trailing, 12)
                .padding(.vertical, 8)
            } else {
                #if DEBUG
                if controllerService.debugMarketingFakeActive {
                    ForEach(controllerService.controllerDetails.keys.sorted().filter { controllerService.rawHIDGamepadSlots[$0] == nil }, id: \.self) { idx in
                        ControllerChipView(
                            controller: nil, index: idx,
                            color: Self.controllerColors[idx % Self.controllerColors.count],
                            info: controllerService.controllerDetails[idx],
                            onSetLight: { _, _, _ in }, onSetBrightness: { _ in },
                            onToggleRGB: {}, isRGBActive: false, onRefresh: {},
                            onOpenExample: {}, rgbSpeed: $controllerService.rgbCycleSpeed,
                            onDisconnect: { .disconnected })
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
                            jumpToPreset(named: ExamplePresets.exampleName(for: brand,
                                                                           family: controllerService.namingFamily(forSlot: index)))
                        },
                        rgbSpeed: $controllerService.rgbCycleSpeed,
                        onDisconnect: { RawHIDGamepadService.shared.disconnect(gameController: controller) },
                        experimental: ControllerLayoutResolver.readsExperimentally(service: controllerService, slot: index),
                        currentBrightness: { controllerService.lightBrightness[index] ?? 2 },
                        ports: controllerService.accessPortDevices(forSlot: index),
                        accessProfile: {
                            let p = controllerService.accessProfile(forSlot: index)
                            return p.number > 0 ? (p.number, p.profile?.name) : nil
                        }(),
                        edgeProfiles: controllerService.edgeProfiles(forSlot: index)
                    )
                }

                // Raw HID gamepads (8BitDo XInput, Xbox 360 wired,
                // Logitech F310/F710, generic descriptor-parsed pads).
                // They don't fit the MFi GCController chip (no battery,
                // no light bar), so render a simpler chip per slot.
                ForEach(rawHIDSortedSlots, id: \.slot) { entry in
                    RawHIDChipView(slot: entry.slot, gamepad: entry.gamepad,
                                   color: Self.controllerColors[entry.slot % Self.controllerColors.count],
                                   experimental: ControllerLayoutResolver.readsExperimentally(service: controllerService, slot: entry.slot))
                }
                // The Steam Controller, read by its own helper.
                if let steamSlot = controllerService.steamControllerSlot {
                    steamChip(slot: steamSlot)
                }
                // Racing wheels read through macOS racing wheel support
                // (a Logitech wheel for Xbox): neither a GCController nor a
                // raw HID pad, so they need a chip of their own.
                ForEach(controllerService.racingWheelSlots.keys.sorted(), id: \.self) { slot in
                    racingWheelChip(slot: slot)
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

    private func steamChip(slot: Int) -> some View {
        let color = Self.controllerColors[slot % Self.controllerColors.count]
        return HStack(spacing: 8) {
            ControllerGlyph(height: 11)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 0) {
                Text("Steam Controller")
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("Slot \(slot)")
                    .font(.system(size: 9))
                    .foregroundStyle(.hint)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func racingWheelChip(slot: Int) -> some View {
        let color = Self.controllerColors[slot % Self.controllerColors.count]
        let info = controllerService.controllerDetails[slot]
        let controls = controllerService.racingWheelControls(forSlot: slot)
        let pedals = [controls?.gas, controls?.brake, controls?.clutch].compactMap { $0 }.filter { $0 }.count
        let buttons = controllerService.racingWheelButtons(forSlot: slot).count
        return HStack(spacing: 8) {
            ControllerGlyph(height: 11)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 0) {
                Text(info?.name ?? controllerService.controllerNames[slot] ?? GameControllerService.racingWheelFallbackName)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(String(localized: "Racing Wheel, \(pedals) pedals, \(buttons) buttons"))
                    .font(.system(size: 9))
                    .foregroundStyle(.hint)
                    .lineLimit(1)
            }
            Spacer()
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
                    Text(device.mode.shownName.isEmpty ? String(localized: "8BitDo controller detected in a mode macOS does not list")
                         : String(localized: "8BitDo controller detected in \(device.mode.shownName) mode"))
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
        // The same modes Help gives, from 8BitDo's own instructions for Apple
        // devices.
        if name.contains("ultimate 2c") || name.contains("ultimate2c") {
            return String(localized: "The Ultimate 2C wired model has no Apple mode. Hold X while plugging it in for its Windows mode, which InputConfig reads directly.")
        }
        if name.contains("sn30") || name.contains("n30 pro") {
            return String(localized: "Turn it off, then hold B and Start to turn it on in the mode for a Mac.")
        }
        return String(localized: "Slide the switch on the back to D, the mode 8BitDo lists for a Mac. A pad without a switch: hold B and Start to turn it on.")
    }

    /// The top-level folders of one sidebar list, each a collapsible
    /// section with the folder's outline, drag-reorderable within the list.
    @ViewBuilder
    func topLevelFolders(_ folders: [PresetGroup], builtIn: Bool) -> some View {
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
                .listRowBackground(FolderOutlineSegment(role: headerRole, color: outline.color,
                                                        selected: selectedFolderID == group.id))
                // Pull the row's leading edge left so List's default sidebar
                // indent doesn't leave a fat empty gap to the left of the
                // disclosure chevron.
                .listRowInsets(EdgeInsets(top: 2, leading: -6,
                                          bottom: 2, trailing: 22))
        }
        .onMove { source, destination in
            withAnimation(.spring(response: 0.35)) {
                presetStore.moveTopLevelGroups(builtIn: builtIn, fromOffsets: source, toOffset: destination)
            }
        }
    }

    /// New Preset from the sidebar: create it, select it, open the editor.
    func createNewPreset() {
        let preset = presetStore.createPreset()
        selectedPresetId = preset.id
        newlyCreatedPresetId = preset.id
        editingPreset = preset
    }

    var bottomToolbar: some View {
        HStack(spacing: 10) {
            Menu {
                Button("New Preset") { createNewPreset() }
                Button("New Group…") {
                    pendingGroupPresetIDs = []
                    newGroupName = String(localized: "New Group").withoutRTLMark
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
            .voiceNames("Donate", "Donate to InputConfig")
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
                presetStore.previewImportsOrMacroText(from: urls)
            }
        }
        .fileDialogMessage(Text("Choose preset files to import"))
        .sheet(isPresented: Binding(
            get: { !presetStore.importReviewQueue.isEmpty },
            set: { if !$0 { presetStore.cancelImportReview() } }
        )) {
            ImportReviewSheet()
                .environmentObject(presetStore)
                .glassBackground()
        }
    }

    /// Whether a chosen file is a macro written as text rather than a
    /// preset: not JSON, and its first real line is a macro option or step.
    // MARK: - Detail View

    @ViewBuilder
    private var detailView: some View {
        VStack(spacing: 0) {
            // The scrolling detail content gets the canonical header fade so it
            // dissolves into the window vibrancy under the transparent titlebar
            // instead of colliding with the toolbar. Applied once here so both
            // PresetDetailView and welcomeView inherit it; the developer log
            // below sits outside the faded region.
            // In its own scope: a switch re-runs the page from here.
            SelectionScope(selection: selection) {
            Group {
                if let presetId = selectedPresetId,
                   let preset = presetStore.presets.first(where: { $0.id == presetId }) {
                    PresetDetailView(
                        preset: presetBinding(for: preset),
                        pageDrafts: pageDrafts,
                        onEdit: { editingPreset = committed(preset) },
                        onToggle: { togglePreset(committed(preset)) },
                        onJumpToBinding: { target in
                            pendingEditorJump = target
                            editingPreset = committed(preset)
                        }
                    )
                    // The visualizer under the editor sheet stops its clock:
                    // drawing a live pad nobody can see took frames from the
                    // editor's scrolling.
                    .environment(\.visualizerSuspended, editingPreset != nil)
                    .environmentObject(mappingEngine)
                    .environmentObject(controllerService)
                    .environmentObject(presetStore)
                } else {
                    welcomeView
                }
            }
            .headerFade()
            }

            // Developer log: on by default, at the bottom, with a Settings
            // switch for people who want the room.
            // Hidden on the home screen; every preset page carries it.
            // hasSelection, not the id: it changes only between Home and a
            // page, so a switch from one preset to another leaves the log
            // alone (it showed nothing a switch changes, and re-ran twice).
            if showDebugLog && selection.hasSelection {
                Divider()
                    .padding(.horizontal)
                DebugLogView(onHome: false)
                    .equatable()
                    .environmentObject(mappingEngine)
                    .environmentObject(controllerService)
                    .padding(.vertical, 8)
            }
        }
    }
}

// MARK: - Folder outline (sidebar)

/// Which part of a folder's outline a List row draws.
enum FolderOutlineRole {
    case single, top, middle, bottom
    /// The row that ends a folder, with the bottom edge of its outline.
    var closesFolder: Bool { self == .bottom || self == .single }
}

/// Passed down a top-level folder's rows: the folder's color and which row
/// closes the box.
/// A wrapping row of views, each line centered. Lines break where the next
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
/// at both ends toward whatever it groups. Gray, matching the caption text.
struct BracketHeader: View {
    let title: LocalizedStringKey
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
        .accessibilityAddTraits(.isHeader)
    }

    /// One half of the bar: the line along the top edge, and the tick at
    /// the outer end pointing down.
    private func arm(leading: Bool) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            // The bar runs through the title's center line; the ticks
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
    /// A selected folder header: filled inside this same outline, so the
    /// highlight follows its corners and edges exactly.
    var selected: Bool = false
    private let radius: CGFloat = 8
    /// 8 pt inside the cell on both sides. The list itself is padded 12 pt
    /// on the left (see `sidebarView`), so the line lands 20 pt from the
    /// window edge, the same as its right edge has to the panel's divider
    /// (8 pt to the scroll bar, then the bar).
    private let insetLeading: CGFloat = 0
    /// 20 points from the outline to the scroll bar, which stays in place,
    /// as from the sidebar's left edge to the outline.
    private let insetTrailing: CGFloat = 20.5
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
            ZStack(alignment: .topLeading) {
                if selected {
                    fillShape(h: h)
                        .fill(color.opacity(0.22))
                        .padding(1)
                }
                edges(w: w, h: h)
                    .stroke(color.opacity(selected ? 0.45 : 0.18), lineWidth: 1)
            }
            .frame(width: w, height: h)
            .offset(x: insetLeading, y: top)
        }
    }

    /// The area inside the outline for this role, for the selected fill.
    private func fillShape(h: CGFloat) -> UnevenRoundedRectangle {
        let r = max(0, min(radius, h / 2) - 1)
        switch role {
        case .single: return UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r,
                                                    bottomTrailingRadius: r, topTrailingRadius: r)
        case .top:    return UnevenRoundedRectangle(topLeadingRadius: r, topTrailingRadius: r)
        case .bottom: return UnevenRoundedRectangle(bottomLeadingRadius: r, bottomTrailingRadius: r)
        case .middle: return UnevenRoundedRectangle()
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


/// The preset selected in the sidebar (ContentView.selectedPresetId).
/// Observable, so only a view that reads `id` re-runs when it changes.
@MainActor @Observable
final class PresetSelection {
    var id: UUID? {
        didSet {
            if hasSelection != (id != nil) { hasSelection = id != nil }
            guard oldValue != id else { return }
            untrackedID = id
            // Two rows hear of a switch: the one left and the one picked.
            if let old = oldValue, let row = rows[old], row.isSelected { row.isSelected = false }
            if let new = id, let row = rows[new], !row.isSelected { row.isSelected = true }
        }
    }
    /// Whether any preset is selected: changes only between Home and a page.
    private(set) var hasSelection = false

    /// `id` again, read without being observed: a row's state is made from
    /// it inside SidebarRows, which must not re-run on every switch.
    @ObservationIgnored private var untrackedID: UUID?
    @ObservationIgnored private var rows: [UUID: PresetRowSelection] = [:]

    /// One preset's row state, kept for as long as the window is: the
    /// sidebar asks for it every time it makes that row. Reading it does not
    /// observe `id`.
    func row(for presetID: UUID) -> PresetRowSelection {
        if let row = rows[presetID] { return row }
        let row = PresetRowSelection(isSelected: untrackedID == presetID)
        rows[presetID] = row
        return row
    }
}

/// Whether one sidebar row is the selected one. Each row reads its own, so a
/// switch redraws the two rows it changes and no other; every row reading
/// `PresetSelection.id` would redraw them all.
@MainActor @Observable
final class PresetRowSelection {
    fileprivate(set) var isSelected: Bool
    init(isSelected: Bool) { self.isSelected = isSelected }
}

/// Everything the sidebar's preset and folder rows read from ContentView
/// apart from the selection, which each row reads for itself. The store's
/// publish count stands for the whole store. A new read of ContentView
/// state in those rows (`sidebarRowsContent` and what it calls) must join
/// this key, or a change of it would not redraw them.
/// The folder paths for the Move to Group menus, kept for the folders and
/// the Hide Built-in setting they were made from. A reference in State, so
/// reading it never invalidates a view: the first sidebar already has the
/// paths, where the cache set in the sidebar's onAppear left the first rows
/// working them out one row at a time and then made every row a second time
/// (their key changed) right after the window first showed.
@MainActor
final class GroupPathMemo {
    private var groups: [PresetGroup]?
    private var hideBuiltIn = false
    private var paths: [(id: UUID, path: String)] = []

    func paths(groups: [PresetGroup], hideBuiltIn: Bool,
               _ compute: () -> [(id: UUID, path: String)]) -> [(id: UUID, path: String)] {
        if let kept = self.groups, kept == groups, self.hideBuiltIn == hideBuiltIn { return paths }
        paths = compute()
        self.groups = groups
        self.hideBuiltIn = hideBuiltIn
        return paths
    }
}

struct SidebarRowsKey: Equatable {
    var storeRevision: Int
    var query: String
    var selectedFolderID: UUID?
    var flashingPresetID: UUID?
    var flashingGroupID: UUID?
    /// The folder whose color popover is open, and the one asked about
    /// in Delete Folder: both hang off a folder header's binding.
    var colorEditingGroupID: UUID?
    var folderPendingDelete: UUID?
    var folderPickerColor: Color = .accentColor
    /// The Move to Group menu of every row.
    var groupPaths: [(id: UUID, path: String)]

    static func == (a: Self, b: Self) -> Bool {
        guard a.storeRevision == b.storeRevision, a.query == b.query,
              a.selectedFolderID == b.selectedFolderID, a.flashingPresetID == b.flashingPresetID,
              a.flashingGroupID == b.flashingGroupID, a.colorEditingGroupID == b.colorEditingGroupID,
              a.folderPendingDelete == b.folderPendingDelete, a.folderPickerColor == b.folderPickerColor,
              a.groupPaths.count == b.groupPaths.count else { return false }
        for i in a.groupPaths.indices where a.groupPaths[i].id != b.groupPaths[i].id || a.groupPaths[i].path != b.groupPaths[i].path {
            return false
        }
        return true
    }
}

/// The sidebar's preset and folder rows, made again only when their key
/// changes. A switch re-runs the sidebar's SelectionScope (the List's
/// selection is read there), which made every row again: each folder's
/// DisclosureGroup, every PresetRowView with its closures and a copy of its
/// preset. Now the parent's run stops here, and the switch redraws only the
/// two rows whose PresetRowSelection flipped.
/// SwiftUI uses the Equatable conformance on its own. Not `.equatable()`:
/// an EquatableView is one view, and the List showed it as one empty row in
/// place of these sections and rows. Nothing observed here either: a run of
/// its own, without a new value from the parent, left the rows inside a
/// DisclosureGroup as they were (tested offscreen), so a store change comes
/// in through the key's revision.
extension SidebarRowsKey {
    /// For the Test Bench, which has no SwiftUI: a picker color unlike the
    /// default one.
    mutating func pickAnotherColorForTest() { folderPickerColor = .red }
}

extension SidebarRows where Content == EmptyView {
    /// For the Test Bench: a gate compared by its key alone.
    init(key: SidebarRowsKey) { self.init(key: key, content: { EmptyView() }) }
}

struct SidebarRows<Content: View>: View, Equatable {
    let key: SidebarRowsKey
    @ViewBuilder let content: () -> Content

    nonisolated static func == (a: Self, b: Self) -> Bool { a.key == b.key }

    var body: some View {
        #if DEBUG
        let _ = BodyRuns.note("SidebarRows")
        #endif
        content()
    }
}

/// Runs its content in its own body, so the selection is read and tracked
/// here and a change re-runs this scope, not the view that made it. The
/// content closure is the maker's, so it still reads the maker's state, and
/// any change of that state re-runs the maker, which makes a new scope.
struct SelectionScope<Content: View>: View {
    let selection: PresetSelection
    @ViewBuilder let content: () -> Content

    var body: some View {
        #if DEBUG
        let _ = BodyRuns.note("SelectionScope")
        #endif
        // Read here too, not only inside the content: a List's rows can be
        // made outside any body, and the scope must re-run on every change.
        let _ = selection.id
        content()
    }
}

/// Holder for per-slot visualizer control objects; see `visualizerControls`.
final class VisualizerControlBox {
    var states: [Int: VisualizerControlState] = [:]
}

/// Where a scroll anchor sits in its NSScrollView, read when asked, so a
/// scrollTo that would not move the page can be skipped. Not observed.
final class ScrollAnchorBox {
    weak var view: NSView?

    /// The anchor's top is at the top of the visible area, below the
    /// toolbar's inset: where scrollTo(_:anchor: .top) puts it. False when
    /// that cannot be read, so the caller scrolls as before.
    @MainActor var isScrolledTo: Bool {
        guard let view, let scroll = view.enclosingScrollView, scroll.documentView?.isFlipped == true else { return false }
        let clip = scroll.contentView
        let anchor = view.convert(view.bounds, to: clip)
        return abs(clip.bounds.minY - (anchor.minY - clip.contentInsets.top)) < 0.5
    }
}

/// Hands its view to a ScrollAnchorBox. Zero height, not an accessibility
/// element, never hit.
struct ScrollAnchorProbe: NSViewRepresentable {
    let box: ScrollAnchorBox
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { box.view = nsView }
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
            if let idle = ControllerPowerService.shared.debugIdleSeconds(controller) {
                out += "  idle for \(idle) s (idle disconnect \(ControllerPowerService.shared.idleDisconnectOn ? "on, \(ControllerPowerService.shared.idleMinutes) min" : "off"), reconnect \(ControllerPowerService.shared.autoReconnectOn ? "on" : "off"))\n"
            }
            let turned = svc.debugIntegratedAngle(for: controller)
            out += String(format: "  turned since last drain x=%+.3f y=%+.3f z=%+.3f rad (%+.0f %+.0f %+.0f deg)\n",
                          turned.x, turned.y, turned.z, turned.x * 180 / .pi, turned.y * 180 / .pi, turned.z * 180 / .pi)
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

/// Tells OpenedPresetFiles whether another sheet is up, so an opened
/// preset's review waits for it. A modifier, not one more closure on the
/// main window's chain, which the type-checker could not finish.
private struct SheetStateRelay: ViewModifier {
    let up: Bool
    func body(content: Content) -> some View {
        content.onChange(of: up, initial: true) { _, value in
            OpenedPresetFiles.otherSheetIsUp = value
        }
    }
}

/// The Presets menu's actions (see `Notification.Name.inputConfigSidebarCommand`).
enum SidebarCommand {
    case duplicate, export, print, favorite, delete, moveUp, moveDown, moveToFolder
    case renameFolder, folderColor, newSubfolder, deleteFolder, folderUp, folderDown, moveFolderInto
    case nextFolder, previousFolder, toggleFolder, expandAll, collapseAll
    case showTrash, restoreLastDeleted, emptyTrash, trashItems
}

/// Moves the selected preset or folder into a folder chosen from a list:
/// the keyboard path to what the rows' own menus do.
struct SidebarMoveSheet: View {
    let target: SidebarMoveTarget
    let store: PresetStore
    let choices: [(id: UUID, path: String)]
    let close: () -> Void
    /// After a move, so the sidebar scrolls to what moved, as the row menu does.
    var moved: (SidebarMoveTarget) -> Void = { _ in }
    @State private var destination: UUID?
    @State private var loaded = false

    private var title: String {
        switch target {
        case .preset(let id):
            let name = store.presets.first { $0.id == id }?.shownName ?? ""
            return String(localized: "Move \u{201C}\(name)\u{201D} to a folder")
        case .folder(let id):
            let name = store.groups.first { $0.id == id }.map { ShippedText.t($0.name) } ?? ""
            return String(localized: "Move the folder \u{201C}\(name)\u{201D}")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Picker("Folder", selection: $destination) {
                if case .preset = target { Text("No folder").tag(UUID?.none) } else { Text("Top Level (no parent)").tag(UUID?.none) }
                ForEach(choices, id: \.id) { choice in
                    Text(choice.path).tag(Optional(choice.id))
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Move") { move() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            switch target {
            case .preset(let id): destination = store.presets.first { $0.id == id }?.groupID
            case .folder(let id): destination = store.groups.first { $0.id == id }?.parentID
            }
        }
    }

    private func move() {
        switch target {
        case .preset(let id): store.setPresetGroup(id, groupID: destination)
        case .folder(let id): store.setGroupParent(id, parentID: destination)
        }
        // The destination and every folder above it, so the moved item shows.
        var open = destination
        var hops = 0
        while let id = open, hops < 8 {
            store.setGroupExpanded(id, true)
            open = store.groups.first { $0.id == id }?.parentID
            hops += 1
        }
        let path = choices.first { $0.id == destination }?.path
        AccessibilityNotification.Announcement(path.map { String(localized: "Moved to \($0)") } ?? String(localized: "Moved to the top level")).post()
        close()
        moved(target)
    }
}

/// Put Back or Delete Permanently one Trash entry, chosen from a list: the
/// keyboard path to the Trash rows' own buttons.
struct TrashSheet: View {
    let store: PresetStore
    let close: () -> Void
    let restored: (UUID) -> Void
    @State private var choice: UUID?
    @State private var confirmingDelete = false

    private var entries: [(id: UUID, name: String, isFolder: Bool)] {
        store.deletedFolders.map { ($0.id, ShippedText.t($0.name), true) }
            + store.recentlyDeleted.sorted { $0.deletedAt > $1.deletedAt }.map { ($0.id, $0.preset.shownName, false) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Put Back from Trash")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Picker("Item", selection: $choice) {
                ForEach(entries, id: \.id) { e in
                    Text(e.isFolder ? String(localized: "Folder \(e.name)") : e.name).tag(Optional(e.id))
                }
            }
            HStack {
                Button("Delete Permanently\u{2026}", role: .destructive) { confirmingDelete = true }
                    .disabled(choice == nil)
                Spacer()
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Put Back") { putBack() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(choice == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { if choice == nil { choice = entries.first?.id } }
        .confirmationDialog(deleteTitle, isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Permanently", role: .destructive) { deleteChosen() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It cannot be put back.")
        }
    }

    /// Names what goes: a folder takes its presets with it, which the
    /// plain "Delete it permanently?" never said.
    private var deleteTitle: String {
        if let f = store.deletedFolders.first(where: { $0.id == choice }) {
            return String(localized: "Delete the folder \u{201C}\(ShippedText.t(f.name))\u{201D} and its presets permanently?")
        }
        if let p = store.recentlyDeleted.first(where: { $0.id == choice }) {
            return String(localized: "Delete \u{201C}\(p.preset.shownName)\u{201D} permanently?")
        }
        return String(localized: "Delete it permanently?")
    }

    private func putBack() {
        guard let choice else { return }
        if let f = store.deletedFolders.first(where: { $0.id == choice }) {
            store.restoreDeletedFolder(f)
            AccessibilityNotification.Announcement(String(localized: "Put back \(ShippedText.t(f.name))")).post()
        } else if let p = store.recentlyDeleted.first(where: { $0.id == choice }), store.restoreDeleted(p) {
            AccessibilityNotification.Announcement(String(localized: "Put back \(p.preset.shownName)")).post()
            restored(p.preset.id)
        }
        close()
    }

    private func deleteChosen() {
        guard let id = choice else { return }
        if let f = store.deletedFolders.first(where: { $0.id == id }) {
            store.permanentlyDeleteFolder(f)
            AccessibilityNotification.Announcement(String(localized: "\(ShippedText.t(f.name)) deleted permanently")).post()
        } else if let p = store.recentlyDeleted.first(where: { $0.id == id }) {
            store.permanentlyDelete(p)
            AccessibilityNotification.Announcement(String(localized: "\(p.preset.shownName) deleted permanently")).post()
        }
        choice = entries.first?.id
        if entries.isEmpty { close() }
    }
}

/// What the Move to Folder sheet moves.
enum SidebarMoveTarget: Identifiable, Hashable {
    case preset(UUID), folder(UUID)
    var id: Self { self }
}


/// Calls back when the running preset changes; its own modifier, so the
/// main view's long modifier chain stays within the type checker's budget.
private struct ActivePresetWatch: ViewModifier {
    let id: UUID?
    let action: (UUID?) -> Void
    func body(content: Content) -> some View {
        content.onChange(of: id) { _, new in action(new) }
    }
}

/// Keeps the sidebar list's scroll bar in place when the system shows scroll
/// bars all the time, instead of hiding it while the list fits, so the rows
/// keep one width. With floating scroll bars it changes nothing.
/// Glides the sidebar to a preset. SwiftUI's scrollTo did not move the
/// List to a row inside a folder (and jumps where it does), so the row is
/// found in the sidebar's own outline view through a small anchor view each
/// preset row carries, and the clip view is animated there, which is how
/// AppKit scrolls smoothly.
@MainActor
enum SidebarSmoothScroll {
    static weak var scrollView: NSScrollView?

    final class Anchor: NSView {
        var presetID: UUID?
        /// Behind the row: a click belongs to the list.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        /// The rows draw their own selection, inset to the outlines, so the
        /// row view draws none. On the row view, never the table: with the
        /// table's own style at none, NSTableView skips its row click logic
        /// unless SwiftUI's subclass overrides that, and without the override
        /// a click selected nothing while the arrow keys still worked.
        func hideRowHighlight() {
            var view = superview
            while let v = view {
                if let row = v as? NSTableRowView {
                    if row.selectionHighlightStyle != .none { row.selectionHighlightStyle = .none }
                    return
                }
                view = v.superview
            }
        }
        override func layout() {
            super.layout()
            hideRowHighlight()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let presetID { SidebarSmoothScroll.anchors[presetID] = WeakAnchor(view: self) }
            hideRowHighlight()
        }
    }
    struct WeakAnchor { weak var view: Anchor? }
    static var anchors: [UUID: WeakAnchor] = [:]

    /// True when the row was found and the sidebar is on its way (or
    /// already shows it); false to fall back to SwiftUI's scrollTo.
    @discardableResult
    static func toPreset(_ id: UUID, animated: Bool) -> Bool {
        guard let sv = scrollView, let table = sv.documentView as? NSTableView else { return false }
        func rowIndex() -> Int? {
            guard let v = anchors[id]?.view, v.window != nil, v.presetID == id else { return nil }
            let r = table.row(for: v)
            return r >= 0 ? r : nil
        }
        var found = rowIndex()
        if found == nil {
            // Off screen, the row has no view yet: make the rows' views,
            // which builds their anchors, and look again.
            for r in 0..<table.numberOfRows { _ = table.view(atColumn: 0, row: r, makeIfNecessary: true) }
            table.layoutSubtreeIfNeeded()
            found = rowIndex()
        }
        guard let row = found else { return false }
        let rect = table.rect(ofRow: row)
        let clip = sv.contentView
        let view = clip.bounds
        let inset = sv.contentInsets.top
        // Already fully in view, clear of the title bar: nothing to move.
        if rect.minY >= view.minY + inset, rect.maxY <= view.maxY { return true }
        // Centered in the part of the list below the title bar.
        let maxY = max(-inset, table.frame.height - view.height)
        let y = min(max(rect.midY - (view.height + inset) / 2, -inset), maxY)
        let target = NSPoint(x: view.origin.x, y: y)
        if animated {
            let distance = abs(target.y - view.minY)
            NSAnimationContext.runAnimationGroup { ctx in
                // Longer for a longer way, within reason.
                ctx.duration = min(0.6, 0.25 + Double(distance) / 4000)
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(target)
            }
        } else {
            clip.setBoundsOrigin(target)
        }
        sv.reflectScrolledClipView(clip)
        return true
    }
}

/// A click on a sidebar row, read beside the List, never by a gesture on the
/// row: a tap gesture on a List row, even a simultaneous one, can take the
/// click from the list's own selection, and on other Macs a click on a preset
/// did nothing while the arrow keys still moved it. These views take no clicks
/// at all; one local monitor sees the press on its way to the list and passes
/// it on. The action runs before the list selects, so it reads the row as it
/// was.
@MainActor
enum SidebarClicks {
    final class Target: NSView {
        var action: () -> Void = {}
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                SidebarClicks.targets.add(self)
                SidebarClicks.startMonitor()
            } else {
                SidebarClicks.targets.remove(self)
            }
        }
    }
    private static let targets = NSHashTable<Target>.weakObjects()
    private static var monitor: Any?

    private static func startMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            // A plain click: the second of a double click toggled a row
            // back, and a control-click is the row's menu.
            if event.clickCount == 1, !event.modifierFlags.contains(.control) {
                MainActor.assumeIsolated { fire(at: event.locationInWindow, in: event.window) }
            }
            return event
        }
    }

    /// The visible part of its bounds, so a row scrolled away under the
    /// search field or the window's edge is not hit. Bounds too: a view that
    /// does not clip reports a visibleRect wider than itself, and a click
    /// anywhere near fired it.
    static func fire(at point: NSPoint, in window: NSWindow?) {
        guard let window, window.attachedSheet == nil else { return }
        let hit = targets.allObjects.filter { $0.window === window && $0.bounds.intersection($0.visibleRect).contains($0.convert(point, from: nil)) }
        hit.forEach { $0.action() }
    }
}

struct SidebarClickTarget: NSViewRepresentable {
    let action: () -> Void
    func makeNSView(context: Context) -> SidebarClicks.Target {
        let v = SidebarClicks.Target()
        v.action = action
        return v
    }
    func updateNSView(_ nsView: SidebarClicks.Target, context: Context) { nsView.action = action }
}

/// The anchor a preset row carries so the sidebar can find it.
struct SidebarRowAnchor: NSViewRepresentable {
    let id: UUID
    func makeNSView(context: Context) -> SidebarSmoothScroll.Anchor {
        let v = SidebarSmoothScroll.Anchor()
        v.presetID = id
        return v
    }
    func updateNSView(_ nsView: SidebarSmoothScroll.Anchor, context: Context) {
        if nsView.presetID != id {
            nsView.presetID = id
            if nsView.window != nil { SidebarSmoothScroll.anchors[id] = SidebarSmoothScroll.WeakAnchor(view: nsView) }
        }
        // A reused row view comes back with the table's style.
        nsView.hideRowHighlight()
    }
}

struct KeepScrollerShown: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }
        override func layout() {
            super.layout()
            apply()
        }
        func apply() {
            guard let window, let root = window.contentView else { return }
            let mid = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
            func find(_ v: NSView) -> NSScrollView? {
                if let sv = v as? NSScrollView, sv.documentView is NSTableView,
                   sv.convert(sv.bounds, to: nil).contains(mid) { return sv }
                for sub in v.subviews { if let f = find(sub) { return f } }
                return nil
            }
            guard let scroll = find(root) else { return }
            SidebarSmoothScroll.scrollView = scroll
            if !scroll.hasVerticalScroller { scroll.hasVerticalScroller = true }
            if scroll.autohidesScrollers { scroll.autohidesScrollers = false }
        }
    }
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
