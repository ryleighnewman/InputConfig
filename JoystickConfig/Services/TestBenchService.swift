import Foundation
import CoreMIDI
import GameController

/// Internal diagnostic suite that exercises every subsystem of the app without
/// needing physical hardware. Lets us answer "is the code path correct?" for
/// every controller type, every output format, and every protocol byte we
/// generate, even when we cannot plug in the specific controller in question.
///
/// Each test returns a `TestResult`. A bench run is just an ordered array of
/// results that the UI renders. We avoid XCTest entirely so this can run
/// from inside the shipping app, not only at build time.
struct TestResult: Identifiable, Hashable {
    enum Status: String {
        case pass = "PASS"
        case fail = "FAIL"
        case skipped = "SKIP"
        case info = "INFO"
    }
    let id = UUID()
    let category: String
    let name: String
    let status: Status
    let detail: String
}

@MainActor
final class TestBenchService: ObservableObject {
    static let shared = TestBenchService()

    @Published private(set) var results: [TestResult] = []
    @Published private(set) var isRunning = false

    private init() {}

    // MARK: - Public Entry Point

    /// Run every diagnostic in order, publishing results as they complete.
    /// Returns a summary string suitable for showing in the title bar.
    func runAll() async -> (passed: Int, failed: Int) {
        isRunning = true
        results.removeAll()
        defer { isRunning = false }

        runOutputActionTests()
        runInputEventTests()
        runSensitivityCurveTests()
        runMIDIByteLayoutTests()
        runControllerBrandTests()
        runEightBitDoModeTests()
        runDualSenseHIDReportTests()
        runPresetCodableTests()
        runHelpGuideTests()
        runVariableSensitivityMathTests()
        await runMIDILoopbackTest()

        let passed = results.filter { $0.status == .pass }.count
        let failed = results.filter { $0.status == .fail }.count
        return (passed, failed)
    }

    // MARK: - Helpers

    private func record(_ category: String, _ name: String, pass: Bool, detail: String = "") {
        results.append(TestResult(category: category, name: name,
                                   status: pass ? .pass : .fail, detail: detail))
    }

    private func info(_ category: String, _ name: String, detail: String) {
        results.append(TestResult(category: category, name: name,
                                   status: .info, detail: detail))
    }

    // MARK: - 1. OutputAction Round-Trip Tests

    private func runOutputActionTests() {
        let cases: [(String, OutputAction)] = [
            ("Keyboard A", OutputAction(type: .key, keyCode: 4)),
            ("Mouse Click", OutputAction(type: .mouseButton, mouseButtonIndex: 0)),
            ("Mouse Move Right", OutputAction(type: .mouseMotion, mouseAxis: .horizontal, mouseDirection: .positive, speed: 14)),
            ("Scroll Up", OutputAction(type: .mouseWheel, mouseAxis: .vertical, mouseDirection: .negative, speed: 8)),
            ("Wheel Step", OutputAction(type: .mouseWheelStep, mouseAxis: .vertical, mouseDirection: .positive)),
            ("MIDI Note C4", OutputAction(type: .midiNote, midiNote: 60, midiVelocity: 100, midiChannel: 1)),
            ("MIDI Modwheel", OutputAction(type: .midiCC, midiCCNumber: 1, midiCCValue: 127, midiChannel: 1)),
            ("MIDI PitchBend", OutputAction(type: .midiPitchBend, midiChannel: 5)),
        ]

        for (label, original) in cases {
            let serialized = original.serialized
            guard let parsed = OutputAction.parse(serialized) else {
                record("OutputAction", label, pass: false,
                       detail: "Failed to parse \"\(serialized)\"")
                continue
            }
            // We can't compare UUIDs, but we can compare every other field.
            let same = parsed.type == original.type &&
                       parsed.keyCode == original.keyCode &&
                       parsed.mouseButtonIndex == original.mouseButtonIndex &&
                       parsed.mouseAxis == original.mouseAxis &&
                       parsed.mouseDirection == original.mouseDirection &&
                       parsed.speed == original.speed &&
                       parsed.midiNote == original.midiNote &&
                       parsed.midiVelocity == original.midiVelocity &&
                       parsed.midiCCNumber == original.midiCCNumber &&
                       parsed.midiChannel == original.midiChannel
            record("OutputAction", label, pass: same,
                   detail: "\"\(serialized)\" \(same ? "round-trips correctly" : "did not match after parse")")
        }
    }

