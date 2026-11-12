import SwiftUI
import Combine

/// Edit Layout, Reset (while editing), and the zoom for one visualizer,
/// drawn by the host on the Live Visualizer title row.
struct VisualizerHeaderControls: View {
    @Bindable var control: VisualizerControlState

    var body: some View {
        #if DEBUG
        let _ = BodyRuns.note("VisualizerHeaderControls")
        #endif
        HStack(spacing: 10) {
            Button {
                control.editMode.toggle()
            } label: {
                Label(control.editMode ? String(localized: "Done Editing") : String(localized: "Edit Layout"),
                      systemImage: control.editMode ? "checkmark.circle.fill" : "pencil.and.outline")
            }
            // Black text and icon on the blue, as on the Quick Start Guide button.
            .buttonStyle(SolidButton(tint: control.editMode ? .green : .blue, size: .compact,
                                     label: control.editMode ? nil : .black))
            .disabled(control.showingModel && !control.editMode)
            .help(control.showingModel ? String(localized: "The controller is drawn as it is built, so its controls stay in place")
                  : (control.editMode ? String(localized: "Finish customizing") : String(localized: "Drag widgets to rearrange the layout, or right-click one to move it a step at a time")))
            .spotlightAnchor(SpotlightID.customizeButton)

            if control.editMode {
                Button {
                    control.resetToken += 1
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .font(.callout)
                }
                .buttonStyle(.solidSecondary)
                .help("Reset all widgets to their default position")
            }

            // Zoom: minus, slider, plus. Kept with the map's position for
            // each preset and group (see VirtualControllerView.saveView).
            HStack(spacing: 4) {
                Button {
                    control.scale = max(0.3, control.scale - 0.1)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                        .font(.caption)
                        .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .help("Shrink visualizer")
                .accessibilityLabel("Shrink visualizer")

                Slider(value: $control.scale, in: 0.3...1.5)
                    .frame(width: 80)
                    .help("Resize the live visualizer content")
                    .accessibilityLabel("Visualizer size")
                    .accessibilityValue(String(localized: "\(String(format: "%.0f", control.scale * 100)) percent"))

                Button {
                    control.scale = min(1.5, control.scale + 0.1)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.caption)
                        .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .help("Enlarge visualizer")
                .accessibilityLabel("Enlarge visualizer")
            }
        }
    }
}


/// Color for a region's palette index, shared by every region map.
func regionPaletteColor(at index: Int) -> Color {
    let palette = TouchpadRegion.colorPalette
    let safe = max(0, min(palette.count - 1, index))
    switch palette[safe] {
    case "red":    return .red
    case "orange": return .orange
    case "yellow": return .yellow
    case "green":  return .green
    case "mint":   return .mint
    case "teal":   return .teal
    case "cyan":   return .cyan
    case "blue":   return .blue
    case "indigo": return .indigo
    case "purple": return .purple
    case "pink":   return .pink
    case "brown":  return .brown
    default:       return .gray
    }
}

/// A surface with regions drawn on it and a live point moving over it:
/// the screen for cursor regions, a stick's travel for stick regions.
/// A region the point is inside lights up, the same way a pressed
/// touchpad zone does, so the map reads without the preset running.
struct RegionMapView: View {
    let title: String
    let systemImage: String
    /// Width divided by height of the surface being drawn.
    let aspect: CGFloat
    let regions: [TouchpadRegion]
    /// Live position on the surface, 0...1 in both axes.
    let point: CGPoint
    let pointLabel: String
    /// The screen map follows the real pointer: it observes the cursor
    /// service and keeps its sampling alive while the map is on screen.
    var liveCursor: Bool = false
    /// The screen map shows this display rather than the pointer's when
    /// set: its shape, its regions, and the pointer only while it is there.
    var displayOverride: DisplayKey? = nil
    /// The Screen template's map: wider and taller than the side maps.
    var large: Bool = false
    /// Clicking a region goes to the row that binds it, the same as
    /// clicking a button on the controller map. Nil leaves the map
    /// read-only.
    var onPick: ((TouchpadRegion) -> Void)?
    /// The map's spoken name when no title is drawn (a stick's popover).
    var accessibilityName: String? = nil
    /// Wraps a region in the visualizer's inspector, the popover that lists
    /// its rows with a way to each and to the region's editor. Used in place
    /// of `onPick` when set.
    var inspect: ((TouchpadRegion, AnyView) -> AnyView)? = nil

