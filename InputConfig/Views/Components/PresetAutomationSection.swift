import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Per-preset automation panel for the preset editor (labeled
/// "Automation & Gaming Utilities" in the UI; the type keeps the PresetAutomation
/// name for file-format compatibility). Houses settings that should ride
/// along with each preset rather than living in global app Settings -
/// because what makes sense for, say, a Counter-Strike preset (confine
/// cursor, hide cursor, auto-launch Steam) is exactly wrong for a
/// desktop-productivity preset.
///
/// Wired into PresetEditorView at the bottom of the binding list.
/// Bound to `preset.automation` so changes flow through the editor's
/// normal save / cancel path.
struct PresetAutomationSection: View {
    @SwiftUI.Binding var automation: PresetAutomation
    @State private var expanded: Bool = false
    @State private var showingAppPicker: Bool = false
    @State private var showingAutoSwitchAppPicker: Bool = false
    /// Live slider values while dragging. The sliders write the preset on
    /// release: each drag tick was its own undo step and pushed every
    /// earlier edit out of the history.
    @State private var liveBuffer: Double?
    @State private var liveRecenter: Double?
    @State private var liveSensitivity: Double?
    @Environment(\.appTextScale) private var textScale
    @AppStorage(FrontmostAppWatcher.enabledDefaultsKey)
    private var autoSwitchGloballyEnabled: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 14) {
                    autoLaunchBlock
                    Divider()
                    autoSwitchBlock
                    Divider()
                    cursorBlock
                }
                .padding(.top, 8)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Automation & Gaming Utilities")
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        Text(summaryLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                // The whole header opens and closes it, not only the arrow.
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }
            }
            .padding(12)
            // The light purple card it had in 1.2.
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.purple.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.purple.opacity(0.25), lineWidth: 1)
            )
            .spotlightAnchor(SpotlightID.automationPanel)
        }
        // The Quick Start tour scrolls here and opens it.
        .onReceive(NotificationCenter.default.publisher(for: .inputConfigScrollToAutomation)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) { expanded = true }
        }
        #if DEBUG
        // `post inputconfig.debug.automation` opens the section; `scrollrow 9999`
        // then brings it to the top of the editor for the article screenshots.
        .background(DebugScrollRowAnchor(displayNumber: 9999))
        .onReceive({
            DebugHookRelay.shared.ensure("inputconfig.debug.automation")
            return NotificationCenter.default.publisher(for: Notification.Name("inputconfig.debug.automation"))
        }()) { _ in expanded = true }
        #endif
    }

    /// One-line collapsed summary so the section telegraphs what's on
    /// without making the user expand it.
    private var summaryLine: String {
        var parts: [String] = []
        if !automation.launchAppPath.isEmpty {
            let path = automation.launchAppPath
            let last = (path as NSString).lastPathComponent
            parts.append(String(localized: "launches \(last.isEmpty ? path : last)"))
        }
        if let apps = automation.autoActivateBundleIDs, !apps.isEmpty {
            parts.append(apps.count == 1 ? String(localized: "auto for 1 app") : String(localized: "auto for \(apps.count) apps"))
        }
        if automation.confineCursor { parts.append(String(localized: "confine cursor")) }
        if automation.autoRecenterCursor { parts.append(String(localized: "auto-recenter")) }
        if automation.hideCursorWhileActive { parts.append(String(localized: "hide cursor")) }
        if automation.sensitivityMultiplier != 1.0 {
            parts.append(String(format: String(localized: "sensitivity ×%.2f"), locale: .current, automation.sensitivityMultiplier))
        }
        if automation.scrollMultiplier != 1.0 {
            parts.append(String(format: String(localized: "scroll ×%.2f"), locale: .current, automation.scrollMultiplier))
        }
        return parts.isEmpty
            ? String(localized: "Optional extras: auto-launch an app, confine, recenter, or hide the cursor. Expand to set up.")
            : parts.joined(separator: ", ")
    }

    // MARK: - Auto launch

    @ViewBuilder
    private var autoLaunchBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "app.dashed")
                    .foregroundStyle(.secondary)
                Text("Auto-launch when preset activates")
                    .font(.subheadline.weight(.semibold))
            }
            HStack {
                TextField("/Applications/Steam.app or com.valvesoftware.steam",
                          text: $automation.launchAppPath)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("App to launch")
                Button {
                    showingAppPicker = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help("Pick an application")
                .accessibilityLabel("Pick an application")
                if !automation.launchAppPath.isEmpty {
                    Button {
                        automation.launchAppPath = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear")
                    .accessibilityLabel("Clear launch app")
                }
            }
            TextField("Optional deep link, e.g. steam://run/730",
                      text: $automation.launchURL)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Deep link to open")
            Text("Both fields run on activation. Leave blank to disable. The app can be an .app bundle or a bundle identifier such as com.valvesoftware.steam.")
                .font(.caption2)
                .foregroundStyle(.hint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .fileImporter(isPresented: $showingAppPicker,
                      allowedContentTypes: [UTType.application],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                automation.launchAppPath = url.path
            }
        }
        // Said by VoiceOver, so the two app pickers can be told apart.
        .fileDialogMessage(Text("Choose the app this preset opens when it starts"))
    }

    // MARK: - Auto switch by frontmost app

    @ViewBuilder
    private var autoSwitchBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.left.arrow.right.square")
                    .foregroundStyle(.secondary)
                Text("Activate when these apps are in front")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    showingAutoSwitchAppPicker = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("Add an application")
                .accessibilityLabel("Add an application")
            }

            let apps = automation.autoActivateBundleIDs ?? []
            if apps.isEmpty {
                Text("Empty. Add an app and this preset activates by itself whenever that app comes to the front, then steps aside when you leave.")
                    .font(.caption2)
                    .foregroundStyle(.hint)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(apps, id: \.self) { bundleID in
                    HStack(spacing: 6) {
                        Image(systemName: "app.badge.checkmark")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Text(displayName(forBundleID: bundleID))
                            .font(.caption)
                        Text(bundleID)
                            .font(.caption2)
                            .foregroundStyle(.hint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            var list = automation.autoActivateBundleIDs ?? []
                            list.removeAll { $0 == bundleID }
                            automation.autoActivateBundleIDs = list.isEmpty ? nil : list
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove")
                        .accessibilityLabel("Remove \(displayName(forBundleID: bundleID))")
                    }
                }
            }

            if !autoSwitchGloballyEnabled {
                Toggle(isOn: $autoSwitchGloballyEnabled) {
                    Text("Automatic switching is off globally. Turn it on for these lists to take effect.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .controlSize(.small)
            }
        }
        .fileImporter(isPresented: $showingAutoSwitchAppPicker,
                      allowedContentTypes: [UTType.application],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first,
               let bundleID = Bundle(url: url)?.bundleIdentifier {
                var list = automation.autoActivateBundleIDs ?? []
                if !list.contains(bundleID) {
                    list.append(bundleID)
                    automation.autoActivateBundleIDs = list
                }
            }
        }
        .fileDialogMessage(Text("Choose an app that switches to this preset when it comes to the front"))
    }

    private func displayName(forBundleID bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleID
    }

    // MARK: - Cursor controls

    @ViewBuilder
    private var cursorBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "cursorarrow.motionlines")
                    .foregroundStyle(.secondary)
                Text("Cursor while active")
                    .font(.subheadline.weight(.semibold))
            }
            Text("Only while this preset runs, and paused whenever InputConfig or the Finder is in front.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Turned on while the preset runs: it is on, but waits while
            // this window is in front, so say so rather than seem to do
            // nothing, and how to stop it.
            if (automation.confineCursor || automation.autoRecenterCursor || automation.hideCursorWhileActive),
               MappingEngine.current?.isRunning == true {
                Label {
                    Text("On now. It starts when you switch to another app; stop it any time with \(EmergencyStopService.shared.spec.displayString).")
                } icon: {
                    Image(systemName: "info.circle.fill").foregroundStyle(.purple)
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            }

            Toggle(isOn: $automation.confineCursor) {
                Label("Confine cursor away from screen edges",
                      systemImage: "rectangle.inset.filled")
            }
            if automation.confineCursor {
                HStack {
                    Text("Buffer:").font(.caption).foregroundStyle(.secondary)
                    ThrottledSlider("Cursor confine buffer", value: $automation.confineBufferPx, in: 1...200, step: 1,
                                    onLiveChange: { liveBuffer = $0 })
                        // The stored value moved (release, Undo): it is shown again.
                        .onChange(of: automation.confineBufferPx) { _, _ in liveBuffer = nil }
                        .accessibilityValue("\(Int(liveBuffer ?? automation.confineBufferPx)) pixels")
                    Text("\(Int(liveBuffer ?? automation.confineBufferPx)) px")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 56 * max(1, textScale), alignment: .trailing)
                }
            }

            Toggle(isOn: $automation.autoRecenterCursor) {
                Label("Auto-recenter cursor",
                      systemImage: "arrow.triangle.2.circlepath")
            }
            if automation.autoRecenterCursor {
                HStack {
                    Text("Interval:").font(.caption).foregroundStyle(.secondary)
                    ThrottledSlider("Auto-recenter interval", value: $automation.autoRecenterIntervalMs, in: 50...2000, step: 10,
                                    onLiveChange: { liveRecenter = $0 })
                        .onChange(of: automation.autoRecenterIntervalMs) { _, _ in liveRecenter = nil }
                        .accessibilityValue("\(Int(liveRecenter ?? automation.autoRecenterIntervalMs)) milliseconds")
                    Text("\(Int(liveRecenter ?? automation.autoRecenterIntervalMs)) ms")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 64 * max(1, textScale), alignment: .trailing)
                }
            }

            Toggle(isOn: $automation.hideCursorWhileActive) {
                Label("Hide system cursor",
                      systemImage: "cursorarrow.slash")
            }

            HStack {
                Label("Sensitivity multiplier",
                      systemImage: "speedometer")
                Spacer()
                Text(String(format: "×%.2f", locale: .current, liveSensitivity ?? automation.sensitivityMultiplier))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ThrottledSlider("Sensitivity multiplier", value: $automation.sensitivityMultiplier, in: 0.1...5.0, step: 0.05,
                            onLiveChange: { liveSensitivity = $0 })
                .onChange(of: automation.sensitivityMultiplier) { _, _ in liveSensitivity = nil }
                .accessibilityValue(String(format: String(localized: "times %.2f"), locale: .current, liveSensitivity ?? automation.sensitivityMultiplier))
        }
    }
}

