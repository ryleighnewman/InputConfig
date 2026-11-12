import SwiftUI
import SceneKit
import Metal
import GameController
import UniformTypeIdentifiers

// ContentView, the welcome screen, the tutorial, turning presets on and off, and the permission
// sheets. Split from ContentView.swift, where the type and its state live, so a Debug build type-
// checks it in parallel with the rest.

extension ContentView {
    // MARK: - Welcome

    /// Shown in the detail area when no preset is selected. Acts as both a
    /// landing page and a feature index. Designed to be skim-able: an icon,
    /// a headline, a one-line subtitle, a feature grid, and a single call
    /// to action. Not a modal or popup - replaces the "Select a preset"
    /// placeholder when the user hasn't picked one yet.
    var welcomeView: some View {
        ScrollViewReader { welcomeProxy in
        let _ = LaunchSignpost.once("Welcome.body")
        ScrollView {
            VStack(spacing: 24) {
                // Headline
                VStack(spacing: 10) {
                    ControllerGlyph(height: 42)
                        .foregroundStyle(.hint)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Welcome to InputConfig")
                            .font(.title2.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        // Small gray version on the same line, which doubles
                        // as the release-notes button (same pattern as the
                        // sibling app's home header).
                        Button { showWelcomeChangelog = true } label: {
                            Text(Changelog.currentVersion)
                                .font(.caption)
                                .foregroundStyle(.hint)
                        }
                        .buttonStyle(.plain)
                        .help("What's new in this version")
                        .accessibilityLabel("Version \(Changelog.currentVersion), what's new")
                        .accessibilityInputLabels([Text(Changelog.currentVersion), Text("What's new")])
                        .popover(isPresented: $showWelcomeChangelog, arrowEdge: .bottom) {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 14) {
                                    Text("What's new").font(.headline).accessibilityAddTraits(.isHeader)
                                    ForEach(Changelog.entries) { entry in
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(entry.version)
                                                .font(.subheadline.weight(.semibold))
                                                .accessibilityAddTraits(.isHeader)
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
                                .background(OverlayScrollers())
                            }
                            // Keys scroll it, with nothing focusable inside.
                            .focusable()
                            .frame(maxHeight: 460)
                        }
                    }
                    Text("Do anything with your Mac!")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 24)

                // Quick actions, in two rows: the two creation buttons on top,
                // the two help / onboarding buttons underneath.
                VStack(spacing: 10) {
                    // Row 1: create a preset, or build one with the wizard.
                    // Each row is a centered flow, so a narrow window wraps
                    // its buttons onto another line instead of squeezing.
                    CenteredFlow(spacing: 10) {
                        Button {
                            let preset = presetStore.createPreset()
                            selectedPresetId = preset.id
                            // Mark this as freshly-created so an editor
                            // Cancel deletes the empty draft instead of
                            // leaving it lingering in the sidebar.
                            newlyCreatedPresetId = preset.id
                            editingPreset = preset
                        } label: {
                            Label("Create New Preset", systemImage: "plus")
                        }
                        .buttonStyle(.solid)
                        .spotlightAnchor(SpotlightID.createNew)

                        // Smart Preset Maker: guided wizard, as a quiet secondary
                        // capsule so it doesn't overpower the creation action.
                        Button {
                            showingSmartMaker = true
                        } label: {
                            Label("Smart Preset Maker", systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.solidSecondary)
                        .help("Answer a few quick questions and we'll build a tailored preset for your game, app, or workflow")

                        // The ready-made first preset for everyone: opens its
                        // page, where Activate starts it.
                        if let easyBrowse = presetStore.presets.first(where: { $0.name == ExamplePresets.easyBrowseName }) {
                            Button {
                                revealPreset(easyBrowse.id)
                                announceOpened(easyBrowse)
                            } label: {
                                // The name the sidebar shows for it.
                                Label(String(localized: "Start with \(easyBrowse.shownName)"), systemImage: "hand.wave")
                            }
                            .buttonStyle(.solidSecondary)
                            .help("A ready-made layout for using the whole Mac from a controller: pointer, scrolling, clicks, dictation, reading aloud, Spotlight, and web pages. Opens it; press Activate to start.")
                        }
                    }

                    // Row 2: onboarding + docs, underneath the creation buttons.
                    CenteredFlow(spacing: 10) {
                        Button("Quick Start Guide") {
                            startTutorial()
                        }
                        // Sized to match the other welcome buttons. The hero
                        // glass CTA (GlassCTAButton) is reserved for standalone
                        // primary surfaces, not this grid of equal actions.
                        .buttonStyle(SolidButton(tint: .teal))
                        .help("Guided walkthrough of every major feature with click animations")

                        Button {
                            HelpGuideWindowController.shared.show()
                        } label: {
                            Label("Open Help Guide", systemImage: "questionmark.circle")
                        }
                        .buttonStyle(.solidSecondary)

                        Button {
                            settingsSheetTab = .about
                        } label: {
                            Label("About", systemImage: "info.circle")
                        }
                        .buttonStyle(.solidSecondary)
                        .help("The story behind InputConfig, the changelog, and ways to say hi")
                    }
                }

                // A literal horizontal bracket over the grid with its title
                // in the gap, gray like the caption text.
                BracketHeader(title: "Feature Showcases")
                    .padding(.top, 6)
                    .padding(.horizontal, 28)

                // Feature grid - each card opens an animated demo sheet
                // explaining the feature, with a button to jump to a matching
                // example preset. Four columns at the default window size; a
                // card never goes under 210 pt wide, so a narrower window or
                // a wider sidebar drops to three columns and the cards move
                // down instead of their text squeezing.
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 210), spacing: 12)],
                    spacing: 12
                ) {
                    demoCard(kind: .keyboardMouse,
                             icon: "keyboard",
                             detail: "Map any button, trigger, or stick to keyboard keys, mouse buttons, mouse motion, or scroll wheel.",
                             tint: .orange)
                    demoCard(kind: .controllers,
                             icon: "gamecontroller.fill",
                             detail: "DualSense, DualShock 4, Xbox, Switch Pro, Joy-Cons, Stadia, 8BitDo, and any MFi gamepad.",
                             tint: .cyan)
                    demoCard(kind: .voiceCommands,
                             icon: "waveform",
                             detail: "Say a phrase and it fires any output, no controller needed: show your windows, open search, start dictation.",
                             tint: .mint)
                    demoCard(kind: .midiInput,
                             icon: "pianokeys",
                             detail: "Use a MIDI keyboard or knob box as input, no controller needed. Knobs can switch, scroll with speed, nudge in steps, or work the Mac's volume like a fader.",
                             tint: .pink)
                    demoCard(kind: .midi,
                             icon: "music.note.list",
                             detail: "Send Note, CC, and Pitch Bend through a virtual MIDI port to GarageBand, Logic, Ableton, and more.",
                             tint: .pink)
                    demoCard(kind: .systemControl,
                             icon: "gearshape.2.fill",
                             detail: "Outputs can run the Mac itself: volume, mute, media keys, brightness, Mission Control, lock screen, Siri Shortcuts, open any app or URL.",
                             tint: .teal)
                    demoCard(kind: .siriShortcuts,
                             icon: "sparkles.rectangle.stack.fill",
                             detail: "Run any Siri Shortcut from any input: scenes, timers, Do Not Disturb, whole automations: one press, no focus stolen.",
                             tint: .indigo)
                    demoCard(kind: .inputRemap,
                             icon: "keyboard.badge.ellipsis",
                             detail: "The Mac's keyboard as an input: letters, both sides of every modifier, the top row's brightness, media, and volume keys, and F13 to F19, all live on a drawn keyboard.",
                             tint: .orange)
                    demoCard(kind: .macTrackpad,
                             icon: "rectangle.and.hand.point.up.left.fill",
                             detail: "Trackpad and Magic Mouse as inputs: clicks, side and middle buttons, scroll in four directions, double clicks, scroll gestures, and force click, all drawn live.",
                             tint: .mint)
                    demoCard(kind: .modifierHolds,
                             icon: "command",
                             detail: "Hold a modifier on its own to run the Mac. Command, Option, and Shift keep every shortcut; only a long hold or a double tap alone fires.",
                             tint: .indigo)
                    demoCard(kind: .variableSensitivity,
                             icon: "slider.horizontal.below.rectangle",
                             detail: "Joystick depth scales output speed. Pick linear, smooth, or aggressive curves per binding.",
                             tint: .blue)
                    demoCard(kind: .deadzone,
                             icon: "scope",
                             detail: "Live joystick visualizer with a draggable trail and slider to find the perfect deadzone.",
                             tint: .green)
                    demoCard(kind: .stickZones,
                             icon: "circle.dashed",
                             detail: "Rings and areas on a stick, bands on a trigger, and flicks like back twice, each one a button.",
                             tint: .cyan)
                    demoCard(kind: .toggleMode,
                             icon: "switch.2",
                             detail: "Press once to latch on, press again to release. Sticky modifiers, push-to-talk, auto-run.",
                             tint: .orange)
                    demoCard(kind: .macros,
                             icon: "bolt.fill",
                             detail: "Record keys and clicks in any app or build the steps by hand: text, scrolls, pointer moves, waits. Turbo rapid-fires any button.",
                             tint: .yellow)
                    demoCard(kind: .stackedOutputs,
                             icon: "square.stack.3d.up.fill",
                             detail: "One press fires key + click + MIDI + speech in parallel. Different from a macro: all at once, not in sequence.",
                             tint: .blue)
                    demoCard(kind: .holdDoubleTap,
                             icon: "hand.tap.fill",
                             detail: "Press, hold, and double-tap each fire their own outputs. One button, three actions, adjustable timing.",
                             tint: .blue)
                    demoCard(kind: .appAutoSwitch,
                             icon: "app.connected.to.app.below.fill",
                             detail: "Presets activate themselves when their app comes to the front: the game preset in the game, the DAW preset in the DAW.",
                             tint: .green)
                    demoCard(kind: .autoLaunch,
                             icon: "app.badge.fill",
                             detail: "Per-preset Utilities: open an app on activate, confine the cursor, hide the system pointer.",
                             tint: .green)
                    demoCard(kind: .touchpad,
                             icon: "rectangle.and.hand.point.up.left.fill",
                             detail: "DualSense and DualShock 4 touchpad surfaces can drive the mouse cursor.",
                             tint: .mint)
                    demoCard(kind: .touchpadRegions,
                             icon: "rectangle.split.2x2.fill",
                             detail: "Carve the DualSense touchpad into regions that each fire their own binding, with a pulse when you hit one.",
                             tint: .orange)
                    demoCard(kind: .gyro,
                             icon: "gyroscope",
                             detail: "Tilt-to-aim with the controller's gyroscope, on controllers with motion sensors: DualSense, DualShock 4, Switch and Steam Controllers and more.",
                             tint: .teal)
                    demoCard(kind: .cursorRegions,
                             icon: "rectangle.dashed",
                             detail: "Draw screen regions that act as inputs: the cursor entering one can press keys, run macros, or fire anything else.",
                             tint: .purple)
                    demoCard(kind: .haptic,
                             icon: "waveform",
                             detail: "Vibrate the controller when a binding fires. Works with DualSense, DualSense Edge, and similar.",
                             tint: .purple)
                    demoCard(kind: .speech,
                             icon: "speaker.wave.2.fill",
                             detail: "Speak a custom phrase on press, through the Mac's sound output.",
                             tint: .indigo)
                    demoCard(kind: .midiCC,
                             icon: "dial.high.fill",
                             detail: "Sticks and triggers send continuous MIDI Control Change values. Soft knobs for your DAW.",
                             tint: .purple)
                    demoCard(kind: .stats,
                             icon: "chart.bar.fill",
                             detail: "Lifetime counts of presses, motion, scrolls, and MIDI events with most-used inputs and presets. All local, no telemetry.",
                             tint: .brown)
                    demoCard(kind: .lightBar,
                             icon: "light.beacon.max.fill",
                             detail: "Pick a color with the picker, set brightness, or run an RGB cycle on DualSense controllers.",
                             tint: .red)
                }
                .padding(.horizontal, 28)

                QuickTipsPill()
                    .padding(.horizontal, 40)

                Text("Plug in a controller to get started. Open the Help menu for setup guides for every supported device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                // Sister-app shoutout, anchoring the bottom of the homepage.
                // Mirrors the shoutout YapToText's About page gives
                // InputConfig, so the two apps point at each other.
                HStack(spacing: 14) {
                    Image("YapToTextIcon")
                        .resizable().scaledToFit()
                        .frame(width: 48, height: 48)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Like InputConfig? Try YapToText.")
                            .font(.callout.weight(.semibold))
                        Text("From the same developer: ultra-powerful dictation, processed entirely on your Mac, with advanced customization for exactly how you work. Free, private, and completely offline.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 10)
                    Link(destination: URL(string: "https://apps.apple.com/us/app/yaptotext/id6786382289?mt=12")!) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.forward.app").accessibilityHidden(true)
                            Text("App Store")
                        }
                        .font(.callout)
                    }
                    .help("Opens YapToText on the Mac App Store. It's free.")
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.secondary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
                )
                .padding(.horizontal, 28)
                .padding(.bottom, 30)
            }
            .frame(maxWidth: .infinity)
        }
        // The tour's highlighted card is scrolled into view.
        .onChange(of: tutorialFeatureSpotlight) { _, kind in
            guard let kind else { return }
            withAnimation(.easeInOut(duration: 0.5)) { welcomeProxy.scrollTo(kind, anchor: .center) }
        }
        }  // ScrollViewReader
    }

    /// Clickable feature card that opens the matching animated demo sheet.
    @ViewBuilder
    private func demoCard(kind: FeatureDemoKind, icon: String, detail: LocalizedStringKey, tint: Color) -> some View {
        FeatureCardButton(kind: kind, icon: icon, detail: detail, tint: tint,
                          isHighlighted: tutorialFeatureSpotlight == kind) {
            presentedDemoKind = kind
        }
        .modifier(ConditionalSpotlightAnchor(
            active: tutorialFeatureSpotlight == kind,
            id: SpotlightID.welcomeCard))
        .id(kind)
    }

    /// Stand-alone home-screen feature card with the same hover lift /
    /// tint / scale treatment the Statistics dashboard uses on its
    /// tiles. Lifted out of `demoCard` because tracking a hover state
    /// requires its own `@State`, and embedding @State inside a
    /// `@ViewBuilder func` doesn't compose well.
    private struct FeatureCardButton: View {
        @Environment(\.appReduceMotion) private var appReduceMotion
        let kind: FeatureDemoKind
        let icon: String
        let detail: LocalizedStringKey
        let tint: Color
        let isHighlighted: Bool
        let onTap: () -> Void
        @State private var hovering: Bool = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            // TimelineView gives us a continuous time stream so the
            // spotlight pulse actually loops while `isHighlighted` is
            // true. (`.animation(...repeatForever..., value:)` keyed
            // on a Bool only fires on the transition and doesn't
            // actually animate - SwiftUI sees no value change to
            // interpolate against, so the card just sat there.)
            // Reduce Motion pauses the timeline and pins the pulse at
            // fully highlighted instead of looping.
            TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                    paused: !isHighlighted || reduceMotion || appReduceMotion)) { context in
                let pulse: Double = {
                    guard isHighlighted else { return 0 }
                    if reduceMotion { return 1.0 }
                    return (sin(context.date.timeIntervalSinceReferenceDate * 2.4) + 1) / 2
                }()
                Button(action: onTap) {
                    cardLabel(pulse: pulse)
                }
                .buttonStyle(.plain)
                .focusRingForKeyboardUsers()
                // Voice Control answers to the title on the card, not the
                // title and its whole description.
                .accessibilityInputLabels([Text(kind.title)])
                .onHover { hovering = $0 }
            }
        }

        @ViewBuilder
        private func cardLabel(pulse: Double) -> some View {
            // Pre-compute everything that depends on `pulse` so the
            // modifier chain sees plain Color / CGFloat / Double
            // values. Inline ternary arithmetic was timing out the
            // type-checker.
            let fillColor: Color = {
                if isHighlighted { return tint.opacity(0.18 + 0.18 * pulse) }
                if hovering { return tint.opacity(0.16) }
                return Color.clear
            }()
            let strokeColor: Color = {
                if isHighlighted { return tint.opacity(0.7 + 0.3 * pulse) }
                if hovering { return tint.opacity(0.55) }
                return Color.clear
            }()
            let strokeWidth: CGFloat = isHighlighted
                ? CGFloat(1.5 + pulse)
                : 1
            let shadowColor: Color = isHighlighted
                ? tint.opacity(0.3 + 0.5 * pulse)
                : Color.clear
            let shadowRadius: CGFloat = isHighlighted
                ? CGFloat(8.0 + 8.0 * pulse)
                : 0
            let scale: CGFloat = {
                if reduceMotion || appReduceMotion { return 1.0 }
                if isHighlighted { return CGFloat(1.0 + 0.05 * pulse) }
                if hovering { return 1.02 }
                return 1.0
            }()
            // Tint only lights up on hover or while the tour highlights
            // the card. At rest every tile's icon is neutral gray, so the
            // grid reads as one calm surface instead of a wall of color.
            let active: Bool = hovering || isHighlighted
            let iconColor: Color = active ? tint : Color.secondary.opacity(0.55)
            let chevronTint: Color = active ? tint : Color.secondary.opacity(0.45)
            return HStack(alignment: .top, spacing: 10) {
                IconView(name: icon, glyphHeight: 14)
                    .font(.system(size: 18))
                    .foregroundStyle(iconColor)
                    .frame(width: 24, height: 24)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(kind.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Image(systemName: "play.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(chevronTint)
                            .accessibilityHidden(true)
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 10).fill(fillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(strokeColor, lineWidth: strokeWidth)
            )
            .shadow(color: shadowColor, radius: shadowRadius)
            .scaleEffect(scale)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    /// Helper because `.spotlightAnchor(...)` can't be conditionally
    /// applied directly inside a ViewBuilder; use a ViewModifier.
    private struct ConditionalSpotlightAnchor: ViewModifier {
        let active: Bool
        let id: String
        func body(content: Content) -> some View {
            if active {
                content.spotlightAnchor(id)
            } else {
                content
            }
        }
    }

    // MARK: - Helpers

    func presetBinding(for preset: Preset) -> SwiftUI.Binding<Preset> {
        SwiftUI.Binding(
            get: { presetStore.presets.first(where: { $0.id == preset.id }) ?? preset },
            set: { newValue in
                presetStore.savePreset(newValue)
            }
        )
    }

    /// The preset as stored, after the name, tag or notes still being typed
    /// on the page are saved. The editor and the engine start from this:
    /// the editor's Save writes its whole copy, so one opened within half a
    /// second of typing would have put the old name back.
    func committed(_ preset: Preset) -> Preset {
        pageDrafts.commit()
        return presetStore.presets.first(where: { $0.id == preset.id }) ?? preset
    }

    // MARK: - Actions

    /// Queue the preset for delete confirmation. The dialog is wired up via
    /// the main body's `.confirmationDialog(presenting:)`.
    func confirmDelete(_ preset: Preset) {
        presetPendingDelete = preset
    }

    // MARK: - Quick Start tutorial

    /// Close any sheets opened by tutorial steps when the tour ends.
    /// Wired up through TutorialPlumbing so the heavy body chain doesn't
    /// hold yet another onChange.
    /// The tour closes the editor only when nothing in it is unsaved: an
    /// editor the person opened during the tour lost its changes.
    /// The tour's own editor, unless the person has one open on another
    /// preset: replacing it dropped their unsaved edits (a new draft was
    /// deleted outright) and left the running preset paused.
    private func openTourEditor(_ p: Preset) {
        if let open = OpenEditor.current, open.presetID != p.id { return }
        editingPreset = committed(p)
    }

    private func closeTourEditor() {
        // The tour's own demo editor always closes; it puts that preset back.
        let isTourDemo = editingPreset?.id != nil && editingPreset?.id == tutorialPresetSnapshot?.id
        if isTourDemo || OpenEditor.current?.isDirty() != true { editingPreset = nil }
    }

    /// The preset the tour borrowed, as it was, kept on disk until the tour
    /// ends: a quit mid-tour left the borrowed slot's type rewritten for good.
    static let tourBorrowKey = "InputConfig.tourBorrowedPreset.v1"

    /// Puts back the slot types, and drops groups the tour added that are
    /// still empty; anything the user did meanwhile stays.
    static func restoreTourBorrow(_ original: Preset, in store: PresetStore) {
        UserDefaults.standard.removeObject(forKey: tourBorrowKey)
        guard var current = store.presets.first(where: { $0.id == original.id }) else { return }
        for g in current.joysticks.indices where g < original.joysticks.count {
            current.joysticks[g].inputKind = original.joysticks[g].inputKind
        }
        while current.joysticks.count > original.joysticks.count,
              current.joysticks.last?.bindings.isEmpty == true {
            current.joysticks.removeLast()
        }
        current.modifiedAt = original.modifiedAt
        store.savePreset(current, skipSnapshot: true, keepDate: true)
    }

    /// A borrow left by a tour that never ended (quit, crash): undone once.
    static func restoreLeftoverTourBorrow(in store: PresetStore) {
        guard let data = UserDefaults.standard.data(forKey: tourBorrowKey) else { return }
        guard let original = try? JSONDecoder().decode(Preset.self, from: data) else {
            UserDefaults.standard.removeObject(forKey: tourBorrowKey); return
        }
        restoreTourBorrow(original, in: store)
    }

    func handleTutorialEnded() {
        // The tour's editor closes while the snapshot still says which
        // preset is its demo: cleared first, the check always failed and the
        // draft with the tour's slot kind stayed open.
        closeTourEditor()
        if let original = tutorialPresetSnapshot {
            Self.restoreTourBorrow(original, in: presetStore)
        }
        tutorialPresetSnapshot = nil
        tutorialFeatureSpotlight = nil
        HelpGuideWindowController.shared.closeForTour()
        showingMotionCalibrationFromMenu = false
        showingTouchpadCalibrationFromMenu = false
    }

    /// Kick off the guided tour. The first step's action fires immediately
    /// so the app responds the moment the user clicks "Start Tutorial".
    /// Pulled out of the `.sheet(onDismiss:)` closure inline because
    /// stacking too many `.onChange` / `.onReceive` modifiers on the
    /// same view plus an inline multi-statement dismiss handler made
    /// SwiftUI's type-checker time out. As a plain method the body
    /// resolves instantly.
    func handleEditorDismiss() {
        // If the user canceled a newly created preset, delete it.
        // The hardDelete path skips trash so a "create + cancel"
        // cycle doesn't litter the Recently Deleted buffer with
        // empty drafts. The lookup is forgiving - if for any reason
        // the row is already gone we silently no-op instead of
        // crashing on a force-unwrap.
        if let newId = newlyCreatedPresetId {
            if let draft = presetStore.presets.first(where: { $0.id == newId }) {
                // Only discard PRISTINE drafts. If the user scanned or added
                // any bindings before pressing Escape, keep the preset;
                // hard-deleting it threw away real setup work.
                let isPristine = draft.joysticks.allSatisfy { $0.bindings.isEmpty }
                if isPristine {
                    presetStore.hardDeletePreset(draft)
                    if selectedPresetId == newId { selectedPresetId = nil }
                }
            } else if selectedPresetId == newId {
                selectedPresetId = nil
            }
            newlyCreatedPresetId = nil
        }
        // Outputs go back to how they were before the editor opened, and
        // an override ends with the editor.
        mappingEngine.editorOpen = false
        mappingEngine.outputsPaused = pauseToRestoreAfterEdit
        engineWasRunningBeforeEdit = false
        // Clear any pending jump so re-opening the editor doesn't reuse
        // a stale target.
        pendingEditorJump = nil
    }

    func startTutorial() {
        // Make sure the welcome page is showing so the demo cards are
        // visible to spotlight.
        selectedPresetId = nil
        showingStats = false
        editingPreset = nil
        showingMotionCalibrationFromMenu = false
        showingTouchpadCalibrationFromMenu = false
        // Collapse the debug log so the welcome feature grid + Quick
        // Tour have full vertical room. The DebugLogView reads the
        // same @AppStorage key so this takes effect immediately.
        UserDefaults.standard.set(false, forKey: "InputConfig.debugLogExpanded")
        // Inject a synthetic DualSense Edge so all the visualizer
        // widgets (sticks / triggers / gyro / touchpad / paddles /
        // light bar) render during the tour even with no real
        // hardware plugged in. Cleaned up when the user finishes or
        // skips.
        controllerService.enableTutorialFakeController()
        tutorialState.start(steps: tutorialSteps)
    }

    /// Pick the first non-empty preset we can find. Used by the tutorial
    /// to land the user on something meaningful even if their first
    /// preset is empty.
    private func tutorialDemoPreset() -> Preset? {
        return presetStore.presets.first(where: { !$0.joysticks.isEmpty })
            ?? presetStore.presets.first
    }

    /// Pull the Minecraft seeded preset so the interactive walkthrough
    /// at the end of the tour has a concrete target. Falls back to any
    /// preset that mentions "Minecraft" in its name, then to the first
    /// non-empty preset, so the tour never dead-ends on a missing
    /// seed.
    private func tutorialMinecraftPreset() -> Preset? {
        if let p = presetStore.presets.first(where: { $0.name == "Minecraft" }) {
            return p
        }
        if let p = presetStore.presets.first(where: {
            $0.name.lowercased().contains("minecraft")
        }) {
            return p
        }
        return tutorialDemoPreset()
    }

    /// Tutorial helper: set the given preset's slot's inputKind via
    /// the store. Used by the Live Visualizer step to flip the demo
    /// preset's first slot into controller mode so the visualizer
    /// shows controller widgets even when no controller is connected.
    /// Idempotent - calling with the same kind a second time is a
    /// no-op write (still touches modifiedAt but harmless).
    /// Runs an editor step's action in the tour's editor, opening it first
    /// when Back arrived from a step that had closed it ("We opened the
    /// first row's Options" with no editor open).
    private func inTourEditor(_ p: Preset?, _ work: @escaping () -> Void) {
        guard let p, editingPreset?.id != p.id else { work(); return }
        openTourEditor(p)
        let at = TutorialState.shared.stepIndex
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard TutorialState.shared.isActive, TutorialState.shared.stepIndex == at else { return }
            work()
        }
    }

    fileprivate func tutorialSetSlotKind(presetID: UUID,
                                         slot: Int,
                                         kind: SlotInputKind) {
        guard var updated = presetStore.presets.first(where: { $0.id == presetID })
            else { return }
        // Remembered once, so the tour's change is undone when it ends: it
        // used to rewrite the user's own preset for good.
        if tutorialPresetSnapshot == nil {
            tutorialPresetSnapshot = updated
            if let data = try? JSONEncoder().encode(updated) {
                UserDefaults.standard.set(data, forKey: Self.tourBorrowKey)
            }
        }
        while updated.joysticks.count <= slot {
            updated.joysticks.append(JoystickMapping(tag: ""))
        }
        updated.joysticks[slot].inputKind = kind
        updated.modifiedAt = Date()
        presetStore.savePreset(updated)
    }

    /// Sequence of guided steps. Each action mutates ContentView state so
    /// the user sees the live app respond as the tour progresses; the
    /// spotlight references named anchors that ContentView attaches to
    /// the matching UI elements.
    private var tutorialSteps: [TutorialStep] {
        [
            TutorialStep(
                icon: "sparkles",
                tint: .teal,
                title: String(localized: "Welcome to InputConfig"),
                body: String(localized: "This short tour shows you around. Parts of the app light up as we go. Click Next to start."),
                action: {
                    selectedPresetId = nil
                    showingStats = false
                }
            ),
            TutorialStep(
                icon: "house.fill",
                tint: .blue,
                title: String(localized: "Home, Stats, and Settings"),
                body: String(localized: "These buttons at the top take you home, open your Statistics, and open Settings."),
                spotlight: SpotlightID.homeButton,
                spotlightShape: .circle,
                action: { selectedPresetId = nil }
            ),
            TutorialStep(
                icon: "list.bullet.rectangle",
                tint: .indigo,
                title: String(localized: "Your preset library"),
                body: String(localized: "The sidebar holds your presets. Each preset is one set of controls, and folders keep them tidy."),
                spotlight: SpotlightID.sidebar,
                action: { selectedPresetId = nil }
            ),
            TutorialStep(
                icon: "books.vertical.fill",
                tint: .orange,
                title: String(localized: "Example presets to learn from"),
                body: String(localized: "Each card on the home page shows a feature in action and opens an example preset you can try."),
                spotlight: SpotlightID.welcomeCard,
                action: {
                    selectedPresetId = nil
                    closeTourEditor()
                    // Pulse the gyro card first, then send the
                    // simulated cursor to land on it so the user sees
                    // exactly which tile we mean.
                    tutorialFeatureSpotlight = .gyro
                    // After the grid has scrolled the card into view.
                    let tourStepAt = TutorialState.shared.stepIndex
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                        // Not once the person moved on: it took the next step's pointer.
                        guard TutorialState.shared.isActive, TutorialState.shared.stepIndex == tourStepAt else { return }
                        TutorialState.shared.simulateClickThen(
                            at: SpotlightID.welcomeCard
                        ) {
                            // Don't actually open the demo sheet -
                            // we're just visually pointing the user at
                            // the right card.
                        }
                    }
                }
            ),

            // ─── Open a preset and walk through the editor first ───

            TutorialStep(
                icon: "rectangle.fill.on.rectangle.fill",
                tint: .teal,
                title: String(localized: "A preset's page"),
                body: String(localized: "Click a preset to see its page, with an Activate button and the Live Visualizer."),
                spotlight: SpotlightID.sidebar,
                action: {
                    tutorialFeatureSpotlight = nil
                    TutorialState.shared.simulateClickThen(
                        at: SpotlightID.sidebar
                    ) {
                        if let p = tutorialDemoPreset() {
                            selectedPresetId = p.id
                        }
                    }
                }
            ),
            TutorialStep(
                icon: "slider.horizontal.3",
                tint: .indigo,
                title: String(localized: "Edit the preset"),
                body: String(localized: "Edit opens the editor. Each row is one binding: a control on the left, and what it does on the right."),
                spotlight: SpotlightID.editButton,
                action: {
                    if let p = tutorialDemoPreset() {
                        selectedPresetId = p.id
                        TutorialState.shared.simulateClickThen(
                            at: SpotlightID.editButton
                        ) {
                            openTourEditor(p)
                        }
                    }
                }
            ),
            TutorialStep(
                icon: "bolt.fill",
                tint: .yellow,
                title: String(localized: "Options"),
                body: String(localized: "Every row has Options for the details, like toggle, turbo, macros and spoken text. We opened the first row's Options for you."),
                demo: .macroChain,
                action: {
                    inTourEditor(tutorialDemoPreset()) {
                    NotificationCenter.default.post(
                        name: .inputConfigScrollToFirstBinding, object: nil)
                    // After a brief pause for the scroll to land, ask
                    // the first row to expand its Options disclosure.
                    // It uses its own internal @State so this is the
                    // only way to drive it from outside.
                    if let firstID = tutorialDemoPreset()?
                        .joysticks.first?.bindings.first?.id {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                            NotificationCenter.default.post(
                                name: .inputConfigExpandBindingOptions,
                                object: firstID)
                        }
                    }
                    }
                }
            ),
            TutorialStep(
                icon: "tray.and.arrow.down.fill",
                tint: .blue,
                title: String(localized: "Save, then close"),
                body: String(localized: "Save keeps your changes and Cancel drops them. The tour closes the editor without saving."),
                action: {
                    // No pointer: the tour card sits over Save and Cancel.
                    let at = TutorialState.shared.stepIndex
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        guard TutorialState.shared.isActive, TutorialState.shared.stepIndex == at else { return }
                        withAnimation { closeTourEditor() }
                    }
                }
            ),
            TutorialStep(
                icon: "play.fill",
                tint: .green,
                title: String(localized: "Activate the preset"),
                body: String(localized: "Click Activate when you're ready, and your controller does what the preset says. Click it again to stop."),
                spotlight: SpotlightID.activateButton,
                action: {
                    closeTourEditor()
                    // Brief beat after the editor closes (previous step
                    // may have just dismissed it) before the cursor
                    // flies over.
                    let tourStepAt = TutorialState.shared.stepIndex
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        // Not once the person moved on: it took the next step's pointer.
                        guard TutorialState.shared.isActive, TutorialState.shared.stepIndex == tourStepAt else { return }
                        TutorialState.shared.simulateClickThen(
                            at: SpotlightID.activateButton
                        ) {
                            // Don't actually toggle - just point the
                            // user at the button. They activate when
                            // ready themselves.
                        }
                    }
                }
            ),

            // ─── Now show the Live Visualizer and its features ─────

            TutorialStep(
                icon: "gamecontroller.fill",
                tint: .teal,
                title: String(localized: "Live Visualizer"),
                body: String(localized: "The Live Visualizer shows your controller as you use it. Click any part to see what it does."),
                spotlight: SpotlightID.visualizer,
                demo: .buttonMapping,
                action: {
                    closeTourEditor()
                    // Auto-scroll the detail panel to the visualizer
                    // section. PresetDetailView listens for this and
                    // also expands the DisclosureGroup.
                    NotificationCenter.default.post(
                        name: .inputConfigScrollToVisualizer, object: nil)
                }
            ),
            TutorialStep(
                icon: "rectangle.3.group",
                tint: .blue,
                title: String(localized: "Controller menu"),
                body: String(localized: "This menu picks what the visualizer shows. We picked a controller so you can see one even without one connected."),
                spotlight: SpotlightID.templatePicker,
                action: {
                    // Force controller layout on the demo preset's
                    // first slot so the next several steps have widgets
                    // to point at.
                    if let p = tutorialDemoPreset() {
                        tutorialSetSlotKind(presetID: p.id, slot: 0, kind: .controller)
                    }
                }
            ),
            TutorialStep(
                icon: "dot.circle.and.hand.point.up.left.fill",
                tint: .blue,
                title: String(localized: "Sticks"),
                body: String(localized: "The sticks move as you push the real ones. Click a stick to see its rows."),
                demo: .analogStick
            ),
            TutorialStep(
                icon: "arrow.up.and.down.text.horizontal",
                tint: .orange,
                title: String(localized: "Triggers"),
                body: String(localized: "The triggers fill as you pull them. A row can go faster the harder you pull."),
                demo: .pressureTrigger
            ),
            TutorialStep(
                icon: "gyroscope",
                tint: .purple,
                title: String(localized: "Gyroscope motion"),
                body: String(localized: "Controllers with motion sensors can aim or steer as you tilt them. Watch the pointer click the motion picture: its menu resets the gyro."),
                demo: .gyro,
                action: {
                    NotificationCenter.default.post(name: .inputConfigScrollToVisualizer, object: nil)
                    let at = TutorialState.shared.stepIndex
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                        guard TutorialState.shared.isActive, TutorialState.shared.stepIndex == at else { return }
                        TutorialState.shared.simulateClickThen(at: SpotlightID.motionWidget) {
                            NotificationCenter.default.post(name: .inputConfigTourInspect, object: "Motion")
                        }
                    }
                }
            ),
            TutorialStep(
                icon: "gamecontroller",
                tint: .blue,
                title: String(localized: "Every control where it sits"),
                body: String(localized: "Every button is drawn where it is on your controller, and lights up when you press it."),
                action: {
                    NotificationCenter.default.post(name: .inputConfigTourInspect, object: nil)
                }
            ),
            TutorialStep(
                icon: "light.beacon.max.fill",
                tint: .pink,
                title: String(localized: "Light bar color"),
                body: String(localized: "On a PlayStation controller, pick a light bar color here. It shows while this preset is on."),
                spotlight: SpotlightID.lightBarStrip,
                demo: .lightBar,
                action: {
                    NotificationCenter.default.post(name: .inputConfigScrollToVisualizer, object: nil)
                }
            ),
            TutorialStep(
                icon: "note.text",
                tint: .yellow,
                title: String(localized: "Notes"),
                body: String(localized: "Keep notes about a preset here, like which game it's for."),
                spotlight: SpotlightID.notesSection,
                action: {
                    // Back from Calibrate Motion: its sheet goes.
                    showingMotionCalibrationFromMenu = false
                    NotificationCenter.default.post(name: .inputConfigScrollToNotes, object: nil)
                }
            ),
            TutorialStep(
                icon: "gyroscope",
                tint: .purple,
                title: String(localized: "Calibrate Motion"),
                body: String(localized: "Calibrate Motion, in the Controller menu, sets your controller's resting position. Lay it flat, click Start, and hold still for a moment."),
                action: {
                    closeTourEditor()
                    showingTouchpadCalibrationFromMenu = false
                    // Brief beat so a previously-open sheet has time to
                    // dismiss before we present the next one - otherwise
                    // SwiftUI quietly skips the second presentation.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if TutorialState.shared.isActive { showingMotionCalibrationFromMenu = true }
                    }
                }
            ),
            TutorialStep(
                icon: "rectangle.and.hand.point.up.left.fill",
                tint: .mint,
                title: String(localized: "Touchpad regions"),
                body: String(localized: "A region turns part of the touchpad into its own button. Watch the pointer select one; drag on the pad to draw your own."),
                action: {
                    showingMotionCalibrationFromMenu = false
                    // After the motion sheet has gone: one sheet at a time.
                    let at = TutorialState.shared.stepIndex
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        // A preset with saved touchpad regions shows some; else the demo's.
                        guard TutorialState.shared.isActive, TutorialState.shared.stepIndex == at,
                              let p = presetStore.presets.max(by: { $0.touchpadRegions.count < $1.touchpadRegions.count })
                                .flatMap({ $0.touchpadRegions.isEmpty ? nil : $0 }) ?? tutorialDemoPreset() else { return }
                        selectedPresetId = p.id
                        let g = p.joysticks.firstIndex { $0.inputKind == .controller } ?? 0
                        pendingEditorJump = EditorJumpTarget(joystickIndex: g, inputSerialized: "", action: .showZones(.touchpad))
                        openTourEditor(p)
                        // Once the card is open on the touchpad, the pointer picks a region.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            guard TutorialState.shared.isActive, TutorialState.shared.stepIndex == at else { return }
                            TutorialState.shared.simulateClickThen(at: SpotlightID.tourRegion) {
                                NotificationCenter.default.post(name: .inputConfigTourSelectRegion, object: 0)
                            }
                        }
                    }
                }
            ),
            TutorialStep(
                icon: "chart.line.uptrend.xyaxis",
                tint: .purple,
                title: String(localized: "Statistics"),
                body: String(localized: "Statistics shows how you use InputConfig, like button presses and time connected. It all stays on your Mac."),
                spotlight: SpotlightID.statsButton,
                spotlightShape: .circle,
                action: {
                    showingMotionCalibrationFromMenu = false
                    showingTouchpadCalibrationFromMenu = false
                    closeTourEditor()
                    // Back from Settings or Help: those go first.
                    let sheetUp = settingsSheetTab != nil
                    settingsSheetTab = nil
                    HelpGuideWindowController.shared.closeForTour()
                    let at = TutorialState.shared.stepIndex
                    DispatchQueue.main.asyncAfter(deadline: .now() + (sheetUp ? 0.3 : 0)) {
                        guard TutorialState.shared.isActive, TutorialState.shared.stepIndex == at else { return }
                        TutorialState.shared.simulateClickThen(
                            at: SpotlightID.statsButton
                        ) {
                            showingStats = true
                        }
                    }
                }
            ),
            TutorialStep(
                icon: "gear",
                tint: .gray,
                title: String(localized: "Settings"),
                body: String(localized: "Settings has your language, text size, backups and more."),
                spotlight: SpotlightID.settingsButton,
                spotlightShape: .circle,
                action: {
                    showingMotionCalibrationFromMenu = false
                    showingTouchpadCalibrationFromMenu = false
                    closeTourEditor()
                    showingStats = false
                    HelpGuideWindowController.shared.closeForTour()
                    TutorialState.shared.simulateClickThen(
                        at: SpotlightID.settingsButton
                    ) {
                        settingsSheetTab = .general
                    }
                }
            ),
            TutorialStep(
                icon: "questionmark.circle.fill",
                tint: .cyan,
                title: String(localized: "Help"),
                body: String(localized: "Help has a guide for every feature. You can start this tour again from the Help menu too."),
                action: {
                    showingMotionCalibrationFromMenu = false
                    showingTouchpadCalibrationFromMenu = false
                    closeTourEditor()
                    // The previous Settings step left the sheet open;
                    // close it, then open Help once it has gone.
                    settingsSheetTab = nil
                    showingStats = false
                    let at = TutorialState.shared.stepIndex
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        guard TutorialState.shared.isActive, TutorialState.shared.stepIndex == at else { return }
                        HelpGuideWindowController.shared.showForTour()
                    }
                }
            ),
            TutorialStep(
                icon: "tray.and.arrow.down",
                tint: .blue,
                title: String(localized: "Import a preset"),
                body: String(localized: "Got a preset file from a friend? Import it with this button, and check it over before it's added."),
                spotlight: SpotlightID.importButton,
                action: {
                    HelpGuideWindowController.shared.closeForTour()
                    settingsSheetTab = nil
                    showingStats = false
                }
            ),

            // ─── Interactive Minecraft walkthrough ─────────────────
            // From here on the tour stops *explaining* the app in
            // abstract terms and starts driving it. Each action()
            // closure mutates ContentView's @State so the user sees
            // the real UI respond - sidebar selection, editor sheet
            // opening, scrolling to specific binding rows, expanding
            // their Options disclosure - exactly what they would do
            // themselves when building a Minecraft preset from scratch.

            TutorialStep(
                icon: "cube.fill",
                tint: .green,
                title: String(localized: "A real preset: Minecraft"),
                body: String(localized: "Now let's look at a real preset. Watch the pointer open Minecraft."),
                spotlight: SpotlightID.sidebar,
                action: {
                    closeTourEditor()
                    settingsSheetTab = nil
                    showingStats = false
                    HelpGuideWindowController.shared.closeForTour()
                    TutorialState.shared.simulateClickThen(
                        at: SpotlightID.sidebar
                    ) {
                        if let mc = tutorialMinecraftPreset() {
                            selectedPresetId = mc.id
                            NotificationCenter.default.post(
                                name: .inputConfigScrollToPreset,
                                object: mc.id)
                        }
                    }
                }
            ),
            TutorialStep(
                icon: "slider.horizontal.3",
                tint: .orange,
                title: String(localized: "Open the editor"),
                body: String(localized: "Next, the pointer opens Minecraft's editor."),
                spotlight: SpotlightID.editButton,
                action: {
                    if let mc = tutorialMinecraftPreset() {
                        selectedPresetId = mc.id
                        TutorialState.shared.simulateClickThen(
                            at: SpotlightID.editButton
                        ) {
                            openTourEditor(mc)
                        }
                    }
                }
            ),
            TutorialStep(
                icon: "rectangle.dashed",
                tint: .indigo,
                title: String(localized: "A row, left to right"),
                body: String(localized: "Each row reads left to right: the control, an arrow, then what it does. The buttons at the end add, copy or delete a row."),
                action: {
                    inTourEditor(tutorialMinecraftPreset()) {
                    NotificationCenter.default.post(
                        name: .inputConfigScrollToFirstBinding, object: nil)
                    }
                }
            ),
            TutorialStep(
                icon: "dot.scope",
                tint: .red,
                title: String(localized: "Scan a control"),
                body: String(localized: "To set a control, click Scan, then press the button or move the stick. The row fills itself in."),
                action: {
                    inTourEditor(tutorialMinecraftPreset()) {
                    NotificationCenter.default.post(name: .inputConfigScrollToFirstBinding, object: "top")
                    }
                }
            ),
            TutorialStep(
                icon: "bolt.fill",
                tint: .yellow,
                title: String(localized: "Macros"),
                body: String(localized: "A macro plays several keys in a row from one press. Turn on Macro in a row's Options to add its steps."),
                action: {
                    inTourEditor(tutorialMinecraftPreset()) {
                    NotificationCenter.default.post(
                        name: .inputConfigScrollToFirstBinding, object: "top")
                    if let firstID = tutorialMinecraftPreset()?
                        .joysticks.first?.bindings.first?.id {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                            NotificationCenter.default.post(
                                name: .inputConfigExpandBindingOptions,
                                object: firstID)
                        }
                    }
                    }
                }
            ),
            TutorialStep(
                icon: "plus.circle.fill",
                tint: .green,
                title: String(localized: "Several actions at once"),
                body: String(localized: "The small + on a row adds another action, so one press can do several things together."),
                action: { inTourEditor(tutorialMinecraftPreset()) {} }
            ),
            TutorialStep(
                icon: "circle.dashed",
                tint: .mint,
                title: String(localized: "Regions"),
                body: String(localized: "A region turns part of a control into its own button, like pushing the stick all the way forward to sprint. Watch the pointer select Minecraft's Sprint region."),
                action: {
                    inTourEditor(tutorialMinecraftPreset()) {
                    if let mc = tutorialMinecraftPreset(), !mc.joysticks.isEmpty {
                        let g = mc.joysticks.firstIndex { $0.inputKind == .controller } ?? 0
                        ShowZonesRequest(groupIndex: g, part: .stick(0)).post()
                        let at = TutorialState.shared.stepIndex
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            guard TutorialState.shared.isActive, TutorialState.shared.stepIndex == at else { return }
                            TutorialState.shared.simulateClickThen(at: SpotlightID.tourRegion) {
                                NotificationCenter.default.post(name: .inputConfigTourSelectRegion, object: 0)
                            }
                        }
                    }
                    }
                }
            ),
            TutorialStep(
                icon: "slider.horizontal.3",
                tint: .gray,
                title: String(localized: "Utilities"),
                body: String(localized: "Utilities can open the game when the preset starts, and keep the pointer away from the screen edges while it runs. We opened it for you."),
                action: {
                    inTourEditor(tutorialMinecraftPreset()) {
                    NotificationCenter.default.post(
                        name: .inputConfigScrollToAutomation, object: nil)
                    }
                }
            ),
            TutorialStep(
                icon: "tray.and.arrow.down.fill",
                tint: .blue,
                title: String(localized: "Save the preset"),
                body: String(localized: "On your own, Save keeps your changes. The tour closes the editor without saving."),
                action: {
                    // No pointer: the tour card sits over Save and Cancel.
                    let at = TutorialState.shared.stepIndex
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        guard TutorialState.shared.isActive, TutorialState.shared.stepIndex == at else { return }
                        withAnimation { closeTourEditor() }
                    }
                }
            ),
            TutorialStep(
                icon: "play.circle.fill",
                tint: .green,
                title: String(localized: "Play Minecraft"),
                body: String(localized: "Click Activate to start the preset, and it opens Minecraft for you. Click again to stop."),
                spotlight: SpotlightID.activateButton,
                action: {
                    NotificationCenter.default.post(
                        name: .inputConfigScrollToTop, object: nil)
                    let tourStepAt = TutorialState.shared.stepIndex
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        // Not once the person moved on: it took the next step's pointer.
                        guard TutorialState.shared.isActive, TutorialState.shared.stepIndex == tourStepAt else { return }
                        TutorialState.shared.simulateClickThen(
                            at: SpotlightID.activateButton
                        ) {
                            // No-op - user activates when they're ready
                            // to launch Minecraft.
                        }
                    }
                }
            ),

            // ─── Wrap-up ───────────────────────────────────────────

            TutorialStep(
                icon: "books.vertical.fill",
                tint: .orange,
                title: String(localized: "Examples to copy"),
                body: String(localized: "Back home. Every card here opens an example you can copy and make your own."),
                action: {
                    selectedPresetId = nil
                    closeTourEditor()
                    showingStats = false
                    settingsSheetTab = nil
                    tutorialFeatureSpotlight = nil
                }
            ),
            TutorialStep(
                icon: "checkmark.circle.fill",
                tint: .green,
                title: String(localized: "You're all set"),
                body: String(localized: "That's the tour! Start it again any time from the Quick Start Guide button or the Help menu."),
                action: {
                    selectedPresetId = nil
                    closeTourEditor()
                }
            )
        ]
    }

    /// Actually delete the queued preset. The store moves it to the
    /// on-disk trash where the sidebar's Trash section can restore it
    /// at any time.
    func performPendingDelete() {
        guard let preset = presetPendingDelete else { return }
        if selectedPresetId == preset.id {
            // The next preset in the same folder (else the one before), so
            // a keyboard user keeps their place instead of going Home.
            let list = presetStore.showFavoritesOnly && !presetStore.favoritePresets.isEmpty
                ? presetStore.favoritePresets : presetStore.presets(in: preset.groupID)
            let i = list.firstIndex { $0.id == preset.id }
            let neighbor = i.flatMap { i in i + 1 < list.count ? list[i + 1] : (i > 0 ? list[i - 1] : nil) }
            selectedPresetId = neighbor?.id
        }
        // Stop the mapping engine BEFORE removing the preset. Earlier
        // versions called deletePreset → deactivateAll, which only
        // cleared the active flag but left the engine polling the now-
        // deleted preset, firing ghost outputs until the user stopped
        // it manually.
        // The live copy: one started while the dialog was up kept running
        // after it was deleted.
        let current = presetStore.presets.first { $0.id == preset.id } ?? preset
        if current.isActive || presetStore.activePresetId == current.id {
            mappingEngine.stop()
        }
        presetStore.deletePreset(current)
        presetPendingDelete = nil
        AccessibilityNotification.Announcement(String(localized: "\(preset.shownName) moved to the Trash")).post()
    }

    func pauseZonePresetStartedBehindEditor(_ id: UUID?) {
        guard let editing = editingPreset?.id, let id, mappingEngine.isRunning,
              let running = mappingEngine.activePreset else { return }
        if id != editing, Self.readsRegions(running) {
            editorPausedRunning = true
            mappingEngine.editorOverride = false
            mappingEngine.outputsPaused = true
        } else if editorPausedRunning {
            // The edited preset, or one that reads no regions, started over a
            // pause the editor made for a zone preset: that pause is not its,
            // and its rows sent nothing until the editor closed.
            editorPausedRunning = false
            mappingEngine.editorOverride = !outputsPausedBeforeEdit
            mappingEngine.outputsPaused = outputsPausedBeforeEdit
        }
    }

    /// Whether a preset's rows read any zone or region the editor swaps out.
    static func readsRegions(_ p: Preset) -> Bool {
        p.joysticks.contains { $0.bindings.contains { b in
            [.touchpadRegion, .cursorRegion, .stickRegion, .screenPixel, .screenText, .voicePhrase].contains(b.input.type)
                || (b.input.gestureSteps ?? []).contains { $0.zone != nil }
        } }
    }

    /// The editor's Activate and Deactivate, by the same path as the preset
    /// page's button. Activate starts the editor's draft (a new preset's rows
    /// may not be saved yet) and runs it live, unpaused unless the menu bar
    /// paused it. Deactivate on a preset that moves the pointer arms the
    /// controller's restart hold, as an emergency stop does, so someone whose
    /// only pointer is that preset can start it again.
    func toggleEditedPreset(_ draft: Preset) {
        let stored = presetStore.presets.first(where: { $0.id == draft.id })
        if stored?.isActive == true, let stored {
            // togglePreset's stop arms the controller restart hold.
            togglePreset(stored)
            return
        }
        togglePreset(stored?.isRunnable == true ? stored! : draft)
        if mappingEngine.isRunning, presetStore.activePresetId == draft.id {
            editorPausedRunning = false
            mappingEngine.editorOverride = !outputsPausedBeforeEdit
            mappingEngine.outputsPaused = outputsPausedBeforeEdit
        }
    }

    func togglePreset(_ preset: Preset, fromShortcut: Bool = false) {
        if preset.isActive {
            // The one stop every entry point shares: it arms the controller
            // restart hold for a pointer preset, so someone who drives the
            // pointer with it is not left with a dead pointer.
            MenuBarController.deactivate(store: presetStore, engine: mappingEngine)
            return
        }
        // No empty-group check here: startEngine's isRunnable test is the
        // one every start path uses (a drive-only preset has no groups).
        // Gate: if this preset uses motion / touchpad bindings, ensure the
        // user has run the corresponding calibration. Missing calibration
        // makes the cursor / aim feel wrong on a brand-new controller.
        // The calibration gate is gone: the gyro zero learns itself while
        // the controller rests and pitch and roll are anchored to the
        // accelerometer, and a DualSense or DualShock touchpad read through
        // the GameController framework already spans the whole pad. The
        // alert it raised on every activation of a motion or touchpad preset
        // read as "the preset does not work". Calibration stays available in
        // each row's Options for the raw HID path and for people who want it.
        startEngine(with: preset, fromShortcut: fromShortcut)
    }

    private func startEngine(with preset: Preset, fromShortcut: Bool = false) {
        // An empty preset cannot do anything; activating it would show the
        // green active state over an engine with nothing to run.
        // Drive mode counts: a drive-only preset was refused here although
        // the engine runs it.
        guard preset.isRunnable else { return }
        guard presetStore.confirmFirstStart(preset, background: false),
              presetStore.confirmRestrictiveStart(preset, background: fromShortcut) else { return }
        mappingEngine.stop()
        presetStore.activatePreset(preset)
        mappingEngine.start(with: preset)
        // A preset that emits keyboard/mouse output needs Accessibility for
        // that output to reach other apps. If it isn't granted yet, prompt
        // the user the moment they activate such a preset.
        accessibility.refresh()
        // With the editor up the root alert's flag would sit set behind
        // the sheet and pop the alert when the editor closed, and the
        // editor has no Accessibility banner of its own: the menu bar
        // warning (log entry, orange icon) says so instead.
        if !accessibility.isTrusted, presetUsesKeyboardOrMouse(preset) {
            if canPresentSheet {
                showAccessibilityAlert = true
            } else {
                MenuBarController.warnIfAccessibilityMissing(for: preset, background: true)
            }
        }
    }

    /// True when the preset needs Accessibility; see `Preset.needsAccessibility`.
    /// This missed Type Text, system actions, macros, hold and double-tap
    /// outputs, and Mac keyboard and mouse inputs.
    private func presetUsesKeyboardOrMouse(_ preset: Preset) -> Bool {
        preset.needsAccessibility
    }

    /// The currently-active preset, if any.
    private var runningPreset: Preset? {
        presetStore.presets.first(where: { $0.isActive })
    }

    /// Reassuring, proactive Accessibility explainer shown on launch when the
    /// permission isn't granted. Spells out exactly what the app uses it for
    /// and that nothing leaves the Mac, so people can decide with the facts.
    @ViewBuilder
    var accessibilityIntroSheet: some View {
        VStack(spacing: 16) {
            Image(systemName: "accessibility")
                .font(.system(size: 46, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: 84, height: 84)
                .background(
                    Circle().fill(
                        LinearGradient(colors: [.blue, .indigo],
                                       startPoint: .top, endPoint: .bottom)
                    )
                )
                .padding(.top, 6)
                .accessibilityHidden(true)

            Text(accessibility.isTrusted ? String(localized: "Accessibility Is On") : String(localized: "Turn On Accessibility"))
                .font(.title2.weight(.bold))
                .accessibilityAddTraits(.isHeader)

            Text("InputConfig uses macOS Accessibility to send the keyboard and mouse actions your controller is mapped to, and to read your Mac's keyboard and mouse while a preset, Scan, or the Live Visualizer uses them as inputs. Everything stays on your Mac; nothing is recorded or sent anywhere.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if accessibility.isTrusted {
                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text("Granted. Every mapping can run.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("System Settings, Privacy & Security, Accessibility, then switch on InputConfig.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                if accessibility.isTrusted {
                    Button {
                        showingAccessibilityIntro = false
                    } label: {
                        Text("Done").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.solid)
                    .keyboardShortcut(.defaultAction)
                    .closesOnEscape { showingAccessibilityIntro = false }
                } else {
                    Button {
                        // requestAccess registers the app's row in the
                        // Accessibility pane and shows the system prompt.
                        // Only opening the pane landed users in a list with
                        // no InputConfig row to turn on. The sheet stays up
                        // and flips to Done the moment the switch is on.
                        accessibility.requestAccess()
                    } label: {
                        Text("Turn On Accessibility")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.solid)
                    .keyboardShortcut(.defaultAction)
                    .focusRingForKeyboardUsers()

                    // The two helpers for when the switch will not stick:
                    // reveal this copy of the app (wherever this build
                    // lives) to drag into the list, and re-read the state.
                    HStack(spacing: 8) {
                        Button {
                            accessibility.revealAppInFinder()
                        } label: {
                            Label("Show in Finder", systemImage: "folder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.solidSecondary)
                        .help("Reveals the app so you can drag it into the Accessibility list")
                        Button {
                            accessibility.refresh()
                            // The refresh speaks only a change; a recheck
                            // that finds it still off says so too.
                            if !accessibility.isTrusted {
                                AccessibilityNotification.Announcement(String(localized: "Accessibility access not granted")).post()
                            }
                        } label: {
                            Label("Recheck", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.solidSecondary)
                        .help("Re-read the permission after switching it on")
                    }

                    // Remembered: the sheet opened on every launch. The
                    // banner and the alert on activating a preset that
                    // needs the permission still ask when it matters.
                    Button("Maybe Later") {
                        suppressAccessibilityIntro = true
                        showingAccessibilityIntro = false
                    }
                    .keyboardShortcut(.cancelAction)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 2)

            if !accessibility.isTrusted {
                Text("If the switch does not stick, press Show in Finder and drag InputConfig from the Finder window into the Accessibility list in System Settings, then switch it on there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .padding(28)
        .frame(width: 430)
    }

    /// First launch only: what the app is for and who made it, before the
    /// permission ask.
    var welcomeIntroSheet: some View {
        VStack(spacing: 16) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)
                    .padding(.top, 4)
                    .accessibilityHidden(true)
            }

            Text("Welcome to InputConfig")
                .font(.title2.weight(.bold))
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 10) {
                Text("InputConfig exists to be a powerful accessibility tool, made for the people who need it most. The idea is simple: any input can become any output.")
                Text("It was built by somebody who needed it, and it is in active development. If you ever need anything, or if something does not work, please reach out on GitHub or through the website so that it can be fixed. Here for you! :)")
                HStack(spacing: 14) {
                    Button {
                        HelpGuideWindowController.shared.show()
                    } label: {
                        Label("Help", systemImage: "questionmark.circle")
                    }
                    Link(destination: URL(string: "https://github.com/ryleighnewman/InputConfig/issues")!) {
                        Label("GitHub", systemImage: "ladybug")
                    }
                    Link(destination: URL(string: "https://inputconfig.com/help/")!) {
                        Label("inputconfig.com", systemImage: "safari")
                    }
                }
                .font(.callout)
                .buttonStyle(.plain)
                .focusRingForKeyboardUsers()
                .foregroundStyle(Color.accentColor)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            Button {
                finishWelcome()
            } label: {
                Text("Let's Get Started").frame(maxWidth: .infinity)
            }
            .buttonStyle(.solid)
            .keyboardShortcut(.defaultAction)
            // Escape too, like the app's other one-button sheets.
            .closesOnEscape { finishWelcome() }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 430)
    }

    private func finishWelcome() {
        welcomeIntroSeen = true
        showingWelcomeIntro = false
        // Then the permission, if it is still needed.
        if !accessibility.isTrusted && !suppressAccessibilityIntro {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                // Not over a sheet opened meanwhile (Command N): the flag
                // stayed on and blocked every later sheet.
                guard !anotherSheetIsUp, editingPreset == nil, !accessibility.isTrusted else { return }
                showingAccessibilityIntro = true
            }
        }
    }

    /// Top-of-window banner shown while a keyboard/mouse preset is active but
    /// Accessibility hasn't been granted, so the user sees why their mappings
    /// aren't landing and can fix it in one click. Collapses to nothing
    /// otherwise (zero-height safe-area inset).
    /// A deep orange that white small text reads on (about 6 to 1).
    private static let bannerOrange = Color(red: 0.62, green: 0.30, blue: 0.0)

    @ViewBuilder
    var accessibilityBanner: some View {
        if !accessibility.isTrusted,
           let active = runningPreset, presetUsesKeyboardOrMouse(active) {
            HStack(spacing: 10) {
                Image(systemName: "accessibility")
                VStack(alignment: .leading, spacing: 1) {
                    Text("Accessibility access needed")
                        .font(.caption.weight(.semibold))
                    Text("Turn on InputConfig in Privacy & Security → Accessibility to send keyboard & mouse input.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.92))
                }
                Spacer(minLength: 8)
                Button("Open Settings") { accessibility.requestAccess() }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Self.bannerOrange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.white))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Self.bannerOrange)
        }
    }

    func exportPreset(_ preset: Preset) {
        // With the name, tag and notes still being typed (P2's drafts).
        let preset = committed(preset)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        // The name the sidebar shows; the file still carries the stored one.
        panel.nameFieldStringValue = "\(preset.shownName.withoutRTLMark).json"
        panel.message = String(localized: "Choose where to save the preset file")
        if panel.runModal() == .OK, let url = panel.url, !presetStore.exportPresetToFile(preset, to: url) {
            let alert = NSAlert()
            alert.messageText = String(localized: "Could not save the file there")
            alert.informativeText = String(localized: "Choose another folder, such as Documents or the Desktop.")
            alert.runModal()
        }
    }

    func showPresetInFinder(_ preset: Preset) {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let presetsDir = appSupport.appendingPathComponent("InputConfig/presets")
        let filePath = presetsDir.appendingPathComponent(preset.filename).path
        NSWorkspace.shared.selectFile(filePath, inFileViewerRootedAtPath: "")
    }

    func sharePreset(_ preset: Preset) {
        // A copy made for sharing, named after the preset: the library file
        // is named by its UUID and carries this Mac's state (running flag,
        // folder, order, auto-launch paths, apps that switch to it).
        var copy = preset.sanitizedForImport(removingOpeners: false).withoutDisplayPins()
        copy.groupID = nil
        var safeName = preset.name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A file name is at most 255 bytes: a long Thai or emoji name failed
        // to write and Share did nothing.
        while safeName.utf8.count > 200 { safeName.removeLast() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Share", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent((safeName.isEmpty ? "Preset" : safeName) + ".json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(copy).write(to: fileURL, options: .atomic)
        } catch {
            ActivityLog.shared.error("Presets", "Could not prepare \(preset.name) for sharing: \(error.localizedDescription)")
            return
        }

        let picker = NSSharingServicePicker(items: [fileURL])
        if let window = NSApp.keyWindow, let contentView = window.contentView {
            let frame = contentView.bounds
            let rect = NSRect(x: frame.midX, y: frame.midY, width: 1, height: 1)
            picker.show(relativeTo: rect, of: contentView, preferredEdge: .minY)
        }
    }
}
