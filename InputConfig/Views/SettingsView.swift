#if os(macOS)
import SwiftUI
import GameController

struct SettingsView: View {
    @EnvironmentObject var presetStore: PresetStore
    @EnvironmentObject var controllerService: GameControllerService
    @EnvironmentObject var mappingEngine: MappingEngine

    /// Which tab is currently visible. Replaces SwiftUI's `TabView` because
    /// `TabView`'s tab bar clips against a sheet's rounded top corners on
    /// macOS, leaving the tab pills half-cut. A plain segmented Picker sits
    /// safely inside the sheet's content area.
    @State private var selectedTab: SettingsTab = .general

    /// Mirrors the same `@AppStorage` key used by the main app scene so
    /// flipping this toggle immediately hides or shows the menu bar icon.
    @AppStorage("InputConfig.showMenuBarIcon") private var showMenuBarIcon = true
    /// Drives the system-wide "toggle most recent preset" hotkey. Same key
    /// AppState reads at launch to decide whether to register the chord.
    @AppStorage(GlobalHotKeyService.enabledDefaultsKey) private var globalHotkeyEnabled = false

    /// Controller poll rate in Hz. Mirrors the `pollHz` UserDefaults key
    /// that `MappingEngine.start(with:)` reads when scheduling its poll
    /// timer. Stored as Int (60/120/180/240). Changes take effect on the
    /// next preset activation.
    @AppStorage("InputConfig.pollHz") private var pollHz: Int = 120

    /// When true, the engine reads pollHzOnAC vs pollHzOnBattery
    /// depending on the Mac's current power source and re-installs the
    /// poll timer the moment that source changes. Off by default for
    /// existing users so the single-rate behaviour stays.
    @AppStorage("InputConfig.autoPollHzByPower") private var autoPollByPower: Bool = false
    @AppStorage("InputConfig.pollHzOnAC") private var pollHzOnAC: Int = 120
    @AppStorage("InputConfig.pollHzOnBattery") private var pollHzOnBattery: Int = 60

