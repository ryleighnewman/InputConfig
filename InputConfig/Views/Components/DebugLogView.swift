import SwiftUI

/// The developer log. Lives at the bottom of the main window, always, and
/// can pop out into its own window. The header is a live status strip
/// (engine, controllers, permission, problems) so the panel says something
/// even collapsed; expanded, it lists the activity log with a level and a
/// source per line, filters, and a Save Report button that writes one text
/// file with the machine, the setup, and the log for a bug report.
struct DebugLogView: View {
    /// Whether this view currently owns a pushed resize cursor.
    @State private var resizeCursorPushed = false
    /// True in the pop-out window: no collapse control, fills the window.
    var standalone: Bool = false
    /// True on the home screen. The log starts closed there every time the
    /// home screen appears, so the welcome page keeps its room; it can still
    /// be opened with the chevron.
    var onHome: Bool = false

    @EnvironmentObject var mappingEngine: MappingEngine
    @EnvironmentObject var controllerService: GameControllerService
    @ObservedObject private var log = ActivityLog.shared
    @ObservedObject private var accessibility = AccessibilityPermissionService.shared

    /// Persist the user's expand choice across launches via UserDefaults,
    /// but default the log to collapsed so the welcome / home screen
    /// has full room for the feature grid + Quick Tour. Users who
    /// expand it (typically while editing a preset) keep their choice.
    @AppStorage("InputConfig.debugLogExpanded") private var isExpanded: Bool = false
    @State private var filterText = ""
    @State private var showEventsOnly = false
    @State private var showProblemsOnly = false
    @State private var autoScroll = true
    @State private var logHeight: CGFloat = 180
    @State private var savedFlashUntil: Date?

    private static let controllerColors: [Color] = [.green, .purple, .red, .orange, .cyan, .pink, .yellow, .mint]

    private var expanded: Bool { standalone || isExpanded }

