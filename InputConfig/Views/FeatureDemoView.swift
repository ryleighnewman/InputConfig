import SwiftUI

/// Identifies which feature the welcome page just opened. Used to drive the
/// `FeatureDemoView` body and to look up the matching example preset.
enum FeatureDemoKind: String, CaseIterable, Identifiable {
    // Ordered as a guided tour: the core idea first, then tuning, then
    // advanced mapping, then alternate inputs, feedback, the controller LED,
    // creative MIDI output, per-preset automation, and finally usage stats.
    case keyboardMouse
    case controllers
    case chassisTap
    case variableSensitivity
    case deadzone
    case toggleMode
    case macros
    case stackedOutputs
    case touchpad
    case touchpadRegions
    case gyro
    case haptic
    case speech
    case lightBar
    case midiInput
    case systemControl
    case siriShortcuts
    case inputRemap
    case macTrackpad
    case modifierHolds
    case holdDoubleTap
    case appAutoSwitch
    case cursorRegions
    case midi
    case midiCC
    case autoLaunch
    case stats

    var id: String { rawValue }

    /// Stable key used to look up the matching example preset by name.
    var presetKey: String? {
        switch self {
        case .chassisTap:          return "chassis_tap"
        case .variableSensitivity: return "variable_sensitivity"
        case .deadzone:            return "deadzone"
        case .haptic:              return "haptic"
        case .speech:              return "speech"
        case .macros:              return "macros"
        case .touchpad:            return "touchpad"
        case .touchpadRegions:     return "touchpad_regions"
        case .midi:                return "midi"
        case .gyro:                return "gyro"
        case .toggleMode:          return "toggle_mode"
        case .stackedOutputs:      return "stacked_outputs"
        case .autoLaunch:          return "auto_launch"
        case .midiCC:              return "midi_cc"
        case .midiInput:           return "midi_input"
        case .systemControl:       return "system_control"
        case .keyboardMouse:       return "keyboard_mouse"
        case .siriShortcuts:       return "siri_shortcuts"
        case .inputRemap:          return "input_remap"
        case .macTrackpad:         return "mac_trackpad"
        case .modifierHolds:       return "modifier_holds"
        case .holdDoubleTap:       return "hold_double_tap"
        case .appAutoSwitch:       return "app_auto_switch"
        case .cursorRegions:       return "cursor_regions"
        case .lightBar:            return "light_bar"
        // These two are not a preset: the controllers card opens a layout
        // for whatever is connected, and the statistics card opens Statistics.
        case .controllers, .stats: return nil
        }
    }

    /// What the demo's call-to-action button does. Every card lands on a
    /// preset that shows the feature, except the controllers card (a layout
    /// for whatever is connected) and the statistics card.
    enum CTA: Equatable {
        case preset(String)     // jump to the example preset with this display name
        case controllerPreset   // jump to the layout that matches the connected controller
        case statistics         // open the Statistics dashboard
        case settings           // open Settings (nothing uses this now)
    }
    var cta: CTA {
        switch self {
        case .stats:       return .statistics
        case .controllers: return .controllerPreset
        default:
            if let key = presetKey, let name = ExamplePresets.demoPresetNames[key] {
                return .preset(name)
            }
            return .settings
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
        case .touchpadRegions:     return "Touchpad Zones"
        case .gyro:                return "Gyroscope Motion"
        case .stats:               return "Lifetime Statistics"
        case .toggleMode:          return "Toggle Mode"
        case .stackedOutputs:      return "Stacked Outputs"
        case .autoLaunch:          return "Auto-Launch + Cursor Confine"
        case .midiCC:              return "MIDI CC Dials"
        case .midiInput:           return "MIDI Devices as Input"
        case .systemControl:       return "System Functions"
        case .siriShortcuts:       return "Siri Shortcuts"
        case .inputRemap:          return "Mac Keyboard as Input"
        case .macTrackpad:         return "Trackpad & Magic Mouse"
        case .modifierHolds:       return "Modifier Holds"
        case .holdDoubleTap:       return "Hold & Double-Tap"
        case .appAutoSwitch:       return "Per-App Auto-Switch"
        case .chassisTap:          return "Tap the Mac"
        case .cursorRegions:       return "Cursor Regions"
        }
    }

    /// The order of the cards on the home page, which is the order the
    /// demo sheet's arrows walk through.
    static let tourOrder: [FeatureDemoKind] = [
        .keyboardMouse, .controllers, .chassisTap, .midiInput, .midi, .systemControl,
        .siriShortcuts, .inputRemap, .macTrackpad, .modifierHolds, .variableSensitivity, .deadzone, .toggleMode, .macros,
        .stackedOutputs, .holdDoubleTap, .appAutoSwitch, .autoLaunch, .touchpad, .touchpadRegions, .gyro,
        .cursorRegions, .haptic, .speech, .midiCC, .stats, .lightBar,
    ]

    /// The explanation as short dash points, one sentence each.
    var points: [String] {
        explanation
            .replacingOccurrences(of: "e.g. ", with: "e.g.\u{00A0}")
            .components(separatedBy: ". ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
            .map { $0.replacingOccurrences(of: "e.g.\u{00A0}", with: "e.g. ") }
    }

    var explanation: String {
        switch self {
        case .keyboardMouse:
            return "Every button, trigger, and stick can drive any keyboard key, mouse button, mouse motion, or scroll wheel. Bindings happen at the system level so they work in every app on macOS."
        case .midi:
            return "InputConfig publishes a virtual CoreMIDI source. Open GarageBand, Logic, Ableton, Reaper, or any DAW; pick InputConfig as the input; and the controller starts driving notes, CC, pitch bend, program change, and transport messages."
        case .variableSensitivity:
            return "Trigger pressure and joystick depth scale output speed so light inputs give precise control and full presses accelerate. Three response curves are built in: Linear, Smooth (exponential), and Aggressive (square-root). Pick per binding for how you want triggers and sticks to feel - racing-game throttle vs. FPS aim vs. instant-snap menu navigation."
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
        case .touchpadRegions:
            return "Carve the DualSense touchpad into zones and each one is a soft button: touch it and a binding fires. Four corners for undo, redo, copy, and paste; three columns for flashcard ratings; a strip of hotbar slots. Zones carry every option a button does, including a haptic pulse so you can feel the one you hit. Draw them in Calibrate Touchpad and bind them like anything else."
        case .gyro:
            return "Controllers with motion sensors (DualSense, DualSense Edge, DualShock 4, Switch Pro, Joy-Con) expose gyroscope rotation rate, accelerometer, and absolute attitude. Bind any of them like a half-axis. The classic recipe: gyro yaw drives mouse X, gyro pitch drives mouse Y - motion aim, free across every app."
        case .stats:
            return "Every button press, mouse motion, scroll tick, MIDI event, and macro execution is counted locally. The Statistics window shows your most-used inputs and presets, daily connection history, and total time spent mapping. Nothing is sent over the network - the entire dataset lives in your sandbox container."
        case .toggleMode:
            return "Flip a binding from 'hold while pressed' to 'press once to latch on, press again to release'. Perfect for sticky modifiers (Shift / Cmd that you can park), push-to-talk that you can leave on, or auto-run W in any game."
        case .stackedOutputs:
            return "Wire one input to multiple outputs in parallel - a key AND a mouse click AND a MIDI note AND a spoken phrase, all firing simultaneously. Different from a macro (which is a sequence with delays); stacked outputs are simpler to debug and faster to author."
        case .autoLaunch:
            return "Each preset has its own Automation & Gaming Utilities panel. Activating the preset can auto-launch an app (e.g. Steam, your DAW, a specific game), confine the cursor away from screen edges, auto-recenter it, and hide the system pointer - all turned off when you deactivate. Per-game settings, never global."
        case .siriShortcuts:
            return "Any input can run any Shortcut from the Shortcuts app, by name: toggle Do Not Disturb, set a smart-home scene, start a timer, log a workout - entire automations on one pad or button. Shortcuts run in the background without stealing focus, and the binding editor lists your installed Shortcuts so there is nothing to type. Open App and Open URL outputs live in the same menu for launching anything else."
        case .inputRemap:
            return "The Mac's own keyboard is an input, not just an output. Every key binds like a controller button: the letters, the modifiers on each side, the top row's brightness, media, and volume keys, and F13 to F19 on a full-size keyboard. The Live Visualizer draws the keyboard and lights each key as you press it. InputConfig listens alongside macOS, so a key keeps doing what it did; the spare keys are the ones to bind."
        case .macTrackpad:
            return "The trackpad and Magic Mouse are inputs too. Clicks, two-finger clicks, the side and middle buttons, scrolling in four directions, a double click, a scroll gesture from the moment fingers touch until momentum stops, and the trackpad's force click all bind to anything. The Live Visualizer draws the mouse and the pad and shows every one of them as it happens."
        case .modifierHolds:
            return "A modifier key can carry a second job without losing its first. With no output on the plain press, Command, Option, and Shift keep working in every shortcut; only a long hold on its own, or a double tap, fires something: hold Right Command for Spotlight, double tap it for Launchpad, hold Right Option for Dictation, hold Right Shift for Mission Control. The hold time and double tap window are set per row."
        case .holdDoubleTap:
            return "Every binding can carry three actions: press, hold, and double-tap each fire their own outputs, with an adjustable hold threshold and double-tap window per binding. One controller button becomes jump on tap, sprint on hold, and inventory on double-tap."
        case .appAutoSwitch:
            return "Presets can activate themselves when a chosen app comes to the front: the game preset in the game, the DAW preset in your DAW, the browsing preset everywhere else. Add bundle identifiers in the editor's Automation panel, flip the global toggle in Settings, and InputConfig does the switching for you."
        case .chassisTap:
            return "Your MacBook has a motion sensor inside it, and InputConfig can feel you knock on the case. Tap the palm rest or the lid with a fingertip: taps close together count as one gesture, from a single up to a quintuple, and a pause starts a new count. It is the only input that needs no hardware at all, so it works with nothing plugged in. Typing is ignored on purpose, so working at the keyboard never sets it off."
        case .cursorRegions:
            return "Draw regions on the screen that act as inputs: the cursor entering one can press keys, run macros, or fire any other output. Pair with stick- or gyro-driven cursor movement for dwell-free, gaze-style control, or park hot corners anywhere you like."
        case .systemControl:
            return "Bind any input to a system function: volume up and down, mute, play / pause and track skip, screen brightness, Mission Control, Launchpad, Spotlight, lock screen, the screenshot toolbar - or run one of your Siri Shortcuts, open any app, or open any URL. Pair them with Turn-mode knobs and a MIDI encoder becomes a hardware volume or brightness dial."
        case .midiInput:
            return "Plug in any MIDI keyboard, pad controller, or knob box and use it to drive your Mac, with no game controller connected. Notes and pads act like buttons. Knobs get three modes: Switch fires past halfway, Dial speeds up the further you turn from center, and Turn fires a nudge per step in either direction. Pair a knob with the System Volume output and it becomes a hardware volume fader: position equals level, and it only takes over once you actually move it."
        case .midiCC:
            return "Bind axes (sticks, triggers) to continuous MIDI Control Change values. Sticks become soft modulation knobs for filter cutoff, expression, channel volume, pan, anything CC-mappable in your DAW. Different from MIDI Notes - CC sends a 0-127 value every poll, perfect for sweeps and automation."
        }
    }
}

/// Modal that opens from a welcome-page card. Shows an animated demo of the
/// feature and (when applicable) a button that loads a matching example
/// preset in the sidebar.
struct FeatureDemoView: View {
    let kind: FeatureDemoKind
    let onJumpToPreset: (String) -> Void
    let onOpenStatistics: () -> Void
    let onOpenSettings: () -> Void
    /// The example layout that matches the controller connected right now,
    /// for the Wide Controller Support card.
    var presetForConnectedController: () -> String = { "FPS (PS5 DualSense)" }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The showcase on screen. Starts at the card that opened the sheet;
    /// the arrows walk the home page's order and wrap around.
    @State private var current: FeatureDemoKind?
    /// Which way the last step went, so the content slides that way.
    @State private var stepForward = true
    /// True while the content is faded out between two showcases. The
    /// outgoing content fades and drifts first; the next showcase is built
    /// while nothing is visible, so its first layout never stalls a frame
    /// that the eye can see; then it drifts in from the other side.
    @State private var swapping = false
    /// True from the moment the next showcase is in place until it has
    /// drifted in, so it starts on the far side rather than where the old
    /// one left.
    @State private var staged = false

