import SwiftUI
import AppKit

/// Settings sub-panel for cursor-related quality-of-life options that
/// make playing games on macOS less painful. All features are off by
/// default; flipping a toggle here writes through to the persisted
/// state in `CursorGuardService` (which itself reads from
/// UserDefaults so the choices survive launches).
struct GamingUtilitiesPanel: View {
    @ObservedObject private var guardSvc = CursorGuardService.shared
    /// The "Every" slider's value while its thumb is held. The service
    /// gets the value on release: each write there restarts the guard's
    /// timer, which while a preset ran was once per step of the drag.
    @State private var recenterLiveMs: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("These apply to every preset while it runs, but not over InputConfig, the Finder or System Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Confine: the toggle, then its margin on the line below.
            // The slider a switch reveals fades in and what follows slides,
            // not jumps (off under either Reduce Motion: Settings' sheet root
            // strips the transaction).
            Toggle(isOn: $guardSvc.edgeConfineEnabled.animation(.snappy(duration: 0.22))) {
                Label("Keep the pointer off the screen edges", systemImage: "rectangle.inset.filled")
            }
            if guardSvc.edgeConfineEnabled {
                sliderRow("Margin", value: $guardSvc.edgeBufferPx, range: 1...200, step: 1,
                          text: String(localized: "\(Int(guardSvc.edgeBufferPx)) px"),
                          spoken: String(localized: "\(Int(guardSvc.edgeBufferPx)) pixels"))
            }

            // Recenter
            Toggle(isOn: $guardSvc.autoRecenterEnabled.animation(.snappy(duration: 0.22))) {
                Label("Recenter the pointer on a timer", systemImage: "arrow.triangle.2.circlepath")
            }
            if guardSvc.autoRecenterEnabled {
                HStack(spacing: 10) {
                    let everyMs = Int(recenterLiveMs ?? guardSvc.recenterIntervalMs)
                    sliderRow("Every", value: $guardSvc.recenterIntervalMs, range: 50...2000, step: 10,
                              text: String(localized: "\(everyMs) ms"),
                              spoken: String(localized: "\(everyMs) milliseconds"),
                              live: { recenterLiveMs = $0 == guardSvc.recenterIntervalMs ? nil : $0 })
                    Button {
                        guardSvc.warpToAnchor()
                    } label: {
                        Label("Now", systemImage: "scope")
                    }
                    .buttonStyle(.solidSecondaryCompact)
                    .help("Move the pointer to the center of the screen it is on")
                }
                // Once the value lands (a release, an arrow key, Reset),
                // the label reads the stored one again.
                .onChange(of: guardSvc.recenterIntervalMs) { _, _ in recenterLiveMs = nil }
            }

            // Hide
            Toggle(isOn: $guardSvc.hideCursorWhileEngineRunning) {
                Label("Hide the pointer while a preset runs", systemImage: "cursorarrow.slash")
            }

            // Speed
            Label("Pointer speed for stick and gyro motion", systemImage: "speedometer")
            sliderRow("Speed", value: $guardSvc.sensitivityMultiplier, range: 0.1...5.0, step: 0.05,
                      text: String(format: "×%.2f", locale: .current, guardSvc.sensitivityMultiplier))

            Text("Keeping the pointer off screen edges keeps game cameras turning. Speed multiplies every Mouse Motion row, not the Mac's pointer speed.")
                .font(.caption)
                .foregroundStyle(.hint)
                .fixedSize(horizontal: false, vertical: true)

            if guardSvc.engineActive {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                    Text("A preset is running; these are live.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Label, slider, value: one indented line under its toggle, the same
    /// shape for every slider on the panel. With `live`, the bound value
    /// is written when the thumb is let go (and on each arrow key or
    /// VoiceOver step), and `live` hears every step for the label.
    private func sliderRow(_ label: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>,
                           step: Double, text: String, spoken: String? = nil,
                           live: ((Double) -> Void)? = nil) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(minWidth: 52, alignment: .leading)
            if let live {
                ThrottledSlider(label, value: value, in: range, step: step, onLiveChange: live)
                    .accessibilityValue(spoken ?? text)
            } else {
                Slider(value: value, in: range, step: step) { EmptyView() }
                    .accessibilityLabel(label)
                    .accessibilityValue(spoken ?? text)
            }
            Text(text)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .trailing)
        }
        .padding(.leading, 26)
    }
}
