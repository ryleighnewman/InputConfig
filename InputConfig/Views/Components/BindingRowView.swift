import SwiftUI
import Combine

/// A single binding row with fixed-width columns for consistent alignment.
struct BindingRowView: View {
    @SwiftUI.Binding var binding: BindingModel
    let onScan: () -> Void
    /// Scan for the chord's second control (any input on any device).
    var onScanModifier: () -> Void = {}
    let onRemove: () -> Void
    var onDuplicate: (() -> Void)?
    /// Starts a reorder drag from the handle. Owned by the group, which
    /// holds the array being reordered.
    /// Live reorder callbacks from the drag handle. Vertical translation in
    /// points, then a single end call. The parent owns the ordering.
    var onDragChanged: ((CGFloat) -> Void)? = nil
    var onDragEnded: (() -> Void)? = nil
    var isHighlighted: Bool = false
    /// 1-based position of this binding within its joystick group. Drives the
    /// "#N" chip at the start of every row so the Live Visualizer can refer
    /// to a specific row by number.
    var displayNumber: Int = 0
    /// True while this row is the target of a jump-to-binding pulse triggered
    /// by clicking on the Live Visualizer. Shows a yellow ring for ~1.2 s.
    var isPulsing: Bool = false

    /// Named extra buttons exposed by the controller for this slot.
    /// Passed in as a plain value type by the parent so we don't have
    /// to inject `GameControllerService` as an `@EnvironmentObject` -
    /// avoids a strict-concurrency boundary and keeps this view
    /// trivially previewable. Empty when no controller is connected or
    /// the slot has no extras.
    var extraButtons: [GameControllerService.ExtraButton] = []

    /// Preset list for the App Action output's target picker, passed as
    /// plain values for the same previewability reason as extraButtons.
    var availablePresets: [(id: UUID, name: String)] = []

    /// Your Shortcuts and applications, already loaded. The output menu
    /// lists both, and reading them on the spot would run a subprocess and
    /// a folder scan on the main thread while the menu is being built.
    @ObservedObject private var systemLists = SystemListsCache.shared

    /// Joystick slot this row's group belongs to, for the live motion meter
    /// on gyro rows.
    var slot: Int = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    @State private var showAdvanced = false
    @State private var showMacroEditor = false
    @State private var liveOuterDeadzone: Double?
    @State private var showDeadzoneCalibration = false
    /// Region editors opened straight from the input pickers, so defining a
    /// missing cursor/stick region doesn't require a detour through Settings.
    @State private var showCursorRegionsEditor = false
    @State private var showStickRegionsEditor = false
    /// Drives the firing arrow's left-to-right sweep while highlighted.
    @State private var arrowShoot = false

    /// Live mirrors of slider values, updated every drag tick so the value
    /// shown next to each slider follows the thumb in real time. The
    /// underlying BindingModel still only commits on slider release to keep
    /// the editor's re-render chain off the per-frame hot path.
    @State private var liveSpeed: [Int: Double] = [:]
    @State private var liveHaptic: Double?
    @State private var liveHapticDuration: Double?
    @State private var liveDeadzone: Double?

    // Fixed column widths for perfect alignment
    private let dragWidth: CGFloat = 20
    private let numberColWidth: CGFloat = 40
    /// Where sub-rows (note, Options) start: under the Scan column, past the
    /// handle and the number, so every line of the row shares one left edge.
    private var leftGutter: CGFloat {
        dragWidth + colGap + (displayNumber > 0 ? numberColWidth + colGap : 0)
    }
    private let scanColWidth: CGFloat = 54
    /// Wider than before (was 78) so the full input-type names like
    /// "Keyboard Key", "Cursor Region", "Stick Region" actually show
    /// in the picker label instead of getting truncated to "Keyboa…"
    /// which made the picker look locked.
    private let typeColWidth: CGFloat = 116
    private let indexColWidth: CGFloat = 124
    /// Wider than before (was 58) because for extKey / extMouse this
    /// column hosts the device picker, and device names like
    /// "Built-in Keyboard" overflowed and visually collided with the
    /// next column's keyboard icon.
    private let dirColWidth: CGFloat = 130
    private let arrowWidth: CGFloat = 24
    /// Wide enough for "Mission Control" and "Speak Selection" next to their
    /// icon without truncating to "Mission Cont…".
    private let outTypeColWidth: CGFloat = 156
    /// The one horizontal gap used everywhere on the primary row: between
    /// the boxes and the arrow, between controls inside a box, and between
    /// an output's icon and its menu. Consistent spacing is what makes the
    /// two halves read as the same kind of thing.
    private let gap: CGFloat = 8
    /// Every output icon sits in a cell this wide, scaled to fit, so a wide
    /// symbol (Mission Control) and a narrow one (a lock) leave the same
    /// distance to the menu after them.
    private let iconCell: CGFloat = 18
    private let actionsWidth: CGFloat = 48
    private let colGap: CGFloat = 8

    /// Total width of input columns (for sub-row indentation)
    private var inputColumnsWidth: CGFloat {
        dragWidth + numberColWidth + scanColWidth + typeColWidth + indexColWidth + dirColWidth + arrowWidth + colGap * 7
    }

    /// Inner padding of the Input and Output boxes.
    static let boxPadH: CGFloat = 8
    static let boxPadV: CGFloat = 4
    /// Left edge of the Input box and its width, for the INPUT / OUTPUT
    /// header the group draws above its rows. Derived from the same column
    /// widths as the row itself, so the header cannot drift.
    static let inputBoxLeading: CGFloat = 10 + 20 + 8 + 40 + 8
    static let inputBoxWidth: CGFloat = 54 + 116 + 124 + 130 + 8 * 3 + boxPadH * 2
    static let arrowSlotWidth: CGFloat = 24 + 8 * 2
    /// The trailing action buttons plus the row's own right padding.
    static let actionsSlotWidth: CGFloat = 48 + 18 + 10
    /// Where the column brackets the group draws above its rows start and
    /// end: the Input bracket runs from just after the number chip to just
    /// before the arrow, the Output bracket from just after the arrow to the
    /// row's right edge. Measured from the row box's left edge.
    static let inputBracketLeading: CGFloat = 10 + 20 + 8 + 30
    static let inputBracketWidth: CGFloat = inputBoxLeading + inputBoxWidth - 4 - inputBracketLeading
    static let outputBracketLeading: CGFloat = inputBoxLeading + inputBoxWidth + arrowSlotWidth + 4
    static let bracketTrailing: CGFloat = 10

    /// No `.onHover` here on purpose. A row-level hover flag looks cheap, but
    /// `@State` on it means every row the pointer crosses re-runs this whole
    /// body - twice, on enter and on exit. While the user scrolls with the
    /// pointer resting over the list, every row that slides underneath gets
    /// rebuilt and re-measured, which re-dirties the layout and the
    /// accessibility responder tree on every frame. That was the choppiness.
    /// Tooltips are attached unconditionally instead: static structure, so a
    /// scrolling row costs nothing beyond moving.
    var body: some View {
        rowBody
    }

    private var rowBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Primary row
            HStack(spacing: colGap) {
                // Drag handle, far left so the row reads handle, number, then
                // the binding itself. This is the only drag source on the
                // row, so menus and text never start a drag by accident.
                // A direct drag gesture, not `.onDrag`. An NSItemProvider drag
                // hands the reorder to AppKit's drag session: the pointer gets
                // a small snapshot of the handle instead of the row, and every
                // reorder decision has to round-trip through a DropDelegate,
                // which is what made dragging feel heavy and detached. The
                // gesture lets the parent lift the whole row under the pointer
                // and move it in place.
                Image(systemName: "line.3.horizontal")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: dragWidth, height: 22)
                    .contentShape(Rectangle())
                    .overlay(
                        // An AppKit tracking view, not a SwiftUI DragGesture.
                        // Two reasons. A SwiftUI gesture is torn down whenever
                        // the row's body re-runs, so anything that changes the
                        // row mid-drag - folding its Options away, the list
                        // reordering - silently cancels the drag and the row
                        // is left stranded. And SwiftUI reports translation in
                        // a space that moves with the row we are offsetting,
                        // which makes the reading feed on its own output and
                        // the row shake. This view persists across body
                        // updates and measures against the screen.
                        RowDragHandle(
                            onBegan: {
                                if showAdvanced {
                                    var t = Transaction()
                                    t.disablesAnimations = true
                                    withTransaction(t) { showAdvanced = false }
                                }
                            },
                            onChanged: { onDragChanged?($0) },
                            onEnded: { onDragEnded?() }
                        )
                    )
                    .help("Drag to reorder")
                    .accessibilityLabel("Reorder handle")

                // Row number chip - matches the number shown in the Live
                // Visualizer popover so users can find the right row when
                // they click an input on the visualizer.
                if displayNumber > 0 {
                    Text("#\(displayNumber)")
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.12))
                        )
                        .frame(width: numberColWidth, alignment: .leading)
                }

                // Non-color firing cue: the green highlight alone isn't
                // distinguishable with Differentiate Without Color on, so add
                // a bolt while the row is firing. VoiceOver already announces
                // the highlight state, hence the hidden marker.
                if isHighlighted && differentiateWithoutColor {
                    Image(systemName: "bolt.fill")
                        .font(.callout)
                        .iconTint(.green)
                        .accessibilityHidden(true)
                }

                // INPUT box: scan + type + index + direction, enclosed so
                // the row reads as "this input" -> "these outputs".
                HStack(spacing: gap) {
                // COL 1: Scan
                Button("Scan", action: onScan)
                    .buttonStyle(.solidSecondaryCompact)
                    .frame(width: scanColWidth, alignment: .center)
                    .accessibilityLabel("Scan binding \(displayNumber)")
                    .accessibilityHint("Press a button, key, or axis on your controller to record this binding")

                // COL 2: Input Type. A lazy Menu (matching KeyCodePicker and
                // the index picker) instead of Picker: NSPopUpButton-backed
                // Pickers pre-build every item on row creation, which made
                // scrolling the binding list hitch as rows materialized.
                // Grouped so the first decision on every row is no longer an
                // undifferentiated 11-item list.
                Menu {
                    Section("Controller") {
                        inputTypeChoice(.button)
                        inputTypeChoice(.axis)
                        inputTypeChoice(.hat)
                    }
                    Section("Touchpad") {
                        inputTypeChoice(.touchpad)
                        inputTypeChoice(.touchpadRegion)
                        inputTypeChoice(.touchpadGesture)
                    }
                    Section("This Mac") {
                        inputTypeChoice(.chassisTap)
                    }
                    Section("Motion") {
                        inputTypeChoice(.motion)
                    }
                    Section("Keyboard and mouse") {
                        inputTypeChoice(.extKey)
                        inputTypeChoice(.extMouse)
                    }
                    Section("Zones") {
                        inputTypeChoice(.cursorRegion)
                        inputTypeChoice(.stickRegion)
                    }
                    Section("MIDI") {
                        inputTypeChoice(.midi)
                    }
                } label: {
                    menuChevronLabel(binding.input.type.displayName)
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .frame(width: typeColWidth, alignment: .leading)
                .accessibilityLabel("Input type")
                .accessibilityValue(binding.input.type.displayName)

                // COL 3: Index
                indexPicker
                    .frame(width: indexColWidth, alignment: .leading)
                    .accessibilityLabel(indexPickerAccessibilityLabel)
                    .accessibilityValue(indexPickerAccessibilityValue)

                // COL 4: Direction (or empty spacer for Button type)
                directionPicker
                    .frame(width: dirColWidth, alignment: .leading)
                    .accessibilityLabel(directionPickerAccessibilityLabel)
                    .accessibilityValue(directionPickerAccessibilityValue)

                }
                .padding(.horizontal, Self.boxPadH)
                .padding(.vertical, Self.boxPadV)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Input")

                // Fixed-position arrow right after the input columns. The two
                // flexible `maxWidth: .infinity` halves that used to center it
                // forced SwiftUI to renegotiate each row's width with repeated
                // sizeThatFits probes; on a large preset that pegged the main
                // thread solid. Only the output side stays flexible now, so the
                // row lays out in a single pass.
                firingArrow

                // OUTPUT box: icon + type + value, with any extra outputs
                // stacked beneath inside the same box. Row actions sit
                // outside it at the trailing edge.
                VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: gap) {
                if binding.outputs.isEmpty {
                    // A row laid out by "every control" waits here for its
                    // output; picking one creates it with that type's
                    // defaults, and the normal controls take over.
                    Menu {
                        outputTypeMenuItems(select: { type in
                            var action = OutputAction(type: .key, keyCode: 4)
                            action.type = type
                            binding.outputs = [action]
                        }, selectSystemKind: { kind in
                            var action = OutputAction(type: .systemAction, keyCode: 4)
                            action.systemActionKind = kind
                            binding.outputs = [action]
                        }, setParameter: { text in
                            guard !binding.outputs.isEmpty else { return }
                            binding.outputs[0].text = text
                        }, setAppAction: { kind, presetID in
                            var action = OutputAction(type: .appAction)
                            action.appActionKind = kind
                            action.targetPresetID = presetID
                            binding.outputs = [action]
                        }, setKey: { code in
                            binding.outputs = [OutputAction(type: .key, keyCode: code)]
                        })
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle")
                            Text("Choose an output")
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .font(.callout)
                        .foregroundStyle(Color.accentColor)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Choose an output")
                }
                if !binding.outputs.isEmpty {
                    HStack(spacing: gap) {
                        outputIconCell(for: binding.outputs[0])

                        Menu {
                            outputTypeMenuItems(select: { firstOutputTypeBinding.wrappedValue = $0 },
                                                selectSystemKind: { kind in
                                                    guard !binding.outputs.isEmpty else { return }
                                                    binding.outputs[0].type = .systemAction
                                                    binding.outputs[0].systemActionKind = kind
                                                },
                                                setParameter: { text in
                                                    guard !binding.outputs.isEmpty else { return }
                                                    binding.outputs[0].text = text
                                                },
                                                setAppAction: { kind, presetID in
                                                    guard !binding.outputs.isEmpty else { return }
                                                    binding.outputs[0].type = .appAction
                                                    binding.outputs[0].appActionKind = kind
                                                    binding.outputs[0].targetPresetID = presetID
                                                },
                                                setKey: { code in
                                                    guard !binding.outputs.isEmpty else { return }
                                                    binding.outputs[0].type = .key
                                                    binding.outputs[0].keyCode = code
                                                })
                        } label: {
                            menuChevronLabel(outputMenuTitle(binding.outputs[0]))
                        }
                        .menuStyle(.borderlessButton)
                        .controlSize(.small)
                        .accessibilityLabel("Output type")
                        .accessibilityValue(binding.outputs[0].type.displayName)
                    }
                    .frame(width: outTypeColWidth, alignment: .leading)

                    // Output value (flexible)
                    outputValueControls(at: 0)

                    if binding.outputs.count > 1 {
                        Button {
                            removeOutput(at: 0)
                        } label: {
                            Image(systemName: "xmark.circle")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove this output")
                    }
                }
                Spacer(minLength: 0)
                }
                secondaryOutputRows
                }
                .padding(.horizontal, Self.boxPadH)
                .padding(.vertical, Self.boxPadV)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Output")

                // Actions
                HStack(spacing: 3) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            binding.outputs.append(OutputAction(type: .key, keyCode: 4))
                        }
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.callout)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .hoverHelp("Add output")
                    .accessibilityLabel("Add output")

                    if let onDuplicate {
                        CopyIconButton(action: onDuplicate,
                                       helpText: "Duplicate this binding")
                            .accessibilityLabel("Duplicate this binding")
                    }

                    Button(action: onRemove) {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red.opacity(0.7))
                            .font(.callout)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove binding")
                }
                .frame(width: actionsWidth + 18, alignment: .trailing)
            }

            // Per-binding note: a short line describing what this control does.
            // Smart presets auto-fill it; users can edit or add their own.
            // Symmetric breathing room so it sits centered between the
            // mapping row above and the Options disclosure below.
            noteRow
                .padding(.vertical, 3)

            // Advanced options
            advancedSection
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHighlighted ? Color.green.opacity(0.18) : Color(nsColor: .controlBackgroundColor).opacity(0.45))
                // Instant fade-in (so quick taps feel snappy), longer fade-out (so the
