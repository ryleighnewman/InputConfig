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

    /// The row being tuned. While the sheet is open its sliders are
    /// previewed on that row (MappingEngine.deadzonePreview), so the rows
    /// behind it light by the new values before Save.
    var rowID: UUID? = nil
    /// The zones key Edit zones opens on: a zone row's own (a band on a
    /// stick's axis opens that band's axis, not the stick). Nil: worked out
    /// from the axis.
    var zonesKey: Int? = nil
    /// The row's way along a single axis, and Rests at one end, so the
    /// gauge reads the axis as the engine does.
    var direction: AxisDirection? = nil
    var fullTravel = false

    @EnvironmentObject var controllerService: GameControllerService
    @Environment(\.appTextScale) private var textScale
    /// The preset's zones, drawn over the plot so a deadzone can be set
    /// with the zones it feeds in view.
    @ObservedObject private var zones = StickRegionService.shared
    @State private var showZones = false

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
    /// Saved, so the preview stays until the editor's live apply has the
    /// new values (a moment later), rather than flicking back to the old.
    @State private var saved = false

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

    /// The zones on what this sheet plots: the stick's plane zones, or a
    /// trigger's bands (the gauge shows a trigger's own travel, which is
    /// what a band measures; other single axes show distance from rest).
    private var shownZones: [TouchpadRegion] {
        if is2D { return zones.regions(forStick: axisPair.x == 0 ? 0 : 1) }
        if isTrigger { return zones.regions(forStick: StickRegionService.bandKeyBase + axisIndex) }
        return []
    }

    /// What each slider does, in the colors the drawing uses. The green
    /// line is not a limit: past it the row keeps working, at full strength.
    private var innerMeaning: String {
        is2D ? String(localized: "Inside the red ring nothing happens, so a stick that drifts at rest is ignored.")
             : String(localized: "In the red band nothing happens, so a light rest on the control is ignored.")
    }

    private var outerMeaning: String {
        is2D ? String(localized: "Anything past the green ring counts as pushed all the way. The row keeps working out there, at full strength.")
             : String(localized: "Anything in the green band counts as pushed all the way. The row keeps working there, at full strength.")
    }

    private func zoneIsLit(_ r: TouchpadRegion) -> Bool {
        // The zones are drawn as the stick reads; this row's Invert mirrors
        // only its own dot.
        let sx = isInverted ? -currentX : currentX, sy = isInverted ? -currentY : currentY
        if is2D { return hypot(sx, sy) >= 0.25 && r.contains(normalizedX: Double(sx + 1) / 2, y: Double(sy + 1) / 2) }
        return r.maxY > r.minY && r.containsTravel(Double(max(0, min(1, currentX))))
    }

    private var title: String {
        switch axisIndex {
        case 0, 1: return String(localized: "Left Thumbstick Deadzone")
        case 2, 3: return String(localized: "Right Thumbstick Deadzone")
        case 4:    return String(localized: "Left Trigger Deadzone")
        case 5:    return String(localized: "Right Trigger Deadzone")
        default:   return String(localized: "Axis \(axisIndex) Deadzone")
        }
    }

    /// Whether this axis has any zone, plane or band, as the row's
    /// direction menu counts them: the button reads Edit then.
    private var hasAnyZones: Bool {
        !shownZones.isEmpty
            || !zones.regions(forStick: StickRegionService.bandKeyBase + axisIndex).isEmpty
            || (is2D && axisPair.y.map { !zones.regions(forStick: StickRegionService.bandKeyBase + $0).isEmpty } == true)
            || zonesKey.map { !zones.regions(forStick: $0).isEmpty } == true
    }

    /// One whole sentence per kind, so a language that agrees a pronoun
    /// with the noun (French, Italian) can; the names join as a locale list.
    @ViewBuilder
    private var zonesCaption: some View {
        if !shownZones.isEmpty {
            let names = shownZones.map(\.shownName).formatted(.list(type: .and))
            Text(is2D
                 ? String(localized: "Outlined: the regions on this stick, lit while it is inside one: \(names).")
                 : String(localized: "Outlined: the regions on this trigger, lit while it is inside one: \(names)."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The zones are drawn in the editor, in the row's group: this keeps
    /// what was set here, closes, and shows them there. Without a row (a
    /// preview), the zone sheet opens instead.
    private var zonesButton: some View {
        Button(!hasAnyZones
               ? String(localized: "Draw a region on this stick or trigger\u{2026}")
               : String(localized: "Edit regions\u{2026}")) {
            guard let rowID else { showZones = true; return }
            if inner != deadzone { deadzone = inner }
            if outer != outerDeadzone { outerDeadzone = outer }
            saved = true
            onClose()
            let part = ZonePart(regionKey: zonesKey ?? (is2D ? (axisPair.x == 0 ? 0 : 1) : StickRegionService.bandKeyBase + axisIndex))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                ShowZonesRequest(bindingID: rowID, part: part).post()
            }
        }
            .buttonStyle(.solidSecondaryCompact)
            .fixedSize()
            .accessibilityInputLabels([Text("Edit regions"), Text("Draw a region"), Text("Regions")])
            .accessibilityHint("Opens the region editor for this stick or trigger")
    }

    /// Everything under the title bar.
    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
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
            // The caption beside the button when they fit, under it when
            // larger text leaves no room, so the button is never squeezed.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    zonesCaption
                    Spacer(minLength: 0)
                    zonesButton
                }
                VStack(alignment: .leading, spacing: 6) {
                    zonesCaption
                    zonesButton
                }
            }
            .sheet(isPresented: $showZones) {
                StickRegionsView(startKey: zonesKey ?? (is2D ? (axisPair.x == 0 ? 0 : 1) : StickRegionService.bandKeyBase + axisIndex),
                                 slot: slot)
                    .glassBackground()
            }

            Divider()

            // Inner deadzone slider
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Deadzone")
                        .font(.subheadline)
                    Spacer()
                    Text(Self.percent(inner))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $inner, in: 0.01...0.9, step: 0.01)
                    .accessibilityLabel("Deadzone")
                    .accessibilityValue("\(Int((inner * 100).rounded())) percent")
                    .accessibilityHint(innerMeaning)
                Text(innerMeaning)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Outer deadzone slider
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Full push at")
                        .font(.subheadline)
                    Spacer()
                    Text(Self.percent(outer))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $outer, in: max(inner + 0.05, 0.1)...1.0, step: 0.01)
                    .accessibilityLabel("Full push at")
                    .accessibilityValue("\(Int((outer * 100).rounded())) percent")
                    .accessibilityHint(outerMeaning)
                Text(outerMeaning)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Stats
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) {
                    statBlocks
                    Spacer()
                    resetTrailButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 20) { statBlocks }
                    resetTrailButton
                }
            }
            .padding(.top, 4)

            if controllerService.connectedControllers.isEmpty
                && controllerService.rawHIDGamepadSlots.isEmpty
                && controllerService.racingWheelSlots.isEmpty
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
    }

    /// Text Size above Default widens the sheet with the text, up to the
    /// screen, and fixes its height so the scroll view has room to scroll.
    private var scale: CGFloat { max(1, textScale) }
    private var sheetWidth: CGFloat {
        let screenW = NSScreen.main?.visibleFrame.width ?? 1440
        return min(440 * scale, max(440, screenW - 80))
    }
    private var sheetHeight: CGFloat? {
        guard scale > 1 else { return nil }
        let screenH = NSScreen.main?.visibleFrame.height ?? 900
        return min(620 * scale, max(440, screenH - 80))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Title bar
            HStack {
                Image(systemName: "scope")
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Cancel") { onClose() }
                .buttonStyle(.solidSecondaryCompact)
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    // Only what changed, so an untouched value stays unset.
                    if inner != deadzone { deadzone = inner }
                    if outer != outerDeadzone { outerDeadzone = outer }
                    saved = true
                    onClose()
                }
                .buttonStyle(.solidCompact)
                    .keyboardShortcut(.defaultAction)
            }

            // Larger Text Size scrolls everything under the title bar, so
            // Cancel and Save stay in reach.
            if scale > 1 {
                ScrollView { content }
            } else {
                content
            }
        }
        .padding(20)
        .frame(width: sheetWidth, height: sheetHeight)
        .onAppear {
            if !hasSnapshot {
                inner = deadzone
                outer = outerDeadzone
                hasSnapshot = true
            }
            startSampling()
        }
        .onChange(of: inner) { _, _ in updatePreview() }
        .onChange(of: outer) { _, _ in updatePreview() }
        .onDisappear {
            stopSampling()
            guard let rowID, MappingEngine.deadzonePreview?.id == rowID else { return }
            if saved {
                let kept = MappingEngine.deadzonePreview
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if let now = MappingEngine.deadzonePreview, let kept,
                       now.id == kept.id, now.inner == kept.inner, now.outer == kept.outer {
                        MappingEngine.deadzonePreview = nil
                    }
                }
            } else {
                MappingEngine.deadzonePreview = nil
            }
        }
    }

    // MARK: - 2D Visualizer

    private var twoDVisualizer: some View {
        StickPlot(size: canvasSize, x: currentX, y: currentY, trail: trail,
                  deadzones: [inner], fullPush: outer, zones: shownZones, lit: zoneIsLit) { EmptyView() }
    }

    // MARK: - Trigger Visualizer

    /// Vertical trigger gauge with both inner deadzone (red band at the
    /// bottom - input below this point is ignored) and full push (green
    /// band at the top - input above this point counts as all the way).
    private var triggerVisualizer: some View {
        var labels: [(color: Color, text: String)] = [
            (.secondary, String(localized: "\(Self.percent(1)) Top", comment: "The top of the deadzone bar, 100%"))]
        if outer < 0.99 { labels.append((.green, String(localized: "Full push at \(Self.percent(outer))"))) }
        labels.append((.red, String(localized: "Deadzone \(Self.percent(inner))")))
        labels.append((.accentColor, String(localized: "Current \(Self.percent(Double(magnitude)))")))
        labels.append((.secondary, String(localized: "\(Self.percent(0)) Rest", comment: "The bottom of the deadzone bar, 0%, the stick at rest")))
        return TriggerGauge(pulled: Double(magnitude), deadzones: [inner], fullPush: outer,
                            bands: shownZones, lit: zoneIsLit, labels: labels) { EmptyView() }
    }

    // MARK: - Stat helper

    /// A share as a whole percent in the app's language ("25 %" in French).
    static func percent(_ v: Double) -> String {
        v.formatted(.percent.precision(.fractionLength(0)))
    }

    @ViewBuilder
    private var statBlocks: some View {
        statBlock("Current", Self.percent(Double(magnitude)))
        statBlock("Peak", Self.percent(Double(maxMagnitude)))
        statBlock("Inside deadzone", magnitude < Float(inner) ? String(localized: "Yes") : String(localized: "No"))
        if !shownZones.isEmpty {
            // Also said in words, since the lit zone is otherwise only a
            // brighter fill.
            statBlock("In region", shownZones.first(where: zoneIsLit)?.shownName ?? String(localized: "None"))
        }
    }

    private var resetTrailButton: some View {
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

    @ViewBuilder
    private func statBlock(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit())
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var magnitude: Float {
        if is2D {
            return sqrt(currentX * currentX + currentY * currentY)
        } else {
            return Float(Self.axisAmount(Double(currentX),
                                         oneWay: isTrigger || controllerService.axisReadsOneWay(slot: slot, index: axisIndex),
                                         direction: direction, fullTravel: fullTravel))
        }
    }

    /// How far a single axis is pushed the row's way, 0 to 1, as the engine
    /// reads it (Invert already applied): a trigger, or an axis the pad
    /// reads 0 to 1, as it is; Rests at one end across the whole travel;
    /// otherwise the row's side of center. A zone row has no way and reads
    /// the distance from center.
    static func axisAmount(_ v: Double, oneWay: Bool, direction: AxisDirection?, fullTravel: Bool) -> Double {
        func clamp(_ x: Double) -> Double { x.isFinite ? max(0, min(1, x)) : 0 }
        if oneWay { return clamp(v) }
        guard let direction else { return clamp(abs(v)) }
        if fullTravel { return direction == .positive ? clamp((v + 1) / 2) : clamp((1 - v) / 2) }
        return clamp(direction == .positive ? v : -v)
    }

    private func updatePreview() {
        guard let rowID, hasSnapshot else { return }
        MappingEngine.deadzonePreview = (rowID, Float(inner), Float(outer))
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

// MARK: - Shared drawings

/// The stick plot the Adjust live sheet and the Regions editor share: the
/// travel circle, the crosshair, the stick's regions, the red deadzone ring,
/// the green full-push ring, the trail and the live dot. One drawing, so the
/// two never look different. `extra` sits on top, in the plot's square.
struct StickPlot<Extra: View>: View {
    let size: CGFloat
    /// The live reading, in the app's axes (down is positive).
    let x: Float
    let y: Float
    var trail: [(x: Float, y: Float)] = []
    var showsDot = true
    /// Red rings: where rows start to count.
    var deadzones: [Double] = []
    /// Green ring: where a row counts as pushed all the way.
    var fullPush: Double = 1
    var zones: [TouchpadRegion] = []
    var lit: (TouchpadRegion) -> Bool = { _ in false }
    var selected: UUID? = nil
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1.5)
            Path { path in
                path.move(to: CGPoint(x: 0, y: size / 2))
                path.addLine(to: CGPoint(x: size, y: size / 2))
                path.move(to: CGPoint(x: size / 2, y: 0))
                path.addLine(to: CGPoint(x: size / 2, y: size))
            }
            .stroke(Color.secondary.opacity(0.15), lineWidth: 1)

            // The regions, under the deadzone rings.
            ForEach(zones) { zone in
                let box = zone.drawnBox
                let on = lit(zone), picked = zone.id == selected
                ZoneSwatch(ring: zone.ring, color: regionPaletteColor(at: zone.colorIndex),
                           fill: on ? 0.32 : (picked ? 0.2 : 0.06), stroke: on || picked ? 1 : 0.7,
                           lineWidth: on || picked ? 2.5 : 1)
                    .frame(width: max(1, box.width * size), height: max(1, box.height * size))
                    .position(x: box.midX * size, y: box.midY * size)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            ForEach(deadzones, id: \.self) { dz in
                Circle()
                    .fill(Color.red.opacity(0.08))
                    .frame(width: CGFloat(dz) * size, height: CGFloat(dz) * size)
                Circle()
                    .strokeBorder(Color.red.opacity(0.5), lineWidth: 1, antialiased: true)
                    .frame(width: CGFloat(dz) * size, height: CGFloat(dz) * size)
            }
            if fullPush < 0.99 {
                Circle()
                    .strokeBorder(Color.green.opacity(0.5), lineWidth: 1, antialiased: true)
                    .frame(width: CGFloat(fullPush) * size, height: CGFloat(fullPush) * size)
            }

            ForEach(Array(trail.enumerated()), id: \.offset) { index, point in
                let progress = Double(index) / Double(max(1, trail.count - 1))
                Circle()
                    .fill(Color.accentColor.opacity(0.05 + 0.35 * progress))
                    .frame(width: 4, height: 4)
                    .position(x: px(point.x), y: px(point.y))
            }
            if showsDot {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 12, height: 12)
                    .shadow(color: Color.accentColor.opacity(0.5), radius: 4)
                    .position(x: px(x), y: px(y))
            }
            extra()
        }
        .frame(width: size, height: size)
        // Drawn in the stick's own coordinates: right is right in every language.
        .environment(\.layoutDirection, .leftToRight)
    }

    private func px(_ v: Float) -> CGFloat { size / 2 + CGFloat(max(-1, min(1, v))) * size / 2 }
}