    private var shown: FeatureDemoKind { current ?? kind }
    private var tourIndex: Int { FeatureDemoKind.tourOrder.firstIndex(of: shown) ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header. The title row is a fixed height and pinned to the
            // top, so the title is in the same place on every card. The
            // points sit in a fixed box under it and are centred in it, so
            // a card with one line and a card with three both read as one
            // block rather than text hugging the title or the divider.
            VStack(alignment: .leading, spacing: 0) {
                // The icon lives in a fixed 44 pt slot, at one point size,
                // so every title starts at the same x whatever the symbol's
                // own width. The slot is clipped so a wide symbol cannot
                // push the title either.
                HStack(spacing: 16) {
                    IconView(name: iconName, glyphHeight: 24)
                        .font(.system(size: 28))
                        .iconTint(tint)
                        .frame(width: 44, height: 44)
                        .clipped()
                    Text(shown.title)
                        .font(.title3.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .frame(height: 44)
                // The points are centred in the band between the title's
                // bottom and the top of the grey box, exactly that band: no
                // spacing is added below, so the box begins where the band
                // ends.
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(shown.points.enumerated()), id: \.offset) { _, point in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("-")
                                .accessibilityHidden(true)
                                .foregroundStyle(.tertiary)
                            Text(point)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 60)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 104)
            }
            .id(shown)
            .compositingGroup()
            .modifier(SlideSwap(swapping: swapping, staged: staged, forward: stepForward, reduceMotion: reduceMotion))
            .frame(height: 148, alignment: .top)
            .padding(.bottom, -14)   // the band ends at the box: no gap

            // The demo, with an arrow on each side to step to the neighbour
            // showcase. Fills the space between the header and the buttons.
            demoSurface
                .id(shown)
                .compositingGroup()
                .modifier(SlideSwap(swapping: swapping, staged: staged, forward: stepForward, reduceMotion: reduceMotion))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .leading) { arrow(forward: false) }
                .overlay(alignment: .trailing) { arrow(forward: true) }

            HStack {
                Button("Close") { dismiss() }
                    .buttonStyle(.solidSecondary)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text("\(tourIndex + 1) of \(FeatureDemoKind.tourOrder.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Showcase \(tourIndex + 1) of \(FeatureDemoKind.tourOrder.count)")
                Spacer()
                ctaButton
                    .focusEffectDisabled()
            }
        }
        .padding(22)
        .frame(width: 560, height: 500)
        // Left and right arrow keys step too.
        .background {
            Group {
                Button("") { step(forward: false) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { step(forward: true) }.keyboardShortcut(.rightArrow, modifiers: [])
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    private func step(forward: Bool) {
        let order = FeatureDemoKind.tourOrder
        let next = (tourIndex + (forward ? 1 : order.count - 1)) % order.count
        guard !swapping else { return }
        stepForward = forward
        if reduceMotion {
            current = order[next]
            return
        }
        // Out, swap while invisible, in.
        withAnimation(.easeIn(duration: 0.12)) { swapping = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) {
                current = order[next]
                staged = true
            }
            withAnimation(.easeOut(duration: 0.22)) { swapping = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { staged = false }
        }
    }

    /// A round chevron floating at the edge of the demo.
    private func arrow(forward: Bool) -> some View {
        Button {
            step(forward: forward)
        } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(.regularMaterial))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .padding(8)
        .help(forward ? "Next showcase" : "Previous showcase")
        .accessibilityLabel(forward ? "Next showcase" : "Previous showcase")
    }

    /// The call-to-action button. Closing the demo sheet and presenting the
    /// destination is the parent's job (see ContentView), so these only invoke
    /// the relevant closure; the parent dismisses then routes.
    @ViewBuilder
    /// One style and one width for every card, so the button is in the
    /// same place whichever showcase is up. The labels vary; the button
    /// does not.
    private var ctaButton: some View {
        let label: (String, String)
        let action: () -> Void
        switch shown.cta {
        case .preset(let name):
            label = ("Open \(name)", "arrowshape.right.fill")
            action = { onJumpToPreset(name) }
        case .controllerPreset:
            // Named after the example that matches the connected pad, so the
            // button says exactly what it opens.
            let name = presetForConnectedController()
            label = ("Open \(name)", "arrowshape.right.fill")
            action = { onJumpToPreset(name) }
        case .statistics:
            label = ("Open Statistics", "chart.bar.fill")
            action = { onOpenStatistics() }
        case .settings:
            label = ("Open Settings", "gearshape.fill")
            action = { onOpenSettings() }
        }
        // The same solid button as everywhere else in the app, tinted for
        // the card; nothing special-cased about it.
        return Button(action: action) {
            Label(label.0, systemImage: label.1)
                .lineLimit(1)
        }
        .buttonStyle(SolidButton(tint: tint))
    }

    private var tint: Color {
        switch shown {
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
        case .touchpadRegions:     return .orange
        case .gyro:                return .teal
        case .stats:               return .brown
        case .toggleMode:          return .orange
        case .stackedOutputs:      return .blue
        case .autoLaunch:          return .green
        case .midiCC:              return .purple
        case .midiInput:           return .pink
        case .systemControl:       return .teal
        case .siriShortcuts:       return .indigo
        case .inputRemap:          return .orange
        case .macTrackpad:         return .mint
        case .modifierHolds:       return .indigo
        case .holdDoubleTap:       return .blue
        case .appAutoSwitch:       return .green
        case .chassisTap:          return .mint
        case .cursorRegions:       return .purple
        }
    }

    private var iconName: String {
        switch shown {
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
        case .touchpadRegions:     return "rectangle.split.2x2.fill"
        case .gyro:                return "gyroscope"
        case .stats:               return "chart.bar.fill"
        case .toggleMode:          return "switch.2"
        case .stackedOutputs:      return "square.stack.3d.up.fill"
        case .autoLaunch:          return "app.badge.fill"
        case .midiCC:              return "dial.high.fill"
        case .midiInput:           return "pianokeys"
        case .systemControl:       return "gearshape.2.fill"
        case .siriShortcuts:       return "sparkles.rectangle.stack.fill"
        case .inputRemap:          return "keyboard.badge.ellipsis"
        case .macTrackpad:         return "rectangle.and.hand.point.up.left.fill"
        case .modifierHolds:       return "command"
        case .holdDoubleTap:       return "hand.tap.fill"
        case .appAutoSwitch:       return "app.connected.to.app.below.fill"
        case .chassisTap:          return "hand.tap.fill"
        case .cursorRegions:       return "rectangle.dashed"
        }
    }

    @ViewBuilder
    private var demoSurface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.08))
            // Keep every demo clear of the arrows that float at the edges:
            // the content gets the middle, the arrows get the margins.
            Group {
            switch shown {
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
            case .touchpadRegions:     TouchpadRegionsDemo()
            // The horizon ball plus its three readouts run taller than the
            // surface; scaled to fit with room under the Z line.
            case .gyro:                GyroDemo()
            case .stats:               StatsDemo()
            case .toggleMode:          ToggleModeDemo()
            case .stackedOutputs:      StackedOutputsDemo()
            case .autoLaunch:          AutoLaunchDemo()
            case .midiCC:              MidiCCDemo()
            case .midiInput:           MidiInputDemo()
            case .systemControl:       SystemControlDemo()
            case .siriShortcuts:       SiriShortcutsDemo()
            case .inputRemap:          InputRemapDemo()
            case .macTrackpad:         MacTrackpadDemo()
            case .modifierHolds:       ModifierHoldsDemo()
            case .holdDoubleTap:       HoldDoubleTapDemo()
            case .appAutoSwitch:       AppAutoSwitchDemo()
            case .chassisTap:          ChassisTapDemo()
            case .cursorRegions:       CursorRegionsDemo()
            }
            }
            .padding(.horizontal, 46)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 200)
    }
}

