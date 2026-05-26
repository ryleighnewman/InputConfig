import SwiftUI

/// Identifies which feature the welcome page just opened. Used to drive the
/// `FeatureDemoView` body and to look up the matching example preset.
enum FeatureDemoKind: String, CaseIterable, Identifiable {
    case keyboardMouse
    case midi
    case variableSensitivity
    case deadzone
    case macros
    case haptic
    case speech
    case lightBar
    case controllers
    case touchpad
    case gyro

    var id: String { rawValue }

    /// Stable key used to look up the matching example preset by name.
    var presetKey: String? {
        switch self {
        case .variableSensitivity: return "variable_sensitivity"
        case .deadzone:            return "deadzone"
        case .haptic:              return "haptic"
        case .speech:              return "speech"
        case .macros:              return "macros"
        case .touchpad:            return "touchpad"
        case .midi:                return "midi"
        case .gyro:                return "gyro"
        // No directly-matching showcase preset for these; the button hides.
        case .keyboardMouse, .lightBar, .controllers: return nil
        }
    }

    var title: String {
        switch self {
        case .keyboardMouse:       return "Keyboard & Mouse"
        case .midi:                return "MIDI Output"
        case .variableSensitivity: return "Variable Sensitivity"
        case .deadzone:            return "Deadzone Calibration"
        case .macros:              return "Macros & Turbo"
        case .haptic:              return "Haptic Feedback"
        case .speech:              return "Spoken Feedback"
        case .lightBar:            return "Light Bar Control"
        case .controllers:         return "Wide Controller Support"
        case .touchpad:            return "Touchpad Mouse"
        case .gyro:                return "Gyroscope Motion"
        }
    }

    var explanation: String {
        switch self {
        case .keyboardMouse:
            return "Every button, trigger, and stick can drive any keyboard key, mouse button, mouse motion, or scroll wheel. Bindings happen at the system level so they work in every app on macOS."
        case .midi:
            return "JoystickConfig publishes a virtual CoreMIDI source. Open GarageBand, Logic, Ableton, Reaper, or any DAW; pick JoystickConfig as the input; and the controller starts driving notes, CC, pitch bend, program change, and transport messages."
        case .variableSensitivity:
            return "Joystick depth scales output speed so small deflections give precise control and large deflections accelerate. Three curves are built in: Linear, Smooth (exponential), and Aggressive (square-root)."
        case .deadzone:
            return "Tune the inner deadzone to ignore stick drift and the outer deadzone so you reach full speed without bottoming the stick. The live calibration ring shows your stick position in real time."
        case .macros:
            return "Chain keystrokes with custom timing per step, or set Turbo on any button to rapid-fire it at a configurable rate. Macros can mix any output type, including MIDI."
        case .haptic:
            return "Bindings on DualSense and DualSense Edge can fire haptic feedback when they trigger. Pick an intensity per binding so important actions feel bigger."
        case .speech:
            return "Speak a custom phrase out loud when a binding fires. Choose Mac speakers or, where supported, the controller's built-in speaker."
        case .lightBar:
            return "Set the DualSense light bar to a custom color, dim or bright, or run an RGB cycle. Configured in Settings; runs through a sandboxed helper that uses Sony's HID color report."
        case .controllers:
            return "DualSense, DualSense Edge, DualShock 4, Xbox One / Series, Switch Pro, Joy-Cons, Stadia, 8BitDo Pro 2 / Ultimate / SN30 Pro+, and any MFi gamepad."
        case .touchpad:
            return "DualSense and DualShock 4 touchpad surfaces drive the mouse cursor. The touchpad press still works as a button. Multiple fingers map independently, so finger one can move the cursor while finger two scrolls."
        case .gyro:
            return "Controllers with motion sensors (DualSense, DualSense Edge, DualShock 4, Switch Pro, Joy-Con) expose gyroscope rotation rate, accelerometer, and absolute attitude. Bind any of them like a half-axis. The classic recipe: gyro yaw drives mouse X, gyro pitch drives mouse Y - motion aim, free across every app."
        }
    }
}

