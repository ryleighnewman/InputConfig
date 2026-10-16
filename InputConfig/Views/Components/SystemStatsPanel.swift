import SwiftUI

/// Compact readout of the InputConfig process's live resource use:
/// CPU%, resident memory, thread count, and a coarse "energy impact"
/// number. Lives in Settings → General so the user can confirm a
/// polling-rate or preset change didn't blow up CPU/RAM. Subscribes
/// to `SystemStatsService` only while visible to avoid burning a 1 Hz
/// timer when the panel isn't on screen.
struct SystemStatsPanel: View {
    @ObservedObject private var stats = SystemStatsService.shared

    var body: some View {
        let s = stats.current
        let c = stats.cumulative
        let p = stats.power
        VStack(alignment: .leading, spacing: 10) {
            // Live. A flow, so on a narrow sheet the values wrap to a
            // second line instead of squeezing.
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Now")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 58, alignment: .leading)
                CenteredFlow(spacing: 16, alignment: .leading) {
                    stat("CPU", String(format: "%.1f%%", locale: .current, s.smoothedCpuPercent), cpuTint(for: s.smoothedCpuPercent))
                    stat("Memory", String(format: String(localized: "%.0f MB"), locale: .current, s.residentMemoryMB), memoryTint(for: s.residentMemoryMB))
                    stat("Threads", "\(s.threadCount)")
                    stat("Energy", "\(s.energyImpact)", energyTint(for: s.energyImpact))
                }
            }

            Divider()

            // Session totals, with the reset at the end.
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Session")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 58, alignment: .leading)
                CenteredFlow(spacing: 16, alignment: .leading) {
                    stat("Uptime", formatDuration(c.sessionUptime))
                    stat("Avg CPU", String(format: "%.1f%%", locale: .current, c.averageCpuPercent), cpuTint(for: c.averageCpuPercent))
                    stat("Peak CPU", String(format: "%.1f%%", locale: .current, c.peakCpuPercent), cpuTint(for: c.peakCpuPercent))
                    stat("Peak memory", String(format: String(localized: "%.0f MB"), locale: .current, c.peakMemoryMB), memoryTint(for: c.peakMemoryMB))
                    stat("Energy", formatEnergy(c.estimatedEnergyJoules))
                    stat("Polls", formatBigNumber(c.controllerPollsCounted))
                }
                Spacer(minLength: 0)
                Button("Reset") { stats.resetSessionStats() }
                    .buttonStyle(.solidSecondaryCompact)
                    .controlSize(.small)
                    .help("Start the session totals over")
            }

            // Power, only on a laptop.
            if p.source != nil || p.batteryPercent != nil {
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Power")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 58, alignment: .leading)
                    CenteredFlow(spacing: 16, alignment: .leading) {
                        stat("Source", p.source.map(PowerText.source) ?? String(localized: "Unknown"), powerSourceColor(p.source))
                        if let pct = p.batteryPercent {
                            stat("Battery", "\(pct)%", batteryTint(for: pct))
                        }
                        if abs(p.batteryDeltaPercent) >= 0.5 {
                            let delta = p.batteryDeltaPercent
                            stat("Since start", String(format: "%+.0f%%", locale: .current, -delta), delta > 0 ? .orange : .green)
                        }
                        if let mins = p.minutesRemaining {
                            stat("Time left", String(localized: "\(mins) min"))
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .onAppear { stats.retain() }
        .onDisappear { stats.release() }
    }

    /// One label and one value, the same size everywhere on the panel.
    private func stat(_ label: LocalizedStringKey, _ value: String, _ color: Color = .primary) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit())
                .foregroundStyle(color)
        }
        .fixedSize()
        // One stop per stat for VoiceOver: "CPU, 3.2%".
        .accessibilityElement(children: .combine)
    }

    // MARK: - Formatting

    /// "1h 02m" / "13m 09s" / "47s", the units in the app's language and
    /// the second number zero-padded so the tile keeps its width.
    private func formatDuration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        func two(_ n: Int) -> String { n.formatted(.number.precision(.integerLength(2)).grouping(.never)) }
        if s >= 3600 {
            return String(localized: "\(s / 3600)h \(two((s % 3600) / 60))m", comment: "Uptime: hours, then zero-padded minutes, short units")
        }
        if s >= 60 {
            return String(localized: "\(s / 60)m \(two(s % 60))s", comment: "Uptime: minutes, then zero-padded seconds, short units")
        }
        return String(localized: "\(s)s", comment: "Uptime in seconds, short unit")
    }

    /// Joules → human units. <1 kJ stays in J; otherwise kJ. Includes
    /// a Wh equivalent in the tooltip when over a minute of energy.
    private func formatEnergy(_ joules: Double) -> String {
        // The unit in the app's language, as Statistics shows it.
        let m = Measurement(value: joules, unit: UnitEnergy.joules)
        return joules < 1000
            ? m.formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))))
            : m.converted(to: .kilojoules).formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                                                  numberFormatStyle: .number.precision(.fractionLength(1))))
    }

    /// 1234567 → "1.23M", 12345 → "12.3K", in the app's language. Reads
    /// cleanly in a tile.
    private func formatBigNumber(_ n: UInt64) -> String {
        Double(n).formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
    }

    private func powerSourceColor(_ s: String?) -> Color {
        guard let s = s else { return .secondary }
        if s.lowercased().contains("battery") { return .orange }
        return .green
    }

    private func batteryTint(for pct: Int) -> Color {
        if pct <= 15 { return .red }
        if pct <= 35 { return .orange }
        return .green
    }

    @ViewBuilder
    private func cpuTint(for v: Double) -> Color {
        if v > 80 { return .red }
        if v > 40 { return .orange }
        return .green
    }

    private func memoryTint(for mb: Double) -> Color {
        if mb > 500 { return .red }
        if mb > 250 { return .orange }
        return .secondary
    }

    private func energyTint(for impact: Int) -> Color {
        if impact > 70 { return .red }
        if impact > 35 { return .orange }
        return .green
    }
}
