import Foundation
import CoreMIDI

/// Sends MIDI messages out of a virtual MIDI source named "InputConfig".
///
/// Any DAW or music app on the Mac that supports external MIDI input (Logic
/// Pro, Ableton Live, GarageBand, MainStage, Bitwig, FL Studio for Mac, etc.)
/// will see "InputConfig" as an available MIDI source. The user connects
/// to it in the DAW's MIDI settings and our controller becomes a MIDI device.
///
/// Implementation notes:
///   - Uses MIDIClientCreate + MIDISourceCreate to expose the virtual port.
///   - No sandbox entitlement is needed for CoreMIDI virtual sources.
///   - Tracks active notes so the engine can release them cleanly when the
///     binding fires note-off.
///   - Pitch bend is sent as a 14-bit value (0 to 16383, centered at 8192).
///   - Variable axes get scaled to the appropriate 0..127 or 0..16383 range
///     by the MappingEngine before it calls into this service.
final class MIDIService: @unchecked Sendable {
    static let shared = MIDIService()

    private let queue = DispatchQueue(label: "com.inputconfig.midi")
    private var client: MIDIClientRef = 0
    private var virtualSource: MIDIEndpointRef = 0
    private var isSetup = false

    /// Active notes per channel keyed by note number. releaseAllNotes() uses
    /// this to silence every tracked note when the engine stops or a preset
    /// deactivates. Per-note sendNoteOff silences only the note it is handed (it
    /// does not consult this set), so a binding that changes its note value
    /// mid-press should rely on releaseAllNotes, not a paired note-off, to
    /// avoid leaving the previous note stuck on.
    private var activeNotes: [Int: Set<Int>] = [:] // channel -> notes
    private let activeNotesLock = NSLock()

    /// Display name of the virtual MIDI port. Apps will see this in their
    /// MIDI source list.
    static let portName = "InputConfig"

    /// Endpoint ref of our own virtual source, or 0 before it exists.
    /// `MIDIInputService` compares sources against this so it never listens
    /// to itself, without matching a real device that happens to share the
    /// "InputConfig" name. Written once during setup, before CoreMIDI can
    /// report the new source to any client.
    nonisolated(unsafe) private(set) static var ownSourceEndpoint: MIDIEndpointRef = 0

    private init() {
        // Pre-allocate the activeNotes dict for every possible MIDI
        // channel so note-on doesn't pay a "create empty Set + insert
        // + write back to dict" round trip on every press. With 16
        // pre-allocated Sets, the hot path becomes a single
        // `insert(note)` on an existing Set reference.
        for ch in 0..<16 {
            activeNotes[ch] = Set<Int>()
        }
        setup()
    }

    /// Whether the virtual MIDI port was created successfully. If false the
    /// rest of the methods become no-ops.
    var isReady: Bool { isSetup }

    // MARK: - Setup

    private func setup() {
        let clientName = "InputConfig" as CFString
        let status = MIDIClientCreateWithBlock(clientName, &client) { _ in
            // CoreMIDI notifications come through here (devices added/removed).
            // We don't need to act on them for outbound-only use.
        }
        guard status == noErr else {
            return
        }

        let portName = Self.portName as CFString
        let srcStatus = MIDISourceCreate(client, portName, &virtualSource)
        guard srcStatus == noErr else {
            return
        }
        Self.ownSourceEndpoint = virtualSource

        // Make the virtual source persist across sessions so DAWs can reconnect
        // automatically. Earlier this derived the id from String.hashValue,
        // which since Swift 4.2 is randomly seeded PER PROCESS, so the id
        // changed every launch and DAWs lost their saved connection; abs() on
        // it could also trap on Int.min. Generate a stable random id once and
        // persist it.
        let uniqueIDKey = "InputConfig.midiSourceUniqueID"
        let uniqueID: Int32
        if let saved = UserDefaults.standard.object(forKey: uniqueIDKey) as? Int {
            uniqueID = Int32(truncatingIfNeeded: saved)
        } else {
            let generated = Int32.random(in: 1...Int32.max)
            UserDefaults.standard.set(Int(generated), forKey: uniqueIDKey)
            uniqueID = generated
        }
        // CoreMIDI refuses an id another endpoint already holds (often
        // another copy of this app still running, or an endpoint that is
        // about to go away). Then a fresh one is used for this session
        // only; the saved id is asked for again on the next launch, and
        // replaced only once it was refused on three launches in a row,
        // so one clash did not cost a DAW its saved connection for good.
        let refusalsKey = "InputConfig.midiSourceUniqueIDRefusals"
        let idStatus = MIDIObjectSetIntegerProperty(virtualSource, kMIDIPropertyUniqueID, uniqueID)
        if idStatus == noErr {
            UserDefaults.standard.removeObject(forKey: refusalsKey)
        } else {
            let refusals = UserDefaults.standard.integer(forKey: refusalsKey) + 1
            UserDefaults.standard.set(refusals, forKey: refusalsKey)
            let retry = Int32.random(in: 1...Int32.max)
            let retryStatus = MIDIObjectSetIntegerProperty(virtualSource, kMIDIPropertyUniqueID, retry)
            let inUse: Int32
            if retryStatus == noErr {
                inUse = retry
                ActivityLog.shared.warning("MIDI", "The saved MIDI source id \(uniqueID) was refused (status \(idStatus)); using \(retry). Apps that saved InputConfig as a source may need to pick it again.")
            } else {
                var assigned: Int32 = 0
                MIDIObjectGetIntegerProperty(virtualSource, kMIDIPropertyUniqueID, &assigned)
                inUse = assigned
                ActivityLog.shared.warning("MIDI", "Could not set the MIDI source id (status \(idStatus), retry \(retryStatus)); CoreMIDI assigned \(assigned). Apps that saved InputConfig as a source may need to pick it again.")
            }
            if refusals >= 3, inUse != 0 {
                UserDefaults.standard.set(Int(inUse), forKey: uniqueIDKey)
                UserDefaults.standard.removeObject(forKey: refusalsKey)
            }
        }

        isSetup = true
    }

    // MARK: - Sending

    /// Who holds each sounding note (channel * 128 + note), by the row
    /// that pressed it, so two rows on one note keep it sounding until the
    /// second lets go, as held keys do. Touched on `queue` only.
    private var noteHolders: [Int: Set<String>] = [:]

    /// Send a Note On. With an owner, a note another owner already holds
    /// is not struck again.
    func sendNoteOn(note: Int, velocity: Int, channel: Int, owner: String? = nil) {
        guard isSetup else { return }
        let bytes = Self.noteOnBytes(note: note, velocity: velocity, channel: channel)
        let safeNote = Int(bytes[1])
        let safeCh = Int(bytes[0] & 0x0F)

        queue.async { [self] in
            if let owner {
                let key = safeCh * 128 + safeNote
                let held = !(noteHolders[key] ?? []).isEmpty
                noteHolders[key, default: []].insert(owner)
                if held { return }
            }
            send(bytes: bytes)
            track(note: safeNote, channel: safeCh, on: true)
            usedChannels.insert(safeCh)
        }
    }

    /// Send a Note Off. With an owner, only once no other owner holds it.
    func sendNoteOff(note: Int, channel: Int, owner: String? = nil) {
        guard isSetup else { return }
        let bytes = Self.noteOffBytes(note: note, channel: channel)
        let safeNote = Int(bytes[1])
        let safeCh = Int(bytes[0] & 0x0F)
        queue.async { [self] in
            let key = safeCh * 128 + safeNote
            if let owner {
                noteHolders[key]?.remove(owner)
                if !(noteHolders[key] ?? []).isEmpty { return }
            }
            noteHolders[key] = nil
            send(bytes: bytes)
            track(note: safeNote, channel: safeCh, on: false)
        }
    }

    /// Channels sent on since the last release. Touched on `queue` only.
    private var usedChannels: Set<Int> = []

    /// Release every note we have tracked as active. Called by MappingEngine
    /// when the engine stops or a preset is deactivated, so we never leave
    /// stuck notes hanging in the DAW.
    /// Let go of the notes these owners hold (a controller that left),
    /// leaving notes another row still holds sounding.
    func releaseNotes(ownerPrefix prefix: String) {
        guard isSetup else { return }
        queue.async { [self] in
            for (key, holders) in noteHolders where holders.contains(where: { $0.hasPrefix(prefix) }) {
                let left = holders.filter { !$0.hasPrefix(prefix) }
                noteHolders[key] = left.isEmpty ? nil : left
                guard left.isEmpty else { continue }
                let bytes = Self.noteOffBytes(note: key % 128, channel: key / 128 + 1)
                send(bytes: bytes)
                track(note: key % 128, channel: key / 128, on: false)
            }
        }
    }

    func releaseAllNotes() {
        guard isSetup else { return }
        // The callers' side of the two dedup caches is dropped in the same
        // step that queues the reset, so it stays in step with the queue's.
        askedLock.lock()
        defer { askedLock.unlock() }
        askedCC.forget()
        askedPitchBend.forget()
        queue.async { [self] in
            noteHolders.removeAll()
            activeNotesLock.lock()
            let snapshot = activeNotes
            // Reset the per-channel sets in place (pre-populated with
            // empty Set<Int> in init) rather than removing keys, so
            // future note-on calls don't have to re-allocate the
            // per-channel storage.
            for ch in activeNotes.keys {
                activeNotes[ch]?.removeAll(keepingCapacity: true)
            }
            activeNotesLock.unlock()

            // Per-note NoteOff for everything we know about.
            for (channel, notes) in snapshot {
                for note in notes {
                    send(bytes: [0x80 | UInt8(channel), UInt8(note), 0])
                }
            }

            // Only on the channels this app sent on since the last reset.
            // The burst went out on all 16 for every stop, edit, pause,
            // lock and disconnect, even for presets that send no MIDI, and
            // cut the notes and sustain of a keyboard played into the same
            // armed track.
            let channels = usedChannels.sorted()
            usedChannels.removeAll()

            // Belt-and-suspenders: also blast CC 123 (All Notes Off)
            // on every channel used. Catches the case where the DAW lost
            // a NoteOn (dropped packet, clock skew) and would
            // otherwise hold a stuck note forever after the engine
            // stops. CC 123 is the standard MIDI panic gesture.
            for channel in channels {
                send(bytes: [0xB0 | UInt8(channel), 123, 0])
            }

            // Also reset continuous controllers and re-center pitch bend, so a
            // CC or pitch-bend binding that was mid-send doesn't leave the DAW
            // with a stuck mod wheel or a detuned pitch after the engine stops.
            for channel in channels {
                send(bytes: [0xB0 | UInt8(channel), 121, 0])     // Reset All Controllers
                send(bytes: [0xE0 | UInt8(channel), 0x00, 0x40]) // Pitch bend center
            }
            // The CC reset above returns the DAW's controllers to default, so
            // drop the dedup caches; the next CC / pitch-bend send must reach
            // the DAW even if its value matches what we last sent before stop.
            lastSentCC.removeAll(keepingCapacity: true)
            lastSentPitchBend.removeAll(keepingCapacity: true)
        }
    }

