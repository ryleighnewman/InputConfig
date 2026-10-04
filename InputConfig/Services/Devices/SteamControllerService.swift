import Foundation

/// Steam Controller buttons. The raw value is the InputConfig binding index
/// (0-22, stored in presets); `hardwareBit` is the bit position inside the
/// 24-bit button field emitted by `SteamControllerHelper` (report bytes 8-10,
/// see SDL_hidapi_steam.c). The two agree for every button except the last two:
/// bit 21 is unknown, stick click is bit 22, and "left pad and stick in use
/// together" is bit 23. The Steam Controller exposes more buttons than a
/// standard MFi gamepad (two trackpad clicks, two grip paddles, the Steam
/// button, etc.), so we use our own index scheme rather than overloading the
/// existing MFi numbering.
enum SteamControllerButton: Int, CaseIterable {
    case rightTrigger = 0    // RT digital (trigger pulled fully)
    case leftTrigger = 1     // LT digital
    case rightBumper = 2     // RB
    case leftBumper = 3      // LB
    case y = 4
    case b = 5
    case x = 6
    case a = 7
    case dpadUp = 8
    case dpadRight = 9
    case dpadLeft = 10
    case dpadDown = 11
    case back = 12           // "previous" / Select
    case steam = 13          // Steam (home) button
    case forward = 14        // Start / "next"
    case leftGrip = 15       // back paddle
    case rightGrip = 16      // back paddle
    case leftPadClick = 17   // left trackpad pressed
    case rightPadClick = 18  // right trackpad pressed
    case leftPadTouch = 19
    case rightPadTouch = 20
    case stickClick = 21     // L3 - clicked the analog stick (hardware bit 22)
    case stickActive = 22    // left pad and stick both in use (hardware bit 23)

    /// The Steam Controller's index for a button in the standard gamepad
    /// numbering (0 A, 1 B, 2 X, 3 Y, 4 LB, 5 RB, 8 Back, 9 Menu, 10
    /// Home, 11 left stick click), for settings stored in that numbering,
    /// such as the emergency stop's controller button. nil when it has no
    /// such button.
    static func index(forStandardButton standard: Int) -> Int? {
        switch standard {
        case 0: return SteamControllerButton.a.rawValue
        case 1: return SteamControllerButton.b.rawValue
        case 2: return SteamControllerButton.x.rawValue
        case 3: return SteamControllerButton.y.rawValue
        case 4: return SteamControllerButton.leftBumper.rawValue
        case 5: return SteamControllerButton.rightBumper.rawValue
        case 8: return SteamControllerButton.back.rawValue
        case 9: return SteamControllerButton.forward.rawValue
        case 10: return SteamControllerButton.steam.rawValue
        case 11: return SteamControllerButton.stickClick.rawValue
        default: return nil
        }
    }

    /// InputConfig binding index. We map onto the same 0-22 space; this
    /// keeps preset JSON readable ("btn 5 = B button").
    var bindingIndex: Int { rawValue }

    /// Bit position in the helper's button field (SDL_hidapi_steam.c's
    /// masks: bit 22 the stick click, bit 23 the left pad and stick both
    /// in use; bit 21 is unknown and not exposed).
    var hardwareBit: Int {
        switch self {
        case .stickClick: return 22
        case .stickActive: return 23
        default: return rawValue
        }
    }

    /// Mask for this button inside `SteamControllerState.buttons`.
    var hardwareMask: UInt32 { UInt32(1) << UInt32(hardwareBit) }

