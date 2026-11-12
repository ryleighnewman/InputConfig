import SwiftUI
import AppKit

/// The small floating panel a macro recording shows while InputConfig has
/// stepped aside: it says the recording is running, counts the steps, and
/// has Pause and Stop. A non-activating panel, so clicking it never brings
/// InputConfig to the front, and it stays on screen while the app is hidden.
@MainActor
final class RecordingHUD {
    static let shared = RecordingHUD()
    private var panel: NSPanel?

    private init() {}

    func show() {
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - panel.frame.height - 12))
        }
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    /// The panel follows its content, centered where it is: the words and the
    /// count run longer than English in several languages.
    func fit(_ size: CGSize) {
        guard let panel, abs(panel.frame.width - size.width) > 0.5 else { return }
        var frame = panel.frame
        frame.origin.x += (frame.width - size.width) / 2
        frame.size = size
        panel.setFrame(frame, display: true)
    }

    /// Whether a point (AppKit screen coordinates, as NSEvent.mouseLocation)
    /// lands on the panel: its clicks are not macro steps.
    func contains(_ point: NSPoint) -> Bool {
        guard let panel, panel.isVisible else { return false }
        return panel.frame.insetBy(dx: -4, dy: -4).contains(point)
    }

    private func makePanel() -> NSPanel {
        let panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 44),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        // InputConfig hides itself for the take; the panel must not go too.
        panel.canHide = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // A click on Pause must not take the keyboard from the app being
        // recorded: the next keys went to the panel, and Command Q to us.
        panel.becomesKeyOnlyIfNeeded = true
        let host = FirstClickHostingView(rootView: AnyView(RecordingHUDView().appAccessibility()))
        host.frame = panel.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    /// Answers the first click, with the panel never key.
    private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    /// Takes clicks without activating the app.
    private final class HUDPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }
}

private struct RecordingHUDView: View {
    /// Observable: this panel re-runs for the count and the pause state it
    /// shows, not for every step change of the take.
    private let recorder = MacroRecorderService.shared

    var body: some View {
        #if DEBUG
        let _ = BodyRuns.note("RecordingHUDView")
        #endif
        HStack(spacing: 10) {
            Circle()
                .fill(recorder.userPaused || recorder.paused ? Color.secondary : Color.red)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text(recorder.paused ? String(localized: "Waiting")
                 : recorder.userPaused ? String(localized: "Paused") : String(localized: "Recording"))
                .font(.callout.weight(.semibold))
            Text("\(recorder.pressCount) pressed")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button(recorder.userPaused ? String(localized: "Resume") : String(localized: "Pause")) {
                recorder.togglePause()
            }
            .buttonStyle(.solidSecondaryCompact)
            Button("Stop") { recorder.stop(returnToApp: true) }
                .buttonStyle(.solidCompact)
                .accessibilityHint("Stops the recording and goes back to InputConfig")
        }
        .padding(.horizontal, 14)
        .frame(minWidth: 300, minHeight: 44)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .fixedSize()
        .background(GeometryReader { geometry in
            Color.clear.onChange(of: geometry.size, initial: true) { _, size in
                DispatchQueue.main.async { RecordingHUD.shared.fit(size) }
            }
        })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Macro recording")
    }
}
