import Foundation

/// Per-controller calibration. The user runs a calibration sweep once: as
/// they cover the surface, we record the min/max X/Y their finger actually
/// reaches. We then remap deltas so a "full sweep" of the calibrated area
/// equals one normalized unit, instead of using the nominal 1920×1080 box.
struct TouchpadCalibration: Codable, Hashable {
    var minX: Int
    var maxX: Int
    var minY: Int
    var maxY: Int
    /// Wall-clock time the calibration was last persisted. nil for the
    /// sentinel uncalibrated value; non-nil whenever the user has saved.
    /// Decoded leniently - older saves without this key still load fine.
    var savedAt: Date?
    /// Flat-packed grid of "touched" cells from the calibration UI. Stored
    /// row-major (col + row * cols). Optional so older saves without this
    /// key still decode and produce an empty grid. The size in the file
    /// drives the on-screen layout; we ship 12×7 by default but the view
    /// is permissive about the dimensions it gets back.
    var gridCells: [Bool]?

    var spanX: Int { max(1, maxX - minX) }
    var spanY: Int { max(1, maxY - minY) }

    /// Sentinel "not yet calibrated" value covering the full nominal range
    /// of a DualSense / DualShock touchpad.
    static let uncalibrated = TouchpadCalibration(minX: 0, maxX: 1919, minY: 0, maxY: 1079, savedAt: nil, gridCells: nil)

    /// True when the user has actually done a calibration sweep (i.e. the
    /// stored bounds differ from the uncalibrated sentinel OR a savedAt was
    /// ever recorded).
    var isUserCalibrated: Bool {
        savedAt != nil ||
            !(minX == TouchpadCalibration.uncalibrated.minX
              && maxX == TouchpadCalibration.uncalibrated.maxX
              && minY == TouchpadCalibration.uncalibrated.minY
              && maxY == TouchpadCalibration.uncalibrated.maxY)
    }
}

/// A user-defined zone on the touchpad surface. Coordinates are normalized
/// 0...1 so they survive different controllers / calibration changes. When
/// a finger enters the region, the region becomes "pressed" and binding
/// inputs of type `.touchpadRegion` referencing this region fire as if a
/// button was pushed.
struct TouchpadRegion: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    /// Normalized rectangle. minX/maxX in [0, 1], same for Y. Y=0 is the
    /// top of the touchpad (matches the helper's coordinate convention).
    var minX: Double
    var maxX: Double
    var minY: Double
    var maxY: Double
    /// Color index (0..colorPalette.count-1) used for UI rendering. Each
    /// new region cycles through the palette so they're easy to tell apart.
    var colorIndex: Int

    /// Color palette regions cycle through. Kept in the model so it
    /// survives serialization and the UI doesn't need a separate lookup.
    static let colorPalette: [String] = ["mint", "cyan", "pink", "orange",
                                         "yellow", "purple", "indigo", "green"]

    init(id: UUID = UUID(), name: String, minX: Double, maxX: Double,
         minY: Double, maxY: Double, colorIndex: Int = 0) {
        self.id = id
        self.name = name
        self.minX = min(minX, maxX)
        self.maxX = max(minX, maxX)
        self.minY = min(minY, maxY)
        self.maxY = max(minY, maxY)
        self.colorIndex = colorIndex
    }

    /// Test whether the normalized point is inside this region.
    func contains(normalizedX: Double, y: Double) -> Bool {
        normalizedX >= minX && normalizedX <= maxX &&
        y >= minY && y <= maxY
    }
}

/// Bridges `TouchpadHelper` (a separate process that reads raw HID input
/// reports from DualSense / DualShock 4 controllers) into the rest of the
/// app. The main app cannot read those bytes directly without breaking
/// `gamecontrolleragentd`'s grip on the device, so we spawn the helper which
/// opens the HID device WITHOUT seizing, parses the touchpad bytes, and
/// emits them line-by-line on stdout.
///
/// `MappingEngine` pulls the latest per-finger delta out of `consumeDelta(...)`
/// each frame. The "consume" naming is deliberate: the call resets the
/// accumulator so a slow caller cannot accidentally double-count motion.
final class TouchpadService: @unchecked Sendable {
    nonisolated(unsafe) static let shared = TouchpadService()

    /// Per-finger normalized delta-since-last-consume. Values are in roughly
    /// [-1, 1] but can exceed it on a fast swipe; consumers clamp.
    struct FingerDelta {
        var dx: Float = 0
        var dy: Float = 0
        var active: Bool = false
    }

