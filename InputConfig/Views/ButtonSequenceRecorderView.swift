import SwiftUI

/// Records a button sequence for a Button Sequence row: press the buttons
/// on the controller in order, and they are the sequence. Reads the pads
/// the way the running row does (ButtonSequenceRecognizer.downSet on each
/// poll's state), so what is recorded is what fires: a d-pad diagonal is
/// two presses, a roll across the d-pad is each new direction once. Scan
/// is held open meanwhile so the presses do not also fire the preset's rows.
struct ButtonSequenceRecorder: View {
    /// The row's time between presses, so what is recorded is what fires.
    var windowMs: Int = 600
    /// The slot the row's group reads; only its pad's presses are steps, as
    /// only they make the row fire. A second player's resting thumb or a
    /// trackpad adopted as a pad added presses here.
    var slot: Int? = nil
    /// The row's device names its buttons (the family it prints).
    let buttonName: (Int) -> String
    let onSave: ([Int]) -> Void

    @EnvironmentObject private var controllerService: GameControllerService
    @Environment(\.dismiss) private var dismiss

    @State private var steps: [Int] = []
    @State private var finished = false
    @State private var lastPressAt: Double = 0
    @State private var tick = 0
    /// A gap went past the row's time between presses: at that pace the
    /// row will not fire, though the recording took it.
    @State private var tooSlow = false
    /// What each slot held on the last sample: a press is a code that was
    /// up the sample before, as in the recognizer.
    @State private var prevDown: [Int: Set<Int>] = [:]
    @State private var timer: Timer?

    /// Recording ends once the row's time between presses has passed,
    /// with a floor so a slow hand still finishes its sequence.
    private var quietEnd: Double { max(1.0, Double(windowMs) / 1000) }
    private var isFull: Bool { steps.count >= InputEvent.maxSequenceSteps }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Record a button sequence")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Press the buttons on the controller in order. Recording stops shortly after the last press.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                Text("Presses")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Text(steps.isEmpty ? String(localized: "None yet") : steps.map(buttonName).joined(separator: ", "))
                    .font(.system(size: 22, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if tooSlow {
                    Text("Some presses came slower than the time between presses; the row will need them faster or a longer time.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button("Start Over") { startOver() }
                    .buttonStyle(.solidSecondaryCompact)
                    .disabled(steps.isEmpty && !finished)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.solidSecondaryCompact)
                    .keyboardShortcut(.cancelAction)
                Button("Use This Sequence") { onSave(steps); dismiss() }
                    .buttonStyle(.solidCompact)
                    .keyboardShortcut(.defaultAction)
                    .disabled(steps.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        // Held back only while taking: once finished, the person who drives
        // the pointer with the controller has to reach Use and Cancel.
        .onChange(of: finished) { _, done in MappingEngine.editorListenerArmed = !done }
        .onAppear { MappingEngine.editorListenerArmed = true; start() }
        .onDisappear { MappingEngine.editorListenerArmed = false; stop() }
        .task(id: tick) {
            // Ends the recording once the pad has been quiet long enough.
            guard !finished, !steps.isEmpty else { return }
            try? await Task.sleep(for: .seconds(quietEnd))
            guard !Task.isCancelled, !finished, !steps.isEmpty,
                  CACurrentMediaTime() - lastPressAt >= quietEnd - 0.05 else { return }
            finished = true
            stop()
            AccessibilityNotification.Announcement(String(localized: "Done: \(steps.map(buttonName).joined(separator: ", "))")).post()
        }
    }

    private var status: String {
        if controllerService.connectedControllers.isEmpty, controllerService.rawHIDGamepadSlots.isEmpty,
           controllerService.steamControllerSlot == nil, controllerService.racingWheelSlots.isEmpty {
            return String(localized: "No controller is reading. Connect one to record.")
        }
        if finished {
            return isFull
                ? String(localized: "\(steps.count) of \(InputEvent.maxSequenceSteps), full. Use this sequence, or start over.")
                : String(localized: "Done. Use this sequence, or start over.")
        }
        if steps.isEmpty { return String(localized: "Waiting for the first press.") }
        return String(localized: "Recording. Press again, or wait to finish.")
    }

    private func start() {
        // Scan's own events are not used: it arms the editor listener,
        // turns live polling on and keeps the rows quiet while the pads
        // are sampled below.
        controllerService.startScanning { _ in }
        prevDown = [:]
        timer?.invalidate()
        // At the engine's rate: a quick tap fell between two 30 Hz samples.
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            Task { @MainActor in sample() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        controllerService.stopScanning()
    }

    /// One poll, read the way ButtonSequenceRecognizer.feed reads it.
    private func sample() {
        guard !finished else { return }
        let now = CACurrentMediaTime()
        let slots = slot.map { [$0] } ?? controllerService.currentStates.keys.sorted()
        for slot in slots where controllerService.rawHIDGamepadSlots[slot]?.isPointingDevice != true {
            guard let state = controllerService.peekControllerState(at: slot) else { continue }
            let down = ButtonSequenceRecognizer.downSet(state).subtracting(controllerService.sequenceTouchCodes(slot: slot))
            // A slot's first sample is where it rests: a button already
            // held when recording begins is not a press.
            guard let was = prevDown[slot] else { prevDown[slot] = down; continue }
            prevDown[slot] = down
            for code in down.subtracting(was).sorted() where !isFull {
                if !steps.isEmpty, now - lastPressAt > Double(windowMs) / 1000 { tooSlow = true }
                steps.append(code)
                lastPressAt = now
                tick += 1
            }
        }
        // The cap ends the recording now, not after the quiet time, so no
        // press is taken in silence while the status still says Recording.
        if isFull {
            finished = true
            stop()
            AccessibilityNotification.Announcement(String(localized: "Done: \(steps.map(buttonName).joined(separator: ", ")). \(steps.count) of \(InputEvent.maxSequenceSteps), full.")).post()
        }
    }

    private func startOver() {
        steps.removeAll()
        finished = false
        tooSlow = false
        stop()
        start()
    }
}
