import SwiftUI
import SceneKit
import Metal
import GameController
import UniformTypeIdentifiers

// MARK: - Smart Preset Maker (guided wizard)

/// Branching wizard that turns a few answers ("Play a game" -> "Roblox" ->
/// "Switch Pro") into a tailored preset, fusing a researched mapping profile
/// with the user's controller and chosen options. Generated presets carry
/// controller-aware setup notes and land in the sidebar where the user picks.
struct SmartPresetMakerView: View {
    @EnvironmentObject var presetStore: PresetStore
    @EnvironmentObject var controllerService: GameControllerService
    @Environment(\.dismiss) private var dismiss
    var onCreated: (Preset) -> Void

    enum Step: Int, CaseIterable { case category, item, controller, options, finish }

    @State private var step: Step = .category
    @State private var category: SmartPresetProfile.Category?
    @State private var profile: SmartPresetProfile?
    @State private var brand: ControllerBrand = .dualSense
    @State private var search = ""
    @State private var makerSearchAnnouncement: DispatchWorkItem?

    @State private var autoLaunch = false
    @State private var appPath = ""
    /// An app picked with Choose: it replaces the Steam link even when it
    /// is the profile's own path.
    @State private var appChosen = false
    @State private var confine = false
    @State private var recenter = false
    @State private var hideCursor = false
    @State private var addTouchpad = true
    @State private var addGyro = true
    @State private var rumble = false
    @State private var paddles = false
    @State private var pointerRamp = false
    @State private var sprintAtFullPush = true
    @State private var walkOnLightPush = true
    @State private var lightColor: Color = .green

