import SwiftUI
import Combine

/// A joystick group showing its header and list of bindings.
/// Rows light from LiveRowLights, so live input never re-runs the group.
struct JoystickGroupView: View {
    @SwiftUI.Binding var joystick: JoystickMapping
    /// Settings' Face button names: the rows read it through
    /// FaceLetters.current, so a change re-renders them.
    @AppStorage(FaceLetters.defaultsKey) private var faceChoice = FaceLetters.automatic.rawValue
    let joystickIndex: Int
    let controllerName: String
    let onAddBinding: () -> Void
    let onRemoveBinding: (Int) -> Void
    let onDuplicateBinding: (Int) -> Void
    let onScanInput: (Int) -> Void
    /// Scan for a row's chord control (the second input it must hold).
    var onScanModifierInput: (Int, Int?) -> Void = { _, _ in }
    let onSortBindings: () -> Void
    let onDuplicate: () -> Void
    let onRemoveJoystick: () -> Void
    /// Binding UUID currently pulsing (jump-to-binding from Live Visualizer).
    /// nil when no pulse is active.
    var pulsingBindingID: UUID? = nil
    var focusBindingID: UUID? = nil
    /// A row a jump is heading for: built at once, with the rows above it,
    /// rather than waiting for the staged reveal to reach it.
    var revealThrough: UUID? = nil
    /// The jump target is in a group below this one: every row here is
    /// built now, so rows filling in later do not push the target away.
    var revealAll = false
    /// The slot this group reads, worked out with the preset's other groups
    /// the way the engine does. nil falls back to this group on its own.
    var resolvedSlot: Int? = nil
    /// The connected pad this group would read if it stopped waiting for
    /// its own, worked out with the preset's other groups.
    var standInPadName: () -> String? = { nil }

    /// Preset list for the App Action target picker, passed as plain values
    /// so the row views stay store-subscription free.
    var availablePresets: [(id: UUID, name: String)] = []

    // Not the mapping engine: nothing here reads it, and observing it
    // re-ran every row on each of its debug log flushes (5 Hz while active).
    @EnvironmentObject var controllerService: GameControllerService
    @Environment(\.appTextScale) private var textScale
    /// The preset's own Buttons choice, from the editor.
    @Environment(\.presetButtonFamily) private var presetFamily

    /// How this group's rows name their buttons: the preset's family when
    /// it has one, else the family of the controller this group reads, and
    /// the controller's when the two number their buttons differently.
    private var effectiveButtonFamily: FaceLetters? {
        controllerService.naming(forSlot: deviceSlot, presetFamily: presetFamily).family
    }

    /// The connected pad's own names, when the rows are named for its family.
    private var effectiveModelNames: ButtonNames.ModelNames {
        controllerService.naming(forSlot: deviceSlot, presetFamily: presetFamily).model
    }
    // The live sets that light a row are NOT observed here: each row hears
    // only its own key (LiveRowLights). Observing them re-ran this whole
    // group, every row, up to 30 times a second while the pointer moved or
    // the list scrolled, because a scroll is itself a live mouse input.
    @ObservedObject private var rawHIDService = RawHIDGamepadService.shared
    @ObservedObject private var deviceRegistry = HIDDeviceRegistry.shared
    /// Zone edits redo the rows' overlap notes.
    @ObservedObject private var stickZones = StickRegionService.shared
    /// Keyboards and mice for the device menu, refreshed when the list
    /// changes rather than on every event the service publishes.
    @State private var externalDevices: [ExternalInputDeviceService.Device] = ExternalInputDeviceService.shared.devices
    /// The binding being dragged by its handle, if any.
    /// Live row-reorder state. Held as plain `@State` (not `@StateObject`) so
    /// this group does NOT observe it: a drag updates 120 times a second, and
    /// re-running the group body that often would re-serialize every row's
    /// input key on every frame. Only the small per-row offset modifier
    /// observes it.
    @State private var rowDrag = RowDragState()
    /// How many rows are built so far (see the reveal task); everything
    /// once the first rows have settled.
    @State private var revealedRows = JoystickGroupView.firstReveal
    static let firstReveal = 8

    /// Builds the rows down to the jump target now, so the editor can
    /// scroll to it; the staged reveal carries on below it.
    private func revealForJump() {
        if revealAll, revealedRows < joystick.bindings.count {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { revealedRows = .max }
            return
        }
        guard let id = revealThrough, let i = joystick.bindings.firstIndex(where: { $0.id == id }),
              i >= revealedRows else { return }
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { revealedRows = i + 1 + Self.revealBatch }
    }
    static let revealBatch = 4
    /// Current height of each row, so a drag only moves past a row once
    /// the pointer has crossed its middle (this is what stops the reorder
    /// from oscillating when the rows shift under the pointer).
    /// Measured row heights, used only by the drag-reorder midpoint rule.
    ///
    /// Deliberately a reference box rather than `@State` of a dictionary:
    /// writing a measured height into `@State` invalidates this whole group,
    /// which re-evaluates all of its rows. Heights are written from a
    /// `GeometryReader` during layout, so that turned every re-measure into
    /// another full group pass. The box is read live by the drop delegate and
    /// never needs to trigger a redraw.
    @State private var rowHeights = RowFrameStore()
    @State private var preSortSnapshot: [BindingModel]?
    /// The rows right after the sort. Undo sort is offered only while the
    /// rows still match it: later, it rolled back every edit made after
    /// the sort, the same problem the toolbar's Undo Sort had.
    @State private var postSortSnapshot: [BindingModel]?
    /// Inline rename popover state for the "Custom name…" menu item.
    @State private var renamePopoverOpen: Bool = false
    @State private var renameDraft: String = ""
    /// Stick Settings popover: set the deadzone across every axis binding
    /// in this joystick in one move instead of expanding each row's Options.
    @State private var showStickSettings = false
    /// The Zones section at the foot of the group, and the part it shows.
    @State private var zonesOpen = false
    @State private var zonesPart: ZonePart?
    /// Set when a request opened the section, so it is scrolled into view.
    @State private var scrollToZones = false
    /// The row that opened the section, for its Back button.
    @State private var zonesReturnRow: UUID?
    @State private var newSectionPopoverOpen = false
    @State private var newSectionName = ""
    @State private var bulkDeadzone: Double = 0.25