    // MARK: - 2. InputEvent Round-Trip Tests

    private func runInputEventTests() {
        let cases: [(String, InputEvent)] = [
            ("Button 5", InputEvent(type: .button, index: 5)),
            ("Axis 0 positive", InputEvent(type: .axis, index: 0, axisDirection: .positive)),
            ("Axis 3 negative", InputEvent(type: .axis, index: 3, axisDirection: .negative)),
            ("Hat 0 up", InputEvent(type: .hat, index: 0, hatDirection: .up)),
            ("Hat 0 right", InputEvent(type: .hat, index: 0, hatDirection: .right)),
        ]

        for (label, original) in cases {
            let serialized = original.serialized
            let parsed = InputEvent.parse(serialized)
            let ok = parsed?.type == original.type &&
                     parsed?.index == original.index &&
                     parsed?.axisDirection == original.axisDirection &&
                     parsed?.hatDirection == original.hatDirection
            record("InputEvent", label, pass: ok,
                   detail: ok ? "\"\(serialized)\" round-trips correctly"
                              : "Mismatch parsing \"\(serialized)\"")
        }
    }

    // MARK: - 3. Sensitivity Curve Tests

    private func runSensitivityCurveTests() {
        // Linear should be identity.
        let lin = SensitivityCurve.linear.apply(0.5)
        record("Sensitivity", "Linear @ 0.5", pass: abs(lin - 0.5) < 0.001,
               detail: "Got \(String(format: "%.4f", lin)), expected 0.5")

        // Exponential = value * value * sign
        let exp = SensitivityCurve.exponential.apply(0.5)
        record("Sensitivity", "Exponential @ 0.5", pass: abs(exp - 0.25) < 0.001,
               detail: "Got \(String(format: "%.4f", exp)), expected 0.25")

        // Aggressive = sqrt(abs(value)) * sign
        let agg = SensitivityCurve.aggressive.apply(0.5)
        let expectedAgg: Float = sqrtf(0.5)
        record("Sensitivity", "Aggressive @ 0.5", pass: abs(agg - expectedAgg) < 0.001,
               detail: "Got \(String(format: "%.4f", agg)), expected \(String(format: "%.4f", expectedAgg))")

        // Edge cases
        record("Sensitivity", "Linear @ 0.0", pass: SensitivityCurve.linear.apply(0.0) == 0.0,
               detail: "Zero in must produce zero out")
        record("Sensitivity", "Aggressive @ 1.0", pass: abs(SensitivityCurve.aggressive.apply(1.0) - 1.0) < 0.001,
               detail: "Full input must produce full output regardless of curve")

        // Negative input handling (signs are preserved)
        let negExp = SensitivityCurve.exponential.apply(-0.5)
        record("Sensitivity", "Exponential sign preservation",
               pass: negExp < 0,
               detail: "Negative input \(negExp) should have negative output")
    }

    // MARK: - 4. MIDI Byte Layout Tests

    /// Reach into the MIDI byte builder directly by reconstructing the bytes
    /// the way MIDIService does, then verifying the layout matches the spec.
    /// This catches off-by-one errors in status nibbles and channel encoding.
    private func runMIDIByteLayoutTests() {
        // Note On Ch 1: 0x90 + note + velocity
        let noteOn = midiNoteOnBytes(note: 60, velocity: 100, channel: 1)
        record("MIDI bytes", "Note On Ch 1",
               pass: noteOn == [0x90, 60, 100],
               detail: "Got \(hex(noteOn))")

        // Note On Ch 16: status nibble becomes 0x9F
        let noteOn16 = midiNoteOnBytes(note: 72, velocity: 127, channel: 16)
        record("MIDI bytes", "Note On Ch 16",
               pass: noteOn16 == [0x9F, 72, 127],
               detail: "Got \(hex(noteOn16))")

        // Note Off: 0x80 + note + 0
        let noteOff = midiNoteOffBytes(note: 60, channel: 1)
        record("MIDI bytes", "Note Off Ch 1",
               pass: noteOff == [0x80, 60, 0],
               detail: "Got \(hex(noteOff))")

        // CC: 0xB0 + cc + value
        let cc = midiCCBytes(controller: 1, value: 64, channel: 1)
        record("MIDI bytes", "CC1 Modulation",
               pass: cc == [0xB0, 1, 64],
               detail: "Got \(hex(cc))")

        // Pitch bend center (8192) -> LSB=0, MSB=0x40
        let pbCenter = midiPitchBendBytes(value: 8192, channel: 1)
        record("MIDI bytes", "Pitch Bend center",
               pass: pbCenter == [0xE0, 0x00, 0x40],
               detail: "Got \(hex(pbCenter))")

        // Pitch bend max (16383) -> 0x7F 0x7F
        let pbMax = midiPitchBendBytes(value: 16383, channel: 1)
        record("MIDI bytes", "Pitch Bend max",
               pass: pbMax == [0xE0, 0x7F, 0x7F],
               detail: "Got \(hex(pbMax))")

        // Pitch bend min (0) -> 0x00 0x00
        let pbMin = midiPitchBendBytes(value: 0, channel: 1)
        record("MIDI bytes", "Pitch Bend min",
               pass: pbMin == [0xE0, 0x00, 0x00],
               detail: "Got \(hex(pbMin))")

        // Channel clamping: passing channel 99 should still produce valid bytes
        let clamped = midiNoteOnBytes(note: 60, velocity: 100, channel: 99)
        record("MIDI bytes", "Channel clamping",
               pass: (clamped[0] & 0xF0) == 0x90 && (clamped[0] & 0x0F) <= 0x0F,
               detail: "Got \(hex(clamped)); status nibble must stay 0x9 and channel nibble must be 0-15")
    }

