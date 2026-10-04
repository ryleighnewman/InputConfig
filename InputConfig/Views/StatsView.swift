import SwiftUI
import Charts

/// One tile's worth of detail. Each tile in the grid is a `StatTileView`
/// built from one of these, and clicking it opens a `StatDetailPopover`.
struct StatDetail: Identifiable {
    let id = UUID()
    let icon: String
    let tint: Color
    let value: String
    let label: String
    /// Plain-English explanation of what the number actually counts. Shown
    /// in the detail popover so the user understands how each metric is
    /// gathered.
    let explanation: String
    /// Optional related rows ("see also") for richer drill-downs.
    var related: [(label: String, value: String)] = []
    /// Top inputs leaderboard (button presses / axis flicks / etc.). Drawn
    /// as a mini horizontal-bar chart inside the detail popover.
    var topInputs: [(key: String, count: Int)]? = nil
    /// Top presets leaderboard.
    var topPresets: [(name: String, count: Int)]? = nil
    /// Top controllers leaderboard (seconds-of-connection per device).
    var topControllers: [(name: String, seconds: TimeInterval)]? = nil
    /// 14-day connection history in seconds-per-day, oldest first. Drawn
    /// as a sparkline / bar chart for tiles where it makes sense.
    var last14Days: [TimeInterval]? = nil
}

