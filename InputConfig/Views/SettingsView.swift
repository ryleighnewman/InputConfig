#if os(macOS)
import SwiftUI
import AVFoundation
import GameController
import Carbon.HIToolbox

struct SettingsView: View {
    /// The size Settings opens at, in its own window and in the sheet
    /// ContentView presents it in. One number for both: a sheet narrower
    /// than this cut off the left side of the About page.
    static let preferredSize = CGSize(width: 660, height: 620)

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
    /// Mirrors the key ContentView reads to pin the activity log under the
    /// detail pane. On until turned off (see ContentView.showDebugLog).
    @AppStorage("InputConfig.showDebugLog") private var showDebugLog = true
    /// Which letters the face buttons are shown with (Controllers tab).
    @AppStorage(FaceLetters.defaultsKey) private var faceLetters = FaceLetters.automatic.rawValue
    /// Drives the system-wide "toggle most recent preset" hotkey. Same key
    /// AppState reads at launch to decide whether to register the chord.
    @AppStorage(GlobalHotKeyService.enabledDefaultsKey) private var globalHotkeyEnabled = false

    /// Bumped when the emergency stop chord changes so the Emergency stop
    /// section's chord field and warning lines re-evaluate. The section
    /// bumps it on a recording; a reset or a restore here bumps it too.
    @State private var panicSpecRevision = 0
    /// Why the last recorded emergency stop chord was refused.
    @State private var panicChordRefusal: String?
    @State private var globalChordRefusal: String? {
        didSet { if let globalChordRefusal { AccessibilityNotification.Announcement(globalChordRefusal).post() } }
    }
    @State private var showingResetConfirm = false
    /// The preset Pause stopped, so Resume can start that one again.
    @State private var pausedPresetID: UUID?
    /// Result of Export Backup or Restore from Backup, shown as an alert.
    @State private var backupMessage: (title: String, text: String)?

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
    @AppStorage("InputConfig.a11y.highContrast") private var a11yHighContrast = false
    @AppStorage(ScanTiming.key) private var scanSeconds = 20
    @AppStorage(InputSimulator.followLayoutKey) private var keysFollowLayout = false
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
            Picker("Settings section", selection: $selectedTab) {
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
        .frame(minWidth: Self.preferredSize.width, idealWidth: Self.preferredSize.width,
               minHeight: Self.preferredSize.height, idealHeight: Self.preferredSize.height)
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

                    Text("Used to send the keys and clicks you map, and to read the keyboard and mouse while a preset or Scan uses them. Nothing is recorded or sent anywhere.")
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
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                section(title: "Accent color") {
                    AccentColorPicker()
                    Text("Automatic follows System Settings. The last one picks any color.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section(title: "Text and motion") {
                    // Label above the picker, like Menu bar icon below: beside
                    // it, the five segments grew with the text size and
                    // squeezed the label.
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Text size")
                        Picker("Text size", selection: $a11yTextSize) {
                            Text("Small").tag(-1)
                            Text("Default").tag(0)
                            Text("Large").tag(1)
                            Text("Extra Large").tag(2)
                            Text("Huge").tag(3)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 460)
                        .accessibilityLabel("Text size")
                    }
                    Text("Scales all text in the app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle("Bold text", isOn: $a11yBoldText)
                        .toggleStyle(.switch)

                    Toggle("Higher contrast text", isOn: $a11yHighContrast)
                        .toggleStyle(.switch)
                    Text("Brightens hints and status lines. On by itself when Increase Contrast is on in System Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle("Reduce transparency", isOn: $a11yReduceTransparency)
                        .toggleStyle(.switch)

                    Toggle("Reduce motion", isOn: $a11yReduceMotion)
                        .toggleStyle(.switch)
                    Text("Live data still moves.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("These apply to this app only.")
                        .font(.caption)
                        .foregroundStyle(.hint)
                }

                section(title: "Scan") {
                    Picker("Scan waits for", selection: $scanSeconds) {
                        Text("10 seconds").tag(10)
                        Text("20 seconds").tag(20)
                        Text("40 seconds").tag(40)
                        Text("1 minute").tag(60)
                        Text("Until canceled").tag(0)
                    }
                    .frame(maxWidth: 320)
                    Text("How long Scan waits for you to press a control. When time runs out it is said aloud. Changing it also sets how long the Mac key and mouse button scan waits.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section(title: "Keyboard output") {
                    Toggle("Keys follow the keyboard layout", isOn: $keysFollowLayout)
                    Text("On a keyboard layout other than US, a row set to a letter, digit or punctuation key types that character: on French AZERTY, A types a instead of q. Leave it off for games, which read keys by where they are, so W A S D stay on the same physical keys. Shortcuts with Command or Control always follow the layout.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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

                    Text("One of these always stays on so you can reach the app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // The menu bar glyph: pick the one that says what you
                    // use the app for. Turns green while a preset runs
                    // whichever you choose.
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Menu bar icon")
                        MenuBarIconPicker()
                        Text("Turns green while a preset runs.")
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
                                // never shows a hotkey that is not live. One
                                // of InputConfig's own shortcuts is named.
                                let chord = GlobalHotKeyService.spec
                                if EmergencyStopService.shared.claims(chord) {
                                    globalChordRefusal = "The emergency stop uses \(chord.displayString). Choose another emergency stop chord first."
                                    globalHotkeyEnabled = false
                                } else if let owner = presetStore.presets.first(where: { $0.activateHotKey == chord }) {
                                    globalChordRefusal = "\(chord.displayString) already activates \u{201C}\(owner.name)\u{201D}. Give that preset another shortcut first."
                                    globalHotkeyEnabled = false
                                } else if !GlobalHotKeyService.shared.enable() {
                                    globalChordRefusal = "Another app already uses \(chord.displayString)."
                                    globalHotkeyEnabled = false
                                } else {
                                    globalChordRefusal = nil
                                }
                            } else {
                                GlobalHotKeyService.shared.disable()
                            }
                        }
                    Text("\(GlobalHotKeyService.shared.shortcutDescription), from any app. If another app owns it, this switches off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let refusal = globalChordRefusal {
                        Text(refusal)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                section(title: "Emergency stop") {
                    EmergencyStopSettingsContent(specRevision: $panicSpecRevision,
                                                 chordRefusal: $panicChordRefusal)
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
                    Text("A preset that lists apps in its Automation panel turns on when one comes to the front; the previous one returns when you leave.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section(title: "Reliability") {
                    Toggle("Restore active preset after a crash",
                           isOn: $crashRecovery.sessionRestoreEnabled)
                    Text("InputConfig asks before starting it again, and starts it by itself after 20 seconds with no answer. A second crash soon after skips this, so a bad preset can't trap you.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle("Detect freezes and save diagnostics",
                           isOn: $freezeWatchdog.enabled)
                    Text("After 15 seconds frozen, the active preset is saved, so a force quit loses nothing.")
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
                                .foregroundStyle(.hint)
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
                            .help("The folder where macOS keeps crash reports, in the Finder (or the Console app, if the folder cannot be opened)")
                        }
                    }

                    Toggle("Show the activity log", isOn: $showDebugLog)
                    Text("At the bottom of the main window. Save Report makes a file to send with a bug report: the app's actions, preset and device names, and settings. Typed text, websites and Shortcut names are counted in characters, not written out.")
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
                            // Unset, the engine uses the single rate above;
                            // show that rather than a default it ignores.
                            Picker("On power adapter", selection: Binding(
                                get: { (UserDefaults.standard.object(forKey: "InputConfig.pollHzOnAC") as? Int) ?? pollHz },
                                // Applied here: picking the value the stored
                                // default already held changed nothing, so
                                // onChange never ran and the engine kept the
                                // old rate.
                                set: { pollHzOnAC = $0; mappingEngine.applyPollRate() })) {
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
                        Text("A lower rate on battery lasts longer.")
                            .font(.caption)
                            .foregroundStyle(.hint)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Picker("Controller poll rate", selection: $pollHz) {
                            Text("60 Hz, power saver").tag(60)
                            Text("120 Hz, default").tag(120)
                            Text("180 Hz, high precision").tag(180)
                            Text("240 Hz, maximum").tag(240)
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
                                // Through the store too, so the sidebar and
                                // menu bar stop showing the preset as running.
                                pausedPresetID = mappingEngine.activePreset?.id
                                mappingEngine.stop()
                                presetStore.deactivateAll()
                            }
                            .buttonStyle(.solidSecondaryCompact)
                            .help("Stop the active preset. Change the rate, then click Resume to start it again.")
                        }
                    } else if let pausedID = pausedPresetID,
                              let last = presetStore.presets.first(where: { $0.id == pausedID }) {
                        HStack(spacing: 6) {
                            Image(systemName: "pause.circle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                                .accessibilityHidden(true)
                            Text("Engine stopped. Rate will be \(MappingEngine.configuredPollHz()) Hz on next start.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Button("Resume") {
                                pausedPresetID = nil
                                presetStore.activatePreset(last)
                                mappingEngine.start(with: last)
                            }
                            .buttonStyle(.solidCompact)
                            .help("Start \(last.name) again with the chosen rate.")
                        }
                    }

                    if !autoPollByPower && pollHz > 120 {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                                .accessibilityHidden(true)
                            Text("Uses more battery and CPU. Use 120 Hz if the app feels sluggish.")
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
                    Text("Your presets and settings. Updates keep them; a built-in preset you never changed may be updated to its new layout (see What's New).")
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
                    HStack(spacing: 8) {
                        Button("Restore Built-in Presets") {
                            let count = presetStore.restoreBuiltInPresets()
                            backupMessage = (title: "Built-in presets",
                                             text: count == 0 ? "Every built-in preset is already in your library."
                                                : "\(count) built-in preset\(count == 1 ? " was" : "s were") put back. Ones you kept, edited or not, were left as they are.")
                        }
                        .buttonStyle(.solidSecondaryCompact)
                        Button("Check Older Presets Again") {
                            let count = LegacyRowCheck.shared.checkAgain()
                            backupMessage = (title: "Older presets",
                                             text: count == 0
                                                ? "There are no presets from before 1.6 to check."
                                                : "Presets made before 1.6 are offered again the next time a controller that 1.6 numbers differently connects.")
                        }
                        .buttonStyle(.solidSecondaryCompact)
                        Text("Moves rows recorded on a controller before 1.6 to the controls 1.6 reads.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .alert(backupMessage?.title ?? "", isPresented: Binding(
                        get: { backupMessage != nil },
                        set: { if !$0 { backupMessage = nil } })) {
                        Button("OK", role: .cancel) {}
                    } message: {
                        Text(backupMessage?.text ?? "")
                    }
                }

                section(title: "Reset") {
                    Text("Presets, folders, and backups stay.")
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
                            AppSettingsApply.applyAll(engine: mappingEngine, store: presetStore)
                            // The default stop chord may be a preset's now:
                            // the preset lets go and the stop registers.
                            presetStore.clearHotKeysClaimedByEmergencyStop()
                            EmergencyStopService.shared.refreshRegistration()
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
                .accessibilityAddTraits(.isHeader)
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
            do {
                let data = try JSONSerialization.data(withJSONObject: envelope,
                                                      options: [.prettyPrinted, .sortedKeys])
                try data.write(to: url, options: .atomic)
                ActivityLog.shared.info("Settings", "Backup saved to \(url.lastPathComponent)")
            } catch {
                ActivityLog.shared.error("Settings", "Backup could not be saved: \(error.localizedDescription)")
                backupMessage = ("Backup Not Saved", error.localizedDescription)
            }
        }
    }

    /// Pick a backup envelope and restore from it. Presets and folders
    /// already on this Mac are kept; the backup's are added beside them.
    private func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard let data = try? Data(contentsOf: url),
                  let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  envelope["presets"] != nil || envelope["userDefaults"] != nil else {
                backupMessage = ("Not a Backup",
                                 "\(url.lastPathComponent) is not an InputConfig backup. To add a single preset, use Import Preset File.")
                return
            }
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
        let exportedKeys: [String] = defaults.dictionaryRepresentation().keys
            .filter { AppSettingsReset.isRestorable($0) && !AppSettingsReset.isUpgradeRecord($0) }
            .sorted()
        for key in exportedKeys {
            if let v = defaults.object(forKey: key) {
                // Encode Data values as base64 strings for JSON portability.
                if let d = v as? Data {
                    prefs[key] = ["__data": d.base64EncodedString()]
                } else if key == HIDDeviceRegistry.rememberedKey, let list = v as? [String] {
                    // A device's key carries its serial hashed with a salt
                    // that stays on this Mac, so it cannot match on another.
                    // The backup also carries the plain vendor and product
                    // ("vvvv:pppp"), which still reconnects it after a
                    // restore there. Only in the backup: on this Mac that
                    // key would connect every identical pad.
                    let pairs = list.compactMap { $0.count >= 9 ? String($0.prefix(9)) : nil }
                    // A tag of this Mac's salt, so a restore here can tell
                    // and leave the plain keys out.
                    prefs[key] = Array(Set(list + pairs)).sorted() + [AppSettingsReset.saltTagPrefix + AppSettingsReset.saltTag]
                } else if JSONSerialization.isValidJSONObject([v]) {
                    prefs[key] = v
                }
            }
        }
        var envelope: [String: Any] = [
            "schemaVersion": 1,
            // Which version made it, and when 1.6 first ran on that Mac, so a
            // restore knows which presets and trash entries 1.6 already upgraded.
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "presets": presetsArray,
            "groups": groupsArray,
            "trash": trashArray,
            "userDefaults": prefs
        ]
        if let first = defaults.object(forKey: PresetStore.first16LaunchKey) as? Date {
            envelope["first16LaunchAt"] = first.timeIntervalSince1970
        }
        // Gyro calibration lives in its own file; carried so a new Mac
        // starts with the pads already calibrated.
        if let motion = MotionCalibrationService.shared.exportData() {
            envelope["motionCalibration"] = motion.base64EncodedString()
        }
        return envelope
    }

    private func restoreBackup(_ envelope: [String: Any]) {
        // v1 is the only published format. A newer backup is refused
        // rather than partly restored.
        let version = (envelope["schemaVersion"] as? Int) ?? 1
        guard version <= 1 else {
            backupMessage = ("Backup From a Newer Version",
                             "This backup was made by a newer InputConfig. Update the app, then restore it.")
            return
        }
        func decodeAll<T: Decodable>(_ key: String, as type: T.Type, unreadable: inout Int) -> [T] {
            guard let list = envelope[key] as? [[String: Any]] else { return [] }
            return list.compactMap { dict in
                guard let data = try? JSONSerialization.data(withJSONObject: dict),
                      let value = try? JSONDecoder().decode(T.self, from: data) else {
                    unreadable += 1
                    return nil
                }
                return value
            }
        }
        var unreadable = 0
        let presets = decodeAll("presets", as: Preset.self, unreadable: &unreadable)
        let groups = decodeAll("groups", as: PresetGroup.self, unreadable: &unreadable)
        let trash = decodeAll("trash", as: PresetStore.TrashSnapshot.self, unreadable: &unreadable)
        // A backup made by 1.6 names its version (1.5 wrote none); one from
        // an early 1.6 build carried its one-shot flags instead.
        let prefs = envelope["userDefaults"] as? [String: Any]
        let madeBy16 = envelope["appVersion"] != nil
            || prefs?["InputConfig.builtInRowFixes16.v1"] != nil
            || prefs?["InputConfig.desktopNavigationAClicks.v1"] != nil
        let source16 = (envelope["first16LaunchAt"] as? Double).map(Date.init(timeIntervalSince1970:))
        var summary = presetStore.restoreFromBackup(presets: presets, groups: groups, trash: trash,
                                                    madeBy16: madeBy16, source16Since: source16)
        summary.unreadable = unreadable

        // UserDefaults. Data values travel as base64 under a "__data"
        // marker; backups written before 1.5 stored a few as bare strings.
        let dataKeys: Set<String> = [
            "InputConfig.touchpadCalibration.v1",
            "InputConfig.touchpadRegions.v1",
            "InputConfig.touchpadActiveDevice.v2",
            "InputConfig.cursorRegions.v1",
            "InputConfig.stickRegions.v1",
        ]
        var settingsRestored = 0
        var skippedSettings = 0
        if let prefs = envelope["userDefaults"] as? [String: Any] {
            let defaults = UserDefaults.standard
            // Only the app's own keys, and only values UserDefaults can hold:
            // a null crashed the app, a negative panic key code crashed every
            // launch after, and keys such as AppleLanguages could be planted.
            for (key, rawValue) in prefs where AppSettingsReset.isRestorable(key)
                && !AppSettingsReset.isRestoreSkipped(key) {
                guard let value = AppSettingsReset.restorableValue(rawValue, forKey: key) else {
                    skippedSettings += 1
                    continue
                }
                let restored: Any
                if let dict = value as? [String: Any], let str = dict["__data"] as? String,
                   let data = Data(base64Encoded: str) {
                    restored = data
                } else if dataKeys.contains(key), let str = value as? String, let data = Data(base64Encoded: str) {
                    restored = data
                } else {
                    restored = value
                }
                if key == "InputConfig.touchpadCalibration.v1", let data = restored as? Data,
                   let calibration = try? JSONDecoder().decode(TouchpadCalibration.self, from: data) {
                    // Through the service: it also keeps a file copy, which
                    // wins over UserDefaults at launch.
                    TouchpadService.shared.saveCalibration(calibration)
                } else {
                    defaults.set(AppSettingsReset.merged(restored, into: key, idMap: summary.idMap), forKey: key)
                }
                settingsRestored += 1
            }
        }
        if let motion = envelope["motionCalibration"] as? String, let data = Data(base64Encoded: motion) {
            MotionCalibrationService.shared.mergeImported(data)
        }
        // The stored values changed underneath the running services.
        AppSettingsApply.applyAll(engine: mappingEngine, store: presetStore)
        // Only now is the backup's Emergency Stop chord in place, so preset
        // shortcuts are checked against it here, not against this Mac's
        // before the restore (which cleared one for nothing, or let a preset
        // and the stop share a chord).
        presetStore.clearHotKeysClaimedByEmergencyStop()
        // The stop tried to register before that preset let go of its chord.
        EmergencyStopService.shared.refreshRegistration()
        panicSpecRevision += 1

        var lines: [String] = []
        lines.append("\(summary.presetsAdded) preset\(summary.presetsAdded == 1 ? "" : "s") added")
        if summary.builtInsReplaced > 0 { lines.append("\(summary.builtInsReplaced) built-in preset\(summary.builtInsReplaced == 1 ? "" : "s") from the backup added beside this Mac\u{2019}s copy, named \u{201C}(from backup)\u{201D}") }
        if summary.presetsSkipped > 0 { lines.append("\(summary.presetsSkipped) already here, kept as they are") }
        if summary.groupsAdded > 0 { lines.append("\(summary.groupsAdded) folder\(summary.groupsAdded == 1 ? "" : "s") added") }
        if summary.trashAdded > 0 { lines.append("\(summary.trashAdded) in the Trash") }
        lines.append("\(settingsRestored) setting\(settingsRestored == 1 ? "" : "s") restored")
        if skippedSettings > 0 { lines.append("\(skippedSettings) setting\(skippedSettings == 1 ? "" : "s") skipped as invalid") }
        if summary.unreadable > 0 { lines.append("\(summary.unreadable) item\(summary.unreadable == 1 ? "" : "s") could not be read") }
        if !summary.withOpeners.isEmpty {
            let names = summary.withOpeners.prefix(5).map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ")
            lines.append("Opens apps or websites, or starts by itself: \(names)\(summary.withOpeners.count > 5 ? " and \(summary.withOpeners.count - 5) more" : ""). Check these in the editor before running them.")
        }
        ActivityLog.shared.info("Settings", "Backup restored: " + lines.joined(separator: ", "))
        backupMessage = ("Backup Restored", lines.joined(separator: "\n"))
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
                        // The Steam Controller, read by its own helper.
                        if let steamSlot = controllerService.steamControllerSlot {
                            HStack {
                                ControllerGlyph(height: 14)
                                    .foregroundStyle(.green)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading) {
                                    Text("Steam Controller").font(.body)
                                    Text("Slot #\(steamSlot) · read by InputConfig's Steam Controller helper")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(10)
                            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }

                if !hasAnyController {
                    section(title: "How to connect") {
                        connectionTipsView
                    }
                }

                section(title: "Face button names") {
                    Picker("Face button names", selection: $faceLetters) {
                        ForEach(FaceLetters.settingsChoices) { choice in
                            Text(choice.title).tag(choice.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    Text("PlayStation, Switch, Stadia, GameCube, and Steam controllers show the names printed on them, unless a preset is written for another controller. This sets the letters for other pads, including the many that report themselves as Xbox pads: choose Nintendo for one with B printed on the bottom, like many 8BitDo pads. Positions puts compass names on every pad. Only the names change, never the presets.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Screen regions and stick zones belong to a preset, and
                // are drawn from that preset's editor. The editors that used
                // to open from here worked on the shared working set and
                // saved to nothing: every zone drawn was gone at the next
                // launch, and a binding made against it dangled for good.
                section(title: "Screen regions and stick zones") {
                    Text("Each preset has its own. Open it, choose Edit, and draw them from a row's Options.")
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
                        // Only a pad with a mode switch can be moved to a mode
                        // macOS reads; for most raw HID devices this is the
                        // only way they are read.
                        if gamepad.vendorID == EightBitDoDetector.vendorID {
                            Text("If it doesn't respond in a preset, switch it to a mode macOS reads; see Help for your model.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
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
                                                    .foregroundStyle(.hint)
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
        if let known = GameControllerService.firedIndex(forElement: name, brand: controllerService.controllerDetails[slot]?.brand) {
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
                    .foregroundStyle(.hint)
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
                    .accessibilityAddTraits(.isHeader)
                    .font(.headline)
                Text("I built InputConfig as an accessibility tool, simply because I needed one. My hands don't work that well, which makes a keyboard and mouse difficult, so I depend on other devices to control my Mac.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The mapping tools out there were either expensive, missing important features, or not really built for the people using them.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text(storeSafe("So I made the input mapper of my dreams: free, endlessly customizable, and happy to treat any device (a game controller, a MIDI keyboard, a spare mouse) as a first-class way to drive a Mac. I hope it's helpful for you too. If you run into any problems, or have suggestions, please let me know.",
                               "So I made the input mapper of my dreams: open, endlessly customizable, and happy to treat any device (a game controller, a MIDI keyboard, a spare mouse) as a first-class way to drive a Mac. I hope it's helpful for you too. If you run into any problems, or have suggestions, please let me know."))
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
                    Image(systemName: "arrow.up.forward").imageScale(.small).foregroundStyle(.hint)
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
                Text("To everyone who suggested features, tested rough builds, and told me exactly where it hurt: this app is shaped by you. Without this community, InputConfig wouldn't exist. Thank you.\n\nA special thank you to Tanya Riseman for extensive testing and feedback, to the GitHub community for feature requests and help tracking down bugs, to everyone who has donated, and to those who have reached out to me privately. You all are awesome!")
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

/// Reset Settings to Default. Clears the app's preference keys, so every
/// @AppStorage and every service that reads UserDefaults falls back to its
/// built-in default. Records are kept: what has been seeded and migrated,
/// the tip count, the last-seen version, the MIDI port's identity, the
/// per-preset region layouts, favorites, calibration, remembered devices,
/// and window positions.
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
        // The user's data, not settings: stars, calibration, and the devices
        // connected by hand. The dialog promises presets are untouched, and
        // losing every star or a tuned tap threshold reads as data loss.
        "InputConfig.favoritePresets", "InputConfig.tap.minPeak",
        "InputConfig.motion.rezeroButtons", "InputConfig.manualHIDDevices",
        "InputConfig.motion.clearedKeys",
        "InputConfig.welcomeIntroSeen", "InputConfig.tutorialFakeActive",
        // Records 1.6 keeps: the pads this Mac has seen (a group named for
        // one is pinned to it) and when 1.6 first ran.
        "InputConfig.seenControllerNames", "InputConfig.first16LaunchAt",
    ]
    private static let keptPrefixes = ["InputConfig.seededExample", "InputConfig.review.",
                                       // The presets still to offer the pre-1.6 row fix.
                                       "InputConfig.legacyRowCheck."]

    static func isSetting(_ key: String) -> Bool {
        guard prefixes.contains(where: { key.hasPrefix($0) }) else { return false }
        if kept.contains(key) { return false }
        // Versioned keys (".v1", ".v2") are one-shot migrations and stored
        // data, never settings: clearing retiredKeyboardDeck.v1 sent a
        // restored Keyboard Deck back to the trash, and clearing
        // presetButtonFamilies.v1 forced every family back.
        if key.range(of: #"\.v[0-9]+$"#, options: .regularExpression) != nil { return false }
        return !keptPrefixes.contains(where: { key.hasPrefix($0) })
    }

    /// Keys a backup may write. Machine-local keys are never exported, so
    /// a backup that carries one was not made by this app.
    static let backupSkipped: Set<String> = [
        "InputConfig.lastActivatedPresetId", "InputConfig.recovery.lastFreezeAt",
        "InputConfig.TestBench", "InputConfig.midiSourceUniqueID",
        // The salt behind every stored device hash; with it, a backup's
        // hashes could be tested against guessed serials.
        DeviceSerial.saltKey,
    ]

    static func isRestorable(_ key: String) -> Bool {
        prefixes.contains(where: { key.hasPrefix($0) }) && !backupSkipped.contains(key)
    }

    /// This Mac's record of what it has seeded and upgraded. Never written
    /// to a backup: restored into 1.5, a 1.6 backup's flags would make the
    /// later update to 1.6 skip every upgrade it owes that Mac. Listed by
    /// name, since other versioned keys (touchpadCalibration.v1 and the
    /// like) are real data.
    static let upgradeRecords: Set<String> = [
        "InputConfig.ankiShippedNotes.v1", "InputConfig.builtInRowFixes16.v1", "InputConfig.builtInRowFixes16.v2",
        "InputConfig.builtInRowNotes16.v1", "InputConfig.builtInTags16.v1", "InputConfig.desktopNavigationAClicks.v1",
        "InputConfig.driveThrottleSign16.v1", "InputConfig.eightBitDoBackButtons.v1", "InputConfig.nintendoFacePositions.v1",
        "InputConfig.presetButtonFamilies.v1", "InputConfig.presetButtonFamilies.v2", "InputConfig.presetButtonFamilies.v3",
        "InputConfig.retiredKeyboardDeck.v1", "InputConfig.sideButtonBlock.v1", "InputConfig.sideButtonBrackets.v1",
        "InputConfig.lastSeenVersion", "InputConfig.lastExampleSeedBuild", "InputConfig.first16LaunchAt",
    ]
    static func isUpgradeRecord(_ key: String) -> Bool {
        upgradeRecords.contains(key) || key.hasPrefix("InputConfig.seededExample")
            || key.hasPrefix("InputConfig.legacyRowCheck.")
    }

    /// Keys a backup carries but a restore leaves as they are on this Mac:
    /// which version last ran and which built-ins were seeded. Restoring a
    /// 1.5 backup's values made 1.6 forget its own seeding and upgrades.
    static func isRestoreSkipped(_ key: String) -> Bool {
        // Safety switches stay as they are on this Mac: a backup from
        // someone else turned the Emergency Stop off and auto-switch on.
        key == EmergencyStopService.enabledKey || key == EmergencyStopService.controllerKey
            || key == "InputConfig.autoSwitch.enabled"
            || key == "InputConfig.lastSeenVersion" || key == "InputConfig.lastExampleSeedBuild"
            || key.hasPrefix("InputConfig.seededExample")
            // This Mac's own upgrade records: another Mac's would switch off
            // a check still owed here, or offer presets this Mac lacks.
            || isUpgradeRecord(key)
    }

    static let saltTagPrefix = "#mac:"
    /// A one-way tag of this Mac's device salt.
    static var saltTag: String { DeviceSerial.hashed("backup salt tag") }

    /// User data that a restore adds to rather than replaces: stars,
    /// devices connected by hand, and re-zero buttons. A list merges as a
    /// union; a table keeps this Mac's entries and adds the backup's others.
    static func merged(_ restored: Any, into key: String, idMap: [UUID: UUID] = [:]) -> Any? {
        let defaults = UserDefaults.standard
        switch key {
        case "InputConfig.seenControllerNames":
            // Every pad either Mac has seen.
            guard let incoming = restored as? [String] else { return restored }
            let current = defaults.stringArray(forKey: key) ?? []
            return current + incoming.filter { !current.contains($0) }
        case "InputConfig.favoritePresets", "InputConfig.manualHIDDevices":
            guard var incoming = restored as? [String] else { return restored }
            if key == "InputConfig.manualHIDDevices" {
                // Restored on the Mac that made the backup: its own keys
                // still match, and the plain vendor and product keys would
                // connect every identical pad, so they are left out.
                let sameMac = incoming.contains(saltTagPrefix + saltTag)
                incoming.removeAll { $0.hasPrefix(saltTagPrefix) }
                if sameMac {
                    let hashedPrefixes = Set(incoming.filter { $0.count > 9 }.map { String($0.prefix(9)) })
                    incoming.removeAll { $0.count == 9 && hashedPrefixes.contains($0) }
                }
            }
            // A star on a built-in the restore kept this Mac's copy of
            // follows to that copy.
            incoming = incoming.map { id in UUID(uuidString: id).flatMap { idMap[$0] }?.uuidString ?? id }
            let current = defaults.stringArray(forKey: key) ?? []
            return current + incoming.filter { !current.contains($0) }
        case "InputConfig.motion.clearedKeys":
            // This Mac's own list: its keys are salted per Mac, and an old
            // list switched drift learning off for pads calibrated since.
            return defaults.stringArray(forKey: key) ?? []
        case "InputConfig.motion.rezeroButtons":
            guard let incoming = restored as? [String: Any] else { return restored }
            var current = defaults.dictionary(forKey: key) ?? [:]
            for (k, v) in incoming where current[k] == nil { current[k] = v }
            return current
        default:
            return restored
        }
    }

    /// A backup value made safe for UserDefaults: JSON null removed at any
    /// depth (UserDefaults aborts the app on NSNull), only property-list
    /// types kept, and the keys the app reads as unsigned codes, rates, and
    /// sizes kept in range. nil means skip the key.
    static func restorableValue(_ value: Any, forKey key: String) -> Any? {
        guard let clean = plistSafe(value) else { return nil }
        if let n = clean as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
           let range = numericRanges[key] {
            let v = n.doubleValue
            guard v.isFinite, range.contains(v) else { return nil }
        }
        return clean
    }

    private static let numericRanges: [String: ClosedRange<Double>] = [
        "InputConfig.panicKeyCode": 0...0xFFFF,
        "InputConfig.panicModifiers": 0...0xFFFF,
        "InputConfig.panicHoldSeconds": 0.5...30,
        "InputConfig.panicControllerButton": 0...127,
        "InputConfig.pollHz": 10...1000,
        "InputConfig.pollHzOnAC": 10...1000,
        "InputConfig.pollHzOnBattery": 10...1000,
        "InputConfig.rgbCycleSpeed": 0...100,
        "InputConfig.a11y.textSize": -1...3,
        "InputConfig.tap.minPeak": 0.01...1.0,
        "CursorGuard.recenterIntervalMs": 16...60_000,
        "CursorGuard.edgeBufferPx": 0...2000,
        "CursorGuard.sensitivity": 0.05...20,
        // Counters the app adds one to: Int.max from a damaged backup
        // overflowed and trapped on every launch.
        "InputConfig.review.launches": 0...1_000_000,
        "InputConfig.review.activations": 0...1_000_000,
        "InputConfig.tipCount": 0...1_000_000,
    ]

    private static func plistSafe(_ value: Any) -> Any? {
        switch value {
        case is NSNull:
            return nil
        case let n as NSNumber:
            return (CFGetTypeID(n) != CFBooleanGetTypeID() && !n.doubleValue.isFinite) ? nil : n
        case let s as String:
            return s
        case let d as Data:
            return d
        case let date as Date:
            return date
        case let list as [Any]:
            return list.compactMap(plistSafe)
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            for (k, v) in dict { if let safe = plistSafe(v) { out[k] = safe } }
            return out
        default:
            return nil
        }
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

/// Push stored settings into the running services. Settings normally
/// applies each change from its own control's handler, but Reset and
/// Restore change stored values with no control involved, so without this
/// the old emergency-stop chord stayed registered, a hidden Dock icon stayed
/// hidden, and the watchdog kept its old state until relaunch.
@MainActor
enum AppSettingsApply {
    static func applyAll(engine: MappingEngine?, store: PresetStore?) {
        let d = UserDefaults.standard
        var dock = (d.object(forKey: "InputConfig.showDockIcon") as? Bool) ?? true
        let menu = (d.object(forKey: MenuBarController.defaultsKey) as? Bool) ?? true
        // One way back to the app always stays: never both hidden.
        if !dock && !menu {
            dock = true
            d.set(true, forKey: "InputConfig.showDockIcon")
        }
        AppState.applyDockIconVisible(dock)
        MenuBarController.shared.setVisible(menu)
        ChassisTapService.shared.reloadThresholdFromDefaults()

        EmergencyStopService.shared.refreshRegistration()
        if d.bool(forKey: GlobalHotKeyService.enabledDefaultsKey) {
            if !GlobalHotKeyService.shared.enable() {
                d.set(false, forKey: GlobalHotKeyService.enabledDefaultsKey)
            }
        } else {
            GlobalHotKeyService.shared.disable()
        }
        FreezeWatchdogService.shared.reloadFromDefaults()
        CrashRecoveryService.shared.reloadFromDefaults()
        store?.reloadFavoritesFromDefaults()
        engine?.applyPollRate()
        // Settings the services keep in memory: the gaming utilities, the
        // menu bar glyph, built-in device exclusion and the RGB cycle speed.
        CursorGuardService.shared.reloadFromDefaults()
        MenuBarController.shared.refreshMenuBarImage()
        let exclude = d.bool(forKey: ExternalInputDeviceService.excludeBuiltInKey)
        if ExternalInputDeviceService.shared.excludeBuiltInDevices != exclude {
            ExternalInputDeviceService.shared.excludeBuiltInDevices = exclude
        }
        let rgb = (d.object(forKey: "InputConfig.rgbCycleSpeed") as? Double) ?? 1.0
        if let gc = engine?.controllerServiceForSettings, gc.rgbCycleSpeed != rgb { gc.rgbCycleSpeed = rgb }
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
        Text("Reads the phrase on rows with Speak on. More voices install in System Settings, Accessibility, Spoken Content, Manage Voices.")
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
        Toggle("Launch at login", isOn: launchAtLoginBinding)
            .toggleStyle(.switch)
            .onAppear { service.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                service.refresh()
            }
        if service.needsApproval {
            HStack(spacing: 8) {
                Text("macOS needs you to allow InputConfig in Login Items first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Login Items") { service.openLoginItemsSettings() }
                    .buttonStyle(.solidSecondaryCompact)
            }
        }
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
        Entry(version: "1.6", points: [
            "Optimized for macOS 27, with a new app icon made for the Dark, Clear, and Tinted styles",
            "Added infrastructure for far more controllers: generic USB pads and arcade sticks take their button names from the community SDL GameControllerDB, and wheels, flight sticks, and pedals are read on every axis at full resolution and every hat switch",
            "Generic USB pads and a single Joy-Con number their controls like other controllers; InputConfig offers to update older rows on USB pads",
            "Added infrastructure for two-player adapters and dual arcade encoders, so each player gets a controller of their own",
            "Added infrastructure for Valve's 2026 Steam Controller on a USB cable, over Bluetooth, or through its Puck: every button, the four back buttons, both trackpads, the gyro, rumble, and battery, and a built-in preset",
            "Added trackpad handling for both Steam Controllers: slide, tap, double tap, and press on either pad",
            "Added infrastructure for the Logitech G29 and G923 wheels: a wheel in compatibility mode is switched to its own mode, the pedals read 0 to 1, and the Live Visualizer shows how far the wheel is turned in degrees",
            "Added infrastructure for the Stream Deck, the Neo's touch points and the Stream Deck modules included, connected from the Devices menu or the menu bar",
            "A controller that also acts as a keyboard, such as some arcade sticks, works once Input Monitoring is allowed for InputConfig in System Settings",
            "With two PlayStation controllers connected, each gets its own light color, rumble, and Edge paddles, and two identical controllers can go to two players",
            "A group set to one controller reads another of the same family when its own is away, such as an Edge for a DualSense, and otherwise says it is waiting, with one click to use the controller that is connected",
            "InputConfig explains controllers macOS cannot read: Xbox 360 pads in the Devices menu, and 8BitDo pads in the wrong mode in the main window",
            "Disconnect a controller from its entry at the top of the sidebar, or switch it off from its Live Visualizer panel so it reads as idle everywhere, remembered for that controller",
            "The Live Visualizer draws 19 controllers as themselves, with every control where it really is and what each one is bound to",
            "One menu on each Live Visualizer panel: Automatic, Screen, Keyboard, Touchpad, Mouse and MIDI, then Connected, where you pick which connected controller a group reads, and a menu for each maker for the model it is drawn as, even with nothing connected",
            "The Live Visualizer lists what each control does in a key down both sides of the drawing, each caption joined to its control by a line that never crosses another, so no label sits on a control or another label",
            "Drag the Live Visualizer map to move it around inside its panel; where you leave it and its zoom are kept for each preset, and Reset View puts it back",
            "The Live Visualizer marks every deadzone a group's rows set, on sticks, triggers, pedals, wheels and the gyro, the way the deadzone calibration does, and triggers are taller so the percent reads clearly",
            "Click a control, or any part of the Mouse, Keyboard, Touchpad, Screen or stick zone map, in the Live Visualizer to see what it does and jump to its rows, and draw a screen region or open Touchpad Setup from there",
            "Light bar color as an output: any input can turn a DualSense or DualShock 4 light a color while held, set a color that stays, or switch the rainbow on and off, and a preset's rainbow runs at its own speed",
            "Share, Create, and Capture keep their macOS screenshot and recording shortcut unless the running preset uses them",
            "The controller emergency stop is a hold of Back and Start together, with a buzz a second in, and the same hold starts the preset again; on an Access Controller it is socket 7, and an Emergency Stop button under Activate and Edit shows the shortcut",
            "The binding editor opens faster and scrolls smoothly",
            "While the editor is open, the controller still moves the pointer and clicks, and Escape, Return, Tab, the arrows and Space still work from it, so Save and Cancel are always in reach",
            "Override on the editor's paused banner lets the running preset work fully while you edit; Scan still holds outputs back while it listens",
            "A row's hold and double tap each get a full second action at the bottom of Options: keys and shortcuts, clicks, typed text, MIDI, system functions, several outputs at once, and on a hold, pointer movement and scrolling",
            "Macro steps can send keyboard shortcuts, a row can repeat a held key like a real keyboard, and a repeating macro waits between passes",
            "Choose how long Scan waits, up to until canceled, and hear when it times out",
            "Type a screen region's, stick zone's or touchpad zone's place and size, and a fixed click point's X and Y, instead of only dragging",
            "Undo in the editor still steps back after Save and opening the editor again, and Previous versions lists a change the moment it is saved",
            "Every stick row shows its deadzone, and Adjust live sets it while you watch the stick",
            "Pointer speed and Scroll speed sliders on the preset page, Ramp-up on pointer rows, a D-pad that can take one direction at a time, and the pointer stops the moment you let go of the stick",
            "Re-zeroing the gyro centers the pointer on the display it is on, and tilt aiming is steadier: turning the controller no longer reads as tilt, and a resting hand no longer twitches the pointer",
            "Shortcuts in presets follow your keyboard layout, so Command A selects all on AZERTY, QWERTZ and Dvorak keyboards; Settings, Keyboard output can make typed keys follow it too, off by default since games read keys by position",
            "Bind keys from gaming, ISO, and Japanese keyboards, mouse buttons up to 32, controller buttons up to 128, and a tilt wheel",
            "MIDI Start, Continue, and Stop can be bound as inputs, and stick-driven MIDI CC reaches the full 0 to 127 range past the deadzone",
            "Name every button the Xbox, PlayStation, Nintendo, Stadia, GameCube, or Steam Controller way for each preset, or North, South, East, and West in Settings",
            "Pick the app's accent color in Settings, or any custom color",
            "Higher contrast text in Settings brightens hints and status lines, and turns on with the Mac's Increase Contrast",
            "A mouse side button can be kept from also going Back in a browser",
            "Star your favorite presets and show only favorites in the sidebar and the menu bar",
            "New built-in presets: Easy Browse for using the whole Mac from a controller, Easy Edit for a controller in one hand and a mouse in the other, and Auto Clicker, which clicks 5 to 20 times a second, on and off, while held, or a set number of times",
            "Restore Built-in Presets in Settings puts back any built-in you deleted",
            "Check Older Presets Again in Settings offers the update for presets made before 1.6 once more",
            "Import a preset by opening it or dropping it on the Dock icon: the review shows every action, macro and pointer setting in full, actions that open apps or websites can be removed first, and the preset asks before its first start",
            "Convert To makes a new preset beside the original",
            "The Smart Preset Maker fills back paddles, gives 13 apps their Mac shortcuts instead of Windows ones, and opens Steam games through Steam",
            "The built-in presets list rows on one stick or the D-pad in the same order on every install",
            "The Access Controller preset follows Sony's base profile: the center button clicks, socket 5 right-clicks, and socket 7 opens Spotlight",
            "Desktop Navigation: A clicks, and Select All moved to the right stick press",
            "Built-in presets you never changed are updated: Minecraft's right stick click swaps hands, the PS5 FPS touchpad opens the map, MIDI: Knob Deck scrolls from a centered knob, MIDI: Transport Control no longer drops the volume to 0, and Motion Cursor scrolls the same way as the other pointer presets",
            "In Trackpad & Mouse and Keyboard & Mouse Input, the side buttons send Command [ and ] and no longer also go Back on their own",
            "The Xbox and 8BitDo FPS presets, Minecraft, and Racing Game use Menu for Escape and View for Tab",
            "Keyboard Deck is retired: a copy you never changed moves to the Trash, and a copy you changed stays",
            "Confine, recenter, and hide cursor pause while InputConfig, the Finder, System Settings, the Dock or a permission prompt is in front; when a preset lists apps they work only there, and a preset that launches an app keeps them in the game it starts, such as Minecraft from its launcher",
            "New touchpad rows move the pointer as far up and down as they do side to side; rows made before 1.6 keep the speed they had",
            "One-Stick Driving with Throttle axis is a trigger uses the whole travel of a gas pedal that reads -1 to 1",
            "While the Mac sleeps or is locked no key is sent: at the lock screen only the pointer, clicks, and scrolling work",
            "After a crash, InputConfig asks before starting your preset again, and starts it by itself after 20 seconds with no answer",
            "Cancel in the editor asks before throwing away changes, and Empty Trash and deleting a folder ask first",
            "VoiceOver names every field in the binding editor and the visualizers, and the keyboard focus ring is back",
            "Text Size and Reduce Transparency reach every part of the app",
            "The menu bar icon turns orange when a running preset needs Accessibility, and rows start working the moment it is granted",
            "Statistics has a new look, and counts each controller's own time",
            "Uses less CPU and energy while nothing is moving",
            "Fixed the Switch Pro Controller and Joy-Con face buttons, where pressing A fired the rows meant for B; when one first connects, InputConfig offers to update rows recorded on it before",
            "Fixed 8BitDo back buttons, which were read as a DualSense Edge's Fn buttons, and the Pro 2's back buttons and wired model over USB; rows recorded on them before are offered the same update",
            "Fixed a gamepad that macOS GameController reads under a different name also being read directly, which doubled every press on a second slot",
            "Fixed a plain row and a chord row on the same button both lighting in the editor: a row lights only when it would fire, its held controls included",
            "Fixed keys and mouse buttons left held after a crash, a forced quit, or when two buttons share a key",
            "Fixed quick presses on two buttons mixing their shortcuts, and double clicks not opening files",
            "Fixed One-Stick Driving accelerating when the stick was pulled back; Invert throttle, the old workaround, is turned off",
            "Fixed recording a shortcut that InputConfig already uses, and Settings now says which shortcut or app holds a chord",
            "Fixed lifting or tilting a MacBook counting as a tap",
            "Fixed the Steam Controller's buttons, stick click, and wireless connection",
            "Fixed two identical controllers switching on and off together and sharing a motion zero, and controllers lost after a Bluetooth reconnect or a sleep",
            "Fixed the pointer vanishing past a screen edge, and recenter and confine fighting the stick",
            "Fixed chords firing the plain row on release, and gyro aim losing part of every turn",
            "Fixed Launchpad, brightness, keyboard light, Eject, Lock Screen, and Mouse Wheel Step outputs",
            "Fixed a damaged preset file freezing the app, and presets dropping rows made by a newer version",
            "Restoring a backup on a new Mac no longer duplicates the built-in presets, and says what it restored",
            "Fixed touchpad regions saving to the wrong preset, and Clear in Motion Calibration not sticking",
            "Fixed several built-in presets and Smart Presets whose rows did not match their notes",
            "Help is corrected throughout, and now covers gaming keypads, macro pads, pen tablets, switch interfaces, and Xbox Elite paddles",
        ]),
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
            "The sidebar splits into My Presets and Built-in Presets, with colored folder outlines and Move to Group",
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
            "A Cancel button on the scan overlay, so a scan can be canceled without a keyboard",
            "The help guides have a search field, plus new guides for chords, ratcheting, and tapping the Mac",
            "New built-in preset Anki in Desktop & Productivity: the face buttons rate flashcards, the bumpers undo and replay audio, stick clicks mark and bury, and the D-pad scrolls the card. Every row is labeled with its Anki action, and Anki is in the Smart Preset Maker's app list too",
            "Fixed: the release notes you are reading now did not appear for people who already had the app installed, so earlier updates arrived silently",
        ]),
        Entry(version: "1.3", points: [
            "Knob modes for MIDI dials: Dial mode treats the center of the knob as zero, so scrolling and mouse motion speed up the further you turn, with a deadzone to stop at center",
            "Turn mode fires a nudge for every few steps of rotation, clockwise or counterclockwise, built for volume, brightness, and stepped scrolling",
            "Both modes work with the sensitivity curves, deadzone settings, and variable speed the analog sticks already use",
            "System volume as a fader: a new output that makes the Mac's volume follow a knob, the pitch wheel, aftertouch, or a controller trigger 1-to-1",
            "Turn Step setting per binding: Fine, Normal, Coarse, or Chunky nudge sensitivity for Turn mode",
            "The volume fader only takes over once you actually move the control, so activating a preset never jumps the volume",
            "New built-in preset MIDI: Knob Deck and a new welcome-screen demo showing MIDI devices driving the Mac",
            "System Function outputs: volume, mute, media keys, brightness, Mission Control, Launchpad, Spotlight, lock screen, screenshot, Siri Shortcuts, and opening any app or URL",
            "New built-in preset MIDI: Media Deck, with pads and knobs running media keys, volume steps, and brightness",
            "A What's New popup after each update, so new features are never silently installed",
            "The YapToText shoutout now lives at the bottom of the welcome screen with a one-click App Store link",
            "An About button on the welcome screen opens the redesigned About page: the story behind the app, the changelog, source code, and support",
            "An Accessibility area in Settings: app-wide text size, bold text, reduced transparency, and reduced motion",
            "MIDI is now a full Live Visualizer template: a seven-octave velocity-shaded keyboard, named knob dials, pitch bend and aftertouch meters, a channel strip, and a live event log, switchable like any layout and automatic for MIDI presets",
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
/// Every version's changes, newest first, in a scrolling list.
struct FullChangelogList: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Changelog").font(.headline)
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
            .frame(width: 400, alignment: .leading)
        }
        .frame(maxHeight: 480)
    }
}

struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showFullChangelog = false

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
                // A link to the whole list, opened right here: Settings
                // cannot open over this sheet, so pointing at its path sent
                // people looking for it.
                Button("See the full changelog") { showFullChangelog = true }
                    .buttonStyle(.link)
                    .font(.caption)
                    .accessibilityHint("Shows every change in every version")
                    .popover(isPresented: $showFullChangelog, arrowEdge: .bottom) {
                        FullChangelogList()
                    }
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


// MARK: - Emergency stop

/// The Emergency stop controls: the keyboard shortcut switch and recorder,
/// the controller hold with its button, hold time, and Start options, and
/// every refusal and warning they show. Settings shows it in General, and
/// the preset header's Emergency Stop button shows it in a popover, so the
/// two can never drift apart. The body is a flat list of rows for the
/// caller's own VStack to space.
struct EmergencyStopSettingsContent: View {
    @EnvironmentObject var presetStore: PresetStore

    /// Bumped when the chord changes so the chord field and the warning
    /// lines re-evaluate. Owned by the caller, since Settings bumps it
    /// after a reset or a restore too.
    @SwiftUI.Binding var specRevision: Int
    /// Why the last recorded chord was refused. Owned by the caller so the
    /// line outlives a switch of Settings tabs, as it always has.
    @SwiftUI.Binding var chordRefusal: String?

    /// Emergency stop. Defaults to on: a kill switch you have to switch on
    /// first is not a kill switch.
    @AppStorage(EmergencyStopService.enabledKey) private var panicHotkeyEnabled = true
    @AppStorage(EmergencyStopService.controllerKey) private var panicControllerEnabled = true
    @AppStorage(EmergencyStopService.controllerBtnKey) private var panicControllerButton =
        EmergencyStopService.defaultControllerButton
    @AppStorage(EmergencyStopService.holdSecondsKey) private var panicHoldSeconds =
        EmergencyStopService.defaultHoldSeconds
    @AppStorage(EmergencyStopService.withStartKey) private var panicWithStart = true
    /// Sets the refusal line and reads it out, so VoiceOver hears why a
    /// chord was not kept.
    private var panicChordRefusal: String? {
        get { chordRefusal }
        nonmutating set {
            chordRefusal = newValue
            if let newValue { AccessibilityNotification.Announcement(newValue).post() }
        }
    }

    /// Why the keyboard stop is not live, naming a preset that holds its
    /// chord rather than blaming another app.
    private var unregisteredStopText: String? {
        let stop = EmergencyStopService.shared
        guard panicHotkeyEnabled, !stop.isRegistered else { return nil }
        if let owner = presetStore.presets.first(where: { $0.activateHotKey == stop.spec }) {
            return "\u{201C}\(owner.name)\u{201D} uses \(stop.spec.displayString), so this shortcut does nothing. Choose another chord, or change that preset's."
        }
        return "Another app holds \(stop.spec.displayString), so this shortcut does nothing. Choose another chord."
    }

    var body: some View {
        Text("Turns the active preset off and releases every key, mouse button, and note it was holding.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        Toggle("Keyboard shortcut", isOn: $panicHotkeyEnabled)
            .onChange(of: panicHotkeyEnabled) { _, on in
                let chord = EmergencyStopService.shared.spec
                if on, let owner = presetStore.presets.first(where: { $0.activateHotKey == chord }) {
                    panicChordRefusal = "\(chord.displayString) already activates \u{201C}\(owner.name)\u{201D}. Choose another chord."
                    panicHotkeyEnabled = false
                    return
                }
                if on, GlobalHotKeyService.shared.isEnabled, chord == GlobalHotKeyService.spec {
                    panicChordRefusal = "\(chord.displayString) already turns the last preset on and off. Choose another chord."
                    panicHotkeyEnabled = false
                    return
                }
                EmergencyStopService.shared.setEnabled(on)
                if on && !EmergencyStopService.shared.isRegistered {
                    // The chord field stays usable while the switch is
                    // off, so a new chord can be tried.
                    panicChordRefusal = "Another app already uses \(chord.displayString). Choose another chord."
                    panicHotkeyEnabled = false
                } else if on {
                    panicChordRefusal = nil
                }
            }
        HStack(spacing: 10) {
            Text("Shortcut")
                .foregroundStyle(.secondary)
            HotKeyRecorderField(spec: EmergencyStopService.shared.spec, label: "Emergency stop shortcut") { newSpec in
                // InputConfig's own shortcuts are refused here: registering
                // one twice fails, which turned the keyboard stop off and
                // blamed another app.
                if GlobalHotKeyService.shared.isEnabled, newSpec == GlobalHotKeyService.spec {
                    panicChordRefusal = "\(newSpec.displayString) already turns the last preset on and off. Choose another chord."
                    specRevision &+= 1
                    return
                }
                if let owner = presetStore.presets.first(where: { $0.activateHotKey == newSpec }) {
                    panicChordRefusal = "\(newSpec.displayString) already activates \u{201C}\(owner.name)\u{201D}. Choose another chord."
                    specRevision &+= 1
                    return
                }
                panicChordRefusal = nil
                // A recorded chord also turns the switch on. One another
                // app holds is not kept: the chord and switch that were
                // there come back, and the field stays usable for another
                // try.
                if !EmergencyStopService.shared.trySpec(newSpec) {
                    panicChordRefusal = "Another app already uses \(newSpec.displayString). Choose another chord."
                }
                panicHotkeyEnabled = EmergencyStopService.shared.isEnabled
                specRevision &+= 1
            }
            .id(specRevision)
            Spacer()
        }
        if EmergencyStopService.shared.spec.stealsATypingKey {
            Label("This key will no longer type anywhere on the Mac. A function key avoids that.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let refusal = panicChordRefusal ?? unregisteredStopText {
            Text(refusal)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        Text("Use at least one modifier, such as Control Option Command period, or a modifier with an unused key like F13.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .id(specRevision)

        Divider()

        Toggle("Hold a button on the controller", isOn: $panicControllerEnabled)
        Text("Works in every preset. A normal press still does what the preset says. You feel a buzz a second in, and once it stops, the same hold starts the preset again. On an Access Controller, hold socket 7 (Options).")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 10) {
            Text("Button")
                .foregroundStyle(.secondary)
            Picker("Emergency stop button", selection: $panicControllerButton) {
                ForEach(BindingRowView.standardButtonLabels, id: \.index) { entry in
                    Text(entry.label).tag(entry.index)
                }
            }
            .labelsHidden()
            .frame(width: 230)
            Text("held for")
                .foregroundStyle(.secondary)
            Picker("Emergency stop hold time", selection: $panicHoldSeconds) {
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
        if panicControllerButton == EmergencyStopService.defaultControllerButton {
            Toggle("With Start (Menu / Options / Plus) held too", isOn: $panicWithStart)
                .disabled(!panicControllerEnabled)
                .help("Back alone is used by Easy Browse and the game presets; a slow press of it should not stop them.")
        }

        Text("Any control can also be bound to Emergency Stop in the editor.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Shortcut recorder

/// Click, then press the chord you want. Records the next key press that
/// carries at least one modifier, so a bare letter cannot be captured as a
/// system-wide shortcut by accident.
struct HotKeyRecorderField: View {
    let spec: HotKeySpec
    /// What the shortcut does, read by VoiceOver before the chord.
    var label: String = "Shortcut"
    let onRecord: (HotKeySpec) -> Void

    @State private var recording = false
    /// Set when the user pressed a key with no modifiers, which macOS will
    /// not register as a global shortcut.
    @State private var needsModifier = false
    @State private var monitor: Any?
    @State private var current: HotKeySpec

    init(spec: HotKeySpec, label: String = "Shortcut", onRecord: @escaping (HotKeySpec) -> Void) {
        self.spec = spec
        self.label = label
        self.onRecord = onRecord
        _current = State(initialValue: spec)
    }

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? (hint ?? "Press a key…") : current.displayString)
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
        .accessibilityLabel(label)
        .accessibilityValue(recording ? (hint ?? "Recording, press a shortcut") : current.displayString)
        .help("Click, then press the shortcut you want. It needs Command or Control, or Option with a function, arrow, or navigation key: macOS will not hand an app a single key, Shift or Option with a letter would stop that character typing anywhere, and Command Q, W, C, V and the like are macOS's own.")
        .onDisappear { stop() }
        // Recording lets every InputConfig chord go, the emergency stop's
        // included, so it ends when the app or window is left.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in stop() }
        .onChange(of: hint) { _, new in
            if let new { AccessibilityNotification.Announcement(new).post() }
        }
    }

    /// What the field asks for when a press could not be taken.
    private var hint: String? {
        guard needsModifier else { return nil }
        return macOSChord ? "macOS uses that: add \u{2303} or \u{2325}" : "Add \u{2318} or \u{2303}"
    }
    @State private var macOSChord = false

    /// Command (or Command Shift) with a key macOS and every app use.
    private static func isMacOSShortcut(_ s: HotKeySpec) -> Bool {
        guard s.modifiers == UInt32(cmdKey) || s.modifiers == UInt32(cmdKey | shiftKey) else { return false }
        let keys: Set<Int> = [kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_H, kVK_ANSI_M, kVK_ANSI_C, kVK_ANSI_V,
                              kVK_ANSI_X, kVK_ANSI_Z, kVK_ANSI_A, kVK_ANSI_S, kVK_Tab, kVK_Space, kVK_ANSI_Comma]
        return keys.contains(Int(s.keyCode))
    }

    private func start() {
        recording = true
        needsModifier = false
        macOSChord = false
        HotKeyCenter.shared.suspendAll()
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
                needsModifier = true; macOSChord = false
                return nil
            }
            let recorded = HotKeySpec(keyCode: UInt32(event.keyCode), modifiers: mods)
            // Shift or Option with a typing key would take that character
            // from every app (Shift slash is "?"), so it needs one more
            // modifier.
            guard !recorded.stealsATypingKey else {
                needsModifier = true; macOSChord = false
                return nil
            }
            // Command Q, W, C, V and the like, pressed out of habit, would
            // stop working in every app.
            guard !Self.isMacOSShortcut(recorded) else {
                needsModifier = true; macOSChord = true
                return nil
            }
            // Stopped first, so InputConfig's own chords are back before
            // the new one registers next to them.
            stop()
            current = recorded
            onRecord(recorded)
            return nil
        }
    }

    private func stop() {
        let wasRecording = recording
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        guard wasRecording else { return }
        // The emergency stop comes back first; if it could not, its state
        // is worked out again so Settings and the menu bar stay truthful.
        let stop = EmergencyStopService.shared
        let lost = HotKeyCenter.shared.resumeAll(first: stop.tokens)
        if !lost.isDisjoint(with: stop.tokens) { stop.refreshRegistration() }
    }
}


/// A row of the menu bar glyphs to choose from; the chosen one wears a ring.
/// Accent color swatches, like System Settings' own row: Automatic first (the
/// multicolor wheel, which leaves macOS in charge), then the colors. The
/// choice takes effect at once in every window through appAccessibility().
struct AccentColorPicker: View {
    @AppStorage(AppAccent.storageKey) private var choiceRaw: String = AppAccent.automatic.rawValue
    @AppStorage(AppAccent.customKey) private var customHex: String = ""

    private var choice: AppAccent { AppAccent(rawValue: choiceRaw) ?? .automatic }

    /// The color well's value. Picking a color stores it and selects Custom.
    private var customColor: Binding<Color> {
        Binding(
            get: { AppAccent.color(hex: customHex) ?? Color(red: 0.255, green: 0.616, blue: 0.812) },
            set: { newValue in
                if let hex = AppAccent.hex(of: newValue) { customHex = hex }
                choiceRaw = AppAccent.custom.rawValue
            })
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(AppAccent.swatches) { option in
                Button {
                    choiceRaw = option.rawValue
                } label: {
                    swatch(option)
                        .frame(width: 20, height: 20)
                        .padding(3)
                        .overlay(
                            Circle().strokeBorder(choice == option ? Color.primary.opacity(0.55) : Color.clear,
                                                  lineWidth: 2)
                        )
                }
                .buttonStyle(.plain)
                .help(option.label)
                .accessibilityLabel("\(option.label) accent color")
                .accessibilityAddTraits(choice == option ? .isSelected : [])
            }
            // Custom: the macOS color well. Clicking it opens the Colors
            // panel; any color picked there becomes the accent.
            ColorPicker("Custom", selection: customColor, supportsOpacity: false)
                .labelsHidden()
                .padding(3)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(choice == .custom ? Color.primary.opacity(0.55) : Color.clear, lineWidth: 2)
                )
                .help("Custom")
                .accessibilityLabel("Custom accent color")
                .accessibilityAddTraits(choice == .custom ? .isSelected : [])
            Text(choice.label)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
        }
    }

    @ViewBuilder
    private func swatch(_ option: AppAccent) -> some View {
        if let color = option.color {
            Circle().fill(color)
        } else {
            Circle().fill(AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .pink, .red],
                                          center: .center))
        }
    }
}

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