    private var cursorService: CursorRegionService { CursorRegionService.shared }
    @Environment(\.visualizerSuspended) private var suspended
    @State private var tracking = false

    private func setTracking(_ on: Bool) {
        guard on != tracking else { return }
        tracking = on
        if on { cursorService.beginTracking() } else { cursorService.endTracking() }
    }

    private var livePoint: CGPoint { liveCursor ? cursorService.cursorNormalized : point }

    /// The display the map represents.
    private var shownDisplay: DisplayKey? { displayOverride ?? cursorService.currentDisplay }
    /// Whether the pointer is on the display the map represents.
    private var pointerIsHere: Bool {
        !liveCursor || displayOverride == nil || displayOverride == cursorService.currentDisplay
    }

    /// The screen map is drawn in the shape of the display the pointer is
    /// actually on. Drawn at a fixed 16:10 it lied on every other display:
    /// a region that covers the right third of an ultrawide was drawn as a
    /// much taller box than the one it fires in.
    private var drawnAspect: CGFloat {
        guard liveCursor else { return aspect }
        let live = cursorService.aspect(of: displayOverride) ?? cursorService.currentScreenAspect
        return max(0.5, min(4.0, live))
    }

    /// What the map is showing: the display name, and a note when there is
    /// more than one, because these regions follow the pointer onto any
    /// display rather than belonging to one of them.
    private var subtitle: String? {
        guard liveCursor else { return nil }
        let name = shownDisplay?.name ?? cursorService.currentScreenName
        guard !name.isEmpty else { return nil }
        let here = regions.filter { cursorService.regionApplies($0, on: shownDisplay) }.count
        if here < regions.count {
            return String(localized: "\(name): \(here) of \(regions.count) regions apply here")
        }
        let perDisplay = regions.contains { $0.display != nil }
        return cursorService.screenCount > 1 && !perDisplay
            ? String(localized: "\(name), and every other display")
            : name
    }

    private var inside: Set<UUID> {
        guard pointerIsHere else { return [] }
        let p = livePoint
        return Set(regions.filter { applies($0) && $0.contains(normalizedX: p.x, y: p.y) }.map(\.id))
    }

    /// Whether the region counts on the display the map is showing. Only
    /// the screen map distinguishes: a stick or pad zone always applies.
    private func applies(_ region: TouchpadRegion) -> Bool {
        !liveCursor || cursorService.regionApplies(region, on: shownDisplay)
    }

    // Observes the cursor only while it draws it live: a stick or touchpad
    // zone map, or a map under the editor, does not redraw on every
    // pointer move.
    var body: some View {
        // The hold on the cursor sampler lives on this container, which
        // keeps its identity across the swap below: on the inner view, the
        // new branch's onAppear ran before the old one's onDisappear and
        // the hold was let go just after it was taken.
        VStack(spacing: 0) {
            if liveCursor && !suspended { CursorRegionObserver { mapBody } } else { mapBody }
        }
        // Its own hold on the cursor sampler, let go under the editor.
        .onAppear { setTracking(liveCursor && !suspended) }
        .onDisappear { setTracking(false) }
        .onChange(of: suspended) { _, now in setTracking(liveCursor && !now) }
    }

