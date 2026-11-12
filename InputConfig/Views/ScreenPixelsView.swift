import SwiftUI
import AppKit

/// Asks the editor to open the Screen Colors sheet, from a screen color
/// row's menu.
struct ShowScreenColorsRequest {
    var bindingID: UUID? = nil
    static let name = Notification.Name("InputConfig.ShowScreenColors")
    func post() { NotificationCenter.default.post(name: Self.name, object: self) }
}

/// Editor for a preset's screen color watches: a point on a display, the
/// color a row waits for there, how close is close enough, and whether the
/// row is held while the color shows or pressed when it changes.
///
/// A watch is picked from the screen itself: Pick from the screen counts
/// three seconds while you move the pointer over the spot, then reads the
/// point and its color with this app's own windows left out of the
/// capture (ScreenCapture.image excludes them). While the
/// sheet is open every watch shows the color the screen has there now,
/// and whether it would be pressed, so the tolerance can be set by eye.
struct ScreenPixelsView: View {
    @ObservedObject private var svc = ScreenPixelService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selectedID: UUID?
    @State private var countdown: Int = 0
    /// Change watches that just pressed, held a moment so it can be seen.
    @State private var pulsed: Set<UUID> = []
    /// The watch whose color could not be read off the screen.
    @State private var sampleFailed: UUID?
    @State private var permission = ScreenRecordingPermission.hasAccess
    /// Allow was clicked: the grant counts only once the app is opened again.
    @State private var permissionRequested = false
    @State private var pendingDeleteID: UUID?
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool
    /// Focus lands here after the last watch is deleted.
    @FocusState private var doneFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Screen colors")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .focused($doneFocused)
                    .keyboardShortcut(.defaultAction)
            }
            Text("A row fires from what a spot on the screen shows: a health bar turning red, a light coming on, a bar reaching a mark. Pick the spot and its color from the screen, then choose how close the color has to be.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !permission { permissionCard }

            HStack(alignment: .top, spacing: 16) {
                list
                    .frame(width: 250)
                Divider()
                if let w = selected {
                    detail(w)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "eyedropper.halffull")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(svc.watches.isEmpty ? "Add a screen color to begin." : "Select a screen color to edit it.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 320)
        }
        .padding(20)
        .frame(minWidth: 700, idealWidth: 760, minHeight: 480)
        // Escape, whichever control has the keyboard.
        .background {
            Button("") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        // Said, not only shown by the Pressed caption.
        .onChange(of: selectedID.map { svc.pressed.contains($0) }) { _, pressed in
            guard let pressed else { return }
            AccessibilityNotification.Announcement(pressed ? String(localized: "Pressed") : String(localized: "Not pressed")).post()
        }
        // A Change press is over before anything would draw it again.
        .onChange(of: svc.pulses) { old, new in
            let fired = Set(new.filter { old[$0.key] != $0.value }.keys)
            pulsed.formUnion(fired)
            if let selectedID, fired.contains(selectedID) {
                AccessibilityNotification.Announcement(String(localized: "Pressed")).post()
            }
            Task {
                try? await Task.sleep(for: .seconds(0.5))
                pulsed.subtract(fired)
            }
        }
        // Another watch picked during the count: the pick is called off, or
        // it landed on the newly picked watch.
        .onChange(of: selectedID) { _, _ in pendingDeleteID = nil; countdown = 0; sampleFailed = nil }
        .onAppear {
            permission = ScreenRecordingPermission.hasAccess
            svc.beginTracking()
            if selectedID == nil { selectedID = svc.watches.first?.id }
        }
        .onDisappear { svc.endTracking() }
        // Each second of the count is one sleep; a new count restarts it.
        .task(id: countdown) {
            guard countdown > 0 else { return }
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { tickCountdown() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permission = ScreenRecordingPermission.hasAccess
        }
    }

    private var selected: ScreenPixelWatch? {
        guard let id = selectedID else { return nil }
        return svc.watch(with: id)
    }

    // MARK: - Permission

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Screen Recording is not allowed for InputConfig", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout.weight(.medium))
            Text("Reading a color on the screen needs Screen Recording under Privacy & Security. Nothing is recorded or kept: the app reads a few points and throws them away.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Allow Screen Recording…") {
                    // A false here means the prompt is up, not a refusal.
                    if ScreenRecordingPermission.request() { permission = true } else { permissionRequested = true }
                }
                .buttonStyle(.solidCompact)
                Button("Open System Settings") { ScreenRecordingPermission.openSystemSettings() }
                    .buttonStyle(.solidSecondaryCompact)
            }
            if permissionRequested {
                Text("Quit and reopen InputConfig after allowing it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.08)))
    }

    // MARK: - List

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            List(selection: $selectedID) {
                ForEach(svc.watches) { w in
                    HStack(spacing: 8) {
                        Self.swatch(w.red, w.green, w.blue, size: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(w.shownName).lineLimit(1)
                            Text(w.mode == .match ? "While it shows" : "When it changes")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if showsPressed(w) {
                            Circle().fill(Color.green).frame(width: 8, height: 8)
                                .accessibilityLabel("Pressed")
                        }
                    }
                    .tag(w.id)
                }
            }
            .listStyle(.inset)
            HStack {
                Button {
                    addWatch()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                // Its first reading would raise the system's Screen Recording
                // prompt over the sheet; the sheet asks for it itself.
                .disabled(svc.watches.count >= ScreenPixelWatch.maxWatches || !permission)
                Spacer()
                if let id = selectedID {
                    Button(role: .destructive) {
                        if pendingDeleteID == id {
                            svc.delete(id); pendingDeleteID = nil; selectedID = svc.watches.first?.id
                            doneFocused = true
                        } else {
                            pendingDeleteID = id
                            AccessibilityNotification.Announcement(String(localized: "Press Delete again to remove it")).post()
                        }
                    } label: {
                        Label(pendingDeleteID == id ? "Confirm" : "Delete", systemImage: "trash")
                    }
                }
            }
            .controlSize(.small)
        }
    }

    private func showsPressed(_ w: ScreenPixelWatch) -> Bool {
        w.mode == .change ? pulsed.contains(w.id) : svc.isPressed(w.id)
    }

    private func addWatch() {
        var w = ScreenPixelService.watchUnderPointer() ?? ScreenPixelWatch()
        w.colorIndex = svc.nextColorIndex
        w.name = ""
        svc.upsert(w)
        selectedID = w.id
        pendingDeleteID = nil
        // Its color: what is under the pointer right now.
        sampleInto(w.id)
    }

    // MARK: - Detail

    private func detail(_ w: ScreenPixelWatch) -> some View {
        let live = svc.samples[w.id]
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Name
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name").font(.caption).foregroundStyle(.secondary)
                    TextField("Name", text: Binding(
                        get: { w.name },
                        set: { var c = w; c.name = $0; svc.upsert(c) }))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                }

                // The spot and its color
                VStack(alignment: .leading, spacing: 6) {
                    Text("Spot and color").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Self.swatch(w.red, w.green, w.blue, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(w.hexColor).font(.body.monospaced())
                            Text(placeDescription(w))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    HStack(spacing: 8) {
                        Button(countdown > 0 ? String(localized: "Picking in \(countdown)…") : String(localized: "Pick from the screen (3 s)")) {
                            startCountdown()
                        }
                        .buttonStyle(.solidCompact)
                        .disabled(countdown > 0 || !permission)
                        Button("Use the color there now") { sampleInto(w.id) }
                            .buttonStyle(.solidSecondaryCompact)
                            .disabled(!permission)
                    }
                    Text("Pick from the screen counts three seconds while you move the pointer over the spot, then reads the point and its color.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if sampleFailed == w.id {
                        Text("Could not read the screen there")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                // Live reading
                VStack(alignment: .leading, spacing: 6) {
                    Text("Right now").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        if let live {
                            Self.swatch(live.red, live.green, live.blue, size: 24)
                            let d = w.distance(toRed: live.red, green: live.green, blue: live.blue)
                            Text(String(format: "#%02X%02X%02X", live.red, live.green, live.blue)).font(.callout.monospaced())
                            Text(String(localized: "\(Int((d * 100).rounded()))% away"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(showsPressed(w) ? "Pressed" : "Not pressed")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(showsPressed(w) ? Color.green : Color.secondary)
                        } else {
                            Text(permission ? "Reading…" : "Needs Screen Recording")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }

                // Mode and tolerance
                VStack(alignment: .leading, spacing: 6) {
                    Text("Fires").font(.caption).foregroundStyle(.secondary)
                    Picker("Fires", selection: Binding(
                        get: { w.mode },
                        set: { var c = w; c.mode = $0; svc.upsert(c) })) {
                        ForEach(ScreenPixelMode.allCases) { m in Text(m.displayName).tag(m) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 420)
                    Text(w.mode == .match
                         ? "Held, like a button, while the spot is within the tolerance of the color."
                         : "A short press each time the spot changes by more than the tolerance.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Tolerance").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(String(localized: "\(Int((w.tolerance * 100).rounded()))%"))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { w.tolerance },
                        set: { var c = w; c.tolerance = $0; svc.upsert(c) }), in: 0.01...0.6)
                        .frame(maxWidth: 420)
                        .accessibilityLabel("Tolerance")
                        .accessibilityValue(String(localized: "\(Int((w.tolerance * 100).rounded())) percent"))
                    Text("Low keeps to one exact color; higher lets the same color through at another brightness. 12% suits most indicators.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Display
                if let d = w.display {
                    Text(CursorRegionService.shared.isDisplayAttached(d)
                         ? String(localized: "On \(d.name)")
                         : String(localized: "On \(d.name) (not connected; this watch reads nothing until it is back)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.trailing, 4)
        }
    }

    private func placeDescription(_ w: ScreenPixelWatch) -> String {
        // No points while its display is not connected: it read "( pt)".
        guard let s = ScreenPixelService.screen(for: w) else {
            return String(localized: "\(Int((w.x * 100).rounded()))% across, \(Int((w.y * 100).rounded()))% down")
        }
        let px = "\(Int((w.x * s.frame.width).rounded())), \(Int((w.y * s.frame.height).rounded()))"
        return String(localized: "\(Int((w.x * 100).rounded()))% across, \(Int((w.y * 100).rounded()))% down (\(px) pt)")
    }

    /// A square of one color, shared with the Live Visualizer's list.
    static func swatch(_ r: Int, _ g: Int, _ b: Int, size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: size / 4)
            .fill(Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255))
            .frame(width: size, height: size)
            .overlay(RoundedRectangle(cornerRadius: size / 4).stroke(Color.primary.opacity(0.3), lineWidth: 0.5))
            .accessibilityLabel(String(format: "#%02X%02X%02X", r, g, b))
    }

    // MARK: - Picking

    private func startCountdown() {
        guard selectedID != nil else { return }
        countdown = 3
        AccessibilityNotification.Announcement(String(localized: "Move the pointer over the spot. Picking in three seconds.")).post()
    }

    private func tickCountdown() {
        guard countdown > 0 else { return }
        countdown -= 1
        if countdown == 0, let id = selectedID, let current = svc.watch(with: id) {
            // The pointer's place becomes the spot; the color follows.
            guard var moved = ScreenPixelService.watchUnderPointer() else { return }
            moved.id = current.id; moved.name = current.name; moved.tolerance = current.tolerance
            moved.mode = current.mode; moved.colorIndex = current.colorIndex
            moved.red = current.red; moved.green = current.green; moved.blue = current.blue
            svc.upsert(moved)
            sampleInto(id)
            AccessibilityNotification.Announcement(String(localized: "Picked")).post()
        }
    }

    /// Reads the screen at the watch's spot and makes that its color. A
    /// capture can come back empty while the display list is fetched, so
    /// it is tried once more before saying so.
    private func sampleInto(_ id: UUID, retrying: Bool = true) {
        guard let w = svc.watch(with: id) else { return }
        ScreenPixelService.sampleColor(for: w) { color in
            if let (r, g, b) = color {
                guard var c = svc.watch(with: id) else { return }
                c.red = r; c.green = g; c.blue = b
                svc.upsert(c)
                sampleFailed = nil
            } else if retrying {
                Task {
                    try? await Task.sleep(for: .seconds(0.3))
                    sampleInto(id, retrying: false)
                }
            } else {
                sampleFailed = id
                AccessibilityNotification.Announcement(String(localized: "Could not read the screen there")).post()
            }
        }
    }
}
