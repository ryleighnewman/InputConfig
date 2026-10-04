import SwiftUI
import AppKit

/// Settings sub-panel for cursor-related quality-of-life options that
/// make playing games on macOS less painful. All features are off by
/// default; flipping a toggle here writes through to the persisted
/// state in `CursorGuardService` (which itself reads from
/// UserDefaults so the choices survive launches).
struct GamingUtilitiesPanel: View {
    @ObservedObject private var guardSvc = CursorGuardService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Used by presets that don't set their own.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Confine: the toggle, then its margin on the line below.
            Toggle(isOn: $guardSvc.edgeConfineEnabled) {
                Label("Keep the pointer off the screen edges", systemImage: "rectangle.inset.filled")
            }
            if guardSvc.edgeConfineEnabled {
                sliderRow("Margin", value: $guardSvc.edgeBufferPx, range: 1...200, step: 1,
                          text: "\(Int(guardSvc.edgeBufferPx)) px")
            }

            // Recenter
            Toggle(isOn: $guardSvc.autoRecenterEnabled) {
                Label("Recenter the pointer on a timer", systemImage: "arrow.triangle.2.circlepath")
            }
            if guardSvc.autoRecenterEnabled {
                HStack(spacing: 10) {
                    sliderRow("Every", value: $guardSvc.recenterIntervalMs, range: 50...2000, step: 10,
                              text: "\(Int(guardSvc.recenterIntervalMs)) ms")
                    Button {
                        guardSvc.warpToAnchor()
                    } label: {
                        Label("Now", systemImage: "scope")
                    }
                    .buttonStyle(.solidSecondaryCompact)
                    .help("Move the pointer to the center of the screen it is on")
                }
            }

            // Hide
            Toggle(isOn: $guardSvc.hideCursorWhileEngineRunning) {
                Label("Hide the pointer while a preset runs", systemImage: "cursorarrow.slash")
            }

            // Speed
            Label("Pointer speed for stick and gyro motion", systemImage: "speedometer")
            sliderRow("Speed", value: $guardSvc.sensitivityMultiplier, range: 0.1...5.0, step: 0.05,
                      text: String(format: "×%.2f", guardSvc.sensitivityMultiplier))

            Text("Keeping the pointer off screen edges keeps game cameras turning. Speed multiplies every Mouse Motion row, not the Mac's pointer speed.")
                .font(.caption)
                .foregroundStyle(.hint)
                .fixedSize(horizontal: false, vertical: true)

            if guardSvc.engineActive {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("A preset is running; these are live.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Label, slider, value: one indented line under its toggle, the same
    /// shape for every slider on the panel.
    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>,
                           step: Double, text: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(minWidth: 52, alignment: .leading)
            Slider(value: value, in: range, step: step) { EmptyView() }
                .accessibilityLabel(label)
                .accessibilityValue(text)
            Text(text)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .trailing)
        }
        .padding(.leading, 26)
    }
}
