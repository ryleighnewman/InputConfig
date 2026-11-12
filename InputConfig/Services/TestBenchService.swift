import Foundation
import AppKit
import ApplicationServices
import Combine
import CoreMIDI
import GameController
import Observation

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
    /// Whether a real key had reached the app before this run: the key tap
    /// cases feed their own presses, which the snapshot must not report.
    private var keyboardSeenBeforeRun = false

    func runAll() async -> (passed: Int, failed: Int) {
        // Two runs interleave at every await, and step on each other's sinks.
        guard !isRunning else {
            return (results.filter { $0.status == .pass }.count, results.filter { $0.status == .fail }.count)
        }
        isRunning = true
        results.removeAll()
        keyboardSeenBeforeRun = ExternalInputDeviceService.shared.receivedAnyKeyboardEvent
        defer { isRunning = false }

        runOutputActionTests()
        runInputEventTests()
        runExtraButtonsAndKeysTests()
        runSensitivityCurveTests()
        runMIDIByteLayoutTests()
        runControllerBrandTests()
        runFaceNameTests()
        runSpokenTableTests()
        // DEBUG only: it rewrites the live Face button names setting, which
        // a user's bench run quit midway would leave changed.
        #if DEBUG
        await runFaceLettersCacheTests()
        #endif
        runEightBitDoModeTests()
        runAccessControllerTests()
        runLogitechWheelTests()
        runDirectPadIdleTests()
        runSwitch2CalibrationTests()
        runMotionMathTests()
        runCanvasCellTests()
        runControllerPowerTests()
        runHelpLinkTests()
        runCGEventDecoderTests()
        runPlayStationProbeTests()
        runVisualizerObservationTests()
        runXboxBatteryTests()
        runPresetCodableTests()
        runPageHeaderDraftTests()
        runScreenInputEventTests()
        runScreenWatchCodableTests()
        runScreenWatchPresetTests()
        runTextNormalizationTests()
        runScreenPixelMathTests()
        runScreenCaptureCutTests()
        runMacroRecordingTests()
        runButtonSequenceTests()
        runBlockingAndLightTests()
        runObservationStageZeroTests()
        await runPageSwitchTests()
        await runSpeedRowTests()
        runSelectionObservationTests()
        runLaunchPathTests()
        runIdleWakeTests()
        await runPresetQueryTests()
        runVersionConsistencyTests()
        runHelpGuideTests()
        runLoadAndCacheTests()
        runVariableSensitivityMathTests()
        runHIDDescriptorParserTests()
        runLayoutTranslationCoverage()
        runCanvasCacheTests()
        runCanvasFrozenLayerTests()
        await runCanvasKeyAccessibilityTests()
        runRememberedMatchTests()
        runShipReviewCases()
        runFixAfterCases()
        runHIDProfileMatrixTests()
        runHIDEdgeCaseFuzzTests()
        runFixtureCorpus()
        await runSequenceFixtures(HIDFixtureCorpus.sequences)
        #if DEBUG
        runRawHIDReportThreadReplay()
        #endif
        await runMIDILoopbackTest()
        await runSteamControllerSimulationTest()
        await runKeyboardOutputLoopbackTest()
        await runScrollStyleTests()
        #if DEBUG
        await runSecondAuditTests()
        await runEditorRowCases()
        #endif
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
        let skipped = results.filter { $0.status == .skipped }
        var text = "passed=\(passed) failed=\(failed) skipped=\(skipped.count)\n"
        for r in results where r.status == .fail {
            text += "FAIL \(r.category): \(r.name): \(r.detail)\n"
        }
        for r in skipped { text += "SKIP \(r.category): \(r.name): \(r.detail)\n" }
        let counts = Dictionary(grouping: results.filter { $0.status == .pass }, by: \.category)
        for category in counts.keys.sorted() { text += "RAN \(category): \(counts[category]?.count ?? 0)\n" }
        // The engine bench's digest and time per poll too, for comparing runs.
        for r in results where r.status == .info
            && (r.name.hasPrefix("coverage") || r.name.contains("unverified") || r.name.contains("not wired")
                || r.category == "Engine Rows" || r.category == "Editor Rows") {
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

    private func skip(_ category: String, _ name: String, detail: String) {
        results.append(TestResult(category: category, name: name,
                                   status: .skipped, detail: detail))
    }

    /// The visualizer's control state and render clock are Observable
    /// (1.10): a view re-runs only for a property it read, and only when
    /// the value changes.
    private func runVisualizerObservationTests() {
        let cat = "Observation"
        final class Fired: @unchecked Sendable { var count = 0 }
        func fires(_ read: (VisualizerControlState) -> Void, _ write: (VisualizerControlState) -> Void) -> Bool {
            let state = VisualizerControlState()
            let fired = Fired()
            withObservationTracking { read(state) } onChange: { fired.count += 1 }
            write(state)
            return fired.count > 0
        }
        // A preset switch writes scale and editMode with the values they had.
        let sameScale = fires({ _ = $0.scale }, { $0.scale = 1.0 })
        let sameEdit = fires({ _ = $0.editMode }, { $0.editMode = false })
        record(cat, "Visualizer controls: a write of the same value is silent",
               pass: !sameScale && !sameEdit, detail: "scale \(sameScale), editMode \(sameEdit)")
        // The panel reads editMode, scale and resetToken, and only writes showingModel.
        let model = fires({ _ = ($0.editMode, $0.scale, $0.resetToken) }, { $0.showingModel = true })
        record(cat, "Visualizer controls: showingModel leaves the panel alone", pass: !model)
        let zoom = fires({ _ = $0.scale }, { $0.scale = 0.8 })
        let reset = fires({ _ = $0.resetToken }, { $0.resetToken += 1 })
        let edit = fires({ _ = ($0.editMode, $0.showingModel) }, { $0.editMode.toggle() })
        record(cat, "Visualizer controls: zoom, Reset and Edit Layout notify their readers",
               pass: zoom && reset && edit, detail: "zoom \(zoom), reset \(reset), edit \(edit)")
        let clock = VisualizerRenderClock()
        let ticked = Fired()
        withObservationTracking { _ = clock.generation } onChange: { ticked.count += 1 }
        clock.generation &+= 1
        record(cat, "Render clock: a tick notifies the live host", pass: ticked.count == 1, detail: "\(ticked.count)")
    }

    // MARK: - Idle wakeups

    /// The decisions that let a resting app sleep: which presets want the
    /// DualSense report stream, and the engine poll's idle rate.
    private func runIdleWakeTests() {
        let cat = "Idle wakeups"
        let published = DualSenseSupplementService.publishedButtons
        #if DEBUG
        // The set the engine checks is the set the decoder publishes: a USB
        // report with PS, mute, both FN buttons and both paddles down.
        let S = DualSenseSupplementService.shared
        let location: UInt64 = 0xD4D4_0000_0000_0001
        S.debugInstall(location: location, productID: 0x0DF2)
        var report = [UInt8](repeating: 0, count: 64)
        report[0] = 0x01
        report[10] = 0xF5
        S.debugInject(location: location, bytes: report)
        let decoded = Set(S.supplementalButtons(for: nil, sonySlotCount: 1).keys)
        // Let go again, so nothing reads as held after the check.
        report[10] = 0
        S.debugInject(location: location, bytes: report)
        record(cat, "Supplement buttons match what the decoder publishes", pass: decoded == published,
               detail: "decoded \(decoded.sorted()), engine checks \(published.sorted())")
        #endif
        for b in published.sorted() {
            record(cat, "A row on button \(b) wants the DualSense stream",
                   pass: MappingEngine.wantsSupplement(buttonsRead: [0, 1, b], holdButtons: [8]))
            record(cat, "The hold on button \(b) wants the DualSense stream",
                   pass: MappingEngine.wantsSupplement(buttonsRead: [0], holdButtons: [b]))
        }
        record(cat, "Plain buttons and the default hold leave the stream off",
               pass: !MappingEngine.wantsSupplement(buttonsRead: Set(0...9).union([11, 12, 13, 14, 18, 19]), holdButtons: [8, 9]))

        func rate(pad: Bool, reads: Bool, hold: Bool, editor: Bool = false, listener: Bool = false) -> Int {
            MappingEngine.idlePollRate(fullHz: 120, padConnected: pad, readsPads: reads, holdEnabled: hold,
                                       editorOpen: editor, listenerArmed: listener)
        }
        record(cat, "No pad connected: no idle timer", pass: rate(pad: false, reads: true, hold: true) == 0)
        record(cat, "Keyboard preset, hold off: no idle timer beside a pad", pass: rate(pad: true, reads: false, hold: false) == 0)
        record(cat, "Keyboard preset, hold on, a pad: 30 Hz for the hold", pass: rate(pad: true, reads: false, hold: true) == 30)
        record(cat, "Controller preset, a pad: 30 Hz as before", pass: rate(pad: true, reads: true, hold: false) == 30)
        record(cat, "Editor open, no pad: 30 Hz for its scan edges", pass: rate(pad: false, reads: true, hold: true, editor: true) == 30)
        record(cat, "Listening sheet, no pad: 30 Hz for its edge", pass: rate(pad: false, reads: true, hold: true, listener: true) == 30)
    }

    // MARK: - 1. OutputAction Round-Trip Tests

    private func runOutputActionTests() {
        let cases: [(String, OutputAction)] = [
            ("Keyboard A", OutputAction(type: .key, keyCode: 4)),
            ("Mouse Click", OutputAction(type: .mouseButton, mouseButtonIndex: 0)),
            ("Mouse Move Right", OutputAction(type: .mouseMotion, mouseAxis: .horizontal, mouseDirection: .positive, speed: 14)),
            ("Scroll Up", OutputAction(type: .mouseWheel, mouseAxis: .vertical, mouseDirection: .negative, speed: 8)),
            ("Wheel Step", OutputAction(type: .mouseWheelStep, mouseAxis: .vertical, mouseDirection: .positive)),
            ("Mouse Motion Step Left 25", OutputAction(type: .mouseStep, mouseAxis: .horizontal, mouseDirection: .negative, speed: 25)),
            ("Precision While Held 40%", { var a = OutputAction(type: .appAction, appActionKind: .holdPrecision); a.speed = 40; return a }()),
            ("Return Pointer to Spot 3", { var a = OutputAction(type: .appAction, appActionKind: .returnPointer); a.speed = 3; return a }()),
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
                       parsed.midiChannel == original.midiChannel &&
                       parsed.appActionKind == original.appActionKind &&
                       parsed.serialized == original.serialized
            record("OutputAction", label, pass: same,
                   detail: "\"\(serialized)\" \(same ? "round-trips correctly" : "did not match after parse")")
        }
        // Mouse Motion Step: macro text both ways, and the distance clamp.
        let nudge = OutputAction(type: .mouseStep, mouseAxis: .vertical, mouseDirection: .positive, speed: 40)
        let words = nudge.macroTextWords ?? ""
        let back = OutputAction.fromMacroText(verb: "nudge", args: ["down", "40"])
        record("OutputAction", "Mouse Motion Step as macro text",
               pass: words == "nudge down 40" && back?.type == .mouseStep && back?.speed == 40
                   && back?.mouseAxis == .vertical && back?.mouseDirection == .positive,
               detail: "\"\(words)\"")
        let diag = OutputAction.fromMacroText(verb: "nudge", args: ["up-left", "15"])
        let diagBack = diag.flatMap { OutputAction.parse($0.serialized) }
        record("OutputAction", "Diagonal Mouse Motion Step",
               pass: diag?.macroTextWords == "nudge up-left 15" && diag?.serialized == "mst 0 - 15 -"
                   && diagBack?.stepDelta.x == -15 && diagBack?.stepDelta.y == -15,
               detail: "\(diag?.serialized ?? "nil") -> \(diagBack.map { "(\($0.stepDelta.x), \($0.stepDelta.y))" } ?? "nil")")
        let far = OutputAction.fromMacroText(verb: "nudge", args: ["left", "9000"])
        let none = OutputAction(type: .mouseStep, mouseAxis: .horizontal, mouseDirection: .positive, speed: 0)
        record("OutputAction", "Mouse Motion Step distance clamps to 1...500",
               pass: far?.resolvedStepDistance == 500 && none.resolvedStepDistance == 1,
               detail: "9000 -> \(far?.resolvedStepDistance ?? -1), 0 -> \(none.resolvedStepDistance)")
        // Through the real writer and parser, as the Text view, a file and
        // a paste use them: a Move pointer by step written is read back.
        let nudgeSteps = [MacroStep(action: nudge), MacroStep(action: diag ?? nudge)]
        let nudgeText = MacroText.write(steps: nudgeSteps, options: nil, watches: [], heading: nil)
        let nudgeParsed = MacroText.parse(nudgeText, watches: [], currentOptions: MacroTextOptions())
        record("OutputAction", "Move pointer by step written as macro text parses back",
               pass: !nudgeParsed.hasErrors && nudgeParsed.steps.count == 2
                   && nudgeParsed.steps[0].action.serialized == nudge.serialized
                   && nudgeParsed.steps[1].action.serialized == diag?.serialized,
               detail: nudgeText.replacingOccurrences(of: "\n", with: "; ")
                   + (nudgeParsed.issues.first.map { " (\($0.message))" } ?? ""))
        // Curly quotes typed inside a Type Text survive a round trip.
        let curly = OutputAction(type: .typeText, text: "say \u{201C}hi\u{201D} now")
        let curlyText = MacroText.write(steps: [MacroStep(action: curly)], options: nil, watches: [], heading: nil)
        let curlyParsed = MacroText.parse(curlyText, watches: [], currentOptions: MacroTextOptions())
        record("OutputAction", "Curly quotes inside typed text survive macro text",
               pass: !curlyParsed.hasErrors && curlyParsed.steps.first?.action.text == curly.text,
               detail: curlyText)
        // Convert moves a button sequence's buttons as it moves button rows:
        // Xbox Down, Down, A is Switch Down, Down, A (button 1 there).
        var seqPreset = Preset(name: "Sequence", tag: "Tests")
        seqPreset.joysticks = [JoystickMapping(tag: "Pad", bindings: [
            BindingModel(input: .buttonSequence([253, 253, 0]), outputs: [OutputAction(type: .key, keyCode: 44)])])]
        let seqMoved = ControllerType.convert(preset: seqPreset, from: .xboxSeries, to: .switchPro)
        let seqSteps = seqMoved.joysticks.first?.bindings.first?.input.sequenceSteps ?? []
        record("Presets", "Convert moves a button sequence's steps",
               pass: seqSteps == [253, 253, 1], detail: seqSteps.map(String.init).joined(separator: " "))
        // An untouched 1.8 Macros & Turbo (before X and the sequence) is
        // still the built-in, so a backup restore does not add a second.
        let shippedMacros = ExamplePresets.showcaseMacrosTurbo
        var macros18 = shippedMacros
        macros18.writtenByFormatVersion = 3
        for g in macros18.joysticks.indices {
            macros18.joysticks[g].bindings.removeAll {
                $0.input.type == .buttonSequence || ($0.input.type == .button && $0.input.index == 2)
            }
        }
        record("Presets", "A 1.8 Macros & Turbo copy matches the built-in",
               pass: PresetStore.matchesShipped(macros18, shippedMacros, builtInFolder: nil)
                   && BuiltInUpdate.offers(for: macros18).contains { $0.id == BuiltInUpdate.macrosTurbo19.id })
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

    // MARK: - Spoken tables and the Face button names cache

    /// HotKeySpec.spokenKey and ButtonNames.spokenGlyphs read tables built
    /// once; they used to build them on every call. The old per-call code is
    /// kept here, so every key and glyph is compared with what it gave.
    private func runSpokenTableTests() {
        let cat = "Spoken Tables"
        func oldSpokenKey(_ key: String) -> String {
            let marks = [".": String(localized: "period"), ",": String(localized: "comma"), "/": String(localized: "slash"),
                         ";": String(localized: "semicolon"), ":": String(localized: "colon"),
                         "!": String(localized: "exclamation mark"), "-": String(localized: "hyphen"),
                         "=": String(localized: "equals sign"), "?": String(localized: "question mark"),
                         "'": String(localized: "apostrophe"), "esc": String(localized: "escape"),
                         "[": String(localized: "left bracket"), "]": String(localized: "right bracket"),
                         "\\": String(localized: "backslash"), "`": String(localized: "grave accent"),
                         "^": String(localized: "caret"), "<": String(localized: "less than"),
                         "#": String(localized: "number sign"), "\u{00B4}": String(localized: "acute accent"),
                         "*": String(localized: "asterisk")]
            let bare = key.hasPrefix("\u{200F}") ? String(key.dropFirst()) : key
            return marks[bare] ?? key
        }
        func oldSpokenGlyphs(_ name: String) -> String {
            let words: [Character: String] = [
                "\u{00D7}": String(localized: "spoken.cross", defaultValue: "Cross", comment: "The PlayStation Cross button, as a screen reader says it"),
                "\u{25CB}": String(localized: "spoken.circle", defaultValue: "Circle", comment: "The PlayStation Circle button, as a screen reader says it"),
                "\u{25A1}": String(localized: "spoken.square", defaultValue: "Square", comment: "The PlayStation Square button, as a screen reader says it"),
                "\u{25B3}": String(localized: "spoken.triangle", defaultValue: "Triangle", comment: "The PlayStation Triangle button, as a screen reader says it"),
                "\u{2715}": String(localized: "spoken.cross", defaultValue: "Cross", comment: "The PlayStation Cross button, as a screen reader says it"),
            ]
            guard name.contains(where: { words[$0] != nil }) else { return name }
            return name.map { words[$0] ?? String($0) }.joined()
        }

        // Every mark in the table, bare and behind the right-to-left mark,
        // every key code's name, and names that are not marks.
        var keys = HotKeySpec.spokenMarkWords.keys.flatMap { [$0, "\u{200F}" + $0] }
        keys += (0...127).map { HotKeySpec.keyName(for: UInt32($0)) }
        keys += ["", "a", "Esc", "Keypad .", "Space", "\u{200F}", "..", "F12"]
        let keyMisses = keys.filter { HotKeySpec.spokenKey($0) != oldSpokenKey($0) }
        let markMisses = keys.map { "Command + \($0)" }.filter {
            HotKeySpec.spokenMarks(in: $0) != $0.components(separatedBy: " ").map(oldSpokenKey).joined(separator: " ")
        }
        record(cat, "Spoken key names equal the old per-call table for every key",
               pass: keyMisses.isEmpty && markMisses.isEmpty && HotKeySpec.spokenMarkWords.count == 20,
               detail: keyMisses.isEmpty && markMisses.isEmpty
                   ? "\(keys.count) names, \(HotKeySpec.spokenMarkWords.count) marks"
                   : "differ: \((keyMisses + markMisses).prefix(6).joined(separator: " | "))")

        // Every glyph alone and in a name, every family's button names under
        // every face choice, and plain words.
        var names = ButtonNames.spokenGlyphWords.keys.flatMap { [String($0), "\($0) button", "L1 + \($0)"] }
        for family in FaceLetters.allCases {
            for choice in [FaceLetters.automatic, .xbox, .playstation, .nintendo, .positions] {
                names += (0..<24).map { ButtonNames.label($0, family: family, choice: choice) }
            }
        }
        names += ["", "Cross", "A", "\u{00D7}\u{25CB}\u{25A1}\u{25B3}\u{2715}"]
        let glyphMisses = names.filter { ButtonNames.spokenGlyphs($0) != oldSpokenGlyphs($0) }
        record(cat, "Spoken glyph names equal the old per-call table for every glyph",
               pass: glyphMisses.isEmpty && ButtonNames.spokenGlyphWords.count == 5,
               detail: glyphMisses.isEmpty ? "\(names.count) names, \(ButtonNames.spokenGlyphWords.count) glyphs"
                                          : "differ: \(glyphMisses.prefix(6).joined(separator: " | "))")
    }

    /// FaceLetters.current is cached; a change of the Face button names
    /// setting, from this thread or another, must show at the next read.
    private func runFaceLettersCacheTests() async {
        let cat = "Face Button Names"
        let d = UserDefaults.standard
        let key = FaceLetters.defaultsKey
        let saved = d.string(forKey: key)
        defer {
            if let saved { d.set(saved, forKey: key) } else { d.removeObject(forKey: key) }
        }
        var wrong: [String] = []
        _ = FaceLetters.current
        for choice in [FaceLetters.playstation, .nintendo, .positions, .xbox, .automatic, .playstation] {
            d.set(choice.rawValue, forKey: key)
            let first = FaceLetters.current, again = FaceLetters.current
            let label = ButtonNames.label(0, family: nil)
            if first != choice || again != choice || FaceLetters.stored != choice
                || label != ButtonNames.label(0, family: nil, choice: choice) {
                wrong.append("\(choice.rawValue): \(first.rawValue)/\(again.rawValue) \"\(label)\"")
            }
        }
        d.removeObject(forKey: key)
        if FaceLetters.current != .automatic { wrong.append("removed: \(FaceLetters.current.rawValue)") }
        d.set("not a choice", forKey: key)
        if FaceLetters.current != .automatic { wrong.append("unknown: \(FaceLetters.current.rawValue)") }
        record(cat, "The cached Face button names follow each settings change",
               pass: wrong.isEmpty, detail: wrong.isEmpty ? "6 changes, a removal, an unknown value" : wrong.joined(separator: "; "))

        // A write on another thread, then a read here.
        d.set(FaceLetters.xbox.rawValue, forKey: key)
        _ = FaceLetters.current
        await Task.detached { UserDefaults.standard.set(FaceLetters.nintendo.rawValue, forKey: FaceLetters.defaultsKey) }.value
        let afterOther = FaceLetters.current
        record(cat, "The cached Face button names follow a write from another thread",
               pass: afterOther == .nintendo, detail: afterOther.rawValue)
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

        // Pointer speed on the Mac's own mouse and trackpad: a move goes back
        // to where it started and lands at the delta times the speed.
        let half = PointerSpeedShaper.scaledLocation(from: CGPoint(x: 100, y: 200), delta: CGVector(dx: 10, dy: 10), speed: 0.5, within: nil)
        record("Pointer Speed", "Half speed moves half as far, the same way", pass: half == CGPoint(x: 105, y: 205), detail: "\(half)")
        let double = PointerSpeedShaper.scaledLocation(from: CGPoint(x: 100, y: 204), delta: CGVector(dx: 10, dy: -4), speed: 2, within: nil)
        record("Pointer Speed", "Double speed lands twice as far", pass: double == CGPoint(x: 120, y: 196), detail: "\(double)")
        let edge = PointerSpeedShaper.scaledLocation(from: CGPoint(x: 1905, y: 15), delta: CGVector(dx: 10, dy: -5), speed: 3,
                                                     within: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        record("Pointer Speed", "Kept on the screen", pass: edge.x == 1919 && edge.y == 0, detail: "\(edge)")

        // Sony pads checked against GameController: the bits read the way
        // SDL's PS5 and PS4 drivers read them.
        record("Sony Check", "Cross, Circle, Square, Triangle bits", pass: DualSenseSupplementService.pressedMain(0x20 | 0x40 | 0x10 | 0x80 | 0x08, 0) == [0, 1, 2, 3])
        record("Sony Check", "Shoulders, Create, Options, stick clicks", pass: DualSenseSupplementService.pressedMain(0x08, 0x01 | 0x02 | 0x10 | 0x20 | 0x40 | 0x80) == [4, 5, 8, 9, 11, 12])
        var dsUSB = [UInt8](repeating: 0, count: 64); dsUSB[0] = 0x01; dsUSB[8] = 0x48; dsUSB[9] = 0x20
        let dsMain = dsUSB.withUnsafeBufferPointer { DualSenseSupplementService.mainButtons($0.baseAddress!, length: 64, isDS4: false) }
        record("Sony Check", "DualSense USB buttons at 8 and 9", pass: dsMain.map { $0.0 == 0x48 && $0.1 == 0x20 } == true)
        var ds4USB = [UInt8](repeating: 0, count: 64); ds4USB[0] = 0x01; ds4USB[5] = 0x28; ds4USB[6] = 0x01
        let ds4Main = ds4USB.withUnsafeBufferPointer { DualSenseSupplementService.mainButtons($0.baseAddress!, length: 64, isDS4: true) }
        record("Sony Check", "DualShock 4 USB buttons at 5 and 6", pass: ds4Main.map { $0.0 == 0x28 && $0.1 == 0x01 } == true)
        let simple = [UInt8](repeating: 0, count: 10)
        record("Sony Check", "A short report is not read", pass: simple.withUnsafeBufferPointer { DualSenseSupplementService.mainButtons($0.baseAddress!, length: 10, isDS4: false) } == nil)

        let calm = PointerSpeedShaper.steadied(CGVector(dx: 10, dy: 0), previous: CGVector(dx: 0, dy: 0), steadying: 1)
        record("Pointer Speed", "Steadying keeps part of the last move", pass: abs(calm.dx - 1.5) < 0.0001 && calm.dy == 0, detail: "\(calm)")
        let none = PointerSpeedShaper.steadied(CGVector(dx: 10, dy: -3), previous: CGVector(dx: 50, dy: 50), steadying: 0)
        record("Pointer Speed", "No steadying passes the move as it came", pass: none.dx == 10 && none.dy == -3, detail: "\(none)")

        // 8BitDo motors, as SDL_hidapi_8bitdo.c sends them.
        let motors = "8BitDo Motors"
        record(motors, "Full buzz is report 0x05 with both motors at 255",
               pass: RawHIDGamepadService.eightBitDoRumbleReport(intensity: 1) == [0x05, 255, 255, 0, 0])
        record(motors, "Off is report 0x05 with both motors at 0",
               pass: RawHIDGamepadService.eightBitDoRumbleReport(intensity: 0) == [0x05, 0, 0, 0, 0])
        record(motors, "Intensity is clamped", pass: RawHIDGamepadService.eightBitDoRumbleReport(intensity: 3)[1] == 255
               && RawHIDGamepadService.eightBitDoRumbleReport(intensity: -1)[2] == 0)
        record(motors, "Only the Ultimate 2 Wireless (2DC8:6012), from its 34 byte firmware 1.03 reports",
               pass: RawHIDGamepadService.eightBitDoRumbleProducts == [0x6012: 34] && RawHIDGamepadService.eightBitDoRumbleVendor == 0x2DC8)

        // The caps the user picks: the drawing follows them.
        let plain = ControllerLayout.psAccess(ports: [:], profile: nil)
        record(cat, "Caps: pillow and dome leave the drawing as is",
               pass: ControllerLayout.applyingAccessCaps(AccessCapSet(), to: plain).controls.count == plain.controls.count)
        var wide = AccessCapSet(); wide.sockets[5] = .wideFlat
        let wideLayout = ControllerLayout.applyingAccessCaps(wide, to: plain)
        record(cat, "Caps: a wide flat cap on 5 covers 6 and answers to both",
               pass: wideLayout.control("socket6") == nil && wideLayout.control("socket5")?.inputs.buttons.contains(44) == true
                   && wideLayout.control("socket5")?.inputs.buttons.contains(45) == true,
               detail: "\(String(describing: wideLayout.control("socket5")?.inputs.buttons))")
        var tagged = AccessCapSet(); tagged.tags[5] = 4
        record(cat, "Caps: a Square tag on socket 5 draws a square", pass: ControllerLayout.applyingAccessCaps(tagged, to: plain).control("socket5")?.symbol == "square")
        record(cat, "Caps: a cap label follows the function code", pass: ControllerLayout.accessCapLabel(code: 3, socket: 5).symbol == "triangle"
               && ControllerLayout.accessCapLabel(code: 9, socket: 2).printed == "L1" && ControllerLayout.accessCapLabel(code: nil, socket: 6).printed == "6")
        var wrap = AccessCapSet(); wrap.sockets[8] = .wideFlat
        record(cat, "Caps: a wide flat cap on 8 covers 1", pass: ControllerLayout.applyingAccessCaps(wrap, to: plain).control("socket1") == nil)
        var mixedCaps = AccessCapSet(); mixedCaps.sockets[1] = .curve; mixedCaps.sockets[3] = .overhang; mixedCaps.sockets[4] = .bare; mixedCaps.stick = .ball
        let mixedLayout = ControllerLayout.applyingAccessCaps(mixedCaps, to: plain)
        let s3 = mixedLayout.control("socket3"), s3plain = plain.control("socket3")
        record(cat, "Caps: curve, overhang toward the center, bare socket, ball stick",
               pass: { if case .curve? = mixedLayout.control("socket1")?.shape { return true }; return false }()
                   && (s3.map { abs($0.center.y - 0.5) } ?? 1) < (s3plain.map { abs($0.center.y - 0.5) } ?? 0)
                   && (mixedLayout.control("socket4")?.size ?? 1) < 0.1
                   && (mixedLayout.control("stick")?.size ?? 1) < (plain.control("stick")?.size ?? 0))

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

    // MARK: - 7c2. Raw, Steam and wheel pads waking the resting poll

    /// What counts as a move on a direct pad, and DirectPadActivity's wake:
    /// only watched sources, one wake per rest however many reports, none
    /// once the poll woke by itself, none after a stop.
    private func runDirectPadIdleTests() {
        let cat = "Direct Pad Idle"
        var rest = ControllerState()
        rest.buttons = [0: 0, 1: 0]; rest.axes = [0: 0.1, 1: -0.2]; rest.hats = [0: (x: 0, y: 0)]
        rest.motion = [.gyroX: 0.01]
        var imuOnly = rest; imuOnly.motion = [.gyroX: 0.5, .accelZ: 1]
        var press = rest; press.buttons[1] = 1
        var tilt = rest; tilt.axes[0] = 0.11
        var hat = rest; hat.hats[0] = (x: 0, y: -1)
        var extra = ControllerState(); extra.buttons = [14: 0]
        typealias G = RawHIDGamepad
        record(cat, "A repeat or an IMU-only sample is not a move",
               pass: !G.movesControls(rest, over: rest) && !G.movesControls(imuOnly, over: rest) && !G.movesControls(ControllerState(), over: rest))
        record(cat, "A press, a stick step or a hat is a move",
               pass: G.movesControls(press, over: rest) && G.movesControls(tilt, over: rest) && G.movesControls(hat, over: rest))
        record(cat, "A control seen for the first time is a move", pass: G.movesControls(extra, over: rest))

        final class Held: @unchecked Sendable { var blocks: [@Sendable () -> Void] = [] }
        let held = Held()
        let activity = DirectPadActivity(post: { held.blocks.append($0) })
        var wakes = 0
        let read = NSObject(), unread = NSObject()
        activity.setWake { wakes += 1 }
        activity.watch([ObjectIdentifier(read)])
        activity.setResting(true)
        activity.noteChange(ObjectIdentifier(unread))
        record(cat, "An unread pad neither wakes nor stamps", pass: held.blocks.isEmpty && activity.lastChangeTime == 0)
        activity.noteChange(ObjectIdentifier(read))
        activity.noteChange(ObjectIdentifier(read))
        record(cat, "A read pad sends one wake per rest", pass: held.blocks.count == 1 && activity.lastChangeTime > 0)
        held.blocks.forEach { $0() }; held.blocks.removeAll()
        record(cat, "The wake reaches the engine", pass: wakes == 1)
        activity.setResting(false)
        let stamped = activity.lastChangeTime
        activity.noteChange(ObjectIdentifier(read))
        record(cat, "At full rate a move only stamps", pass: held.blocks.isEmpty && activity.lastChangeTime >= stamped)
        activity.setResting(true)
        activity.noteChange(ObjectIdentifier(read))
        activity.setResting(false)
        held.blocks.forEach { $0() }; held.blocks.removeAll()
        record(cat, "A wake that finds the poll awake does nothing", pass: wakes == 1)
        activity.setResting(true)
        activity.noteChange(ObjectIdentifier(read))
        record(cat, "The next rest wakes again", pass: held.blocks.count == 1)
        held.blocks.removeAll()
        activity.reset()
        activity.noteChange(ObjectIdentifier(read))
        record(cat, "Nothing after a stop", pass: held.blocks.isEmpty && activity.lastChangeTime == 0 && !activity.watches(ObjectIdentifier(read)))
    }

    // MARK: - 7d. Switch 2 flash calibration and enabler commands

    /// The motion math every pad shares: the raw IMU helper (gravity,
    /// tilt angles, the turn sign) and the GameController path's gravity
    /// carrier, with synthetic samples in the frame the code documents
    /// (X right, Y away from the player, Z up out of the face).
    /// The controller drawing redraws a control only when what it shows
    /// changed (ControllerCanvas's cells): on a DualSense, Cross pressed
    /// redraws Cross alone and the left stick moved the left stick alone; a
    /// new token redraws every control, an open inspector its own.
    private func runCanvasCellTests() {
        #if DEBUG
        guard let layout = ControllerLayoutCatalog.layout(.dualSense) else {
            record("Controller drawing", "The DualSense drawing for the cell checks", pass: false); return
        }
        func canvas(_ st: ControllerState, token: Int = 1, open: String? = nil) -> ControllerCanvas {
            ControllerCanvas(layout: layout, state: st, legend: { _ in (nil, nil) }, caption: { _ in nil },
                             inspect: { _, v in v }, cellToken: token, openControl: open)
        }
        let rest = canvas(ControllerState())
        func redrawn(_ other: ControllerCanvas) -> [String] {
            layout.controls.filter { other.debugCellRedraws($0, since: rest) }.map(\.id).sorted()
        }
        var pressed = ControllerState()
        pressed.buttons[0] = 1
        var moved = ControllerState()
        moved.axes[0] = 0.4
        let none = redrawn(canvas(ControllerState())), press = redrawn(canvas(pressed)), move = redrawn(canvas(moved))
        let token = redrawn(canvas(ControllerState(), token: 2)), open = redrawn(canvas(ControllerState(), open: "cross"))
        record("Controller drawing", "Nothing changed redraws no control", pass: none.isEmpty, detail: none.joined(separator: ", "))
        record("Controller drawing", "A press redraws that control alone", pass: press == ["cross"], detail: press.joined(separator: ", "))
        record("Controller drawing", "A stick moving redraws that stick alone", pass: move == ["lstick"], detail: move.joined(separator: ", "))
        record("Controller drawing", "A new token redraws every control", pass: token == layout.controls.map(\.id).sorted(),
               detail: "\(token.count) of \(layout.controls.count)")
        record("Controller drawing", "An open inspector redraws its control", pass: open == ["cross"], detail: open.joined(separator: ", "))
        #endif
    }

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
            // Restored whatever happens, so a trap in the read never leaves
            // the user's setting at 7.
            defer { if let old { UserDefaults.standard.set(old, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
            UserDefaults.standard.set(7, forKey: key); let v = P.shared.idleMinutes
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
            // A connected Switch 2 Pro's own calibration is put back after.
            let theirs = C.current(product: 0x2069)
            defer { C.store(theirs, product: 0x2069) }
            var report = [UInt8](repeating: 0, count: 64)
            report[0] = 0x09; report[6] = 0x00; report[7] = 0x0C; report[8] = 0x80   // left X 3072, Y 2048
            report[9] = 0x00; report[10] = 0x08; report[11] = 0x80
            C.store(C.from(replies: [C.leftStickAddress: reply(stick: [0x00, 0x08, 0x80, 0x00, 0x04, 0x40, 0x00, 0x06, 0x60])]), product: 0x2069)
            let mapped = HIDReportDecoder.decode(report: Data(report), profile: proProfile).axes[0] ?? 0
            C.store(nil, product: 0x2069)
            let fallback = HIDReportDecoder.decode(report: Data(report), profile: proProfile).axes[0] ?? 0
            record(cat, "Decoder uses the stored calibration and falls back without it", pass: abs(mapped - 1) < 0.001 && abs(fallback - 0.62) < 0.01,
                   detail: "calibrated \(mapped), fallback \(fallback)")
        } else {
            skip(cat, "Decoder uses the stored calibration and falls back without it", detail: "No Switch 2 Pro profile")
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

    /// The detail page's typed name and tag: kept with the preset they were
    /// typed on, written in one change, and nothing written when unchanged.
    private func runPageHeaderDraftTests() {
        let cat = "Page header draft"
        var a = Preset(name: "Racing", tag: "No tag", joysticks: [JoystickMapping(tag: "")])
        let b = Preset(name: "Flying", tag: "Planes", joysticks: [JoystickMapping(tag: "")])
        var draft = PresetHeaderDraft(presetID: a.id)
        draft.name = "Racing 2"
        record(cat, "Typing shows only on the preset it was typed on",
               pass: draft.text(\.name, on: a.id) == "Racing 2" && draft.text(\.name, on: b.id) == nil
                   && draft.text(\.tag, on: a.id) == nil,
               detail: "on A \(draft.text(\.name, on: a.id) ?? "nil"), on B \(draft.text(\.name, on: b.id) ?? "nil")")
        let changed = draft.apply(to: &a)
        record(cat, "A typed name is written and the untyped tag kept",
               pass: changed && a.name == "Racing 2" && a.tag == "No tag",
               detail: "changed \(changed), name \(a.name), tag \(a.tag)")
        draft.tag = "No tag"
        let again = draft.apply(to: &a)
        record(cat, "Text typed back to what is stored writes nothing", pass: !again,
               detail: "changed \(again)")
    }

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

        // A backup's Type Text gets the import's cap on restore, in every
        // list a row can carry it in.
        let long = String(repeating: "a", count: Preset.importTextLimit * 2)
        var longRow = BindingModel(input: InputEvent.button(0), outputs: [OutputAction(type: .typeText, text: long)])
        longRow.holdOutputs = [OutputAction(type: .typeText, text: long)]
        longRow.macroSteps = [MacroStep(action: OutputAction(type: .typeText, text: long))]
        var restored = Preset(name: "Long text", tag: "Tests", joysticks: [JoystickMapping(tag: "Pad", bindings: [longRow])])
        PresetStore.capTypedText(&restored)
        let capped = restored.joysticks[0].bindings[0]
        record("Preset Codable", "A restored backup's Type Text is cut to the import limit",
               pass: capped.outputs[0].text?.count == Preset.importTextLimit
                   && capped.holdOutputs?[0].text?.count == Preset.importTextLimit
                   && capped.macroSteps?[0].action.text?.count == Preset.importTextLimit,
               detail: "\(capped.outputs[0].text?.count ?? -1) characters")
    }

    // MARK: - 8b. Screen color, screen text and voice phrase (1.9)

    /// "spx", "stx" and "vph" carry a watch or phrase id and nothing else:
    /// the id survives a round trip, and a token with a garbage id or no
    /// id parses to nil like any other malformed token.
    private func runScreenInputEventTests() {
        let cat = "InputEvent"
        let id = UUID()
        let cases: [(String, InputEvent, String, (InputEvent) -> UUID?)] = [
            ("Screen color spx", InputEvent.screenPixel(id), "spx", { $0.screenPixelID }),
            ("Screen text stx", InputEvent.screenText(id), "stx", { $0.screenTextID }),
            ("Voice phrase vph", InputEvent.voicePhrase(id), "vph", { $0.voicePhraseID }),
        ]
        for (label, original, prefix, field) in cases {
            let serialized = original.serialized
            let parsed = InputEvent.parse(serialized)
            let ok = serialized.hasPrefix("\(prefix) ") && serialized.count == prefix.count + 33
                && parsed?.type == original.type && parsed.flatMap(field) == id
                && parsed?.serialized == serialized
            record(cat, label, pass: ok,
                   detail: ok ? "\"\(serialized)\" round-trips correctly" : "Mismatch parsing \"\(serialized)\"")

            // Malformed tokens: no id, a short id, 32 characters that are
            // not hex, a dashed id, and a second word that is not an id.
            let bad = ["\(prefix)", "\(prefix) ", "\(prefix) 1234", "\(prefix) " + String(repeating: "zz", count: 16),
                       "\(prefix) \(id.uuidString)", "\(prefix) 12", "\(prefix) " + String(repeating: "0", count: 33)]
            let survivors = bad.filter { InputEvent.parse($0) != nil }
            record(cat, "\(label) rejects garbage", pass: survivors.isEmpty,
                   detail: survivors.isEmpty ? "\(bad.count) malformed tokens parse to nil" : "Parsed: \(survivors)")
        }
        // The nil-id placeholder serializes to the zero id and reads back.
        let bare = InputEvent(type: .screenPixel, index: 0)
        let zero = InputEvent.parse(bare.serialized)
        record(cat, "Screen color without id", pass: zero?.type == .screenPixel && zero?.screenPixelID?.uuidString == "00000000-0000-0000-0000-000000000000",
               detail: "\"\(bare.serialized)\" parses to the zero id")
    }

    /// The three 1.9 models encode and decode to equal values, read a
    /// hand-edited JSON with missing and out-of-range fields without a
    /// trap, and clamp once (clamping a clamped value changes nothing).
    private func runScreenWatchCodableTests() {
        let cat = "Screen Watch Codable"
        let display = DisplayKey(vendor: 1552, model: 43217, serial: 0, name: "Bench Display", uuid: "BENCH-UUID")
        let pixel = ScreenPixelWatch(name: "Pixel", display: display, x: 0.125, y: 0.875, red: 10, green: 200, blue: 30,
                                     tolerance: 0.3, mode: .change, colorIndex: 3)
        var text = ScreenTextWatch()
        text.name = "Text"; text.display = display; text.minX = 0.1; text.minY = 0.2; text.maxX = 0.6; text.maxY = 0.7
        text.text = "Ready to go"; text.mode = .appears; text.colorIndex = 2
        var phrase = VoicePhrase()
        phrase.name = "Phrase"; phrase.phrase = "jump now"; phrase.colorIndex = 5

        func roundTrip<T: Codable & Equatable>(_ label: String, _ value: T) {
            do {
                let data = try JSONEncoder().encode(value)
                let back = try JSONDecoder().decode(T.self, from: data)
                record(cat, label, pass: back == value, detail: back == value ? "Encode/decode equal" : "Decoded value differs")
            } catch {
                record(cat, label, pass: false, detail: "\(error)")
            }
        }
        roundTrip("ScreenPixelWatch round trip", pixel)
        roundTrip("ScreenTextWatch round trip", text)
        roundTrip("VoicePhrase round trip", phrase)

        // A watch without a display encodes no "display" key, so a preset
        // exported from one Mac is not pinned to its monitors.
        var free = pixel; free.display = nil
        if let data = try? JSONEncoder().encode(free), let json = String(data: data, encoding: .utf8) {
            record(cat, "Display left out when nil", pass: !json.contains("\"display\""), detail: json)
        } else {
            record(cat, "Display left out when nil", pass: false, detail: "did not encode")
        }

        // Tolerant decoding: nothing here traps, every number is clamped,
        // an unknown mode falls back to the default.
        let pixelJSON = """
        {"name":"Edited","x":-3,"y":2.5,"red":300,"green":-1,"blue":12,"tolerance":5.0,"mode":"unknown","colorIndex":-4}
        """
        if let w = try? JSONDecoder().decode(ScreenPixelWatch.self, from: Data(pixelJSON.utf8)) {
            let ok = w.name == "Edited" && w.x == 0 && w.y == 1 && w.red == 255 && w.green == 0 && w.blue == 12
                && w.tolerance == 1 && w.mode == .match && w.colorIndex == 0 && w.display == nil
            record(cat, "ScreenPixelWatch tolerant decode", pass: ok,
                   detail: "x=\(w.x) y=\(w.y) rgb=\(w.red),\(w.green),\(w.blue) tolerance=\(w.tolerance) mode=\(w.mode) colorIndex=\(w.colorIndex)")
            record(cat, "ScreenPixelWatch clamp idempotent", pass: w.clampedValues() == w && w.clampedValues().clampedValues() == w.clampedValues(),
                   detail: "clampedValues() on a decoded watch changes nothing")
        } else {
            record(cat, "ScreenPixelWatch tolerant decode", pass: false, detail: "Decode failed")
        }
        let textJSON = """
        {"minX":0.9,"maxX":0.2,"minY":"nope","maxY":7,"mode":"unknown","text":"Go","colorIndex":-1,"id":"not a uuid"}
        """
        if let w = try? JSONDecoder().decode(ScreenTextWatch.self, from: Data(textJSON.utf8)) {
            let ok = w.minX == 0.2 && w.maxX == 0.9 && w.minY == 0.25 && w.maxY == 1 && w.mode == .shows
                && w.text == "Go" && w.colorIndex == 0 && w.name == ""
            record(cat, "ScreenTextWatch tolerant decode", pass: ok,
                   detail: "min=\(w.minX),\(w.minY) max=\(w.maxX),\(w.maxY) mode=\(w.mode) colorIndex=\(w.colorIndex)")
            record(cat, "ScreenTextWatch clamp idempotent", pass: w.clampedValues() == w,
                   detail: "clampedValues() on a decoded watch changes nothing")
        } else {
            record(cat, "ScreenTextWatch tolerant decode", pass: false, detail: "Decode failed")
        }
        if let p = try? JSONDecoder().decode(VoicePhrase.self, from: Data("{\"phrase\":\"hi\",\"colorIndex\":-9}".utf8)) {
            record(cat, "VoicePhrase tolerant decode", pass: p.phrase == "hi" && p.colorIndex == 0 && p.name == "",
                   detail: "phrase=\(p.phrase) colorIndex=\(p.colorIndex)")
        } else {
            record(cat, "VoicePhrase tolerant decode", pass: false, detail: "Decode failed")
        }
        let empty = (try? JSONDecoder().decode(ScreenPixelWatch.self, from: Data("{}".utf8))) != nil
            && (try? JSONDecoder().decode(ScreenTextWatch.self, from: Data("{}".utf8))) != nil
            && (try? JSONDecoder().decode(VoicePhrase.self, from: Data("{}".utf8))) != nil
        record(cat, "Empty object decodes to defaults", pass: empty, detail: "{} reads as a default watch or phrase")

        // Inverted bounds are swapped, not clamped to a line.
        var inverted = ScreenTextWatch()
        inverted.minX = 0.8; inverted.maxX = 0.3; inverted.minY = 0.9; inverted.maxY = 0.1
        let c = inverted.clampedValues()
        record(cat, "ScreenTextWatch swaps inverted bounds", pass: c.minX == 0.3 && c.maxX == 0.8 && c.minY == 0.1 && c.maxY == 0.9 && c.clampedValues() == c,
               detail: "min=\(c.minX),\(c.minY) max=\(c.maxX),\(c.maxY)")
    }

    /// A preset carries all three arrays through JSON, and a preset with
    /// none of them writes none of the three keys, so a pre-1.9 preset
    /// encodes to the same bytes it did before the arrays existed.
    private func runScreenWatchPresetTests() {
        let cat = "Preset Codable"
        var full = Preset(name: "Screen and voice", tag: "Tests")
        full.screenPixels = [ScreenPixelWatch(name: "A", display: nil, x: 0.2, y: 0.3, red: 1, green: 2, blue: 3),
                             ScreenPixelWatch(name: "B", display: nil, x: 0.4, y: 0.5, red: 4, green: 5, blue: 6, tolerance: 0.5, mode: .change)]
        var t = ScreenTextWatch(); t.text = "Paused"; t.mode = .appears
        full.screenTexts = [t]
        var v = VoicePhrase(); v.phrase = "next page"
        full.voicePhrases = [v]
        full.joysticks = [JoystickMapping(tag: "Stick", bindings: [
            BindingModel(id: UUID(), input: .screenPixel(full.screenPixels[0].id), outputs: [OutputAction(type: .key, keyCode: 4)]),
            BindingModel(id: UUID(), input: .screenText(t.id), outputs: [OutputAction(type: .key, keyCode: 5)]),
            BindingModel(id: UUID(), input: .voicePhrase(v.id), outputs: [OutputAction(type: .key, keyCode: 6)]),
        ])]

        func keys(_ data: Data) -> Set<String> {
            ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]).map { Set($0.keys) } ?? []
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(full)
            let back = try JSONDecoder().decode(Preset.self, from: data)
            let same = back.screenPixels == full.screenPixels && back.screenTexts == full.screenTexts && back.voicePhrases == full.voicePhrases
            record(cat, "Screen and voice arrays round-trip", pass: same,
                   detail: same ? "\(full.screenPixels.count) colors, \(full.screenTexts.count) texts, \(full.voicePhrases.count) phrases survived" : "Arrays differ after decode")
            let inputs = back.joysticks.first?.bindings.map(\.input) ?? []
            record(cat, "Screen and voice bindings round-trip",
                   pass: inputs.count == 3 && inputs[0].screenPixelID == full.screenPixels[0].id
                         && inputs[1].screenTextID == t.id && inputs[2].voicePhraseID == v.id,
                   detail: "Binding inputs keep their watch and phrase ids")
            let fullKeys = keys(data)
            record(cat, "Populated preset writes the three keys",
                   pass: fullKeys.isSuperset(of: ["screenPixels", "screenTexts", "voicePhrases"]), detail: "keys=\(fullKeys.count)")

            // Pre-1.9 byte identity: the same preset with the arrays empty
            // and the bindings gone encodes without the three keys, and
            // with exactly the other keys the populated one has.
            var legacy = full
            legacy.screenPixels = []; legacy.screenTexts = []; legacy.voicePhrases = []; legacy.joysticks = []
            let legacyData = try encoder.encode(legacy)
            let legacyKeys = keys(legacyData)
            let absent = legacyKeys.isDisjoint(with: ["screenPixels", "screenTexts", "voicePhrases"])
            record(cat, "Empty arrays leave no keys behind", pass: absent,
                   detail: absent ? "No screenPixels, screenTexts or voicePhrases key in the JSON" : "Found: \(legacyKeys.intersection(["screenPixels", "screenTexts", "voicePhrases"]))")
            record(cat, "Legacy preset keys unchanged", pass: legacyKeys == fullKeys.subtracting(["screenPixels", "screenTexts", "voicePhrases"]),
                   detail: "Only the three 1.9 keys differ between the populated and the empty preset")
            let legacyBack = try JSONDecoder().decode(Preset.self, from: legacyData)
            record(cat, "Legacy preset decodes to empty arrays",
                   pass: legacyBack.screenPixels.isEmpty && legacyBack.screenTexts.isEmpty && legacyBack.voicePhrases.isEmpty
                         && legacyBack.name == legacy.name,
                   detail: "A preset without the keys reads as having none")
            // Encoding is stable: the same value gives the same bytes twice.
            record(cat, "Legacy preset bytes stable", pass: try encoder.encode(legacy) == legacyData,
                   detail: "\(legacyData.count) bytes both times")
        } catch {
            record(cat, "Screen and voice preset", pass: false, detail: "\(error)")
        }

        // One bad entry drops only itself, not the rest of the list.
        let mixed = """
        {"id":"8A1C2E54-2B1E-4E0F-9C1D-3F6A7B8C9D0E","name":"Mixed","screenPixels":[{"x":0.1},"junk",{"x":0.9}],"screenTexts":[7,{"text":"ok"}],"voicePhrases":[{"phrase":"a"},null,{"phrase":"b"}]}
        """
        if let p = try? JSONDecoder().decode(Preset.self, from: Data(mixed.utf8)) {
            record(cat, "Bad list entries dropped one by one",
                   pass: p.screenPixels.count == 2 && p.screenTexts.count == 1 && p.voicePhrases.count == 2,
                   detail: "colors=\(p.screenPixels.count) texts=\(p.screenTexts.count) phrases=\(p.voicePhrases.count)")
        } else {
            record(cat, "Bad list entries dropped one by one", pass: false, detail: "Whole preset failed to decode")
        }
    }

    /// `ScreenTextWatch.normalized` (shared by screen text and voice) and
    /// the voice phrase matcher on words only, no microphone.
    private func runTextNormalizationTests() {
        let cat = "Text Normalization"
        let cases: [(String, String, String)] = [
            ("Mixed case", "Hello WORLD", "hello world"),
            ("Accents", "Café Déjà Vu", "cafe deja vu"),
            ("Curly apostrophe", "Don\u{2019}t stop", "don't stop"),
            ("Straight apostrophe", "Don't stop", "don't stop"),
            ("Left curly quote", "\u{2018}tis", "'tis"),
            ("Punctuation", "Ready! Set, go...", "ready set go"),
            ("Double spaces", "a  b   c", "a b c"),
            ("Leading and trailing", "  padded  ", "padded"),
            ("Tabs and newlines", "one\ttwo\nthree", "one two three"),
            ("Digits kept", "Level 42", "level 42"),
            ("Empty", "", ""),
            ("Only punctuation", "?!.,", ""),
        ]
        for (label, input, want) in cases {
            let got = ScreenTextWatch.normalized(input)
            record(cat, label, pass: got == want, detail: got == want ? "\"\(input)\" -> \"\(got)\"" : "got \"\(got)\", want \"\(want)\"")
        }
        record(cat, "Normalized is idempotent",
               pass: cases.allSatisfy { ScreenTextWatch.normalized(ScreenTextWatch.normalized($0.1)) == ScreenTextWatch.normalized($0.1) },
               detail: "normalized(normalized(s)) == normalized(s)")
        record(cat, "Curly and straight match", pass: ScreenTextWatch.normalized("Don\u{2019}t") == ScreenTextWatch.normalized("Don't"),
               detail: "Both apostrophes fold to the same text")

        let matches: [(String, String, String, Int)] = [
            ("Single word once", "jump", "please jump now", 1),
            ("Repeated word", "jump", "jump jump jump", 3),
            ("Whole words only", "jump", "jumping and jumped", 0),
            ("Two words in a row", "jump up", "jump up jump down jump up", 2),
            ("Two words apart", "jump up", "jump and up", 0),
            ("Case and punctuation", "Jump!", "I said JUMP.", 1),
            ("Accent in the phrase", "café", "a cafe here", 1),
            ("Longer than transcript", "one two three", "one two", 0),
            ("Empty phrase", "", "anything", 0),
            ("Empty transcript", "jump", "", 0),
            ("Overlapping run", "a a", "a a a", 2),
        ]
        for (label, phrase, transcript, want) in matches {
            let got = VoicePhraseService.occurrences(of: phrase, in: transcript)
            record("Voice Phrase Match", label, pass: got == want,
                   detail: "\"\(phrase)\" in \"\(transcript)\": got \(got), want \(want)")
        }
    }

    /// `ScreenPixelWatch.distance` at its ends and `ScreenPixelService.averageColor`
    /// on images drawn here.
    private func runScreenPixelMathTests() {
        let cat = "Screen Color Math"
        let white = ScreenPixelWatch(name: "", display: nil, x: 0, y: 0, red: 255, green: 255, blue: 255)
        let black = ScreenPixelWatch(name: "", display: nil, x: 0, y: 0, red: 0, green: 0, blue: 0)
        let mid = ScreenPixelWatch(name: "", display: nil, x: 0, y: 0, red: 40, green: 120, blue: 200)
        record(cat, "Same color is 0", pass: mid.distance(toRed: 40, green: 120, blue: 200) == 0, detail: "distance to itself")
        let bw = black.distance(toRed: 255, green: 255, blue: 255)
        record(cat, "Black to white is 1", pass: abs(bw - 1) < 1e-12, detail: "distance=\(bw)")
        let wb = white.distance(toRed: 0, green: 0, blue: 0)
        record(cat, "Symmetric", pass: abs(bw - wb) < 1e-12
               && abs(mid.distance(toRed: 0, green: 0, blue: 0) - black.distance(toRed: 40, green: 120, blue: 200)) < 1e-12,
               detail: "d(a, b) == d(b, a)")
        let one = mid.distance(toRed: 41, green: 120, blue: 200)
        record(cat, "One step is 1/441.67", pass: abs(one - 1 / ScreenPixelWatch.maxDistance) < 1e-12 && one > 0 && one < 0.01,
               detail: "distance=\(one)")
        let over = ScreenPixelWatch(name: "", display: nil, x: 0, y: 0, red: 999, green: -5, blue: 255)
        record(cat, "Out-of-range watch color clamps in distance", pass: over.distance(toRed: 255, green: 0, blue: 255) == 0,
               detail: "999,-5 reads as 255,0")

        func image(width: Int, height: Int, fill: (CGContext) -> Void) -> CGImage? {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            fill(ctx)
            return ctx.makeImage()
        }
        func rgb(_ ctx: CGContext, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ rect: CGRect) {
            ctx.setFillColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1)
            ctx.fill(rect)
        }
        guard let solid = image(width: 6, height: 6, fill: { rgb($0, 200, 30, 90, CGRect(x: 0, y: 0, width: 6, height: 6)) }),
              let halves = image(width: 2, height: 1, fill: {
                  rgb($0, 255, 0, 0, CGRect(x: 0, y: 0, width: 1, height: 1))
                  rgb($0, 0, 0, 255, CGRect(x: 1, y: 0, width: 1, height: 1))
              }),
              let dot = image(width: 1, height: 1, fill: { rgb($0, 7, 8, 9, CGRect(x: 0, y: 0, width: 1, height: 1)) }),
              let big = image(width: 40, height: 24, fill: { rgb($0, 0, 128, 0, CGRect(x: 0, y: 0, width: 40, height: 24)) })
        else {
            record(cat, "Synthetic images", pass: false, detail: "CGContext could not be made")
            return
        }
        func check(_ label: String, _ img: CGImage, _ want: (Int, Int, Int), slack: Int = 0) {
            guard let got = ScreenPixelService.averageColor(img) else {
                record(cat, label, pass: false, detail: "averageColor returned nil"); return
            }
            let ok = abs(got.0 - want.0) <= slack && abs(got.1 - want.1) <= slack && abs(got.2 - want.2) <= slack
            record(cat, label, pass: ok, detail: "got \(got), want \(want)")
        }
        check("Solid 6x6 average", solid, (200, 30, 90))
        check("Half red half blue 2x1 is the midpoint", halves, (127, 0, 127), slack: 1)
        check("1x1 image", dot, (7, 8, 9))
        check("Larger image than the 16x16 scratch", big, (0, 128, 0))
    }

    /// The shared capture's cut path on two fixed images: each watch's
    /// square cut from a capture of the union reads what a capture of its
    /// own read, a change under one watch moves only that watch, the
    /// pixel hash that skips text recognition tells the two apart, and
    /// watches spread wide take separate captures.
    private func runScreenCaptureCutTests() {
        let cat = "Screen Capture Cut"
        // 64 by 40 pixels of gray, standing for a capture of this union of
        // display pixels, with a 6 by 6 square (3 points at 2x) under each
        // of two watches. Rects are top-left origin, as captures count them.
        let union = CGRect(x: 100, y: 200, width: 64, height: 40)
        let first = CGRect(x: 104, y: 206, width: 6, height: 6), second = CGRect(x: 140, y: 220, width: 6, height: 6)
        func capture(_ secondColor: (CGFloat, CGFloat, CGFloat)) -> CGImage? {
            let w = Int(union.width), h = Int(union.height)
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            func fill(_ c: (CGFloat, CGFloat, CGFloat), _ r: CGRect) {
                ctx.setFillColor(red: c.0 / 255, green: c.1 / 255, blue: c.2 / 255, alpha: 1)
                // The context's origin is the bottom left.
                ctx.fill(CGRect(x: r.minX - union.minX, y: union.maxY - r.maxY, width: r.width, height: r.height))
            }
            fill((50, 50, 50), union)
            fill((200, 30, 90), first)
            fill(secondColor, second)
            return ctx.makeImage()
        }
        guard let a = capture((10, 220, 40)), let b = capture((10, 40, 220)), let again = capture((10, 220, 40)) else {
            record(cat, "Synthetic captures", pass: false, detail: "CGContext could not be made")
            return
        }
        func colors(_ image: CGImage) -> [(Int, Int, Int)?] {
            [first, second].map { ScreenCapture.cut(image, at: $0, within: union).flatMap(ScreenPixelService.averageColor) }
        }
        func same(_ got: (Int, Int, Int)?, _ want: (Int, Int, Int)) -> Bool { got.map { $0 == want } ?? false }
        let ca = colors(a), cb = colors(b)
        record(cat, "Each watch reads its own square from the shared capture",
               pass: same(ca[0], (200, 30, 90)) && same(ca[1], (10, 220, 40)), detail: "\(ca)")
        record(cat, "A change under one watch moves only that watch",
               pass: same(cb[0], (200, 30, 90)) && same(cb[1], (10, 40, 220)), detail: "\(cb)")
        let edge = ScreenCapture.cut(a, at: CGRect(x: 160, y: 236, width: 6, height: 6), within: union)
        record(cat, "A square at the capture's edge is cut to it",
               pass: edge?.width == 4 && edge?.height == 4, detail: "\(edge?.width ?? 0)x\(edge?.height ?? 0)")
        record(cat, "A square outside the capture reads nothing",
               pass: ScreenCapture.cut(a, at: CGRect(x: 10, y: 10, width: 6, height: 6), within: union) == nil)
        let ha = ScreenTextService.pixelHash(a), hb = ScreenTextService.pixelHash(b), hAgain = ScreenTextService.pixelHash(again)
        record(cat, "Unchanged pixels hash the same, so recognition is skipped",
               pass: ha != nil && ha == hAgain, detail: "\(ha.map(String.init) ?? "nil") vs \(hAgain.map(String.init) ?? "nil")")
        record(cat, "Changed pixels hash differently, so the text is read again",
               pass: ha != nil && hb != nil && ha != hb)
        let near = ScreenCapture.clusters(of: [first, second])
        let far = ScreenCapture.clusters(of: [first, CGRect(x: 3000, y: 1800, width: 6, height: 6), second])
        record(cat, "Watches near each other share one capture",
               pass: near.count == 1 && near[0].members == [0, 1] && near[0].union == first.union(second))
        record(cat, "Watches spread wider than the cap take their own",
               pass: far.count == 2 && far[0].members == [0, 2] && far[1].members == [1]
                   && far.allSatisfy { $0.union.width <= ScreenCapture.clusterCap && $0.union.height <= ScreenCapture.clusterCap },
               detail: "\(far.map(\.members))")
    }

    /// The Siri and Shortcuts entity query, against the live preset store:
    /// ids that exist come back as entities, ids that do not are left out.
    // MARK: - 8g. Macro recording (1.9)

    /// The recorder's edges become steps: a lone press is a Tap with its
    /// hold, a press another interrupts is a Hold down and a Release, a
    /// modifier held over a tap rides on it as its shortcut, and the
    /// presses that bring InputConfig back are not steps.
    private func runMacroRecordingTests() {
        let cat = "Macro recording"
        func rec(_ edges: [(MacroRecording.Control, Bool, Double)]) -> MacroRecording {
            var r = MacroRecording()
            for (c, down, at) in edges { r.add(c, down: down, at: at) }
            return r
        }
        func tap(_ s: MacroStep) -> Bool { (s.eventKind ?? .tap) == .tap }

        // Two taps: V held 60 ms, then K 200 ms later held 40 ms.
        let two = rec([(.key(25), true, 1.0), (.key(25), false, 1.06), (.key(14), true, 1.26), (.key(14), false, 1.30)]).steps()
        record(cat, "Two taps keep their waits and holds",
               pass: two.count == 2 && tap(two[0]) && two[0].action.keyCode == 25 && two[0].delayMs == 0 && two[0].holdMs == 60
                   && tap(two[1]) && two[1].action.keyCode == 14 && two[1].delayMs == 200 && two[1].holdMs == 40 && two[1].modifiers == nil,
               detail: two.map { "\($0.action.keyCode ?? -1):\($0.delayMs)/\($0.holdMs)" }.joined(separator: " "))

        // Command held over V: one Tap V with Command, no step for Command.
        let shortcut = rec([(.key(227), true, 0), (.key(25), true, 0.1), (.key(25), false, 0.15), (.key(227), false, 0.2)]).steps()
        record(cat, "A modifier held over a tap is its shortcut",
               pass: shortcut.count == 1 && tap(shortcut[0]) && shortcut[0].action.keyCode == 25 && shortcut[0].modifiers == [227],
               detail: "\(shortcut.count) steps, modifiers \(shortcut.first?.modifiers ?? [])")

        // Shift pressed alone is a key of its own.
        let alone = rec([(.key(225), true, 0), (.key(225), false, 0.05)]).steps()
        record(cat, "A modifier pressed alone is a tap", pass: alone.count == 1 && alone[0].action.keyCode == 225 && tap(alone[0]))

        // A held down while S is tapped: Hold down A, Tap S, Release A.
        let chord = rec([(.key(4), true, 0), (.key(22), true, 0.1), (.key(22), false, 0.15), (.key(4), false, 0.3)]).steps()
        let chordOK = chord.count == 3 && chord[0].eventKind == .down && chord[0].action.keyCode == 4 && chord[0].holdMs == 0
            && tap(chord[1]) && chord[1].action.keyCode == 22 && chord[1].delayMs == 100 && chord[1].holdMs == 50
            && chord[2].eventKind == .up && chord[2].action.keyCode == 4 && chord[2].delayMs == 150
        record(cat, "An interrupted press is Hold down then Release", pass: chordOK,
               detail: chord.map { "\($0.eventKind ?? .tap) \($0.action.keyCode ?? -1) \($0.delayMs)/\($0.holdMs)" }.joined(separator: ", "))

        // A press with no release by the end is dropped; a release with no press is ignored.
        let open = rec([(.key(25), true, 0), (.key(25), false, 0.05), (.mouseButton(0), true, 0.5), (.key(99), false, 0.6)]).steps()
        record(cat, "An unfinished press and a stray release are not steps", pass: open.count == 1 && open[0].action.keyCode == 25)

        // The Command Tab back to InputConfig at the end is not a step.
        let back = rec([(.key(25), true, 0), (.key(25), false, 0.05), (.key(227), true, 0.5), (.key(43), true, 0.6),
                        (.key(43), false, 0.65), (.key(227), false, 0.7)]).steps()
        record(cat, "A trailing Command Tab is dropped", pass: back.count == 1 && back[0].action.keyCode == 25)
        // Record More appends after the kept edges, so dropReturnToApp is
        // what cuts the switch back to InputConfig: exact edges and the
        // press count the sheet shows.
        func edges(_ r: MacroRecording) -> [String] { r.edges.map { "\($0.control) \($0.down ? "d" : "u") \($0.at)" } }
        var cmdTab = rec([(.key(25), true, 0), (.key(25), false, 0.05), (.key(227), true, 0.5), (.key(43), true, 0.6),
                          (.key(43), false, 0.65), (.key(227), false, 0.7)])
        let dropped1 = cmdTab.dropReturnToApp()
        record(cat, "dropReturnToApp cuts a trailing Command Tab and counts its two presses",
               pass: dropped1 == 2 && edges(cmdTab) == ["key(25) d 0.0", "key(25) u 0.05"], detail: "\(dropped1) \(edges(cmdTab))")
        var clickBack = rec([(.key(25), true, 0), (.key(25), false, 0.05), (.mouseButton(0), true, 0.5)])
        let dropped2 = clickBack.dropReturnToApp()
        record(cat, "dropReturnToApp cuts a click still down at the end and counts one press",
               pass: dropped2 == 1 && edges(clickBack) == ["key(25) d 0.0", "key(25) u 0.05"], detail: "\(dropped2) \(edges(clickBack))")
        var plain = rec([(.key(25), true, 0), (.key(25), false, 0.05)])
        let dropped3 = plain.dropReturnToApp()
        record(cat, "dropReturnToApp leaves a finished take alone", pass: dropped3 == 0 && plain.edges.count == 2)
        var middle = rec([(.key(227), true, 0), (.key(43), true, 0.1), (.key(43), false, 0.15), (.key(227), false, 0.2),
                          (.key(26), true, 0.5), (.key(26), false, 0.55)])
        let dropped4 = middle.dropReturnToApp()
        record(cat, "dropReturnToApp keeps a Command Tab followed by more steps", pass: dropped4 == 0 && middle.edges.count == 6)

        // Command held over a click stays its own Hold down and Release: a
        // mouse step carries no modifiers at playback.
        let click = rec([(.key(227), true, 0), (.mouseButton(0), true, 0.1), (.mouseButton(0), false, 0.15), (.key(227), false, 0.2)]).steps()
        record(cat, "A modifier over a click is held around it",
               pass: click.count == 3 && click[0].eventKind == .down && click[0].action.keyCode == 227
                   && tap(click[1]) && click[1].action.type == .mouseButton && click[1].modifiers == nil
                   && click[2].eventKind == .up && click[2].action.keyCode == 227)
        // The shortcut is decided at the key's down: Command let go during the hold still counts.
        let early = rec([(.key(227), true, 0), (.key(25), true, 0.1), (.key(227), false, 0.12), (.key(25), false, 0.15)]).steps()
        record(cat, "A modifier released during the hold still folds", pass: early.count == 1 && early[0].modifiers == [227])
        // A rolling chord releases in the recorded order.
        let roll = rec([(.key(26), true, 0), (.key(7), true, 0.1), (.key(26), false, 0.2), (.key(7), false, 0.3)]).steps()
        record(cat, "A rolling chord keeps its release order",
               pass: roll.count == 4 && roll[0].eventKind == .down && roll[0].action.keyCode == 26
                   && roll[1].eventKind == .down && roll[1].action.keyCode == 7
                   && roll[2].eventKind == .up && roll[2].action.keyCode == 26
                   && roll[3].eventKind == .up && roll[3].action.keyCode == 7)

        // Mouse buttons are steps too, and even timing replaces the recorded waits.
        let mouse = rec([(.mouseButton(1), true, 0), (.mouseButton(1), false, 0.4)]).steps(keepTiming: false)
        record(cat, "A mouse button is a step, even timing when asked",
               pass: mouse.count == 1 && mouse[0].action.type == .mouseButton && mouse[0].action.mouseButtonIndex == 1
                   && mouse[0].delayMs == MacroRecording.evenMs && mouse[0].holdMs == MacroRecording.evenMs)

        // More presses than the cap: cut, not crashed.
        var long = MacroRecording()
        for i in 0..<(MacroRecording.maxSteps + 20) {
            long.add(.key(4), down: true, at: Double(i) * 0.1); long.add(.key(4), down: false, at: Double(i) * 0.1 + 0.02)
        }
        record(cat, "Steps are capped", pass: long.steps().count == MacroRecording.maxSteps)

        // Milliseconds: rounded, never negative, clamped at 30 s.
        record(cat, "ms rounds and clamps", pass: MacroRecording.ms(0.0604) == 60 && MacroRecording.ms(-1) == 0
               && MacroRecording.ms(.nan) == 0 && MacroRecording.ms(45) == 30_000)

        // A click with its position: a Move pointer step right before it.
        let placed = rec([(.move(x: 100, y: 200), true, 0.9999), (.mouseButton(0), true, 1.0), (.mouseButton(0), false, 1.05)]).steps()
        record(cat, "A click keeps its position as a move before it",
               pass: placed.count == 2 && placed[0].eventKind == .moveTo && placed[0].action.clickX == 100 && placed[0].action.clickY == 200
                   && placed[0].holdMs == 0 && tap(placed[1]) && placed[1].action.type == .mouseButton && placed[1].delayMs == 0)
        // Scrolls the same way close together are one step; a turn is another.
        let scrolled = rec([(.scroll(axis: .vertical, lines: 2), true, 0), (.scroll(axis: .vertical, lines: 3), true, 0.1),
                            (.scroll(axis: .vertical, lines: -1), true, 0.2)]).steps()
        record(cat, "Scrolls merge by direction",
               pass: scrolled.count == 2 && scrolled[0].action.type == .mouseWheelStep && scrolled[0].count == 5
                   && scrolled[0].action.mouseDirection == .positive && scrolled[1].count == 1 && scrolled[1].action.mouseDirection == .negative)
        // Path samples glide into each other.
        let path = rec([(.move(x: 0, y: 0), true, 0), (.move(x: 10, y: 10), true, 0.1), (.key(4), true, 0.3), (.key(4), false, 0.35)]).steps()
        record(cat, "Path moves glide until the next move",
               pass: path.count == 3 && path[0].holdMs == 100 && path[1].holdMs == 0 && path[2].delayMs == 200)
        // Playback timing: speed divides, jitter spreads, bounds hold.
        let base = MacroStep.playbackSeconds(1000, speed: 1, jitterPercent: 0, roll: 0)
        record(cat, "Playback timing scales and spreads",
               pass: base == 1 && MacroStep.playbackSeconds(1000, speed: 2, jitterPercent: 0, roll: 0) == 0.5
                   && MacroStep.playbackSeconds(1000, speed: 1, jitterPercent: 50, roll: 1) == 1.5
                   && MacroStep.playbackSeconds(1000, speed: 1, jitterPercent: 50, roll: -1) == 0.5
                   && MacroStep.playbackSeconds(1000, speed: 100, jitterPercent: 0, roll: 0) == 0.25
                   && MacroStep.playbackSeconds(0, speed: 1, jitterPercent: 50, roll: 1) == 0
                   && MacroStep.playbackSeconds(60_000, speed: 0.25, jitterPercent: 0, roll: 0) == 30)
        // The double Escape that stops a recording leaves no step.
        var esc = rec([(.key(4), true, 0), (.key(4), false, 0.05), (.key(41), true, 1), (.key(41), false, 1.05), (.key(41), true, 1.2)])
        esc.dropTrailingEscapes(since: 1)
        record(cat, "Trailing Escapes are dropped", pass: esc.steps().count == 1 && esc.steps()[0].action.keyCode == 4)

        // A scroll while a key is down splits the press: the scroll plays with the key held.
        let scrollHeld = rec([(.key(4), true, 0), (.scroll(axis: .vertical, lines: 3), true, 0.1), (.key(4), false, 0.3)]).steps()
        record(cat, "A scroll inside a press is Hold down, Scroll, Release",
               pass: scrollHeld.count == 3 && scrollHeld[0].eventKind == .down && scrollHeld[0].action.keyCode == 4
                   && tap(scrollHeld[1]) && scrollHeld[1].action.type == .mouseWheelStep && scrollHeld[1].count == 3 && scrollHeld[1].delayMs == 100
                   && scrollHeld[2].eventKind == .up && scrollHeld[2].action.keyCode == 4 && scrollHeld[2].delayMs == 200,
               detail: scrollHeld.map { "\($0.eventKind ?? .tap) \($0.action.type) \($0.delayMs)" }.joined(separator: ", "))
        // Let go somewhere else: the move inside the press makes it a drag.
        // A tap follows it, since a move nothing follows is dropped.
        let drag = rec([(.mouseButton(0), true, 1.0), (.move(x: 200, y: 200), true, 1.4999), (.mouseButton(0), false, 1.5),
                        (.key(4), true, 2.0), (.key(4), false, 2.05)]).steps()
        record(cat, "A move inside a press is a drag",
               pass: drag.count == 4 && drag[0].eventKind == .down && drag[0].action.type == .mouseButton
                   && drag[1].eventKind == .moveTo && drag[1].action.clickX == 200 && drag[1].action.clickY == 200 && drag[1].holdMs == 0
                   && drag[2].eventKind == .up && drag[2].action.type == .mouseButton
                   && tap(drag[3]) && drag[3].action.keyCode == 4,
               detail: drag.map { "\($0.eventKind ?? .tap) \($0.action.type) \($0.delayMs)/\($0.holdMs)" }.joined(separator: ", "))
        // The glide is time spent: the sample after it does not wait again.
        record(cat, "A glide is not waited for twice", pass: path.count == 3 && path[1].delayMs == 0,
               detail: path.map { "\($0.delayMs)/\($0.holdMs)" }.joined(separator: " "))
        // Command over a click and a key: not folded, so the click keeps
        // it; the key under it gets no modifiers of its own.
        let around = rec([(.key(227), true, 0), (.mouseButton(0), true, 0.1), (.mouseButton(0), false, 0.15),
                          (.key(6), true, 0.3), (.key(6), false, 0.35), (.key(227), false, 0.5)]).steps()
        record(cat, "A modifier over a click and a key is never folded",
               pass: around.count == 4 && around[0].eventKind == .down && around[0].action.keyCode == 227
                   && tap(around[1]) && around[1].action.type == .mouseButton && around[1].modifiers == nil
                   && tap(around[2]) && around[2].action.keyCode == 6 && around[2].modifiers == nil
                   && around[3].eventKind == .up && around[3].action.keyCode == 227,
               detail: around.map { "\($0.eventKind ?? .tap) \($0.action.keyCode ?? -1) mods \($0.modifiers ?? [])" }.joined(separator: ", "))
        // Moves at the end are the pointer going back to the sheet.
        let wander = rec([(.key(4), true, 0), (.key(4), false, 0.05), (.move(x: 50, y: 60), true, 0.5), (.move(x: 70, y: 80), true, 0.6)]).steps()
        record(cat, "Trailing moves are dropped", pass: wander.count == 1 && tap(wander[0]) && wander[0].action.keyCode == 4)
        // The click on the Dock icon that brought InputConfig back: gone
        // with its move when it is fresh, kept when it is older.
        let dockEdges: [(MacroRecording.Control, Bool, Double)] = [(.key(4), true, 0), (.key(4), false, 0.05), (.move(x: 10, y: 10), true, 0.9999),
                                                                    (.mouseButton(0), true, 1.0), (.mouseButton(0), false, 1.05)]
        var fresh = rec(dockEdges)
        let freshWent = fresh.dropTrailingClick(before: 1.2, within: 0.3)
        var stale = rec(dockEdges)
        let staleWent = stale.dropTrailingClick(before: 1.5, within: 0.3)
        var noClick = rec([(.key(4), true, 0), (.key(4), false, 0.05)])
        record(cat, "A trailing click within 0.3 s is dropped, an older one kept",
               pass: freshWent && fresh.edges.count == 2 && fresh.steps().count == 1 && fresh.steps()[0].action.keyCode == 4
                   && !staleWent && stale.edges.count == 5 && stale.steps().count == 3
                   && !noClick.dropTrailingClick(before: 1, within: 0.3) && noClick.edges.count == 2,
               detail: "fresh \(fresh.edges.count) edges, stale \(stale.edges.count) edges")
        // A capped wait: the 5 s pause is cut to 1 s, the 2 s hold stays whole.
        let pauseEdges: [(MacroRecording.Control, Bool, Double)] = [(.key(4), true, 0), (.key(4), false, 0.05), (.key(5), true, 5.05), (.key(5), false, 7.05)]
        let capped = rec(pauseEdges).steps(capWaitMs: 1000)
        let uncapped = rec(pauseEdges).steps()
        record(cat, "A capped wait cuts the pause, not the hold",
               pass: capped.count == 2 && capped[1].delayMs == 1000 && capped[1].holdMs == 2000
                   && uncapped.count == 2 && uncapped[1].delayMs == 5000 && uncapped[1].holdMs == 2000,
               detail: "capped \(capped.last?.delayMs ?? -1)/\(capped.last?.holdMs ?? -1), uncapped \(uncapped.last?.delayMs ?? -1)/\(uncapped.last?.holdMs ?? -1)")
        // Over the cap, mid-glide path samples go before any press does.
        var walk = MacroRecording()
        for i in 0..<250 { walk.add(.move(x: Double(i), y: 0), down: true, at: Double(i) * 0.1) }
        walk.add(.key(4), down: true, at: 25.0); walk.add(.key(4), down: false, at: 25.05)
        let thinned = walk.steps()
        let moves = thinned.filter { $0.eventKind == .moveTo }
        record(cat, "Path samples are thinned before presses are cut",
               pass: thinned.count == MacroRecording.maxSteps && moves.count == MacroRecording.maxSteps - 1
                   && tap(thinned[MacroRecording.maxSteps - 1]) && thinned[MacroRecording.maxSteps - 1].action.keyCode == 4
                   && thinned[0].action.clickX == 0 && moves.last?.action.clickX == 249,
               detail: "\(thinned.count) steps, \(moves.count) moves, last \(thinned.last?.action.keyCode ?? -1)")
        // The recorder publishes only when the steps change (D6): two runs
        // of steps() differ by ids alone, a measured hold is a change, and
        // a pointer sample at the end of the take is none.
        var live = rec([(.key(4), true, 0), (.key(4), false, 0.05)])
        let first = live.steps(), again = live.steps()
        let longer = rec([(.key(4), true, 0), (.key(4), false, 0.08)]).steps()
        live.add(.move(x: 10, y: 10), down: true, at: 0.2)
        let afterMove = live.steps()
        record(cat, "Recorder steps compare by content, not id",
               pass: first != again && MacroRecorderService.sameSteps(first, again)
                   && !MacroRecorderService.sameSteps(first, longer) && MacroRecorderService.sameSteps(first, afterMove),
               detail: "\(first.count) \(longer.count) \(afterMove.count)")

        // continueOnTimeout: absent from older JSON, nil on decode; true survives.
        do {
            let plain = MacroStep(action: OutputAction(type: .key, keyCode: 4), eventKind: .waitFor, timeoutMs: 2000)
            let plainData = try JSONEncoder().encode(plain)
            let plainText = String(decoding: plainData, as: UTF8.self)
            let plainBack = try JSONDecoder().decode(MacroStep.self, from: plainData)
            let goOn = MacroStep(action: OutputAction(type: .key, keyCode: 4), eventKind: .waitFor, timeoutMs: 2000, continueOnTimeout: true)
            let goOnBack = try JSONDecoder().decode(MacroStep.self, from: try JSONEncoder().encode(goOn))
            record(cat, "continueOnTimeout is nil when the JSON lacks it and keeps true",
                   pass: !plainText.contains("continueOnTimeout") && plainBack.continueOnTimeout == nil && plainBack.eventKind == .waitFor
                       && plainBack.timeoutMs == 2000 && goOnBack.continueOnTimeout == true,
                   detail: plainText)
        } catch {
            record(cat, "continueOnTimeout is nil when the JSON lacks it and keeps true", pass: false, detail: "\(error)")
        }
        // macroLoop and a key sequence past 255 through a whole preset file.
        do {
            let looped = BindingModel(id: UUID(), input: InputEvent(type: .button, index: 0),
                                      outputs: [OutputAction(type: .key, keyCode: 4)],
                                      macroSteps: [MacroStep(action: OutputAction(type: .key, keyCode: 4))], macroLoop: true)
            let once = BindingModel(id: UUID(), input: InputEvent(type: .button, index: 1), outputs: [OutputAction(type: .key, keyCode: 5)])
            let typed = BindingModel(id: UUID(), input: .keySequence([304, 4]), outputs: [OutputAction(type: .key, keyCode: 6)])
            let preset = Preset(name: "Macro round-trip", tag: "Tests", joysticks: [JoystickMapping(tag: "Rows", bindings: [looped, once, typed])])
            let back = try JSONDecoder().decode(Preset.self, from: try JSONEncoder().encode(preset))
            let rows = back.joysticks.first?.bindings ?? []
            record(cat, "macroLoop round-trips",
                   pass: rows.count == 3 && rows[0].macroLoop == true && rows[1].macroLoop == nil
                       && rows[0].macroSteps?.count == 1,
                   detail: "\(rows.count) rows, loop \(String(describing: rows.first?.macroLoop))")
            record(cat, "A key sequence past 255 survives a preset file",
                   pass: rows.count == 3 && rows[2].input.type == .keySequence && rows[2].input.sequenceSteps == [304, 4]
                       && back.clampedValues().joysticks[0].bindings[2].input.sequenceSteps == [304, 4],
                   detail: rows.last?.input.serialized ?? "")
        } catch {
            record(cat, "macroLoop round-trips", pass: false, detail: "\(error)")
        }
    }

    // MARK: - 8h. Button sequences (1.9)

    /// Which keys a preset holds back from other apps, and the light
    /// report never claiming the light when told not to.
    private func runBlockingAndLightTests() {
        let cat = "Blocking"
        var w = BindingModel(input: InputEvent(type: .extKey, index: 26), outputs: [OutputAction(type: .key, keyCode: 82)])
        w.blockOriginal = true
        var shift = BindingModel(input: InputEvent(type: .extKey, index: 225), outputs: [OutputAction(type: .key, keyCode: 4)])
        shift.blockOriginal = true
        var oneKeyboard = BindingModel(input: InputEvent(type: .extKey, index: 4), outputs: [OutputAction(type: .key, keyCode: 5)])
        oneKeyboard.blockOriginal = true
        oneKeyboard.input.extDeviceID = "usb.1234.5678"
        var media = BindingModel(input: InputEvent(type: .extKey, index: 308), outputs: [OutputAction(type: .key, keyCode: 5)])
        media.blockOriginal = true
        var plain = BindingModel(input: InputEvent(type: .extKey, index: 7), outputs: [OutputAction(type: .key, keyCode: 5)])
        plain.blockOriginal = nil
        var side = BindingModel(input: InputEvent(type: .extMouse, index: 3), outputs: [OutputAction(type: .key, keyCode: 5)])
        side.blockOriginal = true
        let preset = Preset(name: "Blocking", tag: "Tests",
                            joysticks: [JoystickMapping(tag: "Keys", bindings: [w, shift, oneKeyboard, media, plain, side])])
        let keys = MappingEngine.blockedKeys(in: preset)
        record(cat, "Only an ordinary key on any keyboard with the toggle on blocks",
               pass: keys == [26], detail: "\(keys.sorted())")
        record(cat, "A mouse row never lands in the blocked keys, nor a key row in the blocked buttons",
               pass: !keys.contains(3) && MappingEngine.blockedMouseButtons(in: preset) == [3])

        // A key sequence blocks its own keys (not a modifier in it); a chord
        // row blocks only with its held control, a plain row always; a
        // middle button double click row blocks the button.
        var seq = BindingModel(input: InputEvent(type: .keySequence, index: 0), outputs: [OutputAction(type: .key, keyCode: 5)])
        seq.input.sequenceSteps = [13, 225, 14]
        seq.blockOriginal = true
        var chordJ = BindingModel(input: InputEvent(type: .extKey, index: 13), outputs: [OutputAction(type: .key, keyCode: 5)])
        chordJ.setModifiers([InputEvent(type: .extKey, index: 227)])
        chordJ.blockOriginal = true
        var dbl = BindingModel(input: InputEvent(type: .extMouse, index: 2), outputs: [OutputAction(type: .key, keyCode: 5)])
        dbl.input.extMouseKind = .doubleClick
        dbl.blockOriginal = true
        let more = Preset(name: "Blocking 2", tag: "Tests",
                          joysticks: [JoystickMapping(tag: "Keys", bindings: [seq, chordJ, dbl])])
        let chords = MappingEngine.keyBlockChords(in: more)
        record(cat, "A key sequence row blocks every key in its sequence but the modifier",
               pass: Set(chords.keys) == [13, 14], detail: "\(chords.keys.sorted())")
        let j = chords[13] ?? []
        record(cat, "A key blocked by a plain row and by a chord row blocks always, and only with the chord for that row",
               pass: j.count == 2 && j.contains(where: { $0.isEmpty })
                   && j.contains(where: { $0.map(\.index) == [227] }), detail: "\(j.map { $0.map(\.index) })")
        record(cat, "A middle button double click row blocks the middle button",
               pass: MappingEngine.blockedMouseButtons(in: more) == [2])
        // Blocking the held controls: K always, Left Command never.
        var wk = BindingModel(input: InputEvent(type: .extKey, index: 26), outputs: [OutputAction(type: .key, keyCode: 5)])
        wk.setModifiers([InputEvent(type: .extKey, index: 14), InputEvent(type: .extKey, index: 227)])
        wk.blockHeldControls = true
        let held = MappingEngine.keyBlockChords(in: Preset(name: "Blocking 3", tag: "Tests",
                                                           joysticks: [JoystickMapping(tag: "Keys", bindings: [wk])]))
        record(cat, "Blocking the held controls blocks a held key always and never a modifier, and leaves the row's own key alone",
               pass: Set(held.keys) == [14] && held[14] == [[]], detail: "\(held.keys.sorted())")

        let ds = InProcessLightWriter.dualSenseLightReport(bluetooth: false, sequence: 0, touchLight: false, rgb: (255, 0, 0),
                                                           brightness: 2, setup: false, touchMotors: true, weak: 100, strong: 200,
                                                           hapticsSelect: true, motorMask: 0, improvedRumble: false)
        record(cat, "A rumble write with the light left alone claims no light field",
               pass: ds[2] == 0x00 && ds[1] != 0 && ds[3] == 100 && ds[4] == 200, detail: "flag1 \(ds[2])")
        let ds4 = InProcessLightWriter.dualShock4LightReport(bluetooth: false, touchLight: false, rgb: (255, 0, 0),
                                                             touchMotors: true, weak: 100, strong: 200)
        record(cat, "A DualShock 4 rumble write with the light left alone clears the light flag",
               pass: ds4[1] & 0x02 == 0 && ds4[1] & 0x01 != 0, detail: "flags \(ds4[1])")
    }

    private func runButtonSequenceTests() {
        let cat = "Button sequence"
        let e = InputEvent.buttonSequence([253, 253, 0])
        record(cat, "bsq serializes and round-trips",
               pass: e.serialized == "bsq 253.253.0" && InputEvent.parse("bsq 253.253.0")?.sequenceSteps == [253, 253, 0]
                   && InputEvent.parse("bsq -")?.sequenceSteps == [] && InputEvent.parse("bsq 1.x") == nil
                   && InputEvent.parse("bsq 1.999") == nil && InputEvent.parse("bsq 1.2.3.4.5.6.7.8.9")?.sequenceSteps?.count == InputEvent.maxSequenceSteps,
               detail: e.serialized)

        let k = InputEvent.keySequence([13, 14])
        record(cat, "ksq serializes and round-trips",
               pass: k.serialized == "ksq 13.14" && InputEvent.parse("ksq 13.14")?.type == .keySequence
                   && InputEvent.parse("ksq 13.14")?.sequenceSteps == [13, 14] && InputEvent.parse("ksq 300")?.sequenceSteps == [300]
                   && InputEvent.parse("bsq 300") == nil)

        var r = ButtonSequenceRecognizer()
        r.windowMs = 500
        let steps = [12, 12, 0]
        func press(_ b: Int, at t: Double) -> Bool {
            // A press is a poll with the button down after a poll with it up.
            _ = r.feed(down: [], now: t - 0.01, steps: steps)
            return r.feed(down: [b], now: t, steps: steps)
        }
        let inOrder = !press(12, at: 1.0) && !press(12, at: 1.2) && press(0, at: 1.4)
        record(cat, "Presses in order fire on the last one", pass: inOrder)
        r.reset()
        let wrong = !press(12, at: 2.0) && !press(1, at: 2.2) && !press(12, at: 2.4) && !press(12, at: 2.6) && press(0, at: 2.8)
        record(cat, "A wrong press starts over", pass: wrong)
        r.reset()
        // One extra leading press of a repeated opening: the last three
        // presses are still the sequence, so it fires.
        let repeated = !press(12, at: 6.0) && !press(12, at: 6.2) && !press(12, at: 6.4) && press(0, at: 6.6)
        record(cat, "An extra leading press keeps the matched start", pass: repeated)
        r.reset()
        let late = !press(12, at: 3.0) && !press(12, at: 3.2) && !press(0, at: 4.0)
        record(cat, "A press past the window starts over", pass: late)
        r.reset()
        // Down held over two polls is one press; a second button pressed
        // while the first stays down is the next press.
        let held = !r.feed(down: [12], now: 5.0, steps: steps) && !r.feed(down: [12], now: 5.1, steps: steps)
            && r.progress == 1
            && !r.feed(down: [], now: 5.2, steps: steps) && !r.feed(down: [12], now: 5.3, steps: steps)
            && r.progress == 2
            && r.feed(down: [12, 0], now: 5.4, steps: steps)
        record(cat, "A held button is one press", pass: held)
        var empty = ButtonSequenceRecognizer()
        record(cat, "An empty sequence never fires", pass: !empty.feed(down: [0], now: 1, steps: []))
        // Two buttons landing in one poll are walked in the sequence's
        // order, whichever way their indexes sort.
        var pair = ButtonSequenceRecognizer()
        let highFirst = !pair.feed(down: [], now: 7.0, steps: [3, 0]) && pair.feed(down: [0, 3], now: 7.1, steps: [3, 0])
        pair.reset()
        let lowFirst = !pair.feed(down: [], now: 8.0, steps: [0, 0, 12]) && !pair.feed(down: [0], now: 8.1, steps: [0, 0, 12])
            && !pair.feed(down: [], now: 8.2, steps: [0, 0, 12]) && pair.feed(down: [0, 12], now: 8.3, steps: [0, 0, 12])
        record(cat, "Two presses in one poll are read in the sequence's order", pass: highFirst && lowFirst)
        // The d-pad reads as the four hat codes.
        var state = ControllerState()
        state.buttons[0] = 1; state.hats[0] = (x: 0, y: -1)
        record(cat, "Down on the d-pad is code 253", pass: ButtonSequenceRecognizer.downSet(state) == [0, 253])
        state.hats[0] = (x: 1, y: 0.4)
        record(cat, "Right past the threshold only", pass: ButtonSequenceRecognizer.downSet(state) == [0, 255])
        // A diagonal is both directions at once, and a sequence recorded
        // from the same down set fires from the same diagonal.
        var diagonal = ControllerState()
        diagonal.hats[0] = (x: -1, y: -1)
        let diagonalDown = ButtonSequenceRecognizer.downSet(diagonal)
        var dr = ButtonSequenceRecognizer()
        let diagonalFires = diagonalDown == [253, 254]
            && !dr.feed(down: [], now: 9.0, steps: [253, 254, 0]) && !dr.feed(down: diagonalDown, now: 9.1, steps: [253, 254, 0])
            && !dr.feed(down: [], now: 9.2, steps: [253, 254, 0]) && dr.feed(down: [0], now: 9.3, steps: [253, 254, 0])
        record(cat, "A d-pad diagonal is two presses in one poll", pass: diagonalFires, detail: "\(diagonalDown.sorted())")
        // The clamp's ceiling follows the type: key codes run past 255
        // (media keys, Globe), button and hat codes stop there.
        let media = InputEvent.keySequence([304, 4, 0x1_0000]).clampedValues()
        let pad = InputEvent.buttonSequence([304, 4]).clampedValues()
        record(cat, "A key sequence keeps codes past 255, a button sequence does not",
               pass: media.sequenceSteps == [304, 4, 0xFFFF] && pad.sequenceSteps == [255, 4],
               detail: "\(media.serialized) / \(pad.serialized)")
    }

    private func runPresetQueryTests() async {
        let cat = "App Intents"
        guard let store = AppState.current?.presetStore else {
            skip(cat, "PresetQuery.entities(for:)", detail: "Needs the live AppState; the store reads Application Support and cannot be built in isolation")
            return
        }
        let query = PresetQuery()
        let missing = [UUID(), UUID()]
        do {
            let none = try await query.entities(for: missing)
            record(cat, "Unknown ids give no entities", pass: none.isEmpty, detail: "\(none.count) entities for 2 random ids")
            guard let first = store.presets.first else {
                skip(cat, "Known ids give entities", detail: "The preset store is empty")
                return
            }
            let some = try await query.entities(for: [missing[0], first.id, missing[1]])
            record(cat, "Known ids give entities", pass: some.count == 1 && some.first?.id == first.id && some.first?.name == first.shownName,
                   detail: "1 of 3 ids exists: got \(some.count), name \"\(some.first?.name ?? "")\"")
            let all = try await query.entities(for: store.presets.map(\.id))
            record(cat, "Every stored preset resolves", pass: all.count == store.presets.count && Set(all.map(\.id)) == Set(store.presets.map(\.id)),
                   detail: "\(all.count) of \(store.presets.count)")
            let empty = try await query.entities(for: [])
            record(cat, "No ids give no entities", pass: empty.isEmpty, detail: "\(empty.count) entities for no ids")
        } catch {
            record(cat, "PresetQuery.entities(for:)", pass: false, detail: "\(error)")
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

    // MARK: - 9b. Launch read, caches and the undo budget (1.10)

    /// The launch read decodes every preset file at once; each must come
    /// out as a decode on its own made it, with the same row counts and
    /// the shared counters untouched. The caches added for the sidebar,
    /// Help search, Help text and the log must answer what the code
    /// without them did.
    private func runLoadAndCacheTests() {
        let cat = "Load and Caches"

        // Files: plain presets of 1 to 7 rows, one with a row from a newer
        // build (kept raw), one with a number no row can hold, one that is
        // not a preset, one that is not JSON.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ic-decode-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var urls: [URL] = []
        func write(_ data: Data?, _ name: String) {
            let url = dir.appendingPathComponent(name)
            try? data?.write(to: url)
            urls.append(url)
        }
        for i in 0..<24 {
            let rows = (0...(i % 7)).map { n in
                BindingModel(input: InputEvent.button(n), outputs: [OutputAction(type: .typeText, text: "row \(n) of \(i)")])
            }
            write(try? JSONEncoder().encode(Preset(name: "Decode \(i)", tag: "Tests", joysticks: [JoystickMapping(tag: "Pad", bindings: rows)])), "\(i).json")
        }
        let base = Preset(name: "Newer rows", tag: "Tests",
                          joysticks: [JoystickMapping(tag: "Pad", bindings: [BindingModel(input: InputEvent.button(0), outputs: [])])])
        if let data = try? JSONEncoder().encode(base),
           var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           var groups = dict["joysticks"] as? [[String: Any]], var rows = groups.first?["bindings"] as? [Any] {
            rows.append(["id": UUID().uuidString, "input": ["type": "aFutureInputKind"], "outputs": []])
            groups[0]["bindings"] = rows
            dict["joysticks"] = groups
            write(try? JSONSerialization.data(withJSONObject: dict), "kept.json")
            if var text = (try? JSONSerialization.data(withJSONObject: dict)).flatMap({ String(data: $0, encoding: .utf8) }),
               let at = text.range(of: "\"aFutureInputKind\"") {
                text.replaceSubrange(at, with: "1e999")
                write(text.data(using: .utf8), "huge.json")
            }
        }
        write(Data("{\"name\": 3}".utf8), "notapreset.json")
        write(Data("not json".utf8), "garbage.json")

        let savedDropped = JoystickMapping.droppedRowsDuringDecode
        let savedKept = JoystickMapping.keptRowsDuringDecode
        let together = PresetStore.decodeFiles(urls) { try $0.decode(Preset.self, from: $1) }
        let staticsUntouched = JoystickMapping.droppedRowsDuringDecode == savedDropped
            && JoystickMapping.keptRowsDuringDecode == savedKept
        var mismatches: [String] = []
        for (url, read) in zip(urls, together) {
            JoystickMapping.droppedRowsDuringDecode = 0
            JoystickMapping.keptRowsDuringDecode = 0
            let alone = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Preset.self, from: $0) }
            let same = (try? read.result.get()) == alone
                && read.counts.dropped == JoystickMapping.droppedRowsDuringDecode
                && read.counts.kept == JoystickMapping.keptRowsDuringDecode
            if !same { mismatches.append(url.lastPathComponent) }
        }
        JoystickMapping.droppedRowsDuringDecode = savedDropped
        JoystickMapping.keptRowsDuringDecode = savedKept
        let keptRead = zip(urls, together).first { $0.0.lastPathComponent == "kept.json" }?.1
        record(cat, "Files decoded at once come out as each decoded alone, row counts too",
               pass: together.count == urls.count && mismatches.isEmpty,
               detail: mismatches.isEmpty ? "\(urls.count) files" : mismatches.joined(separator: ", "))
        record(cat, "A newer build's row is counted on its own file's counter", pass: keptRead?.counts.kept == 1,
               detail: "kept \(keptRead?.counts.kept ?? -1)")
        record(cat, "Decoding at once leaves the shared row counters alone", pass: staticsUntouched)

        // The sidebar's cached folder lists, against the lists worked out again.
        if let store = AppState.current?.presetStore {
            let folders: [UUID?] = [nil] + store.groups.map(\.id)
            let wrong = folders.filter { store.presets(in: $0) != store.presetsUncached(in: $0) }
            record(cat, "Every cached folder list is the list worked out again", pass: wrong.isEmpty,
                   detail: "\(folders.count) folders, \(wrong.count) differ")
            let favorites = store.presets.filter { store.favoriteIDs.contains($0.id) }
                .sorted { $0.shownName.localizedStandardCompare($1.shownName) == .orderedAscending }
            record(cat, "The cached favorites are the favorites worked out again", pass: store.favoritePresets == favorites)
            // Notes are not part of a preset's place; its name is.
            if var sample = store.presets.first {
                let before = PresetStore.sidebarKeys([sample], sort: store.sidebarSort)
                sample.notes += " more"
                let notes = PresetStore.sidebarKeys([sample], sort: store.sidebarSort)
                sample.name += " renamed"
                let named = PresetStore.sidebarKeys([sample], sort: store.sidebarSort)
                record(cat, "A note keeps the sidebar order, a name drops it", pass: before == notes && before != named)
            }
            // The versions list shows each file's binding count.
            if let preset = store.presets.first(where: { !store.versions(for: $0).isEmpty }) {
                let wrongCounts = store.versions(for: preset).filter { v in
                    let p = (try? Data(contentsOf: v.fileURL)).flatMap { try? JSONDecoder().decode(Preset.self, from: $0) }
                    return p?.joysticks.flatMap(\.bindings).count != v.bindingCount
                }
                record(cat, "Each version lists its file's binding count", pass: wrongCounts.isEmpty,
                       detail: "\(wrongCounts.count) differ")
            } else {
                skip(cat, "Each version lists its file's binding count", detail: "No preset here has a previous version")
            }
        } else {
            skip(cat, "Sidebar caches", detail: "Needs the live AppState")
        }

        // Help search on NSString, against the String search it replaced.
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let english = HelpGuideLibrary.all.map(\.searchText)
        let localized = HelpGuideLibrary.localizedAll.map(\.searchText)
        var searchMisses: [String] = []
        // No "ß": Swift's own String search with .caseInsensitive matches it on
        // nearly any text with an "s" so it is no reference there.
        for q in ["po", "poi", "point", "resume", "résumé", "dualsense", "zzqx", "a b"] {
            let reference = zip(HelpGuideLibrary.localizedAll, zip(localized, english))
                .filter { $0.1.0.range(of: q, options: options) != nil
                    || (HelpLocalizer.isTranslated && $0.1.1.range(of: q, options: options) != nil) }.map(\.0.id)
            if HelpGuideView.matching(q).map(\.id) != reference { searchMisses.append(q) }
        }
        record(cat, "Help search finds what the String search found", pass: searchMisses.isEmpty,
               detail: searchMisses.joined(separator: ", "))
        let sharpS = HelpGuideView.matching("ß").count
        record(cat, "Help search for ß does not match every guide", pass: sharpS < HelpGuideLibrary.localizedAll.count,
               detail: "\(sharpS) of \(HelpGuideLibrary.localizedAll.count)")

        // Help text parsed once gives what a fresh parse gives.
        let samples = ["Plain words.", "**Bold** and a [link](https://inputconfig.com/help/first-preset).",
                       "Not *closed", ""] + HelpGuideLibrary.localizedAll.prefix(3).map(\.intro)
        let parsedDiffers = samples.filter { s in
            let fresh = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(s)
            return helpMarkdown(s) != fresh || helpMarkdown(s) != fresh
        }
        record(cat, "Help text from the cache is the text parsed again", pass: parsedDiffers.isEmpty,
               detail: "\(parsedDiffers.count) of \(samples.count) differ")

        // The log filtered a flush at a time, through trims and a clear,
        // against the whole log filtered again.
        func entry(_ id: Int) -> ActivityLog.Entry {
            ActivityLog.Entry(id: id, time: Date(), level: [ActivityLog.Level.info, .event, .warning, .error][id % 4],
                              source: id % 3 == 0 ? "Engine" : "Presets", text: id % 5 == 0 ? "PRESS A" : "line \(id)", slot: nil)
        }
        let keep: (ActivityLog.Entry) -> Bool = { $0.level >= .event && $0.text.localizedCaseInsensitiveContains("press") }
        var entries: [ActivityLog.Entry] = []
        var shown: [ActivityLog.Entry] = []
        var through = 0
        var nextID = 1
        var logMismatch = -1
        for round in 0..<60 {
            if round == 40 { entries.removeAll() }
            for _ in 0..<(round % 9 + 1) { entries.append(entry(nextID)); nextID += 1 }
            if entries.count > 50 { entries.removeFirst(entries.count - 50) }
            shown = DebugLogView.refiltered(shown, through: through, entries: entries, keep: keep)
            through = entries.last?.id ?? through
            if shown.map(\.id) != entries.filter(keep).map(\.id), logMismatch < 0 { logMismatch = round }
        }
        record(cat, "The log filtered a flush at a time matches it filtered whole", pass: logMismatch < 0,
               detail: logMismatch < 0 ? "" : "first differs at round \(logMismatch)")

        // The undo byte budget: oldest steps first, the least recently used
        // preset's from its oldest, and the newest keeps its newest step.
        let a = UUID(), b = UUID(), c = UUID()
        let steps: [UUID: [Int]] = [a: [10, 10, 10], b: [20, 20], c: [5]]
        let roomy = EditorHistory.fitting([a, b, c], steps, budget: 1_000)
        let exact = EditorHistory.fitting([a, b, c], steps, budget: 75)
        let part = EditorHistory.fitting([a, b, c], steps, budget: 60)
        let tight = EditorHistory.fitting([a, b, c], steps, budget: 25)
        let tiny = EditorHistory.fitting([a, b, c], steps, budget: 1)
        record(cat, "Undo kept after Save fits its byte budget, oldest presets first",
               pass: tight == [a: 2, b: 0, c: 0] && tiny == [a: 1, b: 0, c: 0],
               detail: "\(tight[a] ?? -1) \(tight[b] ?? -1) \(tight[c] ?? -1)")
        record(cat, "Undo kept after Save under its byte budget keeps every step",
               pass: roomy == [a: 3, b: 2, c: 1] && exact == roomy)
        record(cat, "Undo kept after Save over its budget drops one step at a time, oldest first",
               pass: part == [a: 3, b: 1, c: 0], detail: "\(part[a] ?? -1) \(part[b] ?? -1) \(part[c] ?? -1)")
        // The same on real snapshots: what stays is each history's newest
        // steps in order, so Undo walks back through them one by one.
        func step(_ name: String, rows: Int) -> Preset {
            Preset(name: name, tag: "Tests", joysticks: [JoystickMapping(tag: "A", bindings: (0..<rows).map {
                BindingModel(input: InputEvent.button($0 % 16), outputs: []) })])
        }
        let oldStack = (0..<4).map { step("old \($0)", rows: 10) }
        let midStack = (0..<3).map { step("mid \($0)", rows: 20) }
        let newStack = (0..<5).map { step("new \($0)", rows: 40) }
        let whole: [UUID: (undo: [Preset], savedAs: Preset)] = [
            c: (oldStack, step("old saved", rows: 10)), b: (midStack, step("mid saved", rows: 20)),
            a: (newStack, step("new saved", rows: 40))]
        let allBytes = whole.values.reduce(0) { $0 + $1.undo.map(EditorHistory.snapshotBytes).reduce(0, +) }
        var untouched = whole
        EditorHistory.trim(&untouched, order: [a, b, c], budget: allBytes)
        record(cat, "Kept undo under its byte budget stays exactly as it was",
               pass: untouched.count == 3 && untouched.allSatisfy { $0.value.undo == whole[$0.key]?.undo })
        // Over by the oldest history and one step of the next: those go.
        let row = MemoryLayout<BindingModel>.stride, group = MemoryLayout<JoystickMapping>.stride
        var cut = whole
        EditorHistory.trim(&cut, order: [a, b, c], budget: allBytes - 4 * (10 * row + group) - (20 * row + group))
        var walked: [String] = []
        var stack = cut[b]?.undo ?? []
        while let last = stack.popLast() { walked.append(last.name) }
        record(cat, "Kept undo over its budget loses its oldest steps and still walks back in order",
               pass: cut[c] == nil && cut[b]?.undo == Array(midStack.suffix(2)) && cut[a]?.undo == newStack
                   && walked == ["mid 2", "mid 1"],
               detail: "old \(cut[c]?.undo.count ?? 0), mid \(cut[b]?.undo.count ?? 0), new \(cut[a]?.undo.count ?? 0)")
        var starved = whole
        EditorHistory.trim(&starved, order: [a, b, c], budget: 0)
        record(cat, "Kept undo over any budget keeps the newest snapshot of the preset just saved",
               pass: starved.count == 1 && starved[a]?.undo == [newStack[4]] && starved[a]?.savedAs.name == "new saved")
        // This library's own presets: twenty of its largest at a hundred
        // steps each still fit, so nothing it holds is ever dropped. DEBUG
        // only: the bench ships in Release, and a user with very large
        // presets would see a failure for trimming that works.
        #if DEBUG
        if let store = AppState.current?.presetStore {
            let worst = store.presets.map(EditorHistory.snapshotBytes).sorted(by: >).prefix(20).reduce(0, +) * 100
            record(cat, "This library's worst kept undo fits the byte budget", pass: worst <= EditorHistory.byteBudget,
                   detail: "\(worst >> 10) KB of \(EditorHistory.byteBudget >> 20) MB")
        }
        #endif
        let sized = Preset(name: "Sized", tag: "Tests", joysticks: [
            JoystickMapping(tag: "A", bindings: Array(repeating: BindingModel(input: InputEvent.button(0), outputs: []), count: 3)),
            JoystickMapping(tag: "B", bindings: Array(repeating: BindingModel(input: InputEvent.button(1), outputs: []), count: 5))])
        record(cat, "A step is its largest group's rows plus its groups",
               pass: EditorHistory.snapshotBytes(sized) == 5 * MemoryLayout<BindingModel>.stride + 2 * MemoryLayout<JoystickMapping>.stride)
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

        // The engine's own scaling, not this section's arithmetic.
        let ccHalf = MappingEngine.ccValue(magnitude: 0.5)
        record("Variable Sensitivity", "CC scaling 0.5 -> 64",
               pass: ccHalf == 64, detail: "Got \(ccHalf)")
        let ccFull = MappingEngine.ccValue(magnitude: 1)
        record("Variable Sensitivity", "CC scaling 1.0 -> 127",
               pass: ccFull == 127, detail: "Got \(ccFull)")

        // Pitch bend: -1 -> 0, 0 -> 8192, 1 -> 16383
        // A stick read both ways (+/-): center, ends, and the deadzone.
        record("Variable Sensitivity", "Both ways CC is 64 at center, 0 and 127 at the ends",
               pass: MappingEngine.ccValue(centered: 0) == 64 && MappingEngine.ccValue(centered: -1) == 0
                   && MappingEngine.ccValue(centered: 1) == 127)
        record("Variable Sensitivity", "Both ways stays 0 inside the deadzone on either side",
               pass: MappingEngine.bipolarValue(0.1, inner: 0.2, outer: 1) == 0
                   && MappingEngine.bipolarValue(-0.1, inner: 0.2, outer: 1) == 0)
        record("Variable Sensitivity", "Both ways rises smoothly out of the deadzone and keeps its sign",
               pass: abs(MappingEngine.bipolarValue(0.6, inner: 0.2, outer: 1) - 0.5) < 0.001
                   && abs(MappingEngine.bipolarValue(-0.6, inner: 0.2, outer: 1) + 0.5) < 0.001)
        record("Variable Sensitivity", "Both ways reaches the end at Full push",
               pass: MappingEngine.bipolarValue(0.8, inner: 0.2, outer: 0.8) == 1
                   && MappingEngine.bipolarValue(-0.9, inner: 0.2, outer: 0.8) == -1)
        let bothWaysRow = InputEvent.parse(InputEvent(type: .axis, index: 0, axisDirection: nil).serialized)
        record("Variable Sensitivity", "A both ways row survives its text form",
               pass: bothWaysRow?.type == .axis && bothWaysRow?.axisDirection == nil)
        let pbDown = MappingEngine.pitchBendValue(-1)
        let pbCenter = MappingEngine.pitchBendValue(0)
        let pbUp = MappingEngine.pitchBendValue(1)
        record("Variable Sensitivity", "Pitch bend full down",
               pass: pbDown == 0, detail: "Got \(pbDown)")
        record("Variable Sensitivity", "Pitch bend center",
               pass: pbCenter == 8192, detail: "Got \(pbCenter)")
        record("Variable Sensitivity", "Pitch bend full up",
               pass: pbUp == 16383, detail: "Got \(pbUp)")

        // Links an Open URL row or a launch link never opens, by any name.
        let refused = ["cifs://host/share", "shortcuts-production://run-shortcut?name=X", "workflow://x",
                       "facetime-open-link://x", "smb://host", "file:///etc/hosts"]
            .compactMap(URL.init(string:)).filter { SystemActionService.opensLink($0) }.map(\.absoluteString)
        record("Open URL", "Share, Shortcut and call links are refused", pass: refused.isEmpty,
               detail: refused.isEmpty ? "all refused" : "opened: \(refused.joined(separator: ", "))")
        record("Open URL", "A web link opens", pass: URL(string: "https://inputconfig.com").map(SystemActionService.opensLink) == true)
    }

    // MARK: - HID Descriptor Parser self-test
    //
    // Hand-crafted HID 1.11 short-item byte sequences representative of
    // common controller archetypes (8BitDo XInput, Hori fight stick,
    // racing wheel, generic gamepad). Each is fed through
    // `HIDDescriptorParser.parse` and the resulting GenericLayout is
    // checked for shape (button/axis/hat counts). Catches parser
    // regressions like the bit-cursor off-by-one and mixed-axis-width
    // bugs found in review.

    /// The ship review's cases: values that trapped in the macro writer, and
    /// the Steam games whose launch is their link.
    /// The review's fix-after list.
    private func runFixAfterCases() {
        let cat = "Fix after list"
        func parse(_ t: String, toggle: Bool = false) -> MacroTextResult {
            MacroText.parse(t, watches: [], currentOptions: MacroTextOptions(), isToggle: toggle)
        }
        func text(_ r: MacroTextResult) -> String { r.issues.map(\.message).joined(separator: " ") }
        var escapes = MacroRecording()
        escapes.add(.key(4), down: true, at: 0)
        escapes.add(.key(4), down: false, at: 0.05)
        escapes.add(.key(41), down: true, at: 1)
        escapes.add(.key(41), down: false, at: 1.05)
        escapes.add(.move(x: 3, y: 4), down: true, at: 1.1)
        escapes.dropTrailingEscapes(since: 1)
        record(cat, "A path sample between two Escapes goes with them", pass: escapes.edges.count == 2)
        var travel = MacroRecording()
        travel.add(.key(4), down: true, at: 0)
        travel.add(.key(4), down: false, at: 0.05)
        travel.add(.move(x: 3, y: 4), down: true, at: 0.2)
        travel.add(.move(x: 5, y: 6), down: true, at: 0.3)
        travel.dropTrailingMoves()
        record(cat, "Pausing drops the trip to the panel", pass: travel.edges.count == 2)
        record(cat, "F10 and F11 stop keys answer to Mute and Volume Down",
               pass: MacroRecorderService.isStopKey(310, stopKey: 67) && MacroRecorderService.isStopKey(312, stopKey: 68)
                   && !MacroRecorderService.isStopKey(310, stopKey: 68))
        let capped = parse(String(repeating: "tap a\n", count: 200) + "wait 500")
        record(cat, "A cap note from a trailing wait names its line", pass: text(capped).contains("201"), detail: text(capped))
        let soft = parse("tap a\u{2028}tap b\u{2029}tap c\u{85}tap d")
        record(cat, "Unicode line breaks split lines", pass: soft.steps.count == 4 && soft.issues.isEmpty, detail: text(soft))
        let typed = MacroStep(action: OutputAction(type: .typeText, text: "a\u{2028}b"))
        record(cat, "Typed text with a Unicode line break is not written as words",
               pass: typed.action.macroTextWords == nil)
        for quoted in ["type \u{201E}hallo\u{201C}", "type \u{AB}hallo\u{BB}", "type \u{BB}hallo\u{AB}"] {
            let read = parse(quoted)
            record(cat, "\(quoted) reads as text", pass: read.steps.first?.action.text == "hallo" && read.issues.isEmpty, detail: text(read))
        }
        var toggled = BindingModel(input: InputEvent.button(0), outputs: [])
        toggled.toggleMode = true
        toggled.macroInterruptOnRelease = true
        record(cat, "A toggled row's stale while held is not written",
               pass: MacroTextOptions(row: toggled).macroInterruptOnRelease == nil)
        let launchpad = parse("tap launchpad")
        record(cat, "tap launchpad is the System Function",
               pass: launchpad.steps.first?.action.type == .systemAction && launchpad.issues.allSatisfy { !$0.isError }, detail: text(launchpad))
        let volume = parse("tap volume up")
        record(cat, "tap volume up stays the key", pass: volume.steps.first?.action.type == .key, detail: text(volume))
        let app = parse("open app Safari")
        record(cat, "open app with no quotes says so", pass: text(app).contains("quotes"), detail: text(app))
        let german = ScreenTextService.recognitionPlan(for: "Bereit", preferred: ["de-DE"])
        record(cat, "Screen text reads the Mac's language", pass: german.languages.first?.hasPrefix("de") == true && !german.accurate,
               detail: german.languages.joined(separator: " "))
        let japanese = ScreenTextService.recognitionPlan(for: "\u{6E96}\u{5099}\u{5B8C}\u{4E86}", preferred: ["ja-JP"])
        record(cat, "Screen text reads Japanese at the accurate level", pass: japanese.accurate && japanese.languages.contains("ja-JP"),
               detail: japanese.languages.joined(separator: " "))
        let polish = ScreenTextService.recognitionPlan(for: "Gotowe", preferred: ["pl-PL"])
        record(cat, "A Mac language the fast level lacks stays fast for Latin words", pass: !polish.accurate,
               detail: polish.languages.joined(separator: " "))
        let typedJapanese = ScreenTextService.recognitionPlan(for: "\u{3053}\u{3093}\u{306B}\u{3061}\u{306F}", preferred: ["en-US"])
        record(cat, "Words in another script bring their language", pass: typedJapanese.languages.contains("ja-JP"),
               detail: typedJapanese.languages.joined(separator: " "))
        record(cat, "The views behind sidebar rows take no clicks",
               pass: SidebarSmoothScroll.Anchor().hitTest(.zero) == nil && SidebarClicks.Target().hitTest(.zero) == nil)
        let far = parse("nudge up 1000")
        record(cat, "A nudge past the limit says so", pass: text(far).contains("500"), detail: text(far))
    }

    private func runShipReviewCases() {
        let cat = "Ship review"
        var huge = MacroStep(action: OutputAction(type: .mouseButton))
        huge.action.clickX = 1e30
        huge.action.clickY = -1e30
        huge.eventKind = .moveTo
        let moved = MacroText.writeLine(huge, watches: [])
        record(cat, "A huge Move pointer number writes without trapping", pass: moved.contains("100000"), detail: moved)
        var mods = MacroStep(action: OutputAction(type: .key, keyCode: 4))
        mods.modifiers = [Int.max, 227]
        let clamped = mods.clamped()
        let written = MacroText.writeLine(clamped, watches: [])
        record(cat, "A huge step modifier is dropped on load", pass: clamped.modifiers == [227], detail: written)
        let unclamped = MacroText.writeLine(mods, watches: [])
        record(cat, "A huge step modifier writes without trapping", pass: !unclamped.isEmpty)
        for id in ["half-life-2", "portal-2", "team-fortress-2"] {
            guard let profile = SmartPresetLibrary.all.first(where: { $0.id == id }) else {
                record(cat, "\(id) profile is in the library", pass: false); continue
            }
            let options = SmartPresetGenerator.Options(name: id, groupID: nil, autoLaunchApp: true, appPathOverride: nil,
                                                       confineCursor: false, autoRecenter: false, hideCursor: false, lightColor: nil)
            let preset = SmartPresetGenerator.makePreset(from: profile, brand: .xbox, options: options)
            record(cat, "\(profile.displayName) keeps its steam:// link",
                   pass: preset.automation.launchURL.lowercased().hasPrefix("steam://"), detail: preset.automation.launchURL)
        }
        // The library is a bundled file now (it was a string literal that
        // put a second copy in the binary); every entry in it decodes.
        let entries = Bundle.main.url(forResource: "SmartPresetLibrary", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([JSONValue].self, from: $0) }
        record(cat, "The Smart Preset library loads every profile from its file",
               pass: !SmartPresetLibrary.all.isEmpty && entries?.count == SmartPresetLibrary.all.count,
               detail: "\(SmartPresetLibrary.all.count) of \(entries?.count ?? 0)")
    }

    /// Every drawing's notes, readability lines and control names have a
    /// German entry: a reworded note left untranslated showed in English in
    /// all 26 languages. German stands in for the 26, which move together.
    private func runLayoutTranslationCoverage() {
        guard let table = HelpLocalizer.bundledTable("layouts-de") else {
            record("Layout translations", "German drawing table loads", pass: false); return
        }
        var missing: [String] = []
        for layout in ControllerLayoutCatalog.all {
            switch layout.readability {
            case .partial(let s), .notReadable(let s): if table[s] == nil { missing.append(s) }
            case .full: break
            }
            for c in layout.controls {
                if let n = c.note, table[n] == nil { missing.append(n) }
                if let n = c.name, table[n] == nil { missing.append(n) }
                switch c.readable {
                case .notReported(let s), .conditional(let s): if table[s] == nil { missing.append(s) }
                case .read: break
                }
            }
        }
        let unique = Array(Set(missing)).sorted()
        record("Layout translations", "Every drawing note has a translation", pass: unique.isEmpty,
               detail: unique.isEmpty ? "all present" : "\(unique.count) missing: " + unique.prefix(5).joined(separator: " | "))
    }

    /// The visualizer's caches keep their newest entries past the cap,
    /// rather than emptying at a count: a lap over every preset stays warm.
    private func runCanvasCacheTests() {
        let cat = "Canvas caches"
        var cache = OldestFirstCache<Int>(cap: 256)
        for n in 0..<300 { cache["k" + String(n)] = n }
        let kept = (44..<300).allSatisfy { n in cache["k" + String(n)] == n }
        let dropped = (0..<44).allSatisfy { n in cache["k" + String(n)] == nil }
        record(cat, "Past the cap the oldest entries go, the newest stay",
               pass: cache.count == 256 && kept && dropped,
               detail: "count \(cache.count), newest 256 kept: \(kept), oldest 44 gone: \(dropped)")
        cache["k299"] = -1
        cache["k300"] = 300
        record(cat, "A rewrite keeps its place; a new key drops the oldest",
               pass: cache.count == 256 && cache["k299"] == -1 && cache["k44"] == nil && cache["k45"] == 45,
               detail: "count \(cache.count), k299 \(cache["k299"].map(String.init) ?? "nil"), k44 \(cache["k44"].map(String.init) ?? "nil")")
    }

    /// The controller drawing's frozen layer (ControllerCanvas) draws what
    /// working the drawing out draws: every complete layout, pressed, with
    /// a caption on every control, drawn with the layer off, then with it
    /// made, then looked up, compared pixel for pixel; the look up makes no
    /// layer.
    private func runCanvasFrozenLayerTests() {
        #if DEBUG
        let (drawn, differ, remade) = ControllerCanvas.debugFrozenLayerCheck()
        record("Controller drawing", "The frozen layer draws what working it out draws", pass: drawn > 0 && differ.isEmpty,
               detail: differ.isEmpty ? "\(drawn) layouts identical" : "differ: " + differ.prefix(6).joined(separator: ", "))
        record("Controller drawing", "A second draw looks the layer up", pass: remade.isEmpty,
               detail: remade.isEmpty ? "no layer made again" : "made again: " + remade.prefix(6).joined(separator: ", "))
        let (compared, routeDiffer) = ControllerCanvas.debugQuickRouteCheck()
        record("Controller drawing", "The quick key routing lays out what the full routing lays out", pass: compared > 0 && routeDiffer.isEmpty,
               detail: routeDiffer.isEmpty ? "\(compared) keys identical" : "differ: " + routeDiffer.prefix(6).joined(separator: ", "))
        let (pairs, keyDiffer) = ControllerCanvas.debugKeyCanvasCheck()
        record("Controller drawing", "The drawn key captions match the Text view captions", pass: pairs > 0 && keyDiffer.isEmpty,
               detail: keyDiffer.isEmpty ? "\(pairs) pictures within 24 levels" : "differ: " + keyDiffer.prefix(6).joined(separator: ", "))
        #endif
    }

    /// Drawing the key's captions in a Canvas (KeyCaptions) leaves VoiceOver
    /// what it had: every complete layout, in an offscreen window, read
    /// through the Accessibility API with the captions as Text views and as
    /// drawn, element for element (role, label, value, help, in order).
    /// Note: the first read turns on the app's accessibility tree for the
    /// rest of the run, as VoiceOver or any assistive app would; take timing
    /// runs in a fresh launch.
    private func runCanvasKeyAccessibilityTests() async {
        #if DEBUG
        let cat = "Controller drawing"
        let name = "Drawn key captions keep every VoiceOver element of the drawing"
        guard AXIsProcessTrusted() else {
            skip(cat, name, detail: "This build is not trusted for Accessibility, so it cannot read its own elements")
            return
        }
        let title = "InputConfig bench drawing " + UUID().uuidString
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 640, height: 1400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = title
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        let host = ControllerCanvas.debugHost()
        window.contentView = host
        window.orderFrontRegardless()
        defer {
            ControllerCanvas.keyCanvasOff = false
            window.orderOut(nil)
            window.close()
        }
        let pid = getpid()
        /// The window's elements, read off the main thread while main
        /// answers; read again until two reads agree (the tree fills in on
        /// the first request).
        func read() async -> [String] {
            var last: [String]? = nil
            for _ in 0..<4 {
                let lines = await withCheckedContinuation { (done: CheckedContinuation<[String], Never>) in
                    Thread.detachNewThread { done.resume(returning: Self.accessibilityLines(pid: pid, window: title)) }
                }
                if lines == last { return lines }
                last = lines
            }
            return last ?? []
        }
        var differ: [String] = []
        var layouts = 0, elements = 0
        for layout in ControllerLayoutCatalog.all where layout.isComplete {
            for pressed in [false, true] {
                var trees: [[String]] = []
                for off in [true, false] {
                    ControllerCanvas.debugShow(layout, pressed: pressed, keyCanvasOff: off, in: host)
                    trees.append(await read())
                }
                // The drawing's group, its label the model's name, holds
                // every control: a tree without it read nothing.
                let found = trees[0].contains { $0.contains(layout.shownName) }
                if !found || trees[0] != trees[1] {
                    differ.append("\(layout.id.rawValue)\(pressed ? " pressed" : "")"
                                  + (found ? " (\(trees[0].count) vs \(trees[1].count))" : " (not read)"))
                }
                elements += trees[1].count
            }
            layouts += 1
        }
        record(cat, name, pass: layouts > 0 && differ.isEmpty,
               detail: differ.isEmpty ? "\(layouts) layouts at rest and pressed, \(elements) elements, identical"
                                      : "differ: " + differ.prefix(6).joined(separator: ", "))
        #endif
    }

    #if DEBUG
    /// Every element under the window titled `window`, depth first, one
    /// line each: role, label, value, help. Runs off the main thread (the
    /// Accessibility API asks main for each answer); plain loops only.
    nonisolated private static func accessibilityLines(pid: pid_t, window: String) -> [String] {
        func attribute(_ e: AXUIElement, _ name: String) -> AnyObject? {
            var value: AnyObject?
            return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
        }
        func text(_ e: AXUIElement, _ name: String) -> String {
            guard let v = attribute(e, name) else { return "" }
            if let s = v as? String { return s }
            if let n = v as? NSNumber { return n.stringValue }
            return ""
        }
        var lines: [String] = []
        func walk(_ e: AXUIElement, depth: Int) {
            lines.append("\(depth) \(text(e, kAXRoleAttribute)) | \(text(e, kAXDescriptionAttribute)) | \(text(e, kAXTitleAttribute))"
                         + " | \(text(e, kAXValueAttribute)) | \(text(e, kAXHelpAttribute))")
            guard let children = attribute(e, kAXChildrenAttribute) as? [AXUIElement] else { return }
            for child in children { walk(child, depth: depth + 1) }
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 3)
        guard let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        for w in windows where text(w, kAXTitleAttribute) == window {
            if let children = attribute(w, kAXChildrenAttribute) as? [AXUIElement] {
                for child in children { walk(child, depth: 0) }
            }
        }
        return lines
    }
    #endif

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
        // crash or hang. Long-item OOB guard lives here.
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
            if f.status == .unverified, failures.isEmpty {
                info(category, "\(f.id) (unverified)", detail: detail)
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
            if seq.status == .unverified, misses.isEmpty {
                info("Fixtures: sequences", "\(seq.id) (unverified)", detail: "\(tag) \(misses.isEmpty ? "\(seq.steps.count) steps met" : misses.joined(separator: "; "))")
            } else {
                record("Fixtures: sequences", seq.id, pass: misses.isEmpty, detail: "\(tag) \(misses.isEmpty ? "\(seq.steps.count) steps met" : misses.joined(separator: "; "))")
            }
        }
    }

    #if DEBUG
    /// Raw HID reports arrive on RawHIDReportThread, not the main thread.
    /// Every raw and descriptor fixture and sequence goes through the live
    /// dispatcher twice, into two synthetic pads made the way an attach
    /// makes them: once on the main thread as before, once on the report
    /// thread. After each report both pads must hold the same buttons, axes
    /// and hats (motion is left out: the IMU code weighs each sample by the
    /// time since the last). Each descriptor pad's relative axes, now kept
    /// on the pad, must match the plan's.
    private func runRawHIDReportThreadReplay() {
        let cat = "Raw HID report thread"
        let raw = RawHIDGamepadService.shared
        var offMain = false
        RawHIDReportThread.shared.sync { offMain = !Thread.isMainThread }
        record(cat, "reports are handled off the main thread", pass: offMain)
        // Decoding held for the whole case, so removing the pads between
        // fixtures does not stop and start it (and a real 2026 Steam
        // Controller's IMU with it) a few hundred times.
        raw.setDecodingWanted(true, reason: "bench")
        defer { raw.setDecodingWanted(false, reason: "bench") }

        struct Run { let name: String; let vid: Int32; let pid: Int32; let transport: String; let device: String; let descriptor: [UInt8]?; let reports: [(UInt32, [UInt8])] }
        func run(_ name: String, _ route: HIDFixture.Route, _ transport: HIDFixture.Transport, _ device: String, _ reports: [(UInt32, [UInt8])]) -> Run? {
            let link = transport == .bluetooth ? "Bluetooth" : "USB"
            switch route {
            case .rawHID(let vid, let pid, let t):
                return Run(name: name, vid: vid, pid: pid, transport: t ?? link, device: device, descriptor: nil, reports: reports)
            case .descriptor(_, let desc, let vid, let pid, _):
                return Run(name: name, vid: vid, pid: pid, transport: link, device: device, descriptor: desc, reports: reports)
            default:
                return nil
            }
        }
        var runs: [Run] = HIDFixtureCorpus.all.compactMap { f in
            run(f.id, f.route, f.transport, f.device, [(UInt32(f.reportID), f.bytes)])
        }
        for seq in HIDFixtureCorpus.sequences {
            let transport: HIDFixture.Transport = {
                if case .rawHID(_, _, let t) = seq.route, t?.lowercased().contains("bluetooth") == true { return .bluetooth }
                return .usb
            }()
            if let r = run("seq:" + seq.id, seq.route, transport, seq.id, seq.steps.map { (UInt32($0.reportID), HIDFixture.parse($0.hex)) }) {
                runs.append(r)
            }
        }

        func signature(_ s: ControllerState) -> String {
            let b = s.buttons.keys.sorted().map { "b\($0)=\(String(format: "%.4f", s.buttons[$0] ?? 0))" }
            let a = s.axes.keys.sorted().map { "a\($0)=\(String(format: "%.4f", s.axes[$0] ?? 0))" }
            let h = s.hats.keys.sorted().map { "h\($0)=\(s.hats[$0].map { "\($0.x),\($0.y)" } ?? "")" }
            return (b + a + h).joined(separator: " ")
        }

        var compared = 0, padsMade = 0
        var mismatches: [String] = []
        var axisMisses: [String] = []
        for r in runs {
            guard let mainKey = raw.debugInstallSyntheticPad(vendorID: r.vid, productID: r.pid, transport: r.transport,
                                                              productName: r.device, descriptor: r.descriptor),
                  let threadKey = raw.debugInstallSyntheticPad(vendorID: r.vid, productID: r.pid, transport: r.transport,
                                                                productName: r.device, descriptor: r.descriptor),
                  let mainPad = raw.debugPad(key: mainKey), let threadPad = raw.debugPad(key: threadKey) else {
                // No profile for the route: the fixture checks above report it.
                raw.debugRemoveSyntheticPads()
                continue
            }
            padsMade += 1
            let planAxes: [Int] = {
                guard case .generic(let g)? = threadPad.profile?.layout else { return [] }
                return HIDExtendedLayoutRegistry.extended(for: g).relativeAxisSlots
            }()
            if threadPad.relativeAxes != planAxes {
                axisMisses.append("\(r.name): pad \(threadPad.relativeAxes) plan \(planAxes)")
            }
            for (n, report) in r.reports.enumerated() where !report.1.isEmpty {
                raw.debugInject(key: mainKey, reportID: report.0, bytes: report.1)
                raw.dispatchOnReportThread(key: threadKey, reportID: report.0, bytes: report.1, wait: true)
                compared += 1
                let onMain = signature(mainPad.state), onThread = signature(threadPad.state)
                if onMain != onThread {
                    mismatches.append("\(r.name) report \(n): main [\(onMain)] thread [\(onThread)]")
                }
            }
            raw.debugRemoveSyntheticPads()
        }
        record(cat, "\(compared) reports from \(padsMade) fixtures and sequences decode the same on the report thread",
               pass: compared > 0 && mismatches.isEmpty,
               detail: mismatches.isEmpty ? "" : mismatches.prefix(4).joined(separator: "; "))
        record(cat, "relative axes kept on each pad match the descriptor plan",
               pass: axisMisses.isEmpty, detail: axisMisses.prefix(4).joined(separator: "; "))

        // The replay hook queues its reports without waiting: they land in
        // the order sent, before anything the main thread does after them
        // on the thread (a removal, a decode start).
        if let r = runs.first(where: { $0.reports.filter { !$0.1.isEmpty }.count >= 2 }),
           let mainKey = raw.debugInstallSyntheticPad(vendorID: r.vid, productID: r.pid, transport: r.transport,
                                                      productName: r.device, descriptor: r.descriptor),
           let threadKey = raw.debugInstallSyntheticPad(vendorID: r.vid, productID: r.pid, transport: r.transport,
                                                        productName: r.device, descriptor: r.descriptor),
           let mainPad = raw.debugPad(key: mainKey), let threadPad = raw.debugPad(key: threadKey) {
            for report in r.reports where !report.1.isEmpty {
                raw.debugInject(key: mainKey, reportID: report.0, bytes: report.1)
                raw.dispatchOnReportThread(key: threadKey, reportID: report.0, bytes: report.1)
            }
            RawHIDReportThread.shared.sync {}
            let onMain = signature(mainPad.state), onThread = signature(threadPad.state)
            record(cat, "queued reports land in order (\(r.name))", pass: onMain == onThread,
                   detail: onMain == onThread ? "" : "main [\(onMain)] thread [\(onThread)]")
        } else {
            info(cat, "queued order case", detail: "no fixture sequence with two reports and a profile")
        }
        raw.debugRemoveSyntheticPads()
    }
    #endif

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
                     "activeProfile": "\(d.activeProfile)",
                     "mapped": (d.mapped?.buttons ?? [:]).filter { $0.value > 0.5 }.keys.sorted().map(String.init).joined(separator: ","),
                     "hat": d.mapped.map { "\(Int($0.hat.x)),\(Int($0.hat.y))" } ?? "nil"]
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
        case .eightBitDo: return "eightBitDo"
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
        #if DEBUG
        // As played: the velocity a key was struck with is kept after its
        // release, for a MIDI Note output that follows it. Not with a preset
        // running: an Any device row on note 127 would fire.
        if !(MappingEngine.current?.isRunning ?? false) {
        let dev = "testbench-velocity"
        MIDIInputService.shared.debugInject(status: 0x9, channel: 1, data1: 127, data2: 37, deviceID: dev)
        MIDIInputService.shared.debugInject(status: 0x8, channel: 1, data1: 127, data2: 0, deviceID: dev)
        let kept = MIDIInputService.shared.noteVelocity(127, channel: nil, deviceID: dev)
        record("MIDI Loopback", "Played velocity kept after release", pass: kept == 37,
               detail: "note 127 struck at 37, read back \(kept.map(String.init) ?? "nil")")
        MIDIInputService.shared.debugForgetVelocity(deviceID: dev)
        } else {
            skip("MIDI Loopback", "Played velocity kept after release", detail: "A preset is running")
        }
        #endif

        // The note goes out of the real virtual source, so every app
        // subscribed to it hears it. Not while a preset runs. (The MIDI
        // destinations on this Mac say nothing about who subscribes to the
        // source, so they are not checked; the result notes the reach.)
        if MappingEngine.current?.isRunning ?? false {
            skip("MIDI Loopback", "Send Note On round-trip",
                 detail: "A preset is running; stop it and run the bench again to send the test note.")
            return
        }

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
               detail: found ? "Received Note On 60 vel 100 on Ch 1; a DAW listening to InputConfig's source also received the test note"
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
        // Not while a preset runs: the diagnostics launch the helper, which
        // takes the controller out of lizard mode under the running preset.
        if MappingEngine.current?.isRunning ?? false {
            skip("Steam Controller Helper", "Helper diagnostics",
                 detail: "A preset is running; the helper is not launched by the bench meanwhile. Stop the preset and run the bench again.")
        } else {
            await runSteamHelperDiagnostics(svc)
        }

        // --- Pass 2: synthetic simulation (proves downstream bridge) ---
        svc.endSimulation()
        // Not with a real one connected: the simulation shares its state, and
        // ending it wiped the live pad's state and its learned gyro rest.
        if svc.isConnected {
            skip("Steam Controller Simulation", "Synthetic reports",
                 detail: "A Steam Controller is connected; turn it off and run the bench again.")
            return
        }
        await runSteamControllerSimulation(svc)
    }

    /// Pass 1 of the Steam Controller test: start the helper and report
    /// what it says. Released again before returning.
    private func runSteamHelperDiagnostics(_ svc: SteamControllerService) async {
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
            // A dongle with its controller off, or an idle pad, sends no frame:
            // said, not counted as a failure.
            if d.readyHandshakeReceived, d.firstStateLineReceived {
                record("Steam Controller Helper", "First state report parsed", pass: true,
                       detail: "Engine is receiving real Steam Controller HID frames.")
            } else if d.readyHandshakeReceived {
                info("Steam Controller Helper", "No input frames yet",
                     detail: "Handshake completed but no input frames: the controller may be off, or idle in its own mouse mode with no preset running. Move a stick or press a button while running this test.")
            }
        }

        // The diagnostics retain above started the helper; let it go so
        // Run All does not leave the Steam helper running.
        svc.release()
    }

    private func runSteamControllerSimulation(_ svc: SteamControllerService) async {
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
             detail: "All 23 logical buttons (A/B/X/Y, bumpers, triggers, D-pad, Steam, Back, Forward, grip paddles, trackpad clicks/touches, stick click/active) are reachable through the same ControllerState dictionary the MappingEngine reads. Bind to button indices 0...22 to fire from a real Steam Controller.")
        info("Steam Controller Simulation",
             "Trackpad / stick axis layout",
             detail: "The Steam Controller has TWO trackpads plus an analog stick. Axis 0/1 = analog thumbstick X/Y (only fires when the stick is the active source). Axis 2/3 = right trackpad X/Y. Axis 4/5 = left/right triggers. Axis 6/7 = left trackpad X/Y (only fires when the stick is NOT active). Plus button 17 = left pad click, 18 = right pad click, 19 = left pad touch, 20 = right pad touch.")
    }

    // MARK: - Keyboard Output Loopback

    /// Minimal sanity check for the keyboard-output path. We deliberately
    /// **do not** try to verify cross-app delivery from within our own
    /// process. Two attempts to do so failed:
    ///
    /// 1. A same-process `CGEventTap` listener did not reliably show
    ///    events we post from the SAME process via `.cghidEventTap`, so a
    ///    miss proves nothing. They can reach a session tap (the marker
    ///    guards in the key tap, the button tap and the wheel shaper exist
    ///    because they do), and cross-app delivery works.
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
             detail: "In-process verification is unreliable: self-posted events can reach a same-process session tap but not reliably, so a miss there proves nothing, and CGEventSource.counterForEventType deadlocks on the SkyLight subsystem when called from a sandboxed app. To prove cross-app keystrokes work, the only valid test is: open TextEdit with text, activate the Desktop Navigation preset, plug in a controller, press D-pad Up, and the text cursor should move.")
    }

    // MARK: - Scroll direction and smooth scrolling

    /// The preset's Scroll direction and Smooth scrolling, caught before
    /// they reach the system so nothing in front scrolls.
    #if DEBUG
    // MARK: - Second review

    private func runSecondAuditTests() async {
        runCatalogTests()
        runMacroTextEdgeTests()
        runRecorderRuleTests()
        runBlockMigrationTests()
        runRowRuleTests()
        runWatcherRuleTests()
        runShippedAndLimitTests()
        runHelpCoverageTests()
        runScreenDisplayTests()
        runThirdAuditTests()
        // These take the simulator's posting path, its held state, the key
        // tap's state and the engine's suspend edges: one skip per section.
        if MappingEngine.current?.isRunning ?? false {
            let why = "A preset is running; stop it and run the Test Bench again"
            for section in ["Key Blocking", "Clicks and Modifiers", "Lizard Mode", "Precision While Held", "Macro Release", "Freeze Watchdog", "Play Once", "Engine Rows"] {
                skip(section, "\(section) cases", detail: why)
            }
            return
        }
        guard MappingEngine.current != nil else {
            for section in ["Key Blocking", "Clicks and Modifiers", "Lizard Mode", "Precision While Held", "Macro Release", "Freeze Watchdog", "Play Once", "Engine Rows"] {
                skip(section, "\(section) cases", detail: "No engine")
            }
            return
        }
        runKeyTapTests()
        runKeyTapThreadTests()
        // A deadlock left a thread holding the mouse lock: what follows takes it.
        guard runClickAndFlagTests() else {
            for section in ["Lizard Mode", "Precision While Held", "Macro Release", "Freeze Watchdog", "Play Once", "Engine Rows"] {
                skip(section, "\(section) cases", detail: "A click case did not finish; the mouse lock is held")
            }
            return
        }
        runLizardEdgeTests()
        runPrecisionTests()
        await runReleaseCopiesTest()
        await runMacroOneHopTests()
        runWatchdogReleaseTest()
        runLockedPlayOnceTest()
        runEngineRowsBench()
    }

    /// Play once refused at the lock screen or asleep, run under the gate (ENG-1).
    private func runLockedPlayOnceTest() {
        let cat = "Play Once"
        guard let engine = MappingEngine.current else { return }
        let steps = [MacroStep(action: OutputAction(type: .key, keyCode: 4))]
        let oldSink = InputSimulator.debugEventSink
        InputSimulator.debugEventSink = { _ in }
        defer { InputSimulator.debugEventSink = oldSink }
        engine.debugSuspend("screen lock")
        let locked = engine.playMacroFromEditor(steps, speed: 1, jitterPercent: 0)
        engine.debugResume("screen lock")
        engine.debugSuspend(MappingEngine.unlistedAppReason)
        let gated = engine.playMacroFromEditor(steps, speed: 1, jitterPercent: 0)
        engine.stopEditorPlayback()
        engine.debugResume(MappingEngine.unlistedAppReason)
        record(cat, "Play once does not start at the lock screen, and does under Only in these apps",
               pass: !locked && gated)
    }

    /// A 300-row preset through 1,000 polls of a scripted pad, every event
    /// the engine posts caught by the sink. The stream has to match a model
    /// of the rows worked out here from the script (plain rows, a chord
    /// taking over its plain rows, a bigger chord taking over a smaller one,
    /// toggles, two rows holding one key), a second run has to give the same
    /// stream, and its digest and the time per poll are printed, so a run
    /// before and after an engine change can be compared line for line.
    private func runEngineRowsBench() {
        let cat = "Engine Rows"
        guard let engine = MappingEngine.current else { return }
        guard !engine.outputsPaused, !engine.isSuspended, !engine.editorOpen else {
            skip(cat, "300 rows through 1,000 polls", detail: "Outputs are paused or held back, or the editor is open")
            return
        }
        // Clear of the emergency hold, whichever button it is set to.
        let emergency = EmergencyStopService.shared
        let avoid: Set<Int> = [emergency.controllerButton, EmergencyStopService.startButton,
                               EmergencyStopService.defaultControllerButton]
        let pool = [4, 5, 0, 1, 2, 3, 6, 7, 10, 11, 12, 13, 14, 15].filter { !avoid.contains($0) }
        let mods = Array(pool.prefix(2)), buttons = Array(pool.dropFirst(2))
        var mains: [InputEvent] = buttons.map { InputEvent.button($0) }
        for axis in 0..<4 {
            mains.append(.axis(axis, direction: .positive))
            mains.append(.axis(axis, direction: .negative))
        }
        for direction: HatDirection in [.up, .down, .left, .right] { mains.append(.hat(0, direction: direction)) }

        // The rows, and the same rows as the model reads them: the input by
        // its place in `mains`, the held buttons, the key (none for the two
        // motion holds, which send nothing) and Toggle.
        struct Row { let main: Int; let held: [Int]; let key: Int?; let toggle: Bool }
        var rows: [Row] = []
        var bindings: [BindingModel] = []
        let keys = Array(4...39)
        for r in 0..<300 {
            let key = keys[(r * 7) % keys.count]
            let out = [OutputAction(type: .key, keyCode: key)]
            if r < 240 {
                let m = r % mains.count
                rows.append(Row(main: m, held: [], key: key, toggle: false))
                bindings.append(BindingModel(input: mains[m], outputs: out))
            } else if r < 290 {
                // One held button, the other, or both: both takes over from one.
                let m = r % buttons.count
                let held = r % 3 == 0 ? [mods[0]] : r % 3 == 1 ? [mods[1]] : mods
                var b = BindingModel(input: mains[m], outputs: out)
                b.setModifiers(held.map { InputEvent.button($0) })
                rows.append(Row(main: m, held: held, key: key, toggle: false))
                bindings.append(b)
            } else if r < 296 {
                // Each on an input of its own, so one press turns it off.
                let m = ((r - 290) * 3 + 1) % mains.count
                rows.append(Row(main: m, held: [], key: key, toggle: true))
                bindings.append(BindingModel(input: mains[m], outputs: out, toggleMode: true))
            } else {
                let m = r % buttons.count
                let kind: AppActionKind = r < 298 ? .holdMuteMotion : .holdEnableMotion
                rows.append(Row(main: m, held: [], key: nil, toggle: false))
                bindings.append(BindingModel(input: mains[m], outputs: [OutputAction(type: .appAction, appActionKind: kind)]))
            }
        }
        let preset = Preset(name: "Bench rows", tag: "Tests", joysticks: [JoystickMapping(tag: "Pad", bindings: bindings)])
        let service = engine.controllerServiceForSettings
        let slot = service.effectiveSlots(for: preset.joysticks)[0] ?? 0
        guard slot != GameControllerService.noSlot, !service.isIgnored(slot: slot) else {
            skip(cat, "300 rows through 1,000 polls", detail: "The first slot is switched off or pinned")
            return
        }

        // The script: nothing for four polls (rows held at a start wait for a
        // release), then one or two controls change every four polls, the
        // held buttons twice as often as the rest, then all let go.
        struct Pad { var down: Set<Int> = []; var axes: [Int: Float] = [0: 0, 1: 0, 2: 0, 3: 0]; var hat: (x: Float, y: Float) = (0, 0) }
        var seed: UInt64 = 0x5EED_00D3
        func next(_ n: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(seed >> 33) % n
        }
        let flips = mods + mods + buttons
        let ring: [(x: Float, y: Float)] = [(0, 0), (0, 1), (1, 0), (0, -1), (-1, 0)]
        var pads: [Pad] = []
        var pad = Pad()
        for poll in 0..<950 {
            if poll >= 4, poll % 4 == 0 {
                for _ in 0...next(2) {
                    let pick = next(flips.count + 5)
                    if pick < flips.count {
                        let b = flips[pick]
                        if pad.down.remove(b) == nil { pad.down.insert(b) }
                    } else if pick < flips.count + 4 {
                        let a = pick - flips.count
                        let v = pad.axes[a] ?? 0
                        pad.axes[a] = v == 0 ? 1 : v > 0 ? -1 : 0
                    } else {
                        let i = ring.firstIndex { $0.x == pad.hat.x && $0.y == pad.hat.y } ?? 0
                        pad.hat = ring[(i + 1) % ring.count]
                    }
                }
            }
            pads.append(pad)
        }
        pads.append(contentsOf: repeatElement(Pad(), count: 10))

        // The model: what the engine sends for these rows, poll by poll, as
        // key downs and ups once a key's first holder presses and its last
        // lets go.
        func own(_ m: Int, _ pad: Pad) -> Bool {
            let input = mains[m]
            switch input.type {
            case .button: return pad.down.contains(input.index)
            case .axis:
                let v = pad.axes[input.index] ?? 0
                return input.axisDirection == .positive ? v > 0.25 : v < -0.25
            default:
                switch input.hatDirection {
                case .up: return pad.hat.y >= 0.5
                case .down: return pad.hat.y <= -0.5
                case .left: return pad.hat.x <= -0.5
                case .right: return pad.hat.x >= 0.5
                case .none: return false
                }
            }
        }
        func simulate(_ pads: [Pad]) -> (polls: [(downs: Int, ups: Int)], toggledOn: [Int], holding: Int) {
            var active = [Bool](repeating: false, count: rows.count)
            var toggled = [Bool](repeating: false, count: rows.count)
            var latched = Set<String>()
            var holders: [Int: Set<Int>] = [:]
            var polls: [(downs: Int, ups: Int)] = []
            for pad in pads {
                var downs = 0, ups = 0
                func press(_ key: Int, _ row: Int) {
                    holders[key, default: []].insert(row)
                    if holders[key]?.count == 1 { downs += 1 }
                }
                func release(_ key: Int, _ row: Int) {
                    guard holders[key]?.remove(row) != nil else { return }
                    if holders[key]?.isEmpty == true { holders[key] = nil; ups += 1 }
                }
                var claimed = Set<Int>()
                var satisfied: [Int: [Set<Int>]] = [:]
                for row in rows where !row.held.isEmpty && row.held.allSatisfy({ pad.down.contains($0) }) && own(row.main, pad) {
                    claimed.insert(row.main)
                    satisfied[row.main, default: []].append(Set(row.held))
                }
                for (i, row) in rows.enumerated() {
                    let ownDown = own(row.main, pad)
                    var isActive = ownDown
                    if !row.held.isEmpty {
                        let k = "c\(row.main):\(row.held)"
                        if isActive { isActive = row.held.allSatisfy { pad.down.contains($0) } }
                        if isActive, let others = satisfied[row.main], others.count > 1,
                           others.contains(where: { $0.isStrictSuperset(of: Set(row.held)) }) {
                            isActive = false
                            latched.insert(k)
                        }
                        if isActive, latched.contains(k) { isActive = false } else if !ownDown { latched.remove(k) }
                    } else {
                        let k = "p\(row.main)"
                        if isActive, claimed.contains(row.main) {
                            latched.insert(k)
                            isActive = false
                        } else if isActive, latched.contains(k) {
                            isActive = false
                        } else if !isActive {
                            latched.remove(k)
                        }
                    }
                    let was = active[i]
                    active[i] = isActive
                    guard let key = row.key else { continue }
                    if row.toggle {
                        guard isActive, !was else { continue }
                        toggled[i].toggle()
                        if toggled[i] { press(key, i) } else { release(key, i) }
                    } else if isActive, !was {
                        press(key, i)
                    } else if !isActive, was {
                        release(key, i)
                    }
                }
                polls.append((downs, ups))
            }
            return (polls, rows.indices.filter { toggled[$0] }, holders.count)
        }
        // A toggle left on is pressed off before the end, so nothing is held
        // when the preset stops; then let go until the thousandth poll.
        for i in simulate(pads).toggledOn {
            var on = Pad()
            let input = mains[rows[i].main]
            switch input.type {
            case .button: on.down = [input.index]
            case .axis: on.axes[input.index] = input.axisDirection == .positive ? 1 : -1
            default:
                switch input.hatDirection {
                case .up: on.hat = (0, 1)
                case .down: on.hat = (0, -1)
                case .left: on.hat = (-1, 0)
                default: on.hat = (1, 0)
                }
            }
            pads.append(contentsOf: repeatElement(on, count: 3))
            pads.append(contentsOf: repeatElement(Pad(), count: 3))
        }
        pads.append(contentsOf: repeatElement(Pad(), count: max(0, 1000 - pads.count)))
        let expected = simulate(pads)
        let states: [ControllerState] = pads.map { pad in
            var s = ControllerState()
            for b in pool { s.buttons[b] = pad.down.contains(b) ? 1 : 0 }
            s.axes = pad.axes
            s.hats = [0: pad.hat]
            return s
        }

        let savedStats = StatsService.shared.stats
        let savedScripted = GameControllerService.debugScriptedStates
        let oldSink = InputSimulator.debugEventSink
        engine.debugLizardSink = { _ in }
        engine.debugQuiet = true
        defer {
            engine.debugQuiet = false
            engine.debugLizardSink = nil
            InputSimulator.debugEventSink = oldSink
            GameControllerService.debugScriptedStates = savedScripted
            StatsService.shared.debugRestore(savedStats)
        }
        func run() -> (events: [(poll: Int, type: UInt32, code: Int64)], seconds: Double) {
            var events: [(poll: Int, type: UInt32, code: Int64)] = []
            var poll = -1
            InputSimulator.debugEventSink = { event in
                events.append((poll, event.type.rawValue, event.getIntegerValueField(.keyboardEventKeycode)))
            }
            engine.debugStartQuiet(preset)
            let start = CACurrentMediaTime()
            for (i, state) in states.enumerated() {
                poll = i
                GameControllerService.debugScriptedStates[slot] = state
                engine.debugPollOnce()
            }
            let seconds = CACurrentMediaTime() - start
            poll = states.count
            engine.debugStopQuiet()
            InputSimulator.debugEventSink = { _ in }
            return (events, seconds)
        }
        func digest(_ events: [(poll: Int, type: UInt32, code: Int64)]) -> String {
            var h: UInt64 = 0xcbf2_9ce4_8422_2325
            for e in events {
                for v in [UInt64(e.poll), UInt64(e.type), UInt64(bitPattern: e.code)] { h = (h ^ v) &* 0x0000_0100_0000_01b3 }
            }
            return String(h, radix: 16)
        }
        let first = run()
        let second = run()

        var actual = [(downs: Int, ups: Int, other: Int)](repeating: (0, 0, 0), count: states.count)
        var afterStop = 0
        var balance: [Int64: Int] = [:]
        for e in first.events {
            guard e.poll >= 0, e.poll < states.count else { afterStop += 1; continue }
            switch e.type {
            case CGEventType.keyDown.rawValue: actual[e.poll].downs += 1; balance[e.code, default: 0] += 1
            case CGEventType.keyUp.rawValue: actual[e.poll].ups += 1; balance[e.code, default: 0] -= 1
            default: actual[e.poll].other += 1
            }
        }
        let mismatch = states.indices.first { p in
            actual[p].downs != expected.polls[p].downs || actual[p].ups != expected.polls[p].ups || actual[p].other != 0
        }
        let presses = expected.polls.reduce(0) { $0 + $1.downs }
        record(cat, "300 rows through 1,000 polls send what the rows ask for, poll by poll",
               pass: mismatch == nil && presses > 100,
               detail: mismatch.map { p in "poll \(p): sent \(actual[p]), expected \(expected.polls[p])" } ?? "\(presses) presses")
        record(cat, "Every key the rows pressed is let go, and nothing more goes out at the stop",
               pass: expected.holding == 0 && balance.values.allSatisfy { $0 == 0 } && afterStop == 0,
               detail: "model holding \(expected.holding), unbalanced \(balance.filter { $0.value != 0 }.count), at stop \(afterStop)")
        record(cat, "A second run sends the same stream",
               pass: digest(first.events) == digest(second.events) && first.events.count == second.events.count)
        info(cat, "300 rows, 1,000 polls",
             detail: "digest \(digest(first.events)), \(first.events.count) events, "
                 + "\(Int(first.seconds * 1_000_000 / Double(states.count))) and \(Int(second.seconds * 1_000_000 / Double(states.count))) us per poll")
    }

    // MARK: - Third review

    private func runThirdAuditTests() {
        runScanCompletionTests()
        runMacroKeyMarkerTests()
        runHostileInputTests()
        runMacroTextRoundTripTests()
        runSeededBuiltInTests()
        runDeferredArrivalTests()
        runHeldPaneTests()
    }

    /// The Scan path's row rules, through the same function the Scan
    /// completion calls (J-C, EDT-1).
    private func runScanCompletionTests() {
        let cat = "Scan"
        var row = BindingModel(input: .extMouseButton(3), outputs: [OutputAction(type: .key, keyCode: 4)])
        row.blockOriginal = true
        row.setModifiers([.extKey(hidCode: 225)])
        PresetEditorView.applyScannedInput(.extKey(hidCode: 26), to: &row)
        record(cat, "A Scan onto another control drops its Block and keeps a key row's Second control",
               pass: row.blockOriginal == nil && row.modifiers.map(\.serialized) == [InputEvent.extKey(hidCode: 225).serialized])
        var same = BindingModel(input: .extKey(hidCode: 26), outputs: [OutputAction(type: .key, keyCode: 4)])
        same.blockOriginal = true
        same.setModifiers([.extKey(hidCode: 225)])
        PresetEditorView.applyScannedInput(.extKey(hidCode: 26), to: &same)
        record(cat, "A Scan of the same key keeps its Block and its Second control",
               pass: same.blockOriginal == true && same.modifiers.count == 1)
        var midi = same
        PresetEditorView.applyScannedInput(.midi(.note, number: 60), to: &midi)
        record(cat, "A Scan onto a MIDI note drops the Second control", pass: midi.modifiers.isEmpty && midi.blockOriginal == nil)
    }

    /// Every writer branch through the parser and back: a changed field,
    /// count, modifier or option that one of them dropped shipped unseen
    /// (the shipped-macro case compares actions only).
    private func runMacroTextRoundTripTests() {
        let cat = "Macro Text"
        let watch = (id: UUID(), name: "Health bar")
        let text = """
        repeat: 3
        speed: 2
        vary: 25
        tap a
        cmd shift a for 120
        click
        right click
        hold middle click
        release middle click
        mouse 4
        scroll up 3
        scroll down
        move to 100, 200 over 500
        wait 80
        wait for "Health bar" up to 2000, then go on anyway
        type \u{201C}hello there\u{201D}
        hold b
        release b
        """
        func parse(_ t: String) -> MacroTextResult { MacroText.parse(t, watches: [watch], currentOptions: MacroTextOptions()) }
        func fields(_ s: MacroStep) -> String {
            "\(s.action.serialized)|\(s.modifiers ?? [])|\(s.delayMs)|\(s.holdMs)|\(s.eventKind ?? .tap)|\(s.count ?? 0)|\(s.watchID?.uuidString ?? "")|\(s.timeoutMs ?? 0)|\(s.continueOnTimeout ?? false)"
        }
        let first = parse(text)
        // 14 steps: a wait line is the next step's delay, not a step of its own.
        record(cat, "The round-trip text has no problem line", pass: !first.hasErrors && first.steps.count == 14,
               detail: first.issues.map(\.message).prefix(2).joined(separator: "; ") + " (\(first.steps.count) steps)")
        let written = MacroText.write(steps: first.steps, options: first.options, watches: [watch], heading: nil)
        let second = parse(written)
        let same = first.steps.map(fields) == second.steps.map(fields) && first.options == second.options
        let mismatch = zip(first.steps.map(fields), second.steps.map(fields)).first { $0 != $1 }
        record(cat, "Every step kind and option survives write then parse, field by field",
               pass: same, detail: mismatch.map { "\($0.0) != \($0.1)" } ?? "")
        let again = MacroText.write(steps: second.steps, options: second.options, watches: [watch], heading: nil)
        record(cat, "Writing the parsed text again gives the same text", pass: again == written)
        // The seams the import and the List paste route text through.
        record(cat, "looksLikeMacro tells macro lines from a preset file",
               pass: MacroText.looksLikeMacro("tap a") && MacroText.looksLikeMacro("hold b\nwait 80\nrelease b")
                   && !MacroText.looksLikeMacro("{\"name\":\"x\",\"joysticks\":[]}") && !MacroText.looksLikeMacro(""))
        record(cat, "blocks splits two headed macros and keeps one plain text whole",
               pass: MacroText.blocks("# Macro on A\ntap a\n\n# Macro on B\ntap b").count == 2 && MacroText.blocks("tap a\ntap b").count == 1)
        // Durations with units and the European decimal.
        func delay(_ t: String) -> Int? { let r = parse(t); return r.hasErrors ? nil : r.steps.first?.delayMs }
        func hold(_ t: String) -> Int? { let r = parse(t); return r.hasErrors ? nil : r.steps.first?.holdMs }
        record(cat, "Durations take s and ms and a comma decimal",
               pass: delay("wait 1,5s") == 1500 && delay("wait 0.5s") == 500 && delay("wait 80ms") == 80 && delay("wait 2s") == 2000
                   && hold("tap a for 0.5s") == 500 && MacroText.parseDuration("1,5s") == 1500 && MacroText.parseDuration("80ms") == 80,
               detail: "\(delay("wait 1,5s") ?? -1) \(delay("wait 0.5s") ?? -1) \(delay("wait 80ms") ?? -1) \(hold("tap a for 0.5s") ?? -1)")
        record(cat, "A comma decimal with no unit is a problem line", pass: parse("wait 1,5").hasErrors)
    }

    /// A built-in seeded by 1.9 carries the updates it has had and still
    /// reads as shipped, in memory and after a save (PER-1, PER-2).
    private func runSeededBuiltInTests() {
        let cat = "Shipped Presets and Limits"
        let shipped = ExamplePresets.showcaseMacrosTurbo
        var seeded = shipped
        BuiltInUpdate.markSeen(BuiltInUpdate.ids(for: seeded.name), on: &seeded)
        let ids = BuiltInUpdate.ids(for: seeded.name).sorted()
        var back: Preset?
        if let data = try? JSONEncoder().encode(seeded) { back = try? JSONDecoder().decode(Preset.self, from: data) }
        record(cat, "A built-in seeded with its updates is exactly as shipped, before and after a save, and is offered nothing",
               pass: !ids.isEmpty && seeded.seenUpdates == ids
                   && PresetStore.matchesShipped(seeded, shipped, builtInFolder: nil, exact: true)
                   && back.map { PresetStore.matchesShipped($0, shipped, builtInFolder: nil, exact: true) && $0.seenUpdates == ids } == true
                   && BuiltInUpdate.offers(for: seeded).isEmpty,
               detail: "\(ids)")
    }

    /// Hostile text and files: the parser and the decoder must come back,
    /// quickly, with clamped values, whatever a clipboard or a file holds.
    private func runHostileInputTests() {
        let cat = "Hostile Input"
        func parsed(_ text: String) -> (result: MacroTextResult, seconds: Double) {
            let start = CACurrentMediaTime()
            let r = MacroText.parse(text, watches: [], currentOptions: MacroTextOptions())
            return (r, CACurrentMediaTime() - start)
        }
        let longLine = parsed("type \u{201C}" + String(repeating: "a", count: 200_000) + "\u{201D}")
        record(cat, "A 200,000 character line parses in under a second", pass: longLine.seconds < 1, detail: String(format: "%.3f s", longLine.seconds))
        let manyLines = parsed(Array(repeating: "tap a", count: 10_000).joined(separator: "\n"))
        record(cat, "Ten thousand lines parse in under two seconds and are cut to the cap",
               pass: manyLines.seconds < 2 && manyLines.result.steps.count <= MacroRecording.maxSteps,
               detail: String(format: "%.3f s, %d steps", manyLines.seconds, manyLines.result.steps.count))
        let hostile = [
            "wait 99999999999999999999999", "key 99999999999999999999", "hold step {", "hold step {\"type\":\"key\",\"keyCode\":1e400}",
            "move to 1e308, -1e308 over 99999999999", "scroll up 999999999999", "tap " + String(repeating: "shift ", count: 5000) + "a",
            "type \u{201C}" + String(repeating: "\u{201C}", count: 1000) + "\u{201D}", "wait for " + String(repeating: "x", count: 10_000),
            String(repeating: "# ", count: 50_000), "repeat: 99999999999999999", "speed: -1e308", "vary: 1e308",
        ]
        var slow: [String] = []
        for text in hostile {
            let r = parsed(text)
            if r.seconds > 0.5 { slow.append(String(text.prefix(20))) }
            for step in r.result.steps {
                if step.delayMs < 0 || step.holdMs < 0 { slow.append("negative time from " + String(text.prefix(20))) }
            }
        }
        record(cat, "Hostile lines come back within half a second with no negative times", pass: slow.isEmpty, detail: "\(slow)")
        // A preset file with wrong types, wild numbers and unknown enum raw
        // values either refuses to decode or decodes to clamped values.
        var row = BindingModel(input: .button(0), outputs: [OutputAction(type: .key, keyCode: 4)])
        row.macroSteps = Array(repeating: MacroStep(action: OutputAction(type: .key, keyCode: 4), delayMs: 1, holdMs: 1), count: 3_000)
        var p = Preset(name: "Hostile", tag: "Tests", joysticks: [JoystickMapping(tag: "Pad", bindings: [row])])
        p.notes = String(repeating: "n", count: 200_000)
        guard var dict = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(p))) as? [String: Any] else {
            record(cat, "Preset round trip", pass: false); return
        }
        var joysticks = dict["joysticks"] as! [[String: Any]]
        var bindings = joysticks[0]["bindings"] as! [[String: Any]]
        var b = bindings[0]
        // Numbers that decode: a Double past a Float's range drops the row.
        b["deadzone"] = 1e30; b["holdThresholdMs"] = -5; b["repeatCount"] = 1 << 40; b["turboRate"] = 0
        var input = b["input"] as! [String: Any]; input["index"] = -99_999_999_999; b["input"] = input
        bindings[0] = b; joysticks[0]["bindings"] = bindings; dict["joysticks"] = joysticks
        dict["formatVersion"] = 99; dict["seenUpdates"] = ["a": 1]; dict["futureField"] = ["deep": [1, NSNull()]]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        let start = CACurrentMediaTime()
        let decoded = try? JSONDecoder().decode(Preset.self, from: data)
        let took = CACurrentMediaTime() - start
        var sane = true
        if let d = decoded {
            // The row has to be there: dropped, there was no clamp to read.
            if let r = d.clampedValues().joysticks.first?.bindings.first {
                sane = (r.macroSteps?.count ?? 0) <= Preset.macroStepsLoadCeiling
                    && (r.repeatCount ?? 1) <= 100 && (r.holdThresholdMs ?? 50) >= 50
                    && (r.deadzone ?? 0) <= 1
            } else {
                sane = false
            }
        }
        record(cat, "A hostile preset file decodes to clamped values or is refused, in under a second",
               pass: took < 1 && sane, detail: String(format: "%.3f s, decoded %@", took, decoded == nil ? "no" : "yes"))
        let types = ["{\"id\":\"x\",\"name\":5,\"joysticks\":\"nope\"}", "[1,2]", "", "{}", "{\"joysticks\":[{\"bindings\":[{\"input\":{\"type\":\"warpDrive\"}}]}]}"]
        var crashedOrSlow: [String] = []
        for t in types {
            let s = CACurrentMediaTime()
            _ = try? JSONDecoder().decode(Preset.self, from: Data(t.utf8))
            if CACurrentMediaTime() - s > 0.5 { crashedOrSlow.append(t) }
        }
        record(cat, "Wrong-typed, empty and unknown-enum preset files are refused or read without a trap", pass: crashedOrSlow.isEmpty)
    }

    /// A held or released key named like a System Function is written with
    /// `key`, and every verb reads it back as the key (J-E).
    private func runMacroKeyMarkerTests() {
        let cat = "Macro Text"
        var turned: [String] = []
        for code in [71, 72, 304, 307, 308, 309, 310, 311, 312] {
            for kind in [MacroStepKind.down, .up] {
                let step = MacroStep(action: OutputAction(type: .key, keyCode: code), eventKind: kind)
                let text = MacroText.write(steps: [step], options: nil, watches: [], heading: nil)
                let back = MacroText.parse(text, watches: [], currentOptions: MacroTextOptions()).steps
                if back.count != 1 || back[0].action.type != .key || back[0].action.keyCode != code || back[0].eventKind != kind {
                    turned.append("\(kind == .down ? "hold" : "release") \(code)")
                }
            }
        }
        record(cat, "A held or released key named like a System Function reads back as the key", pass: turned.isEmpty, detail: "\(turned)")
        let marked = MacroText.parse("tap key volume up", watches: [], currentOptions: MacroTextOptions()).steps
        record(cat, "tap key volume up is the key", pass: marked.count == 1 && marked[0].action.type == .key)
        let number = MacroText.parse("hold key 2047", watches: [], currentOptions: MacroTextOptions()).steps
        record(cat, "key with a code number still reads", pass: number.count == 1 && number[0].action.keyCode == 2047)
    }

    /// The four events: a pad listed under an app's switch, a preset picked
    /// by hand in the game, the person leaving it, the waiting pad looked at
    /// again (J-G).
    private func runDeferredArrivalTests() {
        let cat = "Automatic Switching"
        typealias W = ControllerConnectWatcher
        let listed = Date()
        let chosen = listed.addingTimeInterval(5)
        let left = listed.addingTimeInterval(9)
        let deferred = ["dualsense": listed]
        record(cat, "A pad waiting out an app's switch is dropped once a preset is picked by hand",
               pass: W.releasedArrivals(deferred, handChosen: chosen).isEmpty)
        record(cat, "With no hand choice the waiting pad is looked at again",
               pass: W.releasedArrivals(deferred, handChosen: nil) == ["dualsense"]
                   && W.releasedArrivals(deferred, handChosen: listed.addingTimeInterval(-5)) == ["dualsense"])
        let a = UUID(), h = UUID()
        record(cat, "A waiting pad with a hand choice after it connected leaves that choice",
               pass: W.isReconnect(now: left, departed: nil, connected: listed, handChosen: chosen, deferred: true)
                   && W.arrivalAction(appHolds: false, reconnect: true, active: h, restored: a) == .leave
                   && !W.isReconnect(now: left, departed: nil, connected: listed, handChosen: chosen))
    }

    /// The editor's Text pane registry: clean lines are written by Save,
    /// the rest are asked about, a deleted row's go with it (J-D).
    private func runHeldPaneTests() {
        let cat = "Macro Text Pane"
        // All four, with the editor maybe open: a section name being typed
        // was lost on the next Save when the hooks were left cleared.
        let saved = EditorInlineEdit.panes
        let savedEnd = EditorInlineEdit.end, savedOwner = EditorInlineEdit.owner, savedFieldCommit = EditorInlineEdit.commit
        defer {
            EditorInlineEdit.panes = saved
            EditorInlineEdit.end = savedEnd
            EditorInlineEdit.owner = savedOwner
            EditorInlineEdit.commit = savedFieldCommit
        }
        EditorInlineEdit.panes = [:]
        let rowA = BindingModel(input: .button(0), outputs: []), rowB = BindingModel(input: .button(1), outputs: [])
        let gone = UUID()
        func pane(_ name: String, _ wait: EditorInlineEdit.HeldPane.Wait) -> EditorInlineEdit.HeldPane {
            EditorInlineEdit.HeldPane(wait: { _ in wait },
                                      write: { _, yes in { row in row.note = yes ? name + "!" : name } },
                                      lostLine: { _ in name })
        }
        EditorInlineEdit.holdPane(rowA.id, pane("a", .clean))
        EditorInlineEdit.holdPane(rowB.id, pane("b", .needsYes(["opens"])))
        EditorInlineEdit.holdPane(gone, pane("gone", .clean))
        var preset = Preset(name: "Panes", tag: "Tests", joysticks: [JoystickMapping(tag: "Pad", bindings: [rowA, rowB])])
        EditorInlineEdit.commitPanes(in: &preset)
        let notes = preset.joysticks[0].bindings.map { $0.note ?? "" }
        // The written pane is let go; the one still asking stays held.
        record(cat, "Save writes clean pane lines to the draft's row and leaves the rest to ask about",
               pass: notes == ["a", ""] && EditorInlineEdit.heldPanes(in: preset).count == 1, detail: "\(notes)")
        // A field's commit writes through the editor's storage, as a
        // section heading does through its row binding. The draft here is
        // read through get and set, as @State is, so an inout access takes
        // a copy first: the field must commit before that access.
        final class Draft { var storage: Preset; init(_ p: Preset) { storage = p }
            var preset: Preset { get { storage } set { storage = newValue } } }
        let draft = Draft(preset)
        let savedCommit = EditorInlineEdit.commit
        EditorInlineEdit.commit = { draft.storage.joysticks[0].bindings[0].section = "Typed" }
        EditorInlineEdit.commitField()
        EditorInlineEdit.commitPanes(in: &draft.preset)
        EditorInlineEdit.commit = savedCommit
        record(cat, "A section name still being typed survives Save's pane pass",
               pass: draft.storage.joysticks[0].bindings[0].section == "Typed",
               detail: draft.storage.joysticks[0].bindings[0].section ?? "nil")
        EditorInlineEdit.reset()
        record(cat, "An inline field ending does not drop a pane", pass: EditorInlineEdit.panes.count == 2)
        EditorInlineEdit.resetAll()
        record(cat, "Closing the editor drops every pane", pass: EditorInlineEdit.panes.isEmpty)
    }

    /// The watchdog's release and stamp from its own queue while main is
    /// held: a defaults observer on the main queue made the stamp wait for
    /// main, so nothing was let go during the hang (J-H).
    private func runWatchdogReleaseTest() {
        let cat = "Freeze Watchdog"
        let key = CrashRecoveryService.lastFreezeKey
        let before = UserDefaults.standard.object(forKey: key)
        let done = DispatchSemaphore(value: 0)
        let start = Date()
        DispatchQueue.global().async {
            FreezeWatchdogService.letGoDuringFreeze()
            done.signal()
        }
        // Main is held right here, as in a hang.
        let finished = done.wait(timeout: .now() + 2) == .success
        let took = Date().timeIntervalSince(start)
        // The call that timed out finishes once main is free: waited for,
        // so its late stamp cannot land over the value put back.
        // Under the real watchdog's 15 s, so it does not stamp a freeze the
        // bench caused over the value put back; a slower one may still land.
        if !finished { _ = done.wait(timeout: .now() + 10) }
        let stamped = (UserDefaults.standard.object(forKey: key) as? Double).map { $0 > start.timeIntervalSince1970 - 1 } == true
        if let before { UserDefaults.standard.set(before, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        record(cat, "The watchdog lets go and stamps from its own queue while main is held",
               pass: finished && stamped, detail: String(format: "%.3f s, stamped %@", took, stamped ? "yes" : "no"))
    }

    /// Format 4 dropped the Block a 1.8 file left on rows it never meant.
    private func runBlockMigrationTests() {
        let cat = "Preset Format"
        func row(_ input: InputEvent) -> BindingModel {
            var r = BindingModel(input: input, outputs: [OutputAction(type: .key, keyCode: 44)])
            r.blockOriginal = true
            return r
        }
        var doubleClick = InputEvent.extMouseButton(3); doubleClick.extMouseKind = .doubleClick
        let preset = Preset(name: "Blocks", tag: "Tests", joysticks: [JoystickMapping(tag: "Mac", bindings: [
            row(.extKey(hidCode: 26)), row(.extMouseButton(3)), row(doubleClick), row(.keySequence([26, 22])),
        ])])
        guard let data = try? JSONEncoder().encode(preset),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            record(cat, "Block migration fixture encodes", pass: false); return
        }
        func kept(version: Int?) -> [Bool]? {
            var copy = json
            copy["formatVersion"] = version
            guard let bytes = try? JSONSerialization.data(withJSONObject: copy),
                  let decoded = try? JSONDecoder().decode(Preset.self, from: bytes) else { return nil }
            return decoded.joysticks[0].bindings.map { $0.blockOriginal == true }
        }
        record(cat, "Below format 4 only a pressed mouse button keeps Block",
               pass: kept(version: 3) == [false, true, false, false] && kept(version: nil) == [false, true, false, false],
               detail: "\(String(describing: kept(version: 3)))")
        record(cat, "From format 4 every Block stays",
               pass: kept(version: 4) == [true, true, true, true] && kept(version: 5) == [true, true, true, true])
    }

    private func runRowRuleTests() {
        let cat = "Row Rules"
        // Never held: Hold, Turbo and Only while held are not offered.
        var doubleClick = InputEvent.extMouseButton(3); doubleClick.extMouseKind = .doubleClick
        var wheelY = InputEvent.extMouseButton(0); wheelY.extMouseKind = .scrollY
        var wheelX = InputEvent.extMouseButton(0); wheelX.extMouseKind = .scrollX
        let never: [InputEvent] = [.buttonSequence([253, 0]), .keySequence([26, 22]), doubleClick, wheelY, wheelX]
        let held: [InputEvent] = [.button(0), .extMouseButton(3), .extKey(hidCode: 26)]
        record(cat, "Sequences, a double click and wheel notches are never held",
               pass: never.allSatisfy(MappingEngine.isNeverHeld))
        record(cat, "A button, a mouse button and a key can be held",
               pass: !held.contains(where: MappingEngine.isNeverHeld))
        // What a row keeps when its input changes.
        var moved = BindingModel(input: .extMouseButton(3), outputs: [])
        moved.blockOriginal = true
        moved.macroInterruptOnRelease = true
        moved.input = .extKey(hidCode: 26)
        moved.forgetInputBoundOptions()
        record(cat, "Block does not follow a row to a new input, and Only while held stays on one that can be held",
               pass: moved.blockOriginal == nil && moved.macroInterruptOnRelease == true)
        moved.macroInterruptOnRelease = true
        moved.input = .keySequence([26, 22])
        moved.forgetInputBoundOptions()
        record(cat, "Only while held goes on an input that is never held", pass: moved.macroInterruptOnRelease == nil)
        // The way out of an editing session.
        var scrollOnly = Preset(name: "Scroll", tag: "Tests")
        scrollOnly.automation.scrollReverseVertical = true
        let empty = Preset(name: "Empty", tag: "Tests")
        let pointer = Preset(name: "Pointer", tag: "Tests", joysticks: [JoystickMapping(tag: "Pad", bindings: [
            BindingModel(input: .button(0), outputs: [OutputAction(type: .mouseButton, mouseButtonIndex: 0)])])])
        let safeKeys = Preset(name: "Keys", tag: "Tests", joysticks: [JoystickMapping(tag: "Pad", bindings: [
            BindingModel(input: .button(0), outputs: [OutputAction(type: .key, keyCode: 40)])])])
        record(cat, "A draft with nothing to run has no way out",
               pass: !MappingEngine.draftKeepsWayOut(saved: scrollOnly, draft: empty))
        record(cat, "A scroll-only preset's draft keeps its way out",
               pass: MappingEngine.draftKeepsWayOut(saved: scrollOnly, draft: scrollOnly))
        record(cat, "A draft that drops the pointer rows loses the way out",
               pass: !MappingEngine.draftKeepsWayOut(saved: pointer, draft: scrollOnly))
        record(cat, "A draft that drops the Return row loses the way out",
               pass: !MappingEngine.draftKeepsWayOut(saved: safeKeys, draft: scrollOnly))
        record(cat, "A scroll style asks for Accessibility", pass: scrollOnly.needsAccessibility && !empty.needsAccessibility)
    }

    private func runPrecisionTests() {
        let cat = "Precision While Held"
        let sim = InputSimulator.shared
        sim.setPrecision(0.5, owner: "1:a")
        sim.setPrecision(0.5, owner: "2:b")
        sim.clearPrecision(ownerPrefix: "1:")
        record(cat, "A pad that leaves clears only its own rows' holds", pass: sim.debugPrecisionHolders == 1)
        sim.clearPrecision()
        record(cat, "The full clear leaves none", pass: sim.debugPrecisionHolders == 0)
        sim.setPrecision(0.5, owner: "1:a")
        MappingEngine.current?.stop()
        record(cat, "Stop clears a hold with nothing running", pass: sim.debugPrecisionHolders == 0)
    }

    /// A Release step lets go of every held copy of a key, one per part of a
    /// shortcut; read from inside the chain, since its end lets go of all.
    private func runReleaseCopiesTest() async {
        let cat = "Macro Release"
        guard let engine = MappingEngine.current else { return }
        let sim = InputSimulator.shared
        let oldSink = InputSimulator.debugEventSink
        InputSimulator.debugEventSink = { _ in }
        defer { InputSimulator.debugEventSink = oldSink }
        func step(_ code: Int, _ kind: MacroStepKind, delay: Int = 0) -> MacroStep {
            MacroStep(action: OutputAction(type: .key, keyCode: code), delayMs: delay, holdMs: 0, eventKind: kind)
        }
        engine.playMacroFromEditor([step(225, .down), step(225, .down), step(225, .up, delay: 300), step(44, .tap, delay: 400)],
                                   speed: 1, jitterPercent: 0)
        try? await Task.sleep(for: .milliseconds(150))
        let heldMid = sim.debugHeldKeyCount
        try? await Task.sleep(for: .milliseconds(300))
        let heldAfter = sim.debugHeldKeyCount
        record(cat, "Two Hold Shift then Release Shift holds Shift, then nothing",
               pass: heldMid == 1 && heldAfter == 0, detail: "\(heldMid) then \(heldAfter)")
        try? await Task.sleep(for: .milliseconds(550))
        // A chain running late would type a real Space once the sink is back,
        // and fail the Play once case after it.
        for _ in 0..<60 where engine.editorPlaybackRunning { try? await Task.sleep(for: .milliseconds(50)) }
    }

    /// A Tap or Hold down step asks main once, in its press hop (D6): the
    /// order of what goes out is the same, and a stop during a step's wait
    /// or a Wait step presses nothing after it.
    private func runMacroOneHopTests() async {
        let cat = "Macro Play"
        guard let engine = MappingEngine.current else { return }
        final class Caught: @unchecked Sendable {
            let lock = NSLock()
            var keys: [String] = []
            func take() -> [String] { lock.lock(); defer { keys = []; lock.unlock() }; return keys }
        }
        let caught = Caught()
        let oldSink = InputSimulator.debugEventSink
        InputSimulator.debugEventSink = { event in
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let mark: String
            switch event.type {
            case .keyDown: mark = "\(code)v"
            case .keyUp: mark = "\(code)^"
            case .flagsChanged: mark = "\(code)f"
            default: return
            }
            caught.lock.lock(); caught.keys.append(mark); caught.lock.unlock()
        }
        defer { InputSimulator.debugEventSink = oldSink }
        func step(_ code: Int, _ kind: MacroStepKind, delay: Int = 0, hold: Int = 0) -> MacroStep {
            MacroStep(action: OutputAction(type: .key, keyCode: code), delayMs: delay, holdMs: hold, eventKind: kind)
        }
        func finish() async {
            for _ in 0..<40 where engine.editorPlaybackRunning { try? await Task.sleep(for: .milliseconds(25)) }
        }
        // Hold Shift, tap A under it, release Shift, tap B.
        _ = caught.take()
        engine.playMacroFromEditor([step(225, .down), step(4, .tap, hold: 20), step(225, .up), step(5, .tap, delay: 50, hold: 20)],
                                   speed: 1, jitterPercent: 0)
        await finish()
        let played = caught.take()
        let plain = played.filter { !$0.hasSuffix("f") }
        let shift = played.indices.filter { played[$0] == "56f" }
        let order = plain == ["0v", "0^", "11v", "11^"] && shift.count == 2
            && shift[0] < (played.firstIndex(of: "0v") ?? -1)
            && shift[1] > (played.firstIndex(of: "0^") ?? Int.max) && shift[1] < (played.firstIndex(of: "11v") ?? -1)
        record(cat, "Hold Shift, Tap A, Release Shift, Tap B go out in that order",
               pass: order && !engine.editorPlaybackRunning, detail: played.joined(separator: " "))
        // Stopped during the next Tap's wait: its press hop refuses it.
        engine.playMacroFromEditor([step(4, .tap, hold: 20), step(5, .tap, delay: 300, hold: 20)], speed: 1, jitterPercent: 0)
        try? await Task.sleep(for: .milliseconds(100))
        engine.stopEditorPlayback()
        await finish()
        let cut = caught.take()
        record(cat, "A stop during a Tap's wait presses nothing more",
               pass: cut == ["0v", "0^"] && !engine.editorPlaybackRunning, detail: cut.joined(separator: " "))
        // Stopped during a Wait step: its own gate ends the chain.
        engine.playMacroFromEditor([step(4, .tap, hold: 20), step(0, .wait, delay: 300), step(5, .tap, hold: 20)],
                                   speed: 1, jitterPercent: 0)
        try? await Task.sleep(for: .milliseconds(100))
        engine.stopEditorPlayback()
        await finish()
        let waited = caught.take()
        record(cat, "A stop during a Wait step presses nothing more",
               pass: waited == ["0v", "0^"] && !engine.editorPlaybackRunning, detail: waited.joined(separator: " "))
    }

    /// The languages the app declares (Bundle.main.localizations listed
    /// each one twice here, so a count against it was meaningless).
    private static var shippedLanguages: Set<String> {
        Set(Bundle.main.object(forInfoDictionaryKey: "CFBundleLocalizations") as? [String] ?? [])
    }

    /// Every compiled language table, read straight from the bundle.
    private func languageTables(_ table: String) -> [String: [String: String]] {
        var out: [String: [String: String]] = [:]
        for lang in Bundle.main.localizations where lang != "Base" {
            guard let url = Bundle.main.url(forResource: table, withExtension: "strings", subdirectory: nil, localization: lang),
                  let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
            out[lang] = plist.compactMapValues { $0 as? String }
        }
        return out
    }

    private func runCatalogTests() {
        let cat = "Catalogs"
        let tables = languageTables("Localizable")
        // The build writes these two as binary plists (Pack Text Resources);
        // the string catalog compiles them to UTF-16 XML, 38 percent larger.
        var unpacked: [String] = []
        for lang in Bundle.main.localizations where lang != "Base" {
            for table in ["Localizable", "KeyNames"] {
                guard let url = Bundle.main.url(forResource: table, withExtension: "strings", subdirectory: nil, localization: lang),
                      let handle = try? FileHandle(forReadingFrom: url) else { continue }
                if (try? handle.read(upToCount: 6)) != Data("bplist".utf8) { unpacked.append("\(lang) \(table)") }
                try? handle.close()
            }
        }
        record(cat, "The Localizable and KeyNames tables ship as binary plists",
               pass: unpacked.isEmpty && !tables.isEmpty, detail: unpacked.prefix(5).joined(separator: "; "))
        let spec = /%(?:(\d+)\$)?(lld|ld|d|@|f|\.\df)/
        func specifiers(_ text: String) -> (kinds: [String], indexed: Bool) {
            let found = text.matches(of: spec)
            return (found.map { String($0.output.2) }, found.contains { $0.output.1 != nil })
        }
        var reordered: [String] = []
        var dashed: [String] = []
        for (lang, table) in tables {
            for (key, value) in table {
                if value.unicodeScalars.contains(where: { (0x2013...0x2015).contains($0.value) }) { dashed.append("\(lang): \(key)") }
                let source = specifiers(key)
                guard Set(source.kinds).count >= 2 else { continue }
                let target = specifiers(value)
                if !target.indexed, target.kinds != source.kinds { reordered.append("\(lang): \(key)") }
            }
        }
        let languages = Self.shippedLanguages.count
        record(cat, "Every language table is present", pass: tables.count == languages, detail: "\(tables.count) of \(languages)")
        record(cat, "A translation with two kinds of placeholder keeps their order or numbers them",
               pass: reordered.isEmpty, detail: reordered.prefix(5).joined(separator: "; "))
        record(cat, "No translation holds an en, em or horizontal dash",
               pass: dashed.isEmpty, detail: dashed.prefix(5).joined(separator: "; "))
        // Plural keys sit in the .stringsdict in the languages that need one;
        // English holds only those, and the arrow keys are right-to-left only.
        var keySets: [String: Set<String>] = [:]
        for (lang, table) in tables where lang != "en" {
            var keys = Set(table.keys)
            if let url = Bundle.main.url(forResource: "Localizable", withExtension: "stringsdict", subdirectory: nil, localization: lang),
               let plurals = NSDictionary(contentsOf: url) as? [String: Any] { keys.formUnion(plurals.keys) }
            keySets[lang] = keys.filter { !$0.contains("\u{2192}") }
        }
        let every = keySets.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        let short = keySets.filter { $0.value.count != every.count }.map { "\($0.key) lacks \(every.subtracting($0.value).sorted().prefix(2))" }
        record(cat, "Every language has the same keys", pass: short.isEmpty, detail: short.sorted().prefix(4).joined(separator: "; "))
        // The other catalogs: every language, and no dash.
        for table in ["KeyNames", "AppShortcuts", "InfoPlist"] {
            let other = languageTables(table)
            let dashes = other.flatMap { lang, t in
                t.values.filter { $0.unicodeScalars.contains { (0x2013...0x2015).contains($0.value) } }.map { "\(lang): \($0)" }
            }
            record(cat, "\(table) is in every language with no dash",
                   // English is the source of these three; its strings are the keys.
                   pass: other.count >= languages - 1 && Set(other.keys).isSuperset(of: Self.shippedLanguages.subtracting(["en"]))
                       && dashes.isEmpty, detail: "\(other.count) of \(languages) languages; \(dashes.prefix(3))")
        }
        let british = ["cancelled", "colour", "centre", "behaviour", "favourite", "organis", "analys", "grey"]
        let spelled = (tables.first?.value.keys ?? [String: String]().keys).filter { key in
            british.contains { key.lowercased().contains($0) } && !key.lowercased().contains("analysis")
        }
        record(cat, "English strings use American spelling", pass: spelled.isEmpty, detail: spelled.prefix(5).joined(separator: "; "))
    }

    private func runMacroTextEdgeTests() {
        let cat = "Macro Text"
        func roundTrip(_ steps: [MacroStep]) -> [MacroStep] {
            let text = MacroText.write(steps: steps, options: nil, watches: [], heading: nil)
            return MacroText.parse(text, watches: [], currentOptions: MacroTextOptions()).steps
        }
        // Keys whose words start with a System Function's word stay keys.
        var turned: [Int] = []
        for code in [71, 72, 304, 307, 308, 309, 310, 311, 312] {
            let back = roundTrip([MacroStep(action: OutputAction(type: .key, keyCode: code))])
            if back.count != 1 || back[0].action.type != .key || back[0].action.keyCode != code { turned.append(code) }
        }
        record(cat, "A key step named like a System Function reads back as the key", pass: turned.isEmpty, detail: "\(turned)")
        let held = MacroText.parse("hold volume up", watches: [], currentOptions: MacroTextOptions()).steps
        record(cat, "hold volume up written by hand is the System Function",
               pass: held.count == 1 && held[0].action.type == .systemAction)
        func parsed(_ text: String) -> MacroTextResult {
            MacroText.parse(text, watches: [], currentOptions: MacroTextOptions())
        }
        func typed(_ text: String) -> String? {
            let result = parsed(text)
            return result.hasErrors ? nil : result.steps.first?.action.text
        }
        record(cat, "A # inside curly quotes is text", pass: typed("type \u{201C}a # b\u{201D}") == "a # b")
        record(cat, "Straight quotes sit inside a curly pair", pass: typed("type \u{201C}a \"b\" c\u{201D}") == "a \"b\" c")
        record(cat, "An apostrophe in straight quotes is text", pass: typed("type \"it's\"") == "it's")
        record(cat, "A lone curly quote is a problem, not text", pass: parsed("type \u{201C}abc").hasErrors)
        record(cat, "A straight quote does not close a curly one", pass: parsed("type \u{201C}abc\"").hasErrors)
        record(cat, "nudge without a direction is a problem", pass: parsed("nudge 10").hasErrors)
        record(cat, "hold scroll, hold type and hold nudge are problems",
               pass: parsed("hold scroll up").hasErrors && parsed("hold type \"a\"").hasErrors && parsed("hold nudge up 10").hasErrors)
        record(cat, "A key with fn as the last word keeps its modifier", pass: !parsed("cmd fn").hasErrors)
        let long = Array(repeating: "tap a", count: 205).joined(separator: "\n")
        record(cat, "Lines past the 200 step cap are cut with a note",
               pass: parsed(long).steps.count == MacroRecording.maxSteps)
        let rows = ExamplePresets.macrosTurbo19Rows
        let shipped = rows.typed.macroSteps ?? []
        let again = roundTrip(shipped)
        // A wait step's action means nothing; only the steps that do something compare.
        func acts(_ steps: [MacroStep]) -> [String] { steps.filter { $0.eventKind != .wait }.map(\.action.serialized) }
        record(cat, "The shipped typed macro reads back step for step",
               pass: !shipped.isEmpty && acts(again) == acts(shipped) && again.count == shipped.count)
    }

    private func runRecorderRuleTests() {
        let cat = "Macro Recorder"
        typealias C = MacroRecording.Control
        func kinds(_ take: MacroRecording) -> [MacroStepKind] { take.steps().map { $0.eventKind ?? .tap } }
        var scroll = MacroRecording()
        scroll.add(.key(227), down: true, at: 1)
        scroll.add(.scroll(axis: .vertical, lines: 2), down: true, at: 1.5)
        scroll.closeOpen([.key(227)])
        let held = scroll.steps()
        record(cat, "A modifier still down over a trailing scroll stays a Hold, a Scroll and a Release",
               pass: held.count == 3 && held[0].eventKind == .down && held[1].action.type == .mouseWheelStep && held[2].eventKind == .up,
               detail: "\(kinds(scroll))")
        var alone = MacroRecording()
        alone.add(.key(227), down: true, at: 1)
        alone.closeOpen([.key(227)])
        record(cat, "A press with nothing after it is dropped", pass: alone.isEmpty)
        // Exact edges: the press with nothing after it is dropped, the one
        // held over the click closes a millisecond after the click's up.
        var take = MacroRecording()
        take.add(.key(227), down: true, at: 1)
        take.add(.mouseButton(0), down: true, at: 1.2)
        take.add(.mouseButton(0), down: false, at: 1.3)
        take.add(.key(225), down: true, at: 1.4)
        take.closeOpen([.key(227), .key(225)])
        let closed = take.edges
        let exact = closed.count == 4
            && closed[0].control == .key(227) && closed[0].down && closed[0].at == 1
            && closed[1].control == .mouseButton(0) && closed[1].down
            && closed[2].control == .mouseButton(0) && !closed[2].down
            && closed[3].control == .key(227) && !closed[3].down && abs(closed[3].at - 1.301) < 1e-9
        record(cat, "Two open presses with a click between: the empty one goes, the held one closes 1 ms after the click",
               pass: exact && kinds(take) == [.down, .tap, .up],
               detail: closed.map { "\($0.control) \($0.down ? "d" : "u") \($0.at)" }.joined(separator: ", "))
        record(cat, "The stop key answers, and F12 to the Volume Up key as well",
               pass: MacroRecorderService.isStopKey(69, stopKey: 69) && MacroRecorderService.isStopKey(311, stopKey: 69)
                   && !MacroRecorderService.isStopKey(311, stopKey: 70) && !MacroRecorderService.isStopKey(69, stopKey: -1))
        record(cat, "Skip the first click, and a click just after the switch",
               pass: MacroRecorderService.firstClickSkipped(awaiting: true, sinceSwitch: nil)
                   && MacroRecorderService.firstClickSkipped(awaiting: false, sinceSwitch: 0.2)
                   && !MacroRecorderService.firstClickSkipped(awaiting: false, sinceSwitch: 1))
    }

    /// The key tap's decision, with its state saved and put back: below the
    /// running guard, since each synthetic press is also fed to the rows.
    private func runKeyTapTests() {
        let cat = "Key Blocking"
        let service = ExternalInputDeviceService.shared
        let w = 13, f13 = 105, f5 = 96
        let wCode = 26, f13Code = 104, f5Code = 62   // HID usages for the blocked keys
        let saved = service.debugKeyBlockState()
        defer {
            service.debugRestoreKeyBlocks(saved)
            ExternalInputDeviceService.debugGlobeHeld = nil
        }
        service.debugClearSwallowed()
        service.debugSetKeyBlocks([wCode, f13Code])
        let plain = service.debugKeyTap(down: true, virtualKey: w)
        let repeated = service.debugKeyTap(down: true, virtualKey: w, autorepeat: true)
        let released = service.debugKeyTap(down: false, virtualKey: w)
        let extra = service.debugKeyTap(down: false, virtualKey: w)
        record(cat, "A blocked press, its repeat and its release are swallowed, and nothing more",
               pass: plain && repeated && released && !extra)
        record(cat, "Command with a blocked key is a shortcut and passes",
               pass: !service.debugKeyTap(down: true, virtualKey: w, flags: .maskCommand))
        if HotKeyCenter.shared.isShortcut(virtualKey: w, flags: .maskShift) {
            skip(cat, "Shift with a blocked key stays blocked unless it is a shortcut", detail: "Shift W is one of this Mac's shortcuts")
        } else {
            record(cat, "Shift with a blocked key stays blocked unless it is a shortcut",
                   pass: service.debugKeyTap(down: true, virtualKey: w, flags: .maskShift))
            _ = service.debugKeyTap(down: false, virtualKey: w)
        }
        if HotKeyCenter.shared.isShortcut(virtualKey: f13, flags: .maskShift) {
            // Already registered (the Emergency Stop on Shift F13): the pass
            // is tested on the live shortcut.
            record(cat, "A Shift-only shortcut on a blocked key passes",
                   pass: !service.debugKeyTap(down: true, virtualKey: f13, flags: .maskShift))
            _ = service.debugKeyTap(down: false, virtualKey: f13, flags: .maskShift)
        } else if let id = HotKeyCenter.shared.register(keyCode: UInt32(f13), modifiers: 1 << 9, action: {}) {
            let stop = service.debugKeyTap(down: true, virtualKey: f13, flags: .maskShift)
            _ = service.debugKeyTap(down: false, virtualKey: f13, flags: .maskShift)
            HotKeyCenter.shared.unregister(id)
            record(cat, "A Shift-only shortcut on a blocked key passes", pass: !stop)
        } else {
            record(cat, "A Shift-only shortcut on a blocked key passes", pass: false, detail: "Shift F13 could not be registered")
        }
        service.debugSetKeyBlocks([wCode], paused: true)
        record(cat, "A blocked key passes while blocking is paused", pass: !service.debugKeyTap(down: true, virtualKey: w))
        service.debugSetKeyBlocks([wCode], selfFront: true)
        record(cat, "A blocked key passes with InputConfig in front", pass: !service.debugKeyTap(down: true, virtualKey: w))
        // While the pointer passes, the pointer row's chord alone stays blocked.
        let pointerChord = [InputEvent(type: .extKey, index: 225)]
        service.setPointerOutputsPassing(true)
        service.debugSetKeyBlocks([wCode], chords: [wCode: [pointerChord, []]], paused: true, pointer: [wCode: [pointerChord]])
        record(cat, "A plain key passes beside a chord row on the same key that clicks",
               pass: !service.debugKeyTap(down: true, virtualKey: w))
        service.setPointerOutputsPassing(false)
        record(cat, "A pointer row's key passes while the pointer does not",
               pass: !service.debugKeyTap(down: true, virtualKey: w, flags: .maskShift))
        service.setPointerOutputsPassing(saved.passing)
        // Swallowed, then a press that passes while paused, then its release:
        // the release is the front app's, since the passed press forgot the swallow.
        service.debugClearSwallowed()
        service.debugSetKeyBlocks([wCode])
        let first = service.debugKeyTap(down: true, virtualKey: w)
        service.debugSetKeyBlocks([wCode], paused: true)
        _ = service.debugKeyTap(down: true, virtualKey: w)
        service.debugSetKeyBlocks([wCode])
        record(cat, "A passed press forgets an earlier swallow", pass: first && !service.debugKeyTap(down: false, virtualKey: w))
        // A chord on Command holds W back with Command, not with Command Option.
        let chord = [wCode: [[InputEvent.extKey(hidCode: 227)]]]
        service.debugSetKeyBlocks([wCode], chords: chord)
        let command: UInt64 = 0x0008 | CGEventFlags.maskCommand.rawValue
        record(cat, "A chord on Command holds its key back",
               pass: service.debugKeyTap(down: true, virtualKey: w, flags: CGEventFlags(rawValue: command)))
        _ = service.debugKeyTap(down: false, virtualKey: w)
        record(cat, "A press that adds Option to the chord's Command is the Mac's",
               pass: !service.debugKeyTap(down: true, virtualKey: w, flags: CGEventFlags(rawValue: command | CGEventFlags.maskAlternate.rawValue)))
        service.debugSetKeyBlocks([wCode], paused: true, running: [wCode: [[]]])
        record(cat, "A blocked key whose row runs while paused stays blocked", pass: service.debugKeyTap(down: true, virtualKey: w))
        _ = service.debugKeyTap(down: false, virtualKey: w)
        // Two rows on W: a plain one that does not run while paused, and a
        // Shift W one that does. Plain W passes, Shift W is swallowed.
        let shiftChord = [InputEvent.extKey(hidCode: 225)]
        service.debugSetKeyBlocks([wCode], chords: [wCode: [[], shiftChord]], paused: true, running: [wCode: [shiftChord]])
        let plainPaused = service.debugKeyTap(down: true, virtualKey: w)
        _ = service.debugKeyTap(down: false, virtualKey: w)
        let shiftPaused = service.debugKeyTap(down: true, virtualKey: w, flags: CGEventFlags(rawValue: 0x0002 | CGEventFlags.maskShift.rawValue))
        _ = service.debugKeyTap(down: false, virtualKey: w, flags: CGEventFlags(rawValue: 0x0002 | CGEventFlags.maskShift.rawValue))
        record(cat, "Paused, a plain press of a key kept only for its Shift row passes, and Shift plus the key is swallowed",
               pass: !plainPaused && shiftPaused)
        service.debugSetKeyBlocks([wCode, f5Code])
        ExternalInputDeviceService.debugGlobeHeld = true
        record(cat, "Globe with a blocked key passes", pass: !service.debugKeyTap(down: true, virtualKey: w))
        // fn is how a MacBook types F5 and Page Up: those keep their Block.
        let fnF5 = service.debugKeyTap(down: true, virtualKey: f5, flags: .maskSecondaryFn)
        _ = service.debugKeyTap(down: false, virtualKey: f5)
        record(cat, "F5 typed with fn held stays blocked", pass: fnF5)
        // A row that waits for fn itself keeps its key blocked with fn down.
        service.debugSetKeyBlocks([wCode], chords: [wCode: [[InputEvent.extKey(hidCode: KeyCodeMap.globeFnCode)]]])
        let fnW = service.debugKeyTap(down: true, virtualKey: w, flags: .maskSecondaryFn)
        _ = service.debugKeyTap(down: false, virtualKey: w)
        ExternalInputDeviceService.debugGlobeHeld = nil
        record(cat, "A row whose Second control is fn keeps its key blocked with fn held", pass: fnW)
        // Control held by a row of this app is no shortcut of the person's.
        let ownControl: UInt = 0x0001
        record(cat, "A Control this app holds does not make a blocked key a shortcut",
               pass: ExternalInputDeviceService.personShortcutFlags(CGEventFlags(rawValue: 0x0001 | CGEventFlags.maskControl.rawValue), own: ownControl).isEmpty
                   && ExternalInputDeviceService.personShortcutFlags(CGEventFlags(rawValue: 0x2001 | CGEventFlags.maskControl.rawValue), own: ownControl) == .maskControl
                   && ExternalInputDeviceService.personShortcutFlags(.maskControl, own: 0) == .maskControl)
        record(cat, "Caps Lock offers no Block", pass: !MappingEngine.keyCanBlock(57))
        // A Second control the tap cannot read: the key is not listed (KEY-5).
        var padChord = BindingModel(input: .extKey(hidCode: wCode), outputs: [OutputAction(type: .key, keyCode: 82)])
        padChord.blockOriginal = true
        padChord.setModifiers([.button(1)])
        let unreadable = Preset(name: "Chord", tag: "Tests", joysticks: [JoystickMapping(tag: "Mac", bindings: [padChord])])
        record(cat, "A key row whose Second control is a pad's button blocks nothing",
               pass: MappingEngine.blockedKeys(in: unreadable).isEmpty)
    }

    /// The key tap's decision on its own thread: one script of presses
    /// through debugKeyTap, made on main and then on the taps' thread while
    /// main waits, gives the same answers both times, and the ones the tap
    /// gave on main with the engine's answers as closures (1.9).
    private func runKeyTapThreadTests() {
        let cat = "Key Blocking"
        let service = ExternalInputDeviceService.shared
        let w = 13, wCode = 26
        let saved = service.debugKeyBlockState()
        defer {
            service.debugRestoreKeyBlocks(saved)
            ExternalInputDeviceService.debugGlobeHeld = nil
        }
        ExternalInputDeviceService.debugGlobeHeld = false
        let command = CGEventFlags(rawValue: 0x0008 | CGEventFlags.maskCommand.rawValue)
        // Command W taken by a shortcut of this Mac passes as one, press and release.
        let commandHeld = !HotKeyCenter.shared.isShortcut(virtualKey: w, flags: command)
        // A Second control only the engine can read: the A key.
        let a = InputEvent.extKey(hidCode: 4)
        let aKey = 0
        struct Step {
            let setup: (() -> Void)?
            /// The key pressed or let go: W unless the step says.
            var key = 13
            let down: Bool
            var flags: CGEventFlags = []
            var repeating = false
            let expect: Bool
        }
        let steps: [Step] = [
            Step(setup: { service.debugSetKeyBlocks([wCode]); service.setPointerOutputsPassing(false) }, down: true, expect: true),
            Step(setup: nil, down: true, repeating: true, expect: true),
            Step(setup: nil, down: false, expect: true),
            Step(setup: nil, down: false, expect: false),
            Step(setup: nil, down: true, flags: command, expect: false),
            Step(setup: nil, down: false, flags: command, expect: false),
            Step(setup: { service.debugSetKeyBlocks([wCode], paused: true) }, down: true, expect: false),
            Step(setup: nil, down: false, expect: false),
            Step(setup: { service.debugSetKeyBlocks([wCode], selfFront: true) }, down: true, expect: false),
            Step(setup: nil, down: false, expect: false),
            Step(setup: { service.debugSetKeyBlocks([wCode], paused: true, running: [wCode: [[]]]) }, down: true, expect: true),
            Step(setup: nil, down: false, expect: true),
            Step(setup: { service.debugSetKeyBlocks([wCode], chords: [wCode: [[InputEvent.extKey(hidCode: 227)]]]) },
                 down: true, flags: command, expect: commandHeld),
            Step(setup: nil, down: false, flags: command, expect: commandHeld),
            Step(setup: { service.debugSetKeyBlocks([wCode], chords: [wCode: [[a]]]) }, down: true, expect: false),
            Step(setup: nil, down: false, expect: false),
            Step(setup: { service.debugSetKeyBlocks([wCode], chords: [wCode: [[a]]], held: [a]) }, down: true, expect: true),
            Step(setup: nil, down: false, expect: true),
            // Paused with the pointer passing, the pointer row's chord holds
            // W back; once the pointer stops passing, plain W is the app's.
            Step(setup: {
                service.debugSetKeyBlocks([wCode], chords: [wCode: [[], [a]]], paused: true, pointer: [wCode: [[a]]], held: [a])
                service.setPointerOutputsPassing(true)
            }, down: true, expect: true),
            Step(setup: { service.setPointerOutputsPassing(false) }, down: false, expect: true),
            Step(setup: nil, down: true, expect: false),
            Step(setup: nil, down: false, expect: false),
            // A chord on A, with the engine still saying A is up (its answer
            // comes two main hops later): A going down through the tap holds
            // W back at once, with no main turn in between.
            Step(setup: { service.debugSetKeyBlocks([wCode], chords: [wCode: [[a]]]) }, key: aKey, down: true, expect: false),
            Step(setup: nil, down: true, expect: true),
            Step(setup: nil, down: false, expect: true),
            Step(setup: nil, key: aKey, down: false, expect: false),
            // A let go through the tap with the engine still saying held: W
            // right after it is the front app's again, not lost.
            Step(setup: { service.debugSetKeyBlocks([wCode], chords: [wCode: [[a]]], held: [a]) }, key: aKey, down: true, expect: false),
            Step(setup: nil, key: aKey, down: false, expect: false),
            Step(setup: nil, down: true, expect: false),
            Step(setup: nil, down: false, expect: false),
        ]
        let expected = steps.map(\.expect)
        /// The answers, or why the run stopped.
        func run(onTapThread: Bool) -> (answers: [Bool], failure: String?) {
            service.debugClearSwallowed()
            var answers: [Bool] = []
            for (i, step) in steps.enumerated() {
                step.setup?()
                guard onTapThread else {
                    answers.append(service.debugKeyTap(down: step.down, virtualKey: step.key, flags: step.flags, autorepeat: step.repeating))
                    continue
                }
                guard let r = service.debugKeyTapOnTapThread(down: step.down, virtualKey: step.key, flags: step.flags, autorepeat: step.repeating) else {
                    return (answers, "no answer within 1 s at step \(i + 1): the decision waited on main")
                }
                if r.onMain { return (answers, "step \(i + 1) ran on the main thread") }
                answers.append(r.swallowed)
            }
            return (answers, nil)
        }
        func mismatches(_ answers: [Bool]) -> String {
            let wrong = zip(answers, expected).enumerated().filter { $0.element.0 != $0.element.1 }.map { "\($0.offset + 1)" }
            return wrong.isEmpty ? "\(answers.count) answers" : "Wrong at steps \(wrong.joined(separator: ", "))"
        }
        let onMain = run(onTapThread: false)
        record(cat, "\(steps.count) key events give the same swallow decisions as the tap on main did",
               pass: onMain.failure == nil && onMain.answers == expected, detail: onMain.failure ?? mismatches(onMain.answers))
        let offMain = run(onTapThread: true)
        record(cat, "The same \(steps.count) on the taps' own thread, with main waiting, give the same decisions",
               pass: offMain.failure == nil && offMain.answers == expected, detail: offMain.failure ?? mismatches(offMain.answers))
    }

    /// False when a case did not finish and left the mouse lock held.
    @discardableResult
    private func runClickAndFlagTests() -> Bool {
        let cat = "Clicks and Modifiers"
        final class Caught: @unchecked Sendable {
            let lock = NSLock()
            var events: [(type: CGEventType, flags: CGEventFlags, at: CGPoint)] = []
            func take() -> [(type: CGEventType, flags: CGEventFlags, at: CGPoint)] {
                lock.lock(); defer { events = []; lock.unlock() }
                return events
            }
        }
        let caught = Caught()
        let sim = InputSimulator.shared
        let oldSink = InputSimulator.debugEventSink
        let oldCapture = TestCapture.active
        let spots = sim.debugSavedSpots
        InputSimulator.debugEventSink = { event in
            caught.lock.lock(); caught.events.append((event.type, event.flags, event.location)); caught.lock.unlock()
        }
        // The pointer is never warped, and the mouse's own buttons read up.
        TestCapture.active = true
        TestCapture.clear()
        InputSimulator.debugHardwareButtonsDown = false
        // A case that timed out left a thread holding the mouse lock: the
        // clean-up below takes it too, so it is skipped and the run goes on.
        var wedged = false
        defer {
            InputSimulator.debugPhysicalFlags = nil
            if !wedged {
                // Before the sink goes back: a button a failed case left down
                // would be let go on the real Mac, ending the person's drag.
                sim.inputModifierCodes = []
                sim.releaseAll()
                InputSimulator.debugEventSink = oldSink
                InputSimulator.debugHardwareButtonsDown = nil
                TestCapture.active = oldCapture
                sim.debugSavedSpots = spots
            } else {
                // A thread that only ran late goes on posting: the sink swallows
                // it, with the capture left on, for the rest of the session.
                // Back to the real sink, a late click or move reached the Mac.
                InputSimulator.debugEventSink = { _ in }
                info(cat, "Capture left on after a timed-out case", detail: "Events stay swallowed so a late thread cannot click or move the pointer; relaunch the app")
            }
        }
        // Off the main thread with a time limit, so a lock taken twice
        // fails this case instead of hanging the bench.
        func finishes(_ work: @escaping @Sendable () -> Void) -> Bool {
            let done = DispatchSemaphore(value: 0)
            Thread.detachNewThread { work(); done.signal() }
            return done.wait(timeout: .now() + 3) == .success
        }
        // Every kind of button, through the real down and up.
        for button in [0, 1, 2, 3] {
            let clicked = finishes {
                sim.mouseButtonDown(button, owner: "bench")
                sim.mouseButtonUp(button, owner: "bench")
            }
            let types = caught.take().map(\.type)
            record(cat, "A click on button \(button) goes down and up with no deadlock",
                   pass: clicked && types.count == 2, detail: "\(types.map(\.rawValue))")
            if !clicked { wedged = true; return false }
        }
        // The keyboard's modifiers ride on clicks.
        let left = (cmd: UInt64(0x0008), ctrl: UInt64(0x0001), alt: UInt64(0x0020), shift: UInt64(0x0002))
        InputSimulator.debugPhysicalFlags = left.cmd | left.ctrl | left.alt | CGEventFlags.maskAlphaShift.rawValue
        _ = finishes { sim.mouseButtonDown(0, owner: "bench"); sim.mouseButtonUp(0, owner: "bench") }
        let flags = caught.take().first?.flags ?? []
        record(cat, "Command, Control, Option and Caps Lock on the keyboard reach a click",
               pass: flags.isSuperset(of: [.maskCommand, .maskControl, .maskAlternate, .maskAlphaShift]), detail: "\(flags.rawValue)")
        InputSimulator.debugPhysicalFlags = left.shift
        record(cat, "Shift on the keyboard reaches a move and a scroll",
               pass: sim.debugMouseFlags(includingStandalone: false).contains(.maskShift))
        // A modifier the preset reads as an input stays off.
        sim.inputModifierCodes = [225]
        record(cat, "A modifier the preset reads as an input is left off",
               pass: !sim.debugMouseFlags(includingStandalone: true).contains(.maskShift))
        sim.inputModifierCodes = []
        // Just after this app moved it, the reading may still be its own.
        sim.debugNoteOwnModifierChange(225)
        record(cat, "A modifier this app just moved is not read from the keyboard for 0.3 s",
               pass: !sim.debugMouseFlags(includingStandalone: true).contains(.maskShift))
        InputSimulator.debugPhysicalFlags = 0
        // The pointer off the main thread, as the macro thread moves it.
        TestCapture.clear()
        let placed = finishes { for i in 0..<500 { sim.placePointer(atX: Double(i % 40), y: 5) } }
        let notes = TestCapture.log.filter { $0.hasPrefix("place ") }.count
        record(cat, "Five hundred pointer placements off the main thread finish",
               pass: placed && notes == 500 && caught.take().count == 500, detail: "\(notes) placed")
        if !placed { wedged = true; return false }
        // A row that jumps the pointer and clicks: the jump comes first.
        if let engine = MappingEngine.current {
            sim.savePointerSpot(1)
            var jump = OutputAction(type: .appAction)
            jump.appActionKind = .returnPointer
            let click = OutputAction(type: .mouseButton, mouseButtonIndex: 0)
            engine.debugFire([click, jump], press: true, owner: "bench")
            engine.debugFire([click], press: false, owner: "bench")
            let order = caught.take().map(\.type)
            let down = order.firstIndex(of: .leftMouseDown)
            let moved = order.firstIndex(of: .mouseMoved)
            record(cat, "A row that places the pointer and clicks places it first, with no drag",
                   pass: down != nil && moved != nil && moved! < down! && !order.contains(.leftMouseDragged),
                   detail: "\(order.map(\.rawValue))")
            // Locked from an unlisted app, a pointer row's click passes; the
            // unlock with the gate still up lets go of it (J-A).
            engine.debugSuspend(MappingEngine.unlistedAppReason)
            engine.debugSuspend("screen lock")
            engine.debugFire([click], press: true, owner: "0:bench")
            let pressed = caught.take().map(\.type).contains(.leftMouseDown)
            engine.debugResume("screen lock")
            let released = caught.take().map(\.type).contains(.leftMouseUp)
            engine.debugResume(MappingEngine.unlistedAppReason)
            record(cat, "Unlocking into an unlisted app lets go of a click a pointer row held at the lock screen",
                   pass: pressed && released && sim.debugHeldKeyCount == 0, detail: "pressed \(pressed), released \(released)")
        } else {
            skip(cat, "Pointer order and the unlock release", detail: "No engine")
        }
        return true
    }

    private func runShippedAndLimitTests() {
        let cat = "Shipped Presets and Limits"
        let shipped = ExamplePresets.showcaseMacrosTurbo
        var deleted = shipped
        for g in deleted.joysticks.indices {
            deleted.joysticks[g].bindings.removeAll { $0.input.type == .buttonSequence }
        }
        deleted.writtenByFormatVersion = Preset.currentFormatVersion
        BuiltInUpdate.markSeen([BuiltInUpdate.macrosTurbo19.id], on: &deleted)
        record(cat, "A copy that had the update, with an added row deleted, is the person's",
               pass: !PresetStore.matchesShipped(deleted, shipped, builtInFolder: nil)
                   && BuiltInUpdate.offers(for: deleted).isEmpty)
        // Through a real save and load, as a backup carries it (PER-1): every
        // save writes format 4, the marker is what decides.
        func roundTrip(_ p: Preset) -> Preset? {
            guard let data = try? JSONEncoder().encode(p) else { return nil }
            return try? JSONDecoder().decode(Preset.self, from: data)
        }
        var untouched18 = shipped
        for g in untouched18.joysticks.indices {
            untouched18.joysticks[g].bindings.removeAll { $0.input.type == .buttonSequence || ($0.input.type == .button && $0.input.index == 2) }
        }
        let saved18 = roundTrip(untouched18), savedDeleted = roundTrip(deleted)
        record(cat, "An untouched 1.8 copy saved by 1.9 still matches; one that had the update and lost a row does not",
               pass: saved18.map { PresetStore.matchesShipped($0, shipped, builtInFolder: nil) && $0.writtenByFormatVersion >= 4 } == true
                   && savedDeleted.map { !PresetStore.matchesShipped($0, shipped, builtInFolder: nil) && $0.seenUpdates == deleted.seenUpdates } == true)
        var old = deleted
        old.writtenByFormatVersion = 3
        // Built from the 1.8 rows: the shipped preset without the added rows.
        var before = shipped
        for g in before.joysticks.indices {
            before.joysticks[g].bindings.removeAll { $0.input.type == .buttonSequence || ($0.input.type == .button && $0.input.index == 2) }
        }
        before.writtenByFormatVersion = 3
        var applied = before
        _ = BuiltInUpdate.macrosTurbo19.apply(&applied)
        record(cat, "A file from before the row existed matches once the update is applied",
               pass: !BuiltInUpdate.macrosTurbo19.isApplied(before)
                   && PresetStore.matchesShipped(before, shipped, builtInFolder: nil)
                   && BuiltInUpdate.macrosTurbo19.isApplied(applied)
                   && PresetStore.matchesShipped(applied, shipped, builtInFolder: nil, exact: true))
        record(cat, "A copy with a changed row does not match",
               pass: { () -> Bool in
                   var changed = shipped
                   changed.joysticks[0].bindings[0].outputs = [OutputAction(type: .key, keyCode: 4)]
                   return !PresetStore.matchesShipped(changed, shipped, builtInFolder: nil)
               }())
        // Load keeps what 1.8 stored; only a damaged file meets the ceilings.
        func loaded(steps: Int, notes: Int) -> Preset? {
            var row = BindingModel(input: .button(0), outputs: [])
            row.macroSteps = Array(repeating: MacroStep(action: OutputAction(type: .key, keyCode: 4)), count: steps)
            var p = Preset(name: "Limits", tag: "Tests", joysticks: [JoystickMapping(tag: "Pad", bindings: [row])])
            p.notes = String(repeating: "n", count: notes)
            guard let data = try? JSONEncoder().encode(p) else { return nil }
            return try? JSONDecoder().decode(Preset.self, from: data)
        }
        record(cat, "A 250 step macro and a 6,000 character note load whole",
               pass: { () -> Bool in
                   guard let p = loaded(steps: 250, notes: 6_000) else { return false }
                   return p.joysticks[0].bindings[0].macroSteps?.count == 250 && p.notes.count == 6_000
               }())
        record(cat, "A 3,000 step macro is held to 2,000 on load",
               pass: loaded(steps: 3_000, notes: 0)?.joysticks[0].bindings[0].macroSteps?.count == 2_000)
        // The review says what a preset holds back from other apps.
        var row = BindingModel(input: .extKey(hidCode: 26), outputs: [OutputAction(type: .key, keyCode: 4)])
        row.blockOriginal = true
        let blocking = Preset(name: "Blocks", tag: "Tests", joysticks: [JoystickMapping(tag: "Mac", bindings: [row])])
        record(cat, "The import review names keys held back",
               pass: PresetStore.reviewLines(for: blocking).contains { $0.contains(KeyCodeMap.name(for: 26)) })
        // A sequence through Convert.
        let keys = Preset(name: "Keys", tag: "Tests", joysticks: [JoystickMapping(tag: "Mac", bindings: [
            BindingModel(input: .keySequence([26, 22]), outputs: [OutputAction(type: .key, keyCode: 44)])])])
        let moved = ControllerType.convert(preset: keys, from: .ps5, to: .xboxSeries)
        record(cat, "Convert leaves a key sequence alone",
               pass: moved.joysticks[0].bindings[0].input.sequenceSteps == [26, 22])
    }

    private func runHelpCoverageTests() {
        let cat = "Help Translations"
        var tables: [String: [String: String]] = [:]
        for lang in Bundle.main.localizations where lang != "Base" && lang != "en" {
            guard let table = HelpLocalizer.bundledTable("help-\(lang)") else { continue }
            tables[lang] = table
        }
        let languages = Self.shippedLanguages.subtracting(["en"])
        record(cat, "Every language has a table", pass: Set(tables.keys) == languages, detail: "\(tables.count) of \(languages.count)")
        // The build packs every table (Pack Text Resources); a plain .json
        // left in the bundle still reads, so only this case would see it.
        let folder = Bundle.main.url(forResource: "HelpTranslations", withExtension: nil)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder?.path ?? "")) ?? []
        let packed = files.filter { $0.hasSuffix(".json.lzfse") }
        record(cat, "Every help, preset and drawing table ships packed",
               pass: packed.count == files.count && packed.count == 3 * languages.count,
               detail: "\(packed.count) packed of \(files.count) files, \(3 * languages.count) wanted")
        let keySets = Set(tables.values.map { Set($0.keys) })
        record(cat, "Every table has the same keys", pass: keySets.count == 1, detail: "\(keySets.count) different sets")
        // Lowered as the owed list is paid; a prune shows up as a jump.
        let owed = 0
        let wanted = Set(HelpLocalizer.allStrings())
        let missing = wanted.subtracting(tables.values.first?.keys.map { $0 } ?? [])
        record(cat, "Help strings with no translation stay within the owed list",
               pass: missing.count <= owed, detail: "\(missing.count) of \(wanted.count)")
    }

    private func runScreenDisplayTests() {
        let cat = "Screen Watches"
        var pixel = ScreenPixelWatch()
        pixel.display = DisplayKey(vendor: 1, model: 2, serial: 3, name: "Bench gone")
        record(cat, "A color watch on a display that is gone reads nothing", pass: ScreenPixelService.screen(for: pixel) == nil)
        pixel.display = nil
        record(cat, "A color watch with no display reads the primary", pass: ScreenPixelService.screen(for: pixel) != nil)
        var text = ScreenTextWatch()
        text.display = DisplayKey(vendor: 1, model: 2, serial: 3, name: "Bench gone")
        record(cat, "A text watch on a display that is gone reads nothing", pass: ScreenTextService.screen(for: text) == nil)
    }

    private func runWatcherRuleTests() {
        let cat = "Automatic Switching"
        typealias W = ControllerConnectWatcher
        let now = Date()
        let soon = now.addingTimeInterval(2)
        let past = now.addingTimeInterval(-2)
        record(cat, "A pad published inside the install quiet is no arrival",
               pass: !W.isListening(now: now, quietUntil: soon, tourPad: false, restoreAlertUp: false))
        record(cat, "Nothing arrives under the Quick Tour or the crash alert",
               pass: !W.isListening(now: now, quietUntil: past, tourPad: true, restoreAlertUp: false)
                   && !W.isListening(now: now, quietUntil: past, tourPad: false, restoreAlertUp: true))
        record(cat, "A pad after the quiet is an arrival",
               pass: W.isListening(now: now, quietUntil: past, tourPad: false, restoreAlertUp: false))
        let ago = { (seconds: Double) in now.addingTimeInterval(-seconds) }
        record(cat, "A pad never seen leaving is no reconnect",
               pass: !W.isReconnect(now: now, departed: nil, connected: ago(10), handChosen: ago(5)))
        record(cat, "Back inside two minutes is a reconnect",
               pass: W.isReconnect(now: now, departed: ago(60), connected: ago(600), handChosen: nil))
        record(cat, "Back after two minutes with no hand choice is a fresh arrival",
               pass: !W.isReconnect(now: now, departed: ago(300), connected: ago(600), handChosen: nil))
        record(cat, "Back after an idle disconnect, a preset chosen since it connected, is a reconnect",
               pass: W.isReconnect(now: now, departed: ago(900), connected: ago(1800), handChosen: ago(1200)))
        record(cat, "A hand choice before the pad connected does not count",
               pass: !W.isReconnect(now: now, departed: ago(900), connected: ago(1200), handChosen: ago(1800)))
        let a = UUID(), b = UUID()
        record(cat, "An arrival during an app's switch waits",
               pass: W.arrivalAction(appHolds: true, reconnect: false, active: a, restored: nil) == .wait)
        record(cat, "A reconnect leaves a preset chosen since, and replaces the one brought back",
               pass: W.arrivalAction(appHolds: false, reconnect: true, active: a, restored: b) == .leave
                   && W.arrivalAction(appHolds: false, reconnect: true, active: a, restored: a) == .start
                   && W.arrivalAction(appHolds: false, reconnect: true, active: nil, restored: nil) == .start)
        record(cat, "A fresh arrival starts its preset",
               pass: W.arrivalAction(appHolds: false, reconnect: false, active: a, restored: nil) == .start)
        // The gate's overlay skip, on both entry points.
        let overlays = ["com.apple.loginwindow", "com.apple.SecurityAgent", "com.apple.ScreenSaver.Engine",
                        "com.apple.UserNotificationCenter", "com.apple.accessibility.universalAccessAuthWarn"]
        record(cat, "The lock screen and system prompts do not count for the gate",
               pass: overlays.allSatisfy { !MappingEngine.frontmostCountsForGate($0) } && FrontmostAppWatcher.systemOverlays.count == 5)
        record(cat, "An app, and nothing known in front, do count",
               pass: MappingEngine.frontmostCountsForGate("com.apple.Safari") && MappingEngine.frontmostCountsForGate(nil))
    }

    private func runLizardEdgeTests() {
        let cat = "Lizard Mode"
        guard let engine = MappingEngine.current else { return }
        var last: Bool?
        engine.debugLizardSink = { last = $0 }
        defer { engine.debugLizardSink = nil }
        let sleep = "sleep", lock = "screen lock", gate = "app not listed"
        func walk(_ steps: [(String, Bool)]) -> Bool? {
            last = nil
            for (reason, on) in steps { on ? engine.debugSuspend(reason) : engine.debugResume(reason) }
            return last
        }
        // After both orders the Mac is at the lock screen, pointer passing.
        record(cat, "Sleep then lock then wake leaves the pad's own mouse off",
               pass: walk([(sleep, true), (lock, true), (sleep, false)]) == true)
        _ = walk([(lock, false)])
        record(cat, "Lock then sleep then wake leaves the pad's own mouse off",
               pass: walk([(lock, true), (sleep, true), (sleep, false)]) == true)
        _ = walk([(lock, false)])
        record(cat, "Gate then lock then the gate lifting leaves the pad's own mouse off",
               pass: walk([(gate, true), (lock, true), (gate, false)]) == true)
        _ = walk([(lock, false)])
        record(cat, "Held back by the gate alone the pad's own mouse is on",
               pass: walk([(gate, true)]) == false)
        record(cat, "Siri's held back answer reads exactly the gate", pass: engine.isHeldByAppGate)
        _ = walk([(lock, true)])
        record(cat, "With the lock beside it the gate alone no longer explains it", pass: !engine.isHeldByAppGate)
        _ = walk([(lock, false), (gate, false)])
    }
    #endif

    private func runScrollStyleTests() async {
        let cat = "Scroll Direction and Smoothing"
        // The checks take the simulator's scroll path and its style for about
        // a second: a running preset's own scrolls went into the sink and
        // its style flipped under it, as with the MIDI loopback.
        if MappingEngine.current?.isRunning ?? false {
            skip(cat, "Scroll direction, smoothing and the app gate",
                 detail: "A preset is running; stop it and run the Test Bench again")
            return
        }
        final class Caught: @unchecked Sendable {
            let lock = NSLock()
            var events: [(x: Int32, y: Int32, lines: Bool)] = []
            func take() -> [(x: Int32, y: Int32, lines: Bool)] {
                lock.lock(); defer { events = []; lock.unlock() }
                return events
            }
        }
        let caught = Caught()
        let sim = InputSimulator.shared
        sim.setTestScrollSink { x, y, lines in
            caught.lock.lock(); caught.events.append((x, y, lines)); caught.lock.unlock()
        }
        defer {
            sim.setTestScrollSink(nil)
            if let engine = MappingEngine.current { engine.applyScrollStyle() }
            else { sim.setScrollStyle(reverseVertical: false, reverseHorizontal: false, glideMs: nil) }
        }

        sim.setScrollStyle(reverseVertical: true, reverseHorizontal: false, glideMs: nil)
        sim.scrollWheel(deltaX: 3, deltaY: 10)
        sim.scrollWheelStep(axis: .vertical, direction: .positive, lines: 2)
        sim.scrollWheelStep(axis: .horizontal, direction: .positive, lines: 1)
        let flipped = caught.take()
        record(cat, "Reverse up and down flips vertical scrolls and notches only",
               pass: flipped.count == 3 && flipped[0] == (3, -10, false) && flipped[1] == (0, -2, true) && flipped[2] == (1, 0, true),
               detail: flipped.map { "\($0.x),\($0.y)\($0.lines ? " lines" : "")" }.joined(separator: "; "))

        sim.setScrollStyle(reverseVertical: false, reverseHorizontal: true, glideMs: nil)
        sim.scrollWheel(deltaX: 4, deltaY: 5)
        let sideways = caught.take()
        record(cat, "Reverse left and right flips sideways scrolls only",
               pass: sideways.count == 1 && sideways[0] == (-4, 5, false))

        sim.setScrollStyle(reverseVertical: false, reverseHorizontal: false, glideMs: 150)
        sim.scrollWheel(deltaX: 0, deltaY: 120)
        let atOnce = caught.take()
        try? await Task.sleep(nanoseconds: 450_000_000)
        let glided = caught.take()
        let total = glided.reduce(0) { $0 + Int($1.y) }
        record(cat, "Smooth scrolling glides a scroll out, largest first, to the exact distance",
               pass: atOnce.isEmpty && glided.count >= 5 && total == 120 && glided.allSatisfy { !$0.lines }
                   && (glided.first?.y ?? 0) > (glided.last?.y ?? 0),
               detail: "\(glided.count) steps, \(total) px, first \(glided.first?.y ?? 0), last \(glided.last?.y ?? 0)")

        sim.scrollWheelStep(axis: .vertical, direction: .negative, lines: 1)
        try? await Task.sleep(nanoseconds: 450_000_000)
        let notch = caught.take()
        record(cat, "A wheel notch glides as pixels while smoothing is on",
               pass: !notch.isEmpty && notch.reduce(0) { $0 + Int($1.y) } == -40 && notch.allSatisfy { !$0.lines })

        #if DEBUG
        // Command held on its own, then a notch: a line notch, so the
        // modifier rides on it (SCR-1). The key goes to the sink, not the Mac.
        let keySink = InputSimulator.debugEventSink
        InputSimulator.debugEventSink = { _ in }
        InputSimulator.debugPhysicalFlags = 0
        sim.keyDown(227, owner: "bench")
        sim.scrollWheelStep(axis: .vertical, direction: .positive, lines: 1)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let modified = caught.take()
        let carried = sim.debugMouseFlags(includingStandalone: true).contains(.maskCommand)
        sim.keyUp(227, owner: "bench")
        record(cat, "A notch with a modifier held on its own stays a line notch, carrying it, while smoothing is on",
               pass: modified.count == 1 && modified[0].lines && carried,
               detail: modified.map { "\($0.y)\($0.lines ? " lines" : "")" }.joined(separator: "; ") + (carried ? ", Command" : ", no Command"))
        // The keyboard's own modifier (or one in a chord) counts the same.
        // Option, not the Command this app just let go, which the keyboard
        // reading skips for 0.3 s.
        InputSimulator.debugPhysicalFlags = 0x0020 | CGEventFlags.maskAlternate.rawValue
        sim.scrollWheelStep(axis: .vertical, direction: .positive, lines: 1)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let physical = caught.take()
        InputSimulator.debugPhysicalFlags = nil
        InputSimulator.debugEventSink = keySink
        record(cat, "A notch with Option held on the keyboard stays a line notch too",
               pass: physical.count == 1 && physical[0].lines, detail: "\(physical.count) events")
        #endif

        var gated = PresetAutomation()
        gated.autoActivateBundleIDs = ["com.example.Game"]
        let off = MappingEngine.appGateHolds(gated, frontmost: "com.apple.Safari")
        gated.onlyInListedApps = true
        record(cat, "Only in these apps holds the preset back in an unlisted app only",
               pass: !off && MappingEngine.appGateHolds(gated, frontmost: "com.apple.Safari")
                   && !MappingEngine.appGateHolds(gated, frontmost: "COM.EXAMPLE.GAME")
                   && !MappingEngine.appGateHolds(gated, frontmost: Bundle.main.bundleIdentifier)
                   && !MappingEngine.appGateHolds(gated, frontmost: nil))
        gated.autoActivateBundleIDs = nil
        record(cat, "Only in these apps with no apps listed holds nothing",
               pass: !MappingEngine.appGateHolds(gated, frontmost: "com.apple.Safari"))

        // A preset with no rows that only changes scrolling still starts;
        // one that only lists apps, or leaves out both wheel and trackpad,
        // has nothing to do.
        var scrollOnly = Preset(name: "Scroll only", tag: "Tests")
        let empty = scrollOnly.isRunnable
        scrollOnly.automation.onlyInListedApps = true
        scrollOnly.automation.autoActivateBundleIDs = ["com.example.Game"]
        let appsOnly = scrollOnly.isRunnable
        scrollOnly.automation.scrollReverseVertical = true
        let reversed = scrollOnly.isRunnable
        scrollOnly.automation.scrollReverseSkipsMouse = true
        let neither = scrollOnly.isRunnable
        scrollOnly.automation.scrollReverseVertical = nil
        scrollOnly.automation.smoothScrolling = true
        let smoothed = scrollOnly.isRunnable
        scrollOnly.automation.smoothScrolling = nil
        scrollOnly.automation.scrollMultiplier = 2
        let fasterAlone = scrollOnly.isRunnable
        scrollOnly.automation.scrollSpeedIncludesTrackpad = true
        let faster = scrollOnly.isRunnable
        record(cat, "A preset that only changes scrolling can start, one that only lists apps cannot",
               pass: !empty && !appsOnly && reversed && !neither && smoothed && !fasterAlone && faster
                   && !scrollOnly.hasMappings,
               detail: [empty, appsOnly, reversed, neither, smoothed, fasterAlone, faster].map { $0 ? "1" : "0" }.joined())

        // Turned off, as when the preset stops: the rest is not sent.
        sim.scrollWheel(deltaX: 0, deltaY: 500)
        sim.setScrollStyle(reverseVertical: false, reverseHorizontal: false, glideMs: nil)
        try? await Task.sleep(nanoseconds: 450_000_000)
        let stopped = caught.take()
        record(cat, "Stopping the preset drops a glide under way",
               pass: stopped.count <= 1 && stopped.reduce(0) { $0 + Int($1.y) } < 500,
               detail: "\(stopped.count) steps, \(stopped.reduce(0) { $0 + Int($1.y) }) of 500 px sent")

        #if DEBUG
        await runGlideOnPumpCases(cat)
        await runWheelShaperPassingCases(cat)
        #endif
    }

    #if DEBUG
    /// The smooth scroll glide is stepped by the pointer pump's tick while
    /// the pump runs and by its own timer otherwise. Whoever steps it, the
    /// same scroll must come out as the same steps, in the same order, to
    /// the same total; handovers lose and repeat nothing; the pump stays
    /// awake while pixels are owed and sleeps once they are not. Each step
    /// takes a fixed time step here, so the steps do not depend on how late
    /// a timer fires on a busy Mac. Called with no preset running (the
    /// caller skips otherwise), so the pump is off and is left off.
    private func runGlideOnPumpCases(_ cat: String) async {
        final class Steps: @unchecked Sendable {
            let lock = NSLock()
            var steps: [(x: Int32, y: Int32, queue: String)] = []
            func take() -> [(x: Int32, y: Int32, queue: String)] {
                lock.lock(); defer { steps = []; lock.unlock() }
                return steps
            }
        }
        let sim = InputSimulator.shared
        let pump = MouseMotionPump.shared
        guard !pump.debugIsRunning else {
            skip(cat, "Smooth scrolling glides the same with the pointer pump running and without it",
                 detail: "The pointer pump is running; stop the preset and run the Test Bench again")
            return
        }
        let steps = Steps()
        sim.setTestScrollSink { x, y, _ in
            let queue = String(cString: __dispatch_queue_get_label(nil))
            steps.lock.lock(); steps.steps.append((x, y, queue)); steps.lock.unlock()
        }
        InputSimulator.debugGlideStepSeconds = 1.0 / 120
        defer {
            InputSimulator.debugGlideStepSeconds = nil
            pump.stop()
        }
        sim.setScrollStyle(reverseVertical: false, reverseHorizontal: false, glideMs: 150)
        let pumpQueue = "com.inputconfig.mousepump", glideQueue = "InputConfig.SmoothScroll"
        func same(_ a: [(x: Int32, y: Int32, queue: String)], _ b: [(x: Int32, y: Int32, queue: String)]) -> Bool {
            guard a.count == b.count else { return false }
            for i in a.indices where a[i].x != b[i].x || a[i].y != b[i].y { return false }
            return true
        }
        func total(_ a: [(x: Int32, y: Int32, queue: String)]) -> (Int, Int) {
            var x = 0, y = 0
            for s in a { x += Int(s.x); y += Int(s.y) }
            return (x, y)
        }
        func onlyOn(_ a: [(x: Int32, y: Int32, queue: String)], _ q: String) -> Bool {
            for s in a where s.queue != q { return false }
            return true
        }
        func describe(_ a: [(x: Int32, y: Int32, queue: String)]) -> String {
            let t = total(a)
            return "\(a.count) steps, \(t.0),\(t.1) px"
        }

        // 1. No pump: the glide's own timer, as with no pointer preset.
        sim.scrollWheel(deltaX: 7, deltaY: 500)
        try? await Task.sleep(nanoseconds: 800_000_000)
        let alone = steps.take()
        record(cat, "With no pointer pump a glide keeps its own timer, to the exact distance",
               pass: !alone.isEmpty && total(alone) == (7, 500) && onlyOn(alone, glideQueue),
               detail: describe(alone))

        // 2. The pump running and awake (just started): its tick steps it.
        pump.start()
        sim.scrollWheel(deltaX: 7, deltaY: 500)
        try? await Task.sleep(nanoseconds: 800_000_000)
        let awake = steps.take()
        let sleptAfter = pump.debugIsSleeping
        record(cat, "With the pointer pump running its tick steps the glide: the same steps in the same order, no second timer",
               pass: same(alone, awake) && onlyOn(awake, pumpQueue) && sleptAfter,
               detail: describe(awake) + (sleptAfter ? ", pump asleep after" : ", pump still awake after"))

        // 3. The pump asleep: woken for the glide, kept awake while pixels
        // are owed though nothing moves, asleep again soon after.
        let asleepBefore = pump.debugIsSleeping
        sim.scrollWheel(deltaX: 7, deltaY: 500)
        try? await Task.sleep(nanoseconds: 120_000_000)
        let awakeMid = !pump.debugIsSleeping
        try? await Task.sleep(nanoseconds: 680_000_000)
        let woken = steps.take()
        let asleepAfter = pump.debugIsSleeping
        record(cat, "A sleeping pointer pump wakes for a glide, stays awake while it is owed and sleeps after",
               pass: asleepBefore && awakeMid && asleepAfter && same(alone, woken) && onlyOn(woken, pumpQueue),
               detail: describe(woken) + ", asleep before \(asleepBefore), awake mid \(awakeMid), asleep after \(asleepAfter)")

        // 4. The pump stops mid glide (a preset stops, the watchdog): the
        // glide's own timer finishes it, nothing lost or sent twice.
        sim.scrollWheel(deltaX: 7, deltaY: 500)
        try? await Task.sleep(nanoseconds: 60_000_000)
        pump.stop()
        try? await Task.sleep(nanoseconds: 800_000_000)
        let handed = steps.take()
        let firstTimer = handed.firstIndex { $0.queue == glideQueue } ?? handed.count
        let order = firstTimer > 0 && firstTimer < handed.count
            && onlyOn(Array(handed[..<firstTimer]), pumpQueue) && onlyOn(Array(handed[firstTimer...]), glideQueue)
        record(cat, "A pointer pump stopped mid glide hands it to the glide's timer, the same steps in the same order",
               pass: same(alone, handed) && order,
               detail: describe(handed) + ", \(firstTimer) on the pump")

        // 5. The pump's own stick scroll takes over a glide the timer was
        // stepping, and steps its own scroll in the same tick: every unit
        // the pump scrolled comes out, once, and the timer stops.
        sim.scrollWheel(deltaX: 0, deltaY: 300)
        try? await Task.sleep(nanoseconds: 30_000_000)
        pump.start()
        _ = pump.takeScrolledUnits()
        pump.setScrollVelocity(x: 0, y: 2000)
        try? await Task.sleep(nanoseconds: 800_000_000)
        let units = pump.takeScrolledUnits()
        let mixed = steps.take()
        let firstPump = mixed.firstIndex { $0.queue == pumpQueue } ?? mixed.count
        let takenOver = firstPump < mixed.count && onlyOn(Array(mixed[firstPump...]), pumpQueue)
        record(cat, "A stick scroll on the pointer pump takes over a glide under way and glides every unit it scrolled",
               pass: units > 0 && takenOver && total(mixed) == (0, 300 + units),
               detail: describe(mixed) + ", \(units) units from the pump, \(firstPump) steps on the timer first")
        pump.setScrollVelocity(x: 0, y: 0)
    }

    /// The wheel shaper's tap is off while the preset is held back (every
    /// scroll would pass untouched), and on again when it shapes; this app
    /// in front leaves it on since 1.10. Needs Accessibility for the tap; skipped without it.
    /// The speed asked for is 1.0000001, so the brief real tap changes no
    /// scroll anyone makes meanwhile.
    private func runWheelShaperPassingCases(_ cat: String) async {
        let shaper = MouseWheelShaper.shared
        let name = "The wheel shaper's tap is off while it would only pass scrolls, on while it shapes"
        let frontBefore = shaper.debugTapState.selfInFront
        defer {
            shaper.setSelfInFront(frontBefore)
            if let engine = MappingEngine.current { engine.applyScrollStyle() }
            else { shaper.configure(reverseVertical: false, reverseHorizontal: false, wheel: false, trackpad: false, smooth: false) }
        }
        shaper.setSelfInFront(false)
        func configure(passing: Bool) {
            shaper.configure(reverseVertical: false, reverseHorizontal: false, wheel: false, trackpad: false,
                             smooth: false, wheelSpeed: 1.0000001, passing: passing)
        }
        configure(passing: true)
        var waited = 0
        // Made on its own thread, on, then turned off as held back.
        while !(shaper.debugTapState.present && !shaper.debugTapState.enabled) && waited < 20 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            waited += 1
        }
        let held = shaper.debugTapState
        guard held.present else {
            skip(cat, name, detail: "No tap could be made (Accessibility off?)")
            return
        }
        configure(passing: false)
        let shaping = shaper.debugTapState
        shaper.setSelfInFront(true)
        let front = shaper.debugTapState
        shaper.setSelfInFront(false)
        let back = shaper.debugTapState
        configure(passing: true)
        let heldAgain = shaper.debugTapState
        func bits(_ s: (present: Bool, enabled: Bool, offOnPurpose: Bool, selfInFront: Bool)) -> String {
            (s.present ? "P" : "-") + (s.enabled ? "E" : "-") + (s.offOnPurpose ? "O" : "-")
        }
        // Since 1.10 InputConfig in front shapes too (a speed set in the
        // editor is felt at once), so the tap stays on then.
        record(cat, name,
               pass: !held.enabled && held.offOnPurpose && shaping.enabled && !shaping.offOnPurpose
                   && front.enabled && !front.offOnPurpose && back.enabled && !back.offOnPurpose
                   && heldAgain.present && !heldAgain.enabled && heldAgain.offOnPurpose,
               detail: [held, shaping, front, back, heldAgain].map(bits).joined(separator: " "))
    }
    #endif

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
        // Pads read from their own reports, and racing wheels: a working
        // F310 or Switch 2 pad read as nothing plugged in.
        let rawPads = RawHIDGamepadService.shared.connectedGamepads
        let wheels = MappingEngine.current?.controllerServiceForSettings.racingWheelSlots ?? [:]
        for pad in rawPads {
            info("Hardware Snapshot", "Detected: \(pad.displayName)", detail: "Read from its HID reports (\(pad.transport)).")
        }
        for (slot, wheel) in wheels.sorted(by: { $0.key < $1.key }) {
            info("Hardware Snapshot", "Detected: \(wheel.vendorName ?? "Racing wheel")", detail: "Racing wheel in slot \(slot).")
        }
        if controllers.isEmpty {
            let others = !rawPads.isEmpty || !wheels.isEmpty || SteamControllerService.shared.isConnected
            info("Hardware Snapshot",
                 "Game controllers (GCController framework)",
                 detail: "0 controllers connected through Apple's GameController framework (PS5 DualSense, DualSense Edge, DualShock 4, Xbox, Switch Pro, Joy-Cons, 8BitDo in Apple mode, Stadia, any MFi gamepad)."
                    + (others ? " The pads listed here are read another way." : " Plug or pair one in and re-run."))
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
            let received = keyboardSeenBeforeRun
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

// MARK: - Performance cases (perf build only)

#if DEBUG
/// Main-thread stall sampler: a 1 ms timer in the common modes cannot fire
/// while main is busy, so the gap between two fires is the stall. The
/// selectbench hook's sampler (ContentView), as a type.
@MainActor
final class MainStallSampler {
    private var timer: Timer?
    private var last = 0.0
    /// Longest gap, seconds.
    private(set) var worst = 0.0
    /// Sum of the gaps over 8 ms, seconds.
    private(set) var busy = 0.0
    func start() {
        stop()
        last = CACurrentMediaTime(); worst = 0; busy = 0
        let t = Timer(timeInterval: 0.001, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    private func tick() {
        let now = CACurrentMediaTime(), gap = now - last
        last = now
        if gap > worst { worst = gap }
        if gap > 0.008 { busy += gap }
    }
    func stop() { timer?.invalidate(); timer = nil }
}

/// Memory as the bench reads it: resident (mach_task_basic_info, as
/// SystemStatsService reads it) and the physical footprint (task_vm_info,
/// Activity Monitor's Memory column), which file cache and shared pages move
/// far less. The footprint is the gated number.
enum ProcessMemory {
    static func read() -> (resident: UInt64, footprint: UInt64) {
        var basic = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr1 = withUnsafeMutablePointer(to: &basic) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        var vm = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr2 = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
            }
        }
        return (kr1 == KERN_SUCCESS ? UInt64(basic.resident_size) : 0,
                kr2 == KERN_SUCCESS ? UInt64(vm.phys_footprint) : 0)
    }
    /// Live malloc blocks across all zones, a net growth check that costs nothing.
    static func liveBlocks() -> Int {
        var st = malloc_statistics_t()
        malloc_zone_statistics(nil, &st)
        return Int(st.blocks_in_use)
    }
}

/// Counts main-thread mallocs through libmalloc's logger slot, the hook
/// MallocStackLogging uses (type bit 2 is an allocation; realloc sets it
/// too). Installed for one measurement and removed. Refuses to replace a
/// live logger (MallocStackLogging, Instruments), and then gives no number.
enum MainThreadMallocCounter {
    typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
    /// Written by the hook on the main thread only, read on main after it is removed.
    nonisolated(unsafe) static var count: UInt64 = 0
    private static var slot: UnsafeMutablePointer<Logger?>? {
        // RTLD_DEFAULT, which Swift does not import.
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger")?.assumingMemoryBound(to: Optional<Logger>.self)
    }
    /// Main-thread mallocs made inside `body`, or nil when the slot was taken.
    static func measure(_ body: () -> Void) -> UInt64? {
        guard let slot, slot.pointee == nil else { body(); return nil }
        let hook: Logger = { type, _, _, _, _, _ in
            if type & 2 != 0, pthread_main_np() != 0 { MainThreadMallocCounter.count &+= 1 }
        }
        count = 0
        slot.pointee = hook
        body()
        slot.pointee = nil
        return count
    }
}

/// Whether the Mac is quiet enough for a number to count: a 1-minute load
/// under half the cores and no thermal pressure. A failing line on a loaded
/// Mac reads NOISY, not FAIL.
enum PerfHost {
    static var cores: Int { ProcessInfo.processInfo.activeProcessorCount }
    static var loadAverage1: Double { var l = [0.0, 0.0, 0.0]; getloadavg(&l, 3); return l[0] }
    static var thermal: ProcessInfo.ThermalState { ProcessInfo.processInfo.thermalState }
    static var quiet: Bool { loadAverage1 < Double(cores) / 2 && thermal == .nominal }
    static func line(_ when: String) -> String {
        "PERF host.\(when) cores=\(cores) loadavg1=\(String(format: "%.1f", loadAverage1)) thermal=\(thermal.rawValue) quiet=\(quiet ? "yes" : "no")"
    }
}

/// What `inputconfig.debug.perfbench` runs.
struct PerfOptions {
    /// "switch", "tick", "save", "launch", "keystroke", "viz", "memory", or "all".
    var cases: Set<String> = ["all"]
    /// Laps per case; lap 1 warms caches and is never counted.
    var runs = 5
    /// The synthetic pad is on (the script posts inputconfig.debug.fakecontroller first).
    var pad = false
    func wants(_ c: String) -> Bool { cases.contains("all") || cases.contains(c) }
}

/// Budgets in the units of the PERF lines. A measured one is its baseline
/// times `allowance` and only ratchets down: after a gain lands and three
/// quiet runs agree, the baseline drops to the new median in the same
/// change. Raising one needs a stated reason. The others
/// are hard ceilings until they have a baseline.
enum PerfBudget {
    /// Repeat noise on a quiet Mac is about 8 percent for the worst stall and
    /// 12 for the busy sum; 15 percent clears it and still catches a 20
    /// percent regression.
    static let allowance = 1.15
    /// Median over presets of each preset's worst main-thread stall per
    /// switch, as first measured:
    /// 109 ms idle, 156 ms with the synthetic pad. Budgets 125.4 and 179.4.
    static let switchIdleBaseMs = 109.0
    static let switchPadBaseMs = 156.0
    /// The 1.9 goal, printed as goal=, never gated.
    static let switchGoalMs = 33.0
    /// 24 percent of a 120 Hz frame for 300 rows.
    static let tickMicrosPerPoll = 2000.0
    /// 300 rows should not allocate per row.
    static let tickMallocsPerPoll = 24.0
    static let saveEncodeMs = 8.0
    static let launchToSidebarMs = 900.0
    /// Two 60 Hz frames.
    static let keystrokeStallMs = 30.0
    /// reload(with:) of a 300-row draft after the editor's 300 ms pause.
    static let keystrokeReloadMs = 60.0
    /// Busy main per second with the synthetic pad sweeping on screen.
    static let vizBusyMsPerSecond = 160.0
    static let vizWorstMs = 25.0
    /// Footprint growth over a second tour of every preset.
    static let memoryTourMb = 20.0
}

extension TestBenchService {
    private static let perfCategory = "Performance"
    /// The PERF lines for perfbench.txt, built as the cases record.
    private static var perfLines: [String] = []
    private static var perfStartQuiet = true

    /// The headless performance report: one PERF line per case, the host
    /// before and after.
    var perfReport: String { Self.perfLines.joined(separator: "\n") + "\n" }

    /// The performance run, not part of runAll(): these cases need the
    /// optimized perf build and a quiet Mac, and take
    /// a few minutes. The first number after the name is the gated one.
    func runPerformance(_ o: PerfOptions) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        results.removeAll { $0.category == Self.perfCategory }
        Self.perfStartQuiet = PerfHost.quiet
        Self.perfLines = [PerfHost.line("start")]
        if o.wants("launch") { runLaunchBudget() }
        if o.wants("save") { runSaveBudget(o) }
        if o.wants("tick") { await runEngineTickBudget(o) }
        if o.wants("switch") { await runPresetSwitchBudget(o) }
        if o.wants("viz") { await runVisualizerTickBudget(o) }
        if o.wants("keystroke") { await runEditorKeystrokeBudget(o) }
        // Last: it switches presets twice over.
        if o.wants("memory") { await runMemoryTourBudget(o) }
        Self.perfLines.append(PerfHost.line("end"))
    }

    private func perfLine(_ name: String, gated: (key: String, value: Double), budget: Double, pass: Bool,
                          extra: String, runs: Int) {
        let quiet = Self.perfStartQuiet && PerfHost.quiet
        let status = pass ? "PASS" : (quiet ? "FAIL" : "NOISY")
        let line = "PERF \(name) \(gated.key)=\(Self.perfFmt(gated.value)) \(extra) budget=\(Self.perfFmt(budget)) runs=\(runs) \(status)"
        Self.perfLines.append(line)
        record(Self.perfCategory, name, pass: pass || !quiet, detail: line)
    }

    private func perfSkip(_ name: String, _ why: String) {
        Self.perfLines.append("PERF \(name) SKIP \(why)")
        skip(Self.perfCategory, name, detail: why)
    }

    private static func perfFmt(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
    private static func median(_ v: [Double]) -> Double {
        let s = v.sorted()
        return s.isEmpty ? 0 : s[s.count / 2]
    }
    private static func percentile(_ v: [Double], _ p: Double) -> Double {
        let s = v.sorted()
        return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * p))]
    }

    /// The main window is up: the selection hooks live on its content, so a
    /// closed window would switch nothing and pass.
    private var perfWindowUp: Bool { MenuBarController.mainWindow?.isVisible == true }

    /// 300 rows over three groups, in the mix the shipped presets use: 180
    /// button-to-key (18 with turbo, 18 with a held control), 60 stick-to-
    /// pointer, 30 stick-to-key with a deadzone and a curve, 30 three-step
    /// button sequences. Never saved except by the keystroke case.
    static func perfBenchPreset(rows: Int = 300) -> Preset {
        var groups: [JoystickMapping] = []
        for g in 0..<3 {
            var list: [BindingModel] = []
            for i in 0..<(rows / 3) {
                let kind = i % 10
                switch kind {
                case 0...5:
                    var b = BindingModel(input: .button(i % 16), outputs: [OutputAction(type: .key, keyCode: 4 + (i % 26))])
                    if kind == 0 { b.turboEnabled = true; b.turboRate = 10 }
                    if kind == 1 { b.modifierInput = .button(15 - (i % 16)) }
                    list.append(b)
                case 6, 7:
                    let a = OutputAction(type: .mouseMotion, mouseAxis: i % 4 < 2 ? .horizontal : .vertical,
                                         mouseDirection: kind == 6 ? .positive : .negative, speed: 8)
                    var b = BindingModel(input: .axis(i % 4, direction: kind == 6 ? .positive : .negative), outputs: [a])
                    b.deadzone = 0.2
                    b.variableSensitivity = true
                    list.append(b)
                case 8:
                    var b = BindingModel(input: .axis(i % 6, direction: .positive), outputs: [OutputAction(type: .key, keyCode: 30 + (i % 10))])
                    b.deadzone = 0.3
                    b.sensitivityCurve = .exponential
                    list.append(b)
                default:
                    list.append(BindingModel(input: .buttonSequence([i % 16, (i + 1) % 16, (i + 2) % 16]),
                                             outputs: [OutputAction(type: .key, keyCode: 44)]))
                }
            }
            groups.append(JoystickMapping(tag: "Group \(g + 1)", bindings: list))
        }
        return Preset(name: "Perf 300", tag: "Bench", joysticks: groups)
    }

    // MARK: Launch

    /// Process start to the sidebar's first appear, from tmp/launch.txt
    /// (LaunchClock). The script relaunches N times and writes the median
    /// there before posting perfbench; posted by hand, it is this launch.
    private func runLaunchBudget() {
        guard LaunchClock.sidebarMs > 0 else { perfSkip("launch", "this launch has not shown the sidebar"); return }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("launch.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            perfSkip("launch", "no launch.txt"); return
        }
        func field(_ k: String) -> Double? {
            text.split(whereSeparator: { $0 == " " || $0 == "\n" }).first { $0.hasPrefix(k + "=") }
                .flatMap { Double($0.dropFirst(k.count + 1)) }
        }
        let sidebar = field("to_sidebar_ms") ?? 0, finish = field("to_didfinish_ms") ?? 0
        let samples = Int(field("samples") ?? 1)
        perfLine("launch", gated: ("to_sidebar_ms", sidebar), budget: PerfBudget.launchToSidebarMs,
                 pass: sidebar > 0 && sidebar <= PerfBudget.launchToSidebarMs,
                 extra: "to_didfinish_ms=\(Self.perfFmt(finish)) this_launch_ms=\(Int(LaunchClock.sidebarMs)) samples=\(samples)",
                 runs: samples)
    }

    // MARK: Save

    /// JSONEncoder().encode of the 300-row preset, as savePresetToDisk runs
    /// it on the io queue; the custom encode(to:) paths are what can regress.
    /// The first encode is discarded; the byte count is on the line so a
    /// format change that doubles the file shows.
    private func runSaveBudget(_ o: PerfOptions) {
        let preset = Self.perfBenchPreset()
        var ms: [Double] = [], bytes = 0
        for i in 0..<max(3, o.runs * 2 - 1) {
            let s = CACurrentMediaTime()
            let data = try? JSONEncoder().encode(preset)
            let took = (CACurrentMediaTime() - s) * 1000
            bytes = data?.count ?? 0
            if i > 0 { ms.append(took) }
        }
        let data = try? JSONEncoder().encode(preset)
        let s = CACurrentMediaTime()
        let back = data.flatMap { try? JSONDecoder().decode(Preset.self, from: $0) }
        let decodeMs = (CACurrentMediaTime() - s) * 1000
        let rows = back?.joysticks.reduce(0) { $0 + $1.bindings.count } ?? 0
        let encode = Self.median(ms)
        perfLine("save.300", gated: ("encode_ms", encode), budget: PerfBudget.saveEncodeMs,
                 pass: encode <= PerfBudget.saveEncodeMs && rows == 300,
                 extra: "max=\(Self.perfFmt(ms.max() ?? 0)) bytes=\(bytes) decode_ms=\(Self.perfFmt(decodeMs)) rows_back=\(rows)",
                 runs: ms.count)
    }

    // MARK: Engine tick

    /// 1,000 debugPollOnce on the 300-row preset with three scripted pads
    /// moving every poll (sticks on sin and cos, a button every 7th poll, a
    /// hat every 13th), so deadzones, curves, turbo, held controls and
    /// sequences all run. Synchronous on main with the engine's timer
    /// stopped, so nothing interleaves. Outputs go to the event sink and
    /// TestCapture, so no key or pointer move reaches the Mac. The frames are
    /// built before the clock starts, so the time and the mallocs are the
    /// engine's alone. Mallocs come from one more batch, counted separately,
    /// since the logger slows malloc.
    private func runEngineTickBudget(_ o: PerfOptions) async {
        let name = "tick.300"
        guard let engine = MappingEngine.current else { perfSkip(name, "no engine"); return }
        guard !engine.isRunning else { perfSkip(name, "a preset is running; stop it first"); return }
        let batches = max(2, o.runs), perBatch = 1000 / batches
        func frame(_ n: Int) -> [Int: ControllerState] {
            var st = ControllerState()
            let t = Double(n) / 60
            st.axes[0] = Float(cos(t * 2.1)) * 0.93; st.axes[1] = Float(sin(t * 2.1)) * 0.93
            st.axes[2] = Float(cos(t * 1.6)) * 0.72; st.axes[3] = Float(sin(t * 1.6)) * 0.72
            st.axes[4] = Float((sin(t * 1.15) + 1) / 2); st.axes[5] = Float((cos(t * 0.95) + 1) / 2)
            st.buttons[n % 16] = (n / 7) % 2 == 0 ? 1 : 0
            st.hats[0] = (n / 13) % 2 == 0 ? (x: 1, y: 0) : (x: 0, y: 0)
            return [0: st, 1: st, 2: st]
        }
        let frames = (0..<(batches + 1) * perBatch).map(frame)
        let sim = InputSimulator.shared
        let oldSink = InputSimulator.debugEventSink
        let oldCapture = TestCapture.active
        InputSimulator.debugEventSink = { _ in }
        TestCapture.active = true
        TestCapture.clear()
        GameControllerService.debugScriptedStates = [:]
        engine.start(with: Self.perfBenchPreset())
        engine.debugStopPollTimer()
        var perPoll: [Double] = [], worstPoll = 0.0
        for batch in 0..<batches {
            var sum = 0.0
            for n in 0..<perBatch {
                GameControllerService.debugScriptedStates = frames[batch * perBatch + n]
                let s = CACurrentMediaTime()
                engine.debugPollOnce()
                let took = CACurrentMediaTime() - s
                sum += took
                if batch > 0 { worstPoll = max(worstPoll, took) }
            }
            // Batch 0 warms the slot map and the row caches.
            if batch > 0 { perPoll.append(sum / Double(perBatch) * 1_000_000) }
        }
        let counted = MainThreadMallocCounter.measure {
            for n in 0..<perBatch {
                GameControllerService.debugScriptedStates = frames[batches * perBatch + n]
                engine.debugPollOnce()
            }
        }
        engine.stop()
        GameControllerService.debugScriptedStates = [:]
        // The pointer pump and turbo stop with the engine; anything already
        // on its way lands in the sink, not on the Mac.
        try? await Task.sleep(for: .milliseconds(200))
        sim.releaseAll()
        InputSimulator.debugEventSink = oldSink
        TestCapture.active = oldCapture
        TestCapture.clear()
        let us = Self.median(perPoll)
        let mallocs = counted.map { Double($0) / Double(perBatch) }
        let pass = us <= PerfBudget.tickMicrosPerPoll && (mallocs ?? 0) <= PerfBudget.tickMallocsPerPoll
        perfLine(name, gated: ("us_per_poll", us), budget: PerfBudget.tickMicrosPerPoll, pass: pass,
                 extra: "max_us=\(Self.perfFmt(worstPoll * 1_000_000)) mallocs_per_poll=\(mallocs.map { Self.perfFmt($0) } ?? "n/a") budget_mallocs=\(Self.perfFmt(PerfBudget.tickMallocsPerPoll)) polls=\(batches * perBatch) rows=300",
                 runs: batches - 1)
    }

    // MARK: Preset switch

    /// Every preset in sidebar order, selected by id, main sampled for 400 ms
    /// after each, as the selectbench hook does. Per preset the median over
    /// laps 2 to N; gated is the median over presets, the number
    /// the baseline was taken with.
    private func runPresetSwitchBudget(_ o: PerfOptions) async {
        let name = o.pad ? "switch.pad" : "switch.idle"
        guard let store = AppState.current?.presetStore else { perfSkip(name, "no AppState"); return }
        guard perfWindowUp else { perfSkip(name, "the main window is closed"); return }
        let presets = store.presetsInSidebarOrder
        guard presets.count > 1 else { perfSkip(name, "fewer than two presets"); return }
        let base = o.pad ? PerfBudget.switchPadBaseMs : PerfBudget.switchIdleBaseMs
        let budget = base * PerfBudget.allowance
        let laps = max(2, o.runs)
        var worstBy: [UUID: [Double]] = [:], busyBy: [UUID: [Double]] = [:]
        let sampler = MainStallSampler()
        for lap in 1...laps {
            for p in presets {
                sampler.start()
                NotificationCenter.default.post(name: .init("inputconfig.debug.selectid"), object: p.id.uuidString)
                try? await Task.sleep(for: .seconds(0.4))
                sampler.stop()
                // Lap 1 fills the drawing's caches, the hook's cold lap.
                guard lap > 1 else { continue }
                worstBy[p.id, default: []].append(sampler.worst * 1000)
                busyBy[p.id, default: []].append(sampler.busy * 1000)
            }
        }
        let worst = presets.map { Self.median(worstBy[$0.id] ?? []) }
        let busy = presets.map { Self.median(busyBy[$0.id] ?? []) }
        let slowest = zip(presets, worst).max { $0.1 < $1.1 }
        let gated = Self.median(worst)
        perfLine(name, gated: ("median_ms", gated), budget: budget, pass: gated <= budget,
                 extra: "p90=\(Self.perfFmt(Self.percentile(worst, 0.9))) max=\(Self.perfFmt(worst.max() ?? 0)) busy_median_ms=\(Self.perfFmt(Self.median(busy))) base=\(Self.perfFmt(base)) goal=\(Self.perfFmt(PerfBudget.switchGoalMs)) presets=\(presets.count) slowest=\"\(slowest?.0.name ?? "")\" slowest_ms=\(Self.perfFmt(slowest?.1 ?? 0))",
                 runs: laps - 1)
    }

    // MARK: Visualizer tick

    /// The synthetic pad sweeping (its sticks move on CACurrentMediaTime, so
    /// the visualizer's signature changes every tick) under a preset with a
    /// controller group, main sampled for 3 s per lap. Gated: busy ms per
    /// second (gaps over 8 ms); work under 8 ms a tick reads 0 here, so
    /// pair it with Time Profiler. The visualizer pauses while the app is
    /// not in front, so this case needs the app active (the script's
    /// `front` word) and skips otherwise.
    private func runVisualizerTickBudget(_ o: PerfOptions) async {
        let name = "viz.pad"
        guard o.pad else { perfSkip(name, "needs the synthetic pad (pad)"); return }
        guard let store = AppState.current?.presetStore else { perfSkip(name, "no AppState"); return }
        guard perfWindowUp else { perfSkip(name, "the main window is closed"); return }
        guard NSApp.isActive else { perfSkip(name, "the app is not in front, so the visualizer is paused (run with front)"); return }
        let controllerTypes: Set<InputType> = [.button, .axis, .hat]
        guard let p = store.presetsInSidebarOrder.first(where: { preset in
            preset.joysticks.contains { g in
                g.inputKind == .controller || (g.inputKind == .auto && g.bindings.contains { controllerTypes.contains($0.input.type) })
            }
        }) else { perfSkip(name, "no preset with a controller group"); return }
        NotificationCenter.default.post(name: .init("inputconfig.debug.selectid"), object: p.id.uuidString)
        // The switch itself is not this case.
        try? await Task.sleep(for: .seconds(1.0))
        var busy: [Double] = [], worst: [Double] = []
        let sampler = MainStallSampler()
        let laps = max(2, o.runs)
        for lap in 1...laps {
            sampler.start()
            try? await Task.sleep(for: .seconds(3))
            sampler.stop()
            if lap > 1 { busy.append(sampler.busy * 1000 / 3); worst.append(sampler.worst * 1000) }
        }
        let b = Self.median(busy), w = Self.median(worst)
        perfLine(name, gated: ("busy_ms_per_s", b), budget: PerfBudget.vizBusyMsPerSecond,
                 pass: b <= PerfBudget.vizBusyMsPerSecond && w <= PerfBudget.vizWorstMs,
                 extra: "worst_ms=\(Self.perfFmt(w)) budget_worst=\(Self.perfFmt(PerfBudget.vizWorstMs)) seconds=3 preset=\"\(p.name)\"",
                 runs: laps - 1)
    }

    // MARK: Editor keystroke

    /// One note edit in an open 300-row editor, the preset running: the
    /// worst main stall in the 250 ms after it (SwiftUI on the row list plus
    /// recordHistory; the editor's 300 ms pause has not ended), and the time
    /// from the edit to the engine's reload landing (the activePreset
    /// publish) less that 300 ms pause. A note edit keeps runtimeShape, so
    /// the reload takes the fast path. The preset is saved for the case and
    /// deleted for good after it, Trash and versions included.
    private func runEditorKeystrokeBudget(_ o: PerfOptions) async {
        let name = "keystroke.300"
        guard let store = AppState.current?.presetStore, let engine = MappingEngine.current else { perfSkip(name, "no AppState"); return }
        guard store.activePresetId == nil, !engine.isRunning else { perfSkip(name, "a preset is running; stop it first"); return }
        guard perfWindowUp, OpenEditor.current == nil else { perfSkip(name, "the main window is closed or an editor is open"); return }
        var preset = Self.perfBenchPreset()
        preset.name = "Perf 300 (bench, deleted after)"
        store.savePreset(preset, skipSnapshot: true)
        let saved = store.presets.first { $0.id == preset.id } ?? preset
        let sim = InputSimulator.shared
        let oldSink = InputSimulator.debugEventSink
        let oldCapture = TestCapture.active
        InputSimulator.debugEventSink = { _ in }
        TestCapture.active = true
        MenuBarController.activate(saved, store: store, engine: engine, background: true, quietPointerWarning: true)
        NotificationCenter.default.post(name: .init("inputconfig.debug.selectid"), object: saved.id.uuidString)
        try? await Task.sleep(for: .seconds(0.5))
        // No name: the edit hook opens the selected preset.
        NotificationCenter.default.post(name: .init("inputconfig.debug.edit"), object: nil)
        for _ in 0..<30 where OpenEditor.current?.presetID != saved.id { try? await Task.sleep(for: .milliseconds(100)) }
        let opened = OpenEditor.current?.presetID == saved.id && engine.isRunning
        var stalls: [Double] = [], reloads: [Double] = []
        let laps = max(2, o.runs)
        if opened {
            // The editor's first layout and its live hooks settle.
            try? await Task.sleep(for: .seconds(1.5))
            final class Stamp { var at = 0.0 }
            let sampler = MainStallSampler()
            for lap in 1...laps {
                let stamp = Stamp()
                let sub = engine.$activePreset.dropFirst().sink { _ in if stamp.at == 0 { stamp.at = CACurrentMediaTime() } }
                let posted = CACurrentMediaTime()
                sampler.start()
                NotificationCenter.default.post(name: .init("inputconfig.debug.editnote"), object: "1 \(lap * 7 % 100) note \(lap)")
                try? await Task.sleep(for: .seconds(0.25))
                // Before the 300 ms pause ends: the stall is the keystroke's alone.
                sampler.stop()
                try? await Task.sleep(for: .seconds(0.45))
                sub.cancel()
                guard lap > 1 else { continue }
                stalls.append(sampler.worst * 1000)
                if stamp.at > 0 { reloads.append((stamp.at - posted) * 1000 - 300) }
            }
        }
        NotificationCenter.default.post(name: .init("inputconfig.debug.closesheets"), object: nil)
        try? await Task.sleep(for: .seconds(0.5))
        if engine.isRunning { MenuBarController.deactivate(store: store, engine: engine) }
        try? await Task.sleep(for: .milliseconds(200))
        sim.releaseAll()
        InputSimulator.debugEventSink = oldSink
        TestCapture.active = oldCapture
        if let p = store.presets.first(where: { $0.id == saved.id }) { store.deletePreset(p) }
        if let entry = store.recentlyDeleted.first(where: { $0.preset.id == saved.id }) { store.permanentlyDelete(entry) }
        guard opened else { perfSkip(name, "the editor did not open on the bench preset, or it did not start"); return }
        let stall = Self.median(stalls), reload = reloads.isEmpty ? -1 : Self.median(reloads)
        perfLine(name, gated: ("stall_ms", stall), budget: PerfBudget.keystrokeStallMs,
                 pass: stall <= PerfBudget.keystrokeStallMs && reload >= 0 && reload <= PerfBudget.keystrokeReloadMs,
                 extra: "reload_ms=\(reload < 0 ? "none" : Self.perfFmt(reload)) budget_reload=\(Self.perfFmt(PerfBudget.keystrokeReloadMs)) stall_max=\(Self.perfFmt(stalls.max() ?? 0)) rows=300",
                 runs: laps - 1)
    }

    // MARK: Memory

    /// Footprint before, after one tour of every preset (caches fill), and
    /// after a second (a cache stops growing, a leak does not). Gated: the
    /// second tour's footprint growth. Resident and live malloc blocks are on
    /// the line; thousands of blocks kept with a flat footprint say small
    /// objects are kept per switch (an observer, a closure).
    private func runMemoryTourBudget(_ o: PerfOptions) async {
        let name = "memory.tour"
        guard let store = AppState.current?.presetStore else { perfSkip(name, "no AppState"); return }
        guard perfWindowUp else { perfSkip(name, "the main window is closed"); return }
        let presets = store.presetsInSidebarOrder
        func tour() async {
            for p in presets {
                NotificationCenter.default.post(name: .init("inputconfig.debug.selectid"), object: p.id.uuidString)
                try? await Task.sleep(for: .seconds(0.25))
            }
            // Autorelease pools and the page's own caches settle.
            try? await Task.sleep(for: .seconds(1.0))
        }
        let m0 = ProcessMemory.read(), b0 = ProcessMemory.liveBlocks()
        await tour()
        let m1 = ProcessMemory.read(), b1 = ProcessMemory.liveBlocks()
        await tour()
        let m2 = ProcessMemory.read(), b2 = ProcessMemory.liveBlocks()
        func mb(_ a: UInt64, _ b: UInt64) -> Double { (Double(b) - Double(a)) / 1_048_576 }
        let lap2 = mb(m1.footprint, m2.footprint)
        perfLine(name, gated: ("footprint_delta_mb", lap2), budget: PerfBudget.memoryTourMb, pass: lap2 <= PerfBudget.memoryTourMb,
                 extra: String(format: "lap1_mb=%+.1f resident_delta_mb=%+.1f blocks_delta=%+ld blocks_lap1=%+ld footprint_mb=%.0f presets=%ld",
                               mb(m0.footprint, m1.footprint), mb(m1.resident, m2.resident), b2 - b1, b1 - b0,
                               Double(m2.footprint) / 1_048_576, presets.count),
                 runs: 2)
    }
}
#endif

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

        guard status == noErr else { stop(); return false }

        // Our own virtual source only, by endpoint: by name, any device
        // whose name contained "InputConfig" was listened to as well.
        let own = MIDIService.ownSourceEndpoint
        guard own != 0 else { stop(); return false }
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