    /// Last quantized value sent per (channel, controller), used to drop
    /// redundant identical CC packets that a variable axis would otherwise
    /// emit every poll frame. Only touched on `queue`, so it needs no lock.
    private var lastSentCC: [Int: Int] = [:]

    /// Last pitch-bend value sent per channel, to drop redundant identical
    /// pitch-bend packets a held stick would otherwise emit every frame. Only
    /// touched on `queue`.
    private var lastSentPitchBend: [Int: Int] = [:]

    /// The last value per key, and whether a new one differs from it.
    struct LastValues {
        private var last: [Int: Int] = [:]
        /// True, and remembered, when `value` is not the one last given.
        mutating func changes(_ key: Int, to value: Int) -> Bool {
            if last[key] == value { return false }
            last[key] = value
            return true
        }
        mutating func forget() { last.removeAll(keepingCapacity: true) }
    }
    /// The callers' copy of the two caches above, under `askedLock`: a held
    /// axis row asks for the same value every poll, and each ask built its
    /// bytes and queued a block only for the queue to drop it. A value is
    /// noted and its block queued in one locked step (and so is a reset),
    /// so these see the same sends and resets, in the same order, as the
    /// queue's caches do, and drop exactly what the queue would have.
    private var askedCC = LastValues()
    private var askedPitchBend = LastValues()
    private let askedLock = NSLock()

    /// Send a Control Change. `value` is 0-127.
    func sendCC(controller: Int, value: Int, channel: Int) {
        guard isSetup else { return }
        let safeCh = max(0, min(15, channel - 1))
        let safeCC = max(0, min(127, controller))
        let safeVal = max(0, min(127, value))
        askedLock.lock()
        defer { askedLock.unlock() }
        guard askedCC.changes((safeCh << 8) | safeCC, to: safeVal) else { return }
        let bytes = Self.ccBytes(controller: controller, value: value, channel: channel)

        queue.async { [self] in
            // Skip redundant identical CC packets: a variable axis bound to a
            // CC can fire the same 0-127 value every poll frame (up to ~120/s),
            // flooding the DAW. Only send when the value actually changed.
            let key = (safeCh << 8) | safeCC
            if lastSentCC[key] == safeVal { return }
            lastSentCC[key] = safeVal
            send(bytes: bytes)
            usedChannels.insert(safeCh)
        }
    }

    /// Send Pitch Bend. `value` is 0-16383, centered at 8192.
    func sendPitchBend(value: Int, channel: Int) {
        guard isSetup else { return }
        let safeVal = clamp(value, 0, 16383)
        let safeCh = max(0, min(15, channel - 1))
        askedLock.lock()
        defer { askedLock.unlock() }
        guard askedPitchBend.changes(safeCh, to: safeVal) else { return }
        let bytes = Self.pitchBendBytes(value: value, channel: channel)
        queue.async { [self] in
            // Skip redundant identical pitch-bend packets: a held stick would
            // otherwise flood the DAW every poll frame.
            if lastSentPitchBend[safeCh] == safeVal { return }
            lastSentPitchBend[safeCh] = safeVal
            send(bytes: bytes)
            usedChannels.insert(safeCh)
        }
    }

    // MARK: - Message bytes
    // The exact bytes each send puts on the wire, as their own functions so
    // the Test Bench checks what ships instead of a copy.

    static func noteOnBytes(note: Int, velocity: Int, channel: Int) -> [UInt8] {
        // Velocity 0 would be read as a note-off, so it is at least 1.
        [0x90 | UInt8(max(0, min(15, channel - 1))), UInt8(max(0, min(127, note))), UInt8(max(1, min(127, velocity)))]
    }

    static func noteOffBytes(note: Int, channel: Int) -> [UInt8] {
        [0x80 | UInt8(max(0, min(15, channel - 1))), UInt8(max(0, min(127, note))), 0]
    }

    static func ccBytes(controller: Int, value: Int, channel: Int) -> [UInt8] {
        [0xB0 | UInt8(max(0, min(15, channel - 1))), UInt8(max(0, min(127, controller))), UInt8(max(0, min(127, value)))]
    }

    static func pitchBendBytes(value: Int, channel: Int) -> [UInt8] {
        let v = max(0, min(16383, value))
        return [0xE0 | UInt8(max(0, min(15, channel - 1))), UInt8(v & 0x7F), UInt8((v >> 7) & 0x7F)]
    }

    /// Send a Program Change. The receiving instrument switches to the
    /// numbered patch (sound) when this arrives. `program` is 0-127.
    func sendProgramChange(program: Int, channel: Int) {
        guard isSetup else { return }
        let safeProg = clamp(program, 0, 127)
        let safeCh = clamp(channel - 1, 0, 15)
        queue.async { [self] in
            send(bytes: [0xC0 | UInt8(safeCh), UInt8(safeProg)])
        }
    }

    /// Send a real-time transport message. These are single-byte system
    /// messages with no channel - DAWs use them to control playback.
    /// 0xFA = Start, 0xFB = Continue, 0xFC = Stop.
    func sendTransport(_ transport: MIDITransport) {
        guard isSetup else { return }
        queue.async { [self] in
            send(bytes: [transport.statusByte])
        }
    }

    // MARK: - Internal Sending

    private func send(bytes: [UInt8]) {
        #if DEBUG
        if TestCapture.active { TestCapture.note("midi " + bytes.map { String(format: "%02X", $0) }.joined(separator: " ")); return }
        #endif
        guard isSetup else { return }
        var packetList = MIDIPacketList()
        let packet = MIDIPacketListInit(&packetList)
        // Stamped with the host clock: CoreMIDI's headers say a zero
        // timestamp is not "now" for MIDIReceived, so a receiver could
        // schedule the event instead of playing it at once.
        let now = MIDITimeStamp(mach_absolute_time())

        bytes.withUnsafeBufferPointer { buf in
            _ = MIDIPacketListAdd(&packetList,
                                  MemoryLayout<MIDIPacketList>.size,
                                  packet,
                                  now,
                                  bytes.count,
                                  buf.baseAddress!)
        }
        MIDIReceived(virtualSource, &packetList)
    }

    private func track(note: Int, channel: Int, on: Bool) {
        activeNotesLock.lock()
        defer { activeNotesLock.unlock() }
        // `activeNotes` is pre-populated in init for channels 0..15, so
        // the dict subscript always hits an existing key. Mutate the
        // stored Set in place via the subscript-with-default pattern,
        // which avoids the read-copy-write dance the previous version
        // did (allocated a new Set on every note-on).
        if on {
            activeNotes[channel, default: Set<Int>()].insert(note)
        } else {
            activeNotes[channel]?.remove(note)
        }
    }

    private func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
        return min(max(v, lo), hi)
    }

    // MARK: - Helpers

    /// Convert a MIDI note number into a human-readable label like "C4".
    /// MIDI note 60 is middle C in scientific pitch notation (C4).
    static func noteName(_ note: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let safeNote = max(0, min(127, note))
        let octave = (safeNote / 12) - 1
        let name = names[safeNote % 12]
        return "\(name)\(octave)"
    }

    /// Common CC numbers with human-readable names. Used in the binding
    /// editor's CC picker so users can find familiar ones quickly.
    static let commonCCs: [(number: Int, name: String)] = [
        (1, String(localized: "Modulation Wheel")),
        (2, String(localized: "Breath Controller")),
        (4, String(localized: "Foot Controller")),
        (5, String(localized: "Portamento Time")),
        (7, String(localized: "Volume")),
        (8, String(localized: "Balance")),
        (10, String(localized: "Pan")),
        (11, String(localized: "Expression")),
        (64, String(localized: "Sustain Pedal")),
        (65, String(localized: "Portamento On/Off")),
        (66, String(localized: "Sostenuto Pedal")),
        (67, String(localized: "Soft Pedal")),
        (71, String(localized: "Resonance")),
        (74, String(localized: "Cutoff Frequency")),
        (91, String(localized: "Reverb Depth")),
        (93, String(localized: "Chorus Depth")),
        (120, String(localized: "All Sound Off")),
        (123, String(localized: "All Notes Off")),
    ]

    /// Pre-built lookup so picker rendering does not have to do a linear scan
    /// through `commonCCs` for every CC number on every render.
    static let ccNameByNumber: [Int: String] = {
        Dictionary(uniqueKeysWithValues: commonCCs.map { ($0.number, $0.name) })
    }()

    /// Pre-built labels for all 128 CC numbers, used directly by the picker.
    /// Computed once at startup; avoids per-render string concatenation.
    static let ccPickerLabels: [(number: Int, label: String)] = {
        (0...127).map { n in
            if let name = ccNameByNumber[n] {
                return (n, "\(n): \(name)")
            } else {
                return (n, "\(n)")
            }
        }
    }()

    /// Pre-built labels for all 128 MIDI note numbers.
    /// Computed once at startup; avoids per-render note-name calculations.
    static let notePickerLabels: [(number: Int, label: String)] = {
        (0...127).map { n in (n, "\(noteName(n)) (\(n))") }
    }()
}

// MARK: - MIDI Input