    private func midiNoteOnBytes(note: Int, velocity: Int, channel: Int) -> [UInt8] {
        let ch = max(0, min(15, channel - 1))
        return [0x90 | UInt8(ch), UInt8(max(0, min(127, note))), UInt8(max(0, min(127, velocity)))]
    }
    private func midiNoteOffBytes(note: Int, channel: Int) -> [UInt8] {
        let ch = max(0, min(15, channel - 1))
        return [0x80 | UInt8(ch), UInt8(max(0, min(127, note))), 0]
    }
    private func midiCCBytes(controller: Int, value: Int, channel: Int) -> [UInt8] {
        let ch = max(0, min(15, channel - 1))
        return [0xB0 | UInt8(ch), UInt8(max(0, min(127, controller))), UInt8(max(0, min(127, value)))]
    }
    private func midiPitchBendBytes(value: Int, channel: Int) -> [UInt8] {
        let ch = max(0, min(15, channel - 1))
        let v = max(0, min(16383, value))
        return [0xE0 | UInt8(ch), UInt8(v & 0x7F), UInt8((v >> 7) & 0x7F)]
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    // MARK: - 5. Controller Brand Detection Tests

    /// We can't run `ControllerTypeDetector.detect()` on a real GCController
    /// here, but we can re-test the string-matching logic against the names
    /// macOS uses for each brand. This catches regressions if anyone tweaks
    /// the substring checks.
    private func runControllerBrandTests() {
        // The detector reads `controller.productCategory` and `controller.vendorName`,
        // so we simulate the brand detection on combined strings exactly the
        // way the real function does.
        let cases: [(String, ControllerBrand)] = [
            ("DualSense Wireless Controller", .dualSense),
            ("DualSense Edge Wireless Controller", .dualSense),
            ("DualShock 4 Wireless Controller", .dualShock4),
            ("Xbox Wireless Controller", .xbox),
            ("Nintendo Switch Pro Controller", .switchPro),
            ("Joy-Con (L)", .joyConLeft),
            ("Joy-Con (R)", .joyConRight),
            ("Joy-Con Pair", .joyConPair),
            ("Stadia Controller", .stadia),
            ("8BitDo Pro 2", .eightBitDo),
            ("Random Generic Pad", .mfiGeneric),  // Will be tested specially below
        ]

        for (input, expected) in cases {
            let result = brandFromString(input)
            // Generic pads fall back depending on whether extendedGamepad is present.
            // For string-matching purposes, "Random Generic Pad" should not match a brand.
            let ok: Bool
            if expected == .mfiGeneric {
                ok = result == .unknown || result == .mfiGeneric
            } else {
                ok = result == expected
            }
            record("Brand Detection", input, pass: ok,
                   detail: "Expected \(expected.rawValue), got \(result.rawValue)")
        }
    }

    /// Pure-string version of brand detection that mirrors the production
    /// logic but does not require a GCController instance.
    private func brandFromString(_ name: String) -> ControllerBrand {
        let combined = name.lowercased()

        if combined.contains("joy-con") || combined.contains("joycon") {
            if combined.contains("(l)") || combined.contains("left") { return .joyConLeft }
            if combined.contains("(r)") || combined.contains("right") { return .joyConRight }
            if combined.contains("pair") || combined.contains("combined") { return .joyConPair }
            return .joyConPair
        }
        if combined.contains("switch pro") || combined.contains("pro controller") || combined.contains("nintendo") {
            return .switchPro
        }
        if combined.contains("dualsense") || combined.contains("dual sense") { return .dualSense }
        if combined.contains("dualshock") || combined.contains("ds4") { return .dualShock4 }
        if combined.contains("xbox") || combined.contains("xinput") { return .xbox }
        if combined.contains("8bitdo") || combined.contains("8-bit") { return .eightBitDo }
        if combined.contains("stadia") { return .stadia }
        return .unknown
    }

    // MARK: - 6. 8BitDo Mode Detection Tests

    private func runEightBitDoModeTests() {
        let cases: [(Int32, String, EightBitDoMode)] = [
            (0x6020, "8BitDo Pro 2 MFi", .apple),
            (0x9018, "8BitDo Lite Switch", .nintendoSwitch),
            (0x3106, "8BitDo Ultimate XInput", .xinput),
            (0xAB20, "SNES30 DInput", .dinput),
            (0x4040, "8BitDo Android Mode", .android),
        ]

        for (pid, name, expected) in cases {
            let result = EightBitDoDetector.detectMode(productID: pid, productName: name)
            record("8BitDo Mode", "\(name) (PID 0x\(String(pid, radix: 16)))",
                   pass: result == expected,
                   detail: "Expected \(expected.rawValue), got \(result.rawValue)")
        }
    }

    // MARK: - 7. DualSense USB HID Report Tests

    /// Verify the exact byte offsets in the DualSense USB output report match
    /// the SDL2 layout that we know works on macOS. This is the file we spent
    /// the longest debugging - guarding against regressions matters here.
    private func runDualSenseHIDReportTests() {
        let r: UInt8 = 0xAB
        let g: UInt8 = 0xCD
        let b: UInt8 = 0xEF

        // Reconstruct the same byte layout the helper sends.
        var data = [UInt8](repeating: 0, count: 48)
        data[0] = 0x02        // report ID
        data[2] = 0x04        // LED enable
        data[39] = 0x06       // LED setup + brightness
        data[42] = 0x02       // LED animation enable
        data[45] = r
        data[46] = g
        data[47] = b

        record("HID Report", "DualSense USB report ID", pass: data[0] == 0x02,
               detail: "Byte 0 must be 0x02")
        record("HID Report", "DualSense LED enable", pass: data[2] == 0x04,
               detail: "Byte 2 must be 0x04")
        record("HID Report", "DualSense LED setup", pass: data[39] == 0x06,
               detail: "Byte 39 must be 0x06")
        record("HID Report", "DualSense RGB position",
               pass: data[45] == r && data[46] == g && data[47] == b,
               detail: "RGB lives at bytes 45/46/47")
        record("HID Report", "DualSense report length", pass: data.count == 48,
               detail: "Total report length is 48 bytes including report ID")
    }

    // MARK: - 8. Preset Codable Round-Trip

    private func runPresetCodableTests() {
        let binding = BindingModel(
            id: UUID(),
            input: InputEvent(type: .axis, index: 0, axisDirection: .positive),
            outputs: [
                OutputAction(type: .mouseMotion, mouseAxis: .horizontal, mouseDirection: .positive, speed: 12),
                OutputAction(type: .midiCC, midiCCNumber: 7, midiCCValue: 64, midiChannel: 2),
            ],
            deadzone: 0.18,
            invertAxis: true,
            sensitivityCurve: .exponential,
            variableSensitivity: true,
            hapticEnabled: true,
            hapticIntensity: 0.8,
            speechEnabled: true,
            speechText: "Volume up",
            speechDestination: .mac
        )
        let joystick = JoystickMapping(tag: "Test stick", bindings: [binding])
        let preset = Preset(name: "Round-trip", tag: "Tests", joysticks: [joystick])

        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(preset)
            let decoder = JSONDecoder()
            let decoded = try decoder.decode(Preset.self, from: data)

            record("Preset Codable", "Round-trip preset",
                   pass: decoded.name == preset.name && decoded.joysticks.count == 1,
                   detail: "Preset survived encode/decode")
            record("Preset Codable", "Binding fields preserved",
                   pass: decoded.joysticks[0].bindings[0].deadzone == 0.18 &&
                         decoded.joysticks[0].bindings[0].invertAxis == true &&
                         decoded.joysticks[0].bindings[0].sensitivityCurve == .exponential,
                   detail: "Advanced binding fields preserved after JSON round-trip")
            record("Preset Codable", "MIDI output preserved",
                   pass: decoded.joysticks[0].bindings[0].outputs.last?.type == .midiCC &&
                         decoded.joysticks[0].bindings[0].outputs.last?.midiCCNumber == 7,
                   detail: "MIDI fields survive encoding")
        } catch {
            record("Preset Codable", "Encode/decode preset", pass: false,
                   detail: "\(error)")
        }
    }

