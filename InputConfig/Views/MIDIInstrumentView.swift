import SwiftUI
import Combine

// MARK: - MIDI Instrument layout

/// The MIDI template for the Live Visualizer: a full instrument panel that
/// renders inside the same box, picker, and zoom chrome as the controller
/// layouts. Selected from the template picker like any other layout and
/// chosen automatically for slots whose bindings are mostly MIDI, so MIDI
/// presets get it by default.
///
/// What it shows, per connected device (or one resting panel with nothing
/// connected):
///
///   • Seven-octave velocity-shaded keyboard - held notes glow with press
///     strength, bound notes carry a dot, octaves are labeled
///   • A dial for every bound CC (at rest until touched) plus every CC the
///     hardware has sent, with standard controller names (Mod Wheel,
///     Cutoff, Sustain...), knob-mode badges, and the freshest knob lit
///   • Pitch bend and aftertouch meters, the last Program Change, and a
///     16-slot channel activity strip
///   • A rolling event log (notes with velocity, sparse CC sweeps, program
///     changes) plus the session's total event count
///
/// Every key and knob opens the binding inspector with jump-to-editor.
/// Render discipline: state only mutates when the service's event counter
/// or device list actually changed, so an idle instrument costs one lock
/// per tick and zero re-renders.
struct MIDIInstrumentView: View {
    @Environment(\.visualizerSuspended) private var suspended
    /// The app's direction, put back in the popovers of the keyboard strip,
    /// which is drawn left to right like the instrument.
    @Environment(\.layoutDirection) private var appDirection
    let preset: Preset
    let slot: Int
    var onJump: ((EditorJumpTarget) -> Void)?

    @State private var snapshot: [MIDIInputService.DeviceActivity] = []
    @State private var lastCounter: UInt64 = 0
    @State private var deviceSignature: String = ""
    @State private var openInspector: String?
    @State private var stripWidthEstimate: CGFloat = 600

