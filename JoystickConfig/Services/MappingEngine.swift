import Foundation
import Combine

/// The core engine that reads controller inputs and fires output actions.
/// 120Hz polling with debug logging capability.
@MainActor
class MappingEngine: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var activePreset: Preset?
    /// Mirror of currently-active inputs. NOT @Published - observers update
    /// via the throttled `activeInputsPublished` instead so a fast-changing
    /// joystick does not re-render the editor 120 times per second.
    var activeInputs: Set<String> = []
    @Published var activeInputsPublished: Set<String> = []
    private var activeInputsLastFlush: Date = .distantPast
    @Published var debugLog: [(text: String, joystickIndex: Int?)] = []  // Rolling debug log visible in UI

    private var controllerService: GameControllerService
    private var pollTimer: Timer?

    private var activeStates: [Int: Set<String>] = [:]
    private let defaultAxisThreshold: Float = 0.25
    private let hatThreshold: Float = 0.5

    // Toggle mode state: tracks which bindings are currently toggled on
    private var toggleStates: [String: Bool] = [:]
    // Turbo state: tracks last fire time for turbo bindings
    private var turboTimestamps: [String: Date] = [:]
    // Cache of serialized input keys to avoid repeated string allocations at 120Hz
    private var serializedKeyCache: [UUID: String] = [:]

    private var debugEnabled = true
    private var debugLineCount = 0

    /// Internal buffer the polling loop writes to without triggering UI
    /// re-renders. A separate timer flushes this into `debugLog` (which is
    /// @Published) at a much slower rate so the editor and other observers
    /// of `mappingEngine` do not re-render on every input event.
    private var pendingLog: [(text: String, joystickIndex: Int?)] = []
    private var logFlushTimer: Timer?
    /// True while the active preset retains TouchpadService. Tracked
    /// separately so stop() only releases when start() retained.
    private var usesTouchpadInput = false

    /// When true, the engine keeps polling and updating `activeInputs` so the
    /// editor's row highlights and the touchpad calibration UI keep working,
    /// but it does NOT fire any outputs (no mouse motion, no keystrokes, no
    /// MIDI). Set while the preset editor is open so a touchpad-as-mouse
    /// preset can't fling the cursor across the screen while the user is
    /// trying to configure it.
    @Published var outputsPaused: Bool = false {
        didSet {
            if outputsPaused {
                // Release any output state that was currently held so the
                // user doesn't end up with a stuck key or held mouse button
                // the moment we pause.
                InputSimulator.shared.releaseAll()
                MIDIService.shared.releaseAllNotes()
                pendingMouseDeltaX = 0
                pendingMouseDeltaY = 0
                pendingScrollDeltaX = 0
                pendingScrollDeltaY = 0
            }
        }
    }

    init(controllerService: GameControllerService) {
        self.controllerService = controllerService
    }

    // MARK: - Start / Stop

    func start(with preset: Preset) {
        guard !preset.joysticks.isEmpty else { return }

        activePreset = preset
        isRunning = true
        activeStates.removeAll()
        activeInputs.removeAll()
        toggleStates.removeAll()
        turboTimestamps.removeAll()
        serializedKeyCache.removeAll()
        debugLog.removeAll()
        pendingLog.removeAll()
        debugLineCount = 0

        for i in preset.joysticks.indices {
            activeStates[i] = Set<String>()
        }

        StatsService.shared.enginStarted(presetName: preset.name)
        log("Engine started with preset: \(preset.name)")
        log("Joysticks: \(preset.joysticks.count), Total bindings: \(preset.joysticks.flatMap(\.bindings).count)")
        log("Connected controllers: \(controllerService.connectedControllers.count)")

        // Spin up the touchpad helper only if the preset actually uses
        // touchpad inputs. Avoids running a subprocess users didn't opt in to.
        let usesTouchpad = preset.joysticks.contains { joystick in
            joystick.bindings.contains {
                $0.input.type == .touchpad || $0.input.type == .touchpadRegion
            }
        }
        if usesTouchpad {
            TouchpadService.shared.retain()
            usesTouchpadInput = true
            log("Touchpad input enabled (started TouchpadHelper)")
        } else {
            usesTouchpadInput = false
        }

        for (i, ctrl) in controllerService.connectedControllers.enumerated() {
            log("  Controller \(i): \(ctrl.vendorName ?? "Unknown"), hasExtendedGamepad: \(ctrl.extendedGamepad != nil)")
        }

        // Push the preset's light-bar override (if any) so every
        // light-capable controller flashes the preset's color while it's
        // active. We apply temporarily - the slot's stored default color is
        // untouched, so revert in stop() simply re-asserts it.
        if let override = preset.lightBarColor {
            let bri: UInt8? = preset.lightBarBrightness.map { UInt8(max(0, min(2, $0))) }
            for slot in controllerService.controllerDetails.keys
                where controllerService.controllerDetails[slot]?.hasLight == true {
                controllerService.applyTemporaryLight(
                    at: slot,
                    red: override.floatR,
                    green: override.floatG,
                    blue: override.floatB,
                    brightness: bri)
            }
            log("Applied preset light-bar override (\(override.r),\(override.g),\(override.b))")
        }

        // 120 Hz polling - 240 caused UI freezes when the editor was open
        // because the @Published activeInputs cascaded re-renders. 120 is
        // still well below human reaction time.
        let pollInterval: TimeInterval = 1.0 / 120.0
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollControllers()
            }
        }
        RunLoop.main.add(pollTimer!, forMode: .common)

        // Flush log entries to the @Published array at 5 Hz so observers
        // of mappingEngine do not re-render on every input event.
        logFlushTimer?.invalidate()
        logFlushTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.flushPendingLog()
            }
        }
        RunLoop.main.add(logFlushTimer!, forMode: .common)
    }

    func stop() {
        StatsService.shared.engineStopped()
        pollTimer?.invalidate()
        pollTimer = nil
        logFlushTimer?.invalidate()
        logFlushTimer = nil
        isRunning = false
        InputSimulator.shared.releaseAll()
        MIDIService.shared.releaseAllNotes()
        if usesTouchpadInput {
            TouchpadService.shared.release()
            usesTouchpadInput = false
        }

        // Revert any preset light-bar override by re-asserting each
        // light-capable controller's stored slot color. setControllerLight
        // reads from `lightColors` / slot defaults, so the user-configured
        // general color comes back automatically.
        if let preset = activePreset, preset.lightBarColor != nil {
            for slot in controllerService.controllerDetails.keys
                where controllerService.controllerDetails[slot]?.hasLight == true {
                controllerService.setControllerLight(at: slot)
            }
            log("Reverted light bar to general color")
        }

        activeStates.removeAll()
        activeInputs.removeAll()
        activePreset = nil
        log("Engine stopped")
        // Final flush so the user sees the stop event in the log view.
        flushPendingLog()
    }

    // MARK: - Debug Logging

    private func log(_ message: String, joystick: Int? = nil) {
        debugLineCount += 1
        let entry = "[\(debugLineCount)] \(message)"
        // Write to the internal buffer (no @Published trigger). The flush
        // timer copies this into `debugLog` at 5 Hz so observers of the
        // mapping engine do not re-render on every input event.
        pendingLog.append((text: entry, joystickIndex: joystick))
        if pendingLog.count > 50 {
            pendingLog.removeFirst()
        }
        #if DEBUG
        print("[MappingEngine] \(message)")
        #endif
    }

    /// Copy accumulated log entries into the @Published `debugLog` array.
    /// Only fires when there's something new and only at the timer's rate.
    private func flushPendingLog() {
        guard !pendingLog.isEmpty else { return }
        debugLog = pendingLog
    }

    // MARK: - Polling

    private var pollCount = 0

    /// Accumulated mouse motion delta for the current poll frame. Each
    /// continuous axis binding adds to this, and a single CGEvent is
    /// posted at the end of the poll. This produces true diagonal motion
    /// when, for example, a stick is pushed up-and-left and two separate
    /// bindings (X+ and Y-) both fire in the same frame.
    private var pendingMouseDeltaX: Int = 0
    private var pendingMouseDeltaY: Int = 0
    private var pendingScrollDeltaX: Int32 = 0
    private var pendingScrollDeltaY: Int32 = 0

    private func pollControllers() {
        guard let preset = activePreset else { return }
        pollCount += 1
        pendingMouseDeltaX = 0
        pendingMouseDeltaY = 0
        pendingScrollDeltaX = 0
        pendingScrollDeltaY = 0

        for (joystickIndex, joystickMapping) in preset.joysticks.enumerated() {
            guard let state = controllerService.readControllerState(at: joystickIndex) else {
                // Log once every 120 polls (1 second)
                if pollCount % 120 == 1 {
                    log("No controller state for joystick \(joystickIndex)", joystick: joystickIndex)
                }
                continue
            }

            // Log raw state once per second for debugging
            if pollCount % 120 == 1 {
                let activeButtons = state.buttons.filter { $0.value > 0.5 }.map { "btn\($0.key)" }
                let activeAxes = state.axes.filter { abs($0.value) > defaultAxisThreshold }.map { "axi\($0.key)=\(String(format: "%.2f", $0.value))" }
                if !activeButtons.isEmpty || !activeAxes.isEmpty {
                    log("Raw state J\(joystickIndex): \(activeButtons + activeAxes)", joystick: joystickIndex)
                }
            }

            var currentlyActive = Set<String>()

            for binding in joystickMapping.bindings {
                let isActive = checkInput(binding.input, state: state, binding: binding)
                let inputKey = cachedKey(for: binding)
                let bindKey = "\(joystickIndex):\(inputKey)"

                if isActive {
                    currentlyActive.insert(inputKey)
                }

                let wasActive = activeStates[joystickIndex]?.contains(inputKey) ?? false

                if binding.toggleMode == true {
                    // Toggle mode: press toggles on/off
                    if isActive && !wasActive {
                        let isToggledOn = toggleStates[bindKey] ?? false
                        if isToggledOn {
                            log("TOGGLE OFF: \(inputKey)", joystick: joystickIndex)
                            fireOutputs(binding.outputs, press: false)
                            toggleStates[bindKey] = false
                        } else {
                            log("TOGGLE ON: \(inputKey) -> \(binding.outputs.map(\.serialized))", joystick: joystickIndex)
                            fireOutputs(binding.outputs, press: true)
                            toggleStates[bindKey] = true
                            fireFeedback(for: binding, joystickIndex: joystickIndex)
                        }
                    }
                    // Keep firing continuous outputs while toggled on
                    if toggleStates[bindKey] == true {
                        fireContinuousOutputs(binding.outputs, input: binding.input, state: state, binding: binding)
                    }
                } else if binding.turboEnabled == true {
                    // Turbo mode: rapid fire while held
                    if isActive {
                        if !wasActive {
                            log("TURBO START: \(inputKey) -> \(binding.outputs.map(\.serialized))", joystick: joystickIndex)
                            fireFeedback(for: binding, joystickIndex: joystickIndex)
                        }
                        let rate = binding.turboRate ?? 10
                        let interval = 1.0 / Double(rate)
                        let now = Date()
                        let lastFire = turboTimestamps[bindKey] ?? .distantPast
                        if now.timeIntervalSince(lastFire) >= interval {
                            fireOutputs(binding.outputs, press: true)
                            // Schedule release after half the interval
                            DispatchQueue.main.asyncAfter(deadline: .now() + interval * 0.4) { [weak self] in
                                self?.fireOutputs(binding.outputs, press: false)
                            }
                            turboTimestamps[bindKey] = now
                        }
                        fireContinuousOutputs(binding.outputs, input: binding.input, state: state, binding: binding)
                    } else if wasActive {
                        log("TURBO END: \(inputKey)", joystick: joystickIndex)
                        fireOutputs(binding.outputs, press: false)
                        turboTimestamps.removeValue(forKey: bindKey)
                    }
                } else {
                    // Normal mode
                    if isActive && !wasActive {
                        StatsService.shared.recordButtonPress(inputKey: inputKey)
                        log("PRESS: \(inputKey) -> \(binding.outputs.map(\.serialized))", joystick: joystickIndex)
                        // Check for macro
                        if let steps = binding.macroSteps, !steps.isEmpty {
                            executeMacro(steps, joystickIndex: joystickIndex)
                        } else if (binding.repeatCount ?? 1) > 1 {
                            fireWithRepeat(binding)
                        } else {
                            fireOutputs(binding.outputs, press: true)
                        }
                        fireFeedback(for: binding, joystickIndex: joystickIndex)
                    } else if !isActive && wasActive {
                        log("RELEASE: \(inputKey)", joystick: joystickIndex)
                        if binding.macroSteps == nil && (binding.repeatCount ?? 1) <= 1 {
                            fireOutputs(binding.outputs, press: false)
                        }
                    } else if isActive {
                        fireContinuousOutputs(binding.outputs, input: binding.input, state: state, binding: binding)
                    }
                }
            }

            activeStates[joystickIndex] = currentlyActive
        }

        // Flush accumulated mouse and scroll deltas as a single CGEvent.
        // Skipped while outputsPaused so the editor can stay open over an
        // active touchpad-mouse preset without the cursor flying around.
        // (Deltas themselves are zeroed at the start of every frame.)
        if !outputsPaused {
            if pendingMouseDeltaX != 0 || pendingMouseDeltaY != 0 {
                InputSimulator.shared.moveMouse(deltaX: pendingMouseDeltaX, deltaY: pendingMouseDeltaY)
                StatsService.shared.recordMouseMotion(pixels: abs(pendingMouseDeltaX) + abs(pendingMouseDeltaY))
            }
            if pendingScrollDeltaX != 0 || pendingScrollDeltaY != 0 {
                InputSimulator.shared.scrollWheel(deltaX: pendingScrollDeltaX, deltaY: pendingScrollDeltaY)
                StatsService.shared.recordScroll(ticks: Int(abs(pendingScrollDeltaX) + abs(pendingScrollDeltaY)))
            }
        }

        // Update active inputs for UI highlighting
        var allActive = Set<String>()
        for (_, states) in activeStates {
            allActive.formUnion(states)
        }
        if allActive != activeInputs {
            activeInputs = allActive
            // Throttle the @Published mirror to 10 Hz so the highlighted
            // row in the editor doesn't trigger a full sheet re-render on
            // every poll frame.
            let now = Date()
            if now.timeIntervalSince(activeInputsLastFlush) > 0.1 {
                activeInputsLastFlush = now
                activeInputsPublished = allActive
            }
        }
    }

    /// Returns cached serialized key for a binding's input to avoid string allocations in 120Hz loop
    private func cachedKey(for binding: BindingModel) -> String {
        if let cached = serializedKeyCache[binding.id] { return cached }
        let key = binding.input.serialized
        serializedKeyCache[binding.id] = key
        return key
    }

    /// Remap a raw axis magnitude (0...1) through the binding's inner and
    /// outer deadzones. Below the inner deadzone the result is 0. Above the
    /// outer deadzone the result is 1. Between them the value is linearly
    /// scaled so the full 0...1 output range is reached without having to
    /// push the stick to the absolute mechanical limit.
    private func remapMagnitude(_ magnitude: Float, binding: BindingModel?) -> Float {
        let inner = binding?.deadzone ?? defaultAxisThreshold
        let outer = binding?.outerDeadzone ?? 1.0
        let safeOuter = max(min(outer, 1.0), inner + 0.01)  // never collapse the range
        let m = max(0, min(1, magnitude))
        if m <= inner { return 0 }
        if m >= safeOuter { return 1 }
        return (m - inner) / (safeOuter - inner)
    }

    // MARK: - Input Checking

    private func checkInput(_ input: InputEvent, state: ControllerState, binding: BindingModel? = nil) -> Bool {
        let axisThreshold = binding?.deadzone ?? defaultAxisThreshold

        switch input.type {
        case .button:
            return (state.buttons[input.index] ?? 0) > 0.5

        case .axis:
            guard var value = state.axes[input.index] else { return false }
            if binding?.invertAxis == true { value = -value }
            switch input.axisDirection {
            case .positive:
                return value > axisThreshold
            case .negative:
                return value < -axisThreshold
            case .none:
                return abs(value) > axisThreshold
            }

        case .hat:
            guard let hat = state.hats[input.index] else { return false }
            switch input.hatDirection {
            case .up:
                return hat.y > hatThreshold
            case .down:
                return hat.y < -hatThreshold
            case .left:
                return hat.x < -hatThreshold
            case .right:
                return hat.x > hatThreshold
            case .none:
                return false
            }

        case .touchpad:
            // A touchpad "axis" is considered active while the finger is in
            // contact AND there is non-trivial motion in the requested
            // direction since the last poll. Motion driven outputs read the
            // delta directly via processAxisInput.
            let finger = input.touchpadFinger ?? input.index
            guard TouchpadService.shared.isFingerActive(finger),
                  let axis = input.touchpadAxis else { return false }
            // Peek without consuming. We don't have a peek API; this branch
            // is used by digital outputs (e.g. mapping touchpad swipe to a
            // key). For analog outputs the consume happens in processAxisInput.
            let value = TouchpadService.shared.consumeDelta(finger: finger, axis: axis)
            switch input.axisDirection {
            case .positive: return value > axisThreshold
            case .negative: return value < -axisThreshold
            case .none:     return abs(value) > axisThreshold
            }

        case .touchpadRegion:
            // Press for as long as any finger sits inside the named region.
            guard let id = input.touchpadRegionID else { return false }
            return TouchpadService.shared.isRegionPressed(id)

        case .motion:
            // Motion is treated as a half-axis: pick the channel and
            // direction the binding asked for, threshold on a small dead
            // zone so resting drift doesn't fire the binding.
            guard let channel = input.motionChannel,
                  let raw = state.motion[channel] else { return false }
            let value = (binding?.invertAxis == true) ? -raw : raw
            switch input.axisDirection {
            case .positive: return value > axisThreshold
            case .negative: return value < -axisThreshold
            case .none:     return abs(value) > axisThreshold
            }
        }
    }

    // MARK: - Output Firing

    private func fireOutputs(_ outputs: [OutputAction], press: Bool) {
        if outputsPaused { return }
        if press {
            for output in outputs {
                switch output.type {
                case .key: StatsService.shared.recordKeyPress()
                case .mouseButton: StatsService.shared.recordMouseClick()
                case .midiNote, .midiCC, .midiPitchBend, .midiProgramChange, .midiTransport:
                    StatsService.shared.recordMidiEvent()
                default: break
                }
            }
        }
        for output in outputs {
            switch output.type {
            case .key:
                if let code = output.keyCode {
                    if press {
                        InputSimulator.shared.keyDown(code)
                    } else {
                        InputSimulator.shared.keyUp(code)
                    }
                }

            case .mouseButton:
                if let btn = output.mouseButtonIndex {
                    if press {
                        InputSimulator.shared.mouseButtonDown(btn)
                    } else {
                        InputSimulator.shared.mouseButtonUp(btn)
                    }
                }

            case .mouseWheelStep:
                if press, let axis = output.mouseAxis, let dir = output.mouseDirection {
                    InputSimulator.shared.scrollWheelStep(axis: axis, direction: dir)
                }

            case .mouseMotion, .mouseWheel:
                break

            case .midiNote:
                let note = output.midiNote ?? 60
                let vel = output.midiVelocity ?? 100
                let ch = output.midiChannel ?? 1
                if press {
                    MIDIService.shared.sendNoteOn(note: note, velocity: vel, channel: ch)
                } else {
                    MIDIService.shared.sendNoteOff(note: note, channel: ch)
                }

            case .midiCC:
                let cc = output.midiCCNumber ?? 1
                let ch = output.midiChannel ?? 1
                // Buttons fire the configured value on press, 0 on release.
                // Axes are handled by fireContinuousOutputs for smooth values.
                let value = press ? (output.midiCCValue ?? 127) : 0
                MIDIService.shared.sendCC(controller: cc, value: value, channel: ch)

            case .midiPitchBend:
                let ch = output.midiChannel ?? 1
                // Buttons snap to full bend on press, recenter on release.
                let value = press ? 16383 : 8192
                MIDIService.shared.sendPitchBend(value: value, channel: ch)

            case .midiProgramChange:
                // Program Change fires only on press. There's no "release"
                // for a program change - the instrument stays on the new
                // patch until something else changes it.
                if press {
                    let prog = output.midiProgramNumber ?? 0
                    let ch = output.midiChannel ?? 1
                    MIDIService.shared.sendProgramChange(program: prog, channel: ch)
                }

            case .midiTransport:
                // Transport messages fire on press only. Stop is symmetric
                // with Start in user terms - assign both to different buttons.
                if press {
                    MIDIService.shared.sendTransport(output.midiTransport ?? .start)
                }
            }
        }
    }

    /// Execute a macro sequence asynchronously
    private func executeMacro(_ steps: [MacroStep], joystickIndex: Int) {
        StatsService.shared.recordMacroExecution()
        log("MACRO: executing \(steps.count) steps", joystick: joystickIndex)
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            for step in steps {
                // Pre-step delay
                if step.delayMs > 0 {
                    Thread.sleep(forTimeInterval: Double(step.delayMs) / 1000.0)
                }
                // Press
                DispatchQueue.main.async {
                    self?.fireOutputs([step.action], press: true)
                }
                // Hold
                if step.holdMs > 0 {
                    Thread.sleep(forTimeInterval: Double(step.holdMs) / 1000.0)
                }
                // Release
                DispatchQueue.main.async {
                    self?.fireOutputs([step.action], press: false)
                }
            }
        }
    }

    /// Execute outputs with repeat count
    private func fireWithRepeat(_ binding: BindingModel) {
        let count = binding.repeatCount ?? 1
        let delayMs = binding.repeatDelayMs ?? 100

        if count <= 1 {
            fireOutputs(binding.outputs, press: true)
            return
        }

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            for i in 0..<count {
                DispatchQueue.main.async {
                    self?.fireOutputs(binding.outputs, press: true)
                }
                Thread.sleep(forTimeInterval: 0.05)
                DispatchQueue.main.async {
                    self?.fireOutputs(binding.outputs, press: false)
                }
                if i < count - 1 {
                    Thread.sleep(forTimeInterval: Double(delayMs) / 1000.0)
                }
            }
        }
    }

    private func fireContinuousOutputs(_ outputs: [OutputAction], input: InputEvent, state: ControllerState, binding: BindingModel? = nil) {
        if outputsPaused { return }
        for output in outputs {
            switch output.type {
            case .mouseMotion:
                guard let axis = output.mouseAxis, let dir = output.mouseDirection else { continue }
                let speed = output.speed ?? 6

                // Variable sensitivity defaults to true for axis input (gives natural feel).
                // When false, output fires at full speed once the axis crosses the deadzone.
                let useVariable = binding?.variableSensitivity ?? (input.type == .axis || input.type == .touchpad || input.type == .motion)

                var magnitude: Float = 1.0
                var signedMagnitude: Float = 1.0   // for touchpad / motion: sign indicates direction of motion
                if useVariable, input.type == .axis, var axisValue = state.axes[input.index] {
                    if binding?.invertAxis == true { axisValue = -axisValue }
                    let rawMag = min(abs(axisValue), 1.0)
                    // Apply inner/outer deadzone remap before the curve so
                    // the curve operates on the post-deadzone normalized
                    // 0...1 range, not the raw analog value.
                    magnitude = remapMagnitude(rawMag, binding: binding)
                    if let curve = binding?.sensitivityCurve {
                        magnitude = abs(curve.apply(magnitude))
                    }
                } else if input.type == .touchpad,
                          let tpAxis = input.touchpadAxis {
                    let finger = input.touchpadFinger ?? input.index
                    // Touchpad already reports a per-frame delta; we don't
                    // need to remap by a deadzone here. Sign carries motion
                    // direction. Use a much larger gain than axes because
                    // delta values are typically very small (a fraction of
                    // surface width per frame).
                    var delta = TouchpadService.shared.consumeDelta(finger: finger, axis: tpAxis)
                    if binding?.invertAxis == true { delta = -delta }
                    // Filter by requested half-axis: + means motion in the
                    // positive direction counts, motion in the other direction
                    // is ignored. This lets users bind "swipe right" → mouse
                    // right and "swipe left" → mouse left independently.
                    switch input.axisDirection {
                    case .positive: if delta < 0 { delta = 0 }
                    case .negative: if delta > 0 { delta = 0 }
                    case .none: break
                    }
                    // Touchpad speed multiplier - delta is in [-1, 1] roughly
                    // per second of motion; scale so a normal swipe moves the
                    // cursor a healthy distance.
                    let gain: Float = 80.0
                    signedMagnitude = delta * gain
                    magnitude = abs(signedMagnitude)
                }

                // Motion (gyro / accel) feeds the analog mouse path the same
                // way touchpad delta does. A positive gyro-Y while bound to
                // mouse-X+ moves the cursor right; the binding's invertAxis
                // flag flips the polarity.
                if useVariable, input.type == .motion,
                   let channel = input.motionChannel,
                   var motionValue = state.motion[channel] {
                    if binding?.invertAxis == true { motionValue = -motionValue }
                    // Filter by half-axis like we do for touchpad.
                    switch input.axisDirection {
                    case .positive: if motionValue < 0 { motionValue = 0 }
                    case .negative: if motionValue > 0 { motionValue = 0 }
                    case .none: break
                    }
                    // Gyro rotation rate is roughly radians/sec; tilt of a
                    // controller during normal gameplay produces values up
                    // to ~5 rad/s. Apply a moderate gain so a wrist twist
                    // gives a useful cursor delta.
                    let gain: Float = 8.0
                    signedMagnitude = motionValue * gain
                    magnitude = abs(signedMagnitude)
                }

                let scaledSpeed: Int
                if input.type == .touchpad || input.type == .motion {
                    // signedMagnitude already encodes direction + speed;
                    // mouseDirection picks which CGEvent axis it adds to.
                    scaledSpeed = Int(abs(signedMagnitude) * Float(speed) / 6.0)
                } else {
                    scaledSpeed = Int(Float(speed) * magnitude)
                }
                // Accumulate into pendingMouseDelta. The poll loop flushes
                // the total in a single CGEvent at the end of the frame so
                // diagonal motion combines naturally.
                switch (axis, dir) {
                case (.horizontal, .positive): pendingMouseDeltaX += scaledSpeed
                case (.horizontal, .negative): pendingMouseDeltaX -= scaledSpeed
                case (.vertical, .positive): pendingMouseDeltaY += scaledSpeed
                case (.vertical, .negative): pendingMouseDeltaY -= scaledSpeed
                }

            case .mouseWheel:
                guard let axis = output.mouseAxis, let dir = output.mouseDirection else { continue }
                let speed = output.speed ?? 6

                let useVariable = binding?.variableSensitivity ?? (input.type == .axis)

                var magnitude: Float = 1.0
                if useVariable, input.type == .axis, var axisValue = state.axes[input.index] {
                    if binding?.invertAxis == true { axisValue = -axisValue }
                    let rawMag = min(abs(axisValue), 1.0)
                    magnitude = remapMagnitude(rawMag, binding: binding)
                    if let curve = binding?.sensitivityCurve {
                        magnitude = abs(curve.apply(magnitude))
                    }
                }

                let scaledSpeed = Int32(Float(speed) * magnitude)
                switch (axis, dir) {
                case (.horizontal, .positive): pendingScrollDeltaX += scaledSpeed
                case (.horizontal, .negative): pendingScrollDeltaX -= scaledSpeed
                case (.vertical, .positive): pendingScrollDeltaY += scaledSpeed
                case (.vertical, .negative): pendingScrollDeltaY -= scaledSpeed
                }

            case .midiCC:
                // Continuous axis driving a CC. Map the axis's full range to
                // 0..127. For positive-only inputs (triggers, axis "positive"
                // direction) we map 0..1 to 0..127. For full-range axes we
                // map -1..1 to 0..127.
                guard input.type == .axis, var axisValue = state.axes[input.index] else { continue }
                if binding?.invertAxis == true { axisValue = -axisValue }

                let ccValue: Int
                if input.axisDirection == .positive {
                    var mag = max(0, min(1, axisValue))
                    if let curve = binding?.sensitivityCurve { mag = abs(curve.apply(mag)) }
                    ccValue = Int(mag * 127)
                } else if input.axisDirection == .negative {
                    var mag = max(0, min(1, -axisValue))
                    if let curve = binding?.sensitivityCurve { mag = abs(curve.apply(mag)) }
                    ccValue = Int(mag * 127)
                } else {
                    // Full-range axis: -1..1 maps to 0..127
                    let normalized = (axisValue + 1) / 2
                    ccValue = Int(max(0, min(1, normalized)) * 127)
                }
                let cc = output.midiCCNumber ?? 1
                let ch = output.midiChannel ?? 1
                MIDIService.shared.sendCC(controller: cc, value: ccValue, channel: ch)

            case .midiPitchBend:
                // Pitch bend is signed and centered at 8192. -1..1 maps to 0..16383.
                guard input.type == .axis, var axisValue = state.axes[input.index] else { continue }
                if binding?.invertAxis == true { axisValue = -axisValue }
                var v: Float
                if input.axisDirection == .positive {
                    v = max(0, min(1, axisValue))
                } else if input.axisDirection == .negative {
                    v = -max(0, min(1, -axisValue))
                } else {
                    v = max(-1, min(1, axisValue))
                }
                if let curve = binding?.sensitivityCurve {
                    let mag = curve.apply(abs(v))
                    v = v >= 0 ? mag : -mag
                }
                let pbValue = Int((v + 1) / 2 * 16383)
                let ch = output.midiChannel ?? 1
                MIDIService.shared.sendPitchBend(value: pbValue, channel: ch)

            default:
                break
            }
        }
    }

    // MARK: - Feedback (Haptics + Speech)

    /// Fire haptic and speech feedback for a binding press event.
    private func fireFeedback(for binding: BindingModel, joystickIndex: Int) {
        if outputsPaused { return }
        if binding.hapticEnabled == true,
           joystickIndex < controllerService.connectedControllers.count {
            let controller = controllerService.connectedControllers[joystickIndex]
            let intensity = binding.hapticIntensity ?? 0.6
            FeedbackService.shared.vibrate(controller: controller, intensity: intensity)
        }

        if binding.speechEnabled == true {
            let phrase = binding.speechText?.isEmpty == false
                ? binding.speechText!
                : binding.input.serialized
            let destination = binding.speechDestination ?? .mac
            FeedbackService.shared.speak(phrase, destination: destination)
        }
    }
}