// MARK: - Shared demo building blocks

/// Compact "input button" widget that visibly depresses when `pressed` is
/// true. Shared across the demos that follow the `input → arrow → output`
/// pattern so every visualization tells the same story consistently.
@ViewBuilder
private func inputBlock(label: String, pressed: Bool, tint: Color) -> some View {
    VStack(spacing: 6) {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(pressed ? tint.opacity(0.6) : Color.secondary.opacity(0.18))
            RoundedRectangle(cornerRadius: 12)
                .stroke(pressed ? tint : Color.secondary.opacity(0.4),
                        lineWidth: pressed ? 2 : 1)
            Image(systemName: "circle.fill")
                .font(.system(size: pressed ? 22 : 26))
                .foregroundStyle(pressed ? .white : tint.opacity(0.7))
        }
        .frame(width: 56, height: 56)
        .scaleEffect(pressed ? 0.92 : 1)
        .animation(.easeOut(duration: 0.08), value: pressed)

        Text(label)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
    .frame(width: 70)
}

/// Horizontal arrow with a flowing gradient that brightens when `active`
/// is true. Visually conveys "input traveling to output" across the demo.
/// A struct (not a free func) so it can read the Reduce Motion setting.
private struct GradientArrow: View {
    @Environment(\.appReduceMotion) private var appReduceMotion
    let active: Bool
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
    TimelineView(.animation(paused: reduceMotion || appReduceMotion)) { context in
        let t = context.date.timeIntervalSinceReferenceDate
        let flow = active ? (sin(t * 4) + 1) / 2 : 0.0

        HStack(spacing: 0) {
            // Tail: a thin bar with the moving gradient.
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.12))
                    .frame(height: 6)
                Capsule()
                    .fill(LinearGradient(
                        colors: [tint.opacity(0.2),
                                 tint.opacity(0.4 + flow * 0.5),
                                 tint.opacity(0.8 + flow * 0.2)],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: active ? 70 : 0, height: 6)
                    .animation(.easeOut(duration: 0.15), value: active)
            }
            .frame(width: 70)
            // Head: arrowhead that fades in when active.
            Image(systemName: "arrowtriangle.right.fill")
                .foregroundStyle(active ? tint : tint.opacity(0.25))
                .font(.system(size: 18))
                .scaleEffect(active ? 1 : 0.85)
        }
        .frame(width: 90)
    }
    }
}

/// Call-site shim so existing `gradientArrow(active:tint:)` uses keep working.
@ViewBuilder
private func gradientArrow(active: Bool, tint: Color) -> some View {
    GradientArrow(active: active, tint: tint)
}

// MARK: - Demo: Keyboard & Mouse

private struct KeyboardMouseDemo: View {
    @Environment(\.appReduceMotion) private var appReduceMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One loop: the stick steers the cursor, then three controls fire in
    /// turn and the Mac answers each with a key, a click, or a scroll.
    private let loop: Double = 6.0

    var body: some View {
        TimelineView(.animation(paused: reduceMotion || appReduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: loop)
            // Beats: 0-2.4 stick and cursor, 2.4-3.6 Cross = Space,
            // 3.6-4.8 R2 = click, 4.8-6.0 right stick = scroll.
            let steering = t < 2.4
            let beat = steering ? 0 : 1 + Int((t - 2.4) / 1.2)
            let inBeat = steering ? t / 2.4 : ((t - 2.4).truncatingRemainder(dividingBy: 1.2)) / 1.2
            let pressed = !steering && inBeat < 0.5
            let ripple = pressed ? inBeat / 0.5 : 1

            // Stick sweeps once round while steering, then rests centred.
            let angle = steering ? inBeat * 2 * .pi : 0
            let thumbX = steering ? cos(angle) * 12 : 0
            let thumbY = steering ? sin(angle) * 12 : 0
            let cursorX = steering ? cos(angle) * 56 : 56
            let cursorY = steering ? sin(angle) * 32 : 0
            // Right stick nudges up while scrolling, and the page rows slide.
            let rightY: CGFloat = (beat == 3 && pressed) ? -10 : 0
            let scrollShift: CGFloat = beat == 3 ? CGFloat(inBeat) * 18 : 0

            HStack(spacing: 22) {
                // A controller face: sticks, a shoulder, and the face buttons.
                ZStack {
                    RoundedRectangle(cornerRadius: 22)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1.5)
                        .frame(width: 170, height: 96)
                    // R2, the shoulder that clicks.
                    Capsule()
                        .fill(Color.orange.opacity(beat == 2 && pressed ? 0.9 : 0.18))
                        .frame(width: 34, height: 9)
                        .offset(x: 58, y: -52)
                    Text("R2").font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(beat == 2 && pressed ? Color.white : Color.secondary)
                        .offset(x: 58, y: -52)
                    // Left stick.
                    Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 1.5).frame(width: 36, height: 36)
                        .offset(x: -50, y: 2)
                    Circle().fill(steering ? Color.orange : Color.secondary.opacity(0.5)).frame(width: 14, height: 14)
                        .offset(x: -50 + thumbX, y: 2 + thumbY)
                    // Right stick, used for scrolling.
                    Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 1.5).frame(width: 30, height: 30)
                        .offset(x: 18, y: 22)
                    Circle().fill(beat == 3 && pressed ? Color.orange : Color.secondary.opacity(0.5)).frame(width: 12, height: 12)
                        .offset(x: 18, y: 22 + rightY)
                    // Face buttons; Cross (bottom) is the one that types.
                    ForEach(0..<4, id: \.self) { k in
                        let pos: [CGPoint] = [CGPoint(x: 58, y: -16), CGPoint(x: 72, y: -2), CGPoint(x: 58, y: 12), CGPoint(x: 44, y: -2)]
                        let lit = k == 2 && beat == 1 && pressed
                        Circle()
                            .fill(lit ? Color.orange : Color.secondary.opacity(0.22))
                            .frame(width: 12, height: 12)
                            .offset(x: pos[k].x, y: pos[k].y)
                    }
                    Text("Controller")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .offset(y: 60)
                }
                .frame(width: 170, height: 106)

                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)

                // The Mac: a small screen with the cursor, a page that
                // scrolls, a click ripple, and a key that lights.
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        .frame(width: 170, height: 106)
                    // Page rows that slide when the right stick scrolls.
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(0..<7, id: \.self) { r in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.secondary.opacity(0.14))
                                .frame(width: r % 3 == 2 ? 70 : 110, height: 5)
                        }
                    }
                    .offset(x: -14, y: -scrollShift)
                    .frame(width: 170, height: 106)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    // Click ripple at the cursor.
                    if beat == 2 && pressed {
                        Circle()
                            .stroke(Color.orange.opacity(0.9 * (1 - ripple)), lineWidth: 2)
                            .frame(width: 8 + 34 * ripple, height: 8 + 34 * ripple)
                            .offset(x: cursorX, y: cursorY)
                    }
                    Image(systemName: beat == 2 && pressed ? "cursorarrow.click.2" : "cursorarrow")
                        .font(.title3)
                        .iconTint(.orange)
                        .offset(x: cursorX, y: cursorY)
                    // The key Cross types, lit while it is held.
                    Text("Space")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(beat == 1 && pressed ? Color.white : Color.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 4)
                            .fill(Color.orange.opacity(beat == 1 && pressed ? 0.9 : 0.12)))
                        .offset(x: -50, y: 38)
                    Text(beat == 0 ? "Stick moves the cursor" :
                         beat == 1 ? "Cross types Space" :
                         beat == 2 ? "R2 clicks" : "Right stick scrolls")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .offset(y: 62)
                }
                .frame(width: 170, height: 106)
            }
        }
    }
}

// MARK: - Demo: MIDI