// MARK: - Remembered match

extension TestBenchService {
    /// A slot whose pad no layout knows, or with no pad at all, keeps its
    /// miss: the Live Visualizer asks for it several times a pass.
    func runRememberedMatchTests() {
        #if DEBUG
        let cat = "Controller drawing"
        guard let service = AppState.current?.controllerService else {
            skip(cat, "A slot with no model keeps its miss", detail: "no controller service")
            return
        }
        // Every slot: the remembered answer is the one the rules give now.
        var differ: [Int] = []
        for slot in 0..<8 where ControllerLayoutResolver.cachedMatch(service: service, slot: slot)?.id
            != ControllerLayoutResolver.match(service: service, slot: slot)?.id { differ.append(slot) }
        record(cat, "The remembered match is the match", pass: differ.isEmpty,
               detail: differ.isEmpty ? "8 slots agree" : "slots differ: " + differ.map(String.init).joined(separator: ", "))
        // An empty slot, past any pad plugged in: asked again, no rules run.
        let empty = 15
        _ = ControllerLayoutResolver.cachedMatch(service: service, slot: empty)
        let runs = ControllerLayoutResolver.debugMatchRuns
        for _ in 0..<5 { _ = ControllerLayoutResolver.cachedMatch(service: service, slot: empty) }
        let again = ControllerLayoutResolver.debugMatchRuns - runs
        record(cat, "A slot with no model keeps its miss", pass: again == 0,
               detail: again == 0 ? "5 asks, no match run" : "\(again) match runs in 5 asks")
        #endif
    }
}