// green dwell tracks the latched visibility period from
// GameControllerService.rawActiveExpiry).
.animation(isHighlighted ? .linear(duration: 0.0) : .easeOut(duration: 0.18),
           value: isHighlighted)
        )
        .overlay(
            // A hairline edge makes each row its own box even when the fill
            // is close to the sheet behind it.
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isHighlighted ? Color.green.opacity(0.4) : Color.primary.opacity(0.09),
                              lineWidth: isHighlighted ? 1.5 : 1)
                // Instant fade-in (so quick taps feel snappy), longer fade-out (so the
// green dwell tracks the latched visibility period from
// GameControllerService.rawActiveExpiry).
.animation(isHighlighted ? .linear(duration: 0.0) : .easeOut(duration: 0.18),
           value: isHighlighted)
        )
        .overlay(
            // Jump-to-binding pulse: bright yellow ring that fades out
            // after the user clicks an input on the Live Visualizer.
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isPulsing ? Color.yellow.opacity(0.85) : Color.clear, lineWidth: 2.5)
                .animation(.easeOut(duration: 0.6), value: isPulsing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .debugExpandOptions($showAdvanced)
        .modifier(DebugToggleOptionsModifier(displayNumber: displayNumber, toggle: toggleOptions))
        .sheet(isPresented: $showDeadzoneCalibration) {
            DeadzoneCalibrationView(
                axisIndex: binding.input.index,
                deadzone: deadzoneCalibrationBinding,
                outerDeadzone: outerDeadzoneBinding,
                isInverted: binding.invertAxis ?? false,
                onClose: { showDeadzoneCalibration = false }
            )
            .glassBackground()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name("InputConfig.ExpandBindingOptions"))) { note in
            // Tutorial / external trigger to auto-expand this row's
            // Options disclosure so the user sees what's inside
            // without having to click. Notification's object is the
            // target binding's UUID; we only react if it matches us.
            if let id = note.object as? UUID, id == binding.id {
                withAnimation(.easeInOut(duration: 0.4)) { showAdvanced = true }
            }
        }
        .onDisappear {
            // Cancel any in-flight scan when this row goes away.
            // Without this, closing the editor mid-scan leaves the
            // static timer/subscription alive; when its 5-second
            // deadline fires it writes into a `@Binding` whose source
            // is gone, routing the keypress to a stale preset draft.
            Self.cancelActiveScan()
        }
    }

    // MARK: - Per-binding note

    /// Bridges the optional `binding.note` to a non-optional String the
    /// TextField can edit. Writing an all-whitespace value clears it back to
    /// nil so empty notes don't bloat the saved preset.
    private var noteBinding: SwiftUI.Binding<String> {
        SwiftUI.Binding(
            get: { binding.note ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                binding.note = trimmed.isEmpty ? nil : newValue
            }
        )
    }

    /// A subtle inline "what this does" field shown under each binding. It is
    /// always present (so any row can get a note) but stays visually quiet when
    /// empty. Smart presets pre-fill it from the profile so people can read
    /// what every control does right where it is mapped.
    /// Whether the note line shows a live text field. Collapsed rows render
    /// plain Text: AppKit text fields are the most expensive control these
    /// rows create, and materializing one per row made scrolling the binding
    /// list hitch. Clicking the note swaps the field in.
    @State private var editingNote = false
    @FocusState private var noteFieldFocused: Bool

    @ViewBuilder
    private var noteRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: colGap) {
            // "Notes" sits in the number column so the line is labelled the
            // same way the primary row is numbered; the text itself starts
            // under the Scan column.
            Text("Notes")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .frame(width: numberColWidth, alignment: .leading)
            if editingNote {
                TextField("Add a note (what this control does)", text: noteBinding)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .foregroundStyle((binding.note?.isEmpty ?? true) ? .tertiary : .secondary)
                    .lineLimit(1)
                    .focused($noteFieldFocused)
                    .onSubmit { editingNote = false }
                    .onChange(of: noteFieldFocused) { _, focused in
                        if !focused { editingNote = false }
                    }
            } else {
                Button {
                    editingNote = true
                    DispatchQueue.main.async { noteFieldFocused = true }
                } label: {
                    Text((binding.note?.isEmpty ?? true)
                         ? "Add a note (what this control does)"
                         : (binding.note ?? ""))
                        .font(.callout)
                        .foregroundStyle((binding.note?.isEmpty ?? true) ? .tertiary : .secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Note")
                .accessibilityValue((binding.note?.isEmpty ?? true) ? "empty" : (binding.note ?? ""))
                .accessibilityHint("Edit the note for this binding")
            }
        }
        .padding(.leading, dragWidth + colGap)
        .padding(.top, 3)
    }

    // MARK: - Index Picker (fixed width)

    @ViewBuilder
    private var indexPicker: some View {
        switch binding.input.type {
        case .chassisTap:
            Menu {
                Button("Single tap") { binding.input.index = 1 }
                Button("Double tap") { binding.input.index = 2 }
                Button("Triple tap") { binding.input.index = 3 }
                Button("Quadruple tap") { binding.input.index = 4 }
                Button("Quintuple tap") { binding.input.index = 5 }
            } label: {
                menuChevronLabel(chassisTapLabel)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)

        case .button:
            // Three sections in priority order:
            // 1. "This Controller" - dynamically discovered extras
            //    (paddles, FN, mute, Home, touchpad) for the slot's
            //    connected controller. Lets users pick by physical
            //    name instead of guessing the index.
            // 2. "Standard" - canonical MFi labels for the well-known
            //    button indices (A/B/X/Y, LB/RB, Start/Back/Home...).
            // 3. "All Indices" - generic Button 0-63 fallback.
            Menu {
                if !extraButtons.isEmpty {
                    Section("This controller") {
                        // extraButtonsSnapshot already returns the array sorted
                        // by index, so iterate it directly instead of re-sorting
                        // on every row render.
                        ForEach(extraButtons) { extra in
                            Button("\(extra.label) (#\(extra.index))") {
                                binding.input.index = extra.index
                            }
                        }
                    }
                }
                Section("Standard") {
                    ForEach(Self.standardButtonLabels, id: \.index) { entry in
                        Button("\(entry.label) (#\(entry.index))") {
                            binding.input.index = entry.index
                        }
                    }
                }
                Section("All indices") {
                    ForEach(0..<64, id: \.self) { i in
                        Button("Button \(i)") { binding.input.index = i }
                    }
                }
            } label: {
                menuLabel(buttonMenuLabel(for: binding.input.index))
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

        case .axis:
            Menu {
                ForEach(0..<16, id: \.self) { i in
                    Button("Axis #\(i)") { binding.input.index = i }
                }
            } label: {
                menuLabel("Axis #\(binding.input.index)")
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

        case .hat:
            Picker("", selection: $binding.input.index) {
                ForEach(0..<16, id: \.self) { i in
                    Text("Hat #\(i)").tag(i)
                }
            }
            .labelsHidden()
            .controlSize(.small)

        case .touchpad:
            // Touchpad "index" represents the finger slot (0 or 1).
            Picker("", selection: touchpadFingerBinding) {
                Text("Finger 1").tag(0)
                Text("Finger 2").tag(1)
            }
            .labelsHidden()
            .controlSize(.small)

        case .motion:
            // Pick the motion channel. Menu items use the long
            // `menuDescription` ("Gyro Z (roll rate)") so users
            // recognize the axis, but the closed-button label shows
            // the short `displayName` ("Gyro Z") so it fits the
            // fixed-width index column without overlapping the next
            // column.
            Menu {
                ForEach(MotionChannel.allCases) { channel in
                    Button(channel.menuDescription) {
                        binding.input.motionChannel = channel
                    }
                }
            } label: {
                menuLabel((binding.input.motionChannel ?? .gyroY).displayName)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

        case .touchpadRegion:
            // Pick from defined regions by name. If none are defined yet, the
            // menu shows a hint so users know to open Calibrate Touchpad.
            Menu {
                let regions = TouchpadService.shared.allRegions()
                if regions.isEmpty {
                    Text("This preset has no touchpad regions yet")
                    Text("Open Options › Calibrate Touchpad to draw some")
                } else {
                    ForEach(regions) { region in
                        Button {
                            binding.input.touchpadRegionID = region.id
                        } label: {
                            regionMenuLabel(region)
                        }
                    }
                }
            } label: {
                regionMenuLabel(name: touchpadRegionDisplayName,
                                colorIndex: touchpadRegionColorIndex)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

        case .cursorRegion:
            // Parallel to `.touchpadRegion` but the regions are screen-space
            // zones tracked against the macOS cursor position.
            Menu {
                let regions = CursorRegionService.shared.allRegions()
                if regions.isEmpty {
                    Text("No screen regions yet")
                } else {
                    // Grouped by the display each region belongs to, so
                    // "Top left" on the built-in screen and "Top left" on
                    // the external one are never confused.
                    ForEach(Self.screenRegionSections(regions), id: \.title) { section in
                        Section(section.title) {
                            ForEach(section.regions) { region in
                                Button {
                                    binding.input.cursorRegionID = region.id
                                } label: {
                                    regionMenuLabel(region)
                                }
                            }
                        }
                    }
                }
                Divider()
                Button("Edit screen regions…") {
                    showCursorRegionsEditor = true
                }
            } label: {
                regionMenuLabel(name: cursorRegionDisplayName,
                                colorIndex: cursorRegionColorIndex)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()
            .sheet(isPresented: $showCursorRegionsEditor) {
                CursorRegionsView()
                    .glassBackground()
            }

        case .stickRegion:
            // Parallel to `.cursorRegion` but the regions are zones in
            // the joystick stick's X/Y plane. The index field carries
            // the stick selection (0 = left, 1 = right); the picker
            // groups regions by stick so users can see both sticks'
            // regions at once.
            Menu {
                let leftRegions = StickRegionService.shared.regions(forStick: 0)
                let rightRegions = StickRegionService.shared.regions(forStick: 1)
                if leftRegions.isEmpty && rightRegions.isEmpty {
                    Text("No stick regions defined")
                } else {
                    if !leftRegions.isEmpty {
                        Section("Left stick") {
                            ForEach(leftRegions) { region in
                                Button {
                                    binding.input.index = 0
                                    binding.input.stickRegionID = region.id
                                } label: {
                                    regionMenuLabel(region)
                                }
                            }
                        }
                    }
                    if !rightRegions.isEmpty {
                        Section("Right stick") {
                            ForEach(rightRegions) { region in
                                Button {
                                    binding.input.index = 1
                                    binding.input.stickRegionID = region.id
                                } label: {
                                    regionMenuLabel(region)
                                }
                            }
                        }
                    }
                }
                Divider()
                Button("Edit stick zones…") {
                    showStickRegionsEditor = true
                }
            } label: {
                regionMenuLabel(name: stickRegionDisplayName,
                                colorIndex: stickRegionColorIndex)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()
            .sheet(isPresented: $showStickRegionsEditor) {
                StickRegionsView()
                    .glassBackground()
            }

        case .extKey:
            // HID usage code. Most users won't remember a code by number, so
            // we surface a Scan affordance: if the user clicks "Scan" the next
            // physical key press on any detected keyboard becomes the binding.
            Menu {
                Section("Common keys") {
                    ForEach(commonHIDKeys, id: \.code) { entry in
                        Button("\(entry.label) (code \(entry.code))") {
                            binding.input.index = entry.code
                        }
                    }
                }
                Section("Scan") {
                    Button("Press any key on detected keyboard…") {
                        scanForExternalKey()
                    }
                }
            } label: {
                menuLabel(KeyCodeMap.name(for: binding.input.index))
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

        case .extMouse:
            // Sub-kind: button vs motion vs scroll.
            Menu {
                ForEach(ExtMouseKind.allCases) { kind in
                    Button(kind.displayName) {
                        binding.input.extMouseKind = kind
                        // Reset the index for kinds that don't need one.
                        if kind != .button && kind != .doubleClick { binding.input.index = 0 }
                    }
                }
            } label: {
                menuLabel((binding.input.extMouseKind ?? .button).displayName)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

        case .touchpadGesture:
            // The gesture kind discriminator (two-finger tap, etc.).
            Menu {
                ForEach(TouchpadGestureKind.allCases) { kind in
                    Button(kind.displayName) {
                        binding.input.touchpadGestureKind = kind
                    }
                }
            } label: {
                menuLabel(binding.input.touchpadGestureKind?.displayName
                          ?? "Two-finger tap")
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

        case .midi:
            midiIndexPicker
        }
    }

    /// 12 most-used HID Keyboard / Keypad usage codes for the dropdown.
    private var commonHIDKeys: [(label: String, code: Int)] {
        [
            ("A", 4), ("S", 22), ("D", 7), ("W", 26),
            ("Space", 44), ("Return", 40), ("Escape", 41), ("Tab", 43),
            ("Left", 80), ("Right", 79), ("Up", 82), ("Down", 81)
        ]
    }

    /// Watches `ExternalInputDeviceService.events` for one key-down then
    /// assigns it as this binding's input. Guaranteed to cancel via a
    /// scheduled timer even if no key is ever pressed - earlier versions
    /// relied on a `Date()` check inside the sink, which only ran when
    /// the subject fired, leaking the subscription forever if nothing
    /// happened. Also single-shot: re-clicking Scan cancels the previous
    /// listener via the static reference so multiple rows can't pile up.
    /// What macOS calls each mouse button number.
    static func mouseButtonName(_ index: Int) -> String {
        switch index {
        case 0: return "Left click"
        case 1: return "Right click"
        case 2: return "Middle click"
        default: return "Button \(index + 1)"
        }
    }

    private func scanForExternalKey() {
        scanExternal(keyboard: true) { event in
            if case .keyDown(let dev, let code) = event { return (code, dev) }
            return nil
        }
    }

    private func scanForExternalMouseButton() {
        scanExternal(mouse: true) { event in
            if case .mouseButtonDown(let dev, let b) = event { return (b, dev) }
            return nil
        }
    }

    /// Watches `ExternalInputDeviceService.events` for the first event
    /// `pick` accepts and assigns it as this binding's input. The monitor
    /// is held open for the scan and let go when it ends, so scanning
    /// works with no preset running. Guaranteed to cancel via a scheduled
    /// timer even if nothing is ever pressed, and single-shot: a new Scan
    /// cancels the previous listener via the static reference.
    private func scanExternal(mouse: Bool = false, keyboard: Bool = false,
                              pick: @escaping (ExternalInputDeviceService.Event) -> (Int, String)?) {
        Self.cancelActiveScan()
        let svc = ExternalInputDeviceService.shared
        svc.retain("scan", mouse: mouse, keyboard: keyboard)
        // A press already down when Scan was clicked must not count, so
        // events in the first instant are ignored.
        let armedAt = Date().addingTimeInterval(0.15)
        let cancellable = svc.events.sink { event in
            guard Date() >= armedAt, let (index, dev) = pick(event) else { return }
            DispatchQueue.main.async {
                binding.input.index = index
                binding.input.extDeviceID = dev
                Self.cancelActiveScan()
            }
        }
        Self.activeScanCancellable = cancellable
        // Hard 5-second deadline. Fires on the main run loop so it always
        // runs even if no events arrive on the subject.
        Self.activeScanTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { _ in
            Self.cancelActiveScan()
        }
    }

    /// Single global slot for the active "scan for keyboard key" listener.
    /// Static so re-clicking Scan on a different row always cancels the
    /// previous subscription instead of stacking them.
    private static var activeScanCancellable: AnyCancellable?
    private static var activeScanTimer: Timer?

    /// Cancel any in-flight external-input scan. Called from
    /// `.onDisappear` so a row that goes away mid-scan doesn't keep
    /// the static timer/subscription alive and fire its 5-second
    /// deadline writing into a now-dead `@Binding`.
    static func cancelActiveScan() {
        activeScanCancellable?.cancel()
        activeScanCancellable = nil
        activeScanTimer?.invalidate()
        activeScanTimer = nil
        ExternalInputDeviceService.shared.release("scan")
    }

    private var touchpadRegionDisplayName: String {
        if let id = binding.input.touchpadRegionID,
           let r = TouchpadService.shared.region(with: id) {
            return r.name
        }
        return "Pick region"
    }

    private var cursorRegionDisplayName: String {
        if let id = binding.input.cursorRegionID,
           let r = CursorRegionService.shared.region(with: id) {
            if let d = r.display { return "\(r.name) on \(d.name)" }
            return r.name
        }
        return "Pick a screen region"
    }

    /// Regions that apply to every display first, then one group per
    /// display, in the order the displays are attached.
    static func screenRegionSections(_ regions: [TouchpadRegion]) -> [(title: String, regions: [TouchpadRegion])] {
        var out: [(String, [TouchpadRegion])] = []
        let any = regions.filter { $0.display == nil }
        if !any.isEmpty { out.append(("Every display", any)) }
        var seen: [DisplayKey] = []
        for r in regions {
            guard let d = r.display, !seen.contains(d) else { continue }
            seen.append(d)
            let attached = CursorRegionService.shared.isDisplayAttached(d)
            out.append((attached ? d.name : "\(d.name) (not connected)", regions.filter { $0.display == d }))
        }
        return out
    }

    /// Palette slot of the chosen region, so the row can show the same
    /// color the maps draw it in. Nil when no region is chosen yet.
    private var cursorRegionColorIndex: Int? {
        guard let id = binding.input.cursorRegionID,
              let r = CursorRegionService.shared.region(with: id) else { return nil }
        return r.colorIndex
    }

    private var touchpadRegionColorIndex: Int? {
        guard let id = binding.input.touchpadRegionID,
              let r = TouchpadService.shared.region(with: id) else { return nil }
        return r.colorIndex
    }

    private var stickRegionColorIndex: Int? {
        guard let id = binding.input.stickRegionID,
              let found = StickRegionService.shared.region(with: id) else { return nil }
        return found.region.colorIndex
    }

    /// Canonical labels for the standard 22 MFi button slots. Surfaced
    /// in the button index picker so users see "A / Cross (#0)" instead
    /// of just "Button 0". Indices 16-21 cover DualSense Edge paddles
    /// and Function buttons.
    static let standardButtonLabels: [(index: Int, label: String)] = [
        (0, "A / Cross"),
        (1, "B / Circle"),
        (2, "X / Square"),
        (3, "Y / Triangle"),
        (4, "LB / L1"),
        (5, "RB / R1"),
        (6, "LT / L2 (digital)"),
        (7, "RT / R2 (digital)"),
        (8, "Back / Share / Select"),
        (9, "Start / Options"),
        (10, "Home / PS / Guide"),
        (11, "L3 (left stick click)"),
        (12, "R3 (right stick click)"),
        (13, "Touchpad press"),
        (14, "Share (where exposed)"),
        (15, "Microphone / Mute"),
        (16, "Left Paddle"),
        (17, "Right Paddle"),
        (18, "Paddle 3"),
        (19, "Paddle 4"),
        (20, "FN 1 / Left Function"),
        (21, "FN 2 / Right Function"),
    ]

    /// Closed-menu label. Prefers the connected controller's named
    /// extra (e.g. "Left Paddle") for the active index, falls back to
    /// a canonical standard label, otherwise the bare "Button N".
    private func buttonMenuLabel(for index: Int) -> String {
        if let extra = extraButtons.first(where: { $0.index == index }) {
            return extra.label
        }
        if let std = Self.standardButtonLabels.first(where: { $0.index == index }) {
            return std.label
        }
        return "Button \(index)"
    }

    /// "Single tap" / "Double tap" / "Triple tap" for the index column.
    private var chassisTapLabel: String {
        TapCalibrationView.gestureName(max(1, min(5, binding.input.index)))
    }

    private var stickRegionDisplayName: String {
        if let id = binding.input.stickRegionID,
           let lookup = StickRegionService.shared.region(with: id) {
            let stick = lookup.stickIndex == 1 ? "Right" : "Left"
            return "\(stick): \(lookup.region.name)"
        }
        return "Pick stick region"
    }

    /// MIDI: the first column picks the message family and its number
    /// (note or CC). Pitch bend and aftertouch are per-channel, so they
    /// have no number and the menu collapses to just the family.
    @ViewBuilder
    private var midiIndexPicker: some View {
        Menu {
            Section("Message") {
                ForEach(MIDIInputKind.allCases) { kind in
                    Button(kind.displayName) {
                        binding.input.midiKind = kind
                        // Reset the number to something sensible for the
                        // new family so the row never shows "CC 60".
                        if kind == .note { binding.input.index = 60 }
                        else if kind == .cc { binding.input.index = 1 }
                        else { binding.input.index = 0 }
                    }
                }
            }
            let kind = binding.input.midiKind ?? .note
            if kind.usesNumber {
                Section(kind == .note ? "Note" : (kind == .cc ? "Controller" : "Program")) {
                    // Live devices make Scan the better path, so this menu
                    // stays short: common values, not all 128.
                    ForEach(Self.midiNumberChoices(for: kind), id: \.0) { pair in
                        Button(pair.1) { binding.input.index = pair.0 }
                    }
                }
            }
        } label: {
            menuChevronLabel(midiIndexLabel)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
    }

    private var midiIndexLabel: String {
        let kind = binding.input.midiKind ?? .note
        switch kind {
        case .note:          return MIDIService.noteName(binding.input.index)
        case .cc:            return "CC \(binding.input.index)"
        case .programChange: return "Prog \(binding.input.index)"
        case .pitchBend:     return "Pitch Bend"
        case .aftertouch:    return "Aftertouch"
        }
    }

    /// Menu choices per message family. Notes span a usable keyboard
    /// range; CC lists the controllers people actually bind.
    private static func midiNumberChoices(for kind: MIDIInputKind) -> [(Int, String)] {
        switch kind {
        case .note:
            return (36...84).map { ($0, MIDIService.noteName($0)) }
        case .cc:
            var out = MIDIService.commonCCs.map { ($0.number, "CC \($0.number) - \($0.name)") }
            let common = Set(MIDIService.commonCCs.map(\.number))
            out += (0...127).filter { !common.contains($0) }.map { ($0, "CC \($0)") }
            return out
        case .programChange:
            return (0...127).map { ($0, "Program \($0)") }
        case .pitchBend, .aftertouch:
            return []
        }
    }

    /// MIDI: the second column picks the channel (or Any).
    @ViewBuilder
    private var midiChannelPicker: some View {
        Menu {
            // Device section first: this is where users look to confirm
            // their MIDI keyboard was detected at all.
            Section("Device") {
                Button("Any device") { binding.input.midiDeviceID = nil }
                let devices = MIDIInputService.shared.connectedDevices()
                if devices.isEmpty {
                    Text("No MIDI devices detected")
                } else {
                    ForEach(devices) { device in
                        Button(device.name) { binding.input.midiDeviceID = device.id }
                    }
                }
            }
            Button("Any channel") { binding.input.midiChannel = nil }
            Section("Channel") {
                ForEach(1...16, id: \.self) { ch in
                    Button("Channel \(ch)") { binding.input.midiChannel = ch }
                }
            }
            // Knob interpretation, for CC only: Switch (the default,
            // fires past halfway), Dial (speed from center, like a stick
            // axis), or Turn (relative nudges per step of rotation).
            if (binding.input.midiKind ?? .note) == .cc {
                Section("Knob mode") {
                    ForEach(MIDICCMode.allCases) { mode in
                        Button(mode.displayName) {
                            // Store nil for the default so pre-existing
                            // bindings keep byte-identical serialization.
                            binding.input.midiCCMode = (mode == .threshold) ? nil : mode
                        }
                    }
                }
                if binding.input.midiCCMode == .relative {
                    Section("Turn step") {
                        Button("Fine (2 units per nudge)")   { binding.input.midiTurnStep = 2 }
                        Button("Normal (4 units per nudge)") { binding.input.midiTurnStep = nil }
                        Button("Coarse (8 units per nudge)") { binding.input.midiTurnStep = 8 }
                        Button("Chunky (16 units per nudge)") { binding.input.midiTurnStep = 16 }
                    }
                }
            }
            // Continuous controllers can be bound as a half-axis, so
            // offer the direction alongside the channel rather than
            // adding a fourth column just for MIDI.
            if (binding.input.midiKind ?? .note).isContinuous {
                Section("Direction") {
                    ForEach(AxisDirection.allCases) { dir in
                        Button(dir.displayName) { binding.input.axisDirection = dir }
                    }
                }
            }
        } label: {
            menuChevronLabel(midiChannelLabel)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
    }

    /// Channel-column label: channel (or Any), prefixed with the knob
    /// mode badge when a CC binding uses a non-default mode, so a Dial
    /// or Turn binding is recognisable without opening the menu.
    private var midiChannelLabel: String {
        let ch = binding.input.midiChannel.map { "Ch \($0)" } ?? "Any ch"
        if (binding.input.midiKind ?? .note) == .cc,
           let badge = binding.input.midiCCMode?.badge {
            return "\(badge) \u{00B7} \(ch)"
        }
        return ch
    }

    // MARK: - Index / Direction Accessibility

    /// Spoken role name for the index picker, matching whatever the closed
    /// menu is actually choosing for the current input type. VoiceOver reads
    /// this before the value so the control never announces a bare number.
    private var indexPickerAccessibilityLabel: String {
        switch binding.input.type {
        case .button: return "Button"
        case .axis: return "Axis"
        case .hat: return "Hat"
        case .touchpad: return "Finger"
        case .motion: return "Motion channel"
        case .touchpadRegion: return "Touchpad zone"
        case .cursorRegion: return "Screen region"
        case .stickRegion: return "Stick region"
        case .extKey: return "Key"
        case .extMouse: return "Mouse input"
        case .touchpadGesture: return "Gesture"
        case .chassisTap: return "Tap count"
        case .midi: return "MIDI message"
        }
    }

    /// Current selection spoken as the index picker's value. Mirrors the
    /// closed-menu label text for each input type.
    private var indexPickerAccessibilityValue: String {
        switch binding.input.type {
        case .button:
            return buttonMenuLabel(for: binding.input.index)
        case .axis:
            return "Axis \(binding.input.index)"
        case .hat:
            return "Hat \(binding.input.index)"
        case .touchpad:
            return (binding.input.touchpadFinger ?? binding.input.index) == 1 ? "Finger 2" : "Finger 1"
        case .motion:
            return (binding.input.motionChannel ?? .gyroY).displayName
        case .touchpadRegion:
            return touchpadRegionDisplayName
        case .cursorRegion:
            return cursorRegionDisplayName
        case .chassisTap:
            return chassisTapLabel
        case .stickRegion:
            return stickRegionDisplayName
        case .midi:
            return binding.input.displayName
        case .extKey:
            return KeyCodeMap.name(for: binding.input.index)
        case .extMouse:
            return (binding.input.extMouseKind ?? .button).displayName
        case .touchpadGesture:
            return binding.input.touchpadGestureKind?.displayName ?? "Two-finger tap"
        }
    }

    /// Spoken role name for the direction column. Some input types host a
    /// device picker or a compound axis picker here instead of a plain
    /// direction, so the label follows what the column actually controls.
    private var directionPickerAccessibilityLabel: String {
        switch binding.input.type {
        case .extKey:
            return "Keyboard device"
        case .extMouse:
            switch binding.input.extMouseKind ?? .button {
            case .button, .doubleClick: return "Mouse button"
            case .moveX, .moveY, .scrollX, .scrollY: return "Direction"
            case .pressure, .deepPress, .scrollGesture: return "Mouse input"
            }
        case .touchpad:
            return "Axis and direction"
        default:
            return "Direction"
        }
    }

    /// Current selection spoken as the direction column's value, matching the
    /// closed-menu label for the active input type.
    private var directionPickerAccessibilityValue: String {
        switch binding.input.type {
        case .button, .touchpadRegion, .cursorRegion, .stickRegion, .touchpadGesture, .chassisTap:
            return "Not applicable"
        case .midi:
            return binding.input.midiChannel.map { "Channel \($0)" } ?? "Any channel"
        case .axis, .motion:
            return axisDirectionBinding.wrappedValue.displayName
        case .hat:
            return hatDirectionBinding.wrappedValue.displayName
        case .touchpad:
            let axisLabel = (binding.input.touchpadAxis ?? .x).rawValue.uppercased()
            let dirLabel = (binding.input.axisDirection ?? .positive).displayName
            return "\(axisLabel) \(dirLabel)"
        case .extKey:
            return externalDeviceLabel(kind: .keyboard)
        case .extMouse:
            switch binding.input.extMouseKind ?? .button {
            case .button, .doubleClick: return Self.mouseButtonName(binding.input.index)
            case .moveX, .moveY, .scrollX, .scrollY:
                return (binding.input.axisDirection ?? .positive).displayName
            case .pressure, .deepPress: return "Built-in trackpad"
            case .scrollGesture: return "Trackpad or Magic Mouse"
            }
        }
    }

    // MARK: - Direction Picker (fixed width, empty for buttons)

    @ViewBuilder
    private var directionPicker: some View {
        switch binding.input.type {
        case .button, .chassisTap:
            // Empty placeholder to keep column width consistent
            Color.clear

        case .axis:
            // Lazy Menu instead of Picker for the same scroll-perf reason
            // as the type menus: NSPopUpButtons pre-build on row creation.
            Menu {
                ForEach(AxisDirection.allCases) { dir in
                    Button(dir.displayName) { axisDirectionBinding.wrappedValue = dir }
                }
            } label: {
                menuChevronLabel(axisDirectionBinding.wrappedValue.displayName)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)

        case .hat:
            Menu {
                ForEach(HatDirection.allCases) { dir in
                    Button(dir.displayName) { hatDirectionBinding.wrappedValue = dir }
                }
            } label: {
                menuChevronLabel(hatDirectionBinding.wrappedValue.displayName)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)

        case .touchpadRegion:
            // Region inputs are button-like; no direction picker needed.
            Color.clear

        case .cursorRegion:
            // Same shape as `.touchpadRegion`: button-like, no direction.
            Color.clear

        case .stickRegion:
            // Stick region also acts like a button (pressed while
            // stick is inside the rect). The stick index is carried in
            // the InputEvent's `index` field and chosen from the region
            // picker, so no direction widget is needed here either.
            Color.clear

        case .motion:
            // Motion inputs read like axes: pick + or - polarity.
            Picker("", selection: axisDirectionBinding) {
                ForEach(AxisDirection.allCases) { dir in
                    Text(dir.displayName).tag(dir)
                }
            }
            .labelsHidden()
            .controlSize(.small)

        case .touchpad:
            // For touchpad, the direction picker is a compound: X/Y axis +
            // half-axis direction. We render it as a single Menu so it fits
            // in the existing column width.
            Menu {
                Section("X (left/right)") {
                    Button("X +  (right)") { setTouchpad(axis: .x, dir: .positive) }
                    Button("X \u{2212}  (left)") { setTouchpad(axis: .x, dir: .negative) }
                }
                Section("Y (up/down)") {
                    Button("Y +  (down)") { setTouchpad(axis: .y, dir: .positive) }
                    Button("Y \u{2212}  (up)")   { setTouchpad(axis: .y, dir: .negative) }
                }
            } label: {
                let axisLabel = (binding.input.touchpadAxis ?? .x).rawValue.uppercased()
                let dirLabel = (binding.input.axisDirection ?? .positive).displayName
                menuLabel("\(axisLabel) \(dirLabel)")
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

        case .extKey:
            // Device picker: which specific keyboard, or "Any".
            externalDeviceMenu(kind: .keyboard)

        case .extMouse:
            // For mouse buttons, this column picks button index (1..8).
            // For motion / scroll, it picks the + / - half-axis direction
            // and shows the device picker via an inline Menu.
            switch binding.input.extMouseKind ?? .button {
            case .button, .doubleClick:
                // Buttons are numbered the way macOS reports them: 0 is the
                // main click, 1 the secondary, 2 the middle, then the side
                // buttons. The menu names them so nobody has to know that.
                Menu {
                    ForEach(0..<8, id: \.self) { btn in
                        Button(Self.mouseButtonName(btn)) { binding.input.index = btn }
                    }
                    Divider()
                    Button("Scan: press a mouse button…") { scanForExternalMouseButton() }
                    Divider()
                    Section("Device") { externalDeviceMenuItems(kind: .mouse) }
                } label: {
                    menuLabel(Self.mouseButtonName(binding.input.index))
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .fixedSize()
            case .moveX, .moveY, .scrollX, .scrollY:
                Menu {
                    Button("+") { binding.input.axisDirection = .positive }
                    Button("\u{2212}") { binding.input.axisDirection = .negative }
                    Divider()
                    Section("Device") { externalDeviceMenuItems(kind: .mouse) }
                } label: {
                    menuLabel((binding.input.axisDirection ?? .positive).displayName)
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .fixedSize()
            case .pressure, .deepPress:
                // Force Touch inputs are built-in-trackpad only: no button
                // index or direction to pick.
                Text("Built-in trackpad")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            case .scrollGesture:
                Text("Trackpad or Magic Mouse")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }

        case .touchpadGesture:
            // Gesture bindings have no direction. Render an empty
            // spacer so the column width stays aligned with the rest
            // of the rows.
            Color.clear.frame(width: 0, height: 0)

        case .midi:
            // MIDI reuses this column for the channel (plus the
            // direction for continuous messages), so a note binding
            // reads "C3 / Any ch" across the two columns.
            midiChannelPicker
        }
    }

    /// Borderless menu for picking which detected external device this
    /// binding targets, including an "Any" sentinel. No `.fixedSize()`
    /// here on purpose: the parent HStack column width must clip the
    /// menu so a long device name (e.g. "Built-in Keyboard") doesn't
    /// run into the next picker.
    @ViewBuilder
    private func externalDeviceMenu(kind: ExternalInputDeviceService.Kind) -> some View {
        Menu {
            externalDeviceMenuItems(kind: kind)
        } label: {
            menuLabel(externalDeviceLabel(kind: kind))
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
    }

    /// Computes the human label for the device-picker button. Pulled out of
    /// the `Menu`'s `label:` ViewBuilder closure because mixing assignment
    /// statements with view-builder syntax doesn't compile cleanly.
    private func externalDeviceLabel(kind: ExternalInputDeviceService.Kind) -> String {
        if let id = binding.input.extDeviceID,
           let name = ExternalInputDeviceService.shared.deviceName(for: id) {
            return name
        }
        return "Any \(kind.rawValue)"
    }

    @ViewBuilder
    private func externalDeviceMenuItems(kind: ExternalInputDeviceService.Kind) -> some View {
        Button("Any \(kind.rawValue)") {
            binding.input.extDeviceID = nil
        }
        let matching = ExternalInputDeviceService.shared.devices.filter { $0.kind == kind }
        if matching.isEmpty {
            Text("No detected devices")
        } else {
            ForEach(matching) { device in
                Button(device.productName) {
                    binding.input.extDeviceID = device.id
                }
            }
        }
    }

    private func setTouchpad(axis: TouchpadAxis, dir: AxisDirection) {
        binding.input.touchpadAxis = axis
        binding.input.axisDirection = dir
    }

    private var touchpadFingerBinding: SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.input.touchpadFinger ?? binding.input.index },
            set: { newValue in
                binding.input.touchpadFinger = newValue
                binding.input.index = newValue
            }
        )
    }

    // MARK: - Output Value Controls

    private func appActionKindBinding(at index: Int) -> SwiftUI.Binding<AppActionKind> {
        SwiftUI.Binding(
            get: {
                binding.outputs.indices.contains(index)
                    ? (binding.outputs[index].appActionKind ?? .togglePauseOutputs)
                    : .togglePauseOutputs
            },
            set: {
                guard binding.outputs.indices.contains(index) else { return }
                binding.outputs[index].appActionKind = $0
            }
        )
    }

    private func targetPresetBinding(at index: Int) -> SwiftUI.Binding<UUID?> {
        SwiftUI.Binding(
            get: { binding.outputs.indices.contains(index) ? binding.outputs[index].targetPresetID : nil },
            set: {
                guard binding.outputs.indices.contains(index) else { return }
                binding.outputs[index].targetPresetID = $0
            }
        )
    }

    private func outputTextBinding(at index: Int) -> SwiftUI.Binding<String> {
        SwiftUI.Binding(
            get: { binding.outputs.indices.contains(index) ? (binding.outputs[index].text ?? "") : "" },
            set: {
                guard binding.outputs.indices.contains(index) else { return }
                binding.outputs[index].text = $0.isEmpty ? nil : $0
            }
        )
    }

    @ViewBuilder
    private func outputValueControls(at index: Int) -> some View {
        // During an animated removal SwiftUI briefly retains the outgoing row
        // with its now-stale index; guard so `binding.outputs[index]` and the
        // per-control get closures never trap on an out-of-range index.
        if !binding.outputs.indices.contains(index) {
            EmptyView()
        } else {
            outputValueControlsBody(at: index)
        }
    }

    @ViewBuilder
    private func outputValueControlsBody(at index: Int) -> some View {
        let actionBinding = outputBinding(at: index)

        switch binding.outputs[index].type {
        case .key:
            KeyCodePicker(selectedCode: keyCodeBinding(at: index))

        case .absoluteVolume:
            // No parameters: the fader simply follows the input's
            // position. Explain the pairing so it isn't a mystery row.
            Text("Volume follows this control's position, 0 to 100%")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize()

        case .systemAction:
            systemActionControls(at: index)

        case .typeText:
            TextField("Text to type", text: outputTextBinding(at: index))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(minWidth: 140)
                .hoverHelp("Typed exactly as written when the input is pressed. Capitals, symbols, and any language work.")

        case .appAction:
            HStack(spacing: 6) {
                Picker("", selection: appActionKindBinding(at: index)) {
                    ForEach(AppActionKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 160)
                .accessibilityLabel("App action")
                if binding.outputs[index].appActionKind == .activatePreset {
                    Picker("", selection: targetPresetBinding(at: index)) {
                        Text("Choose preset…").tag(UUID?.none)
                        ForEach(availablePresets, id: \.id) { entry in
                            Text(entry.name).tag(UUID?.some(entry.id))
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(minWidth: 130)
                    .accessibilityLabel("Target preset")
                }
            }

        case .mouseButton:
            // Lazy Menu: only builds the 32 button options when opened.
            Menu {
                ForEach(0..<32, id: \.self) { i in
                    Button(mouseButtonName(i)) {
                        binding.outputs[index].mouseButtonIndex = i
                    }
                }
            } label: {
                menuLabel(mouseButtonName(binding.outputs[index].mouseButtonIndex ?? 0))
            }
            .menuStyle(.borderlessButton)
            .frame(minWidth: 120)
            .controlSize(.small)
            clickPointControls(at: index)

        case .mouseMotion, .mouseWheel:
            // Compact horizontal: direction, then slider, then numeric
            // readout. The "Speed" word was previously here as a label but
            // it pushed the row over the editor's minWidth on smaller
            // windows and clipped neighbouring columns; the icon-style
            // gauge symbol now hints at what the slider controls without
            // adding meaningful width.
            HStack(spacing: 6) {
                Picker("", selection: mouseAxisDirBinding(at: index)) {
                    Text("Up").tag("1 -")
                    Text("Right").tag("0 +")
                    Text("Down").tag("1 +")
                    Text("Left").tag("0 -")
                }
                .labelsHidden()
                .frame(width: 64)
                .controlSize(.small)

                Image(systemName: "speedometer")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .hoverHelp("Output speed")

                ThrottledSlider(
                    value: speedBinding(at: index),
                    in: 1...50,
                    step: 1,
                    onLiveChange: { liveSpeed[index] = $0 }
                )
                    .frame(minWidth: 60, idealWidth: 90)

                TextField("", value: liveSpeedBinding(at: index), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56)
                    .controlSize(.small)
                    .multilineTextAlignment(.center)
            }

        case .mouseWheelStep:
            Picker("", selection: mouseAxisDirBinding(at: index)) {
                Text("Up").tag("1 -")
                Text("Right").tag("0 +")
                Text("Down").tag("1 +")
                Text("Left").tag("0 -")
            }
            .labelsHidden()
            .frame(width: 70)
            .controlSize(.small)

        case .midiNote:
            HStack(spacing: 6) {
                fieldLabel("Note")
                // Lazy Menu so the 128 note options only build when opened.
                Menu {
                    ForEach(MIDIService.notePickerLabels, id: \.number) { entry in
                        Button(entry.label) {
                            binding.outputs[index].midiNote = entry.number
                        }
                    }
                } label: {
                    let current = binding.outputs[index].midiNote ?? 60
                    menuLabel("\(MIDIService.noteName(current)) (\(current))")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 100)
                .controlSize(.small)

                fieldLabel("Vel")
                TextField("", value: midiVelocityBinding(at: index), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 44)
                    .controlSize(.small)
                    .multilineTextAlignment(.center)

                fieldLabel("Ch")
                Picker("", selection: midiChannelBinding(at: index)) {
                    ForEach(1...16, id: \.self) { c in
                        Text("\(c)").tag(c)
                    }
                }
                .labelsHidden()
                .frame(width: 50)
                .controlSize(.small)
            }

        case .midiCC:
            HStack(spacing: 6) {
                fieldLabel("CC")
                // Lazy Menu so the 128 CC options only build when opened.
                Menu {
                    ForEach(MIDIService.ccPickerLabels, id: \.number) { entry in
                        Button(entry.label) {
                            binding.outputs[index].midiCCNumber = entry.number
                        }
                    }
                } label: {
                    let current = binding.outputs[index].midiCCNumber ?? 1
                    let label = MIDIService.ccNameByNumber[current].map { "\(current) - \($0)" } ?? "\(current)"
                    menuLabel(label)
                }
                .menuStyle(.borderlessButton)
                // Flexible, not fixed: at the sheet's minimum width a fixed
                // 160 pushed the whole row past the sheet edge, clipping the
                // section labels on the left and the delete buttons on the
                // right for every row in a MIDI preset.
                .frame(minWidth: 96, idealWidth: 160)
                .controlSize(.small)

                fieldLabel("Ch")
                Picker("", selection: midiChannelBinding(at: index)) {
                    ForEach(1...16, id: \.self) { c in
                        Text("\(c)").tag(c)
                    }
                }
                .labelsHidden()
                .frame(width: 50)
                .controlSize(.small)
            }

        case .midiPitchBend:
            HStack(spacing: 6) {
                fieldLabel("Ch")
                Picker("", selection: midiChannelBinding(at: index)) {
                    ForEach(1...16, id: \.self) { c in
                        Text("\(c)").tag(c)
                    }
                }
                .labelsHidden()
                .frame(width: 50)
                .controlSize(.small)
                Text("Use with a continuous axis for smooth bend.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }

        case .midiProgramChange:
            HStack(spacing: 6) {
                fieldLabel("Program")
                Menu {
                    ForEach(0...127, id: \.self) { p in
                        Button("\(p)") { binding.outputs[index].midiProgramNumber = p }
                    }
                } label: {
                    menuLabel("\(binding.outputs[index].midiProgramNumber ?? 0)")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 70)
                .controlSize(.small)

                fieldLabel("Ch")
                Picker("", selection: midiChannelBinding(at: index)) {
                    ForEach(1...16, id: \.self) { c in
                        Text("\(c)").tag(c)
                    }
                }
                .labelsHidden()
                .frame(width: 50)
                .controlSize(.small)
            }

        case .midiTransport:
            HStack(spacing: 6) {
                fieldLabel("Action")
                Picker("", selection: midiTransportBinding(at: index)) {
                    ForEach(MIDITransport.allCases) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                .labelsHidden()
                .frame(width: 100)
                .controlSize(.small)
                Text("Sends a real-time transport message to the DAW.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Secondary Outputs

    @ViewBuilder
    private var secondaryOutputRows: some View {
        if binding.outputs.count > 1 {
            ForEach(Array(binding.outputs.enumerated().dropFirst()), id: \.element.id) { index, output in
                secondaryOutputRow(index: index, output: output)
            }
        }
    }

    private func secondaryOutputRow(index: Int, output: OutputAction) -> some View {
        HStack(spacing: gap) {
            Text("+")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            HStack(spacing: gap) {
                outputIconCell(for: output)

                Menu {
                    outputTypeMenuItems(select: { outputTypeBinding(at: index).wrappedValue = $0 },
                                        selectSystemKind: { kind in
                                            binding.outputs[index].type = .systemAction
                                            binding.outputs[index].systemActionKind = kind
                                        },
                                        setParameter: { text in
                                            guard binding.outputs.indices.contains(index) else { return }
                                            binding.outputs[index].text = text
                                        },
                                        setAppAction: { kind, presetID in
                                            guard binding.outputs.indices.contains(index) else { return }
                                            binding.outputs[index].type = .appAction
                                            binding.outputs[index].appActionKind = kind
                                            binding.outputs[index].targetPresetID = presetID
                                        },
                                        setKey: { code in
                                            guard binding.outputs.indices.contains(index) else { return }
                                            binding.outputs[index].type = .key
                                            binding.outputs[index].keyCode = code
                                        })
                } label: {
                    menuChevronLabel(binding.outputs.indices.contains(index)
                                     ? outputMenuTitle(binding.outputs[index])
                                     : OutputType.key.displayName)
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .accessibilityLabel("Output type")
                .accessibilityValue(binding.outputs.indices.contains(index)
                                    ? binding.outputs[index].type.displayName
                                    : OutputType.key.displayName)
            }
            .frame(width: outTypeColWidth, alignment: .leading)

            outputValueControls(at: index)

            Button {
                removeOutput(at: index)
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove this output")

            Spacer(minLength: 0)
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// An output's icon in a fixed cell, scaled to fit it. SF Symbols vary
    /// a lot in width, and letting each one take its natural size put the
    /// menu after a wide symbol visibly further right than after a narrow
    /// one; the cell makes the icon-to-menu distance the same on every row.
    private func outputIconCell(for output: OutputAction) -> some View {
        Image(systemName: outputIcon(for: output))
            .resizable()
            .scaledToFit()
            .foregroundStyle(outputColor(for: output))
            .frame(width: iconCell - 4, height: 13)
            .frame(width: iconCell, height: 18)
    }

    // MARK: - Advanced Section

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The button comes first so it stays put; the panel unfolds
            // below it.
            HStack {
                Button {
                    toggleOptions()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.right")
                            .font(.callout)
                            .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                        Text("Options")
                            .font(.callout)
                    }
                    .foregroundStyle(hasAdvancedOptions ? Color.blue : Color.secondary)
                    .fixedSize()
                }
                .buttonStyle(.plain)
                // Collapsed summary of WHICH options are set, replacing the
                // old bare asterisk that said only that something was.
                if !showAdvanced && hasAdvancedOptions {
                    Text(advancedOptionsSummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
            }
            // Options starts in the number column, directly under "#n" and
            // the "Notes" label, so the three lines of a row share one edge.
            .padding(.leading, dragWidth + colGap)
            .padding(.top, 4)

            if showAdvanced {
                advancedOptionsRow
                    // Full width on purpose: the left column sits under the
                    // row's Input column and the right under its Output.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 12)
                    .padding(.top, 6)
                    // The row's clip shape trims the panel while it slides
                    // out from under the button, so opening reads as a fold.
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    /// Animated open and close. Only the drag handle folds the panel
    /// without animation, because it must be instant for the reorder to
    /// start on the right frame.
    private func toggleOptions() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            showAdvanced.toggle()
        }
    }

    // MARK: - Advanced Options

    private var hasAdvancedOptions: Bool {
        !binding.modifiers.isEmpty ||
        binding.deadzone != nil || binding.invertAxis == true ||
        binding.toggleMode == true || binding.turboEnabled == true ||
        binding.sensitivityCurve != nil || (binding.repeatCount ?? 1) > 1 ||
        (binding.macroSteps?.isEmpty == false) ||
        binding.variableSensitivity != nil ||
        binding.holdOutputs != nil || binding.doubleTapOutputs != nil ||
        binding.hapticEnabled == true || binding.speechEnabled == true
    }

    /// One-line summary of the configured advanced options, shown next to
    /// the collapsed disclosure. Built from the same fields
    /// `hasAdvancedOptions` checks.
    private var advancedOptionsSummary: String {
        var parts: [String] = []
        if let dz = binding.deadzone { parts.append("Deadzone \(Int(dz * 100))%") }
        if binding.invertAxis == true { parts.append("Inverted") }
        if let curve = binding.sensitivityCurve, curve != .linear {
            parts.append(curve == .exponential ? "Smooth curve" : "Aggressive curve")
        }
        if binding.variableSensitivity == true { parts.append("Variable") }
        if !binding.modifiers.isEmpty {
            parts.append("With " + binding.modifiers.map { modifierName($0) }.joined(separator: " + "))
        }
        if binding.toggleMode == true && binding.turboEnabled == true {
            parts.append("Auto every \(turboIntervalMs) ms")
        } else {
            if binding.toggleMode == true { parts.append("Toggle") }
            if binding.turboEnabled == true { parts.append("Every \(turboIntervalMs) ms") }
        }
        if let n = binding.turboMaxCount, n > 0, binding.turboEnabled == true { parts.append("\(n)x then stop") }
        if (binding.repeatCount ?? 1) > 1 { parts.append("Repeat x\(binding.repeatCount ?? 1)") }
        if let steps = binding.macroSteps, !steps.isEmpty {
            parts.append("Macro \(steps.count) \(steps.count == 1 ? "step" : "steps")")
        }
        if let hold = binding.holdOutputs?.first {
            parts.append("Hold \(hold.displayName)")
        }
        if let double = binding.doubleTapOutputs?.first {
            parts.append("2x \(double.displayName)")
        }
        if binding.hapticEnabled == true {
            if let ms = binding.hapticDurationMs, ms >= FeedbackService.transientCutoffMs {
                parts.append("Vibrate \(hapticDurationLabel(Double(ms)))")
            } else {
                parts.append("Vibrate")
            }
        }
        if binding.speechEnabled == true { parts.append("Speak") }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// Where the row's arrow sits, measured from the row's left edge; the
    /// options divider goes exactly under it.
    private static let arrowCentreX: CGFloat = {
        let boxEnd: CGFloat = BindingRowView.inputBoxLeading + BindingRowView.inputBoxWidth
        let half: CGFloat = BindingRowView.arrowSlotWidth / 2
        // The column constants overshoot the arrow's real center by 15 pt
        // (the input box lays out narrower than the sum of its column
        // widths). Measured off a render: arrow at 1185 px, divider at 1215,
        // at 1.97 px per point.
        return boxEnd + half - 15
    }()

    private var advancedOptionsRow: some View {
        // Two columns under the row's own Input and Output headings, split by
        // a divider that sits on the row's arrow: how the control is read on
        // the left, what the row sends on the right.
        let leftWidth = max(220, Self.arrowCentreX - leftGutter - 0.5)
        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) { inputSideOptions }
                .frame(width: leftWidth - 16, alignment: .leading)
                .padding(.trailing, 16)
            Divider()
            VStack(alignment: .leading, spacing: 8) { outputSideOptions }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, Self.arrowSlotWidth / 2 + 4)
        }
        .padding(.leading, leftGutter)
    }

    /// Left column: everything about reading the control.
    @ViewBuilder
    private var inputSideOptions: some View {
        if binding.input.type == .motion {
            optionsBox("Motion") {
                MotionRowPanel(
                    slot: slot,
                    channel: binding.input.motionChannel ?? .gyroY,
                    direction: binding.input.axisDirection,
                    invert: binding.invertAxis ?? false,
                    deadzone: liveDeadzone ?? Double(binding.deadzone ?? 0.25))
                advancedAxisOptions
            }
        } else if binding.input.type == .axis {
            optionsBox(isTriggerAxis ? "Trigger" : "Stick") { advancedAxisOptions }
        } else if binding.input.type == .stickRegion {
            optionsBox("Stick zone") { advancedAxisOptions }
        } else if binding.input.type == .touchpad {
            optionsBox("Finger movement") { advancedAxisOptions }
        }
        if [.touchpad, .touchpadRegion, .touchpadGesture].contains(binding.input.type) {
            optionsBox("Touchpad") {
                HStack(spacing: 10) {
                    Text("Swipe to every edge once so a swipe moves the pointer the same distance in every direction, and draw tap zones.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    TouchpadCalibrateButton()
                }
            }
        }
        if binding.input.type == .chassisTap {
            optionsBox("Tap the Mac") {
                HStack(spacing: 10) {
                    Text("Watch your knocks on a live trace and set how firm a tap has to be. The setting is shared by every preset.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    TapCalibrateButton()
                }
            }
        }
        if ![.extKey, .extMouse, .midi].contains(binding.input.type) {
            optionsBox("Second control") { modifierPicker }
        }
    }

    /// Right column: everything about what the row sends.
    @ViewBuilder
    private var outputSideOptions: some View {
        optionsBox("How it fires") { pressBehaviorOptions }
        optionsBox("Extra actions") { tapHoldOptions }
        optionsBox("Macro") { macroOptions }
        optionsBox("Feedback") {
            advancedFeedbackOptions
            if binding.speechEnabled == true {
                speechDetailRow
            }
        }
    }

    /// One area of the Options panel: its title at the top-left and its
    /// controls inside one rounded box, so each area reads as a unit
    /// instead of a run of headings and hairlines.
    private func optionsBox<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.12), lineWidth: 1))
    }

    /// A short label beside a parameter field. Fixed so it never wraps
    /// letter-by-letter when the output column gets narrow.
    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .fixedSize()
            .lineLimit(1)
    }

    @ViewBuilder
    private var advancedFeedbackOptions: some View {
        // Haptic toggle
        Toggle(isOn: hapticBinding) {
            HStack(spacing: 3) {
                Image(systemName: "waveform")
                    .font(.callout)
                Text("Vibrate")
                    .font(.callout)
            }
            .foregroundStyle(.secondary)
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .hoverHelp("Vibrate the controller when this binding fires (DualSense, DualSense Edge, and similar).")

        if binding.hapticEnabled == true {
            HStack(spacing: 4) {
                Text("Strength")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ThrottledSlider(
                    value: hapticIntensityBinding,
                    in: 0.1...1.0,
                    step: 0.05,
                    onLiveChange: { liveHaptic = $0 }
                )
                    .frame(width: 60)
                Text(String(format: "%.0f%%", (liveHaptic ?? Double(binding.hapticIntensity ?? 0.6)) * 100))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 30)
            }
            HStack(spacing: 4) {
                Text("Duration")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ThrottledSlider(
                    value: hapticDurationBinding,
                    in: 0...Double(FeedbackService.maxDurationMs),
                    step: 20,
                    onLiveChange: { liveHapticDuration = $0 }
                )
                    .frame(width: 60)
                Text(hapticDurationLabel(liveHapticDuration ?? Double(binding.hapticDurationMs ?? FeedbackService.defaultDurationMs)))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 44, alignment: .leading)
            }
            .hoverHelp("Tap is a single short pulse. Longer settings rumble for that long, up to two seconds.")
        }

        // Speech toggle
        Toggle(isOn: speechBinding) {
            HStack(spacing: 3) {
                Image(systemName: "speaker.wave.2")
                    .font(.callout)
                Text("Speak")
                    .font(.callout)
            }
            .foregroundStyle(.secondary)
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .hoverHelp("Speak a phrase out loud when this binding fires.")
    }

    @ViewBuilder
    private var speechDetailRow: some View {
        HStack(spacing: 10) {
            Text("Phrase")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Phrase to speak", text: speechTextBinding)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(maxWidth: 200)

            Text("Output")
                .font(.callout)
                .foregroundStyle(.secondary)
            Picker("", selection: speechDestinationBinding) {
                Text("Mac").tag(SpeechDestination.mac)
                Text("Controller").tag(SpeechDestination.controller)
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 110)
            Spacer()
        }
    }

    /// Output-type menu grouped Keyboard / Mouse / MIDI / App, so keyboard-
    /// and-mouse users stop wading through DAW terminology on every choice.
    /// Shared by the primary and secondary output menus; built lazily on
    /// open like KeyCodePicker, so rows render without pre-building it.
    @ViewBuilder
    private func outputTypeMenuItems(select: @escaping (OutputType) -> Void,
                                     selectSystemKind: @escaping (SystemActionKind) -> Void,
                                     setParameter: @escaping (String) -> Void = { _ in },
                                     setAppAction: @escaping (AppActionKind, UUID?) -> Void = { _, _ in },
                                     setKey: @escaping (Int) -> Void = { _ in }) -> some View {
        Section("Keyboard") {
            Menu(OutputType.key.displayName) {
                Button("Choose on the row\u{2026}") { select(.key) }
                Divider()
                ForEach(KeyCodeMap.groups, id: \.self) { group in
                    Menu(group) {
                        ForEach(KeyCodeMap.allKeys.filter { $0.group == group }) { key in
                            Button(key.name) { setKey(key.code) }
                        }
                    }
                }
            }
            Button(OutputType.typeText.displayName) { select(.typeText) }
        }
        Section("Mouse") {
            Button(OutputType.mouseButton.displayName) { select(.mouseButton) }
            Button(OutputType.mouseMotion.displayName) { select(.mouseMotion) }
            Button(OutputType.mouseWheel.displayName) { select(.mouseWheel) }
            Button(OutputType.mouseWheelStep.displayName) { select(.mouseWheelStep) }
        }
        Section("MIDI") {
            Button(OutputType.midiNote.displayName) { select(.midiNote) }
            Button(OutputType.midiCC.displayName) { select(.midiCC) }
            Button(OutputType.midiPitchBend.displayName) { select(.midiPitchBend) }
            Button(OutputType.midiProgramChange.displayName) { select(.midiProgramChange) }
            Button(OutputType.midiTransport.displayName) { select(.midiTransport) }
        }
        Section("App") {
            Menu(OutputType.appAction.displayName) {
                ForEach(AppActionKind.allCases) { kind in
                    if kind == .activatePreset {
                        Menu(kind.displayName) {
                            if availablePresets.isEmpty {
                                Text("No other presets yet")
                            } else {
                                ForEach(availablePresets, id: \.id) { entry in
                                    Button(entry.name) { setAppAction(kind, entry.id) }
                                }
                            }
                        }
                    } else {
                        Button(kind.displayName) { setAppAction(kind, nil) }
                    }
                }
            }
        }
        Section("Feedback") {
            // A row can do nothing but vibrate or speak: the engine fires
            // feedback on every press whether or not the row has outputs.
            Button(binding.hapticEnabled == true ? "Vibrate (on)" : "Vibrate the controller") {
                binding.hapticEnabled = true
                if binding.hapticIntensity == nil { binding.hapticIntensity = 0.6 }
                showAdvanced = true
            }
            Button(binding.speechEnabled == true ? "Speak a phrase (on)" : "Speak a phrase") {
                binding.speechEnabled = true
                showAdvanced = true
            }
        }
        Section("Extra actions") {
            Button("Different action when held\u{2026}") {
                if binding.holdOutputs?.isEmpty != false {
                    binding.holdOutputs = [OutputAction(type: .key, keyCode: 41)]
                }
                if binding.holdThresholdMs == nil { binding.holdThresholdMs = 300 }
                showAdvanced = true
            }
            Button("Action on a double tap\u{2026}") {
                if binding.doubleTapOutputs?.isEmpty != false {
                    binding.doubleTapOutputs = [OutputAction(type: .key, keyCode: 40)]
                }
                if binding.doubleTapWindowMs == nil { binding.doubleTapWindowMs = 300 }
                showAdvanced = true
            }
            Button("Run a sequence of steps (macro)\u{2026}") {
                if binding.macroSteps?.isEmpty != false {
                    let seed = binding.outputs.first ?? OutputAction(type: .key, keyCode: 44)
                    binding.macroSteps = [MacroStep(action: seed)]
                }
                showAdvanced = true
            }
        }
        Section("System") {
            Button(OutputType.absoluteVolume.displayName) { select(.absoluteVolume) }
            ForEach(SystemActionKind.grouped, id: \.category) { group in
                Menu(group.category) {
                    ForEach(group.kinds) { kind in
                        switch kind {
                        case .runShortcut:
                            Menu {
                                let names = systemLists.shortcuts
                                if names.isEmpty {
                                    Text("No Shortcuts found")
                                } else {
                                    ForEach(names, id: \.self) { name in
                                        Button(name) { selectSystemKind(kind); setParameter(name) }
                                    }
                                }
                                Divider()
                                Button("Type a name\u{2026}") { selectSystemKind(kind) }
                            } label: {
                                Label(kind.displayName, systemImage: kind.iconName)
                            }
                        case .openApp:
                            Menu {
                                let apps = systemLists.apps
                                if apps.isEmpty {
                                    Text("No applications found")
                                } else {
                                    ForEach(apps, id: \.self) { app in
                                        Button(app) { selectSystemKind(kind); setParameter(app) }
                                    }
                                }
                                Divider()
                                Button("Type a name or path\u{2026}") { selectSystemKind(kind) }
                            } label: {
                                Label(kind.displayName, systemImage: kind.iconName)
                            }
                        default:
                            Button {
                                selectSystemKind(kind)
                            } label: {
                                Label(kind.displayName, systemImage: kind.iconName)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Selects an input type from the lazy type menu.
    private func inputTypeChoice(_ type: InputType) -> some View {
        Button(type.displayName) {
            binding.input.type = type
            // Seed defaults when switching INTO MIDI so the row doesn't
            // inherit the previous type's index (button 0 would show as
            // note C-2) and so the message family is never nil.
            if type == .midi {
                if binding.input.midiKind == nil {
                    binding.input.midiKind = .note
                    binding.input.index = 60          // middle C
                }
                if binding.input.axisDirection == nil {
                    binding.input.axisDirection = .positive
                }
            }
            // Axis and Hat need the same treatment. Only Scan used to produce a
            // directed event, so a row switched to Axis by hand kept
            // axisDirection == nil, which the engine reads as "either
            // direction" while the picker renders "+". A Hat row left with
            // hatDirection == nil matched nothing at all and silently never
            // fired, even though the UI showed "Hat 0 Up".
            if type == .axis, binding.input.axisDirection == nil {
                binding.input.axisDirection = .positive
            }
            if type == .hat, binding.input.hatDirection == nil {
                binding.input.hatDirection = .up
            }
        }
    }

    /// Shared label style for the lazy menus, matching KeyCodePicker.
    private func menuChevronLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// Tap-vs-hold and double-tap rows. Both multiply what one input can do:
    /// quick tap fires the normal outputs, a long hold (or a second tap) fires
    /// a separate keyboard key. Disabled while a macro owns the binding, since
    /// the engine gives macros precedence.
    @ViewBuilder
    private var tapHoldOptions: some View {
        let macroOwned = binding.macroSteps?.isEmpty == false
        Toggle(isOn: doubleTapEnabledBinding) {
            Text("Send a different action on a double tap")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .toggleStyle(.checkbox)
        .controlSize(.regular)
        .disabled(macroOwned)

        if binding.doubleTapOutputs != nil {
            HStack(spacing: 8) {
                Text("Double tap sends")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                KeyCodePicker(selectedCode: doubleTapKeyBinding)
                    .frame(width: 150)
                Text("within")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("", value: doubleTapWindowBinding, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56)
                    .controlSize(.regular)
                    .multilineTextAlignment(.center)
                Text("ms")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .disabled(macroOwned)
        }
    }

    private var holdEnabledBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { binding.holdOutputs != nil },
            set: { on in
                if on {
                    binding.holdOutputs = [OutputAction(type: .key, keyCode: 225)]
                } else {
                    binding.holdOutputs = nil
                    binding.holdThresholdMs = nil
                }
            }
        )
    }

    private var holdKeyBinding: SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.holdOutputs?.first?.keyCode ?? 225 },
            set: { binding.holdOutputs = [OutputAction(type: .key, keyCode: $0)] }
        )
    }

    private var holdThresholdBinding: SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.holdThresholdMs ?? 300 },
            set: { binding.holdThresholdMs = max(50, min(5000, $0)) }
        )
    }

    private var doubleTapEnabledBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { binding.doubleTapOutputs != nil },
            set: { on in
                if on {
                    binding.doubleTapOutputs = [OutputAction(type: .key, keyCode: 4)]
                } else {
                    binding.doubleTapOutputs = nil
                    binding.doubleTapWindowMs = nil
                }
            }
        )
    }

    private var doubleTapKeyBinding: SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.doubleTapOutputs?.first?.keyCode ?? 4 },
            set: { binding.doubleTapOutputs = [OutputAction(type: .key, keyCode: $0)] }
        )
    }

    private var doubleTapWindowBinding: SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.doubleTapWindowMs ?? 300 },
            set: { binding.doubleTapWindowMs = max(100, min(2000, $0)) }
        )
    }

    /// Arrow between the input and output columns. While the row is firing
    /// it tints green and sweeps left to right (a repeating "shoot" toward
    /// the output side), then settles back when the input releases. The
    /// animation is Core Animation driven, so it costs no per-frame SwiftUI
    /// body work.
    private var firingArrow: some View {
        Image(systemName: "arrow.right")
            .font(.callout)
            .foregroundStyle(isHighlighted ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary))
            // Static when Reduce Motion is on; the green tint alone signals firing.
            .offset(x: reduceMotion ? 0 : (arrowShoot ? 5 : -5))
            .animation(reduceMotion
                       ? nil
                       : arrowShoot
                       ? Animation.easeIn(duration: 0.3).repeatForever(autoreverses: false)
                       : Animation.easeOut(duration: 0.15),
                       value: arrowShoot)
            .frame(width: arrowWidth)
            .accessibilityHidden(true)
            .onChange(of: isHighlighted) { _, firing in
                arrowShoot = reduceMotion ? false : firing
            }
    }


    @ViewBuilder
    private var advancedAxisOptions: some View {
        // Deadzone
        HStack(spacing: 4) {
            Text("Deadzone")
                .font(.callout)
                .foregroundStyle(.secondary)
            ThrottledSlider(
                value: deadzoneBinding,
                in: 0.01...0.9,
                step: 0.01,
                onLiveChange: { liveDeadzone = $0 }
            )
                .frame(minWidth: 140, maxWidth: 220)
            let dzPct = String(format: "%.0f%%", (liveDeadzone ?? Double(binding.deadzone ?? 0.25)) * 100)
            Text(dzPct)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 30)
            // Visible "Calibrate" button, axis bindings only (the
            // calibration view samples stick / trigger axes). The icon
            // differs for triggers (1D pressure gauge) vs joysticks
            // (2D circle) so the user can tell at a glance which kind
            // of input this binding uses.
            if binding.input.type == .axis {
                Button {
                    showDeadzoneCalibration = true
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: isTriggerAxis ? "gauge.with.dots.needle.50percent" : "dot.circle.and.hand.point.up.left.fill")
                            .font(.callout)
                        Text("Calibrate")
                            .font(.callout)
                    }
                    .foregroundStyle(.tint)
                }
                .buttonStyle(.solidSecondaryCompact)
                .hoverHelp(isTriggerAxis
                      ? "Open the trigger pressure calibration view."
                      : "Calibrate the joystick by moving it around in a circle.")
            }
        }

        // Full push: the engine treats anything past this as all the way, so
        // a stick that no longer reaches its corners still gives full speed.
        if binding.input.type == .axis {
            HStack(spacing: 4) {
                Text("Full push at")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ThrottledSlider(
                    value: outerDeadzoneBinding,
                    in: 0.2...1.0,
                    step: 0.01,
                    onLiveChange: { liveOuterDeadzone = $0 }
                )
                    .frame(minWidth: 140, maxWidth: 220)
                Text(String(format: "%.0f%%", (liveOuterDeadzone ?? Double(binding.outerDeadzone ?? 1.0)) * 100))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 30)
            }
            .hoverHelp("How far the control has to move to count as fully pushed. Lower it for a worn stick or a short-throw trigger.")
        }

        // Invert: the engine negates the axis before the row's + / - filter,
        // so this row answers to the opposite movement. A trigger only ever
        // moves one way, so there is nothing to invert on one.
        if !isTriggerAxis {
            Toggle(isOn: invertBinding) {
                Text("Invert direction")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .hoverHelp(invertExplanation)
        }

        // Curve and Variable apply only on the engine's axis paths.
        if binding.input.type == .axis {
            // Curve
            HStack(spacing: 4) {
                Text("Curve")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Picker("", selection: curveBinding) {
                    Text("Linear").tag(SensitivityCurve.linear)
                    Text("Smooth").tag(SensitivityCurve.exponential)
                    Text("Aggressive").tag(SensitivityCurve.aggressive)
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 80)
            }

            // Variable Sensitivity (scale output by axis depth)
            Toggle(isOn: variableSensitivityBinding) {
                Text("Variable")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .hoverHelp("Scale output speed by how far the joystick or trigger is pushed.")
        }
    }

    /// Chord picker: this row only fires while another button is held.
    /// Controller rows only; keyboard, mouse, and MIDI rows have no
    /// second button on the same device to pair with.
    @ViewBuilder
    private var modifierPicker: some View {
        let mods = binding.modifiers
        ForEach(Array(mods.enumerated()), id: \.offset) { i, mod in
            HStack(spacing: 8) {
                Image(systemName: "plus.square.on.square")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(i == 0 ? "While also holding" : "and")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 118, alignment: .leading)
                modifierMenu(label: modifierName(mod), tinted: true) { replaceModifier(at: i, with: $0) }
                Button {
                    var list = binding.modifiers
                    list.remove(at: i)
                    binding.setModifiers(list)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Remove this held control")
            }
        }
        if mods.count < BindingModel.maxModifiers {
            HStack(spacing: 8) {
                Image(systemName: "plus.square.on.square")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(mods.isEmpty ? "While also holding" : "and")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 118, alignment: .leading)
                modifierMenu(label: mods.isEmpty ? "Nothing\u{2026}" : "Add another\u{2026}", tinted: false) { event in
                    binding.setModifiers(binding.modifiers + [event])
                }
                Button("Scan", action: onScanModifier)
                    .controlSize(.small)
                    .hoverHelp("Press or move any control on any connected device to add it to the list this row waits for.")
            }
        }
        Text(mods.isEmpty
             ? "This row fires on its own. Add up to three controls here and it fires only while all of them are held, like Triangle + D-pad up."
             : "Fires only while \(mods.map { modifierName($0) }.joined(separator: " and ")) \(mods.count == 1 ? "is" : "are") held. A plain row on the same control stays quiet while the chord is held.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The menu of controls a chord slot can take.
    private func modifierMenu(label: String, tinted: Bool,
                              pick: @escaping (InputEvent) -> Void) -> some View {
        Menu {
            ForEach(Self.standardButtonLabels, id: \.index) { entry in
                Button(buttonMenuLabel(for: entry.index)) {
                    pick(InputEvent(type: .button, index: entry.index))
                }
            }
            ForEach(extraButtons.filter { e in !Self.standardButtonLabels.contains { $0.index == e.index } }, id: \.index) { extra in
                Button(extra.label) { pick(InputEvent(type: .button, index: extra.index)) }
            }
            Divider()
            Button("Scan for any control\u{2026}", action: onScanModifier)
        } label: {
            Text(label)
                .font(.callout)
                .foregroundStyle(tinted ? Color.accentColor : .primary)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .hoverHelp("A control this row waits for. Pick a controller button here, or Scan to use anything: a key, a mouse button, a MIDI pad, an accessory switch, a tap.")
    }

    private func replaceModifier(at index: Int, with event: InputEvent) {
        var list = binding.modifiers
        guard list.indices.contains(index) else { return }
        list[index] = event
        binding.setModifiers(list)
    }

    /// A held control in the words the rest of the row uses.
    private func modifierName(_ m: InputEvent) -> String {
        m.type == .button ? buttonMenuLabel(for: m.index) : m.displayName
    }

    @ViewBuilder
    private var pressBehaviorOptions: some View {
        // Toggle, turbo and hold are three mutually exclusive paths in the
        // engine (see pollControllers), so they belong in one menu rather
        // than as separate checkboxes that quietly override each other.
        Picker("", selection: pressModeBinding) {
            Text("Fires while held").tag(PressMode.normal)
            Text("Toggles on and off").tag(PressMode.toggle)
            Text("Repeats while held").tag(PressMode.turbo)
            Text("Repeats until pressed again").tag(PressMode.autoClick)
            Text("Different action when held").tag(PressMode.hold)
        }
        .labelsHidden()
        .frame(width: 260)
        .controlSize(.regular)
        .hoverHelp("What a press of this control does.")

        Text(pressModeExplanation)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if binding.turboEnabled == true {
            autoClickOptions
        }

        if pressMode == .hold {
            HStack(spacing: 8) {
                Text("Holding sends")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                KeyCodePicker(selectedCode: holdKeyBinding)
                    .frame(width: 150)
                Text("after")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("", value: holdThresholdBinding, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56)
                    .controlSize(.regular)
                    .multilineTextAlignment(.center)
                Text("ms")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .disabled(binding.macroSteps?.isEmpty == false)
        }

        // Repeat count
        HStack(spacing: 6) {
            Text("Repeat")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("", value: repeatCountBinding, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
                .controlSize(.regular)
                .multilineTextAlignment(.center)
            Text((binding.repeatCount ?? 1) > 1 ? "times per press" : "time per press")
                .font(.callout)
                .foregroundStyle(.secondary)
        }

        if (binding.repeatCount ?? 1) > 1 {
            HStack(spacing: 6) {
                Text("Wait")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("", value: repeatDelayBinding, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56)
                    .controlSize(.regular)
                    .multilineTextAlignment(.center)
                Text("ms between repeats")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }

    }

    /// Macro toggle with its editor opening directly underneath.
    @ViewBuilder
    private var macroOptions: some View {
        Toggle(isOn: macroToggleBinding) {
            HStack(spacing: 5) {
                Image(systemName: "bolt.fill")
                    .font(.callout)
                Text("Run a sequence of steps (macro)")
                    .font(.callout)
            }
            .foregroundStyle(binding.macroSteps?.isEmpty == false ? Color.orange : .secondary)
        }
        .toggleStyle(.checkbox)
        .controlSize(.regular)

        if showMacroEditor || binding.macroSteps?.isEmpty == false {
            macroEditorSection
        }
    }

    /// The four mutually exclusive things a press can do.
    enum PressMode: Hashable { case normal, toggle, turbo, autoClick, hold }

    private var pressMode: PressMode {
        if binding.toggleMode == true && binding.turboEnabled == true { return .autoClick }
        if binding.toggleMode == true { return .toggle }
        if binding.turboEnabled == true { return .turbo }
        if binding.holdOutputs != nil { return .hold }
        return .normal
    }

    // MARK: Auto-click

    /// The repeat settings every auto-clicker has: the gap between presses in
    /// milliseconds (with the rate it works out to), an optional random
    /// variation so the timing is not machine-perfect, and an optional stop
    /// after a number of presses.
    @ViewBuilder
    private var autoClickOptions: some View {
        HStack(spacing: 6) {
            Text("Every")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("", value: turboIntervalBinding, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
                .controlSize(.regular)
                .multilineTextAlignment(.center)
            Text("ms")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(String(format: "(%.1f per second)", 1000.0 / Double(max(5, turboIntervalMs))))
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .hoverHelp("Time between presses. 100 ms is ten per second; 1000 ms is one per second.")
        HStack(spacing: 6) {
            Text("Vary by up to")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("", value: turboJitterBinding, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
                .controlSize(.regular)
                .multilineTextAlignment(.center)
            Text("ms either way")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .hoverHelp("Adds a random amount, plus or minus, to every gap so the presses are not perfectly regular. 0 keeps them exact.")
        HStack(spacing: 6) {
            Text("Stop after")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("", value: turboMaxCountBinding, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
                .controlSize(.regular)
                .multilineTextAlignment(.center)
            Text((binding.turboMaxCount ?? 0) > 0 ? "presses" : "presses (0 keeps going)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .hoverHelp("Ends the run after this many presses. 0 means it keeps going until you release, or press again in toggle mode.")
    }

    /// Where a mouse button output clicks: wherever the pointer is, or a
    /// fixed point on screen captured from the pointer's current position.
    @ViewBuilder
    private func clickPointControls(at index: Int) -> some View {
        let fixed = binding.outputs[index].clickX != nil
        Menu {
            Button("Where the pointer is") {
                binding.outputs[index].clickX = nil
                binding.outputs[index].clickY = nil
            }
            Button("At a fixed point: use the pointer's position now") {
                captureClickPoint(at: index)
            }
        } label: {
            menuLabel(fixed
                      ? String(format: "at %.0f, %.0f", binding.outputs[index].clickX ?? 0, binding.outputs[index].clickY ?? 0)
                      : "at pointer")
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .hoverHelp("Click wherever the pointer is, or always at one spot on screen. To set the spot, move the pointer there and pick the second option; the position is taken about two seconds later so you have time to move the mouse away from this menu.")
    }

    /// Records the pointer's position two seconds after the menu closes, so
    /// the user can move the pointer to the target first. Stored in
    /// CoreGraphics coordinates (origin top-left) to match the click events.
    private func captureClickPoint(at index: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            guard binding.outputs.indices.contains(index) else { return }
            let location = NSEvent.mouseLocation
            let height = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
            binding.outputs[index].clickX = Double(location.x.rounded())
            binding.outputs[index].clickY = Double((height - location.y).rounded())
        }
    }

    private var turboIntervalMs: Int {
        if let ms = binding.turboIntervalMs, ms > 0 { return ms }
        return Int((1000.0 / Double(max(1, min(60, binding.turboRate ?? 10)))).rounded())
    }

    private var turboIntervalBinding: SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { turboIntervalMs },
            set: { ms in
                let clamped = max(5, min(60_000, ms))
                binding.turboIntervalMs = clamped
                // Keep the older rate field in step for anything that reads it.
                binding.turboRate = max(1, min(60, Int((1000.0 / Double(clamped)).rounded())))
            }
        )
    }

    private var turboJitterBinding: SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.turboJitterMs ?? 0 },
            set: { binding.turboJitterMs = $0 <= 0 ? nil : min(10_000, $0) }
        )
    }

    private var turboMaxCountBinding: SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.turboMaxCount ?? 0 },
            set: { binding.turboMaxCount = $0 <= 0 ? nil : min(100_000, $0) }
        )
    }

    /// Plain-language answer to "what does this do", under the menu.
    private var pressModeExplanation: String {
        switch pressMode {
        case .normal:
            return "The output is held down for as long as you hold the control, and released when you let go."
        case .toggle:
            return "One press turns the output on and leaves it on. The next press turns it off."
        case .turbo:
            return "The output fires over and over while you hold the control, at the rate below."
        case .autoClick:
            return "Press once to start the output firing over and over, and press again to stop it. An auto-clicker: put a click on this row and it clicks for you."
        case .hold:
            return "A quick tap sends the normal output. Holding past the time below sends something else instead, so one control can do two jobs."
        }
    }

    private var pressModeBinding: SwiftUI.Binding<PressMode> {
        SwiftUI.Binding(
            get: { pressMode },
            set: { mode in
                binding.toggleMode = (mode == .toggle || mode == .autoClick) ? true : nil
                binding.turboEnabled = (mode == .turbo || mode == .autoClick) ? true : nil
                if mode == .hold {
                    if binding.holdOutputs == nil {
                        binding.holdOutputs = [OutputAction(type: .key, keyCode: 225)]
                    }
                } else {
                    binding.holdOutputs = nil
                }
            }
        )
    }

    /// Reflects the binding's ACTUAL macro state, not just editor
    /// visibility. The old bridge read a transient @State, so reopening a
    /// preset showed an unchecked box while a saved macro silently
    /// overrode the row's outputs, and unchecking did not disable it.
    /// Turning it on opens the step editor; turning it off removes the
    /// macro (recoverable with Undo, which restores the whole binding).
    private var macroToggleBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { binding.macroSteps?.isEmpty == false || showMacroEditor },
            set: { on in
                if on {
                    showMacroEditor = true
                } else {
                    binding.macroSteps = nil
                    showMacroEditor = false
                }
            }
        )
    }

    // MARK: - Advanced Bindings

    private var deadzoneBinding: SwiftUI.Binding<Double> {
        SwiftUI.Binding(
            get: { Double(binding.deadzone ?? 0.25) },
            set: { binding.deadzone = Float($0) }
        )
    }

    /// Triggers live on axis indices 4 (left) and 5 (right) by convention.
    /// Used to switch the Calibrate button icon between trigger gauge and
    /// joystick circle styles.
    private var invertExplanation: String {
        switch binding.input.type {
        case .motion: return "Read the tilt the other way round: this row fires when the controller moves opposite to its named direction."
        case .touchpad: return "Read the finger the other way round: a swipe left counts as right and up as down for this row."
        case .stickRegion: return "Mirror the stick before checking the zone, so the zone is entered from the opposite side."
        default: return "Read the stick backwards for this row: pushed left counts as right and up as down, and variable speed follows the reversed value. It is per row, so the row for the other direction is unaffected."
        }
    }

    private var isTriggerAxis: Bool {
        binding.input.type == .axis && (binding.input.index == 4 || binding.input.index == 5)
    }

    /// Like `deadzoneBinding` but always writes the value (even the 0.25 default).
    /// The calibration view always wants to persist what the user picked so the
    /// next time they open the editor the slider matches what they set.
    private var deadzoneCalibrationBinding: SwiftUI.Binding<Double> {
        SwiftUI.Binding(
            get: { Double(binding.deadzone ?? 0.25) },
            set: { binding.deadzone = Float($0) }
        )
    }

    /// Outer deadzone binding for the calibration sheet. Defaults to 1.0
    /// (no saturation), which the view interprets as "no outer ring".
    private var outerDeadzoneBinding: SwiftUI.Binding<Double> {
        SwiftUI.Binding(
            get: { Double(binding.outerDeadzone ?? 1.0) },
            set: { binding.outerDeadzone = $0 >= 0.99 ? nil : Float($0) }
        )
    }

    private var invertBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { binding.invertAxis ?? false },
            set: { binding.invertAxis = $0 ? true : nil }
        )
    }

    private var toggleBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { binding.toggleMode ?? false },
            set: {
                binding.toggleMode = $0 ? true : nil
                if $0 { binding.turboEnabled = nil } // Mutually exclusive
            }
        )
    }

    private var turboBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { binding.turboEnabled ?? false },
            set: {
                binding.turboEnabled = $0 ? true : nil
                if $0 { binding.toggleMode = nil } // Mutually exclusive
            }
        )
    }

    private var turboRateBinding: SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.turboRate ?? 10 },
            set: { binding.turboRate = $0 }
        )
    }

    private var curveBinding: SwiftUI.Binding<SensitivityCurve> {
        SwiftUI.Binding(
            get: { binding.sensitivityCurve ?? .linear },
            set: { binding.sensitivityCurve = $0 == .linear ? nil : $0 }
        )
    }

    private var repeatCountBinding: SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.repeatCount ?? 1 },
            set: { binding.repeatCount = $0 <= 1 ? nil : max(1, min(100, $0)) }
        )
    }

    private var repeatDelayBinding: SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.repeatDelayMs ?? 100 },
            set: { binding.repeatDelayMs = max(10, min(5000, $0)) }
        )
    }

    private var variableSensitivityBinding: SwiftUI.Binding<Bool> {
        // Default: true when input is an axis (matches engine behavior), false otherwise
        let defaultValue = binding.input.type == .axis
        return SwiftUI.Binding(
            get: { binding.variableSensitivity ?? defaultValue },
            set: { binding.variableSensitivity = $0 == defaultValue ? nil : $0 }
        )
    }

    private var hapticBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { binding.hapticEnabled ?? false },
            set: { binding.hapticEnabled = $0 ? true : nil }
        )
    }

    private var hapticIntensityBinding: SwiftUI.Binding<Double> {
        SwiftUI.Binding(
            get: { Double(binding.hapticIntensity ?? 0.6) },
            set: { binding.hapticIntensity = Float($0) }
        )
    }

    private var hapticDurationBinding: SwiftUI.Binding<Double> {
        SwiftUI.Binding(
            get: { Double(binding.hapticDurationMs ?? FeedbackService.defaultDurationMs) },
            set: { v in
                let ms = Int(v.rounded())
                // Under the transient cutoff means "a tap", which is the
                // default, so store nothing and keep the file as it was.
                binding.hapticDurationMs = ms < FeedbackService.transientCutoffMs ? nil : ms
            }
        )
    }

    private func hapticDurationLabel(_ ms: Double) -> String {
        ms < Double(FeedbackService.transientCutoffMs) ? "Tap" :
            ms >= 1000 ? String(format: "%.1f s", ms / 1000) : "\(Int(ms)) ms"
    }

    private var speechBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { binding.speechEnabled ?? false },
            set: { binding.speechEnabled = $0 ? true : nil }
        )
    }

    private var speechTextBinding: SwiftUI.Binding<String> {
        SwiftUI.Binding(
            get: { binding.speechText ?? "" },
            set: { binding.speechText = $0.isEmpty ? nil : $0 }
        )
    }

    private var speechDestinationBinding: SwiftUI.Binding<SpeechDestination> {
        SwiftUI.Binding(
            get: { binding.speechDestination ?? .mac },
            set: { binding.speechDestination = $0 == .mac ? nil : $0 }
        )
    }

    // MARK: - Macro Editor

    private var macroEditorSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Macro steps")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle(isOn: macroStopOnReleaseBinding) {
                    Text("Stop on release")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .hoverHelp("Letting go of the input stops the rest of the sequence and releases any held steps.")
                Button {
                    var steps = binding.macroSteps ?? []
                    steps.append(MacroStep(action: OutputAction(type: .key, keyCode: 4)))
                    binding.macroSteps = steps
                } label: {
                    Label("Add a step", systemImage: "plus.circle")
                        .font(.callout)
                }
                .buttonStyle(.solidSecondaryCompact)
            }

            if let steps = binding.macroSteps, !steps.isEmpty {
                macroStepsList(steps)
            } else {
                Text("No steps yet. Add the first step to build the sequence.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }

            Text("Macros override normal outputs. Steps fire in sequence; a Hold down step keeps its key held while the following steps run (for chords like Cmd+C), and Release lets it go.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }

    private func macroStepsList(_ steps: [MacroStep]) -> some View {
        VStack(spacing: 3) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                macroStepRow(index: index, step: step)
            }
        }
    }

    /// A step is two lines: what it does, then when. The timing used to sit
    /// on the same line as bare "50 50" fields, because their Wait and Hold
    /// labels were the first thing squeezed out of a narrow output column.
    private func macroStepRow(index: Int, step: MacroStep) -> some View {
        VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
            Text("\(index + 1).")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 18)

            Picker("", selection: macroStepKindBinding(at: index)) {
                ForEach(MacroStepKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 84)
            .hoverHelp("Tap presses and releases. Hold down keeps the key held while later steps run (for chords like Cmd+C). Release lets go of a held key.")

            Picker("", selection: macroStepTypeBinding(at: index)) {
                // Only the step types with working parameter editors. The
                // full OutputType list offered Mouse Motion / Wheel steps
                // that fired as silent no-ops and MIDI steps locked to
                // hardcoded defaults; more types can return as they gain
                // per-step editors.
                Text(OutputType.key.displayName).tag(OutputType.key)
                Text(OutputType.mouseButton.displayName).tag(OutputType.mouseButton)
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 100)

            if step.action.type == .key {
                KeyCodePicker(selectedCode: macroStepKeyBinding(at: index))
                    .frame(width: 90)
            } else if step.action.type == .mouseButton {
                Picker("", selection: macroStepMouseBtnBinding(at: index)) {
                    ForEach(0..<6, id: \.self) { i in
                        Text(mouseButtonName(i)).tag(i)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 90)
            }

            HStack(spacing: 2) {
                Button { moveMacroStep(at: index, by: -1) } label: {
                    Image(systemName: "chevron.up")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .disabled(index == 0)
                .hoverHelp("Move step up")
                .accessibilityLabel("Move step up")

                Button { moveMacroStep(at: index, by: 1) } label: {
                    Image(systemName: "chevron.down")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .disabled(index >= (binding.macroSteps?.count ?? 0) - 1)
                .hoverHelp("Move step down")
                .accessibilityLabel("Move step down")

                Button { duplicateMacroStep(at: index) } label: {
                    Image(systemName: "plus.square.on.square")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .hoverHelp("Duplicate step")
                .accessibilityLabel("Duplicate step")
            }
            .foregroundStyle(.secondary)

            Button {
                var steps = binding.macroSteps ?? []
                guard index < steps.count else { return }
                steps.remove(at: index)
                binding.macroSteps = steps.isEmpty ? nil : steps
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove this macro step")

            Spacer()
        }
        HStack(spacing: 4) {
            Spacer().frame(width: 24)
            fieldLabel("Wait")
            TextField("", value: macroDelayBinding(at: index), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 52)
                .controlSize(.small)
                .multilineTextAlignment(.center)
                .accessibilityLabel("Wait before this step, milliseconds")
            fieldLabel("ms before it fires, then hold it for")
            TextField("", value: macroHoldBinding(at: index), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 52)
                .controlSize(.small)
                .multilineTextAlignment(.center)
                .accessibilityLabel("Hold this step, milliseconds")
            fieldLabel("ms")
        }
        }
    }

    private func moveMacroStep(at index: Int, by offset: Int) {
        guard var steps = binding.macroSteps else { return }
        let target = index + offset
        guard steps.indices.contains(index), steps.indices.contains(target) else { return }
        steps.swapAt(index, target)
        binding.macroSteps = steps
    }

    private func duplicateMacroStep(at index: Int) {
        guard var steps = binding.macroSteps, steps.indices.contains(index) else { return }
        let src = steps[index]
        let copy = MacroStep(action: src.action, delayMs: src.delayMs, holdMs: src.holdMs,
                             eventKind: src.eventKind)
        steps.insert(copy, at: index + 1)
        binding.macroSteps = steps
    }

    // MARK: - Macro Bindings

    private var macroStopOnReleaseBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { binding.macroInterruptOnRelease ?? false },
            set: { binding.macroInterruptOnRelease = $0 ? true : nil }
        )
    }

    private func macroStepKindBinding(at index: Int) -> SwiftUI.Binding<MacroStepKind> {
        SwiftUI.Binding(
            get: { binding.macroSteps?[index].eventKind ?? .tap },
            set: {
                guard var steps = binding.macroSteps, index < steps.count else { return }
                steps[index].eventKind = ($0 == .tap) ? nil : $0
                binding.macroSteps = steps
            }
        )
    }

    private func macroStepTypeBinding(at index: Int) -> SwiftUI.Binding<OutputType> {
        SwiftUI.Binding(
            get: { binding.macroSteps?[index].action.type ?? .key },
            set: {
                guard var steps = binding.macroSteps, index < steps.count else { return }
                steps[index].action.type = $0
                binding.macroSteps = steps
            }
        )
    }

    private func macroStepKeyBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.macroSteps?[index].action.keyCode ?? 4 },
            set: {
                guard var steps = binding.macroSteps, index < steps.count else { return }
                steps[index].action.keyCode = $0
                binding.macroSteps = steps
            }
        )
    }

    private func macroStepMouseBtnBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.macroSteps?[index].action.mouseButtonIndex ?? 0 },
            set: {
                guard var steps = binding.macroSteps, index < steps.count else { return }
                steps[index].action.mouseButtonIndex = $0
                binding.macroSteps = steps
            }
        )
    }

    private func macroDelayBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.macroSteps?[index].delayMs ?? 50 },
            set: {
                guard var steps = binding.macroSteps, index < steps.count else { return }
                steps[index].delayMs = max(0, min(10000, $0))
                binding.macroSteps = steps
            }
        )
    }

    private func macroHoldBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.macroSteps?[index].holdMs ?? 50 },
            set: {
                guard var steps = binding.macroSteps, index < steps.count else { return }
                steps[index].holdMs = max(0, min(10000, $0))
                binding.macroSteps = steps
            }
        )
    }

    // MARK: - Helpers

    /// Compact label used by Menu-style controls so they look like Pickers
    /// but with lazy contents. Shows the current value and a chevron.
    @ViewBuilder
    /// The color a region is drawn in on the maps, as a small dot. Zones
    /// are told apart by colour on the touchpad and screen maps, so the
    /// picker and the row show the same dot: matching them by name alone
    /// meant reading every name to find the one you just touched.
    private func regionSwatch(_ colorIndex: Int) -> some View {
        Circle()
            .fill(regionPaletteColor(at: colorIndex))
            .frame(width: 9, height: 9)
            .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 0.5))
    }

    /// One region in a picker: its colour, then its name.
    private func regionMenuLabel(_ region: TouchpadRegion) -> some View {
        HStack(spacing: 6) {
            regionSwatch(region.colorIndex)
            Text(region.name)
        }
    }

    /// Menu label for a chosen region: the dot sits before the name.
    private func regionMenuLabel(name: String, colorIndex: Int?) -> some View {
        HStack(spacing: 4) {
            if let colorIndex { regionSwatch(colorIndex) }
            menuLabel(name)
        }
    }

    private func menuLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.up.chevron.down")
                .font(.callout)
                .foregroundStyle(.secondary)
                .layoutPriority(1)
        }
    }

    /// Parameter editor for .systemAction outputs. Parameterless kinds get
    /// a one-line explainer; Run Shortcut gets a text field plus a picker
    /// of the user's installed Shortcuts; Open App / Open URL get a field.
    @ViewBuilder
    private func systemActionControls(at index: Int) -> some View {
        let kind = binding.outputs[index].systemActionKind ?? .playPause
        switch kind {
        case .runShortcut:
            HStack(spacing: 6) {
                TextField("Shortcut name", text: outputTextBinding(at: index))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(minWidth: 140)
                Menu {
                    let names = systemLists.shortcuts
                    if names.isEmpty {
                        Text("No Shortcuts found")
                    } else {
                        ForEach(names, id: \.self) { name in
                            Button(name) { binding.outputs[index].text = name }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.callout)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Choose a Shortcut")
                .hoverHelp("Pick one of your installed Shortcuts.")
            }
        case .openApp:
            TextField("App name or full path", text: outputTextBinding(at: index))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(minWidth: 160)
                .hoverHelp("An app name like Safari, a bundle identifier, or a full .app path.")
        case .openURL:
            TextField("https:// or any URL scheme", text: outputTextBinding(at: index))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(minWidth: 160)
                .hoverHelp("Opens in the default handler. Any scheme works: https, mailto, facetime, shortcuts.")
        default:
            // Never .fixedSize() horizontally: that lets a long explainer
            // force the row wider than the editor sheet, which pushes the
            // whole scroll content sideways and clips it. Truncate instead.
            Text(systemActionExplainer(kind))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func systemActionExplainer(_ kind: SystemActionKind) -> String {
        switch kind {
        case .volumeUp, .volumeDown: return "Nudges the Mac's volume one step per press"
        case .muteToggle: return "Toggles the Mac's output mute"
        case .playPause, .nextTrack, .previousTrack: return "Sends the keyboard's media key"
        case .brightnessUp, .brightnessDown: return "Nudges the built-in display's brightness"
        case .missionControl: return "Opens Mission Control"
        case .launchpad: return "Opens Launchpad"
        case .spotlight: return "Presses Cmd+Space"
        case .lockScreen: return "Locks the screen (Ctrl+Cmd+Q)"
        case .screenshotMenu: return "Opens the screenshot toolbar (Cmd+Shift+5)"
        case .keyboardBrightnessUp, .keyboardBrightnessDown:
            return "Nudges the keyboard backlight"
        case .startDictation:
            return "Presses the dictation key, same as F5"
        case .speakSelection: return "Speaks the selected text (Option+Esc)"
        case .zoomToggle: return "Turns screen zoom on and off (Option+Cmd+8)"
        case .zoomIn: return "Zooms the screen in (Option+Cmd+=)"
        case .zoomOut: return "Zooms the screen out (Option+Cmd+-)"
        case .runShortcut, .openApp, .openURL: return ""
        }
    }

    /// Title for the output-type menu. System Function rows show the
    /// specific function ("Volume Up"), not the generic category.
    private func outputMenuTitle(_ output: OutputAction) -> String {
        if output.type == .systemAction, let kind = output.systemActionKind {
            return kind.displayName
        }
        return output.type.displayName
    }

    private func outputIcon(for action: OutputAction) -> String {
        switch action.type {
        case .key: return "keyboard"
        case .typeText: return "text.cursor"
        case .appAction: return "arrow.triangle.2.circlepath"
        case .absoluteVolume: return "speaker.wave.2.fill"
        case .systemAction: return action.systemActionKind?.iconName ?? "gearshape.fill"
        case .mouseButton, .mouseMotion, .mouseWheel, .mouseWheelStep: return "computermouse"
        case .midiNote: return "music.note"
        case .midiCC: return "slider.horizontal.3"
        case .midiPitchBend: return "waveform.path"
        case .midiProgramChange: return "guitars"
        case .midiTransport: return "playpause"
        }
    }

    private func outputColor(for action: OutputAction) -> Color {
        switch action.type {
        case .key, .typeText: return .orange
        case .appAction: return .teal
        case .absoluteVolume: return .teal
        case .systemAction: return .teal
        case .mouseButton, .mouseMotion, .mouseWheel, .mouseWheelStep: return .purple
        case .midiNote, .midiCC, .midiPitchBend, .midiProgramChange, .midiTransport: return .pink
        }
    }

    private func mouseButtonName(_ index: Int) -> String {
        switch index {
        case 0: return "0 - Main Click"
        case 1: return "1 - Secondary"
        case 2: return "2 - Middle"
        case 3: return "3 - Back"
        case 4: return "4 - Forward"
        case 5: return "5 - Extra"
        default: return "\(index)"
        }
    }

    // MARK: - Bindings

    private var axisDirectionBinding: SwiftUI.Binding<AxisDirection> {
        SwiftUI.Binding(
            get: { binding.input.axisDirection ?? .positive },
            set: { binding.input.axisDirection = $0 }
        )
    }

    private var hatDirectionBinding: SwiftUI.Binding<HatDirection> {
        SwiftUI.Binding(
            get: { binding.input.hatDirection ?? .up },
            set: { binding.input.hatDirection = $0 }
        )
    }

    private var firstOutputTypeBinding: SwiftUI.Binding<OutputType> {
        SwiftUI.Binding(
            get: { binding.outputs.first?.type ?? .key },
            set: { binding.outputs[0].type = $0 }
        )
    }

    private func outputBinding(at index: Int) -> SwiftUI.Binding<OutputAction> {
        SwiftUI.Binding(
            get: { binding.outputs[index] },
            set: { binding.outputs[index] = $0 }
        )
    }

    private func outputTypeBinding(at index: Int) -> SwiftUI.Binding<OutputType> {
        SwiftUI.Binding(
            get: { binding.outputs[index].type },
            set: { binding.outputs[index].type = $0 }
        )
    }

    private func keyCodeBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.outputs[index].keyCode ?? 4 },
            set: { binding.outputs[index].keyCode = $0 }
        )
    }

    private func mouseAxisDirBinding(at index: Int) -> SwiftUI.Binding<String> {
        SwiftUI.Binding(
            get: {
                let axis = binding.outputs[index].mouseAxis?.rawValue ?? 1
                let dir = binding.outputs[index].mouseDirection?.rawValue ?? "-"
                return "\(axis) \(dir)"
            },
            set: { newValue in
                let parts = newValue.split(separator: " ")
                if parts.count >= 2,
                   let axisVal = Int(parts[0]),
                   let axis = MouseAxis(rawValue: axisVal) {
                    binding.outputs[index].mouseAxis = axis
                    binding.outputs[index].mouseDirection = MouseDirection(rawValue: String(parts[1]))
                }
            }
        )
    }

    private func speedBinding(at index: Int) -> SwiftUI.Binding<Double> {
        SwiftUI.Binding(
            get: { Double(binding.outputs[index].speed ?? 6) },
            set: { binding.outputs[index].speed = Int($0) }
        )
    }

    /// TextField binding that reads from the live drag mirror so the box
    /// updates while the user is sliding, and writes go to both the mirror
    /// and the underlying preset (so typing into the field still works).
    private func liveSpeedBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: {
                if let live = liveSpeed[index] { return Int(live) }
                return binding.outputs[index].speed ?? 6
            },
            set: { newValue in
                let clamped = max(1, min(50, newValue))
                binding.outputs[index].speed = clamped
                liveSpeed[index] = Double(clamped)
            }
        )
    }

    // MARK: - MIDI Bindings

    private func midiVelocityBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.outputs[index].midiVelocity ?? 100 },
            set: { binding.outputs[index].midiVelocity = max(0, min(127, $0)) }
        )
    }

    private func midiChannelBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.outputs[index].midiChannel ?? 1 },
            set: { binding.outputs[index].midiChannel = max(1, min(16, $0)) }
        )
    }

    private func midiTransportBinding(at index: Int) -> SwiftUI.Binding<MIDITransport> {
        SwiftUI.Binding(
            get: { binding.outputs[index].midiTransport ?? .start },
            set: { binding.outputs[index].midiTransport = $0 }
        )
    }

    private func removeOutput(at index: Int) {
        withAnimation(.easeInOut(duration: 0.2)) {
            binding.outputs.remove(at: index)
        }
    }
}