    /// Valve's names for the controls (Steamworks input origins): the
    /// arrow buttons are Back and Start, the "D-pad" is the left trackpad's
    /// edge clicks. Only names: presets store the indices.
    var displayName: String {
        switch self {
        case .rightTrigger: return "Right trigger click (full pull)"
        case .leftTrigger: return "Left trigger click (full pull)"
        case .rightBumper: return "Right bumper"
        case .leftBumper: return "Left bumper"
        case .y: return "Y"
        case .b: return "B"
        case .x: return "X"
        case .a: return "A"
        case .dpadUp: return "Left pad up (click)"
        case .dpadRight: return "Left pad right (click)"
        case .dpadLeft: return "Left pad left (click)"
        case .dpadDown: return "Left pad down (click)"
        case .back: return "Back (left arrow)"
        case .steam: return "Steam"
        case .forward: return "Start (right arrow)"
        case .leftGrip: return "Left grip paddle"
        case .rightGrip: return "Right grip paddle"
        case .leftPadClick: return "Left pad click"
        case .rightPadClick: return "Right pad click"
        case .leftPadTouch: return "Left pad touch"
        case .rightPadTouch: return "Right pad touch"
        case .stickClick: return "Stick click"
        case .stickActive: return "Stick active"
        }
    }
}

/// Live snapshot of a connected Steam Controller. Mirrors the helper's
/// output and is what `MappingEngine` reads each frame.
struct SteamControllerState {
    /// Raw 24-bit button bitfield; bit positions match
    /// `SteamControllerButton.hardwareBit`.
    var buttons: UInt32 = 0
    /// Left axis: left trackpad when the `leftPadTouch` bit is set,
    /// otherwise the stick. Range ~ -32768...32767.
    var leftX: Int16 = 0
    var leftY: Int16 = 0
    /// Right axis: always the right trackpad.
    var rightX: Int16 = 0
    var rightY: Int16 = 0
    /// 0-255 analog trigger values.
    var leftTrigger: UInt8 = 0
    var rightTrigger: UInt8 = 0
    /// Gyro / accel raw Int16 values. Not currently surfaced through the
    /// binding system; kept here so a future extension can expose them.
    var gyroX: Int16 = 0
    var gyroY: Int16 = 0
    var gyroZ: Int16 = 0
    var accelX: Int16 = 0
    var accelY: Int16 = 0
    var accelZ: Int16 = 0
    /// True if any "ready" line has arrived from the helper. Used to gate
    /// the "Steam Controller detected" indicator in the UI.
    var connected: Bool = false
}

/// Bridges `SteamControllerHelper` (separate process that reads raw Steam
/// Controller HID and disables lizard mode) into the rest of InputConfig.
/// The helper is the only piece that holds the HID device; this service
/// just parses its stdout into a thread-safe `SteamControllerState`.
final class SteamControllerService: @unchecked Sendable {
    nonisolated(unsafe) static let shared = SteamControllerService()

    private let lock = NSLock()
    private var state = SteamControllerState()

    private var process: Process?
    private var pipeOut: Pipe?
    private var pipeIn: Pipe?
    private var helperRunning = false
    private var retainCount = 0
    /// Wait before relaunching a helper that exited; doubles to 30 s and
    /// resets once a controller reports. Guarded by `lock`.
    private var relaunchDelay: TimeInterval = 1
    /// Helper exits in a row before it sent any controller state: a failed
    /// HID manager open (status 2), or a crash at launch from a signing or
    /// sandbox slip. Retrying will not change either, so after three the
    /// helper is left stopped instead of relaunched (and crash-reported)
    /// every 30 s all session.
    private var managerOpenFailures = 0
    /// This launch of the helper has sent a state line.
    private var sawStateThisLaunch = false
    /// Lizard mode off is wanted (a preset is running); sent to the helper
    /// as "L1" or "L0", and again after every relaunch.
    private var lizardOffWanted = false

    func setLizardModeOff(_ off: Bool) {
        lock.lock()
        engineWantsLizardOff = off
        lock.unlock()
        applyLizardMode()
    }

    /// While a Scan listens, the controller's own keyboard and mouse stay
    /// off whatever the engine wants: B typed Escape and canceled the scan,
    /// A typed Return and was bound as the Return key. Not while the editor
    /// is merely open, where those may be the only pointer the user has.
    func holdLizardModeOffForScan(_ hold: Bool) {
        lock.lock()
        scanHoldsLizardOff = hold
        lock.unlock()
        applyLizardMode()
    }