    /// Live references to the reliability services so the freeze
    /// detection toggle and "last freeze" timestamp update in place.
    @ObservedObject private var crashRecovery = CrashRecoveryService.shared
    @ObservedObject private var freezeWatchdog = FreezeWatchdogService.shared
    @ObservedObject private var accessibility = AccessibilityPermissionService.shared
    @State private var showingCursorRegions = false
    @State private var showingStickRegions = false

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
        .sheet(isPresented: $showingCursorRegions) {
            CursorRegionsView()
        }
        .sheet(isPresented: $showingStickRegions) {
            StickRegionsView()
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
                section(title: "Accessibility") {
                    HStack(spacing: 8) {
                        Image(systemName: accessibility.isTrusted ? "circle.fill" : "exclamationmark.triangle.fill")
                            .font(accessibility.isTrusted ? .system(size: 9) : .body)
                            .foregroundStyle(accessibility.isTrusted ? .green : .orange)
                        Text(accessibility.isTrusted ? "Accessibility access granted" : "Accessibility access not granted")
                            .font(.callout.weight(.medium))
                        Spacer()
                    }
                    .onAppear { accessibility.refresh() }

                    Text("InputConfig uses macOS Accessibility to send the keyboard and mouse actions you map to your controller. That is what lets a game controller operate macOS and your apps. It is used only to perform the mappings you set up; it does not read or monitor your keyboard or mouse, and nothing is logged or sent anywhere.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !accessibility.isTrusted {
                        HStack(spacing: 8) {
                            Button("Grant Access…") { accessibility.requestAccess() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            Button("Open Accessibility Settings") { accessibility.openSystemSettings() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                        Text("Click Grant Access, then turn on InputConfig under System Settings, Privacy and Security, Accessibility. This updates automatically once you do.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                section(title: "Startup") {
                    LaunchAtLoginToggleView()
                }

                section(title: "Menu Bar") {
                    Toggle("Show menu bar icon", isOn: $showMenuBarIcon)
                        .onChange(of: showMenuBarIcon) { _, newValue in
                            MenuBarController.shared.setVisible(newValue)
                        }
                    Text("When turned off, the gamecontroller icon in the macOS menu bar is hidden. The app stays running and all features remain available from the main window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section(title: "Keyboard Shortcut") {
                    Toggle("Universal shortcut to toggle the most recent preset",
                           isOn: $globalHotkeyEnabled)
                        .onChange(of: globalHotkeyEnabled) { _, on in
                            if on {
                                GlobalHotKeyService.shared.enable()
                            } else {
                                GlobalHotKeyService.shared.disable()
                            }
                        }
                    Text("Press \(GlobalHotKeyService.shared.shortcutDescription) anywhere to turn your most recently used preset on or off, even while another app is in front. Works system-wide and needs no extra permission.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section(title: "Reliability") {
                    Toggle("Restore active preset after a crash",
                           isOn: $crashRecovery.sessionRestoreEnabled)
                    Text("If the app exits unexpectedly, the next launch will re-activate the preset that was active before the crash. If a second crash happens within 90 seconds, recovery is skipped so a bad preset can't trap you in a restart loop. Force quitting from Activity Monitor behaves the same as a crash: your last active preset will come back.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle("Detect freezes and save diagnostics",
                           isOn: $freezeWatchdog.enabled)
                    Text("A background watchdog pings the main thread once a second. If the app stops responding for more than 15 seconds the freeze is logged and your active preset is force-saved, so even if you have to force quit while frozen, the next launch will restore it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.secondary)
                        if let when = crashRecovery.lastFreezeAt {
                            Text("Last freeze detected: \(when.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Last freeze detected: never")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                section(title: "Polling Rate") {
                    Toggle(isOn: $autoPollByPower) {
                        Label("Auto-switch on power source",
                              systemImage: "battery.100.bolt")
                    }
                    .onChange(of: autoPollByPower) { _, _ in
                        mappingEngine.applyPollRate()
                    }

                    if autoPollByPower {
                        HStack(spacing: 8) {
                            Image(systemName: "powerplug.fill")
                                .foregroundStyle(.green)
                                .frame(width: 16)
                            Picker("On power adapter", selection: $pollHzOnAC) {
                                Text("60 Hz").tag(60)
                                Text("120 Hz").tag(120)
                                Text("180 Hz").tag(180)
                                Text("240 Hz").tag(240)
                            }
                            .pickerStyle(.menu)
                            .onChange(of: pollHzOnAC) { _, _ in mappingEngine.applyPollRate() }
                        }
                        HStack(spacing: 8) {
                            Image(systemName: "battery.50")
                                .foregroundStyle(.orange)
                                .frame(width: 16)
                            Picker("On battery", selection: $pollHzOnBattery) {
                                Text("60 Hz").tag(60)
                                Text("120 Hz").tag(120)
                                Text("180 Hz").tag(180)
                                Text("240 Hz").tag(240)
                            }
                            .pickerStyle(.menu)
                            .onChange(of: pollHzOnBattery) { _, _ in mappingEngine.applyPollRate() }
                        }
                        Text("The engine switches between these rates the moment macOS reports a power-source change. Pick a lower rate for battery to stretch session time without restarting.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Picker("Controller poll rate", selection: $pollHz) {
                            Text("60 Hz - power saver").tag(60)
                            Text("120 Hz - default").tag(120)
                            Text("180 Hz - high precision").tag(180)
                            Text("240 Hz - maximum").tag(240)
                        }
                        .pickerStyle(.menu)
                        .onChange(of: pollHz) { _, _ in
                            // Live-apply: rebuild the poll timer right now so
                            // the running preset starts honoring the new rate
                            // within one tick. No restart, no preset reload.
                            mappingEngine.applyPollRate()
                        }
                    }

                    // Live readout: shows what the engine is *actually*
                    // ticking at. If the user changes the picker, this
                    // line updates immediately because `currentPollHz`
                    // is @Published and applyPollRate() updates it.
                    if mappingEngine.isRunning {
                        HStack(spacing: 6) {
                            Image(systemName: "play.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                            Text("Engine running at \(mappingEngine.currentPollHz) Hz")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Button("Pause") {
                                mappingEngine.stop()
                            }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                            .help("Stop the active preset. You can change the rate, then click Resume on the main screen to start again.")
                        }
                    } else if let last = mappingEngine.activePreset {
                        HStack(spacing: 6) {
                            Image(systemName: "pause.circle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                            Text("Engine stopped. Rate will be \(pollHz) Hz on next start.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Button("Resume") {
                                mappingEngine.start(with: last)
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .help("Re-start the most recently active preset with the chosen rate.")
                        }
                    } else {
                        Text("Default rate. Balances latency and battery life. New rate applies the moment you activate a preset.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if pollHz > 120 {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                            Text("Sacrifices battery life and CPU. Higher rates can also cause UI hitches in the binding editor while a preset is active. Drop back to 120 Hz if the app feels sluggish.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else if pollHz < 120 {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(.blue)
                                .font(.caption)
                            Text("Lower rate saves battery but may add noticeable latency on fast-twitch inputs like rapid-fire and gyro aim.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                section(title: "System Performance") {
                    SystemStatsPanel()
                }

                section(title: "Gaming Utilities") {
                    GamingUtilitiesPanel()
                }

                section(title: "Data & Storage") {
                    Text("Every preset, group, snapshot, statistic, calibration, and touchpad region is stored inside the app's sandbox container in Application Support and the Preferences plist. App Store updates only replace the app bundle; this container is left untouched, so nothing you've configured is lost on update.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Button("Reveal Data Folder") {
                            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                            let dataDir = appSupport.appendingPathComponent("InputConfig", isDirectory: true)
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
    /// Visually-grouped section card. Each section gets a bold header,
    /// inset content with consistent vertical rhythm, and a subtle
    /// rounded-rectangle background that delineates one section from
    /// the next. Improves readability of long tab contents (the user
    /// said the Controllers / About tabs were "not easy to see").
    private func section<Content: View>(title: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.top, 14)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 0.5)
        )
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
        panel.nameFieldStringValue = "InputConfig-Backup-\(formatter.string(from: Date())).json"
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
        // Trash (soft-deleted presets). Captures both the preset and the
        // original deletedAt timestamp so a "restore on new Mac" landing
        // doesn't reset the trash's chronological ordering. Older
        // restores that lack this field just skip the trash block.
        var trashArray: [[String: Any]] = []
        for snap in presetStore.snapshotTrashForBackup() {
            if let data = try? JSONEncoder().encode(snap),
               let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                trashArray.append(dict)
            }
        }
        // Mirror selected UserDefaults that we own.
        let defaults = UserDefaults.standard
        var prefs: [String: Any] = [:]
        // Every UserDefaults key the app owns. Adding new keys here is
        // how they get carried by Export Backup; missing entries silently
        // reset when the user restores on a new Mac. Grouped roughly
        // by subsystem for readability.
        let exportedKeys: [String] = [
            // Touchpad
            "InputConfig.touchpadCalibration.v1",
            "InputConfig.touchpadRegions.v1",
            "InputConfig.touchpadActiveDevice.v2",
            // Cursor / stick regions
            "InputConfig.cursorRegions.v1",
            "InputConfig.stickRegions.v1",
            // Cursor guard (gaming utilities)
            "CursorGuard.edgeConfine",
            "CursorGuard.edgeBufferPx",
            "CursorGuard.autoRecenter",
            "CursorGuard.recenterIntervalMs",
            "CursorGuard.hideWhileRunning",
            "CursorGuard.sensitivity",
            // Engine poll rate
            "InputConfig.pollHz",
            "InputConfig.autoPollHzByPower",
            "InputConfig.pollHzOnAC",
            "InputConfig.pollHzOnBattery",
            // UI
            "InputConfig.showMenuBarIcon",
            "InputConfig.debugLogExpanded",
            "VirtualController.scale",
            // External input
            "InputConfig.externalInput.excludeBuiltIn",
            // Update + session
            "InputConfig.updateCheck.enabled",
            "InputConfig.updateCheck.dismissedVersions",
            "InputConfig.sessionRestore.enabled",
            "InputConfig.freezeWatchdog.enabled",
            // Misc
            "InputConfig.tipCount",
            "InputConfig.seededExampleGroups.v1",
            "InputConfig.appliedDefaultGroupColors.v2",
        ]
        for key in exportedKeys {
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
            "trash": trashArray,
            "userDefaults": prefs
        ]
    }

    private func restoreBackup(_ envelope: [String: Any]) {
        // Schema-version gate. v1 is the only published format right now.
        // Anything higher means the backup was written by a newer app
        // version; we refuse rather than partially-restore unknown keys.
        // Anything missing the field at all is treated as v1 for
        // backwards compatibility with the original beta backups.
        let version = (envelope["schemaVersion"] as? Int) ?? 1
        guard version <= 1 else {
            NSLog("SettingsView.restoreBackup: unsupported schema version \(version) - aborting restore")
            return
        }

        // Presets
        if let presetsArray = envelope["presets"] as? [[String: Any]] {
            for dict in presetsArray {
                if let data = try? JSONSerialization.data(withJSONObject: dict),
                   let preset = try? JSONDecoder().decode(Preset.self, from: data) {
                    presetStore.savePreset(preset)
                }
            }
        }
        // Groups: match existing entries by UUID, not name. The old code
        // skipped a backup group when ANY existing group happened to
        // share its display name, which silently destroyed the user's
        // saved group color and merged unrelated presets together if
        // two users on different Macs both had a "Gaming" group. Going
        // through UUID lets us tell apart same-name-different-identity
        // and preserves the original group's color + name + ordering.
        if let groupsArray = envelope["groups"] as? [[String: Any]] {
            let existingIDs = Set(presetStore.groups.map { $0.id })
            for dict in groupsArray {
                guard let data = try? JSONSerialization.data(withJSONObject: dict),
                      let group = try? JSONDecoder().decode(PresetGroup.self, from: data) else {
                    continue
                }
                if existingIDs.contains(group.id) {
                    // Same group identity already exists locally; skip
                    // so we don't clobber the user's current name +
                    // color tint. (Future enhancement: surface a merge
                    // dialog rather than silently skipping.)
                    continue
                }
                presetStore.upsertGroup(group)
            }
        }
        // Trash: legacy backups don't have this section. Newer backups
        // include the recently-deleted preset list so a user restoring
        // on a new Mac sees the same trash bin they had on the original.
        if let trashArray = envelope["trash"] as? [[String: Any]] {
            for dict in trashArray {
                if let data = try? JSONSerialization.data(withJSONObject: dict),
                   let snap = try? JSONDecoder().decode(PresetStore.TrashSnapshot.self, from: data) {
                    presetStore.restoreTrashFromBackup(preset: snap.preset, deletedAt: snap.deletedAt)
                }
            }
        }
        // UserDefaults
        if let prefs = envelope["userDefaults"] as? [String: Any] {
            let defaults = UserDefaults.standard
            for (key, value) in prefs {
                if let str = value as? String, let data = Data(base64Encoded: str), key.hasPrefix("InputConfig.touchpad") {
                    defaults.set(data, forKey: key)
                } else {
                    defaults.set(value, forKey: key)
                }
            }
        }
    }

    // MARK: - Controllers

    private var controllersTab: some View {
        // Wrapped in a ScrollView with section helpers so the layout reads
        // top-down like the General tab. The previous version used
        // ContentUnavailableView which expanded to fill the whole sheet,
        // leaving a huge gap between the header and a floating empty state.
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section(title: "Connected Controllers") {
                    HStack {
                        Spacer()
                        Button {
                            controllerService.refreshControllers()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .controlSize(.small)
                    }
                    .padding(.bottom, -4)

                    if controllerService.connectedControllers.isEmpty {
                        // Compact empty state that sits flush under the
                        // header rather than centering itself in dead space.
                        emptyControllersCard
                    } else {
                        controllersList
                    }
                }

                if controllerService.connectedControllers.isEmpty {
                    section(title: "How to Connect") {
                        connectionTipsView
                    }
                }

                section(title: "Cursor Regions") {
                    Text("Draw zones on screen and bind them as Cursor Region inputs. Works with any pointer, including the built-in trackpad.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Button("Open Cursor Regions Editor…") {
                            showingCursorRegions = true
                        }
                        Text("\(CursorRegionService.shared.allRegions().count) defined")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                section(title: "Stick Regions") {
                    Text("Bind diagonals and quadrants on a stick as one input, instead of combining two axis half-bindings. Each stick has its own set.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Button("Open Stick Regions Editor…") {
                            showingStickRegions = true
                        }
                        let leftCount = StickRegionService.shared.regions(forStick: 0).count
                        let rightCount = StickRegionService.shared.regions(forStick: 1).count
                        Text("\(leftCount) left / \(rightCount) right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Quiet inline card replacing the old `ContentUnavailableView`. Keeps the
    /// "no controllers" message visible without claiming the entire sheet.
    private var emptyControllersCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text("No controllers connected")
                    .font(.body)
                Text("Plug in a USB controller or pair one over Bluetooth. It will show up here automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    /// Practical connection hints shown only when nothing is plugged in.
    private var connectionTipsView: some View {
        VStack(alignment: .leading, spacing: 10) {
            tipRow(icon: "cable.connector",
                   title: "USB",
                   body: "Plug the controller in with its USB cable. Wired DualSense, DualShock 4, Xbox, and 8BitDo show up immediately.")
            tipRow(icon: "wave.3.right",
                   title: "Bluetooth",
                   body: "Hold the controller's pair button until its light flashes, then add it from System Settings → Bluetooth.")
            tipRow(icon: "checkmark.seal",
                   title: "Supported",
                   body: "DualSense / DualSense Edge, DualShock 4, Xbox One / Series / Elite, Switch Pro, Joy-Cons, Stadia, 8BitDo, Steam Controller, and any MFi or HID gamepad.")
        }
    }

    @ViewBuilder
    private func tipRow(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.blue)
                .frame(width: 22, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var controllersList: some View {
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

                VStack(alignment: .leading, spacing: 8) {
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
                            // profile exposes, plus the index InputConfig
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
                        .padding(10)
                        .background(Color.secondary.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 8))
                    }
                }
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
        ScrollView {
            VStack(spacing: 22) {
                // App identity card - icon, name, tagline, version.
                VStack(spacing: 12) {
                    if let appIcon = NSApp.applicationIconImage {
                        Image(nsImage: appIcon)
                            .resizable()
                            .frame(width: 96, height: 96)
                    }
                    Text("InputConfig")
                        .font(.largeTitle.weight(.semibold))
                    Text("Universal Input Mapping for macOS")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Version \(bundleShortVersion) · Build \(bundleBuildNumber)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("Map controllers, keyboards, and mice to keyboard, mouse, MIDI, and more, anywhere on macOS.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 24)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .padding(.horizontal, 16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.secondary.opacity(0.12), lineWidth: 0.5)
                )

                // Creator + links.
                VStack(spacing: 6) {
                    Text("Created by Ryleigh Newman")
                        .font(.body.weight(.medium))
                    HStack(spacing: 12) {
                        Link(destination: URL(string: "https://ryleighnewman.com")!) {
                            Label("ryleighnewman.com", systemImage: "link")
                                .font(.callout)
                        }
                        Link(destination: URL(string: "https://github.com/ryleighnewman/InputConfig")!) {
                            Label("Open Source", systemImage: "chevron.left.forwardslash.chevron.right")
                                .font(.callout)
                        }
                    }
                    Text("Contact me if you ever need anything.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .padding(.horizontal, 16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.secondary.opacity(0.12), lineWidth: 0.5)
                )

                // Tip jar.
                Button {
                    TipJarWindowController.shared.show()
                } label: {
                    Label("Support Development", systemImage: "heart.fill")
                        .frame(minWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.pink)

                // Footer copyright.
                Text("Copyright \u{00A9} 2026 Ryleigh Newman. All rights reserved.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
            }
            .padding(20)
        }
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
        Text("Open InputConfig automatically when you log in to macOS.")
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