// MARK: - Row tooltips

/// Tooltips are attached to every row unconditionally.
///
/// The previous version gated them on a per-row hover flag to avoid AppKit
/// tooltip rects. That trade was a loss: the gate is a structural change, so
/// hovering a row swapped its view identity and forced a full rebuild plus a
/// height re-measure of that row. With the pointer parked over the list while
/// scrolling, every row passing under it rebuilt twice per pass, cascading
/// into `NSHostingView.layout` and `AccessibilityNode.updateFocus` work on
/// every display cycle. Static structure is measurably cheaper.
extension View {
    func hoverHelp(_ text: String) -> some View {
        help(text)
    }
}


// MARK: - Drag handle

/// Mouse tracking for the row's reorder handle.
///
/// Deliberately AppKit: an `NSView` instance survives SwiftUI body updates, so
/// a drag keeps running while the row it belongs to re-renders. Reports the
/// pointer's downward travel in points since the press, measured on screen so
/// it is unaffected by the row moving.
private struct RowDragHandle: NSViewRepresentable {
    var onBegan: () -> Void
    var onChanged: (CGFloat) -> Void
    var onEnded: () -> Void

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        view.apply(self)
        return view
    }

    func updateNSView(_ nsView: HandleView, context: Context) {
        nsView.apply(self)
    }

    final class HandleView: NSView {
        private var onBegan: () -> Void = {}
        private var onChanged: (CGFloat) -> Void = { _ in }
        private var onEnded: () -> Void = {}
        private var pressedAt: NSPoint?

        func apply(_ source: RowDragHandle) {
            onBegan = source.onBegan
            onChanged = source.onChanged
            onEnded = source.onEnded
        }

        override func mouseDown(with event: NSEvent) {
            pressedAt = NSEvent.mouseLocation
            onBegan()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = pressedAt else { return }
            // Screen coordinates are y-up; a view offset is y-down.
            onChanged(start.y - NSEvent.mouseLocation.y)
        }

        override func mouseUp(with event: NSEvent) {
            guard pressedAt != nil else { return }
            pressedAt = nil
            onEnded()
        }
    }
}