/// Lifetime statistics dashboard. Opened from the round chart icon in the
/// main window toolbar. Everything shown here is local; no telemetry leaves
/// the device.
struct StatsView: View {
    @StateObject private var service: StatsServiceRef = StatsServiceRef()
    @Environment(\.dismiss) private var dismiss
    @State private var showResetConfirmation = false
    /// Subscribed to live so the power tiles update once per second
    /// while the dashboard is open.
    @ObservedObject private var sysStats = SystemStatsService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 22)
                .padding(.top, 22)
                .padding(.bottom, 6)

            // ScrollView sits flush against the sheet edges so the scroll
            // bar tracks against the outer edge of the window, not inset
            // by the sheet's padding. The content keeps a top inset of its
            // own: flush against the clip edge, the first row of tiles lost
            // its top edge, its keyboard focus ring, and its hover lift.
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.gap) {
                    tileGrid
                    HStack(alignment: .top, spacing: Metrics.gap) {
                        glassCard("Favorite presets") { presetsChart }
                        glassCard("Most-pressed inputs") { inputsSection }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    glassCard("Last 14 days", trailing: busiestDayText) { timelineChart }
                    HStack(alignment: .top, spacing: Metrics.gap) {
                        glassCard("Time per controller") { controllersSection }
                        glassCard("Output mix") { outputsChart }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    glassCard("This session", trailing: "Energy is an estimate") { powerSection }
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }

            Divider()

            HStack {
                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    Label("Reset Statistics", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(SolidButton(tint: .red, prominent: false, size: .compact))
                .foregroundStyle(.red)
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.solidSecondary)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(width: 780, height: 740)
        // The app's layered icon look, set here too so every icon in the
        // sheet and its popovers draws its secondary layers translucent.
        .symbolRenderingMode(.hierarchical)
        .onAppear { sysStats.retain() }
        .onDisappear { sysStats.release() }
        .confirmationDialog("Reset all statistics?",
                            isPresented: $showResetConfirmation,
                            titleVisibility: .visible) {
            Button("Reset Everything", role: .destructive) {
                StatsService.shared.resetAll()
                service.refresh()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Lifetime counters, daily logs, and per-preset history will all return to zero. This cannot be undone.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 26))
                .iconTint(Color.accentColor)
                .frame(width: 44, height: 44)
                .liquidGlass(in: Circle(), tint: Color.accentColor.opacity(0.25))
                .accessibilityHidden(true)
            Text("Statistics")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
        }
    }

    // MARK: - Tiles

    private struct TileSpec {
        let detail: StatDetail
        let subline: String
        let count: Double
        let alwaysShown: Bool
    }

    /// Tiles for the counters that have something to show. A counter still
    /// at zero gets no tile at all, so there is never a wall of zeros.
    private var tileGrid: some View {
        let shown = tileSpecs.filter { $0.alwaysShown || $0.count > 0 }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 10)], spacing: 10) {
            ForEach(shown, id: \.detail.label) { spec in
                StatTileView(detail: spec.detail, subline: spec.subline)
            }
        }
    }

    private var tileSpecs: [TileSpec] {
        let s = service.stats
        // Helpers shared across multiple tiles so each detail sheet can
        // surface real breakdowns instead of a static explanation.
        let topInputs = service.topInputs.prefix(5).map { (key: $0.key, count: $0.count) }
        let topPresets = service.topPresets.prefix(5).map { (name: $0.name, count: $0.count) }
        let topCtrls = service.topControllers.prefix(5).map { (name: $0.name, seconds: $0.time) }
        let last14 = service.last14DaysConnected.map(\.seconds)
        let activeMinutes = s.totalEngineRunningTime / 60
        func perMinute(_ n: Int) -> String {
            activeMinutes >= 1 ? "\(bigNumber(Int(Double(n) / activeMinutes))) per active minute" : "per active minute soon"
        }
        let meters = Double(s.totalMouseMotionPixels) / 96.0 * 0.0254

        return [
            TileSpec(detail: StatDetail(
                icon: "gamecontroller.fill", tint: .blue,
                value: timeShort(s.totalConnectedTime),
                label: "Time with a controller",
                explanation: "Cumulative time any controller has been plugged in or paired since you first launched the app.",
                related: [
                    ("Days tracked", "\(service.daysTracked)"),
                    ("Average per day", service.daysTracked > 0
                        ? timeShort(s.totalConnectedTime / Double(service.daysTracked))
                        : "-")
                ],
                topControllers: topCtrls,
                last14Days: last14),
                subline: service.daysTracked > 0 ? "\(timeShort(s.totalConnectedTime / Double(service.daysTracked))) a day on average" : "",
                count: s.totalConnectedTime, alwaysShown: true),
            TileSpec(detail: StatDetail(
                icon: "play.fill", tint: .green,
                value: timeShort(s.totalEngineRunningTime),
                label: "Time with a preset active",
                explanation: "Total time the mapping engine has been running with a preset active and firing outputs.",
                related: [
                    ("Activations", "\(s.presetActivationCount)"),
                    ("Average per activation", s.presetActivationCount > 0
                        ? timeShort(s.totalEngineRunningTime / Double(s.presetActivationCount))
                        : "-"),
                    ("Connected vs active",
                        s.totalConnectedTime > 0
                        ? String(format: "%.1f%%", min(100, s.totalEngineRunningTime / s.totalConnectedTime * 100))
                        : "-")
                ],
                topPresets: topPresets),
                subline: s.totalConnectedTime > 0
                    ? "\(Int(min(100, s.totalEngineRunningTime / s.totalConnectedTime * 100).rounded()))% of connected time" : "",
                count: s.totalEngineRunningTime, alwaysShown: true),
            TileSpec(detail: StatDetail(
                icon: "hand.point.up.left.fill", tint: .orange,
                value: bigNumber(s.totalButtonPresses),
                label: "Button presses",
                explanation: "Every controller button press counts, across every preset and every controller. Hat / D-pad direction changes count too.",
                related: [
                    ("Average per minute (active)", s.totalEngineRunningTime > 60
                        ? bigNumber(Int(Double(s.totalButtonPresses) / (s.totalEngineRunningTime / 60)))
                        : "-")
                ],
                topInputs: topInputs),
                subline: perMinute(s.totalButtonPresses),
                count: Double(s.totalButtonPresses), alwaysShown: true),
            TileSpec(detail: StatDetail(
                icon: "arrowtriangle.up.fill", tint: .red,
                value: "\(s.presetActivationCount)",
                label: "Preset activations",
                explanation: "Number of distinct times you've turned a preset on. Toggling off then back on counts as a fresh activation.",
                topPresets: topPresets),
                subline: service.topPresets.first.map { "Most often \($0.name)" } ?? "",
                count: Double(s.presetActivationCount), alwaysShown: true),
            TileSpec(detail: StatDetail(
                icon: "keyboard.fill", tint: .indigo,
                value: bigNumber(s.totalKeyPresses),
                label: "Keystrokes sent",
                explanation: "Number of key outputs the engine has fired. A press and its release count once; a row with several keys counts each one.",
                related: [
                    ("Per minute active", s.totalEngineRunningTime > 60
                        ? bigNumber(Int(Double(s.totalKeyPresses) / (s.totalEngineRunningTime / 60)))
                        : "-"),
                    ("Per button press", s.totalButtonPresses > 0
                        ? String(format: "%.2fx", Double(s.totalKeyPresses) / Double(s.totalButtonPresses))
                        : "-")
                ]),
                subline: perMinute(s.totalKeyPresses),
                count: Double(s.totalKeyPresses), alwaysShown: false),
            TileSpec(detail: StatDetail(
                icon: "cursorarrow.click.2", tint: .pink,
                value: bigNumber(s.totalMouseClicks),
                label: "Mouse clicks sent",
                explanation: "Mouse-button outputs the engine has fired: left, right, middle, and other buttons. A press and its release count once.",
                related: [
                    ("Per minute active", s.totalEngineRunningTime > 60
                        ? bigNumber(Int(Double(s.totalMouseClicks) / (s.totalEngineRunningTime / 60)))
                        : "-")
                ]),
                subline: perMinute(s.totalMouseClicks),
                count: Double(s.totalMouseClicks), alwaysShown: false),
            TileSpec(detail: StatDetail(
                icon: "cursorarrow.motionlines", tint: .teal,
                value: meters >= 1000 ? String(format: "%.2f km", meters / 1000) : String(format: "%.1f m", meters),
                label: "Pointer travel",
                explanation: "How far the engine has moved the cursor, measured as pixels on a 96 dpi screen. Stick aim, gyro aim, and touchpad mouse all contribute.",
                related: [
                    ("Pixels", bigNumber(s.totalMouseMotionPixels)),
                    ("Inches (96 dpi)", String(format: "%.1f\"", Double(s.totalMouseMotionPixels) / 96.0)),
                    ("Per minute active", s.totalEngineRunningTime > 60
                        ? bigNumber(Int(Double(s.totalMouseMotionPixels) / (s.totalEngineRunningTime / 60))) + " px"
                        : "-")
                ]),
                subline: "\(bigNumber(s.totalMouseMotionPixels)) pixels at 96 dpi",
                count: Double(s.totalMouseMotionPixels), alwaysShown: false),
            TileSpec(detail: StatDetail(
                icon: "scroll.fill", tint: .mint,
                value: bigNumber(s.totalScrollTicks),
                label: "Scroll ticks",
                explanation: "Vertical and horizontal scroll steps the engine has sent.",
                related: [
                    ("Per minute active", s.totalEngineRunningTime > 60
                        ? bigNumber(Int(Double(s.totalScrollTicks) / (s.totalEngineRunningTime / 60)))
                        : "-")
                ]),
                subline: perMinute(s.totalScrollTicks),
                count: Double(s.totalScrollTicks), alwaysShown: false),
            TileSpec(detail: StatDetail(
                icon: "music.note", tint: .purple,
                value: bigNumber(s.totalMidiEvents),
                label: "MIDI events sent",
                explanation: "Note-on, note-off, CC, pitch-bend, program change: every event sent to the virtual MIDI source counts.",
                related: [
                    ("Per minute active", s.totalEngineRunningTime > 60
                        ? bigNumber(Int(Double(s.totalMidiEvents) / (s.totalEngineRunningTime / 60)))
                        : "-")
                ]),
                subline: perMinute(s.totalMidiEvents),
                count: Double(s.totalMidiEvents), alwaysShown: false),
            TileSpec(detail: StatDetail(
                icon: "rectangle.and.hand.point.up.left.fill", tint: .cyan,
                value: bigNumber(s.totalTouchpadFingerEvents),
                label: "Touchpad finger updates",
                explanation: "Each new finger position reported by a DualSense or DualShock 4 touchpad counts as one update. Long sliding gestures generate many.",
                related: [
                    ("Per minute active", s.totalEngineRunningTime > 60
                        ? bigNumber(Int(Double(s.totalTouchpadFingerEvents) / (s.totalEngineRunningTime / 60)))
                        : "-")
                ]),
                subline: perMinute(s.totalTouchpadFingerEvents),
                count: Double(s.totalTouchpadFingerEvents), alwaysShown: false),
            TileSpec(detail: StatDetail(
                icon: "bolt.fill", tint: .yellow,
                value: bigNumber(s.totalMacroExecutions),
                label: "Macros run",
                explanation: "Number of times a macro binding has fired. Each macro chain counts once regardless of how many steps it contains.",
                related: [
                    ("Per activation", s.presetActivationCount > 0
                        ? String(format: "%.2f", Double(s.totalMacroExecutions) / Double(s.presetActivationCount))
                        : "-")
                ]),
                subline: s.presetActivationCount > 0
                    ? String(format: "%.1f per activation", Double(s.totalMacroExecutions) / Double(s.presetActivationCount)) : "",
                count: Double(s.totalMacroExecutions), alwaysShown: false),
        ]
    }

    // MARK: - Cards / Sections

    /// A section on its own glass card, the app's one card surface.
    private func glassCard<Content: View>(_ title: String, trailing: String? = nil,
                                          @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if let trailing, !trailing.isEmpty {
                    Text(trailing)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            content()
            Spacer(minLength: 0)
        }
        .padding(Metrics.cardPad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .liquidGlass(in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    @ViewBuilder
    private var presetsChart: some View {
        let top = service.topPresets
        if top.isEmpty {
            emptyHint("Activate a preset to start tracking.")
        } else {
            let maxCount = max(1, top.first?.count ?? 1)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(top.enumerated()), id: \.element.name) { i, row in
                    leaderboardRow(rank: i + 1, icon: nil, iconColor: .green,
                                   label: row.name, count: row.count,
                                   maxCount: maxCount, barTint: .green)
                }
            }
        }
    }

    @ViewBuilder
    private var inputsSection: some View {
        let top = Array(service.topInputs.prefix(5))
        if top.isEmpty {
            emptyHint("Push a button on your controller while a preset is active to start tracking.")
        } else {
            let maxCount = max(1, top.first?.count ?? 1)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(top.enumerated()), id: \.element.key) { i, row in
                    leaderboardRow(rank: i + 1, icon: iconForInputKey(row.key), iconColor: .orange,
                                   label: prettyInputLabel(row.key), count: row.count,
                                   maxCount: maxCount, barTint: .orange)
                }
            }
        }
    }

    /// One leaderboard row: rank, optional icon, the name, its count, and a
    /// thin bar under the name sized by its share of the leader.
    private func leaderboardRow(rank: Int,
                                icon: String?,
                                iconColor: Color,
                                label: String,
                                count: Int,
                                maxCount: Int,
                                barTint: Color) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text("\(rank)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(rank == 1 ? AnyShapeStyle(barTint) : AnyShapeStyle(.tertiary))
                .frame(width: 14, alignment: .trailing)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let icon {
                        StatIconBadge(icon: icon, tint: iconColor, diameter: 18)
                    }
                    Text(label)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text("\(count)\u{00D7}")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule()
                            .fill(barTint.opacity(0.8))
                            .frame(width: max(3, CGFloat(Double(count) / Double(maxCount)) * geo.size.width))
                    }
                }
                .frame(height: 4)
                .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Number \(rank), \(label)")
        .accessibilityValue("\(count) times")
    }

    @ViewBuilder
    private var controllersSection: some View {
        let top = service.topControllers
        if top.isEmpty {
            emptyHint("Connect a controller and use it for a while.")
        } else {
            let total = max(1, top.reduce(0) { $0 + $1.time })
            VStack(alignment: .leading, spacing: 10) {
                ForEach(top, id: \.name) { row in
                    let conns = service.stats.controllerConnectionCount[row.name] ?? 0
                    let share = row.time / total
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            StatIconBadge(icon: "gamecontroller.fill", tint: .blue, diameter: 18)
                            Text(row.name)
                                .font(.callout)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(timeShort(row.time))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.primary.opacity(0.08))
                                    Capsule().fill(Color.blue.opacity(0.75))
                                        .frame(width: max(3, CGFloat(share) * geo.size.width))
                                }
                            }
                            .frame(height: 4)
                            Text("\(conns) connection\(conns == 1 ? "" : "s")")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.hint)
                                .fixedSize()
                        }
                        .accessibilityHidden(true)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(row.name)
                    .accessibilityValue("\(timeShort(row.time)), \(Int((share * 100).rounded())) percent, \(conns) connection\(conns == 1 ? "" : "s")")
                }
            }
        }
    }

    /// "Busiest: Sep 28, 59m", for the 14-day card's corner.
    private var busiestDayText: String? {
        guard let best = service.last14DaysConnected.max(by: { $0.seconds < $1.seconds }),
              best.seconds > 0 else { return nil }
        return "Busiest: \(best.date.formatted(.dateTime.month(.abbreviated).day())), \(timeShort(best.seconds))"
    }

    @ViewBuilder
    private var timelineChart: some View {
        let days = service.last14DaysConnected
        let secs = days.map(\.seconds)
        let total = secs.reduce(0, +)
        let peak = secs.max() ?? 0
        let activeDays = secs.filter { $0 > 0 }.count
        let average = activeDays > 0 ? total / Double(activeDays) : 0
        Chart {
            ForEach(days, id: \.date) { day in
                BarMark(
                    x: .value("Day", day.date, unit: .day),
                    y: .value("Seconds", day.seconds)
                )
                .foregroundStyle(day.seconds > 0
                                 ? Color.accentColor.opacity(0.8)
                                 : Color.primary.opacity(0.1))
                .cornerRadius(4)
            }
            if activeDays > 1 {
                RuleMark(y: .value("Average", average))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(Color.secondary)
                    .annotation(position: .top, alignment: .leading) {
                        Text("average \(timeShort(average))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Controller connection over the last 14 days")
        .accessibilityValue("\(timeShort(total)) total across \(activeDays) active \(activeDays == 1 ? "day" : "days"), busiest day \(timeShort(peak))")
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated), centered: true)
                    .font(.caption2)
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel {
                    if let secs = value.as(Double.self) {
                        Text(timeShort(secs))
                            .font(.caption2)
                    }
                }
            }
        }
        .frame(height: 130)
    }

    @ViewBuilder
    private var outputsChart: some View {
        let s = service.stats
        let slices: [(name: String, count: Int, color: Color)] = [
            ("Keystrokes",       s.totalKeyPresses,        .indigo),
            ("Mouse clicks",     s.totalMouseClicks,       .pink),
            ("MIDI events",      s.totalMidiEvents,        .purple),
            ("Scroll ticks",     s.totalScrollTicks,       .mint),
            ("Macros",           s.totalMacroExecutions,   .yellow),
        ]
        let nonZero = slices.filter { $0.count > 0 }
        if nonZero.isEmpty {
            emptyHint("Fire some outputs while a preset is running to see your mix.")
        } else {
            let total = max(1, nonZero.reduce(0) { $0 + $1.count })
            HStack(alignment: .center, spacing: 14) {
                // Donut chart, one sector per output kind, total in the hole.
                Chart(nonZero, id: \.name) { slice in
                    SectorMark(
                        angle: .value("Count", slice.count),
                        innerRadius: .ratio(0.62),
                        angularInset: 1.5
                    )
                    .cornerRadius(3)
                    .foregroundStyle(slice.color.opacity(0.85))
                }
                .chartBackground { _ in
                    VStack(spacing: 0) {
                        Text(bigNumber(total))
                            .font(.headline.monospacedDigit())
                        Text("outputs")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 104, height: 104)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Output mix")
                .accessibilityValue(nonZero
                    .map { "\($0.name) \(Int(Double($0.count) / Double(total) * 100)) percent" }
                    .joined(separator: ", "))

                // Legend with raw counts.
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(nonZero, id: \.name) { slice in
                        HStack(spacing: 7) {
                            Circle().fill(slice.color.opacity(0.85)).frame(width: 8, height: 8)
                                .accessibilityHidden(true)
                            Text(slice.name)
                                .font(.callout)
                            Spacer(minLength: 4)
                            Text(Self.share(slice.count, of: total))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .help("\(slice.count) \(slice.name.lowercased())")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(slice.name)
                        .accessibilityValue("\(slice.count), \(Int(Double(slice.count) / Double(total) * 100)) percent")
                    }
                }
            }
        }
    }

    // MARK: - Format helpers

    /// A share as a whole percent, with "<1%" for a small share that is
    /// not zero, so a used output never reads as 0%.
    private static func share(_ count: Int, of total: Int) -> String {
        let pct = Double(count) / Double(max(1, total)) * 100
        if count > 0 && pct < 1 { return "<1%" }
        return "\(Int(pct.rounded()))%"
    }

    private func bigNumber(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }

    /// Live power and energy for this session, one compact row. The how of
    /// each number lives in its tooltip.
    private var powerSection: some View {
        let c = sysStats.cumulative
        let p = sysStats.power
        return HStack(alignment: .top, spacing: 10) {
            powerTile(label: "Uptime", value: timeShort(c.sessionUptime), icon: "clock",
                      tint: .secondary, hint: "Time the engine and stats panel have been polling.")
            powerTile(label: "Energy", value: formatEnergy(c.estimatedEnergyJoules), icon: "bolt.fill",
                      tint: .yellow, hint: "Coarse estimate: CPU percent times time times a 5 W package.")
            powerTile(label: "Avg CPU", value: String(format: "%.1f%%", c.averageCpuPercent), icon: "cpu",
                      tint: cpuTint(for: c.averageCpuPercent), hint: "Running mean since session start.")
            powerTile(label: "Peak CPU", value: String(format: "%.1f%%", c.peakCpuPercent), icon: "speedometer",
                      tint: cpuTint(for: c.peakCpuPercent), hint: "Highest single sample this session.")
            if let pct = p.batteryPercent {
                powerTile(label: "Battery", value: "\(pct)%", icon: batteryIcon(for: pct),
                          tint: batteryTint(for: pct),
                          hint: [p.source, p.batteryState].compactMap { $0 }.joined(separator: ", "))
            } else if let source = p.source {
                powerTile(label: "Power", value: source, icon: "powerplug.fill",
                          tint: .green, hint: "Where this Mac is drawing power from.")
            }
            if abs(p.batteryDeltaPercent) >= 0.5 {
                let delta = -p.batteryDeltaPercent
                powerTile(label: "This session", value: String(format: "%+.0f%%", delta),
                          icon: delta < 0 ? "arrow.down.circle" : "arrow.up.circle",
                          tint: delta < 0 ? .orange : .green,
                          hint: "Battery change since the panel opened.")
            }
        }
    }

    private func powerTile(label: String, value: String, icon: String,
                           tint: Color, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                StatIconBadge(icon: icon, tint: tint, diameter: 18)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.title3.weight(.medium).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .innerWell()
        .help(hint)
        .accessibilityElement(children: .combine)
        .accessibilityHint(hint)
    }

    private func formatEnergy(_ joules: Double) -> String {
        if joules < 1000 { return String(format: "%.0f J", joules) }
        return String(format: "%.1f kJ", joules / 1000.0)
    }

    private func cpuTint(for v: Double) -> Color {
        if v > 80 { return .red }
        if v > 40 { return .orange }
        return .green
    }

    private func batteryTint(for pct: Int) -> Color {
        if pct <= 15 { return .red }
        if pct <= 35 { return .orange }
        return .green
    }

    private func batteryIcon(for pct: Int) -> String {
        if pct >= 90 { return "battery.100" }
        if pct >= 65 { return "battery.75" }
        if pct >= 40 { return "battery.50" }
        if pct >= 15 { return "battery.25" }
        return "battery.0"
    }

    private func timeShort(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        return "\(s / 86400)d \((s % 86400) / 3600)h"
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.hint)
    }

    private func iconForInputKey(_ key: String) -> String {
        if key.hasPrefix("btn") { return "circle.fill" }
        if key.hasPrefix("axi") { return "arrow.left.and.right" }
        if key.hasPrefix("hat") { return "arrow.up.and.down.and.arrow.left.and.right" }
        if key.hasPrefix("tpd") { return "hand.point.up.left.fill" }
        if key.hasPrefix("tpr") { return "rectangle.dashed" }
        if key.hasPrefix("mtn") { return "gyroscope" }
        return "questionmark"
    }

    /// "Left stick up" rather than "Axis 1 -": the standard gamepad's own
    /// control names, then the input's generic name.
    private func prettyInputLabel(_ key: String) -> String {
        Self.friendlyNames[key] ?? InputEvent.parse(key)?.displayName ?? key
    }

    static let friendlyNames: [String: String] = {
        var names: [String: String] = [:]
        for c in ControllerScaffold.standardGamepad() { names[c.input] = c.name }
        return names
    }()
}

