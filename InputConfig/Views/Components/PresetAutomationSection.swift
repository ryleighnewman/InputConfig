import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

/// Per-preset automation panel for the preset editor (labeled
/// "Automation" in the UI; the type keeps the PresetAutomation
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
    /// This preset is the one running: its cursor utilities are on now.
    var isLive: Bool = false
    /// The preset uses a PlayStation controller with a light bar, so the
    /// Light bar utility is offered.
    var usesPlayStation: Bool = false
    /// The utility shown beside the column.
    @State private var selected: Utility = .appSwitch
    @State private var showingAppPicker: Bool = false
    @State private var showingAutoSwitchAppPicker: Bool = false
    /// Live slider values while dragging. The sliders write the preset on
    /// release: each drag tick was its own undo step and pushed every
    /// earlier edit out of the history.
    @State private var liveBuffer: Double?
    @State private var liveRecenter: Double?
    @State private var liveSensitivity: Double?
    @State private var liveScroll: Double?
    @State private var liveGlide: Double?
    /// Each listed app's name, looked up once: asking the workspace for it
    /// on every body pass cost a file system call per app, twice a row.
    @State private var appNames: [String: String] = [:]
    @Environment(\.appTextScale) private var textScale
    @EnvironmentObject private var controllerService: GameControllerService
    @AppStorage(FrontmostAppWatcher.enabledDefaultsKey)
    private var autoSwitchGloballyEnabled: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Utilities")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityValue(summaryLine)
                    Text("Runs only while this preset is active.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            // Always open: the utilities in a list on the left, the chosen
            // one's settings beside it, as in the Regions card.
            HStack(alignment: .top, spacing: 12) {
                utilityColumn
                Divider()
                utilityPane(selected)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(selected)
                    // A utility that leaves the column (Light bar when the
                    // preset stops using a PlayStation pad) takes its pane along.
                    .onChange(of: visibleUtilities) { _, list in
                        if !list.contains(selected) { selected = .appSwitch }
                    }
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
            .background(
                Color.clear
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
            )
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
        #if DEBUG
        // `scrollrow 9999` brings the section to the top of the editor for
        // the article screenshots.
        .background(DebugScrollRowAnchor(displayNumber: 9999))
        // `post inputconfig.debug.automationnext` shows the next utility.
        .onReceive({
            DebugHookRelay.shared.ensure("inputconfig.debug.automationnext")
            return NotificationCenter.default.publisher(for: Notification.Name("inputconfig.debug.automationnext"))
        }()) { _ in
            let all = visibleUtilities
            selected = all[((all.firstIndex(of: selected) ?? 0) + 1) % all.count]
        }
        #endif
    }

    /// The utilities, in the order of the chips and the column.
    private enum Utility: CaseIterable, Hashable {
        case appSwitch, controllerSwitch, launch, confine, recenter, hide, speed, scroll, direction, smooth
        case pointerDirection, steadying
        case lightBar, idleDisconnect, reconnect

        var title: String {
            switch self {
            case .launch: return String(localized: "Open an app")
            case .appSwitch: return String(localized: "Activate with app")
            case .controllerSwitch: return String(localized: "Activate with controller")
            case .confine: return String(localized: "Confine cursor")
            case .recenter: return String(localized: "Recenter cursor")
            case .hide: return String(localized: "Hide cursor")
            case .speed: return String(localized: "Pointer speed")
            case .scroll: return String(localized: "Scroll speed")
            case .direction: return String(localized: "Scroll direction")
            case .smooth: return String(localized: "Smooth scrolling")
            case .pointerDirection: return String(localized: "Pointer direction")
            case .steadying: return String(localized: "Steady pointer")
            case .lightBar: return String(localized: "Light bar")
            case .idleDisconnect: return String(localized: "Disconnect when unused")
            case .reconnect: return String(localized: "Reconnect controllers")
            }
        }

        var symbol: String {
            switch self {
            case .launch: return "app.dashed"
            case .appSwitch: return "arrow.left.arrow.right.square"
            case .controllerSwitch: return "gamecontroller"
            case .confine: return "rectangle.inset.filled"
            case .recenter: return "arrow.triangle.2.circlepath"
            case .hide: return "cursorarrow.slash"
            case .speed: return "speedometer"
            case .scroll: return "scroll"
            case .direction: return "arrow.up.arrow.down"
            case .smooth: return "water.waves"
            case .pointerDirection: return "arrow.up.and.down.and.arrow.left.and.right"
            case .steadying: return "hand.raised"
            case .lightBar: return "lightbulb"
            case .idleDisconnect: return "powersleep"
            case .reconnect: return "antenna.radiowaves.left.and.right"
            }
        }
    }

    /// Whether this preset uses the utility.
    private func isSet(_ utility: Utility) -> Bool {
        switch utility {
        case .launch: return !automation.launchAppPath.isEmpty || !automation.launchURL.isEmpty
        case .appSwitch: return !(automation.autoActivateBundleIDs ?? []).isEmpty
        case .controllerSwitch: return !(automation.autoActivateControllers ?? []).isEmpty
        case .confine: return automation.confineCursor
        case .recenter: return automation.autoRecenterCursor
        case .hide: return automation.hideCursorWhileActive
        case .speed: return automation.sensitivityMultiplier != 1.0
        case .scroll: return automation.scrollMultiplier != 1.0
        case .direction: return automation.scrollReverseVertical == true || automation.scrollReverseHorizontal == true
        case .smooth: return automation.smoothScrolling == true
        case .pointerDirection: return automation.pointerReverseHorizontal == true || automation.pointerReverseVertical == true
        case .steadying: return (automation.pointerSteadying ?? 0) > 0
        case .lightBar: return automation.leaveLightBar != nil
        case .idleDisconnect: return automation.idleDisconnectMinutes != nil
        case .reconnect: return automation.reconnectOnStart != nil
        }
    }

    /// The utilities this preset can use: the light bar only with a
    /// PlayStation controller.
    private var visibleUtilities: [Utility] {
        Utility.allCases.filter { $0 != .lightBar || usesPlayStation || automation.leaveLightBar != nil }
    }

    /// The short value beside the utility's name: the app, how many apps,
    /// the speed, or On.
    private func detail(_ utility: Utility) -> String? {
        switch utility {
        case .launch:
            let path = automation.launchAppPath
            if path.isEmpty { return automation.launchURL.isEmpty ? nil : String(localized: "Link") }
            let app = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            return app.isEmpty ? path : app
        case .appSwitch:
            let n = automation.autoActivateBundleIDs?.count ?? 0
            return n > 0 ? "\(n)" : nil
        case .controllerSwitch:
            let n = automation.autoActivateControllers?.count ?? 0
            return n > 0 ? "\(n)" : nil
        case .speed, .scroll:
            let v = utility == .speed ? automation.sensitivityMultiplier : automation.scrollMultiplier
            return v != 1.0 ? String(format: "×%.2f", locale: .current, v) : nil
        case .confine, .recenter, .hide:
            return isSet(utility) ? String(localized: "On") : nil
        case .direction:
            return isSet(utility) ? String(localized: "Reversed") : nil
        case .smooth:
            return isSet(utility) ? "\(Int(glideMs)) ms" : nil
        case .pointerDirection:
            return isSet(utility) ? String(localized: "Reversed") : nil
        case .steadying:
            guard let v = automation.pointerSteadying, v > 0 else { return nil }
            return Self.steadyingName(v)
        case .lightBar:
            guard let leave = automation.leaveLightBar else { return nil }
            return leave ? String(localized: "macOS") : String(localized: "InputConfig")
        case .idleDisconnect:
            guard let m = automation.idleDisconnectMinutes else { return nil }
            return m == 0 ? String(localized: "Never") : String(localized: "\(m) min")
        case .reconnect:
            guard let on = automation.reconnectOnStart else { return nil }
            return on ? String(localized: "On") : String(localized: "Off")
        }
    }

    /// The value beside a utility as VoiceOver says it: a count of apps
    /// in words, Off when unused.
    private func spokenDetail(_ utility: Utility) -> String {
        // The device options follow Settings until the preset sets its own.
        if [.lightBar, .idleDisconnect, .reconnect].contains(utility), detail(utility) == nil {
            return String(localized: "As in Settings")
        }
        if utility == .appSwitch {
            let n = automation.autoActivateBundleIDs?.count ?? 0
            if n == 0 { return String(localized: "Off") }
            return n == 1 ? String(localized: "1 app") : String(localized: "\(n) apps")
        }
        if utility == .controllerSwitch {
            let n = automation.autoActivateControllers?.count ?? 0
            if n == 0 { return String(localized: "Off") }
            return n == 1 ? String(localized: "1 controller") : String(localized: "\(n) controllers")
        }
        return detail(utility) ?? String(localized: "Off")
    }

    /// The utilities, one under the other with what each is set to; the
    /// chosen one is lit.
    private var utilityColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(visibleUtilities, id: \.self) { utility in
                Button {
                    selected = utility
                } label: {
                    HStack(spacing: 8) {
                        // The app's own controller artwork for a controller symbol.
                        IconView(name: utility.symbol, glyphHeight: 9)
                            .font(.caption)
                            .foregroundStyle(isSet(utility) ? Color.purple : Color.secondary)
                            .frame(width: 16)
                        Text(utility.title)
                            .font(.callout)
                            .foregroundStyle(utility == selected ? Color.primary : Color.secondary)
                            .lineLimit(1)
                            // The name is kept whole; the value gives way.
                            .layoutPriority(1)
                        Spacer(minLength: 6)
                        if let detail = detail(utility) {
                            Text(detail)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 70, alignment: .trailing)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(utility == selected ? Color.secondary.opacity(0.18) : Color.clear))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(utility == selected ? [.isSelected] : [])
                .accessibilityValue(spokenDetail(utility))
            }
        }
        .frame(width: 200 * min(1.4, max(1, textScale)), alignment: .leading)
    }

    @ViewBuilder
    private func utilityPane(_ utility: Utility) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(utility.title)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(hint(utility))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch utility {
            case .launch: launchPane
            case .appSwitch: appSwitchPane
            case .controllerSwitch: controllerSwitchPane
            case .confine: confinePane
            case .recenter: recenterPane
            case .hide: hidePane
            case .speed: speedPane
            case .scroll: scrollPane
            case .direction: directionPane
            case .smooth: smoothPane
            case .pointerDirection: pointerDirectionPane
            case .steadying: steadyingPane
            case .lightBar: lightBarPane
            case .idleDisconnect: idleDisconnectPane
            case .reconnect: reconnectPane
            }
            if [.confine, .recenter, .hide].contains(utility) { cursorNote }
        }
    }

    private func hint(_ utility: Utility) -> String {
        switch utility {
        case .launch: return String(localized: "Opens an app, a link, or both each time this preset activates.")
        case .appSwitch: return String(localized: "This preset turns on by itself while one of these apps is in front, and steps aside when you leave.")
        case .controllerSwitch: return String(localized: "This preset turns on by itself when one of these controllers connects, and steps aside when it disconnects.")
        case .confine: return String(localized: "Keeps the cursor a set distance from the screen edges.")
        case .recenter: return String(localized: "Moves the cursor back to the middle of the screen on a timer.")
        case .hide: return String(localized: "Hides the system cursor, for games that draw their own.")
        case .speed: return String(localized: "Makes every pointer movement in this preset faster or slower. ×1.00 is as each row is set.")
        case .scroll: return String(localized: "Makes every scroll in this preset faster or slower, and your mouse wheel and trackpad if you include them. ×1.00 is as each row is set.")
        case .direction: return String(localized: "Flips the scrolling this preset makes, and your mouse wheel and trackpad while it runs if you include them. Natural Scrolling in System Settings is not changed.")
        case .smooth: return String(localized: "Each scroll glides to a stop instead of jumping, your mouse wheel's included. Leave it off for games that count wheel notches, such as weapon switching.")
        case .pointerDirection: return String(localized: "Turns your own mouse and trackpad around while this preset runs: the pointer goes the other way. This preset's own pointer rows are not changed.")
        case .steadying: return String(localized: "Smooths small, shaky movements of your own mouse and trackpad while this preset runs, at the cost of a short lag. Stronger steadies more.")
        case .lightBar: return String(localized: "Who sets a DualSense or DualShock 4 light bar while this preset runs. As in Settings follows the switch there.")
        case .idleDisconnect: return String(localized: "Disconnects a wireless controller that sits unused while this preset runs, to save its battery. A controller on a cable is never disconnected.")
        case .reconnect: return String(localized: "Asks paired controllers that are switched on and waiting to connect when this preset starts.")
        }
    }

    /// One-line collapsed summary so the section telegraphs what's on
    /// without making the user expand it.
    private var summaryLine: String {
        var parts: [String] = []
        if !automation.launchAppPath.isEmpty {
            let path = automation.launchAppPath
            let last = (path as NSString).lastPathComponent
            parts.append(String(localized: "launches \(last.isEmpty ? path : last)"))
        } else if !automation.launchURL.isEmpty {
            parts.append(String(localized: "opens a link"))
        }
        if let apps = automation.autoActivateBundleIDs, !apps.isEmpty {
            parts.append(apps.count == 1 ? String(localized: "auto for 1 app") : String(localized: "auto for \(apps.count) apps"))
            if automation.onlyInListedApps == true { parts.append(String(localized: "only in those apps")) }
        }
        if let pads = automation.autoActivateControllers, !pads.isEmpty {
            parts.append(pads.count == 1 ? String(localized: "auto for 1 controller") : String(localized: "auto for \(pads.count) controllers"))
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
        if isSet(.direction) { parts.append(String(localized: "reverse scroll")) }
        if isSet(.smooth) { parts.append(String(localized: "smooth scroll")) }
        return parts.isEmpty
            // The section is always open: no "Expand to set up".
            ? String(localized: "No utilities are on.")
            : parts.joined(separator: ", ")
    }

    // MARK: - Panes

    private var launchPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("/Applications/Steam.app or com.valvesoftware.steam",
                          text: $automation.launchAppPath)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("App to launch")
                Button {
                    showingAppPicker = true
                } label: {
                    Label("Choose…", systemImage: "folder")
                }
                .help("Pick an application")
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
            TextField("Optional link, e.g. steam://run/730",
                      text: $automation.launchURL)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Deep link to open")
            Toggle(isOn: SwiftUI.Binding(
                get: { automation.launchInBackground == true },
                set: { automation.launchInBackground = $0 ? true : nil }
            )) {
                Text("Open it in the background, so the app in front stays in front")
            }
            .toggleStyle(.checkbox)
            // A link alone opens in the background too.
            .disabled(automation.launchAppPath.isEmpty && automation.launchURL.isEmpty)
        }
    }

    private var appSwitchPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(automation.autoActivateBundleIDs ?? [], id: \.self) { bundleID in
                HStack(spacing: 6) {
                    Image(systemName: "app.badge.checkmark")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Text(appNames[bundleID] ?? bundleID)
                        .font(.callout)
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
                    .accessibilityLabel("Remove \(appNames[bundleID] ?? bundleID)")
                }
            }
            Button {
                showingAutoSwitchAppPicker = true
            } label: {
                Label("Add an app", systemImage: "plus")
            }
            Toggle(isOn: SwiftUI.Binding(
                get: { automation.onlyInListedApps == true },
                set: { automation.onlyInListedApps = $0 ? true : nil })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Only work in these apps")
                    Text("Everywhere else this preset does nothing, even when you start it yourself. InputConfig always counts, so you can stop it from here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        // Said as the hint, so the name stays short.
                        .accessibilityHidden(true)
                }
            }
            .accessibilityHint(Text("Everywhere else this preset does nothing, even when you start it yourself. InputConfig always counts, so you can stop it from here."))
            .disabled((automation.autoActivateBundleIDs ?? []).isEmpty)
            .padding(.top, 4)
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
        .onAppear { refreshAppNames() }
        .onChange(of: automation.autoActivateBundleIDs) { _, _ in refreshAppNames() }
    }

    /// The controllers connected now, by the name a group would pin, in
    /// slot order; ignored pads and names already listed are left out.
    private var connectedControllerNames: [String] {
        let listed = Set((automation.autoActivateControllers ?? []).map { $0.lowercased() })
        var seen = Set<String>()
        return controllerService.controllerDetails.sorted { $0.key < $1.key }.compactMap { slot, info in
            let name = info.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !controllerService.isIgnored(slot: slot),
                  !listed.contains(name.lowercased()), seen.insert(name.lowercased()).inserted else { return nil }
            return name
        }
    }

    private var controllerSwitchPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(automation.autoActivateControllers ?? [], id: \.self) { name in
                HStack(spacing: 6) {
                    ControllerGlyph(height: 9)
                        .foregroundStyle(.secondary)
                    Text(verbatim: name)
                        .font(.callout)
                    Spacer()
                    Button {
                        var list = automation.autoActivateControllers ?? []
                        list.removeAll { $0 == name }
                        automation.autoActivateControllers = list.isEmpty ? nil : list
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove")
                    .accessibilityLabel("Remove \(name)")
                }
            }
            let available = connectedControllerNames
            Menu {
                if available.isEmpty {
                    Text("No controller is connected")
                } else {
                    ForEach(available, id: \.self) { name in
                        Button {
                            automation.autoActivateControllers = (automation.autoActivateControllers ?? []) + [name]
                        } label: {
                            Text(verbatim: name)
                        }
                    }
                }
            } label: {
                Label("Add a controller", systemImage: "plus")
            }
            // The load keeps the first 16.
            .disabled((automation.autoActivateControllers ?? []).count >= 16)
            .fixedSize()
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
    }

    private func refreshAppNames() {
        var names: [String: String] = [:]
        for bundleID in automation.autoActivateBundleIDs ?? [] {
            names[bundleID] = displayName(forBundleID: bundleID)
        }
        if names != appNames { appNames = names }
    }

    private func displayName(forBundleID bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleID
    }

    private var confinePane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Confine the cursor while this preset runs", isOn: $automation.confineCursor)
            HStack {
                Text("Distance from the edges").font(.caption).foregroundStyle(.secondary)
                ThrottledSlider("Cursor confine buffer", value: $automation.confineBufferPx, in: 1...200, step: 1,
                                onLiveChange: { liveBuffer = $0 })
                    // The stored value moved (release, Undo): it is shown again.
                    .onChange(of: automation.confineBufferPx) { _, _ in liveBuffer = nil }
                    .accessibilityValue("\(Int(liveBuffer ?? automation.confineBufferPx)) pixels")
                NumberEntryField(label: Text("Distance from the edges"),
                                 value: $automation.confineBufferPx, live: liveBuffer,
                                 range: 1...200, unit: "px")
            }
            .disabled(!automation.confineCursor)
        }
    }

    private var recenterPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Recenter the cursor while this preset runs", isOn: $automation.autoRecenterCursor)
            HStack {
                Text("Every").font(.caption).foregroundStyle(.secondary)
                ThrottledSlider("Auto-recenter interval", value: $automation.autoRecenterIntervalMs, in: 50...2000, step: 10,
                                onLiveChange: { liveRecenter = $0 })
                    .onChange(of: automation.autoRecenterIntervalMs) { _, _ in liveRecenter = nil }
                    .accessibilityValue("\(Int(liveRecenter ?? automation.autoRecenterIntervalMs)) milliseconds")
                NumberEntryField(label: Text("Recenter interval"),
                                 value: $automation.autoRecenterIntervalMs, live: liveRecenter,
                                 range: 50...10000, unit: "ms")
            }
            .disabled(!automation.autoRecenterCursor)
        }
    }

    private var pointerDirectionPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Reverse left and right", isOn: SwiftUI.Binding(
                get: { automation.pointerReverseHorizontal == true },
                set: { automation.pointerReverseHorizontal = $0 ? true : nil }))
            Toggle("Reverse up and down", isOn: SwiftUI.Binding(
                get: { automation.pointerReverseVertical == true },
                set: { automation.pointerReverseVertical = $0 ? true : nil }))
        }
    }

    /// The steadying choices, by strength.
    static let steadyingLevels: [Double] = [0.4, 0.65, 0.9]
    static func steadyingName(_ v: Double) -> String {
        v < 0.5 ? String(localized: "Light") : v < 0.8 ? String(localized: "Medium") : String(localized: "Strong")
    }

    private var steadyingPane: some View {
        Picker("Steady pointer", selection: SwiftUI.Binding(
            get: { automation.pointerSteadying.flatMap { v in Self.steadyingLevels.min { abs($0 - v) < abs($1 - v) } } ?? 0 },
            set: { automation.pointerSteadying = $0 > 0 ? $0 : nil })) {
            Text("Off").tag(0.0)
            ForEach(Self.steadyingLevels, id: \.self) { v in Text(Self.steadyingName(v)).tag(v) }
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
    }

    private var lightBarPane: some View {
        Picker("Light bar", selection: SwiftUI.Binding(
            get: { automation.leaveLightBar.map { $0 ? 2 : 1 } ?? 0 },
            set: { automation.leaveLightBar = $0 == 0 ? nil : $0 == 2 })) {
            Text("As in Settings").tag(0)
            Text("Set by InputConfig").tag(1)
            Text("Left to macOS and other apps").tag(2)
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
    }

    private var idleDisconnectPane: some View {
        Picker("Disconnect when unused", selection: SwiftUI.Binding(
            get: { automation.idleDisconnectMinutes ?? -1 },
            set: { automation.idleDisconnectMinutes = $0 < 0 ? nil : $0 })) {
            Text("As in Settings").tag(-1)
            Text("Never while this preset runs").tag(0)
            ForEach(ControllerPowerService.minuteChoices, id: \.self) { m in
                Text("After \(m) minutes").tag(m)
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    private var reconnectPane: some View {
        Picker("Reconnect controllers", selection: SwiftUI.Binding(
            get: { automation.reconnectOnStart.map { $0 ? 1 : 2 } ?? 0 },
            set: { automation.reconnectOnStart = $0 == 0 ? nil : $0 == 1 })) {
            Text("As in Settings").tag(0)
            Text("When this preset starts").tag(1)
            Text("Never for this preset").tag(2)
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
    }

    private var hidePane: some View {
        Toggle("Hide the cursor while this preset runs", isOn: $automation.hideCursorWhileActive)
    }

    private var speedPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            multiplierRow(String(localized: "Pointer speed"), value: $automation.sensitivityMultiplier, live: $liveSensitivity)
            // The Mac's own mouse and trackpad too, not only this preset's rows.
            Toggle("Include my mouse and trackpad", isOn: SwiftUI.Binding(
                get: { automation.pointerSpeedIncludesMouse == true },
                set: { automation.pointerSpeedIncludesMouse = $0 ? true : nil }))
        }
    }

    private var scrollPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            multiplierRow(String(localized: "Scroll speed"), value: $automation.scrollMultiplier, live: $liveScroll)
            Toggle("Include my mouse wheel", isOn: SwiftUI.Binding(
                get: { automation.scrollSpeedIncludesMouse == true },
                set: { automation.scrollSpeedIncludesMouse = $0 ? true : nil }))
            Toggle("Include my trackpad and Magic Mouse", isOn: SwiftUI.Binding(
                get: { automation.scrollSpeedIncludesTrackpad == true },
                set: { automation.scrollSpeedIncludesTrackpad = $0 ? true : nil }))
        }
    }

    private var directionPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Reverse up and down", isOn: SwiftUI.Binding(
                get: { automation.scrollReverseVertical == true },
                set: { automation.scrollReverseVertical = $0 ? true : nil }))
            Toggle("Reverse left and right", isOn: SwiftUI.Binding(
                get: { automation.scrollReverseHorizontal == true },
                set: { automation.scrollReverseHorizontal = $0 ? true : nil }))
            Toggle("Include my mouse wheel", isOn: SwiftUI.Binding(
                get: { automation.scrollReverseSkipsMouse != true },
                set: { automation.scrollReverseSkipsMouse = $0 ? nil : true }))
                .disabled(!isSet(.direction))
            Toggle("Include my trackpad and Magic Mouse", isOn: SwiftUI.Binding(
                get: { automation.scrollReverseTrackpad == true },
                set: { automation.scrollReverseTrackpad = $0 ? true : nil }))
                .disabled(!isSet(.direction))
        }
    }

    /// The glide time, the default while none is stored.
    private var glideMs: Double { automation.smoothScrollMs ?? PresetAutomation.defaultSmoothScrollMs }

    private var smoothPane: some View {
        let glide = SwiftUI.Binding(get: { glideMs }, set: { automation.smoothScrollMs = $0 })
        return VStack(alignment: .leading, spacing: 8) {
            Toggle("Smooth every scroll this preset makes", isOn: SwiftUI.Binding(
                get: { automation.smoothScrolling == true },
                set: { automation.smoothScrolling = $0 ? true : nil }))
            HStack {
                Text("Glide").font(.caption).foregroundStyle(.secondary)
                ThrottledSlider("Smooth scrolling glide", value: glide, in: 50...600, step: 10,
                                onLiveChange: { liveGlide = $0 })
                    .onChange(of: automation.smoothScrollMs) { _, _ in liveGlide = nil }
                    .accessibilityValue("\(Int(liveGlide ?? glideMs)) milliseconds")
                NumberEntryField(label: Text("Glide"), value: glide, live: liveGlide,
                                 range: 30...1000, unit: "ms")
            }
            .disabled(automation.smoothScrolling != true)
            Toggle("Include my mouse wheel", isOn: SwiftUI.Binding(
                get: { automation.smoothScrollSkipsMouse != true },
                set: { automation.smoothScrollSkipsMouse = $0 ? nil : true }))
                .disabled(automation.smoothScrolling != true)
        }
    }

    /// A ×0.10 to ×5.00 slider with a field to type the number, and Reset.
    private func multiplierRow(_ label: String, value: SwiftUI.Binding<Double>, live: SwiftUI.Binding<Double?>) -> some View {
        HStack {
            ThrottledSlider(LocalizedStringKey(label), value: value, in: 0.1...5.0, step: 0.05,
                            onLiveChange: { live.wrappedValue = $0 })
                .onChange(of: value.wrappedValue) { _, _ in live.wrappedValue = nil }
                .accessibilityValue(String(format: String(localized: "times %.2f"), locale: .current, live.wrappedValue ?? value.wrappedValue))
            NumberEntryField(label: Text(verbatim: label), value: value, live: live.wrappedValue,
                             range: 0.1...5.0, fractionDigits: 2, prefix: "×")
            Button("Reset") { value.wrappedValue = 1.0 }
                .disabled(value.wrappedValue == 1.0)
        }
    }

    /// Under the three cursor utilities: when they run, and that they are
    /// waiting while this window is in front.
    @ViewBuilder
    private var cursorNote: some View {
        if (automation.confineCursor || automation.autoRecenterCursor || automation.hideCursorWhileActive),
           isLive {
            Label {
                Text("On now. It starts when you switch to another app; stop it any time with \(EmergencyStopService.shared.spec.displayString).")
            } icon: {
                Image(systemName: "info.circle.fill").foregroundStyle(.purple)
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Paused whenever InputConfig or the Finder is in front.")
                .font(.caption2)
                .foregroundStyle(.hint)
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
    /// Subscribed only while the section is open and driving is on (see
    /// `axisTicker`), so the editor does not tick 30 times a second for
    /// every preset without it.
    private let axisTimer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()
    private var axisTicking: Bool { expanded && driveConfig?.enabled == true }

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
    /// Custom picked, so its axis steppers show: derived from the axes
    /// alone, it snapped back to Left stick at once.
    @State private var customAxes = false

    private var stickChoice: SwiftUI.Binding<StickChoice> {
        SwiftUI.Binding(
            get: {
                let s = cfg.wrappedValue
                if customAxes { return .custom }
                if s.steerAxis == 0 && s.throttleAxis == 1 { return .left }
                if s.steerAxis == 2 && s.throttleAxis == 3 { return .right }
                return .custom
            },
            set: { choice in
                var c = cfg.wrappedValue
                customAxes = choice == .custom
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
        .background(axisTicker)
        .onChange(of: axisTicking) { _, on in if !on { live.lastPhysicsTick = nil } }
        .debugOneStick(expanded: $expanded, enable: isOn)
    }

    /// The axis timer's subscriber, present only while the section is open
    /// and driving is on: the timer runs while it has one and stops when it
    /// goes.
    @ViewBuilder
    private var axisTicker: some View {
        if axisTicking {
            Color.clear.onReceive(axisTimer) { _ in
                // CRITICAL: no unconditional @State writes here. This fires 30x/s
                // while the section is open; a no-op write still marks the
                // view dirty, and in a large editor each re-layout can outlast the
                // tick interval - the main thread never drains and the app hangs.
                // To the nearest hundredth, so a resting stick's noise does not
                // count as movement.
                let axes = (controllerService.peekControllerState(at: readSlot)?.axes ?? [:])
                    .mapValues { ($0 * 100).rounded() / 100 }
                live.ingest(axes, slot: cfg.wrappedValue.slot)
                live.step(cfg.wrappedValue, engine: telemetry.state)
            }
        }
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
            DriveMeterBar(value: min(max(value, 0), 1), color: color).frame(width: 56)
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
            DriveMeterBar(value: min(max(value, 0), 1), color: color).frame(width: 56)
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
        // Published only for a real move. A resting stick's noise crossed
        // the hundredths now and then, and every publish redrew the meters
        // AND the test drive arena (both watch this object), 30 times a
        // second while the editor scrolled.
        if axes.keys != axisValues.keys
            || axes.contains(where: { abs($0.value - (axisValues[$0.key] ?? 0)) >= 0.03 }) {
            axisValues = axes
        }
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
                // The engine's rule for an inverted trigger: rest is full.
                if c.invertThrottle { fwd = 1 - fwd }
            } else {
                fwd = -Double(axisValues[c.throttleAxis] ?? 0)
                if c.invertThrottle { fwd = -fwd }
            }
            if c.invertSteer { x = -x }
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
            DriveMeterBar(value: Double(min(abs(v), 1)), color: .accentColor)
                .frame(width: 84)
            Text(String(format: "%+.2f", locale: .current, v))
                .font(.caption2.monospacedDigit()).frame(width: 46 * max(1, textScale), alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) value \(String(format: "%.2f", locale: .current, v))")
    }
}

/// A plain drawn bar for the live meters. AppKit's progress indicator,
/// redrawn many times a second inside the scrolling editor, was the
/// expensive part of this panel.
private struct DriveMeterBar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(color).frame(width: geo.size.width * value)
            }
        }
        .frame(height: 5)
    }
}