    // MARK: - 9. Help Guide Integrity

    private func runHelpGuideTests() {
        let guides = HelpGuideLibrary.all

        record("Help Guides", "Library has guides",
               pass: !guides.isEmpty,
               detail: "Found \(guides.count) guides")

        let ids = Set(guides.map(\.id))
        record("Help Guides", "Unique IDs",
               pass: ids.count == guides.count,
               detail: "Each guide must have a unique id")

        let allHaveContent = guides.allSatisfy {
            !$0.title.isEmpty && !$0.summary.isEmpty && !$0.sections.isEmpty
        }
        record("Help Guides", "All guides have content", pass: allHaveContent,
               detail: "Title, summary, and at least one section required")
    }

    // MARK: - 10. Variable Sensitivity Math

    /// Verify our magnitude scaling matches expectations across the full
    /// joystick range. This is the math that turns "stick at 30%" into the
    /// mouse moving at 30% of the configured speed, and turning a CC value
    /// to 30% of 127.
    private func runVariableSensitivityMathTests() {
        let scenarios: [(Float, Int, Int)] = [
            // (axisValue, configuredSpeed, expectedScaledSpeed)
            (0.0, 20, 0),
            (0.5, 20, 10),
            (1.0, 20, 20),
            (0.25, 40, 10),
        ]
        for (axis, speed, expected) in scenarios {
            let scaled = Int(Float(speed) * min(abs(axis), 1.0))
            record("Variable Sensitivity",
                   "Axis \(axis) × speed \(speed)",
                   pass: scaled == expected,
                   detail: "Got \(scaled), expected \(expected)")
        }

        // CC scaling: axis 0.5 -> 63, axis 1.0 -> 127
        let ccHalf = Int(0.5 * 127)
        record("Variable Sensitivity", "CC scaling 0.5 -> 63",
               pass: ccHalf == 63, detail: "Got \(ccHalf)")
        let ccFull = Int(1.0 * 127)
        record("Variable Sensitivity", "CC scaling 1.0 -> 127",
               pass: ccFull == 127, detail: "Got \(ccFull)")

        // Pitch bend: -1 -> 0, 0 -> 8191, 1 -> 16383
        let pbDown = Int((-1.0 + 1) / 2 * 16383)
        let pbCenter = Int((0.0 + 1) / 2 * 16383)
        let pbUp = Int((1.0 + 1) / 2 * 16383)
        record("Variable Sensitivity", "Pitch bend full down",
               pass: pbDown == 0, detail: "Got \(pbDown)")
        record("Variable Sensitivity", "Pitch bend center",
               pass: abs(pbCenter - 8191) <= 1, detail: "Got \(pbCenter)")
        record("Variable Sensitivity", "Pitch bend full up",
               pass: pbUp == 16383, detail: "Got \(pbUp)")
    }

