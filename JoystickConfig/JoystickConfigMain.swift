import SwiftUI

@MainActor
final class AppState: ObservableObject {
    let presetStore = PresetStore()
    let controllerService = GameControllerService()
    let eightBitDoDetector = EightBitDoDetector()
    lazy var mappingEngine = MappingEngine(controllerService: controllerService)
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
        }

        // Menu bar dropdown with quick access to active preset, recent
        // presets, and major app actions. The icon is template style so
        // macOS renders it in the menu bar's theme color (typically gray).
        MenuBarExtra("JoystickConfig", systemImage: "gamecontroller") {
            MenuBarContentView()
                .environmentObject(appState.presetStore)
                .environmentObject(appState.mappingEngine)
        }
        .menuBarExtraStyle(.menu)
    }
}