/// Thin observable wrapper around the singleton StatsService so the view
/// re-renders when its `@Published stats` changes. We can't observe the
/// singleton directly from `@StateObject` since it's nonisolated-unsafe, so
/// we mirror its state into this proxy.
@MainActor
final class StatsServiceRef: ObservableObject {
    @Published var stats: StatsService.PersistentStats
    @Published var topPresets: [(name: String, count: Int)]
    @Published var topInputs: [(key: String, count: Int)]
    @Published var topControllers: [(name: String, time: TimeInterval)]
    @Published var daysTracked: Int
    @Published var last14DaysConnected: [(date: Date, seconds: TimeInterval)]

    private nonisolated(unsafe) var timer: Timer?

    init() {
        let svc = StatsService.shared
        self.stats = svc.stats
        self.topPresets = svc.topPresets
        self.topInputs = svc.topInputs
        self.topControllers = svc.topControllers
        self.daysTracked = svc.daysTracked
        self.last14DaysConnected = svc.last14DaysConnected
        // Refresh once per second while the view is on screen.
        self.timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        if let t = self.timer { RunLoop.main.add(t, forMode: .common) }
    }

    deinit {
        // Capture the timer locally so we don't access an isolated property
        // from the nonisolated deinit. Invalidate it from the main run loop.
        let t = timer
        DispatchQueue.main.async { t?.invalidate() }
    }

