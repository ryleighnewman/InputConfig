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

    /// JoystickConfig binding index. We map onto the same 0-22 space; this
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
/// Controller HID and disables lizard mode) into the rest of JoystickConfig.
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

    private init() {}

    // MARK: - Lifecycle

    func retain() {
        retainCount += 1
        if retainCount == 1 { start() }
    }

    func release() {
        retainCount = max(0, retainCount - 1)
        if retainCount == 0 { stop() }
    }

    private func start() {
        guard !helperRunning else { return }
        guard let helperURL = helperPath() else {
            #if DEBUG
            print("[SteamControllerService] SteamControllerHelper not found in bundle")
            #endif
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
            guard !data.isEmpty else { return }
            self?.consumeStdout(data)
        }
        do {
            try p.run()
            process = p
            pipeOut = outPipe
            pipeIn = inPipe
            helperRunning = true
        } catch {
            #if DEBUG
            print("[SteamControllerService] Helper launch failed: \(error)")
            #endif
        }
    }

    private func stop() {
        guard helperRunning else { return }
        helperRunning = false
        pipeOut?.fileHandleForReading.readabilityHandler = nil
        try? pipeIn?.fileHandleForWriting.close()
        if let p = process, p.isRunning {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                if p.isRunning { p.terminate() }
            }
        }
        process = nil
        pipeOut = nil
        pipeIn = nil
        lock.lock()
        state = SteamControllerState()
        lock.unlock()
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
    }

    /// Lines:
    ///   "R ready"
    ///   "S <seq> <buttonsHex> <lx> <ly> <rx> <ry> <lt> <rt> \
    ///      <gx> <gy> <gz> <ax> <ay> <az>"
    private func handleLine(_ line: String) {
        if line.hasPrefix("R ") {
            lock.lock()
            state.connected = true
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
    /// GCController data. Buttons map 1:1 to indices 0-22, axes map to the
    /// MFi axis indices (0=LX, 1=LY, 2=RX, 3=RY, 4=LT, 5=RT) so existing
    /// presets can target the Steam Controller without a separate axis space.
    func makeControllerState() -> ControllerState {
        let s = currentState()
        var st = ControllerState()
        // Buttons
        for bit in 0..<23 {
            let on: Float = (s.buttons & (1 << UInt32(bit))) != 0 ? 1.0 : 0.0
            st.buttons[bit] = on
        }
        // Axes - Int16 -> Float in [-1, 1]. The left axis is either stick
        // (when stickActive is set) or trackpad; both ranges are the same
        // Int16 span, so the conversion is identical.
        st.axes[0] = Float(s.leftX) / 32767.0
        st.axes[1] = -Float(s.leftY) / 32767.0
        st.axes[2] = Float(s.rightX) / 32767.0
        st.axes[3] = -Float(s.rightY) / 32767.0
        st.axes[4] = Float(s.leftTrigger) / 255.0
        st.axes[5] = Float(s.rightTrigger) / 255.0
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