/// Reads incoming MIDI from every connected device and publishes it as
/// bindable state, so a MIDI keyboard, pad controller, or knob box can
/// drive keyboard / mouse / macro outputs the same way a gamepad does.
/// This is the mirror image of `MIDIService`, which SENDS MIDI.
///
/// Design notes:
///   - One CoreMIDI client + one input port, connected to every source.
///     Sources that appear or disappear are picked up by a setup-changed
///     notification, so hot-plugging a keyboard just works.
///   - State is polled by MappingEngine, not pushed, matching how every
///     other input source in the app behaves. Notes are held until note
///     off; CC / bend / aftertouch keep their last value.
///   - `@unchecked Sendable` with a single NSLock, following the
///     established pattern for services whose C callbacks fire off the
///     main actor (see DualSenseSupplementService / SteamControllerService).
final class MIDIInputService: @unchecked Sendable {

    static let shared = MIDIInputService()

    /// Identifies one connected MIDI source.
    struct Device: Identifiable, Hashable {
        /// CoreMIDI unique ID, stringified. Stable across replug for most
        /// hardware, which is what makes it usable as a binding filter.
        let id: String
        let name: String
    }

    // MARK: State (lock-guarded)

    private let lock = NSLock()
    private var client: MIDIClientRef = 0
    private var inputPort: MIDIPortRef = 0
    private var isSetup = false

    /// deviceID -> channel(1-16) -> note numbers currently held down.
    private var notesDown: [String: [Int: Set<Int>]] = [:]
    /// deviceID -> channel -> cc number -> last value (0-127).
    private var ccValues: [String: [Int: [Int: Int]]] = [:]
    /// deviceID -> channel -> cc number -> arrival order of the last value.
    /// Queries with a nil channel or device match several streams at once;
    /// the FRESHEST stream must win, not the largest value. Otherwise a
    /// stale high value from a replugged or disconnected device masks the
    /// live knob (max(stale 64, live 40) returned 64 and froze the dial).
    private var ccStamps: [String: [Int: [Int: UInt64]]] = [:]
    /// Monotonic arrival counter backing the freshness stamps.
    private var arrivalCounter: UInt64 = 0
    /// deviceID -> channel -> last pitch bend, normalized -1...1.
    private var pitchBend: [String: [Int: Float]] = [:]
    /// When each pitch bend stream last moved, so an Any channel or Any
    /// device row reads the bend being played, not one left off center.
    private var bendStamps: [String: [Int: UInt64]] = [:]
    /// deviceID -> channel -> last channel aftertouch (0-127).
    private var aftertouch: [String: [Int: Int]] = [:]
    /// deviceID -> channel -> note -> polyphonic key pressure (0-127).
    /// There is no per-note binding kind, so the aftertouch queries fold
    /// this in: an "Aftertouch" binding reads the strongest pressure on the
    /// channel, whether the keyboard sends channel or poly aftertouch.
    /// Entries clear on note off so a released key stops pressing.
    private var polyPressure: [String: [Int: [Int: Int]]] = [:]
    /// deviceID -> System Real-Time transport statuses (0xFA Start, 0xFB
    /// Continue, 0xFC Stop) seen since last consumed. Momentary, like
    /// Program Change. Not bindable yet: that needs a new MIDIInputKind
    /// case handled by MappingEngine and the binding editor.
    private var transportHits: [String: Set<UInt8>] = [:]
    /// Sources the input port is currently connected to, endpoint ref ->
    /// unique ID. Lets a rescan connect only new sources and disconnect
    /// ones that went away, instead of reconnecting everything each time.
    /// Guarded by `scanLock`, not `lock`.
    private var connectedSources: [MIDIEndpointRef: Int32] = [:]
    /// Serializes rescans: CoreMIDI notifications and `start()` can both
    /// trigger one, possibly on different threads.
    private let scanLock = NSLock()
    /// deviceID -> channel -> program numbers seen since the last poll.
    /// Program Change is momentary, so these are consumed by the engine.
    private var programHits: [String: [Int: Set<Int>]] = [:]
    /// Relative ("Turn") mode bookkeeping. For every (device|channel|cc)
    /// stream we remember the previous raw value and accumulate how far
    /// the knob has traveled in each direction since the engine last
    /// consumed a step. Travel is in raw CC units (0-127).
    private var ccLastRaw: [String: Int] = [:]
    /// When each CC stream last sent, for telling a press-only control that
    /// repeats its value apart from a fader streaming its position.
    private var ccLastAt: [String: TimeInterval] = [:]
    /// Each CC stream's value when Scan started, so a knob turned smoothly
    /// one step at a time is caught by its total travel.
    private var scanBaseline: [String: Int] = [:]
    /// A CC 0 (Bank Select) waiting briefly to see whether a Program Change
    /// follows: then it was a program button, and the Program Change scans.
    /// Otherwise it is a control of its own (a nanoKONTROL2's first fader).
    private var pendingBankScan: (key: String, event: InputEvent, token: UInt64)?
    private var pendingBankToken: UInt64 = 0
    /// A press that lasts one poll, kept until a poll has shown it. The
    /// engine calls `beginPoll` once per poll; each call shows one waiting
    /// strike for that poll and leaves the poll after it up, so strikes
    /// reach the rows as separate presses however they fell between polls.
    private struct Strike {
        /// Reads as down for the poll in progress.
        var shown = false
        /// Strikes still to show.
        var pending = 0
        /// Polls to read up before the next strike shows.
        var holdoff = 0
        /// When the last strike arrived; one no poll took in time is dropped.
        var at: TimeInterval = 0
    }
    /// A strike nobody polled for this long is forgotten, not fired late.
    private static let strikeMaxAge: TimeInterval = 1.0
    /// Strikes kept per stream, so a stalled main thread cannot bank a burst.
    private static let strikeCap = 8
    /// Note ons no poll has shown yet. A tap that began and ended between
    /// two polls is still one press, and a note struck again while its row
    /// reads down gets a poll up in between. (A 50 ms clock window did
    /// this before: two fast hits merged, and a tap inside a longer main
    /// thread stall was never seen.)
    private var noteStrikes: [NoteKey: Strike] = [:]
    /// Notes let go since the last poll, which may have read them down.
    private var noteEndedSincePoll: Set<NoteKey> = []
    /// CC messages no poll has shown yet, per stream: what a Trigger row
    /// reads, and a Switch row on a press-only stream.
    private var ccStrikes: [CCStream: Strike] = [:]
    /// CC streams that send the same value on every press and never a
    /// lower one (a foot switch sending CC 64 = 127 each time). A Switch
    /// row read such a stream as held from the first press for good; it
    /// reads it as one press per message. A different value takes the
    /// mark away. Kept between launches, so the first press is a press.
    private var pressOnly: Set<CCStream> = []
    private var pressOnlyLoaded = false
    private static let pressOnlyKey = "InputConfig.midi.pressOnlyStreams"
    private static let pressOnlyCap = 64
    /// Program Change and transport hits shown to the poll in progress:
    /// every row of that poll reads them, whatever its channel or device
    /// filter, and the next poll's start takes them away. (Each read
    /// removed the hit before, so of two rows on one message with
    /// different filters only the first fired.)
    private var programShown: [String: [Int: Set<Int>]] = [:]
    private var transportShown: [String: Set<UInt8>] = [:]
    /// When the last Program Change or transport message arrived.
    private var momentaryAt: TimeInterval = 0
    /// Whether `beginPoll` has anything to do.
    private var momentaryDirty = false
    /// One note stream as a key. A struct, not a joined string: the
    /// engine's 120 Hz poll split every entry's string per row.
    private struct NoteKey: Hashable {
        let deviceID: String
        let channel: Int
        let note: Int
    }
    /// The last CC number and when it came, per device and channel, to tell
    /// the low half of a 14-bit pair (sent right after its high half).
    private var lastCCAt: [String: (cc: Int, at: TimeInterval)] = [:]
    /// Net Turn travel per (device, channel, cc) stream: one signed count,
    /// so a pot wobbling 63, 64, 63 cancels out instead of filling both an
    /// up and a down pool and firing both ways while the knob sits still.
    private var ccNetTravel: [CCStream: Int] = [:]
    /// Where each Turn row has read up to, per stream. Every row sees the
    /// whole rotation and steps at its own size; one shared pool let a Fine
    /// row on the same CC drain what a Chunky row was waiting for.
    private var consumerTravelMark: [TravelMark: Int] = [:]
    /// One CC stream as a key. A "device|channel|cc" string was split
    /// back into its three parts for every stream, by every Turn row, on
    /// every poll, under the lock the CoreMIDI thread takes.
    private struct CCStream: Hashable {
        let deviceID: String
        let channel: Int
        let cc: Int
    }
    /// One Turn row's place in one stream.
    private struct TravelMark: Hashable {
        let consumer: String
        let stream: CCStream
    }
    /// Alternation phase per consumer key, so a fast continuous turn
    /// produces press / release / press pulses across poll frames
    /// instead of one long held press (which the OS would treat as a
    /// single keystroke plus key-repeat).
    private var relativePhase: [String: Bool] = [:]
    /// Default raw CC units of travel per relative step. 4 units means a
    /// full end-to-end sweep of a knob fires about 32 nudges, which
    /// tracks how hardware endless encoders feel. Bindings can override
    /// per row (Turn Step in the knob menu).
    static let defaultRelativeStepUnits = 4
    /// Connected sources, for the UI's device picker.
    private var devices: [Device] = []
    /// Bumped once per recognized incoming message. The Live Visualizer
    /// polls this to know whether anything changed since its last frame,
    /// so its render clock can pause while the MIDI gear sits idle.
    private var eventCounter: UInt64 = 0
    /// deviceID -> the last Program Change and its channel (sticky, for
    /// display - unlike `programHits`, which the engine consumes). One per
    /// device, so the label shows the latest, not an arbitrary channel's.
    private var lastProgram: [String: (channel: Int, program: Int)] = [:]
    /// deviceID -> note -> velocity of the CURRENT press (removed on
    /// release). Drives velocity-shaded keys in the visualizer.
    private var noteVel: [String: [Int: Int]] = [:]
    /// The velocity each note was last struck with, kept after release:
    /// a MIDI Note output set to As played reads it, and a tap shorter
    /// than a poll frame is already released by the time the row fires.
    /// Each note's last strike and when it came (an arrival count), so As
    /// played takes the press that fired the row: the hardest strike ever,
    /// on any channel, was used, which an MPE controller hits on every note.
    private var lastNoteVel: [NoteKey: (vel: Int, stamp: UInt64)] = [:]
    private var noteArrivals: UInt64 = 0
    /// deviceID -> channel -> event stamp of the channel's last message.
    private var channelStamps: [String: [Int: UInt64]] = [:]
    /// Per-device rolling event log for the visualizer (newest first).
    /// Raw values only: the line is worded in `activitySnapshot`, not on
    /// the CoreMIDI thread under `lock`.
    private var recentEvents: [String: [RingEvent]] = [:]
    /// Last CC value the ring logged, per stream, so a knob sweep logs a
    /// handful of lines instead of a hundred.
    private var lastLoggedCC: [String: Int] = [:]

