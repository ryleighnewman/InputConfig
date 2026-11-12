import SwiftUI
import AppKit
import Combine
import CoreAudio

/// Asks the editor to open the Voice Phrases sheet, from a voice phrase row's menu.
struct ShowVoicePhrasesRequest {
    var bindingID: UUID? = nil
    static let name = Notification.Name("InputConfig.ShowVoicePhrases")
    func post() { NotificationCenter.default.post(name: Self.name, object: self) }
}

/// Editor for a preset's voice phrases: the words a row waits to hear. While
/// the sheet is open the Mac listens, shows what it hears, and lights each
/// phrase as it is said, so a phrase can be tried before it is bound.
struct VoicePhrasesView: View {
    @ObservedObject private var svc = VoicePhraseService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selectedID: UUID?
    @State private var announcedHeard: [UUID: TimeInterval] = [:]
    @FocusState private var doneFocused: Bool
    @State private var allowed = VoicePermission.microphoneAllowed && VoicePermission.speechAllowed
    @State private var pendingDeleteID: UUID?
    @State private var localeID: String = UserDefaults.standard.string(forKey: VoicePhraseService.localeKey) ?? ""
    @State private var now = ProcessInfo.processInfo.systemUptime
    private let clock = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()
    /// The recognizer's languages, sorted once: the list does not change
    /// while the app runs, and the sort is not free.
    @MainActor private static let locales = VoicePhraseService.supportedLocales()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Voice phrases")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .focused($doneFocused)
                    .keyboardShortcut(.defaultAction)
            }
            Text("A row fires each time you say its phrase. The Mac listens only while a preset with voice rows runs or this sheet is open, recognizes speech on this Mac when the language allows it, and keeps nothing.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !allowed { permissionCard }

            HStack(alignment: .top, spacing: 16) {
                list.frame(width: 250)
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    languageRow
                    VoiceMicrophonePicker()
                    listeningRow
                    Divider()
                    if let p = selected {
                        detail(p)
                    } else {
                        Text(svc.phrases.isEmpty ? "Add a voice phrase to begin." : "Select a voice phrase to edit it.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    Spacer()
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
        .onAppear {
            allowed = VoicePermission.microphoneAllowed && VoicePermission.speechAllowed
            svc.beginTracking()
            // Only what is heard from now on is said: a phrase heard before
            // the sheet opened was announced at once.
            announcedHeard = svc.lastHeard
            if selectedID == nil { selectedID = svc.phrases.first?.id }
        }
        .onDisappear { svc.endTracking() }
        .onReceive(clock) { _ in
            now = ProcessInfo.processInfo.systemUptime
            // Said, not only shown as a green dot for a moment.
            for p in svc.phrases {
                if let t = svc.lastHeard[p.id], t > (announcedHeard[p.id] ?? -1) {
                    announcedHeard[p.id] = t
                    if NSWorkspace.shared.isVoiceOverEnabled { FeedbackService.noteSpokenElsewhere(p.shownName) }
                    AccessibilityNotification.Announcement(String(localized: "Heard \(p.shownName)")).post()
                }
            }
        }
        .onChange(of: selectedID) { _, _ in pendingDeleteID = nil }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            let was = allowed
            allowed = VoicePermission.microphoneAllowed && VoicePermission.speechAllowed
            if allowed && !was { svc.restartForLanguage() }
        }
    }

    private var selected: VoicePhrase? {
        guard let id = selectedID else { return nil }
        return svc.phrase(with: id)
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Microphone or Speech Recognition is not allowed for InputConfig", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout.weight(.medium))
            Text("Hearing a phrase needs the Microphone and Speech Recognition permissions under Privacy & Security. Nothing is recorded or kept.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Allow Microphone and Speech…") {
                    VoicePermission.request {
                        allowed = VoicePermission.microphoneAllowed && VoicePermission.speechAllowed
                        if allowed { svc.restartForLanguage() }
                    }
                }
                .buttonStyle(.solidCompact)
                if VoicePermission.microphoneDenied {
                    Button("Open Microphone Settings") { VoicePermission.openMicrophoneSettings() }
                        .buttonStyle(.solidSecondaryCompact)
                }
                if VoicePermission.speechDenied {
                    Button("Open Speech Recognition Settings") { VoicePermission.openSpeechSettings() }
                        .buttonStyle(.solidSecondaryCompact)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.08)))
    }

    private var languageRow: some View {
        HStack(spacing: 8) {
            Text("Language").font(.caption).foregroundStyle(.secondary)
            Picker("Language", selection: $localeID) {
                Text(String(localized: "This Mac's (\(Locale.current.localizedString(forIdentifier: Locale.current.identifier) ?? Locale.current.identifier))")).tag("")
                ForEach(Self.locales, id: \.identifier) { l in
                    Text(Locale.current.localizedString(forIdentifier: l.identifier) ?? l.identifier).tag(l.identifier)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 320)
            .onChange(of: localeID) { _, id in
                VoicePhraseService.setLocale(id.isEmpty ? nil : Locale(identifier: id))
                svc.restartForLanguage()
            }
            if svc.listening {
                Text(svc.onDevice ? "On this Mac" : "Through Apple's servers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var listeningRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(svc.listening ? Color.green : Color.secondary).frame(width: 8, height: 8)
                Text(svc.listening ? "Listening" : "Not listening")
                    .font(.caption.weight(.semibold))
            }
            if let problem = svc.problem {
                Text(problem).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(svc.transcript.isEmpty ? String(localized: "Say something to see it here.") : String(svc.transcript.suffix(140)))
                    .font(.callout)
                    .foregroundStyle(svc.transcript.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            List(selection: $selectedID) {
                ForEach(svc.phrases) { p in
                    HStack(spacing: 8) {
                        Circle().fill(regionPaletteColor(at: p.colorIndex)).frame(width: 10, height: 10)
                        Text(p.shownName).lineLimit(1)
                        Spacer()
                        if let t = svc.lastHeard[p.id], now - t < 1.5 {
                            Circle().fill(Color.green).frame(width: 8, height: 8)
                                .accessibilityLabel("Heard")
                        }
                    }
                    .tag(p.id)
                }
            }
            .listStyle(.inset)
            HStack {
                Button {
                    var p = VoicePhrase()
                    p.colorIndex = svc.nextColorIndex
                    svc.upsert(p)
                    selectedID = p.id
                    pendingDeleteID = nil
                } label: { Label("Add", systemImage: "plus") }
                .disabled(svc.phrases.count >= VoicePhrase.maxPhrases)
                Spacer()
                if let id = selectedID {
                    Button(role: .destructive) {
                        if pendingDeleteID == id {
                            svc.delete(id); pendingDeleteID = nil; selectedID = svc.phrases.first?.id
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

    private func detail(_ p: VoicePhrase) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Phrase").font(.caption).foregroundStyle(.secondary)
                TextField("Words to say", text: Binding(get: { p.phrase }, set: { var c = p; c.phrase = $0; svc.upsert(c) }))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                Text("One or more words, matched as whole words; case and accents are ignored. Two or three words are heard more surely than one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Numbers are heard as digits: type 2, not two.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("Name", text: Binding(get: { p.name }, set: { var c = p; c.name = $0; svc.upsert(c) }))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
            }
            if let t = svc.lastHeard[p.id] {
                Text(String(localized: "Last heard \(Int(now - t)) s ago"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The microphones the Mac has, kept current as they come and go.
@MainActor
final class MicrophoneList: ObservableObject {
    @Published private(set) var devices: [AudioInputDevices.Device] = AudioInputDevices.all()
    @Published private(set) var defaultUID: String? = AudioInputDevices.defaultInputUID()
    private var installed = false

    func watch() {
        refresh()
        guard !installed else { return }
        installed = true
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    private func refresh() {
        devices = AudioInputDevices.all()
        defaultUID = AudioInputDevices.defaultInputUID()
    }
}

/// Which microphone voice phrases listen to: the system default, or one
/// chosen here and kept even while it is unplugged.
struct VoiceMicrophonePicker: View {
    @StateObject private var list = MicrophoneList()
    @AppStorage(VoicePhraseService.microphoneKey) private var uid: String = ""
    @AppStorage(VoicePhraseService.microphoneNameKey) private var savedName: String = ""

    var body: some View {
        HStack(spacing: 8) {
            Text("Microphone").font(.caption).foregroundStyle(.secondary)
                .accessibilityHidden(true)   // the menu says it
            Picker("Microphone", selection: $uid) {
                Text(defaultLabel).tag("")
                ForEach(list.devices) { d in Text(d.name).tag(d.uid) }
                if !uid.isEmpty, !list.devices.contains(where: { $0.uid == uid }) {
                    Text(String(localized: "\(savedName.isEmpty ? uid : savedName) (not connected)")).tag(uid)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 320)
            .onChange(of: uid) { _, new in
                savedName = list.devices.first { $0.uid == new }?.name ?? (new.isEmpty ? "" : savedName)
                VoicePhraseService.shared.microphoneChanged()
            }
        }
        .onAppear { list.watch() }
    }

    private var defaultLabel: String {
        if let d = list.devices.first(where: { $0.uid == list.defaultUID }) {
            return String(localized: "System default (\(d.name))")
        }
        return String(localized: "System default")
    }
}