/// Per-preset configuration for the one-stick driving system (build 18).
/// Bound to `preset.driveConfig` (optional). Toggling it on materializes a
/// default DriveConfig; the form then exposes the stick, steering, throttle,
/// and reverse-gesture settings. Lives in this file so it ships in the
/// existing Xcode target alongside the other per-preset section.
struct DriveModeSection: View {
    @SwiftUI.Binding var driveConfig: DriveConfig?
    /// The preset's groups, so the readout follows a group set to one
    /// controller the way the engine does.
    var groups: [JoystickMapping] = []
    @State private var expanded: Bool = false
    @EnvironmentObject private var controllerService: GameControllerService
    /// Read, not observed: published 15 times a second while a drive preset
    /// runs, it redrew this whole section, every slider block, on each, and
    /// the editor's frame rate dropped. The live readout observes it alone
    /// (`DriveLiveReadout`); the test car reads it on its own timer.
    private var telemetry: DriveTelemetry { .shared }
    @Environment(\.appTextScale) private var textScale
    @State private var liveDrive: [String: Double] = [:]

    /// The live stick readings and the test car, in an object this section
    /// holds but does not watch: they change up to 30 times a second, and
    /// kept on the section itself every change redrew each slider block,
    /// which dropped the editor's frame rate while scrolling. Only the arena
    /// and the axis meters watch it.
    @State private var live = DriveLive()
    private let axisTimer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    enum StickChoice: String, CaseIterable, Identifiable {
        case left, right, custom
        var id: String { rawValue }
        var label: String { self == .left ? String(localized: "Left stick") : self == .right ? String(localized: "Right stick") : String(localized: "Custom") }
    }