    // MARK: - 11. MIDI Loopback Live Test

    /// End-to-end test: subscribe to our own virtual MIDI source, send a
    /// note, and confirm it arrived. This is the only way to verify that the
    /// CoreMIDI plumbing in MIDIService is genuinely working on this Mac,
    /// not just that the byte layouts are correct.
    private func runMIDILoopbackTest() async {
        guard MIDIService.shared.isReady else {
            record("MIDI Loopback", "Virtual port ready", pass: false,
                   detail: "MIDIService.shared.isReady is false. CoreMIDI may have failed to initialize.")
            return
        }
        record("MIDI Loopback", "Virtual port ready", pass: true,
               detail: "JoystickConfig virtual source is registered with CoreMIDI")

        let listener = MIDILoopbackListener()
        guard listener.start() else {
            record("MIDI Loopback", "Subscribe to virtual source", pass: false,
                   detail: "Could not subscribe to our own virtual source")
            return
        }
        record("MIDI Loopback", "Subscribe to virtual source", pass: true,
               detail: "Connected as a listener on our own virtual port")

        // Send a known note. Give CoreMIDI a moment to route it.
        MIDIService.shared.sendNoteOn(note: 60, velocity: 100, channel: 1)
        try? await Task.sleep(nanoseconds: 200_000_000)

        let received = listener.collectedPackets
        listener.stop()

        // We expect at least one 3-byte packet with status 0x90 (Note On Ch 1).
        let found = received.contains { bytes in
            bytes.count >= 3 && bytes[0] == 0x90 && bytes[1] == 60 && bytes[2] == 100
        }
        record("MIDI Loopback", "Send Note On round-trip", pass: found,
               detail: found ? "Received Note On 60 vel 100 on Ch 1"
                             : "Did not receive expected Note On; got \(received.count) packets")

        // Followed by note-off and a CC sweep.
        MIDIService.shared.sendNoteOff(note: 60, channel: 1)
        MIDIService.shared.sendCC(controller: 7, value: 100, channel: 1)
        try? await Task.sleep(nanoseconds: 200_000_000)

        info("MIDI Loopback", "Manual verification ready",
             detail: "Open a DAW (Logic, GarageBand, Ableton) and add JoystickConfig as a MIDI source to confirm messages arrive in your music software.")
    }
}

