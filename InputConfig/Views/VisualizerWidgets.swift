import SwiftUI
import Combine

// MARK: - Widget components

struct StickWidget: View {
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.appHighContrast) private var appHighContrast
    let label: String
    let x: Float
    let y: Float
    let pressed: Bool
    /// The preset's zones on this stick, drawn on the dot's travel.
    var zones: [TouchpadRegion] = []

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(pressed ? Color.green.opacity(0.25) : Color.secondary.opacity(0.18))
                // The zones on the dot's travel (26 points each way), the
                // one the stick is in filled.
                if !zones.isEmpty {
                    let px = Double((x + 1) / 2), py = Double((y + 1) / 2)
                    ZStack(alignment: .topLeading) {
                        ForEach(zones) { z in
                            let box = z.drawnBox
                            let on = z.contains(normalizedX: px, y: py)
                            ZoneSwatch(ring: z.ring, color: ControllerCanvas.zoneColor(z.colorIndex), fill: on ? 0.6 : 0.18,
                                       stroke: on ? 1 : 0.55, lineWidth: on ? 1.5 : 0.75)
                                .frame(width: max(1, box.width * 52), height: max(1, box.height * 52))
                                .position(x: 10 + box.midX * 52, y: 10 + box.midY * 52)
                        }
                    }
                    .frame(width: 72, height: 72)
                    .clipShape(Circle())
                    .allowsHitTesting(false)
                }
                Circle()
                    .stroke(pressed ? Color.green : Color.secondary.opacity(0.4),
                            lineWidth: pressed && (differentiateWithoutColor || colorSchemeContrast == .increased || appHighContrast) ? 3.5 : 1.5)
                // Crosshair
                Path { p in
                    p.move(to: CGPoint(x: 36, y: 0)); p.addLine(to: CGPoint(x: 36, y: 72))
                    p.move(to: CGPoint(x: 0, y: 36)); p.addLine(to: CGPoint(x: 72, y: 36))
                }
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                // Thumb dot
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 14, height: 14)
                    .offset(x: CGFloat(x) * 26, y: CGFloat(y) * 26)
                    .animation(.linear(duration: 0.03), value: x)
                    .animation(.linear(duration: 0.03), value: y)
            }
            .frame(width: 72, height: 72)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue)
    }

    /// Spoken description of the live analog position and press state, so
    /// VoiceOver users hear where the stick is instead of a silent circle.
    private var accessibilityValue: String {
        pressed ? String(localized: "\(SpokenLive.stick(x: x, y: y)), pressed") : SpokenLive.stick(x: x, y: y)
    }
}

struct TriggerWidget: View {
    let label: String
    let value: Float
    let threshold: Float
    let tint: Color
    /// The preset's bands on this trigger, drawn along its travel.
    var bands: [TouchpadRegion] = []

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 22, height: 80)
                RoundedRectangle(cornerRadius: 4)
                    .fill(tint.gradient)
                    .frame(width: 22, height: max(2, CGFloat(value) * 80))
                    .animation(.linear(duration: 0.04), value: value)
                // The bands, the one the trigger is in filled.
                ForEach(bands) { z in
                    let on = z.containsTravel(Double(min(1, max(0, value))))
                    let color = ControllerCanvas.zoneColor(z.colorIndex)
                    let low = CGFloat(min(1, max(0, z.minY))), high = CGFloat(min(1, max(0, z.maxY)))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color.opacity(on ? 0.55 : 0.18))
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(color.opacity(on ? 1 : 0.6), lineWidth: on ? 1.5 : 0.75))
                        .frame(width: 22, height: max(2, (high - low) * 80))
                        .offset(y: -low * 80)
                        .allowsHitTesting(false)
                }
                // Threshold marker
                Rectangle()
                    .fill(Color.orange.opacity(0.7))
                    .frame(width: 30, height: 1)
                    .offset(y: -CGFloat(threshold) * 80)
            }
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(String(format: "%.0f%%", locale: .current, min(1, max(0, value)) * 100))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.hint)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) trigger")
        .accessibilityValue(SpokenLive.trigger(value))
    }
}