    /// Non-optional working binding; reads a default when nil.
    private var cfg: SwiftUI.Binding<DriveConfig> {
        SwiftUI.Binding(get: { driveConfig ?? DriveConfig() },
                        set: { driveConfig = $0 })
    }
    private var isOn: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { driveConfig?.enabled ?? false },
            set: { on in
                var c = driveConfig ?? DriveConfig()
                c.enabled = on
                driveConfig = c
            })
    }
    private var stickChoice: SwiftUI.Binding<StickChoice> {
        SwiftUI.Binding(
            get: {
                let s = cfg.wrappedValue
                if s.steerAxis == 0 && s.throttleAxis == 1 { return .left }
                if s.steerAxis == 2 && s.throttleAxis == 3 { return .right }
                return .custom
            },
            set: { choice in
                var c = cfg.wrappedValue
                switch choice {
                case .left:  c.steerAxis = 0; c.throttleAxis = 1
                case .right: c.steerAxis = 2; c.throttleAxis = 3
                case .custom: break
                }
                cfg.wrappedValue = c
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(isOn: isOn) {
                        Text("Enable one-stick driving")
                        Text("Steer, accelerate, brake, and shift Drive/Reverse from a single stick. Outputs keyboard and mouse, so it works in games you can drive with the keyboard.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityHint("Turns the whole one-stick driving scheme on or off for this preset.")
                    if driveConfig?.enabled == true {
                        liveFeedback
                        testDriveBlock
                        Divider(); stickBlock
                        Divider(); steeringBlock
                        Divider(); throttleBlock
                        Divider(); reverseBlock
                    }
                }
                .padding(.top, 8)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "steeringwheel").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("One-Stick Driving").font(.headline).accessibilityAddTraits(.isHeader)
                        Text(driveConfig?.enabled == true ? driveSummary : String(localized: "Wheelchair-style driving from one joystick"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if driveConfig?.enabled == true {
                        Text("On")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.green.opacity(0.16)))
                            .foregroundStyle(.green)
                            .accessibilityHidden(true)
                    }
                }
                // The whole header opens and closes it, not only the arrow.
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.22), lineWidth: 1))
        }
        .onReceive(axisTimer) { _ in
            // CRITICAL: no unconditional @State writes here. This fires 30x/s
            // for as long as the editor is open; a no-op write still marks the
            // view dirty, and in a large editor each re-layout can outlast the
            // tick interval - the main thread never drains and the app hangs.
            guard expanded, driveConfig?.enabled == true else {
                live.lastPhysicsTick = nil
                return
            }
            // To the nearest hundredth, so a resting stick's noise does not
            // count as movement.
            let axes = (controllerService.peekControllerState(at: readSlot)?.axes ?? [:])
                .mapValues { ($0 * 100).rounded() / 100 }
            live.ingest(axes, slot: cfg.wrappedValue.slot)
            live.step(cfg.wrappedValue, engine: telemetry.state)
        }
        .debugOneStick(expanded: $expanded, enable: isOn)
    }

    // MARK: - Live feedback (while actually driving)
    private var liveFeedback: some View { DriveLiveReadout() }

    // MARK: - Test drive sandbox

    /// Live 2D sandbox: a vehicle that obeys the exact parameters configured
    /// below. Its moving parts are a view of their own that watches `live`.
    @ViewBuilder private var testDriveBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            blockTitle("Test Drive", "car.fill")
            DriveTestDrive(live: live)
            Text("Move your stick to drive the demo vehicle. No controller? Drag the virtual stick. Parameter changes below apply instantly.")
                .font(.caption2)
                .foregroundStyle(.hint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Test drive sandbox

    // MARK: - Stick
    private var stickBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            blockTitle("Stick", "gamecontroller")
            Picker("Which stick drives", selection: stickChoice) {
                ForEach(StickChoice.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).controlSize(.small)
            .accessibilityLabel("Which stick drives")
            Stepper("Controller slot: \(cfg.wrappedValue.slot)", value: cfg.slot, in: 0...slotLimit)
                .controlSize(.small)
            if stickChoice.wrappedValue == .custom {
                Stepper("Steer axis: \(cfg.wrappedValue.steerAxis)", value: cfg.steerAxis, in: 0...11)
                    .controlSize(.small)
                Stepper("Throttle axis: \(cfg.wrappedValue.throttleAxis)", value: cfg.throttleAxis, in: 0...11)
                    .controlSize(.small)
            }
            // Live readout so the user can confirm which axis is which: a
            // view of its own, the only part that redraws as the stick moves.
            DriveAxisMeters(live: live, cfg: cfg)
            Text("Move the stick and watch the bars; or hold it in one direction and tap the matching button.")
                .font(.caption2).foregroundStyle(.secondary)
            Toggle("Invert steering", isOn: cfg.invertSteer).controlSize(.small)
            Toggle("Invert throttle (if pushing up goes backward)", isOn: cfg.invertThrottle).controlSize(.small)
            sliderRow("Deadzone", cfg.deadzone, 0, 0.4, "%.0f%%", 100, "Center deadzone")
        }
    }

    // MARK: - Steering
    private var steeringBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            blockTitle("Steering", "arrow.left.and.right")
            Picker("Steering output", selection: cfg.steerMode) {
                ForEach(DriveConfig.SteerMode.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented).controlSize(.small)
            .accessibilityLabel("Steering output")
            if cfg.wrappedValue.steerMode == .mouse {
                sliderRow("Steering speed", cfg.steerMouseSpeed, 4, 40, "%.0f px", 1, "Steering speed")
            } else {
                HStack {
                    Text("Left key").font(.caption)
                    KeyCodePicker(selectedCode: cfg.steerLeftKey, voiceRole: "Steer left key").accessibilityLabel("Steer left key")
                    Spacer()
                    Text("Right key").font(.caption)
                    KeyCodePicker(selectedCode: cfg.steerRightKey, voiceRole: "Steer right key").accessibilityLabel("Steer right key")
                }
            }
            sliderRow("Steering curve", cfg.steerCurve, 1, 3, "%.1fx", 1, "Steering response curve")
            Text("A higher steering curve gives a gentle center and progressive lock toward full.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Throttle
    private var throttleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            blockTitle("Throttle and brake", "gauge.with.dots.needle.67percent")
            HStack {
                Text("Accelerate").font(.caption)
                KeyCodePicker(selectedCode: cfg.accelKey, voiceRole: "Accelerate key").accessibilityLabel("Accelerate key")
                Spacer()
                Text("Brake").font(.caption)
                KeyCodePicker(selectedCode: cfg.brakeKey, voiceRole: "Brake key").accessibilityLabel("Brake key")
            }
            Toggle("Throttle axis is a trigger (rests at one end)", isOn: cfg.throttleIsTrigger)
                .controlSize(.small)
                .accessibilityHint("Turn on if you assigned an analog trigger instead of a centered stick. Disables the reverse gesture.")
            Toggle("Brake when centered (active slow-down)", isOn: cfg.coastBrake)
                .controlSize(.small)
                .accessibilityHint("Hold a light brake while the stick is centered so the vehicle slows down instead of coasting.")
            if cfg.wrappedValue.coastBrake {
                sliderRow("Slow-down strength", cfg.coastBrakeStrength, 0.1, 1, "%.0f%%", 100, "Active slow-down strength")
            }
            sliderRow("Sensitivity curve", cfg.throttleCurve, 1, 3, "%.1fx", 1, "Throttle sensitivity curve")
            Text("A higher curve gives finer low-speed control.")
                .font(.caption2).foregroundStyle(.secondary)
            sliderRow("Pulse smoothing", SwiftUI.Binding(
                get: { Double(cfg.wrappedValue.pwmPeriodTicks) },
                set: { cfg.wrappedValue.pwmPeriodTicks = Int($0) }), 3, 12, "%.0f", 1, "Pulse smoothing")
            Text("Variable speed is produced by pulsing the key on and off; this sets how smooth that pulsing is.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Reverse gesture
    private var reverseBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            blockTitle("Reverse gesture", "arrow.uturn.backward")
            if cfg.wrappedValue.throttleIsTrigger {
                Text("Unavailable while the throttle axis is a trigger (a trigger has no backward pull).")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Toggle("Snap fully back a few times to shift into Reverse", isOn: cfg.reverseGestureEnabled)
                    .controlSize(.small)
                if cfg.wrappedValue.reverseGestureEnabled {
                    Stepper("Back taps to engage: \(cfg.wrappedValue.reverseTapCount)", value: cfg.reverseTapCount, in: 2...4)
                        .controlSize(.small)
                    sliderRow("Within window", SwiftUI.Binding(
                        get: { Double(cfg.wrappedValue.reverseWindowMs) },
                        set: { cfg.wrappedValue.reverseWindowMs = Int($0) }), 300, 1500, "%.0f ms", 1, "Tap window")
                    sliderRow("Back-wall threshold", cfg.gestureThreshold, 0.6, 0.98, "%.0f%%", 100, "Back wall threshold")
                    Text("How far back counts as a wall hit; higher means you must snap nearly all the way.")
                        .font(.caption2).foregroundStyle(.secondary)
                    HStack {
                        Text("Reverse key").font(.caption)
                        KeyCodePicker(selectedCode: cfg.reverseKey, voiceRole: "Reverse key").accessibilityLabel("Reverse key")
                        Spacer()
                    }
                    Text("Push fully forward to return to Drive.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// One-line summary shown in the collapsed header when drive is enabled.
    private var driveSummary: String {
        let c = cfg.wrappedValue
        let stick = stickChoice.wrappedValue.label
        let mouse = c.steerMode == .mouse
        let rev = c.reverseGestureEnabled && !c.throttleIsTrigger
        switch (mouse, rev) {
        case (true, true): return String(localized: "On: \(stick), mouse steering, reverse gesture")
        case (true, false): return String(localized: "On: \(stick), mouse steering")
        case (false, true): return String(localized: "On: \(stick), key steering, reverse gesture")
        case (false, false): return String(localized: "On: \(stick), key steering")
        }
    }

    // MARK: - Reusable bits
    /// Numbered from 0, as Input Device and Slot are everywhere else, up to
    /// the preset's last group or the highest connected slot (a Steam or
    /// raw pad sits at 4 and up).
    private var slotLimit: Int {
        max(3, groups.count - 1, controllerService.controllerDetails.keys.filter { $0 < GameControllerService.noSlot }.max() ?? 0)
    }

    /// The slot drive reads, as MappingEngine.driveReadSlot works it out.
    private var readSlot: Int {
        let slot = cfg.wrappedValue.slot
        guard slot < groups.count, groups[slot].inputKind == .controller, groups[slot].customName != nil else { return slot }
        return controllerService.effectiveSlots(for: groups)[slot] ?? slot
    }
    private func miniBar(_ label: LocalizedStringKey, _ value: Double, _ color: Color) -> some View {
        VStack(spacing: 1) {
            ProgressView(value: min(max(value, 0), 1)).tint(color).frame(width: 56)
            Text(label).font(.system(size: 8)).foregroundStyle(.secondary)
        }
    }
    private func blockTitle(_ t: LocalizedStringKey, _ symbol: String) -> some View {
        HStack(spacing: 6) {
            IconView(name: symbol, glyphHeight: 9).font(.caption2).foregroundStyle(.hint)
            Text(t).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .accessibilityAddTraits(.isHeader)
    }
    private func sliderRow(_ label: LocalizedStringKey, _ value: SwiftUI.Binding<Double>,
                           _ lo: Double, _ hi: Double, _ fmt: String, _ scale: Double,
                           _ a11y: LocalizedStringKey) -> some View {
        // The value while dragging, shown and spoken live; the preset is
        // written on release.
        // Named by the row too: two rows can share a range and format.
        let liveKey = "\(String(describing: a11y))-\(lo)-\(hi)-\(fmt)-\(scale)"
        let v = (liveDrive[liveKey] ?? value.wrappedValue) * scale
        return HStack(spacing: 8) {
            Text(label).font(.caption).frame(minWidth: 120, alignment: .leading)
            // Writes on release: each drag tick was its own undo step.
            ThrottledSlider(a11y, value: value, in: lo...hi, step: (hi - lo) / 1000,
                            onLiveChange: { liveDrive[liveKey] = $0 }).controlSize(.small)
                .onChange(of: value.wrappedValue) { _, _ in liveDrive[liveKey] = nil }
                .accessibilityValue(Self.spokenValue(fmt, v))
            Text(String(format: fmt, locale: .current, v))
                .font(.caption2.monospacedDigit()).frame(width: 52 * max(1, textScale), alignment: .trailing)
        }
    }

    /// A slider's value read aloud in the app's language: units in words,
    /// the local decimal mark.
    private static func spokenValue(_ fmt: String, _ v: Double) -> String {
        let whole = Int(v.rounded())
        switch fmt {
        case "%.0f%%": return String(localized: "\(whole) percent")
        case "%.0f px": return String(localized: "\(whole) pixels")
        case "%.0f ms": return String(localized: "\(whole) milliseconds")
        case "%.1fx": return String(localized: "\(v.formatted(.number.precision(.fractionLength(1)))) times",
                                    comment: "A multiplier read aloud, as in 1.5 times")
        default: return String(format: fmt, locale: .current, v)
        }
    }
}

/// The live gear, power, brake and steer while a drive preset runs: the
/// only view that observes the engine's drive telemetry, so its updates
/// redraw this strip and nothing else.
private struct DriveLiveReadout: View {
    @ObservedObject private var telemetry = DriveTelemetry.shared

    private func miniBar(_ label: LocalizedStringKey, _ value: Double, _ color: Color) -> some View {
        VStack(spacing: 1) {
            ProgressView(value: min(max(value, 0), 1)).tint(color).frame(width: 56)
            Text(label).font(.system(size: 8)).foregroundStyle(.secondary)
        }
    }

    var body: some View {
        if let s = telemetry.state {
            HStack(spacing: 10) {
                Text(s.reverse ? String(localized: "Reverse") : String(localized: "Drive"))
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill((s.reverse ? Color.orange : Color.green).opacity(0.18)))
                    .foregroundStyle(s.reverse ? .orange : .green)
                miniBar("Power", Double(s.throttle), s.reverse ? .orange : .green)
                miniBar("Brake", Double(s.brake), .red)
                miniBar("Steer", Double(abs(s.steer)), .blue)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.04)))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(s.reverse
                    ? String(localized: "Live drive state: reverse, power \(Int(s.throttle * 100)) percent")
                    : String(localized: "Live drive state: drive, power \(Int(s.throttle * 100)) percent"))
            .accessibilityValue(String(localized: "Brake \(Int(s.brake * 100)) percent, steer \(Int(abs(s.steer) * 100)) percent"))
        }
    }
}

// MARK: - One-stick driving live state

/// What moves while the One-Stick Driving panel is open: the configured
/// slot's axis readings and the test-drive car. Kept apart from the panel so
/// a stick's movement redraws the arena and the meters only.
@MainActor
final class DriveLive: ObservableObject {
    /// Live axis values for the configured slot, so the user can see which
    /// axis moves and confirm their mapping.
    @Published var axisValues: [Int: Float] = [:]
    /// Where each axis sat when first read (a pedal rests at -1), by slot,
    /// so "most-moved" means moved from rest, not furthest from center.
    var axisRest: [Int: Float] = [:]
    var axisRestSlot: Int?

    /// Test-drive sandbox: a demo vehicle in a logical arena that obeys the
    /// exact drive parameters configured, stepped on the panel's timer.
    static let arenaSize = CGSize(width: 560, height: 200)
    @Published var carPos = CGPoint(x: 280, y: 100)
    @Published var carHeading: Double = -Double.pi / 2
    @Published var carSpeed: Double = 0
    var lastPhysicsTick: Date?
    @Published var virtualStick: CGSize = .zero
    @Published var trail: [CGPoint] = []

    func ingest(_ axes: [Int: Float], slot: Int) {
        if axes != axisValues { axisValues = axes }
        if axisRestSlot != slot {
            axisRestSlot = slot
            axisRest = axes
        } else if axes.keys.contains(where: { axisRest[$0] == nil }) {
            axisRest.merge(axes) { old, _ in old }
        }
    }

    func mostDeflected() -> Int? {
        func moved(_ e: (key: Int, value: Float)) -> Float { abs(e.value - (axisRest[e.key] ?? 0)) }
        guard let m = axisValues.max(by: { moved($0) < moved($1) }), moved(m) > 0.3 else { return nil }
        return m.key
    }
    /// One physics tick. Prefers the REAL drive engine's output (when the
    /// preset is running) so the demo matches what a game would receive;
    /// otherwise shapes raw stick input through the same deadzone and curve
    /// parameters the engine uses.
    func step(_ c: DriveConfig, engine state: DriveModeProcessor.LiveState?) {
        let now = Date()
        guard let last = lastPhysicsTick else {
            lastPhysicsTick = now
            return
        }
        let dt = min(now.timeIntervalSince(last), 0.08)
        guard dt > 0 else { return }

        var steer: Double = 0
        var accel: Double = 0   // -1 full reverse ... +1 full power
        var brake: Double = 0
        if let s = state {
            steer = Double(s.steer)
            accel = (s.reverse ? -1 : 1) * Double(s.throttle)
            brake = Double(s.brake)
        } else {
            var x = Double(axisValues[c.steerAxis] ?? 0)
            var fwd: Double
            if c.throttleIsTrigger {
                // Triggers rest at 0 (0...1), matching the engine. The old
                // (v+1)/2 remap left the preview idling forward at ~43%.
                fwd = max(0, Double(axisValues[c.throttleAxis] ?? 0))
            } else {
                fwd = -Double(axisValues[c.throttleAxis] ?? 0)
            }
            if c.invertSteer { x = -x }
            if c.invertThrottle { fwd = -fwd }
            // Fall back to the on-screen stick when the controller is idle.
            if abs(x) < 0.04 && abs(fwd) < 0.04 {
                x = Double(virtualStick.width)
                fwd = -Double(virtualStick.height)
            }
            steer = Self.shapedAxis(x, deadzone: c.deadzone, curve: c.steerCurve)
            accel = Self.shapedAxis(fwd, deadzone: c.deadzone, curve: c.throttleCurve)
        }
        #if DEBUG
        // The marketing shot (oneStick hook): the demo car drives a steady
        // loop forward instead of following the synthetic controller's jitter.
        if DebugMarketing.shared.oneStick { steer = 0.47; accel = 0.7; brake = 0 }
        #endif

        // Fully idle (no command, car at rest, trail drained): skip every
        // write so an open-but-untouched panel does zero re-render work.
        // The dt clamp above absorbs the stale tick stamp when motion resumes.
        if steer == 0 && accel == 0 && brake == 0 && carSpeed == 0 && trail.isEmpty {
            return
        }
        lastPhysicsTick = now

        // Speed: ease toward the commanded speed. Coast-brake makes the
        // centered-stick stop noticeably firmer, like a power wheelchair.
        let maxForward = 150.0, maxReverse = 70.0
        let target = accel >= 0 ? accel * maxForward : accel * maxReverse
        let centered = abs(accel) < 0.02
        var rate = centered ? (c.coastBrake ? 2.0 + 3.0 * c.coastBrakeStrength : 0.7) : 2.4
        if brake > 0.02 { rate += 4.0 * brake }
        carSpeed += ((brake > 0.5 ? 0 : target) - carSpeed) * min(1, rate * dt)
        if centered && abs(carSpeed) < 0.5 { carSpeed = 0 }

        // Heading: turn rate scales with speed so it steers like a vehicle,
        // and flips while reversing, like a real car.
        let speedFrac = max(-1, min(1, carSpeed / maxForward * 3))
        carHeading += steer * 3.2 * speedFrac * dt

        var p = carPos
        p.x += CGFloat(cos(carHeading) * carSpeed * dt)
        p.y += CGFloat(sin(carHeading) * carSpeed * dt)
        let margin: CGFloat = 18
        if p.x < margin { p.x = margin; carSpeed *= -0.25 }
        if p.x > DriveLive.arenaSize.width - margin { p.x = DriveLive.arenaSize.width - margin; carSpeed *= -0.25 }
        if p.y < margin { p.y = margin; carSpeed *= -0.25 }
        if p.y > DriveLive.arenaSize.height - margin { p.y = DriveLive.arenaSize.height - margin; carSpeed *= -0.25 }
        carPos = p

        if abs(carSpeed) > 2 {
            trail.append(p)
            if trail.count > 90 { trail.removeFirst(trail.count - 90) }
        } else if !trail.isEmpty && carSpeed == 0 {
            // Let the trail fade out once stopped.
            trail.removeFirst()
        }
    }

    /// Deadzone + response-curve shaping, matching the engine's semantics:
    /// remap past the deadzone to 0-1, then apply the curve exponent.
    static func shapedAxis(_ v: Double, deadzone: Double, curve: Double) -> Double {
        let a = abs(v)
        guard a > deadzone, deadzone < 1 else { return 0 }
        let n = min(1, (a - deadzone) / (1 - deadzone))
        return (v < 0 ? -1 : 1) * pow(n, max(0.1, curve))
    }

}

/// The test-drive arena, the virtual stick and the speed readout: the only
/// part of the panel that redraws as the car moves.
struct DriveTestDrive: View {
    @ObservedObject var live: DriveLive
    /// Only the engine's gear is followed, not every telemetry tick: the
    /// gear changes (or the engine stops) while the car sits still too.
    @State private var engineReverse: Bool?

    /// Whether the demo vehicle is currently in reverse: the real processor's
    /// gear when the engine is running, otherwise inferred from motion.
    private var demoReversing: Bool {
        if let engineReverse { return engineReverse }
        return live.carSpeed < -2
    }

    var body: some View {
            HStack(alignment: .top, spacing: 12) {
                arenaCanvas
                    .frame(maxWidth: .infinity)
                    .frame(height: 170)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
                    .accessibilityLabel("Test drive arena")
                    .onReceive(DriveTelemetry.shared.$state.map { $0?.reverse }.removeDuplicates()) { engineReverse = $0 }
                    .accessibilityValue(demoReversing ? String(localized: "Reversing") : String(localized: "Driving, speed \(Int(min(100, abs(live.carSpeed) / 1.5))) percent"))

                VStack(spacing: 10) {
                    Text(demoReversing ? String(localized: "Reverse") : String(localized: "Drive"))
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill((demoReversing ? Color.orange : Color.green).opacity(0.18)))
                        .foregroundStyle(demoReversing ? .orange : .green)

                    VStack(spacing: 2) {
                        Text("\(Int(min(100, abs(live.carSpeed) / 1.5)))%")
                            .font(.callout.monospacedDigit().weight(.semibold))
                        Text("Speed")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    virtualStickPad

                    Button("Reset") {
                        live.carPos = CGPoint(x: DriveLive.arenaSize.width / 2, y: DriveLive.arenaSize.height / 2)
                        live.carHeading = -Double.pi / 2
                        live.carSpeed = 0
                        live.trail.removeAll()
                    }
                    .buttonStyle(.solidSecondaryCompact)
                    .accessibilityHint("Puts the demo vehicle back in the middle of the arena.")
                }
                .frame(width: 92)
            }
    }

    /// The arena the virtual stick steers, unmirrored like the stick.
    private var arenaCanvas: some View { arenaCanvasDrawing.environment(\.layoutDirection, .leftToRight) }

    private var arenaCanvasDrawing: some View {
        Canvas { context, size in
            let s = min(size.width / DriveLive.arenaSize.width, size.height / DriveLive.arenaSize.height)
            context.translateBy(x: (size.width - DriveLive.arenaSize.width * s) / 2,
                                y: (size.height - DriveLive.arenaSize.height * s) / 2)
            context.scaleBy(x: s, y: s)

            // Floor grid so motion is visible even mid-arena.
            var grid = Path()
            for x in stride(from: 70.0, to: DriveLive.arenaSize.width, by: 70) {
                grid.move(to: CGPoint(x: x, y: 0))
                grid.addLine(to: CGPoint(x: x, y: DriveLive.arenaSize.height))
            }
            for y in stride(from: 50.0, to: DriveLive.arenaSize.height, by: 50) {
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: DriveLive.arenaSize.width, y: y))
            }
            context.stroke(grid, with: .color(.secondary.opacity(0.12)), lineWidth: 0.5)

            // Fading tire live.trail.
            if live.trail.count > 1 {
                var path = Path()
                path.move(to: live.trail[0])
                for p in live.trail.dropFirst() { path.addLine(to: p) }
                context.stroke(path, with: .color((demoReversing ? Color.orange : Color.green).opacity(0.3)),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }

            // The vehicle: rounded body + windshield, nose along +x.
            var car = context
            car.translateBy(x: live.carPos.x, y: live.carPos.y)
            car.rotate(by: Angle(radians: live.carHeading))
            let bodyColor: Color = demoReversing ? .orange : .accentColor
            car.fill(Path(roundedRect: CGRect(x: -16, y: -9, width: 32, height: 18), cornerRadius: 6),
                     with: .color(bodyColor))
            car.fill(Path(roundedRect: CGRect(x: 3, y: -6, width: 8, height: 12), cornerRadius: 2),
                     with: .color(.white.opacity(0.75)))
        }
    }

    /// Draggable stand-in stick for testing with no controller connected.
    /// Drawn in the stick's own coordinates: right is right in every language.
    private var virtualStickPad: some View { virtualStickPadDrawing.environment(\.layoutDirection, .leftToRight) }

    private var virtualStickPadDrawing: some View {
        ZStack {
            Circle().fill(Color.secondary.opacity(0.1))
            Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            Circle()
                .fill(Color.accentColor.opacity(0.9))
                .frame(width: 24, height: 24)
                .offset(x: live.virtualStick.width * 22, y: live.virtualStick.height * 22)
        }
        .frame(width: 70, height: 70)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    live.virtualStick = CGSize(width: max(-1, min(1, g.translation.width / 30)),
                                          height: max(-1, min(1, g.translation.height / 30)))
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
                        live.virtualStick = .zero
                    }
                }
        )
        .accessibilityLabel("Virtual test stick")
        .accessibilityHint("Drag to drive the demo vehicle when no controller is connected.")
        // Without a drag: push the stick a moment in one direction, then
        // it springs back, as letting go of a drag does.
        .accessibilityAction(named: "Forward") { pushVirtualStick(CGSize(width: 0, height: -1)) }
        .accessibilityAction(named: "Reverse") { pushVirtualStick(CGSize(width: 0, height: 1)) }
        .accessibilityAction(named: "Steer left") { pushVirtualStick(CGSize(width: -1, height: 0)) }
        .accessibilityAction(named: "Steer right") { pushVirtualStick(CGSize(width: 1, height: 0)) }
    }

    private func pushVirtualStick(_ to: CGSize) {
        live.virtualStick = to
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { live.virtualStick = .zero }
        }
    }

}

