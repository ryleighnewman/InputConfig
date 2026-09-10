import SwiftUI

/// A joystick group showing its header and list of bindings.
/// Observes mappingEngine directly so highlight state updates in real-time.
struct JoystickGroupView: View {
    @SwiftUI.Binding var joystick: JoystickMapping
    let joystickIndex: Int
    let controllerName: String
    let onAddBinding: () -> Void
    let onRemoveBinding: (Int) -> Void
    let onDuplicateBinding: (Int) -> Void
    let onScanInput: (Int) -> Void
    let onSortBindings: () -> Void
    let onDuplicate: () -> Void
    let onRemoveJoystick: () -> Void
    /// Binding UUID currently pulsing (jump-to-binding from Live Visualizer).
    /// nil when no pulse is active.
    var pulsingBindingID: UUID? = nil

    /// Preset list for the App Action target picker, passed as plain values
    /// so the row views stay store-subscription free.
    var availablePresets: [(id: UUID, name: String)] = []

    @EnvironmentObject var mappingEngine: MappingEngine
    @EnvironmentObject var controllerService: GameControllerService
    @ObservedObject private var rawHIDService = RawHIDGamepadService.shared
    @ObservedObject private var externalInput = ExternalInputDeviceService.shared
    /// The binding being dragged by its handle, if any.
    /// Live row-reorder state. Held as plain `@State` (not `@StateObject`) so
    /// this group does NOT observe it: a drag updates 120 times a second, and
    /// re-running the group body that often would re-serialize every row's
    /// input key on every frame. Only the small per-row offset modifier
    /// observes it.
    @State private var rowDrag = RowDragState()
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
    /// Inline rename popover state for the "Custom name..." menu item.
    @State private var renamePopoverOpen: Bool = false
    @State private var renameDraft: String = ""
    /// Stick Settings popover: set the deadzone across every axis binding
    /// in this joystick in one move instead of expanding each row's Options.
    @State private var showStickSettings = false
    @State private var bulkDeadzone: Double = 0.25