// MARK: - Observation, stage 0

extension TestBenchService {
    /// What the views stopped observing in 1.10 stays unobserved. Body run
    /// counts are not testable here; `inputconfig.debug.bodycounts` (DEBUG)
    /// counts them in the app.
    func runObservationStageZeroTests() {
        let cat = "Observation"
        guard let service = AppState.current?.controllerService else {
            skip(cat, "isScanning is not published", detail: "no controller service")
            return
        }
        // A @Published var reflects as "_isScanning". Published, each Scan's
        // two writes re-ran every view observing the service.
        let labels = Set(Mirror(reflecting: service).children.compactMap(\.label))
        record(cat, "isScanning is not published",
               pass: labels.contains("isScanning") && !labels.contains("_isScanning"),
               detail: labels.contains("_isScanning") ? "published" : "plain")
    }

    /// Launch path: the folder paths are worked out once per
    /// change of what they are made from, and the single-copy check asks
    /// for running copies by bundle identifier, which finds the same ones
    /// as reading the whole list.
    func runLaunchPathTests() {
        let cat = "Launch"
        let memo = GroupPathMemo()
        var runs = 0
        func paths(_ groups: [PresetGroup], hide: Bool) -> [(id: UUID, path: String)] {
            memo.paths(groups: groups, hideBuiltIn: hide) {
                runs += 1
                return groups.map { ($0.id, $0.name) }
            }
        }
        var groups = [PresetGroup(name: "A", sortOrder: 0), PresetGroup(name: "B", sortOrder: 1)]
        let first = paths(groups, hide: false)
        _ = paths(groups, hide: false)
        let runsSame = runs
        groups[1].name = "C"
        let renamed = paths(groups, hide: false)
        let runsRenamed = runs
        _ = paths(groups, hide: true)
        let runsHidden = runs
        _ = paths(groups, hide: true)
        record(cat, "Folder paths are worked out once per folder or Hide Built-in change",
               pass: runsSame == 1 && runsRenamed == 2 && runsHidden == 3 && runs == 3
                   && first.map(\.path) == ["A", "B"] && renamed.map(\.path) == ["A", "C"],
               detail: "runs \(runsSame), \(runsRenamed), \(runsHidden), \(runs)")
        // This copy, and two apps that always run.
        var differ: [String] = []
        for id in [Bundle.main.bundleIdentifier ?? "", "com.apple.finder", "com.apple.dock"] where !id.isEmpty {
            let byID = Set(NSRunningApplication.runningApplications(withBundleIdentifier: id).map(\.processIdentifier))
            let listed = Set(NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == id }.map(\.processIdentifier))
            if byID != listed || byID.isEmpty { differ.append("\(id) \(byID.count) vs \(listed.count)") }
        }
        record(cat, "Running copies by bundle identifier match the whole list",
               pass: differ.isEmpty, detail: differ.isEmpty ? "3 identifiers" : differ.joined(separator: "; "))
    }

    /// The sidebar selection (1.10): a preset switch notifies readers of the
    /// id only. The window body reads hasSelection, which a switch from one
    /// preset to another leaves alone.
    func runSelectionObservationTests() {
        let cat = "Observation"
        final class Fired: @unchecked Sendable { var count = 0 }
        func fires(_ start: UUID?, _ read: (PresetSelection) -> Void, _ write: (PresetSelection) -> Void) -> Bool {
            let selection = PresetSelection()
            selection.id = start
            let fired = Fired()
            withObservationTracking { read(selection) } onChange: { fired.count += 1 }
            write(selection)
            return fired.count > 0
        }
        let a = UUID(), b = UUID()
        let switchID = fires(a, { _ = $0.id }, { $0.id = b })
        let switchHas = fires(a, { _ = $0.hasSelection }, { $0.id = b })
        record(cat, "Selection: a switch notifies the id's readers, not the window body",
               pass: switchID && !switchHas, detail: "id \(switchID), hasSelection \(switchHas)")
        let same = fires(a, { _ = ($0.id, $0.hasSelection) }, { $0.id = a })
        record(cat, "Selection: picking the selected preset again is silent", pass: !same)
        let home = fires(a, { _ = $0.hasSelection }, { $0.id = nil })
        let open = fires(nil, { _ = $0.hasSelection }, { $0.id = b })
        let check = PresetSelection()
        check.id = a
        let set = check.hasSelection
        check.id = nil
        record(cat, "Selection: Home and opening a page notify the window body",
               pass: home && open && set && !check.hasSelection,
               detail: "home \(home), open \(open), set \(set), cleared \(!check.hasSelection)")

        // Each sidebar row reads its own PresetRowSelection: a switch tells
        // the row left and the row picked, no other, and making a row's
        // state (which the sidebar's rows do) does not observe the id.
        let rows = PresetSelection()
        let c = UUID(), d = UUID()
        rows.id = a
        let ra = rows.row(for: a), rb = rows.row(for: b), rc = rows.row(for: c)
        let fa = Fired(), fb = Fired(), fc = Fired(), fMake = Fired()
        withObservationTracking { _ = ra.isSelected } onChange: { fa.count += 1 }
        withObservationTracking { _ = rb.isSelected } onChange: { fb.count += 1 }
        withObservationTracking { _ = rc.isSelected } onChange: { fc.count += 1 }
        withObservationTracking { _ = rows.row(for: d) } onChange: { fMake.count += 1 }
        rows.id = b
        record(cat, "Row selection: a switch redraws the row left and the row picked, no other",
               pass: fa.count > 0 && fb.count > 0 && fc.count == 0 && !ra.isSelected && rb.isSelected && !rc.isSelected,
               detail: "left \(fa.count) \(ra.isSelected), picked \(fb.count) \(rb.isSelected), other \(fc.count) \(rc.isSelected)")
        record(cat, "Row selection: making a row's state does not observe the selection",
               pass: fMake.count == 0, detail: "\(fMake.count) notifications")
        // A row made after the switch (a folder opened later) starts right;
        // the same pick again is silent; Home clears the row.
        let fAgain = Fired()
        withObservationTracking { _ = rb.isSelected } onChange: { fAgain.count += 1 }
        rows.id = b
        // Read at once: the switch to d below flips rb and fires it, rightly.
        let repeatCount = fAgain.count
        let late = rows.row(for: b) === rb && rows.row(for: d).isSelected == false
        rows.id = d
        let made = rows.row(for: d).isSelected && !rb.isSelected
        rows.id = nil
        record(cat, "Row selection: a later row starts right, a repeat is silent, Home clears it",
               pass: late && made && repeatCount == 0 && !rows.row(for: d).isSelected,
               detail: "kept \(late), later row \(made), repeat \(repeatCount), home \(!rows.row(for: d).isSelected)")
    }
}