    private var lastStatsTick: Int = -1

    func refresh() {
        let svc = StatsService.shared
        // Skip the republish when nothing changed since the last tick, so an
        // idle second does not re-render the whole stats view.
        guard svc.statsTick != lastStatsTick else { return }
        lastStatsTick = svc.statsTick
        stats = svc.stats
        topPresets = svc.topPresets
        topInputs = svc.topInputs
        topControllers = svc.topControllers
        daysTracked = svc.daysTracked
        last14DaysConnected = svc.last14DaysConnected
    }
}

/// A tinted icon on a soft disc of its own color: the one icon treatment
/// for Statistics (tiles, leaderboards, controllers, power, popovers), so
/// every icon reads as the same layered, translucent mark at any size.
/// Grows with Text Size alongside the glyph it holds.
struct StatIconBadge: View {
    let icon: String
    let tint: Color
    var diameter: CGFloat = 28
    @Environment(\.appTextScale) private var textScale

    var body: some View {
        let d = (diameter * textScale).rounded()
        // The glyph's font goes through the app's scaled .font, so it takes
        // the unscaled size; the controller glyph is sized directly.
        IconView(name: icon, glyphHeight: (d * 0.42).rounded())
            .font(.system(size: (diameter * 0.46).rounded(), weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .iconTint(tint)
            .frame(width: d, height: d)
            .background(Circle().fill(tint.opacity(0.16)))
            .accessibilityHidden(true)
    }
}

/// One tile: a tinted icon badge, the number, its name, and a detail line.
/// Glass like the rest of the page; hover lifts it with the tile's color and
/// a click opens the detail popover anchored to the tile.
struct StatTileView: View {
    let detail: StatDetail
    var subline: String = ""
    @State private var hovering: Bool = false
    @State private var showingDetail: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Stays lit while its popover is open, so it is clear which tile
        // the popover belongs to.
        let lit = hovering || showingDetail
        Button {
            showingDetail.toggle()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center) {
                    StatIconBadge(icon: detail.icon, tint: detail.tint, diameter: 28)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.hint)
                        .opacity(lit ? 1 : 0)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(detail.value)
                        .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(detail.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !subline.isEmpty {
                        Text(subline)
                            .font(.caption2)
                            .foregroundStyle(.hint)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(12)
            .liquidGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous),
                         tint: lit ? detail.tint.opacity(0.22) : nil)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(detail.tint.opacity(lit ? 0.45 : 0), lineWidth: 1)
            )
            .scaleEffect(reduceMotion ? 1.0 : (hovering ? 1.015 : 1.0))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: lit)
        }
        .buttonStyle(.plain)
        // macOS otherwise draws an accent focus ring around the first
        // focusable button when the sheet opens (the top-left tile gets
        // it). Hidden unless Keyboard navigation is on, so every tile
        // looks the same for pointer users and keyboard users still see
        // where focus is.
        .focusRingForKeyboardUsers()
        .onHover { hovering = $0 }
        .help("Details for \(detail.label)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(detail.label): \(detail.value)")
        .accessibilityValue(subline)
        .accessibilityHint("Opens details")
        .accessibilityAddTraits(.isButton)
        // Last, so the tile's accessibility grouping above never reaches
        // into the popover's own elements.
        .popover(isPresented: $showingDetail, arrowEdge: .bottom) {
            StatDetailPopover(detail: detail)
        }
    }
}

