import SwiftUI
import Combine
#if canImport(AppKit)
import AppKit
#endif

/// Overlay shown while scanning for joystick input
struct ScanOverlayView: View {
    @ObservedObject var controllerService: GameControllerService
    let onInputDetected: (InputEvent) -> Void
    let onCancel: () -> Void

    @State private var timeRemaining: Int = 10
    @State private var detectedInput: InputEvent?
    @State private var timer: Timer?
    @State private var didCompleteScan = false
    /// Local AppKit event monitor that lets the scan also pick up the Mac
    /// keyboard, trackpad, and mouse (not just the game controller). Local
    /// monitors deliver events that target this app while it is frontmost, so
    /// they need no Accessibility or Input Monitoring permission - the scan
    /// window is frontmost the whole time it is up.
    @State private var inputMonitor: Any?

    var body: some View {
        ZStack {
            // Dimmed background. Mouse clicks land on the input monitor
            // (which consumes them as scan input), so no tap-catcher here.
            Color.black.opacity(0.5)
                .ignoresSafeArea()

            // Content card
            VStack(spacing: 20) {
                // Timer
                Text("\(timeRemaining)")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("Press a control to map it")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text("Hold a button or move an axis on your controller, or press a key, click, or scroll on your Mac keyboard or trackpad.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)

                if let input = detectedInput {
                    Text("Detected: \(input.displayName)")
                        .font(.title3)
                        .bold()
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                }

                // Esc cancels. We don't use a clickable Cancel button here
                // because the input monitor would capture the click on it as a
                // mouse binding; Esc (handled in the monitor) and the timeout
                // are the clean ways out.
                HStack(spacing: 6) {
                    Text("esc")
                        .font(.caption.monospaced().weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(.white.opacity(0.18))
                        )
                    Text("to cancel")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .foregroundStyle(.white.opacity(0.85))
            }
            .padding(40)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
                    .shadow(radius: 20)
            )
        }
        .onAppear {
            startTimer()
            controllerService.startScanning { event in
                completeScan(with: event)
            }
            installInputMonitor()
        }
        .onDisappear {
            cleanup()
        }
    }

    /// Watch for Mac keyboard / trackpad / mouse input during the scan, in
    /// addition to the game controller. Returns nil from the monitor to
    /// swallow the event (so a captured key does not also type into the app),
    /// except for Escape, which we let through so the Cancel shortcut works.
    private func installInputMonitor() {
        #if canImport(AppKit)
        guard inputMonitor == nil else { return }
        inputMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown,
                       .otherMouseDown, .scrollWheel]
        ) { event in
            handleScanNSEvent(event) ? nil : event
        }
        #endif
    }

    #if canImport(AppKit)
    /// Map a captured AppKit event to an `InputEvent` and finish the scan.
    /// Returns true if the event was consumed.
    private func handleScanNSEvent(_ event: NSEvent) -> Bool {
        guard !didCompleteScan else { return false }
        switch event.type {
        case .keyDown:
            if event.keyCode == 53 { // Escape cancels the scan
                cleanup()
                onCancel()
                return true
            }
            if event.isARepeat { return true }
            guard let hid = ExternalInputDeviceService.hidUsage(forVirtualKeyCode: Int(event.keyCode)) else {
                return true
            }
            completeScan(with: InputEvent(
                type: .extKey, index: hid,
                extDeviceID: ExternalInputDeviceService.builtInKeyboardID))
            return true
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let button = event.type == .leftMouseDown ? 0
                : (event.type == .rightMouseDown ? 1 : event.buttonNumber)
            completeScan(with: InputEvent(
                type: .extMouse, index: button,
                extDeviceID: ExternalInputDeviceService.builtInMouseID,
                extMouseKind: .button))
            return true
        case .scrollWheel:
            let dir: AxisDirection = event.scrollingDeltaY >= 0 ? .positive : .negative
            completeScan(with: InputEvent(
                type: .extMouse, index: 0, axisDirection: dir,
                extDeviceID: ExternalInputDeviceService.builtInMouseID,
                extMouseKind: .scrollY))
            return true
        default:
            return false
        }
    }
    #endif

    /// Single completion path for controller scan results.
    private func completeScan(with event: InputEvent) {
        guard !didCompleteScan else { return }
        didCompleteScan = true
        detectedInput = event
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            cleanup()
            onInputDetected(event)
        }
    }

    private func startTimer() {
        timeRemaining = 10
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            if timeRemaining > 0 {
                timeRemaining -= 1
            } else {
                cleanup()
                onCancel()
            }
        }
    }

    private func cleanup() {
        timer?.invalidate()
        timer = nil
        controllerService.stopScanning()
        #if canImport(AppKit)
        if let m = inputMonitor { NSEvent.removeMonitor(m); inputMonitor = nil }
        #endif
    }
}