    private var engineWantsLizardOff = false
    private var scanHoldsLizardOff = false

    private func applyLizardMode() {
        lock.lock()
        let off = engineWantsLizardOff || scanHoldsLizardOff
        lizardOffWanted = off
        let pipe = pipeIn
        lock.unlock()
        // The throwing write: a helper that just exited is an error here,
        // not a crash (the pipe is set to raise no SIGPIPE at launch).
        try? pipe?.fileHandleForWriting.write(contentsOf: Data((off ? "L1\n" : "L0\n").utf8))
        // The 2026 model is read in the app itself, by the same rule.
        Task { @MainActor in RawHIDGamepadService.shared.setSteamController2026LizardOff(off) }
    }
    private var stdoutBuffer = Data()
    /// Last left stick and left pad values. The controller reports one of
    /// them per frame on the shared leftX/leftY fields; when both are in use
    /// (hardware bit 23) it alternates, so the other side holds its last
    /// value. Guarded by `lock`.
    private var lastStick: (Int16, Int16) = (0, 0)
    private var lastLeftPad: (Int16, Int16) = (0, 0)

    /// Captured diagnostic state for the Test Bench / Settings to surface
    /// to the user when "Steam Controller doesn't work" is reported.
    /// Every step the helper launch + handshake goes through writes here.
    struct Diagnostics {
        var helperPath: String?
        var helperBundled: Bool = false
        var helperLaunched: Bool = false
        var helperLaunchError: String?
        var helperPID: Int32?
        var totalStdoutLines: Int = 0
        var lastStdoutLineAt: Date?
        var lastStdoutLineSample: String?
        var readyHandshakeReceived: Bool = false
        var firstStateLineReceived: Bool = false
        var lastDiagnosticUpdate: Date = Date()
    }

    private var _diagnostics = Diagnostics()

    /// Thread-safe snapshot of the helper's current state for diagnostics.
    func diagnostics() -> Diagnostics {
        lock.lock(); defer { lock.unlock() }
        return _diagnostics
    }

    private init() {}

    // MARK: - Lifecycle

    func retain() {
        // Serialize retain/release under the same lock that guards
        // state, otherwise two concurrent callers can both observe
        // retainCount==0, both call start(), and we spawn two helper
        // processes (the second one leaks the first's Process handle).
        lock.lock()
        retainCount += 1
        let shouldStart = (retainCount == 1)
        lock.unlock()
        if shouldStart { start() }
    }

    func release() {
        lock.lock()
        retainCount = max(0, retainCount - 1)
        let shouldStop = (retainCount == 0)
        lock.unlock()
        if shouldStop { stop() }
    }

    /// Called from the EOF branch of the stdout readabilityHandler.
    /// Flips the connected flag back to false so the chip/banner UI
    /// stops reporting a phantom Steam Controller after the helper
    /// has exited unexpectedly. Idempotent; no-op if state was
    /// already disconnected.
    fileprivate func markHelperDisconnected() {
        lock.lock()
        if state.connected {
            state = SteamControllerState()
        }
        lock.unlock()
    }