struct ShoulderWidget: View {
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.appHighContrast) private var appHighContrast
    let label: String
    let pressed: Bool

    var body: some View {
        ZStack {
            Capsule()
                .fill(pressed ? Color.green.opacity(0.25) : Color.secondary.opacity(0.15))
            Capsule()
                .stroke(pressed ? Color.green : Color.secondary.opacity(0.35),
                        lineWidth: pressed && (differentiateWithoutColor || colorSchemeContrast == .increased || appHighContrast) ? 3 : 1)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(pressed ? .green : .secondary)
        }
        .frame(width: 56, height: 18)
        // Drawn at its own size, like the controller drawing's labels: the
        // app's Text Size spilled the word out of the capsule.
        .environment(\.appTextScale, 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) shoulder")
        .accessibilityValue(pressed ? String(localized: "pressed") : String(localized: "released"))
    }
}

struct DPadWidget: View {
    let hat: (x: Float, y: Float)
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.appHighContrast) private var appHighContrast
    private var moreContrast: Bool { colorSchemeContrast == .increased || appHighContrast }
    /// A press shown by more than hue (see ControllerCanvas).
    private var outline: Bool { differentiateWithoutColor || moreContrast }

    var body: some View {
        let up = hat.y > 0.5
        let down = hat.y < -0.5
        let left = hat.x < -0.5
        let right = hat.x > 0.5
        VStack(spacing: 2) {
            arrow(up: true, active: up)
            HStack(spacing: 2) {
                arrow(left: true, active: left)
                Color.clear.frame(width: 20, height: 20)
                arrow(right: true, active: right)
            }
            arrow(down: true, active: down)
        }
        // Fixed 20 pt cells: at a larger Text Size the arrows overlapped.
        .environment(\.appTextScale, 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("D-pad")
        .accessibilityValue(directionValue(up: up, down: down, left: left, right: right))
    }

    /// Spoken direction the D-pad is currently pressed toward, combining
    /// the two axes so diagonals read naturally (for example "up right").
    private func directionValue(up: Bool, down: Bool, left: Bool, right: Bool) -> String {
        var parts: [String] = []
        if up { parts.append(String(localized: "up")) }
        if down { parts.append(String(localized: "down")) }
        if left { parts.append(String(localized: "left")) }
        if right { parts.append(String(localized: "right")) }
        return parts.isEmpty ? String(localized: "centered") : parts.joined(separator: " ")
    }

    private func arrow(up: Bool = false, down: Bool = false, left: Bool = false, right: Bool = false, active: Bool) -> some View {
        let icon: String =
            up ? "arrowtriangle.up.fill" :
            down ? "arrowtriangle.down.fill" :
            left ? "arrowtriangle.left.fill" :
            "arrowtriangle.right.fill"
        return Image(systemName: icon)
            .font(.body)
            .foregroundStyle(active ? Color.green : Color.secondary.opacity(0.55))
            .frame(width: 20, height: 20)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(active ? Color.green.opacity(0.18) : Color.secondary.opacity(0.10))
            )
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.green, lineWidth: active && outline ? 2.5 : 0))
    }
}

struct FaceButtonGlyph: View {
    let label: String
    let pressed: Bool
    let tint: Color
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.appHighContrast) private var appHighContrast
    private var moreContrast: Bool { colorSchemeContrast == .increased || appHighContrast }
    /// A press shown by more than hue (see ControllerCanvas).
    private var outline: Bool { differentiateWithoutColor || moreContrast }

    /// PlayStation glyphs are drawn as symbols at one fixed size. As text,
    /// the four characters come out at four different sizes.
    private var symbol: String? {
        switch label {
        case "✕": return "xmark"
        case "○": return "circle"
        case "□": return "square"
        case "△": return "triangle"
        default: return nil
        }
    }
    private var spokenName: String {
        switch label {
        case "✕": return String(localized: "Cross")
        case "○": return String(localized: "Circle")
        case "□": return String(localized: "Square")
        case "△": return String(localized: "Triangle")
        // Face button names by position, spoken in full.
        case "S": return String(localized: "South")
        case "E": return String(localized: "East")
        case "W": return String(localized: "West")
        case "N": return String(localized: "North")
        default: return label
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(pressed ? tint.opacity(0.4) : Color.secondary.opacity(0.18))
            Circle()
                .stroke(pressed ? tint : Color.secondary.opacity(0.35), lineWidth: pressed && outline ? 3.5 : 1.5)
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(moreContrast ? Color.primary : (pressed ? tint : tint.opacity(0.85)))
            } else {
                Text(label)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(moreContrast ? Color.primary : (pressed ? tint : tint.opacity(0.85)))
            }
        }
        .frame(width: 32, height: 32)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenName)
        .accessibilityValue(pressed ? String(localized: "pressed") : String(localized: "released"))
    }
}