    /// Keyboard strip range: C0...C8, seven octaves.
    private static let lowNote = 24, highNote = 108
    private static let maxKnobs = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if snapshot.isEmpty {
                devicePanel(placeholderDevice)
            } else {
                ForEach(snapshot) { device in
                    devicePanel(device)
                }
            }
        }
        .onAppear {
            // Live even while the preset is inactive, so the user can watch
            // their gear before flipping the engine on.
            MIDIInputService.shared.start()
            refresh(force: true)
        }
        .onReceive(Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()) { _ in
            // Paused while another app is in front and this window is
            // covered. Kept live when it is still on screen: the usual setup
            // is this window beside a DAW, playing with the DAW in front.
            guard !suspended, NSApp.isActive
                    || MenuBarController.mainWindow?.occlusionState.contains(.visible) == true else { return }
            refresh(force: false)
        }
        // Under the editor it stops; back in view it catches up at once.
        .onChange(of: suspended) { _, now in if !now { refresh(force: true) } }
    }

    private var placeholderDevice: MIDIInputService.DeviceActivity {
        MIDIInputService.DeviceActivity(
            id: "placeholder", name: "MIDI",
            notesDown: [], ccs: [], pitchBend: nil, aftertouch: nil,
            lastProgram: nil, velocities: [:], channelStamps: [:],
            recent: [], eventCount: 0)
    }

    private func refresh(force: Bool) {
        let counter = MIDIInputService.shared.activityCounter()
        let devices = MIDIInputService.shared.connectedDevices()
        let signature = devices.map(\.id).joined(separator: ",")
        guard force || counter != lastCounter || signature != deviceSignature else { return }
        lastCounter = counter
        deviceSignature = signature
        snapshot = MIDIInputService.shared.activitySnapshot()
    }

    /// Standard General MIDI controller names for the knob labels.
    static func ccName(_ cc: Int) -> String? {
        switch cc {
        case 0: return String(localized: "Bank")
        case 1: return String(localized: "Mod Wheel")
        case 2: return String(localized: "Breath")
        case 4: return String(localized: "Foot")
        case 5: return String(localized: "Porta Time")
        case 7: return String(localized: "Volume")
        case 8: return String(localized: "Balance")
        case 10: return String(localized: "Pan")
        case 11: return String(localized: "Expression")
        case 64: return String(localized: "Sustain")
        case 65: return String(localized: "Portamento")
        case 66: return String(localized: "Sostenuto")
        case 67: return String(localized: "Soft Pedal")
        case 71: return String(localized: "Resonance")
        case 72: return String(localized: "Release")
        case 73: return String(localized: "Attack")
        case 74: return String(localized: "Cutoff")
        case 84: return String(localized: "Porta Ctl")
        case 91: return String(localized: "Reverb")
        case 93: return String(localized: "Chorus")
        case 120: return String(localized: "All Sound Off")
        case 123: return String(localized: "All Notes Off")
        default: return nil
        }
    }

    // MARK: Device panel

    @ViewBuilder
    private func devicePanel(_ device: MIDIInputService.DeviceActivity) -> some View {
        let isPlaceholder = device.id == "placeholder"
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "pianokeys")
                    .font(.caption)
                    .foregroundStyle(.pink)
                Text(isPlaceholder
                     ? String(localized: "No MIDI device connected. Plug one in and this goes live")
                     : device.name)
                    .font(.caption.weight(isPlaceholder ? .regular : .semibold))
                    .foregroundStyle(isPlaceholder ? .secondary : .primary)
                Spacer()
                if let program = device.lastProgram {
                    Text("Program \(program)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.pink.opacity(0.14)))
                }
                if !device.notesDown.isEmpty {
                    Text(device.notesDown.sorted().map { MIDIService.noteName($0) }.joined(separator: " "))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.pink)
                        .lineLimit(1)
                }
            }

            keyboardStrip(device)
            knobRow(device)

            HStack(alignment: .top, spacing: 14) {
                bendWidget(device)
                aftertouchWidget(device)
                channelStrip(device)
                Spacer(minLength: 0)
            }

            if !device.recent.isEmpty {
                eventLog(device)
            }
        }
    }

    // MARK: Keyboard strip

    private func boundNotes(deviceID: String) -> Set<Int> {
        var bound: Set<Int> = []
        for group in preset.joysticks {
            for binding in group.bindings
            where binding.input.type == .midi && binding.input.midiKind == .note {
                if let filter = binding.input.midiDeviceID, filter != deviceID { continue }
                bound.insert(binding.input.index)
            }
        }
        return bound
    }

    private static func isBlackKey(_ note: Int) -> Bool {
        [1, 3, 6, 8, 10].contains(note % 12)
    }

    @ViewBuilder
    private func keyboardStrip(_ device: MIDIInputService.DeviceActivity) -> some View {
        let bound = boundNotes(deviceID: device.id)
        let held = device.notesDown
        let velocities = device.velocities
        VStack(alignment: .leading, spacing: 2) {
            Canvas { context, size in
                let whites = (Self.lowNote...Self.highNote).filter { !Self.isBlackKey($0) }
                let whiteW = size.width / CGFloat(whites.count)
                for (i, note) in whites.enumerated() {
                    let rect = CGRect(x: CGFloat(i) * whiteW, y: 0,
                                      width: whiteW - 1, height: size.height)
                    let path = Path(roundedRect: rect, cornerRadius: 1.5)
                    if held.contains(note) {
                        // Velocity shading: soft touches glow lighter.
                        let vel = Double(velocities[note] ?? 100) / 127.0
                        context.fill(path, with: .color(.pink.opacity(0.45 + 0.55 * vel)))
                    } else {
                        context.fill(path, with: .color(.secondary.opacity(0.22)))
                    }
                    if bound.contains(note) {
                        let dot = CGRect(x: rect.midX - 1.5, y: size.height - 6,
                                         width: 3, height: 3)
                        context.fill(Path(ellipseIn: dot),
                                     with: .color(held.contains(note) ? .white : .pink))
                    }
                }
                var whiteIndex = 0
                for note in Self.lowNote...Self.highNote {
                    if Self.isBlackKey(note) {
                        let x = CGFloat(whiteIndex) * whiteW - whiteW * 0.3
                        let rect = CGRect(x: x, y: 0,
                                          width: whiteW * 0.6, height: size.height * 0.6)
                        let path = Path(roundedRect: rect, cornerRadius: 1.5)
                        if held.contains(note) {
                            let vel = Double(velocities[note] ?? 100) / 127.0
                            context.fill(path, with: .color(.pink.opacity(0.45 + 0.55 * vel)))
                        } else {
                            context.fill(path, with: .color(.primary.opacity(0.55)))
                        }
                        if bound.contains(note) {
                            let dot = CGRect(x: rect.midX - 1.5, y: rect.maxY - 5,
                                             width: 3, height: 3)
                            context.fill(Path(ellipseIn: dot),
                                         with: .color(held.contains(note) ? .white : .pink))
                        }
                    } else {
                        whiteIndex += 1
                    }
                }
            }
            .frame(height: 44)
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { stripWidthEstimate = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in stripWidthEstimate = w }
            })
            .contentShape(Rectangle())
            .onTapGesture { location in
                openInspector = "keys-\(device.id)-\(noteAt(location: location))"
            }
            .popover(isPresented: inspectorPresented(prefix: "keys-\(device.id)-")) {
                if let key = openInspector,
                   let note = Int(key.split(separator: "-").last ?? "") {
                    midiInspector(title: String(localized: "\(MIDIService.noteName(note)) (note \(note))"),
                                  kind: .note, number: note, device: device)
                        .environment(\.layoutDirection, appDirection)
                }
            }
            .help("Keys glow with press strength. A dot marks a bound note. Click a key to see its bindings.")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Keyboard")
            .accessibilityValue(held.isEmpty
                ? (bound.count == 1 ? String(localized: "No keys held. 1 bound note") : String(localized: "No keys held. \(bound.count) bound notes"))
                : String(localized: "Held: \(held.sorted().map { MIDIService.noteName($0) }.joined(separator: ", "))"))
            .accessibilityAddTraits(.updatesFrequently)
            // Each bound note's rows without aiming at a key: an action
            // for VoiceOver and Switch Control.
            .accessibilityActions {
                ForEach(bound.sorted(), id: \.self) { note in
                    Button(String(localized: "Show bindings for \(MIDIService.noteName(note))")) {
                        openInspector = "keys-\(device.id)-\(note)"
                    }
                }
            }

            // Octave labels under every C.
            HStack(spacing: 0) {
                let whites = (Self.lowNote...Self.highNote).filter { !Self.isBlackKey($0) }
                ForEach(whites, id: \.self) { note in
                    Text(note % 12 == 0 ? MIDIService.noteName(note) : "")
                        .font(.system(size: 7, weight: .medium).monospaced())
                        .foregroundStyle(.hint)
                        .frame(maxWidth: .infinity)
                }
            }
            // The same from the keyboard and by voice: a menu of the bound notes.
            if !bound.isEmpty {
                Menu {
                    ForEach(bound.sorted(), id: \.self) { note in
                        Button(MIDIService.noteName(note)) { openInspector = "keys-\(device.id)-\(note)" }
                    }
                } label: {
                    Text("Bound notes").font(.caption2)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .environment(\.layoutDirection, appDirection)
            }
        }
        // An instrument: low notes on the left in every language.
        .environment(\.layoutDirection, .leftToRight)
    }

    private func noteAt(location: CGPoint) -> Int {
        let whites = (Self.lowNote...Self.highNote).filter { !Self.isBlackKey($0) }
        // Black keys sit over the top 60 percent of the strip, drawn as in
        // the Canvas above; a click there picks the black key, which could
        // not be inspected when only white keys were hit-tested.
        let whiteW = max(1, stripWidthEstimate) / CGFloat(whites.count)
        if location.y < 44 * 0.6 {
            var whiteIndex = 0
            for note in Self.lowNote...Self.highNote {
                if Self.isBlackKey(note) {
                    let x = CGFloat(whiteIndex) * whiteW - whiteW * 0.3
                    if location.x >= x && location.x <= x + whiteW * 0.6 { return note }
                } else {
                    whiteIndex += 1
                }
            }
        }
        let fraction = max(0, min(0.999, location.x / max(1, stripWidthEstimate)))
        let index = Int(fraction * CGFloat(whites.count))
        return whites[min(index, whites.count - 1)]
    }

    // MARK: Knob row

    private func boundCCs(deviceID: String) -> [Int] {
        var found = Set<Int>()
        for group in preset.joysticks {
            for binding in group.bindings
            where binding.input.type == .midi && binding.input.midiKind == .cc {
                if let filter = binding.input.midiDeviceID, filter != deviceID { continue }
                found.insert(binding.input.index)
            }
        }
        return found.sorted()
    }

    private func ccBadge(cc: Int, deviceID: String) -> (label: String, color: Color)? {
        for group in preset.joysticks {
            for binding in group.bindings
            where binding.input.type == .midi && binding.input.midiKind == .cc
                && binding.input.index == cc {
                if let filter = binding.input.midiDeviceID, filter != deviceID { continue }
                if binding.outputs.contains(where: { $0.type == .absoluteVolume }) {
                    return (String(localized: "Fader"), .teal)
                }
                switch binding.input.midiCCMode {
                case .centered: return (String(localized: "Dial"), .orange)
                case .relative: return (String(localized: "Turn"), .indigo)
                default: return (String(localized: "Switch"), .secondary)
                }
            }
        }
        return nil
    }

    @ViewBuilder
    private func knobRow(_ device: MIDIInputService.DeviceActivity) -> some View {
        // Bound CCs always show, live or at rest, so the panel mirrors the
        // preset before anything is touched; CCs the hardware has sent but
        // the preset doesn't bind follow, most recently moved first.
        let bound = boundCCs(deviceID: device.id)
        let seenByCC = Dictionary(device.ccs.map { ($0.cc, $0) },
                                  uniquingKeysWith: { a, b in a.stamp > b.stamp ? a : b })
        let boundKnobs: [MIDIInputService.CCActivity] = bound.map { cc in
            seenByCC[cc] ?? MIDIInputService.CCActivity(
                deviceID: device.id, channel: 1, cc: cc, value: 0, stamp: 0)
        }
        // One dial per CC (an MPE controller sends one CC on many channels,
        // which drew a dial each and opened their popovers together), and
        // the cap only on the unbound extras: a bound CC past the 16th had
        // no dial at all.
        let extras = device.ccs.filter { !bound.contains($0.cc) && seenByCC[$0.cc]?.id == $0.id }
        let knobs = boundKnobs + extras.prefix(max(0, Self.maxKnobs - boundKnobs.count))
        if knobs.isEmpty {
            Text("Twist a knob or move a slider: every control appears here live.")
                .font(.caption2)
                .foregroundStyle(.hint)
        } else {
            let newest = knobs.map(\.stamp).max() ?? 0
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(knobs) { knob in
                        knobWidget(knob,
                                   isNewest: newest > 0 && knob.stamp == newest,
                                   device: device)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private func knobWidget(_ knob: MIDIInputService.CCActivity, isNewest: Bool,
                            device: MIDIInputService.DeviceActivity) -> some View {
        let badge = ccBadge(cc: knob.cc, deviceID: device.id)
        let fraction = Double(knob.value) / 127.0
        Button {
            openInspector = "cc-\(device.id)-\(knob.cc)"
        } label: {
            VStack(spacing: 3) {
                ZStack {
                    Circle()
                        .trim(from: 0.125, to: 0.875)
                        .stroke(Color.secondary.opacity(0.25),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(90))
                    Circle()
                        .trim(from: 0.125, to: 0.125 + 0.75 * fraction)
                        .stroke(isNewest ? Color.pink : Color.secondary.opacity(0.75),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(90))
                    Text(knob.stamp == 0 ? "-" : "\(knob.value)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(isNewest ? .primary : .secondary)
                }
                .frame(width: 36, height: 36)
                // A knob turns clockwise as it goes up, in every language.
                .environment(\.layoutDirection, .leftToRight)
                Text("CC \(knob.cc)")
                    .font(.system(size: 8, weight: .medium).monospaced())
                    .foregroundStyle(.secondary)
                if let name = Self.ccName(knob.cc) {
                    Text(name)
                        .font(.system(size: 7.5))
                        .foregroundStyle(.hint)
                        .lineLimit(1)
                }
                if let badge {
                    Text(badge.label)
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(badge.color)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(badge.color.opacity(0.14)))
                }
            }
            .frame(width: 62)
        }
        .buttonStyle(.plain)
        .popover(isPresented: inspectorPresented(exact: "cc-\(device.id)-\(knob.cc)")) {
            midiInspector(title: ccTitle(knob.cc), kind: .cc, number: knob.cc, device: device)
        }
        .help("Control Change \(knob.cc)\(Self.ccName(knob.cc).map { " (\($0))" } ?? ""), value \(knob.stamp == 0 ? String(localized: "not seen yet") : String(knob.value)). Click to see its bindings.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ccTitle(knob.cc)
                            + (badge.map { String(localized: ", bound as \($0.label)") } ?? ""))
        .accessibilityValue(knob.stamp == 0 ? String(localized: "not seen yet") : String(localized: "\(knob.value) of 127"))
        .accessibilityHint("Inspects bindings for this control")
        .accessibilityAddTraits(.isButton)
    }

    private func ccTitle(_ cc: Int) -> String {
        if let name = Self.ccName(cc) { return String(localized: "CC \(cc), \(name)") }
        return String(localized: "CC \(cc)")
    }

    // MARK: Meters

    @ViewBuilder
    private func bendWidget(_ device: MIDIInputService.DeviceActivity) -> some View {
        let bend = device.pitchBend ?? 0
        Button {
            openInspector = "bend-\(device.id)"
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pitch Bend")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                        .frame(width: 90, height: 6)
                    Rectangle().fill(Color.secondary.opacity(0.5))
                        .frame(width: 1, height: 10)
                        .offset(x: 45)
                    Circle()
                        .fill(abs(bend) > 0.01 ? Color.pink : Color.secondary)
                        .frame(width: 10, height: 10)
                        .offset(x: 40 + CGFloat(bend) * 45)
                }
                .frame(height: 12)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pitch Bend")
        .accessibilityValue(abs(bend) < 0.01 ? String(localized: "centered") : String(localized: "\(Int((bend * 100).rounded())) percent"))
        .accessibilityHint("Inspects bindings for this control")
        .accessibilityAddTraits(.isButton)
        .popover(isPresented: inspectorPresented(exact: "bend-\(device.id)")) {
            midiInspector(title: String(localized: "Pitch Bend"), kind: .pitchBend, number: nil, device: device)
        }
    }

    @ViewBuilder
    private func aftertouchWidget(_ device: MIDIInputService.DeviceActivity) -> some View {
        let touch = device.aftertouch ?? 0
        Button {
            openInspector = "touch-\(device.id)"
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Aftertouch")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                        .frame(width: 60, height: 6)
                    Capsule()
                        .fill(touch > 0 ? Color.pink : Color.clear)
                        .frame(width: max(0, 60 * CGFloat(touch) / 127), height: 6)
                }
                .frame(height: 12)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Aftertouch")
        .accessibilityValue("\(touch) of 127")
        .accessibilityHint("Inspects bindings for this control")
        .accessibilityAddTraits(.isButton)
        .popover(isPresented: inspectorPresented(exact: "touch-\(device.id)")) {
            midiInspector(title: String(localized: "Aftertouch"), kind: .aftertouch, number: nil, device: device)
        }
    }

    /// Sixteen channel slots; ones this device has spoken on fill in, and
    /// the freshest is highlighted.
    @ViewBuilder
    private func channelStrip(_ device: MIDIInputService.DeviceActivity) -> some View {
        let freshest = device.channelStamps.max(by: { $0.value < $1.value })?.key
        VStack(alignment: .leading, spacing: 2) {
            Text("Channels")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 3) {
                ForEach(1...16, id: \.self) { channel in
                    let seen = device.channelStamps[channel] != nil
                    Circle()
                        .fill(channel == freshest ? Color.pink
                              : seen ? Color.secondary.opacity(0.6)
                              : Color.secondary.opacity(0.15))
                        .frame(width: 6, height: 6)
                        .help(seen ? String(localized: "Channel \(channel)") : String(localized: "Channel \(channel) - no messages yet"))
                }
            }
            .frame(height: 12)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Channels")
        .accessibilityValue(device.channelStamps.isEmpty
            ? String(localized: "No messages yet")
            : String(localized: "Heard on \(device.channelStamps.keys.sorted().map(String.init).joined(separator: ", "))")
                + (freshest.map { String(localized: ", latest \($0)") } ?? ""))
    }

    // MARK: Event log

    @ViewBuilder
    private func eventLog(_ device: MIDIInputService.DeviceActivity) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(device.recent.prefix(4).enumerated()), id: \.offset) { index, line in
                    Text(line)
                        .font(.system(size: 8.5).monospaced())
                        .foregroundStyle(index == 0 ? Color.secondary : Color.secondary.opacity(0.55))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if device.eventCount > 0 {
                Text("\(device.eventCount) events")
                    .font(.system(size: 8.5).monospaced())
                    .foregroundStyle(.hint)
            }
        }
        .padding(.top, 2)
    }

    // MARK: Inspector

    private func inspectorPresented(exact: String) -> Binding<Bool> {
        Binding(get: { openInspector == exact },
                set: { if !$0 { openInspector = nil } })
    }

    private func inspectorPresented(prefix: String) -> Binding<Bool> {
        Binding(get: { openInspector?.hasPrefix(prefix) == true },
                set: { if !$0 { openInspector = nil } })
    }

    private struct MIDIBindingMatch: Identifiable {
        let id: UUID
        let joystickIndex: Int
        let binding: BindingModel
    }

    private func matches(kind: MIDIInputKind, number: Int?, deviceID: String) -> [MIDIBindingMatch] {
        var found: [MIDIBindingMatch] = []
        for (joystickIndex, group) in preset.joysticks.enumerated() {
            for binding in group.bindings
            where binding.input.type == .midi && binding.input.midiKind == kind {
                if let number, binding.input.index != number { continue }
                if let filter = binding.input.midiDeviceID, filter != deviceID { continue }
                found.append(MIDIBindingMatch(id: binding.id,
                                              joystickIndex: joystickIndex,
                                              binding: binding))
            }
        }
        return found
    }

    @ViewBuilder
    private func midiInspector(title: String, kind: MIDIInputKind, number: Int?,
                               device: MIDIInputService.DeviceActivity) -> some View {
        let matchingBindings = matches(kind: kind, number: number, deviceID: device.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                Spacer()
                if !matchingBindings.isEmpty {
                    Text("\(matchingBindings.count) bound")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if matchingBindings.isEmpty {
                Text("No bindings in this preset target this input.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(matchingBindings) { match in
                    Button {
                        openInspector = nil
                        // The row itself, so a second row on the same input
                        // opens that row; after the popover has closed.
                        let target = EditorJumpTarget(joystickIndex: match.joystickIndex,
                                                      inputSerialized: match.binding.input.serialized,
                                                      bindingID: match.binding.id)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { onJump?(target) }
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(match.binding.input.displayName)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(OutputAction.names(match.binding.outputs).joined(separator: " + "))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.forward.circle")
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(minWidth: 230, alignment: .leading)
    }
}