/// Modal that opens from a welcome-page card. Shows an animated demo of the
/// feature and (when applicable) a button that loads a matching example
/// preset in the sidebar.
struct FeatureDemoView: View {
    let kind: FeatureDemoKind
    let onJumpToPreset: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Image(systemName: iconName)
                    .font(.system(size: 32))
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind.title)
                        .font(.title3.weight(.semibold))
                    Text(kind.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            Divider()

            demoSurface

            Divider()

            HStack {
                if kind.presetKey != nil {
                    Button {
                        if let key = kind.presetKey,
                           let presetName = ExamplePresets.demoPresetNames[key] {
                            onJumpToPreset(presetName)
                        }
                        dismiss()
                    } label: {
                        Label("Take me to an example preset", systemImage: "arrowshape.right.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 560, height: 460)
    }

    private var tint: Color {
        switch kind {
        case .keyboardMouse:       return .orange
        case .midi:                return .pink
        case .variableSensitivity: return .blue
        case .deadzone:            return .green
        case .macros:              return .yellow
        case .haptic:              return .purple
        case .speech:              return .indigo
        case .lightBar:            return .red
        case .controllers:         return .cyan
        case .touchpad:            return .mint
        case .gyro:                return .teal
        }
    }

    private var iconName: String {
        switch kind {
        case .keyboardMouse:       return "keyboard"
        case .midi:                return "music.note.list"
        case .variableSensitivity: return "slider.horizontal.below.rectangle"
        case .deadzone:            return "scope"
        case .macros:              return "bolt.fill"
        case .haptic:              return "waveform"
        case .speech:              return "speaker.wave.2.fill"
        case .lightBar:            return "light.beacon.max.fill"
        case .controllers:         return "gamecontroller.fill"
        case .touchpad:            return "rectangle.and.hand.point.up.left.fill"
        case .gyro:                return "gyroscope"
        }
    }

    @ViewBuilder
    private var demoSurface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.08))
            switch kind {
            case .keyboardMouse:       KeyboardMouseDemo()
            case .midi:                MidiDemo()
            case .variableSensitivity: VariableSensitivityDemo()
            case .deadzone:            DeadzoneDemo()
            case .macros:              MacrosDemo()
            case .haptic:              HapticDemo()
            case .speech:              SpeechDemo()
            case .lightBar:            LightBarDemo()
            case .controllers:         ControllersDemo()
            case .touchpad:            TouchpadDemo()
            case .gyro:                GyroDemo()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 200)
    }
}

// MARK: - Demo: Keyboard & Mouse

private struct KeyboardMouseDemo: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = t.truncatingRemainder(dividingBy: 4) / 4
            let angle = phase * 2 * .pi
            // Stick thumb traces a slow circle.
            let stickRadius: CGFloat = 28
            let thumbX = cos(angle) * stickRadius
            let thumbY = sin(angle) * stickRadius
            // Cursor mirrors the stick at a larger scale.
            let cursorX = cos(angle) * 90
            let cursorY = sin(angle) * 60

            HStack(spacing: 32) {
                // Stick visualization
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 2)
                        .frame(width: 80, height: 80)
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 18, height: 18)
                        .offset(x: thumbX, y: thumbY)
                    Text("Stick")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .offset(y: 56)
                }
                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)
                // Mouse cursor on a tiny "desktop"
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        .frame(width: 220, height: 140)
                    Image(systemName: "cursorarrow.rays")
                        .font(.title2)
                        .foregroundStyle(.orange)
                        .offset(x: cursorX, y: cursorY)
                }
            }
        }
    }
}

// MARK: - Demo: MIDI

private struct MidiDemo: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let beat = Int(t.truncatingRemainder(dividingBy: 1.6) / 0.2) % 8

            VStack(spacing: 14) {
                Text("Sending to GarageBand")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 3) {
                    // 8 piano-key boxes light up in sequence.
                    ForEach(0..<8, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(i == beat ? Color.pink : Color.secondary.opacity(0.18))
                            .frame(width: 22, height: 56)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(Color.secondary.opacity(0.4), lineWidth: 0.5)
                            )
                            .animation(.easeOut(duration: 0.08), value: beat)
                    }
                }
                HStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .foregroundStyle(.pink)
                    Text("Note \(60 + beat) · CC 1 · Pitch Bend")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Demo: Variable Sensitivity