struct TouchpadWidget: View {
    @Environment(\.visualizerSuspended) private var suspended
    /// Touchpad button (index 13) state. When the user physically pushes
    /// the touchpad down (not just touches it), this flips to true and the
    /// widget glows green to signal a click vs a swipe.
    let pressed: Bool

    /// The zones of the preset being shown. Regions belong to presets, so
    /// the visualizer draws the ones this preset defines rather than
    /// whatever the service happens to be holding; the service's list is
    /// used only when the preset has none of its own (while a draft is
    /// being edited, for instance).
    var presetRegions: [TouchpadRegion] = []

    /// Single sample of a finger's position with the timestamp it was
    /// captured. The view ages each point and uses age to compute opacity
    /// + size, producing the "whoosh" trail behind the moving finger.
    private struct TrailPoint: Identifiable {
        let id = UUID()
        let x: CGFloat
        let y: CGFloat
        let time: Date
    }

    @State private var trailF0: [TrailPoint] = []
    @State private var trailF1: [TrailPoint] = []

    /// How long a trail point lingers before fading away. Short enough to
    /// feel responsive, long enough that a fast swipe leaves a visible arc.
    private let trailDuration: TimeInterval = 0.35
    /// Hard cap on how many trail samples we retain per finger. Even at a
    /// short trailDuration the sample timer can overrun this on rapid
    /// motion; the cap keeps per-frame render cost bounded. 24 still
    /// produces a visually continuous arc on a fast swipe.
    private let maxTrailPoints = 24
    /// Width divided by height of the real surface. A DualSense pad is a
    /// wide letterbox, a Mac trackpad is close to 3:2, and drawing one in
    /// the other's shape puts every zone in the wrong place: a zone that
    /// covers the bottom third of a Mac trackpad was being drawn as a thin
    /// strip. Defaults to the DualSense pad.
    var surfaceAspect: CGFloat = 220.0 / 70.0

    /// Width / height of the rendered touchpad rect, in the surface's shape.
    private var pad: CGSize {
        let width: CGFloat = 220
        return CGSize(width: width, height: max(60, min(150, width / max(0.6, surfaceAspect))))
    }
    /// Sampled-coordinate range (matches the helper subprocess output).
    private let coordScale = CGSize(width: 1920, height: 1080)

    /// Snapshot of the user-defined detection regions (from the
    /// Touchpad Calibration sheet) so the visualizer can overlay
    /// them. We refresh this on every render tick along with the
    /// trail samples - cheap because the region list is short and
    /// allRegions() just snapshots an Array under the service lock.
    @State private var regions: [TouchpadRegion] = []
    /// IDs of regions currently being touched, so we can light them
    /// up the same way TouchpadCalibrationView does.
    @State private var pressedRegionIDs: Set<UUID> = []
    /// The last tap gesture the pad reported and when, so the widget can
    /// flash "Tap" or "Two-finger tap" for a moment.
    @State private var lastTap: TouchpadGestureKind?
    @State private var lastTapAt: Date = .distantPast

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(pressed
                      ? Color.green.opacity(0.35)
                      : Color.black.opacity(0.25))
                .animation(.easeOut(duration: 0.12), value: pressed)
            RoundedRectangle(cornerRadius: 8)
                .stroke(pressed ? Color.green : Color.mint.opacity(0.5),
                        lineWidth: pressed ? 2 : 1)
                .shadow(color: pressed ? Color.green.opacity(0.7) : .clear,
                        radius: pressed ? 10 : 0)
                .animation(.easeOut(duration: 0.12), value: pressed)

