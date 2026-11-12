import SwiftUI

/// The macro editor's Record steps sheet: press keys and mouse buttons in
/// any app, come back, and the presses are macro steps with the timing
/// they were made with.
struct MacroRecorderView: View {
    /// Whether the row already has steps: the save button then adds to them.
    let appending: Bool
    let onSave: ([MacroStep]) -> Void

    @Bindable private var recorder = MacroRecorderService.shared
    @ObservedObject private var accessibility = AccessibilityPermissionService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var keepTiming = true
    /// A pause longer than a second (reading a dialog, finding a window)
    /// is cut to one; holds are kept whole.
    @State private var capLongWaits = true
    /// Cancel pressed while a take is still running: it asks first.
    @State private var confirmingDiscard = false

    /// The steps as they are now. Read once per body (the status line, the
    /// list, the Use button and the discard dialog share it); the actions
    /// and the stop announcement read it again when they run, after a Stop
    /// that may have closed a held press.
    private var steps: [MacroStep] {
        recorder.liveSteps(keepTiming: keepTiming, capWaitMs: capLongWaits ? MacroRecording.cappedWaitMs : nil)
    }

    var body: some View {
        #if DEBUG
        let _ = BodyRuns.note("MacroRecorderView")
        #endif
        let shown = steps
        VStack(alignment: .leading, spacing: 12) {
            Text("Record macro steps")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Click Start (Command R) and InputConfig steps aside, so the app behind it comes forward. Press the keys and mouse buttons in order; the first click, which only picks the window, is not a step. A small panel at the top of the screen has Pause and Stop; Escape twice or your stop key stops too, and brings you back here. Nothing is recorded while InputConfig is in front.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !accessibility.isTrusted {
                permissionCard
            }

            HStack(spacing: 10) {
                if recorder.isRecording {
                    Button("Stop") { recorder.stop() }
                        .buttonStyle(.solidCompact)
                        .keyboardShortcut("r", modifiers: .command)
                } else {
                    Button(!recorder.hasEdges ? String(localized: "Start Recording") : String(localized: "Record More"))
                        { recorder.start() }
                        .buttonStyle(.solidCompact)
                        .keyboardShortcut("r", modifiers: .command)
                        .disabled(!accessibility.isTrusted || recorder.isFull)
                }
                Button("Start Over") { recorder.startOver() }
                    .buttonStyle(.solidSecondaryCompact)
                    .disabled(!recorder.hasEdges)
                Text(status(stepCount: shown.count))
                    .font(.callout)
                    .foregroundStyle(recorder.isRecording && !recorder.paused ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            HStack(spacing: 14) {
                Toggle("Keep the recorded timing", isOn: $keepTiming)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .hoverHelp("On: each step waits and holds as long as you did. Off: every step waits 50 ms and holds 50 ms.")
                Toggle("Cap waits at 1 s", isOn: $capLongWaits)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .disabled(!keepTiming)
                    .hoverHelp("A pause longer than a second before a step, such as reading a dialog, is cut to one second. Holds are kept as made.")
                Toggle("Skip the first click", isOn: $recorder.skipFirstClick)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .disabled(recorder.isRecording)
                    .hoverHelp("The first click after InputConfig steps aside only picks the window to work in, so it is left out. Turn off when that click is the macro's first step.")
            }
            HStack(spacing: 8) {
                Toggle("Stop key", isOn: SwiftUI.Binding(
                    get: { recorder.stopKeyCode >= 0 },
                    set: { recorder.stopKeyCode = $0 ? 69 : -1 }))   // F12 to begin with
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .disabled(recorder.isRecording)
                    .hoverHelp("A key that stops the recording from the other app and brings you back, beside Escape twice and the Stop button on the recording panel. Pick one the macro does not use; it is never recorded.")
                if recorder.stopKeyCode >= 0 {
                    KeyCodePicker(selectedCode: $recorder.stopKeyCode, voiceRole: "Stop key")
                        .frame(width: 110)
                        .disabled(recorder.isRecording)
                        .accessibilityLabel("Stop key")
                }
            }
            HStack(spacing: 14) {
                Toggle("Click positions", isOn: $recorder.recordClickPositions)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .disabled(recorder.isRecording)
                    .hoverHelp("Each click is played where it was made: a Move pointer step goes before it.")
                Toggle("Pointer path", isOn: $recorder.recordPointerPath)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .disabled(recorder.isRecording)
                    .hoverHelp("The pointer's movement between clicks, as glides, ten samples a second. Off, the pointer jumps to each click. A recording holds 200 steps; the path's samples are the first to go.")
                Toggle("Scrolling", isOn: $recorder.recordScrolling)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .disabled(recorder.isRecording)
                    .hoverHelp("Scroll wheel and trackpad scrolling, as Scroll steps.")
            }

            Text("Steps")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    if shown.isEmpty {
                        Text("None yet")
                            .font(.callout)
                            .foregroundStyle(.hint)
                    }
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, step in
                        Text("\(index + 1). \(Self.describe(step))")
                            .font(.callout.monospacedDigit())
                            .accessibilityLabel(String(localized: "Step \(index + 1): \(Self.describe(step))"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120, maxHeight: 220)

            HStack {
                Spacer()
                Button("Cancel") {
                    // The text above pairs Escape with stopping, and the
                    // double Escape does nothing once InputConfig is in
                    // front: a take still running is not thrown away on
                    // one press without asking.
                    if recorder.isRecording, recorder.hasEdges {
                        confirmingDiscard = true
                    } else {
                        recorder.stop()
                        dismiss()
                    }
                }
                    .buttonStyle(.solidSecondaryCompact)
                    .keyboardShortcut(.cancelAction)
                    .confirmationDialog("Stop recording and discard the steps?",
                                        isPresented: $confirmingDiscard, titleVisibility: .visible) {
                        Button("Discard Steps", role: .destructive) { recorder.stop(); dismiss() }
                        Button("Keep Recording", role: .cancel) {}
                    } message: {
                        Text("Recording is still running, with \(shown.count) steps so far. Click Stop to keep them.")
                    }
                Button(appending ? String(localized: "Add These Steps") : String(localized: "Use These Steps")) {
                    recorder.stop()
                    onSave(steps)
                    dismiss()
                }
                .buttonStyle(.solidCompact)
                .keyboardShortcut(.defaultAction)
                .disabled(shown.isEmpty || recorder.isRecording)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { recorder.startOver() }
        .onDisappear { recorder.stop() }
        .onChange(of: recorder.isRecording) { _, now in
            AccessibilityNotification.Announcement(now
                ? String(localized: "Recording. Switch to the other app and press the keys.")
                : String(localized: "Recording stopped. \(steps.count) steps.")).post()
        }
    }

    private func status(stepCount: Int) -> String {
        if !recorder.isRecording {
            if !recorder.hasEdges { return String(localized: "Not recording.") }
            // The room the row has left, which the take stops at.
            return recorder.isFull
                ? String(localized: "Full: \(recorder.room) steps.")
                : String(localized: "Stopped: \(stepCount) of \(recorder.room) steps.")
        }
        if recorder.paused { return String(localized: "Waiting: switch to the other app.") }
        return String(localized: "Recording in the app in front (\(recorder.pressCount) pressed, \(stepCount) of \(recorder.room) steps).")
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Accessibility is not allowed for InputConfig", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout.weight(.medium))
            Text("Seeing the keys and mouse buttons you press needs Accessibility under Privacy & Security, the same permission the preset's outputs use.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Accessibility Settings") { accessibility.requestAccess() }
                .buttonStyle(.solidCompact)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.08)))
    }

    /// The glyph for each modifier key, left and right.
    static let modifierSymbols: [Int: String] = [
        224: "\u{2303}", 228: "\u{2303}", 226: "\u{2325}", 230: "\u{2325}",
        225: "\u{21E7}", 229: "\u{21E7}", 227: "\u{2318}", 231: "\u{2318}",
    ]

    /// "Tap V with Command, after 120 ms, held 60 ms".
    static func describe(_ step: MacroStep) -> String {
        let kind = step.eventKind ?? .tap
        switch kind {
        case .wait:
            return String(localized: "Wait \(step.delayMs) ms")
        case .moveTo:
            let x = Int(step.action.clickX ?? 0), y = Int(step.action.clickY ?? 0)
            return step.holdMs > 0
                ? String(localized: "Move the pointer to \(x), \(y) over \(step.holdMs) ms, after \(step.delayMs) ms")
                : String(localized: "Move the pointer to \(x), \(y), after \(step.delayMs) ms")
        case .waitFor:
            return String(localized: "Wait for the screen, up to \(step.timeoutMs ?? 10_000) ms")
        default:
            break
        }
        let what: String
        switch step.action.type {
        case .mouseButton: what = BindingRowView.mouseButtonName(step.action.resolvedMouseButton)
        case .mouseWheelStep:
            let lines = step.count ?? 1
            let up = step.action.mouseDirection == .negative
            let vertical = (step.action.mouseAxis ?? .vertical) == .vertical
            let direction = vertical ? (up ? String(localized: "up") : String(localized: "down"))
                                     : (up ? String(localized: "left") : String(localized: "right"))
            return String(localized: "Scroll \(direction) \(lines) lines, after \(step.delayMs) ms")
        case .typeText: what = String(localized: "the text \u{201C}\(step.action.text ?? "")\u{201D}")
        case .systemAction: what = step.action.systemActionKind?.displayName ?? OutputType.systemAction.displayName
        default: what = KeyCodeMap.name(for: step.action.keyCode ?? 4)
        }
        let modifiers = (step.modifiers ?? []).compactMap { Self.modifierSymbols[$0] }.joined()
        let target = modifiers.isEmpty ? what : "\(modifiers) \(what)"
        switch kind {
        case .tap:
            return String(localized: "Tap \(target), after \(step.delayMs) ms, held \(step.holdMs) ms")
        case .down:
            return String(localized: "Hold down \(target), after \(step.delayMs) ms")
        case .up:
            return String(localized: "Release \(target), after \(step.delayMs) ms")
        default:
            return target
        }
    }
}