    private func start() {
        lock.lock(); let alreadyRunning = helperRunning; lock.unlock()
        guard !alreadyRunning else { return }
        let resolvedPath = helperPath()

        lock.lock()
        _diagnostics.helperPath = resolvedPath?.path
        _diagnostics.helperBundled = (resolvedPath != nil)
        _diagnostics.lastDiagnosticUpdate = Date()
        lock.unlock()

        guard let helperURL = resolvedPath else {
            let msg = "SteamControllerHelper not found in the app bundle. The Copy Helpers build phase may have been removed, or this is an App Store build where the helper was stripped."
            lock.lock()
            _diagnostics.helperLaunchError = msg
            lock.unlock()
            NSLog("SteamControllerService: \(msg)")
            return
        }
        let p = Process()
        p.executableURL = helperURL
        let outPipe = Pipe()
        let inPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = inPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // CRITICAL: empty data from a readabilityHandler is the EOF
            // signal (the helper exited - typically because no Steam
            // Controller is connected). If we DON'T detach the handler
            // here, libdispatch keeps invoking it at the dispatcher's
            // discretion which can pin a CPU thread at 100% spinning on
            // a closed pipe. The bug previously surfaced as the entire
            // app sitting at ~100% CPU after launch even when idle.
            if data.isEmpty {
                handle.readabilityHandler = nil
                // Also clear the connected state so the UI doesn't
                // keep showing "Steam Controller detected" forever
                // after the helper crashes or exits. Previous version
                // detached the handler but left `state.connected = true`
                // sticky until the next retain/release cycle.
                self?.markHelperDisconnected()
                return
            }
            self?.consumeStdout(data)
        }
        do {
            try p.run()
            lock.lock()
            process = p
            pipeOut = outPipe
            pipeIn = inPipe
            helperRunning = true
            sawStateThisLaunch = false
            let off = lizardOffWanted
            lock.unlock()
            _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            if off { try? inPipe.fileHandleForWriting.write(contentsOf: Data("L1\n".utf8)) }
            // Detect the helper dying on its own (sandbox kill, crash, or its
            // own exit on a device-open miss). Without this, helperRunning
            // stayed true forever and start()'s `guard !helperRunning` blocked
            // any relaunch until a full release-to-zero then retain cycle.
            p.terminationHandler = { [weak self] proc in
                guard let self = self else { return }
                self.lock.lock()
                // Only clear state if this is still the current helper, so a
                // fast restart can't have the old helper's handler clobber a
                // newer live one.
                let isCurrent = (self.process === proc)
                if isCurrent {
                    self.helperRunning = false
                    self.process = nil
                    self.pipeOut = nil
                    self.pipeIn = nil
                }
                if isCurrent {
                    self.managerOpenFailures = self.sawStateThisLaunch ? 0 : self.managerOpenFailures + 1
                    if self.managerOpenFailures >= 3 {
                        let how = proc.terminationReason == .uncaughtSignal
                            ? "signal \(proc.terminationStatus)" : "status \(proc.terminationStatus)"
                        self._diagnostics.helperLaunchError = "Helper stopped after exiting three times in a row (\(how)); not relaunched"
                    }
                }
                let wanted = self.retainCount > 0 && self.managerOpenFailures < 3
                let delay = self.relaunchDelay
                if isCurrent && wanted { self.relaunchDelay = min(delay * 2, 30) }
                self.lock.unlock()
                if isCurrent { self.markHelperDisconnected() }
                // Still wanted: start it again, backing off. It used to stay
                // gone until every user let go and asked again.
                if isCurrent && wanted {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self else { return }
                        self.lock.lock()
                        let go = self.retainCount > 0 && !self.helperRunning
                        self.lock.unlock()
                        if go { self.start() }
                    }
                }
            }
            lock.lock()
            _diagnostics.helperLaunched = true
            _diagnostics.helperPID = p.processIdentifier
            _diagnostics.helperLaunchError = nil
            _diagnostics.lastDiagnosticUpdate = Date()
            lock.unlock()
        } catch {
            let msg = "Helper launch failed: \(error.localizedDescription)"
            lock.lock()
            _diagnostics.helperLaunchError = msg
            _diagnostics.lastDiagnosticUpdate = Date()
            lock.unlock()
            NSLog("SteamControllerService: \(msg)")
        }
    }

    private func stop() {
        // Snapshot and clear the shared handles under the lock (the
        // terminationHandler mutates the same fields under the same lock), then
        // do the blocking close/terminate calls outside the lock.
        lock.lock()
        guard helperRunning else { lock.unlock(); return }
        helperRunning = false
        let po = pipeOut, pi = pipeIn, p = process
        process = nil
        pipeOut = nil
        pipeIn = nil
        state = SteamControllerState()
        lock.unlock()

        po?.fileHandleForReading.readabilityHandler = nil
        try? pi?.fileHandleForWriting.close()
        if let p = p, p.isRunning {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                if p.isRunning { p.terminate() }
            }
        }
    }

    // MARK: - Consumer API

    /// Thread-safe snapshot of the latest state.
    func currentState() -> SteamControllerState {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    /// True while a Steam Controller is connected and the helper has emitted
    /// at least one valid input report. Mirrors GCController's "connected"
    /// semantics so callers can branch on it like any other controller.
    var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return state.connected
    }

    // MARK: - Test injection

    /// True while a synthetic state is overriding the real helper output.
    /// Set by `simulate*` methods; reset to false by `endSimulation()`.
    private(set) var isSimulating: Bool = false

    /// Inject a fully-formed synthetic state for testing. Marks `connected`
    /// true so the engine reads from us as if the helper were running.
    /// Use this to exercise the Steam Controller pipeline without real
    /// hardware: write a state, give the 120 Hz engine poll a few frames
    /// to see it, then call `endSimulation()` to clear.
    func injectTestState(_ s: SteamControllerState) {
        lock.lock()
        var simulated = s
        simulated.connected = true
        state = simulated
        isSimulating = true
        lock.unlock()
    }

    /// Convenience: simulate a single Steam Controller button held down for
    /// the duration of the call's enclosing scope. The button index is the
    /// `SteamControllerButton.bindingIndex` (rawValue 0...22).
    func simulateButtonDown(_ button: SteamControllerButton) {
        lock.lock()
        var simulated = state
        simulated.buttons |= button.hardwareMask
        simulated.connected = true
        state = simulated
        isSimulating = true
        lock.unlock()
    }

    /// Releases a previously-pressed simulated button.
    func simulateButtonUp(_ button: SteamControllerButton) {
        lock.lock()
        var simulated = state
        simulated.buttons &= ~button.hardwareMask
        state = simulated
        lock.unlock()
    }

    /// Clears any simulated state and goes back to whatever the helper
    /// (if running) reports. If the helper isn't running, marks disconnected.
    func endSimulation() {
        lock.lock()
        // Only a simulation is cleared: called with none running (the Test
        // Bench calls it first to be safe), it wiped a real controller's
        // state and showed it disconnected until the next report.
        if isSimulating {
            state = SteamControllerState()
            isSimulating = false
        }
        lock.unlock()
    }

    // MARK: - Stdout parsing

    private func consumeStdout(_ chunk: Data) {
        stdoutBuffer.append(chunk)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<nl)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            if let line = String(data: lineData, encoding: .utf8) {
                handleLine(line)
            }
        }
        // Hard cap to catch a malformed helper run that never emits a
        // newline. Each state line is well under 256 bytes; 64 KB of
        // garbage means the helper is broken and we should drop it.
        // Without this guard a buggy helper could grow stdoutBuffer
        // unbounded over a long session and consume hundreds of MB.
        if stdoutBuffer.count > 65_536 {
            NSLog("SteamControllerService: stdoutBuffer exceeded 64 KB without a newline; truncating")
            stdoutBuffer.removeAll(keepingCapacity: false)
        }
    }

    /// Lines:
    ///   "R ready"
    ///   "W 1" / "W 0" (dongle: controller connected / disconnected)
    ///   "S <seq> <buttonsHex> <lx> <ly> <rx> <ry> <lt> <rt> \
    ///      <gx> <gy> <gz> <ax> <ay> <az>"
    private func handleLine(_ line: String) {
        lock.lock()
        _diagnostics.totalStdoutLines += 1
        _diagnostics.lastStdoutLineAt = Date()
        _diagnostics.lastStdoutLineSample = String(line.prefix(120))
        _diagnostics.lastDiagnosticUpdate = Date()
        lock.unlock()

        // Wireless dongle connect / disconnect. Clear inputs on disconnect so
        // nothing stays held when the controller powers off mid-press.
        if line == "W 0" || line == "W 1" {
            lock.lock()
            state = SteamControllerState()
            state.connected = (line == "W 1")
            lastStick = (0, 0)
            lastLeftPad = (0, 0)
            lock.unlock()
            return
        }
        // The device went away (unplugged, dongle removed).
        if line == "D" {
            lock.lock()
            state = SteamControllerState()
            lastStick = (0, 0)
            lastLeftPad = (0, 0)
            lock.unlock()
            return
        }
        if line.hasPrefix("R ") {
            // The helper opened the device; not yet a controller. A bare
            // dongle says this too, and treating it as connected made a
            // slot for a controller that was not there. The first state
            // line connects it.
            lock.lock()
            _diagnostics.readyHandshakeReceived = true
            lock.unlock()
            return
        }
        let parts = line.split(separator: " ").map(String.init)
        guard parts.first == "S", parts.count >= 14,
              let reportedButtons = UInt32(parts[2], radix: 16),
              let lx = Int16(parts[3]),
              let ly = Int16(parts[4]),
              let rx = Int16(parts[5]),
              let ry = Int16(parts[6]),
              let lt = UInt8(parts[7]),
              let rt = UInt8(parts[8]),
              let gx = Int16(parts[9]),
              let gy = Int16(parts[10]),
              let gz = Int16(parts[11]),
              let ax = Int16(parts[12]),
              let ay = Int16(parts[13]) else { return }
        // Optional 15th field (accelZ); some lines may truncate.
        let az = parts.count >= 15 ? (Int16(parts[14]) ?? 0) : 0

        // Older firmware reports a click of the stick as a left-pad click
        // while no finger is on the pad (SDL_hidapi_steam.c does the same
        // remap): with neither the pad nor the pad-and-stick bit set, that
        // click is the stick's.
        var buttonsHex = reportedButtons
        let padClick = SteamControllerButton.leftPadClick.hardwareMask
        if buttonsHex & SteamControllerButton.leftPadTouch.hardwareMask == 0,
           buttonsHex & SteamControllerButton.stickActive.hardwareMask == 0,
           buttonsHex & padClick != 0 {
            buttonsHex = (buttonsHex & ~padClick) | SteamControllerButton.stickClick.hardwareMask
        }

        lock.lock()
        state.buttons = buttonsHex
        state.leftX = lx
        state.leftY = ly
        // Which source this frame's left X and Y belong to, per report. Sorted out only when a reader polled, so with the
        // stick and the left pad both in use the poll kept landing on the
        // same kind of frame and the other side lagged in bursts.
        let padFrame = (buttonsHex & SteamControllerButton.leftPadTouch.hardwareMask) != 0
        let padAndStick = (buttonsHex & SteamControllerButton.stickActive.hardwareMask) != 0
        if padFrame {
            lastLeftPad = (lx, ly)
            if !padAndStick { lastStick = (0, 0) }
        } else {
            lastStick = (lx, ly)
            if !padAndStick { lastLeftPad = (0, 0) }
        }
        state.rightX = rx
        state.rightY = ry
        state.leftTrigger = lt
        state.rightTrigger = rt
        state.gyroX = gx
        state.gyroY = gy
        state.gyroZ = gz
        state.accelX = ax
        state.accelY = ay
        state.accelZ = az
        state.connected = true
        relaunchDelay = 1
        managerOpenFailures = 0
        sawStateThisLaunch = true
        _diagnostics.firstStateLineReceived = true
        lock.unlock()
    }

    // MARK: - Helper discovery

    private func helperPath() -> URL? {
        if let bundlePath = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("SteamControllerHelper"),
           FileManager.default.isExecutableFile(atPath: bundlePath.path) {
            return bundlePath
        }
        if let resourcePath = Bundle.main.url(forResource: "SteamControllerHelper", withExtension: nil) {
            return resourcePath
        }
        // Development builds only: #filePath would put the developer's
        // source path into a release binary.
        #if DEBUG
        let devPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SteamControllerHelper/SteamControllerHelper")
        if FileManager.default.isExecutableFile(atPath: devPath.path) {
            return devPath
        }
        #endif
        return nil
    }
}