    @State private var name = ""
    @State private var groupID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView { content.padding(20).frame(maxWidth: .infinity, alignment: .leading) }
            Divider()
            footer
        }
        // Shrinks with a short window rather than being cut off by it.
        .frame(width: 580)
        .frame(minHeight: 300, idealHeight: 600)
        // The whole step is replaced: say which one it is now.
        .onChange(of: step) { _, _ in
            AccessibilityNotification.Announcement(stepSubtitle).post()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .font(.title2)
                .iconTint(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text("Smart Preset Maker").font(.headline).accessibilityAddTraits(.isHeader)
                Text(stepSubtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                // Escape in the search field clears it first, as in the editor.
                if NSApp.currentEvent?.type == .keyDown, step == .item, !search.isEmpty { search = ""; return }
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusRingForKeyboardUsers()
            .accessibilityLabel("Close")
            .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .category:   categoryStep
        case .item:       itemStep
        case .controller: controllerStep
        case .options:    optionsStep
        case .finish:     finishStep
        }
    }

    private var footer: some View {
        HStack {
            if step != .category {
                Button("Back") { back() }.buttonStyle(.solidSecondary)
            }
            Spacer()
            if step == .options {
                Button("Next") { step = .finish }.buttonStyle(.solid)
                    .keyboardShortcut(.defaultAction)
            } else if step == .finish {
                Button("Create Preset") { create() }
                    .buttonStyle(.solid)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
    }

    // MARK: Steps

    private var categoryStep: some View {
        VStack(spacing: 12) {
            Text("What do you want to do?").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(SmartPresetProfile.Category.allCases) { cat in
                Button {
                    category = cat; search = ""; step = .item
                } label: {
                    HStack(spacing: 12) {
                        IconView(name: cat.systemImage, glyphHeight: 17).font(.title2).frame(width: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(catTitle(cat)).font(.headline)
                            Text(catDesc(cat)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.forward").foregroundStyle(.hint).accessibilityHidden(true)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                // Voice Control answers to the title alone.
                .accessibilityInputLabels([Text(catTitle(cat))])
            }
        }
    }

    private var itemStep: some View {
        let items = (category.map { SmartPresetLibrary.profiles(in: $0) } ?? [])
            .filter {
                search.isEmpty
                || $0.displayName.localizedCaseInsensitiveContains(search)
                || ShippedText.t($0.displayName).localizedCaseInsensitiveContains(search)
                || $0.subtitle.localizedCaseInsensitiveContains(search)
                || ShippedText.t($0.subtitle).localizedCaseInsensitiveContains(search)
            }
        return VStack(alignment: .leading, spacing: 10) {
            Text(category?.pluralPrompt ?? String(localized: "Pick one")).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            TextField("Search…", text: $search).textFieldStyle(.roundedBorder)
                // The count said once typing pauses, as the editor's search does.
                .onChange(of: search) { _, _ in
                    makerSearchAnnouncement?.cancel()
                    let n = items.count
                    let work = DispatchWorkItem {
                        AccessibilityNotification.Announcement(n == 0 ? String(localized: "No matches")
                            : n == 1 ? String(localized: "1 match") : String(localized: "\(n) matches")).post()
                    }
                    makerSearchAnnouncement = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
                }
            if items.isEmpty {
                Text("No matches yet. More titles are added over time.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            }
            ForEach(items) { p in
                Button { select(p) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ShippedText.t(p.displayName)).font(.body.weight(.medium))
                            Text(ShippedText.t(p.subtitle)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.forward").foregroundStyle(.hint).accessibilityHidden(true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.05)))
                }
                .buttonStyle(.plain)
                .accessibilityInputLabels([Text(ShippedText.t(p.displayName))])
            }
        }
    }

    private var controllerStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Which controller?").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            ForEach(controllerChoices, id: \.self) { b in
                Button {
                    brand = b
                    if let p = profile { name = "\(ShippedText.t(p.displayName).withoutRTLMark) (\(b.displayName))" }
                    step = .options
                } label: {
                    HStack(spacing: 10) {
                        ControllerGlyph(height: 15).frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(b.displayName)
                                if connectedBrands.contains(b) {
                                    Text("Connected").font(.caption2)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Capsule().fill(Color.green.opacity(0.2)))
                                        .foregroundStyle(.green)
                                }
                            }
                            Text(b.capabilitySummary)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.forward").foregroundStyle(.hint).accessibilityHidden(true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.05)))
                }
                .buttonStyle(.plain)
                .accessibilityInputLabels([Text(b.displayName)])
            }
        }
    }

    private var optionsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Fine-tune").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Toggle("Open the app automatically when this preset activates", isOn: $autoLaunch)
            if autoLaunch {
                HStack {
                    Text(appPath.isEmpty ? ((profile?.launchURL.isEmpty == false) ? String(localized: "Opens through Steam") : String(localized: "No app chosen")) : appPath)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose App…") { chooseApp() }.buttonStyle(.solidSecondaryCompact)
                }
            }
            Divider()
            Toggle("Confine the mouse to the screen (boundaries)", isOn: $confine)
            Toggle("Auto-recenter the cursor", isOn: $recenter)
            Toggle("Hide the cursor while active", isOn: $hideCursor)
            if brand.hasLightBar {
                Divider()
                HStack {
                    Text("Light bar color")
                    Spacer()
                    ColorPicker("Light bar color", selection: $lightColor, supportsOpacity: false).labelsHidden()
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Label { Text("\(brand.displayName) supports: \(brand.capabilitySummary)") } icon: { ControllerGlyph(height: 10) }
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if brand.hasTouchpad {
                    Toggle("Use the touchpad as a trackpad (one finger points, two fingers scroll, tap to click)", isOn: $addTouchpad)
                }
                if brand.hasMotion, let p = profile, SmartPresetGenerator.usesMouseLook(p) {
                    Toggle("Gyro fine aim (tilting the pad nudges the aim on top of the stick)", isOn: $addGyro)
                }
                if let p = profile, SmartPresetGenerator.canRumbleOnTriggers(p) {
                    Toggle("Rumble when a trigger clicks", isOn: $rumble)
                }
                if brand.supports("paddles") {
                    Toggle(brand == .dualSense ? String(localized: "Back buttons repeat the bottom and right face buttons (DualSense Edge)")
                           : brand == .steamController ? String(localized: "Back buttons L4, R4, L5, and R5 repeat the four face buttons")
                           : String(localized: "Back paddles repeat the four face buttons (Xbox Elite)"), isOn: $paddles)
                }
                if let p = profile, SmartPresetGenerator.usesMouseLook(p) {
                    Toggle("Pointer ramp-up (a short push moves slowly, a held push speeds up)", isOn: $pointerRamp)
                }
                if let p = profile, SmartPresetGenerator.canSprintAtFullPush(p) {
                    Toggle("Sprint at full push (the left stick pushed all the way forward also sprints, as on a console)", isOn: $sprintAtFullPush)
                }
                if let p = profile, SmartPresetGenerator.canWalkOnLightPush(p) {
                    Toggle("Walk quietly on a light push (a light push of the left stick holds the walk key, a full push runs)", isOn: $walkOnLightPush)
                }
            }
            if let p = profile, !p.tips.isEmpty {
                Divider()
                Text("Tips").font(.caption.weight(.semibold))
                ForEach(p.tips, id: \.self) { tip in
                    Text("• \(ShippedText.t(tip))").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Name & save").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            TextField("Preset name", text: $name).textFieldStyle(.roundedBorder)
            Picker("Add to folder", selection: $groupID) {
                Text("My Presets").tag(UUID?.none)
                // Full paths, as every other folder chooser: two "Favorites"
                // in different folders could not be told apart.
                ForEach(presetStore.folderPathChoices(), id: \.id) { choice in
                    Text(choice.path).tag(UUID?.some(choice.id))
                }
            }
            if let p = profile {
                VStack(alignment: .leading, spacing: 4) {
                    summaryRow("What", ShippedText.t(p.displayName))
                    summaryRow("Controller", brand.displayName)
                    // Yes only with something to open: on with no app chosen,
                    // the preset launched nothing.
                    summaryRow("Auto-launch", autoLaunch && (!appPath.isEmpty || profile?.launchURL.isEmpty == false)
                               ? String(localized: "Yes") : String(localized: "No"))
                    summaryRow("Mouse confine", confine ? String(localized: "On") : String(localized: "Off"))
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
            }
            if let p = profile {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mapping preview").font(.caption.weight(.semibold))
                    ForEach(Array(p.bindings.prefix(6).enumerated()), id: \.offset) { _, b in
                        Text("\(SmartPresetGenerator.label(for: b.input, brand: brand))  →  \(SmartPresetGenerator.localizedAction(of: b.note))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if p.bindings.count > 6 {
                        Text(p.bindings.count - 6 == 1 ? String(localized: "+ 1 more binding") : String(localized: "+ \(p.bindings.count - 6) more bindings"))
                            .font(.caption2).foregroundStyle(.hint)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.04)))
            }
            Text("After it's created you can edit any binding. If a control doesn't respond, open the binding editor and tap Scan. Controllers vary, so the preset notes list what each control should do.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Helpers

    private func back() {
        step = Step(rawValue: max(0, step.rawValue - 1)) ?? .category
    }

    private func select(_ p: SmartPresetProfile) {
        profile = p
        confine = p.confineCursor
        recenter = p.autoRecenter
        hideCursor = p.hideCursor
        // A Steam game opens through its steam:// link even with no app path.
        autoLaunch = !p.appPath.isEmpty || !p.launchURL.isEmpty
        appPath = p.appPath
        appChosen = false
        lightColor = Color(.sRGB,
                           red: Double(p.light.r) / 255.0,
                           green: Double(p.light.g) / 255.0,
                           blue: Double(p.light.b) / 255.0)
        if let connected = controllerChoices.first(where: { connectedBrands.contains($0) }) { brand = connected }
        name = "\(ShippedText.t(p.displayName).withoutRTLMark) (\(brand.displayName))"
        step = .controller
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.message = String(localized: "Choose the app this preset is for")
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { appPath = url.path; appChosen = true }
    }

    private func create() {
        guard let p = profile else { return }
        let ns = NSColor(lightColor).usingColorSpace(.sRGB) ?? NSColor(lightColor)
        let lc = SmartPresetProfile.Light(
            r: Int((ns.redComponent * 255).rounded()),
            g: Int((ns.greenComponent * 255).rounded()),
            b: Int((ns.blueComponent * 255).rounded()))
        let opts = SmartPresetGenerator.Options(
            name: name.trimmingCharacters(in: .whitespaces),
            groupID: groupID,
            autoLaunchApp: autoLaunch,
            // Only a path the user changed replaces the profile's launch: the
            // pre-filled Steam.app path dropped its steam:// link, so the game
            // itself never started.
            appPathOverride: appPath.isEmpty || (appPath == p.appPath && !appChosen) ? nil : appPath,
            confineCursor: confine,
            autoRecenter: recenter,
            hideCursor: hideCursor,
            lightColor: lc,
            touchpadAsTrackpad: addTouchpad,
            gyroFineAim: addGyro,
            rumbleOnTriggers: rumble,
            backPaddles: paddles,
            pointerRamp: pointerRamp,
            sprintAtFullPush: sprintAtFullPush,
            walkOnLightPush: walkOnLightPush)
        let preset = SmartPresetGenerator.makePreset(from: p, brand: brand, options: opts)
        presetStore.savePreset(preset)
        onCreated(preset)
        dismiss()
    }

    private var connectedBrands: Set<ControllerBrand> {
        Set(controllerService.controllerDetails.values.map { $0.brand }.filter { $0 != .unknown })
    }

    /// The pads a smart preset can be made for. The Steam Controller only
    /// when a 2026 model is connected: the rows use the standard numbering,
    /// which the 2015 model does not read.
    private var controllerChoices: [ControllerBrand] {
        let steam2026 = controllerService.rawHIDGamepadSlots.values.contains { $0.profile?.layout == .steamController2026 }
        return [.dualSense, .dualShock4, .xbox, .switchPro, .eightBitDo, .stadia, .mfiGeneric]
            + (steam2026 ? [.steamController] : [])
    }

    private var stepSubtitle: String {
        switch step {
        case .category:   return String(localized: "Step 1 of 5: Choose what you're setting up")
        case .item:       return String(localized: "Step 2 of 5: Pick the title")
        case .controller: return String(localized: "Step 3 of 5: Pick your controller")
        case .options:    return String(localized: "Step 4 of 5: Options")
        case .finish:     return String(localized: "Step 5 of 5: Name & save")
        }
    }

    private func catTitle(_ c: SmartPresetProfile.Category) -> String {
        switch c {
        case .game:     return String(localized: "Play a game")
        case .app:      return String(localized: "Work in an app")
        case .workflow: return String(localized: "A workflow")
        }
    }

    private func catDesc(_ c: SmartPresetProfile.Category) -> String {
        switch c {
        case .game:     return String(localized: "Roblox, Minecraft, Elden Ring, and more")
        case .app:      return String(localized: "Blender, Photoshop, Word, video editors, and more")
        case .workflow: return String(localized: "Desktop, web, media, presenting, accessibility")
        }
    }

    private func summaryRow(_ key: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(key).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
            Text(value)
        }
        .font(.caption)
    }
}


/// A quiet rotating pill of one-line feature tips, ported from YapToText's
/// QuickTipsPill. The text swaps on a slow clock with NO animated transaction
/// and the pill keeps a stable single-Text structure.
struct QuickTipsPill: View {
    private static let tips: [String] = [
        String(localized: "Press \u{2303}\u{2325}\u{2318}P anywhere to toggle your most recent preset, even while a game is in front (enable it in Settings)."),
        String(localized: "The Smart Preset Maker builds a tailored preset from a few questions: pick a game, answer, done."),
        String(localized: "Gyro aim: bind gyro yaw to mouse X and pitch to mouse Y for motion aiming in any app."),
        String(localized: "The DualSense touchpad can drive your Mac's cursor while a second finger scrolls."),
        String(localized: "Turbo any button to rapid-fire it, or flip a binding to Toggle to latch it on and off."),
        String(localized: "Macros chain keystrokes with per-step timing, and can mix keys, clicks, and MIDI in one sequence."),
        String(localized: "Sticks and triggers can send MIDI notes and CC dials straight into GarageBand, Logic, or Ableton."),
        String(localized: "A preset can auto-activate when its app comes to the front, then step aside when you leave."),
        String(localized: "Set the DualSense light bar per preset so you can see which mapping is live from across the room."),
        // Voice rows in a language with no on-device recognition use Apple's
        // servers, so "nothing uploaded" was not true for everyone.
        String(localized: "Your presets and statistics stay on your Mac. No telemetry, no account."),
        String(localized: "Import presets with the tray icon in the bottom bar; export any preset from its right-click menu."),
        String(localized: "Hide the Dock icon in Settings to run InputConfig as a quiet menu bar app."),
        String(localized: "The editor keeps your last 100 changes: \u{2318}Z and \u{2318}\u{21E7}Z step through them."),
        String(localized: "Click any control on the Live Visualizer to jump straight to its binding in the editor."),
    ]

    @State private var index = Int.random(in: 0..<QuickTipsPill.tips.count)
    @State private var rotator: Task<Void, Never>?
    @State private var holding = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appReduceMotion) private var appReduceMotion

    /// The tip stays put while the pointer is on it, with VoiceOver on, or
    /// with Reduce Motion, so a tip being read is not swapped out.
    private var rotationPaused: Bool {
        holding || reduceMotion || appReduceMotion || NSWorkspace.shared.isVoiceOverEnabled
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "lightbulb.max").iconTint(.accentColor).font(.caption)
            Text(Self.tips[index])
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(Color.secondary.opacity(0.06), in: Capsule())
        .overlay(Capsule().stroke(Color.secondary.opacity(0.12), lineWidth: 0.5))
        .onAppear {
            rotator?.cancel()
            rotator = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 9_000_000_000)
                    guard !Task.isCancelled else { return }
                    if rotationPaused { continue }
                    index = (index + 1) % Self.tips.count
                }
            }
        }
        .onDisappear { rotator?.cancel(); rotator = nil }
        .onHover { holding = $0 }
        .accessibilityLabel("Tip: \(Self.tips[index])")
    }
}
