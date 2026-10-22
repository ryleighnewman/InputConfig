import SwiftUI
import Combine

/// A single binding row with fixed-width columns for consistent alignment.
struct BindingRowView: View {
    /// Key names follow the input source; a change to it redraws the row.
    @ObservedObject private var keyboardLayout = KeyboardLayoutService.shared
    /// The preset's controller family, set by the editor; names the face buttons.
    @Environment(\.presetButtonFamily) private var presetButtonFamily
    @Environment(\.buttonModelNames) private var buttonModelNames
    @Environment(\.deviceButtonNames) private var deviceButtonNames
    @SwiftUI.Binding var binding: BindingModel
    let onScan: () -> Void
    /// Scan for the chord's second control (any input on any device).
    /// Scans a chord control. The slot index replaces that held control;
    /// nil adds a new one.
    var onScanModifier: (Int?) -> Void = { _ in }
    let onRemove: () -> Void
    var onDuplicate: (() -> Void)?
    /// Starts a reorder drag from the handle. Owned by the group, which
    /// holds the array being reordered.
    /// Live reorder callbacks from the drag handle. Vertical translation in
    /// points, then a single end call. The parent owns the ordering.
    var onDragChanged: ((CGFloat) -> Void)? = nil
    var onDragEnded: (() -> Void)? = nil
    /// Moves the row up (-1) or down (+1) without a drag: the handle's
    /// menu, its arrow keys, and an accessibility action.
    var onMove: ((Int) -> Void)? = nil
    var isHighlighted: Bool = false
    /// 1-based position of this binding within its joystick group. Drives the
    /// "#N" chip at the start of every row so the Live Visualizer can refer
    /// to a specific row by number.
    var displayNumber: Int = 0
    /// For a zone row: the numbers of the stick's direction rows the zone
    /// overlaps, worked out by the group (rows do not see each other).
    var zoneOverlap: [Int] = []
    /// For a zone row: the numbers of the zone rows whose zones share part
    /// of this one.
    var zoneZoneOverlap: [Int] = []
    /// For a direction row: the zone rows that take it over inside their
    /// zones.
    var zoneTakenBy: [Int] = []
    /// True while this row is the target of a jump-to-binding pulse triggered
    /// by clicking on the Live Visualizer. Shows a yellow ring for ~1.2 s.
    var isPulsing: Bool = false
    /// Set after the row above it was removed: focus moves here.
    var takesFocus: Bool = false

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


