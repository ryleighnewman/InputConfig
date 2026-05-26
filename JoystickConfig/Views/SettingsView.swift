#if os(macOS)
import SwiftUI
import GameController

struct SettingsView: View {
    @EnvironmentObject var presetStore: PresetStore
    @EnvironmentObject var controllerService: GameControllerService

    /// Which tab is currently visible. Replaces SwiftUI's `TabView` because
    /// `TabView`'s tab bar clips against a sheet's rounded top corners on
    /// macOS, leaving the tab pills half-cut. A plain segmented Picker sits
    /// safely inside the sheet's content area.
    @State private var selectedTab: SettingsTab = .general

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case controllers = "Controllers"
        case about = "About"

        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .general: return "gear"
            case .controllers: return "gamecontroller"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab selector. Pinned at the top of the sheet, tucked safely
            // below the rounded corner via padding.
            Picker("", selection: $selectedTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.systemImage)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 80)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            Group {
                switch selectedTab {
                case .general: generalTab
                case .controllers: controllersTab
                case .about: aboutTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // macOS Form needs more room. With sections containing descriptions
        // and toggles, 500 px clips the labels and right column. Widening
        // keeps multi-line descriptions readable.
        .frame(width: 620, height: 520)
    }

    // MARK: - General

    private var generalTab: some View {
        // Use plain VStack with section headers instead of Form so the
        // sections render left-aligned and full-width on macOS rather than
        // getting squeezed into Form's narrow two-column layout.
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section(title: "Startup") {
                    LaunchAtLoginToggleView()
                }

                section(title: "Polling Rate") {
                    Text("Controller state is polled at 120 Hz for low-latency input.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                section(title: "Data & Storage") {
                    Text("Every preset, group, snapshot, statistic, calibration, and touchpad region is stored inside the app's sandbox container in Application Support and the Preferences plist. App Store updates only replace the app bundle; this container is left untouched, so nothing you've configured is lost on update.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Button("Reveal Data Folder") {
                            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                            let dataDir = appSupport.appendingPathComponent("JoystickConfig", isDirectory: true)
                            NSWorkspace.shared.activateFileViewerSelecting([dataDir])
                        }
                        Button("Export Backup…") {
                            exportBackup()
                        }
                        Button("Restore from Backup…") {
                            importBackup()
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Section header + indented content. Replaces SwiftUI's `Form > Section`
    /// which produces a cramped two-column layout on macOS.
    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
        }
    }

    // MARK: - Backup / Restore

    /// Bundle every piece of user state into one JSON envelope on the user's
    /// chosen filesystem location. Useful for migrating between Macs and for
    /// belt-and-suspenders backups even though the sandbox container
    /// already survives App Store updates.
    private func exportBackup() {
        let panel = NSSavePanel()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "JoystickConfig-Backup-\(formatter.string(from: Date())).json"
        panel.allowedContentTypes = [.json]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let envelope = makeBackupEnvelope()
            if let data = try? JSONSerialization.data(withJSONObject: envelope,
                                                      options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Pick a backup envelope and restore every piece of state from it.
    /// Existing data is overwritten by snapshotting first into the version
    /// history so the user can undo via Revert.
    private func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let data = try? Data(contentsOf: url),
                  let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            restoreBackup(envelope)
        }
    }

    private func makeBackupEnvelope() -> [String: Any] {
        var presetsArray: [[String: Any]] = []
        for p in presetStore.presets {
            if let data = try? JSONEncoder().encode(p),
               let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                presetsArray.append(dict)
            }
        }
        var groupsArray: [[String: Any]] = []
        for g in presetStore.groups {
            if let data = try? JSONEncoder().encode(g),
               let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                groupsArray.append(dict)
            }
        }
        // Mirror selected UserDefaults that we own.
        let defaults = UserDefaults.standard
        var prefs: [String: Any] = [:]
        for key in ["JoystickConfig.touchpadCalibration.v1",
                    "JoystickConfig.touchpadRegions.v1",
                    "JoystickConfig.tipCount",
                    "JoystickConfig.seededExampleGroups.v1"] {
            if let v = defaults.object(forKey: key) {
                // Encode Data values as base64 strings for JSON portability.
                if let d = v as? Data {
                    prefs[key] = d.base64EncodedString()
                } else {
                    prefs[key] = v
                }
            }
        }
        return [
            "schemaVersion": 1,
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "presets": presetsArray,
            "groups": groupsArray,
            "userDefaults": prefs
        ]
    }

    private func restoreBackup(_ envelope: [String: Any]) {
        // Presets
        if let presetsArray = envelope["presets"] as? [[String: Any]] {
            for dict in presetsArray {
                if let data = try? JSONSerialization.data(withJSONObject: dict),
                   let preset = try? JSONDecoder().decode(Preset.self, from: data) {
                    presetStore.savePreset(preset)
                }
            }
        }
        // Groups - overwrite by name if missing
        if let groupsArray = envelope["groups"] as? [[String: Any]] {
            for dict in groupsArray {
                if let data = try? JSONSerialization.data(withJSONObject: dict),
                   let group = try? JSONDecoder().decode(PresetGroup.self, from: data),
                   !presetStore.groups.contains(where: { $0.name == group.name }) {
                    presetStore.createGroup(named: group.name)
                }
            }
        }
        // UserDefaults
        if let prefs = envelope["userDefaults"] as? [String: Any] {
            let defaults = UserDefaults.standard
            for (key, value) in prefs {
                if let str = value as? String, let data = Data(base64Encoded: str), key.hasPrefix("JoystickConfig.touchpad") {
                    defaults.set(data, forKey: key)
                } else {
                    defaults.set(value, forKey: key)
                }
            }
        }
    }

    // MARK: - Controllers

    private var controllersTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Connected Controllers")
                    .font(.subheadline)
                Spacer()
                Button {
                    controllerService.refreshControllers()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }

            if controllerService.connectedControllers.isEmpty {
                ContentUnavailableView {
                    Label("No Controllers", systemImage: "gamecontroller")
                } description: {
                    Text("Connect a game controller to get started.")
                }
            } else {
                // Live press log across all controllers. Press the button
                // you want to map (PS, mute, paddle, FN, etc.) and the
                // exact name Apple's framework reports appears here. Lets
                // us extend `knownButtonMap` to match whatever Sony's
                // newest firmware names the button.
                if !controllerService.recentPhysicalPresses.isEmpty {
                    GroupBox("Live press log") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(controllerService.recentPhysicalPresses.prefix(10)) { entry in
                                HStack(spacing: 6) {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 6))
                                        .foregroundStyle(.green)
                                    Text(entry.name)
                                        .font(.caption.monospaced())
                                    Spacer()
                                    if let idx = entry.mappedIndex {
                                        Text("btn \(idx)")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.green)
                                    } else {
                                        Text("unmapped")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.bottom, 8)
                }

                List {
                    ForEach(Array(controllerService.connectedControllers.enumerated()), id: \.offset) { index, controller in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "gamecontroller.fill")
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading) {
                                    Text(controller.vendorName ?? "Unknown Controller")
                                        .font(.body)
                                    Text("Slot #\(index)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }

                            // Diagnostic: every button the physical input
                            // profile exposes, plus the index JoystickConfig
                            // assigns to it. Press any of these on the
                            // controller and use the same index in a binding.
                            DisclosureGroup("All detected buttons") {
                                let buttonNames = Array(controller.physicalInputProfile.buttons.keys).sorted()
                                if buttonNames.isEmpty {
                                    Text("No physical buttons reported by this controller.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    VStack(alignment: .leading, spacing: 2) {
                                        ForEach(buttonNames, id: \.self) { name in
                                            HStack(spacing: 6) {
                                                Text(name)
                                                    .font(.caption.monospaced())
                                                Spacer()
                                                Text(indexLabel(forButtonName: name, slot: index))
                                                    .font(.caption.monospaced())
                                                    .foregroundStyle(.tertiary)
                                            }
                                        }
                                    }
                                    .padding(.top, 4)
                                }
                            }
                            .font(.caption)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .padding()
    }

    /// Look up the binding index assigned to the named physical button.
    /// Used by the controller diagnostic so the user can match Edge paddles /
    /// FN buttons to the indices they should type into a binding row.
    private func indexLabel(forButtonName name: String, slot: Int) -> String {
        if let known = GameControllerService.publicKnownButtonMap[name] {
            return "btn \(known)"
        }
        return "btn ?"
    }

    // MARK: - About

    /// Marketing version from the bundle's Info.plist (CFBundleShortVersionString).
    /// Falls back to "?" if the plist entry is missing.
    private var bundleShortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    /// Build number from the bundle's Info.plist (CFBundleVersion).
    private var bundleBuildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    private var aboutTab: some View {
        VStack(spacing: 10) {
            if let appIcon = NSApp.applicationIconImage {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 96, height: 96)
            }

            Text("JoystickConfig")
                .font(.largeTitle)

            Text("Game Controller Configuration")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Link(destination: URL(string: "https://apps.apple.com/us/app/joystickconfig/id6761875440?mt=12")!) {
                HStack(spacing: 4) {
                    Text("Version \(bundleShortVersion) (Build \(bundleBuildNumber))")
                    Image(systemName: "arrow.up.right.square")
                }
                .font(.caption.monospacedDigit())
            }
            .help("Open JoystickConfig on the Mac App Store")
            .padding(.top, 2)

            Text("Configure game controller buttons, triggers, and joysticks\nto behave as keyboard and mouse input on macOS.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Text("Created by Ryleigh Newman")
                .font(.body)

            Link("ryleighnewman.com", destination: URL(string: "https://ryleighnewman.com")!)
                .font(.body)

            Text("This app is open source.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Link("View on GitHub", destination: URL(string: "https://github.com/ryleighnewman/JoystickConfig")!)
                .font(.caption)

            Text("Copyright \u{00A9} 2026 Ryleigh Newman. All rights reserved.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Contact me if you ever need anything")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                TipJarWindowController.shared.show()
            } label: {
                Label("Support Development", systemImage: "heart.fill")
                    .frame(minWidth: 180)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .tint(.pink)
            .padding(.top, 8)
        }
        .padding()
    }
}

/// Self-contained toggle for the Launch at Login setting. Pulled out so
/// the Settings tab doesn't need to track the LoginItemService directly.
struct LaunchAtLoginToggleView: View {
    @StateObject private var service = LoginItemService.shared

    var body: some View {
        // Use a single-line Toggle. macOS Form right-aligns the toggle and
        // left-aligns its label cleanly when the label is a plain Text.
        // Description text goes underneath as a separate Form row so it
        // takes the full width and does not get truncated by the column.
        Toggle("Launch at Login", isOn: launchAtLoginBinding)
            .toggleStyle(.switch)
        Text("Open JoystickConfig automatically when you log in to macOS.")
            .font(.caption)
            .foregroundStyle(.secondary)
        if let err = service.lastError {
            Text(err)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var launchAtLoginBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { service.isEnabled },
            set: { _ = service.setEnabled($0) }
        )
    }
}
#endif