            // Faint grid so the surface reads as a real touchpad.
            Path { p in
                p.move(to: CGPoint(x: pad.width / 2, y: 6))
                p.addLine(to: CGPoint(x: pad.width / 2, y: pad.height - 6))
                p.move(to: CGPoint(x: 12, y: pad.height / 2))
                p.addLine(to: CGPoint(x: pad.width - 12, y: pad.height / 2))
            }
            .stroke(Color.mint.opacity(0.15), lineWidth: 0.5)

            // Detection regions overlay. The visualizer is the same
            // surface the user defined regions on in
            // TouchpadCalibrationView, so we mirror that view's region
            // rendering 1:1 (palette color, fill/stroke, "lit up when
            // pressed" highlight). Always rendered behind the finger
            // trails so a region's color shows through.
            ForEach(regions) { region in
                regionRect(region)
            }

            // Trails: rendered through a single Canvas (one draw call
            // for all points per finger) instead of dozens of SwiftUI
            // Circle views with expensive .blur modifiers. This was the
            // root cause of the visible choppiness - the previous
            // approach created up to 132 blurred-circle subviews per
            // frame and the offscreen blur passes were saturating the
            // GPU. Canvas draws everything in one pass with native
            // CoreGraphics fills.
            trailCanvas

            // Dot for the most recent position. Kept as a regular view
            // (only 2 of them) so we get the natural shadow + crispness
            // of SwiftUI shape rendering for the focal point.
            dotRender(point: trailF0.last, hue: .mint, base: 12)
            dotRender(point: trailF1.last, hue: .cyan, base: 10)

            Text("Touchpad")
                .font(.caption2)
                .foregroundStyle(.hint)
                .position(x: 32, y: 8)

            // A tap has no lasting state to draw, so it is shown as a
            // short flash of its name at the top edge.
            if let tap = lastTap, Date().timeIntervalSince(lastTapAt) < 0.7 {
                Text(tap == .oneFingerTap ? String(localized: "Tap") : tap == .doubleTap ? String(localized: "Double tap") : String(localized: "Two-finger tap"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.mint)
                    .position(x: pad.width - 44, y: 8)
                    .transition(.opacity)
            }
        }
        .frame(width: pad.width, height: pad.height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Touchpad")
        .accessibilityValue(pressed ? String(localized: "pressed") : String(localized: "released"))
        // 60 Hz sampling. Higher rates produced visibly worse
        // performance because each tick invalidated @State and forced
        // SwiftUI to rebuild the whole widget body. 30 Hz, the same as the
        // panel around it: at 60 the trail write re-rendered this widget
        // twice for every frame the parent drew, and that extra layout
        // work on the main thread was paid for by the engine's poll timer,
        // which reached the pointer as touchpad lag. The data source is
        // event-driven so the sampled position is always fresh.
        .onReceive(Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()) { now in
            // Paused while another app is in front, like the panel's clock,
            // and under the editor.
            guard NSApp.isActive, !suspended else { return }
            sampleAndPrune(now: now)
            refreshRegionState()
            for kind in [TouchpadGestureKind.oneFingerTap, .doubleTap, .twoFingerTap]
            where TouchpadService.shared.peekGesture(kind) {
                if lastTap != kind || now.timeIntervalSince(lastTapAt) > 0.3 {
                    lastTap = kind; lastTapAt = now
                }
            }
            // The flash is over: let go of the tap, or the next tick's
            // body kept reading a name it no longer draws.
            if lastTap != nil, now.timeIntervalSince(lastTapAt) >= 0.7 { lastTap = nil }
        }
        // Hold the touchpad while the widget is on screen. MappingEngine
        // holds it separately when a preset uses it; the count keeps the
        // touch state until the last one lets go.
        .onAppear {
            TouchpadService.shared.retain()
            // This preset's zones only: the service holds whichever preset
            // ran or was edited last, and its zones were drawn on this pad.
            regions = presetRegions
        }
        .onChange(of: presetRegions) { _, new in
            regions = new
        }
        .onDisappear { TouchpadService.shared.release() }
    }

