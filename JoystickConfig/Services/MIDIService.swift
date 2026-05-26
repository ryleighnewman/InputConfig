import Foundation
import CoreMIDI

/// Sends MIDI messages out of a virtual MIDI source named "JoystickConfig".
///
/// Any DAW or music app on the Mac that supports external MIDI input (Logic
/// Pro, Ableton Live, GarageBand, MainStage, Bitwig, FL Studio for Mac, etc.)
/// will see "JoystickConfig" as an available MIDI source. The user connects
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

    private let queue = DispatchQueue(label: "com.joystickconfig.midi")
    private var client: MIDIClientRef = 0
    private var virtualSource: MIDIEndpointRef = 0
    private var isSetup = false

    /// Active notes per channel keyed by note number. Used so that when a
    /// binding releases and we need to send a note-off, we know exactly what
    /// to silence even if the user changed the note value mid-press.
    private var activeNotes: [Int: Set<Int>] = [:] // channel -> notes
    private let activeNotesLock = NSLock()

    /// Display name of the virtual MIDI port. Apps will see this in their
    /// MIDI source list.
    static let portName = "JoystickConfig"

    private init() {
        setup()
    }

    /// Whether the virtual MIDI port was created successfully. If false the
    /// rest of the methods become no-ops.
    var isReady: Bool { isSetup }

    // MARK: - Setup

    private func setup() {
        let clientName = "JoystickConfig" as CFString
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

        // Make the virtual source persist across sessions so DAWs can
        // reconnect automatically.
        let uniqueID: Int32 = Int32(truncatingIfNeeded: abs(Self.portName.hashValue))
        MIDIObjectSetIntegerProperty(virtualSource, kMIDIPropertyUniqueID, uniqueID)

        isSetup = true
    }

    // MARK: - Sending

    /// Send a Note On.
    func sendNoteOn(note: Int, velocity: Int, channel: Int) {
        guard isSetup else { return }
        let safeNote = clamp(note, 0, 127)
        let safeVel = clamp(velocity, 1, 127) // 0 velocity is interpreted as note-off
        let safeCh = clamp(channel - 1, 0, 15)

        queue.async { [self] in
            send(bytes: [0x90 | UInt8(safeCh), UInt8(safeNote), UInt8(safeVel)])
            track(note: safeNote, channel: safeCh, on: true)
        }
    }

    /// Send a Note Off.
    func sendNoteOff(note: Int, channel: Int) {
        guard isSetup else { return }
        let safeNote = clamp(note, 0, 127)
        let safeCh = clamp(channel - 1, 0, 15)
        queue.async { [self] in
            send(bytes: [0x80 | UInt8(safeCh), UInt8(safeNote), 0])
            track(note: safeNote, channel: safeCh, on: false)
        }
    }

    /// Release every note we have tracked as active. Called by MappingEngine
    /// when the engine stops or a preset is deactivated, so we never leave
    /// stuck notes hanging in the DAW.
    func releaseAllNotes() {
        guard isSetup else { return }
        queue.async { [self] in
            activeNotesLock.lock()
            let snapshot = activeNotes
            activeNotes.removeAll()
            activeNotesLock.unlock()

            for (channel, notes) in snapshot {
                for note in notes {
                    send(bytes: [0x80 | UInt8(channel), UInt8(note), 0])
                }
            }
        }
    }

    /// Send a Control Change. `value` is 0-127.
    func sendCC(controller: Int, value: Int, channel: Int) {
        guard isSetup else { return }
        let safeCC = clamp(controller, 0, 127)
        let safeVal = clamp(value, 0, 127)
        let safeCh = clamp(channel - 1, 0, 15)

        queue.async { [self] in
            send(bytes: [0xB0 | UInt8(safeCh), UInt8(safeCC), UInt8(safeVal)])
        }
    }

    /// Send Pitch Bend. `value` is 0-16383, centered at 8192.
    func sendPitchBend(value: Int, channel: Int) {
        guard isSetup else { return }
        let safeVal = clamp(value, 0, 16383)
        let safeCh = clamp(channel - 1, 0, 15)
        let lsb = UInt8(safeVal & 0x7F)
        let msb = UInt8((safeVal >> 7) & 0x7F)
        queue.async { [self] in
            send(bytes: [0xE0 | UInt8(safeCh), lsb, msb])
        }
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
        let now = MIDITimeStamp(0)

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
        if on {
            var set = activeNotes[channel] ?? Set<Int>()
            set.insert(note)
            activeNotes[channel] = set
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
                return (n, "\(n) - \(name)")
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