private struct VariableSensitivityDemo: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // depth oscillates between 0 and 1 over 3 seconds
            let depth = (sin(t / 3 * 2 * .pi) + 1) / 2

            VStack(alignment: .leading, spacing: 10) {
                Text("Input depth: \(String(format: "%.0f%%", depth * 100))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                curveBar(label: "Linear",    color: .gray,  value: Float(depth))
                curveBar(label: "Smooth",    color: .blue,  value: SensitivityCurve.exponential.apply(Float(depth)))
                curveBar(label: "Aggressive", color: .orange, value: SensitivityCurve.aggressive.apply(Float(depth)))
            }
            .padding(.horizontal, 20)
        }
    }

    private func curveBar(label: String, color: Color, value: Float) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption)
                .frame(width: 80, alignment: .leading)
                .foregroundStyle(.secondary)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(color)
                        .frame(width: max(0, CGFloat(abs(value))) * proxy.size.width)
                }
            }
            .frame(height: 14)
            Text(String(format: "%.0f%%", abs(value) * 100))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

// MARK: - Demo: Deadzone

private struct DeadzoneDemo: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // Thumb traces an outward spiral so it crosses both rings.
            let phase = t.truncatingRemainder(dividingBy: 5) / 5
            let radius = phase * 70
            let angle = phase * 4 * .pi
            let x = cos(angle) * radius
            let y = sin(angle) * radius
            let magnitude = radius / 70

            HStack(spacing: 28) {
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        .frame(width: 150, height: 150)
                    // Inner deadzone (red)
                    Circle()
                        .stroke(Color.red.opacity(0.7), lineWidth: 1.5)
                        .frame(width: 30, height: 30)
                    // Outer deadzone (green)
                    Circle()
                        .stroke(Color.green.opacity(0.6), lineWidth: 1.5)
                        .frame(width: 128, height: 128)
                    // Thumb
                    Circle()
                        .fill(Color.green)
                        .frame(width: 12, height: 12)
                        .offset(x: x, y: y)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Inner: 0.20")
                        .font(.caption.monospaced())
                        .foregroundStyle(.red)
                    Text("Outer: 0.85")
                        .font(.caption.monospaced())
                        .foregroundStyle(.green)
                    Divider().frame(width: 100)
                    Text("Raw: \(String(format: "%.0f%%", magnitude * 100))")
                        .font(.caption.monospaced())
                    let remapped = max(0, min(1, (magnitude - 0.2) / (0.85 - 0.2)))
                    Text("Output: \(String(format: "%.0f%%", remapped * 100))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                }
            }
        }
    }
}

// MARK: - Demo: Macros & Turbo

private struct MacrosDemo: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let cyclePos = t.truncatingRemainder(dividingBy: 2.5)

            let events: [(name: String, at: Double, hold: Double)] = [
                ("Cmd",  0.0, 0.6),
                ("C",    0.15, 0.10),
                ("Tab",  0.6, 0.10),
                ("Cmd",  0.9, 0.6),
                ("V",    1.05, 0.10),
            ]

            VStack(alignment: .leading, spacing: 12) {
                Text("Macro: Copy → Switch → Paste")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        // Timeline bar
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.18))
                            .frame(height: 32)
                        // Each event as a coloured block
                        ForEach(0..<events.count, id: \.self) { i in
                            let e = events[i]
                            RoundedRectangle(cornerRadius: 3)
                                .fill(cyclePos >= e.at && cyclePos < e.at + e.hold
                                      ? Color.yellow : Color.yellow.opacity(0.35))
                                .frame(width: CGFloat(e.hold / 2.5) * proxy.size.width,
                                       height: 32)
                                .offset(x: CGFloat(e.at / 2.5) * proxy.size.width)
                                .overlay(
                                    Text(e.name)
                                        .font(.caption2.monospaced())
                                        .offset(x: CGFloat(e.at / 2.5) * proxy.size.width + 4, y: 0),
                                    alignment: .topLeading
                                )
                        }
                        // Playhead
                        Rectangle()
                            .fill(Color.red)
                            .frame(width: 2, height: 32)
                            .offset(x: CGFloat(cyclePos / 2.5) * proxy.size.width)
                    }
                }
                .frame(height: 32)
                Text("Turbo: spacebar at 12 Hz while held")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 3) {
                    ForEach(0..<24, id: \.self) { i in
                        let on = (Int(t * 12) + i) % 2 == 0
                        Rectangle()
                            .fill(on ? Color.yellow : Color.yellow.opacity(0.2))
                            .frame(width: 8, height: 12)
                    }
                }
            }
            .padding(.horizontal, 18)
        }
    }
}

