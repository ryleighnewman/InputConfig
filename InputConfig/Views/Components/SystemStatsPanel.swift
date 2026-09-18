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
                    stat("CPU", String(format: "%.1f%%", s.smoothedCpuPercent), cpuTint(for: s.smoothedCpuPercent))
                    stat("Memory", String(format: "%.0f MB", s.residentMemoryMB), memoryTint(for: s.residentMemoryMB))
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
                    stat("Avg CPU", String(format: "%.1f%%", c.averageCpuPercent), cpuTint(for: c.averageCpuPercent))
                    stat("Peak CPU", String(format: "%.1f%%", c.peakCpuPercent), cpuTint(for: c.peakCpuPercent))
                    stat("Peak memory", String(format: "%.0f MB", c.peakMemoryMB), memoryTint(for: c.peakMemoryMB))
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
                        stat("Source", p.source ?? "Unknown", powerSourceColor(p.source))
                        if let pct = p.batteryPercent {
                            stat("Battery", "\(pct)%", batteryTint(for: pct))
                        }
                        if abs(p.batteryDeltaPercent) >= 0.5 {
                            let delta = p.batteryDeltaPercent
                            stat("Since start", String(format: "%+.0f%%", -delta), delta > 0 ? .orange : .green)
                        }
                        if let mins = p.minutesRemaining {
                            stat("Time left", "\(mins) min")
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
    private func stat(_ label: String, _ value: String, _ color: Color = .primary) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit())
                .foregroundStyle(color)
        }
        .fixedSize()
    }

    // MARK: - Formatting

    /// "1h 02m 13s" / "13m 09s" / "47s". Compact, monospace-friendly.
    private func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let r = s % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        if m > 0 { return String(format: "%dm %02ds", m, r) }
        return "\(r)s"
    }

    /// Joules → human units. <1 kJ stays in J; otherwise kJ. Includes
    /// a Wh equivalent in the tooltip when over a minute of energy.
    private func formatEnergy(_ joules: Double) -> String {
        if joules < 1000 { return String(format: "%.0f J", joules) }
        return String(format: "%.1f kJ", joules / 1000.0)
    }

    /// 1234567 → "1.23M", 12345 → "12.3K". Reads cleanly in a tile.
    private func formatBigNumber(_ n: UInt64) -> String {
        if n < 1000 { return "\(n)" }
        if n < 1_000_000 { return String(format: "%.1fK", Double(n) / 1000) }
        if n < 1_000_000_000 { return String(format: "%.2fM", Double(n) / 1_000_000) }
        return String(format: "%.2fB", Double(n) / 1_000_000_000)
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
