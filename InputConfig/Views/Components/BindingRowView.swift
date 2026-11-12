import SwiftUI
import Combine
import UniformTypeIdentifiers

/// A single binding row with fixed-width columns for consistent alignment.
struct BindingRowView: View {
    /// Key names follow the input source; a change to it redraws the row.
    @ObservedObject private var keyboardLayout = KeyboardLayoutService.shared
    /// The preset's controller family, set by the editor; names the face buttons.
    @Environment(\.presetButtonFamily) var presetButtonFamily
    @Environment(\.presetScrollMultiplier) var presetScrollMultiplier
    @Environment(\.buttonModelNames) var buttonModelNames
    @Environment(\.deviceButtonNames) var deviceButtonNames
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
    var reduceMotion: Bool { systemReduceMotion || appReduceMotion }
    @Environment(\.accessibilityDifferentiateWithoutColor) var differentiateWithoutColor

    /// True while this row's Mac key or mouse button Scan listens.
    @State var externalScanning = false
    /// Seconds left on that scan, shown on the row so the limit is seen,
    /// not only spoken; and a short visible note when it ran out.
    @State var externalScanLeft = 0
    @State var externalScanTimedOut = false
    /// Seconds until a fixed click point is taken, shown on its menu.
    @State var clickPointLeft: Int?
    /// Which output the countdown is for, so only its menu shows it.
    @State var clickPointTarget: String?
    /// The countdown now running; an older one's blocks see a new token and stop.
    @State var clickPointToken: UUID?
    @State var showAdvanced = false
    @State var showMacroEditor = false
    @State var liveOuterDeadzone: Double?
    @State var showDeadzoneCalibration = false
    /// Region editors opened straight from the input pickers, so defining a
    /// missing cursor/stick region doesn't require a detour through Settings.
    @State var showGestureRecorder = false
    @State var showMacroRecorder = false
    @State var macroPointCountdown = 0
    /// The Use the pointer count, kept so a second click can cancel it.
    @State var macroPointTask: Task<Void, Never>?
    /// Play once: three seconds to switch to the other app, then the steps.
    @State var macroPlayCountdown = 0
    /// The Play once count and playback watch, kept so a second click,
    /// Escape, the emergency stop or the editor closing can cancel it.
    /// Unowned, the count ran on after Cancel and typed into the front app.
    @State var macroPlayTask: Task<Void, Never>?
    /// Escape during the Play once count or playback stops it, whatever
    /// control has focus in the sheet.
    @State var macroPlayEscapeMonitor: Any?
    /// Set by the Stop click, so the end is announced as stopped, not finished.
    @State var macroStopRequested = false
    /// True while the editor's Play once chain runs (polled: the engine's
    /// in-flight set is not published).
    @State var macroPlaying = false
    /// Steps as a list, or as plain text lines: one choice for every row.
    @AppStorage("macroShowsText") var macroShowsText = false
    /// The Text pane's lines and what they parse to, kept by the row so
    /// they outlive the pane (a trip to the List view, a paste or an import
    /// from there, a Save with lines unapplied), in an object the row does
    /// not observe: as ten @State values here, every keystroke in the pane
    /// re-ran this whole row's body. MacroTextPaneView observes it.
    @State var macroPane = MacroTextPaneState()
    // The pane's state by its old names, so the logic below reads and
    // writes it unchanged.
    var macroText: String {
        get { macroPane.text } nonmutating set { macroPane.text = newValue }
    }
    var macroTextResult: MacroTextResult? {
        get { macroPane.result } nonmutating set { macroPane.result = newValue }
    }
    var macroTextWritten: String {
        get { macroPane.written } nonmutating set { macroPane.written = newValue }
    }
    var macroTextOpenerArmed: Bool {
        get { macroPane.openerArmed } nonmutating set { macroPane.openerArmed = newValue }
    }
    var macroTextBaseSteps: [MacroStep]? {
        get { macroPane.baseSteps } nonmutating set { macroPane.baseSteps = newValue }
    }
    var macroTextStaleArmed: Bool {
        get { macroPane.staleArmed } nonmutating set { macroPane.staleArmed = newValue }
    }
    var macroTextNote: (text: String, message: String)? {
        get { macroPane.note } nonmutating set { macroPane.note = newValue }
    }
    var macroTextJustShown: Bool {
        get { macroPane.justShown } nonmutating set { macroPane.justShown = newValue }
    }
    var macroTextParseTask: Task<Void, Never>? {
        get { macroPane.parseTask } nonmutating set { macroPane.parseTask = newValue }
    }
    @State var showSequenceRecorder = false
    @State var showKeySequenceRecorder = false
    /// The axis and direction a row read before a zone was picked for it,
    /// so "Whole stick or trigger, no zone" puts back exactly that.
    @State var axisBeforeZone: (index: Int, direction: AxisDirection?, invert: Bool?)?
    /// Drives the firing arrow's left-to-right sweep while highlighted.
    @State var arrowShoot = false
    /// The Options box a menu choice just turned on ("feedback", "macro",
    /// "extra"): once Options has opened, the editor scrolls it into view
    /// and it glows once in the accent color, so the eye finds it.
    static let revealRow = Notification.Name("InputConfig.RevealRow")
    @State var spotlightBox: String?
    @State var spotlightGlow: String?