/// A number typed straight in, beside a slider: kept within `range`,
/// saved on Return or when the field loses focus, and showing the
/// slider's value while it is dragged.
/// Whether a NumberEntryField has focus, for whoever holds it.
@MainActor
final class NumberEntryFocus {
    var active = false
}

struct NumberEntryField: View {
    let label: Text
    @SwiftUI.Binding var value: Double
    var live: Double? = nil
    let range: ClosedRange<Double>
    var fractionDigits: Int = 0
    var prefix: String? = nil
    var unit: String? = nil
    /// Told when the field takes and loses focus, for a holder that decides
    /// whether to make the field anew (the preset page's speed fields).
    var focusReport: NumberEntryFocus? = nil
    @State private var text = ""
    /// Set by typing only: an outside change (Reset, Undo, the slider) while
    /// the field has focus refreshes it, and a commit with nothing typed
    /// leaves the value alone instead of writing the old digits back.
    @State private var typed = false
    @FocusState private var focused: Bool
    /// This field's key with EditorInlineEdit while it has focus.
    @State private var editID = UUID()
    @Environment(\.appTextScale) private var textScale

    var body: some View {
        HStack(spacing: 3) {
            if let prefix {
                Text(prefix).font(.caption).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            // A light fill, not the rounded-border field: that draws a
            // black well on the glass.
            TextField("", text: SwiftUI.Binding(get: { text }, set: {
                text = $0
                typed = true
                // Escape dropped the registration and kept the focus, so no
                // focus change would bring it back for the next digits.
                if EditorInlineEdit.owner != AnyHashable(editID) { beginEdit() }
            }))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.callout.monospacedDigit())
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .frame(width: CGFloat(fractionDigits > 0 ? 58 : 62) * max(1, textScale))
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.14)))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .stroke(focused ? Color.accentColor.opacity(0.8) : Color.clear, lineWidth: 1.5))
                .focused($focused)
                .onSubmit(commit)
                .accessibilityLabel(label)
                // The unit and the range, which the field alone does not say.
                .accessibilityHint(String(localized: "Type a number from \(spoken(range.lowerBound)) to \(spoken(range.upperBound)), then press Return."))
            if let unit {
                Text(unit).font(.caption).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .onAppear { text = format(value) }
        // A change from outside (Reset, Undo, a slider drag) wins over digits
        // still being typed: kept, Save wrote the typed number over it.
        .onChange(of: value) { _, v in typed = false; text = format(v) }
        .onChange(of: live) { _, v in typed = false; text = format(v ?? value) }
        // Focused, the editor's Save (and Quit) writes the typed value first,
        // as it does a section name being typed. Escape backs out of the
        // digits: it wrote them, then asked about the change it abandoned.
        .onChange(of: focused) { _, on in
            focusReport?.active = on
            if on {
                beginEdit()
            } else {
                commit()
                EditorInlineEdit.clear(editID)
            }
        }
        // Clicking another utility rebuilds the pane without a blur; the
        // typed value was lost.
        .onDisappear {
            if typed { commit() }
            EditorInlineEdit.clear(editID)
            focusReport?.active = false
        }
    }

    private func beginEdit() {
        EditorInlineEdit.begin(editID, onCommit: { commit() }) {
            // Nothing typed: Escape is the editor's, and closes it.
            guard typed else { return false }
            text = format(value)
            typed = false
            // Focus stays here, and the value is said, so a
            // VoiceOver user is not left with nothing focused.
            AccessibilityNotification.Announcement(spoken(value)).post()
            return true
        }
    }

    private func format(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(fractionDigits)).grouping(.never))
    }

    /// A bound as VoiceOver says it, with the field's unit or sign.
    private func spoken(_ v: Double) -> String {
        [prefix, format(v), unit].compactMap { $0 }.joined(separator: prefix == nil ? " " : "")
    }

    private func commit() {
        guard typed else { text = format(value); return }
        typed = false
        let cleaned = text.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "×xX%"))
        let parsed = (try? Double(cleaned, format: .number)) ?? Double(cleaned.replacingOccurrences(of: ",", with: "."))
        if let parsed {
            let scale = pow(10, Double(fractionDigits))
            let v = (min(range.upperBound, max(range.lowerBound, parsed)) * scale).rounded() / scale
            if v != value { value = v }
            text = format(v)
        } else {
            text = format(value)
        }
    }
}