    private let lock = NSLock()
    private var finger0Delta = FingerDelta()
    private var finger1Delta = FingerDelta()

    /// Most recent finger position keyed by (finger, contactId). Used to
    /// compute deltas. We track contactId so that finger-lift / finger-replace
    /// resets the baseline instead of producing a huge jump on touchdown.
    private var lastF0Pos: (id: UInt8, x: Int, y: Int)?
    private var lastF1Pos: (id: UInt8, x: Int, y: Int)?

    private var process: Process?
    private var pipeOut: Pipe?
    private var pipeIn: Pipe?
    private var helperRunning = false

    /// Reference count: the helper subprocess stays alive while at least one
    /// caller has retained it. MappingEngine retains while a touchpad-using
    /// preset is active; the calibration UI retains while open.
    private var retainCount = 0

    /// Touchpad surface dimensions in helper-emitted native units. We use the
    /// larger DualSense bounds; DS4 reports slightly smaller Y, which still
    /// normalizes correctly since deltas are unit-divided.
    private let surfaceWidth: Float = 1920
    private let surfaceHeight: Float = 1080

    /// Currently active calibration. Loaded from UserDefaults at init; saved
    /// when the calibration view writes a new sweep.
    private var calibration: TouchpadCalibration = .uncalibrated
    private static let calibrationKey = "JoystickConfig.touchpadCalibration.v1"

    /// User-defined regions for tap-style mapping. Persisted alongside
    /// calibration so they survive app restarts.
    private var regions: [TouchpadRegion] = []
    private static let regionsKey = "JoystickConfig.touchpadRegions.v1"

    /// Region IDs currently being touched by any finger. Updated whenever a
    /// finger position changes; consumed by MappingEngine's checkInput.
    private var pressedRegions: Set<UUID> = []

    /// Latest absolute finger positions, used by the calibration view to
    /// paint touched cells. Reset on finger lift.
    private var currentF0: (x: Int, y: Int)?
    private var currentF1: (x: Int, y: Int)?

    private init() {
        loadCalibration()
        loadRegions()
    }

    // MARK: - Lifecycle

    /// Increment the helper's retain count. Spawns the subprocess on the
    /// first retain. Pair every call with `release()`.
    func retain() {
        retainCount += 1
        if retainCount == 1 { start() }
    }

    /// Decrement the helper's retain count. Stops the subprocess when it
    /// drops to zero.
    func release() {
        retainCount = max(0, retainCount - 1)
        if retainCount == 0 { stop() }
    }

    /// Start the helper if not already running. Safe to call multiple times.
    func start() {
        guard !helperRunning else { return }
        guard let helperURL = helperPath() else {
            #if DEBUG
            print("[TouchpadService] TouchpadHelper not found in bundle")
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
            print("[TouchpadService] Helper launch failed: \(error)")
            #endif
        }
    }

    /// Stop the helper. Closes the stdin pipe; the helper exits when it
    /// observes that closure. Falls back to SIGTERM after a short grace.
    func stop() {
        guard helperRunning else { return }
        helperRunning = false

        pipeOut?.fileHandleForReading.readabilityHandler = nil
        try? pipeIn?.fileHandleForWriting.close()

        if let p = process, p.isRunning {
            // Give it ~100ms to exit cleanly via stdin EOF, then terminate.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                if p.isRunning { p.terminate() }
            }
        }
        process = nil
        pipeOut = nil
        pipeIn = nil