/// The trigger gauge the Adjust live sheet and the Regions editor share: a
/// bar filled to the live pull, the red deadzone band at the bottom, the
/// green full-push band at the top, the trigger's bands outlined, and the
/// readings in a column beside it. `extra` sits on top, in the bar's frame.
struct TriggerGauge<Extra: View>: View {
    var width: CGFloat = 90
    var height: CGFloat = 240
    /// The live pull, 0 to 1.
    let pulled: Double
    var deadzones: [Double] = []
    var fullPush: Double = 1
    var bands: [TouchpadRegion] = []
    var lit: (TouchpadRegion) -> Bool = { _ in false }
    var selected: UUID? = nil
    /// The column beside the bar, top to bottom.
    var labels: [(color: Color, text: String)] = []
    @ViewBuilder var extra: () -> Extra
    @Environment(\.appTextScale) private var textScale

    var body: some View {
        let pulled = CGFloat(max(0, min(1, pulled)))
        let firstDeadzone = CGFloat(deadzones.min() ?? 0)
        let full = CGFloat(max(firstDeadzone + 0.01, min(1, fullPush)))
        return HStack(spacing: 16) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: width, height: height)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
                // The live fill sits under the bands, so pulling the trigger
                // never covers the deadzones; they stay readable on top of it.
                Rectangle()
                    .fill(Color.accentColor.opacity(pulled <= firstDeadzone ? 0.30 : 0.55))
                    .frame(width: width, height: height * pulled)
                    .animation(.easeOut(duration: 0.08), value: pulled)
                ForEach(deadzones, id: \.self) { dz in
                    Rectangle()
                        .fill(Color.red.opacity(0.22))
                        .frame(width: width, height: height * CGFloat(max(0, min(1, dz))))
                }
                if full < 0.99 {
                    Rectangle()
                        .fill(Color.green.opacity(0.22))
                        .frame(width: width, height: height * (1 - full))
                        .offset(y: -(height * full))
                }
            }
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    ForEach(bands) { band in
                        let color = regionPaletteColor(at: band.colorIndex)
                        let on = lit(band), picked = band.id == selected
                        RoundedRectangle(cornerRadius: 3)
                            .fill(color.opacity(on ? 0.32 : (picked ? 0.2 : 0.04)))
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(color.opacity(on || picked ? 1 : 0.8),
                                                                              lineWidth: on || picked ? 2.5 : 1))
                            .frame(width: width - 10, height: max(2, (band.maxY - band.minY) * height))
                            .offset(x: 5, y: (1 - band.maxY) * height)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    extra()
                }
                .frame(width: width, height: height, alignment: .topLeading)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .frame(width: width, height: height)
            // The bar is a drawing; the labels beside it follow the language.
            .environment(\.layoutDirection, .leftToRight)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                    HStack(spacing: 4) {
                        Rectangle()
                            .fill(label.color.opacity(0.6))
                            .frame(width: 8, height: 2)
                        Text(label.text)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(label.color.opacity(0.85))
                            // Wraps rather than cutting off the percent
                            // ("Volledig ingedrukt bij 85 %").
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: 110 * max(1, textScale), height: height, alignment: .topLeading)
        }
        .frame(height: height)
    }
}

