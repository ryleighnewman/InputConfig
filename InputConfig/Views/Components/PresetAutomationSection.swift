import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Per-preset Advanced Options panel for the preset editor (labelled
/// "Advanced Options" in the UI; the type keeps the PresetAutomation
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
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Advanced Options")
                            .font(.headline)
                        Text(summaryLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
            )
            .spotlightAnchor(SpotlightID.automationPanel)
        }
    }

    /// One-line collapsed summary so the section telegraphs what's on
    /// without making the user expand it.
    private var summaryLine: String {
        var parts: [String] = []
        if !automation.launchAppPath.isEmpty {
            let path = automation.launchAppPath
            let last = (path as NSString).lastPathComponent
            parts.append("launches \(last.isEmpty ? path : last)")
        }
        if let apps = automation.autoActivateBundleIDs, !apps.isEmpty {
            parts.append("auto for \(apps.count) \(apps.count == 1 ? "app" : "apps")")
        }
        if automation.confineCursor { parts.append("confine cursor") }
        if automation.autoRecenterCursor { parts.append("auto-recenter") }
        if automation.hideCursorWhileActive { parts.append("hide cursor") }
        if automation.sensitivityMultiplier != 1.0 {
            parts.append(String(format: "sensitivity ×%.2f", automation.sensitivityMultiplier))
        }
        return parts.isEmpty
            ? "Optional extras: auto-launch an app, confine, recenter, or hide the cursor. Expand to set up."
            : parts.joined(separator: " · ")
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
            Text("Both fields run on activation. Leave blank to disable. Paths accept .app bundles or any executable; identifiers accept reverse-DNS strings.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .fileImporter(isPresented: $showingAppPicker,
                      allowedContentTypes: [UTType.application],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                automation.launchAppPath = url.path
            }
        }
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
                .help("Add an application")
                .accessibilityLabel("Add an application")
            }

            let apps = automation.autoActivateBundleIDs ?? []
            if apps.isEmpty {
                Text("Empty. Add an app and this preset activates by itself whenever that app comes to the front, then steps aside when you leave.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
                            .foregroundStyle(.tertiary)
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
            Text("These only run while this preset is the active one. Stopping the engine restores the system cursor.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $automation.confineCursor) {
                Label("Confine cursor away from screen edges",
                      systemImage: "rectangle.inset.filled")
            }
            if automation.confineCursor {
                HStack {
                    Text("Buffer:").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $automation.confineBufferPx, in: 1...200, step: 1)
                        .accessibilityLabel("Cursor confine buffer")
                        .accessibilityValue("\(Int(automation.confineBufferPx)) pixels")
                    Text("\(Int(automation.confineBufferPx)) px")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                }
            }

            Toggle(isOn: $automation.autoRecenterCursor) {
                Label("Auto-recenter cursor",
                      systemImage: "arrow.triangle.2.circlepath")
            }
            if automation.autoRecenterCursor {
                HStack {
                    Text("Interval:").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $automation.autoRecenterIntervalMs, in: 50...2000, step: 10)
                        .accessibilityLabel("Auto-recenter interval")
                        .accessibilityValue("\(Int(automation.autoRecenterIntervalMs)) milliseconds")
                    Text("\(Int(automation.autoRecenterIntervalMs)) ms")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
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
                Text(String(format: "×%.2f", automation.sensitivityMultiplier))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $automation.sensitivityMultiplier, in: 0.1...5.0, step: 0.05)
                .accessibilityLabel("Sensitivity multiplier")
                .accessibilityValue(String(format: "times %.2f", automation.sensitivityMultiplier))
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
    @State private var expanded: Bool = false
    @EnvironmentObject private var controllerService: GameControllerService
    @EnvironmentObject private var mappingEngine: MappingEngine

    /// Live axis values for the configured slot, refreshed while the panel is
    /// open so the user can see which axis moves and confirm their mapping.
    @State private var axisValues: [Int: Float] = [:]
    private let axisTimer = Timer.publish(every: 1.0 / 20.0, on: .main, in: .common).autoconnect()

    enum StickChoice: String, CaseIterable, Identifiable {
        case left, right, custom
        var id: String { rawValue }
        var label: String { self == .left ? "Left stick" : self == .right ? "Right stick" : "Custom" }
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
                        Text("One-Stick Driving").font(.headline)
                        Text(driveConfig?.enabled == true ? driveSummary : "Wheelchair-style driving from one joystick")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if driveConfig?.enabled == true {
                        Text("On")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.green.opacity(0.2)))
                            .foregroundStyle(.green)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.22), lineWidth: 1))
        }
        .onReceive(axisTimer) { _ in
            guard expanded, driveConfig?.enabled == true else { return }
            axisValues = controllerService.readControllerState(at: cfg.wrappedValue.slot)?.axes ?? [:]
        }
    }

    // MARK: - Live feedback (while actually driving)
    @ViewBuilder private var liveFeedback: some View {
        if let s = mappingEngine.driveLiveState {
            HStack(spacing: 10) {
                Text(s.reverse ? "REVERSE" : "DRIVE")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill((s.reverse ? Color.orange : Color.green).opacity(0.25)))
                    .foregroundStyle(s.reverse ? .orange : .green)
                miniBar("Power", Double(s.throttle), s.reverse ? .orange : .green)
                miniBar("Brake", Double(s.brake), .red)
                miniBar("Steer", Double(abs(s.steer)), .blue)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.04)))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Live drive state: \(s.reverse ? "reverse" : "drive"), power \(Int(s.throttle * 100)) percent")
        }
    }

    // MARK: - Stick
    private var stickBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            blockTitle("Stick", "gamecontroller")
            Picker("Which stick drives", selection: stickChoice) {
                ForEach(StickChoice.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).controlSize(.small)
            .accessibilityLabel("Which stick drives")
            Stepper("Controller slot: \(cfg.wrappedValue.slot + 1)", value: cfg.slot, in: 0...3)
                .controlSize(.small)
            if stickChoice.wrappedValue == .custom {
                Stepper("Steer axis: \(cfg.wrappedValue.steerAxis)", value: cfg.steerAxis, in: 0...11)
                    .controlSize(.small)
                Stepper("Throttle axis: \(cfg.wrappedValue.throttleAxis)", value: cfg.throttleAxis, in: 0...11)
                    .controlSize(.small)
            }
            // Live readout so the user can confirm which axis is which.
            axisReadout("Steer axis \(cfg.wrappedValue.steerAxis)", cfg.wrappedValue.steerAxis)
            axisReadout("Throttle axis \(cfg.wrappedValue.throttleAxis)", cfg.wrappedValue.throttleAxis)
            HStack(spacing: 8) {
                Button("Set steering to most-moved axis") { if let m = mostDeflected() { cfg.wrappedValue.steerAxis = m } }
                    .disabled(mostDeflected() == nil)
                    .accessibilityHint("Push and hold the stick in one direction first. Disabled until the stick is moved far enough.")
                Button("Set throttle to most-moved axis") { if let m = mostDeflected() { cfg.wrappedValue.throttleAxis = m } }
                    .disabled(mostDeflected() == nil)
                    .accessibilityHint("Push and hold the stick in one direction first. Disabled until the stick is moved far enough.")
            }
            .controlSize(.small).font(.caption)
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
                    KeyCodePicker(selectedCode: cfg.steerLeftKey).accessibilityLabel("Steer left key")
                    Spacer()
                    Text("Right key").font(.caption)
                    KeyCodePicker(selectedCode: cfg.steerRightKey).accessibilityLabel("Steer right key")
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
                KeyCodePicker(selectedCode: cfg.accelKey).accessibilityLabel("Accelerate key")
                Spacer()
                Text("Brake").font(.caption)
                KeyCodePicker(selectedCode: cfg.brakeKey).accessibilityLabel("Brake key")
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
                        KeyCodePicker(selectedCode: cfg.reverseKey).accessibilityLabel("Reverse key")
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
        let steer = c.steerMode == .mouse ? "mouse steering" : "key steering"
        let rev = (c.reverseGestureEnabled && !c.throttleIsTrigger) ? ", reverse gesture" : ""
        return "On: \(stick), \(steer)\(rev)"
    }

    // MARK: - Reusable bits
    private func mostDeflected() -> Int? {
        guard let m = axisValues.max(by: { abs($0.value) < abs($1.value) }), abs(m.value) > 0.3 else { return nil }
        return m.key
    }
    private func axisReadout(_ label: String, _ index: Int) -> some View {
        let v = axisValues[index] ?? 0
        return HStack(spacing: 8) {
            Text(label).font(.caption2).frame(width: 116, alignment: .leading)
            ProgressView(value: Double(min(abs(v), 1)))
                .frame(width: 84)
            Text(String(format: "%+.2f", v))
                .font(.caption2.monospacedDigit()).frame(width: 46, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) value \(String(format: "%.2f", v))")
    }
    private func miniBar(_ label: String, _ value: Double, _ color: Color) -> some View {
        VStack(spacing: 1) {
            ProgressView(value: min(max(value, 0), 1)).tint(color).frame(width: 56)
            Text(label).font(.system(size: 8)).foregroundStyle(.secondary)
        }
    }
    private func blockTitle(_ t: String, _ symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.caption2).foregroundStyle(.tertiary)
            Text(t).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .accessibilityAddTraits(.isHeader)
    }
    private func sliderRow(_ label: String, _ value: SwiftUI.Binding<Double>,
                           _ lo: Double, _ hi: Double, _ fmt: String, _ scale: Double,
                           _ a11y: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).frame(width: 120, alignment: .leading)
            Slider(value: value, in: lo...hi).controlSize(.small)
                .accessibilityLabel(a11y)
                .accessibilityValue(String(format: fmt, value.wrappedValue * scale))
            Text(String(format: fmt, value.wrappedValue * scale))
                .font(.caption2.monospacedDigit()).frame(width: 52, alignment: .trailing)
        }
    }
}