        lock.lock()
        finger0Delta = FingerDelta()
        finger1Delta = FingerDelta()
        lastF0Pos = nil
        lastF1Pos = nil
        lock.unlock()
    }

    // MARK: - Consumer API (MappingEngine)

    /// Read & clear the accumulated delta for the given finger and axis.
    /// Returns a value normalized so `1.0` corresponds to one full sweep of
    /// the *calibrated* surface in a single frame.
    func consumeDelta(finger: Int, axis: TouchpadAxis) -> Float {
        lock.lock()
        defer { lock.unlock() }

        let key = finger == 1 ? 1 : 0
        var d = key == 0 ? finger0Delta : finger1Delta
        let value: Float
        switch axis {
        case .x:
            value = d.dx / Float(calibration.spanX)
            d.dx = 0
        case .y:
            value = d.dy / Float(calibration.spanY)
            d.dy = 0
        }
        if key == 0 { finger0Delta = d } else { finger1Delta = d }
        return value
    }

    /// True while the given finger is in contact with the touchpad.
    func isFingerActive(_ finger: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (finger == 1 ? finger1Delta : finger0Delta).active
    }

    /// Latest absolute (x, y) of the given finger in device-native units, or
    /// nil if the finger is not currently in contact. Used by the calibration
    /// view to draw a live cursor and to mark touched grid cells.
    func currentPosition(finger: Int) -> (x: Int, y: Int)? {
        lock.lock(); defer { lock.unlock() }
        return finger == 1 ? currentF1 : currentF0
    }

    /// Device-native touchpad bounds (DualSense values; DS4 is similar).
    var nominalSurfaceSize: (width: Int, height: Int) {
        (Int(surfaceWidth), Int(surfaceHeight))
    }

    // MARK: - Calibration

    func currentCalibration() -> TouchpadCalibration {
        lock.lock(); defer { lock.unlock() }
        return calibration
    }

    /// Persist a new calibration. Pass `.uncalibrated` to reset to defaults.
    /// Writes to BOTH `UserDefaults` and a JSON file in Application Support
    /// so that even if one storage layer hiccups (UserDefaults sync timing,
    /// container migration), the other will recover the value on next launch.
    func saveCalibration(_ new: TouchpadCalibration) {
        var stamped = new
        // Don't stamp the uncalibrated sentinel - that's a reset, not a save.
        if !(new.minX == TouchpadCalibration.uncalibrated.minX
             && new.maxX == TouchpadCalibration.uncalibrated.maxX
             && new.minY == TouchpadCalibration.uncalibrated.minY
             && new.maxY == TouchpadCalibration.uncalibrated.maxY) {
            stamped.savedAt = Date()
        }
        lock.lock()
        calibration = stamped
        lock.unlock()
        guard let data = try? JSONEncoder().encode(stamped) else { return }
        UserDefaults.standard.set(data, forKey: Self.calibrationKey)
        try? data.write(to: Self.calibrationFileURL, options: .atomic)
        #if DEBUG
        print("[TouchpadService] saved calibration: X \(stamped.minX)-\(stamped.maxX) Y \(stamped.minY)-\(stamped.maxY) at \(String(describing: stamped.savedAt)) → \(Self.calibrationFileURL.path)")
        #endif
    }

    private func loadCalibration() {
        // Prefer the on-disk file (more reliable across container migrations),
        // fall back to UserDefaults for older installs.
        if let data = try? Data(contentsOf: Self.calibrationFileURL),
           let decoded = try? JSONDecoder().decode(TouchpadCalibration.self, from: data) {
            calibration = decoded
            #if DEBUG
            print("[TouchpadService] loaded calibration from file: X \(decoded.minX)-\(decoded.maxX) Y \(decoded.minY)-\(decoded.maxY)")
            #endif
            return
        }
        if let data = UserDefaults.standard.data(forKey: Self.calibrationKey),
           let decoded = try? JSONDecoder().decode(TouchpadCalibration.self, from: data) {
            calibration = decoded
            // Promote to the file store so future reads use the canonical path.
            try? data.write(to: Self.calibrationFileURL, options: .atomic)
            #if DEBUG
            print("[TouchpadService] loaded calibration from UserDefaults: X \(decoded.minX)-\(decoded.maxX) Y \(decoded.minY)-\(decoded.maxY)")
            #endif
        }
    }

    /// On-disk calibration location. Lives in the same Application Support
    /// directory as presets so it's covered by the Export Backup feature.
    private static let calibrationFileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("JoystickConfig", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("touchpadCalibration.json")
    }()

    // MARK: - Regions

    /// Snapshot of the current region list. UI iterates over this.
    func allRegions() -> [TouchpadRegion] {
        lock.lock(); defer { lock.unlock() }
        return regions
    }

    /// Look up a region by ID. Returns nil if it's been deleted.
    func region(with id: UUID) -> TouchpadRegion? {
        lock.lock(); defer { lock.unlock() }
        return regions.first(where: { $0.id == id })
    }

    /// True when any finger is currently inside the region.
    func isRegionPressed(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return pressedRegions.contains(id)
    }

    /// Replace the region list and persist. UI calls this after add / edit /
    /// delete operations.
    func saveRegions(_ newRegions: [TouchpadRegion]) {
        lock.lock()
        regions = newRegions
        // Drop pressed-state entries for regions that no longer exist.
        pressedRegions = pressedRegions.filter { id in newRegions.contains(where: { $0.id == id }) }
        lock.unlock()
        if let data = try? JSONEncoder().encode(newRegions) {
            UserDefaults.standard.set(data, forKey: Self.regionsKey)
        }
    }

    private func loadRegions() {
        if let data = UserDefaults.standard.data(forKey: Self.regionsKey),
           let decoded = try? JSONDecoder().decode([TouchpadRegion].self, from: data) {
            regions = decoded
        }
    }

    /// Recompute which regions are currently pressed based on the latest
    /// finger positions. Called from `updateCurrentPositions`.
    private func recomputePressedRegions(f0Active: Bool, f0X: Int, f0Y: Int,
                                         f1Active: Bool, f1X: Int, f1Y: Int) {
        guard !regions.isEmpty else {
            pressedRegions.removeAll()
            return
        }
        var pressed = Set<UUID>()
        let w = Double(surfaceWidth), h = Double(surfaceHeight)
        for region in regions {
            if f0Active && region.contains(normalizedX: Double(f0X) / w, y: Double(f0Y) / h) {
                pressed.insert(region.id)
            } else if f1Active && region.contains(normalizedX: Double(f1X) / w, y: Double(f1Y) / h) {
                pressed.insert(region.id)
            }
        }
        pressedRegions = pressed
    }

    // MARK: - Stdout parsing

    private var stdoutBuffer = Data()

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

    /// Format: "T <seq> <btn> <f0Active> <f0Id> <f0X> <f0Y> <f1Active> <f1Id> <f1X> <f1Y> <kind>"
    private func handleLine(_ line: String) {
        let parts = line.split(separator: " ").map(String.init)
        guard parts.first == "T", parts.count >= 11,
              let f0Active = UInt8(parts[3]),
              let f0Id = UInt8(parts[4]),
              let f0X = Int(parts[5]),
              let f0Y = Int(parts[6]),
              let f1Active = UInt8(parts[7]),
              let f1Id = UInt8(parts[8]),
              let f1X = Int(parts[9]),
              let f1Y = Int(parts[10]) else { return }

        lock.lock()
        defer { lock.unlock() }

        applyFinger(active: f0Active != 0, id: f0Id, x: f0X, y: f0Y,
                    last: &lastF0Pos, delta: &finger0Delta)
        applyFinger(active: f1Active != 0, id: f1Id, x: f1X, y: f1Y,
                    last: &lastF1Pos, delta: &finger1Delta)
        updateCurrentPositions(f0Active: f0Active != 0, f0X: f0X, f0Y: f0Y,
                               f1Active: f1Active != 0, f1X: f1X, f1Y: f1Y)
    }

    private func applyFinger(active: Bool, id: UInt8, x: Int, y: Int,
                             last: inout (id: UInt8, x: Int, y: Int)?,
                             delta: inout FingerDelta) {
        delta.active = active
        if !active {
            last = nil
            return
        }
        // Same finger as before? Accumulate delta. Otherwise reset baseline
        // so a finger-lift-and-replace doesn't produce a jump.
        if let prev = last, prev.id == id {
            delta.dx += Float(x - prev.x)
            delta.dy += Float(y - prev.y)
        }
        last = (id, x, y)
    }

    /// Write the latest absolute positions to the public `currentF0`/`currentF1`
    /// slots so the calibration view can read them in real time.
    private func updateCurrentPositions(f0Active: Bool, f0X: Int, f0Y: Int,
                                        f1Active: Bool, f1X: Int, f1Y: Int) {
        currentF0 = f0Active ? (f0X, f0Y) : nil
        currentF1 = f1Active ? (f1X, f1Y) : nil
        recomputePressedRegions(f0Active: f0Active, f0X: f0X, f0Y: f0Y,
                                f1Active: f1Active, f1X: f1X, f1Y: f1Y)
    }

    // MARK: - Helper discovery

    private func helperPath() -> URL? {
        if let bundlePath = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("TouchpadHelper"),
           FileManager.default.isExecutableFile(atPath: bundlePath.path) {
            return bundlePath
        }
        if let resourcePath = Bundle.main.url(forResource: "TouchpadHelper", withExtension: nil) {
            return resourcePath
        }
        let devPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TouchpadHelper/TouchpadHelper")
        if FileManager.default.isExecutableFile(atPath: devPath.path) {
            return devPath
        }
        return nil
    }
}