    @ViewBuilder
    private var mapBody: some View {
        let hot = inside
        let point = livePoint
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                if !title.isEmpty {
                    HStack {
                        Label(title, systemImage: systemImage)
                            .font(.callout.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        Text(regions.count == 1 ? String(localized: "1 region") : String(localized: "\(regions.count) regions"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.hint)
                        .lineLimit(1)
                }
            }
            GeometryReader { geo in
                // Fit inside the box rather than deriving height from width
                // alone: a 16:10 display at the full width came out taller
                // than the frame, so the bottom of the map, and any region
                // living there, was clipped away.
                let h = min(geo.size.height, geo.size.width / drawnAspect)
                let w = h * drawnAspect
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.22))
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                    // Center lines, so a stick's neutral and a screen's
                    // middle are obvious.
                    Path { p in
                        p.move(to: CGPoint(x: w / 2, y: 4)); p.addLine(to: CGPoint(x: w / 2, y: h - 4))
                        p.move(to: CGPoint(x: 6, y: h / 2)); p.addLine(to: CGPoint(x: w - 6, y: h / 2))
                    }
                    .stroke(Color.secondary.opacity(0.16), lineWidth: 0.5)

                    ForEach(regions) { region in
                        let lit = hot.contains(region.id)
                        // A region for another display is drawn faint, so
                        // it is visible but clearly not live here.
                        let here = applies(region)
                        let color = regionPaletteColor(at: region.colorIndex).opacity(here ? 1 : 0.35)
                        let box = region.drawnBox
                        let rect = CGRect(x: box.minX * w, y: box.minY * h,
                                          width: box.width * w,
                                          height: box.height * h)
                        let swatch = ZoneSwatch(ring: region.ring, color: color, fill: lit ? 0.55 : 0.16,
                                                stroke: lit ? 1 : 0.5, lineWidth: lit ? 2 : 1)
                            .overlay(
                                // A small corner region has no room for its
                                // name; the color and the tooltip carry it.
                                Group {
                                    if rect.width >= 42 && rect.height >= 18 {
                                        Text(region.shownName)
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(lit ? .white : .secondary)
                                            .lineLimit(1)
                                            .padding(.horizontal, 2)
                                    }
                                }
                            )
                            .frame(width: max(8, rect.width), height: max(8, rect.height))
                            .contentShape(ZoneHitShape(ring: region.ring))
                        Group {
                            if let inspect {
                                inspect(region, AnyView(swatch.accessibilityLabel(region.shownName)))
                                    .help("\(region.shownName). Click to see its rows.")
                            } else if let onPick {
                                Button { onPick(region) } label: { swatch }
                                    .buttonStyle(.plain)
                                    .help("\(region.shownName). Click to go to its row.")
                                    .accessibilityLabel(region.shownName)
                                    .accessibilityValue(lit ? String(localized: "Active") : "")
                            } else {
                                swatch.help(region.shownName)
                            }
                        }
                        .position(x: rect.midX, y: rect.midY)
                        .animation(.easeOut(duration: 0.12), value: lit)
                    }

                    // The live point, only while the pointer is on this display.
                    if pointerIsHere {
                        Circle()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: 8, height: 8)
                            .shadow(color: .black.opacity(0.5), radius: 2)
                            .position(x: min(max(0, point.x), 1) * w,
                                      y: min(max(0, point.y), 1) * h)
                    }
                }
                .frame(width: w, height: h)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                // Centered in whatever space is left over once it is fitted.
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                // A map of the screen or the stick: left is left in every
                // language (the inspect popovers put the app's direction back).
                .environment(\.layoutDirection, .leftToRight)
            }
            .frame(height: large ? 300 : (drawnAspect > 1.2 ? 170 : 200))
            .frame(maxWidth: large ? 520 : (drawnAspect > 1.2 ? 320 : 220))
            // Clickable regions stay reachable with VoiceOver.
            // Clickable regions stay reachable with VoiceOver and Voice Control.
            .accessibilityElement(children: inspect != nil || onPick != nil ? .contain : .ignore)
            .accessibilityLabel(accessibilityName ?? (title.isEmpty ? String(localized: "Screen regions") : title))
            .accessibilityValue(hot.isEmpty
                                ? String(localized: "\(pointLabel) outside every region")
                                : String(localized: "\(pointLabel) inside \(regions.filter { hot.contains($0.id) }.map(\.shownName).joined(separator: ", "))"))
        }
        .padding(.top, 4)
    }
}


/// A preset's bands on one axis's travel: a bar with the low end at the
/// bottom, each band across it, lit while the live reading is inside.
struct BandMapView: View {
    let title: String
    let axis: Int
    let regions: [TouchpadRegion]
    /// Live reading, 0...1 of the travel.
    let fraction: Double
    var inspect: ((TouchpadRegion, AnyView) -> AnyView)? = nil
    /// Clicking a band goes to its row (in a control's popover).
    var onPick: ((TouchpadRegion) -> Void)? = nil
    /// The map's spoken name when no title is drawn (a trigger's popover).
    var accessibilityName: String? = nil