    /// Space between binding boxes, and from the boxes to the group's edge.
    static let rowGap: CGFloat = 6
    static let rowInset: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
        VStack(spacing: 0) {
            headerView
                // Older presets were born with this placeholder as their
                // tag; it is not a tag, so clear it on sight.
                .onAppear { if joystick.tag == "Add bindings here" { joystick.tag = "" } }

            if joystick.isExpanded {
                // Compute the per-slot extras snapshot ONCE per render and reuse
                // it for every row. extraButtonsSnapshot maps + sorts cached data
                // under a lock, so calling it once per binding row turned the
                // editor render into an O(rows) hot path (the biggest UI-lag
                // contributor while a preset with many binds is open).
                let extras = controllerService.extraButtonsSnapshot(for: deviceSlot)
                // Rows never display press state, but `pressed` participates
                // in ExtraButton's Equatable, so passing the live snapshot
                // re-rendered every picker-heavy row each time any extra
                // button changed state. Strip it so the rows diff stably;
                // this was the main scroll-lag source while a controller
                // was connected.
                let rowExtras = extras.map {
                    GameControllerService.ExtraButton(label: $0.label, index: $0.index, pressed: false)
                }
                // Use `bindings.indices` instead of `Array(...).enumerated()`
                // to avoid allocating a new array on every render.
                // Plain VStack on purpose: lazy rows re-triggered heavy
                // layout bursts under rapid page-down scrolling. Eager rows
                // measured freeze-proof and CPU-idle during wheel scrolling.
                // Column titles for the two boxes every row is built from.
                // Positioned from the row's own column metrics so the words
                // sit exactly over the boxes they name.
                // The same bracket the home page draws over its showcase
                // grid: one over the input columns, one over the outputs.
                if !joystick.bindings.isEmpty {
                    HStack(spacing: 0) {
                        Color.clear.frame(width: Self.rowInset + BindingRowView.inputBracketLeading(scale: textScale), height: 1)
                        BracketHeader(title: "Input", font: .callout.weight(.semibold))
                            .frame(width: BindingRowView.inputBracketWidth(scale: textScale))
                        Color.clear.frame(width: BindingRowView.outputBracketLeading(scale: textScale)
                                          - BindingRowView.inputBracketLeading(scale: textScale)
                                          - BindingRowView.inputBracketWidth(scale: textScale), height: 1)
                        BracketHeader(title: "Output", font: .callout.weight(.semibold))
                        Color.clear.frame(width: BindingRowView.bracketTrailing + Self.rowInset, height: 1)
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                    .accessibilityHidden(true)
                }
                // Each binding is its own box with a gap between them, so a
                // long preset reads as a stack of cards, not a wall of text.
                VStack(spacing: Self.rowGap) {
                    // Keyed by the row, so a move moves it instead of
                    // rebuilding both rows: focus and an open Options stay.
                    ForEach(Array(joystick.bindings.prefix(revealedRows).enumerated()), id: \.element.id) { index, binding in
                        // A heading above the first row of each run of rows
                        // that share a section name.
                        if let section = binding.section, !section.isEmpty,
                           index == 0 || joystick.bindings[index - 1].section != section {
                            SectionHeadingRow(
                                name: section,
                                onRename: { renameSection(startingAt: index, from: section, to: $0) },
                                onDissolve: { dissolveSection(startingAt: index) })
                        }
                        // Serialize the input once and reuse it across the three
                        // highlight membership checks (was rebuilt 3x per row).
                        let inputKey = binding.input.serialized
                        // EquatableBindingRow instead of a bare BindingRowView:
                        // this view re-runs on EVERY activeInputsPublished /
                        // rawActiveInputs publish (up to 30 Hz while inputs
                        // fire). BindingRowView's closure parameters defeat
                        // SwiftUI's memberwise diffing, so every publish used
                        // to re-run every heavy row body and re-measure the
                        // whole sheet's layout - the main thread pinned at
                        // 90%+ CPU whenever the editor was open with a preset
                        // active. The Equatable shell compares value inputs
                        // only, so unchanged rows skip body entirely.
                        EquatableBindingRow(
                            binding: bindingAt(index),
                            snapshot: binding,
                            // The row lights itself from LiveRowLights, by
                            // the engine's chord rules (see RowLight).
                            liveKey: LiveRowLights.RowLight(binding, in: joystick.bindings, inputKey: inputKey),
                            displayNumber: index + 1,
                            zoneOverlap: binding.input.type == .stickRegion
                                ? StickRegionService.shared.directionRowsOverlapping(binding, in: joystick.bindings) : [],
                            zoneZoneOverlap: binding.input.type == .stickRegion
                                ? StickRegionService.shared.zoneRowsOverlapping(binding, in: joystick.bindings) : [],
                            zoneTakenBy: binding.input.type == .axis
                                ? StickRegionService.shared.zoneRowsTakingOver(binding, in: joystick.bindings) : [],
                            isPulsing: pulsingBindingID == binding.id,
                            takesFocus: focusBindingID == binding.id,
                            // Named extras (paddles/FN/mute/Home) for the
                            // slot's connected controller, passed by value so
                            // BindingRowView doesn't need to subscribe to
                            // the service itself.
                            extraButtons: rowExtras,
                            availablePresets: availablePresets,
                            slot: deviceSlot,
                            faceChoice: faceChoice,
                            onScan: { onScanInput(index) },
                            onScanModifier: { onScanModifierInput(index, $0) },
                            onRemove: { onRemoveBinding(index) },
                            onDuplicate: { onDuplicateBinding(index) },
                            onDragChanged: { dy in dragRow(binding.id, at: index, by: dy) },
                            onDragEnded: { dropRow() },
                            onMove: { (step: Int) in moveRow(binding.id, by: step) }
                        )
                        .equatable()
                        // Reordering without a pointer, for VoiceOver and
                        // Full Keyboard Access: rows moved only by dragging.
                        .accessibilityAction(named: "Move up") { moveRow(binding.id, by: -1) }
                        .accessibilityAction(named: "Move down") { moveRow(binding.id, by: 1) }
                        .background(GeometryReader { geo in
                            // Real position in the list, not a running total of
                            // heights: cumulative sums drift as soon as one row
                            // is a different size than assumed, and the drag
                            // then lands in the wrong slot.
                            Color.clear.onChange(of: geo.frame(in: .named(Self.listSpace)),
                                                 initial: true) { _, f in
                                rowHeights[binding.id] = f
                            }
                        })
                        .modifier(RowDragLift(lift: rowDrag.lift(for: binding.id)))
                        // Under the last row of a section: a line to its plus,
                        // which adds a row at the section's end.
                        if let section = binding.section, !section.isEmpty,
                           index == joystick.bindings.count - 1 || joystick.bindings[index + 1].section != section {
                            SectionEndRow(name: section, onAddRow: { addRow(toSectionEndingAt: index) })
                        }
                    }
                }
                .padding(.horizontal, Self.rowInset)
                .padding(.vertical, Self.rowGap)
                // Suppress implicit transitions on row insertion/removal so
                // scrolling does not trigger animation work for new rows.
                .animation(nil, value: joystick.bindings.count)
                .coordinateSpace(name: Self.listSpace)
                // The first rows come with the sheet; the rest follow in
                // small batches once it has slid in. Building every row in
                // the first frame (about 24 ms each) held the editor back
                // for most of a second on a full preset.
                .onChange(of: revealThrough) { _, _ in revealForJump() }
                .onChange(of: revealAll) { _, _ in revealForJump() }
                .onChange(of: joystick.bindings.count) { _, _ in revealForJump() }
                .task {
                    revealForJump()
                    guard revealedRows < joystick.bindings.count else { revealedRows = .max; return }
                    try? await Task.sleep(for: .milliseconds(380))
                    while revealedRows < joystick.bindings.count {
                        var t = Transaction(); t.disablesAnimations = true
                        withTransaction(t) { revealedRows += Self.revealBatch }
                        try? await Task.sleep(for: .milliseconds(24))
                    }
                    revealedRows = .max
                }

                // A fresh group: offer the whole device in one click, so a
                // new preset does not have to be built one row at a time.
                if joystick.bindings.isEmpty {
                    let caps = scaffoldCapabilities
                    VStack(spacing: 8) {
                        Button {
                            addScaffold(scaffoldControls)
                        } label: {
                            Label("Automatically insert available inputs", systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.solid)
                        .disabled(caps.isEmpty)
                        .help("Adds a row for each input the device reports right now, grouped by part, each waiting for you to choose its output")
                        Text(scaffoldPrompt)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 520)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .padding(.bottom, 10)
                }

                Button(action: onAddBinding) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.green)
                            .accessibilityHidden(true)
                        Text("Add a new bind")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .background(Color.green.opacity(0.03))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.25))
                .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        // A named stop per device group, so two groups' "Row 1" are told
        // apart and a long group can be skipped in one move.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(resolvedHeaderName)
            // The device's regions, in a card of their own under its rows.
            if joystick.isExpanded { zonesSection }
        }
        // The rows name their buttons the way this group's controller does.
        .onReceive(ExternalInputDeviceService.shared.$devices) { externalDevices = $0 }
        // A row's "draw zones", its Options, the preset page or the Live
        // Visualizer asked for one part's zones in this group.
        .onReceive(NotificationCenter.default.publisher(for: ShowZonesRequest.name)) { note in
            guard let request = note.object as? ShowZonesRequest else { return }
            let mine = request.bindingID.map { id in joystick.bindings.contains { $0.id == id } }
                ?? (request.groupIndex == joystickIndex)
            guard mine else { return }
            if !joystick.isExpanded { joystick.isExpanded = true }
            zonesPart = request.part
            zonesReturnRow = request.bindingID
            zonesOpen = true
            scrollToZones = true
            AccessibilityNotification.Announcement(String(localized: "Regions: \(partTitle(request.part))")).post()
        }
        .environment(\.presetButtonFamily, effectiveButtonFamily)
        .environment(\.buttonModelNames, effectiveModelNames)
        .environment(\.deviceButtonNames, descriptorPadButtonNames)
    }

    /// The button names of the pad in this group's slot when it is read from
    /// its descriptor alone (an unknown pad, a flight stick, a button box),
    /// whose numbers are not a gamepad's.
    private var descriptorPadButtonNames: [String]? {
        guard let pad = controllerService.rawHIDGamepadSlots[deviceSlot], let profile = pad.profile,
              profile.identifier.hasPrefix("generic-hid-") || profile.identifier.hasPrefix("raw-hid-") else { return nil }
        return profile.physicalButtonNames
    }

    // MARK: - Zones

    /// The parts of this group's device that zones are drawn on: its
    /// touchpad, its sticks, its triggers, and the screen when the group
    /// reads the pointer; any part a row already uses is listed too.
    private var zoneParts: [ZonePart] {
        let caps = scaffoldCapabilities
        let inputs = joystick.bindings.map(\.input)
        var has = Set<ZonePart>()
        if caps.touchpad || inputs.contains(where: { $0.type == .touchpadRegion && $0.touchpadSurface != 1 }) { has.insert(.touchpad) }
        // A Steam Controller's two trackpads: the right one is the main
        // touch surface, the left one has regions of its own.
        for pad in caps.trackpads { has.insert(pad.surface == 1 ? .leftTrackpad : .touchpad) }
        if inputs.contains(where: { $0.type == .touchpadRegion && $0.touchpadSurface == 1 }) { has.insert(.leftTrackpad) }
        for stick in caps.sticks {
            if stick.x == 0 { has.insert(.stick(0)) } else if stick.x == 2 { has.insert(.stick(1)) }
        }
        if caps.triggers { has.formUnion([.band(4), .band(5)]) }
        for input in inputs where input.type == .stickRegion { has.insert(ZonePart(regionKey: input.index)) }
        if joystick.inputKind == .screen || joystick.inputKind == .mouse
            || inputs.contains(where: { $0.type == .cursorRegion }) { has.insert(.screen) }
        // Left to right as they sit on the pad: left trigger, left stick,
        // touchpad, right stick, right trigger; then other axes, the screen.
        let order: [ZonePart] = [.band(4), .stick(0), .leftTrackpad, .touchpad, .stick(1), .band(5)]
        let others = has.filter { !order.contains($0) && $0 != .screen }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        return order.filter(has.contains) + others + (has.contains(.screen) ? [.screen] : [])
    }

    /// Under the group, in the Automation section's card: Regions, with
    /// this device's parts in a column and the chosen part's regions drawn
    /// and listed beside it.
    @ViewBuilder
    private var zonesSection: some View {
        let listed = zoneParts
        let parts = zonesPart.map { listed.contains($0) ? listed : listed + [$0] } ?? listed
        if !parts.isEmpty {
            let shown = zonesPart.flatMap { parts.contains($0) ? $0 : nil } ?? parts[0]
            VStack(alignment: .leading, spacing: 6) {
                DisclosureGroup(isExpanded: $zonesOpen) {
                    HStack(alignment: .top, spacing: 16) {
                        zonePartColumn(parts, shown: shown)
                        Divider()
                        HStack {
                            Spacer(minLength: 0)
                            zoneEditor(shown)
                                .id(shown)
                            Spacer(minLength: 0)
                        }
                    }
                    .padding(.top, 10)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "circle.dashed")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Regions")
                                .font(.headline)
                                .accessibilityAddTraits(.isHeader)
                                // Several groups each have one: say whose.
                                .accessibilityLabel(String(localized: "Regions of \u{201C}\(resolvedHeaderName)\u{201D}"))
                            Text(zonesSummary(parts))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        // Back to the row that opened this, where it was.
                        if zonesOpen, let rowID = zonesReturnRow,
                           let index = joystick.bindings.firstIndex(where: { $0.id == rowID }) {
                            Button {
                                zonesReturnRow = nil
                                NotificationCenter.default.post(name: BindingRowView.revealRow, object: rowID)
                                AccessibilityNotification.Announcement(String(localized: "Row \(index + 1)")).post()
                            } label: {
                                Label(String(localized: "Back to row \(index + 1)"), systemImage: "chevron.backward")
                            }
                            .buttonStyle(.solidSecondaryCompact)
                        }
                    }
                    // The whole header opens and closes it, not only the arrow.
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { zonesOpen.toggle() } }
                }
                .padding(12)
                // The plain card One-Stick Driving uses; only Automation is purple.
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.22), lineWidth: 1))
            }
            .background(ScrollIntoViewAnchor(active: scrollToZones) { scrollToZones = false })
        }
    }

    /// The parts of the device, one under the other, each with how many
    /// regions it has; the chosen one is lit.
    private func zonePartColumn(_ parts: [ZonePart], shown: ZonePart) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(parts) { part in
                let count = zoneCount(part)
                Button {
                    zonesPart = part
                } label: {
                    HStack(spacing: 8) {
                        Text(partTitle(part))
                            .font(.callout)
                            .foregroundStyle(part == shown ? Color.primary : Color.secondary)
                        Spacer(minLength: 8)
                        if count > 0 {
                            Text("\(count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                // Said once, by the value.
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(part == shown ? Color.secondary.opacity(0.18) : Color.clear))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(part == shown ? [.isSelected] : [])
                .accessibilityValue(count == 1 ? String(localized: "1 region") : String(localized: "\(count) regions"))
            }
        }
        .frame(width: 170 * min(1.4, max(1, textScale)), alignment: .leading)
    }

    /// The rows that read a stick or a trigger: its direction rows and its
    /// region rows, with what each sends and where it starts to count.
    private func partRows(_ part: ZonePart) -> [RegionPartRow] {
        joystick.bindings.enumerated().compactMap { i, b in
            let input = b.input
            var regionID: UUID?
            switch part {
            case .stick(let st):
                if input.type == .axis, input.index == st * 2 || input.index == st * 2 + 1 { break }
                if input.type == .stickRegion, input.index == st { regionID = input.stickRegionID; break }
                return nil
            case .band(let a):
                if input.type == .axis, input.index == a { break }
                if input.type == .stickRegion, input.index == StickRegionService.bandKeyBase + a { regionID = input.stickRegionID; break }
                return nil
            default:
                return nil
            }
            let title: String
            if let regionID {
                title = StickRegionService.shared.region(with: regionID)?.region.shownName ?? String(localized: "Region")
            } else {
                let axis = ButtonNames.axisName(input.index, family: effectiveButtonFamily) ?? String(localized: "Axis #\(input.index)")
                title = input.axisDirection.map { "\(axis) \($0.displayName)" } ?? axis
            }
            // What it sends, short: the note is said in the row itself.
            let output = OutputAction.names(b.outputs).joined(separator: " + ")
            return RegionPartRow(id: b.id, number: i + 1, title: title, output: output,
                                 regionID: regionID, deadzone: Double(b.deadzone ?? 0.25),
                                 fullPush: Double(b.outerDeadzone ?? 1))
        }
    }

    /// Shows a row in the editor with its Options open.
    private func jumpToRow(_ id: UUID) {
        NotificationCenter.default.post(name: BindingRowView.revealRow, object: id)
        NotificationCenter.default.post(name: Notification.Name("InputConfig.ExpandBindingOptions"), object: id)
        if let index = joystick.bindings.firstIndex(where: { $0.id == id }) {
            AccessibilityNotification.Announcement(String(localized: "Row \(index + 1)")).post()
        }
    }

    private func zoneCount(_ part: ZonePart) -> Int {
        switch part {
        case .touchpad: return TouchpadService.shared.allRegions().filter { $0.surface != 1 }.count
        case .leftTrackpad: return TouchpadService.shared.allRegions().filter { $0.surface == 1 }.count
        case .screen: return CursorRegionService.shared.allRegions().count
        case .stick(let s): return stickZones.regions(forStick: s).count
        case .band(let a): return stickZones.regions(forStick: StickRegionService.bandKeyBase + a).count
        }
    }

    /// The line under the title: the parts that have regions, or the parts.
    private func zonesSummary(_ parts: [ZonePart]) -> String {
        let used = parts.filter { zoneCount($0) > 0 }
        if used.isEmpty { return parts.map(partTitle).joined(separator: ", ") }
        return used.map { "\(partTitle($0)) \(zoneCount($0))" }.joined(separator: ", ")
    }

    /// A part's name on this device: a Steam Controller's main touch
    /// surface is its right trackpad.
    private func partTitle(_ part: ZonePart) -> String {
        part == .touchpad && isSteamGroup ? String(localized: "Right trackpad") : part.title
    }

    /// This group reads a Steam Controller, or was made for one.
    private var isSteamGroup: Bool {
        !scaffoldCapabilities.trackpads.isEmpty || effectiveButtonFamily?.isSteam == true
    }

    @ViewBuilder
    private func zoneEditor(_ part: ZonePart) -> some View {
        switch part {
        case .touchpad:
            TouchpadCalibrationView(embedded: true, steam: isSteamGroup)
        case .leftTrackpad:
            TouchpadCalibrationView(embedded: true, surface: 1, steam: true)
        case .screen:
            CursorRegionsView(embedded: true)
        case .stick(let s):
            StickRegionsView(startKey: s, slot: deviceSlot, embedded: true,
                             partRows: partRows(part), onJumpToRow: jumpToRow)
        case .band(let axis):
            StickRegionsView(startKey: StickRegionService.bandKeyBase + axis, slot: deviceSlot, embedded: true,
                             partRows: partRows(part), onJumpToRow: jumpToRow)
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation { joystick.isExpanded.toggle() }
            } label: {
                Image(systemName: joystick.isExpanded ? "chevron.down" : "chevron.forward")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(joystick.isExpanded ? String(localized: "Collapse \(resolvedHeaderName)") : String(localized: "Expand \(resolvedHeaderName)"))

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    // Slot identity picker - tap to bind this slot to a
                    // specific detected device, or set a custom name.
                    deviceMenu
                    // What the group is actually reading: the device picked
                    // from the menu when it is connected, else the slot's
                    // own controller. A slot with no controller says so
                    // quietly, unless the group is MIDI / keyboard / mouse.
                    if let waiting = waitingFor {
                        // Pinned to a controller that is away while another
                        // is here: say so, with the one-click way out.
                        Text("Waiting for \(waiting)")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                        Button("Use the connected controller") {
                            // Set to the pad here that no other group reads:
                            // Auto-detect read this group's own slot, often
                            // an empty one.
                            // Every pad here read by another group: the pin
                            // stays, rather than being cleared for nothing.
                            guard let name = standInPadName() else {
                                GameControllerService.sayEveryPadInUse(); return
                            }
                            joystick.customName = name
                            joystick.inputKind = .controller
                        }
                        .buttonStyle(.link)
                        .font(.callout)
                        .help("Sets this input device to the controller connected now")
                    } else if joystick.customName != nil, !GameControllerService.isNoControllerName(deviceSubtitle) {
                        Text(deviceSubtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if GameControllerService.isNoControllerName(controllerName) && !isDeviceIndependentGroup {
                        Text("No controller in this slot")
                            .font(.callout)
                            .foregroundStyle(.red.opacity(0.7))
                            .lineLimit(1)
                    }
                }
                TextField("What this device does in the preset (optional)", text: .shippedText($joystick.tag))
                    .font(.callout)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // One quiet menu instead of a row of icons.
            deviceActionsMenu
                .popover(isPresented: $showStickSettings, arrowEdge: .bottom) {
                    stickSettingsPopover
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.2))
    }

    // MARK: - Every control, in sections

    /// What the slot's device reports right now, read through the services.
    /// The slot whose device this group is set up for: the one picked from
    /// the device menu when that device is connected, otherwise this
    /// group's own position. Everything about the device (the inventory,
    /// the inserted rows, the name under the header) follows this.
    /// What sits under the name in the header: the connected device this
    /// group reads, with what it offers, so switching device updates here
    /// as well as in the rows.
    private var deviceSubtitle: String {
        let caps = scaffoldCapabilities
        if caps.note != nil { return controllerName }
        return caps.summary.isEmpty ? caps.deviceName : "\(caps.deviceName): \(caps.summary)"
    }

    /// The controller this group is pinned to while it is away and another
    /// one is connected; the group reads nothing until one of them changes.
    private var waitingFor: String? {
        guard deviceSlot == GameControllerService.noSlot, joystick.inputKind == .controller,
              !controllerService.controllerDetails.isEmpty else { return nil }
        return joystick.shownCustomName
    }

    private var deviceSlot: Int {
        resolvedSlot ?? controllerService.effectiveSlot(for: joystick, groupIndex: joystickIndex)
    }

    private var scaffoldCapabilities: ControllerScaffold.DeviceCapabilities {
        ControllerScaffold.capabilities(service: controllerService, slot: deviceSlot,
                                        inputKind: joystick.inputKind, presetFamily: presetFamily)
    }

    private var scaffoldDeviceName: String { scaffoldCapabilities.deviceName }

    /// The line under the insert button. With nothing connected the rows
    /// come from the layout the preset was made for (or a standard one),
    /// and the line says so instead of claiming a detected device.
    private var scaffoldPrompt: String {
        let caps = scaffoldCapabilities
        if caps.isEmpty { return caps.note ?? String(localized: "Nothing to insert for this device.") }
        let device = [caps.deviceArticle, caps.deviceName].filter { !$0.isEmpty }.joined(separator: " ")
        if caps.note != nil {
            return String(localized: "No controller is connected to this slot. Inserting adds the rows of \(device): \(caps.summary).")
        }
        let detected = String(localized: "InputConfig has detected \(device), which has \(caps.summary).")
        return caps.limitation.map { detected + " " + $0 } ?? detected
    }

    private var scaffoldControls: [ControllerScaffold.Control] {
        ControllerScaffold.controls(for: scaffoldCapabilities)
    }

    /// The inventory line under the prompt: what the device presents, and
    /// why the list is short when it is.
    private var scaffoldSummary: String {
        let caps = scaffoldCapabilities
        var text = caps.summary
        if let note = caps.note { text = text.isEmpty ? note : text + ". " + note }
        return text
    }

    /// Everything that used to be a row of icons on the header: inserting
    /// inputs, sections, sorting, stick settings, duplicate, remove.
    private var deviceActionsMenu: some View {
        Menu {
            Button("Automatically insert available inputs") { addScaffold(scaffoldControls) }
                .disabled(scaffoldControls.isEmpty)
            Menu("Insert one part") {
                ForEach(ControllerScaffold.sections(of: scaffoldControls), id: \.self) { section in
                    Button(ControllerScaffold.shownSection(section)) { addScaffold(scaffoldControls.filter { $0.section == section }) }
                }
            }
            .disabled(scaffoldControls.isEmpty)
            Button("New section…") {
                newSectionName = ""
                newSectionPopoverOpen = true
            }
            Divider()
            Button("Sort rows into sections") { sortIntoSections() }
                .disabled(joystick.bindings.isEmpty)
            Button("Sort rows by input") {
                preSortSnapshot = joystick.bindings
                onSortBindings()
                postSortSnapshot = joystick.bindings
            }
            .disabled(joystick.bindings.isEmpty)
            if preSortSnapshot != nil, postSortSnapshot == joystick.bindings {
                Button("Undo sort") {
                    if let snapshot = preSortSnapshot {
                        withAnimation { joystick.bindings = snapshot }
                        preSortSnapshot = nil
                        postSortSnapshot = nil
                    }
                }
            }
            Divider()
            Button("Stick settings…") {
                if let dz = joystick.bindings.first(where: {
                    $0.input.type == .axis && $0.deadzone != nil
                })?.deadzone {
                    bulkDeadzone = Double(dz)
                }
                showStickSettings = true
            }
            Divider()
            Button("Duplicate this input device", action: onDuplicate)
            Button("Remove this input device", role: .destructive, action: onRemoveJoystick)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Insert inputs, sections, sorting, stick settings, duplicate, or remove")
        .accessibilityLabel("Input device actions")
        .popover(isPresented: $newSectionPopoverOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("New section")
                    .font(.callout.weight(.semibold))
                TextField("e.g. Camera", text: $newSectionName)
                    .accessibilityLabel("Section name")
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit { commitNewSection() }
                HStack {
                    Spacer()
                    Button("Cancel") { newSectionPopoverOpen = false }
                        .buttonStyle(.solidSecondaryCompact)
                    Button("Add") { commitNewSection() }
                        .buttonStyle(.solid)
                        .disabled(newSectionName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(14)
        }
    }

    private func addScaffold(_ controls: [ControllerScaffold.Control]) {
        let rows = ControllerScaffold.bindings(for: controls, existing: joystick.bindings)
        guard !rows.isEmpty else { return }
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { joystick.bindings.append(contentsOf: rows) }
        // The button that was pressed is gone now, so say what happened.
        AccessibilityNotification.Announcement(rows.count == 1 ? String(localized: "Added 1 row")
                                               : String(localized: "Added \(rows.count) rows")).post()
    }

    private func sortIntoSections() {
        preSortSnapshot = joystick.bindings
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { joystick.bindings = ControllerScaffold.grouped(joystick.bindings, family: effectiveButtonFamily, headings: scaffoldCapabilities.buttonHeadings) }
        postSortSnapshot = joystick.bindings
    }

    /// A section is its rows, so a new one starts with one blank row.
    private func commitNewSection() {
        let name = newSectionName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        newSectionPopoverOpen = false
        var row = BindingModel(input: InputEvent.button(0), outputs: [])
        row.section = name
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { joystick.bindings.append(row) }
        AccessibilityNotification.Announcement(String(localized: "Section \(name) added with one row")).post()
    }

    /// Indices of the run of rows sharing the section that starts at `start`.
    private func sectionRun(startingAt start: Int) -> Range<Int> {
        guard joystick.bindings.indices.contains(start) else { return start..<start }
        let name = joystick.bindings[start].section
        var end = start
        while end < joystick.bindings.count, joystick.bindings[end].section == name { end += 1 }
        return start..<end
    }

    private func renameSection(startingAt start: Int, from old: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // A late commit (Save while the name was still being typed) after
        // rows moved or the heading went: only the heading it was typed on.
        guard joystick.bindings.indices.contains(start), joystick.bindings[start].section == old else { return }
        for i in sectionRun(startingAt: start) { joystick.bindings[i].section = trimmed }
    }

    private func dissolveSection(startingAt start: Int) {
        for i in sectionRun(startingAt: start) { joystick.bindings[i].section = nil }
        AccessibilityNotification.Announcement(String(localized: "Heading removed, rows kept")).post()
    }

    private func addRow(toSectionEndingAt end: Int) {
        var start = end
        while start > 0, joystick.bindings[start - 1].section == joystick.bindings[end].section { start -= 1 }
        let run = sectionRun(startingAt: start)
        var row = BindingModel(input: InputEvent.button(0), outputs: [])
        row.section = joystick.bindings[start].section
        withAnimation { joystick.bindings.insert(row, at: run.upperBound) }
        AccessibilityNotification.Announcement(String(localized: "Row \(run.upperBound + 1) added to section \(ControllerScaffold.shownSection(row.section ?? ""))")).post()
    }

    // MARK: - Stick settings (bulk deadzone)

    private var axisBindingIndices: [Int] {
        joystick.bindings.indices.filter { joystick.bindings[$0].input.type == .axis }
    }

    private var stickSettingsPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Stick Settings")
                .font(.headline)
            Text("Sets the inner deadzone for every axis binding in this joystick in one move. Individual bindings can still be fine-tuned afterwards in their Options.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Slider(value: $bulkDeadzone, in: 0.01...0.9) {
                    Text("Deadzone")
                }
                .accessibilityValue("\(Int(bulkDeadzone * 100)) percent")
                Text("\(Int(bulkDeadzone * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38 * max(1, textScale), alignment: .trailing)
            }
            HStack {
                if axisBindingIndices.isEmpty {
                    Text("No axis bindings in this joystick yet.")
                        .font(.caption2)
                        .foregroundStyle(.hint)
                }
                Spacer()
                Button(axisBindingIndices.count == 1 ? String(localized: "Apply to 1 axis binding") : String(localized: "Apply to \(axisBindingIndices.count) axis bindings")) {
                    for i in axisBindingIndices {
                        joystick.bindings[i].deadzone = Float(bulkDeadzone)
                    }
                    showStickSettings = false
                }
                .buttonStyle(.solidCompact)
                .disabled(axisBindingIndices.isEmpty)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    /// Display name shown in the header chip. Priority:
    ///   1. user-set customName
    ///   2. controllerName (passed in by the editor - reflects the
    ///      controller actually attached to this slot)
    ///   3. fallback to "Input Device N"
    private var resolvedHeaderName: String {
        if let custom = joystick.shownCustomName, !custom.isEmpty { return custom }
        if let mac = joystick.macInputName { return mac }
        let trimmed = controllerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && !GameControllerService.isNoControllerName(trimmed) { return trimmed }
        // "Joystick" was misleading: a group can hold MIDI, keyboard, and
        // mouse bindings that have nothing to do with a gamepad.
        return String(localized: "Input Device \(joystickIndex)")
    }

    /// True when every binding in this group comes from a source that does
    /// not need a game controller in this slot (MIDI, keyboard, mouse, and
    /// cursor zones). Used to suppress the "no controller" warning, which
    /// otherwise reads as an error to someone mapping a MIDI keyboard.
    private var isDeviceIndependentGroup: Bool {
        guard !joystick.bindings.isEmpty else { return false }
        return joystick.bindings.allSatisfy { b in
            switch b.input.type {
            case .midi, .extKey, .extMouse, .cursorRegion: return true
            default: return false
            }
        }
    }

    /// Tap-to-pick menu replacing the previous bare TextField. Lists
    /// every input device the app knows about (GameController-framework
    /// controllers, raw HID gamepads, attached keyboards, attached
    /// mice) so the user can label this slot with the device they
    /// want it to represent. "Set custom name…" opens an inline
    /// popover with a TextField for free-form labels.
    /// Pre-computed device lists pulled out of the Menu's MenuBuilder
    /// closure. Inline `let` + `filter` chains inside @ViewBuilder /
    /// @MenuBuilder bodies stalls the Swift type-checker; computed
    /// properties give it a fixed shape to reason about.
    private var connectedControllerNames: [String] {
        #if DEBUG
        // The marketing capture's synthetic pads, which have no GCController.
        if controllerService.debugMarketingFakeActive, controllerService.connectedControllers.isEmpty {
            return controllerService.controllerDetails.keys.sorted()
                .filter { controllerService.rawHIDGamepadSlots[$0] == nil }
                .compactMap { controllerService.controllerDetails[$0]?.name }
        }
        #endif
        return controllerService.connectedControllers.map { gc in
            gc.vendorName ?? gc.productCategory
        }
    }

    /// In slot order, so "Name 2" here is the pad matchingSlots calls
    /// "Name 2". Attach order drifted from it once the slots moved.
    private var rawHIDNames: [String] {
        let slotted = controllerService.rawHIDGamepadSlots.sorted { $0.key < $1.key }.map(\.value)
        let ids = Set(slotted.map(\.id))
        return (slotted + rawHIDService.connectedGamepads.filter { !ids.contains($0.id) }).map(\.displayName)
            + controllerService.racingWheelNames.map(\.name)
    }

    private var steamConnected: Bool { controllerService.steamControllerSlot != nil }

    /// One transport's devices from InputConfig ▸ Devices, each usable
    /// from here: a gamepad already being read is picked as a controller;
    /// one the app is not reading yet is connected by hand and picked; a
    /// keyboard, mouse, or headset picks the matching Mac input path.
    @ViewBuilder
    private func transportSection(_ transport: HIDDeviceRegistry.Transport) -> some View {
        let entries = deviceRegistry.entries(on: transport)
        // A Logitech wheel for Xbox is read through macOS racing wheel
        // support: not an HID entry, but plugged in over USB. Picked under
        // Game controllers.
        let wheels = transport == .usb ? controllerService.racingWheelNames : []
        Section(transport.title) {
            if entries.isEmpty && wheels.isEmpty {
                Text(transport.emptyText)
            }
            ForEach(wheels, id: \.slot) { wheel in
                Text("\(wheel.name) (read through macOS racing wheel support)")
            }
            ForEach(entries) { entry in
                if let reason = entry.unreadableReason {
                    // Not something to pick as keyboard input: say what to
                    // do instead, as the Devices menu does.
                    Text("\(entry.name) (\(reason))")
                } else if !rawHIDService.isReading(anyOf: deviceRegistry.devices(for: entry)),
                   rawHIDService.isAwaitingInputMonitoring(anyOf: deviceRegistry.devices(for: entry)) {
                    // Waiting for Input Monitoring: ask for it here too.
                    Button("\(entry.name) (needs Input Monitoring)\u{2026}") {
                        RawHIDGamepadService.requestInputMonitoring()
                    }
                } else if entry.isSteamController {
                    // Picked under Game controllers; as a mouse it sends
                    // nothing while a preset runs.
                    Text("\(entry.name) (read automatically as a Steam Controller)")
                } else if entry.adoptableKind != nil {
                    let device = deviceRegistry.adoptableDevice(for: entry)
                    let reading = rawHIDService.isReading(anyOf: deviceRegistry.devices(for: entry))
                    // GameController already reads it (a DualSense, an Xbox
                    // pad): it is under Game controllers, and connecting it
                    // here would be refused. Picking it just names the slot,
                    // as the Devices menu says.
                    let ownedBySystem = !reading
                        && device.map { rawHIDService.isListedByGameController($0) } == true
                    if reading || ownedBySystem {
                        Button(ownedBySystem ? String(localized: "\(entry.name) (read by macOS GameController)") : entry.name) {
                            joystick.customName = ownedBySystem
                                ? (device.flatMap { rawHIDService.gameControllerName(for: $0) } ?? entry.name)
                                : (readName(for: entry) ?? entry.name)
                            joystick.inputKind = .controller
                        }
                    } else if let device, RawHIDGamepadService.blockedByInputMonitoring(device) {
                        // Opening it needs Input Monitoring: ask, as the
                        // Devices menu does. Connect did nothing here.
                        Button("\(entry.name) (needs Input Monitoring)\u{2026}") {
                            _ = rawHIDService.adopt(device)
                            RawHIDGamepadService.requestInputMonitoring()
                        }
                    } else {
                        Button("Connect \(entry.name)") { connect(entry) }
                    }
                } else {
                    switch entry.primaryKind {
                    case .keyboard, .consumer:
                        Button("\(entry.name) (keyboard input)") {
                            joystick.customName = entry.name
                            joystick.inputKind = .keyboard
                        }
                    case .pointer:
                        Button("\(entry.name) (mouse input)") {
                            joystick.customName = entry.name
                            joystick.inputKind = .mouse
                        }
                    default:
                        Text(entry.name)
                    }
                }
            }
        }
    }

    /// The names with repeats numbered from 2, in order.
    static func numberedNames(_ names: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return names.map { name in
            let n = (seen[name] ?? 0) + 1
            seen[name] = n
            return n == 1 ? name : "\(name) \(n)"
        }
    }

    /// Open the device by hand (same as InputConfig ▸ Devices) and point
    /// this slot at it.
    private func connect(_ entry: HIDDeviceRegistry.Entry) {
        // The slot points at the device only once it is really being read:
        // a refused or failed open left a slot named after a device that
        // sent nothing, with nothing on screen to say why.
        guard let device = deviceRegistry.adoptableDevice(for: entry),
              rawHIDService.adopt(device) || rawHIDService.isReading(anyOf: deviceRegistry.devices(for: entry))
        else { return }
        joystick.customName = readName(for: entry) ?? entry.name
        joystick.inputKind = .controller
    }

    /// The name a pad being read raw goes by under Game controllers (its
    /// profile's name, numbered as that list numbers it), so a pick from
    /// the USB or Bluetooth list pins the slot that reads it.
    private func readName(for entry: HIDDeviceRegistry.Entry) -> String? {
        let keys = Set(deviceRegistry.devices(for: entry).compactMap { RawHIDGamepadService.deviceKey($0) })
        let slotted = controllerService.rawHIDGamepadSlots.sorted { $0.key < $1.key }.map(\.value)
        let ids = Set(slotted.map(\.id))
        let pads = slotted + rawHIDService.connectedGamepads.filter { !ids.contains($0.id) }
        guard let at = pads.firstIndex(where: { keys.contains($0.id) }) else { return nil }
        let gc = connectedControllerNames
        let names = Self.numberedNames(gc + pads.map(\.displayName))
        return gc.count + at < names.count ? names[gc.count + at] : nil
    }

    private var keyboardNames: [String] {
        externalDevices.filter { $0.kind == .keyboard }.map(\.productName)
    }

    private var mouseNames: [String] {
        externalDevices.filter { $0.kind == .mouse }.map(\.productName)
    }

    @ViewBuilder
    private var deviceMenu: some View {
        Menu {
            Button("Auto-detect (\(controllerName))") {
                joystick.customName = nil
                joystick.inputKind = .auto
            }
            Divider()
            // Everything the app can hear from, by where it comes from.
            Section("Game controllers") {
                if connectedControllerNames.isEmpty && rawHIDNames.isEmpty && !steamConnected {
                    Text("None connected")
                }
                // Two of the same controller are numbered ("Xbox Wireless
                // Controller 2"), and the number picks that pad; the same
                // name twice could only ever read the first.
                ForEach(Array(Self.numberedNames(connectedControllerNames + rawHIDNames).enumerated()),
                        id: \.offset) { _, name in
                    Button(name) {
                        joystick.customName = name
                        joystick.inputKind = .controller
                    }
                }
                if steamConnected {
                    Button("Steam Controller") {
                        joystick.customName = "Steam Controller"
                        joystick.inputKind = .controller
                    }
                }
            }
            transportSection(.bluetooth)
            transportSection(.usb)
            if !deviceRegistry.entries(on: .other).isEmpty {
                transportSection(.other)
            }
            Section("Keyboard and mouse") {
                // The event taps hear every keyboard and mouse, so these
                // are always here, connected or not.
                Button("This Mac's keyboard (any keyboard)") {
                    joystick.customName = "Keyboard"
                    joystick.inputKind = .keyboard
                }
                Button("This Mac's mouse or trackpad (any mouse)") {
                    joystick.customName = "Mouse"
                    joystick.inputKind = .mouse
                }
            }
            Section("Screen") {
                // The display as an input: screen regions the pointer
                // enters. Listed as its own device so a screen preset is
                // never labeled with whichever controller is plugged in.
                Button("This Mac's displays (screen regions)") {
                    joystick.customName = "Screen"
                    joystick.inputKind = .screen
                }
            }
            Section("MIDI") {
                let sources = MIDIInputService.shared.connectedDevices()
                if sources.isEmpty {
                    Text("No MIDI sources connected")
                } else {
                    ForEach(sources) { source in
                        Button(source.name) {
                            joystick.customName = source.name
                            joystick.inputKind = .midi
                        }
                    }
                }
            }
            Divider()
            Button("Set custom name…") {
                // The name the header shows ("Clavier" for This Mac's keyboard).
                renameDraft = joystick.shownCustomName ?? ""
                renamePopoverOpen = true
            }
        } label: {
            HStack(spacing: 4) {
                Text(resolvedHeaderName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(joystick.customName == nil ? .secondary : .primary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.hint)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose a detected device or set a custom name for this slot.")
        // The group's name: a heading for the VoiceOver rotor.
        .accessibilityAddTraits(.isHeader)
        .spotlightAnchor(SpotlightID.slotChip)
        .popover(isPresented: $renamePopoverOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Slot name")
                    .font(.headline)
                TextField("e.g. Player 1, Steve", text: $renameDraft)
                    .accessibilityLabel("Slot name")
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                // The name is also how a group set to one controller finds it.
                if joystick.inputKind == .controller, joystick.customName != nil {
                    Text("This input device reads its controller by this name. A new name reads the controller in its own slot instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 220, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Cancel") { renamePopoverOpen = false }
                        .buttonStyle(.solidSecondaryCompact)
                    Spacer()
                    Button("Save") {
                        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        // Unchanged, the stored English stays: it also picks the device by name.
                        if trimmed != joystick.shownCustomName {
                            joystick.customName = trimmed.isEmpty ? nil : trimmed
                        }
                        renamePopoverOpen = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.solid)
                }
            }
            .padding(12)
        }
    }

    /// Follows the pointer and works out where the row would land.
    ///
    /// Deliberately does NOT touch `joystick.bindings` while the drag is in
    /// flight. Reordering the array mid-drag rebuilds every row view, which
    /// is both the stutter and the reason a dropped row used to stick: the
    /// rebuild tore down the very gesture that was driving the drag, so its
    /// `onEnded` never arrived and the row kept its lifted offset. Instead the
    /// dragged row is offset under the pointer, its neighbors slide aside to
    /// open a gap, and the array is reordered exactly once, on drop.
    /// Follows the pointer, decides where the row would land, and opens a gap
    /// there.
    ///
    /// Two things this deliberately does not do. It does not touch
    /// `joystick.bindings` while the drag is in flight: reordering mid-drag
    /// rebuilds every row, which stutters, and tears down the gesture driving
    /// the drag so its `onEnded` never arrives and the row sticks where it was
    /// dropped. And it does not put the moving offset in state this view
    /// observes: that re-ran all of the group's rows on every pointer frame,
    /// which is unusable once a row is expanded. Each row owns a small
    /// `RowLift` instead, so a drag frame re-renders exactly one row.
    private func dragRow(_ id: UUID, at index: Int, by translation: CGFloat) {
        if rowDrag.draggingID != id, rowHeights[id] == nil { return }

        if rowDrag.draggingID != id {
            rowDrag.draggingID = id
            rowDrag.targetID = id
            rowDrag.fromIndex = index
            rowDrag.toIndex = index
            // Snapshot every row's resting position for the whole drag.
            // `rowHeights` is measured by a GeometryReader that sits inside
            // the drag offset, so once rows start sliding aside their
            // measurements slide with them - reading those live made the
            // target feed on its own output and jump to the wrong slot.
            rowDrag.homeFrames = rowHeights.snapshot()
            // The gap this row leaves behind is its own full height, so rows
            // of any size - including an expanded one - move by the right
            // amount.
            rowDrag.step = (rowDrag.homeFrames[id]?.height ?? 0) + Self.rowSpacing
            rowDrag.lift(for: id).lifted = true
        }

        // Collapsing the row's Options at drag start changes its height and
        // shifts everything under it, so re-take the snapshot the first time
        // the measured height disagrees with it.
        if let live = rowHeights[id], let snap = rowDrag.homeFrames[id],
           abs(live.height - snap.height) > 0.5 {
            rowDrag.homeFrames = rowHeights.snapshot()
            rowDrag.step = live.height + Self.rowSpacing
        }

        guard let home = rowDrag.homeFrames[id] else { return }

        rowDrag.lift(for: id).y = translation

        // Where the row's center now sits, compared against every other row's
        // measured position. Row tops and heights are read from the layout
        // itself, so a tall expanded row is handled the same as a short one.
        // The landing index is the number of OTHER rows whose middle sits
        // above the center. Counting the dragged row itself made any upward
        // jitter aim one slot too high, and a drag above the first row
        // opened the gap at the top but dropped back home.
        let center = home.midY + translation
        let target = joystick.bindings.filter { b in
            guard b.id != id, let f = rowDrag.homeFrames[b.id] else { return false }
            return f.midY < center
        }.count
        let targetID = target < joystick.bindings.count && target != rowDrag.fromIndex
            ? joystick.bindings[target].id : id

        if rowDrag.toIndex != target {
            rowDrag.toIndex = target
            rowDrag.targetID = targetID
            openGap()
        }
    }

    /// Slides the rows between the row's home slot and its landing slot, so
    /// the gap is always where the row will end up.
    private func openGap() {
        let from = rowDrag.fromIndex
        let to = rowDrag.toIndex
        for (i, b) in joystick.bindings.enumerated() where b.id != rowDrag.draggingID {
            let shift: CGFloat
            if to > from, i > from, i <= to {
                shift = -rowDrag.step
            } else if to < from, i >= to, i < from {
                shift = rowDrag.step
            } else {
                shift = 0
            }
            let lift = rowDrag.lift(for: b.id)
            if lift.y != shift {
                withAnimation(.easeInOut(duration: 0.14)) { lift.y = shift }
            }
        }
    }

    /// Commits the drag. The move and the offset reset happen in one
    /// animation-free transaction: the row is already sitting in the gap, so
    /// snapping it into that slot is invisible.
    private func dropRow() {
        let draggedID = rowDrag.draggingID
        let targetID = rowDrag.targetID
        rowDrag.draggingID = nil
        rowDrag.homeFrames = [:]

        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            for b in joystick.bindings {
                let lift = rowDrag.lift(for: b.id)
                lift.y = 0
                lift.lifted = false
            }
            // Resolve by identity at commit time. Indices captured when the
            // drag started can be stale by now, and a stale index reorders
            // the wrong row.
            guard let draggedID, let targetID, draggedID != targetID,
                  let from = joystick.bindings.firstIndex(where: { $0.id == draggedID }),
                  let to = joystick.bindings.firstIndex(where: { $0.id == targetID })
            else { return }
            joystick.bindings.move(fromOffsets: IndexSet(integer: from),
                                   toOffset: to > from ? to + 1 : to)
            // A row dropped among other rows takes their section, so the
            // headings stay one run per section.
            if let landed = joystick.bindings.firstIndex(where: { $0.id == draggedID }) {
                let above = landed > 0 ? joystick.bindings[landed - 1].section : nil
                let below = landed + 1 < joystick.bindings.count ? joystick.bindings[landed + 1].section : nil
                // Its own section is kept when a neighbor shares it, so a
                // row can be dropped as the first of a later section.
                let own = joystick.bindings[landed].section
                if own != above && own != below {
                    joystick.bindings[landed].section = landed > 0 ? above : below
                }
            }
        }
    }

    /// Move a row one place up or down, taking its new neighbors' section
    /// the way a drop does.
    private func moveRow(_ id: UUID, by step: Int) {
        guard let from = joystick.bindings.firstIndex(where: { $0.id == id }) else { return }
        let to = from + step
        guard joystick.bindings.indices.contains(to) else { return }
        // At a section edge one step crosses into the next section and the
        // row stays put; otherwise it trades places with its neighbor.
        let neighborSection = joystick.bindings[to].section
        if neighborSection != joystick.bindings[from].section {
            joystick.bindings[from].section = neighborSection
            AccessibilityNotification.Announcement(neighborSection.map { String(localized: "Moved to section \($0)") } ?? String(localized: "Moved to section none")).post()
            return
        }
        joystick.bindings.swapAt(from, to)
        AccessibilityNotification.Announcement(String(localized: "Moved to row \(to + 1)")).post()
    }

    private static let listSpace = "bindingList"
    private static let rowSpacing: CGFloat = 2

    /// Looks the row up by id, not by index: a text field that commits
    /// while its row is being removed would otherwise trap past the end,
    /// or write its value into the row that moved into that slot.
    private func bindingAt(_ index: Int) -> SwiftUI.Binding<BindingModel> {
        let snapshot = joystick.bindings[index]
        let id = snapshot.id
        return SwiftUI.Binding(
            get: { joystick.bindings.first(where: { $0.id == id }) ?? snapshot },
            set: { newValue in
                guard let i = joystick.bindings.firstIndex(where: { $0.id == id }) else { return }
                joystick.bindings[i] = newValue
            }
        )
    }
}

/// Equatable shell around BindingRowView.
///
/// BindingRowView's init takes closures (onScan/onRemove/onDuplicate), which
/// SwiftUI's memberwise diffing cannot compare, so it conservatively re-ran
/// every row body whenever the parent re-evaluated. The parent observes three
/// live services (engine highlight set, controller raw-active set, external
/// input set) that publish up to 30 Hz while inputs fire, which multiplied
/// into every heavy row body re-running and the whole editor sheet
/// re-measuring layout on each publish: the main thread pinned at 90%+ CPU
/// with an editor open while a preset was active.
///
/// EquatableView compares ONLY the value inputs below (the closures are
/// deliberately excluded), so rows whose data and highlight state did not
/// change skip body evaluation and keep their cached layout.
private struct EquatableBindingRow: View, Equatable {
    @SwiftUI.Binding var binding: BindingModel
    /// Value snapshot of the model captured by the parent at render time.
    /// The == below must compare snapshots, NOT `binding.wrappedValue`:
    /// old and new views' bindings read the same underlying storage, so
    /// wrappedValue would always compare equal and edits would never
    /// re-render the row.
    let snapshot: BindingModel
    /// The row's serialized input, the key it lights on.
    let liveKey: LiveRowLights.RowLight
    let displayNumber: Int
    /// A zone row's overlapping direction rows, by number (empty otherwise).
    let zoneOverlap: [Int]
    /// A zone row's overlapping zone rows, by number (empty otherwise).
    let zoneZoneOverlap: [Int]
    /// A direction row's zone rows that take it over, by number.
    let zoneTakenBy: [Int]
    let isPulsing: Bool
    let takesFocus: Bool
    let extraButtons: [GameControllerService.ExtraButton]
    let availablePresets: [(id: UUID, name: String)]
    let slot: Int
    let faceChoice: String
    let onScan: () -> Void
    let onScanModifier: (Int?) -> Void
    let onRemove: () -> Void
    let onDuplicate: () -> Void
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void
    let onMove: (Int) -> Void

    // nonisolated: Equatable's requirement is not actor-isolated, and the
    // comparison touches only Sendable value-type stored properties (the
    // @Binding and closures are deliberately not compared).
    nonisolated static func == (l: Self, r: Self) -> Bool {
        l.snapshot == r.snapshot
            && l.liveKey == r.liveKey
            && l.displayNumber == r.displayNumber
            && l.zoneOverlap == r.zoneOverlap
            && l.zoneZoneOverlap == r.zoneZoneOverlap
            && l.zoneTakenBy == r.zoneTakenBy
            && l.isPulsing == r.isPulsing
            && l.takesFocus == r.takesFocus
            && l.extraButtons == r.extraButtons
            && l.slot == r.slot
            && l.faceChoice == r.faceChoice
            && l.availablePresets.count == r.availablePresets.count
            && l.availablePresets.elementsEqual(r.availablePresets) {
                $0.id == $1.id && $0.name == $1.name
            }
    }

    /// Lit while the row's input fires, set from this row's own key only,
    /// so a press re-renders one row and not the list.
    @State private var lit = false

    var body: some View {
        BindingRowView(
            binding: $binding,
            onScan: onScan,
            onScanModifier: onScanModifier,
            onRemove: onRemove,
            onDuplicate: onDuplicate,
            onDragChanged: onDragChanged,
            onDragEnded: onDragEnded,
            onMove: onMove,
            isHighlighted: lit,
            displayNumber: displayNumber,
            zoneOverlap: zoneOverlap,
            zoneZoneOverlap: zoneZoneOverlap,
            zoneTakenBy: zoneTakenBy,
            isPulsing: isPulsing,
            takesFocus: takesFocus,
            extraButtons: extraButtons,
            availablePresets: availablePresets,
            slot: slot
        )
        // Keyed by the input, so a row whose input changes (a scan, a new
        // type or index) listens for the new one at once.
        .task(id: liveKey) {
            for await on in LiveRowLights.shared.publisher(for: liveKey).values {
                lit = on
                #if DEBUG
                LiveRowLights.shared.debugRowsLit[liveKey] = on
                #endif
            }
        }
    }
}

/// Which inputs are firing, handed to each editor row for its own key
/// only. Merges the raw controller set, the running preset's set, the
/// Mac's keyboard and mouse, and Tap the Mac, and tells a row only when its
/// key turns on or off, so scrolling the list (a live mouse input) or
/// moving a stick re-renders the rows that change and nothing else.
@MainActor
final class LiveRowLights {
    static let shared = LiveRowLights()
    private var lit: Set<String> = []
    private var subjects: [RowLight: CurrentValueSubject<Bool, Never>] = [:]

    /// When an editor row lights, by the rules the engine fires by: its
    /// input and every control it holds with it (Second control) are down,
    /// no chord on the same input holding more of those controls is fully
    /// held, and, for a row with no held controls, no chord on the same
    /// input is fully held (the engine leaves the plain row quiet then).
    /// Lit from the input alone, a plain row and a chord row on one button
    /// both lit, and nothing showed which one fires.
    struct RowLight: Hashable, Sendable {
        let input: String
        /// The raw key that means this row is down: its own input, or for an
        /// inverted axis or motion row the opposite direction, which is what
        /// the controller reports when the engine fires the row.
        let rawInput: String
        let held: [String]
        /// The held controls of every other row in the group on this input
        /// that holds any.
        let rivals: [[String]]

        init(_ row: BindingModel, in rows: [BindingModel], inputKey: String) {
            input = inputKey
            var raw = inputKey
            if row.input.type == .axis || row.input.type == .stickRegion {
                // Lit at the row's own deadzone (the editor's live preview of
                // the deadzone sheet included), not at the raw set's fixed
                // half way: GameControllerService.liveAxisRows sets this key.
                raw = GameControllerService.axisRowKey(row.id)
            } else if row.invertAxis == true, [.motion, .touchpad].contains(row.input.type),
               row.input.axisDirection != .none {
                var flipped = row.input
                flipped.axisDirection = row.input.axisDirection == .positive ? .negative : .positive
                raw = flipped.serialized
            }
            rawInput = raw
            held = row.modifiers.map(\.serialized)
            rivals = rows.filter { $0.id != row.id && !$0.modifiers.isEmpty && $0.input.serialized == inputKey }
                .map { $0.modifiers.map(\.serialized) }
        }

        /// `down` holds the raw keys as they are and the engine's firing
        /// rows' keys marked with a leading "!".
        func isLit(_ down: Set<String>) -> Bool {
            func on(_ key: String) -> Bool { down.contains(key) || down.contains("!" + key) }
            guard down.contains(rawInput) || down.contains("!" + input), held.allSatisfy(on) else { return false }
            let mine = Set(held)
            return !rivals.contains { rival in
                let theirs = Set(rival)
                return rival.allSatisfy(on) && (mine.isEmpty || theirs.isStrictSuperset(of: mine))
            }
        }

        /// Every key this row's light depends on.
        func reads(_ changed: Set<String>) -> Bool {
            func touched(_ key: String) -> Bool { changed.contains(key) || changed.contains("!" + key) }
            return touched(input) || changed.contains(rawInput) || held.contains(where: touched)
                || rivals.contains { $0.contains(where: touched) }
        }
    }
    private var subscription: AnyCancellable?

    private init() {
        subscription = Publishers.CombineLatest4(LiveInputStore.shared.$raw, LiveInputStore.shared.$active,
                                                 ExternalInputDeviceService.shared.$rawActiveInputs,
                                                 ChassisTapActivity.shared.$activeKeys)
            .sink { [weak self] raw, active, external, taps in
                // The engine's set is marked, so an inverted row lights by
                // what fires it, not by the raw direction it inverts.
                MainActor.assumeIsolated { self?.update(raw.union(active.map { "!" + $0 }).union(external).union(taps)) }
            }
    }

    /// Drops every key once the editor closes: rows are only in the
    /// editor, and keys piled up across a session, each walked on every
    /// live-input change.
    func reset() {
        subjects.removeAll()
        #if DEBUG
        debugRowsLit.removeAll()
        #endif
    }

    func publisher(for key: RowLight) -> AnyPublisher<Bool, Never> {
        let subject = subjects[key] ?? {
            let made = CurrentValueSubject<Bool, Never>(key.isLit(lit))
            subjects[key] = made
            return made
        }()
        return subject.removeDuplicates().eraseToAnyPublisher()
    }

    #if DEBUG
    /// For the debug hook: what is lit and which keys rows listen for.
    var debugState: String {
        "rowLights lit=\(lit.sorted()) listening=\(subjects.keys.map(\.input).sorted()) rowsLit=\(debugRowsLit.filter(\.value).keys.map(\.input).sorted())"
    }
    var debugRowsLit: [RowLight: Bool] = [:]
    #endif

    private func update(_ now: Set<String>) {
        guard now != lit else { return }
        let changed = lit.symmetricDifference(now)
        lit = now
        // Only rows that read a control that changed: their input, a held
        // control, or a rival's held control. The publisher drops repeats.
        for (key, subject) in subjects where key.reads(changed) {
            subject.send(key.isLit(now))
        }
    }
}


// MARK: - Reordering by drag

/// Live reorder: as the dragged row's handle passes over another row, the
/// array is rearranged immediately, so the row follows the pointer. Drop
/// just ends the drag; the order is already right.
/// Mutable, non-observed store of measured row frames. See the comment on
/// `rowHeights` in `JoystickGroupView` for why this is not `@State` data.
final class RowFrameStore {
    private var frames: [UUID: CGRect] = [:]
    subscript(id: UUID) -> CGRect? {
        get { frames[id] }
        set { frames[id] = newValue }
    }
    func snapshot() -> [UUID: CGRect] { frames }
}

// MARK: - Row drag

/// One row's visual displacement. Published on its own so that moving a row
/// re-renders that row's lift modifier and nothing else - the row's body does
/// not re-run, and neither do the other rows'.
final class RowLift: ObservableObject {
    @Published var y: CGFloat = 0
    @Published var lifted = false
}

/// Drag bookkeeping. Held by `JoystickGroupView` as plain `@State`, so the
/// group never observes it and a drag never re-renders the group.
final class RowDragState {
    var draggingID: UUID?
    /// Row the dragged one will land on, tracked by identity so the commit
    /// never depends on an index captured earlier.
    var targetID: UUID?
    /// Resting positions of every row, snapshotted when the drag starts.
    var homeFrames: [UUID: CGRect] = [:]
    var fromIndex = 0
    var toIndex = 0
    /// Full pitch of the dragged row: how far the rows it passes step aside.
    var step: CGFloat = 0

    private var lifts: [UUID: RowLift] = [:]

    func lift(for id: UUID) -> RowLift {
        if let existing = lifts[id] { return existing }
        let made = RowLift()
        lifts[id] = made
        return made
    }
}

/// Lifts a row out of the list: it follows the pointer, casts a shadow, and
/// draws above its neighbors.
private struct RowDragLift: ViewModifier {
    @ObservedObject var lift: RowLift

    func body(content: Content) -> some View {
        content
            .offset(y: lift.y)
            .shadow(color: .black.opacity(lift.lifted ? 0.28 : 0),
                    radius: lift.lifted ? 8 : 0,
                    y: lift.lifted ? 4 : 0)
            .zIndex(lift.lifted ? 1 : 0)
    }
}


/// The close of a section, under its last row: a line from the left to the
/// plus at the right, which adds a row at the end of the section.
struct SectionEndRow: View {
    let name: String
    let onAddRow: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: 1)
            Button(action: onAddRow) {
                Image(systemName: "plus.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Add a row to this section")
            .accessibilityLabel("Add a row to section \(ControllerScaffold.shownSection(name))")
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }
}

/// The heading above a run of rows that share a section. Click the name to
/// rename it; the x lifts the heading off its rows (the rows stay). The
/// plus that adds a row sits at the section's end (SectionEndRow).
struct SectionHeadingRow: View {
    let name: String
    let onRename: (String) -> Void
    let onDissolve: () -> Void

    @State private var editing = false
    @State private var draft = ""
    /// This heading's own key for the editor's inline-edit hooks: two
    /// headings of one name (in two groups) cleared each other's.
    @State private var editKey = "section:" + UUID().uuidString
    @FocusState private var focused: Bool
    /// Return hands focus back to the heading's button.
    @FocusState private var headingFocused: Bool

    var body: some View {
        // Each render hands its own commit on, which renames the rows the
        // heading has now.
        let _ = editing ? EditorInlineEdit.refreshCommit(editKey) { commit() } : ()
        HStack(spacing: 8) {
            if editing {
                TextField("Section name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.callout.weight(.semibold))
                    .focused($focused)
                    .onSubmit {
                        commit()
                        DispatchQueue.main.async { headingFocused = true }
                    }
                    .onChange(of: focused) { _, f in if !f { commit() } }
                    .frame(maxWidth: 240)
            } else {
                Button {
                    draft = ControllerScaffold.shownSection(name)
                    editing = true
                    DispatchQueue.main.async { focused = true }
                    EditorInlineEdit.begin(editKey, onCommit: { commit() }) {
                        draft = ControllerScaffold.shownSection(name)
                        editing = false
                        DispatchQueue.main.async { headingFocused = true }
                        return true
                    }
                } label: {
                    Text(ControllerScaffold.shownSection(name))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .focused($headingFocused)
                .help("Rename this section")
                .accessibilityAddTraits(.isHeader)
            }
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: 1)
            Button(action: onDissolve) {
                Image(systemName: "xmark.circle")
                    .font(.callout)
                    .foregroundStyle(.hint)
            }
            .buttonStyle(.plain)
            .help("Remove this heading (the rows stay)")
            .accessibilityLabel("Remove heading \(ControllerScaffold.shownSection(name)), keep its rows")
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Section \(ControllerScaffold.shownSection(name))")
        // Removed while being typed in (its x, or the group removed): its
        // hooks go with it, or Save renamed whatever rows took its place.
        .onDisappear { if editing { EditorInlineEdit.clear(editKey) } }
    }

    private func commit() {
        guard editing else { return }
        editing = false
        EditorInlineEdit.clear(editKey)
        // Left unchanged, a heading keeps its English key, which the rows
        // are grouped by, rather than taking the shown translation.
        guard draft != ControllerScaffold.shownSection(name) else { return }
        onRename(draft)
    }
}
