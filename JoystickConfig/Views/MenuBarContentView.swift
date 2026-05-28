import SwiftUI

/// Content of the menu bar dropdown. Lives in `MenuBarExtra` (macOS 13+) so
/// the controller icon sits in the right side of the menu bar at all times.
///
/// Pulls state from the same `PresetStore` and `MappingEngine` the rest of
/// the app uses, so toggling here keeps the main window in sync. The icon
/// in the menu bar is rendered template-style (looks grayed out / outline)
/// and inverts color to match the user's menu bar theme.
struct MenuBarContentView: View {
    @EnvironmentObject var presetStore: PresetStore
    @EnvironmentObject var mappingEngine: MappingEngine

    var body: some View {
        // Active preset header
        if let active = activePreset {
            HStack(spacing: 6) {
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Text(active.name)
                    .font(.headline)
            }
            .padding(.horizontal, 8)

            Button("Deactivate") {
                togglePreset(active)
            }
            Divider()
        } else {
            Text("No preset active")
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            Divider()
        }

        // Recent presets (up to 6, in storage order)
        if !presetStore.presets.isEmpty {
            Section("Activate Preset") {
                ForEach(presetStore.presets.prefix(6)) { preset in
                    Button {
                        togglePreset(preset)
                    } label: {
                        HStack {
                            if preset.isActive {
                                Image(systemName: "checkmark")
                            }
                            Text(preset.name)
                        }
                    }
                }
                if presetStore.presets.count > 6 {
                    Text("\(presetStore.presets.count - 6) more in the app...")
                        .foregroundStyle(.tertiary)
                }
            }
            Divider()
        }

        // Quick actions
        Button("Open JoystickConfig") {
            openMainWindow()
        }
        .keyboardShortcut("o", modifiers: [.command])

        // For the auxiliary windows (Help, Test Bench, Tip Jar) we used to
        // call openMainWindow() afterwards - which immediately brought the
        // main window to the front and buried whatever we just opened.
        // Now we only activate the app, then let each controller's own
        // show() handle key-window promotion for its window.
        Button("Help Guides") {
            NSApp.activate(ignoringOtherApps: true)
            HelpGuideWindowController.shared.show()
        }

        Button("Test Bench") {
            NSApp.activate(ignoringOtherApps: true)
            TestBenchWindowController.shared.show()
        }

        Button("Support JoystickConfig...") {
            NSApp.activate(ignoringOtherApps: true)
            TipJarWindowController.shared.show()
        }

        Divider()

        Button("Quit JoystickConfig") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: [.command])
    }

    // MARK: - Actions

    private var activePreset: Preset? {
        presetStore.presets.first(where: { $0.isActive })
    }

    private func togglePreset(_ preset: Preset) {
        if preset.isActive {
            mappingEngine.stop()
            presetStore.deactivateAll()
        } else {
            guard !preset.joysticks.isEmpty else { return }
            mappingEngine.stop()
            presetStore.activatePreset(preset)
            mappingEngine.start(with: preset)
        }
    }

    /// Bring the main app window forward. Without this, clicking a menu bar
    /// command that opens another window leaves the main window stuck behind
    /// other apps because the menu bar icon click does not activate us.
    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // Match by display name (now "JoystickConfig") OR fall back to any window
        // that has a content view, so this keeps working if the bundle name
        // changes again.
        for window in NSApp.windows where window.title == "JoystickConfig"
            || window.title == "JoystickConfig"
            || window.contentView != nil {
            window.makeKeyAndOrderFront(nil)
            break
        }
    }
}