/// The popover a tile opens: the metric, what it counts, related numbers,
/// and (when the data allows it) top-N leaderboards and a 14-day history.
/// Every section shares one shape, a small caption title over a quiet well,
/// and the popover sizes to its content on the system's translucent popover
/// surface.
struct StatDetailPopover: View {
    let detail: StatDetail
    @Environment(\.appTextScale) private var textScale

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Text(detail.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !detail.related.isEmpty {
                section("By the numbers") {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(detail.related.enumerated()), id: \.offset) { _, pair in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(pair.label)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 8)
                                Text(pair.value)
                                    .font(.callout.monospacedDigit())
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(pair.label)
                            .accessibilityValue(pair.value)
                        }
                    }
                }
            }

            if let inputs = detail.topInputs, !inputs.isEmpty {
                section("Top inputs") {
                    leaderboard(inputs.map { (label: prettyInputLabel($0.key),
                                              value: "\($0.count)\u{00D7}",
                                              weight: Double($0.count)) })
                }
            }

            if let presets = detail.topPresets, !presets.isEmpty {
                section("Top presets") {
                    leaderboard(presets.map { (label: $0.name,
                                               value: "\($0.count)\u{00D7}",
                                               weight: Double($0.count)) })
                }
            }

            if let ctrls = detail.topControllers, !ctrls.isEmpty {
                section("Top controllers") {
                    leaderboard(ctrls.map { (label: $0.name,
                                             value: timeStr($0.seconds),
                                             weight: $0.seconds) })
                }
            }

            if let last14 = detail.last14Days, !last14.isEmpty {
                section("Last 14 days") {
                    sparkline(values: last14)
                }
            }
        }
        .padding(16)
        .frame(width: (320 * textScale).rounded(), alignment: .leading)
        .modifier(StatPopoverBackdrop())
    }

    /// Same badge and number styling as the tile it came from.
    private var header: some View {
        HStack(spacing: 10) {
            StatIconBadge(icon: detail.icon, tint: detail.tint, diameter: 34)
            VStack(alignment: .leading, spacing: 0) {
                Text(detail.value)
                    .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(detail.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(detail.label)
        .accessibilityValue(detail.value)
        .accessibilityAddTraits(.isHeader)
    }

    /// One section: a caption title over its content in a quiet well.
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .innerWell()
        }
    }

    /// Leaderboard rows drawn like the dashboard's own: the name and its
    /// value on one line, a thin bar under them sized by share of the leader.
    private func leaderboard(_ rows: [(label: String, value: String, weight: Double)]) -> some View {
        let maxWeight = max(1, rows.map(\.weight).max() ?? 1)
        return VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(row.label)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        Text(row.value)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.08))
                            Capsule()
                                .fill(detail.tint.opacity(0.8))
                                .frame(width: max(3, CGFloat(row.weight / maxWeight) * geo.size.width))
                        }
                    }
                    .frame(height: 4)
                    .accessibilityHidden(true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.label)
                .accessibilityValue(row.value)
            }
        }
    }

    /// Compact bar chart of the 14-day history, filling the well's width.
    private func sparkline(values: [Double]) -> some View {
        let maxValue = max(1, values.max() ?? 1)
        let total = values.reduce(0, +)
        let peak = values.max() ?? 0
        let activeDays = values.filter { $0 > 0 }.count
        let height: CGFloat = 44
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(v > 0 ? detail.tint.opacity(0.8) : Color.primary.opacity(0.08))
                    .frame(maxWidth: .infinity)
                    .frame(height: max(4, CGFloat(v / maxValue) * height))
            }
        }
        .frame(height: height, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Last 14 days")
        .accessibilityValue("\(timeStr(total)) total across \(activeDays) active \(activeDays == 1 ? "day" : "days"), busiest day \(timeStr(peak))")
    }

    private func timeStr(_ s: TimeInterval) -> String {
        let i = Int(s)
        if i < 60 { return "\(i)s" }
        if i < 3600 { return "\(i / 60)m" }
        if i < 86400 { return "\(i / 3600)h \((i % 3600) / 60)m" }
        return "\(i / 86400)d \((i % 86400) / 3600)h"
    }

    private func prettyInputLabel(_ key: String) -> String {
        StatsView.friendlyNames[key] ?? InputEvent.parse(key)?.displayName ?? key
    }
}

/// The popover keeps the system's own translucent surface (Liquid Glass on
/// macOS 26 and later, the frosted popover material before that), which
/// already follows the system Reduce Transparency setting. The app's own
/// Reduce Transparency switch swaps in a solid window color, the same rule
/// every glass surface in the app follows.
private struct StatPopoverBackdrop: ViewModifier {
    @AppStorage("InputConfig.a11y.reduceTransparency") private var reduceTransparency = false

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.presentationBackground(Color(nsColor: .windowBackgroundColor))
        } else {
            content
        }
    }
}