private struct MidiDemo: View {
    @Environment(\.appReduceMotion) private var appReduceMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(paused: reduceMotion || appReduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let beat = Int(t.truncatingRemainder(dividingBy: 1.6) / 0.2) % 8
            // Three DAW icons rotate every ~2 seconds.
            let dawIndex = Int(t.truncatingRemainder(dividingBy: 6) / 2)
            let daws: [(String, String, Color)] = [
                ("waveform.path", "GarageBand", .pink),
                ("waveform", "Logic Pro", .orange),
                ("music.mic", "Ableton", .blue)
            ]
            let daw = daws[dawIndex % daws.count]

            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    // Flying music notes that telegraph "MIDI traveling out."
                    ForEach(0..<3, id: \.self) { i in
                        let offset = (t + Double(i) * 0.4)
                            .truncatingRemainder(dividingBy: 1.2) / 1.2
                        Image(systemName: i == 0 ? "music.note" : (i == 1 ? "music.quarternote.3" : "music.note.list"))
                            .font(.title3)
                            .foregroundStyle(.pink.opacity(0.85))
                            .offset(y: -CGFloat(offset) * 6)
                            .opacity(1 - offset * 0.7)
                    }
                    Image(systemName: "arrow.right")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Image(systemName: daw.0)
                            .font(.title)
                            .foregroundStyle(daw.2)
                        Text(daw.1)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .id(daw.1)
                            .transition(.opacity)
                            .animation(.easeInOut(duration: 0.4), value: daw.1)
                    }
                }
                // 8 piano-key boxes light up in sequence.
                HStack(spacing: 3) {
                    ForEach(0..<8, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(i == beat ? Color.pink : Color.secondary.opacity(0.18))
                            .frame(width: 22, height: 48)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(Color.secondary.opacity(0.4), lineWidth: 0.5)
                            )
                            .animation(.easeOut(duration: 0.08), value: beat)
                    }
                }
                HStack(spacing: 12) {
                    Label("Note \(60 + beat)", systemImage: "music.note")
                        .font(.caption.monospaced())
                    Label("CC 1", systemImage: "dial.medium")
                        .font(.caption.monospaced())
                    Label("Bend", systemImage: "arrow.up.and.down")
                        .font(.caption.monospaced())
                    Label("Stop", systemImage: "stop.fill")
                        .font(.caption.monospaced())
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Demo: Variable Sensitivity

private struct VariableSensitivityDemo: View {
    @Environment(\.appReduceMotion) private var appReduceMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(paused: reduceMotion || appReduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // depth oscillates between 0 and 1 over 3 seconds
            let depth = (sin(t / 3 * 2 * .pi) + 1) / 2

            HStack(alignment: .center, spacing: 18) {
                // INPUT side: animated trigger pull (top) and stick depth
                // (bottom). Same depth value drives both so the user sees
                // exactly how analog inputs map to the curve bars beside.
                VStack(spacing: 16) {
                    // Trigger pull
                    VStack(spacing: 4) {
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                                .frame(width: 36, height: 70)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(LinearGradient(
                                    colors: [.blue.opacity(0.6), .blue],
                                    startPoint: .top, endPoint: .bottom))
                                .frame(width: 30, height: max(2, CGFloat(depth) * 64))
                                .padding(.bottom, 3)
                        }
                        Text("Trigger")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    // Stick deflection (just a circle that slides along Y)
                    VStack(spacing: 4) {
                        ZStack {
                            Circle()
                                .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                                .frame(width: 40, height: 40)
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 12, height: 12)
                                .offset(y: CGFloat(0.5 - depth) * 26)
                        }
                        Text("Stick")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)

                // OUTPUT side: three curve bars showing how the SAME analog
                // depth maps through Linear, Smooth, and Aggressive.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Output mapping")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    curveBar(label: "Linear",     color: .gray,   value: Float(depth))
                    curveBar(label: "Smooth",     color: .blue,   value: SensitivityCurve.exponential.apply(Float(depth)))
                    curveBar(label: "Aggressive", color: .orange, value: SensitivityCurve.aggressive.apply(Float(depth)))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
        }
    }

    private func curveBar(label: String, color: Color, value: Float) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .frame(width: 70, alignment: .leading)
                .foregroundStyle(.secondary)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(color)
                        .frame(width: max(0, CGFloat(abs(value))) * proxy.size.width)
                }
            }
            .frame(height: 12)
            Text(String(format: "%.0f%%", abs(value) * 100))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }
}

// MARK: - Demo: Deadzone

private struct DeadzoneDemo: View {
    @Environment(\.appReduceMotion) private var appReduceMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(paused: reduceMotion || appReduceMotion)) { context in
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
    @Environment(\.appReduceMotion) private var appReduceMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(paused: reduceMotion || appReduceMotion)) { context in
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
                        // Each event as a colored block
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
    @Environment(\.appReduceMotion) private var appReduceMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(paused: reduceMotion || appReduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // Press cycle: 0.0 idle, 0.5 pressed, ~1.2s burst, then ease out
            let cycle = t.truncatingRemainder(dividingBy: 2.4)
            let pressed = cycle > 0.4 && cycle < 1.6
            let burst = pressed ? min(1.0, (cycle - 0.4) / 0.15) * max(0, 1.0 - (cycle - 1.4) / 0.2) : 0
            let pulse = pressed ? (sin((cycle - 0.4) * 18) + 1) / 2 : 0

            HStack(spacing: 14) {
                // Input: a button visibly being pressed.
                inputBlock(label: "Press", pressed: pressed, tint: .purple)

                // Gradient arrow charging from input → output.
                gradientArrow(active: pressed, tint: .purple)

                // Output: vibrating controller with intensity bars.
                VStack(spacing: 8) {
                    ZStack {
                        ControllerGlyph(height: 38)
                            .foregroundStyle(.purple.opacity(0.85))
                            .offset(x: CGFloat(sin(t * 40)) * burst * 2,
                                    y: CGFloat(cos(t * 40)) * burst * 2)
                        if pressed {
                            Image(systemName: "iphone.radiowaves.left.and.right")
                                .font(.title2)
                                .foregroundStyle(.purple.opacity(0.6 + burst * 0.4))
                                .offset(y: -38)
                        }
                    }
                    HStack(alignment: .center, spacing: 2) {
                        ForEach(0..<18, id: \.self) { i in
                            let lane = Double(i) / 18
                            let h = (sin((lane + t * 1.5) * 2 * .pi) + 1) / 2
                            let height = max(4, CGFloat(h) * CGFloat(pulse) * 36)
                            Capsule()
                                .fill(Color.purple.opacity(0.85))
                                .frame(width: 3, height: height)
                        }
                    }
                    .frame(height: 38)
                    Text(pressed ? "Vibrating" : "Idle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 140)
            }
            .animation(.easeInOut(duration: 0.25), value: pressed)
        }
    }
}

// MARK: - Demo: Spoken Feedback

private struct SpeechDemo: View {
    @Environment(\.appReduceMotion) private var appReduceMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(paused: reduceMotion || appReduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // A new phrase fires every 1.5s; "pressed" window lines up with
            // the first 0.5s of each phrase so the arrow visibly flashes
            // before the speech bubble appears.
            let cycle = t.truncatingRemainder(dividingBy: 6)
            let phraseIndex = Int(cycle / 1.5)
            let phrase = ["Reload", "Ready", "Cover me", "Push forward"][phraseIndex]
            let withinPhrase = cycle.truncatingRemainder(dividingBy: 1.5)
            let pressed = withinPhrase < 0.5

            HStack(spacing: 14) {
                // Input: button press.
                inputBlock(label: "Press", pressed: pressed, tint: .indigo)

                // Gradient arrow.
                gradientArrow(active: pressed, tint: .indigo)

                // Output: speaker + speech bubble + waveform.
                VStack(spacing: 6) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "speaker.wave.3.fill")
                            .font(.title2)
                            .iconTint(.indigo)
                        Text("“\(phrase)”")
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.indigo.opacity(0.15))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.indigo.opacity(0.35),
                                            lineWidth: 0.5)
                            )
                            .id(phrase)
                            .transition(.scale.combined(with: .opacity))
                            .animation(.easeInOut(duration: 0.35), value: phrase)
                    }
                    HStack(spacing: 3) {
                        ForEach(0..<20, id: \.self) { i in
                            let phase = (Double(i) / 20 + t * 2)
                                .truncatingRemainder(dividingBy: 1)
                            let h = (sin(phase * 2 * .pi) + 1) / 2
                            Capsule()
                                .fill(Color.indigo.opacity(0.7))
                                .frame(width: 3, height: max(4, CGFloat(h) * 30))
                        }
                    }
                    .frame(height: 32)
                }
                .frame(width: 200)
            }
        }
    }
}

// MARK: - Demo: Light Bar