    private var filteredLog: [ActivityLog.Entry] {
        var lines = log.entries
        if showProblemsOnly {
            lines = lines.filter { $0.level >= .warning }
        } else if showEventsOnly {
            lines = lines.filter { $0.level == .event }
        }
        if !filterText.isEmpty {
            lines = lines.filter {
                $0.text.localizedCaseInsensitiveContains(filterText)
                || $0.source.localizedCaseInsensitiveContains(filterText)
            }
        }
        return lines
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            if expanded {
                logContent
                statusBar
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.2))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.secondary.opacity(0.1), lineWidth: 0.5)
        )
        .padding(.horizontal)
        .onAppear { if onHome { isExpanded = false } }
        .onChange(of: onHome) { _, home in
            if home { withAnimation(.easeInOut(duration: 0.2)) { isExpanded = false } }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if !standalone {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "Collapse log" : "Expand log")
                }

                Image(systemName: "terminal.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text("Log")
                    .font(.subheadline)

                statusChips

                Spacer()

                if expanded {
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        TextField("Filter…", text: $filterText)
                            .textFieldStyle(.plain)
                            .font(.caption)
                        if !filterText.isEmpty {
                            Button {
                                filterText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear filter")
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(nsColor: .textBackgroundColor))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
                            )
                    )
                    .frame(maxWidth: 150)

                    Toggle(isOn: $showEventsOnly) {
                        Text("Events").font(.caption2)
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .disabled(showProblemsOnly)
                    .help("Only presses, releases, and taps")

                    Toggle(isOn: $showProblemsOnly) {
                        Text("Problems").font(.caption2)
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Only warnings and errors")

                    Toggle(isOn: $autoScroll) {
                        Text("Follow").font(.caption2)
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Keep the newest line in view")
                }

                if let until = savedFlashUntil, until > Date() {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }

                Button {
                    saveReport()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Save a report: this Mac, the app, what is connected, the settings that matter, and the log, as one text file to send")
                .accessibilityLabel("Save report")

                CopyIconButton(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(reportText(), forType: .string)
                }, helpText: "Copy the report to the clipboard", size: .caption)

                Button {
                    log.clear()
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear log")
                .accessibilityLabel("Clear log")

                if !standalone {
                    Button {
                        ActivityLogWindowController.shared.show(mappingEngine: mappingEngine,
                                                                controllerService: controllerService)
                    } label: {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Open the log in its own window")
                    .accessibilityLabel("Pop out log")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if expanded && !standalone {
                // Resize handle integrated into toolbar bottom edge
                Rectangle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: 3)
                    .frame(maxWidth: 40)
                    .clipShape(Capsule())
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 4)
                    .contentShape(Rectangle().inset(by: -6))
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let newHeight = logHeight - value.translation.height
                                logHeight = min(max(newHeight, 80), 500)
                            }
                    )
                    // Push and pop are balanced by this view's own flag. A
                    // handle that vanishes under the pointer (the log is
                    // collapsed, or opened in its own window) never gets a
                    // hover-out, and the old code then left the resize
                    // arrow stuck on for the whole app.
                    .onHover { hovering in
                        if hovering, !resizeCursorPushed {
                            NSCursor.resizeUpDown.push(); resizeCursorPushed = true
                        } else if !hovering, resizeCursorPushed {
                            NSCursor.pop(); resizeCursorPushed = false
                        }
                    }
                    .onDisappear {
                        if resizeCursorPushed { NSCursor.pop(); resizeCursorPushed = false }
                    }
                    .accessibilityElement()
                    .accessibilityLabel("Resize activity log")
                    .accessibilityValue("\(Int(logHeight)) points tall")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: logHeight = min(logHeight + 40, 500)
                        case .decrement: logHeight = max(logHeight - 40, 80)
                        @unknown default: break
                        }
                    }
            }
        }
    }

    /// Live state at a glance, visible even when the log is collapsed.
    private var statusChips: some View {
        HStack(spacing: 6) {
            if mappingEngine.isRunning {
                chip(icon: "play.fill",
                     text: (mappingEngine.activePreset?.name ?? "Running") + " \u{00B7} \(mappingEngine.currentPollHz) Hz",
                     tint: .green)
            } else {
                chip(icon: "pause.fill", text: "No preset", tint: .secondary)
            }
            let count = controllerService.connectedControllers.count
            chip(icon: "gamecontroller.fill",
                 text: count == 0 ? "No controller" : (count == 1 ? (controllerService.controllerNames[0] ?? "1 controller") : "\(count) controllers"),
                 tint: count == 0 ? .secondary : .blue)
            if !accessibility.isTrusted {
                chip(icon: "exclamationmark.triangle.fill", text: "No Accessibility access", tint: .red)
            }
            if log.errorCount > 0 || log.warningCount > 0 {
                Button {
                    showProblemsOnly = true
                    if !standalone { withAnimation(.easeInOut(duration: 0.2)) { isExpanded = true } }
                } label: {
                    chip(icon: "exclamationmark.circle.fill",
                         text: problemsText,
                         tint: log.errorCount > 0 ? .red : .orange)
                }
                .buttonStyle(.plain)
                .help("Show only warnings and errors")
            }
            if !mappingEngine.activeInputs.isEmpty {
                chip(icon: "bolt.fill", text: "\(mappingEngine.activeInputs.count)", tint: .green)
            }
        }
    }

    private var problemsText: String {
        var parts: [String] = []
        if log.errorCount > 0 { parts.append("\(log.errorCount) error\(log.errorCount == 1 ? "" : "s")") }
        if log.warningCount > 0 { parts.append("\(log.warningCount) warning\(log.warningCount == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }

    private func chip(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 8))
            Text(text)
                .font(.caption2)
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.15)))
    }

    // MARK: - Log Content

    private var logContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if filteredLog.isEmpty {
                        emptyState
                    } else {
                        ForEach(filteredLog) { entry in
                            logLineView(entry)
                                .id(entry.id)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .frame(height: standalone ? nil : logHeight)
            .frame(maxHeight: standalone ? .infinity : nil)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.3))
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5)
            )
            .padding(.horizontal, 8)
            .onChange(of: log.revision) { _, _ in
                if autoScroll, let last = filteredLog.last {
                    // Instant scroll: animating a log tail 5x/sec during active
                    // play was the costly part and reads identically.
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.justify.left")
                .font(.title2)
                .foregroundStyle(.secondary.opacity(0.5))
            Text(log.entries.isEmpty
                 ? "Connect a controller or activate a preset and what happens shows up here"
                 : "No matching log entries")
                .font(.caption)
                .foregroundStyle(.secondary.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// A word for the level, for VoiceOver and for the differentiate-
    /// without-color setting. Color alone was the only severity signal,
    /// on the one surface a person goes to when something is wrong.
    private static func levelName(_ level: ActivityLog.Level) -> String? {
        switch level {
        case .error: return "Error"
        case .warning: return "Warning"
        default: return nil
        }
    }

    private func logLineView(_ entry: ActivityLog.Entry) -> some View {
        let color = lineColor(entry)
        let levelName = Self.levelName(entry.level)
        return HStack(alignment: .top, spacing: 6) {
            // Warnings and errors get a glyph in the dot's place, so the
            // level reads without color.
            if entry.level == .error {
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 9)).foregroundStyle(color).padding(.top, 2)
                    .frame(width: 9)
            } else if entry.level == .warning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9)).foregroundStyle(color).padding(.top, 2)
                    .frame(width: 9)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 5, height: 5)
                    .padding(.top, 5)
                    .frame(width: 9)
            }
            Text(Self.timeFormatter.string(from: entry.time))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.top, 1)
            Text(entry.source)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(color.opacity(0.85))
                .frame(width: 96, alignment: .leading)
                .padding(.top, 1)
            Text(entry.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(entry.level >= .warning ? color : color.opacity(0.9))
                .textSelection(.enabled)
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel([levelName, entry.source, entry.text].compactMap { $0 }.joined(separator: ". "))
    }

    private func lineColor(_ entry: ActivityLog.Entry) -> Color {
        switch entry.level {
        case .error: return .red
        case .warning: return .orange
        case .event:
            if let slot = entry.slot { return Self.controllerColors[slot % Self.controllerColors.count] }
            return entry.text.contains("RELEASE") ? .orange.opacity(0.8) : .green
        case .info:
            switch entry.source {
            case "Engine": return entry.text.contains("started") ? .cyan : (entry.text.contains("stopped") ? .red.opacity(0.8) : .white.opacity(0.55))
            case "Controllers": return .blue.opacity(0.9)
            case "Permissions": return .mint
            case "Light bar": return .pink.opacity(0.8)
            case "Tap the Mac", "Motion": return .teal
            case "Presets": return .cyan.opacity(0.8)
            default: return .white.opacity(0.55)
            }
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text("\(filteredLog.count) entries")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            if showEventsOnly || showProblemsOnly || !filterText.isEmpty {
                Text("(\(log.entries.count) total)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if mappingEngine.isRunning {
                Text("\(mappingEngine.currentPollHz) Hz polling")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Report

    private func reportText() -> String {
        let controllers = controllerService.controllerDetails
            .sorted { $0.key < $1.key }
            .map { (slot: $0.key, info: $0.value) }
        return log.report(controllers: controllers,
                          engineRunning: mappingEngine.isRunning,
                          activePreset: mappingEngine.activePreset?.name,
                          pollHz: mappingEngine.currentPollHz)
    }

    private func saveReport() {
        let panel = NSSavePanel()
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm"
        panel.nameFieldStringValue = "InputConfig Log \(stamp.string(from: Date())).txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.message = "One text file with this Mac, the app, what is connected, and the log."
        let text = reportText()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
            savedFlashUntil = Date().addingTimeInterval(2)
        }
    }
}

/// The pop-out log window. One window, reused; the log inside it is the
/// same view as the panel at the bottom of the main window.
@MainActor
final class ActivityLogWindowController {
    static let shared = ActivityLogWindowController()
    private var window: NSWindow?

    private init() {}

    func show(mappingEngine: MappingEngine, controllerService: GameControllerService) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let root = DebugLogView(standalone: true)
            .environmentObject(mappingEngine)
            .environmentObject(controllerService)
            .padding(.vertical, 10)
            .frame(minWidth: 640, minHeight: 300)
            .windowBackdrop()
            .reduceMotionFriendly()
            .appAccessibility()
        let hosting = NSHostingController(rootView: root)
        let w = NSWindow(contentViewController: hosting)
        w.title = "Activity Log"
        w.setContentSize(NSSize(width: 860, height: 420))
        w.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