    /// One entry of a device's event ring.
    private enum RingEvent {
        case noteOn(note: Int, velocity: Int, channel: Int)
        case noteOff(note: Int, channel: Int)
        case allNotesOff(channel: Int)
        case cc(number: Int, value: Int, channel: Int)
        case program(number: Int, channel: Int)
        case transport(status: UInt8)

        /// The line the visualizer shows for this entry.
        var text: String {
            switch self {
            case let .noteOn(note, velocity, channel):
                return String(localized: "\(MIDIService.noteName(note)) on, vel \(velocity), ch \(channel)")
            case let .noteOff(note, channel):
                return String(localized: "\(MIDIService.noteName(note)) off, ch \(channel)")
            case let .allNotesOff(channel):
                return String(localized: "All notes off, ch \(channel)")
            case let .cc(number, value, channel):
                return String(localized: "CC \(number) = \(value), ch \(channel)")
            case let .program(number, channel):
                return String(localized: "Program \(number), ch \(channel)")
            case let .transport(status):
                switch status {
                case 0xFA: return String(localized: "Transport start")
                case 0xFB: return String(localized: "Transport continue")
                default:   return String(localized: "Transport stop")
                }
            }
        }
    }

    /// Append one entry to a device's event ring (newest first, capped).
    /// Caller must hold `lock`.
    private func pushEvent(_ deviceID: String, _ event: RingEvent) {
        var ring = recentEvents[deviceID] ?? []
        ring.insert(event, at: 0)
        if ring.count > 8 { ring.removeLast(ring.count - 8) }
        recentEvents[deviceID] = ring
    }

    /// Fired on the main actor for every recognized message while a scan
    /// is active, so the binding editor's Scan button can capture MIDI.
    private var scanHandler: ((InputEvent) -> Void)?

    private init() {}

    // MARK: Lifecycle

    /// Open the client and connect to every current source. Safe to call
    /// repeatedly; later calls just re-scan for new devices.
    /// `forceReconnect`: the Devices menu's Reconnect MIDI Sources and
    /// Rescan Devices. A source whose traffic died while it stayed listed
    /// (a Bluetooth or network session) was skipped as already connected.
    func start(forceReconnect: Bool = false) {
        lock.lock()
        let already = isSetup
        lock.unlock()
        if already { connectAllSources(force: forceReconnect); return }

        var newClient: MIDIClientRef = 0
        let status = MIDIClientCreateWithBlock("InputConfig Input" as CFString, &newClient) { [weak self] notification in
            // Devices came or went, or an endpoint was renamed: re-scan.
            // The notification pointer is only valid inside this block.
            switch notification.pointee.messageID {
            case .msgSetupChanged:
                self?.connectAllSources()
            case .msgPropertyChanged:
                // Only name changes matter (the device picker shows them);
                // other property churn does not need a rescan.
                let property = notification.withMemoryRebound(
                    to: MIDIObjectPropertyChangeNotification.self, capacity: 1
                ) { $0.pointee.propertyName.takeUnretainedValue() }
                if CFEqual(property, kMIDIPropertyName)
                    || CFEqual(property, kMIDIPropertyDisplayName) {
                    self?.connectAllSources()
                }
            default:
                break
            }
        }
        guard status == noErr else {
            NSLog("[MIDIInput] MIDIClientCreate failed: %d", status)
            ActivityLog.shared.error("MIDI", "Could not create the MIDI client (status \(status))")
            return
        }

        var port: MIDIPortRef = 0
        let portStatus = MIDIInputPortCreateWithProtocol(
            newClient, "InputConfig In" as CFString, ._1_0, &port
        ) { [weak self] eventList, srcConnRefCon in
            // srcConnRefCon is the source's CoreMIDI unique ID, packed at
            // connect time, so we know which keyboard sent this without a
            // property lookup per message.
            // Offset by one at connect time: a unique ID of 0 packed as a
            // null pointer and its traffic read as "any".
            let deviceID: String
            if let refCon = srcConnRefCon {
                deviceID = String(Int32(bitPattern: UInt32(truncatingIfNeeded: UInt(bitPattern: refCon) &- 1)))
            } else {
                deviceID = "any"
            }
            self?.handle(eventList, deviceID: deviceID)
        }
        guard portStatus == noErr else {
            NSLog("[MIDIInput] MIDIInputPortCreate failed: %d", portStatus)
            ActivityLog.shared.error("MIDI", "Could not open the MIDI input port (status \(portStatus))")
            MIDIClientDispose(newClient)
            return
        }

        lock.lock()
        client = newClient
        inputPort = port
        isSetup = true
        lock.unlock()

        connectAllSources()
        NSLog("[MIDIInput] started")
        ActivityLog.shared.info("MIDI", "MIDI input open, \(MIDIGetNumberOfSources()) source(s)")
    }

    func stop() {
        lock.lock()
        let c = client, p = inputPort
        client = 0; inputPort = 0; isSetup = false
        notesDown.removeAll(); ccValues.removeAll(); pitchBend.removeAll()
        aftertouch.removeAll(); programHits.removeAll(); devices.removeAll()
        polyPressure.removeAll(); transportHits.removeAll()
        clearStrikesLocked()
        lock.unlock()
        // Disposing the port drops its connections.
        scanLock.lock(); connectedSources.removeAll(); scanLock.unlock()
        if p != 0 { MIDIPortDispose(p) }
        if c != 0 { MIDIClientDispose(c) }
    }

    /// Connect the input port to every MIDI source currently present,
    /// skipping our own virtual output port so the app can't hear itself.
    /// Only sources not already connected are connected, and sources that
    /// disappeared are disconnected, so a rescan never stacks a second
    /// connection on a live source.
    private func connectAllSources(force: Bool = false) {
        scanLock.lock(); defer { scanLock.unlock() }
        lock.lock()
        let port = inputPort
        lock.unlock()
        guard port != 0 else { return }
        if force {
            for (src, _) in connectedSources { MIDIPortDisconnectSource(port, src) }
            connectedSources.removeAll()
            // Reconnect is for a source that went quiet while still listed
            // (a network session dropped, a Bluetooth pad asleep): its held
            // notes and pressure never got their release, so a row stayed
            // held. Everything held is let go; live sources send again.
            lock.lock()
            notesDown.removeAll()
            clearStrikesLocked()
            polyPressure.removeAll()
            aftertouch.removeAll()
            pitchBend.removeAll()
            bendStamps.removeAll()
            // The knobs too: a sustain pedal down when the link dropped
            // kept its row (a Switch on CC 64) held through the reconnect.
            // A row reads nil until the live source sends again; the
            // absolute-volume fader re-arms on its next movement.
            ccValues.removeAll()
            ccStamps.removeAll()
            ccLastRaw.removeAll()
            ccLastAt.removeAll()
            ccNetTravel.removeAll()
            consumerTravelMark.removeAll()
            stateGeneration &+= 1
            lock.unlock()
        }

        let ownSource = MIDIService.ownSourceEndpoint
        var found: [Device] = []
        var present: [MIDIEndpointRef: Int32] = [:]
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            guard src != 0 else { continue }
            // Never connect to our own virtual source, or MIDI we send
            // would loop straight back in as input. Compare the endpoint
            // itself, not its name, so a real device called "InputConfig"
            // still works. Another running copy's virtual source is
            // skipped too: its output is this app's own, from a second
            // process, and fed back it fired the rows bound to it.
            if ownSource != 0 && src == ownSource { continue }
            if Self.isOtherInputConfigSource(src) { continue }
            let name = Self.endpointName(src)

            var uid: Int32 = 0
            MIDIObjectGetIntegerProperty(src, kMIDIPropertyUniqueID, &uid)
            let deviceID = String(uid)
            found.append(Device(id: deviceID, name: name))
            present[src] = uid

            if let connectedUID = connectedSources[src] {
                if connectedUID == uid { continue }
                // Same endpoint, new unique ID: reconnect so the refCon
                // attributes its messages to the new ID.
                MIDIPortDisconnectSource(port, src)
                connectedSources.removeValue(forKey: src)
            }
            // Pass the endpoint's unique ID as the connection refCon so
            // the read block knows which device a packet came from
            // without another property lookup per message.
            // The ID's bit pattern plus one, so a unique ID of 0 is not a
            // null pointer; the read block takes the one off again.
            let refCon = UnsafeMutableRawPointer(bitPattern: UInt(UInt32(bitPattern: uid)) + 1)
            let status = MIDIPortConnectSource(port, src, refCon)
            if status == noErr {
                connectedSources[src] = uid
            } else {
                NSLog("[MIDIInput] MIDIPortConnectSource failed for %@: %d", name, status)
            }
        }
        for (src, _) in connectedSources where present[src] == nil {
            // Usually already gone with its device; harmless if so.
            MIDIPortDisconnectSource(port, src)
            connectedSources.removeValue(forKey: src)
        }