    /// Live mirrors of slider values, updated every drag tick so the value
    /// shown next to each slider follows the thumb in real time. The
    /// underlying BindingModel still only commits on slider release to keep
    /// the editor's re-render chain off the per-frame hot path.
    @State var liveSpeed: [Int: Double] = [:]
    @State var liveHaptic: Double?
    @State var liveHapticDuration: Double?
    @State var liveDeadzone: Double?

    // Fixed column widths for perfect alignment
    let dragWidth: CGFloat = 20
    /// Grows with Text Size, like the other columns, so "#12" and "Notes" fit.
    var numberColWidth: CGFloat { Self.numberColWidth(scale: textScale) }
    static func numberColWidth(scale: CGFloat) -> CGFloat { 40 * max(1, scale) }
    /// Where sub-rows (note, Options) start: under the Scan column, past the
    /// handle and the number, so every line of the row shares one left edge.
    /// Where the Options boxes start: just inside the row, so the left box
    /// uses the width under the drag handle and row number too.
    var optionsInset: CGFloat { 10 }
    private var leftGutter: CGFloat {
        dragWidth + colGap + (displayNumber > 0 ? numberColWidth + colGap : 0)
    }
    @Environment(\.appTextScale) var textScale
    /// Column widths grow with Text Size, so the labels in them do not
    /// clip at Extra Large and Huge.
    var scanColWidth: CGFloat { 54 * max(1, textScale) }
    /// Wider than before (was 78) so the full input-type names like
    /// "Keyboard Key", "Cursor Region", "Stick Region" actually show
    /// in the picker label instead of getting truncated to "Keyboa…"
    /// which made the picker look locked.
    var typeColWidth: CGFloat { 116 * max(1, textScale) }
    var indexColWidth: CGFloat { 124 * max(1, textScale) }
    /// Wider than before (was 58) because for extKey / extMouse this
    /// column hosts the device picker, and device names like
    /// "Built-in Keyboard" overflowed and visually collided with the
    /// next column's keyboard icon.
    var dirColWidth: CGFloat { 130 * max(1, textScale) }
    let arrowWidth: CGFloat = 24
    /// Wide enough for "Mission Control" and "Speak Selection" next to their
    /// icon without truncating to "Mission Cont…".
    var outTypeColWidth: CGFloat { 156 * max(1, textScale) }
    /// The one horizontal gap used everywhere on the primary row: between
    /// the boxes and the arrow, between controls inside a box, and between
    /// an output's icon and its menu. Consistent spacing is what makes the
    /// two halves read as the same kind of thing.
    let gap: CGFloat = 8
    /// Every output icon sits in a cell this wide, scaled to fit, so a wide
    /// symbol (Mission Control) and a narrow one (a lock) leave the same
    /// distance to the menu after them.
    let iconCell: CGFloat = 18
    let actionsWidth: CGFloat = 28
    let colGap: CGFloat = 8

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