    var body: some View {
        VStack(spacing: 0) {
            headerView

            if joystick.isExpanded {
                // Compute the per-slot extras snapshot ONCE per render and reuse
                // it for every row. extraButtonsSnapshot maps + sorts cached data
                // under a lock, so calling it once per binding row turned the
                // editor render into an O(rows) hot path (the biggest UI-lag
                // contributor while a preset with many binds is open).
                let extras = controllerService.extraButtonsSnapshot(for: joystickIndex)
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
                VStack(spacing: 2) {
                    ForEach(joystick.bindings.indices, id: \.self) { index in
                        let binding = joystick.bindings[index]
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
                            // Light up against raw controller state OR the
                            // engine's preset-aware set, whichever is firing.
                            // This works even with no preset active.
                            isHighlighted:
                                mappingEngine.activeInputsPublished.contains(inputKey)
                                || controllerService.rawActiveInputs.contains(inputKey)
                                || externalInput.rawActiveInputs.contains(inputKey),
                            displayNumber: index + 1,
                            isPulsing: pulsingBindingID == binding.id,
                            // Named extras (paddles/FN/mute/Home) for the
                            // slot's connected controller, passed by value so
                            // BindingRowView doesn't need to subscribe to
                            // the service itself.
                            extraButtons: rowExtras,
                            availablePresets: availablePresets,
                            onScan: { onScanInput(index) },
                            onRemove: { onRemoveBinding(index) },
                            onDuplicate: { onDuplicateBinding(index) },
                            onDragChanged: { dy in dragRow(binding.id, at: index, by: dy) },
                            onDragEnded: { dropRow() }
                        )
                        .equatable()
                        .id(binding.id)
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
                    }
                }
                .padding(.vertical, 2)
                // Suppress implicit transitions on row insertion/removal so
                // scrolling does not trigger animation work for new rows.
                .animation(nil, value: joystick.bindings.count)
                .coordinateSpace(name: Self.listSpace)

                Button(action: onAddBinding) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.green)
                        Text("Add a new bind")
                            .font(.caption)
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
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation { joystick.isExpanded.toggle() }
            } label: {
                Image(systemName: joystick.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(joystick.isExpanded ? "Collapse joystick group" : "Expand joystick group")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    // Slot identity picker - tap to bind this slot to a
                    // specific detected device, or set a custom name.
                    // Currently this view doesn't own the assignment
                    // (slot index → device) so the picker primarily acts
                    // on the human-readable name; future work threads
                    // a real binding through, e.g. by storing the
                    // selected device's persistentIdentifier in
                    // JoystickMapping.
                    deviceMenu
                    Text("#\(joystickIndex)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    if !(controllerName.contains("No controller") && isDeviceIndependentGroup) {
                        Text(controllerName)
                            .font(.caption2)
                            .foregroundStyle(controllerName.contains("No controller") ? .red.opacity(0.6) : .secondary)
                            .lineLimit(1)
                    }
                }
                TextField("Tag / comment", text: $joystick.tag)
                    .font(.caption)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 4) {
                Button {
                    preSortSnapshot = joystick.bindings
                    onSortBindings()
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Sort bindings")
                .accessibilityLabel("Sort bindings")

                if preSortSnapshot != nil {
                    Button {
                        if let snapshot = preSortSnapshot {
                            withAnimation { joystick.bindings = snapshot }
                            preSortSnapshot = nil
                        }
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .help("Undo sort")
                    .accessibilityLabel("Undo sort")
                }

                Button {
                    // Open on the current value: seed from the first axis
                    // binding that has an explicit deadzone set.
                    if let dz = joystick.bindings.first(where: {
                        $0.input.type == .axis && $0.deadzone != nil
                    })?.deadzone {
                        bulkDeadzone = Double(dz)
                    }
                    showStickSettings = true
                } label: {
                    Image(systemName: "dial.low")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Stick settings: set the deadzone for every axis binding at once")
                .accessibilityLabel("Stick settings")
                .accessibilityHint("Sets the deadzone for every axis binding in this joystick at once.")
                .popover(isPresented: $showStickSettings, arrowEdge: .bottom) {
                    stickSettingsPopover
                }

                CopyIconButton(action: onDuplicate,
                               helpText: "Clone this joystick group",
                               size: .caption)

                Button(action: onRemoveJoystick) {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Remove this joystick group")
                .accessibilityLabel("Remove joystick group")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.2))
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
                Slider(value: $bulkDeadzone, in: 0...0.9) {
                    Text("Deadzone")
                }
                .accessibilityValue("\(Int(bulkDeadzone * 100)) percent")
                Text("\(Int(bulkDeadzone * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
            HStack {
                if axisBindingIndices.isEmpty {
                    Text("No axis bindings in this joystick yet.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Apply to \(axisBindingIndices.count) axis binding\(axisBindingIndices.count == 1 ? "" : "s")") {
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
        if let custom = joystick.customName, !custom.isEmpty { return custom }
        let trimmed = controllerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && !trimmed.contains("No controller") { return trimmed }
        // "Joystick" was misleading: a group can hold MIDI, keyboard, and
        // mouse bindings that have nothing to do with a gamepad.
        return "Input Device \(joystickIndex)"
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
    /// want it to represent. "Set custom name..." opens an inline
    /// popover with a TextField for free-form labels.
    /// Pre-computed device lists pulled out of the Menu's MenuBuilder
    /// closure. Inline `let` + `filter` chains inside @ViewBuilder /
    /// @MenuBuilder bodies stalls the Swift type-checker; computed
    /// properties give it a fixed shape to reason about.
    private var connectedControllerNames: [String] {
        controllerService.connectedControllers.map { gc in
            gc.vendorName ?? gc.productCategory
        }
    }

    private var rawHIDNames: [String] {
        rawHIDService.connectedGamepads.map(\.displayName)
    }

    private var keyboardNames: [String] {
        externalInput.devices.filter { $0.kind == .keyboard }.map(\.productName)
    }

    private var mouseNames: [String] {
        externalInput.devices.filter { $0.kind == .mouse }.map(\.productName)
    }

    @ViewBuilder
    private var deviceMenu: some View {
        Menu {
            Button("Auto-detect (\(controllerName))") {
                joystick.customName = nil
                joystick.inputKind = .auto
            }
            Divider()
            Section("Game controllers") {
                ForEach(Array(connectedControllerNames.enumerated()),
                        id: \.offset) { _, name in
                    Button(name) {
                        joystick.customName = name
                        joystick.inputKind = .controller
                    }
                }
                ForEach(Array(rawHIDNames.enumerated()),
                        id: \.offset) { _, name in
                    Button(name) {
                        joystick.customName = name
                        joystick.inputKind = .controller
                    }
                }
            }
            Section("Keyboards") {
                ForEach(Array(keyboardNames.enumerated()),
                        id: \.offset) { _, name in
                    Button(name) {
                        joystick.customName = name
                        joystick.inputKind = .keyboard
                    }
                }
            }
            Section("Mice") {
                ForEach(Array(mouseNames.enumerated()),
                        id: \.offset) { _, name in
                    Button(name) {
                        joystick.customName = name
                        joystick.inputKind = .mouse
                    }
                }
            }
            Divider()
            Button("Set custom name…") {
                renameDraft = joystick.customName ?? ""
                renamePopoverOpen = true
            }
        } label: {
            HStack(spacing: 4) {
                Text(resolvedHeaderName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(joystick.customName == nil ? .secondary : .primary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose a detected device or set a custom name for this slot.")
        .spotlightAnchor(SpotlightID.slotChip)
        .popover(isPresented: $renamePopoverOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Slot name")
                    .font(.headline)
                TextField("e.g. Player 1 - Steve", text: $renameDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                HStack {
                    Button("Cancel") { renamePopoverOpen = false }
                        .buttonStyle(.solidSecondaryCompact)
                    Spacer()
                    Button("Save") {
                        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        joystick.customName = trimmed.isEmpty ? nil : trimmed
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
    /// dragged row is offset under the pointer, its neighbours slide aside to
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

        // Where the row's centre now sits, compared against every other row's
        // measured position. Row tops and heights are read from the layout
        // itself, so a tall expanded row is handled the same as a short one.
        let centre = home.midY + translation
        var target = 0
        var targetID = id
        for (i, b) in joystick.bindings.enumerated() {
            guard let f = rowDrag.homeFrames[b.id] else { continue }
            if centre >= f.midY {
                target = i
                targetID = b.id
            } else {
                break
            }
        }

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
        }
    }

    private static let listSpace = "bindingList"
    private static let rowSpacing: CGFloat = 2

    private func bindingAt(_ index: Int) -> SwiftUI.Binding<BindingModel> {
        SwiftUI.Binding(
            get: { joystick.bindings[index] },
            set: { joystick.bindings[index] = $0 }
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
    let isHighlighted: Bool
    let displayNumber: Int
    let isPulsing: Bool
    let extraButtons: [GameControllerService.ExtraButton]
    let availablePresets: [(id: UUID, name: String)]
    let onScan: () -> Void
    let onRemove: () -> Void
    let onDuplicate: () -> Void
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void

    // nonisolated: Equatable's requirement is not actor-isolated, and the
    // comparison touches only Sendable value-type stored properties (the
    // @Binding and closures are deliberately not compared).
    nonisolated static func == (l: Self, r: Self) -> Bool {
        l.snapshot == r.snapshot
            && l.isHighlighted == r.isHighlighted
            && l.displayNumber == r.displayNumber
            && l.isPulsing == r.isPulsing
            && l.extraButtons == r.extraButtons
            && l.availablePresets.count == r.availablePresets.count
            && l.availablePresets.elementsEqual(r.availablePresets) {
                $0.id == $1.id && $0.name == $1.name
            }
    }

    var body: some View {
        BindingRowView(
            binding: $binding,
            onScan: onScan,
            onRemove: onRemove,
            onDuplicate: onDuplicate,
            onDragChanged: onDragChanged,
            onDragEnded: onDragEnded,
            isHighlighted: isHighlighted,
            displayNumber: displayNumber,
            isPulsing: isPulsing,
            extraButtons: extraButtons,
            availablePresets: availablePresets
        )
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
/// draws above its neighbours.
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
