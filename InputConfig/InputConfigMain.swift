import SwiftUI

@MainActor
final class AppState: ObservableObject {
    let presetStore = PresetStore()
    let controllerService = GameControllerService()
    let eightBitDoDetector = EightBitDoDetector()
    lazy var mappingEngine = MappingEngine(controllerService: controllerService)
    let crashRecovery = CrashRecoveryService.shared
    let freezeWatchdog = FreezeWatchdogService.shared
    let externalInput = ExternalInputDeviceService.shared
    let accessibility = AccessibilityPermissionService.shared

    init() {
        // Boot the freeze watchdog before any heavy work runs - this is the
        // earliest place the main actor is alive, so we get the most
        // accurate "main thread responsiveness" baseline.
        _ = freezeWatchdog
        // Boot the external HID enumeration too, so keyboards / mice are
        // already detected by the time the user opens Settings → Devices
        // or the binding editor's external-source picker.
        _ = externalInput
        // Boot the Accessibility-permission watcher so its trust state is
        // known at launch and refreshes when we return to the foreground.
        _ = accessibility
        // Register the global "toggle most recent preset" hotkey if the user
        // turned it on in Settings, so it works app-wide from launch.
        if UserDefaults.standard.bool(forKey: GlobalHotKeyService.enabledDefaultsKey) {
            GlobalHotKeyService.shared.enable()
        }
        // If the previous session ended abnormally and the user hasn't
        // opted out of session restore, re-activate whichever preset
        // was active at the time of the crash. Deferred to the next
        // run-loop tick so PresetStore has finished its disk load.
        DispatchQueue.main.async { [presetStore, crashRecovery, mappingEngine] in
            guard let id = crashRecovery.consumeRestoreTarget() else { return }
            if let preset = presetStore.presets.first(where: { $0.id == id }) {
                presetStore.activatePreset(preset)
                // Restore must also START the engine, not just mark the preset
                // active in the UI; otherwise the user's only input device
                // silently does nothing after a crash-recovery restore.
                mappingEngine.start(with: preset)
            }
        }

        // Graceful shutdown. When the user quits, NSApplication posts
        // willTerminate one main-runloop tick before exit; observing it
        // here gives us a deterministic window to release controller
        // state, stop the engine (which flushes pressed keys / mouse
        // buttons via releaseAll), close light-bar helpers, and persist
        // any pending stats. Without this, the process exits with
        // synthesized inputs still "down" in the OS event tap, so a
        // turbo'd or held key carries past the app.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.gracefulShutdown()
        }
    }

    /// Tear down outputs in priority order. Called on willTerminate.
    /// Each step is best-effort - a failure in one shouldn't block
    /// the others. Wraps in a fileprivate method so it's available
    /// from the observer closure above.
    fileprivate func gracefulShutdown() {
        // 0. Flush stats synchronously so the session's counters and time
        //    rollup are on disk before the process exits. The periodic flush
        //    writes asynchronously and may not complete at Cmd+Q.
        StatsService.shared.flushSynchronously()
        // 1. Stop the mapping engine. Releases held keys / mouse
        //    buttons / MIDI notes via the engine's stop() path.
        mappingEngine.stop()
        // 2. Deactivate the active preset record so a re-launch
        //    doesn't think a preset was already running.
        presetStore.deactivateAll()
        // 3. Belt-and-suspenders: drop everything the InputSimulator
        //    still considers pressed. Catches any synthesized keys
        //    the engine didn't track (e.g. macro mid-flight).
        InputSimulator.shared.releaseAll()
        // 4. Close the system-wide CGEventTap + IOHIDManager. Without
        //    this the mach port + runloop source linger past process
        //    exit, blocking a re-launch from grabbing a fresh tap
        //    until the kernel garbage-collects (can take 30+ seconds
        //    on a busy session).
        externalInput.teardownForTermination()
        // 5. Force the system cursor visible. If a preset had
        //    `hideCursorWhileActive` on and the user quit mid-session,
        //    we'd otherwise leave the cursor hidden until login - which
        //    looks indistinguishable from a frozen Mac.
        CursorGuardService.shared.forceShowCursor()
    }
}

