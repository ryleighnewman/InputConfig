import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Per-preset Advanced Options panel for the preset editor (labelled
/// "Advanced Options" in the UI; the type keeps the PresetAutomation
/// name for file-format compatibility). Houses settings that should ride
/// along with each preset rather than living in global app Settings -
/// because what makes sense for, say, a Counter-Strike preset (confine
/// cursor, hide cursor, auto-launch Steam) is exactly wrong for a
/// desktop-productivity preset.
///
/// Wired into PresetEditorView at the bottom of the binding list.
/// Bound to `preset.automation` so changes flow through the editor's
/// normal save / cancel path.
struct PresetAutomationSection: View {
    @SwiftUI.Binding var automation: PresetAutomation
    @State private var expanded: Bool = false
    @State private var showingAppPicker: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 14) {
                    autoLaunchBlock
                    Divider()
                    cursorBlock
                }
                .padding(.top, 8)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Advanced Options")
                            .font(.headline)
                        Text(summaryLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
            )
            .spotlightAnchor(SpotlightID.automationPanel)
        }
    }

    /// One-line collapsed summary so the section telegraphs what's on
    /// without making the user expand it.
    private var summaryLine: String {
        var parts: [String] = []
        if !automation.launchAppPath.isEmpty {
            let path = automation.launchAppPath
            let last = (path as NSString).lastPathComponent
            parts.append("launches \(last.isEmpty ? path : last)")
        }
        if automation.confineCursor { parts.append("confine cursor") }
        if automation.autoRecenterCursor { parts.append("auto-recenter") }
        if automation.hideCursorWhileActive { parts.append("hide cursor") }
        if automation.sensitivityMultiplier != 1.0 {
            parts.append(String(format: "sensitivity ×%.2f", automation.sensitivityMultiplier))
        }
        return parts.isEmpty
            ? "Optional extras: auto-launch an app, confine, recenter, or hide the cursor. Expand to set up."
            : parts.joined(separator: " · ")
    }

    // MARK: - Auto launch

    @ViewBuilder
    private var autoLaunchBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "app.dashed")
                    .foregroundStyle(.secondary)
                Text("Auto-launch when preset activates")
                    .font(.subheadline.weight(.semibold))
            }
            HStack {
                TextField("/Applications/Steam.app or com.valvesoftware.steam",
                          text: $automation.launchAppPath)
                    .textFieldStyle(.roundedBorder)
                Button {
                    showingAppPicker = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help("Pick an application")
                if !automation.launchAppPath.isEmpty {
                    Button {
                        automation.launchAppPath = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear")
                }
            }
            TextField("Optional deep link, e.g. steam://run/730",
                      text: $automation.launchURL)
                .textFieldStyle(.roundedBorder)
            Text("Both fields run on activation. Leave blank to disable. Paths accept .app bundles or any executable; identifiers accept reverse-DNS strings.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .fileImporter(isPresented: $showingAppPicker,
                      allowedContentTypes: [UTType.application],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                automation.launchAppPath = url.path
            }
        }
    }

    // MARK: - Cursor controls

    @ViewBuilder
    private var cursorBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "cursorarrow.motionlines")
                    .foregroundStyle(.secondary)
                Text("Cursor while active")
                    .font(.subheadline.weight(.semibold))
            }
            Text("These only run while this preset is the active one. Stopping the engine restores the system cursor.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $automation.confineCursor) {
                Label("Confine cursor away from screen edges",
                      systemImage: "rectangle.inset.filled")
            }
            if automation.confineCursor {
                HStack {
                    Text("Buffer:").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $automation.confineBufferPx, in: 1...200, step: 1)
                    Text("\(Int(automation.confineBufferPx)) px")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                }
            }

            Toggle(isOn: $automation.autoRecenterCursor) {
                Label("Auto-recenter cursor",
                      systemImage: "arrow.triangle.2.circlepath")
            }
            if automation.autoRecenterCursor {
                HStack {
                    Text("Interval:").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $automation.autoRecenterIntervalMs, in: 50...2000, step: 10)
                    Text("\(Int(automation.autoRecenterIntervalMs)) ms")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
                }
            }

            Toggle(isOn: $automation.hideCursorWhileActive) {
                Label("Hide system cursor",
                      systemImage: "cursorarrow.slash")
            }

            HStack {
                Label("Sensitivity multiplier",
                      systemImage: "speedometer")
                Spacer()
                Text(String(format: "×%.2f", automation.sensitivityMultiplier))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $automation.sensitivityMultiplier, in: 0.1...5.0, step: 0.05)
        }
    }
}