    /// Per-region rect overlay. Same coordinate space as the trail
    /// rendering: normalized [0...1] inside the pad rectangle.
    @ViewBuilder
    private func regionRect(_ region: TouchpadRegion) -> some View {
        let isPressed = pressedRegionIDs.contains(region.id)
        let color = paletteColor(at: region.colorIndex)
        let rect = CGRect(
            x: CGFloat(region.minX) * pad.width,
            y: CGFloat(region.minY) * pad.height,
            width: CGFloat(region.maxX - region.minX) * pad.width,
            height: CGFloat(region.maxY - region.minY) * pad.height)
        RoundedRectangle(cornerRadius: 3)
            .fill(color.opacity(isPressed ? 0.6 : 0.18))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(color.opacity(isPressed ? 1 : 0.55),
                            lineWidth: isPressed ? 1.5 : 0.75)
            )
            .frame(width: max(2, rect.width), height: max(2, rect.height))
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
    }

    /// Which of the drawn regions a finger is inside. The service's own
    /// pressed set is about whichever preset's zones it holds, which may
    /// not be the ones drawn here, so the drawn ones are tested against
    /// its finger positions, as RegionMapView does with the pointer.
    private func refreshRegionState() {
        let tp = TouchpadService.shared
        let size = tp.nominalSurfaceSize
        let fingers: [(x: Double, y: Double)] = (0..<2).compactMap { f in
            tp.currentPosition(finger: f).map {
                (Double($0.x) / Double(max(1, size.width)), Double($0.y) / Double(max(1, size.height)))
            }
        }
        // The shared service is the pad's own surface (0): a second
        // surface's zones are drawn here but never lit by its fingers.
        // Its tap latch too, for a tap between two frames: an id it does not
        // hold reads as up, so another preset's zones change nothing.
        let pressed: Set<UUID> = Set(regions.filter { r in
            r.surface != 1 && (fingers.contains { r.contains(normalizedX: $0.x, y: $0.y) } || tp.isRegionPressed(r.id))
        }.map(\.id))
        if pressed != pressedRegionIDs {
            pressedRegionIDs = pressed
        }
    }

    /// Mirror of TouchpadCalibrationView.paletteColor so the visualizer
    /// renders each region in the same color the user picked in the
    /// calibration sheet. Duplicated rather than shared because both
    /// views use a static palette; the entries never change.
    private func paletteColor(at index: Int) -> Color {
        let palette = TouchpadRegion.colorPalette
        let safeIndex = max(0, min(palette.count - 1, index))
        switch palette[safeIndex] {
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

    /// Single-pass Canvas that renders both fingers' trails as plain
    /// fills. Replaces the previous ForEach-of-blurred-Circles approach
    /// which was the main source of touchpad lag (blur is implemented
    /// as an offscreen pass per view; ~130 of those per frame swamped
    /// the GPU).
    private var trailCanvas: some View {
        // Pause the 60 Hz clock when there is nothing to animate. With both
        // trail buffers empty the Canvas was repainting an empty pad 60x/sec
        // for the whole time a touchpad controller is connected. A finger-down
        // appends to trailF0/trailF1 (@State), which re-runs body and resumes
        // this same-identity timeline on the same render pass (no added latency).
        TimelineView(.animation(minimumInterval: 1.0 / 60.0,
                                paused: suspended || (trailF0.isEmpty && trailF1.isEmpty))) { context in
            Canvas { ctx, _ in
                drawTrail(into: ctx, points: trailF0,
                          color: .mint, at: context.date)
                drawTrail(into: ctx, points: trailF1,
                          color: .cyan, at: context.date)
            }
        }
        .frame(width: pad.width, height: pad.height)
        .allowsHitTesting(false)
    }

    /// Helper that draws one finger's trail into the Canvas context.
    /// Older points are smaller and more transparent than newer ones,
    /// matching the original look but without the expensive per-point
    /// blur. Kept as a static-ish function so the closure stays simple
    /// and the SwiftUI type-checker doesn't time out on a complex body.
    private func drawTrail(into ctx: GraphicsContext, points: [TrailPoint],
                           color: Color, at now: Date) {
        for p in points {
            let age = now.timeIntervalSince(p.time)
            let factor = max(0, 1 - age / trailDuration)
            guard factor > 0.02 else { continue }
            let radius = (4 + 8 * factor) / 2
            let x = p.x / coordScale.width * pad.width
            let y = p.y / coordScale.height * pad.height
            let rect = CGRect(x: x - radius, y: y - radius,
                              width: radius * 2, height: radius * 2)
            ctx.fill(Path(ellipseIn: rect),
                     with: .color(color.opacity(0.45 * factor)))
        }
    }

    /// Solid "current finger" dot rendered on top of the trail so the
    /// active position pops out from the fading wash behind it.
    @ViewBuilder
    private func dotRender(point: TrailPoint?, hue: Color, base: CGFloat) -> some View {
        if let p = point {
            Circle()
                .fill(hue)
                .frame(width: base, height: base)
                .shadow(color: hue.opacity(0.7), radius: 4)
                .position(x: p.x / coordScale.width * pad.width,
                          y: p.y / coordScale.height * pad.height)
        }
    }

    /// Append the current finger positions to the trail buffers (if a
    /// finger is down) and drop any samples older than `trailDuration`.
    /// Also enforces `maxTrailPoints` so a stuck timer can't grow the
    /// buffer unboundedly between prune sweeps.
    private func sampleAndPrune(now: Date) {
        // Idle gate: with no finger on the pad and no fading trail left to
        // prune, every line below is a no-op - but the array mutations still
        // dirtied @State 60x/second and re-rendered the widget continuously
        // while a touchpad controller was merely connected. Bail out first.
        if TouchpadService.shared.currentPosition(finger: 0) == nil,
           TouchpadService.shared.currentPosition(finger: 1) == nil,
           trailF0.isEmpty, trailF1.isEmpty {
            return
        }
        if let p = TouchpadService.shared.currentPosition(finger: 0) {
            trailF0.append(TrailPoint(x: CGFloat(p.x), y: CGFloat(p.y), time: now))
        }
        if let p = TouchpadService.shared.currentPosition(finger: 1) {
            trailF1.append(TrailPoint(x: CGFloat(p.x), y: CGFloat(p.y), time: now))
        }
        let cutoff = now.addingTimeInterval(-trailDuration)
        trailF0.removeAll { $0.time < cutoff }
        trailF1.removeAll { $0.time < cutoff }
        if trailF0.count > maxTrailPoints {
            trailF0.removeFirst(trailF0.count - maxTrailPoints)
        }
        if trailF1.count > maxTrailPoints {
            trailF1.removeFirst(trailF1.count - maxTrailPoints)
        }
    }
}

/// A way a drawn control moves, for the deadzone marked each way.
enum DeadzoneWay: Int, CaseIterable { case right, left, down, up }

/// One motion channel's rows on the Live Visualizer: the Motion panel's
/// bar from a row's Options (centered, the gray band the deadzone, the fill
/// green when a row would fire), with every row on the channel: a band out
/// to each side's first row, the side no row listens to dimmed.
struct MotionDeadzoneMeter: View {
    let channel: MotionChannel
    let value: Float
    let rows: [BindingModel]
    /// The level the running preset's from-the-grip rows measure from, nil
    /// when none has been taken.
    var neutral: Float? = nil

    /// A row's reading as the engine has it: from the grip for a tilt row
    /// set that way, so the meter no longer lit at a normal grip angle.
    private func reading(_ row: BindingModel) -> Float {
        guard row.fromNeutral == true, let neutral,
              [.pitchAngle, .rollAngle, .yawAngle].contains(channel) else { return value }
        let v = value - neutral
        return channel == .yawAngle ? MappingEngine.wrapHalfTurn(v) : v
    }

    /// What the number and the fill show: from the grip when every row is.
    private var shownValue: Float {
        guard let first = rows.first, rows.allSatisfy({ $0.fromNeutral == true }) else { return value }
        return reading(first)
    }

    /// The Motion panel's full scale: gyro rates in rad/s, the rest about -1...1.
    private var scale: Float {
        switch channel {
        case .gyroX, .gyroY, .gyroZ: return 3
        default: return 1
        }
    }

    /// The engine's deadzone for a motion row with none of its own.
    private func deadzone(_ row: BindingModel) -> Float {
        row.deadzone ?? (MappingEngine.drivesPointer(row) ? 0.05 : Float(MappingEngine.motionSwitchDeadzone))
    }

    /// The first row's deadzone on each side (after invert), nil when no row listens there.
    private var sides: (positive: Float?, negative: Float?) {
        var pos: Float?, neg: Float?
        for row in rows {
            let dz = deadzone(row)
            let flip = row.invertAxis == true
            switch row.input.axisDirection {
            case .positive?: if flip { neg = min(neg ?? dz, dz) } else { pos = min(pos ?? dz, dz) }
            case .negative?: if flip { pos = min(pos ?? dz, dz) } else { neg = min(neg ?? dz, dz) }
            case nil: pos = min(pos ?? dz, dz); neg = min(neg ?? dz, dz)
            }
        }
        return (pos, neg)
    }

    private var firing: Bool {
        // A pointer row moves on any turn past a hair, as the engine has it.
        rows.contains { row in
            MappingEngine.drivesPointer(row) ? abs(reading(row)) >= 0.005
                : MappingEngine.motionFires(value: reading(row), direction: row.input.axisDirection,
                                            invert: row.invertAxis == true, deadzone: deadzone(row))
        }
    }

    /// The same in words: VoiceOver drops the lone + and \u{2212} that tell
    /// the two sides apart, and reads "rad/s" letter by letter.
    private var spokenHelp: String {
        func num(_ v: Float) -> String { Double(v).formatted(.number.precision(.significantDigits(1...2))) }
        let s = sides
        let unit = scale == 3 ? String(localized: " radians per second") : ""
        switch (s.positive, s.negative) {
        case let (p?, n?) where p == n: return String(localized: "\(channel.displayName): deadzone \(num(p))\(unit)")
        case let (p?, n?): return String(localized: "\(channel.displayName): deadzone \(num(p))\(unit) on the plus side, \(num(n))\(unit) on the minus side")
        case let (p?, nil): return String(localized: "\(channel.displayName): deadzone \(num(p))\(unit), plus side only")
        case let (nil, n?): return String(localized: "\(channel.displayName): deadzone \(num(n))\(unit), minus side only")
        default: return channel.displayName
        }
    }

    private var help: String {
        func pct(_ v: Float) -> String { Double(v).formatted(.number.precision(.significantDigits(1...2))) }
        let s = sides
        let unit = scale == 3 ? " rad/s" : ""
        switch (s.positive, s.negative) {
        case let (p?, n?) where p == n: return String(localized: "\(channel.displayName): deadzone \(pct(p))\(unit)")
        case let (p?, n?): return String(localized: "\(channel.displayName): deadzone \(pct(p))\(unit) +, \(pct(n))\(unit) \u{2212}")
        case let (p?, nil): return String(localized: "\(channel.displayName): deadzone \(pct(p))\(unit), + only")
        case let (nil, n?): return String(localized: "\(channel.displayName): deadzone \(pct(n))\(unit), \u{2212} only")
        default: return channel.displayName
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(channel.displayName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                // One line, shrunk to fit: "Beschleunigung X" must not
                // break inside the word.
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 70, alignment: .trailing)
            meter.frame(width: 150, height: 8)
            Text(String(format: "%+.2f", locale: .current, shownValue))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(firing ? Color.green : Color.secondary)
                .frame(minWidth: 40, alignment: .leading)
                .fixedSize()
        }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenHelp)
        .accessibilityValue(firing ? String(localized: "past the deadzone") : String(localized: "inside the deadzone"))
    }

    private var meter: some View {
        GeometryReader { geo in
            let half = geo.size.width / 2
            let s = sides
            let pos = s.positive.map { min(half, CGFloat($0 / scale) * half) } ?? 0
            let neg = s.negative.map { min(half, CGFloat($0 / scale) * half) } ?? 0
            let clamped = max(-1, min(1, shownValue / scale))
            let fill = abs(CGFloat(clamped)) * half
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.12))
                // The half no row listens to is dimmed further.
                if s.positive == nil || s.negative == nil {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.08))
                        .frame(width: half)
                        .offset(x: s.positive == nil ? half : 0)
                }
                // Deadzone band, out to each side's first row.
                Rectangle()
                    .fill(Color.secondary.opacity(0.28))
                    .frame(width: (s.negative == nil ? pos : neg) + (s.positive == nil ? neg : pos))
                    .offset(x: half - (s.negative == nil ? pos : neg))
                Rectangle()
                    .fill(firing ? Color.green : Color.accentColor.opacity(0.8))
                    .frame(width: fill)
                    .offset(x: clamped >= 0 ? half : half - fill)
                Rectangle()
                    .fill(Color.primary.opacity(0.4))
                    .frame(width: 1)
                    .offset(x: half)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }
}