    /// Joystick slot this row's group belongs to, for the live motion meter
    /// on gyro rows.
    var slot: Int = 0

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReduceMotion) private var appReduceMotion
    /// The system setting or the app's own Reduce motion switch.
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    /// True while this row's Mac key or mouse button Scan listens.
    @State private var externalScanning = false
    /// Seconds left on that scan, shown on the row so the limit is seen,
    /// not only spoken; and a short visible note when it ran out.
    @State private var externalScanLeft = 0
    @State private var externalScanTimedOut = false
    /// Seconds until a fixed click point is taken, shown on its menu.
    @State private var clickPointLeft: Int?
    /// Which output the countdown is for, so only its menu shows it.
    @State private var clickPointTarget: String?
    @State private var showAdvanced = false
    @State private var showMacroEditor = false
    @State private var liveOuterDeadzone: Double?
    @State private var showDeadzoneCalibration = false
    /// Region editors opened straight from the input pickers, so defining a
    /// missing cursor/stick region doesn't require a detour through Settings.
    @State private var showGestureRecorder = false
    /// The axis and direction a row read before a zone was picked for it,
    /// so "Whole stick or trigger, no zone" puts back exactly that.
    @State private var axisBeforeZone: (index: Int, direction: AxisDirection?, invert: Bool?)?
    /// Drives the firing arrow's left-to-right sweep while highlighted.
    @State private var arrowShoot = false
    /// The Options box a menu choice just turned on ("feedback", "macro",
    /// "extra"): once Options has opened, the editor scrolls it into view
    /// and it glows once in the accent color, so the eye finds it.
    static let revealRow = Notification.Name("InputConfig.RevealRow")
    @State private var spotlightBox: String?
    @State private var spotlightGlow: String?

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
    /// Grows with Text Size, like the other columns, so "#12" and "Notes" fit.
    private var numberColWidth: CGFloat { Self.numberColWidth(scale: textScale) }
    static func numberColWidth(scale: CGFloat) -> CGFloat { 40 * max(1, scale) }
    /// Where sub-rows (note, Options) start: under the Scan column, past the
    /// handle and the number, so every line of the row shares one left edge.
    /// Where the Options boxes start: just inside the row, so the left box
    /// uses the width under the drag handle and row number too.
    private var optionsInset: CGFloat { 10 }
    private var leftGutter: CGFloat {
        dragWidth + colGap + (displayNumber > 0 ? numberColWidth + colGap : 0)
    }
    @Environment(\.appTextScale) private var textScale
    /// Column widths grow with Text Size, so the labels in them do not
    /// clip at Extra Large and Huge.
    private var scanColWidth: CGFloat { 54 * max(1, textScale) }
    /// Wider than before (was 78) so the full input-type names like
    /// "Keyboard Key", "Cursor Region", "Stick Region" actually show
    /// in the picker label instead of getting truncated to "Keyboa…"
    /// which made the picker look locked.
    private var typeColWidth: CGFloat { 116 * max(1, textScale) }
    private var indexColWidth: CGFloat { 124 * max(1, textScale) }
    /// Wider than before (was 58) because for extKey / extMouse this
    /// column hosts the device picker, and device names like
    /// "Built-in Keyboard" overflowed and visually collided with the
    /// next column's keyboard icon.
    private var dirColWidth: CGFloat { 130 * max(1, textScale) }
    private let arrowWidth: CGFloat = 24
    /// Wide enough for "Mission Control" and "Speak Selection" next to their
    /// icon without truncating to "Mission Cont…".
    private var outTypeColWidth: CGFloat { 156 * max(1, textScale) }
    /// The one horizontal gap used everywhere on the primary row: between
    /// the boxes and the arrow, between controls inside a box, and between
    /// an output's icon and its menu. Consistent spacing is what makes the
    /// two halves read as the same kind of thing.
    private let gap: CGFloat = 8
    /// Every output icon sits in a cell this wide, scaled to fit, so a wide
    /// symbol (Mission Control) and a narrow one (a lock) leave the same
    /// distance to the menu after them.
    private let iconCell: CGFloat = 18
    private let actionsWidth: CGFloat = 28
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
    static func inputBoxLeading(scale: CGFloat) -> CGFloat { 10 + 20 + 8 + numberColWidth(scale: scale) + 8 }
    /// The input columns grow with Text Size, so everything placed from
    /// them takes the same scale.
    static func inputBoxWidth(scale: CGFloat) -> CGFloat {
        (54 + 116 + 124 + 130) * max(1, scale) + 8 * 3 + boxPadH * 2
    }
    static let arrowSlotWidth: CGFloat = 24 + 8 * 2
    /// The trailing action buttons plus the row's own right padding.
    static let actionsSlotWidth: CGFloat = 28 + 18 + 10
    /// Where the column brackets the group draws above its rows start and
    /// end: the Input bracket runs from just after the number chip to just
    /// before the arrow, the Output bracket from just after the arrow to the
    /// row's right edge. Measured from the row box's left edge.
    static func inputBracketLeading(scale: CGFloat) -> CGFloat { 10 + 20 + 8 + numberColWidth(scale: scale) - 10 }
    static func inputBracketWidth(scale: CGFloat) -> CGFloat {
        inputBoxLeading(scale: scale) + inputBoxWidth(scale: scale) - 4 - inputBracketLeading(scale: scale)
    }
    static func outputBracketLeading(scale: CGFloat) -> CGFloat {
        inputBoxLeading(scale: scale) + inputBoxWidth(scale: scale) + arrowSlotWidth + 4
    }
    static let bracketTrailing: CGFloat = 10
    /// How much wider the editor gets at this Text Size: the input and
    /// output columns that scale.
    static func extraEditorWidth(scale: CGFloat) -> CGFloat {
        (40 + 54 + 116 + 124 + 130 + 156) * (max(1, scale) - 1)
    }

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
            // One named container per row for VoiceOver ("Row 3, A to
            // Space"), so a row's start and what it maps are heard before
            // its parts, and its Move actions have a home.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(rowAccessibilityLabel)
            // Jumped to from search or the Live Visualizer: VoiceOver goes there.
            .accessibilityFocused($jumpFocus)
            .onChange(of: takesFocus) { _, on in
                guard on else { return }
                jumpFocus = true
                keyboardFocus = true
            }
            .onChange(of: isPulsing) { _, on in
                guard on else { return }
                // Keyboard focus too: a search or visualizer jump left it in
                // the search field, dozens of Tabs away from the row.
                keyboardFocus = true
                // The focus move reads the row; the announcement is for a
                // screen reader without VoiceOver's focus (Speak Selection).
                jumpFocus = true
                if !NSWorkspace.shared.isVoiceOverEnabled {
                    AccessibilityNotification.Announcement(rowAccessibilityLabel).post()
                }
            }
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
                    .accessibilityHint("Drag to reorder, or use Move Up and Move Down")
                    // Without dragging: a right-click menu (pointer, dwell and
                    // Voice Control), the arrow keys once focused (keyboard),
                    // and actions (VoiceOver, Switch Control).
                    .contextMenu {
                        Button("Move Up") { onMove?(-1) }
                        Button("Move Down") { onMove?(1) }
                    }
                    .focusable(onMove != nil)
                    .onKeyPress(.upArrow) { onMove?(-1); return onMove == nil ? .ignored : .handled }
                    .onKeyPress(.downArrow) { onMove?(1); return onMove == nil ? .ignored : .handled }
                    .accessibilityAction(named: "Move Up") { onMove?(-1) }
                    .accessibilityAction(named: "Move Down") { onMove?(1) }

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
                // a bolt while the row is firing. VoiceOver hears the firing
                // state from the Input box's value, hence the hidden marker.
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
                    .focused($keyboardFocus)
                    .accessibilityLabel("Scan binding \(displayNumber)")
                    .accessibilityInputLabels([Text("Scan"), Text("Scan binding \(displayNumber)")])
                    .accessibilityHint("Press a button, key, or axis on your controller to record this binding")

                // COL 2: Input Type. A lazy Menu (matching KeyCodePicker and
                // the index picker) instead of Picker: NSPopUpButton-backed
                // Pickers pre-build every item on row creation, which made
                // scrolling the binding list hitch as rows materialized.
                // Grouped so the first decision on every row is no longer an
                // undifferentiated 11-item list.
                SearchableMenu(choices: { inputTypeSearchChoices }) {
                    Section("Controller") {
                        inputTypeChoice(.button)
                        inputTypeChoice(.axis)
                        inputTypeChoice(.hat)
                        inputTypeChoice(.stickGesture)
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
                    // Stick zones and trigger bands are part of an axis, picked
                    // in the axis menu; a screen region is its own input.
                    Section("Screen") {
                        inputTypeChoice(.cursorRegion)
                    }
                    Section("MIDI") {
                        inputTypeChoice(.midi)
                    }
                } label: {
                    menuChevronLabel(typeMenuTitle)
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .frame(width: typeColWidth, alignment: .leading)
                .accessibilityLabel("Input type")
                .accessibilityValue(typeMenuTitle)
                // Voice Control answers to the word shown first.
                .accessibilityInputLabels([Text(typeMenuTitle), Text("Input type"),
                                           Text("Input type \(displayNumber)")])

                // COL 3: Index
                indexPicker
                    .frame(width: indexColWidth, alignment: .leading)
                    .accessibilityLabel(indexPickerAccessibilityLabel)
                    .accessibilityValue(indexPickerAccessibilityValue)
                    .accessibilityInputLabels([Text(indexPickerAccessibilityValue), Text(indexPickerAccessibilityLabel)])

                // COL 4: Direction (or empty spacer for Button type)
                directionPicker
                    .frame(width: dirColWidth, alignment: .leading)
                    .accessibilityLabel(directionPickerAccessibilityLabel)
                    .accessibilityValue(directionPickerAccessibilityValue)
                    .accessibilityInputLabels([Text(directionPickerAccessibilityValue), Text(directionPickerAccessibilityLabel)])

                }
                .padding(.horizontal, Self.boxPadH)
                .padding(.vertical, Self.boxPadV)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Input")
                .accessibilityValue(isHighlighted ? String(localized: "Firing") : "")

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
                    outputMenu(select: { type in
                            var action = OutputAction(type: .key, keyCode: 4)
                            action.type = type
                            action.fillDefaultsForType()
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
                        }) {
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

                        outputMenu(select: { firstOutputTypeBinding.wrappedValue = $0 },
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
                                   },
                                   keyInShortcut: OutputAction.isShortcut(Array(binding.outputs.dropFirst()))) {
                            menuChevronLabel(outputMenuTitle(binding.outputs[0]))
                        }
                        .menuStyle(.borderlessButton)
                        .controlSize(.small)
                        .accessibilityLabel("Output type")
                        .accessibilityValue(outputMenuTitle(binding.outputs[0]))
                        .accessibilityInputLabels([Text(outputMenuTitle(binding.outputs[0])), Text("Output type"),
                                                   Text("Output type \(displayNumber)")])
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
                if !binding.outputs.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            binding.outputs.append(OutputAction(type: .key, keyCode: 4))
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle")
                            Text("Add another output")
                        }
                        .font(.callout)
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 16 + gap)
                    .padding(.top, 2)
                    .accessibilityLabel("Add output")
                    .accessibilityInputLabels([Text("Add output"), Text("Add output \(displayNumber)")])
                }
                }
                .padding(.horizontal, Self.boxPadH)
                .padding(.vertical, Self.boxPadV)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Output")

                // Actions: copy and delete. Adding an output is a labeled
                // button under the outputs, not a corner icon.
                HStack(spacing: 3) {
                    if let onDuplicate {
                        CopyIconButton(action: onDuplicate,
                                       helpText: "Duplicate this binding",
                                       announcement: nil)
                            .accessibilityLabel("Duplicate this binding")
                    }

                    Button(action: onRemove) {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red.opacity(0.7))
                            .font(.callout)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove binding")
                    .accessibilityInputLabels([Text("Remove binding"), Text("Remove binding \(displayNumber)")])
                }
                .frame(width: actionsWidth + 18, alignment: .trailing)
            }

            // Tap the Mac reads a sensor only some MacBooks have; the row says so.
            if binding.input.type == .chassisTap {
                HStack(alignment: .firstTextBaseline, spacing: colGap) {
                    Color.clear.frame(width: numberColWidth, height: 1)
                    Text(Self.tapTheMacDisclaimer)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 3)
            }

            // Advanced options
            advancedSection

            // Per-binding note: a short line describing what this control
            // does, under Options so the mapping and its options read as
            // one block. Smart presets auto-fill it; users can edit or add
            // their own.
            noteRow
                .padding(.top, 5)
                .padding(.bottom, 1)
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
            // Jump-to-binding highlight after a click on the Live Visualizer
            // or a search result: a solid yellow ring over a yellow wash,
            // eased in quickly, held while the row is the target, and faded
            // out slowly so the eye lands on it.
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.yellow.opacity(isPulsing ? 0.18 : 0))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.yellow.opacity(isPulsing ? 1 : 0), lineWidth: 3))
                .allowsHitTesting(false)
                .animation(isPulsing ? .easeIn(duration: 0.2) : .easeOut(duration: 1.1), value: isPulsing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .debugExpandOptions($showAdvanced)
        .modifier(DebugToggleOptionsModifier(displayNumber: displayNumber, toggle: toggleOptions, adjustLive: { showDeadzoneCalibration = true }))
        .sheet(isPresented: $showDeadzoneCalibration) {
            DeadzoneCalibrationView(
                axisIndex: binding.input.type == .stickRegion ? zoneRowAxis : binding.input.index,
                deadzone: deadzoneCalibrationBinding,
                outerDeadzone: outerDeadzoneBinding,
                isInverted: binding.invertAxis ?? false,
                onClose: { showDeadzoneCalibration = false },
                slot: slot,
                rowID: binding.id,
                zonesKey: zonesSheetKey,
                direction: binding.input.type == .axis ? binding.input.axisDirection : nil,
                fullTravel: binding.fullTravel == true
            )
            .glassBackground()
        }
        // The group's Regions section sends you back here.
        .modifier(RevealRowOnRequest(rowID: binding.id))
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name("InputConfig.ExpandBindingOptions"))) { note in
            // Tutorial / external trigger to auto-expand this row's
            // Options disclosure so the user sees what's inside
            // without having to click. Notification's object is the
            // target binding's UUID; we only react if it matches us.
            if let id = note.object as? UUID, id == binding.id {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.4)) { showAdvanced = true }
            }
        }
        // The live mirrors only follow a drag. Once the row's committed
        // values change (a release, Undo, Stick settings) or Options
        // closes, drop them so a readout never shows an old value.
        .onChange(of: binding) { _, _ in clearLiveMirrors() }
        .onChange(of: showAdvanced) { _, open in if !open { clearLiveMirrors() } }
        .onDisappear {
            // Cancel any in-flight scan when this row goes away.
            // Without this, closing the editor mid-scan leaves the
            // static timer/subscription alive; when its 5-second
            // deadline fires it writes into a `@Binding` whose source
            // is gone, routing the keypress to a stale preset draft.
            Self.cancelActiveScan()
        }
    }

    @AccessibilityFocusState private var jumpFocus: Bool
    /// Keyboard focus on the row's Scan button, for the same jumps.
    @FocusState private var keyboardFocus: Bool

    private var rowAccessibilityLabel: String {
        let input = MappingEngine.spokenInputName(binding.input, family: presetButtonFamily)
        let outputs = binding.outputs.isEmpty ? String(localized: "nothing bound")
            : OutputAction.names(binding.outputs).map(HotKeySpec.spokenKey).joined(separator: " + ")
        return String(localized: "Row \(displayNumber), \(input) to \(outputs)")
    }

    // MARK: - Per-binding note

    /// Bridges the optional `binding.note` to a non-optional String the
    /// TextField can edit. Writing an all-whitespace value clears it back to
    /// nil so empty notes don't bloat the saved preset.
    private var noteBinding: SwiftUI.Binding<String> {
        // A built-in row's note shows in the app's language and stays
        // English on disk unless the person changes it.
        SwiftUI.Binding(
            get: { ShippedText.t(binding.note ?? "") },
            set: { newValue in
                guard newValue != ShippedText.t(binding.note ?? "") else { return }
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
    /// Return in the note field hands focus back to the note's button, not
    /// to nothing (the field it was in goes away).
    @FocusState private var noteButtonFocused: Bool
    @FocusState private var phraseFocused: Bool

    @ViewBuilder
    private var noteRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: colGap) {
            // "Notes" sits in the number column so the line is labeled the
            // same way the primary row is numbered; the text itself starts
            // under the Scan column.
            Text("Notes")
                .font(.callout)
                .foregroundStyle(.hint)
                .frame(width: numberColWidth, alignment: .leading)
            if editingNote {
                TextField("Add a note (what this control does)", text: noteBinding)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .foregroundStyle((binding.note?.isEmpty ?? true) ? AnyShapeStyle(.hint) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .focused($noteFieldFocused)
                    .onSubmit {
                        editingNote = false
                        EditorInlineEdit.clear(binding.id)
                        DispatchQueue.main.async { noteButtonFocused = true }
                    }
                    .onChange(of: noteFieldFocused) { _, focused in
                        if !focused { editingNote = false; EditorInlineEdit.clear(binding.id) }
                    }
            } else {
                Button {
                    editingNote = true
                    DispatchQueue.main.async { noteFieldFocused = true }
                    EditorInlineEdit.begin(binding.id) {
                        editingNote = false
                        DispatchQueue.main.async { noteButtonFocused = true }
                        return true
                    }
                } label: {
                    Text((binding.note?.isEmpty ?? true)
                         ? String(localized: "Add a note (what this control does)")
                         : ShippedText.t(binding.note ?? ""))
                        .font(.callout)
                        .foregroundStyle((binding.note?.isEmpty ?? true) ? AnyShapeStyle(.hint) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused($noteButtonFocused)
                .accessibilityLabel("Note")
                .accessibilityInputLabels([Text("Note"), Text((binding.note?.isEmpty ?? true) ? String(localized: "Add a note") : ShippedText.t(binding.note ?? ""))])
                .accessibilityValue((binding.note?.isEmpty ?? true) ? String(localized: "empty") : ShippedText.t(binding.note ?? ""))
                .accessibilityHint("Edit the note for this binding")
            }
        }
        .padding(.leading, dragWidth + colGap)
        .padding(.top, 3)
    }

    // MARK: - Dropdown search

    /// The input type menu's choices, for its Search.
    private var inputTypeSearchChoices: [MenuSearchChoice] {
        let sections: [(LocalizedStringResource, [InputType])] = [
            ("Controller", [.button, .axis, .hat, .stickGesture]),
            ("Touchpad", [.touchpad, .touchpadRegion, .touchpadGesture]),
            ("This Mac", [.chassisTap]),
            ("Motion", [.motion]),
            ("Keyboard and mouse", [.extKey, .extMouse]),
            ("Screen", [.cursorRegion]),
            ("MIDI", [.midi]),
        ]
        return sections.flatMap { section, types in
            types.map { type in
                MenuSearchChoice(title: Self.inputTypeMenuName(type), path: String(localized: section)) { chooseInputType(type) }
            }
        }
    }

    /// The button menu's choices: this controller's extras, the standard
    /// names, then every index.
    private var buttonIndexSearchChoices: [MenuSearchChoice] {
        var out = extraButtons.map { extra in
            MenuSearchChoice(title: String(localized: "\(extra.label) (#\(extra.index))"),
                             path: String(localized: "This controller")) { binding.input.index = extra.index }
        }
        out += familyButtonLabels.map { entry in
            MenuSearchChoice(title: String(localized: "\(entry.label) (#\(entry.index))"),
                             path: String(localized: "Standard")) { binding.input.index = entry.index }
        }
        for group in 0..<4 {
            let path = MenuSearchChoice.path(String(localized: "All indices"),
                                             String(localized: "Buttons \(group * 32) to \(group * 32 + 31)"))
            out += ((group * 32)..<(group * 32 + 32)).map { i in
                MenuSearchChoice(title: String(localized: "Button \(i)"), path: path,
                                 keywords: buttonMenuLabel(for: i)) { binding.input.index = i }
            }
        }
        return out
    }

    private func axisChoiceTitle(_ i: Int) -> String {
        ButtonNames.axisName(i, family: presetButtonFamily).map { "\($0) (#\(i))" } ?? String(localized: "Axis #\(i)")
    }

    private func axisSearchChoices(_ pick: @escaping (Int) -> Void) -> [MenuSearchChoice] {
        (0..<16).map { i in MenuSearchChoice(title: axisChoiceTitle(i)) { pick(i) } }
    }

    private func chooseMotionChannel(_ channel: MotionChannel) {
        binding.input.motionChannel = channel
        // Measured from the grip is for tilt angles only.
        if ![.pitchAngle, .rollAngle, .yawAngle].contains(channel) { binding.fromNeutral = nil }
    }

    // MARK: - Index Picker (fixed width)

    @ViewBuilder
    private var indexPicker: some View {
        switch binding.input.type {
        case .stickGesture:
            stickGesturePicker
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
            SearchableMenu(choices: { buttonIndexSearchChoices }) {
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
                    ForEach(familyButtonLabels, id: \.index) { entry in
                        Button("\(entry.label) (#\(entry.index))") {
                            binding.input.index = entry.index
                        }
                    }
                }
                // Joysticks, flight sticks, and button boxes can report up
                // to 128 buttons; grouped by 32 so the menu stays short.
                Section("All indices") {
                    ForEach(0..<4, id: \.self) { group in
                        Menu("Buttons \(group * 32) to \(group * 32 + 31)") {
                            ForEach((group * 32)..<(group * 32 + 32), id: \.self) { i in
                                Button("Button \(i)") { binding.input.index = i }
                            }
                        }
                    }
                }
            } label: {
                menuLabel(buttonMenuLabel(for: binding.input.index))
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

        case .axis:
            // Named for the controller family (Left stick X, L2, Right
            // trackpad X on a Steam Controller), the number kept beside it.
            SearchableMenu(choices: { axisSearchChoices { setAxisIndex($0) } }) {
                ForEach(0..<16, id: \.self) { i in
                    Button(axisChoiceTitle(i)) {
                        setAxisIndex(i)
                    }
                }
            } label: {
                menuLabel(ButtonNames.axisName(binding.input.index, family: presetButtonFamily) ?? String(localized: "Axis #\(binding.input.index)"))
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

        case .hat:
            Picker("Hat", selection: $binding.input.index) {
                ForEach(0..<16, id: \.self) { i in
                    Text("Hat #\(i)").tag(i)
                }
            }
            .labelsHidden()
            .controlSize(.small)

        case .touchpad:
            if presetButtonFamily?.isSteam == true {
                // A Steam Controller pad reads one finger; the choice is
                // which pad.
                steamPadPicker
            } else {
                // Touchpad "index" represents the finger slot (0 or 1).
                Picker("Finger", selection: touchpadFingerBinding) {
                    Text("Finger 1").tag(0)
                    Text("Finger 2").tag(1)
                }
                .labelsHidden()
                .controlSize(.small)
            }

        case .motion:
            // Pick the motion channel. Menu items use the long
            // `menuDescription` ("Gyro Z (roll rate)") so users
            // recognize the axis, but the closed-button label shows
            // the short `displayName` ("Gyro Z") so it fits the
            // fixed-width index column without overlapping the next
            // column.
            SearchableMenu(choices: {
                MotionChannel.allCases.map { channel in
                    MenuSearchChoice(title: channel.menuDescription, keywords: channel.displayName) { chooseMotionChannel(channel) }
                } + MotionSetup.allCases.map { setup in
                    MenuSearchChoice(title: setup.title, path: String(localized: "Set Up Full Gyro")) {
                        MotionSetupAction.perform?(binding.id, setup)
                    }
                }
            }) {
                ForEach(MotionChannel.allCases) { channel in
                    Button(channel.menuDescription) { chooseMotionChannel(channel) }
                }
                Divider()
                motionSetupSection
            } label: {
                menuLabel((binding.input.motionChannel ?? .gyroY).displayName)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

        case .touchpadRegion:
            // Pick from defined regions by name; the zones are drawn in this
            // group's Zones section, a click away.
            Menu {
                let regions = TouchpadService.shared.allRegions()
                if regions.isEmpty {
                    Text("This preset has no touchpad regions yet")
                    Button("Draw touchpad regions\u{2026}") { showZones(.touchpad) }
                } else if regions.contains(where: { $0.surface == 1 }) || presetButtonFamily?.isSteam == true {
                    // A Steam Controller: each trackpad's own regions; the
                    // region picked says which pad the row reads.
                    Section(String(localized: "Right trackpad")) {
                        ForEach(regions.filter { $0.surface != 1 }) { region in
                            Button {
                                binding.input.touchpadRegionID = region.id
                                binding.input.touchpadSurface = nil
                            } label: { regionMenuLabel(region) }
                        }
                    }
                    Section(String(localized: "Left trackpad")) {
                        ForEach(regions.filter { $0.surface == 1 }) { region in
                            Button {
                                binding.input.touchpadRegionID = region.id
                                binding.input.touchpadSurface = 1
                            } label: { regionMenuLabel(region) }
                        }
                    }
                    Divider()
                    Button("Edit touchpad regions\u{2026}") { showZones(binding.input.touchpadSurface == 1 ? .leftTrackpad : .touchpad) }
                } else {
                    ForEach(regions) { region in
                        Button {
                            binding.input.touchpadRegionID = region.id
                        } label: {
                            regionMenuLabel(region)
                        }
                    }
                    Divider()
                    Button("Edit touchpad regions\u{2026}") { showZones(.touchpad) }
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
                    showZones(.screen)
                }
            } label: {
                regionMenuLabel(name: cursorRegionDisplayName,
                                colorIndex: cursorRegionColorIndex)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

        case .stickRegion:
            // A zone row's stick or trigger. Only the zone's own stick, or its own trigger: picking one
            // makes the row a direction row on it again.
            Menu {
                ForEach(zoneRowAxes, id: \.self) { i in
                    Button(axisChoiceTitle(i)) {
                        useWholeAxis(index: i)
                    }
                }
            } label: {
                menuLabel(zoneRowStickName)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

        case .extKey:
            // HID usage code. Most users won't remember a code by number, so
            // we surface a Scan affordance: if the user clicks "Scan" the next
            // physical key press on any detected keyboard becomes the binding.
            SearchableMenu(choices: {
                let common = String(localized: "Common keys")
                return commonHIDKeys.map { entry in
                    MenuSearchChoice(title: KeyCodeMap.name(for: entry.code), path: common,
                                     keywords: entry.label) { binding.input.index = entry.code }
                } + [MenuSearchChoice(title: String(localized: "Press any key on detected keyboard\u{2026}"),
                                      path: String(localized: "Scan")) { scanForExternalKey() }]
            }) {
                Section("Common keys") {
                    ForEach(commonHIDKeys, id: \.code) { entry in
                        Button("\(KeyCodeMap.name(for: entry.code)) (code \(entry.code))") {
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
                menuLabel(externalScanning ? String(localized: "Press a key\u{2026} \(externalScanLeft)")
                          : externalScanTimedOut ? String(localized: "Timed out")
                          : KeyCodeMap.name(for: binding.input.index))
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
                        // A move or scroll row reads one way, the "+" it
                        // shows; with none stored it fired both ways.
                        if kind != .button && kind != .doubleClick, binding.input.axisDirection == nil {
                            binding.input.axisDirection = .positive
                        }
                    }
                }
            } label: {
                menuLabel((binding.input.extMouseKind ?? .button).displayName)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

        case .touchpadGesture:
            // The gesture kind discriminator (two-finger tap, etc.). A
            // Steam Controller pad reads one finger, so it has no
            // two-finger tap, and the row also picks the pad.
            let steam = presetButtonFamily?.isSteam == true
            Menu {
                ForEach(TouchpadGestureKind.allCases.filter { !steam || $0 != .twoFingerTap }) { kind in
                    Button(kind.displayName) {
                        binding.input.touchpadGestureKind = kind
                    }
                }
                if steam {
                    Divider()
                    Button("Right trackpad") { binding.input.touchpadSurface = nil }
                    Button("Left trackpad") { binding.input.touchpadSurface = 1 }
                }
            } label: {
                menuLabel((steam ? (binding.input.touchpadSurface == 1 ? String(localized: "Left: ") : String(localized: "Right: ")) : "")
                          + (binding.input.touchpadGestureKind?.displayName ?? String(localized: "Two-finger tap")))
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

        case .midi:
            midiIndexPicker
        }
    }

    /// Which Steam Controller trackpad a touchpad row reads.
    private var steamPadPicker: some View {
        Picker("Pad", selection: SwiftUI.Binding(
            get: { binding.input.touchpadSurface ?? 0 },
            set: { new in
                binding.input.touchpadSurface = new == 1 ? 1 : nil
                binding.input.touchpadFinger = 0
                binding.input.index = 0
            })) {
            Text("Right pad").tag(0)
            Text("Left pad").tag(1)
        }
        .labelsHidden()
        .controlSize(.small)
        .accessibilityLabel("Trackpad")
    }

    /// The most-used HID Keyboard / Keypad usage codes for the dropdown, and
    /// the Globe key, tapped or held as fn.
    private var commonHIDKeys: [(label: String, code: Int)] {
        [
            ("A", 4), ("S", 22), ("D", 7), ("W", 26),
            ("Space", 44), ("Return", 40), ("Escape", 41), ("Tab", 43),
            ("Left", 80), ("Right", 79), ("Up", 82), ("Down", 81),
            ("Globe", KeyCodeMap.globeKeyCode), ("fn", KeyCodeMap.globeFnCode)
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
        case 0: return String(localized: "Left click")
        case 1: return String(localized: "Right click")
        case 2: return String(localized: "Middle click")
        default: return String(localized: "Button \(index &+ 1)")
        }
    }

    private func scanForExternalKey() {
        scanExternal(keyboard: true) { event in
            guard case .keyDown(let dev, let code) = event else { return nil }
            // With VoiceOver on, Control and Option are its own keys: the
            // next VoiceOver command bound Control or Option to the row.
            // Caps Lock too, which VoiceOver can use as its modifier.
            if NSWorkspace.shared.isVoiceOverEnabled, [57, 224, 226, 228, 230].contains(code) { return nil }
            // fn comes first on a Globe tap too, whose own key follows the
            // release: fn alone is taken only if that key does not come.
            if code == KeyCodeMap.globeFnCode {
                DispatchQueue.main.async {
                    let at = Date()
                    Self.pendingFnAt = at
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        guard Self.pendingFnAt == at, externalScanning else { return }
                        Self.pendingFnAt = nil
                        binding.input.index = code
                        binding.input.extDeviceID = dev
                        Self.announce(String(localized: "Set to \(HotKeySpec.spokenKey(KeyCodeMap.name(for: code)))"))
                        Self.cancelActiveScan()
                    }
                }
                return nil
            }
            DispatchQueue.main.async { Self.pendingFnAt = nil }
            return (code, dev)
        }
    }
    private static var pendingFnAt: Date?

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
        svc.retain("scan", mouse: mouse, keyboard: keyboard, movement: false)
        // Shown on the row's menu and spoken, since keys and clicks in this
        // window go to the scan until it ends.
        externalScanning = true
        externalScanTimedOut = false
        Self.activeScanEnded = { externalScanning = false }
        let scanSeconds = ScanTiming.macInputSeconds
        externalScanLeft = scanSeconds
        Self.activeScanTick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            externalScanLeft = max(0, externalScanLeft - 1)
        }
        let ends = String(localized: "Scan ends in \(scanSeconds) seconds.")
        Self.announce(keyboard ? String(localized: "Press the key to use. \(ends)") : String(localized: "Press the mouse button to use. \(ends)"))
        let captured: (Int) -> Void = { index in
            Self.announce(String(localized: "Set to \(keyboard ? HotKeySpec.spokenKey(KeyCodeMap.name(for: index)) : Self.mouseButtonName(index))"))
        }
        // A press already down when Scan was clicked must not count, so
        // events in the first instant are ignored.
        let armedAt = Date().addingTimeInterval(0.15)
        let cancellable = svc.events.sink { event in
            guard Date() >= armedAt, let (index, dev) = pick(event) else { return }
            DispatchQueue.main.async {
                binding.input.index = index
                binding.input.extDeviceID = dev
                captured(index)
                Self.cancelActiveScan()
            }
        }
        Self.activeScanCancellable = cancellable
        // While a key scan runs, keys typed in this window are taken here
        // and kept from the editor, so Escape, Return, Space and Tab bind
        // instead of closing the sheet or pressing a button. This also
        // hears keys without the Accessibility permission, which the
        // service's monitors need.
        if keyboard {
            Self.activeScanKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { ev in
                if ev.type == .keyDown, !ev.isARepeat, Date() >= armedAt {
                    let hid = ExternalInputDeviceService.inputCode(forVirtualKeyCode: Int(ev.keyCode))
                    let event = ExternalInputDeviceService.Event.keyDown(
                        deviceID: ExternalInputDeviceService.builtInKeyboardID, hidCode: hid)
                    if let (index, dev) = pick(event) {
                        binding.input.index = index
                        binding.input.extDeviceID = dev
                        captured(index)
                        DispatchQueue.main.async { Self.cancelActiveScan() }
                    }
                }
                return nil
            }
        }
        // The same for a mouse button scan: a click in this window is taken
        // here, not also sent to the button under the pointer.
        if mouse {
            let types: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown,
                                                .leftMouseUp, .rightMouseUp, .otherMouseUp]
            Self.activeScanMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: types) { ev in
                guard Date() >= armedAt else { return ev }
                if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(ev.type) {
                    let button = ev.type == .leftMouseDown ? 0 : (ev.type == .rightMouseDown ? 1 : ev.buttonNumber)
                    let event = ExternalInputDeviceService.Event.mouseButtonDown(
                        deviceID: ExternalInputDeviceService.builtInMouseID, button: button)
                    if let (index, dev) = pick(event) {
                        binding.input.index = index
                        binding.input.extDeviceID = dev
                        captured(index)
                        DispatchQueue.main.async { Self.cancelActiveScan() }
                    }
                }
                return nil
            }
        }
        // A hard deadline (5 seconds unless Settings changed it). Fires on
        // the main run loop so it always runs even if no events arrive.
        Self.activeScanTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(scanSeconds), repeats: false) { _ in
            Self.announce(String(localized: "Scan timed out. Nothing was set."))
            NSSound.beep()
            Self.cancelActiveScan()
            // Seen on the row for a few seconds, not only spoken.
            externalScanTimedOut = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { externalScanTimedOut = false }
        }
    }

    /// Single global slot for the active "scan for keyboard key" listener.
    /// Static so re-clicking Scan on a different row always cancels the
    /// previous subscription instead of stacking them.
    private static var activeScanCancellable: AnyCancellable?
    private static var activeScanTimer: Timer?
    private static var activeScanTick: Timer?
    private static var activeScanKeyMonitor: Any?
    private static var activeScanMouseMonitor: Any?
    /// Clears the scanning row's "Press a key" label when the scan ends.
    private static var activeScanEnded: (() -> Void)?

    private static func announce(_ text: String, priority: NSAccessibilityPriorityLevel = .high) {
        guard let window = NSApp?.keyWindow ?? NSApp?.mainWindow else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: priority.rawValue])
    }

    /// Cancel any in-flight external-input scan. Called from
    /// `.onDisappear` so a row that goes away mid-scan doesn't keep
    /// the static timer/subscription alive and fire its 5-second
    /// deadline writing into a now-dead `@Binding`.
    static func cancelActiveScan() {
        activeScanCancellable?.cancel()
        activeScanCancellable = nil
        activeScanTimer?.invalidate()
        activeScanTimer = nil
        activeScanTick?.invalidate()
        activeScanTick = nil
        if let monitor = activeScanKeyMonitor {
            NSEvent.removeMonitor(monitor)
            activeScanKeyMonitor = nil
        }
        if let monitor = activeScanMouseMonitor {
            NSEvent.removeMonitor(monitor)
            activeScanMouseMonitor = nil
        }
        ExternalInputDeviceService.shared.release("scan")
        let ended = activeScanEnded
        activeScanEnded = nil
        ended?()
    }

    private var touchpadRegionDisplayName: String {
        if let id = binding.input.touchpadRegionID,
           let r = TouchpadService.shared.region(with: id) {
            return r.shownName
        }
        return String(localized: "Pick region")
    }

    private var cursorRegionDisplayName: String {
        if let id = binding.input.cursorRegionID,
           let r = CursorRegionService.shared.region(with: id) {
            if let d = r.display { return String(localized: "\(r.shownName) on \(d.name)") }
            return r.shownName
        }
        return String(localized: "Pick a screen region")
    }

    /// Regions that apply to every display first, then one group per
    /// display, in the order the displays are attached.
    static func screenRegionSections(_ regions: [TouchpadRegion]) -> [(title: String, regions: [TouchpadRegion])] {
        var out: [(String, [TouchpadRegion])] = []
        let any = regions.filter { $0.display == nil }
        if !any.isEmpty { out.append((String(localized: "Every display"), any)) }
        var seen: [DisplayKey] = []
        for r in regions {
            guard let d = r.display, !seen.contains(d) else { continue }
            seen.append(d)
            let attached = CursorRegionService.shared.isDisplayAttached(d)
            out.append((attached ? d.name : String(localized: "\(d.name) (not connected)"), regions.filter { $0.display == d }))
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

    /// The type column's name: a stick zone or trigger band is shown as the
    /// Axis it belongs to.
    private var typeMenuTitle: String {
        binding.input.type == .stickRegion ? InputType.axis.displayName : binding.input.type.displayName
    }

    /// How this zone shares its stick with the stick's direction rows, said
    /// plainly with the rows it overlaps, and the switch to let both fire.
    @ViewBuilder
    private var zoneSharingOptions: some View {
        let shares = binding.zoneSharesStick != false
        let rows = zoneOverlap.map { "#\($0)" }.joined(separator: ", ")
        VStack(alignment: .leading, spacing: 6) {
            Text(isBandRow
                 ? (zoneOverlap.isEmpty
                    ? String(localized: "No other row on this control reaches into this band.")
                    : zoneOverlap.count == 1
                    ? (shares
                       ? String(localized: "This band overlaps row \(rows). While the control is inside it, this row and that row both fire.")
                       : String(localized: "This band overlaps row \(rows). While the control is inside it, only this row fires; that row waits until the control leaves the band."))
                    : shares
                    ? String(localized: "This band overlaps rows \(rows). While the control is inside it, this row and those rows all fire.")
                    : String(localized: "This band overlaps rows \(rows). While the control is inside it, only this row fires; those rows wait until the control leaves the band."))
                 : zoneOverlap.isEmpty
                 ? String(localized: "No direction row on this stick reaches into this region.")
                 : zoneOverlap.count == 1
                 ? (shares
                    ? String(localized: "This region overlaps row \(rows). While the stick is inside it, this row and that row both fire.")
                    : String(localized: "This region overlaps row \(rows). While the stick is inside it, only this row fires; that row waits until the stick leaves the region."))
                 : shares
                 ? String(localized: "This region overlaps rows \(rows). While the stick is inside it, this row and those rows all fire.")
                 : String(localized: "This region overlaps rows \(rows). While the stick is inside it, only this row fires; those rows wait until the stick leaves the region."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !zoneZoneOverlap.isEmpty {
                let zoneRows = zoneZoneOverlap.map { "#\($0)" }.joined(separator: ", ")
                Text(zoneZoneOverlap.count == 1
                     ? String(localized: "It also overlaps the region of row \(zoneRows). Where the two meet, both rows fire.")
                     : String(localized: "It also overlaps the regions of rows \(zoneRows). Where they meet, each of those rows fires too."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let shareExplanation = isBandRow
                ? String(localized: "Off: inside the band only this row fires, the way a chord takes over its button's plain row. On: the band and the other rows both fire.")
                : String(localized: "Off: inside the region only this row fires, the way a chord takes over its button's plain row. On: the region and the direction rows both fire.")
            Toggle(isOn: SwiftUI.Binding(
                get: { binding.zoneSharesStick != false },
                set: { binding.zoneSharesStick = $0 ? nil : false })) {
                Text(isBandRow
                     ? String(localized: "Let the control's other rows fire in this band too")
                     : String(localized: "Let the stick's direction rows fire in this region too"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .help(shareExplanation)
            .accessibilityInputLabels([Text("Let rows fire"), Text("Share")])
            .accessibilityHint(shareExplanation)
        }
    }

    /// The zones a row on this axis can use instead of a direction: the
    /// plane zones of the stick the axis belongs to, and the axis's own
    /// bands, with the way to draw more.
    @ViewBuilder
    private func zoneChoices(forAxis axis: Int) -> some View {
        let svc = StickRegionService.shared
        let stick: Int? = (0...1).contains(axis) ? 0 : ((2...3).contains(axis) ? 1 : nil)
        let plane = stick.map { svc.regions(forStick: $0) } ?? []
        let bandKey = StickRegionService.bandKeyBase + axis
        let bands = svc.regions(forStick: bandKey)
        if !plane.isEmpty, let stick {
            Section(stick == 1 ? String(localized: "Right stick regions") : String(localized: "Left stick regions")) {
                ForEach(plane) { region in
                    Button { chooseZone(key: stick, region.id) } label: { regionMenuLabel(region) }
                }
            }
        }
        if !bands.isEmpty {
            Section(String(localized: "\(StickRegionService.axisDisplayName(axis)) regions")) {
                ForEach(bands) { region in
                    Button { chooseZone(key: bandKey, region.id) } label: { regionMenuLabel(region) }
                }
            }
        }
        Button(plane.isEmpty && bands.isEmpty
               ? String(localized: "Draw a region on this stick or trigger\u{2026}")
               : String(localized: "Edit regions\u{2026}")) {
            showZones(ZonePart(regionKey: zonesSheetKey))
        }
    }

    /// The zones sheet's tab for an axis: its stick, or its own bands.
    private func zonesKey(forAxis axis: Int) -> Int {
        if (0...1).contains(axis) { return 0 }
        if (2...3).contains(axis) { return 1 }
        return StickRegionService.bandKeyBase + axis
    }

    /// The axis a zone row stands for, for its zone menu: the axis it came
    /// from, or the stick's X axis, or the band's own axis.
    /// The key the zones sheet opens on: a zone row's own zone key, else
    /// the key of the row's axis.
    private var zonesSheetKey: Int {
        binding.input.type == .stickRegion ? binding.input.index : zonesKey(forAxis: binding.input.index)
    }

    private var zoneRowAxis: Int {
        let key = binding.input.index
        if StickRegionService.isBandKey(key) { return key - StickRegionService.bandKeyBase }
        return axisBeforeZone?.index ?? (key == 1 ? 2 : 0)
    }

    /// The axes a zone row can go back to: its stick's X and Y, or the
    /// band's own axis.
    private var zoneRowAxes: [Int] {
        let key = binding.input.index
        if StickRegionService.isBandKey(key) { return [key - StickRegionService.bandKeyBase] }
        return key == 1 ? [2, 3] : [0, 1]
    }

    private var zoneRowStickName: String {
        let key = binding.input.index
        if StickRegionService.isBandKey(key) {
            return StickRegionService.axisDisplayName(key - StickRegionService.bandKeyBase)
        }
        return key == 1 ? String(localized: "Right stick") : String(localized: "Left stick")
    }

    /// The zone's own name, for the direction column.
    private var stickRegionShortName: String {
        if let id = binding.input.stickRegionID, let lookup = StickRegionService.shared.region(with: id) {
            return lookup.region.shownName
        }
        return String(localized: "Pick a region")
    }

    /// The row fires while its stick or trigger is inside the zone.
    private func chooseZone(key: Int, _ id: UUID) {
        if binding.input.type == .axis {
            axisBeforeZone = (binding.input.index, binding.input.axisDirection, binding.invertAxis)
            // Invert would turn the zone half a turn round.
            binding.invertAxis = nil
        }
        binding.input.type = .stickRegion
        // A zone picked here takes over its stick; Options can let it share.
        binding.zoneSharesStick = false
        binding.input.index = key
        binding.input.stickRegionID = id
        binding.input.axisDirection = nil
    }

    /// Back from a zone to the whole axis it was on: a stick's X axis, or
    /// the band's own axis.
    private func useWholeAxis(index: Int? = nil, direction: AxisDirection? = nil) {
        let axis = index ?? zoneRowAxis
        let before = axisBeforeZone
        binding.input.type = .axis
        binding.input.stickRegionID = nil
        binding.input.index = axis
        binding.input.axisDirection = direction ?? (before?.index == axis ? before?.direction : nil) ?? .positive
        if before?.index == axis { binding.invertAxis = before?.invert }
        axisBeforeZone = nil
    }

    private var stickRegionColorIndex: Int? {
        guard let id = binding.input.stickRegionID,
              let found = StickRegionService.shared.region(with: id) else { return nil }
        return found.region.colorIndex
    }

    /// Canonical labels for the standard 22 MFi button slots. Surfaced
    /// in the button index picker so users see "A / Cross (#0)" instead
    /// of just "Button 0". Indices 16-21 cover DualSense Edge paddles
    /// and Function buttons. The four face buttons follow the Face button
    /// letters setting (B / Cross on the bottom for Nintendo-lettered pads).
    static var standardButtonLabels: [(index: Int, label: String)] { standardButtonLabels(for: nil) }

    /// The same, named for a controller family when one is known (the
    /// preset's, or the connected controller's): L1 on a PlayStation pad,
    /// ZL on a Switch pad, Quick Access on a 2026 Steam Controller. With
    /// none, both common names, the face buttons per Settings.
    static func standardButtonLabels(for family: FaceLetters?,
                                     model: ButtonNames.ModelNames = .none) -> [(index: Int, label: String)] {
        ButtonNames.labels(for: family, model: model)
    }

    /// The Standard list for this row's slot: its family, its model's own
    /// names, the Face button names setting.
    private var familyButtonLabels: [(index: Int, label: String)] {
        // A pad read from its descriptor alone has no A or Cross: its
        // buttons are named as Scan and the Automatic rows name them.
        if let names = deviceButtonNames { return names.enumerated().map { (index: $0.offset, label: $0.element) } }
        return Self.standardButtonLabels(for: presetButtonFamily, model: buttonModelNames)
    }

    /// Closed-menu label. Prefers the connected controller's named
    /// extra (e.g. "Left Paddle") for the active index, falls back to
    /// a canonical standard label, otherwise the bare "Button N".
    private func buttonMenuLabel(for index: Int) -> String {
        if let extra = extraButtons.first(where: { $0.index == index }) {
            return extra.label
        }
        if let std = familyButtonLabels.first(where: { $0.index == index }) {
            return std.label
        }
        return String(localized: "Button \(index)")
    }

    /// "Single tap" / "Double tap" / "Triple tap" for the index column.
    /// Said wherever a Tap the Mac row or the feature is shown.
    static var tapTheMacDisclaimer: String {
        String(localized: "Works only on some MacBooks: tested on M4 MacBooks; it did not work on an M1 Pro in our testing.")
    }

    private var chassisTapLabel: String {
        TapCalibrationView.gestureName(max(1, min(5, binding.input.index)))
    }

    private var stickRegionDisplayName: String {
        if let id = binding.input.stickRegionID,
           let lookup = StickRegionService.shared.region(with: id) {
            let stick = StickRegionService.isBandKey(lookup.stickIndex)
                ? StickRegionService.axisDisplayName(lookup.stickIndex - StickRegionService.bandKeyBase)
                : (lookup.stickIndex == 1 ? String(localized: "Right") : String(localized: "Left"))
            return "\(stick): \(lookup.region.shownName)"
        }
        return String(localized: "Pick stick region")
    }

    /// MIDI: the first column picks the message family and its number
    /// (note or CC). Pitch bend and aftertouch are per-channel, so they
    /// have no number and the menu collapses to just the family.
    @ViewBuilder
    private var midiIndexPicker: some View {
        SearchableMenu(choices: {
            let message = String(localized: "Message")
            var out = MIDIInputKind.allCases.map { kind in
                MenuSearchChoice(title: kind.displayName, path: message) { chooseMIDIKind(kind) }
            }
            let kind = binding.input.midiKind ?? .note
            out += Self.midiNumberChoices(for: kind).map { pair in
                MenuSearchChoice(title: pair.1, path: kind.displayName) { binding.input.index = pair.0 }
            }
            return out
        }) {
            Section("Message") {
                ForEach(MIDIInputKind.allCases) { kind in
                    Button(kind.displayName) { chooseMIDIKind(kind) }
                }
            }
            let kind = binding.input.midiKind ?? .note
            if kind.usesNumber {
                Section(kind == .note ? String(localized: "Note") : (kind == .cc ? String(localized: "Controller") : (kind == .transport ? String(localized: "Transport") : String(localized: "Program")))) {
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

    private func chooseMIDIKind(_ kind: MIDIInputKind) {
        binding.input.midiKind = kind
        // Reset the number to something sensible for the
        // new family so the row never shows "CC 60".
        if kind == .note { binding.input.index = 60 }
        else if kind == .cc { binding.input.index = 1 }
        else if kind == .transport { binding.input.index = 0xFA; binding.input.midiChannel = nil }
        else { binding.input.index = 0 }
        // Pressure only rises; a "-" row sent its outputs
        // nothing but 0.
        if kind == .aftertouch { binding.input.axisDirection = .positive }
    }

    private var midiIndexLabel: String {
        let kind = binding.input.midiKind ?? .note
        switch kind {
        case .note:          return MIDIService.noteName(binding.input.index)
        case .cc:            return String(localized: "CC \(binding.input.index)")
        case .programChange: return String(localized: "Prog \(binding.input.index)")
        case .pitchBend:     return String(localized: "Pitch Bend")
        case .aftertouch:    return String(localized: "Aftertouch")
        case .transport:     return MIDIInputKind.transportName(binding.input.index)
        }
    }

    /// Menu choices per message family. Notes span a usable keyboard
    /// range; CC lists the controllers people actually bind.
    private static func midiNumberChoices(for kind: MIDIInputKind) -> [(Int, String)] {
        switch kind {
        case .note:
            return (36...84).map { ($0, MIDIService.noteName($0)) }
        case .cc:
            var out = MIDIService.commonCCs.map { ($0.number, String(localized: "CC \($0.number): \($0.name)")) }
            let common = Set(MIDIService.commonCCs.map(\.number))
            out += (0...127).filter { !common.contains($0) }.map { ($0, String(localized: "CC \($0)")) }
            return out
        case .programChange:
            return (0...127).map { ($0, String(localized: "Program \($0)")) }
        case .transport:
            return [0xFA, 0xFB, 0xFC].map { ($0, MIDIInputKind.transportName($0)) }
        case .pitchBend, .aftertouch:
            return []
        }
    }

    /// Menu titles for the MIDI device list. Two identical keyboards
    /// share a name, so repeats get a number ("Launchkey 2") to tell
    /// them apart.
    static func midiDeviceTitles(_ devices: [MIDIInputService.Device]) -> [(device: MIDIInputService.Device, title: String)] {
        var totals: [String: Int] = [:]
        for d in devices { totals[d.name, default: 0] += 1 }
        var seen: [String: Int] = [:]
        return devices.map { d in
            guard (totals[d.name] ?? 0) > 1 else { return (d, d.name) }
            seen[d.name, default: 0] += 1
            return (d, "\(d.name) \(seen[d.name] ?? 1)")
        }
    }

    /// MIDI: the second column picks the channel (or Any).
    @ViewBuilder
    private var midiChannelPicker: some View {
        SearchableMenu(choices: { midiChannelSearchChoices }) {
            // Device section first: this is where users look to confirm
            // their MIDI keyboard was detected at all.
            Section("Device") {
                Button("Any device") { binding.input.midiDeviceID = nil }
                let devices = MIDIInputService.shared.connectedDevices()
                if devices.isEmpty {
                    Text("No MIDI devices detected")
                } else {
                    ForEach(Self.midiDeviceTitles(devices), id: \.device.id) { entry in
                        Button(entry.title) { binding.input.midiDeviceID = entry.device.id }
                    }
                }
            }
            // Transport messages have no channel, so only the device applies.
            if (binding.input.midiKind ?? .note) != .transport {
                Button("Any channel") { binding.input.midiChannel = nil }
                Section("Channel") {
                    ForEach(1...16, id: \.self) { ch in
                        Button("Channel \(ch)") { binding.input.midiChannel = ch }
                    }
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
            if (binding.input.midiKind ?? .note).isContinuous, binding.input.midiKind != .aftertouch {
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

    /// The channel menu's choices, for its Search.
    private var midiChannelSearchChoices: [MenuSearchChoice] {
        let kind = binding.input.midiKind ?? .note
        let deviceMenu = String(localized: "Device")
        var out = [MenuSearchChoice(title: String(localized: "Any device"), path: deviceMenu) { binding.input.midiDeviceID = nil }]
        out += Self.midiDeviceTitles(MIDIInputService.shared.connectedDevices()).map { entry in
            MenuSearchChoice(title: entry.title, path: deviceMenu) { binding.input.midiDeviceID = entry.device.id }
        }
        if kind != .transport {
            out.append(MenuSearchChoice(title: String(localized: "Any channel")) { binding.input.midiChannel = nil })
            out += (1...16).map { ch in
                MenuSearchChoice(title: String(localized: "Channel \(ch)"), path: String(localized: "Channel")) { binding.input.midiChannel = ch }
            }
        }
        if kind == .cc {
            out += MIDICCMode.allCases.map { mode in
                MenuSearchChoice(title: mode.displayName, path: String(localized: "Knob mode")) {
                    binding.input.midiCCMode = (mode == .threshold) ? nil : mode
                }
            }
            if binding.input.midiCCMode == .relative {
                let step = String(localized: "Turn step")
                out += [
                    MenuSearchChoice(title: String(localized: "Fine (2 units per nudge)"), path: step) { binding.input.midiTurnStep = 2 },
                    MenuSearchChoice(title: String(localized: "Normal (4 units per nudge)"), path: step) { binding.input.midiTurnStep = nil },
                    MenuSearchChoice(title: String(localized: "Coarse (8 units per nudge)"), path: step) { binding.input.midiTurnStep = 8 },
                    MenuSearchChoice(title: String(localized: "Chunky (16 units per nudge)"), path: step) { binding.input.midiTurnStep = 16 },
                ]
            }
        }
        if kind.isContinuous, binding.input.midiKind != .aftertouch {
            out += AxisDirection.allCases.map { dir in
                MenuSearchChoice(title: dir.displayName, path: String(localized: "Direction")) { binding.input.axisDirection = dir }
            }
        }
        return out
    }

    /// Channel-column label: channel (or Any), prefixed with the knob
    /// mode badge when a CC binding uses a non-default mode, so a Dial
    /// or Turn binding is recognizable without opening the menu.
    private var midiChannelLabel: String {
        if (binding.input.midiKind ?? .note) == .transport {
            guard let id = binding.input.midiDeviceID else { return String(localized: "Any device") }
            return MIDIInputService.shared.connectedDevices().first { $0.id == id }?.name ?? String(localized: "Missing device")
        }
        var ch = binding.input.midiChannel.map { String(localized: "Ch \($0)") } ?? String(localized: "Any ch")
        // A row pinned to one device says which, or that it is missing,
        // since it fires for nothing else.
        if let id = binding.input.midiDeviceID {
            let device = MIDIInputService.shared.connectedDevices().first { $0.id == id }
            ch = "\(device?.name ?? String(localized: "Missing device")), \(ch)"
        }
        // A knob or bend row's direction, so a "+" and a "-" row on the
        // same control do not look the same.
        let kind = binding.input.midiKind ?? .note
        if kind.isContinuous, kind != .aftertouch, let dir = binding.input.axisDirection {
            ch += " \(dir.displayName)"
        }
        if kind == .cc, let badge = binding.input.midiCCMode?.badge {
            return "\(badge), \(ch)"
        }
        return ch
    }

    // MARK: - Index / Direction Accessibility

    /// Spoken role name for the index picker, matching whatever the closed
    /// menu is actually choosing for the current input type. VoiceOver reads
    /// this before the value so the control never announces a bare number.
    private var indexPickerAccessibilityLabel: String {
        switch binding.input.type {
        case .button: return String(localized: "Button")
        case .axis: return String(localized: "Axis")
        case .hat: return String(localized: "Hat")
        case .touchpad: return String(localized: "Finger")
        case .motion: return String(localized: "Motion channel")
        case .touchpadRegion: return String(localized: "Touchpad region")
        case .cursorRegion: return String(localized: "Screen region")
        case .stickRegion: return String(localized: "Stick or axis")
        case .stickGesture: return String(localized: "Flicks")
        case .extKey: return String(localized: "Key")
        case .extMouse: return String(localized: "Mouse input")
        case .touchpadGesture: return String(localized: "Gesture")
        case .chassisTap: return String(localized: "Tap count")
        case .midi: return String(localized: "MIDI message")
        }
    }

    /// Current selection spoken as the index picker's value. Mirrors the
    /// closed-menu label text for each input type.
    private var indexPickerAccessibilityValue: String {
        switch binding.input.type {
        case .button:
            return buttonMenuLabel(for: binding.input.index)
        case .axis:
            // As the closed menu reads: the family's name for the axis.
            return ButtonNames.axisName(binding.input.index, family: presetButtonFamily)
                ?? String(localized: "Axis \(binding.input.index)")
        case .hat:
            return String(localized: "Hat \(binding.input.index)")
        case .touchpad:
            // A Steam row names its pad, as the picker on screen does.
            if presetButtonFamily?.isSteam == true { return binding.input.touchpadSurface == 1 ? String(localized: "Left pad") : String(localized: "Right pad") }
            return (binding.input.touchpadFinger ?? binding.input.index) == 1 ? String(localized: "Finger 2") : String(localized: "Finger 1")
        case .motion:
            return (binding.input.motionChannel ?? .gyroY).displayName
        case .touchpadRegion:
            return touchpadRegionDisplayName
        case .cursorRegion:
            return cursorRegionDisplayName
        case .chassisTap:
            return chassisTapLabel
        case .stickRegion:
            return zoneRowStickName
        case .stickGesture:
            return binding.input.displayName
        case .midi:
            return binding.input.displayName
        case .extKey:
            return HotKeySpec.spokenKey(KeyCodeMap.name(for: binding.input.index))
        case .extMouse:
            return (binding.input.extMouseKind ?? .button).displayName
        case .touchpadGesture:
            let kind = binding.input.touchpadGestureKind?.displayName ?? String(localized: "Two-finger tap")
            if presetButtonFamily?.isSteam == true {
                return (binding.input.touchpadSurface == 1 ? String(localized: "Left trackpad, ") : String(localized: "Right trackpad, ")) + kind
            }
            return kind
        }
    }

    /// Spoken role name for the direction column. Some input types host a
    /// device picker or a compound axis picker here instead of a plain
    /// direction, so the label follows what the column actually controls.
    private var directionPickerAccessibilityLabel: String {
        switch binding.input.type {
        case .extKey:
            return String(localized: "Keyboard device")
        case .extMouse:
            switch binding.input.extMouseKind ?? .button {
            case .button, .doubleClick: return String(localized: "Mouse button")
            case .moveX, .moveY, .scrollX, .scrollY: return String(localized: "Direction")
            case .pressure, .deepPress, .scrollGesture: return String(localized: "Mouse input")
            case .penTiltX, .penTiltY: return String(localized: "Direction")
            case .penButton: return String(localized: "Pen button")
            case .penPressure, .penEraser, .penInRange: return String(localized: "Pen input")
            }
        case .touchpad:
            return String(localized: "Axis and direction")
        case .stickRegion:
            return String(localized: "Region")
        default:
            return String(localized: "Direction")
        }
    }

    /// Current selection spoken as the direction column's value, matching the
    /// closed-menu label for the active input type.
    private var directionPickerAccessibilityValue: String {
        switch binding.input.type {
        case .stickRegion:
            return stickRegionShortName
        case .button, .touchpadRegion, .cursorRegion, .stickGesture, .touchpadGesture, .chassisTap:
            return String(localized: "Not applicable")
        case .midi:
            return binding.input.midiChannel.map { String(localized: "Channel \($0)") } ?? String(localized: "Any channel")
        case .axis, .motion:
            return axisDirectionBinding.wrappedValue.spokenName
        case .hat:
            return hatDirectionBinding.wrappedValue.displayName
        case .touchpad:
            let axisLabel = (binding.input.touchpadAxis ?? .x).rawValue.uppercased()
            let dirLabel = (binding.input.axisDirection ?? .positive).spokenName
            return "\(axisLabel) \(dirLabel)"
        case .extKey:
            return externalDeviceLabel(kind: .keyboard)
        case .extMouse:
            switch binding.input.extMouseKind ?? .button {
            case .button, .doubleClick: return Self.mouseButtonName(binding.input.index)
            case .moveX, .moveY, .scrollX, .scrollY:
                return (binding.input.axisDirection ?? .positive).spokenName
            case .pressure, .deepPress: return String(localized: "Built-in trackpad")
            case .scrollGesture: return String(localized: "Trackpad or Magic Mouse")
            case .penTiltX, .penTiltY: return (binding.input.axisDirection ?? .positive).spokenName
            case .penButton: return String(localized: "Pen button \(binding.input.index + 1)")
            case .penPressure, .penEraser, .penInRange: return String(localized: "Pen tablet")
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
            // How the stick fires this row: one direction, or a zone drawn on
            // it. Both are here, side by side, so they read as the two ways
            // to use a stick. Lazy Menu for the same scroll-perf reason as
            // the type menus: NSPopUpButtons pre-build on row creation.
            Menu {
                Section("Direction") {
                    ForEach(AxisDirection.allCases) { dir in
                        Button(dir.displayName) { axisDirectionBinding.wrappedValue = dir }
                    }
                }
                zoneChoices(forAxis: binding.input.index)
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

        case .stickGesture:
            // The stick is picked in the flicks menu.
            Color.clear

        case .stickRegion:
            // A region row: said as a region ("Region: Up"), so it never
            // reads as the plain direction of the same name, with the
            // region's color beside it, which opens it in the Regions editor.
            HStack(spacing: 4) {
                if let colorIndex = stickRegionColorIndex {
                    Button {
                        showZones(ZonePart(regionKey: binding.input.index))
                    } label: {
                        regionSwatch(colorIndex)
                            .padding(3)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show this region in the Regions editor")
                    .accessibilityLabel("Show region \(stickRegionShortName)")
                    .accessibilityInputLabels([Text("Show region"), Text("Show region \(stickRegionShortName)")])
                }
                Menu {
                    Section("Direction") {
                        ForEach(AxisDirection.allCases) { dir in
                            Button(dir.displayName) { useWholeAxis(direction: dir) }
                        }
                    }
                    zoneChoices(forAxis: zoneRowAxis)
                } label: {
                    menuLabel(binding.input.stickRegionID == nil ? stickRegionShortName
                              : String(localized: "Region: \(stickRegionShortName)"))
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .accessibilityLabel(directionPickerAccessibilityLabel)
                .accessibilityValue(directionPickerAccessibilityValue)
                .accessibilityInputLabels([Text(directionPickerAccessibilityValue), Text(directionPickerAccessibilityLabel)])
            }
            // Two controls: the column's name goes on the menu, and the
            // jump button keeps its own.
            .accessibilityElement(children: .contain)

        case .motion:
            // Motion inputs read like axes: pick + or - polarity.
            Picker("Motion direction", selection: axisDirectionBinding) {
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
                SearchableMenu(choices: {
                    (0..<32).map { btn in
                        MenuSearchChoice(title: Self.mouseButtonName(btn),
                                         path: btn < 8 ? "" : String(localized: "More buttons")) { binding.input.index = btn }
                    } + [MenuSearchChoice(title: String(localized: "Scan: press a mouse button\u{2026}")) { scanForExternalMouseButton() }]
                }) {
                    ForEach(0..<8, id: \.self) { btn in
                        Button(Self.mouseButtonName(btn)) { binding.input.index = btn }
                    }
                    // Gaming mice with many side keys report buttons past
                    // 8; macOS numbers them up to 32.
                    Menu("More buttons") {
                        ForEach(8..<32, id: \.self) { btn in
                            Button(Self.mouseButtonName(btn)) { binding.input.index = btn }
                        }
                    }
                    Divider()
                    Button("Scan: press a mouse button…") { scanForExternalMouseButton() }
                    Divider()
                    Section("Device") { externalDeviceMenuItems(kind: .mouse) }
                } label: {
                    menuLabel(externalScanning ? String(localized: "Press a button\u{2026} \(externalScanLeft)")
                              : externalScanTimedOut ? String(localized: "Timed out")
                              : Self.mouseButtonName(binding.input.index))
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
                    .foregroundStyle(.hint)
                    .fixedSize()
            case .scrollGesture:
                Text("Trackpad or Magic Mouse")
                    .font(.callout)
                    .foregroundStyle(.hint)
                    .fixedSize()
            case .penTiltX, .penTiltY:
                Menu {
                    Button("+") { binding.input.axisDirection = .positive }
                    Button("\u{2212}") { binding.input.axisDirection = .negative }
                } label: {
                    menuLabel((binding.input.axisDirection ?? .positive).displayName)
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .fixedSize()
            case .penButton:
                Menu {
                    ForEach(0..<8, id: \.self) { btn in
                        Button(String(localized: "Pen button \(btn + 1)")) { binding.input.index = btn }
                    }
                } label: {
                    menuLabel(String(localized: "Pen button \(binding.input.index + 1)"))
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .fixedSize()
            case .penPressure, .penEraser, .penInRange:
                Text("Pen tablet")
                    .font(.callout)
                    .foregroundStyle(.hint)
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
        return kind.anyDevice
    }

    @ViewBuilder
    private func externalDeviceMenuItems(kind: ExternalInputDeviceService.Kind) -> some View {
        Button(kind.anyDevice) {
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

    private func appActionKindBinding(at index: Int, in list: OutputList = .main) -> SwiftUI.Binding<AppActionKind> {
        SwiftUI.Binding(
            get: { output(at: index, in: list)?.appActionKind ?? .togglePauseOutputs },
            set: { kind in updateOutput(index, in: list) { $0.appActionKind = kind } }
        )
    }

    private func targetPresetBinding(at index: Int, in list: OutputList = .main) -> SwiftUI.Binding<UUID?> {
        SwiftUI.Binding(
            get: { output(at: index, in: list)?.targetPresetID },
            set: { id in updateOutput(index, in: list) { $0.targetPresetID = id } }
        )
    }

    private func outputTextBinding(at index: Int, in list: OutputList = .main) -> SwiftUI.Binding<String> {
        SwiftUI.Binding(
            get: { output(at: index, in: list)?.text ?? "" },
            set: { text in updateOutput(index, in: list) { $0.text = text.isEmpty ? nil : text } }
        )
    }

    /// The controls for one output's value, in any of the row's output
    /// lists: the main action, or the hold or double-tap action.
    @ViewBuilder
    private func outputValueControls(at index: Int, in list: OutputList = .main) -> some View {
        // During an animated removal SwiftUI briefly retains the outgoing row
        // with its now-stale index; guard so the output lookups and the
        // per-control get closures never trap on an out-of-range index.
        if let current = output(at: index, in: list) {
            outputValueControlsBody(at: index, current: current, in: list)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func outputValueControlsBody(at index: Int, current: OutputAction, in list: OutputList) -> some View {
        switch current.type {
        case .key:
            // Command or Control among the other outputs: this key, once
            // picked, is sent as a shortcut by its character.
            KeyCodePicker(selectedCode: keyCodeBinding(at: index, in: list),
                          inShortcut: OutputAction.isShortcut(outputs(in: list).enumerated()
                              .filter { $0.offset != index }.map(\.element)))
                .accessibilityLabel("Key")

        case .absoluteVolume:
            // No parameters: the fader simply follows the input's
            // position. Explain the pairing so it isn't a mystery row.
            Text("Volume follows this control's position, 0 to 100%")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize()

        case .systemAction:
            systemActionControls(at: index, in: list)

        case .lightBar:
            lightBarControls(at: index, current: current, in: list)

        case .controllerProfile:
            Picker("Profile action", selection: SwiftUI.Binding(
                get: { current.resolvedProfileAction },
                set: { action in updateOutput(index, in: list) { $0.profileAction = action } })) {
                ForEach(ControllerProfileAction.allCases) { action in
                    Text(action.menuName).tag(action)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 120 * max(1, textScale))
            .hoverHelp("Switches the profile a PlayStation Access controller has active, as its Profile button does. Over USB-C; over Bluetooth the controller takes only its own button.")

        case .typeText:
            TextField("Text to type", text: outputTextBinding(at: index, in: list))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(minWidth: 140)
                .hoverHelp("Typed exactly as written when the input is pressed. Capitals, symbols, and any language work.")

        case .appAction:
            HStack(spacing: 6) {
                Picker("", selection: appActionKindBinding(at: index, in: list)) {
                    ForEach(appActionKinds(for: list)) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 160 * max(1, textScale))
                .accessibilityLabel("App action")
                if current.appActionKind == .activatePreset {
                    Picker("", selection: targetPresetBinding(at: index, in: list)) {
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
            SearchableMenu(choices: {
                (0..<32).map { i in
                    MenuSearchChoice(title: mouseButtonName(i)) { updateOutput(index, in: list) { $0.mouseButtonIndex = i } }
                }
            }) {
                ForEach(0..<32, id: \.self) { i in
                    Button(mouseButtonName(i)) {
                        updateOutput(index, in: list) { $0.mouseButtonIndex = i }
                    }
                }
            } label: {
                menuLabel(mouseButtonName(current.mouseButtonIndex ?? 0))
            }
            .menuStyle(.borderlessButton)
            .frame(minWidth: 120)
            .controlSize(.small)
            clickPointControls(at: index, in: list)

        case .mouseMotion, .mouseWheel:
            // Compact horizontal: direction, then slider, then numeric
            // readout. The "Speed" word was previously here as a label but
            // it pushed the row over the editor's minWidth on smaller
            // windows and clipped neighboring columns; the icon-style
            // gauge symbol now hints at what the slider controls without
            // adding meaningful width.
            HStack(spacing: 6) {
                Picker("Pointer direction", selection: mouseAxisDirBinding(at: index, in: list)) {
                    Text("Up").tag("1 -")
                    Text("Right").tag("0 +")
                    Text("Down").tag("1 +")
                    Text("Left").tag("0 -")
                }
                .labelsHidden()
                // Sized to its longest direction: "Nach oben" and "Nach
                // unten" must not both cut to "Nach…".
                .fixedSize()
                .controlSize(.small)

                Image(systemName: "speedometer")
                    .font(.callout)
                    .foregroundStyle(.hint)
                    .accessibilityHidden(true)
                    .fixedSize()
                    .hoverHelp("Output speed")

                ThrottledSlider("Output speed",
                    value: speedBinding(at: index, in: list),
                    in: 1...50,
                    step: 1,
                    onLiveChange: { liveSpeed[liveSpeedKey(index, list)] = $0 }
                )
                    .frame(minWidth: 60, idealWidth: 90)
                    .accessibilityValue(String(localized: "Speed \(Int(speedBinding(at: index, in: list).wrappedValue))"))

                TextField("Speed", value: liveSpeedBinding(at: index, in: list), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56 * max(1, textScale))
                    .controlSize(.small)
                    .multilineTextAlignment(.center)
            }

        case .mouseWheelStep:
            Picker("Pointer direction", selection: mouseAxisDirBinding(at: index, in: list)) {
                Text("Up").tag("1 -")
                Text("Right").tag("0 +")
                Text("Down").tag("1 +")
                Text("Left").tag("0 -")
            }
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)

        case .midiNote:
            HStack(spacing: 6) {
                fieldLabel("Note")
                // Lazy Menu so the 128 note options only build when opened.
                SearchableMenu(choices: {
                    MIDIService.notePickerLabels.map { entry in
                        MenuSearchChoice(title: entry.label) { updateOutput(index, in: list) { $0.midiNote = entry.number } }
                    }
                }) {
                    ForEach(MIDIService.notePickerLabels, id: \.number) { entry in
                        Button(entry.label) {
                            updateOutput(index, in: list) { $0.midiNote = entry.number }
                        }
                    }
                } label: {
                    let note = current.midiNote ?? 60
                    menuLabel("\(MIDIService.noteName(note)) (\(note))")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 100 * max(1, textScale))
                .controlSize(.small)

                fieldLabel("Vel")
                TextField("Velocity", value: midiVelocityBinding(at: index, in: list), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 44 * max(1, textScale))
                    .controlSize(.small)
                    .multilineTextAlignment(.center)

                fieldLabel("Ch")
                Picker("MIDI channel", selection: midiChannelBinding(at: index, in: list)) {
                    ForEach(1...16, id: \.self) { c in
                        Text("\(c)").tag(c)
                    }
                }
                .labelsHidden()
                .frame(width: 50 * max(1, textScale))
                .controlSize(.small)
            }

        case .midiCC:
            HStack(spacing: 6) {
                fieldLabel("CC")
                // Lazy Menu so the 128 CC options only build when opened.
                SearchableMenu(choices: {
                    MIDIService.ccPickerLabels.map { entry in
                        MenuSearchChoice(title: entry.label) { updateOutput(index, in: list) { $0.midiCCNumber = entry.number } }
                    }
                }) {
                    ForEach(MIDIService.ccPickerLabels, id: \.number) { entry in
                        Button(entry.label) {
                            updateOutput(index, in: list) { $0.midiCCNumber = entry.number }
                        }
                    }
                } label: {
                    let cc = current.midiCCNumber ?? 1
                    let label = MIDIService.ccNameByNumber[cc].map { "\(cc): \($0)" } ?? "\(cc)"
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
                Picker("MIDI channel", selection: midiChannelBinding(at: index, in: list)) {
                    ForEach(1...16, id: \.self) { c in
                        Text("\(c)").tag(c)
                    }
                }
                .labelsHidden()
                .frame(width: 50 * max(1, textScale))
                .controlSize(.small)

                // A press sends this value (an axis or a MIDI knob follows
                // its own position instead). A hold or double tap action,
                // and the tap of a row that has them, is a press either way.
                let followsPosition = (binding.input.type == .axis || MappingEngine.isContinuousMIDI(binding.input))
                    && list == .main && binding.holdOutputs == nil && binding.doubleTapOutputs == nil && binding.tripleTapOutputs == nil
                if !followsPosition {
                    fieldLabel("Value")
                    TextField("", value: SwiftUI.Binding(
                        get: { current.midiCCValue ?? 127 },
                        set: { v in updateOutput(index, in: list) { $0.midiCCValue = max(0, min(127, v)) } }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 44 * max(1, textScale))
                    .controlSize(.small)
                    .accessibilityLabel("CC value sent on press")
                    .help("The value sent on press; letting go sends 0.")
                }
            }

        case .midiPitchBend:
            HStack(spacing: 6) {
                fieldLabel("Ch")
                Picker("MIDI channel", selection: midiChannelBinding(at: index, in: list)) {
                    ForEach(1...16, id: \.self) { c in
                        Text("\(c)").tag(c)
                    }
                }
                .labelsHidden()
                .frame(width: 50 * max(1, textScale))
                .controlSize(.small)
                Text("Use with a continuous axis for smooth bend.")
                    .font(.callout)
                    .foregroundStyle(.hint)
            }

        case .midiProgramChange:
            HStack(spacing: 6) {
                fieldLabel("Program")
                SearchableMenu(choices: {
                    (0...127).map { p in
                        MenuSearchChoice(title: "\(p)") { updateOutput(index, in: list) { $0.midiProgramNumber = p } }
                    }
                }) {
                    ForEach(0...127, id: \.self) { p in
                        Button("\(p)") { updateOutput(index, in: list) { $0.midiProgramNumber = p } }
                    }
                } label: {
                    menuLabel("\(current.midiProgramNumber ?? 0)")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 70)
                .controlSize(.small)

                fieldLabel("Ch")
                Picker("MIDI channel", selection: midiChannelBinding(at: index, in: list)) {
                    ForEach(1...16, id: \.self) { c in
                        Text("\(c)").tag(c)
                    }
                }
                .labelsHidden()
                .frame(width: 50 * max(1, textScale))
                .controlSize(.small)
            }

        case .midiTransport:
            HStack(spacing: 6) {
                fieldLabel("Action")
                Picker("Transport message", selection: midiTransportBinding(at: index, in: list)) {
                    ForEach(MIDITransport.allCases) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                .labelsHidden()
                .frame(width: 100 * max(1, textScale))
                .controlSize(.small)
                Text("Sends a real-time transport message to the DAW.")
                    .font(.callout)
                    .foregroundStyle(.hint)
            }
        }
    }

    // MARK: - Light bar output

    /// A double tap is one short pulse, so its light keeps the color
    /// rather than showing it for a moment (the engine does the same).
    private func lightModes(for list: OutputList) -> [LightOutputMode] {
        list == .doubleTap || list == .tripleTap ? [.set, .rainbowToggle] : LightOutputMode.allCases
    }

    private func lightModeBinding(at index: Int, in list: OutputList) -> SwiftUI.Binding<LightOutputMode> {
        SwiftUI.Binding(
            get: {
                let mode = output(at: index, in: list)?.resolvedLightMode ?? .whileHeld
                return (list == .doubleTap || list == .tripleTap) && mode == .whileHeld ? .set : mode
            },
            set: { mode in updateOutput(index, in: list) { $0.lightMode = mode } }
        )
    }

    private func lightColorBinding(at index: Int, in list: OutputList) -> SwiftUI.Binding<Color> {
        SwiftUI.Binding(
            get: {
                let c = output(at: index, in: list)?.resolvedLightColor ?? OutputAction.defaultLightColor
                return Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
            },
            set: { value in
                let ns = NSColor(value).usingColorSpace(.sRGB) ?? NSColor(value)
                let rgb = RGBLightColor(floatR: Float(ns.redComponent),
                                        floatG: Float(ns.greenComponent),
                                        floatB: Float(ns.blueComponent))
                updateOutput(index, in: list) { $0.lightColor = rgb }
            }
        )
    }

    /// A colored dot for a swatch menu item. Menus draw SF Symbols as
    /// templates, so the dot is drawn into a plain image instead.
    private static func swatchDot(_ c: RGBLightColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255,
                    blue: CGFloat(c.b) / 255, alpha: 1).setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Mode, then (unless it is the rainbow) the color: a color well and
    /// the light bar picker's named swatches.
    @ViewBuilder
    private func lightBarControls(at index: Int, current: OutputAction, in list: OutputList) -> some View {
        HStack(spacing: 6) {
            Picker("Light bar mode", selection: lightModeBinding(at: index, in: list)) {
                ForEach(lightModes(for: list)) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 130 * max(1, textScale))

            if current.resolvedLightMode != .rainbowToggle {
                ColorPicker("", selection: lightColorBinding(at: index, in: list), supportsOpacity: false)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel("Light bar color")

                SearchableMenu(choices: {
                    RGBLightColor.namedSwatches.map { swatch in
                        MenuSearchChoice(title: swatch.name) { updateOutput(index, in: list) { $0.lightColor = swatch.color } }
                    }
                }) {
                    ForEach(RGBLightColor.namedSwatches, id: \.name) { swatch in
                        Button {
                            updateOutput(index, in: list) { $0.lightColor = swatch.color }
                        } label: {
                            Label {
                                Text(swatch.name)
                            } icon: {
                                Image(nsImage: Self.swatchDot(swatch.color))
                            }
                        }
                    }
                } label: {
                    let c = current.resolvedLightColor
                    menuLabel(c.isNamedSwatch ? c.nearestName : String(localized: "Custom"))
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .frame(width: 84 * max(1, textScale))
                .accessibilityLabel("Light bar swatches")
            } else {
                Text("Speed follows the rainbow setting")
                    .font(.callout)
                    .foregroundStyle(.hint)
                    .fixedSize()
            }
        }
        .hoverHelp("Only a DualSense or DualShock 4 has a color light bar. The color goes to this row's controller; a keyboard, mouse or MIDI row colors every light bar.")
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

    /// One output line under the first: "+", icon, type menu, value
    /// controls and a remove button. The extra actions' editors are built
    /// from these too, every line of them, including the first: it has no
    /// "+" (nothing comes before it) and no remove button while it is the
    /// only output, the same as the main row's first output.
    private func secondaryOutputRow(index: Int, output: OutputAction, in list: OutputList = .main) -> some View {
        let current = self.output(at: index, in: list)
        let removable = index > 0 || outputs(in: list).count > 1
        return HStack(spacing: gap) {
            Text(index > 0 ? "+" : "")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(index == 0)

            HStack(spacing: gap) {
                outputIconCell(for: output)

                outputMenu(select: { outputTypeBinding(at: index, in: list).wrappedValue = $0 },
                           selectSystemKind: { kind in
                               updateOutput(index, in: list) {
                                   $0.type = .systemAction
                                   $0.systemActionKind = kind
                               }
                           },
                           setParameter: { text in
                               updateOutput(index, in: list) { $0.text = text }
                           },
                           setAppAction: { kind, presetID in
                               updateOutput(index, in: list) {
                                   $0.type = .appAction
                                   $0.appActionKind = kind
                                   $0.targetPresetID = presetID
                               }
                           },
                           setKey: { code in
                               updateOutput(index, in: list) {
                                   $0.type = .key
                                   $0.keyCode = code
                               }
                           },
                           keyInShortcut: OutputAction.isShortcut(outputs(in: list).enumerated()
                               .filter { $0.offset != index }.map(\.element)),
                           list: list) {
                    menuChevronLabel(current.map(outputMenuTitle) ?? OutputType.key.displayName)
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .accessibilityLabel("Output type")
                .accessibilityValue(current.map(outputMenuTitle) ?? OutputType.key.displayName)
                .accessibilityInputLabels([Text(current.map(outputMenuTitle) ?? OutputType.key.displayName), Text("Output type")])
            }
            .frame(width: outTypeColWidth, alignment: .leading)

            outputValueControls(at: index, in: list)

            if removable {
                Button {
                    removeOutput(at: index, in: list)
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove this output")
            }

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
            // The menu beside it names the output.
            .accessibilityHidden(true)
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
                        Image(systemName: "chevron.forward")
                            .font(.callout)
                            // Turned to point down when open. SwiftUI mirrors
                            // the rotation in right-to-left too, so 90 is right
                            // for the forward chevron both ways.
                            .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                        Text("Options")
                            .font(.callout)
                    }
                    // Teal, the app icon's own family: apart from the blue
                    // links and the purple Automation; bold once something
                    // in it is set.
                    .foregroundStyle(Self.optionsTeal)
                    .fontWeight(hasAdvancedOptions ? .semibold : .regular)
                    .fixedSize()
                }
                .buttonStyle(.plain)
                // Open or closed, and what is set, for VoiceOver: the chevron's
                // turn and the summary beside it are visual only.
                .accessibilityLabel("Options")
                .accessibilityInputLabels([Text("Options"), Text("Options \(displayNumber)")])
                .accessibilityValue(showAdvanced ? String(localized: "Expanded")
                                    : (advancedOptionsSummary.isEmpty ? String(localized: "Collapsed") : advancedOptionsSummary))
                .accessibilityHint("Shows this row's deadzone, press mode, macro, feedback and extra actions")
                // Collapsed summary of WHICH options are set, replacing the
                // old bare asterisk that said only that something was; with
                // nothing set, what opening it offers, in parentheses.
                if !showAdvanced {
                    Text(hasAdvancedOptions ? advancedOptionsSummary : optionsHint)
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
        binding.deadzone != nil || binding.invertAxis == true || fullTravelShown || fromNeutralShown ||
        binding.toggleMode == true || binding.turboEnabled == true ||
        binding.sensitivityCurve != nil || (binding.repeatCount ?? 1) > 1 ||
        (binding.macroSteps?.isEmpty == false) ||
        binding.variableSensitivity != nil || (binding.rampMs ?? 0) > 0 ||
        binding.holdOutputs != nil || binding.doubleTapOutputs != nil || binding.tripleTapOutputs != nil ||
        binding.hapticEnabled == true || binding.speechEnabled == true ||
        binding.outerDeadzone != nil || binding.keyRepeat == true || binding.blockOriginal == true ||
        (binding.input.type == .stickRegion && binding.zoneSharesStick == false)
    }

    /// What Options holds for this kind of row, shown beside the closed
    /// disclosure while nothing is set, so the row says what it can do.
    /// System teal is about 2.4:1 on a light card, short of the 4.5:1 body
    /// text needs; light appearances get a deeper teal (about 5:1), dark
    /// ones keep the system color.
    static let optionsTeal = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .systemTeal
            : NSColor(srgbRed: 0, green: 0.42, blue: 0.48, alpha: 1)
    })

    private var optionsHint: String {
        switch binding.input.type {
        case .axis, .motion:
            return String(localized: "(open to edit the deadzone, 25% now, sensitivity and inversion)")
        default:
            return String(localized: "(open to edit how it fires, hold, double or triple tap, macro and feedback)")
        }
    }

    /// One-line summary of the configured advanced options, shown next to
    /// the collapsed disclosure. Built from the same fields
    /// `hasAdvancedOptions` checks.
    private var advancedOptionsSummary: String {
        var parts: [String] = []
        if let dz = binding.deadzone {
            parts.append(String(localized: "Deadzone \(Int((dz * 100).rounded()))%"))
        } else if binding.input.type == .axis {
            // Shown at the default too, so the setting is visible without opening Options.
            parts.append(String(localized: "Deadzone 25%"))
        }
        if binding.invertAxis == true { parts.append(String(localized: "Inverted")) }
        if let full = binding.outerDeadzone, binding.input.type == .axis {
            parts.append(String(localized: "Full push at \(Int((full * 100).rounded()))%"))
        }
        if binding.input.type == .stickRegion, binding.zoneSharesStick == false {
            parts.append(isBandRow ? String(localized: "Takes over the control") : String(localized: "Takes over the stick"))
        }
        if binding.keyRepeat == true, showsKeyRepeatToggle { parts.append(String(localized: "Repeats keys")) }
        if binding.blockOriginal == true, showsBlockOriginalToggle { parts.append(String(localized: "Blocks the button")) }
        if !zoneTakenBy.isEmpty {
            parts.append(String(localized: "Waits in region of \(zoneTakenBy.map { "#\($0)" }.joined(separator: ", "))"))
        }
        if fullTravelShown { parts.append(String(localized: "Whole travel")) }
        if fromNeutralShown { parts.append(String(localized: "From the grip")) }
        if let curve = binding.sensitivityCurve, curve != .linear {
            parts.append(curve == .exponential ? String(localized: "Smooth curve") : String(localized: "Aggressive curve"))
        }
        if binding.variableSensitivity == true { parts.append(String(localized: "Variable")) }
        if let r = binding.rampMs, r > 0 { parts.append(String(format: String(localized: "Ramp-up %.3g s"), locale: .current, Double(r) / 1000)) }
        if !binding.modifiers.isEmpty {
            parts.append(String(localized: "With \(binding.modifiers.map { modifierName($0) }.joined(separator: " + "))"))
        }
        if binding.toggleMode == true && binding.turboEnabled == true {
            parts.append(String(localized: "Auto every \(turboIntervalMs) ms"))
        } else {
            if binding.toggleMode == true { parts.append(String(localized: "Toggle")) }
            if binding.turboEnabled == true { parts.append(String(localized: "Every \(turboIntervalMs) ms")) }
        }
        if let n = binding.turboMaxCount, n > 0, binding.turboEnabled == true { parts.append(String(localized: "\(n)x then stop")) }
        if (binding.repeatCount ?? 1) > 1, repeatApplies { parts.append(String(localized: "Repeat x\(binding.repeatCount ?? 1)")) }
        if let steps = binding.macroSteps, !steps.isEmpty {
            parts.append(steps.count == 1 ? String(localized: "Macro 1 step") : String(localized: "Macro \(steps.count) steps"))
        }
        if let hold = binding.holdOutputs, !hold.isEmpty {
            parts.append(String(localized: "Hold \(OutputAction.names(hold).joined(separator: " + "))"))
        }
        if let double = binding.doubleTapOutputs, !double.isEmpty {
            parts.append(String(localized: "2x \(OutputAction.names(double).joined(separator: " + "))"))
        }
        if let triple = binding.tripleTapOutputs, !triple.isEmpty {
            parts.append(String(localized: "3x \(OutputAction.names(triple).joined(separator: " + "))"))
        }
        if binding.hapticEnabled == true {
            if let ms = binding.hapticDurationMs, ms >= FeedbackService.transientCutoffMs {
                parts.append(String(localized: "Vibrate \(hapticDurationLabel(Double(ms)))"))
            } else {
                parts.append(String(localized: "Vibrate"))
            }
        }
        if binding.speechEnabled == true { parts.append(String(localized: "Speak")) }
        return parts.joined(separator: ", ")
    }

    /// Where the row's arrow sits, measured from the row's left edge; the
    /// options divider goes exactly under it.
    private var arrowCenterX: CGFloat {
        let boxEnd: CGFloat = BindingRowView.inputBoxLeading(scale: textScale) + BindingRowView.inputBoxWidth(scale: textScale)
        let half: CGFloat = BindingRowView.arrowSlotWidth / 2
        // The column constants overshoot the arrow's real center by 15 pt
        // (the input box lays out narrower than the sum of its column
        // widths). Measured off a render: arrow at 1185 px, divider at 1215,
        // at 1.97 px per point.
        return boxEnd + half - 15
    }

    /// The row's small live picture, the way into the full Adjust live
    /// sheet. Follows the sliders while they move.
    private var rowPreview: some View {
        MiniDeadzonePreview(
            axisIndex: binding.input.type == .stickRegion ? zoneRowAxis : binding.input.index,
            direction: binding.input.type == .axis ? (binding.input.axisDirection ?? .positive) : nil,
            inner: liveDeadzone ?? Double(binding.deadzone.map(Double.init) ?? defaultDeadzone),
            outer: liveOuterDeadzone ?? Double(binding.outerDeadzone ?? 1.0),
            isInverted: binding.invertAxis == true,
            slot: slot,
            zoneID: binding.input.type == .stickRegion ? binding.input.stickRegionID : nil,
            fullTravel: binding.fullTravel == true
        ) {
            showDeadzoneCalibration = true
        }
    }

    private var advancedOptionsRow: some View {
        // Two columns under the row's own Input and Output headings, split by
        // a divider that sits on the row's arrow: how the control is read on
        // the left, what the row sends on the right.
        let leftWidth = max(220, arrowCenterX - optionsInset - 0.5)
        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) { inputSideOptions }
                .frame(width: leftWidth - 16, alignment: .leading)
                .padding(.trailing, 16)
            Divider()
            VStack(alignment: .leading, spacing: 8) { outputSideOptions }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, Self.arrowSlotWidth / 2 + 4)
        }
        .padding(.leading, optionsInset)
    }

    /// Repeat keys while held, and Block the button's own action, where
    /// each applies. Shown in the stick options and, for buttons, keys,
    /// mouse buttons and every other press input, in their own Press box:
    /// living only in the stick options, neither was reachable on the rows
    /// that need them most.
    private var showsKeyRepeatToggle: Bool {
        binding.toggleMode != true && binding.turboEnabled != true && binding.macroSteps == nil
            && (binding.outputs + (binding.holdOutputs ?? [])).contains(where: { output in
                // A key that can repeat: not a modifier, and an ordinary key
                // (media, volume, brightness and Globe keys never repeat).
                output.type == .key && output.keyCode.map {
                    !(224...231).contains($0) && KeyCodeMap.hidToVirtualKeyCode[$0] != nil
                } == true
            })
    }

    private var showsBlockOriginalToggle: Bool {
        // Only Any mouse or the Mac's own: the engine blocks nothing on a
        // row set to one particular mouse.
        binding.input.type == .extMouse && (binding.input.extMouseKind ?? .button) == .button
            && binding.input.index >= 2
            && [nil, "any", ExternalInputDeviceService.builtInMouseID].contains(binding.input.extDeviceID)
    }

    @ViewBuilder
    private var pressRowToggles: some View {
        // Held keys repeat like a real key. Offered where it can apply: a
        // plain press row with a non-modifier key among its outputs.
        if showsKeyRepeatToggle {
            Toggle(isOn: keyRepeatBinding) {
                Text("Repeat keys while held")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .hoverHelp("Like holding a key on a keyboard: after a moment the key repeats, at the speed set in System Settings, Keyboard. Off, a held key stays down as one press, which games expect.")
        }

        // Block the original: middle and side mouse buttons only, so a
        // bound side button stops also going Back in a browser. Main and
        // secondary click are never offered, so a click can't be lost.
        if showsBlockOriginalToggle {
            Toggle(isOn: blockOriginalBinding) {
                Text("Block the button's own action")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .hoverHelp("While this preset runs, apps stop seeing this button, so it does only what this row says. A side button no longer also goes Back in a browser. Stop the preset and the button works as usual.")
        }

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
                    deadzone: liveDeadzone ?? binding.deadzone.map(Double.init)
                        ?? (MappingEngine.drivesPointer(binding) ? 0.05 : MappingEngine.motionSwitchDeadzone),
                    fromNeutral: binding.fromNeutral == true,
                    drivesPointer: MappingEngine.drivesPointer(binding))
                advancedAxisOptions
            }
        } else if binding.input.type == .axis {
            optionsBox(isTriggerAxis ? "Trigger" : "Stick") {
                HStack(alignment: .top, spacing: 12) {
                    rowPreview
                    VStack(alignment: .leading, spacing: 8) { advancedAxisOptions }
                }
            }
        } else if binding.input.type == .stickRegion {
            optionsBox(isBandRow ? "Band" : "Stick region") {
                HStack(alignment: .top, spacing: 12) {
                    if !isBandRow { rowPreview }
                    VStack(alignment: .leading, spacing: 8) {
                        zoneSharingOptions
                        advancedAxisOptions
                    }
                }
            }
        } else if binding.input.type == .stickGesture {
            optionsBox("Stick gesture") { stickGestureOptions }
        } else if binding.input.type == .touchpad {
            optionsBox("Finger movement") { advancedAxisOptions }
        }
        if ![.motion, .axis, .stickRegion, .stickGesture, .touchpad].contains(binding.input.type),
           showsKeyRepeatToggle || showsBlockOriginalToggle {
            optionsBox("Press") {
                VStack(alignment: .leading, spacing: 8) { pressRowToggles }
            }
        }
        // Calibration and zones are for a PlayStation touchpad; a Steam
        // Controller's pads report their edges already, and zones are on the
        // main surface only.
        if [.touchpad, .touchpadRegion, .touchpadGesture].contains(binding.input.type),
           binding.input.touchpadSurface != 1, presetButtonFamily?.isSteam != true {
            optionsBox("Touchpad") {
                HStack(spacing: 10) {
                    Text("Draw tap regions on the touchpad; each one works like a button.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    TouchpadRegionsButton { showZones(.touchpad) }
                }
            }
        }
        if binding.input.type == .chassisTap {
            optionsBox("Tap the Mac") {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Watch your knocks on a live trace and set how firm a tap has to be. The setting is shared by every preset.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(Self.tapTheMacDisclaimer)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    TapCalibrateButton()
                }
            }
        }
        if ![.extKey, .extMouse, .midi].contains(binding.input.type) {
            optionsBox("Second control") { modifierPicker }
        }
        // A direction row can wait for a region of its own stick or trigger.
        if binding.input.type == .axis, gateRegionKey != nil {
            optionsBox("Region") { regionGatePicker }
        }
    }

    /// Right column: everything about what the row sends.
    @ViewBuilder
    private var outputSideOptions: some View {
        optionsBox("How it fires") { pressBehaviorOptions }
        optionsBox("Macro", spotlightID: "macro") { macroOptions }
        optionsBox("Feedback", spotlightID: "feedback") {
            advancedFeedbackOptions
            if binding.speechEnabled == true {
                speechDetailRow
            }
        }
        // Last, because a full output editor can open inside it.
        optionsBox("Extra actions", spotlightID: "extra") { tapHoldOptions }
    }

    /// Opens Options and points at the box a choice just turned on.
    private func spotlight(_ box: String) {
        showAdvanced = true
        spotlightGlow = nil
        spotlightBox = box
    }

    /// One area of the Options panel: its title at the top-left and its
    /// controls inside one rounded box, so each area reads as a unit
    /// instead of a run of headings and hairlines.
    private func optionsBox<Content: View>(_ title: LocalizedStringKey, spotlightID: String? = nil,
                                           @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.12), lineWidth: 1))
        .overlay {
            if let spotlightID, spotlightGlow == spotlightID {
                OptionsSpotlight(sweeps: !reduceMotion) {
                    if spotlightGlow == spotlightID { spotlightGlow = nil }
                }
            }
        }
        .background(ScrollIntoViewAnchor(active: spotlightID != nil && spotlightBox == spotlightID) {
            spotlightBox = nil
            spotlightGlow = spotlightID
        })
    }

    /// A short label beside a parameter field. Fixed so it never wraps
    /// letter-by-letter when the output column gets narrow.
    private func fieldLabel(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.hint)
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
                    .accessibilityHidden(true)
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
                ThrottledSlider("Vibration strength",
                    value: hapticIntensityBinding,
                    in: 0.1...1.0,
                    step: 0.05,
                    onLiveChange: { liveHaptic = $0 }
                )
                    .frame(width: 60)
                    .accessibilityValue(String(localized: "\(Int(((liveHaptic ?? Double(binding.hapticIntensity ?? 0.6)) * 100).rounded())) percent"))
                    .voiceNames("Strength", "Vibration strength")
                percentField("Strength percent",
                             shown: liveHaptic ?? Double(binding.hapticIntensity ?? 0.6),
                             range: 0.1...1.0, style: .hint, width: 30) {
                    liveHaptic = $0
                    hapticIntensityBinding.wrappedValue = $0
                }
            }
            HStack(spacing: 4) {
                Text("Duration")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ThrottledSlider("Vibration duration",
                    value: hapticDurationBinding,
                    in: 0...Double(FeedbackService.maxDurationMs),
                    step: 20,
                    onLiveChange: { liveHapticDuration = $0 }
                )
                    .frame(width: 60)
                    .accessibilityValue(spokenHapticDuration(liveHapticDuration ?? Double(binding.hapticDurationMs ?? FeedbackService.defaultDurationMs)))
                    .voiceNames("Duration", "Vibration duration")
                Text(hapticDurationLabel(liveHapticDuration ?? Double(binding.hapticDurationMs ?? FeedbackService.defaultDurationMs)))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.hint)
                    // Room for "Tap" and the unit in every language.
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: 44, alignment: .leading)
            }
            .hoverHelp("Tap is a single short pulse. Longer settings rumble for that long, up to two seconds.")
        }

        // Speech toggle
        Toggle(isOn: speechBinding) {
            HStack(spacing: 3) {
                Image(systemName: "speaker.wave.2")
                    .font(.callout)
                    .accessibilityHidden(true)
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
                .focused($phraseFocused)
                .voiceNames("Phrase", "Phrase to speak")
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(maxWidth: 200)

            // No Mac / Controller picker: macOS has no public way to send
            // speech to a controller's speaker, so it always follows the
            // Mac's sound output and the choice did nothing.
            Spacer()
        }
    }

    /// What an extra action can send. A double tap is one short pulse, so
    /// pointer motion and continuous scrolling would do nothing there; a
    /// hold runs them every poll while held. The volume fader follows the
    /// control's position, so it belongs to the main action only, and Pause
    /// Motion While Held is read from the row's main outputs only. A light
    /// bar color suits every list (a double tap's keeps its color, see
    /// lightModes(for:)), so it is offered everywhere.
    private func offersOutputType(_ type: OutputType, in list: OutputList) -> Bool {
        // A hold keeps moving or scrolling while held (the engine runs a
        // held action's pointer motion every poll); a double tap is a
        // single pulse, so it has no motion to give.
        list == .main || (list == .hold && type != .absoluteVolume)
            || ![.mouseMotion, .mouseWheel, .absoluteVolume].contains(type)
    }

    private func appActionKinds(for list: OutputList) -> [AppActionKind] {
        // The held gates act only while the row's own input is held.
        list == .main ? AppActionKind.allCases : AppActionKind.allCases.filter { $0 != .holdMuteMotion && $0 != .holdEnableMotion }
    }

    /// Output-type menu grouped Keyboard / Mouse / MIDI / App, so keyboard-
    /// and-mouse users stop wading through DAW terminology on every choice.
    /// Shared by the primary and secondary output menus and the extra
    /// actions' menus, which leave out what a hold or double tap cannot
    /// send; built lazily on open like KeyCodePicker, so rows render
    /// without pre-building it.
    @ViewBuilder
    private func outputTypeMenuItems(select: @escaping (OutputType) -> Void,
                                     selectSystemKind: @escaping (SystemActionKind) -> Void,
                                     setParameter: @escaping (String) -> Void = { _ in },
                                     setAppAction: @escaping (AppActionKind, UUID?) -> Void = { _, _ in },
                                     setKey: @escaping (Int) -> Void = { _ in },
                                     keyInShortcut: Bool = false,
                                     list: OutputList = .main) -> some View {
        Section("Keyboard") {
            Menu(OutputType.key.displayName) {
                Button("Choose on the row\u{2026}") { select(.key) }
                Divider()
                ForEach(KeyCodeMap.groups, id: \.self) { group in
                    Menu(group) {
                        ForEach(KeyCodeMap.allKeys.filter { $0.group == group }) { key in
                            Button(KeyCodeMap.outputName(for: key.code, inShortcut: keyInShortcut)) { setKey(key.code) }
                                .accessibilityLabel(HotKeySpec.spokenKey(KeyCodeMap.outputName(for: key.code, inShortcut: keyInShortcut)))
                        }
                    }
                }
            }
            Button(OutputType.typeText.displayName) { select(.typeText) }
        }
        Section("Mouse") {
            Button(OutputType.mouseButton.displayName) { select(.mouseButton) }
            if offersOutputType(.mouseMotion, in: list) {
                Button(OutputType.mouseMotion.displayName) { select(.mouseMotion) }
            }
            if offersOutputType(.mouseWheel, in: list) {
                Button(OutputType.mouseWheel.displayName) { select(.mouseWheel) }
            }
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
                ForEach(appActionKinds(for: list)) { kind in
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
        // Feedback and the extra actions belong to the whole row, so only
        // the main action's menus offer them.
        if list == .main {
            Section("Feedback") {
                // A row can do nothing but vibrate or speak: the engine fires
                // feedback on every press whether or not the row has outputs.
                Button(vibrateChoiceTitle) { turnOnVibrate() }
                Button(speakChoiceTitle) { turnOnSpeech() }
            }
            // Same rules as the Options panel: hold and double tap work on a
            // plain row (not toggle or repeat, not a macro), and a macro takes
            // over the row. These shortcuts used to make rows that did nothing.
            Section("Extra actions") {
                let hasMacro = binding.macroSteps?.isEmpty == false
                Button("Different action when held\u{2026}") { addHoldAction() }
                    .disabled(hasMacro || neverHeld)
                Button("Action on a double tap\u{2026}") { addDoubleTapAction() }
                    .disabled(hasMacro)
                Button("Action on a triple tap\u{2026}") { addTripleTapAction() }
                    .disabled(hasMacro)
                Button("Run a sequence of steps (macro)\u{2026}") { startMacro() }
            }
        }
        // Every list may color the light: a hold shows it while held, and a
        // double tap keeps it (see lightModes(for:)).
        if offersOutputType(.lightBar, in: list) {
            Section("Controller") {
                Button {
                    select(.lightBar)
                } label: {
                    Label(OutputType.lightBar.displayName, systemImage: "light.beacon.max.fill")
                }
                Button {
                    select(.controllerProfile)
                } label: {
                    Label(OutputType.controllerProfile.displayName, systemImage: "person.crop.rectangle.stack")
                }
            }
        }
        Section("System") {
            if offersOutputType(.absoluteVolume, in: list) {
                Button(OutputType.absoluteVolume.displayName) { select(.absoluteVolume) }
            }
            ForEach(SystemActionKind.grouped, id: \.category) { group in
                Menu(group.category) {
                    // Run Shortcut and Open App pick the action here; the
                    // Shortcut or app is chosen beside the output. Every
                    // row's menu used to hold every installed app and
                    // Shortcut, thousands of menu items built for each row,
                    // which slowed the editor's open and its first scroll.
                    ForEach(group.kinds) { kind in
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

    private var vibrateChoiceTitle: String {
        binding.hapticEnabled == true ? String(localized: "Vibrate (on)") : String(localized: "Vibrate the controller")
    }

    private var speakChoiceTitle: String {
        binding.speechEnabled == true ? String(localized: "Speak a phrase (on)") : String(localized: "Speak a phrase")
    }

    private func turnOnVibrate() {
        binding.hapticEnabled = true
        if binding.hapticIntensity == nil { binding.hapticIntensity = 0.6 }
        spotlight("feedback")
    }

    private func turnOnSpeech() {
        binding.speechEnabled = true
        spotlight("feedback")
    }

    private func addHoldAction() {
        binding.toggleMode = nil
        binding.turboEnabled = nil
        if binding.holdOutputs?.isEmpty != false {
            binding.holdOutputs = [OutputAction(type: .key, keyCode: 41)]
        }
        if binding.holdThresholdMs == nil { binding.holdThresholdMs = 300 }
        openExtraActions()
    }

    private func addDoubleTapAction() {
        binding.toggleMode = nil
        binding.turboEnabled = nil
        if binding.doubleTapOutputs?.isEmpty != false {
            binding.doubleTapOutputs = [OutputAction(type: .key, keyCode: 40)]
        }
        if binding.doubleTapWindowMs == nil { binding.doubleTapWindowMs = 300 }
        openExtraActions()
    }

    private func addTripleTapAction() {
        binding.toggleMode = nil
        binding.turboEnabled = nil
        if binding.tripleTapOutputs?.isEmpty != false {
            binding.tripleTapOutputs = [OutputAction(type: .key, keyCode: 40)]
        }
        if binding.doubleTapWindowMs == nil { binding.doubleTapWindowMs = 300 }
        openExtraActions()
    }

    private func startMacro() {
        if binding.macroSteps?.isEmpty != false {
            // A step presses a key or a button; any other first
            // output would make a step that does nothing.
            let seed = binding.outputs.first(where: { $0.type == .key || $0.type == .mouseButton })
                ?? OutputAction(type: .key, keyCode: 44)
            binding.macroSteps = [MacroStep(action: seed)]
            binding.holdOutputs = nil
            binding.doubleTapOutputs = nil
            binding.tripleTapOutputs = nil
            binding.turboEnabled = nil
        }
        spotlight("macro")
    }

    /// An output dropdown: the grouped menu, with Search over all of it.
    private func outputMenu<MenuLabel: View>(select: @escaping (OutputType) -> Void,
                                             selectSystemKind: @escaping (SystemActionKind) -> Void,
                                             setParameter: @escaping (String) -> Void = { _ in },
                                             setAppAction: @escaping (AppActionKind, UUID?) -> Void = { _, _ in },
                                             setKey: @escaping (Int) -> Void = { _ in },
                                             keyInShortcut: Bool = false,
                                             list: OutputList = .main,
                                             @ViewBuilder label: @escaping () -> MenuLabel) -> some View {
        SearchableMenu(choices: {
            outputSearchChoices(select: select, selectSystemKind: selectSystemKind, setAppAction: setAppAction,
                                setKey: setKey, keyInShortcut: keyInShortcut, list: list)
        }) {
            outputTypeMenuItems(select: select, selectSystemKind: selectSystemKind, setParameter: setParameter,
                                setAppAction: setAppAction, setKey: setKey, keyInShortcut: keyInShortcut, list: list)
        } label: {
            label()
        }
    }

    /// Everything outputTypeMenuItems offers, nested choices included, in
    /// its order, for the dropdown's Search.
    private func outputSearchChoices(select: @escaping (OutputType) -> Void,
                                     selectSystemKind: @escaping (SystemActionKind) -> Void,
                                     setAppAction: @escaping (AppActionKind, UUID?) -> Void,
                                     setKey: @escaping (Int) -> Void,
                                     keyInShortcut: Bool,
                                     list: OutputList) -> [MenuSearchChoice] {
        typealias C = MenuSearchChoice
        var out: [C] = []
        let keyboard = String(localized: "Keyboard")
        let keyMenu = C.path(keyboard, OutputType.key.displayName)
        out.append(C(title: OutputType.key.displayName, path: keyboard) { select(.key) })
        for group in KeyCodeMap.groups {
            for key in KeyCodeMap.keysByGroup[group] ?? [] {
                let name = KeyCodeMap.outputName(for: key.code, inShortcut: keyInShortcut)
                out.append(C(title: name, path: C.path(keyMenu, group),
                             keywords: key.name + " " + HotKeySpec.spokenKey(name)) { setKey(key.code) })
            }
        }
        out.append(C(title: OutputType.typeText.displayName, path: keyboard) { select(.typeText) })
        let mouse = String(localized: "Mouse")
        for type in [OutputType.mouseButton, .mouseMotion, .mouseWheel, .mouseWheelStep] where offersOutputType(type, in: list) {
            out.append(C(title: type.displayName, path: mouse) { select(type) })
        }
        let midi = String(localized: "MIDI")
        for type in [OutputType.midiNote, .midiCC, .midiPitchBend, .midiProgramChange, .midiTransport] {
            out.append(C(title: type.displayName, path: midi) { select(type) })
        }
        let appMenu = C.path(String(localized: "App"), OutputType.appAction.displayName)
        for kind in appActionKinds(for: list) {
            if kind == .activatePreset {
                for entry in availablePresets {
                    out.append(C(title: entry.name, path: C.path(appMenu, kind.displayName)) { setAppAction(kind, entry.id) })
                }
            } else {
                out.append(C(title: kind.displayName, path: appMenu) { setAppAction(kind, nil) })
            }
        }
        if list == .main {
            let feedback = String(localized: "Feedback")
            out.append(C(title: vibrateChoiceTitle, path: feedback) { turnOnVibrate() })
            out.append(C(title: speakChoiceTitle, path: feedback) { turnOnSpeech() })
            let extra = String(localized: "Extra actions")
            let hasMacro = binding.macroSteps?.isEmpty == false
            if !hasMacro && !neverHeld {
                out.append(C(title: String(localized: "Different action when held\u{2026}"), path: extra) { addHoldAction() })
            }
            if !hasMacro {
                out.append(C(title: String(localized: "Action on a double tap\u{2026}"), path: extra) { addDoubleTapAction() })
                out.append(C(title: String(localized: "Action on a triple tap\u{2026}"), path: extra) { addTripleTapAction() })
            }
            out.append(C(title: String(localized: "Run a sequence of steps (macro)\u{2026}"), path: extra) { startMacro() })
        }
        if offersOutputType(.lightBar, in: list) {
            out.append(C(title: OutputType.lightBar.displayName, path: String(localized: "Controller"),
                         systemImage: "light.beacon.max.fill") { select(.lightBar) })
            out.append(C(title: OutputType.controllerProfile.displayName, path: String(localized: "Controller"),
                         systemImage: "person.crop.rectangle.stack") { select(.controllerProfile) })
        }
        let system = String(localized: "System")
        if offersOutputType(.absoluteVolume, in: list) {
            out.append(C(title: OutputType.absoluteVolume.displayName, path: system) { select(.absoluteVolume) })
        }
        for group in SystemActionKind.grouped {
            for kind in group.kinds {
                out.append(C(title: kind.displayName, path: C.path(system, group.category),
                             systemImage: kind.iconName) { selectSystemKind(kind) })
            }
        }
        return out
    }

    /// While a deadzone slider here is dragged, the row lights and a
    /// running preset fires by it, as with the full sheet's sliders.
    private func previewDeadzone() {
        let inner = liveDeadzone ?? Double(binding.deadzone.map(Double.init) ?? defaultDeadzone)
        let outer = liveOuterDeadzone ?? Double(binding.outerDeadzone ?? 1.0)
        MappingEngine.deadzonePreview = (binding.id, Float(inner), Float(outer))
    }

    private func clearLiveMirrors() {
        // The dragged value is the row's own now (or the drag was dropped);
        // the full sheet clears its own preview when it closes.
        if !showDeadzoneCalibration, MappingEngine.deadzonePreview?.id == binding.id { MappingEngine.deadzonePreview = nil }
        if !liveSpeed.isEmpty { liveSpeed = [:] }
        if liveHaptic != nil { liveHaptic = nil }
        if liveHapticDuration != nil { liveHapticDuration = nil }
        if liveDeadzone != nil { liveDeadzone = nil }
        if liveOuterDeadzone != nil { liveOuterDeadzone = nil }
    }

    /// Selects an input type from the lazy type menu.
    /// Clears the options the row's input type has no control for, after a
    /// type change or a Scan: a stick's Invert, curve or deadzone carried
    /// to a button row could not be seen or changed there, yet the summary
    /// still listed it and Duplicate copied it on.
    static func clearOptionsWithoutControls(_ row: inout BindingModel) {
        let type = row.input.type
        // A scan onto an axis of another stick: its old region is not this one's.
        if type == .axis, let gate = row.onlyInRegion,
           let found = StickRegionService.shared.region(with: gate),
           found.stickIndex != StickRegionService.gateKey(forAxis: row.input.index) {
            row.onlyInRegion = nil
        }
        if type != .axis {
            row.onlyInRegion = nil
            row.sensitivityCurve = nil
            row.outerDeadzone = nil
            row.rampMs = nil
            row.variableSensitivity = nil
            row.fullTravel = nil
        }
        if ![.axis, .motion, .stickRegion, .touchpad, .stickGesture].contains(type) {
            row.deadzone = nil
            row.invertAxis = nil
        }
        if type != .motion { row.fromNeutral = nil }
    }

    private func inputTypeChoice(_ type: InputType) -> some View {
        Button(Self.inputTypeMenuName(type)) { chooseInputType(type) }
    }

    /// An input type as its menu lists it: Hat says what a hat is, since
    /// not everyone knows the word. The row itself keeps the short name.
    static func inputTypeMenuName(_ type: InputType) -> String {
        type == .hat ? String(localized: "Hat (D-pad or thumb switch)") : type.displayName
    }

    private func chooseInputType(_ type: InputType) {
        let previous = binding.input.type
        binding.input.type = type
        if type != previous { Self.clearOptionsWithoutControls(&binding) }
        // A zone, key, mouse, MIDI or region row's number is not a
        // controller button: a band on L2 became "Button 104", which no
        // pad sends, and the row never fired.
        if type == .button, [.stickRegion, .extKey, .extMouse, .midi, .cursorRegion, .touchpadRegion].contains(previous) {
            binding.input.index = 0
            binding.input.stickRegionID = nil
        }
        // The old index means something else in the new type: a tap row
        // made from Button 0 listened for zero taps, a touchpad row read
        // button 3 as its finger, and a hat past 15 had no picker entry.
        if type == .chassisTap, previous != .chassisTap { binding.input.index = 1 }
        if type == .axis, previous == .stickRegion { useWholeAxis() }
        if type == .axis, previous == .stickGesture { binding.input.index = binding.input.index == 1 ? 2 : 0 }
        // Variable and Ramp-up are shown on stick rows only; an Off
        // carried to a touchpad row could not be turned back on.
        if type == .touchpad, previous == .axis {
            binding.variableSensitivity = nil
            binding.rampMs = nil
        }
        if type == .touchpad, binding.input.touchpadFinger == nil {
            // A Steam pad reports one finger only.
            let steam = presetButtonFamily?.isSteam == true
            binding.input.touchpadFinger = !steam && (0...1).contains(binding.input.index) ? binding.input.index : 0
            if steam { binding.input.index = 0 }
        }
        if type == .hat, !(0...15).contains(binding.input.index) { binding.input.index = 0 }
        // A gesture is on a stick: a right stick axis row becomes a right
        // stick gesture, anything else the left stick.
        if type == .stickGesture, previous != .stickGesture {
            binding.input.index = previous == .axis && (2...3).contains(binding.input.index) ? 1
                : (previous == .stickRegion && binding.input.index == 1 ? 1 : 0)
            if binding.input.gestureSteps == nil { binding.input.gestureSteps = [] }
        }
        // Seed defaults when switching INTO MIDI so the row doesn't
        // inherit the previous type's index (button 0 would show as
        // note C-2) and so the message family is never nil.
        // A Mac key, mouse or MIDI row has no Second control box, so a
        // chord left from a controller row could not be seen or removed,
        // and the row fired only while that controller button was held.
        if [.extKey, .extMouse, .midi].contains(type), !binding.modifiers.isEmpty {
            binding.setModifiers([])
        }
        if type == .extMouse, binding.input.axisDirection == nil {
            binding.input.axisDirection = .positive
        }
        if type == .midi {
            // No Invert or Deadzone controls on a MIDI row: an earlier
            // stick's would stay on, unseen.
            if previous != .midi {
                binding.invertAxis = nil
                binding.deadzone = nil
                binding.outerDeadzone = nil
                binding.sensitivityCurve = nil
                binding.variableSensitivity = nil
                binding.rampMs = nil
            }
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
        // Motion and Touchpad rows show a default channel or axis but
        // the engine needs the real value, so a row switched by hand
        // read "Gyro Y +" or "X +" and never fired.
        if type == .motion {
            if binding.input.motionChannel == nil { binding.input.motionChannel = .gyroY }
            if binding.input.axisDirection == nil { binding.input.axisDirection = .positive }
        }
        if type == .touchpad {
            if binding.input.touchpadAxis == nil { binding.input.touchpadAxis = .x }
            if binding.input.axisDirection == nil { binding.input.axisDirection = .positive }
        }
        if type == .touchpadGesture, binding.input.touchpadGestureKind == nil {
            // A Steam pad reports one finger, so it cannot make a two-finger tap.
            binding.input.touchpadGestureKind = presetButtonFamily?.isSteam == true ? .oneFingerTap : .twoFingerTap
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

    /// The stick (0, 1) or band key (100 plus the axis) whose regions a
    /// direction row on this axis can wait for.
    private var gateRegionKey: Int? {
        StickRegionService.gateKey(forAxis: binding.input.index)
    }

    /// A new axis on another stick or band drops the region the row waited
    /// in: it belongs to the old stick.
    private func setAxisIndex(_ i: Int) {
        if StickRegionService.gateKey(forAxis: i) != StickRegionService.gateKey(forAxis: binding.input.index) {
            binding.onlyInRegion = nil
        }
        binding.input.index = i
    }

    /// Anywhere, or only while the stick is inside one region.
    @ViewBuilder
    private var regionGatePicker: some View {
        let key = gateRegionKey ?? 0
        let regions = StickRegionService.shared.regions(forStick: key)
        let chosen = binding.onlyInRegion.flatMap { id in regions.first { $0.id == id } }
        HStack(spacing: 8) {
            Menu {
                Button(String(localized: "Anywhere")) { binding.onlyInRegion = nil }
                if !regions.isEmpty { Divider() }
                ForEach(regions) { region in
                    Button { binding.onlyInRegion = region.id } label: { regionMenuLabel(region) }
                }
                Divider()
                Button("Draw a region on this stick or trigger\u{2026}") { showZones(ZonePart(regionKey: key)) }
            } label: {
                Text(chosen?.shownName ?? String(localized: "Anywhere"))
                    .font(.callout)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Region")
            .accessibilityValue(chosen?.shownName ?? String(localized: "Anywhere"))
            .accessibilityInputLabels([Text("Region"), Text(chosen?.shownName ?? String(localized: "Anywhere"))])
            Spacer(minLength: 0)
        }
        Text(chosen == nil
             ? String(localized: "Fires anywhere past the deadzone, or only inside a region you pick.")
             : String(localized: "Fires only while the stick is inside \(chosen?.shownName ?? "")."))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Shows one part's zones in this row's group, in the editor itself.
    private func showZones(_ part: ZonePart) {
        ShowZonesRequest(bindingID: binding.id, part: part).post()
    }

    /// Opens Options on the Extra actions group, for the row menu's
    /// shortcuts that just turned one of them on.
    private func openExtraActions() {
        spotlight("extra")
    }

    /// The extra actions, each an if-then: when the control is held, or
    /// double tapped, do something else. While a toggle is on, the full
    /// output editor the main action uses opens under it, over the hold or
    /// double-tap list, so the extra action can be any output, or several.
    /// Turning a toggle off removes that action. Disabled while a macro
    /// owns the binding, since the engine gives macros precedence.
    @ViewBuilder
    private var tapHoldOptions: some View {
        let macroOwned = binding.macroSteps?.isEmpty == false
        let tapsLocked = macroOwned || pressMode == .toggle || pressMode == .turbo || pressMode == .autoClick
        // Two groups, each a caption, its switches, and the details of a
        // switch indented under it: what a hold does, then what taps do.
        VStack(alignment: .leading, spacing: 6) {
            Text("While held")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Toggle(isOn: holdEnabledBinding) {
                Text("When held, do something else")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.regular)
            .disabled(macroOwned || (neverHeld && binding.holdOutputs == nil))
            .help(binding.input.type == .stickGesture
                  ? String(localized: "A gesture is not held, so it has no held action.")
                  : neverHeld
                  ? String(localized: "This control is not held, so it has no held action.")
                  : String(localized: "A quick tap sends the row's normal output. Holding past the time set here sends this action instead, held until you let go."))

            if binding.holdOutputs != nil {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("Holding past")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        TextField("Hold threshold in milliseconds", value: holdThresholdBinding, format: .number)
                            .accessibilityHint("50 to 5000 milliseconds")
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 56 * max(1, textScale))
                            .controlSize(.regular)
                            .multilineTextAlignment(.center)
                        Text("ms sends")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    extraOutputEditor(.hold)
                }
                .padding(.leading, 22)
                .disabled(macroOwned)
            }
        }

        Divider()
            .padding(.vertical, 2)

        VStack(alignment: .leading, spacing: 6) {
            Text("Taps")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Toggle(isOn: doubleTapEnabledBinding) {
                Text("When double tapped, do something else")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.regular)
            // The engine reads a double tap only on a plain or hold row, not
            // while the row toggles, repeats, or auto-clicks.
            .disabled(tapsLocked)
            .hoverHelp("Two quick taps send this action instead of the row's normal output. A single tap waits out the time set here before it sends.")

            if binding.doubleTapOutputs != nil {
                extraOutputEditor(.doubleTap)
                    .padding(.leading, 22)
                    .disabled(macroOwned)
            }

            Toggle(isOn: tripleTapEnabledBinding) {
                Text("When triple tapped, do something else")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.regular)
            .disabled(tapsLocked)
            .hoverHelp("Three quick taps send this action instead of the row's normal output. One or two taps wait out the time set here before they send.")

            if binding.tripleTapOutputs != nil {
                extraOutputEditor(.tripleTap)
                    .padding(.leading, 22)
                    .disabled(macroOwned)
            }

            // The window both tap actions count in: each tap inside it of
            // the one before adds to the chain.
            if binding.doubleTapOutputs != nil || binding.tripleTapOutputs != nil {
                HStack(spacing: 8) {
                    Text("Taps count together within")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    TextField("Tap window in milliseconds", value: doubleTapWindowBinding, format: .number)
                        .accessibilityHint("100 to 2000 milliseconds")
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 56 * max(1, textScale))
                        .controlSize(.regular)
                        .multilineTextAlignment(.center)
                    Text("ms")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 22)
                .padding(.top, 2)
                .disabled(macroOwned)
            }
        }
    }

    /// An extra action's outputs, edited with the main action's own output
    /// lines (see secondaryOutputRow), and an Add button in place of the
    /// plus at the end of the main row.
    private func extraOutputEditor(_ list: OutputList) -> some View {
        let items = outputs(in: list)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, output in
                secondaryOutputRow(index: index, output: output, in: list)
            }
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    setOutputs(outputs(in: list) + [OutputAction(type: .key, keyCode: 4)], in: list)
                }
            } label: {
                Label(items.isEmpty ? String(localized: "Add an output") : String(localized: "Add another output"), systemImage: "plus.circle")
                    .font(.callout)
            }
            .buttonStyle(.solidSecondaryCompact)
            .accessibilityLabel(extraListAddLabel(list))
            .accessibilityInputLabels([Text(items.isEmpty ? String(localized: "Add an output") : String(localized: "Add another output")),
                                       Text(extraListAddLabel(list))])
        }
    }

    private func extraListAddLabel(_ list: OutputList) -> String {
        switch list {
        case .hold: return String(localized: "Add an output to the hold action")
        case .tripleTap: return String(localized: "Add an output to the triple tap action")
        default: return String(localized: "Add an output to the double tap action")
        }
    }

    private var holdEnabledBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { binding.holdOutputs != nil },
            set: { on in
                if on {
                    // The same as picking "Different action when held" under
                    // How it fires: hold is one of the press modes, so toggle
                    // and repeat step aside.
                    pressModeBinding.wrappedValue = .hold
                } else {
                    binding.holdOutputs = nil
                    binding.holdThresholdMs = nil
                }
            }
        )
    }

    /// A typed number kept in range, saying so when it was moved: the field
    /// redrew silently and the person believed their value was set.
    static func clamped(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        let kept = min(range.upperBound, max(range.lowerBound, value))
        if kept != value {
            AccessibilityNotification.Announcement(String(localized: "Set to \(kept). The allowed range is \(range.lowerBound) to \(range.upperBound).")).post()
        }
        return kept
    }

    private var holdThresholdBinding: SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.holdThresholdMs ?? 300 },
            set: { binding.holdThresholdMs = Self.clamped($0, 50...5000) }
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
                    if binding.tripleTapOutputs == nil { binding.doubleTapWindowMs = nil }
                }
            }
        )
    }

    private var tripleTapEnabledBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { binding.tripleTapOutputs != nil },
            set: { on in
                if on {
                    binding.tripleTapOutputs = [OutputAction(type: .key, keyCode: 4)]
                    if binding.doubleTapWindowMs == nil { binding.doubleTapWindowMs = 300 }
                } else {
                    binding.tripleTapOutputs = nil
                    if binding.doubleTapOutputs == nil { binding.doubleTapWindowMs = nil }
                }
            }
        )
    }

    private var doubleTapWindowBinding: SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.doubleTapWindowMs ?? 300 },
            set: { binding.doubleTapWindowMs = Self.clamped($0, 100...2000) }
        )
    }

    /// Arrow between the input and output columns. While the row is firing
    /// it tints green and moves toward the output side, then settles back
    /// when the input releases.
    private var firingArrow: some View {
        Image(systemName: "arrow.forward")
            .font(.callout)
            .foregroundStyle(isHighlighted ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary))
            // Static when Reduce Motion is on; the green tint alone signals firing.
            .offset(x: reduceMotion ? 0 : (arrowShoot ? 5 : -5))
            // One nudge toward the output while firing, not a loop: a
            // repeating animation redrew the whole editor at the display's
            // rate for as long as any row stayed lit (a resting stick past
            // its deadzone, a held touch sensor), which cost every frame of
            // scrolling.
            .animation(reduceMotion ? nil : (arrowShoot ? .easeOut(duration: 0.18) : .easeOut(duration: 0.15)),
                       value: arrowShoot)
            .frame(width: arrowWidth)
            .accessibilityHidden(true)
            .onChange(of: isHighlighted) { _, firing in
                arrowShoot = reduceMotion ? false : firing
            }
    }


    /// What the engine uses when the row sets no deadzone: 0.05 for a
    /// motion row that moves the pointer (it smooths below that), 0.25 for
    /// everything else. The slider showed 25% on gyro pointer rows, and
    /// lowering it made slow tilts more damped, not less.
    private var defaultDeadzone: Double {
        binding.input.type == .motion && MappingEngine.drivesPointer(binding) ? 0.05 : 0.25
    }

    /// A zone on one axis's travel rather than on a stick's plane.
    private var isBandRow: Bool {
        binding.input.type == .stickRegion && StickRegionService.isBandKey(binding.input.index)
    }

    @ViewBuilder
    private var advancedAxisOptions: some View {
        // Deadzone: the setting people come to Options for, so it leads, is
        // labeled in full strength, and says in one line what it does.
        // Not on touchpad rows, nor on a band, which is its own threshold:
        // the engine never reads it there.
        if binding.input.type != .touchpad && !isBandRow {
        HStack(spacing: 4) {
            Text("Deadzone")
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
            ThrottledSlider("Deadzone",
                value: deadzoneBinding,
                in: 0.01...0.9,
                step: 0.01,
                onLiveChange: { liveDeadzone = $0; previewDeadzone() }
            )
                .frame(minWidth: 140, maxWidth: 220)
                .accessibilityValue(String(localized: "\(Int(((liveDeadzone ?? Double(binding.deadzone.map(Double.init) ?? defaultDeadzone)) * 100).rounded())) percent"))
            // The percent can be typed as well as dragged to, for Voice
            // Control and anyone who cannot land a slider within 1%.
            percentField("Deadzone percent",
                         shown: liveDeadzone ?? Double(binding.deadzone.map(Double.init) ?? defaultDeadzone),
                         range: 0.01...0.9, style: .secondary, width: 34) {
                liveDeadzone = $0
                deadzoneBinding.wrappedValue = $0
            }
        }
        }
        if binding.input.type == .axis {
            Text(isTriggerAxis
                 ? String(localized: "How far the trigger is pulled before this row reacts. Raise it if the row fires when a finger just rests on the trigger.")
                 : String(localized: "How far the stick moves before this row reacts. Raise it if the pointer or camera drifts when you let go; lower it if small pushes do nothing."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // The other side of a zone's takeover, said on the row it stops.
            if !zoneTakenBy.isEmpty {
                let rows = zoneTakenBy.map { "#\($0)" }.joined(separator: ", ")
                Text(zoneTakenBy.count == 1
                     ? String(localized: "Inside the region of row \(rows), this row waits while that row fires.")
                     : String(localized: "Inside the regions of rows \(rows), this row waits while those rows fire."))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        // Full push: the engine treats anything past this as all the way, so
        // a stick that no longer reaches its corners still gives full speed.
        if binding.input.type == .axis {
            HStack(spacing: 4) {
                Text("Full push at")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ThrottledSlider("Full push at",
                    value: outerDeadzoneBinding,
                    in: 0.2...1.0,
                    step: 0.01,
                    onLiveChange: { liveOuterDeadzone = $0; previewDeadzone() }
                )
                    .frame(minWidth: 140, maxWidth: 220)
                    .accessibilityValue(String(localized: "\(Int(((liveOuterDeadzone ?? Double(binding.outerDeadzone ?? 1.0)) * 100).rounded())) percent"))
                percentField("Full push percent",
                             shown: liveOuterDeadzone ?? Double(binding.outerDeadzone ?? 1.0),
                             range: 0.2...1.0, style: .hint, width: 30) {
                    liveOuterDeadzone = $0
                    outerDeadzoneBinding.wrappedValue = $0
                }
            }
            .hoverHelp("How far the control has to move to count as fully pushed. Past it the row keeps working, at full strength. Lower it for a worn stick or a short-throw trigger.")
        }

        pressRowToggles

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
            .help(invertExplanation)
        }

        // Every motion row offers the ready-made sets of rows, for someone
        // who does not know which channel does what.
        if binding.input.type == .motion {
            Menu {
                ForEach(MotionSetup.allCases) { setup in
                    Button(setup.title) { MotionSetupAction.perform?(binding.id, setup) }
                }
            } label: {
                Label("Set Up Full Gyro", systemImage: "gyroscope")
                    .font(.callout)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()
            .help("Adds the rows a full motion setup needs to this device: gyro aim for the pointer, tilt to move with the arrow keys, or one row per shake and jab. Rows the device already has are skipped.")
        }

        // Tilt angle rows: level can be the grip instead of lying flat.
        if binding.input.type == .motion,
           [.pitchAngle, .rollAngle, .yawAngle].contains(binding.input.motionChannel ?? .gyroY) {
            Toggle(isOn: SwiftUI.Binding(
                get: { binding.fromNeutral == true },
                set: { binding.fromNeutral = $0 ? true : nil }
            )) {
                Text("Level is how you hold it")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .help("Measure the lean from where the controller is held, instead of from lying flat, so a normal grip reads as level. Level is taken when the preset starts, at a re-zero, and whenever motion comes back on after Pause Motion, Motion Only While Held or Motion On / Off.")
        }

        // A pedal, throttle or lever that rests at one end: the row reads
        // its whole travel. Not on the trigger slots, which already do.
        if binding.input.type == .axis, !isTriggerAxis, binding.input.axisDirection != .none,
           !axisAlreadyOneWay || binding.fullTravel == true {
            Toggle(isOn: SwiftUI.Binding(
                get: { binding.fullTravel == true },
                set: { binding.fullTravel = $0 ? true : nil }
            )) {
                Text("Rests at one end (pedal or throttle)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .help("For a pedal, throttle or lever that rests at one end: the row reads its whole travel, nothing at rest and full at the far end. Scan turns this on when the control was resting at an end.")
        }

        // Curve and Variable apply only on the engine's axis paths.
        if binding.input.type == .axis {
            // Curve
            HStack(spacing: 4) {
                Text("Curve")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Picker("Curve", selection: curveBinding) {
                    Text("Linear").tag(SensitivityCurve.linear)
                    Text("Smooth").tag(SensitivityCurve.exponential)
                    Text("Aggressive").tag(SensitivityCurve.aggressive)
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 80 * max(1, textScale))
            }
            .hoverHelp("How speed grows as you push: Linear is even, Smooth stays slow near the center for fine aim, Aggressive gets fast sooner.")

            // Variable Sensitivity (scale output by axis depth)
            Toggle(isOn: variableSensitivityBinding) {
                Text("Variable")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .hoverHelp("Scale output speed by how far the joystick or trigger is pushed.")

            // Ramp-up: pointer rows only. Starts slow and eases to full speed.
            if binding.outputs.contains(where: { $0.type == .mouseMotion }) {
                HStack(spacing: 4) {
                    Text("Ramp-up")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    // Throttled like the other editor sliders: a plain Slider
                    // saved the preset, and added an undo step, on every tick.
                    ThrottledSlider("Ramp-up", value: rampBinding, in: 0...1500, step: 50)
                        .controlSize(.small)
                        .frame(width: 110)
                        .accessibilityValue((binding.rampMs ?? 0) == 0 ? String(localized: "Off") : String(format: String(localized: "%.3g seconds"), locale: .current, Double(binding.rampMs ?? 0) / 1000))
                    Text((binding.rampMs ?? 0) == 0 ? String(localized: "Off") : String(format: String(localized: "%.3g s"), locale: .current, Double(binding.rampMs ?? 0) / 1000))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.hint)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(minWidth: 42, alignment: .leading)
                }
                .hoverHelp("The pointer starts at a fifth of its speed and builds to full speed over this long of holding the stick, so a short push makes a small move you can stop on a target. Off keeps the speed constant.")
            }
        }
    }

    /// A slider's percent, drawn as the plain number it always was but
    /// typable: click it, type 15 and press Return.
    private func percentField<S: ShapeStyle>(_ label: LocalizedStringKey, shown: Double, range: ClosedRange<Double>,
                              style: S, width: CGFloat,
                              set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 0) {
            TextField(label, value: SwiftUI.Binding(
                get: { (shown * 100).rounded() },
                set: { set(min(range.upperBound, max(range.lowerBound, $0 / 100))) }),
                format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .labelsHidden()
                .accessibilityLabel(label)
            Text(verbatim: "%").accessibilityHidden(true)
        }
        .font(.callout.monospacedDigit())
        .foregroundStyle(style)
        // Room for "100%", growing with Text Size like the columns.
        .frame(width: (width + 10) * max(1, textScale))
    }

    private var rampBinding: SwiftUI.Binding<Double> {
        SwiftUI.Binding(
            get: { Double(binding.rampMs ?? 0) },
            set: { binding.rampMs = $0 < 25 ? nil : Int($0) }
        )
    }

    /// Chord picker: this row only fires while another button is held.
    /// Controller rows only; keyboard, mouse, and MIDI rows have no
    /// second button on the same device to pair with.
    @ViewBuilder
    private var modifierPicker: some View {
        let mods = binding.modifiers
        let modNames = LocalizedList.and(mods.map { modifierName($0) })
        ForEach(Array(mods.enumerated()), id: \.offset) { i, mod in
            HStack(spacing: 8) {
                Image(systemName: "plus.square.on.square")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(i == 0 ? String(localized: "While also holding") : String(localized: "and"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 118, alignment: .leading)
                modifierMenu(label: modifierName(mod), tinted: true, slot: i) { replaceModifier(at: i, with: $0) }
                Button {
                    var list = binding.modifiers
                    list.remove(at: i)
                    binding.setModifiers(list)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.hint)
                .accessibilityLabel(String(localized: "Remove \(modifierName(mod))", comment: "Takes a held control out of the chord; the control's name"))
            }
        }
        if mods.count < BindingModel.maxModifiers {
            HStack(spacing: 8) {
                Image(systemName: "plus.square.on.square")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(mods.isEmpty ? String(localized: "While also holding") : String(localized: "and"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 118, alignment: .leading)
                modifierMenu(label: mods.isEmpty ? String(localized: "Nothing\u{2026}") : String(localized: "Add another\u{2026}"), tinted: false, slot: nil) { event in
                    binding.setModifiers(binding.modifiers + [event])
                }
                Button("Scan") { onScanModifier(nil) }
                    .controlSize(.small)
                    .hoverHelp("Press or move any control on any connected device to add it to the list this row waits for.")
            }
        }
        Text(mods.isEmpty
             ? String(localized: "Waits for up to three other controls, held with this one.")
             : (mods.count == 1
                ? String(localized: "Fires only while \(modNames) is held. A plain row on the same control stays quiet while the chord is held.")
                : String(localized: "Fires only while \(modNames) are held. A plain row on the same control stays quiet while the chord is held.")))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The menu of controls a chord slot can take.
    private func modifierMenu(label: String, tinted: Bool, slot: Int?,
                              pick: @escaping (InputEvent) -> Void) -> some View {
        SearchableMenu(choices: {
            familyButtonLabels.map { entry in
                MenuSearchChoice(title: buttonMenuLabel(for: entry.index)) { pick(InputEvent(type: .button, index: entry.index)) }
            } + extraButtons.filter { e in !familyButtonLabels.contains { $0.index == e.index } }.map { extra in
                MenuSearchChoice(title: extra.label) { pick(InputEvent(type: .button, index: extra.index)) }
            } + [MenuSearchChoice(title: String(localized: "Scan for any control\u{2026}")) { onScanModifier(slot) }]
        }) {
            ForEach(familyButtonLabels, id: \.index) { entry in
                Button(buttonMenuLabel(for: entry.index)) {
                    pick(InputEvent(type: .button, index: entry.index))
                }
            }
            ForEach(extraButtons.filter { e in !familyButtonLabels.contains { $0.index == e.index } }, id: \.index) { extra in
                Button(extra.label) { pick(InputEvent(type: .button, index: extra.index)) }
            }
            Divider()
            Button("Scan for any control\u{2026}") { onScanModifier(slot) }
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
        // With a macro, only the modes the engine runs a macro in: turbo
        // and auto-click skipped the macro or sent both, and hold never ran.
        let hasMacro = binding.macroSteps?.isEmpty == false
        // A gesture is over the moment it lands: nothing is held, so the
        // modes that read a hold are not offered.
        let gesture = neverHeld
        Picker("Press mode", selection: pressModeBinding) {
            Text(gesture ? "Sends a quick press" : "Fires while held").tag(PressMode.normal)
            Text("Toggles on and off").tag(PressMode.toggle)
            if (!hasMacro && !gesture) || pressMode == .turbo {
                Text("Repeats while held").tag(PressMode.turbo)
            }
            if !hasMacro || pressMode == .autoClick {
                Text(gesture ? "Repeats until done again" : "Repeats until pressed again").tag(PressMode.autoClick)
            }
            if (!hasMacro && !gesture) || pressMode == .hold {
                Text("Different action when held").tag(PressMode.hold)
            }
        }
        .labelsHidden()
        .frame(width: 260 * max(1, textScale))
        .controlSize(.regular)
        .accessibilityInputLabels([Text(pressModeTitle), Text("Press mode")])
        .hoverHelp("What a press of this control does.")

        Text(hasMacro && ![PressMode.normal, .toggle].contains(pressMode)
             ? String(localized: "This row runs a macro, which only fires while held or toggles on and off. Pick one of those, or remove the macro.")
             : pressModeExplanation)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if binding.turboEnabled == true {
            autoClickOptions
        }

        // Repeat count: only where the engine uses it, a plain press or a
        // macro. Toggle, turbo, hold and double-tap rows ignored it while
        // the field and the summary said "Repeat x3".
        if repeatApplies {
        HStack(spacing: 6) {
            Text("Repeat")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("", value: repeatCountBinding, format: .number)
                .accessibilityLabel("Repeat count")
                .accessibilityHint("1 to 100")
                .textFieldStyle(.roundedBorder)
                .frame(width: 56 * max(1, textScale))
                .controlSize(.regular)
                .multilineTextAlignment(.center)
            Text((binding.repeatCount ?? 1) > 1 ? String(localized: "times per press") : String(localized: "time per press"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }

        if (binding.repeatCount ?? 1) > 1 {
            HStack(spacing: 6) {
                Text("Wait")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("", value: repeatDelayBinding, format: .number)
                    .accessibilityLabel("Milliseconds between repeats")
                    .accessibilityHint("10 to 5000 milliseconds")
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56 * max(1, textScale))
                    .controlSize(.regular)
                    .multilineTextAlignment(.center)
                Text("ms between repeats")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        }

    }

    private var repeatApplies: Bool {
        binding.macroSteps?.isEmpty == false
            || (pressMode == .normal && binding.holdOutputs == nil && binding.doubleTapOutputs == nil && binding.tripleTapOutputs == nil)
    }

    /// Macro toggle with its editor opening directly underneath.
    @ViewBuilder
    private var macroOptions: some View {
        Toggle(isOn: macroToggleBinding) {
            HStack(spacing: 5) {
                Image(systemName: "bolt.fill")
                    .font(.callout)
                    .accessibilityHidden(true)
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
            TextField("Repeat interval in milliseconds", value: turboIntervalBinding, format: .number)
                .accessibilityHint("5 to 60000 milliseconds")
                .textFieldStyle(.roundedBorder)
                .frame(width: 64 * max(1, textScale))
                .controlSize(.regular)
                .multilineTextAlignment(.center)
            Text("ms")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(String(format: String(localized: "(%.1f per second)"), locale: .current, 1000.0 / Double(max(5, turboIntervalMs))))
                .font(.callout)
                .foregroundStyle(.hint)
        }
        .hoverHelp("Time between presses. 100 ms is ten per second; 1000 ms is one per second.")
        HStack(spacing: 6) {
            Text("Vary by up to")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Random variation in milliseconds", value: turboJitterBinding, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 56 * max(1, textScale))
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
            TextField("Stop after this many presses", value: turboMaxCountBinding, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 56 * max(1, textScale))
                .controlSize(.regular)
                .multilineTextAlignment(.center)
            Text((binding.turboMaxCount ?? 0) > 0 ? String(localized: "presses") : String(localized: "presses (0 keeps going)"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .hoverHelp("Ends the run after this many presses. 0 means it keeps going until you release, or press again in toggle mode.")
    }

    /// Where a mouse button output clicks: wherever the pointer is, or a
    /// fixed point on screen captured from the pointer's current position.
    @ViewBuilder
    private func clickPointControls(at index: Int, in list: OutputList = .main) -> some View {
        let current = output(at: index, in: list)
        let fixed = current?.clickX != nil
        Menu {
            Button("Where the pointer is") {
                updateOutput(index, in: list) {
                    $0.clickX = nil
                    $0.clickY = nil
                }
            }
            Button("At a fixed point: the pointer's position in a few seconds") {
                captureClickPoint(at: index, in: list)
            }
        } label: {
            menuLabel((clickPointTarget == "\(index)-\(list)" ? clickPointLeft : nil).map { String(localized: "Taking the spot in \($0)\u{2026}") } ?? (fixed
                      ? String(format: String(localized: "at %.0f, %.0f"), locale: .current, current?.clickX ?? 0, current?.clickY ?? 0)
                      : String(localized: "at pointer")))
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .hoverHelp("Click wherever the pointer is, or always at one spot on screen. To set the spot, pick the second option and move the pointer there; a countdown shows on this menu and is spoken, and the spot is taken when it ends. Or type the spot in the X and Y fields.")
        if fixed {
            // The spot typed in directly, for anyone who cannot hold the
            // pointer still on a target through the countdown.
            HStack(spacing: 4) {
                Text("X").font(.caption).foregroundStyle(.secondary)
                TextField("X", value: clickCoordinate(index, \.clickX, in: list), format: .number.grouping(.never))
                    .frame(width: 56 * max(1, textScale))
                    .accessibilityLabel("Click point X, in points from the left of the main display")
                Text("Y").font(.caption).foregroundStyle(.secondary)
                TextField("Y", value: clickCoordinate(index, \.clickY, in: list), format: .number.grouping(.never))
                    .frame(width: 56 * max(1, textScale))
                    .accessibilityLabel("Click point Y, in points from the top of the main display")
            }
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
        }
    }

    private func clickCoordinate(_ index: Int, _ path: WritableKeyPath<OutputAction, Double?>,
                                 in list: OutputList = .main) -> SwiftUI.Binding<Double> {
        SwiftUI.Binding(
            get: { output(at: index, in: list)?[keyPath: path] ?? 0 },
            set: { value in
                updateOutput(index, in: list) { $0[keyPath: path] = max(-100_000, min(100_000, value.rounded())) }
            })
    }

    /// Records the pointer's position two seconds after the menu closes, so
    /// the user can move the pointer to the target first. Stored in
    /// CoreGraphics coordinates (origin top-left) to match the click events.
    private func captureClickPoint(at index: Int, in list: OutputList = .main) {
        // A countdown seen on the menu and spoken, so nobody is surprised
        // by when the spot is taken. Switch Control glides the pointer
        // slowly, so it gets longer.
        let total = NSWorkspace.shared.isSwitchControlEnabled ? 10 : 3
        Self.announce(String(localized: "Move the pointer to the spot. Taken in \(total) seconds."))
        clickPointLeft = total
        clickPointTarget = "\(index)-\(list)"
        for step in 1..<total {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step)) {
                clickPointLeft = total - step
                // Queued behind the instruction rather than cutting it off.
                if total - step <= 2 { Self.announce("\(total - step)", priority: .medium) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(total)) {
            clickPointLeft = nil
            guard output(at: index, in: list) != nil else { return }
            let location = NSEvent.mouseLocation
            let height = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
            let x = Double(location.x.rounded()), y = Double((height - location.y).rounded())
            updateOutput(index, in: list) {
                $0.clickX = x
                $0.clickY = y
            }
            NSSound(named: "Tink")?.play()
            Self.announce(String(localized: "Spot set at \(Int(x)), \(Int(y))"))
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
                let clamped = Self.clamped(ms, 5...60_000)
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
    /// A stick gesture, a touchpad gesture, a tap on the Mac, a MIDI program
    /// change or transport message, or a knob in Turn mode: pressed for a
    /// moment and never held (MappingEngine.isOneShot), so hold, turbo and a
    /// held action never or always fired on them.
    private var neverHeld: Bool {
        binding.input.type == .stickGesture || MappingEngine.isOneShot(binding.input)
    }

    private var pressModeExplanation: String {
        if neverHeld, binding.input.type != .stickGesture {
            switch pressMode {
            case .normal: return String(localized: "Each time it happens, the output is pressed and let go once.")
            case .toggle: return String(localized: "Each time it happens, the output turns on, and the next time off.")
            case .autoClick: return String(localized: "It starts the output firing over and over, and the next time stops it.")
            case .turbo, .hold: return String(localized: "This control is not held, so this does nothing here. Pick another way for it to fire.")
            }
        }
        if binding.input.type == .stickGesture {
            switch pressMode {
            case .normal: return String(localized: "Each time the gesture is made, the output is pressed and let go once.")
            case .toggle: return String(localized: "The gesture turns the output on and leaves it on. Making it again turns it off.")
            case .autoClick: return String(localized: "The gesture starts the output firing over and over, and making it again stops it.")
            case .turbo, .hold: return String(localized: "A gesture is not held, so this does nothing here. Pick another way for it to fire.")
            }
        }
        switch pressMode {
        case .normal:
            return String(localized: "The output is held down for as long as you hold the control, and released when you let go.")
        case .toggle:
            return String(localized: "One press turns the output on and leaves it on. The next press turns it off.")
        case .turbo:
            return String(localized: "The output fires over and over while you hold the control, at the rate below.")
        case .autoClick:
            return String(localized: "Press once to start the output firing over and over, and press again to stop it. An auto-clicker: put a click on this row and it clicks for you.")
        case .hold:
            return String(localized: "A quick tap sends the normal output. Holding past the time set under Extra actions sends something else instead, so one control can do two jobs.")
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
                // Toggle, repeat and auto-click never run a double tap; it
                // stayed on behind a disabled checkbox, and the summary still
                // said "2x".
                if mode == .toggle || mode == .turbo || mode == .autoClick {
                    binding.doubleTapOutputs = nil
                    binding.doubleTapWindowMs = nil
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
                    // Same as the Extra actions menu: a macro takes the
                    // row over, so repeat, hold and double tap step aside.
                    binding.turboEnabled = nil
                    binding.holdOutputs = nil
                    binding.doubleTapOutputs = nil
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
            get: { binding.deadzone.map(Double.init) ?? defaultDeadzone },
            set: { binding.deadzone = Float($0) }
        )
    }

    /// Triggers live on axis indices 4 (left) and 5 (right) by convention.
    /// Used to switch the Calibrate button icon between trigger gauge and
    /// joystick circle styles.
    private var invertExplanation: String {
        switch binding.input.type {
        case .motion: return String(localized: "Read the tilt the other way round: this row fires when the controller moves opposite to its named direction.")
        case .touchpad: return String(localized: "Read the finger the other way round: a swipe left counts as right and up as down for this row.")
        case .stickGesture:
            return String(localized: "Mirror the stick before reading the gesture: a flick up counts as down and a flick left as right.")
        case .stickRegion:
            return isBandRow
                ? String(localized: "Turn the travel over before checking the band, so a band at the top fires at the bottom.")
                : String(localized: "Mirror the stick before checking the region, so the region is entered from the opposite side.")
        default: return String(localized: "Read the stick backwards for this row: pushed left counts as right and up as down, and variable speed follows the reversed value. It is per row, so the row for the other direction is unaffected.")
        }
    }

    /// Ready-made motion rows for this row's group (see MotionSetup).
    @ViewBuilder
    private var motionSetupSection: some View {
        Section("Set Up Full Gyro") {
            ForEach(MotionSetup.allCases) { setup in
                Button(setup.title) { MotionSetupAction.perform?(binding.id, setup) }
            }
        }
    }

    /// The two options as the engine uses them, and only where their
    /// toggles are shown.
    /// The pad behind the row reads this axis 0 to 1 already. Read through
    /// the engine's service, not observed, so rows do not redraw on input.
    private var axisAlreadyOneWay: Bool {
        guard binding.input.type == .axis, let service = MappingEngine.current?.controllerServiceForSettings else { return false }
        return service.axisReadsOneWay(slot: slot, index: binding.input.index)
    }

    private var fullTravelShown: Bool {
        binding.fullTravel == true && binding.input.type == .axis && !isTriggerAxis && binding.input.axisDirection != .none
    }
    private var fromNeutralShown: Bool {
        binding.fromNeutral == true && binding.input.type == .motion
            && [.pitchAngle, .rollAngle, .yawAngle].contains(binding.input.motionChannel ?? .gyroY)
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

    private var keyRepeatBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            // Off unless turned on, as in 1.5: every row saved before 1.6
            // has no setting, and holding Command Tab or Return there must
            // not start repeating after the update.
            get: { binding.keyRepeat == true },
            set: { binding.keyRepeat = $0 ? true : nil }
        )
    }

    private var blockOriginalBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { binding.blockOriginal ?? false },
            // Off is stored as false, not removed, so the 1.6 upgrade that
            // turns blocking on for never-set side-button rows (run again on
            // a backup restore) leaves a row the user turned off alone.
            set: { binding.blockOriginal = $0 }
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
            set: { binding.repeatCount = $0 <= 1 ? nil : Self.clamped($0, 1...100) }
        )
    }

    private var repeatDelayBinding: SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.repeatDelayMs ?? 100 },
            set: { binding.repeatDelayMs = Self.clamped($0, 10...5000) }
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

    /// The press mode picker's shown choice, which Voice Control answers to.
    private var pressModeTitle: String {
        switch pressMode {
        case .normal: return String(localized: "Fires while held")
        case .toggle: return String(localized: "Toggles on and off")
        case .turbo: return String(localized: "Repeats while held")
        case .autoClick: return String(localized: "Repeats until pressed again")
        case .hold: return String(localized: "Different action when held")
        }
    }

    /// The vibration length as VoiceOver says it, in words, not "ms".
    private func spokenHapticDuration(_ ms: Double) -> String {
        if ms < Double(FeedbackService.transientCutoffMs) { return String(localized: "Tap") }
        if ms >= 1000 { return String(localized: "\((ms / 1000).formatted(.number.precision(.fractionLength(1)))) seconds") }
        return String(localized: "\(Int(ms)) milliseconds")
    }

    private func hapticDurationLabel(_ ms: Double) -> String {
        ms < Double(FeedbackService.transientCutoffMs) ? String(localized: "Tap") :
            ms >= 1000 ? String(format: String(localized: "%.1f s"), locale: .current, ms / 1000) : String(localized: "\(Int(ms)) ms")
    }

    private var speechBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { binding.speechEnabled ?? false },
            set: { binding.speechEnabled = $0 ? true : nil }
        )
    }

    private var speechTextBinding: SwiftUI.Binding<String> {
        SwiftUI.Binding(
            // A built-in phrase in the app's language, English on disk.
            // Shown as typed while it is being typed: passing through a
            // shipped word ("Hello") swapped the field to its translation.
            get: { phraseFocused ? (binding.speechText ?? "") : ShippedText.phrase(binding.speechText ?? "") },
            set: { new in
                let shown = phraseFocused ? (binding.speechText ?? "") : ShippedText.phrase(binding.speechText ?? "")
                if new != shown { binding.speechText = new.isEmpty ? nil : new }
            }
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
            // When it runs comes first: it is part of what the macro is, not
            // a detail tucked beside the Add button.
            HStack(spacing: 8) {
                Text("When it runs")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Picker("When it runs", selection: macroStopOnReleaseBinding) {
                    Text("Every step, each time it is pressed").tag(false)
                    Text("Only while held; letting go stops it").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .hoverHelp("Each time it is pressed: one press plays every step. Only while held: letting go stops the rest of the steps and releases any held keys.")
                Spacer()
            }

            Text("Steps, played in order")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let steps = binding.macroSteps, !steps.isEmpty {
                macroStepsList(steps)
            } else {
                Text("No steps yet. Add the first step to build the sequence.")
                    .font(.callout)
                    .foregroundStyle(.hint)
            }

            Button {
                var steps = binding.macroSteps ?? []
                steps.append(MacroStep(action: OutputAction(type: .key, keyCode: 4)))
                binding.macroSteps = steps
                binding.turboEnabled = nil
                AccessibilityNotification.Announcement(String(localized: "Step \(steps.count) added")).post()
            } label: {
                Label((binding.macroSteps?.isEmpty ?? true) ? String(localized: "Add a step") : String(localized: "Add another step"),
                      systemImage: "plus.circle")
                    .font(.callout)
            }
            .buttonStyle(.solidSecondaryCompact)

            Text("A macro replaces the row's normal output and can have as many steps as you like. For Command V then Command K, add two Tap steps, V and K, each with \u{2318} on. Hold down keeps a key held while later steps run, and Release lets it go. To play the whole macro more than once per press, set Repeat under How it fires.")
                .font(.callout)
                .foregroundStyle(.hint)
                .fixedSize(horizontal: false, vertical: true)
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
                .foregroundStyle(.hint)
                .frame(width: 18)

            Picker("Step action", selection: macroStepKindBinding(at: index)) {
                ForEach(MacroStepKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 84 * max(1, textScale))
            .accessibilityLabel("Step \(index + 1) action")
            .hoverHelp("Tap presses and releases. Hold down keeps the key held while later steps run (for chords like Cmd+C). Release lets go of a held key.")

            Picker("Step type", selection: macroStepTypeBinding(at: index)) {
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
            .frame(width: 100 * max(1, textScale))

            if step.action.type == .key {
                KeyCodePicker(selectedCode: macroStepKeyBinding(at: index),
                              inShortcut: !(macroStep(at: index)?.modifiers ?? []).allSatisfy { !KeyCodeMap.shortcutModifierCodes.contains($0) },
                              voiceRole: "Step \(index + 1) key")
                    .frame(width: 90 * max(1, textScale))
                    .accessibilityLabel("Step \(index + 1) key")
                ShortcutModifierToggles(outputs: macroStepShortcutBinding(at: index), defaultKey: 4)
            } else if step.action.type == .mouseButton {
                Picker("Mouse button", selection: macroStepMouseBtnBinding(at: index)) {
                    ForEach(0..<6, id: \.self) { i in
                        Text(mouseButtonName(i)).tag(i)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 90 * max(1, textScale))
            }

            HStack(spacing: 2) {
                Button { moveMacroStep(at: index, by: -1) } label: {
                    Image(systemName: "chevron.up")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .disabled(index == 0)
                .hoverHelp("Move step up")
                .accessibilityLabel("Move step \(index + 1) up")

                Button { moveMacroStep(at: index, by: 1) } label: {
                    Image(systemName: "chevron.down")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .disabled(index >= (binding.macroSteps?.count ?? 0) - 1)
                .hoverHelp("Move step down")
                .accessibilityLabel("Move step \(index + 1) down")

                Button { duplicateMacroStep(at: index) } label: {
                    Image(systemName: "plus.square.on.square")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .hoverHelp("Duplicate step")
                .accessibilityLabel("Duplicate step \(index + 1)")
            }
            .foregroundStyle(.secondary)

            Button {
                var steps = binding.macroSteps ?? []
                guard index < steps.count else { return }
                steps.remove(at: index)
                binding.macroSteps = steps.isEmpty ? nil : steps
                AccessibilityNotification.Announcement(String(localized: "Step \(index + 1) removed")).post()
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove step \(index + 1)")

            Spacer()
        }
        HStack(spacing: 4) {
            Spacer().frame(width: 24)
            fieldLabel("Wait")
            TextField("", value: macroDelayBinding(at: index), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 52 * max(1, textScale))
                .controlSize(.small)
                .multilineTextAlignment(.center)
                .accessibilityLabel("Wait before this step, milliseconds")
                .voiceNames("Wait", "Wait before this step, milliseconds")
            fieldLabel("ms before it fires, then hold it for")
            TextField("", value: macroHoldBinding(at: index), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 52 * max(1, textScale))
                .controlSize(.small)
                .multilineTextAlignment(.center)
                .accessibilityLabel("Hold this step, milliseconds")
                .voiceNames("Hold", "Hold this step, milliseconds")
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
        AccessibilityNotification.Announcement(String(localized: "Moved to step \(target + 1)")).post()
    }

    private func duplicateMacroStep(at index: Int) {
        guard var steps = binding.macroSteps, steps.indices.contains(index) else { return }
        let src = steps[index]
        let copy = MacroStep(action: src.action, delayMs: src.delayMs, holdMs: src.holdMs,
                             eventKind: src.eventKind, modifiers: src.modifiers)
        steps.insert(copy, at: index + 1)
        binding.macroSteps = steps
        AccessibilityNotification.Announcement(String(localized: "Step duplicated as step \(index + 2)")).post()
    }

    // MARK: - Macro Bindings

    /// A key step as a shortcut, for its modifier toggles: the step's held
    /// modifiers, then its key.
    private func macroStepShortcutBinding(at index: Int) -> SwiftUI.Binding<[OutputAction]?> {
        SwiftUI.Binding(
            get: {
                guard let steps = binding.macroSteps, steps.indices.contains(index) else { return nil }
                return steps[index].pressedActions
            },
            set: { newValue in
                guard var steps = binding.macroSteps, steps.indices.contains(index), let newValue else { return }
                let held = ShortcutOutputs.held(in: newValue)
                steps[index].modifiers = held.isEmpty ? nil : ShortcutOutputs.modifierOrder.filter { held.contains($0) }
                steps[index].action.keyCode = ShortcutOutputs.key(of: newValue, default: steps[index].action.keyCode ?? 4)
                binding.macroSteps = steps
            }
        )
    }

    private var macroStopOnReleaseBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { binding.macroInterruptOnRelease ?? false },
            set: { binding.macroInterruptOnRelease = $0 ? true : nil }
        )
    }

    /// The step at `index`, or nil once it has been removed. A field
    /// committing while its step is deleted would otherwise trap.
    private func macroStep(at index: Int) -> MacroStep? {
        guard let steps = binding.macroSteps, steps.indices.contains(index) else { return nil }
        return steps[index]
    }

    private func macroStepKindBinding(at index: Int) -> SwiftUI.Binding<MacroStepKind> {
        SwiftUI.Binding(
            get: { macroStep(at: index)?.eventKind ?? .tap },
            set: {
                guard var steps = binding.macroSteps, index < steps.count else { return }
                steps[index].eventKind = ($0 == .tap) ? nil : $0
                binding.macroSteps = steps
            }
        )
    }

    private func macroStepTypeBinding(at index: Int) -> SwiftUI.Binding<OutputType> {
        SwiftUI.Binding(
            get: { macroStep(at: index)?.action.type ?? .key },
            set: {
                guard var steps = binding.macroSteps, index < steps.count else { return }
                steps[index].action.type = $0
                steps[index].action.fillDefaultsForType()
                binding.macroSteps = steps
            }
        )
    }

    private func macroStepKeyBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { macroStep(at: index)?.action.keyCode ?? 4 },
            set: {
                guard var steps = binding.macroSteps, index < steps.count else { return }
                steps[index].action.keyCode = $0
                binding.macroSteps = steps
            }
        )
    }

    private func macroStepMouseBtnBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { macroStep(at: index)?.action.mouseButtonIndex ?? 0 },
            set: {
                guard var steps = binding.macroSteps, index < steps.count else { return }
                steps[index].action.mouseButtonIndex = $0
                binding.macroSteps = steps
            }
        )
    }

    private func macroDelayBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { macroStep(at: index)?.delayMs ?? 50 },
            set: {
                guard var steps = binding.macroSteps, index < steps.count else { return }
                steps[index].delayMs = max(0, min(10000, $0))
                binding.macroSteps = steps
            }
        )
    }

    private func macroHoldBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { macroStep(at: index)?.holdMs ?? 50 },
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
    /// are told apart by color on the touchpad and screen maps, so the
    /// picker and the row show the same dot: matching them by name alone
    /// meant reading every name to find the one you just touched.
    private func regionSwatch(_ colorIndex: Int) -> some View {
        Circle()
            .fill(regionPaletteColor(at: colorIndex))
            .frame(width: 9, height: 9)
            .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 0.5))
    }

    /// One region in a picker: its color, then its name.
    // MARK: - Stick gesture

    private var gestureSteps: [GestureStep] { binding.input.gestureSteps ?? [] }

    /// The flicks as arrows ("↓ ↓"), zones by name.
    private var gestureLabel: String {
        let stick = binding.input.index == 1 ? String(localized: "Right") : String(localized: "Left")
        if gestureSteps.isEmpty { return String(localized: "\(stick): pick flicks") }
        let parts = gestureSteps.map { step -> String in
            if let d = step.direction { return d.arrow }
            if let id = step.zone, let found = StickRegionService.shared.region(with: id) { return found.region.shownName }
            return "?"
        }
        return "\(stick): " + parts.joined(separator: " ")
    }

    static let gestureDirectionOrder: [StickDirection] = [.up, .down, .left, .right, .upLeft, .upRight, .downLeft, .downRight]

    private var stickGesturePicker: some View {
        Menu {
            Picker("Stick", selection: SwiftUI.Binding(
                get: { binding.input.index == 1 ? 1 : 0 },
                set: { stick in
                    if stick != (binding.input.index == 1 ? 1 : 0) {
                        binding.input.gestureSteps = gestureSteps.filter { step in
                            guard let id = step.zone else { return true }
                            return StickRegionService.shared.region(with: id)?.stickIndex == stick
                        }
                    }
                    binding.input.index = stick
                })) {
                Text("Left stick").tag(0)
                Text("Right stick").tag(1)
            }
            .pickerStyle(.inline)
            Section("Add a flick") {
                ForEach(Self.gestureDirectionOrder) { d in
                    Button("\(d.arrow)  \(d.displayName)") { appendGestureStep(GestureStep(direction: d)) }
                }
                let zones = StickRegionService.shared.regions(forStick: binding.input.index == 1 ? 1 : 0)
                if !zones.isEmpty {
                    Menu("Into a region") {
                        ForEach(zones) { zone in
                            Button { appendGestureStep(GestureStep(zone: zone.id)) } label: { regionMenuLabel(zone) }
                        }
                    }
                }
            }
            .disabled(gestureSteps.count >= GestureStep.maxSteps)
            Section {
                Button("Record a gesture\u{2026}") { showGestureRecorder = true }
                Button("Remove the last flick") { binding.input.gestureSteps = Array(gestureSteps.dropLast()) }
                    .disabled(gestureSteps.isEmpty)
                Button("Clear") { binding.input.gestureSteps = [] }
                    .disabled(gestureSteps.isEmpty)
            }
        } label: {
            menuLabel(gestureLabel)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .accessibilityLabel("Stick gesture")
        .accessibilityValue(binding.input.displayName)
        .help("The flicks that make up this gesture, in order")
        .sheet(isPresented: $showGestureRecorder) { gestureRecorderSheet }
    }

    /// The recorder, with the row's own stick, timing and Invert.
    private var gestureRecorderSheet: some View {
        StickGestureRecorder(stick: binding.input.index == 1 ? 1 : 0, slot: slot,
                             reach: binding.gestureReach ?? 0.8,
                             longestFlickMs: binding.gestureFlickMs ?? 400,
                             windowMs: binding.gestureWindowMs ?? 600,
                             inverted: binding.invertAxis == true) { steps in
            binding.input.gestureSteps = steps
        }
        .glassBackground()
    }

    private func appendGestureStep(_ step: GestureStep) {
        guard gestureSteps.count < GestureStep.maxSteps else { return }
        binding.input.gestureSteps = gestureSteps + [step]
    }

    @ViewBuilder
    private var stickGestureOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("A flick goes out past the reach and comes back to the middle. Each flick must start within the time between flicks of the last one ending.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text("Reach")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ThrottledSlider("Reach", value: SwiftUI.Binding(
                    get: { binding.gestureReach ?? 0.8 },
                    set: { binding.gestureReach = abs($0 - 0.8) < 0.005 ? nil : $0 }),
                    in: 0.3...1.0, step: 0.05)
                    .frame(minWidth: 120, maxWidth: 200)
                Text((binding.gestureReach ?? 0.8).formatted(.percent.precision(.fractionLength(0))))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 40, alignment: .leading)
            }
            HStack(spacing: 6) {
                Text("Time between flicks")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("Time between flicks in milliseconds", value: SwiftUI.Binding(
                    get: { binding.gestureWindowMs ?? 600 },
                    set: { binding.gestureWindowMs = Self.clamped($0, 150...3000) }), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60 * max(1, textScale))
                    .accessibilityHint("150 to 3000 milliseconds")
                Text("ms").font(.callout).foregroundStyle(.secondary)
            }
            Toggle(isOn: SwiftUI.Binding(
                get: { (binding.gestureFlickMs ?? 400) > 0 },
                set: { binding.gestureFlickMs = $0 ? nil : 0 })) {
                Text("Quick flicks only")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .hoverHelp("A push held out longer than this is a push, not a flick, and starts the gesture over, so steering or pointing with the stick never counts.")
            if (binding.gestureFlickMs ?? 400) > 0 {
                HStack(spacing: 6) {
                    Text("Longest flick")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    TextField("Longest flick in milliseconds", value: SwiftUI.Binding(
                        get: { binding.gestureFlickMs ?? 400 },
                        set: { binding.gestureFlickMs = Self.clamped($0, 50...3000) }), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60 * max(1, textScale))
                        .accessibilityHint("50 to 3000 milliseconds")
                    Text("ms").font(.callout).foregroundStyle(.secondary)
                }
            }
            if gestureSteps.contains(where: { $0.direction == .down }) {
                Text("One-Stick Driving shifts into reverse on two snaps back. If this preset drives with the same stick, turn that off in its driving settings or use another gesture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle(isOn: invertBinding) {
                Text("Invert direction")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .help(invertExplanation)
        }
    }

    private func regionMenuLabel(_ region: TouchpadRegion) -> some View {
        HStack(spacing: 6) {
            regionSwatch(region.colorIndex)
            Text(region.shownName)
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
    private func systemActionControls(at index: Int, in list: OutputList = .main) -> some View {
        let kind = output(at: index, in: list)?.systemActionKind ?? .playPause
        switch kind {
        case .runShortcut:
            HStack(spacing: 6) {
                TextField("Shortcut name", text: outputTextBinding(at: index, in: list))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(minWidth: 140)
                SystemListChooser(list: .shortcuts) { name in updateOutput(index, in: list) { $0.text = name } }
                    .accessibilityLabel("Choose a Shortcut")
                    .hoverHelp("Pick one of your installed Shortcuts.")
            }
        case .openApp:
            HStack(spacing: 6) {
                TextField("App name or full path", text: outputTextBinding(at: index, in: list))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(minWidth: 160)
                    .hoverHelp("An app name like Safari, a bundle identifier, or a full .app path.")
                SystemListChooser(list: .apps) { name in updateOutput(index, in: list) { $0.text = name } }
                    .accessibilityLabel("Choose an app")
                    .hoverHelp("Pick one of your installed applications.")
            }
        case .openURL:
            TextField("https:// or any URL scheme", text: outputTextBinding(at: index, in: list))
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
                // Whole on hover, since a large Text Size cuts off the shortcut.
                .help(systemActionExplainer(kind))
        }
    }

    private func systemActionExplainer(_ kind: SystemActionKind) -> String {
        switch kind {
        case .volumeUp, .volumeDown: return String(localized: "Nudges the Mac's volume one step per press")
        case .muteToggle: return String(localized: "Toggles the Mac's output mute")
        case .playPause, .nextTrack, .previousTrack: return String(localized: "Sends the keyboard's media key")
        case .brightnessUp, .brightnessDown: return String(localized: "Nudges the built-in display's brightness")
        case .missionControl: return String(localized: "Opens Mission Control")
        case .launchpad: return String(localized: "Opens Launchpad")
        case .spotlight: return String(localized: "Presses Cmd+Space")
        case .lockScreen: return String(localized: "Locks the screen (Ctrl+Cmd+Q)")
        case .screenshotMenu: return String(localized: "Opens the screenshot toolbar (Cmd+Shift+5)")
        case .keyboardBrightnessUp, .keyboardBrightnessDown:
            return String(localized: "Nudges the keyboard backlight")
        case .startDictation:
            return String(localized: "Presses the dictation key, same as F5")
        case .speakSelection: return String(localized: "Speaks the selected text (Option+Esc)")
        case .zoomToggle: return String(localized: "Turns screen zoom on and off (Option+Cmd+8)")
        case .zoomIn: return String(localized: "Zooms the screen in (Option+Cmd+=)")
        case .zoomOut: return String(localized: "Zooms the screen out (Option+Cmd+-)")
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
        case .lightBar: return action.resolvedLightMode == .rainbowToggle ? "rainbow" : "light.beacon.max.fill"
        case .controllerProfile: return "person.crop.rectangle.stack"
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
        case .lightBar, .controllerProfile: return .pink
        case .mouseButton, .mouseMotion, .mouseWheel, .mouseWheelStep: return .purple
        case .midiNote, .midiCC, .midiPitchBend, .midiProgramChange, .midiTransport: return .pink
        }
    }

    private func mouseButtonName(_ index: Int) -> String {
        switch index {
        case 0: return String(localized: "0: Main Click")
        case 1: return String(localized: "1: Secondary")
        case 2: return String(localized: "2: Middle")
        case 3: return String(localized: "3: Back")
        case 4: return String(localized: "4: Forward")
        case 5: return String(localized: "5: Extra")
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
            set: {
                guard !binding.outputs.isEmpty else { return }
                binding.outputs[0].type = $0
                binding.outputs[0].fillDefaultsForType()
            }
        )
    }

    // MARK: - Output lists

    /// Which of the row's output lists an output editor works on: the main
    /// action, or the extra action sent instead on a hold or a double tap.
    /// Every output control below takes one, so an extra action gets the
    /// same editor as the main action rather than a reduced copy of it.
    enum OutputList: Int { case main, hold, doubleTap, tripleTap }

    private func outputs(in list: OutputList) -> [OutputAction] {
        switch list {
        case .main: return binding.outputs
        case .hold: return binding.holdOutputs ?? []
        case .doubleTap: return binding.doubleTapOutputs ?? []
        case .tripleTap: return binding.tripleTapOutputs ?? []
        }
    }

    /// Writes a list back. nil is an extra action's off switch, so an edit
    /// that lands after its toggle was turned off (a field committing on
    /// blur, a click point taken after the countdown) leaves it off.
    private func setOutputs(_ value: [OutputAction], in list: OutputList) {
        switch list {
        case .main: binding.outputs = value
        case .hold: if binding.holdOutputs != nil { binding.holdOutputs = value }
        case .doubleTap: if binding.doubleTapOutputs != nil { binding.doubleTapOutputs = value }
        case .tripleTap: if binding.tripleTapOutputs != nil { binding.tripleTapOutputs = value }
        }
    }

    /// The live speed mirror's key: the main list keeps the bare index, and
    /// each extra list its own range, so two lists never share a readout.
    private func liveSpeedKey(_ index: Int, _ list: OutputList) -> Int {
        list.rawValue * 1000 + index
    }

    /// The output at `index`, or nil once it has been removed. A field that
    /// commits while its output is deleted would otherwise trap past the
    /// end, or write into the output that moved into that place.
    private func output(at index: Int, in list: OutputList = .main) -> OutputAction? {
        let all = outputs(in: list)
        return all.indices.contains(index) ? all[index] : nil
    }
    /// Changes the output at `index` if it is still there.
    private func updateOutput(_ index: Int, in list: OutputList = .main, _ change: (inout OutputAction) -> Void) {
        var all = outputs(in: list)
        guard all.indices.contains(index) else { return }
        change(&all[index])
        setOutputs(all, in: list)
    }

    private func outputBinding(at index: Int, in list: OutputList = .main) -> SwiftUI.Binding<OutputAction> {
        let fallback = output(at: index, in: list) ?? OutputAction(type: .key, keyCode: 4)
        return SwiftUI.Binding(
            get: { output(at: index, in: list) ?? fallback },
            set: { value in updateOutput(index, in: list) { $0 = value } }
        )
    }

    private func outputTypeBinding(at index: Int, in list: OutputList = .main) -> SwiftUI.Binding<OutputType> {
        SwiftUI.Binding(
            get: { output(at: index, in: list)?.type ?? .key },
            set: { value in
                updateOutput(index, in: list) {
                    $0.type = value
                    $0.fillDefaultsForType()
                }
            }
        )
    }

    private func keyCodeBinding(at index: Int, in list: OutputList = .main) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { output(at: index, in: list)?.keyCode ?? 4 },
            set: { value in updateOutput(index, in: list) { $0.keyCode = value } }
        )
    }

    private func mouseAxisDirBinding(at index: Int, in list: OutputList = .main) -> SwiftUI.Binding<String> {
        SwiftUI.Binding(
            get: {
                let axis = output(at: index, in: list)?.mouseAxis?.rawValue ?? 1
                let dir = output(at: index, in: list)?.mouseDirection?.rawValue ?? "-"
                return "\(axis) \(dir)"
            },
            set: { newValue in
                let parts = newValue.split(separator: " ")
                if parts.count >= 2,
                   let axisVal = Int(parts[0]),
                   let axis = MouseAxis(rawValue: axisVal) {
                    updateOutput(index, in: list) {
                        $0.mouseAxis = axis
                        $0.mouseDirection = MouseDirection(rawValue: String(parts[1]))
                    }
                }
            }
        )
    }

    private func speedBinding(at index: Int, in list: OutputList = .main) -> SwiftUI.Binding<Double> {
        SwiftUI.Binding(
            get: { Double(output(at: index, in: list)?.speed ?? 6) },
            set: { value in updateOutput(index, in: list) { $0.speed = Int(value) } }
        )
    }

    /// TextField binding that reads from the live drag mirror so the box
    /// updates while the user is sliding, and writes go to both the mirror
    /// and the underlying preset (so typing into the field still works).
    private func liveSpeedBinding(at index: Int, in list: OutputList = .main) -> SwiftUI.Binding<Int> {
        let key = liveSpeedKey(index, list)
        return SwiftUI.Binding(
            get: {
                if let live = liveSpeed[key] { return Int(live) }
                return output(at: index, in: list)?.speed ?? 6
            },
            set: { newValue in
                guard output(at: index, in: list) != nil else { return }
                let clamped = max(1, min(50, newValue))
                updateOutput(index, in: list) { $0.speed = clamped }
                liveSpeed[key] = Double(clamped)
            }
        )
    }

    // MARK: - MIDI Bindings

    private func midiVelocityBinding(at index: Int, in list: OutputList = .main) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { output(at: index, in: list)?.midiVelocity ?? 100 },
            set: { value in updateOutput(index, in: list) { $0.midiVelocity = max(0, min(127, value)) } }
        )
    }

    private func midiChannelBinding(at index: Int, in list: OutputList = .main) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { output(at: index, in: list)?.midiChannel ?? 1 },
            set: { value in updateOutput(index, in: list) { $0.midiChannel = max(1, min(16, value)) } }
        )
    }

    private func midiTransportBinding(at index: Int, in list: OutputList = .main) -> SwiftUI.Binding<MIDITransport> {
        SwiftUI.Binding(
            get: { output(at: index, in: list)?.midiTransport ?? .start },
            set: { value in updateOutput(index, in: list) { $0.midiTransport = value } }
        )
    }

    private func removeOutput(at index: Int, in list: OutputList = .main) {
        var all = outputs(in: list)
        guard all.indices.contains(index) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            all.remove(at: index)
            setOutputs(all, in: list)
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
    func hoverHelp(_ text: LocalizedStringKey) -> some View {
        help(text)
    }

    /// Hides the focus ring macOS draws on a control that only took focus
    /// because a sheet opened, but keeps it for anyone who turned on
    /// Keyboard navigation, since that ring is the only way they see where
    /// they are.
    func focusRingForKeyboardUsers() -> some View {
        modifier(KeyboardFocusRing())
    }
}

/// Follows the Keyboard navigation setting as it changes: it was read only
/// when a view happened to redraw, so turning it on left rings off.
private struct KeyboardFocusRing: ViewModifier {
    @ObservedObject private var access = KeyboardNavigationSetting.shared
    func body(content: Content) -> some View {
        content.focusEffectDisabled(!access.enabled)
    }
}

/// Whether Keyboard navigation (Full Keyboard Access) is on, re-read when
/// the app comes to the front, which is when the setting can have changed.
@MainActor
final class KeyboardNavigationSetting: ObservableObject {
    static let shared = KeyboardNavigationSetting()
    @Published private(set) var enabled = NSApplication.shared.isFullKeyboardAccessEnabled
    private var observer: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?
    /// Control-F7 changes the setting with the app in front, which no
    /// activation reports, so it is also read every 2 seconds while active.
    private var timer: Timer?
    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.timer?.invalidate()
                let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
                t.tolerance = 0.5
                RunLoop.main.add(t, forMode: .common)
                self?.timer = t
            }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.timer?.invalidate()
                self?.timer = nil
            }
        }
    }

    private func refresh() {
        let now = NSApplication.shared.isFullKeyboardAccessEnabled
        if enabled != now { enabled = now }
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
/// centered bar with the deadzone shaded on it, lit green when the row would
/// fire, plus Quick Zero and the full calibration sheet. Owns its own 30 Hz
/// read of the controller state so the row itself stays static.
struct MotionRowPanel: View {
    let slot: Int
    let channel: MotionChannel
    let direction: AxisDirection?
    let invert: Bool
    let deadzone: Double
    /// A tilt row measured from the grip: the meter shows the lean from the
    /// angle first read, taken again at a re-zero, as the engine does.
    var fromNeutral: Bool = false
    /// A pointer row moves on anything past the sensor's noise; its
    /// deadzone only slows or smooths small movement, it cuts nothing off.
    var drivesPointer: Bool = false

    @EnvironmentObject private var controllerService: GameControllerService
    @State private var value: Float = 0
    @State private var neutral: Float?
    @State private var hasMotion = false
    @State private var showCalibration = false
    @State private var zeroFlashUntil: Date?
    /// One timer for the panel's life, not a new one per redraw.
    private let tick = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()
    /// The last Quick Zero found the pad moving, so nothing was stored.
    @State private var zeroMoved = false
    @State private var zeroUnavailable = false

    /// Full-scale of the bar per channel: gyro rates in rad/s, the rest
    /// already normalized to about -1...1.
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

    /// The reading as VoiceOver says it: the unit as words, and the sign
    /// as plus or minus, which a voice drops when written.
    private var spokenReading: String {
        let number = abs(value).formatted(.number.precision(.fractionLength(2)))
        let signed = value < 0 ? String(localized: "minus \(number)") : number
        switch channel {
        case .gyroX, .gyroY, .gyroZ: return signed + String(localized: " radians per second")
        case .accelX, .accelY, .accelZ: return String(localized: "\(signed) g-force")
        default: return signed
        }
    }

    /// The engine's own check for a switch-style motion row.
    private var firing: Bool {
        if drivesPointer { return abs(value) >= 0.005 }
        return MappingEngine.motionFires(value: value, direction: direction, invert: invert, deadzone: Float(deadzone))
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
                Text(hasMotion ? String(format: "%+.2f %@", locale: .current, value, unit) : String(localized: "no motion"))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(firing ? Color.green : Color.secondary)
                    .frame(minWidth: 96, alignment: .leading)
                    .fixedSize()
            }
            // The green bar and readout in words: whether a tilt passes the deadzone.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(channel.menuDescription)
            .accessibilityValue(hasMotion
                ? String(localized: "\(spokenReading), \(firing ? String(localized: "fires") : String(localized: "inside the deadzone"))")
                : String(localized: "no motion"))
            Text(hasMotion
                 ? String(localized: "Move the controller the way this row should fire. The bar turns green when it would; the gray band is the deadzone.")
                 : String(localized: "Connect a controller with motion (a DualSense, DualShock 4, Switch Pro Controller, Joy-Con or Steam Controller) to see it move."))
                .font(.callout)
                .foregroundStyle(.hint)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    // A moving pad is only re-anchored and stores no zero, so
                    // it is not reported as zeroed.
                    let ok = controllerService.rezeroMotion(slot: slot)
                    if ok, controllerService.lastRezeroStoredZero {
                        zeroMoved = false
                        zeroUnavailable = false
                        zeroFlashUntil = Date().addingTimeInterval(2)
                        AccessibilityNotification.Announcement(String(localized: "Zeroed")).post()
                    } else if ok {
                        zeroMoved = true
                        zeroUnavailable = false
                        zeroFlashUntil = nil
                        AccessibilityNotification.Announcement(String(localized: "Moving, hold it still and try again")).post()
                    } else {
                        // A pad it cannot zero (no gyro, or read directly):
                        // not "moving", which no amount of holding still fixes.
                        zeroMoved = false
                        zeroUnavailable = true
                        zeroFlashUntil = nil
                        AccessibilityNotification.Announcement(String(localized: "Quick Zero is not available for this controller; it zeroes itself when it rests")).post()
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "scope").font(.callout).accessibilityHidden(true)
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
                        Image(systemName: "gyroscope").font(.callout).accessibilityHidden(true)
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
                } else if zeroMoved {
                    Text("Moving, hold it still and try again")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if zeroUnavailable {
                    Text("Quick Zero is not available for this controller; it zeroes itself when it rests")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: GameControllerService.motionRezeroedNotification)) { _ in
            neutral = nil
        }
        .onChange(of: channel) { _, _ in neutral = nil }
        .onChange(of: fromNeutral) { _, _ in neutral = nil }
        .onReceive(tick) { _ in
            // Written only when they change: rewriting them 30 times a second
            // redrew the panel even with no controller.
            let motion = controllerService.currentStates[slot]?.motion
            let has = !(motion?.isEmpty ?? true)
            if has != hasMotion { hasMotion = has }
            var v = motion?[channel] ?? 0
            if fromNeutral, [.pitchAngle, .rollAngle, .yawAngle].contains(channel), motion?[channel] != nil {
                // The running preset's level when it has one, so the meter
                // and the row agree; else the angle this meter first read.
                if let engineLevel = MappingEngine.current?.angleNeutral(readSlot: slot, channel: channel) {
                    neutral = engineLevel
                } else if neutral == nil {
                    neutral = v
                }
                v -= neutral ?? v
                if channel == .yawAngle { v = MappingEngine.wrapHalfTurn(v) }
            }
            if v != value { value = v }
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
                // Deadzone band, centered.
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
    let adjustLive: () -> Void
    func body(content: Content) -> some View {
        #if DEBUG
        content.onReceive(DistributedNotificationCenter.default().publisher(
            for: Notification.Name("inputconfig.debug.toggleoptions"))) { note in
            if let n = Int(note.object as? String ?? ""), n == displayNumber { toggle() }
        }
        // `post inputconfig.debug.adjustlive <row number>` opens that row's
        // Adjust live sheet.
        .onReceive(DistributedNotificationCenter.default().publisher(
            for: Notification.Name("inputconfig.debug.adjustlive"))) { note in
            if let n = Int(note.object as? String ?? ""), n == displayNumber { adjustLive() }
        }
        // `post inputconfig.debug.scrollrow <row number>` scrolls the editor
        // so that row sits at the top of the sheet, for article captures.
        .background(DebugScrollRowAnchor(displayNumber: displayNumber))
        #else
        content
        #endif
    }
}

#if DEBUG
struct DebugScrollRowAnchor: NSViewRepresentable {
    let displayNumber: Int
    final class Coordinator: NSObject {
        weak var view: NSView?
        var number = 0
        var token: NSObjectProtocol?
        deinit { if let token { DistributedNotificationCenter.default().removeObserver(token) } }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        let c = context.coordinator
        c.view = v
        c.number = displayNumber
        c.token = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("inputconfig.debug.scrollrow"), object: nil, queue: .main) { [weak c] note in
            guard let c, let v = c.view, Int(note.object as? String ?? "") == c.number,
                  let scroll = v.enclosingScrollView, let doc = scroll.documentView else { return }
            let rect = v.convert(v.bounds, to: doc)
            let y = doc.isFlipped ? rect.minY - 64 : rect.maxY - scroll.contentView.bounds.height + 64   // clear of the title bar the list scrolls under
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.number = displayNumber }
}
#endif


/// Scrolls the editor so the view it sits behind is in sight, once, when
/// `active` turns true, then reports back so the request is spent. The row
/// menu's Extra actions shortcuts open Options on a group that can sit below
/// the window's edge, and the editor's ScrollViewReader lives in its parent,
/// so this asks the enclosing AppKit scroll view instead.
struct ScrollIntoViewAnchor: NSViewRepresentable {
    let active: Bool
    let onDone: () -> Void

    final class Coordinator { var pending = false }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard active, !context.coordinator.pending else { return }
        let coordinator = context.coordinator
        coordinator.pending = true
        let done = onDone
        // After the Options fold has laid out, so the frame is the final one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak nsView] in
            coordinator.pending = false
            if let nsView, nsView.window != nil {
                nsView.scrollToVisible(nsView.bounds)
            }
            done()
        }
    }
}

/// One glow over an Options box: it lights in the accent color, a sheen
/// sweeps across it left to right (left out with Reduce Motion), and it
/// fades, so a box a menu choice just turned on is easy to find.
private struct OptionsSpotlight: View {
    let sweeps: Bool
    let done: () -> Void
    @State private var lit = false
    @State private var sweep: CGFloat = -0.4

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        ZStack {
            shape.fill(Color.accentColor.opacity(0.14))
            if sweeps {
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, Color.accentColor.opacity(0.4), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.35)
                        .offset(x: geo.size.width * sweep)
                }
                .clipShape(shape)
            }
            shape.strokeBorder(Color.accentColor, lineWidth: 2)
        }
        .opacity(lit ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(.easeOut(duration: 0.25)) { lit = true }
            if sweeps { withAnimation(.easeInOut(duration: 0.9)) { sweep = 1.05 } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                withAnimation(.easeIn(duration: 0.8)) { lit = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { done() }
            }
        }
    }
}

/// Scrolls a row into view when the Regions section's Back button asks.
private struct RevealRowOnRequest: ViewModifier {
    let rowID: UUID
    @State private var reveal = false

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: BindingRowView.revealRow)) { note in
                if let id = note.object as? UUID, id == rowID { reveal = true }
            }
            .background(ScrollIntoViewAnchor(active: reveal) { reveal = false })
    }
}

/// Shows the touchpad regions from a touchpad row's Options.
private struct TouchpadRegionsButton: View {
    /// Shows the group's Regions section on the touchpad.
    let open: () -> Void
    var body: some View {
        Button {
            open()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "rectangle.and.hand.point.up.left.fill").font(.callout).accessibilityHidden(true)
                Text("Edit touchpad regions").font(.callout)
            }
            .foregroundStyle(.tint)
        }
        .buttonStyle(.solidSecondaryCompact)
        .fixedSize()
        .help("Draw and name this preset's touchpad regions")
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
                Image(systemName: "hand.tap").font(.callout).accessibilityHidden(true)
                Text("Calibrate Taps").font(.callout)
            }
            .foregroundStyle(.tint)
        }
        .buttonStyle(.solidSecondaryCompact)
        .fixedSize()
        .help("Watch taps on the MacBook live and set the strength that counts as a tap")
        .sheet(isPresented: $showing) {
            TapCalibrationView()
                .glassBackground(windowTint: 0.3)   // as translucent as the main window
        }
    }
}

// MARK: - Shortcut modifiers

/// A macro step's shortcut stored as outputs: the modifiers held with it
/// first (left-hand key codes), then the key, the same order every chord in
/// a preset uses, so Command Z is [Left Command, Z].
enum ShortcutOutputs {
    /// Control, Option, Shift, Command: the order a shortcut is spelled in.
    static let modifierOrder = [224, 226, 225, 227]

    static func isModifier(_ code: Int) -> Bool { (224...231).contains(code) }

    /// Right-hand modifiers count as the left-hand ones for the toggles.
    static func leftHand(_ code: Int) -> Int { (228...231).contains(code) ? code - 4 : code }

    /// The shortcut's key: its last key that is not a modifier, or, for a
    /// lone modifier (the default hold, Shift), that modifier.
    static func key(of outputs: [OutputAction]?, default fallback: Int) -> Int {
        let keys = (outputs ?? []).filter { $0.type == .key }.compactMap(\.keyCode)
        return keys.last(where: { !isModifier($0) }) ?? keys.last ?? fallback
    }

    /// The modifiers held with the key.
    static func held(in outputs: [OutputAction]?) -> Set<Int> {
        let keys = (outputs ?? []).filter { $0.type == .key }.compactMap(\.keyCode)
        let k = key(of: outputs, default: -1)
        return Set(keys.filter { isModifier($0) && $0 != k }.map(leftHand))
    }

    static func build(key: Int, held: Set<Int>) -> [OutputAction] {
        modifierOrder.filter { held.contains($0) && $0 != leftHand(key) }
            .map { OutputAction(type: .key, keyCode: $0) }
            + [OutputAction(type: .key, keyCode: key)]
    }
}

/// Control, Option, Shift and Command toggles beside a single-key picker, so
/// a macro step can press a shortcut such as Command Z.
private struct ShortcutModifierToggles: View {
    @SwiftUI.Binding var outputs: [OutputAction]?
    let defaultKey: Int

    private struct Item: Identifiable {
        let code: Int
        let symbol: String
        let name: String
        var id: Int { code }
    }

    private static let items = [
        Item(code: 224, symbol: "\u{2303}", name: String(localized: "Control")),
        Item(code: 226, symbol: "\u{2325}", name: String(localized: "Option")),
        Item(code: 225, symbol: "\u{21E7}", name: String(localized: "Shift")),
        Item(code: 227, symbol: "\u{2318}", name: String(localized: "Command")),
    ]

    var body: some View {
        let key = ShortcutOutputs.key(of: outputs, default: defaultKey)
        let held = ShortcutOutputs.held(in: outputs)
        HStack(spacing: 2) {
            ForEach(Self.items) { item in
                Toggle(isOn: SwiftUI.Binding(
                    get: { held.contains(item.code) },
                    set: { on in
                        var next = held
                        if on { next.insert(item.code) } else { next.remove(item.code) }
                        outputs = ShortcutOutputs.build(key: key, held: next)
                    }
                )) {
                    Text(item.symbol).frame(minWidth: 14)
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .disabled(ShortcutOutputs.leftHand(key) == item.code)
                .accessibilityLabel(item.name)
                .hoverHelp("Hold \(item.name) with this key, for a shortcut like Command Z")
            }
        }
        .fixedSize()
    }
}

/// The controller family of the preset being edited (see Preset.buttonFamily),
/// handed down by the editor so every row names the face buttons that way.
private struct PresetButtonFamilyKey: EnvironmentKey {
    static let defaultValue: FaceLetters? = nil
}
/// Where the slot's pad differs from its family's names (a DualShock 4's
/// Share), handed down with the family.
private struct ButtonModelNamesKey: EnvironmentKey {
    static let defaultValue: ButtonNames.ModelNames = .none
}
/// The button names of a pad read from its descriptor alone, by number,
/// when the slot's device is one; nil for every pad numbered like a gamepad.
private struct DeviceButtonNamesKey: EnvironmentKey {
    static let defaultValue: [String]? = nil
}
extension EnvironmentValues {
    var presetButtonFamily: FaceLetters? {
        get { self[PresetButtonFamilyKey.self] }
        set { self[PresetButtonFamilyKey.self] = newValue }
    }
    var buttonModelNames: ButtonNames.ModelNames {
        get { self[ButtonModelNamesKey.self] }
        set { self[ButtonModelNamesKey.self] = newValue }
    }
    var deviceButtonNames: [String]? {
        get { self[DeviceButtonNamesKey.self] }
        set { self[DeviceButtonNamesKey.self] = newValue }
    }
}

/// The chooser beside a Run Shortcut or Open App output: your Shortcuts or
/// applications, already loaded by SystemListsCache. Its own view, so only
/// rows that show one observe the lists.
private struct SystemListChooser: View {
    enum List { case shortcuts, apps }
    let list: List
    let pick: (String) -> Void
    @ObservedObject private var lists = SystemListsCache.shared

    var body: some View {
        SearchableMenu(choices: {
            (list == .shortcuts ? lists.shortcuts : lists.apps).map { name in
                MenuSearchChoice(title: name) { pick(name) }
            }
        }) {
            let names = list == .shortcuts ? lists.shortcuts : lists.apps
            if names.isEmpty {
                Text(list == .shortcuts ? String(localized: "No Shortcuts found") : String(localized: "No applications found"))
            } else {
                ForEach(names, id: \.self) { name in
                    Button(name) { pick(name) }
                }
            }
        } label: {
            Image(systemName: "chevron.up.chevron.down")
                .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