// MARK: - Motion row panel

/// Live readout for a gyro / accelerometer row: the chosen channel as a
/// centerd bar with the deadzone shaded on it, lit green when the row would
/// fire, plus Quick Zero and the full calibration sheet. Owns its own 30 Hz
/// read of the controller state so the row itself stays static.
struct MotionRowPanel: View {
    let slot: Int
    let channel: MotionChannel
    let direction: AxisDirection?
    let invert: Bool
    let deadzone: Double

    @EnvironmentObject private var controllerService: GameControllerService
    @State private var value: Float = 0
    @State private var hasMotion = false
    @State private var showCalibration = false
    @State private var zeroFlashUntil: Date?

    /// Full-scale of the bar per channel: gyro rates in rad/s, the rest
    /// already normalised to about -1...1.
    private var scale: Float {
        switch channel {
        case .gyroX, .gyroY, .gyroZ: return 3
        default: return 1
        }
    }

    private var unit: String {
        switch channel {
        case .gyroX, .gyroY, .gyroZ: return "rad/s"
        case .accelX, .accelY, .accelZ: return "g"
        default: return ""
        }
    }

    /// Mirrors the engine's motion check exactly.
    private var firing: Bool {
        let v = invert ? -value : value
        let dz = Float(deadzone)
        switch direction {
        case .positive: return v > dz
        case .negative: return v < -dz
        case .none:     return abs(v) > dz
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(channel.menuDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 132, alignment: .leading)
                meter
                    .frame(width: 170, height: 12)
                Text(hasMotion ? String(format: "%+.2f %@", value, unit) : "no motion")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(firing ? Color.green : Color.secondary)
                    .frame(width: 96, alignment: .leading)
            }
            Text(hasMotion
                 ? "Move the controller the way this row should fire. The bar turns green when it would; the grey band is the deadzone."
                 : "Connect a controller with motion (DualSense, DualShock 4, Switch Pro, Joy-Con) to see it move.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    if controllerService.rezeroMotion(slot: slot) {
                        zeroFlashUntil = Date().addingTimeInterval(2)
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "scope").font(.callout)
                        Text("Quick Zero").font(.callout)
                    }
                    .foregroundStyle(.tint)
                }
                .buttonStyle(.solidSecondaryCompact)
                .disabled(!hasMotion)
                .hoverHelp("Rest the controller and click: its reading right now becomes the new zero. Use it whenever motion drifts. A controller button can do the same: App Action, Re-zero Motion.")

                Button {
                    showCalibration = true
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "gyroscope").font(.callout)
                        Text("Calibrate").font(.callout)
                    }
                    .foregroundStyle(.tint)
                }
                .buttonStyle(.solidSecondaryCompact)
                .hoverHelp("Open Motion Calibration: a careful multi-second capture, live sensor readings, and a controller button for re-zeroing.")

                if let until = zeroFlashUntil, until > Date() {
                    Label("Zeroed", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                }
            }
        }
        .onReceive(Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()) { _ in
            let motion = controllerService.currentStates[slot]?.motion
            hasMotion = !(motion?.isEmpty ?? true)
            value = motion?[channel] ?? 0
            if let until = zeroFlashUntil, until <= Date() { zeroFlashUntil = nil }
        }
        .sheet(isPresented: $showCalibration) {
            MotionCalibrationView()
                .environmentObject(controllerService)
                .glassBackground()
        }
    }

    private var meter: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let half = w / 2
            let dzHalf = min(half, CGFloat(Float(deadzone) / scale) * half)
            let clamped = max(-1, min(1, value / scale))
            let fill = abs(CGFloat(clamped)) * half
            // Which half of the bar this row listens to, after invert.
            let listensPositive: Bool? = {
                guard let d = direction else { return nil }
                return (d == .positive) != invert
            }()
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.12))
                // The half the row does not listen to is dimmed further.
                if let pos = listensPositive {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.08))
                        .frame(width: half)
                        .offset(x: pos ? 0 : half)
                }
                // Deadzone band, centerd.
                Rectangle()
                    .fill(Color.secondary.opacity(0.28))
                    .frame(width: dzHalf * 2)
                    .offset(x: half - dzHalf)
                Rectangle()
                    .fill(firing ? Color.green : Color.accentColor.opacity(0.8))
                    .frame(width: fill)
                    .offset(x: clamped >= 0 ? half : half - fill)
                Rectangle()
                    .fill(Color.primary.opacity(0.4))
                    .frame(width: 1)
                    .offset(x: half)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }
}