private struct LightBarDemo: View {
    @Environment(\.appReduceMotion) private var appReduceMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(paused: reduceMotion || appReduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let hue = t.truncatingRemainder(dividingBy: 6) / 6
            let color = Color(hue: hue, saturation: 0.85, brightness: 1)

            HStack(spacing: 24) {
                // DualSense silhouette with the light bar drawn ABOVE it
                // (offset further up so the color swatch doesn't visually
                // clash with the controller's own shape).
                VStack(spacing: 14) {
                    ZStack {
                        Capsule()
                            .fill(color)
                            .frame(width: 80, height: 12)
                            .blur(radius: 8)
                        Capsule()
                            .fill(color)
                            .frame(width: 60, height: 6)
                    }
                    ControllerGlyph(height: 70)
                        .foregroundStyle(.secondary.opacity(0.5))
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
    @Environment(\.appReduceMotion) private var appReduceMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let entries: [(symbol: String, name: String)] = [
        ("gamecontroller.fill", "DualSense"),
        ("gamecontroller.fill", "Xbox"),
        ("gamecontroller.fill", "Switch Pro"),
        ("gamecontroller.fill", "8BitDo Pro 2"),
        ("gamecontroller.fill", "Stadia"),
        ("gamecontroller.fill", "DualShock 4"),
    ]

    var body: some View {
        TimelineView(.animation(paused: reduceMotion || appReduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let active = Int(t.truncatingRemainder(dividingBy: Double(entries.count) * 1.0))

            VStack(spacing: 12) {
                HStack(spacing: 18) {
                    ForEach(0..<entries.count, id: \.self) { i in
                        let isActive = i == active
                        VStack(spacing: 6) {
                            IconView(name: entries[i].symbol, glyphHeight: isActive ? 24 : 17)
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
    @Environment(\.appReduceMotion) private var appReduceMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(paused: reduceMotion || appReduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // Yaw oscillates left/right; pitch traces a slower curve; roll
            // adds a third axis of motion so the 3D model shows off all
            // three rotations. Each phase has a different period so the
            // demo never repeats a static-looking instant.
            let yaw   = Float(sin(t / 3.5 * 2 * .pi))   // -1...1
            let pitch = Float(sin(t / 2.2 * 2 * .pi))   // -1...1
            let roll  = Float(sin(t / 4.1 * 2 * .pi))   // -1...1

            // The cursor goes where the controller points, like a laser
            // pointer: turn right, it moves right; tilt the nose up, it
            // moves up. A positive pitch on the model is nose up, and screen
            // Y grows downward, so the vertical is negated. Roll does not
            // move it, the same as the real pointer path. The old demo had
            // the vertical the wrong way round, so the cursor dropped as the
            // controller rose.
            let cursorX = CGFloat(yaw) * 66
            let cursorY = -CGFloat(pitch) * 40

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
                    mode: .compact
                )

                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)

                // Cursor that mirrors the controller's tilt - the runtime
                // effect when you bind gyro to mouse motion.
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        .frame(width: 170, height: 106)
                    // Crosshair grid
                    Path { p in
                        p.move(to: CGPoint(x: 85, y: 0))
                        p.addLine(to: CGPoint(x: 85, y: 106))
                        p.move(to: CGPoint(x: 0, y: 53))
                        p.addLine(to: CGPoint(x: 170, y: 53))
                    }
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)

                    Image(systemName: "cursorarrow.rays")
                        .font(.title2)
                        .iconTint(.teal)
                        .offset(x: cursorX, y: cursorY)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

// MARK: - Demo: Touchpad Zones

/// The pad drawn as four zones. A finger lands in each in turn; the zone
/// lights, a pulse ring spreads, and the output it sends appears beside
/// the pad.
private struct TouchpadRegionsDemo: View {
    @Environment(\.appReduceMotion) private var appReduceMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let zones: [(name: String, output: String, color: Color)] = [
        ("Undo", "Cmd Z", .mint), ("Redo", "Cmd Shift Z", .cyan),
        ("Copy", "Cmd C", .pink), ("Paste", "Cmd V", .orange),
    ]
    var body: some View {
        TimelineView(.animation(paused: reduceMotion || appReduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let period = 1.4
            let step = Int(t / period) % 4
            let phase = (t.truncatingRemainder(dividingBy: period)) / period   // 0...1 within a step
            let pressed = phase < 0.45
            let ring = min(1, phase / 0.45)

            HStack(spacing: 24) {
                ZStack {
                    // The pad and its four zones.
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.orange.opacity(0.5), lineWidth: 1.5)
                        .frame(width: 170, height: 82)
                    // Zones are inset from the pad's edge so the pad reads as
                    // the surface and the zones as areas on it.
                    VStack(spacing: 4) {
                        ForEach(0..<2, id: \.self) { row in
                            HStack(spacing: 4) {
                                ForEach(0..<2, id: \.self) { col in
                                    let i = row * 2 + col
                                    let active = i == step && pressed
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(zones[i].color.opacity(active ? 0.55 : 0.14))
                                        .overlay(
                                            Text(zones[i].name)
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(active ? .white : zones[i].color)
                                        )
                                        .frame(width: 75, height: 32)
                                }
                            }
                        }
                    }
                    // The finger, with a pulse ring while the zone is held.
                    let fx: CGFloat = (step % 2 == 0) ? -39.5 : 39.5
                    let fy: CGFloat = (step < 2) ? -18 : 18
                    if pressed {
                        Circle()
                            .stroke(zones[step].color.opacity(0.8 * (1 - ring)), lineWidth: 2)
                            .frame(width: 16 + 40 * ring, height: 16 + 40 * ring)
                            .offset(x: fx, y: fy)
                    }
                    Circle()
                        .fill(Color.white.opacity(pressed ? 0.95 : 0.5))
                        .frame(width: 14, height: 14)
                        .offset(x: fx, y: fy)
                    Text("Touchpad")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .offset(y: 54)
                }
                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)
                // What the zone sends.
                VStack(spacing: 6) {
                    Text(zones[step].output)
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .foregroundStyle(zones[step].color)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(zones[step].color.opacity(pressed ? 0.22 : 0.08)))
                        .contentTransition(.identity)
                    Text(zones[step].name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 130)
            }
        }
    }
}

// MARK: - Demo: Touchpad Mouse

private struct TouchpadDemo: View {
    @Environment(\.appReduceMotion) private var appReduceMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(paused: reduceMotion || appReduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // Finger traces a figure-8 across the trackpad.
            let p = t.truncatingRemainder(dividingBy: 3) / 3
            let theta = p * 2 * .pi
            let fingerX = CGFloat(sin(theta)) * 66
            let fingerY = CGFloat(sin(theta * 2)) * 21
            // Cursor mirrors the finger but stays inside the small desktop
            // rect on the right (170x106). A 1:1 X mapping plus a slight Y
            // bump keeps it visibly bounded without clipping.
            let cursorX = fingerX
            let cursorY = fingerY * 1.4

            HStack(spacing: 24) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.mint.opacity(0.5), lineWidth: 1.5)
                        .frame(width: 170, height: 82)
                    // Faint trail
                    ForEach(0..<8, id: \.self) { i in
                        let lag = Double(i) * 0.04
                        let lagTheta = (p - lag) * 2 * .pi
                        let lx = CGFloat(sin(lagTheta)) * 66
                        let ly = CGFloat(sin(lagTheta * 2)) * 21
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
                        .frame(width: 170, height: 106)
                    Image(systemName: "cursorarrow.rays")
                        .font(.title2)
                        .iconTint(.mint)
                        .offset(x: cursorX, y: cursorY)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

// MARK: - Demo: Lifetime Statistics

private struct StatsDemo: View {
    @Environment(\.appReduceMotion) private var appReduceMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let labels = ["Cross", "Square", "L Trig", "R Trig", "Stick", "D-Pad", "Touch"]

    var body: some View {
        TimelineView(.animation(paused: reduceMotion || appReduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = t.truncatingRemainder(dividingBy: 8) / 8
            let presses = Int(125_437 + phase * 4321)
            let keys    = Int( 89_204 + phase * 3102)
            let clicks  = Int( 21_018 + phase * 802)
            let midi    = Int(  6_417 + phase * 92)

            VStack(spacing: 10) {
                // Top-row KPI tiles. Four counters that look like a real stats
                // dashboard rather than a single floating number.
                HStack(spacing: 8) {
                    kpiTile(icon: "hand.tap.fill",        value: presses, label: "Button presses", tint: .brown)
                    kpiTile(icon: "keyboard.fill",        value: keys,    label: "Key outputs",    tint: .orange)
                    kpiTile(icon: "cursorarrow.click.2",  value: clicks,  label: "Mouse clicks",   tint: .blue)
                    kpiTile(icon: "music.note",           value: midi,    label: "MIDI events",    tint: .pink)
                }
                .padding(.horizontal, 16)

                // Bar chart + axis line below for "most-pressed inputs."
                VStack(spacing: 2) {
                    HStack(alignment: .bottom, spacing: 10) {
                        ForEach(Array(labels.enumerated()), id: \.offset) { i, label in
                            let lane = Double(i) / Double(labels.count)
                            let local = (t * 0.6 + lane * 1.7).truncatingRemainder(dividingBy: 2 * .pi)
                            let raw = (sin(local) + 1.2) / 2.4
                            let height = max(10, CGFloat(raw) * 64)
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(LinearGradient(
                                        colors: [.brown.opacity(0.45),
                                                 .brown.opacity(0.85)],
                                        startPoint: .top, endPoint: .bottom))
                                    .frame(width: 18, height: height)
                                Text(label)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(height: 80)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(height: 0.5)
                }
                .padding(.horizontal, 16)

                // Footer reassurance about privacy.
                HStack(spacing: 4) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption2)
                    Text("Stored locally · no telemetry")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func kpiTile(icon: String, value: Int, label: String, tint: Color) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(tint)
                Text(value.formatted())
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
            }
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(tint.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(tint.opacity(0.25), lineWidth: 0.5)
        )
    }
}

// MARK: - Demo: Toggle Mode

/// Animates a face button being pressed twice. First press latches the output
/// ON and it stays on while the finger is lifted; second press releases it.
/// The "OUTPUT" lamp on the right shows the latched state, the press indicator
/// pulses only while the button is physically down.
private struct ToggleModeDemo: View {
    @Environment(\.appReduceMotion) private var appReduceMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(paused: reduceMotion || appReduceMotion)) { context in
            content(at: context.date.timeIntervalSinceReferenceDate)
        }
    }

    @ViewBuilder
    private func content(at t: TimeInterval) -> some View {
        // 4.0s cycle:
        //   0.0-0.4   press #1 (latch ON)
        //   0.4-2.0   button released, output STAYS ON
        //   2.0-2.4   press #2 (release)
        //   2.4-4.0   button released, output OFF
        let cycle = t.truncatingRemainder(dividingBy: 4.0)
        let firstHalf = cycle < 2.0
        let pressing = (cycle < 0.4) || (cycle >= 2.0 && cycle < 2.4)
        let latched = firstHalf

        HStack(spacing: 14) {
            inputBlock(label: "Tap", pressed: pressing, tint: .orange)
            pressCounter(firstHalf: firstHalf)
            gradientArrow(active: pressing, tint: .orange)
            outputLamp(latched: latched)
        }
    }

    @ViewBuilder
    private func pressCounter(firstHalf: Bool) -> some View {
        let pip1Color: Color = firstHalf ? .orange : Color.secondary.opacity(0.3)
        let pip2Color: Color = firstHalf ? Color.secondary.opacity(0.3) : .orange

        VStack(spacing: 4) {
            Text(firstHalf ? "Press 1" : "Press 2")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .id(firstHalf)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: firstHalf)
            HStack(spacing: 4) {
                Circle().fill(pip1Color).frame(width: 8, height: 8)
                Circle().fill(pip2Color).frame(width: 8, height: 8)
            }
        }
    }

    @ViewBuilder
    private func outputLamp(latched: Bool) -> some View {
        let fillColor: Color = latched ? Color.orange.opacity(0.85) : Color.secondary.opacity(0.18)
        let strokeColor: Color = latched ? .orange : Color.secondary.opacity(0.4)
        let strokeWidth: CGFloat = latched ? 2 : 1
        let textColor: Color = latched ? .white : .secondary
        let labelText = latched ? "HELD" : "OFF"
        let labelColor: Color = latched ? Color.white.opacity(0.8) : Color(NSColor.tertiaryLabelColor)
        let shadowColor: Color = latched ? Color.orange.opacity(0.5) : .clear

        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(fillColor)
                RoundedRectangle(cornerRadius: 10).stroke(strokeColor, lineWidth: strokeWidth)
                VStack(spacing: 2) {
                    Text("W")
                        .font(.system(size: 28, weight: .heavy, design: .monospaced))
                        .foregroundStyle(textColor)
                    Text(labelText)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(labelColor)
                }
            }
            .frame(width: 92, height: 92)
            .shadow(color: shadowColor, radius: 12)
            .animation(.easeOut(duration: 0.18), value: latched)

            Text(latched ? "Auto-running" : "Released")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Demo: Stacked Outputs

/// One physical press fans out into four parallel outputs (key + click + MIDI +
/// speech). Each output lights at the same instant; the whole point is to
/// contrast with macros, which sequence outputs in time.
private struct StackedOutputsDemo: View {
    @Environment(\.appReduceMotion) private var appReduceMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(paused: reduceMotion || appReduceMotion)) { context in
            content(at: context.date.timeIntervalSinceReferenceDate)
        }
    }

    @ViewBuilder
    private func content(at t: TimeInterval) -> some View {
        // 2.4s cycle, press for the first 0.5s.
        let cycle = t.truncatingRemainder(dividingBy: 2.4)
        let pressed = cycle < 0.5
        // All four outputs flash together with the press.
        let flash: Double = pressed
            ? min(1.0, cycle / 0.15)
            : max(0, 1.0 - (cycle - 0.5) / 0.4)

        HStack(spacing: 16) {
            inputBlock(label: "Press", pressed: pressed, tint: .blue)
            fanOutSplitter(flash: flash)
            outputColumn(flash: flash)
        }
        .animation(.easeInOut(duration: 0.25), value: pressed)
    }

    @ViewBuilder
    private func fanOutSplitter(flash: Double) -> some View {
        let strokeOpacity: Double = 0.35 + flash * 0.55

        ZStack {
            Path { p in
                p.move(to: CGPoint(x: 0, y: 50))
                p.addLine(to: CGPoint(x: 30, y: 50))
                for i in 0..<4 {
                    let y = CGFloat(i) * 28 + 4
                    p.move(to: CGPoint(x: 30, y: 50))
                    p.addLine(to: CGPoint(x: 30, y: y))
                    p.addLine(to: CGPoint(x: 60, y: y))
                }
            }
            .stroke(
                Color.blue.opacity(strokeOpacity),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            )
        }
        .frame(width: 60, height: 100)
    }

    @ViewBuilder
    private func outputColumn(flash: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            outputRow(icon: "keyboard",            text: "Key  E",   flash: flash)
            outputRow(icon: "cursorarrow.click.2", text: "Click L",  flash: flash)
            outputRow(icon: "music.note",          text: "MIDI 60",  flash: flash)
            outputRow(icon: "speaker.wave.2.fill", text: "“Reload”", flash: flash)
        }
        .frame(width: 150)
    }

    @ViewBuilder
    private func outputRow(icon: String, text: String, flash: Double) -> some View {
        let lit = flash > 0.05
        let fillColor: Color = lit
            ? Color.blue.opacity(0.25 + flash * 0.45)
            : Color.secondary.opacity(0.12)
        let strokeColor: Color = lit ? .blue : Color.secondary.opacity(0.35)
        let strokeWidth: CGFloat = lit ? 1.5 : 0.5
        let iconColor: Color = lit ? .blue : .secondary
        let textColor: Color = lit ? .primary : .secondary

        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(fillColor)
                RoundedRectangle(cornerRadius: 6).stroke(strokeColor, lineWidth: strokeWidth)
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(iconColor)
            }
            .frame(width: 28, height: 24)
            Text(text)
                .font(.caption.monospaced())
                .foregroundStyle(textColor)
        }
    }
}

// MARK: - Demo: Auto-Launch + Cursor Confine

/// A preset card activates, an app icon swings in (auto-launch), and a glowing
/// confine ring appears around the cursor area. Cursor wanders but gets gently
/// nudged back when it touches the edge.
private struct AutoLaunchDemo: View {
    @Environment(\.appReduceMotion) private var appReduceMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(paused: reduceMotion || appReduceMotion)) { context in
            content(at: context.date.timeIntervalSinceReferenceDate)
        }
    }

    @ViewBuilder
    private func content(at t: TimeInterval) -> some View {
        let cycle = t.truncatingRemainder(dividingBy: 4.0)
        let activated = cycle > 0.2
        let pulse = (sin(t * 3) + 1) / 2
        let cursorX = CGFloat(sin(t * 1.6)) * 70
        let cursorY = CGFloat(cos(t * 1.1)) * 36

        HStack(spacing: 20) {
            activateTile(activated: activated)
            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
            appIcon(activated: activated)
            confineArea(pulse: pulse, cursorX: cursorX, cursorY: cursorY)
        }
    }

    @ViewBuilder
    private func activateTile(activated: Bool) -> some View {
        let strokeOpacity: Double = activated ? 0.9 : 0.4
        let strokeWidth: CGFloat = activated ? 2 : 1
        let shadowColor: Color = activated ? Color.green.opacity(0.5) : .clear

        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.18))
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.green.opacity(strokeOpacity), lineWidth: strokeWidth)
                VStack(spacing: 4) {
                    Image(systemName: "power")
                        .font(.title2)
                        .iconTint(.green)
                    Text("Activate")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
            .frame(width: 70, height: 70)
            .shadow(color: shadowColor, radius: 10)
            Text("Preset")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func appIcon(activated: Bool) -> some View {
        let yOffset: CGFloat = activated ? 0 : 14
        let opacity: Double = activated ? 1 : 0

        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(LinearGradient(
                        colors: [Color.green.opacity(0.6), .green],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 56, height: 56)
                Image(systemName: "app.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white)
            }
            .offset(y: yOffset)
            .opacity(opacity)
            .animation(.spring(response: 0.5, dampingFraction: 0.7), value: activated)
            Text("App launched")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func confineArea(pulse: Double, cursorX: CGFloat, cursorY: CGFloat) -> some View {
        let strokeOpacity: Double = 0.4 + pulse * 0.4

        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.green.opacity(strokeOpacity),
                        style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .frame(width: 170, height: 106)
            Image(systemName: "cursorarrow")
                .font(.title3)
                .iconTint(.green)
                .offset(x: cursorX, y: cursorY)
            Text("Confine")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .offset(y: 64)
        }
    }
}

// MARK: - Demo: MIDI CC Dials

/// A stick rotates around its circle and four CC channels emit continuous
/// values that follow the stick's X / Y / radius / angle. Shown as labeled
/// horizontal bars so it reads as "soft knobs for your DAW."
private struct MidiCCDemo: View {
    @Environment(\.appReduceMotion) private var appReduceMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(paused: reduceMotion || appReduceMotion)) { context in
            content(at: context.date.timeIntervalSinceReferenceDate)
        }
    }

    @ViewBuilder
    private func content(at t: TimeInterval) -> some View {
        let angle = t.truncatingRemainder(dividingBy: 4) / 4 * 2 * .pi
        let radiusFrac = 0.4 + (sin(t / 1.7) + 1) / 4
        let stickRadius: CGFloat = 32
        let thumbX = cos(angle) * stickRadius * radiusFrac
        let thumbY = sin(angle) * stickRadius * radiusFrac

        let ccX     = (cos(angle) * radiusFrac + 1) / 2
        let ccY     = (sin(angle) * radiusFrac + 1) / 2
        let ccR     = radiusFrac
        let ccAngle = (angle / (2 * .pi)).truncatingRemainder(dividingBy: 1)

        HStack(spacing: 22) {
            stickColumn(t: t, angle: angle, thumbX: thumbX, thumbY: thumbY,
                        stickRadius: stickRadius)
            ccColumn(ccX: ccX, ccY: ccY, ccR: ccR, ccAngle: ccAngle)
        }
    }

    @ViewBuilder
    private func stickColumn(t: TimeInterval, angle: Double,
                             thumbX: Double, thumbY: Double,
                             stickRadius: CGFloat) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 2)
                    .frame(width: 86, height: 86)
                ForEach(0..<10, id: \.self) { i in
                    trailDot(index: i, t: t, angle: angle, stickRadius: stickRadius)
                }
                Circle()
                    .fill(Color.purple)
                    .frame(width: 14, height: 14)
                    .offset(x: thumbX, y: thumbY)
            }
            Text("Right Stick")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func trailDot(index i: Int, t: TimeInterval, angle: Double,
                          stickRadius: CGFloat) -> some View {
        let lag = Double(i) * 0.06
        let lagAngle = angle - lag
        let lr = 0.4 + (sin((t - lag) / 1.7) + 1) / 4
        let dotOpacity = max(0, 0.35 - Double(i) * 0.03)

        Circle()
            .fill(Color.purple.opacity(dotOpacity))
            .frame(width: 8, height: 8)
            .offset(x: cos(lagAngle) * stickRadius * lr,
                    y: sin(lagAngle) * stickRadius * lr)
    }