// MARK: - The row's small live preview

/// A small live picture of a stick or trigger row in its Options: the
/// stick's travel with the deadzone and full-push rings, the part of the
/// stick that fires this row shaded, the stick's zones, and a live dot. It
/// follows the sliders as they move. Clicking it opens the full Adjust live
/// sheet.
struct MiniDeadzonePreview: View {
    /// The row's axis (0...3 sticks, 4...5 triggers, more on other pads).
    let axisIndex: Int
    /// The way the row fires: + or -, or nil for a zone row.
    let direction: AxisDirection?
    let inner: Double
    let outer: Double
    let isInverted: Bool
    let slot: Int
    /// For a zone row, the zone it binds, drawn brighter.
    var zoneID: UUID? = nil
    /// Rests at one end: a single axis reads across its whole travel.
    var fullTravel = false
    let onOpen: () -> Void

    @EnvironmentObject private var controllerService: GameControllerService
    @ObservedObject private var zones = StickRegionService.shared
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReduceMotion) private var appReduceMotion
    /// The system setting or the app's own Reduce motion.
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    private var isTrigger: Bool { axisIndex == 4 || axisIndex == 5 }
    private var is2D: Bool { (0...3).contains(axisIndex) }
    private var stick: Int { axisIndex >= 2 ? 1 : 0 }
    private let size: CGFloat = 96

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 4) {
                TimelineView(.periodic(from: .now, by: reduceMotion ? 0.25 : 1.0 / 30)) { _ in
                    picture
                }
                .frame(width: is2D ? size : 44, height: size)
                // A quiet caption, not a button: the picture is what opens
                // the full view.
                Label("Adjust live", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
            .padding(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .environment(\.layoutDirection, .leftToRight)
        .help(helpText)
        .accessibilityLabel("Adjust live")
        .accessibilityInputLabels([Text("Adjust live"), Text("Adjust deadzone live")])
        .accessibilityValue(String(localized: "Deadzone \(Int((inner * 100).rounded())) percent"))
        .accessibilityHint(hintText)
    }

    /// Stick, trigger, or any other single axis (a wheel, throttle or pedal
    /// shown as a bar), each in its own words.
    private var helpText: LocalizedStringKey {
        if is2D { return "Watch the stick here; click to open the full view and set the deadzone while you move it." }
        if isTrigger { return "Watch the trigger here; click to open the full view and set the deadzone while you pull it." }
        return "Watch the control here; click to open the full view and set the deadzone while you move it."
    }

    private var hintText: LocalizedStringKey {
        if is2D { return "Opens the full view of this stick with its deadzone" }
        if isTrigger { return "Opens the full view of this trigger with its deadzone" }
        return "Opens the full view of this control with its deadzone"
    }

    /// The live reading for this row's slot, as the engine sees it.
    private var reading: (x: Double, y: Double) {
        let st = controllerService.peekControllerState(at: slot)
        if is2D {
            var x = Double(st?.axes[stick == 1 ? 2 : 0] ?? 0), y = Double(st?.axes[stick == 1 ? 3 : 1] ?? 0)
            if isInverted { x = -x; y = -y }
            return (x, y)
        }
        var v = Double(st?.axes[axisIndex] ?? 0)
        if isInverted { v = -v }
        return (v, 0)
    }

    @ViewBuilder
    private var picture: some View {
        if is2D { stickPicture } else { barPicture }
    }

    private var stickPicture: some View {
        let r = reading
        let s = size
        return ZStack {
            Circle().fill(Color.black.opacity(0.25))
            Circle().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
            ForEach(zones.regions(forStick: stick)) { zone in
                let box = zone.drawnBox
                let mine = zone.id == zoneID
                ZoneSwatch(ring: zone.ring, color: regionPaletteColor(at: zone.colorIndex),
                           fill: mine ? 0.45 : 0.12, stroke: mine ? 1 : 0.5, lineWidth: mine ? 1.5 : 0.75)
                    .frame(width: max(1, box.width * s), height: max(1, box.height * s))
                    .position(x: box.midX * s, y: box.midY * s)
            }
            // The way this row fires, from the deadzone ring outward: its
            // side of the axis, or toward its own region. Over the regions,
            // so their color never hides it. A shaded half-plane said the
            // same, but its flat edge read as a drawing glitch.
            if let way = firingWay {
                firingArrow(dx: way.dx, dy: way.dy)
                    .stroke(Color.accentColor.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            Circle()
                .strokeBorder(Color.red.opacity(0.6), lineWidth: 1)
                .background(Circle().fill(Color.red.opacity(0.08)))
                .frame(width: inner * s, height: inner * s)
            if outer < 0.99 {
                Circle()
                    .strokeBorder(Color.green.opacity(0.6), lineWidth: 1)
                    .frame(width: outer * s, height: outer * s)
            }
            Circle()
                .fill(Color.accentColor)
                .frame(width: 8, height: 8)
                .position(x: (min(1, max(-1, r.x)) + 1) / 2 * s, y: (min(1, max(-1, r.y)) + 1) / 2 * s)
        }
        .frame(width: s, height: s)
    }

    /// Which way the arrow points, as a unit step in the drawing (y down,
    /// as the app reads): the row's side of its axis, or for a region row
    /// the middle of its region. None for a whole ring, which is every way.
    private var firingWay: (dx: CGFloat, dy: CGFloat)? {
        if let zoneID {
            guard let zone = zones.region(with: zoneID)?.region else { return nil }
            if let ring = zone.ring {
                guard ring.span < 360 else { return nil }
                let a = (ring.start + ring.span / 2) * .pi / 180
                return (CGFloat(cos(a)), CGFloat(-sin(a)))
            }
            let box = zone.drawnBox
            let vx = box.midX - 0.5, vy = box.midY - 0.5
            let length = (vx * vx + vy * vy).squareRoot()
            guard length > 0.05 else { return nil }
            return (vx / length, vy / length)
        }
        guard let direction else { return nil }
        let sign: CGFloat = direction == .positive ? 1 : -1
        return axisIndex == 0 || axisIndex == 2 ? (sign, 0) : (0, sign)
    }

    /// An arrow from just outside the deadzone ring to near the rim, along
    /// a unit step, in the square the stick is drawn in.
    private func firingArrow(dx: CGFloat, dy: CGFloat) -> Path {
        let s = size, c = s / 2
        let start = min(inner * s / 2 + 4, c - 14), end = c - 6
        let tip = CGPoint(x: c + dx * end, y: c + dy * end)
        var path = Path()
        path.move(to: CGPoint(x: c + dx * start, y: c + dy * start))
        path.addLine(to: tip)
        // The head: two short strokes back from the tip.
        let head: CGFloat = 5
        // Back along the arrow and out to each side, at any angle.
        let (px, py) = (-dy, dx)
        path.move(to: CGPoint(x: tip.x - dx * head + px * head, y: tip.y - dy * head + py * head))
        path.addLine(to: tip)
        path.addLine(to: CGPoint(x: tip.x - dx * head - px * head, y: tip.y - dy * head - py * head))
        return path
    }

    private var barPicture: some View {
        let r = reading
        let h = size, w: CGFloat = 26
        let pulled = DeadzoneCalibrationView.axisAmount(
            r.x, oneWay: isTrigger || controllerService.axisReadsOneWay(slot: slot, index: axisIndex),
            direction: direction, fullTravel: fullTravel)
        let bands = zones.regions(forStick: StickRegionService.bandKeyBase + axisIndex)
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.25))
            Rectangle().fill(Color.accentColor.opacity(pulled <= inner ? 0.3 : 0.6))
                .frame(height: h * pulled)
            Rectangle().fill(Color.red.opacity(0.22)).frame(height: h * inner)
            if outer < 0.99 {
                Rectangle().fill(Color.green.opacity(0.22)).frame(height: h * (1 - outer)).offset(y: -h * outer)
            }
            if isTrigger {
                ForEach(bands) { band in
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(regionPaletteColor(at: band.colorIndex).opacity(band.id == zoneID ? 1 : 0.7),
                                lineWidth: band.id == zoneID ? 1.5 : 1)
                        .frame(width: w - 6, height: max(2, (band.maxY - band.minY) * h))
                        .offset(y: -(band.minY * h))
                }
            }
            RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
        }
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