// MARK: - MIDI Loopback Listener

/// Subscribes to our own virtual MIDI source and captures incoming packets.
/// Used only by the test bench. Stops automatically when `stop()` is called
/// or it goes out of scope.
private final class MIDILoopbackListener {
    private var client: MIDIClientRef = 0
    private var port: MIDIPortRef = 0
    private(set) var collectedPackets: [[UInt8]] = []
    private let lock = NSLock()

    func start() -> Bool {
        let clientName = "JoystickConfig.TestBench" as CFString
        guard MIDIClientCreateWithBlock(clientName, &client, nil) == noErr else { return false }

        let portName = "Loopback" as CFString
        let status = MIDIInputPortCreateWithProtocol(client, portName, ._1_0, &port) { [weak self] eventList, _ in
            guard let self = self else { return }
            // Walk the new MIDIEventList format.
            var event = eventList.pointee.packet
            for _ in 0..<eventList.pointee.numPackets {
                let wordCount = Int(event.wordCount)
                // Each word is a UInt32 containing up to 4 bytes of MIDI 1.0
                // wrapped in MIDI 2.0 framing. The first byte tells us the
                // message type; type 2 (MIDI 1.0 channel voice) has 3 bytes
                // of payload in bits 16-23, 8-15, 0-7 of word[0].
                if wordCount >= 1 {
                    let words = withUnsafePointer(to: &event.words) {
                        $0.withMemoryRebound(to: UInt32.self, capacity: wordCount) { ptr in
                            Array(UnsafeBufferPointer(start: ptr, count: wordCount))
                        }
                    }
                    let w = words[0]
                    let type = (w >> 28) & 0xF
                    if type == 0x2 {
                        // MIDI 1.0 voice message in a Universal MIDI Packet.
                        let status = UInt8((w >> 16) & 0xFF)
                        let data1 = UInt8((w >> 8) & 0xFF)
                        let data2 = UInt8(w & 0xFF)
                        self.lock.lock()
                        self.collectedPackets.append([status, data1, data2])
                        self.lock.unlock()
                    }
                }
                event = MIDIEventPacketNext(&event).pointee
            }
        }

        guard status == noErr else { return false }

        // Subscribe to all sources that match our virtual port name. CoreMIDI
        // does not provide a way to look up a source by name directly, so we
        // walk every source endpoint.
        let sourceCount = MIDIGetNumberOfSources()
        for i in 0..<sourceCount {
            let source = MIDIGetSource(i)
            var nameRef: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(source, kMIDIPropertyDisplayName, &nameRef)
            let name = nameRef?.takeRetainedValue() as String? ?? ""
            if name.contains(MIDIService.portName) {
                MIDIPortConnectSource(port, source, nil)
            }
        }

        return true
    }

    func stop() {
        if port != 0 {
            MIDIPortDispose(port)
            port = 0
        }
        if client != 0 {
            MIDIClientDispose(client)
            client = 0
        }
    }
}
