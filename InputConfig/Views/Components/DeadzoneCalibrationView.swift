import SwiftUI
import GameController

/// A sheet that lets the user calibrate a binding's deadzone visually.
///
/// Reads live values from whichever controller is currently connected and
/// plots the joystick or trigger position in real time. For paired-axis
/// inputs (left and right thumbsticks) the visualizer is a 2D circle with
/// the current position dot and a trail of recent points so the user can
/// see the joystick's resting drift and full travel. For trigger axes it
/// is a horizontal bar.
///
/// The deadzone slider shows the chosen threshold overlaid on the
/// visualizer. Anything inside the threshold ring is treated as zero by
/// `MappingEngine.checkInput`, so the user can pick a deadzone large
/// enough to suppress drift but small enough to keep full range.
///
/// Works with every controller that GameController framework exposes,
/// which is everything in our supported list (DualSense, DualSense Edge,
/// DualShock 4, Xbox, 8BitDo in Apple mode, and any MFi gamepad).
struct DeadzoneCalibrationView: View {
    /// The 0-based axis index this binding fires on. We use this to pick the
    /// "pair" axis for 2D visualization: 0 pairs with 1 (left stick),
    /// 2 pairs with 3 (right stick), 4 and 5 are 1D triggers.
    let axisIndex: Int

    /// Two-way binding so changes in the slider immediately update the parent
    /// binding model. We store it as a Double so SwiftUI's Slider accepts it
    /// without manual conversion.
    @Binding var deadzone: Double

    /// Outer deadzone (saturation point). Values >= this map to full output.
    /// Defaults to 1.0 (no outer deadzone). When the user shrinks it, the
    /// stick reaches full deflection earlier in its travel.
    @Binding var outerDeadzone: Double

    /// Whether to invert the axis when reading. Mirrors the binding's invert
    /// setting so the visualizer matches what the engine sees.
    let isInverted: Bool

    let onClose: () -> Void

    /// The controller the row reads. Reading slot 0 always showed the
    /// first pad's stick while tuning a row for the second.
    var slot: Int = 0

    @EnvironmentObject var controllerService: GameControllerService

    @State private var currentX: Float = 0
    @State private var currentY: Float = 0
    @State private var trail: [(x: Float, y: Float)] = []
    @State private var maxMagnitude: Float = 0
    @State private var sampleTimer: Timer?

    // Snapshots of the original values, captured on appear. If the user
    // presses Cancel, we restore these so the binding model doesn't keep
    // the experimental slider values.
    /// The sliders move these; Save writes them to the row once. Bound
    /// straight to the row, every tick saved the preset and added an undo
    /// step, and Cancel on an untouched row wrote the 25% it showed.
    @State private var inner: Double = 0.25
    @State private var outer: Double = 1.0
    @State private var hasSnapshot = false

    private let canvasSize: CGFloat = 260
    private let trailLimit = 200

    // MARK: - Axis Pairing

    /// Returns the pair of axes used for visualization based on the binding's axis.
    /// Returns (xAxis, yAxis) for sticks, or (axisIndex, nil) for 1D inputs.
    private var axisPair: (x: Int, y: Int?) {
        switch axisIndex {
        case 0, 1: return (0, 1)            // Left thumbstick X/Y
        case 2, 3: return (2, 3)            // Right thumbstick X/Y
        default:   return (axisIndex, nil)   // Triggers and anything else are 1D
        }
    }

    private var is2D: Bool { axisPair.y != nil }
    /// Only the standard trigger axes run one way; the other single axes
    /// (a trackpad's X, a wheel, a throttle) run both ways from rest.
    private var isTrigger: Bool { axisIndex == 4 || axisIndex == 5 }

    private var title: String {
        switch axisIndex {
        case 0, 1: return "Left Thumbstick Deadzone"
        case 2, 3: return "Right Thumbstick Deadzone"
        case 4:    return "Left Trigger Deadzone"
        case 5:    return "Right Trigger Deadzone"
        default:   return "Axis \(axisIndex) Deadzone"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Title bar
            HStack {
                Image(systemName: "scope")
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.headline)
                Spacer()
                Button("Cancel") { onClose() }
                .buttonStyle(.solidSecondaryCompact)
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    // Only what changed, so an untouched value stays unset.
                    if inner != deadzone { deadzone = inner }
                    if outer != outerDeadzone { outerDeadzone = outer }
                    onClose()
                }
                .buttonStyle(.solidCompact)
                    .keyboardShortcut(.defaultAction)
            }

