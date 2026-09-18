import SwiftUI

/// Live tap calibrator for the Tap the Mac input. Shows the chassis
/// accelerometer's residual (gravity removed) as a scrolling trace, the
/// detector's threshold and noise floor over it, every threshold crossing
/// with the verdict the detector gave it, and the gestures it committed. A
/// slider moves the threshold floor while the trace runs, so the user can
/// knock, watch where the peaks land, and put the line where their taps clear
/// it and their handling does not.
///
/// The sensor stream is started here if no preset is already running it, and
/// stopped again on close only in that case, so an active preset keeps
/// working while the sheet is open.
struct TapCalibrationView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var snapshot: ChassisTapService.Snapshot?
    @State private var threshold: Double = ChassisTapService.defaultMinPeak
    /// Peak-hold readout of the strongest strike seen since the sheet opened.
    @State private var strongest: Double = 0
    @State private var lastGesture: (count: Int, at: Double)?

    private static let window = 4.0
    /// Top of the plot in g. Taps land at 0.15 to 0.5 g; a hard slam a little
    /// past that. Log scale below keeps the noise floor visible too.
    private static let plotTop = 1.0
    private static let plotBottom = 0.003
    /// Trace resolution. Bins are anchored to absolute time so the trace
    /// scrolls in whole bins instead of re-binning every frame, which is what
    /// made it shimmer.
    private static let binSeconds = 0.008

    @State private var showingTips = false

    var body: some View {
        // One heading line, the plot, one readout line, one threshold row.
        // Four type styles in the whole sheet: headline, callout, caption,
        // caption2 in the plot. The explanations live in the help popover.
        VStack(alignment: .leading, spacing: 14) {
            header

            plot
                .frame(height: 210)
            legend

            readout
                .animation(.easeOut(duration: 0.2), value: lastGesture?.at)

            thresholdControls

            Spacer(minLength: 0)

            HStack {
                Button {
                    ChassisTapService.shared.resetThresholdFloor()
                    threshold = ChassisTapService.defaultMinPeak
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.solidSecondary)
                .disabled(abs(threshold - ChassisTapService.defaultMinPeak) < 0.0005)
                Button {
                    showingTips.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.solidSecondary)
                .help("How to get a clean reading")
                .popover(isPresented: $showingTips, arrowEdge: .top) { tips }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(SolidButton(tint: .accentColor))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 560, minHeight: 440, idealHeight: 440)
        .onAppear {
            threshold = ChassisTapService.shared.thresholdFloor
            ChassisTapService.shared.retain("calibrator")
        }
        .onDisappear {
            ChassisTapService.shared.release("calibrator")
        }
        .onReceive(Timer.publish(every: 1.0 / 40.0, on: .main, in: .common).autoconnect()) { _ in
            let s = ChassisTapService.shared.calibrationSnapshot(window: Self.window + 0.1)
            if let peak = s.strikes.map({ $0.1 }).max(), peak > strongest { strongest = peak }
            if let g = s.gestures.last, g.0 != lastGesture?.at {
                lastGesture = (g.1, g.0)
            }
            snapshot = s
        }
    }

    static func gestureName(_ count: Int) -> String {
        switch count {
        case 1: return "Single tap"
        case 2: return "Double tap"
        case 3: return "Triple tap"
        case 4: return "Quadruple tap"
        case 5: return "Quintuple tap"
        default: return "\(count) taps"
        }
    }

    // MARK: - Header and status

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.tap.fill")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Tap the Mac")
                .font(.headline)
            Spacer()
            statusChip
        }
    }

    private var statusChip: some View {
        let (text, color): (String, Color) = {
            guard let s = snapshot else { return ("Starting", .secondary) }
            if !s.running { return (s.error ?? "Sensor not available on this Mac", .red) }
            if s.hz == 0 && s.silence < 1.5 { return ("Waking sensor", .orange) }
            if s.parked { return ("Sensor parked, waking", .orange) }
            return ("Listening", .green)
        }()
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// What just happened and the strongest knock so far, on one line.
    private var readout: some View {
        HStack(spacing: 6) {
            if let g = lastGesture, let s = snapshot, s.now - g.at < 3.0 {
                Text(Self.gestureName(g.count))
                    .foregroundStyle(.green)
                    .contentTransition(.opacity)
            } else {
                Text("Knock to test")
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text("strongest")
                .foregroundStyle(.secondary)
            Text(strongest > 0 ? String(format: "%.3f g", strongest) : "none yet")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    // MARK: - Plot

    private func y(_ magnitude: Double, in rect: CGRect) -> CGFloat {
        let lo = log10(Self.plotBottom), hi = log10(Self.plotTop)
        let v = log10(max(Self.plotBottom, min(Self.plotTop, magnitude)))
        let t = (v - lo) / (hi - lo)
        return rect.maxY - CGFloat(t) * rect.height
    }

    private var plot: some View {
        Canvas { ctx, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 0, dy: 6)
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 10),
                     with: .color(.black.opacity(0.28)))

            // Gridlines at decades.
            for g in [0.01, 0.1, 1.0] {
                let yy = y(g, in: rect)
                var p = Path(); p.move(to: CGPoint(x: rect.minX, y: yy)); p.addLine(to: CGPoint(x: rect.maxX, y: yy))
                ctx.stroke(p, with: .color(.white.opacity(0.08)), lineWidth: 1)
                ctx.draw(Text(g >= 1 ? "1 g" : String(format: "%.2g g", g)).font(.caption2).foregroundStyle(.secondary),
                         at: CGPoint(x: rect.minX + 4, y: g >= 1 ? yy + 9 : yy - 8), anchor: .leading)
            }

            guard let s = snapshot, s.running else {
                ctx.draw(Text("Waiting for the sensor").font(.callout).foregroundStyle(.secondary),
                         at: CGPoint(x: rect.midX, y: rect.midY))
                return
            }
            // The window's right edge sits on a bin boundary, so every sample
            // stays in the same bin from frame to frame and the whole trace
            // slides left one bin at a time.
            let tEnd = floor(s.now / Self.binSeconds) * Self.binSeconds
            let t0 = tEnd - Self.window
            func x(_ t: Double) -> CGFloat { rect.minX + CGFloat((t - t0) / Self.window) * rect.width }

            // Envelope: peak per bin (a 10 ms knock at 800 Hz is never lost
            // between drawn points), lightly smoothed in log space and drawn
            // as a curve, so the resting noise reads as a calm band and a
            // strike as one clean spike.
            let bins = Int(Self.window / Self.binSeconds)
            if bins > 0, !s.samples.isEmpty {
                var peaks = [Double](repeating: Self.plotBottom, count: bins)
                var have = [Bool](repeating: false, count: bins)
                for (t, m) in s.samples {
                    let b = Int((t - t0) / Self.binSeconds)
                    guard b >= 0, b < bins else { continue }
                    peaks[b] = max(peaks[b], m); have[b] = true
                }
                let lv = peaks.map { log10(max(Self.plotBottom, $0)) }
                var smooth = lv
                for i in 0..<bins {
                    var acc = 0.0, n = 0.0
                    for k in max(0, i - 2)...min(bins - 1, i + 2) where have[k] { acc += lv[k]; n += 1 }
                    // Keep peaks honest: never smooth a strike below itself.
                    smooth[i] = n > 0 ? max(lv[i], acc / n) : lv[i]
                }
                func yl(_ l: Double) -> CGFloat {
                    let lo = log10(Self.plotBottom), hi = log10(Self.plotTop)
                    return rect.maxY - CGFloat((min(hi, l) - lo) / (hi - lo)) * rect.height
                }
                var pts: [CGPoint] = []
                for b in 0..<bins where have[b] {
                    pts.append(CGPoint(x: x(t0 + (Double(b) + 0.5) * Self.binSeconds), y: yl(smooth[b])))
                }
                if pts.count > 2 {
                    var trace = Path()
                    trace.move(to: pts[0])
                    for i in 1..<pts.count {
                        let mid = CGPoint(x: (pts[i - 1].x + pts[i].x) / 2, y: (pts[i - 1].y + pts[i].y) / 2)
                        trace.addQuadCurve(to: mid, control: pts[i - 1])
                    }
                    trace.addLine(to: pts[pts.count - 1])
                    var fill = trace
                    fill.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: rect.maxY))
                    fill.addLine(to: CGPoint(x: pts[0].x, y: rect.maxY))
                    fill.closeSubpath()
                    ctx.fill(fill, with: .linearGradient(Gradient(colors: [Color.accentColor.opacity(0.32), Color.accentColor.opacity(0.02)]),
                                                         startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: rect.maxY)))
                    ctx.stroke(trace, with: .color(Color.accentColor), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                }
            }

            // Noise floor (dashed) and threshold (solid).
            let fy = y(s.noiseFloor, in: rect)
            var floorPath = Path(); floorPath.move(to: CGPoint(x: rect.minX, y: fy)); floorPath.addLine(to: CGPoint(x: rect.maxX, y: fy))
            ctx.stroke(floorPath, with: .color(.gray.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            let ty = y(s.threshold, in: rect)
            var thr = Path(); thr.move(to: CGPoint(x: rect.minX, y: ty)); thr.addLine(to: CGPoint(x: rect.maxX, y: ty))
            ctx.stroke(thr, with: .color(.orange), lineWidth: 1.5)
            ctx.draw(Text(String(format: "threshold %.3f g", s.threshold)).font(.caption2).foregroundStyle(.orange),
                     at: CGPoint(x: rect.maxX - 6, y: ty - 8), anchor: .trailing)

            // Strike markers with verdict color.
            for (t, peak, verdict) in s.strikes {
                let color: Color = verdict.hasPrefix("TAP") ? .green : verdict == "typing" ? .yellow : verdict == "refrac" ? .red : .gray
                let px = x(t), py = y(peak, in: rect)
                let r: CGFloat = verdict.hasPrefix("TAP") ? 4 : 2.5
                ctx.fill(Path(ellipseIn: CGRect(x: px - r, y: py - r, width: r * 2, height: r * 2)), with: .color(color))
                if verdict.hasPrefix("TAP") {
                    ctx.draw(Text(verdict.replacingOccurrences(of: "TAP ", with: "")).font(.caption2).foregroundStyle(.green),
                             at: CGPoint(x: px, y: py - 9), anchor: .bottom)
                }
            }

            // Gesture commits as a vertical tick at the top.
            for (t, count) in s.gestures {
                let px = x(t)
                var p = Path(); p.move(to: CGPoint(x: px, y: rect.minY)); p.addLine(to: CGPoint(x: px, y: rect.minY + 14))
                ctx.stroke(p, with: .color(.green), lineWidth: 2)
                ctx.draw(Text("\(count)").font(.caption2).foregroundStyle(.green),
                         at: CGPoint(x: px + 4, y: rect.minY + 2), anchor: .topLeading)
            }
        }
        .accessibilityLabel("Tap strength over the last four seconds, with the threshold line")
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(.green, "Counted as a tap")
            legendItem(.gray, "Ring-down of a strike")
            legendItem(.red, "Too soon after a tap")
            legendItem(.yellow, "Ignored: typing or clicking")
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func legendItem(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
        }
    }

    // MARK: - Threshold

    /// Label, slider, number: the same row shape as every other setting.
    /// Log slider: the useful range is 0.02 to 0.6 g and the low end needs
    /// the most resolution.
    private var thresholdControls: some View {
        HStack(spacing: 12) {
            Text("Tap threshold")
                .frame(minWidth: 96, alignment: .leading)
            Slider(value: Binding(
                get: { log10(threshold) },
                set: { v in
                    threshold = pow(10, v)
                    ChassisTapService.shared.thresholdFloor = threshold
                }
            ), in: log10(0.02)...log10(0.6))
            .labelsHidden()
            .accessibilityLabel("Tap threshold")
            .accessibilityValue(String(format: "%.3f g", threshold))
            Text(String(format: "%.3f g", threshold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 56, alignment: .trailing)
        }
        .font(.callout)
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Getting a clean reading")
                .font(.headline)
            Text("Knock on the palm rest and put the line where your taps clear it and handling does not. Lower it if taps are missed; raise it if setting the Mac down counts as one.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Knock with a knuckle or fingertip on the palm rest beside the trackpad. Knocks about as fast as a double click count as one gesture, up to five; a pause starts a new count. Typing and clicking shake the case as much as a tap, so strikes within a third of a second of a key or click are ignored (shown in yellow), which is why a tap right after moving the slider does not count. A MacBook on a bed or a lap absorbs taps; a desk gives the strongest peaks.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 360)
    }
}