// MARK: - Demo: Haptic Feedback

private struct HapticDemo: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = (sin(t * 6) + 1) / 2

            VStack(spacing: 12) {
                Text("Vibration intensity")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // 32-bar EQ-style waveform showing pulse intensity.
                HStack(alignment: .center, spacing: 3) {
                    ForEach(0..<32, id: \.self) { i in
                        let phase = (Double(i) / 32 + t * 1.5).truncatingRemainder(dividingBy: 1)
                        let h = (sin(phase * 2 * .pi) + 1) / 2
                        let height = max(6, CGFloat(h) * CGFloat(pulse) * 80)
                        Capsule()
                            .fill(Color.purple)
                            .frame(width: 4, height: height)
                    }
                }
                .frame(height: 80)
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.title2)
                    .foregroundStyle(.purple.opacity(0.6))
            }
        }
    }
}

// MARK: - Demo: Spoken Feedback

private struct SpeechDemo: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let cycle = Int(t.truncatingRemainder(dividingBy: 6) / 1.5) % 4
            let phrase = ["Reload", "Ready", "Cover me", "Push forward"][cycle]

            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "speaker.wave.3.fill")
                        .font(.title)
                        .foregroundStyle(.indigo)
                    Text("“\(phrase)”")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.primary)
                        .id(phrase)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.4), value: phrase)
                }
                HStack(spacing: 4) {
                    ForEach(0..<26, id: \.self) { i in
                        let phase = (Double(i) / 26 + t * 2).truncatingRemainder(dividingBy: 1)
                        let h = (sin(phase * 2 * .pi) + 1) / 2
                        Capsule()
                            .fill(Color.indigo.opacity(0.7))
                            .frame(width: 3, height: max(4, CGFloat(h) * 40))
                    }
                }
                .frame(height: 40)
            }
        }
    }
}

// MARK: - Demo: Light Bar

private struct LightBarDemo: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let hue = t.truncatingRemainder(dividingBy: 6) / 6
            let color = Color(hue: hue, saturation: 0.85, brightness: 1)

            HStack(spacing: 24) {
                // DualSense silhouette + light bar
                ZStack {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 96))
                        .foregroundStyle(.secondary.opacity(0.5))
                    // Light bar bar (drawn over the controller)
                    Capsule()
                        .fill(color)
                        .frame(width: 60, height: 8)
                        .blur(radius: 4)
                        .offset(y: -8)
                    Capsule()
                        .fill(color)
                        .frame(width: 50, height: 4)
                        .offset(y: -8)
                }
                // Hue ring
                ZStack {
                    ForEach(0..<24, id: \.self) { i in
                        let h = Double(i) / 24
                        Rectangle()
                            .fill(Color(hue: h, saturation: 0.85, brightness: 1))
                            .frame(width: 6, height: 18)
                            .offset(y: -50)
                            .rotationEffect(.degrees(Double(i) * 15))
                    }
                    Circle()
                        .stroke(color, lineWidth: 2)
                        .frame(width: 80, height: 80)
                }
            }
        }
    }
}

// MARK: - Demo: Wide Controller Support

private struct ControllersDemo: View {
    private let entries: [(symbol: String, name: String)] = [
        ("gamecontroller.fill", "DualSense"),
        ("gamecontroller.fill", "Xbox"),
        ("gamecontroller.fill", "Switch Pro"),
        ("gamecontroller.fill", "8BitDo Pro 2"),
        ("gamecontroller.fill", "Stadia"),
        ("gamecontroller.fill", "DualShock 4"),
    ]

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let active = Int(t.truncatingRemainder(dividingBy: Double(entries.count) * 1.0))