    @AccessibilityFocusState private var jumpFocus: Bool
    /// Keyboard focus on the row's Scan button, for the same jumps.
    @FocusState var keyboardFocus: Bool
    /// A subtle inline "what this does" field shown under each binding. It is
    /// always present (so any row can get a note) but stays visually quiet when
    /// empty. Smart presets pre-fill it from the profile so people can read
    /// what every control does right where it is mapped.
    /// Whether the note line shows a live text field. Collapsed rows render
    /// plain Text: AppKit text fields are the most expensive control these
    /// rows create, and materializing one per row made scrolling the binding
    /// list hitch. Clicking the note swaps the field in.
    @State var editingNote = false
    @FocusState var noteFieldFocused: Bool
    /// Return in the note field hands focus back to the note's button, not
    /// to nothing (the field it was in goes away).
    @FocusState var noteButtonFocused: Bool
    @FocusState var phraseFocused: Bool
}


#if DEBUG
/// DEBUG: the strings a row hands to VoiceOver and Voice Control (its row
/// label, the column labels and values, the output title, the Options
/// value), collected while the Test Bench renders shipped presets' rows
/// offscreen, so a change to how they are worked out can be shown to leave
/// every one as it was. Nil outside that case: one check per render.
@MainActor
enum RowA11yProbe {
    static var sink: [UUID: [String: String]]?
    static func record(_ id: UUID, _ values: [(String, String)]) {
        guard sink != nil else { return }
        for (key, value) in values { sink?[id, default: [:]][key] = value }
    }
}
#endif

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


// MARK: - Macro text view

/// The Text pane's state. The row owns it, since it outlives the pane (a
/// trip to the List view, a paste or an import from there, Save with lines
/// unapplied); only MacroTextPaneView observes it, so a keystroke redraws
/// the pane and not the row.
@MainActor
final class MacroTextPaneState: ObservableObject {
    /// The pane's lines, edited freely; the row changes only on Apply.
    @Published var text = ""
    /// What the pane's text parses to, refreshed a moment after each edit.
    @Published var result: MacroTextResult?
    /// The text the writer last produced from the row, so a change made in
    /// the Steps pane (or by the recorder) refills a pane nobody has edited.
    @Published var written = ""
    /// True after the first Apply of a text that opens or types something:
    /// the status line says what, and the next click applies it.
    @Published var openerArmed = false
    /// True after the first Apply over steps changed since.
    @Published var staleArmed = false
    /// The line a clicked issue asks the text view to select.
    @Published var selectLine: Int?
    /// A note under the text (several macros pasted, nothing to paste),
    /// shown while the text is still the one it was written for.
    @Published var note: (text: String, message: String)?
    /// The steps the pane's text was written from: steps added or recorded
    /// in the List view since make Apply ask before replacing them. Not
    /// shown, so not published.
    var baseSteps: [MacroStep]?
    /// The pane was just filled from the List view; its first appear keeps it.
    var justShown = false
    var parseTask: Task<Void, Never>?
}

/// The macro Text pane: the editor, the status, the issues and Apply. The
/// row hands in what it decides (Apply, Discard, what an edit or a change
/// to the row does), as closures.
struct MacroTextPaneView: View {
    @ObservedObject var pane: MacroTextPaneState
    var scale: CGFloat
    /// What the pane is written from, as the row was at its last render.
    var rowState: MacroTextRowState
    var reviewLine: ([MacroStep]) -> String
    var apply: () -> Void
    var discard: () -> Void
    var appeared: () -> Void
    var edited: () -> Void
    var rowChanged: () -> Void

    /// Lines as the split on line breaks counted them, without making the
    /// array of them per keystroke.
    private var lineCount: Int {
        pane.text.reduce(into: 1) { count, character in if character == "\n" { count += 1 } }
    }

    /// The first error, else the first note.
    private var leadIssue: MacroTextIssue? {
        guard let result = pane.result else { return nil }
        return result.issues.first(where: \.isError) ?? result.issues.first
    }

    private var otherIssues: [MacroTextIssue] {
        guard let result = pane.result, let lead = leadIssue else { return [] }
        return result.issues.filter { $0 != lead }
    }

