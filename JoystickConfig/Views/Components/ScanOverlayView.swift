import SwiftUI
import Combine

/// Overlay shown while scanning for joystick input
struct ScanOverlayView: View {
    @ObservedObject var controllerService: GameControllerService
    let onInputDetected: (InputEvent) -> Void
    let onCancel: () -> Void

    @State private var timeRemaining: Int = 10
    @State private var detectedInput: InputEvent?
    @State private var timer: Timer?
    /// While the overlay is up, also listen to external keyboard / mouse
    /// events from `ExternalInputDeviceService` (which now includes the
    /// built-in Mac keyboard and trackpad via the CGEventTap) so the
    /// first physical key/button on ANY device finishes the scan.
    @State private var externalSubscription: AnyCancellable?
    @State private var didCompleteScan = false

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { /* prevent tap-through */ }

            // Content card
            VStack(spacing: 20) {
                // Timer
                Text("\(timeRemaining)")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("Hold any button or move any axis on your Joystick")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                if let input = detectedInput {
                    Text("Detected: \(input.displayName)")
                        .font(.title3)
                        .bold()
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                }

                Text("Press ESC to cancel")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))

                Button("Cancel") {
                    cleanup()
                    onCancel()
                }
                .keyboardShortcut(.escape, modifiers: [])
                .buttonStyle(.bordered)
                .tint(.white)
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
            // Also subscribe to external HID + CGEventTap events. First
            // physical event from any source wins.
            externalSubscription = ExternalInputDeviceService.shared.events
                .receive(on: DispatchQueue.main)
                .sink { event in
                    guard !didCompleteScan else { return }
                    switch event {
                    case .keyDown(let dev, let hid):
                        completeScan(with: .extKey(hidCode: hid, deviceID: dev))
                    case .mouseButtonDown(let dev, let btn):
                        completeScan(with: .extMouseButton(btn, deviceID: dev))
                    default:
                        // Ignore key-up, mouse-up, motion, and scroll -
                        // a scan should latch on a discrete down event.
                        break
                    }
                }
        }
        .onDisappear {
            cleanup()
        }
    }

    /// Single completion path so controller, external HID, and CGEventTap
    /// scan results all flow through identical UI feedback.
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
        externalSubscription?.cancel()
        externalSubscription = nil
        controllerService.stopScanning()
    }
}
