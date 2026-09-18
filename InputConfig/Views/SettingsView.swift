#if os(macOS)
import SwiftUI
import AVFoundation
import GameController
import Carbon.HIToolbox

struct SettingsView: View {
    @EnvironmentObject var presetStore: PresetStore
    @EnvironmentObject var controllerService: GameControllerService
    @EnvironmentObject var mappingEngine: MappingEngine

    /// Which tab is currently visible. Replaces SwiftUI's `TabView` because
    /// `TabView`'s tab bar clips against a sheet's rounded top corners on
    /// macOS, leaving the tab pills half-cut. A plain segmented Picker sits
    /// safely inside the sheet's content area.
    @State private var selectedTab: SettingsTab

    /// Which tab the sheet opens on. The homepage About button passes
    /// .about; everywhere else defaults to General.
    init(initialTab: SettingsTab = .general) {
        _selectedTab = State(initialValue: initialTab)
    }

    /// Mirrors the same `@AppStorage` key used by the main app scene so
    /// flipping this toggle immediately hides or shows the menu bar icon.
    @AppStorage("InputConfig.showMenuBarIcon") private var showMenuBarIcon = true
    /// Controls the Dock icon (activation policy). Paired with the menu bar
    /// icon by a see-saw rule so at least one is always visible.
    @AppStorage("InputConfig.showDockIcon") private var showDockIcon = true
    /// Mirrors the key ContentView reads to pin the developer activity log
    /// under the detail pane. Off by default so the shipping UI stays clean.
    @AppStorage("InputConfig.showDebugLog") private var showDebugLog = true
    /// Drives the system-wide "toggle most recent preset" hotkey. Same key
    /// AppState reads at launch to decide whether to register the chord.
    @AppStorage(GlobalHotKeyService.enabledDefaultsKey) private var globalHotkeyEnabled = false

    /// Emergency stop. Defaults to on: a kill switch you have to switch on
    /// first is not a kill switch.
    @AppStorage(EmergencyStopService.enabledKey) private var panicHotkeyEnabled = true
    @AppStorage(EmergencyStopService.controllerKey) private var panicControllerEnabled = true
    @AppStorage(EmergencyStopService.controllerBtnKey) private var panicControllerButton =
        EmergencyStopService.defaultControllerButton
    @AppStorage(EmergencyStopService.holdSecondsKey) private var panicHoldSeconds =
        EmergencyStopService.defaultHoldSeconds
    /// Bumped when the chord changes so the warning line re-evaluates.
    @State private var panicSpecRevision = 0
    @State private var showingResetConfirm = false

    @AppStorage(FrontmostAppWatcher.enabledDefaultsKey) private var autoSwitchEnabled = false

    /// Controller poll rate in Hz. Mirrors the `pollHz` UserDefaults key
    /// that `MappingEngine.start(with:)` reads when scheduling its poll
    /// timer. Stored as Int (60/120/180/240). Changes take effect on the
    /// next preset activation.
    @AppStorage("InputConfig.pollHz") private var pollHz: Int = 120

    /// When true, the engine reads pollHzOnAC vs pollHzOnBattery
    /// depending on the Mac's current power source and re-installs the
    /// poll timer the moment that source changes. Defaults ON (also
    /// registered in AppState) so polling adapts to power out of the box.
    @AppStorage("InputConfig.autoPollHzByPower") private var autoPollByPower: Bool = true
    @AppStorage("InputConfig.pollHzOnAC") private var pollHzOnAC: Int = 120
    @AppStorage("InputConfig.pollHzOnBattery") private var pollHzOnBattery: Int = 60

    /// Live references to the reliability services so the freeze
    /// detection toggle and "last freeze" timestamp update in place.
    @ObservedObject private var crashRecovery = CrashRecoveryService.shared
    @ObservedObject private var freezeWatchdog = FreezeWatchdogService.shared
    @ObservedObject private var accessibility = AccessibilityPermissionService.shared
    /// The live press log, observed here (not via the controller service) so
    /// its per-press updates re-render only this sheet, never the root window.
    @ObservedObject private var pressLog = PhysicalPressLogStore.shared

