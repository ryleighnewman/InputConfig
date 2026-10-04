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
    nonisolated(unsafe) static let shared = MIDIService()

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
        MIDIObjectSetIntegerProperty(virtualSource, kMIDIPropertyUniqueID, uniqueID)

        isSetup = true
    }

    // MARK: - Sending

    /// Send a Note On.
    func sendNoteOn(note: Int, velocity: Int, channel: Int) {
        guard isSetup else { return }
        let bytes = Self.noteOnBytes(note: note, velocity: velocity, channel: channel)
        let safeNote = Int(bytes[1])
        let safeCh = Int(bytes[0] & 0x0F)

        queue.async { [self] in
            send(bytes: bytes)
            track(note: safeNote, channel: safeCh, on: true)
            usedChannels.insert(safeCh)
        }
    }

    /// Send a Note Off.
    func sendNoteOff(note: Int, channel: Int) {
        guard isSetup else { return }
        let bytes = Self.noteOffBytes(note: note, channel: channel)
        let safeNote = Int(bytes[1])
        let safeCh = Int(bytes[0] & 0x0F)
        queue.async { [self] in
            send(bytes: bytes)
            track(note: safeNote, channel: safeCh, on: false)
        }
    }

    /// Channels sent on since the last release. Touched on `queue` only.
    private var usedChannels: Set<Int> = []

    /// Release every note we have tracked as active. Called by MappingEngine
    /// when the engine stops or a preset is deactivated, so we never leave
    /// stuck notes hanging in the DAW.
    func releaseAllNotes() {
        guard isSetup else { return }
        queue.async { [self] in
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

    /// Send a Control Change. `value` is 0-127.
    func sendCC(controller: Int, value: Int, channel: Int) {
        guard isSetup else { return }
        let bytes = Self.ccBytes(controller: controller, value: value, channel: channel)
        let safeCh = Int(bytes[0] & 0x0F)
        let safeCC = Int(bytes[1])
        let safeVal = Int(bytes[2])

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
        let bytes = Self.pitchBendBytes(value: value, channel: channel)
        let safeVal = clamp(value, 0, 16383)
        let safeCh = Int(bytes[0] & 0x0F)
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

    /// Send a single MIDI Timing Clock tick (0xF8). Twenty-four of these per
    /// quarter note are required to sync hardware sequencers and similar.
    /// Most users will not call this directly; included for completeness so
    /// future features can drive clock from a configurable rate.
    func sendClockTick() {
        guard isSetup else { return }
        queue.async { [self] in
            send(bytes: [0xF8])
        }
    }

    // MARK: - Internal Sending

    private func send(bytes: [UInt8]) {
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
        (1, "Modulation Wheel"),
        (2, "Breath Controller"),
        (4, "Foot Controller"),
        (5, "Portamento Time"),
        (7, "Volume"),
        (8, "Balance"),
        (10, "Pan"),
        (11, "Expression"),
        (64, "Sustain Pedal"),
        (65, "Portamento On/Off"),
        (66, "Sostenuto Pedal"),
        (67, "Soft Pedal"),
        (71, "Resonance"),
        (74, "Cutoff Frequency"),
        (91, "Reverb Depth"),
        (93, "Chorus Depth"),
        (120, "All Sound Off"),
        (123, "All Notes Off"),
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

    nonisolated(unsafe) static let shared = MIDIInputService()

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
    /// Each CC stream's value when Scan started, so a knob turned smoothly
    /// one step at a time is caught by its total travel.
    private var scanBaseline: [String: Int] = [:]
    /// A CC 0 (Bank Select) waiting briefly to see whether a Program Change
    /// follows: then it was a program button, and the Program Change scans.
    /// Otherwise it is a control of its own (a nanoKONTROL2's first fader).
    private var pendingBankScan: (key: String, event: InputEvent, token: UInt64)?
    private var pendingBankToken: UInt64 = 0
    /// When each note last went down, so a tap whose Note Off came before
    /// the next poll still reads as pressed for one frame.
    private var noteOnAt: [String: TimeInterval] = [:]
    /// The last CC number and when it came, per device and channel, to tell
    /// the low half of a 14-bit pair (sent right after its high half).
    private var lastCCAt: [String: (cc: Int, at: TimeInterval)] = [:]
    /// Net Turn travel per (device, channel, cc) stream: one signed count,
    /// so a pot wobbling 63, 64, 63 cancels out instead of filling both an
    /// up and a down pool and firing both ways while the knob sits still.
    private var ccNetTravel: [String: Int] = [:]
    /// Where each Turn row has read up to, per stream. Every row sees the
    /// whole rotation and steps at its own size; one shared pool let a Fine
    /// row on the same CC drain what a Chunky row was waiting for.
    private var consumerTravelMark: [String: Int] = [:]
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
    /// deviceID -> channel -> last Program Change (sticky, for display -
    /// unlike `programHits`, which the engine consumes).
    private var lastProgram: [String: [Int: Int]] = [:]
    /// deviceID -> note -> velocity of the CURRENT press (removed on
    /// release). Drives velocity-shaded keys in the visualizer.
    private var noteVel: [String: [Int: Int]] = [:]
    /// deviceID -> channel -> event stamp of the channel's last message.
    private var channelStamps: [String: [Int: UInt64]] = [:]
    /// Per-device rolling event log for the visualizer (newest first).
    private var recentEvents: [String: [String]] = [:]
    /// Last CC value the ring logged, per stream, so a knob sweep logs a
    /// handful of lines instead of a hundred.
    private var lastLoggedCC: [String: Int] = [:]

    /// Append one line to a device's event ring (newest first, capped).
    /// Caller must hold `lock`.
    private func pushEvent(_ deviceID: String, _ text: String) {
        var ring = recentEvents[deviceID] ?? []
        ring.insert(text, at: 0)
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
            let deviceID: String
            if let refCon = srcConnRefCon {
                deviceID = String(Int32(truncatingIfNeeded: Int(bitPattern: refCon)))
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
            // still works.
            if ownSource != 0 && src == ownSource { continue }
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
            let refCon = UnsafeMutableRawPointer(bitPattern: UInt(bitPattern: Int(uid)))
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
        devices = found
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
            aftertouch.removeValue(forKey: dead)
            programHits.removeValue(forKey: dead)
            polyPressure.removeValue(forKey: dead)
            transportHits.removeValue(forKey: dead)
            // Its Turn baselines too, or a knob moved while it was unplugged
            // fired a burst of steps on the first message after replugging.
            let prefix = dead + "|"
            ccLastRaw = ccLastRaw.filter { !$0.key.hasPrefix(prefix) }
            ccNetTravel = ccNetTravel.filter { !$0.key.hasPrefix(prefix) }
            consumerTravelMark = consumerTravelMark.filter { !$0.key.contains("|" + prefix) }
        }
        lock.unlock()
    }

    private static func endpointName(_ endpoint: MIDIEndpointRef) -> String {
        var cf: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &cf) == noErr,
           let name = cf?.takeRetainedValue() as String? {
            return name
        }
        return "MIDI Device"
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
        let label: String
        switch status {
        case 0xFA: label = "Transport start"
        case 0xFB: label = "Transport continue"
        default:   label = "Transport stop"
        }
        pushEvent(deviceID, label)
        let handler = scanHandler
        lock.unlock()
        // Scan picks it up like any other message, so a sequencer's Start
        // button binds in one press.
        if let handler {
            let event = InputEvent.midi(.transport, number: Int(status), deviceID: deviceID)
            DispatchQueue.main.async { handler(event) }
        }
    }

    private func applyMessage(status: UInt8, channel: Int,
                              data1: Int, data2: Int, deviceID: String) {
        var scanEvent: InputEvent?

        lock.lock()
        if status == 0x8 || status == 0x9 || status == 0xA || status == 0xB
            || status == 0xC || status == 0xD || status == 0xE {
            eventCounter &+= 1
            noteActivityLocked()
            channelStamps[deviceID, default: [:]][channel] = eventCounter
        }
        switch status {
        case 0x9 where data2 > 0:   // note on with velocity
            notesDown[deviceID, default: [:]][channel, default: []].insert(data1)
            let onAt = ProcessInfo.processInfo.systemUptime
            noteOnAt["\(deviceID)|\(channel)|\(data1)"] = onAt
            if noteOnAt.count > 256 { noteOnAt = noteOnAt.filter { onAt - $0.value < 1 } }
            noteVel[deviceID, default: [:]][data1] = data2
            pushEvent(deviceID, "\(MIDIService.noteName(data1)) on · vel \(data2) · ch \(channel)")
            scanEvent = .midi(.note, number: data1, channel: channel, deviceID: deviceID)
        case 0x8, 0x9:              // note off (or note on, velocity 0)
            notesDown[deviceID, default: [:]][channel, default: []].remove(data1)
            noteVel[deviceID]?.removeValue(forKey: data1)
            polyPressure[deviceID]?[channel]?.removeValue(forKey: data1)
            pushEvent(deviceID, "\(MIDIService.noteName(data1)) off · ch \(channel)")
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
                if abs(delta) <= 32 { ccNetTravel[rawKey, default: 0] += delta }
            }
            ccLastRaw[rawKey] = data2
            ccValues[deviceID, default: [:]][channel, default: [:]][data1] = data2
            // Log the sweep sparsely: endpoints always, then every 16 units.
            let logKey = "\(deviceID)|\(channel)|\(data1)"
            if data2 == 0 || data2 == 127
                || abs(data2 - (lastLoggedCC[logKey] ?? -100)) >= 16 {
                lastLoggedCC[logKey] = data2
                pushEvent(deviceID, "CC \(data1) = \(data2) · ch \(channel)")
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
            if scanHandler == nil {
                moved = false
            } else if let base = scanBaseline[rawKey] ?? previousRaw {
                scanBaseline[rawKey] = base
                moved = abs(data2 - base) >= 3
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
                scanEvent = .midi(.cc, number: data1, channel: channel, deviceID: deviceID)
            }
        case 0xE:                   // pitch bend: 14-bit, center 8192
            let raw = (data2 << 7) | data1
            pitchBend[deviceID, default: [:]][channel] = Float(raw - 8192) / 8192.0
            if abs(raw - 8192) > 2048 {
                scanEvent = .midi(.pitchBend, number: 0, channel: channel, deviceID: deviceID)
            }
        case 0xD:                   // channel aftertouch
            aftertouch[deviceID, default: [:]][channel] = data1
        case 0xA:                   // polyphonic key pressure: note, pressure
            if data2 > 0 {
                polyPressure[deviceID, default: [:]][channel, default: [:]][data1] = data2
            } else {
                polyPressure[deviceID]?[channel]?.removeValue(forKey: data1)
            }
        case 0xC:                   // program change
            if pendingBankScan?.key == "\(deviceID)|\(channel)" { pendingBankScan = nil }
            programHits[deviceID, default: [:]][channel, default: []].insert(data1)
            lastProgram[deviceID, default: [:]][channel] = data1
            pushEvent(deviceID, "Program \(data1) · ch \(channel)")
            scanEvent = .midi(.programChange, number: data1, channel: channel, deviceID: deviceID)
        default:
            break
        }
        let handler = scanHandler
        lock.unlock()


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
            let bend = pitchBend[dev]?.values.first
            var touch = aftertouch[dev]?.values.max()
            for (_, byNote) in polyPressure[dev] ?? [:] {
                if let poly = byNote.values.max() { touch = max(touch ?? 0, poly) }
            }
            let prog = lastProgram[dev]?.values.first
            return DeviceActivity(id: dev, name: device.name,
                                  notesDown: notes, ccs: ccList,
                                  pitchBend: bend, aftertouch: touch,
                                  lastProgram: prog,
                                  velocities: noteVel[dev] ?? [:],
                                  channelStamps: channelStamps[dev] ?? [:],
                                  recent: recentEvents[dev] ?? [],
                                  eventCount: eventCounter)
        }
    }

    /// Monotonic count of recognized incoming messages, for idle gating.
    func activityCounter() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return eventCounter
    }

    // MARK: Queries used by MappingEngine

    /// True while the given note is held. `channel`/`device` nil = any.
    func isNoteDown(_ note: Int, channel: Int?, deviceID: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        for (dev, byChannel) in notesDown where deviceID == nil || dev == deviceID {
            for (ch, notes) in byChannel where channel == nil || ch == channel {
                if notes.contains(note) { return true }
            }
        }
        // A tap shorter than a poll frame still counts once.
        let now = ProcessInfo.processInfo.systemUptime
        for (key, at) in noteOnAt where now - at < 0.025 {
            let parts = key.split(separator: "|")
            guard parts.count == 3, Int(parts[2]) == note else { continue }
            if let deviceID, String(parts[0]) != deviceID { continue }
            if let channel, Int(parts[1]) != channel { continue }
            return true
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
        for (dev, byChannel) in pitchBend where deviceID == nil || dev == deviceID {
            for (ch, v) in byChannel where channel == nil || ch == channel {
                if abs(v) > abs(out) { out = v }
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
    /// arrived since the last call, and clears it. Momentary like Program
    /// Change. `device` nil = any.
    func consumeTransport(_ status: UInt8, deviceID: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var hit = false
        for (dev, statuses) in transportHits where deviceID == nil || dev == deviceID {
            if statuses.contains(status) {
                hit = true
                transportHits[dev]?.remove(status)
            }
        }
        return hit
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

        for (rawKey, net) in ccNetTravel {
            let parts = rawKey.split(separator: "|", maxSplits: 2).map(String.init)
            guard parts.count == 3,
                  let ch = Int(parts[1]), let number = Int(parts[2]) else { continue }
            guard number == cc else { continue }
            if let channel, ch != channel { continue }
            if let deviceID, parts[0] != deviceID { continue }

            let markKey = consumerKey + "|" + rawKey
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

    /// Whether the given program change arrived since the last call, and
    /// clears it. Program Change is momentary, so it is consumed: the
    /// binding fires for exactly one poll frame.
    func consumeProgramChange(_ program: Int, channel: Int?, deviceID: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var hit = false
        for (dev, byChannel) in programHits where deviceID == nil || dev == deviceID {
            for (ch, programs) in byChannel where channel == nil || ch == channel {
                if programs.contains(program) {
                    hit = true
                    programHits[dev]?[ch]?.remove(program)
                }
            }
        }
        return hit
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
        // A scanned Program Change or Start is not left queued for a row.
        programHits.removeAll()
        transportHits.removeAll()
        lock.unlock()
    }

    /// Forget Program Change and Transport hits nobody read. Called when a
    /// preset starts: a Start or Stop heard with nothing running fired its
    /// row the moment a preset was turned on.
    func clearMomentaryHits() {
        lock.lock()
        programHits.removeAll()
        transportHits.removeAll()
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
        lock.unlock()
    }
}