// MARK: - Preset switch, body runs

extension TestBenchService {
    /// A switch re-runs the page once: the version list, the Emergency Stop
    /// button and the activity log are Equatable and skip a body run that
    /// changes nothing for them. These cases prove each gate still lets a
    /// switch through, and (DEBUG, main window up, nothing over it) that a
    /// switch still shows the preset picked.
    func runPageSwitchTests() async {
        let cat = "Preset Switch"
        guard let store = AppState.current?.presetStore else {
            skip(cat, "Page switch cases", detail: "no preset store")
            return
        }
        let presets = store.presetsInSidebarOrder
        guard presets.count > 1 else {
            skip(cat, "Page switch cases", detail: "fewer than two presets")
            return
        }
        // The version list: a new preset is a new list, the same one is not.
        let a = presets[0], b = presets[1]
        record(cat, "The version list takes a switch to another preset",
               pass: PresetVersionsList(presetID: a.id, presetStore: store)
                   != PresetVersionsList(presetID: b.id, presetStore: store)
                   && PresetVersionsList(presetID: a.id, presetStore: store)
                   == PresetVersionsList(presetID: a.id, presetStore: store))
        // Read by id, the list is the one read by preset.
        let differ = presets.filter { store.versions(forID: $0.id) != store.versions(for: $0) }
        record(cat, "Versions by id match versions by preset", pass: differ.isEmpty,
               detail: differ.isEmpty ? "\(presets.count) presets" : "\(differ.count) differ, first \(differ[0].name)")
        record(cat, "The Emergency Stop button skips a page body run",
               pass: PresetDetailView.EmergencyStopHeaderButton(presetStore: store)
                   == PresetDetailView.EmergencyStopHeaderButton(presetStore: store))
        // The sidebar's rows: the same key skips a switch's run, and each
        // thing they show, changed alone, lets the run through.
        let key = SidebarRowsKey(storeRevision: 1, query: "", selectedFolderID: nil, flashingPresetID: nil,
                                 flashingGroupID: nil, colorEditingGroupID: nil, folderPendingDelete: nil,
                                 groupPaths: [(id: a.id, path: "A")])
        var changed: [(String, SidebarRowsKey)] = []
        func change(_ name: String, _ edit: (inout SidebarRowsKey) -> Void) {
            var k = key
            edit(&k)
            changed.append((name, k))
        }
        change("store") { $0.storeRevision += 1 }
        change("search") { $0.query = "x" }
        change("folder") { $0.selectedFolderID = b.id }
        change("flash") { $0.flashingPresetID = b.id }
        change("folder flash") { $0.flashingGroupID = b.id }
        change("color popover") { $0.colorEditingGroupID = b.id }
        change("folder delete") { $0.folderPendingDelete = b.id }
        change("picker color") { $0.pickAnotherColorForTest() }
        change("folder path") { $0.groupPaths = [(id: a.id, path: "B")] }
        change("folder added") { $0.groupPaths.append((id: b.id, path: "B")) }
        func same(_ x: SidebarRowsKey, _ y: SidebarRowsKey) -> Bool { SidebarRows(key: x) == SidebarRows(key: y) }
        var blocked: [String] = []
        for (name, k) in changed where same(k, key) {
            blocked.append(name)
        }
        record(cat, "The sidebar rows skip a switch, not a change they show",
               pass: same(key, key) && blocked.isEmpty,
               detail: blocked.isEmpty ? "\(changed.count) changes let through" : "held back: \(blocked.joined(separator: ", "))")
        // Every change the store publishes moves the count the key holds.
        let count = store.publishCount
        store.objectWillChange.send()
        record(cat, "A store change reaches the sidebar rows", pass: store.publishCount != count,
               detail: "\(count) to \(store.publishCount)")
        record(cat, "The activity log skips a window body run, not a change of place",
               pass: DebugLogView(onHome: false) == DebugLogView(onHome: false)
                   && DebugLogView(onHome: true) != DebugLogView(onHome: false)
                   && DebugLogView(standalone: true) != DebugLogView(standalone: false))
        #if DEBUG
        await runPageSwitchShownTest(store: store, presets: presets, cat: cat)
        #endif
    }