    /// The opener review while Apply anyway is offered, else the lead
    /// issue, else the summary ("7 steps, 1.1 s").
    private var status: String {
        guard let result = pane.result else { return "" }
        if pane.openerArmed { return reviewLine(result.steps) }
        if let issue = leadIssue { return issue.message }
        return result.summary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MacroTextEditor(text: $pane.text, scale: scale, selectLine: $pane.selectLine)
                .frame(height: MacroTextEditor.height(forLines: lineCount, scale: scale))

            // The summary when the lines are clean, else the first error,
            // else the first note; the rest are buttons that go to their line.
            Text(verbatim: status)
                .font(.callout)
                .foregroundStyle(.hint)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Macro text status")
                .accessibilityValue(Text(verbatim: status))
            if let note = pane.note, note.text == pane.text {
                Text(verbatim: note.message)
                    .font(.callout)
                    .foregroundStyle(.hint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(otherIssues.enumerated()), id: \.offset) { _, issue in
                Button {
                    pane.selectLine = issue.line
                } label: {
                    Text(verbatim: issue.message)
                        .font(.callout)
                        .foregroundStyle(.hint)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Selects line \(issue.line) in the macro text")
            }

            // Only once the lines were edited: the text is the steps until
            // then, and copying or pasting is the text's own Command C and V.
            if pane.text != pane.written {
                HStack(spacing: 8) {
                    Button {
                        apply()
                    } label: {
                        Label(pane.openerArmed || pane.staleArmed ? String(localized: "Apply anyway") : String(localized: "Apply changes"),
                              systemImage: "checkmark.circle")
                            .font(.callout)
                    }
                    .buttonStyle(.solidCompact)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(pane.result?.hasErrors ?? true)
                    .hoverHelp("Makes these lines the row's steps (Command Return). Off while a line has a problem; the line is named above.")

                    Button {
                        discard()
                    } label: {
                        Label("Discard changes", systemImage: "arrow.uturn.backward.circle")
                            .font(.callout)
                    }
                    .buttonStyle(.solidSecondaryCompact)
                    .hoverHelp("Goes back to the row's steps as they are.")
                }
            }
        }
        .onAppear { appeared() }
        .onDisappear {
            pane.parseTask?.cancel()
        }
        .onChange(of: pane.text) { _, _ in edited() }
        .onChange(of: rowState) { _, _ in rowChanged() }
    }
}

/// What the Text pane is written from: a change to any of it refills a
/// pane nobody has edited.
struct MacroTextRowState: Equatable {
    var steps: [MacroStep]?
    var options: MacroTextOptions
    @MainActor init(row: BindingModel) {
        steps = row.macroSteps
        options = MacroTextOptions(row: row)
    }
}

/// The Text pane's editor: an NSTextView, since SwiftUI's TextEditor
/// substitutes curly quotes and dashes, which the parser would then have
/// to read back, and gives no way to select one line from outside.
struct MacroTextEditor: NSViewRepresentable {
    @SwiftUI.Binding var text: String
    var scale: CGFloat
    /// A 1-based line to select and focus; cleared once done.
    @SwiftUI.Binding var selectLine: Int?

    static let inset: CGFloat = 5

    static func font(scale: CGFloat) -> NSFont {
        .monospacedSystemFont(ofSize: NSFont.systemFontSize * max(1, scale), weight: .regular)
    }

    /// Room for `lines` lines, at least 8 and at most 16, plus the inset.
    @MainActor static func height(forLines lines: Int, scale: CGFloat) -> CGFloat {
        lineHeight(scale: scale) * CGFloat(min(16, max(8, lines))) + 2 * inset + 2
    }