struct MotionWidget: View {
    let state: ControllerState
    /// Integrated angles passed in from the parent (VirtualControllerView)
    /// where the single stable Timer lives. We don't run the integrator
    /// here because this view is recreated on every 30 Hz tick of the
    /// outer TimelineView, which kept tearing down Timer subscriptions
    /// and freezing the model after the first sample.
    let integratedRoll: Float
    let integratedPitch: Float
    let integratedYaw: Float

    var body: some View {
        // Prefer real attitude when the controller reports it; fall back
        // to the parent's integrated gyro angles so the model still shows
        // live motion on controllers where Apple's sensor fusion isn't
        // running.
        let rawRoll  = (state.motion[.rollAngle]  ?? 0) * .pi
        let rawPitch = (state.motion[.pitchAngle] ?? 0) * (.pi / 2)
        let rawYaw   = (state.motion[.yawAngle]   ?? 0) * .pi
        // Each angle is chosen on its own. Pitch arrives fused for every
        // pad with an accelerometer, and one test across all three read
        // that as "has attitude", so roll and yaw showed a flat zero on
        // pads without Apple's attitude.
        let roll  = abs(rawRoll)  > 0.0001 ? rawRoll  : integratedRoll
        let pitch = state.motion[.pitchAngle] != nil ? rawPitch : integratedPitch
        let yaw   = abs(rawYaw)   > 0.0001 ? rawYaw   : integratedYaw

        return GyroVisualizationView(
            gyroX: state.motion[.gyroX] ?? 0,
            gyroY: state.motion[.gyroY] ?? 0,
            gyroZ: state.motion[.gyroZ] ?? 0,
            rollAngle: roll,
            pitchAngle: pitch,
            yawAngle: yaw,
            mode: .compact,
            // A picture, not a live SceneKit view: the zoomed map is drawn
            // as one picture (SharpZoom), which cannot hold an AppKit view.
            modelAsImage: true
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Motion")
        .accessibilityValue("Roll \(SpokenLive.degrees(roll)), pitch \(SpokenLive.degrees(pitch)), yaw \(SpokenLive.degrees(yaw)) degrees")
    }
}

/// The light bar's label: an icon, the words, the preset's color, and a
/// chevron. In the drawing it takes the size of the drawing's captions and
/// drops the words when the gap between the triggers is too narrow.
struct LightBarChipLabel: View {
    let off: Bool
    let rainbow: Bool
    let tint: Color?
    /// The Settings switch that leaves the light to macOS: the chip says
    /// so instead of a color the controller will not show.
    var leftToSystem: Bool = false
    @Environment(\.canvasCaptionSize) private var canvasCaptionSize
    private var fs: CGFloat { canvasCaptionSize ?? 12 }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            chip(words: true)
            chip(words: false)
        }
    }

    @ViewBuilder
    private func chip(words: Bool) -> some View {
        HStack(spacing: fs * 0.5) {
            Image(systemName: "light.beacon.max.fill")
                .font(.system(size: fs * 0.9))
                .foregroundStyle(.secondary)
            if words {
                Text("Light bar")
                    .font(.system(size: fs))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            if leftToSystem {
                Text("macOS")
                    .font(.system(size: fs))
                    .foregroundStyle(.primary)
                    .fixedSize()
            } else if off {
                Text("Off")
                    .font(.system(size: fs))
                    .foregroundStyle(.primary)
                    .fixedSize()
            } else if rainbow {
                Capsule()
                    .fill(LinearGradient(colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: fs * 3.2, height: fs * 0.8)
            } else if let tint = tint {
                Capsule()
                    .fill(tint)
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                    .shadow(color: tint.opacity(0.6), radius: 3)
                    .frame(width: fs * 3.2, height: fs * 0.8)
            } else {
                Text("Not set")
                    .font(.system(size: fs))
                    .foregroundStyle(.hint)
                    .fixedSize()
            }
            Image(systemName: "chevron.down")
                .font(.system(size: fs * 0.7, weight: .semibold))
                .foregroundStyle(.hint)
        }
    }

}