    #if DEBUG
    /// Two presets selected in turn through the selectid hook: the window
    /// title, which the page sets from the preset's name, follows each one.
    /// Then the preset shown before is selected again.
    private func runPageSwitchShownTest(store: PresetStore, presets: [Preset], cat: String) async {
        let name = "A switch shows the preset picked"
        guard let window = MenuBarController.mainWindow, window.isVisible else {
            skip(cat, name, detail: "the main window is closed")
            return
        }
        guard window.attachedSheet == nil else {
            skip(cat, name, detail: "a sheet is over the page")
            return
        }
        // Two presets with different shown names, one with versions if any.
        let withVersions = presets.first { !store.versions(forID: $0.id).isEmpty }
        let first = withVersions ?? presets[0]
        guard let second = presets.first(where: { $0.id != first.id && $0.shownName != first.shownName }) else {
            skip(cat, name, detail: "no two presets with different names")
            return
        }
        let before = window.title
        func show(_ p: Preset) async -> String {
            NotificationCenter.default.post(name: .init("inputconfig.debug.selectid"), object: p.id.uuidString)
            try? await Task.sleep(for: .seconds(0.4))
            return window.title
        }
        let t1 = await show(first), t2 = await show(second), t3 = await show(first)
        if t1 == t2 {
            skip(cat, name, detail: "the window title does not follow the page here (\"\(t1)\")")
        } else {
            record(cat, name, pass: t1 == first.shownName && t2 == second.shownName && t3 == first.shownName,
                   detail: "\"\(t1)\" \"\(t2)\" \"\(t3)\" for \"\(first.shownName)\" \"\(second.shownName)\"")
        }
        // Back to what was shown, when one preset has that name.
        let shownBefore = store.presets.filter { $0.shownName == before }
        if shownBefore.count == 1 {
            _ = await show(shownBefore[0])
        } else if !store.presets.contains(where: { $0.shownName == before }) {
            NotificationCenter.default.post(name: .init("inputconfig.debug.welcome"), object: nil)
        }
    }
    #endif
}