    /// One line's height per text scale, measured once: it was a new
    /// NSLayoutManager per render, so per keystroke in the pane.
    @MainActor private static var lineHeights: [CGFloat: CGFloat] = [:]
    @MainActor private static func lineHeight(scale: CGFloat) -> CGFloat {
        if let known = lineHeights[scale] { return known }
        let height = ceil(NSLayoutManager().defaultLineHeight(for: font(scale: scale)))
        lineHeights[scale] = height
        return height
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.delegate = context.coordinator
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        // Plain lines for the parser: no curly quotes, no dashes joined,
        // no words corrected or replaced behind the typist.
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.smartInsertDeleteEnabled = false
        view.textContainerInset = NSSize(width: Self.inset, height: Self.inset)
        view.setAccessibilityLabel(String(localized: "Macro text"))
        view.identifier = Self.identifier
        apply(to: view)
        view.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        apply(to: view)
        if view.string != text {
            context.coordinator.updating = true
            let selected = view.selectedRange()
            view.string = text
            let end = (text as NSString).length
            view.setSelectedRange(NSRange(location: min(selected.location, end), length: 0))
            context.coordinator.updating = false
            // Refilled from the row: the typing it replaced is not undone into.
            context.coordinator.undo.removeAllActions()
        }
        if let line = selectLine {
            select(line: line, in: view)
            DispatchQueue.main.async { self.selectLine = nil }
        }
    }

    private func apply(to view: NSTextView) {
        let font = Self.font(scale: scale)
        if view.font != font { view.font = font }
        view.textColor = .labelColor
        view.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
    }

    /// Selects the line's characters, without its line break, and scrolls
    /// to it.
    private func select(line: Int, in view: NSTextView) {
        let string = view.string as NSString
        var index = 0
        var number = 1
        while number < line, index < string.length {
            index = NSMaxRange(string.lineRange(for: NSRange(location: index, length: 0)))
            number += 1
        }
        guard index <= string.length else { return }
        var range = string.lineRange(for: NSRange(location: index, length: 0))
        let contents = string.substring(with: range).trimmingCharacters(in: .newlines)
        range.length = (contents as NSString).length
        view.window?.makeFirstResponder(view)
        view.setSelectedRange(range)
        view.scrollRangeToVisible(range)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacroTextEditor
        /// True while updateNSView writes the text, so the echo is not
        /// read back as an edit.
        var updating = false

        /// The pane's own undo, so Command Z takes back typing here and not
        /// the editor's last preset change (which could drop the row and
        /// the lines with it).
        let undo = UndoManager()

        init(_ parent: MacroTextEditor) { self.parent = parent }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        func textDidChange(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
    }

    /// The editor's Undo and Redo ask this first.
    static let identifier = NSUserInterfaceItemIdentifier("InputConfig.macroText")
}

// MARK: - Drag handle

/// Mouse tracking for the row's reorder handle.
///
/// Deliberately AppKit: an `NSView` instance survives SwiftUI body updates, so
/// a drag keeps running while the row it belongs to re-renders. Reports the
/// pointer's downward travel in points since the press, measured on screen so
/// it is unaffected by the row moving.
struct RowDragHandle: NSViewRepresentable {
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
                    if neutral != engineLevel { neutral = engineLevel }
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
struct DebugToggleOptionsModifier: ViewModifier {
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

/// One glow over an Options box or the Regions card: it lights in the accent
/// color, a sheen sweeps across it left to right (left out with Reduce
/// Motion), and it fades, so the box a click just sent you to is easy to find.
struct OptionsSpotlight: View {
    var cornerRadius: CGFloat = 10
    let sweeps: Bool
    let done: () -> Void
    @State private var lit = false
    @State private var sweep: CGFloat = -0.4

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
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
struct RevealRowOnRequest: ViewModifier {
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
struct TouchpadRegionsButton: View {
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
struct TapCalibrateButton: View {
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
struct ShortcutModifierToggles: View {
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
                    Text(item.symbol).frame(minWidth: 10)
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
/// The preset's Scroll speed (Preset.automation.scrollMultiplier), handed
/// down by the editor so Play once scrolls a Scroll step at the speed the
/// preset will, not a cached one; nil plays it as the engine's default.
private struct PresetScrollMultiplierKey: EnvironmentKey {
    static let defaultValue: Double? = nil
}
extension EnvironmentValues {
    var presetButtonFamily: FaceLetters? {
        get { self[PresetButtonFamilyKey.self] }
        set { self[PresetButtonFamilyKey.self] = newValue }
    }
    var presetScrollMultiplier: Double? {
        get { self[PresetScrollMultiplierKey.self] }
        set { self[PresetScrollMultiplierKey.self] = newValue }
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
struct SystemListChooser: View {
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
        .controlSize(.small)
        .fixedSize()
    }
}