        lock.lock()
        let changed = devices.map(\.id) != found.map(\.id)
        devices = found
        // Next turn: this runs under the lock.
        if changed { DispatchQueue.main.async { NotificationCenter.default.post(name: Self.devicesChangedNotification, object: nil) } }
        // Drop remembered values for devices that are gone, so a
        // disconnected keyboard's last knob positions can never shadow
        // a live device on any-device bindings.
        let liveIDs = Set(found.map(\.id))
        // Every device any table knows. Walking only the CC table missed a
        // keyboard that never sent a CC, so its held notes stayed down (and
        // a Hold row stayed held) after it was unplugged.
        var known = Set(ccValues.keys).union(ccStamps.keys).union(notesDown.keys)
        known.formUnion(pitchBend.keys); known.formUnion(aftertouch.keys)
        known.formUnion(programHits.keys); known.formUnion(polyPressure.keys)
        known.formUnion(transportHits.keys)
        for dead in known where !liveIDs.contains(dead) {
            ccValues.removeValue(forKey: dead)
            ccStamps.removeValue(forKey: dead)
            notesDown.removeValue(forKey: dead)
            pitchBend.removeValue(forKey: dead)
            bendStamps.removeValue(forKey: dead)
            aftertouch.removeValue(forKey: dead)
            programHits.removeValue(forKey: dead)
            polyPressure.removeValue(forKey: dead)
            transportHits.removeValue(forKey: dead)
            // Its Turn baselines too, or a knob moved while it was unplugged
            // fired a burst of steps on the first message after replugging.
            let prefix = dead + "|"
            ccLastRaw = ccLastRaw.filter { !$0.key.hasPrefix(prefix) }
            ccNetTravel = ccNetTravel.filter { $0.key.deviceID != dead }
            consumerTravelMark = consumerTravelMark.filter { $0.key.stream.deviceID != dead }
            ccLastAt = ccLastAt.filter { !$0.key.hasPrefix(prefix) }
            noteStrikes = noteStrikes.filter { $0.key.deviceID != dead }
            noteEndedSincePoll = noteEndedSincePoll.filter { $0.deviceID != dead }
            ccStrikes = ccStrikes.filter { $0.key.deviceID != dead }
            programShown.removeValue(forKey: dead)
            transportShown.removeValue(forKey: dead)
        }
        lock.unlock()
    }

    /// A virtual source another copy of this app made: it has no entity
    /// (a real device's endpoint always does), and its name or driver
    /// owner is this app's. A hardware port named "InputConfig" keeps
    /// its entity and still connects.
    private static func isOtherInputConfigSource(_ endpoint: MIDIEndpointRef) -> Bool {
        var entity: MIDIEntityRef = 0
        if MIDIEndpointGetEntity(endpoint, &entity) == noErr, entity != 0 { return false }
        var cf: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDriverOwner, &cf) == noErr,
           let owner = cf?.takeRetainedValue() as String?, owner == MIDIService.portName {
            return true
        }
        cf = nil
        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &cf) == noErr,
           let name = cf?.takeRetainedValue() as String?, name == MIDIService.portName {
            return true
        }
        return false
    }

    private static func endpointName(_ endpoint: MIDIEndpointRef) -> String {
        var cf: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &cf) == noErr,
           let name = cf?.takeRetainedValue() as String? {
            return name
        }
        return String(localized: "MIDI Device")
    }

    // MARK: Message handling

    private func handle(_ eventList: UnsafePointer<MIDIEventList>, deviceID: String) {
        // Universal MIDI Packet words. The port speaks MIDI 1.0 protocol,
        // so channel voice arrives as message type 0x2 and System Real-Time
        // as 0x1. A packet can hold several messages of different sizes,
        // so walk it message by message: treating every 32-bit word as its
        // own message misreads the later words of SysEx (0x3) and other
        // multi-word messages as channel voice.
        //
        // unsafeSequence walks the list in place. Copying `list.packet`
        // and calling MIDIEventPacketNext on the copy would step past the
        // copy into unrelated stack memory when a list holds more than one
        // packet.
        for packetPtr in eventList.unsafeSequence() {
            let words = Array(packetPtr.words())
            var w = 0
            while w < words.count {
                let size = Self.umpWordCount(messageType: UInt8((words[w] >> 28) & 0xF))
                // A truncated message cannot be decoded; drop the rest.
                guard w + size <= words.count else { break }
                decodeUMP(words[w], deviceID: deviceID)
                w += size
            }
        }
    }

    /// Size in 32-bit words of a UMP message, from its message type
    /// (the top nibble of the first word), per the M2-104-UM Universal
    /// MIDI Packet specification v1.1:
    ///   0x0 utility, 0x1 system, 0x2 MIDI 1.0 channel voice: 1 word
    ///   0x3 7-bit data (SysEx7), 0x4 MIDI 2.0 channel voice: 2 words
    ///   0x5 8-bit data (SysEx8 / mixed data set): 4 words
    ///   0x6, 0x7 reserved: 1 word
    ///   0x8, 0x9, 0xA reserved: 2 words
    ///   0xB, 0xC reserved: 3 words
    ///   0xD flex data, 0xE reserved, 0xF UMP stream: 4 words
    static func umpWordCount(messageType: UInt8) -> Int {
        switch messageType & 0xF {
        case 0x0, 0x1, 0x2, 0x6, 0x7: return 1
        case 0x3, 0x4, 0x8, 0x9, 0xA: return 2
        case 0xB, 0xC:                return 3
        default:                      return 4   // 0x5, 0xD, 0xE, 0xF
        }
    }

    /// Decode the first word of one UMP message. Handles MIDI 1.0 channel
    /// voice (type 0x2) and System Real-Time transport (type 0x1); every
    /// other message type is skipped whole by the caller's walk.
    private func decodeUMP(_ word: UInt32, deviceID: String) {
        let messageType = UInt8((word >> 28) & 0xF)
        switch messageType {
        case 0x1:
            // System common / real-time: status byte in bits 16-23.
            let status = UInt8((word >> 16) & 0xFF)
            if status == 0xFA || status == 0xFB || status == 0xFC {
                applyTransport(status: status, deviceID: deviceID)
            }
        case 0x2:
            let status = UInt8((word >> 20) & 0xF)     // high nibble of status
            let channel = Int((word >> 16) & 0xF) + 1  // 1-16 for humans
            let data1 = Int((word >> 8) & 0x7F)
            let data2 = Int(word & 0x7F)
            applyMessage(status: status, channel: channel,
                         data1: data1, data2: data2, deviceID: deviceID)
        default:
            break
        }
    }

    /// Called on the main queue when MIDI arrives, at most ten times a
    /// second, so a running preset can rest its poll while the gear is
    /// still. Read and written under lock.
    private var activityHandler: (() -> Void)?
    private var lastActivityHop: TimeInterval = 0
    func setActivityHandler(_ handler: (() -> Void)?) {
        lock.lock(); activityHandler = handler; lock.unlock()
    }
    /// Call locked.
    private func noteActivityLocked() {
        guard let handler = activityHandler else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastActivityHop > 0.1 else { return }
        lastActivityHop = now
        DispatchQueue.main.async(execute: handler)
    }

    /// Record a Start / Continue / Stop transport message.
    private func applyTransport(status: UInt8, deviceID: String) {
        lock.lock()
        eventCounter &+= 1
        noteActivityLocked()
        transportHits[deviceID, default: []].insert(status)
        momentaryAt = ProcessInfo.processInfo.systemUptime
        momentaryDirty = true
        pushEvent(deviceID, .transport(status: status))
        let handler = scanHandler
        lock.unlock()
        // Scan picks it up like any other message, so a sequencer's Start
        // button binds in one press.
        if let handler {
            let event = InputEvent.midi(.transport, number: Int(status), deviceID: deviceID)
            DispatchQueue.main.async { handler(event) }
        }
    }

    #if DEBUG
    /// Tests only: one incoming message, as a device sends it (status is the
    /// high nibble: 0x9 note on, 0x8 note off, 0xB CC, 0xE pitch bend...).
    func debugInject(status: UInt8, channel: Int, data1: Int, data2: Int, deviceID: String = "test-device") {
        applyMessage(status: status, channel: channel, data1: data1, data2: data2, deviceID: deviceID)
    }
    #endif

    private func applyMessage(status: UInt8, channel: Int,
                              data1: Int, data2: Int, deviceID: String) {
        var scanEvent: InputEvent?
        /// The press-only marks to store, when this message changed them.
        var pressOnlySave: [String]?

        lock.lock()
        if status == 0x8 || status == 0x9 || status == 0xA || status == 0xB
            || status == 0xC || status == 0xD || status == 0xE {
            eventCounter &+= 1
            noteActivityLocked()
            channelStamps[deviceID, default: [:]][channel] = eventCounter
        }
        switch status {
        case 0x9 where data2 > 0:   // note on with velocity
            let strikeKey = NoteKey(deviceID: deviceID, channel: channel, note: data1)
            var strike = noteStrikes[strikeKey] ?? Strike()
            // A note the last poll may have read down (still held, or let
            // go since that poll) reads up for one poll before this strike.
            if strike.pending == 0, !strike.shown, strike.holdoff == 0,
               noteEndedSincePoll.contains(strikeKey) || notesDown[deviceID]?[channel]?.contains(data1) == true {
                strike.holdoff = 1
            }
            addStrikeLocked(&strike, at: ProcessInfo.processInfo.systemUptime)
            noteStrikes[strikeKey] = strike
            notesDown[deviceID, default: [:]][channel, default: []].insert(data1)
            noteVel[deviceID, default: [:]][data1] = data2
            noteArrivals &+= 1
            lastNoteVel[NoteKey(deviceID: deviceID, channel: channel, note: data1)] = (data2, noteArrivals)
            pushEvent(deviceID, .noteOn(note: data1, velocity: data2, channel: channel))
            scanEvent = .midi(.note, number: data1, channel: channel, deviceID: deviceID)
        case 0x8, 0x9:              // note off (or note on, velocity 0)
            if notesDown[deviceID, default: [:]][channel, default: []].remove(data1) != nil {
                noteEndedSincePoll.insert(NoteKey(deviceID: deviceID, channel: channel, note: data1))
                momentaryDirty = true
            }
            // An MPE controller bends each note on its own channel and does
            // not re-center a channel when its note ends, so a lifted
            // slide held an Any channel bend row on. With bends on more
            // than one channel, a channel whose last note ends is centered.
            // Its stamp goes too, so a bend still held on another channel
            // is the one read. Only a channel that held notes and bent on
            // its own: a split keyboard's wheel on two channels stays.
            if notesDown[deviceID]?[channel]?.isEmpty == true, (pitchBend[deviceID]?.count ?? 0) > 1,
               let bent = pitchBend[deviceID]?[channel], bent != 0,
               let others = pitchBend[deviceID]?.filter({ $0.key != channel }).values,
               !others.allSatisfy({ $0 == bent }) {
                pitchBend[deviceID]?[channel] = 0
                bendStamps[deviceID]?[channel] = 0
            }
            noteVel[deviceID]?.removeValue(forKey: data1)
            polyPressure[deviceID]?[channel]?.removeValue(forKey: data1)
            pushEvent(deviceID, .noteOff(note: data1, channel: channel))
        case 0xB where data1 == 120 || data1 == 123:   // All Sound Off, All Notes Off
            // A panic button or a DAW stopping a clip ends its notes with
            // the channel-mode message instead of a Note Off each; stored as
            // a knob value it left every note row held. Not a knob for Scan.
            for note in notesDown[deviceID]?[channel] ?? [] { noteVel[deviceID]?.removeValue(forKey: note) }
            notesDown[deviceID]?[channel]?.removeAll()
            polyPressure[deviceID]?[channel]?.removeAll()
            if !noteStrikes.isEmpty {
                noteStrikes = noteStrikes.filter { !($0.key.deviceID == deviceID && $0.key.channel == channel) }
            }
            if data1 == 120 { aftertouch[deviceID]?[channel] = 0 }
            pushEvent(deviceID, .allNotesOff(channel: channel))
        case 0xB:                   // control change
            // Relative-mode travel accumulation. Delta against the last
            // raw value for this exact (device, channel, cc) stream; the
            // first message just seeds the baseline.
            let rawKey = "\(deviceID)|\(channel)|\(data1)"
            // A jump larger than a hand turns between two messages (a
            // replug, a bank switch, an encoder wrapping) only re-seeds the
            // baseline instead of firing a burst of steps.
            let previousRaw = ccLastRaw[rawKey]
            if let prev = previousRaw {
                let delta = data2 - prev
                if abs(delta) <= 32 {
                    ccNetTravel[CCStream(deviceID: deviceID, channel: channel, cc: data1), default: 0] += delta
                }
            }
            ccLastRaw[rawKey] = data2
            let ccAt = ProcessInfo.processInfo.systemUptime
            defer { ccLastAt[rawKey] = ccAt }
            // Every message is a strike, for a Trigger row and for a Switch
            // row on a press-only stream.
            let stream = CCStream(deviceID: deviceID, channel: channel, cc: data1)
            addStrikeLocked(&ccStrikes[stream, default: Strike()], at: ccAt)
            loadPressOnlyLocked()
            if let prev = previousRaw, prev != data2 {
                // A lower or higher value: a pedal or a knob after all.
                if pressOnly.remove(stream) != nil { pressOnlySave = pressOnlyListLocked() }
            } else if previousRaw == data2, data2 >= 64, !pressOnly.contains(stream),
                      let last = ccLastAt[rawKey], ccAt - last > 0.3 {
                // The same high value again after a pause, nothing between:
                // a control that sends on the press only. Its Switch row has
                // read down since the first press: one poll up, then this
                // press and every later one as a press of its own.
                pressOnly.insert(stream)
                if pressOnly.count > Self.pressOnlyCap, let extra = pressOnly.first(where: { $0 != stream }) {
                    pressOnly.remove(extra)
                }
                ccStrikes[stream] = Strike(shown: false, pending: 1, holdoff: 1, at: ccAt)
                pressOnlySave = pressOnlyListLocked()
            }
            ccValues[deviceID, default: [:]][channel, default: [:]][data1] = data2
            // Log the sweep sparsely: endpoints always, then every 16 units.
            let logKey = "\(deviceID)|\(channel)|\(data1)"
            if data2 == 0 || data2 == 127
                || abs(data2 - (lastLoggedCC[logKey] ?? -100)) >= 16 {
                lastLoggedCC[logKey] = data2
                pushEvent(deviceID, .cc(number: data1, value: data2, channel: channel))
            }
            arrivalCounter &+= 1
            ccStamps[deviceID, default: [:]][channel, default: [:]][data1] = arrivalCounter
            // Only offer a knob to Scan once it has really moved (3 or more
            // steps, or a first message above 0), so idle controllers
            // streaming zeros and a jittering resting fader don't hijack the
            // capture. Not the low half of a 14-bit pair (CC 32 to 63 whose
            // CC n-32 is in use), and not RPN or NRPN parameter selects and
            // data entry, which every NRPN knob sends.
            // Travel is measured from where the stream sat when Scan began:
            // compared message to message, a smooth turn moved 1 at a time
            // and was never caught.
            let moved: Bool
            var scannedAsRepeat = false
            if scanHandler == nil {
                moved = false
            } else if let base = scanBaseline[rawKey] {
                moved = abs(data2 - base) >= 3
            } else if let base = previousRaw {
                scanBaseline[rawKey] = base
                // The same nonzero value again after a pause: a footswitch
                // that sends 127 on every press, or an encoder sending one
                // step, never moves 3 from its last value and was never
                // caught. A fader streaming its position sends without a pause.
                let paused = ccLastAt[rawKey].map { ProcessInfo.processInfo.systemUptime - $0 > 0.3 } ?? true
                moved = abs(data2 - base) >= 3 || (data2 == base && data2 > 0 && paused)
                // Caught by the repeat alone: Scan binds it as a Trigger.
                scannedAsRepeat = moved && data2 == base
            } else {
                scanBaseline[rawKey] = data2
                moved = data2 > 0
            }
            // A low half comes right after its high half; a CC 32 to 63 on
            // its own (a nanoKONTROL2 S or M button) is a control of its own.
            let pairKey = "\(deviceID)|\(channel)"
            let now = ProcessInfo.processInfo.systemUptime
            let isLSB = (32...63).contains(data1)
                && lastCCAt[pairKey].map { $0.cc == data1 - 32 && now - $0.at < 0.01 } ?? false
            lastCCAt[pairKey] = (data1, now)
            // Bank Select (CC 0) too: a program button sends it before the
            // Program Change it is meant to scan as.
            let isParameterMessage = [6, 38, 96, 97, 98, 99, 100, 101].contains(data1)
            // Bank Select waits for a possible Program Change (see
            // pendingBankScan) instead of scanning at once.
            if data1 == 0, moved, !isLSB, scanHandler != nil {
                pendingBankToken &+= 1
                pendingBankScan = (pairKey, .midi(.cc, number: 0, channel: channel, deviceID: deviceID), pendingBankToken)
                let token = pendingBankToken
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.firePendingBankScan(token: token)
                }
            }
            if moved && !isLSB && !isParameterMessage && data1 != 0 {
                scanEvent = .midi(.cc, number: data1, channel: channel, deviceID: deviceID,
                                  ccMode: scannedAsRepeat ? .trigger : nil)
            }
        case 0xE:                   // pitch bend: 14-bit, center 8192
            let raw = (data2 << 7) | data1
            pitchBend[deviceID, default: [:]][channel] = Float(raw - 8192) / 8192.0
            arrivalCounter &+= 1
            bendStamps[deviceID, default: [:]][channel] = arrivalCounter
            if abs(raw - 8192) > 2048 {
                // The way the wheel was bent, or a bend down bound as up.
                scanEvent = .midi(.pitchBend, number: 0, channel: channel,
                                  direction: raw < 8192 ? .negative : .positive, deviceID: deviceID)
            }
        case 0xD:                   // channel aftertouch
            aftertouch[deviceID, default: [:]][channel] = data1
            // Scan sees a firm lean into the key, not only its note.
            if data1 >= 64 {
                scanEvent = .midi(.aftertouch, number: 0, channel: channel, deviceID: deviceID)
            }
        case 0xA:                   // polyphonic key pressure: note, pressure
            if data2 > 0 {
                polyPressure[deviceID, default: [:]][channel, default: [:]][data1] = data2
                if data2 >= 64 {
                    scanEvent = .midi(.aftertouch, number: 0, channel: channel, deviceID: deviceID)
                }
            } else {
                polyPressure[deviceID]?[channel]?.removeValue(forKey: data1)
            }
        case 0xC:                   // program change
            if pendingBankScan?.key == "\(deviceID)|\(channel)" { pendingBankScan = nil }
            programHits[deviceID, default: [:]][channel, default: []].insert(data1)
            momentaryAt = ProcessInfo.processInfo.systemUptime
            momentaryDirty = true
            lastProgram[deviceID] = (channel, data1)
            pushEvent(deviceID, .program(number: data1, channel: channel))
            scanEvent = .midi(.programChange, number: data1, channel: channel, deviceID: deviceID)
        default:
            break
        }
        let handler = scanHandler
        lock.unlock()
        if let pressOnlySave { UserDefaults.standard.set(pressOnlySave, forKey: Self.pressOnlyKey) }

        if let handler, let scanEvent {
            DispatchQueue.main.async { handler(scanEvent) }
        }
    }

    private func firePendingBankScan(token: UInt64) {
        lock.lock()
        guard let pending = pendingBankScan, pending.token == token, let handler = scanHandler else {
            lock.unlock(); return
        }
        pendingBankScan = nil
        lock.unlock()
        handler(pending.event)
    }

    // MARK: Live Visualizer snapshot

    /// One CC stream's latest value, for the visualizer's knob row.
    struct CCActivity: Identifiable, Hashable {
        let deviceID: String
        let channel: Int
        let cc: Int
        let value: Int
        let stamp: UInt64
        var id: String { "\(deviceID)|\(channel)|\(cc)" }
    }

    /// Everything the visualizer needs about one connected device.
    struct DeviceActivity: Identifiable, Hashable {
        let id: String        // deviceID
        let name: String
        /// Notes currently held, merged across channels (the strip shows
        /// pitch, not channel).
        let notesDown: Set<Int>
        /// Every CC stream seen so far, most recently moved first.
        let ccs: [CCActivity]
        /// Latest pitch bend across channels, -1...1 (nil = never moved).
        let pitchBend: Float?
        /// Latest channel aftertouch 0-127 (nil = never seen).
        let aftertouch: Int?
        /// Last Program Change received (sticky).
        let lastProgram: Int?
        /// Velocity of each currently held note (for key shading).
        let velocities: [Int: Int]
        /// Channel -> stamp of that channel's most recent message.
        let channelStamps: [Int: UInt64]
        /// Rolling event log, newest first.
        let recent: [String]
        /// Total recognized messages this session (all devices share the
        /// counter; shown as session activity).
        let eventCount: UInt64
    }

    /// Copy of the live state for rendering. Cheap: called at most 30 Hz
    /// by one view, and only while MIDI traffic is actually arriving.
    func activitySnapshot() -> [DeviceActivity] {
        lock.lock(); defer { lock.unlock() }
        return devices.map { device in
            let dev = device.id
            var notes: Set<Int> = []
            for (_, held) in notesDown[dev] ?? [:] { notes.formUnion(held) }
            var ccList: [CCActivity] = []
            for (ch, byCC) in ccValues[dev] ?? [:] {
                for (cc, value) in byCC {
                    let stamp = ccStamps[dev]?[ch]?[cc] ?? 0
                    ccList.append(CCActivity(deviceID: dev, channel: ch,
                                             cc: cc, value: value, stamp: stamp))
                }
            }
            ccList.sort { $0.stamp > $1.stamp }
            // The freshest channel's bend, as the engine reads it: an MPE
            // pad bends on several channels, and the first in dictionary
            // order could be one sitting at center.
            let bend = (pitchBend[dev] ?? [:]).max { (bendStamps[dev]?[$0.key] ?? 0) < (bendStamps[dev]?[$1.key] ?? 0) }?.value
            var touch = aftertouch[dev]?.values.max()
            for (_, byNote) in polyPressure[dev] ?? [:] {
                if let poly = byNote.values.max() { touch = max(touch ?? 0, poly) }
            }
            let prog = lastProgram[dev]?.program
            return DeviceActivity(id: dev, name: device.name,
                                  notesDown: notes, ccs: ccList,
                                  pitchBend: bend, aftertouch: touch,
                                  lastProgram: prog,
                                  velocities: noteVel[dev] ?? [:],
                                  channelStamps: channelStamps[dev] ?? [:],
                                  recent: (recentEvents[dev] ?? []).map(\.text),
                                  eventCount: eventCounter)
        }
    }

    /// Posted when the list of MIDI sources changed.
    static let devicesChangedNotification = Notification.Name("InputConfig.MIDIDevicesChanged")

    /// Monotonic count of recognized incoming messages, for idle gating.
    func activityCounter() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return eventCounter &+ stateGeneration
    }

    /// Bumped when held notes and knob values are cleared without a message
    /// (Reconnect, a preset stop), so the panel redraws them let go. Kept
    /// apart from eventCounter, whose total the panel shows as a count.
    private var stateGeneration: UInt64 = 0

    // MARK: Queries used by MappingEngine

    #if DEBUG
    /// Tests only: the bench's note leaves no velocity behind.
    func debugForgetVelocity(deviceID: String) {
        lock.lock(); defer { lock.unlock() }
        lastNoteVel = lastNoteVel.filter { $0.key.deviceID != deviceID }
        noteStrikes = noteStrikes.filter { $0.key.deviceID != deviceID }
    }
    /// Tests only: a Start, Continue or Stop, as a device sends it.
    func debugInjectTransport(status: UInt8, deviceID: String) {
        applyTransport(status: status, deviceID: deviceID)
    }
    /// Tests only: the device's knobs last spoke `seconds` earlier, so a
    /// test need not wait out the pause a repeated press is told by.
    func debugAgePause(deviceID: String, by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        let prefix = deviceID + "|"
        for key in Array(ccLastAt.keys) where key.hasPrefix(prefix) { ccLastAt[key]? -= seconds }
    }
    /// Tests only: the bench's knob leaves no value, travel or Turn row
    /// state behind.
    func debugForgetKnobs(deviceID: String, consumers: [String]) {
        lock.lock(); defer { lock.unlock() }
        let prefix = deviceID + "|"
        ccValues[deviceID] = nil
        ccStamps[deviceID] = nil
        channelStamps[deviceID] = nil
        ccLastRaw = ccLastRaw.filter { !$0.key.hasPrefix(prefix) }
        ccLastAt = ccLastAt.filter { !$0.key.hasPrefix(prefix) }
        lastLoggedCC = lastLoggedCC.filter { !$0.key.hasPrefix(prefix) }
        ccNetTravel = ccNetTravel.filter { $0.key.deviceID != deviceID }
        consumerTravelMark = consumerTravelMark.filter { $0.key.stream.deviceID != deviceID }
        for consumer in consumers { relativePhase[consumer] = nil }
        recentEvents[deviceID] = nil
        scanBaseline = scanBaseline.filter { !$0.key.hasPrefix(prefix) }
        ccStrikes = ccStrikes.filter { $0.key.deviceID != deviceID }
        noteStrikes = noteStrikes.filter { $0.key.deviceID != deviceID }
        notesDown[deviceID] = nil
        programHits[deviceID] = nil; programShown[deviceID] = nil
        transportHits[deviceID] = nil; transportShown[deviceID] = nil
        loadPressOnlyLocked()
        let marked = pressOnly.count
        pressOnly = pressOnly.filter { $0.deviceID != deviceID }
        if pressOnly.count != marked { UserDefaults.standard.set(pressOnlyListLocked(), forKey: Self.pressOnlyKey) }
    }
    /// Tests only: whether the stream is marked press-only.
    func debugIsPressOnly(cc: Int, channel: Int, deviceID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        loadPressOnlyLocked()
        return pressOnly.contains(CCStream(deviceID: deviceID, channel: channel, cc: cc))
    }
    /// Tests only: every waiting strike is made as old as `seconds`.
    func debugAgeStrikes(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        for key in Array(ccStrikes.keys) { ccStrikes[key]?.at -= seconds }
        for key in Array(noteStrikes.keys) { noteStrikes[key]?.at -= seconds }
        momentaryAt -= seconds
    }
    #endif

    // MARK: One-poll presses

    /// Call locked. One more strike on a stream. A strike left by a time
    /// when nothing polled is not kept beside the new one.
    private func addStrikeLocked(_ strike: inout Strike, at now: TimeInterval) {
        if strike.pending > 0, !strike.shown, now - strike.at > Self.strikeMaxAge { strike.pending = 0 }
        strike.pending = min(Self.strikeCap, strike.pending + 1)
        strike.at = now
        momentaryDirty = true
    }

    /// Call locked. Everything a poll has yet to show, and what it shows now.
    private func clearStrikesLocked() {
        noteStrikes.removeAll()
        noteEndedSincePoll.removeAll()
        ccStrikes.removeAll()
        programShown.removeAll()
        transportShown.removeAll()
        momentaryDirty = false
    }

    /// Call locked. The stored press-only marks, read once.
    private func loadPressOnlyLocked() {
        guard !pressOnlyLoaded else { return }
        pressOnlyLoaded = true
        for entry in UserDefaults.standard.stringArray(forKey: Self.pressOnlyKey) ?? [] {
            // "device|channel|cc"; a device id may hold a bar of its own.
            let parts = entry.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count >= 3, let cc = Int(parts[parts.count - 1]), let channel = Int(parts[parts.count - 2]) else { continue }
            let device = parts.dropLast(2).joined(separator: "|")
            pressOnly.insert(CCStream(deviceID: device, channel: channel, cc: cc))
        }
    }

    /// Call locked. The marks as stored.
    private func pressOnlyListLocked() -> [String] {
        pressOnly.map { "\($0.deviceID)|\($0.channel)|\($0.cc)" }.sorted()
    }

    /// The engine's poll begins: the Program Change and transport messages
    /// that arrived since the last poll are shown to this one and no other,
    /// and each stream with a strike waiting shows one. One lock and a flag
    /// when nothing waits.
    func beginPoll() {
        lock.lock(); defer { lock.unlock() }
        guard momentaryDirty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if !programHits.isEmpty || !transportHits.isEmpty, now - momentaryAt > Self.strikeMaxAge {
            programHits.removeAll(); transportHits.removeAll()
        }
        programShown = programHits
        transportShown = transportHits
        if !programHits.isEmpty { programHits.removeAll() }
        if !transportHits.isEmpty { transportHits.removeAll() }
        if !noteEndedSincePoll.isEmpty { noteEndedSincePoll.removeAll(keepingCapacity: true) }
        var live = !programShown.isEmpty || !transportShown.isEmpty
        if !ccStrikes.isEmpty {
            for key in Array(ccStrikes.keys) {
                guard var strike = ccStrikes[key] else { continue }
                if Self.advance(&strike, now: now) { ccStrikes[key] = strike; live = true } else { ccStrikes[key] = nil }
            }
        }
        if !noteStrikes.isEmpty {
            for key in Array(noteStrikes.keys) {
                guard var strike = noteStrikes[key] else { continue }
                if Self.advance(&strike, now: now) { noteStrikes[key] = strike; live = true } else { noteStrikes[key] = nil }
            }
        }
        momentaryDirty = live
    }

    /// One poll's step for a stream; false once nothing is left of it.
    private static func advance(_ strike: inout Strike, now: TimeInterval) -> Bool {
        if strike.shown {
            // The poll after a press reads up, so the next is a new press.
            strike.shown = false
        } else if strike.pending > 0, now - strike.at > strikeMaxAge {
            strike.pending = 0
            strike.holdoff = 0
        } else if strike.holdoff > 0 {
            strike.holdoff -= 1
        } else if strike.pending > 0 {
            strike.pending -= 1
            strike.shown = true
        }
        return strike.shown || strike.pending > 0 || strike.holdoff > 0
    }

    /// A Switch row's reading of a knob: past halfway on the stream that
    /// sent last, as before, except that a press-only stream is down only
    /// for the poll its press is shown to.
    func ccSwitchDown(_ cc: Int, channel: Int?, deviceID: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var best: Int?
        var bestStamp: UInt64 = 0
        var bestMarked = false
        for (dev, byChannel) in ccValues where deviceID == nil || dev == deviceID {
            for (ch, ccs) in byChannel where channel == nil || ch == channel {
                guard let v = ccs[cc] else { continue }
                var marked = false
                if !pressOnly.isEmpty {
                    let stream = CCStream(deviceID: dev, channel: ch, cc: cc)
                    if pressOnly.contains(stream) {
                        if ccStrikes[stream]?.shown == true { return true }
                        marked = true
                    }
                }
                let stamp = ccStamps[dev]?[ch]?[cc] ?? 0
                if best == nil || stamp > bestStamp {
                    best = v
                    bestStamp = stamp
                    bestMarked = marked
                }
            }
        }
        guard let best, !bestMarked else { return false }
        return best >= 64
    }

    /// A Trigger row's reading: down for the one poll a message on a
    /// matching stream is shown to, whatever value it carried.
    func ccTriggerDown(_ cc: Int, channel: Int?, deviceID: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        for (stream, strike) in ccStrikes where strike.shown && stream.cc == cc {
            if let channel, stream.channel != channel { continue }
            if let deviceID, stream.deviceID != deviceID { continue }
            return true
        }
        return false
    }

    /// How hard the note was last struck (1 to 127) on the matching device
    /// and channel, or nil if it has not been played. Of several matches,
    /// the hardest, as a chord's loudest note is what the ear follows.
    func noteVelocity(_ note: Int, channel: Int?, deviceID: String?) -> Int? {
        lock.lock(); defer { lock.unlock() }
        var best: (vel: Int, stamp: UInt64)?
        for (key, entry) in lastNoteVel where key.note == note {
            if let deviceID, key.deviceID != deviceID { continue }
            if let channel, key.channel != channel { continue }
            if entry.stamp >= (best?.stamp ?? 0) { best = entry }
        }
        return best?.vel
    }

    /// True while the given note is held, as the poll in progress sees it.
    /// `channel`/`device` nil = any. A note struck since the last poll is
    /// down for this one even if it has already ended, and a note struck
    /// again while held reads up for one poll first (see `noteStrikes`).
    func isNoteDown(_ note: Int, channel: Int?, deviceID: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if !noteStrikes.isEmpty {
            for (key, strike) in noteStrikes where strike.shown && key.note == note {
                if let deviceID, key.deviceID != deviceID { continue }
                if let channel, key.channel != channel { continue }
                return true
            }
        }
        for (dev, byChannel) in notesDown where deviceID == nil || dev == deviceID {
            for (ch, notes) in byChannel where channel == nil || ch == channel {
                guard notes.contains(note) else { continue }
                if noteStrikes.isEmpty { return true }
                // Held with a strike still waiting: up until it is shown.
                if (noteStrikes[NoteKey(deviceID: dev, channel: ch, note: note)]?.pending ?? 0) == 0 { return true }
            }
        }
        return false
    }

    /// Last CC value 0-127, or nil if that CC has not been seen. When the
    /// binding matches several streams (nil channel or device), the stream
    /// that reported most recently wins - the physical knob the user is
    /// touching right now - never a stale value from another device.
    func ccValue(_ cc: Int, channel: Int?, deviceID: String?) -> Int? {
        lock.lock(); defer { lock.unlock() }
        var best: Int?
        var bestStamp: UInt64 = 0
        for (dev, byChannel) in ccValues where deviceID == nil || dev == deviceID {
            for (ch, ccs) in byChannel where channel == nil || ch == channel {
                guard let v = ccs[cc] else { continue }
                let stamp = ccStamps[dev]?[ch]?[cc] ?? 0
                if best == nil || stamp > bestStamp {
                    best = v
                    bestStamp = stamp
                }
            }
        }
        return best
    }

    /// Last pitch bend, normalized -1...1 (0 = center).
    func pitchBendValue(channel: Int?, deviceID: String?) -> Float {
        lock.lock(); defer { lock.unlock() }
        var out: Float = 0
        var bestStamp: UInt64 = 0
        var first = true
        for (dev, byChannel) in pitchBend where deviceID == nil || dev == deviceID {
            for (ch, v) in byChannel where channel == nil || ch == channel {
                let stamp = bendStamps[dev]?[ch] ?? 0
                if first || stamp > bestStamp {
                    out = v
                    bestStamp = stamp
                    first = false
                }
            }
        }
        return out
    }

    /// Last aftertouch 0-127: the larger of channel aftertouch and the
    /// strongest polyphonic key pressure on a held note.
    func aftertouchValue(channel: Int?, deviceID: String?) -> Int {
        lock.lock(); defer { lock.unlock() }
        var out = 0
        for (dev, byChannel) in aftertouch where deviceID == nil || dev == deviceID {
            for (ch, v) in byChannel where channel == nil || ch == channel {
                out = max(out, v)
            }
        }
        for (dev, byChannel) in polyPressure where deviceID == nil || dev == deviceID {
            for (ch, byNote) in byChannel where channel == nil || ch == channel {
                if let v = byNote.values.max() { out = max(out, v) }
            }
        }
        return out
    }

    /// Whether a transport message (0xFA Start, 0xFB Continue, 0xFC Stop)
    /// arrived before the poll in progress began. Momentary like Program
    /// Change: `beginPoll` shows it to one poll. `device` nil = any.
    func consumeTransport(_ status: UInt8, deviceID: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !transportShown.isEmpty else { return false }
        for (dev, statuses) in transportShown where deviceID == nil || dev == deviceID {
            if statuses.contains(status) { return true }
        }
        return false
    }

    /// One step of relative ("Turn") travel for the given CC, if enough
    /// has accumulated. `up` selects the direction. Consuming alternates
    /// with a forced release frame, so back-to-back steps reach the OS as
    /// distinct key presses rather than one held key. `channel`/`device`
    /// nil matches any stream, matching how the other queries behave.
    func consumeRelativeStep(cc: Int, channel: Int?, deviceID: String?,
                             up: Bool, consumerKey: String,
                             stepUnits: Int = MIDIInputService.defaultRelativeStepUnits) -> Bool {
        let step = max(1, stepUnits)
        lock.lock(); defer { lock.unlock() }

        // Release frame after every press frame.
        if relativePhase[consumerKey] == true {
            relativePhase[consumerKey] = false
            return false
        }

        for (stream, net) in ccNetTravel {
            guard stream.cc == cc else { continue }
            if let channel, stream.channel != channel { continue }
            if let deviceID, stream.deviceID != deviceID { continue }

            let markKey = TravelMark(consumer: consumerKey, stream: stream)
            // A row seeing a stream for the first time starts from now.
            let mark = consumerTravelMark[markKey] ?? net
            let ahead = net - mark
            if up ? ahead >= step : ahead <= -step {
                consumerTravelMark[markKey] = mark + (up ? step : -step)
                relativePhase[consumerKey] = true
                return true
            }
            // Turned the other way: catch up, so coming back does not first
            // have to undo that travel.
            consumerTravelMark[markKey] = (up ? ahead < 0 : ahead > 0) ? net : mark
        }
        return false
    }

    /// Whether the given program change arrived before the poll in progress
    /// began. Program Change is momentary: `beginPoll` shows it to one poll,
    /// and every row of that poll reads it, whatever its filters.
    func consumeProgramChange(_ program: Int, channel: Int?, deviceID: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !programShown.isEmpty else { return false }
        for (dev, byChannel) in programShown where deviceID == nil || dev == deviceID {
            for (ch, programs) in byChannel where channel == nil || ch == channel {
                if programs.contains(program) { return true }
            }
        }
        return false
    }

    /// Every MIDI source currently connected, for the editor's picker.
    func connectedDevices() -> [Device] {
        lock.lock(); defer { lock.unlock() }
        return devices
    }

    #if DEBUG
    /// Marketing capture only: toggle a pretend keyboard that reports a held
    /// C major chord, a few knob positions, and a little pitch bend, so the
    /// MIDI visualizer can be photographed in use with no hardware attached.
    func debugToggleFakeInstrument() {
        lock.lock(); defer { lock.unlock() }
        let dev = "fake.keyboard"
        if let i = devices.firstIndex(where: { $0.id == dev }) {
            devices.remove(at: i)
            notesDown[dev] = nil; noteVel[dev] = nil; ccValues[dev] = nil; ccStamps[dev] = nil
            pitchBend[dev] = nil; channelStamps[dev] = nil
            eventCounter += 1
            return
        }
        devices.append(Device(id: dev, name: "KeyLab 49"))
        notesDown[dev] = [1: [60, 64, 67]]
        noteVel[dev] = [60: 96, 64: 84, 67: 112]
        ccValues[dev] = [1: [1: 84, 7: 100, 64: 127, 71: 40]]
        var stamps: [Int: UInt64] = [:]
        for (k, cc) in [1, 7, 64, 71].enumerated() { stamps[cc] = eventCounter + UInt64(k + 1) }
        ccStamps[dev] = [1: stamps]
        pitchBend[dev] = [1: 0.3]
        eventCounter += 8
        channelStamps[dev] = [1: eventCounter]
    }
    #endif

    /// True when at least one MIDI source (other than our own output
    /// port) is connected. Drives the editor's "no MIDI device" hint.
    var hasDevices: Bool {
        lock.lock(); defer { lock.unlock() }
        return !devices.isEmpty
    }

    // MARK: Scanning

    func startScanning(_ handler: @escaping (InputEvent) -> Void) {
        start()
        lock.lock(); scanHandler = handler; scanBaseline.removeAll(); lock.unlock()
    }

    func stopScanning() {
        lock.lock()
        scanHandler = nil
        scanBaseline.removeAll()
        // A Bank Select heard by this scan does not reach the next one.
        pendingBankScan = nil
        // A scanned Program Change, Start or pedal press is not left
        // queued for a row.
        programHits.removeAll()
        transportHits.removeAll()
        clearStrikesLocked()
        lock.unlock()
    }

    /// Forget Program Change and Transport hits nobody read. Called when a
    /// preset starts: a Start or Stop heard with nothing running fired its
    /// row the moment a preset was turned on.
    func clearMomentaryHits() {
        lock.lock()
        programHits.removeAll()
        transportHits.removeAll()
        clearStrikesLocked()
        lock.unlock()
    }

    /// Release all held state. Called when the engine stops so a note
    /// held at that moment can't leave a binding stuck on.
    func releaseAll() {
        lock.lock()
        notesDown.removeAll()
        programHits.removeAll()
        polyPressure.removeAll()
        transportHits.removeAll()
        ccNetTravel.removeAll()
        consumerTravelMark.removeAll()
        relativePhase.removeAll()
        clearStrikesLocked()
        stateGeneration &+= 1
        lock.unlock()
    }
}