// MARK: - The page's speed row across a switch

extension TestBenchService {
    /// The speed row is no longer made anew on every switch: its
    /// sliders skip a switch that changes nothing they draw, and its number
    /// fields stay unless one has focus. These cases prove the gates let
    /// every change through and that nothing of one preset reaches the next.
    func runSpeedRowTests() async {
        let cat = "Speed Row"
        let a = UUID(), b = UUID()
        let box = SpeedSliderActions(), other = SpeedSliderActions()
        func slider(_ shown: Double, _ actions: SpeedSliderActions) -> SpeedSlider {
            SpeedSlider(benchTitle: "Pointer speed", shown: shown, actions: actions)
        }
        record(cat, "A speed slider skips a run that changes nothing it draws, not a new value",
               pass: slider(1, box) == slider(1, box) && slider(1, box) != slider(1.05, box)
                   && slider(1, box) != slider(1, other))

        // A drag begun on one preset and still held after a switch writes
        // nothing more, and its end saves nothing; a step with no drag (the
        // keyboard) and a drag on the preset shown now go through.
        var got: [Double] = []
        var ends = 0
        var mouseDown = true
        box.mouseHeld = { mouseDown }
        box.set = { got.append($0) }
        box.ended = { ends += 1 }
        box.presetID = a
        box.editing(true)
        box.step(1.5)
        box.presetID = b
        box.step(2.0)
        box.editing(false)
        let heldAcross = got == [1.5] && ends == 0
        box.step(2.5)
        box.editing(true)
        box.step(3.0)
        box.editing(false)
        record(cat, "A slider drag held across a switch stops writing; later steps and drags land",
               pass: heldAcross && got == [1.5, 2.5, 3.0] && ends == 1,
               detail: "values \(got), saves \(ends)")

        // The same steps with no mouse button down are the keyboard's: the
        // slider keeps focus across a switch, and its arrows act on the
        // preset shown now.
        got = []
        ends = 0
        box.presetID = a
        box.editing(true)
        box.step(1.5)
        box.presetID = b
        mouseDown = false
        box.step(2.0)
        box.editing(false)
        record(cat, "A keyboard step after a switch lands on the preset shown",
               pass: got == [1.5, 2.0] && ends == 1,
               detail: "values \(got), saves \(ends)")

        // The number field: kept across a switch without focus, made anew
        // across one with focus (its typing belongs to the preset left).
        let key = SpeedFieldKey()
        let k1 = key.key(for: a), k2 = key.key(for: b)
        key.focus.active = true
        let k3 = key.key(for: a), k4 = key.key(for: a)
        key.focus.active = false
        let k5 = key.key(for: b)
        record(cat, "A speed field is made anew on a switch only while it has focus",
               pass: k1 == k2 && k3 != k2 && k4 == k3 && k5 == k4,
               detail: "kept \(k1 == k2), focused \(k3 != k2), same preset \(k4 == k3), after focus \(k5 == k4)")

        // The preset page's speed fields moved to the editor's Utilities in
        // 1.10, so the page test that followed them across a switch is gone.
    }
}