    @ViewBuilder
    private func ccColumn(ccX: Double, ccY: Double, ccR: Double, ccAngle: Double) -> some View {
        VStack(spacing: 6) {
            ccBar(label: "CC 1",  hint: "Mod",     value: ccY)
            ccBar(label: "CC 7",  hint: "Volume",  value: ccR)
            ccBar(label: "CC 10", hint: "Pan",     value: ccAngle)
            ccBar(label: "CC 11", hint: "Express", value: ccX)
        }
        .frame(width: 220)
    }

    @ViewBuilder
    private func ccBar(label: String, hint: String, value: Double) -> some View {
        let v127 = Int(value * 127)
        let fillWidthFrac: CGFloat = max(0, CGFloat(value))

        HStack(spacing: 8) {
            Text(label)
                .font(.caption.monospaced())
                .foregroundStyle(.purple)
                .frame(width: 42, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(LinearGradient(
                            colors: [Color.purple.opacity(0.6), .purple],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: fillWidthFrac * proxy.size.width)
                }
            }
            .frame(height: 10)
            Text(String(format: "%3d", v127))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
            Text(hint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .leading)
        }
    }
}


/// MIDI *input* demo: a hardware knob sweeps and the Mac's volume bar
/// tracks it 1-to-1, the fader recipe from the Knob Deck preset.
private struct MidiInputDemo: View {
    @Environment(\.appReduceMotion) private var appReduceMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(paused: reduceMotion || appReduceMotion)) { context in
            content(at: context.date.timeIntervalSinceReferenceDate)
        }
    }

    @ViewBuilder
    private func content(at t: TimeInterval) -> some View {
        let level = (sin(t / 1.4) + 1) / 2
        let pointer = Angle(degrees: -135 + 270 * level)

        HStack(spacing: 26) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 3)
                        .frame(width: 74, height: 74)
                    Circle()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 46, height: 46)
                    Capsule()
                        .fill(Color.pink)
                        .frame(width: 4, height: 22)
                        .offset(y: -16)
                        .rotationEffect(pointer)
                }
                Text("CC 7 · \(Int(level * 127))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Image(systemName: "arrow.right")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 30, height: 84)
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.pink.opacity(0.85))
                        .frame(width: 30, height: max(6, 84 * level))
                }
                HStack(spacing: 3) {
                    Image(systemName: level < 0.05 ? "speaker.slash.fill"
                          : level < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill")
                    Text("\(Int(level * 100))%")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}


/// System Functions demo: a pad press ripples into media, volume, and
/// brightness glyphs lighting up in turn.
private struct SystemControlDemo: View {
    @Environment(\.appReduceMotion) private var appReduceMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let icons = ["playpause.fill", "speaker.wave.2.fill",
                                "sun.max.fill", "rectangle.3.group.fill",
                                "sparkles.rectangle.stack.fill", "lock.fill"]
    var body: some View {
        TimelineView(.animation(paused: reduceMotion || appReduceMotion)) { context in
            content(at: context.date.timeIntervalSinceReferenceDate)
        }
    }

    @ViewBuilder
    private func content(at t: TimeInterval) -> some View {
        let active = Int(t.truncatingRemainder(dividingBy: Double(Self.icons.count) * 0.8) / 0.8)
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                ForEach(Array(Self.icons.enumerated()), id: \.offset) { index, icon in
                    ZStack {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(index == active ? Color.teal.opacity(0.25)
                                                  : Color.secondary.opacity(0.12))
                        Image(systemName: icon)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(index == active ? Color.teal : Color.secondary)
                    }
                    .frame(width: 40, height: 40)
                    .scaleEffect(index == active ? 1.12 : 1.0)
                    .animation(.spring(duration: 0.25), value: active)
                }
            }
            Text("Any input, any system function")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}


/// Siri Shortcuts demo: one pad press ripples into a rotating set of
/// automation outcomes.
private struct SiriShortcutsDemo: View {
    @Environment(\.appReduceMotion) private var appReduceMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let outcomes: [(String, String)] = [
        ("moon.fill", "Do Not Disturb"), ("timer", "Start a timer"),
        ("lightbulb.fill", "Scene: Movie night"), ("house.fill", "I'm home"),
    ]
    var body: some View {
        TimelineView(.animation(paused: reduceMotion || appReduceMotion)) { context in
            content(at: context.date.timeIntervalSinceReferenceDate)
        }
    }
    @ViewBuilder private func content(at t: TimeInterval) -> some View {
        let step = Int(t.truncatingRemainder(dividingBy: Double(Self.outcomes.count) * 1.6) / 1.6)
        let pulse = t.truncatingRemainder(dividingBy: 1.6) < 0.25
        HStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(pulse ? Color.indigo.opacity(0.35) : Color.secondary.opacity(0.14))
                    .frame(width: 54, height: 54)
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(pulse ? Color.indigo : Color.secondary)
            }
            Image(systemName: "arrow.right")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(Self.outcomes.enumerated()), id: \.offset) { index, item in
                    HStack(spacing: 8) {
                        Image(systemName: item.0)
                            .frame(width: 18)
                        Text(item.1)
                            .font(.caption)
                    }
                    .foregroundStyle(index == step ? Color.indigo : Color.secondary.opacity(0.6))
                    .fontWeight(index == step ? .semibold : .regular)
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: step)
    }
}

