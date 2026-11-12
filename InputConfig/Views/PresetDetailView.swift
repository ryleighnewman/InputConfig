import SwiftUI
import SceneKit
import Metal
import GameController
import UniformTypeIdentifiers

struct PresetDetailView: View {
    /// The window's binding to the stored preset, kept as its two closures
    /// rather than as a @Binding. SwiftUI refreshes a view that holds a
    /// Binding on a later update in the same transaction, and a switch has
    /// one (the header's text fields are made anew for each preset), so the
    /// whole page ran a second time for a value it already had. Nothing is
    /// lost: every read still goes through the binding's get, which reads
    /// the store, and a change in the store reaches the page because the
    /// window observes the store and builds the page again.
    private struct PresetAccess {
        let get: () -> Preset
        let set: (Preset) -> Void
    }
    private let access: PresetAccess
    private var preset: Preset {
        get { access.get() }
        nonmutating set { access.set(newValue) }
    }
    /// For the controls that take a binding (the light bar popover).
    private var presetBinding: SwiftUI.Binding<Preset> {
        SwiftUI.Binding(get: access.get, set: access.set)
    }
    let pageDrafts: PresetPageDrafts
    let onEdit: () -> Void
    let onToggle: () -> Void
    /// Asks ContentView to open the editor scrolled to a specific binding
    /// row. Forwarded down to VirtualControllerView, which fires this when
    /// the user taps a row inside any widget popover.
    var onJumpToBinding: (EditorJumpTarget) -> Void = { _ in }

    init(preset: SwiftUI.Binding<Preset>, pageDrafts: PresetPageDrafts,
         onEdit: @escaping () -> Void, onToggle: @escaping () -> Void,
         onJumpToBinding: @escaping (EditorJumpTarget) -> Void = { _ in }) {
        access = PresetAccess(get: { preset.wrappedValue }, set: { preset.wrappedValue = $0 })
        self.pageDrafts = pageDrafts
        self.onEdit = onEdit
        self.onToggle = onToggle
        self.onJumpToBinding = onJumpToBinding
    }

    /// The visualizer's Connected pick: the group reads that controller,
    /// as when it is picked from the editor's device menu.
    private func setGroupDevice(_ name: String?, slot: Int) {
        while preset.joysticks.count <= slot { preset.joysticks.append(JoystickMapping(tag: "")) }
        preset.joysticks[slot].customName = name
        preset.joysticks[slot].inputKind = name == nil ? .auto : .controller
    }

    /// The visualizer's Controller menu: the group's model, and the button
    /// names to match when this preset is for that one controller.
    private func setControllerModel(_ model: ControllerModelID?, slot: Int) {
        // One change, saved once. A panel for a connected pad past the
        // preset's groups gets its group, as the template picker does.
        var updated = preset
        while updated.joysticks.count <= slot { updated.joysticks.append(JoystickMapping(tag: "")) }
        let previous = updated.joysticks[slot].controllerModel
        // Already Automatic: nothing to undo (a family the Smart Preset
        // Maker or a conversion set stays).
        if model == nil, previous == nil { return }
        updated.joysticks[slot].controllerModel = model?.rawValue
        func family(of raw: String?) -> FaceLetters? {
            raw.flatMap { ControllerLayoutCatalog.layout(ControllerModelID(rawValue: $0)) }?.family
        }
        let controllerGroups = updated.joysticks.filter { $0.inputKind == .auto || $0.inputKind == .controller }.count
        let others = updated.joysticks.indices.filter { $0 != slot }.compactMap { family(of: updated.joysticks[$0].controllerModel) }
        // The first model chosen in the preset: remember the family it
        // replaces (a Smart Preset's, a conversion's, or none).
        if model != nil, previous == nil, others.isEmpty, updated.familyBeforeModel == nil {
            updated.familyBeforeModel = updated.buttonFamily?.rawValue ?? ""
        }
        if let model, let layout = ControllerLayoutCatalog.layout(model) {
            // Names follow the choice unless another group's names were set
            // some other way: a family set by this group's earlier choice
            // may change.
            if updated.buttonFamily == nil || updated.buttonFamily == .automatic || controllerGroups <= 1
                || updated.buttonFamily == family(of: previous) {
                updated.buttonFamily = layout.family
            }
        } else if updated.buttonFamily == family(of: previous) {
            // Automatic undoes what the earlier choice set, and only that
            // (a family the Smart Preset Maker set stays): another group's
            // model, else the shipped family for a built-in, else none
            // (names by the connected pad).
            if let other = others.first {
                updated.buttonFamily = other
            } else {
                // The family from before the first choice, else the shipped
                // one for a built-in, else none.
                let before = updated.familyBeforeModel
                updated.buttonFamily = before.map { $0.isEmpty ? nil : FaceLetters(rawValue: $0) }
                    ?? ExamplePresets.buttonFamilies[updated.name]
                if updated.buttonFamily == .automatic { updated.buttonFamily = nil }
            }
        }
        if model == nil, others.isEmpty { updated.familyBeforeModel = nil }
        // A group this menu added past the preset's own, still empty, goes
        // again, so the built-in is not changed by looking.
        if model == nil, slot > 0, slot == updated.joysticks.count - 1 {
            // Every empty group it added on the way, not only the last.
            while updated.joysticks.count > 1, let g = updated.joysticks.last, g.bindings.isEmpty,
                  g.customName == nil, g.inputKind == .auto, g.controllerModel == nil, g.tag.isEmpty {
                updated.joysticks.removeLast()
            }
        }
        preset = updated
    }

    // PresetDetailView does not read the mapping engine directly (the
    // visualizer it embeds gets the engine from a higher injection), so it
    // must NOT subscribe to it here: doing so rebuilt this whole detail body
    // at the engine's 10-30 Hz publish rate while a preset was active.
    @EnvironmentObject var controllerService: GameControllerService
    @EnvironmentObject var presetStore: PresetStore

