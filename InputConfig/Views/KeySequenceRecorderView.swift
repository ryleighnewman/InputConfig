import SwiftUI
import AppKit
import Combine

/// Records a key sequence for a Key Sequence row: type the keys in order
/// on any keyboard, and they are the sequence. Listens through the same
/// keyboard monitor the external keyboard inputs use.
struct KeySequenceRecorder: View {
    /// The row's time between presses, so what is recorded is what fires.
    var windowMs: Int = 600
    let onSave: ([Int]) -> Void

    @ObservedObject private var accessibility = AccessibilityPermissionService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var steps: [Int] = []
    @State private var finished = false
    @State private var lastPressAt: Double = 0
    @State private var tick = 0
    /// A gap went past the row's time between presses: at that pace the
    /// row will not fire, though the recording took it.
    @State private var tooSlow = false
    @State private var subscription: AnyCancellable?

    private static let reason = "keySequenceRecorder"

    /// Recording ends once the row's time between presses has passed,
    /// with a floor so a slow hand still finishes its sequence.
    private var quietEnd: Double { max(1.0, Double(windowMs) / 1000) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Record a key sequence")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Type the keys in order, on any keyboard. Recording stops shortly after the last key. While InputConfig is in front, the keys that work this sheet are not recorded: Tab, Space, the arrows, Return, Escape, and any key with Control, Option or Command held. Type those in another app.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !accessibility.isTrusted {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Accessibility is not allowed for InputConfig", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout.weight(.medium))
                    Button("Open Accessibility Settings") { accessibility.requestAccess() }
                        .buttonStyle(.solidCompact)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.08)))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Keys")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Text(steps.isEmpty ? String(localized: "None yet") : steps.map { KeyCodeMap.name(for: $0) }.joined(separator: ", "))
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
                Button("Start Over") { steps.removeAll(); finished = false; tooSlow = false }
                    .buttonStyle(.solidSecondaryCompact)
                    .disabled(steps.isEmpty && !finished)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.solidSecondaryCompact)
                    .keyboardShortcut(.cancelAction)
                Button("Use This Sequence") { onSave(steps); dismiss() }
                    .buttonStyle(.solidCompact)
                    .keyboardShortcut(.defaultAction)
                    // Return is a key too: only once the quiet time has passed.
                    .disabled(steps.isEmpty || !finished)
            }
        }
        .padding(20)
        .frame(width: 480)
        // Held back while recording, as the other two recorders do: typed
        // keys also fired the running preset's rows.
        // Held back only while taking: once finished, the person who drives
        // the pointer with the controller has to reach Use and Cancel.
        .onChange(of: finished) { _, done in MappingEngine.editorListenerArmed = !done }
        .onAppear { MappingEngine.editorListenerArmed = true; start() }
        .onDisappear {
            MappingEngine.editorListenerArmed = false
            subscription = nil
            ExternalInputDeviceService.shared.release(Self.reason)
        }
        .task(id: tick) {
            guard !finished, !steps.isEmpty else { return }
            try? await Task.sleep(for: .seconds(quietEnd))
            guard !Task.isCancelled, !finished, !steps.isEmpty,
                  ProcessInfo.processInfo.systemUptime - lastPressAt >= quietEnd - 0.05 else { return }
            finished = true
            AccessibilityNotification.Announcement(String(localized: "Done: \(steps.map { KeyCodeMap.name(for: $0) }.joined(separator: ", "))")).post()
        }
    }

    private var status: String {
        if !accessibility.isTrusted { return String(localized: "Keys cannot be seen without Accessibility.") }
        if finished {
            return steps.count >= InputEvent.maxSequenceSteps
                ? String(localized: "\(steps.count) of \(InputEvent.maxSequenceSteps), full. Use this sequence, or start over.")
                : String(localized: "Done. Use this sequence, or start over.")
        }
        if steps.isEmpty { return String(localized: "Waiting for the first key.") }
        return String(localized: "Recording. Type again, or wait to finish.")
    }

    /// The keys that work the sheet while InputConfig is in front: Tab,
    /// Space and the arrows move focus, Return and Escape are its buttons,
    /// a key with Control or Option held is a VoiceOver command, and one
    /// with Command is a menu's. None of them is a step then; typed in
    /// another app, they all are.
    /// Caps Lock (57) too: it is the VoiceOver key for many people, and each
    /// VoiceOver command recorded a step.
    private static let sheetKeys: Set<Int> = [40, 41, 43, 44, 57, 79, 80, 81, 82]
    private static func drivesSheet(_ code: Int) -> Bool {
        guard NSApp.isActive else { return false }
        if sheetKeys.contains(code) { return true }
        return !NSEvent.modifierFlags.intersection([.control, .option, .command]).isEmpty
    }

    private func start() {
        let service = ExternalInputDeviceService.shared
        service.retain(Self.reason, keyboard: true)
        subscription = service.events
            .receive(on: DispatchQueue.main)
            .sink { event in
                // Without Accessibility only modifiers, Caps Lock and fn get
                // through, while the sheet says keys cannot be seen.
                guard case .keyDown(_, let code) = event, accessibility.isTrusted, !finished,
                      steps.count < InputEvent.maxSequenceSteps else { return }
                guard !Self.drivesSheet(code) else {
                    // Shift Tab: the Shift just before it worked the sheet too.
                    if let last = steps.last, (224...231).contains(last) { steps.removeLast() }
                    return
                }
                let now = ProcessInfo.processInfo.systemUptime
                if !steps.isEmpty, now - lastPressAt > Double(windowMs) / 1000 { tooSlow = true }
                steps.append(code)
                lastPressAt = now
                tick += 1
                // The cap ends the recording now, not after the quiet time,
                // so no key is taken in silence while the status still says
                // Recording.
                if steps.count >= InputEvent.maxSequenceSteps {
                    finished = true
                    AccessibilityNotification.Announcement(String(localized: "Done: \(steps.map { KeyCodeMap.name(for: $0) }.joined(separator: ", ")). \(steps.count) of \(InputEvent.maxSequenceSteps), full.")).post()
                }
            }
    }
}