    var body: some View {
        let hot = Set(regions.filter { $0.maxY > $0.minY && $0.containsTravel(fraction) }.map(\.id))
        let ends = StickRegionService.travelEnds(axis: axis)
        VStack(alignment: .leading, spacing: 6) {
            if !title.isEmpty {
            HStack {
                Label(title, systemImage: "slider.vertical.3")
                    .font(.callout.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text(regions.count == 1 ? String(localized: "1 region") : String(localized: "\(regions.count) regions"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            }
            HStack(alignment: .top, spacing: 8) {
                GeometryReader { geo in
                    let w = geo.size.width, h = geo.size.height
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.22))
                        RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                        ForEach(regions) { region in
                            let lit = hot.contains(region.id)
                            let color = regionPaletteColor(at: region.colorIndex)
                            let rect = CGRect(x: 4, y: (1 - region.maxY) * h, width: w - 8,
                                              height: max(6, (region.maxY - region.minY) * h))
                            let swatch = ZoneSwatch(ring: nil, color: color, fill: lit ? 0.55 : 0.16,
                                                    stroke: lit ? 1 : 0.5, lineWidth: lit ? 2 : 1)
                                .overlay(Group {
                                    if rect.height >= 14 {
                                        Text(region.shownName)
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(lit ? .white : .secondary)
                                            .lineLimit(1)
                                            .padding(.horizontal, 2)
                                    }
                                })
                                .frame(width: rect.width, height: rect.height)
                            Group {
                                if let inspect {
                                    inspect(region, AnyView(swatch.accessibilityLabel(region.shownName)))
                                        .help("\(region.shownName). Click to see its rows.")
                                } else if let onPick {
                                    Button { onPick(region) } label: { swatch }
                                        .buttonStyle(.plain)
                                        .help("\(region.shownName). Click to go to its row.")
                                        .accessibilityLabel(region.shownName)
                                        .accessibilityValue(lit ? String(localized: "Active") : "")
                                } else {
                                    swatch.help(region.shownName)
                                }
                            }
                            .position(x: rect.midX, y: rect.midY)
                            .animation(.easeOut(duration: 0.12), value: lit)
                        }
                        Rectangle()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: w, height: 2)
                            .shadow(color: .black.opacity(0.5), radius: 2)
                            .position(x: w / 2, y: (1 - min(1, max(0, fraction))) * h)
                            .allowsHitTesting(false)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .frame(width: 110, height: 170)
                VStack(alignment: .leading) {
                    Text(ends.high).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text(ends.low).font(.caption2).foregroundStyle(.secondary)
                }
                .frame(height: 170)
                .accessibilityHidden(true)
            }
            .accessibilityElement(children: inspect != nil || onPick != nil ? .contain : .ignore)
            .accessibilityLabel(accessibilityName ?? title)
            .accessibilityValue(hot.isEmpty
                                ? String(localized: "Outside every band, at \(fraction.formatted(.percent.precision(.fractionLength(0)))) of the travel")
                                : String(localized: "Inside \(regions.filter { hot.contains($0.id) }.map(\.shownName).joined(separator: ", "))"))
        }
        .padding(.top, 4)
    }
}


/// What a knock on the Mac does in this preset, and which gesture just
/// landed. Lights the matching chip for a moment, the way a pressed button
/// lights on the controller map.
struct TapMapView: View {
    @State private var sensorReason = "visualizer-" + UUID().uuidString
    let counts: [Int]
    @ObservedObject private var activity = ChassisTapActivity.shared

    private static let names = ["", String(localized: "Single"), String(localized: "Double"), String(localized: "Triple"), String(localized: "Quadruple"), String(localized: "Quintuple")]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Taps on the Mac", systemImage: "hand.tap.fill")
                    .font(.callout.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text("knock on the palm rest")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach(counts, id: \.self) { count in
                    chip(count)
                }
            }
        }
        .padding(.top, 4)
        // Keep the sensor awake while the map is on screen, so a knock
        // lights a chip whether or not the preset is running.
        // A reason of its own per map: with one shared reason, the first map
        // to go away stopped the sensor under another still on screen.
        .onAppear { ChassisTapService.shared.retain(sensorReason) }
        .onDisappear { ChassisTapService.shared.release(sensorReason) }
    }

    /// One tap count as a chip that lights when that gesture fires.
    @ViewBuilder
    private func chip(_ count: Int) -> some View {
        let lit: Bool = activity.activeKeys.contains("cht \(count)")
        let fill: Color = lit ? Color.orange.opacity(0.75) : Color.secondary.opacity(0.12)
        let edge: Color = lit ? Color.orange : Color.secondary.opacity(0.3)
        let name: String = Self.names[min(5, count)]
        VStack(spacing: 2) {
            Text("\(count)")
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(lit ? Color.white : Color.secondary)
            Text(name)
                .font(.system(size: 9))
                .foregroundStyle(lit ? Color.white.opacity(0.9) : Color.secondary.opacity(0.7))
        }
        .frame(width: 62, height: 46)
        .background(RoundedRectangle(cornerRadius: 8).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(edge, lineWidth: 1))
        .animation(.easeOut(duration: 0.12), value: lit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) tap")
        .accessibilityValue(lit ? String(localized: "just fired") : String(localized: "idle"))
    }
}