/// DEBUG-only: `post inputconfig.debug.toggleoptions <row number>` runs the
/// Options button's action on that row, so the fold can be captured without
/// clicking into the window.
private struct DebugToggleOptionsModifier: ViewModifier {
    let displayNumber: Int
    let toggle: () -> Void
    func body(content: Content) -> some View {
        #if DEBUG
        content.onReceive(DistributedNotificationCenter.default().publisher(
            for: Notification.Name("inputconfig.debug.toggleoptions"))) { note in
            if let n = Int(note.object as? String ?? ""), n == displayNumber { toggle() }
        }
        #else
        content
        #endif
    }
}


/// Opens the touchpad calibrator from a touchpad row's Options.
private struct TouchpadCalibrateButton: View {
    @EnvironmentObject private var presetStore: PresetStore
    @State private var showing = false
    var body: some View {
        Button {
            showing = true
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "rectangle.and.hand.point.up.left.fill").font(.callout)
                Text("Calibrate Touchpad").font(.callout)
            }
            .foregroundStyle(.tint)
        }
        .buttonStyle(.solidSecondaryCompact)
        .fixedSize()
        .help("Calibrate the touchpad surface and draw tap regions")
        .sheet(isPresented: $showing) {
            TouchpadCalibrationView()
                .environmentObject(presetStore)
                .glassBackground()
        }
    }
}

/// Opens the tap calibrator from a Tap the Mac row's Options.
private struct TapCalibrateButton: View {
    @State private var showing = false
    var body: some View {
        Button {
            showing = true
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "hand.tap").font(.callout)
                Text("Calibrate Taps").font(.callout)
            }
            .foregroundStyle(.tint)
        }
        .buttonStyle(.solidSecondaryCompact)
        .fixedSize()
        .help("Watch taps on the MacBook live and set the strength that counts as a tap")
        .sheet(isPresented: $showing) {
            TapCalibrationView()
                .glassBackground()
        }
    }
}