@main
struct InputConfig: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState.presetStore)
                .environmentObject(appState.controllerService)
                .environmentObject(appState.mappingEngine)
                .environmentObject(appState.eightBitDoDetector)
                .onAppear {
                    MenuBarController.shared.install(
                        presetStore: appState.presetStore,
                        mappingEngine: appState.mappingEngine,
                        controllerService: appState.controllerService
                    )
                    FrontmostAppWatcher.shared.install(
                        presetStore: appState.presetStore,
                        mappingEngine: appState.mappingEngine
                    )
                }
        }
        .defaultSize(width: 1300, height: 750)
        .commands {
            // MARK: File menu - preset creation + quick file actions
            CommandGroup(after: .newItem) {
                Button("New Preset") {
                    _ = appState.presetStore.createPreset()
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Duplicate Active Preset") {
                    if let active = appState.presetStore.presets.first(where: { $0.isActive }) {
                        _ = appState.presetStore.duplicatePreset(active)
                    }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Divider()

                Button("Reveal Data Folder in Finder") {
                    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                    let dataDir = appSupport.appendingPathComponent("InputConfig", isDirectory: true)
                    NSWorkspace.shared.activateFileViewerSelecting([dataDir])
                }
            }

            // MARK: View menu - sidebar + statistics + welcome
            CommandGroup(before: .sidebar) {
                Button("Toggle Sidebar") {
                    NSApp.keyWindow?.firstResponder?.tryToPerform(
                        #selector(NSSplitViewController.toggleSidebar(_:)), with: nil
                    )
                }
                .keyboardShortcut("s", modifiers: [.command, .control])

                Button("Show Statistics") {
                    NotificationCenter.default.post(name: .inputConfigShowStats, object: nil)
                }
                .keyboardShortcut("0", modifiers: .command)
            }

            // MARK: Controller menu - new top-level menu for controller stuff
            CommandMenu("Controller") {
                Button("Refresh Connected Controllers") {
                    appState.controllerService.refreshControllers()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

                Button("Activate / Deactivate Selected Preset") {
                    NotificationCenter.default.post(name: .inputConfigToggleActivePreset, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .option])

                Button("Stop All Activity") {
                    appState.mappingEngine.stop()
                    appState.presetStore.deactivateAll()
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])

                Divider()

                Button("Calibrate Touchpad…") {
                    NotificationCenter.default.post(name: .inputConfigOpenTouchpadCalibration, object: nil)
                }

                Button("Calibrate Motion / Gyro…") {
                    NotificationCenter.default.post(name: .inputConfigOpenMotionCalibration, object: nil)
                }
            }

            // MARK: Help menu - guides + diagnostics
            CommandGroup(replacing: .help) {
                Button("InputConfig Help") {
                    HelpGuideWindowController.shared.show()
                }
                .keyboardShortcut("?", modifiers: .command)

                Button("Quick Start Tour") {
                    NotificationCenter.default.post(name: .inputConfigStartTutorial, object: nil)
                }

                Divider()

                Button("Support InputConfig...") {
                    TipJarWindowController.shared.show()
                }

                Divider()

                Button("Test Bench (Diagnostics)...") {
                    TestBenchWindowController.shared.show()
                }
                .keyboardShortcut("t", modifiers: [.command, .option, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appState.presetStore)
                .environmentObject(appState.controllerService)
                .environmentObject(appState.mappingEngine)
        }
    }
}

/// Switches presets automatically when the frontmost app changes. A preset
/// opts in by listing bundle identifiers in
/// `automation.autoActivateBundleIDs` (the "Auto-activate for apps" list in
/// the editor's Advanced Options), and the whole feature is gated by a
/// global Settings toggle so nothing moves without the user asking.
///
/// Sandbox-safe: NSWorkspace.didActivateApplicationNotification delivers the
/// activated app's bundle identifier with no extra entitlement; the same
/// observer pattern already drives the light-bar re-assert in
/// GameControllerService.
///
/// Restore behavior: the preset that was active before the first auto
/// switch is remembered, and switching to an app that matches no preset
/// brings it back (or deactivates, if nothing was active). A manual
/// activation in between clears the memory, so the watcher never fights
/// an explicit user choice.
@MainActor
final class FrontmostAppWatcher {
    static let shared = FrontmostAppWatcher()

    static let enabledDefaultsKey = "InputConfig.autoSwitch.enabled"

    private weak var presetStore: PresetStore?
    private weak var mappingEngine: MappingEngine?
    private var observer: NSObjectProtocol?
    /// What was active before the first auto switch, restored on leaving.
    private var autoSwitchedFromPresetID: UUID?
    /// The preset the watcher itself activated last; if the active preset
    /// differs, the user switched manually and the watcher backs off.
    private var lastAutoActivatedPresetID: UUID?

    private init() {}

    func install(presetStore: PresetStore, mappingEngine: MappingEngine) {
        guard observer == nil else { return }
        self.presetStore = presetStore
        self.mappingEngine = mappingEngine
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey]
                            as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor in
                self?.handleFrontmost(bundleID: bundleID)
            }
        }
    }

    private func handleFrontmost(bundleID: String?) {
        guard UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey),
              let bundleID,
              bundleID != Bundle.main.bundleIdentifier,
              let store = presetStore,
              let engine = mappingEngine else { return }

        if let match = store.presets.first(where: { preset in
            (preset.automation.autoActivateBundleIDs ?? []).contains(bundleID)
        }) {
            guard store.activePresetId != match.id else { return }
            // Remember what to come back to, but only when this is the
            // FIRST auto switch of a run; hopping between two matched apps
            // keeps the original restore point.
            if lastAutoActivatedPresetID == nil || store.activePresetId != lastAutoActivatedPresetID {
                autoSwitchedFromPresetID = store.activePresetId
            }
            engine.stop()
            store.activatePreset(match)
            engine.start(with: match)
            lastAutoActivatedPresetID = match.id
        } else if let lastAuto = lastAutoActivatedPresetID {
            // Only unwind an ACTIVE auto switch; if the user changed presets
            // manually since, leave their choice alone.
            guard store.activePresetId == lastAuto else {
                lastAutoActivatedPresetID = nil
                autoSwitchedFromPresetID = nil
                return
            }
            if let backID = autoSwitchedFromPresetID,
               let back = store.presets.first(where: { $0.id == backID }) {
                engine.stop()
                store.activatePreset(back)
                engine.start(with: back)
            } else {
                engine.stop()
                store.deactivateAll()
            }
            lastAutoActivatedPresetID = nil
            autoSwitchedFromPresetID = nil
        }
    }
}