            VStack(spacing: 12) {
                HStack(spacing: 18) {
                    ForEach(0..<entries.count, id: \.self) { i in
                        let isActive = i == active
                        VStack(spacing: 6) {
                            Image(systemName: entries[i].symbol)
                                .font(.system(size: isActive ? 30 : 22))
                                .foregroundStyle(isActive ? Color.cyan : Color.secondary.opacity(0.6))
                            Text(entries[i].name)
                                .font(.caption2)
                                .foregroundStyle(isActive ? .primary : .secondary)
                        }
                        .animation(.easeInOut(duration: 0.3), value: isActive)
                    }
                }
                Text("...plus any MFi gamepad")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Demo: Gyroscope Motion

private struct GyroDemo: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // Yaw oscillates left/right; pitch traces a slower curve; roll
            // adds a third axis of motion so the 3D model shows off all
            // three rotations. Each phase has a different period so the
            // demo never repeats a static-looking instant.
            let yaw   = Float(sin(t / 3.5 * 2 * .pi))   // -1...1
            let pitch = Float(sin(t / 2.2 * 2 * .pi))   // -1...1
            let roll  = Float(sin(t / 4.1 * 2 * .pi))   // -1...1

            // Cursor mirror on the right: lags slightly so it looks like
            // the controller is "driving" the cursor.
            let cursorX = CGFloat(yaw) * 90
            let cursorY = CGFloat(pitch) * 55

            HStack(spacing: 24) {
                // Shared 3D gyro model. Magnitudes are scaled so the demo
                // looks lively without spinning too aggressively.
                GyroVisualizationView(
                    gyroX: pitch * 1.2,
                    gyroY: yaw * 1.2,
                    gyroZ: roll * 0.8,
                    rollAngle: roll * 0.35,
                    pitchAngle: pitch * 0.35,
                    yawAngle: yaw * 0.45,
                    mode: .large
                )

                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)

                // Cursor that mirrors the controller's tilt - the runtime
                // effect when you bind gyro to mouse motion.
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        .frame(width: 220, height: 140)
                    // Crosshair grid
                    Path { p in
                        p.move(to: CGPoint(x: 110, y: 0))
                        p.addLine(to: CGPoint(x: 110, y: 140))
                        p.move(to: CGPoint(x: 0, y: 70))
                        p.addLine(to: CGPoint(x: 220, y: 70))
                    }
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)

                    Image(systemName: "cursorarrow.rays")
                        .font(.title2)
                        .foregroundStyle(.teal)
                        .offset(x: cursorX, y: cursorY)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

// MARK: - Demo: Touchpad Mouse

private struct TouchpadDemo: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // Finger traces a figure-8 across the trackpad.
            let p = t.truncatingRemainder(dividingBy: 3) / 3
            let theta = p * 2 * .pi
            let fingerX = CGFloat(sin(theta)) * 80
            let fingerY = CGFloat(sin(theta * 2)) * 25
            // Cursor mirrors the finger but stays inside the small desktop
            // rect on the right (200×120). A 1:1 X mapping plus a slight Y
            // bump keeps it visibly bounded without clipping.
            let cursorX = fingerX
            let cursorY = fingerY * 1.4

            HStack(spacing: 24) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.mint.opacity(0.5), lineWidth: 1.5)
                        .frame(width: 200, height: 90)
                    // Faint trail
                    ForEach(0..<8, id: \.self) { i in
                        let lag = Double(i) * 0.04
                        let lagTheta = (p - lag) * 2 * .pi
                        let lx = CGFloat(sin(lagTheta)) * 80
                        let ly = CGFloat(sin(lagTheta * 2)) * 25
                        Circle()
                            .fill(Color.mint.opacity(0.15 + 0.05 * Double(8 - i)))
                            .frame(width: 14 - CGFloat(i) * 1.2, height: 14 - CGFloat(i) * 1.2)
                            .offset(x: lx, y: ly)
                    }
                    Circle()
                        .fill(Color.mint)
                        .frame(width: 16, height: 16)
                        .offset(x: fingerX, y: fingerY)
                    Text("Touchpad")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .offset(y: 60)
                }
                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        .frame(width: 200, height: 120)
                    Image(systemName: "cursorarrow.rays")
                        .font(.title2)
                        .foregroundStyle(.mint)
                        .offset(x: cursorX, y: cursorY)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