/// Keyboard-as-input demo: a key on a mini keyboard lights up and fires an
/// action, cycling across keys.
private struct InputRemapDemo: View {
    @Environment(\.appReduceMotion) private var appReduceMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Keys as the MacBook prints them, and what each one runs.
    private static let keys: [(label: String, symbol: Bool, action: String)] = [
        ("sun.max", true, "sun.max.fill"),
        ("playpause.fill", true, "music.note"),
        ("speaker.wave.3.fill", true, "speaker.wave.3.fill"),
        ("F13", false, "rectangle.3.group"),
        ("F14", false, "magnifyingglass"),
        ("⌘", false, "sparkles"),
        ("⇧", false, "bolt.fill"),
        ("A", false, "keyboard"),
    ]
    var body: some View {
        TimelineView(.animation(paused: reduceMotion || appReduceMotion)) { context in
            content(at: context.date.timeIntervalSinceReferenceDate)
        }
    }
    @ViewBuilder private func content(at t: TimeInterval) -> some View {
        let active = Int(t.truncatingRemainder(dividingBy: Double(Self.keys.count) * 0.7) / 0.7)
        HStack(spacing: 24) {
            VStack(spacing: 5) {
                HStack(spacing: 5) {
                    ForEach(0..<4, id: \.self) { i in keycap(i, active: active) }
                }
                HStack(spacing: 5) {
                    ForEach(4..<8, id: \.self) { i in keycap(i, active: active) }
                }
            }
            Image(systemName: "arrow.right")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.16))
                    .frame(width: 52, height: 52)
                Image(systemName: Self.keys[active].action)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.orange)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: active)
    }
    private func keycap(_ i: Int, active: Int) -> some View {
        let k = Self.keys[i]
        return ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(i == active ? Color.orange.opacity(0.4) : Color.secondary.opacity(0.16))
            if k.symbol {
                Image(systemName: k.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(i == active ? Color.orange : Color.secondary)
            } else {
                Text(k.label)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(i == active ? Color.orange : Color.secondary)
            }
        }
        .frame(width: 30, height: 26)
    }
}

/// Trackpad and Magic Mouse demo: the pad does four things in turn, a
/// click, a two-finger scroll, a force click, and a double tap, and each
/// one lands on an output.
private struct MacTrackpadDemo: View {
    @Environment(\.appReduceMotion) private var appReduceMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let beats: [(name: String, action: String)] = [
        ("Click", "cursorarrow.click"),
        ("Two-finger scroll", "arrow.up.arrow.down"),
        ("Force click", "rectangle.3.group"),
        ("Double tap", "sparkles"),
    ]
    var body: some View {
        TimelineView(.animation(paused: reduceMotion || appReduceMotion)) { context in
            content(at: context.date.timeIntervalSinceReferenceDate)
        }
    }
    @ViewBuilder private func content(at t: TimeInterval) -> some View {
        let period = 1.6
        let step = Int(t.truncatingRemainder(dividingBy: period * 4) / period)
        let phase = t.truncatingRemainder(dividingBy: period) / period
        let on = phase < 0.55
        let beat = Self.beats[step]
        HStack(spacing: 24) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(step == 2 && on ? Color.mint.opacity(0.2 + 0.3 * phase / 0.55)
                              : (step == 0 && on ? Color.mint.opacity(0.35) : Color.secondary.opacity(0.08)))
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(on ? Color.mint : Color.secondary.opacity(0.4), lineWidth: 1)
                    if step == 1 && on {
                        HStack(spacing: 10) {
                            Circle().fill(Color.mint).frame(width: 12, height: 12)
                            Circle().fill(Color.mint).frame(width: 12, height: 12)
                        }
                        .offset(y: 14 - CGFloat(phase / 0.55) * 28)
                    }
                    if step == 3 && on {
                        Circle().stroke(Color.mint.opacity(1 - phase / 0.55), lineWidth: 2)
                            .frame(width: 14 + 30 * CGFloat(phase / 0.55), height: 14 + 30 * CGFloat(phase / 0.55))
                        Circle().fill(Color.mint).frame(width: 12, height: 12)
                    }
                }
                .frame(width: 120, height: 82)
                Text(beat.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .contentTransition(.identity)
            }
            Image(systemName: "arrow.right")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            ZStack {
                Circle()
                    .fill(Color.mint.opacity(0.16))
                    .frame(width: 52, height: 52)
                Image(systemName: beat.action)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(on ? Color.mint : Color.secondary)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: step)
    }
}

