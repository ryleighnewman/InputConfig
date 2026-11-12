import SwiftUI
import AppKit

/// Asks the editor to open the Screen Text sheet, from a screen text row's menu.
struct ShowScreenTextsRequest {
    var bindingID: UUID? = nil
    static let name = Notification.Name("InputConfig.ShowScreenTexts")
    func post() { NotificationCenter.default.post(name: Self.name, object: self) }
}

/// Editor for a preset's screen text watches: an area of a display, the
/// words a row waits for there, and whether the row is held while they show
/// or pressed when they appear. The area is marked from the screen itself,
/// one corner at a time with a three second count, or typed in percent.
/// While the sheet is open every watch shows what the recognizer reads
/// there now and whether the words were found.
struct ScreenTextsView: View {
    @ObservedObject private var svc = ScreenTextService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selectedID: UUID?
    /// Focus lands here after the last watch is deleted, where the Delete
    /// button was; Done is the one control always there.
    @FocusState private var doneFocused: Bool
    /// 0 none; 1 marking the top-left corner; 2 marking the bottom-right.
    @State private var marking = 0
    @State private var countdown = 0
    @State private var permission = ScreenRecordingPermission.hasAccess
    @State private var pendingDeleteID: UUID?

    /// A clicked button keeps the field's edit open, and the sheet went with
    /// the number uncommitted.
    private func finish() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        DispatchQueue.main.async { dismiss() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Screen text")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { finish() }
                    .focused($doneFocused)
                    .keyboardShortcut(.defaultAction)
            }
            Text("A row fires from the words an area of the screen shows: a label that says Ready, a caption, a score, a name in a list. Mark the area, type the words, and the row is held while they show or pressed when they appear.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !permission { ScreenPermissionCard(permission: $permission) }

            HStack(alignment: .top, spacing: 16) {
                list.frame(width: 250)
                Divider()
                if let w = selected {
                    detail(w)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "text.viewfinder")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(svc.watches.isEmpty ? "Add a screen text to begin." : "Select a screen text to edit it.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 340)
        }
        .padding(20)
        .frame(minWidth: 720, idealWidth: 780, minHeight: 500)
        // Escape, whichever control has the keyboard.
        .background {
            Button("") { finish() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        // Said, not only shown by the Found caption.
        .onChange(of: selectedID.flatMap { svc.readings[$0]?.found }) { _, found in
            guard let found else { return }
            AccessibilityNotification.Announcement(found ? String(localized: "Found") : String(localized: "Not found")).post()
        }
        // Arming does not outlive a selection change.
        // Another watch picked during the count: the mark is called off, or
        // it landed on the newly picked watch.
        .onChange(of: selectedID) { _, _ in pendingDeleteID = nil; countdown = 0; marking = 0 }
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

    private var selected: ScreenTextWatch? {
        guard let id = selectedID else { return nil }
        return svc.watch(with: id)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            List(selection: $selectedID) {
                ForEach(svc.watches) { w in
                    HStack(spacing: 8) {
                        Circle().fill(regionPaletteColor(at: w.colorIndex)).frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(w.shownName).lineLimit(1)
                            Text(w.mode == .shows ? "While it shows" : "When it appears")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if svc.readings[w.id]?.found == true {
                            Circle().fill(Color.green).frame(width: 8, height: 8)
                                .accessibilityLabel("Found")
                        }
                    }
                    .tag(w.id)
                }
            }
            .listStyle(.inset)
            HStack {
                Button { addWatch() } label: { Label("Add", systemImage: "plus") }
                    .disabled(svc.watches.count >= ScreenTextWatch.maxWatches)
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

    private func addWatch() {
        var w = ScreenTextWatch()
        if let place = ScreenTextService.pointerPlace() {
            // A small area around the pointer, to be marked properly next.
            w.display = place.display
            w.minX = max(0, place.x - 0.1); w.maxX = min(1, place.x + 0.1)
            w.minY = max(0, place.y - 0.05); w.maxY = min(1, place.y + 0.05)
        }
        w.colorIndex = svc.nextColorIndex
        svc.upsert(w)
        selectedID = w.id
        pendingDeleteID = nil
    }

    private func detail(_ w: ScreenTextWatch) -> some View {
        let reading = svc.readings[w.id]
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name").font(.caption).foregroundStyle(.secondary)
                    TextField("Name", text: Binding(get: { w.name }, set: { var c = w; c.name = $0; svc.upsert(c) }))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Look for").font(.caption).foregroundStyle(.secondary)
                    TextField("Words", text: Binding(get: { w.text }, set: { var c = w; c.text = $0; svc.upsert(c) }))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                    Text("Case, accents and extra spaces are ignored. Part of a longer line counts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Area").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button(marking == 1 && countdown > 0 ? String(localized: "Marking in \(countdown)…") : String(localized: "Mark the top-left corner (3 s)")) { startMarking(1) }
                            .buttonStyle(.solidCompact)
                            .disabled(countdown > 0)
                        Button(marking == 2 && countdown > 0 ? String(localized: "Marking in \(countdown)…") : String(localized: "Mark the bottom-right corner (3 s)")) { startMarking(2) }
                            .buttonStyle(.solidCompact)
                            .disabled(countdown > 0)
                    }
                    HStack(spacing: 10) {
                        percentField("Left", value: w.minX) { v in var c = w; c.minX = min(v, c.maxX - 0.01); svc.upsert(c) }
                        percentField("Top", value: w.minY) { v in var c = w; c.minY = min(v, c.maxY - 0.01); svc.upsert(c) }
                        percentField("Width", value: w.maxX - w.minX) { v in var c = w; c.maxX = min(1, c.minX + max(0.01, v)); svc.upsert(c) }
                        percentField("Height", value: w.maxY - w.minY) { v in var c = w; c.maxY = min(1, c.minY + max(0.01, v)); svc.upsert(c) }
                    }
                    Text("Each Mark counts three seconds while you move the pointer to that corner of the area. Keep the area tight around the words: a smaller area is read faster and more surely.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Right now").font(.caption).foregroundStyle(.secondary)
                    if let reading {
                        Text(reading.text.isEmpty ? String(localized: "No words read in the area") : reading.text)
                            .font(.callout)
                            .lineLimit(3)
                            .foregroundStyle(reading.text.isEmpty ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(reading.found ? "Found" : "Not found")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(reading.found ? Color.green : Color.secondary)
                    } else {
                        Text(permission ? "Reading…" : "Needs Screen Recording")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Fires").font(.caption).foregroundStyle(.secondary)
                    Picker("Fires", selection: Binding(get: { w.mode }, set: { var c = w; c.mode = $0; svc.upsert(c) })) {
                        ForEach(ScreenTextMode.allCases) { m in Text(m.displayName).tag(m) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 420)
                    Text(w.mode == .shows
                         ? "Held, like a button, while the words are read in the area."
                         : "A short press when the words appear in the area after not being there.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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

    private func percentField(_ title: LocalizedStringKey, value: Double, set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            TextField(title, value: Binding(get: { (value * 100).rounded() }, set: { set(min(100, max(0, $0)) / 100) }), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
                .accessibilityLabel(Text(title))
                .accessibilityValue(String(localized: "\(Int((value * 100).rounded())) percent"))
        }
    }

    private func startMarking(_ corner: Int) {
        guard selectedID != nil else { return }
        marking = corner; countdown = 3
        AccessibilityNotification.Announcement(corner == 1
            ? String(localized: "Move the pointer to the top-left corner. Marking in three seconds.")
            : String(localized: "Move the pointer to the bottom-right corner. Marking in three seconds.")).post()
    }

    private func tickCountdown() {
        guard countdown > 0 else { return }
        countdown -= 1
        guard countdown == 0, let id = selectedID, var w = svc.watch(with: id),
              let place = ScreenTextService.pointerPlace() else { marking = 0; return }
        w.display = place.display
        if marking == 1 {
            w.minX = place.x; w.minY = place.y
            if w.maxX <= w.minX { w.maxX = min(1, w.minX + 0.1) }
            if w.maxY <= w.minY { w.maxY = min(1, w.minY + 0.05) }
        } else {
            w.maxX = place.x; w.maxY = place.y
            if w.minX >= w.maxX { w.minX = max(0, w.maxX - 0.1) }
            if w.minY >= w.maxY { w.minY = max(0, w.maxY - 0.05) }
        }
        svc.upsert(w)
        marking = 0
        AccessibilityNotification.Announcement(String(localized: "Marked")).post()
    }
}

/// The Screen Recording card the screen sheets share.
struct ScreenPermissionCard: View {
    @Binding var permission: Bool
    /// Allow was clicked: the grant counts only once the app is opened again.
    @State private var requested = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Screen Recording is not allowed for InputConfig", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout.weight(.medium))
            Text("Reading the screen needs Screen Recording under Privacy & Security. Nothing is recorded or kept: the app reads the marked areas and throws them away.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Allow Screen Recording…") {
                    // A false here means the prompt is up, not a refusal.
                    if ScreenRecordingPermission.request() { permission = true } else { requested = true }
                }
                .buttonStyle(.solidCompact)
                Button("Open System Settings") { ScreenRecordingPermission.openSystemSettings() }
                    .buttonStyle(.solidSecondaryCompact)
            }
            if requested {
                Text("Quit and reopen InputConfig after allowing it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.08)))
    }
}
