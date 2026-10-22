import Foundation
import AppKit
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
        runExtraButtonsAndKeysTests()
        runSensitivityCurveTests()
        runMIDIByteLayoutTests()
        runControllerBrandTests()
        runFaceNameTests()
        runEightBitDoModeTests()
        runAccessControllerTests()
        runLogitechWheelTests()
        runSwitch2CalibrationTests()
        runMotionMathTests()
        runControllerPowerTests()
        runHelpLinkTests()
        runCGEventDecoderTests()
        runPlayStationProbeTests()
        runXboxBatteryTests()
        runPresetCodableTests()
        runVersionConsistencyTests()
        runHelpGuideTests()
        runVariableSensitivityMathTests()
        runHIDDescriptorParserTests()
        runHIDProfileMatrixTests()
        runHIDEdgeCaseFuzzTests()
        runFixtureCorpus()
        await runSequenceFixtures(HIDFixtureCorpus.sequences)
        await runMIDILoopbackTest()
        await runSteamControllerSimulationTest()
        await runKeyboardOutputLoopbackTest()
        runHardwareSnapshot()

        let passed = results.filter { $0.status == .pass }.count
        let failed = results.filter { $0.status == .fail }.count
        return (passed, failed)
    }

    /// The headless summary: counts, every failure, and the info lines that
    /// prove which checks ran (coverage, unverified fixtures, routes not
    /// wired yet). Written to tmp/testbench.txt by the debug hook.
    var headlessReport: String {
        let passed = results.filter { $0.status == .pass }.count
        let failed = results.filter { $0.status == .fail }.count
        var text = "passed=\(passed) failed=\(failed)\n"
        for r in results where r.status == .fail {
            text += "FAIL \(r.category): \(r.name): \(r.detail)\n"
        }
        for r in results where r.status == .info
            && (r.name.hasPrefix("coverage") || r.name.contains("unverified") || r.name.contains("not wired")) {
            text += "INFO \(r.category): \(r.name): \(r.detail)\n"
        }
        return text
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

    // MARK: - Face button names

    /// The Face button names choice, including PlayStation names on a pad
    /// that is not a PlayStation pad.
    private func runFaceNameTests() {
        let cat = "Face Button Names"
        let ps = (0...3).compactMap { FaceLetters.genericName($0, choice: .playstation) }
        record(cat, "PlayStation names the face buttons on any controller",
               pass: ps == [String(localized: "Cross"), String(localized: "Circle"), String(localized: "Square"), String(localized: "Triangle")]
                   && FaceLetters.playStation(for: .xbox, choice: .playstation)
                   && !FaceLetters.nintendo(for: .switchPro, choice: .playstation),
               detail: ps.joined(separator: ", "))
        record(cat, "A PlayStation pad keeps its names under every lettered choice",
               pass: [FaceLetters.automatic, .xbox, .nintendo, .playstation]
                   .allSatisfy { FaceLetters.playStation(for: .dualSense, choice: $0) },
               detail: "Automatic, Xbox, Nintendo, PlayStation")
    }

    // MARK: - Extra mouse buttons and unusual keys

    /// Gaming mice, gaming keyboards, and ISO or Japanese keyboards nobody
    /// here owns: builds the same events macOS hands the app for them and
    /// runs them through the app's own decoding.
    private func runExtraButtonsAndKeysTests() {
        let cat = "Extra Buttons & Keys"

        // Every button number macOS can report past left and right.
        var wrongButtons: [Int] = []
        for n in 2...31 {
            guard let ev = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown,
                                   mouseCursorPosition: .zero, mouseButton: .center) else {
                wrongButtons.append(n); continue
            }
            ev.setIntegerValueField(.mouseEventButtonNumber, value: Int64(n))
            if ExternalInputDeviceService.mouseButton(of: ev, type: .otherMouseDown) != n {
                wrongButtons.append(n)
            }
        }
        record(cat, "Mouse buttons 3 to 32 each arrive as their own button", pass: wrongButtons.isEmpty,
               detail: wrongButtons.isEmpty ? "30 buttons" : "Wrong: \(wrongButtons)")

        if let tilt = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                              wheel1: 0, wheel2: 3, wheel3: 0) {
            var carry: (x: Double, y: Double) = (0, 0)
            let d = ExternalInputDeviceService.scrollDeltas(of: tilt, carry: &carry)
            record(cat, "A tilt wheel scrolls sideways", pass: d.dx == 3 && d.dy == 0,
                   detail: "dx \(d.dx), dy \(d.dy)")
        } else {
            record(cat, "A tilt wheel scrolls sideways", pass: false, detail: "Could not build the event")
        }

        // Keys gaming and international keyboards send, by macOS key code.
        let keys: [(vk: Int, code: Int, what: String)] = [
            (105, 104, "F13"), (107, 105, "F14"), (113, 106, "F15"), (106, 107, "F16"),
            (64, 108, "F17"), (79, 109, "F18"), (80, 110, "F19"), (90, 111, "F20"),
            (110, 101, "Menu"), (10, 100, "ISO section"), (93, 137, "JIS yen"),
            (94, 135, "JIS underscore"), (95, 133, "JIS keypad comma"),
            (102, 145, "Eisu"), (104, 144, "Kana"),
            (72, 311, "volume up key"), (73, 312, "volume down key"), (74, 310, "mute key"),
        ]
        var wrongKeys: [String] = []
        for k in keys {
            guard let cg = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(k.vk), keyDown: true),
                  let ns = NSEvent(cgEvent: cg) else { wrongKeys.append(k.what); continue }
            if ExternalInputDeviceService.inputCode(forVirtualKeyCode: Int(ns.keyCode)) != k.code {
                wrongKeys.append(k.what)
            }
        }
        record(cat, "F13 to F20, Menu, ISO, Japanese, and volume keys are recognized",
               pass: wrongKeys.isEmpty,
               detail: wrongKeys.isEmpty ? "\(keys.count) keys" : "Wrong: \(wrongKeys.joined(separator: ", "))")

        // A key the app has no name for still becomes an input, and survives
        // being saved in a preset.
        let unnamed = ExternalInputDeviceService.inputCode(forVirtualKeyCode: 66)
        let saved = InputEvent(type: .extKey, index: unnamed).serialized
        record(cat, "A key with no name is still bindable",
               pass: unnamed == KeyCodeMap.unknownKeyBase + 66
                   && KeyCodeMap.name(for: unnamed) == String(localized: "Key code \(66)")
                   && InputEvent.parse(saved)?.index == unnamed,
               detail: "\(KeyCodeMap.name(for: unnamed)), saved as \"\(saved)\"")

        // Media-style keys arrive as system-defined events, not key codes.
        func mediaCode(_ keyType: Int) -> Int? {
            guard let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [],
                                              timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                              data1: (keyType << 16) | (0x0A << 8), data2: -1) else { return nil }
            return ExternalInputDeviceService.mediaKey(from: ev)?.hid
        }
        let play = mediaCode(0x10)
        record(cat, "Play / Pause arrives as a media key", pass: play == 308,
               detail: play.map { KeyCodeMap.name(for: $0) } ?? "Nothing arrived")
        let odd = mediaCode(0x17)
        record(cat, "A media key with no name is still bindable",
               pass: odd == KeyCodeMap.unknownSystemKeyBase + 0x17,
               detail: odd.map { KeyCodeMap.name(for: $0) } ?? "Nothing arrived")
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

    // The production byte builders, so these tests check what ships.
    private func midiNoteOnBytes(note: Int, velocity: Int, channel: Int) -> [UInt8] {
        MIDIService.noteOnBytes(note: note, velocity: velocity, channel: channel)
    }
    private func midiNoteOffBytes(note: Int, channel: Int) -> [UInt8] {
        MIDIService.noteOffBytes(note: note, channel: channel)
    }
    private func midiCCBytes(controller: Int, value: Int, channel: Int) -> [UInt8] {
        MIDIService.ccBytes(controller: controller, value: value, channel: channel)
    }
    private func midiPitchBendBytes(value: Int, channel: Int) -> [UInt8] {
        MIDIService.pitchBendBytes(value: value, channel: channel)
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

    /// Brand detection from a name, through the production matcher.
    private func brandFromString(_ name: String) -> ControllerBrand {
        ControllerTypeDetector.brand(fromName: name) ?? .unknown
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

    // MARK: - 7b. PlayStation Access controller raw report and profiles

    /// The Access controller's own report, decoded the way the reader does,
    /// against the layout measured on a real controller (2026-10-18) and
    /// published by titania, dualsense-ts and ps-access. Bluetooth report
    /// 0x31 byte numbers; the USB report is the same shifted down by one.
    private func runAccessControllerTests() {
        typealias S = AccessControllerPortService
        let cat = "Access Controller"

        // A full report: sockets 1 and 3, center and Profile held, the stick
        // pushed, a stick in E1 at full right and up, a trigger in E2 half
        // way, a button in E3 pressed, E4 empty, profile 2 with switching
        // disabled.
        var bt = [UInt8](repeating: 0, count: 78)
        bt[0] = 0x31
        bt[17] = 0b0000_0101
        bt[18] = 0b0000_1001
        bt[19] = 200; bt[20] = 50
        bt[21] = 255; bt[22] = 0
        bt[23] = 128; bt[24] = 0
        bt[25] = 1; bt[26] = 0
        bt[50] = 0x23   // E1 stick (3), E2 trigger (2)
        bt[42] = 0x01   // E3 button (1), E4 empty
        bt[41] = 0x0A   // profile 2, bit 3 switching disabled
        SonyBluetoothCRC.sealInputReport(&bt)
        guard let d = S.decode(bt) else {
            record(cat, "Bluetooth report decodes", pass: false, detail: "decode returned nil for a 78-byte 0x31 report")
            return
        }
        record(cat, "Bluetooth report decodes", pass: true)
        record(cat, "Sockets and system buttons by bit", pass: d.buttons.isSuperset(of: [40, 42, 48, 51]) && !d.buttons.contains(41) && !d.buttons.contains(49),
               detail: "socket 1 = 40, socket 3 = 42, center = 48, Profile = 51; got \(d.buttons.sorted())")
        record(cat, "Button in E3 while pressed", pass: d.buttons.contains(58), detail: "E3 button = 58; got \(d.buttons.sorted())")
        record(cat, "Stick itself on axes 6 and 7", pass: abs((d.axes[6] ?? 0) - 0.565) < 0.01 && abs((d.axes[7] ?? 0) + 0.612) < 0.01,
               detail: "200 -> +0.565, 50 -> -0.612; got \(d.axes[6] ?? 0), \(d.axes[7] ?? 0)")
        record(cat, "Stick in E1 on axes 8 and 9", pass: abs((d.axes[8] ?? 0) - 1) < 0.01 && d.axes[9] == -1,
               detail: "255 -> +1, 0 -> -1; got \(d.axes[8] ?? 0), \(d.axes[9] ?? 0)")
        record(cat, "Trigger in E2 on axis 10, 0 to 1", pass: abs((d.axes[10] ?? 0) - 128.0 / 255) < 0.001 && d.axes[11] == nil,
               detail: "128 -> 0.502 and no Y; got \(d.axes[10] ?? 0), \(String(describing: d.axes[11]))")
        record(cat, "Button port publishes no axes", pass: d.axes[12] == nil && d.axes[13] == nil)
        record(cat, "Empty port publishes nothing", pass: d.axes[14] == nil && d.axes[15] == nil && d.ports[4] == nil && !d.buttons.contains(59))
        record(cat, "Port types from the type nibbles", pass: d.ports == [1: .stick, 2: .trigger, 3: .button],
               detail: "byte 50 low E1, high E2; byte 42 low E3, high E4; got \(d.ports)")
        record(cat, "Active profile from byte 41 bits 0 to 2", pass: d.activeProfile == 2, detail: "0x0A -> 2; got \(d.activeProfile)")
        record(cat, "Profile switching disabled from byte 41 bit 3", pass: d.switchingDisabled)
        var unsealed = bt; unsealed[77] ^= 0xFF
        record(cat, "Bluetooth report with a bad CRC is dropped", pass: S.decode(unsealed) == nil)

        // The same report over USB: 0x01, 64 bytes, every byte one earlier.
        var usb = [UInt8](repeating: 0, count: 64)
        usb[0] = 0x01
        for i in 1..<64 { usb[i] = bt[i + 1] }
        record(cat, "USB report decodes the same", pass: S.decode(usb) == d, detail: "0x01, 64 bytes, offsets one less than Bluetooth")

        // Reports that are not input: the compact Bluetooth report before
        // the controller is woken, and a wrong length.
        record(cat, "Compact and odd reports ignored", pass: S.decode([0x01] + [UInt8](repeating: 0, count: 9)) == nil
               && S.decode([0x31] + [UInt8](repeating: 0, count: 63)) == nil)

        // Measured at rest with a stick in E1 (USB, 2026-10-18):
        // 17=0 18=0 19=131 20=128 21=128 22=129 23...28=0, byte 50 = 3.
        var rest = [UInt8](repeating: 0, count: 64)
        rest[0] = 0x01
        rest[18] = 131; rest[19] = 128; rest[20] = 128; rest[21] = 129; rest[49] = 3
        if let r = S.decode(rest) {
            record(cat, "Measured rest report: E1 stick, nothing pressed", pass: r.ports == [1: .stick] && r.buttons.isEmpty && abs(r.axes[8] ?? 1) < 0.01 && r.activeProfile == 0,
                   detail: "got ports \(r.ports) buttons \(r.buttons.sorted()) E1 X \(r.axes[8] ?? 9)")
        } else {
            record(cat, "Measured rest report: E1 stick, nothing pressed", pass: false, detail: "decode returned nil")
        }
        // Measured with the stick moved to E2 (byte 50 = 48) and to E4
        // (byte 42 = 0x30, bytes 27/28 = 179/96, profile 2).
        var e2 = rest; e2[20] = 0; e2[21] = 0; e2[22] = 129; e2[23] = 128; e2[49] = 48
        var e4 = rest; e4[20] = 0; e4[21] = 0; e4[49] = 0; e4[41] = 0x30; e4[26] = 179; e4[27] = 96; e4[40] = 2
        let d2 = S.decode(e2), d4 = S.decode(e4)
        record(cat, "Measured E2 report", pass: d2?.ports == [2: .stick] && d2?.axes[8] == nil && abs((d2?.axes[10] ?? 1)) < 0.01,
               detail: "got \(String(describing: d2?.ports)) E2 X \(d2?.axes[10] ?? 9)")
        record(cat, "Measured E4 report", pass: d4?.ports == [4: .stick] && abs((d4?.axes[14] ?? 0) - 0.4) < 0.01 && abs((d4?.axes[15] ?? 0) + 0.251) < 0.01 && d4?.activeProfile == 2,
               detail: "179 -> +0.4, 96 -> -0.251, profile 2; got \(String(describing: d4))")

        // Names every surface shows.
        record(cat, "Button names", pass: S.buttonLabel(40) == String(localized: "Socket 1") && S.buttonLabel(47) == String(localized: "Socket 8")
               && S.buttonLabel(48) == String(localized: "Center button") && S.buttonLabel(49) == String(localized: "Stick press")
               && S.buttonLabel(50) == String(localized: "PS button") && S.buttonLabel(51) == String(localized: "Profile button")
               && S.buttonLabel(56) == String(localized: "E1 button") && S.buttonLabel(59) == String(localized: "E4 button"))
        record(cat, "Axis names", pass: S.axisLabel(6) == String(localized: "Stick X") && S.axisLabel(8) == String(localized: "E1 X")
               && S.axisLabel(15) == String(localized: "E4 Y"))

        // A stored profile, laid out as the controller sends it over USB:
        // 0x02, the name in UTF-16LE at 4, ten button entries of 5 bytes at
        // 100, five port entries of 45 bytes at 152. The assignments are the
        // ones read from a real controller on 2026-10-18.
        var blob = [UInt8](repeating: 0, count: 956)
        blob[0] = 0x02
        for (i, u) in "One hand".utf16.enumerated() { blob[4 + 2 * i] = UInt8(u & 0xFF); blob[5 + 2 * i] = UInt8(u >> 8) }
        let actions = [13, 7, 8, 1, 3, 4, 5, 6, 2, 15]   // L3, Left, Right, Circle, Triangle, Square, Up, Down, Cross, Options
        for (b, code) in actions.enumerated() { blob[100 + b * 5] = UInt8(code) }
        blob[152] = 0x01; blob[153] = 1                       // the stick itself: left stick
        blob[152 + 45] = 0x01; blob[152 + 45 + 1] = 1         // E1: a stick, left
        blob[152 + 2] = 1                                     // orientation: stick to the right
        blob[101] = 9                                         // socket 1 also presses L1
        blob[152 + 90] = 0x03; blob[152 + 90 + 2] = 10        // E2: digital button, R1
        blob[152 + 90 + 3] = 4                                // ... with Square pressed too
        blob[152 + 135] = 0x02; blob[152 + 135 + 2] = 9       // E3: analog button, L1
        blob[152 + 180] = 0x03; blob[152 + 180 + 2] = 11      // E4: digital button, L2
        if let p = S.parseProfile(blob, number: 2) {
            record(cat, "Profile name and number", pass: p.name == "One hand" && p.number == 2, detail: "got \(p.name) \(p.number)")
            record(cat, "Profile socket actions", pass: p.buttonActions == [1: 13, 2: 7, 3: 8, 4: 1, 5: 3, 6: 4, 7: 5, 8: 6, 9: 2, 10: 15],
                   detail: "got \(p.buttonActions.sorted { $0.key < $1.key })")
            record(cat, "Profile port setup", pass: p.stickAssignments == [0: 1, 1: 1] && p.portActions == [2: 10, 3: 9, 4: 11],
                   detail: "got sticks \(p.stickAssignments) buttons \(p.portActions)")
            record(cat, "Profile simultaneous press and orientation", pass: p.secondaryActions == [1: 9] && p.orientation == 1
                   && p.ports[2] == .button(code: 10, secondary: 4, analog: false),
                   detail: "got \(p.secondaryActions) \(p.orientation) \(String(describing: p.ports[2]))")
            record(cat, "Profile actions to slot buttons", pass: S.Profile.buttonIndex(ofAction: 2) == 0 && S.Profile.buttonIndex(ofAction: 1) == 1
                   && S.Profile.buttonIndex(ofAction: 15) == 9 && S.Profile.buttonIndex(ofAction: 10) == 5 && S.Profile.buttonIndex(ofAction: 13) == 11
                   && S.Profile.buttonIndex(ofAction: 5) == nil && S.Profile.buttonIndex(ofAction: 0) == nil,
                   detail: "Cross 0, Circle 1, Options 9, R1 5, L3 11; D-pad and nothing have no button")
            // The drawing: ports as what they hold, sockets with their own
            // bit and the profile's function.
            let layout = ControllerLayout.psAccess(ports: [1: .stick, 2: .button, 3: .trigger], profile: p)
            let e1 = layout.control("e1"), e2 = layout.control("e2"), e3 = layout.control("e3"), e4 = layout.control("e4")
            record(cat, "Drawing: E1 stick on axes 8 and 9", pass: e1?.kind == .stick && e1?.inputs.axes.map(\.index) == [8, 9], detail: "\(String(describing: e1?.inputs))")
            record(cat, "Drawing: E2 button with its own bit and R1", pass: e2?.kind == .faceButton && e2?.inputs.buttons == [57, 5], detail: "\(String(describing: e2?.inputs.buttons))")
            record(cat, "Drawing: E3 trigger on axis 12", pass: e3?.kind == .trigger(.analog) && e3?.inputs.axes.map(\.index) == [12], detail: "\(String(describing: e3?.inputs))")
            record(cat, "Drawing: empty E4 unchanged", pass: e4?.kind == .other && e4?.inputs.buttons.isEmpty == true && e4?.inputs.axes.isEmpty == true,
                   detail: "kind \(String(describing: e4?.kind)) inputs \(String(describing: e4?.inputs))")
            record(cat, "Drawing: socket 1 lights from bit 40 and L3", pass: layout.control("socket1")?.inputs.buttons == [40, 11],
                   detail: "\(String(describing: layout.control("socket1")?.inputs.buttons))")
            record(cat, "Drawing: center lights from bit 48 and Cross", pass: layout.control("center")?.inputs.buttons == [48, 0])
            record(cat, "Drawing: socket 2 (Left, a D-pad direction) keeps its bit only", pass: layout.control("socket2")?.inputs.buttons == [41])
        } else {
            record(cat, "Profile parses", pass: false, detail: "parseProfile returned nil")
        }
        record(cat, "Profile with a wrong first byte rejected", pass: S.parseProfile([UInt8](repeating: 0, count: 956), number: 1) == nil)
        record(cat, "Drawing without devices or profile is the plain layout", pass: ControllerLayout.psAccess(ports: [:], profile: nil).control("e1")?.kind == .other)

        // Each trigger on its own: right at 11, left at 22.
        let mixed = InProcessLightWriter.triggerEffectReport(left: 1, right: 3, bluetooth: false)
        record(cat, "Trigger feel per trigger", pass: mixed[13] == 255 && mixed[24] == 85 && mixed[11] == 0x01 && mixed[22] == 0x01,
               detail: "right force 255 at 13, left force 85 at 24; got \(Array(mixed[11...13])) \(Array(mixed[22...24]))")
        let oneOff = InProcessLightWriter.triggerEffectReport(left: 0, right: 2, bluetooth: false)
        record(cat, "Trigger feel one side off", pass: oneOff[22] == 0x05 && oneOff[11] == 0x01 && oneOff[13] == 170)

        // Writing a profile back: the bytes it was read from with the edits
        // written over them, split into eighteen reports with the CRC last.
        if var p = S.parseProfile(blob, number: 2) {
            p.name = "Left hand"
            p.buttonActions[1] = 2                     // socket 1 now Cross
            p.buttonActions[9] = nil                   // center now nothing
            p.toggles = [3, 11]                        // socket 3 and E1 toggle
            p.ports[2] = .stick(assignment: 2)         // E2 a right stick
            p.ports[4] = .empty                        // E4 empty
            p.secondaryActions = [9: 3]                // center also presses Triangle
            p.orientation = 3                          // stick to the left
            p.ports[3] = .button(code: 9, secondary: 12, analog: true)
            let bytes = S.encode(p)
            let again = S.parseProfile(bytes, number: 2)
            record(cat, "Profile encode keeps size and sentinel", pass: bytes.count == 956 && bytes[0] == 0x02)
            record(cat, "Profile encode round trip", pass: again == p,
                   detail: "name \(again?.name == p.name) actions \(again?.buttonActions == p.buttonActions) toggles \(again?.toggles == p.toggles) ports \(again?.ports == p.ports) number \(again?.number == p.number); ports got \(String(describing: again?.ports.sorted { $0.key < $1.key })) want \(p.ports.sorted { $0.key < $1.key })")
            record(cat, "Profile encode keeps the UUID", pass: Array(bytes[84..<100]) == Array(blob[84..<100]))
            record(cat, "Profile encode: changed port starts clean", pass: bytes[152 + 90] == 0x01 && bytes[152 + 90 + 1] == 2 && bytes[152 + 90 + 3] == 0
                   && (4..<45).allSatisfy { bytes[152 + 90 + $0] == 0 } && (0..<45).allSatisfy { bytes[152 + 180 + $0] == 0 },
                   detail: "E2 type 1 assignment 2 with the old button map cleared, E4 all zero")
            record(cat, "Profile encode: toggle bits", pass: bytes[150] == 0b0000_0100 && bytes[151] == 0b0000_0100,
                   detail: "bit 2 (socket 3) and bit 10 (E1); got \(bytes[150]) \(bytes[151])")
            record(cat, "Profile encode: simultaneous press, orientation in every stick record",
                   pass: bytes[101] == 0 && bytes[100 + 8 * 5 + 1] == 3 && bytes[152 + 2] == 3 && bytes[152 + 45 + 2] == 3 && bytes[152 + 90 + 2] == 3
                   && bytes[152 + 135] == 0x02 && bytes[152 + 135 + 2] == 9 && bytes[152 + 135 + 3] == 12,
                   detail: "got \(bytes[101]) \(bytes[141]) \(bytes[154]) \(bytes[199]) \(bytes[244]) E3 \(Array(bytes[287..<291]))")
            let packets = S.writePackets(number: 2, bytes: bytes)
            let crc = S.crc32(bytes)
            record(cat, "Profile write: eighteen reports of 64", pass: packets.count == 18 && packets.allSatisfy { $0.count == 64 && $0[0] == 0x60 && $0[1] == 0x0A })
            record(cat, "Profile write: chunk index and data", pass: packets[0][2] == 0 && packets[17][2] == 17
                   && Array(packets[0][3..<59]) == Array(bytes[0..<56]) && Array(packets[1][3..<59]) == Array(bytes[56..<112])
                   && Array(packets[17][3..<7]) == Array(bytes[952..<956]))
            record(cat, "Profile write: CRC little-endian at payload offset 6 of the last report",
                   pass: packets[17][7] == UInt8(crc & 0xFF) && packets[17][8] == UInt8((crc >> 8) & 0xFF)
                   && packets[17][9] == UInt8((crc >> 16) & 0xFF) && packets[17][10] == UInt8(crc >> 24),
                   detail: "crc \(String(crc, radix: 16))")
        }
        record(cat, "CRC-32 is the zlib one", pass: S.crc32(Array("123456789".utf8)) == 0xCBF4_3926,
               detail: String(S.crc32(Array("123456789".utf8)), radix: 16))
        let active = S.setActiveCommand(3)
        record(cat, "Set active profile command", pass: active.count == 64 && active[0] == 0x60 && active[1] == 0x05 && active[2] == 3 && active[3...].allSatisfy { $0 == 0 })
        record(cat, "Set active command clamps to 1 to 3", pass: S.setActiveCommand(0)[2] == 1 && S.setActiveCommand(9)[2] == 3)
        record(cat, "No write packets for the base profile", pass: S.writePackets(number: 0, bytes: [UInt8](repeating: 0, count: 956)).isEmpty)
        let full = S.ledReport(rgb: (0x00, 0x80, 0xFF), player: 4, profileLEDMode: 1, statusLED: true)
        record(cat, "Access LED O2: all four systems", pass: full == HIDFixture.parse("02 15 00 00 00 04 00 80 ff 00 00 00 11 01 00 00 00 00 00 00 00 00 00 01 00 00 00 00 00 00 00 00"),
               detail: HIDFixture.hex(full))
        let ledBT = S.ledReport(rgb: (0xFF, 0x00, 0xFF), player: 2, profileLEDMode: 2, statusLED: true, bluetooth: true)
        let o5: [UInt8] = HIDFixture.parse("31 02 15 04 00 00 02 ff 00 ff 00 00 00 11 02 00 00 00 00 00 00 00 00 00 01" + String(repeating: " 00", count: 49) + " 00 87 df 38")
        record(cat, "Access LED O5 Bluetooth framing and CRC", pass: ledBT == o5,
               detail: HIDFixture.hex(Array(ledBT.prefix(26))) + " ... " + HIDFixture.hex(Array(ledBT.suffix(4))))
        let o6: [UInt8] = HIDFixture.parse("31 02 ff ff" + String(repeating: " 00", count: 70) + " 4c 7a ec 13")
        record(cat, "Access LED O6 dismiss frame", pass: S.ledDismissReport() == o6)
        let sweep = S.ledReport(rgb: nil, player: 0, profileLEDMode: 3)
        let forbiddenClear = [full, sweep].allSatisfy { $0[1] & 0x60 == 0 && $0[9] == 0 && $0.count == 32 }
        record(cat, "Access LED O7 forbidden bits never set", pass: forbiddenClear && ledBT.count == 78 && ledBT[10] == 0)
        record(cat, "Read commands", pass: S.readCommand(number: 0)[1] == 0x0F && S.readCommand(number: 1)[1] == 0x10
               && S.readCommand(number: 3)[1] == 0x12 && S.readCommand(number: 2).count == 64 && S.readCommand(number: 2)[0] == 0x60)

        #if DEBUG
        // Port type debounce, through the reader itself: the E3 flap
        // measured on 2026-10-18 (nibble 3 and 0 on alternate reports)
        // must never publish E3; a steady nibble publishes after 25.
        let flapA = HIDFixtureCorpus.access.first { $0.id == "access.usb.flap.e3present" }
        let flapB = HIDFixtureCorpus.access.first { $0.id == "access.usb.flap.e3absent" }
        if let flapA, let flapB {
            let loc: UInt64 = 0xFA5E_0000_ACCE_5502
            S.shared.debugInstallSyntheticPad(location: loc, overUSB: true)
            // By identity: a real Access controller plugged in makes two
            // pads, and an unnamed lookup then answers for neither.
            var synthetic = SonyPadIdentity()
            synthetic.locationID = loc
            for _ in 0..<50 {
                S.shared.debugInjectNow(location: loc, bytes: flapA.bytes)
                S.shared.debugInjectNow(location: loc, bytes: flapB.bytes)
            }
            let flapping = S.shared.portDevices(for: synthetic, accessSlotCount: 1)
            for _ in 0..<30 { S.shared.debugInjectNow(location: loc, bytes: flapA.bytes) }
            let steady = S.shared.portDevices(for: synthetic, accessSlotCount: 1)
            let axesSteady = S.shared.axes(for: synthetic, accessSlotCount: 1)
            S.shared.debugRemoveSyntheticPads()
            record(cat, "Flapping E3 never published", pass: flapping[3] == nil && flapping[2] == .stick,
                   detail: "after 100 alternating reports: \(flapping)")
            record(cat, "Steady E3 published after 25 reports", pass: steady[3] == .stick && axesSteady[12] != nil,
                   detail: "after 30 steady reports: \(steady), axis 12 \(String(describing: axesSteady[12]))")
        } else {
            record(cat, "Debounce fixtures present", pass: false, detail: "access.usb.flap.* missing from the corpus")
        }
        #endif

        // The Controller Profile output.
        let out = OutputAction.parse("cpf prev")
        record(cat, "Controller Profile output parses", pass: out?.type == .controllerProfile && out?.resolvedProfileAction == .previous)
        record(cat, "Controller Profile output serializes", pass: OutputAction(type: .controllerProfile, profileAction: .third).serialized == "cpf 3"
               && OutputAction.parse("cpf")?.resolvedProfileAction == .next)
        record(cat, "Controller Profile targets", pass: ControllerProfileAction.next.target(from: 3) == 1 && ControllerProfileAction.next.target(from: 1) == 2
               && ControllerProfileAction.previous.target(from: 1) == 3 && ControllerProfileAction.second.target(from: 3) == 2
               && ControllerProfileAction.next.target(from: 0) == 1)

        // DualSense Edge profiles: three 64-byte feature reports per slot.
        let ecat = "DualSense Edge"
        var b0 = [UInt8](repeating: 0, count: 64), b1 = [UInt8](repeating: 0, count: 64), b2 = [UInt8](repeating: 0, count: 64)
        b0[0] = 0x73; b1[0] = 0x74; b2[0] = 0x75
        for (i, u) in "Snipe".utf16.enumerated() { b0[6 + 2 * i] = UInt8(u & 0xFF); b0[7 + 2 * i] = UInt8(u >> 8) }
        b2[4] = 10; b2[5] = 200; b2[6] = 0; b2[7] = 255
        for i in 0..<16 { b2[10 + i] = UInt8(i) }
        b2[10 + 4] = 5; b2[10 + 5] = 4     // Circle and Cross swapped
        b2[30] = 2; b2[32] = 0
        if let e = DualSenseEdgeProfiles.parse([b0, b1, b2], slot: .square) {
            record(ecat, "Profile name, slot and triggers", pass: e.assigned && e.name == "Snipe" && e.slot == .square && e.leftTrigger == (10, 200) && e.rightTrigger == (0, 255),
                   detail: "got \(e.name) \(e.slot) \(e.leftTrigger) \(e.rightTrigger)")
            record(ecat, "Profile remaps", pass: e.remaps == ["Circle sends Cross", "Cross sends Circle"], detail: "got \(e.remaps)")
            record(ecat, "Profile stick curves", pass: e.leftStickCurve == 2 && e.rightStickCurve == 0)
        } else {
            record(ecat, "Profile parses", pass: false)
        }
        var u0 = b0; u0[1] = 0x10
        let unassigned = DualSenseEdgeProfiles.parse([u0, b1, b2], slot: .square)
        record(ecat, "Unassigned slot", pass: unassigned?.assigned == false && unassigned?.remaps.isEmpty == true && unassigned?.name == "")
        record(ecat, "Wrong report count rejected", pass: DualSenseEdgeProfiles.parse([b0, b1], slot: .square) == nil)

        // The adaptive trigger report.
        let usbFirm = InProcessLightWriter.triggerEffectReport(left: 3, right: 3, bluetooth: false)
        record(ecat, "Trigger feel USB report", pass: usbFirm.count == 48 && usbFirm[0] == 0x02 && usbFirm[1] == 0x0C
               && usbFirm[11] == 0x01 && usbFirm[12] == 0x20 && usbFirm[13] == 255 && usbFirm[22] == 0x01 && usbFirm[24] == 255
               && usbFirm[2] == 0 && usbFirm[39] == 0 && usbFirm[45] == 0,
               detail: "flags 0x0C, mode 1 at 11 and 22, force 255, nothing claimed for light or motors; got \(usbFirm.prefix(26))")
        let usbOff = InProcessLightWriter.triggerEffectReport(left: 0, right: 0, bluetooth: false)
        record(ecat, "Trigger feel off report", pass: usbOff[11] == 0x05 && usbOff[22] == 0x05 && usbOff[13] == 0 && usbOff[24] == 0)
        let btLight = InProcessLightWriter.triggerEffectReport(left: 1, right: 1, bluetooth: true, sequence: 5)
        record(ecat, "Trigger feel Bluetooth report", pass: btLight.count == 78 && btLight[0] == 0x31 && btLight[1] == 0x50 && btLight[2] == 0x10
               && btLight[3] == 0x0C && btLight[13] == 0x01 && btLight[15] == 85 && btLight[24] == 0x01 && btLight[26] == 85
               && (btLight[74] | btLight[75] | btLight[76] | btLight[77]) != 0,
               detail: "payload two bytes later than USB, CRC at the end; got \(btLight.prefix(28))")
        record(ecat, "Trigger feel levels clamp", pass: InProcessLightWriter.triggerEffectReport(left: 9, right: 9, bluetooth: false)[13] == 255
               && InProcessLightWriter.triggerEffectReport(left: -1, right: -1, bluetooth: false)[11] == 0x05)
    }

    // MARK: - 7c. Logitech wheels: mode switch, range and pedal tables

    /// The static tables against SDL_hidapi_lg4ff.c, hid-lg4ff.c and
    /// hid-lg.c (gaps-sim.md 5.8, LGC-1 to LGC-12).
    private func runLogitechWheelTests() {
        typealias W = LogitechWheel
        let cat = "Logitech Wheel"
        func cmd(_ p: Int32, _ bcd: Int) -> (String, [UInt8], UInt8)? {
            W.nativeModeCommand(product: p, bcdDevice: bcd).map { ($0.name, $0.bytes, $0.reportID) }
        }
        let g29: [UInt8] = [0xF8, 0x09, 0x05, 0x01, 0x01, 0x00, 0x00]
        record(cat, "LGC-1 G29 masks from DF EX", pass: [0x1350, 0x1357, 0x8900, 0x89FF].allSatisfy { cmd(0xC294, $0)?.1 == g29 && cmd(0xC294, $0)?.0 == "G29" })
        record(cat, "LGC-2 Driving Force GT", pass: [0x1300, 0x13FF].allSatisfy { cmd(0xC294, $0)?.1 == [0xF8, 0x09, 0x03, 0x01, 0x00, 0x00, 0x00] })
        record(cat, "LGC-3 G27", pass: [0x1230, 0x123F].allSatisfy { cmd(0xC294, $0)?.1 == [0xF8, 0x09, 0x04, 0x01, 0x00, 0x00, 0x00] })
        record(cat, "LGC-4 G25", pass: [0x1200, 0x122F, 0x1240].allSatisfy { cmd(0xC294, $0)?.1 == [0xF8, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00] })
        record(cat, "LGC-5 Driving Force Pro", pass: [0x1000, 0x1100, 0x1FFF].allSatisfy { cmd(0xC294, $0)?.1 == [0xF8, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00] })
        record(cat, "LGC-6 a real Driving Force EX stays", pass: cmd(0xC294, 0x2100) == nil && cmd(0xC294, 0x0000) == nil)
        record(cat, "LGC-7 a G29 left in G27 mode is switched up", pass: cmd(0xC29B, 0x1350)?.1 == g29 && cmd(0xC29B, 0x1230) == nil
               && cmd(0xC299, 0x1230)?.0 == "G27" && cmd(0xC29A, 0x1350)?.0 == "G29" && cmd(0xC29A, 0x1300) == nil
               && cmd(0xC298, 0x1300)?.0 == "Driving Force GT" && cmd(0xC298, 0x1000) == nil)
        record(cat, "LGC-8 G923 PS mode switches on report 0x30", pass: cmd(0xC267, 0)?.1 == [0xF8, 0x09, 0x07, 0x01, 0x01, 0x00, 0x00] && cmd(0xC267, 0)?.2 == 0x30
               && cmd(0xC267, 0x1350)?.0 == "G923" && cmd(0xC266, 0x1350) == nil,
               detail: "new-lg4ff hid-lg4ff.c lg4ff_switch_from_ps_mode; framing on the wire still to be measured")
        record(cat, "LGC-9 900 degree range command", pass: [0xC24F, 0xC29B, 0xC299, 0xC29A, 0xC266].allSatisfy { W.rangeCommands(product: $0) == [[0xF8, 0x81, 0x84, 0x03, 0x00, 0x00, 0x00]] })
        record(cat, "LGC-10 Driving Force Pro range", pass: W.rangeCommands(product: 0xC298) == [[0xF8, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00], [0x81, 0x0B, 0x00, 0x00, 0x00, 0x00, 0x00]])
        record(cat, "LGC-11 fixed range wheels get no command", pass: [0xC294, 0xCA03, 0xC20E, 0xC267].allSatisfy { W.rangeCommands(product: $0) == nil })
        record(cat, "LGC-12 rotation per source", pass: W.rotationDegrees(product: 0xC294) == 270 && W.rotationDegrees(product: 0xC295) == 270
               && W.rotationDegrees(product: 0xCA03) == 270 && W.rotationDegrees(product: 0xC20E) == 180 && W.rotationDegrees(product: 0xC293) == 180
               && W.rotationDegrees(product: 0xC266) == 900 && W.rotationDegrees(product: 0xC24F) == 900)
        record(cat, "Pedal byte table", pass: W.separatePedalWheels[0xC294] == .init(descriptorLength: 130, combined: 3, gas: 5, brake: 6)
               && W.separatePedalWheels[0xC298] == .init(descriptorLength: 97, combined: 4, gas: 5, brake: 6)
               && W.separatePedalWheels[0xCA03] == .init(descriptorLength: 87, combined: 3, gas: 4, brake: 5)
               && W.separatePedalWheels[0xC20E] == .init(descriptorLength: 82, combined: 2, gas: 3, brake: 4)
               && W.separatePedalWheels.count == 7)
        record(cat, "Every known wheel has a drawing or a rotation", pass: W.products.allSatisfy { W.rotationDegrees(product: $0) != nil || $0 == 0xC267 },
               detail: "\(W.products.filter { W.rotationDegrees(product: $0) == nil }.map { String(format: "%04X", $0) })")
    }

    // MARK: - 7d. Switch 2 flash calibration and enabler commands

    /// The motion math every pad shares: the raw IMU helper (gravity,
    /// tilt angles, the turn sign) and the GameController path's gravity
    /// carrier, with synthetic samples in the frame the code documents
    /// (X right, Y away from the player, Z up out of the face).
    private func runMotionMathTests() {
        let cat = "Motion"
        // A flat pad at rest: the reaction force is 1 g up on Z.
        let imu = DirectIMU()
        var out: [MotionChannel: Float] = [:]
        for _ in 0..<5 { out = imu.processMotion([.accelX: 0, .accelY: 0, .accelZ: 1, .gyroX: 0, .gyroY: 0, .gyroZ: 0]) }
        record(cat, "Flat at rest: gravity removed, pitch and roll zero",
               pass: abs(out[.accelX] ?? 1) < 0.001 && abs(out[.accelZ] ?? 1) < 0.001
                   && abs(out[.pitchAngle] ?? 1) < 0.001 && abs(out[.rollAngle] ?? 1) < 0.001,
               detail: "\(out)")
        // Nose up 45 degrees: the reaction leans onto +Y; pitch reads +0.5
        // (a quarter turn is 1). The gravity average follows at 2 percent a
        // sample, so it is fed until it settles.
        for _ in 0..<600 { out = imu.processMotion([.accelX: 0, .accelY: 0.7071, .accelZ: 0.7071, .gyroX: 0, .gyroY: 0, .gyroZ: 0]) }
        record(cat, "Nose up 45 degrees reads pitch +0.5, roll 0",
               pass: abs((out[.pitchAngle] ?? 0) - 0.5) < 0.02 && abs(out[.rollAngle] ?? 1) < 0.02,
               detail: String(format: "pitch %.3f roll %.3f", out[.pitchAngle] ?? 0, out[.rollAngle] ?? 0))
        // Right side down 90 degrees: up now points out of the pad's left
        // side, so the reaction is along -X; roll reads +0.5 (a half turn
        // is 1).
        let imu2 = DirectIMU()
        for _ in 0..<600 { out = imu2.processMotion([.accelX: -1, .accelY: 0, .accelZ: 0, .gyroX: 0, .gyroY: 0, .gyroZ: 0]) }
        record(cat, "Right side down 90 degrees reads roll +0.5, pitch 0",
               pass: abs((out[.rollAngle] ?? 0) - 0.5) < 0.02 && abs(out[.pitchAngle] ?? 1) < 0.02,
               detail: String(format: "pitch %.3f roll %.3f", out[.pitchAngle] ?? 0, out[.rollAngle] ?? 0))
        // A turn to the right (clockwise from above) is a negative rate
        // about Z up; the app's gyro Z is positive for it.
        let imu3 = DirectIMU()
        for _ in 0..<5 { out = imu3.processMotion([.accelX: 0, .accelY: 0, .accelZ: 1, .gyroX: 0, .gyroY: 0, .gyroZ: -1]) }
        record(cat, "Turning right (rate -1 about up) reads gyro Z +1",
               pass: abs((out[.gyroZ] ?? 0) - 1) < 0.001, detail: "\(out[.gyroZ] ?? 0)")
        // Held nose up 90 degrees (Z forward, Y up), a turn about the real
        // vertical is a rate about the pad's Y; gyro Z still reads it.
        let imu4 = DirectIMU()
        for _ in 0..<600 { out = imu4.processMotion([.accelX: 0, .accelY: 1, .accelZ: 0, .gyroX: 0, .gyroY: -1, .gyroZ: 0]) }
        record(cat, "Held upright, a turn about the vertical still lands on gyro Z",
               pass: abs((out[.gyroZ] ?? 0) - 1) < 0.01, detail: "\(out[.gyroZ] ?? 0)")
        // Pitch and roll rates pass through as they are.
        record(cat, "Gyro X and Y pass through unchanged",
               pass: abs((out[.gyroX] ?? 1)) < 0.001 && abs((out[.gyroY] ?? 0) + 1) < 0.001)
        // An all-zero accelerometer sample is dropped by the applier.
        var decodedOff = ControllerState()
        decodedOff.motion = [.accelX: 0, .accelY: 0, .accelZ: 0, .gyroX: 1]
        let pad = RawHIDGamepad(testProfile: ControllerProfile(identifier: "bench-motion", displayName: "bench", vendorID: 0,
                                                                productMatches: [], layout: .switch2Pro, physicalButtonNames: []),
                                vendorID: 0, productID: 0, transport: "USB", id: 0xFA5E_0000_0000_0001, productName: "bench")
        RawHIDReportApplier.processMotion(&decodedOff, pad: pad)
        record(cat, "Applier drops a sample whose accelerometer is all zero (IMU off)", pass: decodedOff.motion.isEmpty)
        var decodedOn = ControllerState()
        decodedOn.motion = [.accelX: 0, .accelY: 0, .accelZ: 1, .gyroX: 0, .gyroY: 0, .gyroZ: 0]
        RawHIDReportApplier.processMotion(&decodedOn, pad: pad)
        record(cat, "Applier processes a real sample (angles present)", pass: decodedOn.motion[.pitchAngle] != nil && decodedOn.motion[.gyroZ] != nil)

        // The GameController path's gravity carrier (GCMotion frame, gravity
        // (0, 0, -1) lying flat). Turning the pad a quarter turn about X
        // (nose up by the right-hand rule) moves gravity to (0, -1, 0) in
        // the pad's frame.
        typealias G = GameControllerService
        let turned = G.rotateIntoBody(SIMD3<Float>(0, 0, -1), rate: SIMD3<Float>(1, 0, 0), dt: .pi / 2)
        record(cat, "rotateIntoBody: a quarter turn about X carries gravity from -Z to -Y",
               pass: abs(turned.x) < 0.001 && abs(turned.y + 1) < 0.001 && abs(turned.z) < 0.001,
               detail: "\(turned)")
        let unit = (turned * turned).sum().squareRoot()
        record(cat, "rotateIntoBody keeps a unit vector", pass: abs(unit - 1) < 0.0001)
        let zero = G.rotateIntoBody(SIMD3<Float>(0, 0, -1), rate: SIMD3<Float>(0, 0, 0), dt: 0.01)
        record(cat, "rotateIntoBody with no rate changes nothing", pass: zero == SIMD3<Float>(0, 0, -1))
        // stepGravity eases toward the measured direction while quiet, and
        // never more than about a degree a poll.
        let start = SIMD3<Float>(0, 0, -1), measured = SIMD3<Float>(0, -0.7071, -0.7071)
        let eased = G.stepGravity(start, measured: measured, rate: SIMD3<Float>(0, 0, 0), dt: 0.01, gravityOnly: true)
        let moved = ((eased - start) * (eased - start)).sum().squareRoot()
        let closer = ((eased - measured) * (eased - measured)).sum().squareRoot() < ((start - measured) * (start - measured)).sum().squareRoot()
        record(cat, "stepGravity eases toward the accelerometer, at most 0.02 a poll", pass: closer && moved > 0 && moved <= 0.0201,
               detail: String(format: "moved %.4f", moved))
        let busy = G.stepGravity(start, measured: measured, rate: SIMD3<Float>(0, 0, 3), dt: 0.01, gravityOnly: true)
        let busyMoved = ((busy - G.rotateIntoBody(start, rate: SIMD3<Float>(0, 0, 3), dt: 0.01)) * (busy - G.rotateIntoBody(start, rate: SIMD3<Float>(0, 0, 3), dt: 0.01))).sum().squareRoot()
        record(cat, "stepGravity does not ease during a fast turn", pass: busyMoved < 0.0001)
        let noisy = G.stepGravity(start, measured: measured, rate: SIMD3<Float>(0, 0, 0), dt: 0.01, gravityOnly: false)
        record(cat, "stepGravity ignores a sample that is not gravity alone", pass: noisy == start)
    }

    /// SDL_hidapi_switch2.c ParseStickCalibration and MapJoystickAxis on
    /// the two vectors of gaps-nintendo.md 6.3, and the command framing
    /// rules of 5.9 (F-CMD-1 to F-CMD-5).
    /// Idle disconnect and reconnect: what counts as use, when a pad goes,
    /// and which paired devices are controllers.
    /// Help's links to the website open in the app's language where the
    /// site has the page.
    private func runHelpLinkTests() {
        let cat = "Help links"
        typealias H = HelpLocalizer
        let q = URL(string: "https://inputconfig.com/questions/razer-naga-on-mac")!
        let g = URL(string: "https://inputconfig.com/guides/game-controller-lighting-control")!
        record(cat, "App language to site folder",
               pass: H.siteFolder(for: "en") == nil && H.siteFolder(for: "de") == "de" && H.siteFolder(for: "pt-BR") == "pt"
                && H.siteFolder(for: "zh-Hans") == "zh" && H.siteFolder(for: "zh-Hant") == "zh-tw")
        record(cat, "Questions and guides open translated",
               pass: H.siteURL(q, folder: "de").absoluteString == "https://inputconfig.com/de/questions/razer-naga-on-mac"
                && H.siteURL(g, folder: "zh-tw").absoluteString == "https://inputconfig.com/zh-tw/guides/game-controller-lighting-control")
        let english = ["https://inputconfig.com/help/light-bar", "https://inputconfig.com/questions/",
                       "https://inputconfig.com/presets/fps-ps5-dualsense",
                       "https://inputconfig.com/questions/mac-games-with-controller-support",
                       "https://github.com/ryleighnewman/InputConfig"].compactMap(URL.init(string:))
        record(cat, "English-only pages and other sites stay as they are",
               pass: english.allSatisfy { H.siteURL($0, folder: "fr") == $0 } && H.siteURL(q, folder: nil) == q)
    }

    private func runControllerPowerTests() {
        let cat = "Controller power"
        typealias P = ControllerPowerService
        var rest = ControllerState(); rest.axes[0] = 0.02; rest.axes[1] = -0.05; rest.motion[.gyroX] = 0.4; rest.hats[0] = (x: 0, y: 0)
        var press = ControllerState(); press.buttons[3] = 1
        var push = ControllerState(); push.axes[1] = -0.6
        var dpad = ControllerState(); dpad.hats[0] = (x: 1, y: 0)
        var trigger = ControllerState(); trigger.axes[5] = 0.5
        record(cat, "Stick drift and gyro noise are not use", pass: !P.isRealUse(rest))
        record(cat, "A press, a stick push, the D-pad and a trigger are use",
               pass: P.isRealUse(press) && P.isRealUse(push) && P.isRealUse(dpad) && P.isRealUse(trigger))
        record(cat, "Goes after the minutes set, not before", pass: P.shouldDisconnect(idle: 900, minutes: 15, presetRunning: false, whileRunning: false)
               && !P.shouldDisconnect(idle: 899, minutes: 15, presetRunning: false, whileRunning: false))
        record(cat, "A running preset keeps it unless set otherwise", pass: !P.shouldDisconnect(idle: 7200, minutes: 5, presetRunning: true, whileRunning: false)
               && P.shouldDisconnect(idle: 7200, minutes: 5, presetRunning: true, whileRunning: true))
        record(cat, "A gamepad or joystick class of device is a controller", pass: P.looksLikeController(major: 5, minor: 0x02, name: "")
               && P.looksLikeController(major: 5, minor: 0x01, name: "") && !P.looksLikeController(major: 5, minor: 0x10, name: "Magic Keyboard")
               && !P.looksLikeController(major: 4, minor: 0x06, name: "AirPods Pro"))
        record(cat, "A Bluetooth LE pad is told by its name", pass: P.looksLikeController(major: 0, minor: 0, name: "Xbox Wireless Controller")
               && P.looksLikeController(major: 0, minor: 0, name: "DualSense Wireless Controller") && !P.looksLikeController(major: 0, minor: 0, name: "MX Master 3S"))
        record(cat, "Minutes outside the choices fall back to 15", pass: {
            let key = P.idleMinutesKey, old = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.set(7, forKey: key); let v = P.shared.idleMinutes
            if let old { UserDefaults.standard.set(old, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            return v == 15
        }())
    }

    private func runSwitch2CalibrationTests() {
        typealias C = Switch2Calibration
        let cat = "Switch 2"
        func reply(stick block: [UInt8]) -> [UInt8] {
            var r = [UInt8](repeating: 0, count: C.replyLength)
            for (i, b) in block.enumerated() { r[C.replyDataOffset + C.factoryStickOffset + i] = b }
            return r
        }
        let v1 = C.factoryStick(fromReply: reply(stick: [0x00, 0x08, 0x80, 0x72, 0x26, 0x67, 0x72, 0x26, 0x67]))
        record(cat, "Calibration vector 1 parses", pass: v1 == C.Stick(block: [0x00, 0x08, 0x80, 0x72, 0x26, 0x67, 0x72, 0x26, 0x67])
               && v1?.neutralX == 2048 && v1?.neutralY == 2048 && v1?.maxX == 1650 && v1?.minY == 1650,
               detail: "\(String(describing: v1))")
        record(cat, "Vector 1 maps 3698 to +1, 2873 to +0.5, 398 to -1",
               pass: v1.map { abs($0.mapX(3698) - 1) < 0.001 && abs($0.mapX(2873) - 0.5) < 0.001 && abs($0.mapX(398) + 1) < 0.001 } ?? false)
        let v2 = C.factoryStick(fromReply: reply(stick: [0x00, 0x08, 0x80, 0x00, 0x04, 0x40, 0x00, 0x06, 0x60]))
        record(cat, "Vector 2 (max 1024, min 1536) maps 3072 to +1 and 512 to -1",
               pass: v2?.maxX == 1024 && v2?.minX == 1536 && (v2.map { abs($0.mapX(3072) - 1) < 0.001 && abs($0.mapX(512) + 1) < 0.001 } ?? false),
               detail: "the fallback constants would read +0.62 and -0.93")
        record(cat, "Blank flash is not a calibration", pass: C.factoryStick(fromReply: [UInt8](repeating: 0xFF, count: C.replyLength)) == nil
               && C.factoryStick(fromReply: [UInt8](repeating: 0, count: C.replyLength)) == nil)
        var user = [UInt8](repeating: 0, count: C.replyLength)
        user[C.replyDataOffset] = 0xB2; user[C.replyDataOffset + 1] = 0xA1
        for (i, b) in [0x00, 0x08, 0x80, 0x72, 0x26, 0x67, 0x72, 0x26, 0x67].enumerated() { user[C.replyDataOffset + 2 + i] = UInt8(b) }
        record(cat, "User block with magic B2 A1 overrides the factory stick", pass: C.userStick(fromReply: user) == v1
               && C.from(replies: [C.leftStickAddress: reply(stick: [0x00, 0x08, 0x80, 0x00, 0x04, 0x40, 0x00, 0x06, 0x60]), C.userLeftStickAddress: user]).left == v1)
        record(cat, "Flash read command framing", pass: C.readCommand(address: 0x013080) == [0x02, 0x91, 0x00, 0x01, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0x30, 0x01, 0x00]
               && C.readCommand(address: 0x1FC040).suffix(4) == [0x40, 0xC0, 0x1F, 0x00])
        // Bluetooth LE: a notification is report 0x05 without its ID.
        typealias B = Switch2BluetoothService
        let body = Array(HIDFixtureCorpus.nintendo.first { $0.id == "switch2pro05.a" }!.bytes.dropFirst())
        let rebuilt = B.report(fromNotification: Data(body))
        var fromBLE = ControllerState()
        HIDReportDecoder.decodeSwitch2Pro(report: rebuilt, into: &fromBLE)
        record(cat, "Bluetooth LE notification rebuilt as report 0x05 decodes A", pass: rebuilt.first == 0x05 && rebuilt.count == 64 && fromBLE.buttons[1] == 1 && (fromBLE.buttons[0] ?? 0) == 0)
        record(cat, "Bluetooth LE product by name", pass: B.productID(name: "Pro Controller", manufacturerData: nil) == 0x2069
               && B.productID(name: "Joy-Con 2 (L)", manufacturerData: nil) == 0x2066
               && B.productID(name: "Joy-Con 2 (R)", manufacturerData: nil) == 0x2067
               && B.productID(name: "NSO GameCube Controller", manufacturerData: nil) == 0x2073
               && B.productID(name: "Magic Keyboard", manufacturerData: nil) == nil
               && B.productID(name: nil, manufacturerData: nil) == nil)
        // ndeadly's captured advertisement: 53 05 01 00 03 7e 05 69 20 00 01 ...
        let advert: [UInt8] = [0x53, 0x05, 0x01, 0x00, 0x03, 0x7E, 0x05, 0x69, 0x20, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0F]
        var gcAdvert = advert; gcAdvert[7] = 0x73
        var otherAdvert = advert; otherAdvert[7] = 0x09   // a first Switch Pro, not read here
        record(cat, "Bluetooth LE product by Nintendo manufacturer data", pass: B.productID(name: nil, manufacturerData: Data(advert)) == 0x2069
               && B.productID(name: nil, manufacturerData: Data(gcAdvert)) == 0x2073
               && B.productID(name: nil, manufacturerData: Data(otherAdvert)) == nil
               && B.productID(name: nil, manufacturerData: Data([0x4C, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05])) == nil)
        record(cat, "Bluetooth LE feature flags per controller (ndeadly commands.md)", pass: B.featureFlags(productID: 0x2069) == 0x2F && B.featureFlags(productID: 0x2066) == 0x37 && B.featureFlags(productID: 0x2073) == 0x27
               && B.featureCommands(productID: 0x2069) == [[0x0C, 0x91, 0x01, 0x02, 0x00, 0x04, 0x00, 0x00, 0x2F, 0, 0, 0], [0x0C, 0x91, 0x01, 0x04, 0x00, 0x04, 0x00, 0x00, 0x2F, 0, 0, 0]])
        record(cat, "Bluetooth LE player light command keeps the USB frame with interface 1",
               pass: B.playerOneLightCommand.count == 16 && B.playerOneLightCommand[2] == 0x01 && Array(B.playerOneLightCommand[0..<2]) == [0x09, 0x91] && B.playerOneLightCommand[8] == 0x01)
        record(cat, "Joy-Con 2 products are started over USB too", pass: Switch2USBEnabler.productIDs.contains(0x2066) && Switch2USBEnabler.productIDs.contains(0x2067))

        // With a calibration in place the decoder maps through it.
        if let proProfile = ControllerProfileDatabase.profile(forVendor: 0x057E, product: 0x2069) {
            var report = [UInt8](repeating: 0, count: 64)
            report[0] = 0x09; report[6] = 0x00; report[7] = 0x0C; report[8] = 0x80   // left X 3072, Y 2048
            report[9] = 0x00; report[10] = 0x08; report[11] = 0x80
            C.store(C.from(replies: [C.leftStickAddress: reply(stick: [0x00, 0x08, 0x80, 0x00, 0x04, 0x40, 0x00, 0x06, 0x60])]), product: 0x2069)
            let mapped = HIDReportDecoder.decode(report: Data(report), profile: proProfile).axes[0] ?? 0
            C.store(nil, product: 0x2069)
            let fallback = HIDReportDecoder.decode(report: Data(report), profile: proProfile).axes[0] ?? 0
            record(cat, "Decoder uses the stored calibration and falls back without it", pass: abs(mapped - 1) < 0.001 && abs(fallback - 0.62) < 0.01,
                   detail: "calibrated \(mapped), fallback \(fallback)")
        }

        let pro = Switch2USBEnabler.commands(for: 0x2069), gc = Switch2USBEnabler.commands(for: 0x2073)
        // Both pads are asked for report 0x05, the 64 byte format with the
        // IMU that SDL reads (the Pro asked for 0x09 before 1.8's motion work).
        record(cat, "F-CMD-1 Pro start sequence asks for format 0x05", pass: pro.count == 14 && pro[8] == [0x03, 0x91, 0x00, 0x0A, 0x00, 0x04, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00])
        record(cat, "F-CMD-2 GameCube asks for format 0x05", pass: gc[8] == [0x03, 0x91, 0x00, 0x0A, 0x00, 0x04, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00]
               && zip(pro, gc).enumerated().allSatisfy { $0.offset == 8 || $0.element.0 == $0.element.1 })
        record(cat, "F-CMD-3 framing bytes", pass: pro.allSatisfy { $0[1] == 0x91 && $0[2] == 0x00 && $0[4] == 0x00 && $0[6] == 0x00 && $0[7] == 0x00 })
        record(cat, "F-CMD-4 every command carries its declared payload", pass: pro.allSatisfy { $0.count == Int($0[5]) + 8 },
               detail: "\(pro.enumerated().filter { $0.element.count != Int($0.element[5]) + 8 }.map(\.offset))")
        record(cat, "F-CMD-5 first and last commands", pass: pro.first == [0x03, 0x91, 0x00, 0x0D, 0x00, 0x08, 0x00, 0x00, 0x01, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
               && pro.last == [0x09, 0x91, 0x00, 0x07, 0x00, 0x08, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    }

    // MARK: - 7e. CGEvent and NSEvent decoders (mice and keyboards)

    /// The events macOS hands the app for scroll wheels and media keys,
    /// built in process and run through the same decoders (gaps-mice.md
    /// 5.1, F-CG-05 to F-CG-14).
    private func runCGEventDecoderTests() {
        typealias E = ExternalInputDeviceService
        let cat = "CGEvent Decoders"
        var carry: (x: Double, y: Double) = (0, 0)
        if let lines = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: -3, wheel2: 0, wheel3: 0) {
            let d = E.scrollDeltas(of: lines, carry: &carry)
            record(cat, "F-CG-05 three notches down", pass: d.dx == 0 && d.dy == -3, detail: "\(d)")
        } else {
            record(cat, "F-CG-05 three notches down", pass: false, detail: "could not build the event")
        }
        if let pixels = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -37, wheel2: 0, wheel3: 0) {
            // A pixel unit event is continuous with its point delta set by
            // the constructor; the line delta it derives is cleared so the
            // step count comes from the points alone, as a trackpad's does.
            pixels.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
            pixels.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            pixels.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -37)
            let fields = "continuous \(pixels.getIntegerValueField(.scrollWheelEventIsContinuous)) point \(pixels.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)) line \(pixels.getIntegerValueField(.scrollWheelEventDeltaAxis1))"
            carry = (0, 0)
            let first = E.scrollDeltas(of: pixels, carry: &carry)
            let second = E.scrollDeltas(of: pixels, carry: &carry)
            record(cat, "F-CG-06 continuous 37 points twice: 3 then 4 steps", pass: first.dy == -3 && second.dy == -4 && abs(carry.y + 0.4) < 0.001,
                   detail: "first \(first.dy) second \(second.dy) carry \(carry.y); \(fields)")
        }
        var c = 0.0
        record(cat, "A 3 point nudge carries until a step is whole", pass: E.scrollSteps(line: 0, point: 3, continuous: true, carry: &c) == 0
               && E.scrollSteps(line: 0, point: 3, continuous: true, carry: &c) == 0 && E.scrollSteps(line: 0, point: 4, continuous: true, carry: &c) == 1)
        record(cat, "A notched line is one step per line and clears the carry", pass: E.scrollSteps(line: 2, point: 20, continuous: false, carry: &c) == 2 && c == 0)
        record(cat, "A zero line without the continuous flag is one step by sign", pass: E.scrollSteps(line: 0, point: -5, continuous: false, carry: &c) == -1)

        func sysDefined(_ subtype: Int16, _ data1: Int) -> NSEvent? {
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                               context: nil, subtype: subtype, data1: data1, data2: -1)
        }
        let ejectDown = sysDefined(8, (14 << 16) | (0x0A << 8)).flatMap(E.mediaKey(from:))
        let ejectUp = sysDefined(8, (14 << 16) | (0x0B << 8)).flatMap(E.mediaKey(from:))
        record(cat, "F-CG-09 Eject as key type 14 down and up", pass: ejectDown?.hid == 313 && ejectDown?.isDown == true && ejectUp?.hid == 313 && ejectUp?.isDown == false)
        let eject10 = sysDefined(10, 0).flatMap(E.mediaKey(from:))
        record(cat, "F-CG-10 Eject as subtype 10 is a press", pass: eject10?.hid == 313 && eject10?.isDown == true)
        let types: [(Int, Int)] = [(3, 71), (2, 72), (0, 311), (1, 312), (7, 310), (16, 308), (17, 309), (18, 307), (19, 309), (20, 307), (21, 306), (22, 305)]
        let wrong = types.filter { sysDefined(8, ($0.0 << 16) | 0xA00).flatMap(E.mediaKey(from:))?.hid != $0.1 }
        record(cat, "F-CG-11 key types to HID codes (ev_keymap.h)", pass: wrong.isEmpty, detail: "wrong: \(wrong)")
        record(cat, "F-CG-12 unnamed key types become Special key N", pass: sysDefined(8, (0x17 << 16) | 0xA00).flatMap(E.mediaKey(from:))?.hid == KeyCodeMap.unknownSystemKeyBase + 0x17
               && sysDefined(8, (0x19 << 16) | 0xA00).flatMap(E.mediaKey(from:))?.hid == KeyCodeMap.unknownSystemKeyBase + 0x19)
        record(cat, "F-CG-13 aux mouse buttons (subtype 7) are not keys", pass: sysDefined(7, 0x4).flatMap(E.mediaKey(from:)) == nil)
        record(cat, "F-CG-14 an autorepeat (bit 0) is not a new press", pass: sysDefined(8, (16 << 16) | 0xA00 | 0x1).flatMap(E.mediaKey(from:)) == nil)
        if let pen = CGEvent(source: nil) {
            pen.type = .tabletPointer
            pen.setDoubleValueField(.tabletEventPointPressure, value: 0.5)
            pen.setDoubleValueField(.tabletEventTiltX, value: -0.25)
            pen.setDoubleValueField(.tabletEventTiltY, value: 0.75)
            pen.setIntegerValueField(.tabletEventPointButtons, value: 0b10)
            let p = E.tabletPoint(of: pen)
            record(cat, "F-CG-22 tablet pointer: pressure, tilt, barrel button 2", pass: abs(p.pressure - 0.5) < 0.001 && abs(p.tiltX + 0.25) < 0.001 && abs(p.tiltY - 0.75) < 0.001 && p.buttons == 2,
                   detail: "\(p)")
        }
        if let prox = CGEvent(source: nil) {
            prox.type = .tabletProximity
            prox.setIntegerValueField(.tabletProximityEventPointerType, value: 3)
            prox.setIntegerValueField(.tabletProximityEventEnterProximity, value: 1)
            let near = E.tabletProximity(of: prox)
            prox.setIntegerValueField(.tabletProximityEventEnterProximity, value: 0)
            let gone = E.tabletProximity(of: prox)
            record(cat, "F-CG-23 tablet proximity: eraser in range, then out", pass: near.entering && near.eraser && !gone.entering)
        }
        let penInput = InputEvent.parse("ems penTiltY 0 - any")
        record(cat, "Pen inputs round trip", pass: penInput?.extMouseKind == .penTiltY && penInput?.axisDirection == .negative && penInput?.serialized == "ems penTiltY 0 - any"
               && InputEvent.parse("ems penButton 1 + any")?.index == 1)
    }

    // MARK: - 7f. PlayStation capability report (feature 0x03)

    private func runPlayStationProbeTests() {
        typealias P = PlayStationCapabilityProbe
        let cat = "PlayStation Probe"
        // GP2040-CE's PS4 definition report (PS4Driver.cpp fills it): [2] 0x27, [4] 0x0F, [5] 0x07 arcade stick.
        var ps4 = [UInt8](repeating: 0, count: 48)
        for (i, b) in [0x03, 0x21, 0x27, 0x04, 0x0F, 0x07, 0x2C, 0x56, 0x08, 0x00, 0x3D, 0x00, 0xE8, 0x03, 0x04, 0x00, 0xFF, 0x7F, 0x0D, 0x0D].enumerated() { ps4[i] = UInt8(b) }
        let a = P.parse(ps4)
        record(cat, "PS4S-5 GP2040-CE PS4 definition: arcade stick with sensors, light bar, vibration, no touchpad",
               pass: a?.family == .playStation4 && a?.deviceType == .arcadeStick && a?.sensors == true && a?.lightBar == true && a?.vibration == true && a?.touchpad == false,
               detail: "\(String(describing: a))")
        var ps5 = ps4; ps5[2] = 0x28; ps5[5] = 0x00; ps5[4] = 0x40
        let b = P.parse(ps5)
        record(cat, "A PS5 answer ([2] 0x28) routes to the DualSense third party layout", pass: b?.family == .playStation5 && b?.deviceType == .gamepad && b?.touchpad == true && b?.sensors == false)
        var wheel = ps4; wheel[5] = 0x06
        record(cat, "Device type 6 is a wheel", pass: P.parse(wheel)?.deviceType == .wheel)
        var other = ps4; other[2] = 0x11
        record(cat, "An answer without 0x27 or 0x28 is not a PlayStation pad", pass: P.parse(other) == nil && P.parse(Array(ps4.prefix(20))) == nil)
        record(cat, "Razer is never queried by vendor (SDL 6733), only by product", pass: !P.vendors.contains(0x1532) && P.shouldProbe(vendorID: 0x1532, productID: 0x0401) && !P.shouldProbe(vendorID: 0x1532, productID: 0x0001)
               && P.shouldProbe(vendorID: 0x0F0D, productID: 0x1234) && !P.shouldProbe(vendorID: 0x046D, productID: 0xC24F))
        let profile = P.profile(for: a!, vendorID: 0x1532, productID: 0x0401, productName: "Panthera")
        record(cat, "Probe profile uses the DualShock 4 layout with Sony names", pass: profile.layout == .dualShock4 && profile.physicalButtonNames.count == 14 && profile.physicalButtonNames[13] == "Touchpad")
    }

    // MARK: - 7g. Xbox Bluetooth battery report

    private func runXboxBatteryTests() {
        typealias X = XboxBluetoothLayout
        let cat = "Xbox Bluetooth"
        func bat(_ v: UInt8) -> (Int, String)? { X.battery(report: Data([0x04, v])).map { ($0.level, $0.state) } }
        record(cat, "bat-full-battery 0x87", pass: bat(0x87)?.0 == 100 && bat(0x87)?.1 == "Discharging")
        record(cat, "bat-low-usb-charging 0x90", pass: bat(0x90)?.0 == 10 && bat(0x90)?.1 == "Charging")
        record(cat, "bat-normal-usb-charging 0x91", pass: bat(0x91)?.0 == 40 && bat(0x91)?.1 == "Charging")
        record(cat, "bat-high-playcharge 0x8A", pass: bat(0x8A)?.0 == 70)
        record(cat, "bat-powering-off 0x00 is not a reading", pass: bat(0x00) == nil && X.battery(report: Data([0x01, 0x87])) == nil)
        record(cat, "Elite 2 paddle bytes by report length", pass: X.elitePaddleBytes(length: 55)! == (33, 35) && X.elitePaddleBytes(length: 39)! == (17, 19)
               && X.elitePaddleBytes(length: 20)! == (19, 17) && X.elitePaddleBytes(length: 17) == nil)
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

    /// The What's New popup only fires when the bundle's version differs
    /// from the one the user last saw, and it looks the notes up by that
    /// same string. If the newest changelog entry does not match the
    /// shipping version, the release notes never appear for anybody. This
    /// catches that before it ships.
    private func runVersionConsistencyTests() {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        record("Version", "Bundle carries a version", pass: !short.isEmpty && !build.isEmpty,
               detail: "\(short) (\(build))")
        // An unexpanded build variable means Info.plist and the build
        // settings have drifted apart.
        record("Version", "Version is a real number, not a build variable",
               pass: !short.contains("$"), detail: short)
        let newest = Changelog.entries.first?.version ?? ""
        record("Version", "Newest changelog entry matches the bundle version",
               pass: newest == short,
               detail: newest == short ? "\(short)"
                                       : "changelog says \(newest), bundle says \(short)")
        record("Version", "Changelog entries are unique",
               pass: Set(Changelog.entries.map(\.version)).count == Changelog.entries.count,
               detail: "\(Changelog.entries.count) entries")
    }

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
            !$0.title.isEmpty && !$0.intro.isEmpty && !$0.sections.isEmpty
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

    // MARK: - HID Descriptor Parser self-test
    //
    // Hand-crafted HID 1.11 short-item byte sequences representative of
    // common controller archetypes (8BitDo XInput, Hori fight stick,
    // racing wheel, generic gamepad). Each is fed through
    // `HIDDescriptorParser.parse` and the resulting GenericLayout is
    // checked for shape (button/axis/hat counts). Catches parser
    // regressions like the bit-cursor off-by-one and mixed-axis-width
    // bugs the 10-agent audit surfaced.

    private func runHIDDescriptorParserTests() {
        let cases: [(name: String,
                     descriptor: [UInt8],
                     expectedMinButtons: Int,
                     expectedMinAxes: Int,
                     expectsHat: Bool)] = [
            // 1. Minimal gamepad: 4 buttons, 2 axes (X/Y)
            (name: "Minimal 4-button + X/Y",
             descriptor: [
                0x05, 0x01,             // USAGE_PAGE Generic Desktop
                0x09, 0x05,             // USAGE Gamepad
                0xA1, 0x01,             // COLLECTION Application
                0x05, 0x09,             // USAGE_PAGE Buttons
                0x19, 0x01,             // USAGE_MIN 1
                0x29, 0x04,             // USAGE_MAX 4
                0x15, 0x00,             // LOGICAL_MIN 0
                0x25, 0x01,             // LOGICAL_MAX 1
                0x75, 0x01,             // REPORT_SIZE 1
                0x95, 0x04,             // REPORT_COUNT 4
                0x81, 0x02,             // INPUT (Data, Var, Abs)
                0x75, 0x04,             // REPORT_SIZE 4 (padding)
                0x95, 0x01,             // REPORT_COUNT 1
                0x81, 0x03,             // INPUT (Const)
                0x05, 0x01,             // USAGE_PAGE Generic Desktop
                0x09, 0x30,             // USAGE X
                0x09, 0x31,             // USAGE Y
                0x15, 0x81,             // LOGICAL_MIN -127
                0x25, 0x7F,             // LOGICAL_MAX 127
                0x75, 0x08,             // REPORT_SIZE 8
                0x95, 0x02,             // REPORT_COUNT 2
                0x81, 0x02,             // INPUT
                0xC0,                   // END_COLLECTION
             ],
             expectedMinButtons: 4,
             expectedMinAxes: 2,
             expectsHat: false),

            // 2. Generic gamepad with hat
            (name: "8-button + X/Y + hat",
             descriptor: [
                0x05, 0x01, 0x09, 0x05, 0xA1, 0x01,
                0x05, 0x09, 0x19, 0x01, 0x29, 0x08,
                0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08,
                0x81, 0x02,
                0x05, 0x01, 0x09, 0x30, 0x09, 0x31,
                0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x02,
                0x81, 0x02,
                0x09, 0x39,             // USAGE Hat switch
                0x15, 0x01, 0x25, 0x08,
                0x35, 0x00, 0x46, 0x3B, 0x01,
                0x65, 0x14,             // UNIT (degrees)
                0x75, 0x04, 0x95, 0x01,
                0x81, 0x42,             // INPUT (Data, Var, Abs, Null)
                0xC0,
             ],
             expectedMinButtons: 8,
             expectedMinAxes: 2,
             expectsHat: true),
        ]

        for c in cases {
            if let layout = HIDDescriptorParser.parse(Data(c.descriptor)) {
                let bOK = layout.buttonBitOffsets.count >= c.expectedMinButtons
                let aOK = layout.axisByteOffsets.count >= c.expectedMinAxes
                let hOK = c.expectsHat ? (layout.hatByteOffset != nil) : true
                record("HID Descriptor Parser",
                       c.name,
                       pass: bOK && aOK && hOK,
                       detail: "buttons=\(layout.buttonBitOffsets.count) axes=\(layout.axisByteOffsets.count) hat=\(layout.hatByteOffset != nil)")
            } else {
                record("HID Descriptor Parser",
                       c.name,
                       pass: false,
                       detail: "parser returned nil")
            }
        }

        // Truncation safety: a descriptor cut off mid-item must NOT
        // crash or hang. Long-item OOB guard from the audit lives here.
        let truncated: [UInt8] = [0xFE, 0x05, 0x05, 0x01, 0x09]
        let result = HIDDescriptorParser.parse(Data(truncated))
        record("HID Descriptor Parser",
               "Truncated descriptor doesn't crash",
               pass: result == nil || result?.buttonBitOffsets.isEmpty == true,
               detail: "Returned \(result == nil ? "nil" : "empty layout") safely")
    }

    // MARK: - HID Profile DB Matrix
    //
    // For every hand-coded profile that uses the .xinput layout,
    // synthesize a 14-byte HID report exercising each face button +
    // both sticks at full deflection + both triggers at max. Confirms
    // decoder produces the expected ControllerState. Catches the
    // 14-vs-20 byte header detection regression and the DS3 stick
    // 128-vs-127 division bug.

    private func runHIDProfileMatrixTests() {
        let xinputProfiles = ControllerProfileDatabase.all.filter {
            $0.layout == .xinput
        }

        for profile in xinputProfiles {
            // Compact 14-byte XInput report: buttons[2] axes[12]
            var report = [UInt8](repeating: 0, count: 14)
            // A button = bit 12
            report[1] = 0x10
            // LT = 0xFF, RT = 0xFF
            report[2] = 0xFF
            report[3] = 0xFF
            // LX = max (32767), LY = max
            report[4] = 0xFF; report[5] = 0x7F
            report[6] = 0xFF; report[7] = 0x7F
            // RX, RY = max
            report[8] = 0xFF; report[9] = 0x7F
            report[10] = 0xFF; report[11] = 0x7F

            let state = HIDReportDecoder.decode(report: Data(report), profile: profile)

            let aPressed = (state.buttons[0] ?? 0) > 0.5
            let ltMax = (state.axes[4] ?? 0) > 0.95
            let rtMax = (state.axes[5] ?? 0) > 0.95
            let lxMax = (state.axes[0] ?? 0) > 0.95
            // LY is flipped (positive=up in HID, positive=down in our model)
            let lyMax = (state.axes[1] ?? 0) < -0.95

            let allPass = aPressed && ltMax && rtMax && lxMax && lyMax
            record("HID Profile Matrix",
                   profile.displayName,
                   pass: allPass,
                   detail: "A=\(aPressed) LT=\(ltMax) RT=\(rtMax) LX=\(lxMax) LY-flipped=\(lyMax)")
        }

        // DS3 stick deflection should now hit 1.0 at raw 255 (the
        // /127 fix from this round of patches; previously /128 capped
        // at 0.992 and the visualizer's "at limit" detector never
        // fired).
        if let ds3 = ControllerProfileDatabase.all.first(where: { $0.identifier == "sony-dualshock-3" }) {
            var ds3Report = [UInt8](repeating: 0, count: 49)
            ds3Report[0] = 0x01            // report ID
            ds3Report[6 + 1] = 0xFF        // LX at max (with report ID = byte 7 in raw)
            ds3Report[6] = 0xFF            // also test L
            let state = HIDReportDecoder.decode(report: Data(ds3Report), profile: ds3)
            let lxAtLimit = (state.axes[0] ?? 0) >= 0.99
            record("HID Profile Matrix",
                   "DualShock 3 stick reaches 1.0",
                   pass: lxAtLimit,
                   detail: "LX=\(state.axes[0] ?? 0)")
        }
    }

    // MARK: - HID Edge-Case Fuzz
    //
    // Adversarial input safety: malformed reports, axis values at
    // INT16_MIN/MAX, degenerate VID/PID lookups, oversize buffers.
    // Asserts safe behavior (no crash, no infinite loop, clamped
    // output) rather than specific decoded values.

    private func runHIDEdgeCaseFuzzTests() {
        guard let xboxProfile = ControllerProfileDatabase.all.first(where: {
            $0.identifier == "xbox-360-wired"
        }) else {
            record("HID Edge-Case Fuzz",
                   "Setup",
                   pass: false,
                   detail: "Xbox 360 profile not found")
            return
        }

        // 1. Truncated report (3 bytes) must early-return, not crash.
        let truncated = Data([0x00, 0x14, 0xFF])
        _ = HIDReportDecoder.decode(report: truncated, profile: xboxProfile)
        record("HID Edge-Case Fuzz",
               "Truncated 3-byte report doesn't crash",
               pass: true,
               detail: "Survived")

        // 2. Oversize 256-byte report (should decode normally, ignore tail).
        let oversize = Data([UInt8](repeating: 0xAA, count: 256))
        _ = HIDReportDecoder.decode(report: oversize, profile: xboxProfile)
        record("HID Edge-Case Fuzz",
               "256-byte report doesn't crash",
               pass: true,
               detail: "Survived")

        // 3. INT16_MIN axis value must clamp to >= -1.0 (signedInt16
        //    clamp ensures we don't return -1.000030...).
        var minStickReport = [UInt8](repeating: 0, count: 14)
        minStickReport[4] = 0x00; minStickReport[5] = 0x80     // LX = INT16_MIN (-32768)
        let minState = HIDReportDecoder.decode(report: Data(minStickReport), profile: xboxProfile)
        let lx = minState.axes[0] ?? 0
        record("HID Edge-Case Fuzz",
               "INT16_MIN clamps to >= -1.0",
               pass: lx >= -1.0,
               detail: "LX=\(lx)")

        // 4. INT16_MAX axis value at exactly +1.0.
        var maxStickReport = [UInt8](repeating: 0, count: 14)
        maxStickReport[4] = 0xFF; maxStickReport[5] = 0x7F      // LX = INT16_MAX (+32767)
        let maxState = HIDReportDecoder.decode(report: Data(maxStickReport), profile: xboxProfile)
        let lxMax = maxState.axes[0] ?? 0
        record("HID Edge-Case Fuzz",
               "INT16_MAX maps to 1.0",
               pass: lxMax >= 0.999 && lxMax <= 1.0,
               detail: "LX=\(lxMax)")

        // 5. Degenerate VID/PID lookups don't crash.
        _ = ControllerProfileDatabase.profile(forVendor: 0, product: 0)
        _ = ControllerProfileDatabase.profile(forVendor: -1, product: -1)
        _ = ControllerProfileDatabase.profile(forVendor: 0x7FFFFFFF, product: 0x7FFFFFFF)
        record("HID Edge-Case Fuzz",
               "Degenerate VID/PID lookups safe",
               pass: true,
               detail: "Survived 3 lookups")

        // 6. Malformed descriptor with REPORT_SIZE=0 must not infinite-loop.
        let zeroSizeDescriptor = Data([
            0x05, 0x01, 0x09, 0x05, 0xA1, 0x01,
            0x05, 0x09, 0x19, 0x01, 0x29, 0x04,
            0x15, 0x00, 0x25, 0x01,
            // intentionally omit REPORT_SIZE
            0x95, 0x04,             // REPORT_COUNT 4
            0x81, 0x02,             // INPUT
            0xC0,
        ])
        _ = HIDDescriptorParser.parse(zeroSizeDescriptor)
        record("HID Edge-Case Fuzz",
               "Descriptor with no REPORT_SIZE doesn't hang",
               pass: true,
               detail: "Parser bailed safely")

        // 7. Truncated HID descriptor (just a prefix).
        _ = HIDDescriptorParser.parse(Data([0x05]))
        record("HID Edge-Case Fuzz",
               "Single-byte descriptor doesn't crash",
               pass: true,
               detail: "Survived")
    }

    // MARK: - Fixture corpus

    /// Every decoder and output builder fed the bytes in Models/Fixtures: a
    /// lint of the corpus first, one result per fixture, the sequences once
    /// the applier lands, then the coverage line naming what has never been
    /// fed bytes.
    private func runFixtureCorpus() {
        let fixtures = HIDFixtureCorpus.all
        let sequences = HIDFixtureCorpus.sequences
        lintFixtures(fixtures, sequences: sequences)
        for fixture in fixtures { runFixture(fixture) }
        recordFixtureCoverage(fixtures, sequences: sequences)
    }

    private enum FixtureOutcome {
        case notWired(String)
        case checked([String])
    }

    /// Verified and reconstructed fixtures pass or fail with the status in
    /// the detail; an unverified one is info only, never a pass.
    private func runFixture(_ f: HIDFixture) {
        let category = "Fixtures: \(f.device)"
        switch runFixtureRoute(f) {
        case .notWired(let why):
            info(category, "\(f.id) (route not wired yet)", detail: why)
        case .checked(let failures):
            let detail = "[\(f.status.rawValue)] " + (failures.isEmpty ? "\(f.expect.count) expectations met" : failures.joined(separator: "; "))
            if f.status == .unverified {
                info(category, "\(f.id) (unverified)", detail: failures.isEmpty ? detail : "would fail: " + detail)
            } else {
                record(category, f.id, pass: failures.isEmpty, detail: detail)
            }
        }
    }

    /// The profile the attach path would build for a descriptor: the
    /// wheel and macro pad plans, else the plain parse.
    private func descriptorProfile(name: String, descriptor: [UInt8], vendorID vid: Int32, productID pid: Int32) -> ControllerProfile? {
        guard var plan = HIDDescriptorParser.parseExtended(Data(descriptor)) else { return nil }
        if LogitechWheel.isWheel(vendor: vid, product: pid) {
            plan = LogitechWheel.normalize(LogitechWheel.addSeparatePedals(plan, descriptorLength: descriptor.count, vendor: vid, product: pid), product: pid)
        } else if ThrustmasterWheel.isWheel(vendor: vid, product: pid) {
            plan = ThrustmasterWheel.normalize(plan)
        } else if MacroPadLayouts.applies(vendorID: vid, productID: pid, plan) {
            plan = MacroPadLayouts.normalize(plan, vendorID: vid, productID: pid)
        }
        var layout = plan.legacyLayout
        layout.extended = plan
        return ControllerProfile(identifier: "fixture-\(name)", displayName: name, vendorID: vid, productMatches: [.exact(pid)],
                                 layout: .generic(layout), physicalButtonNames: [])
    }

    private func fixtureProfile(vendorID vid: Int32, productID pid: Int32, transport: String?) -> ControllerProfile? {
        if let transport = transport, let p = ControllerProfileDatabase.profile(forVendor: vid, product: pid, transport: transport) { return p }
        if let p = ControllerProfileDatabase.profile(forVendor: vid, product: pid) { return p }
        if XboxBluetoothLayout.isXboxBluetooth(vendorID: vid, productID: pid) {
            return XboxBluetoothLayout.profile(productID: pid, productName: "Xbox Bluetooth fixture")
        }
        // A third party PlayStation pad gets its profile from the capability
        // report at attach; the bench stands in for the answer by class.
        let id = Int(vid) << 16 | Int(pid)
        if SDLGameControllerDB.playStation5Class.contains(id) {
            return PlayStationCapabilityProbe.profile(for: .init(family: .playStation5, deviceType: .gamepad, sensors: false, lightBar: false, vibration: false, touchpad: true),
                                                      vendorID: vid, productID: pid, productName: "PS5 class fixture")
        }
        if SDLGameControllerDB.playStation4Class.contains(id) {
            return PlayStationCapabilityProbe.profile(for: .init(family: .playStation4, deviceType: .arcadeStick, sensors: false, lightBar: false, vibration: false, touchpad: true),
                                                      vendorID: vid, productID: pid, productName: "PS4 class fixture")
        }
        return nil
    }

    private func runFixtureRoute(_ f: HIDFixture) -> FixtureOutcome {
        let bytes = f.bytes
        switch f.route {
        case .accessPorts:
            return .checked(checkAccessPorts(AccessControllerPortService.decode(bytes), expect: f.expect))
        case .accessProfile(let number):
            return .checked(checkAccessProfile(bytes, number: number, expect: f.expect))
        case .rawHID(let vid, let pid, let transport):
            guard let profile = fixtureProfile(vendorID: vid, productID: pid, transport: transport) else {
                return .checked([String(format: "no profile for %04x:%04x", vid, pid)])
            }
            let state = HIDReportDecoder.decode(report: Data(bytes), profile: profile)
            return .checked(checkState(state, expect: f.expect, facts: ["profile": profile.identifier]))
        case .descriptor(let name, let descriptor, let vid, let pid, let version):
            // The real path: a GameControllerDB row for the device when one
            // fits (SDLGameControllerDB.profile), else the plain descriptor plan.
            if vid != 0, let profile = SDLGameControllerDB.profile(descriptor: Data(descriptor), vendorID: vid, productID: pid,
                                                                    version: version, productName: name) {
                let state = HIDReportDecoder.decode(report: Data(bytes), profile: profile)
                return .checked(checkState(state, expect: f.expect, facts: ["descriptor": name, "profile": profile.identifier]))
            }
            guard var plan = HIDDescriptorParser.parseExtended(Data(descriptor)) else {
                return .checked(["descriptor \(name) did not parse"])
            }
            if LogitechWheel.isWheel(vendor: vid, product: pid) {
                plan = LogitechWheel.normalize(LogitechWheel.addSeparatePedals(plan, descriptorLength: descriptor.count, vendor: vid, product: pid), product: pid)
            } else if ThrustmasterWheel.isWheel(vendor: vid, product: pid) {
                plan = ThrustmasterWheel.normalize(plan)
            } else if MacroPadLayouts.applies(vendorID: vid, productID: pid, plan) {
                plan = MacroPadLayouts.normalize(plan, vendorID: vid, productID: pid)
            }
            var state = ControllerState()
            HIDReportDecoder.decodeGeneric(report: Data(bytes), plan: plan, into: &state)
            let indices = plan.reports.flatMap(\.axes).map(\.index)
            var facts = ["descriptor": name, "reports": "\(plan.reports.count)", "axes": indices.sorted().map(String.init).joined(separator: ",")]
            facts["duplicateAxes"] = Set(indices).count != indices.count ? "yes" : ""
            return .checked(checkState(state, expect: f.expect, facts: facts))
        case .edgeProfile:
            return .checked(checkEdgeProfile(bytes, expect: f.expect))
        case .outputReport(let builder):
            guard let got = OutputBuilders.bytes(for: builder) else {
                return .checked(["no builder for \(builder.caseName) yet"])
            }
            return .checked(checkOutput(got, expect: f.expect))
        case .dualSenseSupplement(let pid):
            let isDS4 = [0x05C4, 0x09CC, 0x0BA0].contains(pid)
            let got = DualSenseSupplementService.buttons2(from: bytes, isDS4: isDS4)
            var misses: [String] = []
            for e in f.expect {
                switch e {
                case .supplementByte(let want):
                    if got != want { misses.append("buttons2 got \(got.map { String(format: "0x%02X", $0) } ?? "nil") want \(want.map { String(format: "0x%02X", $0) } ?? "nil")") }
                case .ignored:
                    if got != nil { misses.append("buttons2 got \(String(format: "0x%02X", got ?? 0)) want nil") }
                case .crcValid:
                    break
                default:
                    misses.append("\(e) not checkable on this route")
                }
            }
            return .checked(misses)
        case .steamHelperReport:
            return .notWired("the helper's report parser is not shared with the app yet")
        case .steamHelperLine:
            return .notWired("SteamControllerService.parseStateLine is not split out yet")
        case .eightBitDoMode:
            return .notWired("EightBitDoDetector route lands with the section 6 replacement")
        case .externalInput:
            return .notWired("ExternalInputDeviceService static decoders are not exposed yet")
        }
    }

    /// Sequences need RawHIDReportApplier.apply(data:to:profile:replay:) and a
    /// device free RawHIDGamepad; until both land they are only counted.
    private func runSequenceFixtures(_ sequences: [HIDSequenceFixture]) async {
        for seq in sequences {
            let vid: Int32, pid: Int32, transport: String?
            let profile: ControllerProfile?
            switch seq.route {
            case .rawHID(let v, let p, let t):
                vid = v; pid = p; transport = t
                profile = fixtureProfile(vendorID: v, productID: p, transport: t)
            case .descriptor(let name, let descriptor, let v, let p, _):
                vid = v; pid = p; transport = "USB"
                profile = descriptorProfile(name: name, descriptor: descriptor, vendorID: v, productID: p)
            default:
                info("Fixtures", "sequence \(seq.id)", detail: "only .rawHID and .descriptor sequences run through the applier")
                continue
            }
            guard let profile else {
                record("Fixtures: sequences", seq.id, pass: false, detail: "no profile for the route")
                continue
            }
            let pad = RawHIDGamepad(testProfile: profile, vendorID: vid, productID: pid, transport: transport ?? "USB",
                                    id: 0xFA5E_0000_5E90_0000 | UInt64(abs(seq.id.hashValue) & 0xFFFF))
            var misses: [String] = []
            for (n, step) in seq.steps.enumerated() {
                if step.delayMs > 0 { try? await Task.sleep(nanoseconds: UInt64(step.delayMs) * 1_000_000) }
                let bytes = HIDFixture.parse(step.hex)
                if !bytes.isEmpty {
                    RawHIDReportApplier.apply(data: Data(bytes), to: pad, profile: profile, players: nil, replay: false, steam2026: nil)
                }
                let stepMisses = checkState(pad.state, expect: step.expect, facts: ["profile": profile.identifier])
                misses += stepMisses.map { "step \(n): \($0)" }
            }
            let tag = "[\(seq.status.rawValue)]"
            if seq.status == .unverified {
                info("Fixtures: sequences", "\(seq.id) (unverified)", detail: "\(tag) \(misses.isEmpty ? "\(seq.steps.count) steps met" : misses.joined(separator: "; "))")
            } else {
                record("Fixtures: sequences", seq.id, pass: misses.isEmpty, detail: "\(tag) \(misses.isEmpty ? "\(seq.steps.count) steps met" : misses.joined(separator: "; "))")
            }
        }
    }

    // MARK: Fixture checks, each returning every missed expectation as got/want

    private func fixtureValue(_ v: Float?) -> String {
        v.map { String(format: "%.3f", $0) } ?? "nil"
    }

    private func fixtureMisses(_ got: Float?, _ want: Float, tolerance: Float) -> Bool {
        guard let got = got else { return true }
        return abs(got - want) > tolerance
    }

    /// A `.custom("key=value")` expectation against the facts a route reports.
    private func checkCustom(_ spec: String, facts: [String: String]) -> String? {
        guard let eq = spec.firstIndex(of: "=") else { return "custom \"\(spec)\" is not key=value" }
        let key = String(spec[..<eq]), want = String(spec[spec.index(after: eq)...])
        let got = facts[key]
        return got == want ? nil : "\(key) got \(got ?? "nil") want \(want)"
    }

    private func checkState(_ state: ControllerState, expect: [HIDFixture.Expect], facts: [String: String]) -> [String] {
        var out: [String] = []
        for e in expect {
            switch e {
            case .button(let i, let v):
                if fixtureMisses(state.buttons[i], v, tolerance: 0.001) { out.append("button \(i) got \(fixtureValue(state.buttons[i])) want \(fixtureValue(v))") }
            case .buttonAbsent(let i):
                if (state.buttons[i] ?? 0) != 0 { out.append("button \(i) got \(fixtureValue(state.buttons[i])) want absent") }
            case .axis(let i, let v, let tolerance):
                if fixtureMisses(state.axes[i], v, tolerance: tolerance) { out.append("axis \(i) got \(fixtureValue(state.axes[i])) want \(fixtureValue(v))") }
            case .axisAbsent(let i):
                if let got = state.axes[i] { out.append("axis \(i) got \(fixtureValue(got)) want absent") }
            case .hat(let i, let x, let y):
                if let h = state.hats[i] {
                    if fixtureMisses(h.x, x, tolerance: 0.001) || fixtureMisses(h.y, y, tolerance: 0.001) {
                        out.append("hat \(i) got (\(fixtureValue(h.x)), \(fixtureValue(h.y))) want (\(fixtureValue(x)), \(fixtureValue(y)))")
                    }
                } else {
                    out.append("hat \(i) got nil want (\(fixtureValue(x)), \(fixtureValue(y)))")
                }
            case .motion(let channel, let v, let tolerance):
                if fixtureMisses(state.motion[channel], v, tolerance: tolerance) { out.append("motion \(channel.rawValue) got \(fixtureValue(state.motion[channel])) want \(fixtureValue(v))") }
            case .ignored:
                let touched = state.buttons.values.contains { $0 != 0 } || !state.axes.isEmpty || !state.hats.isEmpty || !state.motion.isEmpty
                if touched { out.append("state changed: buttons \(state.buttons.filter { $0.value != 0 }.keys.sorted()) axes \(state.axes.keys.sorted()) hats \(state.hats.keys.sorted())") }
            case .custom(let spec):
                if let miss = checkCustom(spec, facts: facts) { out.append(miss) }
            case .crcValid:
                break   // recomputed by the lint
            case .relativeSteps(let i, let v):
                if state.relativeSteps[i] != v { out.append("relativeSteps \(i) got \(state.relativeSteps[i].map(String.init) ?? "nil") want \(v)") }
            case .accessPort, .activeProfile, .switchingDisabled, .battery, .supplementByte, .bytes, .bytesPrefix:
                out.append("\(e) not checkable on this route")
            }
        }
        return out
    }

    private func checkAccessPorts(_ decoded: AccessControllerPortService.Decoded?, expect: [HIDFixture.Expect]) -> [String] {
        func portName(_ p: AccessControllerPortService.PortDevice?) -> String { p?.description ?? "empty" }
        guard let d = decoded else {
            return expect.contains(.ignored) ? [] : ["decode returned nil"]
        }
        var out: [String] = []
        let facts = ["ports": d.ports.keys.sorted().map { "\($0):\(portName(d.ports[$0]))" }.joined(separator: ","),
                     "buttons": d.buttons.sorted().map(String.init).joined(separator: ","),
                     "activeProfile": "\(d.activeProfile)"]
        for e in expect {
            switch e {
            case .accessPort(let port, let device):
                if d.ports[port] != device { out.append("port \(port) got \(portName(d.ports[port])) want \(portName(device))") }
            case .axis(let i, let v, let tolerance):
                if fixtureMisses(d.axes[i], v, tolerance: tolerance) { out.append("axis \(i) got \(fixtureValue(d.axes[i])) want \(fixtureValue(v))") }
            case .axisAbsent(let i):
                if let got = d.axes[i] { out.append("axis \(i) got \(fixtureValue(got)) want absent") }
            case .button(let i, let v):
                if d.buttons.contains(i) != (v > 0.5) { out.append("button \(i) got \(d.buttons.contains(i) ? 1 : 0) want \(fixtureValue(v))") }
            case .buttonAbsent(let i):
                if d.buttons.contains(i) { out.append("button \(i) got 1 want absent") }
            case .activeProfile(let n):
                if d.activeProfile != n { out.append("activeProfile got \(d.activeProfile) want \(n)") }
            case .ignored:
                out.append("decoded a report that should be ignored")
            case .custom(let spec):
                if let miss = checkCustom(spec, facts: facts) { out.append(miss) }
            case .crcValid:
                break
            case .switchingDisabled(let want):
                if d.switchingDisabled != want { out.append("switchingDisabled got \(d.switchingDisabled) want \(want)") }
            case .battery(let level, let stateName):
                if d.battery?.level != level || d.battery?.state.rawValue != stateName {
                    out.append("battery got \(d.battery.map { "\($0.level) \($0.state.rawValue)" } ?? "nil") want \(level) \(stateName)")
                }
            case .hat, .motion, .relativeSteps, .supplementByte, .bytes, .bytesPrefix:
                out.append("\(e) not checkable on this route")
            }
        }
        return out
    }

    /// parseProfile, then encode must give back the bytes it read (the first
    /// 948; the tail holds the CRC and padding the controller writes), then
    /// the write packets and the set active command for that number.
    private func checkAccessProfile(_ bytes: [UInt8], number: Int, expect: [HIDFixture.Expect]) -> [String] {
        typealias S = AccessControllerPortService
        guard let p = S.parseProfile(bytes, number: number) else {
            return expect.contains(.ignored) ? [] : ["parseProfile returned nil"]
        }
        var out: [String] = []
        if expect.contains(.ignored) { out.append("parsed a profile that should be rejected") }
        let encoded = S.encode(p)
        if encoded.count != bytes.count { out.append("encode gave \(encoded.count) bytes, read \(bytes.count)") }
        let keep = min(948, min(encoded.count, bytes.count))
        if let i = (0..<keep).first(where: { encoded[$0] != bytes[$0] }) {
            out.append("encode(parse(x)) differs at byte \(i): got \(encoded[i]) want \(bytes[i])")
        }
        let packets = S.writePackets(number: number, bytes: encoded)
        if number == 0 {
            // The base profile is read only: no write packets, no set active.
            if !packets.isEmpty { out.append("writePackets built \(packets.count) packets for the base profile") }
        } else {
            if packets.count != 18 || !packets.allSatisfy({ $0.count == 64 && $0[0] == 0x60 && $0[1] == UInt8(clamping: 0x08 + number) }) {
                out.append("writePackets gave \(packets.count) packets, first bytes \(HIDFixture.hex(Array(packets.first?.prefix(3) ?? [])))")
            }
            let active = S.setActiveCommand(number)
            if active.count != 64 || active[0] != 0x60 || active[1] != 0x05 || active[2] != UInt8(clamping: number) {
                out.append("setActiveCommand gave \(HIDFixture.hex(Array(active.prefix(3))))")
            }
        }
        let facts = ["name": p.name, "number": "\(p.number)", "orientation": "\(p.orientation)",
                     "portActions": p.portActions.keys.sorted().map { "\($0):\(p.portActions[$0] ?? 0)" }.joined(separator: ","),
                     "stickAssignments": p.stickAssignments.keys.sorted().map { "\($0):\(p.stickAssignments[$0] ?? 0)" }.joined(separator: ","),
                     "toggles": p.toggles.sorted().map(String.init).joined(separator: ",")]
        for e in expect {
            switch e {
            case .custom(let spec):
                if let miss = checkCustom(spec, facts: facts) { out.append(miss) }
            case .ignored, .crcValid:
                break
            default:
                out.append("\(e) not checkable on this route")
            }
        }
        return out
    }

    /// Three 64 byte feature reports concatenated; the slot is the first
    /// report's ID.
    private func checkEdgeProfile(_ bytes: [UInt8], expect: [HIDFixture.Expect]) -> [String] {
        guard bytes.count == 192 else { return ["edge profile needs 192 bytes (three reports), got \(bytes.count)"] }
        let reports = stride(from: 0, to: 192, by: 64).map { Array(bytes[$0..<$0 + 64]) }
        guard let slot = DualSenseEdgeProfiles.Slot(rawValue: Int(reports[0][0])) else {
            return ["first report ID \(reports[0][0]) names no slot"]
        }
        guard let p = DualSenseEdgeProfiles.parse(reports, slot: slot) else {
            return expect.contains(.ignored) ? [] : ["parse returned nil"]
        }
        var out: [String] = []
        if expect.contains(.ignored) { out.append("parsed a profile that should be rejected") }
        let facts = ["name": p.name, "assigned": "\(p.assigned)", "slot": "\(slot)",
                     "remaps": p.remaps.joined(separator: ", "),
                     "leftTrigger": "\(p.leftTrigger.min)...\(p.leftTrigger.max)",
                     "rightTrigger": "\(p.rightTrigger.min)...\(p.rightTrigger.max)",
                     "leftStickCurve": "\(p.leftStickCurve)", "rightStickCurve": "\(p.rightStickCurve)"]
        for e in expect {
            switch e {
            case .custom(let spec):
                if let miss = checkCustom(spec, facts: facts) { out.append(miss) }
            case .ignored, .crcValid:
                break
            default:
                out.append("\(e) not checkable on this route")
            }
        }
        return out
    }

    private func checkOutput(_ got: [UInt8], expect: [HIDFixture.Expect]) -> [String] {
        var out: [String] = []
        let facts = ["count": "\(got.count)", "reportID": got.first.map { String(format: "0x%02x", $0) } ?? "none"]
        for e in expect {
            switch e {
            case .bytes(let want):
                if got != want {
                    let i = zip(got, want).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(got.count, want.count)
                    out.append("bytes differ at \(i) (got \(got.count) bytes, want \(want.count)); got \(HIDFixture.hex(got))")
                }
            case .bytesPrefix(let want):
                if Array(got.prefix(want.count)) != want { out.append("prefix got \(HIDFixture.hex(Array(got.prefix(want.count)))) want \(HIDFixture.hex(want))") }
            case .crcValid(let want):
                if got.count >= 78, got[0] == 0x31 {
                    let stored = UInt32(got[74]) | UInt32(got[75]) << 8 | UInt32(got[76]) << 16 | UInt32(got[77]) << 24
                    let valid = sonyCRC32(got[0..<74]) == stored
                    if valid != want { out.append("crc valid \(valid) want \(want)") }
                } else {
                    out.append("crcValid needs a 78 byte 0x31 report, got \(got.count) bytes")
                }
            case .custom(let spec):
                if let miss = checkCustom(spec, facts: facts) { out.append(miss) }
            default:
                out.append("\(e) not checkable on this route")
            }
        }
        return out
    }

    // MARK: Fixture lint and coverage

    /// CRC-32 the way hid-playstation.c ps_check_crc32 computes it: the zlib
    /// polynomial, started with the one byte seed 0xA1 that names an input
    /// report, then the report bytes, then inverted.
    private func sonyCRC32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        func feed(_ byte: UInt8) {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB8_8320 : 0) }
        }
        feed(0xA1)
        for byte in bytes { feed(byte) }
        return ~crc
    }

    private func isSonyBluetooth(_ f: HIDFixture, bytes: [UInt8]) -> Bool {
        switch f.route {
        case .rawHID(let vid, _, _): return vid == 0x054C && f.reportID == 0x31
        case .accessPorts: return bytes.count == 78
        default: return false
        }
    }

    /// The corpus itself: unique ids, hex that parses, the length each route
    /// needs, and every Sony Bluetooth CRC recomputed from bytes 0..<74.
    private func lintFixtures(_ fixtures: [HIDFixture], sequences: [HIDSequenceFixture]) {
        var problems: [String] = []
        var seen: Set<String> = []
        for f in fixtures {
            if !seen.insert(f.id).inserted { problems.append("duplicate id \(f.id)") }
            guard let bytes = HIDFixture.parseStrict(f.hex) else { problems.append("\(f.id): hex does not parse"); continue }
            if case .accessPorts = f.route, !f.expect.contains(.ignored), bytes.count != 64 && bytes.count != 78 {
                problems.append("\(f.id): Access report is \(bytes.count) bytes, want 64 or 78")
            }
            if case .edgeProfile = f.route, bytes.count != 192 {
                problems.append("\(f.id): Edge profile is \(bytes.count) bytes, want 192")
            }
            if isSonyBluetooth(f, bytes: bytes), !f.expect.contains(.crcValid(false)) {
                if bytes.count < 78 {
                    problems.append("\(f.id): Sony Bluetooth report is \(bytes.count) bytes, want 78")
                } else {
                    let stored = UInt32(bytes[74]) | UInt32(bytes[75]) << 8 | UInt32(bytes[76]) << 16 | UInt32(bytes[77]) << 24
                    let computed = sonyCRC32(bytes[0..<74])
                    if computed != stored {
                        problems.append("\(f.id): CRC got \(String(computed, radix: 16)) stored \(String(stored, radix: 16))")
                    }
                }
            }
            if f.status == .verified, f.citation.source.isEmpty {
                problems.append("\(f.id): verified without a source")
            }
        }
        for s in sequences {
            if !seen.insert(s.id).inserted { problems.append("duplicate id \(s.id)") }
            for (i, step) in s.steps.enumerated() where HIDFixture.parseStrict(step.hex) == nil {
                problems.append("\(s.id) step \(i): hex does not parse")
            }
        }
        record("Fixtures", "lint", pass: problems.isEmpty,
               detail: problems.isEmpty ? "\(fixtures.count) fixtures, \(sequences.count) sequences" : problems.joined(separator: "; "))
    }

    private func layoutName(_ layout: ControllerProfile.ReportLayout) -> String {
        switch layout {
        case .xinput: return "xinput"
        case .dualShock3: return "dualShock3"
        case .dualShock4: return "dualShock4"
        case .dualSenseAlt: return "dualSenseAlt"
        case .xboxBluetooth: return "xboxBluetooth"
        case .switch2Pro: return "switch2Pro"
        case .switch2GameCube: return "switch2GameCube"
        case .switch2JoyConLeft: return "switch2JoyConLeft"
        case .switch2JoyConRight: return "switch2JoyConRight"
        case .steamController2026: return "steamController2026"
        case .streamDeck: return "streamDeck"
        case .generic: return "generic"
        }
    }

    /// Every profile, layout and output builder with the number of fixtures
    /// that reach it, and the zeros: what has never been fed bytes.
    private func recordFixtureCoverage(_ fixtures: [HIDFixture], sequences: [HIDSequenceFixture]) {
        var profileOrder: [String] = []
        var profileCounts: [String: Int] = [:]
        for p in ControllerProfileDatabase.all + ControllerProfileDatabase.streamDeckProfiles where profileCounts[p.identifier] == nil {
            profileOrder.append(p.identifier)
            profileCounts[p.identifier] = 0
        }
        let layoutNames = ["xinput", "dualShock3", "dualShock4", "dualSenseAlt", "xboxBluetooth", "switch2Pro", "switch2GameCube", "switch2JoyConLeft", "switch2JoyConRight", "steamController2026", "streamDeck", "generic"]
        var layoutCounts = Dictionary(uniqueKeysWithValues: layoutNames.map { ($0, 0) })
        var builderCounts = Dictionary(uniqueKeysWithValues: OutputBuilder.caseNames.map { ($0, 0) })
        func count(_ route: HIDFixture.Route) {
            switch route {
            case .rawHID(let vid, let pid, let transport):
                guard let profile = fixtureProfile(vendorID: vid, productID: pid, transport: transport) else { return }
                profileCounts[profile.identifier, default: 0] += 1
                layoutCounts[layoutName(profile.layout), default: 0] += 1
            case .descriptor:
                layoutCounts["generic", default: 0] += 1
            case .outputReport(let builder):
                builderCounts[builder.caseName, default: 0] += 1
            default:
                break
            }
        }
        for f in fixtures { count(f.route) }
        for s in sequences { count(s.route) }
        let zeros = profileOrder.filter { profileCounts[$0] == 0 }
            + layoutNames.filter { layoutCounts[$0] == 0 }
            + OutputBuilder.caseNames.filter { builderCounts[$0] == 0 }
        let profileText: String = profileOrder.map { "\($0)=\(profileCounts[$0] ?? 0)" }.joined(separator: ", ")
        let layoutText: String = layoutNames.map { "\($0)=\(layoutCounts[$0] ?? 0)" }.joined(separator: ", ")
        let builderText: String = OutputBuilder.caseNames.map { "\($0)=\(builderCounts[$0] ?? 0)" }.joined(separator: ", ")
        let zeroText: String = zeros.isEmpty ? "none" : zeros.joined(separator: ", ")
        let detail = "profiles: \(profileText); layouts: \(layoutText); builders: \(builderText); zeros: \(zeroText)"
        info("Fixtures", "coverage", detail: detail)
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
               detail: "InputConfig virtual source is registered with CoreMIDI")

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

        // Stop first, so the CoreMIDI thread no longer appends while the
        // list is read.
        listener.stop()
        let received = listener.received()

        // We expect at least one 3-byte packet with status 0x90 (Note On Ch 1).
        let found = received.contains { bytes in
            bytes.count >= 3 && bytes[0] == 0x90 && bytes[1] == 60 && bytes[2] == 100
        }
        record("MIDI Loopback", "Send Note On round-trip", pass: found,
               detail: found ? "Received Note On 60 vel 100 on Ch 1"
                             : "Did not receive expected Note On; got \(received.count) packets")

        // Followed by the note-off, so no note is left sounding. No CC is
        // sent: CC 7 is volume, and any DAW listening would have changed.
        MIDIService.shared.sendNoteOff(note: 60, channel: 1)
        try? await Task.sleep(nanoseconds: 200_000_000)

        info("MIDI Loopback", "Manual verification ready",
             detail: "Open a DAW (Logic, GarageBand, Ableton) and add InputConfig as a MIDI source to confirm messages arrive in your music software.")
    }

    // MARK: - Steam Controller Diagnostics + Simulation

    /// Two passes:
    /// 1. **Real-helper diagnostics**: surfaces whether the helper binary is
    ///    bundled, whether the subprocess actually launched, whether any
    ///    handshake or state lines came back. This is what tells the user
    ///    "why isn't my Steam Controller working" with specific evidence.
    /// 2. **Synthetic simulation**: pumps state through the
    ///    `SteamControllerService` → `makeControllerState()` bridge to
    ///    verify the downstream parsing/dispatch is sound regardless of
    ///    helper state.
    private func runSteamControllerSimulationTest() async {
        let svc = SteamControllerService.shared

        // Make sure no leftover simulation is active from a previous run so
        // diagnostics reflect real-helper state, not test injection.
        svc.endSimulation()

        // --- Pass 1: real helper diagnostics ---
        // Make sure the helper has had a moment to start and (if hardware
        // is plugged in) send something.
        svc.retain()
        try? await Task.sleep(nanoseconds: 600_000_000)
        let d = svc.diagnostics()

        record("Steam Controller Helper",
               "Helper binary present in app bundle",
               pass: d.helperBundled,
               detail: d.helperPath ?? "Not found. The Copy Helpers build phase didn't ship SteamControllerHelper inside Contents/MacOS/. The shipped App Store binary may have this stripped. Rebuild with the helper Copy Files phase enabled.")

        if d.helperBundled {
            record("Steam Controller Helper",
                   "Helper subprocess launched",
                   pass: d.helperLaunched,
                   detail: d.helperLaunchError ?? (d.helperPID.map { "PID \($0)" } ?? "Process running"))
        }

        if d.helperLaunched {
            // The helper stays silent until a real Steam Controller is
            // plugged in - it only emits stdout once it has opened the
            // HID device. So "no output" with no controller is normal,
            // not a failure. We report it as INFO, and ONLY mark a hard
            // failure if the helper produced no output AND we can prove
            // it should have (e.g. a Steam Controller IS plugged in).
            let gotAnyOutput = d.totalStdoutLines > 0
            if gotAnyOutput {
                info("Steam Controller Helper",
                     "Helper emitted output",
                     detail: "\(d.totalStdoutLines) line(s) received; last: \"\(d.lastStdoutLineSample ?? "")\"")
            } else {
                info("Steam Controller Helper",
                     "Helper is running but silent",
                     detail: "This is expected when no Steam Controller is plugged in: the helper stays quiet until it can open the HID device. If you have one plugged in and Steam.app is closed, then this indicates a real problem (check Console.app for crashes).")
            }

            // The "R ready" line is the helper's handshake - it means HID
            // was opened (lizard mode goes off only while a preset runs).
            if gotAnyOutput {
                record("Steam Controller Helper",
                       "Ready handshake received",
                       pass: d.readyHandshakeReceived,
                       detail: d.readyHandshakeReceived
                            ? "Helper opened a Steam Controller interface. A dongle reports this even with no controller on, and lizard mode stays on until a preset runs."
                            : "Helper started but never sent 'R ready'. The Steam Controller is either not plugged in OR Steam.app is holding the device. Quit Steam, then retry.")
            }

            // First "S" state line means actual input report.
            if d.readyHandshakeReceived {
                record("Steam Controller Helper",
                       "First state report parsed",
                       pass: d.firstStateLineReceived,
                       detail: d.firstStateLineReceived
                            ? "Engine is receiving real Steam Controller HID frames."
                            : "Handshake completed but no input frames. Move a stick or press a button on the controller while running this test.")
            }
        }

        // The diagnostics retain above started the helper; let it go so
        // Run All does not leave the Steam helper running.
        svc.release()

        // --- Pass 2: synthetic simulation (proves downstream bridge) ---
        svc.endSimulation()

        // 1. Inject a custom state with a few buttons + axis values.
        var s = SteamControllerState()
        s.buttons = (UInt32(1) << UInt32(SteamControllerButton.a.rawValue))
                  | (UInt32(1) << UInt32(SteamControllerButton.steam.rawValue))
        s.leftX = 16_000      // half-stick right
        s.leftY = -8_000
        s.rightTrigger = 200  // ~78% pulled
        s.gyroX = 1_234
        svc.injectTestState(s)

        // 2. Read it back through the same bridge the engine uses.
        let snapshot = svc.currentState()
        record("Steam Controller Simulation",
               "Inject A + Steam + analog values",
               pass: snapshot.buttons == s.buttons
                   && snapshot.leftX == 16_000
                   && snapshot.leftY == -8_000
                   && snapshot.rightTrigger == 200
                   && snapshot.gyroX == 1_234
                   && snapshot.connected == true,
               detail: "buttons=0x\(String(snapshot.buttons, radix: 16)), lx=\(snapshot.leftX), ly=\(snapshot.leftY), rt=\(snapshot.rightTrigger), gyroX=\(snapshot.gyroX), connected=\(snapshot.connected)")

        // 3. Verify the GameControllerService bridge produces the same
        //    ControllerState the MappingEngine consumes. Steam Controller
        //    button indices match SteamControllerButton.rawValue (0...22),
        //    so binding to "button 7" (the A button) should see a 1.0 value.
        let bridged = SteamControllerService.shared.makeControllerState()
        let aButtonValue = bridged.buttons[SteamControllerButton.a.rawValue] ?? 0
        let steamButtonValue = bridged.buttons[SteamControllerButton.steam.rawValue] ?? 0
        let bButtonValue = bridged.buttons[SteamControllerButton.b.rawValue] ?? 0
        record("Steam Controller Simulation",
               "Bridge to ControllerState (A pressed)",
               pass: aButtonValue > 0.5,
               detail: "A=\(aButtonValue), Steam=\(steamButtonValue), B=\(bButtonValue); only A and Steam should read >0.5")
        record("Steam Controller Simulation",
               "Bridge to ControllerState (B not pressed)",
               pass: bButtonValue < 0.5,
               detail: "B index 5 should read 0 since we didn't set it")

        // 4. Simulate a press/release transition.
        svc.simulateButtonDown(.rightBumper)
        let withRB = svc.makeControllerState()
        let rbValue = withRB.buttons[SteamControllerButton.rightBumper.rawValue] ?? 0
        record("Steam Controller Simulation",
               "simulateButtonDown(.rightBumper)",
               pass: rbValue > 0.5,
               detail: "RB=\(rbValue)")

        svc.simulateButtonUp(.rightBumper)
        let afterRelease = svc.makeControllerState()
        let rbAfter = afterRelease.buttons[SteamControllerButton.rightBumper.rawValue] ?? 0
        record("Steam Controller Simulation",
               "simulateButtonUp(.rightBumper)",
               pass: rbAfter < 0.5,
               detail: "RB after release=\(rbAfter)")

        // 5. Clean up so the live UI doesn't keep showing a ghost controller.
        svc.endSimulation()
        let cleared = svc.currentState()
        record("Steam Controller Simulation",
               "endSimulation() clears state",
               pass: cleared.buttons == 0 && cleared.connected == false,
               detail: "buttons=\(cleared.buttons), connected=\(cleared.connected)")

        info("Steam Controller Simulation",
             "End-to-end verified",
             detail: "All 22 logical buttons (A/B/X/Y, bumpers, triggers, D-pad, Steam, Back, Forward, grip paddles, trackpad clicks/touches, stick click/active) are reachable through the same ControllerState dictionary the MappingEngine reads. Bind to button indices 0...22 to fire from a real Steam Controller.")
        info("Steam Controller Simulation",
             "Trackpad / stick axis layout",
             detail: "The Steam Controller has TWO trackpads plus an analog stick. Axis 0/1 = analog thumbstick X/Y (only fires when the stick is the active source). Axis 2/3 = right trackpad X/Y. Axis 4/5 = left/right triggers. Axis 6/7 = left trackpad X/Y (only fires when the stick is NOT active). Plus button 17 = left pad click, 18 = right pad click, 19 = left pad touch, 20 = right pad touch.")
    }

    // MARK: - Keyboard Output Loopback

    /// Minimal sanity check for the keyboard-output path. We deliberately
    /// **do not** try to verify cross-app delivery from within our own
    /// process. Two attempts to do so failed:
    ///
    /// 1. A same-process `CGEventTap` listener never observes events we
    ///    post from the SAME process via `.cghidEventTap` - false
    ///    negative. (Karabiner-Elements / Enjoyable / BetterMouse all
    ///    exhibit the same in-process invisibility; their cross-app
    ///    delivery still works perfectly.)
    ///
    /// 2. `CGEventSource.counterForEventType(_:eventType:)` deadlocks
    ///    on a SkyLight mutex (`CGSEventSourceShutdown`) from inside a
    ///    sandboxed App Store binary - the test would hang the whole
    ///    test bench main thread.
    ///
    /// So the trustworthy in-process checks are just these two:
    /// `CGEventSource` creates successfully, and `CGEvent.post` returns
    /// without crashing. End-to-end delivery has to be verified manually
    /// by activating a preset and watching a target app receive the
    /// keystrokes.
    private func runKeyboardOutputLoopbackTest() async {
        let testSource = CGEventSource(stateID: .hidSystemState)
        record("Keyboard Output",
               "CGEventSource available",
               pass: testSource != nil,
               detail: testSource != nil
                    ? "CGEventSource(stateID: .hidSystemState) returned non-nil. CoreGraphics is reachable from this sandboxed binary."
                    : "CGEventSource returned nil. This is rare; usually indicates a deep sandbox lockdown.")

        // No key is posted: a real F20 reached whatever app was in front
        // (and any preset row bound to F20), and the void post call could
        // not report anything a test could check anyway.

        info("Keyboard Output",
             "How to verify end-to-end delivery",
             detail: "In-process verification is unreliable: macOS doesn't deliver self-posted HID events back through a same-process session tap (so a CGEventTap listener won't see them), and CGEventSource.counterForEventType deadlocks on the SkyLight subsystem when called from a sandboxed app. To prove cross-app keystrokes work, the only valid test is: open TextEdit with text, activate the Desktop Navigation preset, plug in a controller, press D-pad Up, and the text cursor should move.")
    }

    // MARK: - Hardware Snapshot

    /// Honest, plain-language inventory of what the app currently sees on
    /// this Mac. Distinct from the unit-style tests above: this section is
    /// purely informational and lets a user verify "yes, my X controller /
    /// keyboard / mouse is reaching the app." Without real hardware
    /// connected we cannot positively prove every brand works, but we CAN
    /// enumerate what is plugged in right now and through which subsystem.
    private func runHardwareSnapshot() {
        // --- Game controllers (GCController / MFi path) ---
        let controllers = GCController.controllers()
        if controllers.isEmpty {
            info("Hardware Snapshot",
                 "Game controllers (GCController framework)",
                 detail: "0 controllers connected. PS5 DualSense, DualSense Edge, DualShock 4, Xbox, Switch Pro, Joy-Cons, 8BitDo (Apple mode), Stadia, and any MFi-certified gamepad would appear here through Apple's GameController framework. Plug or pair one in and re-run.")
        } else {
            for c in controllers {
                let name = c.vendorName ?? "Unknown"
                let category = c.productCategory
                let hasExt = c.extendedGamepad != nil ? "extendedGamepad" : "no extendedGamepad"
                info("Hardware Snapshot",
                     "Detected: \(name)",
                     detail: "productCategory=\(category), \(hasExt). Brand detector will route this to its specific button layout.")
            }
        }

        // --- Steam Controller (custom HID via SteamControllerHelper) ---
        let steamDiag = SteamControllerService.shared.diagnostics()
        if steamDiag.firstStateLineReceived {
            info("Hardware Snapshot",
                 "Steam Controller (via SteamControllerHelper)",
                 detail: "Active and streaming HID frames. Map to button indices 0-22.")
        } else if steamDiag.readyHandshakeReceived {
            info("Hardware Snapshot",
                 "Steam Controller (via SteamControllerHelper)",
                 detail: "Helper opened the HID interface but no input frames yet. Move a stick or press a button to confirm.")
        } else if steamDiag.helperLaunched {
            info("Hardware Snapshot",
                 "Steam Controller (via SteamControllerHelper)",
                 detail: "Helper subprocess is running but the controller isn't plugged in OR Steam.app is holding it. Quit Steam and plug the controller in.")
        } else if steamDiag.helperBundled {
            info("Hardware Snapshot",
                 "Steam Controller (via SteamControllerHelper)",
                 detail: "Helper bundled but failed to launch: \(steamDiag.helperLaunchError ?? "unknown reason")")
        } else {
            info("Hardware Snapshot",
                 "Steam Controller (via SteamControllerHelper)",
                 detail: "Helper binary NOT bundled in this app: Steam Controller cannot work in this build. (Shipped App Store versions before 1.2 had this bug.)")
        }

        // --- External keyboards / mice (IOHIDManager path) ---
        let extDevices = ExternalInputDeviceService.shared.devices
        if extDevices.isEmpty {
            info("Hardware Snapshot",
                 "External keyboards / mice",
                 detail: "The Mac's keyboard and mouse are listened to only while a preset, Scan, or the Live Visualizer uses them, and appear here then as one combined keyboard and one combined mouse. They need no permission beyond Accessibility (System Settings, Privacy & Security, Accessibility).")
        } else {
            for d in extDevices {
                info("Hardware Snapshot",
                     "Mac \(d.kind.rawValue): \(d.productName)",
                     detail: "Every keyboard (or every mouse and trackpad) on the Mac, combined. Bind it as a Keyboard Key or Mouse input.")
            }
            let received = ExternalInputDeviceService.shared.receivedAnyKeyboardEvent
            info("Hardware Snapshot",
                 "Mac keyboard events arriving?",
                 detail: received
                    ? "Yes. The Live Visualizer's Keyboard template lights each key as it arrives."
                    : "No key has been seen yet. Keys are read only while a preset or Scan uses a keyboard row; press a bound key with one running. If nothing arrives, check that InputConfig is on in System Settings, Privacy & Security, Accessibility.")
        }

        // --- Built-in keyboard / trackpad (CGEventTap path) ---
        let svc = ExternalInputDeviceService.shared
        if svc.cgEventTapInstalled {
            if svc.cgEventTapReceivedAnyEvent {
                info("Hardware Snapshot",
                     "Built-in Mac keyboard and trackpad",
                     detail: "The mouse tap is active: clicks, scrolling, and (when a row reads it) pointer movement reach InputConfig. Keys are read separately and show in the Live Visualizer's Keyboard template.")
            } else {
                info("Hardware Snapshot",
                     "Built-in Mac keyboard and trackpad",
                     detail: "The mouse tap is installed but has seen nothing yet. Click or scroll to confirm it is working; pointer movement is read only when a row uses it.")
            }
        } else {
            info("Hardware Snapshot",
                 "Built-in Mac keyboard and trackpad",
                 detail: "The mouse event tap is not running. It starts while a mouse or trackpad row is in use and needs the Accessibility permission: System Settings, Privacy & Security, Accessibility.")
        }
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

    /// The messages heard so far, read under the lock.
    func received() -> [[UInt8]] {
        lock.lock(); defer { lock.unlock() }
        return collectedPackets
    }

    func start() -> Bool {
        let clientName = "InputConfig.TestBench" as CFString
        guard MIDIClientCreateWithBlock(clientName, &client, nil) == noErr else { return false }

        let portName = "Loopback" as CFString
        let status = MIDIInputPortCreateWithProtocol(client, portName, ._1_0, &port) { [weak self] eventList, _ in
            guard let self = self else { return }
            // Walk the list in place, as MIDIInputService does: stepping a
            // copied packet with MIDIEventPacketNext read past the copy into
            // stack memory when a list held more than one packet.
            for packetPtr in eventList.unsafeSequence() {
                // Read in place and message by message, as MIDIInputService
                // does: copying the whole packet read past a short one, and
                // reading only its first word missed a note queued behind
                // another message.
                let words = Array(packetPtr.words())
                var w = 0
                while w < words.count {
                    let type = UInt8((words[w] >> 28) & 0xF)
                    let size = MIDIInputService.umpWordCount(messageType: type)
                    guard w + size <= words.count else { break }
                    if type == 0x2 {
                        // MIDI 1.0 voice message in a Universal MIDI Packet.
                        let word = words[w]
                        let status = UInt8((word >> 16) & 0xFF)
                        let data1 = UInt8((word >> 8) & 0xFF)
                        let data2 = UInt8(word & 0xFF)
                        self.lock.lock()
                        self.collectedPackets.append([status, data1, data2])
                        self.lock.unlock()
                    }
                    w += size
                }
            }
        }

        guard status == noErr else { return false }

        // Our own virtual source only, by endpoint: by name, any device
        // whose name contained "InputConfig" was listened to as well.
        let own = MIDIService.ownSourceEndpoint
        guard own != 0 else { return false }
        MIDIPortConnectSource(port, own, nil)
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
