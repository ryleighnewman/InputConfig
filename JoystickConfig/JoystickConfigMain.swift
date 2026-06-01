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

    init() {
        // Boot the freeze watchdog before any heavy work runs - this is the
        // earliest place the main actor is alive, so we get the most
        // accurate "main thread responsiveness" baseline.
        _ = freezeWatchdog
        // Boot the external HID enumeration too, so keyboards / mice are
        // already detected by the time the user opens Settings → Devices
        // or the binding editor's external-source picker.
        _ = externalInput
        // If the previous session ended abnormally and the user hasn't
        // opted out of session restore, re-activate whichever preset
        // was active at the time of the crash. Deferred to the next
        // run-loop tick so PresetStore has finished its disk load.
        DispatchQueue.main.async { [presetStore, crashRecovery] in
            guard let id = crashRecovery.consumeRestoreTarget() else { return }
            if let preset = presetStore.presets.first(where: { $0.id == id }) {
                presetStore.activatePreset(preset)
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
struct JoystickConfig: App {
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
                    let dataDir = appSupport.appendingPathComponent("JoystickConfig", isDirectory: true)
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
                    NotificationCenter.default.post(name: .joystickConfigShowStats, object: nil)
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
                    NotificationCenter.default.post(name: .joystickConfigToggleActivePreset, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .option])

                Button("Stop All Activity") {
                    appState.mappingEngine.stop()
                    appState.presetStore.deactivateAll()
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])

                Divider()

                Button("Calibrate Touchpad…") {
                    NotificationCenter.default.post(name: .joystickConfigOpenTouchpadCalibration, object: nil)
                }

                Button("Calibrate Motion / Gyro…") {
                    NotificationCenter.default.post(name: .joystickConfigOpenMotionCalibration, object: nil)
                }
            }

            // MARK: Help menu - guides + diagnostics
            CommandGroup(replacing: .help) {
                Button("JoystickConfig Help") {
                    HelpGuideWindowController.shared.show()
                }
                .keyboardShortcut("?", modifiers: .command)

                Button("Quick Start Tour") {
                    NotificationCenter.default.post(name: .joystickConfigStartTutorial, object: nil)
                }

                Divider()

                Button("Support JoystickConfig...") {
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
