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
    /// Scan for a row's chord control (the second input it must hold).
    var onScanModifierInput: (Int) -> Void = { _ in }
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
    /// The live sets that light a row, observed here and nowhere else.
    @ObservedObject private var liveInputs = LiveInputStore.shared
    @ObservedObject private var tapActivity = ChassisTapActivity.shared
    @ObservedObject private var rawHIDService = RawHIDGamepadService.shared
    @ObservedObject private var deviceRegistry = HIDDeviceRegistry.shared
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
    /// Inline rename popover state for the "Custom name…" menu item.
    @State private var renamePopoverOpen: Bool = false
    @State private var renameDraft: String = ""
    /// Stick Settings popover: set the deadzone across every axis binding
    /// in this joystick in one move instead of expanding each row's Options.
    @State private var showStickSettings = false
    @State private var newSectionPopoverOpen = false
    @State private var newSectionName = ""
    @State private var bulkDeadzone: Double = 0.25

    /// Space between binding boxes, and from the boxes to the group's edge.
    static let rowGap: CGFloat = 6
    static let rowInset: CGFloat = 8

    var body: some View {
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
                        Color.clear.frame(width: Self.rowInset + BindingRowView.inputBracketLeading, height: 1)
                        BracketHeader(title: "Input", font: .callout.weight(.semibold))
                            .frame(width: BindingRowView.inputBracketWidth)
                        Color.clear.frame(width: BindingRowView.outputBracketLeading
                                          - BindingRowView.inputBracketLeading
                                          - BindingRowView.inputBracketWidth, height: 1)
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
                    ForEach(joystick.bindings.indices, id: \.self) { index in
                        let binding = joystick.bindings[index]
                        // A heading above the first row of each run of rows
                        // that share a section name.
                        if let section = binding.section, !section.isEmpty,
                           index == 0 || joystick.bindings[index - 1].section != section {
                            SectionHeadingRow(
                                name: section,
                                onRename: { renameSection(startingAt: index, to: $0) },
                                onAddRow: { addRow(toSectionStartingAt: index) },
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
                            // Light up against raw controller state OR the
                            // engine's preset-aware set, whichever is firing.
                            // This works even with no preset active.
                            isHighlighted:
                                liveInputs.active.contains(inputKey)
                                || liveInputs.raw.contains(inputKey)
                                || externalInput.rawActiveInputs.contains(inputKey)
                                || tapActivity.activeKeys.contains(inputKey),
                            displayNumber: index + 1,
                            isPulsing: pulsingBindingID == binding.id,
                            // Named extras (paddles/FN/mute/Home) for the
                            // slot's connected controller, passed by value so
                            // BindingRowView doesn't need to subscribe to
                            // the service itself.
                            extraButtons: rowExtras,
                            availablePresets: availablePresets,
                            slot: joystickIndex,
                            onScan: { onScanInput(index) },
                            onScanModifier: { onScanModifierInput(index) },
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
                .padding(.horizontal, Self.rowInset)
                .padding(.vertical, Self.rowGap)
                // Suppress implicit transitions on row insertion/removal so
                // scrolling does not trigger animation work for new rows.
                .animation(nil, value: joystick.bindings.count)
                .coordinateSpace(name: Self.listSpace)

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
                        Text(caps.isEmpty
                             ? (caps.note ?? "Nothing to insert for this device.")
                             : "InputConfig has detected \(caps.deviceArticle) \(caps.deviceName), which has \(caps.summary).")
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
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation { joystick.isExpanded.toggle() }
            } label: {
                Image(systemName: joystick.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(joystick.isExpanded ? "Collapse joystick group" : "Expand joystick group")

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    // Slot identity picker - tap to bind this slot to a
                    // specific detected device, or set a custom name.
                    deviceMenu
                    // What the group is actually reading: the device picked
                    // from the menu when it is connected, else the slot's
                    // own controller. A slot with no controller says so
                    // quietly, unless the group is MIDI / keyboard / mouse.
                    if joystick.customName != nil, !deviceSubtitle.contains("No controller") {
                        Text("· \(deviceSubtitle)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if controllerName.contains("No controller") && !isDeviceIndependentGroup {
                        Text("· no controller in this slot")
                            .font(.callout)
                            .foregroundStyle(.red.opacity(0.7))
                            .lineLimit(1)
                    }
                }
                TextField("What this device does in the preset (optional)", text: $joystick.tag)
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

    private var deviceSlot: Int {
        controllerService.effectiveSlot(for: joystick, groupIndex: joystickIndex)
    }

    private var scaffoldCapabilities: ControllerScaffold.DeviceCapabilities {
        ControllerScaffold.capabilities(service: controllerService, slot: deviceSlot,
                                        inputKind: joystick.inputKind)
    }

    private var scaffoldDeviceName: String { scaffoldCapabilities.deviceName }

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
                    Button(section) { addScaffold(scaffoldControls.filter { $0.section == section }) }
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
            }
            .disabled(joystick.bindings.isEmpty)
            if preSortSnapshot != nil {
                Button("Undo sort") {
                    if let snapshot = preSortSnapshot {
                        withAnimation { joystick.bindings = snapshot }
                        preSortSnapshot = nil
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
    }

    private func sortIntoSections() {
        preSortSnapshot = joystick.bindings
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { joystick.bindings = ControllerScaffold.grouped(joystick.bindings) }
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
    }

    /// Indices of the run of rows sharing the section that starts at `start`.
    private func sectionRun(startingAt start: Int) -> Range<Int> {
        guard joystick.bindings.indices.contains(start) else { return start..<start }
        let name = joystick.bindings[start].section
        var end = start
        while end < joystick.bindings.count, joystick.bindings[end].section == name { end += 1 }
        return start..<end
    }

    private func renameSection(startingAt start: Int, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        for i in sectionRun(startingAt: start) { joystick.bindings[i].section = trimmed }
    }

    private func dissolveSection(startingAt start: Int) {
        for i in sectionRun(startingAt: start) { joystick.bindings[i].section = nil }
    }

    private func addRow(toSectionStartingAt start: Int) {
        let run = sectionRun(startingAt: start)
        var row = BindingModel(input: InputEvent.button(0), outputs: [])
        row.section = joystick.bindings[start].section
        withAnimation { joystick.bindings.insert(row, at: run.upperBound) }
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
    /// want it to represent. "Set custom name…" opens an inline
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

    private var steamConnected: Bool { controllerService.steamControllerSlot != nil }

    /// One transport's devices from InputConfig ▸ Devices, each usable
    /// from here: a gamepad already being read is picked as a controller;
    /// one the app is not reading yet is connected by hand and picked; a
    /// keyboard, mouse, or headset picks the matching Mac input path.
    @ViewBuilder
    private func transportSection(_ transport: HIDDeviceRegistry.Transport) -> some View {
        let entries = deviceRegistry.entries(on: transport)
        Section(transport.rawValue) {
            if entries.isEmpty {
                Text("No \(transport.rawValue) devices")
            }
            ForEach(entries) { entry in
                if entry.adoptableKind != nil {
                    if rawHIDService.isReading(vendorID: entry.vendorID, productID: entry.productID) {
                        Button(entry.name) {
                            joystick.customName = entry.name
                            joystick.inputKind = .controller
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

    /// Open the device by hand (same as InputConfig ▸ Devices) and point
    /// this slot at it.
    private func connect(_ entry: HIDDeviceRegistry.Entry) {
        if let device = deviceRegistry.adoptableDevice(for: entry) {
            rawHIDService.adopt(device)
        }
        joystick.customName = entry.name
        joystick.inputKind = .controller
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
            // Everything the app can hear from, by where it comes from.
            Section("Game controllers") {
                if connectedControllerNames.isEmpty && rawHIDNames.isEmpty && !steamConnected {
                    Text("None connected")
                }
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
                // never labelled with whichever controller is plugged in.
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
                renameDraft = joystick.customName ?? ""
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

        // Where the row's center now sits, compared against every other row's
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
            // A row dropped among other rows takes their section, so the
            // headings stay one run per section.
            if let landed = joystick.bindings.firstIndex(where: { $0.id == draggedID }) {
                let above = landed > 0 ? joystick.bindings[landed - 1].section : nil
                let below = landed + 1 < joystick.bindings.count ? joystick.bindings[landed + 1].section : nil
                joystick.bindings[landed].section = landed > 0 ? above : below
            }
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
    let slot: Int
    let onScan: () -> Void
    let onScanModifier: () -> Void
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
            && l.slot == r.slot
            && l.availablePresets.count == r.availablePresets.count
            && l.availablePresets.elementsEqual(r.availablePresets) {
                $0.id == $1.id && $0.name == $1.name
            }
    }

    var body: some View {
        BindingRowView(
            binding: $binding,
            onScan: onScan,
            onScanModifier: onScanModifier,
            onRemove: onRemove,
            onDuplicate: onDuplicate,
            onDragChanged: onDragChanged,
            onDragEnded: onDragEnded,
            isHighlighted: isHighlighted,
            displayNumber: displayNumber,
            isPulsing: isPulsing,
            extraButtons: extraButtons,
            availablePresets: availablePresets,
            slot: slot
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


/// The heading above a run of rows that share a section. Click the name to
/// rename it; the plus adds a row to the section; the x lifts the heading
/// off its rows (the rows stay).
struct SectionHeadingRow: View {
    let name: String
    let onRename: (String) -> Void
    let onAddRow: () -> Void
    let onDissolve: () -> Void

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            if editing {
                TextField("Section name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.callout.weight(.semibold))
                    .focused($focused)
                    .onSubmit { commit() }
                    .onChange(of: focused) { _, f in if !f { commit() } }
                    .frame(maxWidth: 240)
            } else {
                Button {
                    draft = name
                    editing = true
                    DispatchQueue.main.async { focused = true }
                } label: {
                    Text(name)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Rename this section")
            }
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
            Button(action: onDissolve) {
                Image(systemName: "xmark.circle")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Remove this heading (the rows stay)")
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Section \(name)")
    }

    private func commit() {
        guard editing else { return }
        editing = false
        onRename(draft)
    }
}