#if DEBUG
/// Marketing capture: the phrase shown as just heard, with the panel listening
/// and its rows narrowed so the lit dot sits beside the words
/// (inputconfig.debug.fakeheard). Never compiled into Release.
nonisolated(unsafe) var debugVoiceHeardWords: String?
#endif

/// The preset's screen color and screen text watches and voice phrases
/// under the map, each with what its service reads now: the saved color
/// beside the live one, the words last read, the transcript, and a dot
/// while a row counts as pressed, found or heard. The services sample
/// only while a preset with such rows runs or its sheet is open; this
/// list starts nothing, and says Not running until one of them does.
struct ScreenVoiceStatusView: View {
    let preset: Preset
    /// False while nobody is looking (another app in front, the editor
    /// sheet up): the services are then read once and not observed, so
    /// their samples do not redraw the list.
    let live: Bool

    var body: some View {
        if live {
            Live(preset: preset)
        } else {
            Content(preset: preset, snapshot: Snapshot())
        }
    }

    /// Observes the three services, so only this list redraws on a sample.
    private struct Live: View {
        let preset: Preset
        @ObservedObject private var pixels = ScreenPixelService.shared
        @ObservedObject private var texts = ScreenTextService.shared
        @ObservedObject private var voice = VoicePhraseService.shared
        var body: some View { Content(preset: preset, snapshot: Snapshot()) }
    }

    /// What the services publish, in one value: the list below redraws
    /// when it changes and not otherwise.
    struct Snapshot: Equatable {
        var samples: [UUID: ScreenPixelService.Sample]
        var readings: [UUID: ScreenTextService.Reading]
        var lastHeard: [UUID: TimeInterval]
        var transcript: String
        var listening: Bool
        var problem: String?
        var screenRunning: Bool
        var voiceRunning: Bool

        @MainActor init() {
            samples = ScreenPixelService.shared.samples
            readings = ScreenTextService.shared.readings
            lastHeard = VoicePhraseService.shared.lastHeard
            transcript = VoicePhraseService.shared.transcript
            listening = VoicePhraseService.shared.listening
            problem = VoicePhraseService.shared.problem
            screenRunning = ScreenPixelService.shared.isTracking || ScreenTextService.shared.isTracking
            voiceRunning = VoicePhraseService.shared.isTracking
        }
    }

    /// How long the heard dot stays lit after a phrase, as in its sheet.
    private static let heardSeconds: TimeInterval = 1.5

    private struct Content: View {
        let preset: Preset
        let snapshot: Snapshot
        /// Bumped when the newest press pulse or heard dot has run out, so
        /// the dot goes dark without a clock: the services publish nothing
        /// when a pulse ends.
        @State private var pulseTick = 0
        @State private var heardBefore: TimeInterval = ProcessInfo.processInfo.systemUptime

        /// This preset is the one running: another one's screen and voice
        /// tracking made this list look live, with its microphone's words.
        private var isRunningPreset: Bool { MappingEngine.current?.activePreset?.id == preset.id }