    var body: some View {
        #if DEBUG
        let _ = BodyRuns.note("PresetDetailView")
        let _ = BodyRuns.printChangesIfAsked() ? Self._printChanges() : ()
        #endif
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { detailProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Anchor for the Quick Tour's scroll-to-top.
                    Color.clear.frame(height: 0).id("detail-top")
                        .background(ScrollAnchorProbe(box: detailTop))

                    // 1. Header (name, tag, Activate, Edit).
                    headerSection
                        .padding(.horizontal)
                        .padding(.top, 8)
                        .pageProbeCard("header")

                    // The D-pad's one-direction switch, when the preset binds
                    // D-pad actions. Pointer and scroll speed moved to the
                    // editor's Utilities in 1.10.
                    if presetBindsDpadActions {
                        speedRow
                            .padding(.horizontal)
                            .pageProbeCard("speed")
                    }

                    // A new preset has one empty group, so "no groups" never
                    // happened; the empty state goes up here, under the
                    // header, where it is seen first.
                    // A plain stack: ContentUnavailableView pads itself for a
                    // whole pane and left a tall gap above the visualizer.
                    if !preset.hasMappings {
                        VStack(spacing: 6) {
                            ControllerGlyph(height: 22)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text("No Input Mappings")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            Text("Edit this preset to add joystick mappings.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .accessibilityElement(children: .combine)
                    }

                    // 2. Live Visualizer card.
                    // Tagged so the tour can scrollTo("visualizer-section")
                    // without having to fish through nested SwiftUI views.
                    Color.clear.frame(height: 0).id("visualizer-section")
                    visualizerCard
                        .padding(.horizontal)
                        .spotlightAnchor(SpotlightID.visualizer)
                        .pageProbeCard("visualizer")

                    // 3. Joystick Slots card (mapping count + comment per
                    //    joystick group in the preset).
                    if preset.hasMappings {
                        joystickSlotsCard
                            .padding(.horizontal)
                            .pageProbeCard("slots")
                    }

                    // 4. Notes card. Personal context (which game, gotchas)
                    //    belongs right after the mappings, before the
                    //    technical file metadata below.
                    notesCard
                        .padding(.horizontal)
                        .spotlightAnchor(SpotlightID.notesSection)
                        .id("notes-section")
                        .pageProbeCard("notes")

                    // 5. Details card (Usage, Inputs, Outputs, Controllers,
                    //    Storage, version history).
                    detailsCard
                        .padding(.horizontal)
                        .pageProbeCard("details")
                }
                .padding(.vertical, 14)
            }
            // Each preset opens at the top, as a new page did. Not when it
            // is there already: the call cost a deferred scroll commit on
            // every switch, and moved nothing.
            .onChange(of: preset.id) { _, _ in
                if !detailTop.isScrolledTo { detailProxy.scrollTo("detail-top", anchor: .top) }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: .inputConfigScrollToVisualizer)) { _ in
                showVisualizer = true
                withAnimation(.easeOut(duration: 0.45)) {
                    detailProxy.scrollTo("visualizer-section", anchor: .top)
                }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: .inputConfigScrollToTop)) { _ in
                withAnimation(.easeOut(duration: 0.45)) {
                    detailProxy.scrollTo("detail-top", anchor: .top)
                }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: .inputConfigScrollToNotes)) { _ in
                withAnimation(.easeOut(duration: 0.45)) {
                    detailProxy.scrollTo("notes-section", anchor: .center)
                }
            }
            } // ScrollViewReader

        }
        .navigationTitle(shownName)
    }

    // MARK: - Section card helpers

    /// Wraps a section in a uniform Liquid Glass card. Used by every major
    /// section of the detail panel so they read as one related set and carry
    /// the same real glass as the rest of the app family (spec section 2).
    @ViewBuilder
    private func sectionCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            content()
        }
        .padding(Metrics.cardPad)
        .liquidGlass(in: RoundedRectangle(cornerRadius: Metrics.sectionRadius, style: .continuous))
    }

    /// Standard header row for a section card: tinted SF Symbol, title,
    /// optional trailing content (e.g. a chevron or status pill).
    @ViewBuilder
    private func sectionHeader<Trailing: View>(
        icon: String,
        title: LocalizedStringKey,
        tint: Color = .secondary,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        HStack(spacing: 6) {
            IconView(name: icon, glyphHeight: 12)
                .iconTint(tint)
                .font(.subheadline)
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            trailing()
        }
    }

    // MARK: - Section: Header

    @ViewBuilder
    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                // Keyed to the preset: one field reused across a switch
                // morphed from the old name to the new one, a downward
                // distortion at this size. The page itself stays alive.
                TextField("Preset Name", text: .shipped(headerBinding(\.name, \.name)))
                    .id("\(preset.id)-\(revertGeneration)")
                    .onSubmit { commitHeader() }
                    .font(.title2)
                    .fontWeight(.regular)
                    .textFieldStyle(.plain)
                    .lineLimit(1)
                TextField("Tag / Description", text: .shipped(headerBinding(\.tag, \.tag)))
                    .id("\(preset.id)-\(revertGeneration)")
                    .onSubmit { commitHeader() }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textFieldStyle(.plain)
                    .lineLimit(1)
                // A feature added to this built-in since: said here, added
                // in the editor, where Undo can take it back.
                if let update = BuiltInUpdate.offers(for: preset).first {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(String(localized: "Update for this built-in preset: \(update.title)"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Review in the Editor", action: onEdit)
                            .buttonStyle(.solidSecondaryCompact)
                            .controlSize(.small)
                    }
                    .padding(.top, 4)
                }
            }
            // A typed name or tag reaches the preset half a second after the
            // last keystroke, on Return, or at once when the page goes: each
            // character used to save the preset, which re-rendered the window.
            // Going, the page also leaves the box empty.
            .onDisappear { commitHeader(); pageDrafts.commit = {} }
            .onReceive(NotificationCenter.default.publisher(for: .inputConfigCommitDrafts)) { _ in commitHeader() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in commitHeader() }
            .onAppear { pageDrafts.commit = { commitHeader(); commitNotes() } }
            // Set again on a switch, so the notes it commits are this preset's.
            .onChange(of: preset.id) { pageDrafts.commit = { commitHeader(); commitNotes() } }
            Spacer()
            // Activate and Edit, with the Emergency Stop under them at the
            // width of the pair.
            FirstWidthStack(spacing: 6) {
                HStack(spacing: 8) {
                    Button(action: onToggle) {
                        Label {
                            Text(preset.isActive ? String(localized: "Deactivate") : String(localized: "Activate"))
                        } icon: {
                            // A filled triangle carries far more ink than the
                            // pencil beside it at the same point size, so it read
                            // as a bigger, heavier icon. Drawn a step smaller so
                            // the two buttons match.
                            Image(systemName: preset.isActive ? "stop.fill" : "play.fill")
                                .imageScale(.small)
                        }
                    }
                    .buttonStyle(SolidButton(tint: preset.isActive ? .red : .green))
                    // Nothing to run yet: say so rather than doing nothing on click.
                    .disabled(!preset.isActive && !preset.isRunnable)
                    .help(!preset.isActive && !preset.isRunnable ? String(localized: "Add a row in the editor first") : "")
                    .spotlightAnchor(SpotlightID.activateButton)
                    .accessibilityLabel(preset.isActive
                                        ? String(localized: "Deactivate \(shownName)")
                                        : String(localized: "Activate \(shownName)"))
                    .accessibilityHint(preset.isActive
                                       ? String(localized: "Stops the mapping engine for this preset")
                                       : String(localized: "Starts the mapping engine and applies this preset"))
                    // Voice Control: the word on the button first.
                    .accessibilityInputLabels(preset.isActive
                                              ? [Text("Deactivate"), Text("Deactivate \(shownName)")]
                                              : [Text("Activate"), Text("Activate \(shownName)")])

                    Button(action: onEdit) {
                        Label("Edit", systemImage: "pencil")
                    }
                    .buttonStyle(.solidSecondary)
                    .spotlightAnchor(SpotlightID.editButton)
                    .accessibilityLabel("Edit bindings and mappings")
                    .accessibilityHint("Opens the binding editor for this preset")
                    .accessibilityInputLabels([Text("Edit"), Text("Edit bindings and mappings")])
                }
                // Equatable: it has nothing from the page to show, and its
                // stored settings made every page body run it again.
                EmergencyStopHeaderButton(presetStore: presetStore, padNames: EmergencyStopHeaderButton.padNamesKey())
                    .equatable()
            }
        }
        .spotlightAnchor(SpotlightID.detailHeader)
    }

    /// Stacks its views top to bottom, each as wide as the first one at its
    /// natural width, so the Emergency Stop spans Activate and Edit exactly
    /// and a long label of its own truncates rather than widening the pair.
    private struct FirstWidthStack: Layout {
        var spacing: CGFloat = 6

        private func width(for proposal: ProposedViewSize, subviews: Subviews) -> CGFloat {
            guard let first = subviews.first else { return 0 }
            let natural = first.sizeThatFits(.unspecified).width
            return min(natural, proposal.width ?? natural)
        }

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let w = width(for: proposal, subviews: subviews)
            let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: w, height: nil)).height }
            return CGSize(width: w, height: heights.reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1)))
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let column = ProposedViewSize(width: bounds.width, height: nil)
            var y = bounds.minY
            for subview in subviews {
                subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: column)
                y += subview.sizeThatFits(column).height + spacing
            }
        }
    }

    /// The Emergency Stop under Activate and Edit: every way to stop right
    /// now, and a click opens the same controls as Settings, General,
    /// Emergency stop in a popover.
    struct EmergencyStopHeaderButton: View, Equatable {
        /// Handed on to the popover, never read: observed, every library
        /// change re-ran this button.
        let presetStore: PresetStore

        /// The only input is the store, which is one for the app. What the
        /// label shows comes from its own stored settings and the keyboard
        /// layout, which redraw it themselves; the page re-running (a
        /// switch, a save) does not.
        /// The pads' names for the hold buttons ("Back" or "Create") and
        /// the Access controller note, worked out by the page, which follows
        /// the pads: the label reads them through the service, which is not
        /// observed, so without it a pad connecting left the label's names
        /// stale.
        var padNames: String = ""

        nonisolated static func == (a: Self, b: Self) -> Bool {
            a.presetStore === b.presetStore && a.padNames == b.padNames
        }
        static func padNamesKey() -> String {
            EmergencyStopService.holdButtonName(EmergencyStopService.defaultControllerButton, short: true) + "|"
                + EmergencyStopService.holdButtonName(EmergencyStopService.startButton, short: true) + "|"
                + EmergencyStopService.shared.accessControllerHoldNote
        }
        /// VoiceOver on adds "press Control Option Tab first" to the chord.
        @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverOn
        /// The chord's key is named by the keyboard layout, so a new input
        /// source redraws it.
        @ObservedObject private var keyboardLayout = KeyboardLayoutService.shared

        // The service is not observable, so the label watches the stored
        // settings it reads; a change here, in Settings, or from a restored
        // backup redraws it.
        @AppStorage(EmergencyStopService.enabledKey) private var keyboardOn = true
        @AppStorage(EmergencyStopService.keyCodeKey) private var keyCode = Int(EmergencyStopService.defaultSpec.keyCode)
        @AppStorage(EmergencyStopService.modifiersKey) private var modifiers = Int(EmergencyStopService.defaultSpec.modifiers)
        @AppStorage(EmergencyStopService.controllerKey) private var holdOn = true
        @AppStorage(EmergencyStopService.controllerBtnKey) private var holdButton =
            EmergencyStopService.defaultControllerButton
        @AppStorage(EmergencyStopService.holdSecondsKey) private var holdSeconds =
            EmergencyStopService.defaultHoldSeconds
        @AppStorage(EmergencyStopService.withStartKey) private var withStart = true

        @State private var showingPopover = false
        /// The popover's share of what Settings keeps for the section.
        @State private var specRevision = 0
        @State private var chordRefusal: String?

        /// The chord as the service has it, which names the period key by
        /// this keyboard's layout. The stored code and modifiers are read so
        /// a new chord redraws the label.
        private var chord: HotKeySpec {
            _ = (keyCode, modifiers)
            return EmergencyStopService.shared.spec
        }

        /// A button's everyday name: "Back" from "Back / Share / Select".
        private func shortName(_ index: Int) -> String {
            EmergencyStopService.holdButtonName(index, short: true)
        }

        private var holdNames: [String] {
            let needsStart = withStart && holdButton == EmergencyStopService.defaultControllerButton
            return needsStart ? [shortName(holdButton), shortName(EmergencyStopService.startButton)] : [shortName(holdButton)]
        }

        private var seconds: Double { holdSeconds > 0 ? holdSeconds : EmergencyStopService.defaultHoldSeconds }
        private var secondsText: String {
            seconds.formatted(.number.precision(.fractionLength(0...1)))
        }

        /// "Control Option Command period", for VoiceOver: the modifier
        /// glyphs the chord is shown with, read as words.
        private var spokenChord: String {
            _ = voiceOverOn
            return chord.spokenString + EmergencyStopService.shared.voiceOverChordNote
        }

        private var spokenLabel: String {
            let names = holdNames.count == 2
                ? String(localized: "\(holdNames[0]) and \(holdNames[1])")
                : (holdNames.first ?? "")
            let hold = (seconds == 1
                ? String(localized: "hold \(names) for \(secondsText) second")
                : String(localized: "hold \(names) for \(secondsText) seconds"))
                + EmergencyStopService.shared.accessControllerHoldNote
            switch (keyboardOn, holdOn) {
            case (true, true): return String(localized: "Emergency stop: \(spokenChord), or \(hold)")
            case (true, false): return String(localized: "Emergency stop: \(spokenChord)")
            case (false, true): return String(localized: "Emergency stop: keyboard shortcut off, \(hold)")
            case (false, false): return String(localized: "Emergency stop: keyboard shortcut and controller hold off")
            }
        }

        /// The label: the name, then the chord (or that it is off) in the
        /// secondary color. The controller hold is in the help and the
        /// popover, so the button stays short. One Text, so it can scale
        /// down a little and truncate as a whole.
        private func line() -> Text {
            var label = AttributedString(String(localized: "Emergency Stop"))
            var detail = AttributedString("  " + (keyboardOn ? chord.displayString : String(localized: "Keyboard off")))
            detail.foregroundColor = .secondary
            label.append(detail)
            return Text(label)
        }

        var body: some View {
            #if DEBUG
            let _ = BodyRuns.note("EmergencyStopHeaderButton")
            #endif
            Button {
                showingPopover = true
            } label: {
                // The name and the chord; narrower, it shrinks a little,
                // then gives up its middle so the chord stays in view.
                line()
                    .minimumScaleFactor(0.85)
                    .truncationMode(.middle)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.solidSecondaryCompact)
            // A slightly darker fill than the other gray buttons, so the stop
            // stands apart.
            .background(Capsule().fill(Color.black.opacity(0.14)))
            .help("\(spokenLabel). Click to change it.")
            .accessibilityLabel(spokenLabel)
            .accessibilityInputLabels([Text("Emergency Stop")])
            .accessibilityHint("Opens the emergency stop settings")
            .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Emergency stop")
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        // "Click Emergency Stop" opens this popover, so the
                        // stop itself is one step away, first in it.
                        Button("Stop Now", role: .destructive) {
                            showingPopover = false
                            EmergencyStopService.shared.stop(reason: .menu)
                        }
                        .buttonStyle(SolidButton(tint: .red, prominent: true, size: .compact))
                        .voiceNames("Stop Now", "Emergency Stop")
                    }
                    EmergencyStopSettingsContent(specRevision: $specRevision,
                                                 chordRefusal: $chordRefusal)
                        .environmentObject(presetStore)
                }
                .padding(16)
                .frame(width: 520, alignment: .leading)
            }
            // A refusal belongs to the visit it came from, as when the
            // Settings sheet closes.
            .onChange(of: showingPopover) { _, open in
                if !open { chordRefusal = nil }
            }
        }
    }

    // MARK: - Speed row

    /// Values shown while a speed slider moves. They are saved to the preset
    /// (which restarts it when it is running) once the slider has been still
    /// for a moment or is let go, not on every step of a drag.
    @State private var pointerSpeedDraft: Double?
    @State private var scrollSpeedDraft: Double?
    @State private var pointerSpeedCommit: Task<Void, Never>?
    @State private var scrollSpeedCommit: Task<Void, Never>?
    /// What each speed slider does, refreshed on every page body (see
    /// SpeedSlider), and each number field's key (see SpeedFieldKey).
    @State private var pointerSliderActions = SpeedSliderActions()
    @State private var scrollSliderActions = SpeedSliderActions()
    @State private var pointerFieldKey = SpeedFieldKey()
    @State private var scrollFieldKey = SpeedFieldKey()

    private func presetUses(_ type: OutputType) -> Bool {
        preset.joysticks.contains { group in
            group.bindings.contains { binding in binding.outputs.contains { $0.type == type } }
        }
    }

    /// The D-pad carries something other than pointer motion (keys, a
    /// shortcut, a system function), which is where one direction at a time
    /// matters.
    private var presetBindsDpadActions: Bool {
        preset.joysticks.contains { group in
            group.bindings.contains { b in
                b.input.type == .hat && b.outputs.contains { $0.type != .mouseMotion && $0.type != .mouseWheel }
            }
        }
    }

    private var speedRow: some View {
        // Pointer speed and Scroll speed live in the editor's Utilities
        // One place to set them, felt at once. What
        // is left here is the D-pad's one-direction switch.
        VStack(alignment: .leading, spacing: 8) {
            if presetBindsDpadActions {
                Toggle(isOn: SwiftUI.Binding(
                    get: { preset.automation.dpadOneDirection == true },
                    set: { preset.automation.dpadOneDirection = $0 ? true : nil }
                )) {
                    Text("D-pad one direction at a time")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.checkbox)
                .help("The direction pressed first keeps the D-pad until you let go, so a quick press that brushes the next direction does not fire that row too.")
                .accessibilityHint("The direction pressed first keeps the D-pad until you let go")
            }
        }
    }

    private func speedSlider(_ title: LocalizedStringKey, value: Double,
                             draft: SwiftUI.Binding<Double?>,
                             commitTask: SwiftUI.Binding<Task<Void, Never>?>,
                             actions: SpeedSliderActions,
                             field: SpeedFieldKey,
                             help: LocalizedStringKey,
                             commit: @escaping (Double) -> Void) -> some View {
        let shown = draft.wrappedValue ?? value
        func save(_ v: Double) {
            commitTask.wrappedValue?.cancel()
            commitTask.wrappedValue = nil
            commit(v)
            draft.wrappedValue = nil
        }
        // Refreshed on every page body, so the slider, which skips a body
        // run that changes nothing it draws, always acts on this preset.
        let presetID = preset.id
        actions.presetID = presetID
        actions.set = { newValue in
            draft.wrappedValue = newValue
            commitTask.wrappedValue?.cancel()
            commitTask.wrappedValue = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                save(newValue)
            }
        }
        actions.ended = { if let v = draft.wrappedValue { save(v) } }
        return HStack(spacing: 8) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            SpeedSlider(title: title, shown: shown, actions: actions)
                .equatable()
            // Typed straight in as well. Made anew on a switch only while it
            // has focus (what it holds then is typing for the preset left
            // behind, which it commits as it goes); otherwise it is the same
            // as a new one and stays.
            NumberEntryField(label: Text(title), value: SwiftUI.Binding(get: { value }, set: { save($0) }),
                             live: draft.wrappedValue, range: 0.1...5.0, fractionDigits: 2, prefix: "\u{00D7}",
                             focusReport: field.focus)
                .fixedSize()
                .id(field.key(for: presetID))
        }
        .help(help)
    }

    // MARK: - Section: Live Visualizer card

    @ViewBuilder
    private var visualizerCard: some View {
        let slots = visualizerSlots
        sectionCard {
            // One row: title, the device chip when there is a single
            // visualizer, then its Edit Layout and zoom, then the chevron.
            // With several visualizers each gets its own chip row below.
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showVisualizer.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        IconView(name: "gamecontroller", glyphHeight: 12)
                            .iconTint(.teal)
                            .font(.subheadline)
                        Text("Live Visualizer")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showVisualizer
                                    ? String(localized: "Collapse Live Visualizer")
                                    : String(localized: "Expand Live Visualizer"))
                .accessibilityInputLabels([Text("Live Visualizer")])
                .accessibilityAddTraits(.isHeader)

                if slots.count == 1, let only = slots.first {
                    visualizerDeviceChip(only)
                }
                Spacer(minLength: 4)
                if showVisualizer, slots.count == 1, let only = slots.first {
                    VisualizerHeaderControls(control: visualizerControl(for: only.slot))
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showVisualizer.toggle() }
                } label: {
                    Image(systemName: showVisualizer ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            }

            if showVisualizer {
                visualizerContent
            }
        }
    }

    /// True when the slot's template is the screen, chosen or inferred:
    /// every row is a screen region.
    private func slotShowsScreen(_ slot: Int) -> Bool {
        guard slot < preset.joysticks.count else { return false }
        let group = preset.joysticks[slot]
        if group.inputKind == .screen { return true }
        guard group.inputKind == .auto || group.inputKind == .touchpad, !group.bindings.isEmpty else { return false }
        return group.bindings.allSatisfy { $0.input.type == .cursorRegion }
    }

    /// The Mac input a slot's group reads, when it is not a controller.
    private func macInput(forSlot slot: Int) -> (name: String, symbol: String)? {
        if slotShowsScreen(slot) { return (String(localized: "Screen"), "display") }
        guard slot < preset.joysticks.count, let name = preset.joysticks[slot].macInputName else { return nil }
        return (name, preset.joysticks[slot].macInputSymbol)
    }

    /// "Input Device n", the controller's name, and its connection dot.
    private func visualizerDeviceChip(_ viz: VisualizerSlot) -> some View {
        HStack(spacing: 6) {
            Text("Input Device \(viz.idx)")
                .font(.caption2.weight(.semibold).monospaced())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
            if let mac = macInput(forSlot: viz.slot) {
                // The slot's input is the Mac (keyboard, mouse, a display,
                // MIDI), not a controller: naming the pad that happens to be
                // plugged in, with a connection dot, said the rows belonged
                // to it.
                Label(mac.name, systemImage: mac.symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // The device the panel draws: the group's own when it reads
                // another slot.
                let drawn = viz.slot < preset.joysticks.count
                    ? (controllerService.effectiveSlots(for: preset.joysticks)[viz.slot] ?? viz.slot) : viz.slot
                let connected = controllerService.controllerDetails[drawn] != nil
                if let waiting = controllerService.waitingDeviceName(forGroup: viz.slot, in: preset.joysticks) {
                    // Pinned to a pad that is away while another is here:
                    // the preset reads nothing from this group until then.
                    Text("Waiting for \(waiting)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                    Button("Use the connected controller") {
                        if let name = controllerService.standInPadName(forGroup: viz.slot, in: preset.joysticks) {
                            setGroupDevice(name, slot: viz.slot)
                        } else {
                            GameControllerService.sayEveryPadInUse()
                        }
                    }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help("Sets this input device to the controller connected now")
                } else {
                    Text(connected ? controllerService.controllerName(at: drawn) : String(localized: "No controller"))
                        .font(.caption)
                        .foregroundStyle(connected ? AnyShapeStyle(.secondary) : AnyShapeStyle(.hint))
                        .lineLimit(1)
                    Circle()
                        .fill(connected ? Color.green : Color.red.opacity(0.7))
                        .frame(width: 7, height: 7)
                        .accessibilityLabel(connected ? String(localized: "Connected") : String(localized: "Disconnected"))
                    if connected {
                        // The device's input on or off, kept for that device.
                        let ignored = controllerService.isIgnored(slot: drawn)
                        Toggle("Read this controller", isOn: Binding(
                            get: { !controllerService.isIgnored(slot: drawn) },
                            set: { controllerService.setIgnored(!$0, slot: drawn) }))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                            .help(ignored ? String(localized: "Off: this controller reads as idle everywhere. Switch on to read it again")
                                          : String(localized: "Switch off to ignore this controller everywhere (for a controller counted twice, or one to leave out)"))
                        if ignored {
                            Text("Ignored")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
    }

    /// One control state per visualizer slot, kept for the life of the
    /// detail view so Edit Layout and the zoom survive re-renders.
    private func visualizerControl(for slot: Int) -> VisualizerControlState {
        if let existing = visualizerControls.states[slot] { return existing }
        let fresh = VisualizerControlState()
        visualizerControls.states[slot] = fresh
        return fresh
    }

    /// Which visualizers the page shows: one per connected controller or
    /// per joystick group, whichever is more.
    private var visualizerSlots: [VisualizerSlot] {
        // Every slot either a controller or a preset group is in, once each.
        // Pairing the n-th connected slot with the n-th visualizer showed
        // slot 1 twice and hid group 0 when only slot 1 had a controller.
        let connected = Set(controllerService.controllerDetails.keys)
        // A connected slot a group already draws (pinned to it, or sent to
        // it for motion) gets no second panel of its own.
        let effective = controllerService.effectiveSlots(for: preset.joysticks)
        let drawnByGroups = Set(preset.joysticks.indices.map { effective[$0] ?? $0 })
        let slots = connected.filter { $0 < preset.joysticks.count || !drawnByGroups.contains($0) }
            .union(0..<preset.joysticks.count).sorted()
        return slots.enumerated().map { idx, slot in
            VisualizerSlot(id: connected.contains(slot) ? "slot-\(slot)" : "empty-\(slot)", idx: idx, slot: slot)
        }
    }

    /// The visualizer body extracted so it can be embedded directly in a
    /// section card (with our own collapse chevron) instead of a
    /// Stable identity for each visualizer row so a VirtualControllerView's
    /// @State (gyro integrator, etc.) tracks its controller, not its position.
    /// Keying the ForEach by array index let that state bleed onto a different
    /// controller when one connected or disconnected and shifted the slots.
    private struct VisualizerSlot: Identifiable {
        let id: String
        let idx: Int
        let slot: Int
    }

    /// DisclosureGroup whose chevron sat awkwardly next to the card.
    @ViewBuilder
    private var visualizerContent: some View {
        let connectedSlots = Array(controllerService.controllerDetails.keys).sorted()
        let presetJoystickCount = preset.joysticks.count
        let resolvedVisualizerSlots = visualizerSlots
        let presetUsesMIDI = preset.joysticks.contains { group in
            group.bindings.contains { $0.input.type == .midi }
        }
        if connectedSlots.isEmpty && presetJoystickCount == 0 && !presetUsesMIDI {
            Text("Connect a controller to see its live state here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(resolvedVisualizerSlots) { viz in
                    let slot = viz.slot
                    // With one visualizer the chip and controls sit on the
                    // card's title row; with several, each gets its own.
                    if resolvedVisualizerSlots.count > 1 {
                        HStack(spacing: 8) {
                            visualizerDeviceChip(viz)
                            Spacer()
                            VisualizerHeaderControls(control: visualizerControl(for: slot))
                        }
                    }
                    VirtualControllerView(
                        preset: preset,
                        onJump: { target in
                            onJumpToBinding(target)
                        },
                        fixedSlot: slot,
                        // The light bar picker opens from the strip on the
                        // controller drawing, the same grid as the controller
                        // popover, and pushes the color to the controller
                        // live while this preset is the active one.
                        trailing: {
                            PresetLightBarPopover(
                                color: presetBinding.lightBarColor,
                                brightness: presetBinding.lightBarBrightness,
                                rainbow: presetBinding.lightBarRainbow,
                                rainbowSpeed: presetBinding.lightBarRainbowSpeed,
                                onChanged: pushPresetLightBarLive)
                        },
                        lightBarTint: presetLightBarSwiftUIColor,
                        lightBarRainbow: preset.lightBarRainbow == true,
                        lightBarOff: presetLightBarIsOff,
                        onChangeInputKind: { changedSlot, newKind in
                            updateSlotInputKind(
                                presetID: preset.id,
                                slot: changedSlot,
                                kind: newKind)
                        },
                        onChangeButtonFamily: { preset.buttonFamily = $0 },
                        onChangeControllerModel: { slot, model in
                            setControllerModel(model, slot: slot)
                        },
                        onChangeDevice: { slot, name in
                            setGroupDevice(name, slot: slot)
                        },
                        onChangeTriggerFeel: { left, level in setPresetTriggerFeel(left: left, level: level) },
                        control: visualizerControl(for: slot)
                    )
                    .environmentObject(controllerService)
                }

            }
        }
    }

    // MARK: - Section: Joystick Slots card

    /// Compact summary of every joystick mapping in the preset, grouped
    /// into a single card instead of the loose stack of mini cards we
    /// used to render under the visualizer.
    @ViewBuilder
    private var joystickSlotsCard: some View {
        sectionCard {
            sectionHeader(icon: "rectangle.stack.fill",
                          title: "Joystick Slots",
                          tint: .indigo) {
                Text(preset.joysticks.count == 1 ? String(localized: "1 slot") : String(localized: "\(preset.joysticks.count) slots"))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.hint)
            }

            VStack(spacing: 6) {
                ForEach(Array(preset.joysticks.enumerated()), id: \.element.id) { index, joystick in
                    joystickSlotRow(index: index, joystick: joystick)
                }
            }
        }
    }

    @ViewBuilder
    private func joystickSlotRow(index: Int, joystick: JoystickMapping) -> some View {
        let bindingCount = joystick.bindings.count
        let hasComment = !joystick.tag.isEmpty && joystick.tag != "<write comments here>"

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(resolvedJoystickName(joystick: joystick, slot: index))
                    .font(.subheadline)
                if joystick.customName == nil, joystick.macInputName == nil {
                    Text("#\(index)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.hint)
                }
                Spacer()
                Text(bindingCount == 1 ? String(localized: "1 binding") : String(localized: "\(bindingCount) bindings"))
                    .font(.caption)
                    .foregroundStyle(.hint)
            }
            if hasComment {
                Text(ShippedText.t(joystick.tag))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    // MARK: - Section: Details card

    @ViewBuilder
    private var detailsCard: some View {
        sectionCard {
            sectionHeader(icon: "info.circle.fill",
                          title: "Details",
                          tint: .blue)
            detailsSection
        }
    }

    // MARK: - Section: Notes card

    /// Notes section card. The internal `presetNotesSection` still
    /// renders the icon, label, and TextEditor; the surrounding
    /// sectionCard provides the consistent frame.
    @ViewBuilder
    private var notesCard: some View {
        sectionCard {
            presetNotesSection
        }
    }

    /// Resolve the display name for a joystick mapping slot. Priority:
    ///   1. The user's `customName` if they renamed it.
    ///   2. The currently-connected controller's product name for that
    ///      slot (e.g. "DualSense Wireless Controller").
    ///   3. The fallback "Joystick #N".
    private func resolvedJoystickName(joystick: JoystickMapping, slot: Int) -> String {
        if let custom = joystick.shownCustomName, !custom.isEmpty {
            return custom
        }
        // A slot whose input is the display is not the controller that
        // happens to be plugged in.
        if joystick.inputKind == .screen
            || (!joystick.bindings.isEmpty && joystick.bindings.allSatisfy { $0.input.type == .cursorRegion }) {
            return String(localized: "Screen")
        }
        if let mac = joystick.macInputName { return mac }
        // The pad the group reads, as the visualizer chip names it: a gyro
        // group read the DualSense in slot 1 while this named slot 0's pad.
        let drawn = controllerService.effectiveSlotsCached(for: preset.joysticks)[slot] ?? slot
        if let info = controllerService.controllerDetails[drawn] {
            let trimmed = info.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return String(localized: "Input Device \(slot)")
    }

    /// Apply the visualizer picker's choice back to the preset model
    /// and persist via the store. Auto-creates the joystick mapping
    /// for the slot if one doesn't exist yet (so the picker works on
    /// brand-new presets with no joysticks defined).
    fileprivate func updateSlotInputKind(presetID: UUID, slot: Int, kind: SlotInputKind) {
        guard preset.id == presetID else { return }
        var updated = preset
        while updated.joysticks.count <= slot {
            updated.joysticks.append(JoystickMapping(tag: ""))
        }
        updated.joysticks[slot].inputKind = kind
        updated.modifiedAt = Date()
        preset = updated
        presetStore.savePreset(updated)
    }

    // MARK: - Details

    /// Two-column metadata grid. Left column: Usage / Inputs / Outputs (what
    /// the preset asks for). Right column: Controllers / Storage (what the
    /// user's hardware + filesystem state look like). Saves vertical
    /// space versus the old stacked layout while keeping every datum.
    @ViewBuilder
    private var detailsSection: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 14) {
                detailsRow(title: "Usage", icon: "list.bullet.rectangle",
                           items: usageBullets)
                detailsRow(title: "Inputs", icon: "gamecontroller",
                           items: inputBullets)
                detailsRow(title: "Outputs", icon: "arrow.forward.circle",
                           items: outputBullets)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 14) {
                if controllerService.connectedControllers.isEmpty
                    && controllerService.rawHIDGamepadSlots.isEmpty
                    && controllerService.steamControllerSlot == nil
                    && controllerService.racingWheelSlots.isEmpty
                    && !controllerService.debugMarketingFakeActive {
                    detailsRow(title: "Controllers", icon: "antenna.radiowaves.left.and.right.slash",
                               items: [String(localized: "No controllers currently connected.")])
                } else {
                    detailsRow(title: "Controllers", icon: "antenna.radiowaves.left.and.right",
                               items: controllerBullets)
                }
                storageRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Storage section with Finder + version-history actions instead of a
    /// plain bullet list.
    @ViewBuilder
    private var storageRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc")
                .frame(width: 16)
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                Text("Storage")
                    .font(.caption.weight(.semibold))
                HStack(spacing: 6) {
                    Text("•").foregroundStyle(.hint)
                    Text(preset.filename)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Button {
                        revealInFinder()
                    } label: {
                        Label("Open in Finder", systemImage: "arrow.up.right.square")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 6) {
                    Text("•").foregroundStyle(.hint)
                    Text("Modified \(modifiedRelative)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                versionsDisclosure
            }
            Spacer(minLength: 0)
        }
    }

    @State private var showVisualizer: Bool = true
    /// Edit-mode and zoom state per visualizer slot. A plain box (not
    /// observed here) so creating a state object does not re-run this view;
    /// the title-row controls and the panel observe the objects themselves.
    @State private var visualizerControls = VisualizerControlBox()
    /// The top anchor's place in the page's scroll view, read on a switch.
    @State private var detailTop = ScrollAnchorBox()
    /// Focus state for the notes editor, so the placeholder hides as soon as
    /// the field is clicked rather than waiting for the first typed character.
    @FocusState private var notesFocused: Bool

    /// Notes being typed, written to the preset by `commitNotes`.
    @State private var notesDraft: String?
    /// The preset the Notes draft was typed on, as the header's draft keeps
    /// its own: on a switch the body runs with the new preset before the
    /// flush, and the draft must never show on it.
    @State private var notesDraftID: UUID?
    @State private var notesCommit: Task<Void, Never>?
    /// What the Notes editor shows: the draft, when it belongs here.
    private var shownNotes: String { (notesDraftID == preset.id ? notesDraft : nil) ?? preset.notes }

    private var notesBinding: Binding<String> {
        Binding(get: { shownNotes },
                set: { value in
                    if let id = notesDraftID, id != preset.id { flushNotes(to: id) }
                    notesDraft = value
                    notesDraftID = preset.id
                    notesCommit?.cancel()
                    notesCommit = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(500))
                        guard !Task.isCancelled else { return }
                        commitNotes()
                    }
                })
    }

    private func commitNotes() {
        notesCommit?.cancel()
        notesCommit = nil
        if let id = notesDraftID, id != preset.id { flushNotes(to: id); return }
        guard let draft = notesDraft else { return }
        notesDraft = nil
        notesDraftID = nil
        if draft != preset.notes { preset.notes = draft }
    }

    /// The page moved to another preset with notes still typed: they go
    /// to the preset they were typed on, through the store.
    private func flushNotes(to oldID: UUID) {
        notesCommit?.cancel()
        notesCommit = nil
        guard let draft = notesDraft else { return }
        notesDraft = nil
        notesDraftID = nil
        if var old = presetStore.presets.first(where: { $0.id == oldID }), old.notes != draft {
            old.notes = draft
            presetStore.savePreset(old)
        }
    }

    /// Name and tag being typed, written to the preset by `commitHeader`.
    @State private var headerDraft: PresetHeaderDraft?
    @State private var headerCommit: Task<Void, Never>?

    /// One header field: what is typed on this preset, else the stored text.
    /// `.shipped` wraps it, so a built-in still shows translated and writes
    /// its English only when changed.
    private func headerBinding(_ field: WritableKeyPath<PresetHeaderDraft, String?>,
                               _ stored: KeyPath<Preset, String>) -> Binding<String> {
        Binding(get: { headerDraft?.text(field, on: preset.id) ?? preset[keyPath: stored] },
                set: { value in
                    // Text still waiting from another preset goes there first.
                    if let pending = headerDraft, pending.presetID != preset.id { commitHeader() }
                    var draft = headerDraft ?? PresetHeaderDraft(presetID: preset.id)
                    draft[keyPath: field] = value
                    headerDraft = draft
                    headerCommit?.cancel()
                    headerCommit = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(500))
                        guard !Task.isCancelled else { return }
                        commitHeader()
                    }
                })
    }

    /// The name as shown, with what is being typed: the window title and the
    /// Activate button's spoken label follow each keystroke, as before.
    private var shownName: String {
        headerDraft?.text(\.name, on: preset.id).map(ShippedText.t) ?? preset.shownName
    }

    /// Saves the typed name and tag, in one save, to the preset they were
    /// typed on (this one, or the one the page just left).
    private func commitHeader() {
        if headerCommit != nil { headerCommit?.cancel(); headerCommit = nil }
        guard let draft = headerDraft else { return }
        headerDraft = nil
        if var target = presetStore.presets.first(where: { $0.id == draft.presetID }), draft.apply(to: &target) {
            presetStore.savePreset(target)
        }
    }

    /// The earlier versions, in a view of their own: loading the list on a
    /// switch re-ran the whole page a second time. The page's own reset for
    /// the preset it left runs here, as before.
    private var versionsDisclosure: some View {
        PresetVersionsList(presetID: preset.id, presetStore: presetStore, willRevert: { dropDrafts() })
            .equatable()
            .onChange(of: preset.id) { oldID, _ in
                flushNotes(to: oldID)
                commitHeader()
                resetPageState()
            }
    }

    /// The page lives across preset switches, so what belongs to the preset
    /// left behind goes here. A speed still waiting to commit is dropped: it
    /// was the old preset's, and its write would land on this one. The zoom
    /// is not reset: each panel loads the new preset's own.
    /// Each write only when it changes something: a focus write is a
    /// request even when nothing has focus, and the page ran again for it.
    private func resetPageState() {
        if !showVisualizer { showVisualizer = true }
        if notesFocused { notesFocused = false }
        // Only a panel in Edit Layout: an equal write still publishes.
        for control in visualizerControls.states.values where control.editMode { control.editMode = false }
        if pointerSpeedCommit != nil { pointerSpeedCommit?.cancel(); pointerSpeedCommit = nil }
        if scrollSpeedCommit != nil { scrollSpeedCommit?.cancel(); scrollSpeedCommit = nil }
        if pointerSpeedDraft != nil { pointerSpeedDraft = nil }
        if scrollSpeedDraft != nil { scrollSpeedDraft = nil }
    }

    // MARK: - Per-preset Notes

    @ViewBuilder
    private var presetNotesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "note.text")
                    .iconTint(.yellow)
                Text("Notes")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if !preset.notes.isEmpty {
                    Text(shownNotes.count == 1 ? String(localized: "1 char") : String(localized: "\(shownNotes.count) chars"))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.hint)
                }
            }

            // Plain TextEditor so users can paste multi-line context (which
            // controller this preset is for, what game, gotchas, etc.).
            // Persisted via the same `savePreset` path that the rest of the
            // detail page already uses on change.
            // A built-in preset's notes in the app's language; English on
            // disk until the person changes them.
            TextEditor(text: .shippedText(notesBinding))
                .accessibilityLabel("Preset notes")
                // Typed text reaches the preset half a second after the
                // last keystroke, or at once when the page goes: each
                // character used to save the preset, which re-rendered the
                // window and compared the engine's copy.
                .onDisappear { commitNotes() }
                .onReceive(NotificationCenter.default.publisher(for: .inputConfigCommitDrafts)) { _ in commitNotes() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in commitNotes() }
                .font(.callout)
                .scrollContentBackground(.hidden)
                .focused($notesFocused)
                .frame(minHeight: 60, maxHeight: 120)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.22), lineWidth: 0.5)
                )
                .overlay(alignment: .topLeading) {
                    if shownNotes.isEmpty && !notesFocused {
                        Text("Start typing…")
                            .font(.callout)
                            .foregroundStyle(.hint)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Per-preset Light Bar override

    /// SwiftUI Color for the preset's light-bar override, if any. nil
    /// when no override is set - the visualizer's strip widget uses this
    /// to render its current state.
    private var presetLightBarSwiftUIColor: Color? {
        guard let rgb = preset.lightBarColor else { return nil }
        return Color(red: Double(rgb.floatR),
                     green: Double(rgb.floatG),
                     blue: Double(rgb.floatB))
    }

    /// The preset turns the light off: black, or brightness Off with a
    /// color or the rainbow chosen.
    private var presetLightBarIsOff: Bool {
        let chosen = preset.lightBarColor != nil || preset.lightBarRainbow == true
        let black = preset.lightBarRainbow != true
            && preset.lightBarColor.map { $0.r == 0 && $0.g == 0 && $0.b == 0 } == true
        return chosen && (black || preset.lightBarBrightness == 0)
    }

    /// While this preset is the active one, the controller shows the
    /// override right away, mirroring what the engine does at start. With
    /// the override cleared, the controller goes back to its general color.
    /// A trigger's feel from the Live Visualizer, pushed to the pad at once
    /// while this preset is the active one.
    private func setPresetTriggerFeel(left: Bool, level: Int) {
        let value: Int? = level == 0 ? nil : level
        if left { preset.triggerFeelLeft = value } else { preset.triggerFeelRight = value }
        if MenuBarController.shared.activePresetID == preset.id {
            controllerService.applyPresetTriggerFeel(left: preset.triggerFeelLeft ?? 0, right: preset.triggerFeelRight ?? 0)
        }
    }

    private func pushPresetLightBarLive() {
        guard presetStore.activePresetId == preset.id else { return }
        let slots = controllerService.controllerDetails.keys.filter {
            controllerService.controllerDetails[$0]?.hasLight == true
        }
        let bri = preset.lightBarBrightness.map { UInt8(max(0, min(2, $0))) }
        if preset.lightBarRainbow == true {
            // The rainbow, as the engine starts it; again only retunes it.
            controllerService.applyPresetRainbow(speed: preset.lightBarRainbowSpeed ?? 1, brightness: bri)
        } else if let rgb = preset.lightBarColor {
            // A color ends the preset's rainbow first, so the next rainbow
            // frame does not paint over it.
            if controllerService.presetRainbow != nil {
                controllerService.applyPresetLight(red: rgb.floatR, green: rgb.floatG, blue: rgb.floatB, brightness: bri)
                return
            }
            controllerService.stopAllRGBCycles()
            for slot in slots {
                controllerService.applyTemporaryLight(
                    at: slot, red: rgb.floatR, green: rgb.floatG, blue: rgb.floatB, brightness: bri)
            }
        } else {
            controllerService.revertTemporaryLights()
        }
    }

    /// A version is about to come back whole: what is still being typed is
    /// dropped, or half a second later it went over the reverted text.
    private func dropDrafts() {
        notesCommit?.cancel(); notesCommit = nil; notesDraft = nil; notesDraftID = nil
        headerCommit?.cancel(); headerCommit = nil; headerDraft = nil
        // A speed slider's pending save too, and the name fields made again
        // from the reverted text: a focused field kept its typed text and
        // wrote it back on the next edit.
        if pointerSpeedCommit != nil { pointerSpeedCommit?.cancel(); pointerSpeedCommit = nil }
        if scrollSpeedCommit != nil { scrollSpeedCommit?.cancel(); scrollSpeedCommit = nil }
        pointerSpeedDraft = nil
        scrollSpeedDraft = nil
        revertGeneration &+= 1
    }
    /// Bumped by a revert, so the name and tag fields are made again.
    @State private var revertGeneration = 0

    private func revealInFinder() {
        let url = presetStore.fileURL(for: preset)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @ViewBuilder
    private func detailsRow(title: LocalizedStringKey, icon: String, items: [String]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            IconView(name: icon, glyphHeight: 11)
                .frame(width: 16, alignment: .center)
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                // By position: two identical controllers give identical lines.
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").foregroundStyle(.hint)
                        Text(item)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Detail bullet computation

    private var allBindings: [BindingModel] {
        preset.joysticks.flatMap(\.bindings)
    }

    private var usageBullets: [String] {
        // Tag already lives in the editable subtitle at the top - don't
        // restate it here.
        var bullets: [String] = []
        bullets.append(preset.joysticks.count == 1
                       ? String(localized: "1 joystick mapping")
                       : String(localized: "\(preset.joysticks.count) joystick mappings"))
        bullets.append(allBindings.count == 1
                       ? String(localized: "1 total binding")
                       : String(localized: "\(allBindings.count) total bindings"))
        return bullets
    }

    private var inputBullets: [String] {
        var counts: [InputType: Int] = [:]
        for b in allBindings { counts[b.input.type, default: 0] += 1 }
        var bullets: [String] = []
        if let n = counts[.button], n > 0 { bullets.append(n == 1 ? String(localized: "Buttons: 1 binding") : String(localized: "Buttons: \(n) bindings")) }
        if let n = counts[.axis], n > 0 { bullets.append(n == 1 ? String(localized: "Axes: 1 binding") : String(localized: "Axes: \(n) bindings")) }
        if let n = counts[.hat], n > 0 { bullets.append(n == 1 ? String(localized: "Hat (D-pad): 1 binding") : String(localized: "Hat (D-pad): \(n) bindings")) }
        if let n = counts[.touchpad], n > 0 {
            bullets.append(n == 1
                           ? String(localized: "Touchpad surface: 1 binding (DualSense / DualShock 4 only)")
                           : String(localized: "Touchpad surface: \(n) bindings (DualSense / DualShock 4 only)"))
        }
        if let n = counts[.touchpadRegion], n > 0 {
            bullets.append(n == 1
                           ? String(localized: "Touchpad regions: 1 tap binding")
                           : String(localized: "Touchpad regions: \(n) tap bindings"))
        }
        // The other kinds of input, so a MIDI, keyboard, or tap preset does
        // not read "No inputs bound".
        let others: [(InputType, String)] = [
            (.touchpadGesture, String(localized: "Touchpad gestures")), (.motion, String(localized: "Motion")), (.stickRegion, String(localized: "Stick regions")), (.stickGesture, String(localized: "Stick gestures")), (.buttonSequence, String(localized: "Button sequences")), (.keySequence, String(localized: "Key sequences")),
            (.cursorRegion, String(localized: "Screen regions")), (.screenPixel, String(localized: "Screen colors")), (.screenText, String(localized: "Screen text")), (.voicePhrase, String(localized: "Voice phrases")), (.extKey, String(localized: "Mac keyboard keys")), (.extMouse, String(localized: "Mouse and trackpad")),
            (.midi, "MIDI"), (.chassisTap, String(localized: "Tap the Mac")),
        ]
        for (type, label) in others {
            if let n = counts[type], n > 0 { bullets.append(n == 1 ? String(localized: "\(label): 1 binding") : String(localized: "\(label): \(n) bindings")) }
        }
        if bullets.isEmpty { bullets.append(String(localized: "No inputs bound yet.")) }
        return bullets
    }

    private var outputBullets: [String] {
        var types: Set<OutputType> = []
        var haptic = 0
        var speech = 0
        var macro = 0
        var turbo = 0
        for b in allBindings {
            // Hold, double and triple tap outputs are outputs too: a row
            // with only a hold read as "No outputs configured."
            for o in b.outputs + (b.holdOutputs ?? []) + (b.doubleTapOutputs ?? []) + (b.tripleTapOutputs ?? []) {
                types.insert(o.type)
            }
            if b.hapticEnabled == true { haptic += 1 }
            if b.speechEnabled == true { speech += 1 }
            if b.macroSteps?.isEmpty == false { macro += 1 }
            if b.turboEnabled == true { turbo += 1 }
        }
        var bullets: [String] = []
        if types.contains(.key) { bullets.append(String(localized: "Keyboard keystrokes")) }
        if types.contains(.mouseButton) { bullets.append(String(localized: "Mouse buttons")) }
        if types.contains(.mouseMotion) || types.contains(.mouseStep) { bullets.append(String(localized: "Mouse motion")) }
        if types.contains(.mouseWheel) || types.contains(.mouseWheelStep) { bullets.append(String(localized: "Scroll wheel")) }
        if types.contains(.midiNote) || types.contains(.midiCC)
            || types.contains(.midiPitchBend) || types.contains(.midiProgramChange)
            || types.contains(.midiTransport) {
            bullets.append(String(localized: "MIDI (CoreMIDI virtual source)"))
        }
        if types.contains(.typeText) { bullets.append(String(localized: "Typed text")) }
        if types.contains(.systemAction) { bullets.append(String(localized: "System actions")) }
        if types.contains(.appAction) { bullets.append(String(localized: "App actions")) }
        for kind in [OutputType.absoluteVolume, .lightBar, .controllerProfile] where types.contains(kind) {
            bullets.append(kind.displayName)
        }
        if haptic > 0 { bullets.append(haptic == 1 ? String(localized: "Haptic feedback on 1 binding") : String(localized: "Haptic feedback on \(haptic) bindings")) }
        if speech > 0 { bullets.append(speech == 1 ? String(localized: "Spoken feedback on 1 binding") : String(localized: "Spoken feedback on \(speech) bindings")) }
        if macro > 0 { bullets.append(String(localized: "Macros: \(macro)")) }
        if turbo > 0 { bullets.append(String(localized: "Turbo: \(turbo)")) }
        if bullets.isEmpty { bullets.append(String(localized: "No outputs configured.")) }
        return bullets
    }

    private var controllerBullets: [String] {
        // Battery percentage and similar live state already shows in the
        // sidebar's controller status bar - we don't restate it here. This
        // section focuses on whether the connected hardware can run the
        // preset (button counts, special features, profile match).
        var bullets: [String] = []
        let sortedIndices = controllerService.controllerDetails.keys.sorted()
        for idx in sortedIndices {
            guard let info = controllerService.controllerDetails[idx] else { continue }
            var line = info.name
            if info.brand != .unknown {
                line += "  •  \(info.brand.displayName)"
            }
            bullets.append(line)
            var caps: [String] = []
            caps.append(info.buttonCount == 1 ? String(localized: "1 button") : String(localized: "\(info.buttonCount) buttons"))
            caps.append(info.shownAxisCount == 1 ? String(localized: "1 axis") : String(localized: "\(info.shownAxisCount) axes"))
            if info.hasTouchpad { caps.append(String(localized: "touchpad")) }
            if info.hasLight { caps.append(String(localized: "light bar")) }
            if info.supportsMotion { caps.append(String(localized: "motion sensors")) }
            bullets.append(String(localized: "Capabilities: \(caps.joined(separator: ", "))"))
            bullets.append(String(localized: "Profile: \(info.productCategory)") +
                           (info.hasExtendedGamepad ? String(localized: "  •  extended MFi") : ""))
        }
        return bullets
    }

    @MainActor private static let modifiedFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private var modifiedRelative: String {
        Self.modifiedFormatter.localizedString(for: preset.modifiedAt, relativeTo: Date())
    }

}

// MARK: - Previous versions

/// "Previous versions" under the page's Storage row. The list is read once
/// per preset (on appear and on a switch) and when the store says a version
/// was kept, never in a body: the disk read and decode on the render path
/// pegged the CPU once a controller was connected. Its own view with its own
/// state, so reading it on a switch re-runs only this list, not the page.
struct PresetVersionsList: View, Equatable {
    let presetID: UUID
    /// Read in actions only, never observed.
    let presetStore: PresetStore
    /// The page drops its drafts before a revert (left out of ==).
    var willRevert: () -> Void = {}

    @State private var versions: [PresetStore.PresetVersion] = []
    @State private var showVersions = false

    /// A switch is a new id, which lets the update through; a page body run
    /// for anything else does not reach the list.
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.presetID == b.presetID && a.presetStore === b.presetStore
    }

    var body: some View {
        Group {
            if versions.isEmpty {
                HStack(spacing: 6) {
                    Text("•").foregroundStyle(.hint)
                    Text("No previous versions yet")
                        .font(.caption)
                        .foregroundStyle(.hint)
                }
            } else {
                DisclosureGroup(isExpanded: $showVersions) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(versions) { version in
                            HStack(spacing: 6) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.caption2)
                                    .foregroundStyle(.hint)
                                Text(Self.label(version))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                                Button("Revert") {
                                    revert(to: version)
                                }
                                .buttonStyle(.plain)
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    HStack(spacing: 6) {
                        Text("•").foregroundStyle(.hint)
                        Text("Previous versions (\(versions.count))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .controlSize(.small)
            }
        }
        .onAppear { reload() }
        // Another preset: its list, closed, as the page reset it before.
        .onChange(of: presetID) { _, _ in
            if showVersions { showVersions = false }
            reload()
        }
        // A new version kept for this preset (a save, a change on this
        // page): listed at once. Before, it showed only after switching to
        // another preset and back, so a change just made had no Revert.
        .onReceive(NotificationCenter.default.publisher(for: PresetStore.versionsChangedNotification)) { note in
            if (note.object as? UUID) == presetID { reload() }
        }
        // Intentionally NOT keyed on preset.modifiedAt: that fired a synchronous
        // versions(for:) disk read on EVERY keystroke while editing the name,
        // tag, or notes. The list reloads on preset switch and on appear, which
        // is when this collapsed "Previous versions" group is actually viewed.
    }

    /// Written only when the list differs: two presets with no versions
    /// cost nothing on a switch between them.
    private func reload() {
        let fresh = presetStore.versions(forID: presetID)
        if fresh != versions { versions = fresh }
    }

    /// The preset as stored, as the page's binding reads it.
    private func revert(to v: PresetStore.PresetVersion) {
        guard let preset = presetStore.presets.first(where: { $0.id == presetID }) else { return }
        // Only a version still kept: a pruned one changes nothing, so what
        // is being typed stays.
        if FileManager.default.fileExists(atPath: v.fileURL.path) { willRevert() }
        presetStore.revertPreset(preset, to: v)
    }

    /// Shared by every version row rather than built per row per render.
    @MainActor private static let versionDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    static func label(_ v: PresetStore.PresetVersion) -> String {
        let bindings = v.bindingCount
        let bindingsText = bindings == 1 ? String(localized: "1 binding") : String(localized: "\(bindings) bindings")
        return "\(versionDateFormatter.string(from: v.savedAt))  •  \(bindingsText)"
    }
}

// MARK: - Per-preset light bar popover

/// The light bar picker for one preset, opened from the strip on the Live
/// Visualizer's controller drawing. The same grid as the controller popover:
/// fixed colors, a Custom well that applies as soon as a color is chosen,
/// Rainbow (the RGB cycle, with its speed), then brightness. "Controller's
/// color" clears the override so the preset leaves the light alone.
struct PresetLightBarPopover: View {
    @SwiftUI.Binding var color: RGBLightColor?
    @SwiftUI.Binding var brightness: Int?
    @SwiftUI.Binding var rainbow: Bool?
    @SwiftUI.Binding var rainbowSpeed: Double?
    var onChanged: () -> Void = {}

    @State private var customColor = Color.blue

    private static let swatches: [(name: String, r: UInt8, g: UInt8, b: UInt8)] = [
        ("Red",    255, 0, 0),
        ("Orange", 255, 89, 0),
        ("Yellow", 255, 179, 0),
        ("Green",  0, 255, 0),
        ("Cyan",   0, 255, 255),
        ("Blue",   0, 0, 255),
        ("Purple", 128, 0, 255),
        ("Pink",   255, 0, 153),
        ("White",  255, 255, 255),
        ("Off",    0, 0, 0),
    ]

    private var isRainbow: Bool { rainbow == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "light.beacon.max.fill")
                    .foregroundStyle(.pink)
                Text("Light bar for this preset")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if color != nil || isRainbow {
                    Button("Controller's color") {
                        color = nil
                        brightness = nil
                        rainbow = nil
                        rainbowSpeed = nil
                        onChanged()
                    }
                    .buttonStyle(.solidSecondaryCompact)
                    .controlSize(.small)
                    .help("Forget this preset's color and leave the light bar on the controller's general color")
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 8) {
                ForEach(Self.swatches, id: \.name) { swatch in
                    let swatchColor = swatch.name == "Off" ? Color.gray.opacity(0.3) :
                        Color(red: Double(swatch.r) / 255, green: Double(swatch.g) / 255, blue: Double(swatch.b) / 255)
                    LightSwatchButton(name: localizedColorName(swatch.name), color: swatchColor) {
                        set(RGBLightColor(r: swatch.r, g: swatch.g, b: swatch.b))
                    }
                }
                VStack(spacing: 2) {
                    ColorPicker("", selection: $customColor, supportsOpacity: false)
                        .labelsHidden()
                        .scaleEffect(1.35)
                        .frame(width: 24, height: 24)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                        .shadow(color: customColor.opacity(0.3), radius: 2)
                        .accessibilityLabel("Custom light bar color")
                        .voiceNames("Custom", "Custom light bar color")
                        .onChange(of: customColor) { _, value in
                            let ns = NSColor(value).usingColorSpace(.sRGB) ?? NSColor(value)
                            let rgb = RGBLightColor(floatR: Float(ns.redComponent),
                                                    floatG: Float(ns.greenComponent),
                                                    floatB: Float(ns.blueComponent))
                            // The well taking the preset's own color on open
                            // is not a pick, and must not end a rainbow.
                            guard rgb != color else { return }
                            set(rgb)
                        }
                    Text("Custom")
                        .font(.system(size: 8))
                        .foregroundStyle(.hint)
                }
                // Rainbow: the RGB cycle while the preset runs, as the
                // controller menu's swatch. Ringed while it is the choice.
                Button {
                    rainbow = isRainbow ? nil : true
                    onChanged()
                } label: {
                    VStack(spacing: 2) {
                        Circle()
                            .fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                            .overlay(
                                Circle().strokeBorder(isRainbow ? Color.white.opacity(0.9) : Color.primary.opacity(0.12),
                                                      lineWidth: isRainbow ? 2 : 0.5)
                            )
                            .frame(width: 24, height: 24)
                            .shadow(color: .white.opacity(isRainbow ? 0.5 : 0.2), radius: isRainbow ? 4 : 2)
                        Text("Rainbow")
                            .font(.system(size: 8))
                            .foregroundStyle(isRainbow ? AnyShapeStyle(.secondary) : AnyShapeStyle(.hint))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rainbow, RGB cycle")
                .accessibilityValue(isRainbow ? String(localized: "on") : String(localized: "off"))
                .help(isRainbow ? String(localized: "Turn the rainbow off for this preset") : String(localized: "Cycle the light bar through every color while this preset runs"))
            }

            // Cycle speed, only while Rainbow is the choice. The same scale
            // as the controller menu's slider.
            if isRainbow {
                HStack(spacing: 8) {
                    Text("Speed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "tortoise")
                        .font(.system(size: 10))
                        .foregroundStyle(.hint)
                    ThrottledSlider("Rainbow speed",
                                    value: SwiftUI.Binding(
                                        get: { rainbowSpeed ?? 1 },
                                        set: { rainbowSpeed = $0; onChanged() }),
                                    in: Preset.lightBarRainbowSpeedRange,
                                    step: 0.05)
                        .accessibilityValue(String(format: String(localized: "%.2f times normal"), locale: .current, rainbowSpeed ?? 1))
                    Image(systemName: "hare")
                        .font(.system(size: 10))
                        .foregroundStyle(.hint)
                }
            }

            HStack(spacing: 8) {
                Text("Brightness")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Light bar brightness", selection: SwiftUI.Binding(
                    get: { brightness ?? 2 },
                    set: { brightness = $0; onChanged() })) {
                    Text("Off").tag(0)
                    Text("Dim").tag(1)
                    Text("Bright").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }

            Text(isRainbow
                 ? String(localized: "The light bar cycles through every color while the preset runs and goes back when it stops.")
                 : color == nil
                 ? String(localized: "No color set: the controller keeps its general color while this preset runs.")
                 : String(localized: "The controller switches to this color while the preset runs and goes back when it stops."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(width: 260)
        .animation(.easeOut(duration: 0.18), value: isRainbow)
        .onAppear {
            if let rgb = color {
                customColor = Color(red: Double(rgb.floatR), green: Double(rgb.floatG), blue: Double(rgb.floatB))
            }
        }
    }

    /// A color replaces the rainbow.
    private func set(_ rgb: RGBLightColor) {
        color = rgb
        rainbow = nil
        onChanged()
    }
}

/// Compact capability-chip row that wraps to the next line when the
/// containing width runs out. Used by the controller status popover so the
/// chips never overlap or push other elements out of the popover.
struct FlowChipRow: View {
    let chips: [(String, Color)]

    var body: some View {
        if chips.isEmpty {
            EmptyView()
        } else {
            // Use SwiftUI's built-in flow layout (macOS 13+) - wraps chips
            // to multiple lines when they don't fit.
            FlowLayoutWrapper {
                ForEach(0..<chips.count, id: \.self) { i in
                    Text(chips[i].0)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(chips[i].1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(chips[i].1.opacity(0.15)))
                }
            }
        }
    }
}

/// Tiny flow-wrap container. We can't use SwiftUI 16+ `Layout` because the
/// app deploys to macOS 14, so this falls back to a stacked HStack + the
/// `_VariadicView` mechanism. For simplicity here we use a horizontal
/// wrap via `HStack` + `Spacer` controlled `FlexibleView`-style helper:
/// rendering one HStack per row, breaking on overflow. Implemented with
/// `GeometryReader` measurement.
fileprivate struct FlowLayoutWrapper<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        // The simplest workable wrap on macOS 14: a `WrappingHStack`
        // implemented via a `Layout` that arranges proposed sizes left to
        // right and breaks lines. macOS 14 *does* support `Layout`, so we
        // use it here without needing a deployment-target bump.
        WrappingHStackLayout(spacing: 4, lineSpacing: 4) {
            content
        }
    }
}

/// Left-to-right wrapping layout (the macOS equivalent of HTML's
/// inline-block + word-wrap). Each subview is given its ideal size; rows
/// break when the next subview would overflow.
struct WrappingHStackLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxXSeen: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += rowHeight + lineSpacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            maxXSeen = max(maxXSeen, x)
            rowHeight = max(rowHeight, size.height)
        }
        let totalHeight = y + rowHeight
        return CGSize(width: min(maxWidth, maxXSeen), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.minX + maxWidth {
                y += rowHeight + lineSpacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                       proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// The in-app "Update available" alert and its UpdateCheckService were
// removed: the Mac App Store delivers update notifications itself, and
// App Review guideline 2.4.5(vii) prohibits in-app update checks.

// MARK: - Speed row pieces

/// What a speed slider does: set (a drag step or a keyboard step) and the
/// end of a drag. The page writes fresh closures here on every body run, so
/// a slider that skipped that run still acts on the preset shown now.
@MainActor
final class SpeedSliderActions {
    var presetID: UUID?
    var set: (Double) -> Void = { _ in }
    var ended: () -> Void = {}
    /// The preset a drag began on. The row is no longer made anew on a
    /// switch, so a drag still held across one (a switch from a controller
    /// or a menu shortcut) would have gone on writing to the next preset;
    /// now the rest of it is let go, as when the slider was made anew.
    private(set) var dragPresetID: UUID?
    /// Whether a mouse button is down. A closure so the bench can say.
    var mouseHeld: () -> Bool = { NSEvent.pressedMouseButtons != 0 }

    /// A value from the slider: kept unless it belongs to a drag begun on
    /// another preset.
    func step(_ value: Double) {
        if let started = dragPresetID, started != presetID {
            // A drag still held from the preset left is let go. A keyboard
            // step (no mouse button down) is this preset's own: the slider
            // keeps focus across a switch, and its arrows must still work.
            if mouseHeld() { return }
            dragPresetID = nil
        }
        set(value)
    }

    /// A drag starting or ending. The end saves, unless the drag began on
    /// another preset.
    func editing(_ on: Bool) {
        if on {
            dragPresetID = presetID
        } else {
            let started = dragPresetID
            dragPresetID = nil
            if started == nil || started == presetID { ended() }
        }
    }
}

/// One speed slider, Equatable on what it draws: the value shown. Its
/// stepped track draws a tick at each of its 99 values, which made the
/// slider the dearest view on the page to build or run again, and a switch
/// between presets at the same speed now leaves it alone. The title is the
/// same for the life of the actions box (one box per slider), and the
/// actions themselves go through that box, so `==` compares the box.
struct SpeedSlider: View, Equatable {
    let title: LocalizedStringKey
    let shown: Double
    let actions: SpeedSliderActions

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.shown == b.shown && a.actions === b.actions
    }

    var body: some View {
        #if DEBUG
        let _ = BodyRuns.note("SpeedSlider")
        #endif
        Slider(value: SwiftUI.Binding(get: { shown }, set: { actions.step($0) }),
               in: 0.1...5.0, step: 0.05) { actions.editing($0) }
        .frame(width: 140)
        // The values a slider has anyway (no view in it sets either guide),
        // stated: without them each layout of the row asked the slider's
        // hundred ticks one by one for an alignment of their own, which was
        // most of what the row still cost on a switch. The page lays out to
        // the same frames with and without these (PageBuildProbe, both
        // directions).
        .alignmentGuide(.leading) { _ in 0 }
        .alignmentGuide(VerticalAlignment.center) { $0.height / 2 }
        .accessibilityLabel(title)
        .accessibilityValue(String(format: String(localized: "times %.2f"), locale: .current, shown))
    }
}

extension SpeedSlider {
    /// For the test bench, which does not import SwiftUI.
    init(benchTitle: String, shown: Double, actions: SpeedSliderActions) {
        self.init(title: LocalizedStringKey(benchTitle), shown: shown, actions: actions)
    }
}

/// The identity of a speed number field. The field is made anew when the
/// preset changes while it has focus, as the whole row used to be on every
/// switch: what it holds then is typing on the preset left behind, which it
/// commits to that preset as it goes. Without focus it holds nothing but the
/// value it shows, which follows the new preset, so it stays.
@MainActor
final class SpeedFieldKey {
    let focus = NumberEntryFocus()
    private var presetID: UUID?
    private var current = UUID()

    func key(for id: UUID) -> UUID {
        if presetID != id {
            if presetID != nil, focus.active { current = UUID() }
            presetID = id
        }
        return current
    }
}