            Text(is2D
                 ? "Move the joystick all the way around to plot its full range. Set the deadzone large enough that the dot rests inside it without input, but small enough to keep full travel."
                 : isTrigger
                 ? "Press the trigger fully and release. Set the deadzone large enough to ignore any rest-state pressure without losing the bottom of the trigger's range."
                 : "Move the control fully both ways and let go. The bar shows how far it is from rest either way; set the deadzone large enough that it rests inside it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Visualizer
            HStack {
                Spacer()
                if is2D {
                    twoDVisualizer
                } else {
                    triggerVisualizer
                }
                Spacer()
            }

            Divider()

            // Inner deadzone slider
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Inner Deadzone (ignore below)")
                        .font(.subheadline)
                    Spacer()
                    Text(String(format: "%.0f%%", inner * 100))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $inner, in: 0.01...0.9, step: 0.01)
                    .accessibilityLabel("Inner deadzone")
                    .accessibilityValue("\(Int((inner * 100).rounded())) percent")
            }

            // Outer deadzone slider
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Outer Deadzone (saturate above)")
                        .font(.subheadline)
                    Spacer()
                    Text(String(format: "%.0f%%", outer * 100))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $outer, in: max(inner + 0.05, 0.1)...1.0, step: 0.01)
                    .accessibilityLabel("Outer deadzone")
                    .accessibilityValue("\(Int((outer * 100).rounded())) percent")
            }

            // Stats
            HStack(spacing: 20) {
                statBlock("Current", String(format: "%.0f%%", magnitude * 100))
                statBlock("Peak", String(format: "%.0f%%", maxMagnitude * 100))
                statBlock("Inside deadzone", magnitude < Float(inner) ? "Yes" : "No")
                Spacer()
                Button {
                    trail.removeAll()
                    maxMagnitude = 0
                } label: {
                    Label("Reset Trail", systemImage: "arrow.counterclockwise")
                        .font(.caption)
                }
                .buttonStyle(.solidSecondaryCompact)
                .controlSize(.small)
            }
            .padding(.top, 4)

            if controllerService.connectedControllers.isEmpty
                && controllerService.rawHIDGamepadSlots.isEmpty
                && !controllerService.debugMarketingFakeActive {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Connect a controller to see live input.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            if !hasSnapshot {
                inner = deadzone
                outer = outerDeadzone
                hasSnapshot = true
            }
            startSampling()
        }
        .onDisappear(perform: stopSampling)
    }

    // MARK: - 2D Visualizer

    private var twoDVisualizer: some View {
        ZStack {
            // Outer ring
            Circle()
                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1.5)

            // Axis crosshair
            Path { path in
                path.move(to: CGPoint(x: 0, y: canvasSize / 2))
                path.addLine(to: CGPoint(x: canvasSize, y: canvasSize / 2))
                path.move(to: CGPoint(x: canvasSize / 2, y: 0))
                path.addLine(to: CGPoint(x: canvasSize / 2, y: canvasSize))
            }
            .stroke(Color.secondary.opacity(0.15), lineWidth: 1)

            // Inner deadzone ring (red - input ignored inside)
            Circle()
                .fill(Color.red.opacity(0.08))
                .frame(width: CGFloat(inner) * canvasSize, height: CGFloat(inner) * canvasSize)
            Circle()
                .strokeBorder(Color.red.opacity(0.5), lineWidth: 1, antialiased: true)
                .frame(width: CGFloat(inner) * canvasSize, height: CGFloat(inner) * canvasSize)

            // Outer deadzone ring (green - input saturates outside).
            // Only drawn when the user has narrowed it from the default 1.0.
            if outer < 0.99 {
                Circle()
                    .strokeBorder(Color.green.opacity(0.5), lineWidth: 1, antialiased: true)
                    .frame(width: CGFloat(outer) * canvasSize, height: CGFloat(outer) * canvasSize)
            }

            // Trail of recent points
            ForEach(Array(trail.enumerated()), id: \.offset) { index, point in
                let progress = Double(index) / Double(max(1, trail.count - 1))
                Circle()
                    .fill(Color.accentColor.opacity(0.05 + 0.35 * progress))
                    .frame(width: 4, height: 4)
                    .position(x: pointX(point.x), y: pointY(point.y))
            }

            // Current position dot
            Circle()
                .fill(Color.accentColor)
                .frame(width: 12, height: 12)
                .shadow(color: Color.accentColor.opacity(0.5), radius: 4)
                .position(x: pointX(currentX), y: pointY(currentY))
        }
        .frame(width: canvasSize, height: canvasSize)
    }

    private func pointX(_ value: Float) -> CGFloat {
        canvasSize / 2 + CGFloat(value) * canvasSize / 2
    }
    private func pointY(_ value: Float) -> CGFloat {
        // Invert Y so positive points up like a real stick.
        canvasSize / 2 - CGFloat(value) * canvasSize / 2
    }

    // MARK: - Trigger Visualizer

    /// Vertical trigger gauge with both inner deadzone (red band at the
    /// bottom - input below this point is ignored) and outer deadzone
    /// (green band at the top - input above this point saturates to 100%).
    private var triggerVisualizer: some View {
        let barWidth: CGFloat = 90
        let barHeight: CGFloat = 240
        let pulled = CGFloat(max(0, min(1, isTrigger ? currentX : abs(currentX))))
        let inner = CGFloat(max(0, min(1, inner)))
        let outer = CGFloat(max(inner + 0.01, min(1, outer)))

        return HStack(spacing: 16) {
            // Trigger fill gauge
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: barWidth, height: barHeight)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                    )

                // The live fill sits under the two bands, so pulling the
                // trigger never covers the inner and outer deadzones you
                // are setting; the bands stay readable on top of it.
                let belowInner = pulled <= inner
                Rectangle()
                    .fill(Color.accentColor.opacity(belowInner ? 0.30 : 0.55))
                    .frame(width: barWidth, height: barHeight * pulled)
                    .animation(.easeOut(duration: 0.08), value: pulled)

                // Inner deadzone band (bottom - input ignored)
                Rectangle()
                    .fill(Color.red.opacity(0.22))
                    .frame(width: barWidth, height: barHeight * inner)

                // Outer saturation band (top - input clamps to 100%)
                if outer < 0.99 {
                    Rectangle()
                        .fill(Color.green.opacity(0.22))
                        .frame(width: barWidth, height: barHeight * (1 - outer))
                        .offset(y: -(barHeight * outer))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .frame(width: barWidth, height: barHeight)

            // Labels column with live needle. Inline percentages so the
            // numbers can never get pushed off-screen by extreme deadzone
            // values like 90%.
            VStack(alignment: .leading, spacing: 6) {
                labelRow(color: .secondary, text: "100% Top")
                if outer < 0.99 {
                    labelRow(color: .green, text: String(format: "Outer %.0f%%", outer * 100))
                }
                labelRow(color: .red, text: String(format: "Inner %.0f%%", inner * 100))
                labelRow(color: .accentColor, text: String(format: "Current %.0f%%", pulled * 100))
                labelRow(color: .secondary, text: "0% Rest")
                Spacer(minLength: 0)
            }
            .frame(width: 110, height: barHeight, alignment: .topLeading)
        }
        .frame(height: barHeight)
    }

    @ViewBuilder
    private func labelRow(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Rectangle()
                .fill(color.opacity(0.6))
                .frame(width: 8, height: 2)
            Text(text)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(color.opacity(0.85))
                .lineLimit(1)
        }
    }

    // MARK: - Stat helper

    @ViewBuilder
    private func statBlock(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit())
        }
    }

    private var magnitude: Float {
        if is2D {
            return sqrt(currentX * currentX + currentY * currentY)
        } else {
            return abs(currentX)
        }
    }

    // MARK: - Live Sampling

    private func startSampling() {
        sampleTimer?.invalidate()
        // 60Hz is more than enough for visualization without being heavy.
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            Task { @MainActor in sample() }
        }
        if let t = sampleTimer {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    private func stopSampling() {
        sampleTimer?.invalidate()
        sampleTimer = nil
    }

    private func sample() {
        // The slot the row's device group reads, as the engine does.
        guard let state = controllerService.peekControllerState(at: slot) else { return }
        var x: Float = state.axes[axisPair.x] ?? 0
        var y: Float = 0
        if let yAxis = axisPair.y {
            y = state.axes[yAxis] ?? 0
        }
        if isInverted {
            x = -x
            if axisPair.y != nil { y = -y }
        }

        currentX = x
        currentY = y

        let mag = magnitude
        if mag > maxMagnitude { maxMagnitude = mag }

        // Only add to trail if outside the deadzone; otherwise the rest position
        // would spam the trail with overlapping dots.
        if mag > Float(inner) * 0.5 {
            trail.append((x: x, y: y))
            if trail.count > trailLimit { trail.removeFirst(trail.count - trailLimit) }
        }
    }
}