#if DEBUG
// MARK: - Editor rows (closed row cost and its accessibility strings)

extension TestBenchService {
    /// What a closed editor row costs, and the strings it gives VoiceOver
    /// and Voice Control for every row of every shipped preset. The cost
    /// lines and the digest are INFO lines in the headless report; the full
    /// list is written to tmp/rowa11y.txt, so two builds can be diffed.
    func runEditorRowCases() async {
        let category = "Editor Rows"

        // Every shipped preset's rows, closed.
        let dump = await EditorRowBench.accessibilityDump()
        let text = dump.lines.joined(separator: "\n") + "\n"
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rowa11y.txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        let missing = dump.lines.filter { $0.hasSuffix("NOT RENDERED") }.count
        record(category, "every shipped preset row rendered closed", pass: missing == 0 && dump.rows > 0,
               detail: "\(dump.rows) rows, \(missing) not rendered")
        info(category, "row accessibility digest",
             detail: "\(EditorRowBench.digest(text)) over \(dump.lines.count) strings, \(dump.rows) rows (full list: \(url.path))")

        // The cost of a closed row: 60 rows taken in order from the shipped
        // presets, and 60 of the commonest kind (a button sending one key).
        let all = ExamplePresets.all.flatMap { $0.joysticks.flatMap(\.bindings) }
        let mixed = Array(all.prefix(60))
        if let plain = all.first(where: { $0.input.type == .button && $0.outputs.count == 1 && $0.outputs[0].type == .key
                                            && $0.modifiers.isEmpty && $0.macroSteps == nil }) {
            let cost = await EditorRowBench.cost(of: Array(repeating: plain, count: 60))
            info(category, "row cost, button to key", detail: cost.line)
        }
        let cost = await EditorRowBench.cost(of: mixed)
        info(category, "row cost, shipped mix", detail: cost.line)
        info(category, "row struct size", detail: "BindingRowView \(MemoryLayout<BindingRowView>.size) bytes, copied into each closure its body makes")
    }
}
#endif
