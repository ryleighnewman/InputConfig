import SwiftUI

/// The developer log. Lives at the bottom of the main window, always, and
/// can pop out into its own window. The header is a live status strip
/// (engine, controllers, permission, problems) so the panel says something
/// even collapsed; expanded, it lists the activity log with a level and a
/// source per line, filters, and a Save Report button that writes one text
/// file with the machine, the setup, and the log for a bug report.
struct DebugLogView: View, Equatable {
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

    /// Its two inputs. Everything it shows comes from what it observes (the
    /// log, the engine, the controllers, the permission) and its own state,
    /// which redraw it themselves; its stored settings made every window
    /// body (each preset switch) run it again for nothing.
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.standalone == b.standalone && a.onHome == b.onHome
    }

    /// The entries the filters let through. Cached: computed in the body
    /// on every redraw, the filter ran over the whole log for each of the
    /// list, the count and the scroll, several times a second during play.
    @State private var filteredLog: [ActivityLog.Entry] = []
    /// The newest entry id `filteredLog` has been filtered through, so a
    /// flush filters only what it added (see refiltered). A reference, so
    /// moving it is not a state change.
    @State private var filterCursor = LogFilterCursor()

    private func updateFilteredLog() {
        filteredLog = currentFilteredLog
        filterCursor.throughID = log.entries.last?.id ?? filterCursor.throughID
    }

    /// After a flush: with a filter on, only the new entries are filtered.
    /// It filtered all 2,000 again, about 4 ms per flush during play.
    private func updateFilteredLogAfterFlush() {
        guard filtering else { updateFilteredLog(); return }
        filteredLog = Self.refiltered(filteredLog, through: filterCursor.throughID,
                                      entries: log.entries, keep: passesFilters)
        filterCursor.throughID = log.entries.last?.id ?? filterCursor.throughID
    }

    private var filtering: Bool { showProblemsOnly || showEventsOnly || !filterText.isEmpty }

    private var currentFilteredLog: [ActivityLog.Entry] {
        // Unfiltered, the log itself is shared rather than copied.
        filtering ? log.entries.filter(passesFilters) : log.entries
    }

    /// Whether a line shows under the filters set.
    private func passesFilters(_ e: ActivityLog.Entry) -> Bool {
        if showProblemsOnly {
            if e.level < .warning { return false }
        } else if showEventsOnly {
            if e.level != .event { return false }
        }
        if !filterText.isEmpty {
            return e.text.localizedCaseInsensitiveContains(filterText)
                || e.source.localizedCaseInsensitiveContains(filterText)
        }
        return true
    }

    /// The lines shown after the log changed, from the ones shown before:
    /// lines the log has trimmed or cleared leave from the front, and lines
    /// added after `through` are filtered and appended. Entry ids only grow
    /// and entries never change, so this is the whole log filtered again.
    static func refiltered(_ shown: [ActivityLog.Entry], through: Int, entries: [ActivityLog.Entry],
                           keep: (ActivityLog.Entry) -> Bool) -> [ActivityLog.Entry] {
        let firstID = entries.first?.id ?? Int.max
        var lines = shown
        if let drop = lines.firstIndex(where: { $0.id >= firstID }) {
            lines.removeFirst(drop)
        } else {
            lines.removeAll()
        }
        var start = entries.endIndex
        while start > entries.startIndex, entries[start - 1].id > through { start -= 1 }
        lines.append(contentsOf: entries[start...].filter(keep))
        return lines
    }

    var body: some View {
        #if DEBUG
        let _ = BodyRuns.note("DebugLogView")
        #endif
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            if expanded {
                logContent
                statusBar
            }
        }
        // One named stop for VoiceOver, so the log's start and end are clear.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Activity Log")
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
        .onChange(of: filterText) { _, _ in updateFilteredLog() }
        .onChange(of: showEventsOnly) { _, _ in updateFilteredLog() }
        .onChange(of: showProblemsOnly) { _, _ in updateFilteredLog() }
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
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.forward")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? String(localized: "Collapse log") : String(localized: "Expand log"))
                }

                Image(systemName: "terminal.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text("Log")
                    .font(.subheadline)
                    .accessibilityAddTraits(.isHeader)

                statusChips

                Spacer()

                if expanded {
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass")
                            .font(.caption2)
                            .foregroundStyle(.hint)
                        TextField("Filter…", text: $filterText)
                            .textFieldStyle(.plain)
                            .font(.caption)
                        if !filterText.isEmpty {
                            Button {
                                filterText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.hint)
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
                     text: (mappingEngine.activePreset?.shownName ?? String(localized: "Running")) + ", " + String(localized: "\(mappingEngine.currentPollHz) Hz"),
                     tint: .green)
            } else {
                chip(icon: "pause.fill", text: String(localized: "No preset"), tint: .secondary)
            }
            // Every slot with a device, raw HID and Steam pads included,
            // and the name of the one there is, whichever slot it sits in.
            let slots = controllerService.controllerDetails.keys.sorted()
            let count = slots.count
            chip(icon: "gamecontroller.fill",
                 text: count == 0 ? String(localized: "No controller")
                    : (count == 1 ? (slots.first.flatMap { controllerService.controllerNames[$0] } ?? String(localized: "1 controller"))
                                  : String(localized: "\(count) controllers")),
                 tint: count == 0 ? .secondary : .blue)
            if !accessibility.isTrusted {
                chip(icon: "exclamationmark.triangle.fill", text: String(localized: "No Accessibility access"), tint: .red)
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
                chip(icon: "bolt.fill", text: "\(mappingEngine.activeInputs.count)", tint: .green,
                     spoken: String(localized: "\(mappingEngine.activeInputs.count) inputs active"))
            }
        }
    }

    private var problemsText: String {
        var parts: [String] = []
        if log.errorCount > 0 { parts.append(log.errorCount == 1 ? String(localized: "1 error") : String(localized: "\(log.errorCount) errors")) }
        if log.warningCount > 0 { parts.append(log.warningCount == 1 ? String(localized: "1 warning") : String(localized: "\(log.warningCount) warnings")) }
        return parts.joined(separator: ", ")
    }

    private func chip(icon: String, text: String, tint: Color, spoken: String? = nil) -> some View {
        HStack(spacing: 4) {
            IconView(name: icon, glyphHeight: 10)
                .font(.system(size: 8))
                .accessibilityHidden(true)
            Text(text)
                .font(.caption2)
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.15)))
        // One element, read with what the number counts.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken ?? text)
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
            // Keys scroll back through the log.
            .focusable()
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
            // Opened, popped out or refiltered with Follow on: at the newest
            // line, not the oldest, when nothing new is logged.
            .onAppear {
                updateFilteredLog()
                if autoScroll, let last = filteredLog.last {
                    DispatchQueue.main.async { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: filteredLog.last?.id) { _, last in
                if autoScroll, let last { proxy.scrollTo(last, anchor: .bottom) }
            }
            .onChange(of: log.revision) { _, _ in
                updateFilteredLogAfterFlush()
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
                 ? String(localized: "Connect a controller or activate a preset and what happens shows up here")
                 : String(localized: "No matching log entries"))
                .font(.caption)
                .foregroundStyle(.hint)
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
        case .error: return String(localized: "Error")
        case .warning: return String(localized: "Warning")
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
                .foregroundStyle(.hint)
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
            Text(filteredLog.count == 1 ? String(localized: "1 entry") : String(localized: "\(filteredLog.count) entries"))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            if showEventsOnly || showProblemsOnly || !filterText.isEmpty {
                Text("(\(log.entries.count) total)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.hint)
            }
            Spacer()
            if mappingEngine.isRunning {
                Text("\(mappingEngine.currentPollHz) Hz polling")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.hint)
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
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.calendar = Calendar(identifier: .gregorian)
        stamp.dateFormat = "yyyy-MM-dd HH.mm"
        panel.nameFieldStringValue = "InputConfig Log \(stamp.string(from: Date())).txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.message = String(localized: "One text file with this Mac, the app, what is connected, and the log.")
        let text = reportText()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                savedFlashUntil = Date().addingTimeInterval(2)
                // Cleared on schedule: the badge only went away on a redraw,
                // so it could stay up long after its two seconds.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) { savedFlashUntil = nil }
                AccessibilityNotification.Announcement(String(localized: "Report saved")).post()
            } catch {
                ActivityLog.shared.error("Log", "The report could not be saved: \(error.localizedDescription)")
                AccessibilityNotification.Announcement(String(localized: "The report could not be saved. Choose another folder.")).post()
            }
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
        w.title = String(localized: "Activity Log")
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

/// DebugLogView's place in the log: the newest entry id it has filtered.
final class LogFilterCursor {
    var throughID = 0
}