    // App-level accessibility preferences (Settings > General > Accessibility).
    @AppStorage("InputConfig.a11y.textSize") private var a11yTextSize = 0
    @AppStorage("InputConfig.a11y.boldText") private var a11yBoldText = false
    @AppStorage("InputConfig.a11y.reduceTransparency") private var a11yReduceTransparency = false
    @AppStorage("InputConfig.a11y.reduceMotion") private var a11yReduceMotion = false

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case advanced = "Advanced"
        case controllers = "Devices"
        case about = "About"

        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .general: return "gear"
            case .advanced: return "slider.horizontal.3"
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
                    Label { Text(tab.rawValue) } icon: {
                        IconView(name: tab.systemImage, glyphHeight: 11)
                    }
                    .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Settings section")
            .padding(.horizontal, 40)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            Group {
                switch selectedTab {
                case .general: generalTab
                case .advanced: advancedTab
                case .controllers: controllersTab
                case .about: aboutTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // macOS Form needs more room. With sections containing descriptions
        // and toggles, 500 px clips the labels and right column. Widening
        // keeps multi-line descriptions readable.
        .frame(minWidth: 620, idealWidth: 620, minHeight: 520, idealHeight: 520)
    }

    // MARK: - General

    private var generalTab: some View {
        // Use plain VStack with section headers instead of Form so the
        // sections render left-aligned and full-width on macOS rather than
        // getting squeezed into Form's narrow two-column layout.
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section(title: "Accessibility permission") {
                    HStack(spacing: 8) {
                        Image(systemName: accessibility.isTrusted ? "circle.fill" : "exclamationmark.triangle.fill")
                            .font(accessibility.isTrusted ? .system(size: 9) : .body)
                            .foregroundStyle(accessibility.isTrusted ? .green : .orange)
                            .accessibilityHidden(true)
                        Text(accessibility.isTrusted ? "Accessibility access granted" : "Accessibility access not granted")
                            .font(.callout.weight(.medium))
                        Spacer()
                    }
                    .onAppear { accessibility.refresh() }

                    Text("Accessibility access is how InputConfig sends the keys and clicks you map. It is used only for your mappings; nothing is logged or sent anywhere.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !accessibility.isTrusted {
                        HStack(spacing: 8) {
                            Button("Grant Access…") { accessibility.requestAccess() }
                                .buttonStyle(.solidCompact)
                            Button("Open Accessibility Settings") { accessibility.openSystemSettings() }
                                .buttonStyle(.solidSecondaryCompact)
                        }
                        Text("Click Grant Access, then turn on InputConfig under Privacy and Security, Accessibility.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                section(title: "Text and motion") {
                    HStack(spacing: 10) {
                        Text("Text Size")
                            .font(.callout)
                        Picker("", selection: $a11yTextSize) {
                            Text("Small").tag(-1)
                            Text("Default").tag(0)
                            Text("Large").tag(1)
                            Text("Extra Large").tag(2)
                            Text("Huge").tag(3)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 400)
                        .accessibilityLabel("Text size")
                        Spacer()
                    }
                    Text("Scales all text in the app. macOS has no system-wide text size that apps like this one can follow, so it is set here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle("Bold text", isOn: $a11yBoldText)
                        .toggleStyle(.switch)
                    Text("Heavier text for more contrast.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Reduce transparency", isOn: $a11yReduceTransparency)
                        .toggleStyle(.switch)
                    Text("Solid window backgrounds instead of frosted glass.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Reduce motion", isOn: $a11yReduceMotion)
                        .toggleStyle(.switch)
                    Text("Turns off decorative animation. Live data still moves.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("The Mac's own Accessibility settings are honoured too. These apply to this app only.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                section(title: "Spoken feedback voice") {
                    SpeechVoicePicker()
                }

                section(title: "Startup") {
                    LaunchAtLoginToggleView()
                }

                section(title: "Dock & menu bar") {
                    Toggle("Show Dock icon", isOn: $showDockIcon)
                        .onChange(of: showDockIcon) { _, newValue in
                            // See-saw: turning one off while the other is
                            // already off pops the other back on, so InputConfig
                            // is never left with no way to reopen it.
                            if !newValue && !showMenuBarIcon {
                                showMenuBarIcon = true
                                MenuBarController.shared.setVisible(true)
                            }
                            AppState.applyDockIconVisible(newValue)
                        }

                    Toggle("Show menu bar icon", isOn: $showMenuBarIcon)
                        .onChange(of: showMenuBarIcon) { _, newValue in
                            if !newValue && !showDockIcon {
                                showDockIcon = true
                                AppState.applyDockIconVisible(true)
                            }
                            MenuBarController.shared.setVisible(newValue)
                        }

                    Text("One of these always stays on so you can reach the app. With the Dock icon off, InputConfig lives in the menu bar only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // The menu bar glyph: pick the one that says what you
                    // use the app for. Turns green while a preset runs
                    // whichever you choose.
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Menu bar icon")
                        MenuBarIconPicker()
                        Text("Turns green while a preset is running, whichever you pick.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }

                section(title: "Keyboard shortcut") {
                    Toggle("Universal shortcut to toggle the most recent preset",
                           isOn: $globalHotkeyEnabled)
                        .onChange(of: globalHotkeyEnabled) { _, on in
                            if on {
                                // Registration can fail when another app owns
                                // the chord; snap the switch back so Settings
                                // never shows a hotkey that is not live.
                                if !GlobalHotKeyService.shared.enable() {
                                    globalHotkeyEnabled = false
                                }
                            } else {
                                GlobalHotKeyService.shared.disable()
                            }
                        }
                    Text("\(GlobalHotKeyService.shared.shortcutDescription) turns your last-used preset on or off from any app. If another app owns the shortcut, this switches itself off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section(title: "Emergency stop") {
                    Text("Turns the active preset off and lets go of every key, mouse button, and note the app was holding. It does not turn the controller off or restart anything. It exists for the moment a preset is sending keys or moving the pointer and you cannot get to the app's Stop button: the pointer is confined, a stick is pushing it, or a key is stuck down. One press from the keyboard or a hold on the controller, and the Mac is yours again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle("Keyboard shortcut", isOn: $panicHotkeyEnabled)
                        .onChange(of: panicHotkeyEnabled) { _, on in
                            EmergencyStopService.shared.setEnabled(on)
                            if on && !EmergencyStopService.shared.isRegistered {
                                panicHotkeyEnabled = false
                            }
                        }
                    HStack(spacing: 10) {
                        Text("Shortcut")
                            .foregroundStyle(.secondary)
                        HotKeyRecorderField(spec: EmergencyStopService.shared.spec) { newSpec in
                            EmergencyStopService.shared.setSpec(newSpec)
                            panicHotkeyEnabled = EmergencyStopService.shared.isRegistered
                            panicSpecRevision &+= 1
                        }
                        .disabled(!panicHotkeyEnabled)
                        Spacer()
                    }
                    if EmergencyStopService.shared.spec.stealsATypingKey {
                        Label("This key will no longer type anywhere on the Mac. A function key avoids that.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("A single key works too. A function key like F13 is ideal: unused and one-handed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .id(panicSpecRevision)

                    Divider()

                    Toggle("Hold a button on the controller", isOn: $panicControllerEnabled)
                    Text("Works whatever the preset maps this button to, so the controller in your hand is always a way out. Holding it does nothing else; a normal press still does what the preset says.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Text("Button")
                            .foregroundStyle(.secondary)
                        Picker("", selection: $panicControllerButton) {
                            ForEach(BindingRowView.standardButtonLabels, id: \.index) { entry in
                                Text(entry.label).tag(entry.index)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 230)
                        Text("held for")
                            .foregroundStyle(.secondary)
                        Picker("", selection: $panicHoldSeconds) {
                            Text("1 second").tag(1.0)
                            Text("1.5 seconds").tag(1.5)
                            Text("2 seconds").tag(2.0)
                            Text("3 seconds").tag(3.0)
                            Text("4 seconds").tag(4.0)
                            Text("5 seconds").tag(5.0)
                        }
                        .labelsHidden()
                        .frame(width: 130)
                        Spacer()
                    }
                    .disabled(!panicControllerEnabled)

                    Text("The menu bar shows the current shortcut and hold. Any control can also be bound to Emergency Stop in the editor.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Advanced

    /// Advanced settings split out of General so the General tab stays short:
    /// automation, reliability/diagnostics, polling, system stats, the global
    /// gaming defaults, and data management.
    private var advancedTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section(title: "Automatic preset switching") {
                    Toggle("Switch presets when the front app changes",
                           isOn: $autoSwitchEnabled)
                    Text("A preset that lists apps (Automation panel) activates when one of them comes to the front, and the previous preset returns when you leave.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section(title: "Reliability") {
                    Toggle("Restore active preset after a crash",
                           isOn: $crashRecovery.sessionRestoreEnabled)
                    Text("After a crash or force quit, the next launch brings back the preset that was active. A second crash within 90 seconds skips this so a bad preset cannot trap you.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle("Detect freezes and save diagnostics",
                           isOn: $freezeWatchdog.enabled)
                    Text("If the app freezes for 15 seconds, the freeze is logged and the active preset is saved, so a force quit loses nothing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        if let when = crashRecovery.lastFreezeAt {
                            Text("Last freeze detected: \(when.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Last freeze detected: never")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        // The reports macOS writes when an app crashes or is
                        // killed. Shown once there is a reason to look.
                        if crashRecovery.didRecoverPreviousSession || crashRecovery.lastFreezeAt != nil {
                            Button {
                                CrashRecoveryService.openCrashReports()
                            } label: {
                                Label("Open Crash Reports", systemImage: "doc.text.magnifyingglass")
                            }
                            .buttonStyle(.solidSecondaryCompact)
                            .help("The reports macOS kept for InputConfig, in the Console app")
                        }
                    }

                    Toggle("Show the activity log", isOn: $showDebugLog)
                    Text("The live log at the bottom of the main window: controllers, presets, presses, permissions, and anything that fails. Its Save Report button makes a file to send with a bug report.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section(title: "Polling rate") {
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
                                .accessibilityHidden(true)
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
                                .accessibilityHidden(true)
                            Picker("On battery", selection: $pollHzOnBattery) {
                                Text("60 Hz").tag(60)
                                Text("120 Hz").tag(120)
                                Text("180 Hz").tag(180)
                                Text("240 Hz").tag(240)
                            }
                            .pickerStyle(.menu)
                            .onChange(of: pollHzOnBattery) { _, _ in mappingEngine.applyPollRate() }
                        }
                        Text("Switches the moment the Mac changes power source. A lower battery rate stretches a session.")
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
                                .accessibilityHidden(true)
                            Text("Engine running at \(mappingEngine.currentPollHz) Hz")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Button("Pause") {
                                mappingEngine.stop()
                            }
                            .buttonStyle(.solidSecondaryCompact)
                            .help("Stop the active preset. You can change the rate, then click Resume on the main screen to start again.")
                        }
                    } else if let last = mappingEngine.activePreset {
                        HStack(spacing: 6) {
                            Image(systemName: "pause.circle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                                .accessibilityHidden(true)
                            Text("Engine stopped. Rate will be \(pollHz) Hz on next start.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Button("Resume") {
                                mappingEngine.start(with: last)
                            }
                            .buttonStyle(.solidCompact)
                            .help("Re-start the most recently active preset with the chosen rate.")
                        }
                    }

                    if !autoPollByPower && pollHz > 120 {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                                .accessibilityHidden(true)
                            Text("Costs battery and CPU, and can make the editor hitch while a preset runs. Use 120 Hz if the app feels sluggish.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else if !autoPollByPower && pollHz < 120 {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(.blue)
                                .font(.caption)
                                .accessibilityHidden(true)
                            Text("Saves battery; rapid-fire and gyro aim may feel a touch slower.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                section(title: "System performance") {
                    SystemStatsPanel()
                }

                section(title: "Gaming utilities (global defaults)") {
                    GamingUtilitiesPanel()
                }

                section(title: "Data & storage") {
                    Text("Everything you configure lives in the app's container in Application Support. Updates never touch it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Button("Reveal Data Folder") {
                            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                            let dataDir = appSupport.appendingPathComponent("InputConfig", isDirectory: true)
                            NSWorkspace.shared.activateFileViewerSelecting([dataDir])
                        }
                        .buttonStyle(.solidSecondaryCompact)
                        Button("Export Backup…") {
                            exportBackup()
                        }
                        .buttonStyle(.solidSecondaryCompact)
                        Button("Restore from Backup…") {
                            importBackup()
                        }
                        .buttonStyle(.solidSecondaryCompact)
                    }
                }

                section(title: "Reset") {
                    Text("Puts every setting back to how the app shipped: appearance, poll rate, emergency stop, cursor utilities, calibration. Presets, folders, and backups stay.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Reset Settings to Default…") {
                        showingResetConfirm = true
                    }
                    .buttonStyle(.solidSecondaryCompact)
                    .confirmationDialog("Reset all settings to their defaults?",
                                        isPresented: $showingResetConfirm,
                                        titleVisibility: .visible) {
                        Button("Reset Settings", role: .destructive) {
                            AppSettingsReset.resetToDefaults()
                            mappingEngine.applyPollRate()
                            panicSpecRevision += 1
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Presets and folders are not touched.")
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
        // Every setting the app owns, found by prefix in its own defaults
        // domain rather than listed by hand. The hand-kept list had drifted:
        // the emergency-stop and panic hotkeys, the global activate hotkey,
        // auto-switch, the manual HID devices, the accessibility text
        // settings and more were all missing, so restoring on a new Mac
        // silently dropped the kill switch. A few keys are machine-local
        // and skipped on purpose.
        let skipped: Set<String> = [
            "InputConfig.lastActivatedPresetId", "InputConfig.recovery.lastFreezeAt",
            "InputConfig.TestBench", "InputConfig.midiSourceUniqueID",
        ]
        let exportedKeys: [String] = defaults.dictionaryRepresentation().keys
            .filter { key in
                AppSettingsReset.prefixes.contains(where: { key.hasPrefix($0) }) && !skipped.contains(key)
            }
            .sorted()
        for key in exportedKeys {
            if let v = defaults.object(forKey: key) {
                // Encode Data values as base64 strings for JSON portability.
                if let d = v as? Data {
                    prefs[key] = ["__data": d.base64EncodedString()]
                } else if JSONSerialization.isValidJSONObject([v]) {
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

        // Presets: match existing presets by UUID and skip any that already
        // exist locally, mirroring the Groups path below. Without this, a
        // restore silently overwrote a local preset and its edits whenever the
        // two shared a UUID (e.g. restoring onto a Mac that already has the
        // same preset). Skipping preserves the local copy.
        if let presetsArray = envelope["presets"] as? [[String: Any]] {
            let existingIDs = Set(presetStore.presets.map { $0.id })
            for dict in presetsArray {
                if let data = try? JSONSerialization.data(withJSONObject: dict),
                   var preset = try? JSONDecoder().decode(Preset.self, from: data) {
                    if existingIDs.contains(preset.id) { continue }
                    // Force a safe, app-generated on-disk filename. The decoded
                    // filename comes from an untrusted backup file and could
                    // contain path components (e.g. "../../") that savePreset
                    // would otherwise resolve outside the presets directory.
                    preset.filename = Preset.generateFilename()
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
                    // Untrusted backup: force a safe on-disk filename before it
                    // reaches the trash directory write (path-traversal guard).
                    var p = snap.preset
                    p.filename = Preset.generateFilename()
                    presetStore.restoreTrashFromBackup(preset: p, deletedAt: snap.deletedAt)
                }
            }
        }
        // UserDefaults. Every Data-typed key that export base64-encodes must
        // be base64-decoded here, or it is restored as a raw base64 string and
        // silently corrupted. Previously only "InputConfig.touchpad*" keys were
        // decoded, which dropped cursorRegions.v1 and stickRegions.v1.
        let dataKeys: Set<String> = [
            "InputConfig.touchpadCalibration.v1",
            "InputConfig.touchpadRegions.v1",
            "InputConfig.touchpadActiveDevice.v2",
            "InputConfig.cursorRegions.v1",
            "InputConfig.stickRegions.v1",
        ]
        if let prefs = envelope["userDefaults"] as? [String: Any] {
            let defaults = UserDefaults.standard
            for (key, value) in prefs {
                // Data values travel as base64 under a marker so any key can
                // carry one, not only the handful the old list knew about.
                if let dict = value as? [String: Any], let str = dict["__data"] as? String,
                   let data = Data(base64Encoded: str) {
                    defaults.set(data, forKey: key)
                } else if dataKeys.contains(key), let str = value as? String, let data = Data(base64Encoded: str) {
                    defaults.set(data, forKey: key)   // backups written before 1.5
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
                section(title: "Connected devices") {
                    HStack {
                        Spacer()
                        Button {
                            controllerService.refreshControllers()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.solidSecondaryCompact)
                    }
                    .padding(.bottom, -4)

                    if !hasAnyController {
                        // Compact empty state that sits flush under the
                        // header rather than centering itself in dead space.
                        emptyControllersCard
                    } else {
                        if !controllerService.connectedControllers.isEmpty {
                            controllersList
                        }
                        // Controllers macOS does not expose through the game
                        // controller framework (e.g. an 8BitDo in a non-MFi
                        // mode) are read over raw HID and were previously
                        // invisible here, which made it look like nothing was
                        // detected. List them too.
                        if !controllerService.rawHIDGamepadSlots.isEmpty {
                            rawHIDControllersList
                        }
                    }
                }

                if !hasAnyController {
                    section(title: "How to connect") {
                        connectionTipsView
                    }
                }

                // Screen regions and stick zones belong to a preset, and
                // are drawn from that preset's editor. The editors that used
                // to open from here worked on the shared working set and
                // saved to nothing: every zone drawn was gone at the next
                // launch, and a binding made against it dangled for good.
                section(title: "Screen regions and stick zones") {
                    Text("Zones belong to a preset. Open a preset, choose Edit, and draw screen regions or stick zones from a row's Options; they are saved with that preset.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// True when any controller is present through any path: a GameController
    /// framework device, the Steam virtual slot, or a raw-HID gamepad. The
    /// "Connected Controllers" section and the "How to Connect" hint key off
    /// this so a raw-HID-only controller no longer reads as "none detected".
    private var hasAnyController: Bool {
        !controllerService.connectedControllers.isEmpty
            || !controllerService.rawHIDGamepadSlots.isEmpty
            || controllerService.steamControllerSlot != nil
            || controllerService.debugMarketingFakeActive
    }

    /// Cards for controllers read directly over raw HID (anything macOS does
    /// not surface through the GameController framework, such as an 8BitDo in
    /// a non-MFi mode or a wired Xbox 360 pad). They map exactly like any
    /// other controller; this list just makes them visible in Settings.
    private var rawHIDControllersList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(controllerService.rawHIDGamepadSlots.keys.sorted(), id: \.self) { slot in
                if let gamepad = controllerService.rawHIDGamepadSlots[slot] {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            ControllerGlyph(height: 14)
                                .foregroundStyle(.green)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading) {
                                Text(gamepad.displayName)
                                    .font(.body)
                                Text("Slot #\(slot) · detected over raw HID")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        Text("macOS does not see this controller natively, so InputConfig reads it over HID. If it does not respond in a preset, switch it to a mode macOS reads; see Help for your model.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    /// Quiet inline card replacing the old `ContentUnavailableView`. Keeps the
    /// "no controllers" message visible without claiming the entire sheet.
    private var emptyControllersCard: some View {
        HStack(spacing: 14) {
            ControllerGlyph(height: 22)
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
                if !pressLog.recent.isEmpty {
                    GroupBox("Live press log") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(pressLog.recent.prefix(10)) { entry in
                                HStack(spacing: 6) {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 6))
                                        .foregroundStyle(.green)
                                        .accessibilityHidden(true)
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
                                ControllerGlyph(height: 14)
                                    .foregroundStyle(.blue)
                                    .accessibilityHidden(true)
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
                                    Text("No physical buttons.")
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

    /// Whether the About tab's changelog popover is open.
    @State private var showChangelog = false

    private var aboutTab: some View {
        ScrollView {
            VStack(spacing: 18) {
                aboutHero
                aboutStory
                aboutSourceAndSupport
                aboutCommunityRow
                aboutSiblingApp

                // Footer copyright.
                Text("Copyright \u{00A9} 2026 Ryleigh Newman. All rights reserved.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
            }
            .padding(20)
        }
    }

    /// Shared card chrome for the About rows, matching the rest of Settings.
    @ViewBuilder
    private func aboutCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 0.5)
            )
    }

    // MARK: About rows (mirrors YapToText's About page)

    /// The hero, one compact row: the icon, then the name, the version with
    /// the changelog button beside it, and the tagline.
    private var aboutHero: some View {
        HStack(alignment: .center, spacing: 14) {
            if let appIcon = NSApp.applicationIconImage {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("InputConfig").font(.title2.weight(.semibold))
                HStack(spacing: 8) {
                    Text("Version \(bundleShortVersion) (\(bundleBuildNumber))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Button("View Changelog") { showChangelog = true }
                        .buttonStyle(.solidSecondaryCompact)
                        .accessibilityLabel("View changelog, current version \(Changelog.currentVersion)")
                        .popover(isPresented: $showChangelog, arrowEdge: .bottom) {
                            changelogPopover
                        }
                }
                Text(storeSafe("A free accessibility tool that maps any input device to anything on your Mac.",
                               "An accessibility tool that maps any input device to anything on your Mac."))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var changelogPopover: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("What's new").font(.headline)
                ForEach(Changelog.entries) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.version).font(.subheadline.weight(.semibold))
                        ForEach(entry.points, id: \.self) { point in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("\u{2022}").foregroundStyle(.secondary).accessibilityHidden(true)
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

    private var aboutStory: some View {
        aboutCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Why did I build this?")
                    .font(.headline)
                Text("I built InputConfig as an accessibility tool, simply because I needed one. My hands don't work that well, which makes a keyboard and mouse difficult, so I depend on other devices to control my Mac.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The mapping tools out there were either expensive, missing important features, or not really built for the people using them.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text(storeSafe("So I made the input mapper of my dreams: free, endlessly customizable, and happy to treat any device - a game controller, a MIDI keyboard, a spare mouse - as a first-class way to drive a Mac. I hope it's helpful for you too. If you run into any problems, or have suggestions, please let me know.",
                               "So I made the input mapper of my dreams: open, endlessly customizable, and happy to treat any device - a game controller, a MIDI keyboard, a spare mouse - as a first-class way to drive a Mac. I hope it's helpful for you too. If you run into any problems, or have suggestions, please let me know."))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ryleigh Newman").font(.callout.weight(.semibold))
                    Link("ryleighnewman.com", destination: URL(string: "https://ryleighnewman.com")!)
                        .font(.caption)
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Open source + support, one row of two equal-height boxes with the
    /// Donate button pinned right - same layout as YapToText's About.
    private var aboutSourceAndSupport: some View {
        let boxHeight: CGFloat = 76
        return HStack(spacing: 12) {
            Link(destination: URL(string: "https://github.com/ryleighnewman/InputConfig")!) {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 22)
                    Text("View the source code on GitHub")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.forward").imageScale(.small).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .frame(height: boxHeight)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 0.5)
            )

            HStack(spacing: 10) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.pink)
                    .frame(width: 22)
                Text(storeSafe("Free forever. A tip is never expected, but would truly mean the world.",
                               "A tip is never expected, but would truly mean the world."))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 10)
                Button("Donate") {
                    TipJarWindowController.shared.show()
                }
                .buttonStyle(.solid)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .frame(height: boxHeight)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 0.5)
            )
        }
    }

    private var aboutCommunityRow: some View {
        aboutCard {
            HStack(spacing: 10) {
                Image(systemName: "person.2.fill")
                    .foregroundStyle(.orange)
                    .frame(width: 22)
                Text("To everyone who suggested features, tested rough builds, and told me exactly where it hurt: this app is shaped by you. Without this community, InputConfig wouldn't exist. Thank you.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    private var aboutSiblingApp: some View {
        aboutCard {
            HStack(spacing: 12) {
                Image("YapToTextIcon")
                    .resizable().scaledToFit()
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("YapToText").font(.callout.weight(.semibold))
                    Text("InputConfig is built on the same foundation as YapToText, my free on-device dictation tool.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Link(destination: URL(string: "https://apps.apple.com/us/app/yaptotext/id6786382289?mt=12")!) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.forward.app")
                        Text("App Store")
                    }
                    .font(.callout)
                }
            }
        }
    }
}

/// Self-contained toggle for the Launch at Login setting. Pulled out so
/// the Settings tab doesn't need to track the LoginItemService directly.
/// Reset Settings to Default. Clears the app's preference keys, so every
/// @AppStorage and every service that reads UserDefaults falls back to its
/// built-in default. Records are kept: what has been seeded and migrated,
/// the tip count, the last-seen version, the MIDI port's identity, the
/// per-preset region layouts, and window positions.
enum AppSettingsReset {
    static let prefixes = ["InputConfig.", "CursorGuard.", "suppressAccessibilityIntro"]
    private static let kept: Set<String> = [
        "InputConfig.lastSeenVersion", "InputConfig.tipCount", "InputConfig.midiSourceUniqueID",
        "InputConfig.lastExampleSeedBuild", "InputConfig.appliedDefaultGroupColors.v2",
        "InputConfig.groups.builtInFlagged", "InputConfig.trimmedAnkiNotes.v1",
        "InputConfig.shippedSectionsFilled.v1",
        // One-shot migration flags. Dropping these on a settings reset
        // re-armed the shipped-notes backfill, which replaces the bindings
        // of every shipped preset with the shipped layout on next launch.
        "InputConfig.shippedNotesFilled.v1", "InputConfig.regionsPerPreset.v1",
        "InputConfig.lastActivatedPresetId", "InputConfig.recovery.lastFreezeAt",
        "InputConfig.cursorRegions.v1", "InputConfig.stickRegions.v1", "InputConfig.touchpadRegions.v1",
        "InputConfig.TestBench",
    ]
    private static let keptPrefixes = ["InputConfig.seededExample", "InputConfig.review."]

    static func isSetting(_ key: String) -> Bool {
        guard prefixes.contains(where: { key.hasPrefix($0) }) else { return false }
        if kept.contains(key) { return false }
        return !keptPrefixes.contains(where: { key.hasPrefix($0) })
    }

    @MainActor
    static func resetToDefaults() {
        let defaults = UserDefaults.standard
        guard let bundle = Bundle.main.bundleIdentifier,
              let domain = defaults.persistentDomain(forName: bundle) else { return }
        let keys = domain.keys.filter(isSetting)
        for key in keys { defaults.removeObject(forKey: key) }
        ActivityLog.shared.post(.event, "Settings", "Settings reset to defaults (\(keys.count) keys)")
    }
}

/// The voice that reads a binding's spoken phrase. Default is the Mac's own
/// System Voice from Accessibility, Spoken Content, so a voice chosen there
/// (a premium male voice, for instance) carries into the app. Any installed
/// voice can be picked instead, so the feedback voice can differ from the
/// reading voice.
struct SpeechVoicePicker: View {
    @AppStorage(FeedbackService.voiceKey) private var voiceID = ""
    @State private var voices: [AVSpeechSynthesisVoice] = []

    var body: some View {
        HStack(spacing: 10) {
            Text("Voice")
                .font(.callout)
            Picker("", selection: $voiceID) {
                Text("System voice (Accessibility, Spoken Content)").tag("")
                Divider()
                ForEach(voices, id: \.identifier) { v in
                    Text(label(v)).tag(v.identifier)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 420)
            .accessibilityLabel("Spoken feedback voice")
            Button("Preview") {
                FeedbackService.shared.speak("Copy. Paste. Undo.")
            }
            .buttonStyle(.solidSecondaryCompact)
            Spacer()
        }
        Text("Reads the phrase on any row with Speak turned on. System voice follows the Mac's Spoken Content setting; pick a different one here if the reading voice and the command voice should not sound alike. Enhanced and premium voices are the ones installed under Spoken Content, System Voice, Manage Voices.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        .onAppear { voices = FeedbackService.installedVoices() }
    }

    private func label(_ v: AVSpeechSynthesisVoice) -> String {
        let quality: String
        switch v.quality {
        case .premium: quality = " (Premium)"
        case .enhanced: quality = " (Enhanced)"
        default: quality = ""
        }
        let lang = Locale.current.localizedString(forIdentifier: v.language) ?? v.language
        return "\(v.name)\(quality), \(lang)"
    }
}

struct LaunchAtLoginToggleView: View {
    @StateObject private var service = LoginItemService.shared

    var body: some View {
        // Use a single-line Toggle. macOS Form right-aligns the toggle and
        // left-aligns its label cleanly when the label is a plain Text.
        // Description text goes underneath as a separate Form row so it
        // takes the full width and does not get truncated by the column.
        Toggle("Launch at login", isOn: launchAtLoginBinding)
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

// MARK: - Changelog

/// The in-app release notes: one entry per version, newest first. The About
/// tab's View Changelog button opens this list. Add a new entry here as part of
/// preparing each release.
enum Changelog {
    struct Entry: Identifiable {
        var id: String { version }
        let version: String
        let points: [String]
    }

    /// The running app's own version string, straight from the bundle: "1.1.1 (21)".
    static var currentVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    static let entries: [Entry] = [
        Entry(version: "1.5", points: [
            "Tap the Mac is now enhanced with additional compatibility on more MacBooks",
            "Quadruple and quintuple taps are now available in the binding editor",
            "Tap the Mac: Calibrate Taps is now in the Options of any tap row. Knock on the chassis and watch each strike to set the firmness threshold with a slider",
            "Your Mac is now an official input: every key on the keyboard and every click, scroll, and Force Touch on the mouse or trackpad can be mapped",
            "The Live Visualizer's Keyboard and Mouse & Trackpad templates are live: press a key or click and it lights on the diagram",
            "Four new presets for the Mac's own devices: Keyboard Deck, Trackpad & Mouse, Modifier Holds, and Double Click Deck, each with a home page showcase",
            "Screen regions are now their own input: draw an area of any display and it fires while the pointer is inside it",
            "The Live Visualizer has a Screen template showing the display, its regions, and the live pointer",
            "Zones and regions now belong to the preset they were drawn in",
            "The Live Visualizer builds its map from the connected controller, with proper PlayStation button shapes, a condensed layout, zoom, and a choice of background",
            "Every control in the Live Visualizer is clickable and opens its row in the editor",
            "The editor has a search field that finds any row by input, output, section, or note",
            "Rows sit under section headings, and Automatically insert available inputs adds a row for every control the device has",
            "The device menu lists everything the app can hear from: controllers, Bluetooth and USB devices, this Mac's keyboard and mouse, and MIDI sources",
            "A row's Options panel is laid out as boxes, with the input side on the left and the output side on the right",
            "The output menu now lists your Shortcuts, applications, presets, and every key by group",
            "Chords can hold up to three controls, chosen from the menu or scanned",
            "Accessories plugged into a PlayStation Access Controller or Xbox Adaptive Controller are picked up as inputs",
            "Bluetooth headset and hearing aid buttons can be mapped as media keys",
            "Gyro pointing follows the controller's tilt like a laser pointer, and the gyro zero learns itself",
            "Motion Calibration is one simple sheet with a 3D controller model and a Re-zero button you can assign",
            "Pointer motion from a stick, touchpad, or gyro is smooth, and the touchpad no longer lags while the Live Visualizer is open",
            "Touchpad Mouse works, with one-finger tap, two-finger tap, and double tap as inputs",
            "Rumble on a DualSense Edge is much stronger, its strength setting works, and vibration has a Duration slider",
            "New presets: One-Stick Driving, Access Controller, Cursor Regions, Hold & Double-Tap, Keyboard & Mouse Input, Shortcuts & Apps, and Touchpad Zones",
            "Every built-in preset now carries notes on every row",
            "The Smart Preset Maker can add touchpad-as-trackpad, gyro fine aim, and trigger rumble",
            "Every Feature Showcase opens its preset, with arrows to step through them",
            "The sidebar splits into My Presets and Built-in Presets, with coloured folder outlines and Move to Group",
            "Help is rewritten: shorter, plainer, and current, with every guide's steps in the app",
            "First launch opens with a welcome and the ways to reach out",
            "Settings: choose the menu bar icon, a spoken feedback voice, Next and Previous Preset, and Reset Settings",
            "The activity log shows everything the app does, pops out into its own window, and can save a report",
            "The emergency stop releases held keys, silences the motors, and stops any haptic",
            "VoiceOver speaks the Live Visualizer in plain words, and Reduce Motion applies immediately",
            "The app naps when idle and reads nothing from a controller nobody is looking at",
            "Fixed a crash on the first launch of a fresh install or after an update",
            "Fixed the pointer walking off target with two displays of different heights",
            "Fixed lone modifier keys being invisible to apps, and modifiers left held after quick presses",
            "Fixed mouse buttons 3 and up hanging the app",
            "Fixed the Speed sliders, Confine cursor, Recenter, and Hide cursor doing nothing while a preset ran",
            "Fixed touchpad zones being lost or copied between presets",
            "Fixed a fixed-point click forgetting its point on relaunch",
            "Presets saved by a newer version still open in an older one, and an unreadable preset is named in the log",
            "Export Backup carries every setting, and the privacy policy says nothing is transmitted",
        ]),
        Entry(version: "1.4", points: [
            "Tap the Mac. Your MacBook has a motion sensor, and InputConfig can now feel you knock on the case. Double tap or triple tap the palm rest or the lid to fire any output. It is the first input that needs no hardware at all: no controller, no MIDI device, nothing plugged in",
            "Taps are told apart by counting: two taps close together are a double, three are a triple, and a pause starts a new count. Typing is ignored on purpose, so working at the keyboard never sets it off",
            "New built-in preset Tap the Mac under Feature Showcases: double tap for Mission Control, triple tap to start dictation",
            "Emergency stop: one action that only ever stops, never starts. It halts the engine, releases every held key, button, and note, and gives the pointer back",
            "The emergency stop works three ways: a system-wide keyboard shortcut, holding Home / PS / Guide on the controller for two seconds, and a button in the menu bar. Any control can also be bound to it directly",
            "The controller hold works no matter what the preset maps that button to, so a preset that has taken over the keyboard and mouse can always be escaped from the controller itself",
            "Start Dictation as a System Function output: a control now presses the dictation key itself, exactly as pressing F5 does, so it works with no extra setup",
            "New Accessibility group under System Function: Start Dictation, Speak Selection, Zoom On / Off, Zoom In, and Zoom Out, so the accessibility shortcuts no longer have to be built by hand out of key combinations",
            "Per-preset shortcuts: give any preset its own system-wide key that switches to it, and press it again to stop it",
            "Chords: a binding can now require a second button, so Triangle + D-pad up can run a macro while D-pad up alone keeps its normal job. Set it under Press Behavior with the new While holding menu",
            "Gyro ratcheting: the new Pause Motion While Held app action stops motion aim while a button is held, so you can re-aim the controller without dragging the cursor, the way you lift a mouse",
            "The fn / Globe key is now available in two places, because macOS treats them as two different things. fn / Globe (hold) is under Modifier Keys and adds the fn modifier to another key, which is how shortcuts like Globe + E and Globe + D work. Globe Key (Emoji) is under Special Keys and presses the Globe key on its own, firing whatever you have set it to do",
            "Keyboard Brightness Up and Down added to the Display group",
            "Fixed: presets that use only the trackpad, a cursor region, or a Mac tap did nothing unless a game controller happened to be connected. They now work on their own, which is the whole point of them",
            "Presets can be reordered by dragging, and dragged from one folder into another. Drop a preset onto another to place it there. The order you set now sticks, instead of rearranging itself whenever a preset was edited",
            "Fixed a crash when dragging presets or folders in the sidebar",
            "The scan button now detects modifier keys pressed on their own, including Shift, Control, Option, Command and the fn / Globe key, plus the right Command key and F16 to F19. None of these could be scanned before",
            "The trigger deadzone bar is see-through, so the red inner-deadzone band stays visible while you pull the trigger",
            "InputConfig no longer opens a second copy of itself. Two copies fought over the keyboard and mouse, and only one could use the emergency stop",
            "The app now says so when another app has taken the emergency stop shortcut, instead of failing silently",
            "Editing a preset while it is running now takes effect straight away, instead of waiting for a restart",
            "Duplicating a binding or a slot, and converting a preset between controllers, now keep every setting. Chords, macros, deadzone and the rest used to be dropped",
            "Bindings switched to Axis or Hat by hand now pick a direction, so they fire the way the menu says",
            "Dragging with a controller works: holding a mapped click while moving the stick now sends real drag events, so window moves, text selection, sliders, and drag and drop all work",
            "Cursor motion from a stick no longer asks the system where the cursor is on every frame. This was the cause of high CPU with Variable Sensitivity on",
            "Slow scrolling from a stick is smooth instead of dead or jittery; the fractional part is carried between frames the way cursor motion already was",
            "A stick resting at the edge of its deadzone no longer chatters on and off every frame",
            "The binding editor scrolls and expands smoothly. Moving the pointer across the list no longer makes every row redraw, and row measurements no longer feed back into the layout",
            "Bindings can be reordered by dragging the handle on the left of each row. The row lifts and follows the pointer, the list opens a gap where it will land, and a row with its Options open folds them away while you drag it",
            "A controller reconnecting over Bluetooth no longer shows up twice in the list",
            "A Cancel button on the scan overlay, so a scan can be cancelled without a keyboard",
            "The help guides have a search field, plus new guides for chords, ratcheting, and tapping the Mac",
            "New built-in preset Anki in Desktop & Productivity: the face buttons rate flashcards, the bumpers undo and replay audio, stick clicks mark and bury, and the D-pad scrolls the card. Every row is labelled with its Anki action, and Anki is in the Smart Preset Maker's app list too",
            "Fixed: the release notes you are reading now did not appear for people who already had the app installed, so earlier updates arrived silently",
        ]),
        Entry(version: "1.3", points: [
            "Knob modes for MIDI dials: Dial mode treats the center of the knob as zero, so scrolling and mouse motion speed up the further you turn, with a deadzone to stop at centre",
            "Turn mode fires a nudge for every few steps of rotation, clockwise or counterclockwise, built for volume, brightness, and stepped scrolling",
            "Both modes work with the sensitivity curves, deadzone settings, and variable speed the analog sticks already use",
            "System volume as a fader: a new output that makes the Mac's volume follow a knob, the pitch wheel, aftertouch, or a controller trigger 1-to-1",
            "Turn Step setting per binding: Fine, Normal, Coarse, or Chunky nudge sensitivity for Turn mode",
            "The volume fader only takes over once you actually move the control, so activating a preset never jumps the volume",
            "New built-in preset MIDI: Knob Deck and a new welcome-screen demo showing MIDI devices driving the Mac",
            "System Function outputs: volume, mute, media keys, brightness, Mission Control, Launchpad, Spotlight, lock screen, screenshot, Siri Shortcuts, and opening any app or URL",
            "New built-in preset MIDI: Media Deck - pads and knobs running media keys, volume steps, and brightness",
            "A What's New popup after each update, so new features are never silently installed",
            "The YapToText shoutout now lives at the bottom of the welcome screen with a one-click App Store link",
            "An About button on the welcome screen opens the redesigned About page: the story behind the app, the changelog, source code, and support",
            "An Accessibility area in Settings: app-wide text size, bold text, reduced transparency, and reduced motion",
            "MIDI is now a full Live Visualizer template: a seven-octave velocity-shaded keyboard, named knob dials, pitch bend and aftertouch meters, a channel strip, and a live event log - switchable like any layout and automatic for MIDI presets",
            "Five new welcome-screen cards: Siri Shortcuts, Keyboard & Mouse as Input, Hold & Double-Tap, Per-App Auto-Switch, and Cursor Regions, ordered by importance",
            "The version number now shows in the menu bar popover",
        ]),

        Entry(version: "1.2.1", points: [
            "Fixes MIDI devices not appearing as an option when creating a binding",
            "MIDI now works with no game controller connected, so a MIDI keyboard or pad controller can drive your Mac on its own",
            "Connected MIDI devices are listed by name when you pick an input, so you can confirm yours was found",
            "Input groups are now called Input Device rather than Joystick, since a group can hold MIDI, keyboard, and mouse bindings too",
            "A group no longer warns about a missing controller when nothing in it needs one",
            "The scan panel now tells you that you can play a note or twist a knob to map it",
        ]),

        Entry(version: "1.2", points: [
            "MIDI devices can now be used as an input: bind notes, pads, knobs, the pitch wheel, the sustain pedal, and aftertouch to keys, clicks, macros, or anything else",
            "DualSense Edge extra buttons: the back paddles, both FN buttons, and mute are now bindable like any other input, over Bluetooth and USB",
            "Light bar colors now work over Bluetooth: preset colors, the RGB cycle, and brightness all reach the controller wirelessly",
            "A new DualSense Edge help guide covers binding the extra buttons",
            "More reliable controller data reading behind the scenes, with an automatic fallback when a Bluetooth session goes quiet",
        ]),
        Entry(version: "1.1.1", points: [
            "Fixes a crash that prevented InputConfig from launching on macOS 14 Sonoma",
        ]),
        Entry(version: "1.1", points: [
            "431 built-in presets, over 300 of them new: games, creative and productivity apps, and accessibility workflows including VoiceOver Navigation, Numeric Keypad, Menu Bar and Dock, Emulator, and Comic Reader",
            "Much broader controller compatibility: DualShock 3, Logitech F-series in D mode, fight sticks, multi-mode pads, and wheels, with correct d-pad handling on far more controllers",
            "Keyboard shortcut outputs with modifiers (Cmd+C and friends) now fire as real combos",
            "Fixed stuck mouse buttons after sleep, stuck MIDI controllers and pitch bend after stopping a preset, and edits to a running preset not applying until reactivation",
            "Crash recovery now fully restores your active preset, including restarting the mapping engine",
            "Macros: Toggle plus Macro works as documented, the editor shows macro state accurately, and duplicating a binding keeps every setting",
            "VoiceOver: the input scan overlay announces itself and speaks what it detected, and the binding editor controls are labeled",
            "Live Visualizer: the zoomed controller map stays cleanly inside its panel",
            "Faster and lighter: large reductions in per-frame work across the input path and the interface",
        ]),
        Entry(version: "1.0", points: [
            "Initial release: map any controller, keyboard, or mouse to keyboard, mouse, MIDI, and more, anywhere on macOS",
            "Preset system with groups, notes, per-preset light bar colors, and app auto-activation",
            "Scan to bind: press any control and it maps instantly",
            "Live Visualizer with customizable widget layout",
            "Turbo, macros, hold and double-tap actions, haptics, and spoken feedback per binding",
            "Touchpad calibration and regions, gyroscope aim, deadzone tuning, one-stick driving",
            "MIDI notes, CC, and pitch bend outputs through a built-in virtual MIDI port",
        ]),

        // Everything below shipped under the app's original name,
        // JoystickConfig, before the rename to InputConfig.
        Entry(version: "1.2 (as JoystickConfig)", points: [
            "Support for controllers beyond Apple's framework: the app now reads raw HID gamepads directly, with a descriptor parser and a controller profile database",
            "Your Mac's own keyboard and mouse can be used as input sources",
            "Cursor regions and stick regions: fire bindings when the pointer or a stick enters a zone you draw",
            "Crash recovery restores your active preset after an unexpected quit",
            "Menu bar icon with quick preset switching",
            "Freeze watchdog and cursor guard for a safer always-on experience",
        ]),
        Entry(version: "1.1 (as JoystickConfig)", points: [
            "MIDI output: send notes, CC, and pitch bend to any music app through a built-in virtual port",
            "Steam Controller support",
            "Controller touchpad as a mouse, with calibration",
            "Deadzone calibration with a live plot",
            "Motion calibration for gyroscope presets",
            "Usage statistics, a test bench for trying bindings, and Launch at Login",
        ]),
        Entry(version: "1.0 (as JoystickConfig)", points: [
            "The original release: map a game controller to keyboard and mouse anywhere on macOS",
            "Presets, the mapping engine, and scan to bind",
            "DualSense light bar control and haptic feedback",
        ]),
    ]
}


// MARK: - What's New popup

/// Shown once after every app update: the changelog entry for the version
/// the user just landed on, so new features are never silently installed.
/// ContentView drives presentation by comparing the last-seen version in
/// UserDefaults against the bundle's current version.
struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss

    /// The version the user last saw notes for. Everything released after it
    /// is included, so upgrading across two releases does not skip one.
    var since: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            featuresPage

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.solid)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private var featuresPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if let appIcon = NSApp.applicationIconImage {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 44, height: 44)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Welcome to version \(Changelog.currentVersion)")
                        .font(.title2.weight(.bold))
                    Text("Here's what's new since your last update.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(points.prefix(10), id: \.self) { point in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\u{2022}").foregroundStyle(.secondary).accessibilityHidden(true)
                        Text(point).font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("The full list is under the version number in Settings, About.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(12)
            .innerWell(radius: Metrics.sectionRadius)
        }
    }

    /// Every point released since the version the user last saw, newest
    /// release first. Falls back to the newest release on its own.
    private var points: [String] {
        guard let since,
              let index = Changelog.entries.firstIndex(where: { $0.version == since }),
              index > 0
        else { return Changelog.entries.first?.points ?? [] }
        return Changelog.entries[0..<index].flatMap(\.points)
    }
}


// MARK: - Shortcut recorder

/// Click, then press the chord you want. Records the next key press that
/// carries at least one modifier, so a bare letter cannot be captured as a
/// system-wide shortcut by accident.
struct HotKeyRecorderField: View {
    let spec: HotKeySpec
    let onRecord: (HotKeySpec) -> Void

    @State private var recording = false
    /// Set when the user pressed a key with no modifiers, which macOS will
    /// not register as a global shortcut.
    @State private var needsModifier = false
    @State private var monitor: Any?
    @State private var current: HotKeySpec

    init(spec: HotKeySpec, onRecord: @escaping (HotKeySpec) -> Void) {
        self.spec = spec
        self.onRecord = onRecord
        _current = State(initialValue: spec)
    }

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording
                 ? (needsModifier ? "Add \u{2318} \u{2325} \u{2303} or \u{21E7}" : "Press a key…")
                 : current.displayString)
                .font(.body.monospaced())
                .frame(minWidth: 130)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(recording ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(recording ? Color.accentColor : Color.clear, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("Click, then press the shortcut you want. It needs at least one of Command, Option, Control, or Shift: macOS will not hand an app a shortcut that is a single key on its own.")
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        needsModifier = false
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            var mods: UInt32 = 0
            if event.modifierFlags.contains(.control) { mods |= UInt32(controlKey) }
            if event.modifierFlags.contains(.option)  { mods |= UInt32(optionKey) }
            if event.modifierFlags.contains(.shift)   { mods |= UInt32(shiftKey) }
            if event.modifierFlags.contains(.command) { mods |= UInt32(cmdKey) }
            if event.keyCode == UInt16(kVK_Escape) && mods == 0 {
                stop()
                return nil
            }
            // At least one modifier is required. Measured on macOS 26:
            // RegisterEventHotKey never fires for a modifier-less chord, for
            // a plain key and a function key alike, so accepting one here
            // produced a shortcut that looked set and silently did nothing.
            // Keep listening instead of recording a dead chord.
            guard mods != 0 else {
                needsModifier = true
                return nil
            }
            let recorded = HotKeySpec(keyCode: UInt32(event.keyCode), modifiers: mods)
            current = recorded
            onRecord(recorded)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}


/// A row of the menu bar glyphs to choose from; the chosen one wears a ring.
struct MenuBarIconPicker: View {
    @AppStorage(MenuBarIconChoice.storageKey) private var choiceRaw: String = MenuBarIconChoice.controller.rawValue

    private var choice: MenuBarIconChoice { MenuBarIconChoice(rawValue: choiceRaw) ?? .controller }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 8)], spacing: 8) {
            ForEach(MenuBarIconChoice.allCases) { option in
                Button {
                    choiceRaw = option.rawValue
                    MenuBarController.shared.refreshMenuBarImage()
                } label: {
                    Group {
                        if option == .controller, let glyph = NSImage(named: "ControllerGlyph") {
                            Image(nsImage: glyph)
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 22, height: 15)
                        } else {
                            Image(systemName: option.symbol)
                                .font(.system(size: 16, weight: .medium))
                        }
                    }
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(choice == option ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(choice == option ? Color.accentColor : Color.clear, lineWidth: 1.5)
                    )
                }
                .buttonStyle(.plain)
                .help(option.label)
                .accessibilityLabel("\(option.label) menu bar icon")
                .accessibilityAddTraits(choice == option ? .isSelected : [])
            }
        }
    }
}

#if DEBUG
/// Marketing capture only: App Store screenshots may not call the app
/// "free", so the About page swaps those lines while the
/// `inputconfig.debug.nofree` toggle is on. Release builds always show
/// the normal copy.
@MainActor private func storeSafe(_ normal: String, _ storeCopy: String) -> String {
    DebugMarketing.shared.noFree ? storeCopy : normal
}
#else
@MainActor private func storeSafe(_ normal: String, _ storeCopy: String) -> String { normal }
#endif