        private var running: Bool {
            #if DEBUG
            if debugVoiceHeardWords != nil { return true }
            #endif
            return isRunningPreset && ((snapshot.screenRunning && (!preset.screenPixels.isEmpty || !preset.screenTexts.isEmpty))
                || (snapshot.voiceRunning && !preset.voicePhrases.isEmpty))
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Screen and voice", systemImage: "eye")
                        .font(.callout.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    if !running {
                        Text("Not running")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(preset.screenPixels) { w in pixelRow(w) }
                ForEach(preset.screenTexts) { w in textRow(w) }
                if !preset.voicePhrases.isEmpty {
                    listeningRow
                    ForEach(preset.voicePhrases) { p in phraseRow(p) }
                }
            }
            .padding(.top, 4)
            // A press pulse (Change and Appears modes) and a heard dot end on
            // their own; one sleep per change turns the dot off on time.
            .task(id: snapshot) {
                let pulse = max(ScreenPixelService.pulseSeconds, ScreenTextService.pulseSeconds)
                try? await Task.sleep(for: .seconds(pulse + 0.05))
                guard !Task.isCancelled else { return }
                pulseTick &+= 1
                try? await Task.sleep(for: .seconds(ScreenVoiceStatusView.heardSeconds - pulse))
                guard !Task.isCancelled else { return }
                heardBefore = ProcessInfo.processInfo.systemUptime
            }
        }

        /// The service's answer now. `pulseTick` is read so the row is
        /// drawn again when the pulse has run out.
        private func pressed(_ id: UUID, tick: Int) -> Bool {
            _ = tick
            return ScreenPixelService.shared.isPressed(id)
        }

        private func found(_ id: UUID, tick: Int) -> Bool {
            _ = tick
            return ScreenTextService.shared.isPressed(id) || snapshot.readings[id]?.found == true
        }

        private func heard(_ id: UUID) -> Bool {
            guard let t = snapshot.lastHeard[id] else { return false }
            return t > heardBefore && ProcessInfo.processInfo.systemUptime - t < ScreenVoiceStatusView.heardSeconds
        }

        private func liveDot(_ on: Bool) -> some View {
            Circle().fill(on ? Color.green : Color.secondary.opacity(0.25)).frame(width: 8, height: 8)
        }

        @ViewBuilder
        private func pixelRow(_ w: ScreenPixelWatch) -> some View {
            let on = pressed(w.id, tick: pulseTick)
            let live = snapshot.samples[w.id]
            HStack(spacing: 8) {
                ScreenPixelsView.swatch(w.red, w.green, w.blue, size: 14)
                if let live {
                    ScreenPixelsView.swatch(live.red, live.green, live.blue, size: 14)
                } else {
                    RoundedRectangle(cornerRadius: 3.5)
                        .strokeBorder(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        .frame(width: 14, height: 14)
                }
                Text(w.shownName).font(.caption).lineLimit(1)
                Spacer()
                liveDot(on)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(w.shownName)
            .accessibilityValue(on ? String(localized: "Pressed") : String(localized: "Not pressed"))
        }

        @ViewBuilder
        private func textRow(_ w: ScreenTextWatch) -> some View {
            let on = found(w.id, tick: pulseTick)
            let text = snapshot.readings[w.id]?.text ?? ""
            HStack(spacing: 8) {
                Circle().fill(regionPaletteColor(at: w.colorIndex)).frame(width: 10, height: 10)
                Text(w.shownName).font(.caption).lineLimit(1)
                if !text.isEmpty {
                    Text(text)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
                liveDot(on)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(w.shownName)
            .accessibilityValue(on ? String(localized: "Found") : String(localized: "Not found"))
        }

        private var listeningNow: Bool {
            #if DEBUG
            if debugVoiceHeardWords != nil { return true }
            #endif
            return snapshot.listening && isRunningPreset
        }

        /// The rows at full width, or narrowed for the marketing capture.
        private var rowWidth: CGFloat {
            #if DEBUG
            if debugVoiceHeardWords != nil { return 172 }
            #endif
            return .infinity
        }

        private var listeningRow: some View {
            HStack(spacing: 8) {
                let listening = listeningNow
                liveDot(listening)
                Text(listening ? "Listening" : "Not listening")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(listening ? .primary : .secondary)
                if isRunningPreset, let problem = snapshot.problem {
                    Text(problem).font(.caption2).foregroundStyle(.orange).lineLimit(1)
                } else if listening, !snapshot.transcript.isEmpty {
                    Text(String(snapshot.transcript.suffix(140)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer()
            }
            .frame(maxWidth: rowWidth, alignment: .leading)
            .accessibilityElement(children: .combine)
        }

        private func heardNow(_ p: VoicePhrase) -> Bool {
            #if DEBUG
            if let words = debugVoiceHeardWords { return p.phrase == words }
            #endif
            return heard(p.id)
        }

        @ViewBuilder
        private func phraseRow(_ p: VoicePhrase) -> some View {
            let on = heardNow(p)
            HStack(spacing: 8) {
                Circle().fill(regionPaletteColor(at: p.colorIndex)).frame(width: 10, height: 10)
                Text(p.shownName).font(.caption).lineLimit(1)
                Spacer()
                liveDot(on)
            }
            .frame(maxWidth: rowWidth, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(p.shownName)
            .accessibilityValue(on ? String(localized: "Heard") : String(localized: "idle"))
        }
    }
}