/// Modifier holds demo: a modifier keycap with a ring that fills while it
/// is held; when the ring closes the output fires. A tap does nothing.
private struct ModifierHoldsDemo: View {
    @Environment(\.appReduceMotion) private var appReduceMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let beats: [(key: String, name: String, action: String, label: String)] = [
        ("⌘", "Hold Right Command", "magnifyingglass", "Spotlight"),
        ("⌥", "Hold Right Option", "mic.fill", "Dictation"),
        ("⇧", "Hold Right Shift", "rectangle.3.group", "Mission Control"),
        ("⌘", "Double tap Right Command", "square.grid.3x3.fill", "Launchpad"),
    ]
    var body: some View {
        TimelineView(.animation(paused: reduceMotion || appReduceMotion)) { context in
            content(at: context.date.timeIntervalSinceReferenceDate)
        }
    }
    @ViewBuilder private func content(at t: TimeInterval) -> some View {
        let period = 2.0
        let step = Int(t.truncatingRemainder(dividingBy: period * 4) / period)
        let phase = t.truncatingRemainder(dividingBy: period) / period
        let beat = Self.beats[step]
        let isDouble = step == 3
        // Hold: the ring fills over the first 45% of the beat, then fires.
        // Double tap: two quick presses, then fires.
        let held = isDouble ? ((phase < 0.12) || (phase > 0.2 && phase < 0.32)) : phase < 0.45
        let fired = isDouble ? phase >= 0.32 && phase < 0.85 : phase >= 0.45 && phase < 0.85
        HStack(spacing: 24) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(held ? Color.indigo.opacity(0.35) : Color.secondary.opacity(0.14))
                        .frame(width: 56, height: 56)
                    Text(beat.key)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(held || fired ? Color.indigo : Color.secondary)
                    if !isDouble {
                        Circle()
                            .trim(from: 0, to: fired ? 1 : min(1, phase / 0.45))
                            .stroke(Color.indigo, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 72, height: 72)
                    }
                }
                .frame(height: 76)
                Text(beat.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .contentTransition(.identity)
            }
            Image(systemName: "arrow.right")
                .font(.title3.weight(.semibold))
                .foregroundStyle(fired ? Color.indigo : Color.secondary)
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(Color.indigo.opacity(fired ? 0.22 : 0.08))
                        .frame(width: 52, height: 52)
                    Image(systemName: beat.action)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(fired ? Color.indigo : Color.secondary)
                }
                Text(beat.label)
                    .font(.caption2)
                    .foregroundStyle(fired ? Color.primary : Color.secondary)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: held)
    }
}

/// Hold & double-tap demo: one button, three gestures, three outputs.
private struct HoldDoubleTapDemo: View {
    @Environment(\.appReduceMotion) private var appReduceMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let phases: [(String, String, String)] = [
        ("Press", "arrow.up.circle.fill", "Jump"),
        ("Hold", "figure.run", "Sprint"),
        ("Double-tap", "backpack.fill", "Inventory"),
    ]
    var body: some View {
        TimelineView(.animation(paused: reduceMotion || appReduceMotion)) { context in
            content(at: context.date.timeIntervalSinceReferenceDate)
        }
    }
    @ViewBuilder private func content(at t: TimeInterval) -> some View {
        let step = Int(t.truncatingRemainder(dividingBy: 3 * 1.5) / 1.5)
        let phase = Self.phases[step]
        HStack(spacing: 26) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.28))
                        .frame(width: 54, height: 54)
                    Text("A")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.blue)
                }
                Text(phase.0)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 84)
            }
            Image(systemName: "arrow.right")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                Image(systemName: phase.1)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.blue)
                Text(phase.2)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 90)
        }
        .animation(.easeInOut(duration: 0.3), value: step)
    }
}

/// Per-app auto-switch demo: the frontmost app flips and the active preset
/// follows it.
private struct AppAutoSwitchDemo: View {
    @Environment(\.appReduceMotion) private var appReduceMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(paused: reduceMotion || appReduceMotion)) { context in
            content(at: context.date.timeIntervalSinceReferenceDate)
        }
    }
    @ViewBuilder private func content(at t: TimeInterval) -> some View {
        let gameFront = Int(t.truncatingRemainder(dividingBy: 4) / 2) == 0
        VStack(spacing: 14) {
            HStack(spacing: 18) {
                appTile("gamecontroller.fill", "Game", front: gameFront)
                appTile("music.note", "DAW", front: !gameFront)
            }
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(gameFront ? "FPS preset active" : "MIDI preset active")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.green.opacity(0.14)))
            .contentTransition(.opacity)
        }
        .animation(.easeInOut(duration: 0.3), value: gameFront)
    }
    @ViewBuilder private func appTile(_ icon: String, _ name: String, front: Bool) -> some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 11)
                    .fill(front ? Color.green.opacity(0.25) : Color.secondary.opacity(0.12))
                    .frame(width: 48, height: 48)
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(front ? Color.green : Color.secondary)
            }
            Text(name)
                .font(.caption2)
                .foregroundStyle(front ? .primary : .secondary)
        }
        .scaleEffect(front ? 1.08 : 1.0)
        .animation(.spring(duration: 0.3), value: front)
    }
}

/// Cursor regions demo: the pointer glides into a dashed region and a key
/// fires.
/// Two taps landing on a MacBook, with the shock rippling out and the counter
/// ticking over. Loops on a ~3.4 s cycle: tap, tap, gesture recognised, rest.
private struct ChassisTapDemo: View {
    @Environment(\.appReduceMotion) private var appReduceMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(paused: reduceMotion || appReduceMotion)) { context in
            content(at: context.date.timeIntervalSinceReferenceDate)
        }
    }
    @ViewBuilder private func content(at t: TimeInterval) -> some View {
        let cycle = t.truncatingRemainder(dividingBy: 3.4)
        // Two strikes, 0.45 s apart, then the gesture resolves.
        let strikes: [Double] = [0.5, 0.95]
        let recognised = cycle > 1.5 && cycle < 3.0
        let count = strikes.filter { cycle >= $0 }.count
        HStack(spacing: 26) {
            ZStack {
                // Lid and base, drawn plainly so the ripple is the only motion.
                VStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.secondary.opacity(0.55), lineWidth: 1.5)
                        .frame(width: 118, height: 74)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.45))
                        .frame(width: 140, height: 6)
                }
                ForEach(Array(strikes.enumerated()), id: \.offset) { _, at in
                    let age = cycle - at
                    if age >= 0, age < 0.75 {
                        let p = age / 0.75
                        Circle()
                            .strokeBorder(Color.mint.opacity(1 - p), lineWidth: 2)
                            .frame(width: 16 + p * 74, height: 16 + p * 74)
                            .offset(y: 12)
                    }
                }
                Image(systemName: "hand.tap.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.mint)
                    .opacity(strikes.contains { cycle >= $0 && cycle < $0 + 0.18 } ? 1 : 0.28)
                    .offset(y: 12)
            }
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(recognised ? Color.mint.opacity(0.3) : Color.secondary.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Text("\(count)")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(recognised ? Color.mint : Color.secondary)
                        .contentTransition(.numericText())
                }
                Text(recognised ? "Double tap" : (count > 0 ? "Counting" : "Waiting"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.25), value: count)
    }
}

private struct CursorRegionsDemo: View {
    @Environment(\.appReduceMotion) private var appReduceMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(paused: reduceMotion || appReduceMotion)) { context in
            content(at: context.date.timeIntervalSinceReferenceDate)
        }
    }
    @ViewBuilder private func content(at t: TimeInterval) -> some View {
        let phase = (sin(t * 1.1) + 1) / 2          // 0...1 sweep
        let inside = phase > 0.62
        HStack(spacing: 24) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.08))
                    .frame(width: 170, height: 106)
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(inside ? Color.purple : Color.secondary.opacity(0.5),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.purple.opacity(inside ? 0.18 : 0.04))
                    )
                    .frame(width: 56, height: 40)
                    .offset(x: 84, y: 36)
                Image(systemName: "cursorarrow")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(inside ? Color.purple : Color.secondary)
                    .offset(x: 14 + phase * 92, y: 18 + phase * 36)
            }
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(inside ? Color.purple.opacity(0.3) : Color.secondary.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Text("M")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(inside ? Color.purple : Color.secondary)
                }
                Text(inside ? "Key fires" : "Waiting")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: inside)
    }
}


/// The out-and-in drift for a showcase swap: faded and pushed 28 pt in the
/// travel direction while `swapping`, in place otherwise.
private struct SlideSwap: ViewModifier {
    let swapping: Bool
    let staged: Bool
    let forward: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        // Outgoing content leaves in the travel direction; the staged
        // incoming content waits on the far side and drifts to centre.
        let away: CGFloat = forward ? -28 : 28
        content
            .opacity(swapping ? 0 : 1)
            .offset(x: (swapping && !reduceMotion) ? (staged ? -away : away) : 0)
    }
}