/// The steer and throttle meters and the buttons that pick the most-moved
/// axis: they redraw as the stick moves, the rest of the panel does not.
struct DriveAxisMeters: View {
    @ObservedObject var live: DriveLive
    @SwiftUI.Binding var cfg: DriveConfig
    @Environment(\.appTextScale) private var textScale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            axisReadout(String(localized: "Steer axis \(cfg.steerAxis)"), cfg.steerAxis)
            axisReadout(String(localized: "Throttle axis \(cfg.throttleAxis)"), cfg.throttleAxis)
            HStack(spacing: 8) {
                Button("Set steering to most-moved axis") { if let m = live.mostDeflected() { cfg.steerAxis = m } }
                    .buttonStyle(.solidSecondaryCompact)
                    .disabled(live.mostDeflected() == nil)
                    .accessibilityHint("Push and hold the stick in one direction first. Disabled until the stick is moved far enough.")
                Button("Set throttle to most-moved axis") { if let m = live.mostDeflected() { cfg.throttleAxis = m } }
                    .buttonStyle(.solidSecondaryCompact)
                    .disabled(live.mostDeflected() == nil)
                    .accessibilityHint("Push and hold the stick in one direction first. Disabled until the stick is moved far enough.")
            }
            .controlSize(.small).font(.caption)
        }
    }

    private func axisReadout(_ label: String, _ index: Int) -> some View {
        let v = live.axisValues[index] ?? 0
        return HStack(spacing: 8) {
            Text(label).font(.caption2).frame(minWidth: 116, alignment: .leading)
            ProgressView(value: Double(min(abs(v), 1)))
                .frame(width: 84)
            Text(String(format: "%+.2f", locale: .current, v))
                .font(.caption2.monospacedDigit()).frame(width: 46 * max(1, textScale), alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) value \(String(format: "%.2f", locale: .current, v))")
    }
}
