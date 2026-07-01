import Foundation

/// Steam Controller button bit positions inside the 32-bit button field
/// emitted by `SteamControllerHelper`. The Steam Controller exposes more
/// buttons than a standard MFi gamepad (two trackpad clicks, two grip
/// paddles, the Steam button, etc.), so we map them to indices 0-22 in our
/// own scheme rather than overloading the existing MFi numbering.
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
    case stickClick = 21     // L3 - clicked the analog stick
    case stickActive = 22    // device reporting stick (vs trackpad) on left axis

    /// InputConfig binding index. We map onto the same 0-22 space; this
    /// keeps preset JSON readable ("btn 5 = B button").
    var bindingIndex: Int { rawValue }

    var displayName: String {
        switch self {
        case .rightTrigger: return "RT digital"
        case .leftTrigger: return "LT digital"
        case .rightBumper: return "RB"
        case .leftBumper: return "LB"
        case .y: return "Y"
        case .b: return "B"
        case .x: return "X"
        case .a: return "A"
        case .dpadUp: return "D-pad up"
        case .dpadRight: return "D-pad right"
        case .dpadLeft: return "D-pad left"
        case .dpadDown: return "D-pad down"
        case .back: return "Back"
        case .steam: return "Steam"
        case .forward: return "Forward"
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
    /// 32-bit button bitfield; bit positions match `SteamControllerButton`.
    var buttons: UInt32 = 0
    /// Left axis: stick when `stickActive` bit is set, otherwise left
    /// trackpad. Range ~ -32768...32767.
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
    private var stdoutBuffer = Data()

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
            lock.unlock()
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
                self.lock.unlock()
                if isCurrent { self.markHelperDisconnected() }
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
        simulated.buttons |= (UInt32(1) << UInt32(button.rawValue))
        simulated.connected = true
        state = simulated
        isSimulating = true
        lock.unlock()
    }

    /// Releases a previously-pressed simulated button.
    func simulateButtonUp(_ button: SteamControllerButton) {
        lock.lock()
        var simulated = state
        simulated.buttons &= ~(UInt32(1) << UInt32(button.rawValue))
        state = simulated
        lock.unlock()
    }

    /// Clears any simulated state and goes back to whatever the helper
    /// (if running) reports. If the helper isn't running, marks disconnected.
    func endSimulation() {
        lock.lock()
        state = SteamControllerState()
        isSimulating = false
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
    ///   "S <seq> <buttonsHex> <lx> <ly> <rx> <ry> <lt> <rt> \
    ///      <gx> <gy> <gz> <ax> <ay> <az>"
    private func handleLine(_ line: String) {
        lock.lock()
        _diagnostics.totalStdoutLines += 1
        _diagnostics.lastStdoutLineAt = Date()
        _diagnostics.lastStdoutLineSample = String(line.prefix(120))
        _diagnostics.lastDiagnosticUpdate = Date()
        lock.unlock()

        if line.hasPrefix("R ") {
            lock.lock()
            state.connected = true
            _diagnostics.readyHandshakeReceived = true
            lock.unlock()
            return
        }
        let parts = line.split(separator: " ").map(String.init)
        guard parts.first == "S", parts.count >= 14,
              let buttonsHex = UInt32(parts[2], radix: 16),
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

        lock.lock()
        state.buttons = buttonsHex
        state.leftX = lx
        state.leftY = ly
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
        let devPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SteamControllerHelper/SteamControllerHelper")
        if FileManager.default.isExecutableFile(atPath: devPath.path) {
            return devPath
        }
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
    /// stick and the left trackpad based on the `stickActive` bit; we
    /// route the raw values into either the stick axes OR the left-pad
    /// axes here so a binding to axis 0 only fires from the stick and a
    /// binding to axis 6 only fires from the left pad - never both.
    func makeControllerState() -> ControllerState {
        let s = currentState()
        var st = ControllerState()
        // Buttons
        for bit in 0..<23 {
            let on: Float = (s.buttons & (1 << UInt32(bit))) != 0 ? 1.0 : 0.0
            st.buttons[bit] = on
        }
        let stickIsActive = (s.buttons & (1 << UInt32(SteamControllerButton.stickActive.rawValue))) != 0

        // Stick axes - only populated when the stick is the active source.
        if stickIsActive {
            st.axes[0] = Float(s.leftX) / 32767.0
            st.axes[1] = -Float(s.leftY) / 32767.0
        } else {
            st.axes[0] = 0
            st.axes[1] = 0
        }
        // Right trackpad - always the right side, no multiplexing.
        st.axes[2] = Float(s.rightX) / 32767.0
        st.axes[3] = -Float(s.rightY) / 32767.0
        // Triggers.
        st.axes[4] = Float(s.leftTrigger) / 255.0
        st.axes[5] = Float(s.rightTrigger) / 255.0
        // Left trackpad - only populated when the stick is NOT active so
        // an "axis 6 right" binding never spuriously fires from stick
        // motion and vice-versa.
        if !stickIsActive {
            st.axes[6] = Float(s.leftX) / 32767.0
            st.axes[7] = -Float(s.leftY) / 32767.0
        } else {
            st.axes[6] = 0
            st.axes[7] = 0
        }
        // Hat: synthesize from D-pad bits so existing hat-based bindings
        // work. A four-direction hat is enough.
        let up = (s.buttons & (1 << UInt32(SteamControllerButton.dpadUp.rawValue))) != 0
        let dn = (s.buttons & (1 << UInt32(SteamControllerButton.dpadDown.rawValue))) != 0
        let lf = (s.buttons & (1 << UInt32(SteamControllerButton.dpadLeft.rawValue))) != 0
        let rt = (s.buttons & (1 << UInt32(SteamControllerButton.dpadRight.rawValue))) != 0
        var hx: Float = 0, hy: Float = 0
        if lf { hx -= 1 }
        if rt { hx += 1 }
        if up { hy += 1 }
        if dn { hy -= 1 }
        st.hats[0] = (hx, hy)
        return st
    }
}