// MARK: - Mapping engine adapter

extension SteamControllerService {
    /// Convert the latest Steam Controller snapshot into a `ControllerState`
    /// that the mapping engine can consume the same way it consumes
    /// GCController data.
    ///
    /// Axis layout (chosen so existing MFi presets keep working AND the
    /// Steam Controller's extra surfaces are independently bindable):
    ///   0 / 1 : analog thumbstick X / Y       (left side)
    ///   2 / 3 : right trackpad X / Y          (always the right pad)
    ///   4 / 5 : left trigger / right trigger
    ///   6 / 7 : left trackpad X / Y           (Steam Controller specific)
    ///
    /// The Steam Controller multiplexes leftX/leftY between the analog
    /// stick and the left trackpad, as SDL_hidapi_steam.c reads it:
    /// bit 19 (left pad touched) means the frame carries pad coordinates,
    /// otherwise stick coordinates; bit 23 means both are in use, so the
    /// other source keeps its last value instead of dropping to zero. A
    /// binding to axis 0 only fires from the stick and a binding to axis 6
    /// only fires from the left pad.
    func makeControllerState() -> ControllerState {
        let s = currentState()
        var st = ControllerState()
        // Buttons: binding index -> hardware bit.
        for button in SteamControllerButton.allCases {
            st.buttons[button.bindingIndex] = (s.buttons & button.hardwareMask) != 0 ? 1.0 : 0.0
        }
        let padFrame = (s.buttons & SteamControllerButton.leftPadTouch.hardwareMask) != 0
        let padAndStick = (s.buttons & SteamControllerButton.stickActive.hardwareMask) != 0
        // The left pad counts as touched when either bit is set.
        st.buttons[SteamControllerButton.leftPadTouch.bindingIndex] = (padFrame || padAndStick) ? 1.0 : 0.0

        // The stick and pad values were split per report in handleLine.
        lock.lock()
        let stick = lastStick
        let pad = lastLeftPad
        lock.unlock()

        // Stick axes.
        st.axes[0] = Float(stick.0) / 32767.0
        st.axes[1] = -Float(stick.1) / 32767.0
        // Right trackpad - always the right side, no multiplexing.
        st.axes[2] = Float(s.rightX) / 32767.0
        st.axes[3] = -Float(s.rightY) / 32767.0
        // Triggers.
        st.axes[4] = Float(s.leftTrigger) / 255.0
        st.axes[5] = Float(s.rightTrigger) / 255.0
        // Left trackpad.
        st.axes[6] = Float(pad.0) / 32767.0
        st.axes[7] = -Float(pad.1) / 32767.0
        // Hat: synthesize from D-pad bits so existing hat-based bindings
        // work. A four-direction hat is enough.
        let up = (s.buttons & SteamControllerButton.dpadUp.hardwareMask) != 0
        let dn = (s.buttons & SteamControllerButton.dpadDown.hardwareMask) != 0
        let lf = (s.buttons & SteamControllerButton.dpadLeft.hardwareMask) != 0
        let rt = (s.buttons & SteamControllerButton.dpadRight.hardwareMask) != 0
        var hx: Float = 0, hy: Float = 0
        if lf { hx -= 1 }
        if rt { hx += 1 }
        if up { hy += 1 }
        if dn { hy -= 1 }
        st.hats[0] = (hx, hy)
        return st
    }
}
